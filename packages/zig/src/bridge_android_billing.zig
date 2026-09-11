//! Android product lookup and purchase restoration.
//!
//! Play Billing's client, builders and asynchronous listeners are Java
//! objects and stay in `CraftNative`. Both actions enter Zig and every
//! observable completion returns here. The holder intentionally keeps one
//! shared client: calling restore before products still does nothing and
//! leaves the promise pending, exactly as the shim's null-safe call does.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const get_products = "getProducts";
    pub const restore_purchases = "restorePurchases";
};

pub const products_resolve_global = "_craftProductsResolve";
pub const products_reject_global = "_craftProductsReject";
pub const restore_resolve_global = "_craftRestoreResolve";
pub const restore_reject_global = "_craftRestoreReject";

pub fn errorPayload(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, message);
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "billing errors remain one JavaScript string" {
    const payload = try errorPayload(testing.allocator, "Billing's \"offline\"");
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"Billing's \\\"offline\\\"\"", payload);
}

test "the actions and globals match the injected promises" {
    try testing.expectEqualStrings("getProducts", A.get_products);
    try testing.expectEqualStrings("restorePurchases", A.restore_purchases);
    try testing.expectEqualStrings("_craftProductsResolve", products_resolve_global);
    try testing.expectEqualStrings("_craftProductsReject", products_reject_global);
    try testing.expectEqualStrings("_craftRestoreResolve", restore_resolve_global);
    try testing.expectEqualStrings("_craftRestoreReject", restore_reject_global);
}
