const std = @import("std");
const testing = std.testing;

/// What iOS owes the page, and who currently owes it.
///
/// The Swift template is the specification for the Zig-native migration: its
/// dispatcher is the list of actions a craft iOS app answers today, and Zig has
/// to end up answering all of them. This file is what stops an action being
/// dropped on the way across.
///
/// It exists because the repo already demonstrated the failure. `CraftApp.swift`
/// disagreed with itself: its injected JavaScript offered five `ota*` methods
/// that its own `switch` never handled, and because those methods bypassed the
/// `_createCallback` path that owns the timeout, calling one returned a promise
/// that never settled — not a rejection, not a timeout, nothing. One file, two
/// halves, no mechanism to notice.
///
/// Embedded with `@embedFile` rather than read from disk, so the test is
/// hermetic and reads exactly the bytes the build saw.
const swift_spec = @embedFile("CraftApp.swift");

/// Every Zig module that serves part of the `mobile` namespace. A module
/// migrating actions out of the Swift spec adds itself here — and the ratchet
/// below is what forces that to happen, because migrated actions the scan
/// cannot see would read as "dropped" and fail the build.
const zig_sources = [_][]const u8{
    @embedFile("src/bridge_mobile.zig"),
    @embedFile("src/bridge_mobile_clipboard.zig"),
    @embedFile("src/bridge_mobile_haptics.zig"),
    @embedFile("src/bridge_mobile_device.zig"),
    @embedFile("src/bridge_mobile_system.zig"),
    @embedFile("src/bridge_mobile_display.zig"),
    @embedFile("src/bridge_mobile_storage.zig"),
    @embedFile("src/bridge_mobile_misc.zig"),
    @embedFile("src/bridge_mobile_shortcuts.zig"),
    @embedFile("src/bridge_mobile_securestore.zig"),
    @embedFile("src/bridge_mobile_biometric.zig"),
    @embedFile("src/bridge_mobile_permissions.zig"),
    @embedFile("src/bridge_mobile_db.zig"),
    @embedFile("src/bridge_mobile_notifcancel.zig"),
    @embedFile("src/bridge_mobile_notifications.zig"),
    @embedFile("src/bridge_mobile_bgtasks.zig"),
    @embedFile("src/bridge_mobile_watch.zig"),
    @embedFile("src/bridge_mobile_location.zig"),
    @embedFile("src/bridge_mobile_locrecording.zig"),
    @embedFile("src/bridge_mobile_ar.zig"),
    @embedFile("src/bridge_mobile_motion.zig"),
    @embedFile("src/bridge_mobile_imagepicker.zig"),
    @embedFile("src/bridge_mobile_filepicker.zig"),
    @embedFile("src/bridge_mobile_contactpicker.zig"),
    @embedFile("src/bridge_mobile_calendar.zig"),
    @embedFile("src/bridge_mobile_contacts.zig"),
    @embedFile("src/bridge_mobile_vision.zig"),
    @embedFile("src/bridge_mobile_auth.zig"),
    @embedFile("src/bridge_mobile_siri.zig"),
    @embedFile("src/bridge_mobile_pdf.zig"),
    @embedFile("src/bridge_mobile_bluetooth.zig"),
    @embedFile("src/bridge_mobile_audiorec.zig"),
    @embedFile("src/bridge_mobile_health.zig"),
    @embedFile("src/bridge_mobile_speech.zig"),
    @embedFile("src/bridge_mobile_nfc.zig"),
    @embedFile("src/bridge_mobile_auth_apple.zig"),
};

/// The action list lives in the `switch action` block, and nowhere else.
///
/// Bounding the scan matters more than it looks. `CraftApp.swift` contains 139
/// `case "..."` labels, but only 106 are actions — the rest are sub-switches
/// over haptic styles, permission names, orientations, AR primitives. A whole
/// file scan would count `case "box"` as a bridge action and then fail forever
/// on a list nobody can satisfy.
const dispatch_begin = "func userContentController(";
const dispatch_end = "func webView(";

/// How many spec actions Zig does not serve yet.
///
/// A ratchet, in the shape `capabilities_test.zig` already uses for
/// `max_undeclared`: the number may only go down, and lowering it is what a
/// migration phase costs. It starts at the full spec minus the vertical slice.
///
/// If this ever needs raising, something has been removed from Zig without
/// being removed from the spec, and that is the conversation this constant
/// exists to force.
///
/// History: 105 after the vertical slice (getDeviceInfo); 86 after Tier 0
/// landed clipboard, haptics, device, system, display, and storage; 74 after
/// the secure tier landed flashlight, shortcuts, the Keychain secure store,
/// biometric persistence, and permissions — including the first async reply;
/// 70 after the data tier landed SQLite (dbExecute/dbQuery) and the
/// notification cancels; 64 after pending notifications, background-task
/// scheduling/cancellation, and Watch context/reachability.
///
/// Three actions in that round were deliberately left with the Swift shim
/// rather than served here: scheduleNotification, registerBackgroundTask and
/// sendToWatch all hand iOS a callback that fires later, which needs an event
/// channel iOS does not have yet. Falling through beats `.unavailable`, which
/// would make Zig dispatch and refuse an action the shim serves correctly.
/// 58 after the event channel landed and unblocked the location tier: the
/// first actions that push a stream to the page rather than answering a call.
/// 53 after the presented pickers — image, document and contact — landed on
/// the delegate factory, the last of the three mechanisms this migration
/// needed. Everything remaining is a repetition of a proven pattern.
/// 48 after calendar and contacts. Speech was researched in full and left
/// with the shim: neither action replies, so unlike the earlier deferrals
/// there is no promise to strand and falling through costs the page nothing.
/// 26 once speech came back and took both. The deferral had listed five
/// preconditions and four blockers; the load-bearing one was the realtime
/// audio tap, which is the first callback in this migration that runs on a
/// thread where a lock is a bug rather than a slowdown.
/// 24 with scanNFC, which had no recorded reason at all — not a deferral that
/// expired, just an action nobody had reached.
/// 23 with signInWithApple, which needed the first object-returning delegate
/// method in the migration (`presentationAnchorForAuthorizationController:`).
/// Of the four that had no recorded reason, scanQRCode turned out to have a
/// real one and is in the table below; `registerPush` is the last, and its
/// device token arrives through a notification the Swift app delegate posts,
/// which is a coupling to weigh rather than a wall.
/// 25 with scheduleNotification. Its deferral was the first to expire on its
/// own: the blocker recorded in `bridge_mobile_notifications.zig` was that
/// `ios_async` could only resolve, so an action whose two failure paths are
/// both rejections could not be served without fabricating success —
/// and `deliverErrorCode` landed the day after that was written. Worth
/// re-reading the other deferrals for the same reason before assuming they
/// still hold.
const max_not_yet_migrated: usize = 13;

fn dispatcherRegion() []const u8 {
    const begin = std.mem.indexOf(u8, swift_spec, dispatch_begin) orelse return "";
    const rest = swift_spec[begin..];
    const end = std.mem.indexOf(u8, rest, dispatch_end) orelse return rest;
    return rest[0..end];
}

/// Every `case "name":` in a region, as a set.
fn collectCases(allocator: std.mem.Allocator, region: []const u8) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    var search: usize = 0;
    while (std.mem.indexOfPos(u8, region, search, "case \"")) |at| {
        const name_start = at + "case \"".len;
        const name_end = std.mem.indexOfScalarPos(u8, region, name_start, '"') orelse break;
        try set.put(region[name_start..name_end], {});
        search = name_end;
    }
    return set;
}

/// Every action the injected JavaScript posts, as a set.
fn collectPostedActions(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    const needle = "action: '";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, swift_spec, search, needle)) |at| {
        const name_start = at + needle.len;
        const name_end = std.mem.indexOfScalarPos(u8, swift_spec, name_start, '\'') orelse break;
        try set.put(swift_spec[name_start..name_end], {});
        search = name_end;
    }
    return set;
}

/// Every action name declared in the `A` blocks of every mobile module.
fn collectZigActions(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    // Duplicates are an error, not a merge. `ios_dispatch.route` takes the
    // first module whose handleMessage does not return UnknownAction, so two
    // modules declaring one action makes dispatch order — an implementation
    // detail of a comptime tuple — decide which implementation a page gets.
    // Folding them into one set, as this did, made that invisible.
    for (zig_sources) |source| {
        var it = std.mem.splitScalar(u8, source, '\n');
        var in_block = false;
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "pub const A = struct {")) {
                in_block = true;
                continue;
            }
            if (in_block and std.mem.eql(u8, trimmed, "};")) break;
            if (!in_block) continue;

            // pub const get_device_info = "getDeviceInfo";
            const open = std.mem.indexOfScalar(u8, trimmed, '"') orelse continue;
            const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, '"') orelse continue;
            const name = trimmed[open + 1 .. close];
            if (set.contains(name)) {
                std.debug.print(
                    "action '{s}' is declared by more than one mobile module.\n" ++
                        "  Dispatch order would silently pick one.\n",
                    .{name},
                );
                return error.ActionDeclaredTwice;
            }
            try set.put(name, {});
        }
    }
    return set;
}

test "the spec scan finds the dispatcher, and finds actions in it" {
    // Non-vacuity, first. Every assertion below is a subset check, and a scan
    // that silently matched nothing would satisfy all of them. This is the
    // guard that makes the rest mean something: rename the Swift dispatcher and
    // this fails, rather than the suite going quietly green on an empty set.
    const region = dispatcherRegion();
    try testing.expect(region.len > 1000);

    var cases = try collectCases(testing.allocator, region);
    defer cases.deinit();
    try testing.expect(cases.count() >= 100);
}

test "every action the page can call is one the spec handles" {
    // The `ota*` check. Five methods in the injected JavaScript posted actions
    // the switch never handled, and because they bypassed `_createCallback`
    // they had no timeout either — so calling one returned a promise that never
    // settled. There is deliberately no allow-list here: a page-callable method
    // with nothing behind it is always a bug, and "documented exception" is how
    // it would come back.
    var handled = try collectCases(testing.allocator, dispatcherRegion());
    defer handled.deinit();

    var posted = try collectPostedActions(testing.allocator);
    defer posted.deinit();

    var checked: usize = 0;
    var it = posted.keyIterator();
    while (it.next()) |name| {
        if (!handled.contains(name.*)) {
            std.debug.print(
                "craft.{s}() posts action '{s}', which no dispatcher case handles.\n" ++
                    "  The promise it returns can never settle.\n",
                .{ name.*, name.* },
            );
            return error.PageCanCallAnActionNothingHandles;
        }
        checked += 1;
    }
    try testing.expect(checked >= 50);
}

/// Every action deliberately left with the Swift shim, and why.
///
/// This exists because the reasons kept rotting. They lived in two places that
/// nothing verified — a prose document and a module comment — and both drifted:
/// `docs/ios-development.md` listed thirteen actions as permanently Swift while
/// five of them had already been migrated, and
/// `bridge_mobile_notifications.zig` explained that `scheduleNotification`
/// could not be served for a day longer than that was true, which kept the
/// action with the shim through several passes that each read the note and
/// believed it.
///
/// A list is only load-bearing if something fails when it is wrong. The test
/// below asserts each entry is a real spec action *and* still unmigrated, so
/// migrating one of these breaks the build until its row is deleted. That is
/// the property the doc never had.
///
/// Not exhaustive, and deliberately not: this records deferrals that have a
/// *reason worth keeping*. An action absent from both this table and the Zig
/// modules is simply not done yet, which is a different and honest state.
const Deferral = struct { action: []const u8, reason: []const u8 };

const deliberate_deferrals = [_]Deferral{
    // ARKit / SceneKit. `docs/ios-development.md` asked for this boundary to be
    // declared in `capability_registry.zig`; that registry is desktop-only —
    // 51 namespaces, no `mobile`, and neither `ios.zig` nor `ios_dispatch.zig`
    // reads it — so the boundary is recorded here instead, where the tooling
    // that counts unmigrated actions can see it.

    // StoreKit 2. Narrower than "no ObjC surface": StoreKit *1* is ObjC and
    // `bridge_iap.zig` already drives it from Zig on macOS, so this is a choice
    // about which StoreKit iOS targets, not an impossibility.
    .{ .action = "getProducts", .reason = "Product.PurchaseResult is Swift-only; StoreKit 1 would be a product decision" },
    .{ .action = "purchase", .reason = "Product.PurchaseResult is Swift-only; StoreKit 1 would be a product decision" },
    .{ .action = "restorePurchases", .reason = "Product.PurchaseResult is Swift-only; StoreKit 1 would be a product decision" },

    .{ .action = "startLiveActivity", .reason = "ActivityKit is Swift-only; no ObjC class to reach" },
    .{ .action = "updateLiveActivity", .reason = "ActivityKit is Swift-only; no ObjC class to reach" },
    .{ .action = "endLiveActivity", .reason = "ActivityKit is Swift-only; no ObjC class to reach" },

    .{ .action = "updateWidget", .reason = "WidgetCenter has no ObjC class; only a swiftself trampoline reaches it" },
    .{ .action = "reloadWidgets", .reason = "WidgetCenter has no ObjC class; only a swiftself trampoline reaches it" },

    // Structural, and checked again in the sweep that produced this table.
    .{ .action = "registerBackgroundTask", .reason = "BGTaskScheduler.register must run before launch finishes; a page call is late by construction" },
    .{ .action = "getInitialURL", .reason = "DeepLinkManager is pure Swift with no @objc; the launch URL is not re-derivable" },

    // The device token is delivered to
    // `didRegisterForRemoteNotificationsWithDeviceToken` on `CraftAppDelegate`,
    // which SwiftUI instantiates and owns via
    // `@UIApplicationDelegateAdaptor` — Zig cannot replace it or reliably graft
    // a method onto it. The token then reaches the page through an
    // `NSNotification` that Swift posts. Zig *can* observe that notification,
    // so this is a coupling rather than a wall, and it is recorded as what it
    // is: serving the action would mean depending on Swift to keep posting a
    // name the spec is free to change.
    .{ .action = "registerPush", .reason = "the device token lands on a SwiftUI-owned app delegate; Zig could only observe a notification Swift posts" },

    // VisionKit's `DataScannerViewController` is Swift-only: the framework's
    // Objective-C headers carry DocumentCamera and nothing else, and the
    // delegate callback takes a `RecognizedItem`, a Swift enum with associated
    // values that `objc_msgSend` cannot destructure. Same class of wall as
    // ActivityKit, and checked against the iphonesimulator SDK rather than
    // assumed.
    .{ .action = "scanQRCode", .reason = "VisionKit's DataScanner is Swift-only; the delegate takes a Swift enum with associated values" },

    // UIImagePickerController delivers the movie URL through its Swift-owned
    // delegate. The shim now reads and encodes it correctly; Zig deliberately
    // leaves the action there rather than install a competing picker delegate.
    .{ .action = "startVideoRecording", .reason = "the completed movie arrives through the Swift coordinator's UIImagePickerController delegate" },
};

test "every recorded deferral is real, and still a deferral" {
    // The anti-rot property. A deferral that has been migrated must fail here
    // rather than sit in a list telling the next reader not to bother.
    var spec = try collectCases(testing.allocator, dispatcherRegion());
    defer spec.deinit();

    var zig = try collectZigActions(testing.allocator);
    defer zig.deinit();

    for (deliberate_deferrals) |d| {
        if (!spec.contains(d.action)) {
            std.debug.print(
                "deferral table names `{s}`, which the spec's dispatcher does not have — typo, or the action was renamed\n",
                .{d.action},
            );
            return error.DeferralNamesNoSuchAction;
        }
        if (zig.contains(d.action)) {
            std.debug.print(
                "deferral table still lists `{s}`, but Zig serves it now — delete the row, its reason is spent\n",
                .{d.action},
            );
            return error.DeferralAlreadyMigrated;
        }
        // A reason is the entire point of the row.
        try testing.expect(d.reason.len > 0);
    }

    // Non-vacuity: the loop above is satisfied by an empty table.
    try testing.expect(deliberate_deferrals.len >= 13);

    // As of this commit the table happens to cover every unmigrated action,
    // but that is not asserted. Pinning the exact count would make migrating a
    // deferred action a three-edit chore — delete the row, lower the ratchet,
    // fix the count — and would buy nothing the two checks above do not
    // already catch. The table also stays deliberately non-exhaustive:
    // "nobody has reached it yet" is an honest state for a newly-added action,
    // and demanding a reason for one would only invite an invented reason.

    // And the table cannot claim more than remain unmigrated.
    try testing.expect(deliberate_deferrals.len <= max_not_yet_migrated);
}

test "nothing has been dropped on the way from Swift to Zig" {
    // The migration guard. Every action the spec answers is either served by
    // Zig or explicitly still owed, and the number still owed only goes down.
    //
    // Without this, moving an action across is indistinguishable from losing
    // it: both leave a page calling something nothing answers, which is exactly
    // the state iOS was already in.
    var spec = try collectCases(testing.allocator, dispatcherRegion());
    defer spec.deinit();

    var zig = try collectZigActions(testing.allocator);
    defer zig.deinit();

    try testing.expect(zig.count() >= 1);

    var not_yet: usize = 0;
    var it = spec.keyIterator();
    while (it.next()) |name| {
        if (!zig.contains(name.*)) not_yet += 1;
    }

    if (not_yet > max_not_yet_migrated) {
        std.debug.print(
            "{d} spec actions are not served by Zig, but the ratchet allows {d}.\n" ++
                "  An action has left Zig without leaving the spec.\n",
            .{ not_yet, max_not_yet_migrated },
        );
        return error.MigrationWentBackwards;
    }

    // The ratchet is only a ratchet if it is tightened. A phase that migrates
    // actions without lowering the constant leaves the guard slack, so say so.
    if (not_yet < max_not_yet_migrated) {
        std.debug.print(
            "note: {d} spec actions remain unmigrated; max_not_yet_migrated is {d} and can be lowered.\n",
            .{ not_yet, max_not_yet_migrated },
        );
    }
}

test "every action Zig declares is one the spec actually has" {
    // The other direction. A Zig action the spec does not list is either a
    // typo — `getDeviceinfo` for `getDeviceInfo`, which a page would never
    // reach — or a surface invented on the Zig side that no page knows to call.
    var spec = try collectCases(testing.allocator, dispatcherRegion());
    defer spec.deinit();

    var zig = try collectZigActions(testing.allocator);
    defer zig.deinit();

    var it = zig.keyIterator();
    while (it.next()) |name| {
        if (!spec.contains(name.*)) {
            std.debug.print(
                "bridge_mobile.zig declares '{s}', which the Swift spec does not handle.\n" ++
                    "  Either it is misspelled, or it is a surface no page can reach.\n",
                .{name.*},
            );
            return error.ZigServesAnActionTheSpecDoesNotHave;
        }
    }
}

// ---------------------------------------------------------------------------
// The capability gate
//
// Every action in the spec's dispatcher is guarded by a `config.enable*` flag,
// and until `src/ios_config.zig` existed Zig could not read one — so 32 actions
// it already served were served unconditionally, whatever the app had been
// configured to allow. The table in `gateFor` closes that, and the four tests
// below are what stop it from being a hand-written list that drifts.
//
// The scans are textual, which is the same shape as the action scan above and
// carries the same hazard: a needle that stops matching turns a real check into
// a vacuous one. Each has an explicit floor for that reason.
// ---------------------------------------------------------------------------

const zig_config_source = @embedFile("src/ios_config.zig");

/// `case "action":` -> the `config.X` flag guarding it, for the whole
/// dispatcher.
///
/// A case block runs to the next `case "` at any indent, so the flag found is
/// the one inside *this* case rather than the next one's. Reading a fixed
/// number of following lines instead would attribute `stopListening`, which is
/// ungated, to the `enableHaptics` of the `haptic` case below it.
fn collectSpecGates(allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer map.deinit();

    const region = dispatcherRegion();
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, region, search, "case \"")) |at| {
        const name_start = at + "case \"".len;
        const name_end = std.mem.indexOfScalarPos(u8, region, name_start, '"') orelse break;
        const action = region[name_start..name_end];
        search = name_end;

        const block_end = if (std.mem.indexOfPos(u8, region, name_end, "case \"")) |next|
            next
        else
            region.len;
        const block = region[name_end..block_end];

        const needle = "if config.";
        if (std.mem.indexOf(u8, block, needle)) |flag_at| {
            const flag_start = flag_at + needle.len;
            var flag_end = flag_start;
            while (flag_end < block.len and (std.ascii.isAlphanumeric(block[flag_end]) or
                block[flag_end] == '_')) : (flag_end += 1)
            {}
            try map.put(action, block[flag_start..flag_end]);
        }
    }
    return map;
}

/// `.{ "action", .feature },` from `gateFor`'s table, paired with the JSON key
/// that `feature` maps to in `jsonKey`.
fn collectZigGates(allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer map.deinit();

    const table_start = std.mem.indexOf(u8, zig_config_source, "const table = comptime") orelse
        return error.GateTableNotFound;
    const table_end = std.mem.indexOfPos(u8, zig_config_source, table_start, "\n    };") orelse
        return error.GateTableNotFound;
    const table = zig_config_source[table_start..table_end];

    var it = std.mem.splitScalar(u8, table, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, ".{ \"")) continue;

        const name_start = std.mem.indexOfScalar(u8, trimmed, '"').? + 1;
        const name_end = std.mem.indexOfScalarPos(u8, trimmed, name_start, '"').?;
        const action = trimmed[name_start..name_end];

        const dot = std.mem.indexOfScalarPos(u8, trimmed, name_end, '.') orelse continue;
        var member_end = dot + 1;
        while (member_end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[member_end]) or
            trimmed[member_end] == '_')) : (member_end += 1)
        {}
        const member = trimmed[dot + 1 .. member_end];

        try map.put(action, try jsonKeyOf(member));
    }
    return map;
}

/// The `.member => "enableX",` arm of `jsonKey`, read from the source.
fn jsonKeyOf(member: []const u8) ![]const u8 {
    const body_start = std.mem.indexOf(u8, zig_config_source, "pub fn jsonKey(") orelse
        return error.JsonKeyFnNotFound;
    const body = zig_config_source[body_start..];

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, ".")) continue;
        const arrow = std.mem.indexOf(u8, trimmed, " => \"") orelse continue;
        if (!std.mem.eql(u8, trimmed[1..arrow], member)) continue;

        const key_start = arrow + " => \"".len;
        const key_end = std.mem.indexOfScalarPos(u8, trimmed, key_start, '"') orelse continue;
        return trimmed[key_start..key_end];
    }
    return error.MemberHasNoJsonKey;
}

/// Every `var name: Bool` in `struct CraftConfig`.
fn collectSpecConfigBools(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    const at = std.mem.indexOf(u8, swift_spec, "struct CraftConfig: Codable {") orelse
        return error.CraftConfigNotFound;
    const rest = swift_spec[at..];
    const end = std.mem.indexOf(u8, rest, "\n}") orelse rest.len;

    var it = std.mem.splitScalar(u8, rest[0..end], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "var ")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const type_part = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r");
        if (!std.mem.startsWith(u8, type_part, "Bool")) continue;
        try set.put(std.mem.trim(u8, trimmed["var ".len..colon], " \t\r"), {});
    }
    return set;
}

test "the gate scans find something, so the subset checks below mean something" {
    // The vacuity floor. Every assertion after this is "for each X, ..."; a
    // scan that matched nothing would satisfy all of them silently. The numbers
    // are floors rather than equalities so migrating an action does not have to
    // edit this test — but a rename that breaks a needle drops the count to
    // zero and fails here.
    var spec_gates = try collectSpecGates(testing.allocator);
    defer spec_gates.deinit();
    var zig_gates = try collectZigGates(testing.allocator);
    defer zig_gates.deinit();
    var config_bools = try collectSpecConfigBools(testing.allocator);
    defer config_bools.deinit();

    try testing.expect(spec_gates.count() >= 60);
    try testing.expect(zig_gates.count() >= 30);
    try testing.expect(config_bools.count() >= 35);

    // And the scans read what they claim to read, rather than something that
    // merely has the right shape.
    try testing.expectEqualStrings("enableClipboard", spec_gates.get("clipboardRead").?);
    try testing.expectEqualStrings("enableClipboard", zig_gates.get("clipboardRead").?);
    try testing.expect(config_bools.contains("enableClipboard"));
}

test "every gated action Zig serves consults the flag the spec gates it on" {
    // The check the 32 table entries exist for. Before `ios_config.zig`, every
    // one of these was served whatever the app's configuration said; a new
    // migration that forgets its gate lands back in that state, and this is
    // what refuses it.
    var spec_gates = try collectSpecGates(testing.allocator);
    defer spec_gates.deinit();
    var zig_gates = try collectZigGates(testing.allocator);
    defer zig_gates.deinit();
    var zig_actions = try collectZigActions(testing.allocator);
    defer zig_actions.deinit();

    var missing: usize = 0;
    var disagreeing: usize = 0;

    var it = zig_actions.keyIterator();
    while (it.next()) |action| {
        const spec_flag = spec_gates.get(action.*) orelse continue;
        const zig_flag = zig_gates.get(action.*) orelse {
            std.debug.print(
                "'{s}' is gated on config.{s} in the spec, and Zig serves it ungated.\n" ++
                    "  Add it to ios_config.gateFor's table.\n",
                .{ action.*, spec_flag },
            );
            missing += 1;
            continue;
        };
        if (!std.mem.eql(u8, spec_flag, zig_flag)) {
            std.debug.print(
                "'{s}' is gated on config.{s} in the spec but on {s} in Zig.\n",
                .{ action.*, spec_flag, zig_flag },
            );
            disagreeing += 1;
        }
    }

    try testing.expectEqual(@as(usize, 0), missing);
    try testing.expectEqual(@as(usize, 0), disagreeing);
}

test "the gate table has no entry for an action Zig does not serve" {
    // A stale entry is not harmless. `route` consults `gateFor` before the
    // module chain, so an entry for an action that has moved back to the shim
    // would have Zig refuse it on the shim's behalf — deciding, from Zig's
    // parse of the config, a question the arm that owns the action is about to
    // decide from its own.
    var zig_gates = try collectZigGates(testing.allocator);
    defer zig_gates.deinit();
    var zig_actions = try collectZigActions(testing.allocator);
    defer zig_actions.deinit();
    var spec_gates = try collectSpecGates(testing.allocator);
    defer spec_gates.deinit();

    var it = zig_gates.keyIterator();
    while (it.next()) |action| {
        if (!zig_actions.contains(action.*)) {
            std.debug.print("gateFor has '{s}', which no mobile module serves.\n", .{action.*});
            return error.StaleGateEntry;
        }
        if (!spec_gates.contains(action.*)) {
            std.debug.print(
                "gateFor gates '{s}', which the spec does not gate — Zig would refuse " ++
                    "a call the Swift app allows.\n",
                .{action.*},
            );
            return error.GateNotInSpec;
        }
    }
}

/// The `.reason` text of every `.status = .unavailable` entry, by action.
///
/// The reason is what a reader trusts, so it is what has to be checked. A
/// declaration can be resolved two ways here: `.reason = "..."` inline, and
/// `.reason = some_const` naming a constant elsewhere in the file — both are
/// in use, and a scan that handled only the first would silently skip the
/// second rather than fail.
fn collectUnavailableReasons(allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer map.deinit();

    for (zig_sources) |source| {
        // Bounded to the manifest array, not the whole file: prose quotes
        // `.status = .unavailable` — `bridge_mobile_haptics.zig`'s header does,
        // describing the declaration it removed — and a scan that read comments
        // would attribute that sentence to whichever entry preceded it.
        const table_start = std.mem.indexOf(u8, source, "pub const capability_actions = [_]capabilities.ActionDecl{") orelse
            continue;
        const table_end = std.mem.indexOfPos(u8, source, table_start, "\n};") orelse continue;
        const table = source[table_start..table_end];

        var search: usize = 0;
        while (std.mem.indexOfPos(u8, table, search, ".status = .unavailable")) |at| {
            search = at + 1;

            // The entry names its action as `A.some_const`; resolve it back
            // through the `A` block to the string the spec spells.
            const name_at = std.mem.lastIndexOf(u8, table[0..at], ".name = A.") orelse continue;
            const const_start = name_at + ".name = A.".len;
            var const_end = const_start;
            while (const_end < table.len and (std.ascii.isAlphanumeric(table[const_end]) or
                table[const_end] == '_')) : (const_end += 1)
            {}

            var needle_buf: [96]u8 = undefined;
            const member = table[const_start..const_end];
            if (member.len + 16 > needle_buf.len) continue;
            const decl = try std.fmt.bufPrint(&needle_buf, "const {s} = \"", .{member});
            const decl_at = std.mem.indexOf(u8, source, decl) orelse continue;
            const value_start = decl_at + decl.len;
            const value_end = std.mem.indexOfScalarPos(u8, source, value_start, '"') orelse continue;
            const action = source[value_start..value_end];

            // The reason, inline or by name.
            const reason_at = std.mem.indexOfPos(u8, table, at, ".reason = ") orelse continue;
            const reason_start = reason_at + ".reason = ".len;
            if (table[reason_start] == '"') {
                const reason_end = std.mem.indexOfScalarPos(u8, table, reason_start + 1, '"') orelse continue;
                try map.put(action, table[reason_start + 1 .. reason_end]);
            } else {
                var ident_end = reason_start;
                while (ident_end < table.len and (std.ascii.isAlphanumeric(table[ident_end]) or
                    table[ident_end] == '_')) : (ident_end += 1)
                {}
                var const_buf: [96]u8 = undefined;
                const ident = table[reason_start..ident_end];
                if (ident.len + 10 > const_buf.len) continue;
                const const_decl = try std.fmt.bufPrint(&const_buf, "const {s} =", .{ident});
                const body_at = std.mem.indexOf(u8, source, const_decl) orelse continue;
                const body_end = std.mem.indexOfScalarPos(u8, source, body_at, ';') orelse continue;
                // The whole initialiser, `++` concatenation included.
                try map.put(action, source[body_at..body_end]);
            }
        }
    }
    return map;
}

test "no refusal blames a config flag Zig demonstrably reads" {
    // The rot this exists to catch, in the exact shape it took. `haptic` was
    // declared `.status = .unavailable` because `config.enableHaptics` "is not
    // visible to Zig"; `gateFor`'s table said Zig reads that same flag and
    // refuses the action when it is off. Both were written honestly, months
    // apart, and nothing put them side by side — so the refusal outlived its
    // reason and a working implementation sat unused two hundred lines below it.
    //
    // Deliberately narrower than "gated and unavailable", which is not a
    // contradiction: `lockOrientation` is both, and its reason is about a root
    // view controller rather than about reading a flag. What cannot stand is a
    // refusal *naming* a flag the gate table proves Zig reads.
    var gates = try collectZigGates(testing.allocator);
    defer gates.deinit();

    var reasons = try collectUnavailableReasons(testing.allocator);
    defer reasons.deinit();

    // Non-vacuity: the scan reads each manifest through two indirections — the
    // `A.` constant and its declaration — and either could stop matching.
    try testing.expect(reasons.count() >= 3);

    var it = reasons.iterator();
    while (it.next()) |entry| {
        const flag = gates.get(entry.key_ptr.*) orelse continue;
        if (std.mem.indexOf(u8, entry.value_ptr.*, flag) != null) {
            std.debug.print(
                "`{s}` is declared unavailable and its reason names `{s}`, which `gateFor` " ++
                    "maps it to.\n" ++
                    "  The manifest says Zig cannot read that flag; the gate table says it does " ++
                    "and refuses the action when it is off.\n" ++
                    "  One of them is out of date.\n",
                .{ entry.key_ptr.*, flag },
            );
            return error.RefusalBlamesAFlagZigReads;
        }
    }
}

test "every flag Zig can read is a flag the spec's config actually has" {
    // A misspelled key is not a one-flag bug. A key that is not in the file
    // reads as missing, and one missing key makes the whole decode throw, so
    // `enableMlKit` for `enableMLKit` would disable all 35 capabilities at once
    // — in an app whose config is perfectly valid.
    var config_bools = try collectSpecConfigBools(testing.allocator);
    defer config_bools.deinit();

    const marker = "pub fn jsonKey(";
    const body_start = std.mem.indexOf(u8, zig_config_source, marker).?;
    const body = zig_config_source[body_start..];
    const body_end = std.mem.indexOf(u8, body, "\n    }").?;

    var checked: usize = 0;
    var it = std.mem.splitScalar(u8, body[0..body_end], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, ".")) continue;
        if (std.mem.indexOf(u8, trimmed, " => \"") == null) continue;

        const key_start = std.mem.indexOfScalar(u8, trimmed, '"').? + 1;
        const key_end = std.mem.indexOfScalarPos(u8, trimmed, key_start, '"').?;
        const key = trimmed[key_start..key_end];

        if (!config_bools.contains(key)) {
            std.debug.print(
                "ios_config spells '{s}', which is not a Bool in the spec's CraftConfig.\n" ++
                    "  A key that is not in the file disables every capability, not this one.\n",
                .{key},
            );
            return error.UnknownConfigKey;
        }
        checked += 1;
    }
    try testing.expect(checked >= 35);
}

/// Every key `ios_config.zig` will decode: the three literal lists plus every
/// `Feature`'s json key.
///
/// Built from the declarations rather than by searching the whole file, so a
/// key that appears only in a doc comment does not count as mirrored. That
/// distinction is the whole value of this scan: the header prose names most of
/// these keys, so a whole-file search would pass for a key nothing decodes.
fn collectZigRequiredKeys(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    inline for (.{ "const string_keys", "const extra_bool_keys", "const array_of_string_keys" }) |decl| {
        const at = std.mem.indexOf(u8, zig_config_source, decl) orelse return error.KeyListNotFound;
        const line_end = std.mem.indexOfScalarPos(u8, zig_config_source, at, '\n').?;
        const line = zig_config_source[at..line_end];

        var search: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, search, '"')) |open| {
            const close = std.mem.indexOfScalarPos(u8, line, open + 1, '"') orelse break;
            try set.put(line[open + 1 .. close], {});
            search = close + 1;
        }
    }

    const body_start = std.mem.indexOf(u8, zig_config_source, "pub fn jsonKey(") orelse
        return error.JsonKeyFnNotFound;
    const body = zig_config_source[body_start..];
    const body_end = std.mem.indexOf(u8, body, "\n    }").?;
    var it = std.mem.splitScalar(u8, body[0..body_end], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, ".")) continue;
        if (std.mem.indexOf(u8, trimmed, " => \"") == null) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '"').?;
        const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, '"').?;
        try set.put(trimmed[open + 1 .. close], {});
    }
    return set;
}

test "Zig requires exactly the keys the spec's decoder requires" {
    // The faithfulness the all-or-nothing rule depends on. Swift's synthesized
    // `init(from:)` calls `decode` for every non-optional stored property and
    // throws when one is missing, so the two runtimes agree about a given file
    // only while they require the same set. When `CraftConfig` grows a key this
    // fails until `ios_config.zig` grows it too — otherwise Swift refuses a
    // config Zig accepts, in one process, from one file.
    var zig_keys = try collectZigRequiredKeys(testing.allocator);
    defer zig_keys.deinit();

    const at = std.mem.indexOf(u8, swift_spec, "struct CraftConfig: Codable {").?;
    const rest = swift_spec[at..];
    const end = std.mem.indexOf(u8, rest, "\n}").?;

    var required: usize = 0;
    var optional_seen: usize = 0;
    var it = std.mem.splitScalar(u8, rest[0..end], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "var ")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed["var ".len..colon], " \t\r");

        const after_colon = trimmed[colon + 1 ..];
        const type_end = std.mem.indexOf(u8, after_colon, " =") orelse after_colon.len;
        const type_name = std.mem.trim(u8, after_colon[0..type_end], " \t\r");

        // An optional is decoded with `decodeIfPresent`, so its absence is not
        // a throw and Zig must NOT require it.
        if (std.mem.endsWith(u8, type_name, "?")) {
            optional_seen += 1;
            if (zig_keys.contains(name)) {
                std.debug.print(
                    "ios_config requires '{s}', which is optional in the spec — Zig would " ++
                        "refuse a config Swift accepts.\n",
                    .{name},
                );
                return error.OptionalKeyTreatedAsRequired;
            }
            continue;
        }

        required += 1;
        if (!zig_keys.contains(name)) {
            std.debug.print(
                "the spec's CraftConfig requires '{s}' and ios_config.zig does not decode it.\n" ++
                    "  Swift throws on the missing key and falls back to every flag false; " ++
                    "Zig would accept the same file.\n",
                .{name},
            );
            return error.RequiredKeyNotMirrored;
        }
    }

    // Both directions: a key Zig requires that the spec does not have would
    // make Zig refuse every config the generator writes.
    try testing.expectEqual(required, zig_keys.count());
    try testing.expect(required >= 40);
    try testing.expect(optional_seen >= 1);
}

test "getDeviceInfo answers every field the spec answers" {
    // The regression that made this test necessary. Zig's `getDeviceInfo` is
    // `.live`, so the Swift-hosted seam prefers it over the spec's arm — and
    // it answered four of the spec's fourteen fields. A page reading
    // `screenWidth` or `locale` got `undefined` from an action that reported
    // success, which is the exact failure `.unavailable` exists to prevent and
    // could not catch, because the action does work; it just works less.
    //
    // Keys are read out of the spec rather than listed here, so a field added
    // to `CraftApp.swift` fails this test until Zig answers it too.
    // Anchored to the function, not to `let info:` — the spec has more than
    // one dictionary spelled that way (`getMemoryUsage` has another), and the
    // first match is not this one.
    const fn_start = std.mem.indexOf(u8, swift_spec, "private func getDeviceInfo(callbackId:") orelse
        return error.SpecShapeChanged;
    const body = swift_spec[fn_start..];
    const start = std.mem.indexOf(u8, body, "let info: [String: Any] = [") orelse
        return error.SpecShapeChanged;
    const after = body[start..];
    const end = std.mem.indexOf(u8, after, "\n            ]") orelse return error.SpecShapeChanged;
    const block = after[0..end];

    // Narrowed to the implementation for the reason `implementationOf`
    // documents: `bridge_mobile.zig`'s own tests quote these keys back.
    const zig_src = implementationOf(@embedFile("src/bridge_mobile.zig"));

    var it = std.mem.splitScalar(u8, block, '\n');
    var checked: usize = 0;
    while (it.next()) |line| {
        const q1 = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const rest = line[q1 + 1 ..];
        const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const key = rest[0..q2];
        if (key.len == 0) continue;

        // Zig builds the reply as a format string, so the key appears in the
        // source as the escaped `\"key\":` it will emit.
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "\\\"{s}\\\":", .{key});
        if (std.mem.indexOf(u8, zig_src, needle) == null) {
            std.debug.print("getDeviceInfo: the spec answers `{s}` and Zig does not\n", .{key});
            return error.FieldMissingFromZig;
        }
        checked += 1;
    }

    // A shape change that silently matched nothing would otherwise pass.
    try testing.expectEqual(@as(usize, 14), checked);
}

// ---------------------------------------------------------------------------
// The event channel
//
// Everything above this line is about the *call* channel: the page asks, native
// answers. The other half of the contract runs the other way — native talks
// first, and the page hears it as a `CustomEvent` on `window`. Nothing checked
// that half, and it carries the same two failure modes the action scans exist
// to catch, in a form that is quieter still:
//
//   * A name Zig emits that nothing subscribes to. `craftLocationUpate` for
//     `craftLocationUpdate` compiles, dispatches, and reaches no one. There is
//     no promise to hang and no error to log — the stream simply never starts,
//     which is indistinguishable from a device that has nothing to report.
//     `ios_events.zig`'s own header records this hazard and calls the names
//     "copied from a `sendToWeb` call"; copied, and then never re-checked.
//
//   * A name the page subscribes to that nothing dispatches. This is exactly
//     the `ota*` bug — a surface that read as implemented and was not. When
//     the five unhandled `ota*` methods were fixed to reject through
//     `_unavailable`, the two
//     *subscription* methods beside them were left as they were, because the
//     scan that found them only knew about actions. The event scan caught and
//     removed those dead listeners in #127.
//
// Both scans are textual and carry the usual hazard, so both have floors.
// ---------------------------------------------------------------------------

const zig_events_source = @embedFile("src/ios_events.zig");

/// Extract single-or-double-quoted event names following `needle`, keeping
/// only the `craft`-prefixed identifiers.
///
/// The filter is doing real work rather than tidying. `sendToWeb` is also
/// called through an interpolation — `CustomEvent('\(event)'` in the sink
/// itself — and `addEventListener` is used for `loadend` and
/// `visibilitychange`, neither of which is a bridge event. Restricting to
/// `craft`-prefixed identifiers drops all three, and the prefix is not an
/// assumption: the test below asserts every dispatched name has it.
fn collectQuotedEvents(
    allocator: std.mem.Allocator,
    needle: []const u8,
    quote: u8,
) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    var search: usize = 0;
    while (std.mem.indexOfPos(u8, swift_spec, search, needle)) |at| {
        const start = at + needle.len;
        const end = std.mem.indexOfScalarPos(u8, swift_spec, start, quote) orelse break;
        search = end;

        const name = swift_spec[start..end];
        if (!std.mem.startsWith(u8, name, "craft")) continue;
        var ok = true;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c)) ok = false;
        }
        if (ok) try set.put(name, {});
    }
    return set;
}

/// Every event the spec dispatches: `sendToWeb("craftX", ...)` from native,
/// plus the `CustomEvent('craftX'` literals — one in Swift's deep-link path
/// and two inside the injected JavaScript, which dispatches `craftError` and
/// `craftReady` itself.
fn collectSpecDispatchedEvents(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = try collectQuotedEvents(allocator, "sendToWeb(\"", '"');
    errdefer set.deinit();

    var literal = try collectQuotedEvents(allocator, "CustomEvent('", '\'');
    defer literal.deinit();

    var it = literal.keyIterator();
    while (it.next()) |name| try set.put(name.*, {});
    return set;
}

/// Every event the injected JavaScript subscribes to on the page's behalf.
fn collectSpecSubscribedEvents(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    return collectQuotedEvents(allocator, "addEventListener('", '\'');
}

/// The `.member => "craftX",` arms of `ios_events.Event.eventName`.
fn collectZigEventNames(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    const start = std.mem.indexOf(u8, zig_events_source, "pub fn eventName(") orelse
        return error.EventNameFnNotFound;
    const body = zig_events_source[start..];
    // `eventName` is a method on the enum, so it closes at four-space indent.
    const end = std.mem.indexOf(u8, body, "\n    }") orelse return error.EventNameFnNotFound;

    var it = std.mem.splitScalar(u8, body[0..end], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, ".")) continue;
        const arrow = std.mem.indexOf(u8, trimmed, " => \"") orelse continue;
        const name_start = arrow + " => \"".len;
        const name_end = std.mem.indexOfScalarPos(u8, trimmed, name_start, '"') orelse continue;
        try set.put(trimmed[name_start..name_end], {});
    }
    return set;
}

test "the event scans find both halves of the channel" {
    // Non-vacuity. Every assertion below is a membership check, and a needle
    // that stopped matching would satisfy all of them at once.
    var dispatched = try collectSpecDispatchedEvents(testing.allocator);
    defer dispatched.deinit();
    try testing.expect(dispatched.count() >= 17);

    var subscribed = try collectSpecSubscribedEvents(testing.allocator);
    defer subscribed.deinit();
    try testing.expect(subscribed.count() >= 8);

    var zig = try collectZigEventNames(testing.allocator);
    defer zig.deinit();
    try testing.expect(zig.count() >= 13);

    // The prefix the two filters rely on, checked rather than assumed.
    var it = dispatched.keyIterator();
    while (it.next()) |name| try testing.expect(std.mem.startsWith(u8, name.*, "craft"));
}

test "every event Zig emits is one the spec dispatches" {
    // The typo guard, and the direction that matters most: `ios_events.Event`
    // is a fixed vocabulary transcribed by hand from the spec's `sendToWeb`
    // call sites, and a single wrong character produces a `CustomEvent` with
    // no subscriber. Nothing fails, nothing logs; the page just never hears
    // from the device.
    //
    // The spec is never edited to remove an arm a Zig module has taken over —
    // `CraftApp.swift` stays the specification and the shim — so Zig's
    // vocabulary being a subset of the spec's is a property that holds for as
    // long as this migration runs.
    var dispatched = try collectSpecDispatchedEvents(testing.allocator);
    defer dispatched.deinit();

    var zig = try collectZigEventNames(testing.allocator);
    defer zig.deinit();

    var it = zig.keyIterator();
    while (it.next()) |name| {
        if (!dispatched.contains(name.*)) {
            std.debug.print(
                "ios_events.Event spells '{s}', which the spec never dispatches.\n" ++
                    "  A page written against the Swift app is listening for a different name.\n",
                .{name.*},
            );
            return error.ZigEmitsAnEventTheSpecDoesNotHave;
        }
    }
}

test "every event the page subscribes to is one something dispatches" {
    // The `ota*` check, on the other channel. A subscription with no emitter
    // is quieter than a promise with no handler — there is nothing to await,
    // so the page reports no error and simply behaves as if the device were
    // idle — which makes it likelier to ship and likelier to survive.
    //
    // Zig's emitters are not consulted here on purpose: the test above pins
    // `ios_events.Event` as a subset of what the spec dispatches, so a union
    // with it could not admit a name this set lacks. Adding one anyway would
    // read as though Zig could rescue a dead subscription, and it cannot.
    var dispatched = try collectSpecDispatchedEvents(testing.allocator);
    defer dispatched.deinit();

    var subscribed = try collectSpecSubscribedEvents(testing.allocator);
    defer subscribed.deinit();

    var it = subscribed.keyIterator();
    while (it.next()) |name| {
        if (dispatched.contains(name.*)) continue;
        std.debug.print(
            "the injected JS subscribes to '{s}', which nothing dispatches.\n" ++
                "  The callback a page registers for it can never be called.\n",
            .{name.*},
        );
        return error.PageSubscribesToAnEventNothingEmits;
    }
}

// ---------------------------------------------------------------------------
// Reply shape
//
// `getDeviceInfo answers every field the spec answers` exists because Zig's
// `getDeviceInfo` once answered four of the spec's fourteen fields. The action
// was `.live`, so the seam preferred it; it reported success; a page reading
// `screenWidth` or `locale` got `undefined`. Nothing else in the repo could
// catch that, because from every other angle the action works — it just works
// less.
//
// That test was written for one action, by hand, and the same hazard applies
// to every action whose reply carries more than one field. This generalises
// it: the spec's reply dictionaries are read out of `CraftApp.swift`, matched
// to the action whose case arm produces them, and every key is required of the
// Zig module that declares that action.
//
// Attribution is the whole difficulty, and it is worth doing properly rather
// than checking keys against the union of all Zig sources. Half these keys are
// words like `value`, `key`, `id` and `success` that appear in a dozen
// modules; a union check would pass for every one of them no matter which
// module dropped which field, which is the shape of a test that is green
// because it is vacuous.
// ---------------------------------------------------------------------------

/// The Swift function enclosing `offset`, by name.
///
/// Anchored on ` func <name>(` so a `private func` matches at the `func` and a
/// word merely ending in "func" does not. The last one before the offset is
/// the enclosing one — Swift's functions here are flat, not nested.
fn enclosingFunc(offset: usize) ?[]const u8 {
    var best: ?[]const u8 = null;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, swift_spec, search, "func ")) |at| {
        if (at >= offset) break;
        search = at + "func ".len;
        if (at == 0 or (swift_spec[at - 1] != ' ' and swift_spec[at - 1] != '\n')) continue;

        const paren = std.mem.indexOfScalarPos(u8, swift_spec, search, '(') orelse continue;
        const name = swift_spec[search..paren];
        if (name.len == 0) continue;
        var ok = true;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') ok = false;
        }
        if (ok) best = name;
    }
    return best;
}

/// The bracket-balanced literal beginning at `start`, which must be a `[`.
///
/// A string value containing a bracket would run this long. That fails in the
/// safe direction — a block that swallows the next statement contributes keys
/// Zig was never asked for, and the test says so loudly — rather than quietly
/// checking nothing.
fn balancedBracket(start: usize) ?[]const u8 {
    var depth: i32 = 0;
    var i = start;
    while (i < swift_spec.len) : (i += 1) {
        switch (swift_spec[i]) {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return swift_spec[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// The next `"key":` in `block` at or after `from`, and where to resume.
fn nextDictKey(block: []const u8, from: usize) ?struct { key: []const u8, next: usize } {
    var search = from;
    while (std.mem.indexOfScalarPos(u8, block, search, '"')) |open| {
        const close = std.mem.indexOfScalarPos(u8, block, open + 1, '"') orelse return null;
        search = close + 1;

        var after = close + 1;
        while (after < block.len and (block[after] == ' ' or block[after] == '\n')) : (after += 1) {}
        if (after < block.len and block[after] == ':') {
            return .{ .key = block[open + 1 .. close], .next = search };
        }
    }
    return null;
}

/// The part of a module that is its implementation, not its tests.
///
/// The needle these checks use is the emitted JSON key — `\\"residentSize\\":` —
/// and a module's own test literals are full of exactly that. Searching the
/// whole file lets a module keep passing on the strength of a test asserting a
/// field the implementation has stopped emitting, which is the one arrangement
/// worse than no check: the assertion and the bug live in the same file and
/// agree with each other.
///
/// Verified against the mutation it exists for — deleting `residentSize` from
/// `getMemoryUsage`'s format string passes a whole-file search and fails this
/// one.
fn implementationOf(source: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, source, "\ntest \"") orelse return source;
    return source[0..at];
}

/// Does `source` declare `action` in its `A` block?
fn declaresAction(source: []const u8, action: []const u8) bool {
    const block_start = std.mem.indexOf(u8, source, "pub const A = struct {") orelse return false;
    var it = std.mem.splitScalar(u8, source[block_start..], '\n');
    _ = it.next();
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "};")) break;
        const open = std.mem.indexOfScalar(u8, trimmed, '"') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, '"') orelse continue;
        if (std.mem.eql(u8, trimmed[open + 1 .. close], action)) return true;
    }
    return false;
}

/// The module that serves `action`, or null for one no module declares.
fn zigSourceFor(action: []const u8) ?[]const u8 {
    for (zig_sources) |source| {
        if (declaresAction(source, action)) return source;
    }
    return null;
}

/// The action whose dispatcher case arm calls `func_name`, or reaches `offset`.
///
/// Two shapes to cover: most replies are built inside a private helper the
/// case arm calls, and a few are built inline in the arm itself. The inline
/// ones have `userContentController` as their enclosing function, which no
/// case calls, so they are attributed by position instead.
fn actionProducing(func_name: []const u8, offset: usize) ?[]const u8 {
    const region = dispatcherRegion();
    const region_start = @intFromPtr(region.ptr) - @intFromPtr(swift_spec.ptr);

    var found: ?[]const u8 = null;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, region, search, "case \"")) |at| {
        const name_start = at + "case \"".len;
        const name_end = std.mem.indexOfScalarPos(u8, region, name_start, '"') orelse break;
        const action = region[name_start..name_end];
        search = name_end;

        const block_end = std.mem.indexOfPos(u8, region, name_end, "case \"") orelse region.len;

        // Inline: the dictionary itself sits in this arm.
        if (offset >= region_start + name_end and offset < region_start + block_end) return action;

        // Delegated: the arm calls the helper that builds the dictionary.
        var call_buf: [96]u8 = undefined;
        if (func_name.len + 1 > call_buf.len) continue;
        const call = std.fmt.bufPrint(&call_buf, "{s}(", .{func_name}) catch continue;
        if (std.mem.indexOf(u8, region[name_end..block_end], call) != null) {
            if (found == null) found = action;
        }
    }
    return found;
}

const ReplyDivergence = struct {
    action: []const u8,
    key: []const u8,
    reason: []const u8,
};

/// Keys the spec's reply carries that Zig deliberately does not answer.
///
/// A reply that drops a field is a bug by default — that is what the check
/// below is for — so a row here has to argue that Zig is *right* and the spec
/// is wrong, not merely that they differ.
const deliberate_reply_divergences = [_]ReplyDivergence{
    // Swift's failure arm resolves with `["usedMB": 0, "error": ...]`, which
    // settles the page's promise carrying a fabricated zero: a caller cannot
    // tell "this app uses no memory" from "the reading could not be taken".
    // Zig returns `NativeCallFailed`, so there is no success reply for an
    // `error` key to live in. Documented at the `task_info` call site.
    .{ .action = "getMemoryUsage", .key = "error", .reason = "Swift resolves the failure with a fabricated usedMB: 0; Zig rejects, so there is no reply to carry it" },

    // Declared `.status = .unavailable`: Zig names the action so the seam can
    // refuse it explicitly, and the Swift shim answers. There is no Zig reply
    // to compare, and the shim's own `isConnected` is hardcoded `true` — which
    // is why Zig refuses rather than reproducing it.
    .{ .action = "getNetworkStatus", .key = "isConnected", .reason = "Zig declares it .status = .unavailable; the shim answers, and answers it wrong" },
    .{ .action = "getNetworkStatus", .key = "type", .reason = "Zig declares it .status = .unavailable; the shim answers, and answers it wrong" },
};

fn divergenceRecorded(action: []const u8, key: []const u8) bool {
    for (deliberate_reply_divergences) |d| {
        if (std.mem.eql(u8, d.action, action) and std.mem.eql(u8, d.key, key)) return true;
    }
    return false;
}

/// Walk every multi-key reply dictionary in the spec, calling `visit` with the
/// action it belongs to and each of its keys.
///
/// Shared by the check and its own anti-rot test so the two cannot disagree
/// about what the scan found.
fn forEachReplyKey(
    context: anytype,
    comptime visit: fn (@TypeOf(context), action: []const u8, key: []const u8) anyerror!void,
) !void {
    const anchors = [_][]const u8{
        "resolveCallback(callbackId, result: [",
        "resolveCallbackJSON(callbackId, json: [",
        ": [String: Any] = [",
    };

    for (anchors) |anchor| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, swift_spec, search, anchor)) |at| {
            const bracket = at + anchor.len - 1;
            search = at + anchor.len;

            const block = balancedBracket(bracket) orelse continue;

            // One key is a single-field reply — `["reachable": x]` — which the
            // action's own module test already pins and which cannot lose a
            // field without losing the whole reply.
            var count: usize = 0;
            var at_key: usize = 0;
            while (nextDictKey(block, at_key)) |k| : (at_key = k.next) count += 1;
            if (count < 2) continue;

            const func = enclosingFunc(at) orelse continue;
            const action = actionProducing(func, at) orelse continue;

            at_key = 0;
            while (nextDictKey(block, at_key)) |k| : (at_key = k.next) {
                try visit(context, action, k.key);
            }
        }
    }
}

const ReplyCounter = struct {
    checked: usize = 0,
    actions_seen: usize = 0,
};

/// Does `source` emit `key` as a JSON key?
///
/// Two spellings, because modules legitimately use both. Most build the reply
/// as a format string and the key appears as the escaped `\\"key\\":` it will
/// emit. `bridge_mobile_bgtasks.zig` instead names it — `const scheduled_key =
/// "scheduled";` — and passes it to a shared `taskReply` helper, so the
/// literal never appears beside a colon. Demanding the first spelling would
/// fail a module that is correct, which is the failure that gets a check
/// deleted rather than fixed.
fn emitsJsonKey(source: []const u8, key: []const u8) !bool {
    var buf: [96]u8 = undefined;
    if (key.len + 8 > buf.len) return true;

    const escaped = try std.fmt.bufPrint(&buf, "\\\"{s}\\\":", .{key});
    if (std.mem.indexOf(u8, source, escaped) != null) return true;

    var buf2: [96]u8 = undefined;
    const named = try std.fmt.bufPrint(&buf2, "= \"{s}\";", .{key});
    return std.mem.indexOf(u8, source, named) != null;
}

fn checkReplyKey(counter: *ReplyCounter, action: []const u8, key: []const u8) !void {
    if (divergenceRecorded(action, key)) return;

    // An action no Zig module declares is still owed, not broken — the ratchet
    // above is what tracks those.
    const source = implementationOf(zigSourceFor(action) orelse return);

    if (!try emitsJsonKey(source, key)) {
        std.debug.print(
            "{s}: the spec's reply carries `{s}` and the Zig module serving it never emits that key.\n" ++
                "  The action reports success and the page reads undefined.\n",
            .{ action, key },
        );
        return error.ReplyDropsAFieldTheSpecAnswers;
    }
    counter.checked += 1;
}

test "every field the spec's replies carry is one Zig's reply carries" {
    // The generalisation of the `getDeviceInfo` check, which found exactly this
    // and could only ever find it for one action.
    var counter = ReplyCounter{};
    try forEachReplyKey(&counter, checkReplyKey);

    // Non-vacuity, and a real floor rather than a token one: the scan finds
    // twenty-odd multi-key replies today across device info, the keychain,
    // biometric persistence, background tasks, PDF, SQLite, health, Siri and
    // AR. A parsing change that dropped it to a handful would otherwise leave
    // this test green and checking almost nothing.
    //
    // 52 keys reach this check as of this commit, out of the 64 the scan
    // attributes — the gap is actions Zig does not serve yet, whose absence is
    // the ratchet's business rather than this test's. The floor is set below
    // that with room for the spec to lose a field honestly, and well above
    // what any broken sub-parser would leave behind.
    try testing.expect(counter.checked >= 40);
}

fn countReplyKey(counter: *ReplyCounter, action: []const u8, key: []const u8) !void {
    _ = key;
    _ = action;
    counter.checked += 1;
}

test "the reply scan attributes dictionaries to actions, not to nothing" {
    // The scan has three failure modes that all look like success: an anchor
    // that stops matching, a bracket walk that returns null, and an
    // attribution that never resolves. Each would leave the check above
    // iterating an empty set.
    var counter = ReplyCounter{};
    try forEachReplyKey(&counter, countReplyKey);
    try testing.expect(counter.checked >= 50); // 64 today

    // And the attribution has to reach the two shapes it was written for: a
    // reply built in a private helper, and one built inline in the case arm.
    const helper = actionProducing("getDeviceInfo", 0) orelse return error.AttributionLostTheHelperShape;
    try testing.expectEqualStrings("getDeviceInfo", helper);

    const inline_at = std.mem.indexOf(u8, swift_spec, "\"isConnected\": isConnected") orelse
        return error.SpecShapeChanged;
    const inline_action = actionProducing("userContentController", inline_at) orelse
        return error.AttributionLostTheInlineShape;
    try testing.expectEqualStrings("getNetworkStatus", inline_action);
}

const PairProbe = struct {
    action: []const u8,
    key: []const u8,
    found: bool = false,
};

fn probePair(probe: *PairProbe, action: []const u8, key: []const u8) !void {
    if (std.mem.eql(u8, probe.action, action) and std.mem.eql(u8, probe.key, key)) probe.found = true;
}

test "every recorded reply divergence is real, and still a divergence" {
    // The anti-rot half, in both directions the deferral table checks. A row
    // whose key Zig has started answering argues against code that no longer
    // exists; a row naming a key the spec stopped answering argues against
    // nothing at all, and the next reader has no way to tell which.
    for (deliberate_reply_divergences) |d| {
        try testing.expect(d.reason.len > 0);

        var probe = PairProbe{ .action = d.action, .key = d.key };
        try forEachReplyKey(&probe, probePair);
        if (!probe.found) {
            std.debug.print(
                "the divergence table says {s} deliberately drops `{s}`, and the spec's reply " ++
                    "does not carry that key — delete the row.\n",
                .{ d.action, d.key },
            );
            return error.ReplyDivergenceNamesNoSuchKey;
        }

        const source = implementationOf(zigSourceFor(d.action) orelse continue);
        if (try emitsJsonKey(source, d.key)) {
            std.debug.print(
                "{s} is recorded as deliberately not answering `{s}`, and it answers it now — " ++
                    "delete the row.\n",
                .{ d.action, d.key },
            );
            return error.ReplyDivergenceIsSpent;
        }
    }

    try testing.expect(deliberate_reply_divergences.len >= 3);
}

// ---------------------------------------------------------------------------
// The SDK's event map
//
// `craft.d.ts` augments `WindowEventMap`, which is what gives
// `window.addEventListener('craftLocationUpdate', …)` a typed `detail` instead
// of a bare `Event`. It is a third statement of the event vocabulary, after
// the spec's `sendToWeb` calls and `ios_events.Event`, and it was the only one
// nothing checked — so it had drifted in both directions at once.
//
// It omitted six events that do fire — `craftLocationUpdate`,
// `craftLocationError`, `craftNetworkChange`, `craftPushToken`,
// `craftNotificationResponse` and `craftWatchUserInfo` — so the most-used
// stream in the whole surface reached a page as an untyped `Event` whose
// `detail` was `any`.
//
// ## This file is cross-platform, and the first version of this check was not
//
// `craft.d.ts` is the SDK's whole type surface, not iOS's. Checking it against
// the iOS spec alone got a live type deleted: `craftVoiceAction` is dispatched
// by `CraftBridge.kt`, and a scan that never opened a `.kt.template` reported
// it as fiction. The check that replaced it would then have rejected the fix,
// because a correct Android-only entry fails an iOS-only rule — a guard whose
// own error message argues for the bug.
//
// So the vocabulary here is the union of what either bridge dispatches. The
// Android scan below is the same shape as the Swift one: `sendEvent("craftX"`
// for the helper, plus the `CustomEvent('craftX'` literals the injected JS
// emits directly. Android's `window._craftXResolve` handles are deliberately
// not matched — those are promise plumbing, not events.
// ---------------------------------------------------------------------------

const sdk_types = @embedFile("craft.d.ts");
const android_spec = @embedFile("CraftBridge.kt");

/// Every event `CraftBridge.kt` dispatches to the page.
fn collectAndroidDispatchedEvents(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    const Needle = struct { text: []const u8, quote: u8 };
    const needles = [_]Needle{
        .{ .text = "sendEvent(\"", .quote = '"' },
        .{ .text = "CustomEvent('", .quote = '\'' },
    };

    for (needles) |needle| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, android_spec, search, needle.text)) |at| {
            const start = at + needle.text.len;
            const end = std.mem.indexOfScalarPos(u8, android_spec, start, needle.quote) orelse break;
            search = end;

            const name = android_spec[start..end];
            if (!std.mem.startsWith(u8, name, "craft")) continue;
            var ok = true;
            for (name) |c| {
                if (!std.ascii.isAlphanumeric(c)) ok = false;
            }
            if (ok) try set.put(name, {});
        }
    }
    return set;
}

/// What either bridge dispatches — the vocabulary `craft.d.ts` describes.
fn collectAllDispatchedEvents(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = try collectSpecDispatchedEvents(allocator);
    errdefer set.deinit();

    var android = try collectAndroidDispatchedEvents(allocator);
    defer android.deinit();

    var it = android.keyIterator();
    while (it.next()) |name| try set.put(name.*, {});
    return set;
}

/// The keys of `interface WindowEventMap { … }`.
fn collectSdkEventMap(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    const start = std.mem.indexOf(u8, sdk_types, "interface WindowEventMap {") orelse
        return error.EventMapNotFound;
    const body = sdk_types[start..];
    const end = std.mem.indexOf(u8, body, "\n  }") orelse return error.EventMapNotFound;

    var it = std.mem.splitScalar(u8, body[0..end], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "craft")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        try set.put(trimmed[0..colon], {});
    }
    return set;
}

test "the SDK's event map declares nothing that never fires" {
    // The map is the most authoritative-looking statement of the vocabulary —
    // it is what an editor autocompletes from — and it was the one with no
    // check behind it.
    var map = try collectSdkEventMap(testing.allocator);
    defer map.deinit();

    // Non-vacuity: a renamed interface would empty this set.
    try testing.expect(map.count() >= 21);

    var dispatched = try collectAllDispatchedEvents(testing.allocator);
    defer dispatched.deinit();

    var it = map.keyIterator();
    while (it.next()) |name| {
        if (dispatched.contains(name.*)) continue;

        std.debug.print(
            "craft.d.ts types `{s}` in WindowEventMap, and nothing dispatches it.\n" ++
                "  A listener written against it type-checks and is never called.\n",
            .{name.*},
        );
        return error.SdkTypesAnEventNothingEmits;
    }
}

test "the SDK's event map declares everything that does fire" {
    // The other direction, and the one that had six holes in it. An event
    // missing from the map is not a compile error for the page — the
    // `addEventListener` overload falls back to `Event`, whose `detail` is
    // `any` — so the cost is silent: no autocomplete, no shape, no check that
    // the field being read exists.
    var map = try collectSdkEventMap(testing.allocator);
    defer map.deinit();

    var dispatched = try collectAllDispatchedEvents(testing.allocator);
    defer dispatched.deinit();
    try testing.expect(dispatched.count() >= 20);

    var it = dispatched.keyIterator();
    while (it.next()) |name| {
        if (!map.contains(name.*)) {
            std.debug.print(
                "the spec dispatches `{s}` and craft.d.ts does not type it.\n" ++
                    "  A page listening for it gets a bare Event and a `detail` of any.\n",
                .{name.*},
            );
            return error.SdkDoesNotTypeAnEventThatFires;
        }
    }
}
