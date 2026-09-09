//! `startMotionUpdates` and `stopMotionUpdates` on Android.
//!
//! The fourth listener shim, and the one that needed `android_json_number`
//! first: the payload is six floats printed by `org.json`, which is why this
//! pair was passed over three times.
//!
//! ## One event per sample, carrying both sensors
//!
//! The accelerometer and the gyroscope are registered separately and arrive
//! separately, but every arrival sends *both* — the one that just changed and
//! the last value the other reported. So a device with both sensors at
//! `SENSOR_DELAY_GAME` produces two `craftMotionUpdate` events per cycle, each
//! a complete reading.
//!
//! A sensor that has not reported yet reads as zeroes rather than being
//! absent: `lastAccel ?: floatArrayOf(0f, 0f, 0f)`. So the first event after
//! `startMotionUpdates` always claims one of the two is perfectly still, and a
//! page cannot tell that from a device lying on a table.
//!
//! ## The state is per-registration
//!
//! The shim keeps `lastAccel` and `lastGyro` inside the listener object it
//! creates in `startMotionUpdates`, so stopping and starting forgets them.
//! Reproduced: `reset` runs on start.
//!
//! Both sensors deliver on the main looper — `registerListener` without a
//! `Handler` uses it — so the samples arrive on one thread and the last-value
//! state needs no lock. `stopMotionUpdates` does not touch it.

const std = @import("std");
const events = @import("android_events.zig");

pub const A = struct {
    pub const start_motion_updates = "startMotionUpdates";
    pub const stop_motion_updates = "stopMotionUpdates";
};

pub const event_name = "craftMotionUpdate";

/// The `SensorManager` delay the shim's `when` picks.
pub const Delay = enum {
    fastest,
    game,
    ui,
    normal,

    /// The field on `android.hardware.SensorManager`.
    pub fn field(self: Delay) [:0]const u8 {
        return switch (self) {
            .fastest => "SENSOR_DELAY_FASTEST",
            .game => "SENSOR_DELAY_GAME",
            .ui => "SENSOR_DELAY_UI",
            .normal => "SENSOR_DELAY_NORMAL",
        };
    }
};

/// The shim's `when`, boundaries included.
///
/// Every comparison is `<=`, so 20 is fastest and 21 is game — and the
/// boundaries are the part worth writing down, because "20ms" reading as
/// `SENSOR_DELAY_GAME` would be a plausible off-by-one that nobody would
/// notice except as a slightly wrong sample rate.
pub fn delayFor(interval_ms: i32) Delay {
    if (interval_ms <= 20) return .fastest;
    if (interval_ms <= 60) return .game;
    if (interval_ms <= 200) return .ui;
    return .normal;
}

/// The last reading from each sensor, and whether it has reported at all.
const Reading = struct {
    values: [3]f32 = .{ 0, 0, 0 },
    seen: bool = false,
};

var accelerometer: Reading = .{};
var gyroscope: Reading = .{};

/// Forget both sensors, as creating a new listener object does.
pub fn reset() void {
    accelerometer = .{};
    gyroscope = .{};
}

/// Record a sample. `is_accelerometer` false means the gyroscope.
///
/// The shim's `when` has only those two arms and no else, so a sample from any
/// other sensor updates nothing and still sends an event — which cannot happen
/// today, because only those two are registered.
pub fn record(is_accelerometer: bool, values: [3]f32) void {
    const slot = if (is_accelerometer) &accelerometer else &gyroscope;
    slot.values = values;
    slot.seen = true;
}

pub fn lastAcceleration() [3]f32 {
    return accelerometer.values;
}

pub fn lastRotation() [3]f32 {
    return gyroscope.values;
}

/// `{"acceleration":{"x":…,"y":…,"z":…},"rotation":{"alpha":…,"beta":…,"gamma":…}}`
///
/// The numbers arrive already formatted, because formatting them is
/// `org.json`'s job and not this file's — see `android_json_number`. What is
/// this file's job is the shape: two nested objects, six keys, and the fact
/// that the rotation's keys are Euler angle names rather than x/y/z.
pub fn renderDetail(
    allocator: std.mem.Allocator,
    acceleration: [3][]const u8,
    rotation: [3][]const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"acceleration\":{\"x\":");
    try out.appendSlice(allocator, acceleration[0]);
    try out.appendSlice(allocator, ",\"y\":");
    try out.appendSlice(allocator, acceleration[1]);
    try out.appendSlice(allocator, ",\"z\":");
    try out.appendSlice(allocator, acceleration[2]);
    try out.appendSlice(allocator, "},\"rotation\":{\"alpha\":");
    try out.appendSlice(allocator, rotation[0]);
    try out.appendSlice(allocator, ",\"beta\":");
    try out.appendSlice(allocator, rotation[1]);
    try out.appendSlice(allocator, ",\"gamma\":");
    try out.appendSlice(allocator, rotation[2]);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

/// Send one reading as `craftMotionUpdate`.
pub fn announce(
    allocator: std.mem.Allocator,
    acceleration: [3][]const u8,
    rotation: [3][]const u8,
) !void {
    const detail = try renderDetail(allocator, acceleration, rotation);
    defer allocator.free(detail);
    try events.emitEvent(allocator, event_name, detail);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "every interval lands on the delay the shim's when picks" {
    // The boundaries, which are all `<=`. An off-by-one here is a slightly
    // wrong sample rate and nothing else — no error, no warning.
    try testing.expectEqual(Delay.fastest, delayFor(0));
    try testing.expectEqual(Delay.fastest, delayFor(20));
    try testing.expectEqual(Delay.game, delayFor(21));
    try testing.expectEqual(Delay.game, delayFor(60));
    try testing.expectEqual(Delay.ui, delayFor(61));
    try testing.expectEqual(Delay.ui, delayFor(200));
    try testing.expectEqual(Delay.normal, delayFor(201));
    try testing.expectEqual(Delay.normal, delayFor(100_000));

    // A negative interval is fastest, because the first `<=` catches it. The
    // injected JS sends `interval || 100`, so zero already arrives as 100 —
    // but nothing stops a page calling the interface directly.
    try testing.expectEqual(Delay.fastest, delayFor(-1));
}

test "each delay names a real SensorManager field" {
    try testing.expectEqualStrings("SENSOR_DELAY_FASTEST", Delay.fastest.field());
    try testing.expectEqualStrings("SENSOR_DELAY_GAME", Delay.game.field());
    try testing.expectEqualStrings("SENSOR_DELAY_UI", Delay.ui.field());
    try testing.expectEqualStrings("SENSOR_DELAY_NORMAL", Delay.normal.field());

    // All four distinct, which a copy-paste in the switch would break without
    // changing anything a compiler could see.
    const fields = [_][]const u8{
        Delay.fastest.field(), Delay.game.field(),
        Delay.ui.field(),      Delay.normal.field(),
    };
    for (fields, 0..) |a, i| {
        for (fields[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
}

test "a sensor that has not reported reads as zero, not as absent" {
    reset();
    try testing.expectEqual([3]f32{ 0, 0, 0 }, lastAcceleration());
    try testing.expectEqual([3]f32{ 0, 0, 0 }, lastRotation());

    // And after one accelerometer sample the gyroscope is still zeroes — so
    // the first event claims the device is not rotating, which a page cannot
    // tell from a device lying still.
    record(true, .{ 1, 2, 3 });
    try testing.expectEqual([3]f32{ 1, 2, 3 }, lastAcceleration());
    try testing.expectEqual([3]f32{ 0, 0, 0 }, lastRotation());
    reset();
}

test "each sensor keeps its own last value" {
    reset();
    record(true, .{ 1, 2, 3 });
    record(false, .{ 4, 5, 6 });
    try testing.expectEqual([3]f32{ 1, 2, 3 }, lastAcceleration());
    try testing.expectEqual([3]f32{ 4, 5, 6 }, lastRotation());

    // A second accelerometer sample leaves the gyroscope alone, which is what
    // makes every event a complete reading rather than a partial one.
    record(true, .{ 7, 8, 9 });
    try testing.expectEqual([3]f32{ 7, 8, 9 }, lastAcceleration());
    try testing.expectEqual([3]f32{ 4, 5, 6 }, lastRotation());
    reset();
}

test "starting again forgets what the last registration saw" {
    // The shim's lastAccel/lastGyro live on the listener object, which
    // startMotionUpdates creates fresh — so a stop and start does not carry
    // stale readings across.
    reset();
    record(true, .{ 1, 2, 3 });
    reset();
    try testing.expectEqual([3]f32{ 0, 0, 0 }, lastAcceleration());
}

test "the detail nests two objects, and the rotation is not x y z" {
    // The numbers are already formatted — that is org.json's job, not this
    // file's — so this is about the shape: the rotation's keys are Euler
    // angles, and swapping them for x/y/z would be an easy and invisible
    // mistake.
    const json = try renderDetail(
        testing.allocator,
        .{ "9.81", "0", "-0.5" },
        .{ "0.01", "0", "-0" },
    );
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\{"acceleration":{"x":9.81,"y":0,"z":-0.5},"rotation":{"alpha":0.01,"beta":0,"gamma":-0}}
    , json);
}

test "the detail parses, including org.json's integral and negative-zero forms" {
    // `numberToString` prints an integral float as an integer and negative
    // zero as `-0`. Both are legal JSON numbers, and a page parsing this must
    // not choke on them — which is worth checking, because they look wrong.
    const json = try renderDetail(
        testing.allocator,
        .{ "0", "-0", "9" },
        .{ "1.5", "-2", "0" },
    );
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const acceleration = parsed.value.object.get("acceleration").?.object;
    const rotation = parsed.value.object.get("rotation").?.object;
    try testing.expectEqual(@as(usize, 3), acceleration.count());
    try testing.expectEqual(@as(usize, 3), rotation.count());
    try testing.expect(acceleration.get("x") != null);
    try testing.expect(rotation.get("alpha") != null);
}

test "the actions and event name match the shim exactly" {
    try testing.expectEqualStrings("startMotionUpdates", A.start_motion_updates);
    try testing.expectEqualStrings("stopMotionUpdates", A.stop_motion_updates);
    try testing.expectEqualStrings("craftMotionUpdate", event_name);
}
