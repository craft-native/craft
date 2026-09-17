//! The `mobile` namespace's Siri shortcut pair: `registerSiriShortcut` and
//! `removeSiriShortcut`.
//!
//! Not the same thing as `bridge_mobile_shortcuts.zig`, which serves
//! `setShortcuts`/`clearShortcuts` — those are `UIApplication.shortcutItems`,
//! the long-press menu on the app icon. These two are `NSUserActivity`
//! donations that Siri and Spotlight index. Two features, one English word,
//! and the modules are kept apart so neither has to explain the other.
//!
//! ## No Intents framework, no permission, no UI
//!
//! Worth stating because "Siri shortcut" suggests all three. `CraftApp.swift`
//! never imports Intents for these: `registerSiriShortcut` builds a plain
//! `NSUserActivity`, sets six properties and calls `becomeCurrent()`;
//! `removeSiriShortcut` calls one `NSUserActivity` class method. Both are
//! Foundation, both are ungated in the dispatcher, and neither prompts. That
//! makes them the last actions in the migration that need nothing but
//! `objc_msgSend`.
//!
//! ## The activity's lifetime is Swift's, deliberately
//!
//! Swift's `activity` is a local. ARC releases it when the function returns,
//! immediately after `becomeCurrent()`, so whether the donation outlives the
//! call is the system's business and not the app's. This releases at the same
//! point for the same reason. Holding it in a module-level var would keep the
//! donation alive longer than the spec does — a divergence in the direction of
//! "works better", which is still a divergence in behaviour a page can
//! observe through Spotlight.
//!
//! ## Where the activity type comes from
//!
//! Swift interpolates the template placeholder: `"{{BUNDLE_ID}}.\(action)"`,
//! substituted at project-generation time. Zig has no template, so it reads
//! `[[NSBundle mainBundle] bundleIdentifier]`, which is what that placeholder
//! is generated *from* — `packages/ios/src/index.ts` writes the same string
//! into `project.yml` as `PRODUCT_BUNDLE_IDENTIFIER` and into the Swift
//! source. A generated app cannot tell the two apart; a hand-edited one where
//! they disagree gets the identifier the process actually has, which is the
//! one Siri will match against.
//!
//! Invoking the donated activity returns through `CraftAppDelegate`. The
//! template queues its `craftSiriShortcut` event until the web bridge is ready,
//! so a cold launch carries the same action as a foreground invocation.
//!
//! ## Key order in the replies
//!
//! Swift resolves Swift `Dictionary` literals, and `JSONSerialization` emits
//! their keys in hash order — which is not the literal's order and is not
//! stable across launches. So no page can depend on key order, and the fixed
//! order below is a choice this file is free to make rather than a contract it
//! is preserving.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const compat = @import("compat.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;
const Id = ?*anyopaque;
const is_darwin = builtin.target.os.tag.isDarwin();

pub const A = struct {
    pub const register_siri_shortcut = "registerSiriShortcut";
    pub const remove_siri_shortcut = "removeSiriShortcut";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.register_siri_shortcut, .reply = .result },
    .{ .name = A.remove_siri_shortcut, .reply = .result },
};

pub const SiriBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.register_siri_shortcut)) {
            try self.registerShortcut(data);
        } else if (std.mem.eql(u8, action, A.remove_siri_shortcut)) {
            try self.removeShortcut(data);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// Donate an activity, synchronously.
    ///
    /// No completion handler exists on this path — `becomeCurrent` returns
    /// void — so there is no `ios_async` ticket and the reply goes out inside
    /// the dispatch frame that holds this call's id.
    fn registerShortcut(self: *Self, data: []const u8) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        var fields = try readFields(self.allocator, data, .{ .phrase = true });
        defer fields.deinit(self.allocator);

        const phrase = fields.phrase.?;
        const action = fields.action;

        try donate(self.allocator, phrase, action);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"registered\":true,\"action\":");
        try appendJsonString(self.allocator, &out, action);
        try out.appendSlice(self.allocator, ",\"phrase\":");
        try appendJsonString(self.allocator, &out, phrase);
        try out.append(self.allocator, '}');

        bridge_error.sendResultToJS(self.allocator, A.register_siri_shortcut, out.items);
    }

    /// Delete a donated activity, and answer when the deletion is done, or
    /// with `TIMEOUT` if it has not said so within `removal_deadline_ms`.
    ///
    /// `deleteSavedUserActivitiesWithPersistentIdentifiers:completionHandler:`
    /// takes a `void (^)(void)`, and Swift replies from inside it. Replying
    /// before it fired would tell the page a shortcut is gone while Siri can
    /// still match it — the window is small and the claim is still false.
    ///
    /// The completion comes from a system daemon, and on a freshly booted
    /// simulator it sometimes never comes (#211). Nothing else would ever
    /// settle the call, so the deadline does, and never with `removed: true`:
    /// the deletion may or may not have happened, and a second removal is
    /// harmless.
    ///
    /// Every step that can fail comes before the reply slot is leased, except
    /// claiming a completion block, whose refusal the two `errdefer`s undo.
    /// Once a block holds the parked reply, nothing may fail until Foundation
    /// has it.
    fn removeShortcut(self: *Self, data: []const u8) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        var fields = try readFields(self.allocator, data, .{ .phrase = false });
        defer fields.deinit(self.allocator);

        const NSUserActivity = objc.objc_getClass("NSUserActivity") orelse
            return BridgeError.PlatformNotSupported;
        const identifiers = try singletonArray(self.allocator, fields.action);
        const sel = objc.sel_registerName(
            "deleteSavedUserActivitiesWithPersistentIdentifiers:completionHandler:",
        ) orelse return BridgeError.NativeCallFailed;

        // The reply names the action, so it is shaped before the ticket exists
        // and handed to the slot: the completion carries no arguments at all
        // and has nothing else to reconstruct it from.
        const quoted = try jsonString(std.heap.c_allocator, fields.action);
        defer std.heap.c_allocator.free(quoted);
        const reply = std.fmt.allocPrint(
            std.heap.c_allocator,
            "{{\"removed\":true,\"action\":{s}}}",
            .{quoted},
        ) catch return BridgeError.AllocationFailed;
        errdefer std.heap.c_allocator.free(reply);

        const ticket = ios_async.acquire(A.remove_siri_shortcut) orelse {
            std.log.warn(
                "removeSiriShortcut: no free reply slot; {d} native calls are already " ++
                    "awaiting one",
                .{ios_async.max_in_flight},
            );
            return BridgeError.NativeCallFailed;
        };
        errdefer ios_async.abandon(ticket);

        const block = claimBlock(ticket, reply) orelse {
            std.log.warn(
                "removeSiriShortcut: all {d} completion blocks are still owed a completion " ++
                    "Foundation never delivered; refusing rather than reusing one",
                .{block_count},
            );
            return BridgeError.NativeCallFailed;
        };

        ios_async.scheduleDeadline(ticket, removal_deadline_ms, removalTimedOut);

        const DeleteFn = *const fn (objc.Class, objc.SEL, Id, *anyopaque) callconv(.c) void;
        const deleteFn: DeleteFn = @ptrCast(&objc.objc_msgSend);
        deleteFn(NSUserActivity, sel, identifiers, @ptrCast(&done_blocks[block]));
    }
};

/// Build and donate the `NSUserActivity`, in Swift's order.
fn donate(allocator: std.mem.Allocator, phrase: []const u8, action: []const u8) !void {
    const NSUserActivity = objc.objc_getClass("NSUserActivity") orelse
        return BridgeError.PlatformNotSupported;

    const activity_type = try activityType(allocator, action);
    defer allocator.free(activity_type);

    const ns_type = objc.createNSString(activity_type, allocator) catch
        return BridgeError.AllocationFailed;
    const sel_alloc = objc.sel_registerName("alloc") orelse return BridgeError.NativeCallFailed;
    const sel_init = objc.sel_registerName("initWithActivityType:") orelse
        return BridgeError.NativeCallFailed;

    const allocated = objc.msgSendId(NSUserActivity, sel_alloc) orelse
        return BridgeError.NativeCallFailed;
    const activity = objc.msgSendId1(allocated, sel_init, ns_type) orelse
        return BridgeError.NativeCallFailed;
    // ARC releases Swift's local when the function returns, just after
    // `becomeCurrent()`. Same point, same reason.
    defer release(activity);

    const ns_phrase = objc.createNSString(phrase, allocator) catch
        return BridgeError.AllocationFailed;
    const ns_action = objc.createNSString(action, allocator) catch
        return BridgeError.AllocationFailed;

    try setObject(activity, "setTitle:", ns_phrase);
    try setBool(activity, "setEligibleForSearch:", true);
    try setBool(activity, "setEligibleForPrediction:", true);
    // `NSUserActivityPersistentIdentifier` is a typedef for `NSString *`, so
    // the raw action string is the identifier — which is also what
    // `removeSiriShortcut` deletes by.
    try setObject(activity, "setPersistentIdentifier:", ns_action);
    try setObject(activity, "setSuggestedInvocationPhrase:", ns_phrase);
    try setObject(activity, "setUserInfo:", try userInfo(allocator, ns_action));

    const sel_become = objc.sel_registerName("becomeCurrent") orelse
        return BridgeError.NativeCallFailed;
    objc.msgSend(activity, sel_become);
}

/// `"<bundle identifier>.<action>"`.
fn activityType(allocator: std.mem.Allocator, action: []const u8) ![]u8 {
    const NSBundle = objc.objc_getClass("NSBundle") orelse return BridgeError.NativeCallFailed;
    const sel_main = objc.sel_registerName("mainBundle") orelse return BridgeError.NativeCallFailed;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return BridgeError.NativeCallFailed;
    const sel_identifier = objc.sel_registerName("bundleIdentifier") orelse
        return BridgeError.NativeCallFailed;

    // A process with no bundle identifier is a unit-test host or a bare
    // executable, and an activity type of ".doThing" would be donated into a
    // namespace shared with every other such process. Refusing names the real
    // condition.
    const ns_identifier = objc.msgSendId(bundle, sel_identifier) orelse {
        std.log.warn(
            "registerSiriShortcut: this process has no bundle identifier, so the " ++
                "activity type would not be unique to this app",
            .{},
        );
        return BridgeError.NativeCallFailed;
    };
    const utf8 = objc.getNSStringUTF8(ns_identifier) orelse return BridgeError.NativeCallFailed;

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ std.mem.span(utf8), action }) catch
        BridgeError.AllocationFailed;
}

/// `@{@"action": action}` — Swift's `activity.userInfo = ["action": action]`.
fn userInfo(allocator: std.mem.Allocator, ns_action: Id) !Id {
    const NSDictionary = objc.objc_getClass("NSDictionary") orelse
        return BridgeError.NativeCallFailed;
    const sel = objc.sel_registerName("dictionaryWithObject:forKey:") orelse
        return BridgeError.NativeCallFailed;
    const key = objc.createNSString("action", allocator) catch return BridgeError.AllocationFailed;
    return objc.msgSendId2(NSDictionary, sel, ns_action, key) orelse BridgeError.NativeCallFailed;
}

fn singletonArray(allocator: std.mem.Allocator, value: []const u8) !Id {
    const ns_value = objc.createNSString(value, allocator) catch return BridgeError.AllocationFailed;
    const NSArray = objc.objc_getClass("NSArray") orelse return BridgeError.NativeCallFailed;
    const sel = objc.sel_registerName("arrayWithObject:") orelse return BridgeError.NativeCallFailed;
    return objc.msgSendId1(NSArray, sel, ns_value) orelse BridgeError.NativeCallFailed;
}

fn setObject(target: Id, comptime selector: [*:0]const u8, value: Id) !void {
    const sel = objc.sel_registerName(selector) orelse return BridgeError.NativeCallFailed;
    objc.msgSendVoid1(target, sel, value);
}

fn setBool(target: Id, comptime selector: [*:0]const u8, value: bool) !void {
    const sel = objc.sel_registerName(selector) orelse return BridgeError.NativeCallFailed;
    const SetFn = *const fn (Id, objc.SEL, bool) callconv(.c) void;
    const setFn: SetFn = @ptrCast(&objc.objc_msgSend);
    setFn(target, sel, value);
}

/// The payload fields, owned.
const Fields = struct {
    action: []u8,
    phrase: ?[]u8,

    fn deinit(self: *Fields, allocator: std.mem.Allocator) void {
        allocator.free(self.action);
        if (self.phrase) |p| allocator.free(p);
    }
};

/// Read `action`, and `phrase` when the caller needs it.
///
/// Both Swift arms are `if let … as? String` chains with no `else`, so a
/// missing or mistyped field replies nothing and the page waits out its
/// timeout. Not carried across: every path here ends in a value or an error.
fn readFields(
    allocator: std.mem.Allocator,
    data: []const u8,
    comptime want: struct { phrase: bool },
) !Fields {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return BridgeError.InvalidJSON,
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |o| o,
        else => return BridgeError.InvalidJSON,
    };

    // `shortcutAction`, not `action`: the envelope's own `action` names the
    // bridge action, and the page used to send both under that one key. See
    // the wrapper in `CraftApp.swift`.
    const action = try requiredString(allocator, object, "shortcutAction");
    errdefer allocator.free(action);

    const phrase = if (want.phrase) try requiredString(allocator, object, "phrase") else null;

    return .{ .action = action, .phrase = phrase };
}

fn requiredString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return BridgeError.MissingData;
    const text = switch (value) {
        .string => |s| s,
        else => return BridgeError.InvalidParameter,
    };
    // An empty action would donate an activity type ending in a dot and delete
    // by an identifier that matches nothing.
    if (text.len == 0) return BridgeError.InvalidParameter;
    return allocator.dupe(u8, text) catch BridgeError.AllocationFailed;
}

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, out, s);
    try out.append(allocator, '"');
}

fn jsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendJsonString(allocator, &out, s);
    return out.toOwnedSlice(allocator);
}

fn release(object: Id) void {
    const target = object orelse return;
    const sel = objc.sel_registerName("release") orelse return;
    objc.msgSend(target, sel);
}

// ---------------------------------------------------------------------------
// The deletion completion
// ---------------------------------------------------------------------------

/// How long a removal waits for its completion before answering `TIMEOUT`.
///
/// For `craft.siri.remove`, which arms no timeout of its own, this is the only
/// thing that settles the call; for `_invoke` and `craft-bridge.js`, it is
/// well under their 30 s, so the page hears the native answer rather than its
/// own. It is the same budget the slice fixture
/// gives a daemon-served location fix on the same simulator. A completion
/// that arrives in time logs how long it took, so the number can be checked
/// against CI.
const removal_deadline_ms: u32 = 15_000;

/// A removal waiting on its completion.
///
/// `void (^)(void)` carries nothing — not even a success flag — so everything
/// the reply needs is shaped before the call and parked here. The ticket is
/// stored rather than rebuilt, because a `Ticket` is an index *and* a
/// generation, and the deadline matches on both.
const PendingCall = struct {
    ticket: ios_async.Ticket,
    /// Owned, `c_allocator`. Freed by whichever of the completion and the
    /// deadline takes the call.
    reply: []u8,
    started_ms: i64,
};

/// One per completion block, not per reply slot.
///
/// A block knows only its own index. If blocks were chosen by reply slot, a
/// deadline would release slot k, the next removal would lease slot k and get
/// the same block, and the first removal's late completion would then answer
/// the second with `removed: true` before its deletion had finished. So a
/// block whose call the deadline answered stays `owed` until Foundation calls
/// it, and is never handed to another call in the meantime.
const BlockState = union(enum) {
    free,
    waiting: PendingCall,
    /// Answered by the deadline. Foundation still holds this block and may
    /// call it; when it does, that call is ignored and the block is freed.
    /// Carries when the call started, so a late completion can say how late.
    owed: i64,
};

/// Twice the reply slots, so every slot can be waiting while as many blocks
/// again are still owed a completion that has not come.
const block_count = 2 * ios_async.max_in_flight;

var blocks: [block_count]BlockState = @splat(.free);
var pending_mutex: compat_mutex.Mutex = .{};

/// Park `reply` on the first free block. Null when every block is waiting or
/// owed, which the caller refuses rather than reusing an owed block.
fn claimBlock(ticket: ios_async.Ticket, reply: []u8) ?u5 {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    for (&blocks, 0..) |*state, i| {
        if (state.* != .free) continue;
        state.* = .{ .waiting = .{ .ticket = ticket, .reply = reply, .started_ms = compat.milliTimestamp() } };
        return @intCast(i);
    }
    return null;
}

/// The deadline's half: take the call `ticket` names if it is still waiting,
/// and leave its block owed. Matching the whole ticket is what stops a timer
/// from expiring a newer call that leased the same reply slot.
fn expireIfWaiting(ticket: ios_async.Ticket) ?PendingCall {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    for (&blocks) |*state| {
        const call = switch (state.*) {
            .waiting => |call| call,
            else => continue,
        };
        if (call.ticket.index != ticket.index or call.ticket.generation != ticket.generation) continue;
        state.* = .{ .owed = call.started_ms };
        return call;
    }
    return null;
}

const Settled = union(enum) {
    /// The completion arrived first: answer with this call.
    reply: PendingCall,
    /// The deadline already answered. Nothing to send. When the call started.
    late: i64,
    /// No call was ever parked on this block.
    stray,
};

/// The completion's half. Each block leaves `waiting` or `owed` exactly once,
/// under the lock, so the completion and the deadline cannot both answer.
fn settleBlock(block: u5) Settled {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const state = blocks[block];
    blocks[block] = .free;
    return switch (state) {
        .waiting => |call| .{ .reply = call },
        .owed => |started_ms| .{ .late = started_ms },
        .free => .stray,
    };
}

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// `void (^)(void)` — no arguments at all, which is why none of `ios_async`'s
/// pre-built blocks fit.
const DoneBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// 1 << 28. A global block is never copied, so it can be handed to an API that
/// escapes it with no heap copy and no descriptor lifetime.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

const done_block_descriptor = BlockDescriptor{ .size = @sizeOf(DoneBlock) };

extern var _NSConcreteGlobalBlock: anyopaque;

fn makeDoneInvoke(comptime block: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const DoneBlock) callconv(.c) void {
            deletionFired(block);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeDoneBlocks() [block_count]DoneBlock {
    var out: [block_count]DoneBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = makeDoneInvoke(@intCast(i)),
            .descriptor = &done_block_descriptor,
        };
    }
    return out;
}

var done_blocks: [block_count]DoneBlock =
    if (is_darwin) makeDoneBlocks() else undefined;

/// Runs on whatever queue Foundation chose. `ios_async.deliverJson` copies the
/// payload and hops to the main queue, where `evaluateJavaScript:` is legal.
fn deletionFired(block: u5) void {
    if (!is_darwin) return;

    switch (settleBlock(block)) {
        .reply => |call| {
            defer std.heap.c_allocator.free(call.reply);
            std.log.info(
                "removeSiriShortcut: the deletion completion arrived after {d} ms",
                .{compat.milliTimestamp() - call.started_ms},
            );
            ios_async.deliverJson(call.ticket, call.reply);
        },
        .late => |started_ms| std.log.warn(
            "removeSiriShortcut: a deletion completion arrived {d} ms after the call, after " ++
                "its deadline had answered; ignored",
            .{compat.milliTimestamp() - started_ms},
        ),
        .stray => std.log.warn(
            "removeSiriShortcut completion fired for block {d} with no call recorded; ignored",
            .{block},
        ),
    }
}

/// On the main queue, `removal_deadline_ms` after the call. Does nothing when
/// the completion got there first, which is the usual case: the timer cannot be
/// cancelled.
fn removalTimedOut(context: ?*anyopaque) callconv(.c) void {
    if (!is_darwin) return;

    const call = expireIfWaiting(ios_async.ticketFromDeadline(context)) orelse return;
    defer std.heap.c_allocator.free(call.reply);

    // The page's message is fixed by the error code, so the framework is named
    // here. No `i=` in this line: the slice fixture greps for markers by it.
    std.log.warn(
        "removeSiriShortcut: +[NSUserActivity deleteSavedUserActivitiesWithPersistentIdentifiers:" ++
            "completionHandler:] did not call its completion within {d} ms; answering TIMEOUT",
        .{removal_deadline_ms},
    );
    ios_async.deliverErrorCode(call.ticket, BridgeError.Timeout);
}

const testing = std.testing;

test "the action names match the Swift case labels exactly" {
    try testing.expectEqualStrings("registerSiriShortcut", A.register_siri_shortcut);
    try testing.expectEqualStrings("removeSiriShortcut", A.remove_siri_shortcut);
}

test "both fields are required for a registration, and neither hangs" {
    // Swift's arm is a two-clause `if let … as? String` with no else, so a
    // missing phrase replies nothing at all.
    var fields = try readFields(
        testing.allocator,
        "{\"shortcutAction\":\"openVault\",\"phrase\":\"open my vault\"}",
        .{ .phrase = true },
    );
    defer fields.deinit(testing.allocator);
    try testing.expectEqualStrings("openVault", fields.action);
    try testing.expectEqualStrings("open my vault", fields.phrase.?);

    try testing.expectError(BridgeError.MissingData, readFields(
        testing.allocator,
        "{\"shortcutAction\":\"openVault\"}",
        .{ .phrase = true },
    ));
    try testing.expectError(BridgeError.MissingData, readFields(
        testing.allocator,
        "{\"phrase\":\"open my vault\"}",
        .{ .phrase = true },
    ));
    try testing.expectError(BridgeError.InvalidParameter, readFields(
        testing.allocator,
        "{\"shortcutAction\":\"\",\"phrase\":\"p\"}",
        .{ .phrase = true },
    ));
    try testing.expectError(BridgeError.InvalidParameter, readFields(
        testing.allocator,
        "{\"shortcutAction\":3,\"phrase\":\"p\"}",
        .{ .phrase = true },
    ));
}

test "a removal needs only the action" {
    var fields = try readFields(testing.allocator, "{\"shortcutAction\":\"openVault\"}", .{ .phrase = false });
    defer fields.deinit(testing.allocator);
    try testing.expectEqualStrings("openVault", fields.action);
    try testing.expect(fields.phrase == null);
}

test "an action carrying a quote survives into the reply escaped" {
    // The reply is replayed into the source `evaluateJavaScript:` parses, so
    // an unescaped quote is a syntax error in the page rather than a wrong
    // field.
    const quoted = try jsonString(testing.allocator, "open \"my\" vault\\");
    defer testing.allocator.free(quoted);
    try testing.expectEqualStrings("\"open \\\"my\\\" vault\\\\\"", quoted);
}

test "every declared action dispatches to something" {
    var bridge = SiriBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            continue;
        };
    }
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("setShortcuts", "{}"));
}

test "a refused removal leases no reply slot" {
    if (!is_darwin) return error.SkipZigTest;
    resetBlocks();

    var bridge = SiriBridge.init(testing.allocator);
    defer bridge.deinit();
    // No `action`, so it refuses before the ticket is taken.
    bridge.handleMessage(A.remove_siri_shortcut, "{}") catch {};

    pending_mutex.lock();
    defer pending_mutex.unlock();
    for (blocks) |state| try testing.expect(state == .free);
}

test "each completion block is global and has its own invoke" {
    if (!is_darwin) return error.SkipZigTest;

    for (&done_blocks) |*b| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, b.isa);
        try testing.expectEqual(BLOCK_IS_GLOBAL, b.flags);
        try testing.expectEqual(@sizeOf(DoneBlock), @as(usize, @intCast(b.descriptor.size)));
    }
    try testing.expect(done_blocks[0].invoke != done_blocks[1].invoke);
    try testing.expect(done_blocks[0].invoke != done_blocks[block_count - 1].invoke);
}

test "a completion for a block with no recorded call is ignored" {
    // `void (^)(void)` carries nothing, so a stray fire has no way to identify
    // itself. Freeing the block on settle is what makes the second fire a
    // no-op rather than a double free of the parked reply.
    if (!is_darwin) return error.SkipZigTest;
    resetBlocks();

    deletionFired(0);
    deletionFired(0);
}

// The deadline (#211). None of these reach `ios_async.deliver*`: they drive
// the block table the deadline and the completion race over, which is where
// "exactly one answer, to the right call" is decided. A host test has no main
// queue for the timer or the hop.

/// Free every block, and any reply a previous test left parked.
fn resetBlocks() void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    for (&blocks) |*state| {
        switch (state.*) {
            .waiting => |call| std.heap.c_allocator.free(call.reply),
            else => {},
        }
        state.* = .free;
    }
}

fn parkedReply(text: []const u8) ![]u8 {
    return std.heap.c_allocator.dupe(u8, text);
}

test "a deadline answers a waiting removal once, and leaves its block owed" {
    resetBlocks();
    defer resetBlocks();

    const ticket: ios_async.Ticket = .{ .index = 3, .generation = 7 };
    const block = claimBlock(ticket, try parkedReply("{\"removed\":true}")) orelse return error.NoBlock;

    const call = expireIfWaiting(ticket) orelse return error.DeadlineFoundNothing;
    defer std.heap.c_allocator.free(call.reply);
    try testing.expectEqualStrings("{\"removed\":true}", call.reply);
    try testing.expect(blocks[block] == .owed);

    // A second expiry of the same call finds nothing to answer.
    try testing.expect(expireIfWaiting(ticket) == null);
}

test "a completion after its deadline is ignored, and frees its block" {
    resetBlocks();
    defer resetBlocks();

    const ticket: ios_async.Ticket = .{ .index = 3, .generation = 7 };
    const block = claimBlock(ticket, try parkedReply("r")) orelse return error.NoBlock;
    const call = expireIfWaiting(ticket) orelse return error.DeadlineFoundNothing;
    std.heap.c_allocator.free(call.reply);

    try testing.expect(settleBlock(block) == .late);
    try testing.expect(blocks[block] == .free);
    try testing.expect(settleBlock(block) == .stray);
}

test "a deadline that fires after the completion does nothing" {
    // The usual case: the timer cannot be cancelled, so it fires for every
    // removal, including the ones that were answered long ago.
    resetBlocks();
    defer resetBlocks();

    const ticket: ios_async.Ticket = .{ .index = 3, .generation = 7 };
    const block = claimBlock(ticket, try parkedReply("r")) orelse return error.NoBlock;
    switch (settleBlock(block)) {
        .reply => |call| std.heap.c_allocator.free(call.reply),
        else => return error.CompletionFoundNothing,
    }

    try testing.expect(expireIfWaiting(ticket) == null);
    try testing.expect(blocks[block] == .free);
}

test "a stale deadline cannot expire a newer removal on the same reply slot" {
    resetBlocks();
    defer resetBlocks();

    const first: ios_async.Ticket = .{ .index = 3, .generation = 7 };
    const block = claimBlock(first, try parkedReply("first")) orelse return error.NoBlock;
    switch (settleBlock(block)) {
        .reply => |call| std.heap.c_allocator.free(call.reply),
        else => return error.CompletionFoundNothing,
    }

    const second: ios_async.Ticket = .{ .index = 3, .generation = 9 };
    const again = claimBlock(second, try parkedReply("second")) orelse return error.NoBlock;

    try testing.expect(expireIfWaiting(first) == null);
    switch (blocks[again]) {
        .waiting => |call| try testing.expectEqual(@as(u32, 9), call.ticket.generation),
        else => return error.NewerCallWasExpired,
    }
}

test "a reply slot reused after a deadline never gets the block still owed" {
    // The mix-up a deadline keyed only by reply slot would ship: the first
    // removal's late completion answering the second with `removed: true`
    // before the second deletion had finished.
    resetBlocks();
    defer resetBlocks();

    const first: ios_async.Ticket = .{ .index = 0, .generation = 1 };
    const first_block = claimBlock(first, try parkedReply("first")) orelse return error.NoBlock;
    const expired = expireIfWaiting(first) orelse return error.DeadlineFoundNothing;
    std.heap.c_allocator.free(expired.reply);

    // The same slot index, as `ios_async.acquire` hands out the lowest free one.
    const second: ios_async.Ticket = .{ .index = 0, .generation = 3 };
    const second_block = claimBlock(second, try parkedReply("second")) orelse return error.NoBlock;
    try testing.expect(second_block != first_block);

    // The late completion for the first removal answers nobody.
    try testing.expect(settleBlock(first_block) == .late);
    switch (settleBlock(second_block)) {
        .reply => |call| {
            defer std.heap.c_allocator.free(call.reply);
            try testing.expectEqual(@as(u32, 3), call.ticket.generation);
            try testing.expectEqualStrings("second", call.reply);
        },
        else => return error.SecondCallLost,
    }
}

test "with every block still owed, a removal is refused rather than reusing one" {
    resetBlocks();
    defer resetBlocks();

    pending_mutex.lock();
    for (&blocks) |*state| state.* = .{ .owed = 0 };
    pending_mutex.unlock();

    const reply = try parkedReply("r");
    defer std.heap.c_allocator.free(reply);
    try testing.expect(claimBlock(.{ .index = 0, .generation = 1 }, reply) == null);
    for (blocks) |state| try testing.expect(state == .owed);
}

test "the deadline answers before the page's own request timeout" {
    // `craft-bridge.js` and `_invoke` give up after 30 s with a message that
    // names no framework and no code. (`craft.siri.remove` never gives up, so
    // for it this deadline is the only answer there is.)
    try testing.expect(removal_deadline_ms < 30_000);
}
