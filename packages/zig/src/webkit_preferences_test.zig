const std = @import("std");
const macos = @import("macos.zig");

extern "c" fn craft_test_webkit_pixel(view: macos.objc.id, rgba: *[4]f64) c_int;

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
            defer macos.closeWindow(window);
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
        defer macos.closeWindow(window);
        const webview = findWebView(macos.msgSend0(window, "contentView")) orelse return error.WebViewNotFound;
        try std.testing.expect(macos.msgSendBool(webview, "isOpaque"));
        var rgba: [4]f64 = undefined;
        try std.testing.expectEqual(@as(c_int, 1), craft_test_webkit_pixel(webview, &rgba));
        try std.testing.expectApproxEqAbs(@as(f64, 1), rgba[3], 0.00001);
    }
    std.debug.print("Native WebKit inspection, rendered alpha and distribution capabilities verified.\n", .{});
}
