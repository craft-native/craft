//! The JSON envelope posted by the injected desktop page bridge.
//!
//! The page supplies `t`, `a`, `d` and a correlation id, never a native
//! window pointer. The platform callback supplies the actual sender handles.

const std = @import("std");
const request_context = @import("request_context.zig");

pub const max_message_bytes = 1024 * 1024;

pub const Envelope = struct {
    parsed: std.json.Parsed(std.json.Value),
    kind: []const u8,
    action: []const u8,
    data: ?[]const u8,
    request_id: ?u64,

    pub fn deinit(self: *Envelope) void {
        self.parsed.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Envelope {
    if (source.len > max_message_bytes) return error.MessageTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidBridgeMessage;

    const root = parsed.value.object;
    const kind_value = root.get("t") orelse return error.InvalidBridgeMessage;
    const action_value = root.get("a") orelse return error.InvalidBridgeMessage;
    if (kind_value != .string or action_value != .string) return error.InvalidBridgeMessage;
    if (kind_value.string.len == 0 or action_value.string.len == 0) return error.InvalidBridgeMessage;

    const data_value = root.get("d");
    const data: ?[]const u8 = if (data_value) |value| switch (value) {
        .string => |text| if (text.len == 0) null else text,
        .null => null,
        else => return error.InvalidBridgeMessage,
    } else null;

    return .{
        .parsed = parsed,
        .kind = kind_value.string,
        .action = action_value.string,
        .data = data,
        .request_id = request_context.fromEnvelope(root),
    };
}

test "reads a correlated window request without trusting a sender field" {
    var envelope = try parse(std.testing.allocator,
        \\{"t":"window","a":"open","d":"{\"name\":\"settings\"}","i":41,"window":1234}
    );
    defer envelope.deinit();
    try std.testing.expectEqualStrings("window", envelope.kind);
    try std.testing.expectEqualStrings("open", envelope.action);
    try std.testing.expectEqualStrings("{\"name\":\"settings\"}", envelope.data.?);
    try std.testing.expectEqual(@as(?u64, 41), envelope.request_id);
}

test "rejects malformed and oversize messages" {
    try std.testing.expectError(error.InvalidBridgeMessage, parse(std.testing.allocator, "[]"));
    try std.testing.expectError(error.InvalidBridgeMessage, parse(std.testing.allocator, "{\"t\":\"window\"}"));
    try std.testing.expectError(error.InvalidBridgeMessage, parse(std.testing.allocator, "{\"t\":\"window\",\"a\":\"open\",\"d\":{}}"));
    try std.testing.expectError(error.InvalidBridgeMessage, parse(std.testing.allocator, "{\"t\":\"window\",\"a\":\"\"}"));
    const large = try std.testing.allocator.alloc(u8, max_message_bytes + 1);
    defer std.testing.allocator.free(large);
    try std.testing.expectError(error.MessageTooLarge, parse(std.testing.allocator, large));
}

test "an id-less fire-and-forget action does not inherit a pending reply" {
    var envelope = try parse(std.testing.allocator, "{\"t\":\"window\",\"a\":\"close\",\"d\":\"\"}");
    defer envelope.deinit();
    try std.testing.expect(envelope.data == null);
    try std.testing.expect(envelope.request_id == null);
}
