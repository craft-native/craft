//! `t: "prefs"` — the bridge adapter for the preference store.
//!
//! Thin on purpose: it decodes the action, hands the payload to `prefs.zig`,
//! and turns the answer back into JSON. The rules live in `prefs.zig`, where
//! they are testable against an in-memory backend; the platform lives in
//! `prefs_macos.zig`.
//!
//! ## Why the wire actions are namespaced
//!
//! `_req` in `craft-bridge.js` keys its pending-reply queue by the **action
//! name alone** — a documented limitation, and a real one. Of the six verbs
//! this bridge needs, only `keys` is unclaimed:
//!
//!   * `get` is already a request in the keychain and tags bridges;
//!   * `has` in keychain; `clear` in tags;
//!   * `set` and `delete` have no request-shaped competitor, but the keychain,
//!     crash-reporter and tags bridges all *emit* a result under those bare
//!     names even though their own facades never wait for one — a stray
//!     `{"ok":true}` that would shift a prefs caller off the queue and resolve
//!     it with a foreign payload.
//!
//! So the action on the wire is `prefs:get`, not `get`. `_req` then keys the
//! queue under `prefs:get` for free, `sendResultToJS`/`sendErrorToJS` match it
//! with no extra plumbing, and — unlike the one existing dodge in the tree,
//! which hand-rolls its promise to get a qualified result key — the 30-second
//! reaper that stops a caller hanging forever is preserved.

const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const logging = @import("logging.zig");
const prefs = @import("prefs.zig");
const prefs_macos = @import("prefs_macos.zig");

const log = logging.prefs;
const BridgeError = bridge_error.BridgeError;

const actions = @import("bridge_prefs_actions.zig");

pub const action_get = actions.get;
pub const action_set = actions.set;
pub const action_delete = actions.delete;
pub const action_clear = actions.clear;
pub const action_keys = actions.keys;
pub const action_info = actions.info;

/// The action every reply about an unrecognised action is filed under.
///
/// Never the bytes that arrived. Two reasons, both load-bearing: `craft.invoke`
/// lets a page post a bare action name of its choosing, and echoing one back
/// would reject every in-flight `keychain.get` and `tags.get` holding the same
/// bare name; and `sendErrorToJS` interpolates the action into a single-quoted
/// JS literal with no escaping, so echoing caller-supplied bytes is an
/// injection. Every action string this file passes is a compile-time constant.
pub const action_unknown = actions.unknown;

pub const PrefsBridge = struct {
    allocator: std.mem.Allocator,
    native: prefs_macos.Backend,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .native = prefs_macos.Backend.init(.current_application),
        };
    }

    pub fn deinit(self: *Self) void {
        self.native.deinit();
    }

    fn store(self: *Self) prefs.Store {
        return .{ .backend = self.native.backend() };
    }

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            bridge_error.sendErrorToJS(self.allocator, known(action), BridgeError.PlatformNotSupported);
            return;
        }
        self.handleMessageInternal(action, data) catch |err| {
            bridge_error.sendErrorToJS(self.allocator, known(action), translate(err));
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, action_get)) {
            try self.handleGet(data);
        } else if (std.mem.eql(u8, action, action_set)) {
            try self.handleSet(data);
        } else if (std.mem.eql(u8, action, action_delete)) {
            try self.handleDelete(data);
        } else if (std.mem.eql(u8, action, action_clear)) {
            try self.handleClear();
        } else if (std.mem.eql(u8, action, action_keys)) {
            try self.handleKeys();
        } else if (std.mem.eql(u8, action, action_info)) {
            try self.handleInfo();
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn handleGet(self: *Self, data: []const u8) !void {
        const parsed = try self.parse(prefs.KeyShape, data);
        defer parsed.deinit();

        const read = try self.store().get(self.allocator, parsed.value.k);
        defer if (read == .value and read.value == .string) self.allocator.free(read.value.string);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try prefs.appendReadJson(self.allocator, &out, read);
        bridge_error.sendResultToJS(self.allocator, action_get, out.items);
    }

    fn handleSet(self: *Self, data: []const u8) !void {
        const parsed = try self.parse(prefs.SetShape, data);
        defer parsed.deinit();

        // Re-validated here rather than trusted: `craft.invoke` and a
        // hand-rolled `postMessage` both reach this without passing the JS
        // facade's checks.
        const request = try prefs.decodeSet(parsed.value);
        try self.store().set(request.key, request.value);
        bridge_error.sendResultToJS(self.allocator, action_set, "{\"ok\":true}");
    }

    fn handleDelete(self: *Self, data: []const u8) !void {
        const parsed = try self.parse(prefs.KeyShape, data);
        defer parsed.deinit();

        const existed = try self.store().remove(parsed.value.k);
        bridge_error.sendResultToJS(self.allocator, action_delete, if (existed)
            "{\"ok\":true,\"existed\":true}"
        else
            "{\"ok\":true,\"existed\":false}");
    }

    fn handleClear(self: *Self) !void {
        const removed = try self.store().clear(self.allocator);
        const reply = try std.fmt.allocPrint(self.allocator, "{{\"ok\":true,\"removed\":{d}}}", .{removed});
        defer self.allocator.free(reply);
        bridge_error.sendResultToJS(self.allocator, action_clear, reply);
    }

    fn handleKeys(self: *Self) !void {
        const listed = try self.store().keys(self.allocator);
        defer {
            for (listed) |k| self.allocator.free(k);
            self.allocator.free(listed);
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try prefs.appendKeysJson(self.allocator, &out, listed);
        bridge_error.sendResultToJS(self.allocator, action_keys, out.items);
    }

    /// Which domain the preferences actually landed in, and how to read it.
    ///
    /// Not decoration: an unbundled dev-mode binary writes to a domain named
    /// after the executable, and a packaged `.app` writes to its bundle id, so
    /// preferences set in development appear to vanish when the app is
    /// packaged. This is what turns that into a question with an answer.
    fn handleInfo(self: *Self) !void {
        const domain = try prefs_macos.domainName(self.allocator);
        defer self.allocator.free(domain);

        const listed = try self.store().keys(self.allocator);
        defer {
            for (listed) |k| self.allocator.free(k);
            self.allocator.free(listed);
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"domain\":\"");
        try bridge_error.appendJsonEscaped(self.allocator, &out, domain);
        try out.appendSlice(self.allocator, "\",\"prefix\":\"" ++ prefs.prefix ++ "\",\"count\":");
        const tail = try std.fmt.allocPrint(self.allocator, "{d},\"readCommand\":\"defaults read ", .{listed.len});
        defer self.allocator.free(tail);
        try out.appendSlice(self.allocator, tail);
        try bridge_error.appendJsonEscaped(self.allocator, &out, domain);
        try out.appendSlice(self.allocator, "\"}");

        bridge_error.sendResultToJS(self.allocator, action_info, out.items);
    }

    fn parse(self: *Self, comptime T: type, data: []const u8) !std.json.Parsed(T) {
        if (data.len == 0) return BridgeError.MissingData;
        return std.json.parseFromSlice(T, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch BridgeError.InvalidJSON;
    }
};

/// An action name safe to interpolate into a reply.
fn known(action: []const u8) []const u8 {
    for ([_][]const u8{ action_get, action_set, action_delete, action_clear, action_keys, action_info }) |a| {
        if (std.mem.eql(u8, action, a)) return a;
    }
    return action_unknown;
}

/// Map onto the existing `BridgeError` set rather than adding variants: the
/// code and message switches in `bridge_error.zig` are exhaustive, so a new one
/// means editing both.
fn translate(err: anyerror) BridgeError {
    return switch (err) {
        error.InvalidKey, error.ValueTooLarge, error.UnsupportedValue => BridgeError.InvalidParameter,
        error.BackendFailure => BridgeError.NativeCallFailed,
        error.OutOfMemory => BridgeError.AllocationFailed,
        error.MissingData => BridgeError.MissingData,
        error.InvalidJSON => BridgeError.InvalidJSON,
        error.UnknownAction => BridgeError.UnknownAction,
        error.PlatformNotSupported => BridgeError.PlatformNotSupported,
        else => blk: {
            log.debug("unmapped prefs error: {any}", .{err});
            break :blk BridgeError.NativeCallFailed;
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "an unrecognised action is filed under a constant, never the bytes that arrived" {
    // `sendErrorToJS` splices the action into a single-quoted JS literal with
    // no escaping, and `__craftBridgeError` drains the pending queue by it. So
    // echoing back what arrived is both a script injection and a way to reject
    // every in-flight `keychain.get`.
    try testing.expectEqualStrings(action_unknown, known("get"));
    try testing.expectEqualStrings(action_unknown, known("'+alert(1)+'"));
    try testing.expectEqualStrings(action_unknown, known(""));
    try testing.expectEqualStrings(action_unknown, known("prefs:nope"));

    for ([_][]const u8{ action_get, action_set, action_delete, action_clear, action_keys, action_info }) |a| {
        try testing.expectEqualStrings(a, known(a));
    }
}

test "every wire action is namespaced" {
    // The single assertion that stops someone shortening these back to bare
    // names and silently reintroducing the pending-queue collision.
    for ([_][]const u8{ action_get, action_set, action_delete, action_clear, action_keys, action_info, action_unknown }) |a| {
        try testing.expect(std.mem.startsWith(u8, a, "prefs:"));
    }
}

test "store errors map onto the existing bridge error set" {
    try testing.expectEqual(BridgeError.InvalidParameter, translate(prefs.Error.InvalidKey));
    try testing.expectEqual(BridgeError.InvalidParameter, translate(prefs.Error.ValueTooLarge));
    try testing.expectEqual(BridgeError.InvalidParameter, translate(prefs.Error.UnsupportedValue));
    try testing.expectEqual(BridgeError.NativeCallFailed, translate(prefs.Error.BackendFailure));
    try testing.expectEqual(BridgeError.AllocationFailed, translate(prefs.Error.OutOfMemory));
    try testing.expectEqual(BridgeError.UnknownAction, translate(BridgeError.UnknownAction));
}
