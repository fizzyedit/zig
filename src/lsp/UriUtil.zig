//! Absolute file path <-> `file://` URI conversion for LSP requests. Deliberately minimal:
//! handles the POSIX-path case (this plugin targets zls, which runs locally next to the
//! editor) rather than the full URI grammar.
const std = @import("std");

/// Percent-encodes `path` and prefixes it with `file://`. On POSIX, `path` is expected to
/// start with `/`, giving the conventional `file:///abs/path` triple-slash form.
pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    for (path) |c| {
        switch (c) {
            // RFC 3986 unreserved + the path separator; everything else gets escaped.
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => try out.append(allocator, c),
            else => try out.print(allocator, "%{X:0>2}", .{c}),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Reverses `pathToUri`. Returns an error if `uri` isn't a `file://` URI.
pub fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnsupportedScheme;
    const encoded = uri[prefix.len..];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const byte = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, encoded[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, byte);
            i += 3;
        } else {
            try out.append(allocator, encoded[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "pathToUri / uriToPath roundtrip" {
    const allocator = std.testing.allocator;
    const path = "/Users/foxnne/dev/fizzy/src/App.zig";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///Users/foxnne/dev/fizzy/src/App.zig", uri);

    const back = try uriToPath(allocator, uri);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(path, back);
}

test "pathToUri escapes spaces" {
    const allocator = std.testing.allocator;
    const uri = try pathToUri(allocator, "/a path/with space.zig");
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///a%20path/with%20space.zig", uri);
}
