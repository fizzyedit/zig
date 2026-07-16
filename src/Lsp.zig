//! zls-backed hover, Ctrl/Cmd-click goto-definition, completion, signature help, and format
//! for `.zig`/`.zon` files, built on the shared, server-agnostic `core.lsp.Client` (see
//! `src/core/lsp/Client.zig` in the fizzy repo for the actual JSON-RPC/threading/caching
//! work). This file supplies only what's specific to zls: the spawn command, the
//! `languageId`, the host callbacks, and the `.zig`/`.zon` extension gate.
const std = @import("std");
const builtin = @import("builtin");
const zig = @import("../zig.zig");
const sdk = zig.sdk;
const core = zig.core;
const Client = core.lsp.Client;

var client: Client = .{};

/// Storage for the resolved `zls` command — `Client.Config.command` just holds a slice
/// reference, so this needs to outlive `configure()`. One entry, one process lifetime.
var command_buf: [1][]const u8 = undefined;

/// Storage for the `initializationOptions` sent to zls — same lifetime requirement as
/// `command_buf` (`Client.Config.initialization_options` doc comment: "must outlive every
/// call to `onFolderOpen`, this client re-sends it on every server restart").
var init_options: std.json.ObjectMap = .empty;

fn isZigFile(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".zig") or std.ascii.eqlIgnoreCase(ext, ".zon");
}

fn getFolder() ?[]const u8 {
    return sdk.host().folder();
}

fn log(source: []const u8, level: std.log.Level, msg: []const u8) void {
    sdk.host().logLine(level, source, msg);
}

fn currentEnviron() std.process.Environ {
    return .{ .block = .{ .slice = std.mem.span(@as([*:null]?[*:0]const u8, @ptrCast(std.c.environ))) } };
}

fn tryDir(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, exe_name: []const u8) ?[]const u8 {
    if (dir.len == 0) return null;
    const candidate = std.fs.path.join(gpa, &.{ dir, exe_name }) catch return null;
    std.Io.Dir.accessAbsolute(io, candidate, .{}) catch {
        gpa.free(candidate);
        return null;
    };
    return candidate;
}

fn findInPathList(gpa: std.mem.Allocator, io: std.Io, path_list: []const u8, exe_name: []const u8) ?[]const u8 {
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.tokenizeScalar(u8, path_list, sep);
    while (it.next()) |dir| {
        if (tryDir(gpa, io, dir, exe_name)) |found| return found;
    }
    return null;
}

const login_path_marker = "__fizzy_exe_path__";

/// Spawns the user's login shell once to recover the PATH it has after sourcing
/// `.zshrc`/`.bash_profile`/etc. A desktop-launched app (double-click, Dock, Spotlight,
/// a `.desktop` file) inherits launchd's or the session manager's bare PATH instead —
/// that's the actual gap that leaves a per-user zls install invisible even though a
/// terminal-launched build finds it fine. This mirrors the "shell env" resolution VS Code
/// and most other Electron-style editors do on macOS/Linux for the same reason.
///
/// Output is marker-delimited (and the marker is looked up from the end) so that startup
/// noise a shell rc file prints — banners, version-manager messages, etc. — can't be
/// mistaken for the PATH itself.
fn resolveLoginShellPath(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const environ = currentEnviron();
    const shell = std.process.Environ.getAlloc(environ, gpa, "SHELL") catch return null;
    defer gpa.free(shell);

    const script = "printf '%s\\n%s\\n' \"" ++ login_path_marker ++ "\" \"$PATH\"";
    // fish doesn't accept bundled short flags the way sh-derived shells do.
    const is_fish = std.mem.endsWith(u8, shell, "fish");
    const argv: []const []const u8 = if (is_fish)
        &.{ shell, "-i", "-l", "-c", script }
    else
        &.{ shell, "-ilc", script };

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    defer _ = child.wait(io) catch {};

    var buf: [512]u8 = undefined;
    var rdr = child.stdout.?.readerStreaming(io, &buf);
    const raw = rdr.interface.allocRemaining(gpa, .limited(1 << 16)) catch return null;
    defer gpa.free(raw);

    const marker_pos = std.mem.lastIndexOf(u8, raw, login_path_marker) orelse return null;
    const after_marker = raw[marker_pos + login_path_marker.len ..];
    const nl = std.mem.indexOfScalar(u8, after_marker, '\n') orelse return null;
    const line_start = after_marker[nl + 1 ..];
    const line_end = std.mem.indexOfScalar(u8, line_start, '\n') orelse line_start.len;
    const path_line = std.mem.trim(u8, line_start[0..line_end], " \t\r");
    if (path_line.len == 0) return null;
    return gpa.dupe(u8, path_line) catch null;
}

/// Resolves an absolute path to an executable, checked in priority order:
///   1. The process's own inherited PATH — identical to a plain `execvp(name)`, so this
///      changes nothing for anyone it already works for (e.g. running from a terminal).
///   2. (macOS/Linux only) the user's actual login-shell PATH, recovered by spawning their
///      shell once (see `resolveLoginShellPath`, cached in `shell_path` across repeat
///      calls so resolving both `zls` and `zig` only spawns one shell) — covers an install
///      anywhere on PATH, not just conventional per-user directories.
/// Falls back to the bare exe name (today's behavior, including its error path) if neither
/// finds anything — Windows never needs to look past PATH, since GUI-launched apps there
/// inherit the same session-wide PATH a terminal does.
fn resolveExecutable(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    shell_path: *?[]const u8,
    posix_name: []const u8,
    windows_name: []const u8,
) []const u8 {
    const exe_name = if (builtin.os.tag == .windows) windows_name else posix_name;

    if (std.process.Environ.getAlloc(environ, gpa, "PATH")) |path| {
        defer gpa.free(path);
        if (findInPathList(gpa, io, path, exe_name)) |found| return found;
    } else |_| {}

    if (builtin.os.tag != .windows) {
        if (shell_path.* == null) shell_path.* = resolveLoginShellPath(gpa, io);
        if (shell_path.*) |sp| {
            if (findInPathList(gpa, io, sp, exe_name)) |found| return found;
        }
    }

    return exe_name;
}

/// Wires the shared LSP client to zls — called once from `plugin.register(host)`, the
/// earliest point host-injected values (`sdk.allocator()`, `sdk.host()`) are valid.
pub fn configure() void {
    const gpa = sdk.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const environ = currentEnviron();

    var shell_path: ?[]const u8 = null;
    defer if (shell_path) |sp| gpa.free(sp);

    command_buf[0] = resolveExecutable(gpa, io, environ, &shell_path, "zls", "zls.exe");

    // zls resolves its own zig install by searching PATH, same as we do for zls itself —
    // and inherits this process's (potentially launchd-stripped) environment when spawned,
    // so it hits the exact same "not on PATH" gap. Telling it explicitly via
    // `zig_exe_path` sidesteps that rather than relying on env inheritance to carry our
    // fix-up through to a child process we don't control the spawn options of.
    const zig_path = resolveExecutable(gpa, io, environ, &shell_path, "zig", "zig.exe");
    init_options.put(gpa, "zig_exe_path", .{ .string = zig_path }) catch {};

    client.configure(.{
        .command = &command_buf,
        .language_id = "zig",
        .allocator = gpa,
        .getFolder = getFolder,
        .log = log,
        .refresh = sdk.refresh,
        .initialization_options = .{ .object = init_options },
    });
}

pub fn onFolderOpen(_: *anyopaque, _: std.mem.Allocator) void {
    client.onFolderOpen();
}

pub fn onFolderClose(_: *anyopaque) void {
    client.onFolderClose();
}

pub fn deinit() void {
    client.deinit();
}

pub fn hover(_: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?sdk.language.HoverResult {
    if (!isZigFile(ext)) return null;
    return client.hover(path, bytes, byte_offset);
}

pub fn gotoDefinition(_: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?sdk.language.DefinitionLocation {
    if (!isZigFile(ext)) return null;
    return client.gotoDefinition(path, bytes, byte_offset);
}

pub fn completion(_: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?[]const sdk.language.CompletionItem {
    if (!isZigFile(ext)) return null;
    return client.completion(path, bytes, byte_offset);
}

pub fn signatureHelp(_: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?sdk.language.SignatureHelpResult {
    if (!isZigFile(ext)) return null;
    return client.signatureHelp(path, bytes, byte_offset);
}

pub fn resolveCompletionDocumentation(_: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize, index: usize) ?[]const u8 {
    if (!isZigFile(ext)) return null;
    return client.resolveCompletionDocumentation(path, bytes, byte_offset, index);
}

pub fn supportsFormat(_: *anyopaque, ext: []const u8) bool {
    return isZigFile(ext);
}

pub fn format(_: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8) ?[]const u8 {
    if (!isZigFile(ext)) return null;
    return client.format(path, bytes);
}
