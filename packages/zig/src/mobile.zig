const std = @import("std");
const objc_runtime = @import("objc_runtime.zig");
const compat = @import("compat.zig");

/// Mobile Platform Support
/// Provides iOS and Android native integration

// Use the proper Objective-C runtime wrapper
const objc = objc_runtime.objc;

// JNI for Android
const jni = if (@import("builtin").target.os.tag == .linux) struct {
    // JNI types
    pub const JNIEnv = opaque {};
    pub const jobject = ?*anyopaque;
    pub const jclass = ?*anyopaque;
    pub const jmethodID = ?*anyopaque;
    pub const jfieldID = ?*anyopaque;
    pub const jstring = ?*anyopaque;
    pub const jboolean = u8;
    pub const jint = i32;
    pub const jlong = i64;

    // JNI function pointers (these will be looked up from JNIEnv vtable)
    // The JNIEnv is actually a pointer to a vtable of function pointers
    const JNINativeInterface = extern struct {
        reserved0: ?*anyopaque,
        reserved1: ?*anyopaque,
        reserved2: ?*anyopaque,
        reserved3: ?*anyopaque,
        GetVersion: ?*const fn (*JNIEnv) callconv(.c) jint,
        // ... many more function pointers ...
        FindClass: ?*const fn (*JNIEnv, [*:0]const u8) callconv(.c) jclass,
        GetMethodID: ?*const fn (*JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID,
        GetObjectClass: ?*const fn (*JNIEnv, jobject) callconv(.c) jclass,
        CallObjectMethodV: ?*const fn (*JNIEnv, jobject, jmethodID, ...) callconv(.c) jobject,
        CallVoidMethodV: ?*const fn (*JNIEnv, jobject, jmethodID, ...) callconv(.c) void,
        NewStringUTF: ?*const fn (*JNIEnv, [*:0]const u8) callconv(.c) jstring,
        GetStringUTFChars: ?*const fn (*JNIEnv, jstring, ?*jboolean) callconv(.c) [*:0]const u8,
        ReleaseStringUTFChars: ?*const fn (*JNIEnv, jstring, [*:0]const u8) callconv(.c) void,
    };

    // Helper to get the function table from JNIEnv
    fn getTable(env: *JNIEnv) *JNINativeInterface {
        const env_ptr: **JNINativeInterface = @ptrCast(@alignCast(env));
        return env_ptr.*;
    }

    // Wrapper functions
    pub fn FindClass(env: *JNIEnv, name: [*:0]const u8) jclass {
        const table = getTable(env);
        if (table.FindClass) |func| {
            return func(env, name);
        }
        return null;
    }

    pub fn GetObjectClass(env: *JNIEnv, obj: jobject) jclass {
        const table = getTable(env);
        if (table.GetObjectClass) |func| {
            return func(env, obj);
        }
        return null;
    }

    pub fn GetMethodID(env: *JNIEnv, cls: jclass, name: [*:0]const u8, sig: [*:0]const u8) jmethodID {
        const table = getTable(env);
        if (table.GetMethodID) |func| {
            return func(env, cls, name, sig);
        }
        return null;
    }

    pub fn CallVoidMethod(env: *JNIEnv, obj: jobject, methodID: jmethodID, args: anytype) void {
        const table = getTable(env);
        if (table.CallVoidMethodV) |func| {
            _ = @call(.auto, func, .{ env, obj, methodID } ++ args);
        }
    }

    pub fn CallObjectMethod(env: *JNIEnv, obj: jobject, methodID: jmethodID, args: anytype) jobject {
        const table = getTable(env);
        if (table.CallObjectMethodV) |func| {
            return @call(.auto, func, .{ env, obj, methodID } ++ args);
        }
        return null;
    }

    pub fn NewStringUTF(env: *JNIEnv, bytes: [*:0]const u8) jstring {
        const table = getTable(env);
        if (table.NewStringUTF) |func| {
            return func(env, bytes);
        }
        return null;
    }

    pub fn GetStringUTFChars(env: *JNIEnv, string: jstring, isCopy: ?*jboolean) [*:0]const u8 {
        const table = getTable(env);
        if (table.GetStringUTFChars) |func| {
            return func(env, string, isCopy);
        }
        return @ptrCast(&[_]u8{0});
    }

    pub fn ReleaseStringUTFChars(env: *JNIEnv, string: jstring, utf: [*:0]const u8) void {
        const table = getTable(env);
        if (table.ReleaseStringUTFChars) |func| {
            func(env, string, utf);
        }
    }
} else struct {};

// ============================================================================
// Android Callback Storage
// ============================================================================

/// Stored callbacks for Android ValueCallback (JS evaluation) and permissions
pub const AndroidCallbackStorage = struct {
    // JavaScript evaluation callbacks - indexed by request ID
    js_callbacks: [16]?*const fn ([]const u8) void = @splat(null),
    js_callback_next_id: u32 = 0,

    // Permission callbacks - indexed by request code
    permission_callbacks: [16]?*const fn (bool) void = @splat(null),

    const Self = @This();

    /// Store a JS callback and return its ID
    pub fn storeJsCallback(self: *Self, callback: *const fn ([]const u8) void) u32 {
        const id = self.js_callback_next_id % 16;
        self.js_callbacks[id] = callback;
        self.js_callback_next_id +%= 1;
        return id;
    }

    /// Invoke and clear a JS callback
    pub fn invokeJsCallback(self: *Self, id: u32, result: []const u8) void {
        const idx = id % 16;
        if (self.js_callbacks[idx]) |callback| {
            callback(result);
            self.js_callbacks[idx] = null;
        }
    }

    /// Store a permission callback with request code
    pub fn storePermissionCallback(self: *Self, request_code: u32, callback: *const fn (bool) void) void {
        const idx = request_code % 16;
        self.permission_callbacks[idx] = callback;
    }

    /// Invoke and clear a permission callback
    pub fn invokePermissionCallback(self: *Self, request_code: u32, granted: bool) void {
        const idx = request_code % 16;
        if (self.permission_callbacks[idx]) |callback| {
            callback(granted);
            self.permission_callbacks[idx] = null;
        }
    }
};

/// Global callback storage for Android
var android_callbacks: AndroidCallbackStorage = .{};

// JNI export functions are only compiled on Android (Linux target)
// On other platforms, these are no-ops
comptime {
    if (@import("builtin").target.os.tag == .linux) {
        @export(&Java_app_craft_CraftValueCallback_nativeOnReceiveValue_impl, .{ .name = "Java_app_craft_CraftValueCallback_nativeOnReceiveValue" });
        @export(&Java_app_craft_CraftActivity_nativeOnPermissionResult_impl, .{ .name = "Java_app_craft_CraftActivity_nativeOnPermissionResult" });
    }
}

/// JNI callback function exported for ValueCallback.onReceiveValue
/// Called from Java when evaluateJavascript completes
fn Java_app_craft_CraftValueCallback_nativeOnReceiveValue_impl(
    env: *jni.JNIEnv,
    this: jni.jobject,
    callback_id: jni.jint,
    result: jni.jstring,
) callconv(.c) void {
    _ = this;

    // Convert Java string result to Zig slice
    const result_chars = jni.GetStringUTFChars(env, result, null);
    const result_slice = std.mem.span(result_chars);

    // Invoke the stored callback
    android_callbacks.invokeJsCallback(@intCast(callback_id), result_slice);

    // Release the string
    jni.ReleaseStringUTFChars(env, result, result_chars);
}

/// JNI callback function exported for permission results
/// Called from Activity.onRequestPermissionsResult
fn Java_app_craft_CraftActivity_nativeOnPermissionResult_impl(
    env: *jni.JNIEnv,
    this: jni.jobject,
    request_code: jni.jint,
    granted: jni.jboolean,
) callconv(.c) void {
    _ = env;
    _ = this;

    // Invoke the stored callback
    android_callbacks.invokePermissionCallback(@intCast(request_code), granted != 0);
}

pub const Platform = enum {
    ios,
    android,
    unknown,

    pub fn current() Platform {
        const builtin = @import("builtin");
        return switch (builtin.target.os.tag) {
            .ios => .ios,
            .tvos => .ios,
            .watchos => .ios,
            .macos => .ios, // iOS simulator on macOS
            .linux => .android, // Assume Android when building on Linux for ARM
            else => .unknown,
        };
    }
};

/// Memory Management for Native Objects
pub const NativeObjectManager = struct {
    allocator: std.mem.Allocator,
    tracked_objects: std.AutoHashMap(usize, ObjectInfo),
    total_allocations: usize,
    total_deallocations: usize,
    peak_object_count: usize,

    const ObjectInfo = struct {
        ptr: *anyopaque,
        size: usize,
        type_name: []const u8,
        allocation_time: i64,
    };

    pub fn init(allocator: std.mem.Allocator) NativeObjectManager {
        return .{
            .allocator = allocator,
            .tracked_objects = std.AutoHashMap(usize, ObjectInfo).init(allocator),
            .total_allocations = 0,
            .total_deallocations = 0,
            .peak_object_count = 0,
        };
    }

    pub fn deinit(self: *NativeObjectManager) void {
        // Clean up any remaining tracked objects
        var it = self.tracked_objects.iterator();
        while (it.next()) |entry| {
            self.releaseObject(entry.key_ptr.*) catch |err| {
                std.log.debug("mobile object cleanup failed: {}", .{err});
            };
        }
        self.tracked_objects.deinit();
    }

    pub fn trackObject(self: *NativeObjectManager, ptr: *anyopaque, size: usize, type_name: []const u8) !void {
        const addr = @intFromPtr(ptr);
        const info = ObjectInfo{
            .ptr = ptr,
            .size = size,
            .type_name = type_name,
            .allocation_time = compat.timestamp(),
        };

        try self.tracked_objects.put(addr, info);
        self.total_allocations += 1;

        const current_count = self.tracked_objects.count();
        if (current_count > self.peak_object_count) {
            self.peak_object_count = current_count;
        }
    }

    pub fn releaseObject(self: *NativeObjectManager, addr: usize) !void {
        if (self.tracked_objects.fetchRemove(addr)) |entry| {
            self.total_deallocations += 1;

            // Platform-specific cleanup
            const platform = Platform.current();
            switch (platform) {
                .ios => {
                    if (@import("builtin").target.os.tag.isDarwin()) {
                        // Remove associated objects before releasing
                        objc.objc_removeAssociatedObjects(entry.value.ptr);
                    }
                },
                .android => {
                    // JNI cleanup would go here
                },
                .unknown => {},
            }
        }
    }

    pub fn getObjectInfo(self: *NativeObjectManager, addr: usize) ?ObjectInfo {
        return self.tracked_objects.get(addr);
    }

    pub fn getStats(self: *NativeObjectManager) struct {
        total_allocations: usize,
        total_deallocations: usize,
        current_objects: usize,
        peak_objects: usize,
    } {
        return .{
            .total_allocations = self.total_allocations,
            .total_deallocations = self.total_deallocations,
            .current_objects = self.tracked_objects.count(),
            .peak_objects = self.peak_object_count,
        };
    }

    pub fn printLeaks(self: *NativeObjectManager) void {
        var it = self.tracked_objects.iterator();
        var leak_count: usize = 0;

        std.debug.print("Memory Leak Report:\n", .{});
        while (it.next()) |entry| {
            const age = compat.timestamp() - entry.value.*.allocation_time;
            std.debug.print("  Leaked {s} at 0x{x} (size: {d} bytes, age: {d}s)\n", .{
                entry.value.*.type_name,
                entry.key_ptr.*,
                entry.value.*.size,
                age,
            });
            leak_count += 1;
        }

        if (leak_count == 0) {
            std.debug.print("  No leaks detected!\n", .{});
        } else {
            std.debug.print("  Total leaks: {d}\n", .{leak_count});
        }
    }
};

/// Global native object manager (should be initialized on app startup)
var global_object_manager: ?NativeObjectManager = null;

pub fn initGlobalObjectManager(allocator: std.mem.Allocator) void {
    global_object_manager = NativeObjectManager.init(allocator);
}

pub fn deinitGlobalObjectManager() void {
    if (global_object_manager) |*manager| {
        manager.deinit();
        global_object_manager = null;
    }
}

pub fn getGlobalObjectManager() ?*NativeObjectManager {
    if (global_object_manager) |*manager| {
        return manager;
    }
    return null;
}

/// iOS Native Integration
pub const iOS = struct {
    pub const UIViewController = opaque {};
    pub const UIView = opaque {};
    pub const WKWebView = opaque {};
    pub const NSString = opaque {};

    /// iOS App Configuration
    pub const AppConfig = struct {
        bundle_id: []const u8,
        display_name: []const u8,
        version: []const u8,
        build_number: []const u8,
        supported_orientations: []const Orientation,
        requires_fullscreen: bool = false,
        status_bar_style: StatusBarStyle = .default,
        background_modes: []const BackgroundMode = &[_]BackgroundMode{},

        pub const Orientation = enum {
            portrait,
            portrait_upside_down,
            landscape_left,
            landscape_right,
        };

        pub const StatusBarStyle = enum {
            default,
            light_content,
            dark_content,
        };

        pub const BackgroundMode = enum {
            audio,
            location,
            voip,
            fetch,
            remote_notification,
            processing,
        };
    };

    /// WKWebView Configuration
    pub const WebViewConfig = struct {
        allows_inline_media_playback: bool = true,
        allows_air_play: bool = true,
        allows_picture_in_picture: bool = true,
        media_types_requiring_user_action: MediaTypes = .none,
        data_detector_types: DataDetectorTypes = .all,
        suppresses_incremental_rendering: bool = false,
        allows_back_forward_navigation_gestures: bool = true,
        selection_granularity: SelectionGranularity = .dynamic,

        pub const MediaTypes = enum {
            none,
            audio,
            video,
            all,
        };

        pub const DataDetectorTypes = enum {
            none,
            phone_number,
            link,
            address,
            calendar_event,
            all,
        };

        pub const SelectionGranularity = enum {
            dynamic,
            character,
        };
    };

    /// Create iOS WebView
    pub fn createWebView(allocator: std.mem.Allocator, config: WebViewConfig) !*WKWebView {
        if (!@import("builtin").target.os.tag.isDarwin()) {
            return error.UnsupportedPlatform;
        }

        // Get WKWebView class
        const WKWebViewClass = objc.objc_getClass("WKWebView") orelse return error.ClassNotFound;

        // Create configuration: [[WKWebViewConfiguration alloc] init]
        const WKWebViewConfigurationClass = objc.objc_getClass("WKWebViewConfiguration") orelse return error.ClassNotFound;
        const configObj = try objc.allocInit(WKWebViewConfigurationClass);

        // Configure webview settings based on config
        if (config.allows_inline_media_playback) {
            const sel_setAllowsInlineMediaPlayback = objc.sel_registerName("setAllowsInlineMediaPlayback:") orelse return error.SelectorNotFound;
            const Fn = *const fn (objc.id, objc.SEL, bool) callconv(.c) void;
            const func: Fn = @ptrCast(&@import("objc_runtime.zig").objc.objc_msgSend);
            func(configObj, sel_setAllowsInlineMediaPlayback, true);
        }

        // Create CGRect for webview frame (full screen)
        const frame = objc.CGRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 0, .height = 0 }, // Will be set by layout
        };

        // Create WKWebView: [[WKWebView alloc] initWithFrame:configuration:]
        const sel_alloc = objc.sel_registerName("alloc") orelse return error.SelectorNotFound;
        const sel_initWithFrame = objc.sel_registerName("initWithFrame:configuration:") orelse return error.SelectorNotFound;

        const allocated = objc.msgSendId(WKWebViewClass, sel_alloc);
        const Fn = *const fn (objc.id, objc.SEL, objc.CGRect, objc.id) callconv(.c) objc.id;
        const func: Fn = @ptrCast(&@import("objc_runtime.zig").objc.objc_msgSend);
        // `objc.id` is `?*anyopaque`, so this is optional and a failed
        // `initWithFrame:configuration:` comes back as null. Unwrap once, here,
        // rather than `@ptrCast` the optional away further down — a cast cannot
        // discard optionality, and pretending otherwise is how a nil webview
        // would have reached callers as a live pointer.
        const webview = func(allocated, sel_initWithFrame, frame, configObj) orelse
            return error.WebViewCreationFailed;

        // Track the webview in memory manager.
        //
        // The size reported here is `@sizeOf(WKWebView)` as the runtime knows
        // it, not `@sizeOf(@TypeOf(webview))` — the latter is the width of a
        // pointer, which made every WKWebView in the accounting cost 8 bytes.
        if (getGlobalObjectManager()) |manager| {
            try manager.trackObject(webview, objc.classInstanceSize(WKWebViewClass), "WKWebView");
        }

        // Associate allocator with webview for cleanup
        const allocator_ptr = try allocator.create(std.mem.Allocator);
        allocator_ptr.* = allocator;
        objc.objc_setAssociatedObject(webview, @ptrCast(&allocator_key), allocator_ptr, objc.OBJC_ASSOCIATION_RETAIN);

        return @ptrCast(@alignCast(webview));
    }

    // Key for associated allocator
    var allocator_key: u8 = 0;

    /// Cleanup/dealloc WebView
    pub fn destroyWebView(webview: *WKWebView) void {
        if (!@import("builtin").target.os.tag.isDarwin()) {
            return;
        }

        const webview_ptr: *anyopaque = @ptrCast(@alignCast(webview));
        const addr = @intFromPtr(webview_ptr);

        // Get associated allocator and clean up
        const allocator_ptr = objc.objc_getAssociatedObject(webview_ptr, @ptrCast(&allocator_key));
        if (allocator_ptr) |alloc_ptr| {
            const allocator: *std.mem.Allocator = @ptrCast(@alignCast(alloc_ptr));
            allocator.destroy(allocator);
        }

        // Remove from memory tracking
        if (getGlobalObjectManager()) |manager| {
            manager.releaseObject(addr) catch |err| {
                std.log.debug("failed to release mobile object from tracking: {}", .{err});
            };
        }

        // Remove all associated objects
        objc.objc_removeAssociatedObjects(webview_ptr);

        // Call dealloc if needed (platform handles retain/release)
        const sel_release = objc.sel_registerName("release") orelse return;
        _ = sel_release;
    }

    /// Load URL in WebView
    pub fn loadURL(webview: *WKWebView, url: []const u8) !void {
        if (!@import("builtin").target.os.tag.isDarwin()) {
            return error.UnsupportedPlatform;
        }

        // Get associated allocator for temporary allocations
        const webview_ptr: *anyopaque = @ptrCast(@alignCast(webview));
        const allocator_ptr = objc.objc_getAssociatedObject(webview_ptr, @ptrCast(&allocator_key)) orelse return error.AllocatorNotFound;
        const allocator: *std.mem.Allocator = @ptrCast(@alignCast(allocator_ptr));

        // Create NSString from URL using helper
        const ns_string = try objc.createNSString(url, allocator.*);

        // Get NSURL class and create NSURL
        const NSURLClass = objc.objc_getClass("NSURL") orelse return error.ClassNotFound;
        const sel_URLWithString = objc.sel_registerName("URLWithString:") orelse return error.SelectorNotFound;
        const ns_url = objc.msgSendId1(NSURLClass, sel_URLWithString, ns_string);

        if (ns_url == null) {
            return error.InvalidURL;
        }

        // Create NSURLRequest
        const NSURLRequestClass = objc.objc_getClass("NSURLRequest") orelse return error.ClassNotFound;
        const sel_requestWithURL = objc.sel_registerName("requestWithURL:") orelse return error.SelectorNotFound;
        const request = objc.msgSendId1(NSURLRequestClass, sel_requestWithURL, ns_url);

        // Load request in webview
        const sel_loadRequest = objc.sel_registerName("loadRequest:") orelse return error.SelectorNotFound;
        _ = objc.msgSendId1(webview_ptr, sel_loadRequest, request);
    }

    /// Execute JavaScript
    pub fn evaluateJavaScript(webview: *WKWebView, script: []const u8, callback: ?*const fn ([]const u8) void) !void {
        const builtin = @import("builtin");
        const is_darwin = builtin.target.os.tag == .macos or builtin.target.os.tag == .ios or builtin.target.os.tag == .tvos or builtin.target.os.tag == .watchos;
        if (!is_darwin) {
            return error.UnsupportedPlatform;
        }

        // Get associated allocator
        const webview_ptr: *anyopaque = @ptrCast(@alignCast(webview));
        const allocator_ptr = objc.objc_getAssociatedObject(webview_ptr, @ptrCast(&allocator_key)) orelse return error.AllocatorNotFound;
        const allocator: *std.mem.Allocator = @ptrCast(@alignCast(allocator_ptr));

        // Create NSString from script
        const ns_script = try objc.createNSString(script, allocator.*);

        const sel_evaluateJavaScript = objc.sel_registerName("evaluateJavaScript:completionHandler:") orelse return error.SelectorNotFound;

        // A completion handler is not wired up yet, and asking for one is an
        // error rather than a silent drop.
        //
        // The block that used to live here did not work and could not have.
        // It was built on the stack and handed to an *asynchronous* API — the
        // comment beside it read "valid for duration of call", which is not
        // the property an async callee needs. `_Block_copy` copies the block
        // body but keeps the descriptor *pointer*, and that descriptor was
        // also a function local, so both were dead before WebKit ever invoked
        // them. Its `invoke` signature took `?objc.id`, which is `??*anyopaque`
        // and illegal under `callconv(.c)`; and the `callback` field it stored
        // had a different signature from this function's own parameter, so
        // even the assignment was a type error. None of that was ever noticed
        // because nothing reachable from the iOS exports called this function —
        // which is precisely what `test/ios_surface_test.zig` now prevents.
        //
        // Doing it correctly means a module-level block with static storage
        // (see `bridge_permissions.zig:131-164` for the shape that works) plus
        // a pending-request table so the reply can find its caller. That lands
        // with the dispatcher, not here.
        if (callback != null) return error.CompletionHandlerNotImplemented;

        // Passing nil for `completionHandler:` is legal and is what a
        // fire-and-forget evaluation wants.
        const Fn = *const fn (*anyopaque, objc.SEL, objc.id, ?*anyopaque) callconv(.c) void;
        const func: Fn = @ptrCast(&@import("objc_runtime.zig").objc.objc_msgSend);
        func(webview_ptr, sel_evaluateJavaScript, ns_script, null);
    }

    /// Handle Deep Links
    pub fn handleDeepLink(url: []const u8) !void {
        _ = url;
        // Parse and handle custom URL scheme
    }

    /// Request Permissions
    pub const Permission = enum {
        camera,
        microphone,
        location,
        photos,
        notifications,
        contacts,
        calendar,
        reminders,
    };

    pub const PermissionStatus = enum {
        not_determined,
        restricted,
        denied,
        authorized,
        limited, // For photos
    };

    // `checkPermissionStatus`, its five `statusFrom*AuthorizationStatus`
    // mappers, `requestPermission`, and `showAlert` used to sit between these
    // two enums. The types stay because they are the vocabulary; the functions
    // went because each was broken in a way no test could have caught, since
    // nothing ever called them:
    //
    //   - `requestPermission` took a `callback` and immediately did
    //     `_ = callback;`, then passed null as the completion handler to all
    //     five system calls. Permissions were write-only: the answer was never
    //     delivered to anyone, and Apple documents a null completion for
    //     `requestAccessForMediaType:` as undefined behaviour.
    //   - `checkPermissionStatus` returned `.not_determined` for notifications
    //     unconditionally, whatever the system actually held.
    //   - `showAlert` presented against `keyWindow`, deprecated since iOS 13
    //     and nil in any scene-based app — which is every app the templates
    //     generate. It also computed an auto-dismiss delay and discarded it,
    //     so the alert its own doc comment called self-dismissing never was.
    //
    // They return in the permissions phase, replies correlated by the
    // envelope's request id through a pending-request table rather than by a
    // callback pointer that nothing invokes.

    /// Haptic Feedback
    pub const HapticType = enum {
        selection,
        impact_light,
        impact_medium,
        impact_heavy,
        notification_success,
        notification_warning,
        notification_error,
    };

    pub fn triggerHaptic(haptic_type: HapticType) void {
        if (!@import("builtin").target.os.tag.isDarwin()) {
            return;
        }

        switch (haptic_type) {
            .selection => {
                const UISelectionFeedbackGeneratorClass = objc.objc_getClass("UISelectionFeedbackGenerator") orelse return;
                const sel_selectionChanged = objc.sel_registerName("selectionChanged") orelse return;

                // Create generator: [[UISelectionFeedbackGenerator alloc] init]
                const generator = objc.allocInit(UISelectionFeedbackGeneratorClass) catch return;

                // Trigger haptic: [generator selectionChanged]
                objc.msgSend(generator, sel_selectionChanged);

                // Release
                objc.release(generator);
            },
            .impact_light, .impact_medium, .impact_heavy => {
                const UIImpactFeedbackGeneratorClass = objc.objc_getClass("UIImpactFeedbackGenerator") orelse return;
                const sel_initWithStyle = objc.sel_registerName("initWithStyle:") orelse return;
                const sel_impactOccurred = objc.sel_registerName("impactOccurred") orelse return;

                // Determine impact style
                const style: i64 = switch (haptic_type) {
                    .impact_light => 0, // UIImpactFeedbackStyleLight
                    .impact_medium => 1, // UIImpactFeedbackStyleMedium
                    .impact_heavy => 2, // UIImpactFeedbackStyleHeavy
                    else => 1,
                };

                // Allocate generator
                const sel_alloc = objc.sel_registerName("alloc") orelse return;
                const allocated = objc.msgSendId(UIImpactFeedbackGeneratorClass, sel_alloc);

                // Initialize with style: [[UIImpactFeedbackGenerator alloc] initWithStyle:style]
                const Fn = *const fn (objc.id, objc.SEL, i64) callconv(.c) objc.id;
                const func: Fn = @ptrCast(&@import("objc_runtime.zig").objc.objc_msgSend);
                const generator = func(allocated, sel_initWithStyle, style);

                // Trigger haptic: [generator impactOccurred]
                objc.msgSend(generator, sel_impactOccurred);

                // Release
                objc.release(generator);
            },
            .notification_success, .notification_warning, .notification_error => {
                const UINotificationFeedbackGeneratorClass = objc.objc_getClass("UINotificationFeedbackGenerator") orelse return;
                const sel_notificationOccurred = objc.sel_registerName("notificationOccurred:") orelse return;

                // Create generator: [[UINotificationFeedbackGenerator alloc] init]
                const generator = objc.allocInit(UINotificationFeedbackGeneratorClass) catch return;

                // Determine notification type
                const feedbackType: i64 = switch (haptic_type) {
                    .notification_success => 0, // UINotificationFeedbackTypeSuccess
                    .notification_warning => 1, // UINotificationFeedbackTypeWarning
                    .notification_error => 2, // UINotificationFeedbackTypeError
                    else => 0,
                };

                // Trigger notification: [generator notificationOccurred:feedbackType]
                const Fn = *const fn (objc.id, objc.SEL, i64) callconv(.c) void;
                const func: Fn = @ptrCast(&@import("objc_runtime.zig").objc.objc_msgSend);
                func(generator, sel_notificationOccurred, feedbackType);

                // Release
                objc.release(generator);
            },
        }
    }

};

/// Android Native Integration
pub const Android = struct {
    pub const Activity = opaque {};
    pub const WebView = opaque {};
    pub const Context = opaque {};

    /// Android App Configuration
    pub const AppConfig = struct {
        package_name: []const u8,
        app_name: []const u8,
        version_name: []const u8,
        version_code: u32,
        min_sdk_version: u32 = 21,
        target_sdk_version: u32 = 34,
        supported_orientations: []const Orientation,
        hardware_acceleration: bool = true,
        large_heap: bool = false,
        uses_cleartext_traffic: bool = false,

        pub const Orientation = enum {
            portrait,
            landscape,
            sensor,
            user,
            behind,
            nosensor,
            unspecified,
        };
    };

    /// WebView Configuration
    pub const WebViewConfig = struct {
        javascript_enabled: bool = true,
        dom_storage_enabled: bool = true,
        database_enabled: bool = true,
        media_playback_requires_user_gesture: bool = false,
        allow_file_access: bool = false,
        allow_content_access: bool = false,
        mixed_content_mode: MixedContentMode = .never_allow,
        cache_mode: CacheMode = .default,

        pub const MixedContentMode = enum {
            always_allow,
            never_allow,
            compatibility_mode,
        };

        pub const CacheMode = enum {
            default,
            cache_else_network,
            no_cache,
            cache_only,
        };
    };

    /// JNI Environment (global reference, must be set by Java/Kotlin code)
    var jni_env: ?*jni.JNIEnv = null;

    pub fn setJNIEnv(env: *jni.JNIEnv) void {
        jni_env = env;
    }

    /// Create Android WebView
    pub fn createWebView(allocator: std.mem.Allocator, context: *Context, config: WebViewConfig) !*WebView {
        const builtin = @import("builtin");
        if (builtin.target.os.tag != .linux) {
            return error.UnsupportedPlatform;
        }

        const env = jni_env orelse return error.JNINotInitialized;

        // Get WebView class
        const webview_class_name = "android/webkit/WebView";
        const webview_class = try getJNIClass(env, webview_class_name);

        // Get WebView constructor
        const constructor_id = try getJNIMethod(env, webview_class, "<init>", "(Landroid/content/Context;)V");

        // Create WebView instance
        const webview_obj = jni.CallObjectMethod(env, context, constructor_id, .{});
        if (webview_obj == null) {
            return error.WebViewCreationFailed;
        }

        // Configure WebView settings
        const settings_method = try getJNIMethod(env, webview_class, "getSettings", "()Landroid/webkit/WebSettings;");
        const settings = jni.CallObjectMethod(env, webview_obj, settings_method, .{});

        if (settings != null) {
            const settings_class_name = "android/webkit/WebSettings";
            const settings_class = try getJNIClass(env, settings_class_name);

            // Enable JavaScript
            if (config.javascript_enabled) {
                const set_js_enabled = try getJNIMethod(env, settings_class, "setJavaScriptEnabled", "(Z)V");
                jni.CallVoidMethod(env, settings, set_js_enabled, .{@as(jni.jboolean, 1)});
            }

            // Enable DOM storage
            if (config.dom_storage_enabled) {
                const set_dom_storage = try getJNIMethod(env, settings_class, "setDomStorageEnabled", "(Z)V");
                jni.CallVoidMethod(env, settings, set_dom_storage, .{@as(jni.jboolean, 1)});
            }

            // Enable database
            if (config.database_enabled) {
                const set_database = try getJNIMethod(env, settings_class, "setDatabaseEnabled", "(Z)V");
                jni.CallVoidMethod(env, settings, set_database, .{@as(jni.jboolean, 1)});
            }
        }

        _ = allocator; // Will be used for cleanup tracking
        return @ptrCast(@alignCast(webview_obj));
    }

    /// Load URL in WebView
    pub fn loadURL(webview: *WebView, url: []const u8) !void {
        const builtin = @import("builtin");
        if (builtin.target.os.tag != .linux) {
            return error.UnsupportedPlatform;
        }

        const env = jni_env orelse return error.JNINotInitialized;

        // Get WebView class
        const webview_obj: jni.jobject = @ptrCast(@alignCast(webview));
        const webview_class = jni.GetObjectClass(env, webview_obj);

        // Get loadUrl method
        const load_url_method = try getJNIMethod(env, webview_class, "loadUrl", "(Ljava/lang/String;)V");

        // Convert URL to Java string (need null-terminated string)
        const allocator = std.heap.page_allocator;
        const url_z = try @import("memory.zig").dupeZ(allocator, u8, url);
        defer allocator.free(url_z);
        const url_jstring = jni.NewStringUTF(env, url_z.ptr);

        // Call loadUrl
        jni.CallVoidMethod(env, webview_obj, load_url_method, .{url_jstring});
    }

    /// Execute JavaScript
    pub fn evaluateJavaScript(webview: *WebView, script: []const u8, callback: ?*const fn ([]const u8) void) !void {
        const builtin = @import("builtin");
        if (builtin.target.os.tag != .linux) {
            return error.UnsupportedPlatform;
        }

        const env = jni_env orelse return error.JNINotInitialized;

        // Get WebView class
        const webview_obj: jni.jobject = @ptrCast(@alignCast(webview));
        const webview_class = jni.GetObjectClass(env, webview_obj);

        // Get evaluateJavascript method
        const eval_js_method = try getJNIMethod(env, webview_class, "evaluateJavascript", "(Ljava/lang/String;Landroid/webkit/ValueCallback;)V");

        // Convert script to Java string (need null-terminated string)
        const allocator = std.heap.page_allocator;
        const script_z = try @import("memory.zig").dupeZ(allocator, u8, script);
        defer allocator.free(script_z);
        const script_jstring = jni.NewStringUTF(env, script_z.ptr);

        // Create ValueCallback wrapper if callback is provided
        var value_callback: jni.jobject = null;
        if (callback) |cb| {
            // Store callback and get ID
            const callback_id = android_callbacks.storeJsCallback(cb);

            // Create CraftValueCallback instance (Java class that implements ValueCallback)
            // Java code: new CraftValueCallback(callbackId)
            const craft_callback_class = try getJNIClass(env, "app/craft/CraftValueCallback");
            const callback_init = try getJNIMethod(env, craft_callback_class, "<init>", "(I)V");

            // Allocate new object
            const alloc_method = try getJNIMethod(env, craft_callback_class, "<init>", "(I)V");
            _ = alloc_method;

            // Create instance with callback ID
            value_callback = jni.CallObjectMethod(env, craft_callback_class, callback_init, .{@as(jni.jint, @intCast(callback_id))});
        }

        // Call evaluateJavascript with the ValueCallback wrapper
        jni.CallVoidMethod(env, webview_obj, eval_js_method, .{ script_jstring, value_callback });
    }

    /// Helper function to get JNI class
    fn getJNIClass(env: *jni.JNIEnv, class_name: [:0]const u8) !jni.jclass {
        const cls = jni.FindClass(env, class_name.ptr);
        if (cls == null) {
            return error.ClassNotFound;
        }
        return cls;
    }

    /// Helper function to get JNI method
    fn getJNIMethod(env: *jni.JNIEnv, cls: jni.jclass, method_name: [:0]const u8, signature: [:0]const u8) !jni.jmethodID {
        const method_id = jni.GetMethodID(env, cls, method_name.ptr, signature.ptr);
        if (method_id == null) {
            return error.MethodNotFound;
        }
        return method_id;
    }

    /// Handle Deep Links
    pub fn handleDeepLink(intent_data: []const u8) !void {
        _ = intent_data;
        // Parse and handle Android Intent data
    }

    /// Request Permissions
    pub const Permission = enum {
        camera,
        microphone,
        location_fine,
        location_coarse,
        read_external_storage,
        write_external_storage,
        read_contacts,
        write_contacts,
        record_audio,
    };

    pub fn requestPermission(activity: *Activity, permission: Permission, callback: *const fn (bool) void) !void {
        const builtin = @import("builtin");
        if (builtin.target.os.tag != .linux) {
            return error.UnsupportedPlatform;
        }

        const env = jni_env orelse return error.JNINotInitialized;

        // Get ActivityCompat class
        const activity_compat_class = try getJNIClass(env, "androidx/core/app/ActivityCompat");

        // Convert permission to Android permission string
        const permission_str = switch (permission) {
            .camera => "android.permission.CAMERA",
            .microphone => "android.permission.RECORD_AUDIO",
            .location_fine => "android.permission.ACCESS_FINE_LOCATION",
            .location_coarse => "android.permission.ACCESS_COARSE_LOCATION",
            .read_external_storage => "android.permission.READ_EXTERNAL_STORAGE",
            .write_external_storage => "android.permission.WRITE_EXTERNAL_STORAGE",
            .read_contacts => "android.permission.READ_CONTACTS",
            .write_contacts => "android.permission.WRITE_CONTACTS",
            .record_audio => "android.permission.RECORD_AUDIO",
        };

        // Get requestPermissions method
        const request_permissions_method = try getJNIMethod(
            env,
            activity_compat_class,
            "requestPermissions",
            "(Landroid/app/Activity;[Ljava/lang/String;I)V",
        );

        // Create string array with single permission
        const allocator = std.heap.page_allocator;
        const permission_z = try @import("memory.zig").dupeZ(allocator, u8, permission_str);
        defer allocator.free(permission_z);
        const permission_jstring = jni.NewStringUTF(env, permission_z.ptr);

        // Use a unique request code based on permission type
        const request_code: u32 = 1001 + @backingInt(permission);

        // Store callback to be invoked in onRequestPermissionsResult
        if (callback) |cb| {
            android_callbacks.storePermissionCallback(request_code, cb);
        }

        // Call requestPermissions with unique request code
        const activity_obj: jni.jobject = @ptrCast(@alignCast(activity));
        jni.CallVoidMethod(env, activity_obj, request_permissions_method, .{ permission_jstring, @as(jni.jint, @intCast(request_code)) });
    }

    /// Vibration
    pub fn vibrate(context: *Context, duration_ms: u64) void {
        const builtin = @import("builtin");
        if (builtin.target.os.tag != .linux) {
            return;
        }

        const env = jni_env orelse return;

        // Get Vibrator service
        const context_obj: jni.jobject = @ptrCast(@alignCast(context));
        const context_class = jni.GetObjectClass(env, context_obj);

        const get_system_service_method = getJNIMethod(env, context_class, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;") catch return;

        // Get VIBRATOR_SERVICE constant
        const vibrator_service_str = jni.NewStringUTF(env, "vibrator");
        const vibrator_obj = jni.CallObjectMethod(env, context_obj, get_system_service_method, .{vibrator_service_str});

        if (vibrator_obj != null) {
            const vibrator_class = jni.GetObjectClass(env, vibrator_obj);

            // For Android 26+, use VibrationEffect
            const vibrate_method = getJNIMethod(env, vibrator_class, "vibrate", "(J)V") catch return;
            jni.CallVoidMethod(env, vibrator_obj, vibrate_method, .{@as(jni.jlong, @intCast(duration_ms))});
        }
    }

    /// Toast Notification
    pub fn showToast(context: *Context, message: []const u8, duration: ToastDuration) void {
        const builtin = @import("builtin");
        if (builtin.target.os.tag != .linux) {
            return;
        }

        const env = jni_env orelse return;

        // Get Toast class
        const toast_class = getJNIClass(env, "android/widget/Toast") catch return;

        // Get makeText method
        const make_text_method = getJNIMethod(
            env,
            toast_class,
            "makeText",
            "(Landroid/content/Context;Ljava/lang/CharSequence;I)Landroid/widget/Toast;",
        ) catch return;

        // Convert message to Java string (need null-terminated string)
        const allocator = std.heap.page_allocator;
        const message_z = @import("memory.zig").dupeZ(allocator, u8, message) catch return;
        defer allocator.free(message_z);
        const message_jstring = jni.NewStringUTF(env, message_z.ptr);

        // Convert duration
        const duration_int: jni.jint = switch (duration) {
            .short => 0, // Toast.LENGTH_SHORT
            .long => 1, // Toast.LENGTH_LONG
        };

        // Create toast
        const context_obj: jni.jobject = @ptrCast(@alignCast(context));
        const toast_obj = jni.CallObjectMethod(env, toast_class, make_text_method, .{ context_obj, message_jstring, duration_int });

        if (toast_obj != null) {
            // Show toast
            const toast_obj_class = jni.GetObjectClass(env, toast_obj);
            const show_method = getJNIMethod(env, toast_obj_class, "show", "()V") catch return;
            jni.CallVoidMethod(env, toast_obj, show_method, .{});
        }
    }

    pub const ToastDuration = enum {
        short,
        long,
    };
};

/// Cross-Platform Mobile Window
pub const MobileWindow = struct {
    platform: Platform,
    handle: *anyopaque,
    config: MobileConfig,
    allocator: std.mem.Allocator,

    pub const MobileConfig = struct {
        title: []const u8,
        initial_url: []const u8,
        user_agent: ?[]const u8 = null,
        enable_inspector: bool = false,
        orientation_lock: ?Orientation = null,
        safe_area_insets: bool = true,

        pub const Orientation = enum {
            portrait,
            landscape,
            any,
        };
    };

    pub fn init(allocator: std.mem.Allocator, config: MobileConfig) !MobileWindow {
        const platform = Platform.current();

        return MobileWindow{
            .platform = platform,
            .handle = undefined,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MobileWindow) void {
        _ = self;
        // Platform-specific cleanup
    }

    pub fn loadURL(self: *MobileWindow, url: []const u8) !void {
        switch (self.platform) {
            .ios => {
                const webview: *iOS.WKWebView = @ptrCast(@alignCast(self.handle));
                try iOS.loadURL(webview, url);
            },
            .android => {
                const webview: *Android.WebView = @ptrCast(@alignCast(self.handle));
                try Android.loadURL(webview, url);
            },
            .unknown => return error.UnsupportedPlatform,
        }
    }

    pub fn evaluateJavaScript(self: *MobileWindow, script: []const u8) !void {
        switch (self.platform) {
            .ios => {
                const webview: *iOS.WKWebView = @ptrCast(@alignCast(self.handle));
                try iOS.evaluateJavaScript(webview, script, null);
            },
            .android => {
                const webview: *Android.WebView = @ptrCast(@alignCast(self.handle));
                try Android.evaluateJavaScript(webview, script, null);
            },
            .unknown => return error.UnsupportedPlatform,
        }
    }

    pub fn setOrientation(self: *MobileWindow, orientation: MobileConfig.Orientation) !void {
        _ = self;
        _ = orientation;
        // Platform-specific orientation lock
    }

    pub fn vibrate(self: *MobileWindow, duration_ms: u64) void {
        _ = self;
        _ = duration_ms;
        // Platform-specific vibration
    }

    pub fn showToast(self: *MobileWindow, message: []const u8) void {
        _ = self;
        _ = message;
        // Platform-specific toast
    }
};

/// Mobile Device Information
pub const DeviceInfo = struct {
    platform: Platform,
    os_version: []const u8,
    device_model: []const u8,
    screen_width: u32,
    screen_height: u32,
    scale_factor: f32,
    is_tablet: bool,
    safe_area_insets: SafeAreaInsets,

    pub const SafeAreaInsets = struct {
        top: f32,
        bottom: f32,
        left: f32,
        right: f32,
    };

    pub fn get(allocator: std.mem.Allocator) !DeviceInfo {
        _ = allocator;
        // Would query device info from platform APIs
        return DeviceInfo{
            .platform = Platform.current(),
            .os_version = "0.0.0",
            .device_model = "Unknown",
            .screen_width = 375,
            .screen_height = 667,
            .scale_factor = 2.0,
            .is_tablet = false,
            .safe_area_insets = .{
                .top = 0,
                .bottom = 0,
                .left = 0,
                .right = 0,
            },
        };
    }
};

/// Mobile Lifecycle Events
pub const LifecycleEvent = enum {
    did_finish_launching,
    will_enter_foreground,
    did_become_active,
    will_resign_active,
    did_enter_background,
    will_terminate,
    memory_warning,
};

pub const LifecycleCallback = *const fn (LifecycleEvent) void;

pub const LifecycleManager = struct {
    callbacks: std.ArrayList(LifecycleCallback),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LifecycleManager {
        return LifecycleManager{
            .callbacks = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LifecycleManager) void {
        self.callbacks.deinit(self.allocator);
    }

    pub fn addCallback(self: *LifecycleManager, callback: LifecycleCallback) !void {
        try self.callbacks.append(self.allocator, callback);
    }

    pub fn triggerEvent(self: *LifecycleManager, event: LifecycleEvent) void {
        for (self.callbacks.items) |callback| {
            callback(event);
        }
    }
};

/// Mobile Storage
pub const Storage = struct {
    platform: Platform,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Storage {
        return Storage{
            .platform = Platform.current(),
            .allocator = allocator,
        };
    }

    pub fn getDocumentsDirectory(self: Storage) ![]const u8 {
        _ = self;
        // Platform-specific documents directory path
        return "";
    }

    pub fn getCacheDirectory(self: Storage) ![]const u8 {
        _ = self;
        // Platform-specific cache directory path
        return "";
    }

    pub fn getTemporaryDirectory(self: Storage) ![]const u8 {
        _ = self;
        // Platform-specific temp directory path
        return "";
    }
};

/// Mobile Networking
pub const NetworkStatus = enum {
    unknown,
    not_reachable,
    reachable_via_wifi,
    reachable_via_cellular,
};

pub const NetworkMonitor = struct {
    status: NetworkStatus,
    callbacks: std.ArrayList(*const fn (NetworkStatus) void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NetworkMonitor {
        return NetworkMonitor{
            .status = .unknown,
            .callbacks = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NetworkMonitor) void {
        self.callbacks.deinit(self.allocator);
    }

    pub fn startMonitoring(self: *NetworkMonitor) !void {
        _ = self;
        // Start platform-specific network monitoring
    }

    pub fn stopMonitoring(self: *NetworkMonitor) void {
        _ = self;
        // Stop network monitoring
    }

    pub fn onStatusChange(self: *NetworkMonitor, callback: *const fn (NetworkStatus) void) !void {
        try self.callbacks.append(self.allocator, callback);
    }

    pub fn getCurrentStatus(self: NetworkMonitor) NetworkStatus {
        return self.status;
    }
};
