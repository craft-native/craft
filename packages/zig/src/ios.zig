const std = @import("std");
const objc_runtime = @import("objc_runtime.zig");
const mobile = @import("mobile.zig");
const ios_dispatch = @import("ios_dispatch.zig");
const window_chrome = @import("window_chrome.zig");

// Test collection, not a test. Zig only collects `test` blocks from
// containers the test root *references*, and `ios_dispatch` is a non-pub
// import — so without this, its tests and every mobile module's tests were
// silently absent from `zig build test:ios`. That was found with a canary:
// a deliberately failing test in a module, and a green run.
test {
    _ = ios_dispatch;
}

/// iOS Application Infrastructure
/// Provides UIApplicationDelegate, UIViewController, and full app lifecycle management
/// Re-exported so `test/ios_surface_test.zig` can reach the runtime without
/// importing `objc_runtime.zig` as a second module — a file may belong to only
/// one module per compilation, and this one already belongs to the iOS module.
pub const objc = objc_runtime.objc;

// ============================================================================
// WKScriptMessageHandler
// ============================================================================

/// What the page's `webkit.messageHandlers.craft.postMessage` reaches.
///
/// This is registered as a real Objective-C method on a class built at runtime,
/// which is the piece iOS never had. `setupJSBridge` used to fetch the
/// `WKUserContentController` and then discard it with `_ = content_controller;`
/// under a comment saying a full implementation would register a handler here.
/// Because it never did, `webkit.messageHandlers.craft` was `undefined` in
/// every page craft ever loaded on iOS.
///
/// `macos.zig:5017` is the source this is ported from, and it needed no
/// adaptation beyond the dispatch target: it uses the Objective-C runtime,
/// Foundation and WebKit only, with nothing from AppKit.
export fn craftDidReceiveScriptMessage(
    _: objc.id,
    _: objc.SEL,
    _: objc.id,
    message: objc.id,
) void {
    const sel_body = objc.sel_registerName("body") orelse return;
    const body = objc.msgSendId(message, sel_body);
    if (body == null) return;

    // Re-serialise the message body with NSJSONSerialization rather than
    // walking the Objective-C object graph by hand. WebKit has already parsed
    // the page's object into NSDictionary/NSArray/NSNumber, and asking
    // Foundation to render it back to JSON is both shorter and correct for
    // nested values, unicode, and numbers — none of which the substring parser
    // this replaces could handle.
    const NSJSONSerialization = objc.objc_getClass("NSJSONSerialization") orelse return;
    const sel_data = objc.sel_registerName("dataWithJSONObject:options:error:") orelse return;
    const DataFn = *const fn (objc.id, objc.SEL, objc.id, c_ulong, ?*anyopaque) callconv(.c) objc.id;
    const data_fn: DataFn = @ptrCast(&objc.objc_msgSend);
    const json_data = data_fn(NSJSONSerialization, sel_data, body, 0, null);
    if (json_data == null) return;

    const NSString = objc.objc_getClass("NSString") orelse return;
    const sel_alloc = objc.sel_registerName("alloc") orelse return;
    const allocated = objc.msgSendId(NSString, sel_alloc);
    const sel_init = objc.sel_registerName("initWithData:encoding:") orelse return;
    const NSUTF8StringEncoding: c_ulong = 4;
    const InitFn = *const fn (objc.id, objc.SEL, objc.id, c_ulong) callconv(.c) objc.id;
    const init_fn: InitFn = @ptrCast(&objc.objc_msgSend);
    const json_string = init_fn(allocated, sel_init, json_data, NSUTF8StringEncoding);
    if (json_string == null) return;
    defer objc.release(json_string);

    const utf8 = objc.getNSStringUTF8(json_string) orelse return;
    const json = std.mem.span(utf8);

    ios_dispatch.handleMessage(std.heap.c_allocator, json) catch |err| {
        // A message that cannot be routed is logged, not swallowed. The page
        // has already been answered with an error by the dispatcher where one
        // could be attributed; this covers the cases where it could not.
        std.log.warn("ios bridge: could not handle message: {}", .{err});
    };
}

/// Build the handler class once and attach it to the content controller under
/// the name `craft` — which is what `craft-bridge.js` already posts to.
///
/// `objc_getClass` first, so a second call is a no-op rather than a duplicate
/// class registration.
fn installScriptMessageHandler(content_controller: objc.id) !void {
    const class_name = "CraftIOSScriptMessageHandler";

    var handler_class = objc.objc_getClass(class_name);
    if (handler_class == null) {
        const NSObject = objc.objc_getClass("NSObject") orelse return error.ClassNotFound;
        handler_class = objc.objc_allocateClassPair(NSObject, class_name, 0) orelse
            return error.ClassAllocationFailed;

        const sel = objc.sel_registerName("userContentController:didReceiveScriptMessage:") orelse
            return error.SelectorNotFound;
        const imp: objc.IMP = @ptrCast(@constCast(&craftDidReceiveScriptMessage));
        // v@:@@ — returns void, takes self, _cmd, and two objects.
        if (!objc.class_addMethod(handler_class, sel, imp, "v@:@@")) {
            return error.MethodNotAdded;
        }
        objc.objc_registerClassPair(handler_class);
    }

    const handler = try objc.allocInit(handler_class);

    const sel_add = objc.sel_registerName("addScriptMessageHandler:name:") orelse
        return error.SelectorNotFound;
    const NSString = objc.objc_getClass("NSString") orelse return error.ClassNotFound;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse return error.SelectorNotFound;
    const name = objc.msgSendId1(NSString, sel_string, @as([*:0]const u8, "craft"));

    const AddFn = *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) void;
    const add_fn: AddFn = @ptrCast(&objc.objc_msgSend);
    add_fn(content_controller, sel_add, handler, name);
}

/// Install a script that runs before the page's own scripts do.
///
/// The previous code called `evaluateJavaScript` *before* `loadInitialContent`,
/// so the script ran against the empty document and the navigation that
/// followed discarded it. A `WKUserScript` at `atDocumentStart` is the
/// mechanism that actually survives navigation, and it must be added to the
/// content controller before the webview is constructed — which is why webview
/// creation moved into this file.
fn installUserScript(content_controller: objc.id, source: [:0]const u8) !void {
    const WKUserScript = objc.objc_getClass("WKUserScript") orelse return error.ClassNotFound;
    const NSString = objc.objc_getClass("NSString") orelse return error.ClassNotFound;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse return error.SelectorNotFound;
    const ns_source = objc.msgSendId1(NSString, sel_string, source.ptr);

    const sel_alloc = objc.sel_registerName("alloc") orelse return error.SelectorNotFound;
    const allocated = objc.msgSendId(WKUserScript, sel_alloc);

    const sel_init = objc.sel_registerName("initWithSource:injectionTime:forMainFrameOnly:") orelse
        return error.SelectorNotFound;
    // 0 == WKUserScriptInjectionTimeAtDocumentStart
    const InitFn = *const fn (objc.id, objc.SEL, objc.id, c_long, bool) callconv(.c) objc.id;
    const init_fn: InitFn = @ptrCast(&objc.objc_msgSend);
    const user_script = init_fn(allocated, sel_init, ns_source, 0, true);
    if (user_script == null) return error.UserScriptCreationFailed;

    const sel_add = objc.sel_registerName("addUserScript:") orelse return error.SelectorNotFound;
    objc.msgSendVoid1(content_controller, sel_add, user_script);
}

/// The Phase 1 user script.
///
/// Deliberately not `craft-bridge.js`: that file defines `craft.window.*`,
/// `craft.tray.*`, and `craft.menu.*`, surfaces iOS has no business exposing,
/// and deciding which of them iOS should carry is a larger question than the
/// first vertical slice needs to answer.
///
/// What it does prove is injection *timing*: a page can observe this flag from
/// its own inline script, which is only possible if the user script ran at
/// document start. That is the exact property the previous implementation got
/// wrong.
const phase1_user_script: [:0]const u8 =
    \\window.__craftInjectedAtDocumentStart = true;
;

/// Tell the page there is no window chrome here.
///
/// A component library renders the same markup on a Mac and on a phone. On the
/// Mac it must not draw window buttons, because AppKit already did; on a phone
/// it must not draw them either, because there is no window to close, minimise
/// or zoom — three fake macOS discs in the corner of an iPhone screen are
/// decoration pretending to be controls.
///
/// Saying so explicitly is what makes the difference reachable: the same CSS
/// variable answers "should I draw these?" on both platforms, and the page
/// needs no `navigator.platform` sniffing to ask.
fn installWindowChromeScript(content_controller: objc.id) !void {
    var buffer: [window_chrome.seed_script_size + 1]u8 = undefined;
    const script = window_chrome.seedScript(
        window_chrome.classify(.absent, null, null, .{}),
        buffer[0 .. buffer.len - 1],
    ) catch return error.WindowChromeScriptTooLong;

    buffer[script.len] = 0;
    try installUserScript(content_controller, buffer[0..script.len :0]);
}

// ============================================================================
// UIApplicationMain
// ============================================================================

/// int UIApplicationMain(int, char *[], NSString *principal, NSString *delegate)
extern "c" fn UIApplicationMain(
    argc: c_int,
    argv: [*][*:0]u8,
    principal_class_name: objc.id,
    delegate_class_name: objc.id,
) c_int;

const app_delegate_class_name = "CraftAppDelegate";

/// The Zig delegate UIKit's instance calls back into.
///
/// UIKit constructs the delegate itself, from the class name handed to
/// `UIApplicationMain`, so the callback receives an Objective-C object that
/// knows nothing about this struct. A module-level pointer is the bridge
/// between them. One slot, because an iOS process has one `UIApplication`.
var g_delegate: ?*CraftAppDelegate = null;

/// `application:didFinishLaunchingWithOptions:`
///
/// The first moment UIKit is up and it is legal to touch `UIScreen`,
/// `UIWindow`, or `makeKeyAndVisible`. Everything `run` used to do inline
/// happens from here.
///
/// Returns `bool` rather than `i8`: on 64-bit Apple platforms `__OBJC_BOOL_IS_BOOL`
/// is defined, so `BOOL` is C99 `_Bool` and the type encoding is `B`.
export fn craftAppDidFinishLaunching(
    _: objc.id,
    _: objc.SEL,
    _: objc.id,
    _: objc.id,
) bool {
    const delegate = g_delegate orelse {
        std.log.err("ios: didFinishLaunching fired with no delegate registered", .{});
        return false;
    };

    delegate.didFinishLaunching() catch |err| {
        // Returning false from here tells UIKit the launch failed, which is
        // the truthful answer. The alternative — returning true over a window
        // that was never built — produces a black screen and no diagnostic,
        // which is the failure mode this whole file is being rewritten to
        // stop producing.
        std.log.err("ios: launch failed: {}", .{err});
        return false;
    };

    return true;
}

/// Register the delegate class UIKit will instantiate.
///
/// Same runtime class-building the script message handler uses, and the same
/// `objc_getClass`-first guard so a second call is a no-op.
pub fn registerAppDelegateClass() !void {
    if (objc.objc_getClass(app_delegate_class_name) != null) return;

    const NSObject = objc.objc_getClass("NSObject") orelse return error.ClassNotFound;
    const cls = objc.objc_allocateClassPair(NSObject, app_delegate_class_name, 0) orelse
        return error.ClassAllocationFailed;

    const sel = objc.sel_registerName("application:didFinishLaunchingWithOptions:") orelse
        return error.SelectorNotFound;
    const imp: objc.IMP = @ptrCast(@constCast(&craftAppDidFinishLaunching));
    // B@:@@ — returns BOOL, takes self, _cmd, UIApplication, NSDictionary.
    if (!objc.class_addMethod(cls, sel, imp, "B@:@@")) return error.MethodNotAdded;

    objc.objc_registerClassPair(cls);
}

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

    /// Start the iOS application. Does not return.
    ///
    /// An iOS app starts by handing control to `UIApplicationMain`, which
    /// creates the `UIApplication`, instantiates the delegate class it is
    /// named, and runs the event loop. Everything this file does to UIKit is
    /// only legal after that has happened: `[UIScreen mainScreen]` is nil
    /// before it, so a window built beforehand takes its frame from garbage,
    /// and `makeKeyAndVisible` has no application instance to key against.
    ///
    /// So `run` does two things and then stops being in charge: register a
    /// delegate class whose `application:didFinishLaunchingWithOptions:` is
    /// `craftAppDidFinishLaunching`, and call `UIApplicationMain`. The window,
    /// the webview, and the bridge are all built from inside that callback.
    ///
    /// The previous version spun `[[NSRunLoop currentRunLoop] run]` on the
    /// calling thread, which UIKit does not own — no touch delivery, no
    /// lifecycle notifications, no `UIApplication.sharedApplication`.
    pub fn run(self: *Self, argc: c_int, argv: [*][*:0]u8) noreturn {
        // `comptime`, not a runtime check: `UIApplicationMain` lives in UIKit,
        // which does not exist on macOS. A runtime branch would still leave the
        // call analysed and the symbol referenced, and the host build — which
        // is where `test/ios_surface_test.zig` forces analysis of this file —
        // would fail to link.
        if (comptime @import("builtin").target.os.tag != .ios) {
            std.log.err("ios: run() is only callable on iOS", .{});
            std.process.exit(1);
        }

        mobile.initGlobalObjectManager(self.allocator);

        // UIKit instantiates the delegate class itself, so the callback below
        // receives an Objective-C instance rather than this Zig struct. This is
        // how it finds its way back.
        g_delegate = self;

        registerAppDelegateClass() catch |err| {
            std.log.err("ios: could not register the app delegate class: {}", .{err});
            std.process.exit(1);
        };

        const NSString = objc.objc_getClass("NSString") orelse std.process.exit(1);
        const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse std.process.exit(1);
        const delegate_name = objc.msgSendId1(
            NSString,
            sel_string,
            @as([*:0]const u8, app_delegate_class_name),
        );

        _ = UIApplicationMain(argc, argv, null, delegate_name);

        // `UIApplicationMain` does not return under normal operation.
        std.process.exit(0);
    }

    /// Build the UI. Called by UIKit, once, from
    /// `application:didFinishLaunchingWithOptions:`.
    ///
    /// This is the body `run` used to have, moved to the only point where it is
    /// legal to execute it.
    pub fn didFinishLaunching(self: *Self) !void {
        try self.createWindow();
        try self.createRootViewController();
        try self.loadInitialContent();
        try self.showWindow();

        if (self.on_launch) |callback| {
            callback();
        }
    }

    // `setupJSBridge` used to sit here. It fetched the
    // `WKUserContentController` and then discarded it with
    // `_ = content_controller;`, under a comment promising that a real
    // implementation would register a `WKScriptMessageHandler`. It never did,
    // which is why `webkit.messageHandlers.craft` was undefined in every page
    // craft loaded on iOS.
    //
    // The handler is now installed in `createWebViewWithBridge`, which is the
    // only place it can be: on the configuration, before the webview is built
    // from it.

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
    /// Create the WKWebView with the bridge already attached.
    ///
    /// Order is the whole point of this function, and it is the order the old
    /// code could not express: content controller → handler → user script →
    /// configuration → webview. Anything that attaches to the content
    /// controller has to happen before the webview is constructed from the
    /// configuration that holds it.
    fn createWebViewWithBridge(self: *Self) !objc.id {
        _ = self;

        const WKWebViewConfiguration = objc.objc_getClass("WKWebViewConfiguration") orelse
            return error.ClassNotFound;
        const configuration = try objc.allocInit(WKWebViewConfiguration);

        const WKUserContentController = objc.objc_getClass("WKUserContentController") orelse
            return error.ClassNotFound;
        const content_controller = try objc.allocInit(WKUserContentController);

        try installScriptMessageHandler(content_controller);
        try installUserScript(content_controller, phase1_user_script);
        try installWindowChromeScript(content_controller);

        const sel_set_ucc = objc.sel_registerName("setUserContentController:") orelse
            return error.SelectorNotFound;
        objc.msgSendVoid1(configuration, sel_set_ucc, content_controller);

        const WKWebView = objc.objc_getClass("WKWebView") orelse return error.ClassNotFound;
        const allocated = try objc.alloc(WKWebView);

        // A zero rect: Auto Layout sets the real frame in
        // `setupWebViewConstraints`, and reading `[UIScreen mainScreen] bounds`
        // here would be reading it before UIKit is up.
        const frame = objc.CGRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 0, .height = 0 },
        };

        const sel_init = objc.sel_registerName("initWithFrame:configuration:") orelse
            return error.SelectorNotFound;
        const InitFn = *const fn (objc.id, objc.SEL, objc.CGRect, objc.id) callconv(.c) objc.id;
        const init_fn: InitFn = @ptrCast(&objc.objc_msgSend);
        const webview = init_fn(allocated, sel_init, frame, configuration);
        if (webview == null) return error.WebViewCreationFailed;

        return webview;
    }

    fn createRootViewController(self: *Self) !void {
        // Create CraftViewController (our custom UIViewController)
        const UIViewControllerClass = objc.objc_getClass("UIViewController") orelse return error.ClassNotFound;
        self.root_view_controller = try objc.allocInit(UIViewControllerClass);

        // Build the webview here rather than through `mobile.iOS.createWebView`,
        // which constructs its own `WKWebViewConfiguration` internally and never
        // hands it back. Both the script message handler and the user script
        // attach to the `WKUserContentController`, and that has to be set on the
        // configuration *before* `initWithFrame:configuration:` runs — a webview
        // cannot be given a message handler after the fact.
        const webview_obj = try self.createWebViewWithBridge();
        self.webview = @ptrCast(@alignCast(webview_obj));
        ios_dispatch.setWebView(webview_obj);

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

/// Quick start function for simple apps. Does not return.
///
/// `argc`/`argv` are forwarded because `UIApplicationMain` wants the real ones:
/// UIKit reads launch arguments from them, and synthesising a fake pair means
/// anything passed to the process is silently lost.
pub fn quickStart(allocator: std.mem.Allocator, html: []const u8, argc: c_int, argv: [*][*:0]u8) noreturn {
    var app = CraftAppDelegate.init(allocator, .{
        .name = "Craft App",
        .initial_content = .{ .html = html },
    });

    app.run(argc, argv);
}

/// Quick start with URL. Does not return.
pub fn quickStartURL(allocator: std.mem.Allocator, url: []const u8, argc: c_int, argv: [*][*:0]u8) noreturn {
    var app = CraftAppDelegate.init(allocator, .{
        .name = "Craft App",
        .initial_content = .{ .url = url },
    });

    app.run(argc, argv);
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
