const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");

const BridgeError = bridge_error.BridgeError;

// `std.time.milliTimestamp` was removed in zig 0.17 and the public
// `time.zig` surface was reduced to just the unit constants. Pull the
// wall-clock from libc directly. macOS's `gettimeofday` gives us
// seconds + microseconds since epoch with one syscall.
const TimeSpec = extern struct { tv_sec: i64, tv_usec: i64 };
extern "c" fn gettimeofday(tv: *TimeSpec, tz: ?*anyopaque) c_int;

fn nowMillis() i64 {
    var ts = TimeSpec{ .tv_sec = 0, .tv_usec = 0 };
    _ = gettimeofday(&ts, null);
    return ts.tv_sec * std.time.ms_per_s + @divFloor(ts.tv_usec, std.time.us_per_ms);
}

/// Crash reporter bridge.
///
/// Captures unhandled exceptions raised in the JS layer (we don't try
/// to catch native zig panics — those would already have terminated
/// the process by the time we'd see them). Stores a small ring buffer
/// of recent crashes in memory; apps can drain it and forward to a
/// real backend (Sentry, Bugsnag, custom HTTP) themselves.
///
/// Design choice: we deliberately don't ship a built-in HTTP uploader.
/// Apps care strongly about WHERE crash reports go (data residency,
/// privacy policy disclosures, retention) — picking a default would
/// surprise users. The `flush` action returns the queue and `clear`
/// empties it; that's enough to compose any backend on top.
pub const CrashReporterBridge = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayListUnmanaged(CrashEntry) = .empty,
    enabled: bool = true,
    user_id: ?[]u8 = null,
    app_version: ?[]u8 = null,

    const Self = @This();
    const MAX_QUEUE_LEN: usize = 64; // ring-buffer cap to bound memory

    const CrashEntry = struct {
        timestamp: i64, // epoch ms
        severity: []u8, // "error" | "warning" | "fatal"
        message: []u8,
        source: []u8, // "js" | "native"
        stack: []u8,

        fn deinit(self: *CrashEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.severity);
            allocator.free(self.message);
            allocator.free(self.source);
            allocator.free(self.stack);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.queue.items) |*entry| entry.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        if (self.user_id) |u| self.allocator.free(u);
        if (self.app_version) |v| self.allocator.free(v);
    }

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "report")) {
            try self.report(data);
        } else if (std.mem.eql(u8, action, "flush")) {
            try self.flush();
        } else if (std.mem.eql(u8, action, "clear")) {
            try self.clear();
        } else if (std.mem.eql(u8, action, "setEnabled")) {
            try self.setEnabled(data);
        } else if (std.mem.eql(u8, action, "setUser")) {
            try self.setUser(data);
        } else if (std.mem.eql(u8, action, "setAppVersion")) {
            try self.setAppVersion(data);
        } else if (std.mem.eql(u8, action, "isEnabled")) {
            const json = if (self.enabled) "{\"value\":true}" else "{\"value\":false}";
            bridge_error.sendResultToJS(self.allocator, "isEnabled", json);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn report(self: *Self, data: []const u8) !void {
        if (!self.enabled) {
            bridge_error.sendResultToJS(self.allocator, "report", "{\"queued\":false}");
            return;
        }

        const ParseShape = struct {
            severity: []const u8 = "error",
            message: []const u8 = "",
            source: []const u8 = "js",
            stack: []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        if (parsed.value.message.len == 0) return BridgeError.MissingData;

        // Drop the oldest entry when at capacity. A bounded queue keeps
        // memory predictable; apps that need every crash forwarded
        // should call `flush` periodically (e.g. on craft:ready or on
        // interval). The alternative (unbounded queue) caused a real
        // OOM in early field testing where a tight crash loop produced
        // 100k entries before the user noticed.
        if (self.queue.items.len >= MAX_QUEUE_LEN) {
            var oldest = self.queue.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        const entry = CrashEntry{
            .timestamp = nowMillis(),
            .severity = try self.allocator.dupe(u8, parsed.value.severity),
            .message = try self.allocator.dupe(u8, parsed.value.message),
            .source = try self.allocator.dupe(u8, parsed.value.source),
            .stack = try self.allocator.dupe(u8, parsed.value.stack),
        };
        try self.queue.append(self.allocator, entry);

        if (comptime builtin.mode == .Debug) {
            std.debug.print("[CrashReporter] {s} ({s}): {s}\n", .{
                entry.severity, entry.source, entry.message,
            });
        }

        bridge_error.sendResultToJS(self.allocator, "report", "{\"queued\":true}");
    }

    fn flush(self: *Self) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"entries\":[");
        for (self.queue.items, 0..) |entry, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try writeEntry(self.allocator, &buf, entry, self.user_id, self.app_version);
        }
        try buf.appendSlice(self.allocator, "]}");

        const json = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, "flush", json);

        // Don't clear automatically — apps may want to inspect after
        // flushing. They call `clear()` once they've persisted the
        // entries elsewhere.
    }

    fn clear(self: *Self) !void {
        for (self.queue.items) |*entry| entry.deinit(self.allocator);
        self.queue.clearRetainingCapacity();
        bridge_error.sendResultToJS(self.allocator, "clear", "{\"ok\":true}");
    }

    fn setEnabled(self: *Self, data: []const u8) !void {
        const ParseShape = struct { value: bool = true };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        self.enabled = parsed.value.value;
        bridge_error.sendResultToJS(self.allocator, "setEnabled", "{\"ok\":true}");
    }

    fn setUser(self: *Self, data: []const u8) !void {
        const ParseShape = struct { id: []const u8 = "" };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        if (self.user_id) |old| self.allocator.free(old);
        self.user_id = if (parsed.value.id.len > 0)
            try self.allocator.dupe(u8, parsed.value.id)
        else
            null;
        bridge_error.sendResultToJS(self.allocator, "setUser", "{\"ok\":true}");
    }

    fn setAppVersion(self: *Self, data: []const u8) !void {
        const ParseShape = struct { version: []const u8 = "" };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        if (self.app_version) |old| self.allocator.free(old);
        self.app_version = if (parsed.value.version.len > 0)
            try self.allocator.dupe(u8, parsed.value.version)
        else
            null;
        bridge_error.sendResultToJS(self.allocator, "setAppVersion", "{\"ok\":true}");
    }
};

fn writeEntry(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    entry: CrashReporterBridge.CrashEntry,
    user_id: ?[]const u8,
    app_version: ?[]const u8,
) !void {
    try buf.append(allocator, '{');
    try writeIntField(allocator, buf, "timestamp", entry.timestamp, true);
    try writeStrField(allocator, buf, "severity", entry.severity, false);
    try writeStrField(allocator, buf, "message", entry.message, false);
    try writeStrField(allocator, buf, "source", entry.source, false);
    try writeStrField(allocator, buf, "stack", entry.stack, false);
    if (user_id) |u| try writeStrField(allocator, buf, "userId", u, false);
    if (app_version) |v| try writeStrField(allocator, buf, "appVersion", v, false);
    try buf.append(allocator, '}');
}

fn writeStrField(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try buf.append(allocator, ',');
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, "\":\"");
    for (value) |b| {
        switch (b) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var hex_buf: [6]u8 = undefined;
                const written = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{b}) catch continue;
                try buf.appendSlice(allocator, written);
            },
            else => try buf.append(allocator, b),
        }
    }
    try buf.append(allocator, '"');
}

fn writeIntField(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), key: []const u8, value: i64, first: bool) !void {
    if (!first) try buf.append(allocator, ',');
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, "\":");
    var num_buf: [32]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{value});
    try buf.appendSlice(allocator, num_str);
}
