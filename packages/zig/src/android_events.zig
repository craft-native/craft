//! Pushing JavaScript to the page from Zig, on Android.
//!
//! The counterpart to `ios_events.zig`, and it exists because 39 of
//! `CraftBridge.kt`'s 103 methods reply through
//! `runOnUiThread { webView.evaluateJavascript(…) }` and nothing else. None of
//! them can move to Zig until that path does.
//!
//! ## Zig cannot make a Runnable, so Kotlin keeps the threading
//!
//! `evaluateJavascript` is main-thread-only, and the hop is
//! `Activity.runOnUiThread(Runnable)`. A `Runnable` is a Java object
//! implementing an interface, and JNI can only produce one by registering
//! natives on a class that already exists in the APK — which means shipping a
//! Kotlin class to avoid writing Kotlin.
//!
//! So the hop stays in Kotlin. `CraftNative.deliver(script)` does the
//! `runOnUiThread` and the `evaluateJavascript`, and Zig calls it as a static
//! method. Zig owns what to say; Kotlin owns which thread says it. That split
//! is also why this file is small: it is a channel, not a scheduler.
//!
//! ## The env is per-thread and the VM is not
//!
//! A `JNIEnv` belongs to one thread and caching it across threads is the
//! classic JNI crash. A `JavaVM` is process-wide. So every call here asks the
//! VM for *this* thread's env, and attaches the thread when it has none —
//! which is the normal case for a callback arriving on a framework thread,
//! exactly like a `CLLocationManager` delegate on iOS.
//!
//! A thread this file attaches, this file detaches. Leaving one attached keeps
//! the JVM's thread record alive after the OS thread is gone, and the crash
//! surfaces somewhere unrelated much later.

const std = @import("std");
const jni = @import("jni_runtime.zig");

/// The class holding `deliver`. Fixed, for the reason `android_dispatch.zig`
/// gives: the app's own package is templated and a prebuilt library cannot
/// name it.
pub const holder_class = "com/craft/runtime/CraftNative";

/// The process-wide VM, captured at `JNI_OnLoad`.
var java_vm: ?jni.JavaVM = null;

pub fn setVm(vm: jni.JavaVM) void {
    java_vm = vm;
}

pub fn clearVm() void {
    java_vm = null;
}

/// How many scripts were dropped, and why the count exists.
///
/// A dropped script is a page that never hears back, and the only symptom is
/// a promise that does not settle. Counted rather than logged per-drop: the
/// paths that drop are the ones a device takes in bulk — no VM before load, no
/// WebView before the page exists — and a log line each would drown the thing
/// being diagnosed.
var dropped: usize = 0;

pub fn droppedCount() usize {
    return dropped;
}

pub fn resetDroppedForTest() void {
    dropped = 0;
}

/// This thread's env, attaching if it has none.
///
/// Returns whether the caller must detach. A thread the JVM created — the UI
/// thread, a binder thread — is already attached and must **not** be detached
/// by us; a thread Zig or a native library created must be.
const Attachment = struct {
    env: jni.JNIEnv,
    owned: bool,
};

fn attach(vm: jni.JavaVM) ?Attachment {
    if (jni.envForThisThread(vm)) |env| return .{ .env = env, .owned = false };

    const attach_fn: *const fn (jni.JavaVM, *?*anyopaque, ?*anyopaque) callconv(.c) jni.jint =
        @ptrCast(vm.*.AttachCurrentThread orelse return null);

    var env_ptr: ?*anyopaque = null;
    if (attach_fn(vm, &env_ptr, null) != jni.JNI_OK) return null;
    const env: jni.JNIEnv = @ptrCast(@alignCast(env_ptr orelse return null));
    return .{ .env = env, .owned = true };
}

fn detach(vm: jni.JavaVM) void {
    const detach_fn: *const fn (jni.JavaVM) callconv(.c) jni.jint =
        @ptrCast(vm.*.DetachCurrentThread orelse return);
    _ = detach_fn(vm);
}

/// Hand `script` to `CraftNative.deliver`, from any thread.
///
/// Silent on every failure, and deliberately: the caller is a device callback
/// with nowhere to report to, and the alternatives are a log per location fix
/// or an error nobody reads. `droppedCount` is what a diagnosis reads instead.
pub fn evaluate(script: [*:0]const u8) void {
    const vm = java_vm orelse {
        dropped += 1;
        return;
    };

    const attachment = attach(vm) orelse {
        dropped += 1;
        return;
    };
    defer if (attachment.owned) detach(vm);

    deliverThrough(attachment.env, script) catch {
        dropped += 1;
    };
}

fn deliverThrough(env: jni.JNIEnv, script: [*:0]const u8) !void {
    const j = jni.Jni.init(env);

    // A frame around the class, the string and any pending throwable. Without
    // it a stream delivering several times a second leaks a local ref per
    // delivery and overflows the JVM's sixteen slots — which aborts the
    // process rather than failing a call.
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const cls = try j.findClass(holder_class);
    const text = try j.newStringUtf(script);

    const deliver = try j.staticMethodId(cls, "deliver", "(Ljava/lang/String;)V");
    try j.callStaticVoidMethodA(cls, deliver, &.{.{ .l = text }});
}

/// `window.dispatchEvent(new CustomEvent('name', {detail: json}))`.
///
/// `detail_json` is inlined as an object literal rather than escaped into a
/// string, so a value containing a quote cannot break out — the same reasoning
/// `ios_events.zig` records. The *name* is never interpolated from anything a
/// page or a device can influence; callers pass a literal.
pub fn emitEvent(
    allocator: std.mem.Allocator,
    name: []const u8,
    detail_json: []const u8,
) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "window.dispatchEvent(new CustomEvent('");
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "', {detail: ");
    try out.appendSlice(allocator, detail_json);
    try out.appendSlice(allocator, "}));");
    try out.append(allocator, 0);

    evaluate(@ptrCast(out.items.ptr));
}

/// `window._craftXResolve && window._craftXResolve(payload)`.
///
/// The guard is not defensive noise. These globals are assigned by the
/// injected JS *inside* a promise executor, so between an action being called
/// and its promise being constructed the global does not exist — and a device
/// callback that arrives in that window would otherwise throw a ReferenceError
/// inside `evaluateJavascript`, where nothing sees it. The Kotlin writes the
/// same guard for the same reason.
pub fn settle(
    allocator: std.mem.Allocator,
    global: []const u8,
    payload_json: []const u8,
) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "window.");
    try out.appendSlice(allocator, global);
    try out.appendSlice(allocator, " && window.");
    try out.appendSlice(allocator, global);
    try out.append(allocator, '(');
    try out.appendSlice(allocator, payload_json);
    try out.appendSlice(allocator, ");");
    try out.append(allocator, 0);

    evaluate(@ptrCast(out.items.ptr));
}

// =============================================================================
// Tests
//
// The whole channel is testable because both tables are just function
// pointers: the JavaVM's GetEnv and AttachCurrentThread as much as the env's
// FindClass. So a test can be a thread that is attached, a thread that is not,
// or a process with no VM at all.
// =============================================================================

const testing = std.testing;

var fake_env_table: jni.JNINativeInterface = undefined;
var fake_env_ptr: *const jni.JNINativeInterface = undefined;
var fake_storage: [8]u8 = undefined;

var fake_delivered: [512]u8 = undefined;
var fake_delivered_len: usize = 0;
var fake_attach_calls: usize = 0;
var fake_detach_calls: usize = 0;
var fake_already_attached = true;
var fake_attach_succeeds = true;
var fake_find_class_succeeds = true;

fn eobj(tag: usize) jni.jobject {
    return @ptrCast(&fake_storage[tag]);
}

fn eGetEnv(_: jni.JavaVM, out: *?*anyopaque, _: jni.jint) callconv(.c) jni.jint {
    if (!fake_already_attached) return jni.JNI_EDETACHED;
    out.* = @ptrCast(@constCast(&fake_env_ptr));
    return jni.JNI_OK;
}
fn eAttach(_: jni.JavaVM, out: *?*anyopaque, _: ?*anyopaque) callconv(.c) jni.jint {
    fake_attach_calls += 1;
    if (!fake_attach_succeeds) return -1;
    out.* = @ptrCast(@constCast(&fake_env_ptr));
    return jni.JNI_OK;
}
fn eDetach(_: jni.JavaVM) callconv(.c) jni.jint {
    fake_detach_calls += 1;
    return jni.JNI_OK;
}

fn eFindClass(_: jni.JNIEnv, _: [*:0]const u8) callconv(.c) jni.jclass {
    return if (fake_find_class_succeeds) eobj(0) else null;
}
fn eStaticMethodId(_: jni.JNIEnv, _: jni.jclass, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jmethodID {
    return eobj(1);
}
fn eNewStringUTF(_: jni.JNIEnv, text: [*:0]const u8) callconv(.c) jni.jstring {
    const span = std.mem.span(text);
    fake_delivered_len = @min(span.len, fake_delivered.len);
    @memcpy(fake_delivered[0..fake_delivered_len], span[0..fake_delivered_len]);
    return eobj(2);
}
fn eCallStaticVoidMethodA(_: jni.JNIEnv, _: jni.jclass, _: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) void {}
fn eExceptionOccurred(_: jni.JNIEnv) callconv(.c) jni.jobject {
    return null;
}
fn ePush(_: jni.JNIEnv, _: jni.jint) callconv(.c) jni.jint {
    return 0;
}
fn ePop(_: jni.JNIEnv, keep: jni.jobject) callconv(.c) jni.jobject {
    return keep;
}

fn fakeVm(invoke: *jni.JNIInvokeInterface) void {
    fake_env_table = std.mem.zeroes(jni.JNINativeInterface);
    fake_env_table.FindClass = @ptrCast(&eFindClass);
    fake_env_table.GetStaticMethodID = @ptrCast(&eStaticMethodId);
    fake_env_table.NewStringUTF = @ptrCast(&eNewStringUTF);
    fake_env_table.CallStaticVoidMethodA = @ptrCast(&eCallStaticVoidMethodA);
    fake_env_table.ExceptionOccurred = @ptrCast(&eExceptionOccurred);
    fake_env_table.PushLocalFrame = @ptrCast(&ePush);
    fake_env_table.PopLocalFrame = @ptrCast(&ePop);
    fake_env_ptr = &fake_env_table;

    invoke.* = std.mem.zeroes(jni.JNIInvokeInterface);
    invoke.GetEnv = @ptrCast(&eGetEnv);
    invoke.AttachCurrentThread = @ptrCast(&eAttach);
    invoke.DetachCurrentThread = @ptrCast(&eDetach);

    fake_delivered_len = 0;
    fake_attach_calls = 0;
    fake_detach_calls = 0;
    fake_already_attached = true;
    fake_attach_succeeds = true;
    fake_find_class_succeeds = true;
    resetDroppedForTest();
}

fn delivered() []const u8 {
    return fake_delivered[0..fake_delivered_len];
}

test "a script reaches deliver on an already-attached thread, and nothing is detached" {
    var invoke: jni.JNIInvokeInterface = undefined;
    fakeVm(&invoke);
    const ptr: *const jni.JNIInvokeInterface = &invoke;
    setVm(&ptr);
    defer clearVm();

    evaluate("window.x = 1;");
    try testing.expectEqualStrings("window.x = 1;", delivered());

    // The UI thread and every binder thread are already attached, and
    // detaching one the JVM created tears down a thread the JVM still uses.
    try testing.expectEqual(@as(usize, 0), fake_attach_calls);
    try testing.expectEqual(@as(usize, 0), fake_detach_calls);
    try testing.expectEqual(@as(usize, 0), droppedCount());
}

test "a detached thread is attached and then detached again" {
    // The case that matters: a device callback on a thread the JVM did not
    // create. Leaving it attached keeps the JVM's thread record alive after
    // the OS thread is gone, and the crash surfaces somewhere unrelated later.
    var invoke: jni.JNIInvokeInterface = undefined;
    fakeVm(&invoke);
    const ptr: *const jni.JNIInvokeInterface = &invoke;
    setVm(&ptr);
    defer clearVm();

    fake_already_attached = false;
    evaluate("window.y = 2;");

    try testing.expectEqualStrings("window.y = 2;", delivered());
    try testing.expectEqual(@as(usize, 1), fake_attach_calls);
    try testing.expectEqual(@as(usize, 1), fake_detach_calls);
}

test "every way delivery can fail is counted, not logged and not crashed" {
    var invoke: jni.JNIInvokeInterface = undefined;
    fakeVm(&invoke);
    const ptr: *const jni.JNIInvokeInterface = &invoke;

    // No VM at all — before JNI_OnLoad, or in a build with no runtime linked.
    clearVm();
    resetDroppedForTest();
    evaluate("window.z = 3;");
    try testing.expectEqual(@as(usize, 1), droppedCount());

    // A thread that cannot be attached.
    setVm(&ptr);
    defer clearVm();
    fake_already_attached = false;
    fake_attach_succeeds = false;
    resetDroppedForTest();
    evaluate("window.z = 3;");
    try testing.expectEqual(@as(usize, 1), droppedCount());
    // Nothing was attached, so nothing may be detached.
    try testing.expectEqual(@as(usize, 0), fake_detach_calls);

    // The holder class missing — a runtime loaded against a stale APK.
    fake_already_attached = true;
    fake_attach_succeeds = true;
    fake_find_class_succeeds = false;
    resetDroppedForTest();
    evaluate("window.z = 3;");
    try testing.expectEqual(@as(usize, 1), droppedCount());
}

test "an attached thread is detached even when delivery fails" {
    // The leak this pins: a `defer` that sat after the delivery call, or
    // inside an `if`, would skip the detach on exactly the path that already
    // went wrong.
    var invoke: jni.JNIInvokeInterface = undefined;
    fakeVm(&invoke);
    const ptr: *const jni.JNIInvokeInterface = &invoke;
    setVm(&ptr);
    defer clearVm();

    fake_already_attached = false;
    fake_find_class_succeeds = false;
    evaluate("window.z = 3;");

    try testing.expectEqual(@as(usize, 1), fake_attach_calls);
    try testing.expectEqual(@as(usize, 1), fake_detach_calls);
    try testing.expectEqual(@as(usize, 1), droppedCount());
}

test "an event inlines its detail rather than escaping it into a string" {
    var invoke: jni.JNIInvokeInterface = undefined;
    fakeVm(&invoke);
    const ptr: *const jni.JNIInvokeInterface = &invoke;
    setVm(&ptr);
    defer clearVm();

    try emitEvent(testing.allocator, "craftMotionUpdate", "{\"x\":1,\"y\":\"a\\\"b\"}");
    try testing.expectEqualStrings(
        "window.dispatchEvent(new CustomEvent('craftMotionUpdate', {detail: {\"x\":1,\"y\":\"a\\\"b\"}}));",
        delivered(),
    );
}

test "settling guards the global that the promise may not have assigned yet" {
    // These globals are assigned inside a promise executor, so between the
    // action being called and the promise being built the global does not
    // exist — and a callback arriving in that window would throw a
    // ReferenceError inside evaluateJavascript, where nothing sees it.
    var invoke: jni.JNIInvokeInterface = undefined;
    fakeVm(&invoke);
    const ptr: *const jni.JNIInvokeInterface = &invoke;
    setVm(&ptr);
    defer clearVm();

    try settle(testing.allocator, "_craftLocationResolve", "{\"latitude\":1}");
    try testing.expectEqualStrings(
        "window._craftLocationResolve && window._craftLocationResolve({\"latitude\":1});",
        delivered(),
    );
}
