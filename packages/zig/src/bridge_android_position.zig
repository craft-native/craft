//! `getCurrentPosition` on Android.
//!
//! The fifth listener shim, and the second to need `android_json_number` —
//! seven numbers, six of which are doubles.
//!
//! ## Six doubles, and three of them started as floats
//!
//! `Location.accuracy`, `.speed` and `.bearing` are `Float`, but the shim
//! writes them with `put(name, value)` and the overload Kotlin picks is
//! `put(String, double)` — primitive widening beats boxing. So they are
//! `Double`s by the time `numberToString` sees them, and print as doubles.
//!
//! That matters because the same float prints differently in the two places
//! this bridge sends one. `bridge_android_motion` puts its floats into a
//! `Map`, which boxes them as `Float`, so an accuracy of `0.1f` reads "0.1"
//! there and "0.10000000149011612" here. Neither is wrong; they are different
//! calls. It is the reason `android_json_number` has two functions rather than
//! one widening one.
//!
//! ## Two rejections with different codes and different shapes
//!
//! `{code: 1, message: 'Permission denied'}` is a fixed object. `{code: 2,
//! message: <exception>}` carries whatever Play Services said. Both are JS
//! object literals in the shim with unquoted keys; here they are JSON, which
//! parses to the same object.
//!
//! There is no code 3, and no rejection at all for the case where the fresh
//! location request never produces a result — the promise simply never
//! settles. That is the shim's behaviour and is left alone here; see #157 for
//! the same shape elsewhere.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const get_current_position = "getCurrentPosition";
};

pub const resolve_global = "_craftLocationResolve";
pub const reject_global = "_craftLocationReject";

/// `{code: 1, ...}` — the permission refusal.
pub const code_permission_denied: i32 = 1;

/// `{code: 2, ...}` — whatever the location client failed with.
pub const code_client_failure: i32 = 2;

pub const permission_denied_message = "Permission denied";

/// The seven values a position reply carries, already printed.
///
/// Strings rather than numbers, because printing them is `org.json`'s job —
/// see `android_json_number`. What this file owns is which keys they go under
/// and in what order.
pub const Printed = struct {
    latitude: []const u8,
    longitude: []const u8,
    accuracy: []const u8,
    altitude: []const u8,
    speed: []const u8,
    /// `location.bearing`, under the key `heading`.
    heading: []const u8,
    timestamp: []const u8,
};

/// A position, as the shim's `JSONObject` prints it.
///
/// Insertion order, because `JSONObject` is a `LinkedHashMap` — and the key
/// for `location.bearing` is `heading`, which is the one name here that does
/// not match the field it came from.
pub fn renderPosition(allocator: std.mem.Allocator, values: Printed) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"latitude\":");
    try out.appendSlice(allocator, values.latitude);
    try out.appendSlice(allocator, ",\"longitude\":");
    try out.appendSlice(allocator, values.longitude);
    try out.appendSlice(allocator, ",\"accuracy\":");
    try out.appendSlice(allocator, values.accuracy);
    try out.appendSlice(allocator, ",\"altitude\":");
    try out.appendSlice(allocator, values.altitude);
    try out.appendSlice(allocator, ",\"speed\":");
    try out.appendSlice(allocator, values.speed);
    try out.appendSlice(allocator, ",\"heading\":");
    try out.appendSlice(allocator, values.heading);
    try out.appendSlice(allocator, ",\"timestamp\":");
    try out.appendSlice(allocator, values.timestamp);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// `{code: n, message: "…"}`.
pub fn renderRejection(allocator: std.mem.Allocator, code: i32, message: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"code\":");
    try out.print(allocator, "{d}", .{code});
    try out.appendSlice(allocator, ",\"message\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, message);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "a position prints seven keys, in the shim's order" {
    const json = try renderPosition(testing.allocator, .{
        .latitude = "51.5074",
        .longitude = "-0.1278",
        .accuracy = "12.5",
        .altitude = "35.2",
        .speed = "0",
        .heading = "0",
        .timestamp = "1700000000000",
    });
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\{"latitude":51.5074,"longitude":-0.1278,"accuracy":12.5,"altitude":35.2,"speed":0,"heading":0,"timestamp":1700000000000}
    , json);
}

test "bearing is called heading, which is the one name that changes" {
    // `put("heading", location.bearing)`. Every other key matches its field,
    // so this is the one a rewrite would silently get right-looking and wrong.
    const json = try renderPosition(testing.allocator, .{
        .latitude = "0",
        .longitude = "0",
        .accuracy = "0",
        .altitude = "0",
        .speed = "0",
        .heading = "271.5",
        .timestamp = "0",
    });
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.object.get("bearing") == null);
    try testing.expectEqual(@as(f64, 271.5), parsed.value.object.get("heading").?.float);
    try testing.expectEqual(@as(usize, 7), parsed.value.object.count());
}

test "org.json's integral form parses as a number, not a string" {
    // A stationary device reports speed and bearing of exactly zero, and
    // `numberToString` prints those as `0` rather than `0.0`. A page doing
    // arithmetic on them needs them to be numbers, which they are.
    const json = try renderPosition(testing.allocator, .{
        .latitude = "0",
        .longitude = "-0",
        .accuracy = "9",
        .altitude = "0",
        .speed = "0",
        .heading = "0",
        .timestamp = "1700000000000",
    });
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 9), parsed.value.object.get("accuracy").?.integer);
    try testing.expectEqual(@as(i64, 1700000000000), parsed.value.object.get("timestamp").?.integer);
}

test "the two rejections carry different codes" {
    // A page distinguishes "the user said no" from "the location client
    // failed" by the code alone, so the numbers are API.
    const denied = try renderRejection(testing.allocator, code_permission_denied, permission_denied_message);
    defer testing.allocator.free(denied);
    try testing.expectEqualStrings(
        \\{"code":1,"message":"Permission denied"}
    , denied);

    const failed = try renderRejection(testing.allocator, code_client_failure, "GoogleApiClient is not connected yet");
    defer testing.allocator.free(failed);
    try testing.expectEqualStrings(
        \\{"code":2,"message":"GoogleApiClient is not connected yet"}
    , failed);

    try testing.expectEqual(@as(i32, 1), code_permission_denied);
    try testing.expectEqual(@as(i32, 2), code_client_failure);
}

test "a failure message carrying a quote survives as JSON" {
    // The message is whatever Play Services threw, which is not text this
    // repository controls — and it goes to the page through the same channel
    // that hung the promise before #154.
    const json = try renderRejection(testing.allocator, code_client_failure, "it's \"broken\"\n");
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("it's \"broken\"\n", parsed.value.object.get("message").?.string);
}

test "the action and globals match the shim exactly" {
    try testing.expectEqualStrings("getCurrentPosition", A.get_current_position);
    try testing.expectEqualStrings("_craftLocationResolve", resolve_global);
    try testing.expectEqualStrings("_craftLocationReject", reject_global);
}
