const std = @import("std");

// The CLI owns this string until the app exits. Window creation installs a
// document-start script after the normal bridge and before its first load.
var initial_url: ?[]const u8 = null;
var page_url: ?[]const u8 = null;

pub fn setInitial(url: ?[]const u8) void {
    initial_url = url;
}

pub fn setPage(url: ?[]const u8) void {
    page_url = url;
}

// `--single-instance <id>`: the name every launch of one app shares.
var instance_id: ?[]const u8 = null;

/// Identify this app by an explicit name instead of by executable and page.
/// A launcher that serves its page from a different local port each time
/// would otherwise never look like the same app twice.
pub fn setInstance(id: ?[]const u8) void {
    instance_id = id;
}

pub fn applicationId(allocator: std.mem.Allocator, executable: []const u8) ![:0]u8 {
    return try std.fmt.allocPrintSentinel(allocator, "com.craft.app{x}", .{applicationHash(executable)}, 0);
}

pub fn applicationHash(executable: []const u8) u64 {
    var hash = std.hash.Wyhash.init(0);
    if (instance_id) |id| {
        // Its own domain: an id can never collide with an executable path.
        hash.update("\x01instance\x00");
        hash.update(id);
        return hash.final();
    }
    hash.update(executable);
    hash.update("\x00");
    hash.update(page_url orelse "");
    return hash.final();
}

pub fn initialScript(allocator: std.mem.Allocator) !?[]u8 {
    const url = initial_url orelse return null;
    const literal = try std.json.Stringify.valueAlloc(allocator, url, .{});
    defer allocator.free(literal);
    return try std.fmt.allocPrint(allocator, "window.__craftPendingDeepLink = {s};", .{literal});
}

pub fn deliveryScript(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const literal = try std.json.Stringify.valueAlloc(allocator, url, .{});
    defer allocator.free(literal);
    return try std.fmt.allocPrint(allocator, "if (window.__craftDeliverDeepLink) window.__craftDeliverDeepLink({s});", .{literal});
}

test "initial deep link is escaped for document-start JavaScript" {
    setInitial("myapp://open/\";window.pwned=true;//");
    defer setInitial(null);
    const script = (try initialScript(std.testing.allocator)).?;
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("window.__craftPendingDeepLink = \"myapp://open/\\\";window.pwned=true;//\";", script);
}

test "desktop application IDs distinguish packaged apps and page URLs" {
    setPage("https://one.test/");
    const first = try applicationId(std.testing.allocator, "/opt/first/craft");
    defer std.testing.allocator.free(first);
    const first_again = try applicationId(std.testing.allocator, "/opt/first/craft");
    defer std.testing.allocator.free(first_again);
    try std.testing.expectEqualStrings(first, first_again);
    setPage("https://two.test/");
    const second = try applicationId(std.testing.allocator, "/opt/first/craft");
    defer std.testing.allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    setPage(null);
    const different_app = try applicationId(std.testing.allocator, "/opt/second/craft");
    defer std.testing.allocator.free(different_app);
    try std.testing.expect(!std.mem.eql(u8, first, different_app));
}

test "a single-instance id identifies the app whatever its path or page" {
    setInstance("org.example.app");
    defer setInstance(null);
    setPage("http://127.0.0.1:4100/");
    const first = applicationHash("/opt/one/craft");
    setPage("http://127.0.0.1:4200/");
    try std.testing.expectEqual(first, applicationHash("/Applications/two/craft"));
    setPage(null);
    setInstance("org.example.other");
    try std.testing.expect(first != applicationHash("/opt/one/craft"));
    setInstance(null);
    try std.testing.expect(first != applicationHash("/opt/one/craft"));
}

test "warm link script dispatches an escaped URL" {
    const script = try deliveryScript(std.testing.allocator, "myapp://open/\";window.pwned=true;//");
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("if (window.__craftDeliverDeepLink) window.__craftDeliverDeepLink(\"myapp://open/\\\";window.pwned=true;//\");", script);
}
