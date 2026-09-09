//! Runtime permissions, the two calls every guarded action starts with.
//!
//! The Kotlin reaches these through AndroidX:
//!
//! ```kotlin
//! if (ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_CALENDAR)
//!     != PackageManager.PERMISSION_GRANTED) {
//!     ActivityCompat.requestPermissions(activity, arrayOf(...), REQUEST_CALENDAR)
//! ```
//!
//! Zig calls the framework methods those two delegate to. That is not a
//! shortcut around a dependency — `ContextCompat.checkSelfPermission` *is*
//! `Context.checkSelfPermission` from API 23, and `ActivityCompat`'s
//! `requestPermissions` is `Activity.requestPermissions` from the same level,
//! with the pre-23 branches dead on any modern `minSdk`. Going through the
//! framework also means no `androidx.core` on the JNI side, which matters
//! because `libcraft.so` is built with no NDK and links nothing.
//!
//! ## Which thread
//!
//! `requestPermissions` is documented as main-thread, and this is called from
//! the WebView's JavaBridge thread — because the shim calls it from there too.
//! Hoisting it onto the main looper here would be a divergence, and a silent
//! one: the two would then differ in when the dialog appears relative to the
//! rejection the page already received.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

/// `PackageManager.PERMISSION_GRANTED`.
///
/// A compile-time constant in Java, so the shim's DEX holds the literal `0`
/// rather than a field read — which is why it is a literal here as well.
pub const granted: i32 = 0;

pub const read_calendar = "android.permission.READ_CALENDAR";
pub const write_calendar = "android.permission.WRITE_CALENDAR";
pub const read_contacts = "android.permission.READ_CONTACTS";

/// `activity.checkSelfPermission(permission) == PERMISSION_GRANTED`.
pub fn isGranted(j: Jni, activity: jobject, permission: [*:0]const u8) !bool {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const name = try j.newStringUtf(permission);
    const activity_cls = try j.objectClass(activity);
    const result = try j.callIntMethodA(
        activity,
        try j.methodId(activity_cls, "checkSelfPermission", "(Ljava/lang/String;)I"),
        &.{.{ .l = name }},
    );
    return result == granted;
}

/// `activity.requestPermissions(new String[]{permission}, code)`.
///
/// The result arrives at `onRequestPermissionsResult`, which the shim does not
/// implement for these codes — so the request is what makes the *next* call
/// succeed, and this one still fails. That is the shim's behaviour and the
/// reason the caller rejects immediately after.
pub fn request(j: Jni, activity: jobject, permission: [*:0]const u8, code: i32) !void {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const string_cls = try j.findClass("java/lang/String");
    const names = try j.newObjectArray(1, string_cls);
    try j.setObjectArrayElement(names, 0, try j.newStringUtf(permission));

    const activity_cls = try j.objectClass(activity);
    try j.callVoidMethodA(
        activity,
        try j.methodId(activity_cls, "requestPermissions", "([Ljava/lang/String;I)V"),
        &.{ .{ .l = names }, .{ .i = code } },
    );
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the permission names match Manifest.permission exactly" {
    // `Manifest.permission.READ_CALENDAR` is a compile-time constant, so the
    // shim compares against these exact strings. A typo here is a permission
    // that is never granted and an action that always rejects.
    try testing.expectEqualStrings("android.permission.READ_CALENDAR", read_calendar);
    try testing.expectEqualStrings("android.permission.WRITE_CALENDAR", write_calendar);
    try testing.expectEqualStrings("android.permission.READ_CONTACTS", read_contacts);
}

test "PERMISSION_GRANTED is zero, and PERMISSION_DENIED is not" {
    // -1 is PERMISSION_DENIED. The comparison is `== granted` rather than
    // `!= denied` because a future third value would then read as granted.
    try testing.expectEqual(@as(i32, 0), granted);
    try testing.expect(granted != -1);
}
