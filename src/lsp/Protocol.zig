//! Minimal JSON-RPC 2.0 framing + the handful of LSP request/response shapes this plugin
//! actually sends (`initialize`, `initialized`, `textDocument/didOpen`, `didChange`,
//! `hover`, `definition`). Deliberately not a general LSP type library — see
//! `docs/PLUGINS.md` in the fizzy repo for why the SDK boundary keeps `bytes`/`path` as
//! plain parameters instead of a richer document model.
const std = @import("std");

/// Whether LSP `Position.character` is a UTF-8 byte offset within the line (if the server
/// honored our `general.positionEncodings: ["utf-8"]` capability) or the LSP-default UTF-16
/// code-unit offset. Negotiated once during `initialize`; see `Client.zig`.
pub const PositionEncoding = enum { utf8, utf16 };

pub const Position = struct {
    line: u32,
    character: u32,
};

/// Convert a byte offset into `text` to an LSP `Position`, in the given encoding.
pub fn byteOffsetToPosition(text: []const u8, byte_offset: usize, encoding: PositionEncoding) Position {
    const offset = @min(byte_offset, text.len);
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < offset) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    const line_bytes = text[line_start..offset];
    const character: u32 = switch (encoding) {
        .utf8 => @intCast(line_bytes.len),
        .utf16 => blk: {
            var units: u32 = 0;
            var view = std.unicode.Utf8View.initUnchecked(line_bytes);
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                units += if (cp > 0xFFFF) 2 else 1;
            }
            break :blk units;
        },
    };
    return .{ .line = line, .character = character };
}

/// Convert an LSP `Position` back to a byte offset into `text`.
pub fn positionToByteOffset(text: []const u8, pos: Position, encoding: PositionEncoding) usize {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line and i < text.len) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    if (line < pos.line) return text.len; // position past EOF, clamp

    const line_start = i;
    var line_end = line_start;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    const line_bytes = text[line_start..line_end];

    switch (encoding) {
        .utf8 => return line_start + @min(pos.character, line_bytes.len),
        .utf16 => {
            var units: u32 = 0;
            var byte_off: usize = 0;
            var view = std.unicode.Utf8View.initUnchecked(line_bytes);
            var it = view.iterator();
            while (units < pos.character) {
                const cp = it.nextCodepoint() orelse break;
                units += if (cp > 0xFFFF) 2 else 1;
                byte_off = it.i;
            }
            return line_start + byte_off;
        },
    }
}

/// Serializes `value` to JSON and writes it as one `Content-Length`-framed LSP message.
pub fn writeMessage(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(body);
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

/// Reads one `Content-Length`-framed message body from `reader`. Returned slice is owned by
/// the caller (allocated with `allocator`).
pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = try reader.takeDelimiterExclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) break; // blank line ends the header block
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const value = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
        // Other headers (e.g. Content-Type) are ignored.
    }
    const len = content_length orelse return error.MissingContentLength;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    try reader.readSliceAll(body);
    return body;
}

pub fn nextRequestId(counter: *std.atomic.Value(i64)) i64 {
    return counter.fetchAdd(1, .monotonic);
}

/// A parsed JSON-RPC response frame's relevant fields, borrowed from a `std.json.Parsed(Value)`
/// the caller owns and frees.
pub const ParsedResponse = struct {
    id: ?i64,
    /// Present on success.
    result: ?std.json.Value,
    /// Present on failure; `.message` is the error text if any.
    err: ?std.json.Value,
};

pub fn parseResponse(parsed: std.json.Value) ParsedResponse {
    var out: ParsedResponse = .{ .id = null, .result = null, .err = null };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return out,
    };
    if (obj.get("id")) |id_v| {
        switch (id_v) {
            .integer => |n| out.id = n,
            else => {},
        }
    }
    out.result = obj.get("result");
    out.err = obj.get("error");
    return out;
}
