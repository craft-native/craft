//! The AppleScript bridge against the real scripting runtime: what a page would receive for a
//! script that works, one that fails, and one whose output holds control characters.
//!
//! A root of its own, as `bridge_fs_test.zig` explains: tests inside `bridge_apple_script.zig`
//! would ride into every binary that reaches `macos.zig`. Only macOS has NSAppleScript, so the
//! tests skip elsewhere. None of these scripts talks to another app, so no permission is asked.

const std = @import("std");
const builtin = @import("builtin");
const bridge_apple_script = @import("bridge_apple_script.zig");

const testing = std.testing;

fn runParsed(source: []const u8) !std.json.Parsed(std.json.Value) {
    const reply = try bridge_apple_script.run(testing.allocator, source);
    defer testing.allocator.free(reply);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{ .allocate = .alloc_always });
}

test "a script that works returns its result" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const parsed = try runParsed("return \"hello\"");
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("ok").?.bool);
    try testing.expectEqualStrings("hello", parsed.value.object.get("result").?.string);
    try testing.expect(parsed.value.object.get("error") == null);
}

test "a script that raises an error reports its number and message" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const parsed = try runParsed("error \"the disk is full\" number 77");
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.get("ok").?.bool);
    const failure = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, 77), failure.get("code").?.integer);
    try testing.expectEqualStrings("the disk is full", failure.get("message").?.string);
}

test "a script that does not compile reports a syntax error" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const parsed = try runParsed("tell application \"Finder\" to get {");
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.get("ok").?.bool);
    const failure = parsed.value.object.get("error").?.object;
    const code = failure.get("code").?.integer;
    try testing.expect(code == -2741 or code == -2740 or code == -2753);
    try testing.expect(failure.get("message").?.string.len > 0);
}

test "control characters in a result still produce valid JSON" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const parsed = try runParsed("return \"a\" & (ASCII character 1) & \"b\" & (ASCII character 31) & \"c\" & tab & \"d\" & quote & \"e\"");
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("ok").?.bool);
    try testing.expectEqualStrings("a\x01b\x1fc\td\"e", parsed.value.object.get("result").?.string);
}

test "unicode survives the trip" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const parsed = try runParsed("return \"Résumé 日本語 🚀\"");
    defer parsed.deinit();
    try testing.expectEqualStrings("Résumé 日本語 🚀", parsed.value.object.get("result").?.string);
}

test "repeated runs do not accumulate failures or leak the allocator" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    for (0..50) |_| {
        const ok = try runParsed("return 1 + 1");
        ok.deinit();
        const bad = try runParsed("error \"x\" number 1");
        bad.deinit();
    }
}
