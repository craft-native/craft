//! Which URLs `shell.openExternal` hands to the operating system.
//!
//! This is the app-facing half of the policy `external_link.zig` describes.
//! There a *page* asks, on behalf of whoever wrote its content, and gets
//! `http` and `https` and nothing else. Here the app's own code asks, about a
//! URL it chose, so the list is wider — but it is still a list. The call ends
//! in `NSWorkspace openURL:` (or `xdg-open`, or `start`), which means "do
//! whatever this URL means on this machine", and an open-ended scheme set
//! makes every installed handler reachable from one bridge call.
//!
//! What is allowed, and why each entry is here:
//!
//!   - `http`, `https`: the browser. The reason the call exists.
//!   - `file`: a path the app picked, opened by its default handler. Pages do
//!     not get this (see `external_link.zig`); the app does.
//!   - `mailto`: compose a message in the default mail client. Nothing runs
//!     and nothing is sent without the person pressing Send.
//!   - `x-apple.systempreferences` (macOS only): a System Settings pane. It is
//!     the documented way to send someone to the switch an app needs flipped,
//!     and it only ever opens a pane; it cannot change a setting.
//!
//! Everything else is refused, and the refusal is reported to the caller:
//! `javascript:` and `data:` are not the system's to open at all, and other
//! custom schemes (`ssh:`, `vnc:`, `smb:`, app-registered ones) do things on
//! arrival that the caller of a function named "open external" did not
//! obviously ask for. An app that needs one of those can make that decision
//! explicitly with `shell.spawn`.

const std = @import("std");

pub const Decision = enum {
    /// Hand it to the operating system.
    open,
    /// Do nothing, and tell the caller so.
    refuse,
};

const Rule = struct {
    /// Lower-case, without the colon.
    scheme: []const u8,
    /// Whether the scheme must be followed by `//`. True for the hierarchical
    /// schemes, where `https:evil` is not a link anyone meant to write.
    slashes: bool,
    /// Whether the scheme exists only on macOS.
    macos_only: bool = false,
};

const rules = [_]Rule{
    .{ .scheme = "http", .slashes = true },
    .{ .scheme = "https", .slashes = true },
    .{ .scheme = "file", .slashes = true },
    .{ .scheme = "mailto", .slashes = false },
    .{ .scheme = "x-apple.systempreferences", .slashes = false, .macos_only = true },
};

/// Longest scheme in `rules`. A candidate longer than this cannot match, so it
/// is refused without being copied anywhere.
const max_scheme_len = blk: {
    var longest: usize = 0;
    for (rules) |rule| longest = @max(longest, rule.scheme.len);
    break :blk longest;
};

/// What to do with a URL the app asked to open, on the given operating system.
///
/// The operating system is a parameter rather than read from `builtin` so the
/// macOS-only entry can be tested from any host.
///
/// Only the scheme is examined, exactly as in `external_link.decide`: it is
/// the whole decision, and it is compared in full and without regard to case,
/// so neither `https-evil:` nor `JavaScript:` gets a different answer than its
/// plain spelling.
pub fn decide(url: []const u8, os: std.Target.Os.Tag) Decision {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return .refuse;
    const scheme = url[0..colon];
    if (scheme.len == 0 or scheme.len > max_scheme_len) return .refuse;

    // A control character anywhere is not part of any URL worth opening, and
    // on the platforms that hand the string to a launcher process it is one
    // more thing that should not arrive there.
    for (url) |c| {
        if (c < 0x20 or c == 0x7f) return .refuse;
    }

    for (rules) |rule| {
        if (!std.ascii.eqlIgnoreCase(scheme, rule.scheme)) continue;
        if (rule.macos_only and os != .macos) return .refuse;
        if (rule.slashes and !std.mem.startsWith(u8, url[colon + 1 ..], "//")) return .refuse;
        return .open;
    }
    return .refuse;
}

const testing = std.testing;

/// Every desktop the shell bridge runs on.
const desktops = [_]std.Target.Os.Tag{ .macos, .linux, .windows };

fn expectEverywhere(expected: Decision, url: []const u8) !void {
    for (desktops) |os| try testing.expectEqual(expected, decide(url, os));
}

test "web links open on every desktop" {
    try expectEverywhere(.open, "https://example.com/a");
    try expectEverywhere(.open, "http://example.com");
    try expectEverywhere(.open, "https://example.com:8443/a?b=c&d=e#f");
    try expectEverywhere(.open, "http://127.0.0.1:3000/callback");
}

test "a file URL opens, because the app chose the path" {
    // The opposite of `external_link.zig`, on purpose: there a page is asking.
    try expectEverywhere(.open, "file:///Users/someone/report.pdf");
}

test "a mail link opens the mail client" {
    try expectEverywhere(.open, "mailto:someone@example.com");
    try expectEverywhere(.open, "mailto:someone@example.com?subject=Hello%20there");
}

test "a System Settings pane opens on macOS" {
    for ([_][]const u8{
        "x-apple.systempreferences:com.apple.preference.security",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.wifi-settings-extension",
        "x-apple.systempreferences:com.apple.settings.Storage",
    }) |url| {
        try testing.expectEqual(Decision.open, decide(url, .macos));
    }
}

test "a System Settings URL means nothing off macOS and is refused there" {
    const url = "x-apple.systempreferences:com.apple.preference.security";
    try testing.expectEqual(Decision.refuse, decide(url, .linux));
    try testing.expectEqual(Decision.refuse, decide(url, .windows));
}

test "the scheme is matched without regard to case" {
    try expectEverywhere(.open, "HTTPS://example.com");
    try expectEverywhere(.open, "MailTo:someone@example.com");
    try testing.expectEqual(Decision.open, decide("X-Apple.SystemPreferences:com.apple.preference.security", .macos));
}

test "script and inline-data URLs are refused however they are spelled" {
    for ([_][]const u8{
        "javascript:alert(1)",
        "JavaScript:alert(1)",
        "JAVASCRIPT://example.com/%0aalert(1)",
        "data:text/html,<script>alert(1)</script>",
        "DATA:text/html;base64,PHNjcmlwdD4=",
        "vbscript:msgbox(1)",
        "blob:https://example.com/0000",
        "about:blank",
    }) |url| {
        try expectEverywhere(.refuse, url);
    }
}

test "other custom schemes do not reach installed apps" {
    for ([_][]const u8{
        "ftp://example.com",
        "smb://server/share",
        "vnc://host",
        "ssh://host",
        "tel:+15551234",
        "itms-apps://apps.apple.com/app/id1",
        "zoommtg://zoom.us/join?confno=1",
        "slack://open",
        "craft://whatever",
        "x-apple.systempreferences-evil:pane",
        "x-apple.reminder://",
    }) |url| {
        try expectEverywhere(.refuse, url);
    }
}

test "a scheme that merely starts with an allowed one is refused" {
    try expectEverywhere(.refuse, "https-evil://example.com");
    try expectEverywhere(.refuse, "httpx://example.com");
    try expectEverywhere(.refuse, "mailtox:someone@example.com");
    try expectEverywhere(.refuse, "filex:///etc/passwd");
}

test "a hierarchical scheme without its slashes is refused" {
    try expectEverywhere(.refuse, "https:example.com");
    try expectEverywhere(.refuse, "http:/example.com");
    try expectEverywhere(.refuse, "file:/etc/passwd");
    try expectEverywhere(.refuse, "https:");
}

test "something with no scheme goes nowhere" {
    try expectEverywhere(.refuse, "");
    try expectEverywhere(.refuse, "example.com");
    try expectEverywhere(.refuse, "//example.com");
    try expectEverywhere(.refuse, "/relative/path");
    try expectEverywhere(.refuse, ":no-scheme");
}

test "whitespace and control characters do not smuggle a URL through" {
    try expectEverywhere(.refuse, " https://example.com");
    try expectEverywhere(.refuse, "\thttps://example.com");
    try expectEverywhere(.refuse, "https://example.com/\nsecond-line");
    try expectEverywhere(.refuse, "https://example.com/\x00");
    try expectEverywhere(.refuse, "mailto:a@example.com\r\nBcc:b@example.com");
}

test "an absurdly long scheme is refused rather than truncated" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 'a');
    buf[255] = ':';
    try expectEverywhere(.refuse, &buf);
}
