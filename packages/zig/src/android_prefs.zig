//! `SharedPreferences`, which three actions now reach for.
//!
//! The shim opens a preferences file by name in five places — the shared-item
//! trio, the widget data, the voice actions — and each does the same four
//! calls: `getSharedPreferences`, `edit`, `putString`/`remove`, `apply`. This
//! is that sequence once.
//!
//! What it deliberately does *not* own is the file's name. Each caller decides
//! that, because the names are the part that differs and the part that goes
//! wrong: `craft_shared_<group>` is built from page text, `craft_widget_prefs`
//! has to match what `CraftWidgetProvider` reads, and `craft_voice_actions` is
//! read by nothing else at all. A helper that also chose the name would be
//! four helpers wearing one signature.
//!
//! ## `apply`, not `commit`
//!
//! Every writer here uses `apply`: it hands the write to a background thread
//! and returns void, so a failure is not observable at the call site. That is
//! what the shim does, and it is why every one of these actions resolves with
//! a promise about having *asked* rather than about having written.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

/// `Context.MODE_PRIVATE`.
///
/// A compile-time constant in Java, so the shim's DEX holds the literal 0
/// rather than a field read — which is why it is a literal here too.
pub const mode_private: i32 = 0;

/// `activity.getSharedPreferences(name, MODE_PRIVATE)`.
///
/// `name` is a slice rather than a literal because one caller builds it from
/// page text, and it goes through `newStringUtf8` for the same reason.
pub fn open(j: Jni, allocator: std.mem.Allocator, activity: jobject, name: []const u8) !jobject {
    return j.callObjectMethodA(
        activity,
        try j.methodId(
            try j.objectClass(activity),
            "getSharedPreferences",
            "(Ljava/lang/String;I)Landroid/content/SharedPreferences;",
        ),
        &.{ .{ .l = try j.newStringUtf8(allocator, name) }, .{ .i = mode_private } },
    );
}

/// `prefs.edit()`.
pub fn edit(j: Jni, prefs: jobject) !jobject {
    return j.callObjectMethod(
        prefs,
        try j.methodId(
            try j.objectClass(prefs),
            "edit",
            "()Landroid/content/SharedPreferences$Editor;",
        ),
    );
}

/// `editor.putString(key, value)`, whose return value is the editor again.
pub fn putString(
    j: Jni,
    allocator: std.mem.Allocator,
    editor: jobject,
    key: []const u8,
    value: []const u8,
) !void {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    _ = try j.callObjectMethodA(
        editor,
        try j.methodId(
            try j.objectClass(editor),
            "putString",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;",
        ),
        &.{
            .{ .l = try j.newStringUtf8(allocator, key) },
            .{ .l = try j.newStringUtf8(allocator, value) },
        },
    );
}

/// `editor.putBoolean(key, value)`.
pub fn putBoolean(
    j: Jni,
    allocator: std.mem.Allocator,
    editor: jobject,
    key: []const u8,
    value: bool,
) !void {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    _ = try j.callObjectMethodA(
        editor,
        try j.methodId(
            try j.objectClass(editor),
            "putBoolean",
            "(Ljava/lang/String;Z)Landroid/content/SharedPreferences$Editor;",
        ),
        &.{
            .{ .l = try j.newStringUtf8(allocator, key) },
            .{ .z = if (value) jni.JNI_TRUE else jni.JNI_FALSE },
        },
    );
}

/// `editor.putLong(key, value)`.
pub fn putLong(
    j: Jni,
    allocator: std.mem.Allocator,
    editor: jobject,
    key: []const u8,
    value: i64,
) !void {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    _ = try j.callObjectMethodA(
        editor,
        try j.methodId(
            try j.objectClass(editor),
            "putLong",
            "(Ljava/lang/String;J)Landroid/content/SharedPreferences$Editor;",
        ),
        &.{ .{ .l = try j.newStringUtf8(allocator, key) }, .{ .j = value } },
    );
}

/// `editor.remove(key)`.
pub fn remove(j: Jni, allocator: std.mem.Allocator, editor: jobject, key: []const u8) !void {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    _ = try j.callObjectMethodA(
        editor,
        try j.methodId(
            try j.objectClass(editor),
            "remove",
            "(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;",
        ),
        &.{.{ .l = try j.newStringUtf8(allocator, key) }},
    );
}

/// `editor.apply()`.
pub fn apply(j: Jni, editor: jobject) !void {
    try j.callVoidMethodA(
        editor,
        try j.methodId(try j.objectClass(editor), "apply", "()V"),
        &.{},
    );
}

/// `prefs.getString(key, null)`, null included.
///
/// The caller owns the returned bytes. Null means the key is absent, which is
/// a different answer from an empty string and is kept as one.
pub fn getString(
    j: Jni,
    allocator: std.mem.Allocator,
    prefs: jobject,
    key: []const u8,
) !?[]u8 {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

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

/// `prefs.getBoolean(key, fallback)`.
pub fn getBoolean(
    j: Jni,
    allocator: std.mem.Allocator,
    prefs: jobject,
    key: []const u8,
    fallback: bool,
) !bool {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    return j.callBooleanMethodA(
        prefs,
        try j.methodId(try j.objectClass(prefs), "getBoolean", "(Ljava/lang/String;Z)Z"),
        &.{
            .{ .l = try j.newStringUtf8(allocator, key) },
            .{ .z = if (fallback) jni.JNI_TRUE else jni.JNI_FALSE },
        },
    );
}

/// `prefs.getLong(key, fallback)`.
pub fn getLong(
    j: Jni,
    allocator: std.mem.Allocator,
    prefs: jobject,
    key: []const u8,
    fallback: i64,
) !i64 {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    return j.callLongMethodA(
        prefs,
        try j.methodId(try j.objectClass(prefs), "getLong", "(Ljava/lang/String;J)J"),
        &.{ .{ .l = try j.newStringUtf8(allocator, key) }, .{ .j = fallback } },
    );
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "MODE_PRIVATE is zero" {
    // The shim's DEX holds this literal, so a field read here would be the
    // slower way to get the same number and a chance to get a different one.
    try testing.expectEqual(@as(i32, 0), mode_private);
}
