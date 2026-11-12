const std = @import("std");
const base = @import("base.zig");
const Component = base.Component;
const ComponentProps = base.ComponentProps;

/// Get current timestamp in milliseconds (compatible with Zig 0.16)
fn getMilliTimestamp() i64 {
    // Cross-platform via compat; see the note in src/error_context.zig. POSIX
    // `clock_gettime` cannot compile for Windows (`clockid_t` is `void`).
    return @import("../compat.zig").milliTimestamp();
}

/// Toast/Notification Component
pub const Toast = struct {
    component: Component,
    message: []const u8,
    title: ?[]const u8,
    type: ToastType,
    duration: ?u64, // milliseconds, null = persistent
    position: ToastPosition,
    visible: bool,
    closable: bool,
    auto_dismiss: bool,
    on_show: ?*const fn () void,
    on_dismiss: ?*const fn () void,
    show_time: ?i64,

    pub const ToastType = enum {
        info,
        success,
        warning,
        err,
    };

    pub const ToastPosition = enum {
        top_left,
        top_center,
        top_right,
        bottom_left,
        bottom_center,
        bottom_right,
    };

    pub fn init(allocator: std.mem.Allocator, message: []const u8, props: ComponentProps) !*Toast {
        const toast = try allocator.create(Toast);
        errdefer allocator.destroy(toast);
        const component = try Component.init(allocator, "toast", props);
        toast.* = Toast{
            .component = component,
            .message = message,
            .title = null,
            .type = .info,
            .duration = 5000, // 5 seconds default
            .position = .top_right,
            .visible = false,
            .closable = true,
            .auto_dismiss = true,
            .on_show = null,
            .on_dismiss = null,
            .show_time = null,
        };
        return toast;
    }

    pub fn deinit(self: *Toast) void {
        self.component.deinit();
        self.component.allocator.destroy(self);
    }

    pub fn show(self: *Toast) void {
        self.visible = true;
        self.show_time = getMilliTimestamp();

        if (self.on_show) |callback| {
            callback();
        }
    }

    pub fn dismiss(self: *Toast) void {
        self.visible = false;
        self.show_time = null;

        if (self.on_dismiss) |callback| {
            callback();
        }
    }

    pub fn toggle(self: *Toast) void {
        if (self.visible) {
            self.dismiss();
        } else {
            self.show();
        }
    }

    pub fn setType(self: *Toast, toast_type: ToastType) void {
        self.type = toast_type;
    }

    pub fn setTitle(self: *Toast, title: []const u8) void {
        self.title = title;
    }

    pub fn setMessage(self: *Toast, message: []const u8) void {
        self.message = message;
    }

    pub fn setDuration(self: *Toast, duration_ms: ?u64) void {
        self.duration = duration_ms;
    }

    pub fn setPosition(self: *Toast, position: ToastPosition) void {
        self.position = position;
    }

    pub fn setClosable(self: *Toast, closable: bool) void {
        self.closable = closable;
    }

    pub fn setAutoDismiss(self: *Toast, auto_dismiss: bool) void {
        self.auto_dismiss = auto_dismiss;
    }

    pub fn shouldAutoDismiss(self: *const Toast) bool {
        if (!self.auto_dismiss or self.duration == null or self.show_time == null) {
            return false;
        }

        const now = getMilliTimestamp();
        const elapsed = @as(u64, @intCast(now - self.show_time.?));
        return elapsed >= self.duration.?;
    }

    pub fn getRemainingTime(self: *const Toast) ?u64 {
        if (self.duration == null or self.show_time == null or !self.visible) {
            return null;
        }

        const now = getMilliTimestamp();
        const elapsed = @as(u64, @intCast(now - self.show_time.?));

        if (elapsed >= self.duration.?) {
            return 0;
        }

        return self.duration.? - elapsed;
    }

    pub fn onShow(self: *Toast, callback: *const fn () void) void {
        self.on_show = callback;
    }

    pub fn onDismiss(self: *Toast, callback: *const fn () void) void {
        self.on_dismiss = callback;
    }
};

pub const ToastManager = struct {
    toasts: std.ArrayList(*Toast),
    allocator: std.mem.Allocator,
    max_toasts: usize,

    pub fn init(allocator: std.mem.Allocator) ToastManager {
        return ToastManager{
            .toasts = .empty,
            .allocator = allocator,
            .max_toasts = 5,
        };
    }

    pub fn deinit(self: *ToastManager) void {
        for (self.toasts.items) |toast| {
            toast.deinit();
        }
        self.toasts.deinit(self.allocator);
    }

    pub fn add(self: *ToastManager, toast: *Toast) !void {
        // Remove oldest toast if at capacity
        if (self.toasts.items.len >= self.max_toasts) {
            const oldest = self.toasts.orderedRemove(0);
            oldest.deinit();
        }

        try self.toasts.append(self.allocator, toast);
        toast.show();
    }

    pub fn remove(self: *ToastManager, toast: *Toast) void {
        for (self.toasts.items, 0..) |t, i| {
            if (t == toast) {
                _ = self.toasts.swapRemove(i);
                toast.deinit();
                break;
            }
        }
    }

    pub fn removeAt(self: *ToastManager, index: usize) void {
        if (index < self.toasts.items.len) {
            const toast = self.toasts.swapRemove(index);
            toast.deinit();
        }
    }

    pub fn clear(self: *ToastManager) void {
        for (self.toasts.items) |toast| {
            toast.deinit();
        }
        self.toasts.clearRetainingCapacity();
    }

    pub fn updateAutoDismiss(self: *ToastManager) void {
        var i: usize = 0;
        while (i < self.toasts.items.len) {
            const toast = self.toasts.items[i];
            if (toast.shouldAutoDismiss()) {
                self.removeAt(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn setMaxToasts(self: *ToastManager, max: usize) void {
        self.max_toasts = max;

        // Remove excess toasts
        while (self.toasts.items.len > max) {
            const oldest = self.toasts.orderedRemove(0);
            oldest.deinit();
        }
    }
};
