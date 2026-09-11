//! Android screenshot replies.
//!
//! View drawing-cache and Bitmap work stays in the Kotlin holder because it
//! must run on Android's main looper and operates entirely on Java objects.
//! The action and its observable values live here: Zig turns the captured PNG
//! bytes into the exact no-wrap data URL and quotes Java exception messages.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const take_screenshot = "takeScreenshot";
};

pub const resolve_global = "_craftScreenshotResolve";
pub const reject_global = "_craftScreenshotReject";

pub fn errorPayload(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, message);
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

pub fn imagePayload(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const prefix = "data:image/png;base64,";
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, prefix.len + encoded_len + 2);
    errdefer allocator.free(out);
    out[0] = '"';
    @memcpy(out[1 .. 1 + prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out[1 + prefix.len .. out.len - 1], bytes);
    out[out.len - 1] = '"';
    return out;
}

const testing = std.testing;

test "PNG bytes become the shim's no-wrap data URL" {
    const payload = try imagePayload(testing.allocator, "png");
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"data:image/png;base64,cG5n\"", payload);
}

test "errors remain one JavaScript string" {
    const payload = try errorPayload(testing.allocator, "View's \"gone\"");
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"View's \\\"gone\\\"\"", payload);
}

test "the action and globals match the injected promise" {
    try testing.expectEqualStrings("takeScreenshot", A.take_screenshot);
    try testing.expectEqualStrings("_craftScreenshotResolve", resolve_global);
    try testing.expectEqualStrings("_craftScreenshotReject", reject_global);
}
