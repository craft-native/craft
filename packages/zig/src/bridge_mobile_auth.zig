//! The `mobile` namespace's biometric prompt: `authenticate`.
//!
//! Separate from `bridge_mobile_biometric.zig` on purpose. That file serves
//! the three `*BiometricPersistence` actions and says at the top that it
//! contains no `LAContext` — because Swift implements those three against one
//! in-memory `Date` and never consults biometrics for them. It is the rare
//! mobile module that is pure Zig with no Darwin gate anywhere, and folding a
//! LocalAuthentication call into it would make it Objective-C-bound on every
//! platform the dispatch chain compiles for, to no one's benefit. The prompt
//! lives here; the bookkeeping stays there.
//!
//! Unblocked by `ios_config.zig`: the Swift arm is behind `config.enableBiometric`
//! with no `else`, so a page calling `authenticate` in an app that left the
//! flag off got a promise that never settled. `ios_dispatch.route` refuses on
//! the flag now, and this is what happens once the flag is on.
//!
//! ## Two replies, and neither is the pooled one
//!
//! Swift resolves the bare JSON `true` on success and *rejects* on failure.
//! `ios_async`'s pre-built `boolErrorBlock` cannot express that: its delivery
//! path answers the strings `"granted"` and `"denied"`, which is the
//! permission vocabulary that `checkPermission` speaks and not this. A page
//! doing `if (await craft.authenticate())` would read `"denied"` as truthy and
//! let the user straight in.
//!
//! So the block below is the module's own, in the shape
//! `bridge_mobile_notifications.zig` established: global, one comptime
//! invoke per slot so it knows its ticket without capturing, and answering
//! through `ios_async.deliverJson` / `deliverErrorCode`.
//!
//! ## Cancelled is not denied
//!
//! Swift rejects every failure with the same `localizedDescription`, so a page
//! cannot tell "the user pressed Cancel" from "there are no biometrics on this
//! device". The protocol has codes for both, and the distinction is the one a
//! caller actually branches on: a cancel is a decision to re-offer the prompt,
//! everything else is a reason to fall back to a passcode. `LAErrorUserCancel`
//! becomes `CANCELLED`; the rest stay `PERMISSION_DENIED`. This is the same
//! divergence `bridge_mobile_filepicker.zig` already makes for a dismissed
//! picker, for the same reason.
//!
//! ## The context's lifetime
//!
//! `LAContext` is created +1 and released in the reply block, which is the
//! point Swift's local goes out of scope. Releasing it earlier would free it
//! while LocalAuthentication is still showing the prompt; never releasing it
//! would leak one context per call. The one path that leaks is an app killed
//! mid-prompt, where the process is going away anyway.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;
const Id = ?*anyopaque;
const is_darwin = builtin.target.os.tag.isDarwin();

pub const A = struct {
    pub const authenticate = "authenticate";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.authenticate, .reply = .result },
};

/// `LAPolicyDeviceOwnerAuthenticationWithBiometrics`.
///
/// Swift passes `.deviceOwnerAuthenticationWithBiometrics`, which is 1. The
/// neighbouring `LAPolicyDeviceOwnerAuthentication` is 2 and falls back to the
/// device passcode — a materially weaker check that would let a page believe a
/// fingerprint was presented when a four-digit code was typed.
const policy_biometrics: c_long = 1;

/// `LAErrorUserCancel`. The user pressed Cancel on the prompt.
const la_error_user_cancel: c_long = -2;

/// Swift's `body["reason"] as? String ?? "Authenticate to continue"`.
///
/// The string is shown to the user inside the system prompt, so it is part of
/// the app's visible text and not a detail. An absent reason defaults; a
/// present non-string is refused rather than replaced, which is where this
/// diverges from `as?` silently substituting the default.
const default_reason = "Authenticate to continue";

/// The reply Swift resolves on success: the bare JSON `true`, not an object.
///
/// `resolveCallback(callbackId, result: true)` under `.fragmentsAllowed`.
/// `craft-bridge.js` resolves with `payload || {}`, so an object here would
/// still be truthy and a page comparing `=== true` would silently stop
/// working.
const success_reply = "true";

pub const AuthBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (!std.mem.eql(u8, action, A.authenticate)) return BridgeError.UnknownAction;
        try self.authenticate(data);
    }

    fn authenticate(self: *Self, data: []const u8) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        const reason = try readReason(self.allocator, data);
        defer self.allocator.free(reason);

        const LAContext = objc.objc_getClass("LAContext") orelse {
            std.log.warn(
                "authenticate: LAContext is not in this process; the app does not link " ++
                    "LocalAuthentication",
                .{},
            );
            return BridgeError.PlatformNotSupported;
        };
        const context = objc.allocInit(LAContext) catch return BridgeError.NativeCallFailed;
        errdefer release(context);

        // Swift's guard. Asking first is not politeness: `evaluatePolicy` on a
        // device with no enrolled biometrics still calls back, but only after
        // presenting and dismissing UI, and the reason string would flash on
        // screen for a check that could never succeed.
        try requireBiometricsAvailable(context);

        const ns_reason = objc.createNSString(reason, self.allocator) catch
            return BridgeError.AllocationFailed;

        const ticket = ios_async.acquire(A.authenticate) orelse {
            std.log.warn(
                "authenticate: no free reply slot; {d} native calls are already awaiting one",
                .{ios_async.max_in_flight},
            );
            return BridgeError.NativeCallFailed;
        };
        errdefer ios_async.abandon(ticket);

        publishPendingCall(ticket, context);

        const sel = objc.sel_registerName("evaluatePolicy:localizedReason:reply:") orelse
            return BridgeError.NativeCallFailed;
        const EvaluateFn = *const fn (Id, objc.SEL, c_long, Id, *anyopaque) callconv(.c) void;
        const evaluate: EvaluateFn = @ptrCast(&objc.objc_msgSend);
        evaluate(context, sel, policy_biometrics, ns_reason, replyBlock(ticket));
    }
};

/// `canEvaluatePolicy:error:`, with the framework's own reason in the log.
///
/// Swift rejects with `error?.localizedDescription ?? "Biometric not
/// available"`. The protocol has no message field, so the description goes to
/// the log — where "no identities are enrolled" and "biometry is locked out"
/// are different enough to act on, and both would otherwise arrive as the same
/// bare code.
fn requireBiometricsAvailable(context: Id) !void {
    const sel = objc.sel_registerName("canEvaluatePolicy:error:") orelse
        return BridgeError.NativeCallFailed;
    const CanEvaluateFn = *const fn (Id, objc.SEL, c_long, *Id) callconv(.c) bool;
    const canEvaluate: CanEvaluateFn = @ptrCast(&objc.objc_msgSend);

    var err: Id = null;
    if (canEvaluate(context, sel, policy_biometrics, &err)) return;

    logNSError("authenticate", err);
    return BridgeError.PermissionDenied;
}

/// The `reason`, or the reason it cannot be used.
///
/// Pure, so the host tests pin every outcome Swift's `as?` collapsed into a
/// silent default.
fn readReason(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return BridgeError.InvalidJSON,
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |o| o,
        else => return BridgeError.InvalidJSON,
    };

    const value = object.get("reason") orelse
        return allocator.dupe(u8, default_reason) catch BridgeError.AllocationFailed;

    return switch (value) {
        // An explicit JSON null is Swift's `NSNull`, which `as? String` turns
        // into nil and the `??` then defaults — so null defaults too.
        .null => allocator.dupe(u8, default_reason) catch BridgeError.AllocationFailed,
        .string => |s| if (s.len == 0)
            BridgeError.InvalidParameter
        else
            allocator.dupe(u8, s) catch BridgeError.AllocationFailed,
        else => BridgeError.InvalidParameter,
    };
}

// ---------------------------------------------------------------------------
// The reply block
// ---------------------------------------------------------------------------

/// What a slot's reply block needs that the block itself cannot carry.
///
/// The ticket is stored rather than rebuilt from the index: a `Ticket` is an
/// index *and* a generation, and inventing the generation at reply time would
/// defeat the check that stops a late completion from answering whoever holds
/// the slot now.
const PendingCall = struct {
    ticket: ios_async.Ticket,
    context: Id,
};

var pending_calls: [ios_async.max_in_flight]?PendingCall = @splat(null);
var pending_mutex: compat_mutex.Mutex = .{};

/// Record the call a slot's block will answer. The slot is leased exclusively
/// by this ticket, so the entry is ours to overwrite.
fn publishPendingCall(ticket: ios_async.Ticket, context: Id) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls[ticket.index] = .{ .ticket = ticket, .context = context };
}

/// Read and clear a slot's entry. Clearing is what makes a second fire of the
/// same completion a no-op rather than a second reply — and, here, a second
/// `release` of a context that is already gone.
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

/// `void (^)(BOOL, NSError *)`.
///
/// The same shape as `ios_async.boolErrorBlock`, and deliberately not that
/// block: this one answers `true` or an error, where the pooled one answers
/// `"granted"` or `"denied"`.
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
        fn invoke(_: *const ReplyBlock, success: bool, err: Id) callconv(.c) void {
            replyFired(index, success, err);
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

/// Runs on whatever queue LocalAuthentication chose.
///
/// It must not reply from here — `evaluateJavaScript:` is main-thread-only —
/// so both outcomes go through `ios_async`, which hops to the main queue and
/// answers under the request id captured back at dispatch. Swift's own
/// `DispatchQueue.main.async` in this position is the same hop, done by hand.
fn replyFired(index: u5, success: bool, err: Id) void {
    if (!is_darwin) return;

    const call = takePendingCall(index) orelse {
        std.log.warn(
            "authenticate reply fired for slot {d} with no call recorded; ignored",
            .{index},
        );
        return;
    };

    // Released here, which is where Swift's local goes out of scope: the
    // prompt is finished with it, and holding it longer would leak one context
    // per authentication.
    release(call.context);

    if (success) {
        ios_async.deliverJson(call.ticket, success_reply);
        return;
    }

    logNSError(A.authenticate, err);
    ios_async.deliverErrorCode(call.ticket, if (errorCode(err) == la_error_user_cancel)
        BridgeError.Cancelled
    else
        BridgeError.PermissionDenied);
}

fn errorCode(err: Id) c_long {
    const ns_error = err orelse return 0;
    const sel = objc.sel_registerName("code") orelse return 0;
    const CodeFn = *const fn (Id, objc.SEL) callconv(.c) c_long;
    const codeFn: CodeFn = @ptrCast(&objc.objc_msgSend);
    return codeFn(ns_error, sel);
}

fn logNSError(action: []const u8, err: Id) void {
    const ns_error = err orelse {
        std.log.warn("{s}: refused, and the framework reported no reason", .{action});
        return;
    };
    const sel = objc.sel_registerName("localizedDescription") orelse return;
    const ns_description = objc.msgSendId(ns_error, sel) orelse return;
    const utf8 = objc.getNSStringUTF8(ns_description) orelse return;
    std.log.warn("{s}: {s}", .{ action, std.mem.span(utf8) });
}

fn release(object: Id) void {
    const target = object orelse return;
    const sel = objc.sel_registerName("release") orelse return;
    objc.msgSend(target, sel);
}

const testing = std.testing;

test "the action name matches the Swift case label exactly" {
    try testing.expectEqualStrings("authenticate", A.authenticate);
}

test "success resolves the bare JSON true, not an object" {
    // Swift's `resolveCallback(callbackId, result: true)` under
    // `.fragmentsAllowed`. An object would still be truthy through
    // `craft-bridge.js`'s `payload || {}`, so a page comparing `=== true`
    // would silently stop working rather than fail visibly.
    try testing.expectEqualStrings("true", success_reply);
}

test "the policy is the biometric one, not the passcode fallback" {
    // LAPolicyDeviceOwnerAuthentication (2) falls back to the device passcode.
    // Passing it would let a page believe a fingerprint was presented when a
    // four-digit code was typed — the same call, a materially weaker claim.
    try testing.expectEqual(@as(c_long, 1), policy_biometrics);
    try testing.expectEqual(@as(c_long, -2), la_error_user_cancel);
}

test "an absent or null reason defaults, a mistyped one is refused" {
    // Swift's `body["reason"] as? String ?? "Authenticate to continue"` also
    // rewrites a present-but-non-string reason into the default and reports
    // success — a payload field the page sent, replaced with a different one.
    // Absence defaults here because that is what the injected JS sends; a
    // wrong type does not.
    const absent = try readReason(testing.allocator, "{}");
    defer testing.allocator.free(absent);
    try testing.expectEqualStrings(default_reason, absent);

    const null_reason = try readReason(testing.allocator, "{\"reason\":null}");
    defer testing.allocator.free(null_reason);
    try testing.expectEqualStrings(default_reason, null_reason);

    const given = try readReason(testing.allocator, "{\"reason\":\"Unlock the vault\"}");
    defer testing.allocator.free(given);
    try testing.expectEqualStrings("Unlock the vault", given);

    try testing.expectError(
        BridgeError.InvalidParameter,
        readReason(testing.allocator, "{\"reason\":7}"),
    );
    try testing.expectError(
        BridgeError.InvalidParameter,
        readReason(testing.allocator, "{\"reason\":\"\"}"),
    );
    try testing.expectError(BridgeError.InvalidJSON, readReason(testing.allocator, "[]"));
}

test "every declared action dispatches to something" {
    var bridge = AuthBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            continue;
        };
    }
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("getDeviceInfo", "{}"));
}

test "a refusal leases no reply slot" {
    // A lease that is never released narrows the pool for every later call.
    // The host has no LAContext, so this exercises the earliest refusal path.
    if (!is_darwin) return error.SkipZigTest;

    var bridge = AuthBridge.init(testing.allocator);
    defer bridge.deinit();
    bridge.handleMessage(A.authenticate, "{}") catch {};

    pending_mutex.lock();
    defer pending_mutex.unlock();
    for (pending_calls) |entry| try testing.expect(entry == null);
}

test "each slot's reply block is global and has its own invoke" {
    if (!is_darwin) return error.SkipZigTest;

    for (&reply_blocks) |*b| {
        // A global block is never copied, which is what makes it safe to hand
        // to an API that escapes it.
        try testing.expectEqual(&_NSConcreteGlobalBlock, b.isa);
        try testing.expectEqual(BLOCK_IS_GLOBAL, b.flags);
        try testing.expectEqual(@sizeOf(ReplyBlock), @as(usize, @intCast(b.descriptor.size)));
    }
    // Each slot needs its own invoke, or every reply would answer whichever
    // call the shared invoke happened to name.
    try testing.expect(reply_blocks[0].invoke != reply_blocks[1].invoke);
}

test "a reply for a slot with no recorded call is ignored" {
    // A completion that fires twice, or after the slot was abandoned, must not
    // release a context that is already gone or answer a call that is not
    // there.
    if (!is_darwin) return error.SkipZigTest;

    pending_mutex.lock();
    for (&pending_calls) |*entry| entry.* = null;
    pending_mutex.unlock();

    replyFired(0, true, null);
    replyFired(0, false, null);
}
