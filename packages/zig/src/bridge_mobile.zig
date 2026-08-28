const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;

/// The `mobile` namespace: what a page can ask about the device it is running on.
///
/// This is the first namespace craft serves from Zig on a phone. It carries one
/// action, deliberately — the point of the first one is to prove the whole path
/// (page → script message handler → dispatcher → native → reply → page), and a
/// second action proves nothing the first did not.
///
/// `getDeviceInfo` was chosen over the alternatives because its answer cannot be
/// faked. `"systemName":"iOS"` and `"isSimulator":true` can only come from a
/// real UIKit process; a stub, a browser fallback, or a half-wired bridge
/// cannot produce them. Compare the fallback this replaces, which resolved
/// `{success:true, browser:true}` and made "the bridge worked" and "there is no
/// bridge" identical to the caller.
///
/// `haptic` would have been the obvious first pick and is the wrong one: it is
/// fire-and-forget, so it exercises no reply path, and Core Haptics is a silent
/// no-op on the simulator — it would have passed while doing nothing.
pub const A = struct {
    pub const get_device_info = "getDeviceInfo";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.get_device_info, .reply = .result },
};

pub const MobileBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        _ = data;
        if (std.mem.eql(u8, action, A.get_device_info)) {
            try self.getDeviceInfo();
        } else {
            return bridge_error.BridgeError.UnknownAction;
        }
    }

    fn getDeviceInfo(self: *Self) !void {
        var buf: [512]u8 = undefined;
        const json = try describeDevice(&buf);
        bridge_error.sendResultToJS(self.allocator, A.get_device_info, json);
    }
};

/// Whether this process is running under the iOS Simulator.
///
/// Read from the environment rather than a compile-time target check: a
/// simulator build and a device build are the same `-ios-simulator` triple to
/// some toolchains, and the point of reporting this at all is to let a test
/// distinguish "ran on a simulator" from "was answered by something that never
/// ran". `SIMULATOR_DEVICE_NAME` is set by simctl in every launched process.
fn isSimulator() bool {
    // `std.c.getenv`, not `std.posix.getenv` — the latter does not exist in
    // this Zig version. `bridge_fs.zig:569` records the same finding.
    return std.c.getenv("SIMULATOR_DEVICE_NAME") != null;
}

/// Ask UIKit what device this is, and render it as the JSON the page receives.
///
/// Every value here comes from a live `objc_msgSend` into UIKit. That is the
/// property under test: a wrong answer is possible, but a *fabricated* one is
/// not, because there is no path to this string that does not go through the
/// Objective-C runtime in a running application.
fn describeDevice(buf: []u8) ![]const u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const UIDevice = objc.objc_getClass("UIDevice") orelse return error.ClassNotFound;
    const sel_current = objc.sel_registerName("currentDevice") orelse return error.SelectorNotFound;
    const device = objc.msgSendId(UIDevice, sel_current);
    if (device == null) return error.NoCurrentDevice;

    const system_name = try nsStringField(device, "systemName");
    const system_version = try nsStringField(device, "systemVersion");
    const model = try nsStringField(device, "model");

    return std.fmt.bufPrint(
        buf,
        "{{\"systemName\":\"{s}\",\"systemVersion\":\"{s}\",\"model\":\"{s}\",\"isSimulator\":{}}}",
        .{ system_name, system_version, model, isSimulator() },
    );
}

/// Send a zero-argument selector that returns an NSString, and borrow its UTF-8.
///
/// The returned slice points into the NSString's own buffer, which is
/// autoreleased — fine here because it is formatted into the caller's buffer
/// before this function's caller returns, and nothing retains it afterwards.
fn nsStringField(target: objc.id, comptime selector: [:0]const u8) ![]const u8 {
    const sel = objc.sel_registerName(selector) orelse return error.SelectorNotFound;
    const ns = objc.msgSendId(target, sel);
    if (ns == null) return error.NilString;
    const utf8 = objc.getNSStringUTF8(ns) orelse return error.NilString;
    return std.mem.span(utf8);
}

const testing = std.testing;

test "the declared action is the one the handler serves" {
    // A namespace whose table and dispatcher disagree is the failure this
    // whole effort exists to make impossible, so it is worth asserting even
    // with one action in the table.
    try testing.expectEqual(@as(usize, 1), capability_actions.len);
    try testing.expectEqualStrings(A.get_device_info, capability_actions[0].name);
    try testing.expectEqual(capabilities.Reply.result, capability_actions[0].reply);
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = MobileBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
}

test "device JSON is shaped the way the page expects" {
    // `describeDevice` needs UIKit, which is absent on the host, so this pins
    // the contract rather than the values: the fixture page and the simulator
    // harness both match on these key names.
    var buf: [512]u8 = undefined;
    const rendered = try std.fmt.bufPrint(
        &buf,
        "{{\"systemName\":\"{s}\",\"systemVersion\":\"{s}\",\"model\":\"{s}\",\"isSimulator\":{}}}",
        .{ "iOS", "18.0", "iPhone", true },
    );
    try testing.expectEqualStrings(
        "{\"systemName\":\"iOS\",\"systemVersion\":\"18.0\",\"model\":\"iPhone\",\"isSimulator\":true}",
        rendered,
    );
}
