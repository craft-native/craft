//! The WatchConnectivity actions of the `mobile` namespace that Zig can serve
//! honestly: `updateWatchContext` and `isWatchReachable`.
//!
//! `sendToWatch` is deliberately **not** in the `A` block — see the last
//! section. It is not `.unavailable`; it is absent, so `ios_dispatch`'s
//! first-match chain falls through to the Swift shim that serves it correctly
//! today.
//!
//! One JS surface reaches these: the Swift-injected `window.craft.watch`
//! object. `updateContext(context)` posts `{action:'updateWatchContext',
//! context: context, callbackId: id}`; `isReachable()` posts the action alone.
//! Neither promise goes through `_createCallback`, so neither has a timeout —
//! a dropped message parks the page forever, which is why every path here ends
//! in a reply or an error.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **Both replies are objects, not bare fragments.** This is the one place
//!    this module differs from every mobile module migrated before it. Swift
//!    serialises with `.fragmentsAllowed`, which *permits* a bare value but
//!    does not *unwrap* a dictionary, and both of these Swift paths resolve
//!    dictionaries: `["reachable": reachable]` and `["updated": true]`. So the
//!    wire shapes are `{"reachable":true}` / `{"reachable":false}` and
//!    `{"updated":true}` — never `true` / `false`. Both consumers depend on the
//!    wrapper: `craft.d.ts` types them `Promise<{reachable: boolean}>` and
//!    `Promise<{updated: boolean}>`, and `test-bridges.html` prints
//!    `JSON.stringify(result)`, which would render `false` instead of
//!    `{"reachable":false}` if the wrapper were dropped. `result.reachable`
//!    would be `undefined` in every real app. The reply-shape tests below pin
//!    the wrapper explicitly, because "match the sibling modules" is exactly
//!    the wrong instinct here.
//!  - **The payload field is `context`** — not `applicationContext`, not
//!    `data`. That is what the injected JS posts and what the Swift shim reads
//!    (`body["context"] as? [String: Any]`), pinned on both sides of the
//!    migration. The `callbackId` also present is correlation plumbing the Zig
//!    envelope replaces with `i`; it is ignored, not consumed.
//!  - **The context is carried whole and nested.** Swift's hand-off path
//!    rebuilds it with `JSONSerialization.jsonObject(with:)`, so nested values
//!    arrive as Foundation containers; `toFoundationDictionary` below takes the
//!    same byte route, and produces the same Foundation types.
//!    `updateApplicationContext:` requires property list types, and all but
//!    one of those are: `NSString`, `NSNumber`, `NSArray` and `NSDictionary`.
//!    The exception is `NSNull`, which a JSON `null` becomes and which is
//!    *not* a property list type — a context carrying one is refused with
//!    `WCErrorCodePayloadUnsupportedTypes`, mapped below to
//!    `InvalidParameter`. That is not a divergence: WebKit hands Swift the
//!    same `NSNull` for the same `null`, so the shim's
//!    `updateApplicationContext` throws on it too.
//!  - **An empty context is legal.** `WCSession.h`: "If there is no app
//!    context, it should be updated with an empty dictionary." `{}` is passed
//!    through, not refused.
//!  - **A missing or unactivated session answers `{"reachable":false}`,** not
//!    an error. Swift's `wcSession?.isReachable ?? false` says the same thing
//!    for the same reason: no session, no reachable watch.
//!
//! ## What is deliberately not carried across
//!
//! **Swift's silent hang.** The `updateWatchContext` dispatcher arm is
//! `if let context = body["context"] as? [String: Any]` with **no `else`**: a
//! missing `context`, or a `context` that is not an object, replies nothing at
//! all and the untimed promise never settles. Malformed input errors here
//! instead — `MissingData` when the field is absent, `InvalidParameter` when it
//! is present but not an object. Same divergence, same argument, as
//! `bridge_mobile_notifcancel.zig`'s missing-`id` note.
//!
//! **The rejection *text*.** `sendErrorToJS` carries a `BridgeError` enum;
//! there is no free-text channel. Swift rejects with
//! `error.localizedDescription` ("The payload contained unsupported types.",
//! "The session is not activated.") and `test-bridges.html` prints
//! `e.message`. This is a precedented loss, not a new one —
//! `bridge_mobile_misc.zig` documents the identical trade for `setFlashlight`,
//! and `bridge_mobile_securestore.zig` for its OSStatus mapping. The specifics
//! go to the log: `updateApplicationContext:error:` is called with a real
//! `NSError` out-parameter (unlike `misc`'s null one) precisely because the
//! `WCErrorCode` is genuinely diagnostic, and the domain, code and
//! `localizedDescription` are all logged before the enum is chosen.
//!
//! **The `enableWatchApp` config gate.** Swift only ever calls
//! `setupWatchConnectivity` under `if config.enableWatchApp`, and that flag has
//! no Zig mirror — it appears nowhere in `packages/zig/src`. Both actions are
//! therefore served unconditionally, exactly as `securestore` and `notifcancel`
//! document for their own gates. This grants a page nothing it should not have:
//! with the gate off Swift never activated a session, so `defaultSession`'s
//! `activationState` is `NotActivated` and both actions answer honestly —
//! `{"reachable":false}` and a refusal to update.
//!
//! ## Read-only: no `activateSession`, no `setDelegate:`, ever
//!
//! `WCSession` is a singleton, so when Swift's `setupWatchConnectivity` ran,
//! `+[WCSession defaultSession]` hands Zig the very same object Swift already
//! delegated and activated. Reading it is safe. Activating it from Zig is not,
//! twice over:
//!
//!  - `WCSession.h` says "A delegate must exist before the session will allow
//!    sends" and that calling activate without one is undefined. Zig cannot
//!    supply a `WCSessionDelegate` without `objc_allocateClassPair` plus three
//!    `@required` methods.
//!  - It would stomp the Swift delegate that feeds the `craftWatchMessage` and
//!    `craftWatchReachability` events the page already listens for.
//!
//! So `resolveSession` reads `isSupported`, `defaultSession` and
//! `activationState` and stops. The `activationState` check is a deliberate,
//! tiny divergence from Swift's plain nil-check: the header says the session
//! "must be activated on startup before the session's properties contain
//! correct values", so reading `isReachable` on an unactivated session reads an
//! undefined value. In every case where the guard changes the answer, Swift's
//! answer was `false` too (its ivar was nil) — and for `updateWatchContext` it
//! turns the common "watch support was never enabled" case into a nameable
//! refusal instead of a generic `WCErrorCodeSessionNotActivated`.
//!
//! ## No bundle-identifier guard, and no exception hazard
//!
//! Do not copy `bridge_mobile_notifcancel.zig`'s bundle guard reflexively. That
//! exists because `[UNUserNotificationCenter currentNotificationCenter]`
//! *raises* `NSInternalInconsistencyException` in a process with no bundle id,
//! and an uncaught ObjC exception is an uncatchable SIGABRT. Every
//! `WCSession` failure mode reached here is a `nil`, a `NO`, or an `NSError`:
//! `WCError.h` defines `SessionMissingDelegate = 7003`,
//! `SessionNotActivated = 7004`, `DeviceNotPaired = 7005`,
//! `WatchAppNotInstalled = 7006`, `NotReachable = 7007`,
//! `InvalidParameter = 7008`, `PayloadTooLarge = 7009`,
//! `PayloadUnsupportedTypes = 7010` — **error codes, not exceptions**. Calling
//! `updateApplicationContext:error:` on an unactivated or delegate-less session
//! returns `NO` and an `NSError`; it does not raise.
//!
//! `WCSession.h` is `API_UNAVAILABLE(macos)`, so on a native macOS host test
//! runner `objc_getClass("WCSession")` returns null. That is not a failure —
//! it is the honest `{"reachable":false}`, identical to Swift's nil ivar, and
//! it is the one live Objective-C path the host tests below can actually
//! exercise. `build.zig` links no `WatchConnectivity` framework anywhere; in
//! the Swift-hosted app the framework is in the process because `CraftApp.swift`
//! does `import WatchConnectivity`, so `objc_getClass` resolves. In a
//! hypothetical Zig-only app it would not, and `isWatchReachable` would report
//! `false` forever — honest, and worth knowing.
//!
//! ## Why `sendToWatch` is absent rather than `.unavailable`
//!
//! `-[WCSession sendMessage:replyHandler:errorHandler:]` takes two
//! one-argument blocks, and `WCSession.h` guarantees that **exactly one of them
//! is invoked** and that both fire on "a non-main serial queue". Zig can build
//! the reply-handler half: a global block plus `ios_async.deliverJson` would
//! resolve the watch's dictionary correctly.
//!
//! It cannot build the error half. `ios_async` has no error-delivery path —
//! `deliverOnMain` ends unconditionally in `bridge_error.sendResultToJS`, and
//! `sendErrorToJS` appears nowhere in that file. Every available move is a rule
//! violation:
//!
//!  - resolve something on the error path → fabricated success;
//!  - `ios_async.abandon` the ticket → silence on an untimed promise, the exact
//!    bug `ios_async` exists to prevent;
//!  - call `craft_ios_deliver_error` from the block → that export does not hop
//!    to the main queue, so it would reach `evaluateJavaScript` from
//!    WatchConnectivity's background delegate queue.
//!
//! And the error path is the *common* path here, not the exotic one: unpaired
//! simulator, watch app not installed, not reachable, reply timed out. The
//! bundled `CraftWatchApp.swift.template` implements only
//! `session(_:didReceiveMessage:)` — the no-reply variant — so against the
//! shipped companion the reply handler never fires and the error handler always
//! does.
//!
//! The Swift shim serves all of this correctly today: its reply handler routes
//! through `deliverResultIfHandOff` and its error handler through
//! `deliverErrorIfHandOff`, rejecting the page's promise with the real
//! `localizedDescription`. Declaring the action `.unavailable` would *steal* it
//! from that shim and turn every call into a refusal, which is strictly worse
//! than what ships now. So the action is omitted from `A` entirely and falls
//! through.
//!
//! Unblocking condition, precisely: `sendToWatch` becomes migratable the moment
//! `ios_async` gains a `deliverError(ticket, BridgeError)` — a slot field plus
//! one branch in `deliverOnMain` — at which point it still costs the
//! `localizedDescription` text, and must additionally call
//! `+[NSJSONSerialization isValidJSONObject:]` before serialising the watch's
//! reply. Swift does not: `resolveCallback` hands the reply straight to
//! `dataWithJSONObject:`, which *raises* `NSInvalidArgumentException` for the
//! `NSDate`/`NSData` values `WCSession` permits, and Swift's `catch` cannot
//! catch that. A watch replying `["at": Date()]` aborts the app today; Zig must
//! not reproduce it.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The same type as `objc.id` — `?*anyopaque` — spelled locally.
///
/// `objc_runtime.objc` is an empty struct off Darwin, and a function
/// *signature* is analysed even when a comptime platform guard makes its body
/// unreachable, so naming `objc.id` in the `callconv(.c)` types below would
/// break the host build. It stays a single optional pointer, never `?objc.id`:
/// a double optional is illegal in a `callconv(.c)` type.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches the two lists by string in both
/// directions.
///
/// `sendToWatch` is absent on purpose — the module comment's last section
/// gives the full argument. An action listed here is an action this module
/// takes away from the Swift shim, and that trade is only worth making when
/// Zig's answer is at least as good.
pub const A = struct {
    pub const update_watch_context = "updateWatchContext";
    pub const is_watch_reachable = "isWatchReachable";
};

/// Both `.result`: each Swift path terminates in exactly one
/// `resolveCallback`, and both injected JS methods return untimed promises the
/// page awaits — `.none` here would strand a caller forever, not for thirty
/// seconds.
///
/// Both `.live`. Neither needs a permission prompt, an entitlement or a
/// completion handler: reading `isReachable` and calling
/// `updateApplicationContext:error:` are synchronous. `.unavailable` is for an
/// action that dispatches and refuses, and neither of these does.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.update_watch_context, .reply = .result },
    .{ .name = A.is_watch_reachable, .reply = .result },
};

// -----------------------------------------------------------------------------
// Reply fragments.
//
// Objects, not bare booleans. Swift resolves `["reachable": …]` and
// `["updated": true]` dictionaries; `.fragmentsAllowed` permits a bare value
// but never unwraps a dictionary into one. Static, so replying allocates
// nothing.
// -----------------------------------------------------------------------------

const reachable_true = "{\"reachable\":true}";
const reachable_false = "{\"reachable\":false}";

/// `updateWatchContext` has no `false` reply: Swift's failure path *rejects*,
/// it does not resolve `{"updated":false}`.
const updated_true = "{\"updated\":true}";

fn reachableFragment(reachable: bool) []const u8 {
    return if (reachable) reachable_true else reachable_false;
}

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host, where
/// `WCSession` does not exist.
const Route = enum { update_context, is_reachable };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.update_watch_context)) return .update_context;
    if (std.mem.eql(u8, action, A.is_watch_reachable)) return .is_reachable;
    return null;
}

pub const WatchBridge = struct {
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
            .update_context => self.updateWatchContext(data),
            .is_reachable => self.isWatchReachable(),
        };
    }

    /// Push a new application context to the paired watch.
    ///
    /// Validation runs before any Objective-C, so a payload the handler must
    /// refuse is refused identically on every platform and the host tests can
    /// pin it without a `WCSession` in sight.
    fn updateWatchContext(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const context = try parseContext(parsed.value);

        const session = switch (try resolveSession()) {
            .active => |s| s,
            .absent => |why| {
                // Swift rejects here too ("Watch session not available"), and
                // its message is the thing this bridge cannot carry — so the
                // specific reason goes to the log and the page gets the one
                // code that fits: there is no session to update.
                std.log.warn(
                    "updateWatchContext: no usable WCSession ({s}); refusing rather than reporting an update that did not happen",
                    .{@tagName(why)},
                );
                return bridge_error.BridgeError.NotFound;
            },
        };

        try pushApplicationContext(self.allocator, session, context);

        bridge_error.sendResultToJS(self.allocator, A.update_watch_context, updated_true);
    }

    /// Answer whether the paired watch is reachable right now.
    ///
    /// Never an error on a working iOS device: an absent, unsupported or
    /// unactivated session is `{"reachable":false}`, which is both true and
    /// exactly what Swift's `wcSession?.isReachable ?? false` returns. The
    /// payload is ignored, as Swift ignores the body — the injected JS posts
    /// the action alone and `ios_dispatch.payloadOf` hands this `"{}"`.
    fn isWatchReachable(self: *Self) !void {
        const reachable = switch (try resolveSession()) {
            .active => |s| readIsReachable(s),
            .absent => |why| blk: {
                std.log.info("isWatchReachable: no usable WCSession ({s}); answering false", .{@tagName(why)});
                break :blk false;
            },
        };

        bridge_error.sendResultToJS(self.allocator, A.is_watch_reachable, reachableFragment(reachable));
    }
};

// =============================================================================
// Payload parsing. Pure, so every outcome Swift's `as? [String: Any]`
// collapsed into a silent hang is pinnable on a host.
// =============================================================================

/// Parse `d`, distinguishing a bad payload from a failed allocation — telling
/// the page INVALID_JSON about its own good JSON sends whoever debugs it to
/// the wrong side of the bridge.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
}

/// The `context` field as a JSON object, or the reason it cannot be used.
///
/// No `requireNulFree` here, and that is deliberate rather than an omission.
/// The sibling modules refuse embedded NULs because their route to Foundation
/// is `stringWithUTF8String:`, which truncates. This one re-serialises to bytes
/// and goes through `+[NSJSONSerialization JSONObjectWithData:options:error:]`,
/// which is length-based: a NUL in a key or a value survives intact, so there
/// is nothing to refuse. `bridge_mobile_shortcuts.zig` documents the same
/// exemption for `userInfo`.
fn parseContext(payload: std.json.Value) !std.json.Value {
    const object = switch (payload) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
    const field = object.get("context") orelse return bridge_error.BridgeError.MissingData;
    return switch (field) {
        .object => field,
        // Swift's `as? [String: Any]` fails here and replies nothing at all.
        // A coercion would be worse: `updateApplicationContext:` takes a
        // dictionary, and wrapping a string in one would sync a context the
        // page never asked for and report `{"updated":true}` for it.
        else => bridge_error.BridgeError.InvalidParameter,
    };
}

/// Re-serialise a parsed value to JSON bytes for `NSJSONSerialization`.
///
/// `std.json.Value` does not remember its source span, so this walk exists.
/// Duplicated from `bridge_mobile_shortcuts.zig`, where it is file-private by
/// design — the same way `securestore` duplicated its externs rather than
/// widening another module's surface.
///
/// Strings and keys go through `bridge_error.appendJsonEscaped`, which escapes
/// every control byte including NUL; an unescaped control byte would make the
/// bytes invalid JSON that Foundation refuses, turning a legal context into a
/// refusal.
///
/// The `.float` arm refuses a non-finite value: `{d}` would render `inf`,
/// which is not JSON, and the failure would otherwise surface as an opaque nil
/// from Foundation. That arm is a guard against a hand-built `Value`, not
/// against a payload — `std.json` never parses a number into a non-finite
/// `.float`. See the `.number_string` arm for where an out-of-range literal
/// actually lands.
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
        // Reachable under the *default* options, contrary to what the copy of
        // this walk in `bridge_mobile_shortcuts.zig` claims: `std.json` falls
        // back to `.number_string` for an integer literal that overflows `i64`
        // (`99999999999999999999`) and for a float literal that parses
        // non-finite (`1e400`). The bytes are the scanner-validated source
        // token, so re-emitting them verbatim is both valid JSON and the only
        // lossless answer — rendering them through `{d}` would round
        // `99999999999999999999` to a different number, and refusing them
        // would drop a field Swift delivers. (Swift delivers it *rounded*:
        // WebKit hands the shim a JS double, so the legacy path loses the
        // extra digits this one keeps. Keeping more of the page's payload is
        // the safe direction to differ in.)
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
// WCError mapping. Pure and table-driven, so the choice of code is reviewable
// without a paired watch.
// =============================================================================

/// `WCErrorDomain`, spelled out rather than read from the framework's global:
/// the symbol only exists when WatchConnectivity is linked, and this comparison
/// must work in the host build too.
const wc_error_domain = "WCErrorDomain";

// `WCError.h`, verbatim. Only the codes this module can distinguish are named;
// the rest fall to the catch-all deliberately.
const wc_device_not_paired: c_long = 7005;
const wc_watch_app_not_installed: c_long = 7006;
const wc_invalid_parameter: c_long = 7008;
const wc_payload_too_large: c_long = 7009;
const wc_payload_unsupported_types: c_long = 7010;

/// The nearest `BridgeError` for an `NSError` from
/// `updateApplicationContext:error:`.
///
/// Domain-checked before the code is read, because `NSError` codes are
/// domain-scoped: a `7008` from some other domain means something else
/// entirely, and mapping it to `InvalidParameter` would blame the page for a
/// failure that was not its payload's fault.
///
/// The mapping is lossy in exactly the way `bridge_mobile_misc.zig` and
/// `bridge_mobile_securestore.zig` already are — `sendErrorToJS` carries an
/// enum, not text — so the caller logs the domain, code and
/// `localizedDescription` before calling this.
fn bridgeErrorForNSError(domain: ?[]const u8, code: c_long) bridge_error.BridgeError {
    const d = domain orelse return bridge_error.BridgeError.NativeCallFailed;
    if (!std.mem.eql(u8, d, wc_error_domain)) return bridge_error.BridgeError.NativeCallFailed;

    return switch (code) {
        // The page sent something WatchConnectivity will not carry. Its
        // payload is the thing to change, so name it.
        wc_invalid_parameter,
        wc_payload_too_large,
        wc_payload_unsupported_types,
        => bridge_error.BridgeError.InvalidParameter,

        // There is no watch on the other end to receive the context.
        wc_device_not_paired,
        wc_watch_app_not_installed,
        => bridge_error.BridgeError.NotFound,

        // Everything else, including SessionNotActivated (7004) and
        // SessionMissingDelegate (7003), which `resolveSession` normally
        // catches first.
        else => bridge_error.BridgeError.NativeCallFailed,
    };
}

// =============================================================================
// The Objective-C half. Read-only on the session; see the module comment.
//
// Main thread throughout: `ios_dispatch.handleMessage` runs synchronously from
// `craftDidReceiveScriptMessage`, a `WKScriptMessageHandler` callback WebKit
// delivers on the main thread — the reasoning is written out at
// `bridge_mobile_display.zig`. Both calls here are synchronous, so no
// `ios_async` ticket and no main-queue hop are involved; the only action in
// this namespace with a completion handler is the one this module does not
// serve.
// =============================================================================

/// `WCSessionActivationState`. `NotActivated = 0, Inactive = 1, Activated = 2`.
const activation_state_activated: c_long = 2;

/// Why there is no session to talk to. Each variant is a distinct, nameable
/// cause the log can print; the page sees one answer for all of them, because
/// Swift gave one answer for all of them too.
const NoSession = enum {
    /// `objc_getClass("WCSession")` was null — WatchConnectivity is not in the
    /// process. Always the case on a macOS host: `WCSession.h` is
    /// `API_UNAVAILABLE(macos)`.
    framework_absent,
    /// `+[WCSession isSupported]` said NO — iPad, or another device with no
    /// watch pairing support.
    unsupported_device,
    /// `+[WCSession defaultSession]` returned nil, which the header does not
    /// document but which costs one branch to survive.
    no_default_session,
    /// The singleton exists but nobody activated it — Swift's
    /// `setupWatchConnectivity` never ran, which is what `enableWatchApp:
    /// false` looks like from here. Its properties are undefined until
    /// activation, so they are not read.
    not_activated,
};

const Session = union(enum) {
    absent: NoSession,
    active: *anyopaque,
};

/// The default `WCSession`, if there is one that has been activated.
///
/// `.absent` is a real answer, not a failure: both callers have something
/// honest to do with it. Only the platform gate is an error, because off
/// Darwin there is no question to answer.
fn resolveSession() !Session {
    if (!is_darwin) return error.UnsupportedPlatform;

    const WCSession = objc.objc_getClass("WCSession") orelse
        return .{ .absent = .framework_absent };

    const sel_supported = objc.sel_registerName("isSupported") orelse return error.SelectorNotFound;
    if (!objc.msgSendBool(WCSession, sel_supported)) return .{ .absent = .unsupported_device };

    const sel_default = objc.sel_registerName("defaultSession") orelse return error.SelectorNotFound;
    const session = objc.msgSendId(WCSession, sel_default) orelse
        return .{ .absent = .no_default_session };

    // `activationState` is an `NSInteger` property; `objc_runtime.zig` has no
    // integer-returning helper, so the cast is local.
    const sel_state = objc.sel_registerName("activationState") orelse return error.SelectorNotFound;
    const StateFn = *const fn (Id, objc.SEL) callconv(.c) c_long;
    const state_fn: StateFn = @ptrCast(&objc.objc_msgSend);
    if (state_fn(session, sel_state) != activation_state_activated) {
        return .{ .absent = .not_activated };
    }

    return .{ .active = session };
}

/// `-[WCSession isReachable]`. Only ever called on an activated session, where
/// the header says the property is meaningful.
fn readIsReachable(session: *anyopaque) bool {
    if (!is_darwin) return false;

    const sel = objc.sel_registerName("isReachable") orelse return false;
    return objc.msgSendBool(session, sel);
}

/// `-[WCSession updateApplicationContext:error:]` — synchronous, `BOOL`, no
/// completion handler.
///
/// The `NSError` out-parameter is passed for real rather than null, which is
/// where this differs from `bridge_mobile_misc.zig`'s `lockForConfiguration:`:
/// there the BOOL was the whole answer, here the `WCErrorCode` is what tells
/// "your payload is too large" apart from "there is no watch", and both the log
/// line and the chosen `BridgeError` depend on it.
fn pushApplicationContext(
    allocator: std.mem.Allocator,
    session: *anyopaque,
    context: std.json.Value,
) !void {
    if (!is_darwin) return error.UnsupportedPlatform;

    const dictionary = try toFoundationDictionary(allocator, context);

    const sel_update = objc.sel_registerName("updateApplicationContext:error:") orelse
        return error.SelectorNotFound;

    var err_out: Id = null;
    const UpdateFn = *const fn (Id, objc.SEL, Id, ?*Id) callconv(.c) bool;
    const update_fn: UpdateFn = @ptrCast(&objc.objc_msgSend);
    if (update_fn(session, sel_update, dictionary, &err_out)) return;

    // A NO with no error object is not something the header allows, but a
    // nil-dereference here would be a crash where a refusal belongs.
    const ns_error = err_out orelse {
        std.log.warn("updateWatchContext: updateApplicationContext: returned NO with no NSError", .{});
        return bridge_error.BridgeError.NativeCallFailed;
    };

    const domain = readNSString(ns_error, "domain");
    const code = readNSInteger(ns_error, "code");
    // The one channel a `BridgeError` enum leaves for Swift's
    // `error.localizedDescription`, which the page used to receive verbatim.
    std.log.warn(
        "updateWatchContext: updateApplicationContext: failed — domain={s} code={d} description={s}",
        .{
            domain orelse "(none)",
            code,
            readNSString(ns_error, "localizedDescription") orelse "(none)",
        },
    );
    return bridgeErrorForNSError(domain, code);
}

/// A parsed JSON object as the Foundation containers
/// `updateApplicationContext:` accepts, via
/// `+[NSJSONSerialization JSONObjectWithData:options:error:]` (autoreleased).
///
/// The round trip through bytes is the honest route, and the same one Swift's
/// hand-off path takes: NSString keys and values built this way keep embedded
/// NULs that `stringWithUTF8String:` would truncate, and the containers it
/// produces are the ones `updateApplicationContext:` wants. The one type it
/// produces that is *not* a property list type is `NSNull`, from a JSON
/// `null`; that is refused by `updateApplicationContext:` itself with
/// `WCErrorCodePayloadUnsupportedTypes`, exactly as it refuses the `NSNull`
/// WebKit hands the Swift shim. A nil back from here is the earlier failure —
/// the context holds something JSON cannot carry — and is `InvalidParameter`,
/// with the log naming it, since the error code alone cannot.
fn toFoundationDictionary(allocator: std.mem.Allocator, value: std.json.Value) !*anyopaque {
    if (!is_darwin) return error.UnsupportedPlatform;

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
        std.log.warn("updateWatchContext: the context did not survive NSJSONSerialization; refusing", .{});
        return bridge_error.BridgeError.InvalidParameter;
    };
}

/// A zero-argument `NSString`-returning property, as bytes. Null for a nil
/// string or a selector that will not register — both are "nothing to log",
/// never a crash.
fn readNSString(object: Id, comptime selector: [*:0]const u8) ?[]const u8 {
    if (!is_darwin) return null;

    const sel = objc.sel_registerName(selector) orelse return null;
    const value = objc.msgSendId(object, sel) orelse return null;
    const utf8 = objc.getNSStringUTF8(value) orelse return null;
    return std.mem.span(utf8);
}

/// A zero-argument `NSInteger`-returning property.
fn readNSInteger(object: Id, comptime selector: [*:0]const u8) c_long {
    if (!is_darwin) return 0;

    const sel = objc.sel_registerName(selector) orelse return 0;
    const Fn = *const fn (Id, objc.SEL) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(object, sel);
}

// =============================================================================
// Tests — host-only.
//
// Everything that decides what the page sees is pure and pinned here: routing
// in both directions, the omission of `sendToWatch`, the `context` field name,
// the refusals Swift turned into a silent hang, the byte walk that carries the
// nested context, the WCError mapping, and — the rule-4 regression test — the
// object wrappers on both reply fragments.
//
// The one live Objective-C path a host can run is `resolveSession` on macOS,
// where `objc_getClass("WCSession")` is null because `WCSession.h` is
// `API_UNAVAILABLE(macos)`. That is asserted for real. Nothing here activates
// a session or writes an application context: on a runner that did have a live
// session, that would push a context to somebody's actual watch.
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    try testing.expectEqualStrings(A.update_watch_context, capability_actions[0].name);
    try testing.expectEqualStrings(A.is_watch_reachable, capability_actions[1].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        // `.reason` is only meaningful on an `.unavailable` row; a stray one
        // here would be shown to an app about an action that works.
        try testing.expect(decl.reason == null);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("updateWatchContext", A.update_watch_context);
    try testing.expectEqualStrings("isWatchReachable", A.is_watch_reachable);
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

test "sendToWatch is left to the Swift shim, not claimed and not refused" {
    // The deliberate omission, asserted so it cannot be "fixed" by accident.
    //
    // `ios_dispatch`'s chain treats UnknownAction as "not mine, ask the next"
    // and any other error as final. So the *only* spelling of "let the shim
    // keep serving this" is: absent from `A`, absent from `routeFor`, and
    // UnknownAction out of `handleMessage`. An `.unavailable` declaration
    // would dispatch and refuse, stealing an action the shim answers correctly
    // today — including the error path, which `ios_async` cannot yet deliver.
    var bridge = WatchBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expect(routeFor("sendToWatch") == null);
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("sendToWatch", "{\"message\":{\"action\":\"ping\"}}"),
    );

    for (capability_actions) |decl| {
        try testing.expect(!std.mem.eql(u8, decl.name, "sendToWatch"));
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = WatchBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Near misses — casing is how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("iswatchreachable", "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("updatewatchcontext", "{\"context\":{}}"),
    );
    // The JS surface method names, which are not action names.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("isReachable", "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("updateContext", "{\"context\":{}}"),
    );
    // The Swift *helper* name, which is not a dispatcher case.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("sendMessageToWatch", "{}"),
    );
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = WatchBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.update_watch_context, "{not json"),
    );
}

fn expectContextError(json: []const u8, expected: anyerror) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, parseContext(parsed.value));
}

test "the field name the page sends is the one that is read" {
    // `{action:'updateWatchContext', context: context, callbackId: id}` in the
    // injected JS; the shim reads `body["context"]`. A rename on either side of
    // the migration would make the two handlers read different payloads.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"context\":{\"status\":\"active\"},\"callbackId\":\"cb_7\"}",
        .{},
    );
    defer parsed.deinit();

    const context = try parseContext(parsed.value);
    try testing.expectEqualStrings("active", context.object.get("status").?.string);

    // The plausible wrong names are *absences*, not aliases — a payload
    // carrying only them must read as missing, or a handler bound to the wrong
    // name would pass this suite.
    try expectContextError("{\"applicationContext\":{\"a\":1}}", bridge_error.BridgeError.MissingData);
    try expectContextError("{\"data\":{\"a\":1}}", bridge_error.BridgeError.MissingData);
    try expectContextError("{\"message\":{\"a\":1}}", bridge_error.BridgeError.MissingData);
}

test "a missing context is refused rather than defaulted" {
    // Swift's `if let context = body["context"] as? [String: Any]` fails here
    // and replies nothing at all — the legacy promise has no timeout, so that
    // is a hang forever. An error is the deliberate divergence; defaulting to
    // `{}` would be worse, because an empty dictionary is a *meaningful*
    // context that clears whatever the watch was showing.
    var bridge = WatchBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.update_watch_context, "{}"),
    );
}

test "a context that is not an object is refused, not coerced" {
    try expectContextError("{\"context\":\"active\"}", bridge_error.BridgeError.InvalidParameter);
    try expectContextError("{\"context\":7}", bridge_error.BridgeError.InvalidParameter);
    try expectContextError("{\"context\":null}", bridge_error.BridgeError.InvalidParameter);
    try expectContextError("{\"context\":true}", bridge_error.BridgeError.InvalidParameter);
    // An array is the interesting one: it is a valid JSON *container* and
    // still not something `updateApplicationContext:` accepts.
    try expectContextError("{\"context\":[1,2]}", bridge_error.BridgeError.InvalidParameter);
}

test "an empty context is accepted, because the header says it is meaningful" {
    // `WCSession.h`: "If there is no app context, it should be updated with an
    // empty dictionary." Refusing `{}` would deny a page the documented way to
    // clear the context.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"context\":{}}",
        .{},
    );
    defer parsed.deinit();

    const context = try parseContext(parsed.value);
    try testing.expectEqual(@as(usize, 0), context.object.count());
}

test "a payload that is not an object is bad JSON, not a missing field" {
    try expectContextError("[]", bridge_error.BridgeError.InvalidJSON);
    try expectContextError("\"context\"", bridge_error.BridgeError.InvalidJSON);
    try expectContextError("null", bridge_error.BridgeError.InvalidJSON);
}

test "the replies are the objects Swift resolves, not bare fragments" {
    // The rule-4 regression test, and the reason this module is not like its
    // siblings. Swift resolves `["reachable": reachable]` and
    // `["updated": true]`; `.fragmentsAllowed` permits a bare value but never
    // unwraps a dictionary into one.
    //
    // `craft.d.ts` types these `Promise<{reachable: boolean}>` and
    // `Promise<{updated: boolean}>`, and `test-bridges.html` renders
    // `JSON.stringify(result)` — so a bare `false` here would print
    // "Watch reachable: false" instead of "Watch reachable: {"reachable":false}"
    // and make `result.reachable` undefined in every real app.
    try testing.expectEqualStrings("{\"reachable\":true}", reachableFragment(true));
    try testing.expectEqualStrings("{\"reachable\":false}", reachableFragment(false));
    try testing.expectEqualStrings("{\"updated\":true}", updated_true);

    // And they are parseable as the objects they claim to be, with the field
    // names the page reads.
    for ([_][]const u8{ reachable_true, reachable_false }) |fragment| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, fragment, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value.object.get("reachable").? == .bool);
    }
    var updated = try std.json.parseFromSlice(std.json.Value, testing.allocator, updated_true, .{});
    defer updated.deinit();
    try testing.expectEqual(true, updated.value.object.get("updated").?.bool);
}

test "there is no updated:false reply, because Swift rejects instead" {
    // `updateWatchContext`'s failure path is `rejectCallback`, not
    // `resolveCallback(["updated": false])`. A `false` fragment existing at all
    // would be an invitation to resolve one, which is fabricated success: the
    // page would see a settled promise for a context that never synced.
    try testing.expect(std.mem.indexOf(u8, updated_true, "false") == null);
}

fn serializeToOwned(value: std.json.Value) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try serializeJsonValue(testing.allocator, &out, value);
    return out.toOwnedSlice(testing.allocator);
}

fn expectRoundTrip(source: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, source, .{});
    defer parsed.deinit();

    const bytes = try serializeToOwned(parsed.value);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(expected, bytes);
}

test "the context is carried whole, nested values included" {
    // The dropped-field bug this migration exists to remove. Swift hands the
    // context to Foundation with its nesting intact; anything less here would
    // sync a context the page did not ask for and still reply
    // `{"updated":true}`.
    try expectRoundTrip(
        "{\"lastUpdate\":1700000000000,\"status\":\"active\"}",
        "{\"lastUpdate\":1700000000000,\"status\":\"active\"}",
    );
    try expectRoundTrip(
        "{\"a\":{\"b\":[1,true,null,\"c\"]}}",
        "{\"a\":{\"b\":[1,true,null,\"c\"]}}",
    );
    try expectRoundTrip("{}", "{}");
}

test "control bytes in keys and values are escaped, not emitted raw" {
    // An unescaped control byte makes the bytes invalid JSON, which Foundation
    // refuses — turning a legal context into a refusal. NUL is the one
    // `bridge_handoff.zig`'s older copy of this walk misses.
    try expectRoundTrip(
        "{\"a\\u0000b\":\"c\\u0000d\"}",
        "{\"a\\u0000b\":\"c\\u0000d\"}",
    );
    try expectRoundTrip("{\"k\":\"line\\nbreak\"}", "{\"k\":\"line\\nbreak\"}");
    try expectRoundTrip("{\"k\":\"quote\\\"and\\\\slash\"}", "{\"k\":\"quote\\\"and\\\\slash\"}");
}

test "an embedded NUL survives instead of being refused" {
    // The siblings refuse NULs because their route is `stringWithUTF8String:`,
    // which truncates. This one is length-based through
    // `NSJSONSerialization`, so there is nothing to refuse — and refusing
    // anyway would drop a payload the handler carries perfectly well.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"context\":{\"k\":\"a\\u0000b\"}}",
        .{},
    );
    defer parsed.deinit();

    const context = try parseContext(parsed.value);
    const value = context.object.get("k").?.string;
    try testing.expectEqual(@as(usize, 3), value.len);
    try testing.expectEqual(@as(u8, 0), value[1]);
}

test "a non-finite number is refused before Foundation sees it" {
    // `{d}` would render `inf`, which is not JSON; Foundation would answer nil
    // and the cause would be invisible.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);

    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        serializeJsonValue(testing.allocator, &out, .{ .float = std.math.inf(f64) }),
    );
    out.clearRetainingCapacity();
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        serializeJsonValue(testing.allocator, &out, .{ .float = std.math.nan(f64) }),
    );
}

test "a large float keeps its digits instead of overflowing the buffer" {
    // 1e300 is 301 digits in decimal notation; a [64]u8 would turn a legal
    // JSON number into a NoSpaceLeft refusal.
    const bytes = try serializeToOwned(.{ .float = 1e300 });
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len > 300);
    try testing.expectEqual(@as(u8, '1'), bytes[0]);
}

test "a number too big for i64 or f64 is carried verbatim, not rounded or dropped" {
    // The `.number_string` arm, which the sibling copy of this walk dismisses
    // as unreachable. It is not: `std.json` falls back to it for an integer
    // literal that overflows `i64` and for a float literal that parses
    // non-finite, both under the default options this module uses. Pinned
    // because the two wrong answers are silent — `{d}` on a rounded `f64`
    // would sync a *different* number than the page sent and still reply
    // `{"updated":true}`, and refusing would drop a field Swift carries.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"big\":99999999999999999999,\"huge\":1e400}",
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("big").? == .number_string);
    try testing.expect(parsed.value.object.get("huge").? == .number_string);

    try expectRoundTrip(
        "{\"big\":99999999999999999999,\"huge\":1e400}",
        "{\"big\":99999999999999999999,\"huge\":1e400}",
    );
}

test "WCError codes map to the nearest code the page can act on" {
    const E = bridge_error.BridgeError;

    // The page's payload is the thing to change.
    try testing.expectEqual(E.InvalidParameter, bridgeErrorForNSError(wc_error_domain, wc_invalid_parameter));
    try testing.expectEqual(E.InvalidParameter, bridgeErrorForNSError(wc_error_domain, wc_payload_too_large));
    try testing.expectEqual(E.InvalidParameter, bridgeErrorForNSError(wc_error_domain, wc_payload_unsupported_types));

    // There is no watch on the other end.
    try testing.expectEqual(E.NotFound, bridgeErrorForNSError(wc_error_domain, wc_device_not_paired));
    try testing.expectEqual(E.NotFound, bridgeErrorForNSError(wc_error_domain, wc_watch_app_not_installed));

    // Session state and everything unnamed.
    try testing.expectEqual(E.NativeCallFailed, bridgeErrorForNSError(wc_error_domain, 7003));
    try testing.expectEqual(E.NativeCallFailed, bridgeErrorForNSError(wc_error_domain, 7004));
    try testing.expectEqual(E.NativeCallFailed, bridgeErrorForNSError(wc_error_domain, 7007));
    try testing.expectEqual(E.NativeCallFailed, bridgeErrorForNSError(wc_error_domain, 0));
}

test "a code from another domain is not read as a WCError" {
    // `NSError` codes are domain-scoped. `NSCocoaErrorDomain` 7009 is not
    // PayloadTooLarge, and blaming the page's payload for it would send whoever
    // debugs it to the wrong side of the bridge.
    const E = bridge_error.BridgeError;
    try testing.expectEqual(E.NativeCallFailed, bridgeErrorForNSError("NSCocoaErrorDomain", wc_payload_too_large));
    try testing.expectEqual(E.NativeCallFailed, bridgeErrorForNSError("NSPOSIXErrorDomain", wc_device_not_paired));
    try testing.expectEqual(E.NativeCallFailed, bridgeErrorForNSError(null, wc_invalid_parameter));
    // A prefix match would be a silent widening; the comparison is exact.
    try testing.expectEqual(E.NativeCallFailed, bridgeErrorForNSError("WCErrorDomainExtra", wc_invalid_parameter));
}

test "validation outruns Objective-C on every platform" {
    // The same refusals with and without a runtime behind them: a payload the
    // handler must refuse is refused identically on Linux and macOS, which is
    // what makes the parser tests above binding for the device build too.
    var bridge = WatchBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.update_watch_context, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.update_watch_context, "{\"context\":\"active\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.update_watch_context, "[]"),
    );
}

test "off Darwin the handlers refuse rather than fake an answer" {
    if (is_darwin) return error.SkipZigTest;

    var bridge = WatchBridge.init(testing.allocator);
    defer bridge.deinit();

    // A valid payload, so the refusal is the platform's and not the parser's.
    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.update_watch_context, "{\"context\":{\"status\":\"active\"}}"),
    );
    // Notably *not* `{"reachable":false}`: off Darwin there is no WCSession
    // question to answer, and answering it anyway would be a claim nothing
    // checked.
    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.is_watch_reachable, "{}"),
    );
    try testing.expectError(error.UnsupportedPlatform, resolveSession());
}

test "on a macOS host WatchConnectivity is absent, and that is a real answer" {
    if (!is_darwin) return error.SkipZigTest;

    // `WCSession.h` is `API_AVAILABLE(ios, macCatalyst) API_UNAVAILABLE(macos)`,
    // so `objc_getClass` returns null here. This is the one live Objective-C
    // path a host can exercise, and the honest answer is exactly Swift's:
    // no session, no reachable watch.
    //
    // If a runner ever *does* resolve the class — a Catalyst host — pinning
    // `.framework_absent` would be wrong to force, so any absence is accepted.
    // What must never happen is `.active` on a machine with no paired watch.
    //
    // The second call is the load-bearing half, and the reason this is not a
    // tautology: `resolveSession` promises to be *read-only*. It reads
    // `isSupported`, `defaultSession` and `activationState` and stops — it
    // never calls `activate` or `setDelegate:`, because activating without a
    // `WCSessionDelegate` is undefined and would stomp the delegate feeding
    // the page's `craftWatchMessage` events. An implementation that activated
    // would change its own answer between these two calls, on the very host
    // where nothing else can catch it.
    const first = try resolveSession();
    switch (first) {
        .absent => {},
        .active => {
            // A live activated session on the test host means the runner is an
            // app with WatchConnectivity set up. Updating its context would
            // push to somebody's actual watch, so stop rather than pretend.
            return error.SkipZigTest;
        },
    }

    const second = try resolveSession();
    switch (second) {
        .absent => |why| try testing.expectEqual(first.absent, why),
        .active => return error.ResolveSessionActivatedTheSession,
    }
}

test "an absent session refuses the update instead of reporting one" {
    if (!is_darwin) return error.SkipZigTest;

    // The rule-1 case. There is no WCSession on this host, so nothing can have
    // been synced — `{"updated":true}` would be a fabricated success. The
    // refusal must come from the session check and not from the parser, so the
    // payload is a valid one.
    switch (try resolveSession()) {
        .active => return error.SkipZigTest,
        .absent => {},
    }

    var bridge = WatchBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.NotFound,
        bridge.handleMessage(A.update_watch_context, "{\"context\":{\"status\":\"active\"}}"),
    );
}

test "isWatchReachable answers false instead of erroring when there is no session" {
    if (!is_darwin) return error.SkipZigTest;

    // The property that makes this action `.reply = .result` and never a
    // rejection: Swift's `wcSession?.isReachable ?? false` always resolves, and
    // the promise it resolves has no timeout. A handler that errored here would
    // reject a call the page expects to settle with `{"reachable":false}`.
    //
    // This is the one test that runs a handler all the way to
    // `sendResultToJS`, so it logs one "failed to send bridge result to JS"
    // warning: there is no webview in a test runner. That warning is the
    // evidence the reply was attempted — the alternative, asserting only that
    // no error came back, would also pass for a handler that silently returned
    // without replying at all.
    switch (try resolveSession()) {
        .active => return error.SkipZigTest,
        .absent => {},
    }

    var bridge = WatchBridge.init(testing.allocator);
    defer bridge.deinit();

    try bridge.handleMessage(A.is_watch_reachable, "{}");
    // The payload is ignored, as Swift ignores the body — a page posting extra
    // fields must not turn a question into a refusal.
    try bridge.handleMessage(A.is_watch_reachable, "{\"callbackId\":\"cb_7\"}");
}
