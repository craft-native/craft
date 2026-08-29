//! The haptics half of the `mobile` namespace: `haptic` and `vibrate`.
//!
//! Split out of `bridge_mobile.zig` because the two actions have opposite
//! contracts — `haptic` is fire-and-forget and gated on a config flag, while
//! `vibrate` replies and is gated on nothing — and because one of them cannot
//! be served honestly from Zig yet. Keeping that admission next to the working
//! action, rather than folded into the namespace's main file, is the point.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const mobile = @import("mobile.zig");

const objc = objc_runtime.objc;

/// Reused rather than redefined: `mobile.iOS.HapticType` is already the
/// vocabulary the rest of the tree speaks, and a second spelling of the same
/// seven cases is a second thing to keep in step.
const HapticType = mobile.iOS.HapticType;

pub const A = struct {
    pub const haptic = "haptic";
    pub const vibrate = "vibrate";
};

/// `haptic` is declared `unavailable`, and that is a decision, not an oversight.
///
/// The Swift it replaces does not run `triggerHaptic` unconditionally — it runs
/// it `if config.enableHaptics` (`CraftApp.swift:537`), and that flag defaults
/// to **false** in both the template (`CraftApp.swift:190`) and the SDK
/// (`packages/ios/src/index.ts:118`). It reaches Zig through nothing: no
/// `craft_ios_*` export carries it, no build option encodes it. So serving
/// `haptic` from here means serving a *different action* from the one the spec
/// defines — every app on the default config would start buzzing on
/// `craft.haptics.impact()`, which is the entire shipped haptics surface, and
/// no test in this repo could see it because the Taptic Engine has no readback.
///
/// The three ways to make that go away are all worse than saying so:
///   - fire anyway → a behaviour change that is invisible in CI and obvious on
///     a device;
///   - hardcode the gate false → a permanent no-op that reports nothing, which
///     is the shape of the nine Android handlers that were deleted;
///   - reply `{"success":true}` → fabricated success, the thing this migration
///     exists to stop.
///
/// So the handler refuses and the manifest says why. Unblocking it is small and
/// deliberate: plumb the flag in (a `craft_ios_set_capabilities` export or a
/// build option), then swap the refusal in `haptic()` for the mapping and the
/// trigger below, both of which are written and pinned by the tests at the
/// bottom of this file. What must not happen is the flip happening silently.
///
/// Note the inconsistency this preserves: `case "vibrate"` has no
/// `enableHaptics` gate in the spec either, so `craft.vibrate([100])` already
/// fires impacts on an app with haptics "disabled". `vibrate` stays ungated to
/// match; the asymmetry is the spec's, not ours.
const haptic_unavailable_reason =
    "iOS gates haptic on config.enableHaptics, which defaults to false and is " ++
    "not visible to Zig; serving it here would enable haptics for every app " ++
    "that never opted in";

pub const capability_actions = [_]capabilities.ActionDecl{
    // `.none` is the action's contract regardless of status: the page's
    // `craft.haptic()` returns undefined and the spec's `case "haptic"` never
    // touches `resolveCallback`. An error still reaches the page — with no
    // pending entry to settle, `craft-bridge.js` reports it to the console —
    // so a refusal is logged rather than swallowed.
    .{
        .name = A.haptic,
        .reply = .none,
        .status = .unavailable,
        .reason = haptic_unavailable_reason,
    },
    // `.result` carrying the JSON literal `true`. Not a shape worth improving:
    // the hand-off path already delivers exactly this today, and `.none` would
    // park any `_req`-based caller for the full 30s timeout.
    .{ .name = A.vibrate, .reply = .result },
};

/// The reply `vibrate` sends, byte-identical to what the hand-off path delivers
/// today. A bare `true`, not an object — the spec serialises with
/// `.fragmentsAllowed`. It stays truthy on purpose: `craft-bridge.js` resolves
/// with `payload || {}`, so `false` or `0` would arrive as `{}`.
const vibrate_reply = "true";

pub const HapticsBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.haptic)) {
            return self.haptic(data);
        } else if (std.mem.eql(u8, action, A.vibrate)) {
            return self.vibrate(data);
        }
        return bridge_error.BridgeError.UnknownAction;
    }

    /// Refuses, for the reason recorded on `haptic_unavailable_reason`.
    ///
    /// The payload is not parsed first. Reporting a malformed `style` would
    /// imply the style was going to be used, and it is not — a refusal that
    /// sometimes reports a different cause is harder to act on than one that
    /// always says the same thing.
    ///
    /// The error name is what lands in the device log; the page sees
    /// `NATIVE_CALL_FAILED`, `ios_dispatch.asBridgeError`'s catch-all, because
    /// the wire protocol has no code for "declared unavailable". The manifest
    /// is where an app reads the actual reason.
    fn haptic(_: *Self, _: []const u8) !void {
        return error.HapticsGateNotVisibleToZig;
    }

    /// `case "vibrate"` (`CraftApp.swift:685-691`).
    ///
    /// Two paths, and which one runs is decided exactly the way Swift's
    /// `body["pattern"] as? [Int]` decides it — see `patternArray`. A
    /// well-formed array schedules impacts (possibly none, for `[]`); anything
    /// else fires a single medium impact immediately.
    ///
    /// The `true` goes out only if the work succeeded. The spec replies `true`
    /// unconditionally, but its work cannot visibly fail; ours can — a missing
    /// `UIImpactFeedbackGenerator` is a real condition — and answering `true`
    /// to a call that did nothing is the failure mode this migration exists to
    /// remove. A caller that gets an error can retry or degrade; one that gets
    /// `true` cannot.
    fn vibrate(self: *Self, data: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return bridge_error.BridgeError.InvalidJSON;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return bridge_error.BridgeError.InvalidJSON,
        };

        if (patternArray(root.get("pattern"))) |items| {
            _ = try schedulePattern(items);
        } else {
            // Swift's else arm. Deliberately *not* `MissingData`: `craft.vibrate()`
            // with no argument posts no `pattern` at all, and rejecting that
            // would be stricter than the surface the page is written against.
            try triggerHapticChecked(.impact_medium);
        }

        bridge_error.sendResultToJS(self.allocator, A.vibrate, vibrate_reply);
    }
};

/// Swift's `if let pattern = body["pattern"] as? [Int]`, as a decision.
///
/// Returns the elements when the cast would succeed and null when it would
/// fail — absent key, not an array, or an array holding anything that is not an
/// integer. Note that an *empty* array is a successful cast, so `[]` returns an
/// empty slice rather than null: `craft.haptics.vibrate()` sends `[]`, and it
/// must schedule nothing rather than take the single-impact fallback.
///
/// Non-integer numbers fail the cast, matching `NSNumber`'s exact-representability
/// rule. In practice `JSON.stringify` renders every integral JS number without a
/// fraction, so a `.float` on the wire is always genuinely non-integral —
/// `[100.5]` is the case this rejects, and it rejects it the way Swift does.
///
/// The returned slice points into the caller's `std.json.Parsed`, so it is only
/// valid until that is deinitialised.
fn patternArray(value: ?std.json.Value) ?[]const std.json.Value {
    const v = value orelse return null;
    const items = switch (v) {
        .array => |a| a.items,
        else => return null,
    };
    for (items) |item| {
        if (item != .integer) return null;
    }
    return items;
}

/// How far from *now* entry `index` of a pattern lands, or null if it does
/// nothing. Three facts from `vibratePattern` (`CraftApp.swift:3210-3220`),
/// carried across deliberately:
///
///  1. Even indices only. The Web Vibration API reads odd entries as pauses;
///     the spec reads them and then ignores them entirely, not even as timing.
///  2. Only `duration > 0` fires. Zero and negative entries are skipped.
///  3. **The delay is measured from now, not accumulated.** For
///     `[100, 50, 100, 50, 200]` that puts indices 0 and 2 on the *same
///     instant*, so the canonical five-element example produces two impacts,
///     not three.
///
/// (3) is almost certainly not what "pattern" is meant to mean, and it is kept
/// anyway: this is a migration, the Swift is the specification, and a running
/// offset would be a silent behaviour change dressed as a port. It is written
/// down here so the next reader knows it was a decision and not a transcription
/// slip — changing it is a product call, not a cleanup.
///
/// The multiply saturates rather than overflowing: `duration` is whatever
/// integer the page put in the array, and an overflowing multiply is a panic in
/// a safe build. A clamped delay is a distant one, which is the same nothing an
/// enormous delay would have been.
fn impactDelayNs(index: usize, duration_ms: i64) ?i64 {
    if (index % 2 != 0) return null;
    if (duration_ms <= 0) return null;
    return std.math.mul(i64, duration_ms, std.time.ns_per_ms) catch std.math.maxInt(i64);
}

/// Queue a medium impact for each firing entry, and report how many were
/// queued.
///
/// The class and both selectors are resolved *before* anything is scheduled.
/// The blocks run long after this function returns, by which point the reply is
/// already on its way to the page and a failure has nowhere to be reported — so
/// the one check that can still reach the caller is made while it still can.
fn schedulePattern(items: []const std.json.Value) !usize {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    _ = objc.objc_getClass("UIImpactFeedbackGenerator") orelse return error.ClassNotFound;
    _ = objc.sel_registerName("initWithStyle:") orelse return error.SelectorNotFound;
    _ = objc.sel_registerName("impactOccurred") orelse return error.SelectorNotFound;

    var scheduled: usize = 0;
    for (items, 0..) |item, index| {
        const duration_ms = switch (item) {
            .integer => |n| n,
            // `patternArray` guarantees this cannot happen; an explicit error
            // beats `unreachable` if that guarantee is ever loosened.
            else => return bridge_error.BridgeError.InvalidParameter,
        };
        const delay_ns = impactDelayNs(index, duration_ms) orelse continue;

        const when = dispatch.dispatch_time(dispatch.DISPATCH_TIME_NOW, delay_ns);
        dispatch.dispatch_after(when, &dispatch._dispatch_main_q, &medium_impact_block);
        scheduled += 1;
    }
    return scheduled;
}

/// `mobile.iOS.triggerHaptic` with the failures reported instead of swallowed.
///
/// The existing one is `fn (HapticType) void` whose every failure path is
/// `orelse return`, so a missing class and a fired haptic are the same value to
/// a caller. That is fine for its two fire-and-forget callers and not fine for
/// a bridge, which has to decide between replying and erroring. Same ObjC, same
/// enum, same constants — only the return type differs.
///
/// No dispatch hop. `UIFeedbackGenerator` is main-thread-only, and the only
/// path here starts in `craftDidReceiveScriptMessage`, a `WKScriptMessageHandler`
/// callback that WebKit already delivers on the main thread.
///
/// What this still cannot tell you: whether anything was *felt*. The Taptic
/// Engine is absent on the simulator and on iPad, and System Haptics can be off
/// in Settings — all three are silent no-ops with no API that reports them. So
/// "returned without error" means "UIKit accepted the call", never "the device
/// buzzed", which is the other half of why `haptic` has no success reply to
/// fabricate.
fn triggerHapticChecked(haptic_type: HapticType) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    switch (haptic_type) {
        .selection => {
            const class = objc.objc_getClass("UISelectionFeedbackGenerator") orelse
                return error.ClassNotFound;
            const sel_selection_changed = objc.sel_registerName("selectionChanged") orelse
                return error.SelectorNotFound;

            const generator = try objc.allocInit(class);
            if (generator == null) return error.GeneratorNotCreated;
            defer objc.release(generator);

            objc.msgSend(generator, sel_selection_changed);
        },
        .impact_light, .impact_medium, .impact_heavy => {
            const class = objc.objc_getClass("UIImpactFeedbackGenerator") orelse
                return error.ClassNotFound;
            const sel_init_with_style = objc.sel_registerName("initWithStyle:") orelse
                return error.SelectorNotFound;
            const sel_impact_occurred = objc.sel_registerName("impactOccurred") orelse
                return error.SelectorNotFound;

            // UIImpactFeedbackStyle. Light/Medium/Heavy; Soft(3) and Rigid(4)
            // exist but nothing maps to them — see `hapticTypeForStyle`.
            const style: i64 = switch (haptic_type) {
                .impact_light => 0,
                .impact_heavy => 2,
                else => 1,
            };

            const allocated = try objc.alloc(class);
            if (allocated == null) return error.GeneratorNotCreated;

            // `initWithStyle:` takes an NSInteger, so the cast must say i64 —
            // an object-argument msgSend here would pass the enum as a pointer
            // and get a garbage style, silently.
            const InitWithStyle = *const fn (objc.id, objc.SEL, i64) callconv(.c) objc.id;
            const init_with_style: InitWithStyle = @ptrCast(&objc.objc_msgSend);
            const generator = init_with_style(allocated, sel_init_with_style, style);
            if (generator == null) {
                objc.release(allocated);
                return error.GeneratorNotCreated;
            }
            defer objc.release(generator);

            objc.msgSend(generator, sel_impact_occurred);
        },
        .notification_success, .notification_warning, .notification_error => {
            const class = objc.objc_getClass("UINotificationFeedbackGenerator") orelse
                return error.ClassNotFound;
            const sel_notification_occurred = objc.sel_registerName("notificationOccurred:") orelse
                return error.SelectorNotFound;

            const generator = try objc.allocInit(class);
            if (generator == null) return error.GeneratorNotCreated;
            defer objc.release(generator);

            // UINotificationFeedbackType: Success/Warning/Error.
            const feedback_type: i64 = switch (haptic_type) {
                .notification_warning => 1,
                .notification_error => 2,
                else => 0,
            };

            const NotificationOccurred = *const fn (objc.id, objc.SEL, i64) callconv(.c) void;
            const notification_occurred: NotificationOccurred = @ptrCast(&objc.objc_msgSend);
            notification_occurred(generator, sel_notification_occurred, feedback_type);
        },
    }
}

/// `triggerHaptic(style:)` (`CraftApp.swift:2562-2579`) as a mapping.
///
/// Written, tested, and — while `haptic` is refused — not yet reachable from a
/// handler. It is here because it is the finished half of the blocked action:
/// once `enableHaptics` is visible to Zig, `haptic()` becomes a parse of
/// `style` plus a call to this plus a call to `triggerHapticChecked`, with the
/// mapping already pinned against the spec rather than re-derived under time
/// pressure.
///
/// Two quirks are reproduced rather than fixed, because fixing either here
/// would be a behaviour change hidden inside a migration:
///
///  - **`"soft"` maps to a medium impact, not a selection haptic.**
///    `craft.haptics.selection()` posts `'soft'` (`CraftApp.swift:2334`), which
///    hits the spec's `default:` arm — so the shipped `selection()` has never
///    produced a selection haptic, and `.selection` is reachable only through a
///    direct `craft.haptic('selection')`. `HapticType` has no `impact_soft`
///    tag, so honouring `'soft'` as `UIImpactFeedbackStyleSoft` would mean
///    widening the enum *and* changing what the shipped API does.
///  - **An unknown style is absorbed, not rejected.** A typo is indistinguishable
///    from `"medium"`. With no reply channel there is nowhere to report it, and
///    the spec's `default:` swallows it too.
///
/// The field is `style`. Not `type` — `examples/web_to_native/app.html` posts
/// `{type: ...}` but through a local `invoke` shim that never reaches this
/// bridge, and `craft-bridge.d.ts`'s `triggerHaptic({style})` is a different
/// action name in a different namespace.
fn hapticTypeForStyle(style: []const u8) HapticType {
    if (std.mem.eql(u8, style, "light")) return .impact_light;
    if (std.mem.eql(u8, style, "heavy")) return .impact_heavy;
    if (std.mem.eql(u8, style, "success")) return .notification_success;
    if (std.mem.eql(u8, style, "warning")) return .notification_warning;
    if (std.mem.eql(u8, style, "error")) return .notification_error;
    if (std.mem.eql(u8, style, "selection")) return .selection;
    return .impact_medium;
}

// =============================================================================
// libdispatch, and the one block this file needs.
//
// Declared inside a struct so they stay lazily analysed: off Darwin the only
// reference to any of them sits behind a comptime-false `isDarwin()` guard, so
// a Linux host build never asks the linker for a symbol libSystem owns.
// =============================================================================

const dispatch = struct {
    const DISPATCH_TIME_NOW: u64 = 0;

    extern "c" fn dispatch_time(when: u64, delta: i64) u64;
    extern "c" fn dispatch_after(when: u64, queue: *anyopaque, block: *const anyopaque) void;

    /// `dispatch_get_main_queue()` is a macro over this symbol, not a function
    /// call — the main queue *is* the address of this global.
    extern var _dispatch_main_q: anyopaque;
};

const BlockDescriptor = extern struct {
    reserved: usize = 0,
    size: usize,
};

/// `dispatch_block_t` is `void (^)(void)`, so `invoke` takes one argument — the
/// block itself — unlike the two-argument completion blocks in
/// `bridge_permissions.zig`.
const DispatchBlock = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*const anyopaque) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

/// A *global* block, not a stack one — and that is the whole reason this is
/// spelled out rather than copied from `bridge_permissions.zig`.
///
/// Those blocks are handed to `requestAccess…`, which consumes them
/// synchronously, so `_NSConcreteStackBlock` is fine there. `dispatch_after`
/// instead calls `Block_copy` on its argument and holds it until the block
/// fires. `Block_copy` on a global block is the identity function; on a stack
/// block it heap-copies and later releases, which happens to work for a
/// non-capturing block but leans on an implementation detail of libclosure for
/// a lifetime that outlives this call.
///
/// It captures nothing because the spec's block captures nothing: every
/// scheduled entry is the same medium impact, so one file-scope constant serves
/// an entire pattern.
extern var _NSConcreteGlobalBlock: anyopaque;

const BLOCK_IS_GLOBAL: c_int = 1 << 28;

/// Runs on the main queue, after the reply has already gone out. There is no
/// caller left to tell, so a failure is logged — the alternative is a silent
/// nothing, which is how you end up unable to tell a broken generator from a
/// device with System Haptics switched off.
fn mediumImpactInvoke(_: *const anyopaque) callconv(.c) void {
    triggerHapticChecked(.impact_medium) catch |err| {
        std.log.warn("craft-bridge: scheduled vibrate impact did not fire: {}", .{err});
    };
}

const medium_impact_descriptor = BlockDescriptor{ .size = @sizeOf(DispatchBlock) };

const medium_impact_block = DispatchBlock{
    .isa = &_NSConcreteGlobalBlock,
    .flags = BLOCK_IS_GLOBAL,
    .reserved = 0,
    .invoke = mediumImpactInvoke,
    .descriptor = &medium_impact_descriptor,
};

const testing = std.testing;

test "the table declares exactly the two actions the dispatcher serves" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    try testing.expectEqualStrings(A.haptic, capability_actions[0].name);
    try testing.expectEqualStrings(A.vibrate, capability_actions[1].name);

    // The replies are the halves that go wrong invisibly: a `.result` that
    // never replies parks the caller for 30s, and a `.none` that is awaited
    // resolves immediately and means nothing.
    try testing.expectEqual(capabilities.Reply.none, capability_actions[0].reply);
    try testing.expectEqual(capabilities.Reply.result, capability_actions[1].reply);
}

test "an unavailable action carries the reason with it" {
    // Without a reason, `unavailable` tells an app that something is broken and
    // nothing about what to do next — which is most of the value of declaring
    // it at all.
    for (capability_actions) |decl| {
        if (decl.status != .unavailable) continue;
        try testing.expect(decl.reason != null);
        try testing.expect(decl.reason.?.len > 0);
    }
    try testing.expectEqual(capabilities.ActionStatus.unavailable, capability_actions[0].status);
    try testing.expectEqual(capabilities.ActionStatus.live, capability_actions[1].status);
}

test "every declared action dispatches — none of them falls through as unknown" {
    // The drift this whole effort exists to make impossible: a name in the
    // table that the chain does not compare against would be reported to the
    // page as served, and reach the host shim instead.
    var bridge = HapticsBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != bridge_error.BridgeError.UnknownAction);
            continue;
        };
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = HapticsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );

    // Near-misses too: the shipped surface has a `craft.haptics` namespace
    // object, and `haptics` is not `haptic`.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("haptics", "{}"),
    );
}

test "haptic refuses rather than firing an ungated haptic" {
    // The refusal is the migration's honest answer while `config.enableHaptics`
    // has no Zig representation. If this test starts failing because someone
    // implemented the action, the flag has to have been plumbed through first —
    // that is the conversation this assertion exists to force.
    var bridge = HapticsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        error.HapticsGateNotVisibleToZig,
        bridge.handleMessage(A.haptic, "{\"style\":\"medium\"}"),
    );
}

test "every style the shipped surface posts maps the way the spec's switch does" {
    try testing.expectEqual(HapticType.impact_light, hapticTypeForStyle("light"));
    try testing.expectEqual(HapticType.impact_heavy, hapticTypeForStyle("heavy"));
    try testing.expectEqual(HapticType.notification_success, hapticTypeForStyle("success"));
    try testing.expectEqual(HapticType.notification_warning, hapticTypeForStyle("warning"));
    try testing.expectEqual(HapticType.notification_error, hapticTypeForStyle("error"));
    try testing.expectEqual(HapticType.selection, hapticTypeForStyle("selection"));
    try testing.expectEqual(HapticType.impact_medium, hapticTypeForStyle("medium"));
}

test "the spec's default arm absorbs everything else, including 'soft'" {
    // `craft.haptics.selection()` posts 'soft', which lands here — so the
    // shipped selection() has never produced a selection haptic. Pinned as a
    // known quirk so it is not rediscovered as a bug, and not fixed here
    // because fixing it is a behaviour change, not a port.
    try testing.expectEqual(HapticType.impact_medium, hapticTypeForStyle("soft"));
    try testing.expectEqual(HapticType.impact_medium, hapticTypeForStyle("rigid"));
    // A typo is indistinguishable from "medium". There is no reply channel to
    // say otherwise on, which is exactly what the spec does too.
    try testing.expectEqual(HapticType.impact_medium, hapticTypeForStyle("mediuim"));
    try testing.expectEqual(HapticType.impact_medium, hapticTypeForStyle(""));
}

/// Parse a payload and classify its `pattern` the way `vibrate` does.
fn classify(json: []const u8) !?[]const std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    // The slice would dangle past `parsed.deinit()`, so tests assert on length
    // and on the null/non-null decision rather than holding the elements.
    const items = patternArray(parsed.value.object.get("pattern")) orelse return null;
    return items[0..0];
}

test "a well-formed integer pattern takes the loop path" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"pattern\":[100,50,100,50,200]}",
        .{},
    );
    defer parsed.deinit();

    const items = patternArray(parsed.value.object.get("pattern")).?;
    try testing.expectEqual(@as(usize, 5), items.len);
    try testing.expectEqual(@as(i64, 100), items[0].integer);
}

test "an empty pattern is a successful cast, so it schedules nothing" {
    // The asymmetry that matters: `craft.haptics.vibrate()` sends `[]`, which
    // must fire nothing, while a *missing* pattern fires one medium impact.
    // Collapsing the two would make the common call buzz.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"pattern\":[]}",
        .{},
    );
    defer parsed.deinit();

    const items = patternArray(parsed.value.object.get("pattern"));
    try testing.expect(items != null);
    try testing.expectEqual(@as(usize, 0), items.?.len);
}

test "an absent, non-array, or non-integer pattern takes the single-impact arm" {
    // All three are `as? [Int]` failures in the spec, and all three still reply
    // `true`. Returning MissingData for the absent case would be stricter than
    // the surface: `craft.vibrate()` with no argument posts no `pattern` at all.
    try testing.expectEqual(@as(?[]const std.json.Value, null), try classify("{}"));
    try testing.expectEqual(@as(?[]const std.json.Value, null), try classify("{\"pattern\":null}"));
    try testing.expectEqual(@as(?[]const std.json.Value, null), try classify("{\"pattern\":100}"));
    try testing.expectEqual(@as(?[]const std.json.Value, null), try classify("{\"pattern\":\"100\"}"));
    // One bad element spoils the cast, exactly as `[Any] as? [Int]` does.
    try testing.expectEqual(@as(?[]const std.json.Value, null), try classify("{\"pattern\":[100.5]}"));
    try testing.expectEqual(@as(?[]const std.json.Value, null), try classify("{\"pattern\":[100,\"x\"]}"));
    try testing.expectEqual(@as(?[]const std.json.Value, null), try classify("{\"pattern\":[100,null]}"));
}

test "odd entries are pauses that do nothing at all, not even to timing" {
    try testing.expectEqual(@as(?i64, null), impactDelayNs(1, 50));
    try testing.expectEqual(@as(?i64, null), impactDelayNs(3, 5000));
    try testing.expect(impactDelayNs(0, 50) != null);
    try testing.expect(impactDelayNs(2, 50) != null);
}

test "zero and negative durations are skipped" {
    try testing.expectEqual(@as(?i64, null), impactDelayNs(0, 0));
    try testing.expectEqual(@as(?i64, null), impactDelayNs(0, -100));
}

test "delays are measured from now, so the canonical pattern collapses to two" {
    // [100, 50, 100, 50, 200] fires at +100ms, +100ms and +200ms — indices 0
    // and 2 land on the same instant. This is the spec's semantics and it is
    // almost certainly not what "pattern" means; it is reproduced on purpose,
    // and this assertion is here so a future reader can tell the difference
    // between a bug and a decision before changing it.
    const pattern = [_]i64{ 100, 50, 100, 50, 200 };
    var delays: [3]i64 = undefined;
    var count: usize = 0;
    for (pattern, 0..) |duration_ms, index| {
        if (impactDelayNs(index, duration_ms)) |delay| {
            delays[count] = delay;
            count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(i64, 100 * std.time.ns_per_ms), delays[0]);
    try testing.expectEqual(delays[0], delays[1]);
    try testing.expectEqual(@as(i64, 200 * std.time.ns_per_ms), delays[2]);
}

test "an absurd duration saturates instead of panicking" {
    // The page controls these integers. An overflowing multiply is a panic in a
    // safe build, which would turn a malformed payload into a dead app.
    try testing.expectEqual(
        @as(?i64, std.math.maxInt(i64)),
        impactDelayNs(0, std.math.maxInt(i64)),
    );
}

test "the vibrate reply is the bare JSON literal the hand-off path already sends" {
    // Not `{"success":true}`. The spec serialises with `.fragmentsAllowed`, so
    // a page on the hand-off path receives `true` today, and it must keep
    // receiving `true`. Truthy also matters: `craft-bridge.js` resolves with
    // `payload || {}`, which would turn `false` into an empty object.
    try testing.expectEqualStrings("true", vibrate_reply);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, vibrate_reply, .{});
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.bool);
}

test "the scheduled block is global, so dispatch_after's Block_copy is a no-op" {
    // A stack block would be heap-copied and later released by libclosure —
    // workable for a non-capturing block, but a lifetime that outlives the call
    // resting on an implementation detail. The flag is what makes Block_copy
    // return the same pointer.
    try testing.expectEqual(@as(c_int, 0x10000000), BLOCK_IS_GLOBAL);
    try testing.expectEqual(@sizeOf(DispatchBlock), medium_impact_descriptor.size);

    // Asserted on the block, not only on the constants it is assembled from.
    // Without these two the test name is a claim nothing checks: swapping in
    // the `_NSConcreteStackBlock` spelling that five other files in this tree
    // use leaves `BLOCK_IS_GLOBAL` and the descriptor size both correct and the
    // block no longer global. Guarded because naming `_NSConcreteGlobalBlock`
    // is what pulls the symbol into the link.
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    try testing.expectEqual(BLOCK_IS_GLOBAL, medium_impact_block.flags);
    try testing.expectEqual(&_NSConcreteGlobalBlock, medium_impact_block.isa);
    try testing.expectEqual(&medium_impact_descriptor, medium_impact_block.descriptor);
}
