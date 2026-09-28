//! JS delivery for a native desktop window transition. Platform code chooses
//! the actual live WebView; this module only formats the event payload.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

pub fn format(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    detail_json: []const u8,
    window_name: ?[]const u8,
) ![]u8 {
    var script: std.ArrayListUnmanaged(u8) = .empty;
    errdefer script.deinit(allocator);
    try script.appendSlice(allocator, "if(window.__craftDeliverWindowEvent)window.__craftDeliverWindowEvent(\"");
    try bridge_error.appendJsonEscaped(allocator, &script, event_name);
    try script.appendSlice(allocator, "\",");
    try script.appendSlice(allocator, if (detail_json.len == 0) "{}" else detail_json);
    if (window_name) |name| {
        try script.appendSlice(allocator, ",\"");
        try bridge_error.appendJsonEscaped(allocator, &script, name);
        try script.append(allocator, '"');
    }
    try script.appendSlice(allocator, ");");
    return script.toOwnedSlice(allocator);
}

test "a local transition addresses only the page's main handle" {
    const script = try format(std.testing.allocator, "focus", "", null);
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("if(window.__craftDeliverWindowEvent)window.__craftDeliverWindowEvent(\"focus\",{});", script);
}

test "a creator receives the named child event with escaped id" {
    const script = try format(std.testing.allocator, "resize", "{\"width\":640}", "set\"tings");
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("if(window.__craftDeliverWindowEvent)window.__craftDeliverWindowEvent(\"resize\",{\"width\":640},\"set\\\"tings\");", script);
}
