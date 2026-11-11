//! Single-instance activation, relaunch, and file-drop delivery for the
//! Windows and Linux desktop bridges.
//!
//! Everything here is the part that is the same on both platforms: what a
//! second launch sends to the first, the script that hands it to the page,
//! and the command line a relaunch runs. How the bytes cross between two
//! processes (a `WM_COPYDATA` packet, a GApplication action) is the
//! platform's business.

const std = @import("std");
const builtin = @import("builtin");

pub const max_args = 32;
/// Both transports carry one bounded packet.
pub const max_payload_bytes = 16 * 1024;

// The CLI owns these for the life of the process.
var instance_args: []const []const u8 = &.{};
var single_instance = false;
var original_argv: []const []const u8 = &.{};

/// Record `--single-instance` and the `--instance-arg` values of this launch.
pub fn configure(enabled: bool, args: []const []const u8) void {
    single_instance = enabled;
    instance_args = args;
}

pub fn isSingleInstance() bool {
    return single_instance;
}

pub fn launchArgs() []const []const u8 {
    return instance_args;
}

/// The command line this process was started with, for `relaunch`.
pub fn setOriginalArgv(argv: []const []const u8) void {
    original_argv = argv;
}

pub const Payload = struct {
    args: []const []const u8 = &.{},
    url: ?[]const u8 = null,
};

/// What a second launch forwards: its `--instance-arg` values and its deep
/// link, if it was started by one.
pub fn encode(allocator: std.mem.Allocator, args: []const []const u8, url: ?[]const u8) ![]u8 {
    if (args.len > max_args) return error.TooManyArguments;
    const json = try std.json.Stringify.valueAlloc(allocator, Payload{ .args = args, .url = url }, .{});
    errdefer allocator.free(json);
    if (json.len > max_payload_bytes) return error.PayloadTooLarge;
    return json;
}

/// Validate a forwarded packet. It crossed a process boundary, so it is
/// parsed again here instead of being trusted as the JSON it claims to be.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Payload) {
    if (bytes.len == 0 or bytes.len > max_payload_bytes) return error.InvalidPayload;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidPayload;
    const parsed = std.json.parseFromSlice(Payload, allocator, bytes, .{ .allocate = .alloc_always }) catch
        return error.InvalidPayload;
    errdefer parsed.deinit();
    if (parsed.value.args.len > max_args) return error.InvalidPayload;
    if (parsed.value.url) |url| {
        if (url.len == 0 or std.mem.indexOfScalar(u8, url, 0) != null) return error.InvalidPayload;
    }
    return parsed;
}

/// The script that tells the running page another launch happened.
pub fn secondInstanceScript(allocator: std.mem.Allocator, payload: Payload) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return std.fmt.allocPrint(
        allocator,
        "if (window.__craftDeliverSecondInstance) window.__craftDeliverSecondInstance({s});",
        .{json},
    );
}

/// The script that reports dropped files, in the shape `macos_file_drop.zig`
/// delivers.
pub fn fileDropScript(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, paths, .{});
    defer allocator.free(json);
    return std.fmt.allocPrint(
        allocator,
        "if (window.__craftDeliverFileDrop) window.__craftDeliverFileDrop({s});",
        .{json},
    );
}

// ---------------------------------------------------------------------------
// Relaunch
// ---------------------------------------------------------------------------

/// A launcher that started Craft (an app's own agent or wrapper) names itself
/// here so `craft.app.relaunch()` restarts the whole app and not only the
/// window process. Set by the launcher in Craft's environment; a page cannot
/// change it.
pub const relaunch_executable_env = "CRAFT_RELAUNCH_EXECUTABLE";
/// A JSON array of arguments for that launcher. The literal string `{pid}` in
/// any element is replaced with the exiting Craft process id.
pub const relaunch_args_env = "CRAFT_RELAUNCH_ARGS";
/// Appended to Craft's own command line on a self-relaunch, so the new
/// process waits for the old one before it claims the single-instance name.
pub const wait_flag = "--relaunch-wait-pid";

pub const Command = struct {
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,

    pub fn deinit(self: *Command) void {
        self.arena.deinit();
    }
};

/// Build the command a relaunch runs.
///
/// With a launcher override: that executable and its declared arguments.
/// Otherwise: this process's own command line again, minus any earlier wait
/// flag, plus one naming the process that is about to exit.
pub fn relaunchCommand(
    backing: std.mem.Allocator,
    argv: []const []const u8,
    override_executable: ?[]const u8,
    override_args_json: ?[]const u8,
    pid: u32,
) !Command {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var pid_buffer: [16]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});

    if (override_executable) |executable| {
        if (executable.len == 0) return error.InvalidRelaunchExecutable;
        try out.append(allocator, try allocator.dupe(u8, executable));
        if (override_args_json) |json| {
            if (json.len > 0) {
                const parsed = std.json.parseFromSliceLeaky([]const []const u8, allocator, json, .{}) catch
                    return error.InvalidRelaunchArguments;
                for (parsed) |arg| {
                    try out.append(allocator, try std.mem.replaceOwned(u8, allocator, arg, "{pid}", pid_text));
                }
            }
        }
    } else {
        if (argv.len == 0) return error.MissingExecutable;
        var index: usize = 0;
        while (index < argv.len) : (index += 1) {
            if (std.mem.eql(u8, argv[index], wait_flag)) {
                index += 1;
                continue;
            }
            try out.append(allocator, try allocator.dupe(u8, argv[index]));
        }
        try out.append(allocator, wait_flag);
        try out.append(allocator, try allocator.dupe(u8, pid_text));
    }
    return .{ .arena = arena, .argv = try out.toOwnedSlice(allocator) };
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getpid() c_int;
extern "c" fn kill(pid: c_int, signal: c_int) c_int;
extern "c" fn usleep(microseconds: c_uint) c_int;
extern "kernel32" fn GetCurrentProcessId() callconv(.c) u32;
extern "kernel32" fn OpenProcess(access: u32, inherit: c_int, pid: u32) callconv(.c) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: u32) callconv(.c) u32;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.c) c_int;

fn environment(name: [*:0]const u8) ?[]const u8 {
    const value = getenv(name) orelse return null;
    const text = std.mem.span(value);
    return if (text.len == 0) null else text;
}

pub fn currentPid() u32 {
    if (builtin.os.tag == .windows) return GetCurrentProcessId();
    return @intCast(getpid());
}

/// Start the replacement process. The caller quits afterwards; the child is
/// not waited for and outlives this process.
pub fn spawnRelaunch(allocator: std.mem.Allocator) !void {
    var command = try relaunchCommand(
        allocator,
        original_argv,
        environment(relaunch_executable_env),
        environment(relaunch_args_env),
        currentPid(),
    );
    defer command.deinit();
    const io = @import("io_context.zig").get();
    _ = try std.process.spawn(io, .{
        .argv = command.argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

/// Wait, briefly, for the process that relaunched us to finish exiting. It
/// still holds the single-instance name until it does; without this the new
/// process would forward to the one it is replacing and exit.
pub fn waitForExit(pid: u32) void {
    if (pid == 0) return;
    if (builtin.os.tag == .windows) {
        const synchronize: u32 = 0x00100000;
        const handle = OpenProcess(synchronize, 0, pid) orelse return;
        defer _ = CloseHandle(handle);
        _ = WaitForSingleObject(handle, 10_000);
        return;
    }
    var attempts: usize = 0;
    // Signal 0 probes without signalling. A failure means the process is gone
    // (or was never ours to see), which is the condition being waited for.
    while (attempts < 200 and kill(@intCast(pid), 0) == 0) : (attempts += 1) {
        _ = usleep(50_000);
    }
}

const testing = std.testing;

test "a forwarded launch round-trips its arguments and link" {
    const json = try encode(testing.allocator, &.{ "/tmp/project \"a\"", "--flag" }, "myapp://open/1");
    defer testing.allocator.free(json);
    const parsed = try decode(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.args.len);
    try testing.expectEqualStrings("/tmp/project \"a\"", parsed.value.args[0]);
    try testing.expectEqualStrings("myapp://open/1", parsed.value.url.?);

    const script = try secondInstanceScript(testing.allocator, parsed.value);
    defer testing.allocator.free(script);
    try testing.expectEqualStrings(
        "if (window.__craftDeliverSecondInstance) window.__craftDeliverSecondInstance({\"args\":[\"/tmp/project \\\"a\\\"\",\"--flag\"],\"url\":\"myapp://open/1\"});",
        script,
    );
}

test "a packet that is not the expected JSON is refused" {
    try testing.expectError(error.InvalidPayload, decode(testing.allocator, ""));
    try testing.expectError(error.InvalidPayload, decode(testing.allocator, "window.pwned=true"));
    try testing.expectError(error.InvalidPayload, decode(testing.allocator, "{\"args\":[],\"extra\":1}"));
    try testing.expectError(error.InvalidPayload, decode(testing.allocator, "{\"args\":[],\"url\":\"\"}"));
    try testing.expectError(error.InvalidPayload, decode(testing.allocator, "\xff\xfe"));
    var many: [max_args + 1][]const u8 = undefined;
    for (&many) |*arg| arg.* = "x";
    try testing.expectError(error.TooManyArguments, encode(testing.allocator, &many, null));
}

test "dropped paths are escaped for the page" {
    const script = try fileDropScript(testing.allocator, &.{ "/tmp/a \"b\".txt", "C:\\x\\y" });
    defer testing.allocator.free(script);
    try testing.expectEqualStrings(
        "if (window.__craftDeliverFileDrop) window.__craftDeliverFileDrop([\"/tmp/a \\\"b\\\".txt\",\"C:\\\\x\\\\y\"]);",
        script,
    );
}

test "a self-relaunch repeats the command line and names the exiting process" {
    var command = try relaunchCommand(
        testing.allocator,
        &.{ "/opt/app/craft", "--url", "http://127.0.0.1:1/", wait_flag, "11", "--single-instance" },
        null,
        null,
        4242,
    );
    defer command.deinit();
    const expected = [_][]const u8{ "/opt/app/craft", "--url", "http://127.0.0.1:1/", "--single-instance", wait_flag, "4242" };
    try testing.expectEqual(expected.len, command.argv.len);
    for (expected, command.argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "a launcher override replaces the command and receives the pid it asked for" {
    var command = try relaunchCommand(
        testing.allocator,
        &.{"/opt/app/craft"},
        "/opt/app/launcher",
        "[\"--after-update\",\"--wait={pid}\"]",
        77,
    );
    defer command.deinit();
    try testing.expectEqual(@as(usize, 3), command.argv.len);
    try testing.expectEqualStrings("/opt/app/launcher", command.argv[0]);
    try testing.expectEqualStrings("--wait=77", command.argv[2]);
    try testing.expectError(error.InvalidRelaunchArguments, relaunchCommand(testing.allocator, &.{"x"}, "/l", "{}", 1));
    try testing.expectError(error.MissingExecutable, relaunchCommand(testing.allocator, &.{}, null, null, 1));
}
