const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos.zig");
const capabilities = @import("capabilities.zig");

const objc = macos.objc;

/// Install an NSWindowDelegate that translates AppKit window-state
/// transitions into `craft:window:*` events in JS. Today we cover:
///
///   `craft:window:focus` — windowDidBecomeKey
///   `craft:window:blur`  — windowDidResignKey
///   `craft:window:resize` — windowDidResize (size only — not the live drag)
///   `craft:window:move`  — windowDidMove
///   `craft:window:close` — windowWillClose
///
/// "willClose" fires after AppKit has committed to closing the window —
/// i.e. you can't actually intercept it from here without subclassing
/// NSWindow's `-close`. That's out of scope for now; if an app needs
/// a close-confirmation dialog, install it on `beforeunload` from JS,
/// which fires before AppKit's close path runs.
///
/// macOS-only. Idempotent.
var installed: bool = false;
var delegate_instance: objc.id = null;

pub fn install(window: objc.id) void {
    if (builtin.target.os.tag != .macos) return;
    if (@intFromPtr(window) == 0) return;

    if (!installed) {
        const NSObject = macos.getClass("NSObject");
        const class_name = "CraftWindowDelegate";

        var cls = objc.objc_getClass(class_name);
        if (cls == null) {
            cls = objc.objc_allocateClassPair(NSObject, class_name, 0);
            if (cls == null) return;

            // Each delegate selector maps to a one-line emit fn below.
            addMethod(cls, "windowDidBecomeKey:", &windowDidBecomeKey);
            addMethod(cls, "windowDidResignKey:", &windowDidResignKey);
            addMethod(cls, "windowDidResize:", &windowDidResize);
            addMethod(cls, "windowDidMove:", &windowDidMove);
            addMethod(cls, "windowWillClose:", &windowWillClose);
            addMethod(cls, "windowDidMiniaturize:", &windowDidMiniaturize);
            addMethod(cls, "windowDidDeminiaturize:", &windowDidDeminiaturize);

            objc.objc_registerClassPair(cls);
        }

        delegate_instance = macos.msgSend0(macos.msgSend0(cls, "alloc"), "init");
        installed = true;
        // Five channels, one delegate. The names are composed in JS from
        // `__craftDeliverWindowEvent`, so no source scan could ever find them.
        inline for ([_]capabilities.Channel{ .window_focus, .window_blur, .window_resize, .window_move, .window_close }) |ch| {
            _ = capabilities.registerEmitter(ch);
        }

        if (comptime builtin.mode == .debug) {
            std.debug.print("[WindowEvents] Installed NSWindowDelegate\n", .{});
        }
    }

    // The delegate is process-global but the window is per-instance;
    // each call attaches the same delegate to a new window. AppKit holds
    // the delegate weakly, so the global retain we did at init is what
    // keeps it alive across windows.
    _ = macos.msgSend1(window, "setDelegate:", delegate_instance);
}

fn addMethod(cls: objc.Class, sel_name: [*:0]const u8, imp: *const anyopaque) void {
    _ = objc.class_addMethod(cls, macos.sel(sel_name), @ptrCast(@constCast(imp)), "v@:@");
}

export fn windowDidBecomeKey(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    fire("focus", "");
}

export fn windowDidResignKey(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    fire("blur", "");
}

export fn windowDidMiniaturize(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    fire("minimize", "");
}

export fn windowDidDeminiaturize(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    fire("restore", "");
}

export fn windowDidResize(_: objc.id, _: objc.SEL, notification: objc.id) callconv(.c) void {
    const window = macos.msgSend0(notification, "object");
    if (@intFromPtr(window) == 0) return fire("resize", "");
    const frame = macos.msgSendRect(window, "frame");
    var buf: [192]u8 = undefined;
    // Include the window's ObjC pointer as a stable identifier so multi-
    // window apps can correlate which window resized. The pointer value
    // is opaque from JS but stable for the window's lifetime.
    const wid: usize = @intFromPtr(window);
    const detail = std.fmt.bufPrint(&buf, "{{\"id\":\"w{x}\",\"width\":{d},\"height\":{d}}}", .{
        wid, frame.size.width, frame.size.height,
    }) catch return fire("resize", "");
    fire("resize", detail);
}

export fn windowDidMove(_: objc.id, _: objc.SEL, notification: objc.id) callconv(.c) void {
    const window = macos.msgSend0(notification, "object");
    if (@intFromPtr(window) == 0) return fire("move", "");
    const frame = macos.msgSendRect(window, "frame");
    var buf: [192]u8 = undefined;
    const wid: usize = @intFromPtr(window);
    const detail = std.fmt.bufPrint(&buf, "{{\"id\":\"w{x}\",\"x\":{d},\"y\":{d}}}", .{
        wid, frame.origin.x, frame.origin.y,
    }) catch return fire("move", "");
    fire("move", detail);
}

export fn windowWillClose(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    fire("close", "");
}

/// Build `window.__craftDeliverWindowEvent('<name>', <detailJSON or {}>)`
/// and dispatch it on the WKWebView's window. JS turns it into a
/// `craft:window:<name>` CustomEvent.
fn fire(name: []const u8, detail_json: []const u8) void {
    const webview = macos.getGlobalWebView() orelse return;

    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(std.heap.c_allocator);

    script.appendSlice(std.heap.c_allocator, "if (window.__craftDeliverWindowEvent) window.__craftDeliverWindowEvent('") catch return;
    script.appendSlice(std.heap.c_allocator, name) catch return;
    script.appendSlice(std.heap.c_allocator, "',") catch return;
    if (detail_json.len > 0) {
        script.appendSlice(std.heap.c_allocator, detail_json) catch return;
    } else {
        script.appendSlice(std.heap.c_allocator, "{}") catch return;
    }
    script.appendSlice(std.heap.c_allocator, ");") catch return;
    script.append(std.heap.c_allocator, 0) catch return;

    const NSString = macos.getClass("NSString");
    const js_str = macos.msgSend1(NSString, "stringWithUTF8String:", @as([*:0]const u8, @ptrCast(script.items.ptr)));
    _ = macos.msgSend2(webview, "evaluateJavaScript:completionHandler:", js_str, @as(?*anyopaque, null));
}
