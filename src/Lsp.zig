//! zls-backed hover, Ctrl/Cmd-click goto-definition, completion, signature help, and format
//! for `.zig`/`.zon` files, built on the shared, server-agnostic `core.lsp.Client` (see
//! `src/core/lsp/Client.zig` in the fizzy repo for the actual JSON-RPC/threading/caching
//! work). This file supplies only what's specific to zls: the spawn command, the
//! `languageId`, the host callbacks, and the `.zig`/`.zon` extension gate.
const std = @import("std");
const zig = @import("../zig.zig");
const sdk = zig.sdk;
const core = zig.core;
const Client = core.lsp.Client;

var client: Client = .{};

fn isZigFile(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".zig") or std.ascii.eqlIgnoreCase(ext, ".zon");
}

fn getFolder() ?[]const u8 {
    return sdk.host().folder();
}

fn log(source: []const u8, level: std.log.Level, msg: []const u8) void {
    sdk.host().logLine(level, source, msg);
}

/// Wires the shared LSP client to zls — called once from `plugin.register(host)`, the
/// earliest point host-injected values (`sdk.allocator()`, `sdk.host()`) are valid.
pub fn configure() void {
    client.configure(.{
        .command = &.{"zls"},
        .language_id = "zig",
        .allocator = sdk.allocator(),
        .getFolder = getFolder,
        .log = log,
        .refresh = sdk.refresh,
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
