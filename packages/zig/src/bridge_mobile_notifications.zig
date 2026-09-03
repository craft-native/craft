//! The local-notification *read* action of the `mobile` namespace:
//! `getPendingNotifications`.
//!
//! One JS surface reaches it: the legacy `craft.notifications.getPending()`,
//! which posts `{action:'getPendingNotifications', callbackId: id}` and hands
//! back a promise built by hand rather than through `_createCallback` — so it
//! has **no timeout**. A dropped reply parks the page forever, which is why
//! every path below ends in a reply, an error, or a loudly logged refusal.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **No payload.** The injected JS posts the action alone and the Swift
//!    dispatcher reads nothing out of `body`. `ios_dispatch.payloadOf` hands
//!    this handler `"{}"` for an absent `d`; it is ignored rather than parsed,
//!    exactly as `cancelAllNotifications` ignores its own. A page that sends
//!    junk in `d` still gets the pending list, because that is what Swift does.
//!  - **The reply is a bare JSON array**, not a wrapper object. Swift builds
//!    `[[String: Any]]` and resolves it through `JSONSerialization` with
//!    `.fragmentsAllowed`, so the resolved value is
//!    `[{"id":…,"title":…,"body":…,"subtitle":…}, …]`, and `[]` when nothing
//!    is scheduled. `test-bridges.html` does `JSON.stringify(pending, null, 2)`
//!    straight onto the resolved value; any wrapper would change what it prints.
//!  - **Four keys per entry, `subtitle` included.** `craft.d.ts`'s
//!    `PendingNotification` is `{id, title, body}` and omits `subtitle`, but
//!    Swift emits it and Swift is the contract the migration has to preserve;
//!    the `.d.ts` is behind. All four are non-nullable `NSString`s that default
//!    to `""`, so every entry always carries every key. Swift's dictionary
//!    ordering is arbitrary — this module fixes the order at id, title, body,
//!    subtitle so the bytes on the wire are testable.
//!  - **The trigger is not in the reply.** Swift never reads
//!    `request.trigger`, so there is no "when does it fire" field to match and
//!    none is invented here.
//!  - **No authorization prompt.** Swift's read path calls
//!    `getPendingNotificationRequests` directly; asking for permission on a
//!    read would put a system alert in front of a user who only listed
//!    something.
//!
//! ## What is deliberately not carried across
//!
//! **Swift's silent hang.** The dispatcher arm is
//! `if config.enableLocalNotifications { … }` with no `else`, and the gate
//! defaults to `false` — so with notifications disabled the untimed promise
//! never settles. `enableLocalNotifications` has no mirror anywhere in
//! `packages/zig/src`, so this action is served unconditionally, the same call
//! `bridge_mobile_securestore.zig` and `bridge_mobile_notifcancel.zig` made.
//! Listing an app's *own* pending notifications grants a page strictly less
//! than the cancel-everything that precedent already serves ungated.
//!
//! **A truncated string reported as the whole one.** `-[NSString UTF8String]`
//! is NUL-terminated, so a stored title carrying an embedded U+0000 — which
//! Swift's `JSONSerialization` would round-trip intact — reads back short.
//! Unreachable from craft's own scheduler, reachable from an app that
//! schedules notifications in native code. Rather than report the truncation
//! as the full title, the byte length is checked against
//! `lengthOfBytesUsingEncoding:` and a mismatch fails the whole reply.
//!
//! ## The bundle-identifier guard, first and non-negotiable
//!
//! `[UNUserNotificationCenter currentNotificationCenter]` raises
//! `NSInternalInconsistencyException` in a process with no bundle identifier,
//! and an uncaught Objective-C exception is an uncatchable SIGABRT rather than
//! an error to map. That is exactly the process the bare `craft` fixture binary
//! and this file's own test runner are, so `requireBundleIdentifier` runs
//! before anything touches the center — the same guard
//! `bridge_mobile_notifcancel.zig` documents.
//!
//! ## `scheduleNotification` is deliberately absent from `A`
//!
//! It is not declared `.unavailable` — it is not claimed at all, so
//! `ios_dispatch` falls through to the Swift shim, which schedules
//! notifications correctly today whenever the gate is on. `.unavailable` would
//! *steal* a working action in order to refuse it, which is strictly worse for
//! the page than leaving it where it works.
//!
//! The reason it cannot be served honestly yet is a missing piece of
//! `ios_async`, not a missing selector:
//!
//!  1. **Both Swift failure paths are rejections**, not results:
//!     `rejectCallback(callbackId, error: "Permission denied")` when
//!     authorization is refused, and `rejectCallback(callbackId, error:
//!     error.localizedDescription)` when `addNotificationRequest:` fails.
//!     `ios_async` can only *resolve* — `deliverJson` is the whole asynchronous
//!     reply surface. Resolving the string "denied" for a denied prompt would
//!     be textbook fabricated success: the page's `catch` never runs and its
//!     `lastNotificationId` becomes the word "denied", which it then feeds
//!     straight into `cancelNotification`. `craft_ios_deliver_error` is not the
//!     way out; it is an export for the Swift shim and calls `evalJS` inline,
//!     so calling it from a UserNotifications completion queue would run
//!     `evaluateJavaScript:` off the main thread. The fix is an
//!     `ios_async.deliverError(ticket, code, message)` sharing `deliverJson`'s
//!     slot, `dispatch_async_f` hop, and request-id restoration; hand-rolling a
//!     second main-queue hop in a bridge module is the bug that file exists to
//!     prevent.
//!  2. **It is a two-stage chain over an autoreleased object.**
//!     `requestWithIdentifier:content:trigger:` is autoreleased, and the pool
//!     it lives in drains long before the authorization completion fires, so
//!     the request has to be retained and stashed per slot alongside a
//!     pre-escaped reply fragment for the identifier — the same side table this
//!     file already keeps for the read path, one field wider.
//!  3. Two decisions would have to be recorded rather than inherited: Swift
//!     passes `delay / 1000` to `UNTimeIntervalNotificationTrigger`
//!     unguarded, and an interval of zero or less raises an uncatchable ObjC
//!     exception, so `{delay: 0}` SIGABRTs the app today
//!     (`bridge_notification.zig` documents the same trap and answers it with
//!     a nil trigger, which is how UserNotifications spells "now"); and the
//!     page's fields arrive nested under `notification`, with `scheduleAt`,
//!     `sound`, and `data` present in the TypeScript surface and dropped on the
//!     floor by Swift.
//!
//! None of that is guesswork — it is a second file's worth of change to
//! `ios_async`, which this pass is not making. Until it is made, the shim keeps
//! the action.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const compat_mutex = @import("compat_mutex.zig");
const memory = @import("memory.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The same type as `objc.id` — `?*anyopaque` — spelled locally, per the
/// notifcancel/securestore precedent: `objc_runtime.objc` is an empty struct
/// off Darwin and a signature is analysed even when a comptime guard prunes the
/// body, so naming `objc.id` here would break the Linux build. A single
/// optional pointer, never `?objc.id` — a double optional is illegal in
/// `callconv(.c)`.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches this block against those labels in
/// both directions.
///
/// What it does *not* do is check that two modules never claim the same
/// action, though `ios_dispatch` says it does: `collectZigActions` folds every
/// module's block into one `StringHashMap`, so a duplicate is invisible there
/// and `ios_dispatch`'s first-match routing would quietly become
/// order-dependent. Until that check exists the tests below stand in for it,
/// pinning the near neighbours — `cancelNotification`,
/// `cancelAllNotifications`, `scheduleNotification` — as actions this module
/// does not answer.
///
/// Only the read action is here. See the module comment for why
/// scheduleNotification is left to the shim rather than claimed and refused.
pub const A = struct {
    pub const get_pending_notifications = "getPendingNotifications";
    pub const schedule_notification = "scheduleNotification";
};

/// `.result`: Swift resolves the callback with the array, and the JS promise is
/// the untimed legacy kind — `.none` would strand a caller forever rather than
/// for thirty seconds.
///
/// `.live`: the read needs no permission prompt, no entitlement, and no
/// configuration beyond a bundle identifier. Nothing here warrants
/// `.unavailable`.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.get_pending_notifications, .reply = .result },
    // `.result`: the spec resolves the identifier string, and the page's
    // promise is the untimed legacy kind. `.live`, because the reason this was
    // absent is gone — see the module comment.
    .{ .name = A.schedule_notification, .reply = .result },
};

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host without issuing the
/// Objective-C call the handler exists to make.
const Route = enum { get_pending, schedule };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.get_pending_notifications)) return .get_pending;
    if (std.mem.eql(u8, action, A.schedule_notification)) return .schedule;
    return null;
}

pub const NotificationsBridge = struct {
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
            .get_pending => self.getPendingNotifications(data),
            .schedule => self.scheduleNotification(data),
        };
    }

    /// List the app's pending notification requests.
    ///
    /// `data` is accepted and ignored: the injected JS posts no payload and the
    /// Swift dispatcher reads none, so parsing one here would invent a way for
    /// this call to fail that the shim does not have.
    ///
    /// Every fallible step — the bundle guard, the center, all nine selectors —
    /// runs *before* `ios_async.acquire`, so there is no error path between
    /// leasing a slot and handing the block to the framework. That ordering is
    /// the whole reason this reads as one straight line: a failure after the
    /// lease would have to release the slot by hand, and a missed release is a
    /// permanently narrower pool.
    fn getPendingNotifications(self: *Self, data: []const u8) !void {
        _ = self;
        _ = data;
        if (!is_darwin) return error.UnsupportedPlatform;

        try requireBundleIdentifier();
        const center = try notificationCenter();
        const sel_get = objc.sel_registerName("getPendingNotificationRequestsWithCompletionHandler:") orelse
            return error.SelectorNotFound;
        const sels = try Sels.resolve();

        const ticket = ios_async.acquire(A.get_pending_notifications) orelse return poolFull();

        // Published before the framework call, never after: the completion runs
        // on a queue UserNotifications picks and can fire before `msgSend`
        // returns. A block that arrived at an empty side-table slot would have
        // no ticket to reply with.
        publishPendingCall(ticket, sels);

        // The completion is `void (^)(NSArray<UNNotificationRequest *> *)`,
        // which neither `boolBlock` nor `boolErrorBlock` fits — hence this
        // module's own per-slot global block, feeding `ios_async.deliverJson`.
        const Fn = *const fn (Id, Id, *anyopaque) callconv(.c) void;
        const func: Fn = @ptrCast(&objc.objc_msgSend);
        func(center, sel_get, arrayBlock(ticket));
    }

    /// Schedule one local notification, and answer with its identifier.
    ///
    /// Two stages, exactly as the spec has them: ask for authorization, and
    /// only on a grant build the request and add it. The content and the
    /// request are built *inside* the authorization completion, which is where
    /// the spec builds them — so the autoreleased request never has to survive
    /// a completion boundary, and nothing needs retaining. What does survive is
    /// the identifier, which the second stage answers with; it is owned heap
    /// memory parked on the slot.
    ///
    /// Every fallible step runs before `ios_async.acquire`, per this file's
    /// existing rule: no error path may sit between leasing a slot and handing
    /// a block to the framework, because a failure there would have to release
    /// the slot by hand and a missed release narrows the pool permanently.
    fn scheduleNotification(self: *Self, data: []const u8) !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        try requireBundleIdentifier();
        const center = try notificationCenter();
        const sels = try ScheduleSels.resolve();
        const sel_request = objc.sel_registerName("requestAuthorizationWithOptions:completionHandler:") orelse
            return error.SelectorNotFound;

        var schedule = try parseSchedule(self.allocator, data);
        errdefer schedule.deinit(self.allocator);

        const ticket = ios_async.acquire(A.schedule_notification) orelse return poolFull();

        publishScheduleCall(ticket, sels, schedule);

        const Fn = *const fn (Id, Id, c_ulong, *anyopaque) callconv(.c) void;
        const func: Fn = @ptrCast(&objc.objc_msgSend);
        func(center, sel_request, un_options_alert_sound_badge, boolErrorBlock(ticket));
    }
};

/// The answer for a full block pool, copied from `bridge_mobile_permissions`:
/// `BridgeError` has no "Busy", INVALID_PARAMETER is the migration notes'
/// designated stand-in, and the point is that the seventeenth concurrent call
/// gets an explicit rejection instead of a promise that never settles.
fn poolFull() bridge_error.BridgeError {
    std.log.warn(
        "getPendingNotifications refused: all {d} async slots in flight",
        .{ios_async.max_in_flight},
    );
    return bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// Reply shaping. Pure — no Objective-C — so the exact bytes the page receives
// are pinned by host tests on every platform.
// =============================================================================

/// The array Swift's `requests.map { … }` produces, assembled incrementally so
/// the Objective-C walk can feed it one request at a time without first
/// materialising every string.
///
/// Key order is fixed at id, title, body, subtitle. Swift's is a `Dictionary`
/// and therefore arbitrary; a caller cannot depend on it, but a *test* can only
/// pin bytes that are deterministic, so one order is chosen and held.
const PendingList = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    written: usize = 0,

    fn init(allocator: std.mem.Allocator) PendingList {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *PendingList) void {
        self.out.deinit(self.allocator);
    }

    fn append(
        self: *PendingList,
        notif_id: []const u8,
        title: []const u8,
        body: []const u8,
        subtitle: []const u8,
    ) !void {
        try self.out.append(self.allocator, if (self.written == 0) '[' else ',');
        try self.out.appendSlice(self.allocator, "{\"id\":");
        try self.appendString(notif_id);
        try self.out.appendSlice(self.allocator, ",\"title\":");
        try self.appendString(title);
        try self.out.appendSlice(self.allocator, ",\"body\":");
        try self.appendString(body);
        try self.out.appendSlice(self.allocator, ",\"subtitle\":");
        try self.appendString(subtitle);
        try self.out.append(self.allocator, '}');
        self.written += 1;
    }

    /// Every one of these four values is app-controlled text that ends up
    /// replayed into the source `evaluateJavaScript:` parses, so it goes
    /// through the shared escaper rather than `{s}` — a `"` in a notification
    /// title would otherwise break the page's promise resolution.
    fn appendString(self: *PendingList, s: []const u8) !void {
        try self.out.append(self.allocator, '"');
        try bridge_error.appendJsonEscaped(self.allocator, &self.out, s);
        try self.out.append(self.allocator, '"');
    }

    /// The finished fragment. An empty queue is `[]` — a real answer that
    /// resolves, not an error and not `null`.
    fn finish(self: *PendingList) ![]u8 {
        if (self.written == 0) try self.out.append(self.allocator, '[');
        try self.out.append(self.allocator, ']');
        return self.out.toOwnedSlice(self.allocator);
    }
};

// =============================================================================
// Objective-C: selectors resolved up front, then a walk that cannot look
// anything up.
// =============================================================================

/// `NSUTF8StringEncoding`. Used only to ask a string how long it really is, so
/// a NUL-truncated read can be told from a short string.
const ns_utf8_string_encoding: c_ulong = 4;

fn selector(name: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.sel_registerName(name) orelse error.SelectorNotFound;
}

/// Every selector the completion block needs, resolved while a synchronous
/// error is still deliverable.
///
/// The block runs after the dispatch frame is gone; a `sel_registerName`
/// failure in there could only be logged and dropped, because `ios_async` has
/// no error channel. Resolving them here turns that class of failure into an
/// ordinary rejection the page can see.
const Sels = struct {
    count: Id,
    object_at: Id,
    identifier: Id,
    content: Id,
    title: Id,
    body: Id,
    subtitle: Id,
    utf8: Id,
    utf8_length: Id,

    fn resolve() !Sels {
        if (!is_darwin) return error.UnsupportedPlatform;
        return .{
            .count = try selector("count"),
            .object_at = try selector("objectAtIndex:"),
            .identifier = try selector("identifier"),
            .content = try selector("content"),
            .title = try selector("title"),
            .body = try selector("body"),
            .subtitle = try selector("subtitle"),
            .utf8 = try selector("UTF8String"),
            .utf8_length = try selector("lengthOfBytesUsingEncoding:"),
        };
    }
};

/// Refuse to go anywhere near `UNUserNotificationCenter` in a process without a
/// bundle identifier: `currentNotificationCenter` raises
/// `NSInternalInconsistencyException` there, and an uncaught Objective-C
/// exception is an uncatchable SIGABRT, not an error to map.
fn requireBundleIdentifier() !void {
    if (!is_darwin) return error.UnsupportedPlatform;

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
    if (!is_darwin) return error.UnsupportedPlatform;

    const UNUserNotificationCenter = objc.objc_getClass("UNUserNotificationCenter") orelse
        return error.ClassNotFound;
    const sel_current = objc.sel_registerName("currentNotificationCenter") orelse
        return error.SelectorNotFound;
    return objc.msgSendId(UNUserNotificationCenter, sel_current) orelse error.NativeCallFailed;
}

/// One `NSString` as bytes, or a refusal.
///
/// The truncation check is the reason this is not one line. `UTF8String` hands
/// back a NUL-terminated buffer, so a title containing U+0000 — legal in a
/// notification, and preserved by the `JSONSerialization` this reply is
/// bug-compatible with — reads back as its prefix.
/// `lengthOfBytesUsingEncoding:` counts the real encoded bytes, so a mismatch
/// is exactly that case, and reporting the prefix as the whole title is the
/// one thing worse than failing.
///
/// The returned slice borrows the string's internal buffer, which is valid for
/// the current autorelease pool; every caller copies it into the reply before
/// returning.
fn readString(ns: Id, sels: Sels) ![]const u8 {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (ns == null) return error.NativeCallFailed;

    const Utf8Fn = *const fn (Id, Id) callconv(.c) ?[*:0]const u8;
    const utf8: Utf8Fn = @ptrCast(&objc.objc_msgSend);
    const cstr = utf8(ns, sels.utf8) orelse return error.NativeCallFailed;
    const text = std.mem.span(cstr);

    const LenFn = *const fn (Id, Id, c_ulong) callconv(.c) c_ulong;
    const len_of: LenFn = @ptrCast(&objc.objc_msgSend);
    const encoded = len_of(ns, sels.utf8_length, ns_utf8_string_encoding);
    if (encoded != text.len) return error.EmbeddedNulInNativeString;

    return text;
}

/// Walk `NSArray<UNNotificationRequest *>` into the reply fragment.
///
/// A nil array is refused rather than answered `[]`: the completion parameter
/// is declared non-nullable, so nil would mean the framework broke its own
/// contract, and "no pending notifications" is a claim this module would have
/// no basis for.
fn shapePendingReply(allocator: std.mem.Allocator, requests: Id, sels: Sels) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (requests == null) return error.NativeCallFailed;

    const CountFn = *const fn (Id, Id) callconv(.c) c_ulong;
    const count_of: CountFn = @ptrCast(&objc.objc_msgSend);
    const total = count_of(requests, sels.count);

    var list = PendingList.init(allocator);
    defer list.deinit();

    var i: c_ulong = 0;
    while (i < total) : (i += 1) {
        const request = objc.msgSendId1(requests, sels.object_at, i) orelse return error.NativeCallFailed;
        const content = objc.msgSendId(request, sels.content) orelse return error.NativeCallFailed;

        try list.append(
            try readString(objc.msgSendId(request, sels.identifier), sels),
            try readString(objc.msgSendId(content, sels.title), sels),
            try readString(objc.msgSendId(content, sels.body), sels),
            try readString(objc.msgSendId(content, sels.subtitle), sels),
        );
    }

    return list.finish();
}

// =============================================================================
// The per-slot completion block, and the side table that gives it a ticket.
//
// A global block captures nothing, which is what makes `Block_copy` on it the
// identity function and removes every lifetime question. The price is that the
// block knows only its own slot index, baked in at comptime — so the ticket's
// generation, and the selectors resolved at dispatch time, are looked up here.
// =============================================================================

const PendingCall = struct {
    ticket: ios_async.Ticket,
    sels: Sels,
};

var pending_calls: [ios_async.max_in_flight]?PendingCall = @splat(null);
var pending_mutex: compat_mutex.Mutex = .{};

/// Record the call a slot's block will answer. The slot is leased exclusively
/// by this ticket, so the entry is ours to overwrite.
fn publishPendingCall(ticket: ios_async.Ticket, sels: Sels) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls[ticket.index] = .{ .ticket = ticket, .sels = sels };
}

/// Read and clear a slot's entry. Clearing is what makes a second fire of the
/// same completion a no-op rather than a second reply.
fn takePendingCall(index: u5) ?PendingCall {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const call = pending_calls[index];
    pending_calls[index] = null;
    return call;
}

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// `void (^)(NSArray<UNNotificationRequest *> *)` — one object argument and no
/// BOOL, which is why `ios_async`'s pre-built blocks do not fit.
const ArrayBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// 1 << 28. `Block_copy` on a global block returns the same pointer, so a
/// module-level block can be handed to an API that escapes it with no heap
/// copy, no copy/dispose helpers, and no descriptor lifetime.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

const array_block_descriptor = BlockDescriptor{ .size = @sizeOf(ArrayBlock) };

extern var _NSConcreteGlobalBlock: anyopaque;

/// One invoke per slot, comptime-generated so each block knows which slot it is
/// without capturing anything.
fn makeArrayInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const ArrayBlock, requests: Id) callconv(.c) void {
            pendingCompletionFired(index, requests);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeArrayBlocks() [ios_async.max_in_flight]ArrayBlock {
    var out: [ios_async.max_in_flight]ArrayBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = makeArrayInvoke(@intCast(i)),
            .descriptor = &array_block_descriptor,
        };
    }
    return out;
}

var array_blocks: [ios_async.max_in_flight]ArrayBlock =
    if (is_darwin) makeArrayBlocks() else undefined;

fn arrayBlock(ticket: ios_async.Ticket) *anyopaque {
    return @ptrCast(&array_blocks[ticket.index]);
}

/// Runs on whatever queue UserNotifications chose. It must not reply from here
/// — `evaluateJavaScript:` is main-thread-only — so the finished JSON goes to
/// `ios_async.deliverJson`, which copies it, hops to the main queue, and
/// answers under the request id captured back at dispatch.
///
/// The one path that cannot answer is a reply that will not shape: out of
/// memory, a nil array, or a NUL-truncated string. That is answered with
/// `ios_async.deliverError`, which reports NATIVE_CALL_FAILED through this same
/// slot and hop — so the caller learns the call failed instead of waiting out a
/// promise nothing will settle.
fn pendingCompletionFired(index: u5, requests: Id) void {
    if (!is_darwin) return;

    const call = takePendingCall(index) orelse {
        std.log.warn(
            "getPendingNotifications completion fired for slot {d} with no call recorded; ignored",
            .{index},
        );
        return;
    };

    const allocator = std.heap.c_allocator;
    const json = shapePendingReply(allocator, requests, call.sels) catch |err| {
        // Rejects rather than going silent. This abandoned the slot and left
        // the caller's untimed promise hanging, on the reasoning that
        // `ios_async` could resolve and nothing else, so the choice was
        // between a fabricated result and silence. That stopped being true one
        // day after it was written: `deliverError` reports NATIVE_CALL_FAILED
        // through the same slot, the same `dispatch_async_f` hop to the main
        // queue, and the same restored request id. Silence was the lesser
        // wrong only while it was the only alternative to a lie.
        std.log.err(
            "getPendingNotifications could not shape its reply ({}); rejecting",
            .{err},
        );
        ios_async.deliverError(call.ticket);
        return;
    };
    defer allocator.free(json);

    ios_async.deliverJson(call.ticket, json);
}

// =============================================================================
// scheduleNotification: parsing, selectors, and the two-stage completion chain.
// =============================================================================

/// `UNAuthorizationOptionAlert | Sound | Badge` = `(1<<2)|(1<<1)|(1<<0)`.
/// `UNUserNotificationCenter.h:23-25`. Same value
/// `bridge_mobile_permissions.zig` resolved independently, which is the
/// cross-check that it is not a guess.
const un_options_alert_sound_badge: c_ulong = 7;

/// `NSCalendarUnitYear|Month|Day|Hour|Minute|Second`, the set the spec asks
/// `Calendar.current.dateComponents` for. `NSCalendar.h:61-66` defines each as
/// the matching `kCFCalendarUnit*`, and `CFCalendar.h:68-73` gives the bits:
/// year `1<<2` through second `1<<7`, so the union is 252.
const calendar_units_ymdhms: c_ulong = (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7);

/// When the notification fires.
///
/// `.now` is the spec's nil trigger — UserNotifications reads that as "deliver
/// immediately". It is also where a non-positive `delay` lands, and that is a
/// deliberate divergence: the spec passes `delay / 1000` to
/// `UNTimeIntervalNotificationTrigger` unguarded, and an interval of zero or
/// less raises an uncatchable Objective-C exception, so `{delay: 0}` SIGABRTs
/// the app today. `bridge_notification.zig` documents the same trap and answers
/// it the same way. Crashing the process is not a behaviour worth reproducing.
const Trigger = union(enum) {
    now,
    /// Seconds, always > 0.
    interval: f64,
    /// Seconds since the epoch.
    calendar: f64,
};

/// The parsed `notification` object, owning its strings.
const Schedule = struct {
    /// `null` means the page sent none and the spec's `UUID().uuidString`
    /// applies. Generated in the Objective-C path so this stays pure.
    id: ?[]u8,
    title: []u8,
    body: []u8,
    subtitle: ?[]u8,
    badge: ?i64,
    trigger: Trigger,

    fn deinit(self: *Schedule, allocator: std.mem.Allocator) void {
        if (self.id) |v| allocator.free(v);
        allocator.free(self.title);
        allocator.free(self.body);
        if (self.subtitle) |v| allocator.free(v);
        self.* = undefined;
    }
};

/// Read the page's `notification` object.
///
/// Follows the spec's coercions rather than tightening them: a non-string
/// `title` or `body` becomes `""` because `as? String ?? ""` does, and a
/// non-numeric `badge` is dropped because `as? Int` yields nil. The one place
/// this refuses where the spec does not is a missing `notification` object —
/// the spec's `case` has no `else`, so that call never reaches a
/// `resolveCallback` and the page's promise hangs forever. A rejection is the
/// only honest answer available.
fn parseSchedule(allocator: std.mem.Allocator, data: []const u8) !Schedule {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return bridge_error.BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
    const notification = switch (root.get("notification") orelse
        return bridge_error.BridgeError.MissingData) {
        .object => |o| o,
        else => return bridge_error.BridgeError.MissingData,
    };

    // `as? String ?? ""`, field by field.
    const title = try allocator.dupe(u8, stringOr(notification.get("title"), ""));
    errdefer allocator.free(title);
    const body = try allocator.dupe(u8, stringOr(notification.get("body"), ""));
    errdefer allocator.free(body);

    const subtitle: ?[]u8 = if (notification.get("subtitle")) |v| switch (v) {
        .string => |str| try allocator.dupe(u8, str),
        else => null,
    } else null;
    errdefer if (subtitle) |v| allocator.free(v);

    const id: ?[]u8 = if (notification.get("id")) |v| switch (v) {
        .string => |str| try allocator.dupe(u8, str),
        else => null,
    } else null;
    errdefer if (id) |v| allocator.free(v);

    return .{
        .id = id,
        .title = title,
        .body = body,
        .subtitle = subtitle,
        .badge = numberOr(notification.get("badge")),
        .trigger = triggerFrom(notification),
    };
}

fn stringOr(value: ?std.json.Value, fallback: []const u8) []const u8 {
    const v = value orelse return fallback;
    return switch (v) {
        .string => |s| s,
        else => fallback,
    };
}

/// `as? Int`: a JSON integer, or a float that is exactly one. Anything else is
/// nil, and the badge is left unset.
fn numberOr(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (f == @trunc(f) and f >= -9.2e18 and f <= 9.2e18) @intFromFloat(f) else null,
        else => null,
    };
}

/// `timestamp` wins over `delay`, as it does in the spec's if/else-if.
fn triggerFrom(notification: std.json.ObjectMap) Trigger {
    if (millisFrom(notification.get("timestamp"))) |ms| return .{ .calendar = ms / 1000.0 };
    if (millisFrom(notification.get("delay"))) |ms| {
        const seconds = ms / 1000.0;
        // See `Trigger`: the spec crashes here, this delivers now.
        return if (seconds > 0) .{ .interval = seconds } else .now;
    }
    return .now;
}

fn millisFrom(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// Selectors for the schedule path, all resolved before a slot is leased.
const ScheduleSels = struct {
    ns_string: Id,
    number_with_ll: Id,
    content_alloc_init: Id,
    set_title: Id,
    set_body: Id,
    set_subtitle: Id,
    set_badge: Id,
    set_sound: Id,
    default_sound: Id,
    trigger_interval: Id,
    trigger_calendar: Id,
    current_calendar: Id,
    components_from: Id,
    date_with_since1970: Id,
    request_with: Id,
    add_request: Id,
    uuid_string: Id,

    fn resolve() !ScheduleSels {
        if (!is_darwin) return error.UnsupportedPlatform;
        return .{
            .ns_string = try selector("stringWithUTF8String:"),
            .number_with_ll = try selector("numberWithLongLong:"),
            .content_alloc_init = try selector("init"),
            .set_title = try selector("setTitle:"),
            .set_body = try selector("setBody:"),
            .set_subtitle = try selector("setSubtitle:"),
            .set_badge = try selector("setBadge:"),
            .set_sound = try selector("setSound:"),
            .default_sound = try selector("defaultSound"),
            .trigger_interval = try selector("triggerWithTimeInterval:repeats:"),
            .trigger_calendar = try selector("triggerWithDateMatchingComponents:repeats:"),
            .current_calendar = try selector("currentCalendar"),
            .components_from = try selector("components:fromDate:"),
            .date_with_since1970 = try selector("dateWithTimeIntervalSince1970:"),
            .request_with = try selector("requestWithIdentifier:content:trigger:"),
            .add_request = try selector("addNotificationRequest:withCompletionHandler:"),
            .uuid_string = try selector("UUIDString"),
        };
    }
};

const ScheduleCall = struct {
    ticket: ios_async.Ticket,
    sels: ScheduleSels,
    schedule: Schedule,
};

var schedule_calls: [ios_async.max_in_flight]?ScheduleCall = @splat(null);

fn publishScheduleCall(ticket: ios_async.Ticket, sels: ScheduleSels, schedule: Schedule) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    schedule_calls[ticket.index] = .{ .ticket = ticket, .sels = sels, .schedule = schedule };
}

fn takeScheduleCall(index: u5) ?ScheduleCall {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const call = schedule_calls[index];
    schedule_calls[index] = null;
    return call;
}

/// `void (^)(BOOL, NSError *)` — the authorization completion.
const BoolErrorBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// `void (^)(NSError *)` — `addNotificationRequest:`'s completion.
const ErrorBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

const bool_error_block_descriptor = BlockDescriptor{ .size = @sizeOf(BoolErrorBlock) };
const error_block_descriptor = BlockDescriptor{ .size = @sizeOf(ErrorBlock) };

fn makeBoolErrorInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const BoolErrorBlock, granted: bool, _: Id) callconv(.c) void {
            authorizationFired(index, granted);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeBoolErrorBlocks() [ios_async.max_in_flight]BoolErrorBlock {
    var out: [ios_async.max_in_flight]BoolErrorBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = makeBoolErrorInvoke(@intCast(i)),
            .descriptor = &bool_error_block_descriptor,
        };
    }
    return out;
}

fn makeErrorInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const ErrorBlock, err: Id) callconv(.c) void {
            addFired(index, err);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeErrorBlocks() [ios_async.max_in_flight]ErrorBlock {
    var out: [ios_async.max_in_flight]ErrorBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = makeErrorInvoke(@intCast(i)),
            .descriptor = &error_block_descriptor,
        };
    }
    return out;
}

var bool_error_blocks: [ios_async.max_in_flight]BoolErrorBlock =
    if (is_darwin) makeBoolErrorBlocks() else undefined;
var error_blocks: [ios_async.max_in_flight]ErrorBlock =
    if (is_darwin) makeErrorBlocks() else undefined;

fn boolErrorBlock(ticket: ios_async.Ticket) *anyopaque {
    return @ptrCast(&bool_error_blocks[ticket.index]);
}

fn errorBlock(ticket: ios_async.Ticket) *anyopaque {
    return @ptrCast(&error_blocks[ticket.index]);
}

/// Stage one, on whatever queue UserNotifications chose.
///
/// A refusal answers `PERMISSION_DENIED`, where the spec rejects with the
/// string "Permission denied" — the typed code every other migrated module
/// uses, carrying the same meaning in a form a page can branch on.
fn authorizationFired(index: u5, granted: bool) void {
    if (!is_darwin) return;

    var call = takeScheduleCall(index) orelse {
        std.log.warn(
            "scheduleNotification authorization fired for slot {d} with no call recorded; ignored",
            .{index},
        );
        return;
    };
    const allocator = std.heap.c_allocator;

    if (!granted) {
        call.schedule.deinit(allocator);
        ios_async.deliverErrorCode(call.ticket, bridge_error.BridgeError.PermissionDenied);
        return;
    }

    const request = buildRequest(&call.schedule, call.sels) catch |err| {
        std.log.err("scheduleNotification could not build its request ({}); rejecting", .{err});
        call.schedule.deinit(allocator);
        ios_async.deliverError(call.ticket);
        return;
    };

    const center = notificationCenter() catch {
        call.schedule.deinit(allocator);
        ios_async.deliverError(call.ticket);
        return;
    };

    // Republished before the add, for the reason the first publish exists: the
    // completion can fire before `msgSend` returns.
    publishScheduleCall(call.ticket, call.sels, call.schedule);

    const Fn = *const fn (Id, Id, Id, *anyopaque) callconv(.c) void;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    func(center, call.sels.add_request, request, errorBlock(call.ticket));
}

/// Stage two. Answers the identifier the request was filed under, which is what
/// the page needs to cancel it later.
fn addFired(index: u5, err: Id) void {
    if (!is_darwin) return;

    var call = takeScheduleCall(index) orelse {
        std.log.warn(
            "scheduleNotification add fired for slot {d} with no call recorded; ignored",
            .{index},
        );
        return;
    };
    const allocator = std.heap.c_allocator;
    defer call.schedule.deinit(allocator);

    if (err != null) {
        std.log.warn("scheduleNotification: addNotificationRequest reported an error", .{});
        ios_async.deliverErrorCode(call.ticket, bridge_error.BridgeError.NativeCallFailed);
        return;
    }

    const id = call.schedule.id orelse {
        // `buildRequest` fills this in from `NSUUID` before the add, so a null
        // here means the request was filed under an identifier nothing kept.
        // Answering anyway would hand the page a value it cannot cancel with.
        std.log.err("scheduleNotification: the request was added with no identifier recorded", .{});
        ios_async.deliverError(call.ticket);
        return;
    };

    // A bare JSON string, which is what the spec resolves. Escaped, because a
    // page-supplied identifier can contain a quote.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    out.append(allocator, '"') catch return ios_async.deliverError(call.ticket);
    bridge_error.appendJsonEscaped(allocator, &out, id) catch
        return ios_async.deliverError(call.ticket);
    out.append(allocator, '"') catch return ios_async.deliverError(call.ticket);

    ios_async.deliverJson(call.ticket, out.items);
}

/// Build `UNNotificationRequest` from the parsed schedule.
///
/// Runs inside the authorization completion, where the spec builds it, so the
/// autoreleased result is handed straight to `addNotificationRequest:` without
/// crossing a pool boundary.
///
/// Fills `schedule.id` when the page sent none, using `NSUUID` exactly as the
/// spec's `UUID().uuidString` does — so the identifier answered to the page is
/// the identifier the request was actually filed under.
fn buildRequest(schedule: *Schedule, sels: ScheduleSels) !Id {
    const allocator = std.heap.c_allocator;

    const UNMutableNotificationContent = objc.objc_getClass("UNMutableNotificationContent") orelse
        return error.ClassNotFound;
    const sel_alloc = objc.sel_registerName("alloc") orelse return error.SelectorNotFound;
    const content = objc.msgSendId(objc.msgSendId(UNMutableNotificationContent, sel_alloc), sels.content_alloc_init);
    if (content == null) return error.NoContent;

    try setStringField(content, sels.set_title, schedule.title, sels);
    try setStringField(content, sels.set_body, schedule.body, sels);
    if (schedule.subtitle) |sub| try setStringField(content, sels.set_subtitle, sub, sels);

    if (schedule.badge) |badge| {
        const NSNumber = objc.objc_getClass("NSNumber") orelse return error.ClassNotFound;
        const NumFn = *const fn (Id, Id, c_longlong) callconv(.c) Id;
        const num: NumFn = @ptrCast(&objc.objc_msgSend);
        const boxed = num(NSNumber, sels.number_with_ll, @intCast(badge));
        objc.msgSendVoid1(content, sels.set_badge, boxed);
    }

    // `content.sound = .default`, unconditional in the spec.
    const UNNotificationSound = objc.objc_getClass("UNNotificationSound") orelse
        return error.ClassNotFound;
    objc.msgSendVoid1(content, sels.set_sound, objc.msgSendId(UNNotificationSound, sels.default_sound));

    const trigger = try buildTrigger(schedule.trigger, sels);

    if (schedule.id == null) schedule.id = try uuidString(allocator, sels);
    const ns_id = try nsString(schedule.id.?, sels);

    const UNNotificationRequest = objc.objc_getClass("UNNotificationRequest") orelse
        return error.ClassNotFound;
    const ReqFn = *const fn (Id, Id, Id, Id, Id) callconv(.c) Id;
    const req: ReqFn = @ptrCast(&objc.objc_msgSend);
    const request = req(UNNotificationRequest, sels.request_with, ns_id, content, trigger);
    if (request == null) return error.NoRequest;
    return request;
}

/// A nil trigger is legal and means "deliver now" — see `Trigger`.
fn buildTrigger(trigger: Trigger, sels: ScheduleSels) !Id {
    switch (trigger) {
        .now => return null,
        .interval => |seconds| {
            const UNTimeIntervalNotificationTrigger =
                objc.objc_getClass("UNTimeIntervalNotificationTrigger") orelse return error.ClassNotFound;
            const Fn = *const fn (Id, Id, f64, bool) callconv(.c) Id;
            const func: Fn = @ptrCast(&objc.objc_msgSend);
            return func(UNTimeIntervalNotificationTrigger, sels.trigger_interval, seconds, false);
        },
        .calendar => |epoch_seconds| {
            const NSDate = objc.objc_getClass("NSDate") orelse return error.ClassNotFound;
            const DateFn = *const fn (Id, Id, f64) callconv(.c) Id;
            const date_fn: DateFn = @ptrCast(&objc.objc_msgSend);
            const date = date_fn(NSDate, sels.date_with_since1970, epoch_seconds);

            const NSCalendar = objc.objc_getClass("NSCalendar") orelse return error.ClassNotFound;
            const calendar = objc.msgSendId(NSCalendar, sels.current_calendar);
            const CompFn = *const fn (Id, Id, c_ulong, Id) callconv(.c) Id;
            const comp_fn: CompFn = @ptrCast(&objc.objc_msgSend);
            const components = comp_fn(calendar, sels.components_from, calendar_units_ymdhms, date);

            const UNCalendarNotificationTrigger =
                objc.objc_getClass("UNCalendarNotificationTrigger") orelse return error.ClassNotFound;
            const TrigFn = *const fn (Id, Id, Id, bool) callconv(.c) Id;
            const trig_fn: TrigFn = @ptrCast(&objc.objc_msgSend);
            return trig_fn(UNCalendarNotificationTrigger, sels.trigger_calendar, components, false);
        },
    }
}

fn nsString(text: []const u8, sels: ScheduleSels) !Id {
    const allocator = std.heap.c_allocator;
    // `memory.dupeZ`, not `allocator.dupeZ`: 0.17 dropped the method in some
    // dev builds, which is the churn that helper exists to absorb.
    const c_text = try memory.dupeZ(allocator, u8, text);
    defer allocator.free(c_text);

    const NSString = objc.objc_getClass("NSString") orelse return error.ClassNotFound;
    const Fn = *const fn (Id, Id, [*:0]const u8) callconv(.c) Id;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    const ns = func(NSString, sels.ns_string, c_text.ptr);
    if (ns == null) return error.NoString;
    return ns;
}

fn setStringField(content: Id, sel: Id, text: []const u8, sels: ScheduleSels) !void {
    objc.msgSendVoid1(content, sel, try nsString(text, sels));
}

fn uuidString(allocator: std.mem.Allocator, sels: ScheduleSels) ![]u8 {
    const NSUUID = objc.objc_getClass("NSUUID") orelse return error.ClassNotFound;
    const sel_uuid = objc.sel_registerName("UUID") orelse return error.SelectorNotFound;
    const uuid = objc.msgSendId(NSUUID, sel_uuid);
    if (uuid == null) return error.NoUUID;
    const ns = objc.msgSendId(uuid, sels.uuid_string);
    if (ns == null) return error.NoUUID;
    const utf8 = objc.getNSStringUTF8(ns) orelse return error.NoUUID;
    return allocator.dupe(u8, std.mem.span(utf8));
}

// =============================================================================
// Tests — host-only.
//
// Everything that decides what the page sees is pinned as pure logic: routing,
// the action name, the reply bytes, the escaping, the empty case. The one
// Objective-C path a host can reach — the bundle-identifier refusal — is
// exercised for real, because the test runner is exactly the bundle-less
// process the guard exists for. The `getPendingNotificationRequests` call
// itself is never made from here; in a process that *did* have a bundle
// identifier it would query that app's real notification center.
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    try testing.expectEqualStrings(A.get_pending_notifications, capability_actions[0].name);
    try testing.expectEqualStrings(A.schedule_notification, capability_actions[1].name);
    try testing.expectEqual(capabilities.Reply.result, capability_actions[1].reply);
    try testing.expectEqual(capabilities.ActionStatus.live, capability_actions[1].status);

    // A `.result` whose handler never replies parks the caller on an untimed
    // promise; a `.none` that is awaited resolves immediately and means
    // nothing. Both failure modes are invisible from the page, so the field is
    // asserted rather than assumed.
    try testing.expectEqual(capabilities.Reply.result, capability_actions[0].reply);
    try testing.expectEqual(capabilities.ActionStatus.live, capability_actions[0].status);
    // `.live` and a reason together would be a contradiction the manifest shows
    // to apps.
    try testing.expect(capability_actions[0].reason == null);
}

test "the action name matches the Swift case label exactly" {
    // The conformance ratchet compares this against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("getPendingNotifications", A.get_pending_notifications);
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

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = NotificationsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Casing is how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("getpendingnotifications", "{}"),
    );
    // The JS surface method name, which is not an action name.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("getPending", "{}"),
    );
    // The Swift *helper* name, which is not a dispatcher case either — it is
    // spelled the same as the action and would route if the module matched on
    // helpers, but `getPendingNotifications` is genuinely both, so the near
    // miss checked here is the plural-less form.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("getPendingNotification", "{}"),
    );
    // The neighbouring cancel actions belong to `bridge_mobile_notifcancel`;
    // two modules answering one action would make `ios_dispatch`'s first-match
    // routing order-dependent.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("cancelNotification", "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("cancelAllNotifications", "{}"),
    );
}

test "scheduleNotification is claimed now, and routes" {
    // This asserted the opposite until the blocker went away. The module
    // comment said `ios_async` could only resolve, so an action whose two
    // failure paths are both rejections could not be served honestly and was
    // left to the shim. `deliverErrorCode` landed the day after that was
    // written; both refusals have a home now, and the action is served.
    var bridge = NotificationsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expect(routeFor(A.schedule_notification) == .schedule);

    var declared = false;
    for (capability_actions) |decl| {
        if (std.mem.eql(u8, decl.name, A.schedule_notification)) declared = true;
    }
    try testing.expect(declared);

    // On the host there is no bundle identifier, so it refuses before touching
    // the notification center — which is the guard, not a missing migration.
    try testing.expectError(
        error.NoBundleIdentifier,
        bridge.handleMessage(A.schedule_notification, "{\"notification\":{\"title\":\"t\"}}"),
    );
}

test "the payload is read the way the spec reads it" {
    const allocator = testing.allocator;

    // `as? String ?? ""` for title and body; a non-string is not an error.
    var plain = try parseSchedule(allocator, "{\"notification\":{\"title\":7,\"body\":\"b\"}}");
    defer plain.deinit(allocator);
    try testing.expectEqualStrings("", plain.title);
    try testing.expectEqualStrings("b", plain.body);
    try testing.expect(plain.subtitle == null);
    try testing.expect(plain.badge == null);
    try testing.expect(plain.id == null);
    try testing.expect(plain.trigger == .now);

    // `timestamp` wins over `delay`, as the spec's if/else-if does.
    var both = try parseSchedule(allocator, "{\"notification\":{\"timestamp\":2000,\"delay\":9000}}");
    defer both.deinit(allocator);
    try testing.expectEqual(@as(f64, 2.0), both.trigger.calendar);

    var delayed = try parseSchedule(allocator, "{\"notification\":{\"delay\":1500}}");
    defer delayed.deinit(allocator);
    try testing.expectEqual(@as(f64, 1.5), delayed.trigger.interval);

    // A missing `notification` hangs the page in the spec — its `case` has no
    // `else` and never reaches a callback. Rejecting is the only honest answer.
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        parseSchedule(allocator, "{}"),
    );
}

test "a non-positive delay delivers now instead of raising" {
    // The spec passes `delay / 1000` to `UNTimeIntervalNotificationTrigger`
    // unguarded, and an interval of zero or less raises an uncatchable ObjC
    // exception — so `{delay: 0}` SIGABRTs the app today. A nil trigger is how
    // UserNotifications spells "now"; `bridge_notification.zig` answers the
    // same trap the same way.
    const allocator = testing.allocator;
    for ([_][]const u8{
        "{\"notification\":{\"delay\":0}}",
        "{\"notification\":{\"delay\":-1}}",
        "{\"notification\":{\"delay\":-0.5}}",
    }) |payload| {
        var s2 = try parseSchedule(allocator, payload);
        defer s2.deinit(allocator);
        try testing.expect(s2.trigger == .now);
    }
}

test "the calendar unit mask is the header's, not a guess" {
    // `NSCalendar.h:61-66` defines each unit as the matching `kCFCalendarUnit*`,
    // and `CFCalendar.h:68-73` gives year `1<<2` through second `1<<7`. A
    // sibling module once shipped a guessed HealthKit bit that named a
    // different option and crashed, so this cites its source.
    try testing.expectEqual(@as(c_ulong, 252), calendar_units_ymdhms);
    try testing.expect(calendar_units_ymdhms & (1 << 1) == 0); // era, not asked for
    try testing.expectEqual(@as(c_ulong, 7), un_options_alert_sound_badge);
}

test "each schedule slot has its own block, and a call is taken once" {
    if (!is_darwin) return error.SkipZigTest;
    for (&bool_error_blocks) |*b| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, b.isa);
        try testing.expectEqual(BLOCK_IS_GLOBAL, b.flags);
    }
    try testing.expect(bool_error_blocks[0].invoke != bool_error_blocks[1].invoke);
    try testing.expect(error_blocks[0].invoke != error_blocks[1].invoke);

    // Take-and-clear is what makes a double-fired completion a no-op rather
    // than a second reply.
    const allocator = testing.allocator;
    var schedule = try parseSchedule(allocator, "{\"notification\":{\"title\":\"t\"}}");
    defer schedule.deinit(allocator);
    publishScheduleCall(.{ .index = 2, .generation = 9 }, undefined, schedule);
    try testing.expect(takeScheduleCall(2) != null);
    try testing.expect(takeScheduleCall(2) == null);
}

test "the payload is ignored, not parsed" {
    // Swift's dispatcher reads nothing out of `body` for this action, and the
    // injected JS posts none. A payload that is not even JSON must therefore
    // reach exactly the same outcome as `{}` — if it did not, this module would
    // have invented a failure the shim does not have, and a page passing junk
    // in `d` would get INVALID_JSON where Swift gave it the pending list.
    // Three real dispatches, so this has to be a process the bundle guard
    // stops. In a runner that *does* carry a bundle identifier (tests hosted
    // inside an app) each call would issue a live
    // `getPendingNotificationRequests` and lease an async slot that no run loop
    // is here to release — narrowing the pool for everything after it, and
    // leaving side-table entries the later slot tests assert are absent.
    if (is_darwin) {
        if (requireBundleIdentifier()) |_| return error.SkipZigTest else |_| {}
    }

    var bridge = NotificationsBridge.init(testing.allocator);
    defer bridge.deinit();

    const empty = bridge.handleMessage(A.get_pending_notifications, "{}");
    const junk = bridge.handleMessage(A.get_pending_notifications, "{not json");
    const structured = bridge.handleMessage(A.get_pending_notifications, "[1,2,3]");

    // Whatever the platform answers, it answers the same three times, and it is
    // never a JSON complaint.
    try testing.expectEqual(empty, junk);
    try testing.expectEqual(empty, structured);
    if (empty) |_| {} else |err| {
        try testing.expect(err != bridge_error.BridgeError.InvalidJSON);
        try testing.expect(err != bridge_error.BridgeError.MissingData);
    }
}

test "an empty queue is the bare array, not null and not an error" {
    var list = PendingList.init(testing.allocator);
    defer list.deinit();

    const json = try list.finish();
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("[]", json);
}

test "one request is the four-key object Swift builds, in a bare array" {
    // Swift's `requests.map` produces `["id":…, "title":…, "body":…,
    // "subtitle":…]` and resolves the array itself through `.fragmentsAllowed`.
    // `test-bridges.html` stringifies the resolved value directly, so a
    // wrapper object — `{"notifications":[…]}` — would change what it prints
    // and what `craft.d.ts`'s `Promise<PendingNotification[]>` describes.
    var list = PendingList.init(testing.allocator);
    defer list.deinit();

    try list.append("notif-42", "Test Notification", "Body text", "Sub");
    const json = try list.finish();
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "[{\"id\":\"notif-42\",\"title\":\"Test Notification\",\"body\":\"Body text\",\"subtitle\":\"Sub\"}]",
        json,
    );
}

test "subtitle is emitted even though craft.d.ts omits it" {
    // `PendingNotification` in `packages/typescript/types/craft.d.ts` is
    // `{id, title, body}`. Swift emits `subtitle` regardless, and Swift is the
    // contract this migration has to preserve — dropping the key to match a
    // stale type would silently remove a field an app may already read.
    var list = PendingList.init(testing.allocator);
    defer list.deinit();

    try list.append("i", "t", "b", "");
    const json = try list.finish();
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"subtitle\":\"\"") != null);
}

test "several requests are comma-separated with no trailing comma" {
    var list = PendingList.init(testing.allocator);
    defer list.deinit();

    try list.append("a", "1", "x", "");
    try list.append("b", "2", "y", "");
    try list.append("c", "3", "z", "");
    const json = try list.finish();
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "[{\"id\":\"a\",\"title\":\"1\",\"body\":\"x\",\"subtitle\":\"\"}," ++
            "{\"id\":\"b\",\"title\":\"2\",\"body\":\"y\",\"subtitle\":\"\"}," ++
            "{\"id\":\"c\",\"title\":\"3\",\"body\":\"z\",\"subtitle\":\"\"}]",
        json,
    );

    // Cheap structural cross-check: the fragment must parse as an array of
    // three objects, which is what the page's `JSON.stringify` will do to it.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
    try testing.expectEqual(@as(usize, 4), parsed.value.array.items[0].object.count());
}

test "notification text is escaped, not interpolated" {
    // These strings are app-controlled and are replayed into the source
    // `evaluateJavaScript:` parses. An unescaped quote or backslash would break
    // the page's promise resolution outright; a raw newline is invalid JSON.
    var list = PendingList.init(testing.allocator);
    defer list.deinit();

    try list.append("id\"1", "say \"hi\"", "back\\slash", "line\nbreak\ttab");
    const json = try list.finish();
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "[{\"id\":\"id\\\"1\",\"title\":\"say \\\"hi\\\"\"," ++
            "\"body\":\"back\\\\slash\",\"subtitle\":\"line\\nbreak\\ttab\"}]",
        json,
    );

    // And it must survive a round trip with the bytes intact.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const first = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("id\"1", first.get("id").?.string);
    try testing.expectEqualStrings("say \"hi\"", first.get("title").?.string);
    try testing.expectEqualStrings("back\\slash", first.get("body").?.string);
    try testing.expectEqualStrings("line\nbreak\ttab", first.get("subtitle").?.string);
}

test "the side table hands each slot's completion its own ticket, once" {
    // The block is global and captures nothing, so this table is the only way
    // a completion learns which call it is answering. Two properties matter: a
    // published call comes back with the generation intact (a stale generation
    // would make `deliverJson` a silent no-op), and taking it clears the entry,
    // so a double-firing completion cannot reply twice.
    const ticket = ios_async.Ticket{ .index = 3, .generation = 77 };
    const sels = Sels{
        .count = null,
        .object_at = null,
        .identifier = null,
        .content = null,
        .title = null,
        .body = null,
        .subtitle = null,
        .utf8 = null,
        .utf8_length = null,
    };

    publishPendingCall(ticket, sels);

    const taken = takePendingCall(3) orelse return error.PublishedCallWentMissing;
    try testing.expectEqual(@as(u5, 3), taken.ticket.index);
    try testing.expectEqual(@as(u32, 77), taken.ticket.generation);

    try testing.expect(takePendingCall(3) == null);
}

test "a completion for a slot with no recorded call does nothing" {
    // A late or duplicate fire must not reach `deliverJson` at all. With the
    // entry cleared there is no ticket to reply with, and the block returns
    // without touching the pool — asserted by the neighbouring slots staying
    // empty rather than by observing a reply that must not happen.
    try testing.expect(takePendingCall(9) == null);
    pendingCompletionFired(9, null);
    try testing.expect(takePendingCall(9) == null);
}

test "off Darwin the handler refuses rather than fake an empty list" {
    if (is_darwin) return error.SkipZigTest;

    var bridge = NotificationsBridge.init(testing.allocator);
    defer bridge.deinit();

    // `[]` would be a perfectly plausible-looking lie here: a page cannot tell
    // "no notifications are scheduled" from "this platform has no notification
    // center".
    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.get_pending_notifications, "{}"),
    );
}

test "without a bundle identifier the guard fires before the center is touched" {
    if (!is_darwin) return error.SkipZigTest;

    // The host test runner is a bare binary with no Info.plist — exactly the
    // process in which `currentNotificationCenter` would SIGABRT. If the guard
    // were ever reordered behind the center call, this test would crash the
    // runner rather than fail, which is still a loud answer.
    if (requireBundleIdentifier()) |_| {
        // A runner that does carry a bundle identifier (tests hosted inside an
        // app) would make the call below a real query against that app's
        // notification center; proving the guard needs the bundle-less
        // environment, so skip rather than pretend.
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.NoBundleIdentifier => {
            var bridge = NotificationsBridge.init(testing.allocator);
            defer bridge.deinit();

            try testing.expectError(
                error.NoBundleIdentifier,
                bridge.handleMessage(A.get_pending_notifications, "{}"),
            );

            // And the refusal must happen before any slot is leased: a lease
            // that is never released narrows the pool for every later call.
            for (pending_calls) |entry| try testing.expect(entry == null);
        },
        else => return err,
    }
}

test "the completion blocks are global, one per slot, and distinct" {
    if (!is_darwin) return error.SkipZigTest;

    // `getPendingNotificationRequestsWithCompletionHandler:` copies the block
    // and holds it until it fires. `Block_copy` is the identity on a global
    // block and a heap copy on a stack one, so the isa and the flag are the
    // whole lifetime argument.
    for (&array_blocks) |*b| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, b.isa);
        try testing.expectEqual(BLOCK_IS_GLOBAL, b.flags);
        try testing.expectEqual(@as(c_ulong, @sizeOf(ArrayBlock)), b.descriptor.size);
    }

    // Each slot needs its *own* invoke, or every completion would report the
    // same slot index and answer the wrong caller.
    try testing.expect(array_blocks[0].invoke != array_blocks[1].invoke);
    try testing.expect(arrayBlock(.{ .index = 0, .generation = 1 }) !=
        arrayBlock(.{ .index = 1, .generation = 1 }));
}
