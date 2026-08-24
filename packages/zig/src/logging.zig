const std = @import("std");
const builtin = @import("builtin");
const compat_mutex = @import("compat_mutex.zig");
const io_context = @import("io_context.zig");

/// Log levels for Craft logging system
pub const LogLevel = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,
    off = 255,

    pub fn asText(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
            .off => "OFF",
        };
    }

    pub fn asColor(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "\x1b[90m", // Gray
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warn => "\x1b[33m", // Yellow
            .err => "\x1b[31m", // Red
            .fatal => "\x1b[35m", // Magenta
            .off => "",
        };
    }
};

/// Log output target
pub const LogTarget = enum {
    stderr,
    stdout,
    file,
    callback,
    none,
};

/// Configuration for the logger
pub const LogConfig = struct {
    level: LogLevel = if (builtin.mode == .debug) .debug else .info,
    target: LogTarget = .stderr,
    colored: bool = true,
    show_timestamp: bool = true,
    show_module: bool = true,
    show_source: bool = builtin.mode == .debug,
    file_path: ?[]const u8 = null,
    callback: ?*const fn (LogLevel, []const u8, []const u8) void = null,
};

/// Global logger state
var global_config: LogConfig = .{};
var global_file: ?std.Io.File = null;
var global_mutex: compat_mutex.Mutex = .{};

/// Initialize the logging system
pub fn init(config: LogConfig) void {
    global_mutex.lock();
    defer global_mutex.unlock();

    global_config = config;

    if (config.target == .file) {
        if (config.file_path) |path| {
            const io = io_context.get();
            global_file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch null;
        }
    }
}

/// Deinitialize the logging system
pub fn deinit() void {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_file) |f| {
        f.close(io_context.get());
        global_file = null;
    }
}

/// Set the minimum log level
pub fn setLevel(level: LogLevel) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    global_config.level = level;
}

/// Get the current log level
pub fn getLevel() LogLevel {
    return global_config.level;
}

/// Core logging function
fn logInternal(
    level: LogLevel,
    module: []const u8,
    comptime format: []const u8,
    args: anytype,
    src: std.builtin.SourceLocation,
) void {
    // Check if we should log at this level
    if (@backingInt(level) < @backingInt(global_config.level)) {
        return;
    }

    global_mutex.lock();
    defer global_mutex.unlock();

    const config = global_config;

    // Format the message
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Timestamp - use C clock for wall time where available
    if (config.show_timestamp) {
        if (comptime @hasDecl(std.c, "clock_gettime")) {
            var ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
                const secs_total: i64 = ts.sec;
                const hours = @mod(@divFloor(secs_total, 3600), 24);
                const mins = @mod(@divFloor(secs_total, 60), 60);
                const secs = @mod(secs_total, 60);

                const ts_str = std.fmt.bufPrint(buf[pos..], "{d:0>2}:{d:0>2}:{d:0>2} ", .{
                    @as(u64, @intCast(hours)),
                    @as(u64, @intCast(mins)),
                    @as(u64, @intCast(secs)),
                }) catch return;
                pos += ts_str.len;
            }
        }
    }

    // Color start. Use memcpy via slice assignment so a long prefix can't run
    // off the end of `buf` — previously this blindly wrote `color.len` bytes
    // with no `pos + color.len <= buf.len` check.
    if (config.colored and config.target != .file) {
        const color = level.asColor();
        if (pos + color.len > buf.len) return;
        @memcpy(buf[pos .. pos + color.len], color);
        pos += color.len;
    }

    // Level
    const level_str = std.fmt.bufPrint(buf[pos..], "[{s}] ", .{level.asText()}) catch return;
    pos += level_str.len;

    // Color reset
    if (config.colored and config.target != .file) {
        const reset = "\x1b[0m";
        if (pos + reset.len > buf.len) return;
        @memcpy(buf[pos .. pos + reset.len], reset);
        pos += reset.len;
    }

    // Module
    if (config.show_module and module.len > 0) {
        const mod_str = std.fmt.bufPrint(buf[pos..], "[{s}] ", .{module}) catch return;
        pos += mod_str.len;
    }

    // Message
    const msg = std.fmt.bufPrint(buf[pos..], format, args) catch return;
    pos += msg.len;

    // Source location (debug only)
    if (config.show_source) {
        const src_str = std.fmt.bufPrint(buf[pos..], " ({s}:{d})", .{ src.file, src.line }) catch return;
        pos += src_str.len;
    }

    // Newline — bail out if we're already at the edge rather than writing
    // one byte past the buffer.
    if (pos >= buf.len) return;
    buf[pos] = '\n';
    pos += 1;

    // Output
    const io = io_context.get();
    switch (config.target) {
        .stderr => {
            std.Io.File.stderr().writeStreamingAll(io, buf[0..pos]) catch |write_err| {
                // Cannot use logging here to avoid recursion; use debug print as fallback
                std.debug.print("logging: stderr write failed: {}\n", .{write_err});
            };
        },
        .stdout => {
            std.Io.File.stdout().writeStreamingAll(io, buf[0..pos]) catch |write_err| {
                std.debug.print("logging: stdout write failed: {}\n", .{write_err});
            };
        },
        .file => {
            if (global_file) |f| {
                f.writeStreamingAll(io_context.get(), buf[0..pos]) catch |write_err| {
                    std.debug.print("logging: file write failed: {}\n", .{write_err});
                };
            }
        },
        .callback => {
            if (config.callback) |cb| {
                cb(level, module, buf[0..pos]);
            }
        },
        .none => {},
    }
}

/// Module-scoped logger for cleaner API
pub fn scoped(comptime module: []const u8) type {
    return struct {
        pub fn trace(comptime format: []const u8, args: anytype) void {
            logInternal(.trace, module, format, args, @src());
        }

        pub fn debug(comptime format: []const u8, args: anytype) void {
            logInternal(.debug, module, format, args, @src());
        }

        pub fn info(comptime format: []const u8, args: anytype) void {
            logInternal(.info, module, format, args, @src());
        }

        pub fn warn(comptime format: []const u8, args: anytype) void {
            logInternal(.warn, module, format, args, @src());
        }

        pub fn err(comptime format: []const u8, args: anytype) void {
            logInternal(.err, module, format, args, @src());
        }

        pub fn fatal(comptime format: []const u8, args: anytype) void {
            logInternal(.fatal, module, format, args, @src());
        }
    };
}

// Convenience functions for unscoped logging

pub fn trace(comptime format: []const u8, args: anytype) void {
    logInternal(.trace, "", format, args, @src());
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    logInternal(.debug, "", format, args, @src());
}

pub fn info(comptime format: []const u8, args: anytype) void {
    logInternal(.info, "", format, args, @src());
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    logInternal(.warn, "", format, args, @src());
}

pub fn err(comptime format: []const u8, args: anytype) void {
    logInternal(.err, "", format, args, @src());
}

pub fn fatal(comptime format: []const u8, args: anytype) void {
    logInternal(.fatal, "", format, args, @src());
}

// ============================================
// Pre-defined module loggers for Craft bridges
// ============================================

pub const bridge = scoped("Bridge");
pub const dialog = scoped("Dialog");
pub const clipboard = scoped("Clipboard");
pub const notification = scoped("Notification");
pub const menu = scoped("Menu");
pub const tray = scoped("Tray");
pub const fs = scoped("FS");
pub const network = scoped("Network");
pub const power = scoped("Power");
pub const window = scoped("Window");
pub const system = scoped("System");
pub const webview = scoped("WebView");
pub const marketplace = scoped("Marketplace");
pub const shortcuts = scoped("Shortcuts");
pub const prefs = scoped("Prefs");

// ============================================
// Tests
// ============================================

test "log level ordering" {
    try std.testing.expect(@backingInt(LogLevel.trace) < @backingInt(LogLevel.debug));
    try std.testing.expect(@backingInt(LogLevel.debug) < @backingInt(LogLevel.info));
    try std.testing.expect(@backingInt(LogLevel.info) < @backingInt(LogLevel.warn));
    try std.testing.expect(@backingInt(LogLevel.warn) < @backingInt(LogLevel.err));
    try std.testing.expect(@backingInt(LogLevel.err) < @backingInt(LogLevel.fatal));
}

test "scoped logger" {
    const myLog = scoped("TestModule");
    // Just verify it compiles - actual output would go to stderr
    _ = myLog;
}

test "log level text" {
    try std.testing.expectEqualStrings("DEBUG", LogLevel.debug.asText());
    try std.testing.expectEqualStrings("ERROR", LogLevel.err.asText());
}
