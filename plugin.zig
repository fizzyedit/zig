const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const Highlight = @import("src/Highlight.zig");
const Lsp = @import("src/Lsp.zig");

pub const plugin_options = @import("fizzy_plugin_options");

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_options.id,
    .display_name = plugin_options.name,
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
    .completion = Lsp.completion,
    .signatureHelp = Lsp.signatureHelp,
    .resolveCompletionDocumentation = Lsp.resolveCompletionDocumentation,
    .supportsFormat = Lsp.supportsFormat,
    .format = Lsp.format,
};

const icon_png = @embedFile("ICON.png");
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
    Lsp.configure();
    try host.registerLanguageSupport(language_support);
}

fn deinit(_: *anyopaque) void {
    Lsp.deinit();
}

comptime {
    sdk.Plugin.assertUtilityVTable(vtable);
}
