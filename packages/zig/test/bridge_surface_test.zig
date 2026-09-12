//! What `window.craft` promises, and what each bridge actually puts on it.
//!
//! `ios_conformance_test.zig` checks one direction and says so: every action
//! the injected JavaScript can *post* is one the dispatcher handles. That was
//! written for the `ota*` bug — five methods whose promises could never settle.
//!
//! The reverse has never been checked, and it is where the surface has drifted
//! furthest. `craft.d.ts` declares `window.craft` as `CraftBridge`, an
//! interface of direct methods. Every one must be a callable property on both
//! platform objects. Platform-only capabilities still expose the method and
//! reject with a useful error, instead of failing at property lookup with a
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
const std = @import("std");
const testing = std.testing;

const ios_spec = @embedFile("CraftApp.swift");
const android_spec = @embedFile("CraftBridge.kt");
const sdk_types = @embedFile("craft.d.ts");

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

/// Is `name` defined as a direct function property on this object?
///
/// The indentation of `platform` identifies the outer object's property
/// depth. This deliberately does not accept a same-named method buried in a
/// namespace: `craft.health.getData` does not make `craft.getData` callable.
fn definesDirectMethod(object: []const u8, name: []const u8) bool {
    var property_indent: ?usize = null;
    var lines = std.mem.splitScalar(u8, object, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "platform:")) {
            property_indent = line.len - trimmed.len;
            break;
        }
    }

    const expected_indent = property_indent orelse return false;
    lines = std.mem.splitScalar(u8, object, '\n');
    while (lines.next()) |line| {
        const body = std.mem.trimStart(u8, line, " \t");
        if (line.len - body.len != expected_indent) continue;
        if (!std.mem.startsWith(u8, body, name)) continue;

        var i = name.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
        if (i >= body.len or body[i] != ':') continue;

        i += 1;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
        if (std.mem.startsWith(u8, body[i..], "function")) return true;
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
    try testing.expect(definesDirectMethod(ios, "getDeviceInfo"));
    try testing.expect(definesDirectMethod(android, "getDeviceInfo"));
    try testing.expect(!definesDirectMethod(ios, "getAll"));
    try testing.expect(!definesDirectMethod(android, "getAll"));
    try testing.expect(!definesDirectMethod(ios, "noSuchMethodAnywhere"));
}

test "every direct method craft.d.ts declares exists directly on both bridges" {
    // Not `.?` — a broken scan should fail this test with a name, not abort the
    // whole runner on an unwrap and take the other tests' output with it.
    const ios = craftObject(ios_spec) orelse return error.IosCraftObjectNotFound;
    const android = craftObject(android_spec) orelse return error.AndroidCraftObjectNotFound;

    var declared = try collectDeclaredMethods(testing.allocator);
    defer declared.deinit(testing.allocator);

    var absent_ios: usize = 0;
    var absent_android: usize = 0;
    var absent_both: usize = 0;

    for (declared.items) |name| {
        const on_ios = definesDirectMethod(ios, name);
        const on_android = definesDirectMethod(android, name);
        if (on_ios and on_android) continue;

        if (!on_ios) absent_ios += 1;
        if (!on_android) absent_android += 1;
        if (!on_ios and !on_android) {
            absent_both += 1;
            std.debug.print("  craft.{s}() is declared and exists on neither bridge\n", .{name});
        } else if (!on_ios) {
            std.debug.print("  craft.{s}() is declared, exists on Android, TypeError on iOS\n", .{name});
        } else {
            std.debug.print("  craft.{s}() is declared, exists on iOS, TypeError on Android\n", .{name});
        }
    }

    if (absent_ios != 0 or absent_android != 0) {
        std.debug.print(
            "\n{d} declared methods are absent from iOS, {d} from Android, {d} from both.\n" ++
                "  A method on `CraftBridge` is a promise that `window.craft.<name>` is callable.\n" ++
                "  Either implement it on the bridge or stop declaring it.\n",
            .{ absent_ios, absent_android, absent_both },
        );
        return error.DeclaredMethodMissingFromBridge;
    }
}
