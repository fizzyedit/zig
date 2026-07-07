const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = fizzy.plugin.create(b, .{
        .name = "zig",
        .version = @import("build.zig.zon").version,
        .target = target,
        .optimize = optimize,
    });
    fizzy.plugin.install(b, lib, .{});
}
