//! Where Kotlin hands an action to Zig.
//!
//! The counterpart to `ios_dispatch.zig`, and the two seams differ because the
//! two bridges do. iOS posts a message and settles a promise later, so its seam
//! is `craft_ios_handle_action` returning "claimed / not mine" with the reply
//! arriving separately. Android's `@JavascriptInterface` methods are ordinary
//! synchronous calls that return a `String`, so the seam is a synchronous
//! function returning a `jstring`.
//!
//! ## `null` means "not mine", exactly as `.not_ours` does on iOS
//!
//! Every native method here returns null for an action Zig does not serve, and
//! the Kotlin falls through to its own implementation. That is the same
//! hand-back `ios_dispatch.hostServesItself` performs, and it is what makes
//! this migratable one action at a time: an app running a build where Zig
//! serves three actions behaves identically to one where it serves none.
//!
//! ## The templated package, and why there is a second Kotlin class
//!
//! The usual way to bind a `native` method is to export a symbol the JVM finds
//! by mangling — `Java_com_example_CraftBridge_nativeGetDeviceInfo`. That name
//! embeds the package, and `CraftBridge.kt.template` opens with
//! `package {{PACKAGE_NAME}}`, defaulting to `com.craft.<appname>`. A mangled
//! export would resolve for exactly one app and raise `UnsatisfiedLinkError`
//! on first call for every other — at runtime, long after a build that looked
//! fine. `RegisterNatives` binds by name at load time instead and never sees
//! the package.
//!
//! That solves the method name and not the class name: `FindClass` needs one,
//! and a prebuilt library cannot know a name chosen when the app is generated.
//! So the natives are not bound to `CraftBridge` at all. They are bound to
//! `com.craft.runtime.CraftNative`, a small holder whose package is **fixed**
//! and not templated, and the generated `CraftBridge` delegates to it. One
//! extra class buys a library that is identical for every app.

const std = @import("std");
const builtin = @import("builtin");
const jni = @import("jni_runtime.zig");
const device = @import("bridge_android_device.zig");
const system = @import("bridge_android_system.zig");
const clipboard = @import("bridge_android_clipboard.zig");

const Jni = jni.Jni;

/// The allocator every reply is built with.
///
/// `page_allocator`, and the choice is a build constraint rather than a
/// preference. `c_allocator` would pull in bionic, and Zig cannot provide
/// bionic — a static Android library links nothing and builds anyway, but this
/// one is shared and has to resolve its symbols, so libc here means the whole
/// library needs the NDK to build at all. Standing free of libc keeps it
/// buildable with nothing but Zig.
///
/// Every native call wraps this in an arena, so the page granularity costs one
/// page per call rather than one per allocation, and nothing has to be freed
/// individually on the way out.
const backing = std.heap.page_allocator;

/// The VM, captured at load so a later callback on a framework thread can ask
/// it for that thread's `JNIEnv`.
///
/// A `JNIEnv` is per-thread and must never be cached across threads; a
/// `JavaVM` is process-wide and is the one handle that may be. Storing the
/// wrong one of these is the crash that only shows up once something calls
/// back from a non-Java thread.
var java_vm: ?jni.JavaVM = null;

pub fn vm() ?jni.JavaVM {
    return java_vm;
}

/// The Java class the natives bind to. Fixed, unlike the bridge's own package.
pub const holder_class = "com/craft/runtime/CraftNative";

/// The JVM calls this when `System.loadLibrary` resolves the library.
///
/// Returning a version the runtime does not offer fails the load, so this
/// returns 1.6 — what ART provides and what Android documents as the floor.
///
/// `FindClass` is legal here and only here for a class of the app's own: this
/// runs on the thread that called `loadLibrary`, which carries the app's class
/// loader. The same call from a thread the JVM did not create resolves against
/// the *system* loader and would not find `CraftNative` at all — one of JNI's
/// sharper edges, and the reason registration happens at load rather than
/// lazily on first use.
///
/// A failed registration does not fail the load. Returning an error version
/// here would stop the library loading at all, and the Kotlin holder already
/// treats a missing native as "ask the shim" — so the honest outcome is a
/// logged warning and an app that behaves exactly as it did before Zig was
/// linked.
pub export fn JNI_OnLoad(vm_handle: jni.JavaVM, _: ?*anyopaque) callconv(.c) jni.jint {
    java_vm = vm_handle;

    switch (bindNatives(vm_handle)) {
        .registered => {},
        .no_env => std.log.err(
            "craft: no JNIEnv at load; every action stays on the Kotlin shim",
            .{},
        ),
        .class_not_found => std.log.err(
            "craft: {s} not on the class path; every action stays on the Kotlin shim",
            .{holder_class},
        ),
        .register_failed => std.log.err(
            "craft: RegisterNatives refused a method on {s}; check the descriptors " ++
                "against CraftNative.kt. Every action stays on the Kotlin shim",
            .{holder_class},
        ),
    }

    return jni.JNI_VERSION_1_6;
}

/// The native methods this library binds, by Java name and signature.
///
/// The signatures are checked by the JVM at registration rather than at call
/// time, which is the one piece of type safety this seam gets for free: a
/// wrong descriptor here fails `RegisterNatives` at load with a message naming
/// the method, rather than corrupting a stack on first use.
const natives = [_]jni.JNINativeMethod{
    .{
        .name = "nativeGetDeviceInfo",
        .signature = "(Landroid/app/Activity;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeGetDeviceInfo),
    },
    // No Activity parameter: `Runtime` and `Log` are static, so neither of
    // these needs anything the app hands over. The signature says so, and a
    // signature that asked for one would fail registration rather than be
    // quietly ignored.
    .{
        .name = "nativeGetMemoryUsage",
        .signature = "()Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeGetMemoryUsage),
    },
    .{
        .name = "nativeLog",
        .signature = "(Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeLog),
    },
    .{
        .name = "nativeClipboardRead",
        .signature = "(Landroid/app/Activity;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeClipboardRead),
    },
    .{
        .name = "nativeClipboardWrite",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeClipboardWrite),
    },
};

/// How binding went. A value rather than a log line, so every path is
/// assertable: the test runner treats an error-level log as a failed test, so
/// a function that reported by logging could only ever be tested on the path
/// that succeeds — which is the one path that does not need testing.
pub const LoadOutcome = enum {
    registered,
    /// The VM would not give this thread a `JNIEnv`.
    no_env,
    /// `CraftNative` was not on the class path.
    class_not_found,
    /// The class was found and `RegisterNatives` refused it — almost always a
    /// method name or descriptor that does not match what Kotlin declares.
    register_failed,
};

/// Find the holder and bind the natives to it. No logging; see `LoadOutcome`.
///
/// Idempotent by JNI's own rule: registering a method that is already
/// registered replaces it, so a second call after a hot reload is not an error.
pub fn bindNatives(vm_handle: jni.JavaVM) LoadOutcome {
    const env = jni.envForThisThread(vm_handle) orelse return .no_env;
    const j = Jni.init(env);
    const cls = j.findClass(holder_class) catch return .class_not_found;
    jni.registerNatives(env, cls, &natives) catch return .register_failed;
    return .registered;
}

/// `nativeGetDeviceInfo(activity)` — the first action served from Zig.
///
/// Returns null on any failure rather than throwing. The Kotlin's own
/// `getDeviceInfo` is the fallback, so a null here is "ask the shim", which is
/// strictly better than propagating a Java exception the page would see as an
/// unexplained rejection from a method whose Kotlin version cannot fail.
fn nativeGetDeviceInfo(env: jni.JNIEnv, _: jni.jobject, activity: jni.jobject) callconv(.c) jni.jstring {
    const j = Jni.init(env);

    // One arena for the whole call. The reply is built out of a dozen small
    // strings that all die together the moment `NewStringUTF` has copied them
    // into the JVM's heap, which is exactly the lifetime an arena models.
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const info = device.read(allocator, j, activity) catch |err| {
        std.log.warn("craft: getDeviceInfo fell through to the shim ({s})", .{@errorName(err)});
        return null;
    };

    const json = device.render(allocator, info) catch return null;

    // `NewStringUTF` reads to a NUL, and `render` produces a plain slice.
    // Copied rather than terminated in place because the reply is JSON built
    // for the page, and giving `render` a sentinel to satisfy would put a
    // JNI detail into the half of this action that has nothing to do with Java.
    const owned = allocator.allocSentinel(u8, json.len, 0) catch return null;
    @memcpy(owned, json);

    return j.newStringUtf(owned.ptr) catch null;
}

/// `nativeGetMemoryUsage()` — the JVM heap, as JSON.
fn nativeGetMemoryUsage(env: jni.JNIEnv, _: jni.jobject) callconv(.c) jni.jstring {
    const j = Jni.init(env);

    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const usage = system.readMemory(j) catch |err| {
        std.log.warn("craft: getMemoryUsage fell through to the shim ({s})", .{@errorName(err)});
        return null;
    };

    const json = system.renderMemory(allocator, usage) catch return null;
    const owned = allocator.allocSentinel(u8, json.len, 0) catch return null;
    @memcpy(owned, json);

    return j.newStringUtf(owned.ptr) catch null;
}

/// `nativeLog(message)` — returns whether Zig wrote the line.
///
/// A boolean rather than void, because "not mine" has to be expressible.
/// `void` would leave the Kotlin unable to tell a successful native log from a
/// runtime that declined, and it would log the message twice or not at all.
fn nativeLog(env: jni.JNIEnv, _: jni.jobject, message: jni.jstring) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = j.stringToUtf8(allocator, message) catch return jni.JNI_FALSE;
    const owned = allocator.allocSentinel(u8, text.len, 0) catch return jni.JNI_FALSE;
    @memcpy(owned, text);

    system.writeLog(j, owned.ptr) catch |err| {
        std.log.warn("craft: log fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeClipboardRead(activity)`.
///
/// Null here means "ask the shim", and an empty *string* means "the clipboard
/// is empty" — two different answers that a nullable String is exactly able to
/// carry, and that a plain String would collapse into one.
fn nativeClipboardRead(env: jni.JNIEnv, _: jni.jobject, activity: jni.jobject) callconv(.c) jni.jstring {
    const j = Jni.init(env);

    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = clipboard.read(allocator, j, activity) catch |err| {
        std.log.warn("craft: clipboardRead fell through to the shim ({s})", .{@errorName(err)});
        return null;
    };

    const owned = allocator.allocSentinel(u8, text.len, 0) catch return null;
    @memcpy(owned, text);
    return j.newStringUtf(owned.ptr) catch null;
}

/// `nativeClipboardWrite(activity, text)`.
fn nativeClipboardWrite(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    text: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = j.stringToUtf8(allocator, text) catch return jni.JNI_FALSE;
    const owned = allocator.allocSentinel(u8, value.len, 0) catch return jni.JNI_FALSE;
    @memcpy(owned, value);

    clipboard.write(j, activity, owned.ptr) catch |err| {
        std.log.warn("craft: clipboardWrite fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// --- A fake JVM, enough to drive the whole load path ----------------------
//
// `JNI_OnLoad` is handed a JavaVM and has to reach a JNIEnv, a class and
// RegisterNatives before it has bound anything. All three are table entries,
// so all three can be Zig functions.

var fake_env_table: jni.JNINativeInterface = undefined;
var fake_env_ptr: *const jni.JNINativeInterface = undefined;
var fake_class_storage: u8 = 0;
var fake_registered_count: jni.jint = -1;
var fake_register_result: jni.jint = jni.JNI_OK;
var fake_find_class_succeeds = true;
var fake_get_env_succeeds = true;

fn fakeGetEnv(_: jni.JavaVM, out: *?*anyopaque, _: jni.jint) callconv(.c) jni.jint {
    if (!fake_get_env_succeeds) return jni.JNI_EDETACHED;
    out.* = @ptrCast(@constCast(&fake_env_ptr));
    return jni.JNI_OK;
}

fn fakeFindClass(_: jni.JNIEnv, _: [*:0]const u8) callconv(.c) jni.jclass {
    if (!fake_find_class_succeeds) return null;
    return @ptrCast(&fake_class_storage);
}

fn fakeExceptionOccurred(_: jni.JNIEnv) callconv(.c) jni.jobject {
    return null;
}

fn fakeRegisterNatives(
    _: jni.JNIEnv,
    _: jni.jclass,
    _: [*]const jni.JNINativeMethod,
    count: jni.jint,
) callconv(.c) jni.jint {
    fake_registered_count = count;
    return fake_register_result;
}

fn fakeVm() jni.JNIInvokeInterface {
    var invoke = std.mem.zeroes(jni.JNIInvokeInterface);
    invoke.GetEnv = @ptrCast(&fakeGetEnv);

    fake_env_table = std.mem.zeroes(jni.JNINativeInterface);
    fake_env_table.FindClass = @ptrCast(&fakeFindClass);
    fake_env_table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);
    fake_env_table.RegisterNatives = @ptrCast(&fakeRegisterNatives);
    fake_env_ptr = &fake_env_table;

    fake_registered_count = -1;
    fake_register_result = jni.JNI_OK;
    fake_find_class_succeeds = true;
    fake_get_env_succeeds = true;
    return invoke;
}

test "the load path finds the holder and binds every native to it" {
    var invoke = fakeVm();
    const ptr: *const jni.JNIInvokeInterface = &invoke;

    try testing.expectEqual(LoadOutcome.registered, bindNatives(&ptr));

    // Every declared method was handed to RegisterNatives in one call — a
    // partial registration would leave some actions bound and others throwing
    // UnsatisfiedLinkError at their first use.
    try testing.expectEqual(@as(jni.jint, @intCast(natives.len)), fake_registered_count);
}

test "each way the load can fail is reported as itself" {
    // These are the three states an app can actually be in, and telling them
    // apart is the difference between a one-line log and an afternoon: no
    // runtime linked, a stale Kotlin holder, a descriptor that stopped
    // matching.
    var invoke = fakeVm();
    const ptr: *const jni.JNIInvokeInterface = &invoke;

    fake_get_env_succeeds = false;
    try testing.expectEqual(LoadOutcome.no_env, bindNatives(&ptr));

    fake_get_env_succeeds = true;
    fake_find_class_succeeds = false;
    try testing.expectEqual(LoadOutcome.class_not_found, bindNatives(&ptr));

    fake_find_class_succeeds = true;
    fake_register_result = -1;
    try testing.expectEqual(LoadOutcome.register_failed, bindNatives(&ptr));
}

test "JNI_OnLoad asks for the version Android actually provides, and captures the VM" {
    // Returning a version ART does not offer fails the whole library load, and
    // surfaces as an UnsatisfiedLinkError with no useful cause.
    var invoke = fakeVm();
    const ptr: *const jni.JNIInvokeInterface = &invoke;
    try testing.expectEqual(jni.JNI_VERSION_1_6, JNI_OnLoad(&ptr, null));

    // The VM is the one handle that may be cached across threads, and a later
    // callback on a framework thread has nothing else to ask for its env.
    try testing.expect(vm() != null);
    java_vm = null;
}

test "the registered natives name methods the Kotlin actually declares" {
    // A descriptor is checked by the JVM at registration, so a wrong one fails
    // at load rather than at call — but only if the *name* matches something.
    // These two strings are the contract with CraftBridge.kt.
    try testing.expectEqual(@as(usize, 5), natives.len);
    try testing.expectEqualStrings("nativeGetDeviceInfo", std.mem.span(natives[0].name));

    // And the class they bind to is the fixed one, not the templated bridge.
    // A `{{` here would mean the library had been made app-specific.
    try testing.expectEqualStrings("com/craft/runtime/CraftNative", holder_class);
    try testing.expect(std.mem.indexOf(u8, holder_class, "{") == null);
    try testing.expectEqualStrings(
        "(Landroid/app/Activity;)Ljava/lang/String;",
        std.mem.span(natives[0].signature),
    );
}

test "the JavaVM table puts GetEnv where the header does" {
    try testing.expectEqual(@as(usize, 3), @offsetOf(jni.JNIInvokeInterface, "DestroyJavaVM") / @sizeOf(jni.JniFn));
    try testing.expectEqual(@as(usize, 4), @offsetOf(jni.JNIInvokeInterface, "AttachCurrentThread") / @sizeOf(jni.JniFn));
    try testing.expectEqual(@as(usize, 6), @offsetOf(jni.JNIInvokeInterface, "GetEnv") / @sizeOf(jni.JniFn));
    try testing.expectEqual(@as(usize, 8 * @sizeOf(jni.JniFn)), @sizeOf(jni.JNIInvokeInterface));
}

test "a JNINativeMethod is three pointers, in the header's order" {
    // RegisterNatives reads this array by offset like everything else in JNI.
    try testing.expectEqual(@as(usize, 0), @offsetOf(jni.JNINativeMethod, "name"));
    try testing.expectEqual(@as(usize, @sizeOf(usize)), @offsetOf(jni.JNINativeMethod, "signature"));
    try testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), @offsetOf(jni.JNINativeMethod, "fnPtr"));
}
