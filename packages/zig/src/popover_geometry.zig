//! Where a menubar popover goes: under its status item, centred on it, and
//! kept on that item's screen.
//!
//! Pure, so the one placement rule is tested without a menu bar. The AppKit
//! side that measures the item and moves the window is `tray_popover.zig`.
//!
//! Coordinates are AppKit's: origin at the bottom left of the main screen,
//! y growing upwards. A second screen to the left has negative x.

const std = @import("std");

pub const Rect = struct { x: f64, y: f64, width: f64, height: f64 };
pub const Point = struct { x: f64, y: f64 };

/// Between the bottom of the menu bar and the popover's top edge. The system's
/// own status menus (Wi-Fi, Control Center) leave about this much.
pub const gap: f64 = 6;

/// The least room kept between the popover and either side of the screen.
pub const margin: f64 = 8;

/// The popover's origin (its bottom-left corner).
///
/// `item` is the status item's frame on screen and `visible` that screen's
/// `visibleFrame`, the part below the menu bar and beside the Dock. Centred on
/// the item, as NSPopover places itself, then pulled back inside the screen:
/// items sit at the right of the menu bar, so a wide popover centred on one
/// usually hangs off the edge.
pub fn anchor(item: Rect, visible: Rect, width: f64, height: f64) Point {
    const min_x = visible.x + margin;
    const max_x = visible.x + visible.width - margin - width;

    var x = item.x + item.width / 2 - width / 2;
    if (x > max_x) x = max_x;
    // Last, so a popover wider than the screen keeps its left edge - and the
    // start of every line of its content - visible.
    if (x < min_x) x = min_x;

    // The item's bottom edge is the menu bar's. With the menu bar set to hide,
    // the visible frame reaches the top of the screen and the item may not be
    // on screen at all, so take whichever is lower.
    const top = @min(item.y, visible.y + visible.height) - gap;

    return .{ .x = @round(x), .y = @round(top - height) };
}

const testing = std.testing;

// A 1512x982 laptop screen: 37pt menu bar, no Dock at the bottom.
const laptop = Rect{ .x = 0, .y = 0, .width = 1512, .height = 945 };

test "centres under an item with room on both sides" {
    const item = Rect{ .x = 700, .y = 945, .width = 30, .height = 37 };
    const origin = anchor(item, laptop, 360, 500);
    try testing.expectEqual(@as(f64, 715 - 180), origin.x);
    try testing.expectEqual(@as(f64, 945 - gap - 500), origin.y);
}

test "an item near the right edge pulls the popover back on screen" {
    const item = Rect{ .x = 1400, .y = 945, .width = 30, .height = 37 };
    const origin = anchor(item, laptop, 360, 500);
    try testing.expectEqual(@as(f64, 1512 - margin - 360), origin.x);
}

test "an item near the left edge keeps the margin" {
    const item = Rect{ .x = 2, .y = 945, .width = 30, .height = 37 };
    try testing.expectEqual(margin, anchor(item, laptop, 360, 500).x);
}

test "places on the item's own screen, which need not start at zero" {
    // A second display to the left of the main one.
    const left = Rect{ .x = -1920, .y = 0, .width = 1920, .height = 1055 };
    const item = Rect{ .x = -300, .y = 1055, .width = 28, .height = 25 };
    const origin = anchor(item, left, 360, 500);
    try testing.expectEqual(@as(f64, -286 - 180), origin.x);
    try testing.expectEqual(@as(f64, 1055 - gap - 500), origin.y);
}

test "a popover wider than the screen keeps its left edge visible" {
    const narrow = Rect{ .x = 0, .y = 0, .width = 300, .height = 600 };
    const item = Rect{ .x = 250, .y = 600, .width = 30, .height = 24 };
    try testing.expectEqual(margin, anchor(item, narrow, 400, 200).x);
}

test "a hidden menu bar puts the popover under the top of the screen" {
    const full = Rect{ .x = 0, .y = 0, .width = 1512, .height = 982 };
    // The item's window is parked above the screen while the bar is hidden.
    const item = Rect{ .x = 700, .y = 1000, .width = 30, .height = 37 };
    try testing.expectEqual(@as(f64, 982 - gap - 500), anchor(item, full, 360, 500).y);
}

test "lands on whole points, so the border does not blur" {
    const item = Rect{ .x = 700.5, .y = 945, .width = 31, .height = 37 };
    const origin = anchor(item, laptop, 361, 500);
    try testing.expectEqual(@round(origin.x), origin.x);
}
