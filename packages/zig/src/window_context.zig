//! Which window a bridge message came from.
//!
//! Every window bridge action — `close`, `startDrag`, `setAppearance` — used
//! to act on one handle held by the global `WindowBridge`, set when the first
//! window was built. That is correct while an app has one window and wrong the
//! moment it has two: a Settings window asking to close itself closed the main
//! window instead, because the bridge had never heard of any other.
//!
//! The sender is not something the page can be trusted to state, and it is not
//! something it should have to. `WKScriptMessage` carries the `WKWebView` that
//! posted it, and a webview knows its window, so the answer is already in the
//! message. The dispatcher records it here before it routes, and the window
//! bridge reads it back — the same trick `request_context.zig` plays with the
//! call id, and for the same reason: threading a parameter through every
//! handler is a change every future handler can forget to make.
//!
//! ## Why a stack
//!
//! Bridge dispatch nests: a modal run loop (`NSOpenPanel`) keeps delivering
//! script messages, so a second message is handled inside the first. Those two
//! can be from different windows. One slot would leave the outer call acting
//! on the inner call's window after the inner one returned.
//!
//! ## Threading
//!
//! Thread-local, like `request_context`. Bridge messages are dispatched on the
//! main thread; anything reading this from elsewhere sees an empty stack and
//! falls back to the bridge's own handle, which is what every caller did
//! before this module existed.

const std = @import("std");
const window_registry = @import("window_registry.zig");

pub const Handle = window_registry.Handle;

/// Deep enough for any real nesting — frames are only added by a modal run
/// loop re-entering dispatch, which nests by user action.
pub const max_depth = 16;

threadlocal var frames: [max_depth]Handle = @splat(0);
threadlocal var depth: usize = 0;

/// Begin serving a message from `handle`. Pass 0 when the sender is unknown,
/// so it shadows any enclosing frame rather than inheriting a window that is
/// not the sender's. Always pair with `pop`.
pub fn push(handle: Handle) void {
    if (depth < max_depth) frames[depth] = handle;
    // Counted past the array on purpose, so `pop` stays balanced with `push`
    // and an overflowed frame reads as unknown rather than as the frame
    // sixteen levels up.
    depth += 1;
}

pub fn pop() void {
    if (depth > 0) depth -= 1;
}

/// The window now being served, if it is known.
pub fn current() ?Handle {
    if (depth == 0 or depth > max_depth) return null;
    const handle = frames[depth - 1];
    return if (handle == 0) null else handle;
}

pub fn resetForTesting() void {
    depth = 0;
    frames = @splat(0);
}

const testing = std.testing;

test "nothing is being served before dispatch" {
    resetForTesting();
    try testing.expect(current() == null);
}

test "the window a message came from is what dispatch reads" {
    resetForTesting();
    push(0x1000);
    defer pop();
    try testing.expectEqual(@as(?Handle, 0x1000), current());
}

test "a nested message does not leak into the call around it" {
    // A file panel spins a run loop that keeps delivering script messages, and
    // the inner one can come from another window.
    resetForTesting();
    push(0x1000);
    defer pop();
    {
        push(0x2000);
        defer pop();
        try testing.expectEqual(@as(?Handle, 0x2000), current());
    }
    try testing.expectEqual(@as(?Handle, 0x1000), current());
}

test "an unknown sender shadows the call around it" {
    // Inheriting the outer window would have the inner call act on a window
    // that had nothing to do with it.
    resetForTesting();
    push(0x1000);
    defer pop();
    push(0);
    defer pop();
    try testing.expect(current() == null);
}

test "popping more than was pushed does not underflow" {
    resetForTesting();
    pop();
    pop();
    push(0x1000);
    try testing.expectEqual(@as(?Handle, 0x1000), current());
    pop();
    try testing.expect(current() == null);
}

test "past the stack's depth the frame reads as unknown" {
    resetForTesting();
    // This test deliberately leaves the stack deep, and every other test in
    // the binary reads the same thread-local — so it puts it back rather than
    // handing the next one a frame sixteen levels down.
    defer resetForTesting();
    var i: usize = 0;
    while (i < max_depth + 3) : (i += 1) push(0x1000 + i);
    try testing.expect(current() == null);

    // And unwinds back to a real frame rather than staying stuck.
    i = 0;
    while (i < 3) : (i += 1) pop();
    try testing.expectEqual(@as(?Handle, 0x1000 + max_depth - 1), current());
}
