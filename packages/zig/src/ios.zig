const std = @import("std");
const objc_runtime = @import("objc_runtime.zig");
const mobile = @import("mobile.zig");

/// iOS Application Infrastructure
/// Provides UIApplicationDelegate, UIViewController, and full app lifecycle management
const objc = objc_runtime.objc;

// ============================================================================
// iOS Application Delegate
// ============================================================================

/// CraftAppDelegate - Main iOS application delegate
/// Handles app lifecycle events and window setup
pub const CraftAppDelegate = struct {
    window: ?objc.id = null,
    root_view_controller: ?objc.id = null,
    webview: ?*mobile.iOS.WKWebView = null,
    allocator: std.mem.Allocator,
    config: AppConfig,

    // Callbacks
    on_launch: ?*const fn () void = null,
    on_foreground: ?*const fn () void = null,
    on_background: ?*const fn () void = null,
    on_terminate: ?*const fn () void = null,
    on_memory_warning: ?*const fn () void = null,
    on_js_message: ?*const fn ([]const u8) void = null,

    pub const AppConfig = struct {
        /// App display name
        name: []const u8 = "Craft App",
        /// Initial HTML content or URL
        initial_content: Content,
        /// Status bar style
        status_bar_style: StatusBarStyle = .default,
        /// Support orientations
        orientations: []const Orientation = &[_]Orientation{.portrait},
        /// Enable WebKit inspector (debug only)
        enable_inspector: bool = false,
        /// Custom user agent suffix
        user_agent_suffix: ?[]const u8 = null,
        /// Tint color for UI elements (RGBA)
        tint_color: ?[4]u8 = null,
        /// Allow background audio
        background_audio: bool = false,

        pub const Content = union(enum) {
            html: []const u8,
            url: []const u8,
            file: []const u8,
        };

        pub const StatusBarStyle = enum {
            default,
            light,
            dark,
            hidden,
        };

        pub const Orientation = enum {
            portrait,
            portrait_upside_down,
            landscape_left,
            landscape_right,

            pub fn toMask(self: Orientation) u32 {
                return switch (self) {
                    .portrait => 0x02, // UIInterfaceOrientationMaskPortrait
                    .portrait_upside_down => 0x04, // UIInterfaceOrientationMaskPortraitUpsideDown
                    .landscape_left => 0x10, // UIInterfaceOrientationMaskLandscapeLeft
                    .landscape_right => 0x08, // UIInterfaceOrientationMaskLandscapeRight
                };
            }
        };
    };

    const Self = @This();

    /// Initialize the app delegate
    pub fn init(allocator: std.mem.Allocator, config: AppConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Register callbacks for lifecycle events
    pub fn onLaunch(self: *Self, callback: *const fn () void) void {
        self.on_launch = callback;
    }

    pub fn onForeground(self: *Self, callback: *const fn () void) void {
        self.on_foreground = callback;
    }

    pub fn onBackground(self: *Self, callback: *const fn () void) void {
        self.on_background = callback;
    }

    pub fn onTerminate(self: *Self, callback: *const fn () void) void {
        self.on_terminate = callback;
    }

    pub fn onMemoryWarning(self: *Self, callback: *const fn () void) void {
        self.on_memory_warning = callback;
    }

    // `registerJSHandler` and `getBridge` used to sit here, handing callers a
    // `*JSBridge` whose `handleMessage` had no caller anywhere in the tree —
    // `setupJSBridge` below never registered a `WKScriptMessageHandler`, so
    // nothing could ever deliver a message to it. They are gone along with the
    // bridge itself; the replacement routes through `ios_dispatch.zig` and the
    // same `bridge_*.zig` modules the desktop uses.

    /// Start the iOS application
    /// This should be called from main() and will not return until the app terminates
    pub fn run(self: *Self) !void {
        if (!@import("builtin").target.os.tag.isDarwin()) {
            return error.UnsupportedPlatform;
        }

        // Initialize global object manager for memory tracking
        mobile.initGlobalObjectManager(self.allocator);
        defer mobile.deinitGlobalObjectManager();

        // These four are the pieces that survive into the real startup path,
        // and they are called here so the compiler keeps checking them. They
        // must not run in this order on a device: every one of them touches
        // UIKit, and UIKit is not initialised until `UIApplicationMain` has
        // been called. `[UIScreen mainScreen]` returns nil before that, so
        // `createWindow` builds its `initWithFrame:` rect out of garbage, and
        // `showWindow`'s `makeKeyAndVisible` traps with no `UIApplication`
        // instance to key against.
        try self.createWindow();
        try self.createRootViewController();
        try self.setupJSBridge();
        try self.loadInitialContent();
        try self.showWindow();

        if (self.on_launch) |callback| {
            callback();
        }

        // There is no run loop to enter. The previous version spun
        // `[[NSRunLoop currentRunLoop] run]`, which is not how an iOS app
        // starts and gave no touch delivery and no lifecycle events.
        //
        // Saying so is the honest state of this file: iOS compiles again, and
        // it does not yet launch. The next phase registers a delegate class,
        // calls `UIApplicationMain`, and moves the five calls above into
        // `application:didFinishLaunchingWithOptions:`, which is the only
        // point at which they are legal.
        return error.RunLoopNotImplemented;
    }

    /// Set up WKScriptMessageHandler for JavaScript bridge
    fn setupJSBridge(self: *Self) !void {
        if (self.webview == null) return error.WebViewNotInitialized;

        // Get the webview's configuration
        const webview_ptr: objc.id = @ptrCast(@alignCast(self.webview.?));
        const sel_configuration = objc.sel_registerName("configuration") orelse return error.SelectorNotFound;
        const configuration = objc.msgSendId(webview_ptr, sel_configuration);

        // Get user content controller
        const sel_userContentController = objc.sel_registerName("userContentController") orelse return error.SelectorNotFound;
        const content_controller = objc.msgSendId(configuration, sel_userContentController);

        // Nothing is registered on the controller yet, so a page's
        // `window.webkit.messageHandlers.craft` is undefined and every call
        // from JS is silently dropped. The comment that used to sit here said
        // the bridge would "work through evaluateJavaScript polling" instead —
        // no such polling was ever written, which is why iOS has looked wired
        // up without being reachable.
        //
        // `macos.zig:5071` already does this correctly and uses nothing from
        // AppKit — objc runtime, Foundation, and WebKit only — so the next
        // phase ports it here rather than inventing a second one.
        _ = content_controller;
    }

    /// Create the main UIWindow
    fn createWindow(self: *Self) !void {
        // Get UIScreen mainScreen bounds
        const UIScreenClass = objc.objc_getClass("UIScreen") orelse return error.ClassNotFound;
        const sel_mainScreen = objc.sel_registerName("mainScreen") orelse return error.SelectorNotFound;
        const sel_bounds = objc.sel_registerName("bounds") orelse return error.SelectorNotFound;

        const mainScreen = objc.msgSendId(UIScreenClass, sel_mainScreen);

        // Get bounds as CGRect
        const BoundsFn = *const fn (objc.id, objc.SEL) callconv(.c) objc.CGRect;
        const boundsFn: BoundsFn = @ptrCast(&objc_runtime.objc.objc_msgSend);
        const bounds = boundsFn(mainScreen, sel_bounds);

        // Create UIWindow: [[UIWindow alloc] initWithFrame:bounds]
        const UIWindowClass = objc.objc_getClass("UIWindow") orelse return error.ClassNotFound;
        const sel_initWithFrame = objc.sel_registerName("initWithFrame:") orelse return error.SelectorNotFound;

        const allocated = try objc.alloc(UIWindowClass);
        const InitFn = *const fn (objc.id, objc.SEL, objc.CGRect) callconv(.c) objc.id;
        const initFn: InitFn = @ptrCast(&objc_runtime.objc.objc_msgSend);
        self.window = initFn(allocated, sel_initWithFrame, bounds);

        // Set window background color
        const sel_setBackgroundColor = objc.sel_registerName("setBackgroundColor:") orelse return error.SelectorNotFound;
        const UIColorClass = objc.objc_getClass("UIColor") orelse return error.ClassNotFound;
        const sel_whiteColor = objc.sel_registerName("whiteColor") orelse return error.SelectorNotFound;
        const whiteColor = objc.msgSendId(UIColorClass, sel_whiteColor);

        const SetColorFn = *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void;
        const setColorFn: SetColorFn = @ptrCast(&objc_runtime.objc.objc_msgSend);
        setColorFn(self.window.?, sel_setBackgroundColor, whiteColor);
    }

    /// Create root view controller with WKWebView
    fn createRootViewController(self: *Self) !void {
        // Create CraftViewController (our custom UIViewController)
        const UIViewControllerClass = objc.objc_getClass("UIViewController") orelse return error.ClassNotFound;
        self.root_view_controller = try objc.allocInit(UIViewControllerClass);

        // Create WKWebView configuration
        const webview_config = mobile.iOS.WebViewConfig{
            .allows_inline_media_playback = true,
            .allows_air_play = true,
            .allows_back_forward_navigation_gestures = true,
        };

        // Create WKWebView
        self.webview = try mobile.iOS.createWebView(self.allocator, webview_config);
        const webview_obj: objc.id = @ptrCast(@alignCast(self.webview.?));

        // Get view controller's view
        const sel_view = objc.sel_registerName("view") orelse return error.SelectorNotFound;
        const vc_view = objc.msgSendId(self.root_view_controller.?, sel_view);

        // Add webview as subview: [view addSubview:webview]
        const sel_addSubview = objc.sel_registerName("addSubview:") orelse return error.SelectorNotFound;
        const AddSubviewFn = *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void;
        const addSubviewFn: AddSubviewFn = @ptrCast(&objc_runtime.objc.objc_msgSend);
        addSubviewFn(vc_view, sel_addSubview, webview_obj);

        // Set webview to fill the view using Auto Layout
        try self.setupWebViewConstraints(vc_view, webview_obj);

        // Configure status bar style
        try self.configureStatusBar();

        // Set root view controller on window
        const sel_setRootViewController = objc.sel_registerName("setRootViewController:") orelse return error.SelectorNotFound;
        const SetVCFn = *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void;
        const setVCFn: SetVCFn = @ptrCast(&objc_runtime.objc.objc_msgSend);
        setVCFn(self.window.?, sel_setRootViewController, self.root_view_controller.?);
    }

    /// Setup Auto Layout constraints for webview
    fn setupWebViewConstraints(self: *Self, parent_view: objc.id, webview: objc.id) !void {
        _ = self;

        // Disable autoresizing mask translation
        const sel_setTranslatesAutoresizingMaskIntoConstraints = objc.sel_registerName("setTranslatesAutoresizingMaskIntoConstraints:") orelse return error.SelectorNotFound;
        const SetTranslatesFn = *const fn (objc.id, objc.SEL, bool) callconv(.c) void;
        const setTranslatesFn: SetTranslatesFn = @ptrCast(&objc_runtime.objc.objc_msgSend);
        setTranslatesFn(webview, sel_setTranslatesAutoresizingMaskIntoConstraints, false);

        // Get layout anchors
        const sel_topAnchor = objc.sel_registerName("topAnchor") orelse return error.SelectorNotFound;
        const sel_bottomAnchor = objc.sel_registerName("bottomAnchor") orelse return error.SelectorNotFound;
        const sel_leadingAnchor = objc.sel_registerName("leadingAnchor") orelse return error.SelectorNotFound;
        const sel_trailingAnchor = objc.sel_registerName("trailingAnchor") orelse return error.SelectorNotFound;
        const sel_safeAreaLayoutGuide = objc.sel_registerName("safeAreaLayoutGuide") orelse return error.SelectorNotFound;

        // Get safe area layout guide
        const safeArea = objc.msgSendId(parent_view, sel_safeAreaLayoutGuide);

        // Get anchors
        const webviewTop = objc.msgSendId(webview, sel_topAnchor);
        const webviewBottom = objc.msgSendId(webview, sel_bottomAnchor);
        const webviewLeading = objc.msgSendId(webview, sel_leadingAnchor);
        const webviewTrailing = objc.msgSendId(webview, sel_trailingAnchor);

        const safeTop = objc.msgSendId(safeArea, sel_topAnchor);
        const safeBottom = objc.msgSendId(safeArea, sel_bottomAnchor);
        const safeLeading = objc.msgSendId(safeArea, sel_leadingAnchor);
        const safeTrailing = objc.msgSendId(safeArea, sel_trailingAnchor);

        // Create constraints
        const sel_constraintEqualToAnchor = objc.sel_registerName("constraintEqualToAnchor:") orelse return error.SelectorNotFound;
        const sel_setActive = objc.sel_registerName("setActive:") orelse return error.SelectorNotFound;

        const ConstraintFn = *const fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id;
        const constraintFn: ConstraintFn = @ptrCast(&objc_runtime.objc.objc_msgSend);

        const SetActiveFn = *const fn (objc.id, objc.SEL, bool) callconv(.c) void;
        const setActiveFn: SetActiveFn = @ptrCast(&objc_runtime.objc.objc_msgSend);

        // Activate constraints
        const topConstraint = constraintFn(webviewTop, sel_constraintEqualToAnchor, safeTop);
        setActiveFn(topConstraint, sel_setActive, true);

        const bottomConstraint = constraintFn(webviewBottom, sel_constraintEqualToAnchor, safeBottom);
        setActiveFn(bottomConstraint, sel_setActive, true);

        const leadingConstraint = constraintFn(webviewLeading, sel_constraintEqualToAnchor, safeLeading);
        setActiveFn(leadingConstraint, sel_setActive, true);

        const trailingConstraint = constraintFn(webviewTrailing, sel_constraintEqualToAnchor, safeTrailing);
        setActiveFn(trailingConstraint, sel_setActive, true);
    }

    /// Configure status bar appearance
    fn configureStatusBar(self: *Self) !void {
        _ = self;
        // Status bar configuration is handled by Info.plist and preferredStatusBarStyle
        // The view controller should override preferredStatusBarStyle
    }

    /// Load initial content into webview
    fn loadInitialContent(self: *Self) !void {
        if (self.webview == null) return error.WebViewNotInitialized;

        switch (self.config.initial_content) {
            .url => |url| {
                try mobile.iOS.loadURL(self.webview.?, url);
            },
            .html => |html| {
                try self.loadHTMLString(html);
            },
            .file => |path| {
                try self.loadFileURL(path);
            },
        }
    }

    /// Load HTML string into webview
    fn loadHTMLString(self: *Self, html: []const u8) !void {
        if (!@import("builtin").target.os.tag.isDarwin()) {
            return error.UnsupportedPlatform;
        }

        const webview_ptr: objc.id = @ptrCast(@alignCast(self.webview.?));

        // Create NSString from HTML
        const html_ns = try objc.createNSString(html, self.allocator);

        // Create base URL (empty string)
        const NSURLClass = objc.objc_getClass("NSURL") orelse return error.ClassNotFound;
        const sel_fileURLWithPath = objc.sel_registerName("fileURLWithPath:") orelse return error.SelectorNotFound;

        const empty_path = try objc.createNSString("", self.allocator);
        const base_url = objc.msgSendId1(NSURLClass, sel_fileURLWithPath, empty_path);

        // Load HTML: [webview loadHTMLString:html baseURL:baseURL]
        const sel_loadHTMLString = objc.sel_registerName("loadHTMLString:baseURL:") orelse return error.SelectorNotFound;
        // `objc.id` is already `?*anyopaque`, so `?objc.id` is a double
        // optional — and a non-pointer optional has no guaranteed in-memory
        // representation, which makes it illegal in a `callconv(.c)`
        // signature. A nil `baseURL:` is spelled by passing a null `objc.id`,
        // not by wrapping the type in another optional.
        const LoadHTMLFn = *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.id;
        const loadHTMLFn: LoadHTMLFn = @ptrCast(&objc_runtime.objc.objc_msgSend);
        _ = loadHTMLFn(webview_ptr, sel_loadHTMLString, html_ns, base_url);
    }

    /// Load file URL into webview
    fn loadFileURL(self: *Self, path: []const u8) !void {
        if (!@import("builtin").target.os.tag.isDarwin()) {
            return error.UnsupportedPlatform;
        }

        const webview_ptr: objc.id = @ptrCast(@alignCast(self.webview.?));

        // Create file URL
        const NSURLClass = objc.objc_getClass("NSURL") orelse return error.ClassNotFound;
        const sel_fileURLWithPath = objc.sel_registerName("fileURLWithPath:") orelse return error.SelectorNotFound;

        const path_ns = try objc.createNSString(path, self.allocator);
        const file_url = objc.msgSendId1(NSURLClass, sel_fileURLWithPath, path_ns);

        // Get parent directory for allowing read access
        const sel_URLByDeletingLastPathComponent = objc.sel_registerName("URLByDeletingLastPathComponent") orelse return error.SelectorNotFound;
        const dir_url = objc.msgSendId(file_url, sel_URLByDeletingLastPathComponent);

        // Load file: [webview loadFileURL:url allowingReadAccessToURL:dirURL]
        const sel_loadFileURL = objc.sel_registerName("loadFileURL:allowingReadAccessToURL:") orelse return error.SelectorNotFound;
        const LoadFileFn = *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.id;
        const loadFileFn: LoadFileFn = @ptrCast(&objc_runtime.objc.objc_msgSend);
        _ = loadFileFn(webview_ptr, sel_loadFileURL, file_url, dir_url);
    }

    /// Make window visible
    fn showWindow(self: *Self) !void {
        if (self.window == null) return error.WindowNotInitialized;

        // Make window key and visible: [window makeKeyAndVisible]
        const sel_makeKeyAndVisible = objc.sel_registerName("makeKeyAndVisible") orelse return error.SelectorNotFound;
        objc.msgSend(self.window.?, sel_makeKeyAndVisible);
    }

    // `runMainLoop` used to live here, spinning
    // `[[NSRunLoop currentRunLoop] run]`. That is not how an iOS app starts.
    // UIKit owns the run loop, and it only owns it once `UIApplicationMain`
    // has been called — which is also what makes `UIApplication.sharedApplication`
    // and `[UIScreen mainScreen]` return anything but nil. Spinning a bare
    // NSRunLoop meant no touch delivery, no lifecycle notifications, and a
    // window built against a garbage frame.
    //
    // The replacement is not a function; it is a restructure. `run()` registers
    // a delegate class and calls `UIApplicationMain`, and everything this file
    // used to do inline moves into `application:didFinishLaunchingWithOptions:`.

    /// Execute JavaScript in the webview
    pub fn evaluateJavaScript(self: *Self, script: []const u8, callback: ?*const fn ([]const u8) void) !void {
        if (self.webview == null) return error.WebViewNotInitialized;
        try mobile.iOS.evaluateJavaScript(self.webview.?, script, callback);
    }

    /// Get safe area insets
    pub fn getSafeAreaInsets(self: *Self) !SafeAreaInsets {
        if (self.window == null) return error.WindowNotInitialized;

        const sel_safeAreaInsets = objc.sel_registerName("safeAreaInsets") orelse return error.SelectorNotFound;

        const InsetsFn = *const fn (objc.id, objc.SEL) callconv(.c) UIEdgeInsets;
        const insetsFn: InsetsFn = @ptrCast(&objc_runtime.objc.objc_msgSend);
        const insets = insetsFn(self.window.?, sel_safeAreaInsets);

        return SafeAreaInsets{
            .top = @floatCast(insets.top),
            .bottom = @floatCast(insets.bottom),
            .left = @floatCast(insets.left),
            .right = @floatCast(insets.right),
        };
    }

    /// Trigger haptic feedback
    pub fn haptic(self: *Self, haptic_type: mobile.iOS.HapticType) void {
        _ = self;
        mobile.iOS.triggerHaptic(haptic_type);
    }

    // `showAlert`, `requestPermission`, and `checkPermission` were one-line
    // forwards to `mobile.iOS` functions that have been deleted, for reasons
    // recorded where they used to live: the alert presented against
    // `keyWindow`, nil in any scene-based app; the permission request threw
    // its caller's callback away (`_ = callback;`) and passed null for every
    // completion handler; and the status check returned `.not_determined` for
    // notifications no matter what the system said.
    //
    // They come back in the permissions phase, against a pending-request table
    // keyed by the envelope's request id — not a callback that nothing calls.
};

/// Safe area insets
pub const SafeAreaInsets = struct {
    top: f32,
    bottom: f32,
    left: f32,
    right: f32,
};

/// UIEdgeInsets structure (matches iOS)
const UIEdgeInsets = extern struct {
    top: f64,
    left: f64,
    bottom: f64,
    right: f64,
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Quick start function for simple apps
pub fn quickStart(allocator: std.mem.Allocator, html: []const u8) !void {
    var app = CraftAppDelegate.init(allocator, .{
        .name = "Craft App",
        .initial_content = .{ .html = html },
    });

    try app.run();
}

/// Quick start with URL
pub fn quickStartURL(allocator: std.mem.Allocator, url: []const u8) !void {
    var app = CraftAppDelegate.init(allocator, .{
        .name = "Craft App",
        .initial_content = .{ .url = url },
    });

    try app.run();
}

// ============================================================================
// Tests
// ============================================================================

test "CraftAppDelegate initialization" {
    const allocator = std.testing.allocator;

    const config = CraftAppDelegate.AppConfig{
        .name = "Test App",
        .initial_content = .{ .html = "<h1>Hello</h1>" },
    };

    const app = CraftAppDelegate.init(allocator, config);
    _ = app;

    // Can't fully test without iOS runtime
}

test "SafeAreaInsets" {
    const insets = SafeAreaInsets{
        .top = 47.0,
        .bottom = 34.0,
        .left = 0.0,
        .right = 0.0,
    };

    try std.testing.expectEqual(@as(f32, 47.0), insets.top);
    try std.testing.expectEqual(@as(f32, 34.0), insets.bottom);
}
