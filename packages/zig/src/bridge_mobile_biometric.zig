//! The biometric "session persistence" actions of the `mobile` namespace:
//! `setBiometricPersistence`, `checkBiometricPersistence`,
//! `clearBiometricPersistence`.
//!
//! **Despite the name, there is no Keychain, no `SecAccessControl` and no
//! `LAContext` here.** Swift implements all three against one in-memory field —
//! `private var biometricSessionExpiry: Date?` (CraftApp.swift:4434) — and
//! nothing else in that file reads it: the actual biometric prompt never
//! consults it. The "session" is bookkeeping the page asked to be kept and
//! reads back, which makes this the rare mobile action set that is pure Zig —
//! module state plus a millisecond clock, no Objective-C at all, and therefore
//! no Darwin gate anywhere in this file. It behaves identically on every
//! platform the dispatch chain compiles for.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **The reply shapes**, per `craft.d.ts:1256` and the Swift dictionary
//!    literals: enable answers `{"enabled":true,"duration":…,"expiresAt":…}`,
//!    disable `{"enabled":false}`, check `{"isValid":…,"remainingSeconds":…}`,
//!    clear `{"cleared":true}` — always, even when nothing was set.
//!  - **The unit mismatch.** `expiresAt` is epoch *milliseconds*
//!    (`timeIntervalSince1970 * 1000`); `remainingSeconds` is *seconds*.
//!    Ugly, shipped, load-bearing.
//!  - **An absent `duration` defaults to 300**, in agreement with both layers
//!    above this one: the injected JS posts `duration || 300` and the Swift
//!    dispatcher falls back with `?? 300`. A *present* `0` or negative reaches
//!    Swift as itself and makes an instantly-expired session, so it does here.
//!  - **`check` never clears an expired session.** It answers
//!    `{"isValid":false,"remainingSeconds":0}` and leaves the stale expiry in
//!    place, exactly as Swift leaves the stale `Date`. Only an explicit
//!    `clear` or a disable drops it. Expired and never-set are the same reply,
//!    indistinguishable by design.
//!  - **Strict `<` at the boundary**: Swift's `Date() < expiry` means the
//!    session is already invalid at the exact instant it expires.
//!
//! ## What is deliberately not carried across
//!
//! **Swift's silent hang.** The dispatcher arm is
//! `if let enabled = body["enabled"] as? Bool` with no else
//! (CraftApp.swift:1003), so a missing or non-bool `enabled` replies nothing
//! and the page's promise never settles. Here it is `MissingData` /
//! `InvalidParameter`.
//!
//! **Swift's silent re-typing of `duration`.** `as? Double ?? 300` rewrites a
//! present-but-non-numeric `duration` into 300 and reports success — a payload
//! field the page sent, replaced with a different value. Here it is
//! `InvalidParameter`; only *absence* defaults, because absence is what the
//! injected JS actually sends on the disable path.
//!
//! **`biometricSessionDuration`** (CraftApp.swift:4435) — written on every
//! enable, read by nothing, ever. Not replicated.
//!
//! ## The one migration hazard: the state must move whole
//!
//! The expiry lives in whichever language serves the action. If Zig served
//! `check` while the un-migrated Swift shim still served `set`, the two would
//! each hold their own expiry and a session Swift enabled would check as
//! invalid. All three actions therefore live in this one module and enter
//! `mobile_bridges` together; serving a subset of them from Zig is the one
//! wrong way to deploy this file.
//!
//! The state is a module-level `?f64` with no lock: every access happens
//! inside `handleMessage`, which runs in the `WKScriptMessageHandler` callback
//! on the main thread (the same argument `readApplicationState` in
//! `bridge_mobile_device.zig` records). It does not survive relaunch — but
//! neither did Swift's, and outliving the process would be a *stronger*
//! promise than the page was given.

const std = @import("std");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const compat = @import("compat.zig");

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// The conformance ratchet matches these strings against `CraftApp.swift` in
/// both directions, so a tidier spelling would register as Zig serving an
/// action the spec does not have.
pub const A = struct {
    pub const set_biometric_persistence = "setBiometricPersistence";
    pub const check_biometric_persistence = "checkBiometricPersistence";
    pub const clear_biometric_persistence = "clearBiometricPersistence";
};

/// All three `.result` and `.live`: every Swift path ends in exactly one
/// `resolveCallback`, every injected `craft.authPersistence` method returns a
/// promise the page awaits, and nothing here needs a framework, an
/// entitlement, or a device.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.set_biometric_persistence, .reply = .result },
    .{ .name = A.check_biometric_persistence, .reply = .result },
    .{ .name = A.clear_biometric_persistence, .reply = .result },
};

/// Which handler an action selects, or null for one this namespace does not
/// serve. Split from `handleMessage` so the table-versus-dispatch agreement
/// is assertable without driving the handlers.
const Route = enum { set_persistence, check_persistence, clear_persistence };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.set_biometric_persistence)) return .set_persistence;
    if (std.mem.eql(u8, action, A.check_biometric_persistence)) return .check_persistence;
    if (std.mem.eql(u8, action, A.clear_biometric_persistence)) return .clear_persistence;
    return null;
}

/// When the current session stops being valid, in epoch milliseconds — the
/// unit `expiresAt` is answered in — or null when no session is set.
///
/// `f64` rather than `i64` because Swift's arithmetic is all `Double`: a
/// fractional `duration` is legal JSON, accepted by Swift, and produces a
/// fractional expiry that `check` must subtract from faithfully. The one
/// non-finite route into this variable is closed at `expiryFor`.
///
/// Module state, not instance state, and `init` must never touch it: the
/// dispatch chain constructs a fresh bridge per message, and an `init` that
/// reset this would wipe the session between the `set` that stored it and the
/// `check` that reads it. Tests reset it explicitly for the same reason.
var session_expiry_ms: ?f64 = null;

pub const BiometricStoreBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const route = routeFor(action) orelse return bridge_error.BridgeError.UnknownAction;
        // Exhaustive, so a `Route` added without a handler is a compile error
        // instead of a silently unreachable action.
        return switch (route) {
            .set_persistence => self.setBiometricPersistence(data),
            // `check` and `clear` carry no payload — the injected JS posts
            // only the callback id — so `data` is ignored the way
            // `getAppState` ignores it, rather than validated against a
            // contract that does not exist.
            .check_persistence => self.checkBiometricPersistence(),
            .clear_persistence => self.clearBiometricPersistence(),
        };
    }

    /// Start a session (`enabled:true`) or drop it (`enabled:false`).
    ///
    /// The state is written only after every fallible step, so a refused
    /// payload cannot half-apply: an `InvalidParameter` set leaves whatever
    /// session existed exactly as it was, which is what the error told the
    /// page.
    fn setBiometricPersistence(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const request = try parseSetRequest(parsed.value);

        var buf: [768]u8 = undefined;
        const json: []const u8 = if (request.enabled) blk: {
            const now: f64 = @floatFromInt(compat.milliTimestamp());
            const expiry = try expiryFor(now, request.duration_seconds);
            // Reply built *before* the state is committed: `enableReply` is
            // fallible in type (`bufPrint` can refuse), and a failure after
            // the write would enable a session while telling the page it
            // failed — the half-applied outcome this ordering rules out.
            const reply = try enableReply(&buf, request.duration_seconds, expiry);
            session_expiry_ms = expiry;
            break :blk reply;
        } else blk: {
            session_expiry_ms = null;
            break :blk disable_reply;
        };
        bridge_error.sendResultToJS(self.allocator, A.set_biometric_persistence, json);
    }

    /// Is there a live session, and for how much longer.
    fn checkBiometricPersistence(self: *Self) !void {
        var buf: [512]u8 = undefined;
        const now: f64 = @floatFromInt(compat.milliTimestamp());
        const json = try checkReply(&buf, session_expiry_ms, now);
        bridge_error.sendResultToJS(self.allocator, A.check_biometric_persistence, json);
    }

    /// Drop the session. Unconditionally `{"cleared":true}`, as in Swift —
    /// clearing a session that never existed is not a failure a caller could
    /// act on, and `clear` is idempotent the way `removeSharedItem` is.
    fn clearBiometricPersistence(self: *Self) !void {
        session_expiry_ms = null;
        bridge_error.sendResultToJS(self.allocator, A.clear_biometric_persistence, clear_reply);
    }
};

/// One `set` request, after validation.
const SetRequest = struct {
    enabled: bool,
    /// Seconds, as the page sends it. 300 when absent — the default both
    /// layers above already apply.
    duration_seconds: f64 = 300,
};

/// Parse `d`, distinguishing a bad payload from a failed allocation.
/// `OutOfMemory` propagates as itself: telling the page INVALID_JSON about
/// its own good JSON sends whoever debugs it to the wrong side of the bridge.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
}

/// The `enabled`/`duration` pair, or the reason it cannot be used.
///
/// Pure, so the host tests can pin every outcome Swift's `if let` collapsed
/// into one silent fall-through. The field names are pinned on both sides of
/// the migration: `handleAction` in `CraftApp.swift` parses `d` straight into
/// `body` and the un-migrated arm reads `body["enabled"]` and
/// `body["duration"]`.
///
/// `duration` is read — and type-checked — on the disable path too, where its
/// value goes unused. The injected JS never sends it there, so anything
/// present came from a hand-rolled post, and a request malformed in the field
/// it chose to send is refused whole rather than half-read.
fn parseSetRequest(payload: std.json.Value) !SetRequest {
    const object = switch (payload) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    const enabled_field = object.get("enabled") orelse return bridge_error.BridgeError.MissingData;
    const enabled = switch (enabled_field) {
        .bool => |b| b,
        else => return bridge_error.BridgeError.InvalidParameter,
    };

    var request = SetRequest{ .enabled = enabled };

    if (object.get("duration")) |duration_field| {
        request.duration_seconds = switch (duration_field) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => return bridge_error.BridgeError.InvalidParameter,
        };
        // JSON cannot spell NaN or a literal infinity, but it can spell
        // `1e999`, which `std.json` parses to +inf rather than refusing. An
        // infinite duration would put `inf` — not JSON — into the reply.
        // Swift fares no better: it stores the infinite Date and its
        // `resolveCallback` then dies inside `JSONSerialization`, which
        // refuses non-finite numbers. Refusing up front is the honest version
        // of the same outcome.
        if (!std.math.isFinite(request.duration_seconds)) return bridge_error.BridgeError.InvalidParameter;
    }

    return request;
}

/// `Date(timeIntervalSinceNow: duration)`, in epoch milliseconds.
///
/// Fallible because f64 arithmetic can leave the finite range even when
/// `duration` itself is finite: a duration near 1.8e305 seconds survives
/// `parseSetRequest`'s check and overflows in the `* 1000.0` here. An
/// infinite expiry would render as `inf` and break every later reply, so
/// "a duration no clock can represent" is `InvalidParameter`.
fn expiryFor(now_ms: f64, duration_seconds: f64) !f64 {
    const expiry = now_ms + duration_seconds * 1000.0;
    if (!std.math.isFinite(expiry)) return bridge_error.BridgeError.InvalidParameter;
    return expiry;
}

/// `{"enabled":true,"duration":…,"expiresAt":…}` — the enable reply.
///
/// `bufPrint`, not the escaping builder `bridge_mobile_storage.zig` needs:
/// every interpolated value is a number this module computed, and `{d}` on a
/// finite f64 always renders plain decimal — never scientific, never `inf` —
/// which is exactly the JSON number grammar. Whole values print without a
/// trailing `.0`, so `"duration":300` reaches the page as the integer it
/// sent; JavaScript does not distinguish.
fn enableReply(buf: []u8, duration_seconds: f64, expires_at_ms: f64) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"enabled\":true,\"duration\":{d},\"expiresAt\":{d}}}",
        .{ duration_seconds, expires_at_ms },
    );
}

/// The disable reply. No `duration` and no `expiresAt`: Swift's disable arm
/// answers the one field, and inventing the others would describe a session
/// that no longer exists.
const disable_reply = "{\"enabled\":false}";

/// Doubles as the expired-session reply: Swift renders "never set" and
/// "expired" identically (`isValid:false, remainingSeconds:0`), and the page
/// cannot tell them apart by design.
const no_session_reply = "{\"isValid\":false,\"remainingSeconds\":0}";

/// The clear reply. Unconditional, as in Swift.
const clear_reply = "{\"cleared\":true}";

/// `{"isValid":…,"remainingSeconds":…}` — the check reply.
///
/// Pure in `(expiry, now)` so every branch is a host test with a chosen
/// clock. Three Swift behaviours are pinned here: an expired-but-set timer is
/// `false`/`0` and never a negative remainder; `Date() < expiry` is strict,
/// so the exact expiry instant is already invalid; and `remainingSeconds` is
/// *seconds* while the stored expiry (and `expiresAt`) are milliseconds — the
/// divide by 1000 is the contract, not a tidy-up.
fn checkReply(buf: []u8, expiry_ms: ?f64, now_ms: f64) ![]const u8 {
    const expiry = expiry_ms orelse return no_session_reply;
    if (!(now_ms < expiry)) return no_session_reply;
    return std.fmt.bufPrint(
        buf,
        "{{\"isValid\":true,\"remainingSeconds\":{d}}}",
        .{(expiry - now_ms) / 1000.0},
    );
}

const testing = std.testing;

test "every declared action is one the dispatcher routes" {
    // The failure the mechanism exists to prevent: a name in the table that
    // `handleMessage` has never heard of, which the manifest then promises.
    for (capability_actions) |decl| {
        if (routeFor(decl.name) == null) {
            std.debug.print("declared action '{s}' does not route\n", .{decl.name});
            return error.DeclaredActionDoesNotRoute;
        }
    }
}

test "every route the dispatcher has is a declared action" {
    // The other direction. `handleMessage` switches exhaustively over
    // `Route`, so a route without a handler cannot compile; this catches a
    // route with a handler and no declaration. Each declaration must claim a
    // *distinct* route — two rows naming one action would leave another
    // route undeclared while the count still matched.
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

test "the action names are the ones the Swift dispatcher answers" {
    // The wire contract, spelled out: a rename here is invisible until a page
    // stops being answered.
    try testing.expectEqualStrings("setBiometricPersistence", A.set_biometric_persistence);
    try testing.expectEqualStrings("checkBiometricPersistence", A.check_biometric_persistence);
    try testing.expectEqualStrings("clearBiometricPersistence", A.clear_biometric_persistence);
}

test "all three actions resolve a promise and none is declared beyond its means" {
    // `.live` is honest here precisely because nothing native is involved:
    // there is no framework to be missing and no entitlement to lack.
    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = BiometricStoreBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Casing is how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("setbiometricpersistence", "{}"),
    );
    // The desktop biometric bridge's vocabulary, which is a different
    // namespace this module must not shadow.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("evaluate", "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("getBiometryType", "{}"),
    );
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = BiometricStoreBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.set_biometric_persistence, "{not json"),
    );
}

/// Parse a literal payload straight through to a `SetRequest`. Unlike
/// storage's `Request`, this one holds no slices into the parsed tree, so it
/// can be returned past the parse's deinit.
fn parseSetFromLiteral(json: []const u8) !SetRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return parseSetRequest(parsed.value);
}

test "the two field names the page sends are the two that are read" {
    const request = try parseSetFromLiteral("{\"enabled\":true,\"duration\":300}");
    try testing.expect(request.enabled);
    try testing.expectEqual(@as(f64, 300), request.duration_seconds);
}

test "a missing enabled is refused, not left hanging" {
    // Swift's `if let enabled = body["enabled"] as? Bool` has no else, so
    // this exact payload leaves the page's promise pending forever. Every
    // path here answers.
    try testing.expectError(bridge_error.BridgeError.MissingData, parseSetFromLiteral("{}"));
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        parseSetFromLiteral("{\"duration\":300}"),
    );
}

test "a non-bool enabled is refused, not coerced" {
    // JavaScript truthiness stops at the bridge: 1 and "true" are not `true`,
    // and guessing which way the page meant them would enable or disable a
    // session it did not ask about.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseSetFromLiteral("{\"enabled\":1}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseSetFromLiteral("{\"enabled\":\"true\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseSetFromLiteral("{\"enabled\":null}"),
    );
}

test "an absent duration defaults to 300, matching both layers above" {
    const enable = try parseSetFromLiteral("{\"enabled\":true}");
    try testing.expectEqual(@as(f64, 300), enable.duration_seconds);
    // The disable path is where absence is the *normal* case: the injected
    // JS `disable()` sends no duration field at all.
    const disable = try parseSetFromLiteral("{\"enabled\":false}");
    try testing.expect(!disable.enabled);
    try testing.expectEqual(@as(f64, 300), disable.duration_seconds);
}

test "a present duration is taken at its word, zero and negative included" {
    // The injected JS maps a falsy duration to 300 *before posting*, so a 0
    // arriving here was sent deliberately by a hand-rolled post — and Swift
    // honours it as an instantly-expired session. Re-defaulting it would
    // silently alter a field the page sent.
    try testing.expectEqual(@as(f64, 0), (try parseSetFromLiteral("{\"enabled\":true,\"duration\":0}")).duration_seconds);
    try testing.expectEqual(@as(f64, -60), (try parseSetFromLiteral("{\"enabled\":true,\"duration\":-60}")).duration_seconds);
    try testing.expectEqual(@as(f64, 2.5), (try parseSetFromLiteral("{\"enabled\":true,\"duration\":2.5}")).duration_seconds);
}

test "a non-numeric duration is refused, not silently replaced with 300" {
    // Swift's `as? Double ?? 300` rewrites `"duration":"300"` into 300 and
    // reports success — the dropped-payload-field bug, verbatim.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseSetFromLiteral("{\"enabled\":true,\"duration\":\"300\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseSetFromLiteral("{\"enabled\":true,\"duration\":{}}"),
    );
    // The disable path validates too: the value is unused there, but a
    // request malformed in the field it chose to send is refused whole.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseSetFromLiteral("{\"enabled\":false,\"duration\":[]}"),
    );
}

test "a duration JSON can spell but no clock can hold is refused" {
    // `1e999` is legal JSON and `std.json` parses it to +inf rather than
    // refusing. Left through, it would print `inf` into the reply — which is
    // not JSON — and Swift's own reply serialisation refuses non-finite
    // numbers anyway.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseSetFromLiteral("{\"enabled\":true,\"duration\":1e999}"),
    );
}

test "a payload that is not an object is bad JSON, not a missing field" {
    try testing.expectError(bridge_error.BridgeError.InvalidJSON, parseSetFromLiteral("[]"));
    try testing.expectError(bridge_error.BridgeError.InvalidJSON, parseSetFromLiteral("true"));
}

test "the expiry is now plus the duration, in milliseconds" {
    try testing.expectEqual(@as(f64, 1301000), try expiryFor(1001000, 300));
    // Fractional durations survive: 1.5005 s is 1500.5 ms.
    try testing.expectEqual(@as(f64, 1001500.5), try expiryFor(1000000, 1.5005));
    // A negative duration is a legal, instantly-expired session, as in
    // Swift's `Date(timeIntervalSinceNow:)`.
    try testing.expectEqual(@as(f64, 940000), try expiryFor(1000000, -60));
}

test "a finite duration whose expiry is not finite is refused" {
    // floatMax survives `parseSetRequest`'s finiteness check; the `* 1000.0`
    // here is what overflows. Letting it through would store `inf` and break
    // every later `check`.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        expiryFor(0, std.math.floatMax(f64)),
    );
}

test "the enable reply is the Swift dictionary verbatim, expiresAt in milliseconds" {
    var buf: [768]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"enabled\":true,\"duration\":300,\"expiresAt\":1301000}",
        try enableReply(&buf, 300, 1301000),
    );
}

test "a fractional duration is echoed back, not rounded" {
    var buf: [768]u8 = undefined;
    const json = try enableReply(&buf, 2.5, 1756480000002.5);
    try testing.expectEqualStrings(
        "{\"enabled\":true,\"duration\":2.5,\"expiresAt\":1756480000002.5}",
        json,
    );

    // And it is JSON whose numbers survive as numbers.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("enabled").?.bool);
    try testing.expectEqual(@as(f64, 2.5), parsed.value.object.get("duration").?.float);
    try testing.expectEqual(@as(f64, 1756480000002.5), parsed.value.object.get("expiresAt").?.float);
}

test "a live session answers true and the remainder in seconds" {
    var buf: [512]u8 = undefined;
    // The stored expiry and `now` are milliseconds; the reply divides. The
    // units differ from `expiresAt` on purpose, because they differ in Swift.
    try testing.expectEqualStrings(
        "{\"isValid\":true,\"remainingSeconds\":300}",
        try checkReply(&buf, 1301000, 1001000),
    );
    // Sub-second remainders keep their fraction.
    try testing.expectEqualStrings(
        "{\"isValid\":true,\"remainingSeconds\":1.5}",
        try checkReply(&buf, 1001500, 1000000),
    );
}

test "no session, an expired session and the exact expiry instant all answer the same" {
    var buf: [512]u8 = undefined;
    // Never set.
    try testing.expectEqualStrings(no_session_reply, try checkReply(&buf, null, 1000000));
    // Expired: zero, never a negative remainder — Swift's ternary pins that.
    try testing.expectEqualStrings(no_session_reply, try checkReply(&buf, 999000, 1000000));
    // Swift's `Date() < expiry` is strict: at the boundary, the session is
    // already over.
    try testing.expectEqualStrings(no_session_reply, try checkReply(&buf, 1000000, 1000000));
}

test "the constant replies are the fields the SDK type declares, and nothing more" {
    // `craft.d.ts`: disable() -> {enabled}, check() -> {isValid,
    // remainingSeconds}, clear() -> {cleared}. The field counts matter too:
    // extra fields would be harmless to today's stringify-only consumers and
    // a lie to the next one.
    const disable = try std.json.parseFromSlice(std.json.Value, testing.allocator, disable_reply, .{});
    defer disable.deinit();
    try testing.expect(!disable.value.object.get("enabled").?.bool);
    try testing.expectEqual(@as(usize, 1), disable.value.object.count());

    const none = try std.json.parseFromSlice(std.json.Value, testing.allocator, no_session_reply, .{});
    defer none.deinit();
    try testing.expect(!none.value.object.get("isValid").?.bool);
    try testing.expectEqual(@as(i64, 0), none.value.object.get("remainingSeconds").?.integer);
    try testing.expectEqual(@as(usize, 2), none.value.object.count());

    const cleared = try std.json.parseFromSlice(std.json.Value, testing.allocator, clear_reply, .{});
    defer cleared.deinit();
    try testing.expect(cleared.value.object.get("cleared").?.bool);
    try testing.expectEqual(@as(usize, 1), cleared.value.object.count());
}

test "enable stores the expiry the reply names; disable and clear drop it" {
    session_expiry_ms = null;
    defer session_expiry_ms = null;

    var bridge = BiometricStoreBridge.init(testing.allocator);
    defer bridge.deinit();

    // The reply itself goes to a webview this process does not have —
    // `sendResultToJS` swallows that, as `bridge_mobile_device.zig`'s log
    // test already relies on — so the observable half on a host is the state.
    const before = compat.milliTimestamp();
    try bridge.handleMessage(A.set_biometric_persistence, "{\"enabled\":true,\"duration\":300}");
    const after = compat.milliTimestamp();

    const expiry = session_expiry_ms orelse return error.SessionNotStored;
    try testing.expect(expiry >= @as(f64, @floatFromInt(before)) + 300000);
    try testing.expect(expiry <= @as(f64, @floatFromInt(after)) + 300000);

    try bridge.handleMessage(A.set_biometric_persistence, "{\"enabled\":false}");
    try testing.expect(session_expiry_ms == null);

    try bridge.handleMessage(A.set_biometric_persistence, "{\"enabled\":true}");
    try testing.expect(session_expiry_ms != null);
    try bridge.handleMessage(A.clear_biometric_persistence, "{}");
    try testing.expect(session_expiry_ms == null);
}

test "a refused set leaves the session exactly as it was" {
    // The half-applied failure mode: state written before validation. The
    // page was told InvalidParameter, so nothing may have changed.
    session_expiry_ms = 123456789;
    defer session_expiry_ms = null;

    var bridge = BiometricStoreBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.set_biometric_persistence, "{\"enabled\":\"yes\",\"duration\":300}"),
    );
    try testing.expectEqual(@as(?f64, 123456789), session_expiry_ms);

    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.set_biometric_persistence, "{\"duration\":300}"),
    );
    try testing.expectEqual(@as(?f64, 123456789), session_expiry_ms);
}

test "check reports an expired session without clearing it" {
    // Swift leaves the stale Date in place; `check` is a reader here too.
    // Only `clear` and disable remove it, and a later `set` overwrites it.
    session_expiry_ms = 5; // 1970, long expired
    defer session_expiry_ms = null;

    var bridge = BiometricStoreBridge.init(testing.allocator);
    defer bridge.deinit();

    try bridge.handleMessage(A.check_biometric_persistence, "{}");
    try testing.expectEqual(@as(?f64, 5), session_expiry_ms);
}
