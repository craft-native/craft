//! Test-only C boundary for exercising the public Zig surface from UIKit.
const std = @import("std");
const metal = @import("metal_surface");
const allocator = std.heap.c_allocator;
const Harness = struct { surface: metal.Surface };
fn code(err: anyerror) c_int {
    return @intCast(@intFromError(err));
}

export fn craft_metal_fixture_open(view: ?*anyopaque, output: *?*Harness) c_int {
    output.* = null;
    // The simulator's GPU is the host's, shared with every other process on a
    // CI runner: a submitted blit has waited more than the default second
    // there (GPUTimeout, release 0.0.404). These tests check pixels, scale and
    // ownership, not GPU latency, so give completion the surface's largest
    // supported budget. A command that never completes still times out.
    var surface = metal.Surface.init(view, .{ .max_buffer_bytes = 16 * 1024 * 1024, .command_timeout_ms = 5000 }) catch |err| return code(err);
    const harness = allocator.create(Harness) catch |err| {
        surface.deinit() catch unreachable;
        return code(err);
    };
    harness.* = .{ .surface = surface };
    output.* = harness;
    return 0;
}
export fn craft_metal_fixture_frame(harness: *Harness, frame: u32) c_int {
    const metrics = harness.surface.resize() catch |err| return code(err);
    const count = @as(usize, metrics.width) * metrics.height;
    const expected = allocator.alloc(u32, count) catch |err| return code(err);
    defer allocator.free(expected);
    const actual = allocator.alloc(u32, count) catch |err| return code(err);
    defer allocator.free(actual);
    for (expected, 0..) |*pixel, index| {
        const x = index % metrics.width;
        const y = index / metrics.width;
        pixel.* = if (y < 8 and x == frame % metrics.width) 0xffffffff else if (x < metrics.width / 2 and y < metrics.height / 2) 0xffe02040 else if (x >= metrics.width / 2 and y < metrics.height / 2) 0xff20c060 else if (x < metrics.width / 2) 0xff2040e0 else 0xffd0a020;
    }
    harness.surface.present(expected) catch |err| return code(err);
    harness.surface.readPixels(actual) catch |err| return code(err);
    if (!std.mem.eql(u32, expected, actual)) return code(error.NativePixelMismatch);
    return 0;
}
export fn craft_metal_fixture_dimensions(harness: *Harness, width: *u32, height: *u32, scale: *f64) c_int {
    const metrics = harness.surface.resize() catch |err| return code(err);
    width.* = metrics.width;
    height.* = metrics.height;
    scale.* = metrics.scale;
    return 0;
}
export fn craft_metal_fixture_suspend(harness: *Harness, suspended: c_int) c_int {
    harness.surface.setSuspended(suspended != 0) catch |err| return code(err);
    return 0;
}
export fn craft_metal_fixture_close(harness: *Harness) c_int {
    harness.surface.deinit() catch |err| return code(err);
    allocator.destroy(harness);
    return 0;
}
export fn craft_metal_fixture_error(value: c_int) [*:0]const u8 {
    return if (value == 0) "ok" else @errorName(@errorFromInt(@as(u16, @intCast(value)))).ptr;
}
