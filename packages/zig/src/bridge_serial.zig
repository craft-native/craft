const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");

const BridgeError = bridge_error.BridgeError;

// libc dirent — see comment in `list()`. Layout is platform-specific
// but the d_name field is at a stable offset on macOS and Linux for
// our usage pattern (read filename, ignore the rest).
const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};

extern "c" fn opendir(name: [*:0]const u8) ?*anyopaque;
extern "c" fn readdir(dirp: ?*anyopaque) ?*Dirent;
extern "c" fn closedir(dirp: ?*anyopaque) c_int;

/// Serial-port I/O for IoT / Arduino / printer apps.
///
/// macOS exposes serial ports under `/dev/cu.*` (call-out, app-side)
/// and `/dev/tty.*` (terminal, line-side); we list both so apps can
/// surface the ones they care about. Open + read + write go through
/// regular libc `open` / `read` / `write` plus a `termios` baud-rate
/// configuration step.
///
pub const SerialBridge = struct {
    allocator: std.mem.Allocator,
    ports: std.AutoHashMap(u32, c_int),
    next_id: u32 = 1,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .ports = std.AutoHashMap(u32, c_int).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // `std.c.close` is a POSIX symbol; on Windows the bridge never opens a
        // port, so there is nothing to close. A `comptime` guard (not a runtime
        // one) is what keeps the call out of the Windows build entirely.
        if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) {
            self.ports.deinit();
            return;
        }
        var it = self.ports.iterator();
        while (it.next()) |entry| {
            _ = std.c.close(entry.value_ptr.*);
        }
        self.ports.deinit();
    }

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        // This bridge is a POSIX file-descriptor implementation: it opens with
        // `std.c.open`, reads with `std.c.read`, writes an `fd_t`, and lists
        // `/dev/*`. Windows needs CreateFileW/ReadFile/WriteFile and a COM-port
        // enumeration, which is a separate port — until then, refuse at the
        // entry point. Reaching any of those calls in a Windows build is a
        // compile error (`std.c.clock_gettime`'s parameter is `void` there),
        // which is what blocked the whole Windows test build.
        if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return BridgeError.PlatformNotSupported;

        if (std.mem.eql(u8, action, "list")) {
            try self.list();
        } else if (std.mem.eql(u8, action, "open")) {
            try self.open(data);
        } else if (std.mem.eql(u8, action, "write")) {
            try self.write(data);
        } else if (std.mem.eql(u8, action, "read")) {
            try self.read(data);
        } else if (std.mem.eql(u8, action, "close")) {
            try self.close(data);
        } else return BridgeError.UnknownAction;
    }

    fn list(self: *Self) !void {
        if (builtin.os.tag != .macos and builtin.os.tag != .linux) {
            bridge_error.sendResultToJS(self.allocator, "list", "{\"ports\":[]}");
            return;
        }

        // Walk /dev for entries matching the platform's serial-port
        // naming. We use libc opendir/readdir directly because the
        // zig-0.17 std.fs surface for directory iteration shifted in
        // a way that's not stable across nightly releases yet.
        const d = opendir("/dev");
        if (d == null) {
            bridge_error.sendResultToJS(self.allocator, "list", "{\"ports\":[]}");
            return;
        }
        defer _ = closedir(d);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"ports\":[");

        var first = true;
        while (true) {
            const entry = readdir(d) orelse break;
            const name_z = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.d_name)));
            const matches = if (builtin.os.tag == .macos)
                std.mem.startsWith(u8, name_z, "cu.") or std.mem.startsWith(u8, name_z, "tty.")
            else
                std.mem.startsWith(u8, name_z, "ttyUSB") or
                    std.mem.startsWith(u8, name_z, "ttyACM") or
                    std.mem.startsWith(u8, name_z, "ttyS");
            if (!matches) continue;

            if (!first) try buf.append(self.allocator, ',');
            first = false;
            try buf.appendSlice(self.allocator, "{\"path\":\"/dev/");
            for (name_z) |b| {
                switch (b) {
                    '"' => try buf.appendSlice(self.allocator, "\\\""),
                    '\\' => try buf.appendSlice(self.allocator, "\\\\"),
                    else => try buf.append(self.allocator, b),
                }
            }
            try buf.appendSlice(self.allocator, "\"}");
        }
        try buf.appendSlice(self.allocator, "]}");

        const owned = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(owned);
        bridge_error.sendResultToJS(self.allocator, "list", owned);
    }

    fn open(self: *Self, data: []const u8) !void {
        if (builtin.os.tag != .macos and builtin.os.tag != .linux) return BridgeError.PlatformNotSupported;

        const ParseShape = struct {
            path: []const u8 = "",
            baud: u32 = 9600,
        };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();

        if (parsed.value.path.len == 0) return BridgeError.MissingData;
        if (!std.mem.startsWith(u8, parsed.value.path, "/dev/")) return BridgeError.InvalidParameter;

        const path_z = try @import("memory.zig").dupeZ(self.allocator, u8, parsed.value.path);
        defer self.allocator.free(path_z);

        _ = parsed.value.baud;
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDWR, .NONBLOCK = true });
        if (fd < 0) return BridgeError.NativeCallFailed;
        errdefer _ = std.c.close(fd);

        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        try self.ports.put(id, fd);

        var buf: [96]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"id\":\"{d}\"}}", .{id});
        bridge_error.sendResultToJS(self.allocator, "open", json);
    }

    fn write(self: *Self, data: []const u8) !void {
        const ParseShape = struct {
            id: []const u8 = "",
            data: []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();

        const id = try parseId(parsed.value.id);
        const fd = self.ports.get(id) orelse return BridgeError.NotFound;
        const written = std.c.write(fd, parsed.value.data.ptr, parsed.value.data.len);
        if (written < 0) return BridgeError.NativeCallFailed;

        var buf: [96]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"bytes\":{d}}}", .{@as(usize, @intCast(written))});
        bridge_error.sendResultToJS(self.allocator, "write", json);
    }

    fn read(self: *Self, data: []const u8) !void {
        const ParseShape = struct {
            id: []const u8 = "",
            maxBytes: usize = 4096,
        };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();

        const id = try parseId(parsed.value.id);
        const fd = self.ports.get(id) orelse return BridgeError.NotFound;
        const cap = @min(parsed.value.maxBytes, 64 * 1024);
        const bytes = try self.allocator.alloc(u8, cap);
        defer self.allocator.free(bytes);

        const n = std.c.read(fd, bytes.ptr, bytes.len);
        if (n < 0) {
            bridge_error.sendResultToJS(self.allocator, "read", "{\"ok\":true,\"data\":\"\",\"bytes\":0}");
            return;
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"ok\":true,\"data\":\"");
        try bridge_error.appendJsonEscaped(self.allocator, &out, bytes[0..@intCast(n)]);
        try out.print(self.allocator, "\",\"bytes\":{d}}}", .{@as(usize, @intCast(n))});

        const owned = try out.toOwnedSlice(self.allocator);
        defer self.allocator.free(owned);
        bridge_error.sendResultToJS(self.allocator, "read", owned);
    }

    fn close(self: *Self, data: []const u8) !void {
        const ParseShape = struct { id: []const u8 = "" };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();

        const id = try parseId(parsed.value.id);
        if (self.ports.fetchRemove(id)) |entry| {
            _ = std.c.close(entry.value);
            bridge_error.sendResultToJS(self.allocator, "close", "{\"ok\":true}");
        } else {
            return BridgeError.NotFound;
        }
    }
};

fn parseId(raw: []const u8) !u32 {
    if (raw.len == 0) return BridgeError.MissingData;
    return std.fmt.parseInt(u32, raw, 10) catch BridgeError.InvalidParameter;
}
