//! Android's in-app review request.
//!
//! Play Core owns the `Task` objects and their Java listeners, so those
//! objects stay in `CraftNative`. Zig starts the flow and owns both page
//! outcomes. This is the same boundary as biometric authentication: Kotlin
//! supplies objects JNI cannot implement, while the action and promise
//! semantics live here.
//!
//! A completed launch resolves even if Google Play chose not to show a card.
//! That is Play Review's contract and the existing shim's behavior. Only the
//! initial `requestReviewFlow` task can reject the promise.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const request_review = "requestReview";
};

pub const resolve_global = "_craftReviewResolve";
pub const reject_global = "_craftReviewReject";
pub const failed_fallback = "Review flow failed";

/// Ask the fixed-package holder to construct Play Core's listener objects and
/// start the request. Both listeners call registered natives back in Zig.
pub fn request(j: Jni, activity: jobject) !void {
    const holder = try j.findClass("com/craft/runtime/CraftNative");
    try j.callStaticVoidMethodA(
        holder,
        try j.staticMethodId(
            holder,
            "startReviewFlow",
            "(Landroid/app/Activity;)V",
        ),
        &.{.{ .l = activity }},
    );
}

/// A review failure as a JavaScript string, including its JSON quotes.
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

test "the action and globals match the injected promise" {
    try testing.expectEqualStrings("requestReview", A.request_review);
    try testing.expectEqualStrings("_craftReviewResolve", resolve_global);
    try testing.expectEqualStrings("_craftReviewReject", reject_global);
}

test "an absent Play error keeps the shim's fallback" {
    const payload = try rejectionPayload(testing.allocator, failed_fallback);
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"Review flow failed\"", payload);
}

test "a Play error survives as one JavaScript string" {
    const payload = try rejectionPayload(testing.allocator, "Play's \"busy\"\nretry");
    defer testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("Play's \"busy\"\nretry", parsed.value.string);
}
