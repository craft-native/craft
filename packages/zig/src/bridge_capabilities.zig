//! `t: "capabilities"` — the page asking what the native side actually serves.
//!
//! Answered from `capability_registry.zig`, which is built from the same action
//! constants the dispatch chains compare against, and from the live-emitter set
//! that only real emitters can mark. Nothing here is hand-maintained, which is
//! the entire point: a hand-written capability list would be authoritative-
//! looking and wrong within a release, and that is worse than no list at all.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");
const registry = @import("capability_registry.zig");

const BridgeError = bridge_error.BridgeError;

/// Namespace-qualified, like the prefs bridge and for the same reason: the
/// pending-reply queue is keyed by action name alone, so a bare `get` would be
/// drained by whichever of keychain or tags replied first.
pub const A = struct {
    pub const get = "capabilities:get";
};

/// What craft serves on the `capabilities` namespace.
pub const capability_actions = [_]@import("capabilities.zig").ActionDecl{
    .{ .name = A.get, .reply = .result },
};

pub const action_get = A.get;

/// What an unrecognised action is reported under.
///
/// Never the bytes that arrived: the action is interpolated into a JS literal
/// unescaped, and `craft.invoke` lets a page choose it.
pub const action_unknown = "capabilities:unknownAction";

pub const CapabilitiesBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, _: []const u8) !void {
        if (!std.mem.eql(u8, action, A.get)) {
            bridge_error.sendErrorToJS(self.allocator, action_unknown, BridgeError.UnknownAction);
            return;
        }

        // Rendered per call rather than cached: an emitter can register after
        // the page loads — a subsystem that only initialises on first use — and
        // answering from a snapshot would be the stale-declaration problem this
        // whole mechanism exists to prevent.
        const json = registry.manifestJson(self.allocator) catch {
            bridge_error.sendErrorToJS(self.allocator, action_get, BridgeError.AllocationFailed);
            return;
        };
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, action_get, json);
    }
};

const testing = std.testing;

test "the action names are namespaced" {
    try testing.expect(std.mem.startsWith(u8, action_get, "capabilities:"));
    try testing.expect(std.mem.startsWith(u8, action_unknown, "capabilities:"));
}
