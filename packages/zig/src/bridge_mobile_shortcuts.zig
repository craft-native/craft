//! The home-screen quick-action pair of the `mobile` namespace:
//! `setShortcuts`, `clearShortcuts`.
//!
//! These are `UIApplication.shortcutItems` — the long-press menu on the app
//! icon — not the desktop hotkeys of `bridge_shortcuts.zig`, which shares
//! nothing with this file but a word. Both actions are one property write on
//! the shared application, done synchronously: the Swift helpers wrap the
//! write in `DispatchQueue.main.async`, but the Zig dispatcher is already
//! inside the `WKScriptMessageHandler` callback on the main thread, so the
//! hop would only move the reply away from the frame that holds this call's
//! id. No completion handler exists anywhere on either path, hence no
//! `ios_async` ticket.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **`setShortcuts` resolves with the object `{"count":N}`** — the Swift
//!    dictionary literal — and `clearShortcuts` resolves with the **bare JSON
//!    fragment `true`** (Swift serialises with `.fragmentsAllowed`, and
//!    `test-bridges.html` renders `'Shortcuts cleared: ' + result`, so the
//!    bare boolean is load-bearing).
//!  - **An empty `shortcuts` array is a valid request**: it installs an empty
//!    list and replies `{"count":0}`, exactly as Swift does. It is not folded
//!    into `clearShortcuts`.
//!  - **A JSON `null` `subtitle`/`iconName`/`userInfo` means "none"**, the
//!    same answer as omitting the field — Swift's `as? String` turns `NSNull`
//!    into `nil`, and `JSON.stringify` keeps an explicit null where it drops
//!    an undefined.
//!
//! ## What is deliberately not carried across
//!
//! **Swift's silent hang.** The dispatcher arm is `if let shortcuts = ... as?
//! [[String: Any]]` with no `else`: a missing or non-array `shortcuts` replies
//! nothing and the page's promise never settles. Every path here ends in a
//! reply or an error, per the precedent `bridge_mobile_storage.zig` set.
//!
//! **Swift's silent element skip.** An element missing `type` or `title` is
//! `continue`d and the reply reports a smaller `count`. Skipping is dropping a
//! payload element under a success, so a malformed element refuses the whole
//! batch with `InvalidParameter` instead — which also means `count` always
//! equals the length of the array the page sent, never a quiet subset. The
//! same goes for a `subtitle`/`iconName`/`userInfo` of the wrong type, which
//! Swift's `as?` casts would drop while installing the rest of the shortcut.
//!
//! **A NUL byte in `type`, `title`, `subtitle` or `iconName`.** All four reach
//! UIKit through `stringWithUTF8String:`, which stops at the first NUL, and
//! `type` in particular is the identity the app would match on activation — a
//! truncated one is a different shortcut than the page named, reported as
//! installed. Refused with `InvalidParameter`; see `requireNulFree`.
//! `userInfo` string values are exempt: they travel as escaped JSON bytes
//! through `NSJSONSerialization` and keep their NULs whole.
//!
//! ## `userInfo` is carried, not dropped
//!
//! Nothing in the repo sends it, but the injected JS contract permits it and
//! Swift stores it, so silently discarding it here would be the exact
//! dropped-field bug this migration exists to remove. The element's sub-JSON
//! is re-serialised and handed to `NSJSONSerialization`, which yields the same
//! Foundation types (`NSString`/`NSNumber`/`NSArray`/`NSDictionary`/`NSNull`)
//! that Swift's `as? [String: NSSecureCoding]` cast admits.
//!
//! ## The gap that is real and is not this file's to close
//!
//! Installing shortcuts is honest — they appear in the long-press menu — but
//! **tapping one never reaches the page**: the injected JS registers
//! `craftShortcut` listeners, and no template implements
//! `application(_:performActionFor:completionHandler:)` or any scene-delegate
//! equivalent, so nothing ever dispatches that event. Tapping launches or
//! foregrounds the app and stops there. Pre-existing, identical under the
//! Swift shim, and outside these two actions' scope.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;

/// The same type as `objc.id` — `?*anyopaque` — spelled locally.
///
/// `objc_runtime.objc` is an empty struct off Darwin, and a function
/// *signature* is analysed even when a comptime platform guard makes its body
/// unreachable, so naming `objc.id` in module-level signatures would break the
/// host build. It stays a single optional pointer, never `?objc.id`: a double
/// optional is illegal in a `callconv(.c)` type.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// The conformance ratchet matches the two lists by string in both directions.
pub const A = struct {
    pub const set_shortcuts = "setShortcuts";
    pub const clear_shortcuts = "clearShortcuts";
};

/// Both `.result`: each Swift path terminates in exactly one
/// `resolveCallback`, and both injected JS methods return promises the page
/// awaits. `clearShortcuts` resolving with a bare fragment is still a result —
/// `.none` would tell an app the action is fire-and-forget and strand the
/// caller for the whole request timeout.
///
/// Both `.live`: everything each action does is one main-thread property
/// write, fully reachable from Zig.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.set_shortcuts, .reply = .result },
    .{ .name = A.clear_shortcuts, .reply = .result },
};

/// One shortcut, after validation. Slices borrow from the parsed payload,
/// which outlives every use — the whole handler runs inside one dispatch.
///
/// The field is `@"type"` and not something prettier because the wire name is
/// the contract: the injected JS posts `type`, the Swift shim reads
/// `shortcut["type"]`, and a rename here is exactly the field-name drift that
/// broke `craft.fs.writeFile`.
const Shortcut = struct {
    type: []const u8,
    title: []const u8,
    subtitle: ?[]const u8 = null,
    icon_name: ?[]const u8 = null,
    /// Kept as the parsed JSON value; converted to Foundation objects only on
    /// Darwin, at install time. Always `.object` when non-null.
    user_info: ?std.json.Value = null,
};

/// Which handler an action selects, or null for one this namespace does not
/// serve. Split out from `handleMessage` so the table-versus-dispatch
/// agreement can be asserted on a host, where `UIApplication` does not exist.
const Route = enum { set_shortcuts, clear_shortcuts };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.set_shortcuts)) return .set_shortcuts;
    if (std.mem.eql(u8, action, A.clear_shortcuts)) return .clear_shortcuts;
    return null;
}

pub const ShortcutsBridge = struct {
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
            .set_shortcuts => self.setShortcuts(data),
            .clear_shortcuts => self.clearShortcuts(),
        };
    }

    /// Replace the app's quick actions with the batch the page sent.
    fn setShortcuts(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const shortcuts = try parseShortcuts(self.allocator, parsed.value);
        defer self.allocator.free(shortcuts);

        try installShortcuts(self.allocator, shortcuts);

        // Counted from what Zig validated and installed, never read back from
        // `shortcutItems` — Swift counts its own local array the same way. The
        // whole batch installs or nothing does, so this is always the length
        // the page sent.
        var buf: [40]u8 = undefined;
        const json = try countReply(&buf, shortcuts.len);
        bridge_error.sendResultToJS(self.allocator, A.set_shortcuts, json);
    }

    /// Remove all quick actions.
    ///
    /// `data` is deliberately not parsed: the injected JS posts no payload
    /// (`ios_dispatch.payloadOf` normalises the absent `d` to `"{}"`), Swift
    /// dispatches unconditionally, and there is no field whose absence or
    /// shape could change what "clear" means.
    fn clearShortcuts(self: *Self) !void {
        try uninstallShortcuts();
        bridge_error.sendResultToJS(self.allocator, A.clear_shortcuts, clear_reply);
    }
};

/// The `clearShortcuts` resolution: Swift's `resolveCallback(_, result: true)`
/// under `.fragmentsAllowed` — a bare boolean, not `{"success":true}`. The
/// page string-concatenates the resolved value, so the fragment is the shape.
const clear_reply = "true";

/// Parse `d`, distinguishing a bad payload from a failed allocation —
/// `OutOfMemory` propagates as itself so nobody debugs their own good JSON.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
}

/// The validated batch, or the reason it cannot be installed. Pure, so the
/// host tests can pin every outcome Swift collapsed into a silent hang, a
/// silent skip, or a silent `as?`-cast drop.
///
/// A missing `shortcuts` is `MissingData` (the required field is absent), a
/// present-but-wrong one — including JSON `null` — is `InvalidParameter`,
/// matching `bridge_mobile_storage.zig`'s split. Swift replies *nothing* in
/// both cases and the page hangs; the divergence is the module's headline.
fn parseShortcuts(allocator: std.mem.Allocator, payload: std.json.Value) ![]Shortcut {
    const object = switch (payload) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    const field = object.get("shortcuts") orelse return bridge_error.BridgeError.MissingData;
    const array = switch (field) {
        .array => |a| a,
        else => return bridge_error.BridgeError.InvalidParameter,
    };

    var out: std.ArrayListUnmanaged(Shortcut) = .empty;
    errdefer out.deinit(allocator);
    for (array.items) |element| {
        try out.append(allocator, try parseShortcut(element));
    }
    return out.toOwnedSlice(allocator);
}

/// One element. Everything wrong with it is `InvalidParameter` — the
/// malformed thing is an entry inside the `shortcuts` argument, not a missing
/// top-level field — and it refuses the batch rather than being skipped; the
/// module comment carries the argument.
fn parseShortcut(element: std.json.Value) !Shortcut {
    const object = switch (element) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidParameter,
    };

    var shortcut = Shortcut{
        .type = try requiredString(object, "type"),
        .title = try requiredString(object, "title"),
    };
    shortcut.subtitle = try optionalString(object, "subtitle");
    shortcut.icon_name = try optionalString(object, "iconName");

    if (object.get("userInfo")) |info| {
        shortcut.user_info = switch (info) {
            .null => null,
            // Kept whole; strings inside may carry NULs, which the
            // NSJSONSerialization route preserves — no `requireNulFree` here.
            .object => info,
            // Swift's `as? [String: NSSecureCoding]` turns anything else into
            // nil and installs the shortcut without it, reported as success.
            else => return bridge_error.BridgeError.InvalidParameter,
        };
    }

    return shortcut;
}

/// A field Swift `guard`s on: present and a string, or the batch is refused.
fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const field = object.get(name) orelse return bridge_error.BridgeError.InvalidParameter;
    const s = switch (field) {
        .string => |v| v,
        else => return bridge_error.BridgeError.InvalidParameter,
    };
    try requireNulFree(s);
    return s;
}

/// A field Swift reads with `as? String`: absent and JSON `null` both mean
/// "none"; any other non-string is refused rather than dropped.
fn optionalString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const field = object.get(name) orelse return null;
    return switch (field) {
        .null => null,
        .string => |v| blk: {
            try requireNulFree(v);
            break :blk v;
        },
        else => bridge_error.BridgeError.InvalidParameter,
    };
}

/// Refuse a string carrying the one byte `stringWithUTF8String:` cannot
/// survive. `\u0000` is a legal JSON escape and `std.json` decodes it to the
/// byte, so a page can reach this. Without the check, a `type` of
/// `"open\u0000debug"` would install the shortcut whose activation identity is
/// `"open"` and reply `{"count":1}` as if the asked-for one existed.
fn requireNulFree(s: []const u8) !void {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return bridge_error.BridgeError.InvalidParameter;
}

/// `{"count":N}` — the Swift dictionary literal, verbatim. `bufPrint` is safe
/// here where storage needed escaping: nothing page-controlled is echoed.
fn countReply(buf: []u8, count: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"count\":{d}}}", .{count});
}

/// Re-serialise a parsed value to JSON bytes for `NSJSONSerialization`.
///
/// `std.json.Value` does not remember its source span, so this walk exists.
/// Strings and keys go through `bridge_error.appendJsonEscaped`, which escapes
/// every control byte — `bridge_handoff.zig`'s older copy of this walk misses
/// NUL, and an unescaped control byte makes the bytes invalid JSON that
/// Foundation would refuse, turning a legal payload into a refusal.
///
/// A non-finite float is refused *here*, purely and testably: `{d}` would
/// render `inf`, which is not JSON, and the failure would otherwise surface as
/// an opaque nil from Foundation.
fn serializeJsonValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: std.json.Value,
) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var buf: [24]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{i}));
        },
        .float => |f| {
            if (!std.math.isFinite(f)) return bridge_error.BridgeError.InvalidParameter;
            // `{d}` renders decimal notation, never scientific, and a finite
            // f64 can need up to `bufferSize(.decimal, f64)` (347) bytes —
            // 1e300 alone is 301 digits. A smaller buffer turns that legal
            // JSON number into a NoSpaceLeft refusal.
            var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{f}));
        },
        // Only produced under parse options this module does not use, but
        // carrying it costs one line and dropping it would be a silent hole.
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| {
            try out.append(allocator, '"');
            try bridge_error.appendJsonEscaped(allocator, out, s);
            try out.append(allocator, '"');
        },
        .array => |items| {
            try out.append(allocator, '[');
            for (items.items, 0..) |item, i| {
                if (i > 0) try out.append(allocator, ',');
                try serializeJsonValue(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |obj| {
            try out.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.append(allocator, ',');
                first = false;
                try out.append(allocator, '"');
                try bridge_error.appendJsonEscaped(allocator, out, entry.key_ptr.*);
                try out.appendSlice(allocator, "\":");
                try serializeJsonValue(allocator, out, entry.value_ptr.*);
            }
            try out.append(allocator, '}');
        },
    }
}

// =============================================================================
// The Objective-C half. Main thread throughout — see the module comment.
// =============================================================================

/// `[UIApplication sharedApplication]`, non-nil or an error.
///
/// Resolved before anything is built so a process with no shared application —
/// an app extension, or one that has not reached `UIApplicationMain` — fails
/// early instead of assembling items nothing can install.
fn sharedApplication() !*anyopaque {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const UIApplication = objc.objc_getClass("UIApplication") orelse return error.ClassNotFound;
    const sel_shared = objc.sel_registerName("sharedApplication") orelse return error.SelectorNotFound;
    return objc.msgSendId(UIApplication, sel_shared) orelse error.NoSharedApplication;
}

/// Build the item array and assign it. All-or-nothing: any element that fails
/// aborts before `setShortcutItems:` is reached, leaving the previous set
/// installed — never a partial batch reported whole.
fn installShortcuts(allocator: std.mem.Allocator, shortcuts: []const Shortcut) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const app = try sharedApplication();

    const NSMutableArray = objc.objc_getClass("NSMutableArray") orelse return error.ClassNotFound;
    const sel_array = objc.sel_registerName("array") orelse return error.SelectorNotFound;
    const sel_add = objc.sel_registerName("addObject:") orelse return error.SelectorNotFound;
    // Autoreleased; on the error paths below the pool drains it, items and
    // all, at the end of this run-loop turn.
    const items = objc.msgSendId(NSMutableArray, sel_array);
    if (items == null) return error.NativeCallFailed;

    for (shortcuts) |shortcut| {
        // Non-null by construction — `addObject:` raises an uncatchable
        // NSInvalidArgumentException on nil, which is why `makeShortcutItem`
        // returns `*anyopaque` and not `Id`.
        const item = try makeShortcutItem(allocator, shortcut);
        objc.msgSendVoid1(items, sel_add, item);
        // `alloc`/`init` handed it over at +1; the array's retain is now the
        // one keeping it alive. Without this, one item leaks per shortcut per
        // call.
        objc.release(item);
    }

    const sel_set = objc.sel_registerName("setShortcutItems:") orelse return error.SelectorNotFound;
    objc.msgSendVoid1(app, sel_set, items);
}

/// `UIApplication.shared.shortcutItems = nil`, which is how "no shortcuts" is
/// spelled — distinct from assigning an empty array, though UIKit renders both
/// as an empty menu.
fn uninstallShortcuts() !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const app = try sharedApplication();
    const sel_set = objc.sel_registerName("setShortcutItems:") orelse return error.SelectorNotFound;
    objc.msgSendVoid1(app, sel_set, @as(Id, null));
}

/// One `UIApplicationShortcutItem`, at +1 and never nil.
///
/// `initWithType:localizedTitle:...` declares `type` and `localizedTitle`
/// nonnull and raises on a nil — so the `createNSString` results are checked
/// even though `std.json` has already validated the bytes as UTF-8, because a
/// nil into that initialiser is an uncatchable crash, not an error.
fn makeShortcutItem(allocator: std.mem.Allocator, shortcut: Shortcut) !*anyopaque {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const ns_type = try objc.createNSString(shortcut.type, allocator);
    if (ns_type == null) return bridge_error.BridgeError.InvalidParameter;
    const ns_title = try objc.createNSString(shortcut.title, allocator);
    if (ns_title == null) return bridge_error.BridgeError.InvalidParameter;

    var ns_subtitle: Id = null;
    if (shortcut.subtitle) |subtitle| {
        ns_subtitle = try objc.createNSString(subtitle, allocator);
        if (ns_subtitle == null) return bridge_error.BridgeError.InvalidParameter;
    }

    var icon: Id = null;
    if (shortcut.icon_name) |name| icon = try makeIcon(allocator, name);

    var user_info: Id = null;
    if (shortcut.user_info) |info| user_info = try toFoundationObject(allocator, info);

    const UIApplicationShortcutItem = objc.objc_getClass("UIApplicationShortcutItem") orelse
        return error.ClassNotFound;
    // Registered before `alloc` so a failed lookup cannot leak the +1 object.
    const sel_init = objc.sel_registerName("initWithType:localizedTitle:localizedSubtitle:icon:userInfo:") orelse
        return error.SelectorNotFound;

    const allocated = try objc.alloc(UIApplicationShortcutItem);
    if (allocated == null) return error.NativeCallFailed;

    // subtitle, icon and userInfo are declared nullable — nil is the "none"
    // the page asked for, not a missing argument.
    const InitFn = *const fn (Id, objc.SEL, Id, Id, Id, Id, Id) callconv(.c) Id;
    const init_fn: InitFn = @ptrCast(&objc.objc_msgSend);
    const item = init_fn(allocated, sel_init, ns_type, ns_title, ns_subtitle, icon, user_info);
    // A nil from init means init consumed the allocation (the ObjC
    // convention), so there is nothing to release here.
    return item orelse error.NativeCallFailed;
}

/// `+[UIApplicationShortcutIcon iconWithSystemImageName:]` (iOS 13+),
/// autoreleased.
///
/// The honesty limit: UIKit returns a real icon object even for a bogus SF
/// Symbols name — it just renders blank — and exposes no validation API, so a
/// typo'd `iconName` cannot be caught here by anyone. The nil check guards the
/// call convention, not the name.
fn makeIcon(allocator: std.mem.Allocator, name: []const u8) !*anyopaque {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const UIApplicationShortcutIcon = objc.objc_getClass("UIApplicationShortcutIcon") orelse
        return error.ClassNotFound;
    const sel_icon = objc.sel_registerName("iconWithSystemImageName:") orelse return error.SelectorNotFound;

    const ns_name = try objc.createNSString(name, allocator);
    if (ns_name == null) return bridge_error.BridgeError.InvalidParameter;

    return objc.msgSendId1(UIApplicationShortcutIcon, sel_icon, ns_name) orelse error.NativeCallFailed;
}

/// A parsed JSON object as the Foundation containers Swift's
/// `as? [String: NSSecureCoding]` admits, via
/// `+[NSJSONSerialization JSONObjectWithData:options:error:]` (autoreleased).
///
/// The round trip through bytes is the honest route: NSString keys and values
/// built this way keep embedded NULs that `stringWithUTF8String:` would
/// truncate, and every Foundation type it can produce conforms to
/// NSSecureCoding. A nil back is `InvalidParameter` — the caller's `userInfo`
/// holds something JSON cannot carry — with the log naming the field, since
/// the error code alone cannot.
fn toFoundationObject(allocator: std.mem.Allocator, value: std.json.Value) !*anyopaque {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);
    try serializeJsonValue(allocator, &bytes, value);

    const NSData = objc.objc_getClass("NSData") orelse return error.ClassNotFound;
    const sel_data = objc.sel_registerName("dataWithBytes:length:") orelse return error.SelectorNotFound;
    const data = objc.msgSendId2(NSData, sel_data, bytes.items.ptr, @as(c_ulong, @intCast(bytes.items.len)));
    if (data == null) return error.NativeCallFailed;

    const NSJSONSerialization = objc.objc_getClass("NSJSONSerialization") orelse return error.ClassNotFound;
    const sel_parse = objc.sel_registerName("JSONObjectWithData:options:error:") orelse
        return error.SelectorNotFound;
    const ParseFn = *const fn (Id, objc.SEL, Id, c_ulong, Id) callconv(.c) Id;
    const parse_fn: ParseFn = @ptrCast(&objc.objc_msgSend);
    return parse_fn(NSJSONSerialization, sel_parse, data, 0, null) orelse {
        std.log.warn("a shortcut's userInfo did not survive NSJSONSerialization; refusing the batch", .{});
        return bridge_error.BridgeError.InvalidParameter;
    };
}

// =============================================================================
// Tests. Host-only by construction: everything that decides what the page
// sees — routing, validation, reply shaping, the userInfo byte walk — is a
// pure function beside the two UIKit writes.
// =============================================================================

const testing = std.testing;

test "every declared action is one the dispatcher routes" {
    for (capability_actions) |decl| {
        if (routeFor(decl.name) == null) {
            std.debug.print("declared action '{s}' does not route\n", .{decl.name});
            return error.DeclaredActionDoesNotRoute;
        }
    }
}

test "every route the dispatcher has is a declared action" {
    // Each declaration must claim a distinct route and every route must be
    // claimed — counting alone would let two rows share one route while
    // another went undeclared.
    var claimed = std.mem.zeroes([std.enums.values(Route).len]bool);
    for (capability_actions) |decl| {
        const route = routeFor(decl.name) orelse return error.DeclaredActionDoesNotRoute;
        const slot = @backingInt(route);
        if (claimed[slot]) return error.TwoDeclarationsShareARoute;
        claimed[slot] = true;
    }
    for (claimed) |taken| {
        if (!taken) return error.RouteNotDeclared;
    }
}

test "both actions reply with a result the page awaits" {
    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "the action names are the ones the Swift dispatcher answers" {
    // The wire contract, spelled out: the conformance scan compares `A`
    // against `CraftApp.swift`'s case labels and catches one drifting, but not
    // both renamed in step.
    try testing.expectEqualStrings("setShortcuts", A.set_shortcuts);
    try testing.expectEqualStrings("clearShortcuts", A.clear_shortcuts);
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = ShortcutsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // The Swift *helper* names, which are not action names — accepting one
    // would serve an action the spec's dispatcher does not have.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("setAppShortcuts", "{\"shortcuts\":[]}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("clearAppShortcuts", "{}"),
    );
    // Casing is how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("setshortcuts", "{}"),
    );
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = ShortcutsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.set_shortcuts, "{not json"),
    );
}

test "a missing shortcuts field is an answer on every platform, not a hang" {
    // The headline divergence: Swift's `if let ... as? [[String: Any]]` has no
    // `else`, so this exact payload leaves the page's promise unsettled
    // forever. Validation also runs before any platform gate, so the page gets
    // the specific error rather than UnsupportedPlatform wherever this runs.
    var bridge = ShortcutsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.set_shortcuts, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.set_shortcuts, "{\"shortcuts\":null}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.set_shortcuts, "{\"shortcuts\":\"new-message\"}"),
    );
}

fn expectParseError(json: []const u8, expected: anyerror) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, parseShortcuts(testing.allocator, parsed.value));
}

test "the fields the injected JS sends are the fields that are read" {
    // test-bridges.html's exact batch, plus a userInfo the contract permits.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"shortcuts":[
        \\  {"type":"new-message","title":"New Message","subtitle":"Start composing","iconName":"square.and.pencil"},
        \\  {"type":"search","title":"Search","iconName":"magnifyingglass"},
        \\  {"type":"settings","title":"Settings","iconName":"gear","userInfo":{"tab":"general"}}
        \\]}
    , .{});
    defer parsed.deinit();

    const shortcuts = try parseShortcuts(testing.allocator, parsed.value);
    defer testing.allocator.free(shortcuts);

    try testing.expectEqual(@as(usize, 3), shortcuts.len);
    try testing.expectEqualStrings("new-message", shortcuts[0].type);
    try testing.expectEqualStrings("New Message", shortcuts[0].title);
    try testing.expectEqualStrings("Start composing", shortcuts[0].subtitle.?);
    try testing.expectEqualStrings("square.and.pencil", shortcuts[0].icon_name.?);
    try testing.expect(shortcuts[0].user_info == null);
    // The second element sends no subtitle, which must be "none", not "".
    try testing.expect(shortcuts[1].subtitle == null);
    try testing.expectEqualStrings("magnifyingglass", shortcuts[1].icon_name.?);
    // userInfo rides along whole rather than being dropped.
    const info = shortcuts[2].user_info orelse return error.UserInfoDropped;
    try testing.expectEqualStrings("general", info.object.get("tab").?.string);
}

test "an empty batch is a valid request, not an error and not a clear" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"shortcuts\":[]}", .{});
    defer parsed.deinit();

    const shortcuts = try parseShortcuts(testing.allocator, parsed.value);
    defer testing.allocator.free(shortcuts);
    try testing.expectEqual(@as(usize, 0), shortcuts.len);
}

test "a malformed element refuses the batch instead of being skipped" {
    // Swift `continue`s these and reports a smaller count — an element
    // silently dropped under a success. The whole batch is refused so `count`
    // can never quietly disagree with what the page sent.
    try expectParseError(
        "{\"shortcuts\":[{\"title\":\"No Type\"}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"no-title\"}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
    // A good element does not buy a bad one a pass.
    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"ok\",\"title\":\"Ok\"},42]}",
        bridge_error.BridgeError.InvalidParameter,
    );
}

test "a required field of the wrong type is refused, not coerced" {
    try expectParseError(
        "{\"shortcuts\":[{\"type\":7,\"title\":\"T\"}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"t\",\"title\":null}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
}

test "null and absent optionals both mean none; wrong types are refused" {
    // Swift's `as? String` folds NSNull and a number to nil alike — the first
    // is the page saying "none", the second is a field silently dropped while
    // the shortcut installs anyway.
    var parsed = try std.json.parseFromSlice(testing_value_type, testing.allocator, "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"T\",\"subtitle\":null,\"iconName\":null,\"userInfo\":null}]}", .{});
    defer parsed.deinit();

    const shortcuts = try parseShortcuts(testing.allocator, parsed.value);
    defer testing.allocator.free(shortcuts);
    try testing.expect(shortcuts[0].subtitle == null);
    try testing.expect(shortcuts[0].icon_name == null);
    try testing.expect(shortcuts[0].user_info == null);

    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"T\",\"subtitle\":3}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"T\",\"iconName\":[]}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"T\",\"userInfo\":\"not an object\"}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
}

// Spelled once: `std.json.Value` as a type argument inside a string-heavy test.
const testing_value_type = std.json.Value;

test "a NUL in any UIKit-bound string is refused, not truncated" {
    // All four reach UIKit via `stringWithUTF8String:`, which stops at the
    // first NUL; `type` is the identity a future activation handler would
    // match on, so a truncated one is a different shortcut reported installed.
    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"a\\u0000b\",\"title\":\"T\"}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"a\\u0000b\"}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"T\",\"subtitle\":\"a\\u0000b\"}]}",
        bridge_error.BridgeError.InvalidParameter,
    );
    try expectParseError(
        "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"T\",\"iconName\":\"a\\u0000b\"}]}",
        bridge_error.BridgeError.InvalidParameter,
    );

    // A NUL inside userInfo is *kept*: that path never crosses a C string, so
    // refusing it would drop a value the handler can carry perfectly well.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"T\",\"userInfo\":{\"k\":\"a\\u0000b\"}}]}", .{});
    defer parsed.deinit();
    const shortcuts = try parseShortcuts(testing.allocator, parsed.value);
    defer testing.allocator.free(shortcuts);
    const info = shortcuts[0].user_info orelse return error.UserInfoDropped;
    try testing.expectEqualSlices(u8, &[_]u8{ 'a', 0, 'b' }, info.object.get("k").?.string);
}

test "a payload that is not an object is bad JSON, not a missing field" {
    try expectParseError("[]", bridge_error.BridgeError.InvalidJSON);
    try expectParseError("\"shortcuts\"", bridge_error.BridgeError.InvalidJSON);
}

test "the count reply is the Swift dictionary verbatim, and is JSON" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("{\"count\":0}", try countReply(&buf, 0));
    try testing.expectEqualStrings("{\"count\":3}", try countReply(&buf, 3));

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, try countReply(&buf, 3), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("count").?.integer);
}

test "the clear reply is the bare fragment true, not an object" {
    // Swift resolves with `.fragmentsAllowed`, and the page renders
    // 'Shortcuts cleared: ' + result — wrapping this in {"success":true} would
    // "fix" it into displaying [object Object].
    try testing.expectEqualStrings("true", clear_reply);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, clear_reply, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .bool);
    try testing.expect(parsed.value.bool);
}

test "the userInfo byte walk survives a std.json round trip" {
    const source =
        \\{"s":"quo\"te\\slash","n":-7,"f":1.5,"b":true,"z":null,"a":[1,"two",{"deep":false}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, source, .{});
    defer parsed.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serializeJsonValue(testing.allocator, &out, parsed.value);

    var round = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer round.deinit();
    const obj = round.value.object;
    try testing.expectEqualStrings("quo\"te\\slash", obj.get("s").?.string);
    try testing.expectEqual(@as(i64, -7), obj.get("n").?.integer);
    try testing.expectEqual(@as(f64, 1.5), obj.get("f").?.float);
    try testing.expect(obj.get("b").?.bool);
    try testing.expect(obj.get("z").? == .null);
    try testing.expectEqualStrings("two", obj.get("a").?.array.items[1].string);
    try testing.expect(!obj.get("a").?.array.items[2].object.get("deep").?.bool);
}

test "the byte walk escapes control bytes Foundation would refuse raw" {
    // The exact miss in bridge_handoff.zig's older walk: a NUL emitted as the
    // raw byte is invalid JSON, so NSJSONSerialization would answer nil and a
    // legal userInfo would be refused. \u0000 in, \u0000 out.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"k\":\"a\\u0000b\"}", .{});
    defer parsed.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serializeJsonValue(testing.allocator, &out, parsed.value);

    try testing.expect(std.mem.indexOf(u8, out.items, "\\u0000") != null);
    try testing.expect(std.mem.indexOfScalar(u8, out.items, 0) == null);
}

test "a float of extreme magnitude is rendered whole, not refused" {
    // 1e300 is 301 decimal digits under `{d}` and 5e-324 — the smallest
    // subnormal — is 326; both are legal JSON that std.json parses to
    // `.float`. The 64-byte buffer this pins against answered them
    // NoSpaceLeft, which reached the page as NativeCallFailed for a lawful
    // userInfo.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"big\":1e300,\"tiny\":5e-324}", .{});
    defer parsed.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serializeJsonValue(testing.allocator, &out, parsed.value);

    // Still JSON after the digits stretch. The 301-digit rendering of 1e300
    // is integer-shaped and too wide for i64, so std.json re-reads it as
    // `.number_string` — its spelling for a number wider than its scalars;
    // Foundation's parser has no such split and reads it as one number.
    var round = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer round.deinit();
    const big = round.value.object.get("big").?.number_string;
    try testing.expectEqual(@as(usize, 301), big.len);
    try testing.expectEqual(@as(u8, '1'), big[0]);
    // The subnormal renders as 0.00…05, floats on the re-parse, and Ryu's
    // shortest digits make the value exact.
    try testing.expectEqual(@as(f64, 5e-324), round.value.object.get("tiny").?.float);
}

test "a non-finite float is refused before Foundation sees it" {
    // std.json parses 1e999 to inf; `{d}` would render it as `inf`, which is
    // not JSON, and the failure would surface as an opaque nil three calls
    // later. Refusing here keeps the diagnosis one frame deep.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        serializeJsonValue(testing.allocator, &out, .{ .float = std.math.inf(f64) }),
    );
}

// The remaining tests exercise the Objective-C half against the live runtime —
// libobjc and Foundation on a macOS host, no UIKit and no device required.

test "userInfo becomes a Foundation dictionary with its NUL intact" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"route\":\"a\\u0000b\",\"depth\":3}", .{});
    defer parsed.deinit();

    const dict = try toFoundationObject(testing.allocator, parsed.value);
    try testing.expect(try isKindOf(dict, "NSDictionary"));

    // The value under "route" must be an NSString of *three* characters —
    // proving the JSON-bytes route carries what `stringWithUTF8String:`
    // truncates, which is the whole reason userInfo takes it.
    const route = try dictValueForKey(testing.allocator, dict, "route");
    try testing.expect(route != null);
    try testing.expect(try isKindOf(route, "NSString"));
    try testing.expectEqual(@as(usize, 3), try nsStringLength(route));
}

test "a missing UIApplication is reported rather than read past" {
    // macOS links no UIKit, which is the same shape as an app extension or a
    // pre-UIApplicationMain process on a device: `objc_getClass` answers null
    // and the handler must error, not install into nothing or fabricate
    // `true`. Pinned to macOS — on iOS the class exists and the right answer
    // is a real install.
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;

    var bridge = ShortcutsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(error.ClassNotFound, bridge.handleMessage(A.clear_shortcuts, "{}"));
    try testing.expectError(
        error.ClassNotFound,
        bridge.handleMessage(A.set_shortcuts, "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"T\"}]}"),
    );
}

test "off Darwin the platform gate answers instead of crashing" {
    if (builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    var bridge = ShortcutsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.set_shortcuts, "{\"shortcuts\":[{\"type\":\"t\",\"title\":\"T\"}]}"),
    );
    try testing.expectError(error.UnsupportedPlatform, bridge.handleMessage(A.clear_shortcuts, "{}"));
}

/// `-[NSObject isKindOfClass:]` for the host tests above.
fn isKindOf(obj: Id, class_name: [*:0]const u8) !bool {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const cls = objc.objc_getClass(class_name) orelse return error.ClassNotFound;
    const sel_kind = objc.sel_registerName("isKindOfClass:") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, objc.SEL, Id) callconv(.c) bool;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(obj, sel_kind, cls);
}

/// `-[NSDictionary objectForKey:]` for the host tests above.
fn dictValueForKey(allocator: std.mem.Allocator, dict: Id, key: []const u8) !Id {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const ns_key = try objc.createNSString(key, allocator);
    if (ns_key == null) return error.NativeCallFailed;
    const sel_obj = objc.sel_registerName("objectForKey:") orelse return error.SelectorNotFound;
    return objc.msgSendId1(dict, sel_obj, ns_key);
}

/// `-[NSString length]` — UTF-16 code units, which is what makes it the right
/// probe for "did the NUL survive": "a\x00b" is three either way.
fn nsStringLength(ns: Id) !usize {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel_length = objc.sel_registerName("length") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, objc.SEL) callconv(.c) c_ulong;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return @intCast(func(ns, sel_length));
}
