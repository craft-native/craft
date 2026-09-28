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
    /// Platform-specific control object (WebView2 controller on Windows).
    context: usize = 0,
    /// WebView2 subscription to remove before releasing a closed webview.
    message_token: ?i64 = null,
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

test "a window keeps its own platform control object" {
    var registry: Registry = .{};
    const first = registry.rememberWithContext(0x1000, 0x1001, 0x1002).?;
    const second = registry.rememberWithContext(0x2000, 0x2001, 0x2002).?;
    try std.testing.expectEqual(@as(usize, 0x1002), registry.byId(first).?.context);
    try std.testing.expectEqual(@as(usize, 0x2002), registry.byId(second).?.context);
    _ = registry.forgetWindow(0x1000);
    try std.testing.expectEqual(@as(usize, 0x2002), registry.byWindow(0x2000).?.context);
}
