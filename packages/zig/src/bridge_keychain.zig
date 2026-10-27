const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const keychain_mod = @import("keychain.zig");

const BridgeError = bridge_error.BridgeError;

/// Wraps `keychain.zig` (which already implements the platform-specific
/// stores: macOS Keychain Services, iOS, Linux Secret Service, Windows
/// Credential Manager) so JS can do `craft.keychain.set(account, secret)`.
///
/// Items are scoped under a `service_name` per Keychain instance. We
/// lazily build a single instance per process keyed on the service
/// passed in — this matches the typical "one app, one Keychain bucket"
/// usage pattern. Apps that want multiple buckets should pass distinct
/// `service` values per call; we allocate on demand.
pub const KeychainBridge = struct {
    allocator: std.mem.Allocator,
    // Cache the most recently used keychain instance so we don't pay
    // for re-initialisation on every call. A more elaborate cache (per
    // service) is overkill for now — apps rarely use more than one.
    cached: ?CachedKeychain = null,

    const Self = @This();

    const CachedKeychain = struct {
        service: []u8,
        kc: keychain_mod.Keychain,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        if (self.cached) |*c| {
            c.kc.deinit();
            self.allocator.free(c.service);
        }
    }

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            // `@errorCast(err)` only works for cast-from-superset cases;
            // here `err: anyerror` is broader than `BridgeError`, so we
            // can't @errorCast it back — the cast would silently produce
            // an invalid value. Manually map the variants we care about.
            const e: BridgeError = switch (err) {
                error.MissingData => BridgeError.MissingData,
                error.InvalidJSON => BridgeError.InvalidJSON,
                error.UnknownAction => BridgeError.UnknownAction,
                error.NoAccess, error.AuthFailed, error.InteractionNotAllowed => BridgeError.PermissionDenied,
                error.UserCancelled => BridgeError.Cancelled,
                error.Unimplemented => BridgeError.PlatformNotSupported,
                else => BridgeError.NativeCallFailed,
            };
            bridge_error.sendErrorToJS(self.allocator, action, e);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "set")) {
            const params = try parsePayload(self.allocator, data);
            defer freePayload(self.allocator, params);
            var kc = try self.getKeychain(params.service);
            try kc.setPassword(params.account, params.password orelse "");
            bridge_error.sendResultToJS(self.allocator, "set", "{\"ok\":true}");
        } else if (std.mem.eql(u8, action, "get")) {
            const params = try parsePayload(self.allocator, data);
            defer freePayload(self.allocator, params);
            var kc = try self.getKeychain(params.service);
            const got = try kc.getPassword(params.account);
            try sendValueResult(self.allocator, "get", got);
            if (got) |v| self.allocator.free(v);
        } else if (std.mem.eql(u8, action, "delete")) {
            const params = try parsePayload(self.allocator, data);
            defer freePayload(self.allocator, params);
            var kc = try self.getKeychain(params.service);
            try kc.deletePassword(params.account);
            bridge_error.sendResultToJS(self.allocator, "delete", "{\"ok\":true}");
        } else if (std.mem.eql(u8, action, "has")) {
            const params = try parsePayload(self.allocator, data);
            defer freePayload(self.allocator, params);
            var kc = try self.getKeychain(params.service);
            const present = try kc.hasPassword(params.account);
            const json = if (present) "{\"value\":true}" else "{\"value\":false}";
            bridge_error.sendResultToJS(self.allocator, "has", json);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn getKeychain(self: *Self, service: []const u8) !*keychain_mod.Keychain {
        // Reuse the cached instance only when the service matches; tear
        // down + rebuild on a different service to avoid leaking the old
        // one. This is "fast enough" — Keychain init is cheap, and apps
        // typically pin one service per process.
        if (self.cached) |*c| {
            if (std.mem.eql(u8, c.service, service)) return &c.kc;
            c.kc.deinit();
            self.allocator.free(c.service);
            self.cached = null;
        }

        // errdefer here matters: if Keychain.init fails AFTER we've
        // duped the service string, the old code leaked the dup. Free
        // it on error so this stays clean across long-running processes.
        const service_copy = try self.allocator.dupe(u8, service);
        errdefer self.allocator.free(service_copy);
        const kc = try keychain_mod.Keychain.init(self.allocator, service_copy);
        self.cached = .{ .service = service_copy, .kc = kc };
        return &self.cached.?.kc;
    }
};

const Payload = struct {
    service: []const u8,
    account: []const u8,
    password: ?[]const u8,
};

fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !Payload {
    const ParseShape = struct {
        service: []const u8 = "",
        account: []const u8 = "",
        password: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(ParseShape, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return BridgeError.InvalidJSON;
    defer parsed.deinit();
    if (parsed.value.service.len == 0) return BridgeError.MissingData;
    if (parsed.value.account.len == 0) return BridgeError.MissingData;
    return .{
        .service = try allocator.dupe(u8, parsed.value.service),
        .account = try allocator.dupe(u8, parsed.value.account),
        .password = if (parsed.value.password) |p| try allocator.dupe(u8, p) else null,
    };
}

fn freePayload(allocator: std.mem.Allocator, p: Payload) void {
    allocator.free(p.service);
    allocator.free(p.account);
    if (p.password) |pw| allocator.free(pw);
}

fn sendValueResult(allocator: std.mem.Allocator, action: []const u8, value: ?[]const u8) !void {
    if (value == null) {
        bridge_error.sendResultToJS(allocator, action, "{\"value\":null}");
        return;
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"value\":\"");
    for (value.?) |b| {
        switch (b) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var escaped: [6]u8 = undefined;
                try buf.appendSlice(allocator, try std.fmt.bufPrint(&escaped, "\\u{x:0>4}", .{b}));
            },
            else => try buf.append(allocator, b),
        }
    }
    try buf.appendSlice(allocator, "\"}");
    const owned = try buf.toOwnedSlice(allocator);
    defer allocator.free(owned);
    bridge_error.sendResultToJS(allocator, action, owned);
}
