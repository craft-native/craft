//! The Android actions that need nothing but the JVM: `getMemoryUsage` and
//! `log`.
//!
//! Tier 0 in the sense the iOS migration used: no permission prompt, no UI, no
//! callback, and — the part specific to Android — **no `Activity`**. Both reach
//! a static class and stop, so neither depends on anything the app hands over.
//!
//! ## `getMemoryUsage` is not the iOS action wearing a different name
//!
//! iOS asks the kernel for this process's resident size through `task_info`.
//! Android asks the *JVM* about its own heap through `java.lang.Runtime`, and
//! those are different quantities: `Runtime.totalMemory()` is what the managed
//! heap has reserved, not what the process holds. Every native allocation this
//! bridge makes is outside it.
//!
//! So the two platforms answer with different keys and that is correct rather
//! than sloppy — iOS emits `usedMB`/`residentSize`/`virtualSize`, Android emits
//! `usedMB`/`maxMB`/`totalMB`/`usedBytes`/`maxBytes`. Only `usedMB` is shared,
//! and even that means something different. Making them agree would mean one
//! of them lying about which number it measured.
//!
//! ## The rounding is arithmetic, not formatting
//!
//! `Math.round(usedMemory / 1024.0 / 1024.0 * 100) / 100.0` is hundredths of a
//! megabyte, rounded half up. Done here in integers for the reason
//! `bridge_mobile_device.zig` gives for the same figure on iOS: the rounding
//! becomes a property of a function that can be asserted on a host, rather than
//! of a float format that has to be observed.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;

/// The action names, spelled exactly as `CraftBridge.kt` spells them. The
/// conformance ratchet matches the two lists by string.
pub const A = struct {
    pub const get_memory_usage = "getMemoryUsage";
    pub const log = "log";
};

/// What the JVM reports about its own heap.
pub const MemoryUsage = struct {
    used_bytes: i64,
    max_bytes: i64,
    total_bytes: i64,
};

/// Bytes as hundredths of a megabyte, rounded half up.
///
/// Integer arithmetic so the rounding is assertable. `Math.round` in Java is
/// `floor(x + 0.5)`, which for a non-negative byte count is the same as adding
/// half the divisor before dividing — and a byte count is never negative, so
/// the difference between round-half-up and round-half-away never arises.
///
/// The divisor is 1024*1024/100 scaled: hundredths of a MiB means
/// `bytes * 100 / (1024*1024)`, and the `+ half` is the round.
pub fn hundredthsOfMebibyte(bytes: i64) i64 {
    if (bytes <= 0) return 0;
    const mib: i64 = 1024 * 1024;
    return @divTrunc(bytes * 100 + @divTrunc(mib, 2), mib);
}

/// `usedMB` and friends, rendered the way `JSONObject.put(double)` renders
/// them: a whole number loses its fraction, everything else keeps exactly the
/// hundredths it has.
///
/// Java prints `117.0` for a whole double and Zig's `{d}` prints `117`. That
/// difference is invisible to `JSON.parse` — both produce the same number — and
/// chasing it would mean formatting by hand to match a Java quirk no consumer
/// can observe.
fn appendMegabytes(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), bytes: i64) !void {
    const hundredths = hundredthsOfMebibyte(bytes);
    const fraction = @mod(hundredths, 100);

    try out.print(allocator, "{d}.", .{@divTrunc(hundredths, 100)});
    // Padded by hand rather than with a width spec. `{d:0>2}` renders `+74`
    // on this toolchain — a sign, not a zero — which is not a number JSON
    // accepts, and the reply stops parsing at the dot.
    if (fraction < 10) try out.append(allocator, '0');
    try out.print(allocator, "{d}", .{fraction});
}

/// The reply bytes for `getMemoryUsage`.
///
/// Key order follows the Kotlin's `put` order, for the same reason the device
/// module follows it: a diff against the Kotlin is how this gets reviewed.
pub fn renderMemory(allocator: std.mem.Allocator, usage: MemoryUsage) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"usedMB\":");
    try appendMegabytes(allocator, &out, usage.used_bytes);
    try out.appendSlice(allocator, ",\"maxMB\":");
    try appendMegabytes(allocator, &out, usage.max_bytes);
    try out.appendSlice(allocator, ",\"totalMB\":");
    try appendMegabytes(allocator, &out, usage.total_bytes);

    // The byte counts are exact and stay integers. A `long` past 2^53 would
    // lose precision in `JSON.parse`, but a JVM heap that large does not exist.
    try out.appendSlice(allocator, ",\"usedBytes\":");
    try out.print(allocator, "{d}", .{usage.used_bytes});
    try out.appendSlice(allocator, ",\"maxBytes\":");
    try out.print(allocator, "{d}", .{usage.max_bytes});
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

/// Ask `java.lang.Runtime` about the managed heap.
///
/// `used = total - free` is the Kotlin's own arithmetic, and it is the only
/// one of the three that is derived rather than read.
pub fn readMemory(j: Jni) !MemoryUsage {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const cls = try j.findClass("java/lang/Runtime");
    const runtime = try j.callStaticObjectMethodA(
        cls,
        try j.staticMethodId(cls, "getRuntime", "()Ljava/lang/Runtime;"),
        &.{},
    );

    const total = try j.callLongMethod(runtime, try j.methodId(cls, "totalMemory", "()J"));
    const free = try j.callLongMethod(runtime, try j.methodId(cls, "freeMemory", "()J"));
    const max = try j.callLongMethod(runtime, try j.methodId(cls, "maxMemory", "()J"));

    return .{ .used_bytes = total - free, .max_bytes = max, .total_bytes = total };
}

/// `android.util.Log.d("CraftBridge", message)`.
///
/// The tag is the Kotlin's, character for character. Anyone filtering logcat on
/// `CraftBridge` is filtering on a string, and changing it because Zig now
/// emits the line would break a filter that has nothing to do with this
/// migration.
pub fn writeLog(j: Jni, message: [*:0]const u8) !void {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const cls = try j.findClass("android/util/Log");
    const tag = try j.newStringUtf("CraftBridge");
    const text = try j.newStringUtf(message);

    // `Log.d` returns the number of bytes written, which the Kotlin ignores
    // and so does this. Discarding it is not the same as calling a void
    // method: the JVM would push a different frame for `CallStaticVoidMethodA`.
    _ = try j.callStaticIntMethodA(
        cls,
        try j.staticMethodId(cls, "d", "(Ljava/lang/String;Ljava/lang/String;)I"),
        &.{ .{ .l = tag }, .{ .l = text } },
    );
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "hundredths of a mebibyte round the way Math.round does" {
    // Exact boundaries first: one MiB is 100 hundredths by definition.
    try testing.expectEqual(@as(i64, 100), hundredthsOfMebibyte(1024 * 1024));
    try testing.expectEqual(@as(i64, 200), hundredthsOfMebibyte(2 * 1024 * 1024));
    try testing.expectEqual(@as(i64, 0), hundredthsOfMebibyte(0));

    // Half rounds up, which is what `floor(x + 0.5)` does for a positive x.
    // Half a hundredth of a MiB is 1048576/200 = 5242.88 bytes, so 5243 is the
    // first byte count at or above the halfway point and 5242 is below it.
    // (Writing the boundary as `1024*1024/200` truncates to 5242 and asserts
    // the opposite of what it looks like — which is what the first version of
    // this test did.)
    try testing.expectEqual(@as(i64, 1), hundredthsOfMebibyte(5243));
    try testing.expectEqual(@as(i64, 0), hundredthsOfMebibyte(5242));

    // A negative cannot come from a byte count, and answering 0 is better than
    // answering a negative megabyte.
    try testing.expectEqual(@as(i64, 0), hundredthsOfMebibyte(-1));
}

test "the memory reply carries every key the Kotlin puts, and parses" {
    const usage = MemoryUsage{
        .used_bytes = 123_456_789,
        .max_bytes = 536_870_912,
        .total_bytes = 268_435_456,
    };
    const json = try renderMemory(testing.allocator, usage);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqual(@as(usize, 5), obj.count());
    try testing.expectEqual(@as(i64, 123_456_789), obj.get("usedBytes").?.integer);
    try testing.expectEqual(@as(i64, 536_870_912), obj.get("maxBytes").?.integer);

    // 123456789 / 1048576 = 117.7375… → 117.74
    try testing.expectApproxEqAbs(@as(f64, 117.74), obj.get("usedMB").?.float, 0.0001);
    // 536870912 is exactly 512 MiB, and 268435456 exactly 256.
    try testing.expectApproxEqAbs(@as(f64, 512), obj.get("maxMB").?.float, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 256), obj.get("totalMB").?.float, 0.0001);
}

test "a whole number of megabytes still renders as a number" {
    // The `.00` path: `512.00` is valid JSON and parses to 512, but a bug in
    // the fraction split would produce `512.` or `512.0` — one of which is not
    // JSON at all.
    const json = try renderMemory(testing.allocator, .{
        .used_bytes = 1024 * 1024,
        .max_bytes = 1024 * 1024,
        .total_bytes = 1024 * 1024,
    });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"usedMB\":1.00,") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1), parsed.value.object.get("usedMB").?.float, 0.0001);
}

test "a heap under a hundredth of a megabyte does not render as garbage" {
    // The zero-fraction edge, from the other side: a two-digit pad is what
    // stops 5 hundredths becoming "0.5".
    const json = try renderMemory(testing.allocator, .{
        .used_bytes = 52_429, // ~0.05 MiB
        .max_bytes = 0,
        .total_bytes = 0,
    });
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"usedMB\":0.05,") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"maxMB\":0.00,") != null);
}

test "the action names match the Kotlin methods exactly" {
    try testing.expectEqualStrings("getMemoryUsage", A.get_memory_usage);
    try testing.expectEqualStrings("log", A.log);
}
