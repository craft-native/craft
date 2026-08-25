const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const capabilities = @import("capabilities.zig");

/// The action names this bridge dispatches on.
///
/// Declared once, here, and referenced by both the dispatch chain below and the
/// capability table beside it — so the two cannot disagree. That is enforced:
/// `test/capabilities_test.zig` fails if a declared bridge compares `action`
/// against a bare string literal anywhere, which makes it impossible to add an
/// action without also declaring it.
pub const A = struct {
    pub const hide_dock_icon = "hideDockIcon";
    pub const show_dock_icon = "showDockIcon";
    pub const quit = "quit";
    pub const get_info = "getInfo";
    pub const notify = "notify";
    pub const set_badge = "setBadge";
    pub const bounce = "bounce";
};

/// What craft serves on the `app` namespace.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.hide_dock_icon, .reply = .none },
    .{ .name = A.show_dock_icon, .reply = .none },
    .{ .name = A.quit, .reply = .none },
    .{ .name = A.get_info, .reply = .result },
    .{ .name = A.notify, .reply = .none },
    .{ .name = A.set_badge, .reply = .none },
    .{ .name = A.bounce, .reply = .none },
};

/// Bridge handler for app-level control messages from JavaScript
pub const AppBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Handle app-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8) !void {
        self.handleMessageWithData(action, null) catch |err| {
            std.log.warn("app bridge message handling failed for '{s}': {}", .{ action, err });
        };
    }

    pub fn handleMessageWithData(self: *Self, action: []const u8, data: ?[]const u8) !void {
        if (std.mem.eql(u8, action, A.hide_dock_icon)) {
            try self.hideDockIcon();
        } else if (std.mem.eql(u8, action, A.show_dock_icon)) {
            try self.showDockIcon();
        } else if (std.mem.eql(u8, action, A.quit)) {
            try self.quit();
        } else if (std.mem.eql(u8, action, A.get_info)) {
            try self.getInfo();
        } else if (std.mem.eql(u8, action, A.notify)) {
            try self.notify(data);
        } else if (std.mem.eql(u8, action, A.set_badge)) {
            try self.setBadge(data);
        } else if (std.mem.eql(u8, action, A.bounce)) {
            try self.bounce();
        } else {
            if (comptime builtin.mode == .debug)
                std.debug.print("[AppBridge] Unknown action: {s}\n", .{action});
        }
    }

    fn hideDockIcon(self: *Self) !void {
        _ = self;
        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            const NSApplication = macos.getClass("NSApplication");
            const app = macos.msgSend0(NSApplication, "sharedApplication");

            // NSApplicationActivationPolicyAccessory = 1 (hides dock icon)
            const NSApplicationActivationPolicyAccessory: c_long = 1;
            _ = macos.msgSend1(app, "setActivationPolicy:", NSApplicationActivationPolicyAccessory);

            if (comptime builtin.mode == .debug)
                std.debug.print("[Bridge] Dock icon hidden\n", .{});
        }
    }

    fn showDockIcon(self: *Self) !void {
        _ = self;
        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            const NSApplication = macos.getClass("NSApplication");
            const app = macos.msgSend0(NSApplication, "sharedApplication");

            // NSApplicationActivationPolicyRegular = 0 (shows dock icon)
            const NSApplicationActivationPolicyRegular: c_long = 0;
            _ = macos.msgSend1(app, "setActivationPolicy:", NSApplicationActivationPolicyRegular);

            if (comptime builtin.mode == .debug)
                std.debug.print("[Bridge] Dock icon shown\n", .{});
        }
    }

    fn quit(self: *Self) !void {
        _ = self;
        if (builtin.os.tag == .macos) {
            // Restore any hidden menubar items before quitting
            const menubar_collapse = @import("menubar_collapse.zig");
            menubar_collapse.cleanup();

            const macos = @import("macos.zig");
            const NSApplication = macos.getClass("NSApplication");
            const app = macos.msgSend0(NSApplication, "sharedApplication");
            macos.msgSendVoid0(app, "terminate:");
        } else {
            std.process.exit(0);
        }
    }

    fn getInfo(self: *Self) !void {
        // Earlier this was an unimplemented stub that just logged a
        // debug line — JS callers got nothing back, ever. Read the
        // real bundle metadata via [NSBundle mainBundle].
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getInfo", "{\"name\":\"\",\"version\":\"\",\"bundleId\":\"\",\"bundlePath\":\"\",\"executablePath\":\"\"}");
            return;
        }
        const macos = @import("macos.zig");
        const NSBundle = macos.getClass("NSBundle");
        const bundle = macos.msgSend0(NSBundle, "mainBundle");

        // -objectForInfoDictionaryKey: returns NSString* or nil. Walk
        // the well-known keys; NSBundle handles their localised
        // resolution where applicable.
        const name = readBundleString(bundle, "CFBundleName") orelse readBundleString(bundle, "CFBundleDisplayName") orelse "";
        defer if (name.len > 0) std.heap.c_allocator.free(name);
        const version = readBundleString(bundle, "CFBundleShortVersionString") orelse readBundleString(bundle, "CFBundleVersion") orelse "";
        defer if (version.len > 0) std.heap.c_allocator.free(version);
        const bundle_id = readBundleString(bundle, "CFBundleIdentifier") orelse "";
        defer if (bundle_id.len > 0) std.heap.c_allocator.free(bundle_id);

        const bundle_path = readPath(bundle, "bundlePath") orelse "";
        defer if (bundle_path.len > 0) std.heap.c_allocator.free(bundle_path);
        const executable_path = readPath(bundle, "executablePath") orelse "";
        defer if (executable_path.len > 0) std.heap.c_allocator.free(executable_path);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{");
        try appendStrField(self.allocator, &buf, "name", name, true);
        try appendStrField(self.allocator, &buf, "version", version, false);
        try appendStrField(self.allocator, &buf, "bundleId", bundle_id, false);
        try appendStrField(self.allocator, &buf, "bundlePath", bundle_path, false);
        try appendStrField(self.allocator, &buf, "executablePath", executable_path, false);
        try buf.appendSlice(self.allocator, "}");

        const owned = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(owned);
        bridge_error.sendResultToJS(self.allocator, "getInfo", owned);
    }

    fn notify(self: *Self, data: ?[]const u8) !void {
        _ = self;
        if (data == null) return;

        // Earlier this used `indexOf("\"title\":\"")` + `indexOfPos`,
        // which broke on escaped quotes (`{"title":"a\"b"}`) and on any
        // payload with a string value containing the literal substring
        // `"title":"`. Use the JSON parser like every other bridge in
        // this file does post-fix.
        const ParseShape = struct {
            title: []const u8 = "Notification",
            body: []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(ParseShape, std.heap.c_allocator, data.?, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        const title = parsed.value.title;
        const body = parsed.value.body;

        if (comptime builtin.mode == .debug)
            std.debug.print("[AppBridge] Sending notification: {s} - {s}\n", .{ title, body });

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            macos.showNotification(title, body) catch |err| {
                if (comptime builtin.mode == .debug)
                    std.debug.print("[AppBridge] Notification error: {}\n", .{err});
            };
        }
    }

    fn setBadge(self: *Self, data: ?[]const u8) !void {
        _ = self;
        if (data == null) return;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // The TS facade and the JS bridge both send `{count:N}` —
            // earlier this only accepted `{badge:"<string>"}`, so the
            // dock tile never updated. Accept either shape: prefer
            // the modern `count` numeric, fall back to legacy `badge`
            // string for callers still on the old surface.
            const ParseShape = struct {
                count: ?i64 = null,
                badge: []const u8 = "",
            };
            const parsed = std.json.parseFromSlice(ParseShape, std.heap.c_allocator, data.?, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer parsed.deinit();

            const NSApplication = macos.getClass("NSApplication");
            const app = macos.msgSend0(NSApplication, "sharedApplication");
            const dock_tile = macos.msgSend0(app, "dockTile");

            // Pick the badge label — number wins, falls through to
            // explicit string, falls through to clear.
            var label_buf: [32]u8 = undefined;
            const label: ?[]const u8 = blk: {
                if (parsed.value.count) |n| {
                    if (n <= 0) break :blk null;
                    const s = std.fmt.bufPrint(&label_buf, "{d}", .{n}) catch break :blk null;
                    break :blk s;
                }
                if (parsed.value.badge.len > 0) break :blk parsed.value.badge;
                break :blk null;
            };

            if (label) |l| {
                const cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, l);
                defer std.heap.c_allocator.free(cstr);
                const NSString = macos.getClass("NSString");
                const str_alloc = macos.msgSend0(NSString, "alloc");
                const ns = macos.msgSend1(str_alloc, "initWithUTF8String:", cstr.ptr);
                _ = macos.msgSend1(dock_tile, "setBadgeLabel:", ns);
            } else {
                _ = macos.msgSend1(dock_tile, "setBadgeLabel:", @as(?*anyopaque, null));
            }
        }
    }

    fn bounce(self: *Self) !void {
        _ = self;
        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            const NSApplication = macos.getClass("NSApplication");
            const app = macos.msgSend0(NSApplication, "sharedApplication");

            // NSApplicationActivateIgnoringOtherApps + request user attention
            // NSInformationalRequest = 10
            const NSInformationalRequest: c_long = 10;
            _ = macos.msgSend1(app, "requestUserAttention:", NSInformationalRequest);
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

// =============================================================================
// Helpers for getInfo()
// =============================================================================

/// Read an NSBundle Info.plist string (e.g. CFBundleName) into an
/// owned UTF-8 slice on the c_allocator. Returns null when the key is
/// missing — callers OR-fallback to a sibling key per Apple convention.
fn readBundleString(bundle: anytype, key: []const u8) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const macos = @import("macos.zig");
    const ns_key = macos.createNSString(key);
    const value = macos.msgSend1(bundle, "objectForInfoDictionaryKey:", ns_key);
    if (@intFromPtr(value) == 0) return null;
    return copyNSStringUTF8(value);
}

/// NSBundle has direct getter selectors (`-bundlePath`, `-executablePath`)
/// for paths — these aren't dictionary keys.
fn readPath(bundle: anytype, selector: [*:0]const u8) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const macos = @import("macos.zig");
    const value = macos.msgSend0(bundle, selector);
    if (@intFromPtr(value) == 0) return null;
    return copyNSStringUTF8(value);
}

fn copyNSStringUTF8(ns_string: anytype) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const macos = @import("macos.zig");
    const utf8 = macos.msgSend0(ns_string, "UTF8String");
    if (@intFromPtr(utf8) == 0) return null;
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
    return std.heap.c_allocator.dupe(u8, slice) catch null;
}

fn appendStrField(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try buf.append(allocator, ',');
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, "\":\"");
    for (value) |b| {
        switch (b) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, b),
        }
    }
    try buf.append(allocator, '"');
}
