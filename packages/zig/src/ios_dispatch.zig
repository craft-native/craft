const std = @import("std");
const builtin = @import("builtin");
const objc_runtime = @import("objc_runtime.zig");
const request_context = @import("request_context.zig");
const bridge_error = @import("bridge_error.zig");
const capabilities = @import("capabilities.zig");
pub const ios_async = @import("ios_async.zig");
pub const ios_events = @import("ios_events.zig");
pub const ios_delegate = @import("ios_delegate.zig");
pub const ios_config = @import("ios_config.zig");
const bridge_mobile = @import("bridge_mobile.zig");
const bridge_mobile_clipboard = @import("bridge_mobile_clipboard.zig");
const bridge_mobile_haptics = @import("bridge_mobile_haptics.zig");
const bridge_mobile_device = @import("bridge_mobile_device.zig");
const bridge_mobile_system = @import("bridge_mobile_system.zig");
const bridge_mobile_display = @import("bridge_mobile_display.zig");
const bridge_mobile_storage = @import("bridge_mobile_storage.zig");
const bridge_mobile_misc = @import("bridge_mobile_misc.zig");
const bridge_mobile_shortcuts = @import("bridge_mobile_shortcuts.zig");
const bridge_mobile_securestore = @import("bridge_mobile_securestore.zig");
const bridge_mobile_biometric = @import("bridge_mobile_biometric.zig");
const bridge_mobile_permissions = @import("bridge_mobile_permissions.zig");
const bridge_mobile_db = @import("bridge_mobile_db.zig");
const bridge_mobile_notifcancel = @import("bridge_mobile_notifcancel.zig");
const bridge_mobile_notifications = @import("bridge_mobile_notifications.zig");
const bridge_mobile_bgtasks = @import("bridge_mobile_bgtasks.zig");
const bridge_mobile_watch = @import("bridge_mobile_watch.zig");
const bridge_mobile_location = @import("bridge_mobile_location.zig");
const bridge_mobile_locrecording = @import("bridge_mobile_locrecording.zig");
const bridge_mobile_motion = @import("bridge_mobile_motion.zig");
const bridge_mobile_imagepicker = @import("bridge_mobile_imagepicker.zig");
const bridge_mobile_filepicker = @import("bridge_mobile_filepicker.zig");
const bridge_mobile_contactpicker = @import("bridge_mobile_contactpicker.zig");
const bridge_mobile_calendar = @import("bridge_mobile_calendar.zig");
const bridge_mobile_contacts = @import("bridge_mobile_contacts.zig");
const bridge_mobile_vision = @import("bridge_mobile_vision.zig");
const bridge_mobile_auth = @import("bridge_mobile_auth.zig");
const bridge_mobile_siri = @import("bridge_mobile_siri.zig");
const bridge_mobile_pdf = @import("bridge_mobile_pdf.zig");
const bridge_mobile_bluetooth = @import("bridge_mobile_bluetooth.zig");
const bridge_mobile_audiorec = @import("bridge_mobile_audiorec.zig");
const bridge_mobile_health = @import("bridge_mobile_health.zig");
const bridge_mobile_speech = @import("bridge_mobile_speech.zig");
const bridge_mobile_nfc = @import("bridge_mobile_nfc.zig");
const bridge_mobile_auth_apple = @import("bridge_mobile_auth_apple.zig");

const objc = objc_runtime.objc;

/// The iOS end of the bridge: what a page's `postMessage` reaches, and how a
/// reply gets back to it.
///
/// The envelope is the desktop one — `{t, a, d, i}` — and the reply goes out
/// through `bridge_error.sendResultToJS`, which is the same function every
/// `bridge_*.zig` module already calls. That is the whole reason for choosing
/// this envelope over the one the Swift template speaks: reply correlation is
/// the hardest part of a bridge, and `craft-bridge.js` plus `request_context`
/// plus `formatResultJS` already implement it, with per-call ids, a timeout,
/// and a guard so a late reply cannot settle someone else's call.
///
/// Before this, `ios.zig` had a bridge that parsed JSON by substring search
/// and a `handleMessage` with no caller anywhere in the tree — because nothing
/// ever registered a `WKScriptMessageHandler`. A page's
/// `webkit.messageHandlers.craft` was undefined, so every call took the
/// fallback branch and resolved `{success:true, browser:true}`. "The bridge
/// worked" and "there is no bridge" were the same value.
/// The webview a reply is evaluated against.
///
/// One slot, because iOS has one webview. When multi-window arrives this
/// becomes a lookup keyed by the same request id the reply already carries —
/// the id is threaded through `request_context` for exactly that reason.
/// `objc.id`, not `?objc.id`. The extra optional was a real defect, not
/// redundancy: `objc.id` is already `?*anyopaque`, so a double optional made
/// `setWebView(null)` store a *present* outer value wrapping a nil webview,
/// and `global_webview orelse return error.NoWebView` below then unwrapped
/// only the outer one and sailed past. Every reply after such a call went to
/// `objc_msgSend(nil, …)`, which is a silent no-op — the action ran, it
/// worked, and the page heard nothing, with no error anywhere to say so.
///
/// One optional means "no webview" has one spelling and `orelse` catches it.
/// (`macos.zig:4075` still holds the two-level version. It is unreachable
/// there today because nothing passes nil, but it is the same shape.)
var global_webview: objc.id = null;

pub fn setWebView(webview: objc.id) void {
    global_webview = webview;
}

pub fn getWebView() objc.id {
    return global_webview;
}

/// Evaluate JavaScript in the page. `bridge.evalJS`'s `.ios` arm.
///
/// The completion handler is nil, which is legal and is what a reply wants:
/// nothing awaits the result of delivering a result. The block machinery that
/// a *callback-taking* evaluation needs is a separate problem, and the version
/// that used to sit in `mobile.zig` got it wrong in four ways at once — see
/// the note there.
pub fn evalJS(script: []const u8) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const webview = global_webview orelse return error.NoWebView;

    // `createNSString` allocates rather than copying into a fixed buffer, which
    // matters: a reply's size is set by whatever the handler returns, and a
    // stack ceiling here would truncate JavaScript into a syntax error in the
    // page with nothing to point at.
    const ns_script = try objc.createNSString(script, std.heap.c_allocator);

    const sel_eval = objc.sel_registerName("evaluateJavaScript:completionHandler:") orelse return error.SelectorNotFound;
    const Fn = *const fn (objc.id, objc.SEL, objc.id, ?*anyopaque) callconv(.c) void;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    func(webview, sel_eval, ns_script, null);
}

/// Route one `{t, a, d, i}` message.
///
/// Mirrors `macos.zig:handleBridgeMessageJSON`, including the detail that cost
/// the desktop a bug: the payload `d` is handed to the namespace, not dropped.
pub fn handleMessage(allocator: std.mem.Allocator, json_str: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidBridgeMessage;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidBridgeMessage,
    };

    const msg_type = switch (root.get("t") orelse return error.MissingType) {
        .string => |value| value,
        else => return error.InvalidBridgeMessage,
    };
    const action = switch (root.get("a") orelse return error.MissingAction) {
        .string => |value| value,
        else => return error.InvalidBridgeMessage,
    };

    // Which call this is, so the reply can name it rather than leaving the page
    // to guess by action name. Pushed unconditionally: a message with no `i`
    // pushes null and so shadows any enclosing request instead of inheriting an
    // id that is not its own. Deferred pop because dispatch can fail anywhere.
    request_context.push(request_context.fromEnvelope(root));
    defer request_context.pop();

    // One line per dispatch, naming the call. On a device this is the only
    // window into the bridge — there is no console to watch — and it is what
    // lets a harness observe that a message arrived at all, separately from
    // whether it was answered correctly.
    std.log.info("craft-bridge dispatch t={s} a={s} i={?d}", .{
        msg_type,
        action,
        request_context.current(),
    });

    const data = try payloadOf(root);

    try route(allocator, msg_type, action, data);
}

/// The payload `d`, as a JSON string the namespace can parse.
///
/// `craft-bridge.js` sends `d` already stringified — `_post` builds
/// `{t, a, d: d || ''}` — and omits it for the many actions that need none. So
/// the string and absent cases are the real ones, and both are handled here.
///
/// An absent `d` becomes `{}` rather than `""`. An empty string would clear a
/// handler's `orelse MissingData` guard and then fail JSON parsing instead,
/// which reports the wrong cause — the same trap `macos.zig` documents at its
/// own payload extraction.
///
/// A structured `d` (object or array) is rejected rather than quietly dropped.
/// The desktop re-renders it with a `jsonValueToString` that is private to
/// `macos.zig`; sharing that is part of extracting the common dispatcher, and
/// until then an explicit error is the honest answer. Silently substituting
/// `{}` here would hand the handler an empty payload and let it act on
/// defaults, which is how `craft.fs.writeFile` came to write empty files.
fn payloadOf(root: std.json.ObjectMap) ![]const u8 {
    const data_val = root.get("d") orelse return "{}";
    return switch (data_val) {
        .string => |s| if (s.len == 0) "{}" else s,
        .object, .array => error.StructuredPayloadNotSupported,
        .null => "{}",
        else => error.InvalidPayload,
    };
}

/// Namespace routing, with a hand-off for what Zig does not serve yet.
///
/// This is the piece that makes the migration incremental rather than a
/// cutover. An action Zig has not taken over is passed to the host shim, which
/// answers it exactly as it does today; each later phase moves actions from the
/// shim arm to the Zig arm and the page sees no difference. Without it, every
/// phase before the last would ship an app missing most of its API.
///
/// Whatever happens, the page gets an answer. Silence is the one outcome ruled
/// out: a reply that never arrives is indistinguishable from a slow one until
/// the page's timeout fires, and thirty seconds of nothing is the worst
/// diagnostic a bridge can give.
fn route(allocator: std.mem.Allocator, msg_type: []const u8, action: []const u8, data: []const u8) !void {
    if (!std.mem.eql(u8, msg_type, "mobile")) {
        bridge_error.sendErrorToJS(allocator, action, bridge_error.BridgeError.UnknownAction);
        return error.UnknownNamespace;
    }

    switch (try offerToModules(allocator, action, data)) {
        .answered => return,
        .not_ours => {},
    }

    if (try handOffToHost(action, data)) return;

    bridge_error.sendErrorToJS(allocator, action, bridge_error.BridgeError.UnknownAction);
    return error.UnknownAction;
}

/// Whether the Zig modules took responsibility for an action.
///
/// The distinction the hand-off is built on, and the one a Swift-hosted app
/// needs too: `answered` means the page will hear back from Zig and nobody
/// else may reply, `not_ours` means nothing here recognised the action and
/// whoever asked must serve it themselves.
///
/// A refusal is `answered`. Every path that calls `sendErrorToJS` has settled
/// the page's promise, so treating "refused" as "not mine" would let a second
/// arm answer the same call — the double-reply this envelope exists to
/// prevent.
const Offer = enum { answered, not_ours };

/// The capability gate, then the module chain. Shared by the two entry points
/// so they cannot drift: `route` for a message Zig received itself, and
/// `craft_ios_handle_action` for one a Swift host received and passed over.
fn offerToModules(allocator: std.mem.Allocator, action: []const u8, data: []const u8) !Offer {
    // The app's own configuration, before anything else. An action the spec
    // gates on a `config.enable*` flag is refused here when that flag is off,
    // rather than served — which is what every one of these did until
    // `ios_config.zig` existed, because Zig had no way to read the flag.
    //
    // Only actions this file's modules serve are gated. `gateFor` returns null
    // for the rest, so an action still on the shim keeps whatever answer the
    // shim gives it: Zig refusing on Swift's behalf would mean deciding, from
    // Zig's parse of the config, a question the arm that owns the action is
    // about to decide from its own.
    if (ios_config.gateFor(action)) |feature| {
        if (!ios_config.isEnabled(feature)) {
            std.log.info(
                "ios: refusing {s}; {s} is not enabled in craft.config.json",
                .{ action, feature.jsonKey() },
            );
            bridge_error.sendErrorToJS(allocator, action, bridge_error.BridgeError.CapabilityDisabled);
            return bridge_error.BridgeError.CapabilityDisabled;
        }
    }

    // First module that recognises the action wins. UnknownAction means
    // "not mine, ask the next"; any other error means a handler ran and
    // failed, and its answer is final — retrying the same action against
    // another module (or the shim) would replace a specific failure with
    // whatever the next thing happens to say.
    //
    // `test/ios_conformance_test.zig` fails the build if one action is
    // declared by two modules, so first-match is deterministic rather than
    // dependent on the order of this tuple. That check was claimed here
    // before it existed; it exists now.
    inline for (mobile_bridges) |Bridge| {
        var bridge = Bridge.init(allocator);
        defer bridge.deinit();

        if (bridge.handleMessage(action, data)) |_| {
            return .answered;
        } else |err| switch (err) {
            bridge_error.BridgeError.UnknownAction => {},
            else => {
                bridge_error.sendErrorToJS(allocator, action, asBridgeError(err));
                return err;
            },
        }
    }

    return .not_ours;
}

/// Every Zig module serving the `mobile` namespace, in dispatch order.
///
/// Growing this list is what a migration phase does. The conformance test in
/// `test/ios_conformance_test.zig` embeds the same files and holds the ratchet,
/// so adding a module here without listing it there — or vice versa — fails
/// the build rather than silently narrowing the served surface.
const mobile_bridges = .{
    bridge_mobile.MobileBridge,
    bridge_mobile_clipboard.ClipboardBridge,
    bridge_mobile_haptics.HapticsBridge,
    bridge_mobile_device.DeviceBridge,
    bridge_mobile_system.SystemBridge,
    bridge_mobile_display.DisplayBridge,
    bridge_mobile_storage.StorageBridge,
    bridge_mobile_misc.MiscBridge,
    bridge_mobile_shortcuts.ShortcutsBridge,
    bridge_mobile_securestore.SecureStoreBridge,
    bridge_mobile_biometric.BiometricStoreBridge,
    bridge_mobile_permissions.PermissionsBridge,
    bridge_mobile_db.DbBridge,
    bridge_mobile_notifcancel.NotifCancelBridge,
    bridge_mobile_notifications.NotificationsBridge,
    bridge_mobile_bgtasks.BgTasksBridge,
    bridge_mobile_watch.WatchBridge,
    bridge_mobile_location.LocationBridge,
    bridge_mobile_locrecording.LocationRecordingBridge,
    bridge_mobile_motion.MotionBridge,
    bridge_mobile_imagepicker.ImagePickerBridge,
    bridge_mobile_filepicker.FilePickerBridge,
    bridge_mobile_contactpicker.ContactPickerBridge,
    bridge_mobile_calendar.CalendarBridge,
    bridge_mobile_contacts.ContactsBridge,
    bridge_mobile_vision.VisionBridge,
    bridge_mobile_auth.AuthBridge,
    bridge_mobile_siri.SiriBridge,
    bridge_mobile_pdf.PdfBridge,
    bridge_mobile_bluetooth.BluetoothBridge,
    bridge_mobile_audiorec.AudioRecordingBridge,
    bridge_mobile_health.HealthBridge,
    bridge_mobile_speech.SpeechBridge,
    bridge_mobile_nfc.NfcBridge,
    bridge_mobile_auth_apple.AppleAuthBridge,
};

/// The same modules again, as their capability manifests.
///
/// A second spelling of `mobile_bridges` is not something to want, but the two
/// cannot be one: `mobile_bridges` holds bridge *types* and `capability_actions`
/// is declared at module scope, so there is no way to reach a module's manifest
/// from its struct. The comptime length check below is what keeps them in step
/// — a module added to one list and not the other fails the build.
const mobile_manifests = [_][]const capabilities.ActionDecl{
    &bridge_mobile.capability_actions,
    &bridge_mobile_clipboard.capability_actions,
    &bridge_mobile_haptics.capability_actions,
    &bridge_mobile_device.capability_actions,
    &bridge_mobile_system.capability_actions,
    &bridge_mobile_display.capability_actions,
    &bridge_mobile_storage.capability_actions,
    &bridge_mobile_misc.capability_actions,
    &bridge_mobile_shortcuts.capability_actions,
    &bridge_mobile_securestore.capability_actions,
    &bridge_mobile_biometric.capability_actions,
    &bridge_mobile_permissions.capability_actions,
    &bridge_mobile_db.capability_actions,
    &bridge_mobile_notifcancel.capability_actions,
    &bridge_mobile_notifications.capability_actions,
    &bridge_mobile_bgtasks.capability_actions,
    &bridge_mobile_watch.capability_actions,
    &bridge_mobile_location.capability_actions,
    &bridge_mobile_locrecording.capability_actions,
    &bridge_mobile_motion.capability_actions,
    &bridge_mobile_imagepicker.capability_actions,
    &bridge_mobile_filepicker.capability_actions,
    &bridge_mobile_contactpicker.capability_actions,
    &bridge_mobile_calendar.capability_actions,
    &bridge_mobile_contacts.capability_actions,
    &bridge_mobile_vision.capability_actions,
    &bridge_mobile_auth.capability_actions,
    &bridge_mobile_siri.capability_actions,
    &bridge_mobile_pdf.capability_actions,
    &bridge_mobile_bluetooth.capability_actions,
    &bridge_mobile_audiorec.capability_actions,
    &bridge_mobile_health.capability_actions,
    &bridge_mobile_speech.capability_actions,
    &bridge_mobile_nfc.capability_actions,
    &bridge_mobile_auth_apple.capability_actions,
};

comptime {
    if (mobile_manifests.len != mobile_bridges.len) {
        @compileError("mobile_manifests and mobile_bridges must list the same modules");
    }
}

/// Whether a host that offered this action has to serve it itself.
///
/// `.status = .unavailable` in a module's manifest means the handler is
/// reachable and refuses, deliberately, because Zig cannot do the thing
/// correctly — `haptic` cannot see `config.enableHaptics`, and the rest say
/// why in their own `reason`.
///
/// In the Zig-hosted app that refusal is the honest end of the line: `route`
/// tries `handOffToHost` next, and the shim is what actually serves it. The
/// host-offered path has no such fallback — `craft_ios_handle_action`
/// deliberately does not consult `handOffToHost`, because there the host *is*
/// the caller. So claiming one of these would not be a refusal instead of an
/// answer, it would be a refusal instead of the *host's working answer*: an app
/// that has haptics today would stop buzzing the moment the runtime was linked,
/// and the page would get a rejection where it used to get silence-and-a-buzz.
///
/// `test/ios_conformance_test.zig` already treats falling through as better
/// than `.unavailable`. This is that rule, applied to the one path that had no
/// way to fall through.
fn hostServesItself(action: []const u8) bool {
    for (mobile_manifests) |manifest| {
        for (manifest) |decl| {
            if (decl.status == .unavailable and std.mem.eql(u8, decl.name, action)) return true;
        }
    }
    return false;
}

/// Narrow an arbitrary handler error to one the page's error codes can express.
///
/// A handler's error set is wider than `BridgeError` — it picks up allocation
/// failures and whatever else its implementation can raise. Those still have to
/// reach the page as *something*: the alternative is a handler that fails and
/// says nothing, which leaves the caller waiting on a promise that will not
/// settle. `NativeCallFailed` is the honest catch-all for "it broke in a way
/// the protocol has no word for".
fn asBridgeError(err: anyerror) bridge_error.BridgeError {
    return switch (err) {
        error.AllocationFailed, error.OutOfMemory => bridge_error.BridgeError.AllocationFailed,
        error.InvalidJSON => bridge_error.BridgeError.InvalidJSON,
        error.InvalidParameter => bridge_error.BridgeError.InvalidParameter,
        error.MissingData => bridge_error.BridgeError.MissingData,
        error.NotFound => bridge_error.BridgeError.NotFound,
        error.PermissionDenied => bridge_error.BridgeError.PermissionDenied,
        error.PlatformNotSupported, error.UnsupportedPlatform => bridge_error.BridgeError.PlatformNotSupported,
        error.Timeout => bridge_error.BridgeError.Timeout,
        error.UnknownAction => bridge_error.BridgeError.UnknownAction,
        else => bridge_error.BridgeError.NativeCallFailed,
    };
}

/// Hand an action to the host shim. Returns false when there is no shim.
///
/// Found by name at runtime rather than linked, so a Zig-only app — the
/// fixture, or any app that has migrated everything — carries no dependency on
/// the shim existing. `objc_getClass` returning null is the normal answer
/// there, not an error.
///
/// The shim does not reply. It produces a payload and hands it back through
/// `craft_ios_deliver_result`, so the wire format, the request id, and the
/// escaping all stay in one place. Two components replying to the same page by
/// two different routes is how this codebase ended up with five envelopes.
fn handOffToHost(action: []const u8, data: []const u8) !bool {
    if (!builtin.target.os.tag.isDarwin()) return false;

    const shim = objc.objc_getClass("CraftSwiftShim") orelse return false;

    const sel = objc.sel_registerName("handleAction:payload:requestId:") orelse
        return error.SelectorNotFound;

    const allocator = std.heap.c_allocator;
    const ns_action = try objc.createNSString(action, allocator);
    const ns_payload = try objc.createNSString(data, allocator);

    // The id the reply must carry. Read here, while the dispatch frame is still
    // on the stack, because the shim may answer asynchronously and
    // `request_context.current()` will be empty by then.
    const request_id: i64 = if (request_context.current()) |id| @intCast(id) else -1;

    const Fn = *const fn (objc.id, objc.SEL, objc.id, objc.id, i64) callconv(.c) bool;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(shim, sel, ns_action, ns_payload, request_id);
}

/// Hand the Zig runtime the webview its replies are evaluated against.
///
/// The one thing a Swift-hosted app must do before any message is offered
/// below. In the Zig-hosted app `ios.zig` sets this itself while building the
/// webview; when SwiftUI owns the `WKWebView`, Zig never sees it and every
/// reply would reach `error.NoWebView` — an action that ran, worked, and told
/// nobody.
///
/// Not retained. The caller owns the webview and outlives the runtime: it is
/// the app's own root view. Retaining it here would create a cycle with
/// nothing to break it, since this pointer is never cleared except by a second
/// call.
export fn craft_ios_set_webview(webview: ?*anyopaque) callconv(.c) void {
    setWebView(webview);
}

/// Take over a location recording that outlived the last launch.
///
/// The one thing Zig has to do at launch rather than on a page message, and the
/// reason it needs an export of its own: SwiftUI builds the coordinator before
/// it builds the view, so `CraftWebView.Coordinator.init` runs — and
/// `restoreLocationRecordingState()` with it — before `craft_ios_set_webview`
/// has been called even once. Whichever runtime restores first owns the
/// `CLLocationManager` for the rest of the launch.
///
/// Swift calls this *instead of* its own restore, inside the same
/// `config.enableGeolocation` guard, and falls back to
/// `restoreLocationRecordingState()` only when `dlsym` does not find this
/// symbol — which is exactly the app that has no Zig recorder to take over.
///
/// Returns true when Zig has taken responsibility, so the caller must not also
/// restore. That is not the same as "a recording was found": an app with no
/// recording in progress still has a Zig-owned recorder for the next `start`,
/// and a Swift restore under it would be a second owner of one file.
export fn craft_ios_adopt_location_recording() callconv(.c) bool {
    return bridge_mobile_location.adoptRecording();
}

/// Forget the webview, if it is still the one the caller installed.
///
/// The other half of `craft_ios_set_webview`, and the reason it is needed:
/// Zig holds the webview unretained, so once SwiftUI tears the view down the
/// pointer is dangling and every later reply is an `objc_msgSend` into freed
/// memory. `UIViewRepresentable` has a `dismantleUIView` hook for exactly this
/// moment, and this is what it calls.
///
/// Compare-and-clear, not an unconditional reset. SwiftUI is free to build the
/// replacement view *before* dismantling the old one — during a state-driven
/// rebuild it usually does — and a blind clear on dismantle would blank the
/// pointer the new view had already installed, leaving a live app whose
/// replies all reach `error.NoWebView`. Clearing only when the pointer still
/// matches makes the two orders equivalent.
export fn craft_ios_clear_webview(webview: ?*anyopaque) callconv(.c) void {
    if (global_webview == webview) global_webview = null;
}

/// Offer one already-parsed page message to the Zig dispatcher.
///
/// The entry point for a **Swift-hosted** app, where `WKScriptMessageHandler`
/// belongs to SwiftUI and Zig is a library rather than the thing that owns
/// `UIApplicationMain`. The caller has already parsed the page's message, so
/// this takes the three fields routing needs directly instead of re-parsing an
/// envelope Zig never saw.
///
/// Returns **true when Zig has taken responsibility** — the page will hear
/// back from Zig and the caller must not answer. Returns **false only when no
/// Zig module recognised the action**, which is the caller's signal to serve
/// it themselves.
///
/// A refusal returns true. `offerToModules` calls `sendErrorToJS` before it
/// reports a failure, so the promise is already settled; answering again from
/// the Swift side would resolve a callback that has been deleted at best, and
/// deliver two contradictory answers to one call at worst.
///
/// `handOffToHost` is deliberately **not** consulted here. In this direction
/// the host is the caller, so handing back to `CraftSwiftShim` would take a
/// round trip through the Objective-C runtime to reach the same `dispatch`
/// method the caller is about to call anyway — and would do it under a
/// synthetic `zig:` callback id, routing the reply back through Zig for no
/// reason. `false` says the same thing in one word.
///
/// `request_id` is negative for a page message with no callback waiting on it,
/// matching the null the `{t,a,d,i}` envelope carries in that case.
export fn craft_ios_handle_action(
    action_ptr: [*]const u8,
    action_len: usize,
    payload_ptr: [*]const u8,
    payload_len: usize,
    request_id: i64,
) callconv(.c) bool {
    const action = action_ptr[0..action_len];
    const payload = payload_ptr[0..payload_len];

    // Pushed for the whole call, exactly as `handleMessage` does: a reply
    // formatted after this frame is gone reads `request_context.current()` and
    // would stamp null, falling back to action-name correlation and handing
    // one caller's answer to another.
    request_context.push(if (request_id < 0) null else @intCast(request_id));
    defer request_context.pop();

    // The same line `handleMessage` logs, and for the same reason: on a device
    // this is the only window into the bridge. `t=mobile` is spelled out
    // rather than taken from an envelope, because a host-offered message has
    // no envelope — this path is only ever the mobile namespace.
    std.log.info("craft-bridge dispatch t=mobile a={s} i={?d}", .{
        action,
        request_context.current(),
    });

    // Before the gate and the module chain, because this is not a question
    // about what the config allows or what a handler would do — it is a
    // question about which arm owns the action at all, and the answer is the
    // caller's own.
    if (hostServesItself(action)) {
        std.log.info("ios: {s} is declared unavailable; leaving it to the host", .{action});
        return false;
    }

    const offer = offerToModules(std.heap.c_allocator, action, payload) catch {
        // A module ran and failed, and answered the page on its way out. That
        // is a served action with an unhappy result, not an unserved one.
        return true;
    };
    return offer == .answered;
}

/// Deliver a result the host shim produced.
///
/// Exported for the shim to call. Everything after this point is the same path
/// a Zig-served action takes — same formatting, same escaping, same evalJS —
/// which is the point: the shim decides *what* the answer is, never *how* it
/// gets there.
///
/// `request_id` is negative for a message the page sent without one, matching
/// the null the envelope carries in that case.
export fn craft_ios_deliver_result(
    action_ptr: [*]const u8,
    action_len: usize,
    json_ptr: [*]const u8,
    json_len: usize,
    request_id: i64,
) callconv(.c) void {
    const action = action_ptr[0..action_len];
    const json = json_ptr[0..json_len];

    // Restore the id the shim was handed, so the reply names the call that is
    // actually waiting on it rather than falling back to action-name matching.
    request_context.push(if (request_id < 0) null else @intCast(request_id));
    defer request_context.pop();

    bridge_error.sendResultToJS(std.heap.c_allocator, action, json);
}

/// Deliver an error the host shim produced.
///
/// A separate export from `craft_ios_deliver_result` because results and
/// errors reach the page by different routes — `__craftBridgeResult` resolves
/// the pending promise, `__craftBridgeError` rejects it. Delivering a shim
/// rejection as a result would make the caller's promise *resolve* with an
/// error-shaped object, which is the fabricated-success bug wearing a
/// different hat: the catch block the app wrote never runs.
///
/// The message and code are free text from the shim, escaped here with the
/// same `appendJsonEscaped` every native error already goes through — the
/// Swift side must not hand-escape (its own attempt replaced only `'` and
/// let backslashes break out of the string literal).
export fn craft_ios_deliver_error(
    action_ptr: [*]const u8,
    action_len: usize,
    message_ptr: [*]const u8,
    message_len: usize,
    code_ptr: [*]const u8,
    code_len: usize,
    request_id: i64,
) callconv(.c) void {
    const allocator = std.heap.c_allocator;
    const action = action_ptr[0..action_len];
    const message = message_ptr[0..message_len];
    const code = code_ptr[0..code_len];

    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(allocator);

    buildShimError(allocator, &json, action, message, code, request_id) catch return;

    const js = std.fmt.allocPrint(
        allocator,
        "if(window.__craftBridgeError)window.__craftBridgeError({s});",
        .{json.items},
    ) catch return;
    defer allocator.free(js);

    evalJS(js) catch |err| {
        std.log.warn("ios bridge: could not deliver shim error for '{s}': {}", .{ action, err });
    };
}

/// The `__craftBridgeError` payload for a shim-raised error. Split out so the
/// host tests can pin the exact shape without a webview.
fn buildShimError(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    action: []const u8,
    message: []const u8,
    code: []const u8,
    request_id: i64,
) !void {
    try out.appendSlice(allocator, "{\"error\":true,\"code\":\"");
    try bridge_error.appendJsonEscaped(allocator, out, code);
    try out.appendSlice(allocator, "\",\"action\":\"");
    try bridge_error.appendJsonEscaped(allocator, out, action);
    try out.appendSlice(allocator, "\",\"message\":\"");
    try bridge_error.appendJsonEscaped(allocator, out, message);
    try out.append(allocator, '"');
    if (request_id >= 0) {
        try out.appendSlice(allocator, ",\"id\":");
        try out.print(allocator, "{d}", .{request_id});
    }
    try out.append(allocator, '}');
}

test {
    _ = ios_async;
    _ = ios_events;
    _ = ios_delegate;
}

const testing = std.testing;

test "an envelope without a type is rejected" {
    try testing.expectError(
        error.MissingType,
        handleMessage(testing.allocator, "{\"a\":\"getDeviceInfo\"}"),
    );
}

test "an envelope without an action is rejected" {
    try testing.expectError(
        error.MissingAction,
        handleMessage(testing.allocator, "{\"t\":\"mobile\"}"),
    );
}

test "malformed JSON is rejected rather than parsed by guesswork" {
    // The bridge this replaces searched for `"method":"` as a substring, which
    // would happily "parse" this and act on whatever followed.
    try testing.expectError(
        error.InvalidBridgeMessage,
        handleMessage(testing.allocator, "{\"t\":\"mobile\", \"a\":"),
    );
}

test "an absent payload becomes an empty object, not an empty string" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"t\":\"mobile\",\"a\":\"x\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("{}", try payloadOf(parsed.value.object));
}

test "a string payload is passed through unchanged" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"t\":\"mobile\",\"a\":\"x\",\"d\":\"{\\\"k\\\":1}\"}",
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("{\"k\":1}", try payloadOf(parsed.value.object));
}

test "a structured payload is refused, not silently emptied" {
    // Substituting `{}` here would hand the handler an empty payload and let it
    // proceed on defaults. That is precisely the shape of the bug where
    // `craft.fs.writeFile` wrote empty files: a field the page sent, dropped on
    // the way in, with success reported anyway.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"t\":\"mobile\",\"a\":\"x\",\"d\":{\"k\":1}}",
        .{},
    );
    defer parsed.deinit();
    try testing.expectError(error.StructuredPayloadNotSupported, payloadOf(parsed.value.object));
}

test "evalJS without a webview reports it rather than crashing" {
    const saved = global_webview;
    defer global_webview = saved;
    global_webview = null;

    try testing.expectError(error.NoWebView, evalJS("void 0"));
}

test "with no host shim present, the hand-off declines rather than failing" {
    // The host build has no `CraftSwiftShim` class, which is the same situation
    // a fully-migrated app is in. Declining has to be the normal answer, not an
    // error: an app that has taken every action into Zig should carry no
    // dependency on a shim existing.
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    try testing.expect(!try handOffToHost("anything", "{}"));
}

test "a handler error reaches the page as something the protocol can say" {
    // A handler's error set is wider than BridgeError. Whatever it raises still
    // has to arrive as an error code, because the alternative is a handler that
    // fails silently and leaves the caller on a promise that never settles.
    try testing.expectEqual(
        bridge_error.BridgeError.AllocationFailed,
        asBridgeError(error.OutOfMemory),
    );
    try testing.expectEqual(
        bridge_error.BridgeError.UnknownAction,
        asBridgeError(error.UnknownAction),
    );
    try testing.expectEqual(
        bridge_error.BridgeError.PlatformNotSupported,
        asBridgeError(error.UnsupportedPlatform),
    );
    // The catch-all. An error the protocol has no word for still gets one.
    try testing.expectEqual(
        bridge_error.BridgeError.NativeCallFailed,
        asBridgeError(error.SomethingNobodyAnticipated),
    );
}

test "a request id survives the trip out to the host and back" {
    // The shim may answer asynchronously, by which point the dispatch frame is
    // gone and `request_context.current()` is empty. The id is therefore read
    // at hand-off time and passed explicitly, then restored on delivery. Losing
    // it would drop the reply back to action-name matching, which hands one
    // caller's answer to another whenever two calls of the same action are in
    // flight.
    request_context.push(7);
    const captured: i64 = if (request_context.current()) |id| @intCast(id) else -1;
    request_context.pop();

    try testing.expectEqual(@as(i64, 7), captured);
    try testing.expectEqual(@as(?u64, null), request_context.current());

    // And the negative sentinel round-trips as "no id", matching the null the
    // envelope carries when the page sent none.
    request_context.push(if (captured < 0) null else @intCast(captured));
    defer request_context.pop();
    try testing.expectEqual(@as(?u64, 7), request_context.current());
}

test "a shim error carries its code, message, and id, correctly escaped" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);

    // The message contains the three characters Swift's hand-escaping got
    // wrong: a backslash, a quote, and a newline.
    try buildShimError(testing.allocator, &out, "share", "path \\ \"x\"\ngone", "NOT_FOUND", 9);
    try testing.expectEqualStrings(
        "{\"error\":true,\"code\":\"NOT_FOUND\",\"action\":\"share\",\"message\":\"path \\\\ \\\"x\\\"\\ngone\",\"id\":9}",
        out.items,
    );
}

test "a shim error with no request id omits the id field entirely" {
    // Omitted, not null or -1: the page's error handler treats a present id as
    // a promise to reject, and a sentinel would reject nothing — or worse,
    // someone else's call.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);

    try buildShimError(testing.allocator, &out, "share", "m", "E", -1);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"id\"") == null);
}

test "a host offer that no module recognises comes back as the host's problem" {
    // The whole contract of `craft_ios_handle_action` in one assertion. A
    // Swift-hosted app calls this first and serves the action itself when the
    // answer is false; if an unrecognised action ever returned true, that
    // action would silently stop working in every generated app — the page's
    // promise would hang with nobody having agreed to answer it.
    try testing.expect(!craft_ios_handle_action("noSuchAction", "noSuchAction".len, "{}", 2, 7));
}

test "a host offer for a served action is claimed, not handed back" {
    // `getDeviceInfo` is served by `bridge_mobile_device.zig` on every
    // platform this test runs on. The reply cannot arrive — there is no
    // webview in a test binary, so `sendResultToJS` reaches
    // `error.NoWebView` — but claiming is the half under test: true means Zig
    // has taken responsibility, and a caller that also answered would be the
    // double-reply this return value exists to prevent.
    //
    // Off Darwin the action still routes; it just fails inside the handler,
    // which is `answered` too. Either way the answer is true, and that is the
    // point: "claimed" is about ownership, never about success.
    try testing.expect(craft_ios_handle_action("getDeviceInfo", "getDeviceInfo".len, "{}", 2, 1));
}

test "a host offer for a disabled capability is claimed and refused, not handed back" {
    // The trap this return value is shaped around. `clipboardRead` is served
    // by Zig and gated on `enableClipboard`; a test binary has no bundled
    // craft.config.json, so `isEnabled` is false and the gate refuses.
    //
    // The refusal already called `sendErrorToJS`, so the page's promise is
    // settled. Returning false here would invite the Swift arm to answer the
    // same call a second time — and Swift's own arm for a disabled capability
    // has no `else`, so the page would get one rejection and one silence.
    try testing.expect(craft_ios_handle_action("clipboardRead", "clipboardRead".len, "{}", 2, 3));
}

test "a negative request id means no callback is waiting" {
    // Mirrors `craft_ios_deliver_result`'s reading of the same sentinel. The
    // id is pushed for the duration of the call and popped after, so a stack
    // that leaked a frame would be visible here as a non-empty context once
    // the call has returned.
    try testing.expect(request_context.current() == null);
    _ = craft_ios_handle_action("noSuchAction", "noSuchAction".len, "{}", 2, -1);
    try testing.expect(request_context.current() == null);
}

test "setting the webview from a host is what makes replies reachable" {
    // The one call a Swift-hosted app must make before offering anything.
    // Without it every reply lands on `error.NoWebView`: the action runs, it
    // works, and the page never hears. Restored afterwards so the ordering of
    // tests in this file cannot matter.
    const saved = getWebView();
    defer setWebView(saved);

    setWebView(null);
    try testing.expectError(error.NoWebView, evalJS("1"));

    var fake: u8 = 0;
    craft_ios_set_webview(&fake);
    try testing.expect(getWebView() == @as(objc.id, @ptrCast(&fake)));

    // And clearing it is reachable again, which is the half that was broken:
    // a host that hands over nil must leave the runtime saying "no webview"
    // rather than quietly addressing every reply to it.
    craft_ios_set_webview(null);
    try testing.expectError(error.NoWebView, evalJS("1"));
}

test "an action declared unavailable is left to the host, not claimed" {
    // The regression this guards. Each of these has a working Swift arm and a
    // Zig handler that refuses on purpose; before the host-offered path knew
    // the difference, linking the runtime replaced the working answer with a
    // rejection. `false` here is what sends the call back to Swift's switch.
    const declared_unavailable = [_][]const u8{
        "haptic",
        "getNetworkStatus",
        "lockOrientation",
        "unlockOrientation",
    };
    for (declared_unavailable) |action| {
        try testing.expect(hostServesItself(action));
        try testing.expect(!craft_ios_handle_action(action.ptr, action.len, "{}", 2, 11));
    }
}

test "the fall-through is read from the manifests, not from a list kept beside them" {
    // `hostServesItself` must answer for exactly the actions the modules
    // declare `.unavailable` — no more, or a working Zig action is handed away;
    // no fewer, or the regression comes back for whichever one was missed. So
    // count the declarations rather than trusting the test above's literals.
    var declared: usize = 0;
    for (mobile_manifests) |manifest| {
        for (manifest) |decl| {
            if (decl.status == .unavailable) {
                declared += 1;
                try testing.expect(hostServesItself(decl.name));
            }
        }
    }
    try testing.expectEqual(@as(usize, 4), declared);
}

test "a live action is still claimed, unavailable is not a blanket hand-back" {
    // The other half: `vibrate` sits in the same module as `haptic` and is
    // `.live`, so the seam must keep claiming it. A fall-through that widened
    // to whole modules would silently un-migrate everything beside a refusal.
    try testing.expect(!hostServesItself("vibrate"));
    try testing.expect(!hostServesItself("setKeepAwake"));
    try testing.expect(!hostServesItself("getDeviceInfo"));
    try testing.expect(!hostServesItself("noSuchAction"));
}

test "clearing the webview only forgets the one the caller named" {
    // The rebuild order that makes a blind clear wrong: SwiftUI builds the
    // replacement, then dismantles the original. If dismantling cleared
    // unconditionally, the live view installed a moment earlier would be
    // dropped and every reply after it would reach `error.NoWebView`.
    const first: *anyopaque = @ptrFromInt(0x1000);
    const second: *anyopaque = @ptrFromInt(0x2000);
    defer setWebView(null);

    craft_ios_set_webview(first);
    craft_ios_set_webview(second); // the replacement arrives first
    craft_ios_clear_webview(first); // then the original is dismantled
    try testing.expect(getWebView() == second);

    craft_ios_clear_webview(second);
    try testing.expect(getWebView() == null);
}
