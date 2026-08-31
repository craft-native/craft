//! `openCamera` and `pickImage` — the `mobile` namespace's two photo actions.
//!
//! They are one picker. Swift serves both from a single
//! `UIImagePickerController` and a single delegate pair on `Coordinator`
//! (`CraftApp.swift:376` declares `UIImagePickerControllerDelegate,
//! UINavigationControllerDelegate`), and they differ in exactly one property:
//! `sourceType`. The two delegate methods, the success shape, the cancel
//! shape and the dismissal are shared. So this is one module, one delegate
//! class, one instance, one pending ticket — and `Source` is both the action
//! selector and the `UIImagePickerControllerSourceType` raw value.
//!
//! ## What crosses the bridge
//!
//! **Nothing.** Both injected methods are declared `function()` with zero
//! parameters (`CraftApp.swift:1574-1590`), and the v1 surface drops its
//! options on the floor too — `craft.camera.takePicture` is
//! `function() { return legacyOpenCamera().then(normalizePhoto); }` at
//! `:2343`, so the `CameraOptions` typed in
//! `packages/typescript/src/api/mobile.ts:517` never reaches native on iOS.
//! The Swift dispatcher reads nothing out of `body` either (`:554-563`).
//! `data` is therefore accepted and ignored, on the
//! `bridge_mobile_location.getCurrentPosition` precedent: parsing it would
//! invent a failure mode the shim does not have. There is no field here to
//! drop.
//!
//! ## What goes back
//!
//! **Success is a five-key object**, `CraftApp.swift:2647-2654`:
//!
//! ```json
//! {"base64":"…","uri":"data:image/jpeg;base64,…","width":3024,"height":4032,"mimeType":"image/jpeg"}
//! ```
//!
//! `base64` is the raw encoding and `uri` is the same bytes again behind a
//! `data:` prefix. The duplication is the contract — `normalizePhoto`
//! (`:2417`) passes an object straight through onto `PhotoResult`
//! (`mobile.ts:533-544`), which names all five keys — so it is reproduced
//! rather than tidied. `mimeType` is the literal `"image/jpeg"` for both
//! actions always, because the image is re-encoded to JPEG whatever the user
//! picked. `width`/`height` are `-[UIImage size]` in **points**, and
//! `JSONSerialization` renders an integral double with no fraction, which is
//! what `{d}` does too.
//!
//! `test-bridges.html:513` reads the result as a string (`image?.length`) and
//! has therefore printed `Base64 length: 0` against Swift for as long as this
//! dictionary has existed. That is a pre-existing bug in the test page, not a
//! reason to reply with a bare string: a string would break `craft.camera.*`
//! and the SDK, which are written for the object.
//!
//! **Cancel is a rejection**, not a resolve and not a distinct result
//! (`:2661-2665` — `rejectCallback(pendingCallbackId, error: "Cancelled")`).
//! It has to be: `craft-bridge.js:70` resolves with `payload || {}`, so a
//! `null` or `false` result would arrive at the page as `{}` and the app's
//! `catch` would never run.
//!
//! ## The one thing this module cannot say
//!
//! Swift's cancel carries `code: "CRAFT_ERROR"` and `message: "Cancelled"`.
//! `ios_async.deliverError` hardcodes `bridge_error.BridgeError.NativeCallFailed`
//! (`ios_async.zig:258-265`), so the rejection the page receives here says
//! `NATIVE_CALL_FAILED` / `"Native API call failed"`. The promise still
//! rejects and the app's `catch` still runs — that half of the contract is
//! kept — but the stated cause is wrong, and this comment is the only place
//! that is allowed to say otherwise.
//!
//! Calling `bridge_error.sendErrorToJS` from the delegate callback instead is
//! not an option: it ends in `evaluateJavaScript`, and by then the request id
//! is gone anyway. The fix is a foundation change —
//! `ios_async.deliverErrorCode(ticket, err)`, one extra field on `Slot` set
//! under the same lock — and the document and contact pickers need the
//! identical thing (`documentPickerWasCancelled` `:4912`,
//! `contactPickerDidCancel` `:5102` both say `"Cancelled"`). It is recorded
//! here rather than worked around.
//!
//! ## The config gate, and exactly what it stands in for
//!
//! Swift wraps both actions in `if config.enableCamera`, which defaults to
//! **false** (`CraftApp.swift:192`, `packages/ios/src/index.ts:120`). When it
//! is false the `case` falls off the end and replies *nothing at all*, while
//! `CraftSwiftShim.handleAction` still returns `true` (`:5247`) so Zig
//! believes the hand-off succeeded. The injected promise is the hand-built
//! kind with no timeout. **In a default-config app, `openCamera` and
//! `pickImage` hang the page forever today.** The "working Swift shim" is
//! only working for an app that set `enableCamera: true`.
//!
//! `enableCamera` has no Zig-reachable channel, so this module gates on the
//! Info.plist keys `packages/ios/src/index.ts:185-186` writes:
//!
//!  - **`NSCameraUsageDescription` is an extra gate on `openCamera` only, and
//!    it is a crash guard rather than a config proxy.** Presenting a `.camera` picker in a
//!    process without that key is a TCC termination, not an error anything
//!    could be told about. It is written for
//!    `enableCamera || enableVideoRecording || enableQRScanner || enableAR`.
//!  - **`NSPhotoLibraryUsageDescription` stands in for `config.enableCamera`,
//!    and it is over-broad by `enableVideoRecording`** — it is written for
//!    `enableCamera || enableVideoRecording`, which is the closest proxy
//!    available. It is emphatically **not** a photo-library permission gate:
//!    `UIImagePickerController` with `.photoLibrary` has run out-of-process
//!    since iOS 11 and neither prompts nor requires the key. Refusing on it is
//!    a statement about how the app was configured, never about what the
//!    system would allow.
//!
//! So `openCamera` requires *both* keys and `pickImage` requires only the
//! photo-library one.
//!
//! Measured against the shim, that trades three ways. An `enableCamera: true`
//! app behaves exactly as it does now. A default-config app gets an explicit
//! `PERMISSION_DENIED` instead of a promise that never settles — strictly
//! better. And exactly one configuration, `enableVideoRecording: true` with
//! `enableCamera: false`, gains a capability Swift denies it; that one is a
//! real widening, it runs in the direction the Info.plist already sanctions
//! (the usage strings exist, so the user sees a prompt the app declared), and
//! the cell it widens is otherwise an infinite hang. The alternative was to
//! leave both actions out of `A` entirely and keep the hang, which is a trade
//! rather than a free choice.
//!
//! `.unavailable` was never on the table: a declared-`.unavailable` action
//! dispatches and refuses, which would take the working `enableCamera: true`
//! path away from the shim. `bridge_mobile_misc.zig`'s "Why unserved rather
//! than `.unavailable`" is the precedent.
//!
//! ## Simulator
//!
//! `+[UIImagePickerController isSourceTypeAvailable:]` answers `NO` for
//! `.camera` on every simulator. Presenting anyway shows nothing and the
//! delegate never fires — a promise that hangs, the single worst outcome — so
//! `openCamera` asks first and refuses synchronously, before any slot is
//! leased, exactly as Swift does at `:2616-2619`. `pickImage` has no such
//! guard in Swift and gets none here: `.photoLibrary` is available on
//! simulator and device alike, and an empty library still presents a picker
//! whose only move is Cancel.
//!
//! ## One picker, one caller
//!
//! A modal serves exactly one call, so there is one `pending` for the module
//! rather than one per action — both actions present the same kind of sheet
//! and only one can be up. A second request while one is presented is refused
//! **for the second caller**, with the first left alone. That is the opposite
//! of `bridge_mobile_location.getCurrentPosition`, which rejects the
//! *displaced first* call: there `requestLocation` genuinely cancels the
//! earlier request so it can never be answered, while here the first picker is
//! still on screen and will answer. Replacing it would strand its promise
//! forever.
//!
//! The cost of refusing rather than displacing is that a `pending` which is
//! never taken refuses every later call for the life of the process. Three
//! callbacks can take it — the pick, the cancel, and
//! `presentationControllerDidDismiss:` for the swipe-down that has been widely
//! reported not to fire `imagePickerControllerDidCancel:` since iOS 13. That
//! third one is a belt, not a proof: if a presentation controller cannot be
//! reached the module says so in the log and does **not** claim that a cancel
//! is always delivered.
//!
//! ## A Swift bug this deliberately does not inherit
//!
//! `startVideoRecording` (`:3731-3749`) reuses the *same* `Coordinator`
//! delegate and the *same* `pendingCallbackId`, sets `mediaTypes` to
//! `["public.movie"]`, and then `didFinishPickingMediaWithInfo` reads
//! `info[.originalImage]` — nil for a movie — so every finished recording
//! rejects with `"Failed to process image"`. It stays with the shim; because
//! this module has its own delegate class and its own instance, the crosstalk
//! disappears rather than getting worse.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const ios_delegate = @import("ios_delegate.zig");
const bridge_mobile_system = @import("bridge_mobile_system.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The same type as `objc.id` — `?*anyopaque` — spelled locally, per the
/// location/motion precedent: `objc_runtime.objc` is an empty struct off
/// Darwin and a `callconv(.c)` fn-pointer *type* is analysed even when a
/// comptime platform guard prunes the body around it. A single optional
/// pointer, never `?objc.id`: a double optional is illegal in `callconv(.c)`.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches this block against those labels in
/// both directions and fails the build if two modules declare one name.
pub const A = struct {
    pub const open_camera = "openCamera";
    pub const pick_image = "pickImage";
};

/// `.result`: each Swift path terminates in one `resolveCallback` (the pick)
/// or one `rejectCallback` (the cancel, or an image that would not encode),
/// and the page's promise is the hand-built kind with no timeout — `.none`
/// here would park a caller forever rather than for thirty seconds.
///
/// `.live`: it dispatches and presents. A refusal is a specific failure — the
/// app was not built with the camera enabled, no camera on this device, the
/// picker is already up — never the action's normal answer, which is what
/// `.unavailable` would declare.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.open_camera, .reply = .result },
    .{ .name = A.pick_image, .reply = .result },
};

/// Which picker an action selects — and, because the values are chosen to be,
/// the `UIImagePickerControllerSourceType` to set.
///
/// `NSInteger`, hence `c_long`: a narrower type passes 0 and 1 correctly by
/// luck and breaks the day the enum grows.
/// `UIImagePickerControllerSourceTypeSavedPhotosAlbum = 2` is deliberately
/// absent — no action posts it.
const Source = enum(c_long) {
    photo_library = 0,
    camera = 1,

    fn actionName(self: Source) []const u8 {
        return switch (self) {
            .camera => A.open_camera,
            .photo_library => A.pick_image,
        };
    }
};

/// Which picker an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host that has no UIKit.
fn routeFor(action: []const u8) ?Source {
    if (std.mem.eql(u8, action, A.open_camera)) return .camera;
    if (std.mem.eql(u8, action, A.pick_image)) return .photo_library;
    return null;
}

/// `image.jpegData(compressionQuality: 0.8)` — Swift's spelling, `:2646`.
/// Always JPEG, always this quality, for both actions.
const jpeg_compression_quality: f64 = 0.8;

pub const ImagePickerBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const source = routeFor(action) orelse return bridge_error.BridgeError.UnknownAction;
        return self.present(source, data);
    }

    /// Configure a `UIImagePickerController` for `source`, present it, and let
    /// the delegate answer when the user is done.
    ///
    /// `data` is accepted and ignored — see the module comment; neither JS
    /// surface sends a field and the Swift dispatcher reads none.
    ///
    /// Every fallible step runs *before* `ios_async.acquire`: the config gate,
    /// the class, the camera-availability question, all five delegate
    /// selectors, both `dlsym`s, the delegate class and instance, the
    /// presenter, the picker itself and every selector used to present it.
    /// `bridge_mobile_location.zig` states the rule this follows: no error path
    /// may exist between leasing a slot and handing the request to the
    /// framework, because a missed `abandon` permanently narrows the pool. The
    /// one exception below — `publish` answering `.busy` — releases the lease
    /// by hand on the way out, and is the only path that has to.
    fn present(self: *Self, source: Source, data: []const u8) !void {
        _ = self;
        _ = data;
        if (!is_darwin) return error.UnsupportedPlatform;

        const action = source.actionName();

        // The config gate first. It is the only refusal that touches no UIKit
        // at all, and on a host build it is what keeps everything below from
        // running against a runtime that has no picker in it.
        try requireConfigured(source);

        // A cheap refusal before any of the expensive work: a modal is on
        // screen, so nothing built here could be presented anyway. `publish`
        // below is the authoritative one — it decides under the lock, so a
        // request that slipped past this read still cannot displace the first.
        if (busyWith()) |holder| return busyRefusal(action, holder);

        const PickerClass = objc.objc_getClass("UIImagePickerController") orelse {
            std.log.warn(
                "{s} refused: this process has no UIImagePickerController class, " ++
                    "so UIKit is not loaded here",
                .{action},
            );
            return bridge_error.BridgeError.PlatformNotSupported;
        };

        // Swift's `guard UIImagePickerController.isSourceTypeAvailable(.camera)`.
        // Asked, never assumed: on a simulator the answer is NO, and presenting
        // anyway shows nothing and never calls the delegate back.
        if (source == .camera) {
            const sel_available = try selector("isSourceTypeAvailable:");
            const AvailableFn = *const fn (Id, Id, c_long) callconv(.c) bool;
            const available: AvailableFn = @ptrCast(&objc.objc_msgSend);
            if (!available(PickerClass, sel_available, @backingInt(Source.camera))) {
                std.log.warn(
                    "openCamera refused: no camera source is available on this device " ++
                        "(every simulator answers NO)",
                    .{},
                );
                return bridge_error.BridgeError.PlatformNotSupported;
            }
        }

        // Everything the delegate will need to shape a reply, resolved while an
        // error is still deliverable to the caller.
        const work = try Work.resolve();

        const delegate = try ensureDelegate();
        const presenter = try bridge_mobile_system.uikit.topmostViewController();

        const sel_set_source = try selector("setSourceType:");
        const sel_set_delegate = try selector("setDelegate:");
        const sel_present = try selector("presentViewController:animated:completion:");

        const picker = (try objc.allocInit(PickerClass)) orelse return error.NativeCallFailed;
        // +1 from alloc/init. The presenting controller retains the picker for
        // the life of the presentation, so this reference is ours to drop —
        // and on every error path below it is the only one there is. Same
        // shape as `bridge_mobile_system.share`.
        defer objc.release(picker);

        const SetSourceFn = *const fn (Id, Id, c_long) callconv(.c) void;
        const set_source: SetSourceFn = @ptrCast(&objc.objc_msgSend);
        set_source(picker, sel_set_source, @backingInt(source));

        // `mediaTypes` and `allowsEditing` are deliberately left alone: Swift
        // sets neither, so the defaults (`["public.image"]` and `NO`) are the
        // contract, and `.originalImage` is the right info key precisely
        // because editing is off.
        objc.msgSendVoid1(picker, sel_set_delegate, delegate);

        // If UIKit adapts this presentation to a popover — which it can on a
        // regular size class, i.e. any iPad and iPhone in some multitasking
        // configurations — it raises `NSGenericException` when neither
        // `sourceView` nor `barButtonItem` is set, and an Objective-C exception
        // is an uncatchable crash from Zig. `anchorPopover` reads
        // `popoverPresentationController` and returns immediately when it is
        // nil, which Apple documents it to be unless the modal presentation
        // style is `.popover`. So this either anchors a popover correctly or
        // does nothing at all; which of the two happens is UIKit's decision and
        // is not predicted here.
        try bridge_mobile_system.uikit.anchorPopover(picker, presenter);

        var dismiss_observed = attachDismissObserver(picker, delegate, sel_set_delegate);

        const PresentFn = *const fn (Id, Id, Id, bool, Id) callconv(.c) void;
        const present_fn: PresentFn = @ptrCast(&objc.objc_msgSend);

        const ticket = ios_async.acquire(action) orelse return poolFull(action);

        // Published before the framework call, never after: presentation is
        // asynchronous but a delegate callback that reached an empty slot would
        // have no ticket to answer with.
        switch (publish(.{ .ticket = ticket, .source = source, .work = work })) {
            .published => {},
            .busy => |holder| {
                // Lost a race with another dispatch. The lease is released by
                // hand here because this is the one error path that exists
                // after `acquire`; leaving it would narrow the pool forever.
                ios_async.abandon(ticket);
                return busyRefusal(action, holder);
            },
        }

        present_fn(presenter, sel_present, picker, true, null);

        // A presentation controller may only exist once the presentation has
        // begun. Retried here rather than claimed above, because the interactive
        // -dismissal callback is the only thing that can free `pending` when a
        // sheet is swiped away and `imagePickerControllerDidCancel:` does not
        // fire.
        if (!dismiss_observed) dismiss_observed = attachDismissObserver(picker, delegate, sel_set_delegate);
        if (!dismiss_observed) {
            std.log.info(
                "{s}: no presentation controller to observe; a swipe-down dismissal " ++
                    "may leave this call unanswered",
                .{action},
            );
        }
    }
};

/// The answer for a full slot pool, copied from `bridge_mobile_location`:
/// `BridgeError` has no "Busy", `INVALID_PARAMETER` is the migration notes'
/// designated stand-in, and the point is that the caller gets an explicit
/// rejection instead of a promise that never settles.
fn poolFull(action: []const u8) bridge_error.BridgeError {
    std.log.warn(
        "{s} refused: all {d} async slots in flight",
        .{ action, ios_async.max_in_flight },
    );
    return bridge_error.BridgeError.InvalidParameter;
}

/// The answer for a second request while a picker is already on screen.
///
/// The *second* caller is refused and the first is left alone, because the
/// first picker is still up and will answer. Same `INVALID_PARAMETER`
/// stand-in, for the same reason: `BridgeError` cannot say "busy", and silence
/// is not an option.
fn busyRefusal(action: []const u8, holder: Source) bridge_error.BridgeError {
    std.log.warn(
        "{s} refused: {s} already has a picker presented; refusing the second call rather " ++
            "than replacing the first, whose promise would then never settle",
        .{ action, holder.actionName() },
    );
    return bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// Reply shaping. Pure — no Objective-C — so the exact bytes the page receives
// are pinned by host tests on every platform.
// =============================================================================

/// One picked image, read into plain values.
///
/// `base64` is the raw encoding, owned by whoever built it. `width`/`height`
/// are `-[UIImage size]` in points, which is what Swift puts on the wire.
const Photo = struct {
    base64: []const u8,
    width: f64,
    height: f64,
};

/// The five-key object Swift's `didFinishPickingMediaWithInfo` resolves.
///
/// Key order is fixed at base64, uri, width, height, mimeType. Swift's is a
/// `Dictionary` and therefore arbitrary; a caller cannot depend on it, but a
/// test can only pin bytes that are deterministic, so one order is chosen and
/// held.
///
/// The encoded payload is appended **twice** — once raw, once behind the
/// `data:` prefix — because that is what `PhotoResult` is written for. It is
/// the single largest cost in this path and it is not this module's to change.
fn shapePhoto(allocator: std.mem.Allocator, photo: Photo) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // Not escaped, and that is checked rather than asserted: the standard
    // base64 alphabet plus its pad character contains no byte JSON must
    // escape. See "the encoded payload needs no JSON escaping" below, which
    // fails if the encoder is ever swapped for one whose alphabet does.
    try out.appendSlice(allocator, "{\"base64\":\"");
    try out.appendSlice(allocator, photo.base64);
    try out.appendSlice(allocator, "\",\"uri\":\"");
    try out.appendSlice(allocator, data_uri_prefix);
    try out.appendSlice(allocator, photo.base64);
    try out.appendSlice(allocator, "\",\"width\":");
    try appendNumber(allocator, &out, photo.width);
    try out.appendSlice(allocator, ",\"height\":");
    try appendNumber(allocator, &out, photo.height);
    try out.appendSlice(allocator, ",\"mimeType\":\"");
    try out.appendSlice(allocator, mime_type);
    try out.appendSlice(allocator, "\"}");

    return out.toOwnedSlice(allocator);
}

/// Swift's `"data:image/jpeg;base64," + base64`.
const data_uri_prefix = "data:image/jpeg;base64,";

/// The literal Swift sends for both actions, always — the image is re-encoded
/// to JPEG, so a PNG or HEIC chosen from the library still arrives as this.
const mime_type = "image/jpeg";

/// One `f64` as a JSON number.
///
/// `{d}` renders decimal notation, never scientific, and prints an integral
/// value with no fraction — `3024`, matching what `JSONSerialization` writes
/// for the same `CGFloat`. A finite `f64` can need up to
/// `std.fmt.float.bufferSize(.decimal, f64)` (347) bytes, so the buffer is
/// sized from the formatter rather than guessed.
///
/// Non-finite is refused rather than printed: `inf` and `nan` are not JSON,
/// and `JSONSerialization` refuses them too. A refusal reaches the page as a
/// rejection; printing them would produce a syntax error inside the reply
/// script with nothing to point at.
fn appendNumber(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: f64,
) !void {
    if (!std.math.isFinite(value)) return bridge_error.BridgeError.InvalidParameter;
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{value}));
}

/// What a delegate callback decided to send.
///
/// Deciding and sending are separate so the decision is checkable without a
/// picker: getting `.reject` and `.photo` the wrong way round is the difference
/// between an app's `catch` running and its `then` running on an image that
/// does not exist.
const Answer = union(enum) {
    /// The five-key object, ready to hand to `ios_async.deliverJson`.
    photo: []const u8,
    /// A rejection. Every failure *and* every cancel takes this arm.
    reject,
};

/// The two ways this module answers a captured call, and the only two.
///
/// Neither replies directly — `evaluateJavaScript` is main-thread-only and
/// these run on a framework callback — so both go through `ios_async`, which
/// hops to the main queue under the request id captured back at dispatch.
fn settle(call: Pending, answer: Answer) void {
    switch (answer) {
        .photo => |json| ios_async.deliverJson(call.ticket, json),
        // A Cancel is not a native failure — the call worked and the answer
        // is "no" — so it carries the code that says so.
        .reject => ios_async.deliverErrorCode(call.ticket, bridge_error.BridgeError.Cancelled),
    }
}

/// Swift's `if let image = …, let imageData = … { resolve } else { reject }`.
/// A reply that could not be built is a rejection, never an object with an
/// empty payload and zeroed dimensions — `normalizePhoto` would hand the app
/// exactly that and its `then` would run.
fn finishAnswer(json: ?[]const u8) Answer {
    return if (json) |bytes| .{ .photo = bytes } else .reject;
}

/// A cancel is a **rejection**. Swift is
/// `rejectCallback(pendingCallbackId, error: "Cancelled")`, and
/// `craft-bridge.js` resolves with `payload || {}`, so any resolved shape —
/// `null`, `false`, `{}` — would run the app's `then` branch for a picture the
/// user declined to take.
const cancel_answer: Answer = .reject;

// =============================================================================
// The config gate. See the module comment for what each key does and does not
// stand for.
// =============================================================================

/// Written by `packages/ios/src/index.ts:185` for
/// `enableCamera || enableVideoRecording || enableQRScanner || enableAR`.
/// Required before a `.camera` picker may be presented at all.
const key_camera_usage = "NSCameraUsageDescription";

/// Written by `packages/ios/src/index.ts:186` for
/// `enableCamera || enableVideoRecording`. Used here as the closest available
/// proxy for `config.enableCamera` — **not** as a permission gate; a
/// `.photoLibrary` picker needs no such key on iOS 11+.
const key_photo_library_usage = "NSPhotoLibraryUsageDescription";

fn requireConfigured(source: Source) !void {
    if (!is_darwin) return error.UnsupportedPlatform;

    // Checked first, and only for the camera: this one is a crash guard, not a
    // configuration question. Presenting a `.camera` picker in a process
    // without the key is a TCC termination — there is no error to map and
    // nothing left to tell the page.
    if (source == .camera and !try infoPlistHas(key_camera_usage)) {
        std.log.warn(
            "openCamera refused: Info.plist has no {s}, and presenting a camera picker " ++
                "without it terminates the process rather than failing",
            .{key_camera_usage},
        );
        return bridge_error.BridgeError.PermissionDenied;
    }

    if (!try infoPlistHas(key_photo_library_usage)) {
        std.log.warn(
            "{s} refused: Info.plist has no {s}, the closest available proxy for " ++
                "config.enableCamera, so this app was not built with the camera enabled",
            .{ source.actionName(), key_photo_library_usage },
        );
        return bridge_error.BridgeError.PermissionDenied;
    }
}

/// Whether the main bundle's Info.plist carries `key`.
///
/// Errors rather than answering `false` when the runtime itself will not
/// cooperate: "there is no NSBundle class" and "this app did not enable the
/// camera" are different facts, and collapsing them would blame the app's
/// configuration for a broken process. Every runtime result is guarded.
fn infoPlistHas(comptime key: [*:0]const u8) !bool {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSBundle = objc.objc_getClass("NSBundle") orelse return error.ClassNotFound;
    const sel_main = objc.sel_registerName("mainBundle") orelse return error.SelectorNotFound;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return error.NoMainBundle;

    const NSString = objc.objc_getClass("NSString") orelse return error.ClassNotFound;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse
        return error.SelectorNotFound;
    const ns_key = objc.msgSendId1(NSString, sel_string, key) orelse return error.NativeCallFailed;

    const sel_lookup = objc.sel_registerName("objectForInfoDictionaryKey:") orelse
        return error.SelectorNotFound;
    return objc.msgSendId1(bundle, sel_lookup, ns_key) != null;
}

// =============================================================================
// Everything the delegate needs, resolved while an error is still deliverable.
// =============================================================================

fn selector(name: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.sel_registerName(name) orelse error.SelectorNotFound;
}

/// The five selectors a delegate callback sends.
///
/// Resolved at dispatch for the reason `bridge_mobile_location.Sels` states: a
/// `sel_registerName` failure inside a callback could only be logged, or worse
/// turned into a rejection for a picture the user actually took.
const Sels = struct {
    object_for_key: Id,
    size: Id,
    bytes: Id,
    length: Id,
    /// `-[UIViewController dismissViewControllerAnimated:completion:]`, sent to
    /// the picker; UIKit forwards it to the presenter. Both Swift callbacks
    /// call it, and missing either one leaves the app behind a modal forever.
    dismiss: Id,

    fn resolve() !Sels {
        if (!is_darwin) return error.UnsupportedPlatform;
        return .{
            .object_for_key = try selector("objectForKey:"),
            .size = try selector("size"),
            .bytes = try selector("bytes"),
            .length = try selector("length"),
            .dismiss = try selector("dismissViewControllerAnimated:completion:"),
        };
    }
};

/// `NSData *UIImageJPEGRepresentation(UIImage *, CGFloat)`.
///
/// `CGFloat` is `double` on every 64-bit Apple platform. This is a plain C
/// function with no Objective-C equivalent — `-jpegData(compressionQuality:)`
/// is Swift-only sugar over it.
const JpegFn = *const fn (Id, f64) callconv(.c) Id;

/// Everything a delegate callback needs, captured for the call it will answer.
const Work = struct {
    sels: Sels,
    /// The value of `UIImagePickerControllerOriginalImage`, the info key Swift
    /// reads. Resolved before presenting, so a UIKit that does not carry it is
    /// a synchronous refusal rather than a picker nobody can read the result of.
    original_image_key: Id,
    jpeg: JpegFn,

    fn resolve() !Work {
        if (!is_darwin) return error.UnsupportedPlatform;

        // `dlsym` rather than `extern "c"`: the host test binaries link
        // Cocoa/WebKit/CoreGraphics and not UIKit, and `refAllDecls` forces
        // analysis of every declaration, so an `extern "c" fn
        // UIImageJPEGRepresentation` would be an undefined symbol at host link
        // time. The same route `bridge_mobile_location.bestAccuracy` takes for
        // `kCLLocationAccuracyBest`.
        const jpeg_symbol = dlsym(RTLD_DEFAULT, "UIImageJPEGRepresentation") orelse {
            std.log.warn(
                "image picker refused: UIImageJPEGRepresentation is not in this process, " ++
                    "so a picked image could not be encoded",
                .{},
            );
            return bridge_error.BridgeError.PlatformNotSupported;
        };

        // `UIImagePickerControllerOriginalImage` is an `extern NSString * const`
        // in UIKit. Read through the symbol rather than rebuilt from its own
        // spelling: the constant's *value* happening to equal its name is
        // undocumented, and a null answer here is the honest "UIKit is not
        // here" rather than a plausible-looking string that matches nothing.
        const key_symbol = dlsym(RTLD_DEFAULT, "UIImagePickerControllerOriginalImage") orelse {
            std.log.warn(
                "image picker refused: UIImagePickerControllerOriginalImage is not in this " ++
                    "process, so a pick could not be read",
                .{},
            );
            return bridge_error.BridgeError.PlatformNotSupported;
        };
        const key_cell: *const Id = @ptrCast(@alignCast(key_symbol));
        const original_image_key = key_cell.* orelse return error.NativeCallFailed;

        return .{
            .sels = try Sels.resolve(),
            .original_image_key = original_image_key,
            // `@alignCast` because `dlsym` answers with a `*anyopaque`, whose
            // alignment is 1; a function pointer's is 4. The assertion is sound —
            // this address is a function entry point in a loaded image.
            .jpeg = @ptrCast(@alignCast(jpeg_symbol)),
        };
    }
};

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// dyld's "search every image" pseudo-handle, `(void *)-2` on Darwin.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

// =============================================================================
// The delegate class, built at runtime.
// =============================================================================

/// Deliberately namespaced, on the `CraftIOSLocationDelegate` precedent: a
/// generic name risks colliding with a desktop class in the same host test
/// binary, and both sides look their class up with `objc_getClass` first — so
/// whichever registered second would silently adopt the other's IMPs.
const delegate_class_name = "CraftIOSImagePickerDelegate";

/// The delegate instance, held for the life of the process.
///
/// `UIImagePickerController` holds its `delegate` **weakly**, and
/// `ios_delegate.instantiate` returns +1 while retaining nothing. This var is
/// the strong reference; without it the first Cancel is a use-after-free.
var delegate_instance: Id = null;

/// The method table, so the encodings are assertable on a host.
///
/// A wrong encoding string still registers and still dispatches, then reads
/// arguments out of the wrong registers with no crash and no compile error —
/// which is why `ios_delegate.enc` names the shapes rather than spelling them.
///
/// A function rather than a `const`: `@ptrCast` from a function pointer to
/// `*const anyopaque` is a runtime cast, and a container-level initialiser
/// would ask the compiler to perform it at comptime.
///
/// The three IMPs are plain `fn … callconv(.c)` rather than `export fn`. What
/// `class_addMethod` needs is the C calling convention and the `(self, _cmd, …)`
/// parameter order, both of which a plain function has; an exported symbol
/// would additionally be visible to the linker, which is how the desktop and
/// iOS location delegates collided once already.
fn delegateMethods() [3]ios_delegate.Method {
    return .{
        // - (void)imagePickerController:(UIImagePickerController *)picker
        //        didFinishPickingMediaWithInfo:(NSDictionary *)info
        .{
            .selector = "imagePickerController:didFinishPickingMediaWithInfo:",
            .imp = @ptrCast(&craftIOSImagePickerDidFinish),
            .types = ios_delegate.enc.void_two_objects,
        },
        // - (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
        .{
            .selector = "imagePickerControllerDidCancel:",
            .imp = @ptrCast(&craftIOSImagePickerDidCancel),
            .types = ios_delegate.enc.void_one_object,
        },
        // - (void)presentationControllerDidDismiss:(UIPresentationController *)pc
        // The swipe-down belt. iOS 13+; on anything older it is simply never sent.
        .{
            .selector = "presentationControllerDidDismiss:",
            .imp = @ptrCast(&craftIOSImagePickerDidDismiss),
            .types = ios_delegate.enc.void_one_object,
        },
    };
}

/// Register the delegate class once, and keep one instance alive.
///
/// `UIImagePickerControllerDelegate`, `UINavigationControllerDelegate` and
/// `UIAdaptivePresentationControllerDelegate` are deliberately not declared:
/// UIKit dispatches through `respondsToSelector:`, so conformance is not
/// required, and Swift implements none of the navigation-delegate methods it
/// declares at `:376` either.
fn ensureDelegate() !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (delegate_instance) |existing| return existing;

    const methods = delegateMethods();
    const cls = try ios_delegate.defineClass(delegate_class_name, "NSObject", &methods);
    const instance = (try ios_delegate.instantiate(cls)) orelse return error.NativeCallFailed;
    delegate_instance = instance;
    return instance;
}

/// Make the picker's presentation controller report an interactive dismissal
/// to us. Returns whether it was attached.
///
/// A `.photoLibrary` picker has presented as a sheet since iOS 13, and a
/// swipe-down is widely reported not to call
/// `imagePickerControllerDidCancel:`. That report is not verified anywhere in
/// this repo, so this is a belt and not a fix: it costs two messages, and if
/// the report is right it is the only thing that frees `pending` after a
/// swipe. This module refuses later calls while one is pending, so a stranded
/// ticket is worse here than in Swift — it would disable the picker for the
/// life of the process.
///
/// Idempotent against the real cancel: whichever callback runs first takes
/// `pending` under the lock, so the second finds nothing, and `ios_async`'s
/// generation counter would make a second delivery a no-op anyway.
fn attachDismissObserver(picker: Id, delegate: Id, sel_set_delegate: Id) bool {
    if (!is_darwin) return false;

    const sel_presentation = objc.sel_registerName("presentationController") orelse return false;
    const presentation = objc.msgSendId(picker, sel_presentation) orelse return false;
    objc.msgSendVoid1(presentation, sel_set_delegate, delegate);
    return true;
}

// =============================================================================
// One pending call for the whole module, because one modal serves one caller.
// =============================================================================

const Pending = struct {
    ticket: ios_async.Ticket,
    source: Source,
    work: Work,
};

var pending: ?Pending = null;

/// Guards `pending`. Held even though UIKit delivers these callbacks on the
/// main thread, because "it should always be the main thread" is not a guard
/// and the dispatch side is not provably main-thread for every entry point.
var state_mutex: compat_mutex.Mutex = .{};

/// `.busy` carries who is holding the picker, so the refusal can name it.
const PublishResult = union(enum) { published, busy: Source };

/// Record the call the delegate will answer, refusing rather than replacing.
///
/// The opposite of `bridge_mobile_location.publishPendingFix`, deliberately:
/// there the framework cancels the earlier request, so the displaced caller
/// can never be answered and must be rejected. Here the first picker is still
/// on screen and will answer, so replacing it would strand a promise that was
/// about to settle.
fn publish(call: Pending) PublishResult {
    state_mutex.lock();
    defer state_mutex.unlock();
    if (pending) |existing| return .{ .busy = existing.source };
    pending = call;
    return .published;
}

/// Read and clear. Clearing is what makes a second delegate call — a late
/// fire, or the dismissal belt after a real cancel — a no-op rather than a
/// second reply, and it is what frees the picker for the next caller.
fn takePending() ?Pending {
    state_mutex.lock();
    defer state_mutex.unlock();
    const call = pending;
    pending = null;
    return call;
}

/// Which action is holding the picker, or null when it is free.
fn busyWith() ?Source {
    state_mutex.lock();
    defer state_mutex.unlock();
    return if (pending) |call| call.source else null;
}

// =============================================================================
// The delegate methods.
//
// None of them replies directly: `evaluateJavaScript` is main-thread-only and
// these are framework callbacks, so the finished JSON goes to
// `ios_async.deliverJson` (or `deliverError`), which hops to the main queue and
// answers under the request id captured back at dispatch.
// =============================================================================

/// `-imagePickerController:didFinishPickingMediaWithInfo:`
fn craftIOSImagePickerDidFinish(_: Id, _: Id, picker: Id, info: Id) callconv(.c) void {
    if (!is_darwin) return;

    const call = takePending();

    // Swift's first line, and unconditional for a reason: a shaping failure
    // below must still take the modal off the screen. A rejected promise is
    // recoverable; an app stuck behind a picker it cannot close is not.
    dismissPresented(picker, if (call) |c| c.work.sels.dismiss else null);

    const answering = call orelse {
        std.log.info(
            "image picker: a pick arrived with no call waiting; ignored rather than " ++
                "answered twice",
            .{},
        );
        return;
    };

    const allocator = std.heap.c_allocator;

    // Swift's `"Failed to process image"` branch is every failure here: a nil
    // image, a JPEG encode that returned nothing, a reply that would not shape.
    const json: ?[]u8 = buildPhotoReply(info, answering.work, allocator) catch |err| shaped: {
        std.log.err(
            "{s}: could not build the reply for the picked image ({}); rejecting rather " ++
                "than replying with an image that was not encoded",
            .{ answering.source.actionName(), err },
        );
        break :shaped null;
    };
    defer if (json) |owned| allocator.free(owned);

    settle(answering, finishAnswer(json));
}

/// Read the pick and shape it, or fail. Split from the callback so the
/// callback has exactly one reply site.
fn buildPhotoReply(info: Id, work: Work, allocator: std.mem.Allocator) ![]u8 {
    const photo = try readPhoto(info, work, allocator);
    defer allocator.free(photo.base64);
    return shapePhoto(allocator, photo);
}

/// `-imagePickerControllerDidCancel:`
fn craftIOSImagePickerDidCancel(_: Id, _: Id, picker: Id) callconv(.c) void {
    if (!is_darwin) return;

    const call = takePending();
    dismissPresented(picker, if (call) |c| c.work.sels.dismiss else null);

    const answering = call orelse {
        std.log.info("image picker: a cancel arrived with no call waiting; ignored", .{});
        return;
    };

    // A rejection, per `cancel_answer`. The code it carries is
    // `NATIVE_CALL_FAILED` and not Swift's `"Cancelled"`, because
    // `ios_async.deliverError` has no way to name an error — see the module
    // comment, which is the only place that says so.
    settle(answering, cancel_answer);
}

/// `-presentationControllerDidDismiss:` — the swipe-down belt.
///
/// Nothing is dismissed here: UIKit has already taken the sheet off the
/// screen, which is precisely what this callback reports. Sending
/// `dismissViewControllerAnimated:` now could take down whatever the presenter
/// shows next instead.
fn craftIOSImagePickerDidDismiss(_: Id, _: Id, _: Id) callconv(.c) void {
    if (!is_darwin) return;

    // Empty is the ordinary case: a real cancel or a real pick already took it.
    const answering = takePending() orelse return;

    std.log.info(
        "{s}: the picker was dismissed interactively without a delegate callback; " ++
            "rejecting rather than leaving the call unanswered",
        .{answering.source.actionName()},
    );
    settle(answering, cancel_answer);
}

/// `[picker dismissViewControllerAnimated:YES completion:nil]`.
///
/// `resolved` is the selector captured at dispatch when there is a call to
/// answer. A stray callback has none, so it registers the selector here — that
/// is not a reply path, so a failure is loggable rather than something a
/// caller could be told about either way.
///
/// `?Id` is `??*anyopaque`, and *both* nulls have to reach the registration
/// below. The outer one is "no call was waiting, so nothing was captured"; the
/// inner one is a captured `Sels` whose `dismiss` is itself null. A single
/// `orelse` only unwraps the outer one, and would then hand `objc_msgSend` a
/// nil selector — a crash on a live picker rather than the miss this branch is
/// written for. So it is flattened first.
fn dismissPresented(picker: Id, resolved: ?Id) void {
    if (!is_darwin) return;

    const sel = flattenSelector(resolved) orelse
        (objc.sel_registerName("dismissViewControllerAnimated:completion:") orelse {
            std.log.err(
                "image picker: dismissViewControllerAnimated:completion: would not register; " ++
                    "the picker stays on screen",
                .{},
            );
            return;
        });

    const DismissFn = *const fn (Id, Id, bool, Id) callconv(.c) void;
    const dismiss: DismissFn = @ptrCast(&objc.objc_msgSend);
    dismiss(picker, sel, true, null);
}

/// Collapse `??*anyopaque` to `?*anyopaque` so one `orelse` covers both nulls.
///
/// Split out only so the collapse is assertable on a host — the bug it prevents
/// (a nil selector reaching `objc_msgSend`) has no observable form short of a
/// device crash.
fn flattenSelector(resolved: ?Id) Id {
    return if (resolved) |inner| inner else null;
}

/// `CGSize` — two `CGFloat`s, 16 bytes.
///
/// Spelled locally rather than named from `objc_runtime`, on the
/// `bridge_mobile_location.Coord` precedent, so the layout is visible at the
/// call site. Returned through the regular `objc_msgSend`: `objc_msgSend_stret`
/// is for structs larger than this and does not exist on arm64 at all.
const Size = extern struct { width: f64, height: f64 };

/// Turn the picker's info dictionary into the values the reply is built from.
///
/// The returned `base64` is owned by the caller. Every Objective-C result is
/// guarded, and each nil is a distinct error rather than a zero: Swift's
/// `else { rejectCallback(…, "Failed to process image") }` covers all of them,
/// and a plausible-looking empty photo is exactly the fabrication that must not
/// happen.
///
/// The `NSData` is autoreleased and consumed synchronously here — encoded
/// before this function returns — so no ownership is taken of it.
fn readPhoto(info: Id, work: Work, allocator: std.mem.Allocator) !Photo {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (info == null) return error.NoPickerInfo;

    const ObjectForKeyFn = *const fn (Id, Id, Id) callconv(.c) Id;
    const object_for_key: ObjectForKeyFn = @ptrCast(&objc.objc_msgSend);
    const image = object_for_key(info, work.sels.object_for_key, work.original_image_key) orelse
        return error.NoOriginalImage;

    // Read before the encode, so the dimensions describe the same UIImage the
    // bytes came from.
    const SizeFn = *const fn (Id, Id) callconv(.c) Size;
    const size_fn: SizeFn = @ptrCast(&objc.objc_msgSend);
    const size = size_fn(image, work.sels.size);

    const data = work.jpeg(image, jpeg_compression_quality) orelse return error.JpegEncodingFailed;

    const LengthFn = *const fn (Id, Id) callconv(.c) c_ulong;
    const length_fn: LengthFn = @ptrCast(&objc.objc_msgSend);
    const length: usize = @intCast(length_fn(data, work.sels.length));
    if (length == 0) return error.EmptyJpegData;

    const BytesFn = *const fn (Id, Id) callconv(.c) ?[*]const u8;
    const bytes_fn: BytesFn = @ptrCast(&objc.objc_msgSend);
    const bytes = bytes_fn(data, work.sels.bytes) orelse return error.EmptyJpegData;

    // Encoded once, in Zig, over the raw buffer. The alternative,
    // `-base64EncodedStringWithOptions:`, would allocate a multi-megabyte
    // `NSString` that then has to be copied out again; this is the one copy in
    // this path that can actually be removed.
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(length));
    errdefer allocator.free(out);
    _ = encoder.encode(out, bytes[0..length]);

    return .{ .base64 = out, .width = size.width, .height = size.height };
}

// =============================================================================
// Tests — host-only.
//
// Everything that decides page-visible bytes is pure and pinned here: routing
// in both directions, the five keys and their order, the duplicated payload,
// integral dimensions, the cancel-is-a-rejection decision, and the concurrency
// policy that is the whole reason a modal needs state at all.
//
// Nothing here presents a picker or touches UIKit. On a macOS runner
// `objc_getClass("UIImagePickerController")` is null and the test binary has no
// Info.plist, so the config gate refuses first — which is what makes the file
// safe to run. The Objective-C paths that *are* exercised for real are the ones
// with no device behind them: selector resolution and delegate registration.
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    try testing.expectEqualStrings(A.open_camera, capability_actions[0].name);
    try testing.expectEqualStrings(A.pick_image, capability_actions[1].name);

    for (capability_actions) |decl| {
        // A `.result` whose handler never replies parks the caller on an untimed
        // promise; a `.none` that is awaited resolves immediately and means
        // nothing. Swift settles both of these, so both are `.result`.
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        // `.live` with a reason would be a contradiction the manifest shows apps.
        try testing.expect(decl.reason == null);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("openCamera", A.open_camera);
    try testing.expectEqualStrings("pickImage", A.pick_image);
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
    // action the page can call and the manifest denies exists. Each declaration
    // must claim a *distinct* route — counting alone would let two rows share
    // one route while another went undeclared.
    const sources = std.enums.values(Source);
    var claimed = std.mem.zeroes([std.enums.values(Source).len]bool);

    for (capability_actions) |decl| {
        const route = routeFor(decl.name) orelse return error.DeclaredActionDoesNotRoute;
        var slot: usize = sources.len;
        for (sources, 0..) |candidate, i| {
            if (candidate == route) slot = i;
        }
        if (slot == sources.len) return error.RouteIsNotEnumerated;
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
                .{@tagName(sources[slot])},
            );
            return error.RouteNotDeclared;
        }
    }
}

test "the two actions differ only in the source type they set" {
    // The whole design of this module in two assertions. The raw values are
    // UIKit's: PhotoLibrary = 0, Camera = 1, SavedPhotosAlbum = 2 (unused).
    try testing.expectEqual(Source.camera, routeFor("openCamera").?);
    try testing.expectEqual(Source.photo_library, routeFor("pickImage").?);
    try testing.expectEqual(@as(c_long, 1), @backingInt(Source.camera));
    try testing.expectEqual(@as(c_long, 0), @backingInt(Source.photo_library));

    // And each knows its own name back, because every log line and every
    // `ios_async.acquire` is keyed on it — a swap here would correlate a reply
    // to the wrong action.
    try testing.expectEqualStrings(A.open_camera, Source.camera.actionName());
    try testing.expectEqualStrings(A.pick_image, Source.photo_library.actionName());
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = ImagePickerBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );

    // Casing is how a real typo arrives, and a miss does not fail loudly:
    // `ios_dispatch` reads UnknownAction as "not mine" and hands the action to
    // the Swift shim, so a typo silently keeps the old implementation.
    for ([_][]const u8{ "opencamera", "OpenCamera", "pickimage", "PickImage" }) |typo| {
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(typo, "{}"),
        );
    }

    // The neighbours that share Swift's Coordinator delegate but are not this
    // module's. Two modules answering one action would make `ios_dispatch`'s
    // first-match routing order-dependent — and `startVideoRecording` in
    // particular must keep reaching the shim, whose delegate crosstalk this
    // module exists partly to avoid inheriting.
    for ([_][]const u8{
        "startVideoRecording",
        "stopVideoRecording",
        "takeScreenshot",
        "share",
    }) |action| {
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(action, "{}"),
        );
    }
}

// -----------------------------------------------------------------------------
// Reply shaping.
// -----------------------------------------------------------------------------

/// A JSON number as an `f64`, whatever variant `std.json` chose for it. The
/// variant is a property of the *bytes*: `{d}` renders 3024 as the integer
/// token `3024` (`.integer`) and 3024.5 as `3024.5` (`.float`), so reading
/// `.float` directly would panic on the first.
fn numberOf(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |text| try std.fmt.parseFloat(f64, text),
        else => error.ReplyFieldIsNotANumber,
    };
}

test "the reply is the five-key object Swift resolves, in a fixed order" {
    const json = try shapePhoto(testing.allocator, .{
        .base64 = "aGVsbG8=",
        .width = 3024,
        .height = 4032,
    });
    defer testing.allocator.free(json);

    // The exact bytes, because the shape is the contract and `PhotoResult`
    // names all five keys. Integral dimensions carry no fraction: Swift's
    // `JSONSerialization` writes `3024` for the same CGFloat, and `{d}` agrees.
    try testing.expectEqualStrings(
        "{\"base64\":\"aGVsbG8=\"," ++
            "\"uri\":\"data:image/jpeg;base64,aGVsbG8=\"," ++
            "\"width\":3024,\"height\":4032," ++
            "\"mimeType\":\"image/jpeg\"}",
        json,
    );

    // And it really parses as the object the page consumes, rather than merely
    // looking like one.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(usize, 5), obj.count());
    try testing.expectEqualStrings("aGVsbG8=", obj.get("base64").?.string);
    try testing.expectEqualStrings("image/jpeg", obj.get("mimeType").?.string);
    try testing.expectEqual(@as(f64, 3024), try numberOf(obj.get("width").?));
    try testing.expectEqual(@as(f64, 4032), try numberOf(obj.get("height").?));
}

test "the payload is carried twice, raw in base64 and prefixed in uri" {
    // The duplication is the contract, not an oversight: `normalizePhoto`
    // passes the object straight through and the SDK's `PhotoResult` reads both
    // fields. A `uri` that merely repeated `base64` without the prefix, or a
    // `base64` that carried the prefix, would each break one consumer.
    const payload = "QUJDREVGRw==";
    const json = try shapePhoto(testing.allocator, .{
        .base64 = payload,
        .width = 1,
        .height = 1,
    });
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const base64 = parsed.value.object.get("base64").?.string;
    const uri = parsed.value.object.get("uri").?.string;

    try testing.expectEqualStrings(payload, base64);
    try testing.expectEqualStrings(data_uri_prefix ++ payload, uri);
    try testing.expect(std.mem.startsWith(u8, uri, "data:image/jpeg;base64,"));
    try testing.expect(!std.mem.startsWith(u8, base64, "data:"));
}

test "the mime type is the JPEG literal for both actions, whatever was picked" {
    // The image is re-encoded at `jpeg_compression_quality`, so a PNG or HEIC
    // chosen from the library still arrives as JPEG. Sniffing the original
    // type and reporting it would be a different, and wrong, contract.
    try testing.expectEqualStrings("image/jpeg", mime_type);
    try testing.expectEqual(@as(f64, 0.8), jpeg_compression_quality);
}

test "a fractional dimension keeps its fraction rather than being rounded" {
    // `UIImage.size` is in points and is a CGFloat, so a scaled or cropped
    // image can be fractional. Truncating would report a size the image does
    // not have.
    const json = try shapePhoto(testing.allocator, .{
        .base64 = "",
        .width = 375.5,
        .height = 812.25,
    });
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(f64, 375.5), try numberOf(parsed.value.object.get("width").?));
    try testing.expectEqual(@as(f64, 812.25), try numberOf(parsed.value.object.get("height").?));
}

test "a non-finite dimension is refused rather than printed" {
    // `inf` and `nan` are not JSON. Printing them would put a bare `inf` inside
    // the reply script and turn the whole `__craftBridgeResult` call into a
    // syntax error in the page, with nothing to point at.
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |bad| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            shapePhoto(testing.allocator, .{ .base64 = "", .width = bad, .height = 1 }),
        );
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            shapePhoto(testing.allocator, .{ .base64 = "", .width = 1, .height = bad }),
        );
    }
}

test "the encoded payload needs no JSON escaping" {
    // `shapePhoto` appends the payload straight into a JSON string, which is
    // only safe because of what the encoder can emit. Checked rather than
    // asserted in a comment: if the encoder is ever swapped for one with a
    // different alphabet — url-safe uses `-` and `_`, which are also fine, but
    // a future one might not be — this fails here rather than on a device with
    // a reply the page cannot parse.
    const encoder = std.base64.standard.Encoder;
    for (std.base64.standard_alphabet_chars) |c| {
        try testing.expect(c != '"' and c != '\\' and c >= 0x20);
    }
    try testing.expect(encoder.pad_char != null);
    const pad = encoder.pad_char.?;
    try testing.expect(pad != '"' and pad != '\\' and pad >= 0x20);
}

test "a real encode round-trips into a reply the page can parse" {
    // The bytes chosen include 0xFF 0xD8 0xFF, a real JPEG SOI, and a run that
    // forces padding — the two things that make an encoder's output visibly
    // wrong if the length arithmetic is off.
    const raw = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F' };
    const encoder = std.base64.standard.Encoder;

    const encoded = try testing.allocator.alloc(u8, encoder.calcSize(raw.len));
    defer testing.allocator.free(encoded);
    _ = encoder.encode(encoded, &raw);

    const json = try shapePhoto(testing.allocator, .{
        .base64 = encoded,
        .width = 10,
        .height = 10,
    });
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const decoder = std.base64.standard.Decoder;
    const field = parsed.value.object.get("base64").?.string;
    const back = try testing.allocator.alloc(u8, try decoder.calcSizeForSlice(field));
    defer testing.allocator.free(back);
    try decoder.decode(back, field);
    try testing.expectEqualSlices(u8, &raw, back);
}

// -----------------------------------------------------------------------------
// Which callback resolves and which rejects.
// -----------------------------------------------------------------------------

test "a cancel rejects rather than resolving anything" {
    // The single most important shape in this file. `craft-bridge.js` resolves
    // with `payload || {}`, so a `null`, `false` or `{}` result for a cancel
    // would run the app's `then` branch — `normalizePhoto` would even hand it a
    // well-formed `PhotoResult` with an empty payload — for a picture the user
    // declined to take. Swift rejects; so does this.
    try testing.expect(cancel_answer == .reject);
    try testing.expect(cancel_answer != .photo);
}

test "an image that will not encode rejects, and only a complete one resolves" {
    // Swift's `if let image = …, let imageData = …` — both halves required,
    // either one missing is `"Failed to process image"`. A reply built from a
    // missing half would be `{"base64":"","width":0,"height":0,…}`, which is
    // indistinguishable from a real photo of nothing, and `normalizePhoto`
    // would pass it straight through to the app's `then`.
    try testing.expect(finishAnswer(null) == .reject);

    const shaped = "{\"base64\":\"\",\"uri\":\"data:image/jpeg;base64,\",\"width\":1,\"height\":1,\"mimeType\":\"image/jpeg\"}";
    switch (finishAnswer(shaped)) {
        .photo => |json| try testing.expectEqualStrings(shaped, json),
        .reject => return error.AShapedReplyWasRejected,
    }
}

// -----------------------------------------------------------------------------
// One picker, one caller.
// -----------------------------------------------------------------------------

/// A `Work` with nothing resolved. Safe in these tests because none of them
/// reaches a delegate callback — they exercise the slot, not the picker.
const empty_work = Work{
    .sels = .{
        .object_for_key = null,
        .size = null,
        .bytes = null,
        .length = null,
        .dismiss = null,
    },
    .original_image_key = null,
    .jpeg = &noopJpeg,
};

fn noopJpeg(_: Id, _: f64) callconv(.c) Id {
    return null;
}

test "the slot hands the delegate its ticket once, and clearing it frees the picker" {
    _ = takePending();

    const ticket = ios_async.Ticket{ .index = 6, .generation = 17 };
    try testing.expect(publish(.{ .ticket = ticket, .source = .camera, .work = empty_work }) == .published);

    const taken = takePending() orelse return error.PublishedCallWentMissing;
    try testing.expectEqual(@as(u5, 6), taken.ticket.index);
    try testing.expectEqual(@as(u32, 17), taken.ticket.generation);
    try testing.expectEqual(Source.camera, taken.source);

    // Taken means gone: a double-firing delegate must not reply twice, and the
    // next caller must find the picker free.
    try testing.expect(takePending() == null);
    try testing.expect(busyWith() == null);
}

test "a second request while a picker is presented is refused, and the first is untouched" {
    // The concurrency policy, and the one place it deliberately differs from
    // `bridge_mobile_location`: there the framework cancels the earlier request
    // so the displaced caller *must* be rejected; here the first picker is
    // still on screen and will answer, so replacing it would strand a promise
    // that was about to settle.
    _ = takePending();

    const first = ios_async.Ticket{ .index = 2, .generation = 3 };
    const second = ios_async.Ticket{ .index = 9, .generation = 4 };

    try testing.expect(publish(.{ .ticket = first, .source = .camera, .work = empty_work }) == .published);

    // The refusal names who is holding it, and it is the *second* caller that
    // is refused.
    const refused = publish(.{ .ticket = second, .source = .photo_library, .work = empty_work });
    switch (refused) {
        .published => return error.SecondRequestSilentlyReplacedTheFirst,
        .busy => |holder| try testing.expectEqual(Source.camera, holder),
    }
    try testing.expectEqual(Source.camera, busyWith().?);

    // And it is a rejection the caller can see, never silence.
    try testing.expectEqual(
        bridge_error.BridgeError.InvalidParameter,
        busyRefusal(A.pick_image, .camera),
    );

    // The survivor is the first, unchanged — the whole point.
    const survivor = takePending() orelse return error.FirstCallWasDropped;
    try testing.expectEqual(@as(u5, 2), survivor.ticket.index);
    try testing.expectEqual(@as(u32, 3), survivor.ticket.generation);
    try testing.expectEqual(Source.camera, survivor.source);

    // With the picker free, the next caller is admitted.
    try testing.expect(publish(.{ .ticket = second, .source = .photo_library, .work = empty_work }) == .published);
    _ = takePending();
}

test "a delegate callback with no call recorded touches no slot" {
    // A late or duplicate fire must not reach `deliverJson`/`deliverError` at
    // all. With the slot empty there is no ticket to reply with, and all three
    // methods return without touching the pool — asserted by the slot staying
    // empty rather than by observing a reply that must not happen.
    _ = takePending();

    craftIOSImagePickerDidFinish(null, null, null, null);
    try testing.expect(takePending() == null);

    craftIOSImagePickerDidCancel(null, null, null);
    try testing.expect(takePending() == null);

    craftIOSImagePickerDidDismiss(null, null, null);
    try testing.expect(takePending() == null);

    try testing.expect(busyWith() == null);
}

test "the pool refusal is an error the caller sees, not a dropped call" {
    try testing.expectEqual(
        bridge_error.BridgeError.InvalidParameter,
        poolFull(A.open_camera),
    );
}

// -----------------------------------------------------------------------------
// Platform and gate.
// -----------------------------------------------------------------------------

test "off Darwin the handler refuses rather than pretending to present" {
    if (is_darwin) return error.SkipZigTest;

    var bridge = ImagePickerBridge.init(testing.allocator);
    defer bridge.deinit();

    for ([_][]const u8{ A.open_camera, A.pick_image }) |action| {
        try testing.expectError(error.UnsupportedPlatform, bridge.handleMessage(action, "{}"));
    }
    try testing.expectError(error.UnsupportedPlatform, requireConfigured(.camera));
    try testing.expectError(error.UnsupportedPlatform, requireConfigured(.photo_library));
    try testing.expectError(error.UnsupportedPlatform, Sels.resolve());
    try testing.expectError(error.UnsupportedPlatform, Work.resolve());
    try testing.expectError(error.UnsupportedPlatform, ensureDelegate());
}

test "without the usage descriptions the gate refuses before any picker exists" {
    if (!is_darwin) return error.SkipZigTest;

    // The host runner is a bare binary with no Info.plist, which is exactly the
    // "this app was not built with the camera enabled" case the gate is for. It
    // is also what keeps this file safe to run: everything past the gate would
    // look for UIKit, and on a runner that had it, present a real picker.
    if (requireConfigured(.photo_library)) |_| {
        // A runner that does carry the key (tests hosted inside a real app)
        // would take the live path below, so skip rather than present.
        return error.SkipZigTest;
    } else |err| switch (err) {
        bridge_error.BridgeError.PermissionDenied => {
            var bridge = ImagePickerBridge.init(testing.allocator);
            defer bridge.deinit();

            for ([_][]const u8{ A.open_camera, A.pick_image }) |action| {
                try testing.expectError(
                    bridge_error.BridgeError.PermissionDenied,
                    bridge.handleMessage(action, "{}"),
                );
            }

            // The refusal happens before a slot is leased and before anything
            // is published: an unreleased lease narrows the pool for every
            // later call, and a published call with no picker behind it would
            // refuse every request for the life of the process.
            try testing.expect(takePending() == null);
            try testing.expect(busyWith() == null);
        },
        else => return err,
    }
}

test "the payload is ignored, not parsed" {
    if (!is_darwin) return error.SkipZigTest;
    // Real dispatches, so this needs the process the gate stops.
    if (requireConfigured(.photo_library)) |_| return error.SkipZigTest else |_| {}

    // Both injected methods are declared `function()` and the Swift dispatcher
    // reads nothing out of `body`, so a payload that is not even JSON must
    // reach exactly the same outcome as `{}`. If it did not, this module would
    // have invented a failure the shim does not have.
    var bridge = ImagePickerBridge.init(testing.allocator);
    defer bridge.deinit();

    for ([_][]const u8{ A.open_camera, A.pick_image }) |action| {
        const empty = bridge.handleMessage(action, "{}");
        const junk = bridge.handleMessage(action, "{not json");
        const missing = bridge.handleMessage(action, "");
        // The options the SDK types but the page never sends.
        const options = bridge.handleMessage(
            action,
            "{\"quality\":0.5,\"maxWidth\":1024,\"camera\":\"front\",\"allowsEditing\":true}",
        );

        try testing.expectEqual(empty, junk);
        try testing.expectEqual(empty, missing);
        try testing.expectEqual(empty, options);

        if (empty) |_| {} else |err| {
            try testing.expect(err != bridge_error.BridgeError.InvalidJSON);
            try testing.expect(err != bridge_error.BridgeError.MissingData);
        }
    }

    try testing.expect(takePending() == null);
}

test "every selector the delegate needs resolves on a real runtime" {
    if (!is_darwin) return error.SkipZigTest;

    // `sel_registerName` interns a name whether or not any class implements it,
    // so this touches no framework and presents nothing. What it catches is a
    // typo in one of the five spellings, which would otherwise surface as a
    // rejected pick — or a picker that cannot be dismissed — on a device.
    const sels = try Sels.resolve();
    inline for (comptime std.meta.fieldNames(Sels)) |name| {
        if (@field(sels, name) == null) {
            std.debug.print("selector for Sels.{s} did not resolve\n", .{name});
            return error.SelectorDidNotResolve;
        }
    }

    // Distinct, or two different reads would come from one property.
    try testing.expect(sels.bytes != sels.length);
    try testing.expect(sels.size != sels.object_for_key);
    try testing.expect(sels.dismiss != sels.size);
}

test "the delegate class registers under its own name, idempotently" {
    if (!is_darwin) return error.SkipZigTest;

    // No UIKit is involved: this allocates an NSObject subclass and one
    // instance. It is the load-bearing half of the delegate — a class that does
    // not register, or that adopts another module's IMPs, is a picker that
    // never answers.
    const first = try ensureDelegate();
    const second = try ensureDelegate();

    // The same live instance, not merely two non-null answers: the instance is
    // the strong reference `UIImagePickerController`'s weak `delegate` depends
    // on, and a second one would leave the first free to be released.
    try testing.expectEqual(first, second);

    const cls = objc.object_getClass(first) orelse return error.DelegateHasNoClass;
    try testing.expectEqualStrings(delegate_class_name, std.mem.span(objc.class_getName(cls)));

    // All three methods attached. UIKit dispatches through
    // `respondsToSelector:`, so a method that failed to attach is a callback
    // that is simply never made — silence, on an untimed promise.
    const sel_responds = objc.sel_registerName("respondsToSelector:") orelse
        return error.SelectorNotFound;
    const RespondsFn = *const fn (Id, Id, Id) callconv(.c) bool;
    const responds: RespondsFn = @ptrCast(&objc.objc_msgSend);

    for (delegateMethods()) |method| {
        const sel = objc.sel_registerName(method.selector.ptr) orelse return error.SelectorNotFound;
        if (!responds(first, sel_responds, sel)) {
            std.debug.print("the delegate does not respond to {s}\n", .{method.selector});
            return error.DelegateMissingMethod;
        }
    }
}

test "the delegate methods carry the encodings their signatures actually have" {
    // A wrong encoding registers, dispatches, and then reads arguments out of
    // the wrong registers: no compile error, often no crash, just garbage
    // pointers. Naming them is the only defence, so the pairing is pinned.
    const methods = delegateMethods();
    try testing.expectEqual(@as(usize, 3), methods.len);

    try testing.expectEqualStrings(
        "imagePickerController:didFinishPickingMediaWithInfo:",
        methods[0].selector,
    );
    // Two object arguments — the picker and the info dictionary.
    try testing.expectEqualStrings("v@:@@", methods[0].types);

    try testing.expectEqualStrings(
        "imagePickerControllerDidCancel:",
        methods[1].selector,
    );
    // One object argument — the picker.
    try testing.expectEqualStrings("v@:@", methods[1].types);

    try testing.expectEqualStrings(
        "presentationControllerDidDismiss:",
        methods[2].selector,
    );
    try testing.expectEqualStrings("v@:@", methods[2].types);

    // Taken from `ios_delegate.enc` rather than spelled here, so a caller
    // cannot drift from the shared vocabulary.
    try testing.expectEqualStrings(ios_delegate.enc.void_two_objects, methods[0].types);
    try testing.expectEqualStrings(ios_delegate.enc.void_one_object, methods[1].types);
    try testing.expectEqualStrings(ios_delegate.enc.void_one_object, methods[2].types);
}

test "a captured dismiss selector that is itself null falls through to registration" {
    // `dismissPresented` takes `?Id`, which is `??*anyopaque`: the callbacks
    // build it as `if (call) |c| c.work.sels.dismiss else null`, so a stray
    // callback yields the *outer* null and a call yields `.some(selector)`.
    // Nothing stops that inner selector from being null — `empty_work` is
    // exactly that shape — and a lone `orelse` would unwrap `.some(null)` into
    // a nil selector handed straight to `objc_msgSend`, which is a crash on a
    // live picker rather than the missing-selector branch.
    const outer_null: ?Id = null;
    const inner_null: ?Id = @as(Id, null);

    // The two really are distinct values at the type level, which is the whole
    // trap: only one of them is `null` to `orelse`.
    try testing.expect(outer_null == null);
    try testing.expect(inner_null != null);
    try testing.expect(inner_null.? == null);

    // Flattened, both mean "no selector was captured".
    try testing.expect(flattenSelector(outer_null) == null);
    try testing.expect(flattenSelector(inner_null) == null);
    try testing.expect(flattenSelector(empty_work.sels.dismiss) == null);
}

test "the delegate class name cannot collide with another module's" {
    // `bridge_location.zig` registers `CraftLocationDelegate` for the desktop
    // and `bridge_mobile_location.zig` registers `CraftIOSLocationDelegate`,
    // and all of them are compiled into the same host test binary. Every one of
    // these looks its class up with `objc_getClass` first, so whichever
    // registered second would silently adopt the other's IMPs.
    try testing.expectEqualStrings("CraftIOSImagePickerDelegate", delegate_class_name);
    for ([_][]const u8{
        "CraftLocationDelegate",
        "CraftIOSLocationDelegate",
        "CraftScriptMessageHandler",
    }) |taken| {
        try testing.expect(!std.mem.eql(u8, delegate_class_name, taken));
    }
}
