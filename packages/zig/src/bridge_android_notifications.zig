//! Local notifications on Android: `scheduleNotification`,
//! `cancelNotification` and `cancelAllNotifications`.
//!
//! ## Only the immediate half of scheduling is served
//!
//! A `delay` above zero posts the notification through
//! `Handler(Looper.getMainLooper()).postDelayed { ... }`, and Zig cannot make
//! a `Runnable` — the same wall the reply channel exists to get around, except
//! that this one needs a Java object rather than a Java call. So a delayed
//! notification is handed back to the shim before anything has happened, and
//! only `delay <= 0` is served here.
//!
//! Declining early matters: the shim creates the channel and builds the
//! notification on both paths, so returning after any of that would do the
//! work twice.
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
    pub const schedule_notification = "scheduleNotification";
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
// scheduleNotification
// =============================================================================

/// The globals the injected JS assigns for scheduling.
pub const schedule_resolve_global = "_craftNotifResolve";
pub const schedule_reject_global = "_craftNotifReject";

/// `CraftBridge.notificationChannelId`.
const channel_id = "craft_notifications";
const channel_name = "Craft Notifications";
const channel_description = "Notifications from Craft app";

/// `NotificationManager.IMPORTANCE_DEFAULT` and `Build.VERSION_CODES.O`.
///
/// Compile-time constants in Java, so the shim's DEX holds the literals.
const importance_default: i32 = 3;
const version_o: i32 = 26;

/// What the page sent, in the shape `NotificationData` declares.
pub const Notification = struct {
    title: []const u8,
    body: []const u8,
    /// `optString("id", System.currentTimeMillis().toString())`.
    id: []const u8,
    /// `optLong("delay", 0)`. Above zero is the path Zig hands back.
    delay: i64,
};

/// Read the declared shape, or null where only `org.json` would.
///
/// `default_id` is the shim's `System.currentTimeMillis().toString()`,
/// computed by the caller because it is a JNI call rather than a host clock.
pub fn parseNotification(value: std.json.Value, default_id: []const u8) ?Notification {
    const object = switch (value) {
        .object => |o| o,
        else => return null,
    };

    return .{
        .title = optString(object, "title", "") orelse return null,
        .body = optString(object, "body", "") orelse return null,
        .id = optString(object, "id", default_id) orelse return null,
        .delay = optLong(object, "delay", 0) orelse return null,
    };
}

fn optString(object: std.json.ObjectMap, name: []const u8, fallback: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return fallback;
    return switch (value) {
        .string => |text| text,
        // `JSONObject.NULL.toString()`, the same four characters every other
        // migrated action reproduces.
        .null => "null",
        else => null,
    };
}

fn optLong(object: std.json.ObjectMap, name: []const u8, fallback: i64) ?i64 {
    const value = object.get(name) orelse return fallback;
    return switch (value) {
        .integer => |n| n,
        .null => fallback,
        else => null,
    };
}

/// Whether this notification is one Zig serves.
///
/// The shim's branch is `if (delay > 0)`, so zero and every negative go to
/// `notify` immediately — a page sending `delay: -1` gets a notification now,
/// not an error.
pub fn servesImmediately(notification: Notification) bool {
    return notification.delay <= 0;
}

/// `Build.VERSION.SDK_INT`.
pub fn sdkInt(j: Jni) !i32 {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    const version_cls = try j.findClass("android/os/Build$VERSION");
    return j.staticIntField(version_cls, try j.staticFieldId(version_cls, "SDK_INT", "I"));
}

/// `createNotificationChannel()`, which is a no-op below API 26.
///
/// Called before every `notify`, as the shim calls it — creating a channel
/// that already exists updates nothing the app did not set, so it is cheap
/// rather than merely harmless.
pub fn ensureChannel(j: Jni, activity: jobject) !void {
    if (try sdkInt(j) < version_o) return;

    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const channel_cls = try j.findClass("android/app/NotificationChannel");
    const channel = try j.newObjectA(
        channel_cls,
        try j.methodId(channel_cls, "<init>", "(Ljava/lang/String;Ljava/lang/CharSequence;I)V"),
        &.{
            .{ .l = try j.newStringUtf(channel_id) },
            .{ .l = try j.newStringUtf(channel_name) },
            .{ .i = importance_default },
        },
    );

    try j.callVoidMethodA(
        channel,
        try j.methodId(channel_cls, "setDescription", "(Ljava/lang/String;)V"),
        &.{.{ .l = try j.newStringUtf(channel_description) }},
    );

    const manager = try notificationManager(j, activity);
    try j.callVoidMethodA(
        manager,
        try j.methodId(
            try j.objectClass(manager),
            "createNotificationChannel",
            "(Landroid/app/NotificationChannel;)V",
        ),
        &.{.{ .l = channel }},
    );
}

/// Build the notification and post it, returning the id's Java hash.
///
/// `NotificationCompat.Builder` rather than the framework's `Notification.
/// Builder`, because that is what the shim uses and the two do not produce
/// identical objects — compat writes its own extras, and a notification built
/// one way and cancelled the other is a difference nobody would look for.
/// `FindClass` reaches androidx because a native method's class loader is the
/// one that declared it, and `CraftNative` is an app class.
pub fn post(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    notification: Notification,
) !jni.jint {
    try j.pushLocalFrame(32);
    defer _ = j.popLocalFrame(null);

    const builder_cls = try j.findClass("androidx/core/app/NotificationCompat$Builder");
    const builder = try j.newObjectA(
        builder_cls,
        try j.methodId(builder_cls, "<init>", "(Landroid/content/Context;Ljava/lang/String;)V"),
        &.{ .{ .l = activity }, .{ .l = try j.newStringUtf(channel_id) } },
    );

    // `android.R.drawable.ic_dialog_info`. A resource id is a number the
    // platform assigns, so it is read rather than written down.
    const r_drawable_cls = try j.findClass("android/R$drawable");
    const icon = try j.staticIntField(
        r_drawable_cls,
        try j.staticFieldId(r_drawable_cls, "ic_dialog_info", "I"),
    );
    _ = try j.callObjectMethodA(
        builder,
        try j.methodId(builder_cls, "setSmallIcon", "(I)Landroidx/core/app/NotificationCompat$Builder;"),
        &.{.{ .i = icon }},
    );

    _ = try j.callObjectMethodA(
        builder,
        try j.methodId(
            builder_cls,
            "setContentTitle",
            "(Ljava/lang/CharSequence;)Landroidx/core/app/NotificationCompat$Builder;",
        ),
        &.{.{ .l = try j.newStringUtf8(allocator, notification.title) }},
    );

    _ = try j.callObjectMethodA(
        builder,
        try j.methodId(
            builder_cls,
            "setContentText",
            "(Ljava/lang/CharSequence;)Landroidx/core/app/NotificationCompat$Builder;",
        ),
        &.{.{ .l = try j.newStringUtf8(allocator, notification.body) }},
    );

    // Read rather than written down: this is androidx's own constant, and it
    // is the one number here that a version bump could move.
    const priority_default = try j.staticIntField(
        builder_cls,
        try j.staticFieldId(builder_cls, "PRIORITY_DEFAULT", "I"),
    );
    _ = try j.callObjectMethodA(
        builder,
        try j.methodId(builder_cls, "setPriority", "(I)Landroidx/core/app/NotificationCompat$Builder;"),
        &.{.{ .i = priority_default }},
    );

    _ = try j.callObjectMethodA(
        builder,
        try j.methodId(builder_cls, "setAutoCancel", "(Z)Landroidx/core/app/NotificationCompat$Builder;"),
        &.{.{ .z = jni.JNI_TRUE }},
    );

    const built = try j.callObjectMethod(
        builder,
        try j.methodId(builder_cls, "build", "()Landroid/app/Notification;"),
    );

    // `id.hashCode()` — from the Java object, for the reason at the top of
    // this file: Java hashes UTF-16 code units, and reproducing that means
    // reimplementing the encoding to reimplement the hash.
    const id_string = try j.newStringUtf8(allocator, notification.id);
    const hash = try j.callIntMethod(
        id_string,
        try j.methodId(try j.objectClass(id_string), "hashCode", "()I"),
    );

    const manager = try notificationManager(j, activity);
    try j.callVoidMethodA(
        manager,
        try j.methodId(
            try j.objectClass(manager),
            "notify",
            "(ILandroid/app/Notification;)V",
        ),
        &.{ .{ .i = hash }, .{ .l = built } },
    );
    return hash;
}

/// `System.currentTimeMillis().toString()` — the shim's default id.
pub fn defaultId(j: Jni, allocator: std.mem.Allocator) ![]u8 {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    const system_cls = try j.findClass("java/lang/System");
    const now = try j.callStaticLongMethodA(
        system_cls,
        try j.staticMethodId(system_cls, "currentTimeMillis", "()J"),
        &.{},
    );
    return std.fmt.allocPrint(allocator, "{d}", .{now});
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

// --- scheduleNotification --------------------------------------------------

fn parsedNotification(json: []const u8, default_id: []const u8) !?Notification {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var doc = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    defer doc.deinit();

    const parsed = parseNotification(doc.value, default_id) orelse return null;
    return Notification{
        .title = try testing.allocator.dupe(u8, parsed.title),
        .body = try testing.allocator.dupe(u8, parsed.body),
        .id = try testing.allocator.dupe(u8, parsed.id),
        .delay = parsed.delay,
    };
}

fn freeNotification(n: Notification) void {
    testing.allocator.free(n.title);
    testing.allocator.free(n.body);
    testing.allocator.free(n.id);
}

test "the declared shape reads straight through" {
    const n = (try parsedNotification(
        \\{"title":"Order shipped","body":"Arriving Tuesday","id":"order-7","delay":0}
    , "1700000000000")).?;
    defer freeNotification(n);

    try testing.expectEqualStrings("Order shipped", n.title);
    try testing.expectEqualStrings("Arriving Tuesday", n.body);
    try testing.expectEqualStrings("order-7", n.id);
    try testing.expectEqual(@as(i64, 0), n.delay);
}

test "an absent id becomes the clock, and absent text becomes empty" {
    // `optString("id", System.currentTimeMillis().toString())`. The default is
    // computed by the caller because it is a JNI call rather than a host
    // clock, and it is passed in so this stays a pure function.
    const n = (try parsedNotification("{}", "1700000000000")).?;
    defer freeNotification(n);

    try testing.expectEqualStrings("", n.title);
    try testing.expectEqualStrings("", n.body);
    try testing.expectEqualStrings("1700000000000", n.id);
    try testing.expectEqual(@as(i64, 0), n.delay);
}

test "a delay above zero is the shim's, and everything else is served here" {
    // `if (delay > 0)` — so a negative delay is not an error and not a
    // rejection: the shim posts it immediately, and so does this.
    for ([_]struct { delay: i64, served: bool }{
        .{ .delay = 0, .served = true },
        .{ .delay = -1, .served = true },
        .{ .delay = std.math.minInt(i64), .served = true },
        .{ .delay = 1, .served = false },
        .{ .delay = 60_000, .served = false },
    }) |case| {
        try testing.expectEqual(case.served, servesImmediately(.{
            .title = "",
            .body = "",
            .id = "x",
            .delay = case.delay,
        }));
    }
}

test "an explicit null is text for a string and a fallback for the delay" {
    // The org.json split every migrated action reproduces: optString reaches
    // for JSONObject.NULL.toString(), optLong does not.
    const n = (try parsedNotification(
        \\{"title":null,"body":null,"id":null,"delay":null}
    , "1700000000000")).?;
    defer freeNotification(n);

    try testing.expectEqualStrings("null", n.title);
    try testing.expectEqualStrings("null", n.body);
    // Including the id, which then becomes the notification's identity — a
    // page sending {id: null} twice replaces its own notification.
    try testing.expectEqualStrings("null", n.id);
    try testing.expectEqual(@as(i64, 0), n.delay);
}

test "a shape only org.json would coerce is handed back" {
    for ([_][]const u8{
        \\{"title":1.5}
        ,
        \\{"id":7}
        ,
        \\{"delay":"1000"}
        ,
        \\{"delay":1.5}
        ,
        \\{"body":true}
        ,
        \\[]
        ,
        \\"Order shipped"
        ,
    }) |payload| {
        if (try parsedNotification(payload, "1700000000000")) |n| {
            freeNotification(n);
            std.debug.print("payload was served rather than handed back: {s}\n", .{payload});
            return error.CoercedShapeAccepted;
        }
    }
}

test "the channel is the shim's, and its constants are the folded literals" {
    // The id has to match `CraftBridge.notificationChannelId`, or a
    // notification posts to a channel the user has never seen and cannot have
    // configured — and on API 26+ one that does not exist is dropped silently.
    try testing.expectEqualStrings("craft_notifications", channel_id);
    try testing.expectEqualStrings("Craft Notifications", channel_name);
    try testing.expectEqualStrings("Notifications from Craft app", channel_description);

    // NotificationManager.IMPORTANCE_DEFAULT and Build.VERSION_CODES.O.
    try testing.expectEqual(@as(i32, 3), importance_default);
    try testing.expectEqual(@as(i32, 26), version_o);
}

test "scheduleNotification names its action and globals as the shim does" {
    try testing.expectEqualStrings("scheduleNotification", A.schedule_notification);
    try testing.expectEqualStrings("_craftNotifResolve", schedule_resolve_global);
    try testing.expectEqualStrings("_craftNotifReject", schedule_reject_global);
}
