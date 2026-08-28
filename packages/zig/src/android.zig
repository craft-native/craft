const std = @import("std");
const builtin = @import("builtin");
const mobile = @import("mobile.zig");

/// Android Native Integration
/// Provides a clean API for building Android apps with Craft
///
/// Usage:
///   var app = android.CraftActivity.init(allocator, .{
///       .name = "My App",
///       .package_name = "com.example.myapp",
///       .initial_content = .{ .html = html },
///   });
///   try app.run();

// ============================================================================
// CraftActivity - Main Android Activity
// ============================================================================

/// CraftActivity - Android Activity with WebView
/// Similar to iOS CraftAppDelegate but for Android
pub const CraftActivity = struct {
    allocator: std.mem.Allocator,
    config: ActivityConfig,
    js_bridge: ?*JSBridge = null,
    webview: ?*mobile.Android.WebView = null,

    // JNI references
    // These were `?jni.JNIEnv` and `?jni.jobject` against a local `jni`
    // namespace that aliased everything to `*anyopaque` — no vtable, no
    // JavaVM, nothing that could actually reach Java. Untyped pointers say the
    // same thing without implying a binding exists. The real types arrive with
    // `android_jni.zig`, from the NDK's own `jni.h`.
    jni_env: ?*anyopaque = null,
    activity: ?*anyopaque = null,

    // Callbacks
    on_create: ?*const fn () void = null,
    on_resume: ?*const fn () void = null,
    on_pause: ?*const fn () void = null,
    on_destroy: ?*const fn () void = null,
    on_back_pressed: ?*const fn () bool = null,

    const Self = @This();

    pub const ActivityConfig = struct {
        name: []const u8 = "Craft App",
        package_name: []const u8 = "com.craft.app",
        initial_content: Content = .{ .html = default_html },
        theme: Theme = .light,
        orientation: Orientation = .portrait,
        fullscreen: bool = false,
        hardware_accelerated: bool = true,
        enable_javascript: bool = true,
        enable_dom_storage: bool = true,
        allow_file_access: bool = false,
        enable_inspector: bool = false,
    };

    pub const Content = union(enum) {
        html: []const u8,
        url: []const u8,
        asset: []const u8, // Load from assets folder
    };

    pub const Theme = enum {
        light,
        dark,
        system,
    };

    pub const Orientation = enum {
        portrait,
        landscape,
        sensor,
        unspecified,
    };

    pub fn init(allocator: std.mem.Allocator, config: ActivityConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Set onCreate callback
    pub fn onCreate(self: *Self, callback: *const fn () void) void {
        self.on_create = callback;
    }

    /// Set onResume callback
    pub fn onResume(self: *Self, callback: *const fn () void) void {
        self.on_resume = callback;
    }

    /// Set onPause callback
    pub fn onPause(self: *Self, callback: *const fn () void) void {
        self.on_pause = callback;
    }

    /// Set onDestroy callback
    pub fn onDestroy(self: *Self, callback: *const fn () void) void {
        self.on_destroy = callback;
    }

    /// Set onBackPressed callback (return true to consume the event)
    pub fn onBackPressed(self: *Self, callback: *const fn () bool) void {
        self.on_back_pressed = callback;
    }

    /// Register a custom JavaScript handler
    pub fn registerJSHandler(self: *Self, name: []const u8, handler: JSBridge.Handler) !void {
        if (self.js_bridge) |bridge| {
            try bridge.registerHandler(name, handler);
        }
    }

    /// Get the JavaScript bridge
    pub fn getBridge(self: *Self) ?*JSBridge {
        return self.js_bridge;
    }

    /// Evaluate JavaScript in the WebView
    pub fn evaluateJavaScript(self: *Self, script: []const u8, callback: ?*const fn ([]const u8) void) !void {
        _ = self;
        _ = script;
        _ = callback;
        // Would call Android WebView.evaluateJavascript via JNI
    }

    /// Load HTML content
    pub fn loadHTML(self: *Self, html: []const u8) !void {
        _ = self;
        _ = html;
        // Would call WebView.loadDataWithBaseURL via JNI
    }

    /// Load URL
    pub fn loadURL(self: *Self, url: []const u8) !void {
        _ = self;
        _ = url;
        // Would call WebView.loadUrl via JNI
    }

    /// Run the activity (called from JNI onCreate)
    pub fn run(self: *Self) !void {
        // Initialize JavaScript bridge
        const bridge = try self.allocator.create(JSBridge);
        bridge.* = JSBridge.init(self.allocator);
        bridge.activity = self;
        self.js_bridge = bridge;

        // Load initial content
        switch (self.config.initial_content) {
            .html => |html| try self.loadHTML(html),
            .url => |url| try self.loadURL(url),
            .asset => |asset| {
                const url = try std.fmt.allocPrint(self.allocator, "file:///android_asset/{s}", .{asset});
                defer self.allocator.free(url);
                try self.loadURL(url);
            },
        }

        // Call onCreate callback
        if (self.on_create) |callback| {
            callback();
        }

        // Send ready event
        if (self.js_bridge) |bridge_ptr| {
            bridge_ptr.sendEvent("ready", "{}") catch |err| {
                std.log.warn("failed to send ready event to Android JS bridge: {}", .{err});
            };
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.js_bridge) |bridge| {
            bridge.deinit();
            self.allocator.destroy(bridge);
        }
    }
};

// ============================================================================
// JavaScript Bridge for Android
// ============================================================================

/// JavaScript bridge for Android WebView
/// Handles messages from JavaScript via @JavascriptInterface
pub const JSBridge = struct {
    handlers: std.StringHashMap(Handler),
    allocator: std.mem.Allocator,
    activity: ?*CraftActivity = null,

    pub const Handler = *const fn (params: []const u8, bridge: *JSBridge, callback_id: []const u8) void;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) JSBridge {
        // No built-in handlers are registered any more. The nine that used to
        // be here — `getPlatform`, `showToast`, `vibrate`, `setClipboard`,
        // `getClipboard`, `share`, `openURL`, `getNetworkStatus`, `showAlert`
        // — each extracted their arguments, discarded them, and replied
        // `{"success": true}`. `getPlatform` answered with a hardcoded
        // `"version": "14"`. A handler that fabricates success is worse than a
        // missing one: the missing one is reported to the caller.
        return .{
            .handlers = std.StringHashMap(Handler).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.handlers.deinit();
    }

    pub fn registerHandler(self: *Self, name: []const u8, handler: Handler) !void {
        try self.handlers.put(name, handler);
    }

    pub fn sendResponse(self: *Self, callback_id: []const u8, result: []const u8) !void {
        if (self.activity == null) return error.NoActivity;
        if (callback_id.len == 0) return;

        var buf: [2048]u8 = undefined;
        const script = std.fmt.bufPrint(&buf,
            \\if (window['__craftCallback_{s}']) {{ window['__craftCallback_{s}']({s}); }}
        , .{ callback_id, callback_id, result }) catch return;

        try self.activity.?.evaluateJavaScript(script, null);
    }

    pub fn sendError(self: *Self, callback_id: []const u8, error_message: []const u8) !void {
        if (self.activity == null) return error.NoActivity;
        if (callback_id.len == 0) return;

        var buf: [2048]u8 = undefined;
        const script = std.fmt.bufPrint(&buf,
            \\if (window['__craftCallback_{s}']) {{ window['__craftCallback_{s}']({{ error: '{s}' }}); }}
        , .{ callback_id, callback_id, error_message }) catch return;

        try self.activity.?.evaluateJavaScript(script, null);
    }

    pub fn sendEvent(self: *Self, event: []const u8, data: []const u8) !void {
        if (self.activity == null) return error.NoActivity;

        var buf: [2048]u8 = undefined;
        const script = std.fmt.bufPrint(&buf,
            \\window.dispatchEvent(new CustomEvent('craft:{s}', {{ detail: {s} }}));
        , .{ event, data }) catch return;

        try self.activity.?.evaluateJavaScript(script, null);
    }
};

// ============================================================================
// Quick Start Helper
// ============================================================================

/// Quick start an Android app with HTML content
pub fn quickStart(allocator: std.mem.Allocator, html: []const u8) !void {
    var app = CraftActivity.init(allocator, .{
        .name = "Craft App",
        .initial_content = .{ .html = html },
    });
    defer app.deinit();
    try app.run();
}

// ============================================================================
// Default HTML
// ============================================================================

const default_html =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\    <meta charset="UTF-8">
    \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\    <title>Craft App</title>
    \\    <style>
    \\        * { box-sizing: border-box; margin: 0; padding: 0; }
    \\        body {
    \\            font-family: 'Roboto', sans-serif;
    \\            display: flex;
    \\            align-items: center;
    \\            justify-content: center;
    \\            min-height: 100vh;
    \\            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    \\            color: white;
    \\            text-align: center;
    \\            padding: 20px;
    \\        }
    \\        h1 { font-size: 2rem; margin-bottom: 1rem; }
    \\        p { opacity: 0.9; font-size: 1.1rem; }
    \\    </style>
    \\</head>
    \\<body>
    \\    <div>
    \\        <h1>Welcome to Craft</h1>
    \\        <p>Your Android app is ready!</p>
    \\    </div>
    \\</body>
    \\</html>
;

// ============================================================================
// Tests
// ============================================================================

test "CraftActivity initialization" {
    const allocator = std.testing.allocator;

    const config = CraftActivity.ActivityConfig{
        .name = "Test App",
        .package_name = "com.test.app",
        .initial_content = .{ .html = "<h1>Hello</h1>" },
    };

    const app = CraftActivity.init(allocator, config);
    _ = app;
}

test "JSBridge initialization" {
    const allocator = std.testing.allocator;

    var bridge = JSBridge.init(allocator);
    defer bridge.deinit();

    const handler = struct {
        fn handle(_: []const u8, _: *JSBridge, _: []const u8) void {}
    }.handle;

    try bridge.registerHandler("test", handler);
}
