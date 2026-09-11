//! `startBluetoothScan` and `stopBluetoothScan` on Android.
//!
//! The third listener shim. `ScanCallback` is an abstract Java class, so the
//! object lives in `CraftNative` and every result forwards here.
//!
//! ## Start results are explicit
//!
//! The Kotlin holder owns the `ScanCallback`, but Zig owns the promise. Its
//! integer result distinguishes a scan that actually started from an absent
//! adapter, a powered-off adapter, a missing permission, or a scanner/runtime
//! failure. This prevents an unavailable radio from looking like a successful
//! scan in an empty room. See #185.
//!
//! ## The name default is a decision, so it is made here
//!
//! `result.device.name ?: "Unknown"` — a BLE advertisement often carries no
//! name at all, so this is the common case rather than the edge one. The
//! holder passes the nullable name across and this module applies the default,
//! which keeps the one judgement in the file that has tests.

const std = @import("std");
const events = @import("android_events.zig");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const start_bluetooth_scan = "startBluetoothScan";
    pub const stop_bluetooth_scan = "stopBluetoothScan";
};

pub const resolve_global = "_craftBleResolve";
pub const reject_global = "_craftBleReject";

/// The event each scan result becomes.
pub const event_name = "craftBluetoothDevice";

/// What a device with no advertised name is called.
pub const unknown_name = "Unknown";

/// `CraftBridge.REQUEST_BLUETOOTH`.
pub const request_bluetooth: i32 = 1009;

pub const StartStatus = enum(i32) {
    started = 0,
    no_adapter = 1,
    powered_off = 2,
    permission_denied = 3,
    scanner_unavailable = 4,
    failed = 5,
};

pub fn startError(status: i32) ?[]const u8 {
    return switch (status) {
        @backingInt(StartStatus.started) => null,
        @backingInt(StartStatus.no_adapter) => "Bluetooth is unavailable on this device",
        @backingInt(StartStatus.powered_off) => "Bluetooth is switched off",
        @backingInt(StartStatus.permission_denied) => "Bluetooth permission denied",
        @backingInt(StartStatus.scanner_unavailable) => "Bluetooth LE scanning is unavailable",
        else => "Bluetooth scan could not start",
    };
}

/// `{"id":"…","name":"…","rssi":-70}`.
///
/// Key order is the shim's `mapOf`, which is a `LinkedHashMap` — so id, name,
/// rssi, and not alphabetical.
pub fn renderDevice(
    allocator: std.mem.Allocator,
    address: []const u8,
    name: ?[]const u8,
    rssi: i32,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"id\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, address);
    try out.appendSlice(allocator, "\",\"name\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, name orelse unknown_name);
    try out.appendSlice(allocator, "\",\"rssi\":");
    try out.print(allocator, "{d}", .{rssi});
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// Send one scan result as `craftBluetoothDevice`.
pub fn announce(
    allocator: std.mem.Allocator,
    address: []const u8,
    name: ?[]const u8,
    rssi: i32,
) !void {
    const detail = try renderDevice(allocator, address, name, rssi);
    defer allocator.free(detail);
    try events.emitEvent(allocator, event_name, detail);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "a named device prints the shim's three keys, in its order" {
    const json = try renderDevice(testing.allocator, "AA:BB:CC:DD:EE:FF", "Pixel Buds", -63);
    defer testing.allocator.free(json);

    // `mapOf` is a LinkedHashMap and `JSONObject(Map)` keeps its iteration
    // order, so this is insertion order rather than alphabetical.
    try testing.expectEqualStrings(
        \\{"id":"AA:BB:CC:DD:EE:FF","name":"Pixel Buds","rssi":-63}
    , json);
}

test "a device with no name is Unknown, not empty and not absent" {
    // `result.device.name ?: "Unknown"`. A BLE advertisement often carries no
    // name, so this is the common case — and "Unknown" is a string a page may
    // well be filtering on.
    const json = try renderDevice(testing.allocator, "AA:BB", null, -90);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\{"id":"AA:BB","name":"Unknown","rssi":-90}
    , json);

    // An empty name is not the absent case: the device advertised one, and it
    // is empty.
    const empty = try renderDevice(testing.allocator, "AA:BB", "", -90);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings(
        \\{"id":"AA:BB","name":"","rssi":-90}
    , empty);
}

test "rssi is a number, and it is usually negative" {
    // Signal strength in dBm — a bare JSON number, not a string, so a page can
    // compare it. Zero and positive values are legal and do occur very close
    // to a transmitter.
    for ([_]i32{ -100, -63, 0, 7 }) |rssi| {
        const json = try renderDevice(testing.allocator, "AA", "x", rssi);
        defer testing.allocator.free(json);

        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(i64, rssi), parsed.value.object.get("rssi").?.integer);
    }
}

test "a device name carrying a quote survives as JSON" {
    // A BLE name is whatever the peripheral advertises — arbitrary bytes the
    // app has no say over, arriving through the event channel.
    const json = try renderDevice(testing.allocator, "AA", "Bob's \"speaker\"\n", -50);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("Bob's \"speaker\"\n", parsed.value.object.get("name").?.string);
}

test "the actions, globals and event name match the shim exactly" {
    try testing.expectEqualStrings("startBluetoothScan", A.start_bluetooth_scan);
    try testing.expectEqualStrings("stopBluetoothScan", A.stop_bluetooth_scan);
    try testing.expectEqualStrings("_craftBleResolve", resolve_global);
    try testing.expectEqualStrings("_craftBleReject", reject_global);
    try testing.expectEqualStrings("craftBluetoothDevice", event_name);
    try testing.expectEqualStrings("Unknown", unknown_name);
}

test "scan start statuses reject every path that did not start a scan" {
    try testing.expectEqual(@as(?[]const u8, null), startError(@backingInt(StartStatus.started)));
    try testing.expectEqualStrings("Bluetooth is unavailable on this device", startError(@backingInt(StartStatus.no_adapter)).?);
    try testing.expectEqualStrings("Bluetooth is switched off", startError(@backingInt(StartStatus.powered_off)).?);
    try testing.expectEqualStrings("Bluetooth permission denied", startError(@backingInt(StartStatus.permission_denied)).?);
    try testing.expectEqualStrings("Bluetooth LE scanning is unavailable", startError(@backingInt(StartStatus.scanner_unavailable)).?);
    try testing.expectEqualStrings("Bluetooth scan could not start", startError(@backingInt(StartStatus.failed)).?);
    try testing.expectEqualStrings("Bluetooth scan could not start", startError(99).?);
}
