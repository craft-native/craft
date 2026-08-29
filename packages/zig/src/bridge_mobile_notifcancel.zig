//! The notification-cancel actions of the `mobile` namespace:
//! `cancelNotification`, `cancelAllNotifications`.
//!
//! One JS surface reaches these: the legacy `craft.notifications` object —
//! `cancel(notificationId)` posts `{action:'cancelNotification',
//! id: notificationId, callbackId: id}`, `cancelAll()` posts the action alone.
//! The modern contract-install (`Object.assign` over the legacy object) keeps
//! both methods unchanged. Neither promise has a timeout — they do not go
//! through `_createCallback` — so a dropped message parks the page forever,
//! which is why every path here ends in a reply or an error.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **The identifier field is `id`** — not `identifier`, not
//!    `notificationId`. That is what the injected JS posts and what the Swift
//!    shim reads (`body["id"]`), pinned on both sides of the migration. The
//!    `callbackId` also present in the payload is correlation plumbing the
//!    Zig envelope replaces with `i`; it is ignored, not consumed.
//!  - **Replies are the bare fragment `true`**, Swift's
//!    `resolveCallback(callbackId, result: true)` through `.fragmentsAllowed`.
//!    No object wrapper. Consumers discard the value (`craft.d.ts` says
//!    `Promise<void>`); what they rely on is that the promise settles.
//!  - **Pending removal only.** Swift calls
//!    `removePendingNotificationRequests(withIdentifiers:)` /
//!    `removeAllPendingNotificationRequests()` and never touches delivered
//!    notifications — zero "Delivered" calls in `CraftApp.swift`. The desktop
//!    module (`bridge_notification.zig`) *does* also clear delivered ones;
//!    copying that here would make the Zig and Swift handlers observably
//!    different mid-migration, so it is deliberately not copied.
//!  - **Cancelling an unknown or never-scheduled id is a no-op that still
//!    resolves `true`** — the UN call ignores unmatched identifiers, and so
//!    does Swift. Idempotent, like the securestore removes next door.
//!  - **An empty-string `id` passes through.** Swift hands `""` to the UN
//!    center, which matches nothing, and resolves `true`. The desktop module
//!    errors `MissingData` on an empty id; bug-compatibility with the Swift
//!    shim wins here, because the two handlers must be interchangeable while
//!    the shim still exists.
//!
//! ## What is deliberately not carried across
//!
//! **Swift's silent hang.** The dispatcher arm is
//! `if config.enableLocalNotifications, let notifId = body["id"] as? String`
//! with no `else`: a missing `id`, a non-string `id`, or the gate at its
//! default `false` replies nothing at all, and the untimed promise never
//! settles. Malformed input errors here instead (`MissingData` /
//! `InvalidParameter`). The `enableLocalNotifications` gate has no Zig mirror
//! (it appears nowhere in `packages/zig/src`), so the actions are served
//! unconditionally — the securestore module documents the same choice, and
//! cancelling notifications grants a page strictly less than the wipe that
//! precedent already serves ungated.
//!
//! **An `id` with an embedded NUL.** `\u0000` is a legal JSON escape and a
//! page can send it; the route to the UN center is `stringWithUTF8String:`,
//! which truncates at the NUL and would cancel a *different* identifier than
//! the page named, then report `true` for the full one. Refused as
//! `InvalidParameter`, exactly as `bridge_mobile_storage.requireNulFree` does.
//!
//! ## The bundle-identifier guard, first and non-negotiable
//!
//! `[UNUserNotificationCenter currentNotificationCenter]` raises
//! `NSInternalInconsistencyException` in a process without a bundle
//! identifier, and an uncaught Objective-C exception is an uncatchable
//! SIGABRT. That is precisely the environment the bare `craft` fixture binary
//! and the host test runner execute in, so both handlers ask
//! `requireBundleIdentifier` before anything touches the center — the same
//! condition `bridge_notification.zig`'s `hasBundleIdentifier` guards on the
//! desktop. The refusal is an explicit error reply, never a fabricated `true`:
//! a process that cannot reach the notification center has not cancelled
//! anything.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;

/// The same type as `objc.id` — `?*anyopaque` — spelled locally, per the
/// securestore precedent: `objc_runtime.objc` is an empty struct off Darwin
/// and signatures are analysed even when a comptime guard prunes the body, so
/// naming `objc.id` here would break the Linux build. A single optional
/// pointer, never `?objc.id` — a double optional is illegal in `callconv(.c)`.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches the two lists by string in both
/// directions.
pub const A = struct {
    pub const cancel_notification = "cancelNotification";
    pub const cancel_all_notifications = "cancelAllNotifications";
};

/// Both `.result`: each Swift path resolves a callback, and both JS promises
/// are the untimed legacy kind — `.none` here would strand a caller forever,
/// not for thirty seconds.
///
/// Both `.live`. Cancelling needs no permission prompt, no completion
/// handler, no entitlement — removal of the app's own pending requests is a
/// plain synchronous call — so nothing warrants `.unavailable`.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.cancel_notification, .reply = .result },
    .{ .name = A.cancel_all_notifications, .reply = .result },
};

/// The one reply shape both actions produce: Swift's
/// `resolveCallback(callbackId, result: true)` through `.fragmentsAllowed` is
/// the bare fragment `true`. Static, so replying allocates nothing.
const true_fragment = "true";

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host. The split is
/// load-bearing for `cancelAllNotifications`: it has no payload and therefore
/// no validation step, so a test that *called* it to prove routing would — in
/// a process that does have a bundle identifier — issue a real
/// `removeAllPendingNotificationRequests` against whatever app runs the tests.
const Route = enum { cancel_one, cancel_all };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.cancel_notification)) return .cancel_one;
    if (std.mem.eql(u8, action, A.cancel_all_notifications)) return .cancel_all;
    return null;
}

pub const NotifCancelBridge = struct {
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
            .cancel_one => self.cancelNotification(data),
            .cancel_all => self.cancelAllNotifications(),
        };
    }

    /// Remove one pending notification request by identifier. Resolves the
    /// bare `true` whether or not anything matched — Swift's exact semantics.
    ///
    /// Validation runs before any Objective-C: a payload the handler must
    /// refuse is refused identically on every platform, and the host tests
    /// can pin it without a notification center in sight.
    fn cancelNotification(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const notif_id = try parseId(parsed.value);

        try requireBundleIdentifier();
        const center = try notificationCenter();
        try removePending(self.allocator, center, notif_id);

        bridge_error.sendResultToJS(self.allocator, A.cancel_notification, true_fragment);
    }

    /// Remove every pending notification request. The payload is ignored, as
    /// Swift ignores the body: the injected JS posts the action alone, and
    /// `ios_dispatch.payloadOf` hands this `"{}"` for an absent `d`. An
    /// already-empty queue still resolves `true` — idempotent, as in Swift.
    fn cancelAllNotifications(self: *Self) !void {
        try requireBundleIdentifier();
        const center = try notificationCenter();
        try removeAllPending(center);

        bridge_error.sendResultToJS(self.allocator, A.cancel_all_notifications, true_fragment);
    }
};

/// Parse `d`, distinguishing a bad payload from a failed allocation — telling
/// the page INVALID_JSON about its own good JSON sends whoever debugs it to
/// the wrong side of the bridge.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
}

/// The `id` field, or the reason it cannot be used. Pure, so the host tests
/// can pin every outcome Swift's `as? String` collapsed into a silent hang.
///
/// An empty string is *not* refused: Swift passes `""` through to a harmless
/// UN no-op and resolves `true`, and bug-compatibility with the shim is the
/// contract mid-migration (the desktop module's `MissingData`-on-empty is the
/// documented divergence, not this).
fn parseId(payload: std.json.Value) ![]const u8 {
    const object = switch (payload) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
    const id_field = object.get("id") orelse return bridge_error.BridgeError.MissingData;
    const notif_id = switch (id_field) {
        .string => |s| s,
        // Swift's `as? String` fails here and replies nothing at all. A
        // coercion would be worse: it would cancel a stringified something
        // the page never named and report success.
        else => return bridge_error.BridgeError.InvalidParameter,
    };
    try requireNulFree(notif_id);
    return notif_id;
}

/// Refuse an `id` carrying the one byte it cannot survive. `\u0000` is a
/// legal JSON escape and `std.json` decodes it to the byte, so a page can
/// reach this; `createNSString` (`stringWithUTF8String:`) would then truncate
/// and the removal would address a *different* identifier than the caller
/// gave, while the reply reported `true` for the full one.
fn requireNulFree(s: []const u8) !void {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return bridge_error.BridgeError.InvalidParameter;
}

/// Refuse to go anywhere near `UNUserNotificationCenter` in a process without
/// a bundle identifier — `currentNotificationCenter` raises
/// `NSInternalInconsistencyException` there, and an uncaught ObjC exception
/// is an uncatchable SIGABRT, not an error to map. This is the condition the
/// bare `craft` fixture binary and the host test runner actually run in.
fn requireBundleIdentifier() !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSBundle = objc.objc_getClass("NSBundle") orelse return error.ClassNotFound;
    const sel_main = objc.sel_registerName("mainBundle") orelse return error.SelectorNotFound;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return error.NoBundleIdentifier;
    const sel_ident = objc.sel_registerName("bundleIdentifier") orelse return error.SelectorNotFound;
    if (objc.msgSendId(bundle, sel_ident) == null) return error.NoBundleIdentifier;
}

/// `[UNUserNotificationCenter currentNotificationCenter]`, guarded. A null
/// class means UserNotifications.framework is not in the process — a link
/// configuration problem, named rather than crashed on.
fn notificationCenter() !Id {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const UNUserNotificationCenter = objc.objc_getClass("UNUserNotificationCenter") orelse return error.ClassNotFound;
    const sel_current = objc.sel_registerName("currentNotificationCenter") orelse return error.SelectorNotFound;
    const center = objc.msgSendId(UNUserNotificationCenter, sel_current) orelse return error.NativeCallFailed;
    return center;
}

/// `removePendingNotificationRequests(withIdentifiers:)` with a one-element
/// array, matching Swift's `[id]`. Synchronous, void, no completion handler.
fn removePending(allocator: std.mem.Allocator, center: Id, notif_id: []const u8) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    // `createNSString` can fail (allocation, missing class) *and* can hand
    // back nil — `stringWithUTF8String:` returns nil for bytes it rejects.
    // `std.json` already validated UTF-8 and the NUL check ran, so a nil here
    // should not fire, but unchecked it would be an uncatchable
    // NSInvalidArgumentException inside `arrayWithObject:`.
    const ns_id = try objc.createNSString(notif_id, allocator);
    if (ns_id == null) return error.StringCreationFailed;

    const NSArray = objc.objc_getClass("NSArray") orelse return error.ClassNotFound;
    const sel_array = objc.sel_registerName("arrayWithObject:") orelse return error.SelectorNotFound;
    const identifiers = objc.msgSendId1(NSArray, sel_array, ns_id) orelse return error.NativeCallFailed;

    const sel_remove = objc.sel_registerName("removePendingNotificationRequestsWithIdentifiers:") orelse return error.SelectorNotFound;
    objc.msgSendVoid1(center, sel_remove, identifiers);
}

/// `removeAllPendingNotificationRequests` — void, zero arguments.
fn removeAllPending(center: Id) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel_remove_all = objc.sel_registerName("removeAllPendingNotificationRequests") orelse return error.SelectorNotFound;
    objc.msgSend(center, sel_remove_all);
}

// =============================================================================
// Tests — host-only. Everything that decides what the page sees (routing,
// field names, refusal reasons, the reply fragment) is pinned as pure logic,
// and the one Objective-C path a host can reach — the bundle-identifier
// refusal — is exercised for real, because the test runner is exactly the
// bundle-less process the guard exists for. The UN removal calls themselves
// are never made from here: in a process that *did* have a bundle identifier
// they would remove that app's actual pending notifications.
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    try testing.expectEqualStrings(A.cancel_notification, capability_actions[0].name);
    try testing.expectEqualStrings(A.cancel_all_notifications, capability_actions[1].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("cancelNotification", A.cancel_notification);
    try testing.expectEqualStrings("cancelAllNotifications", A.cancel_all_notifications);
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

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = NotifCancelBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Near misses — casing is how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("cancelnotification", "{}"),
    );
    // The JS surface method names, which are not action names.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("cancel", "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("cancelAll", "{}"),
    );
    // The Swift *helper* name, which is not a dispatcher case.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("cancelLocalNotification", "{}"),
    );
    // The neighbouring notification actions this module must not claim: two
    // modules answering one action would make `ios_dispatch`'s first-match
    // routing order-dependent.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("scheduleNotification", "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("requestNotificationPermission", "{}"),
    );
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = NotifCancelBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.cancel_notification, "{not json"),
    );
}

fn expectIdError(json: []const u8, expected: anyerror) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, parseId(parsed.value));
}

test "the field name the page sends is the one that is read" {
    // `{action:'cancelNotification', id: notificationId, callbackId: id}` in
    // the injected JS; the shim reads `body["id"]`. A rename on either side of
    // the migration would make the two handlers read different payloads.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"id\":\"notif-42\",\"callbackId\":\"cb_7\"}",
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("notif-42", try parseId(parsed.value));

    // The plausible wrong names are *absences*, not aliases — a payload
    // carrying only them must read as missing, or a handler bound to the
    // wrong name would pass this suite.
    try expectIdError("{\"identifier\":\"n\"}", bridge_error.BridgeError.MissingData);
    try expectIdError("{\"notificationId\":\"n\"}", bridge_error.BridgeError.MissingData);
}

test "a missing id is refused rather than defaulted" {
    // Swift's `if let notifId = body["id"] as? String` fails here and replies
    // nothing at all — the legacy promise has no timeout, so that is a hang
    // forever. An error is the deliberate divergence; a default would be
    // worse still, cancelling an identifier the page never named.
    var bridge = NotifCancelBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.cancel_notification, "{}"),
    );
}

test "a non-string id is refused, not coerced" {
    try expectIdError("{\"id\":7}", bridge_error.BridgeError.InvalidParameter);
    try expectIdError("{\"id\":null}", bridge_error.BridgeError.InvalidParameter);
    try expectIdError("{\"id\":[\"n\"]}", bridge_error.BridgeError.InvalidParameter);
}

test "an id with an embedded NUL is refused, not truncated" {
    // `stringWithUTF8String:` stops at the first NUL, so an unchecked
    // "a\u0000b" would cancel the request named "a" while the reply reported
    // `true` for the full identifier the page sent.
    try expectIdError("{\"id\":\"a\\u0000b\"}", bridge_error.BridgeError.InvalidParameter);
}

test "an empty id is accepted, matching the Swift shim" {
    // Swift hands "" to the UN center — a harmless no-op — and resolves
    // `true`. The desktop module refuses an empty id; interchangeability with
    // the shim is the contract here, so the parser passes it through and the
    // module comment carries the divergence.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"id\":\"\"}",
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("", try parseId(parsed.value));
}

test "a payload that is not an object is bad JSON, not a missing field" {
    try expectIdError("[]", bridge_error.BridgeError.InvalidJSON);
    try expectIdError("\"notif-42\"", bridge_error.BridgeError.InvalidJSON);
}

test "the reply is the bare fragment Swift's .fragmentsAllowed produces" {
    // `resolveCallback(callbackId, result: true)` serialises to the JSON
    // fragment `true` — not `{"success":true}`, which would change what a
    // caller inspecting the resolved value sees.
    try testing.expectEqualStrings("true", true_fragment);
}

test "off Darwin the handlers refuse rather than fake success" {
    if (builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    var bridge = NotifCancelBridge.init(testing.allocator);
    defer bridge.deinit();

    // A valid payload, so the refusal is the platform's and not the parser's.
    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.cancel_notification, "{\"id\":\"n1\"}"),
    );
    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.cancel_all_notifications, "{}"),
    );
}

test "without a bundle identifier the guard fires before the center is touched" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    // The host test runner is a bare binary with no Info.plist — exactly the
    // process in which `currentNotificationCenter` would SIGABRT. The guard
    // must turn that into an error reply, and it must fire for both actions.
    // If these expectations are ever *reached* and fail, the guard has been
    // reordered behind the center call and this test will have crashed the
    // runner instead — which is still a loud answer.
    if (requireBundleIdentifier()) |_| {
        // A runner that does carry a bundle identifier (tests hosted inside
        // an app) would make the calls below real removals against that
        // app's pending notifications; proving the guard needs the bundle-less
        // environment, so skip rather than pretend.
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.NoBundleIdentifier => {
            var bridge = NotifCancelBridge.init(testing.allocator);
            defer bridge.deinit();

            try testing.expectError(
                error.NoBundleIdentifier,
                bridge.handleMessage(A.cancel_notification, "{\"id\":\"conformance-probe\"}"),
            );
            try testing.expectError(
                error.NoBundleIdentifier,
                bridge.handleMessage(A.cancel_all_notifications, "{}"),
            );
        },
        else => return err,
    }
}

test "validation outruns Objective-C on every platform" {
    // The same refusals with and without a runtime behind them: a payload the
    // handler must refuse is refused identically on Linux and macOS, which is
    // what makes the parser tests above binding for the device build too.
    var bridge = NotifCancelBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.cancel_notification, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.cancel_notification, "{\"id\":42}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.cancel_notification, "{\"id\":\"a\\u0000b\"}"),
    );
}
