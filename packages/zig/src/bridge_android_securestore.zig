//! The Android secure-storage quartet: `secureSet`, `secureGet`,
//! `secureRemove`, `secureClear`.
//!
//! ## Kotlin passes the store; Zig does not build one
//!
//! Every other action here reaches its platform object through the `Activity`.
//! These four do not, and the difference is deliberate. `securePrefs` is
//!
//!     EncryptedSharedPreferences.create(activity, "craft_secure_prefs",
//!         masterKey, AES256_SIV, AES256_GCM)
//!
//! over a lazily-built `MasterKey`. Zig could construct that — it is two
//! builder calls and two enum constants — and constructing it would be a
//! mistake. It is a second implementation of a security-sensitive
//! construction, in a second language, that has to agree with the first
//! exactly: a different key scheme, a different file name, a different SIV
//! mode, and the two halves write data neither can read. Nothing would fail
//! at build time and the symptom would be a user's saved token disappearing
//! after an app update.
//!
//! So the native methods take the `SharedPreferences` as a parameter. The
//! object is Kotlin's, the lifetime is Kotlin's, and Zig only ever calls the
//! plain `SharedPreferences` interface on it — which is the whole of what the
//! Kotlin does too, since `EncryptedSharedPreferences` *is* a
//! `SharedPreferences` and the encryption is behind the interface.
//!
//! This generalises: where the shim already holds a configured platform
//! object, handing it across the seam beats rebuilding it.
//!
//! ## `secureGet` has three answers where the others have two
//!
//! The Kotlin returns `String?`, and null there means "no such key". The seam
//! also needs to say "Zig did not serve this" — and a nullable String cannot
//! carry both, because an absent key and a declined call are different things
//! and the caller must do different things about them.
//!
//! There is no spare value to steal: `""` is a legitimate stored value, and so
//! is any sentinel a caller could also have saved. So the reply is an envelope,
//! `{"found":…}`, and null is reserved for "declined". Three states, three
//! representations, none of them overloaded.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const secure_set = "secureSet";
    pub const secure_get = "secureGet";
    pub const secure_remove = "secureRemove";
    pub const secure_clear = "secureClear";
};

/// `prefs.edit()` — the editor every write goes through.
///
/// `SharedPreferences.Editor` is an inner interface, so its binary name
/// carries the `$`: `android/content/SharedPreferences$Editor`.
fn editor(j: Jni, prefs: jobject) !jobject {
    const prefs_cls = try j.objectClass(prefs);
    return j.callObjectMethod(
        prefs,
        try j.methodId(prefs_cls, "edit", "()Landroid/content/SharedPreferences$Editor;"),
    );
}

/// `edit.apply()`.
///
/// `apply` rather than `commit`, matching the Kotlin. It writes to memory
/// synchronously and to disk on a background thread, and returns void — so a
/// disk failure is invisible to both implementations, and "true" here means
/// the edit was accepted rather than persisted. Switching to `commit` would
/// make Zig report a truth the shim does not, which is a divergence even when
/// it is an improvement.
fn apply(j: Jni, edit: jobject) !void {
    const edit_cls = try j.objectClass(edit);
    try j.callVoidMethodA(edit, try j.methodId(edit_cls, "apply", "()V"), &.{});
}

pub fn set(j: Jni, prefs: jobject, key: [*:0]const u8, value: [*:0]const u8) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const edit = try editor(j, prefs);
    const edit_cls = try j.objectClass(edit);

    _ = try j.callObjectMethodA(
        edit,
        try j.methodId(
            edit_cls,
            "putString",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;",
        ),
        &.{ .{ .l = try j.newStringUtf(key) }, .{ .l = try j.newStringUtf(value) } },
    );
    try apply(j, edit);
}

pub fn remove(j: Jni, prefs: jobject, key: [*:0]const u8) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const edit = try editor(j, prefs);
    const edit_cls = try j.objectClass(edit);

    _ = try j.callObjectMethodA(
        edit,
        try j.methodId(edit_cls, "remove", "(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;"),
        &.{.{ .l = try j.newStringUtf(key) }},
    );
    try apply(j, edit);
}

pub fn clear(j: Jni, prefs: jobject) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const edit = try editor(j, prefs);
    const edit_cls = try j.objectClass(edit);

    _ = try j.callObjectMethodA(
        edit,
        try j.methodId(edit_cls, "clear", "()Landroid/content/SharedPreferences$Editor;"),
        &.{},
    );
    try apply(j, edit);
}

/// The reply envelope for `secureGet`. See the module comment for why a bare
/// nullable string cannot carry these three states.
pub fn renderRead(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (value) |text| {
        try out.appendSlice(allocator, "{\"found\":true,\"value\":\"");
        // The quotes are this caller's job — `appendJsonEscaped` escapes the
        // contents and writes no delimiters. A stored value containing a quote
        // would otherwise tear the envelope and read back as absent.
        try bridge_error.appendJsonEscaped(allocator, &out, text);
        try out.appendSlice(allocator, "\"}");
    } else {
        try out.appendSlice(allocator, "{\"found\":false}");
    }
    return out.toOwnedSlice(allocator);
}

/// `prefs.getString(key, null)`, as an owned optional. Caller frees.
pub fn get(allocator: std.mem.Allocator, j: Jni, prefs: jobject, key: [*:0]const u8) !?[]u8 {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const prefs_cls = try j.objectClass(prefs);
    const value = try j.callObjectMethodA(
        prefs,
        try j.methodId(
            prefs_cls,
            "getString",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
        ),
        // The default is null, which is what makes "absent" distinguishable
        // from a stored empty string.
        &.{ .{ .l = try j.newStringUtf(key) }, .{ .l = null } },
    );
    if (value == null) return null;
    return try j.stringToUtf8(allocator, value);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the read envelope distinguishes absent from empty" {
    // The whole reason the envelope exists. A stored `""` and a missing key
    // are different, and a bare nullable string collapses them the moment the
    // seam also needs to say "declined".
    const absent = try renderRead(testing.allocator, null);
    defer testing.allocator.free(absent);
    const empty = try renderRead(testing.allocator, "");
    defer testing.allocator.free(empty);

    var a = try std.json.parseFromSlice(std.json.Value, testing.allocator, absent, .{});
    defer a.deinit();
    var e = try std.json.parseFromSlice(std.json.Value, testing.allocator, empty, .{});
    defer e.deinit();

    try testing.expectEqual(false, a.value.object.get("found").?.bool);
    try testing.expect(a.value.object.get("value") == null);

    try testing.expectEqual(true, e.value.object.get("found").?.bool);
    try testing.expectEqualStrings("", e.value.object.get("value").?.string);
}

test "a stored value containing a quote does not tear the envelope" {
    // Secure storage holds tokens, and a JWT is base64 — but nothing stops a
    // page storing arbitrary text, and `appendJsonEscaped` writes no
    // delimiters of its own. The same trap that broke the iOS
    // location-recording state file.
    const json = try renderRead(testing.allocator, "a\"b\\c\nd");
    defer testing.allocator.free(json);

    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    try testing.expectEqual(true, p.value.object.get("found").?.bool);
    try testing.expectEqualStrings("a\"b\\c\nd", p.value.object.get("value").?.string);
}

test "the action names match the Kotlin methods exactly" {
    try testing.expectEqualStrings("secureSet", A.secure_set);
    try testing.expectEqualStrings("secureGet", A.secure_get);
    try testing.expectEqualStrings("secureRemove", A.secure_remove);
    try testing.expectEqualStrings("secureClear", A.secure_clear);
}

// --- A fake SharedPreferences ---------------------------------------------
//
// `renderRead` above tests the envelope, and the envelope is only half the
// decision: whether a key is absent is settled in `get`, against
// `getString(key, null)`. A mutation returning `""` for an absent key passed
// every test in this file until these were written — the same shape of gap the
// envelope exists to close, one layer down.

var fake_storage: [8]u8 = undefined;
var fake_value_present = true;

fn sobj(tag: usize) jobject {
    return @ptrCast(&fake_storage[tag]);
}
fn sObjectClass(_: jni.JNIEnv, _: jobject) callconv(.c) jni.jclass {
    return sobj(0);
}
fn sMethodId(_: jni.JNIEnv, _: jni.jclass, name: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jmethodID {
    return @ptrCast(@constCast(name));
}
fn sNewStringUTF(_: jni.JNIEnv, _: [*:0]const u8) callconv(.c) jni.jstring {
    return sobj(1);
}
fn sCallObjectMethodA(_: jni.JNIEnv, _: jobject, _: jni.jmethodID, args: [*]const jni.jvalue) callconv(.c) jobject {
    // `getString(key, null)` — the second argument is the default, and the
    // fake honours it rather than inventing one, because "the default comes
    // back" is precisely the absent case.
    if (!fake_value_present) return args[1].l;
    return sobj(2);
}
fn sGetStringUTFChars(_: jni.JNIEnv, _: jni.jstring, _: ?*jni.jboolean) callconv(.c) ?[*:0]const u8 {
    return "stored";
}
fn sReleaseStringUTFChars(_: jni.JNIEnv, _: jni.jstring, _: [*:0]const u8) callconv(.c) void {}
fn sExceptionOccurred(_: jni.JNIEnv) callconv(.c) jobject {
    return null;
}
fn sPush(_: jni.JNIEnv, _: jni.jint) callconv(.c) jni.jint {
    return 0;
}
fn sPop(_: jni.JNIEnv, keep: jobject) callconv(.c) jobject {
    return keep;
}

fn getWith(present: bool) !?[]u8 {
    fake_value_present = present;
    var table = std.mem.zeroes(jni.JNINativeInterface);
    table.GetObjectClass = @ptrCast(&sObjectClass);
    table.GetMethodID = @ptrCast(&sMethodId);
    table.NewStringUTF = @ptrCast(&sNewStringUTF);
    table.CallObjectMethodA = @ptrCast(&sCallObjectMethodA);
    table.GetStringUTFChars = @ptrCast(&sGetStringUTFChars);
    table.ReleaseStringUTFChars = @ptrCast(&sReleaseStringUTFChars);
    table.ExceptionOccurred = @ptrCast(&sExceptionOccurred);
    table.PushLocalFrame = @ptrCast(&sPush);
    table.PopLocalFrame = @ptrCast(&sPop);

    const ptr: *const jni.JNINativeInterface = &table;
    return get(testing.allocator, Jni.init(&ptr), sobj(3), "token");
}

test "an absent key reads as null, never as an empty string" {
    // The mutation this was written for: returning `""` here instead of null
    // makes every missing key look like a stored empty string, and the
    // envelope then reports `found: true` for something that was never saved.
    const absent = try getWith(false);
    try testing.expect(absent == null);

    const present = try getWith(true);
    defer if (present) |p| testing.allocator.free(p);
    try testing.expect(present != null);
    try testing.expectEqualStrings("stored", present.?);
}

test "the absent case survives the round trip through the envelope" {
    // End to end, because the two halves are only correct together: a `get`
    // that loses the distinction and a `renderRead` that keeps it still
    // produce `{"found":true}` for a key nobody stored.
    const absent = try getWith(false);
    const json = try renderRead(testing.allocator, absent);
    defer testing.allocator.free(json);

    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    try testing.expectEqual(false, p.value.object.get("found").?.bool);
}
