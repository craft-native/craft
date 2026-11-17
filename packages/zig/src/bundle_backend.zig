//! A bundled backend is a child of the native UI host. Craft must own AppKit
//! and Powerbox access; an inherited sandbox helper cannot register a UI app.
const std = @import("std");
const builtin = @import("builtin");
const io_context = @import("io_context.zig");
const backend_lifecycle = @import("backend_lifecycle.zig");
const security_scope = @import("security_scope.zig");

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
extern "c" fn poll(fds: [*]PollFd, count: c_uint, timeout_ms: c_int) c_int;

pub fn validHelperName(name: []const u8) bool {
    return name.len > 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\\") == null;
}

pub fn validSessionUrl(url: []const u8) bool {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    for (rest[0..slash]) |c| if (!std.ascii.isDigit(c)) return false;
    const port = std.fmt.parseInt(u16, rest[0..slash], 10) catch return false;
    if (port == 0 or !std.mem.startsWith(u8, rest[slash..], "/?session=")) return false;
    const token = rest[slash + "/?session=".len ..];
    if (token.len == 0 or token.len > 256) return false;
    for (token) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

pub const Host = struct {
    allocator: std.mem.Allocator,
    process: std.process.Child,
    input: std.Io.File,
    output: std.Io.File,
    drainer: ?std.Thread,
    url: []const u8,

    pub fn start(allocator: std.mem.Allocator, executable_directory: []const u8, name: []const u8) !Host {
        if (comptime builtin.os.tag != .macos) return error.UnsupportedPlatform;
        if (!validHelperName(name)) return error.InvalidBackendExecutable;
        const io = io_context.get();
        const path = try std.fs.path.join(allocator, &.{ executable_directory, name });
        defer allocator.free(path);
        // The live environment, not the snapshot taken at startup, plus the
        // folders this process holds open for the backend to inherit.
        var environment = try currentEnvironment(allocator);
        defer environment.deinit();
        const granted = try security_scope.joinedPaths(allocator);
        defer allocator.free(granted);
        if (granted.len > 0) {
            try environment.put(security_scope.env_key, granted);
        } else {
            _ = environment.swapRemove(security_scope.env_key);
        }
        var child = try std.process.spawn(io, .{
            .argv = &.{ path, "--serve", "--managed" },
            .cwd = .{ .path = executable_directory },
            .environ_map = &environment,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer {
            // The pinned std.process.Child.kill reaps the child and clears
            // its id. Calling wait afterwards asserts, hiding startup errors.
            child.kill(io);
        }
        const input = child.stdin orelse return error.MissingBackendPipe;
        const output = child.stdout orelse return error.MissingBackendPipe;
        // Host owns these pipes; waiting on Child must not close a descriptor
        // while the log drainer still uses it.
        child.stdin = null;
        child.stdout = null;
        errdefer input.close(io);
        errdefer output.close(io);
        const url = try readSessionUrl(allocator, output, 15_000);
        errdefer allocator.free(url);
        const drainer = try std.Thread.spawn(.{}, drain, .{output});
        return .{ .allocator = allocator, .process = child, .input = input, .output = output, .drainer = drainer, .url = url };
    }

    pub fn stop(self: *Host) void {
        const io = io_context.get();
        self.input.close(io);
        // EOF lets the backend flush local state. Bound the grace period so a
        // broken helper cannot keep the application alive indefinitely.
        _ = backend_lifecycle.waitForExit(&self.process, io, .fromSeconds(3));
        self.process.kill(io);
        if (self.drainer) |thread| thread.join();
        self.output.close(io);
        self.allocator.free(self.url);
        self.* = undefined;
    }
};

fn currentEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const pair = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (eq == 0) continue;
        try map.put(pair[0..eq], pair[eq + 1 ..]);
    }
    return map;
}

/// The one backend a bundled app runs, owned here so a bridge action can
/// restart it. `start` and `stop` bracket the app's lifetime in `minimal.zig`.
var managed: ?Host = null;
var managed_allocator: std.mem.Allocator = undefined;
var managed_directory: []u8 = &.{};
var managed_name: []u8 = &.{};

/// Start the app's backend after reopening the folders the person granted, so
/// it inherits access to them. Returns its session URL, owned by this module.
pub fn startManaged(allocator: std.mem.Allocator, executable_directory: []const u8, name: []const u8) ![]const u8 {
    if (managed != null) return error.BackendAlreadyRunning;
    security_scope.restore();
    managed_allocator = allocator;
    managed_directory = try allocator.dupe(u8, executable_directory);
    errdefer allocator.free(managed_directory);
    managed_name = try allocator.dupe(u8, name);
    errdefer allocator.free(managed_name);
    managed = try Host.start(allocator, managed_directory, managed_name);
    return managed.?.url;
}

pub fn isManaged() bool {
    return managed != null;
}

/// Replace the running backend with a fresh one. A sandbox extension reaches a
/// child only when it is spawned, so this is how a folder granted while the
/// app is open becomes visible to its backend. Returns the new session URL.
pub fn restartManaged() ![]const u8 {
    if (managed) |*host| {
        host.stop();
        managed = null;
    } else return error.NoManagedBackend;
    managed = try Host.start(managed_allocator, managed_directory, managed_name);
    return managed.?.url;
}

pub fn stopManaged() void {
    if (managed) |*host| host.stop();
    managed = null;
    if (managed_directory.len > 0) managed_allocator.free(managed_directory);
    if (managed_name.len > 0) managed_allocator.free(managed_name);
    managed_directory = &.{};
    managed_name = &.{};
}

fn readSessionUrl(allocator: std.mem.Allocator, output: std.Io.File, timeout_ms: u32) ![]const u8 {
    const io = io_context.get();
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var buffer: [4096]u8 = undefined;
    var length: usize = 0;
    while (length < buffer.len) {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        const elapsed = @divFloor(@max(start.durationTo(now).raw.nanoseconds, 0), std.time.ns_per_ms);
        if (elapsed >= timeout_ms) return error.BackendStartupTimeout;
        var fd = [_]PollFd{.{ .fd = output.handle, .events = 1, .revents = 0 }};
        const ready = poll(&fd, 1, @intCast(timeout_ms - elapsed));
        if (ready == 0) return error.BackendStartupTimeout;
        if (ready < 0) return error.BackendPipeFailure;
        var byte: [1]u8 = undefined;
        const read = output.readStreaming(io, &.{&byte}) catch return error.BackendExitedBeforeReady;
        if (read == 0) return error.BackendExitedBeforeReady;
        if (byte[0] == '\n') {
            const url = std.mem.trim(u8, buffer[0..length], "\r");
            if (!validSessionUrl(url)) return error.InvalidBackendSessionUrl;
            return allocator.dupe(u8, url);
        }
        buffer[length] = byte[0];
        length += 1;
    }
    return error.BackendSessionUrlTooLong;
}

fn drain(output: std.Io.File) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const length = output.readStreaming(io_context.get(), &.{&buffer}) catch return;
        if (length == 0) return;
        std.debug.print("{s}", .{buffer[0..length]});
    }
}

test "bundled helpers stay inside MacOS and session URLs stay on authenticated loopback" {
    try std.testing.expect(validHelperName("stx-backend"));
    for ([_][]const u8{ "", ".", "..", "../backend", "/tmp/backend", "dir\\backend" }) |name|
        try std.testing.expect(!validHelperName(name));
    try std.testing.expect(validSessionUrl("http://127.0.0.1:12345/?session=abc-123"));
    for ([_][]const u8{
        "https://external.example/?session=a", "http://127.0.0.1:0/?session=a",
        "http://127.0.0.1:1234/",              "http://127.0.0.1:1234/?session=a&external=true",
        "http://127.0.0.1:65536/?session=a",   "http://127.0.0.1:1234/?session=",
    }) |url| try std.testing.expect(!validSessionUrl(url));
}

test "a backend exiting before readiness returns its startup error without a second wait" {
    if (comptime builtin.os.tag != .macos) return;
    try std.testing.expectError(error.BackendExitedBeforeReady, Host.start(std.testing.allocator, "/usr/bin", "false"));
}
