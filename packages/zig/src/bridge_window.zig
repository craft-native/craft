const std = @import("std");
const builtin = @import("builtin");
const color_parse = @import("color.zig");
const bridge_error = @import("bridge_error.zig");
const logging = @import("logging.zig");
const json_utils = @import("json_utils.zig");
const window_context = @import("window_context.zig");
const window_registry = @import("window_registry.zig");

const BridgeError = bridge_error.BridgeError;
const log = logging.window;

fn formatOpenResult(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"name\":\"");
    try bridge_error.appendJsonEscaped(allocator, &json, name);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

/// Bridge handler for window control messages from JavaScript
pub const WindowBridge = struct {
    allocator: std.mem.Allocator,
    window_handle: ?*anyopaque = null,
    webview_handle: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn setWindowHandle(self: *Self, handle: *anyopaque) void {
        self.window_handle = handle;
    }

    pub fn setWebViewHandle(self: *Self, handle: *anyopaque) void {
        self.webview_handle = handle;
    }

    /// Handle window-related messages from JavaScript
    /// action: the action name, data: optional JSON data string
    pub fn handleMessage(self: *Self, action: []const u8) !void {
        self.handleMessageWithData(action, null) catch |err| {
            self.reportError(action, err);
        };
    }

    /// Report error to JavaScript and log
    fn reportError(self: *Self, action: []const u8, err: anyerror) void {
        const bridge_err: BridgeError = switch (err) {
            BridgeError.WindowHandleNotSet => BridgeError.WindowHandleNotSet,
            BridgeError.WebViewHandleNotSet => BridgeError.WebViewHandleNotSet,
            BridgeError.MissingData => BridgeError.MissingData,
            BridgeError.InvalidJSON => BridgeError.InvalidJSON,
            BridgeError.InvalidParameter => BridgeError.InvalidParameter,
            else => BridgeError.NativeCallFailed,
        };
        bridge_error.sendErrorToJS(self.allocator, action, bridge_err);
    }

    pub fn handleMessageWithData(self: *Self, action: []const u8, data: ?[]const u8) !void {
        if (std.mem.eql(u8, action, "show")) {
            try self.show(data);
        } else if (std.mem.eql(u8, action, "hide")) {
            try self.hide(data);
        } else if (std.mem.eql(u8, action, "toggle")) {
            try self.toggle(data);
        } else if (std.mem.eql(u8, action, "focus")) {
            try self.focus(data);
        } else if (std.mem.eql(u8, action, "blur")) {
            try self.blur(data);
        } else if (std.mem.eql(u8, action, "minimize")) {
            try self.minimize(data);
        } else if (std.mem.eql(u8, action, "maximize")) {
            try self.maximize(data);
        } else if (std.mem.eql(u8, action, "unmaximize")) {
            try self.unmaximize(data);
        } else if (std.mem.eql(u8, action, "restore")) {
            try self.restore(data);
        } else if (std.mem.eql(u8, action, "close")) {
            try self.close(data);
        } else if (std.mem.eql(u8, action, "center")) {
            try self.center(data);
        } else if (std.mem.eql(u8, action, "toggleFullscreen")) {
            try self.toggleFullscreen(data);
        } else if (std.mem.eql(u8, action, "setFullscreen")) {
            try self.setFullscreen(data);
        } else if (std.mem.eql(u8, action, "setSize")) {
            try self.setSize(data);
        } else if (std.mem.eql(u8, action, "setPosition")) {
            try self.setPosition(data);
        } else if (std.mem.eql(u8, action, "moveBy")) {
            try self.moveBy(data);
        } else if (std.mem.eql(u8, action, "setBounds")) {
            try self.setBounds(data);
        } else if (std.mem.eql(u8, action, "setTitle")) {
            try self.setTitle(data);
        } else if (std.mem.eql(u8, action, "getTitle")) {
            try self.getTitle(data);
        } else if (std.mem.eql(u8, action, "getSize")) {
            try self.getSize(data);
        } else if (std.mem.eql(u8, action, "getPosition")) {
            try self.getPosition(data);
        } else if (std.mem.eql(u8, action, "getBounds")) {
            try self.getBounds(data);
        } else if (std.mem.eql(u8, action, "isAlwaysOnTop")) {
            try self.isAlwaysOnTop(data);
        } else if (std.mem.eql(u8, action, "isResizable")) {
            try self.isResizable(data);
        } else if (std.mem.eql(u8, action, "isMovable")) {
            try self.isMovable(data);
        } else if (std.mem.eql(u8, action, "getOpacity")) {
            try self.getOpacity(data);
        } else if (std.mem.eql(u8, action, "getState")) {
            try self.getState(data);
        } else if (std.mem.eql(u8, action, "getFocused")) {
            try self.getFocused();
        } else if (std.mem.eql(u8, action, "loadHTML")) {
            try self.loadHTML(data);
        } else if (std.mem.eql(u8, action, "loadURL")) {
            try self.loadURL(data);
        } else if (std.mem.eql(u8, action, "reload")) {
            try self.reload(data);
        } else if (std.mem.eql(u8, action, "setAppearance")) {
            try self.setAppearance(data);
        } else if (std.mem.eql(u8, action, "setVibrancy")) {
            try self.setVibrancy(data);
        } else if (std.mem.eql(u8, action, "setWebSidebarCollapsed")) {
            try self.setWebSidebarCollapsed(data);
        } else if (std.mem.eql(u8, action, "setAlwaysOnTop")) {
            try self.setAlwaysOnTop(data);
        } else if (std.mem.eql(u8, action, "setOpacity")) {
            try self.setOpacity(data);
        } else if (std.mem.eql(u8, action, "setResizable")) {
            try self.setResizable(data);
        } else if (std.mem.eql(u8, action, "setBackgroundColor")) {
            try self.setBackgroundColor(data);
        } else if (std.mem.eql(u8, action, "setMinSize") or std.mem.eql(u8, action, "setMinimumSize")) {
            try self.setMinSize(data);
        } else if (std.mem.eql(u8, action, "setMaxSize") or std.mem.eql(u8, action, "setMaximumSize")) {
            try self.setMaxSize(data);
        } else if (std.mem.eql(u8, action, "setMovable")) {
            try self.setMovable(data);
        } else if (std.mem.eql(u8, action, "startDrag")) {
            try self.startDrag(data);
        } else if (std.mem.eql(u8, action, "setHasShadow")) {
            try self.setHasShadow(data);
        } else if (std.mem.eql(u8, action, "setWindowLevel")) {
            try self.setWindowLevel(data);
        } else if (std.mem.eql(u8, action, "setAspectRatio")) {
            try self.setAspectRatio(data);
        } else if (std.mem.eql(u8, action, "flashFrame")) {
            try self.flashFrame(data);
        } else if (std.mem.eql(u8, action, "setProgressBar")) {
            try self.setProgressBar(data);
        } else if (std.mem.eql(u8, action, "open") or std.mem.eql(u8, action, "create")) {
            // `create` is what the TypeScript SDK's `windows.create()` has
            // always sent, to a host that had no handler for it. Same action.
            try self.open(data);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// The window this action applies to.
    ///
    /// The window the message came from, when there is one — the dispatcher
    /// reads it off the `WKScriptMessage`, so it is the sender's own window
    /// and not something the page asserts. `self.window_handle` is the window
    /// craft was started with, and stays the answer for everything that does
    /// not arrive as a message: a menu item, a native callback, an app that
    /// only ever has one window.
    ///
    /// Before this, every action used that one handle. With a second window
    /// open, `craft.window.close()` from the Settings page closed the main
    /// window — the bridge had no way of knowing who was asking.
    fn requireWindowHandle(self: *Self, data: ?[]const u8) BridgeError!*anyopaque {
        if (data) |json_data| {
            if (json_utils.getString(json_data, "windowId")) |name| {
                // `main` means "the page this SDK instance is running in".
                // Every page constructs its local WindowManager that way, so
                // resolving it through the registry would incorrectly send a
                // child page back to the process's first window.
                if (!std.mem.eql(u8, name, "main")) {
                    const named = window_registry.byName(name) orelse
                        return BridgeError.InvalidParameter;
                    return @ptrFromInt(named);
                }
            }
        }
        if (window_context.current()) |sender| {
            return @ptrFromInt(sender);
        }
        return self.window_handle orelse BridgeError.WindowHandleNotSet;
    }

    /// The webview this action applies to.
    ///
    /// Exactly parallel to `requireWindowHandle`: a page-driven action belongs
    /// to the webview that posted it. The stored handle is only the fallback
    /// for native callers and the original single-window path. Without the
    /// sender context, `reload()` in a secondary window reloads whichever
    /// webview happened to initialise the process-global bridge first.
    fn requireWebViewHandle(self: *Self, data: ?[]const u8) BridgeError!*anyopaque {
        if (data) |json_data| {
            if (json_utils.getString(json_data, "windowId")) |name| {
                if (!std.mem.eql(u8, name, "main")) {
                    const window = window_registry.byName(name) orelse
                        return BridgeError.InvalidParameter;
                    if (builtin.os.tag == .macos) {
                        const macos = @import("macos.zig");
                        const maybe_webview = macos.webViewForWindow(@ptrFromInt(window)) orelse
                            return BridgeError.WebViewHandleNotSet;
                        const webview = maybe_webview orelse
                            return BridgeError.WebViewHandleNotSet;
                        return webview;
                    }
                    return BridgeError.WebViewHandleNotSet;
                }
            }
        }
        if (window_context.currentWebView()) |sender| {
            return @ptrFromInt(sender);
        }
        return self.webview_handle orelse BridgeError.WebViewHandleNotSet;
    }

    /// Open a second window, or bring forward the one already open by that name.
    ///
    /// The name is the argument that matters. Craft's window actions have
    /// always addressed "the" window, which is why this action did not exist:
    /// a page could not have said which of two windows it meant. Naming the
    /// window at the moment it is opened answers that for the only caller that
    /// needs to — the one that opens it — and makes a second `open` idempotent
    /// rather than a second window, which is what every Mac app's Cmd+, does.
    ///
    /// Style is the same vocabulary the CLI takes, so a window opened from the
    /// page can be the same kind of window as the one craft was started with:
    /// hidden titlebar, a native material behind the sidebar span or the whole
    /// view. Without that a Settings window would be the one surface in the
    /// app sitting on plain white.
    fn open(self: *Self, data: ?[]const u8) !void {
        const json_data = data orelse return BridgeError.MissingData;

        // `id` is what the TypeScript SDK calls it; `name` is what it is.
        const name = json_utils.getString(json_data, "name") orelse
            json_utils.getString(json_data, "id") orelse
            return BridgeError.InvalidParameter;

        const url = json_utils.getString(json_data, "url");
        const html = json_utils.getString(json_data, "html");
        if (url == null and html == null) return BridgeError.InvalidParameter;

        if (builtin.os.tag != .macos) return BridgeError.NativeCallFailed;

        const macos = @import("macos.zig");

        const style: macos.WindowStyle = .{
            .frameless = json_utils.getBool(json_data, "frameless") orelse false,
            .transparent = json_utils.getBool(json_data, "transparent") orelse false,
            .resizable = json_utils.getBool(json_data, "resizable") orelse true,
            .closable = json_utils.getBool(json_data, "closable") orelse true,
            .miniaturizable = json_utils.getBool(json_data, "minimizable") orelse true,
            .always_on_top = json_utils.getBool(json_data, "alwaysOnTop") orelse false,
            .fullscreen = json_utils.getBool(json_data, "fullscreen") orelse false,
            .titlebar_hidden = json_utils.getBool(json_data, "titlebarHidden") orelse false,
            .web_sidebar_material = json_utils.getBool(json_data, "webSidebarMaterial") orelse false,
            .web_window_material = json_utils.getBool(json_data, "webWindowMaterial") orelse false,
            .web_sidebar_width = json_utils.getInt(u32, json_data, "webSidebarWidth") orelse 286,
            .web_sidebar_material_opacity = json_utils.getFloat(f64, json_data, "webSidebarMaterialOpacity") orelse 0.78,
            // Craft's own row beside the window buttons — the sidebar toggle
            // and two history arrows. A page with its own history row turns it
            // off rather than showing two sets of arrows that disagree.
            .web_chrome_controls = json_utils.getBool(json_data, "chromeControls") orelse true,
            // A second window that keeps preferences has to share the first
            // window's store, or it writes them where nothing else can read
            // them.
            .persistent_storage = json_utils.getBool(json_data, "persistentStorage") orelse false,
            // The inspector follows the window that opened it: an app built
            // with `--no-devtools` should not grow a right-click Inspect
            // Element by opening its own Settings.
            .dev_tools = json_utils.getBool(json_data, "devTools") orelse false,
            .x = json_utils.getInt(i32, json_data, "x"),
            .y = json_utils.getInt(i32, json_data, "y"),
        };

        const window = macos.openNamedWindow(.{
            .name = name,
            .title = json_utils.getString(json_data, "title") orelse name,
            .url = url,
            .html = html,
            .width = json_utils.getInt(u32, json_data, "width") orelse 800,
            .height = json_utils.getInt(u32, json_data, "height") orelse 600,
            .style = style,
        }) catch return BridgeError.NativeCallFailed;

        // A floor on the size, so a window with a fixed-width sidebar cannot be
        // dragged narrower than the sidebar it contains.
        const min_width = json_utils.getInt(u32, json_data, "minWidth");
        const min_height = json_utils.getInt(u32, json_data, "minHeight");
        if (min_width != null or min_height != null) {
            const size = macos.NSSize{
                .width = @floatFromInt(min_width orelse 0),
                .height = @floatFromInt(min_height orelse 0),
            };
            const msg = @as(*const fn (macos.objc.id, macos.objc.SEL, macos.NSSize) callconv(.c) void, @ptrCast(&macos.objc.objc_msgSend));
            msg(window, macos.sel("setMinSize:"), size);
        }

        // Answer with the name rather than nothing: `open` is the one window
        // action a page waits on, because what it does next — focus it, close
        // it — needs to know it exists.
        const json = try formatOpenResult(self.allocator, name);
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, "open", json);
    }

    fn show(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.showWindow(handle);
        }
    }

    fn hide(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.hideWindow(handle);
        }
    }

    fn toggle(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.toggleWindow(handle);
        }
    }

    fn minimize(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.minimizeWindow(handle);
        }
    }

    fn close(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.closeWindow(handle);
        }
    }

    fn focus(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // makeKeyAndOrderFront focuses the window
            macos.showWindow(handle);
        }
    }

    fn blur(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.msgSendVoid0(handle, "resignKeyWindow");
        }
    }

    fn maximize(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // On macOS, "zoom" is the maximize equivalent
            macos.maximizeWindow(handle);
        }
    }

    fn unmaximize(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            if (macos.msgSendBool(handle, "isZoomed")) macos.maximizeWindow(handle);
        }
    }

    fn restore(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            if (macos.msgSendBool(handle, "isMiniaturized")) {
                macos.msgSendVoid1(handle, "deminiaturize:", @as(?*anyopaque, null));
            } else if (macos.msgSendBool(handle, "isZoomed")) {
                macos.maximizeWindow(handle);
            }
        }
    }

    fn center(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.msgSendVoid0(handle, "center");
        }
    }

    fn toggleFullscreen(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.toggleFullscreen(handle);
        }
    }

    fn setFullscreen(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        // Parse `{"fullscreen": true|false}`. The old implementation fell
        // back to matching any `:false` / `:true` in the blob, which meant
        // a payload like `{"resize":false,"fullscreen":true}` was read as
        // `fullscreen=false` because the `:false` needle fired first.
        const should_be_fullscreen = if (data) |json_data|
            // `craft.window.setFullscreen(on)` sends `{"value":…}`; this read
            // `fullscreen`, which the page has never sent, so `orelse true`
            // fired on every call and `setFullscreen(false)` *entered*
            // fullscreen. `fullscreen` stays accepted for raw callers.
            json_utils.getBool(json_data, "value") orelse
                json_utils.getBool(json_data, "fullscreen") orelse true
        else
            true;

        log.debug("setFullscreen: {}", .{should_be_fullscreen});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Check current fullscreen state using styleMask
            const style_mask_ptr = macos.msgSend0(handle, "styleMask");
            const style_mask = @as(c_ulong, @intFromPtr(style_mask_ptr));
            // NSWindowStyleMaskFullScreen = 1 << 14 = 16384
            const is_currently_fullscreen = (style_mask & 16384) != 0;

            // Only toggle if we need to change state
            if (should_be_fullscreen != is_currently_fullscreen) {
                macos.toggleFullscreen(handle);
            }
        }
    }

    fn setSize(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        const json_data = data orelse return BridgeError.MissingData;

        // Use the shared JSON helper; it handles whitespace, escapes, and
        // keeps parsing scoped to the named field.
        const width = json_utils.getInt(u32, json_data, "width") orelse 800;
        const height = json_utils.getInt(u32, json_data, "height") orelse 600;

        log.debug("setSize: {}x{}", .{ width, height });

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.setWindowSize(handle, width, height);
        }
    }

    fn setPosition(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        const json_data = data orelse return BridgeError.MissingData;

        // `getInt` only accepts a leading `-` on the number itself, so
        // payloads like `12-34` fall back to the default instead of being
        // mis-parsed into the truncated prefix the old hand-rolled loop
        // produced.
        const x = json_utils.getInt(i32, json_data, "x") orelse 100;
        const y = json_utils.getInt(i32, json_data, "y") orelse 100;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.setWindowPosition(handle, x, y);
        }
    }

    fn moveBy(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        const json_data = data orelse return BridgeError.MissingData;

        const dx = json_utils.getFloat(f64, json_data, "dx") orelse 0.0;
        const dy = json_utils.getFloat(f64, json_data, "dy") orelse 0.0;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.moveWindowBy(handle, dx, dy);
        }
    }

    fn setBounds(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        const json_data = data orelse return BridgeError.MissingData;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            var frame = macos.msgSendRect(handle, "frame");
            frame.origin.x = json_utils.getFloat(f64, json_data, "x") orelse frame.origin.x;
            frame.origin.y = json_utils.getFloat(f64, json_data, "y") orelse frame.origin.y;
            if (json_utils.getFloat(f64, json_data, "width")) |width| {
                if (width <= 0) return BridgeError.InvalidParameter;
                frame.size.width = width;
            }
            if (json_utils.getFloat(f64, json_data, "height")) |height| {
                if (height <= 0) return BridgeError.InvalidParameter;
                frame.size.height = height;
            }

            const msg = @as(
                *const fn (@TypeOf(handle), macos.objc.SEL, macos.NSRect, bool) callconv(.c) void,
                @ptrCast(&macos.objc.objc_msgSend),
            );
            msg(handle, macos.sel("setFrame:display:"), frame, true);
        }
    }

    fn setTitle(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        const json_data = data orelse return BridgeError.MissingData;

        // Use the shared getString helper (imported at module scope), which
        // correctly respects backslash escapes — the old inline parser used
        // indexOfPos for the closing quote and would truncate at the first
        // `\"` inside the title.
        const title = json_utils.getString(json_data, "title") orelse return BridgeError.InvalidJSON;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            const title_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, title);
            defer self.allocator.free(title_cstr);

            const NSString = macos.getClass("NSString");
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_title = macos.msgSend1(str_alloc, "initWithUTF8String:", title_cstr.ptr);
            _ = macos.msgSend1(handle, "setTitle:", ns_title);
        }
    }

    fn sendStringResult(self: *Self, action: []const u8, value: []const u8) !void {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);
        try json.append(self.allocator, '"');
        try bridge_error.appendJsonEscaped(self.allocator, &json, value);
        try json.append(self.allocator, '"');
        bridge_error.sendResultToJS(self.allocator, action, json.items);
    }

    fn sendBoolResult(self: *Self, action: []const u8, value: bool) void {
        bridge_error.sendResultToJS(self.allocator, action, if (value) "true" else "false");
    }

    fn getTitle(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag != .macos) return self.sendStringResult("getTitle", "");

        const macos = @import("macos.zig");
        const title = macos.msgSend0(handle, "title");
        if (title == null) return self.sendStringResult("getTitle", "");
        const utf8 = macos.msgSend0(title, "UTF8String");
        if (utf8 == null) return self.sendStringResult("getTitle", "");
        try self.sendStringResult("getTitle", std.mem.span(@as([*:0]const u8, @ptrCast(utf8))));
    }

    fn getSize(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getSize", "{\"width\":0,\"height\":0}");
            return;
        }
        const frame = @import("macos.zig").msgSendRect(handle, "frame");
        var buf: [128]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"width\":{d},\"height\":{d}}}", .{ frame.size.width, frame.size.height });
        bridge_error.sendResultToJS(self.allocator, "getSize", json);
    }

    fn getPosition(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getPosition", "{\"x\":0,\"y\":0}");
            return;
        }
        const frame = @import("macos.zig").msgSendRect(handle, "frame");
        var buf: [128]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"x\":{d},\"y\":{d}}}", .{ frame.origin.x, frame.origin.y });
        bridge_error.sendResultToJS(self.allocator, "getPosition", json);
    }

    fn getBounds(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getBounds", "{\"x\":0,\"y\":0,\"width\":0,\"height\":0}");
            return;
        }
        const frame = @import("macos.zig").msgSendRect(handle, "frame");
        var buf: [224]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &buf,
            "{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}",
            .{ frame.origin.x, frame.origin.y, frame.size.width, frame.size.height },
        );
        bridge_error.sendResultToJS(self.allocator, "getBounds", json);
    }

    fn isAlwaysOnTop(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag != .macos) return self.sendBoolResult("isAlwaysOnTop", false);
        self.sendBoolResult("isAlwaysOnTop", @import("macos.zig").msgSend0Ulong(handle, "level") != 0);
    }

    fn isResizable(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag != .macos) return self.sendBoolResult("isResizable", false);
        self.sendBoolResult("isResizable", (@import("macos.zig").msgSend0Ulong(handle, "styleMask") & 8) != 0);
    }

    fn isMovable(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag != .macos) return self.sendBoolResult("isMovable", false);
        self.sendBoolResult("isMovable", @import("macos.zig").msgSendBool(handle, "isMovable"));
    }

    fn getOpacity(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getOpacity", "1");
            return;
        }
        var buf: [64]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{d}", .{@import("macos.zig").msgSend0Double(handle, "alphaValue")});
        bridge_error.sendResultToJS(self.allocator, "getOpacity", json);
    }

    fn getState(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(
                self.allocator,
                "getState",
                "{\"isVisible\":false,\"isMinimized\":false,\"isMaximized\":false,\"isFullscreen\":false,\"isFocused\":false,\"isAlwaysOnTop\":false,\"bounds\":{\"x\":0,\"y\":0,\"width\":0,\"height\":0}}",
            );
            return;
        }

        const macos = @import("macos.zig");
        const frame = macos.msgSendRect(handle, "frame");
        const style_mask = macos.msgSend0Ulong(handle, "styleMask");
        var buf: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &buf,
            "{{\"isVisible\":{},\"isMinimized\":{},\"isMaximized\":{},\"isFullscreen\":{},\"isFocused\":{},\"isAlwaysOnTop\":{},\"bounds\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}}}",
            .{
                macos.msgSendBool(handle, "isVisible"),
                macos.msgSendBool(handle, "isMiniaturized"),
                macos.msgSendBool(handle, "isZoomed"),
                (style_mask & 16384) != 0,
                macos.msgSendBool(handle, "isKeyWindow"),
                macos.msgSend0Ulong(handle, "level") != 0,
                frame.origin.x,
                frame.origin.y,
                frame.size.width,
                frame.size.height,
            },
        );
        bridge_error.sendResultToJS(self.allocator, "getState", json);
    }

    fn getFocused(self: *Self) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getFocused", "null");
            return;
        }

        const macos = @import("macos.zig");
        const app = macos.msgSend0(macos.getClass("NSApplication"), "sharedApplication");
        const focused = macos.msgSend0(app, "keyWindow");
        if (focused == null) {
            bridge_error.sendResultToJS(self.allocator, "getFocused", "null");
            return;
        }

        const handle = @intFromPtr(focused);
        if (!window_registry.isKnown(handle)) {
            bridge_error.sendResultToJS(self.allocator, "getFocused", "null");
            return;
        }

        // Every page calls its own window `main`. A named result is only for a
        // retained child handle in the caller's manager; exposing a raw ObjC
        // pointer here would produce an id no JavaScript handle can resolve.
        if (window_context.current()) |sender| {
            if (sender == handle) return self.sendStringResult("getFocused", "main");
        }
        if (window_registry.nameOf(handle)) |name| {
            return self.sendStringResult("getFocused", name);
        }
        bridge_error.sendResultToJS(self.allocator, "getFocused", "null");
    }

    fn reload(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWebViewHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.reloadWindow(handle);
        }
    }

    fn loadHTML(self: *Self, data: ?[]const u8) !void {
        const webview = try self.requireWebViewHandle(data);
        const json_data = data orelse return BridgeError.MissingData;
        const html = json_utils.getStringDecoded(self.allocator, json_data, "html") catch
            return BridgeError.InvalidJSON;
        const decoded = html orelse return BridgeError.InvalidParameter;
        defer self.allocator.free(decoded);

        if (builtin.os.tag != .macos) return BridgeError.PlatformNotSupported;
        try @import("macos.zig").loadHTMLInWebView(webview, decoded);
    }

    fn loadURL(self: *Self, data: ?[]const u8) !void {
        const webview = try self.requireWebViewHandle(data);
        const json_data = data orelse return BridgeError.MissingData;
        const url = json_utils.getStringDecoded(self.allocator, json_data, "url") catch
            return BridgeError.InvalidJSON;
        const decoded = url orelse return BridgeError.InvalidParameter;
        defer self.allocator.free(decoded);
        if (decoded.len == 0) return BridgeError.InvalidParameter;

        if (builtin.os.tag != .macos) return BridgeError.PlatformNotSupported;
        try @import("macos.zig").loadURLInWebView(webview, decoded);
    }

    /// Pin this window to light or dark, or hand it back to the system.
    ///
    /// A page with its own appearance control is the only thing that knows
    /// which mode it is in, and anything native drawn behind it — a vibrancy
    /// view, a material backdrop, the window buttons — resolves against the
    /// window's appearance rather than the page's. Without a way to say so,
    /// choosing dark in an app left a dark page on a light material.
    fn setAppearance(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        const json_data = data orelse return BridgeError.MissingData;
        const mode = json_utils.getString(json_data, "appearance") orelse return BridgeError.InvalidJSON;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            if (std.mem.eql(u8, mode, "system")) {
                macos.clearAppearance(handle);
            } else if (std.mem.eql(u8, mode, "dark")) {
                macos.setAppearance(handle, true);
            } else if (std.mem.eql(u8, mode, "light")) {
                macos.setAppearance(handle, false);
            } else {
                return BridgeError.InvalidParameter;
            }
        }
    }

    fn setVibrancy(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Parse vibrancy type from {"vibrancy": "..."}
            var vibrancy_type: []const u8 = "none";
            if (data) |json_data| {
                // `setVibrancy(material)` sends `{"material":"sidebar"}`;
                // this scanned for `"vibrancy":"`, never matched, and left
                // "none" — which takes the *removal* branch below, so the call
                // stripped vibrancy instead of applying it.
                const vkey = if (std.mem.indexOf(u8, json_data, "\"material\":\"") != null)
                    "\"material\":\""
                else
                    "\"vibrancy\":\"";
                if (std.mem.indexOf(u8, json_data, vkey)) |idx| {
                    // `vkey.len`, not a literal: the two spellings happen to
                    // be the same length, which is luck and not something the
                    // next key added here would inherit.
                    const start = idx + vkey.len;
                    if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                        vibrancy_type = json_data[start..end];
                    }
                }
            }

            log.debug("setVibrancy: {s}", .{vibrancy_type});

            // Get NSVisualEffectView material enum value
            // Common values: 0=appearance-based, 1=light, 2=dark, 3=titlebar, 4=selection
            // 10=menu, 11=popover, 12=sidebar, 13=header, 14=sheet, 17=HUD, etc.
            var material: c_long = 0;
            if (std.mem.eql(u8, vibrancy_type, "sidebar")) {
                material = 12;
            } else if (std.mem.eql(u8, vibrancy_type, "header")) {
                material = 13;
            } else if (std.mem.eql(u8, vibrancy_type, "sheet")) {
                material = 14;
            } else if (std.mem.eql(u8, vibrancy_type, "menu")) {
                material = 10;
            } else if (std.mem.eql(u8, vibrancy_type, "popover")) {
                material = 11;
            } else if (std.mem.eql(u8, vibrancy_type, "fullscreen-ui")) {
                material = 15;
            } else if (std.mem.eql(u8, vibrancy_type, "hud")) {
                material = 17;
            } else if (std.mem.eql(u8, vibrancy_type, "titlebar")) {
                material = 3;
            } else if (std.mem.eql(u8, vibrancy_type, "none") or std.mem.eql(u8, vibrancy_type, "null")) {
                // Remove vibrancy - set window to opaque
                _ = macos.msgSend1(handle, "setOpaque:", true);
                return;
            }

            // Make window non-opaque for vibrancy
            _ = macos.msgSend1(handle, "setOpaque:", false);

            // Get content view and set up visual effect
            const content_view = macos.msgSend0(handle, "contentView");
            if (content_view != null) {
                // Create NSVisualEffectView
                const NSVisualEffectView = macos.getClass("NSVisualEffectView");
                const effect_view = macos.msgSend0(macos.msgSend0(NSVisualEffectView, "alloc"), "init");

                // Set material
                _ = macos.msgSend1(effect_view, "setMaterial:", material);

                // Set blending mode (behindWindow = 0)
                _ = macos.msgSend1(effect_view, "setBlendingMode:", @as(c_long, 0));

                // Set state (followsWindowActiveState = 1)
                _ = macos.msgSend1(effect_view, "setState:", @as(c_long, 1));

                // Set as background of content view
                _ = macos.msgSend3(content_view, "addSubview:positioned:relativeTo:", effect_view, @as(c_long, -1), @as(?*anyopaque, null));
            }
        }
    }

    fn setWebSidebarCollapsed(self: *Self, data: ?[]const u8) !void {
        const json_data = data orelse return BridgeError.MissingData;
        const handle = try self.requireWindowHandle(data);
        const collapsed = json_utils.getBool(json_data, "collapsed") orelse false;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.setWebSidebarCollapsed(handle, collapsed);
        }
    }

    fn setAlwaysOnTop(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        const always_on_top = if (data) |json_data|
            json_utils.getBool(json_data, "value") orelse
                json_utils.getBool(json_data, "alwaysOnTop") orelse true
        else
            true;

        log.debug("setAlwaysOnTop: {}", .{always_on_top});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // NSFloatingWindowLevel = 3, NSNormalWindowLevel = 0
            const level: c_long = if (always_on_top) 3 else 0;
            _ = macos.msgSend1(handle, "setLevel:", level);
        }
    }

    fn setOpacity(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        var opacity: f64 = 1.0;
        if (data) |json_data| {
            // Parse {"opacity": 0.8}
            // The page sends `{"value":0.4}`; this scanned for `"opacity":`,
            // never matched, and left the default 1.0 — so every opacity was
            // fully opaque and each value was indistinguishable from the next.
            const key = if (std.mem.indexOf(u8, json_data, "\"value\":") != null) "\"value\":" else "\"opacity\":";
            if (std.mem.indexOf(u8, json_data, key)) |idx| {
                var start = idx + key.len;
                while (start < json_data.len and (json_data[start] == ' ' or json_data[start] == '\t')) : (start += 1) {}
                var end = start;
                while (end < json_data.len and ((json_data[end] >= '0' and json_data[end] <= '9') or json_data[end] == '.')) : (end += 1) {}
                if (end > start) {
                    opacity = std.fmt.parseFloat(f64, json_data[start..end]) catch 1.0;
                }
            }
        }

        // Clamp to valid range
        opacity = @max(0.0, @min(1.0, opacity));
        log.debug("setOpacity: {d:.2}", .{opacity});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            const msg = @as(*const fn (@TypeOf(handle), macos.objc.SEL, f64) callconv(.c) void, @ptrCast(&macos.objc.objc_msgSend));
            msg(handle, macos.sel("setAlphaValue:"), opacity);
        }
    }

    fn setResizable(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        const resizable = if (data) |json_data|
            json_utils.getBool(json_data, "value") orelse
                json_utils.getBool(json_data, "resizable") orelse true
        else
            true;

        log.debug("setResizable: {}", .{resizable});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // Get current style mask
            const current_mask_ptr = macos.msgSend0(handle, "styleMask");
            var style_mask = @as(c_ulong, @intFromPtr(current_mask_ptr));

            // NSWindowStyleMaskResizable = 1 << 3 = 8
            const resizable_mask: c_ulong = 8;
            if (resizable) {
                style_mask |= resizable_mask;
            } else {
                style_mask &= ~resizable_mask;
            }

            _ = macos.msgSend1(handle, "setStyleMask:", style_mask);
        }
    }

    fn setBackgroundColor(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        // Default to white
        var r: f64 = 1.0;
        var g: f64 = 1.0;
        var b: f64 = 1.0;
        var a: f64 = 1.0;

        if (data) |json_data| {
            // `{"color": "..."}` — any CSS colour the parser understands.
            if (json_utils.getString(json_data, "color")) |text| {
                const parsed = color_parse.parse(text) orelse {
                    // Refused rather than approximated. This used to fall back
                    // to white, so `setBackgroundColor("violet")` produced an
                    // opaque white window and no indication that the value had
                    // not been understood.
                    log.warn("setBackgroundColor: cannot parse colour '{s}'", .{text});
                    return BridgeError.InvalidParameter;
                };
                r = parsed.r;
                g = parsed.g;
                b = parsed.b;
                a = parsed.a;
            } else {
                // `{"r":…, "g":…, "b":…, "a":…}`, each 0–1.
                r = json_utils.getFloat(f64, json_data, "r") orelse r;
                g = json_utils.getFloat(f64, json_data, "g") orelse g;
                b = json_utils.getFloat(f64, json_data, "b") orelse b;
                a = json_utils.getFloat(f64, json_data, "a") orelse a;
            }
        }

        log.debug("setBackgroundColor: r={d:.2}, g={d:.2}, b={d:.2}, a={d:.2}", .{ r, g, b, a });

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Create NSColor
            const NSColor = macos.getClass("NSColor");
            const color_sel = macos.sel("colorWithRed:green:blue:alpha:");
            const msg = @as(*const fn (macos.objc.Class, macos.objc.SEL, f64, f64, f64, f64) callconv(.c) macos.objc.id, @ptrCast(&macos.objc.objc_msgSend));
            const color = msg(NSColor, color_sel, r, g, b, a);

            // Set window background color
            _ = macos.msgSend1(handle, "setBackgroundColor:", color);
        }
    }

    fn setMinSize(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        var width: u32 = 100;
        var height: u32 = 100;

        if (data) |json_data| {
            // Parse {"width": 400, "height": 300}
            if (std.mem.indexOf(u8, json_data, "\"width\":")) |idx| {
                var start = idx + 8;
                while (start < json_data.len and (json_data[start] == ' ' or json_data[start] == '\t')) : (start += 1) {}
                var end = start;
                while (end < json_data.len and json_data[end] >= '0' and json_data[end] <= '9') : (end += 1) {}
                if (end > start) {
                    width = std.fmt.parseInt(u32, json_data[start..end], 10) catch 100;
                }
            }
            if (std.mem.indexOf(u8, json_data, "\"height\":")) |idx| {
                var start = idx + 9;
                while (start < json_data.len and (json_data[start] == ' ' or json_data[start] == '\t')) : (start += 1) {}
                var end = start;
                while (end < json_data.len and json_data[end] >= '0' and json_data[end] <= '9') : (end += 1) {}
                if (end > start) {
                    height = std.fmt.parseInt(u32, json_data[start..end], 10) catch 100;
                }
            }
        }

        log.debug("setMinSize: {}x{}", .{ width, height });

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // Create NSSize and set minimum size
            const size = macos.NSSize{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
            const msg = @as(*const fn (@TypeOf(handle), macos.objc.SEL, macos.NSSize) callconv(.c) void, @ptrCast(&macos.objc.objc_msgSend));
            msg(handle, macos.sel("setMinSize:"), size);
        }
    }

    fn setMaxSize(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        var width: u32 = 10000;
        var height: u32 = 10000;

        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "\"width\":")) |idx| {
                var start = idx + 8;
                while (start < json_data.len and (json_data[start] == ' ' or json_data[start] == '\t')) : (start += 1) {}
                var end = start;
                while (end < json_data.len and json_data[end] >= '0' and json_data[end] <= '9') : (end += 1) {}
                if (end > start) {
                    width = std.fmt.parseInt(u32, json_data[start..end], 10) catch 10000;
                }
            }
            if (std.mem.indexOf(u8, json_data, "\"height\":")) |idx| {
                var start = idx + 9;
                while (start < json_data.len and (json_data[start] == ' ' or json_data[start] == '\t')) : (start += 1) {}
                var end = start;
                while (end < json_data.len and json_data[end] >= '0' and json_data[end] <= '9') : (end += 1) {}
                if (end > start) {
                    height = std.fmt.parseInt(u32, json_data[start..end], 10) catch 10000;
                }
            }
        }

        log.debug("setMaxSize: {}x{}", .{ width, height });

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            const size = macos.NSSize{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
            const msg = @as(*const fn (@TypeOf(handle), macos.objc.SEL, macos.NSSize) callconv(.c) void, @ptrCast(&macos.objc.objc_msgSend));
            msg(handle, macos.sel("setMaxSize:"), size);
        }
    }

    fn setMovable(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        const movable = if (data) |json_data|
            json_utils.getBool(json_data, "value") orelse
                json_utils.getBool(json_data, "movable") orelse true
        else
            true;

        log.debug("setMovable: {}", .{movable});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            _ = macos.msgSend1(handle, "setMovable:", @as(c_int, if (movable) 1 else 0));
        }
    }

    fn startDrag(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.startWindowDrag(handle);
        }
    }

    fn setHasShadow(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        const has_shadow = if (data) |json_data|
            json_utils.getBool(json_data, "value") orelse
                json_utils.getBool(json_data, "hasShadow") orelse true
        else
            true;

        log.debug("setHasShadow: {}", .{has_shadow});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            _ = macos.msgSend1(handle, "setHasShadow:", @as(c_int, if (has_shadow) 1 else 0));
        }
    }

    fn setWindowLevel(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);
        const json_data = data orelse return BridgeError.MissingData;
        const level = json_utils.getInt(c_long, json_data, "level") orelse return BridgeError.InvalidParameter;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            _ = macos.msgSend1(handle, "setLevel:", level);
        }
    }

    /// Set aspect ratio for window resizing
    /// JSON: {"width": 16, "height": 9} or {"ratio": 1.777}
    fn setAspectRatio(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle(data);

        var width: f64 = 0;
        var height: f64 = 0;

        if (data) |json_data| {
            // Try ratio first
            if (std.mem.indexOf(u8, json_data, "\"ratio\":")) |idx| {
                var start = idx + 8;
                while (start < json_data.len and (json_data[start] == ' ' or json_data[start] == '\t')) : (start += 1) {}
                var end = start;
                while (end < json_data.len and ((json_data[end] >= '0' and json_data[end] <= '9') or json_data[end] == '.')) : (end += 1) {}
                if (end > start) {
                    const ratio = std.fmt.parseFloat(f64, json_data[start..end]) catch 0;
                    if (ratio > 0) {
                        width = ratio;
                        height = 1.0;
                    }
                }
            } else {
                // Parse width/height
                if (std.mem.indexOf(u8, json_data, "\"width\":")) |idx| {
                    var start = idx + 8;
                    while (start < json_data.len and (json_data[start] == ' ' or json_data[start] == '\t')) : (start += 1) {}
                    var end = start;
                    while (end < json_data.len and ((json_data[end] >= '0' and json_data[end] <= '9') or json_data[end] == '.')) : (end += 1) {}
                    if (end > start) {
                        width = std.fmt.parseFloat(f64, json_data[start..end]) catch 0;
                    }
                }
                if (std.mem.indexOf(u8, json_data, "\"height\":")) |idx| {
                    var start = idx + 9;
                    while (start < json_data.len and (json_data[start] == ' ' or json_data[start] == '\t')) : (start += 1) {}
                    var end = start;
                    while (end < json_data.len and ((json_data[end] >= '0' and json_data[end] <= '9') or json_data[end] == '.')) : (end += 1) {}
                    if (end > start) {
                        height = std.fmt.parseFloat(f64, json_data[start..end]) catch 0;
                    }
                }
            }
        }

        log.debug("setAspectRatio: {d:.2}:{d:.2}", .{ width, height });

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            if (width > 0 and height > 0) {
                // Set aspect ratio using setContentAspectRatio:
                const size = macos.NSSize{ .width = width, .height = height };
                const msg = @as(*const fn (@TypeOf(handle), macos.objc.SEL, macos.NSSize) callconv(.c) void, @ptrCast(&macos.objc.objc_msgSend));
                msg(handle, macos.sel("setContentAspectRatio:"), size);
            } else {
                // Clear aspect ratio by setting to 0,0
                const size = macos.NSSize{ .width = 0, .height = 0 };
                const msg = @as(*const fn (@TypeOf(handle), macos.objc.SEL, macos.NSSize) callconv(.c) void, @ptrCast(&macos.objc.objc_msgSend));
                msg(handle, macos.sel("setContentAspectRatio:"), size);
            }
        }
    }

    /// Flash the window frame to get user attention (bounce dock icon on macOS)
    /// JSON: {"flash": true} or {"count": 3}
    fn flashFrame(self: *Self, data: ?[]const u8) !void {
        _ = try self.requireWindowHandle(data);

        const should_flash = if (data) |json_data|
            json_utils.getBool(json_data, "flash") orelse true
        else
            true;

        log.debug("flashFrame: {}", .{should_flash});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            if (should_flash) {
                // Get NSApplication and request user attention
                const NSApplication = macos.getClass("NSApplication");
                const app = macos.msgSend0(NSApplication, "sharedApplication");

                // NSCriticalRequest = 0, NSInformationalRequest = 10
                // Use informational (bounce once) by default
                const request_type: c_long = 10;
                _ = macos.msgSend1(app, "requestUserAttention:", request_type);
            } else {
                // Cancel any pending attention request
                const NSApplication = macos.getClass("NSApplication");
                const app = macos.msgSend0(NSApplication, "sharedApplication");
                _ = macos.msgSend1(app, "cancelUserAttentionRequest:", @as(c_long, 0));
            }
        }
    }

    /// Set dock progress bar (macOS only)
    /// JSON: {"progress": 0.5} (0.0-1.0) or {"progress": -1} to hide
    fn setProgressBar(self: *Self, data: ?[]const u8) !void {
        _ = try self.requireWindowHandle(data);

        var progress: f64 = -1;
        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "\"progress\":")) |idx| {
                var start = idx + 11;
                while (start < json_data.len and (json_data[start] == ' ' or json_data[start] == '\t')) : (start += 1) {}
                var end = start;
                // Allow negative numbers
                if (start < json_data.len and json_data[start] == '-') {
                    end += 1;
                }
                while (end < json_data.len and ((json_data[end] >= '0' and json_data[end] <= '9') or json_data[end] == '.')) : (end += 1) {}
                if (end > start) {
                    progress = std.fmt.parseFloat(f64, json_data[start..end]) catch -1;
                }
            }
        }

        log.debug("setProgressBar: {d:.2}", .{progress});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Get dock tile from NSApplication
            const NSApplication = macos.getClass("NSApplication");
            const app = macos.msgSend0(NSApplication, "sharedApplication");
            const dock_tile = macos.msgSend0(app, "dockTile");

            if (progress < 0) {
                // Hide progress indicator
                _ = macos.msgSend1(dock_tile, "setShowsApplicationBadge:", @as(c_int, 0));
                // Remove any existing progress view
                _ = macos.msgSend1(dock_tile, "setContentView:", @as(?*anyopaque, null));
            } else {
                // Clamp progress to 0-1
                const clamped = @max(0.0, @min(1.0, progress));

                // Create NSProgressIndicator for dock
                const NSProgressIndicator = macos.getClass("NSProgressIndicator");
                const indicator = macos.msgSend0(macos.msgSend0(NSProgressIndicator, "alloc"), "init");

                // Set determinate mode
                _ = macos.msgSend1(indicator, "setIndeterminate:", @as(c_int, 0));

                // Set min/max values
                const msg_double = @as(*const fn (@TypeOf(indicator), macos.objc.SEL, f64) callconv(.c) void, @ptrCast(&macos.objc.objc_msgSend));
                msg_double(indicator, macos.sel("setMinValue:"), 0.0);
                msg_double(indicator, macos.sel("setMaxValue:"), 1.0);
                msg_double(indicator, macos.sel("setDoubleValue:"), clamped);

                // Set content view on dock tile
                _ = macos.msgSend1(dock_tile, "setContentView:", indicator);
                _ = macos.msgSend0(dock_tile, "display");
            }
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

// Unit tests for WindowBridge
test "WindowBridge.requireWindowHandle returns error when null" {
    const testing = std.testing;
    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();

    const result = bridge.requireWindowHandle(null);
    try testing.expectError(BridgeError.WindowHandleNotSet, result);
}

test "WindowBridge.requireWebViewHandle returns error when null" {
    const testing = std.testing;
    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();

    const result = bridge.requireWebViewHandle(null);
    try testing.expectError(BridgeError.WebViewHandleNotSet, result);
}

test "WindowBridge uses the sending webview before its stored fallback" {
    const testing = std.testing;
    window_context.resetForTesting();
    defer window_context.resetForTesting();

    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();
    bridge.setWebViewHandle(@ptrFromInt(0x1000));

    window_context.push(0x2000, 0x2001);
    defer window_context.pop();

    try testing.expectEqual(
        @as(usize, 0x2001),
        @intFromPtr(try bridge.requireWebViewHandle(null)),
    );
}

test "a named window handle overrides the sending window" {
    const testing = std.testing;
    window_registry.resetForTesting();
    window_context.resetForTesting();
    defer window_registry.resetForTesting();
    defer window_context.resetForTesting();

    try testing.expect(window_registry.rememberNamed(0x3000, "settings"));
    window_context.push(0x2000, 0x2001);
    defer window_context.pop();

    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();
    bridge.setWindowHandle(@ptrFromInt(0x1000));

    try testing.expectEqual(
        @as(usize, 0x3000),
        @intFromPtr(try bridge.requireWindowHandle("{\"windowId\":\"settings\"}")),
    );
}

test "the local main alias still means the sending window" {
    const testing = std.testing;
    window_context.resetForTesting();
    defer window_context.resetForTesting();

    window_context.push(0x2000, 0x2001);
    defer window_context.pop();

    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();
    bridge.setWindowHandle(@ptrFromInt(0x1000));

    try testing.expectEqual(
        @as(usize, 0x2000),
        @intFromPtr(try bridge.requireWindowHandle("{\"windowId\":\"main\"}")),
    );
}

test "an unknown named window is rejected instead of touching the sender" {
    const testing = std.testing;
    window_registry.resetForTesting();
    window_context.resetForTesting();
    defer window_registry.resetForTesting();
    defer window_context.resetForTesting();

    window_context.push(0x2000, 0x2001);
    defer window_context.pop();

    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        BridgeError.InvalidParameter,
        bridge.requireWindowHandle("{\"windowId\":\"gone\"}"),
    );
}

test "an action that takes a payload fails without one" {
    // The contract the router broke: `handleMessage` deliberately passes no
    // data, so every action that needs some must report MissingData through it.
    // That is correct behaviour here and a bug at the call site — the router
    // used to send every window message down this path, so setSize, setTitle,
    // setWebSidebarCollapsed and 15 others could never see their arguments.
    const testing = std.testing;
    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(BridgeError.MissingData, bridge.setWebSidebarCollapsed(null));
}

test "the same action succeeds when the payload is routed through" {
    const testing = std.testing;
    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();
    bridge.setWindowHandle(@ptrFromInt(0x1000));

    try bridge.setWebSidebarCollapsed("{\"collapsed\":true}");
    try bridge.setWebSidebarCollapsed("{\"collapsed\":false}");
}

test "web sidebar collapse requires a target window" {
    const testing = std.testing;
    window_context.resetForTesting();
    defer window_context.resetForTesting();

    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        BridgeError.WindowHandleNotSet,
        bridge.setWebSidebarCollapsed("{\"collapsed\":true}"),
    );
}

test "handleMessageWithData reaches a payload action" {
    // End of the path the router now takes. `handleMessage` would swallow the
    // payload before it got here.
    const testing = std.testing;
    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();
    bridge.setWindowHandle(@ptrFromInt(0x1000));

    try bridge.handleMessageWithData("setWebSidebarCollapsed", "{\"collapsed\":true}");
}

test "open result preserves an app-chosen name as JSON data" {
    const testing = std.testing;
    const name = "settings\"\\line\nnext";
    const result = try formatOpenResult(testing.allocator, name);
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(name, parsed.value.object.get("name").?.string);
}
