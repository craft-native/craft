//! Select a live desktop webview for a bridge reply.
//!
//! A reply made while serving a page belongs to that page. If its webview was
//! destroyed during a nested run loop, sending the reply to the latest window
//! would settle somebody else's call instead. Only native callers without a
//! sender context may use the platform's fallback webview.

const std = @import("std");

pub fn select(live_webviews: []const usize, sender: ?usize, fallback: ?usize) ?usize {
    const requested = sender orelse fallback orelse return null;
    if (requested == 0) return null;
    for (live_webviews) |webview| {
        if (webview == requested) return webview;
    }
    return null;
}

test "a page reply targets its own live webview" {
    const live = [_]usize{ 0x1000, 0x2000 };
    try std.testing.expectEqual(@as(?usize, 0x1000), select(&live, 0x1000, 0x2000));
}

test "a destroyed sender never falls through to another page" {
    const live = [_]usize{0x2000};
    try std.testing.expectEqual(@as(?usize, null), select(&live, 0x1000, 0x2000));
}

test "a native caller uses only a live fallback" {
    const live = [_]usize{ 0x1000, 0x2000 };
    try std.testing.expectEqual(@as(?usize, 0x2000), select(&live, null, 0x2000));
    try std.testing.expectEqual(@as(?usize, null), select(&live, null, 0x3000));
    try std.testing.expectEqual(@as(?usize, null), select(&live, null, null));
    try std.testing.expectEqual(@as(?usize, null), select(&live, null, 0));
}
