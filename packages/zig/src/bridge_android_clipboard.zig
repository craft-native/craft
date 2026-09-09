//! `clipboardRead` and `clipboardWrite` on Android.
//!
//! The first actions here that need the `Activity` — `getSystemService` is a
//! `Context` method — and the first with a null path that is not an error.
//!
//! ## `getPrimaryClip()` returning null is the normal case, not the sad one
//!
//! Since Android 10 an app may only read the clipboard while it holds focus,
//! or if it is the default input method. Everywhere else `getPrimaryClip()`
//! answers null and the system logs a line the app cannot suppress. That is
//! not a failure to report: the Kotlin returns `""` for it, and so does this.
//! An error here would turn a routine platform restriction into a rejected
//! promise on a page that did nothing wrong.
//!
//! Three states collapse to the same empty string, and the Kotlin spells all
//! three out: no clip at all, a clip holding no items, and an item whose text
//! is null. The last is reachable — a `ClipData` can carry a URI or an Intent
//! with no text representation — so it is a branch rather than a formality.
//!
//! ## `CLIPBOARD_SERVICE` is read, not spelled
//!
//! The value is `"clipboard"` and has been since API 1, so hardcoding it would
//! work. It is read off `android.content.Context` anyway, because a constant
//! copied into another language is a constant that can only ever be wrong
//! later, and reading it costs one static field access on a path that already
//! makes five calls.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

/// The action names, spelled exactly as `CraftBridge.kt` spells them.
pub const A = struct {
    pub const clipboard_read = "clipboardRead";
    pub const clipboard_write = "clipboardWrite";
};

/// `activity.getSystemService(Context.<name>)`.
///
/// Split out because both actions need it and because the constant lookup is
/// the fiddly half: `getSystemService` takes the *value* of the constant, not
/// its name, so the field has to be read before the call can be made.
fn systemService(j: Jni, activity: jobject, constant: [*:0]const u8) !jobject {
    const context_cls = try j.findClass("android/content/Context");
    const name = try j.staticObjectField(
        context_cls,
        try j.staticFieldId(context_cls, constant, "Ljava/lang/String;"),
    );

    const activity_cls = try j.objectClass(activity);
    return j.callObjectMethodA(
        activity,
        try j.methodId(
            activity_cls,
            "getSystemService",
            "(Ljava/lang/String;)Ljava/lang/Object;",
        ),
        &.{.{ .l = name }},
    );
}

/// The clipboard's first item as text, or empty when there is nothing to read.
///
/// Caller owns the result.
pub fn read(allocator: std.mem.Allocator, j: Jni, activity: jobject) ![]u8 {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const manager = try systemService(j, activity, "CLIPBOARD_SERVICE");
    const manager_cls = try j.objectClass(manager);

    const clip = try j.callObjectMethod(
        manager,
        try j.methodId(manager_cls, "getPrimaryClip", "()Landroid/content/ClipData;"),
    );
    // The Android 10 path. Not an error — see the module comment.
    if (clip == null) return allocator.dupe(u8, "");

    const clip_cls = try j.objectClass(clip);
    const count = try j.callIntMethod(
        clip,
        try j.methodId(clip_cls, "getItemCount", "()I"),
    );
    if (count <= 0) return allocator.dupe(u8, "");

    const item = try j.callObjectMethodA(
        clip,
        try j.methodId(clip_cls, "getItemAt", "(I)Landroid/content/ClipData$Item;"),
        &.{.{ .i = 0 }},
    );
    if (item == null) return allocator.dupe(u8, "");

    const item_cls = try j.objectClass(item);
    const text = try j.callObjectMethod(
        item,
        try j.methodId(item_cls, "getText", "()Ljava/lang/CharSequence;"),
    );
    // A ClipData carrying a URI or an Intent has no text, and `?.toString()`
    // in the Kotlin is what makes that an empty string rather than "null".
    if (text == null) return allocator.dupe(u8, "");

    // `toString` off the object's own class rather than off CharSequence: the
    // interface declares it, but the implementation is on String or
    // SpannableString, and asking the concrete class is what the JVM resolves
    // anyway.
    const text_cls = try j.objectClass(text);
    const string = try j.callObjectMethod(
        text,
        try j.methodId(text_cls, "toString", "()Ljava/lang/String;"),
    );
    if (string == null) return allocator.dupe(u8, "");

    return j.stringToUtf8(allocator, string);
}

/// Put `text` on the clipboard under the label the Kotlin uses.
///
/// The label is `"Craft"`, and it is user-visible: Android 13 and later show a
/// preview toast naming it. Changing it because Zig now does the writing would
/// change what the user sees.
pub fn write(j: Jni, allocator: std.mem.Allocator, activity: jobject, text: []const u8) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const manager = try systemService(j, activity, "CLIPBOARD_SERVICE");
    const manager_cls = try j.objectClass(manager);

    const clip_cls = try j.findClass("android/content/ClipData");
    const label = try j.newStringUtf("Craft");
    const value = try j.newStringUtf8(allocator, text);

    // `newPlainText` takes two CharSequences; a String is one, and the JVM
    // accepts the subtype without a cast.
    const clip = try j.callStaticObjectMethodA(
        clip_cls,
        try j.staticMethodId(
            clip_cls,
            "newPlainText",
            "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;",
        ),
        &.{ .{ .l = label }, .{ .l = value } },
    );

    try j.callVoidMethodA(
        manager,
        try j.methodId(manager_cls, "setPrimaryClip", "(Landroid/content/ClipData;)V"),
        &.{.{ .l = clip }},
    );
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the action names match the Kotlin methods exactly" {
    try testing.expectEqualStrings("clipboardRead", A.clipboard_read);
    try testing.expectEqualStrings("clipboardWrite", A.clipboard_write);
}

// --- A fake clipboard ------------------------------------------------------
//
// `read` walks six Java objects, and the branch that matters — a null clip —
// is the one a real device takes most of the time. None of that is reachable
// from a host without a JVM, except that a `JNIEnv` is a table of pointers, so
// the JVM can be written in Zig.
//
// The trick that keeps it readable: `GetMethodID` returns the method *name*
// pointer as the `jmethodID`. The id is opaque to JNI and only ever handed
// back to a Call, so the fake can read it as a string and dispatch on it —
// which is what lets one `CallObjectMethod` stand in for six real methods
// without a table of its own.

const Scenario = enum {
    /// `getPrimaryClip()` answers null. The Android 10+ default.
    no_clip,
    /// A clip with `getItemCount() == 0`.
    empty_clip,
    /// An item whose `getText()` is null — a URI or Intent clip.
    no_text,
    /// Text, present and readable.
    has_text,
};

var scenario: Scenario = .has_text;
var fake_storage: [8]u8 = undefined;
var fake_text: [*:0]const u8 = "copied";
var fake_frames_pushed: usize = 0;
var fake_frames_popped: usize = 0;

fn obj(tag: usize) jobject {
    return @ptrCast(&fake_storage[tag]);
}

fn methodName(id: jni.jmethodID) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(id.?)));
}

fn fakeFindClass(_: jni.JNIEnv, _: [*:0]const u8) callconv(.c) jni.jclass {
    return obj(0);
}
fn fakeObjectClass(_: jni.JNIEnv, _: jobject) callconv(.c) jni.jclass {
    return obj(0);
}
fn fakeStaticFieldId(_: jni.JNIEnv, _: jni.jclass, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jfieldID {
    return obj(1);
}
fn fakeStaticObjectField(_: jni.JNIEnv, _: jni.jclass, _: jni.jfieldID) callconv(.c) jobject {
    return obj(2); // the "clipboard" service name
}
fn fakeMethodId(_: jni.JNIEnv, _: jni.jclass, name: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jmethodID {
    return @ptrCast(@constCast(name));
}
fn fakeExceptionOccurred(_: jni.JNIEnv) callconv(.c) jobject {
    return null;
}
fn fakePushLocalFrame(_: jni.JNIEnv, _: jni.jint) callconv(.c) jni.jint {
    fake_frames_pushed += 1;
    return 0;
}
fn fakePopLocalFrame(_: jni.JNIEnv, keep: jobject) callconv(.c) jobject {
    fake_frames_popped += 1;
    return keep;
}

fn fakeCallObjectMethod(_: jni.JNIEnv, _: jobject, id: jni.jmethodID) callconv(.c) jobject {
    const name = methodName(id);
    if (std.mem.eql(u8, name, "getPrimaryClip"))
        return if (scenario == .no_clip) null else obj(3);
    if (std.mem.eql(u8, name, "getText"))
        return if (scenario == .no_text) null else obj(5);
    if (std.mem.eql(u8, name, "toString")) return obj(6);
    return null;
}

fn fakeCallObjectMethodA(_: jni.JNIEnv, _: jobject, id: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) jobject {
    const name = methodName(id);
    if (std.mem.eql(u8, name, "getSystemService")) return obj(4);
    if (std.mem.eql(u8, name, "getItemAt")) return obj(5);
    return null;
}

fn fakeCallIntMethod(_: jni.JNIEnv, _: jobject, id: jni.jmethodID) callconv(.c) jni.jint {
    if (std.mem.eql(u8, methodName(id), "getItemCount"))
        return if (scenario == .empty_clip) 0 else 1;
    return 0;
}

fn fakeGetStringUTFChars(_: jni.JNIEnv, _: jni.jstring, _: ?*jni.jboolean) callconv(.c) ?[*:0]const u8 {
    return fake_text;
}
fn fakeReleaseStringUTFChars(_: jni.JNIEnv, _: jni.jstring, _: [*:0]const u8) callconv(.c) void {}

fn fakeEnv(table: *jni.JNINativeInterface) void {
    table.* = std.mem.zeroes(jni.JNINativeInterface);
    table.FindClass = @ptrCast(&fakeFindClass);
    table.GetObjectClass = @ptrCast(&fakeObjectClass);
    table.GetStaticFieldID = @ptrCast(&fakeStaticFieldId);
    table.GetStaticObjectField = @ptrCast(&fakeStaticObjectField);
    table.GetMethodID = @ptrCast(&fakeMethodId);
    table.CallObjectMethod = @ptrCast(&fakeCallObjectMethod);
    table.CallObjectMethodA = @ptrCast(&fakeCallObjectMethodA);
    table.CallIntMethod = @ptrCast(&fakeCallIntMethod);
    table.GetStringUTFChars = @ptrCast(&fakeGetStringUTFChars);
    table.ReleaseStringUTFChars = @ptrCast(&fakeReleaseStringUTFChars);
    table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);
    table.PushLocalFrame = @ptrCast(&fakePushLocalFrame);
    table.PopLocalFrame = @ptrCast(&fakePopLocalFrame);
    fake_frames_pushed = 0;
    fake_frames_popped = 0;
}

fn readWith(s: Scenario) ![]u8 {
    scenario = s;
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;
    return read(testing.allocator, Jni.init(&ptr), obj(7));
}

test "a clipboard with text reads as that text" {
    const text = try readWith(.has_text);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("copied", text);
}

test "every way the clipboard can be empty answers with an empty string" {
    // All three are what the Kotlin answers, and none is an error. The first
    // is the one that matters: since Android 10 an app that does not hold
    // focus gets null from getPrimaryClip, so this is the branch a real device
    // takes most of the time.
    for ([_]Scenario{ .no_clip, .empty_clip, .no_text }) |s| {
        const text = try readWith(s);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("", text);
    }
}

test "the local frame is closed on every path, including the early returns" {
    // Three of the four paths return before the end of the function, and each
    // leaves a frame open if the defer is ever moved below them. Sixteen slots
    // leak per call, and the JVM aborts the process on overflow rather than
    // failing a call — so this is a crash, not a leak, and it only shows up
    // after enough reads.
    for ([_]Scenario{ .no_clip, .empty_clip, .no_text, .has_text }) |s| {
        const text = try readWith(s);
        testing.allocator.free(text);
        try testing.expectEqual(fake_frames_pushed, fake_frames_popped);
        try testing.expectEqual(@as(usize, 1), fake_frames_popped);
    }
}
