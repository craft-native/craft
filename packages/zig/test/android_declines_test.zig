//! Every way an Android native gives up has to say so.
//!
//! A native in `src/android_dispatch.zig` declines by returning `null` or
//! `JNI_FALSE`, and the Kotlin shim then serves the action itself. That hand-
//! back is by design and invisible to the page — which is also what made it
//! invisible to everyone else. `getDeviceInfo` ran on its first emulator
//! throwing
//!
//!     java.lang.NoSuchFieldError: no "J" field "longVersionCode" in class
//!       "Landroid/content/pm/PackageInfo;"
//!
//! on every call, and nothing noticed: the page got an answer, the suite
//! passed, and the only trace was one warning in logcat. About 170 other
//! failure paths did not even leave that — `catch return null`, `catch {}` —
//! so a JNI plumbing failure in any of them looked exactly like a native doing
//! its job.
//!
//! They go through three helpers now, each with a distinct message:
//! `fellThrough`, `failedWithoutFallback` and `undelivered`. The mobile E2E
//! runtime leg fails on any of those lines, which is what lets it claim Zig
//! *served* the calls it exercised rather than merely loaded.
//!
//! ## The rule
//!
//! No `catch` in the dispatcher may discard its error: a `catch` without a
//! `|capture|` whose handler is only `return`, `return null`,
//! `return jni.JNI_FALSE`, `null` or `{}` is a silent decline and fails this
//! test. The compiler already refuses an unused capture, so once the error is
//! captured it has to go somewhere.
//!
//! Two shapes stay allowed, deliberately:
//!
//! - `catch return .some_outcome` — returning an enum outcome that the caller
//!   reports. `bindNatives` does this and `JNI_OnLoad` logs every outcome.
//! - `catch { ... }` with a body — a handler that does something, like the
//!   `saveFile` path that rejects its promise with a specific message.
//!
//! Scoped to the dispatcher because that is where declines to Kotlin happen.
//! The bridge modules return errors with `try` and the dispatcher is what
//! turns them into a decline.

const std = @import("std");
const testing = std.testing;

const dispatch = @embedFile("android_dispatch.zig");

const Finding = struct {
    line: usize,
    text: []const u8,
};

/// The first silent decline in `source`, or null if there is none.
fn firstSilentCatch(source: []const u8) ?Finding {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        // Comments and multiline string lines describe code, they are not code.
        if (std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "\\\\")) continue;

        const code = withoutTrailingComment(raw);
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, code, search, "catch")) |at| {
            search = at + "catch".len;
            if (!isWordAt(code, at, "catch".len)) continue;

            const rest = std.mem.trimStart(u8, code[search..], " \t");
            if (isSilentHandler(rest)) return .{ .line = number, .text = trimmed };
        }
    }
    return null;
}

/// Whether what follows a `catch` discards the error without a capture.
fn isSilentHandler(rest: []const u8) bool {
    if (std.mem.startsWith(u8, rest, "|")) return false;

    if (std.mem.startsWith(u8, rest, "{}")) return true;
    if (std.mem.startsWith(u8, rest, "null")) return !continuesIdentifier(rest, "null".len);

    if (std.mem.startsWith(u8, rest, "return")) {
        if (continuesIdentifier(rest, "return".len)) return false;
        const value = std.mem.trimStart(u8, rest["return".len..], " \t");
        // An enum outcome the caller reports, like `bindNatives`.
        if (std.mem.startsWith(u8, value, ".")) return false;
        if (value.len == 0) return true;
        if (value[0] == ';' or value[0] == ',' or value[0] == ')') return true;
        if (std.mem.startsWith(u8, value, "null")) return !continuesIdentifier(value, "null".len);
        if (std.mem.startsWith(u8, value, "jni.JNI_FALSE")) return !continuesIdentifier(value, "jni.JNI_FALSE".len);
    }
    return false;
}

fn continuesIdentifier(text: []const u8, len: usize) bool {
    if (text.len <= len) return false;
    const c = text[len];
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isWordAt(text: []const u8, at: usize, len: usize) bool {
    const before_ok = at == 0 or !(std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '_');
    return before_ok and !continuesIdentifier(text[at..], len);
}

/// `line` up to a `//` that is not inside a string literal.
///
/// URLs are why this is not `indexOf("//")`: the dispatcher builds
/// `https://` strings, and cutting there would hide any `catch` after one.
fn withoutTrailingComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
        } else if (c == '"') {
            in_string = true;
        } else if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            return line[0..i];
        }
    }
    return line;
}

test "the scanner recognises every silent shape the dispatcher used to have" {
    // Handed both answers before it is trusted with the real file: a scanner
    // that finds nothing proves nothing until it has been shown to find
    // something.
    const silent = [_][]const u8{
        "    const text = j.stringToUtf8(allocator, value) catch return jni.JNI_FALSE;",
        "    const s = foo() catch return null;",
        "    return j.newStringUtf8(allocator, json) catch null;",
        "    events.settle(allocator, global, payload) catch {};",
        "    const text = j.stringToUtf8(allocator, message) catch return;",
        "        .latitude = json_number.fromDouble(j, allocator, latitude) catch return,",
        "    const call = (dbCall(j, allocator, sql) catch return jni.JNI_FALSE) orelse",
        "    const x = (render(allocator) catch return null) orelse",
        "        j.staticMethodId(holder, \"x\", \"()V\") catch return jni.JNI_FALSE,",
    };
    for (silent) |line| {
        if (firstSilentCatch(line) == null) {
            std.debug.print("\nthe scanner missed a silent decline:\n    {s}\n", .{line});
            return error.ScannerMissedSilentCatch;
        }
    }

    const fine = [_][]const u8{
        "    const text = j.stringToUtf8(allocator, value) catch |err| return fellThrough(\"log\", err, jni.JNI_FALSE);",
        "    events.settle(allocator, global, payload) catch |err| undelivered(\"reviewError\", err);",
        "    const cls = j.findClass(holder_class) catch return .class_not_found;",
        "    const plan = files.planFor(data_text) catch {",
        "    // `catch return null` used to be everywhere",
        "    const url = \"https://example.com\"; // catch {} in a comment",
        "    const nullable = returnValue() catch |e| nullOr(e);",
    };
    for (fine) |line| {
        if (firstSilentCatch(line)) |finding| {
            std.debug.print("\nthe scanner flagged a handled catch:\n    {s}\n", .{finding.text});
            return error.ScannerFlaggedHandledCatch;
        }
    }
}

test "no native in the Android dispatcher declines without saying so" {
    if (firstSilentCatch(dispatch)) |finding| {
        std.debug.print(
            \\
            \\src/android_dispatch.zig:{d} declines without saying so:
            \\
            \\    {s}
            \\
            \\A native that gives up here hands the action back to the Kotlin shim
            \\(or, from a callback, drops it) with nothing in logcat — the page still
            \\gets an answer, so the failure is invisible. Capture the error and route
            \\it through `fellThrough`, `failedWithoutFallback` or `undelivered`.
            \\
        , .{ finding.line, finding.text });
        return error.SilentDecline;
    }
}

test "the three decline messages are the ones the E2E suite looks for" {
    // scripts/mobile-e2e/android.ts fails its runtime leg on these phrases. If
    // a helper's wording drifted, the suite would stop seeing declines and pass
    // on a runtime that was handing every call to Kotlin.
    for ([_][]const u8{
        " fell through to the shim (",
        " failed with no fallback (",
        " could not reach the page (",
    }) |phrase| {
        if (std.mem.indexOf(u8, dispatch, phrase) == null) {
            std.debug.print("\nandroid_dispatch.zig no longer contains \"{s}\"\n", .{phrase});
            return error.DeclinePhraseMissing;
        }
    }
}
