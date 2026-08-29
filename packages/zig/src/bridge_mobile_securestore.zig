//! The secure-storage actions of the `mobile` namespace: `secureSet`,
//! `secureGet`, `secureRemove`, `secureClear`.
//!
//! **Same keychain, same namespace as `bridge_mobile_storage.zig`.** The Swift
//! helpers (`secureStore`/`secureRetrieve`/`secureRemove`/`secureClear` in
//! `CraftApp.swift`) identify an item by `kSecClass` + `kSecAttrAccount` and
//! nothing else — no `kSecAttrService` anywhere in the file, no key prefix, no
//! access group. That means `secureSet("k")` and `setSharedItem("k")` (group
//! omitted) read and overwrite the *same item*. Adding a service attribute here
//! would look like hygiene and would actually make every item the Swift shim
//! ever wrote unreadable, which is the one thing a partial migration must not
//! do. The overlap is Swift's design, carried across on purpose.
//!
//! Two JS surfaces funnel into these actions: the legacy `craft.secureStore`
//! object (`set`/`get`/`remove`, promises with **no timeout**) and the modern
//! `craft.secureStorage` wrapper, which delegates set/get/delete to the legacy
//! object and reaches `secureClear` through `craft._invoke` (30s timeout). The
//! no-timeout legacy promises are why every path in this file ends in a reply
//! or an error — a dropped message parks the page forever.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **Replies are bare JSON fragments**, Swift's `.fragmentsAllowed`:
//!    `true`/`false` for set/remove/clear, a bare string or `null` for get.
//!    No object wrapper anywhere, unlike the sharedItems shapes next door.
//!  - **A keychain failure on set/remove/clear *resolves* `false`** rather than
//!    rejecting. That is not fabricated success — `false` is the contract's
//!    failure value, and it is what every existing caller is written against.
//!    The raw OSStatus goes to the log, which is the only channel a bare
//!    boolean leaves for it.
//!  - **`remove` and `clear` treat `errSecItemNotFound` as `true`** — both are
//!    idempotent and a caller cannot act on the difference.
//!  - **Accessibility is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**, on
//!    the add only.
//!  - **`get` answers `null` for a missing key** — the promise resolves, it
//!    does not reject.
//!
//! ## What is deliberately not carried across
//!
//! **Swift's silent hang.** The set/get/remove dispatcher arms are `if let`s
//! with no `else`: a missing `key`, a non-string `value`, or a disabled
//! `enableSecureStorage` config replies nothing at all, and the legacy promise
//! never settles. Malformed input errors here instead. The capability gate has
//! no Zig mirror (`enableSecureStorage` appears nowhere in `packages/zig/src`),
//! so the actions are served unconditionally. For set/get/remove that grants a
//! page nothing new: the *ungated* sharedItems actions next door already
//! read and write the same items (one namespace — see above). The two gated
//! modules that came before chose differently — clipboard kept its gate
//! plumbable (`craft_ios_set_clipboard_enabled`, rejecting `PermissionDenied`
//! when off) and haptics declared its gated action `.unavailable` — and
//! `secureClear` is where the difference is real: under Swift's default-false
//! gate a page got CAPABILITY_DISABLED instead of a wipe, and here the wipe is
//! always live. If that gate is wanted back, clipboard's hook is the pattern;
//! what must not come back is Swift's silent hang on the other three.
//!
//! **`get`'s collapse of every failure into `null`.** Swift returns `nil` for
//! *any* non-success status, so a page cannot tell "nothing stored" from "the
//! keychain call failed". Here only `errSecItemNotFound` is `null`; any other
//! status is an error with the number in the log. Same for stored bytes that
//! are not UTF-8 (Swift's `String(data:encoding:)` fails and resolves `null`
//! over a value that *exists*): that is an error here, because `null` is a
//! claim about the store that nothing verified.
//!
//! **A `key` with an embedded NUL.** Swift stores it whole; the route Zig has
//! to the keychain (`stringWithUTF8String:`) truncates at the NUL and would
//! file the item under a shorter name than the caller gave, then report success
//! for a key it did not use. Refused as `InvalidParameter`, exactly as
//! `bridge_mobile_storage.requireNulFree` does. The *value* keeps its NUL: it
//! travels as bytes-plus-length through `dataWithBytes:length:` and back out
//! through `length`/`bytes`, so nothing truncates it, and refusing it would
//! drop a payload the handler carries perfectly well.
//!
//! **Swift's shared delete/add dictionary.** `secureStore` hands the same
//! dictionary — `kSecValueData` and `kSecAttrAccessible` included — to both
//! `SecItemDelete` and `SecItemAdd` and discards the delete's status.
//! `keychainStore` below builds the delete-scoped query first (class + account,
//! the shape `remove` already uses) and only then adds the value attributes;
//! `bridge_mobile_storage.zig`'s module comment carries the full argument.
//!
//! ## The `secureClear` blast radius, named because it is invisible
//!
//! Swift's `secureClear` deletes with a query of `kSecClass` alone: **every
//! generic-password item the app can see**, including everything
//! `setSharedItem` wrote (the two namespaces are one namespace — see above).
//! `keychainClear` is bug-compatible with that, because a narrower clear would
//! leave items behind that Swift's would have removed and the two
//! implementations must be interchangeable mid-migration. A page that calls
//! `craft.secureStorage.clear()` wipes the sharedItems store too, whichever
//! language answers. This is also why the host tests below never *invoke* the
//! clear handler: it has no validation step to fail early at, and on a macOS
//! test runner the query would address the developer's login keychain.

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
/// unreachable, so naming `objc.id` in the `callconv(.c)` types below would
/// break the host build. It stays a single optional pointer, never `?objc.id`:
/// a double optional is illegal in a `callconv(.c)` type.
const Id = ?*anyopaque;

/// Toll-free-bridged CoreFoundation values — the `kSec*` globals — kept
/// nominally distinct from `Id` in the signatures, as in
/// `bridge_mobile_storage.zig`.
const CFTypeRef = ?*anyopaque;

/// `SInt32`, fixed by the ABI; every keychain status of interest is negative.
const OSStatus = i32;

// Security.framework and CoreFoundation. Duplicated from
// `bridge_mobile_storage.zig` rather than imported from it: these are
// file-private there by design, and `extern` declarations are free to repeat.
// The build note there applies here too — `-framework Security` must reach the
// app link, which Swift's `import Security` autolinks and the zig-slice fixture
// passes explicitly.
extern "c" fn SecItemAdd(attributes: CFTypeRef, result: ?*CFTypeRef) OSStatus;
extern "c" fn SecItemCopyMatching(query: CFTypeRef, result: ?*CFTypeRef) OSStatus;
extern "c" fn SecItemDelete(query: CFTypeRef) OSStatus;
extern "c" fn CFRelease(cf: CFTypeRef) void;

extern "c" const kSecClass: CFTypeRef;
extern "c" const kSecClassGenericPassword: CFTypeRef;
extern "c" const kSecAttrAccount: CFTypeRef;
extern "c" const kSecAttrAccessible: CFTypeRef;
extern "c" const kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFTypeRef;
extern "c" const kSecValueData: CFTypeRef;
extern "c" const kSecReturnData: CFTypeRef;
extern "c" const kSecMatchLimit: CFTypeRef;
extern "c" const kSecMatchLimitOne: CFTypeRef;
extern "c" const kCFBooleanTrue: CFTypeRef;

/// Only the statuses this file *branches* on. Everything else stays unmapped —
/// a mis-transcribed constant that reclassifies one failure as another is worse
/// than a generic one — and reaches the log by its raw number.
const errSecSuccess: OSStatus = 0;
const errSecItemNotFound: OSStatus = -25300;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches the two lists by string in both
/// directions.
pub const A = struct {
    pub const secure_set = "secureSet";
    pub const secure_get = "secureGet";
    pub const secure_remove = "secureRemove";
    pub const secure_clear = "secureClear";
};

/// All four `.result`: each Swift path resolves or rejects a callback, and
/// each JS surface returns a promise — the legacy ones without a timeout, so
/// `.none` here would strand a caller forever, not for thirty seconds.
///
/// All four `.live`. Every operation is a plain Security.framework call with
/// no UI, no completion handler and no entitlement requirement (no access
/// group is ever named), so nothing needs `.unavailable`.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.secure_set, .reply = .result },
    .{ .name = A.secure_get, .reply = .result },
    .{ .name = A.secure_remove, .reply = .result },
    .{ .name = A.secure_clear, .reply = .result },
};

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host. That split is
/// load-bearing for exactly one action here: `secureClear` has no payload and
/// therefore no validation step, so a test that *called* it to prove routing
/// would issue a class-wide `SecItemDelete` against the machine running the
/// tests.
const Route = enum { set, get, remove, clear };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.secure_set)) return .set;
    if (std.mem.eql(u8, action, A.secure_get)) return .get;
    if (std.mem.eql(u8, action, A.secure_remove)) return .remove;
    if (std.mem.eql(u8, action, A.secure_clear)) return .clear;
    return null;
}

pub const SecureStoreBridge = struct {
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
            .set => self.secureSet(data),
            .get => self.secureGet(data),
            .remove => self.secureRemove(data),
            .clear => self.secureClear(),
        };
    }

    /// Store `value` under `key`, replacing whatever was there. Resolves
    /// `true`/`false`, Swift's `resolveCallback(callbackId, result: success)`.
    fn secureSet(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const request = try parseSetRequest(parsed.value);
        const stored = try keychainStore(self.allocator, request.key, request.value);
        bridge_error.sendResultToJS(self.allocator, A.secure_set, boolFragment(stored));
    }

    /// Read `key`. A missing item resolves `null`; a found one resolves the
    /// bare string. Both are fragments, not objects — `test-bridges.html` does
    /// `'Stored and retrieved: ' + value` with the reply directly.
    fn secureGet(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const key = try parseKey(parsed.value);
        const found = try keychainRetrieve(self.allocator, key);
        defer if (found) |bytes| self.allocator.free(bytes);

        const json = try valueFragment(self.allocator, found);
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, A.secure_get, json);
    }

    /// Delete `key`. Absent resolves `true`, as in Swift — idempotent.
    fn secureRemove(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const key = try parseKey(parsed.value);
        const removed = try keychainDelete(self.allocator, key);
        bridge_error.sendResultToJS(self.allocator, A.secure_remove, boolFragment(removed));
    }

    /// Delete every generic-password item — see the module comment for what
    /// that includes. The payload is ignored, as Swift ignores the body: the
    /// only caller is `craft._invoke('secureClear')`, which sends none, and
    /// `ios_dispatch.payloadOf` hands this `"{}"` for an absent `d`.
    fn secureClear(self: *Self) !void {
        const cleared = try keychainClear();
        bridge_error.sendResultToJS(self.allocator, A.secure_clear, boolFragment(cleared));
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

/// The set payload after validation. Field names are the ones the injected JS
/// posts (`{action:'secureSet', key: key, value: value, callbackId: id}`) and
/// the un-migrated shim reads (`body["key"]`, `body["value"]`) — pinned on
/// both sides of the migration.
const SetRequest = struct {
    key: []const u8,
    value: []const u8,
};

/// The `key` field, or the reason it cannot be used. Pure, so the host tests
/// can pin every outcome Swift's `as? String` collapsed into a silent hang.
fn parseKey(payload: std.json.Value) ![]const u8 {
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
    return key;
}

fn parseSetRequest(payload: std.json.Value) !SetRequest {
    const key = try parseKey(payload);

    const object = payload.object; // parseKey proved it is an object
    const value_field = object.get("value") orelse return bridge_error.BridgeError.MissingData;
    const value = switch (value_field) {
        .string => |s| s,
        // Swift's `as? String` fails here and replies nothing at all. A
        // coercion would be worse: it would overwrite a real secret with a
        // stringified something and report success.
        else => return bridge_error.BridgeError.InvalidParameter,
    };

    return .{ .key = key, .value = value };
}

/// Refuse a `key` carrying the one byte it cannot survive. `\u0000` is a legal
/// JSON escape and `std.json` decodes it to the byte, so a page can reach
/// this; `createNSString` (`stringWithUTF8String:`) would then truncate and
/// the item would be filed under a name the caller did not give. The value
/// needs no equivalent — `makeData` passes bytes and a length, and the NSData
/// round-trip test below pins that a NUL survives it.
fn requireNulFree(s: []const u8) !void {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return bridge_error.BridgeError.InvalidParameter;
}

/// The bare boolean fragments Swift's `.fragmentsAllowed` produces from
/// `resolveCallback(callbackId, result: success)`. Static, so the boolean
/// replies allocate nothing.
fn boolFragment(ok: bool) []const u8 {
    return if (ok) "true" else "false";
}

/// The get reply: a bare JSON string, or the literal `null` for a missing key.
///
/// Escaped with `appendJsonEscaped` because the value is page-controlled and
/// is replayed into JavaScript that `evaluateJavaScript:` parses as source — a
/// `"` or `\` in a stored secret would otherwise break the page's promise
/// resolution. `null` and `""` are different answers and stay different: a
/// stored empty string must read back as `""`.
fn valueFragment(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (value) |v| {
        try out.append(allocator, '"');
        try bridge_error.appendJsonEscaped(allocator, &out, v);
        try out.append(allocator, '"');
    } else {
        try out.appendSlice(allocator, "null");
    }
    return out.toOwnedSlice(allocator);
}

/// Log a keychain failure with the one thing a bare-boolean reply cannot
/// carry: the raw OSStatus. The `key` names the failing call; the **value is
/// never logged**, here or anywhere in this file — it is the secret the caller
/// chose the keychain for.
fn logStatus(op: []const u8, key: []const u8, status: OSStatus) void {
    std.log.warn("secure store {s} failed for key '{s}': OSStatus {d}", .{ op, key, status });
}

/// The query every operation starts from: class + account. No service, no
/// access group, matching the Swift exactly — see the module comment for why
/// adding either would strand Swift-written data.
///
/// The dictionary is an autoreleased `NSMutableDictionary`, alive for the
/// run-loop turn the `WKScriptMessageHandler` callback runs inside, handed to
/// `SecItem*` via toll-free bridging.
fn newQuery(allocator: std.mem.Allocator, key: []const u8) !Id {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSMutableDictionary = objc.objc_getClass("NSMutableDictionary") orelse return error.ClassNotFound;
    const sel_dictionary = objc.sel_registerName("dictionary") orelse return error.SelectorNotFound;
    const query = objc.msgSendId(NSMutableDictionary, sel_dictionary);
    if (query == null) return error.QueryAllocationFailed;

    try setQueryValue(query, kSecClass, kSecClassGenericPassword);

    // `createNSString` can hand back nil (its `stringWithUTF8String:` returns
    // nil for bytes it rejects). `std.json` already validated UTF-8 and the
    // NUL check ran, so this should not fire — but an unchecked nil into
    // `setObject:forKey:` is an uncatchable NSInvalidArgumentException, so it
    // is named rather than assumed away.
    const account = try objc.createNSString(key, allocator);
    if (account == null) return error.StringCreationFailed;
    try setQueryValue(query, kSecAttrAccount, account);

    return query;
}

/// `-[NSMutableDictionary setObject:forKey:]` with the nil checks that keep a
/// missing Security.framework constant a named error instead of an
/// uncatchable ObjC exception.
fn setQueryValue(dict: Id, cf_key: CFTypeRef, value: Id) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    if (cf_key == null or value == null) return error.MissingKeychainConstant;

    const sel_set = objc.sel_registerName("setObject:forKey:") orelse return error.SelectorNotFound;
    objc.msgSendVoid2(dict, sel_set, value, cf_key);
}

/// `+[NSData dataWithBytes:length:]`, autoreleased. The value's bytes as-is:
/// `std.json` validated them as UTF-8 already, so there is no conversion step
/// and nothing that can fail the way Swift's `value.data(using: .utf8)!`
/// force-unwrap could.
fn makeData(bytes: []const u8) !Id {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSData = objc.objc_getClass("NSData") orelse return error.ClassNotFound;
    const sel_data = objc.sel_registerName("dataWithBytes:length:") orelse return error.SelectorNotFound;

    // The length must be an explicit `c_ulong` (`NSUInteger`): the variadic
    // msgSend cast takes the argument type from what is passed.
    const data = objc.msgSendId2(NSData, sel_data, bytes.ptr, @as(c_ulong, @intCast(bytes.len)));
    if (data == null) return error.NSDataCreationFailed;
    return data;
}

/// Store `value` under `key`, replacing any existing item; `false` means the
/// add failed and the status is in the log.
///
/// Delete-then-add as in Swift, but the delete gets the *scoped* query (class
/// + account) before the value attributes go in — see the module comment. The
/// delete's status is discarded exactly as Swift discards it: "nothing to
/// replace" is the common case. The add's status is never discarded.
fn keychainStore(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !bool {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const query = try newQuery(allocator, key);

    _ = SecItemDelete(query);

    try setQueryValue(query, kSecValueData, try makeData(value));
    // Device-local, never iCloud-synced, unreadable while locked. On the add
    // only — in a delete or match query it would filter rather than set.
    try setQueryValue(query, kSecAttrAccessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly);

    const status = SecItemAdd(query, null);
    if (status == errSecSuccess) return true;
    logStatus("set", key, status);
    return false;
}

/// Read `key`, returning an owned copy of its bytes, or null when absent.
///
/// Copied out because `SecItemCopyMatching`'s result arrives **+1 retained**
/// — ARC released it for Swift, Zig must not forget to — and the copy lets the
/// `CFRelease` sit next to the read on every path.
///
/// Divergence from Swift, on purpose: Swift folds *every* non-success status
/// and every non-UTF-8 value into `nil` → the page sees `null`, a claim that
/// nothing is stored. Only `errSecItemNotFound` earns `null` here; a failed
/// call or an undecodable item is an error with the diagnostic in the log.
fn keychainRetrieve(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const query = try newQuery(allocator, key);
    // `kCFBooleanTrue`, not an NSNumber built here — Swift's `true` bridges to
    // the `__NSCFBoolean` singleton.
    try setQueryValue(query, kSecReturnData, kCFBooleanTrue);
    try setQueryValue(query, kSecMatchLimit, kSecMatchLimitOne);

    var result: CFTypeRef = null;
    const status = SecItemCopyMatching(query, &result);

    if (status == errSecItemNotFound) return null;
    if (status != errSecSuccess) {
        logStatus("get", key, status);
        return bridge_error.BridgeError.NativeCallFailed;
    }

    const data = result orelse {
        // errSecSuccess with no object should be impossible; if it happens it
        // is not "nothing stored" and must not be answered as `null`.
        std.log.warn("secure store get for key '{s}' returned errSecSuccess with no data", .{key});
        return bridge_error.BridgeError.NativeCallFailed;
    };
    defer CFRelease(data);

    // Swift's `result as? Data`: one message send to be sure this is not
    // something else read as raw bytes.
    if (!try isData(data)) {
        std.log.warn("secure store get for key '{s}' returned a non-CFData result", .{key});
        return bridge_error.BridgeError.NativeCallFailed;
    }

    const len = try dataLength(data);
    const bytes: []const u8 = if (len == 0)
        // `-bytes` is documented to return nil for empty data.
        &[_]u8{}
    else
        (try dataBytes(data) orelse {
            std.log.warn("secure store get for key '{s}' returned {d} bytes at a nil pointer", .{ key, len });
            return bridge_error.BridgeError.NativeCallFailed;
        })[0..len];

    if (!std.unicode.utf8ValidateSlice(bytes)) {
        // The item exists; only its bytes cannot ride a string-valued API.
        // Swift resolves `null` here, indistinguishable from "not stored".
        std.log.warn("secure store item for key '{s}' is not valid UTF-8; this API only returns strings", .{key});
        return bridge_error.BridgeError.InvalidParameter;
    }

    return try allocator.dupe(u8, bytes);
}

/// Delete `key`; absent is `true`, any other failure is `false` with the
/// status logged — Swift's `status == errSecSuccess || status ==
/// errSecItemNotFound`, verbatim.
fn keychainDelete(allocator: std.mem.Allocator, key: []const u8) !bool {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const query = try newQuery(allocator, key);
    const status = SecItemDelete(query);
    if (status == errSecSuccess or status == errSecItemNotFound) return true;
    logStatus("remove", key, status);
    return false;
}

/// Delete every generic-password item the app can see — the class-only query
/// is the entire scope, and the module comment names what that includes. An
/// already-empty store is `true`, as in Swift.
fn keychainClear() !bool {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSMutableDictionary = objc.objc_getClass("NSMutableDictionary") orelse return error.ClassNotFound;
    const sel_dictionary = objc.sel_registerName("dictionary") orelse return error.SelectorNotFound;
    const query = objc.msgSendId(NSMutableDictionary, sel_dictionary);
    if (query == null) return error.QueryAllocationFailed;

    try setQueryValue(query, kSecClass, kSecClassGenericPassword);

    const status = SecItemDelete(query);
    if (status == errSecSuccess or status == errSecItemNotFound) return true;
    logStatus("clear", "*", status);
    return false;
}

/// `-[NSObject isKindOfClass:[NSData class]]`; true for the toll-free-bridged
/// `CFDataRef` the keychain hands back.
fn isData(obj: Id) !bool {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSData = objc.objc_getClass("NSData") orelse return error.ClassNotFound;
    const sel_kind = objc.sel_registerName("isKindOfClass:") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id, Id) callconv(.c) bool;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(obj, sel_kind, NSData);
}

/// `-[NSData length]`. `NSUInteger`, hence `c_ulong`.
fn dataLength(data: Id) !usize {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel_length = objc.sel_registerName("length") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id) callconv(.c) c_ulong;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return @intCast(func(data, sel_length));
}

/// `-[NSData bytes]` — not `-UTF8String`, which a `CFDataRef` does not answer;
/// that typo would be a runtime crash, not a compile error. The pointer is
/// valid until the data is released, which the caller does after copying.
fn dataBytes(data: Id) !?[*]const u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel_bytes = objc.sel_registerName("bytes") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id) callconv(.c) ?[*]const u8;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(data, sel_bytes);
}

// =============================================================================
// Tests — host-only. Everything that decides what the page sees (routing,
// parsing, fragment shaping) is a pure function beside the Security calls, and
// the Security calls themselves are never made from here: three of the four
// handlers fail validation before reaching them, and `secureClear`, which has
// no validation to fail at, is pinned through `routeFor` alone (invoking it
// would address the login keychain of whatever machine runs the tests).
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 4), capability_actions.len);
    try testing.expectEqualStrings(A.secure_set, capability_actions[0].name);
    try testing.expectEqualStrings(A.secure_get, capability_actions[1].name);
    try testing.expectEqualStrings(A.secure_remove, capability_actions[2].name);
    try testing.expectEqualStrings(A.secure_clear, capability_actions[3].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("secureSet", A.secure_set);
    try testing.expectEqualStrings("secureGet", A.secure_get);
    try testing.expectEqualStrings("secureRemove", A.secure_remove);
    try testing.expectEqualStrings("secureClear", A.secure_clear);
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

test "the payload-taking actions fail validation before any Security call" {
    // `{}` has no `key`, so set/get/remove error out before the keychain is
    // touched — which is what makes this safe on a developer's machine, and
    // what rules out a routed name whose handler ignores its payload contract.
    // `secureClear` is deliberately absent: it has no payload and no
    // validation gate, so invoking it here would be a real class-wide delete.
    var bridge = SecureStoreBridge.init(testing.allocator);
    defer bridge.deinit();

    const payload_actions = [_][]const u8{ A.secure_set, A.secure_get, A.secure_remove };
    for (payload_actions) |name| {
        try testing.expectError(
            bridge_error.BridgeError.MissingData,
            bridge.handleMessage(name, "{}"),
        );
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = SecureStoreBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Near misses — casing is how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("secureset", "{}"),
    );
    // The JS surface names, which are not action names.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("secureStore", "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("secureStorage", "{}"),
    );
    // The sharedItems namespace next door shares the *keychain* with this
    // module but must not share the dispatch: two modules claiming one action
    // would make `ios_dispatch`'s first-match routing order-dependent.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("setSharedItem", "{\"key\":\"k\",\"value\":\"v\"}"),
    );
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = SecureStoreBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.secure_get, "{not json"),
    );
}

fn expectKeyError(json: []const u8, expected: anyerror) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, parseKey(parsed.value));
}

fn expectSetError(json: []const u8, expected: anyerror) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, parseSetRequest(parsed.value));
}

test "the field names the page sends are the ones that are read" {
    // `{action:'secureSet', key: key, value: value, callbackId: id}` in the
    // injected JS; the shim reads `body["key"]` / `body["value"]`. A rename on
    // either side of the migration would make the two handlers read different
    // payloads.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"key\":\"token\",\"value\":\"abc123\"}",
        .{},
    );
    defer parsed.deinit();

    const request = try parseSetRequest(parsed.value);
    try testing.expectEqualStrings("token", request.key);
    try testing.expectEqualStrings("abc123", request.value);
    try testing.expectEqualStrings("token", try parseKey(parsed.value));
}

test "an absent key is refused rather than defaulted" {
    try expectKeyError("{}", bridge_error.BridgeError.MissingData);
    try expectSetError("{\"value\":\"v\"}", bridge_error.BridgeError.MissingData);
}

test "an absent value is refused rather than stored as empty" {
    // Swift's `if let value = body["value"] as? String` fails here and replies
    // nothing at all — the legacy promise has no timeout, so that is a hang. A
    // default of `""` would be worse: it would overwrite a real secret and
    // resolve `true`.
    try expectSetError("{\"key\":\"k\"}", bridge_error.BridgeError.MissingData);
}

test "a non-string key or value is refused, not coerced" {
    try expectKeyError("{\"key\":7}", bridge_error.BridgeError.InvalidParameter);
    try expectKeyError("{\"key\":null}", bridge_error.BridgeError.InvalidParameter);
    try expectSetError("{\"key\":\"k\",\"value\":7}", bridge_error.BridgeError.InvalidParameter);
    try expectSetError("{\"key\":\"k\",\"value\":null}", bridge_error.BridgeError.InvalidParameter);
}

test "an explicitly empty value is a value, and is stored" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"key\":\"k\",\"value\":\"\"}",
        .{},
    );
    defer parsed.deinit();
    const request = try parseSetRequest(parsed.value);
    try testing.expectEqualStrings("", request.value);
}

test "a key with an embedded NUL is refused, not truncated" {
    // `stringWithUTF8String:` stops at the first NUL, so an unchecked
    // "a\u0000b" would address the item named "a" while the reply reported on
    // the full key — and `secureGet("a")` would then hand back a secret filed
    // under a different page key.
    try expectKeyError("{\"key\":\"a\\u0000b\"}", bridge_error.BridgeError.InvalidParameter);
    try expectSetError(
        "{\"key\":\"a\\u0000b\",\"value\":\"v\"}",
        bridge_error.BridgeError.InvalidParameter,
    );

    // The *value* keeps its NUL: `makeData` passes bytes and a length, so
    // nothing truncates, and the NSData round-trip test below proves it.
    // Refusing it would drop a payload the handler carries fine — and Swift
    // stores it whole too, so this is the compatible answer, not the lenient
    // one.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"key\":\"k\",\"value\":\"a\\u0000b\"}",
        .{},
    );
    defer parsed.deinit();
    const request = try parseSetRequest(parsed.value);
    try testing.expectEqualSlices(u8, &[_]u8{ 'a', 0, 'b' }, request.value);
}

test "a payload that is not an object is bad JSON, not a missing field" {
    try expectKeyError("[]", bridge_error.BridgeError.InvalidJSON);
    try expectKeyError("\"key\"", bridge_error.BridgeError.InvalidJSON);
}

test "the boolean replies are the two bare fragments and nothing else" {
    // Swift resolves with `.fragmentsAllowed`, so the page receives the JSON
    // fragment `true` or `false` — not `{"success":true}`, which is the shape
    // next door in sharedItems and would break `craft.secureStore.set`'s
    // boolean contract.
    try testing.expectEqualStrings("true", boolFragment(true));
    try testing.expectEqualStrings("false", boolFragment(false));
}

test "a found value and a missing one are different fragments" {
    const found = try valueFragment(testing.allocator, "abc123");
    defer testing.allocator.free(found);
    try testing.expectEqualStrings("\"abc123\"", found);

    // A nil String? cast `as Any` bridges to NSNull, which serializes as the
    // fragment `null` — the promise *resolves* with null, it does not reject.
    const missing = try valueFragment(testing.allocator, null);
    defer testing.allocator.free(missing);
    try testing.expectEqualStrings("null", missing);

    // A stored empty string is not a missing item.
    const empty = try valueFragment(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("\"\"", empty);
}

test "a page-controlled value cannot break the reply" {
    // The fragment is replayed into JavaScript that `evaluateJavaScript:`
    // parses as source; an unescaped quote in a stored secret would be a
    // syntax error in the page. The NUL matters too: a value stored with one
    // must survive the round trip through the JSON escape.
    const json = try valueFragment(testing.allocator, "we\"ird\\secret\nwith\x00nul");
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("we\"ird\\secret\nwith\x00nul", parsed.value.string);
}

test "the constants that are branched on are the documented ones" {
    // `errSecItemNotFound` is the difference between `null`/`true` and a
    // failure on three of the four actions; a wrong `errSecSuccess` would make
    // every call look failed.
    try testing.expectEqual(@as(OSStatus, 0), errSecSuccess);
    try testing.expectEqual(@as(OSStatus, -25300), errSecItemNotFound);
}

// The remaining tests exercise the Objective-C half against the live runtime —
// libobjc and Foundation only, no keychain, skipped off Darwin. They exist
// because a wrong selector string is a runtime crash or a silent no-op, never
// a compile error, and these are this file's own copies of the selectors.

test "the NSData selectors round-trip bytes, embedded NUL included" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    // The NUL is the point: `length`/`bytes` rather than `UTF8String`, which
    // would truncate a stored secret at the first zero byte and report the
    // truncation as the value.
    const payload = "se\x00cret";
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

    // Stands in for "the keychain returned something else" — the case that
    // must not be read as raw bytes and handed to the page as a secret.
    const ns = try objc.createNSString("not data", testing.allocator);
    try testing.expect(!try isData(ns));
}

test "the query builder produces a dictionary the runtime accepts" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    // Proves the `kSec*` globals resolve, `NSMutableDictionary` allocates, and
    // `setObject:forKey:`'s selector is spelled right — without a single
    // `SecItem*` call, so the host keychain is never touched. A headless CI
    // runner may have no login keychain at all, and a test depending on one is
    // a flake, not a gate; the write/read/delete round trip needs the
    // simulator fixture.
    const query = try newQuery(testing.allocator, "conformance-probe");
    try testing.expect(query != null);
}
