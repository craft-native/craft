const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const keychain_mod = @import("keychain.zig");

const BridgeError = bridge_error.BridgeError;

const pending = @import("ios_async.zig");
const Operation = enum { set, get, delete, has };

/// Keychain calls may wait for authentication. Keep them off AppKit's main
/// thread, with owned arguments and the shared correlated reply lifecycle.
pub const KeychainBridge = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) KeychainBridge {
        return .{ .allocator = allocator };
    }
    pub fn deinit(_: *KeychainBridge) void {}
    pub fn handleMessage(self: *KeychainBridge, action: []const u8, data: []const u8) !void {
        self.schedule(action, data) catch |err| {
            bridge_error.sendErrorToJS(self.allocator, action, keychainError(err));
        };
    }
    fn schedule(_: *KeychainBridge, action: []const u8, data: []const u8) !void {
        const thread = try startWork(action, data, perform);
        thread.detach();
    }
};

fn startWork(action: []const u8, data: []const u8, comptime runner: fn (*Work) void) !std.Thread {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .ios) return BridgeError.PlatformNotSupported;
    const operation = std.meta.stringToEnum(Operation, action) orelse return BridgeError.UnknownAction;
    const allocator = std.heap.c_allocator;
    const payload = try parsePayload(allocator, data);
    errdefer freePayload(allocator, payload);
    if (operation == .set and payload.password == null) return BridgeError.MissingData;
    const ticket = pending.acquire(action) orelse return BridgeError.Busy;
    errdefer pending.abandon(ticket);
    const work = try allocator.create(Work);
    errdefer allocator.destroy(work);
    work.* = .{ .operation = operation, .payload = payload, .ticket = ticket };
    return try std.Thread.spawn(.{}, runner, .{work});
}

const Work = struct { operation: Operation, payload: Payload, ticket: pending.Ticket };
fn perform(work: *Work) void {
    const allocator = std.heap.c_allocator;
    defer {
        freePayload(allocator, work.payload);
        allocator.destroy(work);
    }
    const json = execute(allocator, work.operation, work.payload) catch |err| {
        pending.deliverErrorCode(work.ticket, keychainError(err));
        return;
    };
    defer allocator.free(json);
    pending.deliverJson(work.ticket, json);
}

fn execute(allocator: std.mem.Allocator, operation: Operation, payload: Payload) ![]u8 {
    var kc = try keychain_mod.Keychain.init(allocator, payload.service);
    defer kc.deinit();
    switch (operation) {
        .set => {
            try kc.setPassword(payload.account, payload.password.?);
            return allocator.dupe(u8, "{\"ok\":true}");
        },
        .delete => {
            try kc.deletePassword(payload.account);
            return allocator.dupe(u8, "{\"ok\":true}");
        },
        .has => return allocator.dupe(u8, if (try kc.hasPassword(payload.account)) "{\"value\":true}" else "{\"value\":false}"),
        .get => {
            const got = try kc.getPassword(payload.account);
            defer if (got) |value| allocator.free(value);
            return valueResult(allocator, got);
        },
    }
}

fn keychainError(err: anyerror) BridgeError {
    return switch (err) {
        error.MissingData => BridgeError.MissingData,
        error.InvalidJSON => BridgeError.InvalidJSON,
        error.UnknownAction => BridgeError.UnknownAction,
        error.NoAccess, error.AuthFailed, error.InteractionNotAllowed => BridgeError.PermissionDenied,
        error.UserCancelled => BridgeError.Cancelled,
        error.Unimplemented => BridgeError.PlatformNotSupported,
        error.InvalidData, error.Param => BridgeError.InvalidParameter,
        else => bridge_error.fromHandlerError(err),
    };
}

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
    const service = try allocator.dupe(u8, parsed.value.service);
    errdefer allocator.free(service);
    const account = try allocator.dupe(u8, parsed.value.account);
    errdefer allocator.free(account);
    return .{ .service = service, .account = account, .password = if (parsed.value.password) |p| try allocator.dupe(u8, p) else null };
}

fn freePayload(allocator: std.mem.Allocator, p: Payload) void {
    allocator.free(p.service);
    allocator.free(p.account);
    if (p.password) |pw| allocator.free(pw);
}

fn valueResult(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    if (value == null) return allocator.dupe(u8, "{\"value\":null}");
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
    return buf.toOwnedSlice(allocator);
}

test "Keychain replies preserve arbitrary control characters as valid JSON" {
    const allocator = std.testing.allocator;
    const secret = "unicode é\n\x00\x01\t\\\"";
    const json = try valueResult(allocator, secret);
    defer allocator.free(json);
    const decoded = try std.json.parseFromSlice(struct { value: []const u8 }, allocator, json, .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings(secret, decoded.value.value);
    try std.testing.expectEqual(BridgeError.PermissionDenied, keychainError(error.InteractionNotAllowed));
}

const WorkerTest = struct {
    var released: std.atomic.Value(bool) = .init(false);
    var timed_out = false;
    var owned_payload = false;
    var separate_thread = false;
    var parent: std.Thread.Id = undefined;
    fn run(work: *Work) void {
        const allocator = std.heap.c_allocator;
        defer {
            freePayload(allocator, work.payload);
            allocator.destroy(work);
        }
        defer pending.abandon(work.ticket);
        const deadline = @import("compat.zig").milliTimestamp() + 1000;
        while (!released.load(.acquire)) {
            if (@import("compat.zig").milliTimestamp() > deadline) {
                timed_out = true;
                break;
            }
            std.Thread.yield() catch {};
        }
        owned_payload = std.mem.eql(u8, work.payload.service, "owned.service") and std.mem.eql(u8, work.payload.password.?, "owned secret");
        separate_thread = std.Thread.getCurrentId() != parent;
    }
};

test "Keychain work returns while the native operation waits and owns its payload" {
    if (builtin.os.tag != .macos and builtin.os.tag != .ios) return error.SkipZigTest;
    WorkerTest.released.store(false, .release);
    WorkerTest.timed_out = false;
    WorkerTest.parent = std.Thread.getCurrentId();
    const data = try std.testing.allocator.dupe(u8, "{\"service\":\"owned.service\",\"account\":\"fixture\",\"password\":\"owned secret\"}");
    defer std.testing.allocator.free(data);
    const thread = try startWork("set", data, WorkerTest.run);
    @memset(data, 0);
    WorkerTest.released.store(true, .release);
    thread.join();
    try std.testing.expect(!WorkerTest.timed_out);
    try std.testing.expect(WorkerTest.owned_payload);
    try std.testing.expect(WorkerTest.separate_thread);
}
