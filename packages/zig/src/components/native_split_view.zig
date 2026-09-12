const std = @import("std");
const macos = @import("../macos.zig");
const NativeSidebar = @import("native_sidebar.zig").NativeSidebar;
const NativeFileBrowser = @import("native_file_browser.zig").NativeFileBrowser;

/// High-level wrapper for NSSplitView combining sidebar and file browser
/// Creates a complete Finder-like layout with resizable divider
pub const NativeSplitView = struct {
    split_view: macos.objc.id,
    sidebar: ?*NativeSidebar,
    file_browser: ?*NativeFileBrowser,
    allocator: std.mem.Allocator,

    pub const SplitViewConfig = struct {
        sidebar_width: f64 = 240.0,
        min_sidebar_width: f64 = 180.0,
        min_content_width: f64 = 400.0,
        divider_style: DividerStyle = .thin,
    };

    pub const DividerStyle = enum(c_long) {
        thick = 1,
        thin = 2,
        pane_splitter = 3,
    };

    pub fn init(allocator: std.mem.Allocator, config: SplitViewConfig) !*NativeSplitView {
        const self = try allocator.create(NativeSplitView);
        errdefer allocator.destroy(self);

        // Create NSSplitView
        const NSSplitView = macos.getClass("NSSplitView");
        const split_view = macos.msgSend0(macos.msgSend0(NSSplitView, "alloc"), "init");

        // Configure split view
        _ = macos.msgSend1(split_view, "setVertical:", @as(c_int, 1)); // Vertical split (side-by-side)
        _ = macos.msgSend1(split_view, "setDividerStyle:", @backingInt(config.divider_style));

        // Set autosave name for divider position persistence
        const autosave_name = macos.createNSString("CraftSplitView");
        _ = macos.msgSend1(split_view, "setAutosaveName:", autosave_name);

        self.* = .{
            .split_view = split_view,
            .sidebar = null,
            .file_browser = null,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *NativeSplitView) void {
        // Components are borrowed from the bridge registries. Detach their
        // views before releasing the split view so either component can be
        // reused or safely destroyed afterward.
        if (self.sidebar) |sidebar| {
            _ = macos.msgSend0(sidebar.getView(), "removeFromSuperview");
        }
        if (self.file_browser) |browser| {
            _ = macos.msgSend0(browser.getView(), "removeFromSuperview");
        }
        _ = macos.msgSend0(self.split_view, "removeFromSuperview");
        _ = macos.msgSend0(self.split_view, "release");
        self.allocator.destroy(self);
    }

    pub fn usesSidebar(self: *const NativeSplitView, sidebar: *const NativeSidebar) bool {
        return self.sidebar == sidebar;
    }

    pub fn usesFileBrowser(self: *const NativeSplitView, browser: *const NativeFileBrowser) bool {
        return self.file_browser == browser;
    }

    /// Get the split view (top-level view to add to window)
    pub fn getView(self: *NativeSplitView) macos.objc.id {
        return self.split_view;
    }

    /// Set the sidebar component
    pub fn setSidebar(self: *NativeSplitView, sidebar: *NativeSidebar) void {
        self.sidebar = sidebar;

        // Add sidebar view as first subview
        const sidebar_view = sidebar.getView();
        _ = macos.msgSend1(self.split_view, "addSubview:", sidebar_view);

        // Configure sidebar constraints
        _ = macos.msgSend1(sidebar_view, "setAutoresizingMask:", @as(c_ulong, 18)); // Width + Height resizable
    }

    /// Set the file browser component
    pub fn setFileBrowser(self: *NativeSplitView, file_browser: *NativeFileBrowser) void {
        self.file_browser = file_browser;

        // Add file browser view as second subview
        const browser_view = file_browser.getView();
        _ = macos.msgSend1(self.split_view, "addSubview:", browser_view);

        // Configure browser constraints
        _ = macos.msgSend1(browser_view, "setAutoresizingMask:", @as(c_ulong, 18)); // Width + Height resizable
    }

    /// Set frame for the entire split view
    pub fn setFrame(self: *NativeSplitView, x: f64, y: f64, width: f64, height: f64) void {
        const NSRect = extern struct {
            origin: extern struct { x: f64, y: f64 },
            size: extern struct { width: f64, height: f64 },
        };

        const frame = NSRect{
            .origin = .{ .x = x, .y = y },
            .size = .{ .width = width, .height = height },
        };

        _ = macos.msgSend1(self.split_view, "setFrame:", frame);
    }

    /// Set Auto Layout constraints (alternative to setFrame)
    pub fn setAutoresizingMask(self: *NativeSplitView, mask: c_ulong) void {
        _ = macos.msgSend1(self.split_view, "setAutoresizingMask:", mask);
    }

    /// Set the position of the divider
    pub fn setDividerPosition(self: *NativeSplitView, position: f64) void {
        _ = macos.msgSend2(self.split_view, "setPosition:ofDividerAtIndex:", position, @as(c_long, 0));
    }

    /// Get the current divider position
    pub fn getDividerPosition(self: *NativeSplitView) f64 {
        // Get the frame of the first subview (sidebar)
        const subviews = macos.msgSend0(self.split_view, "subviews");
        if (subviews == @as(macos.objc.id, null)) return 240.0;

        const first_view = macos.msgSend1(subviews, "objectAtIndex:", @as(c_long, 0));
        if (first_view == @as(macos.objc.id, null)) return 240.0;

        const frame = macos.msgSend0(first_view, "frame");

        // Extract width from frame (assuming NSRect layout)
        const frame_ptr: [*]const f64 = @ptrCast(@alignCast(&frame));
        return frame_ptr[2]; // width is at offset 2 in NSRect
    }

    /// Enable/disable divider dragging
    pub fn setDividerCanCollapse(self: *NativeSplitView, can_collapse: bool) void {
        _ = macos.msgSend1(self.split_view, "setCanCollapseSubviews:", @as(c_int, if (can_collapse) 1 else 0));
    }

    /// Adjust subview sizes to fit
    pub fn adjustSubviews(self: *NativeSplitView) void {
        _ = macos.msgSend0(self.split_view, "adjustSubviews");
    }
};
