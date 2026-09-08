//! `cancelNotification` and `cancelAllNotifications` on Android.
//!
//! ## The id is hashed by Java, not by Zig
//!
//! `NotificationManager.cancel` takes an `int`, and the page sends a string —
//! so the Kotlin cancels `id.hashCode()`. Getting that number wrong cancels a
//! different notification or none at all, silently either way.
//!
//! Zig could reimplement it: `h = 31*h + c` over the characters, wrapping at
//! 32 bits. It does not, and the reason is not effort. Java hashes **UTF-16
//! code units**, so a notification id carrying an emoji is two surrogate units
//! there and four bytes in the UTF-8 this bridge otherwise works in — and the
//! two produce different numbers. Reproducing that means converting back to
//! UTF-16 first, which is reimplementing the encoding to reimplement the hash.
//!
//! Calling `hashCode()` on the `jstring` the JVM already holds cannot diverge.
//! It costs one JNI call on a path that makes four, and it is the same
//! judgement `bridge_android_securestore.zig` makes about the store: where the
//! platform already has the thing, ask it rather than rebuild it.
//!
//! The cost is that nothing here is host-testable, and that is the honest
//! trade — a test of a hash this file does not compute would be testing a
//! second implementation that does not ship.
//!
//! ## Cancelling an unknown id is a no-op that still succeeds
//!
//! `cancel` ignores an id it does not have, and so does the Kotlin. That
//! matches the iOS notification cancels next door, which document the same
//! idempotence for the same reason: a page clearing a notification it already
//! dismissed has done nothing wrong.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const cancel_notification = "cancelNotification";
    pub const cancel_all_notifications = "cancelAllNotifications";
};

/// `activity.getSystemService(Context.NOTIFICATION_SERVICE)`.
fn notificationManager(j: Jni, activity: jobject) !jobject {
    const context_cls = try j.findClass("android/content/Context");
    const name = try j.staticObjectField(
        context_cls,
        try j.staticFieldId(context_cls, "NOTIFICATION_SERVICE", "Ljava/lang/String;"),
    );

    const activity_cls = try j.objectClass(activity);
    return j.callObjectMethodA(
        activity,
        try j.methodId(activity_cls, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;"),
        &.{.{ .l = name }},
    );
}

/// `notificationManager.cancel(id.hashCode())`.
///
/// Takes the `jstring` rather than a Zig slice on purpose: the hash has to
/// come from the Java object, and converting to UTF-8 first would throw away
/// exactly the representation the hash is defined over.
pub fn cancel(j: Jni, activity: jobject, id: jni.jstring) !void {
    if (id == null) return jni.JniError.NullReference;

    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const id_cls = try j.objectClass(id);
    const hash = try j.callIntMethod(id, try j.methodId(id_cls, "hashCode", "()I"));

    const manager = try notificationManager(j, activity);
    const manager_cls = try j.objectClass(manager);
    try j.callVoidMethodA(
        manager,
        try j.methodId(manager_cls, "cancel", "(I)V"),
        &.{.{ .i = hash }},
    );
}

/// `notificationManager.cancelAll()`.
pub fn cancelAll(j: Jni, activity: jobject) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const manager = try notificationManager(j, activity);
    const manager_cls = try j.objectClass(manager);
    try j.callVoidMethodA(
        manager,
        try j.methodId(manager_cls, "cancelAll", "()V"),
        &.{},
    );
}

// =============================================================================
// Tests
//
// A fake NotificationManager, because the one thing worth pinning here is the
// *sequence*: the id must be hashed by Java and the result handed to `cancel`,
// rather than any other integer reaching it.
// =============================================================================

const testing = std.testing;

var fake_storage: [8]u8 = undefined;
var fake_cancelled_with: jni.jint = 0;
var fake_cancel_all_called = false;
var fake_hash: jni.jint = 0;

fn cobj(tag: usize) jobject {
    return @ptrCast(&fake_storage[tag]);
}
fn cName(id: ?*anyopaque) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(id.?)));
}
fn cFindClass(_: jni.JNIEnv, _: [*:0]const u8) callconv(.c) jni.jclass {
    return cobj(0);
}
fn cObjectClass(_: jni.JNIEnv, _: jobject) callconv(.c) jni.jclass {
    return cobj(0);
}
fn cStaticFieldId(_: jni.JNIEnv, _: jni.jclass, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jfieldID {
    return cobj(1);
}
fn cStaticObjectField(_: jni.JNIEnv, _: jni.jclass, _: jni.jfieldID) callconv(.c) jobject {
    return cobj(2);
}
fn cMethodId(_: jni.JNIEnv, _: jni.jclass, name: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jmethodID {
    return @ptrCast(@constCast(name));
}
fn cCallIntMethod(_: jni.JNIEnv, _: jobject, id: jni.jmethodID) callconv(.c) jni.jint {
    // Only `hashCode` reaches here, and answering something recognisable is
    // what lets the assertion below be about the wiring rather than the value.
    if (std.mem.eql(u8, cName(id), "hashCode")) return fake_hash;
    return 0;
}
fn cCallObjectMethodA(_: jni.JNIEnv, _: jobject, _: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) jobject {
    return cobj(3);
}
fn cCallVoidMethodA(_: jni.JNIEnv, _: jobject, id: jni.jmethodID, args: [*]const jni.jvalue) callconv(.c) void {
    const name = cName(id);
    if (std.mem.eql(u8, name, "cancel")) fake_cancelled_with = args[0].i;
    if (std.mem.eql(u8, name, "cancelAll")) fake_cancel_all_called = true;
}
fn cExceptionOccurred(_: jni.JNIEnv) callconv(.c) jobject {
    return null;
}
fn cPush(_: jni.JNIEnv, _: jni.jint) callconv(.c) jni.jint {
    return 0;
}
fn cPop(_: jni.JNIEnv, keep: jobject) callconv(.c) jobject {
    return keep;
}

fn fakeEnv(table: *jni.JNINativeInterface) void {
    table.* = std.mem.zeroes(jni.JNINativeInterface);
    table.FindClass = @ptrCast(&cFindClass);
    table.GetObjectClass = @ptrCast(&cObjectClass);
    table.GetStaticFieldID = @ptrCast(&cStaticFieldId);
    table.GetStaticObjectField = @ptrCast(&cStaticObjectField);
    table.GetMethodID = @ptrCast(&cMethodId);
    table.CallIntMethod = @ptrCast(&cCallIntMethod);
    table.CallObjectMethodA = @ptrCast(&cCallObjectMethodA);
    table.CallVoidMethodA = @ptrCast(&cCallVoidMethodA);
    table.ExceptionOccurred = @ptrCast(&cExceptionOccurred);
    table.PushLocalFrame = @ptrCast(&cPush);
    table.PopLocalFrame = @ptrCast(&cPop);
    fake_cancelled_with = 0;
    fake_cancel_all_called = false;
}

test "the id Java hashed is the id that gets cancelled" {
    // The claim worth pinning: `cancel` receives `hashCode()`'s answer and not
    // some other integer. A version that passed a length, an index, or a hash
    // Zig computed itself would cancel a different notification — silently,
    // because cancelling an id that does not exist succeeds.
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    fake_hash = -1_234_567;
    try cancel(Jni.init(&ptr), cobj(4), cobj(5));
    try testing.expectEqual(@as(jni.jint, -1_234_567), fake_cancelled_with);

    // Negative hashes are ordinary — Java's is a signed 32-bit wrap — so the
    // value must survive the trip unchanged rather than being made positive.
    fake_hash = 0;
    try cancel(Jni.init(&ptr), cobj(4), cobj(5));
    try testing.expectEqual(@as(jni.jint, 0), fake_cancelled_with);
}

test "a null id is refused rather than cancelling notification zero" {
    // `hashCode()` on null would throw, but the JNI call would have been made
    // first — and an unchecked null here reaches `cancel(0)`, which quietly
    // cancels whatever notification hashes to zero.
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try testing.expectError(jni.JniError.NullReference, cancel(Jni.init(&ptr), cobj(4), null));
    try testing.expectEqual(@as(jni.jint, 0), fake_cancelled_with);
}

test "cancelAll asks for cancelAll, not a cancel with some id" {
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try cancelAll(Jni.init(&ptr), cobj(4));
    try testing.expect(fake_cancel_all_called);
}

test "the action names match the Kotlin methods exactly" {
    try testing.expectEqualStrings("cancelNotification", A.cancel_notification);
    try testing.expectEqualStrings("cancelAllNotifications", A.cancel_all_notifications);
}
