const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos.zig");
const capabilities = @import("capabilities.zig");

const objc = macos.objc;

var installed: bool = false;
// If a URL is delivered before the page is ready, hold it here so the
// JS side can pick it up via `craft.deepLink.getInitialUrl()` once it
// boots. Replaced by every subsequent URL.
// AppleEvent handlers and JS calls both run on the main run loop thread
// in the single-threaded craft binary, so this is effectively a single
// access point. No mutex needed.
var pending_url: ?[]u8 = null;

const kInternetEventClass: u32 = 0x4755524C; // 'GURL'
const kAEGetURL: u32 = 0x4755524C; // 'GURL'
const keyDirectObject: u32 = 0x2D2D2D2D; // '----'

/// Register an AppleEvent handler for `kAEGetURL` so the OS routes
/// `myapp://...` URLs into our process whenever the user opens such a
/// link (including the very first launch).
///
/// This is only half of it. macOS dispatches a URL to an app because the
/// app's bundle claims the scheme under `CFBundleURLTypes`, and nothing
/// craft produced used to write that key — so this handler was complete,
/// correct, and could never fire. `packageApp` now emits it from the
/// `urlSchemes` an app declares; a bare binary with no bundle still cannot
/// be a URL handler, because there is nothing for LaunchServices to
/// register.
///
/// macOS-only. Idempotent.
pub fn install() void {
    if (installed) return;
    if (builtin.target.os.tag != .macos) return;

    // Build a small handler class with one selector that matches the
    // AppleEvent handler signature. We can't register a free C function
    // with NSAppleEventManager — it requires a target/selector.
    const NSObject = macos.getClass("NSObject");
    const class_name = "CraftDeepLinkHandler";

    var cls = objc.objc_getClass(class_name);
    if (cls == null) {
        cls = objc.objc_allocateClassPair(NSObject, class_name, 0);
        if (cls == null) return;

        const handler_imp: objc.IMP = @ptrCast(@constCast(&handleAppleEvent));
        _ = objc.class_addMethod(
            cls,
            macos.sel("handleAppleEvent:withReplyEvent:"),
            handler_imp,
            "v@:@@",
        );

        objc.objc_registerClassPair(cls);
    }

    const handler = macos.msgSend0(macos.msgSend0(cls, "alloc"), "init");
    // Retain the handler globally — NSAppleEventManager doesn't keep a
    // strong reference, and we need the instance alive for the lifetime
    // of the process.
    _ = macos.msgSend0(handler, "retain");

    const NSAppleEventManager = macos.getClass("NSAppleEventManager");
    const mgr = macos.msgSend0(NSAppleEventManager, "sharedAppleEventManager");

    const Fn = *const fn (objc.id, objc.SEL, objc.id, objc.SEL, u32, u32) callconv(.c) void;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    f(
        mgr,
        macos.sel("setEventHandler:andSelector:forEventClass:andEventID:"),
        handler,
        macos.sel("handleAppleEvent:withReplyEvent:"),
        kInternetEventClass,
        kAEGetURL,
    );

    installed = true;
    _ = capabilities.registerEmitter(.deeplink);

    if (comptime builtin.mode == .debug) {
        std.debug.print("[DeepLink] Installed AppleEvent handler for kAEGetURL\n", .{});
    }
}

export fn handleAppleEvent(
    self: objc.id,
    selector: objc.SEL,
    event: objc.id,
    reply: objc.id,
) callconv(.c) void {
    _ = self;
    _ = selector;
    _ = reply;

    // Pull `keyDirectObject` out of the AppleEvent — that's where Apple
    // stuffs the URL string for kAEGetURL.
    const ParamFn = *const fn (objc.id, objc.SEL, u32) callconv(.c) objc.id;
    const param_fn: ParamFn = @ptrCast(&objc.objc_msgSend);
    const direct = param_fn(event, macos.sel("paramDescriptorForKeyword:"), keyDirectObject);
    if (@intFromPtr(direct) == 0) return;

    const ns_str = macos.msgSend0(direct, "stringValue");
    if (@intFromPtr(ns_str) == 0) return;

    const utf8 = macos.msgSend0(ns_str, "UTF8String");
    if (@intFromPtr(utf8) == 0) return;
    const url_slice = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));

    deliver(url_slice);
}

fn deliver(url: []const u8) void {
    // Stash so getInitialUrl() can return it if the page wasn't ready.
    if (pending_url) |old| std.heap.c_allocator.free(old);
    pending_url = std.heap.c_allocator.dupe(u8, url) catch null;

    // Build window.__craftDeliverDeepLink("<url>") with proper escaping.
    var escaped: std.ArrayListUnmanaged(u8) = .empty;
    defer escaped.deinit(std.heap.c_allocator);

    for (url) |b| {
        switch (b) {
            '\\' => escaped.appendSlice(std.heap.c_allocator, "\\\\") catch return,
            '"' => escaped.appendSlice(std.heap.c_allocator, "\\\"") catch return,
            '\n' => escaped.appendSlice(std.heap.c_allocator, "\\n") catch return,
            '\r' => escaped.appendSlice(std.heap.c_allocator, "\\r") catch return,
            '\t' => escaped.appendSlice(std.heap.c_allocator, "\\t") catch return,
            else => escaped.append(std.heap.c_allocator, b) catch return,
        }
    }

    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(std.heap.c_allocator);
    script.appendSlice(std.heap.c_allocator, "if (window.__craftDeliverDeepLink) window.__craftDeliverDeepLink(\"") catch return;
    script.appendSlice(std.heap.c_allocator, escaped.items) catch return;
    script.appendSlice(std.heap.c_allocator, "\");") catch return;
    script.append(std.heap.c_allocator, 0) catch return;

    const webview = macos.getGlobalWebView() orelse return;
    const NSString = macos.getClass("NSString");
    const js_str = macos.msgSend1(NSString, "stringWithUTF8String:", @as([*:0]const u8, @ptrCast(script.items.ptr)));
    _ = macos.msgSend2(webview, "evaluateJavaScript:completionHandler:", js_str, @as(?*anyopaque, null));

    if (comptime builtin.mode == .debug) {
        std.debug.print("[DeepLink] Delivered URL to JS: {s}\n", .{url});
    }
}
