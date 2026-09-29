const std = @import("std");

// The CLI owns this string until the app exits. Window creation installs a
// document-start script after the normal bridge and before its first load.
var initial_url: ?[]const u8 = null;

pub fn setInitial(url: ?[]const u8) void {
    initial_url = url;
}

pub fn initialScript(allocator: std.mem.Allocator) !?[]u8 {
    const url = initial_url orelse return null;
    const literal = try std.json.Stringify.valueAlloc(allocator, url, .{});
    defer allocator.free(literal);
    return try std.fmt.allocPrint(allocator, "window.__craftPendingDeepLink = {s};", .{literal});
}

test "initial deep link is escaped for document-start JavaScript" {
    setInitial("myapp://open/\";window.pwned=true;//");
    defer setInitial(null);
    const script = (try initialScript(std.testing.allocator)).?;
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("window.__craftPendingDeepLink = \"myapp://open/\\\";window.pwned=true;//\";", script);
}
