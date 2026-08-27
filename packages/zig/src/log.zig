const std = @import("std");
const builtin = @import("builtin");
const io_context = @import("io_context.zig");
const compat_mutex = @import("compat_mutex.zig");

pub const LogLevel = enum {
    Debug,
    Info,
    Warning,
    Error,
    Fatal,
    /// Record nothing.
    ///
    /// Last, so the existing `level >= min_level` comparison silences
    /// everything when it is the minimum — no branch anywhere else has to know
    /// about it. `logging.zig` has had an `off` for as long as it has existed;
    /// this side had no way to say the same thing, so an app that wanted
    /// quiet had to not configure logging at all, which is not the same as
    /// asking for it.
    Off,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .Debug => "DEBUG",
            .Info => "INFO",
            .Warning => "WARN",
            .Error => "ERROR",
            .Fatal => "FATAL",
            .Off => "OFF",
        };
    }

    pub fn color(self: LogLevel) []const u8 {
        return switch (self) {
            .Debug => "\x1B[36m", // Cyan
            .Info => "\x1B[32m", // Green
            .Warning => "\x1B[33m", // Yellow
            .Error => "\x1B[31m", // Red
            .Fatal => "\x1B[35m", // Magenta
            // Never emitted; a record at this level is filtered before formatting.
            .Off => "",
        };
    }
};

pub const LogConfig = struct {
    min_level: LogLevel = .Info,
    enable_colors: bool = true,
    enable_timestamps: bool = true,
    output_file: ?[]const u8 = null,
    json_output: bool = false,
    /// Also write every record to stderr.
    ///
    /// On by default, which is what this logger has always done. A caller that
    /// wants a file and a quiet terminal — a packaged app, a headless run —
    /// had no way to ask, because the stderr write was unconditional.
    mirror_to_stderr: bool = true,
    filter_pattern: ?[]const u8 = null,
};

var current_config: LogConfig = .{};
var log_file: ?std.Io.File = null;

/// Where the next record goes.
///
/// `Io.Dir.CreateFileOptions` has no append flag in this Zig, and
/// `writeStreamingAll` starts at position zero — so an existing log was
/// overwritten from the beginning on every run, leaving whatever was longer
/// than the new content stranded past the end as garbage. Seeded from the
/// file's size at open and advanced by every write, with `writePositionalAll`,
/// which is how appending is spelled here.
var log_file_offset: u64 = 0;

/// Storage for the configuration's strings.
///
/// `LogConfig` carries `output_file` and `filter_pattern` as slices, and
/// `init` used to keep the caller's. The path arrives from the command line
/// and `minimal.zig` frees those strings during startup, so retaining them
/// would leave this module reading freed memory on the first log call after
/// argument parsing finished — a use-after-free that arrives only once
/// something actually configures the logger, which nothing did until now.
var output_file_storage: [std.fs.max_path_bytes]u8 = undefined;
var filter_storage: [256]u8 = undefined;
/// Guards `current_config`, `log_file`, and the final write to stderr+file
/// so concurrent loggers don't interleave bytes or race on config updates.
/// The previous module-level `var`s were read/written from every call site
/// without any synchronization.
var log_mutex: compat_mutex.Mutex = .{};

/// True while this thread is inside `log`.
///
/// `compat_mutex` falls back to a spinlock when `std.Thread.Mutex` is absent,
/// and it is absent in this Zig — so the lock is non-recursive and never
/// yields. A `std.log` call made from inside `log` would spin against a lock
/// this thread already holds, forever: a hard hang with no panic and no
/// stack. That was unreachable while nothing configured the logger, and
/// routing every `std.log` site through it is exactly what makes it reachable.
///
/// Dropping the inner record is the right trade. The alternative is a process
/// that stops responding because something logged while logging.
threadlocal var in_log: bool = false;

/// The `Io` to write through, captured at `init`.
///
/// `io_context.get()` takes `global_state`'s own non-recursive spinlock, and
/// `log` used to call it while holding `log_mutex` — two spinlocks nested in a
/// fixed order, and a lazy `std.Io.Threaded` construction on the C allocator
/// reachable from inside a log call. Captured once instead.
var log_io: ?std.Io = null;

/// Whether stderr is a terminal, decided once at `init`.
///
/// Per-record would mean an `isatty` on every line, and the answer cannot
/// change for a running process anyway.
var stderr_is_tty: bool = false;

pub fn init(config: LogConfig) !void {
    log_mutex.lock();
    defer log_mutex.unlock();

    // Close any previously opened log file. Previously, calling `init` twice
    // would overwrite `log_file` and silently leak the old file handle.
    if (log_file) |f| {
        f.close(io_context.get());
        log_file = null;
    }

    current_config = config;
    log_file_offset = 0;
    log_io = io_context.get();
    stderr_is_tty = std.Io.File.stderr().isTty(log_io.?) catch false;

    // Take copies before anything else can free the originals.
    if (config.output_file) |path| {
        if (path.len > output_file_storage.len) return error.NameTooLong;
        @memcpy(output_file_storage[0..path.len], path);
        current_config.output_file = output_file_storage[0..path.len];
    }
    if (config.filter_pattern) |pattern| {
        if (pattern.len > filter_storage.len) return error.NameTooLong;
        @memcpy(filter_storage[0..pattern.len], pattern);
        current_config.filter_pattern = filter_storage[0..pattern.len];
    }

    if (current_config.output_file) |path| {
        const io = io_context.get();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
            .read = true,
        });
        // Append rather than overwrite: a log that starts again from byte zero
        // on every launch loses the run that diagnosed the problem.
        const existing = file.stat(io) catch |stat_err| {
            file.close(io);
            return stat_err;
        };
        log_file_offset = existing.size;
        log_file = file;
    }
}

pub fn deinit() void {
    log_mutex.lock();
    defer log_mutex.unlock();
    if (log_file) |file| {
        file.close(io_context.get());
        log_file = null;
    }
}

pub fn setLevel(level: LogLevel) void {
    log_mutex.lock();
    defer log_mutex.unlock();
    current_config.min_level = level;
}

pub fn getLevel() LogLevel {
    log_mutex.lock();
    defer log_mutex.unlock();
    return current_config.min_level;
}

pub fn shouldLog(level: LogLevel) bool {
    log_mutex.lock();
    defer log_mutex.unlock();
    return @backingInt(level) >= @backingInt(current_config.min_level);
}

/// Internal, lock-free variant used by `log()` while it already holds
/// `log_mutex`. Keeping the public `shouldLog` locked means callers that
/// call it outside `log()` still observe consistent state.
fn shouldLogLocked(level: LogLevel) bool {
    return @backingInt(level) >= @backingInt(current_config.min_level);
}

/// `std.fmt.bufPrint` that clips instead of failing.
///
/// Returns as much of the formatted text as fits, ending with a marker so a
/// reader can tell the difference between a short message and a clipped one.
/// The alternative — what this code did before — was to return nothing at all
/// and log no record, silently.
fn formatTruncating(buf: []u8, comptime format: []const u8, args: anytype) []const u8 {
    if (std.fmt.bufPrint(buf, format, args)) |written| {
        return written;
    } else |_| {}

    const marker = "…[truncated]";
    if (buf.len <= marker.len) return buf[0..0];

    // Re-format into the space that is left, then stamp the marker on the end.
    // A second failure means even the clipped form does not fit, so keep
    // whatever was written and mark it.
    const room = buf.len - marker.len;
    var written_len: usize = room;
    if (std.fmt.bufPrint(buf[0..room], format, args)) |written| {
        written_len = written.len;
    } else |_| {}
    @memcpy(buf[written_len..][0..marker.len], marker);
    return buf[0 .. written_len + marker.len];
}

pub fn log(
    comptime level: LogLevel,
    comptime format: []const u8,
    args: anytype,
) void {
    // Single lock acquisition for the whole emission path: level check,
    // config/filter read, formatting, and the stderr+file write. This
    // prevents stderr interleaving between threads and makes config
    // updates atomic with emission. Previously every call touched
    // `current_config` and `log_file` unsynchronized.
    // Before the lock, not after: the point is to never reach a lock this
    // thread already holds.
    if (in_log) return;
    in_log = true;
    defer in_log = false;

    log_mutex.lock();
    defer log_mutex.unlock();

    if (!shouldLogLocked(level)) return;

    // Format the message, truncating rather than dropping it.
    //
    // This was `bufPrint(...) catch return`, which discarded the whole record
    // when it did not fit — so the longest messages, which are usually the
    // ones worth reading, were the only ones guaranteed to be missing. A log
    // that silently omits its biggest entries is worse than one that clips
    // them, because nothing indicates anything was lost.
    var msg_buf: [2048]u8 = undefined;
    const message = formatTruncating(&msg_buf, format, args);

    // Apply filter if configured
    if (current_config.filter_pattern) |pattern| {
        if (std.mem.indexOf(u8, message, pattern) == null) {
            return; // Skip messages that don't match filter
        }
    }

    var output_buf: [4096]u8 = undefined;
    var output_len: usize = 0;

    // Each call owns its own timestamp buffer — safe for concurrent logging.
    var ts_buf: [timestamp_len]u8 = undefined;
    const timestamp = formatTimestamp(&ts_buf);

    if (current_config.json_output) {
        // JSON output — escape the message so that quotes, newlines, and
        // backslashes don't produce invalid JSON. Previously a message like
        // `foo "bar"\nbaz` would corrupt every log consumer parsing the stream.
        var esc_buf: [4096]u8 = undefined;
        var esc_len: usize = 0;
        var i: usize = 0;
        while (i < message.len) {
            const c = message[i];

            // Anything outside ASCII is walked as a UTF-8 sequence rather than
            // byte by byte. Passing high bytes through individually is what
            // the previous loop did, and a message carrying invalid UTF-8 — a
            // filename, a truncated IPC frame — then produced a line that
            // `JSON.parse` rejects. A log format that a bad byte can make
            // unreadable is not a structured log format.
            if (c >= 0x80) {
                const seq_len = std.unicode.utf8ByteSequenceLength(c) catch 0;
                const valid = seq_len > 0 and i + seq_len <= message.len and
                    std.unicode.utf8ValidateSlice(message[i..][0..seq_len]);
                const chunk: []const u8 = if (valid) message[i..][0..seq_len] else "\\ufffd";
                if (esc_len + chunk.len > esc_buf.len) break;
                @memcpy(esc_buf[esc_len..][0..chunk.len], chunk);
                esc_len += chunk.len;
                i += if (valid) seq_len else 1;
                continue;
            }

            i += 1;
            const esc: []const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => blk: {
                    var hex: [6]u8 = undefined;
                    const slice = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}) catch break :blk "";
                    if (esc_len + slice.len > esc_buf.len) break :blk "";
                    @memcpy(esc_buf[esc_len..][0..slice.len], slice);
                    esc_len += slice.len;
                    break :blk "";
                },
                else => &[_]u8{c},
            };
            if (esc.len == 0) continue;
            if (esc_len + esc.len > esc_buf.len) break;
            @memcpy(esc_buf[esc_len..][0..esc.len], esc);
            esc_len += esc.len;
        }

        output_len = formatTruncating(&output_buf, "{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"message\":\"{s}\"}}\n", .{ timestamp, level.toString(), esc_buf[0..esc_len] }).len;
    } else if (current_config.enable_timestamps) {
        output_len = formatTruncating(&output_buf, "[{s}] {s} {s}\n", .{ timestamp, level.toString(), message }).len;
    } else {
        output_len = formatTruncating(&output_buf, "{s} {s}\n", .{ level.toString(), message }).len;
    }

    const output = output_buf[0..output_len];

    // Colour is formatted separately, for stderr only.
    //
    // Both sinks used to receive the same bytes, so a run with `--log-file`
    // either put ANSI escapes in the file or — the workaround this replaces —
    // turned colour off for the terminal as well, to keep the file clean. A
    // log file full of `\x1b[2m` is unreadable to `grep`, and a terminal that
    // loses its colours because a file was requested is a strange trade.
    //
    // Only when stderr is a terminal, decided once at `init` rather than per
    // record: colour written into a redirected stderr is the same problem as
    // colour written into the file.
    var colour_buf: [4096]u8 = undefined;
    var colour_len: usize = 0;
    if (current_config.enable_colors and stderr_is_tty and !current_config.json_output) {
        const reset = "\x1B[0m";
        const dim = "\x1B[2m";
        colour_len = if (current_config.enable_timestamps)
            formatTruncating(&colour_buf, "{s}[{s}]{s} {s}{s}{s} {s}\n", .{ dim, timestamp, reset, level.color(), level.toString(), reset, message }).len
        else
            formatTruncating(&colour_buf, "{s}{s}{s} {s}\n", .{ level.color(), level.toString(), reset, message }).len;
    }

    const io = log_io orelse io_context.get();

    if (current_config.mirror_to_stderr) {
        const for_stderr = if (colour_len > 0) colour_buf[0..colour_len] else output;
        _ = std.Io.File.stderr().writeStreamingAll(io, for_stderr) catch {};
    }

    // Appended at the tracked offset. `writeStreamingAll` writes from position
    // zero, which overwrote the previous run in place.
    if (log_file) |file| {
        file.writePositionalAll(io, output, log_file_offset) catch return;
        log_file_offset += output.len;
    }
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    log(.Debug, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    log(.Info, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    log(.Warning, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    log(.Error, format, args);
}

pub fn fatal(comptime format: []const u8, args: anytype) void {
    log(.Fatal, format, args);
}

/// Format an HH:MM:SS **local** timestamp into the caller-provided buffer.
/// Returning a slice into the caller's buffer avoids the previous
/// thread-unsafe shared static buffer. Uses `localtime_r` so developers
/// reading live logs see their own wall-clock time instead of raw UTC.
/// `ts.sec` values below zero are clamped to 0 so pre-1970 clocks (e.g.
/// a VM booting with no RTC) can't panic in `@intCast`.
/// An ISO-8601 UTC timestamp: `YYYY-MM-DDTHH:MM:SSZ`.
///
/// This used to emit `HH:MM:SS` and nothing else, which is fine for watching a
/// terminal and useless for the thing `--log-file` exists to produce: a trail
/// you read afterwards, possibly days afterwards, to work out what a
/// long-running app did. A time with no date cannot answer that.
///
/// UTC rather than local. The previous comment claimed it used `localtime_r`;
/// the body did modular arithmetic on the epoch and left a dead `_ = t;`
/// behind. `localtime_r` is not declared in `std.c` in this Zig, so honouring
/// that comment would mean declaring the extern — and a log shared between a
/// machine and whoever reads it later is better off unambiguous anyway.
fn formatTimestamp(buf: *[timestamp_len]u8) []const u8 {
    const fallback = "0000-00-00T00:00:00Z";

    // `compat.timestamp` rather than `std.c.clock_gettime`: the latter does not
    // compile for Windows in this Zig, and this file only ever built because
    // nothing instantiated `log` — wiring every std.log site through it is
    // what made the Windows path get analysed for the first time.
    const secs = @import("compat.zig").timestamp();
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    const day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = epoch_seconds.getDaySeconds();

    const written = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    }) catch {
        @memcpy(buf, fallback);
        return buf[0..];
    };
    return written;
}

/// Width of `YYYY-MM-DDTHH:MM:SSZ`.
const timestamp_len = 20;

// =============================================================================
// Tests
// =============================================================================
//
// This module had none. It was written complete — levels, JSON, a filter, a
// mutex, file output — and then never configured by anything, so every path
// below the default was unexercised. Wiring `--log-file` in front of it
// without first running it would have been the same mistake the rest of this
// codebase keeps making: shipping code that looks right and has never run.

const testing = std.testing;

fn resetInLogForTesting() void {
    in_log = false;
}

test "a message longer than the buffer is clipped, not discarded" {
    // The defect: `bufPrint(...) catch return` dropped the entire record when
    // it did not fit, so the longest messages — usually the interesting ones —
    // were the only ones certain to be missing, with nothing to say so.
    var buf: [64]u8 = undefined;
    var long: [500]u8 = undefined;
    @memset(&long, 'x');

    const out = formatTruncating(&buf, "{s}", .{long});
    try testing.expect(out.len > 0);
    try testing.expect(out.len <= buf.len);
    try testing.expect(std.mem.endsWith(u8, out, "…[truncated]"));
}

test "a message that fits is untouched" {
    var buf: [64]u8 = undefined;
    const out = formatTruncating(&buf, "hello {s}", .{"world"});
    try testing.expectEqualStrings("hello world", out);
}

test "a buffer too small even for the marker yields nothing rather than corrupting it" {
    var buf: [4]u8 = undefined;
    const out = formatTruncating(&buf, "{s}", .{"much longer than four"});
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "the configuration's strings are copied, not borrowed" {
    // `init` stored the caller's slices, and `minimal.zig` frees the
    // command-line strings during startup — so the first log call after
    // argument parsing would have read freed memory. Nothing had configured
    // the logger before, which is the only reason it never happened.
    var path_buf: [64]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&path_buf, "{s}", .{"craft-log-borrow-test.txt"});

    try init(.{ .output_file = scratch, .filter_pattern = "keepme", .mirror_to_stderr = false });
    defer {
        deinit();
        std.Io.Dir.cwd().deleteFile(io_context.get(), "craft-log-borrow-test.txt") catch {};
    }

    // Scribble over the caller's buffer. A borrowed slice would now be garbage.
    @memset(&path_buf, '!');

    try testing.expectEqualStrings("craft-log-borrow-test.txt", current_config.output_file.?);
    try testing.expectEqualStrings("keepme", current_config.filter_pattern.?);
}

test "a second run appends instead of overwriting the first" {
    // `Io.Dir.CreateFileOptions` has no append flag and `writeStreamingAll`
    // starts at position zero, so every run rewrote the file from the
    // beginning — losing the run that diagnosed the problem and leaving any
    // longer previous content stranded past the end.
    const io = io_context.get();
    const path = "craft-log-append-test.txt";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try init(.{
        .output_file = path,
        .min_level = .Debug,
        .enable_colors = false,
        .enable_timestamps = false,
        .mirror_to_stderr = false,
    });
    log(.Info, "first run {d}", .{1});
    deinit();

    try init(.{
        .output_file = path,
        .min_level = .Debug,
        .enable_colors = false,
        .enable_timestamps = false,
        .mirror_to_stderr = false,
    });
    log(.Info, "second run {d}", .{2});
    deinit();

    var read_buf: [4096]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &read_buf, 0);
    const contents = read_buf[0..n];

    // Both runs are present, and in order.
    const first = std.mem.indexOf(u8, contents, "first run 1") orelse return error.FirstRunLost;
    const second = std.mem.indexOf(u8, contents, "second run 2") orelse return error.SecondRunLost;
    try testing.expect(first < second);
}

test "the level filter keeps quiet records out of the file" {
    const io = io_context.get();
    const path = "craft-log-level-test.txt";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try init(.{
        .output_file = path,
        .min_level = .Warning,
        .enable_colors = false,
        .enable_timestamps = false,
        .mirror_to_stderr = false,
    });
    log(.Debug, "quiet", .{});
    log(.Info, "also quiet", .{});
    log(.Warning, "loud", .{});
    deinit();

    var read_buf: [4096]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &read_buf, 0);
    const contents = read_buf[0..n];

    try testing.expect(std.mem.indexOf(u8, contents, "loud") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "quiet") == null);
}

test "json output stays parseable when the message fights back" {
    const io = io_context.get();
    const path = "craft-log-json-test.txt";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try init(.{
        .output_file = path,
        .min_level = .Debug,
        .json_output = true,
        .mirror_to_stderr = false,
    });
    log(.Error, "he said {s} then a newline{s}and a tab{s}", .{ "\"hi\"", "\n", "\t" });
    deinit();

    var read_buf: [4096]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &read_buf, 0);
    const line = std.mem.trimEnd(u8, read_buf[0..n], "\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ERROR", parsed.value.object.get("level").?.string);
    const msg = parsed.value.object.get("message").?.string;
    try testing.expect(std.mem.indexOf(u8, msg, "\"hi\"") != null);
}

test "mirroring to stderr can be turned off without losing the file" {
    // The stderr write was unconditional, so a packaged or headless app could
    // not ask for a file and a quiet terminal.
    const io = io_context.get();
    const path = "craft-log-quiet-test.txt";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try init(.{
        .output_file = path,
        .min_level = .Debug,
        .enable_colors = false,
        .enable_timestamps = false,
        .mirror_to_stderr = false,
    });
    log(.Info, "written to the file only", .{});
    deinit();

    var read_buf: [1024]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &read_buf, 0);
    try testing.expect(std.mem.indexOf(u8, read_buf[0..n], "written to the file only") != null);
}

test "re-initialising closes the previous file rather than leaking it" {
    const io = io_context.get();
    const a = "craft-log-reinit-a.txt";
    const b = "craft-log-reinit-b.txt";
    defer std.Io.Dir.cwd().deleteFile(io, a) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, b) catch {};

    try init(.{ .output_file = a, .mirror_to_stderr = false });
    try init(.{ .output_file = b, .mirror_to_stderr = false });
    try testing.expectEqualStrings(b, current_config.output_file.?);
    deinit();
    try testing.expect(log_file == null);
}

test "json survives a message that is not valid UTF-8" {
    // A filename, a truncated IPC frame, any raw byte over 0x7f: these used to
    // be copied into the JSON string verbatim, producing a line that
    // `JSON.parse` rejects. A structured log a single bad byte can make
    // unreadable is not structured.
    const io = io_context.get();
    const path = "craft-log-utf8-test.txt";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try init(.{
        .output_file = path,
        .min_level = .Debug,
        .json_output = true,
        .mirror_to_stderr = false,
    });
    // 0xFF is never valid UTF-8; the é is, and must survive intact.
    log(.Warning, "bad byte {s} and caf\xc3\xa9", .{"\xff\xfe"});
    deinit();

    var read_buf: [4096]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &read_buf, 0);
    const line = std.mem.trimEnd(u8, read_buf[0..n], "\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const msg = parsed.value.object.get("message").?.string;
    try testing.expect(std.mem.indexOf(u8, msg, "café") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "\u{fffd}") != null);
}

test "a timestamp carries the date, not just the time" {
    // `--log-file` produces a trail read afterwards, sometimes days
    // afterwards. `HH:MM:SS` alone cannot say which day.
    var buf: [timestamp_len]u8 = undefined;
    const ts = formatTimestamp(&buf);
    try testing.expectEqual(timestamp_len, ts.len);
    try testing.expectEqual(@as(u8, '-'), ts[4]);
    try testing.expectEqual(@as(u8, '-'), ts[7]);
    try testing.expectEqual(@as(u8, 'T'), ts[10]);
    try testing.expectEqual(@as(u8, 'Z'), ts[timestamp_len - 1]);
    // A plausible year rather than the epoch fallback.
    const year = try std.fmt.parseInt(u16, ts[0..4], 10);
    try testing.expect(year >= 2020);
}

test "logging from inside logging drops the inner record instead of hanging" {
    // `compat_mutex` is a non-recursive spinlock here — `std.Thread.Mutex`
    // does not exist in this Zig — so a reentrant call would spin against a
    // lock this thread already holds, forever. Routing every std.log site
    // through this module is what made that reachable.
    resetInLogForTesting();
    try testing.expect(!in_log);

    in_log = true;
    // Would deadlock without the guard; returns immediately with it.
    log(.Error, "reentrant", .{});
    try testing.expect(in_log);

    resetInLogForTesting();
    try testing.expect(!in_log);
}

test "off silences every level" {
    // `logging.zig` has always had an `off`; this side had no way to say the
    // same thing, so an app that wanted quiet had to not configure logging at
    // all — which is not the same as asking for it.
    const io = io_context.get();
    const path = "craft-log-off-test.txt";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try init(.{ .output_file = path, .min_level = .Off, .mirror_to_stderr = false });
    log(.Debug, "no", .{});
    log(.Info, "no", .{});
    log(.Warning, "no", .{});
    log(.Error, "no", .{});
    log(.Fatal, "not even this", .{});
    deinit();

    var read_buf: [256]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &read_buf, 0);
    try testing.expectEqual(@as(usize, 0), n);
}

test "off is the highest level, so the ordering check silences by itself" {
    // Placed last in the enum on purpose: `level >= min_level` then does the
    // work and no other branch has to know the concept exists.
    const values = std.enums.values(LogLevel);
    try testing.expectEqual(LogLevel.Off, values[values.len - 1]);
    for (values) |level| {
        if (level == .Off) continue;
        try testing.expect(@backingInt(level) < @backingInt(LogLevel.Off));
    }
}

test "the file never receives colour, even when the terminal is getting it" {
    // Both sinks used to be handed the same bytes, so a run with --log-file
    // either wrote ANSI escapes into the file or turned colour off for the
    // terminal too. A log full of \x1b[2m is unreadable to grep.
    //
    // `stderr_is_tty` is forced, because a test process is piped and would
    // otherwise produce no coloured line at all — the first version of this
    // test passed against a deliberately reverted fix for exactly that reason.
    const io = io_context.get();
    const path = "craft-log-colour-test.txt";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try init(.{
        .output_file = path,
        .min_level = .Debug,
        .enable_colors = true, // asked for, and still must not reach the file
        .mirror_to_stderr = false,
    });
    stderr_is_tty = true; // after init, which computes it
    defer stderr_is_tty = false;
    log(.Error, "a red line on a terminal", .{});
    deinit();

    var read_buf: [1024]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &read_buf, 0);
    const contents = read_buf[0..n];

    try testing.expect(std.mem.indexOf(u8, contents, "a red line on a terminal") != null);
    try testing.expect(std.mem.indexOfScalar(u8, contents, 0x1B) == null);
}
