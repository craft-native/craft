//! The geolocation actions of the `mobile` namespace: `getCurrentPosition`,
//! `watchPosition` and `clearWatch`.
//!
//! The last two were absent from the `A` block until now, for one recorded
//! reason: `ios_events.emit` took a `capabilities.Channel`, whose location
//! names are `craft:location:update` and `craft:location:error`, and no iOS
//! page listens for either — every subscriber in the injected JS listens for
//! `craftLocationUpdate`. A subscribe that resolves `true` and then delivers
//! nothing is fabricated success wearing a subscription, so the shim kept both.
//!
//! `ios_events` now carries its own `Event` enum taken from Swift's
//! `sendToWeb` call sites — `.location_update` *is* `"craftLocationUpdate"`,
//! `.location_error` *is* `"craftLocationError"`. The name can be spelled, so
//! the stream can be served, so both actions land here. Nothing else about the
//! argument changed: `clearWatch` still only makes sense in the same module as
//! `watchPosition`, and they migrate together.
//!
//! Two JS surfaces reach `getCurrentPosition`, and both end up in the same
//! place. The legacy `craft.geolocation.getCurrentPosition()` posts
//! `{action:'getCurrentPosition', callbackId: id}` and builds its `Promise`
//! by hand rather than through `_createCallback` — so it has **no timeout**;
//! an unanswered call parks the page forever. The v1 wrapper
//! `craft.location.getCurrentPosition(options)` forwards straight to it. That
//! is why every path below ends in a reply or an error, and why
//! `didFailWithError` must answer rather than log.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **No payload crosses the bridge.** `legacyGeolocation.getCurrentPosition`
//!    is declared `function()` — zero parameters — so the `options` object the
//!    v1 wrapper accepts (`enableHighAccuracy`, `timeout`, `maximumAge`, typed
//!    in `packages/typescript/src/api/mobile.ts`) is dropped by the *page*,
//!    before native sees anything. This is not a field this module drops: the
//!    field never arrives. `d` is therefore ignored rather than parsed, exactly
//!    as the Swift dispatcher reads nothing out of `body` for this action —
//!    parsing it would invent a way for the call to fail that the shim does not
//!    have.
//!  - **The reply is an object with eight keys**, from `didUpdateLocations`:
//!    `latitude`, `longitude`, `altitude`, `accuracy`, `altitudeAccuracy`,
//!    `heading`, `speed`, `timestamp`. Swift resolves a `[String: Any]`
//!    dictionary, and `.fragmentsAllowed` permits a bare value but never
//!    unwraps a dictionary into one. Swift's key order is a `Dictionary` and
//!    therefore arbitrary; one order is fixed here so the bytes are testable,
//!    the same call `bridge_mobile_notifications.zig` makes for `PendingList`.
//!  - **Three key names do not match their sources, and all three are easy to
//!    get wrong.** `accuracy` is `horizontalAccuracy`; `altitudeAccuracy` is
//!    `verticalAccuracy`; `heading` is **`course`** — the direction of travel,
//!    not a `CLHeading` compass reading, which nothing in this path ever asks
//!    for. The desktop's `bridge_location.zig` emits `horizontalAccuracy` and
//!    `verticalAccuracy` verbatim and has no `heading` at all; those are a
//!    different contract and copying them here would rename three fields out
//!    from under the page.
//!  - **CoreLocation's `-1` sentinels are passed through raw, not nulled.**
//!    The Swift dictionary has no `nil` checks, no `>= 0` guards and no
//!    coalescing, so an invalid `horizontalAccuracy`, `verticalAccuracy`,
//!    `speed` or `course` lands on the wire as `-1`. `Location.accuracy` is
//!    typed `number`, not `number | null`; nulling would be a divergence the
//!    page is not written for.
//!  - **`timestamp` is fractional milliseconds** — `timeIntervalSince1970 *
//!    1000`, an `f64`, not an integer.
//!
//! ## What is deliberately not carried across
//!
//! **The rejection text.** Swift rejects with `error.localizedDescription` and
//! the default code `CRAFT_ERROR`; `ios_async.deliverError` yields
//! `NativeCallFailed` → `NATIVE_CALL_FAILED`, because `sendErrorToJS` carries a
//! `BridgeError` enum and there is no free-text channel. Precedented loss —
//! `bridge_mobile_misc.zig` and `bridge_mobile_watch.zig` document the same
//! trade — and the `NSError` domain, code and `localizedDescription` are all
//! logged before the enum is chosen.
//!
//! **`didUpdateLocations` with an empty array.** Swift's `guard let location =
//! locations.last else { return }` replies nothing at all, which on an untimed
//! promise is a hang forever. Here it is an error. Same divergence, same
//! argument, as `bridge_mobile_watch.zig`'s missing-`context` note.
//!
//! **Swift's orphaned first caller.** `getCurrentPosition` assigns
//! `singleLocationCallbackId = callbackId` unconditionally, so a second call
//! while one is in flight overwrites the first id and the first promise never
//! settles. Here the displaced call is rejected instead — see "One native slot
//! for the one-shot, one flag for the watch, one mutex for both" below for the
//! cost that buys.
//!
//! **Nothing about `craftLocationError` any more.** A paragraph here used to
//! record that Swift's `didFailWithError` both rejects the caller *and* fires
//! `craftLocationError` while this module could only reject. It now does both,
//! in Swift's order, because `ios_events.Event.location_error` spells exactly
//! that name. Two things about it are worth keeping straight: nothing in the
//! injected JS or in `test-bridges.html` subscribes to `craftLocationError`
//! today — the only listeners anywhere are for `craftLocationUpdate` — so it
//! is emitted because the Swift app a page may have been written against emits
//! it, not because a subscriber is known to exist; and it is fired
//! *unconditionally*, exactly as Swift's is, rather than only while a watch is
//! running. A watch that hits an error has no reply left to reject — its
//! `true` went out when it started — so the event is the only channel it has.
//!
//! **The recording side effect.** Swift's `didUpdateLocations` calls
//! `appendRecordedLocation(data)` for *every* fix, including a one-shot
//! `requestLocation`, so calling `getCurrentPosition` during an active
//! recording appends one extra sample to the track that `readLocationRecording`
//! later returns. This module has its own `CLLocationManager`, so that sample
//! is no longer added. Arguably the more correct behaviour — a one-shot query
//! is not part of a route — but it *is* a behaviour change, and a page counting
//! samples will see one fewer.
//!
//! **One `craftLocationUpdate` per manager while a recording is running.** The
//! six `*LocationRecording` actions stay with the shim
//! (`bridge_mobile_locrecording.zig` serves only `readLocationRecording`), so a
//! recording runs Swift's manager and Swift's `didUpdateLocations`, which fires
//! `craftLocationUpdate` for every fix whenever `isRecordingLocation` is true —
//! watch or no watch. A page that records *and* watches therefore has two
//! managers feeding one event name, and its watch callback runs roughly twice
//! as often as it did under a single shared manager. Every one of those events
//! carries a real fix; none is fabricated and none is dropped. It is a
//! duplication, it is visible to a page that counts samples, and it disappears
//! when the recording actions migrate.
//!
//! The converse loss is gone rather than added to: a `getCurrentPosition`
//! issued while *this* module's watch is running is broadcast to the watch
//! subscribers again, because one `didUpdateLocations` settles the one-shot and
//! emits the same fix, exactly as Swift's does.
//!
//! ## The cross-action cost, stated rather than argued away
//!
//! `locationManager.delegate = self` is set in exactly four Swift places:
//! `getCurrentPosition`, `watchPosition`, `startLocationRecording` and
//! `restoreLocationRecordingState`. The `requestPermission` arm for
//! `location`/`locationAlways` does **not** set it — it only assigns
//! `locationPermissionCallbackId` and calls `requestWhenInUseAuthorization` —
//! and that request is settled *only* by
//! `locationManagerDidChangeAuthorization` firing on Swift's manager.
//! `bridge_mobile_permissions.zig` returns `UnknownAction` for those two
//! permission values, so `requestPermission('location')` is still shim-served.
//!
//! Taking `getCurrentPosition` into Zig — with Zig's own manager and its own
//! delegate — removes one of the two commonly-hit paths that gave Swift's
//! manager a delegate. `craft.permissions.request('location')` therefore
//! resolves in fewer orderings than before: it already fails today when it is
//! the first location call a page makes, and after this it also fails when
//! `getCurrentPosition` was the only call before it. Taking `watchPosition`
//! removes the *second* of those two paths: after this change the only things
//! left that give Swift's manager a delegate are `startLocationRecording` and
//! `restoreLocationRecordingState`. So `craft.permissions.request('location')`
//! now settles only in an app that has started or restored a recording. That is
//! a narrowing of an already-broken path rather than a new break — it was
//! already broken for the first location call any page makes — but it is
//! narrower than it was before this change, and the earlier wording ("watchPosition
//! and the three recording actions still install Swift's delegate") is no
//! longer true. The fix is to migrate `requestPermission` for location in
//! `bridge_mobile_permissions.zig`, which is a second file this pass is not
//! writing.
//!
//! ## What `watchPosition` and `clearWatch` owe the page, exactly
//!
//! **Neither carries a payload, and `clearWatch` carries no watch id.**
//! `nextLocationWatchId` is a pure JS-side map key: `craft.location.watchPosition`
//! hands the page an incrementing integer, keeps its callbacks in a `Map`, and
//! only posts to native when the map goes from empty to one and back. The
//! native side has a single on/off, and both JS surfaces post
//! `{action:'clearWatch'}` with no `id`. So the `id` is not a field this module
//! drops — it never crosses the bridge, exactly as `options` does not for
//! `getCurrentPosition`.
//!
//! **Both replies are the bare fragment `true`.** Swift is
//! `resolveCallback(callbackId, result: true)` for each, and `resolveCallback`
//! serialises with `.fragmentsAllowed`, which permits a bare value. Not
//! `{"ok":true}`, not `{"watchId":1}` — the opposite of
//! `bridge_mobile_watch.zig`, whose replies are objects because Swift resolved
//! dictionaries there. `craft-bridge.js` resolves with `payload || {}`, so a
//! falsy reply would arrive as `{}`; `true` stays truthy on purpose.
//!
//! **`watchPosition` replies synchronously.** Its `resolveCallback` is the last
//! line of the Swift method, straight after `startUpdatingLocation()` — it is
//! not a delegate callback and does not wait for a fix. So this module answers
//! through `bridge_error.sendResultToJS` inside the dispatch, and never leases
//! an `ios_async` slot for it. A slot would be held for the life of the
//! subscription and would narrow the pool for every other call.
//!
//! **The stream is the eight-key fix object, on `craftLocationUpdate`.**
//! `didUpdateLocations` builds one dictionary and both resolves it to the
//! one-shot and hands it to `sendToWeb`, so the event `detail` and the
//! `getCurrentPosition` reply are the *same shape*. That is why `shapeFix` runs
//! once below and its bytes are used twice.
//!
//! **`clearWatch` is not gated on `enableGeolocation`.** `case "clearWatch":`
//! in the Swift dispatcher has no capability check at all — unlike
//! `getCurrentPosition`, `watchPosition` and `startLocationRecording`, which
//! are each wrapped in one. So `clearWatch` here does not consult the
//! Info.plist gate either: a page can always stop a watch, including in an app
//! that could never have started one, where it is a no-op that still replies
//! `true`.
//!
//! ## One delegate, two consumers — the whole risk in this change
//!
//! The delegate now serves a one-shot `requestLocation` *and* a running
//! `startUpdatingLocation` at the same time, and they interact three ways.
//!
//! **A fix while both are live must settle the one-shot and emit, in that
//! order.** Swift's `didUpdateLocations` resolves `singleLocationCallbackId`
//! first, clears it, and only then calls `sendToWeb`. `takeDelegateWork` reads
//! both under one lock — taking the pending fix, leaving the watch — so the two
//! are one decision that cannot interleave, and `ios_async.deliverJson` is
//! enqueued before `ios_events.emit`. Both hops target `_dispatch_main_q`,
//! which is serial, so enqueue order *is* delivery order.
//!
//! It is worth being explicit about where that fix comes from, because
//! `requestLocation()` and `startUpdatingLocation()` are not designed to be
//! combined: with a watch running, a `getCurrentPosition` is answered by the
//! *stream's* next callback rather than by its own request, since one
//! `didUpdateLocations` serves whatever is waiting. Swift's shim has exactly
//! this arrangement on exactly one manager, so the behaviour is the same one
//! the page sees today — and it is why the one-shot is preferred as the source
//! of the shaping selectors: the reply is built from the selectors captured for
//! the call being answered.
//!
//! **A fix consumes the one-shot and never the watch.** A one-shot is answered
//! once; a subscription is answered until it is cleared. Clearing the watch the
//! way the pending fix is cleared would deliver exactly one event and then go
//! silent with the page's callback still registered — the failure mode that is
//! invisible from the page, because a stream has no way to say "that was the
//! last one".
//!
//! **`clearWatch` must not strand a one-shot.** CoreLocation documents
//! `stopUpdatingLocation()` as cancelling a pending `requestLocation()`, so the
//! fix that would have answered an in-flight `getCurrentPosition` is not
//! coming, and its promise is the untimed hand-built kind: a page parked
//! forever. So the stop takes the pending fix out with it, under the same lock,
//! and rejects it. Swift has the same cancellation and no such handling — it
//! relies on CoreLocation reporting the cancellation through `didFailWithError`,
//! which is not guaranteed. Rejecting is the same outcome, made certain.
//!
//! The point above closes the only door that might have been left open: with a
//! watch running, a pending one-shot would otherwise be answered by the
//! stream's next fix — but the stop ends the stream too, so after a
//! `clearWatch` there is no callback left from which any answer could come.
//!
//! The corollary is deliberate: a `clearWatch` that stops **nothing** takes
//! nothing. Swift's `stopWatchingPosition()` never consults
//! `isWatchingLocation` before calling `stopUpdatingLocation()` — its only
//! guard is `if !isRecordingLocation` — so in Swift a `clearWatch` with no
//! watch running still cancels an in-flight `getCurrentPosition`, provided no
//! recording is up. This module only stops what it started, so that one
//! survives. That is a divergence, it is in the direction of answering a caller
//! that Swift may leave hanging, and it is stated rather than smoothed over.
//!
//! One thing this module does *not* need and Swift does: the
//! `if !isRecordingLocation` guard in `stopWatchingPosition()`. That guard
//! exists because Swift's single manager serves the watch and the recorder at
//! once. The recording actions are shim-served against Swift's own manager, so
//! stopping *this* module's manager cannot interrupt a recording; there is no
//! Coordinator state to read, and no guard is claimed for one.
//!
//! ## `allowsBackgroundLocationUpdates`, and the exception it can raise
//!
//! CoreLocation raises an Objective-C exception when it is set to `YES` in a
//! process whose `UIBackgroundModes` lacks `location`, and an uncaught ObjC
//! exception is an uncatchable SIGABRT rather than an error to map — the same
//! class of hazard `bridge_mobile_notifcancel.zig`'s bundle guard exists for.
//!
//! `getCurrentPosition` still never touches it, because Swift's does not:
//! only `watchPosition` and the recording actions call
//! `configureBackgroundLocationIfNeeded()`. `watchPosition` does, gated on the
//! condition that actually throws — `UIBackgroundModes` containing `location`,
//! read from the running process — rather than on the usage-description key.
//! `packages/ios/src/index.ts` writes the mode (`:232`) and
//! `NSLocationAlwaysAndWhenInUseUsageDescription` (`:188`) from the same
//! `enableBackgroundLocation` flag, so in a generated app the two always agree
//! and this is exactly `config.enableBackgroundLocation`; in a hand-edited
//! plist carrying the usage string without the mode, inferring from the key
//! would be a crash rather than a divergence.
//!
//! It is set rather than left alone because leaving it alone is not free:
//! without it a watch stops delivering the moment the app is backgrounded, and
//! for an app that set `enableBackgroundLocation` that is the entire feature.
//! The page sees no error when that happens — the stream simply goes quiet — so
//! the one case where it genuinely cannot be set (a `CLLocationManager` that
//! does not respond to the selector at all) is logged rather than passed over.
//! `clearWatch` sets it back to NO, mirroring `stopWatchingPosition()`; setting
//! it to NO is safe in any process, because only YES can raise.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const ios_events = @import("ios_events.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The same type as `objc.id` — `?*anyopaque` — spelled locally, per the
/// notifications/watch precedent: `objc_runtime.objc` is an empty struct off
/// Darwin and a function *signature* is analysed even when a comptime platform
/// guard prunes the body, so naming `objc.id` in the `callconv(.c)` types below
/// would break the host build. A single optional pointer, never `?objc.id` — a
/// double optional is illegal in `callconv(.c)`.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches this block against those labels in
/// both directions, and fails the build if two modules declare one name.
///
/// An action listed here is an action taken away from the Swift shim, and that
/// trade is only worth making when Zig's answer is at least as good. For
/// `watchPosition` that turned on one fact — whether `ios_events` could spell
/// `craftLocationUpdate` — and it now can.
pub const A = struct {
    pub const get_current_position = "getCurrentPosition";
    pub const watch_position = "watchPosition";
    pub const clear_watch = "clearWatch";
};

/// `.result`: the Swift path terminates in exactly one `resolveCallback` (from
/// `didUpdateLocations`) or one `rejectCallback` (from `didFailWithError`), and
/// the JS promise is the untimed hand-built kind — `.none` here would strand a
/// caller forever rather than for thirty seconds.
///
/// `.live`: it dispatches and does the thing. `.unavailable` is for an action
/// that dispatches and refuses, which this is not — a refusal here is a
/// specific failure (geolocation not configured, pool full, CoreLocation
/// error), never the action's normal answer.
///
/// All three are `.result`, and for `watchPosition` and `clearWatch` that is
/// the *synchronous* kind: Swift resolves each with a bare `true` from the
/// dispatcher itself. `.none` would be wrong for a different reason there —
/// `craft._invoke` awaits both, and an unanswered await is a thirty-second
/// stall followed by a timeout rejection for a subscription that is actually
/// running.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.get_current_position, .reply = .result },
    .{ .name = A.watch_position, .reply = .result },
    .{ .name = A.clear_watch, .reply = .result },
};

/// The reply `watchPosition` and `clearWatch` send.
///
/// Swift's `resolveCallback(callbackId, result: true)` through
/// `.fragmentsAllowed` is the bare fragment `true` — not `{"ok":true}`, and not
/// a watch id, which is a JS-side map key that never crosses the bridge. Static,
/// so replying allocates nothing.
const true_fragment = "true";

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host without touching
/// CoreLocation.
const Route = enum { current_position, watch_position, clear_watch };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.get_current_position)) return .current_position;
    if (std.mem.eql(u8, action, A.watch_position)) return .watch_position;
    if (std.mem.eql(u8, action, A.clear_watch)) return .clear_watch;
    return null;
}

pub const LocationBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const route = routeFor(action) orelse return bridge_error.BridgeError.UnknownAction;
        // Exhaustive, so a `Route` without a handler is a compile error.
        return switch (route) {
            .current_position => self.getCurrentPosition(data),
            .watch_position => self.watchPosition(data),
            .clear_watch => self.clearWatch(data),
        };
    }

    /// Ask CoreLocation for one fix and answer when it arrives.
    ///
    /// `data` is accepted and ignored: the page drops `options` before posting
    /// (`legacyGeolocation.getCurrentPosition` takes no parameters) and the
    /// Swift dispatcher reads nothing out of `body`. Parsing it would invent a
    /// failure mode the shim does not have.
    ///
    /// Every fallible step — the Info.plist gate, all nine reply selectors, the
    /// delegate class, the manager, the two request selectors — runs *before*
    /// `ios_async.acquire`, so there is no error path between leasing a slot
    /// and handing the request to the framework. A failure after the lease
    /// would have to release the slot by hand, and a missed release is a
    /// permanently narrower pool.
    fn getCurrentPosition(self: *Self, data: []const u8) !void {
        _ = self;
        _ = data;
        if (!is_darwin) return error.UnsupportedPlatform;

        const authorization = try resolveAuthorization();
        const sels = try Sels.resolve();
        const mgr = try ensureManager();

        const auth_selector_name: [*:0]const u8 = switch (authorization) {
            .always => "requestAlwaysAuthorization",
            .when_in_use => "requestWhenInUseAuthorization",
        };
        const sel_authorize = try selector(auth_selector_name);
        const sel_request = try selector("requestLocation");

        const ticket = ios_async.acquire(A.get_current_position) orelse return poolFull();

        // Published before the framework call, never after: `requestLocation`
        // is asynchronous but the delegate can in principle be reached before
        // `msgSend` returns, and a callback that arrived at an empty slot would
        // have no ticket to reply with.
        if (publishPendingFix(ticket, sels)) |displaced| {
            // Swift overwrites `singleLocationCallbackId` here and the first
            // caller's untimed promise never settles. Rejecting it is strictly
            // better: every caller ends up settled. See "One native slot for
            // the one-shot, ..." below for what this costs.
            std.log.warn(
                "getCurrentPosition: a second call displaced one still in flight; " ++
                    "rejecting the first rather than orphaning it",
                .{},
            );
            ios_async.deliverError(displaced.ticket);
        }

        objc.msgSend(mgr, sel_authorize);
        objc.msgSend(mgr, sel_request);
    }

    /// Start the continuous stream, and answer `true` for having started it.
    ///
    /// Swift's order is delegate, `isWatchingLocation = true`,
    /// `requestLocationAuthorization()`, `configureBackgroundLocationIfNeeded()`,
    /// `startUpdatingLocation()`, `resolveCallback(… true)`, and that order is
    /// kept: the watch is published *before* the framework call, because a fix
    /// that reached the delegate first would find no watch recorded and be
    /// dropped as a stray.
    ///
    /// `data` is accepted and ignored, as it is for `getCurrentPosition`. Both
    /// JS surfaces post the action alone — the legacy
    /// `geolocation.watchPosition(callback)` keeps its callback in the page and
    /// the v1 `craft.location.watchPosition(callback)` keeps its callback in a
    /// `Map` — so there is no field here to drop.
    ///
    /// Calling it twice is what the page does when a second subscriber appears
    /// after a `clearWatch` raced it, and it is idempotent in Swift: the flag is
    /// re-set, authorization re-requested, `startUpdatingLocation` re-issued
    /// (a documented no-op on a manager already updating), `true` re-resolved.
    /// It is idempotent here for the same reasons.
    ///
    /// Every fallible step runs before the watch is published, so there is no
    /// error path between recording a subscription and starting the stream that
    /// would leave the module believing it is watching when nothing is running.
    fn watchPosition(self: *Self, data: []const u8) !void {
        _ = data;
        if (!is_darwin) return error.UnsupportedPlatform;

        const authorization = try resolveAuthorization();
        const sels = try Sels.resolve();
        const background = try backgroundLocationDeclared();
        const mgr = try ensureManager();

        const auth_selector_name: [*:0]const u8 = switch (authorization) {
            .always => "requestAlwaysAuthorization",
            .when_in_use => "requestWhenInUseAuthorization",
        };
        const sel_authorize = try selector(auth_selector_name);
        const sel_start = try selector("startUpdatingLocation");
        const sel_responds = try selector("respondsToSelector:");
        const sel_allows_background = try selector("setAllowsBackgroundLocationUpdates:");
        const sel_shows_indicator = try selector("setShowsBackgroundLocationIndicator:");

        publishWatch(sels);

        objc.msgSend(mgr, sel_authorize);

        if (background) {
            // `configureBackgroundLocationIfNeeded()`, under the guard that
            // makes it safe. Both properties take the same value in Swift, and
            // both are set to it here.
            if (!setBoolIfSupported(mgr, sel_responds, sel_allows_background, true)) {
                std.log.warn(
                    "watchPosition: this CLLocationManager has no " ++
                        "allowsBackgroundLocationUpdates; the watch will stop when the app " ++
                        "is backgrounded even though UIBackgroundModes declares location",
                    .{},
                );
            }
            // Purely the status-bar indicator. A manager without it is an OS too
            // old for the property, not a broken subscription, so it is not
            // worth a warning of its own.
            _ = setBoolIfSupported(mgr, sel_responds, sel_shows_indicator, true);
        }

        objc.msgSend(mgr, sel_start);

        bridge_error.sendResultToJS(self.allocator, A.watch_position, true_fragment);
    }

    /// Stop the stream this module started, and answer `true`.
    ///
    /// No Info.plist gate: `case "clearWatch":` in the Swift dispatcher carries
    /// no `config.enableGeolocation` check, so borrowing `getCurrentPosition`'s
    /// gate would refuse a stop the shim always performs.
    ///
    /// `data` is ignored, and there is no watch id in it to ignore — see the
    /// module comment. Stopping is unconditional in the sense that matters: the
    /// page gets `true` whether or not anything was running, exactly as Swift
    /// does, because "there is no watch" and "the watch is now stopped" are the
    /// same state from a caller's point of view.
    fn clearWatch(self: *Self, data: []const u8) !void {
        _ = data;
        if (!is_darwin) return error.UnsupportedPlatform;

        // All three selectors resolved while an error is still deliverable, and
        // before any state changes: a failure after `takeWatchAndPending` would
        // leave the module reporting no watch while the manager kept updating.
        const sel_stop = try selector("stopUpdatingLocation");
        const sel_responds = try selector("respondsToSelector:");
        const sel_allows_background = try selector("setAllowsBackgroundLocationUpdates:");

        const stop = takeWatchAndPending();

        // `stopUpdatingLocation` cancels a pending `requestLocation`, so a
        // one-shot in flight is not going to be answered by CoreLocation. Its
        // promise has no timeout, so leaving it is a page parked forever.
        //
        // Settled *here*, above every remaining exit from this function, rather
        // than after the stop: `takeWatchAndPending` has already removed it from
        // `pending_fix` under the lock, so no delegate callback can find it any
        // more. From that line on, the only question is whether anybody tells
        // the caller — and any path that returns without answering strands it.
        // The manager lookup below is such a path.
        //
        // Null whenever `stop.watching` is false: nothing was stopped, so
        // nothing was cancelled, so there is nothing to reject.
        if (stop.pending) |call| {
            std.log.warn(
                "clearWatch: stopUpdatingLocation cancels the in-flight getCurrentPosition; " ++
                    "rejecting it rather than leaving its promise unsettled",
                .{},
            );
            ios_async.deliverError(call.ticket);
        }

        if (!stop.watching) {
            // Nothing of ours is running, so nothing is stopped and — unlike
            // Swift — no in-flight `getCurrentPosition` is cancelled.
            bridge_error.sendResultToJS(self.allocator, A.clear_watch, true_fragment);
            return;
        }

        const mgr = manager orelse {
            // Not reachable: a watch is only ever published after
            // `ensureManager` returned, and `manager` is never cleared. Saying
            // so beats replying `true` for a stop with nothing behind it.
            std.log.err("clearWatch: a watch was recorded with no CLLocationManager behind it", .{});
            return bridge_error.BridgeError.NativeCallFailed;
        };

        objc.msgSend(mgr, sel_stop);
        // Mirrors `stopWatchingPosition()`'s `allowsBackgroundLocationUpdates =
        // false`. Setting it to NO is safe in any process — only YES can raise.
        _ = setBoolIfSupported(mgr, sel_responds, sel_allows_background, false);

        bridge_error.sendResultToJS(self.allocator, A.clear_watch, true_fragment);
    }
};

/// The answer for a full block pool, copied from `bridge_mobile_permissions`:
/// `BridgeError` has no "Busy", INVALID_PARAMETER is the migration notes'
/// designated stand-in, and the point is that the seventeenth concurrent call
/// gets an explicit rejection instead of a promise that never settles.
fn poolFull() bridge_error.BridgeError {
    std.log.warn(
        "getCurrentPosition refused: all {d} async slots in flight",
        .{ios_async.max_in_flight},
    );
    return bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// Reply shaping. Pure — no Objective-C — so the exact bytes the page receives
// are pinned by host tests on every platform.
// =============================================================================

/// One CLLocation, read into plain doubles.
///
/// The fields are named for their **sources**, not for the wire keys they fill,
/// so `shapeFix` has to perform the three renames visibly and a test can pin
/// them. Getting `heading` <- `course` or `accuracy` <- `horizontalAccuracy`
/// backwards is silent: every value is a plausible-looking double.
const Fix = struct {
    latitude: f64,
    longitude: f64,
    altitude: f64,
    horizontal_accuracy: f64,
    vertical_accuracy: f64,
    course: f64,
    speed: f64,
    /// `timeIntervalSince1970 * 1000` — fractional milliseconds, not an integer.
    timestamp_ms: f64,
};

/// The eight-key object Swift's `didUpdateLocations` resolves.
///
/// Key order is fixed at latitude, longitude, altitude, accuracy,
/// altitudeAccuracy, heading, speed, timestamp. Swift's is a `Dictionary` and
/// therefore arbitrary; a caller cannot depend on it, but a *test* can only pin
/// bytes that are deterministic, so one order is chosen and held.
fn shapeFix(allocator: std.mem.Allocator, fix: Fix) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"latitude\":");
    try appendNumber(allocator, &out, fix.latitude);
    try out.appendSlice(allocator, ",\"longitude\":");
    try appendNumber(allocator, &out, fix.longitude);
    try out.appendSlice(allocator, ",\"altitude\":");
    try appendNumber(allocator, &out, fix.altitude);
    // `accuracy`, not `horizontalAccuracy`: the desktop bridge uses the raw
    // property name and is a different contract.
    try out.appendSlice(allocator, ",\"accuracy\":");
    try appendNumber(allocator, &out, fix.horizontal_accuracy);
    try out.appendSlice(allocator, ",\"altitudeAccuracy\":");
    try appendNumber(allocator, &out, fix.vertical_accuracy);
    // `heading` is `-[CLLocation course]`, the direction of travel, and never
    // a `CLHeading` compass reading — nothing in this path asks for one.
    try out.appendSlice(allocator, ",\"heading\":");
    try appendNumber(allocator, &out, fix.course);
    try out.appendSlice(allocator, ",\"speed\":");
    try appendNumber(allocator, &out, fix.speed);
    try out.appendSlice(allocator, ",\"timestamp\":");
    try appendNumber(allocator, &out, fix.timestamp_ms);
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

/// One `f64` as a JSON number.
///
/// `{d}` renders decimal notation, never scientific, and a finite `f64` can
/// need up to `std.fmt.float.bufferSize(.decimal, f64)` (347) bytes — 1e300
/// alone is 301 digits. This payload is eight doubles wide and a `[64]u8`
/// anywhere in it would turn a legal reading into a `NoSpaceLeft` refusal.
///
/// Non-finite is refused rather than printed: `inf` and `nan` are not JSON, and
/// Swift's own `JSONSerialization` refuses them too. A refusal reaches the page
/// as a rejection; printing them would produce a syntax error inside the reply
/// script with nothing to point at.
fn appendNumber(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: f64,
) !void {
    if (!std.math.isFinite(value)) return bridge_error.BridgeError.InvalidParameter;
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{value}));
}

/// The `craftLocationError` detail: Swift's `["message": error.localizedDescription]`,
/// which is `{"message":"…"}` on the wire. One key, no `code` and no `domain` —
/// the `NSError` carries both and Swift puts neither on the bridge, so adding
/// them would be a shape no page is written for.
///
/// The description is free text: locale-dependent, device-dependent, and
/// occasionally quoting a file path back at you. `ios_events.formatEvent`
/// inlines this detail into a JavaScript source position verbatim, so it is
/// escaped with the shared `bridge_error.escapeJsonString` and never
/// interpolated with a bare `{s}` — an unescaped `"` would close the string
/// early and turn the whole `dispatchEvent` call into a syntax error in the
/// page, with nothing to point at.
///
/// The scratch buffer is sized from the input rather than fixed: the worst case
/// is six output bytes per input byte (a control byte becoming `\u001f`), and a
/// fixed buffer would silently turn a long localised error into a dropped event.
fn shapeLocationError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const scratch = try allocator.alloc(u8, message.len * 6 + 1);
    defer allocator.free(scratch);

    const escaped = try bridge_error.escapeJsonString(scratch, message);
    return std.fmt.allocPrint(allocator, "{{\"message\":\"{s}\"}}", .{escaped});
}

// =============================================================================
// The Info.plist gate, which stands in for two config flags Zig cannot see.
// =============================================================================

/// Which authorization Swift's `requestLocationAuthorization()` would ask for.
const Authorization = enum { when_in_use, always };

/// Emitted into Info.plist by `packages/ios/src/index.ts` iff
/// `enableGeolocation || enableBackgroundLocation`.
const key_when_in_use = "NSLocationWhenInUseUsageDescription";

/// Emitted iff `enableBackgroundLocation` — the same condition that selects
/// `requestAlwaysAuthorization` in Swift.
const key_always = "NSLocationAlwaysAndWhenInUseUsageDescription";

/// Decide, from evidence in the running process, whether geolocation was
/// configured and which prompt to ask for.
///
/// Neither `config.enableGeolocation` nor `config.enableBackgroundLocation` has
/// a Zig mirror — they appear nowhere in `packages/zig/src` outside a comment —
/// which is the same gap `bridge_mobile_watch.zig` documents for
/// `enableWatchApp`. Rather than guess, this reads the Info.plist keys the
/// generator writes from exactly those flags. Apple requires the usage
/// description before authorization may be requested at all, so its absence is
/// both the honest signal that the app was never built for location and the
/// condition under which requesting would be illegitimate; the refusal happens
/// before any request is made, so what the system would otherwise do never
/// arises.
///
/// Two divergences, both real and neither hideable:
///
///  - Swift rejects a disabled-geolocation call with `CAPABILITY_DISABLED`.
///    `bridge_error.BridgeError` has no such member; `PermissionDenied` ->
///    `PERMISSION_DENIED` is the nearest thing the protocol can say.
///  - The when-in-use key is written for `enableGeolocation ||
///    enableBackgroundLocation`, so the plist alone cannot tell those two
///    flags apart. They cannot normally disagree: `packages/ios/src/index.ts`
///    normalises the pair — `if (config.enableBackgroundLocation)
///    config.enableGeolocation = true` — before it writes *both*
///    `craft.config.json`, which is the file Swift decodes out of the bundle
///    at runtime, and the Info.plist, so a generated app answers the same on
///    both sides. The residual gap is a bundled `craft.config.json` edited by
///    hand afterwards: Swift would read `enableGeolocation: false` and refuse
///    where this gate, reading a plist nobody regenerated, opens. That
///    widening runs in the direction the Info.plist already sanctions — the
///    usage string exists, so the user sees a prompt the app declared — but it
///    is still a widening.
fn resolveAuthorization() !Authorization {
    if (!is_darwin) return error.UnsupportedPlatform;

    if (!try infoPlistHas(key_when_in_use)) {
        // Not "getCurrentPosition refused": `watchPosition` takes this same
        // gate, and a log line that names the wrong action sends whoever reads
        // it to the wrong call site.
        std.log.warn(
            "location refused: Info.plist has no {s}, so this app was not built " ++
                "with geolocation enabled",
            .{key_when_in_use},
        );
        return bridge_error.BridgeError.PermissionDenied;
    }

    return if (try infoPlistHas(key_always)) .always else .when_in_use;
}

/// The main bundle's Info.plist value for `key`, or null when it has none.
///
/// Errors rather than answering null when the runtime itself will not
/// cooperate: "there is no NSBundle class" and "this app did not ask for
/// location" are different facts, and collapsing them would blame the app's
/// configuration for a broken process.
fn infoPlistValue(comptime key: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSBundle = objc.objc_getClass("NSBundle") orelse return error.ClassNotFound;
    const sel_main = objc.sel_registerName("mainBundle") orelse return error.SelectorNotFound;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return error.NoMainBundle;

    const NSString = objc.objc_getClass("NSString") orelse return error.ClassNotFound;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse
        return error.SelectorNotFound;
    const ns_key = objc.msgSendId1(NSString, sel_string, key) orelse return error.NativeCallFailed;

    const sel_lookup = objc.sel_registerName("objectForInfoDictionaryKey:") orelse
        return error.SelectorNotFound;
    return objc.msgSendId1(bundle, sel_lookup, ns_key);
}

/// Whether the main bundle's Info.plist carries `key`.
fn infoPlistHas(comptime key: [*:0]const u8) !bool {
    return (try infoPlistValue(key)) != null;
}

/// The array `configureBackgroundLocationIfNeeded()` needs to have been told
/// about before `allowsBackgroundLocationUpdates` may be set to YES.
const key_background_modes = "UIBackgroundModes";

/// Whether this process declared the `location` background mode.
///
/// This is the *exact* precondition for `allowsBackgroundLocationUpdates = YES`:
/// CoreLocation raises an exception when it is set in a process whose
/// `UIBackgroundModes` lacks `location`, and an uncaught Objective-C exception
/// is an uncatchable SIGABRT rather than an error to map. Reading the array
/// itself tests the condition that actually throws.
///
/// It is also, in a generated app, exactly `config.enableBackgroundLocation`:
/// `packages/ios/src/index.ts` writes the mode and
/// `NSLocationAlwaysAndWhenInUseUsageDescription` from that one flag. Inferring
/// it from the usage-description key instead would agree in every generated app
/// and be a crash in a hand-edited plist that carries the string without the
/// mode — which is the wrong direction to be wrong in.
///
/// A missing key is `false`, not an error: an app that declared no background
/// modes is the ordinary case, and it is the same answer as
/// `enableBackgroundLocation: false`.
fn backgroundLocationDeclared() !bool {
    if (!is_darwin) return error.UnsupportedPlatform;

    const modes = (try infoPlistValue(key_background_modes)) orelse return false;

    const sel_contains = objc.sel_registerName("containsObject:") orelse
        return error.SelectorNotFound;
    const sel_responds = objc.sel_registerName("respondsToSelector:") orelse
        return error.SelectorNotFound;

    const RespondsFn = *const fn (Id, Id, Id) callconv(.c) bool;
    const responds: RespondsFn = @ptrCast(&objc.objc_msgSend);

    // A plist whose `UIBackgroundModes` is a string rather than an array is a
    // broken plist; sending `containsObject:` to it is an unrecognised selector
    // and therefore a SIGABRT. Asking first turns that into a `false`.
    if (!responds(modes, sel_responds, sel_contains)) {
        std.log.warn(
            "watchPosition: {s} is present but does not respond to containsObject:; " ++
                "treating background location as undeclared",
            .{key_background_modes},
        );
        return false;
    }

    const NSString = objc.objc_getClass("NSString") orelse return error.ClassNotFound;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse
        return error.SelectorNotFound;
    const ns_location = objc.msgSendId1(NSString, sel_string, @as([*:0]const u8, "location")) orelse
        return error.NativeCallFailed;

    const ContainsFn = *const fn (Id, Id, Id) callconv(.c) bool;
    const contains: ContainsFn = @ptrCast(&objc.objc_msgSend);
    return contains(modes, sel_contains, ns_location);
}

/// Set a `BOOL` property, but only if the receiver actually has it. Returns
/// whether it was set, so a caller that cares can say so.
///
/// `allowsBackgroundLocationUpdates` is iOS 9+ and
/// `showsBackgroundLocationIndicator` iOS 11+, and neither exists on the macOS
/// `CLLocationManager` this file is also compiled against. An unrecognised
/// selector is a SIGABRT rather than an error, so `respondsToSelector:` is the
/// guard — a deployment-target comparison would be a claim about the build
/// rather than a check on the object in hand.
fn setBoolIfSupported(target: Id, sel_responds: Id, sel: Id, value: bool) bool {
    if (!is_darwin) return false;

    const RespondsFn = *const fn (Id, Id, Id) callconv(.c) bool;
    const responds: RespondsFn = @ptrCast(&objc.objc_msgSend);
    if (!responds(target, sel_responds, sel)) return false;

    const SetFn = *const fn (Id, Id, bool) callconv(.c) void;
    const set: SetFn = @ptrCast(&objc.objc_msgSend);
    set(target, sel, value);
    return true;
}

// =============================================================================
// The delegate class, built at runtime.
//
// Follows `ios.zig`'s `installScriptMessageHandler` exactly: `objc_getClass`
// first so a second call is a no-op, then `objc_allocateClassPair`,
// `class_addMethod` with the right type encoding, `objc_registerClassPair`.
// =============================================================================

/// Deliberately *not* `"CraftLocationDelegate"`.
///
/// `bridge_location.zig` registers that name for the desktop, and it is
/// compiled into this module's graph on a macOS host runner (`bridge.zig`
/// imports `macos.zig`, which imports `bridge_location.zig`). Both files look
/// the class up with `objc_getClass` first, so whichever registered second
/// would silently adopt the other's class — and the other's IMPs, which read
/// different properties and fire different events.
const delegate_class_name = "CraftIOSLocationDelegate";

/// The delegate instance, held for the life of the process.
///
/// `CLLocationManager` holds its delegate **weakly**; a released delegate is a
/// crash the next time a fix arrives. This var is the strong reference.
var delegate_instance: Id = null;

/// The one `CLLocationManager` this module owns.
///
/// Module-level for the same reason as the delegate: a manager that goes out of
/// scope stops delivering. One per process, created on first use from the main
/// thread (dispatch runs synchronously from `craftDidReceiveScriptMessage`, a
/// WebKit main-thread callback), which is also where CoreLocation wants it so
/// the delegate callbacks land on the main run loop.
var manager: Id = null;

fn selector(name: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.sel_registerName(name) orelse error.SelectorNotFound;
}

/// Register the delegate class once, and keep one instance alive.
fn ensureDelegate() !*anyopaque {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (delegate_instance) |existing| return existing;

    var cls = objc.objc_getClass(delegate_class_name);
    if (cls == null) {
        // Both selectors resolved before the class pair is allocated: a failure
        // between `objc_allocateClassPair` and `objc_registerClassPair` leaves
        // an unregistered class behind that nothing can dispose of.
        const sel_update = try selector("locationManager:didUpdateLocations:");
        const sel_fail = try selector("locationManager:didFailWithError:");

        const NSObject = objc.objc_getClass("NSObject") orelse return error.ClassNotFound;
        cls = objc.objc_allocateClassPair(NSObject, delegate_class_name, 0) orelse
            return error.ClassAllocationFailed;

        // v@:@@ — returns void, takes self, _cmd, the manager, and one object
        // (the NSArray of CLLocation, or the NSError).
        if (!objc.class_addMethod(cls, sel_update, @ptrCast(&didUpdateLocations), "v@:@@")) {
            return error.MethodNotAdded;
        }
        if (!objc.class_addMethod(cls, sel_fail, @ptrCast(&didFailWithError), "v@:@@")) {
            return error.MethodNotAdded;
        }
        objc.objc_registerClassPair(cls);
    }

    // `locationManagerDidChangeAuthorization:` is deliberately not added.
    // Swift implements it purely to settle a pending `requestPermission`, which
    // this module does not serve, and it emits nothing: no iOS page subscribes
    // to any authorization event, so there is no `craft:location:authChanged`
    // contract on this platform to honour. Adding the method would mean
    // inventing one. CoreLocation dispatches through `respondsToSelector:`, so
    // omitting it is legal, exactly as `ios.zig`'s handler declares no protocol.

    const instance = (try objc.allocInit(cls)) orelse return error.NativeCallFailed;
    delegate_instance = instance;
    return instance;
}

/// `kCLLocationAccuracyBest`, if the symbol is in the process.
///
/// It is an `extern const CLLocationAccuracy` — a `double` variable — whose
/// value is not in the header, so hardcoding one would be a guess. `dlsym` it
/// out of whatever loaded CoreLocation, as `bridge_mobile_permissions.zig` does
/// for `AVMediaTypeVideo`. A null answer is not a failure: Apple documents
/// `desiredAccuracy`'s default as `kCLLocationAccuracyBest` already, so leaving
/// the property alone lands on the same value Swift assigns.
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// dyld's "search every image" pseudo-handle, (void *)-2 on Darwin.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

fn bestAccuracy() ?f64 {
    if (!is_darwin) return null;
    const symbol = dlsym(RTLD_DEFAULT, "kCLLocationAccuracyBest") orelse return null;
    const cell: *const f64 = @ptrCast(@alignCast(symbol));
    return cell.*;
}

/// `CLActivityTypeFitness`. A header enum constant — `Other = 1`,
/// `AutomotiveNavigation = 2`, `Fitness = 3` — so this one is safe to spell out.
const cl_activity_type_fitness: c_long = 3;

/// Build the manager once, configured the way `CraftApp.swift` configures its
/// own at construction, with this module's delegate attached.
///
/// All three properties Swift sets are now load-bearing on this manager.
/// `desiredAccuracy` governs the one-shot `requestLocation`; `activityType` and
/// `pausesLocationUpdatesAutomatically` govern automatic pausing during the
/// continuous updates `watchPosition` starts — an earlier revision of this
/// comment called those two inert, which was true only while `watchPosition`
/// belonged to the shim. `pausesLocationUpdatesAutomatically` is `false` because
/// Swift sets it false: a manager that pauses itself stops calling the delegate
/// and the page's watch callback simply goes quiet.
fn ensureManager() !*anyopaque {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (manager) |existing| return existing;

    const CLLocationManager = objc.objc_getClass("CLLocationManager") orelse
        return error.ClassNotFound;

    // The delegate first: a manager that exists with no delegate would be
    // cached by the line below and never deliver anything.
    const delegate = try ensureDelegate();

    const sel_set_delegate = try selector("setDelegate:");
    const sel_activity = try selector("setActivityType:");
    const sel_pauses = try selector("setPausesLocationUpdatesAutomatically:");

    const created = (try objc.allocInit(CLLocationManager)) orelse return error.NativeCallFailed;

    objc.msgSendVoid1(created, sel_set_delegate, delegate);

    if (bestAccuracy()) |accuracy| {
        const sel_accuracy = try selector("setDesiredAccuracy:");
        const AccuracyFn = *const fn (Id, Id, f64) callconv(.c) void;
        const set_accuracy: AccuracyFn = @ptrCast(&objc.objc_msgSend);
        set_accuracy(created, sel_accuracy, accuracy);
    } else {
        // `ensureManager` runs for `watchPosition` too, so this is not
        // `getCurrentPosition`'s line to claim.
        std.log.info(
            "location: kCLLocationAccuracyBest is not in this process; " ++
                "leaving desiredAccuracy at its default, which Apple documents as the same value",
            .{},
        );
    }

    const ActivityFn = *const fn (Id, Id, c_long) callconv(.c) void;
    const set_activity: ActivityFn = @ptrCast(&objc.objc_msgSend);
    set_activity(created, sel_activity, cl_activity_type_fitness);

    const PausesFn = *const fn (Id, Id, bool) callconv(.c) void;
    const set_pauses: PausesFn = @ptrCast(&objc.objc_msgSend);
    set_pauses(created, sel_pauses, false);

    manager = created;
    return created;
}

// =============================================================================
// The selectors the delegate needs, resolved while an error is still deliverable.
// =============================================================================

/// Everything `didUpdateLocations` will send, looked up at dispatch time.
///
/// The delegate runs after the dispatch frame is gone; a `sel_registerName`
/// failure in there could only be logged, or worse, turned into a rejection for
/// a fix that actually arrived. Resolving them here makes that class of failure
/// an ordinary synchronous error the page can see.
///
/// Both consumers capture a set: `getCurrentPosition` stores one on its
/// `PendingFix`, `watchPosition` stores one in `watch_sels`. The nine names are
/// the same either way — the split exists so that neither consumer's stream
/// depends on the other having run first, and so that a watch which outlives
/// every one-shot still has selectors of its own to shape events with.
const Sels = struct {
    last_object: Id,
    coordinate: Id,
    altitude: Id,
    horizontal_accuracy: Id,
    vertical_accuracy: Id,
    course: Id,
    speed: Id,
    timestamp: Id,
    time_interval_since_1970: Id,

    fn resolve() !Sels {
        if (!is_darwin) return error.UnsupportedPlatform;
        return .{
            // Swift uses `locations.last`, so `lastObject` matches exactly and
            // returns nil for an empty array — no count/objectAtIndex:
            // arithmetic, and no chance of an off-by-one on the boundary.
            .last_object = try selector("lastObject"),
            .coordinate = try selector("coordinate"),
            .altitude = try selector("altitude"),
            .horizontal_accuracy = try selector("horizontalAccuracy"),
            .vertical_accuracy = try selector("verticalAccuracy"),
            .course = try selector("course"),
            .speed = try selector("speed"),
            .timestamp = try selector("timestamp"),
            .time_interval_since_1970 = try selector("timeIntervalSince1970"),
        };
    }
};

// =============================================================================
// One native slot for the one-shot, one flag for the watch, one mutex for both.
//
// Swift keeps a single `singleLocationCallbackId`, and so does this: there is
// one manager and one delegate, and `didUpdateLocations` cannot tell two
// overlapping `requestLocation`s apart. The slot is guarded by a mutex even
// though CoreLocation delivers on the run loop that created the manager (the
// main one), because "it should always be the main thread" is not a guard.
//
// Displacement, not refusal, is the policy. Refusing a second call while one is
// pending would be tidier, but a slot that never clears — a fix that never
// arrives, an authorization prompt left unanswered — would then refuse every
// later call for the life of the process. Displacement cannot get stuck.
//
// What it costs: CoreLocation may report a cancelled `requestLocation` through
// `didFailWithError`, which would consume the *surviving* caller's ticket and
// reject it even though a fix follows. That is a wrong answer in the safe
// direction — an error where a reading was available — never a reading that is
// not real.
//
// The watch is the opposite kind of state and is stored differently for that
// reason. A one-shot is a *ticket* — one reply, consumed on the first callback,
// displaced by a newer caller. A watch is a *mode* — no reply after its initial
// `true`, answered by every callback, and idempotent to re-enter, because the
// page's own `Map` of callbacks is the thing that actually counts subscribers
// and it only ever posts on the empty-to-one and one-to-empty transitions.
// =============================================================================

const PendingFix = struct {
    ticket: ios_async.Ticket,
    sels: Sels,
};

var pending_fix: ?PendingFix = null;

/// The selectors the running watch shapes its events with, or null when no
/// watch is running.
///
/// It doubles as Swift's `isWatchingLocation` flag, because the two are always
/// set and cleared together and a separate boolean could disagree with it. The
/// selectors are captured at dispatch for the same reason the one-shot's are:
/// `sel_registerName` failing inside a delegate callback could only be logged,
/// and a watch is a callback that runs for as long as the page is subscribed.
var watch_sels: ?Sels = null;

/// Guards *both* of the above, deliberately.
///
/// One `didUpdateLocations` has to settle the one-shot and feed the watch, and
/// one `clearWatch` has to stop the watch and take the one-shot down with it.
/// Two locks would let those two pairs interleave; one lock makes each pair a
/// single decision. It is held even though CoreLocation delivers on the run loop
/// that created the manager, because "it should always be the main thread" is
/// not a guard.
var state_mutex: compat_mutex.Mutex = .{};

/// Record the call the delegate will answer, returning whatever it displaced so
/// the caller can reject that one rather than drop it.
fn publishPendingFix(ticket: ios_async.Ticket, sels: Sels) ?PendingFix {
    state_mutex.lock();
    defer state_mutex.unlock();
    const displaced = pending_fix;
    pending_fix = .{ .ticket = ticket, .sels = sels };
    return displaced;
}

/// Read and clear the slot. Clearing is what makes a second delegate call — a
/// late fix, a duplicate error — a no-op rather than a second reply.
fn takePendingFix() ?PendingFix {
    state_mutex.lock();
    defer state_mutex.unlock();
    const call = pending_fix;
    pending_fix = null;
    return call;
}

/// Record the running watch. Overwriting is the whole behaviour: a second
/// `watchPosition` is idempotent in Swift, and the selectors are the same ones.
fn publishWatch(sels: Sels) void {
    state_mutex.lock();
    defer state_mutex.unlock();
    watch_sels = sels;
}

/// What a delegate callback is answering: a one-shot, a watch, or both.
const DelegateWork = struct {
    /// Taken, and therefore cleared — a fix answers a one-shot exactly once.
    pending: ?PendingFix,
    /// Read, and deliberately *not* cleared — a fix feeds a watch every time,
    /// until `clearWatch` stops it. Clearing it here would deliver one event
    /// and then go silent with the page's callback still registered.
    watch: ?Sels,
};

fn takeDelegateWork() DelegateWork {
    state_mutex.lock();
    defer state_mutex.unlock();
    const call = pending_fix;
    pending_fix = null;
    return .{ .pending = call, .watch = watch_sels };
}

/// What `clearWatch` is stopping.
const WatchStop = struct {
    /// Whether a watch of this module's was running. False means
    /// `stopUpdatingLocation` is not called at all, which is why `pending` is
    /// then left alone.
    watching: bool,
    /// The one-shot that `stopUpdatingLocation` is about to cancel, so the
    /// caller can reject it. Null when there was none, and always null when
    /// nothing was stopped.
    pending: ?PendingFix,
};

/// Stop the watch and take any one-shot with it, in one lock.
///
/// The two are one decision: CoreLocation documents `stopUpdatingLocation()` as
/// cancelling a pending `requestLocation()`, so whoever clears the watch is also
/// the one who has to settle the one-shot it just cancelled. Doing it in two
/// locks would leave a window in which a fix could arrive for a request that is
/// already dead.
///
/// When no watch was running nothing is stopped, so nothing is cancelled and the
/// one-shot is left strictly alone.
fn takeWatchAndPending() WatchStop {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (watch_sels == null) return .{ .watching = false, .pending = null };
    watch_sels = null;

    const call = pending_fix;
    pending_fix = null;
    return .{ .watching = true, .pending = call };
}

// =============================================================================
// The delegate methods.
//
// Neither replies directly: `evaluateJavaScript` is main-thread-only and these
// are framework callbacks, so the finished JSON goes to `ios_async.deliverJson`
// (or `deliverError`), which hops to the main queue and answers under the
// request id captured back at dispatch. Plain `fn`, never `export`: the desktop
// `bridge_location.zig` already exports `didUpdateLocations` and
// `didFailWithError` by those names, and it is in the same host-test binary.
// =============================================================================

fn didUpdateLocations(_: Id, _: Id, _: Id, locations: Id) callconv(.c) void {
    if (!is_darwin) return;

    // One read: the one-shot is taken, the watch is left. See `DelegateWork`.
    const work = takeDelegateWork();

    // Either consumer's selectors will do — they are the same nine names, and
    // `Sels.resolve()` is deterministic — but preferring the one-shot's keeps
    // the reply shaped from the selectors captured for *that* call.
    const sels = blk: {
        if (work.pending) |call| break :blk call.sels;
        if (work.watch) |watching| break :blk watching;
        // A fix for a call already answered, or one that arrived after the
        // watch stopped. Nothing to reply to and nobody subscribed.
        std.log.info("location: a fix arrived with no call waiting and no watch running; ignored", .{});
        return;
    };

    const fix = readFix(locations, sels) catch |err| {
        reportUnusableFix(work.pending, "read the CLLocation", err);
        return;
    };

    const allocator = std.heap.c_allocator;
    const json = shapeFix(allocator, fix) catch |err| {
        reportUnusableFix(work.pending, "shape the fix", err);
        return;
    };
    defer allocator.free(json);

    // Swift's order, kept: `resolveCallback(singleLocationCallbackId, …)` runs
    // before `sendToWeb("craftLocationUpdate", …)`. Both of these hops target
    // `_dispatch_main_q`, which is serial, so enqueueing in this order is
    // delivering in this order.
    //
    // One shape, used twice, because Swift builds one dictionary and hands it
    // to both. A page reading `e.detail.accuracy` and a page reading
    // `position.accuracy` are reading the same eight keys.
    if (work.pending) |call| ios_async.deliverJson(call.ticket, json);
    if (work.watch != null) ios_events.emit(.location_update, json);
}

fn didFailWithError(_: Id, _: Id, _: Id, err_object: Id) callconv(.c) void {
    if (!is_darwin) return;

    // Read once and reused below: the log line is the one channel a
    // `BridgeError` enum leaves for a rejected caller, and the event is the
    // only channel a watch has at all.
    const description = readNSString(err_object, "localizedDescription") orelse "(none)";

    std.log.warn(
        "location: CLLocationManager failed - domain={s} code={d} description={s}",
        .{
            readNSString(err_object, "domain") orelse "(none)",
            readNSInteger(err_object, "code"),
            description,
        },
    );

    // Swift's order again: `rejectCallback(singleLocationCallbackId, …)` first,
    // then `sendToWeb("craftLocationError", …)`.
    if (takePendingFix()) |call| {
        ios_async.deliverError(call.ticket);
    } else {
        std.log.info("location: a CoreLocation error arrived with no one-shot waiting", .{});
    }

    // Unconditional, exactly as Swift's `sendToWeb` here is: it fires whether or
    // not a callback was pending and whether or not a watch is running. A watch
    // that hits an error has no reply left to reject — its `true` went out when
    // it started — so conditioning the event on a pending call would make the
    // one consumer that needs it the one that never gets it.
    emitLocationError(description);
}

/// Answer a fix that arrived and could not be used.
///
/// Two consumers, two consequences, and the log level follows the consequence
/// rather than the cause. A waiting `getCurrentPosition` is *rejected*: Swift
/// returns silently from `guard let location = locations.last else { return }`,
/// which on that untimed hand-built promise is a hang forever, so this is a real
/// failure being reported to a caller. A watch has nobody to reject — its `true`
/// went out when it started — and Swift emits nothing here either, so it is a
/// gap in a stream rather than a failed call.
///
/// What neither consumer gets is a position. No `craftLocationUpdate` is
/// emitted, because no reading was taken, and an event carrying a
/// plausible-looking fix that nothing measured is the exact fabrication this
/// migration exists to remove.
fn reportUnusableFix(pending: ?PendingFix, comptime what: []const u8, err: anyerror) void {
    if (pending) |call| {
        std.log.err(
            "getCurrentPosition: could not " ++ what ++ " ({}); rejecting rather than " ++
                "reporting a position that was not read",
            .{err},
        );
        ios_async.deliverError(call.ticket);
    } else {
        std.log.warn(
            "watchPosition: could not " ++ what ++ " ({}); no craftLocationUpdate is emitted " ++
                "for a position that was not read",
            .{err},
        );
    }
}

/// Fire `craftLocationError` with the message Swift puts in it.
///
/// A failure to shape the detail drops the event rather than emitting a
/// half-built one: `ios_events.formatEvent` inlines the detail into JavaScript
/// source, so a malformed detail is a syntax error in the page rather than a
/// missing field. The drop is logged, because a silent one is indistinguishable
/// from no error having happened.
fn emitLocationError(message: []const u8) void {
    const allocator = std.heap.c_allocator;

    const detail = shapeLocationError(allocator, message) catch |err| {
        std.log.warn(
            "location: could not shape the craftLocationError detail ({}); the event is dropped " ++
                "rather than sent malformed",
            .{err},
        );
        return;
    };
    defer allocator.free(detail);

    ios_events.emit(.location_error, detail);
}

/// `CLLocationCoordinate2D` — 16 bytes of two doubles.
///
/// Returned through the regular `objc_msgSend` on both arm64 and x86_64: the
/// `_stret` variant is for large structs and does not exist on arm64 at all.
/// `bridge_location.zig` writes out the same reasoning for the same struct.
const Coord = extern struct { latitude: f64, longitude: f64 };

/// Read the last `CLLocation` out of the delegate's array.
///
/// `objc_msgSend_fpret` is not used and must not be: it is `long double`-only on
/// x86_64 and absent on arm64, so a `double`-returning property goes through the
/// plain symbol. `macos.zig`'s `msgSend0Double` does the same.
fn readFix(locations: Id, sels: Sels) !Fix {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (locations == null) return error.NativeCallFailed;

    const IdFn = *const fn (Id, Id) callconv(.c) Id;
    const send_id: IdFn = @ptrCast(&objc.objc_msgSend);
    const location = send_id(locations, sels.last_object) orelse return error.NoLocationInUpdate;

    const CoordFn = *const fn (Id, Id) callconv(.c) Coord;
    const send_coord: CoordFn = @ptrCast(&objc.objc_msgSend);
    const coordinate = send_coord(location, sels.coordinate);

    const DoubleFn = *const fn (Id, Id) callconv(.c) f64;
    const send_double: DoubleFn = @ptrCast(&objc.objc_msgSend);

    const date = send_id(location, sels.timestamp) orelse return error.NativeCallFailed;

    return .{
        .latitude = coordinate.latitude,
        .longitude = coordinate.longitude,
        .altitude = send_double(location, sels.altitude),
        // No `>= 0` filtering anywhere below: CoreLocation's -1 sentinels are
        // what Swift puts on the wire, and the page's types are written for
        // numbers rather than nulls.
        .horizontal_accuracy = send_double(location, sels.horizontal_accuracy),
        .vertical_accuracy = send_double(location, sels.vertical_accuracy),
        .course = send_double(location, sels.course),
        .speed = send_double(location, sels.speed),
        .timestamp_ms = send_double(date, sels.time_interval_since_1970) * 1000.0,
    };
}

/// A zero-argument `NSString`-returning property, as bytes. Null for a nil
/// string or a selector that will not register — both are "nothing to report",
/// never a crash. The slice borrows the string's internal buffer, which is valid
/// for the current autorelease pool; every caller consumes it synchronously —
/// logged, or copied by `shapeLocationError` — before returning.
fn readNSString(object: Id, comptime name: [*:0]const u8) ?[]const u8 {
    if (!is_darwin) return null;

    const sel = objc.sel_registerName(name) orelse return null;
    const value = objc.msgSendId(object, sel) orelse return null;
    const utf8 = objc.getNSStringUTF8(value) orelse return null;
    return std.mem.span(utf8);
}

/// A zero-argument `NSInteger`-returning property.
fn readNSInteger(object: Id, comptime name: [*:0]const u8) c_long {
    if (!is_darwin) return 0;

    const sel = objc.sel_registerName(name) orelse return 0;
    const Fn = *const fn (Id, Id) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(object, sel);
}

// =============================================================================
// Tests - host-only.
//
// Everything that decides page-visible bytes is pure and pinned here: routing
// in both directions, the eight keys and their order, the three renamed keys,
// the -1 passthrough, non-finite refusal, a float buffer big enough for 1e300,
// the error event's one-key detail and its escaping, and — the part that is new
// and is the whole risk of serving a stream from the same delegate as a
// one-shot — how a fix, and a `clearWatch`, settle the two of them together.
//
// Nothing here constructs a `CLLocationManager` or requests authorization. On a
// macOS runner that would raise a real TCC location prompt against the test
// process, and unlike `WCSession` — which is `API_UNAVAILABLE(macos)` and so
// safely absent — CoreLocation exists on macOS and AppKit may well have loaded
// it, so `objc_getClass("CLLocationManager") == null` is not a safe assertion
// either. The Objective-C paths that *are* exercised for real are the ones with
// no device behind them: selector resolution, the Info.plist gate, and the
// delegate class registration.
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 3), capability_actions.len);
    try testing.expectEqualStrings(A.get_current_position, capability_actions[0].name);
    try testing.expectEqualStrings(A.watch_position, capability_actions[1].name);
    try testing.expectEqualStrings(A.clear_watch, capability_actions[2].name);

    for (capability_actions) |decl| {
        // A `.result` whose handler never replies parks the caller on an untimed
        // promise; a `.none` that is awaited resolves immediately and means
        // nothing. Both failure modes are invisible from the page. Swift
        // resolves all three of these, so all three are `.result` — including
        // `watchPosition`, whose `true` is about the subscribe having started,
        // not about a fix having arrived.
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        // `.live` with a reason would be a contradiction the manifest shows to apps.
        try testing.expect(decl.reason == null);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("getCurrentPosition", A.get_current_position);
    try testing.expectEqualStrings("watchPosition", A.watch_position);
    try testing.expectEqualStrings("clearWatch", A.clear_watch);
}

test "the reply both subscribe actions send is the bare fragment Swift resolves" {
    // `resolveCallback(callbackId, result: true)` through `.fragmentsAllowed`.
    // `{"ok":true}` would break `if (await craft._invoke('watchPosition'))`
    // nowhere and `{"watchId":…}` would invent an id the native side does not
    // have — but `craft-bridge.js` resolves with `payload || {}`, so the one
    // thing that genuinely matters is that this stays truthy.
    try testing.expectEqualStrings("true", true_fragment);
}

test "every declared action is one the dispatcher routes" {
    for (capability_actions) |decl| {
        if (routeFor(decl.name) == null) {
            std.debug.print("declared action '{s}' does not route\n", .{decl.name});
            return error.DeclaredActionDoesNotRoute;
        }
    }
}

test "every route the dispatcher has is a declared action" {
    // The other direction: a route with a handler and no declaration is an
    // action the page can call and the manifest denies exists. Each declaration
    // must claim a *distinct* route — counting alone would let two rows share
    // one route while another went undeclared.
    var claimed = std.mem.zeroes([std.enums.values(Route).len]bool);
    for (capability_actions) |decl| {
        const route = routeFor(decl.name) orelse return error.DeclaredActionDoesNotRoute;
        const slot = @backingInt(route);
        if (claimed[slot]) {
            std.debug.print("two declarations route to {s}\n", .{@tagName(route)});
            return error.TwoDeclarationsShareARoute;
        }
        claimed[slot] = true;
    }
    for (claimed, 0..) |taken, slot| {
        if (!taken) {
            std.debug.print(
                "route {s} has a handler but no capability_actions row\n",
                .{@tagName(@as(Route, @fromBackingInt(@intCast(slot))))},
            );
            return error.RouteNotDeclared;
        }
    }
}

test "watchPosition and clearWatch route to their own handlers" {
    try testing.expectEqual(Route.current_position, routeFor("getCurrentPosition").?);
    try testing.expectEqual(Route.watch_position, routeFor("watchPosition").?);
    try testing.expectEqual(Route.clear_watch, routeFor("clearWatch").?);

    // Casing is how a real typo arrives, and a miss here does not fail loudly:
    // `ios_dispatch` reads UnknownAction as "not mine" and hands the action to
    // the Swift shim, so a typo would silently run two implementations of the
    // same watch against two managers.
    for ([_][]const u8{ "watchposition", "WatchPosition", "clearwatch", "ClearWatch" }) |typo| {
        try testing.expect(routeFor(typo) == null);
    }
}

test "the stream is emitted on the name an iOS page's addEventListener names" {
    // The single fact that kept these two actions with the shim until now, and
    // the single fact that could silently un-serve them again.
    //
    // Both subscribers in the injected JS are
    // `window.addEventListener('craftLocationUpdate', …)`: the legacy
    // `geolocation.watchPosition`, and the v1 `craft.location` wrapper's shared
    // dispatcher. A repo-wide grep finds no iOS subscriber to any other
    // spelling. `ios_events.Event` carries that vocabulary;
    // `capabilities.Channel` carries the desktop's, and emitting the desktop
    // spelling would resolve `true` and then feed the page's callback nothing
    // forever — a subscription that reports success and never delivers.
    try testing.expectEqualStrings(
        "craftLocationUpdate",
        ios_events.Event.location_update.eventName(),
    );
    try testing.expectEqualStrings(
        "craftLocationError",
        ios_events.Event.location_error.eventName(),
    );

    // Pinned as the thing they must *not* be, so that a well-meaning
    // consolidation onto `capabilities.Channel` fails here rather than on a
    // device.
    try testing.expectEqualStrings(
        "craft:location:update",
        capabilities.Channel.location_update.eventName(),
    );
    try testing.expect(!std.mem.eql(
        u8,
        ios_events.Event.location_update.eventName(),
        capabilities.Channel.location_update.eventName(),
    ));
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = LocationBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Casing is how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("getcurrentposition", "{}"),
    );
    // The neighbouring recording actions belong to another module; two modules
    // answering one action would make `ios_dispatch`'s first-match routing
    // order-dependent.
    for ([_][]const u8{
        "startLocationRecording",
        "pauseLocationRecording",
        "resumeLocationRecording",
        "stopLocationRecording",
        "getLocationRecordingState",
        "readLocationRecording",
    }) |action| {
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(action, "{}"),
        );
    }
    // `requestPermission('location')` is a permissions action, not this one,
    // and it is still shim-served — see the cross-action note in the module
    // comment.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("requestPermission", "{\"permission\":\"location\"}"),
    );
}

// -----------------------------------------------------------------------------
// Reply shaping.
// -----------------------------------------------------------------------------

/// A JSON number as an `f64`, whatever variant `std.json` chose for it.
///
/// Needed because the variant is a property of the *bytes*, not of the value:
/// `{d}` renders 65 as the integer token `65` (`.integer`), 3.25 as `3.25`
/// (`.float`), and 1e300 as 301 digits with no decimal point — an integer token
/// that overflows `i64` and lands in `.number_string`. Reading `.float`
/// directly, as the first draft of these tests did, panics on two of the three.
fn numberOf(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |text| try std.fmt.parseFloat(f64, text),
        else => error.ReplyFieldIsNotANumber,
    };
}

/// A fix whose eight doubles are all different, so no test below can pass with
/// two of them transposed.
const sample_fix = Fix{
    .latitude = 37.7749,
    .longitude = -122.4194,
    .altitude = 12.5,
    .horizontal_accuracy = 65,
    .vertical_accuracy = 3.25,
    .course = 180.5,
    .speed = 1.75,
    .timestamp_ms = 1700000000123.5,
};

test "the reply is the eight-key object Swift resolves, in a fixed order" {
    // Swift builds a `[String: Any]` and resolves it through
    // `.fragmentsAllowed`, which permits a bare value but never unwraps a
    // dictionary into one. A bare number, an array, or a `{position: …}`
    // wrapper would all break `result.latitude` in every app.
    const json = try shapeFix(testing.allocator, sample_fix);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"latitude\":37.7749,\"longitude\":-122.4194,\"altitude\":12.5," ++
            "\"accuracy\":65,\"altitudeAccuracy\":3.25,\"heading\":180.5," ++
            "\"speed\":1.75,\"timestamp\":1700000000123.5}",
        json,
    );

    // And it parses as the object it claims to be, with exactly eight keys.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 8), parsed.value.object.count());
}

test "accuracy, altitudeAccuracy and heading carry the sources Swift gave them" {
    // The three renames, and the only three places this module can silently
    // disagree with the spec: `accuracy` is `horizontalAccuracy`,
    // `altitudeAccuracy` is `verticalAccuracy`, and `heading` is `course` —
    // the direction of travel, not a compass reading. Transposing any pair
    // produces a reply that still parses and is still wrong.
    const json = try shapeFix(testing.allocator, sample_fix);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;

    try testing.expectEqual(sample_fix.horizontal_accuracy, try numberOf(object.get("accuracy").?));
    try testing.expectEqual(sample_fix.vertical_accuracy, try numberOf(object.get("altitudeAccuracy").?));
    try testing.expectEqual(sample_fix.course, try numberOf(object.get("heading").?));
    try testing.expectEqual(sample_fix.latitude, try numberOf(object.get("latitude").?));
    try testing.expectEqual(sample_fix.longitude, try numberOf(object.get("longitude").?));
    try testing.expectEqual(sample_fix.altitude, try numberOf(object.get("altitude").?));
    try testing.expectEqual(sample_fix.speed, try numberOf(object.get("speed").?));
    try testing.expectEqual(sample_fix.timestamp_ms, try numberOf(object.get("timestamp").?));

    // The desktop `bridge_location.zig` emits the raw property names. They are
    // a different contract, and a copy-paste from it would put them here.
    try testing.expect(std.mem.indexOf(u8, json, "horizontalAccuracy") == null);
    try testing.expect(std.mem.indexOf(u8, json, "verticalAccuracy") == null);
    // Nor is there a watch id anywhere: this action returns a position.
    try testing.expect(std.mem.indexOf(u8, json, "watchId") == null);
}

test "CoreLocation's -1 sentinels are passed through, not nulled" {
    // Swift's dictionary has no nil checks, no `>= 0` guards and no coalescing,
    // so an invalid reading reaches the page as -1. `Location.accuracy` is
    // typed `number`, not `number | null`, and a page doing arithmetic on it
    // would get NaN from a null.
    const json = try shapeFix(testing.allocator, .{
        .latitude = 0,
        .longitude = 0,
        .altitude = 0,
        .horizontal_accuracy = -1,
        .vertical_accuracy = -1,
        .course = -1,
        .speed = -1,
        .timestamp_ms = 0,
    });
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"latitude\":0,\"longitude\":0,\"altitude\":0,\"accuracy\":-1," ++
            "\"altitudeAccuracy\":-1,\"heading\":-1,\"speed\":-1,\"timestamp\":0}",
        json,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    // Numbers, not nulls, and the number is -1 — the assertion the wording
    // above is about.
    for ([_][]const u8{ "accuracy", "altitudeAccuracy", "heading", "speed" }) |key| {
        const value = parsed.value.object.get(key).?;
        try testing.expect(value != .null);
        try testing.expectEqual(@as(f64, -1), try numberOf(value));
    }
}

test "the timestamp keeps its fraction rather than being truncated to a millisecond" {
    // `timeIntervalSince1970 * 1000` is a fractional double. Rounding it would
    // be a quiet change to a value pages use to order samples.
    const json = try shapeFix(testing.allocator, .{
        .latitude = 1,
        .longitude = 2,
        .altitude = 3,
        .horizontal_accuracy = 4,
        .vertical_accuracy = 5,
        .course = 6,
        .speed = 7,
        .timestamp_ms = 1700000000123.456,
    });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"timestamp\":1700000000123.456") != null);
}

test "a non-finite reading is refused in every field, not printed" {
    // `inf` and `nan` are not JSON. Printing either would produce a syntax
    // error inside the reply script with nothing to point at; Swift's own
    // `JSONSerialization` refuses them too. Each field is checked separately,
    // because one unguarded `appendNumber` call site is all it takes.
    const fields = [_][]const u8{
        "latitude",          "longitude", "altitude", "horizontal_accuracy",
        "vertical_accuracy", "course",    "speed",    "timestamp_ms",
    };
    for (fields, 0..) |name, index| {
        for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |bad| {
            var fix = sample_fix;
            switch (index) {
                0 => fix.latitude = bad,
                1 => fix.longitude = bad,
                2 => fix.altitude = bad,
                3 => fix.horizontal_accuracy = bad,
                4 => fix.vertical_accuracy = bad,
                5 => fix.course = bad,
                6 => fix.speed = bad,
                7 => fix.timestamp_ms = bad,
                else => unreachable,
            }
            if (shapeFix(testing.allocator, fix)) |json| {
                testing.allocator.free(json);
                std.debug.print("field '{s}' accepted a non-finite value\n", .{name});
                return error.NonFiniteAccepted;
            } else |err| {
                try testing.expectEqual(bridge_error.BridgeError.InvalidParameter, err);
            }
        }
    }
}

test "an extreme magnitude keeps its digits instead of overflowing the buffer" {
    // `{d}` renders decimal, never scientific: 1e300 is 301 digits, and the
    // payload carries eight doubles. A `[64]u8` anywhere in `appendNumber`
    // would turn a legal reading into a NoSpaceLeft refusal — which the page
    // would see as a rejected position request.
    const json = try shapeFix(testing.allocator, .{
        .latitude = 1e300,
        .longitude = -1e300,
        .altitude = 1e-300,
        .horizontal_accuracy = std.math.floatMax(f64),
        .vertical_accuracy = -std.math.floatMax(f64),
        .course = std.math.floatMin(f64),
        .speed = 0,
        .timestamp_ms = 1e300,
    });
    defer testing.allocator.free(json);

    try testing.expect(json.len > 1500);
    try testing.expect(std.mem.indexOf(u8, json, "e+") == null);
    try testing.expect(std.mem.indexOf(u8, json, "E") == null);

    // Still valid JSON, and the largest value survived intact rather than
    // being clipped at a buffer boundary.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 8), parsed.value.object.count());
    try testing.expectEqual(@as(f64, 1e300), try numberOf(parsed.value.object.get("latitude").?));
    try testing.expectEqual(
        std.math.floatMax(f64),
        try numberOf(parsed.value.object.get("accuracy").?),
    );
}

test "the watch event and the one-shot reply are the same bytes" {
    // `didUpdateLocations` shapes once and uses the result twice — `deliverJson`
    // for a pending one-shot, `ios_events.emit` for the watch — because Swift
    // builds one `[String: Any]` and hands it to both `resolveCallback` and
    // `sendToWeb`. A page doing `craft.location.watchPosition(p => …)` and a
    // page doing `craft.location.getCurrentPosition()` read the same eight keys,
    // so a second shaping function here would be two contracts wearing one name.
    const json = try shapeFix(testing.allocator, sample_fix);
    defer testing.allocator.free(json);

    // The detail is inlined as a JSON literal by `ios_events.formatEvent`, not
    // quoted, so these bytes are what `e.detail` parses to.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 8), parsed.value.object.count());
    for ([_][]const u8{
        "latitude",         "longitude", "altitude", "accuracy",
        "altitudeAccuracy", "heading",   "speed",    "timestamp",
    }) |key| {
        try testing.expect(parsed.value.object.get(key) != null);
    }
}

// -----------------------------------------------------------------------------
// The error event's detail.
// -----------------------------------------------------------------------------

test "the error event carries Swift's one-key message object" {
    // `sendToWeb("craftLocationError", data: ["message": error.localizedDescription])`.
    // One key. The NSError's `domain` and `code` are logged here but are not on
    // the wire, because Swift does not put them there.
    const json = try shapeLocationError(testing.allocator, "The operation could not be completed.");
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"message\":\"The operation could not be completed.\"}",
        json,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.object.count());
    try testing.expect(parsed.value.object.get("code") == null);
    try testing.expect(parsed.value.object.get("domain") == null);
}

test "a description carrying quotes, backslashes or control bytes stays inside its string" {
    // `ios_events.formatEvent` inlines this detail into a JavaScript source
    // position verbatim. An unescaped `"` closes the string early and turns the
    // whole `dispatchEvent(...)` call into a syntax error in the page, with
    // nothing to point at — and an NSError's `localizedDescription` is
    // device- and locale-controlled text that quotes file paths back at you.
    const raw = "a \"b\" \\ c\nd\te\x01";
    const json = try shapeLocationError(testing.allocator, raw);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"message\":\"a \\\"b\\\" \\\\ c\\nd\\te\\u0001\"}",
        json,
    );

    // And it round-trips: the page receives the description Swift would have
    // sent, not an escaped rendering of it.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(raw, parsed.value.object.get("message").?.string);
}

test "an empty and a very long description are both shaped rather than dropped" {
    const empty = try shapeLocationError(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("{\"message\":\"\"}", empty);

    // Worst case is six output bytes per input byte. A fixed scratch buffer
    // would turn a long localised error into a `BufferTooSmall`, and
    // `emitLocationError` drops an event it cannot shape — so the page would
    // lose exactly the errors that had the most to say.
    const long = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(long);
    @memset(long, 0x01);

    const json = try shapeLocationError(testing.allocator, long);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 4096), parsed.value.object.get("message").?.string.len);
}

test "the float buffer is sized from the formatter, not from a guess" {
    // The constant this module depends on, asserted rather than assumed: a
    // decimal f64 needs 347 bytes in the worst case, and the sibling modules
    // that guessed 64 truncated.
    try testing.expect(std.fmt.float.bufferSize(.decimal, f64) > 300);
}

// -----------------------------------------------------------------------------
// The single-fix slot, the watch flag, and the three ways they interact.
//
// `takeWatchAndPending()` is used as the reset between tests as well as being
// the thing under test: it is the only function that clears both, and using a
// test-only clearer would let production and test disagree about what "clear"
// means.
// -----------------------------------------------------------------------------

const empty_sels = Sels{
    .last_object = null,
    .coordinate = null,
    .altitude = null,
    .horizontal_accuracy = null,
    .vertical_accuracy = null,
    .course = null,
    .speed = null,
    .timestamp = null,
    .time_interval_since_1970 = null,
};

test "the slot hands the delegate its ticket once, and clearing it stops a second reply" {
    // The delegate methods are plain C functions with no capture, so this slot
    // is the only way either of them learns which call it is answering. Two
    // properties matter: a published call comes back with its generation intact
    // (a stale generation makes `deliverJson` a silent no-op), and taking it
    // clears the entry, so a double-firing delegate cannot reply twice.
    try testing.expect(takePendingFix() == null);

    const ticket = ios_async.Ticket{ .index = 4, .generation = 91 };
    try testing.expect(publishPendingFix(ticket, empty_sels) == null);

    const taken = takePendingFix() orelse return error.PublishedCallWentMissing;
    try testing.expectEqual(@as(u5, 4), taken.ticket.index);
    try testing.expectEqual(@as(u32, 91), taken.ticket.generation);

    try testing.expect(takePendingFix() == null);
}

test "a second call displaces the first and hands it back to be rejected" {
    // Swift overwrites `singleLocationCallbackId` and the displaced promise
    // never settles. Returning the old entry is what lets the handler reject it
    // instead — the caller must be able to see what it evicted, or the eviction
    // is a silent drop.
    try testing.expect(takePendingFix() == null);

    const first = ios_async.Ticket{ .index = 1, .generation = 2 };
    const second = ios_async.Ticket{ .index = 3, .generation = 4 };

    try testing.expect(publishPendingFix(first, empty_sels) == null);

    const displaced = publishPendingFix(second, empty_sels) orelse
        return error.DisplacedCallWasDroppedSilently;
    try testing.expectEqual(@as(u5, 1), displaced.ticket.index);
    try testing.expectEqual(@as(u32, 2), displaced.ticket.generation);

    // The survivor is the newer one, and it is still there to be answered.
    const remaining = takePendingFix() orelse return error.SurvivingCallWentMissing;
    try testing.expectEqual(@as(u5, 3), remaining.ticket.index);
    try testing.expectEqual(@as(u32, 4), remaining.ticket.generation);
}

test "a delegate callback with no call recorded does nothing to the slot" {
    // A late or duplicate fire must not reach `deliverJson`/`deliverError` at
    // all. With the slot empty there is no ticket to reply with, and both
    // methods return without touching the pool — asserted by the slot staying
    // empty rather than by observing a reply that must not happen.
    //
    // `didFailWithError` does still fire `craftLocationError` here, exactly as
    // Swift's does with a nil `singleLocationCallbackId`: the event is not
    // conditioned on a caller. What it must not do is take a slot.
    _ = takeWatchAndPending();
    try testing.expect(takePendingFix() == null);

    didUpdateLocations(null, null, null, null);
    try testing.expect(takePendingFix() == null);

    didFailWithError(null, null, null, null);
    try testing.expect(takePendingFix() == null);

    // And neither of them started a watch.
    try testing.expect(!takeWatchAndPending().watching);
}

test "one fix settles the one-shot and feeds the watch, consuming only the one-shot" {
    // The interaction this whole change turns on. A `getCurrentPosition` and a
    // `watchPosition` can be live at the same time, one `didUpdateLocations`
    // has to serve both, and the two halves behave differently: the reply is
    // answered once, the stream is answered every time.
    //
    // Reading them under one lock is what makes that one decision. Two locks
    // would leave a window where a `clearWatch` could land between taking the
    // fix and reading the watch, and the fix would then be replied to for a
    // subscription that had already been told it was stopped.
    _ = takeWatchAndPending();
    try testing.expect(takePendingFix() == null);

    const ticket = ios_async.Ticket{ .index = 7, .generation = 11 };
    try testing.expect(publishPendingFix(ticket, empty_sels) == null);
    publishWatch(empty_sels);

    const first = takeDelegateWork();
    const pending = first.pending orelse return error.OneShotWasNotHandedToTheDelegate;
    try testing.expectEqual(@as(u5, 7), pending.ticket.index);
    try testing.expectEqual(@as(u32, 11), pending.ticket.generation);
    try testing.expect(first.watch != null);

    // The second fix of the same subscription: no one-shot left to answer — a
    // double reply is a settled promise being settled again — and the watch
    // still there, because a stream that stops after one event is a page whose
    // callback is registered and silent.
    const second = takeDelegateWork();
    try testing.expect(second.pending == null);
    try testing.expect(second.watch != null);

    _ = takeWatchAndPending();
}

test "clearing a running watch settles the one-shot it just cancelled" {
    // CoreLocation documents `stopUpdatingLocation()` as cancelling a pending
    // `requestLocation()`, so the fix that would have answered an in-flight
    // `getCurrentPosition` is not coming. Its promise is the untimed
    // hand-built kind, so leaving it there is a page parked forever, not a page
    // that waits thirty seconds. `clearWatch` has to be handed that call in
    // order to reject it — if this returned null the rejection could not
    // happen, and the drop would be silent.
    _ = takeWatchAndPending();
    try testing.expect(takePendingFix() == null);

    publishWatch(empty_sels);
    const ticket = ios_async.Ticket{ .index = 2, .generation = 5 };
    try testing.expect(publishPendingFix(ticket, empty_sels) == null);

    const stop = takeWatchAndPending();
    try testing.expect(stop.watching);
    const stranded = stop.pending orelse return error.PendingFixWasStrandedByClearWatch;
    try testing.expectEqual(@as(u5, 2), stranded.ticket.index);
    try testing.expectEqual(@as(u32, 5), stranded.ticket.generation);

    // Cleared, so a fix that races the stop cannot reply to the ticket
    // `clearWatch` has already rejected.
    try testing.expect(takePendingFix() == null);
    try testing.expect(!takeWatchAndPending().watching);
}

test "clearing a watch that is not running leaves a pending one-shot alone" {
    // The deliberate divergence. Swift's `stopWatchingPosition()` calls
    // `stopUpdatingLocation()` unconditionally, so in Swift a `clearWatch` with
    // no watch running still cancels an in-flight `getCurrentPosition`. This
    // module only stops what it started, so nothing is cancelled and the
    // one-shot survives to be answered.
    //
    // Getting this wrong is invisible in the shape of the reply and visible
    // only as a position request that fails whenever the page happens to
    // unmount a map component at the same moment.
    _ = takeWatchAndPending();

    const ticket = ios_async.Ticket{ .index = 9, .generation = 3 };
    try testing.expect(publishPendingFix(ticket, empty_sels) == null);

    const stop = takeWatchAndPending();
    try testing.expect(!stop.watching);
    try testing.expect(stop.pending == null);

    const survivor = takePendingFix() orelse return error.IdleClearWatchTookTheOneShot;
    try testing.expectEqual(@as(u5, 9), survivor.ticket.index);
    try testing.expectEqual(@as(u32, 3), survivor.ticket.generation);
}

test "a fix that cannot be read leaves the watch running and reports nothing" {
    // `readFix` refuses a null `locations` — Swift's `guard let location =
    // locations.last else { return }`. Two things must hold: no
    // `craftLocationUpdate` is emitted, because no reading was taken and a
    // plausible-looking event is the fabrication this migration exists to
    // remove; and the subscription survives, because one unreadable callback is
    // not the end of a stream.
    _ = takeWatchAndPending();
    publishWatch(empty_sels);

    didUpdateLocations(null, null, null, null);

    const after = takeWatchAndPending();
    try testing.expect(after.watching);
    try testing.expect(after.pending == null);
}

test "re-entering watchPosition is idempotent rather than additive" {
    // The page posts `watchPosition` on the empty-to-one transition of its own
    // callback `Map`, but a `clearWatch` racing a new subscriber can produce a
    // second post. Swift re-sets its flag and re-issues `startUpdatingLocation`;
    // there is one native watch either way, and one `clearWatch` stops it.
    _ = takeWatchAndPending();

    publishWatch(empty_sels);
    publishWatch(empty_sels);

    try testing.expect(takeWatchAndPending().watching);
    try testing.expect(!takeWatchAndPending().watching);
}

// -----------------------------------------------------------------------------
// Platform behaviour.
// -----------------------------------------------------------------------------

test "off Darwin the handler refuses rather than invent a position" {
    if (is_darwin) return error.SkipZigTest;

    var bridge = LocationBridge.init(testing.allocator);
    defer bridge.deinit();

    // A zeroed position would be a perfectly plausible-looking lie: (0, 0) is
    // a real coordinate, and a page cannot tell it from a reading. A `true`
    // from `watchPosition` or `clearWatch` would be the same lie about a
    // subscription that is not running and a stop that did not happen.
    for ([_][]const u8{ A.get_current_position, A.watch_position, A.clear_watch }) |action| {
        try testing.expectError(error.UnsupportedPlatform, bridge.handleMessage(action, "{}"));
    }
    try testing.expectError(error.UnsupportedPlatform, resolveAuthorization());
    try testing.expectError(error.UnsupportedPlatform, Sels.resolve());
    try testing.expectError(error.UnsupportedPlatform, ensureManager());
    try testing.expectError(error.UnsupportedPlatform, ensureDelegate());
    try testing.expectError(error.UnsupportedPlatform, backgroundLocationDeclared());
}

test "without the usage description the gate refuses before any manager exists" {
    if (!is_darwin) return error.SkipZigTest;

    // The host test runner is a bare binary with no Info.plist, which is
    // exactly the "geolocation was never configured" case the gate is for.
    // It is also what keeps this whole file safe to run: everything past the
    // gate would build a real `CLLocationManager` and raise a TCC prompt
    // against the test process.
    if (resolveAuthorization()) |_| {
        // A runner that *does* carry the key (tests hosted inside a real app)
        // would take the live path below, so skip rather than prompt.
        return error.SkipZigTest;
    } else |err| switch (err) {
        bridge_error.BridgeError.PermissionDenied => {
            var bridge = LocationBridge.init(testing.allocator);
            defer bridge.deinit();

            try testing.expectError(
                bridge_error.BridgeError.PermissionDenied,
                bridge.handleMessage(A.get_current_position, "{}"),
            );

            // `watchPosition` is wrapped in the same `config.enableGeolocation`
            // check in the Swift dispatcher, so it takes the same gate.
            try testing.expectError(
                bridge_error.BridgeError.PermissionDenied,
                bridge.handleMessage(A.watch_position, "{}"),
            );

            // `clearWatch` is *not*: `case "clearWatch":` carries no capability
            // check at all, so a page can always stop a watch — including in an
            // app that could never have started one, where it is a no-op that
            // still replies `true`. Borrowing getCurrentPosition's gate here
            // would refuse a stop the shim always performs.
            try bridge.handleMessage(A.clear_watch, "{}");

            // The refusal must happen before the manager is built and before a
            // slot is leased: an unreleased lease narrows the pool for every
            // later call, and a manager built here would outlive the test. The
            // no-op `clearWatch` must not have built one either.
            try testing.expect(manager == null);
            try testing.expect(takePendingFix() == null);
            try testing.expect(!takeWatchAndPending().watching);
        },
        else => return err,
    }
}

test "the payload is ignored, not parsed" {
    if (!is_darwin) return error.SkipZigTest;
    // Three real dispatches, so this needs the process the gate stops.
    if (resolveAuthorization()) |_| return error.SkipZigTest else |_| {}

    // The page drops `options` before posting — `legacyGeolocation.getCurrentPosition`
    // takes no parameters — and the Swift dispatcher reads nothing out of
    // `body`. A payload that is not even JSON must therefore reach exactly the
    // same outcome as `{}`; if it did not, this module would have invented a
    // failure the shim does not have.
    var bridge = LocationBridge.init(testing.allocator);
    defer bridge.deinit();

    const empty = bridge.handleMessage(A.get_current_position, "{}");
    const junk = bridge.handleMessage(A.get_current_position, "{not json");
    const options = bridge.handleMessage(
        A.get_current_position,
        "{\"enableHighAccuracy\":true,\"timeout\":5000,\"maximumAge\":0}",
    );

    try testing.expectEqual(empty, junk);
    try testing.expectEqual(empty, options);
    if (empty) |_| {} else |err| {
        try testing.expect(err != bridge_error.BridgeError.InvalidJSON);
        try testing.expect(err != bridge_error.BridgeError.MissingData);
    }

    // `watchPosition` is posted with no payload by both JS surfaces, and
    // `clearWatch` posts no `id` — `nextLocationWatchId` is a JS-side map key.
    // So neither may acquire a way to fail on a payload it never receives.
    const watch_empty = bridge.handleMessage(A.watch_position, "{}");
    const watch_junk = bridge.handleMessage(A.watch_position, "{not json");
    try testing.expectEqual(watch_empty, watch_junk);

    try bridge.handleMessage(A.clear_watch, "{}");
    try bridge.handleMessage(A.clear_watch, "{not json");
    try bridge.handleMessage(A.clear_watch, "{\"id\":3}");
    try testing.expect(!takeWatchAndPending().watching);
}

test "every selector the delegate needs resolves on a real runtime" {
    if (!is_darwin) return error.SkipZigTest;

    // `sel_registerName` interns a name whether or not any class implements it,
    // so this touches no framework and prompts for nothing. What it catches is
    // a typo in one of the nine spellings, which would otherwise surface as a
    // rejected position request on a device.
    const sels = try Sels.resolve();
    inline for (comptime std.meta.fieldNames(Sels)) |name| {
        if (@field(sels, name) == null) {
            std.debug.print("selector for Sels.{s} did not resolve\n", .{name});
            return error.SelectorDidNotResolve;
        }
    }

    // Distinct selectors, or two readings would come from one property.
    try testing.expect(sels.horizontal_accuracy != sels.vertical_accuracy);
    try testing.expect(sels.course != sels.speed);
    try testing.expect(sels.altitude != sels.coordinate);
}

test "the delegate class registers under its own name, idempotently" {
    if (!is_darwin) return error.SkipZigTest;

    // No CoreLocation is involved: this allocates an NSObject subclass and one
    // instance. It is the load-bearing half of the delegate — a class that does
    // not register, or that adopts the desktop's IMPs, is a position request
    // that never answers on a device.
    const first = try ensureDelegate();

    // `objc_getClass` first means a second call must hand back the same live
    // instance rather than registering a duplicate class pair.
    const second = try ensureDelegate();
    try testing.expectEqual(first, second);

    // And it really is our class, not `bridge_location.zig`'s
    // `CraftLocationDelegate` — which is compiled into this same host binary,
    // looks itself up with `objc_getClass` too, and registers three methods
    // whose IMPs read different properties and fire desktop events.
    try testing.expect(!std.mem.eql(u8, delegate_class_name, "CraftLocationDelegate"));
    const cls = objc.object_getClass(first) orelse return error.DelegateHasNoClass;
    try testing.expectEqualStrings(delegate_class_name, std.mem.span(objc.class_getName(cls)));

    // Both methods were added. CoreLocation dispatches through
    // `respondsToSelector:`, so a method that failed to attach is a callback
    // that is simply never made — silence, on an untimed promise.
    const sel_responds = objc.sel_registerName("respondsToSelector:") orelse
        return error.SelectorNotFound;
    const RespondsFn = *const fn (Id, Id, Id) callconv(.c) bool;
    const responds: RespondsFn = @ptrCast(&objc.objc_msgSend);

    for ([_][*:0]const u8{
        "locationManager:didUpdateLocations:",
        "locationManager:didFailWithError:",
    }) |name| {
        const sel = objc.sel_registerName(name) orelse return error.SelectorNotFound;
        if (!responds(first, sel_responds, sel)) {
            std.debug.print("the delegate does not respond to {s}\n", .{name});
            return error.DelegateMissingMethod;
        }
    }

    // And it deliberately does not implement the authorization callback: there
    // is no iOS contract for one, so implementing it would mean inventing a
    // channel no page subscribes to.
    const sel_auth = objc.sel_registerName("locationManagerDidChangeAuthorization:") orelse
        return error.SelectorNotFound;
    try testing.expect(!responds(first, sel_responds, sel_auth));
}
