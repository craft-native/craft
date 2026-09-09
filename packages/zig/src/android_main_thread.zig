//! Getting onto the main thread, which Zig cannot do by itself.
//!
//! Several Android calls must run on the main looper — `Window.addFlags`
//! touches the view hierarchy, `setRequestedOrientation` goes through the
//! Activity — and the shim wraps each in `activity.runOnUiThread { ... }`.
//! That takes a `Runnable`, a Java object implementing a Java interface, and
//! JNI cannot make one: `RegisterNatives` binds methods on a class that
//! already exists in the APK, so a native can *be* called from Java but cannot
//! be handed to Java as an object.
//!
//! This is the same wall `android_events.zig` gets around for replies, and the
//! same answer: Kotlin owns the object, Zig owns the work. `CraftNative.runOnMain`
//! posts a `Runnable` that calls straight back into `nativeRunTask`, carrying a
//! token — and the Activity, so nothing here has to hold a reference across
//! the hop.
//!
//! ## Why a token and not a pointer
//!
//! The obvious shape is to pass Zig a pointer and cast it back. It is also the
//! shape where a stale `Runnable` — one the looper still holds after whatever
//! queued it is gone — reads freed memory and the crash lands somewhere else
//! entirely.
//!
//! A token is checkable. Each slot carries a generation that increments when
//! the slot is reused, so a token from a previous occupant does not match and
//! the task is dropped rather than run. `nativeRunTask` cannot be made to run
//! the wrong task by anything the JVM does with timing.
//!
//! ## The table is fixed and small
//!
//! Thirty-two slots, no allocator. These tasks live between a page's call and
//! the next turn of the looper — microseconds — so the table being full means
//! something is wrong rather than busy, and the caller falls through to the
//! shim rather than growing.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

/// The work to do once the main thread is reached.
///
/// A tagged union rather than a function pointer and an opaque payload: every
/// variant is small, the set is closed, and a reader can see what can be
/// queued without following an indirection. A variant needing heap memory
/// would carry an owned slice and gain a `free` arm below.
pub const Task = union(enum) {
    /// `activity.setRequestedOrientation(mode)`.
    set_requested_orientation: i32,
};

const slot_count = 32;

const Slot = struct {
    task: Task = undefined,
    generation: u32 = 0,
    occupied: bool = false,
};

var slots: [slot_count]Slot = @splat(.{});

/// The table is written from the JavaBridge thread and read from the main
/// looper, which are different threads by construction — that is the entire
/// point of the hop.
///
/// A spin lock rather than a mutex, because `std.Io.Mutex` on this toolchain
/// wants an `Io` and a JNI native has nowhere to get one. The critical
/// sections are a handful of instructions over a 32-entry array, and at most
/// two threads ever contend, so spinning is the cheap answer rather than the
/// lazy one.
var table_locked: std.atomic.Value(bool) = .init(false);

fn lockTable() void {
    while (table_locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockTable() void {
    table_locked.store(false, .release);
}

pub const PostError = error{TableFull};

/// Claim a slot and return its token, or fail if none is free.
///
/// Split from `post` so the reservation is testable without a JVM: this is
/// where every property worth checking lives.
pub fn reserve(task: Task) PostError!u64 {
    lockTable();
    defer unlockTable();

    for (&slots, 0..) |*slot, index| {
        if (slot.occupied) continue;
        slot.task = task;
        slot.occupied = true;
        return (@as(u64, @intCast(index)) << 32) | slot.generation;
    }
    return error.TableFull;
}

/// Take the task a token names, or null if the token is stale or unknown.
///
/// Taking rather than reading: a slot is released here, so a `Runnable` that
/// somehow fires twice finds nothing the second time.
pub fn claim(token: u64) ?Task {
    const index: usize = @intCast(token >> 32);
    const generation: u32 = @truncate(token);

    if (index >= slot_count) return null;

    lockTable();
    defer unlockTable();

    const slot = &slots[index];
    if (!slot.occupied or slot.generation != generation) return null;

    const task = slot.task;
    slot.occupied = false;
    // Wrapping, because the only thing that matters is that a token minted
    // before this point stops matching. Sixty-four thousand reuses of one slot
    // between a post and its Runnable is not a thing that happens.
    slot.generation +%= 1;
    return task;
}

/// Give a reserved slot back, for a caller that could not schedule it.
///
/// Without this a failed `runOnMain` would leak the slot until the table
/// filled, and the failure would show up as an unrelated action falling
/// through much later.
pub fn release(token: u64) void {
    _ = claim(token);
}

/// `CraftNative.runOnMain(activity, token, delayMs)`.
///
/// `delay_ms` above zero posts through a `Handler`; zero goes through
/// `runOnUiThread`, which runs inline when the caller is already on the main
/// thread. The shim's `runOnUiThread` has that same property, so an action
/// this serves keeps the shim's ordering.
pub fn post(j: Jni, activity: jobject, task: Task, delay_ms: i64) !void {
    const token = try reserve(task);
    errdefer release(token);

    const holder = try j.findClass(holder_class);
    try j.callStaticVoidMethodA(
        holder,
        try j.staticMethodId(holder, "runOnMain", "(Landroid/app/Activity;JJ)V"),
        &.{ .{ .l = activity }, .{ .j = @bitCast(token) }, .{ .j = delay_ms } },
    );
}

/// The fixed-package holder the natives are registered on.
const holder_class = "com/craft/runtime/CraftNative";

/// Run the task a token names. Called from `nativeRunTask`, on the main thread.
pub fn run(j: Jni, activity: jobject, token: u64) void {
    const task = claim(token) orelse return;
    switch (task) {
        .set_requested_orientation => |mode| setRequestedOrientation(j, activity, mode) catch {},
    }
}

fn setRequestedOrientation(j: Jni, activity: jobject, mode: i32) !void {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    try j.callVoidMethodA(
        activity,
        try j.methodId(try j.objectClass(activity), "setRequestedOrientation", "(I)V"),
        &.{.{ .i = mode }},
    );
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn clearTable() void {
    lockTable();
    defer unlockTable();
    for (&slots) |*slot| slot.occupied = false;
}

test "a reserved task comes back exactly once" {
    clearTable();

    const token = try reserve(.{ .set_requested_orientation = 1 });
    const claimed = claim(token).?;
    try testing.expectEqual(@as(i32, 1), claimed.set_requested_orientation);

    // The second claim is the one that matters: a Runnable the looper somehow
    // ran twice must not set the orientation twice.
    try testing.expect(claim(token) == null);
}

test "a stale token does not run the slot's new occupant" {
    clearTable();

    const first = try reserve(.{ .set_requested_orientation = 1 });
    _ = claim(first);

    // The same slot, a new task. Without the generation, `first` would still
    // index it and would run this.
    const second = try reserve(.{ .set_requested_orientation = 8 });
    try testing.expect(claim(first) == null);

    const claimed = claim(second).?;
    try testing.expectEqual(@as(i32, 8), claimed.set_requested_orientation);
}

test "an unknown token is dropped rather than indexing out of bounds" {
    clearTable();

    // A token naming a slot past the end, which is what a corrupted or
    // fabricated long would look like arriving from Java.
    try testing.expect(claim(0xFFFF_FFFF_0000_0000) == null);
    try testing.expect(claim(std.math.maxInt(u64)) == null);
    // And one naming a real slot that holds nothing.
    try testing.expect(claim(0) == null);
}

test "the table fills and says so rather than overwriting" {
    clearTable();

    var tokens: [slot_count]u64 = undefined;
    for (&tokens) |*token| token.* = try reserve(.{ .set_requested_orientation = 0 });

    try testing.expectError(error.TableFull, reserve(.{ .set_requested_orientation = 0 }));

    // Every token is distinct — the failure above is a full table and not a
    // slot handed out twice.
    for (tokens, 0..) |a, i| {
        for (tokens[i + 1 ..]) |b| try testing.expect(a != b);
    }

    // And releasing one makes room again.
    release(tokens[3]);
    _ = try reserve(.{ .set_requested_orientation = 0 });
}

test "releasing a token a caller could not schedule frees its slot" {
    clearTable();

    const token = try reserve(.{ .set_requested_orientation = 1 });
    release(token);
    try testing.expect(claim(token) == null);

    // The slot is genuinely free rather than merely unreadable.
    var count: usize = 0;
    while (count < slot_count) : (count += 1) {
        _ = try reserve(.{ .set_requested_orientation = 0 });
    }
}

test "the holder class is the fixed one, not the templated bridge" {
    // A `{{` here would mean the library had been made app-specific, which is
    // the thing RegisterNatives exists to avoid.
    try testing.expectEqualStrings("com/craft/runtime/CraftNative", holder_class);
    try testing.expect(std.mem.indexOf(u8, holder_class, "{") == null);
}
