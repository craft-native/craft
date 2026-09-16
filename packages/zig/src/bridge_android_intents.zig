//! The Android actions that hand something to another app: `openURL` and
//! `share`.
//!
//! Both build an `Intent` and call `startActivity`, which is why they are one
//! module — they share every JNI call between them, and the only thing that
//! differs is which extras go on the intent.
//!
//! ## What each one can find out
//!
//! `startActivity` throws `ActivityNotFoundException` when nothing on the
//! device handles the intent, and the Kotlin's `openURL` catches it and answers
//! `false`. That is the only failure `openURL` can see: once another app is
//! launched, whether the user did anything with it is unobservable from here.
//!
//! `share` can find out one thing more, and has to, because the page's promise
//! resolves with it (#203). The chooser reports a pick through the
//! `IntentSender` passed to `createChooser`, and reports a dismissal not at
//! all. Its activity result arrives in both cases, and is `RESULT_CANCELED` in
//! both. So neither signal answers alone, and the Kotlin combines them: the
//! sender marks a pick, and the result, which always comes, settles the promise
//! with whatever was marked. This module launches the chooser with both halves
//! wired. It does not own either, which is why the sender and the request code
//! arrive as arguments rather than being built here: `CraftBridge` receives the
//! result, so `CraftBridge` chooses the code it routes on.
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
pub fn openUrl(j: Jni, allocator: std.mem.Allocator, activity: jobject, url: []const u8) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const uri_cls = try j.findClass("android/net/Uri");
    const url_string = try j.newStringUtf8(allocator, url);
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

/// `startActivityForResult(Intent.createChooser(Intent(ACTION_SEND)…, "Share", chosen), request_code)`.
///
/// An empty `title` skips `EXTRA_SUBJECT` entirely rather than setting it to
/// the empty string — see the module comment. `chosen` is the `IntentSender`
/// the chooser fires when the person picks an app, and `request_code` is the
/// one `CraftBridge.onActivityResult` settles the page's promise on.
pub fn share(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    text: []const u8,
    title: []const u8,
    chosen: jobject,
    request_code: i32,
) !void {
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
    const body = try j.newStringUtf8(allocator, text);
    _ = try j.callObjectMethodA(intent, put_extra, &.{ .{ .l = extra_text }, .{ .l = body } });

    if (title.len != 0) {
        const extra_subject = try intentConstant(j, intent_cls, "EXTRA_SUBJECT");
        const subject = try j.newStringUtf8(allocator, title);
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
            "(Landroid/content/Intent;Ljava/lang/CharSequence;Landroid/content/IntentSender;)Landroid/content/Intent;",
        ),
        &.{ .{ .l = intent }, .{ .l = chooser_label }, .{ .l = chosen } },
    );

    // For a result, not a plain start: the result is the only signal that
    // arrives when the person dismisses the chooser, and without it the page's
    // promise would wait for a pick that is never coming.
    const activity_cls = try j.objectClass(activity);
    try j.callVoidMethodA(
        activity,
        try j.methodId(activity_cls, "startActivityForResult", "(Landroid/content/Intent;I)V"),
        &.{ .{ .l = chooser }, .{ .i = request_code } },
    );
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
/// The last arguments `createChooser` and `startActivityForResult` received.
var fake_chooser_sender: jobject = null;
var fake_request_code: ?jni.jint = null;

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
    // Copied, not borrowed. The caller re-encodes into a scratch buffer and
    // frees it as soon as the JVM has the string — which is what a real
    // `NewStringUTF` licenses, and what made this fake read freed memory when
    // it held the pointer.
    const copy = testing.allocator.dupe(u8, std.mem.span(text)) catch return obj(3);
    fake_strings.append(testing.allocator, copy) catch testing.allocator.free(copy);
    return obj(3);
}
fn fCallStaticObjectMethodA(_: jni.JNIEnv, _: jni.jclass, id: jni.jmethodID, args: [*]const jni.jvalue) callconv(.c) jobject {
    fake_calls.append(testing.allocator, nameOf(id)) catch {};
    if (std.mem.eql(u8, nameOf(id), "createChooser")) fake_chooser_sender = args[2].l;
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
fn fCallVoidMethodA(_: jni.JNIEnv, _: jobject, id: jni.jmethodID, args: [*]const jni.jvalue) callconv(.c) void {
    fake_calls.append(testing.allocator, nameOf(id)) catch {};
    if (std.mem.eql(u8, nameOf(id), "startActivityForResult")) fake_request_code = args[1].i;
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
    for (fake_strings.items) |text| testing.allocator.free(text);
    fake_strings.clearRetainingCapacity();
    fake_throw_on_start = false;
    fake_pending = null;
    fake_chooser_sender = null;
    fake_request_code = null;
}

fn freeFakes() void {
    fake_calls.deinit(testing.allocator);
    fake_field_names.deinit(testing.allocator);
    for (fake_strings.items) |text| testing.allocator.free(text);
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

    try openUrl(Jni.init(&ptr), testing.allocator, obj(8), "https://example.com/x?y=1");

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
        openUrl(Jni.init(&ptr), testing.allocator, obj(8), "definitely-not-a-scheme://x"),
    );
}

test "share sets the text extra and the chooser" {
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try share(Jni.init(&ptr), testing.allocator, obj(8), "hello", "Subject", obj(9), 1011);

    try testing.expect(sawField("ACTION_SEND"));
    try testing.expect(sawField("EXTRA_TEXT"));
    try testing.expect(sawField("EXTRA_SUBJECT"));
    try testing.expect(sawCall("setType"));
    try testing.expect(sawCall("putExtra"));
    try testing.expect(sawCall("createChooser"));
    try testing.expect(sawString("text/plain"));
    try testing.expect(sawString("Share"));
}

test "share launches for a result, with the sender and code it was given" {
    // Both halves of how the page learns what happened. A plain startActivity
    // gets no result, so a dismissed chooser would leave the promise waiting
    // for ever; a chooser without the sender reports no pick, so every share
    // would resolve false.
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try share(Jni.init(&ptr), testing.allocator, obj(8), "hello", "", obj(9), 1011);

    try testing.expect(sawCall("startActivityForResult"));
    try testing.expect(!sawCall("startActivity"));
    try testing.expectEqual(obj(9), fake_chooser_sender);
    try testing.expectEqual(@as(?jni.jint, 1011), fake_request_code);
}

test "a chooser that cannot start reports the exception rather than success" {
    // CraftBridge rejects the page's promise on this; swallowing it would
    // leave the promise waiting on a result for an activity that never began.
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    fake_throw_on_start = true;
    try testing.expectError(
        jni.JniError.JavaException,
        share(Jni.init(&ptr), testing.allocator, obj(8), "hello", "", obj(9), 1011),
    );
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

    try share(Jni.init(&ptr), testing.allocator, obj(8), "hello", "", obj(9), 1011);

    try testing.expect(sawField("EXTRA_TEXT"));
    try testing.expect(!sawField("EXTRA_SUBJECT"));
    // And the rest of the intent is still built.
    try testing.expect(sawCall("createChooser"));
    try testing.expect(sawCall("startActivityForResult"));
}

test "the action names match the Kotlin methods exactly" {
    try testing.expectEqualStrings("openURL", A.open_url);
    try testing.expectEqualStrings("share", A.share);
}
