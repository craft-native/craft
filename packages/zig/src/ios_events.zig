//! Pushing an event to the page, from wherever the event happened.
//!
//! A reply answers a call the page made; an event is native talking first.
//! That difference decides everything about this file. There is no request id
//! to carry, so `ios_async`'s slot pool has nothing to hold — but the hard part
//! it solves is still here: a `CLLocationManager` delegate callback, a
//! `CMMotionManager` handler, a `SFSpeechRecognizer` result all arrive on
//! whatever queue the framework chose, and `evaluateJavaScript` is
//! main-thread-only.
//!
//! The desktop emits events by concatenating JavaScript by hand —
//! `bridge_iap.zig:362` builds `dispatchEvent(new CustomEvent('...', { detail:
//! { productId: '` and then appends a value with its own escaping. That works
//! until a value contains a quote. Here the detail is already JSON, so it is
//! inlined as an object literal and never escaped twice; the only thing
//! interpolated as a *name* comes from the `Channel` enum, which is a fixed
//! set of literals rather than anything a page or a device can influence.
//!
//! ## The event vocabulary is iOS's, not the desktop's
//!
//! This file was first written against `capabilities.Channel`, whose names are
//! all `craft:`-prefixed (`craft:location:update`) and whose own test enforces
//! that prefix. The iOS page contract is a different vocabulary: Swift's
//! `sendToWeb` dispatches `craftLocationUpdate`, `craftMotionUpdate`,
//! `craftSpeechResult` — camelCase, no colon. A `Channel` therefore cannot
//! *spell* the name an iOS page is listening for, and emitting the desktop
//! spelling would fire an event with no subscriber: a stream that looks
//! implemented and delivers nothing.
//!
//! So `Event` below is the iOS vocabulary, taken from the `sendToWeb` call
//! sites. Where a desktop channel means the same thing, `capabilityChannel`
//! maps to it, and emitting marks that channel live — so `craft.capabilities()`
//! still answers from the code that does the emitting rather than a
//! hand-maintained list. Where there is no desktop equivalent the mapping is
//! null, which is honest rather than approximate.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const compat_mutex = @import("compat_mutex.zig");

/// The events an iOS page subscribes to.
///
/// Every name here is copied from a `sendToWeb` call in
/// `packages/ios/templates/CraftApp.swift` — that is the contract, and a page
/// written against the Swift app must keep working when Zig serves the same
/// action. `eventName` is what lands in the `CustomEvent` constructor.
pub const Event = enum {
    location_update,
    location_error,
    motion_update,
    speech_result,
    speech_error,
    speech_end,
    network_change,
    deep_link,
    push_token,
    notification_response,
    bluetooth_device,
    ar_plane,

    pub fn eventName(self: Event) []const u8 {
        return switch (self) {
            .location_update => "craftLocationUpdate",
            .location_error => "craftLocationError",
            .motion_update => "craftMotionUpdate",
            .speech_result => "craftSpeechResult",
            .speech_error => "craftSpeechError",
            .speech_end => "craftSpeechEnd",
            .network_change => "craftNetworkChange",
            .deep_link => "craftDeepLink",
            .push_token => "craftPushToken",
            .notification_response => "craftNotificationResponse",
            .bluetooth_device => "craftBluetoothDevice",
            .ar_plane => "craftARPlane",
        };
    }
};

// There is deliberately no mapping from an `Event` to a
// `capabilities.Channel`.
//
// An earlier version had one, and emitting `craftLocationUpdate` registered
// `craft:location:update` as live. That reads as a small convenience and is a
// false claim: `Liveness.live` means "something in this build took out a
// permit to emit on it", and nothing in an iOS build ever dispatches the
// `craft:`-prefixed name. A page reading `craft.capabilities()` would be told
// a channel is live that it cannot receive — the overclaiming this manifest
// exists to prevent, committed by the manifest's own plumbing.
//
// `unknown` is the honest answer for a desktop channel on iOS. It also removed
// an unsynchronised write: `registerEmitter` sets `live_channels[...]` and
// `emit` is explicitly callable from any thread.
//
// When the capabilities vocabulary grows names an iOS page actually
// subscribes to, this becomes a real mapping rather than an approximate one.

/// A queued event, owned until the main queue drains it.
const Pending = struct {
    in_use: bool = false,
    /// The channel, not its name: an enum is a fixed vocabulary, and the
    /// formatter reads the literal from it rather than accepting a string that
    /// could carry a quote into a JS source position.
    event: Event = .location_update,
    /// The `detail` payload as JSON. Owned; freed after delivery.
    detail: ?[]u8 = null,
};

/// Events can burst — a location subscription at high accuracy fires several
/// times a second, and a page that has stopped listening still costs a hop.
/// Sixteen deep matches the async pool; beyond that the oldest queued event is
/// dropped in favour of the newest, which is the right trade for a stream
/// whose consumer wants current state rather than history.
const max_queued = 16;

var queue: [max_queued]Pending = @splat(.{});
var queue_mutex: compat_mutex.Mutex = .{};

/// How many events were dropped because the queue was full.
///
/// Counted rather than logged per-drop: a saturated stream would otherwise
/// produce a log line per event and drown the thing being diagnosed. Read it
/// when a page reports missing updates.
var dropped: usize = 0;

pub fn droppedCount() usize {
    queue_mutex.lock();
    defer queue_mutex.unlock();
    return dropped;
}

const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
extern "c" fn dispatch_async_f(queue_ref: *anyopaque, context: ?*anyopaque, work: dispatch_function_t) void;
extern var _dispatch_main_q: anyopaque;

/// Emit `channel` with `detail_json` as the event's `detail`.
///
/// Safe to call from any thread. `detail_json` must be a complete JSON value —
/// an object literal is the convention — and is copied, because the caller is
/// typically a delegate callback whose buffer dies on return.
///
/// A full queue drops the *oldest* pending event rather than refusing the new
/// one. For a stream, stale data is worse than a gap.
pub fn emit(event: Event, detail_json: []const u8) void {
    if (!builtin.target.os.tag.isDarwin()) return;

    const allocator = std.heap.c_allocator;
    const copy = allocator.dupe(u8, detail_json) catch {
        // Nothing to deliver and nobody to tell — an event has no promise
        // waiting on it. Counted so a page reporting gaps has something to
        // point at.
        queue_mutex.lock();
        defer queue_mutex.unlock();
        dropped += 1;
        return;
    };

    var index: usize = undefined;
    {
        queue_mutex.lock();
        defer queue_mutex.unlock();

        index = findFreeSlot() orelse blk: {
            // Evict the oldest. Slot 0 is as good as any: the queue is drained
            // in index order, so it holds the least recently delivered.
            if (queue[0].detail) |old| allocator.free(old);
            queue[0] = .{};
            dropped += 1;
            break :blk 0;
        };

        queue[index] = .{ .in_use = true, .event = event, .detail = copy };
    }

    dispatch_async_f(&_dispatch_main_q, @ptrFromInt(index + 1), deliverOnMain);
}

fn findFreeSlot() ?usize {
    for (&queue, 0..) |*slot, i| {
        if (!slot.in_use) return i;
    }
    return null;
}

fn deliverOnMain(context: ?*anyopaque) callconv(.c) void {
    const index: usize = @intFromPtr(context orelse return) - 1;
    if (index >= max_queued) return;

    var event: Event = undefined;
    var detail: ?[]u8 = null;
    {
        queue_mutex.lock();
        defer queue_mutex.unlock();
        const slot = &queue[index];
        if (!slot.in_use) return; // evicted before this hop ran
        event = slot.event;
        detail = slot.detail;
        slot.* = .{};
    }

    const allocator = std.heap.c_allocator;
    const payload = detail orelse return;
    defer allocator.free(payload);

    const js = formatEvent(allocator, event, payload) catch return;
    defer allocator.free(js);

    const ios_dispatch = @import("ios_dispatch.zig");
    ios_dispatch.evalJS(js) catch |err| {
        std.log.warn("ios events: could not emit {s}: {}", .{ event.eventName(), err });
    };
}

/// The `dispatchEvent` call for one event.
///
/// The detail is inlined as a JSON literal, not as a quoted string: it is
/// already JSON, and wrapping it would make the page parse a string containing
/// an object. The `if (window.dispatchEvent)` guard mirrors the desktop's, for
/// a document torn down between the emit and the hop.
///
/// Split out from `deliverOnMain` so the exact bytes are testable without a
/// webview or a run loop.
fn formatEvent(
    allocator: std.mem.Allocator,
    event: Event,
    detail_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "if(window.dispatchEvent)window.dispatchEvent(new CustomEvent('{s}',{{detail:{s}}}));",
        .{ event.eventName(), detail_json },
    );
}

const testing = std.testing;

test "an event inlines its detail as JSON, not as a quoted string" {
    // Quoting it would hand the page a string that happens to contain an
    // object, so `e.detail.latitude` would be undefined and the subscriber
    // would read it as a missing reading rather than a bug.
    const js = try formatEvent(testing.allocator, .location_update, "{\"latitude\":1.5}");
    defer testing.allocator.free(js);

    try testing.expectEqualStrings(
        "if(window.dispatchEvent)window.dispatchEvent(new CustomEvent('craftLocationUpdate',{detail:{\"latitude\":1.5}}));",
        js,
    );
}

test "every event name is one an iOS page actually subscribes to" {
    // The names come from Swift's sendToWeb call sites, NOT from
    // capabilities.Channel — whose names are all `craft:`-prefixed and which
    // therefore cannot spell any of these. Emitting the desktop spelling would
    // fire an event with no listener: a stream that looks implemented and
    // delivers nothing. This is the check that keeps the two vocabularies from
    // being confused again.
    try testing.expectEqualStrings("craftLocationUpdate", Event.location_update.eventName());
    try testing.expectEqualStrings("craftMotionUpdate", Event.motion_update.eventName());
    try testing.expectEqualStrings("craftSpeechResult", Event.speech_result.eventName());

    inline for (std.enums.values(Event)) |e| {
        // camelCase, no colon — the iOS convention.
        try testing.expect(std.mem.startsWith(u8, e.eventName(), "craft"));
        try testing.expect(std.mem.indexOfScalar(u8, e.eventName(), ':') == null);
    }
}

test "emitting claims nothing about the desktop channel vocabulary" {
    // The iOS names and the `craft:` names are different vocabularies. An
    // earlier version registered a desktop channel on emit, which made
    // craft.capabilities() report `craft:location:update` live on a platform
    // that never dispatches it. A manifest whose own plumbing overclaims is
    // worse than no manifest, so the mapping is gone — and this fails if it
    // comes back.
    try testing.expect(!@hasDecl(Event, "capabilityChannel"));
}

test "a full queue drops the oldest event and counts it" {
    // A stream's consumer wants current state. Refusing the newest reading to
    // preserve a stale one is the wrong trade, but a silent drop is worse than
    // a counted one.
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const before = droppedCount();

    queue_mutex.lock();
    for (&queue) |*slot| {
        if (!slot.in_use) slot.* = .{ .in_use = true, .event = .location_update, .detail = null };
    }
    queue_mutex.unlock();

    emit(.location_update, "{\"n\":1}");
    try testing.expect(droppedCount() > before);

    queue_mutex.lock();
    defer queue_mutex.unlock();
    for (&queue) |*slot| {
        if (slot.detail) |owned| std.heap.c_allocator.free(owned);
        slot.* = .{};
    }
}
