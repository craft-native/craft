//! Every window craft opens must be reopenable.
//!
//! This test exists because of a bug that nothing else could have caught.
//! `isCraftWindow` decided whether a window was craft's by asking whether its
//! content view was a `WKWebView`. That is true of the plain window and false
//! of the other three: `--web-sidebar-material` installs a backdrop container,
//! `createWindowWithSidebar` sets a split view controller, and
//! `createWindowWithSidebarURL` installs its own container. All three keep
//! their closed window alive, so the reopen handler found them, skipped them,
//! and left the app activated with nothing on screen — the exact dead end the
//! handler was added to remove.
//!
//! It compiled. Every test passed. It failed only against a real
//! `kAEReopenApplication` on a window style no test constructs, and **no test
//! in this repository constructs a window at all**.
//!
//! ## Why this is a source test
//!
//! Constructing a window means a live `NSApplication`, a `WKWebView` and the
//! WebContent process behind it — heavy, and flaky on a runner with no
//! display. The properties worth defending do not need any of that:
//!
//!   1. every window constructor registers its window, and
//!   2. nothing infers craft-ness from the window's appearance again.
//!
//! Both are properties of the source, and they are only checkable *because*
//! the fix replaced an inference with a registration. "Does this window look
//! like ours?" can only be answered by holding a window. "Did every
//! constructor register?" can be answered by reading. Making the property
//! checkable was worth as much as fixing the bug.
//!
//! Each check carries a floor, because a scan that finds nothing passes
//! vacuously, and a vacuous pass is how this class of bug returns.

const std = @import("std");
const testing = std.testing;

const macos_source = @embedFile("src/macos.zig");

/// The Objective-C initialiser every `NSWindow` in craft goes through.
const window_init = "initWithContentRect:styleMask:backing:defer:";

/// What a constructor must call on the window it just made.
const register_call = "keepWindowAfterClose(";

/// Whether `body` really calls `needle`, ignoring commented-out occurrences.
///
/// Substring matching alone cannot tell a call from a mention. Commenting a
/// registration out would leave the text in place and satisfy a naive scan —
/// which is exactly how this check was first found to be toothless, by
/// commenting one out and watching it pass.
fn callsFunction(body: []const u8, needle: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, body, search, needle)) |hit| {
        search = hit + needle.len;
        const start = lineStart(body, hit);
        const before = std.mem.trimStart(u8, body[start..hit], " \t");
        // `//` anywhere before it on the line makes it a comment, and `///`
        // makes it documentation.
        if (std.mem.startsWith(u8, before, "//")) continue;
        if (std.mem.indexOf(u8, body[start..hit], "//") != null) continue;
        return true;
    }
    return false;
}

/// Start of the line containing `needle`.
fn lineStart(source: []const u8, at: usize) usize {
    var i = at;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

/// The `fn` declaration enclosing byte `at`.
///
/// Zig indents declarations at column zero inside a file, so the nearest
/// preceding line beginning with `fn ` or `pub fn ` is the enclosing
/// top-level function. Container-level methods are indented and belong to a
/// struct whose own declaration is found the same way.
fn enclosingFn(source: []const u8, at: usize) ?[]const u8 {
    var i = lineStart(source, at);
    while (true) {
        const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        const line = source[i..line_end];
        if (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "pub fn ")) return line;
        if (i == 0) return null;
        i = lineStart(source, i - 1);
    }
}

/// Byte range of the function body enclosing `at`, from its `fn` line to the
/// next top-level `fn` line (or end of file).
fn enclosingFnBody(source: []const u8, at: usize) []const u8 {
    var start = lineStart(source, at);
    while (start > 0) {
        const line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..line_end];
        if (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "pub fn ")) break;
        start = lineStart(source, start - 1);
    }

    var end = at;
    while (end < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, end, '\n') orelse source.len;
        const line = source[end..line_end];
        if (end != start and (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "pub fn "))) break;
        if (line_end >= source.len) {
            end = source.len;
            break;
        }
        end = line_end + 1;
    }
    return source[start..end];
}

test "every window craft constructs is registered as one of its own" {
    // The check that would have caught the bug this file exists for — had the
    // answer been recorded rather than inferred. It is recorded now, so this
    // is the property that keeps it recorded.
    var constructors: usize = 0;
    var unregistered: usize = 0;

    var search: usize = 0;
    while (std.mem.indexOfPos(u8, macos_source, search, window_init)) |hit| {
        search = hit + window_init.len;

        // The name is mentioned in prose as well as called. Only a real
        // `msgSend4(...)` call constructs a window.
        const line = macos_source[lineStart(macos_source, hit)..hit];
        if (std.mem.indexOf(u8, line, "msgSend4") == null) continue;

        constructors += 1;
        const body = enclosingFnBody(macos_source, hit);
        if (!callsFunction(body, register_call)) {
            unregistered += 1;
            const name = enclosingFn(macos_source, hit) orelse "(unknown)";
            std.debug.print(
                "\nwindow constructor does not call {s}: {s}\n",
                .{ register_call, name },
            );
        }
    }

    // Floor: craft has three window constructors. If a refactor renames the
    // initialiser this scan finds none and would otherwise pass having checked
    // nothing at all.
    try testing.expect(constructors >= 3);
    try testing.expectEqual(@as(usize, 0), unregistered);
}

test "whether a window is craft's is recorded, never inferred from the window" {
    // The specific regression. `isCraftWindow` asked the window what its
    // content view was; three of craft's four window styles answer with a
    // container rather than the webview, so those windows were silently
    // skipped by reopen.
    //
    // Any re-introduction reads the window instead of the registry, and every
    // way of doing that goes through one of these.
    const start = std.mem.indexOf(u8, macos_source, "fn isCraftWindow(") orelse {
        // Renamed or removed: this test can no longer defend anything and must
        // say so rather than pass.
        return error.IsCraftWindowNotFound;
    };
    const body = enclosingFnBody(macos_source, start);

    for ([_][]const u8{
        "contentView",
        "isKindOfClass:",
        "contentViewController",
        "subviews",
    }) |inference| {
        if (std.mem.indexOf(u8, body, inference) != null) {
            std.debug.print("\nisCraftWindow inspects the window ({s}) instead of the registry\n", .{inference});
            return error.WindowIdentityInferred;
        }
    }

    // And it must actually consult the registry, rather than being stubbed to
    // a constant that passes the check above.
    try testing.expect(callsFunction(body, "window_registry.isKnown"));
}

test "the reopen handler filters by that answer" {
    // Registration is worth nothing if the reopen loop stops asking. This
    // pins the one place the two meet.
    const start = std.mem.indexOf(u8, macos_source, "fn appShouldHandleReopen(") orelse
        return error.ReopenHandlerNotFound;
    const body = enclosingFnBody(macos_source, start);

    try testing.expect(callsFunction(body, "isCraftWindow("));
    try testing.expect(callsFunction(body, "makeKeyAndOrderFront:"));
}

test "a closed window survives long enough to be reopened" {
    // `releasedWhenClosed` defaults to YES for a window built with
    // `initWithContentRect:`, so without this the window is deallocated on
    // close and reopening it is a use-after-free rather than a missing
    // feature. It is set in the same helper that registers, so that a
    // constructor cannot get one without the other.
    const start = std.mem.indexOf(u8, macos_source, "fn keepWindowAfterClose(") orelse
        return error.HelperNotFound;
    const body = enclosingFnBody(macos_source, start);

    try testing.expect(callsFunction(body, "setReleasedWhenClosed:"));
    try testing.expect(callsFunction(body, "rememberCraftWindow("));
}

test "the scan can actually find the constructors it claims to check" {
    // Guards the guard: every test above depends on `enclosingFnBody` locating
    // real function bodies. If the file's formatting changes such that it
    // returns the whole file, the checks above pass regardless of the code.
    const start = std.mem.indexOf(u8, macos_source, "fn isCraftWindow(").?;
    const body = enclosingFnBody(macos_source, start);

    try testing.expect(body.len > 0);
    // A body that large means the scan lost its bearings and every check above
    // is now looking at unrelated code.
    try testing.expect(body.len < macos_source.len / 10);
    try testing.expect(std.mem.startsWith(u8, body, "fn isCraftWindow("));
}

test "a commented-out call does not count as a call" {
    // The weakness that made the constructor check toothless: substring
    // matching cannot tell a call from a mention, so commenting a registration
    // out satisfied it. Found by doing exactly that and watching the test pass.
    try testing.expect(callsFunction("    keepWindowAfterClose(window);", "keepWindowAfterClose("));
    try testing.expect(!callsFunction("    // keepWindowAfterClose(window);", "keepWindowAfterClose("));
    try testing.expect(!callsFunction("    /// keepWindowAfterClose(window);", "keepWindowAfterClose("));
    try testing.expect(!callsFunction("    _ = x; // keepWindowAfterClose(window);", "keepWindowAfterClose("));
    // A real call on a line that also carries a trailing comment still counts.
    try testing.expect(callsFunction("    keepWindowAfterClose(window); // why", "keepWindowAfterClose("));
}
