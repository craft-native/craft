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
/// biometric persistence, and permissions — including the first async reply.
const max_not_yet_migrated: usize = 74;

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
            try set.put(trimmed[open + 1 .. close], {});
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
