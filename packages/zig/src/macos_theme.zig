const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos.zig");
const capabilities = @import("capabilities.zig");

const objc = macos.objc;

// Single global observer instance — appearance is process-wide on macOS,
// so there's no reason to install per-window handlers.
var observer_instance: objc.id = null;
var installed: bool = false;

/// Install an NSAppearance KVO observer that fires `craft:theme` events
/// in JS whenever the system's effective appearance changes (light↔dark
/// switches, including the macOS "auto" mode that flips at sunset).
///
/// Idempotent. macOS-only — no-op elsewhere because GTK / Win32 use
/// totally different mechanisms (we'll add those when those backends
/// grow this surface).
pub fn install() void {
    if (installed) return;
    if (builtin.target.os.tag != .macos) return;

    const NSObject = macos.getClass("NSObject");
    const class_name = "CraftThemeObserver";

    var cls = objc.objc_getClass(class_name);
    if (cls == null) {
        cls = objc.objc_allocateClassPair(NSObject, class_name, 0);
        if (cls == null) return;

        // observeValueForKeyPath:ofObject:change:context:
        const obs_imp: objc.IMP = @ptrCast(@constCast(&observeValueForKeyPath));
        _ = objc.class_addMethod(
            cls,
            macos.sel("observeValueForKeyPath:ofObject:change:context:"),
            obs_imp,
            "v@:@@@^v",
        );

        objc.objc_registerClassPair(cls);
    }

    const instance = macos.msgSend0(macos.msgSend0(cls, "alloc"), "init");
    observer_instance = instance;

    // Watch NSApp.effectiveAppearance. Apple's recommended approach in
    // AppKit-land — KVO on the shared application's appearance keypath.
    const NSApplication = macos.getClass("NSApplication");
    const app = macos.msgSend0(NSApplication, "sharedApplication");
    if (@intFromPtr(app) != 0) {
        const key = macos.createNSString("effectiveAppearance");
        // NSKeyValueObservingOptionNew (1) | NSKeyValueObservingOptionInitial (4) = 5
        // Initial fires once immediately so the JS-side cached value is
        // populated without waiting for the user to toggle their Mac.
        const opts: c_ulong = 1 | 4;
        const Fn = *const fn (objc.id, objc.SEL, objc.id, objc.id, c_ulong, ?*anyopaque) callconv(.c) void;
        const f: Fn = @ptrCast(&objc.objc_msgSend);
        f(app, macos.sel("addObserver:forKeyPath:options:context:"), instance, key, opts, null);
    }

    installed = true;
    _ = capabilities.registerEmitter(.theme);

    if (comptime builtin.mode == .debug) {
        std.debug.print("[Theme] Installed NSAppearance observer\n", .{});
    }
}

export fn observeValueForKeyPath(
    self: objc.id,
    selector: objc.SEL,
    keyPath: objc.id,
    object: objc.id,
    change: objc.id,
    context: ?*anyopaque,
) callconv(.c) void {
    _ = self;
    _ = selector;
    _ = keyPath;
    _ = object;
    _ = change;
    _ = context;
    deliver();
}

/// Read the system's current appearance and post it to JS.
fn deliver() void {
    const NSApplication = macos.getClass("NSApplication");
    const app = macos.msgSend0(NSApplication, "sharedApplication");
    if (@intFromPtr(app) == 0) return;

    const appearance = macos.msgSend0(app, "effectiveAppearance");
    if (@intFromPtr(appearance) == 0) return;

    // bestMatchFromAppearancesWithNames: returns the matched name (or nil)
    // — we ask whether the current appearance is one of the dark variants
    // and fall back to "light" otherwise. This is the API Apple intends
    // for "are we in dark mode?" queries.
    const dark_name = macos.createNSString("NSAppearanceNameDarkAqua");
    const light_name = macos.createNSString("NSAppearanceNameAqua");

    // Build a 2-element array via arrayWithObjects:count: (variadic
    // arrayWithObjects: needs nil-terminated args, which is awkward in
    // Zig). Two-call build instead.
    var arr_items: [2]objc.id = .{ dark_name, light_name };
    const NSArray = macos.getClass("NSArray");
    const Fn = *const fn (objc.id, objc.SEL, [*]const objc.id, c_ulong) callconv(.c) objc.id;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    const names_arr = f(NSArray, macos.sel("arrayWithObjects:count:"), &arr_items, 2);

    const matched = macos.msgSend1(appearance, "bestMatchFromAppearancesWithNames:", names_arr);
    // Earlier code called `msgSendBool(matched, "isEqualToString:")` —
    // that sends the selector with NO argument, which is undefined
    // behaviour (the implementation reads garbage off the stack). Use
    // the typed helper that actually passes the comparison NSString.
    const is_dark = if (@intFromPtr(matched) != 0)
        isEqualToString(matched, "NSAppearanceNameDarkAqua")
    else
        false;

    const json = if (is_dark) "{\"appearance\":\"dark\"}" else "{\"appearance\":\"light\"}";

    var script_buf: [256]u8 = undefined;
    const script = @import("memory.zig").bufPrintZ(&script_buf, "if (window.__craftDeliverTheme) window.__craftDeliverTheme({s});", .{json}) catch return;

    if (getGlobalWebViewSafe()) |webview| {
        const NSString = macos.getClass("NSString");
        const js_str = macos.msgSend1(NSString, "stringWithUTF8String:", @as([*:0]const u8, @ptrCast(script.ptr)));
        _ = macos.msgSend2(webview, "evaluateJavaScript:completionHandler:", js_str, @as(?*anyopaque, null));
    }
}

fn isEqualToString(ns_string: objc.id, str: []const u8) bool {
    const other = macos.createNSString(str);
    const Fn = *const fn (objc.id, objc.SEL, objc.id) callconv(.c) bool;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(ns_string, macos.sel("isEqualToString:"), other);
}

fn getGlobalWebViewSafe() ?objc.id {
    return macos.getGlobalWebView();
}
