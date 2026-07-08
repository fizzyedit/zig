//! A minimal zls (https://github.com/zigtools/zls) client: process lifecycle, JSON-RPC
//! framing, and just enough of the LSP to answer `textDocument/hover` and
//! `textDocument/definition`.
//!
//! Threading model (read this before touching anything below):
//! - `hover`/`gotoDefinition` are called on the **draw thread**, every frame the mouse
//!   dwells over a token (hover) or on a Ctrl/Cmd+click (gotoDefinition). `hover` must
//!   never block — it only reads a cache and, on a miss, hands a *copy* of the input off to
//!   a background worker. `gotoDefinition` is allowed to block briefly (a few hundred ms).
//! - The reader thread and dispatch-worker thread are the only places that block on zls I/O.
//!   Neither may call `dvui.*` — they only touch their own copied inputs, this struct's
//!   fields (behind `SpinLock`), and `sdk.allocator()`, mirroring the discipline documented
//!   on `pixi`'s `PackJob.zig`.
//! - `bytes` passed into `hover`/`gotoDefinition` is a borrowed slice into the live,
//!   mutable document buffer — copy it before handing it to the background queue.
const std = @import("std");
const zig_mod = @import("../../zig.zig");
const sdk = zig_mod.sdk;
const dvui = zig_mod.dvui;
const Protocol = @import("Protocol.zig");
const UriUtil = @import("UriUtil.zig");

const Client = @This();

/// Real OS-thread-safe spinlock (`std.atomic.Mutex` has no blocking `lock()`, only
/// `tryLock`/`unlock`) for the short critical sections below — every locked region here is
/// O(1) hashmap/list work, never I/O, so spinning is fine.
const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        while (!self.inner.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(self: *SpinLock) void {
        self.inner.unlock();
    }
};

const StateTag = enum(u8) { not_started, starting, ready, unavailable };

const ResponseSlot = struct {
    ready: std.atomic.Value(bool) = .init(false),
    /// Raw JSON message body, owned by `sdk.allocator()`. Set once by the reader thread,
    /// consumed and freed by whichever caller is waiting on this slot.
    body: ?[]u8 = null,
};

const DocState = struct {
    version: i32,
    last_hash: u64,
};

const CacheKey = struct {
    path_hash: u64,
    byte_offset: usize,
};

const CacheEntry = struct {
    text: []u8,
    /// Insertion sequence number (from `Client.cache_seq`), used for oldest-first eviction.
    /// A plain counter, not wall-clock time — this zig's `std.time` has no timestamp function
    /// usable off the `Io` interface, and a counter is all LRU-ish eviction needs anyway.
    seq: u64,
};

const HoverJob = struct {
    path: []u8,
    bytes: []u8,
    byte_offset: usize,
    key: CacheKey,
};

state: std.atomic.Value(StateTag) = .init(.not_started),
workspace_root: ?[]u8 = null,
child: ?std.process.Child = null,
next_id: std.atomic.Value(i64) = .init(1),
encoding: Protocol.PositionEncoding = .utf16,
shutdown: std.atomic.Value(bool) = .init(false),

reader_thread: ?std.Thread = null,
dispatch_thread: ?std.Thread = null,

write_lock: SpinLock = .{},

response_map_lock: SpinLock = .{},
response_map: std.AutoHashMapUnmanaged(i64, *ResponseSlot) = .empty,

open_docs_lock: SpinLock = .{},
open_docs: std.StringHashMapUnmanaged(DocState) = .empty,

hover_cache_lock: SpinLock = .{},
hover_cache: std.AutoHashMapUnmanaged(CacheKey, CacheEntry) = .empty,
in_flight: std.AutoHashMapUnmanaged(CacheKey, void) = .empty,
cache_seq: u64 = 0,

queue_lock: SpinLock = .{},
queue: std.ArrayListUnmanaged(HoverJob) = .empty,

/// Scratch buffer for the path returned from `gotoDefinition` — valid only until the next
/// `gotoDefinition` call, which matches how the caller (`TextEditor.drawEditor`) uses it:
/// synchronously, immediately after the call returns, in the same frame.
def_path_buf: std.ArrayListUnmanaged(u8) = .empty,

const hover_cache_limit = 256;
const poll_interval_ms: u64 = 5;
const hover_timeout_ms: u64 = 2000;
const definition_timeout_ms: u64 = 400;
const initialize_timeout_ms: u64 = 10_000;

// ---- SDK-facing entry points (called on the draw thread) ------------------------------

pub fn onFolderOpen(self: *Client) void {
    // A real project folder is always authoritative over a per-file fallback root (see
    // `ensureStarted`) — restart zls against it if a process is already running (e.g. was
    // lazily spawned against a loose file's directory before this folder was opened).
    if (self.state.load(.acquire) != .not_started) self.shutdownProcess();
    self.workspaceRootUpdate();
}

pub fn onFolderClose(self: *Client) void {
    self.shutdownProcess();
    if (self.workspace_root) |r| sdk.allocator().free(r);
    self.workspace_root = null;
}

pub fn deinit(self: *Client) void {
    self.shutdownProcess();
    if (self.workspace_root) |r| sdk.allocator().free(r);
    self.workspace_root = null;
    self.def_path_buf.deinit(sdk.allocator());
}

/// Non-blocking. Returns a cached hover result, or null and (on a cache miss) kicks off a
/// background fetch for next time.
pub fn hover(self: *Client, path: []const u8, bytes: []const u8, byte_offset: usize) ?sdk.language.HoverResult {
    if (path.len == 0) return null;
    if (!self.ensureStarted(path)) return null;

    const gpa = sdk.allocator();
    const key: CacheKey = .{ .path_hash = std.hash.Wyhash.hash(0, path), .byte_offset = byte_offset };

    self.hover_cache_lock.lock();
    if (self.hover_cache.get(key)) |entry| {
        self.hover_cache_lock.unlock();
        return .{ .text = entry.text };
    }
    if (self.in_flight.contains(key)) {
        self.hover_cache_lock.unlock();
        return null;
    }
    self.in_flight.put(gpa, key, {}) catch {
        self.hover_cache_lock.unlock();
        return null;
    };
    self.hover_cache_lock.unlock();

    const owned_path = gpa.dupe(u8, path) catch {
        self.clearInFlight(key);
        return null;
    };
    const owned_bytes = gpa.dupe(u8, bytes) catch {
        gpa.free(owned_path);
        self.clearInFlight(key);
        return null;
    };

    self.queue_lock.lock();
    self.queue.append(gpa, .{ .path = owned_path, .bytes = owned_bytes, .byte_offset = byte_offset, .key = key }) catch {
        self.queue_lock.unlock();
        gpa.free(owned_path);
        gpa.free(owned_bytes);
        self.clearInFlight(key);
        return null;
    };
    self.queue_lock.unlock();
    dvui.log.warn("zig: hover: queued fetch for {s}@{d}", .{ path, byte_offset });
    return null;
}

/// May block up to `definition_timeout_ms`. Returns the definition location for the symbol
/// at `byte_offset`, or null on timeout / no result / zls unavailable.
pub fn gotoDefinition(self: *Client, path: []const u8, bytes: []const u8, byte_offset: usize) ?sdk.language.DefinitionLocation {
    dvui.log.warn("zig: gotoDefinition: path={s} byte_offset={d}", .{ path, byte_offset });
    if (path.len == 0) return null;
    if (!self.ensureStarted(path)) {
        dvui.log.warn("zig: gotoDefinition: ensureStarted returned false (state={s})", .{@tagName(self.state.load(.acquire))});
        return null;
    }

    const io = dvui.io;
    const gpa = sdk.allocator();

    self.syncDocument(io, path, bytes) catch |err| {
        dvui.log.warn("zig: gotoDefinition: syncDocument failed: {any}", .{err});
        return null;
    };

    const pos = Protocol.byteOffsetToPosition(bytes, byte_offset, self.encoding);
    const uri = UriUtil.pathToUri(gpa, path) catch return null;
    defer gpa.free(uri);

    const req = self.sendRequest(io, "textDocument/definition", .{
        .textDocument = .{ .uri = uri },
        .position = pos,
    }) catch |err| {
        dvui.log.warn("zig: gotoDefinition: sendRequest failed: {any}", .{err});
        return null;
    };

    const body = self.waitForSlot(io, req.id, req.slot, definition_timeout_ms) orelse {
        dvui.log.warn("zig: gotoDefinition: request (id={d}) timed out", .{req.id});
        return null;
    };
    defer gpa.free(body);
    dvui.log.warn("zig: gotoDefinition response (id={d}): {s}", .{ req.id, body });

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    const result = resp.result orelse {
        dvui.log.warn("zig: gotoDefinition: no result (error={any})", .{resp.err});
        return null;
    };

    const loc_obj = firstLocationObject(result) orelse return null;
    const target_uri = jsonString(loc_obj, "uri") orelse return null;
    const range = jsonObject(loc_obj, "range") orelse return null;
    const start = jsonObject(range, "start") orelse return null;
    const line = jsonInt(start, "line") orelse return null;
    const character = jsonInt(start, "character") orelse return null;

    const target_path = UriUtil.uriToPath(gpa, target_uri) catch return null;
    defer gpa.free(target_path);

    // Only need the target file's contents to convert Position -> byte offset when it
    // differs from the source document (same-file jumps could reuse `bytes`, but reading
    // the target is simpler and correct in both cases — goto-definition is already an
    // infrequent, budget-allowed-to-block user action).
    const target_bytes = std.Io.Dir.cwd().readFileAlloc(io, target_path, gpa, .limited(64 * 1024 * 1024)) catch null;
    defer if (target_bytes) |tb| gpa.free(tb);

    const byte_off = if (target_bytes) |tb|
        Protocol.positionToByteOffset(tb, .{ .line = @intCast(line), .character = @intCast(character) }, self.encoding)
    else
        0;

    self.def_path_buf.clearRetainingCapacity();
    self.def_path_buf.appendSlice(gpa, target_path) catch return null;
    return .{ .path = self.def_path_buf.items, .byte_offset = byte_off };
}

// ---- lifecycle --------------------------------------------------------------------------

fn workspaceRootUpdate(self: *Client) void {
    const gpa = sdk.allocator();
    if (self.workspace_root) |r| gpa.free(r);
    self.workspace_root = null;
    if (sdk.host().folder()) |f| {
        self.workspace_root = gpa.dupe(u8, f) catch null;
    }
}

/// Falls back to `doc_path`'s containing directory as the workspace root when no project
/// folder is open — otherwise a loose file opened without "Open Project Folder" would never
/// get hover/goto-definition at all. A real folder open (`onFolderOpen`) always overrides
/// this and restarts zls against the authoritative root.
fn deriveFallbackRoot(self: *Client, doc_path: []const u8) void {
    const dir = std.fs.path.dirname(doc_path) orelse return;
    self.workspace_root = sdk.allocator().dupe(u8, dir) catch null;
}

/// Non-blocking: kicks off a background spawn+handshake at most once per `not_started`
/// period. Returns whether the client is ready to accept requests right now.
fn ensureStarted(self: *Client, doc_path: []const u8) bool {
    switch (self.state.load(.acquire)) {
        .ready => return true,
        .unavailable => return false,
        .starting => return false,
        .not_started => {
            if (self.workspace_root == null) self.deriveFallbackRoot(doc_path);
            if (self.workspace_root == null) {
                dvui.log.warn("zig: ensureStarted: no workspace root (doc_path={s}) — not spawning zls", .{doc_path});
                return false;
            }
            dvui.log.warn("zig: ensureStarted: kicking off zls startup thread (root={s})", .{self.workspace_root.?});
            self.state.store(.starting, .release);
            const t = std.Thread.spawn(.{}, startupThreadMain, .{self}) catch |err| {
                dvui.log.warn("zig: std.Thread.spawn(startupThreadMain) failed: {any}", .{err});
                self.state.store(.unavailable, .release);
                return false;
            };
            t.detach();
            return false;
        },
    }
}

fn startupThreadMain(self: *Client) void {
    self.spawnAndHandshake(dvui.io) catch |err| {
        dvui.log.warn("zig: zls unavailable ({any})", .{err});
        self.state.store(.unavailable, .release);
        return;
    };
    self.state.store(.ready, .release);
}

fn spawnAndHandshake(self: *Client, io: std.Io) !void {
    const root = self.workspace_root orelse return error.NoWorkspace;
    const gpa = sdk.allocator();

    dvui.log.warn("zig: spawning zls, cwd={s}", .{root});
    self.child = std.process.spawn(io, .{
        .argv = &.{"zls"},
        .cwd = .{ .path = root },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| {
        dvui.log.warn("zig: std.process.spawn(\"zls\") failed: {any}", .{err});
        return err;
    };
    dvui.log.warn("zig: zls process spawned", .{});

    self.reader_thread = try std.Thread.spawn(.{}, readerThreadMain, .{ self, io });

    const root_uri = try UriUtil.pathToUri(gpa, root);
    defer gpa.free(root_uri);

    const req = try self.sendRequest(io, "initialize", .{
        .processId = @as(?u32, null),
        .rootUri = root_uri,
        .capabilities = .{
            .general = .{ .positionEncodings = &[_][]const u8{"utf-8"} },
            .textDocument = .{
                .definition = .{ .linkSupport = false },
            },
        },
    });
    dvui.log.warn("zig: sent initialize (id={d}), waiting up to {d}ms", .{ req.id, initialize_timeout_ms });
    const body = self.waitForSlot(io, req.id, req.slot, initialize_timeout_ms) orelse {
        dvui.log.warn("zig: initialize timed out — zls never responded", .{});
        return error.InitializeTimeout;
    };
    defer gpa.free(body);
    dvui.log.warn("zig: initialize response: {s}", .{body});

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    if (resp.result) |result| {
        if (jsonObject(result, "capabilities")) |caps| {
            if (jsonString(caps, "positionEncoding")) |enc| {
                if (std.mem.eql(u8, enc, "utf-8")) self.encoding = .utf8;
            }
        }
    }
    dvui.log.warn("zig: negotiated position encoding: {s}", .{@tagName(self.encoding)});

    try self.sendNotification(io, "initialized", .{});

    self.dispatch_thread = try std.Thread.spawn(.{}, dispatchThreadMain, .{ self, io });
    dvui.log.warn("zig: zls ready", .{});
}

fn shutdownProcess(self: *Client) void {
    if (self.state.load(.acquire) == .not_started) return;
    const gpa = sdk.allocator();
    const io = dvui.io;

    self.shutdown.store(true, .release);
    if (self.child) |*c| c.kill(io);

    if (self.reader_thread) |t| {
        t.join();
        self.reader_thread = null;
    }
    if (self.dispatch_thread) |t| {
        t.join();
        self.dispatch_thread = null;
    }
    self.child = null;
    self.shutdown.store(false, .release);

    self.hover_cache_lock.lock();
    var hc_it = self.hover_cache.iterator();
    while (hc_it.next()) |e| gpa.free(e.value_ptr.text);
    self.hover_cache.clearAndFree(gpa);
    self.in_flight.clearAndFree(gpa);
    self.hover_cache_lock.unlock();

    self.open_docs_lock.lock();
    var od_it = self.open_docs.iterator();
    while (od_it.next()) |e| gpa.free(e.key_ptr.*);
    self.open_docs.clearAndFree(gpa);
    self.open_docs_lock.unlock();

    self.queue_lock.lock();
    for (self.queue.items) |j| {
        gpa.free(j.path);
        gpa.free(j.bytes);
    }
    self.queue.clearAndFree(gpa);
    self.queue_lock.unlock();

    self.response_map_lock.lock();
    self.response_map.clearAndFree(gpa);
    self.response_map_lock.unlock();

    self.encoding = .utf16;
    self.state.store(.not_started, .release);
}

fn clearInFlight(self: *Client, key: CacheKey) void {
    self.hover_cache_lock.lock();
    _ = self.in_flight.remove(key);
    self.hover_cache_lock.unlock();
}

// ---- background threads -----------------------------------------------------------------

fn readerThreadMain(self: *Client, io: std.Io) void {
    const gpa = sdk.allocator();
    var buf: [1 << 16]u8 = undefined;
    var rdr = self.child.?.stdout.?.reader(io, &buf);
    while (!self.shutdown.load(.acquire)) {
        const body = Protocol.readMessage(gpa, &rdr.interface) catch {
            self.state.store(.unavailable, .release);
            return;
        };
        var owned = true;
        defer if (owned) gpa.free(body);

        var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch continue;
        defer parsed.deinit();
        const resp = Protocol.parseResponse(parsed.value);
        const id = resp.id orelse continue; // server notification (e.g. diagnostics) — ignored

        self.response_map_lock.lock();
        const slot = self.response_map.get(id);
        self.response_map_lock.unlock();
        if (slot) |s| {
            s.body = body;
            owned = false;
            s.ready.store(true, .release);
        }
    }
}

fn dispatchThreadMain(self: *Client, io: std.Io) void {
    const gpa = sdk.allocator();
    while (!self.shutdown.load(.acquire)) {
        self.queue_lock.lock();
        const job: ?HoverJob = if (self.queue.items.len > 0) self.queue.orderedRemove(0) else null;
        self.queue_lock.unlock();

        const j = job orelse {
            io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};
            continue;
        };
        defer gpa.free(j.path);
        defer gpa.free(j.bytes);
        defer self.clearInFlight(j.key);

        self.runHoverJob(io, j) catch |err| {
            dvui.log.warn("zig: runHoverJob failed: {any}", .{err});
            continue;
        };
    }
}

fn runHoverJob(self: *Client, io: std.Io, j: HoverJob) !void {
    const gpa = sdk.allocator();
    try self.syncDocument(io, j.path, j.bytes);

    const pos = Protocol.byteOffsetToPosition(j.bytes, j.byte_offset, self.encoding);
    const uri = try UriUtil.pathToUri(gpa, j.path);
    defer gpa.free(uri);

    const req = try self.sendRequest(io, "textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = pos,
    });
    const body = self.waitForSlot(io, req.id, req.slot, hover_timeout_ms) orelse {
        dvui.log.warn("zig: hover request (id={d}) timed out", .{req.id});
        return;
    };
    defer gpa.free(body);
    dvui.log.warn("zig: hover response (id={d}): {s}", .{ req.id, body });

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    const result = resp.result orelse {
        dvui.log.warn("zig: hover response had no result (error={any})", .{resp.err});
        return;
    };
    if (result == .null) return;
    const contents = jsonGet(result, "contents") orelse {
        dvui.log.warn("zig: hover result had no 'contents' field", .{});
        return;
    };
    const text = extractContentsText(contents) orelse {
        dvui.log.warn("zig: could not extract text from hover 'contents'", .{});
        return;
    };
    const owned_text = try gpa.dupe(u8, text);

    self.hover_cache_lock.lock();
    defer self.hover_cache_lock.unlock();
    self.cache_seq += 1;
    self.hover_cache.put(gpa, j.key, .{ .text = owned_text, .seq = self.cache_seq }) catch {
        gpa.free(owned_text);
        return;
    };
    self.evictOldestIfNeededLocked(gpa);
}

fn evictOldestIfNeededLocked(self: *Client, gpa: std.mem.Allocator) void {
    if (self.hover_cache.count() <= hover_cache_limit) return;
    var oldest_key: ?CacheKey = null;
    var oldest_seq: u64 = std.math.maxInt(u64);
    var it = self.hover_cache.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.seq < oldest_seq) {
            oldest_seq = e.value_ptr.seq;
            oldest_key = e.key_ptr.*;
        }
    }
    if (oldest_key) |k| {
        if (self.hover_cache.fetchRemove(k)) |kv| gpa.free(kv.value.text);
    }
}

// ---- document sync ------------------------------------------------------------------------

fn syncDocument(self: *Client, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const gpa = sdk.allocator();
    const hash = std.hash.Wyhash.hash(0, bytes);

    var send_open = false;
    var send_change = false;
    var version: i32 = 1;

    self.open_docs_lock.lock();
    if (self.open_docs.getPtr(path)) |st| {
        if (st.last_hash != hash) {
            st.version += 1;
            st.last_hash = hash;
            version = st.version;
            send_change = true;
        }
    } else {
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        try self.open_docs.put(gpa, owned_path, .{ .version = 1, .last_hash = hash });
        send_open = true;
    }
    self.open_docs_lock.unlock();

    if (!send_open and !send_change) return;

    const uri = try UriUtil.pathToUri(gpa, path);
    defer gpa.free(uri);

    if (send_open) {
        try self.sendNotification(io, "textDocument/didOpen", .{
            .textDocument = .{ .uri = uri, .languageId = "zig", .version = @as(i32, 1), .text = bytes },
        });
    } else {
        try self.sendNotification(io, "textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = &[_]struct { text: []const u8 }{.{ .text = bytes }},
        });
    }
}

// ---- JSON-RPC plumbing --------------------------------------------------------------------

fn send(self: *Client, io: std.Io, value: anytype) !void {
    self.write_lock.lock();
    defer self.write_lock.unlock();
    const gpa = sdk.allocator();
    const stdin = self.child.?.stdin.?;
    var buf: [4096]u8 = undefined;
    var w = stdin.writer(io, &buf);
    try Protocol.writeMessage(gpa, &w.interface, value);
}

const SentRequest = struct { id: i64, slot: *ResponseSlot };

fn sendRequest(self: *Client, io: std.Io, method: []const u8, params: anytype) !SentRequest {
    const gpa = sdk.allocator();
    const id = Protocol.nextRequestId(&self.next_id);
    const slot = try gpa.create(ResponseSlot);
    slot.* = .{};

    self.response_map_lock.lock();
    try self.response_map.put(gpa, id, slot);
    self.response_map_lock.unlock();

    const Params = @TypeOf(params);
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: i64,
        method: []const u8,
        params: Params,
    };
    self.send(io, Msg{ .id = id, .method = method, .params = params }) catch |err| {
        self.response_map_lock.lock();
        _ = self.response_map.remove(id);
        self.response_map_lock.unlock();
        gpa.destroy(slot);
        return err;
    };
    return .{ .id = id, .slot = slot };
}

fn sendNotification(self: *Client, io: std.Io, method: []const u8, params: anytype) !void {
    const Params = @TypeOf(params);
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: Params,
    };
    try self.send(io, Msg{ .method = method, .params = params });
}

/// Polls `slot.ready` until it's set or `timeout_ms` elapses. Either way, removes the slot
/// from `response_map` and frees it — the caller owns the returned body (if any).
fn waitForSlot(self: *Client, io: std.Io, id: i64, slot: *ResponseSlot, timeout_ms: u64) ?[]u8 {
    const gpa = sdk.allocator();
    var waited: u64 = 0;
    while (!slot.ready.load(.acquire)) {
        if (self.shutdown.load(.acquire) or waited >= timeout_ms) {
            self.response_map_lock.lock();
            _ = self.response_map.remove(id);
            self.response_map_lock.unlock();
            gpa.destroy(slot);
            return null;
        }
        io.sleep(std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake) catch {};
        waited += poll_interval_ms;
    }
    self.response_map_lock.lock();
    _ = self.response_map.remove(id);
    self.response_map_lock.unlock();
    const body = slot.body;
    gpa.destroy(slot);
    return body;
}

// ---- JSON helpers -------------------------------------------------------------------------

fn jsonGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}
fn jsonObject(v: std.json.Value, key: []const u8) ?std.json.Value {
    const got = jsonGet(v, key) orelse return null;
    return switch (got) {
        .object => got,
        else => null,
    };
}
fn jsonString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const got = jsonGet(v, key) orelse return null;
    return switch (got) {
        .string => |s| s,
        else => null,
    };
}
fn jsonInt(v: std.json.Value, key: []const u8) ?i64 {
    const got = jsonGet(v, key) orelse return null;
    return switch (got) {
        .integer => |n| n,
        else => null,
    };
}

/// `textDocument/definition` may reply with a single `Location`, a `Location[]`, or (if we
/// hadn't disabled `linkSupport`) `LocationLink[]` — we only ever request the plain-`Location`
/// shape, so this just unwraps the optional array layer.
fn firstLocationObject(result: std.json.Value) ?std.json.Value {
    return switch (result) {
        .object => result,
        .array => |arr| if (arr.items.len > 0) arr.items[0] else null,
        else => null,
    };
}

/// `Hover.contents` may be a plain string, a `MarkupContent`/`MarkedString` object with a
/// `value` field, or an array of either — walks all three shapes for the first text found.
fn extractContentsText(contents: std.json.Value) ?[]const u8 {
    return switch (contents) {
        .string => |s| s,
        .object => |o| if (o.get("value")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null,
        .array => |arr| if (arr.items.len > 0) extractContentsText(arr.items[0]) else null,
        else => null,
    };
}
