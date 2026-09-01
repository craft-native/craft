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

    /// Delete a donated activity, and answer when the deletion is done.
    ///
    /// `deleteSavedUserActivitiesWithPersistentIdentifiers:completionHandler:`
    /// takes a `void (^)(void)`, and Swift replies from inside it. Replying
    /// before it fired would tell the page a shortcut is gone while Siri can
    /// still match it — the window is small and the claim is still false.
    fn removeShortcut(self: *Self, data: []const u8) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        var fields = try readFields(self.allocator, data, .{ .phrase = false });
        defer fields.deinit(self.allocator);

        const NSUserActivity = objc.objc_getClass("NSUserActivity") orelse
            return BridgeError.PlatformNotSupported;
        const identifiers = try singletonArray(self.allocator, fields.action);

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

        publishPendingCall(ticket, reply);

        const sel = objc.sel_registerName(
            "deleteSavedUserActivitiesWithPersistentIdentifiers:completionHandler:",
        ) orelse return BridgeError.NativeCallFailed;
        const DeleteFn = *const fn (objc.Class, objc.SEL, Id, *anyopaque) callconv(.c) void;
        const deleteFn: DeleteFn = @ptrCast(&objc.objc_msgSend);
        deleteFn(NSUserActivity, sel, identifiers, doneBlock(ticket));
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

    const action = try requiredString(allocator, object, "action");
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

/// The reply a slot's completion will send.
///
/// `void (^)(void)` carries nothing — not even a success flag — so everything
/// the reply needs is shaped before the call and parked here. The ticket is
/// stored rather than rebuilt from the slot index, because a `Ticket` is an
/// index *and* a generation and inventing the generation would defeat the
/// check that stops a late completion answering whoever holds the slot now.
const PendingCall = struct {
    ticket: ios_async.Ticket,
    /// Owned, `c_allocator`. Freed when the completion fires.
    reply: []u8,
};

var pending_calls: [ios_async.max_in_flight]?PendingCall = @splat(null);
var pending_mutex: compat_mutex.Mutex = .{};

fn publishPendingCall(ticket: ios_async.Ticket, reply: []u8) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls[ticket.index] = .{ .ticket = ticket, .reply = reply };
}

/// Read and clear. Clearing is what makes a second fire of the same completion
/// a no-op rather than a second reply and a double free.
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

fn makeDoneInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const DoneBlock) callconv(.c) void {
            deletionFired(index);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeDoneBlocks() [ios_async.max_in_flight]DoneBlock {
    var out: [ios_async.max_in_flight]DoneBlock = undefined;
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

var done_blocks: [ios_async.max_in_flight]DoneBlock =
    if (is_darwin) makeDoneBlocks() else undefined;

fn doneBlock(ticket: ios_async.Ticket) *anyopaque {
    return @ptrCast(&done_blocks[ticket.index]);
}

/// Runs on whatever queue Foundation chose. `ios_async.deliverJson` copies the
/// payload and hops to the main queue, where `evaluateJavaScript:` is legal.
fn deletionFired(index: u5) void {
    if (!is_darwin) return;

    const call = takePendingCall(index) orelse {
        std.log.warn(
            "removeSiriShortcut completion fired for slot {d} with no call recorded; ignored",
            .{index},
        );
        return;
    };
    defer std.heap.c_allocator.free(call.reply);

    ios_async.deliverJson(call.ticket, call.reply);
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
        "{\"action\":\"openVault\",\"phrase\":\"open my vault\"}",
        .{ .phrase = true },
    );
    defer fields.deinit(testing.allocator);
    try testing.expectEqualStrings("openVault", fields.action);
    try testing.expectEqualStrings("open my vault", fields.phrase.?);

    try testing.expectError(BridgeError.MissingData, readFields(
        testing.allocator,
        "{\"action\":\"openVault\"}",
        .{ .phrase = true },
    ));
    try testing.expectError(BridgeError.MissingData, readFields(
        testing.allocator,
        "{\"phrase\":\"open my vault\"}",
        .{ .phrase = true },
    ));
    try testing.expectError(BridgeError.InvalidParameter, readFields(
        testing.allocator,
        "{\"action\":\"\",\"phrase\":\"p\"}",
        .{ .phrase = true },
    ));
    try testing.expectError(BridgeError.InvalidParameter, readFields(
        testing.allocator,
        "{\"action\":3,\"phrase\":\"p\"}",
        .{ .phrase = true },
    ));
}

test "a removal needs only the action" {
    var fields = try readFields(testing.allocator, "{\"action\":\"openVault\"}", .{ .phrase = false });
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

    var bridge = SiriBridge.init(testing.allocator);
    defer bridge.deinit();
    // No `action`, so it refuses before the ticket is taken.
    bridge.handleMessage(A.remove_siri_shortcut, "{}") catch {};

    pending_mutex.lock();
    defer pending_mutex.unlock();
    for (pending_calls) |entry| try testing.expect(entry == null);
}

test "each slot's completion block is global and has its own invoke" {
    if (!is_darwin) return error.SkipZigTest;

    for (&done_blocks) |*b| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, b.isa);
        try testing.expectEqual(BLOCK_IS_GLOBAL, b.flags);
        try testing.expectEqual(@sizeOf(DoneBlock), @as(usize, @intCast(b.descriptor.size)));
    }
    try testing.expect(done_blocks[0].invoke != done_blocks[1].invoke);
}

test "a completion for a slot with no recorded call is ignored" {
    // `void (^)(void)` carries nothing, so a stray fire has no way to identify
    // itself. Clearing the entry on take is what makes the second fire a
    // no-op rather than a double free of the parked reply.
    if (!is_darwin) return error.SkipZigTest;

    pending_mutex.lock();
    for (&pending_calls) |*entry| entry.* = null;
    pending_mutex.unlock();

    deletionFired(0);
    deletionFired(0);
}
