//! Numbers, printed the way `org.json` prints them.
//!
//! Four migrated modules have declined to format a float, and the reason is
//! always the same: `JSONObject` does not print numbers with a format string.
//! Android's `numberToString` is
//!
//! ```java
//! double doubleValue = number.doubleValue();
//! JSON.checkDouble(doubleValue);                       // throws on NaN, ±Inf
//! if (number.equals(NEGATIVE_ZERO)) return "-0";
//! long longValue = number.longValue();
//! if (doubleValue == (double) longValue) return Long.toString(longValue);
//! return number.toString();                            // Float or Double
//! ```
//!
//! Three of those five lines are decisions a reimplementation would have to
//! rediscover — an integral double prints as an integer, negative zero prints
//! as `-0`, and the fallback is `Float.toString` or `Double.toString`
//! depending on which box the number arrived in, which are *different*
//! functions for the same value.
//!
//! So this asks Java. It is the same judgement `bridge_android_notifications`
//! makes about `hashCode` and `bridge_android_files` about `Base64.decode`:
//! where the platform already has the thing, ask it rather than rebuild it —
//! and here rebuilding means reproducing the shortest-round-trip algorithm for
//! two float widths, where being wrong is a silently different number rather
//! than a failure.
//!
//! ## What it costs
//!
//! Three JNI calls per number: box, format, read back. `getCurrentPosition`
//! makes seven of those once. A motion stream at 50 Hz makes six per event,
//! which is 900 calls a second — real, and still far below what the sensor
//! delivery itself costs.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;

/// `JSONObject.numberToString(Float.valueOf(value))`.
pub fn fromFloat(j: Jni, allocator: std.mem.Allocator, value: f32) ![]u8 {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const float_cls = try j.findClass("java/lang/Float");
    const boxed = try j.callStaticObjectMethodA(
        float_cls,
        try j.staticMethodId(float_cls, "valueOf", "(F)Ljava/lang/Float;"),
        &.{.{ .f = value }},
    );
    return numberToString(j, allocator, boxed);
}

/// `JSONObject.numberToString(Double.valueOf(value))`.
///
/// A separate function rather than a widened `fromFloat`, because the two do
/// not agree: `Float.toString(0.1f)` is "0.1" and `Double.toString(0.1f)` is
/// "0.10000000149011612". Which box a number arrives in is part of what the
/// shim's output means.
pub fn fromDouble(j: Jni, allocator: std.mem.Allocator, value: f64) ![]u8 {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const double_cls = try j.findClass("java/lang/Double");
    const boxed = try j.callStaticObjectMethodA(
        double_cls,
        try j.staticMethodId(double_cls, "valueOf", "(D)Ljava/lang/Double;"),
        &.{.{ .d = value }},
    );
    return numberToString(j, allocator, boxed);
}

fn numberToString(j: Jni, allocator: std.mem.Allocator, boxed: jni.jobject) ![]u8 {
    const json_cls = try j.findClass("org/json/JSONObject");
    const text = try j.callStaticObjectMethodA(
        json_cls,
        try j.staticMethodId(
            json_cls,
            "numberToString",
            "(Ljava/lang/Number;)Ljava/lang/String;",
        ),
        &.{.{ .l = boxed }},
    );
    return j.stringToUtf8(allocator, text);
}

// No tests, deliberately.
//
// Everything here is three JNI calls and a descriptor; there is no formatting
// to check, because not formatting is the point. A host test would have to
// stand up a fake `numberToString` and would then be asserting that a fake
// agrees with itself.
//
// What *is* checked lives with the callers: `bridge_android_motion` tests the
// shape of the object these numbers go into, with the formatted strings
// injected, so the part this file does not own is tested and the part it does
// own is Java's.
