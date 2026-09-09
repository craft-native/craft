//! The screen: `lockOrientation`, `unlockOrientation` and `setKeepAwake`.
//!
//! Everything here goes through `android_main_thread`, because everything here
//! touches the Activity's window and the shim wraps each one in
//! `runOnUiThread { ... }`.
//!
//! ## They answer by returning, not through the reply channel
//!
//! Both are `Boolean` methods that `return true` after *queueing* the work.
//! So the page's promise resolves before the orientation has changed, on the
//! shim as much as here — `runOnUiThread` returns immediately when the caller
//! is not the main thread, which the JavaBridge thread never is. Nothing here
//! makes that worse and nothing here fixes it.
//!
//! ## The constants are read, not written down
//!
//! `ActivityInfo.SCREEN_ORIENTATION_*` are compile-time constants, so the
//! shim's DEX holds the numbers and literals here would be faithful. They are
//! read anyway, for the reason `addContact` reads its MIME types: a wrong
//! column name throws, and a wrong orientation number silently locks the
//! device the wrong way round.
//!
//! ## Two names mean the same thing, and an unknown name unlocks
//!
//! `landscape` and `landscapeLeft` both map to `SCREEN_ORIENTATION_LANDSCAPE`
//! — so a page asking for the left-hand landscape and a page asking for either
//! landscape get the same lock. `landscapeRight` is the only one that reaches
//! `REVERSE_LANDSCAPE`.
//!
//! And the `else` branch is `SCREEN_ORIENTATION_UNSPECIFIED`, which is what
//! `unlockOrientation` sets. So `craft.lockOrientation("portrat")` does not
//! fail — it silently *unlocks*, and still returns true.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const main_thread = @import("android_main_thread.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const lock_orientation = "lockOrientation";
    pub const unlock_orientation = "unlockOrientation";
    pub const set_keep_awake = "setKeepAwake";
};

/// Which `ActivityInfo` constant a page's string names.
pub const Mode = enum {
    unspecified,
    landscape,
    portrait,
    reverse_landscape,

    /// The field on `android.content.pm.ActivityInfo`.
    pub fn field(self: Mode) [:0]const u8 {
        return switch (self) {
            .unspecified => "SCREEN_ORIENTATION_UNSPECIFIED",
            .landscape => "SCREEN_ORIENTATION_LANDSCAPE",
            .portrait => "SCREEN_ORIENTATION_PORTRAIT",
            .reverse_landscape => "SCREEN_ORIENTATION_REVERSE_LANDSCAPE",
        };
    }
};

/// The shim's `when (orientation)`, including its `else`.
pub fn modeFor(orientation: []const u8) Mode {
    if (std.mem.eql(u8, orientation, "portrait")) return .portrait;
    if (std.mem.eql(u8, orientation, "landscape")) return .landscape;
    if (std.mem.eql(u8, orientation, "landscapeLeft")) return .landscape;
    if (std.mem.eql(u8, orientation, "landscapeRight")) return .reverse_landscape;
    return .unspecified;
}

/// `ActivityInfo.<field>`.
pub fn constantFor(j: Jni, mode: Mode) !i32 {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    const info_cls = try j.findClass("android/content/pm/ActivityInfo");
    return j.staticIntField(info_cls, try j.staticFieldId(info_cls, mode.field(), "I"));
}

/// Queue `activity.setRequestedOrientation(...)` for the main thread.
pub fn apply(j: Jni, activity: jobject, mode: Mode) !void {
    const constant = try constantFor(j, mode);
    try main_thread.post(j, activity, .{ .set_requested_orientation = constant }, 0);
}

// =============================================================================
// setKeepAwake
// =============================================================================
//
// ## The field it writes is read by nothing
//
// The shim's block ends `isKeepingAwake = enabled`, and that field is written
// there and read nowhere else in `CraftBridge.kt`. So unlike the flashlight
// pair — where `toggleFlashlight` reads what `setFlashlight` wrote, and Zig
// serving one would leave the other inverting a stale value — there is no
// state to keep in step here. Worth saying, because the two look identical
// from the outside and only one of them is safe to take.

/// `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON`.
///
/// Read through JNI rather than written down. A wrong column name throws and a
/// wrong flag does not: the window would quietly get `FLAG_DIM_BEHIND` or
/// `FLAG_BLUR_BEHIND` instead, and the screen would keep timing out while
/// everything reported success.
pub fn keepScreenOnFlag(j: Jni) !i32 {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    const params_cls = try j.findClass("android/view/WindowManager$LayoutParams");
    return j.staticIntField(
        params_cls,
        try j.staticFieldId(params_cls, "FLAG_KEEP_SCREEN_ON", "I"),
    );
}

/// Queue `window.addFlags(...)` or `window.clearFlags(...)` for the main thread.
pub fn keepAwake(j: Jni, activity: jobject, enabled: bool) !void {
    const flag = try keepScreenOnFlag(j);
    try main_thread.post(j, activity, .{ .set_window_flags = .{
        .flags = flag,
        .add = enabled,
    } }, 0);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "every name the shim knows maps where the shim maps it" {
    try testing.expectEqual(Mode.portrait, modeFor("portrait"));
    try testing.expectEqual(Mode.landscape, modeFor("landscape"));

    // Both of these are SCREEN_ORIENTATION_LANDSCAPE in the shim. Written as
    // two rows rather than one, because they read like they should differ.
    try testing.expectEqual(Mode.landscape, modeFor("landscapeLeft"));
    try testing.expectEqual(Mode.reverse_landscape, modeFor("landscapeRight"));
}

test "an unknown name unlocks rather than failing" {
    // The shim's `else`. `craft.lockOrientation("portrat")` returns true and
    // leaves the device unlocked, which is worth knowing before debugging it.
    try testing.expectEqual(Mode.unspecified, modeFor("portrat"));
    try testing.expectEqual(Mode.unspecified, modeFor(""));
    try testing.expectEqual(Mode.unspecified, modeFor("PORTRAIT"));
    try testing.expectEqual(Mode.unspecified, modeFor("portrait "));
    try testing.expectEqual(Mode.unspecified, modeFor("upsideDown"));
}

test "unlocking is the same constant an unknown name reaches" {
    // `unlockOrientation` sets SCREEN_ORIENTATION_UNSPECIFIED, which is why
    // the typo above is not a harmless no-op: it actively unlocks.
    try testing.expectEqualStrings(
        "SCREEN_ORIENTATION_UNSPECIFIED",
        Mode.unspecified.field(),
    );
}

test "each mode names a real ActivityInfo field" {
    // The names are what `GetStaticFieldID` looks up, so a typo is a
    // NoSuchFieldError at the call rather than a compile error here.
    try testing.expectEqualStrings("SCREEN_ORIENTATION_LANDSCAPE", Mode.landscape.field());
    try testing.expectEqualStrings("SCREEN_ORIENTATION_PORTRAIT", Mode.portrait.field());
    try testing.expectEqualStrings(
        "SCREEN_ORIENTATION_REVERSE_LANDSCAPE",
        Mode.reverse_landscape.field(),
    );

    // All four are distinct, which a copy-paste in the switch above would
    // quietly break.
    const fields = [_][]const u8{
        Mode.unspecified.field(),
        Mode.landscape.field(),
        Mode.portrait.field(),
        Mode.reverse_landscape.field(),
    };
    for (fields, 0..) |a, i| {
        for (fields[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
}

test "the actions match the shim exactly" {
    try testing.expectEqualStrings("lockOrientation", A.lock_orientation);
    try testing.expectEqualStrings("unlockOrientation", A.unlock_orientation);
    try testing.expectEqualStrings("setKeepAwake", A.set_keep_awake);
}
