//! Zig/ZON tree-sitter highlighting for the text editor.
const std = @import("std");
const zig = @import("../zig.zig");
const dvui = zig.dvui;
const sdk = zig.sdk;

const zig_queries = @embedFile("../queries/zig.scm");

const TreeSitter = if (dvui.useTreeSitter) struct {
    extern fn tree_sitter_zig() callconv(.c) *anyopaque;
} else struct {};

fn rgb(r: u8, g: u8, b: u8) dvui.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn hi(name: []const u8, color: dvui.Color) sdk.HighlightStyle {
    return .{ .name = name, .opts = .{ .color_text = color } };
}

const ident_gold = rgb(0xd5, 0xc6, 0x83);
const keyword_brown = rgb(0x87, 0x65, 0x60);
const keyword_modifier_brown = rgb(0x61, 0x53, 0x53);
const type_orange = rgb(0xce, 0xa4, 0x7f);
const type_color = rgb(199, 140, 122);
const function_green = rgb(0x4d, 0xa5, 0x86);

const zig_highlights = [_]sdk.HighlightStyle{
    hi("comment", rgb(0x57, 0x5b, 0x65)),
    hi("keyword", keyword_brown),
    hi("keyword.type", keyword_brown),
    hi("keyword.function", keyword_brown),
    hi("keyword.modifier", keyword_modifier_brown),
    hi("keyword.conditional", type_orange),
    hi("keyword.repeat", type_orange),
    hi("keyword.return", type_orange),
    hi("keyword.operator", type_orange),
    hi("keyword.import", keyword_brown),
    hi("keyword.exception", type_orange),
    hi("keyword.coroutine", type_orange),
    hi("variable", ident_gold),
    hi("variable.parameter", ident_gold),
    hi("variable.member", ident_gold),
    hi("variable.builtin", rgb(0x6a, 0x66, 0x56)),
    hi("module", ident_gold),
    hi("type", type_color),
    hi("type.builtin", type_color),
    hi("function", function_green),
    hi("function.call", function_green),
    hi("function.builtin", function_green),
    hi("constant", rgb(0x60, 0x74, 0xd2)),
    hi("constant.builtin", rgb(0x53, 0x5c, 0x90)),
    hi("string", rgb(0x60, 0xc0, 0xd2)),
    hi("string.escape", rgb(0x58, 0x8e, 0x9a)),
    hi("character", rgb(0x60, 0xd2, 0xbe)),
    hi("number", rgb(0x60, 0x9a, 0xd2)),
    hi("number.float", rgb(0x60, 0x9a, 0xd2)),
    hi("boolean", rgb(0x53, 0x5c, 0x90)),
    hi("operator", rgb(0xb9, 0xb9, 0xb5)),
    hi("label", rgb(0xc8, 0xc8, 0xc8)),
    hi("punctuation", rgb(0x9c, 0x9d, 0x9d)),
};

pub fn treeSitterHighlight(_: *anyopaque, ext: []const u8) ?sdk.TreeSitterHighlight {
    if (!dvui.useTreeSitter) return null;
    if (!std.ascii.eqlIgnoreCase(ext, ".zig") and !std.ascii.eqlIgnoreCase(ext, ".zon")) return null;
    return .{
        .language = TreeSitter.tree_sitter_zig(),
        .queries = zig_queries,
        .highlights = &zig_highlights,
    };
}
