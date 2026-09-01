//! The `mobile` namespace's odds and ends: the flashlight, a window
//! screenshot, and the deep-link handshake — plus the recorded reason
//! `getInitialURL` stays *unserved*, so `ios_dispatch.route` falls through to
//! the Swift shim that answers it correctly today. See `deliberately_unserved`.
//!
//! ## What changed, and what it unblocked
//!
//! Three of these four actions used to be unserved, and two of them for the
//! same reason: their Swift arms are conditional on `CraftConfig` flags
//! (`enableScreenCapture`, `enableDeepLinks`) that existed only as Swift
//! properties. Serving them regardless would have switched on capabilities the
//! app author turned off — fabricated authorization, the class of bug this
//! migration exists to remove.
//!
//! `ios_config.zig` is that missing channel. It reads the same bundled
//! `craft.config.json` Swift decodes, and `ios_dispatch.route` refuses a gated
//! action before this module runs, so neither handler below has to know a flag
//! exists. Both are now exactly what Swift does once its own guard passes.
//!
//! Each action's own shape:
//!
//!  - **`setFlashlight`** was always servable: no gate at all in the Swift
//!    dispatcher, and every step a synchronous AVFoundation call — no
//!    completion handler, no `ios_async` ticket — so the exchange happens
//!    inside the dispatch frame that holds the request id.
//!  - **`takeScreenshot`** renders the key window's layer into an image
//!    context and answers a `data:` URL. Also synchronous: Swift wraps its
//!    body in `DispatchQueue.main.async`, but `didReceiveScriptMessage`
//!    already runs on the main thread, so the hop would defer the same work to
//!    the next runloop turn and nothing else.
//!  - **`registerDeepLinkHandler`** acknowledges and does nothing else,
//!    because there is nothing native to register — Swift's whole arm is
//!    `resolveCallback(callbackId, result: true)`, and the real registration
//!    is the page's own `addEventListener('craftDeepLink', …)`. Worth stating
//!    plainly: this action is a handshake, and porting it faithfully means
//!    porting a handshake.
//!  - **`getInitialURL`** cannot be answered from Zig at all, and the config
//!    channel does not change that. The value lives in
//!    `DeepLinkManager.shared.initialURL` — a private property of a pure-Swift
//!    class that derives from nothing and declares no `@objc`, so
//!    `objc_getClass("DeepLinkManager")` cannot find it and neither `shared`
//!    nor `getInitialURL()` has an ObjC entry point. It is fed by SwiftUI's
//!    `.onOpenURL`, which Zig has no path to, and the launch URL is not
//!    re-derivable afterwards (not in the environment, not in NSUserDefaults).
//!
//! ## Why unserved rather than `.unavailable`
//!
//! `ios_dispatch.route` hands an action to `CraftSwiftShim` only when every
//! module answers `UnknownAction`. A declared-`.unavailable` action
//! *dispatches and refuses* — `bridge_mobile_display.lockOrientation` is the
//! precedent — so declaring `getInitialURL` would take it away from the arm
//! that answers it correctly today.
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
//!
//! `takeScreenshot` needs no such flag: UIKit is already linked there, and its
//! five drawing entry points are resolved by `dlsym` at call time rather than
//! declared `extern "c"`, so the host test binaries — which link Cocoa, not
//! UIKit — get an honest refusal instead of a link error.

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
    pub const take_screenshot = "takeScreenshot";
    pub const register_deep_link_handler = "registerDeepLinkHandler";
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
};

/// `.result`: every Swift path terminates in `resolveCallback(…, true)` or a
/// rejection, and the injected `setFlashlight` returns a promise the page can
/// await. `.live`: the no-torch outcome (simulator, torchless hardware, an
/// app that dropped AVFoundation) is a per-call rejection — a property of the
/// device the call found, not of the action.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.set_flashlight, .reply = .result },
    .{ .name = A.take_screenshot, .reply = .result },
    .{ .name = A.register_deep_link_handler, .reply = .result },
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
        } else if (std.mem.eql(u8, action, A.take_screenshot)) {
            try self.takeScreenshot();
        } else if (std.mem.eql(u8, action, A.register_deep_link_handler)) {
            try self.registerDeepLinkHandler();
        } else {
            // `getInitialURL` lands here on purpose: `UnknownAction` is what
            // routes an action onward to the Swift shim. See the module
            // comment.
            return BridgeError.UnknownAction;
        }
    }

    /// The key window's pixels, as a `data:` URL, exactly as Swift spells it.
    ///
    /// No `ios_async` ticket and no queue hop. Swift wraps its body in
    /// `DispatchQueue.main.async`, but `didReceiveScriptMessage` already runs
    /// on the main thread, so the hop would only defer the same work to the
    /// next runloop turn — and doing it inline keeps the whole exchange inside
    /// the dispatch frame that holds the request id, which is where a reply is
    /// cheapest to correlate.
    fn takeScreenshot(self: *Self) !void {
        const png = try captureKeyWindowPng(self.allocator);
        defer self.allocator.free(png);

        // Swift resolves with a Swift `String` under `.fragmentsAllowed`, so
        // the page receives a bare JSON string rather than an object. Base64
        // and the prefix contain nothing JSON escapes, but the shared escaper
        // runs anyway: a hand-argued "these bytes are safe" is how an escaping
        // bug gets introduced later by someone changing the prefix.
        const scratch = try self.allocator.alloc(u8, png.len * 2 + 2);
        defer self.allocator.free(scratch);
        const escaped = try bridge_error.escapeJsonString(scratch[1..], png);

        scratch[0] = '"';
        scratch[1 + escaped.len] = '"';
        bridge_error.sendResultToJS(self.allocator, A.take_screenshot, scratch[0 .. escaped.len + 2]);
    }

    /// Acknowledge that the page may listen for `craftDeepLink`.
    ///
    /// Swift's whole arm is `resolveCallback(callbackId, result: true)` behind
    /// the `enableDeepLinks` gate — the real registration is the page's own
    /// `addEventListener`, and there is nothing native to register. What made
    /// this unservable was that Zig could not see the gate, so its `true` would
    /// have claimed a registration in apps that had deep links switched off;
    /// `ios_config` now refuses the action before this runs, and the remaining
    /// behaviour is Swift's, unchanged.
    fn registerDeepLinkHandler(self: *Self) !void {
        bridge_error.sendResultToJS(self.allocator, A.register_deep_link_handler, success_reply);
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

/// The `data:` URL prefix Swift concatenates ahead of the base64.
///
/// Part of the wire contract, not decoration: `CraftApp.swift:4177` builds
/// `"data:image/png;base64," + imageData.base64EncodedString()`, and a page
/// that assigns the reply straight to `img.src` needs it.
const png_data_url_prefix = "data:image/png;base64,";

// UIKit's C drawing entry points. Chosen over `UIGraphicsImageRenderer`,
// which is what Swift uses, for one reason: `imageWithActions:` takes an
// Objective-C block, and a *global* block cannot capture the layer it has to
// render. Reaching the layer would mean stashing it in a module-level var
// across the call — real shared mutable state, on the main thread, to avoid a
// pair of C calls that do the same thing.
//
// The pixels are the same. `UIGraphicsImageRenderer`'s default format is
// opaque = false at the screen's scale, which is exactly
// `UIGraphicsBeginImageContextWithOptions(size, NO, 0.0)` — 0.0 meaning "the
// main screen's scale". These are deprecated as of iOS 17 and still present;
// the deprecation is a compiler diagnostic for ObjC callers, and nothing here
// compiles ObjC.
// Resolved with `dlsym` rather than declared `extern "c"`, the route
// `bridge_mobile_imagepicker.resolve` already takes for
// `UIImageJPEGRepresentation`: the host test binaries link Cocoa and not
// UIKit, and `refAllDecls` forces analysis of every declaration, so a direct
// `extern` would be five undefined symbols at host link time.
const BeginContextFn = *const fn (objc.CGSize, bool, objc.CGFloat) callconv(.c) void;
const GetContextFn = *const fn () callconv(.c) ?*anyopaque;
const GetImageFn = *const fn () callconv(.c) Id;
const EndContextFn = *const fn () callconv(.c) void;
const PngDataFn = *const fn (Id) callconv(.c) Id;

/// The five UIKit drawing entry points, resolved together.
///
/// Together rather than one at a time so a UIKit that carries some but not all
/// of them refuses before beginning an image context — the one call here with
/// a cleanup obligation. Resolving `UIImagePNGRepresentation` lazily after
/// `UIGraphicsBeginImageContextWithOptions` had already run would mean either
/// leaking the context or unwinding it from an error path that exists only for
/// this.
const Graphics = struct {
    begin: BeginContextFn,
    current: GetContextFn,
    image: GetImageFn,
    end: EndContextFn,
    png: PngDataFn,

    fn resolve() !Graphics {
        return .{
            .begin = @ptrCast(@alignCast(try symbol("UIGraphicsBeginImageContextWithOptions"))),
            .current = @ptrCast(@alignCast(try symbol("UIGraphicsGetCurrentContext"))),
            .image = @ptrCast(@alignCast(try symbol("UIGraphicsGetImageFromCurrentImageContext"))),
            .end = @ptrCast(@alignCast(try symbol("UIGraphicsEndImageContext"))),
            .png = @ptrCast(@alignCast(try symbol("UIImagePNGRepresentation"))),
        };
    }

    fn symbol(comptime name: [*:0]const u8) !*anyopaque {
        return dlsym(RTLD_DEFAULT, name) orelse {
            std.log.warn(
                "takeScreenshot refused: {s} is not in this process, so the window " ++
                    "could not be rendered",
                .{name},
            );
            return BridgeError.PlatformNotSupported;
        };
    }
};

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// `RTLD_DEFAULT` — search every image already loaded into the process.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// `data:image/png;base64,…` for the key window, or the reason there is none.
///
/// Follows Swift step for step, including which window: `connectedScenes`
/// is a `Set`, and Swift takes `.first` of it, which is an arbitrary element
/// rather than a defined one. `anyObject` is the same choice made explicit.
/// Apps with one scene — every app this template generates — cannot tell the
/// difference.
fn captureKeyWindowPng(allocator: std.mem.Allocator) ![]u8 {
    if (!builtin.target.os.tag.isDarwin()) return BridgeError.PlatformNotSupported;

    const gfx = try Graphics.resolve();
    const window = try keyWindow();

    const sel_bounds = objc.sel_registerName("bounds") orelse return BridgeError.NativeCallFailed;
    const BoundsFn = *const fn (Id, objc.SEL) callconv(.c) objc.CGRect;
    const boundsFn: BoundsFn = @ptrCast(&objc.objc_msgSend);
    const bounds = boundsFn(window, sel_bounds);

    // A zero-sized context yields a nil image rather than an empty PNG, and
    // the nil would surface as "Failed to capture screenshot" several steps
    // later. Refusing here names the actual condition.
    if (bounds.size.width <= 0 or bounds.size.height <= 0) {
        std.log.warn(
            "takeScreenshot: the key window is {d}x{d}; there is nothing to capture",
            .{ bounds.size.width, bounds.size.height },
        );
        return BridgeError.NativeCallFailed;
    }

    const sel_layer = objc.sel_registerName("layer") orelse return BridgeError.NativeCallFailed;
    const layer = objc.msgSendId(window, sel_layer) orelse return BridgeError.NativeCallFailed;

    // 0.0 scale means the main screen's, matching UIGraphicsImageRenderer's
    // default format; `false` for opaque keeps the alpha channel Swift's
    // renderer also keeps.
    gfx.begin(bounds.size, false, 0.0);
    // Paired with the Begin above on every path out of this block, including
    // the error returns: leaving a context on the stack corrupts the next
    // capture rather than this one, which is the hard kind of bug to trace
    // back.
    defer gfx.end();

    const context = gfx.current() orelse {
        std.log.warn("takeScreenshot: no image context after beginning one", .{});
        return BridgeError.NativeCallFailed;
    };

    const sel_render = objc.sel_registerName("renderInContext:") orelse
        return BridgeError.NativeCallFailed;
    objc.msgSendVoid1(layer, sel_render, context);

    const image = gfx.image() orelse {
        std.log.warn("takeScreenshot: the image context produced no image", .{});
        return BridgeError.NativeCallFailed;
    };

    const png = gfx.png(image) orelse {
        // Swift's own failure branch: `image.pngData()` returning nil.
        std.log.warn("takeScreenshot: the captured image has no PNG representation", .{});
        return BridgeError.NativeCallFailed;
    };

    const sel_base64 = objc.sel_registerName("base64EncodedStringWithOptions:") orelse
        return BridgeError.NativeCallFailed;
    const Base64Fn = *const fn (Id, objc.SEL, c_ulong) callconv(.c) Id;
    const base64Fn: Base64Fn = @ptrCast(&objc.objc_msgSend);
    const ns_base64 = base64Fn(png, sel_base64, 0) orelse return BridgeError.NativeCallFailed;

    const utf8 = objc.getNSStringUTF8(ns_base64) orelse return BridgeError.NativeCallFailed;
    const encoded = std.mem.span(utf8);

    return std.mem.concat(allocator, u8, &.{ png_data_url_prefix, encoded });
}

/// The window Swift's `connectedScenes.first`/`windows.first` pair reaches.
///
/// Every step can legitimately be nil — an app in the background has scenes
/// but no attached window, and a scene that is not a `UIWindowScene` has no
/// `windows` at all. Swift collapses the lot into one "No window available"
/// rejection; the log lines below keep them apart, because a missing scene and
/// a scene with no windows are different states of the app.
fn keyWindow() !Id {
    const UIApplication = objc.objc_getClass("UIApplication") orelse
        return BridgeError.NativeCallFailed;
    const sel_shared = objc.sel_registerName("sharedApplication") orelse
        return BridgeError.NativeCallFailed;
    const app = objc.msgSendId(UIApplication, sel_shared) orelse {
        std.log.warn("takeScreenshot: no UIApplication instance", .{});
        return BridgeError.NativeCallFailed;
    };

    const sel_scenes = objc.sel_registerName("connectedScenes") orelse
        return BridgeError.NativeCallFailed;
    const scenes = objc.msgSendId(app, sel_scenes) orelse {
        std.log.warn("takeScreenshot: the application has no connected scenes", .{});
        return BridgeError.NativeCallFailed;
    };

    const sel_any = objc.sel_registerName("anyObject") orelse return BridgeError.NativeCallFailed;
    const scene = objc.msgSendId(scenes, sel_any) orelse {
        std.log.warn("takeScreenshot: the connected-scene set is empty", .{});
        return BridgeError.NativeCallFailed;
    };

    // Swift's `as? UIWindowScene` is a conditional cast; sending `windows` to
    // a scene that is not one would be an unrecognised selector, and that is a
    // SIGABRT rather than an error this function could return.
    const UIWindowScene = objc.objc_getClass("UIWindowScene") orelse
        return BridgeError.NativeCallFailed;
    const sel_is_kind = objc.sel_registerName("isKindOfClass:") orelse
        return BridgeError.NativeCallFailed;
    const IsKindFn = *const fn (Id, objc.SEL, objc.Class) callconv(.c) bool;
    const isKind: IsKindFn = @ptrCast(&objc.objc_msgSend);
    if (!isKind(scene, sel_is_kind, UIWindowScene)) {
        std.log.warn("takeScreenshot: the connected scene is not a UIWindowScene", .{});
        return BridgeError.NativeCallFailed;
    }

    const sel_windows = objc.sel_registerName("windows") orelse return BridgeError.NativeCallFailed;
    const windows = objc.msgSendId(scene, sel_windows) orelse
        return BridgeError.NativeCallFailed;

    const sel_first = objc.sel_registerName("firstObject") orelse
        return BridgeError.NativeCallFailed;
    return objc.msgSendId(windows, sel_first) orelse {
        std.log.warn("takeScreenshot: the window scene has no windows", .{});
        return BridgeError.NativeCallFailed;
    };
}

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 3), capability_actions.len);
    try testing.expectEqualStrings(A.set_flashlight, capability_actions[0].name);
    try testing.expectEqualStrings(A.take_screenshot, capability_actions[1].name);
    try testing.expectEqualStrings(A.register_deep_link_handler, capability_actions[2].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "the action name matches the Swift case label exactly" {
    // The conformance ratchet compares this string against the `case "…":`
    // labels in `CraftApp.swift`, in both directions; a prettier spelling
    // would register as Zig serving an action the spec does not have.
    try testing.expectEqualStrings("setFlashlight", A.set_flashlight);
    try testing.expectEqualStrings("takeScreenshot", A.take_screenshot);
    try testing.expectEqualStrings("registerDeepLinkHandler", A.register_deep_link_handler);
}

test "every declared action dispatches to something" {
    // What this rules out is a name in the table `handleMessage` never
    // compares against — which would reach the shim as `UnknownAction` while
    // the capability manifest claimed Zig served it.
    //
    // `UnknownAction` is the only forbidden outcome, not any error.
    // `setFlashlight` fails validation on `{}` before touching AVFoundation,
    // and `takeScreenshot` refuses on a host whose UIKit symbols `dlsym`
    // cannot find; both are the handler running, which is what is being
    // asserted.
    var bridge = MiscBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            continue;
        };
    }
}

test "the screenshot reply is a bare JSON string carrying a data URL" {
    // Swift resolves with a `String` under `.fragmentsAllowed`, so the page
    // gets `"data:image/png;base64,…"` and not `{"image":…}`. A page that
    // assigns the reply to `img.src` depends on both the quoting and the
    // prefix.
    try testing.expectEqualStrings("data:image/png;base64,", png_data_url_prefix);
}

test "a screenshot on a host without UIKit refuses rather than inventing one" {
    // The five drawing entry points are UIKit's, and the host test binaries
    // link Cocoa. `dlsym` finding nothing has to be a refusal — a module that
    // answered with an empty or placeholder PNG here would be fabricating the
    // one thing this action exists to return.
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    try testing.expectError(
        BridgeError.PlatformNotSupported,
        captureKeyWindowPng(testing.allocator),
    );
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
