const std = @import("std");
const macos = @import("../macos.zig");
const ViewControllerWrapper = @import("view_controller_wrapper.zig").ViewControllerWrapper;

/// Wrapper for NSSplitViewController with native Liquid Glass sidebar
/// Uses NSSplitViewItem with sidebar behavior to let AppKit apply Liquid Glass automatically
/// NO manual NSVisualEffectView - AppKit handles the glass material natively
pub const NativeSplitViewController = struct {
    split_view_controller: macos.objc.id,
    split_view: macos.objc.id,
    sidebar_item: ?macos.objc.id,
    content_item: ?macos.objc.id,
    sidebar_view_controller: ?*ViewControllerWrapper,
    content_view_controller: ?*ViewControllerWrapper,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*NativeSplitViewController {
        const self = try allocator.create(NativeSplitViewController);
        errdefer allocator.destroy(self);

        // Create NSSplitViewController
        const NSSplitViewController = macos.getClass("NSSplitViewController");
        const split_view_controller = macos.msgSend0(macos.msgSend0(NSSplitViewController, "alloc"), "init");

        // Get the split view
        const split_view = macos.msgSend0(split_view_controller, "splitView");

        // Configure split view for vertical orientation (sidebar on left)
        _ = macos.msgSend1(split_view, "setVertical:", @as(c_int, 1)); // YES

        // Set thin divider style for modern appearance
        _ = macos.msgSend1(split_view, "setDividerStyle:", @as(c_long, 1)); // NSSplitViewDividerStyleThin

        // Set autosave name for split position persistence
        const autosaveName = macos.createNSString("CraftMainSplitView");
        _ = macos.msgSend1(split_view, "setAutosaveName:", autosaveName);

        self.* = .{
            .split_view_controller = split_view_controller,
            .split_view = split_view,
            .sidebar_item = null,
            .content_item = null,
            .sidebar_view_controller = null,
            .content_view_controller = null,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *NativeSplitViewController) void {
        if (self.sidebar_item) |item| {
            _ = macos.msgSend1(self.split_view_controller, "removeSplitViewItem:", item);
        }
        if (self.content_item) |item| {
            _ = macos.msgSend1(self.split_view_controller, "removeSplitViewItem:", item);
        }
        if (self.sidebar_view_controller) |vc| vc.deinit();
        if (self.content_view_controller) |vc| vc.deinit();
        _ = macos.msgSend0(self.split_view_controller, "release");
        self.allocator.destroy(self);
    }

    /// Get the split view controller (to set as window content view controller)
    pub fn getSplitViewController(self: *NativeSplitViewController) macos.objc.id {
        return self.split_view_controller;
    }

    /// Get the split view itself
    pub fn getSplitView(self: *NativeSplitViewController) macos.objc.id {
        return self.split_view;
    }

    /// Add a sidebar using NSSplitViewItem.sidebarWithViewController:
    /// Wraps content in NSVisualEffectView for Liquid Glass material
    pub fn setSidebar(self: *NativeSplitViewController, sidebar_view: macos.objc.id) !void {
        // CRITICAL: Wrap sidebar in NSVisualEffectView for translucent glass effect
        const NSVisualEffectView = macos.getClass("NSVisualEffectView");
        const glass_view = macos.msgSend0(macos.msgSend0(NSVisualEffectView, "alloc"), "init");

        // CRITICAL: Enable layer backing for vibrancy to work
        _ = macos.msgSend1(glass_view, "setWantsLayer:", @as(c_int, 1)); // YES

        // Set material to .sidebar (NSVisualEffectMaterialSidebar = 5)
        _ = macos.msgSend1(glass_view, "setMaterial:", @as(c_long, 5));

        // Set blending mode to .behindWindow (0) for proper transparency
        _ = macos.msgSend1(glass_view, "setBlendingMode:", @as(c_long, 0));

        // Set state to .active (1) to always show the effect
        _ = macos.msgSend1(glass_view, "setState:", @as(c_long, 1));

        // CRITICAL: Set initial frame for the glass view
        const NSRect = extern struct {
            origin: extern struct { x: f64, y: f64 },
            size: extern struct { width: f64, height: f64 },
        };
        const initial_frame = NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 240.0, .height = 600.0 },
        };
        _ = macos.msgSend1(glass_view, "setFrame:", initial_frame);

        // Add sidebar content as subview of the glass view
        _ = macos.msgSend1(glass_view, "addSubview:", sidebar_view);
        errdefer {
            _ = macos.msgSend0(sidebar_view, "removeFromSuperview");
            _ = macos.msgSend0(glass_view, "release");
        }

        // Set autoresizing mask on BOTH views to resize properly
        const NSViewWidthSizable: c_ulong = 2;
        const NSViewHeightSizable: c_ulong = 16;
        const mask = NSViewWidthSizable | NSViewHeightSizable;
        _ = macos.msgSend1(glass_view, "setAutoresizingMask:", mask);
        _ = macos.msgSend1(sidebar_view, "setAutoresizingMask:", mask);

        // Wrap the glass view in a view controller
        const view_controller_wrapper = try ViewControllerWrapper.init(self.allocator, glass_view);
        // The wrapper's NSViewController retains its view. Balance the
        // alloc/init ownership so controller teardown can release it fully.
        _ = macos.msgSend0(glass_view, "release");
        self.sidebar_view_controller = view_controller_wrapper;

        // Use sidebarWithViewController: class method to create sidebar item
        const NSSplitViewItem = macos.getClass("NSSplitViewItem");
        const sidebar_item = macos.msgSend1(NSSplitViewItem, "sidebarWithViewController:", view_controller_wrapper.getViewController());

        // Configure sidebar constraints
        _ = macos.msgSend1(sidebar_item, "setMinimumThickness:", @as(f64, 240.0));
        _ = macos.msgSend1(sidebar_item, "setMaximumThickness:", @as(f64, 350.0));
        _ = macos.msgSend1(sidebar_item, "setCanCollapse:", @as(c_int, 1)); // YES - allow collapse

        // CRITICAL: Allow full height layout for the sidebar to extend under titlebar
        _ = macos.msgSend1(sidebar_item, "setAllowsFullHeightLayout:", @as(c_int, 1)); // YES

        // Set holding priority to ensure sidebar gets space
        // Use 751 (higher than NSLayoutPriorityDefaultHigh = 750)
        _ = macos.msgSend1(sidebar_item, "setHoldingPriority:", @as(f32, 751.0));

        // Add sidebar item FIRST (sidebars should be added before content)
        _ = macos.msgSend1(self.split_view_controller, "addSplitViewItem:", sidebar_item);

        // Ensure it starts uncollapsed
        _ = macos.msgSend1(sidebar_item, "setCollapsed:", @as(c_int, 0)); // NO

        self.sidebar_item = sidebar_item;

        std.debug.print("[LiquidGlass] ✓ Created sidebar with NSVisualEffectView for glass material\n", .{});
    }

    /// Set the content view (typically a WKWebView)
    /// Content extends full-width under the floating sidebar with automatic safe area insets
    pub fn setContent(self: *NativeSplitViewController, content_view: macos.objc.id) !void {
        // Wrap the content view in a view controller
        const view_controller_wrapper = try ViewControllerWrapper.init(self.allocator, content_view);
        self.content_view_controller = view_controller_wrapper;

        // Create NSSplitViewItem for content
        const NSSplitViewItem = macos.getClass("NSSplitViewItem");
        const content_item = macos.msgSend1(NSSplitViewItem, "splitViewItemWithViewController:", view_controller_wrapper.getViewController());

        // Content should not collapse
        _ = macos.msgSend1(content_item, "setCanCollapse:", @as(c_int, 0)); // NO

        // Set LOWER holding priority so content compresses before sidebar
        _ = macos.msgSend1(content_item, "setHoldingPriority:", @as(f32, 250.0));

        // Add content item to split view controller
        _ = macos.msgSend1(self.split_view_controller, "addSplitViewItem:", content_item);

        self.content_item = content_item;

        std.debug.print("[LiquidGlass] ✓ Content extends under floating sidebar with safe area insets\n", .{});
    }

    /// Get the root view of the split view controller (for setting as window content view)
    pub fn getView(self: *NativeSplitViewController) macos.objc.id {
        return macos.msgSend0(self.split_view_controller, "view");
    }

    /// Optional: Set divider position manually (usually AppKit handles this automatically)
    pub fn setDividerPosition(self: *NativeSplitViewController, position: f64) void {
        _ = macos.msgSend2(self.split_view, "setPosition:ofDividerAtIndex:", position, @as(c_long, 0));
        std.debug.print("[LiquidGlass] Set divider position to {d}px\n", .{position});
    }
};
