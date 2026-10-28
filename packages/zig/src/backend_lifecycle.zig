//! Bounded, cancellable process cleanup for managed application backends.
const std = @import("std");
const builtin = @import("builtin");

pub fn waitForExit(child: *std.process.Child, io: std.Io, timeout: std.Io.Duration) ?std.process.Child.Term {
    if (comptime builtin.os.tag == .macos) return waitForDarwinExit(child, io, timeout);
    const Result = union(enum) {
        exited: std.process.Child.WaitError!std.process.Child.Term,
        timeout: std.Io.Cancelable!void,
    };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    select.async(.exited, std.process.Child.wait, .{ child, io });
    select.async(.timeout, std.Io.sleep, .{ io, timeout, .awake });
    defer select.cancelDiscard();
    const result = select.await() catch return null;
    return switch (result) {
        .exited => |term| term catch null,
        .timeout => null,
    };
}

fn waitForDarwinExit(child: *std.process.Child, io: std.Io, timeout: std.Io.Duration) ?std.process.Child.Term {
    const pid = child.id orelse return null;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const queue = std.c.kqueue();
    if (queue < 0) return null;
    defer _ = std.c.close(queue);
    const changes = [_]std.c.Kevent{.{
        .ident = @intCast(pid),
        .filter = std.c.EVFILT.PROC,
        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
        .fflags = std.c.NOTE.EXIT,
        .data = 0,
        .udata = 0,
    }};
    var events: [1]std.c.Kevent = undefined;
    if (std.c.kevent(queue, &changes, 1, &events, 0, null) < 0) {
        // The helper can exit between spawn and registration. It is still ours
        // to reap, but registering an already exited process reports ESRCH.
        if (std.posix.errno(-1) == .SRCH) return child.wait(io) catch null;
        return null;
    }
    // Darwin's pinned Child.wait blocks in wait4. Cancelling a Select that
    // contains it can wait for the child anyway, defeating the grace timeout.
    // Observe exit with the kernel first; only then use Child.wait to reap and
    // close its owned pipes. A timeout leaves the child intact for forced kill.
    while (true) {
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
        const remaining = @max(timeout.nanoseconds - elapsed, 0);
        const deadline: std.c.timespec = .{
            .sec = @intCast(@divFloor(remaining, std.time.ns_per_s)),
            .nsec = @intCast(@mod(remaining, std.time.ns_per_s)),
        };
        const count = std.c.kevent(queue, &changes, 0, &events, 1, &deadline);
        if (count < 0) {
            if (std.posix.errno(count) == .INTR and remaining > 0) continue;
            return null;
        }
        if (count == 0 or events[0].flags & std.c.EV.ERROR != 0) return null;
        if (events[0].fflags & std.c.NOTE.EXIT != 0) return child.wait(io) catch null;
    }
}

test "backend shutdown waits for graceful completion and bounds a stuck helper" {
    if (comptime builtin.os.tag != .macos) return;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "sleep 0.05; exit 7" } });
    defer child.kill(io);
    const term = waitForExit(&child, io, .fromSeconds(1)) orelse return error.BackendDidNotFinish;
    try std.testing.expectEqual(@as(u8, 7), term.exited);
    var stuck = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "3" } });
    defer stuck.kill(io);
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectEqual(null, waitForExit(&stuck, io, .fromMilliseconds(20)));
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
    try std.testing.expect(elapsed < 2 * std.time.ns_per_s);
    try std.testing.expect(stuck.id != null);
    try std.testing.expectEqual(null, waitForExit(&stuck, io, .fromMilliseconds(0)));
    stuck.kill(io);
    try std.testing.expectEqual(null, stuck.id);
}

test "backend shutdown reaps a helper that already exited" {
    if (comptime builtin.os.tag != .macos) return;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 9" } });
    defer child.kill(io);
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    const term = waitForExit(&child, io, .fromSeconds(1)) orelse return error.BackendDidNotFinish;
    try std.testing.expectEqual(@as(u8, 9), term.exited);
    try std.testing.expectEqual(null, child.id);
}
