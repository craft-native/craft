//! `getDeviceInfo` on Android — the first action this bridge serves from Zig.
//!
//! The Kotlin it replaces is `CraftBridge.getDeviceInfo()`, a
//! `@JavascriptInterface` method that builds a `JSONObject` of thirteen keys
//! and returns it as a string. Thirteen is the number that matters: an action
//! that answers twelve of them reports success and hands the page `undefined`
//! for the thirteenth, which is the exact regression `getDeviceInfo answers
//! every field the spec answers` was written for on the iOS side. So this
//! answers all thirteen or it is not this action.
//!
//! ## The shape, and why it is split in two
//!
//! `read` does the JNI work and returns a plain `DeviceInfo`. `render` turns a
//! `DeviceInfo` into the reply bytes. Nothing about `render` touches Java.
//!
//! That split is what makes the reply testable. Escaping, key completeness,
//! number formatting and the float's precision are all decided in `render`,
//! and a host test drives it directly with no JVM, no emulator and no fake.
//! The half that genuinely needs a device is then only the field *wiring* —
//! which class, which name, which signature.
//!
//! ## Where this diverges from the Kotlin, deliberately
//!
//! **`appVersion` and `appBuild` have Kotlin `try`/`catch` fallbacks** —
//! `"unknown"` and `0` — for a `getPackageInfo` that throws
//! `NameNotFoundException`. Those are reproduced exactly: a Java exception on
//! that path is caught, cleared, and turned into the same fallback, not
//! propagated. An app whose own package is unfindable is a broken install, and
//! the spec's answer to it is a string that says so rather than a failed call.
//!
//! **Everything else propagates.** A missing `android/os/Build` is not a
//! condition to paper over with a default — it means the class loader handed
//! back something no Android process would, and a fabricated `"unknown"` there
//! would be an invented device rather than a reported failure.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

/// The action name, spelled exactly as the Kotlin method is named. The
/// conformance scan matches the two by string.
pub const A = struct {
    pub const get_device_info = "getDeviceInfo";
};

/// Everything the reply carries, read out of Java and owned by the caller.
///
/// Strings are allocated; `deinit` frees them. `platform` is not a field: it
/// is the literal `"android"` in the Kotlin and there is nothing to read.
pub const DeviceInfo = struct {
    model: []const u8,
    manufacturer: []const u8,
    brand: []const u8,
    device: []const u8,
    system_version: []const u8,
    app_version: []const u8,
    sdk_version: i32,
    screen_width: i32,
    screen_height: i32,
    density: f32,
    app_build: i64,
    is_emulator: bool,

    pub fn deinit(self: DeviceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        allocator.free(self.manufacturer);
        allocator.free(self.brand);
        allocator.free(self.device);
        allocator.free(self.system_version);
        allocator.free(self.app_version);
    }
};

/// The reply bytes, byte-for-byte what the page's `JSON.parse` receives.
///
/// Keys are emitted in the Kotlin's `put` order. That is not required by JSON
/// and no consumer depends on it, but a diff against the Kotlin is the way
/// this gets reviewed, and matching the order keeps that diff readable.
pub fn render(allocator: std.mem.Allocator, info: DeviceInfo) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '{');
    try appendString(allocator, &out, "model", info.model);
    try appendString(allocator, &out, "manufacturer", info.manufacturer);
    try appendString(allocator, &out, "brand", info.brand);
    try appendString(allocator, &out, "device", info.device);
    try appendString(allocator, &out, "systemVersion", info.system_version);

    try out.appendSlice(allocator, ",\"sdkVersion\":");
    try out.print(allocator, "{d}", .{info.sdk_version});
    try out.appendSlice(allocator, ",\"screenWidth\":");
    try out.print(allocator, "{d}", .{info.screen_width});
    try out.appendSlice(allocator, ",\"screenHeight\":");
    try out.print(allocator, "{d}", .{info.screen_height});

    // `density` is a Java float and JSONObject renders it with Java's
    // shortest-round-trip rule, so 2.75 is "2.75" and never "2.7500000".
    // `{d}` is Zig's equivalent; a fixed-precision format would put trailing
    // zeroes on a value a page may well be comparing as a string.
    try out.appendSlice(allocator, ",\"density\":");
    try out.print(allocator, "{d}", .{info.density});

    try out.appendSlice(allocator, ",\"platform\":\"android\"");

    try appendString(allocator, &out, "appVersion", info.app_version);

    try out.appendSlice(allocator, ",\"appBuild\":");
    try out.print(allocator, "{d}", .{info.app_build});

    try out.appendSlice(allocator, ",\"isEmulator\":");
    try out.appendSlice(allocator, if (info.is_emulator) "true" else "false");

    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// `,"key":"escaped value"`.
///
/// The quotes are written here, not by `appendJsonEscaped`, which escapes the
/// contents and emits no delimiters. Leaving them to it produces a document
/// that tears at the first value containing a quote — and a device name is
/// user-settable on most Android builds, so that value is reachable.
fn appendString(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    key: []const u8,
    value: []const u8,
) !void {
    // A separator only when something is already in the object. `out` holds
    // just `{` on the first call, so the check is exact rather than a guess —
    // and an unconditional comma here produced `{,"model":...`, which is a
    // document that stops parsing at character two.
    if (out.items.len > 1) try out.append(allocator, ',');
    try out.append(allocator, '"');
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, "\":\"");
    try bridge_error.appendJsonEscaped(allocator, out, value);
    try out.append(allocator, '"');
}

// =============================================================================
// The JNI half
// =============================================================================

/// `Build.FINGERPRINT.contains("generic") || contains("emulator")`.
///
/// Kotlin's own test, kept as a function so it can be asserted without a
/// device. Deliberately not widened: the Kotlin does not check `"sdk"`,
/// `"vbox"` or the other markers a more thorough emulator test would, and this
/// answers the same question the shim answers.
pub fn fingerprintLooksEmulated(fingerprint: []const u8) bool {
    return std.mem.indexOf(u8, fingerprint, "generic") != null or
        std.mem.indexOf(u8, fingerprint, "emulator") != null;
}

/// Read a `static final String` off a class, as UTF-8.
fn staticString(
    allocator: std.mem.Allocator,
    j: Jni,
    cls: jni.jclass,
    name: [*:0]const u8,
) ![]u8 {
    const id = try j.staticFieldId(cls, name, "Ljava/lang/String;");
    const value = try j.staticObjectField(cls, id);
    defer j.deleteLocalRef(value);
    return j.stringToUtf8(allocator, value);
}

/// Everything the reply needs, read out of the running process.
///
/// `activity` is the `android.app.Activity` the Kotlin bridge holds — the same
/// object its `activity.windowManager` and `activity.packageManager` reach.
///
/// The whole body runs inside one local frame. Reading this much walks eleven
/// Java objects (two classes, four strings, a WindowManager, a Display, a
/// DisplayMetrics, a PackageManager, a PackageInfo) and the JVM only
/// guarantees sixteen local slots — so the alternative to a frame is eleven
/// `defer`s, one of which eventually gets forgotten.
pub fn read(allocator: std.mem.Allocator, j: Jni, activity: jobject) !DeviceInfo {
    try j.pushLocalFrame(24);
    // `null`: nothing read here survives the frame. Every string is already
    // copied into allocator memory by `stringToUtf8`, and every number is a
    // value — so there is no reference worth promoting.
    defer _ = j.popLocalFrame(null);

    const build = try j.findClass("android/os/Build");

    const model = try staticString(allocator, j, build, "MODEL");
    errdefer allocator.free(model);
    const manufacturer = try staticString(allocator, j, build, "MANUFACTURER");
    errdefer allocator.free(manufacturer);
    const brand = try staticString(allocator, j, build, "BRAND");
    errdefer allocator.free(brand);
    const device = try staticString(allocator, j, build, "DEVICE");
    errdefer allocator.free(device);

    const fingerprint = try staticString(allocator, j, build, "FINGERPRINT");
    defer allocator.free(fingerprint);

    // `Build$VERSION` — a nested class, and the `$` is not decoration: the JVM
    // knows this type by that binary name and `android/os/Build/VERSION` finds
    // nothing.
    const version_cls = try j.findClass("android/os/Build$VERSION");
    const system_version = try staticString(allocator, j, version_cls, "RELEASE");
    errdefer allocator.free(system_version);
    const sdk_version = try j.staticIntField(
        version_cls,
        try j.staticFieldId(version_cls, "SDK_INT", "I"),
    );

    const metrics = try readDisplayMetrics(j, activity);
    const package = try readPackageInfo(allocator, j, activity, sdk_version);

    return .{
        .model = model,
        .manufacturer = manufacturer,
        .brand = brand,
        .device = device,
        .system_version = system_version,
        .app_version = package.version_name,
        .sdk_version = sdk_version,
        .screen_width = metrics.width,
        .screen_height = metrics.height,
        .density = metrics.density,
        .app_build = package.build,
        .is_emulator = fingerprintLooksEmulated(fingerprint),
    };
}

const Metrics = struct { width: i32, height: i32, density: f32 };

/// `activity.windowManager.defaultDisplay.getMetrics(DisplayMetrics())`.
///
/// `getDefaultDisplay` is deprecated from API 30 and the Kotlin suppresses the
/// warning rather than branching. Reproduced as-is: switching to
/// `Context.getDisplay()` here would answer a different question on a
/// multi-display device than the shim answers, and this action's contract is
/// the shim's until the shim changes.
fn readDisplayMetrics(j: Jni, activity: jobject) !Metrics {
    const activity_cls = try j.objectClass(activity);
    const window_manager = try j.callObjectMethod(
        activity,
        try j.methodId(activity_cls, "getWindowManager", "()Landroid/view/WindowManager;"),
    );

    const wm_cls = try j.objectClass(window_manager);
    const display = try j.callObjectMethod(
        window_manager,
        try j.methodId(wm_cls, "getDefaultDisplay", "()Landroid/view/Display;"),
    );

    // `DisplayMetrics` is filled in by the callee, so it has to be constructed
    // here and handed over — the one place this action allocates a Java object.
    const metrics_cls = try j.findClass("android/util/DisplayMetrics");
    const metrics = try j.newObjectA(metrics_cls, try j.methodId(metrics_cls, "<init>", "()V"), &.{});

    const display_cls = try j.objectClass(display);
    try j.callVoidMethodA(
        display,
        try j.methodId(display_cls, "getMetrics", "(Landroid/util/DisplayMetrics;)V"),
        &.{.{ .l = metrics }},
    );

    // Public fields, not getters — DisplayMetrics has never had accessors.
    return .{
        .width = try j.intField(metrics, try j.fieldId(metrics_cls, "widthPixels", "I")),
        .height = try j.intField(metrics, try j.fieldId(metrics_cls, "heightPixels", "I")),
        .density = try j.floatField(metrics, try j.fieldId(metrics_cls, "density", "F")),
    };
}

const Package = struct { version_name: []const u8, build: i64 };

/// `packageManager.getPackageInfo(packageName, 0)`, with the Kotlin's own
/// fallbacks for the throw.
///
/// The two `try`/`catch` blocks in the shim collapse every failure to
/// `"unknown"` and `0`, so that is what a Java exception produces here. The
/// exception is cleared on the way — `Jni.check` does that — because leaving it
/// pending would poison the next call rather than the current one, and the
/// next call is in the caller.
fn readPackageInfo(allocator: std.mem.Allocator, j: Jni, activity: jobject, sdk: i32) !Package {
    const fallback = Package{ .version_name = try allocator.dupe(u8, "unknown"), .build = 0 };
    errdefer allocator.free(fallback.version_name);

    const activity_cls = try j.objectClass(activity);
    const manager = j.callObjectMethod(
        activity,
        try j.methodId(activity_cls, "getPackageManager", "()Landroid/content/pm/PackageManager;"),
    ) catch return fallback;

    const name = j.callObjectMethod(
        activity,
        try j.methodId(activity_cls, "getPackageName", "()Ljava/lang/String;"),
    ) catch return fallback;

    const manager_cls = try j.objectClass(manager);
    const get_info = try j.methodId(
        manager_cls,
        "getPackageInfo",
        "(Ljava/lang/String;I)Landroid/content/pm/PackageInfo;",
    );
    const info = j.callObjectMethodA(manager, get_info, &.{
        .{ .l = name },
        .{ .i = 0 },
    }) catch return fallback;

    const info_cls = try j.objectClass(info);

    const name_field = try j.fieldId(info_cls, "versionName", "Ljava/lang/String;");
    const version_object = try j.objectField(info, name_field);
    // `versionName` is genuinely nullable — an app with no `versionName` in its
    // manifest has it null, and Kotlin's `put` would store JSON null. The shim's
    // catch does not cover that, so the fallback string is used rather than
    // emitting a null a page would have to test for.
    const version_name = if (version_object == null)
        try allocator.dupe(u8, "unknown")
    else
        try j.stringToUtf8(allocator, version_object);
    errdefer allocator.free(version_name);
    allocator.free(fallback.version_name);

    // API 28 split the build number in two: `longVersionCode` is the whole
    // value, `versionCode` its low 32 bits. Reading the wrong one on a modern
    // app truncates rather than failing.
    const build: i64 = if (sdk >= 28)
        try j.longField(info, try j.fieldId(info_cls, "longVersionCode", "J"))
    else
        try j.intField(info, try j.fieldId(info_cls, "versionCode", "I"));

    return .{ .version_name = version_name, .build = build };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn sampleInfo() DeviceInfo {
    return .{
        .model = "Pixel 8 Pro",
        .manufacturer = "Google",
        .brand = "google",
        .device = "husky",
        .system_version = "14",
        .app_version = "1.2.3",
        .sdk_version = 34,
        .screen_width = 1008,
        .screen_height = 2244,
        .density = 2.625,
        .app_build = 4_000_000_123,
        .is_emulator = false,
    };
}

test "the reply carries every key the Kotlin puts, and parses" {
    // The regression this mirrors is iOS's: `getDeviceInfo` was `.live` and
    // answered four of fourteen fields, so a page read `undefined` from an
    // action that reported success. Thirteen keys or this is not the action.
    const json = try render(testing.allocator, sampleInfo());
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqual(@as(usize, 13), obj.count());

    try testing.expectEqualStrings("Pixel 8 Pro", obj.get("model").?.string);
    try testing.expectEqualStrings("Google", obj.get("manufacturer").?.string);
    try testing.expectEqualStrings("google", obj.get("brand").?.string);
    try testing.expectEqualStrings("husky", obj.get("device").?.string);
    try testing.expectEqualStrings("14", obj.get("systemVersion").?.string);
    try testing.expectEqualStrings("android", obj.get("platform").?.string);
    try testing.expectEqualStrings("1.2.3", obj.get("appVersion").?.string);
    try testing.expectEqual(@as(i64, 34), obj.get("sdkVersion").?.integer);
    try testing.expectEqual(@as(i64, 1008), obj.get("screenWidth").?.integer);
    try testing.expectEqual(@as(i64, 2244), obj.get("screenHeight").?.integer);
    try testing.expectEqual(@as(i64, 4_000_000_123), obj.get("appBuild").?.integer);
    try testing.expectEqual(false, obj.get("isEmulator").?.bool);
    try testing.expectApproxEqAbs(@as(f64, 2.625), obj.get("density").?.float, 0.0001);
}

test "appBuild survives a value that does not fit in 32 bits" {
    // The reason `longVersionCode` is read at all. An app past 2^31 builds is
    // unusual; an app whose `versionCode` encodes a date or an ABI split is
    // not, and those cross the boundary routinely. Truncating here would
    // report a different build than the one installed.
    var info = sampleInfo();
    info.app_build = 9_007_199_254_740_991;
    const json = try render(testing.allocator, info);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(
        @as(i64, 9_007_199_254_740_991),
        parsed.value.object.get("appBuild").?.integer,
    );
}

test "a device name containing a quote does not tear the document" {
    // `ro.product.model` is settable on a rooted or custom build, and
    // `appendJsonEscaped` writes no delimiters — so a caller that forgot the
    // quotes would produce a reply that stops parsing at the first one. The
    // same trap that broke the iOS location-recording state file.
    var info = sampleInfo();
    info.model = "My \"Best\" Phone";
    info.app_version = "1.0\\beta";
    const json = try render(testing.allocator, info);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("My \"Best\" Phone", parsed.value.object.get("model").?.string);
    try testing.expectEqualStrings("1.0\\beta", parsed.value.object.get("appVersion").?.string);
    try testing.expectEqual(@as(usize, 13), parsed.value.object.count());
}

test "a control character in a device name is escaped, not embedded" {
    var info = sampleInfo();
    info.model = "Tab\tNewline\n";
    const json = try render(testing.allocator, info);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("Tab\tNewline\n", parsed.value.object.get("model").?.string);
}

test "density renders the way JSONObject renders a float" {
    // Java prints a float with the shortest representation that round-trips,
    // so 2.75 is "2.75". A fixed-precision format here would emit "2.7500000"
    // and change a value some pages compare as a string.
    var info = sampleInfo();
    info.density = 2.75;
    const json = try render(testing.allocator, info);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"density\":2.75,") != null);

    info.density = 3;
    const whole = try render(testing.allocator, info);
    defer testing.allocator.free(whole);
    try testing.expect(std.mem.indexOf(u8, whole, "\"density\":3,") != null);
}

test "the emulator test asks exactly what the Kotlin asks" {
    // Real fingerprints, and the two markers the shim looks for.
    try testing.expect(fingerprintLooksEmulated("generic/sdk_gphone64_arm64/emu64a:14/UE1A.230829.036/11228894:user/release-keys"));
    try testing.expect(fingerprintLooksEmulated("Android/aosp_cf_x86_64_phone/emulator:13/x/y:userdebug/test-keys"));
    try testing.expect(!fingerprintLooksEmulated("google/husky/husky:14/AP1A.240405.002/11480754:user/release-keys"));
    try testing.expect(!fingerprintLooksEmulated("samsung/dm3qxxx/dm3q:14/UP1A.231005.007/S918BXXU4BWL5:user/release-keys"));

    // Not widened past the shim: these are emulator markers this deliberately
    // does not know about, because the Kotlin does not either.
    try testing.expect(!fingerprintLooksEmulated("unknown/vbox86p/vbox86p:9/x/y:userdebug/test-keys"));
}

test "the action name matches the Kotlin method exactly" {
    // The scan that pairs the two lists matches by string, so a rename on
    // either side has to be a rename on both.
    try testing.expectEqualStrings("getDeviceInfo", A.get_device_info);
}
