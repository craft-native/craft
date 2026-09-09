//! `setSharedItem`, `getSharedItem` and `removeSharedItem` on Android.
//!
//! The iOS side of this is a keychain access group, which is why the page's
//! globals are called `_craftSharedKeychain*`. Android has no such thing, so
//! the shim uses a `SharedPreferences` file per group — plain, not encrypted,
//! which is worth knowing given the name the page sees. That is the shim's
//! choice and is ported rather than changed here.
//!
//! ## The group is a filename
//!
//! `"craft_shared_" + group` becomes the preferences file's name, and `group`
//! is whatever the page passed. A group containing a path separator does not
//! land where a reader would guess, and `getSharedPreferences` is what decides
//! what happens then. Reproduced exactly: the naming is the only part of this
//! that can silently disagree between the two implementations, and it is
//! decided before any JNI call.
//!
//! ## Every reply carries the key back
//!
//! Both the resolve shapes name the key, so a page can tell which of several
//! outstanding calls settled — which matters here more than elsewhere, since
//! all three actions share one pair of globals and a second call overwrites
//! the first's resolve function.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const set_shared_item = "setSharedItem";
    pub const get_shared_item = "getSharedItem";
    pub const remove_shared_item = "removeSharedItem";
};

pub const resolve_global = "_craftSharedKeychainResolve";
pub const reject_global = "_craftSharedKeychainReject";

/// `Context.MODE_PRIVATE`, a compile-time constant the shim's DEX holds as 0.
const mode_private: i32 = 0;

const prefix = "craft_shared";

/// `if (group.isNotEmpty()) "craft_shared_$group" else "craft_shared"`.
pub fn prefsName(allocator: std.mem.Allocator, group: []const u8) ![:0]u8 {
    if (group.len == 0) {
        const name = try allocator.allocSentinel(u8, prefix.len, 0);
        @memcpy(name, prefix);
        return name;
    }

    const name = try allocator.allocSentinel(u8, prefix.len + 1 + group.len, 0);
    @memcpy(name[0..prefix.len], prefix);
    name[prefix.len] = '_';
    @memcpy(name[prefix.len + 1 ..], group);
    return name;
}

/// `{success: true, key: "<key>"}` — what `setSharedItem` and
/// `removeSharedItem` resolve with.
pub fn successPayload(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"success\":true,\"key\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, key);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

/// `{value: <value>, key: "<key>"}`, where a missing value is a JSON null.
///
/// The shim writes the two branches as two separate `evaluateJavascript`
/// calls; the only difference between them is this argument, so they are one
/// function here and the null is a value rather than a branch.
pub fn valuePayload(allocator: std.mem.Allocator, key: []const u8, value: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"value\":");
    if (value) |text| {
        try out.append(allocator, '"');
        try bridge_error.appendJsonEscaped(allocator, &out, text);
        try out.append(allocator, '"');
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, ",\"key\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, key);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

/// `activity.getSharedPreferences(prefsName(group), MODE_PRIVATE)`.
fn openPrefs(j: Jni, allocator: std.mem.Allocator, activity: jobject, group: []const u8) !jobject {
    const name = try prefsName(allocator, group);
    defer allocator.free(name);

    const activity_cls = try j.objectClass(activity);
    return j.callObjectMethodA(
        activity,
        try j.methodId(
            activity_cls,
            "getSharedPreferences",
            "(Ljava/lang/String;I)Landroid/content/SharedPreferences;",
        ),
        &.{ .{ .l = try j.newStringUtf8(allocator, name) }, .{ .i = mode_private } },
    );
}

/// `prefs.edit().putString(key, value).apply()`.
pub fn set(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    group: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const prefs = try openPrefs(j, allocator, activity, group);
    const editor = try editorFor(j, prefs);
    const editor_cls = try j.objectClass(editor);

    _ = try j.callObjectMethodA(
        editor,
        try j.methodId(
            editor_cls,
            "putString",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;",
        ),
        &.{
            .{ .l = try j.newStringUtf8(allocator, key) },
            .{ .l = try j.newStringUtf8(allocator, value) },
        },
    );

    // `apply` rather than `commit`: it writes on a background thread and
    // returns void, so a failure is not observable here — which is exactly
    // what the shim's resolve already promises regardless.
    try j.callVoidMethodA(editor, try j.methodId(editor_cls, "apply", "()V"), &.{});
}

/// `prefs.edit().remove(key).apply()`.
pub fn remove(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    group: []const u8,
    key: []const u8,
) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const prefs = try openPrefs(j, allocator, activity, group);
    const editor = try editorFor(j, prefs);
    const editor_cls = try j.objectClass(editor);

    _ = try j.callObjectMethodA(
        editor,
        try j.methodId(
            editor_cls,
            "remove",
            "(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;",
        ),
        &.{.{ .l = try j.newStringUtf8(allocator, key) }},
    );
    try j.callVoidMethodA(editor, try j.methodId(editor_cls, "apply", "()V"), &.{});
}

/// `prefs.getString(key, null)`, null included.
///
/// The caller owns the returned bytes; null means the key is absent, which is
/// the answer the page gets as `{value: null}` rather than as a rejection.
pub fn get(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    group: []const u8,
    key: []const u8,
) !?[]u8 {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const prefs = try openPrefs(j, allocator, activity, group);
    const value = try j.callObjectMethodA(
        prefs,
        try j.methodId(
            try j.objectClass(prefs),
            "getString",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
        ),
        &.{ .{ .l = try j.newStringUtf8(allocator, key) }, .{ .l = null } },
    );

    if (value == null) return null;
    return try j.stringToUtf8(allocator, value);
}

fn editorFor(j: Jni, prefs: jobject) !jobject {
    return j.callObjectMethod(
        prefs,
        try j.methodId(
            try j.objectClass(prefs),
            "edit",
            "()Landroid/content/SharedPreferences$Editor;",
        ),
    );
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the preferences file is named the way the shim names it" {
    const plain = try prefsName(testing.allocator, "");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("craft_shared", plain);

    const grouped = try prefsName(testing.allocator, "team");
    defer testing.allocator.free(grouped);
    try testing.expectEqualStrings("craft_shared_team", grouped);

    // `isNotEmpty()` is a length check, not a blank check — a group of one
    // space is a group, and its file is named with the space in it.
    const spaced = try prefsName(testing.allocator, " ");
    defer testing.allocator.free(spaced);
    try testing.expectEqualStrings("craft_shared_ ", spaced);
}

test "the name is NUL-terminated, because FindClass's neighbour needs it" {
    // `NewStringUTF` takes a C string. A slice that merely looks right here
    // would read past the end at the call site instead.
    const name = try prefsName(testing.allocator, "team");
    defer testing.allocator.free(name);
    try testing.expectEqual(@as(u8, 0), name.ptr[name.len]);
}

test "a set or remove resolves with the key it was given" {
    const payload = try successPayload(testing.allocator, "token");
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("{\"success\":true,\"key\":\"token\"}", payload);
}

test "a get resolves with the value, or with a JSON null" {
    const found = try valuePayload(testing.allocator, "token", "abc");
    defer testing.allocator.free(found);
    try testing.expectEqualStrings("{\"value\":\"abc\",\"key\":\"token\"}", found);

    // The absent case is a resolve, not a rejection: a page reading a key it
    // never wrote has done nothing wrong.
    const missing = try valuePayload(testing.allocator, "token", null);
    defer testing.allocator.free(missing);
    try testing.expectEqualStrings("{\"value\":null,\"key\":\"token\"}", missing);

    // And an empty string is not the absent case.
    const empty = try valuePayload(testing.allocator, "token", "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("{\"value\":\"\",\"key\":\"token\"}", empty);
}

test "a key or value carrying a quote survives as JSON" {
    // Both are page text, and both go through the reply channel — the same
    // shape that hung the promise before #154 was fixed.
    const payload = try valuePayload(testing.allocator, "it's", "a \"quoted\" value\nwith a newline");
    defer testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("it's", parsed.value.object.get("key").?.string);
    try testing.expectEqualStrings(
        "a \"quoted\" value\nwith a newline",
        parsed.value.object.get("value").?.string,
    );

    const success = try successPayload(testing.allocator, "it's");
    defer testing.allocator.free(success);
    var parsed_success = try std.json.parseFromSlice(std.json.Value, testing.allocator, success, .{});
    defer parsed_success.deinit();
    try testing.expectEqualStrings("it's", parsed_success.value.object.get("key").?.string);
    try testing.expect(parsed_success.value.object.get("success").?.bool);
}

test "MODE_PRIVATE is zero" {
    // A compile-time constant in Java, so the shim's DEX holds the literal.
    try testing.expectEqual(@as(i32, 0), mode_private);
}

test "the actions and globals match the shim exactly" {
    try testing.expectEqualStrings("setSharedItem", A.set_shared_item);
    try testing.expectEqualStrings("getSharedItem", A.get_shared_item);
    try testing.expectEqualStrings("removeSharedItem", A.remove_shared_item);
    try testing.expectEqualStrings("_craftSharedKeychainResolve", resolve_global);
    try testing.expectEqualStrings("_craftSharedKeychainReject", reject_global);
}
