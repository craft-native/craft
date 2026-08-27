const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const logging = @import("logging.zig");

const log = logging.scoped("UpdaterBridge");

const BridgeError = bridge_error.BridgeError;

/// Auto-updater bridge using Sparkle framework
/// Sparkle must be linked with the application for this to work
pub const UpdaterBridge = struct {
    allocator: std.mem.Allocator,
    updater: ?*anyopaque = null,
    feed_url: ?[]const u8 = null,
    automatic_checks: bool = true,
    check_interval: u32 = 86400, // 24 hours in seconds

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Handle updater-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            self.reportError(action, err);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "configure")) {
            try self.configure(data);
        } else if (std.mem.eql(u8, action, "checkForUpdates")) {
            try self.checkForUpdates();
        } else if (std.mem.eql(u8, action, "checkForUpdatesInBackground")) {
            try self.checkForUpdatesInBackground();
        } else if (std.mem.eql(u8, action, "setAutomaticChecks")) {
            try self.setAutomaticChecks(data);
        } else if (std.mem.eql(u8, action, "setCheckInterval")) {
            try self.setCheckInterval(data);
        } else if (std.mem.eql(u8, action, "setFeedURL")) {
            try self.setFeedURL(data);
        } else if (std.mem.eql(u8, action, "getLastUpdateCheckDate")) {
            try self.getLastUpdateCheckDate();
        } else if (std.mem.eql(u8, action, "getUpdateInfo")) {
            try self.getUpdateInfo();
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

    /// Configure the updater with initial settings
    /// JSON: {"feedURL": "https://example.com/appcast.xml", "automaticChecks": true, "checkInterval": 86400}
    fn configure(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            self.sendStatus("unavailable", "Sparkle updater is only available on macOS");
            return;
        }

        const macos = @import("macos.zig");

        // Initialize SUUpdater shared instance
        const SUUpdater = macos.getClass("SUUpdater");
        if (SUUpdater == null) {
            log.debug("Sparkle framework not available", .{});
            self.sendStatus("unavailable", "Sparkle framework not linked");
            return;
        }

        self.updater = macos.msgSend0(SUUpdater, "sharedUpdater");
        if (self.updater == null) {
            log.debug("Failed to get shared updater", .{});
            return;
        }

        const ConfigureParams = struct {
            feedURL: []const u8 = "",
            automaticChecks: ?bool = null,
            checkInterval: ?u32 = null,
        };

        const parsed = std.json.parseFromSlice(ConfigureParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const params = parsed.value;

        // Set feed URL if provided.
        //
        // Two bugs fixed here:
        //   1. `url.ptr` is a plain `[]const u8` slice — not null-terminated.
        //      Passing it to `stringWithUTF8String:` caused ObjC to read past
        //      the slice end until it found a zero byte. Use `dupeZ`.
        //   2. The previous order was `free(old); dupe(new)` — if `dupe`
        //      returned `error.OutOfMemory`, `self.feed_url` still pointed at
        //      the freed buffer. Dupe first, then free the old pointer.
        if (params.feedURL.len > 0) {
            const url = params.feedURL;
            const new_feed = try self.allocator.dupe(u8, url);
            if (self.feed_url) |old_url| self.allocator.free(old_url);
            self.feed_url = new_feed;

            const url_z = try @import("memory.zig").dupeZ(self.allocator, u8, url);
            defer self.allocator.free(url_z);

            // NSString / NSURL are core Foundation classes and shouldn't be
            // missing on a supported macOS, but `getClass` returns null on
            // failure and msgSend1 on null is undefined behavior. Bail
            // loudly if anything's off.
            const NSString = macos.getClass("NSString");
            if (NSString == null) {
                log.warn("Foundation NSString class not available; skipping feed URL", .{});
                return;
            }
            const NSURL = macos.getClass("NSURL");
            if (NSURL == null) {
                log.warn("Foundation NSURL class not available; skipping feed URL", .{});
                return;
            }
            const url_str = macos.msgSend1(NSString, "stringWithUTF8String:", url_z.ptr);
            const nsurl = macos.msgSend1(NSURL, "URLWithString:", url_str);

            _ = macos.msgSend1(self.updater.?, "setFeedURL:", nsurl);
            log.debug("Feed URL set: {s}", .{url});
        }

        // Set automatic checks if provided
        if (params.automaticChecks) |auto_checks| {
            self.automatic_checks = auto_checks;
            _ = macos.msgSend1Bool(self.updater.?, "setAutomaticallyChecksForUpdates:", auto_checks);
        }

        // Set check interval if provided
        if (params.checkInterval) |interval| {
            self.check_interval = interval;
            _ = macos.msgSend1Double(self.updater.?, "setUpdateCheckInterval:", @floatFromInt(interval));
            log.debug("Check interval set: {d}s", .{interval});
        }

        self.sendStatus("configured", "Updater configured successfully");
    }

    /// Check for updates and show UI if available
    fn checkForUpdates(self: *Self) !void {
        if (comptime builtin.os.tag != .macos) {
            self.sendStatus("unavailable", "Sparkle updater is only available on macOS");
            return;
        }

        const macos = @import("macos.zig");

        if (self.updater == null) {
            // Try to get shared updater
            const SUUpdater = macos.getClass("SUUpdater");
            if (SUUpdater != null) {
                self.updater = macos.msgSend0(SUUpdater, "sharedUpdater");
            }
        }

        if (self.updater) |updater| {
            log.debug("Checking for updates...", .{});
            _ = macos.msgSend1(updater, "checkForUpdates:", @as(?*anyopaque, null));
            self.sendStatus("checking", "Checking for updates");
        } else {
            self.sendStatus("unavailable", "Updater not initialized");
        }
    }

    /// Check for updates silently in background
    fn checkForUpdatesInBackground(self: *Self) !void {
        if (comptime builtin.os.tag != .macos) {
            self.sendStatus("unavailable", "Sparkle updater is only available on macOS");
            return;
        }

        const macos = @import("macos.zig");

        if (self.updater == null) {
            const SUUpdater = macos.getClass("SUUpdater");
            if (SUUpdater != null) {
                self.updater = macos.msgSend0(SUUpdater, "sharedUpdater");
            }
        }

        if (self.updater) |updater| {
            log.debug("Checking for updates in background...", .{});
            _ = macos.msgSend0(updater, "checkForUpdatesInBackground");
            self.sendStatus("checking_background", "Checking for updates in background");
        }
    }

    /// Enable/disable automatic update checks
    /// JSON: {"enabled": true}
    fn setAutomaticChecks(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            self.sendStatus("unavailable", "Sparkle updater is only available on macOS");
            return;
        }

        const macos = @import("macos.zig");

        // `craft.updater.setAutomaticChecks(on)` sends `{"value":…}`; this
        // declared only `enabled`, so `ignore_unknown_fields` dropped the
        // boolean and every call read the `false` default — automatic checks
        // could be turned off but never on. `enabled` stays accepted.
        const EnabledParams = struct {
            value: ?bool = null,
            enabled: bool = false,
        };

        const parsed = std.json.parseFromSlice(EnabledParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const enabled = parsed.value.value orelse parsed.value.enabled;

        self.automatic_checks = enabled;

        if (self.updater) |updater| {
            _ = macos.msgSend1Bool(updater, "setAutomaticallyChecksForUpdates:", enabled);
            log.debug("Automatic checks: {}", .{enabled});
        }
    }

    /// Set the update check interval in seconds
    /// JSON: {"interval": 86400}
    fn setCheckInterval(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            self.sendStatus("unavailable", "Sparkle updater is only available on macOS");
            return;
        }

        const macos = @import("macos.zig");

        // Same mismatch: the page sends `{"seconds":…}` and this declared only
        // `interval`, so every interval silently stayed at the 24-hour default.
        const IntervalParams = struct {
            seconds: ?u32 = null,
            interval: u32 = 86400,
        };

        const parsed = std.json.parseFromSlice(IntervalParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const interval = parsed.value.seconds orelse parsed.value.interval;

        self.check_interval = interval;

        if (self.updater) |updater| {
            _ = macos.msgSend1Double(updater, "setUpdateCheckInterval:", @floatFromInt(interval));
            log.debug("Check interval: {d}s", .{interval});
        }
    }

    /// Set the appcast feed URL
    /// JSON: {"url": "https://example.com/appcast.xml"}
    fn setFeedURL(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            self.sendStatus("unavailable", "Sparkle updater is only available on macOS");
            return;
        }

        const macos = @import("macos.zig");

        const FeedURLParams = struct {
            url: []const u8 = "",
        };

        const parsed = std.json.parseFromSlice(FeedURLParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const url = parsed.value.url;

        // Same dupeZ + dupe-before-free pattern as `configure`.
        if (url.len > 0) {
            const new_feed = try self.allocator.dupe(u8, url);
            if (self.feed_url) |old_url| self.allocator.free(old_url);
            self.feed_url = new_feed;

            if (self.updater) |updater| {
                const url_z = try @import("memory.zig").dupeZ(self.allocator, u8, url);
                defer self.allocator.free(url_z);

                const NSString = macos.getClass("NSString");
                const url_str = macos.msgSend1(NSString, "stringWithUTF8String:", url_z.ptr);
                const NSURL = macos.getClass("NSURL");
                const nsurl = macos.msgSend1(NSURL, "URLWithString:", url_str);
                _ = macos.msgSend1(updater, "setFeedURL:", nsurl);
                log.debug("Feed URL: {s}", .{url});
            }
        }
    }

    /// Get the last update check date
    fn getLastUpdateCheckDate(self: *Self) !void {
        if (comptime builtin.os.tag != .macos) {
            self.sendStatus("unavailable", "Sparkle updater is only available on macOS");
            return;
        }

        const macos = @import("macos.zig");

        if (self.updater) |updater| {
            const date = macos.msgSend0(updater, "lastUpdateCheckDate");
            if (date) |d| {
                // Get time interval since 1970
                const interval = macos.msgSend0Double(d, "timeIntervalSince1970");
                const timestamp: i64 = @intFromFloat(interval * 1000); // Convert to milliseconds

                const bridge = @import("bridge.zig");
                var buf: [128]u8 = undefined;
                const js = std.fmt.bufPrint(&buf, "if(window.__craftUpdaterLastCheck)window.__craftUpdaterLastCheck({d});", .{timestamp}) catch return;

                bridge.evalJS(js) catch |err| {
                    std.log.debug("JS eval failed for updater last check callback: {}", .{err});
                };
            }
        }
    }

    /// Get current update info if available
    fn getUpdateInfo(self: *Self) !void {
        if (comptime builtin.os.tag != .macos) {
            self.sendStatus("unavailable", "Sparkle updater is only available on macOS");
            return;
        }

        const bridge = @import("bridge.zig");

        // Escape the feed URL before embedding in a JSON-looking JS literal.
        // A crafted feed URL containing `"` or `\` would otherwise break out
        // of the string and inject into the webview.
        var feed_buf: [1024]u8 = undefined;
        const feed_raw = self.feed_url orelse "";
        const feed_esc = bridge_error.escapeJsonString(&feed_buf, feed_raw) catch "";

        // Send current configuration
        var buf: [2048]u8 = undefined;
        const js = std.fmt.bufPrint(&buf,
            \\if(window.__craftUpdaterInfo)window.__craftUpdaterInfo({{
            \\"automaticChecks":{},
            \\"checkInterval":{d},
            \\"feedURL":"{s}"
            \\}});
        , .{
            self.automatic_checks,
            self.check_interval,
            feed_esc,
        }) catch return;

        bridge.evalJS(js) catch |err| {
            std.log.debug("JS eval failed for updater info callback: {}", .{err});
        };
    }

    /// Send status update to JavaScript. Escapes `status` and `message`
    /// before injection so a payload containing `'`/`\`/newline can't break
    /// out of the string literal (JS injection).
    fn sendStatus(_: *Self, status: []const u8, message: []const u8) void {
        const bridge = @import("bridge.zig");

        var status_buf: [64]u8 = undefined;
        var msg_buf: [256]u8 = undefined;
        const status_esc = bridge_error.escapeJsSingleQuoted(&status_buf, status) catch return;
        const msg_esc = bridge_error.escapeJsSingleQuoted(&msg_buf, message) catch return;

        var buf: [512]u8 = undefined;
        const js = std.fmt.bufPrint(&buf,
            \\if(window.__craftUpdaterStatus)window.__craftUpdaterStatus('{s}','{s}');
        , .{ status_esc, msg_esc }) catch return;

        bridge.evalJS(js) catch |err| {
            std.log.debug("JS eval failed for updater status callback: {}", .{err});
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.feed_url) |url| {
            self.allocator.free(url);
        }
    }
};

/// Global updater bridge instance
var global_updater_bridge: ?*UpdaterBridge = null;

pub fn getGlobalUpdaterBridge() ?*UpdaterBridge {
    return global_updater_bridge;
}

pub fn setGlobalUpdaterBridge(bridge: *UpdaterBridge) void {
    global_updater_bridge = bridge;
}
