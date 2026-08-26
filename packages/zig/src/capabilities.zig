//! What the native side actually serves, as data the page can ask for.
//!
//! Three shipped bugs share one shape: the JS bridge declares a surface, native
//! silently does not serve it, and the app finds out in production. Reachability
//! of `window.craft.x` is not evidence that anything is behind it — the script is
//! one `@embedFile`d blob, injected whole, whatever the binary implements.
//!
//! The point of this file is **not** to list the gaps. It is that there was no
//! mechanism by which a shipped surface could be *known* to be wired, so the
//! number of gaps was whatever the last manual audit said it was. This is the
//! mechanism; the gaps are triage.
//!
//! ## The rule that makes it hold
//!
//! A declaration nobody dispatches on drifts on the first pull request that adds
//! an action and forgets the table — and that is strictly worse than having no
//! capabilities API at all, because it turns "the page cannot tell" into "the
//! page is told something false". So:
//!
//! **An action name appears as a string literal exactly once, in the bridge's
//! action table, and the dispatch chain compares against that same constant.**
//!
//! One literal, two readers. `test/capabilities_test.zig` enforces it three
//! ways: every declared action must dispatch, no undeclared action may, and a
//! declared bridge's source may not contain a raw literal comparison at all.
//!
//! ## Honesty about coverage
//!
//! A namespace craft has not audited is reported `undeclared` rather than
//! guessed at. That is a real answer an app can act on — "craft will not claim
//! anything about this" — and it is deliberately uncomfortable, because the
//! ratchet in the conformance test only lets the number of them go down.

const std = @import("std");

/// Whether an action sends a reply the caller is waiting on.
///
/// Worth recording because the two failure modes look nothing alike from the
/// page: an action declared `.result` whose handler never replies leaves the
/// caller parked until the request timeout, while a `.none` action that a
/// caller awaits resolves immediately and means nothing.
pub const Reply = enum {
    /// Fire-and-forget: native acknowledges nothing.
    none,
    /// Native calls `sendResultToJS` under this action name.
    result,
};

pub const ActionStatus = enum {
    /// Dispatches, does the thing.
    live,
    /// Reachable, and known not to work. `reason` is required.
    unavailable,
};

pub const ActionDecl = struct {
    name: []const u8,
    reply: Reply = .result,
    status: ActionStatus = .live,
    /// Required when `status == .unavailable`, and shown to the app.
    reason: ?[]const u8 = null,
};

pub const NamespaceStatus = enum {
    /// Has an action table, and the conformance test enforces it.
    declared,
    /// Routed, but craft has not audited it and will not claim anything.
    undeclared,
    /// Every action is reachable and none of them work. `reason` is required.
    unavailable,
    /// Implemented natively but absent from the dispatch chain, so nothing can
    /// reach it. Distinct from `unavailable`: the code is there and works.
    unrouted,
};

pub const NamespaceDecl = struct {
    /// The `t` a message carries, e.g. "tray".
    name: []const u8,
    status: NamespaceStatus,
    actions: []const ActionDecl = &.{},
    reason: ?[]const u8 = null,
};

// =============================================================================
// Event channels
// =============================================================================

/// Every `craft:*` event the JS surface subscribes to.
///
/// Enumerated rather than derived, because the names follow no convention worth
/// deriving from: `craft:menu:action` is colon-separated and `craft:powerSleep`
/// is camel-cased, and both are load-bearing spellings a page already listens
/// for. Renaming them to be consistent would break every app.
///
/// `test/capabilities_test.zig` checks this list against every `_evt('craft:…')`
/// in `craft-bridge.js`. It shipped with 22 of the 44 and claimed to be
/// complete, which is the same overclaiming this whole mechanism exists to
/// stop — so now the claim is enforced.
pub const Channel = enum {
    bluetooth_deviceconnected,
    bluetooth_devicedisconnected,
    bluetooth_devicefound,
    bonjour_found,
    bonjour_lost,
    deeplink,
    filedrop,
    fs_change,
    handoff_incoming,
    iap_failed,
    iap_productsloaded,
    iap_purchased,
    iap_restored,
    localserver_request,
    location_authchanged,
    location_error,
    location_update,
    menu_action,
    menubar_statechange,
    midi_message,
    networkchange,
    notification_action,
    notification_click,
    powersleep,
    powerwake,
    screen_change,
    screensharing_change,
    serial_data,
    servicemenu_invoked,
    settings_open,
    shortcut,
    shortcut_error,
    speechrecognition_final,
    speechrecognition_partial,
    theme,
    touchbar_action,
    tray_menuaction,
    updateavailable,
    updatedownloaded,
    window_blur,
    window_close,
    window_focus,
    window_minimize,
    window_move,
    window_resize,
    window_restore,

    pub fn eventName(self: Channel) []const u8 {
        return switch (self) {
            .bluetooth_deviceconnected => "craft:bluetooth:deviceConnected",
            .bluetooth_devicedisconnected => "craft:bluetooth:deviceDisconnected",
            .bluetooth_devicefound => "craft:bluetooth:deviceFound",
            .bonjour_found => "craft:bonjour:found",
            .bonjour_lost => "craft:bonjour:lost",
            .deeplink => "craft:deepLink",
            .filedrop => "craft:fileDrop",
            .fs_change => "craft:fs:change",
            .handoff_incoming => "craft:handoff:incoming",
            .iap_failed => "craft:iap:failed",
            .iap_productsloaded => "craft:iap:productsLoaded",
            .iap_purchased => "craft:iap:purchased",
            .iap_restored => "craft:iap:restored",
            .localserver_request => "craft:localServer:request",
            .location_authchanged => "craft:location:authChanged",
            .location_error => "craft:location:error",
            .location_update => "craft:location:update",
            .menu_action => "craft:menu:action",
            .menubar_statechange => "craft:menubar:stateChange",
            .midi_message => "craft:midi:message",
            .networkchange => "craft:networkChange",
            .notification_action => "craft:notification:action",
            .notification_click => "craft:notification:click",
            .powersleep => "craft:powerSleep",
            .powerwake => "craft:powerWake",
            .screen_change => "craft:screen:change",
            .screensharing_change => "craft:screenSharing:change",
            .serial_data => "craft:serial:data",
            .servicemenu_invoked => "craft:serviceMenu:invoked",
            .settings_open => "craft:settings:open",
            .shortcut => "craft:shortcut",
            .shortcut_error => "craft:shortcut:error",
            .speechrecognition_final => "craft:speechRecognition:final",
            .speechrecognition_partial => "craft:speechRecognition:partial",
            .theme => "craft:theme",
            .touchbar_action => "craft:touchbar:action",
            .tray_menuaction => "craft:tray:menuAction",
            .updateavailable => "craft:updateAvailable",
            .updatedownloaded => "craft:updateDownloaded",
            .window_blur => "craft:window:blur",
            .window_close => "craft:window:close",
            .window_focus => "craft:window:focus",
            .window_minimize => "craft:window:minimize",
            .window_move => "craft:window:move",
            .window_resize => "craft:window:resize",
            .window_restore => "craft:window:restore",
        };
    }
};

const channel_count = std.enums.values(Channel).len;

/// Which channels something has claimed it emits on.
///
/// Set only by `registerEmitter`, so "this channel has a live emitter" cannot
/// be asserted by a table — it has to be earned by code that actually holds an
/// `Emitter`. A subsystem that is compiled out, or never initialised, never
/// marks its channel, and the manifest says so.
var live_channels = std.mem.zeroes([channel_count]bool);

/// A permit to dispatch on one channel.
///
/// Has no public initialiser other than `registerEmitter`: that is the whole
/// design. Sixteen of craft's forty-two event subscriptions have no emitter
/// anywhere, and no table derived from dispatch actions could ever have shown
/// that.
pub const Emitter = struct {
    channel: Channel,

    pub fn eventName(self: Emitter) []const u8 {
        return self.channel.eventName();
    }
};

/// Claim a channel and get the permit to emit on it.
pub fn registerEmitter(channel: Channel) Emitter {
    live_channels[@backingInt(channel)] = true;
    return .{ .channel = channel };
}

/// What craft can honestly say about a channel.
///
/// There is no `dead`. A source scan cannot establish absence: `craft:window:*`
/// names are composed in JavaScript from `__craftDeliverWindowEvent('focus')`,
/// so no Zig file contains the literal even though the emitter is right there.
/// The shipped version reported a bare `false` for anything unregistered, which
/// a page reasonably reads as "this will never fire" — and 21 of 22 channels
/// said it, including `craft:menu:action` and `craft:theme`, both of which work.
pub const Liveness = enum {
    /// Something in this build took out a permit to emit on it.
    live,
    /// Craft cannot prove it either way. Subscribe and see; do not disable a
    /// feature over it.
    unknown,

    pub fn text(self: Liveness) []const u8 {
        return switch (self) {
            .live => "live",
            .unknown => "unknown",
        };
    }
};

pub fn liveness(channel: Channel) Liveness {
    return if (live_channels[@backingInt(channel)]) .live else .unknown;
}

pub fn isLive(channel: Channel) bool {
    return live_channels[@backingInt(channel)];
}

/// Forget every registration. Tests only — the process otherwise only ever
/// gains emitters.
pub fn resetEmittersForTesting() void {
    live_channels = std.mem.zeroes([channel_count]bool);
}

// =============================================================================
// The manifest
// =============================================================================

fn appendEscaped(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    // Every string here is a compile-time constant from this file, so this is
    // belt and braces rather than a security boundary — but a reason string
    // with an apostrophe in it should not be able to produce broken JSON.
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
            var hex: [6]u8 = undefined;
            try out.appendSlice(gpa, try std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}));
        },
        else => try out.append(gpa, c),
    };
}

fn appendReason(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), reason: ?[]const u8) !void {
    if (reason) |r| {
        try out.appendSlice(gpa, ",\"reason\":\"");
        try appendEscaped(gpa, out, r);
        try out.appendSlice(gpa, "\"");
    }
}

/// Render the whole manifest as JSON.
///
/// Built at call time from the registry and the live-emitter set rather than
/// cached: an emitter can register after the page loads (a subsystem that only
/// initialises on first use), and a manifest that answered from a snapshot
/// would be exactly the stale-declaration problem this file exists to prevent.
pub fn buildManifest(gpa: std.mem.Allocator, registry: []const NamespaceDecl) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\"namespaces\":{");
    for (registry, 0..) |ns, index| {
        if (index > 0) try out.append(gpa, ',');
        try out.append(gpa, '"');
        try appendEscaped(gpa, &out, ns.name);
        try out.appendSlice(gpa, "\":{\"status\":\"");
        try out.appendSlice(gpa, @tagName(ns.status));
        try out.append(gpa, '"');
        try appendReason(gpa, &out, ns.reason);

        if (ns.actions.len > 0) {
            try out.appendSlice(gpa, ",\"actions\":{");
            for (ns.actions, 0..) |action, action_index| {
                if (action_index > 0) try out.append(gpa, ',');
                try out.append(gpa, '"');
                try appendEscaped(gpa, &out, action.name);
                try out.appendSlice(gpa, "\":{\"status\":\"");
                try out.appendSlice(gpa, @tagName(action.status));
                try out.appendSlice(gpa, "\",\"reply\":\"");
                try out.appendSlice(gpa, @tagName(action.reply));
                try out.append(gpa, '"');
                try appendReason(gpa, &out, action.reason);
                try out.append(gpa, '}');
            }
            try out.append(gpa, '}');
        }
        try out.append(gpa, '}');
    }

    try out.appendSlice(gpa, "},\"channels\":{");
    inline for (std.enums.values(Channel), 0..) |channel, index| {
        if (index > 0) try out.append(gpa, ',');
        try out.append(gpa, '"');
        try appendEscaped(gpa, &out, channel.eventName());
        try out.appendSlice(gpa, "\":\"");
        try out.appendSlice(gpa, liveness(channel).text());
        try out.append(gpa, '"');
    }
    try out.appendSlice(gpa, "}}");

    return out.toOwnedSlice(gpa);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "a channel has no emitter until something registers one" {
    resetEmittersForTesting();
    defer resetEmittersForTesting();

    try testing.expect(!isLive(.fs_change));
    const emitter = registerEmitter(.fs_change);
    try testing.expect(isLive(.fs_change));
    try testing.expectEqualStrings("craft:fs:change", emitter.eventName());

    // Registering one channel says nothing about any other.
    try testing.expect(!isLive(.powersleep));
}

test "every channel has a distinct event name" {
    // A duplicate would make one of the two silently unreportable: the manifest
    // is keyed by event name, so the second would overwrite the first.
    //
    // Runtime rather than `inline for`: at 44 channels the nested comptime loop
    // exceeds Zig's backwards-branch budget.
    const all = std.enums.values(Channel);
    var names: [all.len][]const u8 = undefined;
    for (all, 0..) |ch, i| names[i] = ch.eventName();
    for (names, 0..) |a, i| {
        for (names[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
}

test "every channel name is a craft: event" {
    inline for (std.enums.values(Channel)) |channel| {
        try testing.expect(std.mem.startsWith(u8, channel.eventName(), "craft:"));
    }
}

test "the manifest reports a declared namespace with its actions" {
    resetEmittersForTesting();
    defer resetEmittersForTesting();

    const registry = [_]NamespaceDecl{.{
        .name = "clipboard",
        .status = .declared,
        .actions = &.{
            .{ .name = "readText", .reply = .result },
            .{ .name = "writeText", .reply = .none },
        },
    }};

    const json = try buildManifest(testing.allocator, &registry);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const clipboard = parsed.value.object.get("namespaces").?.object.get("clipboard").?.object;
    try testing.expectEqualStrings("declared", clipboard.get("status").?.string);
    const actions = clipboard.get("actions").?.object;
    try testing.expectEqualStrings("live", actions.get("readText").?.object.get("status").?.string);
    try testing.expectEqualStrings("result", actions.get("readText").?.object.get("reply").?.string);
    try testing.expectEqualStrings("none", actions.get("writeText").?.object.get("reply").?.string);
}

test "an unavailable surface carries the reason with it" {
    // The reason is the whole value of declaring it: "updater is unavailable"
    // sends an app looking for a bug in its own code, "Sparkle framework not
    // linked" does not.
    const registry = [_]NamespaceDecl{.{
        .name = "updater",
        .status = .unavailable,
        .reason = "Sparkle framework is not linked into this build",
        .actions = &.{
            .{ .name = "checkForUpdates", .status = .unavailable, .reason = "Sparkle framework is not linked into this build" },
        },
    }};

    const json = try buildManifest(testing.allocator, &registry);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const updater = parsed.value.object.get("namespaces").?.object.get("updater").?.object;
    try testing.expectEqualStrings("unavailable", updater.get("status").?.string);
    try testing.expectEqualStrings("Sparkle framework is not linked into this build", updater.get("reason").?.string);
    try testing.expectEqualStrings(
        "Sparkle framework is not linked into this build",
        updater.get("actions").?.object.get("checkForUpdates").?.object.get("reason").?.string,
    );
}

test "an undeclared namespace claims nothing rather than claiming everything" {
    // The honest answer for a namespace craft has not audited. It must not
    // look like `declared` with an empty action list, which an app would read
    // as "this namespace has no actions".
    const registry = [_]NamespaceDecl{.{ .name = "midi", .status = .undeclared }};

    const json = try buildManifest(testing.allocator, &registry);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const midi = parsed.value.object.get("namespaces").?.object.get("midi").?.object;
    try testing.expectEqualStrings("undeclared", midi.get("status").?.string);
    try testing.expect(midi.get("actions") == null);
}

test "the manifest reports every channel, live or not" {
    resetEmittersForTesting();
    defer resetEmittersForTesting();
    _ = registerEmitter(.menu_action);

    const json = try buildManifest(testing.allocator, &.{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const channels = parsed.value.object.get("channels").?.object;

    // Every channel is present — a dead one has to be reported as dead, not
    // omitted, or an app cannot tell "no emitter" from "channel I misspelled".
    try testing.expectEqual(@as(usize, channel_count), channels.count());
    try testing.expectEqualStrings("live", channels.get("craft:menu:action").?.string);
    // Not "dead" — craft cannot prove a channel has no emitter, and saying so
    // is what made the shipped manifest tell pages to disable working features.
    try testing.expectEqualStrings("unknown", channels.get("craft:fs:change").?.string);
}

test "a reason cannot break the manifest out of its JSON" {
    const registry = [_]NamespaceDecl{.{
        .name = "x",
        .status = .unavailable,
        .reason = "has a \" and a \\ and a \n newline",
    }};
    const json = try buildManifest(testing.allocator, &registry);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "has a \" and a \\ and a \n newline",
        parsed.value.object.get("namespaces").?.object.get("x").?.object.get("reason").?.string,
    );
}

test "an empty registry is still valid JSON" {
    const json = try buildManifest(testing.allocator, &.{});
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("namespaces").?.object.count());
}
