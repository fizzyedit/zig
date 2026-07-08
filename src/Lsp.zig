//! zls-backed hover + Ctrl/Cmd-click goto-definition for `.zig`/`.zon` files. Owns the single
//! `lsp.Client` instance for this plugin; see `lsp/Client.zig` for the actual protocol work.
const std = @import("std");
const zig = @import("../zig.zig");
const sdk = zig.sdk;
const dvui = zig.dvui;
const Client = @import("lsp/Client.zig");

var client: Client = .{};

fn isZigFile(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".zig") or std.ascii.eqlIgnoreCase(ext, ".zon");
}

pub fn onFolderOpen(_: *anyopaque, _: std.mem.Allocator) void {
    dvui.log.warn("zig: onFolderOpen fired, host.folder()={?s}", .{sdk.host().folder()});
    client.onFolderOpen();
}

pub fn onFolderClose(_: *anyopaque) void {
    client.onFolderClose();
}

pub fn deinit() void {
    client.deinit();
}

var logged_first_hover_call = false;

pub fn hover(_: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?sdk.language.HoverResult {
    if (!logged_first_hover_call) {
        logged_first_hover_call = true;
        dvui.log.warn("zig: hover hook reached for the first time, ext={s} path={s}", .{ ext, path });
    }
    if (!isZigFile(ext)) return null;
    return client.hover(path, bytes, byte_offset);
}

pub fn gotoDefinition(_: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?sdk.language.DefinitionLocation {
    if (!isZigFile(ext)) return null;
    return client.gotoDefinition(path, bytes, byte_offset);
}
