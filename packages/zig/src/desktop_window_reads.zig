//! Results for read-only desktop window actions. The native caller supplies
//! live OS values; this module preserves the SDK's JSON reply shapes.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");
const desktop_window_registry = @import("desktop_window_registry.zig");

pub fn string(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    const text = value orelse return allocator.dupe(u8, "null");
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &json, text);
    try json.append(allocator, '"');
    return json.toOwnedSlice(allocator);
}

pub fn geometry(allocator: std.mem.Allocator, action: []const u8, bounds: desktop_window_registry.Geometry) ![]u8 {
    if (std.mem.eql(u8, action, "getSize"))
        return std.fmt.allocPrint(allocator, "{{\"width\":{d},\"height\":{d}}}", .{ bounds.width, bounds.height });
    if (std.mem.eql(u8, action, "getPosition"))
        return std.fmt.allocPrint(allocator, "{{\"x\":{d},\"y\":{d}}}", .{ bounds.x, bounds.y });
    if (std.mem.eql(u8, action, "getBounds"))
        return std.fmt.allocPrint(allocator, "{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ bounds.x, bounds.y, bounds.width, bounds.height });
    return error.UnknownAction;
}

pub const State = struct {
    is_visible: bool,
    is_minimized: bool,
    is_maximized: bool,
    is_fullscreen: bool,
    is_focused: bool,
    is_always_on_top: bool,
    bounds: desktop_window_registry.Geometry,
};

pub fn state(allocator: std.mem.Allocator, value: State) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"isVisible\":{},\"isMinimized\":{},\"isMaximized\":{},\"isFullscreen\":{},\"isFocused\":{},\"isAlwaysOnTop\":{},\"bounds\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}}}",
        .{ value.is_visible, value.is_minimized, value.is_maximized, value.is_fullscreen, value.is_focused, value.is_always_on_top, value.bounds.x, value.bounds.y, value.bounds.width, value.bounds.height },
    );
}

/// Never return a name for an OS window that has already been destroyed or
/// belongs to another process. Every page calls its own window `main`.
pub fn focusedName(
    live: *const desktop_window_registry.Registry,
    sender: usize,
    focused: usize,
    named: ?[]const u8,
) ?[]const u8 {
    if (live.byWindow(focused) == null) return null;
    if (sender == focused) return "main";
    return named;
}

test "read results preserve SDK shapes and escape names" {
    const allocator = std.testing.allocator;
    const name = try string(allocator, "set\"tings");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("\"set\\\"tings\"", name);
    const absent = try string(allocator, null);
    defer allocator.free(absent);
    try std.testing.expectEqualStrings("null", absent);
    const bounds: desktop_window_registry.Geometry = .{ .x = -20, .y = 30, .width = 800, .height = 600 };
    const size = try geometry(allocator, "getSize", bounds);
    defer allocator.free(size);
    try std.testing.expectEqualStrings("{\"width\":800,\"height\":600}", size);
    const position = try geometry(allocator, "getPosition", bounds);
    defer allocator.free(position);
    try std.testing.expectEqualStrings("{\"x\":-20,\"y\":30}", position);
    const full = try geometry(allocator, "getBounds", bounds);
    defer allocator.free(full);
    try std.testing.expectEqualStrings("{\"x\":-20,\"y\":30,\"width\":800,\"height\":600}", full);

    const window_state = try state(allocator, .{
        .is_visible = true,
        .is_minimized = false,
        .is_maximized = false,
        .is_fullscreen = true,
        .is_focused = true,
        .is_always_on_top = false,
        .bounds = bounds,
    });
    defer allocator.free(window_state);
    try std.testing.expectEqualStrings("{\"isVisible\":true,\"isMinimized\":false,\"isMaximized\":false,\"isFullscreen\":true,\"isFocused\":true,\"isAlwaysOnTop\":false,\"bounds\":{\"x\":-20,\"y\":30,\"width\":800,\"height\":600}}", window_state);
}

test "focused name is scoped to a live window and the sender alias" {
    var live: desktop_window_registry.Registry = .{};
    _ = live.remember(0x1000, 0x1001);
    _ = live.remember(0x2000, 0x2001);
    try std.testing.expectEqualStrings("main", focusedName(&live, 0x1000, 0x1000, null).?);
    try std.testing.expectEqualStrings("settings", focusedName(&live, 0x1000, 0x2000, "settings").?);
    try std.testing.expect(focusedName(&live, 0x1000, 0x3000, "other") == null);
    _ = live.forgetWindow(0x2000);
    try std.testing.expect(focusedName(&live, 0x1000, 0x2000, "settings") == null);
}
