//! The `mobile` namespace's two file actions: `pickFile` and `saveFile`.
//!
//! They look like a pair and are not. `pickFile` presents
//! `UIDocumentPickerViewController`, so its answer arrives from a delegate
//! callback long after the dispatch frame is gone and needs an `ios_async`
//! ticket. `saveFile` presents nothing at all — it writes straight into
//! `<container>/Documents/<filename>` and resolves the path from inside the
//! dispatch. The third member of the family, `downloadFile`, is deliberately
//! left with the Swift shim; see `deliberately_unserved`.
//!
//! ## Neither action has any injected JavaScript, so the field names come from
//! ## the Swift dispatcher
//!
//! `window.craft.pickFile` and `window.craft.saveFile` **do not exist** in the
//! injected iOS bridge. `injectNativeBridge` spans `CraftApp.swift:1164`-`2426`
//! and contains no occurrence of `file` at all, and `craft-bridge.js` has no
//! `mobile` surface either (its `saveFile` is `_req('dialog','saveFile',…)` —
//! the desktop dialog namespace, a different action in a different namespace).
//! So `test-bridges.html:585` and both README examples are `TypeError`s on the
//! legacy Swift path, and the dispatcher arms are reachable only through the
//! Zig envelope `{t:"mobile", a:"pickFile"|"saveFile", d, i}`. That is a
//! pre-existing bug, the same one `bridge_mobile_motion.zig` records for
//! `startMotionUpdates`, and it is why the payload field names below are read
//! off the Swift dispatcher's own `body[...]` reads and cross-checked against
//! `craft.d.ts` and Android's `CraftBridge.kt.template` rather than off an
//! injected method that was never written.
//!
//! ## The payloads, exactly
//!
//! **`pickFile`** reads one optional field, `types`, an array of strings
//! (`CraftApp.swift:817`). Nothing else is read. Absent or null means Swift's
//! default of a single `UTTypeItem`.
//!
//! **`saveFile`** reads two required fields, `data` and `filename`
//! (`CraftApp.swift:829-831`). There is no third field: `craft.d.ts:217`
//! declares a `mimeType` parameter and the README passes one, but neither
//! Swift nor Android ever reads it. It is a type-declaration fiction, so a
//! `mimeType` in the payload is accepted and ignored rather than invented into
//! a field or turned into an error.
//!
//! ## The reply shapes, exactly
//!
//! **`pickFile` resolves an object** (`CraftApp.swift:4897-4902`):
//! `{"name":…,"path":…,"data":"data:<mime>;base64,<b64>","mimeType":…}`. The
//! `data:` URL uses the same derived MIME string, and the base64 is
//! `-[NSData base64EncodedStringWithOptions:0]` — standard alphabet, padded,
//! unwrapped. Key order is Swift's literal order; Swift's own is a `Dictionary`
//! and therefore arbitrary, so one order is fixed here to make the bytes
//! testable.
//!
//! **`pickFile` rejects on cancel.** `documentPickerWasCancelled:` calls
//! `rejectCallback(pendingCallbackId, error: "Cancelled")`
//! (`CraftApp.swift:4913`), so a cancel is a rejected promise and not a
//! distinct resolve — the opposite of the shape a picker often has, and worth
//! reading twice. An empty `urls` array is likewise a reject
//! (`"No file selected"`, `CraftApp.swift:4889`).
//!
//! **`saveFile` resolves a bare JSON string**, the written path
//! (`CraftApp.swift:3658` through `resolveCallback`'s `.fragmentsAllowed`).
//! Not an object. `craft.d.ts:217` types it `Promise<void>`, but Android agrees
//! with Swift (`file.absolutePath`), and `craft-bridge.js` settles with
//! `payload || {}` — a non-empty path survives that, and the path can never be
//! empty here, so there is no truthiness trap.
//!
//! ## The config gate Zig cannot see, and why both actions are served anyway
//!
//! Swift wraps both arms in `if config.enableFilePicker` /
//! `if config.enableFileDownload`, each defaulting to **false**
//! (`CraftApp.swift:206-207`), each with **no `else`**. So with the default
//! config the Swift path replies *nothing at all* while
//! `CraftSwiftShim.handleAction` still returns true: the page's promise never
//! settles. `ios.zig`'s `AppConfig` has no mirror of either flag, and — unlike
//! motion, where `NSMotionUsageDescription` is an exact proxy — there is no
//! Info.plist key to read instead: `renderUsageDescriptions`
//! (`packages/ios/src/index.ts:183-199`) writes nothing from either flag.
//!
//! Both are therefore served unconditionally, and an app that set
//! `enableFilePicker: false` or `enableFileDownload: false` now gets the
//! behaviour anyway. Restoring the gate means adding the fields to
//! `AppConfig`, not adding a guess here — the same trade
//! `bridge_mobile_system.zig` records word for word for `share`.
//!
//! Falling through to the shim is not the safe option it was for
//! `takeScreenshot`, because the shim does not answer these correctly today:
//! with the flag off it answers with silence, and `ios_dispatch.zig:170-174`
//! names silence as the one outcome ruled out. `.unavailable` is strictly
//! worse again — `ios_dispatch.route` only reaches the shim when every module
//! returns `UnknownAction`, so declaring it would make Zig dispatch and refuse.
//!
//! What makes serving them defensible rather than merely better-than-silence:
//! `pickFile` is user-mediated, so nothing is read without the user tapping a
//! file, and `saveFile` writes only inside the app's own container, needs no
//! OS permission and shows no UI.
//!
//! ## Five deliberate divergences from Swift
//!
//! **1. Security-scoped access is taken around the read.** Swift's
//! `documentPicker(_:didPickDocumentsAt:)` is a bare `try? Data(contentsOf: url)`
//! with no `startAccessingSecurityScopedResource` anywhere in the repo. Because
//! the picker is built with `asCopy == NO`, the URL is a security-scoped
//! reference to a document outside the container: on a device that read
//! **fails**, `try?` yields nil, and Swift falls to its degraded branch. In the
//! simulator the same read usually succeeds, which is why the bug has never
//! been noticed. This module takes the scope and releases it in a `defer`.
//! Swift does *not* do this; the claim is only about what this file does.
//!
//! **2. A file whose bytes cannot be read is rejected, not resolved.** Swift
//! resolves `{name, path}` with no `data` and no `mimeType`
//! (`CraftApp.swift:4903-4906`) — without the field its own `PickedFile` type
//! declares required and the only in-repo consumer reads
//! (`test-bridges.html:589` reads `file?.data?.length`). With the scoping fix
//! above, a failed read is a real failure, and resolving a data-less object for
//! it is fabricated-adjacent success. It is a rejection here.
//!
//! **3. An unmappable `types` entry is refused rather than dropped.** Swift's
//! `compactMap` silently discards entries it cannot map, and can therefore
//! produce an *empty* allowed-types array. Dropping a field the page sent is
//! the failure rule 2 exists for, so an entry that maps to nothing is an
//! `INVALID_PARAMETER` naming it.
//!
//! **4. `+[UTType typeWithIdentifier:]` is tried as a third fallback**, after
//! Swift's `typeWithMIMEType:` then `typeWithFilenameExtension:`. This is an
//! intentional improvement, declared rather than slipped in: Swift never tries
//! it, so a bare type identifier maps to nothing at all there. It never widens
//! past what the page asked for — an entry that names a declared identifier
//! becomes exactly that type, and one that names nothing is still refused.
//!
//! What it does *not* do is rescue the README's own documented call. Measured
//! on the host UniformTypeIdentifiers: `public.image` maps by identifier, but
//! `public.pdf` is not a declared identifier at all (the real one is
//! `com.adobe.pdf`) and maps by none of the three routes, so
//! `pickFile(['public.image','public.pdf'])` is refused by divergence 3 — where
//! Swift silently `compactMap`s both away and presents a picker with an empty
//! allowed-types array. The refusal is the honest answer; the README is what
//! needs fixing, and that is not this file's change to make.
//!
//! One measured caveat on divergence 3's reach: `typeWithFilenameExtension:`
//! answers a *dynamic* type (`dyn.…`) for an arbitrary dot-free string, so a
//! garbage entry like `"notanextension"` is accepted as that dynamic type
//! rather than refused. Nothing is fabricated — the picker simply matches no
//! file — and it is exactly what Swift's second `??` arm does too; the refusal
//! path is reached by dotted non-identifiers, which is where Swift's silent
//! drop actually bites.
//!
//! **5. `filename` is checked before it is joined.** Swift applies
//! `appendingPathComponent` to an unsanitised page-supplied string
//! (`CraftApp.swift:3645`), so `"../Library/Preferences/x.plist"` escapes
//! `Documents`. A name containing `/` or a NUL, an empty name, and the two
//! names `.` and `..` are refused here. With `/` excluded, `..` can only ever
//! be the whole name, so those four checks are exhaustive for traversal — and
//! an ordinary name like `my..notes.txt` still passes.
//!
//! And one bug that is simply not reproduced: Swift's `saveFile` reaches
//! `resolveCallback(callbackId, result: fileURL.path)` even when the data URL
//! had the wrong number of comma-separated parts or its base64 would not decode
//! (`CraftApp.swift:3651-3658` — the `if` body just never runs, nothing throws).
//! `data:text/plain,hello` triggers it: the page is told a file was written
//! where nothing was. Here both are `INVALID_PARAMETER`.
//!
//! ## Dismissal
//!
//! `UIDocumentPickerViewController` dismisses itself before calling its
//! delegate — which is why Swift's two delegate methods contain no `dismiss`
//! call, in visible contrast to the image picker, which dismisses explicitly at
//! `CraftApp.swift:2643` and `2662`. Sending an unconditional dismiss would
//! therefore be a *second* dismiss, and a second dismiss is not a no-op:
//! `-dismissViewControllerAnimated:completion:` on a controller with nothing
//! presented forwards up the presentation chain and can tear down something
//! nobody asked to close.
//!
//! So both callbacks dismiss, and both check first: `dismissPicker` reads the
//! controller's own `presentingViewController` and does nothing when it is nil
//! (already dismissed itself). When it is non-nil the picker really is still on
//! screen and is dismissed by sending the message to the picker itself, which
//! UIKit routes to its presenter. The app cannot end up parked behind a modal,
//! and nothing unrelated is dismissed either.
//!
//! ## The swipe-down belt
//!
//! A modal the delegate never hears about is the other half of the problem, and
//! it is the *page* rather than the app that pays for it. The picker is a sheet,
//! and an interactive dismissal is widely reported not to send
//! `documentPickerWasCancelled:` — the same report `bridge_mobile_imagepicker.zig`
//! and `bridge_mobile_contactpicker.zig` carry belts for, and one this repo
//! verifies on no device. Without a belt a swipe leaves `pending_pick` set
//! forever: the call is never answered (silence, which `ios_dispatch.zig:170-174`
//! rules out) **and** every later `pickFile` is refused for the life of the
//! process, which is strictly worse than Swift, where only the one promise is
//! stranded.
//!
//! `presentationControllerDidDismiss:` is that belt: it is registered on the
//! same delegate, and the picker's presentation controller is pointed at that
//! delegate before presenting and again after, so a swipe *rejects* the call
//! rather than stranding it. Belt, not fix — UIKit sends it only for a
//! user-driven dismissal, so it cannot fire after a pick or a Cancel that
//! already answered, and if the report is wrong it costs two messages. The one
//! case it does not cover is a presentation controller that already carries a
//! delegate of its own, which is left alone rather than displaced; that is
//! logged where it happens rather than assumed away.
//!
//! ## One pending pick, refused rather than replaced
//!
//! Swift keeps a single `pendingCallbackId` (`CraftApp.swift:383`) shared
//! across the camera, the image picker, the document picker, the contact
//! picker, the QR scanner, Apple Sign-In, NFC and Bluetooth, and overwrites it
//! unconditionally — so two overlapping picks strand the first promise forever.
//! A picker is modal and serves exactly one call, so this module keeps exactly
//! one pending ticket for this picker kind, under a mutex, and a second
//! `pickFile` issued while one is presented is an explicit error to the
//! *second* caller. The first ticket is never replaced.
//!
//! ## Ceilings and simulator caveats
//!
//! The whole file crosses the bridge base64-encoded inside one
//! `evaluateJavaScript` string — about 1.37 bytes of JavaScript source per byte
//! of file. Swift has exactly the same ceiling; it is noted here rather than
//! discovered on a 200 MB video.
//!
//! `UIDocumentPickerViewController` itself works in the simulator — it is not
//! camera-class hardware, so the "unavailable on simulator, must reject"
//! precedent does not apply. What the simulator lacks is content to pick, and
//! the `zig-slice` fixture cannot tap Cancel or choose a file anyway, so only
//! `pickFile`'s refusal paths are reachable from that harness. `saveFile` is
//! fully fixture-testable. Security scoping is invisible in the simulator,
//! where URLs resolve to ordinary host paths and the read succeeds without it —
//! a green simulator run proves nothing about divergence 1.
//!
//! `objc_getClass("UTType")` may be null in the Zig-only fixture:
//! `packages/ios/fixtures/zig-slice/build-and-run.sh:65` links only
//! UIKit/WebKit/Foundation/Security, while the generated app pulls
//! UniformTypeIdentifiers in through `CraftApp.swift:20`. A null class is a
//! named error with a log line naming the missing framework — never a silent
//! fallback to the `[.item]` default, which would quietly widen the file types
//! the app author asked to restrict.

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
const BridgeError = bridge_error.BridgeError;

/// The same type as `objc.id` — `?*anyopaque` — spelled locally.
///
/// `objc_runtime.objc` is an empty struct off Darwin, and a `callconv(.c)`
/// fn-pointer *type* is analysed even where a comptime platform guard makes the
/// surrounding code unreachable, so naming `objc.id` in the delegate signatures
/// below would break the host build. A single optional pointer, never
/// `?objc.id`: a double optional is illegal in a `callconv(.c)` signature.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
///
/// `test/ios_conformance_test.zig` matches this block against those labels in
/// both directions and fails the build if two modules declare one name. Keep
/// the doc comments in this block free of quoted text: the scanner takes the
/// first quoted string on every line it sees between the header and the closing
/// brace.
pub const A = struct {
    pub const pick_file = "pickFile";
    pub const save_file = "saveFile";
    pub const download_file = "downloadFile";
};

/// Nothing in this family is unserved any more.
///
/// `downloadFile` was the last entry, recorded as data so a test could hold
/// that it was neither declared nor routed. It is declared now, and the empty
/// list is kept rather than deleted so the test that walks it keeps compiling
/// and the next deferral has somewhere to go.
pub const deliberately_unserved = [_][]const u8{};

/// Both `.result`: each Swift path terminates in exactly one `resolveCallback`
/// or one `rejectCallback`, and the page awaits both. `.none` on either would
/// resolve a caller immediately with nothing.
///
/// Both `.live`: a refusal here is a specific failure — a cancelled pick, an
/// unreadable file, a filename that would escape the container, a full async
/// pool — never the action's normal answer. `.unavailable` is for an action
/// that dispatches and refuses, which neither of these is.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.pick_file, .reply = .result },
    .{ .name = A.save_file, .reply = .result },
    .{ .name = A.download_file, .reply = .result },
};

/// Which handler an action selects, split out of `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host without UIKit.
const Route = enum { pick_file, save_file, download_file };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.pick_file)) return .pick_file;
    if (std.mem.eql(u8, action, A.save_file)) return .save_file;
    if (std.mem.eql(u8, action, A.download_file)) return .download_file;
    return null;
}

pub const FilePickerBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const route = routeFor(action) orelse return BridgeError.UnknownAction;
        // Exhaustive, so a `Route` without a handler is a compile error.
        return switch (route) {
            .pick_file => self.pickFile(data),
            .save_file => self.saveFile(data),
            .download_file => self.downloadFile(data),
        };
    }

    /// Present the document picker and answer when the user has chosen or
    /// cancelled.
    ///
    /// Every fallible step runs *before* `ios_async.acquire`, and the only
    /// thing between publishing the ticket and presenting is the presentation
    /// itself. A failure after the lease would have to release the slot by
    /// hand, and a missed release is a permanently narrower pool.
    fn pickFile(self: *Self, data: []const u8) !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        const request = try parsePickRequest(self.allocator, data);
        defer request.deinit(self.allocator);

        // Guarded once, here, for both uses below: the default `public.item`
        // and every mapped entry need this class. A null answer means the
        // process has no UniformTypeIdentifiers — the fixture's link line — and
        // that is an error, never a silent fall back to the default, which
        // would widen the types the app author asked to restrict.
        const UTTypeClass = objc.objc_getClass("UTType") orelse {
            std.log.err(
                "pickFile: this process has no UTType class, so no content type can be " ++
                    "built; the app or fixture needs -framework UniformTypeIdentifiers",
                .{},
            );
            return BridgeError.NativeCallFailed;
        };

        const content_types = try buildContentTypes(self.allocator, request, UTTypeClass);
        const delegate = try ensureDelegate();

        const PickerClass = objc.objc_getClass("UIDocumentPickerViewController") orelse
            return error.ClassNotFound;

        // `initForOpeningContentTypes:` — the one-argument iOS 14+ form, which
        // is what Swift's single-label call binds to, i.e. `asCopy == NO`.
        // Deployment target is 16.0, so its availability is unconditional. The
        // deprecated `initWithDocumentTypes:inMode:` is not used.
        const sel_init = try selector("initForOpeningContentTypes:");
        const sel_set_delegate = try selector("setDelegate:");
        const sel_set_multi = try selector("setAllowsMultipleSelection:");
        const sel_present = try selector("presentViewController:animated:completion:");
        // The swipe-down belt's reads, resolved here with everything else so a
        // missing selector fails the call rather than silently leaving the only
        // thing that answers an interactive dismissal unattached.
        const dismiss_sels = DismissSels{
            .presentation = try selector("presentationController"),
            .delegate = try selector("delegate"),
            .set_delegate = sel_set_delegate,
        };

        const allocated = try objc.alloc(PickerClass);
        const InitFn = *const fn (Id, Id, Id) callconv(.c) Id;
        const init_fn: InitFn = @ptrCast(&objc.objc_msgSend);
        const picker = init_fn(allocated, sel_init, content_types) orelse
            return error.NativeCallFailed;
        // `alloc` gave us +1 and `init` consumed it. The presenter retains the
        // picker for the life of the presentation, so ours is the reference to
        // drop — and on the refusal paths below it is the only one there is.
        defer objc.release(picker);

        // The picker holds its delegate **weakly** (`UIDocumentPickerViewController.h:65`),
        // which is why `delegate_instance` is a module-level var rather than a
        // local: dropping it would be a use-after-free the first time the user
        // taps Cancel.
        objc.msgSendVoid1(picker, sel_set_delegate, delegate);

        const SetBoolFn = *const fn (Id, Id, bool) callconv(.c) void;
        const set_bool: SetBoolFn = @ptrCast(&objc.objc_msgSend);
        // Swift sets this explicitly at `CraftApp.swift:3603` even though false
        // is the default, and the reply shape has room for exactly one file.
        set_bool(picker, sel_set_multi, false);

        // Swift presents on `windowScene.windows.first?.rootViewController`
        // (`CraftApp.swift:3594`), which logs "which is already presenting" and
        // silently does nothing when anything else is up — leaving the promise
        // unsettled. This walks `presentedViewController` from the webview's own
        // window instead. A declared deviation, and strictly the more correct
        // one. No `anchorPopover` call: the picker's default presentation style
        // is a form/page sheet, so `popoverPresentationController` is nil and
        // there is nothing to anchor — unlike `UIActivityViewController`, which
        // traps without one.
        const presenter = try bridge_mobile_system.uikit.topmostViewController();

        // Attached before presenting, because that is when a presentation
        // controller can already exist, and retried after `presentViewController:`
        // for the case where UIKit only builds one there. Infallible either way:
        // it reports whether it took and never fails the call.
        var dismiss_observed = attachDismissObserver(picker, delegate, dismiss_sels);

        const ticket = ios_async.acquire(A.pick_file) orelse return poolFull();

        // Published before the framework call, never after: the delegate can in
        // principle be reached before `present` returns, and a callback that
        // arrived at an empty slot would have no ticket to reply with.
        if (!publishPendingPick(ticket)) {
            // Swift overwrites its one `pendingCallbackId` here and the first
            // caller's promise never settles. The second caller is refused
            // instead; the first keeps the picker and its ticket.
            ios_async.abandon(ticket);
            std.log.warn(
                "pickFile refused: a document picker is already presented and owns the " ++
                    "pending reply; refusing the second call rather than stranding the first",
                .{},
            );
            return BridgeError.InvalidParameter;
        }

        const PresentFn = *const fn (Id, Id, Id, bool, Id) callconv(.c) void;
        const present_fn: PresentFn = @ptrCast(&objc.objc_msgSend);
        present_fn(presenter, sel_present, picker, true, null);

        if (!dismiss_observed) dismiss_observed = attachDismissObserver(picker, delegate, dismiss_sels);
        if (!dismiss_observed) {
            std.log.warn(
                "pickFile: the picker's presentation controller could not be observed " ++
                    "(absent, or already carrying a delegate this file will not displace); " ++
                    "if a swipe-down dismissal does not send documentPickerWasCancelled: " ++
                    "then this call stays unanswered and every later one is refused",
                .{},
            );
        }
    }

    /// Write `data` into `<container>/Documents/<filename>` and resolve the
    /// path.
    ///
    /// Fully synchronous: Swift presents nothing here — no export-mode picker,
    /// no temp file, no delegate — so there is no `ios_async` ticket and the
    /// reply goes out from inside the dispatch frame that holds the request id.
    fn saveFile(self: *Self, data: []const u8) !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return BridgeError.InvalidJSON;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return BridgeError.InvalidJSON,
        };

        const request = try parseSaveRequest(root);

        const bytes = try decodeSaveBytes(self.allocator, request.data);
        defer self.allocator.free(bytes);

        const directory = try documentsPath(self.allocator);
        defer self.allocator.free(directory);

        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ directory, request.filename },
        );
        defer self.allocator.free(path);

        try writeFileAtomically(self.allocator, path, bytes);

        const json = try shapeSavedPath(self.allocator, path);
        defer self.allocator.free(json);

        bridge_error.sendResultToJS(self.allocator, A.save_file, json);
    }

    /// Fetch a URL and land it in Documents under `filename`.
    ///
    /// The third action of this family, and the last one it was missing. The
    /// module recorded it as "out of scope for this round"; nothing structural
    /// stood in the way, only a completion shape — `void (^)(NSURL *,
    /// NSURLResponse *, NSError *)` — that no pooled block covers.
    ///
    /// Two divergences from Swift, both deliberate:
    ///
    ///  - **The filename is validated.** `saveFile` already refuses a name
    ///    carrying `/` or a NUL, because `appendingPathComponent` on
    ///    `"../Library/Preferences/x.plist"` escapes the container. Swift's
    ///    `downloadFile` runs the same `appendingPathComponent` with no such
    ///    check, so the same escape is available through the download path
    ///    today. Guarding one entrance and not the other is not a guard.
    ///  - **The error text is a code.** Swift rejects with
    ///    `error.localizedDescription`; the protocol carries no message field,
    ///    so the description goes to the log and the page gets
    ///    `NATIVE_CALL_FAILED`.
    fn downloadFile(self: *Self, data: []const u8) !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return BridgeError.InvalidJSON;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return BridgeError.InvalidJSON,
        };

        const url_text = try downloadField(root, "url");
        const filename = try downloadField(root, "filename");
        try validateFilename(filename);

        const url = objc.createNSURL(url_text, self.allocator) catch return BridgeError.AllocationFailed;
        if (url == null) {
            // Swift's `guard let downloadURL = URL(string: url)`.
            std.log.warn("downloadFile refused: the url did not parse", .{});
            return BridgeError.InvalidParameter;
        }

        const NSURLSession = objc.objc_getClass("NSURLSession") orelse return error.ClassNotFound;
        const sel_shared = try selector("sharedSession");
        const session = objc.msgSendId(NSURLSession, sel_shared) orelse return error.NativeCallFailed;

        const owned_filename = std.heap.c_allocator.dupe(u8, filename) catch
            return BridgeError.AllocationFailed;
        errdefer std.heap.c_allocator.free(owned_filename);

        const ticket = ios_async.acquire(A.download_file) orelse {
            std.log.warn(
                "downloadFile: no free reply slot; {d} native calls are already awaiting one",
                .{ios_async.max_in_flight},
            );
            return BridgeError.NativeCallFailed;
        };
        errdefer ios_async.abandon(ticket);

        publishDownload(ticket, owned_filename);

        const sel_task = try selector("downloadTaskWithURL:completionHandler:");
        const TaskFn = *const fn (Id, Id, Id, *anyopaque) callconv(.c) Id;
        const taskFn: TaskFn = @ptrCast(&objc.objc_msgSend);
        const task = taskFn(session, sel_task, url, @ptrCast(&download_blocks[ticket.index])) orelse {
            _ = takeDownload(ticket.index);
            return error.NativeCallFailed;
        };

        const sel_resume = try selector("resume");
        objc.msgSend(task, sel_resume);
    }
};

/// The answer for a full block pool, in the shape `bridge_mobile_location.zig`
/// uses: `BridgeError` has no "Busy", `INVALID_PARAMETER` is the migration
/// notes' designated stand-in, and the point is that the seventeenth concurrent
/// call gets an explicit rejection instead of a promise that never settles.
fn poolFull() BridgeError {
    std.log.warn("pickFile refused: all {d} async slots in flight", .{ios_async.max_in_flight});
    return BridgeError.InvalidParameter;
}

fn selector(name: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.sel_registerName(name) orelse error.SelectorNotFound;
}

// =============================================================================
// Payload parsing. Pure — no Objective-C — so every field the page can send is
// driven by host tests on every platform.
// =============================================================================

/// What `pickFile` read out of the payload.
const PickRequest = struct {
    /// Null when the page sent no `types`, or sent null — Swift's `[.item]`
    /// default. Never an empty slice: an empty `types` array is refused at
    /// parse, so `buildContentTypes` can rely on having at least one entry.
    types: ?[][]const u8,

    fn deinit(self: PickRequest, allocator: std.mem.Allocator) void {
        const list = self.types orelse return;
        for (list) |entry| allocator.free(entry);
        allocator.free(list);
    }
};

/// `types`, and nothing else — Swift reads no other key out of `body` for this
/// action, and inventing one would create a way for the call to fail that the
/// shim does not have.
///
/// The entries are copied because the caller frees the parsed JSON before the
/// picker is built.
fn parsePickRequest(allocator: std.mem.Allocator, data: []const u8) !PickRequest {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return BridgeError.InvalidJSON,
    };

    const value = root.get("types") orelse return .{ .types = null };
    const array = switch (value) {
        // `body["types"] as? [String]` yields nil for JSON null, and nil is
        // exactly the default case.
        .null => return .{ .types = null },
        .array => |items| items,
        else => {
            std.log.warn("pickFile refused: types is present but is not an array", .{});
            return BridgeError.InvalidParameter;
        },
    };

    if (array.items.len == 0) {
        // What `initForOpeningContentTypes:` does with an empty array is not
        // documented and was not verified, and Swift can reach it by way of a
        // `compactMap` that dropped everything. Refusing beats presenting a
        // picker whose behaviour nobody has established.
        std.log.warn("pickFile refused: types is an empty array", .{});
        return BridgeError.InvalidParameter;
    }

    var list = try allocator.alloc([]const u8, array.items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |entry| allocator.free(entry);
        allocator.free(list);
    }

    for (array.items) |item| {
        const text = switch (item) {
            .string => |s| s,
            else => {
                std.log.warn("pickFile refused: types contains a non-string entry", .{});
                return BridgeError.InvalidParameter;
            },
        };
        list[filled] = try allocator.dupe(u8, text);
        filled += 1;
    }

    return .{ .types = list };
}

/// What `saveFile` read out of the payload. Both slices borrow the parsed JSON,
/// which the caller keeps alive for the whole write.
const SaveRequest = struct {
    data: []const u8,
    filename: []const u8,
};

/// `data` and `filename`, both required, and deliberately no third field.
///
/// A `mimeType` in the payload is neither read nor refused: `craft.d.ts` and the
/// README pass one, Swift and Android both ignore it, and erroring on it would
/// break the documented call for a field that has never meant anything.
fn parseSaveRequest(root: std.json.ObjectMap) !SaveRequest {
    const data_value = root.get("data") orelse {
        std.log.warn("saveFile refused: no data field", .{});
        return BridgeError.MissingData;
    };
    const filename_value = root.get("filename") orelse {
        std.log.warn("saveFile refused: no filename field", .{});
        return BridgeError.MissingData;
    };

    const data = switch (data_value) {
        .string => |s| s,
        else => {
            std.log.warn("saveFile refused: data is not a string", .{});
            return BridgeError.InvalidParameter;
        },
    };
    const filename = switch (filename_value) {
        .string => |s| s,
        else => {
            std.log.warn("saveFile refused: filename is not a string", .{});
            return BridgeError.InvalidParameter;
        },
    };

    try validateFilename(filename);

    return .{ .data = data, .filename = filename };
}

/// Refuse a `filename` that would name a file outside `Documents`.
///
/// Swift joins the page's string straight on with `appendingPathComponent`, so
/// `"../Library/Preferences/x.plist"` escapes the directory. Four checks, and
/// with `/` excluded they are exhaustive for traversal: a `..` component can
/// then only be the entire name. An ordinary name that merely contains two dots
/// — `my..notes.txt` — is not refused, because it names nothing but itself.
fn validateFilename(filename: []const u8) BridgeError!void {
    if (filename.len == 0) {
        std.log.warn("saveFile refused: filename is empty", .{});
        return BridgeError.InvalidParameter;
    }
    if (std.mem.indexOfScalar(u8, filename, '/') != null) {
        std.log.warn("saveFile refused: filename contains a path separator", .{});
        return BridgeError.InvalidParameter;
    }
    if (std.mem.indexOfScalar(u8, filename, 0) != null) {
        // A NUL would truncate the C string every native path API sees, so the
        // file written would not be the file named.
        std.log.warn("saveFile refused: filename contains a NUL byte", .{});
        return BridgeError.InvalidParameter;
    }
    if (std.mem.eql(u8, filename, ".") or std.mem.eql(u8, filename, "..")) {
        std.log.warn("saveFile refused: filename is a directory reference", .{});
        return BridgeError.InvalidParameter;
    }
}

/// The `data:` prefix Swift tests with `hasPrefix`.
const data_url_prefix = "data:";

/// The bytes `saveFile` writes, decoded the way Swift decodes them — minus
/// Swift's two silent no-write paths.
///
/// `data:` prefixed: Swift splits on every `","` and requires exactly two parts,
/// then base64-decodes the second. Both of those can fail, and when either does
/// Swift writes nothing and *still resolves the path* — the page is told a file
/// exists where nothing was written, or where a stale earlier file still sits.
/// Both are `INVALID_PARAMETER` here.
///
/// Not `data:` prefixed: the string is written as UTF-8 text, which for bytes
/// already in hand is a copy. Both branches therefore reduce to "write these
/// bytes", which is why there is one write path below and not two.
///
/// `std.base64.standard.Decoder` has the same strictness as
/// `Data(base64Encoded:)` with default options: standard alphabet, padding
/// required, no non-alphabet characters tolerated.
fn decodeSaveBytes(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, data, data_url_prefix)) {
        return allocator.dupe(u8, data);
    }

    if (std.mem.count(u8, data, ",") != 1) {
        std.log.warn(
            "saveFile refused: the data URL does not split into exactly two comma-separated " ++
                "parts, so there is nothing to decode",
            .{},
        );
        return BridgeError.InvalidParameter;
    }

    const comma = std.mem.indexOfScalar(u8, data, ',').?;
    const encoded = data[comma + 1 ..];

    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch {
        std.log.warn("saveFile refused: the data URL payload is not valid base64", .{});
        return BridgeError.InvalidParameter;
    };

    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    decoder.decode(out, encoded) catch {
        std.log.warn("saveFile refused: the data URL payload is not valid base64", .{});
        return BridgeError.InvalidParameter;
    };
    return out;
}

// =============================================================================
// Reply shaping. Pure, so the exact bytes the page receives are pinned by host
// tests on every platform.
// =============================================================================

/// One picked file, read out of the security-scoped URL. Every field is owned,
/// including `mime_type` when it is the fallback, so freeing is unconditional.
const PickedFile = struct {
    name: []u8,
    path: []u8,
    mime_type: []u8,
    /// The base64 body alone. The `data:` prefix is added by `shapePickedFile`,
    /// so the bytes are stored once rather than concatenated twice.
    base64: []u8,

    fn deinit(self: PickedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.mime_type);
        allocator.free(self.base64);
    }
};

/// Swift's fallback when a filename extension maps to no type
/// (`CraftApp.swift:5081-5083`), used for both the `mimeType` key and the
/// `data:` prefix, exactly as Swift uses one string for both.
const default_mime_type = "application/octet-stream";

/// The four-key object `documentPicker(_:didPickDocumentsAt:)` resolves.
///
/// Key order is `name`, `path`, `data`, `mimeType` — Swift's literal order.
/// Swift's own is a `Dictionary` and therefore arbitrary, so no caller can
/// depend on it, but a test can only pin bytes that are deterministic.
///
/// `name`, `path` and `mime_type` are JSON-escaped: filenames are user
/// controlled and legitimately contain `"` and `\`. The base64 body is appended
/// raw, because the standard alphabet plus `=` needs no escaping — and that is
/// *checked* rather than asserted, by the scan below, so a body that somehow
/// carried anything else is a refusal instead of broken JavaScript in the page.
fn shapePickedFile(allocator: std.mem.Allocator, file: PickedFile) ![]u8 {
    if (!isStandardBase64(file.base64)) {
        // `warn`, not `err`: this is a refusal, which is how every other
        // refusal in the mobile modules is logged, and the host test below
        // drives it on purpose.
        std.log.warn(
            "pickFile: the encoded body carries a byte outside the base64 alphabet; " ++
                "refusing rather than emitting a reply that would not parse",
            .{},
        );
        return BridgeError.NativeCallFailed;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"name\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, file.name);
    try out.appendSlice(allocator, "\",\"path\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, file.path);
    try out.appendSlice(allocator, "\",\"data\":\"data:");
    try bridge_error.appendJsonEscaped(allocator, &out, file.mime_type);
    try out.appendSlice(allocator, ";base64,");
    try out.appendSlice(allocator, file.base64);
    try out.appendSlice(allocator, "\",\"mimeType\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, file.mime_type);
    try out.appendSlice(allocator, "\"}");

    return out.toOwnedSlice(allocator);
}

fn isStandardBase64(s: []const u8) bool {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '+', '/', '=' => {},
        else => return false,
    };
    return true;
}

/// `saveFile`'s reply: the written path as a **bare JSON string**, not an
/// object.
///
/// `resolveCallback` serialises with `.fragmentsAllowed`, so Swift's
/// `result: fileURL.path` goes on the wire as a bare string, and Android agrees
/// (`file.absolutePath`). An object here would be a shape nothing is written
/// for.
fn shapeSavedPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, path);
    try out.append(allocator, '"');

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// How a delegate callback settles the pending call.
//
// The resolve-versus-reject decision is rule 4's, so it lives in one pure
// function rather than being spelled at each callback: `cancelled` mapping to
// anything but `reject` is the single most likely way this file could go wrong,
// and it is pinned by a host test.
// =============================================================================

/// What a document-picker callback found.
/// The error code each rejecting outcome deserves.
///
/// The distinction was always here — `Outcome` separates a Cancel from an
/// unreadable file — but there was no channel to carry it, so all four
/// arrived as NATIVE_CALL_FAILED and the page could not tell "the user said
/// no" from "something broke". `ios_async.deliverErrorCode` is that channel.
///
/// `no_selection` and `dismissed` are cancels in every sense the page cares
/// about: nothing was picked, and nothing went wrong. Only `unreadable` is a
/// genuine native failure.
fn errorFor(outcome: Outcome) bridge_error.BridgeError {
    return switch (outcome) {
        .cancelled, .no_selection, .dismissed => bridge_error.BridgeError.Cancelled,
        .unreadable => bridge_error.BridgeError.NativeCallFailed,
        .picked => unreachable, // not a rejecting outcome
    };
}

const Outcome = enum {
    /// A file was chosen and its bytes were read.
    picked,
    /// The user tapped Cancel — `documentPickerWasCancelled:`.
    cancelled,
    /// `didPickDocumentsAtURLs:` with an empty array.
    no_selection,
    /// A file was chosen and something about reading or shaping it failed.
    unreadable,
    /// The sheet was swiped away — `presentationControllerDidDismiss:`, which
    /// arrives when `documentPickerWasCancelled:` does not.
    dismissed,
};

/// How the page's promise must be settled.
const Answer = enum { resolve, reject };

/// Swift's mapping, verbatim: only the read-succeeded branch resolves.
///
/// `cancelled` is a **reject** (`rejectCallback(pendingCallbackId, error: "Cancelled")`),
/// not a distinct resolve. `no_selection` is Swift's `"No file selected"`
/// reject. `unreadable` is this file's divergence 2 — Swift resolves a
/// data-less `{name, path}` there, which reports success for a file whose
/// contents nobody read. `dismissed` is a swipe-down: nothing was picked, so
/// resolving anything would be success for a pick that did not happen.
fn answerFor(outcome: Outcome) Answer {
    return switch (outcome) {
        .picked => .resolve,
        .cancelled, .no_selection, .unreadable, .dismissed => .reject,
    };
}

/// Settle whatever call this picker was serving, and nothing else.
///
/// Takes the pending ticket, so a second callback — a late fire, a duplicate —
/// finds nothing and is a no-op rather than a second reply. `json` is required
/// for `.resolve` and ignored otherwise; a `.resolve` with no payload is
/// downgraded to an error rather than resolved empty, because
/// `craft-bridge.js` settles with `payload || {}` and an empty resolve would
/// look like success.
///
/// Never calls `evaluateJavaScript`: this runs on a framework callback, and the
/// reply is main-thread-only. `ios_async` owns that hop.
fn settlePick(outcome: Outcome, json: ?[]const u8) void {
    const ticket = takePendingPick() orelse {
        std.log.info(
            "pickFile: a document-picker callback arrived with no call waiting; ignored",
            .{},
        );
        return;
    };

    switch (answerFor(outcome)) {
        .resolve => {
            const payload = json orelse {
                std.log.err("pickFile: a resolve was decided with no payload to send", .{});
                ios_async.deliverError(ticket);
                return;
            };
            ios_async.deliverJson(ticket, payload);
        },
        .reject => {
            // Swift rejects with free text — "Cancelled", "No file selected" —
            // and `sendErrorToJS` carries an enum, so the exact wording is
            // still lost. What is no longer lost is the *kind*: `errorFor`
            // maps a Cancel to CANCELLED and only a genuine read failure to
            // NATIVE_CALL_FAILED, so a page can tell "the user said no" from
            // "something broke" without reading a log.
            ios_async.deliverErrorCode(ticket, errorFor(outcome));
        },
    }
}

// =============================================================================
// One pending pick, guarded.
//
// A picker is modal and serves exactly one call, so there is one slot rather
// than a pool. It is mutex-guarded even though WebKit delivers the dispatch and
// UIKit delivers the callbacks on the main thread, because "it should always be
// the main thread" is not a guard.
// =============================================================================

var pending_pick: ?ios_async.Ticket = null;
var pick_mutex: compat_mutex.Mutex = .{};

/// Record the call the delegate will answer. False means one is already
/// recorded, and the caller must refuse — never replace, which would strand the
/// first caller's promise forever.
fn publishPendingPick(ticket: ios_async.Ticket) bool {
    pick_mutex.lock();
    defer pick_mutex.unlock();
    if (pending_pick != null) return false;
    pending_pick = ticket;
    return true;
}

/// Read and clear the slot. Clearing is what makes a second callback a no-op
/// rather than a second reply, and what lets the next `pickFile` through.
fn takePendingPick() ?ios_async.Ticket {
    pick_mutex.lock();
    defer pick_mutex.unlock();
    const ticket = pending_pick;
    pending_pick = null;
    return ticket;
}

// =============================================================================
// The delegate class, built once through `ios_delegate`.
// =============================================================================

/// Deliberately prefixed, following `bridge_mobile_location.zig`'s
/// `CraftIOSLocationDelegate`: both this and any desktop registration look a
/// class up with `objc_getClass` first, so a shared name would let whichever
/// registered second silently adopt the other's IMPs.
const delegate_class_name = "CraftIOSDocumentPickerDelegate";

/// The plural, iOS 11+ selector. The deprecated singular
/// `documentPicker:didPickDocumentAtURL:` is deliberately not registered —
/// UIKit calls the plural, and registering both would give two answers to one
/// pick on any OS that still called the old one.
const sel_did_pick_documents = "documentPicker:didPickDocumentsAtURLs:";
const sel_was_cancelled = "documentPickerWasCancelled:";
/// The swipe-down belt, registered on the same delegate. iOS 13+; on anything
/// older it is never sent. See `attachDismissObserver`.
const sel_did_dismiss = "presentationControllerDidDismiss:";

/// The delegate instance, held for the life of the process.
///
/// `UIDocumentPickerViewController.h:65` declares `delegate` **weak**, and
/// `ios_delegate.instantiate` does not retain. This var is the strong
/// reference; without it the first Cancel is a use-after-free.
var delegate_instance: Id = null;

fn ensureDelegate() !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (delegate_instance) |existing| return existing;

    // Plain `fn`, not `export fn`: an exported symbol is process-global and
    // these names are generic enough to collide with another delegate in the
    // same binary. `class_addMethod` takes the address either way.
    const cls = try ios_delegate.defineClass(delegate_class_name, "NSObject", &.{
        .{
            .selector = sel_did_pick_documents,
            .imp = @ptrCast(&documentPickerDidPickDocumentsAtURLs),
            // `- (void)m:(id)controller :(id)urls`. A wrong encoding still
            // registers and still dispatches, then reads arguments from the
            // wrong registers with no crash and no compile error, which is why
            // the shape is named rather than spelled.
            .types = ios_delegate.enc.void_two_objects,
        },
        .{
            .selector = sel_was_cancelled,
            .imp = @ptrCast(&documentPickerWasCancelled),
            // `- (void)m:(id)controller`.
            .types = ios_delegate.enc.void_one_object,
        },
        .{
            // `- (void)presentationControllerDidDismiss:(UIPresentationController *)pc`
            .selector = sel_did_dismiss,
            .imp = @ptrCast(&documentPickerDidDismissInteractively),
            .types = ios_delegate.enc.void_one_object,
        },
    });

    const instance = (try ios_delegate.instantiate(cls)) orelse return error.NativeCallFailed;
    delegate_instance = instance;
    return instance;
}

/// Dismiss the picker, but only if it is still presented.
///
/// `UIDocumentPickerViewController` dismisses itself before calling the
/// delegate — Swift's two methods contain no `dismiss` call, unlike the image
/// picker's. An unconditional dismiss would therefore be a second one, and
/// `-dismissViewControllerAnimated:completion:` on a controller with nothing
/// presented forwards up the presentation chain and can close something nobody
/// asked to close. Reading `presentingViewController` first is what makes this
/// safe in both worlds: nil means it has already gone, non-nil means it is
/// genuinely still up and the app would otherwise be stuck behind it.
fn dismissPicker(controller: Id) void {
    if (!is_darwin) return;
    if (controller == null) return;

    const sel_presenting = objc.sel_registerName("presentingViewController") orelse return;
    if (objc.msgSendId(controller, sel_presenting) == null) return;

    const sel_dismiss = objc.sel_registerName("dismissViewControllerAnimated:completion:") orelse {
        std.log.warn(
            "pickFile: no dismissViewControllerAnimated:completion: selector; the document " ++
                "picker is still presented",
            .{},
        );
        return;
    };
    const DismissFn = *const fn (Id, Id, bool, Id) callconv(.c) void;
    const dismiss: DismissFn = @ptrCast(&objc.objc_msgSend);
    dismiss(controller, sel_dismiss, true, null);
}

fn documentPickerDidPickDocumentsAtURLs(_: Id, _: Id, controller: Id, urls: Id) callconv(.c) void {
    if (!is_darwin) return;

    dismissPicker(controller);

    const allocator = std.heap.c_allocator;

    const sel_first = objc.sel_registerName("firstObject") orelse {
        std.log.err("pickFile: no firstObject selector; cannot read the picked URL", .{});
        settlePick(.unreadable, null);
        return;
    };
    // `urls.first` in Swift. `firstObject` answers nil for an empty array,
    // where `objectAtIndex:0` would raise an uncatchable NSRangeException.
    const url = objc.msgSendId(urls, sel_first) orelse {
        std.log.warn("pickFile: the document picker returned no URL", .{});
        settlePick(.no_selection, null);
        return;
    };

    const file = readPickedFile(allocator, url) catch |err| {
        std.log.err(
            "pickFile: could not read the picked file ({}); rejecting rather than resolving " ++
                "an object with no data, which is what the Swift path does here",
            .{err},
        );
        settlePick(.unreadable, null);
        return;
    };
    defer file.deinit(allocator);

    const json = shapePickedFile(allocator, file) catch |err| {
        std.log.err("pickFile: could not shape the reply ({})", .{err});
        settlePick(.unreadable, null);
        return;
    };
    defer allocator.free(json);

    settlePick(.picked, json);
}

fn documentPickerWasCancelled(_: Id, _: Id, controller: Id) callconv(.c) void {
    if (!is_darwin) return;

    dismissPicker(controller);

    // Swift's `rejectCallback(pendingCallbackId, error: "Cancelled")`. The word
    // survives only here — the wire carries a `BridgeError` enum.
    std.log.info("pickFile: cancelled by the user", .{});
    settlePick(.cancelled, null);
}

/// The user swiped the sheet away.
///
/// Nothing is dismissed here: UIKit has already taken the sheet off the screen,
/// which is exactly what this callback reports, and sending
/// `dismissViewControllerAnimated:` now could close whatever the presenter shows
/// next. The only job is to settle the call.
///
/// Reached with the slot already empty whenever a real callback got there first,
/// in which case `settlePick` is a no-op rather than a second answer.
fn documentPickerDidDismissInteractively(_: Id, _: Id, _: Id) callconv(.c) void {
    if (!is_darwin) return;

    std.log.warn(
        "pickFile: the picker was dismissed interactively; rejecting the call rather than " ++
            "leaving it unanswered on a promise that has no timeout",
        .{},
    );
    settlePick(.dismissed, null);
}

/// The three selectors the swipe-down belt needs, resolved at dispatch so a
/// missing one fails the call rather than silently leaving the only thing that
/// answers an interactive dismissal unattached.
const DismissSels = struct {
    /// `-[UIViewController presentationController]`.
    presentation: Id,
    /// `-[UIPresentationController delegate]`, read so an existing delegate is
    /// never displaced.
    delegate: Id,
    /// `-[UIPresentationController setDelegate:]` — the same `setDelegate:` the
    /// picker's own delegate is installed with.
    set_delegate: Id,
};

/// Point the picker's presentation controller at this module's delegate, so an
/// interactive dismissal reaches `presentationControllerDidDismiss:`. Returns
/// whether it was attached.
///
/// `UIDocumentPickerViewController` presents as a form/page sheet, and a
/// swipe-down is widely reported not to send `documentPickerWasCancelled:`.
/// That report is verified on no device in this repo, so this is a belt and not
/// a fix: it costs two messages, and if the report is right it is the only
/// thing that ever frees `pending_pick` after a swipe. It matters more here than
/// in Swift, because this module *refuses* later calls while one is pending — a
/// stranded ticket disables `pickFile` for the life of the process, where Swift
/// merely strands the one promise. It is also the same belt
/// `bridge_mobile_imagepicker.zig` and `bridge_mobile_contactpicker.zig` carry.
///
/// A presentation controller that already carries a delegate is left alone and
/// reported as not attached: displacing one would change how the picker manages
/// its own adaptive presentation, which is a new bug in exchange for a belt.
///
/// Idempotent against the real cancel. UIKit sends
/// `presentationControllerDidDismiss:` only for a user-driven dismissal, never
/// for a programmatic one, so it cannot follow a pick or a Cancel that already
/// answered — and if it did anyway, `takePendingPick` has already emptied the
/// slot and `ios_async`'s generation counter would drop the second delivery.
fn attachDismissObserver(picker: Id, delegate: Id, sels: DismissSels) bool {
    if (!is_darwin) return false;

    const presentation = objc.msgSendId(picker, sels.presentation) orelse return false;
    if (objc.msgSendId(presentation, sels.delegate) != null) return false;

    objc.msgSendVoid1(presentation, sels.set_delegate, delegate);
    return true;
}

// =============================================================================
// Reading the picked file.
// =============================================================================

/// Read one security-scoped document URL into the four fields the reply needs.
///
/// The `start`/`stop` pair around the read is the fix described as divergence 1
/// in the module comment: the picker was built with `asCopy == NO`, so this URL
/// points outside the app container and the read fails on a device without it.
/// It is invisible in the simulator, where the URL resolves to an ordinary host
/// path and the read succeeds either way — so a green simulator run says
/// nothing about this call.
fn readPickedFile(allocator: std.mem.Allocator, url: Id) !PickedFile {
    if (!is_darwin) return error.UnsupportedPlatform;

    const sel_start = try selector("startAccessingSecurityScopedResource");
    const sel_stop = try selector("stopAccessingSecurityScopedResource");
    const sel_last_component = try selector("lastPathComponent");
    const sel_path = try selector("path");
    const sel_extension = try selector("pathExtension");
    const sel_data_with_url = try selector("dataWithContentsOfURL:");
    const sel_base64 = try selector("base64EncodedStringWithOptions:");

    // BOOL, and the return matters: the stop must be sent only when the start
    // succeeded, because the access counter is balanced.
    const scoped = objc.msgSendBool(url, sel_start);
    defer if (scoped) objc.msgSend(url, sel_stop);

    const name_obj = objc.msgSendId(url, sel_last_component) orelse return error.NativeCallFailed;
    const name = try copyNSString(allocator, name_obj);
    errdefer allocator.free(name);

    const path_obj = objc.msgSendId(url, sel_path) orelse return error.NativeCallFailed;
    const path = try copyNSString(allocator, path_obj);
    errdefer allocator.free(path);

    const extension_obj = objc.msgSendId(url, sel_extension);
    const mime_type = try copyMimeType(allocator, extension_obj);
    errdefer allocator.free(mime_type);

    const NSData = objc.objc_getClass("NSData") orelse return error.ClassNotFound;
    // Nil here is Swift's `try?` yielding nil, which is where it resolves an
    // object with no `data`. This is the branch that fails on a device without
    // the security scope above.
    const data_obj = objc.msgSendId1(NSData, sel_data_with_url, url) orelse
        return error.FileContentsUnreadable;

    // Options 0 — exactly `Data.base64EncodedString()`: standard alphabet,
    // padded, no line wrapping.
    const base64_obj = objc.msgSendId1(data_obj, sel_base64, @as(c_ulong, 0)) orelse
        return error.NativeCallFailed;
    const base64 = try copyNSString(allocator, base64_obj);

    return .{ .name = name, .path = path, .mime_type = mime_type, .base64 = base64 };
}

/// `URL.mimeType` from `CraftApp.swift:5078-5085`: the filename extension's
/// preferred MIME type, or `application/octet-stream`.
///
/// A nil at either step is Swift's fallback and not an error — a file with no
/// extension, or an extension no type claims, is an ordinary file. The `UTType`
/// class *is* looked up again here and a null answer is an error rather than a
/// fallback, which is unreachable in practice (`pickFile` refused before
/// presenting if the class was absent) but is a guard rather than an assumption.
fn copyMimeType(allocator: std.mem.Allocator, extension_obj: Id) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const fallback = try allocator.dupe(u8, default_mime_type);
    errdefer allocator.free(fallback);

    if (extension_obj == null) return fallback;

    const UTTypeClass = objc.objc_getClass("UTType") orelse return error.ClassNotFound;
    const sel_with_extension = try selector("typeWithFilenameExtension:");
    const sel_preferred = try selector("preferredMIMEType");

    const ut_type = objc.msgSendId1(UTTypeClass, sel_with_extension, extension_obj) orelse
        return fallback;
    const mime_obj = objc.msgSendId(ut_type, sel_preferred) orelse return fallback;

    const mime = try copyNSString(allocator, mime_obj);
    allocator.free(fallback);
    return mime;
}

/// The `UTType` array `initForOpeningContentTypes:` takes.
///
/// Swift's default is `[.item]`, the `UTTypeItem` global. It is built here with
/// `+[UTType typeWithIdentifier:@"public.item"]` rather than by `dlsym`-ing the
/// `UTType *const` cell: the identifier is documented and stable, and it does
/// not depend on the symbol being exported by whatever image loaded the
/// framework.
///
/// Each page-supplied entry is mapped MIME type first and filename extension
/// second, as Swift does, and then by identifier — see divergence 4. An entry
/// that maps to nothing is refused rather than dropped.
///
/// `parsePickRequest` refuses an empty `types` array, so the returned array
/// always has at least one element.
fn buildContentTypes(allocator: std.mem.Allocator, request: PickRequest, UTTypeClass: Id) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSMutableArray = objc.objc_getClass("NSMutableArray") orelse return error.ClassNotFound;
    const sel_array = try selector("array");
    const sel_add = try selector("addObject:");
    const sel_with_identifier = try selector("typeWithIdentifier:");
    const sel_with_mime = try selector("typeWithMIMEType:");
    const sel_with_extension = try selector("typeWithFilenameExtension:");

    const types = objc.msgSendId(NSMutableArray, sel_array) orelse return error.NativeCallFailed;

    const listed = request.types orelse {
        const ns_item = try objc.createNSString("public.item", allocator);
        if (ns_item == null) return error.NativeCallFailed;
        const item = objc.msgSendId1(UTTypeClass, sel_with_identifier, ns_item) orelse {
            std.log.err("pickFile: UTType has no public.item; cannot build the default", .{});
            return BridgeError.NativeCallFailed;
        };
        objc.msgSendVoid1(types, sel_add, item);
        return types;
    };

    for (listed) |entry| {
        const ns_entry = try objc.createNSString(entry, allocator);
        if (ns_entry == null) {
            std.log.warn("pickFile refused: a types entry is not valid UTF-8", .{});
            return BridgeError.InvalidParameter;
        }

        const mapped =
            objc.msgSendId1(UTTypeClass, sel_with_mime, ns_entry) orelse
            objc.msgSendId1(UTTypeClass, sel_with_extension, ns_entry) orelse
            objc.msgSendId1(UTTypeClass, sel_with_identifier, ns_entry) orelse
            {
                // Swift's `compactMap` drops this silently and can end up with
                // an empty array; dropping a field the page sent is exactly
                // what must not happen.
                std.log.warn(
                    "pickFile refused: types entry '{s}' is not a MIME type, a filename " ++
                        "extension, or a type identifier",
                    .{entry},
                );
                return BridgeError.InvalidParameter;
            };

        // `-[NSMutableArray addObject:]` raises NSInvalidArgumentException on
        // nil, which from Zig is an uncatchable crash rather than something the
        // page can be told about. `mapped` is non-null by construction above.
        objc.msgSendVoid1(types, sel_add, mapped);
    }

    return types;
}

// =============================================================================
// The Documents directory and the write. Both are the third copy of a chain
// `bridge_mobile_db.zig` and `bridge_mobile_locrecording.zig` already carry
// file-privately; extracting the shared helper is a change to those two files
// and is not made here.
// =============================================================================

/// `NSDocumentDirectory`.
const ns_document_directory: c_ulong = 9;
/// `NSUserDomainMask`.
const ns_user_domain_mask: c_ulong = 1;
/// `NSUTF8StringEncoding`.
const ns_utf8_string_encoding: c_ulong = 4;
/// `NSDataWritingAtomic`.
const ns_data_writing_atomic: c_ulong = 1;

/// `NSFileManager` -> `URLsForDirectory:inDomains:` -> `firstObject` -> `path`,
/// the chain Swift's `saveFile` runs, with every step guarded.
///
/// Swift subscripts with `[0]`, which raises `NSRangeException` on an empty
/// result; `firstObject` answers nil, and nil here is a named refusal rather
/// than an uncatchable SIGABRT.
fn documentsPath(allocator: std.mem.Allocator) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSFileManager = objc.objc_getClass("NSFileManager") orelse return error.ClassNotFound;
    const sel_default = try selector("defaultManager");
    const manager = objc.msgSendId(NSFileManager, sel_default) orelse return error.NativeCallFailed;

    const sel_urls = try selector("URLsForDirectory:inDomains:");
    // NSUInteger arguments: explicit `c_ulong`, because the variadic msgSend
    // cast takes its argument types from what is passed.
    const urls = objc.msgSendId2(
        manager,
        sel_urls,
        ns_document_directory,
        ns_user_domain_mask,
    ) orelse return error.NativeCallFailed;

    const sel_first = try selector("firstObject");
    const url = objc.msgSendId(urls, sel_first) orelse return error.NotFound;

    const sel_path = try selector("path");
    const path_obj = objc.msgSendId(url, sel_path) orelse return error.NativeCallFailed;

    return copyNSString(allocator, path_obj);
}

/// Write `bytes` to `path`, atomically.
///
/// Swift's two branches differ — the base64 one uses `Data.write(to:)` with
/// default options (non-atomic) and the text one
/// `String.write(to:atomically:true,encoding:.utf8)`. Both are atomic here; the
/// difference is observable only in that a crash mid-write leaves the previous
/// file intact rather than a truncated one, which is the direction worth being
/// wrong in.
///
/// `writeToFile:options:error:` rather than `writeToFile:atomically:`, purely so
/// the `NSError` can be logged: the page's reply carries a `BridgeError` enum
/// and the description has nowhere else to go.
fn writeFileAtomically(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSData = objc.objc_getClass("NSData") orelse return error.ClassNotFound;
    const sel_with_bytes = try selector("dataWithBytes:length:");
    const sel_write = try selector("writeToFile:options:error:");

    const data_obj = objc.msgSendId2(
        NSData,
        sel_with_bytes,
        bytes.ptr,
        @as(c_ulong, bytes.len),
    ) orelse return error.NativeCallFailed;

    const ns_path = try objc.createNSString(path, allocator);
    if (ns_path == null) return error.NativeCallFailed;

    var write_error: Id = null;
    const WriteFn = *const fn (Id, Id, Id, c_ulong, *Id) callconv(.c) bool;
    const write_fn: WriteFn = @ptrCast(&objc.objc_msgSend);
    const wrote = write_fn(data_obj, sel_write, ns_path, ns_data_writing_atomic, &write_error);

    if (!wrote) {
        std.log.warn(
            "saveFile: could not write '{s}': {s}",
            .{ path, readNSString(write_error, "localizedDescription") orelse "(no description)" },
        );
        return BridgeError.NativeCallFailed;
    }
}

/// An `NSString` as owned bytes, refusing a value `UTF8String` truncated.
///
/// `-[NSString UTF8String]` is NUL-terminated, so a name or path carrying an
/// embedded U+0000 would read back short — and a short path names a *different*
/// file. The C-string length is therefore checked against
/// `lengthOfBytesUsingEncoding:`, the same check
/// `bridge_mobile_locrecording.zig` and `bridge_mobile_notifications.zig` make.
fn copyNSString(allocator: std.mem.Allocator, ns_string: Id) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const cstr = objc.getNSStringUTF8(ns_string) orelse return error.NativeCallFailed;
    const bytes = std.mem.span(cstr);

    const sel_len = try selector("lengthOfBytesUsingEncoding:");
    const LenFn = *const fn (Id, Id, c_ulong) callconv(.c) c_ulong;
    const len_fn: LenFn = @ptrCast(&objc.objc_msgSend);
    const declared = len_fn(ns_string, sel_len, ns_utf8_string_encoding);

    if (declared != bytes.len) {
        std.log.warn(
            "file picker: a string is {d} UTF-8 bytes but reads back as {d}; refusing rather " ++
                "than reporting a truncated name or path",
            .{ declared, bytes.len },
        );
        return error.NativeCallFailed;
    }

    return allocator.dupe(u8, bytes);
}

/// A zero-argument `NSString`-returning property, as borrowed bytes. Null for a
/// nil object, a nil string, or a selector that will not register — all three
/// are "nothing to report". The slice borrows the string's buffer, valid for the
/// current autorelease pool; the only caller logs it synchronously.
fn readNSString(object: Id, comptime name: [*:0]const u8) ?[]const u8 {
    if (!is_darwin) return null;
    if (object == null) return null;

    const sel = objc.sel_registerName(name) orelse return null;
    const value = objc.msgSendId(object, sel) orelse return null;
    const utf8 = objc.getNSStringUTF8(value) orelse return null;
    return std.mem.span(utf8);
}

// =============================================================================
// Tests - host-only.
//
// Everything that decides page-visible bytes is pure and pinned here: routing
// in both directions, both payloads field by field, the resolve/reject decision
// for all four outcomes, the four-key success object and the bare-string save
// reply, the base64 and filename guards, and the concurrent-pick refusal.
//
// Nothing here presents a picker or touches the Documents directory. On a macOS
// runner `objc_getClass("UIDocumentPickerViewController")` is null — UIKit is
// not loadable there at all — so the UIKit paths are unreachable rather than
// merely skipped, and the fixture cannot drive a modal either (it posts raw
// envelopes with no way to tap Cancel or choose a file). `saveFile` is the half
// that a simulator fixture can drive end to end.
// =============================================================================

/// One required string field of `downloadFile`'s payload.
///
/// Swift's arm is a two-clause `if let … as? String` chain with no `else`, so
/// a missing or mistyped field settles nothing and the page waits out its
/// timeout. Every path here ends in a value or an error.
fn downloadField(root: std.json.ObjectMap, comptime key: []const u8) ![]const u8 {
    const value = root.get(key) orelse {
        std.log.warn("downloadFile refused: no " ++ key ++ " field", .{});
        return BridgeError.MissingData;
    };
    return switch (value) {
        .string => |text| if (text.len == 0) {
            std.log.warn("downloadFile refused: " ++ key ++ " is empty", .{});
            return BridgeError.InvalidParameter;
        } else text,
        else => {
            std.log.warn("downloadFile refused: " ++ key ++ " is not a string", .{});
            return BridgeError.InvalidParameter;
        },
    };
}

// ===========================================================================
// The download completion
//
// `void (^)(NSURL *location, NSURLResponse *response, NSError *error)` — three
// object arguments, which no `ios_async` pooled block covers. Global, one
// comptime invoke per slot, in the shape `bridge_mobile_notifications.zig`
// established.
//
// The move happens inside the block, on whatever queue NSURLSession chose,
// because that is the only window in which `location` is valid: the temporary
// file is deleted the moment the handler returns. `NSFileManager` is safe to
// use from any thread for this, and the reply goes out through
// `ios_async.deliverJson`, which does its own hop to the main queue.
// ===========================================================================

/// The filename a slot's completion will move its download to.
const PendingDownload = struct {
    ticket: ios_async.Ticket,
    /// Owned, `c_allocator`. Freed when the completion fires.
    filename: []u8,
};

var pending_downloads: [ios_async.max_in_flight]?PendingDownload = @splat(null);
var download_mutex: compat_mutex.Mutex = .{};

fn publishDownload(ticket: ios_async.Ticket, filename: []u8) void {
    download_mutex.lock();
    defer download_mutex.unlock();
    pending_downloads[ticket.index] = .{ .ticket = ticket, .filename = filename };
}

/// Read and clear, so a second fire is a no-op rather than a second reply and
/// a double free.
fn takeDownload(index: u5) ?PendingDownload {
    download_mutex.lock();
    defer download_mutex.unlock();
    const call = pending_downloads[index];
    pending_downloads[index] = null;
    return call;
}

const DownloadBlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

const DownloadBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const DownloadBlockDescriptor,
};

/// 1 << 28 — a global block is never copied.
const DOWNLOAD_BLOCK_IS_GLOBAL: c_int = 1 << 28;

const download_block_descriptor = DownloadBlockDescriptor{ .size = @sizeOf(DownloadBlock) };

extern var _NSConcreteGlobalBlock: anyopaque;

fn makeDownloadInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const DownloadBlock, location: Id, _: Id, err: Id) callconv(.c) void {
            downloadFinished(index, location, err);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeDownloadBlocks() [ios_async.max_in_flight]DownloadBlock {
    var out: [ios_async.max_in_flight]DownloadBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = DOWNLOAD_BLOCK_IS_GLOBAL,
            .invoke = makeDownloadInvoke(@intCast(i)),
            .descriptor = &download_block_descriptor,
        };
    }
    return out;
}

var download_blocks: [ios_async.max_in_flight]DownloadBlock =
    if (is_darwin) makeDownloadBlocks() else undefined;

fn downloadFinished(index: u5, location: Id, err: Id) void {
    if (!is_darwin) return;

    const call = takeDownload(index) orelse {
        std.log.warn(
            "downloadFile completion fired for slot {d} with no call recorded; ignored",
            .{index},
        );
        return;
    };
    const allocator = std.heap.c_allocator;
    defer allocator.free(call.filename);

    if (err != null) {
        logNSError("downloadFile", err);
        ios_async.deliverErrorCode(call.ticket, BridgeError.NativeCallFailed);
        return;
    }
    if (location == null) {
        // Swift's `guard let localURL else { reject("Download failed") }`.
        std.log.warn("downloadFile: the task reported neither a file nor an error", .{});
        ios_async.deliverErrorCode(call.ticket, BridgeError.NativeCallFailed);
        return;
    }

    const path = moveIntoDocuments(allocator, location, call.filename) catch |move_err| {
        std.log.warn("downloadFile: could not move the download into place: {}", .{move_err});
        ios_async.deliverErrorCode(call.ticket, BridgeError.NativeCallFailed);
        return;
    };
    defer allocator.free(path);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    out.append(allocator, '"') catch {
        ios_async.deliverError(call.ticket);
        return;
    };
    bridge_error.appendJsonEscaped(allocator, &out, path) catch {
        ios_async.deliverError(call.ticket);
        return;
    };
    out.append(allocator, '"') catch {
        ios_async.deliverError(call.ticket);
        return;
    };

    // Swift resolves `destinationURL.path` — a bare JSON string, not an object.
    ios_async.deliverJson(call.ticket, out.items);
}

/// `Documents/<filename>`, replacing anything already there, and the path.
fn moveIntoDocuments(allocator: std.mem.Allocator, location: Id, filename: []const u8) ![]u8 {
    const documents = try documentsPath(allocator);
    defer allocator.free(documents);

    const destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ documents, filename });
    errdefer allocator.free(destination);

    const NSFileManager = objc.objc_getClass("NSFileManager") orelse return error.ClassNotFound;
    const sel_default = try selector("defaultManager");
    const manager = objc.msgSendId(NSFileManager, sel_default) orelse return error.NativeCallFailed;

    const ns_destination = try objc.createNSString(destination, allocator);

    // Swift removes an existing file first, because `moveItemAtURL:` fails
    // rather than overwriting. A failure here is ignored exactly as Swift's
    // `if fileExists` guard ignores the race between the two calls.
    const sel_exists = try selector("fileExistsAtPath:");
    const ExistsFn = *const fn (Id, Id, Id) callconv(.c) bool;
    const exists: ExistsFn = @ptrCast(&objc.objc_msgSend);
    if (exists(manager, sel_exists, ns_destination)) {
        const sel_remove = try selector("removeItemAtPath:error:");
        const RemoveFn = *const fn (Id, Id, Id, ?*Id) callconv(.c) bool;
        const remove: RemoveFn = @ptrCast(&objc.objc_msgSend);
        _ = remove(manager, sel_remove, ns_destination, null);
    }

    const NSURL = objc.objc_getClass("NSURL") orelse return error.ClassNotFound;
    const sel_file_url = try selector("fileURLWithPath:");
    const destination_url = objc.msgSendId1(NSURL, sel_file_url, ns_destination) orelse
        return error.NativeCallFailed;

    const sel_move = try selector("moveItemAtURL:toURL:error:");
    const MoveFn = *const fn (Id, Id, Id, Id, ?*Id) callconv(.c) bool;
    const move: MoveFn = @ptrCast(&objc.objc_msgSend);
    var move_error: Id = null;
    if (!move(manager, sel_move, location, destination_url, &move_error)) {
        logNSError("downloadFile", move_error);
        return error.NativeCallFailed;
    }

    return destination;
}

fn logNSError(action: []const u8, err: Id) void {
    const ns_error = err orelse return;
    const sel = objc.sel_registerName("localizedDescription") orelse return;
    const ns_description = objc.msgSendId(ns_error, sel) orelse return;
    const utf8 = objc.getNSStringUTF8(ns_description) orelse return;
    std.log.warn("{s}: {s}", .{ action, std.mem.span(utf8) });
}

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 3), capability_actions.len);
    try testing.expectEqualStrings(A.pick_file, capability_actions[0].name);
    try testing.expectEqualStrings(A.save_file, capability_actions[1].name);
    try testing.expectEqualStrings(A.download_file, capability_actions[2].name);

    for (capability_actions) |decl| {
        // A `.result` whose handler never replies parks the caller until its
        // timeout; a `.none` that is awaited resolves immediately and means
        // nothing. Swift resolves or rejects both of these.
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        // `.live` with a reason would be a contradiction the manifest shows apps.
        try testing.expect(decl.reason == null);
    }
}

test "the action names match the Swift case labels exactly" {
    try testing.expectEqualStrings("pickFile", A.pick_file);
    try testing.expectEqualStrings("saveFile", A.save_file);
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

test "the dispatcher reaches both handlers, not just the routing table" {
    // The other half of table-versus-dispatch: `routeFor` agreeing with
    // `capability_actions` proves nothing if `handleMessage` never calls the
    // handler. Both payloads fail early and for their own reason — `saveFile`
    // has no `data` field, and `pickFile` finds no UIKit picker class on a
    // macOS host — so this is a routing check and not a device test. What it
    // rules out is the one silent failure: `UnknownAction`, which
    // `ios_dispatch.route` reads as "not mine" and hands to the Swift shim.
    var bridge = FilePickerBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            continue;
        };
        // Neither can succeed here: `saveFile` is missing its required fields
        // and `pickFile` has no picker to present.
        std.debug.print("'{s}' unexpectedly succeeded on a host\n", .{decl.name});
        return error.HandlerSucceededWithoutADevice;
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = FilePickerBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("noSuchAction", "{}"));

    // Casing is how a real typo arrives, and a miss does not fail loudly:
    // `ios_dispatch` reads UnknownAction as "not mine" and hands the action to
    // the Swift shim, so a typo would silently un-serve the action.
    for ([_][]const u8{ "pickfile", "PickFile", "savefile", "SaveFile" }) |typo| {
        try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage(typo, "{}"));
    }

    // The desktop dialog namespace has its own `saveFile`; it is a different
    // action reached through a different `t`, and nothing about it belongs here.
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("showSaveDialog", "{}"));
}

test "downloadFile is left with the shim, and left undeclared" {
    var bridge = FilePickerBridge.init(testing.allocator);
    defer bridge.deinit();

    for (deliberately_unserved) |name| {
        // `UnknownAction` is the one return `ios_dispatch.route` turns into a
        // Swift-shim hand-off. Anything else would take the action away from
        // the arm that answers it today.
        try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage(name, "{}"));

        for (capability_actions) |decl| {
            try testing.expect(!std.mem.eql(u8, decl.name, name));
        }
        try testing.expect(routeFor(name) == null);
    }
}

// -----------------------------------------------------------------------------
// pickFile payload.
// -----------------------------------------------------------------------------

test "pickFile with no types asks for the default single item type" {
    // `body[\"types\"] as? [String]` is nil, and Swift's `allowedTypes` stays
    // `[.item]`. Null must behave the same as absent, because that is what the
    // cast does with a JSON null.
    for ([_][]const u8{ "{}", "{\"types\":null}" }) |payload| {
        const request = try parsePickRequest(testing.allocator, payload);
        defer request.deinit(testing.allocator);
        try testing.expect(request.types == null);
    }
}

test "pickFile carries every types entry the page sent, in order" {
    const request = try parsePickRequest(
        testing.allocator,
        "{\"types\":[\"image/png\",\"pdf\",\"public.image\"]}",
    );
    defer request.deinit(testing.allocator);

    const listed = request.types orelse return error.TypesWereDropped;
    try testing.expectEqual(@as(usize, 3), listed.len);
    try testing.expectEqualStrings("image/png", listed[0]);
    try testing.expectEqualStrings("pdf", listed[1]);
    try testing.expectEqualStrings("public.image", listed[2]);
}

test "pickFile refuses a types field it cannot use rather than dropping it" {
    // An empty array is what Swift's compactMap can produce, and what
    // `initForOpeningContentTypes:` does with one is unverified. A non-array
    // and a non-string entry are payloads no page should send, and silently
    // treating any of them as the default would widen the types the app asked
    // to restrict.
    for ([_][]const u8{
        "{\"types\":[]}",
        "{\"types\":\"image/png\"}",
        "{\"types\":42}",
        "{\"types\":[\"image/png\",7]}",
        "{\"types\":[null]}",
    }) |payload| {
        try testing.expectError(
            BridgeError.InvalidParameter,
            parsePickRequest(testing.allocator, payload),
        );
    }
}

test "pickFile refuses a payload that is not a JSON object" {
    for ([_][]const u8{ "[]", "\"types\"", "not json" }) |payload| {
        try testing.expectError(
            BridgeError.InvalidJSON,
            parsePickRequest(testing.allocator, payload),
        );
    }
}

// -----------------------------------------------------------------------------
// saveFile payload.
// -----------------------------------------------------------------------------

/// Parse `json` and hand its root object to `parseSaveRequest`. The request
/// borrows the parsed value, so the caller frees them together.
fn saveRequestFrom(json: []const u8) !struct {
    parsed: std.json.Parsed(std.json.Value),
    request: SaveRequest,

    fn deinit(self: *@This()) void {
        self.parsed.deinit();
    }
} {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    errdefer parsed.deinit();
    return .{ .parsed = parsed, .request = try parseSaveRequest(parsed.value.object) };
}

test "saveFile reads data and filename, and nothing else" {
    var got = try saveRequestFrom(
        "{\"data\":\"hello\",\"filename\":\"notes.txt\",\"mimeType\":\"text/plain\"}",
    );
    defer got.deinit();

    try testing.expectEqualStrings("hello", got.request.data);
    try testing.expectEqualStrings("notes.txt", got.request.filename);
    // `mimeType` is declared by `craft.d.ts` and passed by the README, and read
    // by neither Swift nor Android. Accepting and ignoring it is the only shape
    // that neither invents a field nor breaks the documented call.
}

test "saveFile refuses a payload missing either required field" {
    const parsed_a = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"filename\":\"a.txt\"}",
        .{},
    );
    defer parsed_a.deinit();
    try testing.expectError(BridgeError.MissingData, parseSaveRequest(parsed_a.value.object));

    const parsed_b = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"data\":\"hello\"}",
        .{},
    );
    defer parsed_b.deinit();
    try testing.expectError(BridgeError.MissingData, parseSaveRequest(parsed_b.value.object));
}

test "saveFile refuses a data or filename of the wrong type" {
    for ([_][]const u8{
        "{\"data\":7,\"filename\":\"a.txt\"}",
        "{\"data\":\"hello\",\"filename\":7}",
        "{\"data\":null,\"filename\":\"a.txt\"}",
    }) |payload| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
        defer parsed.deinit();
        try testing.expectError(
            BridgeError.InvalidParameter,
            parseSaveRequest(parsed.value.object),
        );
    }
}

test "a filename that would leave the Documents directory is refused" {
    // Swift joins this string on with appendingPathComponent and the write
    // lands wherever it points.
    for ([_][]const u8{
        "",
        "..",
        ".",
        "../Library/Preferences/x.plist",
        "sub/dir.txt",
        "/etc/passwd",
        "a\x00b.txt",
    }) |name| {
        try testing.expectError(BridgeError.InvalidParameter, validateFilename(name));
    }
}

test "an ordinary filename with dots in it is not refused" {
    // The traversal check must not be a substring match on "..": a name with no
    // separator cannot name a parent directory whatever dots it contains.
    for ([_][]const u8{ "notes.txt", "my..notes.txt", "..hidden", "archive.tar.gz", "a" }) |name| {
        try validateFilename(name);
    }
}

// -----------------------------------------------------------------------------
// saveFile content decoding.
// -----------------------------------------------------------------------------

test "a plain string is written as its own bytes" {
    const bytes = try decodeSaveBytes(testing.allocator, "hello, world");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello, world", bytes);
}

test "a base64 data URL is decoded to the bytes it encodes" {
    const bytes = try decodeSaveBytes(testing.allocator, "data:text/plain;base64,aGVsbG8=");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello", bytes);
}

test "an empty base64 body decodes to an empty file, as Swift writes one" {
    const bytes = try decodeSaveBytes(testing.allocator, "data:,");
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

test "a data URL that cannot be decoded is refused, never reported as written" {
    // Swift reaches `resolveCallback(callbackId, result: fileURL.path)` for
    // every one of these having written nothing: the `if` body just never runs
    // and nothing throws. `data:text/plain,hello` is the documented reproducer.
    for ([_][]const u8{
        "data:text/plain,hello",
        "data:",
        "data:text/plain;base64",
        "data:a,b,c",
        "data:text/plain;base64,aGVsbG8",
        "data:text/plain;base64,!!!!",
    }) |payload| {
        try testing.expectError(
            BridgeError.InvalidParameter,
            decodeSaveBytes(testing.allocator, payload),
        );
    }
}

test "a string that merely contains data: is not treated as a data URL" {
    // `hasPrefix`, not `contains`.
    const bytes = try decodeSaveBytes(testing.allocator, "see data:text/plain,hello");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("see data:text/plain,hello", bytes);
}

// -----------------------------------------------------------------------------
// Reply shaping.
// -----------------------------------------------------------------------------

test "a picked file is the four-key object Swift resolves" {
    const file = PickedFile{
        .name = @constCast("report.pdf"),
        .path = @constCast("/private/var/mobile/report.pdf"),
        .mime_type = @constCast("application/pdf"),
        .base64 = @constCast("aGVsbG8="),
    };

    const json = try shapePickedFile(testing.allocator, file);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"name\":\"report.pdf\",\"path\":\"/private/var/mobile/report.pdf\"," ++
            "\"data\":\"data:application/pdf;base64,aGVsbG8=\",\"mimeType\":\"application/pdf\"}",
        json,
    );

    // And it is valid JSON with the keys the page reads, not just string-equal.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("report.pdf", parsed.value.object.get("name").?.string);
    try testing.expectEqualStrings(
        "data:application/pdf;base64,aGVsbG8=",
        parsed.value.object.get("data").?.string,
    );
}

test "a filename carrying quotes and backslashes stays valid JSON" {
    // Filenames are user controlled and legitimately contain both. An
    // unescaped quote would close the string early and turn the whole reply
    // script into a syntax error in the page, with nothing to point at.
    const file = PickedFile{
        .name = @constCast("we\"ird\\name.txt"),
        .path = @constCast("/tmp/we\"ird\\name.txt"),
        .mime_type = @constCast("text/plain"),
        .base64 = @constCast("QQ=="),
    };

    const json = try shapePickedFile(testing.allocator, file);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("we\"ird\\name.txt", parsed.value.object.get("name").?.string);
    try testing.expectEqualStrings("/tmp/we\"ird\\name.txt", parsed.value.object.get("path").?.string);
}

test "an encoded body outside the base64 alphabet is refused, not emitted raw" {
    // The body is appended without escaping because the standard alphabet needs
    // none. This is the check that makes that claim true rather than assumed.
    const file = PickedFile{
        .name = @constCast("a.txt"),
        .path = @constCast("/tmp/a.txt"),
        .mime_type = @constCast("text/plain"),
        .base64 = @constCast("abc\"def"),
    };
    try testing.expectError(
        BridgeError.NativeCallFailed,
        shapePickedFile(testing.allocator, file),
    );
}

test "the saved path goes back as a bare JSON string, not an object" {
    // `resolveCallback` serialises with .fragmentsAllowed and Swift resolves
    // `fileURL.path`. An object here would be a shape nothing reads.
    const json = try shapeSavedPath(testing.allocator, "/var/mobile/Documents/notes.txt");
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("\"/var/mobile/Documents/notes.txt\"", json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .string);

    // And it is truthy: `craft-bridge.js` settles with `payload || {}`, so an
    // empty reply would arrive as `{}`. A container path is never empty.
    try testing.expect(parsed.value.string.len > 0);
}

test "a path needing escaping survives the bare-string reply" {
    const json = try shapeSavedPath(testing.allocator, "/tmp/we\"ird\\path.txt");
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/tmp/we\"ird\\path.txt", parsed.value.string);
}

// -----------------------------------------------------------------------------
// How a callback settles the call.
// -----------------------------------------------------------------------------

test "a cancel is a rejection, and only a read that succeeded resolves" {
    // The single most likely way this file could go wrong, and the one thing
    // that cannot be read off a picker in a test: Swift's
    // `documentPickerWasCancelled:` calls `rejectCallback(…, \"Cancelled\")`,
    // not a resolve, and an empty `urls` array is its `\"No file selected\"`
    // reject.
    try testing.expectEqual(Answer.resolve, answerFor(.picked));
    try testing.expectEqual(Answer.reject, answerFor(.cancelled));
    try testing.expectEqual(Answer.reject, answerFor(.no_selection));
    // Divergence 2: Swift resolves `{name, path}` here, without the `data` its
    // own type declares required.
    try testing.expectEqual(Answer.reject, answerFor(.unreadable));
    // The swipe-down belt. Nothing was picked, so a resolve would be success
    // for a pick that did not happen.
    try testing.expectEqual(Answer.reject, answerFor(.dismissed));

    // And every outcome is covered: a new one added without a row above would
    // otherwise be pinned by nothing.
    try testing.expectEqual(@as(usize, 5), std.enums.values(Outcome).len);
}

test "the swipe-down belt is registered, and only the answer paths reject" {
    // Without `presentationControllerDidDismiss:` on the delegate, a sheet the
    // user swipes away leaves `pending_pick` set: the call is never answered
    // *and* every later pickFile is refused for the life of the process. Two
    // sibling picker modules carry the same belt.
    try testing.expectEqualStrings("presentationControllerDidDismiss:", sel_did_dismiss);
    // `- (void)m:(id)presentationController` — one object, not two.
    try testing.expectEqualStrings("v@:@", ios_delegate.enc.void_one_object);
}

test "the two delegate selectors are the plural pair, with the encodings UIKit calls" {
    // A wrong encoding still registers and still dispatches, then reads
    // arguments from the wrong registers with no crash and no compile error.
    // Naming the shapes is the only defence available, so the pairing is pinned.
    try testing.expectEqualStrings("documentPicker:didPickDocumentsAtURLs:", sel_did_pick_documents);
    try testing.expectEqualStrings("documentPickerWasCancelled:", sel_was_cancelled);
    try testing.expectEqualStrings("v@:@@", ios_delegate.enc.void_two_objects);
    try testing.expectEqualStrings("v@:@", ios_delegate.enc.void_one_object);

    // And the deprecated singular is not one of them: registering it would give
    // two answers to one pick on any OS that still called it.
    try testing.expect(!std.mem.eql(u8, sel_did_pick_documents, "documentPicker:didPickDocumentAtURL:"));
}

test "the delegate class name is this module's own" {
    // Both this and any desktop registration look a class up with
    // `objc_getClass` first, so a shared name would let whichever registered
    // second silently adopt the other's IMPs.
    try testing.expectEqualStrings("CraftIOSDocumentPickerDelegate", delegate_class_name);
}

// -----------------------------------------------------------------------------
// One pending pick.
// -----------------------------------------------------------------------------

test "a second pick while one is presented is refused, never a silent replacement" {
    // Swift overwrites its single `pendingCallbackId` and the first caller's
    // promise never settles. The refusal is what makes every caller settle.
    try testing.expect(takePendingPick() == null);

    const first = ios_async.acquire(A.pick_file) orelse return error.PoolUnexpectedlyFull;
    defer ios_async.abandon(first);
    try testing.expect(publishPendingPick(first));

    const second = ios_async.acquire(A.pick_file) orelse return error.PoolUnexpectedlyFull;
    defer ios_async.abandon(second);
    try testing.expect(!publishPendingPick(second));

    // The first ticket is still the one a callback would answer — not the
    // second, and not nothing.
    const held = takePendingPick() orelse return error.PendingPickWasLost;
    try testing.expectEqual(first.index, held.index);
    try testing.expectEqual(first.generation, held.generation);

    // With the slot free, the next pick takes it.
    try testing.expect(publishPendingPick(second));
    try testing.expect(takePendingPick() != null);
    try testing.expect(takePendingPick() == null);
}

test "a callback with nothing pending is ignored rather than replying twice" {
    // A late fire, or a duplicate: `takePendingPick` cleared the slot on the
    // first one, so the second finds nothing. The belt is the ordinary case
    // here — UIKit can send `presentationControllerDidDismiss:` after a Cancel
    // that already answered, and it must be a no-op, not a second reply.
    try testing.expect(takePendingPick() == null);
    settlePick(.cancelled, null);
    settlePick(.dismissed, null);
    settlePick(.picked, "{}");
    try testing.expect(takePendingPick() == null);
}

test "downloadFile guards the container the same way saveFile does" {
    // Swift's downloadFile runs the same `appendingPathComponent` as saveFile
    // and does *not* validate, so "../Library/Preferences/x.plist" escapes the
    // container through the download path today. Guarding one entrance and not
    // the other is not a guard.
    try testing.expectError(BridgeError.InvalidParameter, validateFilename("../escape.plist"));
    try testing.expectError(BridgeError.InvalidParameter, validateFilename("a/b.txt"));
    try validateFilename("fine.txt");
}

test "downloadFile requires both fields and refuses empties" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"url\":\"https://a/b\",\"filename\":\"b.txt\"}",
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("https://a/b", try downloadField(root, "url"));
    try testing.expectEqualStrings("b.txt", try downloadField(root, "filename"));

    const empty = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"url\":\"\",\"filename\":7}",
        .{},
    );
    defer empty.deinit();
    try testing.expectError(BridgeError.InvalidParameter, downloadField(empty.value.object, "url"));
    try testing.expectError(BridgeError.InvalidParameter, downloadField(empty.value.object, "filename"));
    try testing.expectError(BridgeError.MissingData, downloadField(empty.value.object, "nope"));
}

test "each download block is global and has its own invoke" {
    if (!is_darwin) return error.SkipZigTest;

    for (&download_blocks) |*b| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, b.isa);
        try testing.expectEqual(DOWNLOAD_BLOCK_IS_GLOBAL, b.flags);
        try testing.expectEqual(@sizeOf(DownloadBlock), @as(usize, @intCast(b.descriptor.size)));
    }
    try testing.expect(download_blocks[0].invoke != download_blocks[1].invoke);
}

test "a download completion for a slot with no recorded call is ignored" {
    // Otherwise a second fire double-frees the parked filename.
    if (!is_darwin) return error.SkipZigTest;

    download_mutex.lock();
    for (&pending_downloads) |*entry| entry.* = null;
    download_mutex.unlock();

    downloadFinished(0, null, null);
    downloadFinished(0, null, null);
}

test "nothing in this family is unserved any more" {
    try testing.expectEqual(@as(usize, 0), deliberately_unserved.len);
    try testing.expect(routeFor("downloadFile") != null);
}
