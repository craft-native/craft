//! `window.craft.shortcuts` — global hotkeys.
//!
//! A thin adapter: it decodes the action, hands the payload to
//! `shortcut_registry.zig`, and turns the answer back into JavaScript. The
//! decisions live in the registry, where they are testable; the key is
//! actually reserved by `macos_hotkey.zig`.
//!
//! What used to be here, and what craft-native/craft#47 was about: an app
//! could register a hotkey, be told it worked, and never receive a keystroke.
//! `setupGlobalMonitor` computed an event mask, discarded it, installed
//! nothing, and logged "Global monitor setup (polling mode)" — there was no
//! polling either. The matcher it was supposed to feed was reachable only from
//! a function with no callers anywhere in the tree. Three further mismatches
//! sat on top of it, each individually fatal:
//!
//!   * the JS bridge sends `{id, accelerator}`; this file read `key` and
//!     `modifiers`, so every registration failed its own validation before it
//!     got anywhere near the missing monitor;
//!   * `isRegistered` and `list` answered by calling `__craftShortcutList` and
//!     friends, which nothing defines — so those promises hung for the full
//!     30-second request timeout and then rejected;
//!   * a triggered shortcut called `__craftShortcutCallback`, which nothing
//!     defines either, while the JS side was listening for a `craft:shortcut`
//!     event that was never dispatched.

const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const logging = @import("logging.zig");
const registry_mod = @import("shortcut_registry.zig");
const accel = @import("accelerator.zig");
const capabilities = @import("capabilities.zig");

const log = logging.shortcuts;

const BridgeError = bridge_error.BridgeError;

/// Re-exported so callers that named these through this module keep working.
pub const Modifiers = accel.Modifiers;
pub const Shortcut = registry_mod.Registration;

pub const action_register = registry_mod.action_register;
pub const action_unregister = registry_mod.action_unregister;
pub const action_unregister_all = registry_mod.action_unregister_all;
pub const action_enable = registry_mod.action_enable;
pub const action_disable = registry_mod.action_disable;
pub const action_is_registered = registry_mod.action_is_registered;
pub const action_list = registry_mod.action_list;

/// The event a triggered shortcut arrives on, matching `_evt('craft:shortcut')`
/// in `craft-bridge.js`.
pub const event_triggered = "craft:shortcut";

/// Where a registration that could not be granted is reported.
///
/// `register` is fire-and-forget on the JS side — its action name collides
/// with other bridges' in the request queue, so it cannot be a request without
/// mixing replies — which leaves an app no way to hear that the key it asked
/// for belongs to someone else. This event is that way.
pub const event_error = "craft:shortcut:error";

fn platform() registry_mod.Platform {
    if (comptime builtin.os.tag == .macos) {
        return .{
            .register = struct {
                fn f(keycode: u16, modifiers: u32, hotkey_id: u32) registry_mod.Ref {
                    return @import("macos_hotkey.zig").register(keycode, modifiers, hotkey_id);
                }
            }.f,
            .unregister = struct {
                fn f(ref: registry_mod.Ref) void {
                    @import("macos_hotkey.zig").unregister(ref);
                }
            }.f,
        };
    }
    // Linux and Windows have no global-hotkey implementation in craft yet.
    // Refusing every registration is the honest answer: the alternative —
    // accepting them — is the bug this file was rewritten to fix.
    return registry_mod.unsupported_platform;
}

pub const ShortcutsBridge = struct {
    allocator: std.mem.Allocator,
    registry: registry_mod.Registry,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .registry = registry_mod.Registry.init(allocator, platform()),
        };
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
        if (comptime builtin.os.tag == .macos) {
            @import("macos_hotkey.zig").on_pressed = null;
        }
        const global_state = @import("global_state.zig");
        global_state.instance.setShortcutsBridge(null);
    }

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            const bridge_err: BridgeError = err;
            // The action name travels with the error so `__craftBridgeError`
            // rejects only that action's callers.
            bridge_error.sendErrorToJS(self.allocator, action, bridge_err);

            // `isRegistered` and `list` are requests: the line above rejects
            // the promise their caller is holding, and that is the whole
            // report. Every other verb is fire-and-forget, so its caller has
            // already moved on and there is nothing to reject — the error
            // event is the only way it hears anything at all.
            const is_request = std.mem.eql(u8, action, action_is_registered) or
                std.mem.eql(u8, action, action_list);
            if (!is_request) self.reportFailure(data, bridge_err);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, action_register)) {
            self.ensureDelivery();
            const entry = try self.registry.register(data);
            log.debug("registered {s} as {s}", .{ entry.id, entry.accelerator });
        } else if (std.mem.eql(u8, action, action_unregister)) {
            try self.registry.unregister(data);
        } else if (std.mem.eql(u8, action, action_unregister_all)) {
            self.registry.unregisterAll();
        } else if (std.mem.eql(u8, action, action_enable)) {
            try self.registry.setEnabled(data, true);
        } else if (std.mem.eql(u8, action, action_disable)) {
            try self.registry.setEnabled(data, false);
        } else if (std.mem.eql(u8, action, action_is_registered)) {
            const json = try self.registry.isRegisteredJson(data);
            defer self.allocator.free(json);
            bridge_error.sendResultToJS(self.allocator, action, json);
        } else if (std.mem.eql(u8, action, action_list)) {
            const json = try self.registry.listJson();
            defer self.allocator.free(json);
            bridge_error.sendResultToJS(self.allocator, action, json);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// Point the platform's hotkey callback at this bridge. Cheap and
    /// idempotent, so it runs before every registration rather than depending
    /// on an initialisation order.
    fn ensureDelivery(self: *Self) void {
        _ = capabilities.registerEmitter(.shortcut);
        _ = capabilities.registerEmitter(.shortcut_error);
        const global_state = @import("global_state.zig");
        global_state.instance.setShortcutsBridge(self);
        if (comptime builtin.os.tag == .macos) {
            @import("macos_hotkey.zig").on_pressed = onHotKeyPressed;
        }
    }

    /// Called on the main thread when a registered combination is pressed
    /// anywhere in the system.
    pub fn deliver(self: *Self, hotkey_id: u32) void {
        const entry = self.registry.findByHotkeyId(hotkey_id) orelse return;
        // A hotkey disabled between the press and its delivery must not fire.
        if (!entry.enabled) return;

        log.debug("triggered {s} ({s})", .{ entry.id, entry.accelerator });
        const detail = registry_mod.triggeredDetail(self.allocator, entry.id, entry.accelerator) catch return;
        defer self.allocator.free(detail);
        self.dispatch(event_triggered, detail);
    }

    fn reportFailure(self: *Self, data: []const u8, err: BridgeError) void {
        // Best effort: the id is read back out of the payload so the app can
        // tell which of its registrations failed. A payload too malformed to
        // yield an id still gets the error, just without one.
        const IdOnly = struct { id: []const u8 = "" };
        var id: []const u8 = "";
        const parsed = std.json.parseFromSlice(IdOnly, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch null;
        defer if (parsed) |p| p.deinit();
        if (parsed) |p| id = p.value.id;

        const detail = registry_mod.errorDetail(
            self.allocator,
            id,
            bridge_error.errorCodeString(err),
            bridge_error.errorMessage(err),
        ) catch return;
        defer self.allocator.free(detail);
        self.dispatch(event_error, detail);
    }

    /// Emit `new CustomEvent(name, { detail })` into the page.
    fn dispatch(self: *Self, name: []const u8, detail: []const u8) void {
        const bridge = @import("bridge.zig");

        const js = registry_mod.eventScript(self.allocator, name, detail) catch return;
        defer self.allocator.free(js);

        bridge.evalJS(js) catch |eval_err| {
            log.debug("could not deliver {s}: {}", .{ name, eval_err });
        };
    }
};

/// Bridge between the platform's C callback and the live bridge instance.
fn onHotKeyPressed(hotkey_id: u32) void {
    const global_state = @import("global_state.zig");
    if (global_state.instance.getShortcutsBridge()) |bridge| bridge.deliver(hotkey_id);
}
