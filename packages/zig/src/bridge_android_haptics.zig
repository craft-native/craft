//! `haptic` and `vibrate` on Android.
//!
//! ## Two SDK branches, both live
//!
//! The Kotlin picks its vibrator two ways — `VibratorManager.defaultVibrator`
//! from API 31, the deprecated `VIBRATOR_SERVICE` below it — and its effect two
//! ways, `VibrationEffect` from API 26 and a raw duration below that. The
//! generator defaults `minSdk` to 26, so the pre-26 arm looks dead; a caller
//! can pass `minSdk: 24` and it is not. Both are ported rather than assumed
//! away, and the branch is a runtime read of `Build.VERSION.SDK_INT` exactly as
//! the Kotlin's is.
//!
//! Worth knowing while reading the pre-26 arm: it vibrates for a flat 20ms
//! whatever the style. On API 24 and 25 every haptic feels identical, and that
//! is the shim's behaviour rather than a simplification made here.
//!
//! ## The pattern is parsed here and the effect is built there
//!
//! `vibrate` takes a JSON array of milliseconds. Parsing it in Zig and handing
//! the platform a `long[]` keeps the split every module here uses: the decision
//! is testable on a host, the call is not.
//!
//! A malformed pattern declines rather than erroring. `JSONArray.getLong`
//! throws on an element it cannot convert, the Kotlin catches it and writes
//! "Vibration error" to the log, and nothing vibrates. Declining reaches the
//! same place — the Kotlin runs, throws, logs — and keeps the log line, which
//! returning an error from here would swallow.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const haptic = "haptic";
    pub const vibrate = "vibrate";
};

/// API levels the Kotlin branches on, by the constant it names.
const sdk_s: jni.jint = 31; // Build.VERSION_CODES.S — VibratorManager
const sdk_o: jni.jint = 26; // Build.VERSION_CODES.O — VibrationEffect

/// One effect, as the Kotlin's `when` describes it.
///
/// A tagged union rather than a duration plus a flag: `createOneShot` and
/// `createWaveform` take different arguments, and collapsing them into one
/// shape would mean carrying an unused field through every arm.
pub const Effect = union(enum) {
    /// `createOneShot(milliseconds, DEFAULT_AMPLITUDE)`.
    one_shot: jni.jlong,
    /// `createWaveform(timings, -1)` — no repeat.
    waveform: []const jni.jlong,
};

/// The Kotlin's `when (style)`, as a function.
///
/// Split out because this is the whole of the action's decision and the only
/// half a host can check. The timings are the shim's, to the millisecond: a
/// page that has tuned its feedback around them would feel the difference.
pub fn effectForStyle(style: []const u8) Effect {
    if (std.mem.eql(u8, style, "light")) return .{ .one_shot = 10 };
    if (std.mem.eql(u8, style, "medium")) return .{ .one_shot = 20 };
    if (std.mem.eql(u8, style, "heavy")) return .{ .one_shot = 50 };
    if (std.mem.eql(u8, style, "success")) return .{ .waveform = &.{ 0, 30, 50, 30 } };
    if (std.mem.eql(u8, style, "warning")) return .{ .waveform = &.{ 0, 50, 100, 50 } };
    if (std.mem.eql(u8, style, "error")) return .{ .waveform = &.{ 0, 100, 50, 100 } };
    if (std.mem.eql(u8, style, "selection")) return .{ .one_shot = 5 };
    // The `else ->` arm. An unknown style is absorbed as medium rather than
    // refused, which is what the shim does and what the iOS side does too.
    return .{ .one_shot = 20 };
}

/// The timings in a `vibrate` payload, or null when the shim would throw.
///
/// `JSONArray.getLong` accepts an integer, truncates a double, and parses a
/// numeric string; anything else throws. Matched here, because a page sending
/// `["100"]` vibrates on the shim and would otherwise stop vibrating the day
/// Zig took the action over.
pub fn parsePattern(allocator: std.mem.Allocator, json: []const u8) !?[]jni.jlong {
    // The rejections go through an error rather than a `null` return, so that
    // `errdefer` actually fires. An earlier version returned null from inside
    // the loop with the slice already allocated, which `errdefer` does not
    // cover — the testing allocator caught it as four leaked allocations.
    return parseStrictly(allocator, json) catch |err| switch (err) {
        error.OutOfMemory => err,
        error.NotAPattern => null,
    };
}

fn parseStrictly(allocator: std.mem.Allocator, json: []const u8) ![]jni.jlong {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return error.NotAPattern;
    defer parsed.deinit();

    const array = switch (parsed.value) {
        .array => |a| a,
        else => return error.NotAPattern,
    };

    const out = try allocator.alloc(jni.jlong, array.items.len);
    errdefer allocator.free(out);

    for (array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .integer => |n| n,
            .float => |f| @intFromFloat(std.math.trunc(f)),
            .string => |text| std.fmt.parseInt(jni.jlong, text, 10) catch
                return error.NotAPattern,
            else => return error.NotAPattern,
        };
    }
    return out;
}

/// The device's vibrator, by whichever route this API level offers.
fn vibrator(j: Jni, activity: jobject) !jobject {
    const version_cls = try j.findClass("android/os/Build$VERSION");
    const sdk = try j.staticIntField(
        version_cls,
        try j.staticFieldId(version_cls, "SDK_INT", "I"),
    );

    const context_cls = try j.findClass("android/content/Context");
    const activity_cls = try j.objectClass(activity);
    const get_service = try j.methodId(
        activity_cls,
        "getSystemService",
        "(Ljava/lang/String;)Ljava/lang/Object;",
    );

    if (sdk >= sdk_s) {
        const name = try j.staticObjectField(
            context_cls,
            try j.staticFieldId(context_cls, "VIBRATOR_MANAGER_SERVICE", "Ljava/lang/String;"),
        );
        const manager = try j.callObjectMethodA(activity, get_service, &.{.{ .l = name }});
        const manager_cls = try j.objectClass(manager);
        return j.callObjectMethod(
            manager,
            try j.methodId(manager_cls, "getDefaultVibrator", "()Landroid/os/Vibrator;"),
        );
    }

    const name = try j.staticObjectField(
        context_cls,
        try j.staticFieldId(context_cls, "VIBRATOR_SERVICE", "Ljava/lang/String;"),
    );
    return j.callObjectMethodA(activity, get_service, &.{.{ .l = name }});
}

/// Whether this device builds `VibrationEffect`s.
fn hasVibrationEffect(j: Jni) !bool {
    const version_cls = try j.findClass("android/os/Build$VERSION");
    const sdk = try j.staticIntField(
        version_cls,
        try j.staticFieldId(version_cls, "SDK_INT", "I"),
    );
    return sdk >= sdk_o;
}

/// Play `effect` on the device's vibrator.
pub fn play(j: Jni, activity: jobject, effect: Effect) !void {
    try j.pushLocalFrame(24);
    defer _ = j.popLocalFrame(null);

    const device = try vibrator(j, activity);
    const device_cls = try j.objectClass(device);

    if (!try hasVibrationEffect(j)) {
        // The pre-26 arm. `vibrate(long)` takes a duration and nothing else,
        // so a waveform collapses to the shim's flat 20ms — see the module
        // comment. Not an approximation invented here.
        const millis: jni.jlong = switch (effect) {
            .one_shot => |ms| ms,
            .waveform => 20,
        };
        try j.callVoidMethodA(
            device,
            try j.methodId(device_cls, "vibrate", "(J)V"),
            &.{.{ .j = millis }},
        );
        return;
    }

    const effect_cls = try j.findClass("android/os/VibrationEffect");
    const built = switch (effect) {
        .one_shot => |ms| blk: {
            const amplitude = try j.staticIntField(
                effect_cls,
                try j.staticFieldId(effect_cls, "DEFAULT_AMPLITUDE", "I"),
            );
            break :blk try j.callStaticObjectMethodA(
                effect_cls,
                try j.staticMethodId(effect_cls, "createOneShot", "(JI)Landroid/os/VibrationEffect;"),
                &.{ .{ .j = ms }, .{ .i = amplitude } },
            );
        },
        .waveform => |timings| blk: {
            const array = try j.newLongArray(timings);
            break :blk try j.callStaticObjectMethodA(
                effect_cls,
                try j.staticMethodId(effect_cls, "createWaveform", "([JI)Landroid/os/VibrationEffect;"),
                // -1 is "do not repeat", and it is the shim's value on both
                // waveform paths.
                &.{ .{ .l = array }, .{ .i = -1 } },
            );
        },
    };

    try j.callVoidMethodA(
        device,
        try j.methodId(device_cls, "vibrate", "(Landroid/os/VibrationEffect;)V"),
        &.{.{ .l = built }},
    );
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "every style maps to the timings the shim uses" {
    // Millisecond-exact, because a page that tuned its feedback around these
    // would feel a change that no test of "it vibrated" would catch.
    try testing.expectEqual(@as(jni.jlong, 10), effectForStyle("light").one_shot);
    try testing.expectEqual(@as(jni.jlong, 20), effectForStyle("medium").one_shot);
    try testing.expectEqual(@as(jni.jlong, 50), effectForStyle("heavy").one_shot);
    try testing.expectEqual(@as(jni.jlong, 5), effectForStyle("selection").one_shot);

    try testing.expectEqualSlices(jni.jlong, &.{ 0, 30, 50, 30 }, effectForStyle("success").waveform);
    try testing.expectEqualSlices(jni.jlong, &.{ 0, 50, 100, 50 }, effectForStyle("warning").waveform);
    try testing.expectEqualSlices(jni.jlong, &.{ 0, 100, 50, 100 }, effectForStyle("error").waveform);
}

test "an unknown style is absorbed as medium, not refused" {
    // The `else ->` arm. iOS does the same thing for the same reason: with no
    // reply channel there is nowhere to report a typo, so a wrong style is
    // indistinguishable from "medium" on both platforms.
    try testing.expectEqual(@as(jni.jlong, 20), effectForStyle("soft").one_shot);
    try testing.expectEqual(@as(jni.jlong, 20), effectForStyle("").one_shot);
    try testing.expectEqual(@as(jni.jlong, 20), effectForStyle("HEAVY").one_shot);
}

test "a pattern parses the way JSONArray.getLong reads it" {
    const alloc = testing.allocator;

    {
        const p = (try parsePattern(alloc, "[0,100,50,100]")).?;
        defer alloc.free(p);
        try testing.expectEqualSlices(jni.jlong, &.{ 0, 100, 50, 100 }, p);
    }
    // A double truncates rather than rounding — `getLong` casts.
    {
        const p = (try parsePattern(alloc, "[10.9]")).?;
        defer alloc.free(p);
        try testing.expectEqualSlices(jni.jlong, &.{10}, p);
    }
    // A numeric string parses. A page sending ["100"] vibrates on the shim,
    // and would stop the day Zig took the action over if this were refused.
    {
        const p = (try parsePattern(alloc, "[\"100\", 50]")).?;
        defer alloc.free(p);
        try testing.expectEqualSlices(jni.jlong, &.{ 100, 50 }, p);
    }
    // An empty array is a valid pattern that vibrates for no time at all.
    {
        const p = (try parsePattern(alloc, "[]")).?;
        defer alloc.free(p);
        try testing.expectEqual(@as(usize, 0), p.len);
    }
}

test "a pattern the shim would throw on declines instead of erroring" {
    // Null here means "let the Kotlin run", which throws, logs
    // "Vibration error", and vibrates nothing. Returning an error instead
    // would reach the same silence and lose the log line.
    const alloc = testing.allocator;
    try testing.expect(try parsePattern(alloc, "not json") == null);
    try testing.expect(try parsePattern(alloc, "{\"a\":1}") == null);
    try testing.expect(try parsePattern(alloc, "[true]") == null);
    try testing.expect(try parsePattern(alloc, "[null]") == null);
    try testing.expect(try parsePattern(alloc, "[\"abc\"]") == null);
    try testing.expect(try parsePattern(alloc, "[[1,2]]") == null);
}

test "the action names match the Kotlin methods exactly" {
    try testing.expectEqualStrings("haptic", A.haptic);
    try testing.expectEqualStrings("vibrate", A.vibrate);
}
