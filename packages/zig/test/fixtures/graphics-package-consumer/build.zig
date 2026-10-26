const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const craft = b.dependency("craft", .{ .target = target, .optimize = optimize, .@"js-runtime" = false, .@"desktop-host" = false });
    const app = b.addExecutable(.{ .name = "graphics-consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "craft", .module = craft.module("craft") }},
    }) });
    b.step("compile", "Compile the documented Craft graphics consumer").dependOn(&app.step);
    const run = b.addRunArtifact(app);
    b.step("check", "Run the documented Craft graphics consumer").dependOn(&run.step);
}
