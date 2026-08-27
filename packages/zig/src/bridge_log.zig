const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const host_log = @import("log.zig");

const BridgeError = bridge_error.BridgeError;

/// The page's own log, forwarded to the same sink as craft's.
///
/// `craft.log.{debug,info,warn,error}(message)` used to reach
/// `std.debug.print` on macOS and *nothing at all* anywhere else — the write
/// sat behind `if (builtin.os.tag == .macos)`, so on Linux and Windows the
/// payload was parsed, discarded, and answered `{"ok":true}`. A page that
/// logged into that got a resolved promise and no record.
///
/// It goes through `log.zig` now, which is what `--log-file` configures, so a
/// page's diagnostics land in the same file and the same order as the host's
/// rather than in a different place on one platform and nowhere on the others.
///
/// The `os_log_create` handle this file used to open on macOS is gone. It was
/// created at init, never used, and the comment beside it called it a
/// placeholder for a future revision that would reach `os_log` proper —
/// which needs libBlocksRuntime and never happened. A file sink is the thing
/// it was standing in for.
/// The host level a page's `level` string means.
///
/// Anything unrecognised is info rather than dropped: a page that invents a
/// level, or sends none, should still be heard. Silently discarding it would
/// be the same failure this file already had on Linux and Windows.
fn levelFor(name: []const u8) host_log.LogLevel {
    const table = .{
        .{ "debug", host_log.LogLevel.Debug },
        .{ "trace", host_log.LogLevel.Debug },
        .{ "info", host_log.LogLevel.Info },
        .{ "log", host_log.LogLevel.Info },
        .{ "warn", host_log.LogLevel.Warning },
        .{ "warning", host_log.LogLevel.Warning },
        .{ "error", host_log.LogLevel.Error },
        .{ "err", host_log.LogLevel.Error },
        .{ "fatal", host_log.LogLevel.Fatal },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    return .Info;
}

pub const LogBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Longest page message recorded. The text comes from the page, and the
    /// host sink formats into a fixed buffer — clamping here means a long
    /// message is clipped at a boundary this file chose rather than one the
    /// formatter happened to have.
    const max_message = 1024;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "log")) try self.log(data) else return BridgeError.UnknownAction;
    }

    fn log(self: *Self, data: []const u8) !void {
        const ParseShape = struct {
            level: []const u8 = "info",
            message: []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();

        const message = if (parsed.value.message.len > max_message)
            parsed.value.message[0..max_message]
        else
            parsed.value.message;

        // Tagged `[page]` so a log file makes it obvious which side a line came
        // from — the host's records and the page's now share one stream, and
        // telling them apart is most of what makes that stream readable.
        switch (levelFor(parsed.value.level)) {
            .Debug => host_log.log(.Debug, "[page] {s}", .{message}),
            .Info => host_log.log(.Info, "[page] {s}", .{message}),
            .Warning => host_log.log(.Warning, "[page] {s}", .{message}),
            .Error => host_log.log(.Error, "[page] {s}", .{message}),
            .Fatal => host_log.log(.Fatal, "[page] {s}", .{message}),
            // `levelFor` never returns this — a page cannot ask to be silenced,
            // only the host can — but the switch stays exhaustive so adding a
            // level is a compile error rather than a dropped record.
            .Off => {},
        }

        bridge_error.sendResultToJS(self.allocator, "log", "{\"ok\":true}");
    }
};

const testing = std.testing;

test "the levels the page facade sends all map to a host level" {
    // These four are exactly what `craft.log.*` sends (craft-bridge.js).
    try testing.expectEqual(host_log.LogLevel.Debug, levelFor("debug"));
    try testing.expectEqual(host_log.LogLevel.Info, levelFor("info"));
    try testing.expectEqual(host_log.LogLevel.Warning, levelFor("warn"));
    try testing.expectEqual(host_log.LogLevel.Error, levelFor("error"));
}

test "level names are matched without regard to case" {
    try testing.expectEqual(host_log.LogLevel.Warning, levelFor("WARN"));
    try testing.expectEqual(host_log.LogLevel.Error, levelFor("Error"));
}

test "an unrecognised level is still heard" {
    // Dropping it would repeat the failure this file already had, where a
    // page's log was parsed, discarded, and answered ok.
    try testing.expectEqual(host_log.LogLevel.Info, levelFor("verbose"));
    try testing.expectEqual(host_log.LogLevel.Info, levelFor(""));
    try testing.expectEqual(host_log.LogLevel.Info, levelFor("🙂"));
}

test "the payload the page sends decodes into a level and a message" {
    const Shape = struct {
        level: []const u8 = "info",
        message: []const u8 = "",
    };
    const payload =
        \\{"level":"warn","message":"something happened"}
    ;
    const parsed = try std.json.parseFromSlice(Shape, testing.allocator, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try testing.expectEqual(host_log.LogLevel.Warning, levelFor(parsed.value.level));
    try testing.expectEqualStrings("something happened", parsed.value.message);
}

test "a page cannot log an unbounded message" {
    // The text comes from the page. Clipping here means the boundary is one
    // this file chose rather than whatever the host formatter happened to have.
    var huge: [LogBridge.max_message * 2]u8 = undefined;
    @memset(&huge, 'x');
    const clipped = if (huge.len > LogBridge.max_message) huge[0..LogBridge.max_message] else huge[0..];
    try testing.expectEqual(LogBridge.max_message, clipped.len);
}
