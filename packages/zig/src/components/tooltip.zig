const std = @import("std");
const base = @import("base.zig");
const Component = base.Component;
const ComponentProps = base.ComponentProps;

/// Get current timestamp in milliseconds
fn getMilliTimestamp() i64 {
    // Cross-platform via compat; see the note in src/error_context.zig. POSIX
    // `clock_gettime` cannot compile for Windows (`clockid_t` is `void`).
    return @import("../compat.zig").milliTimestamp();
}

/// Tooltip Component - Displays hover information
pub const Tooltip = struct {
    component: Component,
    text: []const u8,
    target: ?*Component,
    position: TooltipPosition,
    visible: bool,
    delay_ms: u64,
    offset_x: i32,
    offset_y: i32,
    max_width: ?usize,
    show_arrow: bool,
    theme: TooltipTheme,
    on_show: ?*const fn () void,
    on_hide: ?*const fn () void,
    show_time: ?i64,

    pub const TooltipPosition = enum {
        top,
        bottom,
        left,
        right,
        top_left,
        top_right,
        bottom_left,
        bottom_right,
    };

    pub const TooltipTheme = enum {
        dark,
        light,
        info,
        warning,
        err,
        success,
    };

    pub fn init(allocator: std.mem.Allocator, text: []const u8, props: ComponentProps) !*Tooltip {
        const tooltip = try allocator.create(Tooltip);
        errdefer allocator.destroy(tooltip);
        const component = try Component.init(allocator, "tooltip", props);
        tooltip.* = Tooltip{
            .component = component,
            .text = text,
            .target = null,
            .position = .top,
            .visible = false,
            .delay_ms = 500, // 500ms default delay
            .offset_x = 0,
            .offset_y = 8,
            .max_width = 300,
            .show_arrow = true,
            .theme = .dark,
            .on_show = null,
            .on_hide = null,
            .show_time = null,
        };
        return tooltip;
    }

    pub fn deinit(self: *Tooltip) void {
        self.component.deinit();
        self.component.allocator.destroy(self);
    }

    pub fn setTarget(self: *Tooltip, target: *Component) void {
        self.target = target;
    }

    pub fn setText(self: *Tooltip, text: []const u8) void {
        self.text = text;
    }

    pub fn setPosition(self: *Tooltip, position: TooltipPosition) void {
        self.position = position;
    }

    pub fn setTheme(self: *Tooltip, theme: TooltipTheme) void {
        self.theme = theme;
    }

    pub fn setDelay(self: *Tooltip, delay_ms: u64) void {
        self.delay_ms = delay_ms;
    }

    pub fn setOffset(self: *Tooltip, x: i32, y: i32) void {
        self.offset_x = x;
        self.offset_y = y;
    }

    pub fn setMaxWidth(self: *Tooltip, width: ?usize) void {
        self.max_width = width;
    }

    pub fn setShowArrow(self: *Tooltip, show_arrow: bool) void {
        self.show_arrow = show_arrow;
    }

    pub fn show(self: *Tooltip) void {
        if (!self.visible) {
            self.visible = true;
            self.show_time = getMilliTimestamp();

            if (self.on_show) |callback| {
                callback();
            }
        }
    }

    pub fn hide(self: *Tooltip) void {
        if (self.visible) {
            self.visible = false;
            self.show_time = null;

            if (self.on_hide) |callback| {
                callback();
            }
        }
    }

    pub fn toggle(self: *Tooltip) void {
        if (self.visible) {
            self.hide();
        } else {
            self.show();
        }
    }

    pub fn shouldShow(self: *const Tooltip) bool {
        const show_start = self.show_time orelse return false;
        const now = getMilliTimestamp();
        const elapsed_ms: u64 = @intCast(@max(0, now - show_start));
        return elapsed_ms >= self.delay_ms;
    }

    pub fn onShow(self: *Tooltip, callback: *const fn () void) void {
        self.on_show = callback;
    }

    pub fn onHide(self: *Tooltip, callback: *const fn () void) void {
        self.on_hide = callback;
    }

    pub fn getVisibleDuration(self: *const Tooltip) ?u64 {
        if (!self.visible) return null;
        const show_start = self.show_time orelse return null;
        const now = getMilliTimestamp();
        return @intCast(@max(0, now - show_start));
    }
};
