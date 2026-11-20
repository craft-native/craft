//! Every namespace the bridge routes, and what craft is willing to claim about it.
//!
//! One row per `t` value in the live dispatch chain in `macos.zig`, which is
//! checked: `test/capabilities_test.zig` fails if the chain gains an arm this
//! file does not list, or lists one the chain does not have.
//!
//! ## Why most rows say `undeclared`
//!
//! Declaring a namespace means refactoring its dispatch chain so the action
//! names live in exactly one place, and that is a mechanical change across
//! every bridge — around 279 action names in 47 files. Landing all of it beside
//! a new public API would produce a diff reviewable only by trusting the
//! compiler.
//!
//! So a namespace craft has not audited answers `undeclared`, which is a real
//! answer an app can act on: craft will not claim anything about it. It is
//! deliberately uncomfortable, and the conformance test holds a ceiling on how
//! many there may be that only ever goes down.

pub const capabilities = @import("capabilities.zig");
const bridge_app = @import("bridge_app.zig");
const bridge_capabilities = @import("bridge_capabilities.zig");
const bridge_clipboard = @import("bridge_clipboard.zig");
const bridge_haptics = @import("bridge_haptics.zig");
const bridge_screen = @import("bridge_screen.zig");
const bridge_timers = @import("bridge_timers.zig");
const bridge_tray = @import("bridge_tray.zig");

pub const registry = [_]capabilities.NamespaceDecl{
    // Implemented and unreachable: bridge_marketplace.zig dispatches eleven
    // actions, and no arm in the dispatch chain routes `marketplace` to it, so
    // no message can arrive. Listed precisely because it is not routed — the
    // alternative is that it stays invisible, which is how it got this way.
    .{
        .name = "marketplace",
        .status = .unrouted,
        .reason = "implemented but not routed: no dispatcher arm sends messages to it",
    },
    .{ .name = "app", .status = .declared, .actions = &bridge_app.capability_actions },
    .{ .name = "appleScript", .status = .undeclared },
    .{ .name = "audio", .status = .undeclared },
    .{ .name = "autoLaunch", .status = .undeclared },
    .{ .name = "biometric", .status = .undeclared },
    .{ .name = "bluetooth", .status = .undeclared },
    .{ .name = "bonjour", .status = .undeclared },
    // The introspection namespace itself, so a page can tell "craft is too old
    // to have capabilities" from "capabilities says this is missing".
    .{ .name = "capabilities", .status = .declared, .actions = &bridge_capabilities.capability_actions },
    .{ .name = "clipboard", .status = .declared, .actions = &bridge_clipboard.capability_actions },
    .{ .name = "continuityCamera", .status = .undeclared },
    .{ .name = "coreml", .status = .undeclared },
    .{ .name = "crashReporter", .status = .undeclared },
    .{ .name = "dialog", .status = .undeclared },
    .{ .name = "dragOut", .status = .undeclared },
    .{ .name = "fileAssociations", .status = .undeclared },
    .{ .name = "focus", .status = .undeclared },
    .{ .name = "fs", .status = .undeclared },
    .{ .name = "handoff", .status = .undeclared },
    // Declared from its first commit rather than retrofitted: the trackpad
    // half of the haptics API the phones already serve.
    .{ .name = "haptics", .status = .declared, .actions = &bridge_haptics.capability_actions },
    .{ .name = "iap", .status = .undeclared },
    .{ .name = "keychain", .status = .undeclared },
    .{ .name = "localServer", .status = .undeclared },
    .{ .name = "location", .status = .undeclared },
    .{ .name = "log", .status = .undeclared },
    .{ .name = "menu", .status = .undeclared },
    .{ .name = "menubarCollapse", .status = .undeclared },
    .{ .name = "midi", .status = .undeclared },
    .{ .name = "nativeUI", .status = .undeclared },
    .{ .name = "network", .status = .undeclared },
    .{ .name = "notification", .status = .undeclared },
    .{ .name = "pdf", .status = .undeclared },
    .{ .name = "permissions", .status = .undeclared },
    .{ .name = "power", .status = .undeclared },
    // Landed after this registry was written, and the conformance test caught
    // it — which is the mechanism doing its job on a real integration rather
    // than on a contrived one. A good stage-1 candidate: its action names are
    // already centralised in bridge_prefs_actions.zig.
    .{ .name = "prefs", .status = .undeclared },
    .{ .name = "printing", .status = .undeclared },
    .{ .name = "screen", .status = .declared, .actions = &bridge_screen.capability_actions },
    .{ .name = "screenCapture", .status = .undeclared },
    .{ .name = "screenSharing", .status = .undeclared },
    .{ .name = "serial", .status = .undeclared },
    .{ .name = "serviceMenu", .status = .undeclared },
    .{ .name = "shell", .status = .undeclared },
    .{ .name = "shortcuts", .status = .undeclared },
    .{ .name = "speech", .status = .undeclared },
    .{ .name = "speechRecognition", .status = .undeclared },
    .{ .name = "spotlight", .status = .undeclared },
    .{ .name = "system", .status = .undeclared },
    .{ .name = "tags", .status = .undeclared },
    .{ .name = "timers", .status = .declared, .actions = &bridge_timers.capability_actions },
    .{ .name = "touchbar", .status = .undeclared },
    .{ .name = "tray", .status = .declared, .actions = &bridge_tray.capability_actions },
    .{ .name = "updater", .status = .unavailable, .reason = "the Sparkle framework is not linked into this build, so every updater call reaches a null SUUpdater" },
    .{ .name = "vision", .status = .undeclared },
    .{ .name = "window", .status = .undeclared },
};

/// Rendered for `craft.capabilities()`. Caller frees.
///
/// This registry describes the audited macOS dispatch chain, so on Windows the
/// rendered manifest is filtered through that backend's routed set: a
/// `declared` namespace Windows cannot dispatch has nothing to promise there.
pub fn manifestJson(gpa: @import("std").mem.Allocator) ![]u8 {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) {
        const windows_backend = @import("capabilities_windows.zig");
        return capabilities.buildManifestFor(gpa, &registry, &windows_backend.routed, windows_backend.demotion_reason);
    }
    return capabilities.buildManifest(gpa, &registry);
}

test "the windows manifest demotes a declared namespace this backend cannot dispatch" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const std = @import("std");
    const windows_backend = @import("capabilities_windows.zig");

    const json = try manifestJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const spaces = parsed.value.object.get("namespaces") orelse return error.MissingNamespaces;
    const namespaces = spaces.object;

    // The failure this guards against: the registry gains a `declared` row (and
    // the macOS chain gains its arm) while nothing here can reach it. The
    // manifest would promise the surface on Windows and the first call would
    // answer PLATFORM_NOT_SUPPORTED -- which is what `haptics` did before this
    // filter existed.
    var demoted: usize = 0;
    for (registry) |ns| {
        if (ns.status != .declared) continue;
        const entry = (namespaces.get(ns.name) orelse return error.MissingNamespace).object;
        const status = (entry.get("status") orelse return error.MissingStatus).string;
        if (windows_backend.routes(ns.name)) {
            // Reachable here, so the claim and its action table both survive.
            try std.testing.expectEqualStrings("declared", status);
            try std.testing.expect(entry.get("actions") != null);
        } else {
            // Not reachable, so it keeps neither the claim nor the names of
            // actions that belong to the chain that does have the arm.
            try std.testing.expectEqualStrings("unavailable", status);
            try std.testing.expectEqualStrings(windows_backend.demotion_reason, (entry.get("reason") orelse return error.MissingReason).string);
            try std.testing.expect(entry.get("actions") == null);
            demoted += 1;
        }
    }
    // The demotion has to be doing work; `haptics` alone makes it non-vacuous.
    try std.testing.expect(demoted >= 1);
}
