//! The CoreMotion actions of the `mobile` namespace — `startMotionUpdates` and
//! `stopMotionUpdates` — served here, on Zig's own `CMMotionManager`.
//!
//! A previous round of this module served **nothing**, and was right to: the
//! only way to push an event was `capabilities.Channel`, whose names are all
//! `craft:`-prefixed and whose own test enforces that prefix, so nothing in Zig
//! could *spell* `craftMotionUpdate`. Starting a sensor and streaming into a
//! name no page listens for is fabricated success at the event layer. That
//! blocker is gone: `ios_events.Event` is the iOS vocabulary taken from Swift's
//! `sendToWeb` call sites, and `.motion_update` dispatches exactly
//! `craftMotionUpdate`.
//!
//! ## What Swift does, exactly
//!
//! `CraftApp.swift:857-865` (dispatcher) and `:3751-3790` (implementation):
//!
//!  - **`startMotionUpdates` takes one field, `interval`,** a number in
//!    **milliseconds**, defaulting to **100** (`body["interval"] as? Double ??
//!    100`). `:3758` divides it by 1000 into the `NSTimeInterval` seconds
//!    `deviceMotionUpdateInterval` wants. Android agrees on the name, the unit
//!    and the default (`CraftBridge.kt.template:547`). `craft.d.ts:245`
//!    declares `startMotionUpdates(): void` — no parameter and no promise — and
//!    is wrong on both counts.
//!  - **`stopMotionUpdates` takes nothing.** Swift reads nothing out of `body`;
//!    `ios_dispatch.payloadOf` would hand a handler `"{}"`.
//!  - **Both replies are the bare fragment `true`.** `resolveCallback`
//!    serialises with `.fragmentsAllowed` and both paths pass `result: true`
//!    (`:3784`, `:865`) — so `true`, never `{"ok":true}` and never the object
//!    wrapper `bridge_mobile_watch.zig` needed. `startMotionUpdates` replies
//!    *once*, after the framework call returns, and then the handler block
//!    emits repeatedly; `stopMotionUpdates` replies once and emits nothing.
//!  - **`startMotionUpdates`'s only failure path is a rejection** (`:3753-3755`,
//!    "Motion sensors not available"), never a resolved `false`. It fires when
//!    the manager is nil (the `enableMotionSensors` flag is off) or when
//!    `isDeviceMotionAvailable` is NO.
//!  - **The event is `craftMotionUpdate`** — no `craft:` prefix, no colons —
//!    dispatched through `sendToWeb` (`:4835-4845`), which inlines the JSON as
//!    the `detail` literal exactly as `ios_events.formatEvent` does.
//!  - **The detail has three keys** (`:3764-3780`): `acceleration`
//!    (`CMDeviceMotion.userAcceleration`, x/y/z), `rotation`
//!    (`CMAttitude.yaw/pitch/roll` as alpha/beta/gamma — **attitude in
//!    radians, not gyroscope rate**), and `gravity` (`CMDeviceMotion.gravity`,
//!    x/y/z). `shapeDetail` emits those and only those.
//!  - **The handler queue is `.main`** (`:3761`), i.e. `[NSOperationQueue
//!    mainQueue]`. This uses the same queue, so the callback lands where
//!    Swift's did. `ios_events.emit` is thread-safe regardless — it copies,
//!    queues and hops to the main queue itself — so the choice is about
//!    matching the spec, not about safety.
//!
//! ## The three consumers all read keys nothing has ever emitted
//!
//! `packages/ios/templates/test-bridges.html:397-402` reads
//! `e.detail.accelerometer` and `e.detail.gyroscope`; `packages/ios/README.md`
//! and `craft.d.ts`'s `CraftMotionUpdateEvent` say the same. **Neither iOS nor
//! Android has ever produced those keys** — Android emits `acceleration` plus a
//! `rotation` that really is gyro rate, and no `gravity` at all. Every
//! documented consumer reads `undefined` today.
//!
//! The emitter is the contract this migration must preserve — the conformance
//! test embeds `CraftApp.swift` as the spec — so `shapeDetail` emits Swift's
//! three keys and a test below pins that it does *not* invent
//! `accelerometer`/`gyroscope`. Renaming `attitude` to `gyroscope` would be an
//! outright lie about what the number is. The doc/type/test-page mismatch is a
//! real, separate, pre-existing bug and is reported rather than papered over.
//!
//! Worth knowing while reading any of that: **`window.craft.startMotionUpdates`
//! does not exist in the injected iOS JavaScript.** `injectNativeBridge`
//! (`CraftApp.swift:1155`-`2427`) contains no occurrence of "motion" at all,
//! and `craft-bridge.js` has no `mobile` surface either. So the README example
//! and the test page's two buttons are `TypeError`s on the legacy path, and the
//! dispatcher arm is reachable only through the Zig hand-off envelope. That is
//! a second pre-existing bug, and it is why "what the page consumes" had to be
//! read off the Swift dispatcher and cross-checked against Android rather than
//! off an injected JS method that was never written.
//!
//! ## The `enableMotionSensors` gate, and why the Info.plist stands in for it
//!
//! `CraftApp.swift:859` is `if config.enableMotionSensors { … }` with **no
//! `else`**, so on the Swift path with the flag off `startMotionUpdates`
//! replies nothing at all while `CraftSwiftShim.handleAction` still returns
//! true: the page's promise never settles. The flag defaults to `false`
//! (`packages/ios/src/index.ts:139`) and has no mirror anywhere under
//! `packages/zig/src`.
//!
//! `NSMotionUsageDescription` is an *exact* proxy for it —
//! `packages/ios/src/index.ts:192` writes that Info.plist key from
//! `config.enableMotionSensors` and from nothing else, with no `||` (unlike the
//! location keys, where `bridge_mobile_location.zig` had to document a residual
//! gap). So `requireMotionConfigured` reads the key and refuses when it is
//! absent. Two things that buys, and one it costs:
//!
//!  - a hang becomes a nameable refusal, which is strictly better than the
//!    shim's silence;
//!  - an app whose author switched motion off does not get motion because Zig
//!    happens to own its own manager and could have ignored the flag.
//!  - The cost is a vocabulary mismatch: Swift rejects with `CRAFT_ERROR` and
//!    the message "Motion sensors not available", while `BridgeError` has no
//!    such member. `PermissionDenied` -> `PERMISSION_DENIED` is what this says
//!    for "the app was not built with motion enabled", and
//!    `PlatformNotSupported` -> `PLATFORM_NOT_SUPPORTED` for "this device has
//!    no device motion". Swift collapsed both into one message; splitting them
//!    tells the page which of the two it is.
//!
//! Note that `NSMotionUsageDescription` is not itself required by
//! `CMMotionManager` for device motion — it is CMPedometer and
//! CMMotionActivityManager that need it. It is read here purely as evidence of
//! the build-time flag, and that is the only claim made for it.
//!
//! ## `isDeviceMotionAvailable` is checked before anything starts
//!
//! It is **NO on the simulator**, which is where most of this will first be
//! run. Starting anyway would hand the page a stream of zeroes that no sensor
//! produced — a fabricated reading, which is worse than no reading. So the
//! availability check happens before the manager is asked to start, and a NO
//! is an error the page can catch, exactly as Swift's `guard` makes it.
//!
//! ## `CMAcceleration` is `{double x, y, z}` — 24 bytes — and the ABI splits
//!
//! On aarch64 that is a homogeneous floating aggregate returned in `v0`-`v2`
//! through plain `objc_msgSend`. On `x86_64` it is >16 bytes, MEMORY class, and
//! needs the caller-provided-pointer entry point `objc_msgSend_stret`.
//! `build.zig:1860` builds an x86_64 iOS-simulator target, so both ship.
//!
//! `objc_runtime.msgSendStret` is **wrong for this**: it selects by `@sizeOf`
//! alone and would reference `objc_msgSend_stret` on arm64, which arm64 libobjc
//! does not export — an undefined symbol at app link. `acceleration_entry`
//! below is the comptime `builtin.target.cpu.arch` choice
//! `menubar_collapse.zig:117-128` already makes for `-frame`, and a test pins
//! it. The doubles (`yaw`/`pitch`/`roll`) go through plain `objc_msgSend` on
//! both arches; `objc_msgSend_fpret` is an x86_64 `long double` concern only
//! and is not used.
//!
//! ## The handler is a module-level GLOBAL block
//!
//! `startDeviceMotionUpdatesToQueue:withHandler:` *escapes* its block: it
//! `Block_copy`s it and calls it repeatedly for as long as updates run. A stack
//! block would be a dangling call the moment the dispatch frame returned. The
//! block here is file-scope with `isa = &_NSConcreteGlobalBlock` and
//! `BLOCK_IS_GLOBAL` set, so `Block_copy` is the identity function — the
//! pattern `ios_async.zig` and `bridge_mobile_haptics.zig` both use.
//!
//! It captures nothing, because it cannot: a global block has no capture
//! storage. Everything it needs — the six selectors it sends — lives in
//! `stream`, published under a mutex *before* the framework call, so a handler
//! that somehow ran before `msgSend` returned would still find them.
//!
//! `ios_async` is deliberately **not** used. Its slot pool answers *one* call
//! with *one* reply; this handler is a repeating stream that never replies at
//! all. `startMotionUpdates`'s single reply is synchronous, from inside the
//! dispatch frame, where `request_context` still names the call — so there is
//! no late reply to correlate and nothing for a ticket to hold.
//!
//! ## Restart, and what `stopMotionUpdates` may honestly claim
//!
//! CoreMotion does not define what a second
//! `startDeviceMotionUpdatesToQueue:withHandler:` does while updates are
//! already running, and Swift calls it again regardless. This stops first when
//! `stream` says updates are live, so a page that changes `interval` ends with
//! exactly one stream at the rate it asked for.
//!
//! `stopMotionUpdates` replies `true` even when no manager was ever built,
//! which mirrors Swift's `motionManager?.stopDeviceMotionUpdates()` — an
//! optional-chained no-op that still resolves `true`. That is not a fabricated
//! success: the postcondition the page asked for ("no motion updates are being
//! delivered") holds. It holds *because* this module serves `startMotionUpdates`
//! too — the earlier round could not have said this, since a Zig-only
//! `stopMotionUpdates` would have stopped its own null manager while Swift's
//! kept streaming. Either both actions are served or neither is; both are.
//!
//! ## What is pure and what is not
//!
//! `intervalSeconds` and `shapeDetail` touch no Objective-C and no state, and
//! they are the two places the observable contract can silently go wrong — a
//! dropped `interval`, a renamed detail key, a `[64]u8` that turns a legal
//! double into `NoSpaceLeft`. They are pinned by host tests that run on every
//! platform. The CoreMotion half is exercised as far as a host honestly can:
//! selector interning, the block's global flags, the ABI entry-point choice,
//! the refusal paths, and — measured, not argued — `isDeviceMotionAvailable`
//! answering NO on a machine with no device-motion service.
//!
//! One correction worth carrying: `CMMotionManager.h` is
//! `API_UNAVAILABLE(macos)`, and an earlier note in this module concluded from
//! that that `objc_getClass("CMMotionManager")` is null on macOS. It is not —
//! the class is present on a macOS runner. So the class's absence is not a
//! guard anywhere in this file; `ensureManager` guards the lookup because a
//! lookup should be guarded, and `isDeviceMotionAvailable` is what actually
//! refuses a machine without sensors. No test constructs the module-level
//! manager: `manager` staying null is asserted, so a later change that starts
//! building one inside the test runner fails loudly.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_events = @import("ios_events.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The same type as `objc.id` — `?*anyopaque` — spelled locally, per the
/// location/notifications precedent: `objc_runtime.objc` is an empty struct off
/// Darwin and a function *signature* is analysed even when a comptime platform
/// guard prunes the body, so naming `objc.id` in the `callconv(.c)` types below
/// would break the host build. A single optional pointer, never `?objc.id` — a
/// double optional is illegal in `callconv(.c)`.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches this block against those labels in
/// both directions, and fails the build if two modules declare one name.
pub const A = struct {
    pub const start_motion_updates = "startMotionUpdates";
    pub const stop_motion_updates = "stopMotionUpdates";
};

/// `.result` for both: each terminates in exactly one `sendResultToJS` or one
/// error. `.none` would tell an app not to await a call that does reply, and a
/// declared `.result` that never replied would park the caller until the
/// page's timeout.
///
/// `.live` for both: they dispatch and do the thing. `.unavailable` is for an
/// action that dispatches and refuses, which neither is — a refusal here is a
/// specific condition (motion not configured, no device motion, CoreMotion
/// absent), never the action's normal answer.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.start_motion_updates, .reply = .result },
    .{ .name = A.stop_motion_updates, .reply = .result },
};

/// The event the stream carries, spelled as `sendToWeb` spells it.
///
/// No `craft:` prefix and no colon: this is the iOS vocabulary, and it is why
/// `ios_events.Event` exists separately from `capabilities.Channel`. Emitting
/// a `craft:`-style name here would fire an event with no subscriber.
pub const event: ios_events.Event = .motion_update;

/// Pinned as a literal so a test can compare it against `event.eventName()`
/// without the comparison being a tautology over one constant.
pub const event_name = "craftMotionUpdate";

/// Swift's default when `interval` is absent: 100 **milliseconds**
/// (`CraftApp.swift:860`). Android's injected JS defaults identically.
pub const default_interval_ms: f64 = 100;

/// Both replies, as the bare JSON fragment `resolveCallback(…, result: true)`
/// produces under `.fragmentsAllowed`. Not `{"ok":true}`.
const reply_true = "true";

/// Emitted into Info.plist by `packages/ios/src/index.ts:192` iff
/// `config.enableMotionSensors` — the flag with no Zig mirror. See the module
/// comment for what this proxy claims and what it does not.
const key_motion_usage = "NSMotionUsageDescription";

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host without touching
/// CoreMotion.
const Route = enum { start, stop };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.start_motion_updates)) return .start;
    if (std.mem.eql(u8, action, A.stop_motion_updates)) return .stop;
    return null;
}

pub const MotionBridge = struct {
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
            .start => self.startMotionUpdates(data),
            .stop => self.stopMotionUpdates(data),
        };
    }

    /// `case "startMotionUpdates"` (`CraftApp.swift:858-862`, `:3752-3785`).
    ///
    /// Every fallible step runs before the framework call, so the reply is
    /// sent only once there is nothing left that can fail: payload, config
    /// gate, six handler selectors, four dispatcher selectors, the operation
    /// queue, the manager, and `isDeviceMotionAvailable`. `startDeviceMotion…`
    /// itself returns void and cannot report anything.
    fn startMotionUpdates(self: *Self, data: []const u8) !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return bridge_error.BridgeError.InvalidJSON;
        defer parsed.deinit();
        const seconds = try intervalSeconds(parsed.value);

        try requireMotionConfigured();

        // Resolved here, not in the handler: the handler runs after this frame
        // is gone, where a `sel_registerName` failure could only be logged.
        const sels = try Sels.resolve();

        const sel_available = try selector("isDeviceMotionAvailable");
        const sel_set_interval = try selector("setDeviceMotionUpdateInterval:");
        const sel_start = try selector("startDeviceMotionUpdatesToQueue:withHandler:");
        const sel_stop = try selector("stopDeviceMotionUpdates");
        const queue = try mainOperationQueue();

        const mgr = try ensureManager();

        if (!objc.msgSendBool(mgr, sel_available)) {
            // The simulator's answer, and some hardware's. Swift's `guard`
            // rejects here too. Starting anyway would emit zeroes that no
            // sensor measured, which is the one outcome worse than an error.
            std.log.warn(
                "startMotionUpdates refused: isDeviceMotionAvailable is NO — there is no " ++
                    "device-motion service here (a simulator reports this), and a stream of " ++
                    "zeroes would be readings nothing took",
                .{},
            );
            return bridge_error.BridgeError.PlatformNotSupported;
        }

        // CoreMotion does not define a second start over a live one. Stopping
        // first makes a re-`start` with a new interval mean exactly one stream
        // at the new rate.
        if (isStreaming()) objc.msgSend(mgr, sel_stop);

        const IntervalFn = *const fn (Id, Id, f64) callconv(.c) void;
        const set_interval: IntervalFn = @ptrCast(&objc.objc_msgSend);
        set_interval(mgr, sel_set_interval, seconds);

        // Armed before the framework call, never after: the handler is a
        // global block with no captures, so `stream` is the only place it can
        // read its selectors from, and one that fired before `msgSend`
        // returned would otherwise drop the first sample.
        armStream(sels);

        const StartFn = *const fn (Id, Id, Id, *const anyopaque) callconv(.c) void;
        const start: StartFn = @ptrCast(&objc.objc_msgSend);
        start(mgr, sel_start, queue, @ptrCast(&motion_block));

        bridge_error.sendResultToJS(self.allocator, A.start_motion_updates, reply_true);
    }

    /// `case "stopMotionUpdates"` (`CraftApp.swift:863-865`, `:3787-3790`).
    ///
    /// `data` is accepted and ignored, exactly as Swift reads nothing out of
    /// `body`. Parsing it would invent a way for the call to fail that the
    /// spec does not have — `ios_dispatch.payloadOf` hands this `"{}"` anyway.
    ///
    /// Disarming happens whether or not a manager exists, and it happens
    /// *before* the framework call rather than after. A handler block already
    /// queued on the main queue can still run once
    /// `stopDeviceMotionUpdates` has returned; with `stream` cleared it finds
    /// no selectors and emits nothing, so "stopped" means stopped from the
    /// page's side of the bridge and not merely from CoreMotion's. Ordering it
    /// first is what makes that true without assuming this dispatch and the
    /// handler share the main thread — the same assumption `stream_mutex`
    /// declines to make.
    fn stopMotionUpdates(self: *Self, data: []const u8) !void {
        if (!is_darwin) return error.UnsupportedPlatform;
        _ = data;

        disarmStream();

        if (manager) |mgr| {
            const sel_stop = try selector("stopDeviceMotionUpdates");
            objc.msgSend(mgr, sel_stop);
        }

        bridge_error.sendResultToJS(self.allocator, A.stop_motion_updates, reply_true);
    }
};

// =============================================================================
// The config gate.
// =============================================================================

/// Refuse unless the app was built with `enableMotionSensors`.
///
/// See the module comment for why the Info.plist key is an exact proxy for the
/// flag and what that does and does not claim.
fn requireMotionConfigured() !void {
    if (!is_darwin) return error.UnsupportedPlatform;

    if (try infoPlistHas(key_motion_usage)) return;

    std.log.warn(
        "startMotionUpdates refused: Info.plist has no {s}, so this app was not built with " ++
            "motion sensors enabled",
        .{key_motion_usage},
    );
    return bridge_error.BridgeError.PermissionDenied;
}

/// Whether the main bundle's Info.plist carries `key`.
///
/// Errors rather than answering `false` when the runtime itself will not
/// cooperate: "there is no NSBundle class" and "this app did not ask for
/// motion" are different facts, and collapsing them would blame the app's
/// configuration for a broken process. Every runtime result is guarded.
fn infoPlistHas(comptime key: [*:0]const u8) !bool {
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
    return objc.msgSendId1(bundle, sel_lookup, ns_key) != null;
}

// =============================================================================
// The manager and the queue.
// =============================================================================

fn selector(name: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.sel_registerName(name) orelse error.SelectorNotFound;
}

/// The one `CMMotionManager` this module owns.
///
/// Module-level because `ios_dispatch` builds a fresh `MotionBridge` per
/// dispatch and drops it again: a manager held on the bridge would be released
/// the instant `startMotionUpdates` returned, and the stream with it. Swift's
/// is an ivar on a coordinator that outlives every call, for the same reason.
var manager: Id = null;

fn ensureManager() !*anyopaque {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (manager) |existing| return existing;

    const CMMotionManager = objc.objc_getClass("CMMotionManager") orelse {
        // Not a device without sensors — a process without CoreMotion at
        // all. The generated app always has it (`CraftApp.swift:15` is
        // `import CoreMotion`, and swiftc links what it imports). A bare Zig
        // binary that has loaded nothing else does not; a host test binary
        // linking Cocoa and WebKit does, transitively — which is why the
        // class's presence is never used as a proxy for anything.
        std.log.warn(
            "startMotionUpdates refused: there is no CMMotionManager class in this process, " ++
                "so CoreMotion is not loaded here",
            .{},
        );
        return bridge_error.BridgeError.PlatformNotSupported;
    };

    const created = (try objc.allocInit(CMMotionManager)) orelse return error.NativeCallFailed;
    manager = created;
    return created;
}

/// `[NSOperationQueue mainQueue]` — Swift's `to: .main` (`CraftApp.swift:3761`).
fn mainOperationQueue() !*anyopaque {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSOperationQueue = objc.objc_getClass("NSOperationQueue") orelse
        return error.ClassNotFound;
    const sel_main = try selector("mainQueue");
    return objc.msgSendId(NSOperationQueue, sel_main) orelse error.NativeCallFailed;
}

// =============================================================================
// The selectors the handler needs, resolved while an error is still deliverable.
// =============================================================================

/// Everything the handler block will send.
///
/// Copied into `stream` rather than looked up per sample: at 100 Hz this is a
/// hot path, and — more importantly — a `sel_registerName` failure inside the
/// handler could only be logged, never turned into an answer for anybody.
const Sels = struct {
    user_acceleration: Id,
    gravity: Id,
    attitude: Id,
    roll: Id,
    pitch: Id,
    yaw: Id,

    fn resolve() !Sels {
        if (!is_darwin) return error.UnsupportedPlatform;
        return .{
            .user_acceleration = try selector("userAcceleration"),
            .gravity = try selector("gravity"),
            .attitude = try selector("attitude"),
            .roll = try selector("roll"),
            .pitch = try selector("pitch"),
            .yaw = try selector("yaw"),
        };
    }
};

// =============================================================================
// The stream's state. The handler captures nothing, so this is where it reads.
// =============================================================================

const Stream = struct {
    /// Non-null exactly while updates are meant to be delivered. The handler
    /// reads its selectors here, and a null is what makes a late callback a
    /// no-op instead of an event after `stopMotionUpdates`.
    sels: ?Sels = null,
    /// One fault line per start.
    ///
    /// A handler that fails at 100 Hz would otherwise write a hundred log
    /// lines a second and drown the thing being diagnosed — the same reason
    /// `ios_events` counts drops instead of logging each one. The first fault
    /// after each start is logged with its reason; the rest are silent.
    fault_logged: bool = false,
};

var stream: Stream = .{};

/// Guarded even though both sides normally run on the main thread — the
/// dispatch is a WebKit main-thread callback and the handler is on
/// `mainQueue`. "It should always be the main thread" is not a guard, and
/// `NSOperationQueue.mainQueue` is a promise about *scheduling*, not one this
/// module can enforce.
var stream_mutex: compat_mutex.Mutex = .{};

fn armStream(sels: Sels) void {
    stream_mutex.lock();
    defer stream_mutex.unlock();
    stream = .{ .sels = sels, .fault_logged = false };
}

fn disarmStream() void {
    stream_mutex.lock();
    defer stream_mutex.unlock();
    stream = .{};
}

fn streamSels() ?Sels {
    stream_mutex.lock();
    defer stream_mutex.unlock();
    return stream.sels;
}

fn isStreaming() bool {
    stream_mutex.lock();
    defer stream_mutex.unlock();
    return stream.sels != null;
}

/// True the first time it is called since the last `armStream`.
fn claimFaultLog() bool {
    stream_mutex.lock();
    defer stream_mutex.unlock();
    if (stream.fault_logged) return false;
    stream.fault_logged = true;
    return true;
}

// =============================================================================
// The handler block. Global, so `Block_copy` is the identity function.
// =============================================================================

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// `CMDeviceMotionHandler` — `void (^)(CMDeviceMotion *motion, NSError *error)`.
const MotionBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const fn (*const anyopaque, Id, Id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

/// 1 << 28. A global block is never copied: `Block_copy` returns the same
/// pointer. No heap block, no copy/dispose pair, no descriptor lifetime — which
/// is what makes it safe to hand to an API that holds it for the life of the
/// stream.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

extern var _NSConcreteGlobalBlock: anyopaque;

const motion_block_descriptor = BlockDescriptor{ .size = @sizeOf(MotionBlock) };

/// Guarded on `is_darwin` the way `ios_async.zig` guards its pool: off Darwin
/// the initialiser would name `_NSConcreteGlobalBlock`, which is a symbol only
/// libsystem_blocks has.
const motion_block: MotionBlock = if (is_darwin) .{
    .isa = &_NSConcreteGlobalBlock,
    .flags = BLOCK_IS_GLOBAL,
    .invoke = motionHandler,
    .descriptor = &motion_block_descriptor,
} else undefined;

/// One device-motion callback: read, shape, emit. Never reply — there is no
/// call waiting on it.
///
/// Three ways out without an event, and none of them invents one:
///
///  - **not armed** — a callback that outlived `stopMotionUpdates`, or one for
///    a stream this module never started. Silent: it is the expected shape of
///    a queued block draining after a stop, not a fault.
///  - **no sample** — Swift's `guard let motion = motion else { return }`. The
///    iOS event vocabulary has no `craftMotionError`, so there is nobody to
///    tell; emitting zeroes instead would be a reading nothing took.
///  - **unshapeable** — a nil `attitude`, or a non-finite double.
///    `ios_events.formatEvent` inlines the detail as a raw JSON literal, so a
///    `nan` would not produce a bad number, it would produce a `dispatchEvent`
///    call the page cannot parse and take the whole event with it. Dropping
///    one sample is the smaller loss.
fn motionHandler(_: *const anyopaque, motion: Id, err: Id) callconv(.c) void {
    if (!is_darwin) return;

    const sels = streamSels() orelse return;

    if (motion == null) {
        if (claimFaultLog()) {
            std.log.warn(
                "craftMotionUpdate: CoreMotion delivered no sample (error={s}); no event is " ++
                    "emitted for a reading that was not taken. Further faults in this stream " ++
                    "are not logged",
                .{readNSString(err, "localizedDescription") orelse "(none)"},
            );
        }
        return;
    }

    const sample = readSample(motion, sels) catch |read_err| {
        if (claimFaultLog()) {
            std.log.warn(
                "craftMotionUpdate: could not read the CMDeviceMotion ({}); dropping the " ++
                    "sample. Further faults in this stream are not logged",
                .{read_err},
            );
        }
        return;
    };

    const allocator = std.heap.c_allocator;
    const detail = shapeDetail(allocator, sample) catch |shape_err| {
        if (claimFaultLog()) {
            std.log.warn(
                "craftMotionUpdate: could not shape the detail ({}); dropping the sample. " ++
                    "Further faults in this stream are not logged",
                .{shape_err},
            );
        }
        return;
    };
    defer allocator.free(detail);

    // Safe from any thread: it copies, queues and hops to the main queue
    // itself. Never `evaluateJavaScript` from here.
    ios_events.emit(event, detail);
}

/// `CMAcceleration` — `typedef struct { double x, y, z; }`, 24 bytes.
///
/// Kept separate from the wire-shaped `Vector3` so the ABI type and the JSON
/// type can be reasoned about independently; they happen to have the same
/// three fields in the same order, and the conversion below is where that
/// coincidence is stated rather than assumed.
const CMAcceleration = extern struct { x: f64, y: f64, z: f64 };

/// The bare shape of an `objc_msgSend` symbol, before it is cast to the
/// signature of the message being sent.
const MsgSendEntry = *const fn () callconv(.c) void;

/// The `objc_msgSend` entry point a 24-byte struct return needs on this arch.
///
/// x86_64 classes anything over 16 bytes as MEMORY and returns it through a
/// caller-provided pointer, which is `objc_msgSend_stret`. arm64 routes every
/// return shape through `objc_msgSend` and does not export the `_stret`
/// variant at all — naming it there is an undefined symbol at app link, which
/// is exactly why `objc_runtime.msgSendStret` (which selects on `@sizeOf`
/// alone) must not be used for this.
const acceleration_entry: MsgSendEntry = if (!is_darwin)
    undefined
else if (builtin.target.cpu.arch == .x86_64)
    &objc.objc_msgSend_stret
else
    &objc.objc_msgSend;

/// Read one `CMDeviceMotion` into plain doubles.
///
/// `objc_msgSend_fpret` is not used and must not be: it is `long double`-only
/// on x86_64 and absent on arm64, so a `double`-returning property goes through
/// the plain symbol. `macos.zig`'s `msgSend0Double` does the same.
fn readSample(motion: Id, sels: Sels) !MotionSample {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (motion == null) return error.NativeCallFailed;

    const IdFn = *const fn (Id, Id) callconv(.c) Id;
    const send_id: IdFn = @ptrCast(&objc.objc_msgSend);

    const DoubleFn = *const fn (Id, Id) callconv(.c) f64;
    const send_double: DoubleFn = @ptrCast(&objc.objc_msgSend);

    const VectorFn = *const fn (Id, Id) callconv(.c) CMAcceleration;
    const send_vector: VectorFn = @ptrCast(acceleration_entry);

    // `attitude` is an object, and a nil one would make the three doubles
    // below `objc_msgSend` to nil — which returns 0.0 rather than crashing, so
    // an unguarded read would emit a flat, plausible, entirely invented
    // orientation.
    const attitude = send_id(motion, sels.attitude) orelse return error.NoAttitudeInSample;

    const acceleration = send_vector(motion, sels.user_acceleration);
    const gravity = send_vector(motion, sels.gravity);

    return .{
        .acceleration = .{ .x = acceleration.x, .y = acceleration.y, .z = acceleration.z },
        // Swift's three renames, performed visibly: yaw -> alpha, pitch ->
        // beta, roll -> gamma (`CraftApp.swift:3771-3773`).
        .rotation = .{
            .alpha = send_double(attitude, sels.yaw),
            .beta = send_double(attitude, sels.pitch),
            .gamma = send_double(attitude, sels.roll),
        },
        .gravity = .{ .x = gravity.x, .y = gravity.y, .z = gravity.z },
    };
}

/// A zero-argument `NSString`-returning property, as bytes. Null for a nil
/// object, a nil string, or a selector that will not register — all three are
/// "nothing to log", never a crash. The slice borrows the string's internal
/// buffer, which is valid for the current autorelease pool; the only caller
/// logs it immediately.
fn readNSString(object: Id, comptime name: [*:0]const u8) ?[]const u8 {
    if (!is_darwin) return null;
    if (object == null) return null;

    const sel = objc.sel_registerName(name) orelse return null;
    const value = objc.msgSendId(object, sel) orelse return null;
    const utf8 = objc.getNSStringUTF8(value) orelse return null;
    return std.mem.span(utf8);
}

// =============================================================================
// The payload. Pure, and pinned before anything can drift.
// =============================================================================

/// The `interval` field, converted to the seconds
/// `deviceMotionUpdateInterval` wants.
///
/// Field name, unit and default all come from the Swift dispatcher
/// (`body["interval"] as? Double ?? 100`, then `interval / 1000.0`),
/// cross-checked against Android's injected JS, because iOS's injected JS never
/// defined the method at all.
///
/// Two deliberate divergences from `as? Double`, both in the direction of
/// saying something rather than guessing:
///
///  - **A present-but-not-numeric `interval` is refused.** Swift silently falls
///    back to 100, and — because Foundation bridges `__NSCFBoolean` to
///    `NSNumber` — turns `{"interval":true}` into a 1 ms interval, which is a
///    very expensive way to mistype a number. Refusing is the same call
///    `bridge_mobile_watch.zig` documents for its missing-`context` hang.
///  - **A non-finite `interval` is refused.** JSON has no `NaN` literal, but
///    `1e400` parses to `.number_string` and then to `inf`, and an infinite
///    `NSTimeInterval` is undefined behaviour inside CoreMotion rather than a
///    slow update.
///
/// An *absent* `interval` is not a divergence: 100 ms is the real contract and
/// is honoured.
pub fn intervalSeconds(payload: std.json.Value) !f64 {
    const object = switch (payload) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    const ms: f64 = if (object.get("interval")) |field| switch (field) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        // `std.json` parks a literal that overflows `i64`, or parses
        // non-finite, in `.number_string` with the scanner-validated source
        // bytes. It is still a number the page sent, so it is read rather than
        // refused for its spelling; the finiteness check below is what catches
        // `1e400`.
        .number_string => |s| std.fmt.parseFloat(f64, s) catch
            return bridge_error.BridgeError.InvalidParameter,
        else => return bridge_error.BridgeError.InvalidParameter,
    } else default_interval_ms;

    if (!std.math.isFinite(ms)) return bridge_error.BridgeError.InvalidParameter;
    return ms / 1000.0;
}

// =============================================================================
// The event detail. Pure, and the bytes are the contract.
// =============================================================================

/// One three-axis reading, in the key spelling Swift uses for `acceleration`
/// and `gravity`.
pub const Vector3 = struct { x: f64, y: f64, z: f64 };

/// Swift's `rotation`: `CMAttitude`'s yaw, pitch and roll, **in radians**,
/// renamed to alpha/beta/gamma on the way out.
///
/// Named `Attitude` rather than `Rotation` so nothing in Zig can mistake it for
/// `CMDeviceMotion.rotationRate`, which is the gyroscope and which Swift never
/// reads. The wire key stays `rotation`, because that is what ships.
pub const Attitude = struct {
    /// `CMAttitude.yaw` (`CraftApp.swift:3771`).
    alpha: f64,
    /// `CMAttitude.pitch` (`:3772`).
    beta: f64,
    /// `CMAttitude.roll` (`:3773`).
    gamma: f64,
};

/// Everything one `craftMotionUpdate` carries.
pub const MotionSample = struct {
    /// `CMDeviceMotion.userAcceleration` — G's, gravity already removed.
    acceleration: Vector3,
    /// `CMDeviceMotion.attitude` — radians.
    rotation: Attitude,
    /// `CMDeviceMotion.gravity` — G's.
    gravity: Vector3,
};

/// One JSON number.
///
/// The buffer is `std.fmt.float.bufferSize(.decimal, f64)` — 347 bytes — and
/// not a byte less. `{d}` renders decimal notation, never scientific, so
/// `f64` extremes are long: `1e300` is 301 characters and the smallest
/// subnormal is 326. A `[64]u8` here would turn a legal reading into
/// `NoSpaceLeft`, which is the kind of failure that only shows up on a device.
///
/// A non-finite value is refused rather than printed. `ios_events.formatEvent`
/// inlines the detail as a raw JSON literal, so a single `nan` would not
/// produce a bad number — it would produce a `dispatchEvent(…)` call the page
/// cannot parse, taking the whole event with it. CoreMotion should never hand
/// one back; that is a reason to check cheaply, not a reason to assume.
fn appendNumber(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: f64) !void {
    if (!std.math.isFinite(value)) return bridge_error.BridgeError.InvalidParameter;
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{value}));
}

/// One `{"k":n,"k":n,"k":n}` sub-object. The keys differ between
/// `acceleration`/`gravity` (x/y/z) and `rotation` (alpha/beta/gamma), so they
/// are a parameter; the shape does not.
fn appendVector(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    keys: [3][]const u8,
    values: [3]f64,
) !void {
    try out.append(allocator, '{');
    for (keys, values, 0..) |key, value, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try out.appendSlice(allocator, key);
        try out.appendSlice(allocator, "\":");
        try appendNumber(allocator, out, value);
    }
    try out.append(allocator, '}');
}

/// The `detail` of one `craftMotionUpdate`, as the complete JSON value
/// `ios_events.emit` wants.
///
/// Three keys, Swift's three, in Swift's source order. Swift builds a
/// `Dictionary`, so its own key order is arbitrary and no caller can depend on
/// it — but a *test* can only pin bytes that are deterministic, so one order is
/// chosen and held. Nothing here is a string, so nothing needs escaping: every
/// value is a number this function formats itself.
///
/// Caller owns the returned slice.
pub fn shapeDetail(allocator: std.mem.Allocator, sample: MotionSample) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const xyz = [3][]const u8{ "x", "y", "z" };

    try out.appendSlice(allocator, "{\"acceleration\":");
    try appendVector(allocator, &out, xyz, .{
        sample.acceleration.x,
        sample.acceleration.y,
        sample.acceleration.z,
    });
    try out.appendSlice(allocator, ",\"rotation\":");
    try appendVector(allocator, &out, .{ "alpha", "beta", "gamma" }, .{
        sample.rotation.alpha,
        sample.rotation.beta,
        sample.rotation.gamma,
    });
    try out.appendSlice(allocator, ",\"gravity\":");
    try appendVector(allocator, &out, xyz, .{
        sample.gravity.x,
        sample.gravity.y,
        sample.gravity.z,
    });
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Tests — host-only.
//
// Everything that decides page-visible bytes is pure and pinned here: routing
// in both directions, the two replies, the three detail keys and their order,
// the interval's unit and default, non-finite refusal, and a float buffer big
// enough for 1e300.
//
// Nothing here constructs the *module-level* `CMMotionManager`: on the host the
// Info.plist gate refuses before `ensureManager` is reached, and `manager ==
// null` is asserted rather than assumed, because "it would refuse" is a claim
// and not an observation until it is.
//
// `objc_getClass("CMMotionManager")` is **not** null on this host, and nothing
// in this file treats it as though it were — see the availability test below,
// which allocates a manager of its own precisely so that
// `isDeviceMotionAvailable` is sent to a real object rather than to nil. The
// Objective-C paths exercised for real are the ones with no device behind them:
// selector interning, the block's global flags, the struct-return entry point,
// the availability refusal, and the handler's no-op paths.
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    // Table -> dispatch. A row here is what `craft.capabilities()` shows an
    // app; declaring an action `handleMessage` answers with UnknownAction
    // would tell an app craft serves something the shim is actually serving.
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    for (capability_actions) |decl| {
        try testing.expect(routeFor(decl.name) != null);
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        // `.live` must not carry a reason; only `.unavailable` may.
        try testing.expect(decl.reason == null);
    }
}

test "every route the dispatcher has is a declared action" {
    // Dispatch -> table, the direction that catches a served-but-undeclared
    // action: it works, and `craft.capabilities()` says it does not exist.
    inline for (std.enums.values(Route)) |route| {
        const name = switch (route) {
            .start => A.start_motion_updates,
            .stop => A.stop_motion_updates,
        };
        var found = false;
        for (capability_actions) |decl| {
            if (std.mem.eql(u8, decl.name, name)) found = true;
        }
        try testing.expect(found);
        try testing.expectEqual(route, routeFor(name).?);
    }
}

test "the action names match the Swift case labels exactly" {
    // `test/ios_conformance_test.zig` scans the `A` block against
    // `CraftApp.swift`'s `case "…"` labels, but only as sets — this pins the
    // spelling at the point a reader is looking at it.
    try testing.expectEqualStrings("startMotionUpdates", A.start_motion_updates);
    try testing.expectEqualStrings("stopMotionUpdates", A.stop_motion_updates);
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = MotionBridge.init(testing.allocator);
    defer bridge.deinit();

    const E = bridge_error.BridgeError;

    // Casing is how a real typo arrives.
    try testing.expectError(E.UnknownAction, bridge.handleMessage("startmotionupdates", "{}"));
    // The plausible near misses, including the shapes other platforms use.
    try testing.expectError(E.UnknownAction, bridge.handleMessage("startMotion", "{}"));
    try testing.expectError(E.UnknownAction, bridge.handleMessage("startDeviceMotionUpdates", "{}"));
    try testing.expectError(E.UnknownAction, bridge.handleMessage("stopMotion", "{}"));
    // Neighbours that belong to other modules; two modules answering one
    // action would make `ios_dispatch`'s first-match routing order-dependent.
    try testing.expectError(E.UnknownAction, bridge.handleMessage("getDeviceInfo", "{}"));
    try testing.expectError(E.UnknownAction, bridge.handleMessage("getCurrentPosition", "{}"));
    try testing.expectError(E.UnknownAction, bridge.handleMessage("noSuchAction", "{}"));

    // And `routeFor` agrees, so the two cannot drift apart.
    try testing.expect(routeFor("startmotionupdates") == null);
    try testing.expect(routeFor("") == null);
}

test "both replies are the bare fragment true, not an object wrapper" {
    // `resolveCallback` serialises with `.fragmentsAllowed` and both Swift
    // paths pass `result: true` (`CraftApp.swift:3784`, `:865`). A page written
    // against `await craft.startMotionUpdates()` compares the resolved value,
    // so `{"ok":true}` would be truthy and wrong.
    try testing.expectEqualStrings("true", reply_true);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply_true, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.bool);
}

test "the event is the iOS spelling, and no capabilities.Channel can carry it" {
    // The first half is the contract: `sendToWeb("craftMotionUpdate", …)` is
    // what `test-bridges.html:397` listens for.
    try testing.expectEqualStrings(event_name, event.eventName());
    try testing.expectEqualStrings("craftMotionUpdate", event.eventName());
    try testing.expect(std.mem.indexOfScalar(u8, event.eventName(), ':') == null);

    // The second half is the reason `ios_events.Event` exists at all, and the
    // reason an earlier round of this module served nothing: every
    // `capabilities.Channel` name is `craft:`-prefixed, so none of them can
    // spell this. Emitting a desktop-spelled name would fire an event with no
    // subscriber — a stream that looks implemented and delivers nothing.
    for (std.enums.values(capabilities.Channel)) |channel| {
        try testing.expect(!std.mem.eql(u8, channel.eventName(), event_name));
        try testing.expect(std.mem.startsWith(u8, channel.eventName(), "craft:"));
    }
    // Non-vacuity: the loop above proves nothing over an empty enum.
    try testing.expect(std.enums.values(capabilities.Channel).len >= 40);
}

// -----------------------------------------------------------------------------
// The refusal paths.
// -----------------------------------------------------------------------------

test "off Darwin both actions refuse rather than pretend" {
    if (is_darwin) return error.SkipZigTest;

    var bridge = MotionBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.start_motion_updates, "{\"interval\":100}"),
    );
    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.stop_motion_updates, "{}"),
    );
}

test "without the usage description the gate refuses before any manager exists" {
    if (!is_darwin) return error.SkipZigTest;

    // A test runner's main bundle has no NSMotionUsageDescription, which is
    // exactly the shape of an app built with enableMotionSensors off. The
    // refusal must be the config one, and it must happen before CoreMotion is
    // touched — `manager` staying null is the observable half of that.
    try testing.expect(!try infoPlistHas(key_motion_usage));
    try testing.expectError(bridge_error.BridgeError.PermissionDenied, requireMotionConfigured());

    var bridge = MotionBridge.init(testing.allocator);
    defer bridge.deinit();
    try testing.expectError(
        bridge_error.BridgeError.PermissionDenied,
        bridge.handleMessage(A.start_motion_updates, "{}"),
    );
    try testing.expect(manager == null);
    try testing.expect(!isStreaming());
}

test "a bad payload is refused before the config gate, and never defaulted" {
    if (!is_darwin) return error.SkipZigTest;

    var bridge = MotionBridge.init(testing.allocator);
    defer bridge.deinit();
    const E = bridge_error.BridgeError;

    // Ordering matters here: parsing first means a page that sends a mistyped
    // interval learns *that*, rather than learning about the Info.plist.
    try testing.expectError(E.InvalidJSON, bridge.handleMessage(A.start_motion_updates, "{not json"));
    try testing.expectError(
        E.InvalidParameter,
        bridge.handleMessage(A.start_motion_updates, "{\"interval\":\"fast\"}"),
    );
    try testing.expect(manager == null);
}

test "stopMotionUpdates ignores its payload, exactly as Swift reads nothing" {
    if (!is_darwin) return error.SkipZigTest;

    // Swift's `case "stopMotionUpdates"` touches `body` not at all, so a
    // payload that would fail `startMotionUpdates`'s parse must not fail this.
    // This runs a handler all the way to `sendResultToJS`, which logs one
    // "failed to send bridge result to JS" warning: there is no webview in a
    // test runner. That warning is the evidence the reply was attempted — the
    // alternative, asserting only that no error came back, would also pass for
    // a handler that returned without replying at all.
    var bridge = MotionBridge.init(testing.allocator);
    defer bridge.deinit();

    try bridge.handleMessage(A.stop_motion_updates, "{not json");
    try bridge.handleMessage(A.stop_motion_updates, "{\"interval\":\"fast\"}");
    // And a stop with nothing running still answers: the postcondition the
    // page asked for holds, which is why `true` here is not a fabrication.
    try bridge.handleMessage(A.stop_motion_updates, "{}");
    try testing.expect(!isStreaming());
}

// -----------------------------------------------------------------------------
// The Objective-C surface a host can honestly exercise.
// -----------------------------------------------------------------------------

test "every selector the dispatcher and the handler need resolves on a real runtime" {
    if (!is_darwin) return error.SkipZigTest;

    // `sel_registerName` interns a name whether or not any class implements
    // it, so this proves the *spelling* is registrable — a typo would be a
    // selector that resolves and then does nothing on a device, which is the
    // failure this cannot catch and the reason every name is written out
    // against `CraftApp.swift` above.
    const sels = try Sels.resolve();
    try testing.expect(sels.user_acceleration != null);
    try testing.expect(sels.gravity != null);
    try testing.expect(sels.attitude != null);
    try testing.expect(sels.roll != null);
    try testing.expect(sels.pitch != null);
    try testing.expect(sels.yaw != null);

    for ([_][*:0]const u8{
        "isDeviceMotionAvailable",
        "setDeviceMotionUpdateInterval:",
        "startDeviceMotionUpdatesToQueue:withHandler:",
        "stopDeviceMotionUpdates",
        "mainQueue",
    }) |name| {
        try testing.expect((try selector(name)) != null);
    }

    // NSOperationQueue is Foundation, not CoreMotion, so it really is present
    // on the host — the queue path is the one piece of the start sequence a
    // host can run for real.
    try testing.expect((try mainOperationQueue()) != @as(?*anyopaque, null));
}

test "the availability guard really answers NO on a machine with no device motion" {
    if (!is_darwin) return error.SkipZigTest;

    // A correction, measured rather than assumed: `CMMotionManager.h` is
    // `API_UNAVAILABLE(macos)`, and an earlier note in this module concluded
    // from that that `objc_getClass("CMMotionManager")` is null on macOS. It
    // is **not** — CoreMotion ships on macOS and the class is present on this
    // runner. So "the host cannot reach CoreMotion" is not a guard, and
    // nothing in this file uses it as one.
    //
    // What *is* the guard is `isDeviceMotionAvailable`, and this exercises it
    // for real: a Mac has no device-motion service, exactly as a simulator has
    // none, and NO is the answer that must stop `startMotionUpdates` before it
    // streams zeroes nothing measured.
    const cls = objc.objc_getClass("CMMotionManager") orelse return error.SkipZigTest;

    const sel_available = try selector("isDeviceMotionAvailable");
    const sel_responds = objc.sel_registerName("respondsToSelector:") orelse
        return error.SelectorNotFound;
    const RespondsFn = *const fn (Id, Id, Id) callconv(.c) bool;
    const responds: RespondsFn = @ptrCast(&objc.objc_msgSend);

    // This test's own manager, never the module-level one: caching a manager
    // in `manager` here would change what every later test sees.
    const own = (try objc.allocInit(cls)) orelse return error.NativeCallFailed;
    defer objc.release(own);

    // Never send a selector the class does not implement — that is an
    // unrecognised-selector abort, not a test failure.
    if (!responds(own, sel_responds, sel_available)) return error.SkipZigTest;
    try testing.expect(!objc.msgSendBool(own, sel_available));

    // And the module's own manager is still unbuilt, because nothing in this
    // file has been allowed to reach `ensureManager`.
    try testing.expect(manager == null);
    try testing.expect(!isStreaming());
}

test "the handler block is global, so Block_copy cannot heap-copy it" {
    if (!is_darwin) return error.SkipZigTest;

    // `startDeviceMotionUpdatesToQueue:withHandler:` escapes the block and
    // holds it for the life of the stream. A stack block would be a dangling
    // call; a heap copy would need copy/dispose helpers this descriptor does
    // not have. BLOCK_IS_GLOBAL is what makes `Block_copy` the identity.
    try testing.expectEqual(&_NSConcreteGlobalBlock, motion_block.isa.?);
    try testing.expect(motion_block.flags & BLOCK_IS_GLOBAL != 0);
    try testing.expectEqual(@as(c_int, 0), motion_block.reserved);
    try testing.expectEqual(@as(c_ulong, @sizeOf(MotionBlock)), motion_block.descriptor.size);
    try testing.expectEqual(@as(c_ulong, 0), motion_block.descriptor.reserved);
}

test "a 24-byte CMAcceleration goes through the entry point its ABI requires" {
    // The trap `objc_runtime.msgSendStret` walks into: it picks
    // `objc_msgSend_stret` for anything over 16 bytes, and arm64 libobjc does
    // not export that symbol at all.
    try testing.expectEqual(@as(usize, 24), @sizeOf(CMAcceleration));
    try testing.expectEqual(@as(usize, 16), @offsetOf(CMAcceleration, "z"));

    if (!is_darwin) return error.SkipZigTest;
    if (comptime builtin.target.cpu.arch == .x86_64) {
        try testing.expectEqual(@as(MsgSendEntry, &objc.objc_msgSend_stret), acceleration_entry);
    } else {
        try testing.expectEqual(@as(MsgSendEntry, &objc.objc_msgSend), acceleration_entry);
        // Deliberately no "and it is not objc_msgSend_stret" assertion here:
        // writing that would *itself* reference the symbol arm64 libobjc does
        // not export, and this test would be the undefined symbol it exists to
        // prevent. The `expectEqual` above already pins the choice.
    }
}

// -----------------------------------------------------------------------------
// The stream's state, and the handler's three silent exits.
// -----------------------------------------------------------------------------

test "arming and disarming decide whether a callback is live" {
    if (!is_darwin) return error.SkipZigTest;
    defer disarmStream();

    try testing.expect(!isStreaming());
    try testing.expect(streamSels() == null);

    armStream(try Sels.resolve());
    try testing.expect(isStreaming());
    try testing.expect(streamSels() != null);

    disarmStream();
    try testing.expect(!isStreaming());
    try testing.expect(streamSels() == null);
}

test "the fault log fires once per start, so a broken stream cannot flood" {
    if (!is_darwin) return error.SkipZigTest;
    defer disarmStream();

    armStream(try Sels.resolve());
    try testing.expect(claimFaultLog());
    try testing.expect(!claimFaultLog());
    try testing.expect(!claimFaultLog());

    // A restart is a new stream and gets its own line.
    armStream(try Sels.resolve());
    try testing.expect(claimFaultLog());
}

test "a callback with no stream armed does nothing at all" {
    if (!is_darwin) return error.SkipZigTest;

    // The shape of a block draining off the main queue after
    // `stopMotionUpdates`. It must not emit, and it must not log — a queued
    // block after a stop is expected, not a fault.
    disarmStream();
    motionHandler(@ptrCast(&motion_block), null, null);

    // Nothing consumed the fault budget, because the handler returned before
    // reaching it.
    armStream(try Sels.resolve());
    defer disarmStream();
    try testing.expect(claimFaultLog());
}

test "a callback with no sample emits nothing and spends the fault budget" {
    if (!is_darwin) return error.SkipZigTest;
    defer disarmStream();

    // Swift's `guard let motion = motion else { return }`. The point of the
    // test is rule 1: there is no `craftMotionError` in the iOS vocabulary, so
    // a nil sample must produce *no* event rather than a plausible one full of
    // zeroes. `claimFaultLog` returning false afterwards is the evidence the
    // handler took the no-sample exit and not the emit path — the emit path
    // never touches the fault budget.
    armStream(try Sels.resolve());
    motionHandler(@ptrCast(&motion_block), null, null);
    try testing.expect(!claimFaultLog());
}

// -----------------------------------------------------------------------------
// The payload contract.
// -----------------------------------------------------------------------------

fn intervalOf(json: []const u8) !f64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return intervalSeconds(parsed.value);
}

test "interval is milliseconds and arrives as seconds" {
    // `CraftApp.swift:3758`: `let updateInterval = interval / 1000.0`. Getting
    // the unit wrong by 1000 is a sensor that either never fires or melts the
    // battery, and neither looks like a bug from the page.
    try testing.expectEqual(@as(f64, 0.1), try intervalOf("{\"interval\":100}"));
    try testing.expectEqual(@as(f64, 0.02), try intervalOf("{\"interval\":20}"));
    try testing.expectEqual(@as(f64, 1.0), try intervalOf("{\"interval\":1000}"));
}

test "an absent interval defaults to Swift's 100ms, not to zero" {
    // The one place a default is the *right* answer: `?? 100` is the shipped
    // contract on iOS and Android alike. Defaulting to 0 would ask CoreMotion
    // for the fastest rate the hardware has.
    try testing.expectEqual(@as(f64, 0.1), try intervalOf("{}"));
    // A caller that passes unrelated fields must not be refused, since Swift
    // reads only this one key.
    try testing.expectEqual(@as(f64, 0.1), try intervalOf("{\"callbackId\":\"cb_7\"}"));
}

test "an integer and a float interval mean the same thing" {
    // `std.json` produces `.integer` for a bare `100` and `.float` for `100.0`,
    // and a page writing either means the same thing. Handling only one arm is
    // the classic way to drop a field the page really did send.
    try testing.expectEqual(try intervalOf("{\"interval\":100}"), try intervalOf("{\"interval\":100.0}"));
    try testing.expectEqual(@as(f64, 0.0165), try intervalOf("{\"interval\":16.5}"));
    // Negative and zero pass through, as Swift passes them through: the header
    // says the property is capped to hardware minimum and maximum, so refusing
    // them here would invent a rejection the shim does not have.
    try testing.expectEqual(@as(f64, 0.0), try intervalOf("{\"interval\":0}"));
    try testing.expectEqual(@as(f64, -0.005), try intervalOf("{\"interval\":-5}"));
}

test "the field name the page sends is the one that is read" {
    // `body["interval"]` in the Swift dispatcher; `startMotionUpdates(interval
    // || 100)` in Android's injected JS. The plausible wrong names must read as
    // *absent*, or a handler bound to the wrong key would still pass the tests
    // above by falling into the default.
    try testing.expectEqual(@as(f64, 0.1), try intervalOf("{\"updateInterval\":20}"));
    try testing.expectEqual(@as(f64, 0.1), try intervalOf("{\"frequency\":20}"));
    try testing.expectEqual(@as(f64, 0.1), try intervalOf("{\"intervalMs\":20}"));
}

test "a non-numeric interval is refused rather than silently defaulted" {
    // Swift's `as? Double` falls back to 100 for a string and — because
    // Foundation bridges `__NSCFBoolean` to `NSNumber` — turns `true` into a
    // 1 ms interval. Both are a mistyped field acted on as if it were valid.
    const E = bridge_error.BridgeError;
    try testing.expectError(E.InvalidParameter, intervalOf("{\"interval\":\"100\"}"));
    try testing.expectError(E.InvalidParameter, intervalOf("{\"interval\":true}"));
    try testing.expectError(E.InvalidParameter, intervalOf("{\"interval\":null}"));
    try testing.expectError(E.InvalidParameter, intervalOf("{\"interval\":[100]}"));
    try testing.expectError(E.InvalidParameter, intervalOf("{\"interval\":{\"ms\":100}}"));
}

test "an out-of-range interval literal is read, and refused only if it is not finite" {
    // `std.json` parks both of these in `.number_string`: one is an integer too
    // big for `i64`, the other parses non-finite. They are different answers.
    // 1e20 ms is an absurd interval and still a number the page sent, so it is
    // carried; `1e400` is infinity, which is undefined behaviour inside
    // CoreMotion rather than a slow update.
    try testing.expectEqual(@as(f64, 1e17), try intervalOf("{\"interval\":100000000000000000000}"));
    try testing.expectError(bridge_error.BridgeError.InvalidParameter, intervalOf("{\"interval\":1e400}"));
    try testing.expectError(bridge_error.BridgeError.InvalidParameter, intervalOf("{\"interval\":-1e400}"));
}

test "a payload that is not an object is bad JSON, not a missing field" {
    const E = bridge_error.BridgeError;
    var array = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[100]", .{});
    defer array.deinit();
    try testing.expectError(E.InvalidJSON, intervalSeconds(array.value));

    var scalar = try std.json.parseFromSlice(std.json.Value, testing.allocator, "100", .{});
    defer scalar.deinit();
    try testing.expectError(E.InvalidJSON, intervalSeconds(scalar.value));
}

// -----------------------------------------------------------------------------
// The event detail contract.
// -----------------------------------------------------------------------------

/// One number out of a parsed detail, whichever way `std.json` chose to carry
/// it.
///
/// `{d}` renders decimal notation, so `1e300` comes back as 301 digits with no
/// decimal point and no exponent — which `std.json` reads as an integer
/// literal, fails to fit in `i64`, and parks in `.number_string`. Reading only
/// `.float` would make the extreme-value test panic on exactly the values it
/// exists to check.
fn numberOf(value: std.json.Value) !f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| try std.fmt.parseFloat(f64, s),
        else => error.NotANumber,
    };
}

const sample_reading = MotionSample{
    .acceleration = .{ .x = 0.01, .y = -0.5, .z = 0.25 },
    .rotation = .{ .alpha = 1.5, .beta = -0.25, .gamma = 0.125 },
    .gravity = .{ .x = 0.0, .y = -1.0, .z = 0.5 },
};

test "the detail is Swift's three keys, with Swift's sub-keys, as exact bytes" {
    // `CraftApp.swift:3764-3780`, verbatim. `sendToWeb` inlines this as the
    // `detail` literal, exactly as `ios_events.formatEvent` does, so these are
    // the bytes that reach the page's `e.detail` either way.
    const json = try shapeDetail(testing.allocator, sample_reading);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"acceleration\":{\"x\":0.01,\"y\":-0.5,\"z\":0.25}," ++
            "\"rotation\":{\"alpha\":1.5,\"beta\":-0.25,\"gamma\":0.125}," ++
            "\"gravity\":{\"x\":0,\"y\":-1,\"z\":0.5}}",
        json,
    );

    // And it parses as the nested object the page indexes into, rather than as
    // a string that happens to contain one.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const detail = parsed.value.object;
    try testing.expectEqual(@as(usize, 3), detail.count());
    try testing.expectEqual(@as(f64, -0.5), detail.get("acceleration").?.object.get("y").?.float);
    try testing.expectEqual(@as(f64, 1.5), detail.get("rotation").?.object.get("alpha").?.float);
    try testing.expectEqual(@as(usize, 3), detail.get("gravity").?.object.count());
}

test "the detail survives being inlined into the dispatchEvent call" {
    // The other half of the contract: `ios_events.formatEvent` splices these
    // bytes in as a JSON *literal*, not as a quoted string. Shaping the detail
    // correctly and then having it arrive as a string would leave every
    // `e.detail.acceleration` undefined, which is indistinguishable from the
    // sensor never firing.
    const json = try shapeDetail(testing.allocator, sample_reading);
    defer testing.allocator.free(json);

    // Nothing in a detail of pure numbers can need escaping, and a stray quote
    // would end the CustomEvent argument early.
    try testing.expect(std.mem.indexOfScalar(u8, json, '\'') == null);
    try testing.expect(std.mem.indexOfScalar(u8, json, '\\') == null);
    try testing.expect(std.mem.startsWith(u8, json, "{"));
    try testing.expect(std.mem.endsWith(u8, json, "}"));
}

test "the detail does not invent the accelerometer and gyroscope keys the docs read" {
    // The rule-4 regression test. `test-bridges.html:398-400`, `README.md` and
    // `craft.d.ts`'s `CraftMotionUpdateEvent` all read
    // `e.detail.accelerometer` / `e.detail.gyroscope`, and no platform has ever
    // emitted either. Matching the stale docs would be a rename Swift never
    // performed — and `gyroscope` would be an outright lie, because `rotation`
    // carries `CMAttitude` in radians, not `CMDeviceMotion.rotationRate`.
    //
    // The docs are the bug. They are reported separately, not fixed by
    // corrupting the emitter.
    const json = try shapeDetail(testing.allocator, sample_reading);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "accelerometer") == null);
    try testing.expect(std.mem.indexOf(u8, json, "gyroscope") == null);
    try testing.expect(std.mem.indexOf(u8, json, "rotationRate") == null);
    // And the three keys that must be there, spelled as objects.
    try testing.expect(std.mem.indexOf(u8, json, "\"acceleration\":{") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"rotation\":{") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"gravity\":{") != null);
}

test "extreme doubles are rendered in full instead of overflowing the buffer" {
    // The `[64]u8` trap. `{d}` renders decimal notation, never scientific: a
    // finite f64 can need up to `bufferSize(.decimal, f64)` = 347 bytes, and
    // the real worst case is the smallest subnormal at 326 characters. A
    // smaller buffer turns a legal reading into `NoSpaceLeft` — an event that
    // silently stops arriving, on a device, with nothing to point at.
    //
    // CoreMotion will not produce these; the point is that the buffer is sized
    // by the type's range rather than by what a sensor is expected to do.
    const extreme = MotionSample{
        .acceleration = .{ .x = std.math.floatMax(f64), .y = -std.math.floatMax(f64), .z = 1e300 },
        .rotation = .{ .alpha = std.math.floatMin(f64), .beta = -1e-300, .gamma = 5e-324 },
        .gravity = .{ .x = -0.0, .y = 1e-308, .z = -1e308 },
    };

    const json = try shapeDetail(testing.allocator, extreme);
    defer testing.allocator.free(json);

    // Long enough that a 64-byte-per-number implementation could not have
    // produced it, and still valid JSON.
    try testing.expect(json.len > 1500);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.object.count());

    // The values survive the round trip rather than being truncated into a
    // different reading.
    const accel = parsed.value.object.get("acceleration").?.object;
    try testing.expectEqual(std.math.floatMax(f64), try numberOf(accel.get("x").?));
    try testing.expectEqual(-std.math.floatMax(f64), try numberOf(accel.get("y").?));
    try testing.expectEqual(@as(f64, 1e300), try numberOf(accel.get("z").?));
    const rot = parsed.value.object.get("rotation").?.object;
    try testing.expectEqual(std.math.floatMin(f64), try numberOf(rot.get("alpha").?));
    try testing.expectEqual(@as(f64, 5e-324), try numberOf(rot.get("gamma").?));
    const grav = parsed.value.object.get("gravity").?.object;
    try testing.expectEqual(@as(f64, -1e308), try numberOf(grav.get("z").?));
}

test "the float buffer is sized from the formatter, not from a guess" {
    // The number the buffer must be, stated independently of the code that
    // uses it, so shrinking it is a test failure rather than a device bug.
    try testing.expectEqual(@as(usize, 347), std.fmt.float.bufferSize(.decimal, f64));
}

test "an ordinary reading stays short, so the buffer is a ceiling and not a cost" {
    // Sanity in the other direction: sizing for the worst case must not pad
    // every sample. At 100 Hz this string is built a hundred times a second.
    const json = try shapeDetail(testing.allocator, sample_reading);
    defer testing.allocator.free(json);
    try testing.expect(json.len < 140);
}

test "a non-finite reading is refused, because it would break the whole event" {
    // `ios_events.formatEvent` inlines the detail as a raw JSON literal, so a
    // `nan` or an `inf` does not produce a bad number — it produces a
    // `dispatchEvent(…)` call the page cannot parse, and the event is lost
    // rather than degraded. Refusing lets the handler drop one sample instead.
    const E = bridge_error.BridgeError;

    var nan_sample = sample_reading;
    nan_sample.rotation.beta = std.math.nan(f64);
    try testing.expectError(E.InvalidParameter, shapeDetail(testing.allocator, nan_sample));

    var inf_sample = sample_reading;
    inf_sample.acceleration.z = std.math.inf(f64);
    try testing.expectError(E.InvalidParameter, shapeDetail(testing.allocator, inf_sample));

    // Including in the last field written, so a check that only guarded the
    // first vector would not pass.
    var tail_sample = sample_reading;
    tail_sample.gravity.z = -std.math.inf(f64);
    try testing.expectError(E.InvalidParameter, shapeDetail(testing.allocator, tail_sample));
}

test "zero and negative zero are JSON numbers, not omitted fields" {
    // A device lying flat reports zeros on two axes. `{d}` renders them `0` and
    // `-0`, both of which are legal JSON numbers that parse back to zero — the
    // failure mode worth ruling out is a shaper that skips a zero field.
    const flat = MotionSample{
        .acceleration = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
        .rotation = .{ .alpha = 0.0, .beta = -0.0, .gamma = 0.0 },
        .gravity = .{ .x = 0.0, .y = 0.0, .z = -1.0 },
    };

    const json = try shapeDetail(testing.allocator, flat);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"acceleration\":{\"x\":0,\"y\":0,\"z\":0}," ++
            "\"rotation\":{\"alpha\":0,\"beta\":-0,\"gamma\":0}," ++
            "\"gravity\":{\"x\":0,\"y\":0,\"z\":-1}}",
        json,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.object.get("rotation").?.object.count());
}
