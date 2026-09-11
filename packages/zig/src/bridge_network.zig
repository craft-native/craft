const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");

const BridgeError = bridge_error.BridgeError;

/// Network status bridge for connection monitoring
pub const NetworkBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Handle network-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            self.reportError(action, err);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "isConnected")) {
            try self.isConnected(data);
        } else if (std.mem.eql(u8, action, "getConnectionType")) {
            try self.getConnectionType(data);
        } else if (std.mem.eql(u8, action, "getWiFiSSID")) {
            try self.getWiFiSSID(data);
        } else if (std.mem.eql(u8, action, "getWiFiSignalStrength")) {
            try self.getWiFiSignalStrength(data);
        } else if (std.mem.eql(u8, action, "getIPAddress")) {
            try self.getIPAddress(data);
        } else if (std.mem.eql(u8, action, "getMACAddress")) {
            try self.getMACAddress(data);
        } else if (std.mem.eql(u8, action, "getNetworkInterfaces")) {
            try self.getNetworkInterfaces(data);
        } else if (std.mem.eql(u8, action, "isVPNConnected")) {
            try self.isVPNConnected(data);
        } else if (std.mem.eql(u8, action, "getProxySettings")) {
            try self.getProxySettings(data);
        } else if (std.mem.eql(u8, action, "openNetworkPreferences")) {
            try self.openNetworkPreferences(data);
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

    /// Check if device has network connectivity
    /// JSON: {"callbackId": "cb1"}
    fn isConnected(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] isConnected\n", .{});

        if (builtin.os.tag == .macos) {
            // Simple check: try to resolve a hostname
            // In a full implementation, use SCNetworkReachability
            // For now, assume connected if we can get to this code
            const connected = true;

            // Escape the caller-provided callback id — a crafted value
            // containing `'`/`\` would otherwise close the JS string literal.
            var cb_buf: [128]u8 = undefined;
            const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftNetworkCallback)window.__craftNetworkCallback('{s}','isConnected',{});", .{ cb_esc, connected }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for isConnected callback: {}", .{err});
            };
        }
    }

    /// Get connection type (wifi, ethernet, cellular, none)
    /// JSON: {"callbackId": "cb1"}
    fn getConnectionType(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] getConnectionType\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Check for WiFi using CoreWLAN via NSClassFromString
            // This is simplified - full implementation would check active interfaces
            const CWWiFiClient = macos.getClass("CWWiFiClient");
            var conn_type: []const u8 = "ethernet"; // Default assumption

            if (CWWiFiClient != null) {
                const shared_client = macos.msgSend0(CWWiFiClient, "sharedWiFiClient");
                if (shared_client != null) {
                    const interface = macos.msgSend0(shared_client, "interface");
                    if (interface != null) {
                        const power_on = macos.msgSendBool(interface, "powerOn");
                        if (power_on) {
                            conn_type = "wifi";
                        }
                    }
                }
            }

            var cb_buf: [128]u8 = undefined;
            const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftNetworkCallback)window.__craftNetworkCallback('{s}','getConnectionType','{s}');", .{ cb_esc, conn_type }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getConnectionType callback: {}", .{err});
            };
        }
    }

    /// Get current WiFi network name (SSID)
    /// JSON: {"callbackId": "cb1"}
    fn getWiFiSSID(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] getWiFiSSID\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            var ssid: []const u8 = "";

            const CWWiFiClient = macos.getClass("CWWiFiClient");
            if (CWWiFiClient != null) {
                const shared_client = macos.msgSend0(CWWiFiClient, "sharedWiFiClient");
                if (shared_client != null) {
                    const interface = macos.msgSend0(shared_client, "interface");
                    if (interface != null) {
                        const ssid_obj = macos.msgSend0(interface, "ssid");
                        if (ssid_obj != null) {
                            const ssid_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(ssid_obj, "UTF8String"));
                            if (ssid_cstr != null) {
                                ssid = std.mem.span(ssid_cstr);
                            }
                        }
                    }
                }
            }

            // SSID is attacker-controlled (anyone can name a WiFi network).
            // Escape before injecting into JS to block injection via crafted
            // network names.
            var cb_buf: [128]u8 = undefined;
            var ssid_buf: [256]u8 = undefined;
            const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;
            const ssid_esc = bridge_error.escapeJsSingleQuoted(&ssid_buf, ssid) catch return;

            var buf: [768]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftNetworkCallback)window.__craftNetworkCallback('{s}','getWiFiSSID','{s}');", .{ cb_esc, ssid_esc }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getWiFiSSID callback: {}", .{err});
            };
        }
    }

    /// Get WiFi signal strength (RSSI in dBm)
    /// JSON: {"callbackId": "cb1"}
    fn getWiFiSignalStrength(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] getWiFiSignalStrength\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            var rssi: i32 = 0;

            const CWWiFiClient = macos.getClass("CWWiFiClient");
            if (CWWiFiClient != null) {
                const shared_client = macos.msgSend0(CWWiFiClient, "sharedWiFiClient");
                if (shared_client != null) {
                    const interface = macos.msgSend0(shared_client, "interface");
                    if (interface != null) {
                        // `rssiValue` returns NSInteger (signed). Typical WiFi
                        // RSSI is negative (e.g. -60 dBm) so `@intCast` from
                        // the raw pointer-sized word to i32 used to panic in
                        // safety-checked builds. Take the word as isize first.
                        const raw: isize = @bitCast(@intFromPtr(macos.msgSend0(interface, "rssiValue")));
                        rssi = @intCast(std.math.clamp(raw, std.math.minInt(i32), std.math.maxInt(i32)));
                    }
                }
            }

            var cb_buf: [128]u8 = undefined;
            const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftNetworkCallback)window.__craftNetworkCallback('{s}','getWiFiSignalStrength',{d});", .{ cb_esc, rssi }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getWiFiSignalStrength callback: {}", .{err});
            };
        }
    }

    /// Get IP address of primary interface
    /// JSON: {"callbackId": "cb1"}
    fn getIPAddress(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] getIPAddress\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Get local IP using NSHost
            const NSHost = macos.getClass("NSHost");
            const current_host = macos.msgSend0(NSHost, "currentHost");
            const addresses = macos.msgSend0(current_host, "addresses");

            var ip_addr: []const u8 = "";

            // Get first non-localhost address. `count` returns NSUInteger,
            // but `@intFromPtr` on a negative/error return wraps huge —
            // guard through isize.
            const raw_count: isize = @bitCast(@intFromPtr(macos.msgSend0(addresses, "count")));
            const count: usize = if (raw_count > 0) @intCast(raw_count) else 0;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const addr_obj = macos.msgSend1(addresses, "objectAtIndex:", i);
                const addr_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(addr_obj, "UTF8String"));
                const addr_str = std.mem.span(addr_cstr);

                // Skip localhost and IPv6
                if (!std.mem.startsWith(u8, addr_str, "127.") and
                    !std.mem.startsWith(u8, addr_str, "::") and
                    !std.mem.startsWith(u8, addr_str, "fe80"))
                {
                    // Check if it looks like IPv4
                    if (std.mem.indexOf(u8, addr_str, ".") != null and
                        std.mem.indexOf(u8, addr_str, ":") == null)
                    {
                        ip_addr = addr_str;
                        break;
                    }
                }
            }

            // Escape both the callback id and the IP. The IP comes from
            // NSHost (trusted) but future implementations might pull from
            // attacker-controlled DHCP hints, so we escape defensively.
            var cb_buf: [128]u8 = undefined;
            var ip_buf: [128]u8 = undefined;
            const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;
            const ip_esc = bridge_error.escapeJsSingleQuoted(&ip_buf, ip_addr) catch return;

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftNetworkCallback)window.__craftNetworkCallback('{s}','getIPAddress','{s}');", .{ cb_esc, ip_esc }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getIPAddress callback: {}", .{err});
            };
        }
    }

    /// Get MAC address of primary interface
    /// JSON: {"callbackId": "cb1"}
    fn getMACAddress(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] getMACAddress\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            var mac_addr: []const u8 = "";

            const CWWiFiClient = macos.getClass("CWWiFiClient");
            if (CWWiFiClient != null) {
                const shared_client = macos.msgSend0(CWWiFiClient, "sharedWiFiClient");
                if (shared_client != null) {
                    const interface = macos.msgSend0(shared_client, "interface");
                    if (interface != null) {
                        const hw_addr = macos.msgSend0(interface, "hardwareAddress");
                        if (hw_addr != null) {
                            const mac_cstr: [*c]const u8 = @ptrCast(macos.msgSend0(hw_addr, "UTF8String"));
                            if (mac_cstr != null) {
                                mac_addr = std.mem.span(mac_cstr);
                            }
                        }
                    }
                }
            }

            var cb_buf: [128]u8 = undefined;
            var mac_buf: [64]u8 = undefined;
            const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;
            const mac_esc = bridge_error.escapeJsSingleQuoted(&mac_buf, mac_addr) catch return;

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftNetworkCallback)window.__craftNetworkCallback('{s}','getMACAddress','{s}');", .{ cb_esc, mac_esc }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getMACAddress callback: {}", .{err});
            };
        }
    }

    /// Get list of network interfaces
    /// JSON: {"callbackId": "cb1"}
    fn getNetworkInterfaces(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] getNetworkInterfaces\n", .{});

        if (builtin.os.tag == .macos) {
            // Return basic interface info
            // Full implementation would use getifaddrs
            var cb_buf: [128]u8 = undefined;
            const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;

            var buf: [1024]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftNetworkCallback)window.__craftNetworkCallback('{s}','getNetworkInterfaces',[{{name:'en0',type:'wifi'}},{{name:'en1',type:'ethernet'}}]);", .{cb_esc}) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getNetworkInterfaces callback: {}", .{err});
            };
        }
    }

    /// Check if VPN is connected
    /// JSON: {"callbackId": "cb1"}
    fn isVPNConnected(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] isVPNConnected\n", .{});

        if (builtin.os.tag == .macos) {
            // Check for utun interfaces which indicate VPN
            // Simplified - full implementation would check NEVPNManager
            const vpn_connected = false;

            var cb_buf: [128]u8 = undefined;
            const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftNetworkCallback)window.__craftNetworkCallback('{s}','isVPNConnected',{});", .{ cb_esc, vpn_connected }) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for isVPNConnected callback: {}", .{err});
            };
        }
    }

    /// Get proxy settings
    /// JSON: {"callbackId": "cb1"}
    fn getProxySettings(self: *Self, data: []const u8) !void {
        _ = self;
        var callback_id: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"callbackId\":\"")) |idx| {
            const start = idx + 14;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                callback_id = data[start..end];
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] getProxySettings\n", .{});

        if (builtin.os.tag == .macos) {
            // Return null for no proxy
            // Full implementation would use SCDynamicStoreCopyProxies
            var cb_buf: [128]u8 = undefined;
            const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;

            var buf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&buf, "if(window.__craftNetworkCallback)window.__craftNetworkCallback('{s}','getProxySettings',null);", .{cb_esc}) catch return;

            const cross_bridge = @import("bridge.zig");
            cross_bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getProxySettings callback: {}", .{err});
            };
        }
    }

    /// Open Network Preferences pane
    /// JSON: {}
    fn openNetworkPreferences(self: *Self, data: []const u8) !void {
        _ = self;
        _ = data;

        if (comptime builtin.mode == .Debug)
            std.debug.print("[NetworkBridge] openNetworkPreferences\n", .{});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSWorkspace = macos.getClass("NSWorkspace");
            const workspace = macos.msgSend0(NSWorkspace, "sharedWorkspace");

            const NSString = macos.getClass("NSString");
            // String literals are `[*:0]const u8`. Pass `.ptr` explicitly
            // rather than relying on an implicit conversion to the legacy
            // `[*c]const u8` shape — the previous cast compiled but was
            // fragile against tighter comptime type checks.
            const url_literal: [*:0]const u8 = "x-apple.systempreferences:com.apple.preference.network";
            const url_str = macos.msgSend1(NSString, "stringWithUTF8String:", url_literal);

            const NSURL = macos.getClass("NSURL");
            const nsurl = macos.msgSend1(NSURL, "URLWithString:", url_str);

            _ = macos.msgSend1(workspace, "openURL:", nsurl);
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

const global_state = @import("global_state.zig");

/// Global accessors route through `global_state` for thread-safety, matching
/// the rest of the bridges. The previous module-level `var` was read/written
/// without any locking.
pub fn getGlobalNetworkBridge() ?*NetworkBridge {
    return global_state.instance.getNetworkBridge();
}

pub fn setGlobalNetworkBridge(bridge: *NetworkBridge) void {
    global_state.instance.setNetworkBridge(bridge);
}
