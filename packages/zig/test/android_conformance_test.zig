//! What Android owes the page, and who currently owes it.
//!
//! The counterpart to `ios_conformance_test.zig`, and it starts where that one
//! started: `CraftBridge.kt` is the specification, its `@JavascriptInterface`
//! methods are the list of actions a craft Android app answers today, and Zig
//! has to end up answering all of them. This is what stops one being dropped
//! on the way across.
//!
//! iOS reached this file's job with 105 actions unmigrated and is at 13.
//! Android is at 102 of 103. The ratchet exists now rather than later for the
//! reason the iOS one earned: the second migration is where a name quietly
//! stops matching, and by then nothing remembers what the first one agreed to.
//!
//! ## Two seams, not one
//!
//! iOS has a single contract to check — an action string that must appear on
//! both sides. Android has two, because the call arrives through JNI:
//!
//!   1. **the action**, `@JavascriptInterface fun getDeviceInfo()` against the
//!      `A` block of whichever Zig module serves it;
//!   2. **the binding**, the `name` in `android_dispatch.natives` against the
//!      `external fun` that `CraftNative.kt` declares.
//!
//! The second has no compiler behind it at all. `RegisterNatives` matches by
//! string at load, so renaming one side and not the other fails at
//! `System.loadLibrary` — in the app, on a device, with a message that names
//! the method and nothing about where the other half went.

const std = @import("std");
const testing = std.testing;

/// Embedded rather than read from disk, so the test is hermetic and reads
/// exactly the bytes the build saw.
const android_spec = @embedFile("CraftBridge.kt");
const native_holder = @embedFile("CraftNative.kt");
const dispatch_source = @embedFile("src/android_dispatch.zig");

/// Every Zig module serving part of the Android bridge. A module migrating
/// actions adds itself here — and the ratchet is what forces that, because
/// migrated actions the scan cannot see read as "still owed".
const zig_sources = [_][]const u8{
    @embedFile("src/bridge_android_device.zig"),
    @embedFile("src/bridge_android_system.zig"),
    @embedFile("src/bridge_android_clipboard.zig"),
    @embedFile("src/bridge_android_intents.zig"),
    @embedFile("src/bridge_android_network.zig"),
    @embedFile("src/bridge_android_securestore.zig"),
    @embedFile("src/bridge_android_haptics.zig"),
    @embedFile("src/bridge_android_notifcancel.zig"),
    @embedFile("src/bridge_android_calendar.zig"),
    @embedFile("src/bridge_android_db.zig"),
    @embedFile("src/bridge_android_shareditem.zig"),
};

/// How many spec actions Zig does not serve yet.
///
/// A ratchet: the number may only go down, and lowering it is what a migration
/// costs. If it ever needs raising, something has left Zig without leaving the
/// Kotlin, and that is the conversation this constant exists to force.
///
/// History: 103 at the seam; 102 with getDeviceInfo; 100 with getMemoryUsage
/// and log — the first two that need no Activity at all; 98 with the
/// clipboard pair, the first that do; 96 with openURL and share; 95 with
/// getNetworkStatus, which iOS declares unavailable and Android can answer;
/// 91 with the secure-storage quartet, the first to take a Kotlin-held object
/// rather than the Activity; 89 with haptic and vibrate; 87 with the
/// notification cancels; 86 with deleteCalendarEvent, the first to answer
/// through the reply channel rather than by returning; 85 with
/// getCalendarEvents, the first to send the page a payload it built rather
/// than a constant; 84 with createCalendarEvent, the first to read one; 82
/// with the database pair, the first to borrow a connection the Kotlin owns;
/// 79 with the shared-item trio.
const max_not_yet_migrated: usize = 79;

/// Every `@JavascriptInterface fun <name>(` in the Kotlin bridge.
///
/// Anchored on the annotation, not on `fun`, because `CraftBridge.kt` has
/// plenty of private helpers that are not page-callable — `sendEvent`,
/// `taskReply`, the permission plumbing. Only an annotated method is part of
/// the contract, which is the same reason the iOS scan is bounded to the
/// dispatcher rather than the whole file.
fn collectSpecActions(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    const marker = "@JavascriptInterface";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, android_spec, search, marker)) |at| {
        search = at + marker.len;

        const fun_at = std.mem.indexOfPos(u8, android_spec, search, "fun ") orelse break;
        // Only the declaration that immediately follows: an annotation whose
        // next `fun` is fifty lines away means the scan has lost its place.
        if (fun_at - search > 200) continue;

        const name_start = fun_at + "fun ".len;
        var name_end = name_start;
        while (name_end < android_spec.len and
            (std.ascii.isAlphanumeric(android_spec[name_end]) or android_spec[name_end] == '_')) : (name_end += 1)
        {}
        if (name_end == name_start) continue;
        try set.put(android_spec[name_start..name_end], {});
        search = name_end;
    }
    return set;
}

/// Every action name declared in the `A` blocks of the Android modules.
fn collectZigActions(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    for (zig_sources) |source| {
        const block_start = std.mem.indexOf(u8, source, "pub const A = struct {") orelse continue;
        var it = std.mem.splitScalar(u8, source[block_start..], '\n');
        _ = it.next();
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, trimmed, "};")) break;
            const open = std.mem.indexOfScalar(u8, trimmed, '"') orelse continue;
            const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, '"') orelse continue;

            const name = trimmed[open + 1 .. close];
            if (set.contains(name)) {
                std.debug.print(
                    "action '{s}' is declared by more than one Android module.\n" ++
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

const Deferral = struct {
    action: []const u8,
    reason: []const u8,
};

/// Actions deliberately left on the Kotlin, with the reason each is left.
///
/// The iOS table this mirrors exists because three of its reasons had expired
/// and nothing re-checked them — a migration is where prose goes stale fastest,
/// since the thing a reason describes is exactly what the next commit changes.
/// So the table arrives here with the first row that needs it rather than after
/// the tenth, and the two guards below are the whole point: a row Zig starts
/// serving fails, and so does a row naming an action the Kotlin no longer has.
///
/// Deliberately non-exhaustive. Most unmigrated actions are simply not reached
/// yet, which is an honest state that needs no row. A reason is owed only where someone would otherwise try and find
/// out the hard way — and demanding one for the rest would invite an invented
/// reason, which is worse than silence.
const deliberate_deferrals = [_]Deferral{
    // Not a capability gap: the Kotlin builds a `NotificationManagerCompat`,
    // discards it, never reads `count`, and returns. The real work is left as
    // two comments. Migrating it would mean porting a no-op — the same reason
    // the iOS table refuses `startVideoRecording`, whose success path has never
    // run.
    //
    // Android has no first-party badge API and the Kotlin's comment is right
    // about that; launchers implement it through vendor broadcasts. But the
    // page cannot tell, because the same call works on iOS. Tracked in #148.
    .{ .action = "setBadge", .reason = "the Kotlin discards the manager it builds and never reads count; there is no working contract to port" },
    .{ .action = "clearBadge", .reason = "delegates to setBadge, which does nothing" },

    // Kotlin-held state, not a missing API. `setFlashlight` writes
    // `isFlashlightOn` (`CraftBridge.kt:2011`) and `toggleFlashlight` reads it
    // to decide what to flip to (`:2026`). Serving `setFlashlight` from Zig
    // means the Kotlin's body never runs, so the field stops tracking the
    // torch — and the next `toggleFlashlight` inverts a stale value and turns
    // the light on when it is already on.
    //
    // Zig cannot update the field either: the natives are registered on
    // `CraftNative`, which has no reference to the `CraftBridge` instance that
    // owns it. Migrating the pair together would need the state to move too,
    // and that is a change to the shim rather than a migration away from it.
    .{ .action = "setFlashlight", .reason = "writes isFlashlightOn, which toggleFlashlight reads; Zig cannot reach the field" },
    .{ .action = "toggleFlashlight", .reason = "reads isFlashlightOn, which only the Kotlin setFlashlight maintains" },

    // ---- Actions whose whole implementation is a refusal --------------
    //
    // These eight reject with a message and do nothing else. They are the
    // easiest actions in the file to "migrate" — the body is one string — and
    // migrating one would be a way of making this ratchet lie.
    //
    // The number counts actions Zig *serves*, meaning actions a page gets an
    // answer from Zig for. Moving a refusal across changes which language
    // holds the string and nothing a page can observe, so it would lower the
    // count without serving anything. That is worth recording explicitly,
    // because the incentive runs the other way: eleven rows here are eleven
    // easy decrements left on the table.
    //
    // Each is also honest as it stands, which is the other half of the reason.
    // Unlike `setBadge`, a page calling these is told plainly that the feature
    // is not there.
    .{ .action = "purchase", .reason = "the Kotlin rejects with 'Purchase flow not fully implemented'; porting a refusal serves nothing" },
    .{ .action = "scanQRCode", .reason = "the Kotlin rejects; ML Kit scanning was never wired up" },
    .{ .action = "signInWithGoogle", .reason = "the Kotlin rejects; Google Sign In needs build.gradle configuration" },
    .{ .action = "startAR", .reason = "the Kotlin rejects; ARCore needs Activity integration that does not exist" },
    .{ .action = "placeARObject", .reason = "the Kotlin rejects, for the same missing ARCore integration" },
    .{ .action = "removeARObject", .reason = "the Kotlin rejects, for the same missing ARCore integration" },
    .{ .action = "sendToWatch", .reason = "the Kotlin rejects; Wear OS needs a companion app" },
    .{ .action = "updateWatchContext", .reason = "the Kotlin rejects, for the same missing companion app" },

    // ---- And three that answer successfully instead ------------------
    //
    // Same shape, opposite honesty. `startAR` refuses to begin a session, and
    // then these two report success for operations on the session it refused
    // to create: `stopAR` resolves `{stopped: true}` and `getARPlanes`
    // resolves `[]`.
    //
    // The empty array is the one that costs something. A page cannot tell it
    // from "AR is running and has found no planes yet", so the honest failure
    // `startAR` already gave is undone by the next call. Recorded rather than
    // migrated for the same reason as `setBadge`: there is no working
    // behaviour to carry across, and porting the fabrication would spread it.
    .{ .action = "stopAR", .reason = "resolves {stopped:true} for a session startAR always refuses to open" },
    .{ .action = "getARPlanes", .reason = "resolves [], which a page cannot tell from AR running with no planes found" },
    .{ .action = "closePDF", .reason = "resolves true and does nothing; the Kotlin says PDFs open in an external viewer" },
};

test "every recorded deferral is real, and still a deferral" {
    // The anti-rot property. A deferral that has been migrated must fail here
    // rather than sit in a list telling the next reader not to bother.
    var spec = try collectSpecActions(testing.allocator);
    defer spec.deinit();

    var zig = try collectZigActions(testing.allocator);
    defer zig.deinit();

    for (deliberate_deferrals) |d| {
        if (!spec.contains(d.action)) {
            std.debug.print(
                "the deferral table names `{s}`, which CraftBridge.kt does not expose — " ++
                    "typo, or the method was renamed.\n",
                .{d.action},
            );
            return error.DeferralNamesNoSuchAction;
        }
        if (zig.contains(d.action)) {
            std.debug.print(
                "the deferral table still lists `{s}`, but Zig serves it now — " ++
                    "delete the row, its reason is spent.\n",
                .{d.action},
            );
            return error.DeferralAlreadyMigrated;
        }
        // A reason is the entire point of the row.
        try testing.expect(d.reason.len > 0);
    }

    // Non-vacuity: the loop above is satisfied by an empty table.
    try testing.expect(deliberate_deferrals.len >= 15);

    // And the table cannot claim more than remain unmigrated.
    try testing.expect(deliberate_deferrals.len <= max_not_yet_migrated);
}

test "the spec scan finds the bridge, and finds methods in it" {
    // Non-vacuity, first. Every assertion below is a membership check, and a
    // scan that silently matched nothing would satisfy all of them.
    var spec = try collectSpecActions(testing.allocator);
    defer spec.deinit();
    try testing.expect(spec.count() >= 100);

    // And it found real ones rather than fragments.
    try testing.expect(spec.contains("getDeviceInfo"));
    try testing.expect(spec.contains("clipboardRead"));
    try testing.expect(spec.contains("vibrate"));
}

test "every action Zig declares is one the Kotlin bridge actually has" {
    // The typo guard. `getDeviceinfo` for `getDeviceInfo` compiles on both
    // sides and is simply never called — the page keeps reaching the Kotlin,
    // and the Zig implementation sits there looking migrated.
    var spec = try collectSpecActions(testing.allocator);
    defer spec.deinit();

    var zig = try collectZigActions(testing.allocator);
    defer zig.deinit();
    try testing.expect(zig.count() >= 1);

    var it = zig.keyIterator();
    while (it.next()) |name| {
        if (!spec.contains(name.*)) {
            std.debug.print(
                "an Android module declares '{s}', which CraftBridge.kt does not expose.\n" ++
                    "  Either it is misspelled, or it is a surface no page can reach.\n",
                .{name.*},
            );
            return error.ZigServesAnActionTheSpecDoesNotHave;
        }
    }
}

test "nothing has been dropped on the way from Kotlin to Zig" {
    // The migration guard. Without it, moving an action across is
    // indistinguishable from losing it: both leave a page calling something
    // nothing answers.
    var spec = try collectSpecActions(testing.allocator);
    defer spec.deinit();

    var zig = try collectZigActions(testing.allocator);
    defer zig.deinit();

    var not_yet: usize = 0;
    var it = spec.keyIterator();
    while (it.next()) |name| {
        if (!zig.contains(name.*)) not_yet += 1;
    }

    if (not_yet > max_not_yet_migrated) {
        std.debug.print(
            "{d} spec actions are not served by Zig, but the ratchet allows {d}.\n" ++
                "  An action has left Zig without leaving the Kotlin.\n",
            .{ not_yet, max_not_yet_migrated },
        );
        return error.MigrationWentBackwards;
    }

    if (not_yet < max_not_yet_migrated) {
        std.debug.print(
            "note: {d} spec actions remain unmigrated; max_not_yet_migrated is {d} and can be lowered.\n",
            .{ not_yet, max_not_yet_migrated },
        );
    }
}

// ---------------------------------------------------------------------------
// The binding
//
// `RegisterNatives` matches by string at load time. Nothing checks that the
// name Zig registers is the name Kotlin declared — not the Zig compiler, which
// sees a string literal, and not the Kotlin compiler, which sees an `external
// fun` it assumes someone will bind. The two agree until one is renamed, and
// then `System.loadLibrary` fails on a device with a message that names the
// method and says nothing about where its other half went.
//
// So the two lists are read out of the two files and compared here, on a host,
// at build time.
// ---------------------------------------------------------------------------

/// The `name` field of every entry in `android_dispatch.natives`.
fn collectRegisteredNatives(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    const table_start = std.mem.indexOf(u8, dispatch_source, "const natives = [_]jni.JNINativeMethod{") orelse
        return error.NativesTableNotFound;
    const table_end = std.mem.indexOfPos(u8, dispatch_source, table_start, "\n};") orelse
        return error.NativesTableNotFound;
    const table = dispatch_source[table_start..table_end];

    const needle = ".name = \"";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, table, search, needle)) |at| {
        const start = at + needle.len;
        const end = std.mem.indexOfScalarPos(u8, table, start, '"') orelse break;
        try set.put(table[start..end], {});
        search = end;
    }
    return set;
}

/// Every `external fun <name>(` in the Kotlin holder.
fn collectDeclaredNatives(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer set.deinit();

    const needle = "external fun ";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, native_holder, search, needle)) |at| {
        const start = at + needle.len;
        var end = start;
        while (end < native_holder.len and
            (std.ascii.isAlphanumeric(native_holder[end]) or native_holder[end] == '_')) : (end += 1)
        {}
        search = end;
        if (end > start) try set.put(native_holder[start..end], {});
    }
    return set;
}

test "every native Zig registers is one the Kotlin holder declares" {
    // This direction fails the library load: RegisterNatives is given a name
    // the class does not have, refuses the whole batch, and JNI_OnLoad logs
    // that every action stayed on the shim.
    var registered = try collectRegisteredNatives(testing.allocator);
    defer registered.deinit();
    var declared = try collectDeclaredNatives(testing.allocator);
    defer declared.deinit();

    // Non-vacuity: two scans, either of which could stop matching and leave
    // this comparing empty sets.
    try testing.expect(registered.count() >= 1);
    try testing.expect(declared.count() >= 1);

    var it = registered.keyIterator();
    while (it.next()) |name| {
        if (!declared.contains(name.*)) {
            std.debug.print(
                "android_dispatch registers '{s}', which CraftNative.kt does not declare.\n" ++
                    "  RegisterNatives refuses the batch, and every action stays on the shim.\n",
                .{name.*},
            );
            return error.RegisteredNativeNotDeclared;
        }
    }
}

test "every native the Kotlin holder declares is one Zig registers" {
    // The quieter direction, and the worse one. An `external fun` nobody binds
    // loads fine and throws UnsatisfiedLinkError at the call — so it survives
    // the app starting, and surfaces when a page first reaches the feature.
    var registered = try collectRegisteredNatives(testing.allocator);
    defer registered.deinit();
    var declared = try collectDeclaredNatives(testing.allocator);
    defer declared.deinit();

    var it = declared.keyIterator();
    while (it.next()) |name| {
        if (!registered.contains(name.*)) {
            std.debug.print(
                "CraftNative.kt declares '{s}', which android_dispatch never registers.\n" ++
                    "  It loads, and throws UnsatisfiedLinkError the first time a page calls it.\n",
                .{name.*},
            );
            return error.DeclaredNativeNotRegistered;
        }
    }
}

test "the holder's package is the one JNI_OnLoad looks for" {
    // The third string with no compiler behind it. `FindClass` takes a binary
    // name with slashes; the Kotlin declares a package with dots. They are
    // written in two files, in two languages, and a prebuilt library that
    // cannot find its holder binds nothing at all.
    const decl = "package ";
    const at = std.mem.indexOf(u8, native_holder, decl) orelse return error.NoPackageDeclaration;
    const start = at + decl.len;
    var end = start;
    while (end < native_holder.len and native_holder[end] != '\n' and native_holder[end] != '\r') : (end += 1) {}
    const package = std.mem.trim(u8, native_holder[start..end], " \t\r");

    const holder_at = std.mem.indexOf(u8, dispatch_source, "pub const holder_class = \"") orelse
        return error.NoHolderClassConstant;
    const h_start = holder_at + "pub const holder_class = \"".len;
    const h_end = std.mem.indexOfScalarPos(u8, dispatch_source, h_start, '"') orelse
        return error.NoHolderClassConstant;
    const holder = dispatch_source[h_start..h_end];

    // `com.craft.runtime` + `CraftNative` must spell `com/craft/runtime/CraftNative`.
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    for (package) |c| {
        buf[written] = if (c == '.') '/' else c;
        written += 1;
    }
    const expected = try std.fmt.bufPrint(buf[written..], "/CraftNative", .{});
    const full = buf[0 .. written + expected.len];

    if (!std.mem.eql(u8, full, holder)) {
        std.debug.print(
            "CraftNative.kt is in package '{s}', so JNI_OnLoad must look for '{s}'.\n" ++
                "  android_dispatch.holder_class says '{s}'.\n",
            .{ package, full, holder },
        );
        return error.HolderClassDoesNotMatchPackage;
    }

    // And it stays untemplated: a substitution marker here would make the
    // prebuilt library app-specific, which is the whole reason this class is
    // separate from CraftBridge.
    try testing.expect(std.mem.indexOf(u8, package, "{") == null);
}
