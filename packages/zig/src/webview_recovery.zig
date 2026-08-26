//! Bringing a window back after WebKit's content process dies.
//!
//! WKWebView renders in a separate process. When that process is killed — out
//! of memory, a GPU fault, a WebKit bug — the view does not error, close, or
//! notify the page. It goes white and stays white, and the only route back is
//! `reload`, which craft offered exclusively as a menu item the user had to
//! know to click. For an app meant to sit open for days, a blip became a dead
//! window.
//!
//! Reloading is the whole fix, and reloading unconditionally is the whole
//! problem: a page that reliably kills the renderer — an OOM loop, a bad
//! WebGL context — would be reloaded into the same crash forever, pinning a
//! core. So the reloads are budgeted.
//!
//! ## Why the budget is a rate and not a count
//!
//! A plain "three tries and stop" is wrong for the case this exists to serve.
//! An app open for a week that loses its renderer once a day is healthy, and
//! it would spend its three lives in the first three days and then be a white
//! window for the rest of the week. What distinguishes a crash loop from bad
//! luck is not how many crashes there have been but how close together they
//! are — so a window that has stayed up for `reset_after_ns` gets its budget
//! back. `attempts` counts a burst, not a lifetime.
//!
//! This module is pure: the caller supplies the clock, and nothing here talks
//! to Objective-C. That is what lets a crash loop be tested without crashing
//! anything.

const std = @import("std");

pub const Action = enum {
    /// Reload. The content process relaunches on the next load.
    reload,
    /// Stop reloading and show the page that says so. Reloading again would
    /// just be the same crash.
    give_up,
};

pub const Budget = struct {
    /// Reloads allowed within one burst.
    max_attempts: u8 = 3,
    /// Stay up this long and the burst is over. A minute is far longer than a
    /// crash loop takes to go round and far shorter than the gap between two
    /// unrelated failures.
    reset_after_ns: i128 = 60 * std.time.ns_per_s,
};

pub const State = struct {
    attempts: u8 = 0,
    last_crash_ns: ?i128 = null,
};

/// Record a crash and say what to do about it.
pub fn onCrash(state: *State, now_ns: i128, budget: Budget) Action {
    const in_same_burst = if (state.last_crash_ns) |last|
        now_ns -| last < budget.reset_after_ns
    else
        false;

    state.attempts = if (in_same_burst) state.attempts +| 1 else 1;
    state.last_crash_ns = now_ns;

    return if (state.attempts <= budget.max_attempts) .reload else .give_up;
}

// =============================================================================
// Per-window state
// =============================================================================

/// One budget per webview, so a window in a crash loop cannot spend the budget
/// of a window that is fine. Craft opens one window today; #67 opens more, and
/// a single shared counter would be exactly the bug that lands then.
const max_tracked = 8;

const Slot = struct {
    /// The webview this belongs to, as an opaque handle. Zero means free.
    key: usize = 0,
    state: State = .{},
};

var slots: [max_tracked]Slot = @splat(.{});

/// The budget for `key`, creating one if this webview has not crashed before.
///
/// Full table: the least recently troubled slot is reused. Losing a count is
/// the right failure — it costs one extra reload attempt for a window that is
/// probably fine, where refusing to track would cost a window its recovery.
pub fn stateFor(key: usize) *State {
    for (&slots) |*slot| {
        if (slot.key == key) return &slot.state;
    }
    for (&slots) |*slot| {
        if (slot.key == 0) {
            slot.* = .{ .key = key };
            return &slot.state;
        }
    }

    var oldest: *Slot = &slots[0];
    for (&slots) |*slot| {
        const slot_time = slot.state.last_crash_ns orelse std.math.minInt(i128);
        const oldest_time = oldest.state.last_crash_ns orelse std.math.minInt(i128);
        if (slot_time < oldest_time) oldest = slot;
    }
    oldest.* = .{ .key = key };
    return &oldest.state;
}

/// Forget a webview's history. For window teardown, and for tests.
pub fn forget(key: usize) void {
    for (&slots) |*slot| {
        if (slot.key == key) slot.* = .{};
    }
}

pub fn resetAllForTesting() void {
    slots = @splat(.{});
}

// =============================================================================
// The page shown once craft stops trying
// =============================================================================

/// What the window shows after the budget runs out.
///
/// The alternative is the white window this whole file exists to prevent —
/// bounded retries without this just reach the original bug more slowly. It
/// says what happened and offers the reload craft will no longer do on its
/// own, which is also how the burst gets broken: a person clicking it is not
/// a crash loop.
///
/// Self-contained by necessity. There is no server, no bundle path, and no
/// network guarantee at the point this is shown.
pub const give_up_page =
    \\<!doctype html><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>Page stopped responding</title>
    \\<style>
    \\:root{color-scheme:light dark}
    \\body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
    \\background:#fff;color:#1d1d1f;
    \\font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
    \\@media (prefers-color-scheme:dark){body{background:#1e1e1e;color:#f5f5f7}}
    \\main{max-width:26rem;padding:2rem;text-align:center}
    \\h1{font-size:1.0625rem;font-weight:600;margin:0 0 .5rem}
    \\p{margin:0 0 1.25rem;opacity:.7}
    \\button{font:inherit;font-weight:500;padding:.4rem 1.1rem;border-radius:.375rem;
    \\border:1px solid rgba(0,0,0,.15);background:#fff;color:inherit;cursor:pointer}
    \\@media (prefers-color-scheme:dark){button{background:#333;border-color:rgba(255,255,255,.15)}}
    \\</style>
    \\<main>
    \\<h1>This page stopped responding</h1>
    \\<p>It was reloaded a few times and kept failing, so it has been left alone.</p>
    \\<button onclick="if(window.craft&&window.craft.window)window.craft.window.reload();else location.reload()">Reload</button>
    \\</main>
;

const testing = std.testing;
const second = std.time.ns_per_s;

test "the first crash reloads" {
    var state: State = .{};
    try testing.expectEqual(Action.reload, onCrash(&state, 0, .{}));
}

test "a crash loop is cut off after the budget" {
    var state: State = .{};
    const budget: Budget = .{ .max_attempts = 3 };
    try testing.expectEqual(Action.reload, onCrash(&state, 0, budget));
    try testing.expectEqual(Action.reload, onCrash(&state, 1 * second, budget));
    try testing.expectEqual(Action.reload, onCrash(&state, 2 * second, budget));
    try testing.expectEqual(Action.give_up, onCrash(&state, 3 * second, budget));
    try testing.expectEqual(Action.give_up, onCrash(&state, 4 * second, budget));
}

test "a window that stayed up gets its budget back" {
    // The case a lifetime counter gets wrong: an app open for a week that
    // loses its renderer once a day is healthy, and must not be a white window
    // by Thursday.
    var state: State = .{};
    const budget: Budget = .{ .max_attempts = 3, .reset_after_ns = 60 * second };

    var day: i128 = 0;
    while (day < 7) : (day += 1) {
        const t = day * 24 * 60 * 60 * second;
        try testing.expectEqual(Action.reload, onCrash(&state, t, budget));
        try testing.expectEqual(@as(u8, 1), state.attempts);
    }
}

test "the reset boundary is exact" {
    var state: State = .{};
    const budget: Budget = .{ .max_attempts = 1, .reset_after_ns = 60 * second };

    try testing.expectEqual(Action.reload, onCrash(&state, 0, budget));
    // One nanosecond short of the window: still the same burst.
    try testing.expectEqual(Action.give_up, onCrash(&state, 60 * second - 1, budget));
    // Exactly the window, measured from the previous crash: a new burst.
    try testing.expectEqual(Action.reload, onCrash(&state, 2 * 60 * second - 1, budget));
}

test "a burst is measured between crashes, not from the first one" {
    // Crashes every 40 seconds never reset a 60-second window, however long it
    // goes on — that is a slow loop, and it is still a loop.
    var state: State = .{};
    const budget: Budget = .{ .max_attempts = 3, .reset_after_ns = 60 * second };
    try testing.expectEqual(Action.reload, onCrash(&state, 0, budget));
    try testing.expectEqual(Action.reload, onCrash(&state, 40 * second, budget));
    try testing.expectEqual(Action.reload, onCrash(&state, 80 * second, budget));
    try testing.expectEqual(Action.give_up, onCrash(&state, 120 * second, budget));
}

test "a clock that goes backwards does not hand out extra reloads" {
    // The caller passes CLOCK_MONOTONIC, so this should not happen on macOS or
    // Linux — but `compat.nanoTimestamp` falls back to wall-clock on Windows,
    // where an NTP correction can step backwards, and returns 0 outright if
    // the clock cannot be read. Saturating subtraction makes all of that read
    // as "no time passed", which keeps the burst intact rather than handing
    // out a fresh budget on every backwards step.
    var state: State = .{};
    const budget: Budget = .{ .max_attempts = 2, .reset_after_ns = 60 * second };
    try testing.expectEqual(Action.reload, onCrash(&state, 1000 * second, budget));
    try testing.expectEqual(Action.reload, onCrash(&state, 500 * second, budget));
    try testing.expectEqual(Action.give_up, onCrash(&state, 0, budget));
}

test "the attempt count cannot wrap around into a fresh budget" {
    var state: State = .{};
    const budget: Budget = .{ .max_attempts = 3, .reset_after_ns = 60 * second };
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = onCrash(&state, @as(i128, @intCast(i)), budget);
    }
    try testing.expectEqual(@as(u8, 255), state.attempts);
    try testing.expectEqual(Action.give_up, onCrash(&state, 1000, budget));
}

test "each window has its own budget" {
    resetAllForTesting();
    const a = stateFor(0x1000);
    const b = stateFor(0x2000);
    const budget: Budget = .{ .max_attempts = 1 };

    try testing.expectEqual(Action.reload, onCrash(a, 0, budget));
    try testing.expectEqual(Action.give_up, onCrash(a, 1, budget));
    // b has spent nothing, and a's loop must not have spent it for them.
    try testing.expectEqual(Action.reload, onCrash(stateFor(0x2000), 2, budget));
    _ = b;
}

test "the same window gets the same budget back" {
    resetAllForTesting();
    _ = onCrash(stateFor(0x1000), 0, .{});
    try testing.expectEqual(@as(u8, 1), stateFor(0x1000).attempts);
    _ = onCrash(stateFor(0x1000), second, .{});
    try testing.expectEqual(@as(u8, 2), stateFor(0x1000).attempts);
}

test "a closed window is forgotten" {
    resetAllForTesting();
    _ = onCrash(stateFor(0x1000), 0, .{});
    forget(0x1000);
    try testing.expectEqual(@as(u8, 0), stateFor(0x1000).attempts);
}

test "more windows than the table holds still each get tracked" {
    resetAllForTesting();
    var i: usize = 1;
    while (i <= max_tracked + 4) : (i += 1) {
        const state = stateFor(i * 0x100);
        try testing.expectEqual(Action.reload, onCrash(state, @intCast(i), .{}));
    }
    // The most recent windows are the ones still held.
    try testing.expectEqual(@as(u8, 1), stateFor((max_tracked + 4) * 0x100).attempts);
}

test "the give-up page carries its own styling and a way back" {
    // It is shown when there is no server, no bundle path and possibly no
    // network, so anything it references it must contain.
    // `location.reload()` alone cannot work here: the page is installed with
    // `loadHTMLString:baseURL:` and a nil base, so reloading navigates to the
    // base rather than re-rendering the substitute document. The button has to
    // go through the bridge, which re-applies what the window actually had.
    try testing.expect(std.mem.indexOf(u8, give_up_page, "window.craft.window.reload()") != null);
    // The fallback still has to be there for a page served without the bridge.
    try testing.expect(std.mem.indexOf(u8, give_up_page, "location.reload()") != null);
    try testing.expect(std.mem.indexOf(u8, give_up_page, "<style>") != null);
    try testing.expect(std.mem.indexOf(u8, give_up_page, "prefers-color-scheme") != null);
    try testing.expect(std.mem.indexOf(u8, give_up_page, "src=") == null);
    try testing.expect(std.mem.indexOf(u8, give_up_page, "href=") == null);
    // No apostrophes: it is passed to Objective-C as a C string, but it is
    // also the kind of literal that ends up inside an `evaluateJavaScript`
    // single-quoted string one refactor later.
    try testing.expect(std.mem.indexOfScalar(u8, give_up_page, '\'') == null);
}
