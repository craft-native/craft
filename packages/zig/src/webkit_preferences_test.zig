const std = @import("std");
const macos = @import("macos.zig");
const craft = @import("main.zig");

extern "c" fn craft_test_webkit_pixel(view: macos.objc.id, rgba: *[4]f64) c_int;
extern "c" fn craft_test_tray_window_begin(window: macos.objc.id, view: macos.objc.id, hidden: bool, hide_dock: bool) void;
extern "c" fn craft_test_tray_window_result() c_int;
extern "c" fn craft_test_tray_callbacks(view: macos.objc.id, other_view: macos.objc.id, item: macos.objc.id, menu: macos.objc.id) c_int;

fn findWebView(view: macos.objc.id) ?macos.objc.id {
    if (view == null) return null;
    if (macos.msgSendBool1Id(view, "isKindOfClass:", macos.getClass("WKWebView"))) return view;
    const children = macos.msgSend0(view, "subviews");
    const count = macos.msgSend0Ulong(children, "count");
    for (0..count) |index| {
        if (findWebView(macos.msgSend1(children, "objectAtIndex:", index))) |found| return found;
    }
    return null;
}

pub fn main() !void {
    const pool = macos.msgSend0(macos.msgSend0(macos.getClass("NSAutoreleasePool"), "alloc"), "init");
    defer macos.msgSendVoid0(pool, "drain");
    macos.initAppWithoutLaunching();
    const app = macos.msgSend0(macos.getClass("NSApplication"), "sharedApplication");
    _ = macos.msgSend1(app, "setActivationPolicy:", @as(c_long, 1));
    macos.msgSendVoid0(app, "finishLaunching");

    try verifyTrayCallbacks();

    for ([_]bool{ false, true }) |transparent| {
        for ([_]bool{ false, true }) |inspectable| {
            const html = if (transparent)
                "<html style='background:transparent'><body style='margin:0;background:transparent'>Public WebKit preferences</body></html>"
            else
                "<html style='background:rgb(24,64,128)'><body style='margin:0;background:rgb(24,64,128)'>Public WebKit preferences</body></html>";
            const style: macos.WindowStyle = .{ .transparent = transparent, .dev_tools = inspectable, .hide_dock_icon = true };
            if (transparent and !macos.supportsTransparentWebContent()) {
                try std.testing.expectError(error.UnsupportedWebViewTransparency, macos.createWindowWithStyle("Unsupported public transparency", 320, 240, html, null, style));
                continue;
            }
            const window = try macos.createWindowWithStyle("Craft WebKit verification", 320, 240, html, null, style);
            defer macos.destroyWindow(window);
            const webview = findWebView(macos.msgSend0(window, "contentView")) orelse return error.WebViewNotFound;
            try std.testing.expectEqual(inspectable, macos.msgSendBool(webview, "isInspectable"));
            const background = macos.msgSend0(webview, "underPageBackgroundColor");
            try std.testing.expect(background != null);
            const expected_alpha: f64 = if (transparent) 0 else 1;
            try std.testing.expectApproxEqAbs(expected_alpha, macos.msgSendFloat(background, "alphaComponent"), 0.00001);
            try std.testing.expectEqual(!transparent, macos.msgSendBool(webview, "isOpaque"));
            var rgba: [4]f64 = undefined;
            try std.testing.expectEqual(@as(c_int, 1), craft_test_webkit_pixel(webview, &rgba));
            std.debug.print("inspectable={any} transparent={any} snapshot rgba={any}\n", .{ inspectable, transparent, rgba });
            try std.testing.expectApproxEqAbs(expected_alpha, rgba[3], 0.00001);
            if (!transparent) {
                // ColorSync can change channel values on different displays.
                // A distinctive blue control proves the page rendered, rather
                // than accepting an empty or white bitmap with opaque alpha.
                try std.testing.expect(rgba[0] < rgba[1] and rgba[1] < rgba[2]);
                try std.testing.expect(rgba[0] < 0.25 and rgba[2] > 0.3 and rgba[2] < 0.75);
            }
        }
    }
    if (!macos.supportsTransparentWebContent()) {
        const window = try macos.createWindowWithStyle("Public Store preferences", 320, 240, "<html style='background:rgb(24,64,128)'><body>Store preferences</body></html>", null, .{ .titlebar_hidden = true, .dev_tools = false, .hide_dock_icon = true });
        defer macos.destroyWindow(window);
        const webview = findWebView(macos.msgSend0(window, "contentView")) orelse return error.WebViewNotFound;
        try std.testing.expect(macos.msgSendBool(webview, "isOpaque"));
        var rgba: [4]f64 = undefined;
        try std.testing.expectEqual(@as(c_int, 1), craft_test_webkit_pixel(webview, &rgba));
        try std.testing.expectApproxEqAbs(@as(f64, 1), rgba[3], 0.00001);
    }
    // Exercise App.run itself, not just its activation helper. A real AppKit
    // mouse down/up must reach WebKit with a status item present, without any
    // page-side showDockIcon/focus workaround or Accessibility permission.
    for ([_]bool{ false, true }) |hide_dock| {
        for ([_]bool{ false, true }) |frameless| {
            try verifyTrayWindow(false, hide_dock, frameless, false);
        }
    }
    try verifyTrayWindow(true, false, false, false);
    try verifyTrayWindow(false, true, false, true);
    std.debug.print("Native WebKit inspection, rendered alpha and distribution capabilities verified.\n", .{});
}

fn verifyTrayCallbacks() !void {
    var app = craft.App.init(std.heap.c_allocator);
    defer app.deinit();
    app.initPlatformForTray();
    const tray = try app.createSystemTray("Craft callback test");
    const created = try app.createWindowWithHTML("Tray callback regression", 320, 240, "<html><body>Tray callbacks</body></html>", .{ .system_tray = true });
    const window: macos.objc.id = @ptrCast(created.native_handle);
    defer macos.destroyWindow(window);
    const webview = findWebView(macos.msgSend0(window, "contentView")) orelse return error.WebViewNotFound;
    var bridge = @import("bridge_tray.zig").TrayBridge.init(std.heap.c_allocator);
    bridge.setTrayHandle(tray.platform_handle.?);
    try bridge.handleMessage("setMenu", "[{\"label\":\"Hello\",\"action\":\"hello\"}]");
    const menu = bridge.current_menu orelse return error.TrayMenuNotCreated;
    defer @import("tray_menu.zig").destroyNSMenu(menu);
    macos.showAllWindows();
    macos.activateWindowedApp();
    try std.testing.expectEqual(@as(c_int, 1), craft_test_tray_callbacks(webview, null, tray.platform_handle, menu));
    macos.hideWindow(window);
    try std.testing.expectEqual(@as(c_int, 1), craft_test_tray_callbacks(webview, null, tray.platform_handle, menu));
    try macos.loadHTMLInWebView(webview, "<html><body>Reloaded tray page</body></html>");
    try std.testing.expectEqual(@as(c_int, 1), craft_test_tray_callbacks(webview, null, tray.platform_handle, menu));

    const child = try app.createWindowWithHTML("Secondary tray page", 320, 240, "<html><body>Other window</body></html>", .{ .system_tray = true });
    const child_window: macos.objc.id = @ptrCast(child.native_handle);
    defer macos.destroyWindow(child_window);
    const child_view = findWebView(macos.msgSend0(child_window, "contentView")) orelse return error.WebViewNotFound;
    try std.testing.expectEqual(@as(c_int, 1), craft_test_tray_callbacks(webview, child_view, tray.platform_handle, menu));
    std.debug.print("Native tray click and menu callbacks verified: visible, hidden, reloaded, and second-window isolation.\n", .{});
}

fn verifyTrayWindow(headless: bool, hide_dock: bool, frameless: bool, menubar_only: bool) !void {
    var app = craft.App.init(std.heap.c_allocator);
    defer app.deinit();
    app.headless = headless;
    app.hide_dock_icon = hide_dock;
    app.initPlatformForTray();
    const tray = try app.createSystemTray("Craft tray input test");
    const window: macos.objc.id = if (menubar_only) null else blk: {
        const created = try app.createWindowWithHTML("Tray activation regression", 320, 240,
            \\<html><body style="margin:0"><button style="position:fixed;inset:0" onclick="this.dataset.clicked='yes'">Click me</button></body></html>
        , .{ .system_tray = true, .headless = headless, .hide_dock_icon = hide_dock, .frameless = frameless });
        break :blk @ptrCast(created.native_handle);
    };
    defer if (window != null) macos.destroyWindow(window);
    const webview = if (window == null) null else findWebView(macos.msgSend0(window, "contentView")) orelse return error.WebViewNotFound;
    // Reproduce the old tray startup: ordering a window alone is not enough
    // to make it interactive. App.run must still activate it.
    if (!headless and !menubar_only) app.showWindows();
    craft_test_tray_window_begin(window, webview, headless or menubar_only, hide_dock);
    try app.run();
    try std.testing.expectEqual(@as(c_int, 1), craft_test_tray_window_result());
    try std.testing.expect(macos.msgSendBool(tray.platform_handle, "isVisible"));
    std.debug.print("Tray input verified: headless={any}, hideDock={any}, frameless={any}, menubarOnly={any}\n", .{ headless, hide_dock, frameless, menubar_only });
}
