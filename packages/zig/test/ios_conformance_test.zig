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
const max_not_yet_migrated: usize = 18;

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
    .{ .action = "startAR", .reason = "SceneKit node-graph glue; miserable and low-value through objc_msgSend" },
    .{ .action = "stopAR", .reason = "SceneKit node-graph glue; miserable and low-value through objc_msgSend" },
    .{ .action = "getARPlanes", .reason = "SceneKit node-graph glue; miserable and low-value through objc_msgSend" },
    .{ .action = "placeARObject", .reason = "SceneKit node-graph glue; miserable and low-value through objc_msgSend" },
    .{ .action = "removeARObject", .reason = "SceneKit node-graph glue; miserable and low-value through objc_msgSend" },

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

    // Not a capability gap: the spec's own success path has never executed, so
    // there is no working contract to port. See the tracking issue.
    .{ .action = "startVideoRecording", .reason = "the spec reads info[.originalImage] for a movie pick, so its success path never runs" },
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
    try testing.expect(deliberate_deferrals.len >= 18);

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

    const zig_src = @embedFile("src/bridge_mobile.zig");

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
