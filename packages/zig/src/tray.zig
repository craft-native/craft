const std = @import("std");
const builtin = @import("builtin");

/// System Tray / Status Bar Icon Support
/// Cross-platform implementation for macOS, Windows, and Linux
pub const SystemTray = struct {
    title: []const u8,
    icon_text: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    visible: bool = true,
    allocator: std.mem.Allocator,

    // Platform-specific handles
    platform_handle: ?*anyopaque = null,

    // Click callback
    click_callback: ?*const fn () void = null,

    // Menu handle
    menu_handle: ?*anyopaque = null,

    // Animation state
    animation_frames: []const []const u8 = &.{},
    animation_interval: u64 = 0,
    animation_running: bool = false,
    animation_index: usize = 0,
    animation_thread: ?std.Thread = null,

    // Drag & drop state
    drop_callback: ?*const fn (files: []const []const u8) void = null,
    accepted_types: []const []const u8 = &.{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, title: []const u8) Self {
        return .{
            .title = title,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Stop animation if running
        self.stopAnimation();

        if (self.platform_handle) |handle| {
            switch (builtin.target.os.tag) {
                .macos => macosDestroy(handle),
                .windows => windowsDestroy(handle),
                .linux => linuxDestroy(handle),
                else => {},
            }
        }
    }

    /// Create and show the system tray icon
    pub fn show(self: *Self) !void {
        switch (builtin.target.os.tag) {
            .macos => {
                self.platform_handle = try macosCreate(self.title, self.icon_text);
            },
            .windows => {
                self.platform_handle = try windowsCreate(self.title, self.icon_text);
            },
            .linux => {
                self.platform_handle = try linuxCreate(self.title, self.icon_text);
            },
            else => return error.PlatformNotSupported,
        }
        self.visible = true;
    }

    /// Hide the system tray icon
    pub fn hide(self: *Self) void {
        self.visible = false;
        if (self.platform_handle) |handle| {
            switch (builtin.target.os.tag) {
                .macos => macosHide(handle),
                .windows => windowsHide(handle),
                .linux => linuxHide(handle),
                else => {},
            }
        }
    }

    /// Update the tray icon text/title (for text-based menubar items)
    pub fn setTitle(self: *Self, title: []const u8) !void {
        self.icon_text = title;
        if (self.platform_handle) |handle| {
            switch (builtin.target.os.tag) {
                .macos => try macosSetTitle(handle, title),
                .windows => try windowsSetTitle(handle, title),
                .linux => try linuxSetTitle(handle, title),
                else => {},
            }
        }
    }

    /// Set tooltip text
    pub fn setTooltip(self: *Self, tooltip: []const u8) !void {
        self.tooltip = tooltip;
        if (self.platform_handle) |handle| {
            switch (builtin.target.os.tag) {
                .macos => try macosSetTooltip(handle, tooltip),
                .windows => try windowsSetTooltip(handle, tooltip),
                .linux => try linuxSetTooltip(handle, tooltip),
                else => {},
            }
        }
    }

    /// Set click callback
    pub fn setClickCallback(self: *Self, callback: *const fn () void) void {
        self.click_callback = callback;
    }

    /// Trigger click event (called from platform code)
    pub fn triggerClick(self: *Self) void {
        if (self.click_callback) |callback| {
            callback();
        }
    }

    /// Attach a menu to the tray icon
    pub fn setMenu(self: *Self, menu_handle: *anyopaque) !void {
        self.menu_handle = menu_handle;
        if (self.platform_handle) |handle| {
            switch (builtin.target.os.tag) {
                .macos => try macosSetMenu(handle, menu_handle),
                .windows => {}, // Windows tray menus handled differently
                .linux => {}, // Linux tray menus handled differently
                else => {},
            }
        }
    }

    /// Set icon image
    pub fn setIcon(self: *Self, icon_path: []const u8) !void {
        if (builtin.target.os.tag == .macos) {
            try macosSetIcon(self.platform_handle.?, icon_path);
        }
    }

    /// Set template image (monochrome, adapts to theme)
    pub fn setTemplateImage(self: *Self, icon_path: []const u8) !void {
        if (builtin.target.os.tag == .macos) {
            try macosSetTemplateImage(self.platform_handle.?, icon_path);
        }
    }

    /// Animate tray icon (text-based frames)
    pub fn animate(self: *Self, frames: []const []const u8, interval_ms: u64) !void {
        if (frames.len == 0) return;

        // Stop any existing animation
        self.stopAnimation();

        // Store animation state
        self.animation_frames = frames;
        self.animation_interval = interval_ms;
        self.animation_running = true;
        self.animation_index = 0;

        // Start animation in a background thread
        self.animation_thread = try std.Thread.spawn(.{}, animationLoop, .{self});
    }

    /// Stop tray icon animation
    pub fn stopAnimation(self: *Self) void {
        if (!self.animation_running) return;

        self.animation_running = false;

        // Wait for animation thread to finish
        if (self.animation_thread) |thread| {
            thread.join();
            self.animation_thread = null;
        }

        self.animation_frames = &.{};
    }

    /// Animation loop (runs in background thread)
    fn animationLoop(self: *Self) void {
        while (self.animation_running) {
            // Update to next frame
            const frame = self.animation_frames[self.animation_index];
            self.setTitle(frame) catch |err| {
                std.log.debug("tray animation frame update failed: {}", .{err});
            };

            // Advance to next frame
            self.animation_index = (self.animation_index + 1) % self.animation_frames.len;

            // Sleep for interval
            std.time.sleep(self.animation_interval * std.time.ns_per_ms);
        }
    }

    /// Register drag & drop support
    pub fn registerDropTypes(self: *Self, types: []const []const u8, callback: *const fn (files: []const []const u8) void) !void {
        self.accepted_types = types;
        self.drop_callback = callback;

        if (self.platform_handle) |handle| {
            switch (builtin.target.os.tag) {
                .macos => try macosRegisterDragTypes(handle, types),
                .windows => windowsRegisterDragTypes(handle, types),
                .linux => linuxRegisterDragTypes(handle, types),
                else => {},
            }
        }
    }

    /// Trigger drop callback (called from platform code)
    pub fn triggerDrop(self: *Self, files: []const []const u8) void {
        if (self.drop_callback) |callback| {
            callback(files);
        }
    }
};

// ============================================================================
// macOS Implementation using NSStatusBar
// ============================================================================

// Objective-C runtime types (manual declarations to avoid @cImport issues with Zig 0.16+)
const objc = if (builtin.target.os.tag == .macos) struct {
    pub const id = ?*anyopaque;
    pub const Class = ?*anyopaque;
    pub const SEL = ?*anyopaque;
    pub const IMP = ?*anyopaque;
    pub const BOOL = bool;

    pub extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
    pub extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
    pub extern "objc" fn objc_msgSend() void;
    pub extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extraBytes: usize) Class;
    pub extern "objc" fn objc_registerClassPair(cls: Class) void;
    pub extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) BOOL;
} else struct {
    pub const id = *anyopaque;
    pub const Class = *anyopaque;
    pub const SEL = *anyopaque;
};

fn msgSend0(target: anytype, selector: [*:0]const u8) if (builtin.target.os.tag == .macos) objc.id else *anyopaque {
    if (builtin.target.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, objc.sel_registerName(selector));
}

fn msgSend1(target: anytype, selector: [*:0]const u8, arg1: anytype) if (builtin.target.os.tag == .macos) objc.id else *anyopaque {
    if (builtin.target.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1)) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, objc.sel_registerName(selector), arg1);
}

fn msgSendVoid1(target: anytype, selector: [*:0]const u8, arg1: anytype) void {
    if (builtin.target.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1)) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, objc.sel_registerName(selector), arg1);
}

fn macosCreate(title: []const u8, icon_text: ?[]const u8) !*anyopaque {
    if (builtin.target.os.tag != .macos) return error.PlatformNotSupported;

    // Create menubar collapse items BEFORE the tray item so they get
    // positions 1 and 2 (rightmost). The tray item will be position 3.
    const menubar_collapse = @import("menubar_collapse.zig");
    menubar_collapse.earlyInit();

    // Get NSStatusBar systemStatusBar
    const NSStatusBar = objc.objc_getClass("NSStatusBar");
    const systemStatusBar = msgSend0(NSStatusBar, "systemStatusBar");

    // Create status item with variable length (NSVariableStatusItemLength = -1)
    // This allows the item to automatically resize based on its content
    const NSVariableStatusItemLength: f64 = -1.0;
    const statusItem = msgSend1(systemStatusBar, "statusItemWithLength:", NSVariableStatusItemLength);

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Created status item with variable length\n", .{});

    // Get the button
    const button = msgSend0(statusItem, "button");
    if (button == null) {
        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[Tray] ERROR: button is null!\n", .{});
        return error.ButtonCreationFailed;
    }

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Got button: {*}\n", .{button});

    // Set initial title with null-terminated string
    const text_to_display = icon_text orelse title;

    var allocator = std.heap.c_allocator;
    const text_z = @import("memory.zig").dupeZ(allocator, u8, text_to_display) catch |err| {
        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[Tray] Error creating null-terminated title: {}\n", .{err});
        return error.AllocationFailed;
    };
    defer allocator.free(text_z);

    const NSString = objc.objc_getClass("NSString");
    const titleStr = msgSend1(NSString, "stringWithUTF8String:", text_z.ptr);
    msgSendVoid1(button, "setTitle:", titleStr);

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Set button title to: {s}\n", .{text_to_display});

    // Set autosaveName for stable positioning
    const NSString_as = objc.objc_getClass("NSString");
    const autosaveName = msgSend1(NSString_as, "stringWithUTF8String:", "barista_tray");
    msgSendVoid1(statusItem, "setAutosaveName:", autosaveName);

    // Make sure the status item is visible
    const visible: c_int = 1;
    msgSendVoid1(statusItem, "setVisible:", visible);

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Status item visibility set\n", .{});

    // Create a default menu with basic items
    const NSMenu = objc.objc_getClass("NSMenu");
    const defaultMenu = msgSend0(msgSend0(NSMenu, "alloc"), "init");

    const NSMenuItem = objc.objc_getClass("NSMenuItem");
    const NSObject = objc.objc_getClass("NSObject");

    // Create a target object for menu actions
    const menuTarget = msgSend0(msgSend0(NSObject, "alloc"), "init");
    _ = msgSend0(menuTarget, "retain"); // Keep it alive

    // Register the menu action method on NSObject class
    const tray_menu = @import("tray_menu.zig");
    const method_sel = objc.sel_registerName("menuAction:");
    const method_imp: objc.IMP = @ptrCast(@constCast(&tray_menu.menuActionCallback));
    _ = objc.class_addMethod(
        @ptrCast(@alignCast(NSObject)),
        method_sel,
        method_imp,
        "v@:@",
    );
    const action_sel = objc.sel_registerName("menuAction:");

    // Add "Show Window" item with action
    const showItem = msgSend0(msgSend0(NSMenuItem, "alloc"), "init");
    const showTitle = msgSend1(NSString, "stringWithUTF8String:", "Show Window");
    msgSendVoid1(showItem, "setTitle:", showTitle);
    msgSendVoid1(showItem, "setTarget:", menuTarget);
    msgSendVoid1(showItem, "setAction:", action_sel);
    const showAction = msgSend1(NSString, "stringWithUTF8String:", "show");
    msgSendVoid1(showItem, "setRepresentedObject:", showAction);
    msgSendVoid1(defaultMenu, "addItem:", showItem);

    // Add "Toggle Menu Bar Items" item with action
    const toggleItem = msgSend0(msgSend0(NSMenuItem, "alloc"), "init");
    const toggleTitle = msgSend1(NSString, "stringWithUTF8String:", "Toggle Menu Bar Items");
    msgSendVoid1(toggleItem, "setTitle:", toggleTitle);
    msgSendVoid1(toggleItem, "setTarget:", menuTarget);
    msgSendVoid1(toggleItem, "setAction:", action_sel);
    const toggleAction = msgSend1(NSString, "stringWithUTF8String:", "toggleMenubar");
    msgSendVoid1(toggleItem, "setRepresentedObject:", toggleAction);
    msgSendVoid1(defaultMenu, "addItem:", toggleItem);

    // Add separator
    const separator1 = msgSend0(NSMenuItem, "separatorItem");
    msgSendVoid1(defaultMenu, "addItem:", separator1);

    // Add "Quit" item with action
    const quitItem = msgSend0(msgSend0(NSMenuItem, "alloc"), "init");
    const quitTitle = msgSend1(NSString, "stringWithUTF8String:", "Quit");
    msgSendVoid1(quitItem, "setTitle:", quitTitle);
    msgSendVoid1(quitItem, "setTarget:", menuTarget);
    msgSendVoid1(quitItem, "setAction:", action_sel);
    const quitAction = msgSend1(NSString, "stringWithUTF8String:", "quit");
    msgSendVoid1(quitItem, "setRepresentedObject:", quitAction);
    msgSendVoid1(defaultMenu, "addItem:", quitItem);

    // Hand the default menu to the click handler rather than attaching it with
    // setMenu:. An attached menu opens on either button and suppresses the
    // button's action, which would make left and right click indistinguishable.
    const tray_click = @import("tray_click.zig");
    tray_click.install(statusItem);
    tray_click.setMenu(defaultMenu);
    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Created with default menu (right click)\n", .{});

    // Retain the status item so it doesn't get deallocated
    _ = msgSend0(statusItem, "retain");

    const handle: *anyopaque = @ptrFromInt(@as(usize, @intCast(@intFromPtr(statusItem))));

    // Set global tray handle for bridge
    const macos = @import("macos.zig");
    macos.setGlobalTrayHandle(handle);

    return handle;
}

pub fn macosSetTitle(handle: *anyopaque, title: []const u8) !void {
    if (builtin.target.os.tag != .macos) return;

    const statusItem: objc.id = @ptrFromInt(@intFromPtr(handle));

    // Get the button
    const button = msgSend0(statusItem, "button");
    if (button == null) {
        return error.ButtonNotFound;
    }

    // Create null-terminated string for NSString
    var allocator = std.heap.c_allocator;
    const title_z = try @import("memory.zig").dupeZ(allocator, u8, title);
    defer allocator.free(title_z);

    // Create NSString from null-terminated title
    const NSString = objc.objc_getClass("NSString");
    if (NSString == null) {
        return error.ClassNotFound;
    }

    const titleStr = msgSend1(NSString, "stringWithUTF8String:", title_z.ptr);
    if (titleStr == null) {
        return error.StringCreationFailed;
    }

    // Set title on button
    msgSendVoid1(button, "setTitle:", titleStr);

    // Force the status item to recalculate its width by re-setting to variable length
    const NSVariableStatusItemLength: f64 = -1.0;
    msgSendVoid1(statusItem, "setLength:", NSVariableStatusItemLength);

    // Call sizeToFit on the button
    _ = msgSend0(button, "sizeToFit");

    // Mark the button as needing display
    msgSendVoid1(button, "setNeedsDisplay:", @as(bool, true));

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Title updated: {s}\n", .{title});
}

pub fn macosSetTooltip(handle: *anyopaque, tooltip: []const u8) !void {
    if (builtin.target.os.tag != .macos) return;

    const statusItem: objc.id = @ptrFromInt(@intFromPtr(handle));

    // Get the button
    const button = msgSend0(statusItem, "button");

    // Create null-terminated string for NSString
    var allocator = std.heap.c_allocator;
    const tooltip_z = try @import("memory.zig").dupeZ(allocator, u8, tooltip);
    defer allocator.free(tooltip_z);

    // Create NSString from null-terminated tooltip
    const NSString = objc.objc_getClass("NSString");
    const tooltipStr = msgSend1(NSString, "stringWithUTF8String:", tooltip_z.ptr);

    // Set tooltip on button
    _ = msgSend1(button, "setToolTip:", tooltipStr);
}

pub fn macosHide(handle: *anyopaque) void {
    if (builtin.target.os.tag != .macos) return;

    const statusItem: objc.id = @ptrFromInt(@intFromPtr(handle));

    // Set visible to NO
    msgSendVoid1(statusItem, "setVisible:", @as(c_int, 0));
    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Status item hidden\n", .{});
}

pub fn macosShow(handle: *anyopaque) void {
    if (builtin.target.os.tag != .macos) return;

    const statusItem: objc.id = @ptrFromInt(@intFromPtr(handle));

    // Set visible to YES
    msgSendVoid1(statusItem, "setVisible:", @as(c_int, 1));
    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Status item shown\n", .{});
}

fn macosDestroy(handle: *anyopaque) void {
    if (builtin.target.os.tag != .macos) return;

    const statusItem: objc.id = @ptrFromInt(@intFromPtr(handle));

    // Get status bar and remove item
    const NSStatusBar = objc.objc_getClass("NSStatusBar");
    const systemStatusBar = msgSend0(NSStatusBar, "systemStatusBar");
    _ = msgSend1(systemStatusBar, "removeStatusItem:", statusItem);

    // Release
    _ = msgSend0(statusItem, "release");
}

pub fn macosSetMenu(handle: *anyopaque, menu: *anyopaque) !void {
    if (builtin.target.os.tag != .macos) return;

    const statusItem: objc.id = @ptrFromInt(@intFromPtr(handle));
    const nsMenu: objc.id = @ptrFromInt(@intFromPtr(menu));

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug")) {
        std.debug.print("[Tray] Setting menu on status item\n", .{});
        std.debug.print("[Tray] Status item: {*}\n", .{statusItem});
        std.debug.print("[Tray] Menu: {*}\n", .{nsMenu});
    }

    // Hold it for right click rather than attaching it, so left click keeps
    // running the button's action.
    @import("tray_click.zig").setMenu(nsMenu);

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Menu set successfully\n", .{});
}

fn macosSetIcon(handle: *anyopaque, icon_path: []const u8) !void {
    if (builtin.target.os.tag != .macos) return;

    const statusItem: objc.id = @ptrFromInt(@intFromPtr(handle));
    const button = msgSend0(statusItem, "button");

    // Create NSImage from file path
    const NSImage = objc.objc_getClass("NSImage");
    const NSString = objc.objc_getClass("NSString");
    const pathStr = msgSend1(NSString, "stringWithUTF8String:", icon_path.ptr);
    const image = msgSend1(NSImage, "imageWithContentsOfFile:", pathStr);

    if (image == null) {
        return error.InvalidIconPath;
    }

    _ = msgSend1(button, "setImage:", image);
}

fn macosSetTemplateImage(handle: *anyopaque, icon_path: []const u8) !void {
    if (builtin.target.os.tag != .macos) return;

    const statusItem: objc.id = @ptrFromInt(@intFromPtr(handle));
    const button = msgSend0(statusItem, "button");

    // Create NSImage from file path
    const NSImage = objc.objc_getClass("NSImage");
    const NSString = objc.objc_getClass("NSString");
    const pathStr = msgSend1(NSString, "stringWithUTF8String:", icon_path.ptr);
    const image = msgSend1(NSImage, "imageWithContentsOfFile:", pathStr);

    if (image == null) {
        return error.InvalidIconPath;
    }

    // Set as template (monochrome, adapts to theme)
    msgSendVoid1(image, "setTemplate:", @as(c_int, 1));
    _ = msgSend1(button, "setImage:", image);
}

fn macosRegisterDragTypes(handle: *anyopaque, types: []const []const u8) !void {
    if (builtin.target.os.tag != .macos) return;

    const statusItem: objc.id = @ptrFromInt(@intFromPtr(handle));
    const button = msgSend0(statusItem, "button");

    // Create NSArray of drag types
    const NSMutableArray = objc.objc_getClass("NSMutableArray");
    const NSString = objc.objc_getClass("NSString");
    const dragTypes = msgSend0(NSMutableArray, "array");

    // Add each type to array
    for (types) |drag_type| {
        const typeStr = msgSend1(NSString, "stringWithUTF8String:", drag_type.ptr);
        _ = msgSend1(dragTypes, "addObject:", typeStr);
    }

    // Register for drag types
    // Note: This requires setting up a delegate with NSDraggingDestination protocol
    // For full implementation, would need to create a custom delegate class
    // This is a simplified stub that shows the concept
    _ = msgSend1(button, "registerForDraggedTypes:", dragTypes);
}

// ============================================================================
// Windows Implementation using Shell_NotifyIcon
// ============================================================================

const windows_tray = if (builtin.target.os.tag == .windows) @import("windows_tray.zig") else struct {};

fn windowsCreate(title: []const u8, _: ?[]const u8) !*anyopaque {
    if (builtin.target.os.tag != .windows) {
        return error.PlatformNotSupported;
    }

    const tray = try std.heap.c_allocator.create(windows_tray.WindowsTray);
    errdefer std.heap.c_allocator.destroy(tray);

    // Pass null to let WindowsTray create its own message-only window
    tray.* = try windows_tray.WindowsTray.init(std.heap.c_allocator, null, title);

    return @ptrCast(tray);
}

fn windowsSetTitle(handle: *anyopaque, title: []const u8) !void {
    if (builtin.target.os.tag != .windows) return;

    const tray = @as(*windows_tray.WindowsTray, @ptrCast(@alignCast(handle)));
    try tray.setTitle(title);
}

fn windowsSetTooltip(handle: *anyopaque, tooltip: []const u8) !void {
    if (builtin.target.os.tag != .windows) return;

    const tray = @as(*windows_tray.WindowsTray, @ptrCast(@alignCast(handle)));
    try tray.setTooltip(tooltip);
}

fn windowsHide(_: *anyopaque) void {
    // Windows doesn't have a hide function; you delete and re-add
    // For now, this is a no-op
}

fn windowsDestroy(handle: *anyopaque) void {
    if (builtin.target.os.tag != .windows) return;

    const tray = @as(*windows_tray.WindowsTray, @ptrCast(@alignCast(handle)));
    tray.deinit();
    std.heap.c_allocator.destroy(tray);
}

// ============================================================================
// Linux Implementation using libappindicator3
// ============================================================================

const linux_tray = if (builtin.target.os.tag == .linux) @import("linux_tray.zig") else struct {};

fn linuxCreate(title: []const u8, icon_text: ?[]const u8) !*anyopaque {
    if (builtin.target.os.tag != .linux) {
        return error.PlatformNotSupported;
    }

    const tray = try std.heap.c_allocator.create(linux_tray.LinuxTray);
    errdefer std.heap.c_allocator.destroy(tray);

    const display_title = if (icon_text) |text| text else title;
    tray.* = try linux_tray.LinuxTray.init(std.heap.c_allocator, display_title);

    return @ptrCast(tray);
}

fn linuxSetTitle(handle: *anyopaque, title: []const u8) !void {
    if (builtin.target.os.tag != .linux) return;

    const tray = @as(*linux_tray.LinuxTray, @ptrCast(@alignCast(handle)));
    try tray.setLabel(title);
}

fn linuxSetTooltip(handle: *anyopaque, tooltip: []const u8) !void {
    if (builtin.target.os.tag != .linux) return;

    const tray = @as(*linux_tray.LinuxTray, @ptrCast(@alignCast(handle)));
    try tray.setTooltip(tooltip);
}

fn linuxHide(_: *anyopaque) void {
    // libappindicator doesn't have a direct hide function
    // Status is set to passive on deinit
}

fn linuxDestroy(handle: *anyopaque) void {
    if (builtin.target.os.tag != .linux) return;

    const tray = @as(*linux_tray.LinuxTray, @ptrCast(@alignCast(handle)));
    tray.deinit();
    std.heap.c_allocator.destroy(tray);
}

// ============================================================================
// Windows Drag & Drop Implementation
// ============================================================================

fn windowsRegisterDragTypes(handle: *anyopaque, types: []const []const u8) void {
    if (builtin.target.os.tag != .windows) return;
    _ = handle;
    _ = types;

    // Windows tray drag & drop requires:
    // 1. The tray icon's window handle
    // 2. OLE DragAcceptFiles or RegisterDragDrop for richer support
    //
    // For file drops, we can use DragAcceptFiles(hwnd, TRUE):
    // extern "shell32" fn DragAcceptFiles(hWnd: HWND, fAccept: BOOL) void;
    //
    // For now, log that drag types were registered
    // Full implementation would need access to the HWND from WindowsTray
    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Windows drag types registered (stub)\n", .{});
}

// ============================================================================
// Linux Drag & Drop Implementation
// ============================================================================

fn linuxRegisterDragTypes(handle: *anyopaque, types: []const []const u8) void {
    if (builtin.target.os.tag != .linux) return;
    _ = handle;
    _ = types;

    // Linux tray drag & drop with GTK requires:
    // 1. Getting the GTK widget from AppIndicator
    // 2. Calling gtk_drag_dest_set() on the widget
    // 3. Connecting to drag-data-received signal
    //
    // GtkTargetEntry for file drops:
    // const target_entry = GtkTargetEntry{ .target = "text/uri-list", .flags = 0, .info = 0 };
    // gtk_drag_dest_set(widget, GTK_DEST_DEFAULT_ALL, &target_entry, 1, GDK_ACTION_COPY);
    //
    // For now, log that drag types were registered
    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Tray] Linux drag types registered (stub)\n", .{});
}
