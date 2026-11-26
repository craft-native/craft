//! Where a page lets the window be dragged (#587).
//!
//! The page marks elements `data-craft-drag`; the injected bridge measures
//! them, and the interactive elements inside them, and sends both lists here
//! whenever layout changes. A mouse-down monitor asks `hits` with the real
//! event's position, so the drag starts from the event itself. A drag begun
//! from JavaScript cannot do that: by the time the page's mousedown reaches
//! native, AppKit's current event is no longer that mouse-down.
//!
//! Coordinates are the webview's own, in points, origin top-left: what
//! `getBoundingClientRect` reports at page zoom 1.

const std = @import("std");

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

/// Enough for a titlebar, a toolbar and a sidebar header, with every button in them.
pub const max_drag = 32;
pub const max_no_drag = 128;
const capacity = 16;

const Entry = struct {
    webview: usize = 0,
    drag: [max_drag]Rect = undefined,
    drag_len: usize = 0,
    no_drag: [max_no_drag]Rect = undefined,
    no_drag_len: usize = 0,
};

var entries: [capacity]Entry = @splat(.{});

fn find(webview: usize) ?*Entry {
    for (&entries) |*entry| if (entry.webview == webview and webview != 0) return entry;
    return null;
}

/// Replace `webview`'s regions; an empty drag list forgets it. Drag regions
/// past `max_drag` are dropped. More than `max_no_drag` holes turns every drag
/// region off instead, because a hole that did not fit would be a button that
/// drags the window rather than being clicked.
pub fn set(webview: usize, drag: []const Rect, no_drag: []const Rect) error{TooManyWindows}!void {
    if (webview == 0) return;
    if (drag.len == 0) {
        forget(webview);
        return;
    }
    const entry = find(webview) orelse for (&entries) |*slot| {
        if (slot.webview == 0) break slot;
    } else return error.TooManyWindows;
    entry.webview = webview;
    entry.drag_len = @min(drag.len, max_drag);
    @memcpy(entry.drag[0..entry.drag_len], drag[0..entry.drag_len]);
    entry.no_drag_len = @min(no_drag.len, max_no_drag);
    @memcpy(entry.no_drag[0..entry.no_drag_len], no_drag[0..entry.no_drag_len]);
    // More holes than fit means some button would turn into a drag handle.
    // Keep none of the drag regions rather than swallow a click on it.
    if (no_drag.len > max_no_drag) entry.drag_len = 0;
}

pub fn forget(webview: usize) void {
    if (find(webview)) |entry| entry.* = .{};
}

/// Whether a mouse-down at (`x`, `y`) in `webview` should drag the window: inside
/// a drag region and outside every no-drag one.
pub fn hits(webview: usize, x: f64, y: f64) bool {
    const entry = find(webview) orelse return false;
    for (entry.no_drag[0..entry.no_drag_len]) |rect| if (rect.contains(x, y)) return false;
    for (entry.drag[0..entry.drag_len]) |rect| if (rect.contains(x, y)) return true;
    return false;
}

/// The page's message: `{"drag":[[x,y,w,h],…],"noDrag":[[x,y,w,h],…]}`.
pub fn setFromJson(allocator: std.mem.Allocator, webview: usize, json: []const u8) !void {
    const Message = struct { drag: []const [4]f64 = &.{}, noDrag: []const [4]f64 = &.{} };
    const parsed = std.json.parseFromSlice(Message, allocator, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidJSON;
    defer parsed.deinit();
    var drag: [max_drag]Rect = undefined;
    var no_drag: [max_no_drag + 1]Rect = undefined;
    const drag_len = @min(parsed.value.drag.len, max_drag);
    for (parsed.value.drag[0..drag_len], 0..) |r, i| drag[i] = try parseRect(r);
    const hole_len = @min(parsed.value.noDrag.len, max_no_drag + 1);
    for (parsed.value.noDrag[0..hole_len], 0..) |r, i| no_drag[i] = try parseRect(r);
    try set(webview, drag[0..drag_len], no_drag[0..hole_len]);
}

fn parseRect(r: [4]f64) error{InvalidParameter}!Rect {
    for (r) |v| if (!std.math.isFinite(v)) return error.InvalidParameter;
    if (r[2] < 0 or r[3] < 0) return error.InvalidParameter;
    return .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] };
}

/// What a double-click in a drag region does, as the titlebar would: the
/// user's "Double-click a window's title bar to" setting.
pub const DoubleClick = enum { zoom, minimize, none };

pub fn doubleClickAction(setting: ?[]const u8) DoubleClick {
    const value = setting orelse return .zoom;
    if (std.ascii.eqlIgnoreCase(value, "Minimize")) return .minimize;
    if (std.ascii.eqlIgnoreCase(value, "None")) return .none;
    return .zoom;
}

const testing = std.testing;

test "a mouse-down drags only inside a drag region and outside its holes" {
    defer forget(0x10);
    try set(0x10, &.{.{ .x = 0, .y = 0, .w = 800, .h = 52 }}, &.{.{ .x = 700, .y = 10, .w = 80, .h = 32 }});
    try testing.expect(hits(0x10, 10, 10));
    try testing.expect(hits(0x10, 699.9, 30));
    try testing.expect(!hits(0x10, 720, 20)); // the button
    try testing.expect(!hits(0x10, 10, 52)); // just below the header
    try testing.expect(!hits(0x11, 10, 10)); // another webview
}

test "an empty drag list forgets the webview" {
    try set(0x20, &.{.{ .x = 0, .y = 0, .w = 10, .h = 10 }}, &.{});
    try testing.expect(hits(0x20, 1, 1));
    try set(0x20, &.{}, &.{});
    try testing.expect(!hits(0x20, 1, 1));
}

test "more holes than fit refuses every drag rather than swallow a button" {
    defer forget(0x30);
    var holes: [max_no_drag + 1]Rect = undefined;
    for (&holes, 0..) |*h, i| h.* = .{ .x = @floatFromInt(i * 2), .y = 0, .w = 1, .h = 1 };
    try set(0x30, &.{.{ .x = 0, .y = 0, .w = 1000, .h = 100 }}, &holes);
    try testing.expect(!hits(0x30, 500, 50));
}

test "the page's message is parsed and bad numbers are refused" {
    defer forget(0x40);
    try setFromJson(testing.allocator, 0x40, "{\"drag\":[[0,0,400,40]],\"noDrag\":[[350,5,40,30]]}");
    try testing.expect(hits(0x40, 100, 20));
    try testing.expect(!hits(0x40, 360, 20));
    try testing.expectError(error.InvalidParameter, setFromJson(testing.allocator, 0x40, "{\"drag\":[[0,0,-1,40]]}"));
    try testing.expectError(error.InvalidJSON, setFromJson(testing.allocator, 0x40, "{\"drag\":"));
}

test "a double-click follows the titlebar setting, zooming by default" {
    try testing.expectEqual(DoubleClick.zoom, doubleClickAction(null));
    try testing.expectEqual(DoubleClick.zoom, doubleClickAction("Maximize"));
    try testing.expectEqual(DoubleClick.minimize, doubleClickAction("Minimize"));
    try testing.expectEqual(DoubleClick.none, doubleClickAction("None"));
}
