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
const permissions = @import("android_permissions.zig");
const device = @import("bridge_android_device.zig");
const system = @import("bridge_android_system.zig");
const clipboard = @import("bridge_android_clipboard.zig");
const intents = @import("bridge_android_intents.zig");
const imagepicker = @import("bridge_android_imagepicker.zig");
const biometric = @import("bridge_android_biometric.zig");
const review = @import("bridge_android_review.zig");
const speech = @import("bridge_android_speech.zig");
const network = @import("bridge_android_network.zig");
const appstate = @import("bridge_android_appstate.zig");
const bluetooth = @import("bridge_android_bluetooth.zig");
const motion = @import("bridge_android_motion.zig");
const position = @import("bridge_android_position.zig");
const json_number = @import("android_json_number.zig");
const securestore = @import("bridge_android_securestore.zig");
const haptics = @import("bridge_android_haptics.zig");
const notifications = @import("bridge_android_notifications.zig");
const events = @import("android_events.zig");
const calendar = @import("bridge_android_calendar.zig");
const db = @import("bridge_android_db.zig");
const shareditem = @import("bridge_android_shareditem.zig");
const contacts = @import("bridge_android_contacts.zig");
const widgets = @import("bridge_android_widgets.zig");
const shortcuts = @import("bridge_android_shortcuts.zig");
const screen = @import("bridge_android_screen.zig");
const files = @import("bridge_android_files.zig");
const locationstore = @import("bridge_android_locationstore.zig");
const main_thread = @import("android_main_thread.zig");

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

/// `CraftBridge.REQUEST_CALENDAR`, the request code the shim passes.
///
/// It has to match, because it is the only thing that would tell an
/// `onRequestPermissionsResult` which request it is answering — and if the
/// shim ever grows one, a code Zig invented would arrive as a request nothing
/// asked for.
const request_calendar: i32 = 1005;

/// The shim's default event length: `System.currentTimeMillis() + 3600000`.
const one_hour_ms: i64 = 60 * 60 * 1000;

/// `CraftBridge.REQUEST_CONTACTS`.
const request_contacts: i32 = 1004;

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
    // The reply channel needs the same handle, and needs it before any action
    // runs: a callback that fires between load and the first native call has
    // nowhere to deliver otherwise.
    events.setVm(vm_handle);

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
    .{
        .name = "nativeOpenUrl",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeOpenUrl),
    },
    .{
        .name = "nativeShare",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeShare),
    },
    .{
        .name = "nativeOpenCamera",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeOpenCamera),
    },
    .{
        .name = "nativePickImage",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativePickImage),
    },
    .{
        .name = "nativePickFile",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativePickFile),
    },
    .{
        .name = "nativeStartVideoRecording",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeStartVideoRecording),
    },
    .{
        .name = "nativeReviewSucceeded",
        .signature = "()V",
        .fnPtr = @ptrCast(&nativeReviewSucceeded),
    },
    .{
        .name = "nativeReviewError",
        .signature = "(Ljava/lang/String;)V",
        .fnPtr = @ptrCast(&nativeReviewError),
    },
    .{
        .name = "nativeRequestReview",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeRequestReview),
    },
    .{
        .name = "nativeSpeechReady",
        .signature = "(Landroid/app/Activity;)V",
        .fnPtr = @ptrCast(&nativeSpeechReady),
    },
    .{
        .name = "nativeSpeechError",
        .signature = "(Landroid/app/Activity;I)V",
        .fnPtr = @ptrCast(&nativeSpeechError),
    },
    .{
        .name = "nativeSpeechResult",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;Z)V",
        .fnPtr = @ptrCast(&nativeSpeechResult),
    },
    .{
        .name = "nativeStartListening",
        .signature = "(Landroid/app/Activity;Z)Z",
        .fnPtr = @ptrCast(&nativeStartListening),
    },
    .{
        .name = "nativeStopListening",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeStopListening),
    },
    // The callback object is Kotlin's; these two are its outcomes, and the
    // third starts the prompt or rejects an unsupported Activity.
    .{
        .name = "nativeBiometricSucceeded",
        .signature = "()V",
        .fnPtr = @ptrCast(&nativeBiometricSucceeded),
    },
    .{
        .name = "nativeBiometricError",
        .signature = "(Ljava/lang/String;)V",
        .fnPtr = @ptrCast(&nativeBiometricError),
    },
    .{
        .name = "nativeAuthenticate",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;Z)Z",
        .fnPtr = @ptrCast(&nativeAuthenticate),
    },
    .{
        .name = "nativeGetNetworkStatus",
        .signature = "(Landroid/app/Activity;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeGetNetworkStatus),
    },
    // These four take the SharedPreferences rather than the Activity: the
    // store is EncryptedSharedPreferences over a MasterKey the Kotlin already
    // built, and rebuilding it here would be a second implementation of a
    // security-sensitive construction that has to agree exactly.
    .{
        .name = "nativeSecureSet",
        .signature = "(Landroid/content/SharedPreferences;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeSecureSet),
    },
    .{
        .name = "nativeSecureGet",
        .signature = "(Landroid/content/SharedPreferences;Ljava/lang/String;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeSecureGet),
    },
    .{
        .name = "nativeSecureRemove",
        .signature = "(Landroid/content/SharedPreferences;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeSecureRemove),
    },
    .{
        .name = "nativeSecureClear",
        .signature = "(Landroid/content/SharedPreferences;)Z",
        .fnPtr = @ptrCast(&nativeSecureClear),
    },
    .{
        .name = "nativeHaptic",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeHaptic),
    },
    .{
        .name = "nativeVibrate",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeVibrate),
    },
    .{
        .name = "nativeCancelNotification",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeCancelNotification),
    },
    .{
        .name = "nativeCancelAllNotifications",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeCancelAllNotifications),
    },
    // The first action that answers through the reply channel rather than by
    // returning. The boolean still means "Zig served it" — the *result* goes
    // to the page separately, which is exactly the shape iOS's seam has.
    .{
        .name = "nativeDeleteCalendarEvent",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeDeleteCalendarEvent),
    },
    .{
        .name = "nativeGetCalendarEvents",
        .signature = "(Landroid/app/Activity;JJ)Z",
        .fnPtr = @ptrCast(&nativeGetCalendarEvents),
    },
    .{
        .name = "nativeCreateCalendarEvent",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeCreateCalendarEvent),
    },
    // The database arrives as an argument rather than being opened here, so
    // one connection serves both languages — the same shape the secure store
    // uses for its SharedPreferences.
    .{
        .name = "nativeDbExecute",
        .signature = "(Landroid/database/sqlite/SQLiteDatabase;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeDbExecute),
    },
    .{
        .name = "nativeDbQuery",
        .signature = "(Landroid/database/sqlite/SQLiteDatabase;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeDbQuery),
    },
    .{
        .name = "nativeSetSharedItem",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeSetSharedItem),
    },
    .{
        .name = "nativeGetSharedItem",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeGetSharedItem),
    },
    .{
        .name = "nativeRemoveSharedItem",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeRemoveSharedItem),
    },
    .{
        .name = "nativeGetContacts",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeGetContacts),
    },
    .{
        .name = "nativeAddContact",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeAddContact),
    },
    .{
        .name = "nativePickContact",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativePickContact),
    },
    // The broadcast action is passed across rather than built here: it is a
    // compile-time constant in the generated app, and deriving it from the
    // runtime package name would silently stop matching under an
    // `applicationIdSuffix`.
    .{
        .name = "nativeUpdateWidget",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeUpdateWidget),
    },
    .{
        .name = "nativeReloadWidgets",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeReloadWidgets),
    },
    .{
        .name = "nativeSetShortcuts",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeSetShortcuts),
    },
    .{
        .name = "nativeClearShortcuts",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeClearShortcuts),
    },
    .{
        .name = "nativeScheduleNotification",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeScheduleNotification),
    },
    // Not an action: the other end of `CraftNative.runOnMain`, which is how
    // anything here reaches the main looper at all.
    .{
        .name = "nativeRunTask",
        .signature = "(Landroid/app/Activity;J)V",
        .fnPtr = @ptrCast(&nativeRunTask),
    },
    .{
        .name = "nativeLockOrientation",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeLockOrientation),
    },
    .{
        .name = "nativeUnlockOrientation",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeUnlockOrientation),
    },
    .{
        .name = "nativeSetKeepAwake",
        .signature = "(Landroid/app/Activity;Z)Z",
        .fnPtr = @ptrCast(&nativeSetKeepAwake),
    },
    .{
        .name = "nativeDownloadFile",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeDownloadFile),
    },
    .{
        .name = "nativeSaveFile",
        .signature = "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;)Z",
        .fnPtr = @ptrCast(&nativeSaveFile),
    },
    // Both answer by returning a String, like clipboardRead: null means "ask
    // the shim" rather than "there is nothing".
    .{
        .name = "nativeGetLocationRecordingState",
        .signature = "(Landroid/app/Activity;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeGetLocationRecordingState),
    },
    .{
        .name = "nativeReadLocationRecording",
        .signature = "(Landroid/app/Activity;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeReadLocationRecording),
    },
    .{
        .name = "nativeStartLocationRecording",
        .signature = "(Landroid/app/Activity;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeStartLocationRecording),
    },
    .{
        .name = "nativeStopLocationRecording",
        .signature = "(Landroid/app/Activity;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeStopLocationRecording),
    },
    .{
        .name = "nativePauseLocationRecording",
        .signature = "(Landroid/app/Activity;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativePauseLocationRecording),
    },
    .{
        .name = "nativeResumeLocationRecording",
        .signature = "(Landroid/app/Activity;)Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeResumeLocationRecording),
    },
    // Not an action: the other end of the network callback the holder owns.
    .{
        .name = "nativeNetworkChanged",
        .signature = "(Landroid/app/Activity;)V",
        .fnPtr = @ptrCast(&nativeNetworkChanged),
    },
    .{
        .name = "nativeStartNetworkMonitoring",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeStartNetworkMonitoring),
    },
    .{
        .name = "nativeStopNetworkMonitoring",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeStopNetworkMonitoring),
    },
    // Not an action: the other end of the lifecycle observer the holder owns.
    // It takes no Activity, because everything it does is state and the reply
    // channel — neither of which needs one.
    .{
        .name = "nativeAppStateEvent",
        .signature = "(Ljava/lang/String;)V",
        .fnPtr = @ptrCast(&nativeAppStateEvent),
    },
    .{
        .name = "nativeStartAppStateMonitoring",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeStartAppStateMonitoring),
    },
    .{
        .name = "nativeStopAppStateMonitoring",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeStopAppStateMonitoring),
    },
    .{
        .name = "nativeGetAppState",
        .signature = "()Ljava/lang/String;",
        .fnPtr = @ptrCast(&nativeGetAppState),
    },
    // Not an action: the other end of the ScanCallback the holder owns. The
    // name arrives nullable, so the "Unknown" default stays a Zig decision.
    .{
        .name = "nativeBluetoothDevice",
        .signature = "(Ljava/lang/String;Ljava/lang/String;I)V",
        .fnPtr = @ptrCast(&nativeBluetoothDevice),
    },
    .{
        .name = "nativeStartBluetoothScan",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeStartBluetoothScan),
    },
    .{
        .name = "nativeStopBluetoothScan",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeStopBluetoothScan),
    },
    // Not an action: the other end of the SensorEventListener the holder owns.
    .{
        .name = "nativeMotionSample",
        .signature = "(ZFFF)V",
        .fnPtr = @ptrCast(&nativeMotionSample),
    },
    .{
        .name = "nativeStartMotionUpdates",
        .signature = "(Landroid/app/Activity;I)Z",
        .fnPtr = @ptrCast(&nativeStartMotionUpdates),
    },
    .{
        .name = "nativeStopMotionUpdates",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeStopMotionUpdates),
    },
    // Not actions: the two ends of the Play Services task listeners the
    // holder owns.
    .{
        .name = "nativeLocationResult",
        .signature = "(DDDDDDJ)V",
        .fnPtr = @ptrCast(&nativeLocationResult),
    },
    .{
        .name = "nativeLocationFailed",
        .signature = "(Ljava/lang/String;)V",
        .fnPtr = @ptrCast(&nativeLocationFailed),
    },
    .{
        .name = "nativeGetCurrentPosition",
        .signature = "(Landroid/app/Activity;)Z",
        .fnPtr = @ptrCast(&nativeGetCurrentPosition),
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

    // Re-encoded rather than handed over: this JSON carries device text — a
    // model name, a carrier — and `NewStringUTF` reads modified UTF-8, where a
    // NUL is two bytes and an astral character is a surrogate pair.
    return j.newStringUtf8(allocator, json) catch null;
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
    return j.newStringUtf8(allocator, json) catch null;
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

    system.writeLog(j, allocator, text) catch |err| {
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

    return j.newStringUtf8(allocator, text) catch null;
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

    clipboard.write(j, allocator, activity, value) catch |err| {
        std.log.warn("craft: clipboardWrite fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// A `jstring` as arena-owned UTF-8, or null.
///
/// Every native below needs this and none of them can share the result, since
/// each arena dies with its call. A plain slice: the JNI side re-encodes on
/// the way back out, so nothing here has to carry a terminator.
fn ownedUtf8(j: Jni, allocator: std.mem.Allocator, str: jni.jstring) ?[]u8 {
    return j.stringToUtf8(allocator, str) catch null;
}

fn nativeOpenUrl(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    url: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();

    const allocator = arena.allocator();

    const value = ownedUtf8(j, allocator, url) orelse return jni.JNI_FALSE;
    intents.openUrl(j, allocator, activity, value) catch |err| {
        // Not a warning. `openURL` answering false is the documented outcome
        // when nothing on the device handles the scheme, and the Kotlin
        // catches exactly this — logging it at warn would put a line in
        // logcat for a page doing something reasonable.
        std.log.debug("craft: openURL declined ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativeShare(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    text: jni.jstring,
    title: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = ownedUtf8(j, allocator, text) orelse return jni.JNI_FALSE;
    const subject = ownedUtf8(j, allocator, title) orelse return jni.JNI_FALSE;

    intents.share(j, allocator, activity, body, subject) catch |err| {
        std.log.warn("craft: share fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativeOpenCamera(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    imagepicker.openCamera(j, activity) catch |err| {
        std.log.warn("craft: openCamera fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativePickImage(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    imagepicker.pickImage(j, activity) catch |err| {
        std.log.warn("craft: pickImage fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativePickFile(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    imagepicker.pickFile(j, activity) catch |err| {
        std.log.warn("craft: pickFile fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativeStartVideoRecording(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    imagepicker.startVideoRecording(j, activity) catch |err| {
        std.log.warn("craft: startVideoRecording fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativeReviewSucceeded(_: jni.JNIEnv, _: jni.jobject) callconv(.c) void {
    events.settle(backing, review.resolve_global, "true") catch {};
}

fn nativeReviewError(
    env: jni.JNIEnv,
    _: jni.jobject,
    message: jni.jstring,
) callconv(.c) void {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = j.stringToUtf8(allocator, message) catch return;
    const payload = review.rejectionPayload(allocator, text) catch return;
    events.settle(allocator, review.reject_global, payload) catch {};
}

fn nativeRequestReview(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    review.request(Jni.init(env), activity) catch |err| {
        std.log.warn("craft: requestReview fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn speechHaptic(j: Jni, activity: jni.jobject) void {
    haptics.play(j, activity, haptics.effectForStyle("light")) catch {};
}

fn nativeSpeechReady(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) void {
    events.emitEvent(backing, speech.start_event, "{}") catch {};
    speechHaptic(Jni.init(env), activity);
}

fn nativeSpeechError(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    error_code: jni.jint,
) callconv(.c) void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const detail = speech.errorDetail(allocator, speech.errorMessage(error_code)) catch return;
    events.emitEvent(allocator, speech.error_event, detail) catch {};
    speechHaptic(Jni.init(env), activity);
}

fn nativeSpeechResult(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    transcript: jni.jstring,
    is_final: jni.jboolean,
) callconv(.c) void {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = j.stringToUtf8(allocator, transcript) catch return;
    const final = is_final == jni.JNI_TRUE;
    const detail = speech.resultDetail(allocator, text, final) catch return;
    events.emitEvent(allocator, speech.result_event, detail) catch {};
    if (final) {
        events.emitEvent(allocator, speech.end_event, "{}") catch {};
        speechHaptic(j, activity);
    }
}

fn nativeStartListening(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    available: jni.jboolean,
) callconv(.c) jni.jboolean {
    if (available != jni.JNI_TRUE) {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const allocator = arena.allocator();
        const detail = speech.errorDetail(allocator, speech.unavailable) catch return jni.JNI_FALSE;
        events.emitEvent(allocator, speech.error_event, detail) catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    }

    const j = Jni.init(env);
    const holder = j.findClass(holder_class) catch return jni.JNI_FALSE;
    j.callStaticVoidMethodA(
        holder,
        j.staticMethodId(holder, "beginSpeechRecognition", "(Landroid/app/Activity;)V") catch
            return jni.JNI_FALSE,
        &.{.{ .l = activity }},
    ) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

fn nativeStopListening(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    const holder = j.findClass(holder_class) catch return jni.JNI_FALSE;
    j.callStaticVoidMethodA(
        holder,
        j.staticMethodId(holder, "endSpeechRecognition", "(Landroid/app/Activity;)V") catch
            return jni.JNI_FALSE,
        &.{.{ .l = activity }},
    ) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

fn nativeBiometricSucceeded(
    _: jni.JNIEnv,
    _: jni.jobject,
) callconv(.c) void {
    events.settle(backing, biometric.resolve_global, "true") catch {};
}

fn nativeBiometricError(
    env: jni.JNIEnv,
    _: jni.jobject,
    message: jni.jstring,
) callconv(.c) void {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = j.stringToUtf8(allocator, message) catch return;
    const payload = biometric.rejectionPayload(allocator, text) catch return;
    events.settle(allocator, biometric.reject_global, payload) catch {};
}

fn nativeAuthenticate(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    reason: jni.jstring,
    supported: jni.jboolean,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    if (supported == jni.JNI_FALSE) {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const allocator = arena.allocator();
        const payload = biometric.rejectionPayload(allocator, biometric.unsupported_activity) catch
            return jni.JNI_FALSE;
        events.settle(allocator, biometric.reject_global, payload) catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    }

    const holder = j.findClass(holder_class) catch return jni.JNI_FALSE;
    j.callStaticVoidMethodA(
        holder,
        j.staticMethodId(
            holder,
            "showBiometricPrompt",
            "(Landroid/app/Activity;Ljava/lang/String;)V",
        ) catch return jni.JNI_FALSE,
        &.{ .{ .l = activity }, .{ .l = reason } },
    ) catch |err| {
        std.log.warn("craft: authenticate fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativeGetNetworkStatus(env: jni.JNIEnv, _: jni.jobject, activity: jni.jobject) callconv(.c) jni.jstring {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const status = network.read(j, activity) catch |err| {
        std.log.warn("craft: getNetworkStatus fell through to the shim ({s})", .{@errorName(err)});
        return null;
    };

    const json = network.render(allocator, status) catch return null;
    return j.newStringUtf8(allocator, json) catch null;
}

fn nativeSecureSet(
    env: jni.JNIEnv,
    _: jni.jobject,
    prefs: jni.jobject,
    key: jni.jstring,
    value: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const k = ownedUtf8(j, allocator, key) orelse return jni.JNI_FALSE;
    const v = ownedUtf8(j, allocator, value) orelse return jni.JNI_FALSE;

    securestore.set(j, allocator, prefs, k, v) catch |err| {
        std.log.warn("craft: secureSet fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// Returns the `{"found":…}` envelope, or null when Zig did not serve the call.
///
/// Null cannot mean "no such key" here — the Kotlin already uses null for
/// that, and the seam needs a third answer. See the module comment on
/// `bridge_android_securestore.zig`.
fn nativeSecureGet(
    env: jni.JNIEnv,
    _: jni.jobject,
    prefs: jni.jobject,
    key: jni.jstring,
) callconv(.c) jni.jstring {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const k = ownedUtf8(j, allocator, key) orelse return null;
    const value = securestore.get(allocator, j, prefs, k) catch |err| {
        std.log.warn("craft: secureGet fell through to the shim ({s})", .{@errorName(err)});
        return null;
    };

    const json = securestore.renderRead(allocator, value) catch return null;
    return j.newStringUtf8(allocator, json) catch null;
}

fn nativeSecureRemove(
    env: jni.JNIEnv,
    _: jni.jobject,
    prefs: jni.jobject,
    key: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();

    const allocator = arena.allocator();

    const k = ownedUtf8(j, allocator, key) orelse return jni.JNI_FALSE;
    securestore.remove(j, allocator, prefs, k) catch |err| {
        std.log.warn("craft: secureRemove fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativeSecureClear(env: jni.JNIEnv, _: jni.jobject, prefs: jni.jobject) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    securestore.clear(j, prefs) catch |err| {
        std.log.warn("craft: secureClear fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativeHaptic(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    style: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();

    const text = j.stringToUtf8(arena.allocator(), style) catch return jni.JNI_FALSE;
    haptics.play(j, activity, haptics.effectForStyle(text)) catch |err| {
        std.log.warn("craft: haptic fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativeVibrate(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    pattern_json: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json = j.stringToUtf8(allocator, pattern_json) catch return jni.JNI_FALSE;

    // Null is a pattern the shim would throw on. Declining lets it throw, log
    // "Vibration error", and vibrate nothing — the same outcome with the log
    // kept. See bridge_android_haptics.parsePattern.
    const timings = haptics.parsePattern(allocator, json) catch return jni.JNI_FALSE;
    if (timings == null) return jni.JNI_FALSE;

    haptics.play(j, activity, .{ .waveform = timings.? }) catch |err| {
        std.log.warn("craft: vibrate fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// The jstring goes through untouched — the id is hashed by Java, and
/// converting to UTF-8 first would throw away the representation the hash is
/// defined over. See bridge_android_notifications.
fn nativeCancelNotification(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    id: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    notifications.cancel(j, activity, id) catch |err| {
        std.log.warn("craft: cancelNotification fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

fn nativeCancelAllNotifications(env: jni.JNIEnv, _: jni.jobject, activity: jni.jobject) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    notifications.cancelAll(j, activity) catch |err| {
        std.log.warn("craft: cancelAllNotifications fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeDeleteCalendarEvent(activity, eventId)`.
///
/// Returns whether Zig took the action, not whether the delete succeeded. The
/// outcome reaches the page through the reply channel, so a `true` here means
/// "do not also run the Kotlin" and nothing more — the same distinction
/// `ios_dispatch` draws between claiming an action and answering it.
fn nativeDeleteCalendarEvent(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    event_id: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = j.stringToUtf8(allocator, event_id) catch return jni.JNI_FALSE;

    const id = calendar.parseEventId(text) orelse {
        // What the shim's NumberFormatException produces, with the message it
        // produces — but escaped, so an id containing a quote rejects instead
        // of hanging the promise. See #154.
        var message: std.ArrayListUnmanaged(u8) = .empty;
        defer message.deinit(allocator);
        message.appendSlice(allocator, "For input string: \"") catch return jni.JNI_FALSE;
        message.appendSlice(allocator, text) catch return jni.JNI_FALSE;
        message.append(allocator, '"') catch return jni.JNI_FALSE;

        calendar.rejectWith(allocator, message.items) catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    };

    calendar.deleteEvent(j, activity, id) catch |err| {
        // A SecurityException for a missing WRITE_CALENDAR permission lands
        // here, as it lands in the shim's catch. The error name rather than
        // the Java message: the throwable was already described to logcat and
        // cleared by `Jni.check`, so its text is gone by now.
        calendar.rejectWith(allocator, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    events.settle(allocator, calendar.resolve_global, "true") catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeGetCalendarEvents(activity, startDateMs, endDateMs)`.
///
/// Reads the calendar and settles `_craftCalendarResolve` with the array.
///
/// ## Where this returns false
///
/// Only before anything has been sent. A failure after the reply channel has
/// been used would settle the page's promise twice, since a false sends the
/// shim down the same path — so the JNI work runs to completion or reports
/// nothing at all, and the shim answers instead.
///
/// That includes the case where the query itself throws. The shim wraps none
/// of `getCalendarEvents` in a try/catch, so a `SecurityException` from a
/// permission revoked between the check and the query propagates out of the
/// `@JavascriptInterface` method and the promise hangs. Rejecting here would
/// be kinder and would also be a divergence nothing records, so this falls
/// through and lets the shim behave as it does. See #157.
fn nativeGetCalendarEvents(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    start_date_ms: jni.jlong,
    end_date_ms: jni.jlong,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const granted = permissions.isGranted(j, activity, permissions.read_calendar) catch |err| {
        std.log.warn("craft: getCalendarEvents fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    if (!granted) {
        // The shim asks and rejects in the same breath: the answer arrives at
        // `onRequestPermissionsResult`, which nothing here implements, so the
        // request is what makes a *later* call work rather than this one.
        permissions.request(j, activity, permissions.read_calendar, request_calendar) catch |err| {
            std.log.warn("craft: getCalendarEvents fell through to the shim ({s})", .{@errorName(err)});
            return jni.JNI_FALSE;
        };
        events.settle(allocator, calendar.list_reject_global, "\"Permission denied\"") catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    }

    const now = calendar.currentTimeMillis(j) catch |err| {
        std.log.warn("craft: getCalendarEvents fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    const window = calendar.windowFor(start_date_ms, end_date_ms, now);

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    calendar.queryEvents(j, allocator, activity, window, &payload) catch |err| {
        std.log.warn("craft: getCalendarEvents fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    events.settle(allocator, calendar.list_resolve_global, payload.items) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeCreateCalendarEvent(activity, eventJson)`.
///
/// Returns false — leaving the shim to serve it — for any payload outside the
/// shape `NewCalendarEvent` declares. `org.json` coerces a `startDate` sent as
/// a string and a `title` sent as a number, and the string forms it produces
/// for a `Double` are not something to reproduce from memory. Declining is
/// cheap here because nothing has been sent yet.
fn nativeCreateCalendarEvent(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    event_json: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const granted = permissions.isGranted(j, activity, permissions.write_calendar) catch |err| {
        std.log.warn("craft: createCalendarEvent fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    if (!granted) {
        permissions.request(j, activity, permissions.write_calendar, request_calendar) catch |err| {
            std.log.warn("craft: createCalendarEvent fell through to the shim ({s})", .{@errorName(err)});
            return jni.JNI_FALSE;
        };
        events.settle(allocator, calendar.create_reject_global, "\"Permission denied\"") catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    }

    const text = j.stringToUtf8(allocator, event_json) catch return jni.JNI_FALSE;

    // `JSONTokener` is lenient where `std.json` is strict — unquoted keys,
    // single quotes, a trailing comma. Everything strict JSON accepts it
    // accepts too, so the difference only ever sends work back to the shim.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
        return jni.JNI_FALSE;
    defer parsed.deinit();

    const start_default = calendar.currentTimeMillis(j) catch return jni.JNI_FALSE;
    const end_default = calendar.currentTimeMillis(j) catch return jni.JNI_FALSE;
    const event = calendar.parseNewEvent(
        parsed.value,
        start_default,
        end_default +% one_hour_ms,
    ) orelse return jni.JNI_FALSE;

    const id = calendar.insertEvent(j, allocator, activity, event) catch |err| {
        // The shim catches here and rejects with the exception's message. The
        // throwable was described to logcat and cleared by `Jni.check` before
        // this point, so the error name is what is left to say.
        calendar.rejectOn(allocator, calendar.create_reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    const payload = calendar.jsonString(allocator, id) catch return jni.JNI_FALSE;
    events.settle(allocator, calendar.create_resolve_global, payload) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// The parameters and SQL both actions start from, or null to decline.
///
/// Declining costs nothing here because it happens before any JNI call that
/// could change the database — the shim then runs the whole method, including
/// its own parse.
fn dbCall(
    j: Jni,
    allocator: std.mem.Allocator,
    sql: jni.jstring,
    params_json: jni.jstring,
    parsed: *std.json.Parsed(std.json.Value),
) !?struct { sql: []const u8, args: [][]const u8 } {
    const sql_text = try j.stringToUtf8(allocator, sql);
    const params_text = try j.stringToUtf8(allocator, params_json);

    parsed.* = std.json.parseFromSlice(std.json.Value, allocator, params_text, .{}) catch
        return null;

    const args = (try db.bindArgs(allocator, parsed.value)) orelse return null;
    return .{ .sql = sql_text, .args = args };
}

/// `nativeDbExecute(database, sql, paramsJson)`.
fn nativeDbExecute(
    env: jni.JNIEnv,
    _: jni.jobject,
    database: jni.jobject,
    sql: jni.jstring,
    params_json: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed: std.json.Parsed(std.json.Value) = undefined;
    const call = (dbCall(j, allocator, sql, params_json, &parsed) catch return jni.JNI_FALSE) orelse
        return jni.JNI_FALSE;

    db.execute(j, allocator, database, call.sql, call.args) catch |err| {
        // The shim catches and rejects with the exception's message; the
        // throwable was described to logcat and cleared by `Jni.check` before
        // this point, so the error name is what is left to say.
        calendar.rejectOn(allocator, db.exec_reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    events.settle(allocator, db.exec_resolve_global, db.exec_result) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeDbQuery(database, sql, paramsJson)`.
fn nativeDbQuery(
    env: jni.JNIEnv,
    _: jni.jobject,
    database: jni.jobject,
    sql: jni.jstring,
    params_json: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed: std.json.Parsed(std.json.Value) = undefined;
    const call = (dbCall(j, allocator, sql, params_json, &parsed) catch return jni.JNI_FALSE) orelse
        return jni.JNI_FALSE;

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    db.query(j, allocator, database, call.sql, call.args, &payload) catch |err| {
        calendar.rejectOn(allocator, db.query_reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    events.settle(allocator, db.query_resolve_global, payload.items) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeSetSharedItem(activity, key, value, group)`.
fn nativeSetSharedItem(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    key: jni.jstring,
    value: jni.jstring,
    group: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const key_text = j.stringToUtf8(allocator, key) catch return jni.JNI_FALSE;
    const value_text = j.stringToUtf8(allocator, value) catch return jni.JNI_FALSE;
    const group_text = j.stringToUtf8(allocator, group) catch return jni.JNI_FALSE;

    shareditem.set(j, allocator, activity, group_text, key_text, value_text) catch |err| {
        calendar.rejectOn(allocator, shareditem.reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    const payload = shareditem.successPayload(allocator, key_text) catch return jni.JNI_FALSE;
    events.settle(allocator, shareditem.resolve_global, payload) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeGetSharedItem(activity, key, group)`.
///
/// An absent key resolves with `{value: null}` rather than rejecting, which is
/// the shim's answer: a page reading a key it never wrote has done nothing
/// wrong.
fn nativeGetSharedItem(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    key: jni.jstring,
    group: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const key_text = j.stringToUtf8(allocator, key) catch return jni.JNI_FALSE;
    const group_text = j.stringToUtf8(allocator, group) catch return jni.JNI_FALSE;

    const value = shareditem.get(j, allocator, activity, group_text, key_text) catch |err| {
        calendar.rejectOn(allocator, shareditem.reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    const payload = shareditem.valuePayload(allocator, key_text, value) catch return jni.JNI_FALSE;
    events.settle(allocator, shareditem.resolve_global, payload) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeRemoveSharedItem(activity, key, group)`.
fn nativeRemoveSharedItem(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    key: jni.jstring,
    group: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const key_text = j.stringToUtf8(allocator, key) catch return jni.JNI_FALSE;
    const group_text = j.stringToUtf8(allocator, group) catch return jni.JNI_FALSE;

    shareditem.remove(j, allocator, activity, group_text, key_text) catch |err| {
        calendar.rejectOn(allocator, shareditem.reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    const payload = shareditem.successPayload(allocator, key_text) catch return jni.JNI_FALSE;
    events.settle(allocator, shareditem.resolve_global, payload) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeGetContacts(activity)`.
///
/// Falls through when the query fails, for the reason `getCalendarEvents`
/// does: the shim wraps none of `getContacts` in a try/catch, so an exception
/// escapes the `@JavascriptInterface` method and the promise hangs. Inventing
/// a rejection here would be kinder and would be a divergence nothing
/// records. See #157.
fn nativeGetContacts(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const granted = permissions.isGranted(j, activity, permissions.read_contacts) catch |err| {
        std.log.warn("craft: getContacts fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    if (!granted) {
        permissions.request(j, activity, permissions.read_contacts, request_contacts) catch |err| {
            std.log.warn("craft: getContacts fell through to the shim ({s})", .{@errorName(err)});
            return jni.JNI_FALSE;
        };
        events.settle(allocator, contacts.reject_global, "\"Permission denied\"") catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    }

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    contacts.queryContacts(j, allocator, activity, &payload) catch |err| {
        std.log.warn("craft: getContacts fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    events.settle(allocator, contacts.resolve_global, payload.items) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeAddContact(activity, contactJson)`.
///
/// Resolves with the new contact's id as a JSON *string*, because the shim
/// interpolated a `Long` into a quoted JavaScript string and the page has
/// always received text.
fn nativeAddContact(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    contact_json: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const granted = permissions.isGranted(j, activity, permissions.write_contacts) catch |err| {
        std.log.warn("craft: addContact fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    if (!granted) {
        permissions.request(j, activity, permissions.write_contacts, request_contacts) catch |err| {
            std.log.warn("craft: addContact fell through to the shim ({s})", .{@errorName(err)});
            return jni.JNI_FALSE;
        };
        events.settle(allocator, contacts.add_reject_global, "\"Permission denied\"") catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    }

    const text = j.stringToUtf8(allocator, contact_json) catch return jni.JNI_FALSE;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
        return jni.JNI_FALSE;
    defer parsed.deinit();

    const contact = contacts.parseNewContact(parsed.value) orelse return jni.JNI_FALSE;

    const id = contacts.addContact(j, allocator, activity, contact) catch |err| {
        calendar.rejectOn(allocator, contacts.add_reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    var buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{id}) catch return jni.JNI_FALSE;
    const payload = calendar.jsonString(allocator, digits) catch return jni.JNI_FALSE;
    events.settle(allocator, contacts.add_resolve_global, payload) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativePickContact(activity)`.
///
/// True means the permission request or picker launch was queued. As in the
/// shim, neither path settles the promise: the Activity result is not routed
/// to `handleContactPickerResult` by the generated `MainActivity`.
fn nativePickContact(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    contacts.pickContact(Jni.init(env), activity) catch |err| {
        std.log.warn("craft: pickContact fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeUpdateWidget(activity, action, dataJson)`.
fn nativeUpdateWidget(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    action: jni.jstring,
    data_json: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = j.stringToUtf8(allocator, data_json) catch return jni.JNI_FALSE;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
        return jni.JNI_FALSE;
    defer parsed.deinit();

    const update = widgets.parseUpdate(parsed.value) orelse return jni.JNI_FALSE;
    const action_text = j.stringToUtf8(allocator, action) catch return jni.JNI_FALSE;

    widgets.writeUpdate(j, allocator, activity, update) catch |err| {
        calendar.rejectOn(allocator, widgets.reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };
    widgets.broadcast(j, allocator, activity, action_text) catch |err| {
        calendar.rejectOn(allocator, widgets.reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    events.settle(allocator, widgets.resolve_global, widgets.updated_result) catch
        return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeReloadWidgets(activity, action)`.
///
/// The shim wraps none of `reloadWidgets` in a try/catch, so a `sendBroadcast`
/// that throws escapes the `@JavascriptInterface` method and the promise
/// hangs. Rejecting here diverges in the page's favour, and unlike
/// `getCalendarEvents` there is nothing to fall through *to* — the shim would
/// hang. So this one rejects, and says so rather than reproducing a hang.
fn nativeReloadWidgets(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    action: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const action_text = j.stringToUtf8(allocator, action) catch return jni.JNI_FALSE;

    widgets.broadcast(j, allocator, activity, action_text) catch |err| {
        calendar.rejectOn(allocator, widgets.reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    events.settle(allocator, widgets.resolve_global, widgets.reloaded_result) catch
        return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeSetShortcuts(activity, shortcutsJson)`.
fn nativeSetShortcuts(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    shortcuts_json: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sdk = shortcuts.sdkInt(j) catch |err| {
        std.log.warn("craft: setShortcuts fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    if (sdk < shortcuts.n_mr1) {
        const payload = shortcuts.jsonString(allocator, shortcuts.unsupported_message) catch
            return jni.JNI_FALSE;
        events.settle(allocator, shortcuts.reject_global, payload) catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    }

    const text = j.stringToUtf8(allocator, shortcuts_json) catch return jni.JNI_FALSE;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
        return jni.JNI_FALSE;
    defer parsed.deinit();

    // `getString` raises where `optString` defaults, so a payload missing a
    // title is a rejection rather than a shape to hand back — and the shim
    // sets nothing at all, including the entries that parsed.
    const list = shortcuts.parseShortcuts(allocator, parsed.value) catch |err| {
        const payload = shortcuts.jsonString(allocator, @errorName(err)) catch
            return jni.JNI_FALSE;
        events.settle(allocator, shortcuts.reject_global, payload) catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    } orelse return jni.JNI_FALSE;

    shortcuts.set(j, allocator, activity, list) catch |err| {
        const payload = shortcuts.jsonString(allocator, @errorName(err)) catch
            return jni.JNI_FALSE;
        events.settle(allocator, shortcuts.reject_global, payload) catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    };

    const payload = shortcuts.countPayload(allocator, list.len) catch return jni.JNI_FALSE;
    events.settle(allocator, shortcuts.resolve_global, payload) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeClearShortcuts(activity)`.
///
/// Resolves `true` below API 25 without touching anything, because that is
/// what the shim does: nothing to clear is the same as having cleared it.
fn nativeClearShortcuts(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sdk = shortcuts.sdkInt(j) catch |err| {
        std.log.warn("craft: clearShortcuts fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    if (sdk >= shortcuts.n_mr1) {
        shortcuts.clear(j, activity) catch |err| {
            const payload = shortcuts.jsonString(allocator, @errorName(err)) catch
                return jni.JNI_FALSE;
            events.settle(allocator, shortcuts.reject_global, payload) catch return jni.JNI_FALSE;
            return jni.JNI_TRUE;
        };
    }

    events.settle(allocator, shortcuts.resolve_global, "true") catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeScheduleNotification(activity, notificationJson)`.
///
/// Serves only the immediate half. A `delay` above zero needs
/// `Handler.postDelayed`, which needs a `Runnable`, which Zig cannot make —
/// so it is handed back *before* the channel is created or the notification
/// built, because the shim does both on that path too and doing them twice
/// would post nothing visible but would still be wrong.
fn nativeScheduleNotification(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    notification_json: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = j.stringToUtf8(allocator, notification_json) catch return jni.JNI_FALSE;

    // `JSONObject(notificationJson)` throwing is the shim's first catch, so a
    // payload this cannot parse goes back rather than being rejected here.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
        return jni.JNI_FALSE;
    defer parsed.deinit();

    const default_id = notifications.defaultId(j, allocator) catch return jni.JNI_FALSE;
    const notification = notifications.parseNotification(parsed.value, default_id) orelse
        return jni.JNI_FALSE;

    if (!notifications.servesImmediately(notification)) return jni.JNI_FALSE;

    notifications.ensureChannel(j, activity) catch |err| {
        calendar.rejectOn(allocator, notifications.schedule_reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    _ = notifications.post(j, allocator, activity, notification) catch |err| {
        calendar.rejectOn(allocator, notifications.schedule_reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    // The id, not the hash: the page sent a string and gets the same string
    // back, which is what it needs to cancel with later.
    const payload = calendar.jsonString(allocator, notification.id) catch return jni.JNI_FALSE;
    events.settle(allocator, notifications.schedule_resolve_global, payload) catch
        return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeRunTask(activity, token)` — the main thread, arrived at.
///
/// The only native here that is not an action. `CraftNative.runOnMain` posted
/// a `Runnable` that calls this, so by the time it runs the looper is ours and
/// the Activity came back with it rather than being held across the hop.
///
/// Void and silent: there is nothing to answer to. A token that no longer
/// names a task is dropped by `main_thread.run`, which is the case a
/// `Runnable` outliving whatever queued it would otherwise crash on.
fn nativeRunTask(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    token: jni.jlong,
) callconv(.c) void {
    main_thread.run(Jni.init(env), activity, @bitCast(token));
}

/// `nativeLockOrientation(activity, orientation)`.
///
/// True means the work is queued, not that the device has turned — which is
/// what the shim's `return true` after `runOnUiThread` means too.
fn nativeLockOrientation(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    name: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();

    const text = j.stringToUtf8(arena.allocator(), name) catch return jni.JNI_FALSE;

    screen.apply(j, activity, screen.modeFor(text)) catch |err| {
        std.log.warn("craft: lockOrientation fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeUnlockOrientation(activity)`.
fn nativeUnlockOrientation(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    screen.apply(j, activity, .unspecified) catch |err| {
        std.log.warn("craft: unlockOrientation fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeSetKeepAwake(activity, enabled)`.
///
/// Safe to serve where the flashlight pair is not: the shim's block ends
/// `isKeepingAwake = enabled`, and nothing in `CraftBridge.kt` ever reads that
/// field — so the Kotlin body not running leaves nothing stale behind.
fn nativeSetKeepAwake(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    enabled: jni.jboolean,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    screen.keepAwake(j, activity, enabled != jni.JNI_FALSE) catch |err| {
        std.log.warn("craft: setKeepAwake fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeDownloadFile(activity, url, filename)`.
///
/// Resolves with the download id as a JSON *string*, because the shim
/// interpolated its `Long` into a quoted JavaScript string and the page has
/// always received text.
fn nativeDownloadFile(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    url: jni.jstring,
    filename: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url_text = j.stringToUtf8(allocator, url) catch return jni.JNI_FALSE;
    const name_text = j.stringToUtf8(allocator, filename) catch return jni.JNI_FALSE;

    const id = files.download(j, allocator, activity, url_text, name_text) catch |err| {
        calendar.rejectOn(allocator, files.download_reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    var buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{id}) catch return jni.JNI_FALSE;
    const payload = files.jsonString(allocator, digits) catch return jni.JNI_FALSE;
    events.settle(allocator, files.download_resolve_global, payload) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeSaveFile(activity, data, filename)`.
fn nativeSaveFile(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    data: jni.jstring,
    filename: jni.jstring,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data_text = j.stringToUtf8(allocator, data) catch return jni.JNI_FALSE;
    const name_text = j.stringToUtf8(allocator, filename) catch return jni.JNI_FALSE;

    // The plan can be `nothing`, and the shim still resolves with the path.
    // Reproduced rather than corrected — see #175.
    const path = files.save(j, allocator, activity, name_text, files.planFor(data_text)) catch |err| {
        calendar.rejectOn(allocator, files.save_reject_global, @errorName(err)) catch {};
        return jni.JNI_TRUE;
    };

    const payload = files.jsonString(allocator, path) catch return jni.JNI_FALSE;
    events.settle(allocator, files.save_resolve_global, payload) catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeGetLocationRecordingState(activity)`.
///
/// Null means "ask the shim". A recording that never started is not null — it
/// is a state object saying so, which is a different answer.
fn nativeGetLocationRecordingState(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jstring {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const contents = locationstore.readFile(j, allocator, activity) catch |err| {
        std.log.warn("craft: getLocationRecordingState fell through to the shim ({s})", .{@errorName(err)});
        return null;
    };

    // A line the shim would drop and this cannot parse: hand the whole read
    // back rather than disagreeing about how many samples there are.
    const locations = (locationstore.renderLocations(allocator, contents) catch return null) orelse
        return null;

    const state = locationstore.readState(j, allocator, activity, locations.count) catch |err| {
        std.log.warn("craft: getLocationRecordingState fell through to the shim ({s})", .{@errorName(err)});
        return null;
    };

    const json = locationstore.renderState(allocator, state) catch return null;
    return j.newStringUtf8(allocator, json) catch null;
}

/// `nativeReadLocationRecording(activity)`.
fn nativeReadLocationRecording(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jstring {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const contents = locationstore.readFile(j, allocator, activity) catch |err| {
        std.log.warn("craft: readLocationRecording fell through to the shim ({s})", .{@errorName(err)});
        return null;
    };

    const locations = (locationstore.renderLocations(allocator, contents) catch return null) orelse
        return null;
    return j.newStringUtf8(allocator, locations.json) catch null;
}

/// The current state as a Java String, or null if any part of the read
/// declines. Shared by every control, since all four answer with one.
fn recordingStateString(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jni.jobject,
    include_locations: bool,
) jni.jstring {
    const contents = locationstore.readFile(j, allocator, activity) catch return null;
    const locations = (locationstore.renderLocations(allocator, contents) catch return null) orelse
        return null;
    const state = locationstore.readState(j, allocator, activity, locations.count) catch return null;

    const json = locationstore.renderStateWith(
        allocator,
        state,
        if (include_locations) locations.json else null,
    ) catch return null;
    return j.newStringUtf8(allocator, json) catch null;
}

/// `nativeStartLocationRecording(activity)`.
fn nativeStartLocationRecording(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jstring {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const granted = permissions.isGranted(j, activity, permissions.access_fine_location) catch
        return null;

    if (!granted) {
        // A different object from "never recorded": this path builds a fresh
        // JSONObject with an explicit JSONObject.NULL id, so the key is
        // present and null rather than absent.
        const json = locationstore.renderDenied(allocator) catch return null;
        return j.newStringUtf8(allocator, json) catch null;
    }

    const id = locationstore.newRecordingId(j, allocator) catch return null;
    const started_at = locationstore.nowMillis(j) catch return null;
    locationstore.startStore(j, allocator, activity, id, started_at) catch return null;

    // Kotlin names the service class, because its package is templated.
    startRecordingService(j, activity) catch return null;

    return recordingStateString(j, allocator, activity, false);
}

/// `nativeStopLocationRecording(activity)`.
///
/// The state is read *before* the service is stopped, as the shim reads it —
/// so the array it returns is the recording as it stood at the call.
fn nativeStopLocationRecording(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jstring {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    locationstore.stopStore(j, allocator, activity) catch return null;

    // Declining after the store write is safe: `stop` is idempotent, so the
    // shim runs the whole method again and reaches `stopService` itself.
    const result = recordingStateString(j, allocator, activity, true);
    if (result == null) return null;

    stopRecordingService(j, activity) catch return null;
    return result;
}

/// `nativePauseLocationRecording(activity)`.
fn nativePauseLocationRecording(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jstring {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    locationstore.setPaused(j, allocator, activity, true) catch return null;
    return recordingStateString(j, allocator, activity, false);
}

/// `nativeResumeLocationRecording(activity)`.
///
/// Restarts the service only when a recording is active, as the shim does — a
/// page resuming something it never started should not raise a foreground
/// notification.
fn nativeResumeLocationRecording(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jstring {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    locationstore.setPaused(j, allocator, activity, false) catch return null;

    const active = locationstore.isActive(j, allocator, activity) catch return null;
    if (active) startRecordingService(j, activity) catch return null;

    return recordingStateString(j, allocator, activity, false);
}

fn startRecordingService(j: Jni, activity: jni.jobject) !void {
    return callHolderVoid(j, "startRecordingService", activity);
}

fn stopRecordingService(j: Jni, activity: jni.jobject) !void {
    return callHolderVoid(j, "stopRecordingService", activity);
}

/// `nativeNetworkChanged(activity)` — a network callback, arrived at.
///
/// Runs on a Binder thread. That is fine and is the reason the reply channel
/// exists in the shape it does: `events.settle` attaches whatever thread it is
/// called on and the Kotlin deliverer hops to the main looper.
///
/// Void and silent. There is no promise waiting on this — the page registered
/// a callback with `onNetworkChange` and every change calls it — so a failure
/// has nowhere to be reported and shows up in `droppedCount` instead.
fn nativeNetworkChanged(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) void {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const status = network.read(j, activity) catch return;
    const json = network.render(allocator, status) catch return;
    events.settle(allocator, network.change_global, json) catch {};
}

/// `nativeStartNetworkMonitoring(activity)`.
///
/// The callback object is the holder's, because
/// `ConnectivityManager.NetworkCallback` is an abstract Java class and JNI
/// cannot subclass one. What Zig owns is what happens when it fires.
fn nativeStartNetworkMonitoring(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    callHolderVoid(j, "startNetworkWatch", activity) catch |err| {
        std.log.warn("craft: startNetworkMonitoring fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeStopNetworkMonitoring(activity)`.
///
/// A false here after a successful start would leave the callback registered:
/// the shim's own `networkCallback` field is null, so its stop finds nothing
/// to unregister. The holder's stop is the only thing that can undo the
/// holder's start, which is why this reports the JNI failure rather than
/// pretending the shim can finish the job.
fn nativeStopNetworkMonitoring(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    callHolderVoid(j, "stopNetworkWatch", activity) catch |err| {
        std.log.warn("craft: stopNetworkMonitoring failed ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// Call a `(Activity) -> void` static on the holder.
fn callHolderVoid(j: Jni, comptime name: [:0]const u8, activity: jni.jobject) !void {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const holder = try j.findClass(holder_class);
    try j.callStaticVoidMethodA(
        holder,
        try j.staticMethodId(holder, name, "(Landroid/app/Activity;)V"),
        &.{.{ .l = activity }},
    );
}

/// `nativeAppStateEvent(eventName)` — a lifecycle event, arrived at.
///
/// Runs on the main looper, where `ProcessLifecycleOwner` dispatches. Silent:
/// there is no promise waiting, and a page that never registered a callback is
/// the ordinary case rather than an error.
fn nativeAppStateEvent(
    env: jni.JNIEnv,
    _: jni.jobject,
    event_name: jni.jstring,
) callconv(.c) void {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const name = j.stringToUtf8(allocator, event_name) catch return;

    // Null covers both "this event carries no state" and "it carries the one
    // already held", and the shim announces neither.
    const changed = appstate.apply(name) orelse return;
    appstate.announce(allocator, changed) catch {};
}

/// `nativeStartAppStateMonitoring(activity)`.
///
/// The observer is the holder's — `LifecycleEventObserver` is a Java interface
/// — and adding it twice is a no-op, because `LifecycleRegistry` keys its
/// observers by identity. The shim has the same property for the same reason,
/// so unlike the network watch there is nothing to leak here.
fn nativeStartAppStateMonitoring(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    callHolderVoid(j, "startAppStateWatch", activity) catch |err| {
        std.log.warn("craft: startAppStateMonitoring fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeStopAppStateMonitoring(activity)`.
fn nativeStopAppStateMonitoring(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    callHolderVoid(j, "stopAppStateWatch", activity) catch |err| {
        std.log.warn("craft: stopAppStateMonitoring failed ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeGetAppState()`.
///
/// Reads the state Zig now owns. This is why the trio moves together: the
/// Kotlin's `currentAppState` is only written by the observer, so serving the
/// observer without serving this would leave the field frozen at "active"
/// while the real state moved on.
fn nativeGetAppState(env: jni.JNIEnv, _: jni.jobject) callconv(.c) jni.jstring {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();

    return j.newStringUtf8(arena.allocator(), appstate.state().name()) catch null;
}

/// `nativeBluetoothDevice(address, name, rssi)` — one scan result.
fn nativeBluetoothDevice(
    env: jni.JNIEnv,
    _: jni.jobject,
    address: jni.jstring,
    name: jni.jstring,
    rssi: jni.jint,
) callconv(.c) void {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const address_text = j.stringToUtf8(allocator, address) catch return;

    // Null is a device advertising no name, which is the common case rather
    // than the edge one — `bluetooth.announce` applies the shim's "Unknown".
    const name_text: ?[]const u8 = if (name == null)
        null
    else
        j.stringToUtf8(allocator, name) catch return;

    bluetooth.announce(allocator, address_text, name_text, rssi) catch {};
}

/// `nativeStartBluetoothScan(activity)`.
///
/// Resolves `true` whether or not a scan actually started, because the shim
/// does: `bluetoothScanner?.startScan(...)` is skipped when there is no
/// adapter or Bluetooth is off, and the resolve fires regardless. See #185.
fn nativeStartBluetoothScan(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const granted = permissions.isGranted(j, activity, permissions.bluetooth_scan) catch |err| {
        std.log.warn("craft: startBluetoothScan fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    if (!granted) {
        // The shim only asks on API 31+, where the permission exists at all;
        // the holder makes that check, because it is the one that knows how to
        // ask without throwing on older releases.
        callHolderVoid(j, "requestBluetoothScanPermission", activity) catch |err| {
            std.log.warn("craft: startBluetoothScan fell through to the shim ({s})", .{@errorName(err)});
            return jni.JNI_FALSE;
        };
        calendar.rejectOn(allocator, bluetooth.reject_global, "Permission denied") catch {};
        return jni.JNI_TRUE;
    }

    callHolderVoid(j, "startBluetoothWatch", activity) catch |err| {
        std.log.warn("craft: startBluetoothScan fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    events.settle(allocator, bluetooth.resolve_global, "true") catch return jni.JNI_FALSE;
    return jni.JNI_TRUE;
}

/// `nativeStopBluetoothScan(activity)`.
///
/// Cannot decline after a successful start, for the reason the network watch
/// cannot: the shim's own `bleScanCallback` is null, so its stop finds nothing
/// to hand to `stopScan`.
fn nativeStopBluetoothScan(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    callHolderVoid(j, "stopBluetoothWatch", activity) catch |err| {
        std.log.warn("craft: stopBluetoothScan failed ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeMotionSample(isAccelerometer, x, y, z)` — one sensor reading.
///
/// Every sample sends a complete event: the sensor that just reported and the
/// last value the other one gave, which is what the shim does and is why a
/// device with both sensors produces two events per cycle.
fn nativeMotionSample(
    env: jni.JNIEnv,
    _: jni.jobject,
    is_accelerometer: jni.jboolean,
    x: jni.jfloat,
    y: jni.jfloat,
    z: jni.jfloat,
) callconv(.c) void {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    motion.record(is_accelerometer != jni.JNI_FALSE, .{ x, y, z });

    const acceleration = motion.lastAcceleration();
    const rotation = motion.lastRotation();

    // Formatted by org.json, because these are the numbers a page reads and
    // `Float.toString` is not a format string — see `android_json_number`.
    var printed: [6][]const u8 = undefined;
    inline for (0..3) |i| {
        printed[i] = json_number.fromFloat(j, allocator, acceleration[i]) catch return;
        printed[i + 3] = json_number.fromFloat(j, allocator, rotation[i]) catch return;
    }

    motion.announce(
        allocator,
        .{ printed[0], printed[1], printed[2] },
        .{ printed[3], printed[4], printed[5] },
    ) catch {};
}

/// `nativeStartMotionUpdates(activity, intervalMs)`.
///
/// The delay constant is read here and handed across, so the shim's `when`
/// stays a Zig decision while the field it names stays the platform's number.
fn nativeStartMotionUpdates(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
    interval_ms: jni.jint,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    const delay = sensorDelay(j, motion.delayFor(interval_ms)) catch |err| {
        std.log.warn("craft: startMotionUpdates fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    // The shim builds a new listener object, whose lastAccel and lastGyro
    // start null — so a restart forgets what the last one saw.
    motion.reset();

    callHolderInt(j, "startMotionWatch", activity, delay) catch |err| {
        std.log.warn("craft: startMotionUpdates fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `nativeStopMotionUpdates(activity)`.
fn nativeStopMotionUpdates(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);

    callHolderVoid(j, "stopMotionWatch", activity) catch |err| {
        std.log.warn("craft: stopMotionUpdates failed ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };
    return jni.JNI_TRUE;
}

/// `SensorManager.<field>`.
fn sensorDelay(j: Jni, delay: motion.Delay) !jni.jint {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    const manager_cls = try j.findClass("android/hardware/SensorManager");
    return j.staticIntField(manager_cls, try j.staticFieldId(manager_cls, delay.field(), "I"));
}

/// Call an `(Activity, int) -> void` static on the holder.
fn callHolderInt(j: Jni, comptime name: [:0]const u8, activity: jni.jobject, value: jni.jint) !void {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const holder = try j.findClass(holder_class);
    try j.callStaticVoidMethodA(
        holder,
        try j.staticMethodId(holder, name, "(Landroid/app/Activity;I)V"),
        &.{ .{ .l = activity }, .{ .i = value } },
    );
}

/// `nativeLocationResult(...)` — a fix, from either the cached or fresh path.
///
/// Every value arrives as a `double`, including the three the framework types
/// as `float`: the shim writes them with `put(name, value)`, and the overload
/// Kotlin picks is `put(String, double)` because widening beats boxing. So
/// they print as doubles, and the holder widens them for the same reason.
fn nativeLocationResult(
    env: jni.JNIEnv,
    _: jni.jobject,
    latitude: jni.jdouble,
    longitude: jni.jdouble,
    accuracy: jni.jdouble,
    altitude: jni.jdouble,
    speed: jni.jdouble,
    bearing: jni.jdouble,
    time: jni.jlong,
) callconv(.c) void {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    var timestamp: [24]u8 = undefined;
    const printed: position.Printed = .{
        .latitude = json_number.fromDouble(j, allocator, latitude) catch return,
        .longitude = json_number.fromDouble(j, allocator, longitude) catch return,
        .accuracy = json_number.fromDouble(j, allocator, accuracy) catch return,
        .altitude = json_number.fromDouble(j, allocator, altitude) catch return,
        .speed = json_number.fromDouble(j, allocator, speed) catch return,
        .heading = json_number.fromDouble(j, allocator, bearing) catch return,
        // A long, not a double: `put(String, long)` boxes a Long, and
        // `numberToString` prints one with `Long.toString` — which needs no
        // JNI call, because there is no float format to reproduce.
        .timestamp = std.fmt.bufPrint(&timestamp, "{d}", .{time}) catch return,
    };

    const json = position.renderPosition(allocator, printed) catch return;
    events.settle(allocator, position.resolve_global, json) catch {};
}

/// `nativeLocationFailed(message)` — the failure listener.
fn nativeLocationFailed(
    env: jni.JNIEnv,
    _: jni.jobject,
    message: jni.jstring,
) callconv(.c) void {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `${jsQuote(e.message)}` — a null message reaches the page as the four
    // characters "null", which is what `Any?.toString()` produced there.
    const text: []const u8 = if (message == null)
        "null"
    else
        j.stringToUtf8(allocator, message) catch return;

    const json = position.renderRejection(allocator, position.code_client_failure, text) catch return;
    events.settle(allocator, position.reject_global, json) catch {};
}

/// `nativeGetCurrentPosition(activity)`.
fn nativeGetCurrentPosition(
    env: jni.JNIEnv,
    _: jni.jobject,
    activity: jni.jobject,
) callconv(.c) jni.jboolean {
    const j = Jni.init(env);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const granted = permissions.isGranted(j, activity, permissions.access_fine_location) catch |err| {
        std.log.warn("craft: getCurrentPosition fell through to the shim ({s})", .{@errorName(err)});
        return jni.JNI_FALSE;
    };

    if (!granted) {
        // The shim asks for both the fine and the coarse permission, so the
        // holder does too — a request for one where the shim asked for two
        // would leave a page permanently unable to get a coarse fix.
        callHolderVoid(j, "requestLocationPermissions", activity) catch |err| {
            std.log.warn("craft: getCurrentPosition fell through to the shim ({s})", .{@errorName(err)});
            return jni.JNI_FALSE;
        };

        const json = position.renderRejection(
            allocator,
            position.code_permission_denied,
            position.permission_denied_message,
        ) catch return jni.JNI_FALSE;
        events.settle(allocator, position.reject_global, json) catch return jni.JNI_FALSE;
        return jni.JNI_TRUE;
    }

    callHolderVoid(j, "requestCurrentPosition", activity) catch |err| {
        std.log.warn("craft: getCurrentPosition fell through to the shim ({s})", .{@errorName(err)});
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
    try testing.expectEqual(@as(usize, 75), natives.len);
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
