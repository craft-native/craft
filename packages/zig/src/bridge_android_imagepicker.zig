//! The four Android actions that launch a system media/file Activity:
//! `openCamera`, `pickImage`, `pickFile` and `startVideoRecording`.
//!
//! These actions only launch. `CraftBridge.handleImageResult` contains camera
//! and gallery decoding, but `MainActivity.onActivityResult` routes only to
//! Health Connect, so it never calls that handler. File and video have no
//! result handler at all. Consequently all four promises stay pending after
//! the external Activity returns; moving the launch preserves that incomplete
//! behaviour rather than quietly inventing a result path on the Zig side.
//!
//! ## Starting is the part that moved
//!
//! None keeps state between launch and result. The request codes still cross
//! because they are observable to the launched Activity lifecycle and are the
//! exact values the shim uses, even though this template currently drops the
//! corresponding results.
//!
//! `openCamera` also preserves the shim's permission behaviour. A denied call
//! asks for CAMERA and returns without launching or settling the promise; the
//! page has to call again after permission is granted. `pickImage` asks for no
//! permission because the system picker grants access to the selected Uri.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const permissions = @import("android_permissions.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const open_camera = "openCamera";
    pub const pick_image = "pickImage";
    pub const pick_file = "pickFile";
    pub const start_video_recording = "startVideoRecording";
};

/// The request codes the four shim methods launch with.
pub const request_camera: i32 = 1001;
pub const request_gallery: i32 = 1002;
pub const request_file: i32 = 1006;
pub const request_video: i32 = 1008;

/// The permission request code in the shim. Its result is deliberately not
/// handled; granting it makes the next `openCamera` call pass the check.
pub const request_camera_permission: i32 = 101;

fn staticObject(
    j: Jni,
    cls: jni.jclass,
    name: [*:0]const u8,
    signature: [*:0]const u8,
) !jobject {
    return j.staticObjectField(cls, try j.staticFieldId(cls, name, signature));
}

fn startActivityForResult(j: Jni, activity: jobject, intent: jobject, request_code: i32) !void {
    const activity_cls = try j.objectClass(activity);
    try j.callVoidMethodA(
        activity,
        try j.methodId(
            activity_cls,
            "startActivityForResult",
            "(Landroid/content/Intent;I)V",
        ),
        &.{ .{ .l = intent }, .{ .i = request_code } },
    );
}

/// Ask for CAMERA when needed; otherwise launch `ACTION_IMAGE_CAPTURE`.
pub fn openCamera(j: Jni, activity: jobject) !void {
    if (!try permissions.isGranted(j, activity, permissions.camera)) {
        try permissions.request(j, activity, permissions.camera, request_camera_permission);
        return;
    }

    try j.pushLocalFrame(12);
    defer _ = j.popLocalFrame(null);

    const media_store = try j.findClass("android/provider/MediaStore");
    const action = try staticObject(
        j,
        media_store,
        "ACTION_IMAGE_CAPTURE",
        "Ljava/lang/String;",
    );

    const intent_cls = try j.findClass("android/content/Intent");
    const intent = try j.newObjectA(
        intent_cls,
        try j.methodId(intent_cls, "<init>", "(Ljava/lang/String;)V"),
        &.{.{ .l = action }},
    );
    try startActivityForResult(j, activity, intent, request_camera);
}

/// Launch `ACTION_PICK` at `MediaStore.Images.Media.EXTERNAL_CONTENT_URI`.
pub fn pickImage(j: Jni, activity: jobject) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const intent_cls = try j.findClass("android/content/Intent");
    const action = try staticObject(j, intent_cls, "ACTION_PICK", "Ljava/lang/String;");

    // `$` is JNI's spelling of the nested Images.Media class.
    const images = try j.findClass("android/provider/MediaStore$Images$Media");
    const uri = try staticObject(
        j,
        images,
        "EXTERNAL_CONTENT_URI",
        "Landroid/net/Uri;",
    );

    const intent = try j.newObjectA(
        intent_cls,
        try j.methodId(
            intent_cls,
            "<init>",
            "(Ljava/lang/String;Landroid/net/Uri;)V",
        ),
        &.{ .{ .l = action }, .{ .l = uri } },
    );
    try startActivityForResult(j, activity, intent, request_gallery);
}

/// Launch `ACTION_OPEN_DOCUMENT` for any openable MIME type.
///
/// `typesJson` is deliberately absent: the shim accepts it but never reads it,
/// and always asks for `*/*`.
pub fn pickFile(j: Jni, activity: jobject) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const intent_cls = try j.findClass("android/content/Intent");
    const action = try staticObject(j, intent_cls, "ACTION_OPEN_DOCUMENT", "Ljava/lang/String;");
    const intent = try j.newObjectA(
        intent_cls,
        try j.methodId(intent_cls, "<init>", "(Ljava/lang/String;)V"),
        &.{.{ .l = action }},
    );

    const category = try staticObject(j, intent_cls, "CATEGORY_OPENABLE", "Ljava/lang/String;");
    _ = try j.callObjectMethodA(
        intent,
        try j.methodId(
            intent_cls,
            "addCategory",
            "(Ljava/lang/String;)Landroid/content/Intent;",
        ),
        &.{.{ .l = category }},
    );

    _ = try j.callObjectMethodA(
        intent,
        try j.methodId(
            intent_cls,
            "setType",
            "(Ljava/lang/String;)Landroid/content/Intent;",
        ),
        &.{.{ .l = try j.newStringUtf("*/*") }},
    );
    try startActivityForResult(j, activity, intent, request_file);
}

/// Launch `ACTION_VIDEO_CAPTURE` with `EXTRA_VIDEO_QUALITY = 1`.
pub fn startVideoRecording(j: Jni, activity: jobject) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const media_store = try j.findClass("android/provider/MediaStore");
    const action = try staticObject(j, media_store, "ACTION_VIDEO_CAPTURE", "Ljava/lang/String;");
    const quality = try staticObject(j, media_store, "EXTRA_VIDEO_QUALITY", "Ljava/lang/String;");

    const intent_cls = try j.findClass("android/content/Intent");
    const intent = try j.newObjectA(
        intent_cls,
        try j.methodId(intent_cls, "<init>", "(Ljava/lang/String;)V"),
        &.{.{ .l = action }},
    );
    _ = try j.callObjectMethodA(
        intent,
        try j.methodId(
            intent_cls,
            "putExtra",
            "(Ljava/lang/String;I)Landroid/content/Intent;",
        ),
        &.{ .{ .l = quality }, .{ .i = 1 } },
    );
    try startActivityForResult(j, activity, intent, request_video);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

var fake_storage: [16]u8 = undefined;
var fake_calls: std.ArrayListUnmanaged([]const u8) = .empty;
var fake_fields: std.ArrayListUnmanaged([]const u8) = .empty;
var fake_strings: std.ArrayListUnmanaged([]const u8) = .empty;
var fake_permission: jni.jint = permissions.granted;
var fake_request_code: ?jni.jint = null;
var fake_int_extra: ?jni.jint = null;

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
    fake_fields.append(testing.allocator, std.mem.span(name)) catch {};
    return obj(1);
}

fn fStaticObjectField(_: jni.JNIEnv, _: jni.jclass, _: jni.jfieldID) callconv(.c) jobject {
    return obj(2);
}

fn fNewStringUTF(_: jni.JNIEnv, text: [*:0]const u8) callconv(.c) jni.jstring {
    const copy = testing.allocator.dupe(u8, std.mem.span(text)) catch return obj(3);
    fake_strings.append(testing.allocator, copy) catch testing.allocator.free(copy);
    return obj(3);
}

fn fNewObjectA(_: jni.JNIEnv, _: jni.jclass, id: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) jobject {
    fake_calls.append(testing.allocator, nameOf(id)) catch {};
    return obj(4);
}

fn fCallIntMethodA(_: jni.JNIEnv, _: jobject, id: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) jni.jint {
    fake_calls.append(testing.allocator, nameOf(id)) catch {};
    return fake_permission;
}

fn fCallObjectMethodA(_: jni.JNIEnv, _: jobject, id: jni.jmethodID, args: [*]const jni.jvalue) callconv(.c) jobject {
    const name = nameOf(id);
    fake_calls.append(testing.allocator, name) catch {};
    if (std.mem.eql(u8, name, "putExtra")) fake_int_extra = args[1].i;
    return obj(6);
}

fn fCallVoidMethodA(_: jni.JNIEnv, _: jobject, id: jni.jmethodID, args: [*]const jni.jvalue) callconv(.c) void {
    const name = nameOf(id);
    fake_calls.append(testing.allocator, name) catch {};
    if (std.mem.eql(u8, name, "startActivityForResult") or
        std.mem.eql(u8, name, "requestPermissions"))
    {
        fake_request_code = args[1].i;
    }
}

fn fNewObjectArray(_: jni.JNIEnv, _: jni.jsize, _: jni.jclass, _: jobject) callconv(.c) jobject {
    return obj(5);
}

fn fSetObjectArrayElement(_: jni.JNIEnv, _: jobject, _: jni.jsize, _: jobject) callconv(.c) void {}
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
    table.GetStaticFieldID = @ptrCast(&fStaticFieldId);
    table.GetStaticObjectField = @ptrCast(&fStaticObjectField);
    table.NewStringUTF = @ptrCast(&fNewStringUTF);
    table.NewObjectA = @ptrCast(&fNewObjectA);
    table.CallIntMethodA = @ptrCast(&fCallIntMethodA);
    table.CallObjectMethodA = @ptrCast(&fCallObjectMethodA);
    table.CallVoidMethodA = @ptrCast(&fCallVoidMethodA);
    table.NewObjectArray = @ptrCast(&fNewObjectArray);
    table.SetObjectArrayElement = @ptrCast(&fSetObjectArrayElement);
    table.DeleteLocalRef = @ptrCast(&fDeleteLocalRef);
    table.PushLocalFrame = @ptrCast(&fPush);
    table.PopLocalFrame = @ptrCast(&fPop);
}

fn resetFakes() void {
    fake_calls.clearRetainingCapacity();
    fake_fields.clearRetainingCapacity();
    for (fake_strings.items) |value| testing.allocator.free(value);
    fake_strings.clearRetainingCapacity();
    fake_permission = permissions.granted;
    fake_request_code = null;
    fake_int_extra = null;
}

fn freeFakes() void {
    fake_calls.deinit(testing.allocator);
    fake_fields.deinit(testing.allocator);
    for (fake_strings.items) |value| testing.allocator.free(value);
    fake_strings.deinit(testing.allocator);
    fake_calls = .empty;
    fake_fields = .empty;
    fake_strings = .empty;
}

fn saw(items: []const []const u8, expected: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, expected)) return true;
    return false;
}

test "a granted camera call launches the capture intent with the camera result code" {
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try openCamera(Jni.init(&ptr), obj(8));

    try testing.expect(saw(fake_calls.items, "checkSelfPermission"));
    try testing.expect(saw(fake_fields.items, "ACTION_IMAGE_CAPTURE"));
    try testing.expect(saw(fake_calls.items, "startActivityForResult"));
    try testing.expectEqual(@as(?jni.jint, request_camera), fake_request_code);
}

test "a denied camera call asks once and does not launch" {
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;
    fake_permission = -1;

    try openCamera(Jni.init(&ptr), obj(8));

    try testing.expect(saw(fake_calls.items, "requestPermissions"));
    try testing.expect(!saw(fake_calls.items, "startActivityForResult"));
    try testing.expect(saw(fake_strings.items, permissions.camera));
    try testing.expectEqual(@as(?jni.jint, request_camera_permission), fake_request_code);
}

test "the gallery call uses the picker Uri and gallery result code" {
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try pickImage(Jni.init(&ptr), obj(8));

    try testing.expect(saw(fake_fields.items, "ACTION_PICK"));
    try testing.expect(saw(fake_fields.items, "EXTERNAL_CONTENT_URI"));
    try testing.expect(saw(fake_calls.items, "startActivityForResult"));
    try testing.expectEqual(@as(?jni.jint, request_gallery), fake_request_code);
    // Unlike the camera path, the system picker needs no runtime permission.
    try testing.expect(!saw(fake_calls.items, "checkSelfPermission"));
}

test "the file picker ignores its types and asks for any openable document" {
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try pickFile(Jni.init(&ptr), obj(8));

    try testing.expect(saw(fake_fields.items, "ACTION_OPEN_DOCUMENT"));
    try testing.expect(saw(fake_fields.items, "CATEGORY_OPENABLE"));
    try testing.expect(saw(fake_calls.items, "addCategory"));
    try testing.expect(saw(fake_calls.items, "setType"));
    try testing.expect(saw(fake_strings.items, "*/*"));
    try testing.expectEqual(@as(?jni.jint, request_file), fake_request_code);
}

test "video capture asks for the shim's full-quality setting" {
    resetFakes();
    defer freeFakes();
    var table: jni.JNINativeInterface = undefined;
    fakeEnv(&table);
    const ptr: *const jni.JNINativeInterface = &table;

    try startVideoRecording(Jni.init(&ptr), obj(8));

    try testing.expect(saw(fake_fields.items, "ACTION_VIDEO_CAPTURE"));
    try testing.expect(saw(fake_fields.items, "EXTRA_VIDEO_QUALITY"));
    try testing.expect(saw(fake_calls.items, "putExtra"));
    try testing.expectEqual(@as(?jni.jint, 1), fake_int_extra);
    try testing.expectEqual(@as(?jni.jint, request_video), fake_request_code);
}

test "the action and request names match the Kotlin launchers" {
    try testing.expectEqualStrings("openCamera", A.open_camera);
    try testing.expectEqualStrings("pickImage", A.pick_image);
    try testing.expectEqualStrings("pickFile", A.pick_file);
    try testing.expectEqualStrings("startVideoRecording", A.start_video_recording);
    try testing.expectEqual(@as(i32, 1001), request_camera);
    try testing.expectEqual(@as(i32, 1002), request_gallery);
    try testing.expectEqual(@as(i32, 1006), request_file);
    try testing.expectEqual(@as(i32, 1008), request_video);
    try testing.expectEqual(@as(i32, 101), request_camera_permission);
}
