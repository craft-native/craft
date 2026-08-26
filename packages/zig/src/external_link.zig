//! Where a link that wants a new window is allowed to go.
//!
//! `window.open()` and `target="_blank"` ask WKWebView for a second webview.
//! Craft has nowhere to put one, so the request is answered by handing the URL
//! to the system browser and creating nothing — the convention Electron
//! settled on, and what a person clicking a link expects.
//!
//! Which URLs, though, is a security question rather than a routing one. The
//! page asking is not necessarily trusted: an app that renders a chat
//! transcript, a feed, or any third-party HTML is asking on behalf of whoever
//! wrote that content. `NSWorkspace openURL:` is not a browser call — it is
//! "ask LaunchServices to do whatever this URL means", and what it means is
//! decided by whatever is installed on the machine.
//!
//! So this allows exactly `http` and `https` and drops everything else:
//!
//!   - `file://` would hand LaunchServices a local path, which for a `.app`,
//!     a `.command`, or anything with a registered handler is a launch. The
//!     `shell.openExternal` bridge does allow `file://`, and should — the app
//!     itself is calling it, on a path it chose. This is a page calling it, on
//!     a URL nobody vetted, and the two do not deserve the same list.
//!   - Custom schemes reach any registered app: `x-apple.systempreferences:`
//!     opens System Settings panes, and every installed app that claims a
//!     scheme is one `window.open` away.
//!   - `javascript:` and `data:` are not the browser's to open at all.
//!
//! An app that genuinely wants a wider policy has `shell.openExternal`, where
//! its own code decides. That is the difference this file is drawing.

const std = @import("std");

pub const Decision = enum {
    /// Hand it to the system browser and create no webview.
    open_externally,
    /// Create nothing and go nowhere. Logged, never silent.
    drop,
};

/// The schemes a page may send to the system browser, lower-case and with the
/// colon, so a prefix match cannot accept `https-evil:`.
const allowed = [_][]const u8{ "http:", "https:" };

/// What to do with a URL a page asked to open in a new window.
///
/// Nothing here parses the URL beyond its scheme: the scheme is the whole
/// decision, and a parser that tried to do more would be a second place for
/// the two sides to disagree about what a URL is.
pub fn decide(url: []const u8) Decision {
    const scheme_end = std.mem.indexOfScalar(u8, url, ':') orelse return .drop;
    const scheme = url[0 .. scheme_end + 1];

    // A URL is not required to be short, but a scheme is: RFC 3986 gives no
    // limit, yet nothing legitimate is close, and this bounds the buffer.
    if (scheme.len > 16) return .drop;

    var lowered: [16]u8 = undefined;
    for (scheme, 0..) |c, i| lowered[i] = std.ascii.toLower(c);

    for (allowed) |ok| {
        if (std.mem.eql(u8, lowered[0..scheme.len], ok)) return .open_externally;
    }
    return .drop;
}

const testing = std.testing;

test "ordinary web links go to the browser" {
    try testing.expectEqual(Decision.open_externally, decide("https://example.com/a"));
    try testing.expectEqual(Decision.open_externally, decide("http://example.com"));
    try testing.expectEqual(Decision.open_externally, decide("https://example.com:8443/a?b=c#d"));
}

test "the scheme is matched without regard to case" {
    // `Https://` is a perfectly ordinary link, and a case-sensitive check is
    // also a bypass: the drop list would be trivially escaped by shifting one
    // letter.
    try testing.expectEqual(Decision.open_externally, decide("HTTPS://example.com"));
    try testing.expectEqual(Decision.open_externally, decide("HtTp://example.com"));
}

test "a file URL from a page is not opened" {
    // `shell.openExternal` allows these because the app is calling it about a
    // path it chose. A page is not the app.
    try testing.expectEqual(Decision.drop, decide("file:///Applications/Calculator.app"));
    try testing.expectEqual(Decision.drop, decide("FILE:///etc/passwd"));
}

test "script and inline-data URLs are not the browser's to open" {
    try testing.expectEqual(Decision.drop, decide("javascript:alert(1)"));
    try testing.expectEqual(Decision.drop, decide("JavaScript:alert(1)"));
    try testing.expectEqual(Decision.drop, decide("data:text/html,<script>alert(1)</script>"));
}

test "custom schemes cannot reach installed apps" {
    // Each of these is a real handler on a stock or common macOS install.
    for ([_][]const u8{
        "x-apple.systempreferences:com.apple.preference.security",
        "ftp://example.com",
        "smb://server/share",
        "vnc://host",
        "ssh://host",
        "itms-apps://apps.apple.com/app/id1",
        "zoommtg://zoom.us/join?confno=1",
        "slack://open",
        "craft://whatever",
        "mailto:someone@example.com",
        "tel:+15551234",
    }) |url| {
        try testing.expectEqual(Decision.drop, decide(url));
    }
}

test "a scheme that merely starts with an allowed one is not allowed" {
    // The colon is part of the match for this reason.
    try testing.expectEqual(Decision.drop, decide("https-evil://example.com"));
    try testing.expectEqual(Decision.drop, decide("httpx://example.com"));
    try testing.expectEqual(Decision.drop, decide("httpsx:"));
}

test "something with no scheme at all goes nowhere" {
    try testing.expectEqual(Decision.drop, decide(""));
    try testing.expectEqual(Decision.drop, decide("example.com"));
    try testing.expectEqual(Decision.drop, decide("//example.com"));
    try testing.expectEqual(Decision.drop, decide("/relative/path"));
}

test "a leading space does not smuggle a scheme past the check" {
    // WKWebView hands over an NSURL that has already been parsed, so this
    // should not arise — but the check must not be the reason it is safe.
    try testing.expectEqual(Decision.drop, decide(" https://example.com"));
    try testing.expectEqual(Decision.drop, decide("\thttps://example.com"));
    try testing.expectEqual(Decision.drop, decide("\nhttps://example.com"));
}

test "an absurdly long scheme is refused rather than truncated" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 'a');
    buf[63] = ':';
    try testing.expectEqual(Decision.drop, decide(&buf));
}

test "a bare scheme with nothing after it is still a web link" {
    // Degenerate, and NSWorkspace will do nothing useful with it, but it is
    // not this file's job to invent a second opinion about URL syntax.
    try testing.expectEqual(Decision.open_externally, decide("https:"));
}
