const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const Id = objc.id;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The `mobile` display group: the app icon's badge, the idle timer, and the
/// two orientation actions.
///
/// These five arrived together because they are the ones whose Swift arms are
/// *reachable but not reliable*, and the difference between them is worth
/// stating up front.
///
/// `setBadge` / `clearBadge` / `setKeepAwake` are ported and live. Each ends by
/// reading the value back out of UIKit and replying with what UIKit reports, so
/// a reply here is an observation, not an assertion — the property
/// `bridge_mobile.zig` chose `getDeviceInfo` for, applied to a setter.
///
/// `lockOrientation` / `unlockOrientation` are declared `.unavailable` and
/// return an error. Swift does not lock anything: it writes `lockedOrientation`
/// that nothing reads, and `supportedInterfaceOrientations` is overridden
/// nowhere in the template, so `requestGeometryUpdate` is a one-shot nudge the
/// system re-evaluates on the next rotation. A real lock needs a root view
/// controller subclass overriding `supportedInterfaceOrientations`, and
/// `ios.zig` instantiates a stock `UIViewController`. That is a startup-path
/// change, not a bridge action, so this file says so instead of replying
/// `true` to a request it did not carry out.
///
/// ## Three divergences from Swift, all deliberate
///
/// **No config gate.** Swift's dispatcher guards `setKeepAwake` and both
/// orientation actions on `config.enableKeepAwake` / `enableOrientationLock`,
/// which default to `false`, and there is no `else` — so in a default-built app
/// today those calls reply *nothing at all* and the page's promise hangs to
/// timeout. No config is plumbed into the Zig bridge, so these serve
/// unconditionally. That is a behavior change; it is also the only one of the
/// two options that answers the caller.
///
/// **No thread hop.** Every Swift helper here wraps its UIKit work in
/// `DispatchQueue.main.async`. `ios_dispatch.handleMessage` is already called
/// from `craftDidReceiveScriptMessage`, a `WKScriptMessageHandler` callback,
/// which WebKit delivers on the main thread. The hop is redundant, and there is
/// no dispatch-block machinery in this repo to reproduce it with.
///
/// **Badge authorization, as the spec does it.** `setBadge` and `clearBadge`
/// call `requestAuthorizationWithOptions:` first and reject with
/// `PERMISSION_DENIED` when iOS says no — the spec's "Badge permission denied".
/// This used to be skipped with the note that it needed a *capturing* block,
/// which no block in the repo was. That stopped being true when
/// `bridge_mobile_auth.zig` shipped per-slot global blocks whose slot index is
/// baked in at comptime; the same shape is used here. Without it Zig set the
/// number, proved UIKit stored it, and answered `true` for a badge an
/// unauthorised app never draws — a fabricated success, and the one this file
/// was still producing after every other module had stopped.
pub const A = struct {
    pub const set_badge = "setBadge";
    pub const clear_badge = "clearBadge";
    pub const set_keep_awake = "setKeepAwake";
    pub const lock_orientation = "lockOrientation";
    pub const unlock_orientation = "unlockOrientation";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.set_badge, .reply = .result },
    .{ .name = A.clear_badge, .reply = .result },
    .{ .name = A.set_keep_awake, .reply = .result },
    .{
        .name = A.lock_orientation,
        .reply = .result,
        .status = .unavailable,
        .reason = "needs a root view controller overriding supportedInterfaceOrientations; craft's is a stock UIViewController",
    },
    .{
        .name = A.unlock_orientation,
        .reply = .result,
        .status = .unavailable,
        .reason = "nothing to unlock: no orientation lock is ever installed",
    },
};

pub const DisplayBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.set_badge)) {
            try self.setBadge(data);
        } else if (std.mem.eql(u8, action, A.clear_badge)) {
            try self.clearBadge();
        } else if (std.mem.eql(u8, action, A.set_keep_awake)) {
            try self.setKeepAwake(data);
        } else if (std.mem.eql(u8, action, A.lock_orientation)) {
            try self.lockOrientation(data);
        } else if (std.mem.eql(u8, action, A.unlock_orientation)) {
            try self.unlockOrientation();
        } else {
            return bridge_error.BridgeError.UnknownAction;
        }
    }

    /// `{"count":N}` in, bare `true` out — what the spec resolves.
    ///
    /// This answered `{"count":<observed>}` until now, to work around
    /// `craft-bridge.js` settling with `payload || {}`: a falsy scalar reached
    /// the page as `{}` and carried nothing. That is fixed at its source
    /// (`_orEmpty`), so the wrapper is gone and pages reading `=== true` work
    /// again.
    ///
    /// The observed count goes to the log rather than the page. It was the one
    /// thing the object shape bought, and the spec never offered it — a page
    /// that wants the badge back has no API for it in either implementation,
    /// so inventing one here would be a second divergence rather than a fix.
    fn setBadge(self: *Self, data: []const u8) !void {
        const requested = try badgeCountFrom(self.allocator, data);
        try requestBadgeAuthorization(self.allocator, A.set_badge, requested);
    }

    /// The same path as `setBadge` with a fixed 0, so the two cannot drift.
    ///
    /// `clearBadge` sends no payload at all, so there is nothing to parse:
    /// `payloadOf` hands this `{}` and the count is not the caller's to choose.
    fn clearBadge(self: *Self) !void {
        try requestBadgeAuthorization(self.allocator, A.clear_badge, 0);
    }

    /// `{"enabled":<bool>}` in, the bare observed boolean out.
    ///
    /// The spec resolves the `enabled` the page sent; this resolves what UIKit
    /// reports, which is the same value whenever the write took. Bare rather
    /// than `{"enabled":…}` for the reason recorded on `replyBadge`.
    ///
    /// Swift also stores `isKeepingAwake`, which nothing in the template ever
    /// reads. It is not ported: a variable with no reader cannot be wrong, and
    /// carrying it would suggest something restores it later. Nothing does —
    /// `idleTimerDisabled` is per-application state UIKit drops when the app
    /// backgrounds or relaunches, and neither implementation reinstates it.
    fn setKeepAwake(self: *Self, data: []const u8) !void {
        const requested = try keepAwakeFrom(self.allocator, data);
        const observed = try applyKeepAwake(requested);

        bridge_error.sendResultToJS(
            self.allocator,
            A.set_keep_awake,
            if (observed) "true" else "false",
        );
    }

    /// Validates the orientation, then refuses.
    ///
    /// The validation is not ceremony. Erroring on an unrecognized name gives
    /// the caller `InvalidParameter` and erroring on a good one gives
    /// `PlatformNotSupported`, which is the difference between "you asked for
    /// something that does not exist" and "craft cannot do this at all". Swift
    /// conflates them: its `default:` arm turns any unknown string into `.all`
    /// and then reports success.
    ///
    /// `PlatformNotSupported` matters beyond the message. `ios_dispatch.route`
    /// passes only `UnknownAction` to the host shim, so returning a real error
    /// here stops the Swift arm from being asked to try the same thing — which
    /// is right, because what it would do is either nothing observable or, when
    /// `connectedScenes` is empty (the fixture has no scene manifest and uses
    /// the legacy `UIApplicationMain` lifecycle), its `guard ... else { return }`
    /// sits above `resolveCallback` and the promise hangs.
    fn lockOrientation(self: *Self, data: []const u8) !void {
        _ = try requestedOrientation(self.allocator, data);
        return bridge_error.BridgeError.PlatformNotSupported;
    }

    /// Refuses, with nothing to validate: the page sends no payload.
    fn unlockOrientation(self: *Self) !void {
        _ = self;
        return bridge_error.BridgeError.PlatformNotSupported;
    }
};

// =============================================================================
// Reply bodies
// =============================================================================

/// The reply shapes, in one place so the handlers and the tests cannot disagree.
///
/// Split out because a test that re-typed the format string would pass no
/// matter what the handler sent — it would be asserting that `std.fmt` works.
/// These are the strings the page actually receives.
/// What `setBadge` and `clearBadge` resolve. A bare `true`, matching the spec.
const badge_applied = "true";

// =============================================================================
// Badge authorization: ask, then set, then answer — on the threads the spec
// uses for each.
// =============================================================================

/// `UNAuthorizationOptionBadge`. `UNUserNotificationCenter.h:23` in the
/// iPhoneSimulator 26.5 SDK: `UNAuthorizationOptionBadge = (1 << 0)`. Pinned
/// by a test that cites the same line, after a neighbouring module once
/// guessed a `1 << 2` that named a different option entirely.
const un_authorization_option_badge: c_ulong = 1 << 0;

/// Ask iOS for badge authorization, and set the badge only once it says yes.
///
/// The spec's order exactly: `requestAuthorization(options: .badge)`, then
/// `applicationIconBadgeNumber = count` inside `DispatchQueue.main.async` on
/// grant, or reject on refusal. The count is validated *before* anything is
/// asked, so a malformed call fails as it always did without ever triggering
/// the first-run prompt.
///
/// When UserNotifications is not in the process — the `zig-slice` fixture
/// links only UIKit, WebKit and Foundation — there is nothing to ask, and the
/// badge is set directly as before, with a warning saying so. That path cannot
/// be reached by a generated app: `project.yml` links UserNotifications
/// unconditionally.
fn requestBadgeAuthorization(allocator: std.mem.Allocator, action: []const u8, count: i64) !void {
    if (!is_darwin) return error.UnsupportedPlatform;
    _ = std.math.cast(c_long, count) orelse return bridge_error.BridgeError.InvalidParameter;

    const UNCenterClass = objc.objc_getClass("UNUserNotificationCenter") orelse {
        std.log.warn(
            "{s}: UserNotifications is not in this process, so authorization cannot be " ++
                "requested; setting the badge directly, which an unauthorised app will not draw",
            .{action},
        );
        const observed = try applyBadge(count);
        std.log.info("{s}: badge is now {d}", .{ action, observed });
        bridge_error.sendResultToJS(allocator, action, badge_applied);
        return;
    };

    // `currentNotificationCenter` RAISES — not nil — in a process with no
    // bundle identifier, which is every test runner. Same guard as
    // `bridge_mobile_permissions.zig` and `bridge_mobile_notifcancel.zig`.
    try requireBundleIdentifier();

    const sel_current = objc.sel_registerName("currentNotificationCenter") orelse
        return error.SelectorNotFound;
    const center = objc.msgSendId(UNCenterClass, sel_current) orelse return error.NoNotificationCenter;
    const sel = objc.sel_registerName("requestAuthorizationWithOptions:completionHandler:") orelse
        return error.SelectorNotFound;

    const ticket = ios_async.acquire(action) orelse return poolFull(action);
    errdefer ios_async.abandon(ticket);
    publishPendingCall(ticket, action, count);

    const Fn = *const fn (Id, objc.SEL, c_ulong, *anyopaque) callconv(.c) void;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    func(center, sel, un_authorization_option_badge, replyBlock(ticket));
}

fn requireBundleIdentifier() !void {
    const NSBundle = objc.objc_getClass("NSBundle") orelse return error.ClassNotFound;
    const sel_main = objc.sel_registerName("mainBundle") orelse return error.SelectorNotFound;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return error.NoBundleIdentifier;
    const sel_ident = objc.sel_registerName("bundleIdentifier") orelse return error.SelectorNotFound;
    if (objc.msgSendId(bundle, sel_ident) == null) return error.NoBundleIdentifier;
}

fn poolFull(action: []const u8) bridge_error.BridgeError {
    std.log.warn("{s} refused: all {d} async slots in flight", .{ action, ios_async.max_in_flight });
    return bridge_error.BridgeError.InvalidParameter;
}

/// What a slot's block will answer. The ticket is stored, not rebuilt from the
/// index: a ticket carries a generation, and inventing one at reply time would
/// defeat the check that stops a late completion answering the slot's next
/// occupant. `action` is one of the two static names in `A`, never allocated.
const PendingBadge = struct {
    ticket: ios_async.Ticket,
    action: []const u8,
    count: i64,
};

var pending_badges: [ios_async.max_in_flight]?PendingBadge = @splat(null);
var pending_mutex: compat_mutex.Mutex = .{};

fn publishPendingCall(ticket: ios_async.Ticket, action: []const u8, count: i64) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_badges[ticket.index] = .{ .ticket = ticket, .action = action, .count = count };
}

/// Read and clear. Clearing is what makes a second fire a no-op instead of a
/// second reply.
fn takePendingCall(index: u5) ?PendingBadge {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const call = pending_badges[index];
    pending_badges[index] = null;
    return call;
}

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// `void (^)(BOOL, NSError *)` — `requestAuthorizationWithOptions:`'s
/// completion. Not `ios_async.boolErrorBlock`: that one answers the page
/// `"granted"`/`"denied"`, and this one has a badge to set in between.
const ReplyBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// 1 << 28. A global block is never copied, so it can be handed to an API that
/// escapes it with no heap copy and no descriptor lifetime.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;
const reply_block_descriptor = BlockDescriptor{ .size = @sizeOf(ReplyBlock) };

extern var _NSConcreteGlobalBlock: anyopaque;

fn makeReplyInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const ReplyBlock, granted: bool, err: Id) callconv(.c) void {
            authorizationFired(index, granted, err);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeReplyBlocks() [ios_async.max_in_flight]ReplyBlock {
    var out: [ios_async.max_in_flight]ReplyBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = makeReplyInvoke(@intCast(i)),
            .descriptor = &reply_block_descriptor,
        };
    }
    return out;
}

var reply_blocks: [ios_async.max_in_flight]ReplyBlock =
    if (is_darwin) makeReplyBlocks() else undefined;

fn replyBlock(ticket: ios_async.Ticket) *anyopaque {
    return @ptrCast(&reply_blocks[ticket.index]);
}

extern "c" fn dispatch_async_f(
    queue: *anyopaque,
    context: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;
extern var _dispatch_main_q: anyopaque;

/// Runs on whatever queue UserNotifications chose.
///
/// A refusal is answered from here — `ios_async` hops to the main queue
/// itself. A grant is not: the badge has to be *set* on the main thread
/// before the answer is true, which is what Swift's `DispatchQueue.main.async`
/// is for in this position. So the grant path hops first and answers after.
/// The pending entry survives the hop and is taken on the far side, which is
/// what makes a double fire harmless: the second hop finds nothing.
fn authorizationFired(index: u5, granted: bool, err: Id) void {
    if (!is_darwin) return;

    if (!granted) {
        const call = takePendingCall(index) orelse {
            std.log.warn("badge authorization fired for slot {d} with no call recorded; ignored", .{index});
            return;
        };
        _ = err;
        std.log.info("{s}: badge authorization denied", .{call.action});
        ios_async.deliverErrorCode(call.ticket, bridge_error.BridgeError.PermissionDenied);
        return;
    }

    // `index + 1`, never a null context: `ios_async` passes its slot the same
    // way and for the same reason.
    dispatch_async_f(&_dispatch_main_q, @ptrFromInt(@as(usize, index) + 1), applyBadgeOnMain);
}

/// Main thread. Authorized, so set the badge and say so.
fn applyBadgeOnMain(context: ?*anyopaque) callconv(.c) void {
    if (!is_darwin) return;
    const index: u5 = @intCast(@intFromPtr(context) - 1);
    const call = takePendingCall(index) orelse {
        std.log.warn("badge grant reached the main queue for slot {d} with no call recorded; ignored", .{index});
        return;
    };

    const observed = applyBadge(call.count) catch |e| {
        std.log.warn("{s}: authorised, but the badge could not be set: {s}", .{ call.action, @errorName(e) });
        ios_async.deliverErrorCode(call.ticket, bridge_error.BridgeError.NativeCallFailed);
        return;
    };
    std.log.info("{s}: badge is now {d}", .{ call.action, observed });
    ios_async.deliverJson(call.ticket, badge_applied);
}

// =============================================================================
// Payload parsing
// =============================================================================

/// The `count` the page sent, or an error naming why it could not be used.
///
/// Never defaults. A missing `count` is `MissingData`, not 0, because 0 is
/// `clearBadge` — a dropped field would quietly perform a *different action*
/// than the one asked for. That is the `bridge_app.zig` badge bug exactly: the
/// desktop accepted only `{badge:"..."}` while every caller sent `{count:N}`,
/// and the dock tile never updated while the call reported success.
///
/// Swift's `body["count"] as? Int` returns nil for a fractional number and its
/// dispatcher has no `else`, so `setBadge(3.7)` today replies nothing and hangs
/// the promise. Here a whole `3.0` is accepted — JSON has one number type and a
/// page that computed its count with arithmetic legitimately produces it — and
/// anything else is refused out loud.
fn badgeCountFrom(allocator: std.mem.Allocator, data: []const u8) !i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return bridge_error.BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    const count: i64 = switch (root.get("count") orelse return bridge_error.BridgeError.MissingData) {
        .integer => |n| n,
        .float => |f| blk: {
            // Beyond 2^53 an f64 no longer names one integer, so a value out
            // there is not a count anyone can have meant.
            if (f != @trunc(f) or f < 0 or f > 9007199254740991.0)
                return bridge_error.BridgeError.InvalidParameter;
            break :blk @intFromFloat(f);
        },
        // `std.json` emits `.number_string` for integers too large for i64.
        else => return bridge_error.BridgeError.InvalidParameter,
    };

    // UIKit's behavior for a negative badge is undefined, and the page's own
    // type says `number`, not "any number".
    if (count < 0) return bridge_error.BridgeError.InvalidParameter;
    return count;
}

/// The `enabled` the page sent.
///
/// Booleans only — no truthiness coercion. `setKeepAwake(1)` is a caller bug
/// worth reporting, and guessing what a non-boolean meant is how a handler ends
/// up doing the opposite of what was asked.
fn keepAwakeFrom(allocator: std.mem.Allocator, data: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return bridge_error.BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    return switch (root.get("enabled") orelse return bridge_error.BridgeError.MissingData) {
        .bool => |b| b,
        else => return bridge_error.BridgeError.InvalidParameter,
    };
}

/// The orientations Swift's switch recognizes.
///
/// Five, not the two `packages/typescript/types/craft.d.ts:528` publishes —
/// the TS surface and the Swift switch already disagree, and the wire is what a
/// page can actually reach.
pub const Orientation = enum {
    portrait,
    portrait_upside_down,
    landscape_left,
    landscape_right,
    landscape,

    pub fn fromName(name: []const u8) ?Orientation {
        const table = .{
            .{ "portrait", Orientation.portrait },
            .{ "portraitUpsideDown", Orientation.portrait_upside_down },
            .{ "landscapeLeft", Orientation.landscape_left },
            .{ "landscapeRight", Orientation.landscape_right },
            .{ "landscape", Orientation.landscape },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    /// `UIInterfaceOrientationMask`, which is `1 << UIInterfaceOrientation`.
    ///
    /// Spelled out because craft imports no UIKit headers, and kept even though
    /// nothing sends it yet: it is the table the eventual implementation needs,
    /// and the two easy ways to get it wrong — `landscapeLeft` is 4 and
    /// `landscapeRight` is 3, so their masks are 16 and 8, the reverse of the
    /// order they read in — are pinned by a test below rather than left to be
    /// rediscovered.
    pub fn mask(self: Orientation) c_ulong {
        return switch (self) {
            .portrait => 2,
            .portrait_upside_down => 4,
            .landscape_right => 8,
            .landscape_left => 16,
            .landscape => 24,
        };
    }
};

fn requestedOrientation(allocator: std.mem.Allocator, data: []const u8) !Orientation {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return bridge_error.BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    const name = switch (root.get("orientation") orelse return bridge_error.BridgeError.MissingData) {
        .string => |s| s,
        else => return bridge_error.BridgeError.InvalidParameter,
    };

    return Orientation.fromName(name) orelse bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// UIKit
// =============================================================================

/// Set the icon badge, then report what UIKit says it is.
///
/// Two setters, on purpose. `setBadgeCount:withCompletionHandler:` (iOS 16+) is
/// the supported route and is sent whenever `UNUserNotificationCenter` is in
/// the process; `setApplicationIconBadgeNumber:` is deprecated as of iOS 17 but
/// still present and, unlike the modern one, is synchronous — which is why it
/// is the one whose effect can be read back on the next line. Both are handed
/// the same number, so the asynchronous one landing later changes nothing.
///
/// The read-back is the point. Without it this function would be asserting that
/// the badge is set; with it, the reply carries a number that came back out of
/// UIKit. It still does not prove the badge is *visible* — that needs the
/// authorization Swift requests and this does not (see the note on `A`).
///
/// If the deprecated pair ever disappears, this returns an error rather than an
/// unverified success. Fixing that properly means a capturing block for the
/// modern setter's completion handler, which is new machinery and should be a
/// decision, not a side effect.
fn applyBadge(count: i64) !i64 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const wanted = std.math.cast(c_long, count) orelse return bridge_error.BridgeError.InvalidParameter;

    const UIApplicationClass = objc.objc_getClass("UIApplication") orelse return error.ClassNotFound;
    const sel_shared = objc.sel_registerName("sharedApplication") orelse return error.SelectorNotFound;
    const app = objc.msgSendId(UIApplicationClass, sel_shared);
    if (app == null) return error.NoSharedApplication;

    const modern_sent = setBadgeThroughNotificationCenter(wanted);

    const can_set = responds(app, "setApplicationIconBadgeNumber:");
    if (!can_set and !modern_sent) return error.BadgeApiUnavailable;

    if (can_set) {
        const sel_set = objc.sel_registerName("setApplicationIconBadgeNumber:") orelse
            return error.SelectorNotFound;
        const SetFn = *const fn (objc.id, objc.SEL, c_long) callconv(.c) void;
        const set: SetFn = @ptrCast(&objc.objc_msgSend);
        set(app, sel_set, wanted);
    }

    if (!responds(app, "applicationIconBadgeNumber")) return error.BadgeNotVerifiable;

    const sel_get = objc.sel_registerName("applicationIconBadgeNumber") orelse
        return error.SelectorNotFound;
    const GetFn = *const fn (objc.id, objc.SEL) callconv(.c) c_long;
    const get: GetFn = @ptrCast(&objc.objc_msgSend);

    const observed = get(app, sel_get);
    if (observed != wanted) return error.BadgeNotApplied;
    return @intCast(observed);
}

/// Send `setBadgeCount:withCompletionHandler:`. False means it was not sent.
///
/// `objc_getClass` returning null here is a real and expected condition, not a
/// failure: `packages/ios/fixtures/zig-slice/build-and-run.sh` links only
/// UIKit, WebKit and Foundation, so on that fixture UserNotifications is not in
/// the process at all. The caller decides what to do about it — this returns
/// what happened rather than swallowing it.
///
/// The completion handler is `nullable` in the header, so nil is legal and no
/// block is needed. Note that `requestAuthorizationWithOptions:`, which Swift
/// also calls, is *not* nullable there — passing nil to that one crashes, which
/// is part of why authorization is not attempted here.
fn setBadgeThroughNotificationCenter(count: c_long) bool {
    const UNCenterClass = objc.objc_getClass("UNUserNotificationCenter") orelse return false;
    const sel_current = objc.sel_registerName("currentNotificationCenter") orelse return false;
    const center = objc.msgSendId(UNCenterClass, sel_current);
    if (center == null) return false;

    if (!responds(center, "setBadgeCount:withCompletionHandler:")) return false;

    const sel_set = objc.sel_registerName("setBadgeCount:withCompletionHandler:") orelse return false;
    const Fn = *const fn (objc.id, objc.SEL, c_long, ?*anyopaque) callconv(.c) void;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    func(center, sel_set, count, null);
    return true;
}

/// Disable or re-enable the idle timer, then report what UIKit says it is.
///
/// The getter is `isIdleTimerDisabled`, not `idleTimerDisabled`: the property
/// declares `getter=isIdleTimerDisabled`. A wrong selector is not a compile
/// error — it reaches `doesNotRecognizeSelector:` at runtime — so it is worth
/// the line to say why this one looks asymmetric with its setter.
fn applyKeepAwake(enabled: bool) !bool {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const UIApplicationClass = objc.objc_getClass("UIApplication") orelse return error.ClassNotFound;
    const sel_shared = objc.sel_registerName("sharedApplication") orelse return error.SelectorNotFound;
    const app = objc.msgSendId(UIApplicationClass, sel_shared);
    if (app == null) return error.NoSharedApplication;

    const sel_set = objc.sel_registerName("setIdleTimerDisabled:") orelse return error.SelectorNotFound;
    const SetFn = *const fn (objc.id, objc.SEL, bool) callconv(.c) void;
    const set: SetFn = @ptrCast(&objc.objc_msgSend);
    set(app, sel_set, enabled);

    const sel_get = objc.sel_registerName("isIdleTimerDisabled") orelse return error.SelectorNotFound;
    const GetFn = *const fn (objc.id, objc.SEL) callconv(.c) bool;
    const get: GetFn = @ptrCast(&objc.objc_msgSend);

    const observed = get(app, sel_get);
    if (observed != enabled) return error.KeepAwakeNotApplied;
    return observed;
}

/// `-[NSObject respondsToSelector:]`.
///
/// The version gate craft uses everywhere instead of parsing an OS version —
/// `macos.zig:582` records why: the question is always whether *this* selector
/// exists, and asking that directly cannot drift from what the SDK did.
/// `objc_runtime.zig` has no one-argument BOOL sender, hence the local type.
fn responds(target: objc.id, selector_name: [:0]const u8) bool {
    const sel_responds = objc.sel_registerName("respondsToSelector:") orelse return false;
    const selector = objc.sel_registerName(selector_name) orelse return false;
    const Fn = *const fn (objc.id, objc.SEL, objc.SEL) callconv(.c) bool;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(target, sel_responds, selector);
}

const testing = std.testing;

test "the declared table and the dispatcher serve the same actions" {
    // A table and a dispatch chain that disagree is the failure the whole
    // capabilities mechanism exists to make impossible, and it is cheapest to
    // catch here rather than from a page whose promise never settles.
    try testing.expectEqual(@as(usize, 5), capability_actions.len);

    const payloads = [_][]const u8{
        "{\"count\":3}",
        "{}",
        "{\"enabled\":true}",
        "{\"orientation\":\"portrait\"}",
        "{}",
    };
    try testing.expectEqual(capability_actions.len, payloads.len);

    var bridge = DisplayBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions, payloads) |decl, data| {
        // The host has no UIKit, so the live actions fail here. What matters is
        // that they fail *having been dispatched*: `UnknownAction` is the one
        // answer that means the arm is missing.
        if (bridge.handleMessage(decl.name, data)) |_| {} else |err| {
            try testing.expect(err != bridge_error.BridgeError.UnknownAction);
        }
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = DisplayBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Near-misses too: a page calling `setbadge` must be told, not served.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("setbadge", "{\"count\":1}"),
    );
}

test "every unavailable row explains itself" {
    // `.unavailable` without a reason tells an app that something is broken and
    // nothing about what, which is barely better than not declaring it.
    for (capability_actions) |decl| {
        if (decl.status != .unavailable) continue;
        try testing.expect(decl.reason != null);
        try testing.expect(decl.reason.?.len > 0);
    }
}

test "a badge count is read from the field the page actually sends" {
    try testing.expectEqual(@as(i64, 5), try badgeCountFrom(testing.allocator, "{\"count\":5}"));
    try testing.expectEqual(@as(i64, 0), try badgeCountFrom(testing.allocator, "{\"count\":0}"));

    // Whole floats are that integer. JSON has one number type, and a page that
    // computed its count with arithmetic hands over `3.0`.
    try testing.expectEqual(@as(i64, 3), try badgeCountFrom(testing.allocator, "{\"count\":3.0}"));
}

test "a missing count is refused rather than defaulted to zero" {
    // The whole reason this is not `orelse 0`: zero is `clearBadge`. Defaulting
    // would turn a dropped field into a different action, performed silently
    // and reported as success.
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        badgeCountFrom(testing.allocator, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        badgeCountFrom(testing.allocator, "{\"badge\":7}"),
    );
}

test "a count that is not a count is refused, not rounded or dropped" {
    // Swift's `as? Int` returns nil for each of these and its dispatcher has no
    // `else`, so today they reply nothing at all and hang the caller.
    for ([_][]const u8{
        "{\"count\":3.7}",
        "{\"count\":\"5\"}",
        "{\"count\":true}",
        "{\"count\":null}",
        "{\"count\":-1}",
        "{\"count\":[1]}",
    }) |data| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            badgeCountFrom(testing.allocator, data),
        );
    }
}

test "a payload that is not an object is a JSON error, not a missing field" {
    // Reporting `MissingData` for `[1,2]` would send the caller looking for a
    // field in something that has no fields.
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        badgeCountFrom(testing.allocator, "[1,2]"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        badgeCountFrom(testing.allocator, "{\"count\":"),
    );
}

test "keep-awake reads a boolean and only a boolean" {
    try testing.expectEqual(true, try keepAwakeFrom(testing.allocator, "{\"enabled\":true}"));
    try testing.expectEqual(false, try keepAwakeFrom(testing.allocator, "{\"enabled\":false}"));

    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        keepAwakeFrom(testing.allocator, "{}"),
    );
    // No truthiness. Guessing what `1` meant is how a handler ends up doing the
    // opposite of what was asked.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        keepAwakeFrom(testing.allocator, "{\"enabled\":1}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        keepAwakeFrom(testing.allocator, "{\"enabled\":\"true\"}"),
    );
}

test "the orientation names are the ones the Swift switch recognizes" {
    try testing.expectEqual(Orientation.portrait, Orientation.fromName("portrait").?);
    try testing.expectEqual(Orientation.portrait_upside_down, Orientation.fromName("portraitUpsideDown").?);
    try testing.expectEqual(Orientation.landscape_left, Orientation.fromName("landscapeLeft").?);
    try testing.expectEqual(Orientation.landscape_right, Orientation.fromName("landscapeRight").?);
    try testing.expectEqual(Orientation.landscape, Orientation.fromName("landscape").?);

    // Swift's `default:` turns anything else into `.all` and reports success.
    try testing.expectEqual(@as(?Orientation, null), Orientation.fromName("sideways"));
    try testing.expectEqual(@as(?Orientation, null), Orientation.fromName("Portrait"));
}

test "the orientation masks are shifts of UIInterfaceOrientation, not their reading order" {
    // `landscapeLeft` is orientation 4 and `landscapeRight` is 3, so the masks
    // are 16 and 8 — the reverse of the order the names suggest. This is the
    // pair that gets transposed.
    try testing.expectEqual(@as(c_ulong, 2), Orientation.portrait.mask());
    try testing.expectEqual(@as(c_ulong, 4), Orientation.portrait_upside_down.mask());
    try testing.expectEqual(@as(c_ulong, 8), Orientation.landscape_right.mask());
    try testing.expectEqual(@as(c_ulong, 16), Orientation.landscape_left.mask());
    try testing.expectEqual(
        Orientation.landscape_left.mask() | Orientation.landscape_right.mask(),
        Orientation.landscape.mask(),
    );
}

test "the orientation actions refuse, and say which kind of refusal it is" {
    var bridge = DisplayBridge.init(testing.allocator);
    defer bridge.deinit();

    // A well-formed request craft cannot carry out.
    try testing.expectError(
        bridge_error.BridgeError.PlatformNotSupported,
        bridge.handleMessage(A.lock_orientation, "{\"orientation\":\"landscape\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.PlatformNotSupported,
        bridge.handleMessage(A.unlock_orientation, "{}"),
    );

    // A malformed one. Distinct on purpose: the caller can fix this one.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.lock_orientation, "{\"orientation\":\"sideways\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.lock_orientation, "{}"),
    );
}

test "replies are the bare scalars the spec resolves" {
    // These were objects — `{"count":N}` and `{"enabled":<bool>}` — to work
    // around `craft-bridge.js` settling with `payload || {}`, which turned a
    // bare `false` into a truthy `{}`. That is fixed at its source, so the
    // wrapper is gone and the shapes match the spec again: a page doing
    // `(await craft.setKeepAwake(false)) === false` gets `false`, and one doing
    // `(await craft.clearBadge()) === true` gets `true`.
    //
    // Pinned as the literal bytes the handlers send, so re-wrapping either
    // reply fails here rather than reading as coverage.
    try testing.expectEqualStrings("true", badge_applied);

    // Parsed, not just compared, so a literal that is not valid JSON — `True`,
    // or a stray quote — cannot pass.
    for ([_][]const u8{ badge_applied, "true", "false" }) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .bool);
    }
}

test "UIKit work is refused off Darwin rather than attempted" {
    if (builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    try testing.expectError(error.UnsupportedPlatform, applyBadge(1));
    try testing.expectError(error.UnsupportedPlatform, applyKeepAwake(true));
}

test "the badge authorization option is the header's bit, not a guess" {
    // `UNUserNotificationCenter.h:23`: `UNAuthorizationOptionBadge = (1 << 0)`.
    // A neighbouring module once pinned a guessed `1 << 2` for a HealthKit
    // option and shipped a crash; this cites the line instead.
    try testing.expectEqual(@as(c_ulong, 1), un_authorization_option_badge);
    try testing.expect(un_authorization_option_badge != 1 << 1); // Sound
    try testing.expect(un_authorization_option_badge != 1 << 2); // Alert
}

test "each badge slot's reply block is global and has its own invoke" {
    if (!is_darwin) return error.SkipZigTest;
    for (&reply_blocks) |*b| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, b.isa);
        try testing.expectEqual(BLOCK_IS_GLOBAL, b.flags);
        try testing.expectEqual(@sizeOf(ReplyBlock), @as(usize, @intCast(b.descriptor.size)));
    }
    try testing.expect(reply_blocks[0].invoke != reply_blocks[1].invoke);
}

test "a pending badge call is taken exactly once" {
    // The property a double-fired completion relies on: the second `take`
    // finds nothing, so it replies to nobody instead of answering twice.
    const ticket = ios_async.Ticket{ .index = 3, .generation = 42 };
    publishPendingCall(ticket, A.set_badge, 7);
    const first = takePendingCall(3) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 7), first.count);
    try testing.expectEqualStrings(A.set_badge, first.action);
    try testing.expectEqual(@as(u32, 42), first.ticket.generation);
    try testing.expect(takePendingCall(3) == null);
}

test "a bad count is refused before any authorization is requested" {
    // Ordering, not just parsing: the parse failure has to come first, on
    // every platform, so a malformed call never triggers the first-run prompt.
    var bridge = DisplayBridge.init(testing.allocator);
    defer bridge.deinit();
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.set_badge, "{\"count\":\"three\"}"),
    );
}

test "setBadge is refused on the host rather than resolved without asking" {
    // There is no UIKit and no bundle identifier in a test binary, so the
    // only correct outcome is a refusal. Which refusal depends on what the
    // host has loaded — UserNotifications absent takes one path, present
    // takes another — so this pins the shape (an error, never a reply) and
    // not the name. A resolve here would be the exact fabricated success this
    // change exists to remove.
    var bridge = DisplayBridge.init(testing.allocator);
    defer bridge.deinit();
    if (bridge.handleMessage(A.set_badge, "{\"count\":3}")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    if (bridge.handleMessage(A.clear_badge, "{}")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}
