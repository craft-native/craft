//! Platform-neutral live desktop window handles.
//!
//! A native close can arrive without going through `Window.close` (the titlebar
//! close button, for example). The platform callback must forget that window
//! before any later bridge reply or resize selects its destroyed webview.

const std = @import("std");
const desktop_window_controls = @import("desktop_window_controls.zig");

pub const capacity = 32;
pub const Geometry = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const GeometryChange = struct {
    moved: bool,
    resized: bool,
};

pub const StateChange = struct {
    minimized: ?bool,
    fullscreen: ?bool,
};

pub const Entry = struct {
    id: u32,
    window: usize,
    webview: usize,
    /// Platform-specific control object (WebView2 controller on Windows).
    context: usize = 0,
    /// WebView2 subscription to remove before releasing a closed webview.
    message_token: ?i64 = null,
    geometry: ?Geometry = null,
    minimized: bool = false,
    fullscreen: bool = false,
    limits: desktop_window_controls.Limits = .{},
    /// Windows restores these when leaving borderless fullscreen.
    windowed_geometry: ?Geometry = null,
    windowed_style: ?isize = null,
};

pub const Registry = struct {
    entries: [capacity]?Entry = @splat(null),
    next_id: u32 = 1,

    pub fn remember(self: *Registry, window: usize, webview: usize) ?u32 {
        return self.rememberWithContext(window, webview, 0);
    }

    pub fn rememberWithContext(self: *Registry, window: usize, webview: usize, context: usize) ?u32 {
        if (window == 0 or webview == 0 or self.byWindow(window) != null or self.byWebview(webview) != null or self.next_id == 0) return null;
        for (&self.entries) |*slot| {
            if (slot.* == null) {
                const id = self.next_id;
                // Exhaust rather than reuse an id that a caller may still hold.
                self.next_id = if (id == std.math.maxInt(u32)) 0 else id + 1;
                slot.* = .{ .id = id, .window = window, .webview = webview, .context = context };
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

    pub fn byWebview(self: *const Registry, webview: usize) ?Entry {
        if (webview == 0) return null;
        for (self.entries) |slot| {
            if (slot) |entry| {
                if (entry.webview == webview) return entry;
            }
        }
        return null;
    }

    pub fn setMessageToken(self: *Registry, window: usize, token: i64) bool {
        if (window == 0) return false;
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.window == window) {
                    entry.message_token = token;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn setLimits(self: *Registry, window: usize, limits: desktop_window_controls.Limits) bool {
        if (window == 0) return false;
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.window == window) {
                    entry.limits = limits;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn setWindowedState(self: *Registry, window: usize, geometry: ?Geometry, style: ?isize) bool {
        if (window == 0) return false;
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.window == window) {
                    entry.windowed_geometry = geometry;
                    entry.windowed_style = style;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn observeGeometry(self: *Registry, window: usize, next: Geometry) ?GeometryChange {
        if (window == 0) return null;
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.window == window) {
                    const previous = entry.geometry;
                    entry.geometry = next;
                    if (previous) |old| return .{
                        .moved = old.x != next.x or old.y != next.y,
                        .resized = old.width != next.width or old.height != next.height,
                    };
                    return .{ .moved = false, .resized = false };
                }
            }
        }
        return null;
    }

    pub fn observeState(self: *Registry, window: usize, minimized: bool, fullscreen: bool) ?StateChange {
        if (window == 0) return null;
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.window == window) {
                    const change: StateChange = .{
                        .minimized = if (entry.minimized != minimized) minimized else null,
                        .fullscreen = if (entry.fullscreen != fullscreen) fullscreen else null,
                    };
                    entry.minimized = minimized;
                    entry.fullscreen = fullscreen;
                    return change;
                }
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
    try std.testing.expect(registry.remember(0x2000, 0x1001) == null);
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

test "a web message subscription belongs only to its live window" {
    var registry: Registry = .{};
    _ = registry.remember(0x1000, 0x1001);
    _ = registry.remember(0x2000, 0x2001);
    try std.testing.expect(registry.setMessageToken(0x1000, 42));
    try std.testing.expect(!registry.setMessageToken(0x3000, 99));
    try std.testing.expectEqual(@as(?i64, 42), registry.byWebview(0x1001).?.message_token);
    try std.testing.expect(registry.byWebview(0x2001).?.message_token == null);
    try std.testing.expectEqual(@as(?i64, 42), registry.forgetWindow(0x1000).?.message_token);
    try std.testing.expect(registry.byWebview(0x1001) == null);
}

test "portable controls belong to one live window and reset on reopen" {
    var registry: Registry = .{};
    _ = registry.remember(0x1000, 0x1001);
    _ = registry.remember(0x2000, 0x2001);
    const limits: desktop_window_controls.Limits = .{ .minimum = .{ .width = 320, .height = 240 } };
    try std.testing.expect(registry.setLimits(0x1000, limits));
    try std.testing.expect(registry.setWindowedState(0x1000, .{ .x = 10, .y = 20, .width = 800, .height = 600 }, 0x55));
    try std.testing.expect(registry.byWindow(0x2000).?.limits.minimum == null);
    try std.testing.expect(registry.byWindow(0x2000).?.windowed_geometry == null);
    try std.testing.expectEqual(@as(u32, 320), registry.byWindow(0x1000).?.limits.minimum.?.width);
    _ = registry.forgetWindow(0x1000);
    try std.testing.expect(!registry.setLimits(0x1000, limits));
    _ = registry.remember(0x1000, 0x3001);
    try std.testing.expect(registry.byWindow(0x1000).?.limits.minimum == null);
    try std.testing.expect(registry.byWindow(0x1000).?.windowed_style == null);
}

test "geometry changes belong to one live window and reset on reopen" {
    var registry: Registry = .{};
    _ = registry.remember(0x1000, 0x1001);
    _ = registry.remember(0x2000, 0x2001);
    const initial: Geometry = .{ .x = 10, .y = 20, .width = 800, .height = 600 };
    const first = registry.observeGeometry(0x1000, initial).?;
    try std.testing.expect(!first.moved and !first.resized);
    const changed = registry.observeGeometry(0x1000, .{ .x = 30, .y = 20, .width = 900, .height = 600 }).?;
    try std.testing.expect(changed.moved and changed.resized);
    try std.testing.expect(registry.byWindow(0x2000).?.geometry == null);
    _ = registry.forgetWindow(0x1000);
    try std.testing.expect(registry.observeGeometry(0x1000, initial) == null);
    _ = registry.remember(0x1000, 0x3001);
    try std.testing.expect(registry.byWindow(0x1000).?.geometry == null);
}

test "minimize and fullscreen transitions do not leak across windows" {
    var registry: Registry = .{};
    _ = registry.remember(0x1000, 0x1001);
    _ = registry.remember(0x2000, 0x2001);
    const minimized = registry.observeState(0x1000, true, false).?;
    try std.testing.expectEqual(@as(?bool, true), minimized.minimized);
    try std.testing.expect(minimized.fullscreen == null);
    const same = registry.observeState(0x1000, true, false).?;
    try std.testing.expect(same.minimized == null and same.fullscreen == null);
    const restored = registry.observeState(0x1000, false, true).?;
    try std.testing.expectEqual(@as(?bool, false), restored.minimized);
    try std.testing.expectEqual(@as(?bool, true), restored.fullscreen);
    try std.testing.expect(!registry.byWindow(0x2000).?.minimized);
    try std.testing.expect(!registry.byWindow(0x2000).?.fullscreen);
}

test "a window keeps its own platform control object" {
    var registry: Registry = .{};
    const first = registry.rememberWithContext(0x1000, 0x1001, 0x1002).?;
    const second = registry.rememberWithContext(0x2000, 0x2001, 0x2002).?;
    try std.testing.expectEqual(@as(usize, 0x1002), registry.byId(first).?.context);
    try std.testing.expectEqual(@as(usize, 0x2002), registry.byId(second).?.context);
    _ = registry.forgetWindow(0x1000);
    try std.testing.expectEqual(@as(usize, 0x2002), registry.byWindow(0x2000).?.context);
}

test "a stale event subscription id cannot select a reopened window" {
    var registry: Registry = .{};
    const old_id = registry.remember(0x1000, 0x1001).?;
    _ = registry.forgetWindow(0x1000);
    const reopened_id = registry.remember(0x1000, 0x2001).?;
    try std.testing.expect(old_id != reopened_id);
    try std.testing.expect(registry.byId(old_id) == null);
    try std.testing.expectEqual(@as(usize, 0x2001), registry.byId(reopened_id).?.webview);
}
