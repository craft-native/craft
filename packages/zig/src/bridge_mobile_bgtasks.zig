//! The background-task actions of the `mobile` namespace:
//! `scheduleBackgroundTask`, `cancelBackgroundTask`, `cancelAllBackgroundTasks`.
//!
//! One JS surface reaches these: `craft.backgroundTask`, whose four methods
//! post `{action, taskId, …, callbackId}`. None of them goes through
//! `craft._invoke`, so none of them has the 30s timeout — each is a raw `new
//! Promise` stored into `_callbacks`. A dropped message parks the page
//! forever, which is why every path here ends in a reply or an explicit error.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **The identifier field is `taskId`** — that is what the injected JS
//!    posts and what the shim reads (`body["taskId"]`). The `callbackId` in
//!    the same payload is correlation plumbing the `{t,a,d,i}` envelope
//!    replaces; it is ignored, not consumed.
//!  - **The replies are objects, not bare fragments.** Swift resolves
//!    `["taskId": fullTaskId, "scheduled": true]` and
//!    `["taskId": fullTaskId, "cancelled": true]`, and — for cancel-all, the
//!    one reply of the three that differs in shape — `["cancelled": true]`
//!    with **no `taskId` key**. `test-bridges.html` prints
//!    `JSON.stringify(result)` for all three, so every key is observable.
//!    (`craft.d.ts` under-declares these as `{ scheduled: boolean }` and
//!    friends; the runtime objects are the wider ones, and the wider ones are
//!    what ship.)
//!  - **The `fullTaskId` prefix is contract.** All three id-carrying paths
//!    build `"<bundle identifier>.<taskId>"` and the *prefixed* id is what the
//!    reply names. A page that scheduled `craft-sync` gets back
//!    `com.acme.app.craft-sync`, and cancelling needs the same prefix applied
//!    to the same short name — so the join is a pure function pinned by a test
//!    rather than a format string written out three times.
//!  - **Cancelling an unknown identifier is a no-op that still resolves.**
//!    `cancelTaskRequestWithIdentifier:` ignores what it does not have, and so
//!    does Swift. Idempotent, like the notification cancels next door.
//!  - **An empty `taskId` passes through**, as it does in Swift: the shim
//!    hands `"<bundleid>."` to the scheduler and resolves. Bug-compatibility
//!    with the shim is the contract while the shim still exists.
//!
//! ## Deliberate divergences, each with its reason
//!
//! **`registerBackgroundTask` is not served here at all.** It is absent from
//! the `A` block, so `handleMessage` answers `UnknownAction` and
//! `ios_dispatch` falls the action through to the Swift shim, which is the
//! only thing that answers it at all today. Every option here is bad; this is
//! the reasoning for the one that was picked:
//!
//!   1. `BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:)`
//!      must be called **before the app finishes launching**. A page-triggered
//!      call is by definition after `didFinishLaunchingWithOptions:` returned,
//!      and registering late raises `NSInternalInconsistencyException`, which
//!      as an uncaught Objective-C exception is an uncatchable SIGABRT — not
//!      an error Zig could map and report.
//!   2. The launch handler fires minutes-to-hours later in a **new process
//!      launch**, where `ios_dispatch.global_webview` is null and
//!      `sendResultToJS` reaches `error.NoWebView`. Delivering it to a page
//!      needs an event channel iOS craft does not have.
//!   3. `ios_async` cannot help: its ticket pool is one-shot request-to-reply
//!      and its global blocks fire once inside the same process. A launch
//!      handler has to survive process death.
//!   4. `.status = .unavailable` dispatches and refuses, and Zig cannot do the
//!      work either way, so the choice is only about which wrong answer the
//!      page gets. Omission was chosen so that a config which *does* enable
//!      background tasks keeps behaving exactly as it does today, and because
//!      an action Zig never claims stays counted as not-yet-migrated by the
//!      conformance ratchet — `.unavailable` would let it read as handled.
//!
//! Be clear about what omission leaves standing, because neither branch of the
//! shim is correct and this is the weak half of the trade:
//!
//!   - With `config.enableBackgroundTasks` at its **default `false`**, the
//!     shim's `case "registerBackgroundTask":` arm has no `else`, so nothing
//!     replies at all and the untimed promise **hangs forever**. Falling
//!     through preserves that hang; `.unavailable` would at least reject.
//!   - With the gate on, the shim resolves `["taskId": …, "registered": true]`
//!     without ever calling `BGTaskScheduler.register` — it inserts into a
//!     `Set` that is read nowhere (`CraftApp.swift`, `registeredBackgroundTasks`,
//!     written once at one site and never read). So the resolve is a
//!     fabrication: no launch handler exists and none ever fires.
//!
//! Both are `CraftApp.swift` bugs, and the fix is Swift-side — an `else` arm
//! that rejects with `CAPABILITY_DISABLED`, and either a real registration at
//! launch or an honest rejection. If that fix does not land, reconsider this
//! omission: a `.unavailable` refusal beats a promise that never settles.
//!
//! **`requiresNetwork` and `requiresCharging` are honoured, not dropped.** The
//! shim takes both parameters and then never references them: it always builds
//! a `BGAppRefreshTaskRequest`, which has no such properties. A page that asks
//! for `requiresCharging: true` is told its constraint was accepted. Rule 2
//! says a field the page sent is never dropped, so this module builds a
//! `BGProcessingTaskRequest` — which does have `requiresNetworkConnectivity`
//! and `requiresExternalPower` — whenever either flag is true, and the plain
//! `BGAppRefreshTaskRequest` when both are false. Three things make this the
//! safe divergence rather than a risky one: craft's generated Info.plist
//! declares `UIBackgroundModes` = `processing` and *not* `fetch`, so
//! processing is the type a craft app is actually configured for; nothing
//! works on device today anyway (below); and the alternative that preserves
//! the shim's behaviour exactly is the one that lies to the caller.
//!
//! **Malformed input errors rather than hanging or silently defaulting.** The
//! shim's `body["taskId"] as? String` failing replies nothing at all, and its
//! `as? Double ?? 900` turns `delay: "soon"` into fifteen minutes the page
//! never asked for. A *missing* field takes Swift's documented default (900 /
//! false / false, the same defaults the injected JS already applies before
//! posting); a field that is **present with the wrong type** is refused, never
//! coerced.
//!
//! **The `config.enableBackgroundTasks` gate has no Zig mirror.** It appears
//! nowhere in `packages/zig/src`, so the three actions here are served
//! unconditionally — the securestore and notifcancel modules document the same
//! choice. In an app that left the gate at its default `false` this changes a
//! hang into an answer: `schedule` now reaches the scheduler and reports
//! whatever it says (a rejection, until the plist gains
//! `BGTaskSchedulerPermittedIdentifiers`), and the cancels report the no-op
//! they perform. Nothing is granted that the page could not already reach with
//! the gate on, and the actions only ever touch this app's own queue.
//!
//! ## Guards, in the order they fire
//!
//! Parsing and validation run first and touch no Objective-C, so a payload
//! this module must refuse is refused identically on Linux, on a host, and on
//! a device — which is what makes the pure tests below binding for the device
//! build.
//!
//! Then the **bundle-identifier guard**, before anything reaches
//! `BGTaskScheduler`. Unlike `[UNUserNotificationCenter
//! currentNotificationCenter]`, which is verified to raise
//! `NSInternalInconsistencyException` in a bundle-less process,
//! `+[BGTaskScheduler sharedScheduler]` has been measured there and is *safe*:
//! it hands back a scheduler, and a subsequent `submitTaskRequest:error:`
//! answers `NO` with `BGTaskSchedulerErrorDomain` code 3 and a userInfo of
//! `Unrecognized Identifier`. So this guard is **not** a SIGABRT guard — do
//! not copy that reasoning from the notifcancel sibling. It exists for the
//! reason below, and it costs nothing because the identifier is needed for the
//! reply's prefix regardless.
//!
//! It also costs one deliberate divergence: Swift falls back to the literal
//! `"com.craft.app"` when `Bundle.main.bundleIdentifier` is nil and carries on.
//! This module refuses with `NoBundleIdentifier` instead. A process with no
//! bundle identifier has no app identity, so `"com.craft.app.<taskId>"` names a
//! task belonging to an app that is not running: `submit` under it is refused
//! by the scheduler anyway (measured: code 3), and a `cancel` under it would
//! resolve `cancelled: true` having addressed an identifier the caller does not
//! own — fabricated success, which rule 1 outranks bug-compatibility.
//! `default_bundle_prefix` below keeps the shim's spelling recorded, and a test
//! pins that the join produces byte-identical output given that prefix, so if
//! the refusal is ever traded back for parity the string is already right. In a
//! shipped `.app` the fallback is unreachable anyway: `CFBundleIdentifier` is
//! always present.
//!
//! Finally `objc_getClass("BGTaskScheduler")`, which returns **null in the
//! host test binaries** — `build.zig` links Cocoa, WebKit, CoreFoundation,
//! CoreGraphics, CoreMIDI and Security into the iOS test artifacts and never
//! BackgroundTasks. In the shipped app the class is present only because
//! `CraftApp.swift` does `import BackgroundTasks` and Xcode auto-links it;
//! frameworks are linked at the app level in Xcode, not in this static
//! library, so deleting that import post-migration would silently null the
//! class and every action here would start answering `ClassNotFound`.
//!
//! ## What cannot work on device yet, in any language
//!
//! `BGTaskSchedulerPermittedIdentifiers` appears nowhere in the repo, and
//! `renderBackgroundModes` emits only `UIBackgroundModes`. Without the
//! identifier in the plist, `submitTaskRequest:error:` returns `NO` with
//! `BGTaskSchedulerErrorDomain` code 3 (`NotPermitted`). That is a real,
//! reported failure and not a fabrication, so this module serves the action
//! and logs the NSError domain and code — but the plist generator needs a
//! separate fix before `scheduleBackgroundTask` can succeed on hardware. On
//! the simulator a submitted task additionally never launches on its own; it
//! needs the `_simulateLaunchForTaskWithIdentifier:` debugger poke.
//!
//! ## Why `ios_async` is not imported
//!
//! Nothing here is asynchronous. `submitTaskRequest:error:` is a synchronous
//! BOOL with an NSError out-param — no completion handler — and both cancels
//! are synchronous voids. Acquiring a ticket for a reply that is already on
//! the dispatch frame's stack would add a pool slot, a main-queue hop, and a
//! pool-exhaustion failure mode to buy nothing.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;

/// The same type as `objc.id` — `?*anyopaque` — spelled locally, per the
/// notifcancel and securestore precedent: `objc_runtime.objc` is an empty
/// struct off Darwin and signatures are analysed even where a comptime guard
/// prunes the body, so naming `objc.id` here would break the Linux build. A
/// single optional pointer, never `?objc.id` — a double optional is illegal in
/// `callconv(.c)`.
const Id = ?*anyopaque;

/// Likewise for `objc.SEL`, needed in the hand-rolled `objc_msgSend` casts
/// below: `objc_runtime.zig` has no sender for `BOOL (id, SEL, id, NSError **)`
/// nor for a zero-argument `NSInteger`.
const Sel = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches the two lists by string in both
/// directions.
///
/// registerBackgroundTask is absent on purpose — see the module header. The
/// conformance ratchet only counts down, so an omitted action stays counted as
/// not-yet-migrated, which is exactly the honest accounting for it.
pub const A = struct {
    pub const schedule_background_task = "scheduleBackgroundTask";
    pub const cancel_background_task = "cancelBackgroundTask";
    pub const cancel_all_background_tasks = "cancelAllBackgroundTasks";
};

/// All three `.result`: each Swift path resolves a callback, and all three JS
/// promises are the untimed legacy kind — `.none` here would strand a caller
/// forever, not for thirty seconds.
///
/// All three `.live`. Submitting and cancelling need no permission prompt and
/// no completion handler; the plist gap that makes `submit` fail on device is
/// a reported failure, not an action that cannot be reached, so it is not
/// `.unavailable`.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.schedule_background_task, .reply = .result },
    .{ .name = A.cancel_background_task, .reply = .result },
    .{ .name = A.cancel_all_background_tasks, .reply = .result },
};

/// Swift's default when `Bundle.main.bundleIdentifier` is nil. Recorded rather
/// than used: this module refuses in that process instead (module header). A
/// test pins that `joinIdentifier` given this prefix produces byte-identical
/// output to the shim, so the parity trade stays one line away.
const default_bundle_prefix = "com.craft.app";

/// Swift's `body["delay"] as? Double ?? 900`, and the injected JS's
/// `options.delay || 900` — fifteen minutes, applied only when the field is
/// *absent*.
const default_delay_seconds: f64 = 900;

/// The boolean key each reply object carries beside `taskId`. Named so the
/// reply builder cannot be handed a typo and so the cancel-all fragment can be
/// checked against the same spelling.
const scheduled_key = "scheduled";
const cancelled_key = "cancelled";

/// The one reply with no `taskId` key: Swift's
/// `resolveCallback(callbackId, result: ["cancelled": true])`. Static, so
/// cancel-all allocates nothing.
const cancel_all_fragment = "{\"cancelled\":true}";

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host. The split is
/// load-bearing for `cancelAllBackgroundTasks`: it has no payload and
/// therefore no validation step, so a test that *called* it to prove routing
/// would — in a process that does have a bundle identifier — cancel whatever
/// background work the hosting app had pending.
const Route = enum { schedule, cancel_one, cancel_all };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.schedule_background_task)) return .schedule;
    if (std.mem.eql(u8, action, A.cancel_background_task)) return .cancel_one;
    if (std.mem.eql(u8, action, A.cancel_all_background_tasks)) return .cancel_all;
    return null;
}

pub const BgTasksBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const route = routeFor(action) orelse return BridgeError.UnknownAction;
        // Exhaustive, so a `Route` without a handler is a compile error.
        return switch (route) {
            .schedule => self.scheduleBackgroundTask(data),
            .cancel_one => self.cancelBackgroundTask(data),
            .cancel_all => self.cancelAllBackgroundTasks(),
        };
    }

    /// Submit one background-task request. Resolves the object
    /// `{"taskId":"<prefixed>","scheduled":true}`.
    ///
    /// Validation runs before any Objective-C, then the bundle guard, then the
    /// scheduler — so the only way to reach `submitTaskRequest:error:` is with
    /// a payload that was fully understood and a process that is a real app.
    fn scheduleBackgroundTask(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const request = try parseScheduleRequest(parsed.value);

        const prefix = try requireBundlePrefix();
        const full_task_id = try joinIdentifier(self.allocator, prefix, request.task_id);
        defer self.allocator.free(full_task_id);

        const sched = try scheduler();
        try submitRequest(self.allocator, sched, full_task_id, request);

        const reply = try taskReply(self.allocator, full_task_id, scheduled_key);
        defer self.allocator.free(reply);
        bridge_error.sendResultToJS(self.allocator, A.schedule_background_task, reply);
    }

    /// Cancel one pending request by identifier. Resolves
    /// `{"taskId":"<prefixed>","cancelled":true}` whether or not anything
    /// matched — `cancelTaskRequestWithIdentifier:` ignores what it does not
    /// have, and so does Swift.
    fn cancelBackgroundTask(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const task_id = try parseTaskId(parsed.value);

        const prefix = try requireBundlePrefix();
        const full_task_id = try joinIdentifier(self.allocator, prefix, task_id);
        defer self.allocator.free(full_task_id);

        const sched = try scheduler();
        try cancelIdentifier(self.allocator, sched, full_task_id);

        const reply = try taskReply(self.allocator, full_task_id, cancelled_key);
        defer self.allocator.free(reply);
        bridge_error.sendResultToJS(self.allocator, A.cancel_background_task, reply);
    }

    /// Cancel every pending request. The payload is ignored, as Swift ignores
    /// the body: the injected JS posts the action alone and
    /// `ios_dispatch.payloadOf` hands this `"{}"` for an absent `d`. An
    /// already-empty queue still resolves — idempotent, as in Swift.
    ///
    /// The bundle guard still runs even though no identifier is built from it:
    /// this touches the scheduler, and the guard is about what is safe to
    /// touch, not about what the reply says.
    fn cancelAllBackgroundTasks(self: *Self) !void {
        _ = try requireBundlePrefix();

        const sched = try scheduler();
        try cancelAll(sched);

        bridge_error.sendResultToJS(self.allocator, A.cancel_all_background_tasks, cancel_all_fragment);
    }
};

// =============================================================================
// Payload parsing — pure, so every outcome the shim collapsed into a hang or a
// silent default is pinned by a host test.
// =============================================================================

/// Everything `scheduleBackgroundTask` needs, with the shim's defaults already
/// applied for absent fields. Slices borrow from the parsed payload and are
/// copied before it is freed.
const ScheduleRequest = struct {
    task_id: []const u8,
    delay: f64,
    requires_network: bool,
    requires_charging: bool,
};

/// Which `BGTaskRequest` subclass a set of constraints needs.
const RequestKind = enum { app_refresh, processing };

/// The divergence from the shim, isolated into one pure function so it is
/// pinned by a test rather than buried in an ObjC call sequence.
///
/// `BGAppRefreshTaskRequest` has no constraint properties at all — the shim
/// accepts both flags and then always builds one, so both are silently
/// dropped. `BGProcessingTaskRequest` is the subclass that carries
/// `requiresNetworkConnectivity` and `requiresExternalPower`, and `processing`
/// is also the only `UIBackgroundModes` value craft's Info.plist generator
/// emits. So: any constraint at all means processing; no constraints keeps the
/// shim's app-refresh request, which is the cheaper of the two to be granted.
fn requestKindFor(requires_network: bool, requires_charging: bool) RequestKind {
    return if (requires_network or requires_charging) .processing else .app_refresh;
}

/// Parse `d`, distinguishing a bad payload from a failed allocation — telling
/// the page INVALID_JSON about its own good JSON sends whoever debugs it to
/// the wrong side of the bridge.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return BridgeError.InvalidJSON,
    };
}

/// The `taskId` field, or the reason it cannot be used.
///
/// The name is pinned on both sides of the migration: the injected JS posts
/// `taskId` and the shim reads `body["taskId"]`. An empty string is *not*
/// refused — Swift builds `"<bundleid>."` from it and resolves, and
/// interchangeability with the shim is the contract while the shim exists.
fn parseTaskId(payload: std.json.Value) ![]const u8 {
    const object = switch (payload) {
        .object => |o| o,
        else => return BridgeError.InvalidJSON,
    };
    const field = object.get("taskId") orelse return BridgeError.MissingData;
    const task_id = switch (field) {
        .string => |s| s,
        // Swift's `as? String` fails here and replies nothing at all. A
        // coercion would be worse: it would schedule or cancel a stringified
        // something the page never named and report success for it.
        else => return BridgeError.InvalidParameter,
    };
    try requireNulFree(task_id);
    return task_id;
}

/// The full `scheduleBackgroundTask` payload. `parseTaskId` has already proved
/// the value is an object by the time the other three fields are read.
fn parseScheduleRequest(payload: std.json.Value) !ScheduleRequest {
    const task_id = try parseTaskId(payload);
    const object = payload.object;

    return .{
        .task_id = task_id,
        .delay = try parseDelay(object),
        .requires_network = try parseFlag(object, "requiresNetwork"),
        .requires_charging = try parseFlag(object, "requiresCharging"),
    };
}

/// `delay`, in seconds, as an `NSTimeInterval`.
///
/// Accepts `.integer` and `.float` because a JSON number arrives as either and
/// Swift's `as? Double` takes both — the injected JS sends `options.delay ||
/// 900`, which is an integer for every caller that does not pass a fraction.
///
/// `.number_string` is what `std.json` produces for a literal that overflows
/// `i64` or parses to a non-finite float (`1e400`). Swift would hand the
/// latter to `Date(timeIntervalSinceNow:)` as an infinity; there is no such
/// instant, so it is refused rather than turned into an arbitrary date.
///
/// A negative delay is accepted, as in Swift: `earliestBeginDate` in the past
/// means eligible immediately, which is a coherent request.
fn parseDelay(object: std.json.ObjectMap) !f64 {
    const field = object.get("delay") orelse return default_delay_seconds;
    const seconds: f64 = switch (field) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return BridgeError.InvalidParameter,
        // Present and not a number. Swift's `?? 900` would silently schedule
        // fifteen minutes the page never asked for.
        else => return BridgeError.InvalidParameter,
    };
    if (!std.math.isFinite(seconds)) return BridgeError.InvalidParameter;
    return seconds;
}

/// `requiresNetwork` / `requiresCharging`. Absent is `false`, matching both
/// Swift's `?? false` and the injected JS's `options.x || false`; present and
/// not a boolean is refused rather than defaulted, because a page that sent
/// something for a constraint field is asking for a constraint.
fn parseFlag(object: std.json.ObjectMap, name: []const u8) !bool {
    const field = object.get(name) orelse return false;
    return switch (field) {
        .bool => |b| b,
        else => BridgeError.InvalidParameter,
    };
}

/// Refuse a `taskId` carrying the one byte it cannot survive. A NUL is
/// reachable from a page as the legal JSON escape `\u0000`, which `std.json`
/// decodes to the byte; `createNSString` (`stringWithUTF8String:`) would then
/// truncate, and the request submitted or cancelled would carry a *different*
/// identifier than the reply names.
fn requireNulFree(s: []const u8) !void {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return BridgeError.InvalidParameter;
}

// =============================================================================
// Identifier and reply shaping — pure, and the observable contract.
// =============================================================================

/// `"<prefix>.<taskId>"`, Swift's
/// `"\(Bundle.main.bundleIdentifier ?? "com.craft.app").\(taskId)"`.
///
/// Pure and allocating, rather than a format string written out at all three
/// call sites: this string is both what the scheduler is addressed with and
/// what the reply names, and those two must not be able to drift.
fn joinIdentifier(allocator: std.mem.Allocator, prefix: []const u8, task_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, task_id });
}

/// `{"taskId":"<escaped>","<flag>":true}` — the object shape both id-carrying
/// replies use.
///
/// The identifier is escaped with `appendJsonEscaped` because it embeds a
/// page-controlled `taskId` and the whole reply is replayed into
/// `evaluateJavaScript:` as source: a quote or backslash in a task name would
/// otherwise break the page's promise resolution. Key order is not contract —
/// Swift serialises an unordered `NSDictionary` without `.sortedKeys`.
fn taskReply(allocator: std.mem.Allocator, full_task_id: []const u8, flag_key: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"taskId\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, full_task_id);
    try out.appendSlice(allocator, "\",\"");
    try out.appendSlice(allocator, flag_key);
    try out.appendSlice(allocator, "\":true}");

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Objective-C. Every function here opens with the Darwin guard, which prunes
// the rest of its body off Darwin — `objc` is an empty struct there.
// =============================================================================

/// The process's bundle identifier, or null when it has none.
///
/// The returned slice points into the autoreleased NSString's UTF-8 buffer and
/// is valid for the current autorelease-pool turn — the run-loop turn the
/// `WKScriptMessageHandler` callback runs inside. Every caller copies it into
/// an owned identifier before anything else happens.
fn bundleIdentifier() !?[]const u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSBundle = objc.objc_getClass("NSBundle") orelse return error.ClassNotFound;
    const sel_main = objc.sel_registerName("mainBundle") orelse return error.SelectorNotFound;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return null;

    const sel_ident = objc.sel_registerName("bundleIdentifier") orelse return error.SelectorNotFound;
    const ns_ident = objc.msgSendId(bundle, sel_ident) orelse return null;

    const utf8 = objc.getNSStringUTF8(ns_ident) orelse return null;
    return std.mem.span(utf8);
}

/// The bundle identifier, or a refusal to address `BGTaskScheduler` without
/// one.
///
/// Not a crash guard: `+[BGTaskScheduler sharedScheduler]` has been measured in
/// a bundle-less process and returns normally (module header). The refusal is
/// about identity — see the header for why the shim's `?? "com.craft.app"`
/// fallback would let a cancel resolve `cancelled: true` for an identifier the
/// caller does not own.
fn requireBundlePrefix() ![]const u8 {
    return (try bundleIdentifier()) orelse {
        std.log.warn(
            "background tasks: this process has no bundle identifier; " ++
                "refusing rather than addressing BGTaskScheduler as '{s}'",
            .{default_bundle_prefix},
        );
        return error.NoBundleIdentifier;
    };
}

/// `+[BGTaskScheduler sharedScheduler]`, guarded. A null class means
/// BackgroundTasks.framework is not in the process — the normal answer in the
/// host test binaries, and a link-configuration problem in an app — named
/// rather than crashed on.
fn scheduler() !Id {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const BGTaskScheduler = objc.objc_getClass("BGTaskScheduler") orelse return error.ClassNotFound;
    const sel_shared = objc.sel_registerName("sharedScheduler") orelse return error.SelectorNotFound;
    return objc.msgSendId(BGTaskScheduler, sel_shared) orelse error.NativeCallFailed;
}

/// Build the request, apply the constraints, and submit it.
///
/// `submitTaskRequest:error:` is a synchronous `BOOL` with an `NSError **`
/// out-param — no completion handler, so nothing here is asynchronous. The
/// error object is read for the log only: `sendErrorToJS` carries an enum and
/// not text, so Swift's `error.localizedDescription` cannot be reproduced
/// verbatim, and the specifics survive in the device log instead — the
/// `bridge_mobile_misc` precedent.
fn submitRequest(
    allocator: std.mem.Allocator,
    sched: Id,
    full_task_id: []const u8,
    spec: ScheduleRequest,
) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const kind = requestKindFor(spec.requires_network, spec.requires_charging);
    const class_name: [:0]const u8 = switch (kind) {
        .app_refresh => "BGAppRefreshTaskRequest",
        .processing => "BGProcessingTaskRequest",
    };
    const RequestClass = objc.objc_getClass(class_name) orelse return error.ClassNotFound;

    // `createNSString` can fail (allocation, missing class) *and* can hand
    // back nil — `stringWithUTF8String:` returns nil for bytes it rejects.
    // `std.json` already validated UTF-8 and the NUL check ran, so a nil here
    // should not fire; unchecked it would be an uncatchable ObjC exception
    // inside `initWithIdentifier:`.
    const ns_identifier = (try objc.createNSString(full_task_id, allocator)) orelse
        return error.StringCreationFailed;

    const sel_init = objc.sel_registerName("initWithIdentifier:") orelse return error.SelectorNotFound;
    const raw = (try objc.alloc(RequestClass)) orelse return error.NativeCallFailed;
    // Owned: `alloc` + `init`, so it is released below. A nil from a failed
    // `init` has already released `raw` by ObjC convention, so there is
    // nothing to release on that path.
    const request = objc.msgSendId1(raw, sel_init, ns_identifier) orelse return error.NativeCallFailed;
    defer objc.release(request);

    // `+[NSDate dateWithTimeIntervalSinceNow:]` takes an `NSTimeInterval`,
    // i.e. a `double`. Passed as an `f64` so the msgSend cast puts it in a
    // float register; laundering it through an integer would land it in the
    // wrong register file and schedule a garbage date.
    const NSDate = objc.objc_getClass("NSDate") orelse return error.ClassNotFound;
    const sel_since_now = objc.sel_registerName("dateWithTimeIntervalSinceNow:") orelse
        return error.SelectorNotFound;
    const begin_date = objc.msgSendId1(NSDate, sel_since_now, spec.delay) orelse
        return error.NativeCallFailed;

    const sel_set_begin = objc.sel_registerName("setEarliestBeginDate:") orelse return error.SelectorNotFound;
    objc.msgSendVoid1(request, sel_set_begin, begin_date);

    if (kind == .processing) {
        // Only `BGProcessingTaskRequest` responds to these, and by
        // construction of `requestKindFor` the app-refresh branch is never
        // reached with a constraint set. `bool` is the right Zig type for
        // `BOOL`: on 64-bit Apple platforms `__OBJC_BOOL_IS_BOOL` is defined,
        // so `BOOL` is C99 `_Bool` (see `ios.zig`).
        const sel_network = objc.sel_registerName("setRequiresNetworkConnectivity:") orelse
            return error.SelectorNotFound;
        objc.msgSendVoid1(request, sel_network, spec.requires_network);

        const sel_power = objc.sel_registerName("setRequiresExternalPower:") orelse
            return error.SelectorNotFound;
        objc.msgSendVoid1(request, sel_power, spec.requires_charging);
    }

    const sel_submit = objc.sel_registerName("submitTaskRequest:error:") orelse return error.SelectorNotFound;
    const SubmitFn = *const fn (Id, Sel, Id, ?*Id) callconv(.c) bool;
    const submit: SubmitFn = @ptrCast(&objc.objc_msgSend);

    var ns_error: Id = null;
    if (submit(sched, sel_submit, request, &ns_error)) return;

    logSubmitFailure(full_task_id, kind, ns_error);
    return BridgeError.NativeCallFailed;
}

/// `-[BGTaskScheduler cancelTaskRequestWithIdentifier:]` — synchronous, void,
/// and a no-op for an identifier that is not pending.
fn cancelIdentifier(allocator: std.mem.Allocator, sched: Id, full_task_id: []const u8) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const ns_identifier = (try objc.createNSString(full_task_id, allocator)) orelse
        return error.StringCreationFailed;

    const sel_cancel = objc.sel_registerName("cancelTaskRequestWithIdentifier:") orelse
        return error.SelectorNotFound;
    objc.msgSendVoid1(sched, sel_cancel, ns_identifier);
}

/// `-[BGTaskScheduler cancelAllTaskRequests]` — void, zero arguments.
fn cancelAll(sched: Id) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel_cancel_all = objc.sel_registerName("cancelAllTaskRequests") orelse return error.SelectorNotFound;
    objc.msgSend(sched, sel_cancel_all);
}

/// The one thing an enum-shaped error reply cannot carry: which
/// `BGTaskSchedulerErrorCode` came back.
///
/// Worth spelling the codes out here, because code 3 is what every craft app
/// gets today — the generated Info.plist has no
/// `BGTaskSchedulerPermittedIdentifiers`, so no identifier is permitted and
/// every submit is refused.
fn logSubmitFailure(full_task_id: []const u8, kind: RequestKind, ns_error: Id) void {
    if (!builtin.target.os.tag.isDarwin()) return;

    if (ns_error == null) {
        std.log.warn(
            "background task '{s}' ({s}) was refused by BGTaskScheduler with no NSError",
            .{ full_task_id, @tagName(kind) },
        );
        return;
    }

    const domain = nsStringText(sendId(ns_error, "domain")) orelse "<unknown domain>";
    const description = nsStringText(sendId(ns_error, "localizedDescription")) orelse "<no description>";
    const code = nsInteger(ns_error, "code") orelse 0;

    std.log.warn(
        "background task '{s}' ({s}) submit failed: {s} {d} - {s}. " ++
            "BGTaskSchedulerErrorDomain: 1=Unavailable, 2=TooManyPendingTaskRequests, " ++
            "3=NotPermitted (identifier missing from BGTaskSchedulerPermittedIdentifiers)",
        .{ full_task_id, @tagName(kind), domain, code, description },
    );
}

/// `objc_msgSend` returning `id`, with the selector looked up by name and a
/// null selector treated as a null result — log-path only, so a missing
/// selector must not turn into an error that replaces the real one.
fn sendId(target: Id, name: [:0]const u8) Id {
    if (!builtin.target.os.tag.isDarwin()) return null;
    const sel = objc.sel_registerName(name) orelse return null;
    return objc.msgSendId(target, sel);
}

/// A zero-argument `NSInteger` getter. `objc_runtime.zig` has no sender for
/// this shape, hence the local type.
fn nsInteger(target: Id, name: [:0]const u8) ?c_long {
    if (!builtin.target.os.tag.isDarwin()) return null;
    const sel = objc.sel_registerName(name) orelse return null;
    const Fn = *const fn (Id, Sel) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(target, sel);
}

/// An NSString's UTF-8 bytes as a Zig slice, valid for the current
/// autorelease-pool turn. Used only to format a log line, which happens
/// immediately.
fn nsStringText(ns_string: Id) ?[]const u8 {
    if (!builtin.target.os.tag.isDarwin()) return null;
    if (ns_string == null) return null;
    const utf8 = objc.getNSStringUTF8(ns_string) orelse return null;
    return std.mem.span(utf8);
}

// =============================================================================
// Tests — host-only. Everything that decides what the page sees (routing,
// field names, defaults, refusal reasons, the identifier prefix, the reply
// objects) is pinned as pure logic, and the one Objective-C path a host can
// reach — the bundle-identifier refusal — is exercised for real, because the
// test runner is exactly the bundle-less process the guard exists for. The
// scheduler calls themselves are never made from here: in a process that *did*
// have a bundle identifier they would cancel that app's real pending work.
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 3), capability_actions.len);
    try testing.expectEqualStrings(A.schedule_background_task, capability_actions[0].name);
    try testing.expectEqualStrings(A.cancel_background_task, capability_actions[1].name);
    try testing.expectEqualStrings(A.cancel_all_background_tasks, capability_actions[2].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        try testing.expectEqual(@as(?[]const u8, null), decl.reason);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("scheduleBackgroundTask", A.schedule_background_task);
    try testing.expectEqualStrings("cancelBackgroundTask", A.cancel_background_task);
    try testing.expectEqualStrings("cancelAllBackgroundTasks", A.cancel_all_background_tasks);
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
    // action the page can call and the manifest denies exists. Each
    // declaration must claim a *distinct* route — counting alone would let two
    // rows share one route while another went undeclared.
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

test "registerBackgroundTask is deliberately not claimed, so it reaches the shim" {
    // The load-bearing omission. `ios_dispatch` routes to the first module that
    // does not answer `UnknownAction`; answering it here is what lets the
    // action fall through to the Swift shim that resolves it today. If this
    // ever starts routing, `craft.backgroundTask.register()` changes behaviour
    // — see the module header for why Zig cannot serve it honestly.
    var bridge = BgTasksBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("registerBackgroundTask", "{\"taskId\":\"craft-sync\"}"),
    );
    try testing.expect(routeFor("registerBackgroundTask") == null);

    for (capability_actions) |decl| {
        try testing.expect(!std.mem.eql(u8, decl.name, "registerBackgroundTask"));
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = BgTasksBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Near misses — casing is how a real typo arrives.
    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("schedulebackgroundtask", "{}"),
    );
    // Singular, which is the plausible slip for the cancel-all name.
    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("cancelAllBackgroundTask", "{}"),
    );
    // The JS surface method names, which are not action names.
    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("schedule", "{}"),
    );
    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("cancelAll", "{}"),
    );
    // The neighbouring cancel actions this module must not claim: two modules
    // answering one action would make `ios_dispatch`'s first-match routing
    // order-dependent.
    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("cancelNotification", "{}"),
    );
    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("cancelAllNotifications", "{}"),
    );
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = BgTasksBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        BridgeError.InvalidJSON,
        bridge.handleMessage(A.schedule_background_task, "{not json"),
    );
    try testing.expectError(
        BridgeError.InvalidJSON,
        bridge.handleMessage(A.cancel_background_task, "{not json"),
    );
}

fn parse(json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
}

fn expectTaskIdError(json: []const u8, expected: anyerror) !void {
    var parsed = try parse(json);
    defer parsed.deinit();
    try testing.expectError(expected, parseTaskId(parsed.value));
}

test "the identifier field the page sends is the one that is read" {
    // `{action:'scheduleBackgroundTask', taskId: taskId, …}` in the injected
    // JS; the shim reads `body["taskId"]`. A rename on either side of the
    // migration would make the two handlers read different payloads.
    var parsed = try parse("{\"taskId\":\"craft-sync\",\"callbackId\":\"cb_7\"}");
    defer parsed.deinit();
    try testing.expectEqualStrings("craft-sync", try parseTaskId(parsed.value));

    // The plausible wrong names are *absences*, not aliases — a payload
    // carrying only them must read as missing, or a handler bound to the wrong
    // name would pass this suite.
    try expectTaskIdError("{\"id\":\"craft-sync\"}", BridgeError.MissingData);
    try expectTaskIdError("{\"identifier\":\"craft-sync\"}", BridgeError.MissingData);
    try expectTaskIdError("{\"task\":\"craft-sync\"}", BridgeError.MissingData);
}

test "a missing taskId is refused rather than defaulted" {
    // Swift's `let taskId = body["taskId"] as? String` fails here and replies
    // nothing at all — the promise has no timeout, so that is a hang forever.
    // An error is the deliberate divergence; a default would be worse still,
    // addressing an identifier the page never named.
    var bridge = BgTasksBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        BridgeError.MissingData,
        bridge.handleMessage(A.schedule_background_task, "{}"),
    );
    try testing.expectError(
        BridgeError.MissingData,
        bridge.handleMessage(A.cancel_background_task, "{\"delay\":900}"),
    );
}

test "a non-string taskId is refused, not coerced" {
    try expectTaskIdError("{\"taskId\":7}", BridgeError.InvalidParameter);
    try expectTaskIdError("{\"taskId\":null}", BridgeError.InvalidParameter);
    try expectTaskIdError("{\"taskId\":[\"craft-sync\"]}", BridgeError.InvalidParameter);
    try expectTaskIdError("{\"taskId\":true}", BridgeError.InvalidParameter);
}

test "a taskId with an embedded NUL is refused, not truncated" {
    // `stringWithUTF8String:` stops at the first NUL, so an unchecked
    // "syncevil" would submit or cancel the identifier ending in "sync"
    // while the reply named the full one the page sent.
    try expectTaskIdError("{\"taskId\":\"sync\\u0000evil\"}", BridgeError.InvalidParameter);
}

test "an empty taskId is accepted, matching the Swift shim" {
    // Swift builds "<bundleid>." from it, hands that to the scheduler, and
    // resolves. Interchangeability with the shim is the contract here.
    var parsed = try parse("{\"taskId\":\"\"}");
    defer parsed.deinit();
    try testing.expectEqualStrings("", try parseTaskId(parsed.value));
}

test "a payload that is not an object is bad JSON, not a missing field" {
    try expectTaskIdError("[]", BridgeError.InvalidJSON);
    try expectTaskIdError("\"craft-sync\"", BridgeError.InvalidJSON);
    try expectTaskIdError("900", BridgeError.InvalidJSON);
}

test "the schedule payload is read field for field as the page posts it" {
    // The exact object `craft.backgroundTask.schedule('craft-sync', {delay:
    // 900, requiresNetwork: true, requiresCharging: false})` produces, minus
    // the callbackId the envelope replaces. This is `test-bridges.html`'s
    // Schedule button.
    var parsed = try parse(
        "{\"taskId\":\"craft-sync\",\"delay\":900,\"requiresNetwork\":true,\"requiresCharging\":false}",
    );
    defer parsed.deinit();

    const request = try parseScheduleRequest(parsed.value);
    try testing.expectEqualStrings("craft-sync", request.task_id);
    try testing.expectEqual(@as(f64, 900), request.delay);
    try testing.expect(request.requires_network);
    try testing.expect(!request.requires_charging);
}

test "delay arrives as an integer or a float and both are kept exactly" {
    // `as? Double` in Swift takes both, and JSON gives `std.json` an
    // `.integer` for `60` and a `.float` for `0.5`.
    {
        var parsed = try parse("{\"taskId\":\"t\",\"delay\":60}");
        defer parsed.deinit();
        try testing.expectEqual(@as(f64, 60), (try parseScheduleRequest(parsed.value)).delay);
    }
    {
        var parsed = try parse("{\"taskId\":\"t\",\"delay\":0.5}");
        defer parsed.deinit();
        try testing.expectEqual(@as(f64, 0.5), (try parseScheduleRequest(parsed.value)).delay);
    }
    {
        // Negative means "eligible immediately", which is what
        // `Date(timeIntervalSinceNow: -60)` means to iOS. Swift allows it.
        var parsed = try parse("{\"taskId\":\"t\",\"delay\":-60}");
        defer parsed.deinit();
        try testing.expectEqual(@as(f64, -60), (try parseScheduleRequest(parsed.value)).delay);
    }
}

test "an absent delay takes the fifteen minutes both sides already default to" {
    try testing.expectEqual(@as(f64, 900), default_delay_seconds);

    var parsed = try parse("{\"taskId\":\"craft-sync\"}");
    defer parsed.deinit();
    try testing.expectEqual(default_delay_seconds, (try parseScheduleRequest(parsed.value)).delay);
}

fn expectScheduleError(json: []const u8, expected: anyerror) !void {
    var parsed = try parse(json);
    defer parsed.deinit();
    try testing.expectError(expected, parseScheduleRequest(parsed.value));
}

test "a delay that is present and not a number is refused, not silently 900" {
    // Swift's `as? Double ?? 900` schedules fifteen minutes for every one of
    // these, which is a delay the page never asked for reported as success.
    try expectScheduleError("{\"taskId\":\"t\",\"delay\":\"soon\"}", BridgeError.InvalidParameter);
    try expectScheduleError("{\"taskId\":\"t\",\"delay\":null}", BridgeError.InvalidParameter);
    try expectScheduleError("{\"taskId\":\"t\",\"delay\":true}", BridgeError.InvalidParameter);
    try expectScheduleError("{\"taskId\":\"t\",\"delay\":[900]}", BridgeError.InvalidParameter);
}

test "a delay with no representable instant is refused" {
    // `1e400` overflows f64, so `std.json` hands back `.number_string`; there
    // is no `Date(timeIntervalSinceNow: inf)` to schedule against.
    try expectScheduleError("{\"taskId\":\"t\",\"delay\":1e400}", BridgeError.InvalidParameter);
    try expectScheduleError("{\"taskId\":\"t\",\"delay\":-1e400}", BridgeError.InvalidParameter);

    // An integer literal too wide for i64 also arrives as `.number_string`,
    // but it *is* finite as a float and stays accepted — the refusal above is
    // about the instant, not about the token shape.
    var parsed = try parse("{\"taskId\":\"t\",\"delay\":99999999999999999999}");
    defer parsed.deinit();
    try testing.expect(std.math.isFinite((try parseScheduleRequest(parsed.value)).delay));
}

test "absent constraint flags are false, matching both sides" {
    var parsed = try parse("{\"taskId\":\"craft-sync\"}");
    defer parsed.deinit();
    const request = try parseScheduleRequest(parsed.value);
    try testing.expect(!request.requires_network);
    try testing.expect(!request.requires_charging);
}

test "a constraint flag that is present and not a boolean is refused" {
    // A page that sent something for a constraint field is asking for a
    // constraint; `?? false` would drop it and report the schedule succeeded.
    try expectScheduleError("{\"taskId\":\"t\",\"requiresNetwork\":\"yes\"}", BridgeError.InvalidParameter);
    try expectScheduleError("{\"taskId\":\"t\",\"requiresNetwork\":1}", BridgeError.InvalidParameter);
    try expectScheduleError("{\"taskId\":\"t\",\"requiresCharging\":null}", BridgeError.InvalidParameter);
    try expectScheduleError("{\"taskId\":\"t\",\"requiresCharging\":{}}", BridgeError.InvalidParameter);
}

test "the constraint flags choose the request subclass that can carry them" {
    // The divergence from the shim, pinned. The shim always builds an
    // app-refresh request, which has neither property, so both flags are
    // silently dropped; only `BGProcessingTaskRequest` has
    // `requiresNetworkConnectivity` and `requiresExternalPower`.
    try testing.expectEqual(RequestKind.app_refresh, requestKindFor(false, false));
    try testing.expectEqual(RequestKind.processing, requestKindFor(true, false));
    try testing.expectEqual(RequestKind.processing, requestKindFor(false, true));
    try testing.expectEqual(RequestKind.processing, requestKindFor(true, true));

    // The reference page's Schedule button sends `requiresNetwork: true`, so
    // it is the processing path that has to keep working.
    var parsed = try parse(
        "{\"taskId\":\"craft-sync\",\"delay\":900,\"requiresNetwork\":true,\"requiresCharging\":false}",
    );
    defer parsed.deinit();
    const request = try parseScheduleRequest(parsed.value);
    try testing.expectEqual(
        RequestKind.processing,
        requestKindFor(request.requires_network, request.requires_charging),
    );
}

test "the identifier the reply names is the bundle-prefixed one" {
    // `"\(bundleIdentifier).\(taskId)"`. The prefixed id is what comes back to
    // the page, and `test-bridges.html` prints it — so this string is contract,
    // not an implementation detail.
    const joined = try joinIdentifier(testing.allocator, "com.acme.app", "craft-sync");
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("com.acme.app.craft-sync", joined);

    // The shim's nil-bundle spelling, kept byte-identical so the parity trade
    // described in the module header stays one line away.
    const fallback = try joinIdentifier(testing.allocator, default_bundle_prefix, "craft-sync");
    defer testing.allocator.free(fallback);
    try testing.expectEqualStrings("com.craft.app.craft-sync", fallback);

    // Swift's interpolation puts the dot in unconditionally, so an empty
    // taskId yields a trailing dot rather than the bare bundle id.
    const empty = try joinIdentifier(testing.allocator, "com.acme.app", "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("com.acme.app.", empty);
}

test "the schedule reply is the object Swift resolves, not a bare fragment" {
    // `resolveCallback(callbackId, result: ["taskId": fullTaskId, "scheduled":
    // true])`. `test-bridges.html` does `JSON.stringify(result)`, so both keys
    // are observable and a bare `true` would change what the page sees.
    const reply = try taskReply(testing.allocator, "com.acme.app.craft-sync", scheduled_key);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings(
        "{\"taskId\":\"com.acme.app.craft-sync\",\"scheduled\":true}",
        reply,
    );

    var parsed = try parse(reply);
    defer parsed.deinit();
    try testing.expectEqualStrings("com.acme.app.craft-sync", parsed.value.object.get("taskId").?.string);
    try testing.expect(parsed.value.object.get("scheduled").?.bool);
}

test "the cancel reply carries taskId and cancelled" {
    const reply = try taskReply(testing.allocator, "com.acme.app.craft-sync", cancelled_key);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings(
        "{\"taskId\":\"com.acme.app.craft-sync\",\"cancelled\":true}",
        reply,
    );
}

test "the cancel-all reply has no taskId key at all" {
    // The one reply of the three that differs in shape: Swift resolves
    // `["cancelled": true]` with nothing else in it. A page reading
    // `result.taskId` there must get undefined, as it does today.
    try testing.expectEqualStrings("{\"cancelled\":true}", cancel_all_fragment);
    try testing.expect(std.mem.indexOf(u8, cancel_all_fragment, "taskId") == null);
    // The same key spelling the id-carrying cancel uses.
    try testing.expect(std.mem.indexOf(u8, cancel_all_fragment, cancelled_key) != null);

    var parsed = try parse(cancel_all_fragment);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("taskId") == null);
    try testing.expect(parsed.value.object.get("cancelled").?.bool);
}

test "a taskId that would break the reply is escaped, not injected" {
    // The whole reply is replayed into `evaluateJavaScript:` as source, and
    // the identifier embeds a page-controlled name. An unescaped quote would
    // terminate the JSON string and break the page's promise resolution — or
    // worse.
    const full = try joinIdentifier(testing.allocator, "com.acme.app", "a\"b\\c\nd");
    defer testing.allocator.free(full);

    const reply = try taskReply(testing.allocator, full, cancelled_key);
    defer testing.allocator.free(reply);

    var parsed = try parse(reply);
    defer parsed.deinit();
    // Round-trips to exactly the identifier that was addressed, so the page is
    // told the truth about which task it cancelled.
    try testing.expectEqualStrings(full, parsed.value.object.get("taskId").?.string);
}

test "off Darwin the handlers refuse rather than fake success" {
    if (builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    var bridge = BgTasksBridge.init(testing.allocator);
    defer bridge.deinit();

    // Valid payloads, so the refusal is the platform's and not the parser's.
    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(
            A.schedule_background_task,
            "{\"taskId\":\"craft-sync\",\"delay\":900,\"requiresNetwork\":true,\"requiresCharging\":false}",
        ),
    );
    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.cancel_background_task, "{\"taskId\":\"craft-sync\"}"),
    );
    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.cancel_all_background_tasks, "{}"),
    );
}

test "without a bundle identifier the guard fires before the scheduler is touched" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    // The host test runner is a bare binary with no Info.plist. The guard must
    // turn that into an error reply for all three actions, including the one
    // that needs no prefix — cancel-all still reaches the scheduler.
    if (requireBundlePrefix()) |_| {
        // A runner that does carry a bundle identifier (tests hosted inside an
        // app) would make the calls below real cancellations against that
        // app's pending work; proving the guard needs the bundle-less
        // environment, so skip rather than pretend.
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.NoBundleIdentifier => {
            var bridge = BgTasksBridge.init(testing.allocator);
            defer bridge.deinit();

            try testing.expectError(
                error.NoBundleIdentifier,
                bridge.handleMessage(A.schedule_background_task, "{\"taskId\":\"conformance-probe\"}"),
            );
            try testing.expectError(
                error.NoBundleIdentifier,
                bridge.handleMessage(A.cancel_background_task, "{\"taskId\":\"conformance-probe\"}"),
            );
            try testing.expectError(
                error.NoBundleIdentifier,
                bridge.handleMessage(A.cancel_all_background_tasks, "{}"),
            );
        },
        else => return err,
    }
}

test "BackgroundTasks is absent from the host binary, so the scheduler is a named refusal" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    if (objc.objc_getClass("BGTaskScheduler") != null) {
        // Something now links BackgroundTasks into the iOS test artifacts.
        // Calling `sharedScheduler` from here would run it in a bundle-less
        // process, which is the exact unknown this module refuses to explore,
        // so skip loudly rather than risk an uncatchable ObjC exception.
        std.debug.print(
            "BGTaskScheduler is loaded in the test process; the class-not-found path is no longer reachable here\n",
            .{},
        );
        return error.SkipZigTest;
    }

    // The normal answer: no framework, so a named error instead of a crash or
    // a fabricated success. This is also the answer a shipped app would start
    // giving if `import BackgroundTasks` were removed from CraftApp.swift,
    // since frameworks are linked at the app level in Xcode.
    try testing.expectError(error.ClassNotFound, scheduler());
}

test "validation outruns Objective-C on every platform" {
    // The same refusals with and without a runtime behind them: a payload the
    // handler must refuse is refused identically on Linux and macOS, which is
    // what makes the parser tests above binding for the device build too.
    var bridge = BgTasksBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        BridgeError.MissingData,
        bridge.handleMessage(A.schedule_background_task, "{}"),
    );
    try testing.expectError(
        BridgeError.InvalidParameter,
        bridge.handleMessage(A.cancel_background_task, "{\"taskId\":42}"),
    );
    try testing.expectError(
        BridgeError.InvalidParameter,
        bridge.handleMessage(A.schedule_background_task, "{\"taskId\":\"a\\u0000b\"}"),
    );
    try testing.expectError(
        BridgeError.InvalidParameter,
        bridge.handleMessage(A.schedule_background_task, "{\"taskId\":\"t\",\"delay\":\"soon\"}"),
    );
    try testing.expectError(
        BridgeError.InvalidParameter,
        bridge.handleMessage(A.schedule_background_task, "{\"taskId\":\"t\",\"requiresCharging\":\"yes\"}"),
    );
}
