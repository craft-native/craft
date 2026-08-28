const std = @import("std");
const ios = @import("ios.zig");
const mobile = @import("mobile.zig");
const objc_runtime = @import("objc_runtime.zig");

/// iOS Main Entry Point
///
/// This file provides the entry point for iOS applications built with Craft.
/// It exports the necessary C symbols that Xcode expects for iOS app lifecycle.
///
/// Usage in Xcode project:
/// 1. Build the Craft static library for iOS: `zig build build-ios`
/// 2. Link libcraft-ios.a in your Xcode project
/// 3. Call craft_ios_main() from your main.m or AppDelegate
/// Application delegate storage (global for Objective-C callbacks)
var g_app_delegate: ?*ios.CraftAppDelegate = null;
var g_allocator: ?std.mem.Allocator = null;

/// HTML content to load (set by user before calling run)
var g_html_content: ?[]const u8 = null;
var g_url_content: ?[]const u8 = null;

// ============================================================================
// C Exports for Xcode Integration
// ============================================================================

/// Initialize the Craft iOS framework
/// Call this from your AppDelegate's application:didFinishLaunchingWithOptions:
export fn craft_ios_init() callconv(.c) c_int {
    // Use the C allocator for iOS compatibility
    g_allocator = std.heap.c_allocator;
    return 0;
}

/// Set HTML content to load in the webview
/// Call this before craft_ios_run() to specify what to display
export fn craft_ios_set_html(html: [*]const u8, len: usize) callconv(.c) void {
    if (g_allocator) |allocator| {
        // Copy the HTML content
        const html_slice = html[0..len];
        const copied = allocator.alloc(u8, len) catch return;
        @memcpy(copied, html_slice);
        g_html_content = copied;
    }
}

/// Set URL to load in the webview
/// Call this before craft_ios_run() to specify what to display
export fn craft_ios_set_url(url: [*]const u8, len: usize) callconv(.c) void {
    if (g_allocator) |allocator| {
        const url_slice = url[0..len];
        const copied = allocator.alloc(u8, len) catch return;
        @memcpy(copied, url_slice);
        g_url_content = copied;
    }
}

/// Run the Craft iOS application
/// This creates the UIWindow, WKWebView, and starts the app
export fn craft_ios_run() callconv(.c) c_int {
    const allocator = g_allocator orelse return -1;

    // Determine content to load
    const content: ios.CraftAppDelegate.AppConfig.Content = blk: {
        if (g_html_content) |html| {
            break :blk .{ .html = html };
        } else if (g_url_content) |url| {
            break :blk .{ .url = url };
        } else {
            // Default HTML content
            break :blk .{ .html = default_html };
        }
    };

    // Create app delegate
    const app = allocator.create(ios.CraftAppDelegate) catch return -1;
    app.* = ios.CraftAppDelegate.init(allocator, .{
        .name = "Craft App",
        .initial_content = content,
        .status_bar_style = .default,
        .orientations = &[_]ios.CraftAppDelegate.AppConfig.Orientation{
            .portrait,
            .landscape_left,
            .landscape_right,
        },
        .enable_inspector = true,
    });

    g_app_delegate = app;

    // Run the app
    app.run() catch return -1;

    return 0;
}

/// Clean up Craft iOS resources
export fn craft_ios_deinit() callconv(.c) void {
    if (g_allocator) |allocator| {
        if (g_html_content) |html| {
            allocator.free(html);
            g_html_content = null;
        }
        if (g_url_content) |url| {
            allocator.free(url);
            g_url_content = null;
        }
        if (g_app_delegate) |app| {
            allocator.destroy(app);
            g_app_delegate = null;
        }
    }
}

/// Get the current app delegate (for custom handlers)
export fn craft_ios_get_delegate() callconv(.c) ?*ios.CraftAppDelegate {
    return g_app_delegate;
}

/// Trigger haptic feedback
export fn craft_ios_haptic(haptic_type: c_int) callconv(.c) void {
    const h_type: mobile.iOS.HapticType = switch (haptic_type) {
        0 => .impact_light,
        1 => .impact_medium,
        2 => .impact_heavy,
        3 => .notification_success,
        4 => .notification_warning,
        5 => .notification_error,
        else => .selection,
    };
    mobile.iOS.triggerHaptic(h_type);
}

// `craft_ios_show_alert` used to be exported here. It forwarded to
// `mobile.iOS.showAlert`, which presented its UIAlertController against
// `[UIApplication sharedApplication].keyWindow` — deprecated since iOS 13 and
// nil in any scene-based app, which is every app the templates generate. It
// also computed an auto-dismiss delay and then discarded it, so the alert its
// doc comment described as self-dismissing never dismissed.
//
// Nothing outside this file ever called it: no Swift template references any
// `craft_ios_*` symbol.

// ============================================================================
// Default HTML Content
// ============================================================================

const default_html =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\    <meta charset="UTF-8">
    \\    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
    \\    <title>Craft App</title>
    \\    <style>
    \\        * { box-sizing: border-box; margin: 0; padding: 0; }
    \\        body {
    \\            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    \\            display: flex;
    \\            align-items: center;
    \\            justify-content: center;
    \\            min-height: 100vh;
    \\            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    \\            color: white;
    \\            text-align: center;
    \\            padding: 20px;
    \\            padding-top: env(safe-area-inset-top);
    \\            padding-bottom: env(safe-area-inset-bottom);
    \\        }
    \\        h1 { font-size: 2rem; margin-bottom: 1rem; }
    \\        p { opacity: 0.9; font-size: 1.1rem; }
    \\    </style>
    \\</head>
    \\<body>
    \\    <div>
    \\        <h1>Welcome to Craft</h1>
    \\        <p>Your iOS app is ready!</p>
    \\        <p>Set your HTML content using craft_ios_set_html()</p>
    \\    </div>
    \\</body>
    \\</html>
;

// ============================================================================
// Zig-native API (for pure Zig iOS apps)
// ============================================================================

/// Create and run an iOS app with HTML content
pub fn runWithHTML(allocator: std.mem.Allocator, html: []const u8, config: ios.CraftAppDelegate.AppConfig) !void {
    var app_config = config;
    app_config.initial_content = .{ .html = html };

    var app = ios.CraftAppDelegate.init(allocator, app_config);
    try app.run();
}

/// Create and run an iOS app with a URL
pub fn runWithURL(allocator: std.mem.Allocator, url: []const u8, config: ios.CraftAppDelegate.AppConfig) !void {
    var app_config = config;
    app_config.initial_content = .{ .url = url };

    var app = ios.CraftAppDelegate.init(allocator, app_config);
    try app.run();
}

/// Quick start an iOS app with just HTML
pub fn quickStart(allocator: std.mem.Allocator, html: []const u8) !void {
    try ios.quickStart(allocator, html);
}

// The C API surface used to be asserted by a `test` block here that listed
// `craft_ios_set_clipboard`, `craft_ios_open_url`, and `craft_ios_share` —
// three functions this file has never declared. Undeclared identifiers are
// resolved in AstGen, which runs over the whole file regardless of whether a
// test is being built, so those three names were three of the nine errors that
// kept `zig build build-ios-simulator` red from the 0.17 migration onward.
//
// It also asserted nothing a compiler would not: `_ = craft_ios_init;` on an
// `export fn` in the same file cannot fail. `test/ios_surface_test.zig` covers
// the real property — that every declaration reachable from `ios.zig` and
// `mobile.iOS` actually compiles — and it does so on the host, in seconds.
