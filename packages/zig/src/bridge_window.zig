const std = @import("std");
const builtin = @import("builtin");
const color_parse = @import("color.zig");
const bridge_error = @import("bridge_error.zig");
const logging = @import("logging.zig");
const json_utils = @import("json_utils.zig");

const BridgeError = bridge_error.BridgeError;
const log = logging.window;

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
            try self.show();
        } else if (std.mem.eql(u8, action, "hide")) {
            try self.hide();
        } else if (std.mem.eql(u8, action, "toggle")) {
            try self.toggle();
        } else if (std.mem.eql(u8, action, "focus")) {
            try self.focus();
        } else if (std.mem.eql(u8, action, "minimize")) {
            try self.minimize();
        } else if (std.mem.eql(u8, action, "maximize")) {
            try self.maximize();
        } else if (std.mem.eql(u8, action, "close")) {
            try self.close();
        } else if (std.mem.eql(u8, action, "center")) {
            try self.center();
        } else if (std.mem.eql(u8, action, "toggleFullscreen")) {
            try self.toggleFullscreen();
        } else if (std.mem.eql(u8, action, "setFullscreen")) {
            try self.setFullscreen(data);
        } else if (std.mem.eql(u8, action, "setSize")) {
            try self.setSize(data);
        } else if (std.mem.eql(u8, action, "setPosition")) {
            try self.setPosition(data);
        } else if (std.mem.eql(u8, action, "moveBy")) {
            try self.moveBy(data);
        } else if (std.mem.eql(u8, action, "setTitle")) {
            try self.setTitle(data);
        } else if (std.mem.eql(u8, action, "reload")) {
            try self.reload();
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
        } else if (std.mem.eql(u8, action, "setMinSize")) {
            try self.setMinSize(data);
        } else if (std.mem.eql(u8, action, "setMaxSize")) {
            try self.setMaxSize(data);
        } else if (std.mem.eql(u8, action, "setMovable")) {
            try self.setMovable(data);
        } else if (std.mem.eql(u8, action, "startDrag")) {
            try self.startDrag();
        } else if (std.mem.eql(u8, action, "setHasShadow")) {
            try self.setHasShadow(data);
        } else if (std.mem.eql(u8, action, "setAspectRatio")) {
            try self.setAspectRatio(data);
        } else if (std.mem.eql(u8, action, "flashFrame")) {
            try self.flashFrame(data);
        } else if (std.mem.eql(u8, action, "setProgressBar")) {
            try self.setProgressBar(data);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// Get window handle or return error
    fn requireWindowHandle(self: *Self) BridgeError!*anyopaque {
        return self.window_handle orelse BridgeError.WindowHandleNotSet;
    }

    /// Get webview handle or return error
    fn requireWebViewHandle(self: *Self) BridgeError!*anyopaque {
        return self.webview_handle orelse BridgeError.WebViewHandleNotSet;
    }

    fn show(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.showWindow(handle);
        }
    }

    fn hide(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.hideWindow(handle);
        }
    }

    fn toggle(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.toggleWindow(handle);
        }
    }

    fn minimize(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.minimizeWindow(handle);
        }
    }

    fn close(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.closeWindow(handle);
        }
    }

    fn focus(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // makeKeyAndOrderFront focuses the window
            macos.showWindow(handle);
        }
    }

    fn maximize(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // On macOS, "zoom" is the maximize equivalent
            macos.msgSendVoid0(handle, "zoom:");
        }
    }

    fn center(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.msgSendVoid0(handle, "center");
        }
    }

    fn toggleFullscreen(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.toggleFullscreen(handle);
        }
    }

    fn setFullscreen(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle();

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
        const handle = try self.requireWindowHandle();
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
        const handle = try self.requireWindowHandle();
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
        const handle = try self.requireWindowHandle();
        const json_data = data orelse return BridgeError.MissingData;

        const dx = json_utils.getFloat(f64, json_data, "dx") orelse 0.0;
        const dy = json_utils.getFloat(f64, json_data, "dy") orelse 0.0;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.moveWindowBy(handle, dx, dy);
        }
    }

    fn setTitle(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle();
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

    fn reload(self: *Self) !void {
        const handle = try self.requireWebViewHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.reloadWindow(handle);
        }
    }

    /// Pin this window to light or dark, or hand it back to the system.
    ///
    /// A page with its own appearance control is the only thing that knows
    /// which mode it is in, and anything native drawn behind it — a vibrancy
    /// view, a material backdrop, the window buttons — resolves against the
    /// window's appearance rather than the page's. Without a way to say so,
    /// choosing dark in an app left a dark page on a light material.
    fn setAppearance(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle();
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
        const handle = try self.requireWindowHandle();

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

    fn setWebSidebarCollapsed(_: *Self, data: ?[]const u8) !void {
        const json_data = data orelse return BridgeError.MissingData;
        const collapsed = json_utils.getBool(json_data, "collapsed") orelse false;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.setWebSidebarCollapsed(collapsed);
        }
    }

    fn setAlwaysOnTop(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle();

        var always_on_top = true;
        if (data) |json_data| {
            // Parse {"alwaysOnTop": true/false}
            if (std.mem.indexOf(u8, json_data, "false")) |_| {
                always_on_top = false;
            }
        }

        log.debug("setAlwaysOnTop: {}", .{always_on_top});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // NSFloatingWindowLevel = 3, NSNormalWindowLevel = 0
            const level: c_long = if (always_on_top) 3 else 0;
            _ = macos.msgSend1(handle, "setLevel:", level);
        }
    }

    fn setOpacity(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle();

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
        const handle = try self.requireWindowHandle();

        var resizable = true;
        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "false")) |_| {
                resizable = false;
            }
        }

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
        const handle = try self.requireWindowHandle();

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
        const handle = try self.requireWindowHandle();

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
        const handle = try self.requireWindowHandle();

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
        const handle = try self.requireWindowHandle();

        var movable = true;
        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "false")) |_| {
                movable = false;
            }
        }

        log.debug("setMovable: {}", .{movable});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            _ = macos.msgSend1(handle, "setMovable:", @as(c_int, if (movable) 1 else 0));
        }
    }

    fn startDrag(self: *Self) !void {
        const handle = try self.requireWindowHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.startWindowDrag(handle);
        }
    }

    fn setHasShadow(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle();

        var has_shadow = true;
        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "false")) |_| {
                has_shadow = false;
            }
        }

        log.debug("setHasShadow: {}", .{has_shadow});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            _ = macos.msgSend1(handle, "setHasShadow:", @as(c_int, if (has_shadow) 1 else 0));
        }
    }

    /// Set aspect ratio for window resizing
    /// JSON: {"width": 16, "height": 9} or {"ratio": 1.777}
    fn setAspectRatio(self: *Self, data: ?[]const u8) !void {
        const handle = try self.requireWindowHandle();

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
        _ = try self.requireWindowHandle();

        var should_flash = true;
        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "false")) |_| {
                should_flash = false;
            }
        }

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
        _ = try self.requireWindowHandle();

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

    const result = bridge.requireWindowHandle();
    try testing.expectError(BridgeError.WindowHandleNotSet, result);
}

test "WindowBridge.requireWebViewHandle returns error when null" {
    const testing = std.testing;
    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();

    const result = bridge.requireWebViewHandle();
    try testing.expectError(BridgeError.WebViewHandleNotSet, result);
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

    // No window handle is set and none is needed: this action only forwards a
    // flag to the platform layer, which is exactly why its failure was a
    // routing bug rather than a windowing one.
    try bridge.setWebSidebarCollapsed("{\"collapsed\":true}");
    try bridge.setWebSidebarCollapsed("{\"collapsed\":false}");
}

test "handleMessageWithData reaches a payload action" {
    // End of the path the router now takes. `handleMessage` would swallow the
    // payload before it got here.
    const testing = std.testing;
    var bridge = WindowBridge.init(testing.allocator);
    defer bridge.deinit();

    try bridge.handleMessageWithData("setWebSidebarCollapsed", "{\"collapsed\":true}");
}
