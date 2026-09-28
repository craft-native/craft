//! Decode WebView2's UTF-16 message with the same byte limit as the JSON
//! envelope parser. This stays platform-neutral so CI can test the boundary.

const std = @import("std");
const desktop_bridge_envelope = @import("desktop_bridge_envelope.zig");

pub fn fromUtf16(allocator: std.mem.Allocator, wide: []const u16) ![:0]u8 {
    if (wide.len > desktop_bridge_envelope.max_message_bytes) return error.MessageTooLarge;
    const utf8 = try std.unicode.utf16leToUtf8AllocZ(allocator, wide);
    errdefer allocator.free(utf8);
    if (utf8.len > desktop_bridge_envelope.max_message_bytes) return error.MessageTooLarge;
    return utf8;
}

test "converts WebView2 JSON with non-ASCII window names" {
    const message = try fromUtf16(std.testing.allocator, &.{ '{', '"', 'a', '"', ':', '"', 0x00E9, '"', '}' });
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("{\"a\":\"é\"}", message);
}

test "rejects an oversized UTF-16 message before decoding" {
    const wide = try std.testing.allocator.alloc(u16, desktop_bridge_envelope.max_message_bytes + 1);
    defer std.testing.allocator.free(wide);
    try std.testing.expectError(error.MessageTooLarge, fromUtf16(std.testing.allocator, wide));
}
