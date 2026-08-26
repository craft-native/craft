const std = @import("std");
const builtin = @import("builtin");
const logging = @import("logging.zig");
const menubar_collapse = @import("menubar_collapse.zig");

const log = logging.menu;

/// Bridge for JavaScript ↔ native menu bar collapse management.
/// Receives messages from the webview and delegates to menubar_collapse.zig.
pub const MenubarCollapseBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "init")) {
            menubar_collapse.init();
        } else if (std.mem.eql(u8, action, "collapse")) {
            menubar_collapse.collapse();
        } else if (std.mem.eql(u8, action, "expand")) {
            menubar_collapse.expand();
        } else if (std.mem.eql(u8, action, "toggle")) {
            menubar_collapse.toggle();
        } else if (std.mem.eql(u8, action, "getState")) {
            // Answered through `sendResultToJS` like every other request, so it
            // is stamped with the id of the call it answers. It used to hand
            // the page a bespoke reply key — `menubarCollapse:getState` — which
            // the JS side had to queue under by hand: its own pending entry,
            // its own failure path, and no timeout, so a call native never
            // answered held its resolver for the life of the page. The id makes
            // the key irrelevant, so the bespoke queue is gone and this is an
            // ordinary `_req`.
            var buf: [384]u8 = undefined;
            const json = std.fmt.bufPrint(
                &buf,
                "{{\"collapsed\":{s},\"initialized\":{s},\"separatorHidden\":{s}}}",
                .{
                    if (menubar_collapse.isCollapsed()) "true" else "false",
                    if (menubar_collapse.isInitialized()) "true" else "false",
                    if (menubar_collapse.isSeparatorHidden()) "true" else "false",
                },
            ) catch return;
            @import("bridge_error.zig").sendResultToJS(self.allocator, "getState", json);
        } else if (std.mem.eql(u8, action, "setAutoCollapse")) {
            // Parse delay from data (seconds as string)
            if (data.len > 0) {
                const delay = std.fmt.parseInt(u32, data, 10) catch 0;
                menubar_collapse.setAutoCollapse(delay);
            }
        } else if (std.mem.eql(u8, action, "setSeparatorHidden")) {
            const hidden = data.len > 0 and std.mem.eql(u8, data, "true");
            menubar_collapse.setSeparatorHidden(hidden);
        } else if (std.mem.eql(u8, action, "poll")) {
            // Periodic check for auto-collapse timer
            menubar_collapse.checkAutoCollapse();
        } else {
            log.debug("Unknown menubarCollapse action: {s}", .{action});
        }
    }
};
