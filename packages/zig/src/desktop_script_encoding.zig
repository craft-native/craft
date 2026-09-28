//! UTF-16 storage for WebView2 document-start scripts.
//!
//! The embedded Craft bridge is larger than the old 16 KiB stack buffer.
//! Keep the backing allocation alive until WebView2 confirms installation,
//! and preserve its original length so the allocator can free it correctly.

const std = @import("std");

pub const WideScript = struct {
    storage: []u16,
    length: usize,

    pub fn ptr(self: *const WideScript) [*:0]const u16 {
        return @ptrCast(self.storage.ptr);
    }

    pub fn deinit(self: *WideScript, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
    }
};

pub fn encode(allocator: std.mem.Allocator, source: []const u8) !WideScript {
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidScript;
    // Each UTF-16 code unit needs at least one UTF-8 byte, so source.len is
    // a safe upper bound for code units, plus the terminating zero.
    const storage = try allocator.alloc(u16, source.len + 1);
    errdefer allocator.free(storage);
    const length = try std.unicode.utf8ToUtf16Le(storage[0..source.len], source);
    storage[length] = 0;
    return .{ .storage = storage, .length = length };
}

test "a document-start script larger than the former stack limit is retained" {
    const allocator = std.testing.allocator;
    const script = try allocator.alloc(u8, 20_000);
    defer allocator.free(script);
    @memset(script, 'a');

    var wide = try encode(allocator, script);
    defer wide.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 20_000), wide.length);
    try std.testing.expectEqual(@as(u16, 0), wide.ptr()[wide.length]);
    try std.testing.expectEqual(@as(u16, 'a'), wide.ptr()[19_999]);
}

test "UTF-8 characters count UTF-16 code units rather than bytes" {
    var wide = try encode(std.testing.allocator, "Aé😀");
    defer wide.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), wide.length);
    try std.testing.expectEqual(@as(u16, 0), wide.ptr()[4]);
}

test "an embedded NUL cannot silently truncate the installed script" {
    try std.testing.expectError(error.InvalidScript, encode(std.testing.allocator, "one\x00two"));
}
