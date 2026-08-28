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
/// Call this before craft_ios_main() to specify what to display
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
/// Call this before craft_ios_main() to specify what to display
export fn craft_ios_set_url(url: [*]const u8, len: usize) callconv(.c) void {
    if (g_allocator) |allocator| {
        const url_slice = url[0..len];
        const copied = allocator.alloc(u8, len) catch return;
        @memcpy(copied, url_slice);
        g_url_content = copied;
    }
}

/// Run the Craft iOS application. Does not return.
///
/// Renamed from `craft_ios_run` and given `argc`/`argv` because
/// `UIApplicationMain` needs them: UIKit reads launch arguments from that pair,
/// and it is what an app's `main` is handed. The old signature took nothing and
/// returned `c_int`, which could not express either fact — it implied the call
/// returns, and an iOS app's does not.
///
/// Call it from `main`:
///
///     extern int craft_ios_main(int argc, char **argv);
///     int main(int argc, char **argv) { return craft_ios_main(argc, argv); }
export fn craft_ios_main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    const allocator = g_allocator orelse {
        std.log.err("craft_ios_main called before craft_ios_init", .{});
        return -1;
    };

    const content: ios.CraftAppDelegate.AppConfig.Content = blk: {
        if (g_html_content) |html| {
            break :blk .{ .html = html };
        } else if (g_url_content) |url| {
            break :blk .{ .url = url };
        } else {
            break :blk .{ .html = default_html };
        }
    };

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

    app.run(argc, argv);
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

/// Create and run an iOS app with HTML content. Does not return.
pub fn runWithHTML(
    allocator: std.mem.Allocator,
    html: []const u8,
    config: ios.CraftAppDelegate.AppConfig,
    argc: c_int,
    argv: [*][*:0]u8,
) noreturn {
    var app_config = config;
    app_config.initial_content = .{ .html = html };

    var app = ios.CraftAppDelegate.init(allocator, app_config);
    app.run(argc, argv);
}

/// Create and run an iOS app with a URL. Does not return.
pub fn runWithURL(
    allocator: std.mem.Allocator,
    url: []const u8,
    config: ios.CraftAppDelegate.AppConfig,
    argc: c_int,
    argv: [*][*:0]u8,
) noreturn {
    var app_config = config;
    app_config.initial_content = .{ .url = url };

    var app = ios.CraftAppDelegate.init(allocator, app_config);
    app.run(argc, argv);
}

/// Quick start an iOS app with just HTML
pub fn quickStart(allocator: std.mem.Allocator, html: []const u8, argc: c_int, argv: [*][*:0]u8) noreturn {
    ios.quickStart(allocator, html, argc, argv);
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
