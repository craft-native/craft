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

/// Maximum live windows. Fixed so registration needs no allocator on the
/// window-creation path; constructors fail transactionally past this limit.
pub const capacity = 16;

/// How long a window's name may be.
///
/// A name is an app-chosen identifier — "settings", "inspector" — not a
/// title, so it is short by nature. Fixed rather than allocated for the same
/// reason the table is: naming happens on the window-creation path, which has
/// no allocator to hand.
pub const max_name = 64;

/// One row: the window, and what the app that opened it calls it.
///
/// The name is what makes "open the settings window" idempotent. Without it
/// the page can only ask for *a* window, so a second Cmd+, opens a second
/// settings window — and the app has no way to find the first one to focus
/// instead.
const Entry = struct {
    handle: Handle = 0,
    /// The webview whose page created this named window. Native events are
    /// delivered both to the window's own page and to this owner, where the
    /// TypeScript `Window` handle and its listeners live.
    owner_webview: Handle = 0,
    name: [max_name]u8 = @splat(0),
    name_len: usize = 0,

    /// By pointer, not by value: a by-value `self` is a copy that dies at the
    /// return, and the slice would point into it.
    fn named(self: *const Entry) ?[]const u8 {
        return if (self.name_len == 0) null else self.name[0..self.name_len];
    }
};

var windows: [capacity]Entry = @splat(.{});

/// Record a window craft created. Idempotent.
///
/// Returns false if the table was full and the window was not recorded — the
/// caller must abandon construction rather than let a window silently become
/// unreopenable.
pub fn remember(handle: Handle) bool {
    return rememberNamed(handle, null);
}

/// Record a window under a name the app can find it by again.
///
/// A name longer than `max_name`, or one already held by a *different* live
/// window, is refused rather than truncated or duplicated: both would hand
/// back a window that is not the one asked for, and the caller's next act is
/// to show it to somebody.
///
/// Two passes, not one. A single pass that took the first free slot would
/// insert a duplicate whenever `forget` had opened a gap ahead of an existing
/// entry — the window would then be recorded twice and `forget` would clear
/// only one of them.
pub fn rememberNamed(handle: Handle, name: ?[]const u8) bool {
    return rememberNamedOwned(handle, name, 0);
}

/// Record a window and, once, the page that created its typed handle.
///
/// Reopening an existing name from another page does not transfer ownership:
/// subscriptions belong to the handle returned to the original creator, and
/// silently stealing them would make that page stop receiving native events.
pub fn rememberNamedOwned(handle: Handle, name: ?[]const u8, owner_webview: Handle) bool {
    if (handle == 0) return false;
    if (name) |n| {
        if (n.len == 0 or n.len > max_name) return false;
        if (byName(n)) |owner| {
            if (owner != handle) return false;
        }
    }

    for (&windows) |*slot| {
        if (slot.handle == handle) {
            if (name) |n| setName(slot, n);
            if (slot.owner_webview == 0 and owner_webview != 0) slot.owner_webview = owner_webview;
            return true;
        }
    }

    for (&windows) |*slot| {
        if (slot.handle == 0) {
            slot.handle = handle;
            slot.owner_webview = owner_webview;
            if (name) |n| setName(slot, n) else slot.name_len = 0;
            return true;
        }
    }

    return false;
}

/// The page that owns this window's typed handle, if it was runtime-created.
pub fn ownerWebViewOf(handle: Handle) ?Handle {
    if (handle == 0) return null;
    for (windows) |entry| {
        if (entry.handle == handle) {
            return if (entry.owner_webview == 0) null else entry.owner_webview;
        }
    }
    return null;
}

fn setName(slot: *Entry, name: []const u8) void {
    @memcpy(slot.name[0..name.len], name);
    slot.name_len = name.len;
}

/// The window recorded under this name, if one still is.
pub fn byName(name: []const u8) ?Handle {
    if (name.len == 0 or name.len > max_name) return null;
    for (&windows) |*entry| {
        if (entry.handle == 0) continue;
        const known = entry.named() orelse continue;
        if (std.mem.eql(u8, known, name)) return entry.handle;
    }
    return null;
}

/// What this window was opened as, if it was opened under a name.
pub fn nameOf(handle: Handle) ?[]const u8 {
    if (handle == 0) return null;
    for (&windows) |*entry| {
        if (entry.handle == handle) return entry.named();
    }
    return null;
}

/// Whether craft opened this window.
pub fn isKnown(handle: Handle) bool {
    if (handle == 0) return false;
    for (windows) |entry| {
        if (entry.handle == handle) return true;
    }
    return false;
}

/// Drop a window during permanent teardown.
pub fn forget(handle: Handle) void {
    for (&windows) |*slot| {
        if (slot.handle == handle) slot.* = .{};
    }
}

/// Stop delivering child-window events to a webview being destroyed.
/// Children remain alive and continue receiving their own local events.
pub fn forgetOwner(owner_webview: Handle) void {
    if (owner_webview == 0) return;
    for (&windows) |*slot| {
        if (slot.owner_webview == owner_webview) slot.owner_webview = 0;
    }
}

pub fn count() usize {
    var n: usize = 0;
    for (windows) |entry| {
        if (entry.handle != 0) n += 1;
    }
    return n;
}

pub fn resetForTesting() void {
    windows = @splat(.{});
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

test "forgetting an owner leaves its child registered without a dangling target" {
    resetForTesting();
    try testing.expect(rememberNamedOwned(0x1000, "settings", 0x2000));
    forgetOwner(0x2000);
    try testing.expectEqual(@as(?Handle, 0x1000), byName("settings"));
    try testing.expect(ownerWebViewOf(0x1000) == null);
}

test "an orphaned named window can be claimed by its next opener" {
    resetForTesting();
    try testing.expect(rememberNamedOwned(0x1000, "settings", 0x2000));
    forgetOwner(0x2000);
    try testing.expect(rememberNamedOwned(0x1000, "settings", 0x3000));
    try testing.expectEqual(@as(?Handle, 0x3000), ownerWebViewOf(0x1000));
}

test "a window opened under a name is found by it" {
    resetForTesting();
    try testing.expect(rememberNamed(0x1000, "settings"));
    try testing.expectEqual(@as(?Handle, 0x1000), byName("settings"));
    try testing.expectEqualStrings("settings", nameOf(0x1000).?);
}

test "an unnamed window has no name to find it by" {
    resetForTesting();
    try testing.expect(remember(0x1000));
    try testing.expect(nameOf(0x1000) == null);
    try testing.expect(byName("settings") == null);
}

test "a name is not handed to a second window" {
    // The whole point of the name is that asking for "settings" twice reaches
    // the same window. Letting a second one take the name would leave the
    // first unreachable and two settings windows on screen.
    resetForTesting();
    try testing.expect(rememberNamed(0x1000, "settings"));
    try testing.expect(!rememberNamed(0x2000, "settings"));
    try testing.expectEqual(@as(?Handle, 0x1000), byName("settings"));
}

test "naming the same window again is idempotent" {
    resetForTesting();
    try testing.expect(rememberNamed(0x1000, "settings"));
    try testing.expect(rememberNamed(0x1000, "settings"));
    try testing.expectEqual(@as(usize, 1), count());
}

test "a window already recorded can be named afterwards" {
    // `keepWindowAfterClose` records every window craft creates, so by the
    // time the opener names it there is already a row.
    resetForTesting();
    try testing.expect(remember(0x1000));
    try testing.expect(rememberNamed(0x1000, "settings"));
    try testing.expectEqual(@as(usize, 1), count());
    try testing.expectEqual(@as(?Handle, 0x1000), byName("settings"));
}

test "a runtime window remembers the page that owns its typed handle" {
    resetForTesting();
    try testing.expect(rememberNamedOwned(0x1000, "settings", 0x2000));
    try testing.expectEqual(@as(?Handle, 0x2000), ownerWebViewOf(0x1000));
}

test "reopening a named window does not steal its creator" {
    resetForTesting();
    try testing.expect(rememberNamedOwned(0x1000, "settings", 0x2000));
    try testing.expect(rememberNamedOwned(0x1000, "settings", 0x3000));
    try testing.expectEqual(@as(?Handle, 0x2000), ownerWebViewOf(0x1000));
}

test "naming an already registered child records its creator" {
    resetForTesting();
    try testing.expect(remember(0x1000));
    try testing.expect(rememberNamedOwned(0x1000, "settings", 0x2000));
    try testing.expectEqual(@as(?Handle, 0x2000), ownerWebViewOf(0x1000));
}

test "forgetting a window releases its name" {
    resetForTesting();
    try testing.expect(rememberNamed(0x1000, "settings"));
    forget(0x1000);
    try testing.expect(byName("settings") == null);
    try testing.expect(rememberNamed(0x2000, "settings"));
}

test "a name longer than the field is refused, not truncated" {
    // Truncating would silently merge two different windows under one name.
    resetForTesting();
    const too_long: [max_name + 1]u8 = @splat('n');
    try testing.expect(!rememberNamed(0x1000, &too_long));
    try testing.expectEqual(@as(usize, 0), count());
}

test "an empty name is refused" {
    resetForTesting();
    try testing.expect(!rememberNamed(0x1000, ""));
    try testing.expect(byName("") == null);
}

test "a name that fills the field exactly is kept whole" {
    resetForTesting();
    const exact: [max_name]u8 = @splat('n');
    try testing.expect(rememberNamed(0x1000, &exact));
    try testing.expectEqualStrings(&exact, nameOf(0x1000).?);
}

test "a freed slot ahead of a live one does not duplicate it" {
    // A single-pass insert took the first free slot without finishing the
    // scan, so re-recording a window that sat behind a gap added a second row
    // for it — and `forget` then cleared only one.
    resetForTesting();
    _ = remember(0x1000);
    _ = remember(0x2000);
    forget(0x1000);
    try testing.expect(remember(0x2000));
    try testing.expectEqual(@as(usize, 1), count());
    forget(0x2000);
    try testing.expect(!isKnown(0x2000));
}
