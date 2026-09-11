//! `authenticate` on Android.
//!
//! `BiometricPrompt.AuthenticationCallback` is an abstract Java class, so the
//! object itself stays in `CraftNative`. The holder also keeps the
//! `runOnUiThread` hop that constructs and presents the prompt. Every outcome
//! crosses back into Zig, which owns the promise payload and the distinction
//! between an unsupported Activity and an authentication error.
//!
//! ## Failure is not one event
//!
//! `onAuthenticationError` rejects immediately, while
//! `onAuthenticationFailed` deliberately does nothing and lets the user try
//! again. Conflating those callbacks would make a bad fingerprint end the
//! prompt where the Kotlin implementation keeps it open.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const authenticate = "authenticate";
};

pub const resolve_global = "_craftBiometricResolve";
pub const reject_global = "_craftBiometricReject";
pub const unsupported_activity = "Activity not supported";

/// A biometric rejection is a JavaScript string, including its JSON quotes.
pub fn rejectionPayload(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, message);
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the unsupported Activity rejects with the shim's message" {
    const payload = try rejectionPayload(testing.allocator, unsupported_activity);
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"Activity not supported\"", payload);
}

test "a framework error is quoted rather than interpolated into JavaScript" {
    const payload = try rejectionPayload(testing.allocator, "Sensor's \"busy\"\nretry");
    defer testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("Sensor's \"busy\"\nretry", parsed.value.string);
}

test "the action and globals match the injected promise" {
    try testing.expectEqualStrings("authenticate", A.authenticate);
    try testing.expectEqualStrings("_craftBiometricResolve", resolve_global);
    try testing.expectEqualStrings("_craftBiometricReject", reject_global);
}
