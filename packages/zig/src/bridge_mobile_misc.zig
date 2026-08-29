//! The `mobile` namespace's flashlight action — and the recorded decision that
//! the other three actions scoped to this module (`getInitialURL`,
//! `registerDeepLinkHandler`, `takeScreenshot`) stay *unserved*, so that
//! `ios_dispatch.route` falls through to the Swift shim that answers them
//! correctly today. See `deliberately_unserved`.
//!
//! ## Why `setFlashlight` is the only arm
//!
//! It is the only one of the four with no `CraftConfig` gate in front of it:
//! the Swift dispatcher calls `setFlashlight(enabled:)` unconditionally, and
//! the injected capabilities blob hardcodes `flashlight: true`. Every step is
//! a synchronous AVFoundation call — no completion handler, no `ios_async`
//! ticket — so the whole exchange happens inside the dispatch frame that holds
//! the request id, on the main thread WebKit delivered it on.
//!
//! The other three founder on one missing channel: their Swift arms are
//! conditional on `CraftConfig` flags (`enableDeepLinks`,
//! `enableScreenCapture`) that exist only as Swift properties. Nothing carries
//! them to Zig — no export, no shared defaults, nothing to grep — so a Zig
//! handler cannot know whether the app author enabled the feature. Each action
//! adds its own reason on top:
//!
//!  - **`getInitialURL`** cannot be answered from Zig at all. The value lives
//!    in `DeepLinkManager.shared.initialURL` — a private property of a
//!    pure-Swift class that derives from nothing and declares no `@objc`, so
//!    `objc_getClass("DeepLinkManager")` cannot find it and neither `shared`
//!    nor `getInitialURL()` has an ObjC entry point. It is fed by SwiftUI's
//!    `.onOpenURL`, which Zig has no path to, and the launch URL is not
//!    re-derivable afterwards (not in the environment, not in NSUserDefaults).
//!  - **`registerDeepLinkHandler`** does nothing but acknowledge: Swift
//!    replies the bare boolean `true` iff `config.enableDeepLinks`; the real
//!    registration is the page's own `addEventListener('craftDeepLink', …)`.
//!    An unconditional `true` from Zig would report "registered" in apps where
//!    the event can never fire. No JS anywhere in the repo posts the action —
//!    the injected script, `test-bridges.html`, `craft-bridge.js` and the TS
//!    SDK are all silent — so there is also nothing to migrate *for*.
//!  - **`takeScreenshot`**'s capture is fully doable from Zig
//!    (`UIGraphicsBeginImageContextWithOptions` and friends, then
//!    `UIImagePNGRepresentation`), but `enableScreenCapture` defaults to
//!    *false* and Swift's arm skips the handler entirely when it is off.
//!    Serving it unconditionally would switch on a capability the app author
//!    turned off — fabricated authorization, the exact class of bug this
//!    migration exists to remove. It stays with the shim until a config
//!    channel exists.
//!
//! ## Why unserved rather than `.unavailable`
//!
//! `ios_dispatch.route` hands an action to `CraftSwiftShim` only when every
//! module answers `UnknownAction`. A declared-`.unavailable` action
//! *dispatches and refuses* — `bridge_mobile_display.lockOrientation` is the
//! precedent — so declaring these three would take them away from the shim,
//! replacing answers that are correct today with rejections. In a Zig-only
//! build with no shim, the fall-through degrades to an `UnknownAction` error
//! at the page, which is still the honest outcome: absent the config, craft
//! does not know whether these features are enabled, and an error a page can
//! see beats a guess it cannot.
//!
//! ## Build note
//!
//! A generated app autolinks AVFoundation (`CraftApp.swift` does
//! `import AVFoundation`). The zig-slice fixture
//! (`packages/ios/fixtures/zig-slice/build-and-run.sh`) links only
//! UIKit/WebKit/Foundation/Security, so there `objc_getClass("AVCaptureDevice")`
//! returns null until `-framework AVFoundation` is added — which the null
//! check reports as "no flashlight", the same rejection Swift's guard gives a
//! simulator. Honest either way, but the fixture needs the flag before the
//! torch can actually light.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;

/// The same type as `objc.id` — `?*anyopaque` — spelled locally.
///
/// `objc_runtime.objc` is an empty struct off Darwin, and a `callconv(.c)`
/// fn-pointer *type* is analysed even when a comptime platform guard makes the
/// code around it unreachable, so naming `objc.id` there would break the host
/// build. A single optional pointer, never `?objc.id`: a double optional is
/// illegal in a `callconv(.c)` signature.
const Id = ?*anyopaque;

/// `AVCaptureTorchMode`, from `AVCaptureDevice.h`. An `NSInteger`, hence
/// `c_long` — a narrower type would pass the right bits for 0 and 1 by luck
/// and break the day a new mode appears.
const AVCaptureTorchModeOff: c_long = 0;
const AVCaptureTorchModeOn: c_long = 1;

/// The action name, spelled exactly as the Swift `case` label spells it.
///
/// `test/ios_conformance_test.zig` reads this block as "actions Zig serves".
/// The three unserved actions this module documents must therefore *not*
/// appear here: listing one would tell the ratchet it migrated while the shim
/// is still the thing answering it.
pub const A = struct {
    pub const set_flashlight = "setFlashlight";
};

/// The actions this module was scoped to and, on purpose, does not serve.
///
/// Recorded as data rather than prose so a test can hold the two properties
/// the decision rests on: none of them is declared, and each still falls out
/// of `handleMessage` as `UnknownAction` — the one return `ios_dispatch.route`
/// converts into a Swift-shim hand-off. Whoever migrates one for real moves
/// its name from this list into `A` and updates the module comment.
pub const deliberately_unserved = [_][]const u8{
    "getInitialURL",
    "registerDeepLinkHandler",
    "takeScreenshot",
};

/// `.result`: every Swift path terminates in `resolveCallback(…, true)` or a
/// rejection, and the injected `setFlashlight` returns a promise the page can
/// await. `.live`: the no-torch outcome (simulator, torchless hardware, an
/// app that dropped AVFoundation) is a per-call rejection — a property of the
/// device the call found, not of the action.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.set_flashlight, .reply = .result },
};

/// Swift resolves with `resolveCallback(callbackId, result: true)`, serialized
/// `.fragmentsAllowed`, so the page receives the bare JSON boolean `true` —
/// not `{"success":true}`. No caller in the repo reads the resolved value
/// (`craft.d.ts` even types the method `void`), but the shape is the contract
/// and inventing an object here would change it.
const success_reply = "true";

pub const MiscBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.set_flashlight)) {
            try self.setFlashlight(data);
        } else {
            // `getInitialURL`, `registerDeepLinkHandler` and `takeScreenshot`
            // land here on purpose: `UnknownAction` is what routes an action
            // onward to the Swift shim. See the module comment.
            return BridgeError.UnknownAction;
        }
    }

    /// Turn the torch on or off, and say so with Swift's bare `true`.
    fn setFlashlight(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();

        const enabled = try parseEnabled(parsed.value);

        try setTorch(self.allocator, enabled);

        bridge_error.sendResultToJS(self.allocator, A.set_flashlight, success_reply);
    }
};

/// Parse `d`, distinguishing a bad payload from a failed allocation.
///
/// `OutOfMemory` propagates as itself: telling the page INVALID_JSON about its
/// own perfectly good JSON sends whoever debugs it to the wrong side of the
/// bridge.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return BridgeError.InvalidJSON,
    };
}

/// The `enabled` the page sent, or the reason it cannot be used. Pure, so the
/// host tests pin every outcome that Swift's `as? Bool` collapsed into one
/// silent fall-through.
///
/// The field name is the one the injected JS posts beside `action` and
/// `callbackId` — `{action: 'setFlashlight', enabled: enabled, …}` — and the
/// un-migrated shim reads `body["enabled"]`; both sides of the migration have
/// to read the same payload.
///
/// Swift's arm is `if let enabled = body["enabled"] as? Bool` with no `else`:
/// a missing or mistyped field replies nothing and the promise hangs for the
/// full request timeout. That is deliberately not carried across (the storage
/// module states the family policy); every path here ends in a value or an
/// error. One divergence rides along: `as? Bool` also lets the NSNumbers 0
/// and 1 through, so `{"enabled":1}` flips the torch via the shim today and
/// is `InvalidParameter` here — refused rather than coerced, as this family
/// refuses everywhere, and the typed surface
/// (`craft.d.ts: setFlashlight(enabled: boolean)`) never produces it.
fn parseEnabled(payload: std.json.Value) !bool {
    const object = switch (payload) {
        .object => |o| o,
        else => return BridgeError.InvalidJSON,
    };
    const field = object.get("enabled") orelse return BridgeError.MissingData;
    return switch (field) {
        .bool => |b| b,
        else => BridgeError.InvalidParameter,
    };
}

/// The raw `AVCaptureTorchMode` for a request. Pure, so the one value that
/// reaches the hardware is pinned by a host test rather than by reading the
/// header again — a swap would invert every page's flashlight with no error
/// anywhere.
fn torchModeFor(enabled: bool) c_long {
    return if (enabled) AVCaptureTorchModeOn else AVCaptureTorchModeOff;
}

/// `AVCaptureDevice.default(for: .video)` → `hasTorch` → lock, set, unlock.
///
/// Error mapping is lossy the same way the storage module's OSStatus mapping
/// is — `sendErrorToJS` carries an enum, not text — so Swift's two rejection
/// strings become the nearest `BridgeError` and the specifics go to the log:
/// every flavour of "Flashlight not available" (no framework, no device, no
/// torch) is `NotFound`, and a refused `lockForConfiguration:` (Swift's
/// `catch`, rejected with `error.localizedDescription`) is `NativeCallFailed`.
fn setTorch(allocator: std.mem.Allocator, enabled: bool) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const AVCaptureDevice = objc.objc_getClass("AVCaptureDevice") orelse {
        // AVFoundation is not in the process — see the module's build note.
        // No framework, no torch; the same "not available" answer Swift's
        // guard would give, reached one step earlier.
        std.log.warn("setFlashlight: AVCaptureDevice class not found; is AVFoundation linked?", .{});
        return BridgeError.NotFound;
    };

    // AVMediaTypeVideo is the FourCC string "vide". The literal, not the
    // extern constant — same trade as `bridge_continuity_camera.zig`: the
    // constant would put AVFoundation on every consumer's *link* line, and
    // the value is fixed by decades of QuickTime FourCC compatibility.
    const media_type = (try objc.createNSString("vide", allocator)) orelse
        return BridgeError.NativeCallFailed;

    const sel_default = objc.sel_registerName("defaultDeviceWithMediaType:") orelse return error.SelectorNotFound;
    const device = objc.msgSendId1(AVCaptureDevice, sel_default, media_type) orelse {
        // The simulator's answer, and a camera-less device's. Swift's guard
        // takes the same exit: reject, never pretend the torch moved.
        std.log.info("setFlashlight: no default video capture device (simulator, or no camera)", .{});
        return BridgeError.NotFound;
    };

    const sel_has_torch = objc.sel_registerName("hasTorch") orelse return error.SelectorNotFound;
    if (!objc.msgSendBool(device, sel_has_torch)) {
        std.log.info("setFlashlight: capture device has no torch", .{});
        return BridgeError.NotFound;
    }

    // All three selectors are registered *before* the lock is taken, so no
    // error path exists between `lockForConfiguration:` and
    // `unlockForConfiguration` — an early return in that window would leave
    // the device configuration locked for the rest of the process.
    const sel_lock = objc.sel_registerName("lockForConfiguration:") orelse return error.SelectorNotFound;
    const sel_set_mode = objc.sel_registerName("setTorchMode:") orelse return error.SelectorNotFound;
    const sel_unlock = objc.sel_registerName("unlockForConfiguration") orelse return error.SelectorNotFound;

    // `- (BOOL)lockForConfiguration:(NSError **)outError`, with the out-param
    // left null: the BOOL already separates locked from not, the NSError
    // would arrive autoreleased with nothing to do but be logged, and Swift's
    // `catch` keeps only its message too. The usual cause of a refusal is
    // another capture session holding the device.
    const LockFn = *const fn (Id, objc.SEL, ?*Id) callconv(.c) bool;
    const lock: LockFn = @ptrCast(&objc.objc_msgSend);
    if (!lock(device, sel_lock, null)) {
        std.log.warn("setFlashlight: lockForConfiguration: refused", .{});
        return BridgeError.NativeCallFailed;
    }

    objc.msgSendVoid1(device, sel_set_mode, torchModeFor(enabled));
    objc.msgSend(device, sel_unlock);
}

// =============================================================================
// Tests
//
// Host-only, and there is deliberately no live AVFoundation test. On a Mac
// with a Continuity Camera iPhone paired, `defaultDeviceWithMediaType:` can
// return a device whose `hasTorch` is YES — at which point a "test" would
// fire the torch on somebody's actual phone. Every honest outcome on a host
// is either environment-dependent (class linked or not, camera present or
// not) or a side effect on hardware craft does not own, and a test whose pass
// condition varies by desk is a flake, not a gate. The decisions that fit in
// a host test — routing, payload validation, the mode values, the reply
// shape — are pure functions above, and are pinned below.
// =============================================================================

const testing = std.testing;

test "the declared action is the one the handler serves" {
    try testing.expectEqual(@as(usize, 1), capability_actions.len);
    try testing.expectEqualStrings(A.set_flashlight, capability_actions[0].name);
    try testing.expectEqual(capabilities.Reply.result, capability_actions[0].reply);
    try testing.expectEqual(capabilities.ActionStatus.live, capability_actions[0].status);
}

test "the action name matches the Swift case label exactly" {
    // The conformance ratchet compares this string against the `case "…":`
    // labels in `CraftApp.swift`, in both directions; a prettier spelling
    // would register as Zig serving an action the spec does not have.
    try testing.expectEqualStrings("setFlashlight", A.set_flashlight);
}

test "every declared action dispatches to something" {
    // `{}` has no `enabled`, so validation fails *before* any AVFoundation
    // call — which is what makes this safe on a host with a real camera. What
    // it rules out is a name in the table `handleMessage` never compares
    // against.
    var bridge = MiscBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        try testing.expectError(
            BridgeError.MissingData,
            bridge.handleMessage(decl.name, "{}"),
        );
    }
}

test "the unserved actions stay unserved, which is what routes them to the shim" {
    var bridge = MiscBridge.init(testing.allocator);
    defer bridge.deinit();

    for (deliberately_unserved) |name| {
        // `UnknownAction` is the one return `ios_dispatch.route` turns into a
        // Swift-shim hand-off. Anything else — a result, `.unavailable`'s
        // refusal, any other error — would take the action away from the arm
        // that answers it correctly today.
        try testing.expectError(
            BridgeError.UnknownAction,
            bridge.handleMessage(name, "{}"),
        );

        // And none of them is declared: a capability row for an action the
        // shim serves would be this module claiming another component's work,
        // and a name in `A` would tell the conformance ratchet it migrated.
        for (capability_actions) |decl| {
            try testing.expect(!std.mem.eql(u8, decl.name, name));
        }
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = MiscBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // `craft.d.ts` declares `toggleFlashlight` and `test-bridges.html` calls
    // it, but no injected JS defines it and no dispatcher case answers it — a
    // pre-existing spec gap, not an action to invent here.
    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("toggleFlashlight", "{\"enabled\":true}"),
    );
    // Casing is how a real typo arrives.
    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("setflashlight", "{\"enabled\":true}"),
    );
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = MiscBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        BridgeError.InvalidJSON,
        bridge.handleMessage(A.set_flashlight, "{not json"),
    );
}

/// Parse a literal payload and check the extracted `enabled` — the slices in
/// a `std.json.Value` point into the `Parsed`, so it stays alive around the
/// check.
fn expectEnabled(json: []const u8, expected: bool) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(expected, try parseEnabled(parsed.value));
}

fn expectEnabledError(json: []const u8, expected: anyerror) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, parseEnabled(parsed.value));
}

test "the field name the page sends is the field that is read" {
    try expectEnabled("{\"enabled\":true}", true);
    try expectEnabled("{\"enabled\":false}", false);
}

test "a missing enabled is refused rather than defaulted" {
    // Defaulting to `false` would report "torch off" as the success of a
    // request that asked for nothing; Swift replies nothing at all and the
    // promise hangs. Both silent shapes are the ones this family removes.
    try expectEnabledError("{}", BridgeError.MissingData);
    // Field names are case-sensitive on the wire; a near-miss is absent.
    try expectEnabledError("{\"Enabled\":true}", BridgeError.MissingData);
}

test "a non-boolean enabled is refused, not coerced" {
    // The one deliberate divergence from Swift, documented at `parseEnabled`:
    // `as? Bool` lets the NSNumbers 0 and 1 through, so `{"enabled":1}` flips
    // the torch via the shim today. Coercion is refused everywhere in this
    // family, and the typed JS surface never produces it.
    try expectEnabledError("{\"enabled\":1}", BridgeError.InvalidParameter);
    try expectEnabledError("{\"enabled\":0}", BridgeError.InvalidParameter);
    try expectEnabledError("{\"enabled\":\"true\"}", BridgeError.InvalidParameter);
    try expectEnabledError("{\"enabled\":null}", BridgeError.InvalidParameter);
}

test "a payload that is not an object is bad JSON, not a missing field" {
    try expectEnabledError("[]", BridgeError.InvalidJSON);
    try expectEnabledError("true", BridgeError.InvalidJSON);
}

test "the torch modes are the header's values" {
    try testing.expectEqual(@as(c_long, 1), torchModeFor(true));
    try testing.expectEqual(@as(c_long, 0), torchModeFor(false));
}

test "the success reply is Swift's bare boolean, and it parses" {
    // `.fragmentsAllowed`: the page's promise resolves with `true` itself,
    // not an object wrapping it.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, success_reply, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .bool);
    try testing.expect(parsed.value.bool);
}

test "off Darwin the torch refuses rather than pretending" {
    // The platform gate, exercised where it actually gates. On Darwin this
    // same call would reach AVFoundation for real — see the test-section
    // comment for why that is not done.
    if (builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    var bridge = MiscBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.set_flashlight, "{\"enabled\":true}"),
    );
}
