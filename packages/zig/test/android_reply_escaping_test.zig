//! How the answer gets back, and the one character that stops it.
//!
//! Android replies to the page by building JavaScript source and handing it to
//! `WebView.evaluateJavascript`. Fifty-eight of those emissions interpolated a
//! Kotlin value straight into a single-quoted JavaScript string:
//!
//! ```kotlin
//! webView.evaluateJavascript(
//!     "window._craftDeleteEventReject && window._craftDeleteEventReject('${e.message}')", null)
//! ```
//!
//! An apostrophe in the value ends the string early, the script does not parse,
//! and `evaluateJavascript` runs *nothing*. Not the reject, not the resolve —
//! and because these promises are hand-built rather than made by
//! `_createCallback`, there is no timeout behind them. The page waits forever
//! with no console error, since the failure happens inside `evaluateJavascript`
//! where nothing is watching.
//!
//! It is reachable from the page, because Java puts the offending input in the
//! exception: `craft.calendar.delete("1'x")` throws `NumberFormatException: For
//! input string: "1'x"`, and that message is what gets interpolated.
//!
//! ## Why a scanner and not a review
//!
//! The fix is `JSONObject.quote`, which is mechanical — and that is exactly the
//! kind of fix that comes undone. The next reply path written by hand looks
//! like the fifty-eight that were there before it, reads naturally, compiles,
//! and works until someone types an apostrophe. So the rule is checked rather
//! than remembered.
//!
//! ## The rule
//!
//! No Kotlin template may contain the two characters `'$`. That is narrower
//! than "escape your JavaScript" and wider than the reply paths, and both are
//! deliberate: it is trivially decidable, it has no false positives in this
//! tree (every occurrence before this file existed was a JavaScript emission),
//! and a value quoted with `jsQuote` cannot produce it.

const std = @import("std");
const testing = std.testing;

/// Every Kotlin template in `packages/android/templates`, embedded rather than
/// read from disk so the test is hermetic.
///
/// All eight, not just the four that talk to the WebView today — a file that
/// starts emitting JavaScript should already be covered rather than needing
/// someone to notice.
///
/// The list is hand-written, and that is a real limit: a ninth template is not
/// scanned until it is added here. Generating the list from the directory was
/// tried and removed, because `zig build` caches build.zig's evaluation against
/// that file's contents — adding a template did not regenerate the list, and the
/// completeness check passed by reading stale data. A check that cannot fail is
/// worse than an acknowledged gap.
const templates = [_]Template{
    .{ .name = "CraftBridge.kt.template", .source = @embedFile("CraftBridge.kt.template") },
    .{ .name = "CraftBridgeExtensions.kt.template", .source = @embedFile("CraftBridgeExtensions.kt.template") },
    .{ .name = "CraftHealthConnect.kt.template", .source = @embedFile("CraftHealthConnect.kt.template") },
    .{ .name = "CraftHealthConnectStub.kt.template", .source = @embedFile("CraftHealthConnectStub.kt.template") },
    .{ .name = "CraftNative.kt.template", .source = @embedFile("CraftNative.kt.template") },
    .{ .name = "CraftWidgetProvider.kt.template", .source = @embedFile("CraftWidgetProvider.kt.template") },
    .{ .name = "LocationRecordingService.kt.template", .source = @embedFile("LocationRecordingService.kt.template") },
    .{ .name = "MainActivity.kt.template", .source = @embedFile("MainActivity.kt.template") },
};

const Template = struct {
    name: []const u8,
    source: []const u8,
};

/// The offset of the first Kotlin interpolation opening immediately inside a
/// single-quoted JavaScript string, or null if there is none.
fn firstUnquotedInterpolation(source: []const u8) ?usize {
    return std.mem.indexOf(u8, source, "'$");
}

fn sourceOf(name: []const u8) ?[]const u8 {
    for (templates) |template| {
        if (std.mem.eql(u8, template.name, name)) return template.source;
    }
    return null;
}

fn lineOf(source: []const u8, offset: usize) usize {
    return std.mem.count(u8, source[0..offset], "\n") + 1;
}

test "the scanner recognises the shape it exists to catch" {
    // Reading the guard below tells you nothing about whether it looks at
    // anything. Three of this repository's tests have passed for the wrong
    // reason and only deliberate mutation exposed them, so the scanner is
    // handed both answers here before it is trusted with the real files.
    try testing.expect(firstUnquotedInterpolation("f('${e.message}')") != null);
    try testing.expect(firstUnquotedInterpolation("f('$id')") != null);
    try testing.expect(firstUnquotedInterpolation("f({key: '$key'})") != null);

    // And the fix must read as clean, or the guard is unsatisfiable.
    try testing.expect(firstUnquotedInterpolation("f(${jsQuote(e.message)})") == null);
    try testing.expect(firstUnquotedInterpolation("f($json)") == null);
    try testing.expect(firstUnquotedInterpolation("window.$callback") == null);
}

test "no Kotlin template interpolates a value into a single-quoted JavaScript string" {
    for (templates) |template| {
        if (firstUnquotedInterpolation(template.source)) |offset| {
            const line = lineOf(template.source, offset);
            const start = if (std.mem.lastIndexOfScalar(u8, template.source[0..offset], '\n')) |nl|
                nl + 1
            else
                0;
            const excerpt = std.mem.trim(
                u8,
                std.mem.sliceTo(template.source[start..], '\n'),
                " \t\r",
            );
            std.debug.print(
                \\
                \\{s}:{d} interpolates a value into a single-quoted JavaScript string:
                \\
                \\    {s}
                \\
                \\An apostrophe in that value makes the emitted script a syntax error,
                \\`evaluateJavascript` runs nothing, and the page's promise never settles.
                \\Use `jsQuote(value)` — it supplies its own quotes, so the surrounding
                \\'...' comes out.
                \\
            , .{ template.name, line, excerpt });
            return error.UnquotedInterpolation;
        }
    }
}

test "the templates that answer the page are actually in the scanned set" {
    // A floor, not a count: `CraftBridge.kt` alone holds 119 of these. If this
    // drops to zero the embed has gone stale — pointing at the wrong file, or
    // at a file that no longer talks to the WebView — and the escaping guard
    // above would pass on bytes nobody replies with.
    var emissions: usize = 0;
    for (templates) |template| {
        emissions += std.mem.count(u8, template.source, "evaluateJavascript(");
    }
    try testing.expect(emissions >= 100);

    // And the fix is present rather than the sites merely being deleted.
    const bridge = sourceOf("CraftBridge.kt.template").?;
    try testing.expect(std.mem.count(u8, bridge, "jsQuote(") >= 50);

    // `Any?`, not `String?`. The call sites replaced string interpolation,
    // which accepts anything — `contactId` is a Long, `downloadId` is a Long,
    // `errString` is a CharSequence — and narrowing the parameter back makes
    // those three sites stop compiling. Nothing in CI compiles Kotlin, so this
    // is the only thing that would say so. See #163.
    try testing.expect(
        std.mem.indexOf(u8, bridge, "private fun jsQuote(value: Any?): String") != null,
    );
}
