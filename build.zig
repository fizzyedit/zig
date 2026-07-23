const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{
        .target = target,
        .optimize = optimize,
    });
    fizzy.plugin.install(b, plugin.lib, .{});
}
