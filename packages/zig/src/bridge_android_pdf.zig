//! Android's external PDF viewer action.
//!
//! The holder keeps the main-thread Intent and temporary Java `File` work.
//! Zig owns the action and both promise outcomes. The `page` argument remains
//! accepted and ignored: Android opens an external viewer and the existing
//! shim never attempted to position that viewer.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const open_pdf = "openPDF";
};

pub const resolve_global = "_craftPDFResolve";
pub const reject_global = "_craftPDFReject";
pub const opened_payload = "{\"opened\":true}";

pub fn errorPayload(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, message);
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "open success keeps the shim's object payload" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, opened_payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("opened").?.bool);
}

test "viewer errors remain one JavaScript string" {
    const payload = try errorPayload(testing.allocator, "Viewer's \"missing\"");
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"Viewer's \\\"missing\\\"\"", payload);
}

test "the action and globals match the injected promise" {
    try testing.expectEqualStrings("openPDF", A.open_pdf);
    try testing.expectEqualStrings("_craftPDFResolve", resolve_global);
    try testing.expectEqualStrings("_craftPDFReject", reject_global);
}
