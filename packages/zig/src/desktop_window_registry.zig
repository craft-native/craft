//! Platform-neutral live desktop window handles.
//!
//! A native close can arrive without going through `Window.close` (the titlebar
//! close button, for example). The platform callback must forget that window
//! before any later bridge reply or resize selects its destroyed webview.

const std = @import("std");

pub const capacity = 32;
pub const Entry = struct {
    id: u32,
    window: usize,
    webview: usize,
};

pub const Registry = struct {
    entries: [capacity]?Entry = @splat(null),
    next_id: u32 = 1,

    pub fn remember(self: *Registry, window: usize, webview: usize) ?u32 {
        if (window == 0 or webview == 0 or self.byWindow(window) != null or self.next_id == 0) return null;
        for (&self.entries) |*slot| {
            if (slot.* == null) {
                const id = self.next_id;
                // Exhaust rather than reuse an id that a caller may still hold.
                self.next_id = if (id == std.math.maxInt(u32)) 0 else id + 1;
                slot.* = .{ .id = id, .window = window, .webview = webview };
                return id;
            }
        }
        return null;
    }

    pub fn byId(self: *const Registry, id: u32) ?Entry {
        for (self.entries) |slot| {
            if (slot) |entry| {
                if (entry.id == id) return entry;
            }
        }
        return null;
    }

    pub fn byWindow(self: *const Registry, window: usize) ?Entry {
        if (window == 0) return null;
        for (self.entries) |slot| {
            if (slot) |entry| {
                if (entry.window == window) return entry;
            }
        }
        return null;
    }

    pub fn latest(self: *const Registry) ?Entry {
        var result: ?Entry = null;
        for (self.entries) |slot| {
            if (slot) |entry| {
                if (result == null or entry.id > result.?.id) result = entry;
            }
        }
        return result;
    }

    pub fn forgetWindow(self: *Registry, window: usize) ?Entry {
        if (window == 0) return null;
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (entry.window == window) {
                    slot.* = null;
                    return entry;
                }
            }
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        var total: usize = 0;
        for (self.entries) |slot| {
            if (slot != null) total += 1;
        }
        return total;
    }

    pub fn liveWebviews(self: *const Registry, out: *[capacity]usize) []const usize {
        var total: usize = 0;
        for (self.entries) |slot| {
            if (slot) |entry| {
                out[total] = entry.webview;
                total += 1;
            }
        }
        return out[0..total];
    }
};

test "closing one window retains the other and reopen gets a new identity" {
    var registry: Registry = .{};
    const first = registry.remember(0x1000, 0x1001).?;
    const second = registry.remember(0x2000, 0x2001).?;
    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expectEqual(first, registry.forgetWindow(0x1000).?.id);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqual(second, registry.latest().?.id);
    try std.testing.expect(registry.byId(first) == null);

    const reopened = registry.remember(0x3000, 0x3001).?;
    try std.testing.expect(reopened != first and reopened != second);
    try std.testing.expectEqual(reopened, registry.latest().?.id);
    try std.testing.expectEqual(@as(usize, 2), registry.count());
}

test "invalid and duplicate native handles never occupy a slot" {
    var registry: Registry = .{};
    try std.testing.expect(registry.remember(0, 0x1001) == null);
    try std.testing.expect(registry.remember(0x1000, 0) == null);
    try std.testing.expect(registry.remember(0x1000, 0x1001) != null);
    try std.testing.expect(registry.remember(0x1000, 0x2001) == null);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.forgetWindow(0x2000) == null);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "a full registry rejects creation without displacing a live window" {
    var registry: Registry = .{};
    for (0..capacity) |i| {
        try std.testing.expect(registry.remember(i + 1, i + 100) != null);
    }
    try std.testing.expect(registry.remember(0x9000, 0x9001) == null);
    try std.testing.expectEqual(@as(usize, capacity), registry.count());
    try std.testing.expect(registry.byWindow(1) != null);
}

test "reply candidates contain only live webviews" {
    var registry: Registry = .{};
    _ = registry.remember(0x1000, 0x1001);
    _ = registry.remember(0x2000, 0x2001);
    _ = registry.forgetWindow(0x1000);
    var handles: [capacity]usize = undefined;
    try std.testing.expectEqualSlices(usize, &.{0x2001}, registry.liveWebviews(&handles));
    _ = registry.forgetWindow(0x2000);
    try std.testing.expectEqual(@as(usize, 0), registry.liveWebviews(&handles).len);
}
