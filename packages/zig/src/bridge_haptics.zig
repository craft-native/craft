//! `t: "haptics"` — the trackpad half of the haptics API the phones already
//! have.
//!
//! An app calls `haptics.selection()` from `craft-native` and expects the same
//! line to do the sensible thing on every host. On iOS and Android that reaches
//! the `mobile` namespace's `haptic` (`bridge_mobile_haptics.zig`,
//! `bridge_android_haptics.zig`). On a Mac it reaches this file, through the
//! same two action names and the same `{style}` payload, so `craft-bridge.js`
//! can give `window.craft.haptic` and `window.craft.haptics` the shape the
//! mobile bridges give them and the SDK never has to ask where it is running.
//!
//! ## What a Mac can play
//!
//! `NSHapticFeedbackManager` is not a Taptic Engine. It has three patterns —
//! Generic, Alignment, LevelChange — and no intensity, no duration and no
//! notion of success or failure, so the phone vocabulary has to be folded onto
//! those three. `patternForStyle` is that fold, and it says why each style lands
//! where it does.
//!
//! ## When nothing is felt, and why that still answers `true`
//!
//! AppKit plays feedback only while a finger is on a Force Touch trackpad and
//! only for the active app. A Mac with no Force Touch trackpad, a Magic
//! Trackpad that is asleep, a mouse, or an app in the background all get a
//! performer that accepts the call and does nothing — and AppKit offers no way
//! to ask which of those applies. So `true` here means what it means on iOS:
//! "AppKit accepted the call", never "the user felt it". That is deliberate.
//! Haptics are feedback; a desktop with nothing to buzz should behave like a
//! phone with haptics switched off, not fail the flow that asked.
//!
//! ## Off macOS
//!
//! Linux and Windows do not route this namespace: their dispatchers answer
//! every type they do not serve with `PLATFORM_NOT_SUPPORTED`, which is the
//! honest reply — GTK and Win32 have no haptics API to call. `craft.haptic()`
//! surfaces that so a page can feature-detect, and `craft.haptics.*` absorbs it
//! the way the mobile shims absorb `CAPABILITY_DISABLED`. `perform` refuses
//! off macOS as well, so a host test of the handler sees the same refusal the
//! page would.

const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const capabilities = @import("capabilities.zig");

const BridgeError = bridge_error.BridgeError;

/// The action names this bridge dispatches on.
///
/// The same two names the `mobile` namespace serves, on purpose: the page-side
/// shim is then one shape on every host, and `craft.invoke('haptics.haptic')`
/// reads the way `craft.haptic()` does. No other desktop bridge answers either
/// name, so the pending-reply queue cannot confuse them.
pub const A = struct {
    pub const haptic = "haptic";
    pub const vibrate = "vibrate";
};

/// What craft serves on the `haptics` namespace.
pub const capability_actions = [_]capabilities.ActionDecl{
    // `.result`, the bare `true` the mobile bridges answer with. The page's
    // `craft.haptic()` awaits it, and `.none` would leave that promise open.
    .{ .name = A.haptic, .reply = .result },
    .{ .name = A.vibrate, .reply = .result },
};

/// The reply both actions send. A bare `true`, byte-identical to
/// `bridge_mobile_haptics.zig`, so a page written against the phone reads the
/// same answer here. Truthy on purpose: `craft-bridge.js` turns a null payload
/// into `{}`, and the mobile shim's callers already expect `true`.
const success_reply = "true";

/// `NSHapticFeedbackPattern`, from AppKit's `NSHapticFeedback.h`.
///
/// Spelled out rather than borrowed from `audio.zig`, whose table numbers the
/// patterns from 1 and so plays Alignment where it means Generic.
pub const Pattern = enum(c_long) {
    generic = 0,
    alignment = 1,
    level_change = 2,
};

/// `NSHapticFeedbackPerformanceTimeNow`.
///
/// Not `Default`, which AppKit currently treats as `DrawCompleted` and so holds
/// the tap until the next screen update. A page asking for feedback has
/// usually just changed the DOM, and WebKit's draw is not AppKit's: waiting on
/// it can land the tap a frame late or, in a window that is not redrawing, not
/// at all.
const performance_time_now: c_ulong = 1;

/// The style vocabulary of `craft.haptic()`, folded onto the three patterns a
/// Mac has.
///
/// Accepts both spellings a page may hold: the one the mobile shims post
/// (`'light'`, `'heavy'`, `'success'`, `'selection'`, …) and the hyphenated
/// `HapticType` the SDK declares (`'impact-heavy'`, `'notification-error'`).
/// Mobile reads only the first; reading both here costs nothing and means a
/// page that took the type at its word is not quietly given Generic.
///
///  - **selection → Alignment.** Apple reserves Alignment for something
///    snapping into place — a guide, a best fit — which is the closest thing a
///    trackpad has to a picker clicking over to its next value. It is also the
///    one pattern that reads as distinct from a plain tap.
///  - **heavy, error → LevelChange.** LevelChange is the click a Force Touch
///    button gives on crossing a pressure level: the firmest of the three. A
///    heavy impact is the strongest the phones offer, and an error is the one
///    notification that must not be mistaken for a routine tap.
///  - **Everything else → Generic.** Light, medium, soft and rigid differ on a
///    phone in strength, which a trackpad cannot vary. Success and warning are
///    what `craft.haptics.notification()` sends as a light and a medium impact
///    on iOS and Android, so they land where those impacts land and the two
///    routes to one notification feel the same. An unknown style takes Generic
///    too, matching the mobile bridges, whose `default:` arm absorbs a typo as
///    a medium impact rather than rejecting it.
pub fn patternForStyle(style: []const u8) Pattern {
    const level_change = [_][]const u8{ "heavy", "impact-heavy", "error", "notification-error" };
    for (level_change) |name| {
        if (std.mem.eql(u8, style, name)) return .level_change;
    }
    if (std.mem.eql(u8, style, "selection")) return .alignment;
    return .generic;
}

/// The payload's object, or `null` when the page sent none.
///
/// `craft.invoke('haptics.haptic')` with no params posts an empty `d`, and
/// treating that as "no fields" — so every field takes its default — matches
/// how the mobile bridges read a body with no `style`. Anything present must
/// be an object: there is no dictionary in `[1,2]` for a default to stand in
/// for, so that is `InvalidJSON`, not a medium tap.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) BridgeError!?std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, data, " \t\r\n").len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return BridgeError.InvalidJSON;
    if (parsed.value != .object) {
        parsed.deinit();
        return BridgeError.InvalidJSON;
    }
    return parsed;
}

/// `style` as the mobile bridges read it: the string when there is one, and
/// `"medium"` for anything else — absent, null, a number, an object.
fn styleOf(value: ?std.json.Value) []const u8 {
    const v = value orelse return "medium";
    return switch (v) {
        .string => |text| text,
        else => "medium",
    };
}

/// Whether a `vibrate` payload asks for anything to be played.
///
/// The trackpad plays fixed, momentary taps: there is no duration to honour and
/// AppKit offers only "now" or "after the next draw" as timing. So a pattern
/// cannot be reproduced, and the question this answers is the one part of it a
/// Mac can keep — did the page ask for a buzz at all? The rules are the mobile
/// bridge's (`bridge_mobile_haptics.zig`, `patternArray` and `impactDelayNs`),
/// so the same pattern is silent or not on both:
///
///  - An integer array fires when an even index holds a positive duration. The
///    odd entries are pauses; `[]` — what `craft.haptics.vibrate()` sends with
///    no argument — fires nothing.
///  - Anything else — no `pattern`, a number, a string, an array holding a
///    non-integer — fires once, as the mobile `else` arm does.
fn patternFires(value: ?std.json.Value) bool {
    const v = value orelse return true;
    const items = switch (v) {
        .array => |a| a.items,
        else => return true,
    };
    for (items) |item| {
        if (item != .integer) return true;
    }
    for (items, 0..) |item, index| {
        if (index % 2 == 0 and item.integer > 0) return true;
    }
    return false;
}

pub const HapticsBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    /// The dispatcher's entry point. Failures are reported to the page here,
    /// because the macOS chain only logs what a bridge returns — and an
    /// unreported failure leaves `craft.haptic()` waiting out its 30s timeout.
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) void {
        self.dispatch(action, data) catch |err| {
            bridge_error.sendErrorToJS(self.allocator, action, bridge_error.fromHandlerError(err));
        };
    }

    /// The chain itself, returning its error so a test can see it.
    pub fn dispatch(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.haptic)) {
            return self.haptic(data);
        } else if (std.mem.eql(u8, action, A.vibrate)) {
            return self.vibrate(data);
        }
        return BridgeError.UnknownAction;
    }

    /// `{"style": "selection"}` — one tap in the pattern `patternForStyle`
    /// picks. A missing payload or style is a medium impact, i.e. Generic.
    fn haptic(self: *Self, data: []const u8) !void {
        const parsed = try parsePayload(self.allocator, data);
        defer if (parsed) |p| p.deinit();
        const style = styleOf(if (parsed) |p| p.value.object.get("style") else null);

        try perform(patternForStyle(style));
        bridge_error.sendResultToJS(self.allocator, A.haptic, success_reply);
    }

    /// `{"pattern": [100, 50, 100]}` — one Generic tap if the pattern asks for
    /// anything, nothing if it does not. See `patternFires`.
    fn vibrate(self: *Self, data: []const u8) !void {
        const parsed = try parsePayload(self.allocator, data);
        defer if (parsed) |p| p.deinit();

        if (patternFires(if (parsed) |p| p.value.object.get("pattern") else null)) {
            try perform(.generic);
        } else if (builtin.os.tag != .macos) {
            // Nothing to play, and still not a platform that could have: say
            // so, rather than answering `true` for hardware that is not there.
            return error.UnsupportedPlatform;
        }
        bridge_error.sendResultToJS(self.allocator, A.vibrate, success_reply);
    }
};

/// `[[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:pattern
/// performanceTime:NSHapticFeedbackPerformanceTimeNow]`.
///
/// The performer is asked for on every call, as Apple's header says to: it is
/// "the most appropriate feedback performer for the current input device", and
/// the user can plug in or unplug a trackpad while the app runs.
///
/// No dispatch hop. The only path here starts in the `WKScriptMessageHandler`
/// callback, which WebKit delivers on the main thread.
fn perform(pattern: Pattern) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const macos = @import("macos.zig");

    const manager = macos.getClass("NSHapticFeedbackManager");
    if (manager == null) return BridgeError.NativeCallFailed;
    const performer = macos.msgSend0(manager, "defaultPerformer");
    if (performer == null) return BridgeError.NativeCallFailed;

    // Both arguments are integers — NSInteger and NSUInteger — so the cast must
    // say so. The generic `msgSend2` would pass whatever type it is handed, and
    // a pattern smuggled through as a pointer is a garbage pattern, silently.
    const PerformFeedback = *const fn (macos.objc.id, macos.objc.SEL, c_long, c_ulong) callconv(.c) void;
    const perform_feedback: PerformFeedback = @ptrCast(&macos.objc.objc_msgSend);
    perform_feedback(
        performer,
        macos.sel("performFeedbackPattern:performanceTime:"),
        @intFromEnum(pattern),
        performance_time_now,
    );
}

const testing = std.testing;

test "the table declares exactly the two actions the dispatcher serves" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    try testing.expectEqualStrings(A.haptic, capability_actions[0].name);
    try testing.expectEqualStrings(A.vibrate, capability_actions[1].name);
    for (capability_actions) |decl| {
        // Both are awaited by the page, so both must answer.
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "the action names match the mobile namespace's" {
    // The point of the namespace: one page-side shape on every host. A rename
    // on either side would make `craft.invoke('haptics.haptic')` and the
    // phone's `haptic` drift apart without anything failing.
    try testing.expectEqualStrings("haptic", A.haptic);
    try testing.expectEqualStrings("vibrate", A.vibrate);
}

test "the patterns carry AppKit's values" {
    // `audio.zig` numbers these from 1, which plays Alignment for Generic and
    // LevelChange for Alignment. Pinned against the header so this file cannot
    // make the same slip.
    try testing.expectEqual(@as(c_long, 0), @intFromEnum(Pattern.generic));
    try testing.expectEqual(@as(c_long, 1), @intFromEnum(Pattern.alignment));
    try testing.expectEqual(@as(c_long, 2), @intFromEnum(Pattern.level_change));
    try testing.expectEqual(@as(c_ulong, 1), performance_time_now);
}

test "every style the mobile shims post maps to a pattern" {
    try testing.expectEqual(Pattern.alignment, patternForStyle("selection"));
    try testing.expectEqual(Pattern.level_change, patternForStyle("heavy"));
    try testing.expectEqual(Pattern.level_change, patternForStyle("error"));
    try testing.expectEqual(Pattern.generic, patternForStyle("light"));
    try testing.expectEqual(Pattern.generic, patternForStyle("medium"));
    try testing.expectEqual(Pattern.generic, patternForStyle("soft"));
    try testing.expectEqual(Pattern.generic, patternForStyle("rigid"));
    try testing.expectEqual(Pattern.generic, patternForStyle("success"));
    try testing.expectEqual(Pattern.generic, patternForStyle("warning"));
}

test "the SDK's hyphenated HapticType spellings map the same way" {
    try testing.expectEqual(Pattern.alignment, patternForStyle("selection"));
    try testing.expectEqual(Pattern.generic, patternForStyle("impact-light"));
    try testing.expectEqual(Pattern.generic, patternForStyle("impact-medium"));
    try testing.expectEqual(Pattern.level_change, patternForStyle("impact-heavy"));
    try testing.expectEqual(Pattern.generic, patternForStyle("notification-success"));
    try testing.expectEqual(Pattern.generic, patternForStyle("notification-warning"));
    try testing.expectEqual(Pattern.level_change, patternForStyle("notification-error"));
}

test "an unknown style is a plain tap, not an error" {
    // The mobile bridges' `default:` arm, carried across: a typo is
    // indistinguishable from "medium" there, and must be here.
    try testing.expectEqual(Pattern.generic, patternForStyle("mediuim"));
    try testing.expectEqual(Pattern.generic, patternForStyle(""));
    try testing.expectEqual(Pattern.generic, patternForStyle("HEAVY"));
}

test "style is read the way the mobile bridges read it" {
    const alloc = testing.allocator;
    const cases = [_]struct { json: []const u8, want: Pattern }{
        .{ .json = "{\"style\":\"heavy\"}", .want = .level_change },
        .{ .json = "{\"style\":\"selection\"}", .want = .alignment },
        // Every failed `as? String` takes "medium".
        .{ .json = "{}", .want = .generic },
        .{ .json = "{\"style\":null}", .want = .generic },
        .{ .json = "{\"style\":2}", .want = .generic },
        .{ .json = "{\"style\":[\"heavy\"]}", .want = .generic },
    };
    for (cases) |case| {
        const parsed = (try parsePayload(alloc, case.json)).?;
        defer parsed.deinit();
        try testing.expectEqual(case.want, patternForStyle(styleOf(parsed.value.object.get("style"))));
    }
    // No payload at all is no fields, so the default — not a parse failure.
    try testing.expect((try parsePayload(alloc, "")) == null);
    try testing.expect((try parsePayload(alloc, " \n")) == null);
    try testing.expectEqualStrings("medium", styleOf(null));
}

test "a payload that is not an object is rejected, not defaulted" {
    const alloc = testing.allocator;
    try testing.expectError(BridgeError.InvalidJSON, parsePayload(alloc, "not json"));
    try testing.expectError(BridgeError.InvalidJSON, parsePayload(alloc, "[1,2]"));
    try testing.expectError(BridgeError.InvalidJSON, parsePayload(alloc, "\"heavy\""));
    try testing.expectError(BridgeError.InvalidJSON, parsePayload(alloc, "{\"style\":"));
}

/// Parse `json` and ask `patternFires` about its `pattern`.
fn fires(json: []const u8) !bool {
    const parsed = (try parsePayload(testing.allocator, json)).?;
    defer parsed.deinit();
    return patternFires(parsed.value.object.get("pattern"));
}

test "a vibrate pattern fires when an even entry is positive" {
    try testing.expect(try fires("{\"pattern\":[100]}"));
    try testing.expect(try fires("{\"pattern\":[100,50,100]}"));
    try testing.expect(try fires("{\"pattern\":[0,0,200]}"));
}

test "an empty or all-pause pattern plays nothing" {
    // `craft.haptics.vibrate()` sends `[]`, and must not buzz.
    try testing.expect(!(try fires("{\"pattern\":[]}")));
    // Odd entries are pauses, and non-positive durations are skipped.
    try testing.expect(!(try fires("{\"pattern\":[0,500]}")));
    try testing.expect(!(try fires("{\"pattern\":[-100,500,0]}")));
}

test "a missing or malformed pattern takes the single-tap arm" {
    // The mobile `else` arm: every failed `as? [Int]` fires once.
    try testing.expect(try fires("{}"));
    try testing.expect(try fires("{\"pattern\":null}"));
    try testing.expect(try fires("{\"pattern\":100}"));
    try testing.expect(try fires("{\"pattern\":[100.5]}"));
    try testing.expect(try fires("{\"pattern\":[0,\"x\"]}"));
    try testing.expect(patternFires(null));
}

test "every declared action dispatches — none of them falls through as unknown" {
    var bridge = HapticsBridge.init(testing.allocator);
    defer bridge.deinit();
    // Off macOS each one refuses with UnsupportedPlatform. On macOS each one
    // really calls AppKit — a test runner has no trackpad focus, so the
    // performer accepts and plays nothing — and then fails only to find a
    // webview to reply to, which `sendResultToJS` logs rather than returns.
    // So on a Mac this is the whole native path, end to end, minus the page.
    for (capability_actions) |decl| {
        bridge.dispatch(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            try testing.expect(builtin.os.tag != .macos);
            continue;
        };
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = HapticsBridge.init(testing.allocator);
    defer bridge.deinit();
    try testing.expectError(BridgeError.UnknownAction, bridge.dispatch("noSuchAction", "{}"));
    // The namespace is `haptics`; the action is `haptic`.
    try testing.expectError(BridgeError.UnknownAction, bridge.dispatch("haptics", "{}"));
    // And the SDK helper names are facade methods, not actions.
    try testing.expectError(BridgeError.UnknownAction, bridge.dispatch("selection", "{}"));
}

test "off macOS the handler refuses with the platform error the page is shown" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    var bridge = HapticsBridge.init(testing.allocator);
    defer bridge.deinit();
    try testing.expectError(error.UnsupportedPlatform, bridge.dispatch(A.haptic, "{\"style\":\"heavy\"}"));
    try testing.expectError(error.UnsupportedPlatform, bridge.dispatch(A.vibrate, "{\"pattern\":[]}"));
    try testing.expectEqual(BridgeError.PlatformNotSupported, bridge_error.fromHandlerError(error.UnsupportedPlatform));
    // A malformed payload is still reported as malformed first.
    try testing.expectError(BridgeError.InvalidJSON, bridge.dispatch(A.haptic, "[1]"));
}

test "the reply is the bare JSON literal the mobile bridges send" {
    try testing.expectEqualStrings("true", success_reply);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, success_reply, .{});
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.bool);
}
