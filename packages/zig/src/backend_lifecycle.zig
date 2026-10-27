//! Bounded, cancellable process cleanup for managed application backends.
const std = @import("std");
const builtin = @import("builtin");

pub fn waitForExit(child: *std.process.Child, io: std.Io, timeout: std.Io.Duration) ?std.process.Child.Term {
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

test "backend shutdown waits for graceful completion and bounds a stuck helper" {
    if (comptime builtin.os.tag != .macos) return;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "sleep 0.05; exit 7" } });
    defer child.kill(io);
    const term = waitForExit(&child, io, .fromSeconds(1)) orelse return error.BackendDidNotFinish;
    try std.testing.expectEqual(@as(u8, 7), term.exited);
    var stuck = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "60" } });
    defer stuck.kill(io);
    try std.testing.expectEqual(null, waitForExit(&stuck, io, .fromMilliseconds(20)));
}
