//! The shared-storage actions of the `mobile` namespace: `setSharedItem`,
//! `getSharedItem`, `removeSharedItem`.
//!
//! **These are Keychain Services, not `NSUserDefaults`.** The Swift helpers are
//! `setSharedKeychainItem` / `getSharedKeychainItem` / `removeSharedKeychainItem`
//! and they call `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`. There
//! is no suite name and no key namespacing anywhere in the iOS path: an item is
//! identified by `kSecClass` + `kSecAttrAccount` (+ `kSecAttrAccessGroup`), and
//! `kSecAttrService` is never set. Android is the platform that uses
//! preferences — `CraftBridge.kt.template` does `getSharedPreferences(...)` —
//! and `UserDefaults(suiteName:)` in `CraftApp.swift` belongs to `updateWidget`,
//! a different action. Adding a service attribute or a key prefix here would
//! make items written by Zig invisible to the Swift shim and vice versa, which
//! is the one thing a partial migration must not do.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **`remove` treats `errSecItemNotFound` as success**, and `get` treats it
//!    as `{"value":null}`. Only `set` has no not-found case.
//!  - **Accessibility is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`** —
//!    device-local, never iCloud-synced, unreadable while the device is locked.
//!    Set on the add only; `get` and `remove` do not mention it.
//!  - **The reply shapes are the Swift dictionary literals verbatim**:
//!    `{"success":true,"key":…}` for set/remove, `{"value":…,"key":…}` for get.
//!    `packages/typescript/types/craft.d.ts:626` claims `{set:boolean}` and
//!    `{removed:boolean}`; no implementation has ever sent either field —
//!    Swift and Android both send `success`/`key`. The runtime is the truth and
//!    the `.d.ts` is a separate, pre-existing bug, not something to satisfy by
//!    inventing fields here.
//!
//! ## What is deliberately not carried across
//!
//! **Swift's silent hang.** Each dispatcher arm is an `if let` with no `else`,
//! so a missing `key` — or a `value` that is not a string — falls out of the
//! `switch` having replied nothing at all. The page's promise then never
//! settles (the injected `_callbacks` have no timeout of their own). Every path
//! in this file ends in a reply or an error.
//!
//! **A `key` or `group` with an embedded NUL.** Swift stores it whole; this
//! file refuses it, because the route Zig has to the keychain
//! (`stringWithUTF8String:`) truncates at the NUL and would file the item under
//! a shorter name than the caller gave. See `requireNulFree`.
//!
//! **Swift's shared delete/add dictionary.** `setSharedKeychainItem` hands the
//! *same* dictionary — `kSecValueData` and `kSecAttrAccessible` included — to
//! both `SecItemDelete` and `SecItemAdd`, and discards the delete's status. If
//! `SecItemDelete` rejects a query carrying `kSecValueData`, the discarded
//! status hides it and the following add returns `errSecDuplicateItem`, i.e.
//! overwriting an existing key fails. Nothing in this repo exercises `set`
//! twice, so which way it actually goes is unproven. `keychainSet` below builds
//! the delete-scoped query first (class + account + access group, the same shape
//! `remove` already uses successfully) and only then adds the value attributes.
//! That is behaviourally identical wherever the Swift already works, and works
//! in the case where it may not.
//!
//! ## Two gaps that are real and are not papered over
//!
//! 1. **`group` cannot work on a signed device build from this toolchain.**
//!    `renderEntitlements` in `packages/ios/src/index.ts` emits
//!    `associated-domains`, `application-groups`, `healthkit` and
//!    `aps-environment` — never `keychain-access-groups`. So passing a `group`
//!    on hardware returns `errSecMissingEntitlement` (-34018) no matter which
//!    language serves the action. The simulator does not enforce keychain
//!    entitlements, so it will appear to work there and fail on device. This is
//!    a pre-existing spec gap; `failStatus` surfaces it and names it in the log
//!    rather than hiding it. Closing it means a `keychainAccessGroups` config
//!    key and an entitlements entry, which is out of scope here.
//! 2. **`packages/zig/src/keychain.zig` is not reused, on purpose.** Its Apple
//!    arms are `_ = account; return;` for set and `return null` for get, under
//!    an `if (os.tag == .macos or os.tag == .ios)` — so on Apple platforms every
//!    write silently succeeds and every read is empty. That is precisely the
//!    fabricated-success class this migration exists to remove, and building on
//!    it would inherit it. The Security calls here are written fresh.
//!
//! ## Build note
//!
//! These are the first Zig-side references to Security.framework. A generated
//! app is fine — `CraftApp.swift` does `import Security`, which autolinks it —
//! and `packages/ios/fixtures/zig-slice/build-and-run.sh` now passes
//! `-framework Security` explicitly, which it must: nothing else in the fixture
//! links it. `packages/ios/templates/project.yml.template` declares no frameworks
//! at all and relies entirely on Swift autolinking, so an app template that ever
//! drops `import Security` breaks this handler too.

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
/// unreachable, so naming `objc.id` in the signatures below would break the
/// host build. It stays a single optional pointer, never `?objc.id`, because a
/// double optional is illegal in a `callconv(.c)` type.
const Id = ?*anyopaque;

/// `CFTypeRef` is the same `?*anyopaque`, but the distinction is worth keeping
/// in the signatures: the `kSec*` values below are CoreFoundation globals that
/// happen to be toll-free bridged, not objects Zig created or owns.
const CFTypeRef = ?*anyopaque;

/// `SInt32`. Not `c_int` — the width of an `OSStatus` is fixed by the ABI, and
/// every keychain status of interest is negative.
const OSStatus = i32;

// Security.framework and CoreFoundation. C functions and CFString globals —
// there is no Objective-C messaging in `SecItem*`; the only ObjC work in this
// file is building the query dictionary and moving bytes out of the result.
// Modelled on `prefs_macos.zig`, which declares CoreFoundation the same way.
extern "c" fn SecItemAdd(attributes: CFTypeRef, result: ?*CFTypeRef) OSStatus;
extern "c" fn SecItemCopyMatching(query: CFTypeRef, result: ?*CFTypeRef) OSStatus;
extern "c" fn SecItemDelete(query: CFTypeRef) OSStatus;
extern "c" fn CFRelease(cf: CFTypeRef) void;

extern "c" const kSecClass: CFTypeRef;
extern "c" const kSecClassGenericPassword: CFTypeRef;
extern "c" const kSecAttrAccount: CFTypeRef;
extern "c" const kSecAttrAccessGroup: CFTypeRef;
extern "c" const kSecAttrAccessible: CFTypeRef;
extern "c" const kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFTypeRef;
extern "c" const kSecValueData: CFTypeRef;
extern "c" const kSecReturnData: CFTypeRef;
extern "c" const kSecMatchLimit: CFTypeRef;
extern "c" const kSecMatchLimitOne: CFTypeRef;
extern "c" const kCFBooleanTrue: CFTypeRef;

/// Only the two statuses this file *branches* on, plus the one it maps to a
/// distinct `BridgeError`.
///
/// Deliberately not a full transcription of `SecBase.h`: a mis-typed constant
/// would silently reclassify a failure as some other failure, which is strictly
/// worse than leaving it unmapped. Everything else is reported by its raw
/// number in the log and as `NativeCallFailed` to the page.
const errSecSuccess: OSStatus = 0;
const errSecItemNotFound: OSStatus = -25300;
const errSecMissingEntitlement: OSStatus = -34018;

/// The action names, spelled exactly as the Swift `case` labels spell them.
///
/// `test/ios_conformance_test.zig` matches the two lists by string in both
/// directions, so a tidier spelling here does not read as "migrated" — it reads
/// as "Zig serves an action the spec does not have", and the Swift arm stays
/// live forever.
pub const A = struct {
    pub const set_shared_item = "setSharedItem";
    pub const get_shared_item = "getSharedItem";
    pub const remove_shared_item = "removeSharedItem";
};

/// All three `.result`. Each Swift path terminates in exactly one
/// `resolveCallback` or `rejectCallback`, and each injected JS method returns a
/// promise the page awaits — `craft.sharedKeychain.get(...)` is consumed as
/// `result.value`. Declaring any of them `.none` would strand that caller for
/// the whole request timeout.
///
/// All three are `.live`, including the `group` argument: the no-group path
/// works everywhere, and the entitlement gap described in the module comment is
/// a property of one optional argument on device builds, not of the action. It
/// is reported, per call, when it bites.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.set_shared_item, .reply = .result },
    .{ .name = A.get_shared_item, .reply = .result },
    .{ .name = A.remove_shared_item, .reply = .result },
};

/// One request's fields, after validation.
///
/// `group` is `?[]const u8` where null means "no access group" — which JSON
/// `null` and an absent field both mean, because the injected JS sends
/// `group || null` and Swift's `body["group"] as? String` turns `NSNull` into
/// `nil`. An *empty string* is not null: it is passed to the keychain verbatim
/// and the OSStatus is allowed to speak. Mapping `""` to "no group" would be a
/// silently-dropped payload field of exactly the `craft.fs.writeFile` shape.
const Request = struct {
    key: []const u8,
    value: ?[]const u8 = null,
    group: ?[]const u8 = null,
};

pub const StorageBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.set_shared_item)) {
            try self.setSharedItem(data);
        } else if (std.mem.eql(u8, action, A.get_shared_item)) {
            try self.getSharedItem(data);
        } else if (std.mem.eql(u8, action, A.remove_shared_item)) {
            try self.removeSharedItem(data);
        } else {
            return bridge_error.BridgeError.UnknownAction;
        }
    }

    /// Store `value` under `key`, replacing whatever was there.
    fn setSharedItem(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const request = try parseRequest(parsed.value, .value_required);
        // Not `request.value.?`: `parseRequest` guarantees it, but an unwrap
        // that only holds because of an argument two frames up is the kind of
        // invariant that survives exactly until someone reorders the callers.
        const value = request.value orelse return bridge_error.BridgeError.MissingData;

        try keychainSet(self.allocator, request.key, value, request.group);

        const json = try successReply(self.allocator, request.key);
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, A.set_shared_item, json);
    }

    /// Read `key`, or report that there is nothing under it.
    ///
    /// A missing item is a *success* with `"value":null`, not an error — that
    /// is what the page distinguishes, and what `packages/ios/README.md`
    /// documents (`console.log(result.value)`).
    fn getSharedItem(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const request = try parseRequest(parsed.value, .value_absent);

        const found = try keychainGet(self.allocator, request.key, request.group);
        defer if (found) |bytes| self.allocator.free(bytes);

        const json = try valueReply(self.allocator, request.key, found);
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, A.get_shared_item, json);
    }

    /// Delete `key`. "It was not there" is success, exactly as in Swift —
    /// `remove` is idempotent and a caller cannot act on the difference.
    fn removeSharedItem(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const request = try parseRequest(parsed.value, .value_absent);

        try keychainRemove(self.allocator, request.key, request.group);

        const json = try successReply(self.allocator, request.key);
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, A.remove_shared_item, json);
    }
};

/// Whether the action being served needs a `value` field.
const ValueRule = enum { value_required, value_absent };

/// Parse `d`, distinguishing a bad payload from a failed allocation.
///
/// Telling the page INVALID_JSON about its own perfectly good JSON sends
/// whoever debugs it to the wrong side of the bridge, so `OutOfMemory`
/// propagates as itself.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
}

/// The `key`/`value`/`group` triple, or the reason it cannot be used.
///
/// Pure, so the host tests can pin every outcome that Swift's `as? String`
/// collapsed into one silent fall-through. The field names are the three the
/// page posts and are pinned on both sides of the migration: `handleAction` in
/// `CraftApp.swift` parses `d` straight into `body`, and the un-migrated shim
/// reads `body["key"]`, `body["value"]`, `body["group"]`. A prettier spelling
/// here would make the Zig handler and the fallback read different payloads.
///
/// A `group` that is present but not a string is `InvalidParameter` rather than
/// ignored. Swift's `as? String` would drop it and quietly operate on the
/// *default* access group — a different item than the caller named, reported as
/// success.
fn parseRequest(payload: std.json.Value, rule: ValueRule) !Request {
    const object = switch (payload) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    const key_field = object.get("key") orelse return bridge_error.BridgeError.MissingData;
    const key = switch (key_field) {
        .string => |s| s,
        else => return bridge_error.BridgeError.InvalidParameter,
    };
    try requireNulFree(key);

    var request = Request{ .key = key };

    if (rule == .value_required) {
        const value_field = object.get("value") orelse return bridge_error.BridgeError.MissingData;
        request.value = switch (value_field) {
            .string => |s| s,
            else => return bridge_error.BridgeError.InvalidParameter,
        };
    }

    if (object.get("group")) |group_field| {
        request.group = switch (group_field) {
            // `group || null` in the injected JS, so `null` is the normal way
            // for a page to say "no access group" — as common as omitting it.
            .null => null,
            .string => |s| blk: {
                try requireNulFree(s);
                break :blk s;
            },
            else => return bridge_error.BridgeError.InvalidParameter,
        };
    }

    return request;
}

/// Refuse a `key` or `group` carrying the one byte it cannot survive.
///
/// Both reach the keychain as NSStrings built by `objc.createNSString`, i.e.
/// `+[NSString stringWithUTF8String:]`, which stops at the first NUL. A page can
/// reach that: `\u0000` is a legal JSON escape and `std.json` decodes it to the
/// byte rather than rejecting it. Without the check,
/// `set("a\u0000b", secret)` would write the item named `"a"` and reply
/// `{"success":true,"key":"a\u0000b"}` over the top of it, and a later
/// `get("a")` would hand back a secret filed under a different page key. That
/// is a silently-altered payload field reported as success: the two failures
/// this migration exists to remove, at once.
///
/// Swift keeps the NUL (`body["key"] as? String` bridges the whole string), so
/// refusing is a deliberate divergence. It is the only answer available here
/// that is not "a different item than you named, reported as success"; storing
/// it faithfully would mean a `stringWithBytes:length:encoding:` helper this
/// file does not otherwise need.
///
/// `value` needs no equivalent: `makeData` passes bytes and a length, and the
/// NSData round-trip test below pins that a NUL survives it.
fn requireNulFree(s: []const u8) !void {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return bridge_error.BridgeError.InvalidParameter;
}

/// `{"success":true,"key":"…"}` — the set/remove reply.
///
/// Built with `appendJsonEscaped` rather than `bufPrint`, unlike
/// `bridge_mobile.describeDevice`: `key` is page-controlled and is echoed back,
/// so a `"` or `\` in it would produce broken JavaScript at `formatResultJS`.
/// Device fields come from UIKit and cannot contain a quote; a keychain key can.
fn successReply(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"success\":true,\"key\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, key);
    try out.appendSlice(allocator, "\"}");

    return out.toOwnedSlice(allocator);
}

/// `{"value":"…","key":"…"}`, or `{"value":null,"key":"…"}` when absent.
///
/// JSON `null` and the empty string are different answers and stay different:
/// a stored `""` is a value the page wrote and must read back as `""`.
fn valueReply(allocator: std.mem.Allocator, key: []const u8, value: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"value\":");
    if (value) |v| {
        try out.append(allocator, '"');
        try bridge_error.appendJsonEscaped(allocator, &out, v);
        try out.append(allocator, '"');
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, ",\"key\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, key);
    try out.appendSlice(allocator, "\"}");

    return out.toOwnedSlice(allocator);
}

/// The nearest `BridgeError` to an OSStatus. Pure, so the mapping is testable.
///
/// The mapping is lossy and there is no route that is not: `sendErrorToJS`
/// takes a `BridgeError` enum, so the number cannot ride along and the page
/// cannot be told Swift's `"Keychain error: -34018"`. `ios_dispatch.zig` has a
/// free-text error route (`craft_ios_deliver_error`), but it is the shim's
/// entry point and `ios_dispatch.zig` imports the mobile bridges — reaching
/// back for it would be a circular import bought for a nicer string. So the raw
/// status goes to the log instead; see `failStatus`.
fn errorForStatus(status: OSStatus) bridge_error.BridgeError {
    return switch (status) {
        errSecItemNotFound => bridge_error.BridgeError.NotFound,
        errSecMissingEntitlement => bridge_error.BridgeError.PermissionDenied,
        else => bridge_error.BridgeError.NativeCallFailed,
    };
}

/// Log a failed keychain call and return the error the page will see.
///
/// The log line is the whole diagnostic on a device — there is no console to
/// watch — and it carries the one thing the page cannot be given, the raw
/// OSStatus. The `key` is logged because it names the failing call; the
/// **value is never logged**, here or anywhere else in this file, because it is
/// the secret the caller chose the keychain for.
fn failStatus(op: []const u8, key: []const u8, group: ?[]const u8, status: OSStatus) bridge_error.BridgeError {
    std.log.warn("keychain {s} failed for key '{s}': OSStatus {d}", .{ op, key, status });
    if (group) |g| {
        std.log.warn(
            "  ...with access group '{s}'. `renderEntitlements` (packages/ios/src/index.ts) never emits " ++
                "`keychain-access-groups`, so a signed device build gets -34018 here whatever the language; " ++
                "the simulator does not enforce it and will appear to work.",
            .{g},
        );
    }
    return errorForStatus(status);
}

/// The query every one of the three operations starts from: class + account,
/// plus the access group when the caller named one.
///
/// No `kSecAttrService`, matching the Swift exactly — identity is class +
/// account (+ group). Adding one would partition the store so that items
/// written by Zig and by the un-migrated Swift shim could not see each other.
///
/// The dictionary is an autoreleased `NSMutableDictionary`, drained at the end
/// of this run-loop turn; the whole handler completes inside the
/// `WKScriptMessageHandler` callback, so there is always a pool. It is handed to
/// `SecItem*` as a `CFDictionaryRef` — toll-free bridging, which is what
/// `query as CFDictionary` does in Swift.
fn newQuery(allocator: std.mem.Allocator, key: []const u8, group: ?[]const u8) !Id {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSMutableDictionary = objc.objc_getClass("NSMutableDictionary") orelse return error.ClassNotFound;
    const sel_dictionary = objc.sel_registerName("dictionary") orelse return error.SelectorNotFound;
    const query = objc.msgSendId(NSMutableDictionary, sel_dictionary);
    if (query == null) return error.QueryAllocationFailed;

    try setQueryValue(query, kSecClass, kSecClassGenericPassword);

    const account = try objc.createNSString(key, allocator);
    try setQueryValue(query, kSecAttrAccount, account);

    if (group) |g| {
        const ns_group = try objc.createNSString(g, allocator);
        try setQueryValue(query, kSecAttrAccessGroup, ns_group);
    }

    return query;
}

/// `-[NSMutableDictionary setObject:forKey:]`, with the nil check that keeps a
/// missing constant from becoming a crash.
///
/// `setObject:forKey:` raises an `NSInvalidArgumentException` on a nil key or
/// value. An ObjC exception cannot be caught from Zig, so it would take the app
/// down with a stack that names AppKit rather than this file. A null `kSec*`
/// global means Security.framework is not in the process — a real condition, and
/// one worth naming rather than discovering as a crash.
///
/// The key is a `CFStringRef` passed as an `id`: `CFString` is toll-free bridged
/// to `NSString` and so conforms to `NSCopying`, which is all `forKey:` asks.
fn setQueryValue(dict: Id, cf_key: CFTypeRef, value: Id) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    if (cf_key == null or value == null) return error.MissingKeychainConstant;

    const sel_set = objc.sel_registerName("setObject:forKey:") orelse return error.SelectorNotFound;
    objc.msgSendVoid2(dict, sel_set, value, cf_key);
}

/// `+[NSData dataWithBytes:length:]`, autoreleased.
///
/// The payload is `value`'s bytes as-is: `std.json` has already validated them
/// as UTF-8, so there is no conversion step and nothing that can fail the way
/// Swift's `value.data(using: .utf8)!` force-unwrap could.
fn makeData(bytes: []const u8) !Id {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSData = objc.objc_getClass("NSData") orelse return error.ClassNotFound;
    const sel_data = objc.sel_registerName("dataWithBytes:length:") orelse return error.SelectorNotFound;

    // The length must be an explicit `c_ulong` (`NSUInteger`): the variadic
    // `objc_msgSend` cast takes the argument type from what is passed, and a
    // Zig `usize` literal would be a different type in the signature.
    const data = objc.msgSendId2(NSData, sel_data, bytes.ptr, @as(c_ulong, @intCast(bytes.len)));
    if (data == null) return error.NSDataCreationFailed;
    return data;
}

/// Store `value` under `key`, replacing any existing item.
///
/// Delete-then-add, as in Swift, but with the delete given the *scoped* query —
/// see the module comment for why. The delete's status is discarded exactly as
/// Swift discards it: "there was nothing to replace" is the common case and is
/// not a failure. The add's status is never discarded.
fn keychainSet(allocator: std.mem.Allocator, key: []const u8, value: []const u8, group: ?[]const u8) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const query = try newQuery(allocator, key, group);

    _ = SecItemDelete(query);

    try setQueryValue(query, kSecValueData, try makeData(value));
    // Device-local and unreadable while locked. On the add only — naming it in
    // a delete or a match query would filter by it rather than set it.
    try setQueryValue(query, kSecAttrAccessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly);

    const status = SecItemAdd(query, null);
    if (status != errSecSuccess) return failStatus("set", key, group, status);
}

/// Read `key`, returning an owned copy of its bytes, or null when absent.
///
/// Copied out rather than borrowed because the result of
/// `SecItemCopyMatching` arrives **+1 retained** — ARC released it for Swift,
/// Zig must not — and the copy is what lets the `CFRelease` sit next to the
/// read on every path. Forgetting it leaks a page-sized allocation per `get`.
fn keychainGet(allocator: std.mem.Allocator, key: []const u8, group: ?[]const u8) !?[]u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const query = try newQuery(allocator, key, group);
    // `kCFBooleanTrue`, not an `NSNumber` built here. Swift's `true` bridges to
    // the `__NSCFBoolean` singleton, and `prefs_macos.zig` already records what
    // confusing the two costs.
    try setQueryValue(query, kSecReturnData, kCFBooleanTrue);
    try setQueryValue(query, kSecMatchLimit, kSecMatchLimitOne);

    var result: CFTypeRef = null;
    const status = SecItemCopyMatching(query, &result);

    if (status == errSecItemNotFound) return null;
    if (status != errSecSuccess) return failStatus("get", key, group, status);

    const data = result orelse {
        // errSecSuccess with no object back should be impossible; if it happens
        // it is not "the key is empty" and must not be answered as one.
        std.log.warn("keychain get for key '{s}' returned errSecSuccess with no data", .{key});
        return bridge_error.BridgeError.NativeCallFailed;
    };
    defer CFRelease(data);

    // Swift's `result as? Data`. With `kSecReturnData` + `kSecMatchLimitOne`
    // this is always a `CFDataRef`, and the type check costs one message send
    // to be sure it is not something that would be read as raw bytes anyway.
    if (!try isData(data)) {
        std.log.warn("keychain get for key '{s}' returned a non-CFData result", .{key});
        return bridge_error.BridgeError.NativeCallFailed;
    }

    const len = try dataLength(data);
    const bytes: []const u8 = if (len == 0)
        // `-bytes` is documented to return nil for empty data, so a zero length
        // is answered without dereferencing anything.
        &[_]u8{}
    else
        (try dataBytes(data) orelse {
            std.log.warn("keychain get for key '{s}' returned {d} bytes at a nil pointer", .{ key, len });
            return bridge_error.BridgeError.NativeCallFailed;
        })[0..len];

    if (!std.unicode.utf8ValidateSlice(bytes)) {
        // Swift's `String(data:encoding:.utf8)` failing falls into the `else`
        // and rejects with `"Keychain error: 0"` — a status that means success.
        // Neither `BridgeError` fits well: the native call did succeed, so
        // `NativeCallFailed` is wrong, and the caller's parameters were fine, so
        // `InvalidParameter` is only right in the sense that the item under this
        // key is not something a string-valued API can return. The log line is
        // the part that is actually diagnostic.
        std.log.warn("keychain item for key '{s}' is not valid UTF-8; this API only returns strings", .{key});
        return bridge_error.BridgeError.InvalidParameter;
    }

    return try allocator.dupe(u8, bytes);
}

/// Delete `key`. Absent is success, as in Swift.
fn keychainRemove(allocator: std.mem.Allocator, key: []const u8, group: ?[]const u8) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const query = try newQuery(allocator, key, group);
    const status = SecItemDelete(query);
    if (status == errSecSuccess or status == errSecItemNotFound) return;
    return failStatus("remove", key, group, status);
}

/// `-[NSObject isKindOfClass:[NSData class]]`. `CFData` is toll-free bridged, so
/// this is true for the `CFDataRef` the keychain hands back.
fn isData(obj: Id) !bool {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSData = objc.objc_getClass("NSData") orelse return error.ClassNotFound;
    const sel_kind = objc.sel_registerName("isKindOfClass:") orelse return error.SelectorNotFound;
    const Fn = *const fn (objc.id, objc.SEL, objc.id) callconv(.c) bool;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(obj, sel_kind, NSData);
}

/// `-[NSData length]`. `NSUInteger`, hence `c_ulong`.
fn dataLength(data: Id) !usize {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel_length = objc.sel_registerName("length") orelse return error.SelectorNotFound;
    const Fn = *const fn (objc.id, objc.SEL) callconv(.c) c_ulong;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return @intCast(func(data, sel_length));
}

/// `-[NSData bytes]`. Not `-UTF8String`: the keychain returns a `CFDataRef`,
/// which has no such selector — sending it would be a runtime crash rather than
/// a compile error, which is why the selector strings here are worth reading
/// twice.
///
/// The pointer is valid until the data is released, which the caller does after
/// copying.
fn dataBytes(data: Id) !?[*]const u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel_bytes = objc.sel_registerName("bytes") orelse return error.SelectorNotFound;
    const Fn = *const fn (objc.id, objc.SEL) callconv(.c) ?[*]const u8;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(data, sel_bytes);
}

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 3), capability_actions.len);
    try testing.expectEqualStrings(A.set_shared_item, capability_actions[0].name);
    try testing.expectEqualStrings(A.get_shared_item, capability_actions[1].name);
    try testing.expectEqualStrings(A.remove_shared_item, capability_actions[2].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these strings against the `case "…":`
    // labels in `CraftApp.swift`, in both directions. A prettier spelling would
    // register as Zig serving an action the spec does not have.
    try testing.expectEqualStrings("setSharedItem", A.set_shared_item);
    try testing.expectEqualStrings("getSharedItem", A.get_shared_item);
    try testing.expectEqualStrings("removeSharedItem", A.remove_shared_item);
}

test "every declared action dispatches to something" {
    // `{}` has no `key`, so all three fail validation *before* any Security
    // call — which is what makes this safe to run on a developer's machine: the
    // host keychain is never touched. What it rules out is a name in the table
    // that `handleMessage` does not compare against.
    var bridge = StorageBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        try testing.expectError(
            bridge_error.BridgeError.MissingData,
            bridge.handleMessage(decl.name, "{}"),
        );
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = StorageBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("clearSharedItems", "{}"),
    );
    // The Swift *helper* names, which are not action names. Accepting one would
    // mean the conformance scan sees an action the spec's dispatcher lacks.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("setSharedKeychainItem", "{\"key\":\"k\",\"value\":\"v\"}"),
    );
    // The desktop keychain namespace's spelling, which is a different bridge.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("setPassword", "{\"key\":\"k\",\"value\":\"v\"}"),
    );
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = StorageBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.get_shared_item, "{not json"),
    );
}

/// Parse a literal payload and hand the `Request` to `check` while the backing
/// `std.json.Parsed` is still alive — the slices in a `Request` point into it.
fn expectRequest(
    json: []const u8,
    rule: ValueRule,
    check: fn (Request) anyerror!void,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try check(try parseRequest(parsed.value, rule));
}

fn expectRequestError(json: []const u8, rule: ValueRule, expected: anyerror) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, parseRequest(parsed.value, rule));
}

test "the three field names the page sends are the three that are read" {
    try expectRequest(
        "{\"key\":\"token\",\"value\":\"abc123\",\"group\":\"group.app.shared\"}",
        .value_required,
        struct {
            fn check(request: Request) !void {
                try testing.expectEqualStrings("token", request.key);
                try testing.expectEqualStrings("abc123", request.value.?);
                try testing.expectEqualStrings("group.app.shared", request.group.?);
            }
        }.check,
    );
}

test "an absent key is refused rather than defaulted" {
    try expectRequestError("{\"value\":\"v\"}", .value_required, bridge_error.BridgeError.MissingData);
    try expectRequestError("{}", .value_absent, bridge_error.BridgeError.MissingData);
}

test "an absent value is refused rather than stored as empty" {
    // Swift's `if let value = body["value"] as? String` fails here and replies
    // nothing at all. A default of `""` would be worse still: it would silently
    // overwrite a real secret with an empty string and report success.
    try expectRequestError("{\"key\":\"k\"}", .value_required, bridge_error.BridgeError.MissingData);
}

test "a non-string key or value is refused, not coerced" {
    try expectRequestError("{\"key\":7,\"value\":\"v\"}", .value_required, bridge_error.BridgeError.InvalidParameter);
    try expectRequestError("{\"key\":\"k\",\"value\":7}", .value_required, bridge_error.BridgeError.InvalidParameter);
    try expectRequestError("{\"key\":null}", .value_absent, bridge_error.BridgeError.InvalidParameter);
}

test "an explicitly empty value is a value, and is stored" {
    // Distinct from an absent one. Writing `""` is a legitimate request and the
    // page can read it back; only the absent case is an error.
    try expectRequest(
        "{\"key\":\"k\",\"value\":\"\"}",
        .value_required,
        struct {
            fn check(request: Request) !void {
                try testing.expectEqualStrings("", request.value.?);
            }
        }.check,
    );
}

test "null and absent group both mean no access group" {
    // The injected JS sends `group || null`, so `null` is how a page normally
    // says it wants none — as common as omitting the field.
    const cases = [_][]const u8{
        "{\"key\":\"k\",\"group\":null}",
        "{\"key\":\"k\"}",
    };
    for (cases) |json| {
        try expectRequest(json, .value_absent, struct {
            fn check(request: Request) !void {
                try testing.expect(request.group == null);
            }
        }.check);
    }
}

test "an empty group is passed through, not turned into no group" {
    // The dropped-field regression. `""` is not `null`: silently promoting it
    // would search the default access group instead of the one the caller named
    // and report the answer as if it came from theirs.
    try expectRequest(
        "{\"key\":\"k\",\"group\":\"\"}",
        .value_absent,
        struct {
            fn check(request: Request) !void {
                try testing.expect(request.group != null);
                try testing.expectEqualStrings("", request.group.?);
            }
        }.check,
    );
}

test "a key or group with an embedded NUL is refused, not truncated" {
    // `createNSString` goes through `stringWithUTF8String:`, which stops at the
    // first NUL, so an unchecked "a\u0000b" would address the keychain item
    // named "a" while the reply echoed the full key back. Two distinct page
    // keys would then share one item, and `set` would report success for a key
    // it did not use. `\u0000` is a legal JSON escape and `std.json` decodes it
    // to the byte, so a page can reach this.
    try expectRequestError(
        "{\"key\":\"a\\u0000b\",\"value\":\"v\"}",
        .value_required,
        bridge_error.BridgeError.InvalidParameter,
    );
    // The access group takes the same route into the query and so takes the
    // same check: a truncated group names a different access group.
    try expectRequestError(
        "{\"key\":\"k\",\"group\":\"g\\u0000x\"}",
        .value_absent,
        bridge_error.BridgeError.InvalidParameter,
    );

    // The *value* keeps its NUL and is not refused: `makeData` passes bytes and
    // a length, so there is nothing to truncate. Refusing it would be dropping
    // a payload field the handler can carry perfectly well.
    try expectRequest(
        "{\"key\":\"k\",\"value\":\"a\\u0000b\"}",
        .value_required,
        struct {
            fn check(request: Request) !void {
                try testing.expectEqualSlices(u8, &[_]u8{ 'a', 0, 'b' }, request.value.?);
            }
        }.check,
    );
}

test "a group that is not a string is refused rather than ignored" {
    // Swift's `as? String` drops it and quietly operates on the default access
    // group — a different item than the caller named, reported as success.
    try expectRequestError("{\"key\":\"k\",\"group\":42}", .value_absent, bridge_error.BridgeError.InvalidParameter);
}

test "a payload that is not an object is bad JSON, not a missing field" {
    try expectRequestError("[]", .value_absent, bridge_error.BridgeError.InvalidJSON);
    try expectRequestError("\"key\"", .value_absent, bridge_error.BridgeError.InvalidJSON);
}

test "the set and remove reply is the Swift dictionary verbatim" {
    const json = try successReply(testing.allocator, "token");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"success\":true,\"key\":\"token\"}", json);
}

test "a found value and a missing one are different replies" {
    const found = try valueReply(testing.allocator, "token", "abc123");
    defer testing.allocator.free(found);
    try testing.expectEqualStrings("{\"value\":\"abc123\",\"key\":\"token\"}", found);

    const missing = try valueReply(testing.allocator, "token", null);
    defer testing.allocator.free(missing);
    try testing.expectEqualStrings("{\"value\":null,\"key\":\"token\"}", missing);

    // A stored empty string is not a missing item, and the page must be able to
    // tell them apart.
    const empty = try valueReply(testing.allocator, "token", "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("{\"value\":\"\",\"key\":\"token\"}", empty);
}

test "a page-controlled key or value cannot break the reply" {
    // Both are echoed into JavaScript that `evaluateJavaScript:` parses as
    // source. `bufPrint` with `{s}`, which `describeDevice` can safely use for
    // UIKit-sourced strings, would produce a syntax error in the page here.
    const json = try valueReply(testing.allocator, "we\"ird\\key", "line\none\ttwo\x01");
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("we\"ird\\key", parsed.value.object.get("key").?.string);
    try testing.expectEqualStrings("line\none\ttwo\x01", parsed.value.object.get("value").?.string);
}

test "an OSStatus maps to the nearest error, and nothing else is guessed at" {
    try testing.expectEqual(bridge_error.BridgeError.NotFound, errorForStatus(errSecItemNotFound));
    // The entitlement gap: a `group` on a signed device build lands here.
    try testing.expectEqual(bridge_error.BridgeError.PermissionDenied, errorForStatus(errSecMissingEntitlement));
    // errSecDuplicateItem, errSecParam, errSecInteractionNotAllowed and the
    // rest are deliberately unmapped — a mis-transcribed constant that
    // reclassifies one failure as another is worse than a generic one, and the
    // raw number reaches the log either way.
    try testing.expectEqual(bridge_error.BridgeError.NativeCallFailed, errorForStatus(-25299));
    try testing.expectEqual(bridge_error.BridgeError.NativeCallFailed, errorForStatus(-50));
    try testing.expectEqual(bridge_error.BridgeError.NativeCallFailed, errorForStatus(-25308));
}

test "the constants that are branched on are the documented ones" {
    // These three numbers are load-bearing: `errSecItemNotFound` is the
    // difference between `{"value":null}` and a rejection, and a wrong
    // `errSecSuccess` would make every call look like a failure.
    try testing.expectEqual(@as(OSStatus, 0), errSecSuccess);
    try testing.expectEqual(@as(OSStatus, -25300), errSecItemNotFound);
    try testing.expectEqual(@as(OSStatus, -34018), errSecMissingEntitlement);
}

// The remaining tests exercise the Objective-C half against the live runtime.
// They need no device, no UIKit and no keychain — only libobjc and Foundation,
// which a macOS host has — and they are skipped off Darwin. They are here
// because a wrong selector string is not a compile error: it is a runtime crash
// or a silent no-op, and nothing else in this file would catch one.
//
// The keychain calls themselves stay untested. `SecItemCopyMatching` for an
// absent key was run by hand during development and answered
// `errSecItemNotFound` — which proves the `kSec*` globals resolve, the
// dictionary bridges to `CFDictionaryRef`, and the not-found branch is reached —
// but a headless CI runner may have no login keychain at all, and a test that
// depends on that is a flake, not a gate. A write/read/delete round trip needs
// the simulator.

test "the NSData selectors round-trip bytes, embedded NUL included" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    // The NUL is the point: `length`/`bytes` are used rather than
    // `UTF8String` + `std.mem.span`, which would truncate a stored value at the
    // first zero byte and report the truncation as the value.
    const payload = "he\x00llo";
    const data = try makeData(payload);
    try testing.expect(try isData(data));

    const len = try dataLength(data);
    try testing.expectEqual(@as(usize, payload.len), len);

    const bytes = (try dataBytes(data)).?;
    try testing.expectEqualSlices(u8, payload, bytes[0..len]);
}

test "an empty value is empty data, and is never dereferenced" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const data = try makeData("");
    try testing.expect(try isData(data));
    try testing.expectEqual(@as(usize, 0), try dataLength(data));
}

test "the CFData type check rejects something that is not data" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    // Swift's `result as? Data`. An NSString stands in for "the keychain
    // returned something else", which is the case that must not be read as raw
    // bytes and handed to the page as a value.
    const ns = try objc.createNSString("not data", testing.allocator);
    try testing.expect(!try isData(ns));
}
