//! Parse and authenticate the proposed parent/modal relationship before any
//! platform creates or reopens a native window. Native attachment is added
//! separately; until then callers must reject a requested parent explicitly.
const std = @import("std");
const window_registry = @import("window_registry.zig");

pub const Options = window_registry.Relationship;

pub fn parse(
    allocator: std.mem.Allocator,
    json: []const u8,
    sender_window: window_registry.Handle,
    sender_webview: window_registry.Handle,
) !Options {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err|
        return if (err == error.OutOfMemory) err else error.InvalidJSON;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJSON;

    const values = parsed.value.object;
    const modal = if (values.get("modal")) |value| switch (value) {
        .bool => |flag| flag,
        .null => false,
        else => return error.InvalidParameter,
    } else false;
    const always_on_top = if (values.get("alwaysOnTop")) |value| switch (value) {
        .bool => |flag| flag,
        else => false,
    } else false;
    if (modal and always_on_top) return error.InvalidParameter;

    const parent_name = if (values.get("parent")) |value| switch (value) {
        .string => |name| name,
        .null => null,
        else => return error.InvalidParameter,
    } else null;
    const name = parent_name orelse {
        if (modal) return error.InvalidParameter;
        return .{};
    };
    if (name.len == 0 or name.len > window_registry.max_name or
        std.mem.indexOfScalar(u8, name, 0) != null)
        return error.InvalidParameter;

    const parent = if (std.mem.eql(u8, name, "main")) blk: {
        if (!window_registry.isKnown(sender_window)) return error.InvalidParameter;
        break :blk sender_window;
    } else blk: {
        const handle = window_registry.byName(name) orelse return error.InvalidParameter;
        if (sender_webview == 0 or window_registry.ownerWebViewOf(handle) != sender_webview)
            return error.InvalidParameter;
        break :blk handle;
    };
    return .{ .parent = parent, .modal = modal };
}

const testing = std.testing;

test "parent options authenticate main and named parents" {
    window_registry.resetForTesting();
    defer window_registry.resetForTesting();
    try testing.expect(window_registry.rememberNamedOwned(0x1000, "settings", 0x9000));
    try testing.expect(window_registry.rememberNamedOwned(0x2000, "other", 0xA000));
    try testing.expectEqual(@as(?usize, 0x1000), (try parse(testing.allocator, "{\"parent\":\"main\",\"modal\":true}", 0x1000, 0x9000)).parent);
    try testing.expectEqual(@as(?usize, 0x1000), (try parse(testing.allocator, "{\"parent\": \"settings\"}", 0x2000, 0x9000)).parent);
    try testing.expectError(error.InvalidParameter, parse(testing.allocator, "{\"parent\":\"settings\"}", 0x2000, 0xA000));
    try testing.expectError(error.InvalidParameter, parse(testing.allocator, "{\"parent\":\"missing\"}", 0x1000, 0x9000));
}

test "modal relationship rejects missing parent and global topmost" {
    window_registry.resetForTesting();
    defer window_registry.resetForTesting();
    try testing.expect(window_registry.remember(0x1000));
    try testing.expectError(error.InvalidParameter, parse(testing.allocator, "{\"modal\":true}", 0x1000, 0x9000));
    try testing.expectError(error.InvalidParameter, parse(testing.allocator, "{\"parent\":\"main\",\"modal\":true,\"alwaysOnTop\":true}", 0x1000, 0x9000));
    try testing.expectError(error.InvalidParameter, parse(testing.allocator, "{\"parent\":7}", 0x1000, 0x9000));
    try testing.expectError(error.InvalidParameter, parse(testing.allocator, "{\"parent\":\"\"}", 0x1000, 0x9000));
    try testing.expectError(error.InvalidParameter, parse(testing.allocator, "{\"modal\":\"true\"}", 0x1000, 0x9000));
    try testing.expectError(error.InvalidJSON, parse(testing.allocator, "{", 0x1000, 0x9000));
}
