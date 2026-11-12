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
    /// Open ports. A POSIX file descriptor or a Win32 `HANDLE`, both widened to
    /// `usize`: the two are pointer-sized and never coexist on one target, so
    /// one map serves both without a tagged union.
    ports: std.AutoHashMap(u32, usize),
    next_id: u32 = 1,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .ports = std.AutoHashMap(u32, usize).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.ports.iterator();
        while (it.next()) |entry| {
            if (comptime builtin.os.tag == .windows) {
                _ = CloseHandle(@ptrFromInt(entry.value_ptr.*));
            } else {
                _ = std.c.close(@intCast(entry.value_ptr.*));
            }
        }
        self.ports.deinit();
    }

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
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
        if (comptime builtin.os.tag == .windows) return self.windowsList();
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

        if (comptime builtin.os.tag == .windows)
            return self.windowsOpen(parsed.value.path, parsed.value.baud);

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
        try self.ports.put(id, @intCast(fd));

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
        const handle = self.ports.get(id) orelse return BridgeError.NotFound;

        if (comptime builtin.os.tag == .windows) {
            var written: u32 = 0;
            if (parsed.value.data.len > std.math.maxInt(u32)) return BridgeError.InvalidParameter;
            if (WriteFile(@ptrFromInt(handle), parsed.value.data.ptr, @intCast(parsed.value.data.len), &written, null) == 0)
                return BridgeError.NativeCallFailed;
            var wbuf: [96]u8 = undefined;
            const wjson = try std.fmt.bufPrint(&wbuf, "{{\"ok\":true,\"bytes\":{d}}}", .{written});
            bridge_error.sendResultToJS(self.allocator, "write", wjson);
            return;
        }

        const written = std.c.write(@intCast(handle), parsed.value.data.ptr, parsed.value.data.len);
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
        const handle = self.ports.get(id) orelse return BridgeError.NotFound;
        const cap = @min(parsed.value.maxBytes, 64 * 1024);
        const bytes = try self.allocator.alloc(u8, cap);
        defer self.allocator.free(bytes);

        var n: isize = 0;
        if (comptime builtin.os.tag == .windows) {
            var got: u32 = 0;
            if (cap > std.math.maxInt(u32)) return BridgeError.InvalidParameter;
            if (ReadFile(@ptrFromInt(handle), bytes.ptr, @intCast(cap), &got, null) == 0) {
                bridge_error.sendResultToJS(self.allocator, "read", "{\"ok\":true,\"data\":\"\",\"bytes\":0}");
                return;
            }
            n = @intCast(got);
        } else {
            n = std.c.read(@intCast(handle), bytes.ptr, bytes.len);
            if (n < 0) {
                bridge_error.sendResultToJS(self.allocator, "read", "{\"ok\":true,\"data\":\"\",\"bytes\":0}");
                return;
            }
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
            if (comptime builtin.os.tag == .windows) {
                _ = CloseHandle(@ptrFromInt(entry.value));
            } else {
                _ = std.c.close(@intCast(entry.value));
            }
            bridge_error.sendResultToJS(self.allocator, "close", "{\"ok\":true}");
        } else {
            return BridgeError.NotFound;
        }
    }

    /// COM-port enumeration. `QueryDosDeviceW` is the documented way to ask
    /// whether `COM<n>` resolves without opening it: a bound port resolves to a
    /// DOS device target (`\Device\Serial0`, `\Device\BthModem1` for a
    /// Bluetooth link), an unused name fails with `ERROR_FILE_NOT_FOUND`.
    /// Scanning a fixed range is allocation-free and does not depend on the
    /// `SERIALCOMM` registry map, which only lists ports with a driver bound
    /// and whose order is not the numeric one.
    fn windowsList(self: *Self) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"ports\":[");

        var first = true;
        var n: u32 = 1;
        while (n <= 256) : (n += 1) {
            var name_buf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "COM{d}", .{n}) catch continue;

            var wide: [16]u16 = undefined;
            for (name, 0..) |ch, i| wide[i] = ch;
            wide[name.len] = 0;

            var target: [256]u16 = undefined;
            if (QueryDosDeviceW(wide[0..name.len :0].ptr, &target, target.len) == 0) continue;

            if (!first) try out.append(self.allocator, ',');
            first = false;
            try out.appendSlice(self.allocator, "{\"path\":\"");
            try out.appendSlice(self.allocator, name);
            try out.appendSlice(self.allocator, "\"}");
        }
        try out.appendSlice(self.allocator, "]}");

        const owned = try out.toOwnedSlice(self.allocator);
        defer self.allocator.free(owned);
        bridge_error.sendResultToJS(self.allocator, "list", owned);
    }

    /// Open a COM port. Accepts both `COM3` and the `\\.\COM3` device-path
    /// form; the latter is mandatory for `COM10` and above, and harmless for
    /// `COM1`..`COM9`, so it is normalised in rather than required from the
    /// caller.
    fn windowsOpen(self: *Self, path: []const u8, baud: u32) !void {
        var path_buf: [64]u8 = undefined;
        const device_path = if (std.mem.startsWith(u8, path, "\\\\.\\"))
            path
        else
            std.fmt.bufPrint(&path_buf, "\\\\.\\{s}", .{path}) catch return BridgeError.InvalidParameter;

        var wide: [128]u16 = undefined;
        if (device_path.len + 1 > wide.len) return BridgeError.InvalidParameter;
        for (device_path, 0..) |ch, i| {
            if (ch > 0x7f) return BridgeError.InvalidParameter;
            wide[i] = ch;
        }
        wide[device_path.len] = 0;

        const raw = CreateFileW(
            wide[0..device_path.len :0].ptr,
            GENERIC_READ | GENERIC_WRITE,
            0, // exclusive: a serial port cannot be shared
            null,
            OPEN_EXISTING,
            0,
            null,
        );
        if (raw == 0 or raw == std.math.maxInt(usize)) return BridgeError.NativeCallFailed;
        const handle: *anyopaque = @ptrFromInt(raw);
        errdefer _ = CloseHandle(handle);

        // `read` must not park the bridge thread on a blocking Win32 call: a
        // zero total timeout plus an "any byte arrives" interval timeout makes
        // `ReadFile` return immediately with 0 bytes when the port is idle.
        var timeouts = COMMTIMEOUTS{
            .ReadIntervalTimeout = std.math.maxInt(u32),
            .ReadTotalTimeoutMultiplier = 0,
            .ReadTotalTimeoutConstant = 0,
            .WriteTotalTimeoutMultiplier = 0,
            .WriteTotalTimeoutConstant = 5000,
        };
        _ = SetCommTimeouts(handle, &timeouts);

        // Configure the line only when the caller asked for a rate. `GetCommState`
        // first, so the flags the driver considers meaningful are preserved
        // instead of being invented here.
        if (baud != 0) {
            var dcb: DCB = std.mem.zeroes(DCB);
            dcb.DCBlength = @sizeOf(DCB);
            if (GetCommState(handle, &dcb) != 0) {
                dcb.BaudRate = baud;
                dcb.ByteSize = 8;
                dcb.Parity = 0; // NOPARITY
                dcb.StopBits = 0; // ONESTOPBIT
                dcb.flags |= 1; // fBinary
                _ = SetCommState(handle, &dcb);
            }
        }

        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        try self.ports.put(id, raw);

        var buf: [96]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"id\":\"{d}\"}}", .{id});
        bridge_error.sendResultToJS(self.allocator, "open", json);
    }
};

// =============================================================================
// Windows: Win32 serial API
// =============================================================================

const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const OPEN_EXISTING: u32 = 3;

extern "kernel32" fn CreateFileW(
    lp_file_name: [*:0]const u16,
    dw_desired_access: u32,
    dw_share_mode: u32,
    lp_security_attributes: ?*anyopaque,
    dw_creation_disposition: u32,
    dw_flags_and_attributes: u32,
    h_template_file: ?*anyopaque,
) callconv(.c) usize;

extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.c) c_int;

extern "kernel32" fn WriteFile(
    h: *anyopaque,
    buf: [*]const u8,
    n: u32,
    written: *u32,
    overlapped: ?*anyopaque,
) callconv(.c) c_int;

extern "kernel32" fn ReadFile(
    h: *anyopaque,
    buf: [*]u8,
    n: u32,
    read_bytes: *u32,
    overlapped: ?*anyopaque,
) callconv(.c) c_int;

extern "kernel32" fn QueryDosDeviceW(
    lp_device_name: [*:0]const u16,
    lp_target_path: ?[*]u16,
    ucch_max: u32,
) callconv(.c) u32;

extern "kernel32" fn GetCommState(h: *anyopaque, dcb: *DCB) callconv(.c) c_int;
extern "kernel32" fn SetCommState(h: *anyopaque, dcb: *const DCB) callconv(.c) c_int;
extern "kernel32" fn SetCommTimeouts(h: *anyopaque, t: *const COMMTIMEOUTS) callconv(.c) c_int;

/// `DCB` from `winbase.h`. The fourteen bit-field flags are collapsed into one
/// `u32`: the layout is identical, and the bridge only ever flips `fBinary`
/// (bit 0), which `GetCommState` already reports correctly.
const DCB = extern struct {
    DCBlength: u32 = 0,
    BaudRate: u32 = 0,
    flags: u32 = 0,
    wReserved: u16 = 0,
    XonLim: u16 = 0,
    XoffLim: u16 = 0,
    ByteSize: u8 = 0,
    Parity: u8 = 0,
    StopBits: u8 = 0,
    XonChar: u8 = 0,
    XoffChar: u8 = 0,
    ErrorChar: u8 = 0,
    EofChar: u8 = 0,
    EvtChar: u8 = 0,
    wReserved1: u16 = 0,
};

const COMMTIMEOUTS = extern struct {
    ReadIntervalTimeout: u32,
    ReadTotalTimeoutMultiplier: u32,
    ReadTotalTimeoutConstant: u32,
    WriteTotalTimeoutMultiplier: u32,
    WriteTotalTimeoutConstant: u32,
};

fn parseId(raw: []const u8) !u32 {
    if (raw.len == 0) return BridgeError.MissingData;
    return std.fmt.parseInt(u32, raw, 10) catch BridgeError.InvalidParameter;
}
