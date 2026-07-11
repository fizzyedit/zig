//! zls-backed hover + Ctrl/Cmd-click goto-definition for `.zig`/`.zon` files. Owns the single
//! `lsp.Client` instance for this plugin; see `lsp/Client.zig` for the actual protocol work.
const std = @import("std");
const zig = @import("../zig.zig");
const sdk = zig.sdk;
const Client = @import("lsp/Client.zig");

var client: Client = .{};

fn isZigFile(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".zig") or std.ascii.eqlIgnoreCase(ext, ".zon");
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
