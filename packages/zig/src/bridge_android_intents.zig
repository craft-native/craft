//! The Android actions that hand something to another app: `openURL` and
//! `share`.
//!
//! Both build an `Intent` and call `startActivity`, which is why they are one
//! module — they share every JNI call between them, and the only thing that
//! differs is which extras go on the intent.
//!
//! ## Neither reports whether anything happened
//!
//! `startActivity` throws `ActivityNotFoundException` when nothing on the
//! device handles the intent, and the Kotlin's `openURL` catches it and answers
//! `false`. That is the *only* failure either action can see. Once another app
//! is launched, whether the user did anything with it is unobservable from
//! here — `share` in particular returns before the chooser is even drawn.
//!
//! So `true` means "the intent was accepted", never "the user shared
//! something", and a page that treats it as the latter is wrong on both
//! platforms. Kept as-is rather than improved: the shim's answer is the
//! contract while the shim still exists.
//!
//! ## `share` has one branch, and it is the empty title
//!
//! `putExtra(EXTRA_SUBJECT, …)` is skipped when the title is empty, and that
//! is not cosmetic: an empty subject on a mail intent produces a message whose
//! subject line is blank rather than absent, and some clients then refuse to
//! send it. The Kotlin guards it and so does this.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

/// The action names, spelled exactly as `CraftBridge.kt` spells them.
pub const A = struct {
    pub const open_url = "openURL";
    pub const share = "share";
};

/// A `String` constant off `android.content.Intent` — `ACTION_VIEW`,
/// `EXTRA_TEXT` and friends.
///
/// Read rather than spelled, for the reason the clipboard module gives for
/// `CLIPBOARD_SERVICE`: these are stable values, and a stable value copied
/// into another language is one that can only ever be wrong later.
fn intentConstant(j: Jni, intent_cls: jni.jclass, name: [*:0]const u8) !jobject {
    return j.staticObjectField(
        intent_cls,
        try j.staticFieldId(intent_cls, name, "Ljava/lang/String;"),
    );
}

/// `activity.startActivity(intent)`.
fn startActivity(j: Jni, activity: jobject, intent: jobject) !void {
    const activity_cls = try j.objectClass(activity);
    try j.callVoidMethodA(
        activity,
        try j.methodId(activity_cls, "startActivity", "(Landroid/content/Intent;)V"),
        &.{.{ .l = intent }},
    );
}

/// `startActivity(Intent(ACTION_VIEW, Uri.parse(url)))`.
///
/// `Uri.parse` does not validate and does not throw — it accepts anything and
/// produces a Uri with a null scheme for nonsense. The failure that matters
/// comes later, from `startActivity` finding nothing to handle the result, and
/// that arrives here as `JavaException` from the `check` after the call.
pub fn openUrl(j: Jni, activity: jobject, url: [*:0]const u8) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const uri_cls = try j.findClass("android/net/Uri");
    const url_string = try j.newStringUtf(url);
    const uri = try j.callStaticObjectMethodA(
        uri_cls,
        try j.staticMethodId(uri_cls, "parse", "(Ljava/lang/String;)Landroid/net/Uri;"),
        &.{.{ .l = url_string }},
    );

    const intent_cls = try j.findClass("android/content/Intent");
    const action = try intentConstant(j, intent_cls, "ACTION_VIEW");
    const intent = try j.newObjectA(
        intent_cls,
        try j.methodId(intent_cls, "<init>", "(Ljava/lang/String;Landroid/net/Uri;)V"),
        &.{ .{ .l = action }, .{ .l = uri } },
    );

    try startActivity(j, activity, intent);
}

/// `startActivity(Intent.createChooser(Intent(ACTION_SEND)…, "Share"))`.
///
/// An empty `title` skips `EXTRA_SUBJECT` entirely rather than setting it to
/// the empty string — see the module comment.
pub fn share(j: Jni, activity: jobject, text: [*:0]const u8, title: [*:0]const u8) !void {
    try j.pushLocalFrame(24);
    defer _ = j.popLocalFrame(null);

    const intent_cls = try j.findClass("android/content/Intent");
    const action = try intentConstant(j, intent_cls, "ACTION_SEND");
    const intent = try j.newObjectA(
        intent_cls,
        try j.methodId(intent_cls, "<init>", "(Ljava/lang/String;)V"),
        &.{.{ .l = action }},
    );

    // `setType` and `putExtra` both return the intent for chaining, which the
    // Kotlin's `apply` block hides. The returns are discarded here: they are
    // the same object, and keeping them would suggest otherwise.
    const plain = try j.newStringUtf("text/plain");
    _ = try j.callObjectMethodA(
        intent,
        try j.methodId(intent_cls, "setType", "(Ljava/lang/String;)Landroid/content/Intent;"),
        &.{.{ .l = plain }},
    );

    const put_extra = try j.methodId(
        intent_cls,
        "putExtra",
        "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;",
    );

    const extra_text = try intentConstant(j, intent_cls, "EXTRA_TEXT");
    const body = try j.newStringUtf(text);
    _ = try j.callObjectMethodA(intent, put_extra, &.{ .{ .l = extra_text }, .{ .l = body } });

    if (title[0] != 0) {
        const extra_subject = try intentConstant(j, intent_cls, "EXTRA_SUBJECT");
        const subject = try j.newStringUtf(title);
        _ = try j.callObjectMethodA(intent, put_extra, &.{ .{ .l = extra_subject }, .{ .l = subject } });
    }

    // The chooser label is the Kotlin's `"Share"`, and it is what the user
    // reads at the top of the sheet.
    const chooser_label = try j.newStringUtf("Share");
    const chooser = try j.callStaticObjectMethodA(
        intent_cls,
        try j.staticMethodId(
            intent_cls,
            "createChooser",
            "(Landroid/content/Intent;Ljava/lang/CharSequence;)Landroid/content/Intent;",
        ),
        &.{ .{ .l = intent }, .{ .l = chooser_label } },
    );

    try startActivity(j, activity, chooser);
}

// =============================================================================
// Tests
//
// The same fake-JVM shape the clipboard module uses: `GetMethodID` hands back
// the method name as the id, so one Call can stand in for many and the test
// can record the sequence rather than guess at it.
// =============================================================================

const testing = std.testing;

var fake_storage: [16]u8 = undefined;
var fake_calls: std.ArrayListUnmanaged([]const u8) = .empty;
var fake_field_names: std.ArrayListUnmanaged([]const u8) = .empty;
var fake_strings: std.ArrayListUnmanaged([]const u8) = .empty;
var fake_throw_on_start = false;
var fake_pending: jobject = null;

fn obj(tag: usize) jobject {
    return @ptrCast(&fake_storage[tag]);
}
fn nameOf(id: ?*anyopaque) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(id.?)));
}

fn fFindClass(_: jni.JNIEnv, _: [*:0]const u8) callconv(.c) jni.jclass {
    return obj(0);
}
fn fObjectClass(_: jni.JNIEnv, _: jobject) callconv(.c) jni.jclass {
    return obj(0);
}
fn fMethodId(_: jni.JNIEnv, _: jni.jclass, name: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jmethodID {
    return @ptrCast(@constCast(name));
}
fn fStaticFieldId(_: jni.JNIEnv, _: jni.jclass, name: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jfieldID {
    fake_field_names.append(testing.allocator, std.mem.span(name)) catch {};
    return obj(1);
}
fn fStaticObjectField(_: jni.JNIEnv, _: jni.jclass, _: jni.jfieldID) callconv(.c) jobject {
    return obj(2);
}
fn fNewStringUTF(_: jni.JNIEnv, text: [*:0]const u8) callconv(.c) jni.jstring {
    fake_strings.append(testing.allocator, std.mem.span(text)) catch {};
    return obj(3);
}
fn fCallStaticObjectMethodA(_: jni.JNIEnv, _: jni.jclass, id: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) jobject {
    fake_calls.append(testing.allocator, nameOf(id)) catch {};
    return obj(4);
}
fn fCallObjectMethodA(_: jni.JNIEnv, _: jobject, id: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) jobject {
    fake_calls.append(testing.allocator, nameOf(id)) catch {};
    return obj(5);
}
fn fNewObjectA(_: jni.JNIEnv, _: jni.jclass, id: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) jobject {
    fake_calls.append(testing.allocator, nameOf(id)) catch {};
    return obj(6);
}
fn fCallVoidMethodA(_: jni.JNIEnv, _: jobject, id: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) void {
    fake_calls.append(testing.allocator, nameOf(id)) catch {};
    if (fake_throw_on_start) fake_pending = obj(7);
}
fn fExceptionOccurred(_: jni.JNIEnv) callconv(.c) jobject {
    return fake_pending;
}
fn fExceptionDescribe(_: jni.JNIEnv) callconv(.c) void {}
fn fExceptionClear(_: jni.JNIEnv) callconv(.c) void {
    fake_pending = null;
}
fn fDeleteLocalRef(_: jni.JNIEnv, _: jobject) callconv(.c) void {}
fn fPush(_: jni.JNIEnv, _: jni.jint) callconv(.c) jni.jint {
    return 0;
}
fn fPop(_: jni.JNIEnv, keep: jobject) callconv(.c) jobject {
    return keep;
}

fn fakeEnv(table: *jni.JNINativeInterface) void {
    table.* = std.mem.zeroes(jni.JNINativeInterface);
    table.FindClass = @ptrCast(&fFindClass);
    table.GetObjectClass = @ptrCast(&fObjectClass);
    table.GetMethodID = @ptrCast(&fMethodId);
    table.GetStaticMethodID = @ptrCast(&fMethodId);
    table.GetStaticFieldID = @ptrCast(&fStaticFieldId);
    table.GetStaticObjectField = @ptrCast(&fStaticObjectField);
    table.NewStringUTF = @ptrCast(&fNewStringUTF);
    table.CallStaticObjectMethodA = @ptrCast(&fCallStaticObjectMethodA);
    table.CallObjectMethodA = @ptrCast(&fCallObjectMethodA);
    table.NewObjectA = @ptrCast(&fNewObjectA);
    table.CallVoidMethodA = @ptrCast(&fCallVoidMethodA);
    table.ExceptionOccurred = @ptrCast(&fExceptionOccurred);
    table.ExceptionDescribe = @ptrCast(&fExceptionDescribe);
    table.ExceptionClear = @ptrCast(&fExceptionClear);
    table.DeleteLocalRef = @ptrCast(&fDeleteLocalRef);
    table.PushLocalFrame = @ptrCast(&fPush);
    table.PopLocalFrame = @ptrCast(&fPop);
}

fn resetFakes() void {
    fake_calls.clearRetainingCapacity();
    fake_field_names.clearRetainingCapacity();
    fake_strings.clearRetainingCapacity();
    fake_throw_on_start = false;
    fake_pending = null;
}

fn freeFakes() void {
    fake_calls.deinit(testing.allocator);
    fake_field_names.deinit(testing.allocator);
    fake_strings.deinit(testing.allocator);
    fake_calls = .empty;
    fake_field_names = .empty;
    fake_strings = .empty;
}

fn sawCall(name: []const u8) bool {
    for (fake_calls.items) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}
fn sawString(text: []const u8) bool {
    for (fake_strings.items) |c| if (std.mem.eql(u8, c, text)) return true;
    return false;
}
fn sawField(name: []const u8) bool {
    for (fake_field_names.items) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

test "openURL parses the url and hands the intent to the activity" {
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try openUrl(Jni.init(&ptr), obj(8), "https://example.com/x?y=1");

    try testing.expect(sawCall("parse"));
    try testing.expect(sawCall("<init>"));
    try testing.expect(sawCall("startActivity"));
    // The action is read off Intent rather than spelled as a string literal.
    try testing.expect(sawField("ACTION_VIEW"));
    try testing.expect(sawString("https://example.com/x?y=1"));
}

test "a URL nothing can open reports the exception rather than success" {
    // `Uri.parse` accepts anything, so the only failure either action sees is
    // startActivity finding no handler — ActivityNotFoundException, which the
    // Kotlin catches and answers false for.
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    fake_throw_on_start = true;
    try testing.expectError(
        jni.JniError.JavaException,
        openUrl(Jni.init(&ptr), obj(8), "definitely-not-a-scheme://x"),
    );
}

test "share sets the text extra and the chooser" {
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try share(Jni.init(&ptr), obj(8), "hello", "Subject");

    try testing.expect(sawField("ACTION_SEND"));
    try testing.expect(sawField("EXTRA_TEXT"));
    try testing.expect(sawField("EXTRA_SUBJECT"));
    try testing.expect(sawCall("setType"));
    try testing.expect(sawCall("putExtra"));
    try testing.expect(sawCall("createChooser"));
    try testing.expect(sawCall("startActivity"));
    try testing.expect(sawString("text/plain"));
    try testing.expect(sawString("Share"));
}

test "an empty title omits the subject rather than setting it empty" {
    // The one branch in either action. An empty EXTRA_SUBJECT produces a mail
    // draft with a blank subject line rather than none, and some clients then
    // refuse to send it — so "skip" and "set to empty" are different outcomes.
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try share(Jni.init(&ptr), obj(8), "hello", "");

    try testing.expect(sawField("EXTRA_TEXT"));
    try testing.expect(!sawField("EXTRA_SUBJECT"));
    // And the rest of the intent is still built.
    try testing.expect(sawCall("createChooser"));
    try testing.expect(sawCall("startActivity"));
}

test "the action names match the Kotlin methods exactly" {
    try testing.expectEqualStrings("openURL", A.open_url);
    try testing.expectEqualStrings("share", A.share);
}
