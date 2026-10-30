//! The JSON the AppleScript bridge answers with. Nothing here touches the platform, so a
//! script's output, which can hold any byte a window title or document can, is escaped and
//! tested without a webview. The bridge itself is in `bridge_apple_script.zig`.

const std = @import("std");

/// Append `bytes` as the inside of a JSON string. Quotes, backslashes and every control
/// character are escaped: a bare control byte (a window title can hold one) is not valid
/// JSON and would make the page's parser reject the whole reply. UTF-8 passes through.
pub fn appendEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), bytes: []const u8) !void {
    for (bytes) |byte| {
        switch (byte) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0c => try buf.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => {
                var escape: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&escape, "\\u{x:0>4}", .{byte}) catch unreachable;
                try buf.appendSlice(allocator, &escape);
            },
            else => try buf.append(allocator, byte),
        }
    }
}

/// `{"ok":true,"result":"..."}`
pub fn appendSuccess(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), result: []const u8) !void {
    try buf.appendSlice(allocator, "{\"ok\":true,\"result\":\"");
    try appendEscaped(allocator, buf, result);
    try buf.appendSlice(allocator, "\"}");
}

/// `{"ok":false}` when the failure carries no detail, otherwise
/// `{"ok":false,"error":{"code":-1743,"message":"..."}}`. `ok` stays first and unchanged, so
/// callers written against the old reply keep working.
pub fn appendFailure(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), code: ?i64, message: ?[]const u8) !void {
    if (code == null and message == null) {
        try buf.appendSlice(allocator, "{\"ok\":false}");
        return;
    }
    try buf.appendSlice(allocator, "{\"ok\":false,\"error\":{");
    if (code) |value| {
        var number: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&number, "\"code\":{d}", .{value}) catch unreachable;
        try buf.appendSlice(allocator, text);
        if (message != null) try buf.append(allocator, ',');
    }
    if (message) |text| {
        try buf.appendSlice(allocator, "\"message\":\"");
        try appendEscaped(allocator, buf, text);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, "}}");
}

fn build(comptime function: anytype, args: anytype) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(std.testing.allocator);
    try @call(.auto, function, .{ std.testing.allocator, &buf } ++ args);
    return buf.toOwnedSlice(std.testing.allocator);
}

fn expectParsesTo(json: []const u8, comptime check: fn (std.json.Value) anyerror!void) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try check(parsed.value);
}

test "quotes, backslashes and the usual escapes round-trip through a JSON parser" {
    const json = try build(appendSuccess, .{"say \"hi\"\\\n\r\t end"});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"ok\":true,\"result\":\"say \\\"hi\\\"\\\\\\n\\r\\t end\"}", json);
    try expectParsesTo(json, struct {
        fn check(value: std.json.Value) !void {
            try std.testing.expectEqualStrings("say \"hi\"\\\n\r\t end", value.object.get("result").?.string);
        }
    }.check);
}

test "every control character is escaped, so the reply is always valid JSON" {
    var every: [34]u8 = undefined;
    for (0..32) |i| every[i] = @intCast(i);
    every[32] = 0x7f;
    every[33] = 'x';
    const json = try build(appendSuccess, .{every[0..]});
    defer std.testing.allocator.free(json);
    for (json) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    try expectParsesTo(json, struct {
        fn check(value: std.json.Value) !void {
            const result = value.object.get("result").?.string;
            try std.testing.expectEqual(@as(usize, 34), result.len);
            for (0..32) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), result[i]);
            try std.testing.expectEqual(@as(u8, 0x7f), result[32]);
        }
    }.check);
}

test "UTF-8 passes through untouched" {
    const json = try build(appendSuccess, .{"Résumé 日本語 🚀"});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"ok\":true,\"result\":\"Résumé 日本語 🚀\"}", json);
}

test "a failure without detail is the original reply" {
    const json = try build(appendFailure, .{ @as(?i64, null), @as(?[]const u8, null) });
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"ok\":false}", json);
}

test "a failure carries the error number and message" {
    const json = try build(appendFailure, .{ @as(?i64, -1743), @as(?[]const u8, "Not authorized to send Apple events to \"Contacts\".") });
    defer std.testing.allocator.free(json);
    try expectParsesTo(json, struct {
        fn check(value: std.json.Value) !void {
            try std.testing.expect(!value.object.get("ok").?.bool);
            const failure = value.object.get("error").?.object;
            try std.testing.expectEqual(@as(i64, -1743), failure.get("code").?.integer);
            try std.testing.expectEqualStrings("Not authorized to send Apple events to \"Contacts\".", failure.get("message").?.string);
        }
    }.check);
}

test "a failure with only one of the two fields stays valid" {
    const code_only = try build(appendFailure, .{ @as(?i64, -128), @as(?[]const u8, null) });
    defer std.testing.allocator.free(code_only);
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":{\"code\":-128}}", code_only);
    const message_only = try build(appendFailure, .{ @as(?i64, null), @as(?[]const u8, "boom") });
    defer std.testing.allocator.free(message_only);
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":{\"message\":\"boom\"}}", message_only);
}
