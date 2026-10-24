//! Test-only C transport. All drawing and presentation use Craft's public module.
const std = @import("std");
const builtin = @import("builtin");
const craft = @import("craft");
const graphics = craft.graphics;
const scene = graphics.scene;
const native = craft.vulkan_surface;
const allocator = std.heap.c_allocator;
const Context = struct { surface: native.Surface, canvas: graphics.Canvas, readback: []u32 };
var last_error: ?anyerror = null;
fn failed(err: anyerror) c_int {
    last_error = err;
    return 1;
}
export fn craft_vulkan_error() [*:0]const u8 {
    return if (last_error) |err| @errorName(err).ptr else "no error";
}
export fn craft_vulkan_create(display: ?*anyopaque, window: usize, width: u32, height: u32) ?*Context {
    last_error = null;
    const context = allocator.create(Context) catch |err| {
        _ = failed(err);
        return null;
    };
    const canvas = graphics.Canvas.init(allocator, width, height) catch |err| {
        allocator.destroy(context);
        _ = failed(err);
        return null;
    };
    const pixels = allocator.alloc(u32, @as(usize, width) * height) catch |err| {
        var owned = canvas;
        owned.deinit();
        allocator.destroy(context);
        _ = failed(err);
        return null;
    };
    const native_window: native.NativeWindow = if (builtin.os.tag == .windows) .{ .win32 = .{ .instance = display, .window = if (window == 0) null else @ptrFromInt(window) } } else .{ .xlib = .{ .display = display, .window = window } };
    const surface = native.Surface.init(native_window, .{ .width = width, .height = height }) catch |err| {
        allocator.free(pixels);
        var owned = canvas;
        owned.deinit();
        allocator.destroy(context);
        _ = failed(err);
        return null;
    };
    context.* = .{ .surface = surface, .canvas = canvas, .readback = pixels };
    return context;
}
export fn craft_vulkan_resize(context: *Context, width: u32, height: u32) c_int {
    var canvas = graphics.Canvas.init(allocator, width, height) catch |err| return failed(err);
    const pixels = allocator.alloc(u32, @as(usize, width) * height) catch |err| {
        canvas.deinit();
        return failed(err);
    };
    const metrics = context.surface.resize(width, height) catch |err| {
        canvas.deinit();
        allocator.free(pixels);
        return failed(err);
    };
    if (metrics.width != width or metrics.height != height) {
        canvas.deinit();
        allocator.free(pixels);
        return failed(error.NativeExtentMismatch);
    }
    context.canvas.deinit();
    allocator.free(context.readback);
    context.canvas = canvas;
    context.readback = pixels;
    return 0;
}
export fn craft_vulkan_draw(context: *Context, frame: u32, input_x: i32, input_y: i32) c_int {
    const width = context.canvas.width;
    const height = context.canvas.height;
    context.canvas.clear(graphics.Color.rgb(0, 0, 0));
    const atlas = [_]u8{ 224, 32, 64, 255, 32, 192, 96, 255, 32, 64, 224, 255, 208, 160, 32, 255 };
    const white = [_]u8{ 255, 255, 255, 255 };
    const glyphs = [_]scene.Glyph{.{ .codepoint = 'V', .source = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .advance = 2 }};
    const font: scene.BitmapFont = .{ .bitmap = .{ .width = 1, .height = 1, .pixels = &white }, .glyphs = &glyphs, .line_height = 2 };
    scene.drawFrame(&context.canvas, &.{
        .{ .sprite = .{ .bitmap = .{ .width = 2, .height = 2, .pixels = &atlas }, .source = .{ .x = 0, .y = 0, .width = 2, .height = 2 }, .transform = .{ .a = @as(f64, @floatFromInt(width)) / 2, .d = @as(f64, @floatFromInt(height)) / 2, .tx = @floatFromInt(frame % 4) } } },
        .{ .triangle = .{ .bitmap = .{ .width = 1, .height = 1, .pixels = &white }, .vertices = .{ .{ .x = 8, .y = 8, .u = 0, .v = 0 }, .{ .x = 16, .y = 8, .u = 1, .v = 0 }, .{ .x = 8, .y = 16, .u = 0, .v = 1 } } } },
        .{ .text = .{ .font = font, .text = "VV", .transform = .{ .a = 3, .d = 3, .tx = 20, .ty = 8 } } },
    }, .{}) catch |err| return failed(err);
    if (input_x >= 0 and input_y >= 0) context.canvas.drawRect(.{ .x = input_x, .y = input_y, .width = 4, .height = 4 }, graphics.Color.rgb(255, 255, 255));
    context.surface.present(context.canvas.pixels) catch |err| return failed(err);
    context.surface.readPixels(context.readback) catch |err| return failed(err);
    if (!std.mem.eql(u32, context.canvas.pixels, context.readback)) return failed(error.ActualGpuPixelsDiffer);
    return 0;
}
export fn craft_vulkan_suspend(context: *Context, suspended: c_int) c_int {
    context.surface.setSuspended(suspended != 0) catch |err| return failed(err);
    if (suspended != 0) {
        if (context.surface.present(context.canvas.pixels)) |_| return failed(error.PresentedWhileSuspended) else |err| if (err != error.Suspended) return failed(err);
    }
    return 0;
}
export fn craft_vulkan_pixels(context: *Context) [*]const u32 {
    return context.canvas.pixels.ptr;
}
export fn craft_vulkan_dispose(context: *Context) c_int {
    // Never free the context or its window while presentation still owns work.
    context.surface.deinit() catch |err| return failed(err);
    context.canvas.deinit();
    allocator.free(context.readback);
    allocator.destroy(context);
    return 0;
}
