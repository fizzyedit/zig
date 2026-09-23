const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const Highlight = @import("src/Highlight.zig");
const Lsp = @import("src/Lsp.zig");

/// zls is a subprocess driven from a background thread — neither exists on the web
/// (wasm32-freestanding), so the web build is highlighting only. Every LSP entry below is
/// gated on this so `src/Lsp.zig` (and the SDK's `core.lsp`) is never analyzed there.
const has_lsp = !builtin.target.cpu.arch.isWasm();

pub const plugin_options = @import("fizzy_plugin_options");

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_options.id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
    .onFolderOpen = if (has_lsp) Lsp.onFolderOpen else null,
    .onFolderClose = if (has_lsp) Lsp.onFolderClose else null,
};

var plugin_state: u8 = 0;

const language_support: sdk.LanguageSupport = .{
    .id = "zig",
    .owner = &plugin,
    .vtable = &language_vtable,
};

const language_vtable: sdk.LanguageSupport.VTable = .{
    .treeSitterHighlight = Highlight.treeSitterHighlight,
    .documentOpened = if (has_lsp) Lsp.documentOpened else null,
    .hover = if (has_lsp) Lsp.hover else null,
    .gotoDefinition = if (has_lsp) Lsp.gotoDefinition else null,
    .completion = if (has_lsp) Lsp.completion else null,
    .signatureHelp = if (has_lsp) Lsp.signatureHelp else null,
    .resolveCompletionDocumentation = if (has_lsp) Lsp.resolveCompletionDocumentation else null,
    .supportsFormat = if (has_lsp) Lsp.supportsFormat else null,
    .format = if (has_lsp) Lsp.format else null,
};

const icon_png = @embedFile("ICON.png");
const icon_source: dvui.ImageSource = .{ .imageFile = .{
    .bytes = icon_png,
    .name = "ICON.png",
    .invalidation = .ptr,
} };

fn paint(_: ?*anyopaque, subject: sdk.Host.Painter.Subject) bool {
    if (subject != .plugin_logo) return false;
    // `expand = .ratio` fits the logo to whatever rect the host reserved (see `Host.Painter`):
    // 32px on a plugin-store card, a much smaller row glyph in the settings tree.
    // `min_size_content` is only the size asked for when the host leaves it to us.
    _ = dvui.image(@src(), .{ .source = icon_source, .shrink = .ratio }, .{
        .expand = .ratio,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 32, .h = 32 },
    });
    return true;
}

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);
    try host.registerPainter(.{ .owner = &plugin, .draw = paint });
    if (has_lsp) Lsp.configure();
    try host.registerLanguageSupport(language_support);
    if (!has_lsp) return;
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId("zig", "restartLanguageServer"),
        .owner = &plugin,
        .title = "Zig: Restart Language Server",
        .run = cmdRestartLanguageServer,
    });
    // Recover from a wedged zls without quitting — lives under Edit next to Format Document.
    try host.registerMenuSection(.{
        .id = "zig.menu.edit_section",
        .parent_menu_id = "fizzy.menu.edit",
        .owner = &plugin,
        .draw = drawEditMenuSection,
    });
}

fn cmdRestartLanguageServer(_: *anyopaque) !void {
    Lsp.restart();
}

fn drawEditMenuSection(_: ?*anyopaque) !void {
    if (sdk.host().drawMenuItem("Restart Zig Language Server", sdk.Plugin.commandId("zig", "restartLanguageServer"))) {
        sdk.host().runCommand(sdk.Plugin.commandId("zig", "restartLanguageServer")) catch |err| {
            dvui.log.warn("zig: restartLanguageServer failed: {any}", .{err});
        };
    }
}

fn deinit(_: *anyopaque) void {
    if (has_lsp) Lsp.deinit();
}

comptime {
    sdk.Plugin.assertUtilityVTable(vtable);
}
