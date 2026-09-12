const std = @import("std");
const macos = @import("../macos.zig");

/// Generic NSViewController wrapper for wrapping any NSView
/// This is needed because NSSplitViewController requires view controllers, not raw views
pub const ViewControllerWrapper = struct {
    view_controller: macos.objc.id,
    wrapped_view: macos.objc.id,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, view: macos.objc.id) !*ViewControllerWrapper {
        const self = try allocator.create(ViewControllerWrapper);
        errdefer allocator.destroy(self);

        // Create NSViewController
        const NSViewController = macos.getClass("NSViewController");
        const view_controller = macos.msgSend0(macos.msgSend0(NSViewController, "alloc"), "init");

        // Set the view (keeping default autoresizing mask behavior)
        _ = macos.msgSend1(view_controller, "setView:", view);

        self.* = .{
            .view_controller = view_controller,
            .wrapped_view = view,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *ViewControllerWrapper) void {
        _ = macos.msgSend0(self.view_controller, "release");
        self.allocator.destroy(self);
    }

    pub fn getViewController(self: *ViewControllerWrapper) macos.objc.id {
        return self.view_controller;
    }

    pub fn getView(self: *ViewControllerWrapper) macos.objc.id {
        return self.wrapped_view;
    }
};
