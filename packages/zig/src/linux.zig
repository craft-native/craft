const std = @import("std");
const bridge_error = @import("bridge_error.zig");
const desktop_bridge_envelope = @import("desktop_bridge_envelope.zig");
const desktop_window_registry = @import("desktop_window_registry.zig");
const json_utils = @import("json_utils.zig");
const request_context = @import("request_context.zig");
const window_context = @import("window_context.zig");
const window_registry = @import("window_registry.zig");
const window_reply_target = @import("window_reply_target.zig");

// Linux implementation using GTK3 and WebKit2GTK 4.1.
// Requires: libgtk-3-dev, libwebkit2gtk-4.1-dev

// GTK and WebKit C bindings
pub extern "c" fn gtk_init(argc: ?*c_int, argv: ?*anyopaque) void;
pub extern "c" fn gtk_application_new(application_id: [*:0]const u8, flags: c_int) ?*anyopaque;
pub extern "c" fn g_application_run(app: *anyopaque, argc: c_int, argv: [*c][*c]u8) c_int;
pub extern "c" fn gtk_application_window_new(app: *anyopaque) *anyopaque;
pub extern "c" fn gtk_window_set_title(window: *anyopaque, title: [*:0]const u8) void;
pub extern "c" fn gtk_window_set_default_size(window: *anyopaque, width: c_int, height: c_int) void;
pub extern "c" fn gtk_window_present(window: *anyopaque) void;
pub extern "c" fn gtk_window_close(window: *anyopaque) void;
pub extern "c" fn gtk_window_set_decorated(window: *anyopaque, decorated: c_int) void;
pub extern "c" fn gtk_window_set_resizable(window: *anyopaque, resizable: c_int) void;
pub extern "c" fn gtk_window_fullscreen(window: *anyopaque) void;
pub extern "c" fn gtk_window_unfullscreen(window: *anyopaque) void;
pub extern "c" fn gtk_window_maximize(window: *anyopaque) void;
pub extern "c" fn gtk_window_unmaximize(window: *anyopaque) void;
pub extern "c" fn gtk_window_minimize(window: *anyopaque) void;
pub extern "c" fn gtk_widget_hide(widget: *anyopaque) void;
pub extern "c" fn gtk_widget_show(widget: *anyopaque) void;
pub extern "c" fn gtk_window_set_position(window: *anyopaque, x: c_int, y: c_int) void;

pub extern "c" fn webkit_web_view_new() *anyopaque;
pub extern "c" fn webkit_web_view_load_uri(webview: *anyopaque, uri: [*:0]const u8) void;
pub extern "c" fn webkit_web_view_load_html(webview: *anyopaque, html: [*:0]const u8, base_uri: [*:0]const u8) void;
pub extern "c" fn webkit_web_view_reload(webview: *anyopaque) void;
pub extern "c" fn webkit_web_view_get_settings(webview: *anyopaque) *anyopaque;
pub extern "c" fn webkit_settings_set_enable_developer_extras(settings: *anyopaque, enabled: c_int) void;
pub extern "c" fn webkit_settings_set_enable_webgl(settings: *anyopaque, enabled: c_int) void;
pub extern "c" fn webkit_settings_set_javascript_can_access_clipboard(settings: *anyopaque, enabled: c_int) void;
pub extern "c" fn webkit_settings_set_hardware_acceleration_policy(settings: *anyopaque, policy: c_int) void;
pub extern "c" fn webkit_settings_set_enable_javascript(settings: *anyopaque, enabled: c_int) void;
// Media stream (camera/microphone) support
pub extern "c" fn webkit_settings_set_enable_media_stream(settings: *anyopaque, enabled: c_int) void;
pub extern "c" fn webkit_settings_set_enable_mediasource(settings: *anyopaque, enabled: c_int) void;
pub extern "c" fn webkit_settings_set_enable_media_capabilities(settings: *anyopaque, enabled: c_int) void;
// Permission request handling
pub extern "c" fn webkit_permission_request_allow(request: *anyopaque) void;
pub extern "c" fn webkit_permission_request_deny(request: *anyopaque) void;

// Permission request type checking via GObject type system
pub extern "c" fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: c_ulong) c_int;
pub extern "c" fn webkit_user_media_permission_is_for_audio_device(request: *anyopaque) c_int;
pub extern "c" fn webkit_user_media_permission_is_for_video_device(request: *anyopaque) c_int;

// GObject type getters for permission request types
pub extern "c" fn webkit_user_media_permission_request_get_type() c_ulong;
pub extern "c" fn webkit_geolocation_permission_request_get_type() c_ulong;
pub extern "c" fn webkit_notification_permission_request_get_type() c_ulong;
pub extern "c" fn webkit_clipboard_permission_request_get_type() c_ulong;

// JavaScript execution
pub extern "c" fn webkit_web_view_run_javascript(
    webview: *anyopaque,
    script: [*:0]const u8,
    cancellable: ?*anyopaque,
    callback: ?*const fn (*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
) void;
pub extern "c" fn webkit_web_view_run_javascript_finish(
    webview: *anyopaque,
    result: *anyopaque,
    error_ptr: ?*anyopaque,
) *anyopaque;

// User content manager for injecting scripts
pub extern "c" fn webkit_web_view_get_user_content_manager(webview: *anyopaque) *anyopaque;
pub extern "c" fn webkit_user_script_new(
    source: [*:0]const u8,
    injected_frames: c_int,
    injection_time: c_int,
    allow_list: ?*anyopaque,
    block_list: ?*anyopaque,
) *anyopaque;
pub extern "c" fn webkit_user_content_manager_add_script(manager: *anyopaque, script: *anyopaque) void;
pub extern "c" fn webkit_user_content_manager_remove_all_scripts(manager: *anyopaque) void;
pub extern "c" fn webkit_user_content_manager_register_script_message_handler(manager: *anyopaque, name: [*:0]const u8) c_int;
pub extern "c" fn webkit_javascript_result_get_js_value(result: *anyopaque) *anyopaque;
pub extern "c" fn jsc_value_to_json(value: *anyopaque, indent: c_uint) ?[*:0]u8;

pub extern "c" fn gtk_container_add(container: *anyopaque, widget: *anyopaque) void;

pub extern "c" fn g_signal_connect_data(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: *const anyopaque,
    data: ?*anyopaque,
    destroy_data: ?*anyopaque,
    connect_flags: c_int,
) c_ulong;

/// Permission policy configuration - secure by default (deny all sensitive permissions)
pub const PermissionPolicy = struct {
    allow_camera: bool = false,
    allow_microphone: bool = false,
    allow_geolocation: bool = false,
    allow_notifications: bool = true,
    allow_clipboard: bool = true,
};

var permission_policy: PermissionPolicy = .{};

pub fn setPermissionPolicy(policy: PermissionPolicy) void {
    permission_policy = policy;
}

/// Permission request signal handler - checks permission type and respects policy
fn onPermissionRequest(webview: *anyopaque, request: *anyopaque, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = webview;
    _ = user_data;

    // Check if this is a user media (camera/microphone) permission request
    const user_media_type = webkit_user_media_permission_request_get_type();
    if (g_type_check_instance_is_a(request, user_media_type) != 0) {
        const is_audio = webkit_user_media_permission_is_for_audio_device(request) != 0;
        const is_video = webkit_user_media_permission_is_for_video_device(request) != 0;

        if (is_video and is_audio) {
            // Request for both camera and microphone
            if (permission_policy.allow_camera and permission_policy.allow_microphone) {
                std.debug.print("[Permission] Allowed: camera + microphone\n", .{});
                webkit_permission_request_allow(request);
            } else {
                std.debug.print("[Permission] Denied: camera + microphone (camera={}, mic={})\n", .{ permission_policy.allow_camera, permission_policy.allow_microphone });
                webkit_permission_request_deny(request);
            }
        } else if (is_video) {
            if (permission_policy.allow_camera) {
                std.debug.print("[Permission] Allowed: camera\n", .{});
                webkit_permission_request_allow(request);
            } else {
                std.debug.print("[Permission] Denied: camera\n", .{});
                webkit_permission_request_deny(request);
            }
        } else if (is_audio) {
            if (permission_policy.allow_microphone) {
                std.debug.print("[Permission] Allowed: microphone\n", .{});
                webkit_permission_request_allow(request);
            } else {
                std.debug.print("[Permission] Denied: microphone\n", .{});
                webkit_permission_request_deny(request);
            }
        } else {
            std.debug.print("[Permission] Denied: unknown media device\n", .{});
            webkit_permission_request_deny(request);
        }
        return 1;
    }

    // Check if this is a geolocation permission request
    const geolocation_type = webkit_geolocation_permission_request_get_type();
    if (g_type_check_instance_is_a(request, geolocation_type) != 0) {
        if (permission_policy.allow_geolocation) {
            std.debug.print("[Permission] Allowed: geolocation\n", .{});
            webkit_permission_request_allow(request);
        } else {
            std.debug.print("[Permission] Denied: geolocation\n", .{});
            webkit_permission_request_deny(request);
        }
        return 1;
    }

    // Check if this is a notification permission request
    const notification_type = webkit_notification_permission_request_get_type();
    if (g_type_check_instance_is_a(request, notification_type) != 0) {
        if (permission_policy.allow_notifications) {
            std.debug.print("[Permission] Allowed: notifications\n", .{});
            webkit_permission_request_allow(request);
        } else {
            std.debug.print("[Permission] Denied: notifications\n", .{});
            webkit_permission_request_deny(request);
        }
        return 1;
    }

    // Check if this is a clipboard permission request
    const clipboard_type = webkit_clipboard_permission_request_get_type();
    if (g_type_check_instance_is_a(request, clipboard_type) != 0) {
        if (permission_policy.allow_clipboard) {
            std.debug.print("[Permission] Allowed: clipboard\n", .{});
            webkit_permission_request_allow(request);
        } else {
            std.debug.print("[Permission] Denied: clipboard\n", .{});
            webkit_permission_request_deny(request);
        }
        return 1;
    }

    // Deny unknown permission types (secure by default)
    std.debug.print("[Permission] Denied: unknown permission type\n", .{});
    webkit_permission_request_deny(request);
    return 1;
}

// Multi-window registry
pub const WindowEntry = struct {
    id: u32,
    gtk_window: *anyopaque,
    webview: *anyopaque,
};

var desktop_windows: desktop_window_registry.Registry = .{};

pub fn getWindowById(id: u32) ?WindowEntry {
    const entry = desktop_windows.byId(id) orelse return null;
    return .{ .id = entry.id, .gtk_window = @ptrFromInt(entry.window), .webview = @ptrFromInt(entry.webview) };
}

pub fn getWindowCount() u32 {
    return @intCast(desktop_windows.count());
}

fn registerWindow(gtk_window: *anyopaque, webview: *anyopaque) ?u32 {
    return desktop_windows.remember(@intFromPtr(gtk_window), @intFromPtr(webview));
}

/// GTK emits destroy for titlebar closes as well as programmatic closes.
/// Forget the handle at actual teardown, so neither path leaves a stale
/// webview eligible for bridge replies.
fn onWindowDestroyed(widget: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    const entry = desktop_windows.forgetWindow(@intFromPtr(widget)) orelse return;
    window_registry.forgetOwner(entry.webview);
    window_registry.forget(entry.window);
}

/// WebKit supplies the WebView via signal user data; a page-supplied window id
/// is only a name to resolve after the native sender has been authenticated.
fn onScriptMessage(_: *anyopaque, result: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const sender = user_data orelse return;
    const entry = desktop_windows.byWebview(@intFromPtr(sender)) orelse return;
    const value = webkit_javascript_result_get_js_value(result);
    const json_z = jsc_value_to_json(value, 0) orelse return;
    defer g_free(@ptrCast(json_z));

    var envelope = desktop_bridge_envelope.parse(std.heap.c_allocator, std.mem.span(json_z)) catch return;
    defer envelope.deinit();
    window_context.push(entry.window, entry.webview);
    defer window_context.pop();
    request_context.push(envelope.request_id);
    defer request_context.pop();

    if (!std.mem.eql(u8, envelope.kind, "window")) {
        bridge_error.sendErrorToJS(std.heap.c_allocator, envelope.action, error.PlatformNotSupported);
        return;
    }
    handleWindowAction(envelope.action, envelope.data) catch |err| {
        bridge_error.sendErrorToJS(std.heap.c_allocator, envelope.action, bridge_error.fromHandlerError(err));
    };
}

fn namedWindowResult(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"name\":\"");
    try bridge_error.appendJsonEscaped(allocator, &json, name);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

fn openNamedWindow(action: []const u8, data: ?[]const u8) !void {
    const allocator = std.heap.c_allocator;
    const json = data orelse return error.MissingData;
    const explicit_name = try json_utils.getStringDecoded(allocator, json, "name");
    defer if (explicit_name) |name| allocator.free(name);
    const fallback_id = if (explicit_name == null)
        try json_utils.getStringDecoded(allocator, json, "id")
    else
        null;
    defer if (fallback_id) |name| allocator.free(name);
    const name = explicit_name orelse fallback_id orelse return error.InvalidParameter;
    if (name.len == 0 or name.len > window_registry.max_name or
        std.mem.eql(u8, name, "main") or std.mem.indexOfScalar(u8, name, 0) != null)
        return error.InvalidParameter;

    const url = try json_utils.getStringDecoded(allocator, json, "url");
    defer if (url) |text| allocator.free(text);
    const html = try json_utils.getStringDecoded(allocator, json, "html");
    defer if (html) |text| allocator.free(text);
    if (url == null and html == null) return error.InvalidParameter;
    const title = try json_utils.getStringDecoded(allocator, json, "title");
    defer if (title) |text| allocator.free(text);
    for ([_]?[]const u8{ url, html, title }) |value| {
        if (value) |text| if (std.mem.indexOfScalar(u8, text, 0) != null)
            return error.InvalidParameter;
    }

    // Allocate the response before creating native state. A failed allocation
    // must not leave a live window behind a rejected creation Promise.
    const result = try namedWindowResult(allocator, name);
    defer allocator.free(result);
    const owner = window_context.currentWebView() orelse return error.WebViewHandleNotSet;
    if (window_registry.byName(name)) |existing| {
        if (desktop_windows.byWindow(existing) == null) return error.WindowHandleNotSet;
        if (!window_registry.rememberNamedOwned(existing, name, owner)) return error.InvalidParameter;
        gtk_window_present(@ptrFromInt(existing));
        bridge_error.sendResultToJS(allocator, action, result);
        return;
    }

    const width = json_utils.getInt(u32, json, "width") orelse 800;
    const height = json_utils.getInt(u32, json, "height") orelse 600;
    if (width == 0 or height == 0 or width > @as(u32, std.math.maxInt(c_int)) or height > @as(u32, std.math.maxInt(c_int)))
        return error.InvalidParameter;
    var created = try Window.create(.{
        .title = title orelse name,
        .width = width,
        .height = height,
        .x = json_utils.getInt(i32, json, "x"),
        .y = json_utils.getInt(i32, json, "y"),
        .resizable = json_utils.getBool(json, "resizable") orelse true,
        .frameless = json_utils.getBool(json, "frameless") orelse false,
        .fullscreen = json_utils.getBool(json, "fullscreen") orelse false,
        .dev_tools = json_utils.getBool(json, "devTools") orelse false,
    });
    errdefer created.close();
    if (url) |text| try created.loadURL(text) else if (html) |text| try created.loadHTML(text);
    if (!window_registry.rememberNamedOwned(@intFromPtr(created.gtk_window), name, owner))
        return error.TooManyWindows;
    created.show();
    bridge_error.sendResultToJS(allocator, action, result);
}

fn targetWindow(data: ?[]const u8) !desktop_window_registry.Entry {
    if (data) |json| {
        const name = try json_utils.getStringDecoded(std.heap.c_allocator, json, "windowId");
        defer if (name) |text| std.heap.c_allocator.free(text);
        if (name) |text| {
            if (!std.mem.eql(u8, text, "main")) {
                const handle = window_registry.byName(text) orelse return error.NotFound;
                return desktop_windows.byWindow(handle) orelse error.NotFound;
            }
        }
    }
    return desktop_windows.byWindow(window_context.current() orelse return error.WindowHandleNotSet) orelse error.WindowHandleNotSet;
}

fn handleWindowAction(action: []const u8, data: ?[]const u8) !void {
    if (std.mem.eql(u8, action, "open") or std.mem.eql(u8, action, "create"))
        return openNamedWindow(action, data);

    const entry = try targetWindow(data);
    const window: *anyopaque = @ptrFromInt(entry.window);
    const webview: *anyopaque = @ptrFromInt(entry.webview);
    if (std.mem.eql(u8, action, "show") or std.mem.eql(u8, action, "focus")) {
        gtk_window_present(window);
    } else if (std.mem.eql(u8, action, "hide")) {
        gtk_widget_hide(window);
    } else if (std.mem.eql(u8, action, "close") or std.mem.eql(u8, action, "destroy")) {
        gtk_window_close(window);
    } else if (std.mem.eql(u8, action, "minimize")) {
        gtk_window_minimize(window);
    } else if (std.mem.eql(u8, action, "maximize")) {
        gtk_window_maximize(window);
    } else if (std.mem.eql(u8, action, "unmaximize") or std.mem.eql(u8, action, "restore")) {
        gtk_window_unmaximize(window);
    } else if (std.mem.eql(u8, action, "reload")) {
        webkit_web_view_reload(webview);
    } else if (std.mem.eql(u8, action, "setTitle")) {
        const json = data orelse return error.MissingData;
        const title = (try json_utils.getStringDecoded(std.heap.c_allocator, json, "title")) orelse return error.InvalidParameter;
        defer std.heap.c_allocator.free(title);
        if (std.mem.indexOfScalar(u8, title, 0) != null) return error.InvalidParameter;
        const title_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title);
        defer std.heap.c_allocator.free(title_z);
        gtk_window_set_title(window, title_z);
    } else if (std.mem.eql(u8, action, "setSize")) {
        const json = data orelse return error.MissingData;
        const width = json_utils.getInt(u32, json, "width") orelse return error.InvalidParameter;
        const height = json_utils.getInt(u32, json, "height") orelse return error.InvalidParameter;
        if (width == 0 or height == 0 or width > @as(u32, std.math.maxInt(c_int)) or height > @as(u32, std.math.maxInt(c_int)))
            return error.InvalidParameter;
        gtk_window_set_default_size(window, @intCast(width), @intCast(height));
    } else if (std.mem.eql(u8, action, "setPosition")) {
        const json = data orelse return error.MissingData;
        const x = json_utils.getInt(i32, json, "x") orelse return error.InvalidParameter;
        const y = json_utils.getInt(i32, json, "y") orelse return error.InvalidParameter;
        gtk_window_set_position(window, x, y);
    } else if (std.mem.eql(u8, action, "loadURL") or std.mem.eql(u8, action, "loadHTML")) {
        const json = data orelse return error.MissingData;
        const key: []const u8 = if (std.mem.eql(u8, action, "loadURL")) "url" else "html";
        const value = (try json_utils.getStringDecoded(std.heap.c_allocator, json, key)) orelse return error.InvalidParameter;
        defer std.heap.c_allocator.free(value);
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidParameter;
        const value_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, value);
        defer std.heap.c_allocator.free(value_z);
        if (std.mem.eql(u8, action, "loadURL")) webkit_web_view_load_uri(webview, value_z) else webkit_web_view_load_html(webview, value_z, "");
    } else {
        return error.PlatformNotSupported;
    }
}

// Application state
var app_instance: ?*anyopaque = null;

pub const WindowStyle = struct {
    frameless: bool = false,
    transparent: bool = false,
    always_on_top: bool = false,
    resizable: bool = true,
    closable: bool = true,
    miniaturizable: bool = true,
    fullscreen: bool = false,
    x: ?i32 = null,
    y: ?i32 = null,
    dark_mode: ?bool = null,
    enable_hot_reload: bool = false,
    dev_tools: bool = true,
    // Permission policy fields
    allow_camera: bool = false,
    allow_microphone: bool = false,
    allow_geolocation: bool = false,
    allow_notifications: bool = true,
    allow_clipboard: bool = true,
};

pub const Window = struct {
    id: u32,
    gtk_window: *anyopaque,
    webview: *anyopaque,
    title: []const u8,
    width: u32,
    height: u32,
    x: i32,
    y: i32,

    pub fn create(options: @import("api.zig").WindowOptions) !Window {
        // Initialize GTK if not already done
        if (app_instance == null) {
            gtk_init(null, null);
            app_instance = gtk_application_new("com.craft.app", 0);
        }

        const window = gtk_application_window_new(app_instance.?);
        errdefer gtk_window_close(window);

        // Create WebView
        const webview = webkit_web_view_new();
        const manager = webkit_web_view_get_user_content_manager(webview);
        // Connect before registration: WebKit can emit a page message as soon
        // as the injected document-start API becomes available.
        if (g_signal_connect_data(manager, "script-message-received::craft", @ptrCast(&onScriptMessage), webview, null, 0) == 0 or
            webkit_user_content_manager_register_script_message_handler(manager, "craft") == 0)
            return error.SignalConnectionFailed;

        // Configure WebView settings
        const settings = webkit_web_view_get_settings(webview);
        webkit_settings_set_enable_developer_extras(settings, if (options.dev_tools) 1 else 0);
        webkit_settings_set_enable_webgl(settings, 1);
        webkit_settings_set_javascript_can_access_clipboard(settings, 1);

        // Enable camera and microphone access (getUserMedia)
        webkit_settings_set_enable_media_stream(settings, 1);
        webkit_settings_set_enable_mediasource(settings, 1);
        webkit_settings_set_enable_media_capabilities(settings, 1);

        // Configure permission policy from window options
        setPermissionPolicy(.{
            .allow_camera = options.allow_camera,
            .allow_microphone = options.allow_microphone,
            .allow_geolocation = options.allow_geolocation,
            .allow_notifications = options.allow_notifications,
            .allow_clipboard = options.allow_clipboard,
        });

        // Connect permission-request signal with policy-based handler
        _ = g_signal_connect_data(
            webview,
            "permission-request",
            @ptrCast(&onPermissionRequest),
            null,
            null,
            0,
        );
        std.debug.print("[Permission] Linux WebView configured (camera={}, mic={}, geo={}, notify={}, clip={})\n", .{
            options.allow_camera,
            options.allow_microphone,
            options.allow_geolocation,
            options.allow_notifications,
            options.allow_clipboard,
        });

        // Set window properties
        const title_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, options.title);
        defer std.heap.c_allocator.free(title_z);
        gtk_window_set_title(window, title_z);

        gtk_window_set_default_size(window, @intCast(options.width), @intCast(options.height));

        // Apply window style
        if (!options.frameless) {
            gtk_window_set_decorated(window, 1);
        } else {
            gtk_window_set_decorated(window, 0);
        }

        gtk_window_set_resizable(window, if (options.resizable) 1 else 0);

        if (options.fullscreen) {
            gtk_window_fullscreen(window);
        }

        // Position window if specified
        const x: i32 = options.x orelse 100;
        const y: i32 = options.y orelse 100;
        if (options.x != null and options.y != null) {
            gtk_window_set_position(window, @intCast(x), @intCast(y));
        }

        // Add WebView to window
        gtk_container_add(window, webview);

        // Register window in the multi-window registry
        const window_id = registerWindow(window, webview) orelse {
            return error.TooManyWindows;
        };
        if (g_signal_connect_data(window, "destroy", @ptrCast(&onWindowDestroyed), null, null, 0) == 0) {
            _ = desktop_windows.forgetWindow(@intFromPtr(window));
            return error.SignalConnectionFailed;
        }

        var created = Window{
            .id = window_id,
            .gtk_window = window,
            .webview = webview,
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .x = x,
            .y = y,
        };
        // Register the page API before any load. The user-content manager
        // reapplies this document-start script after navigation too.
        try created.injectScript(@embedFile("js/craft-bridge.js"));
        return created;
    }

    pub fn show(self: *Window) void {
        gtk_widget_show(self.gtk_window);
        gtk_window_present(self.gtk_window);
    }

    pub fn hide(self: *Window) void {
        gtk_widget_hide(self.gtk_window);
    }

    pub fn close(self: *Window) void {
        // The destroy signal unregisters only after GTK actually closes it.
        const live = desktop_windows.byId(self.id) orelse return;
        if (live.window != @intFromPtr(self.gtk_window)) return;
        gtk_window_close(self.gtk_window);
    }

    pub fn setSize(self: *Window, width: u32, height: u32) void {
        gtk_window_set_default_size(self.gtk_window, @intCast(width), @intCast(height));
    }

    pub fn setPosition(self: *Window, x: i32, y: i32) void {
        gtk_window_set_position(self.gtk_window, @intCast(x), @intCast(y));
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const title_z = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title) catch return;
        defer std.heap.c_allocator.free(title_z);
        gtk_window_set_title(self.gtk_window, title_z);
    }

    pub fn loadURL(self: *Window, url: []const u8) !void {
        const url_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, url);
        defer std.heap.c_allocator.free(url_z);
        webkit_web_view_load_uri(self.webview, url_z);
    }

    pub fn loadHTML(self: *Window, html: []const u8) !void {
        const html_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, html);
        defer std.heap.c_allocator.free(html_z);
        webkit_web_view_load_html(self.webview, html_z, "");
    }

    pub fn maximize(self: *Window) void {
        gtk_window_maximize(self.gtk_window);
    }

    pub fn minimize(self: *Window) void {
        gtk_window_minimize(self.gtk_window);
    }

    pub fn setFullscreen(self: *Window, fullscreen: bool) void {
        if (fullscreen) {
            gtk_window_fullscreen(self.gtk_window);
        } else {
            gtk_window_unfullscreen(self.gtk_window);
        }
    }

    pub fn executeJavaScript(self: *Window, script: []const u8) !void {
        const script_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, script);
        defer std.heap.c_allocator.free(script_z);
        webkit_web_view_run_javascript(self.webview, script_z, null, null, null);
    }

    pub fn injectScript(self: *Window, script: []const u8) !void {
        if (std.mem.indexOfScalar(u8, script, 0) != null) return error.InvalidScript;
        const script_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, script);
        defer std.heap.c_allocator.free(script_z);

        const content_manager = webkit_web_view_get_user_content_manager(self.webview);
        // WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES = 0
        // WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START = 0
        const user_script = webkit_user_script_new(script_z, 0, 0, null, null);
        webkit_user_content_manager_add_script(content_manager, user_script);
    }

    pub fn clearInjectedScripts(self: *Window) void {
        const content_manager = webkit_web_view_get_user_content_manager(self.webview);
        webkit_user_content_manager_remove_all_scripts(content_manager);
    }

    pub fn enableGPUAcceleration(self: *Window, enable: bool) void {
        const settings = webkit_web_view_get_settings(self.webview);
        // WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS = 2
        // WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER = 1
        webkit_settings_set_hardware_acceleration_policy(settings, if (enable) 2 else 1);
    }
};

pub const App = struct {
    pub fn run() !void {
        if (app_instance) |app| {
            _ = g_application_run(app, 0, undefined);
        }
    }

    pub fn quit() void {
        // GTK will handle quit via signal
    }
};

/// Evaluate JavaScript in the page that sent the current bridge message.
/// Native callers without a sender continue to use the latest live window.
pub fn evalJS(script: []const u8) !void {
    var handles: [desktop_window_registry.capacity]usize = undefined;
    const live = desktop_windows.liveWebviews(&handles);
    const latest = desktop_windows.latest();
    const target = window_reply_target.select(live, window_context.currentWebView(), if (latest) |entry| entry.webview else null) orelse
        return error.NoWebView;
    const script_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, script);
    defer std.heap.c_allocator.free(script_z);
    webkit_web_view_run_javascript(@ptrFromInt(target), script_z, null, null, null);
}

// Legacy API compatibility
pub fn createWindow(title: []const u8, width: u32, height: u32, html: []const u8) !*anyopaque {
    var window = try Window.create(.{
        .title = title,
        .width = width,
        .height = height,
    });
    try window.loadHTML(html);
    window.show();
    return window.gtk_window;
}

pub fn createWindowWithURL(title: []const u8, width: u32, height: u32, url: []const u8, style: WindowStyle) !*anyopaque {
    var window = try Window.create(.{
        .title = title,
        .width = width,
        .height = height,
        .x = style.x,
        .y = style.y,
        .resizable = style.resizable,
        .frameless = style.frameless,
        .transparent = style.transparent,
        .fullscreen = style.fullscreen,
        .dark_mode = style.dark_mode,
        .dev_tools = style.dev_tools,
        .allow_camera = style.allow_camera,
        .allow_microphone = style.allow_microphone,
        .allow_geolocation = style.allow_geolocation,
        .allow_notifications = style.allow_notifications,
        .allow_clipboard = style.allow_clipboard,
    });
    try window.loadURL(url);
    window.show();
    return window.gtk_window;
}

pub fn runApp() void {
    App.run() catch |err| {
        std.debug.print("Error running GTK app: {}\n", .{err});
    };
}

// Notifications using libnotify
pub extern "c" fn notify_init(app_name: [*:0]const u8) c_int;
pub extern "c" fn notify_notification_new(summary: [*c]const u8, body: [*c]const u8, icon: [*c]const u8) *anyopaque;
pub extern "c" fn notify_notification_show(notification: *anyopaque, err: ?*anyopaque) c_int;

pub fn showNotification(title: []const u8, message: []const u8) !void {
    const title_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title);
    defer std.heap.c_allocator.free(title_z);
    const message_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, message);
    defer std.heap.c_allocator.free(message_z);

    _ = notify_init("Craft");
    const notification = notify_notification_new(title_z, message_z, "");
    _ = notify_notification_show(notification, null);
}

// Clipboard using GDK (works on both X11 and Wayland)
pub extern "c" fn gdk_display_get_default() ?*anyopaque;
pub extern "c" fn gdk_display_get_clipboard(display: *anyopaque) ?*anyopaque;
pub extern "c" fn gdk_clipboard_set_text(clipboard: *anyopaque, text: [*:0]const u8) void;
pub extern "c" fn gdk_clipboard_read_text_async(
    clipboard: *anyopaque,
    cancellable: ?*anyopaque,
    callback: ?*const fn (*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
) void;

pub fn setClipboard(text: []const u8) !void {
    const text_z = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, text);
    defer std.heap.c_allocator.free(text_z);

    const display = gdk_display_get_default() orelse return error.NoDisplay;
    const clipboard = gdk_display_get_clipboard(display) orelse return error.NoClipboard;
    gdk_clipboard_set_text(clipboard, text_z);
}

// GDK async read completion extern
pub extern "c" fn gdk_clipboard_read_text_finish(
    clipboard: *anyopaque,
    result: *anyopaque,
    error_ptr: ?*?*anyopaque,
) ?[*:0]const u8;

pub extern "c" fn g_free(mem: ?*anyopaque) void;

// Clipboard read: tries xclip first, then xsel as fallback.
// Note: GDK clipboard read is async-only (gdk_clipboard_read_text_async),
// so we use subprocess tools for synchronous reads. The write path uses
// GDK directly since gdk_clipboard_set_text is synchronous.
pub fn getClipboard(allocator: std.mem.Allocator) ![]u8 {
    // Try using xclip first (most common on Linux)
    {
        const argv = [_][]const u8{
            "xclip",
            "-selection",
            "clipboard",
            "-o",
        };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch |err| {
            std.debug.print("[Clipboard] xclip spawn failed: {}\n", .{err});
            // Continue to xsel fallback
        };

        if (child.stdout) |stdout| {
            const result = stdout.reader().readAllAlloc(allocator, 1024 * 1024) catch {
                _ = child.wait() catch |err| {
                    std.log.debug("xclip wait failed during clipboard read: {}", .{err});
                };
                return try allocator.dupe(u8, "");
            };
            _ = child.wait() catch |err| {
                std.log.debug("xclip wait failed after clipboard read: {}", .{err});
            };
            if (result.len > 0) {
                std.debug.print("[Clipboard] Read via xclip\n", .{});
                return result;
            }
            allocator.free(result);
        }
    }

    // Fallback to xsel
    {
        const argv = [_][]const u8{
            "xsel",
            "--clipboard",
            "--output",
        };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch |err| {
            std.debug.print("[Clipboard] xsel spawn failed: {}\n", .{err});
            return try allocator.dupe(u8, "");
        };

        if (child.stdout) |stdout| {
            const result = stdout.reader().readAllAlloc(allocator, 1024 * 1024) catch {
                _ = child.wait() catch |err| {
                    std.log.debug("xsel wait failed during clipboard read: {}", .{err});
                };
                return try allocator.dupe(u8, "");
            };
            _ = child.wait() catch |err| {
                std.log.debug("xsel wait failed after clipboard read: {}", .{err});
            };
            if (result.len > 0) {
                std.debug.print("[Clipboard] Read via xsel\n", .{});
                return result;
            }
            allocator.free(result);
        }
    }

    // If neither worked, return empty
    return try allocator.dupe(u8, "");
}
