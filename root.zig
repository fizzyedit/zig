const std = @import("std");
const sdk = @import("sdk");

// Without this, `dvui.log.warn`/etc. calls anywhere in this dylib (including inside the
// shared `core.lsp.Client` this plugin's `Lsp.zig` drives) are invisible outside the dylib's
// own private std.log binding — see `sdk.dylib.stdOptions`'s doc comment.
pub const std_options: std.Options = sdk.dylib.stdOptions(@import("src/plugin.zig"));

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
