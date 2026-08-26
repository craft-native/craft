//! Which windows craft opened.
//!
//! The Dock's reopen event arrives with no argument: AppKit hands over the
//! application and craft has to work out, from `[NSApp windows]`, which of them
//! are its own. That list also holds the offscreen windows AppKit keeps for
//! menus, tooltips and its own bookkeeping, and ordering one of those front
//! puts an empty frame on screen.
//!
//! ## Why this is a list and not a test
//!
//! The first version asked the window: is your content view a `WKWebView`?
//! That is true of craft's plain window and false of three others —
//! `--web-sidebar-material` installs a backdrop container, and both sidebar
//! constructors install a container or a split view controller. All three kept
//! their closed window alive, so reopen found them, skipped them, and left the
//! app activated with nothing on screen: exactly the dead end the reopen
//! handler exists to remove.
//!
//! Nothing caught it. It compiles, every test passes, and it fails only against
//! a real reopen event on a window style no test constructs.
//!
//! Recording the answer instead of inferring it fixes that, and it does
//! something else worth more: it turns an untestable property into a
//! checkable one. "Does this window look like ours?" can only be answered by
//! having the window. "Did every constructor register?" is a property of the
//! source, and `test/window_lifecycle_test.zig` checks it.

const std = @import("std");

/// An opaque window handle — `@intFromPtr(NSWindow)` at the call site. Kept
/// opaque so this module stays free of Objective-C and can be tested without
/// AppKit.
pub const Handle = usize;

/// Craft opens one window today; #67 opens more. Far past any real app, and
/// fixed so registration needs no allocator on the window-creation path.
pub const capacity = 16;

var windows: [capacity]Handle = @splat(0);

/// Record a window craft created. Idempotent.
///
/// Returns false if the table was full and the window was not recorded — the
/// caller is expected to say so rather than let a window silently become
/// unreopenable.
pub fn remember(handle: Handle) bool {
    if (handle == 0) return false;
    for (&windows) |*slot| {
        if (slot.* == handle) return true;
        if (slot.* == 0) {
            slot.* = handle;
            return true;
        }
    }
    return false;
}

/// Whether craft opened this window.
pub fn isKnown(handle: Handle) bool {
    if (handle == 0) return false;
    for (windows) |known| {
        if (known == handle) return true;
    }
    return false;
}

/// Drop a window. For real teardown, whenever #67 introduces some.
pub fn forget(handle: Handle) void {
    for (&windows) |*slot| {
        if (slot.* == handle) slot.* = 0;
    }
}

pub fn count() usize {
    var n: usize = 0;
    for (windows) |w| {
        if (w != 0) n += 1;
    }
    return n;
}

pub fn resetForTesting() void {
    windows = @splat(0);
}

const testing = std.testing;

test "a window craft opened is recognised" {
    resetForTesting();
    try testing.expect(remember(0x1000));
    try testing.expect(isKnown(0x1000));
}

test "a window craft did not open is not" {
    // The offscreen windows AppKit keeps for menus and tooltips land here.
    // Ordering one of those front puts an empty frame on screen.
    resetForTesting();
    _ = remember(0x1000);
    try testing.expect(!isKnown(0x2000));
}

test "registering twice does not consume two slots" {
    resetForTesting();
    try testing.expect(remember(0x1000));
    try testing.expect(remember(0x1000));
    try testing.expectEqual(@as(usize, 1), count());
}

test "a null window is neither recorded nor recognised" {
    // `contentView` and friends return nil often enough that zero has to mean
    // nothing rather than becoming a real entry that matches every other nil.
    resetForTesting();
    try testing.expect(!remember(0));
    try testing.expect(!isKnown(0));
    try testing.expectEqual(@as(usize, 0), count());
}

test "every window up to capacity is recorded" {
    resetForTesting();
    var i: usize = 1;
    while (i <= capacity) : (i += 1) {
        try testing.expect(remember(i * 0x100));
    }
    i = 1;
    while (i <= capacity) : (i += 1) {
        try testing.expect(isKnown(i * 0x100));
    }
    try testing.expectEqual(capacity, count());
}

test "past capacity the failure is reported, not swallowed" {
    // The caller logs this. A window that quietly stopped being reopenable is
    // the bug this whole module exists to prevent, so it must not be the
    // silent outcome of a full table.
    resetForTesting();
    var i: usize = 1;
    while (i <= capacity) : (i += 1) _ = remember(i * 0x100);
    try testing.expect(!remember(0xDEAD));
    try testing.expect(!isKnown(0xDEAD));
}

test "forgetting frees the slot for the next window" {
    resetForTesting();
    var i: usize = 1;
    while (i <= capacity) : (i += 1) _ = remember(i * 0x100);
    try testing.expect(!remember(0xDEAD));

    forget(0x100);
    try testing.expect(!isKnown(0x100));
    try testing.expect(remember(0xDEAD));
    try testing.expect(isKnown(0xDEAD));
}

test "forgetting a window that was never known changes nothing" {
    resetForTesting();
    _ = remember(0x1000);
    forget(0x2000);
    try testing.expect(isKnown(0x1000));
    try testing.expectEqual(@as(usize, 1), count());
}
