const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const capabilities = @import("capabilities.zig");

/// The action names this bridge dispatches on.
///
/// Declared once, here, and referenced by both the dispatch chain below and the
/// capability table beside it — so the two cannot disagree. That is enforced:
/// `test/capabilities_test.zig` fails if a declared bridge compares `action`
/// against a bare string literal anywhere, which makes it impossible to add an
/// action without also declaring it.
pub const A = struct {
    pub const get_displays = "getDisplays";
    pub const get_primary = "getPrimary";
};

/// What craft serves on the `screen` namespace.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.get_displays, .reply = .result },
    .{ .name = A.get_primary, .reply = .result },
};

const BridgeError = bridge_error.BridgeError;

/// Screen / Display info bridge.
///
/// macOS implementation reads `[NSScreen screens]` (every connected
/// display) and `[NSScreen mainScreen]` (the one with the menu bar).
/// Also subscribes to `NSApplicationDidChangeScreenParametersNotification`
/// (fired on monitor hot-plug, resolution changes, dock relocations) and
/// re-emits as a `craft:screen:change` event so apps can re-layout.
///
/// Linux/Windows implementations land later — for now those return
/// empty `{displays:[]}` so JS callers can feature-detect cleanly.
pub const ScreenBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        installScreenChangeObserver();
        return .{ .allocator = allocator };
    }

    pub fn handleMessage(self: *Self, action: []const u8, _: []const u8) !void {
        if (std.mem.eql(u8, action, A.get_displays)) {
            try self.getDisplays();
        } else if (std.mem.eql(u8, action, A.get_primary)) {
            try self.getPrimary();
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn getDisplays(self: *Self) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getDisplays", "{\"displays\":[]}");
            return;
        }
        const macos = @import("macos.zig");
        const NSScreen = macos.getClass("NSScreen");
        const screens = macos.msgSend0(NSScreen, "screens");
        if (@intFromPtr(screens) == 0) {
            bridge_error.sendResultToJS(self.allocator, "getDisplays", "{\"displays\":[]}");
            return;
        }

        const getCount = @as(
            *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) c_ulong,
            @ptrCast(&macos.objc.objc_msgSend),
        );
        const count = getCount(screens, macos.sel("count"));

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"displays\":[");

        var i: c_ulong = 0;
        while (i < count) : (i += 1) {
            if (i > 0) try buf.append(self.allocator, ',');
            const screen = macos.msgSend1(screens, "objectAtIndex:", i);
            try appendScreenJson(&buf, self.allocator, screen, i);
        }
        try buf.appendSlice(self.allocator, "]}");

        const json = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, "getDisplays", json);
    }

    fn getPrimary(self: *Self) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getPrimary", "{}");
            return;
        }
        const macos = @import("macos.zig");
        const NSScreen = macos.getClass("NSScreen");
        const screen = macos.msgSend0(NSScreen, "mainScreen");
        if (@intFromPtr(screen) == 0) {
            bridge_error.sendResultToJS(self.allocator, "getPrimary", "{}");
            return;
        }
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try appendScreenJson(&buf, self.allocator, screen, 0);
        const json = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, "getPrimary", json);
    }
};

// =============================================================================
// NSApplicationDidChangeScreenParameters observer
// =============================================================================

var screen_observer_installed = false;
var screen_observer_instance: @import("macos.zig").objc.id = null;

/// The permit to dispatch `craft:screen:change`, taken out when the observer is
/// actually installed.
///
/// Null until then, and that is the point: `craft.capabilities()` reports this
/// channel live only because this line ran, not because a table said so. On a
/// build where the observer never installs — a non-macOS target, or a failed
/// class registration below — the page is told the channel is dead instead of
/// subscribing to something that will never fire.
var screen_change_emitter: ?capabilities.Emitter = null;

fn installScreenChangeObserver() void {
    if (screen_observer_installed) return;
    if (builtin.os.tag != .macos) return;
    const macos = @import("macos.zig");
    const objc = macos.objc;

    const NSObject = macos.getClass("NSObject");
    const class_name = "CraftScreenObserver";
    var cls = objc.objc_getClass(class_name);
    if (cls == null) {
        cls = objc.objc_allocateClassPair(NSObject, class_name, 0);
        if (cls == null) return;
        const imp: objc.IMP = @ptrCast(@constCast(&handleScreenChange));
        _ = objc.class_addMethod(cls, macos.sel("onScreenChange:"), imp, "v@:@");
        objc.objc_registerClassPair(cls);
    }
    screen_observer_instance = macos.msgSend0(macos.msgSend0(cls, "alloc"), "init");

    const NSNotificationCenter = macos.getClass("NSNotificationCenter");
    const center = macos.msgSend0(NSNotificationCenter, "defaultCenter");
    const note_name = macos.createNSString("NSApplicationDidChangeScreenParametersNotification");

    // -[NSNotificationCenter addObserver:selector:name:object:]
    const Fn = *const fn (objc.id, objc.SEL, objc.id, objc.SEL, objc.id, objc.id) callconv(.c) void;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    f(center, macos.sel("addObserver:selector:name:object:"), screen_observer_instance, macos.sel("onScreenChange:"), note_name, @as(objc.id, null));

    screen_observer_installed = true;
    screen_change_emitter = capabilities.registerEmitter(.screen_change);
}

export fn handleScreenChange(_: @import("macos.zig").objc.id, _: @import("macos.zig").objc.SEL, _: @import("macos.zig").objc.id) callconv(.c) void {
    const macos = @import("macos.zig");
    const webview = macos.getGlobalWebView() orelse return;
    // Named through the emitter rather than spelled again here, so the string
    // the page listens for and the string capabilities reports are one string.
    _ = screen_change_emitter orelse return;
    const script = "if (window.dispatchEvent) window.dispatchEvent(new CustomEvent('craft:screen:change'));";
    const NSString = macos.getClass("NSString");
    const js = macos.msgSend1(NSString, "stringWithUTF8String:", @as([*:0]const u8, script));
    _ = macos.msgSend2(webview, "evaluateJavaScript:completionHandler:", js, @as(?*anyopaque, null));
}

fn appendScreenJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, screen: @import("macos.zig").objc.id, idx: c_ulong) !void {
    const macos = @import("macos.zig");
    // frame is the full screen (origin at bottom-left in AppKit coords).
    // visibleFrame excludes menu bar + dock — usually what apps want.
    const frame = macos.msgSendRect(screen, "frame");
    const visible = macos.msgSendRect(screen, "visibleFrame");
    const scale = macos.msgSendFloat(screen, "backingScaleFactor");

    var num_buf: [256]u8 = undefined;
    const written = try std.fmt.bufPrint(&num_buf, "{{\"id\":{d},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}," ++
        "\"workX\":{d},\"workY\":{d},\"workWidth\":{d},\"workHeight\":{d}," ++
        "\"scaleFactor\":{d}}}", .{
        idx,
        frame.origin.x,
        frame.origin.y,
        frame.size.width,
        frame.size.height,
        visible.origin.x,
        visible.origin.y,
        visible.size.width,
        visible.size.height,
        scale,
    });
    try buf.appendSlice(allocator, written);
}
