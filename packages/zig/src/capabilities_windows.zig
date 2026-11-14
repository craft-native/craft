//! What the Windows backend can actually dispatch.
//!
//! `capability_registry.zig` describes the audited macOS dispatch chain. Its
//! `declared` rows are claims about that chain and nothing else, so on Windows a
//! page asking whether `haptics` exists was told "declared" and learned the truth
//! only by calling it and getting PLATFORM_NOT_SUPPORTED. This file is the
//! Windows answer to the same question.
//!
//! Every name here has an arm either in `invoke` (the three namespaces handled
//! before `handleDesktopAction`) or in `handleDesktopAction` itself. Keep this
//! list beside those arms: `capability_registry.zig` fails a test if the registry
//! declares a namespace this file does not list.

const std = @import("std");

/// Shown to the page for a `declared` namespace this backend cannot reach.
pub const demotion_reason = "the windows backend has no dispatcher arm for this namespace";

pub const routed = [_][]const u8{
    "app",
    "autoLaunch",
    "capabilities",
    "clipboard",
    "dialog",
    "fs",
    "log",
    "menu",
    "nativeUI",
    "notification",
    "permissions",
    "power",
    "screen",
    "serial",
    "shell",
    "shortcuts",
    "system",
    "timers",
    "tray",
    "window",
};

pub fn routes(name: []const u8) bool {
    return @import("capabilities.zig").isRouted(&routed, name);
}
