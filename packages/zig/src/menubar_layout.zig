//! Geometry policy independent of AppKit, including secondary-display origins.
const std = @import("std");

pub const MAX_SPACERS = 16;
pub const SpacerPlan = struct { count: usize, width: f64 };

/// One long item is refused on the smaller display before it can hide icons
/// on a larger one. Individually modest items can overflow independently while
/// their combined reservation clears the prefix on every connected display.
pub fn planSpacers(shortest_width: f64, longest_width: f64, modern_overflow: bool) ?SpacerPlan {
    if (!std.math.isFinite(shortest_width) or !std.math.isFinite(longest_width) or shortest_width <= 0 or longest_width < shortest_width) return null;
    if (!modern_overflow) return .{ .count = 1, .width = longest_width };
    const width = shortest_width * 0.4;
    const count = @ceil(longest_width / width);
    if (count > MAX_SPACERS) return null;
    return .{ .count = @intFromFloat(count), .width = width };
}

test "spacer slices cover differently sized displays without one oversized item" {
    const single = planSpacers(1512, 1512, true).?;
    const dual = planSpacers(1512, 2560, true).?;
    try std.testing.expectEqual(@as(usize, 3), single.count);
    try std.testing.expectEqual(@as(usize, 5), dual.count);
    try std.testing.expect(dual.width < 1512.0 / 2);
    try std.testing.expect(@as(f64, @floatFromInt(dual.count)) * dual.width >= 2560);
    try std.testing.expect(planSpacers(0, 2560, true) == null);
    try std.testing.expect(planSpacers(1512, std.math.nan(f64), true) == null);
    try std.testing.expect(planSpacers(1512, 100_000, true) == null);
}

test "classic status bars retain one measured spacer" {
    const plan = planSpacers(800, 2560, false).?;
    try std.testing.expectEqual(@as(usize, 1), plan.count);
    try std.testing.expectEqual(@as(f64, 2560), plan.width);
}

/// macOS inserts up to 16 pt of status-item padding. A spacer may reserve
/// space only when immediately to the left of the compact reveal control.
pub fn spacerPrecedesControl(control_x: f64, spacer_x: f64, spacer_width: f64) bool {
    if (!std.math.isFinite(control_x) or !std.math.isFinite(spacer_x) or !std.math.isFinite(spacer_width) or spacer_width <= 0) return false;
    const gap = control_x - spacer_x - spacer_width;
    return gap >= -1 and gap <= 20;
}

test "only a spacer immediately left of the control can hide a group" {
    try std.testing.expect(spacerPrecedesControl(1285, 1249, 20));
    try std.testing.expect(spacerPrecedesControl(-400, -436, 20));
    try std.testing.expect(!spacerPrecedesControl(1285, 1285, 20));
    try std.testing.expect(!spacerPrecedesControl(1285, 1213, 20));
    try std.testing.expect(!spacerPrecedesControl(1285, std.math.nan(f64), 20));
}

/// Saved positions are requests: the system can clamp them or place a new
/// item on the other side of an existing control. Reserve space only after
/// observing adjacency, narrowing the requested position while still compact.
pub const SpacerPlacement = struct {
    low: f64 = 0,
    high: f64,
    position: f64,
    attempts: u8 = 0,

    pub const Result = union(enum) { ready, retry: f64, failed };

    pub fn init(position: f64, display_width: f64) SpacerPlacement {
        return .{ .high = display_width, .position = @max(0, @min(position, display_width)) };
    }

    pub fn observe(self: *SpacerPlacement, control_x: f64, spacer_x: f64, spacer_width: f64) Result {
        if (spacerPrecedesControl(control_x, spacer_x, spacer_width)) return .ready;
        if (!std.math.isFinite(control_x) or !std.math.isFinite(spacer_x) or spacer_width <= 0) return .failed;
        if (control_x - spacer_x - spacer_width < -1) self.low = self.position else self.high = self.position;
        self.attempts += 1;
        if (self.attempts >= 12 or self.high - self.low < 0.25) return .failed;
        self.position = (self.low + self.high) / 2;
        return .{ .retry = self.position };
    }
};

test "clamped native positions are retried while the spacer stays compact" {
    var placement = SpacerPlacement.init(2, 1512);
    try std.testing.expect(placement.observe(1249, 1285, 20) == .retry);
    try std.testing.expect(placement.position > 2);
    const too_far = placement.position;
    try std.testing.expect(placement.observe(1285, 935, 20) == .retry);
    try std.testing.expect(placement.position < too_far);
    try std.testing.expect(placement.observe(1285, 1249, 20) == .ready);
}

test "placement failure never confirms an overlapping or distant spacer" {
    var placement = SpacerPlacement.init(2, 1512);
    var result: SpacerPlacement.Result = .{ .retry = 2 };
    while (result == .retry) result = placement.observe(1285, 1285, 20);
    try std.testing.expect(result == .failed);
    try std.testing.expect(placement.observe(1285, std.math.nan(f64), 20) == .failed);
}

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
