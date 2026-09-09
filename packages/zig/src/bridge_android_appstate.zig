//! `startAppStateMonitoring`, `stopAppStateMonitoring` and `getAppState`.
//!
//! The second listener shim, and the first migration that moves *state* rather
//! than working around it.
//!
//! ## Why all three, or none
//!
//! `getAppState` returns `currentAppState`, a field only the lifecycle
//! observer writes. Serving the observer from Zig without serving the getter
//! would leave the Kotlin field frozen at its initial "active" while the real
//! state moved — the exact failure the flashlight deferral describes, where
//! one half writes a field the other half reads.
//!
//! So the state moves here, and all three actions come with it. That is what
//! the flashlight row means by "migrating the pair together would need the
//! state to move too": this is what it looks like when it can.
//!
//! Process-global, because `ProcessLifecycleOwner` is: one answer per process,
//! not per Activity. Atomic, because the observer runs on the main looper and
//! `getAppState` is called from the WebView's JavaBridge thread.
//!
//! ## Only a change is announced
//!
//! The observer compares against the current state and does nothing when they
//! match. `ON_START` immediately after `ON_RESUME` is an ordinary sequence and
//! both map to "active", so without that check a page would see two
//! `craftAppStateChange` events for one foregrounding.
//!
//! ## Two deliveries, not one
//!
//! A change calls `window._craftAppStateCallback(state)` *and* dispatches
//! `craftAppStateChange`. Both, in that order, because the shim does both —
//! `onAppStateChange` reads the first and `addEventListener` the second, and a
//! page may well use either.

const std = @import("std");
const events = @import("android_events.zig");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const start_app_state_monitoring = "startAppStateMonitoring";
    pub const stop_app_state_monitoring = "stopAppStateMonitoring";
    pub const get_app_state = "getAppState";
};

/// The global `onAppStateChange` assigns, and the event name `sendEvent` uses.
pub const callback_global = "_craftAppStateCallback";
pub const event_name = "craftAppStateChange";

pub const State = enum {
    active,
    inactive,
    background,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .active => "active",
            .inactive => "inactive",
            .background => "background",
        };
    }
};

/// The state a page sees before anything has happened.
///
/// `private var currentAppState = "active"` — so `getAppState` answers "active"
/// even when monitoring was never started, and that is what a page gets today.
const initial: State = .active;

var current: std.atomic.Value(u8) = .init(@backingInt(initial));

/// What the process currently believes.
pub fn state() State {
    return @fromBackingInt(@intCast(current.load(.acquire)));
}

/// Put the state back to its process start value.
///
/// For tests. Nothing in the bridge resets it, because nothing in a process
/// un-launches the app.
pub fn reset() void {
    current.store(@backingInt(initial), .release);
}

/// `Lifecycle.Event` to a state, or null where the shim's `when` falls to
/// `else` and keeps what it had.
///
/// The names are `Lifecycle.Event`'s own — the holder passes `event.name`
/// rather than an ordinal, because an ordinal is a number that means nothing
/// on its own and would move if the enum ever gained a member.
pub fn stateFor(event: []const u8) ?State {
    if (std.mem.eql(u8, event, "ON_START")) return .active;
    if (std.mem.eql(u8, event, "ON_RESUME")) return .active;
    if (std.mem.eql(u8, event, "ON_PAUSE")) return .inactive;
    if (std.mem.eql(u8, event, "ON_STOP")) return .background;
    return null;
}

/// Apply an event, and say whether it changed anything.
///
/// Null means "announce nothing" — either the event has no state (`ON_CREATE`,
/// `ON_DESTROY`, `ON_ANY`) or it maps to the state already held.
pub fn apply(event: []const u8) ?State {
    const next = stateFor(event) orelse return null;
    if (next == state()) return null;
    current.store(@backingInt(next), .release);
    return next;
}

/// `window._craftAppStateCallback("active")` — the payload, quoted.
pub fn callbackPayload(allocator: std.mem.Allocator, value: State) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, value.name());
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

/// `{"state":"active"}` — the detail `sendEvent` builds.
pub fn eventDetail(allocator: std.mem.Allocator, value: State) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"state\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, value.name());
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

/// Announce a change, both ways the shim announces it.
pub fn announce(allocator: std.mem.Allocator, value: State) !void {
    const payload = try callbackPayload(allocator, value);
    defer allocator.free(payload);
    try events.settle(allocator, callback_global, payload);

    const detail = try eventDetail(allocator, value);
    defer allocator.free(detail);
    try events.emitEvent(allocator, event_name, detail);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "every lifecycle event maps where the shim's when maps it" {
    try testing.expectEqual(State.active, stateFor("ON_START").?);
    try testing.expectEqual(State.active, stateFor("ON_RESUME").?);
    try testing.expectEqual(State.inactive, stateFor("ON_PAUSE").?);
    try testing.expectEqual(State.background, stateFor("ON_STOP").?);
}

test "an event with no state keeps the one already held" {
    // The shim's `else -> currentAppState`. ON_CREATE and ON_DESTROY really do
    // arrive, and ON_ANY is dispatched to observers registered for it.
    try testing.expect(stateFor("ON_CREATE") == null);
    try testing.expect(stateFor("ON_DESTROY") == null);
    try testing.expect(stateFor("ON_ANY") == null);

    // And anything unrecognised, which is what a future enum member would be.
    try testing.expect(stateFor("") == null);
    try testing.expect(stateFor("on_start") == null);
}

test "a process starts active, whether or not anything is monitoring" {
    // `private var currentAppState = "active"`. A page calling getAppState
    // before startAppStateMonitoring gets "active" rather than an error or an
    // empty string, and that is the answer it gets today.
    reset();
    try testing.expectEqual(State.active, state());
    try testing.expectEqualStrings("active", state().name());
}

test "only a change is announced" {
    reset();

    // Already active: ON_START and ON_RESUME are both no-ops, which is what
    // stops one foregrounding producing two craftAppStateChange events.
    try testing.expect(apply("ON_START") == null);
    try testing.expect(apply("ON_RESUME") == null);

    // A real change reports the new state and keeps it.
    try testing.expectEqual(State.inactive, apply("ON_PAUSE").?);
    try testing.expectEqual(State.inactive, state());

    // The same event again changes nothing.
    try testing.expect(apply("ON_PAUSE") == null);

    // And on to background, then back.
    try testing.expectEqual(State.background, apply("ON_STOP").?);
    try testing.expectEqual(State.active, apply("ON_START").?);
    reset();
}

test "an event with no state does not disturb the one held" {
    reset();
    _ = apply("ON_PAUSE");
    try testing.expect(apply("ON_CREATE") == null);
    try testing.expectEqual(State.inactive, state());
    reset();
}

test "the two deliveries carry the same state in two shapes" {
    // `_craftAppStateCallback("active")` and
    // `dispatchEvent(new CustomEvent('craftAppStateChange', {detail: {"state":"active"}}))`
    // — a bare string for the callback, an object for the event.
    const payload = try callbackPayload(testing.allocator, .background);
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"background\"", payload);

    const detail = try eventDetail(testing.allocator, .background);
    defer testing.allocator.free(detail);
    try testing.expectEqualStrings("{\"state\":\"background\"}", detail);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, detail, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("background", parsed.value.object.get("state").?.string);
}

test "the state names are the strings the page compares against" {
    // A page writes `state === 'background'`, so these are API rather than
    // internal spelling.
    try testing.expectEqualStrings("active", State.active.name());
    try testing.expectEqualStrings("inactive", State.inactive.name());
    try testing.expectEqualStrings("background", State.background.name());
}

test "the actions and globals match the shim exactly" {
    try testing.expectEqualStrings("startAppStateMonitoring", A.start_app_state_monitoring);
    try testing.expectEqualStrings("stopAppStateMonitoring", A.stop_app_state_monitoring);
    try testing.expectEqualStrings("getAppState", A.get_app_state);
    try testing.expectEqualStrings("_craftAppStateCallback", callback_global);
    try testing.expectEqualStrings("craftAppStateChange", event_name);
}
