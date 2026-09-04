//! The permission actions of the `mobile` namespace: `checkPermission` and
//! `requestPermission`.
//!
//! The page-side contract (`craft.permissions` in the injected JS) is one
//! field in — `{permission: "camera"}` — and a bare JSON fragment out:
//! `"granted"`, `"denied"`, `"restricted"` or `"undetermined"`. There is no
//! `"prompt"` anywhere in the vocabulary, and no `{status:…}` wrapper — the
//! desktop bridge's `craft.permissions` in `craft-bridge.js` (`t='permissions'`,
//! payload field `name`, reply `{status:…}`) is a different, unrelated contract.
//! Swift serialises replies with `.fragmentsAllowed`, so the bare quoted string
//! is the wire value, and `ios_async`'s `"granted"`/`"denied"` completions are
//! byte-identical to what Swift sends.
//!
//! ## What is served, and what deliberately is not
//!
//! Dispatch is per *action*, but honesty here is per *permission value*: Zig
//! can read ten authorization statuses synchronously and can run three request
//! prompts through `ios_async`'s pooled completion blocks, and it cannot do
//! the rest without machinery it does not own yet. The split:
//!
//!  - `checkPermission` is served for location, locationAlways, camera,
//!    microphone, photos, contacts, calendar, reminders, motion and
//!    bluetooth. `notifications` is handed back to the dispatcher as
//!    `UnknownAction`: the only status API is
//!    `getNotificationSettingsWithCompletionHandler:`, whose completion takes
//!    a `UNNotificationSettings *` and whose answer needs three words —
//!    `ios_async` speaks only BOOL blocks and only two. There is no
//!    synchronous API to fall back on, and answering without asking is the
//!    fabricated-reading class this migration exists to remove.
//!  - `requestPermission` is served for camera, microphone and notifications,
//!    whose completions are exactly the `void(^)(BOOL)` and
//!    `void(^)(BOOL, NSError*)` shapes the block pool was built for.
//!    location/locationAlways (the reply arrives via the app's
//!    `CLLocationManagerDelegate`, needs its `locationManager` and
//!    `enableBackgroundLocation` config, and speaks the full four-word
//!    vocabulary), photos (a status-enum completion with a `.limited`
//!    special case a BOOL cannot carry) and contacts/calendar/reminders
//!    (need a store instance kept alive past the dispatch frame, plus an
//!    iOS 17 availability fork) return `UnknownAction`.
//!  - `openSettings` **is** claimed now, and the reason it was not is worth
//!    keeping. Its reply is a bare JSON *boolean* (`UIApplication.open`'s
//!    completion BOOL, `true`/`false` on the wire) and `ios_async.boolBlock`
//!    replies the strings `"granted"`/`"denied"`. That mismatch is not
//!    cosmetic: `false` is falsy and `"denied"` is truthy, so
//!    `if (await craft.permissions.openSettings())` would take its success
//!    branch on failure. The old note concluded that claiming the action
//!    meant first extending `ios_async` with a bool-literal reply variant.
//!    It did not — a module-owned global block delivering through
//!    `deliverJson` carries any literal, which is the shape
//!    `bridge_mobile_auth.zig` and `bridge_mobile_siri.zig` established
//!    afterwards. What the note was really objecting to remains true and is
//!    still avoided: the repo's one hand-rolled *stack* block
//!    (`bridge_mobile_system.zig:391`) is safe only because `openURL:`
//!    chooses to copy an escaping handler, which is the callee's choice and
//!    not a guarantee. Every block in this file is global, so `Block_copy` is
//!    identity and the question does not arise.
//!
//! Returning `UnknownAction` for a payload value is what keeps this honest
//! without regressing anything: `ios_dispatch.route` treats it as "not mine,
//! ask the next", finds no other module claiming the action, and hands the
//! *same* action and payload to `handOffToHost`, where the un-migrated Swift
//! arm answers exactly as it does today. This is the deliberate opposite of
//! the `.unavailable` declarations in `bridge_mobile_device`
//! (`getNetworkStatus`) and `bridge_mobile_display` (`lockOrientation`):
//! those took actions *away* from the shim because the shim's answers were
//! fabricated or broken; these shim answers are real, and taking them away
//! would trade working behaviour for a tidier table. The cost is that the
//! conformance ratchet keeps counting the payload values above — location,
//! photos, contacts, calendar, reminders — against `requestPermission`, which
//! is the truth. It no longer applies to `openSettings`: that one is claimed,
//! and the ratchet counts it as migrated.
//!
//! ## What is carried across exactly
//!
//!  - The status vocabulary and its precedence: restricted beats denied
//!    beats granted, and everything else — including enum values a future
//!    iOS adds — is `"undetermined"`. That is Swift's `permissionStatus`
//!    helper verbatim. Unknown *permission names* also resolve
//!    `"undetermined"` (Swift's `default` arm); it is a real answer — the
//!    status of a permission iOS has never heard of is not determined — and
//!    erroring instead would diverge from both the shim and Android.
//!  - `requestPermission` for motion and bluetooth resolves
//!    `"undetermined"`: the Swift request switch has no arm for either, so
//!    they fall into `default`. iOS prompts for these implicitly at first
//!    framework use; the spec never requests them explicitly, and neither
//!    does this module. Resolving locally rather than falling through is
//!    identical behaviour, minus one Objective-C round trip.
//!  - `"location"` counts `.authorizedWhenInUse` as granted;
//!    `"locationAlways"` does not. Same raw status, different verdicts, and
//!    the check reads the same deprecated
//!    `+[CLLocationManager authorizationStatus]` the Swift spec calls —
//!    matching it, not modernising it, because the instance property needs a
//!    manager this module does not own.
//!
//! ## Framework presence, not framework linkage
//!
//! Unlike `bridge_mobile_storage`'s Security externs, nothing here is a
//! link-time symbol: every class is found with `objc_getClass` at call time,
//! and the one string constant (`AVMediaTypeVideo`) through `dlsym` with the
//! documented literal value as fallback. A generated app has every class in
//! the process because `CraftApp.swift` imports AVFoundation, Photos,
//! Contacts, EventKit, CoreMotion, CoreBluetooth, CoreLocation and
//! UserNotifications; a process missing one answers `ClassNotFound` →
//! NATIVE_CALL_FAILED, never a crash and never a guess.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The same type as `objc.id` — `?*anyopaque` — spelled locally.
///
/// `objc_runtime.objc` is an empty struct off Darwin, and a function
/// *signature* is analysed even when a comptime platform guard makes its body
/// unreachable, so naming `objc.id` in the signatures below would break the
/// host build. It stays a single optional pointer, never `?objc.id`, because a
/// double optional is illegal in a `callconv(.c)` type.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
///
/// All three are claimed. `openSettings` was not, and this comment said so
/// long after it stopped being true — the module comment above records both
/// the original objection and why a module-owned global block answered it.
/// A doc comment that contradicts the `A` block three lines below it is worse
/// than none: `scheduleNotification` sat with the shim for days after its
/// blocker was fixed because nobody re-read the note that described it.
pub const A = struct {
    pub const check_permission = "checkPermission";
    pub const request_permission = "requestPermission";
    pub const open_settings = "openSettings";
};

/// Both `.result`: every Swift path for these two actions terminates in
/// exactly one `resolveCallback` or `rejectCallback`, and the injected
/// `craft.permissions.check`/`request` return promises the page awaits.
///
/// Both `.live`, with the caveat the module comment spells out: the manifest
/// speaks per action, and a handful of payload *values* ride through to the
/// Swift shim via `UnknownAction`. The page cannot observe the difference —
/// the same reply arrives either way — so `.live` is the accurate claim.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.check_permission, .reply = .result },
    .{ .name = A.request_permission, .reply = .result },
    .{ .name = A.open_settings, .reply = .result },
};

/// Which handler an action selects, or null for one this namespace does not
/// serve. Split out from `handleMessage` so the table-versus-dispatch
/// agreement is assertable on a host that has none of the frameworks.
const Route = enum { check, request, open_settings };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.check_permission)) return .check;
    if (std.mem.eql(u8, action, A.request_permission)) return .request;
    if (std.mem.eql(u8, action, A.open_settings)) return .open_settings;
    return null;
}

/// The permission names the Swift switches recognise, plus `.unknown` for
/// everything else — which is a routed outcome (`"undetermined"`), not an
/// error, because it is Swift's `default` arm.
///
/// Spellings are the Swift `case` labels, compared case-sensitively, exactly
/// as Swift compares them. The name is only ever *compared* — it never
/// reaches `createNSString` — so an embedded NUL needs no refusal here: it
/// fails every comparison and lands in `.unknown`, the same `"undetermined"`
/// Swift gives it (Swift keeps the NUL and also falls to `default`).
const Kind = enum {
    location,
    location_always,
    camera,
    microphone,
    photos,
    contacts,
    calendar,
    reminders,
    motion,
    bluetooth,
    notifications,
    unknown,
};

fn kindFor(name: []const u8) Kind {
    if (std.mem.eql(u8, name, "location")) return .location;
    if (std.mem.eql(u8, name, "locationAlways")) return .location_always;
    if (std.mem.eql(u8, name, "camera")) return .camera;
    if (std.mem.eql(u8, name, "microphone")) return .microphone;
    if (std.mem.eql(u8, name, "photos")) return .photos;
    if (std.mem.eql(u8, name, "contacts")) return .contacts;
    if (std.mem.eql(u8, name, "calendar")) return .calendar;
    if (std.mem.eql(u8, name, "reminders")) return .reminders;
    if (std.mem.eql(u8, name, "motion")) return .motion;
    if (std.mem.eql(u8, name, "bluetooth")) return .bluetooth;
    if (std.mem.eql(u8, name, "notifications")) return .notifications;
    return .unknown;
}

// =============================================================================
// The status vocabulary — Swift's `permissionStatus` helper, verbatim.
// =============================================================================

const granted_json = "\"granted\"";
const denied_json = "\"denied\"";
const restricted_json = "\"restricted\"";
const undetermined_json = "\"undetermined\"";

/// restricted > denied > granted > undetermined, in that order of precedence.
///
/// The order is load-bearing and is Swift's: a status that somehow set both
/// flags must answer `"restricted"`, and `granted == false` with no flag set
/// is `"undetermined"`, not `"denied"` — notDetermined and every future enum
/// value both land there, which is the honest word for either.
fn statusJson(granted: bool, denied: bool, restricted: bool) []const u8 {
    if (restricted) return restricted_json;
    if (denied) return denied_json;
    return if (granted) granted_json else undetermined_json;
}

/// `CLAuthorizationStatus` (an `Int32`, unlike every other status here):
/// 0 notDetermined, 1 restricted, 2 denied, 3 authorizedAlways,
/// 4 authorizedWhenInUse.
///
/// `always_only` is the one behavioural fork between the two location
/// spellings: `"location"` counts whenInUse as granted, `"locationAlways"`
/// counts only always — so a whenInUse grant checked as `"locationAlways"`
/// answers `"undetermined"`, which is the spec's answer, odd as it reads.
fn locationStatusJson(raw: i32, always_only: bool) []const u8 {
    const granted = raw == 3 or (!always_only and raw == 4);
    return statusJson(granted, raw == 2, raw == 1);
}

/// The 0..3 layout that AVFoundation (`AVAuthorizationStatus`), Contacts
/// (`CNAuthorizationStatus`), CoreMotion (`CMAuthorizationStatus`) and
/// CoreBluetooth (`CBManagerAuthorization`) all share: 0 notDetermined,
/// 1 restricted, 2 denied, 3 authorized/allowedAlways.
///
/// One mapper for the four on purpose — they are the same numbers, and four
/// copies would be four places for one transcription slip. Values past 3
/// (e.g. the `.limited` Contacts gained in iOS 18) fold to `"undetermined"`,
/// exactly as Swift's `status == .authorized`-only checks do.
fn simpleAuthStatusJson(raw: c_long) []const u8 {
    return statusJson(raw == 3, raw == 2, raw == 1);
}

/// `PHAuthorizationStatus`: as above, plus 4 limited — and limited *is*
/// granted (`status == .authorized || status == .limited` in Swift). Only
/// exactly 3 or 4; a future 5 is not presumed to be an access level.
fn photosStatusJson(raw: c_long) []const u8 {
    return statusJson(raw == 3 or raw == 4, raw == 2, raw == 1);
}

/// `EKAuthorizationStatus`: as the simple layout, but granted is
/// `status == .authorized || status.rawValue >= 4` in Swift — i.e. `raw >= 3`
/// — because iOS 17 renamed 3 to `.fullAccess` and added 4 `.writeOnly`, and
/// the spec counts both.
fn calendarStatusJson(raw: c_long) []const u8 {
    return statusJson(raw >= 3, raw == 2, raw == 1);
}

/// The one status that is not a small enum: `AVAudioSessionRecordPermission`
/// is an `NSUInteger` of four-character codes.
fn fourCC(comptime s: *const [4]u8) c_ulong {
    return (@as(c_ulong, s[0]) << 24) | (@as(c_ulong, s[1]) << 16) |
        (@as(c_ulong, s[2]) << 8) | @as(c_ulong, s[3]);
}

const record_permission_undetermined: c_ulong = fourCC("undt");
const record_permission_denied: c_ulong = fourCC("deny");
const record_permission_granted: c_ulong = fourCC("grnt");

/// Microphone has no restricted case — Swift passes only `granted` and
/// `denied` to its helper — and anything unrecognised (including `'undt'`)
/// is `"undetermined"`.
fn microphoneStatusJson(raw: c_ulong) []const u8 {
    return statusJson(raw == record_permission_granted, raw == record_permission_denied, false);
}

// =============================================================================
// Payload
// =============================================================================

/// Parse `d`, distinguishing a bad payload from a failed allocation, exactly
/// as `bridge_mobile_storage` does and for the same reason: telling the page
/// INVALID_JSON about its own good JSON sends whoever debugs it to the wrong
/// side of the bridge.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
}

/// The one field the page sends: `permission`, a string. The injected JS
/// builds the payload as `{permission: permission}` and `_invoke` merges in
/// `action`/`callbackId`, so extra fields are normal and ignored.
///
/// Swift folds missing, `null` and non-string into a single
/// `"Missing permission"` reject with code `INVALID_ARGUMENT`. This module's
/// error vocabulary has no such code, so the cases split into the two nearest
/// words — MISSING_DATA for an absent field, INVALID_PARAMETER for a present
/// one of the wrong type. Every such case still *rejects* the promise, which
/// is the part of the contract a page can be written against.
fn permissionName(payload: std.json.Value) ![]const u8 {
    const object = switch (payload) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
    const field = object.get("permission") orelse return bridge_error.BridgeError.MissingData;
    return switch (field) {
        .string => |s| s,
        else => bridge_error.BridgeError.InvalidParameter,
    };
}

pub const PermissionsBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const route = routeFor(action) orelse return bridge_error.BridgeError.UnknownAction;
        return switch (route) {
            .check => self.checkPermission(data),
            .request => self.requestPermission(data),
            .open_settings => self.openSettings(),
        };
    }

    /// Read one authorization status and answer with the bare status string.
    ///
    /// Every served arm is synchronous and prompt-free — reading an
    /// authorization status never triggers a dialog, including
    /// `CBManager.authorization`, which unlike instantiating a
    /// `CBCentralManager` does not start Bluetooth.
    fn checkPermission(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();
        const name = try permissionName(parsed.value);

        const json: []const u8 = switch (kindFor(name)) {
            .location => locationStatusJson(try readLocationStatus(), false),
            .location_always => locationStatusJson(try readLocationStatus(), true),
            .camera => simpleAuthStatusJson(try readCameraStatus(self.allocator)),
            .microphone => microphoneStatusJson(try readMicrophonePermission()),
            .photos => photosStatusJson(try readPhotosStatus()),
            .contacts => simpleAuthStatusJson(try readContactsStatus()),
            .calendar => calendarStatusJson(try readEventKitStatus(ek_entity_event)),
            .reminders => calendarStatusJson(try readEventKitStatus(ek_entity_reminder)),
            .motion => simpleAuthStatusJson(try readMotionStatus()),
            .bluetooth => simpleAuthStatusJson(try readBluetoothStatus()),
            // No sync API exists, and `ios_async` cannot carry a
            // settings-object completion or a three-way answer. The shim
            // asks `getNotificationSettingsWithCompletionHandler:` and
            // resolves from inside it; hand the whole call to it, payload
            // intact, rather than guess.
            .notifications => return bridge_error.BridgeError.UnknownAction,
            // Swift's `default:` — a real answer, see the module comment.
            .unknown => undetermined_json,
        };
        bridge_error.sendResultToJS(self.allocator, A.check_permission, json);
    }

    /// Run a permission prompt whose completion fits `ios_async`, or hand the
    /// value to the shim when it does not.
    ///
    /// The served arms reply later, from the completion, through the block
    /// pool: `"granted"` or `"denied"`, byte-identical to Swift's
    /// `granted ? "granted" : "denied"` under `.fragmentsAllowed`. If the
    /// status is already determined, the frameworks call the completion
    /// immediately with the standing answer — same as Swift, no prompt shown.
    fn requestPermission(self: *Self, data: []const u8) !void {
        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();
        const name = try permissionName(parsed.value);

        switch (kindFor(name)) {
            .camera => try self.requestCamera(),
            .microphone => try requestMicrophone(),
            .notifications => try requestNotifications(),
            // Delegate replies, status-enum completions, store lifetimes and
            // an iOS 17 fork — the shim owns all of that today. Same action,
            // same payload, answered by the Swift arm unchanged.
            .location, .location_always, .photos, .contacts, .calendar, .reminders => {
                return bridge_error.BridgeError.UnknownAction;
            },
            // The Swift request switch has no motion or bluetooth arm; both
            // fall into `default` and resolve "undetermined". iOS prompts for
            // them implicitly at first framework use, never on request.
            .motion, .bluetooth, .unknown => {
                bridge_error.sendResultToJS(self.allocator, A.request_permission, undetermined_json);
            },
        }
    }

    /// `+[AVCaptureDevice requestAccessForMediaType:completionHandler:]` with
    /// a `void(^)(BOOL)` from the pool.
    ///
    /// Every fallible step happens *before* `acquire`, so there is no error
    /// path between the ticket and the framework call and therefore no
    /// `abandon` site. A future edit that adds a fallible step after
    /// `acquire` must call `ios_async.abandon(ticket)` on its error path, or
    /// the slot leaks until the pool answers Busy forever.
    fn requestCamera(self: *Self) !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        const AVCaptureDevice = objc.objc_getClass("AVCaptureDevice") orelse return error.ClassNotFound;
        const sel = objc.sel_registerName("requestAccessForMediaType:completionHandler:") orelse
            return error.SelectorNotFound;
        const media = try mediaTypeVideo(self.allocator);

        const ticket = ios_async.acquire(A.request_permission) orelse return poolFull();

        const Fn = *const fn (Id, Id, Id, *anyopaque) callconv(.c) void;
        const func: Fn = @ptrCast(&objc.objc_msgSend);
        func(AVCaptureDevice, sel, media, ios_async.boolBlock(ticket));
    }

    /// `-[AVAudioSession requestRecordPermission:]` on the shared instance —
    /// the deprecated-but-live API the Swift spec calls; `AVAudioApplication`
    /// is its replacement and would be a divergence, not a port.
    fn requestMicrophone() !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        const session = try audioSession();
        const sel = objc.sel_registerName("requestRecordPermission:") orelse return error.SelectorNotFound;

        const ticket = ios_async.acquire(A.request_permission) orelse return poolFull();

        const Fn = *const fn (Id, Id, *anyopaque) callconv(.c) void;
        const func: Fn = @ptrCast(&objc.objc_msgSend);
        func(session, sel, ios_async.boolBlock(ticket));
    }

    /// Refuse before touching the notification centre in a process the
    /// centre will refuse to exist in.
    fn requireBundleIdentifier() !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        const NSBundle = objc.objc_getClass("NSBundle") orelse return error.ClassNotFound;
        const sel_main = objc.sel_registerName("mainBundle") orelse return error.SelectorNotFound;
        const bundle = objc.msgSendId(NSBundle, sel_main) orelse return error.NoBundleIdentifier;
        const sel_ident = objc.sel_registerName("bundleIdentifier") orelse return error.SelectorNotFound;
        if (objc.msgSendId(bundle, sel_ident) == null) return error.NoBundleIdentifier;
    }

    /// `-[UNUserNotificationCenter requestAuthorizationWithOptions:completionHandler:]`
    /// with a `void(^)(BOOL, NSError *)` from the pool. The error object is
    /// discarded by the pool's invoke, exactly as Swift's `{ granted, _ in }`
    /// discards it — the granted flag is the whole page contract.
    ///
    /// `currentNotificationCenter` RAISES — an uncatchable
    /// `NSInternalInconsistencyException`, not a nil return — in a process
    /// with no bundle identifier, so the bundle is checked first.
    ///
    /// The previous comment here argued the guard was unnecessary because a
    /// dispatched page message only exists inside a bundled app. That is true
    /// of the shipping app and false of every test runner, and "the Swift call
    /// has the same exposure" is not a reason to inherit a crash: an
    /// unguarded call takes the process down with the page's promise still
    /// pending, which is the least diagnosable failure iOS offers.
    /// `bridge_mobile_notifcancel.zig` guards the same call the same way.
    fn requestNotifications() !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        try requireBundleIdentifier();

        const UNUserNotificationCenter = objc.objc_getClass("UNUserNotificationCenter") orelse
            return error.ClassNotFound;
        const sel_current = objc.sel_registerName("currentNotificationCenter") orelse
            return error.SelectorNotFound;
        const center = objc.msgSendId(UNUserNotificationCenter, sel_current) orelse
            return error.NoNotificationCenter;
        const sel = objc.sel_registerName("requestAuthorizationWithOptions:completionHandler:") orelse
            return error.SelectorNotFound;

        const ticket = ios_async.acquire(A.request_permission) orelse return poolFull();

        const Fn = *const fn (Id, Id, c_ulong, *anyopaque) callconv(.c) void;
        const func: Fn = @ptrCast(&objc.objc_msgSend);
        func(center, sel, un_options_alert_badge_sound, ios_async.boolErrorBlock(ticket));
    }

    /// Open the app's page in Settings and say whether iOS did.
    ///
    /// Ungated in the Swift dispatcher, so nothing above this refuses it, and
    /// it is the one action in this file that takes no payload at all.
    fn openSettings(self: *Self) !void {
        if (!is_darwin) return bridge_error.BridgeError.PlatformNotSupported;

        const url_string = settingsUrlString() orelse
            return bridge_error.BridgeError.PlatformNotSupported;

        const NSURL = objc.objc_getClass("NSURL") orelse
            return bridge_error.BridgeError.NativeCallFailed;
        const sel_with_string = objc.sel_registerName("URLWithString:") orelse
            return bridge_error.BridgeError.NativeCallFailed;
        const url = objc.msgSendId1(NSURL, sel_with_string, url_string) orelse {
            // Swift's `guard let url = URL(string:)` else branch, which rejects
            // with "Settings URL is unavailable".
            std.log.warn("openSettings: the settings URL did not parse", .{});
            return bridge_error.BridgeError.NativeCallFailed;
        };

        const UIApplication = objc.objc_getClass("UIApplication") orelse
            return bridge_error.BridgeError.PlatformNotSupported;
        const sel_shared = objc.sel_registerName("sharedApplication") orelse
            return bridge_error.BridgeError.NativeCallFailed;
        const app = objc.msgSendId(UIApplication, sel_shared) orelse
            return bridge_error.BridgeError.NativeCallFailed;

        const NSDictionary = objc.objc_getClass("NSDictionary") orelse
            return bridge_error.BridgeError.NativeCallFailed;
        const sel_dictionary = objc.sel_registerName("dictionary") orelse
            return bridge_error.BridgeError.NativeCallFailed;
        // `options:` is declared nonnull; an empty dictionary is the documented
        // way to pass none.
        const options = objc.msgSendId(NSDictionary, sel_dictionary) orelse
            return bridge_error.BridgeError.NativeCallFailed;

        const ticket = ios_async.acquire(A.open_settings) orelse {
            std.log.warn(
                "openSettings: no free reply slot; {d} native calls are already awaiting one",
                .{ios_async.max_in_flight},
            );
            return bridge_error.BridgeError.NativeCallFailed;
        };
        errdefer ios_async.abandon(ticket);
        publishSettingsCall(ticket);

        const sel_open = objc.sel_registerName("openURL:options:completionHandler:") orelse
            return bridge_error.BridgeError.NativeCallFailed;
        const OpenFn = *const fn (objc.id, objc.SEL, objc.id, objc.id, *anyopaque) callconv(.c) void;
        const openFn: OpenFn = @ptrCast(&objc.objc_msgSend);
        openFn(app, sel_open, url, options, @ptrCast(&settings_blocks[ticket.index]));

        _ = self;
    }
};

/// The answer for a full block pool. `BridgeError` has no "Busy";
/// INVALID_PARAMETER is the designated stand-in from the migration notes,
/// and the point is that the sixteen-plus-first concurrent prompt gets an
/// explicit rejection instead of a promise that never settles.
fn poolFull() bridge_error.BridgeError {
    std.log.warn("permission request refused: all {d} async slots in flight", .{ios_async.max_in_flight});
    return bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// Framework constants — transcribed, so pinned by tests below.
// =============================================================================

/// `EKEntityType`: NSUInteger. event = 0, reminder = 1.
const ek_entity_event: c_ulong = 0;
const ek_entity_reminder: c_ulong = 1;

/// `PHAccessLevel.readWrite` = 2 (NSInteger). `.addOnly` is 1; the spec
/// checks readWrite.
const ph_access_level_read_write: c_long = 2;

/// `CNEntityType.contacts` = 0 (NSInteger) — the only entity type there is.
const cn_entity_type_contacts: c_long = 0;

/// `UNAuthorizationOptions`: badge 1<<0 | sound 1<<1 | alert 1<<2 = 7,
/// matching Swift's `[.alert, .badge, .sound]` exactly — no provisional, no
/// carPlay, nothing the spec did not ask for.
const un_options_alert_badge_sound: c_ulong = 7;

// =============================================================================
// Status readers. Runtime class lookups only — no link-time framework
// dependency; see the module comment.
// =============================================================================

/// `+[CLLocationManager authorizationStatus]`. Deprecated since iOS 14 in
/// favour of the instance property, but it is the exact call the Swift spec
/// makes, needs no manager instance and no delegate, and reading it never
/// prompts. `CLAuthorizationStatus` is an `Int32` — the one status here that
/// is not NSInteger-sized, and a `c_long` cast would read 32 bits of
/// register garbage above it on a big-endian day; `i32` says what it is.
fn readLocationStatus() !i32 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const CLLocationManager = objc.objc_getClass("CLLocationManager") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("authorizationStatus") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id) callconv(.c) i32;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(CLLocationManager, sel);
}

/// `+[AVCaptureDevice authorizationStatusForMediaType:]` with
/// `AVMediaTypeVideo`.
fn readCameraStatus(allocator: std.mem.Allocator) !c_long {
    if (!is_darwin) return error.UnsupportedPlatform;

    const AVCaptureDevice = objc.objc_getClass("AVCaptureDevice") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("authorizationStatusForMediaType:") orelse return error.SelectorNotFound;
    const media = try mediaTypeVideo(allocator);
    const Fn = *const fn (Id, Id, Id) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(AVCaptureDevice, sel, media);
}

/// `-[AVAudioSession recordPermission]` on the shared instance.
fn readMicrophonePermission() !c_ulong {
    if (!is_darwin) return error.UnsupportedPlatform;

    const session = try audioSession();
    const sel = objc.sel_registerName("recordPermission") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id) callconv(.c) c_ulong;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(session, sel);
}

/// `+[PHPhotoLibrary authorizationStatusForAccessLevel:]` — the level-aware
/// form the spec calls (`for: .readWrite`), not the level-less deprecated one,
/// which answers `.authorized` for limited access and would erase the
/// distinction `photosStatusJson` exists to keep.
fn readPhotosStatus() !c_long {
    if (!is_darwin) return error.UnsupportedPlatform;

    const PHPhotoLibrary = objc.objc_getClass("PHPhotoLibrary") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("authorizationStatusForAccessLevel:") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id, c_long) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(PHPhotoLibrary, sel, ph_access_level_read_write);
}

/// `+[CNContactStore authorizationStatusForEntityType:]`. A class method —
/// no store instance is needed to *read*, which is what keeps this arm
/// servable while the request arm is not.
fn readContactsStatus() !c_long {
    if (!is_darwin) return error.UnsupportedPlatform;

    const CNContactStore = objc.objc_getClass("CNContactStore") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("authorizationStatusForEntityType:") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id, c_long) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(CNContactStore, sel, cn_entity_type_contacts);
}

/// `+[EKEventStore authorizationStatusForEntityType:]`, shared by calendar
/// (event = 0) and reminders (reminder = 1).
fn readEventKitStatus(entity: c_ulong) !c_long {
    if (!is_darwin) return error.UnsupportedPlatform;

    const EKEventStore = objc.objc_getClass("EKEventStore") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("authorizationStatusForEntityType:") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id, c_ulong) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(EKEventStore, sel, entity);
}

/// `+[CMMotionActivityManager authorizationStatus]`.
fn readMotionStatus() !c_long {
    if (!is_darwin) return error.UnsupportedPlatform;

    const CMMotionActivityManager = objc.objc_getClass("CMMotionActivityManager") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("authorizationStatus") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(CMMotionActivityManager, sel);
}

/// `+[CBManager authorization]` — the class property getter, whose selector
/// is just the property name. Reading it does not start Bluetooth and does
/// not prompt, unlike instantiating a central manager.
fn readBluetoothStatus() !c_long {
    if (!is_darwin) return error.UnsupportedPlatform;

    const CBManager = objc.objc_getClass("CBManager") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("authorization") orelse return error.SelectorNotFound;
    const Fn = *const fn (Id, Id) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(CBManager, sel);
}

/// `+[AVAudioSession sharedInstance]`, shared by the microphone read and
/// request arms.
fn audioSession() !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const AVAudioSession = objc.objc_getClass("AVAudioSession") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("sharedInstance") orelse return error.SelectorNotFound;
    return objc.msgSendId(AVAudioSession, sel) orelse error.NoAudioSession;
}

// -----------------------------------------------------------------------------
// AVMediaTypeVideo
// -----------------------------------------------------------------------------

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// dyld's "search every image" pseudo-handle, (void *)-2 on Darwin.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// The `AVMediaTypeVideo` constant, without a link-time AVFoundation
/// dependency.
///
/// Extern-linking the `NSString *const` the way `bridge_mobile_storage` links
/// `kSec*` would force `-framework AVFoundation` onto every consumer of the
/// static library — a build-system change no other part of this module needs,
/// since classes are found at runtime. So: `dlsym` the symbol out of whatever
/// loaded AVFoundation (if `AVCaptureDevice` resolved, it is loaded and the
/// symbol is there), and fall back to the documented constant *value*,
/// `@"vide"`, which AVFoundation compares by content — a media type travels
/// through dictionaries and `isEqual:`, never pointer identity, which is also
/// why Swift's bridged strings work.
fn mediaTypeVideo(allocator: std.mem.Allocator) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    if (dlsym(RTLD_DEFAULT, "AVMediaTypeVideo")) |sym| {
        // The symbol is the *variable* — an `NSString *` — so one dereference
        // yields the object. Guarded: a resolved symbol holding nil would
        // otherwise put nil into an ObjC argument that must not be.
        const slot: *Id = @ptrCast(@alignCast(sym));
        if (slot.*) |ns| return ns;
    }
    const ns = try objc.createNSString("vide", allocator);
    if (ns == null) return error.NSStringCreationFailed;
    return ns;
}

// =============================================================================
// Tests. Host-only by construction: everything that decides what the page
// sees — routing, name mapping, status mapping, payload validation — is a
// pure function beside the readers, and no test dispatches a permission kind
// whose reader would touch a live framework (on a developer's Mac some of
// these classes exist, and a *request* arm would put a real TCC prompt on
// someone's screen).
// =============================================================================

// ===========================================================================
// openSettings
//
// Held back until now for a reason recorded at the top of this file: its reply
// is a bare JSON *boolean*, and `ios_async.boolBlock` answers the strings
// `"granted"`/`"denied"`. That mismatch is not cosmetic — `false` is falsy and
// `"denied"` is truthy, so `if (await craft.permissions.openSettings())` would
// take its success branch on failure.
//
// The note said claiming it meant first extending `ios_async` with a
// bool-literal reply. It did not: the module-owned global block that
// `bridge_mobile_auth.zig` and `bridge_mobile_siri.zig` now use answers through
// `deliverJson`, which can carry any literal. What the note was really
// objecting to is still true and still avoided here — "the repo's last
// hand-rolled completion block was stack-allocated with a doc comment asserting
// a lifetime async does not honour" (`bridge_mobile_system.zig:391`). That one
// survives only because `openURL:` copies an escaping block, which is the
// callee's choice to make and not a guarantee this file wants to depend on.
// Every block below is global, so `Block_copy` is identity and the question
// does not arise.
// ===========================================================================

/// `UIApplication.openSettingsURLString`.
///
/// An `extern NSString * const` in UIKit, read through its symbol rather than
/// rebuilt from the literal `"app-settings:"`. The constant's *value* is not
/// API — Apple has changed it before — and a hardcoded string that stops
/// matching would open nothing while still reporting whatever `openURL:`
/// said about a URL iOS does not recognise.
fn settingsUrlString() ?objc.id {
    const symbol = dlsym(RTLD_DEFAULT, "UIApplicationOpenSettingsURLString") orelse {
        std.log.warn(
            "openSettings: UIApplicationOpenSettingsURLString is not in this process",
            .{},
        );
        return null;
    };
    const cell: *const objc.id = @ptrCast(@alignCast(symbol));
    return cell.*;
}

/// The two literals the completion can put on the wire.
///
/// Swift's `resolveCallback(callbackId, result: opened)` under
/// `.fragmentsAllowed`, so the page receives a bare boolean and not an object.
const opened_reply = "true";
const not_opened_reply = "false";

const SettingsBlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// `void (^)(BOOL)`.
const SettingsBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const SettingsBlockDescriptor,
};

/// 1 << 28. A global block is never copied, so it can be handed to an API that
/// escapes it with no heap copy and no descriptor lifetime.
const SETTINGS_BLOCK_IS_GLOBAL: c_int = 1 << 28;

const settings_block_descriptor = SettingsBlockDescriptor{ .size = @sizeOf(SettingsBlock) };

extern var _NSConcreteGlobalBlock: anyopaque;

fn makeSettingsInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const SettingsBlock, opened: bool) callconv(.c) void {
            settingsOpened(index, opened);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeSettingsBlocks() [ios_async.max_in_flight]SettingsBlock {
    var out: [ios_async.max_in_flight]SettingsBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = SETTINGS_BLOCK_IS_GLOBAL,
            .invoke = makeSettingsInvoke(@intCast(i)),
            .descriptor = &settings_block_descriptor,
        };
    }
    return out;
}

var settings_blocks: [ios_async.max_in_flight]SettingsBlock =
    if (is_darwin) makeSettingsBlocks() else undefined;

/// The ticket each slot's block will answer.
var settings_calls: [ios_async.max_in_flight]?ios_async.Ticket = @splat(null);
var settings_mutex: compat_mutex.Mutex = .{};

fn publishSettingsCall(ticket: ios_async.Ticket) void {
    settings_mutex.lock();
    defer settings_mutex.unlock();
    settings_calls[ticket.index] = ticket;
}

/// Read and clear, so a second fire is a no-op rather than a second reply.
fn takeSettingsCall(index: u5) ?ios_async.Ticket {
    settings_mutex.lock();
    defer settings_mutex.unlock();
    const ticket = settings_calls[index];
    settings_calls[index] = null;
    return ticket;
}

/// UIKit calls this on the main queue, but `ios_async` hops anyway — the reply
/// path is the same one every other module uses and does not special-case its
/// caller's queue.
fn settingsOpened(index: u5, opened: bool) void {
    if (!is_darwin) return;

    const ticket = takeSettingsCall(index) orelse {
        std.log.warn(
            "openSettings completion fired for slot {d} with no call recorded; ignored",
            .{index},
        );
        return;
    };
    // A bare literal, not "granted"/"denied": `false` has to stay falsy.
    ios_async.deliverJson(ticket, if (opened) opened_reply else not_opened_reply);
}

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 3), capability_actions.len);
    try testing.expectEqualStrings(A.check_permission, capability_actions[0].name);
    try testing.expectEqualStrings(A.request_permission, capability_actions[1].name);
    try testing.expectEqualStrings(A.open_settings, capability_actions[2].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "the action names are the ones the Swift dispatcher answers" {
    // The wire contract, spelled out. The conformance scan catches a name the
    // spec lacks; it cannot catch both being renamed in step, which this holds.
    try testing.expectEqualStrings("checkPermission", A.check_permission);
    try testing.expectEqualStrings("requestPermission", A.request_permission);
    try testing.expectEqualStrings("openSettings", A.open_settings);
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
    // Each declaration must claim a distinct route and every route must be
    // claimed — counting alone would let two rows share one route while
    // another went undeclared.
    var claimed = std.mem.zeroes([std.enums.values(Route).len]bool);
    for (capability_actions) |decl| {
        const route = routeFor(decl.name) orelse return error.DeclaredActionDoesNotRoute;
        const slot = @backingInt(route);
        if (claimed[slot]) return error.TwoDeclarationsShareARoute;
        claimed[slot] = true;
    }
    for (claimed) |taken| {
        if (!taken) return error.RouteNotDeclared;
    }
}

test "openSettings answers with a bare boolean, never granted/denied" {
    // The pin for the decision this module used to record the other way. Its
    // reply is a bare boolean, `ios_async.boolBlock` replies "granted"/"denied",
    // and "denied" is truthy — a page's `if (await openSettings())` would take
    // the success branch on failure. That is why the completion below is the
    // module's own block delivering a literal, and why these two strings are
    // pinned rather than left to whoever edits the handler next.
    try testing.expectEqualStrings("true", opened_reply);
    try testing.expectEqualStrings("false", not_opened_reply);

    // And it is served here now, rather than handed to the shim.
    try testing.expect(routeFor("openSettings") != null);
}

test "each openSettings block is global and has its own invoke" {
    // Global, not the stack-allocated shape `bridge_mobile_system.zig:391`
    // uses: a stack block is only safe because `openURL:` chooses to copy an
    // escaping handler, and that is the callee's choice rather than a
    // guarantee. `Block_copy` on a global block is identity, so the question
    // does not arise.
    if (!is_darwin) return error.SkipZigTest;

    for (&settings_blocks) |*b| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, b.isa);
        try testing.expectEqual(SETTINGS_BLOCK_IS_GLOBAL, b.flags);
        try testing.expectEqual(@sizeOf(SettingsBlock), @as(usize, @intCast(b.descriptor.size)));
    }
    try testing.expect(settings_blocks[0].invoke != settings_blocks[1].invoke);
}

test "an openSettings completion for a slot with no recorded call is ignored" {
    if (!is_darwin) return error.SkipZigTest;

    settings_mutex.lock();
    for (&settings_calls) |*entry| entry.* = null;
    settings_mutex.unlock();

    settingsOpened(0, true);
    settingsOpened(0, false);
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = PermissionsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Casing is how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("checkpermission", "{}"),
    );
    // The Swift helper's name, which is not an action name.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("permissionStatus", "{}"),
    );
    // The desktop namespace's method names, which are a different bridge.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("check", "{\"permission\":\"camera\"}"),
    );
}

test "every declared action dispatches to something" {
    // `{}` has no `permission`, so both fail validation *before* any
    // framework call — which is what makes this safe on a host. What it rules
    // out is a name in the table `handleMessage` does not compare against.
    var bridge = PermissionsBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        // `openSettings` takes no payload, so it gets past validation and
        // refuses on the host's missing UIKit instead. `UnknownAction` is the
        // only forbidden outcome — that would mean a declared name the
        // handler never compares against.
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != bridge_error.BridgeError.UnknownAction);
            continue;
        };
    }
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = PermissionsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.check_permission, "{not json"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.request_permission, "{not json"),
    );
}

fn expectPermissionName(json: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(expected, try permissionName(parsed.value));
}

fn expectPermissionNameError(json: []const u8, expected: anyerror) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, permissionName(parsed.value));
}

test "the permission field is the one the page sends, extras ignored" {
    try expectPermissionName("{\"permission\":\"camera\"}", "camera");
    // `_invoke` merges `action` and `callbackId` into the payload it posts;
    // their presence must not disturb the read.
    try expectPermissionName(
        "{\"permission\":\"microphone\",\"action\":\"checkPermission\",\"callbackId\":\"cb_1\"}",
        "microphone",
    );
}

test "a missing, null, or non-string permission is refused" {
    // Swift folds all three into one "Missing permission" INVALID_ARGUMENT
    // reject; the codes here split into the two nearest words, but every case
    // still rejects — no arm defaults the field or falls through silently.
    try expectPermissionNameError("{}", bridge_error.BridgeError.MissingData);
    try expectPermissionNameError("{\"permission\":null}", bridge_error.BridgeError.InvalidParameter);
    try expectPermissionNameError("{\"permission\":7}", bridge_error.BridgeError.InvalidParameter);
    try expectPermissionNameError("[]", bridge_error.BridgeError.InvalidJSON);
    try expectPermissionNameError("\"camera\"", bridge_error.BridgeError.InvalidJSON);
}

test "the eleven spec spellings map to their kinds" {
    try testing.expectEqual(Kind.location, kindFor("location"));
    try testing.expectEqual(Kind.location_always, kindFor("locationAlways"));
    try testing.expectEqual(Kind.camera, kindFor("camera"));
    try testing.expectEqual(Kind.microphone, kindFor("microphone"));
    try testing.expectEqual(Kind.photos, kindFor("photos"));
    try testing.expectEqual(Kind.contacts, kindFor("contacts"));
    try testing.expectEqual(Kind.calendar, kindFor("calendar"));
    try testing.expectEqual(Kind.reminders, kindFor("reminders"));
    try testing.expectEqual(Kind.motion, kindFor("motion"));
    try testing.expectEqual(Kind.bluetooth, kindFor("bluetooth"));
    try testing.expectEqual(Kind.notifications, kindFor("notifications"));
}

test "an unrecognised permission resolves undetermined, as the spec's default arm" {
    try testing.expectEqual(Kind.unknown, kindFor("telepathy"));
    // Case-sensitive, as Swift's switch is.
    try testing.expectEqual(Kind.unknown, kindFor("Camera"));
    try testing.expectEqual(Kind.unknown, kindFor(""));

    // End to end: both actions *resolve* for an unknown name — no error, no
    // shim fall-through — because that is what the Swift default arm does.
    var bridge = PermissionsBridge.init(testing.allocator);
    defer bridge.deinit();
    try bridge.handleMessage(A.check_permission, "{\"permission\":\"telepathy\"}");
    try bridge.handleMessage(A.request_permission, "{\"permission\":\"telepathy\"}");
}

test "a NUL-carrying permission lands in unknown rather than being truncated" {
    // The name is only compared, never handed to `stringWithUTF8String:`, so
    // there is nothing to truncate and no refusal is needed: "camera\x00x"
    // is not "camera", fails every comparison, and answers "undetermined" —
    // the same answer Swift's default arm gives the NUL-keeping original.
    try testing.expectEqual(Kind.unknown, kindFor("camera\x00x"));

    var bridge = PermissionsBridge.init(testing.allocator);
    defer bridge.deinit();
    try bridge.handleMessage(A.check_permission, "{\"permission\":\"camera\\u0000x\"}");
}

test "restricted outranks denied outranks granted" {
    // Swift's helper checks in this order, so a status that set two flags
    // answers the severest one. The spellings must also match ios_async's
    // hard-coded completion replies byte for byte, or one action would speak
    // two dialects depending on which arm answered.
    try testing.expectEqualStrings("\"restricted\"", statusJson(true, true, true));
    try testing.expectEqualStrings("\"denied\"", statusJson(true, true, false));
    try testing.expectEqualStrings("\"granted\"", statusJson(true, false, false));
    try testing.expectEqualStrings("\"undetermined\"", statusJson(false, false, false));
}

test "location statuses map per the spec, whenInUse counting only for 'location'" {
    // 0 notDetermined, 1 restricted, 2 denied, 3 always, 4 whenInUse.
    try testing.expectEqualStrings("\"undetermined\"", locationStatusJson(0, false));
    try testing.expectEqualStrings("\"restricted\"", locationStatusJson(1, false));
    try testing.expectEqualStrings("\"denied\"", locationStatusJson(2, false));
    try testing.expectEqualStrings("\"granted\"", locationStatusJson(3, false));
    try testing.expectEqualStrings("\"granted\"", locationStatusJson(4, false));

    // The fork: a whenInUse grant checked as "locationAlways" is not granted
    // — and not denied either. "undetermined" is the spec's answer.
    try testing.expectEqualStrings("\"granted\"", locationStatusJson(3, true));
    try testing.expectEqualStrings("\"undetermined\"", locationStatusJson(4, true));

    // A future status value is not guessed at.
    try testing.expectEqualStrings("\"undetermined\"", locationStatusJson(5, false));
}

test "the shared 0..3 layout maps for camera, contacts, motion and bluetooth" {
    try testing.expectEqualStrings("\"undetermined\"", simpleAuthStatusJson(0));
    try testing.expectEqualStrings("\"restricted\"", simpleAuthStatusJson(1));
    try testing.expectEqualStrings("\"denied\"", simpleAuthStatusJson(2));
    try testing.expectEqualStrings("\"granted\"", simpleAuthStatusJson(3));
    // iOS 18's CNAuthorizationStatus.limited (4) and anything later: Swift's
    // `status == .authorized` is false for them, so "undetermined" — folded,
    // not promoted.
    try testing.expectEqualStrings("\"undetermined\"", simpleAuthStatusJson(4));
}

test "photos limited counts as granted" {
    try testing.expectEqualStrings("\"granted\"", photosStatusJson(3));
    try testing.expectEqualStrings("\"granted\"", photosStatusJson(4));
    try testing.expectEqualStrings("\"denied\"", photosStatusJson(2));
    try testing.expectEqualStrings("\"restricted\"", photosStatusJson(1));
    try testing.expectEqualStrings("\"undetermined\"", photosStatusJson(0));
    // Unlike EventKit, only exactly limited is promoted; 5 is not presumed to
    // be an access level.
    try testing.expectEqualStrings("\"undetermined\"", photosStatusJson(5));
}

test "calendar fullAccess and writeOnly both count as granted" {
    // Swift: `status == .authorized || status.rawValue >= 4` — the iOS 17
    // renames land on 3 (fullAccess) and 4 (writeOnly).
    try testing.expectEqualStrings("\"granted\"", calendarStatusJson(3));
    try testing.expectEqualStrings("\"granted\"", calendarStatusJson(4));
    try testing.expectEqualStrings("\"granted\"", calendarStatusJson(5));
    try testing.expectEqualStrings("\"denied\"", calendarStatusJson(2));
    try testing.expectEqualStrings("\"restricted\"", calendarStatusJson(1));
    try testing.expectEqualStrings("\"undetermined\"", calendarStatusJson(0));
}

test "the microphone four-char codes are the documented ones" {
    // AVAudioSessionRecordPermission is the one status that is not a small
    // enum, and a mistranscribed code would silently reclassify every answer.
    try testing.expectEqual(@as(c_ulong, 1970168948), record_permission_undetermined);
    try testing.expectEqual(@as(c_ulong, 1684369017), record_permission_denied);
    try testing.expectEqual(@as(c_ulong, 1735552628), record_permission_granted);

    try testing.expectEqualStrings("\"granted\"", microphoneStatusJson(record_permission_granted));
    try testing.expectEqualStrings("\"denied\"", microphoneStatusJson(record_permission_denied));
    try testing.expectEqualStrings("\"undetermined\"", microphoneStatusJson(record_permission_undetermined));
    // No restricted case exists for the microphone, and junk is not guessed at.
    try testing.expectEqualStrings("\"undetermined\"", microphoneStatusJson(0));
}

test "what Zig cannot answer honestly falls through to the shim, payload intact" {
    // UnknownAction is the dispatcher's "not mine, ask the next"; the chain
    // ends at handOffToHost with the same action and the same `d`, and the
    // un-migrated Swift arm answers as it always has. Any *other* error here
    // would be final and would take a working reply away from the page.
    var bridge = PermissionsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage(A.check_permission, "{\"permission\":\"notifications\"}"),
    );

    const deferred_requests = [_][]const u8{
        "{\"permission\":\"location\"}",
        "{\"permission\":\"locationAlways\"}",
        "{\"permission\":\"photos\"}",
        "{\"permission\":\"contacts\"}",
        "{\"permission\":\"calendar\"}",
        "{\"permission\":\"reminders\"}",
    };
    for (deferred_requests) |payload| {
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(A.request_permission, payload),
        );
    }
}

test "requesting motion or bluetooth resolves undetermined, as the spec does" {
    // The Swift request switch has no arm for either — both fall into
    // `default` and resolve "undetermined" without prompting. Erroring or
    // falling through would change behaviour the page can already observe.
    var bridge = PermissionsBridge.init(testing.allocator);
    defer bridge.deinit();

    try bridge.handleMessage(A.request_permission, "{\"permission\":\"motion\"}");
    try bridge.handleMessage(A.request_permission, "{\"permission\":\"bluetooth\"}");
}

test "the notification options are Swift's [.alert, .badge, .sound]" {
    // badge 1<<0, sound 1<<1, alert 1<<2. A wrong mask here would not fail —
    // it would quietly request a different set of capabilities than every
    // existing app was granted under.
    try testing.expectEqual(@as(c_ulong, 1 | 2 | 4), un_options_alert_badge_sound);
}

test "the framework constants that are passed as arguments are the documented ones" {
    // Each of these rides into objc_msgSend as a raw integer; a wrong value
    // is not an error but a question about a different entity.
    try testing.expectEqual(@as(c_ulong, 0), ek_entity_event);
    try testing.expectEqual(@as(c_ulong, 1), ek_entity_reminder);
    try testing.expectEqual(@as(c_long, 2), ph_access_level_read_write);
    try testing.expectEqual(@as(c_long, 0), cn_entity_type_contacts);
}
