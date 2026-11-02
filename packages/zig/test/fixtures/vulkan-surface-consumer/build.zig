const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const craft = b.dependency("craft", .{ .target = target, .optimize = optimize, .@"js-runtime" = false, .@"desktop-host" = false });
    const fixture = b.addLibrary(.{ .name = "vulkan-surface-fixture", .linkage = .static, .root_module = b.createModule(.{
        .root_source_file = b.path("src/fixture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = if (target.result.abi == .android) true else null,
        .imports = &.{.{ .name = "craft", .module = craft.module("craft") }},
    }) });
    b.step("compile-library", "Compile the public native Vulkan C transport").dependOn(&fixture.step);
    if (target.result.abi == .android) {
        // Android supplies its real SurfaceView through the authored JNI host.
        const libc = b.option([]const u8, "android-libc", "NDK libc installation file for the Android fixture") orelse {
            b.getInstallStep().dependOn(&b.addFail("Android native fixture requires -Dandroid-libc=/absolute/path/to/ndk-libc.conf").step);
            return;
        };
        fixture.setLibCFile(.{ .cwd_relative = libc });
        fixture.bundle_compiler_rt = true;
        b.installArtifact(fixture);
        return;
    }
    const host = b.addExecutable(.{
        .name = "vulkan-surface-consumer",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Win32 uses native clocks and waits; only the Xlib host uses libc++.
            .link_libcpp = target.result.os.tag != .windows,
        }),
    });
    host.root_module.addCSourceFile(.{ .file = b.path(if (target.result.os.tag == .windows) "src/host-win32.cpp" else "src/host.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    host.root_module.linkLibrary(fixture);
    if (target.result.os.tag == .windows) {
        host.root_module.linkSystemLibrary("user32", .{});
        host.root_module.linkSystemLibrary("gdi32", .{});
    } else {
        host.root_module.linkSystemLibrary("X11", .{});
        host.root_module.linkSystemLibrary("Xtst", .{});
        host.root_module.linkSystemLibrary("dl", .{});
    }
    b.installArtifact(host);
}
