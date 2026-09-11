const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");

const BridgeError = bridge_error.BridgeError;

/// System preferences/settings bridge
pub const SystemBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Handle system-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            self.reportError(action, err);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "getAppearance")) {
            try self.getAppearance(data);
        } else if (std.mem.eql(u8, action, "getAccentColor")) {
            try self.getAccentColor(data);
        } else if (std.mem.eql(u8, action, "getHighlightColor")) {
            try self.getHighlightColor(data);
        } else if (std.mem.eql(u8, action, "getLanguage")) {
            try self.getLanguage(data);
        } else if (std.mem.eql(u8, action, "getLocale")) {
            try self.getLocale(data);
        } else if (std.mem.eql(u8, action, "getTimezone")) {
            try self.getTimezone(data);
        } else if (std.mem.eql(u8, action, "is24HourTime")) {
            try self.is24HourTime(data);
        } else if (std.mem.eql(u8, action, "getReduceMotion")) {
            try self.getReduceMotion(data);
        } else if (std.mem.eql(u8, action, "getReduceTransparency")) {
            try self.getReduceTransparency(data);
        } else if (std.mem.eql(u8, action, "getIncreaseContrast")) {
            try self.getIncreaseContrast(data);
        } else if (std.mem.eql(u8, action, "openSystemPreferences")) {
            try self.openSystemPreferences(data);
        } else if (std.mem.eql(u8, action, "getSystemVersion")) {
            try self.getSystemVersion(data);
        } else if (std.mem.eql(u8, action, "getHostname")) {
            try self.getHostname(data);
        } else if (std.mem.eql(u8, action, "getUsername")) {
            try self.getUsername(data);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn reportError(self: *Self, action: []const u8, err: anyerror) void {
        const bridge_err: BridgeError = switch (err) {
            BridgeError.MissingData => BridgeError.MissingData,
            BridgeError.InvalidJSON => BridgeError.InvalidJSON,
            else => BridgeError.NativeCallFailed,
        };
        bridge_error.sendErrorToJS(self.allocator, action, bridge_err);
    }

    /// Get current appearance (dark/light mode)
    /// JSON: {"callbackId": "cb1"}
    fn getAppearance(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getAppearance\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Check NSApp.effectiveAppearance.name
            const NSApp = macos.msgSend0(macos.getClass("NSApplication"), "sharedApplication");
            const appearance = macos.msgSend0(NSApp, "effectiveAppearance");
            const name = macos.msgSend0(appearance, "name");

            // Get NSString value
            const name_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(name, "UTF8String"));
            const name_str = std.mem.span(name_cstr);

            // Check if it contains "Dark"
            const is_dark = std.mem.indexOf(u8, name_str, "Dark") != null;
            const appearance_str = if (is_dark) "dark" else "light";

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getAppearance','{s}');", .{ callback_id, appearance_str }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getAppearance callback: {}", .{err});
            };
        }
    }

    /// Get system accent color
    /// JSON: {"callbackId": "cb1"}
    fn getAccentColor(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getAccentColor\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Get NSColor.controlAccentColor
            const NSColor = macos.getClass("NSColor");
            const accent_color = macos.msgSend0(NSColor, "controlAccentColor");

            // Convert to RGB
            const rgb_color = macos.msgSend1(accent_color, "colorUsingColorSpace:", macos.msgSend0(macos.getClass("NSColorSpace"), "sRGBColorSpace"));

            const r: f64 = macos.msgSend0Double(rgb_color, "redComponent");
            const g: f64 = macos.msgSend0Double(rgb_color, "greenComponent");
            const b: f64 = macos.msgSend0Double(rgb_color, "blueComponent");

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getAccentColor',{{r:{d:.3},g:{d:.3},b:{d:.3}}});", .{ callback_id, r, g, b }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getAccentColor callback: {}", .{err});
            };
        }
    }

    /// Get highlight color
    /// JSON: {"callbackId": "cb1"}
    fn getHighlightColor(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getHighlightColor\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSColor = macos.getClass("NSColor");
            const highlight_color = macos.msgSend0(NSColor, "selectedTextBackgroundColor");

            const rgb_color = macos.msgSend1(highlight_color, "colorUsingColorSpace:", macos.msgSend0(macos.getClass("NSColorSpace"), "sRGBColorSpace"));

            const r: f64 = macos.msgSend0Double(rgb_color, "redComponent");
            const g: f64 = macos.msgSend0Double(rgb_color, "greenComponent");
            const b: f64 = macos.msgSend0Double(rgb_color, "blueComponent");

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getHighlightColor',{{r:{d:.3},g:{d:.3},b:{d:.3}}});", .{ callback_id, r, g, b }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getHighlightColor callback: {}", .{err});
            };
        }
    }

    /// Get preferred language
    /// JSON: {"callbackId": "cb1"}
    fn getLanguage(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getLanguage\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Get preferred language from NSLocale
            const NSLocale = macos.getClass("NSLocale");
            const preferred_languages = macos.msgSend0(NSLocale, "preferredLanguages");
            const first_lang = macos.msgSend1(preferred_languages, "objectAtIndex:", @as(usize, 0));

            const lang_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(first_lang, "UTF8String"));
            const lang_str = std.mem.span(lang_cstr);

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getLanguage','{s}');", .{ callback_id, lang_str }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getLanguage callback: {}", .{err});
            };
        }
    }

    /// Get current locale
    /// JSON: {"callbackId": "cb1"}
    fn getLocale(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getLocale\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSLocale = macos.getClass("NSLocale");
            const current_locale = macos.msgSend0(NSLocale, "currentLocale");
            const locale_id = macos.msgSend0(current_locale, "localeIdentifier");

            const locale_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(locale_id, "UTF8String"));
            const locale_str = std.mem.span(locale_cstr);

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getLocale','{s}');", .{ callback_id, locale_str }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getLocale callback: {}", .{err});
            };
        }
    }

    /// Get timezone
    /// JSON: {"callbackId": "cb1"}
    fn getTimezone(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getTimezone\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSTimeZone = macos.getClass("NSTimeZone");
            const local_tz = macos.msgSend0(NSTimeZone, "localTimeZone");
            const tz_name = macos.msgSend0(local_tz, "name");

            const tz_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(tz_name, "UTF8String"));
            const tz_str = std.mem.span(tz_cstr);

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getTimezone','{s}');", .{ callback_id, tz_str }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getTimezone callback: {}", .{err});
            };
        }
    }

    /// Check if 24-hour time format
    /// JSON: {"callbackId": "cb1"}
    fn is24HourTime(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] is24HourTime\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Get date format from locale
            const NSDateFormatter = macos.getClass("NSDateFormatter");
            const formatter = macos.msgSend0(NSDateFormatter, "alloc");
            _ = macos.msgSend0(formatter, "init");

            _ = macos.msgSend1(formatter, "setDateStyle:", @as(usize, 0)); // NSDateFormatterNoStyle
            _ = macos.msgSend1(formatter, "setTimeStyle:", @as(usize, 1)); // NSDateFormatterShortStyle

            const format = macos.msgSend0(formatter, "dateFormat");
            const format_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(format, "UTF8String"));
            const format_str = std.mem.span(format_cstr);

            // Check if format contains 'a' (AM/PM indicator)
            const is_24h = std.mem.indexOf(u8, format_str, "a") == null;

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','is24HourTime',{});", .{ callback_id, is_24h }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for is24HourTime callback: {}", .{err});
            };
        }
    }

    /// Get reduce motion accessibility setting
    /// JSON: {"callbackId": "cb1"}
    fn getReduceMotion(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getReduceMotion\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion
            const NSWorkspace = macos.getClass("NSWorkspace");
            const workspace = macos.msgSend0(NSWorkspace, "sharedWorkspace");
            const reduce_motion = macos.msgSendBool(workspace, "accessibilityDisplayShouldReduceMotion");

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getReduceMotion',{});", .{ callback_id, reduce_motion }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getReduceMotion callback: {}", .{err});
            };
        }
    }

    /// Get reduce transparency accessibility setting
    /// JSON: {"callbackId": "cb1"}
    fn getReduceTransparency(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getReduceTransparency\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSWorkspace = macos.getClass("NSWorkspace");
            const workspace = macos.msgSend0(NSWorkspace, "sharedWorkspace");
            const reduce_transparency = macos.msgSendBool(workspace, "accessibilityDisplayShouldReduceTransparency");

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getReduceTransparency',{});", .{ callback_id, reduce_transparency }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getReduceTransparency callback: {}", .{err});
            };
        }
    }

    /// Get increase contrast accessibility setting
    /// JSON: {"callbackId": "cb1"}
    fn getIncreaseContrast(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getIncreaseContrast\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSWorkspace = macos.getClass("NSWorkspace");
            const workspace = macos.msgSend0(NSWorkspace, "sharedWorkspace");
            const increase_contrast = macos.msgSendBool(workspace, "accessibilityDisplayShouldIncreaseContrast");

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getIncreaseContrast',{});", .{ callback_id, increase_contrast }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getIncreaseContrast callback: {}", .{err});
            };
        }
    }

    /// Open System Preferences to a specific pane
    /// JSON: {"pane": "Security"}
    fn openSystemPreferences(self: *Self, data: []const u8) !void {
        _ = self;
        var pane: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"pane\":\"")) |idx| {
            const start = idx + 8;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                pane = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] openSystemPreferences: {s}\n", .{pane});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Build URL: x-apple.systempreferences:com.apple.preference.{pane}
            var url_buf: [256]u8 = undefined;
            const url_str = if (pane.len > 0)
                std.fmt.bufPrint(&url_buf, "x-apple.systempreferences:com.apple.preference.{s}", .{pane}) catch return
            else
                "x-apple.systempreferences:";

            const NSWorkspace = macos.getClass("NSWorkspace");
            const workspace = macos.msgSend0(NSWorkspace, "sharedWorkspace");

            const NSString = macos.getClass("NSString");
            const url_nsstr = macos.msgSend1(NSString, "stringWithUTF8String:", @as([*c]const u8, @ptrCast(url_str.ptr)));

            const NSURL = macos.getClass("NSURL");
            const nsurl = macos.msgSend1(NSURL, "URLWithString:", url_nsstr);

            _ = macos.msgSend1(workspace, "openURL:", nsurl);
        }
    }

    /// Get macOS version
    /// JSON: {"callbackId": "cb1"}
    fn getSystemVersion(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getSystemVersion\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSProcessInfo = macos.getClass("NSProcessInfo");
            const process_info = macos.msgSend0(NSProcessInfo, "processInfo");
            const version_str = macos.msgSend0(process_info, "operatingSystemVersionString");

            const ver_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(version_str, "UTF8String"));
            const ver_str = std.mem.span(ver_cstr);

            var buf: [512]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getSystemVersion','{s}');", .{ callback_id, ver_str }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getSystemVersion callback: {}", .{err});
            };
        }
    }

    /// Get hostname
    /// JSON: {"callbackId": "cb1"}
    fn getHostname(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getHostname\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSProcessInfo = macos.getClass("NSProcessInfo");
            const process_info = macos.msgSend0(NSProcessInfo, "processInfo");
            const hostname = macos.msgSend0(process_info, "hostName");

            const host_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(hostname, "UTF8String"));
            const host_str = std.mem.span(host_cstr);

            var buf: [512]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getHostname','{s}');", .{ callback_id, host_str }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getHostname callback: {}", .{err});
            };
        }
    }

    /// Get current username
    /// JSON: {"callbackId": "cb1"}
    fn getUsername(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[SystemBridge] getUsername\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSProcessInfo = macos.getClass("NSProcessInfo");
            const process_info = macos.msgSend0(NSProcessInfo, "processInfo");
            const username = macos.msgSend0(process_info, "userName");

            const user_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(username, "UTF8String"));
            const user_str = std.mem.span(user_cstr);

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftSystemCallback)window.__craftSystemCallback('{s}','getUsername','{s}');", .{ callback_id, user_str }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getUsername callback: {}", .{err});
            };
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

/// Global system bridge instance
var global_system_bridge: ?*SystemBridge = null;

pub fn getGlobalSystemBridge() ?*SystemBridge {
    return global_system_bridge;
}

pub fn setGlobalSystemBridge(bridge: *SystemBridge) void {
    global_system_bridge = bridge;
}
