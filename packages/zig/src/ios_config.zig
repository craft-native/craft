//! What the app was configured to allow, read from the file Swift reads.
//!
//! Every capability in `CraftApp.swift`'s dispatcher is gated on a
//! `config.enable*` flag, and until now Zig had none of them. That gap was
//! recorded twice as it was hit — `bridge_mobile_system.zig` for `enableShare`,
//! `bridge_mobile_location.zig` for `enableGeolocation` — and worked around
//! once, by reading an Info.plist key the generator writes from the same flag.
//! This file closes it properly: 32 actions Zig already serves are gated in the
//! spec and were being served unconditionally, and 33 of the 48 still on the
//! shim are behind a flag rather than behind any Objective-C difficulty.
//!
//! ## One file, two readers, so the parse has to match
//!
//! `craft.config.json` is written by `packages/ios/src/index.ts:366` and
//! bundled as an optional resource by `project.yml.template`. Swift decodes it
//! out of the bundle at `CraftApp.swift:172-178`. Zig now decodes the same
//! bytes — and it has to reach the *same verdict*, because the hand-off table
//! means both runtimes serve actions in one process from one file. Two
//! opinions about whether clipboard is enabled is one app that both allows and
//! refuses the same capability depending on which arm answered.
//!
//! That is why the decode below is all-or-nothing rather than per-key, which
//! looks like a bug until you check what Swift does. `CraftConfig`'s properties
//! carry default values, but a synthesized `Decodable` does not use them: it
//! calls `decode(Bool.self, forKey:)`, which *throws* when the key is missing.
//! `try?` turns the throw into nil, and line 178 falls back to `CraftConfig()`
//! — every flag false. So a config missing one of its 40 required keys disables
//! all 35 capabilities, not the one key. Reading it per-key here would be more
//! useful and would disagree with Swift on the same file.
//!
//! Each of these was verified against a real `swiftc` decode rather than
//! assumed, because "faithful" is a claim about another language's behaviour:
//!
//!  - a missing required key throws          -> all false
//!  - `1` for a `Bool` throws                -> all false  (not coerced)
//!  - `null` for a `Bool` throws             -> all false
//!  - `"true"` for a `Bool` throws           -> all false
//!  - a non-string in `trustedOrigins` throws-> all false
//!  - an unknown extra key is ignored
//!  - `devServerURL` absent or null is fine  (it is the one optional)
//!
//! ## What a disabled capability answers, and why it is not what Swift answers
//!
//! `CAPABILITY_DISABLED`, through the ordinary error path.
//!
//! Swift replies that on 5 of its 65 gated cases — `share`, `secureClear`,
//! `getCurrentPosition`, `watchPosition`, `startLocationRecording`. The other
//! **60** have no `else` at all: the guard fails, the case falls out of the
//! switch, and the callback is never settled. The page's promise stays pending
//! until `craft-bridge.js`'s timeout fires, thirty seconds later, with no
//! indication that a configuration flag is why.
//!
//! Those 60 are not a contract to port. They are the same defect as the five
//! `ota*` actions the conformance test already catches, at twelve times the
//! scale, and the 5 correct sites say plainly what the intended answer was. So
//! this diverges from the spec deliberately and in one direction: an action
//! that Swift would hang, Zig refuses with a code naming the reason.
//!
//! ## Absent means off
//!
//! No bundled config file is every flag false, matching Swift's fallback. It is
//! also the safe direction for what is really a permissions surface: a
//! capability nobody configured is one nobody asked for. The cost is that a
//! host app which never generated a config serves nothing, which is why the
//! read logs once at warn rather than failing silently.

const std = @import("std");
const builtin = @import("builtin");
const objc_runtime = @import("objc_runtime.zig");
const compat_mutex = @import("compat_mutex.zig");
const io_context = @import("io_context.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// A capability flag in `craft.config.json`.
///
/// One member per `Bool` in Swift's `CraftConfig` that gates an action.
/// `darkMode` is a `Bool` too but gates nothing, so it is absent here and
/// present in `required_keys` — the decode needs it, the gate does not.
pub const Feature = enum {
    ar,
    audio_recording,
    background_location,
    background_tasks,
    biometric,
    bluetooth,
    calendar,
    camera,
    clipboard,
    contacts,
    deep_links,
    file_download,
    file_picker,
    geolocation,
    haptics,
    health_kit,
    in_app_purchase,
    keep_awake,
    live_activities,
    local_database,
    local_notifications,
    ml_kit,
    motion_sensors,
    nfc,
    orientation_lock,
    pdf_viewer,
    push_notifications,
    qr_scanner,
    screen_capture,
    secure_storage,
    share,
    social_auth,
    speech_recognition,
    video_recording,
    watch_app,

    /// The exact key in `craft.config.json`.
    ///
    /// Spelled out rather than derived from the member name: `enableNFC`,
    /// `enableAR`, `enablePDFViewer` and `enableMLKit` are not the
    /// camel-casing of `nfc`, `ar`, `pdf_viewer` or `ml_kit`, and a derivation
    /// that got them wrong would look up a key that is not there — which, under
    /// the all-or-nothing rule above, disables the entire app rather than
    /// failing visibly.
    pub fn jsonKey(self: Feature) []const u8 {
        return switch (self) {
            .ar => "enableAR",
            .audio_recording => "enableAudioRecording",
            .background_location => "enableBackgroundLocation",
            .background_tasks => "enableBackgroundTasks",
            .biometric => "enableBiometric",
            .bluetooth => "enableBluetooth",
            .calendar => "enableCalendar",
            .camera => "enableCamera",
            .clipboard => "enableClipboard",
            .contacts => "enableContacts",
            .deep_links => "enableDeepLinks",
            .file_download => "enableFileDownload",
            .file_picker => "enableFilePicker",
            .geolocation => "enableGeolocation",
            .haptics => "enableHaptics",
            .health_kit => "enableHealthKit",
            .in_app_purchase => "enableInAppPurchase",
            .keep_awake => "enableKeepAwake",
            .live_activities => "enableLiveActivities",
            .local_database => "enableLocalDatabase",
            .local_notifications => "enableLocalNotifications",
            .ml_kit => "enableMLKit",
            .motion_sensors => "enableMotionSensors",
            .nfc => "enableNFC",
            .orientation_lock => "enableOrientationLock",
            .pdf_viewer => "enablePDFViewer",
            .push_notifications => "enablePushNotifications",
            .qr_scanner => "enableQRScanner",
            .screen_capture => "enableScreenCapture",
            .secure_storage => "enableSecureStorage",
            .share => "enableShare",
            .social_auth => "enableSocialAuth",
            .speech_recognition => "enableSpeechRecognition",
            .video_recording => "enableVideoRecording",
            .watch_app => "enableWatchApp",
        };
    }
};

/// Which flags are on.
pub const Flags = std.EnumSet(Feature);

/// The keys Swift's synthesized `init(from:)` calls `decode` for.
///
/// Missing any one of them throws, and the throw disables everything. Only
/// `devServerURL` is optional (`String?` -> `decodeIfPresent`), so it is not
/// listed.
const string_keys = [_][]const u8{ "appName", "bundleId", "backgroundColor" };
const extra_bool_keys = [_][]const u8{"darkMode"};
const array_of_string_keys = [_][]const u8{"trustedOrigins"};
const optional_string_keys = [_][]const u8{"devServerURL"};

/// Decode `json` the way Swift decodes it.
///
/// Returns the empty set for anything Swift's `JSONDecoder` would throw on,
/// which is the same value line 178 falls back to. Pure and allocator-taking so
/// the faithfulness above is testable without a bundle, a simulator, or a run
/// loop.
pub fn parse(allocator: std.mem.Allocator, json: []const u8) Flags {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
        // Swift keeps the *first* of a duplicated key and does not throw —
        // verified, because Zig's default here is `.error`, which would have
        // made a duplicate disable the whole app where Swift shrugs and reads
        // the first value. A hand-edited config that pastes a flag twice is
        // exactly the case this covers.
        .duplicate_field_behavior = .use_first,
    }) catch {
        return Flags.empty;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        // A top-level array or scalar is not a `CraftConfig`.
        else => return Flags.empty,
    };

    inline for (string_keys) |key| {
        const v = root.get(key) orelse return Flags.empty;
        if (v != .string) return Flags.empty;
    }

    inline for (extra_bool_keys) |key| {
        const v = root.get(key) orelse return Flags.empty;
        if (v != .bool) return Flags.empty;
    }

    inline for (array_of_string_keys) |key| {
        const v = root.get(key) orelse return Flags.empty;
        if (v != .array) return Flags.empty;
        for (v.array.items) |item| {
            if (item != .string) return Flags.empty;
        }
    }

    inline for (optional_string_keys) |key| {
        // Absent is fine; so is an explicit null. Present and not a string is
        // a `typeMismatch`, which throws like any other.
        if (root.get(key)) |v| {
            if (v != .string and v != .null) return Flags.empty;
        }
    }

    var flags_out = Flags.empty;
    inline for (comptime std.enums.values(Feature)) |feature| {
        const v = root.get(feature.jsonKey()) orelse return Flags.empty;
        // `.bool` only. A JSON `1` is `.integer` here and `NSNumber`-bridged in
        // Swift, and Swift throws on it rather than coercing — verified, not
        // assumed, because coercing would be the obvious thing to write.
        if (v != .bool) return Flags.empty;
        if (v.bool) flags_out.insert(feature);
    }
    return flags_out;
}

var cache_mutex: compat_mutex.Mutex = .{};
var cached: ?Flags = null;

/// The bundled configuration, read once.
///
/// Swift reads it once in `Coordinator.init` and holds it for the life of the
/// process; a file that changed underneath would give the two runtimes
/// different answers, which is exactly what this file exists to prevent.
pub fn flags() Flags {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (cached) |f| return f;
    const f = readFromBundle();
    cached = f;
    return f;
}

/// Whether `feature` was enabled for this app.
pub fn isEnabled(feature: Feature) bool {
    return flags().contains(feature);
}

/// A config larger than this is not one we wrote.
///
/// The generator's output is about 1.5 KiB. The cap exists so a resource that
/// happens to be named `craft.config.json` and is actually a video cannot be
/// read into memory before being rejected as unparseable.
const max_config_bytes = 1 << 20;

fn readFromBundle() Flags {
    if (!is_darwin) return Flags.empty;

    const path = bundleResourcePath() orelse {
        std.log.warn(
            "ios config: no craft.config.json in the main bundle; " ++
                "every capability is disabled, matching Swift's fallback",
            .{},
        );
        return Flags.empty;
    };

    const allocator = std.heap.c_allocator;
    const bytes = readConfigFile(allocator, std.mem.span(path)) catch {
        // Bundled but unreadable. Swift's `try?` flattens this into the same
        // all-false as "no file", and so does this — but it says which one
        // happened, because they call for different fixes.
        return Flags.empty;
    } orelse return Flags.empty;
    defer allocator.free(bytes);

    const f = parse(allocator, bytes);
    if (f.count() == 0) {
        // Not necessarily an error — a config with every flag off is legal and
        // is the generator's default. Said once, at info, because the
        // alternative reading (a malformed file disabling everything) is
        // otherwise indistinguishable from it in the field.
        std.log.info(
            "ios config: craft.config.json enables no capabilities; " ++
                "if that is unexpected, check every required key is present, " ++
                "since one missing key disables all of them",
            .{},
        );
    }
    return f;
}

/// The config file's bytes, or null if there is no file there.
///
/// Takes the path rather than finding it, so the host tests can drive the read
/// against a real file on any platform instead of only against an app bundle
/// that exists on exactly one.
fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const io = io_context.get();

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            std.log.warn("ios config: could not open '{s}': {}", .{ path, err });
            return error.ConfigUnreadable;
        },
    };
    defer file.close(io);

    const info = file.stat(io) catch |err| {
        std.log.warn("ios config: could not stat '{s}': {}", .{ path, err });
        return error.ConfigUnreadable;
    };

    if (info.size > max_config_bytes) {
        std.log.warn(
            "ios config: craft.config.json is {d} bytes, over the {d}-byte ceiling; " ++
                "refusing to read it",
            .{ info.size, max_config_bytes },
        );
        return error.ConfigUnreadable;
    }

    const buf = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(buf);

    var read: usize = 0;
    while (read < buf.len) {
        const n = file.readStreaming(io, &.{buf[read..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                std.log.warn("ios config: could not read '{s}': {}", .{ path, err });
                return error.ConfigUnreadable;
            },
        };
        if (n == 0) break;
        read += n;
    }

    // A short read is not a truncated config to parse leniently: JSON that
    // stops early is either invalid (all-false, correctly) or — worse —
    // valid-looking with the tail of the flags missing, which under the
    // all-or-nothing rule is also all-false. Refusing here says why.
    if (read != buf.len) {
        std.log.warn(
            "ios config: read {d} of {d} bytes from '{s}'",
            .{ read, buf.len, path },
        );
        allocator.free(buf);
        return error.ConfigUnreadable;
    }

    return buf;
}

/// `[[NSBundle mainBundle] pathForResource:@"craft.config" ofType:@"json"]`.
fn bundleResourcePath() ?[*:0]const u8 {
    const NSBundle = objc.objc_getClass("NSBundle") orelse return null;
    const sel_main = objc.sel_registerName("mainBundle") orelse return null;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return null;

    const NSString = objc.objc_getClass("NSString") orelse return null;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse return null;
    const name = objc.msgSendId1(NSString, sel_string, @as([*:0]const u8, "craft.config")) orelse
        return null;
    const ext = objc.msgSendId1(NSString, sel_string, @as([*:0]const u8, "json")) orelse
        return null;

    const sel_path = objc.sel_registerName("pathForResource:ofType:") orelse return null;
    const path = objc.msgSendId2(bundle, sel_path, name, ext) orelse return null;

    return objc.getNSStringUTF8(path);
}

/// The feature an action is gated on, or null if Zig serving it is ungated.
///
/// Null means one of two different things, and the conformance test in
/// `test/ios_config_gate_test.zig` is what keeps them from being confused:
/// either the spec gates the action on nothing, or Zig does not serve it and
/// the shim applies its own gate. A Zig-served action that the spec gates and
/// this table omits fails that test rather than shipping ungated, which is the
/// state all 32 entries below were in before this file existed.
pub fn gateFor(action: []const u8) ?Feature {
    const table = comptime [_]struct { []const u8, Feature }{
        .{ "addContact", .contacts },
        .{ "cancelAllBackgroundTasks", .background_tasks },
        .{ "cancelAllNotifications", .local_notifications },
        .{ "cancelBackgroundTask", .background_tasks },
        .{ "cancelNotification", .local_notifications },
        .{ "classifyImage", .ml_kit },
        .{ "clipboardRead", .clipboard },
        .{ "clipboardWrite", .clipboard },
        .{ "createCalendarEvent", .calendar },
        .{ "dbExecute", .local_database },
        .{ "dbQuery", .local_database },
        .{ "deleteCalendarEvent", .calendar },
        .{ "detectObjects", .ml_kit },
        .{ "getCalendarEvents", .calendar },
        .{ "getContacts", .contacts },
        .{ "getCurrentPosition", .geolocation },
        .{ "getPendingNotifications", .local_notifications },
        .{ "haptic", .haptics },
        .{ "lockOrientation", .orientation_lock },
        .{ "openCamera", .camera },
        .{ "pickContact", .contacts },
        .{ "pickFile", .file_picker },
        .{ "pickImage", .camera },
        .{ "recognizeText", .ml_kit },
        .{ "registerDeepLinkHandler", .deep_links },
        .{ "saveFile", .file_download },
        .{ "scheduleBackgroundTask", .background_tasks },
        .{ "secureClear", .secure_storage },
        .{ "secureGet", .secure_storage },
        .{ "secureRemove", .secure_storage },
        .{ "secureSet", .secure_storage },
        .{ "setKeepAwake", .keep_awake },
        .{ "share", .share },
        .{ "startMotionUpdates", .motion_sensors },
        .{ "takeScreenshot", .screen_capture },
        .{ "unlockOrientation", .orientation_lock },
        .{ "watchPosition", .geolocation },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, action, entry[0])) return entry[1];
    }
    return null;
}

const testing = std.testing;

/// A config with every required key present, so a test can remove exactly one
/// thing and see the effect of removing that one thing.
fn completeConfig(allocator: std.mem.Allocator, comptime overrides: []const u8) ![]u8 {
    @setEvalBranchQuota(200_000);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    if (overrides.len != 0) {
        try buf.appendSlice(allocator, overrides);
        try buf.append(allocator, ',');
    }

    // Every required key, except one the caller already spelled. Emitting it
    // twice and relying on which duplicate wins would make each test depend on
    // `duplicate_field_behavior`, so a change to that option would quietly
    // rewrite what these tests assert instead of failing one of them.
    inline for (comptime string_keys ++ extra_bool_keys ++ array_of_string_keys) |key| {
        if (comptime !mentions(overrides, key)) {
            try buf.appendSlice(allocator, "\"" ++ key ++ "\":" ++ comptime placeholderFor(key) ++ ",");
        }
    }
    inline for (comptime std.enums.values(Feature)) |feature| {
        if (comptime !mentions(overrides, feature.jsonKey())) {
            try buf.appendSlice(allocator, "\"");
            try buf.appendSlice(allocator, feature.jsonKey());
            try buf.appendSlice(allocator, "\":true,");
        }
    }
    if (buf.items[buf.items.len - 1] == ',') _ = buf.pop();
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

/// Whether `overrides` already spells `"key":`.
fn mentions(comptime overrides: []const u8, comptime key: []const u8) bool {
    return std.mem.indexOf(u8, overrides, "\"" ++ key ++ "\":") != null;
}

fn placeholderFor(comptime key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "trustedOrigins")) return "[]";
    if (std.mem.eql(u8, key, "darkMode")) return "true";
    return "\"T\"";
}

test "a complete config enables exactly the flags it sets" {
    const json = try completeConfig(testing.allocator, "\"enableShare\":false,\"enableNFC\":false");
    defer testing.allocator.free(json);

    const f = parse(testing.allocator, json);

    // The two overrides land last, and `std.json` keeps the last value for a
    // duplicated key, so these are the false ones.
    try testing.expect(!f.contains(.share));
    try testing.expect(!f.contains(.nfc));
    try testing.expect(f.contains(.clipboard));
    try testing.expect(f.contains(.ml_kit));
    try testing.expectEqual(std.enums.values(Feature).len - 2, f.count());
}

test "one missing key disables every capability, as Swift's decoder does" {
    // The behaviour this whole file is shaped around, and the one that looks
    // like a bug: `CraftConfig`'s properties have defaults, but a synthesized
    // `Decodable` never uses them — it throws `keyNotFound`, `try?` swallows
    // it, and `CraftApp.swift:178` falls back to an all-false `CraftConfig()`.
    // Verified against a real swiftc decode before being written here.
    const complete = try completeConfig(testing.allocator, "");
    defer testing.allocator.free(complete);
    try testing.expectEqual(std.enums.values(Feature).len, parse(testing.allocator, complete).count());

    // Drop `enableHaptics` alone. Per-key decoding would lose one capability.
    const needle = ",\"enableHaptics\":true";
    const at = std.mem.indexOf(u8, complete, needle).?;
    const without = try std.mem.concat(testing.allocator, u8, &.{
        complete[0..at], complete[at + needle.len ..],
    });
    defer testing.allocator.free(without);

    try testing.expectEqual(@as(usize, 0), parse(testing.allocator, without).count());
}

test "a required non-capability key is required too" {
    // `darkMode`, `appName`, `bundleId`, `backgroundColor` and `trustedOrigins`
    // gate nothing, so it is tempting to ignore them. Swift decodes all five,
    // and throwing on them is how a config that is merely *stale* — written by
    // an older generator that had fewer keys — disables the app rather than
    // half-enabling it.
    inline for (.{ "\"darkMode\":true,", "\"appName\":\"T\",", "\"trustedOrigins\":[]," }) |needle| {
        const complete = try completeConfig(testing.allocator, "");
        defer testing.allocator.free(complete);
        const at = std.mem.indexOf(u8, complete, needle).?;
        const without = try std.mem.concat(testing.allocator, u8, &.{
            complete[0..at], complete[at + needle.len ..],
        });
        defer testing.allocator.free(without);
        try testing.expectEqual(@as(usize, 0), parse(testing.allocator, without).count());
    }
}

test "a wrongly typed flag is a throw, not a coercion" {
    // Each of these was run through `swiftc` before being pinned. `1` is the
    // one worth stating: JSON has no bool/number distinction in many writers,
    // Foundation bridges both to `NSNumber`, and coercing would be the
    // reasonable-looking choice — but Swift throws, so an app whose config was
    // hand-edited to `"enableCamera": 1` has *no* capabilities, not camera.
    inline for (.{ "1", "0", "null", "\"true\"", "[]" }) |bad| {
        const json = try completeConfig(testing.allocator, "\"enableCamera\":" ++ bad);
        defer testing.allocator.free(json);
        try testing.expectEqual(@as(usize, 0), parse(testing.allocator, json).count());
    }
}

test "an unknown key is ignored, and devServerURL may be absent or null" {
    const with_extra = try completeConfig(testing.allocator, "\"somethingNewer\":42");
    defer testing.allocator.free(with_extra);
    try testing.expectEqual(std.enums.values(Feature).len, parse(testing.allocator, with_extra).count());

    // `devServerURL` is the one `String?` in the struct, so it is the one key
    // whose absence is not a throw.
    const with_null = try completeConfig(testing.allocator, "\"devServerURL\":null");
    defer testing.allocator.free(with_null);
    try testing.expectEqual(std.enums.values(Feature).len, parse(testing.allocator, with_null).count());

    const with_bad = try completeConfig(testing.allocator, "\"devServerURL\":7");
    defer testing.allocator.free(with_bad);
    try testing.expectEqual(@as(usize, 0), parse(testing.allocator, with_bad).count());
}

test "trustedOrigins is checked element by element" {
    // `[String]` throws on the first non-string element, so an array that is
    // mostly strings still disables the app.
    const bad = try completeConfig(testing.allocator, "\"trustedOrigins\":[\"https://a\",3]");
    defer testing.allocator.free(bad);
    try testing.expectEqual(@as(usize, 0), parse(testing.allocator, bad).count());

    const good = try completeConfig(testing.allocator, "\"trustedOrigins\":[\"https://a\"]");
    defer testing.allocator.free(good);
    try testing.expectEqual(std.enums.values(Feature).len, parse(testing.allocator, good).count());
}

test "malformed or non-object JSON is all-false rather than a crash" {
    inline for (.{ "", "{", "[]", "null", "\"a string\"", "{\"appName\":}" }) |bad| {
        try testing.expectEqual(@as(usize, 0), parse(testing.allocator, bad).count());
    }
}

test "every capability key is spelled the way Swift spells it" {
    // A key that does not exist in the file reads as missing, and a missing key
    // disables all 35 — so a single typo here is not a one-flag bug, it is an
    // app that serves nothing. The four irregular ones are the risk:
    // camel-casing the enum member would produce `enableNfc`, `enableAr`,
    // `enablePdfViewer` and `enableMlKit`, none of which are in the file.
    try testing.expectEqualStrings("enableNFC", Feature.nfc.jsonKey());
    try testing.expectEqualStrings("enableAR", Feature.ar.jsonKey());
    try testing.expectEqualStrings("enablePDFViewer", Feature.pdf_viewer.jsonKey());
    try testing.expectEqualStrings("enableMLKit", Feature.ml_kit.jsonKey());

    @setEvalBranchQuota(10_000);
    inline for (comptime std.enums.values(Feature)) |feature| {
        const key = feature.jsonKey();
        try testing.expect(std.mem.startsWith(u8, key, "enable"));
        // Distinctness: two members sharing a key would silently make one of
        // them read the other's flag.
        inline for (comptime std.enums.values(Feature)) |other| {
            if (feature != other) try testing.expect(!std.mem.eql(u8, key, other.jsonKey()));
        }
    }
}

test "gateFor answers for a served action and stays quiet for the rest" {
    try testing.expectEqual(Feature.clipboard, gateFor("clipboardRead").?);
    try testing.expectEqual(Feature.camera, gateFor("pickImage").?);
    try testing.expectEqual(Feature.secure_storage, gateFor("secureSet").?);

    // `openURL` is served and ungated in the spec; `startAR` is gated but not
    // served here, so the shim's own gate applies and this must not answer.
    try testing.expect(gateFor("openURL") == null);
    try testing.expect(gateFor("startAR") == null);
    try testing.expect(gateFor("") == null);
}

test "a duplicated key keeps the first value, as Swift does" {
    // Zig's default for a repeated field is `error.DuplicateField`, which would
    // have disabled every capability over a config that pastes one flag twice.
    // Swift reads the first and carries on — verified with swiftc — so the
    // parse opts into `.use_first`. Without that option this test fails, which
    // is the point of having it.
    const json = try completeConfig(testing.allocator, "\"enableShare\":false");
    defer testing.allocator.free(json);

    const at = std.mem.indexOf(u8, json, "\"enableShare\":false").?;
    const with_dup = try std.mem.concat(testing.allocator, u8, &.{
        json[0 .. at + "\"enableShare\":false".len],
        ",\"enableShare\":true",
        json[at + "\"enableShare\":false".len ..],
    });
    defer testing.allocator.free(with_dup);

    const f = parse(testing.allocator, with_dup);
    try testing.expect(!f.contains(.share)); // first wins, not last
    try testing.expectEqual(std.enums.values(Feature).len - 1, f.count());
}

test "the config file read distinguishes absent from unreadable" {
    // Swift's `try?` flattens both into the same all-false. This does too, at
    // the gate — but the read itself keeps them apart, because "no config was
    // generated" and "the config is there and I could not open it" call for
    // different fixes and only one of them is normal.
    const io = io_context.get();
    const missing = try readConfigFile(testing.allocator, "craft-config-does-not-exist.json");
    try testing.expect(missing == null);

    const name = "craft-config-read-probe.json";
    const file = try std.Io.Dir.cwd().createFile(io, name, .{});
    defer std.Io.Dir.cwd().deleteFile(io, name) catch {};
    {
        defer file.close(io);
        try file.writeStreamingAll(io, "{\"appName\":\"T\"}");
    }

    const bytes = (try readConfigFile(testing.allocator, name)).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"appName\":\"T\"}", bytes);

    // And a real file that is not a config is all-false rather than a crash.
    try testing.expectEqual(@as(usize, 0), parse(testing.allocator, bytes).count());
}
