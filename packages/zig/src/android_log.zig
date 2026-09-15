//! Zig's `std.log` output, routed to logcat through `android.util.Log`.
//!
//! Before this, every `std.log` line in the Android build went to stderr, and
//! ART discards stderr. `JNI_OnLoad` reports a refused `RegisterNatives` that
//! way, so three quite different states were indistinguishable from outside:
//! the library was never shipped, the library loaded but a descriptor was
//! wrong, or the library loaded and bound and the action simply declined. All
//! three end with the Kotlin shim answering and nothing anywhere saying which
//! happened.
//!
//! Through Java rather than `__android_log_write`, because this library
//! deliberately links no libc — `android_dispatch.zig` records why, and the
//! same reasoning rules out `dlopen`ing liblog, since libdl is not linked
//! either. JNI calls are the one thing it can already do, and `android.util.Log`
//! is reachable that way with no new link dependency at all.
//!
//! iOS has never needed this: `ios_dispatch.zig`'s lines reach the device
//! console as they are, which is what the mobile E2E suite reads to prove the
//! Zig runtime served a call. This is the Android counterpart.

const std = @import("std");
const jni = @import("jni_runtime.zig");

/// The logcat tag. Distinct from the Kotlin shim's `CraftBridge`, so a reader
/// can tell which side of the hand-off produced a line.
pub const tag = "CraftNative";

/// Longest line that survives intact. Longer ones are replaced by their own
/// format string, which is comptime-known and still names the log site.
const max_line = 1024;

var java_vm: ?jni.JavaVM = null;
var dropped: std.atomic.Value(usize) = .init(0);

/// Guards against a log inside a log. Everything below can fail, and the
/// failure paths must stay silent — one bad JNI call would otherwise become an
/// unbounded stack of them. Thread-local because two threads logging at once
/// is normal and neither should mute the other.
threadlocal var writing: bool = false;

/// Give the log channel the VM, from `JNI_OnLoad`.
///
/// Until this is called there is nowhere to write, which covers the window
/// before the library is loaded. Lines in that window are counted, not queued:
/// a queue would have to be bounded, and a bound is another thing to get wrong
/// for output nobody is reading yet.
pub fn setVm(vm: jni.JavaVM) void {
    java_vm = vm;
}

/// Lines that could not be written. A diagnosis reads this rather than
/// wondering whether the code was silent or the channel was.
pub fn droppedCount() usize {
    return dropped.load(.monotonic);
}

pub fn resetForTest() void {
    java_vm = null;
    dropped.store(0, .monotonic);
}

/// `std.Options.logFn`, installed by `android_dispatch.zig`.
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (writing) return;
    writing = true;
    defer writing = false;

    // The scope is prefixed rather than dropped, the same choice
    // `src/minimal.zig` makes: `std.log.scoped(...)` is used throughout craft
    // and the scope is most of what makes a line findable.
    const prefix = if (scope == .default) "" else "[" ++ @tagName(scope) ++ "] ";

    var buffer: [max_line]u8 = undefined;
    // On overflow, the format string itself — comptime-known, no arguments to
    // render, and it still says which log site fired. A truncated line would
    // be better still, but `bufPrint` does not report how far it got.
    const text = std.fmt.bufPrint(&buffer, prefix ++ format, args) catch prefix ++ format;

    write(message_level, text);
}

fn write(level: std.log.Level, text: []const u8) void {
    const vm = java_vm orelse {
        _ = dropped.fetchAdd(1, .monotonic);
        return;
    };

    const attachment = jni.attachCurrentThread(vm) orelse {
        _ = dropped.fetchAdd(1, .monotonic);
        return;
    };
    defer attachment.release(vm);

    writeThrough(attachment.env, level, text) catch {
        _ = dropped.fetchAdd(1, .monotonic);
    };
}

fn writeThrough(env: jni.JNIEnv, level: std.log.Level, text: []const u8) !void {
    const j = jni.Jni.init(env);

    // A frame around the class and the two strings. Logging is the one thing
    // that can happen on any thread at any rate, so leaking a local ref per
    // line would overflow the JVM's sixteen slots and abort the process —
    // turning a diagnostic into the fault it was meant to diagnose.
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    // Stack, not the heap: a logger that allocates is a logger that cannot
    // report an allocation failure. Sized for the tag plus a `max_line`
    // message re-encoded to modified UTF-8.
    var storage: [4 * max_line]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fba.allocator();

    const cls = try j.findClass("android/util/Log");
    const tag_string = try j.newStringUtf8(allocator, tag);
    const message = try j.newStringUtf8(allocator, text);

    const method = try j.staticMethodId(cls, methodFor(level), "(Ljava/lang/String;Ljava/lang/String;)I");
    _ = try j.callStaticIntMethodA(cls, method, &.{ .{ .l = tag_string }, .{ .l = message } });
}

/// `android.util.Log`'s one-letter method for each Zig level.
///
/// Named methods rather than `Log.println(priority, …)` so the priority
/// constants do not have to be mirrored here: getting `WARN` wrong by one
/// would misfile every warning under a level that reads as routine.
pub fn methodFor(level: std.log.Level) [*:0]const u8 {
    return switch (level) {
        .err => "e",
        .warn => "w",
        .info => "i",
        .debug => "d",
    };
}

const testing = std.testing;

test "every level maps to a real android.util.Log method" {
    // The four one-letter statics on android.util.Log, and nothing else. A
    // typo here fails at `GetStaticMethodID` on a device and nowhere before.
    for ([_]std.log.Level{ .err, .warn, .info, .debug }) |level| {
        const name = std.mem.span(methodFor(level));
        try testing.expectEqual(@as(usize, 1), name.len);
        try testing.expect(std.mem.indexOfScalar(u8, "ewid", name[0]) != null);
    }
}

test "levels do not share a method" {
    const levels = [_]std.log.Level{ .err, .warn, .info, .debug };
    for (levels, 0..) |left, i| {
        for (levels[i + 1 ..]) |right| {
            try testing.expect(!std.mem.eql(
                u8,
                std.mem.span(methodFor(left)),
                std.mem.span(methodFor(right)),
            ));
        }
    }
}

test "a line with no VM is counted rather than written" {
    resetForTest();
    defer resetForTest();

    try testing.expectEqual(@as(usize, 0), droppedCount());
    write(.warn, "nowhere to put this");
    try testing.expectEqual(@as(usize, 1), droppedCount());
}

test "the tag is not the shim's" {
    // Both reach logcat, and telling Zig's output from Kotlin's is the whole
    // point of the Android half of the E2E suite's attribution.
    try testing.expect(!std.mem.eql(u8, tag, "CraftBridge"));
}
