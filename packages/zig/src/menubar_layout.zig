//! Geometry policy independent of AppKit, including secondary-display origins.
const std = @import("std");

/// Growing toward the left must leave the divider's trailing edge in place.
/// The app's tray can be on either side, so it cannot anchor the hidden group.
pub fn markerEdgeDisplaced(expected_edge: f64, marker_x: f64, marker_width: f64) bool {
    if (!std.math.isFinite(marker_x) or !std.math.isFinite(marker_width) or !std.math.isFinite(expected_edge) or marker_width <= 0) return true;
    // macOS 27 can insert its overflow control and padding while keeping all
    // items on the visible side fixed. The observed divider shift is 56 pt;
    // allow two compact control slots, but reject a move into system overflow.
    return @abs(marker_x + marker_width - expected_edge) > 80;
}

test "native overflow releases the reserved width instead of blanking app menus" {
    try std.testing.expect(!markerEdgeDisplaced(967, 546, 421));
    try std.testing.expect(markerEdgeDisplaced(967, 222, 421));
}

test "moving the whole group across displays preserves its anchor" {
    try std.testing.expect(!markerEdgeDisplaced(-545, -966, 421));
    try std.testing.expect(!markerEdgeDisplaced(2469, 2048, 421));
    try std.testing.expect(markerEdgeDisplaced(2469, 2180, 421));
}

test "invalid or removed geometry cannot confirm a collapse" {
    try std.testing.expect(markerEdgeDisplaced(0, 0, 0));
    try std.testing.expect(markerEdgeDisplaced(40, std.math.nan(f64), 20));
}

test "collapse keeps the reveal arrow fixed regardless of the cup position" {
    const expanded_edge: f64 = 1000;
    try std.testing.expect(!markerEdgeDisplaced(expanded_edge, 980, 20));
    try std.testing.expect(!markerEdgeDisplaced(expanded_edge, 400, 600));
    try std.testing.expect(markerEdgeDisplaced(expanded_edge, 400, 400));
}

test "native overflow insertion does not undo a correctly hidden left group" {
    try std.testing.expect(!markerEdgeDisplaced(1039, 543, 440));
    try std.testing.expect(markerEdgeDisplaced(1039, 219, 440));
}
