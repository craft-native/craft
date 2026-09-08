//! What `window.craft` promises, and what each bridge actually puts on it.
//!
//! `ios_conformance_test.zig` checks one direction and says so: every action
//! the injected JavaScript can *post* is one the dispatcher handles. That was
//! written for the `ota*` bug — five methods whose promises could never settle.
//!
//! The reverse has never been checked, and it is where the surface has drifted
//! furthest. `craft.d.ts` declares `window.craft` as `CraftBridge`, an
//! interface of 78 direct methods; 33 of them are not on the object iOS
//! injects and 17 are on neither platform's. They type-check and throw
//! `TypeError`.
//!
//! ## What this is not claiming
//!
//! The *actions* work. Both bridges expose a generic escape hatch —
//! `craft._invoke(action, payload)` on iOS (`CraftApp.swift:2543`) and
//! `craft.invoke('namespace.action', params)` in `craft-bridge.js` — and the
//! dispatcher arms behind these names are implemented, several of them in Zig.
//! So the gap is a missing *named method* and a declaration promising one, not
//! a missing capability. Worth stating because "unreachable" was the first
//! reading and it was wrong.
//!
//! ## Ratchets rather than a table of reasons
//!
//! The unimplemented names get counts, not rows. A row here would have to
//! carry a reason, and there is no honest reason to write for most of them:
//! they are a backlog nobody has worked through, not a set of decisions —
//! and `ios_conformance_test.zig` already records why demanding a reason for
//! that state "would only invite an invented reason". The failure message
//! names every offender, so the count losing detail costs nothing.

const std = @import("std");
const testing = std.testing;

const ios_spec = @embedFile("CraftApp.swift");
const android_spec = @embedFile("CraftBridge.kt");
const sdk_types = @embedFile("craft.d.ts");

/// How many `CraftBridge` methods iOS's injected object does not define.
///
/// A ratchet in the shape `max_not_yet_migrated` already uses: it may only go
/// down. Adding a declaration without the method fails here, which is the
/// conversation this constant exists to force.
const max_absent_from_ios: usize = 33;

/// The same, for methods on neither bridge. A subset of the above by
/// construction, and the worse half: nothing an app runs on provides them.
const max_absent_from_both: usize = 17;

/// The `window.craft = { … }` object literal, brace-balanced.
///
/// Both bridges build one, which is what makes a single check meaningful:
/// Android reaches native through `CraftAndroid.<method>()` and iOS through
/// `postMessage`, but the object a page writes against is the same idea on
/// both, and `craft.d.ts` describes exactly one of them.
fn craftObject(source: []const u8) ?[]const u8 {
    const marker = "window.craft = {";
    const at = std.mem.indexOf(u8, source, marker) orelse return null;
    var depth: usize = 0;
    var i = at + marker.len - 1;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return source[at .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Is `name` defined as a function on this object, at any nesting depth?
///
/// Depth is deliberately ignored. `craft.d.ts` declares these as direct
/// methods, so a namespaced implementation is still a mismatch with the type —
/// but it is a *different* mismatch from nothing existing at all, and calling
/// the second one "missing" while quietly passing the first would hide the
/// worse case behind the milder one.
fn definesMethod(object: []const u8, name: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, object, search, name)) |at| {
        search = at + 1;

        // A whole word, not a suffix: `stopScan` must not match `startScan`.
        if (at > 0) {
            const before = object[at - 1];
            if (std.ascii.isAlphanumeric(before) or before == '_') continue;
        }

        var i = at + name.len;
        while (i < object.len and (object[i] == ' ' or object[i] == '\n')) : (i += 1) {}
        if (i >= object.len or object[i] != ':') continue;

        i += 1;
        while (i < object.len and (object[i] == ' ' or object[i] == '\n')) : (i += 1) {}
        if (std.mem.startsWith(u8, object[i..], "function")) return true;
    }
    return false;
}

/// The method names declared directly on `interface CraftBridge`.
///
/// Two-space indent is the discriminator: it is what separates a method on the
/// interface itself from one nested inside a namespace object, and only the
/// former is a promise about `window.craft.<name>`.
fn collectDeclaredMethods(allocator: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    const start = std.mem.indexOf(u8, sdk_types, "export interface CraftBridge {") orelse
        return error.CraftBridgeInterfaceNotFound;
    const rest = sdk_types[start..];
    const end = std.mem.indexOf(u8, rest, "\n}") orelse return error.CraftBridgeInterfaceNotFound;

    var it = std.mem.splitScalar(u8, rest[0..end], '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  ")) continue;
        if (std.mem.startsWith(u8, line, "   ")) continue;

        const body = line[2..];
        var i: usize = 0;
        while (i < body.len and (std.ascii.isAlphanumeric(body[i]) or body[i] == '_')) : (i += 1) {}
        if (i == 0 or i >= body.len or body[i] != '(') continue;
        try out.append(allocator, body[0..i]);
    }
    return out;
}

test "the surface scans find both objects and the interface" {
    // Non-vacuity, and the floors are the point: every assertion below counts
    // absences, so a scan that found nothing would report a perfect surface.
    const ios = craftObject(ios_spec) orelse return error.IosCraftObjectNotFound;
    const android = craftObject(android_spec) orelse return error.AndroidCraftObjectNotFound;
    try testing.expect(ios.len > 10_000);
    try testing.expect(android.len > 10_000);

    var declared = try collectDeclaredMethods(testing.allocator);
    defer declared.deinit(testing.allocator);
    try testing.expect(declared.items.len >= 70);

    // And the matcher works in both directions on a name each bridge really
    // does define — otherwise "absent everywhere" would be the vacuous answer.
    try testing.expect(definesMethod(ios, "getDeviceInfo"));
    try testing.expect(definesMethod(android, "getDeviceInfo"));
    try testing.expect(!definesMethod(ios, "noSuchMethodAnywhere"));
}

test "every method craft.d.ts declares exists on the bridges that ship it" {
    // Not `.?` — a broken scan should fail this test with a name, not abort the
    // whole runner on an unwrap and take the other tests' output with it.
    const ios = craftObject(ios_spec) orelse return error.IosCraftObjectNotFound;
    const android = craftObject(android_spec) orelse return error.AndroidCraftObjectNotFound;

    var declared = try collectDeclaredMethods(testing.allocator);
    defer declared.deinit(testing.allocator);

    var absent_ios: usize = 0;
    var absent_both: usize = 0;

    for (declared.items) |name| {
        const on_ios = definesMethod(ios, name);
        const on_android = definesMethod(android, name);
        if (on_ios and on_android) continue;

        if (!on_ios) absent_ios += 1;
        if (!on_ios and !on_android) {
            absent_both += 1;
            std.debug.print("  craft.{s}() is declared and exists on neither bridge\n", .{name});
        } else if (!on_ios) {
            std.debug.print("  craft.{s}() is declared, exists on Android, TypeError on iOS\n", .{name});
        } else {
            std.debug.print("  craft.{s}() is declared, exists on iOS, TypeError on Android\n", .{name});
        }
    }

    if (absent_ios > max_absent_from_ios or absent_both > max_absent_from_both) {
        std.debug.print(
            "\n{d} declared methods are absent from iOS (allowed {d}), {d} from both (allowed {d}).\n" ++
                "  A method on `CraftBridge` is a promise that `window.craft.<name>` is callable.\n" ++
                "  Either implement it on the bridge or stop declaring it.\n",
            .{ absent_ios, max_absent_from_ios, absent_both, max_absent_from_both },
        );
        return error.DeclaredMethodMissingFromBridge;
    }

    // The ratchet is only a ratchet if it is tightened.
    if (absent_ios < max_absent_from_ios or absent_both < max_absent_from_both) {
        std.debug.print(
            "note: {d} absent from iOS and {d} from both; the ratchets are {d}/{d} and can be lowered.\n",
            .{ absent_ios, absent_both, max_absent_from_ios, max_absent_from_both },
        );
    }
}
