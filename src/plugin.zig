const std = @import("std");
const zig = @import("../zig.zig");
const sdk = zig.sdk;
const dvui = zig.dvui;
const Highlight = @import("Highlight.zig");
const Lsp = @import("Lsp.zig");

const plugin_options = @import("fizzy_plugin_options");

pub const manifest = sdk.PluginManifest{
    .id = "zig",
    .name = "Zig",
    .version = plugin_options.version,
};

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "zig",
    .display_name = "Zig",
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
    .onFolderOpen = Lsp.onFolderOpen,
    .onFolderClose = Lsp.onFolderClose,
};

var plugin_state: u8 = 0;

const language_support: sdk.LanguageSupport = .{
    .id = "zig",
    .owner = &plugin,
    .vtable = &language_vtable,
};

const language_vtable: sdk.LanguageSupport.VTable = .{
    .treeSitterHighlight = Highlight.treeSitterHighlight,
    .hover = Lsp.hover,
    .gotoDefinition = Lsp.gotoDefinition,
};

const icon_png = @embedFile("../ICON.png");
const icon_source: dvui.ImageSource = .{ .imageFile = .{
    .bytes = icon_png,
    .name = "ICON.png",
    .invalidation = .ptr,
} };

fn drawPluginIcon(_: ?*anyopaque) void {
    _ = dvui.image(@src(), .{ .source = icon_source, .shrink = .ratio }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 32, .h = 32 },
    });
}

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);
    try host.registerPluginIcon(.{ .owner = &plugin, .draw = drawPluginIcon });
    try host.registerLanguageSupport(language_support);
}

fn deinit(_: *anyopaque) void {
    Lsp.deinit();
}

comptime {
    sdk.Plugin.assertUtilityVTable(vtable);
}
