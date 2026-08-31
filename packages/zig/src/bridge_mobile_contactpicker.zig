//! `pickContact` — present `CNContactPickerViewController` and answer with what
//! the user picked.
//!
//! One action, one payload field, and four delegate methods — Swift's three,
//! plus one belt for a dismissal Swift has no answer to. The Swift
//! original is `CraftApp.swift:969-973` (dispatch), `4301-4323` (presentation)
//! and `5088-5136` (the `CNContactPickerDelegate` extension plus
//! `formatContact`). Everything below is measured against those lines.
//!
//! ## The payload: one field, `multiple`
//!
//! The injected JS (`CraftApp.swift:1970-1978`) posts
//! `{action:'pickContact', multiple: options.multiple || false, callbackId: id}`,
//! so `multiple` is a **top-level** field of `d`. Note what `||` does and does
//! not do: it is not a boolean coercion, it is a fallback. `pickContact({multiple:1})`
//! puts the number `1` on the wire and `pickContact({multiple:'yes'})` puts the
//! string `"yes"`.
//!
//! Swift then reads `body["multiple"] as? Bool ?? false`. `as? Bool` on the
//! bridged `NSNumber` succeeds for exactly `0` and `1` (→ false/true) and
//! returns nil for `2`, for `0.5`, for a string, for anything else — which the
//! `?? false` turns into false. `multipleFrom` below is that rule, spelled out,
//! and it is pinned by tests rather than left to read like a coercion.
//!
//! There is **no other field**. `callbackId` is the shim's own correlation and
//! never reaches a Zig module — `ios_async` owns the request id here.
//!
//! **The page's promise has no timeout.** `pickContact` builds its `Promise`
//! by hand instead of going through `_createCallback` (`CraftApp.swift:1196`,
//! which carries the 30-second `setTimeout`). An unanswered call parks the page
//! forever, which is why every path in this file ends in a reply or an error.
//!
//! ## The replies, which are three different shapes
//!
//!   - **one contact** (`contactPicker:didSelectContact:`) resolves a JSON
//!     *object*: `{"id","givenName","familyName","displayName","phoneNumbers",
//!     "emailAddresses"}`, where `phoneNumbers` is an array of
//!     `{"label","number"}` and `emailAddresses` an array of
//!     `{"label","address"}`. Swift builds a `[String: Any]`, whose key order is
//!     a `Dictionary` and therefore arbitrary; one order is fixed here so the
//!     bytes are testable, the same call `bridge_mobile_notifications.zig`
//!     makes.
//!   - **many contacts** (`contactPicker:didSelectContacts:`) resolves a JSON
//!     *array* of those objects. `contacts.map` over an empty selection is `[]`,
//!     and that **resolves** — it is not an error and not a cancel.
//!     `test-bridges.html:1030` reads `contacts?.length`, so it must be an
//!     array.
//!   - **cancel** (`contactPickerDidCancel:`) **rejects**. This is the one
//!     action in this batch where a cancel is an error rather than a distinct
//!     resolve, so there is deliberately no `{"cancelled":true}` here — that
//!     would be a fabricated success for a pick that never happened.
//!
//! `packages/typescript/types/craft.d.ts:1157-1164` declares `Contact` with
//! `phoneNumbers: string[]` / `emailAddresses: string[]`. That matches
//! `getContacts` (flat `phone.value.stringValue` strings) and is **wrong for
//! this action**, which emits `{label, number}` / `{label, address}` dicts. The
//! runtime shape is the contract; `formatContact` is what is mirrored here, not
//! the type declaration.
//!
//! ## What diverges, stated rather than smoothed over
//!
//! **The cancel error text and code change.** Swift calls
//! `rejectCallback(id, error: "Cancelled")` with the default
//! `code: "CRAFT_ERROR"`, which reaches the page as
//! `{"error":true,"code":"CRAFT_ERROR",…,"message":"Cancelled"}`. Zig replies
//! through `ios_async.deliverError`, which is hard-wired to
//! `BridgeError.NativeCallFailed` → `code:"NATIVE_CALL_FAILED"`,
//! `message:"Native API call failed"`. The page's `catch` still runs and the
//! promise still settles, so nothing hangs and nothing is fabricated — but a
//! page that prints `err.message` (which `test-bridges.html:1022` does) shows
//! different text, and a page that branches on `err.code` sees a different code.
//!
//! This is the honest floor of the available channel, not a preference.
//! `bridge_error.BridgeError.Cancelled` → `CANCELLED` /
//! `"Operation was cancelled"` would be *nearer* the truth, and `ios_async` has
//! no way to send it: `deliverError` sets a `failed` flag and `deliverOnMain`
//! chooses `NativeCallFailed` for every flagged slot. Closing the gap is a
//! change to `ios_async.zig` — a `BridgeError` stored on the slot beside
//! `failed`, and `deliverOnMain` sending that instead of the constant — and it
//! belongs there rather than in a second reply path built here, because a
//! module that reached around `ios_async` would also be reaching around the
//! generation guard that stops a stale callback answering someone else's call.
//! Until then, "the native call failed" is what a cancel says, and saying so
//! here is the point.
//!
//! **`config.enableContacts` has no Zig mirror.** `ios.zig`'s `AppConfig` has
//! no such field — the same gap `bridge_mobile_system.zig` records for
//! `enableShare`. The Info.plist is read instead, and for this flag the mapping
//! is exact: `packages/ios/src/index.ts:189` writes `NSContactsUsageDescription`
//! if and only if `config.enableContacts`, with none of the sharing that made
//! the location keys ambiguous.
//!
//! Two things about that gate have to be said plainly. First, the key is **not
//! a precondition of the API**: `CNContactPickerViewController` runs out of
//! process and needs no Contacts authorization, so this reads the key purely as
//! *evidence of the flag*, never as something the framework requires. Second,
//! the behaviour changes: Swift's `case "pickContact":` has **no `else`**, so an
//! app built with `enableContacts: false` answers the page with *nothing*, on a
//! promise with no timeout — a hang for the life of the page. Here it is an
//! explicit `PERMISSION_DENIED`. Everybody settles, which is strictly better,
//! and it is a difference a page can observe.
//!
//! **No permission is requested, deliberately.** `pickContact` never touches
//! `CNContactStore` and never calls `requestAccess(for:.contacts)`; only
//! `getContacts` and `addContact` do. Adding one here would show the user a
//! prompt the shim never shows.
//!
//! **Nothing is dismissed, and that is a decision rather than an omission.**
//! What is *verified*: `CraftApp.swift` contains exactly five `dismiss(` calls —
//! `UIImagePickerController` (2643, 2662), the PDF viewer (4288, 4294) and the
//! data scanner (4873) — and none of them is in the contact-picker path. Swift's
//! three `CNContactPickerDelegate` methods return without dismissing anything.
//! What is *reasoned*: `CNContactPickerViewController` is an out-of-process
//! remote view controller, which is the standard explanation for why it takes
//! itself down on both Done and Cancel and why its delegate protocol asks for no
//! dismissal.
//!
//! So this file matches the shim exactly, and matching it is the conservative
//! choice in both directions. Adding a dismissal would be a *second* dismissal
//! of a controller already dismissing, and sent to the presenter it would take
//! down whatever else happened to be modal — a new bug, in an action the shim
//! answers. Omitting it can only reproduce a defect the shim already has. This
//! is the one place where the generic picker rule "the delegate must dismiss"
//! does not apply; the image and document pickers are `UIImagePickerController`
//! and `UIDocumentPickerViewController`, both in-process, both of which do need
//! it.
//!
//! Not verified on a device from here: that the picker really does disappear
//! without help. If it turns out not to, the fix is one `dismiss` sent to the
//! *picker* (never the presenter) from each of the picker callbacks.
//!
//! **A contact whose keys were not fetched still crashes.** Touching an
//! unfetched property raises `CNContactPropertyNotFetchedException`, which from
//! Zig is an uncatchable SIGABRT. Swift cannot catch `NSException` either, so
//! this is exact parity with the shim rather than a regression — and there is
//! deliberately no comment below claiming a guard against it, because there
//! isn't one.
//!
//! ## Concurrency: one picker, one ticket, and a refusal that says so
//!
//! Swift keeps a single `pendingCallbackId` (line 383) shared by *every* picker
//! in the coordinator — camera, document, NFC, Bluetooth, contacts. Opening any
//! second picker overwrites it and the first promise never settles. This module
//! keeps its own ticket, and when a second `pickContact` arrives while one is on
//! screen it **refuses the second and leaves the first alone**: the first picker
//! is still presented and will still answer, so displacing it would strand a
//! call that was about to succeed.
//!
//! What that costs, said rather than hidden: the slot is cleared only by a
//! delegate callback. A picker that is never presented, or presented and then
//! never answered, leaves the slot held for the life of the process and refuses
//! every later call. Two causes are known, and they are not both removed:
//!
//!   - **Presenting on a controller that is already presenting**, which UIKit
//!     answers by logging and doing nothing. That one is removed:
//!     `bridge_mobile_system.uikit.topmostViewController()`'s walk up
//!     `presentedViewController` is why this file reuses that function rather
//!     than copying Swift's `windows.first?.rootViewController`
//!     (`CraftApp.swift:4303-4304`), which has the bug.
//!   - **A swipe-down dismissal.** The picker is a sheet on iOS 13+, and an
//!     interactive dismissal is widely reported not to call
//!     `contactPickerDidCancel:` — the same report
//!     `bridge_mobile_imagepicker.zig` carries a belt for, and one this repo
//!     verifies on no device. `presentationControllerDidDismiss:` is that belt
//!     here too: it is registered on the delegate, and the picker's
//!     presentation controller is pointed at that delegate before presenting,
//!     so a swipe rejects the call instead of stranding it. Belt, not fix —
//!     UIKit sends it only for a user-driven dismissal, so it cannot fire after
//!     a pick or a Cancel that already answered, and if the report is wrong it
//!     costs two messages. The one case it does not cover is a presentation
//!     controller that already carries a delegate of its own, which is left
//!     alone rather than displaced; that is logged where it happens rather than
//!     assumed away.
//!
//! No reply is ever sent from a delegate callback directly. `ios_async` is the
//! only channel, and the main-queue hop it performs is not merely thread
//! safety: it is what restores the `request_context` captured at dispatch, so
//! the reply names the call that is waiting instead of falling back to
//! action-name matching.

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
/// location/notifications precedent: `objc_runtime.objc` is an empty struct off
/// Darwin and a function *signature* is analysed even when a comptime platform
/// guard prunes the body, so naming `objc.id` in the `callconv(.c)` types below
/// would break the host build. A single optional pointer, never `?objc.id` — a
/// double optional is illegal in `callconv(.c)`.
const Id = ?*anyopaque;

/// The action name, spelled exactly as the Swift `case` label spells it.
/// `test/ios_conformance_test.zig` matches this block against those labels in
/// both directions, and fails the build if two modules declare one name.
pub const A = struct {
    pub const pick_contact = "pickContact";
};

/// `.result`: every Swift path out of this action terminates in exactly one
/// `resolveCallback` (either `didSelect` overload) or one `rejectCallback`
/// (cancel). `.none` would be a claim that nothing answers, and on this
/// particular promise — hand-built, no `setTimeout` — that is a page parked
/// forever rather than for thirty seconds.
///
/// `.live`, not `.unavailable`: in an app built with `enableContacts` the
/// picker presents and answers. A refusal here is always a specific condition
/// (contacts not configured, ContactsUI not linked, a picker already on screen,
/// the async pool full), never this action's normal answer.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.pick_contact, .reply = .result },
};

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host without touching
/// ContactsUI.
const Route = enum { pick_contact };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.pick_contact)) return .pick_contact;
    return null;
}

pub const ContactPickerBridge = struct {
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
            .pick_contact => self.pickContact(data),
        };
    }

    /// Present the contact picker and hand the answer to the delegate.
    ///
    /// Ordering is load-bearing in two places. The payload is parsed *first*, so
    /// a malformed body is reported the same on any platform and before any
    /// framework is consulted. And every fallible step — the Info.plist gate,
    /// both framework classes, every selector a delegate callback or the
    /// swipe-down belt will need, the delegate class, the presenter, the
    /// predicate, the picker itself — runs **before** `ios_async.acquire`.
    /// Exactly one path leaves this function after the lease without presenting
    /// — the concurrency refusal — and it releases the slot with
    /// `ios_async.abandon` on its way out. Every other statement between the
    /// lease and `presentViewController:` is infallible. That is the property
    /// being protected: a lease that escapes without either a presentation or an
    /// `abandon` narrows the pool for the life of the process.
    fn pickContact(self: *Self, data: []const u8) !void {
        const multiple = try parseMultiple(self.allocator, data);

        if (!is_darwin) return error.UnsupportedPlatform;

        try requireContactsConfigured();

        // ContactsUI first, Contacts second, each guarded on its own: a process
        // that linked Contacts but not ContactsUI is a real configuration, and
        // the fixture (`packages/ios/fixtures/zig-slice/build-and-run.sh:65`)
        // links neither. Naming the missing class beats a generic failure,
        // because the fix is a link line rather than anything in this file.
        const PickerClass = objc.objc_getClass("CNContactPickerViewController") orelse {
            std.log.err(
                "pickContact refused: this process has no CNContactPickerViewController; " ++
                    "ContactsUI.framework is not linked",
                .{},
            );
            return bridge_error.BridgeError.PlatformNotSupported;
        };

        const sels = try Sels.resolve();
        const delegate = try ensureDelegate();

        // The walk up `presentedViewController` is the part Swift is missing —
        // see the module comment. It also matters to the refusal policy: one of
        // the two known ways to leave a ticket unanswered forever is a
        // presentation UIKit silently declines because the target is already
        // presenting, and the walk is what stops this file ever asking for that.
        // The other — a swipe-down that sends no delegate callback — is what
        // `attachDismissObserver` below is for.
        const presenter = try bridge_mobile_system.uikit.topmostViewController();

        const NSPredicate = objc.objc_getClass("NSPredicate") orelse return error.ClassNotFound;
        const sel_predicate_with_value = try selector("predicateWithValue:");
        const sel_set_delegate = try selector("setDelegate:");
        const sel_set_enabling = try selector("setPredicateForEnablingContact:");
        const sel_set_selection = try selector("setPredicateForSelectionOfContact:");
        const sel_present = try selector("presentViewController:animated:completion:");
        // The swipe-down belt's two reads, resolved here with everything else:
        // a missing selector then fails the call rather than silently leaving
        // the only thing that answers an interactive dismissal unattached.
        const dismiss_sels = DismissSels{
            .presentation = try selector("presentationController"),
            .delegate = try selector("delegate"),
            .set_delegate = sel_set_delegate,
        };

        // `+[NSPredicate predicateWithValue:]` takes a `BOOL`, so the cast has
        // to name that argument; `msgSendId1` builds the signature from
        // `@TypeOf(arg1)` and `true` is a Zig `bool`, which is what `B` is on
        // 64-bit Apple platforms.
        const always_true = objc.msgSendId1(NSPredicate, sel_predicate_with_value, true) orelse
            return error.NativeCallFailed;

        const picker = (try objc.allocInit(PickerClass)) orelse return error.NativeCallFailed;
        // `allocInit` gave us +1. `presentViewController:` retains the picker for
        // the life of the presentation, so ours is the reference to drop — and
        // on the refusal paths below it is the only one there is. Same shape as
        // the share sheet's `defer objc.release(activity_vc)`.
        defer objc.release(picker);

        objc.msgSendVoid1(picker, sel_set_delegate, delegate);
        objc.msgSendVoid1(picker, sel_set_enabling, always_true);

        if (multiple) {
            // Swift's `picker.predicateForSelectionOfContact = nil`. The
            // `@as(objc.id, null)` is required: an untyped `null` gives
            // `msgSendVoid1` no argument type to build a signature from.
            objc.msgSendVoid1(picker, sel_set_selection, @as(objc.id, null));
        } else {
            // Swift builds a second `NSPredicate(value: true)` here. One
            // instance serves both properties identically — `NSPredicate` is
            // immutable and neither property mutates it — so the object graph
            // is the same one Swift assembles in two allocations.
            objc.msgSendVoid1(picker, sel_set_selection, always_true);
        }

        // Attached before presenting, because that is when a presentation
        // controller can be configured, and retried after `presentViewController:`
        // for the case where UIKit only builds one there. Infallible either way:
        // it returns whether it took, and never fails the call.
        var dismiss_observed = attachDismissObserver(picker, delegate, dismiss_sels);

        const ticket = ios_async.acquire(A.pick_contact) orelse return poolFull();

        // Published *before* the framework call, never after: a delegate that
        // somehow reached an empty slot would have no ticket to reply with. The
        // publish is also the concurrency check, done under one lock so two
        // dispatches cannot both find the slot free.
        if (!publishPending(.{ .ticket = ticket, .sels = sels })) {
            ios_async.abandon(ticket);
            return alreadyPresented();
        }

        const PresentFn = *const fn (Id, Id, Id, bool, Id) callconv(.c) void;
        const present_fn: PresentFn = @ptrCast(&objc.objc_msgSend);
        // Completion handler nil, as Swift's `present(picker, animated: true)`
        // passes none. There is nothing to do on presentation-complete: the
        // answer comes from the delegate.
        present_fn(presenter, sel_present, picker, true, null);

        if (!dismiss_observed) dismiss_observed = attachDismissObserver(picker, delegate, dismiss_sels);
        if (!dismiss_observed) {
            std.log.warn(
                "pickContact: the picker's presentation controller could not be observed " ++
                    "(absent, or already carrying a delegate this file will not displace); " ++
                    "if a swipe-down dismissal does not send contactPickerDidCancel: then " ++
                    "this call stays unanswered and every later one is refused",
                .{},
            );
        }
    }
};

/// The answer for a full block pool, copied from `bridge_mobile_location`:
/// `BridgeError` has no "Busy", `INVALID_PARAMETER` is the migration notes'
/// designated stand-in, and the point is that the caller gets an explicit
/// rejection instead of a promise that never settles.
fn poolFull() bridge_error.BridgeError {
    std.log.warn(
        "pickContact refused: all {d} async slots are in flight",
        .{ios_async.max_in_flight},
    );
    return bridge_error.BridgeError.InvalidParameter;
}

/// The answer for a second `pickContact` while one is on screen.
///
/// Deliberately *not* displacement. `bridge_mobile_location.zig` rejects the
/// displaced first caller because CoreLocation's one-shot may genuinely never
/// answer; a presented picker is the opposite situation — it is on screen, the
/// user is looking at it, and it will answer. Refusing the newcomer keeps that
/// promise alive. Swift does neither: it overwrites `pendingCallbackId` and the
/// first caller waits forever on an untimed promise.
///
/// Same `INVALID_PARAMETER` stand-in as `poolFull`, for the same reason —
/// `BridgeError` has no word for "busy" — with a log line that says which of
/// the two happened.
fn alreadyPresented() bridge_error.BridgeError {
    std.log.warn(
        "pickContact refused: a contact picker is already presented and still waiting for an " ++
            "answer; the first call is left alone rather than being stranded",
        .{},
    );
    return bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// Payload parsing. Pure — no Objective-C — so the exact coercion Swift performs
// is pinned by host tests on every platform.
// =============================================================================

/// `multiple`, read the way `body["multiple"] as? Bool ?? false` reads it.
///
/// A malformed or non-object `d` is `InvalidJSON` rather than a silent `false`.
/// It is a Zig-only failure mode — `WKScriptMessage.body` is always a
/// dictionary, so Swift never meets it — but guessing `false` for a body that
/// could not be read would be acting on a default the page did not send.
fn parseMultiple(allocator: std.mem.Allocator, data: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return bridge_error.BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    return multipleFrom(root.get("multiple"));
}

/// The `as? Bool ?? false` rule, as a total function.
///
/// `options.multiple || false` in the injected JS is a fallback, not a
/// coercion, so anything truthy reaches the wire unchanged: `1`, `"yes"`, `{}`.
/// Swift's bridged `NSNumber as? Bool` then succeeds for exactly `0` and `1`
/// and yields nil for everything else, which `?? false` collapses to false. So
/// `pickContact({multiple: 2})` and `pickContact({multiple: 'yes'})` both open
/// a *single*-selection picker, and reproducing that is the contract — reading
/// them as "truthy, therefore multiple" would open a different picker than the
/// shim opens for the same call.
fn multipleFrom(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i == 1,
        // `NSNumber(value: 1.0) as? Bool` is true, `0.5` is nil. Only an exact
        // 1 is a yes.
        .float => |f| f == 1.0,
        // A string, an array, an object, JSON null, or a number too large for
        // an i64 (`number_string`). None of them survive `as? Bool`.
        else => false,
    };
}

// =============================================================================
// Reply shaping. Pure — no Objective-C — so the exact bytes the page receives
// are pinned by host tests.
// =============================================================================

/// One `CNLabeledValue`, flattened.
///
/// `value` is the phone number's `stringValue` or the email address; which wire
/// key it lands under — `number` or `address` — is decided by the writer, not
/// stored here, because `formatContact` uses two different key names for the
/// same shape and getting them swapped is silent.
const Labeled = struct {
    label: []const u8,
    value: []const u8,
};

/// One contact, exactly as `formatContact` assembles it.
///
/// The strings borrow whatever buffer they were read from. On the native path
/// that is an `NSString`'s internal UTF-8 buffer, valid for the delegate
/// callback's autorelease pool, and every one of them is copied into the JSON
/// before the callback returns.
const Contact = struct {
    id: []const u8,
    given_name: []const u8,
    family_name: []const u8,
    display_name: []const u8,
    phones: []const Labeled,
    emails: []const Labeled,
};

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    try out.append(allocator, '"');
    // A contact's name, label and number are user data and will contain `"` and
    // `\` in the wild. This reply is replayed into the source
    // `evaluateJavaScript:` parses, so an unescaped quote is a syntax error in
    // the page rather than a wrong field.
    try bridge_error.appendJsonEscaped(allocator, out, s);
    try out.append(allocator, '"');
}

fn appendLabeledArray(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    items: []const Labeled,
    comptime value_key: []const u8,
) !void {
    try out.append(allocator, '[');
    for (items, 0..) |item, i| {
        if (i != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"label\":");
        try appendJsonString(allocator, out, item.label);
        try out.appendSlice(allocator, ",\"" ++ value_key ++ "\":");
        try appendJsonString(allocator, out, item.value);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
}

/// One contact as a JSON object, in a fixed key order.
///
/// Swift's `[String: Any]` has no order at all; fixing one here is what makes
/// the bytes testable. The two `value_key` spellings are the part worth
/// watching: phones are `number`, emails are `address`, and `formatContact` is
/// the only authority for that.
fn appendContact(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    contact: Contact,
) !void {
    try out.appendSlice(allocator, "{\"id\":");
    try appendJsonString(allocator, out, contact.id);
    try out.appendSlice(allocator, ",\"givenName\":");
    try appendJsonString(allocator, out, contact.given_name);
    try out.appendSlice(allocator, ",\"familyName\":");
    try appendJsonString(allocator, out, contact.family_name);
    try out.appendSlice(allocator, ",\"displayName\":");
    try appendJsonString(allocator, out, contact.display_name);
    try out.appendSlice(allocator, ",\"phoneNumbers\":");
    try appendLabeledArray(allocator, out, contact.phones, "number");
    try out.appendSlice(allocator, ",\"emailAddresses\":");
    try appendLabeledArray(allocator, out, contact.emails, "address");
    try out.append(allocator, '}');
}

/// The `didSelectContact:` reply: a bare object.
fn shapeContact(allocator: std.mem.Allocator, contact: Contact) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendContact(allocator, &out, contact);
    return out.toOwnedSlice(allocator);
}

/// The `didSelectContacts:` reply: an array of objects.
///
/// An empty selection is `[]`, which **resolves**. `contacts.map` over an empty
/// array is `[]` in Swift and `test-bridges.html` reads `.length` off it, so
/// turning "nothing selected" into an error or a cancel would break a path the
/// shim answers successfully.
fn shapeContacts(allocator: std.mem.Allocator, contacts: []const Contact) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '[');
    for (contacts, 0..) |contact, i| {
        if (i != 0) try out.append(allocator, ',');
        try appendContact(allocator, &out, contact);
    }
    try out.append(allocator, ']');

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Objective-C: everything looked up once at dispatch, then a walk that cannot
// look anything up.
// =============================================================================

/// The Info.plist key `packages/ios/src/index.ts:189` writes if and only if
/// `config.enableContacts`.
const key_contacts_usage = "NSContactsUsageDescription";

/// `NSUTF8StringEncoding`. Used only to ask a string how long it really is, so
/// a NUL-truncated read can be told from a short string.
const ns_utf8_string_encoding: c_ulong = 4;

/// `CNContactFormatterStyleFullName`. A header enum constant with `FullName = 0`
/// and `PhoneticFullName = 1`, so this one is safe to spell out rather than
/// `dlsym`.
const cn_contact_formatter_style_full_name: c_long = 0;

fn selector(name: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.sel_registerName(name) orelse error.SelectorNotFound;
}

/// The main bundle's Info.plist value for `key`, or null when it has none.
///
/// Errors rather than answering null when the runtime itself will not
/// cooperate: "there is no NSBundle class" and "this app was not built with
/// contacts enabled" are different facts, and collapsing them would blame the
/// app's configuration for a broken process. Same shape as
/// `bridge_mobile_location.zig`'s gate, which is private to that file.
fn infoPlistValue(comptime key: [*:0]const u8) !Id {
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
    return objc.msgSendId1(bundle, sel_lookup, ns_key);
}

/// Refuse when the app was not built with `enableContacts`.
///
/// Checked first, matching Swift's `if config.enableContacts` guarding the whole
/// case. The key is evidence of that flag and nothing more — see the module
/// comment: `CNContactPickerViewController` needs no Contacts authorization, so
/// this is not the framework's precondition being enforced.
fn requireContactsConfigured() !void {
    if (!is_darwin) return error.UnsupportedPlatform;

    if ((try infoPlistValue(key_contacts_usage)) == null) {
        std.log.warn(
            "pickContact refused: Info.plist has no {s}, so this app was not built with " ++
                "contacts enabled",
            .{key_contacts_usage},
        );
        return bridge_error.BridgeError.PermissionDenied;
    }
}

/// Everything a delegate callback needs, resolved while a synchronous error can
/// still reach the page.
///
/// The callbacks run long after the dispatch frame is gone, where a failed
/// `sel_registerName` could only be logged. Resolving here turns that whole
/// class of failure into an ordinary rejection.
///
/// Two *class* objects ride along for the same reason. `CNContactFormatter` and
/// `CNLabeledValue` are used as receivers of class methods
/// (`stringFromContact:style:`, `localizedStringForLabel:`), so a missing
/// Contacts.framework has to be found here rather than inside the callback.
/// They are guarded separately from `CNContactPickerViewController` because
/// they come from a different framework.
const Sels = struct {
    // Contacts.framework classes, as receivers of class methods.
    formatter_class: Id,
    labeled_value_class: Id,
    string_class: Id,

    // NSArray
    count: Id,
    object_at: Id,

    // CNContact
    identifier: Id,
    given_name: Id,
    family_name: Id,
    phone_numbers: Id,
    email_addresses: Id,

    // CNContactFormatter (class method)
    string_from_contact: Id,

    // CNLabeledValue. One class, not two: the Swift generics
    // `CNLabeledValue<CNPhoneNumber>` and `CNLabeledValue<NSString>` are the
    // same Objective-C class.
    label: Id,
    value: Id,
    localized_string_for_label: Id,

    // CNPhoneNumber
    string_value: Id,

    // NSString
    empty_string: Id,
    utf8: Id,
    length_of_bytes: Id,

    fn resolve() !Sels {
        if (!is_darwin) return error.UnsupportedPlatform;

        const formatter = objc.objc_getClass("CNContactFormatter") orelse {
            std.log.err(
                "pickContact refused: this process has no CNContactFormatter; " ++
                    "Contacts.framework is not linked",
                .{},
            );
            return bridge_error.BridgeError.PlatformNotSupported;
        };
        const labeled = objc.objc_getClass("CNLabeledValue") orelse {
            std.log.err(
                "pickContact refused: this process has no CNLabeledValue; " ++
                    "Contacts.framework is not linked",
                .{},
            );
            return bridge_error.BridgeError.PlatformNotSupported;
        };
        const string_class = objc.objc_getClass("NSString") orelse return error.ClassNotFound;

        return .{
            .formatter_class = formatter,
            .labeled_value_class = labeled,
            .string_class = string_class,

            .count = try selector("count"),
            .object_at = try selector("objectAtIndex:"),

            .identifier = try selector("identifier"),
            .given_name = try selector("givenName"),
            .family_name = try selector("familyName"),
            .phone_numbers = try selector("phoneNumbers"),
            .email_addresses = try selector("emailAddresses"),

            .string_from_contact = try selector("stringFromContact:style:"),

            .label = try selector("label"),
            .value = try selector("value"),
            .localized_string_for_label = try selector("localizedStringForLabel:"),

            .string_value = try selector("stringValue"),

            .empty_string = try selector("string"),
            .utf8 = try selector("UTF8String"),
            .length_of_bytes = try selector("lengthOfBytesUsingEncoding:"),
        };
    }
};

/// One `NSString` as bytes, or a refusal.
///
/// The truncation check is why this is not one line. `UTF8String` hands back a
/// NUL-terminated buffer, so a value containing U+0000 — which
/// `JSONSerialization` would have preserved on the Swift side — reads back as
/// its prefix. `lengthOfBytesUsingEncoding:` counts the real encoded bytes, so a
/// mismatch is exactly that case, and reporting a prefix as the whole name is
/// the one thing worse than failing.
///
/// The returned slice borrows the string's internal buffer, valid for the
/// current autorelease pool; every caller copies it into the reply before
/// returning.
fn readString(ns: Id, sels: Sels) ![]const u8 {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (ns == null) return error.NilNativeString;

    const Utf8Fn = *const fn (Id, Id) callconv(.c) ?[*:0]const u8;
    const utf8: Utf8Fn = @ptrCast(&objc.objc_msgSend);
    const cstr = utf8(ns, sels.utf8) orelse return error.NativeCallFailed;
    const text = std.mem.span(cstr);

    const LenFn = *const fn (Id, Id, c_ulong) callconv(.c) c_ulong;
    const len_of: LenFn = @ptrCast(&objc.objc_msgSend);
    if (len_of(ns, sels.length_of_bytes, ns_utf8_string_encoding) != text.len) {
        return error.EmbeddedNulInNativeString;
    }

    return text;
}

/// `[[NSString string]]` — an empty, autoreleased `NSString`.
///
/// Needed because `CNLabeledValue.label` is nullable and Swift passes `""` in
/// its place (`phone.label ?? ""`) before asking for the localized form. Passing
/// nil instead would be a different call than the one being ported.
fn emptyString(sels: Sels) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.msgSendId(sels.string_class, sels.empty_string) orelse error.NativeCallFailed;
}

/// `+[CNLabeledValue localizedStringForLabel:]` on `labeled.label ?? ""`.
fn readLocalizedLabel(labeled: Id, sels: Sels) ![]const u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const raw = objc.msgSendId(labeled, sels.label) orelse try emptyString(sels);
    const localized = objc.msgSendId1(sels.labeled_value_class, sels.localized_string_for_label, raw) orelse
        return error.NativeCallFailed;
    return readString(localized, sels);
}

/// Which kind of `CNLabeledValue` array is being walked.
///
/// The two differ in exactly one step: a phone's `value` is a `CNPhoneNumber`
/// and needs `stringValue`, while an email's `value` already *is* an
/// `NSString`. Sending `stringValue` to an `NSString` would be an unrecognised
/// selector, which is a SIGABRT rather than an error to map — so this is an
/// enum rather than an optional selector that could arrive null.
const LabeledKind = enum { phone, email };

/// Walk an `NSArray<CNLabeledValue *>` into `Labeled` entries.
fn readLabeledValues(
    allocator: std.mem.Allocator,
    array: Id,
    sels: Sels,
    comptime kind: LabeledKind,
) ![]Labeled {
    if (!is_darwin) return error.UnsupportedPlatform;
    // Both `phoneNumbers` and `emailAddresses` are declared non-null and answer
    // an empty array for a contact with none. A nil here would mean the
    // framework broke its own contract, and "this contact has no numbers" is a
    // claim there would be no basis for.
    if (array == null) return error.NativeCallFailed;

    const CountFn = *const fn (Id, Id) callconv(.c) c_ulong;
    const count_of: CountFn = @ptrCast(&objc.objc_msgSend);
    const total = count_of(array, sels.count);

    var out: std.ArrayListUnmanaged(Labeled) = .empty;
    errdefer out.deinit(allocator);

    var i: c_ulong = 0;
    while (i < total) : (i += 1) {
        const entry = objc.msgSendId1(array, sels.object_at, i) orelse return error.NativeCallFailed;

        const label = try readLocalizedLabel(entry, sels);

        const raw_value = objc.msgSendId(entry, sels.value) orelse return error.NativeCallFailed;
        const string_value = switch (kind) {
            .phone => objc.msgSendId(raw_value, sels.string_value) orelse
                return error.NativeCallFailed,
            .email => raw_value,
        };

        try out.append(allocator, .{ .label = label, .value = try readString(string_value, sels) });
    }

    return out.toOwnedSlice(allocator);
}

/// Read one `CNContact` the way `formatContact` reads it.
///
/// `displayName` is the one field where nil is expected and is *not* a failure:
/// `CNContactFormatter.string(from:style:)` returns `String?` and Swift coalesces
/// it with `?? ""`. Every other field is declared non-null — `identifier`,
/// `givenName` and `familyName` answer `@""` for an unset name — so nil there is
/// a broken read and is refused rather than papered over with an empty string.
fn readContact(allocator: std.mem.Allocator, contact: Id, sels: Sels) !Contact {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (contact == null) return error.NativeCallFailed;

    const FormatFn = *const fn (Id, Id, Id, c_long) callconv(.c) Id;
    const format: FormatFn = @ptrCast(&objc.objc_msgSend);
    const formatted = format(
        sels.formatter_class,
        sels.string_from_contact,
        contact,
        cn_contact_formatter_style_full_name,
    );

    const phones = try readLabeledValues(
        allocator,
        objc.msgSendId(contact, sels.phone_numbers),
        sels,
        .phone,
    );
    errdefer allocator.free(phones);

    const emails = try readLabeledValues(
        allocator,
        objc.msgSendId(contact, sels.email_addresses),
        sels,
        .email,
    );
    errdefer allocator.free(emails);

    return .{
        .id = try readString(objc.msgSendId(contact, sels.identifier), sels),
        .given_name = try readString(objc.msgSendId(contact, sels.given_name), sels),
        .family_name = try readString(objc.msgSendId(contact, sels.family_name), sels),
        // Swift's `?? ""`, and only here.
        .display_name = if (formatted == null) "" else try readString(formatted, sels),
        .phones = phones,
        .emails = emails,
    };
}

/// Release the two slices `readContact` allocated. The strings inside are
/// borrowed from Objective-C and are not ours to free.
fn freeContact(allocator: std.mem.Allocator, contact: Contact) void {
    allocator.free(contact.phones);
    allocator.free(contact.emails);
}

// =============================================================================
// The delegate class, built at runtime.
// =============================================================================

/// Deliberately distinct from every other class this process registers. The
/// factory looks a name up before allocating, so two files sharing a name would
/// mean whichever registered second silently adopts the other's IMPs.
const delegate_class_name = "CraftIOSContactPickerDelegate";

/// The delegate instance, held for the life of the process.
///
/// `CNContactPickerViewController` holds its delegate **weakly**;
/// `ios_delegate.instantiate` hands back a +1 object and does not keep it. This
/// var is the strong reference, and dropping it would be a use-after-free the
/// first time the user taps Cancel — not a leak.
var delegate_instance: Id = null;

/// Every method the delegate class carries, always all of them.
///
/// All three of Swift's `CNContactPickerDelegate` methods are here.
/// `contactPicker:didSelectContacts:` is the plural selector Swift's
/// `didSelect contacts: [CNContact]` compiles to and is the entire
/// `multiple:true` reply path — the runtime dispatches delegate methods through
/// `respondsToSelector:`, so omitting it would be a silent no-op and a stranded
/// promise. `presentationControllerDidDismiss:` is the fourth and is not
/// Swift's: it belongs to `UIAdaptivePresentationControllerDelegate` and is the
/// swipe-down belt `attachDismissObserver` installs. Neither protocol is
/// declared on the class, because `respondsToSelector:` is what UIKit actually
/// asks — the same call `bridge_mobile_imagepicker.zig` records.
///
/// One fixed set rather than a per-call one: `defineClass` is idempotent by
/// name, so varying the methods would mean inventing a second class.
fn delegateMethods() [4]ios_delegate.Method {
    return .{
        // - (void)contactPicker:(CNContactPickerViewController *)picker
        //             didSelectContact:(CNContact *)contact
        .{
            .selector = "contactPicker:didSelectContact:",
            .imp = @ptrCast(&didSelectContact),
            .types = ios_delegate.enc.void_two_objects,
        },
        // - (void)contactPicker:(CNContactPickerViewController *)picker
        //             didSelectContacts:(NSArray<CNContact *> *)contacts
        .{
            .selector = "contactPicker:didSelectContacts:",
            .imp = @ptrCast(&didSelectContacts),
            .types = ios_delegate.enc.void_two_objects,
        },
        // - (void)contactPickerDidCancel:(CNContactPickerViewController *)picker
        .{
            .selector = "contactPickerDidCancel:",
            .imp = @ptrCast(&didCancel),
            .types = ios_delegate.enc.void_one_object,
        },
        // - (void)presentationControllerDidDismiss:(UIPresentationController *)pc
        // The swipe-down belt. iOS 13+; on anything older it is never sent.
        .{
            .selector = "presentationControllerDidDismiss:",
            .imp = @ptrCast(&didDismissInteractively),
            .types = ios_delegate.enc.void_one_object,
        },
    };
}

/// Register the class once and keep one instance alive.
fn ensureDelegate() !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (delegate_instance) |existing| return existing;

    const methods = delegateMethods();
    const cls = try ios_delegate.defineClass(delegate_class_name, "NSObject", &methods);

    const instance = (try ios_delegate.instantiate(cls)) orelse return error.NativeCallFailed;
    delegate_instance = instance;
    return instance;
}

/// The three selectors the swipe-down belt needs, resolved at dispatch.
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
/// `CNContactPickerViewController` presents as a sheet on iOS 13+, and a
/// swipe-down is widely reported not to send `contactPickerDidCancel:`. That
/// report is verified on no device in this repo, so this is a belt and not a
/// fix: it costs two messages, and if the report is right it is the only thing
/// that ever frees `pending` after a swipe. It matters more here than in Swift,
/// because this module *refuses* later calls while one is pending — a stranded
/// ticket disables `pickContact` for the life of the process, where Swift
/// merely strands the one promise.
///
/// A presentation controller that already carries a delegate is left alone and
/// reported as not attached: displacing one would change how the picker manages
/// its own adaptive presentation, which is a new bug in exchange for a belt.
///
/// Idempotent against the real cancel. UIKit sends
/// `presentationControllerDidDismiss:` only for a user-driven dismissal, never
/// for a programmatic one, so it cannot follow a pick or a Cancel that already
/// answered — and if it did anyway, `takePending` has already emptied the slot
/// and `ios_async`'s generation counter would drop the second delivery.
fn attachDismissObserver(picker: Id, delegate: Id, sels: DismissSels) bool {
    if (!is_darwin) return false;

    const presentation = objc.msgSendId(picker, sels.presentation) orelse return false;
    if (objc.msgSendId(presentation, sels.delegate) != null) return false;

    objc.msgSendVoid1(presentation, sels.set_delegate, delegate);
    return true;
}

// =============================================================================
// One ticket, one picker, one mutex.
//
// A picker is modal and serves exactly one call, so unlike the location
// one-shot there is never a reason to displace: while `pending` is set the
// picker is on screen and the user is looking at it. The mutex is held even
// though UIKit delivers these callbacks on the main thread, because "it should
// always be the main thread" is not a guard.
// =============================================================================

const Pending = struct {
    ticket: ios_async.Ticket,
    sels: Sels,
};

var pending: ?Pending = null;
var pending_mutex: compat_mutex.Mutex = .{};

/// Record the call the delegate will answer. False means one is already
/// recorded, and the caller must refuse rather than overwrite — an overwrite
/// would strand a promise that was about to be settled.
fn publishPending(call: Pending) bool {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    if (pending != null) return false;
    pending = call;
    return true;
}

/// Read and clear. Clearing is what makes a second delegate call — a duplicate
/// fire, a cancel that races a selection — a no-op rather than a second reply
/// to a promise that has already settled.
fn takePending() ?Pending {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const call = pending;
    pending = null;
    return call;
}

// =============================================================================
// The delegate methods.
//
// None replies directly: `evaluateJavaScript` is main-thread-only *and* the
// `request_context` that names the waiting call is long gone, so the finished
// JSON goes to `ios_async.deliverJson` (or `deliverError`), which hops to the
// main queue and answers under the id captured back at dispatch.
//
// Plain `fn`, never `export`: `@ptrCast(&f)` works either way and an exported
// name could collide with a desktop module in the same host-test binary.
//
// No `dismissViewControllerAnimated:` in any of them. See the module comment —
// `CNContactPickerViewController` is a remote view controller that takes itself
// down, Swift dismisses it nowhere, and a second dismissal would target
// whatever else is modal. `didDismissInteractively` observes a dismissal the
// user performed; it never asks for one.
// =============================================================================

fn didSelectContact(_: Id, _: Id, _: Id, contact: Id) callconv(.c) void {
    if (!is_darwin) return;

    const call = takePending() orelse {
        std.log.warn(
            "pickContact: a contact was selected with no request waiting; ignored rather than " ++
                "answered to whoever holds the slot next",
            .{},
        );
        return;
    };

    const allocator = std.heap.c_allocator;

    const one = readContact(allocator, contact, call.sels) catch |err| {
        std.log.err(
            "pickContact: could not read the selected CNContact ({}); rejecting rather than " ++
                "replying with a contact that was not read",
            .{err},
        );
        ios_async.deliverError(call.ticket);
        return;
    };
    defer freeContact(allocator, one);

    const json = shapeContact(allocator, one) catch |err| {
        std.log.err("pickContact: could not shape the contact reply ({}); rejecting", .{err});
        ios_async.deliverError(call.ticket);
        return;
    };
    defer allocator.free(json);

    ios_async.deliverJson(call.ticket, json);
}

fn didSelectContacts(_: Id, _: Id, _: Id, contacts: Id) callconv(.c) void {
    if (!is_darwin) return;

    const call = takePending() orelse {
        std.log.warn(
            "pickContact: contacts were selected with no request waiting; ignored rather than " ++
                "answered to whoever holds the slot next",
            .{},
        );
        return;
    };

    const allocator = std.heap.c_allocator;

    const list = readContacts(allocator, contacts, call.sels) catch |err| {
        std.log.err(
            "pickContact: could not read the selected CNContacts ({}); rejecting rather than " ++
                "replying with a selection that was not read",
            .{err},
        );
        ios_async.deliverError(call.ticket);
        return;
    };
    defer {
        for (list) |one| freeContact(allocator, one);
        allocator.free(list);
    }

    const json = shapeContacts(allocator, list) catch |err| {
        std.log.err("pickContact: could not shape the contacts reply ({}); rejecting", .{err});
        ios_async.deliverError(call.ticket);
        return;
    };
    defer allocator.free(json);

    // An empty selection is `[]` and resolves — see `shapeContacts`.
    ios_async.deliverJson(call.ticket, json);
}

/// Walk `NSArray<CNContact *>`, reading each contact.
///
/// A nil array is refused rather than answered `[]`: the delegate parameter is
/// `[CNContact]`, non-optional, so nil would mean the framework broke its own
/// contract and "the user selected nothing" is a claim with no basis.
fn readContacts(allocator: std.mem.Allocator, contacts: Id, sels: Sels) ![]Contact {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (contacts == null) return error.NativeCallFailed;

    const CountFn = *const fn (Id, Id) callconv(.c) c_ulong;
    const count_of: CountFn = @ptrCast(&objc.objc_msgSend);
    const total = count_of(contacts, sels.count);

    var out: std.ArrayListUnmanaged(Contact) = .empty;
    errdefer {
        for (out.items) |one| freeContact(allocator, one);
        out.deinit(allocator);
    }

    var i: c_ulong = 0;
    while (i < total) : (i += 1) {
        const contact = objc.msgSendId1(contacts, sels.object_at, i) orelse
            return error.NativeCallFailed;
        try out.append(allocator, try readContact(allocator, contact, sels));
    }

    return out.toOwnedSlice(allocator);
}

/// The user tapped Cancel.
///
/// A **rejection**, matching `rejectCallback(pendingCallbackId, error: "Cancelled")`
/// — never a resolve. Replying `{"cancelled":true}` here would be a success for
/// a pick that did not happen, and the page's `catch` (which is where
/// `test-bridges.html` prints the outcome) would never run.
///
/// The code and message the page sees are `NATIVE_CALL_FAILED` /
/// `"Native API call failed"` rather than Swift's `CRAFT_ERROR` / `"Cancelled"`.
/// That is `ios_async.deliverError`'s fixed wording and it is genuinely wrong
/// about the cause; the module comment records what it would take to fix, and
/// why inventing a second reply path here would be worse.
fn didCancel(_: Id, _: Id, _: Id) callconv(.c) void {
    if (!is_darwin) return;

    const call = takePending() orelse {
        std.log.info("pickContact: a cancel arrived with no request waiting; ignored", .{});
        return;
    };

    std.log.info(
        "pickContact: the user cancelled; rejecting the call (as CRAFT_ERROR/\"Cancelled\" in " ++
            "Swift, as NATIVE_CALL_FAILED here)",
        .{},
    );
    // A Cancel is not a native failure: the call worked and the answer is
    // "no". Reporting NativeCallFailed sends whoever reads the error looking
    // for a bug that is not there.
    ios_async.deliverErrorCode(call.ticket, bridge_error.BridgeError.Cancelled);
}

/// The user swiped the picker away.
///
/// `-presentationControllerDidDismiss:`, and the only thing that answers a
/// dismissal `contactPickerDidCancel:` is reported not to follow. A
/// **rejection**, for the same reason a Cancel is one: nothing was picked, so
/// resolving anything here would be a success for a pick that did not happen.
///
/// Reached with the slot already empty whenever a real callback got there first
/// — a Cancel that did send, or a pick — in which case this is a no-op rather
/// than a second answer.
///
/// Same `NATIVE_CALL_FAILED` / `"Native API call failed"` wording as `didCancel`
/// and wrong about the cause in the same way; see the module comment for where
/// that is fixed.
fn didDismissInteractively(_: Id, _: Id, _: Id) callconv(.c) void {
    if (!is_darwin) return;

    const call = takePending() orelse {
        std.log.info(
            "pickContact: the picker was dismissed with no request waiting; ignored " ++
                "(the cancel or the pick already answered)",
            .{},
        );
        return;
    };

    std.log.warn(
        "pickContact: the picker was dismissed interactively without sending " ++
            "contactPickerDidCancel:; rejecting the call rather than leaving it unanswered " ++
            "on a promise that has no timeout",
        .{},
    );
    ios_async.deliverError(call.ticket);
}

// =============================================================================
// Tests — host-only.
//
// Everything that decides page-visible bytes is pure and pinned here: routing
// in both directions, the `as? Bool ?? false` coercion, the six keys and their
// order, the two different value keys for phones and emails, the empty-array
// resolve, escaping, and the concurrency rule.
//
// Nothing here constructs a `CNContactPickerViewController` or presents
// anything. On a macOS host that class does not exist at all (macOS has
// `CNContactPicker`), and presenting from a test process is not something a
// suite should be able to do by accident.
// =============================================================================

const testing = std.testing;

/// The pending slot is module state, and a test that leaves it set would make
/// the next one refuse. Every test that touches it clears it through here.
fn resetPendingForTesting() void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending = null;
}

fn fakeTicket(index: u5, generation: u32) ios_async.Ticket {
    return .{ .index = index, .generation = generation };
}

fn fakeSels() Sels {
    // Every field is a plain `Id`; nothing below dereferences them, and the
    // concurrency rule under test does not care what they point at.
    return std.mem.zeroes(Sels);
}

test "the declared action is the one the handler serves" {
    try testing.expectEqual(@as(usize, 1), capability_actions.len);
    try testing.expectEqualStrings(A.pick_contact, capability_actions[0].name);

    for (capability_actions) |decl| {
        // A `.result` whose handler never replies parks the caller on a promise
        // with no timeout; a `.none` that is awaited resolves immediately and
        // means nothing. Swift resolves or rejects every path, so `.result`.
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        // `.live` with a reason would be a contradiction the manifest shows apps.
        try testing.expect(decl.reason == null);
    }
}

test "the action name matches the Swift case label exactly" {
    // The conformance ratchet compares this against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as Zig
    // serving an action the spec does not have.
    try testing.expectEqualStrings("pickContact", A.pick_contact);
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

test "an action this module does not serve is refused as UnknownAction" {
    // Not any other error: `ios_dispatch.route` reads UnknownAction as "not
    // mine, ask the next module" and anything else as a final answer. Getting
    // this wrong would make this file swallow another module's action — or the
    // shim's.
    var bridge = ContactPickerBridge.init(testing.allocator);
    defer bridge.deinit();

    for ([_][]const u8{
        "pickImage",
        "pickDocument",
        "getContacts",
        "addContact",
        // Casing is how a real typo arrives, and a miss does not fail loudly:
        // the action would quietly fall through to the Swift shim.
        "pickcontact",
        "PickContact",
        "pickContacts",
        "",
    }) |action| {
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(action, "{}"),
        );
        try testing.expect(routeFor(action) == null);
    }
}

test "pickContact routes to its own handler" {
    try testing.expectEqual(Route.pick_contact, routeFor("pickContact").?);
}

// ---------------------------------------------------------------------------
// Payload parsing
// ---------------------------------------------------------------------------

test "an absent multiple is false, exactly as Swift's ?? false is" {
    // `ios_dispatch.payloadOf` hands an absent `d` through as `{}`, which is the
    // first case here. The page always sends the field today, but a body without
    // it must not become a multi-select picker.
    try testing.expect(!try parseMultiple(testing.allocator, "{}"));
    try testing.expect(!try parseMultiple(testing.allocator, "{\"other\":1}"));
}

test "a boolean multiple is carried through, both ways" {
    try testing.expect(try parseMultiple(testing.allocator, "{\"multiple\":true}"));
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":false}"));
}

test "the numbers NSNumber-as-Bool accepts are the only numbers accepted" {
    // `options.multiple || false` is a fallback, not a coercion, so
    // `pickContact({multiple: 1})` really does put `1` on the wire. Swift's
    // `as? Bool` succeeds for 0 and 1 and fails for everything else.
    try testing.expect(try parseMultiple(testing.allocator, "{\"multiple\":1}"));
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":0}"));
    try testing.expect(try parseMultiple(testing.allocator, "{\"multiple\":1.0}"));
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":0.0}"));

    // 2 is truthy in JavaScript and still opens a single-selection picker,
    // because `as? Bool` returns nil for it. This is the case a "truthy means
    // multiple" reading would get wrong.
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":2}"));
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":-1}"));
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":0.5}"));
}

test "a non-numeric truthy multiple is false, not multi" {
    // `pickContact({multiple: 'yes'})` puts the string on the wire and Swift
    // reads it as false.
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":\"yes\"}"));
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":\"true\"}"));
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":[]}"));
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":{}}"));
    // `JSON.stringify` keeps an explicit null where it drops an undefined.
    try testing.expect(!try parseMultiple(testing.allocator, "{\"multiple\":null}"));
}

test "a body that cannot be read is an error, not a defaulted false" {
    // Acting on a default for a payload that failed to parse is how a field the
    // page sent goes missing with success reported anyway.
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        parseMultiple(testing.allocator, "{\"multiple\":"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        parseMultiple(testing.allocator, "[1,2]"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        parseMultiple(testing.allocator, "\"multiple\""),
    );
}

// ---------------------------------------------------------------------------
// Reply shaping
// ---------------------------------------------------------------------------

test "one contact is the six-key object formatContact builds, in a fixed order" {
    const allocator = testing.allocator;
    const json = try shapeContact(allocator, .{
        .id = "AB12-CD34",
        .given_name = "Ada",
        .family_name = "Lovelace",
        .display_name = "Ada Lovelace",
        .phones = &.{.{ .label = "mobile", .value = "+1 555 0100" }},
        .emails = &.{.{ .label = "work", .value = "ada@example.com" }},
    });
    defer allocator.free(json);

    try testing.expectEqualStrings(
        "{\"id\":\"AB12-CD34\",\"givenName\":\"Ada\",\"familyName\":\"Lovelace\"," ++
            "\"displayName\":\"Ada Lovelace\"," ++
            "\"phoneNumbers\":[{\"label\":\"mobile\",\"number\":\"+1 555 0100\"}]," ++
            "\"emailAddresses\":[{\"label\":\"work\",\"address\":\"ada@example.com\"}]}",
        json,
    );
}

test "phones say number and emails say address" {
    // The single easiest thing to get backwards, and it is silent: both are
    // `{label, <string>}` and a swapped key still parses. `formatContact` is the
    // only authority, and `craft.d.ts` — which declares both as `string[]` — is
    // wrong for this action and must not be followed.
    const allocator = testing.allocator;
    const json = try shapeContact(allocator, .{
        .id = "1",
        .given_name = "",
        .family_name = "",
        .display_name = "",
        .phones = &.{.{ .label = "home", .value = "555" }},
        .emails = &.{.{ .label = "home", .value = "a@b.c" }},
    });
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const phone = parsed.value.object.get("phoneNumbers").?.array.items[0].object;
    try testing.expectEqualStrings("555", phone.get("number").?.string);
    try testing.expect(phone.get("address") == null);

    const email = parsed.value.object.get("emailAddresses").?.array.items[0].object;
    try testing.expectEqualStrings("a@b.c", email.get("address").?.string);
    try testing.expect(email.get("number") == null);
}

test "a contact with no numbers and no addresses keeps both keys as empty arrays" {
    // `formatContact` always assigns both keys, so a page reading
    // `contact.phoneNumbers.length` must not meet `undefined`.
    const allocator = testing.allocator;
    const json = try shapeContact(allocator, .{
        .id = "1",
        .given_name = "Solo",
        .family_name = "",
        .display_name = "Solo",
        .phones = &.{},
        .emails = &.{},
    });
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"phoneNumbers\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"emailAddresses\":[]") != null);
}

test "a name that needs escaping stays valid JSON" {
    // A contact name is user data. Before escaping, a single `"` in it would
    // close the string literal inside the `evaluateJavaScript:` source and turn
    // the reply into a syntax error in the page rather than a wrong field.
    const allocator = testing.allocator;
    const json = try shapeContact(allocator, .{
        .id = "x\\y",
        .given_name = "Ann \"Annie\"",
        .family_name = "O'Neil\nJr",
        .display_name = "Ann\t\"Annie\" O'Neil",
        .phones = &.{.{ .label = "we\"ird", .value = "+1\\555" }},
        .emails = &.{.{ .label = "a\nb", .value = "q\"@example.com" }},
    });
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("x\\y", obj.get("id").?.string);
    try testing.expectEqualStrings("Ann \"Annie\"", obj.get("givenName").?.string);
    try testing.expectEqualStrings("O'Neil\nJr", obj.get("familyName").?.string);
    try testing.expectEqualStrings(
        "we\"ird",
        obj.get("phoneNumbers").?.array.items[0].object.get("label").?.string,
    );
    try testing.expectEqualStrings(
        "q\"@example.com",
        obj.get("emailAddresses").?.array.items[0].object.get("address").?.string,
    );
}

test "the multiple reply is an array, not an object" {
    // `test-bridges.html:1030` reads `contacts?.length`, so an object here would
    // print `undefined contacts` for a selection that worked.
    const allocator = testing.allocator;
    const json = try shapeContacts(allocator, &.{
        .{
            .id = "1",
            .given_name = "A",
            .family_name = "One",
            .display_name = "A One",
            .phones = &.{},
            .emails = &.{},
        },
        .{
            .id = "2",
            .given_name = "B",
            .family_name = "Two",
            .display_name = "B Two",
            .phones = &.{.{ .label = "mobile", .value = "555" }},
            .emails = &.{},
        },
    });
    defer allocator.free(json);

    try testing.expect(json[0] == '[');

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try testing.expectEqualStrings("1", parsed.value.array.items[0].object.get("id").?.string);
    try testing.expectEqualStrings(
        "555",
        parsed.value.array.items[1].object.get("phoneNumbers").?.array.items[0].object.get("number").?.string,
    );
}

test "an empty multi-selection is an empty array that resolves" {
    // `contacts.map` over `[]` is `[]` and Swift resolves it. Turning this into
    // an error, or into a cancel, would fail a call the shim answers. `[]` is
    // also truthy, so `craft-bridge.js`'s `payload || {}` leaves it intact.
    const allocator = testing.allocator;
    const json = try shapeContacts(allocator, &.{});
    defer allocator.free(json);

    try testing.expectEqualStrings("[]", json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
}

test "the single reply is an object rather than an array of one" {
    // The two `didSelect` overloads resolve genuinely different shapes, and a
    // page doing `contact.givenName` after a single pick would read `undefined`
    // off a one-element array.
    const allocator = testing.allocator;
    const one = Contact{
        .id = "1",
        .given_name = "A",
        .family_name = "One",
        .display_name = "A One",
        .phones = &.{},
        .emails = &.{},
    };

    const single = try shapeContact(allocator, one);
    defer allocator.free(single);
    const many = try shapeContacts(allocator, &.{one});
    defer allocator.free(many);

    try testing.expect(single[0] == '{');
    try testing.expect(many[0] == '[');

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, single, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("A", parsed.value.object.get("givenName").?.string);
}

test "a cancel is a rejection, and these are the exact bytes it puts on the wire" {
    // `didCancel` calls `ios_async.deliverError`, which lands in
    // `deliverOnMain` -> `sendErrorToJS(action, NativeCallFailed)`. This builds
    // the same envelope that path builds, so the page-visible result of a
    // cancel is pinned rather than described.
    //
    // Two things are being asserted at once. First, `"error":true` — it goes
    // out through `__craftBridgeError`, which *rejects*. A
    // `{"cancelled":true}` resolve (the shape the image and document pickers
    // use) would be a fabricated success for a pick that did not happen, and
    // the page's `catch` — where `test-bridges.html:1022` prints the outcome —
    // would never run.
    //
    // Second, the divergence, stated in bytes: Swift sends
    // `code:"CRAFT_ERROR"`, `message:"Cancelled"`. These are what the page gets
    // instead, and they are wrong about the cause. See the module comment for
    // why the fix belongs in `ios_async.zig` rather than in a second reply path
    // built here.
    const allocator = testing.allocator;
    var ctx = bridge_error.ErrorContext.init(
        bridge_error.BridgeError.NativeCallFailed,
        A.pick_contact,
        bridge_error.errorMessage(bridge_error.BridgeError.NativeCallFailed),
    );
    ctx.request_id = 11;

    const json = try ctx.toJSON(allocator);
    defer allocator.free(json);

    try testing.expectEqualStrings(
        "{\"error\":true,\"code\":\"NATIVE_CALL_FAILED\",\"action\":\"pickContact\"," ++
            "\"message\":\"Native API call failed\",\"id\":11}",
        json,
    );

    // And it is not any of the resolve shapes: a rejection carries no contact.
    try testing.expect(std.mem.indexOf(u8, json, "givenName") == null);
}

// ---------------------------------------------------------------------------
// Concurrency
// ---------------------------------------------------------------------------

test "a second request while one is presented is refused, and the first is left alone" {
    resetPendingForTesting();
    defer resetPendingForTesting();

    const first = fakeTicket(3, 7);
    try testing.expect(publishPending(.{ .ticket = first, .sels = fakeSels() }));

    // The refusal. Swift overwrites `pendingCallbackId` here and the first
    // promise never settles; the picker on screen is about to answer, so the
    // newcomer is the one that has to be told no.
    try testing.expect(!publishPending(.{ .ticket = fakeTicket(4, 9), .sels = fakeSels() }));

    // And the slot still holds the *first* ticket, not the newcomer's — a
    // refusal that quietly replaced would look identical from the return value.
    pending_mutex.lock();
    defer pending_mutex.unlock();
    try testing.expectEqual(first.index, pending.?.ticket.index);
    try testing.expectEqual(first.generation, pending.?.ticket.generation);
}

test "the slot is handed over once, so a double-firing delegate cannot reply twice" {
    resetPendingForTesting();
    defer resetPendingForTesting();

    const ticket = fakeTicket(1, 2);
    try testing.expect(publishPending(.{ .ticket = ticket, .sels = fakeSels() }));

    const taken = takePending() orelse return error.PendingWentMissing;
    try testing.expectEqual(ticket.index, taken.ticket.index);

    // A cancel racing a selection, or a duplicate fire. `ios_async` would ignore
    // the stale generation anyway, but the slot has to be empty here so the
    // callback never even reaches for a ticket that is already spent.
    try testing.expect(takePending() == null);
}

test "the picker is reusable after it answers" {
    // The refusal above must not be permanent. Once a delegate callback has
    // taken the slot, the next pickContact publishes normally.
    resetPendingForTesting();
    defer resetPendingForTesting();

    try testing.expect(publishPending(.{ .ticket = fakeTicket(0, 1), .sels = fakeSels() }));
    _ = takePending();
    try testing.expect(publishPending(.{ .ticket = fakeTicket(0, 3), .sels = fakeSels() }));
}

test "a delegate callback with no request waiting takes nothing" {
    // The stray-callback path every IMP begins with. It has to be a
    // no-op rather than an answer, because the next thing to occupy the slot
    // would otherwise receive this picker's result.
    resetPendingForTesting();
    defer resetPendingForTesting();

    try testing.expect(takePending() == null);
}

test "the delegate class name is this module's alone" {
    // `ios_delegate.defineClass` looks a name up before allocating, so two files
    // registering one name means whichever ran second silently adopts the
    // other's IMPs — which read different objects and answer different tickets.
    try testing.expectEqualStrings("CraftIOSContactPickerDelegate", delegate_class_name);
}

test "every delegate method is registered at the encoding its selector needs" {
    // A wrong encoding still registers and still dispatches, then reads
    // arguments from the wrong registers with no crash and no compile error. The
    // named constants are the only defence, so the *pairing* is pinned rather
    // than the constants alone: both `didSelect` selectors take the picker plus
    // one object, the cancel and the dismissal take one object each.
    //
    // The count is asserted too. `contactPicker:didSelectContacts:` is the whole
    // `multiple:true` reply path and `presentationControllerDidDismiss:` is the
    // only answer to a swipe-down; UIKit dispatches through
    // `respondsToSelector:`, so dropping either is a silent no-op and a promise
    // that never settles.
    const methods = delegateMethods();
    try testing.expectEqual(@as(usize, 4), methods.len);

    const want = [_]struct { selector: []const u8, types: []const u8 }{
        .{ .selector = "contactPicker:didSelectContact:", .types = "v@:@@" },
        .{ .selector = "contactPicker:didSelectContacts:", .types = "v@:@@" },
        .{ .selector = "contactPickerDidCancel:", .types = "v@:@" },
        .{ .selector = "presentationControllerDidDismiss:", .types = "v@:@" },
    };

    for (methods, 0..) |method, i| {
        try testing.expectEqualStrings(want[i].selector, method.selector);
        try testing.expectEqualStrings(want[i].types, method.types);
    }

    // And the encodings really are the named ones, not two strings that happen
    // to match today.
    try testing.expectEqualStrings(ios_delegate.enc.void_two_objects, methods[0].types);
    try testing.expectEqualStrings(ios_delegate.enc.void_two_objects, methods[1].types);
    try testing.expectEqualStrings(ios_delegate.enc.void_one_object, methods[2].types);
    try testing.expectEqualStrings(ios_delegate.enc.void_one_object, methods[3].types);
}

test "no two delegate methods share a selector" {
    // `class_addMethod` for a selector the class already has is a failure the
    // factory turns into `MethodNotAdded`, so a duplicate would take the whole
    // registration down — and a typo that made two rows equal would otherwise
    // read as an extra method rather than a missing one.
    const methods = delegateMethods();
    for (methods, 0..) |a, i| {
        for (methods[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.selector, b.selector));
        }
    }
}

test "a swipe-down that sends no cancel still empties the slot exactly once" {
    // The belt's contract, as state rather than as prose: whichever callback
    // arrives first takes the ticket, and the second finds nothing. Without it a
    // swipe would leave `pending` set for the life of the process and refuse
    // every later pickContact — which is worse here than in Swift, where only
    // the one promise is stranded.
    resetPendingForTesting();
    defer resetPendingForTesting();

    try testing.expect(publishPending(.{ .ticket = fakeTicket(2, 5), .sels = fakeSels() }));

    // The dismissal gets there first: it takes the ticket...
    const swiped = takePending() orelse return error.PendingWentMissing;
    try testing.expectEqual(@as(u5, 2), swiped.ticket.index);

    // ...and a late `contactPickerDidCancel:` for the same picker finds nothing
    // to answer, so the promise is rejected once rather than twice.
    try testing.expect(takePending() == null);

    // The slot is free again, not wedged.
    try testing.expect(publishPending(.{ .ticket = fakeTicket(2, 7), .sels = fakeSels() }));
}

test "nothing in this module dismisses the picker" {
    // `CNContactPickerViewController` is a remote view controller that takes
    // itself down, and Swift dismisses it in none of its three delegate methods.
    // A `dismiss` added here would be a second dismissal of a controller already
    // dismissing — and on the presenter it would take down whatever else is
    // modal. This is a real difference from the image and document pickers, so
    // it is asserted rather than left to a comment.
    //
    // `presentationControllerDidDismiss:` does not contradict this: it *observes*
    // a dismissal the user performed and never asks for one.
    //
    // The needle is the *call* form — a `selector(` with a dismissal name in it
    // — rather than the bare selector name, so the prose in this file cannot
    // match itself and the assertion keeps meaning something. Which is why the
    // needle is not spelled out in any comment, including this one.
    const source = @embedFile("bridge_mobile_contactpicker.zig");
    try testing.expect(std.mem.indexOf(u8, source, "selector(\"dismiss") == null);
    // Non-vacuity: the same scan finds the present call, so a needle that
    // stopped matching anything could not pass unnoticed.
    try testing.expect(std.mem.indexOf(u8, source, "selector(\"presentViewController") != null);
}
