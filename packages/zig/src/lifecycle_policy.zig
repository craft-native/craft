//! Whether closing the last window should quit the app.
//!
//! With no `NSApplicationDelegate`, AppKit answers this NO, and craft never
//! installed one: closing the last window left a process running with no
//! window, no Dock response, and no way to get either back. Force-quit was the
//! only exit.
//!
//! YES is right for an ordinary windowed app and wrong for the apps that exist
//! precisely to outlive their window — a menubar app, or anything with a tray
//! icon. Those close their window and carry on, which is the feature.
//!
//! So the rule has to be derived rather than fixed, and the derivation lives
//! here, once, instead of as a boolean expression at the call site that
//! nothing checks.

const std = @import("std");

/// What the app looks like, as far as this decision is concerned.
pub const Shape = struct {
    /// A status-bar item: the app has somewhere to live without a window.
    has_tray: bool = false,
    /// No window at all, only a menubar item.
    menubar_only: bool = false,
    /// `--keep-running` or `keepRunning` in the manifest. Null means the app
    /// did not say, and the shape decides.
    explicit_keep_running: ?bool = null,
};

/// True when the app should quit once its last window closes.
pub fn quitOnLastWindowClosed(shape: Shape) bool {
    // An explicit answer is an answer. A tray app that wants to quit with its
    // window is unusual but not wrong, and second-guessing it here would make
    // the flag a lie for exactly the apps most likely to set it.
    if (shape.explicit_keep_running) |keep| return !keep;

    // Anything with a place to live without a window keeps living.
    return !(shape.has_tray or shape.menubar_only);
}

const testing = std.testing;

test "an ordinary windowed app quits with its window" {
    // The bug this fixes: before, this returned NO by AppKit default and the
    // process was stranded.
    try testing.expect(quitOnLastWindowClosed(.{}));
}

test "an app with a tray icon outlives its window" {
    try testing.expect(!quitOnLastWindowClosed(.{ .has_tray = true }));
}

test "a menubar-only app outlives its window" {
    try testing.expect(!quitOnLastWindowClosed(.{ .menubar_only = true }));
    // `--menubar-only` implies a tray in the CLI; neither alone should change
    // the answer, and together they must not cancel out.
    try testing.expect(!quitOnLastWindowClosed(.{ .menubar_only = true, .has_tray = true }));
}

test "asking to keep running overrides the shape" {
    try testing.expect(!quitOnLastWindowClosed(.{ .explicit_keep_running = true }));
}

test "asking to quit overrides the shape too" {
    // A tray app that genuinely wants to go away with its window. Unusual, but
    // the flag has to mean what it says or it is worse than not having it.
    try testing.expect(quitOnLastWindowClosed(.{
        .has_tray = true,
        .explicit_keep_running = false,
    }));
    try testing.expect(quitOnLastWindowClosed(.{
        .menubar_only = true,
        .has_tray = true,
        .explicit_keep_running = false,
    }));
}

test "every shape has an answer" {
    // Exhaustive over the whole input space, so no combination is left to
    // whatever the last `if` happened to fall through to.
    for ([_]bool{ false, true }) |tray| {
        for ([_]bool{ false, true }) |menubar| {
            for ([_]?bool{ null, false, true }) |explicit| {
                const shape: Shape = .{
                    .has_tray = tray,
                    .menubar_only = menubar,
                    .explicit_keep_running = explicit,
                };
                const expected = if (explicit) |keep| !keep else !(tray or menubar);
                try testing.expectEqual(expected, quitOnLastWindowClosed(shape));
            }
        }
    }
}
