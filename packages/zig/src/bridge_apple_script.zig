const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const json = @import("apple_script_json.zig");

const BridgeError = bridge_error.BridgeError;

/// Compile and execute AppleScript via `NSAppleScript`. Apps use this
/// for system-automation flows: telling Mail to compose a message,
/// asking Music to play a track, etc.
///
/// `executeAndReturnError:` returns an `NSAppleEventDescriptor`; we
/// surface its `stringValue` as the result. When the call fails, its
/// error dictionary is threaded through as `error: { code, message }`
/// (`NSAppleScriptErrorNumber` and `NSAppleScriptErrorMessage`), so a
/// caller can tell a refused Automation permission (-1743) or a missing
/// Accessibility grant (-25211) from a syntax error (-2741) or a script
/// the user cancelled (-128). `ok` is unchanged.
pub const AppleScriptBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "execute")) try self.execute(data) else return BridgeError.UnknownAction;
    }

    fn execute(self: *Self, data: []const u8) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "execute", "{\"ok\":false,\"reason\":\"not supported\"}");
            return;
        }
        const ParseShape = struct { source: []const u8 = "" };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        if (parsed.value.source.len == 0) return BridgeError.MissingData;

        const reply = try run(self.allocator, parsed.value.source);
        defer self.allocator.free(reply);
        bridge_error.sendResultToJS(self.allocator, "execute", reply);
    }
};

/// Compile and run `source`, and return the JSON reply the page receives. The caller frees it. Kept apart
/// from the handler so it can be exercised without a webview.
pub fn run(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const macos = @import("macos.zig");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    const NSAppleScript = macos.getClass("NSAppleScript");
    if (@intFromPtr(NSAppleScript) == 0) {
        try buf.appendSlice(allocator, "{\"ok\":false,\"reason\":\"NSAppleScript unavailable\"}");
        return buf.toOwnedSlice(allocator);
    }

    const source_ns = macos.createNSString(source);
    const script = macos.msgSend1(macos.msgSend0(NSAppleScript, "alloc"), "initWithSource:", source_ns);
    // `alloc` returns an owned object; the source string above is autoreleased.
    defer macos.msgSendVoid0(script, "release");

    var error_info: macos.objc.id = null;
    const Fn = *const fn (macos.objc.id, macos.objc.SEL, *macos.objc.id) callconv(.c) macos.objc.id;
    const f: Fn = @ptrCast(&macos.objc.objc_msgSend);
    const result = f(script, macos.sel("executeAndReturnError:"), &error_info);

    if (@intFromPtr(result) == 0) {
        var code: ?i64 = null;
        var message: ?[]const u8 = null;
        if (@intFromPtr(error_info) != 0) {
            const number = macos.msgSend1(error_info, "objectForKey:", macos.createNSString("NSAppleScriptErrorNumber"));
            if (@intFromPtr(number) != 0) code = longValue(number);
            message = nsStringBytes(macos.msgSend1(error_info, "objectForKey:", macos.createNSString("NSAppleScriptErrorMessage")));
        }
        try json.appendFailure(allocator, &buf, code, message);
    } else {
        try json.appendSuccess(allocator, &buf, nsStringBytes(macos.msgSend0(result, "stringValue")) orelse "");
    }
    return buf.toOwnedSlice(allocator);
}

/// The UTF-8 bytes of an NSString, valid while the string is alive. Null for nil.
fn nsStringBytes(ns_string: @import("macos.zig").objc.id) ?[]const u8 {
    if (@intFromPtr(ns_string) == 0) return null;
    const macos = @import("macos.zig");
    const utf8 = macos.msgSend0(ns_string, "UTF8String");
    if (@intFromPtr(utf8) == 0) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
}

fn longValue(number: @import("macos.zig").objc.id) i64 {
    const macos = @import("macos.zig");
    const Fn = *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) c_long;
    const f: Fn = @ptrCast(&macos.objc.objc_msgSend);
    return f(number, macos.sel("longValue"));
}
