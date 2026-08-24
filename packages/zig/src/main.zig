const std = @import("std");
const builtin = @import("builtin");
// Re-exported so callers in the `root` module (minimal.zig, demo.zig) can
// reach Cocoa wrappers like `setApplicationIcon` without doing their own
// `@import("macos.zig")` — Zig 0.17 forbids a single source file from being
// the root of more than one module.
pub const macos = if (builtin.os.tag == .macos) @import("macos.zig") else struct {};
const BridgeAPI = @import("bridge_api.zig").BridgeAPI;

// Re-export io_context so root modules can access it without dual-module conflicts
pub const io_context = @import("io_context.zig");
pub const startup_timing = @import("startup_timing.zig");
pub const js_runtime = @import("js_runtime.zig");

// Re-export iOS module (available on all platforms for cross-compilation)
pub const ios = @import("ios.zig");
pub const mobile = @import("mobile.zig");

// Re-export Android module (available on all platforms for cross-compilation)
pub const android = @import("android.zig");
pub const CraftActivity = android.CraftActivity;
pub const AndroidJSBridge = android.JSBridge;
pub const AndroidFeatures = android.AndroidFeatures;

// Re-export API module
pub const api = @import("api.zig");

// Re-export dialogs module
pub const dialogs = @import("dialogs.zig");
pub const Dialog = dialogs.Dialog;
pub const FileDialogOptions = dialogs.FileDialogOptions;
pub const DirectoryDialogOptions = dialogs.DirectoryDialogOptions;
pub const MessageDialogOptions = dialogs.MessageDialogOptions;
pub const ConfirmDialogOptions = dialogs.ConfirmDialogOptions;
pub const DialogResult = dialogs.DialogResult;
pub const CommonDialogs = dialogs.CommonDialogs;
pub const FileFilter = dialogs.FileFilter;

// Re-export notifications module
pub const notifications_module = @import("notifications.zig");
pub const Notifications = notifications_module.Notifications;
pub const NotificationOptions = notifications_module.NotificationOptions;
pub const NotificationAction = notifications_module.NotificationAction;

// Re-export system tray module
pub const tray_module = @import("tray.zig");
pub const SystemTray = tray_module.SystemTray;

// Re-export clipboard module
pub const clipboard_module = @import("bridge_clipboard.zig");
pub const ClipboardBridge = clipboard_module.ClipboardBridge;

// Re-export hot reload module
pub const hotreload_module = @import("hotreload.zig");
pub const HotReload = hotreload_module.HotReload;
pub const HotReloadConfig = hotreload_module.HotReloadConfig;
pub const FileWatcher = hotreload_module.FileWatcher;
pub const ReloadServer = hotreload_module.ReloadServer;
pub const MobileReloadConfig = hotreload_module.MobileReloadConfig;

// Re-export components
pub const components = @import("components.zig");
pub const Component = components.Component;
pub const ComponentProps = components.ComponentProps;
pub const Button = components.Button;
pub const TextInput = components.TextInput;
pub const Chart = components.Chart;
pub const MediaPlayer = components.MediaPlayer;
pub const CodeEditor = components.CodeEditor;
pub const Tabs = components.Tabs;
pub const Modal = components.Modal;
pub const ProgressBar = components.ProgressBar;
pub const Dropdown = components.Dropdown;
pub const Toast = components.Toast;
pub const ToastManager = components.ToastManager;
pub const TreeView = components.TreeView;
pub const DatePicker = components.DatePicker;
pub const DataGrid = components.DataGrid;
pub const Tooltip = components.Tooltip;
pub const Slider = components.Slider;
pub const Autocomplete = components.Autocomplete;
pub const ColorPicker = components.ColorPicker;

// Re-export platform types
pub const WindowStyle = if (builtin.os.tag == .macos) macos.WindowStyle else struct {
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
    hide_dock_icon: bool = false,
    titlebar_hidden: bool = false,
    system_tray: bool = false,
    system_tray_title: ?[]const u8 = null,
    dev_tools: bool = true,
    native_sidebar: bool = false,
    web_sidebar_material: bool = false,
    web_sidebar_width: u32 = 286,
    web_sidebar_material_opacity: f64 = 0.78,
    benchmark: bool = false,
    /// Accepted so `minimal.zig` can pass one `WindowStyle` on every platform,
    /// and ignored: remembering a window frame is `setFrameAutosaveName:`, an
    /// AppKit facility with no counterpart wired up on GTK or Win32 yet.
    frame_autosave: ?[]const u8 = null,
};

pub const Window = struct {
    title: []const u8,
    width: u32,
    height: u32,
    html: []const u8,
    native_handle: ?*anyopaque = null,

    const Self = @This();

    pub fn init(title: []const u8, width: u32, height: u32, html: []const u8) Self {
        return .{
            .title = title,
            .width = width,
            .height = height,
            .html = html,
        };
    }

    pub fn show(self: *Self) !void {
        switch (builtin.os.tag) {
            .macos => try self.showMacOS(),
            .linux => try self.showLinux(),
            .windows => try self.showWindows(),
            else => return error.UnsupportedPlatform,
        }
    }

    fn showMacOS(self: *Self) !void {
        if (builtin.os.tag == .macos) {
            const window = try macos.createWindow(self.title, self.width, self.height, self.html);
            self.native_handle = @ptrCast(window);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    fn showLinux(self: *Self) !void {
        const linux = @import("linux.zig");
        const window = try linux.createWindow(self.title, self.width, self.height, self.html);
        self.native_handle = window;
    }

    fn showWindows(self: *Self) !void {
        const windows = @import("windows.zig");
        const window = try windows.createWindow(self.title, self.width, self.height, self.html);
        self.native_handle = window;
    }

    pub fn setHtml(self: *Self, html: []const u8) void {
        self.html = html;
    }

    pub fn eval(self: *Self, js: []const u8) !void {
        if (self.native_handle == null) return error.WindowNotShown;
        try @import("bridge.zig").evalJS(js);
    }

    pub fn deinit(self: *Self) void {
        if (self.native_handle) |handle| {
            // Platform-specific cleanup
            _ = handle;
        }
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(*Window),
    system_tray: ?*SystemTray = null,
    system_trays: std.ArrayList(*SystemTray),
    bridge: ?*BridgeAPI = null,
    notifications: ?*Notifications = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .windows = .{ .items = &.{}, .capacity = 0 },
            .system_trays = .{ .items = &.{}, .capacity = 0 },
            .bridge = null,
            .notifications = null,
        };
    }

    /// Initialize platform-specific features (must be called before creating system tray on macOS)
    pub fn initPlatform(self: *Self) void {
        _ = self;
        switch (builtin.os.tag) {
            .macos => {
                if (builtin.os.tag == .macos) {
                    macos.initAppWithoutLaunching();
                    // Create application menu with standard shortcuts (Cmd+Q, Cmd+H)
                    macos.createApplicationMenu();
                }
            },
            else => {},
        }
    }

    /// Initialize platform for system tray apps
    pub fn initPlatformForTray(self: *Self) void {
        _ = self;
        switch (builtin.os.tag) {
            .macos => {
                if (builtin.os.tag == .macos) {
                    macos.initAppForTray();
                }
            },
            else => {},
        }
    }

    // All `create*` helpers below used to leak the newly-allocated struct
    // if the subsequent `show()`/`append()` failed. Each now uses errdefer
    // to destroy the allocation on the error path.

    pub fn createSystemTray(self: *Self, title: []const u8) !*SystemTray {
        const sys_tray = try self.allocator.create(SystemTray);
        errdefer self.allocator.destroy(sys_tray);
        sys_tray.* = SystemTray.init(self.allocator, title);
        try sys_tray.show();
        self.system_tray = sys_tray;

        // Also add to trays list for multi-tray support
        try self.system_trays.append(self.allocator, sys_tray);

        return sys_tray;
    }

    /// Create an additional system tray (for multiple tray icons)
    pub fn createAdditionalTray(self: *Self, title: []const u8) !*SystemTray {
        const sys_tray = try self.allocator.create(SystemTray);
        errdefer self.allocator.destroy(sys_tray);
        sys_tray.* = SystemTray.init(self.allocator, title);
        try sys_tray.show();

        // Add to trays list (not the primary one)
        try self.system_trays.append(self.allocator, sys_tray);

        return sys_tray;
    }

    pub fn createWindow(self: *Self, title: []const u8, width: u32, height: u32, html: []const u8) !*Window {
        const window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);
        window.* = Window.init(title, width, height, html);
        try self.windows.append(self.allocator, window);
        return window;
    }

    pub fn createWindowWithHTML(self: *Self, title: []const u8, width: u32, height: u32, html: []const u8, style: WindowStyle) !*Window {
        if (builtin.os.tag == .macos) {
            const native_window = try macos.createWindowWithHTML(title, width, height, html, style);
            const window = try self.allocator.create(Window);
            errdefer self.allocator.destroy(window);
            window.* = Window.init(title, width, height, html);
            window.native_handle = @ptrCast(native_window);
            try self.windows.append(self.allocator, window);
            return window;
        } else {
            return error.UnsupportedPlatform;
        }
    }

    pub fn createWindowWithURL(self: *Self, title: []const u8, width: u32, height: u32, url: []const u8, style: WindowStyle) !*Window {
        if (builtin.os.tag == .macos) {
            const native_window = try macos.createWindowWithURL(title, width, height, url, style);
            const window = try self.allocator.create(Window);
            errdefer self.allocator.destroy(window);
            window.* = Window.init(title, width, height, "");
            window.native_handle = @ptrCast(native_window);
            try self.windows.append(self.allocator, window);
            return window;
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Create a window with a native macOS sidebar (Finder-style with vibrancy) - HTML mode
    pub fn createWindowWithNativeSidebar(self: *Self, title: []const u8, width: u32, height: u32, html: []const u8, sidebar_width: u32, sidebar_config: ?[]const u8, style: WindowStyle) !*Window {
        if (builtin.os.tag == .macos) {
            const native_window = try macos.createWindowWithSidebar(title, width, height, html, sidebar_width, sidebar_config, style);
            const window = try self.allocator.create(Window);
            errdefer self.allocator.destroy(window);
            window.* = Window.init(title, width, height, html);
            window.native_handle = @ptrCast(native_window);
            try self.windows.append(self.allocator, window);
            return window;
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Create a window with a native macOS sidebar (Finder-style with vibrancy) - URL mode
    pub fn createWindowWithNativeSidebarURL(self: *Self, title: []const u8, width: u32, height: u32, url: []const u8, sidebar_width: u32, sidebar_config: ?[]const u8, style: WindowStyle) !*Window {
        if (builtin.os.tag == .macos) {
            const native_window = try macos.createWindowWithSidebarURL(title, width, height, url, sidebar_width, sidebar_config, style);
            const window = try self.allocator.create(Window);
            errdefer self.allocator.destroy(window);
            window.* = Window.init(title, width, height, url);
            window.native_handle = @ptrCast(native_window);
            try self.windows.append(self.allocator, window);
            return window;
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Show all windows without activating the app (for menubar apps)
    pub fn showWindows(self: *Self) void {
        switch (builtin.os.tag) {
            .macos => {
                if (builtin.os.tag == .macos) {
                    macos.showAllWindows();
                }
            },
            else => {
                for (self.windows.items) |window| {
                    window.show() catch |err| {
                        std.log.warn("failed to show window: {}", .{err});
                    };
                }
            },
        }
    }

    pub fn run(self: *Self) !void {
        // Allow no windows if we have a system tray (menubar-only mode)
        if (self.windows.items.len == 0 and self.system_tray == null) {
            return error.NoWindows;
        }

        // DON'T show windows yet on macOS - they'll be shown after tray is created
        // On other platforms, show them now
        switch (builtin.os.tag) {
            .macos => {
                // Windows will be shown in runMacOS() after platform is ready
            },
            else => {
                for (self.windows.items) |window| {
                    try window.show();
                }
            },
        }

        // Platform-specific event loop
        switch (builtin.os.tag) {
            .macos => try self.runMacOS(),
            .linux => try self.runLinux(),
            .windows => try self.runWindows(),
            else => return error.UnsupportedPlatform,
        }
    }

    fn runMacOS(self: *Self) !void {
        if (builtin.os.tag == .macos) {
            // Show windows if we don't have a system tray
            // If we have a system tray, windows were already shown in the correct order
            // (after tray creation) by the caller
            if (self.system_tray == null) {
                macos.showAllWindows();
                // Windowed app: claim regular activation (Dock icon, key
                // window, foreground) — launching from a bare binary would
                // otherwise leave the window buried with no Dock presence.
                macos.activateWindowedApp();
            }

            // Now run the event loop
            macos.runApp();
        }
    }

    fn runLinux(self: *Self) !void {
        _ = self;
        const linux = @import("linux.zig");
        try linux.App.run();
    }

    fn runWindows(self: *Self) !void {
        _ = self;
        const windows = @import("windows.zig");
        try windows.App.run();
    }

    /// Initialize bridge API for JavaScript communication
    pub fn initBridge(self: *Self) !void {
        if (self.bridge == null) {
            const bridge = try self.allocator.create(BridgeAPI);
            bridge.* = BridgeAPI.init(self.allocator);
            self.bridge = bridge;
        }
    }

    /// Initialize notifications system
    pub fn initNotifications(self: *Self) !void {
        if (self.notifications == null) {
            const notif = try self.allocator.create(Notifications);
            notif.* = Notifications.init(self.allocator);
            self.notifications = notif;
        }
    }

    /// Send a notification
    pub fn notify(self: *Self, options: Notifications.NotificationOptions) !void {
        if (self.notifications == null) {
            try self.initNotifications();
        }
        if (self.notifications) |notif| {
            try notif.send(options);
        }
    }

    pub fn deinit(self: *Self) void {
        // Cleanup bridge
        if (self.bridge) |bridge| {
            bridge.deinit();
            self.allocator.destroy(bridge);
        }

        // Cleanup notifications
        if (self.notifications) |notif| {
            notif.deinit();
            self.allocator.destroy(notif);
        }

        // Cleanup all system trays
        for (self.system_trays.items) |sys_tray| {
            sys_tray.deinit();
            self.allocator.destroy(sys_tray);
        }
        self.system_trays.deinit(self.allocator);

        // Cleanup windows
        for (self.windows.items) |window| {
            window.deinit();
            self.allocator.destroy(window);
        }
        self.windows.deinit(self.allocator);
    }
};

test "create window" {
    const allocator = std.testing.allocator;
    var app = App.init(allocator);
    defer app.deinit();

    const window = try app.createWindow("Test Window", 800, 600, "<h1>Hello, World!</h1>");
    try std.testing.expectEqualStrings("Test Window", window.title);
    try std.testing.expect(window.width == 800);
    try std.testing.expect(window.height == 600);
}

test "set html" {
    const allocator = std.testing.allocator;
    var app = App.init(allocator);
    defer app.deinit();

    const window = try app.createWindow("Test", 800, 600, "<h1>Initial</h1>");
    window.setHtml("<h1>Updated</h1>");
    try std.testing.expectEqualStrings("<h1>Updated</h1>", window.html);
}
