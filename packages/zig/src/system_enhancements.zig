const std = @import("std");
const io_context = @import("io_context.zig");
const builtin = @import("builtin");

/// An environment variable as a slice, or null when it is unset.
///
/// libc rather than std: `std.posix` has no `getenv` in this compiler version,
/// and this build links libc everywhere.
fn envOrEmpty(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// System-level enhancements for Craft framework
/// Includes: keyboard shortcuts, system events, dock features, etc.

// ============================================================================
// 1. Dock Features (macOS)
// ============================================================================

// Objective-C runtime types (manual declarations for Zig 0.16+ compatibility)
const objc = if (builtin.os.tag == .macos) struct {
    pub const id = ?*anyopaque;
    pub const Class = ?*anyopaque;
    pub const SEL = ?*anyopaque;
    pub const IMP = ?*anyopaque;
    pub const BOOL = bool;

    pub extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
    pub extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
    pub extern "objc" fn objc_msgSend() void;
} else struct {
    pub const id = *anyopaque;
    pub const Class = *anyopaque;
    pub const SEL = *anyopaque;
};

// Carbon framework types for global hotkeys (macOS)
const carbon = if (builtin.os.tag == .macos) struct {
    pub const EventHotKeyRef = ?*anyopaque;
    pub const EventTargetRef = ?*anyopaque;

    pub const EventHotKeyID = extern struct {
        signature: u32,
        id: u32,
    };

    // Carbon HIToolbox functions
    pub extern "Carbon" fn RegisterEventHotKey(
        inHotKeyCode: u32,
        inHotKeyModifiers: u32,
        inHotKeyID: EventHotKeyID,
        inTarget: EventTargetRef,
        inOptions: u32,
        outRef: *EventHotKeyRef,
    ) callconv(.c) i32;

    pub extern "Carbon" fn UnregisterEventHotKey(
        inHotKey: EventHotKeyRef,
    ) callconv(.c) i32;

    pub extern "Carbon" fn GetApplicationEventTarget() callconv(.c) EventTargetRef;
} else struct {
    pub const EventHotKeyRef = *anyopaque;
    pub const EventTargetRef = *anyopaque;
    pub const EventHotKeyID = struct { signature: u32, id: u32 };
};

pub const DockFeatures = struct {
    /// Set dock badge (notification count)
    pub fn setBadge(text: []const u8) !void {
        if (builtin.os.tag != .macos) return;

        const NSApp = objc.objc_getClass("NSApplication");
        const app = msgSend0(NSApp, "sharedApplication");
        const dockTile = msgSend0(app, "dockTile");

        const NSString = objc.objc_getClass("NSString");
        const badgeStr = msgSend1(NSString, "stringWithUTF8String:", text.ptr);
        _ = msgSend1(dockTile, "setBadgeLabel:", badgeStr);
    }

    /// Clear dock badge
    pub fn clearBadge() !void {
        if (builtin.os.tag != .macos) return;

        const NSApp = objc.objc_getClass("NSApplication");
        const app = msgSend0(NSApp, "sharedApplication");
        const dockTile = msgSend0(app, "dockTile");

        const NSString = objc.objc_getClass("NSString");
        const emptyStr = msgSend1(NSString, "string");
        _ = msgSend1(dockTile, "setBadgeLabel:", emptyStr);
    }

    /// Set dock progress (0.0 to 1.0)
    /// Uses NSDockTile with a custom progress view
    pub fn setProgress(progress: f64) !void {
        if (builtin.os.tag != .macos) return;

        const NSApp = objc.objc_getClass("NSApplication");
        const app = msgSend0(NSApp, "sharedApplication");
        const dockTile = msgSend0(app, "dockTile");

        // Get or create progress indicator view
        var contentView = msgSend0(dockTile, "contentView");

        if (@intFromPtr(contentView) == 0) {
            // Create a new view for the dock tile
            const NSView = objc.objc_getClass("NSView");
            const NSMakeRect_fn = @as(
                *const fn (f64, f64, f64, f64) callconv(.c) NSRect,
                @ptrCast(&objc.objc_msgSend),
            );
            _ = NSMakeRect_fn;

            contentView = msgSend0(msgSend0(NSView, "alloc"), "init");

            // Set the content view
            msgSendVoid1(dockTile, "setContentView:", contentView);
        }

        // Create/update progress indicator
        const NSProgressIndicator = objc.objc_getClass("NSProgressIndicator");
        const progressIndicator = msgSend0(msgSend0(NSProgressIndicator, "alloc"), "init");

        // Configure progress indicator
        const setDoubleValue = @as(
            *const fn (@TypeOf(progressIndicator), objc.SEL, f64) callconv(.c) void,
            @ptrCast(&objc.objc_msgSend),
        );
        setDoubleValue(progressIndicator, objc.sel_registerName("setMinValue:"), 0.0);
        setDoubleValue(progressIndicator, objc.sel_registerName("setMaxValue:"), 1.0);
        setDoubleValue(progressIndicator, objc.sel_registerName("setDoubleValue:"), progress);

        // Set as indeterminate if progress is negative, determinate otherwise
        const setIndeterminate = @as(
            *const fn (@TypeOf(progressIndicator), objc.SEL, c_int) callconv(.c) void,
            @ptrCast(&objc.objc_msgSend),
        );
        setIndeterminate(progressIndicator, objc.sel_registerName("setIndeterminate:"), if (progress < 0) 1 else 0);

        // Set frame
        msgSendVoid1(progressIndicator, "setFrame:", NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 128, .height = 10 },
        });

        // Add to content view and display
        msgSendVoid1(contentView, "addSubview:", progressIndicator);

        // Force dock tile update
        msgSendVoid0(dockTile, "display");
    }

    /// Clear dock progress indicator
    pub fn clearProgress() !void {
        if (builtin.os.tag != .macos) return;

        const NSApp = objc.objc_getClass("NSApplication");
        const app = msgSend0(NSApp, "sharedApplication");
        const dockTile = msgSend0(app, "dockTile");

        // Remove content view to restore default dock icon
        msgSendVoid1(dockTile, "setContentView:", @as(objc.id, null));
        msgSendVoid0(dockTile, "display");
    }

    /// Bounce dock icon to get attention
    pub fn bounce(critical: bool) !void {
        if (builtin.os.tag != .macos) return;

        const NSApp = objc.objc_getClass("NSApplication");
        const app = msgSend0(NSApp, "sharedApplication");

        const requestType: c_long = if (critical) 0 else 1; // 0 = Critical, 1 = Informational
        _ = msgSend1(app, "requestUserAttention:", requestType);
    }
};

// ============================================================================
// 2. Window Positioning Helpers
// ============================================================================

pub const WindowPosition = struct {
    pub fn center(window: *anyopaque) !void {
        if (builtin.os.tag != .macos) return;

        const nsWindow: objc.id = @ptrFromInt(@intFromPtr(window));
        msgSendVoid0(nsWindow, "center");
    }

    pub fn positionNearTray(window: *anyopaque, statusItem: *anyopaque) !void {
        if (builtin.os.tag != .macos) return;

        const nsWindow: objc.id = @ptrFromInt(@intFromPtr(window));
        const nsStatusItem: objc.id = @ptrFromInt(@intFromPtr(statusItem));

        // Get status item button
        const button = msgSend0(nsStatusItem, "button");
        const buttonWindow = msgSend0(button, "window");

        // Get button frame
        const buttonFrame = msgSendFrame(buttonWindow, "frame");

        // Position window below button
        const windowFrame = msgSendFrame(nsWindow, "frame");

        const NSMakeRect = @import("std").mem.zeroInit(NSRect, .{});
        _ = NSMakeRect;

        const newX = buttonFrame.origin.x;
        const newY = buttonFrame.origin.y - windowFrame.size.height - 5; // 5px gap

        const origin = NSPoint{ .x = newX, .y = newY };
        msgSendVoid1(nsWindow, "setFrameTopLeftPoint:", origin);
    }
};

// ============================================================================
// 3. Window Vibrancy Effects (macOS)
// ============================================================================

pub const VibrancyEffect = enum {
    light,
    dark,
    titlebar,
    selection,
    menu,
    popover,
    sidebar,
    header_view,
    sheet,
    window_background,
    hud_window,
    fullscreen_ui,
    tooltip,
    content_background,
    under_window_background,
    under_page_background,
};

pub const WindowVibrancy = struct {
    /// Set window vibrancy effect (macOS translucent background)
    pub fn setVibrancy(window: *anyopaque, effect: VibrancyEffect) !void {
        if (builtin.os.tag != .macos) return error.PlatformNotSupported;

        const nsWindow: objc.id = @ptrFromInt(@intFromPtr(window));

        // Create NSVisualEffectView
        const NSVisualEffectView = objc.objc_getClass("NSVisualEffectView");
        const effectView = msgSend0(msgSend0(NSVisualEffectView, "alloc"), "init");

        // Set material based on effect type
        const material: c_long = switch (effect) {
            .light => 1, // NSVisualEffectMaterialLight
            .dark => 2, // NSVisualEffectMaterialDark
            .titlebar => 3, // NSVisualEffectMaterialTitlebar
            .selection => 4, // NSVisualEffectMaterialSelection
            .menu => 5, // NSVisualEffectMaterialMenu
            .popover => 6, // NSVisualEffectMaterialPopover
            .sidebar => 7, // NSVisualEffectMaterialSidebar
            .header_view => 10, // NSVisualEffectMaterialHeaderView
            .sheet => 11, // NSVisualEffectMaterialSheet
            .window_background => 12, // NSVisualEffectMaterialWindowBackground
            .hud_window => 13, // NSVisualEffectMaterialHUDWindow
            .fullscreen_ui => 14, // NSVisualEffectMaterialFullScreenUI
            .tooltip => 15, // NSVisualEffectMaterialToolTip
            .content_background => 16, // NSVisualEffectMaterialContentBackground
            .under_window_background => 17, // NSVisualEffectMaterialUnderWindowBackground
            .under_page_background => 18, // NSVisualEffectMaterialUnderPageBackground
        };

        _ = msgSend1(effectView, "setMaterial:", material);

        // Set blending mode
        const NSVisualEffectBlendingModeBehindWindow: c_long = 0;
        _ = msgSend1(effectView, "setBlendingMode:", NSVisualEffectBlendingModeBehindWindow);

        // Set state to active
        const NSVisualEffectStateActive: c_long = 1;
        _ = msgSend1(effectView, "setState:", NSVisualEffectStateActive);

        // Get window content view
        const contentView = msgSend0(nsWindow, "contentView");

        // Get content view bounds
        const bounds = msgSendFrame(contentView, "bounds");

        // Set effect view frame to match content view
        msgSendVoid1(effectView, "setFrame:", bounds);

        // Set autoresizing mask to follow window
        const NSViewWidthSizable: c_ulong = 2;
        const NSViewHeightSizable: c_ulong = 16;
        _ = msgSend1(effectView, "setAutoresizingMask:", NSViewWidthSizable | NSViewHeightSizable);

        // Add effect view as subview
        msgSendVoid1(contentView, "addSubview:positioned:relativeTo:", effectView);

        // Make window background transparent
        msgSendVoid1(nsWindow, "setOpaque:", @as(c_int, 0));
        const NSColor = objc.objc_getClass("NSColor");
        const clearColor = msgSend0(NSColor, "clearColor");
        _ = msgSend1(nsWindow, "setBackgroundColor:", clearColor);
    }

    /// Remove vibrancy effect
    pub fn removeVibrancy(window: *anyopaque) !void {
        if (builtin.os.tag != .macos) return error.PlatformNotSupported;

        const nsWindow: objc.id = @ptrFromInt(@intFromPtr(window));

        // Reset window to opaque
        msgSendVoid1(nsWindow, "setOpaque:", @as(c_int, 1));

        // Get content view and remove effect views
        const contentView = msgSend0(nsWindow, "contentView");
        const subviews = msgSend0(contentView, "subviews");
        const count = msgSend0(subviews, "count");

        var i: usize = 0;
        while (i < @as(usize, @intCast(count))) : (i += 1) {
            const subview = msgSend1(subviews, "objectAtIndex:", i);
            const className = msgSend0(msgSend0(subview, "class"), "description");
            const classNameStr = msgSend0(className, "UTF8String");

            // Check if it's an NSVisualEffectView
            if (std.mem.indexOf(u8, std.mem.span(@as([*:0]const u8, @ptrCast(classNameStr))), "NSVisualEffectView") != null) {
                msgSendVoid0(subview, "removeFromSuperview");
            }
        }
    }
};

// ============================================================================
// 4. System Event Listeners
// ============================================================================

pub const SystemEvents = struct {
    sleep_callback: ?*const fn () void = null,
    wake_callback: ?*const fn () void = null,
    screen_lock_callback: ?*const fn () void = null,

    pub fn init() SystemEvents {
        return .{};
    }

    pub fn onSleep(self: *SystemEvents, callback: *const fn () void) void {
        self.sleep_callback = callback;
        if (builtin.os.tag == .macos) {
            macOSRegisterSleepWake(self);
        }
    }

    pub fn onWake(self: *SystemEvents, callback: *const fn () void) void {
        self.wake_callback = callback;
    }

    pub fn onScreenLock(self: *SystemEvents, callback: *const fn () void) void {
        self.screen_lock_callback = callback;
    }

    // Static reference for callback access
    var global_events: ?*SystemEvents = null;

    fn macOSRegisterSleepWake(self: *SystemEvents) void {
        if (builtin.os.tag != .macos) return;

        global_events = self;

        // Get NSWorkspace shared workspace
        const NSWorkspace = objc.objc_getClass("NSWorkspace");
        const workspace = msgSend0(NSWorkspace, "sharedWorkspace");
        const notificationCenter = msgSend0(workspace, "notificationCenter");

        // Create notification names
        const NSString = objc.objc_getClass("NSString");
        const sleepNotification = msgSend1(
            NSString,
            "stringWithUTF8String:",
            @as([*:0]const u8, "NSWorkspaceWillSleepNotification"),
        );
        const wakeNotification = msgSend1(
            NSString,
            "stringWithUTF8String:",
            @as([*:0]const u8, "NSWorkspaceDidWakeNotification"),
        );
        const screenLockNotification = msgSend1(
            NSString,
            "stringWithUTF8String:",
            @as([*:0]const u8, "NSWorkspaceScreensDidSleepNotification"),
        );

        // Create observer block-like handler class
        const NSObject = objc.objc_getClass("NSObject");
        const class_name = "CraftSystemEventObserver";

        var observer_class = objc.objc_getClass(class_name);
        if (observer_class == null) {
            observer_class = objc.objc_allocateClassPair(NSObject, class_name, 0);

            // Add handleSleep: method
            const handleSleep = @as(
                *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
                @ptrCast(@constCast(&onSleepNotification)),
            );
            _ = objc.class_addMethod(
                observer_class,
                objc.sel_registerName("handleSleep:"),
                @ptrCast(@constCast(handleSleep)),
                "v@:@",
            );

            // Add handleWake: method
            const handleWake = @as(
                *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
                @ptrCast(@constCast(&onWakeNotification)),
            );
            _ = objc.class_addMethod(
                observer_class,
                objc.sel_registerName("handleWake:"),
                @ptrCast(@constCast(handleWake)),
                "v@:@",
            );

            // Add handleScreenLock: method
            const handleScreenLock = @as(
                *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
                @ptrCast(@constCast(&onScreenLockNotification)),
            );
            _ = objc.class_addMethod(
                observer_class,
                objc.sel_registerName("handleScreenLock:"),
                @ptrCast(@constCast(handleScreenLock)),
                "v@:@",
            );

            objc.objc_registerClassPair(observer_class);
        }

        // Create observer instance
        const observer = msgSend0(msgSend0(observer_class.?, "alloc"), "init");

        // Add observers for notifications
        const addObserver = @as(
            *const fn (objc.id, objc.SEL, objc.id, objc.SEL, objc.id, objc.id) callconv(.c) void,
            @ptrCast(&objc.objc_msgSend),
        );

        addObserver(
            notificationCenter,
            objc.sel_registerName("addObserver:selector:name:object:"),
            observer,
            objc.sel_registerName("handleSleep:"),
            sleepNotification,
            @as(objc.id, null),
        );

        addObserver(
            notificationCenter,
            objc.sel_registerName("addObserver:selector:name:object:"),
            observer,
            objc.sel_registerName("handleWake:"),
            wakeNotification,
            @as(objc.id, null),
        );

        addObserver(
            notificationCenter,
            objc.sel_registerName("addObserver:selector:name:object:"),
            observer,
            objc.sel_registerName("handleScreenLock:"),
            screenLockNotification,
            @as(objc.id, null),
        );

        std.debug.print("[SystemEvents] Registered for sleep/wake/screen lock notifications\n", .{});
    }
};

// Notification handler functions (must be at file scope for export)
fn onSleepNotification(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    std.debug.print("[SystemEvents] System will sleep\n", .{});
    if (SystemEvents.global_events) |events| {
        if (events.sleep_callback) |callback| {
            callback();
        }
    }
}

fn onWakeNotification(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    std.debug.print("[SystemEvents] System did wake\n", .{});
    if (SystemEvents.global_events) |events| {
        if (events.wake_callback) |callback| {
            callback();
        }
    }
}

fn onScreenLockNotification(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    std.debug.print("[SystemEvents] Screen locked\n", .{});
    if (SystemEvents.global_events) |events| {
        if (events.screen_lock_callback) |callback| {
            callback();
        }
    }
}

// ============================================================================
// 4. Global Keyboard Shortcuts (macOS Carbon)
// ============================================================================

pub const HotkeyManager = struct {
    hotkeys: std.ArrayList(Hotkey),
    allocator: std.mem.Allocator,

    pub const Hotkey = struct {
        id: u32,
        key_code: u32,
        modifiers: u32,
        callback: *const fn () void,
    };

    pub fn init(allocator: std.mem.Allocator) HotkeyManager {
        return .{
            .hotkeys = std.ArrayList(Hotkey).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HotkeyManager) void {
        // Unregister all hotkeys on macOS using Carbon
        if (builtin.os.tag == .macos) {
            for (self.hotkeys.items) |hotkey| {
                // Use Carbon UnregisterEventHotKey
                // The hotkey ref is stored as the id in our Hotkey struct
                const hotkey_ref: carbon.EventHotKeyRef = @ptrFromInt(hotkey.id);
                _ = carbon.UnregisterEventHotKey(hotkey_ref);
            }
        }
        self.hotkeys.deinit();
    }

    /// Register a global hotkey
    /// key_code: Virtual key code (e.g., 35 for 'P')
    /// modifiers: cmdKey (256), shiftKey (512), optionKey (2048), controlKey (4096)
    pub fn register(self: *HotkeyManager, key_code: u32, modifiers: u32, callback: *const fn () void) !void {
        const id = @as(u32, @intCast(self.hotkeys.items.len + 1));

        if (builtin.os.tag == .macos) {
            // Register hotkey using Carbon API
            const signature: u32 = 0x63726674; // 'crft' (craft signature)
            const hotkey_id = carbon.EventHotKeyID{
                .signature = signature,
                .id = id,
            };

            var hotkey_ref: carbon.EventHotKeyRef = null;
            const target = carbon.GetApplicationEventTarget();

            const result = carbon.RegisterEventHotKey(
                key_code,
                modifiers,
                hotkey_id,
                target,
                0, // options
                &hotkey_ref,
            );

            if (result != 0) {
                return error.HotkeyRegistrationFailed;
            }

            // Store the hotkey reference as the id
            try self.hotkeys.append(.{
                .id = @intFromPtr(hotkey_ref),
                .key_code = key_code,
                .modifiers = modifiers,
                .callback = callback,
            });
        } else {
            // Non-macOS: just store the hotkey
            try self.hotkeys.append(.{
                .id = id,
                .key_code = key_code,
                .modifiers = modifiers,
                .callback = callback,
            });
        }
    }

    /// Parse shortcut string like "Cmd+Shift+P" to key code and modifiers
    pub fn parseShortcut(shortcut: []const u8) struct { key_code: u32, modifiers: u32 } {
        var modifiers: u32 = 0;
        var key_code: u32 = 0;

        // Simple parser (could be enhanced)
        if (std.mem.indexOf(u8, shortcut, "Cmd") != null) modifiers |= 256;
        if (std.mem.indexOf(u8, shortcut, "Shift") != null) modifiers |= 512;
        if (std.mem.indexOf(u8, shortcut, "Option") != null or std.mem.indexOf(u8, shortcut, "Alt") != null) modifiers |= 2048;
        if (std.mem.indexOf(u8, shortcut, "Ctrl") != null or std.mem.indexOf(u8, shortcut, "Control") != null) modifiers |= 4096;

        // Extract last character as key
        if (shortcut.len > 0) {
            const last_char = shortcut[shortcut.len - 1];
            key_code = @as(u32, last_char);
        }

        return .{ .key_code = key_code, .modifiers = modifiers };
    }
};

// ============================================================================
// 5. Local Storage Helper
// ============================================================================

pub const LocalStorage = struct {
    file_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, app_name: []const u8) !LocalStorage {
        // Create path: ~/Library/Application Support/<app_name>/storage.json (macOS)
        const home = envOrEmpty("HOME") orelse return error.NoHomeDir;

        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/Library/Application Support/{s}/storage.json",
            .{ home, app_name },
        );

        // Ensure directory exists
        const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
        try io_context.cwd().createDirPath(io_context.get(), dir_path);

        return .{
            .file_path = path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LocalStorage) void {
        self.allocator.free(self.file_path);
    }

    pub fn set(self: *LocalStorage, key: []const u8, value: []const u8) !void {
        // Load existing data
        const data = try self.loadAll();
        defer self.allocator.free(data);

        // Parse existing JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            // If parsing fails, start fresh
            return try self.writeJson(&.{.{ key, value }});
        };
        defer parsed.deinit();

        // Build new JSON with updated key
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        try output.appendSlice("{");

        var first = true;
        var key_found = false;

        // Copy existing keys, updating the target key
        if (parsed.value == .object) {
            var iter = parsed.value.object.iterator();
            while (iter.next()) |entry| {
                if (!first) try output.appendSlice(",");
                first = false;

                try output.appendSlice("\"");
                try output.appendSlice(entry.key_ptr.*);
                try output.appendSlice("\":");

                if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                    key_found = true;
                    try output.appendSlice("\"");
                    try output.appendSlice(value);
                    try output.appendSlice("\"");
                } else if (entry.value_ptr.* == .string) {
                    try output.appendSlice("\"");
                    try output.appendSlice(entry.value_ptr.*.string);
                    try output.appendSlice("\"");
                } else {
                    // For non-string values, stringify
                    try std.json.stringify(entry.value_ptr.*, .{}, output.writer());
                }
            }
        }

        // Add new key if not found
        if (!key_found) {
            if (!first) try output.appendSlice(",");
            try output.appendSlice("\"");
            try output.appendSlice(key);
            try output.appendSlice("\":\"");
            try output.appendSlice(value);
            try output.appendSlice("\"");
        }

        try output.appendSlice("}");

        // Write to file
        const io = io_context.get();
        const file = try io_context.cwd().createFile(io, self.file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, output.items);
    }

    pub fn get(self: *LocalStorage, key: []const u8) !?[]const u8 {
        // Load and parse JSON
        const data = try self.loadAll();
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            return null;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return null;

        if (parsed.value.object.get(key)) |val| {
            if (val == .string) {
                return try self.allocator.dupe(u8, val.string);
            }
        }

        return null;
    }

    pub fn remove(self: *LocalStorage, key: []const u8) !void {
        const data = try self.loadAll();
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            return; // Nothing to remove
        };
        defer parsed.deinit();

        if (parsed.value != .object) return;

        // Build new JSON without the key
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        try output.appendSlice("{");

        var first = true;
        var iter = parsed.value.object.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) continue;

            if (!first) try output.appendSlice(",");
            first = false;

            try output.appendSlice("\"");
            try output.appendSlice(entry.key_ptr.*);
            try output.appendSlice("\":");

            if (entry.value_ptr.* == .string) {
                try output.appendSlice("\"");
                try output.appendSlice(entry.value_ptr.*.string);
                try output.appendSlice("\"");
            } else {
                try std.json.stringify(entry.value_ptr.*, .{}, output.writer());
            }
        }

        try output.appendSlice("}");

        const io = io_context.get();
        const file = try io_context.cwd().createFile(io, self.file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, output.items);
    }

    pub fn clear(self: *LocalStorage) !void {
        const io = io_context.get();
        const file = try io_context.cwd().createFile(io, self.file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "{}");
    }

    fn loadAll(self: *LocalStorage) ![]const u8 {
        const io = io_context.get();
        const file = io_context.cwd().openFile(io, self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return try self.allocator.dupe(u8, "{}");
            }
            return err;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const buf = try self.allocator.alloc(u8, stat.size);
        _ = try file.readPositional(io, &.{buf}, 0);
        return buf;
    }

    fn writeJson(self: *LocalStorage, pairs: []const struct { []const u8, []const u8 }) !void {
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        try output.appendSlice("{");
        for (pairs, 0..) |pair, i| {
            if (i > 0) try output.appendSlice(",");
            try output.appendSlice("\"");
            try output.appendSlice(pair[0]);
            try output.appendSlice("\":\"");
            try output.appendSlice(pair[1]);
            try output.appendSlice("\"");
        }
        try output.appendSlice("}");

        const io = io_context.get();
        const file = try io_context.cwd().createFile(io, self.file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, output.items);
    }
};

// ============================================================================
// 6. Performance Monitoring
// ============================================================================

pub const PerformanceMonitor = struct {
    start_time: i64,
    allocator: std.mem.Allocator,
    // For CPU tracking
    last_cpu_time: i64 = 0,
    last_cpu_usage: f64 = 0.0,

    pub const Stats = struct {
        memory_used: u64,
        memory_total: u64,
        cpu_percent: f64,
        uptime_seconds: i64,
    };

    pub fn init(allocator: std.mem.Allocator) PerformanceMonitor {
        return .{
            .start_time = std.time.timestamp(),
            .allocator = allocator,
        };
    }

    pub fn getStats(self: *PerformanceMonitor) !Stats {
        const uptime = std.time.timestamp() - self.start_time;

        // Get memory info
        var memory_used: u64 = 0;
        var memory_total: u64 = 0;
        var cpu_percent: f64 = 0.0;

        if (builtin.os.tag == .macos) {
            // Get process memory using mach task_info
            const task_info_result = getMachTaskInfo();
            memory_used = task_info_result.resident_size;
            memory_total = task_info_result.virtual_size;

            // Get system memory
            const sys_mem = getSystemMemory();
            if (sys_mem.total > 0) {
                memory_total = sys_mem.total;
            }

            // Calculate CPU usage using rusage
            cpu_percent = self.calculateCpuUsage();
        } else if (builtin.os.tag == .linux) {
            // Read from /proc/self/statm for memory
            const mem = getLinuxProcessMemory();
            memory_used = mem.resident;
            memory_total = mem.virtual;

            // Read from /proc/stat for CPU
            cpu_percent = self.calculateCpuUsage();
        }

        return .{
            .memory_used = memory_used,
            .memory_total = memory_total,
            .cpu_percent = cpu_percent,
            .uptime_seconds = uptime,
        };
    }

    fn calculateCpuUsage(self: *PerformanceMonitor) f64 {
        // Use rusage for cross-platform CPU time
        var usage: std.posix.rusage = undefined;
        const result = std.posix.getrusage(.self, &usage);
        if (result != 0) return self.last_cpu_usage;

        // Total CPU time in microseconds
        const user_time = @as(i64, usage.utime.sec) * 1_000_000 + usage.utime.usec;
        const sys_time = @as(i64, usage.stime.sec) * 1_000_000 + usage.stime.usec;
        const total_cpu_time = user_time + sys_time;

        const now = std.time.microTimestamp();

        if (self.last_cpu_time > 0) {
            const time_diff = now - self.last_cpu_time;
            const cpu_diff = total_cpu_time - @as(i64, @intCast(@as(u64, @bitCast(self.last_cpu_usage)) * 1_000_000));

            if (time_diff > 0) {
                // Calculate CPU percentage (normalized by elapsed time)
                const cpu_pct = @as(f64, @floatFromInt(cpu_diff)) / @as(f64, @floatFromInt(time_diff)) * 100.0;
                self.last_cpu_usage = @max(0.0, @min(100.0, cpu_pct));
            }
        }

        self.last_cpu_time = now;
        return self.last_cpu_usage;
    }
};

// macOS mach task info
const MachTaskInfo = struct {
    virtual_size: u64,
    resident_size: u64,
};

fn getMachTaskInfo() MachTaskInfo {
    if (builtin.os.tag != .macos) {
        return .{ .virtual_size = 0, .resident_size = 0 };
    }

    // mach_task_basic_info structure
    const MACH_TASK_BASIC_INFO = 20;
    const MACH_TASK_BASIC_INFO_COUNT = 10;

    var info: extern struct {
        virtual_size: u64,
        resident_size: u64,
        resident_size_max: u64,
        user_time: extern struct { seconds: u32, microseconds: u32 },
        system_time: extern struct { seconds: u32, microseconds: u32 },
        policy: i32,
        suspend_count: i32,
    } = undefined;

    var count: u32 = MACH_TASK_BASIC_INFO_COUNT;

    // Use mach_task_self to get current task port
    const mach_task_self = @extern(*fn () callconv(.c) u32, .{ .name = "mach_task_self" });
    const task_info_fn = @extern(*fn (u32, u32, *anyopaque, *u32) callconv(.c) i32, .{ .name = "task_info" });

    const kern_result = task_info_fn(mach_task_self(), MACH_TASK_BASIC_INFO, @ptrCast(&info), &count);

    if (kern_result == 0) {
        return .{
            .virtual_size = info.virtual_size,
            .resident_size = info.resident_size,
        };
    }

    return .{ .virtual_size = 0, .resident_size = 0 };
}

const SystemMemory = struct {
    total: u64,
    available: u64,
};

fn getSystemMemory() SystemMemory {
    if (builtin.os.tag == .macos) {
        // Use sysctl for total physical memory
        const CTL_HW = 6;
        const HW_MEMSIZE = 24;

        var mib = [_]c_int{ CTL_HW, HW_MEMSIZE };
        var mem_size: u64 = 0;
        var size: usize = @sizeOf(u64);

        const sysctl_fn = @extern(*fn ([*]c_int, c_uint, *anyopaque, *usize, ?*anyopaque, usize) callconv(.c) c_int, .{ .name = "sysctl" });
        const result = sysctl_fn(&mib, 2, @ptrCast(&mem_size), &size, null, 0);

        if (result == 0) {
            return .{ .total = mem_size, .available = 0 };
        }
    }

    return .{ .total = 0, .available = 0 };
}

const LinuxMemory = struct {
    virtual: u64,
    resident: u64,
};

fn getLinuxProcessMemory() LinuxMemory {
    if (builtin.os.tag != .linux) {
        return .{ .virtual = 0, .resident = 0 };
    }

    // Read /proc/self/statm
    const io = io_context.get();
    const file = io_context.cwd().openFile(io, "/proc/self/statm", .{}) catch {
        return .{ .virtual = 0, .resident = 0 };
    };
    defer file.close(io);

    var buf: [256]u8 = undefined;
    const bytes_read = file.readPositional(io, &.{&buf}, 0) catch return .{ .virtual = 0, .resident = 0 };
    const content = buf[0..bytes_read];

    // Parse: size resident shared text lib data dt
    var iter = std.mem.splitScalar(u8, content, ' ');
    const virtual_pages = std.fmt.parseInt(u64, iter.next() orelse "0", 10) catch 0;
    const resident_pages = std.fmt.parseInt(u64, iter.next() orelse "0", 10) catch 0;

    // Convert pages to bytes (typically 4KB pages)
    const page_size: u64 = 4096;
    return .{
        .virtual = virtual_pages * page_size,
        .resident = resident_pages * page_size,
    };
}

// ============================================================================
// Helper functions for Objective-C messaging
// ============================================================================

fn msgSend0(target: anytype, selector: [*:0]const u8) objc.id {
    if (builtin.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, objc.sel_registerName(selector));
}

fn msgSend1(target: anytype, selector: [*:0]const u8, arg1: anytype) objc.id {
    if (builtin.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1)) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, objc.sel_registerName(selector), arg1);
}

fn msgSendVoid0(target: anytype, selector: [*:0]const u8) void {
    if (builtin.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, objc.sel_registerName(selector));
}

fn msgSendVoid1(target: anytype, selector: [*:0]const u8, arg1: anytype) void {
    if (builtin.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1)) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, objc.sel_registerName(selector), arg1);
}

fn msgSendFrame(target: anytype, selector: [*:0]const u8) NSRect {
    if (builtin.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) NSRect, @ptrCast(&objc.objc_msgSend));
    return msg(target, objc.sel_registerName(selector));
}

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub const NSPoint = extern struct {
    x: f64,
    y: f64,
};

pub const NSSize = extern struct {
    width: f64,
    height: f64,
};
