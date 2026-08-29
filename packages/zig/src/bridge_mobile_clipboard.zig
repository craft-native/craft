//! The clipboard actions of the `mobile` namespace: `clipboardRead`,
//! `clipboardWrite`.
//!
//! Ported from the two inline arms in `CraftApp.swift`'s dispatcher. The Swift
//! is eleven lines, and three of its behaviours are deliberately not carried
//! across:
//!
//! 1. **It can leave the caller waiting forever.** Both arms are an `if` with
//!    no `else`, and clipboard is one of the few actions whose promise is built
//!    inline instead of through `_createCallback` — which is the only thing
//!    that installs the 30-second rejection. So a false `enableClipboard`, or a
//!    `text` that is not a string, replies with nothing at all: not resolved,
//!    not rejected, ever. Every path in this file ends in a reply or an error.
//! 2. **`UIPasteboard.string ?? ""` conflates three different facts.** See
//!    `readClipboard`.
//! 3. **It reports success for a write it never checked.** See `putString`.
//!
//! ## The payload moved, and defaulting it would erase the clipboard
//!
//! The Swift-injected `window.craft` posts `text` at the *top level*, a sibling
//! of `action`. `ios_dispatch` never looks there — it hands a namespace only
//! the stringified `d`. A page still posting the flat legacy shape therefore
//! arrives here with `d` absent, which `payloadOf` turns into `{}`. That is why
//! an absent `text` is `MissingData` rather than a defaulted `""`: defaulting is
//! precisely how `craft.fs.writeFile` came to write empty files for months, and
//! here the same mistake would silently *wipe* the user's clipboard and report
//! success. The page-side call must be
//! `{t:'mobile', a:'clipboardWrite', d:'{"text":"…"}', i:N}`.
//!
//! ## `enableClipboard` is a deliberate behaviour change, recorded here
//!
//! The Swift gate reads `config.enableClipboard`, which originates in
//! TypeScript (`packages/ios/src/index.ts`, defaulting to `false`), is
//! templated into the Swift `CraftConfig`, and never reaches Zig. Rather than
//! guess at it or drop it, it is left plumbable: a host can call
//! `craft_ios_set_clipboard_enabled(false)` at startup. It defaults to
//! *enabled*, because a default of off would answer every app with
//! PERMISSION_DENIED until a host that does not exist yet is written. This is a
//! real change: an app that left `enableClipboard: false` now gets a working
//! clipboard while the capability object the page reads still says
//! `clipboard: false`.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;

/// The action names, spelled exactly as the Swift `case` labels spell them.
///
/// `test/ios_conformance_test.zig` matches the two lists by string, so a
/// tidier spelling here does not read as "migrated" — it reads as "Zig serves
/// an action the spec does not have", and the Swift arm stays live forever.
pub const A = struct {
    pub const clipboard_read = "clipboardRead";
    pub const clipboard_write = "clipboardWrite";
};

/// Both `.result`. `clipboardWrite` hands nothing back but is not
/// fire-and-forget: Swift resolves it with `true`, and `craft.clipboard.write()`
/// returns a promise the page awaits. Declaring it `.none` would strand that
/// caller for the whole request timeout. Desktop's `clipboard/writeText` is
/// `.none` for a reason that does not apply here — `craft-bridge.js` posts it
/// through `_send`, which resolves on post rather than on an answer.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.clipboard_read, .reply = .result },
    .{ .name = A.clipboard_write, .reply = .result },
};

/// The two literal replies. `clipboardRead` answers a *bare* JSON string and
/// `clipboardWrite` a bare `true`; `formatResultJS` interpolates whatever it is
/// given straight into `__craftBridgeResult(...)`, so neither needs wrapping.
const reply_true = "true";
const reply_no_text = "\"\"";

/// NSUTF8StringEncoding, for `-lengthOfBytesUsingEncoding:`.
const ns_utf8_string_encoding: usize = 4;

/// Whether the app permits clipboard access — the `enableClipboard` gate the
/// module comment describes.
///
/// A plain `bool`, not an atomic: WebKit delivers
/// `userContentController:didReceiveScriptMessage:` on the main thread and
/// `ios_dispatch.handleMessage` runs synchronously from there, so every reader
/// is the main thread, and the only writer is a host doing this once at startup.
var clipboard_enabled: bool = true;

pub fn setEnabled(value: bool) void {
    clipboard_enabled = value;
}

/// Startup hook for a host that wants the Swift gate back, alongside
/// `craft_ios_deliver_result`. Turning the capability off makes the handlers
/// *reject* with `PermissionDenied`; it must never reproduce the Swift gate's
/// actual failure mode, which was silence.
export fn craft_ios_set_clipboard_enabled(value: bool) callconv(.c) void {
    clipboard_enabled = value;
}

pub const ClipboardBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.clipboard_read)) {
            try self.readClipboard();
        } else if (std.mem.eql(u8, action, A.clipboard_write)) {
            try self.writeClipboard(data);
        } else {
            return bridge_error.BridgeError.UnknownAction;
        }
    }

    /// Read the pasteboard, and say *which* of the "no text" cases happened.
    ///
    /// The reply is a bare JSON string — `"hello"`, not `{"text":"hello"}`.
    /// That is what the page consumes: `test-bridges.html` does
    /// `'Clipboard: ' + await craft.clipboard.read()`, and an object reply
    /// renders as `[object Object]`. It diverges from desktop
    /// `clipboard/readText`, which answers `{"text":…}`; unifying the two is a
    /// contract change the page has to be rewritten for, so it is not made here
    /// by accident.
    ///
    /// `-hasStrings` is asked first because `-string` on its own cannot tell an
    /// empty pasteboard from a refusal. On iOS 16+ reading contents another app
    /// wrote presents a system confirmation, and a denial yields nil with no
    /// API that reports why. So: no strings at all is answered `""`, which is
    /// true; strings present but `-string` nil is `PermissionDenied`, because
    /// something was there and we were not given it. Swift answered `""` to
    /// both, and to a pasteboard holding an image.
    ///
    /// **This action can put an alert on the screen.** A page that calls it on
    /// load shows the user an unexplained paste prompt. Two things I could not
    /// verify and that want confirming on a device (the simulator never prompts,
    /// because a same-app write never does): that `-hasStrings` is itself
    /// prompt-free, and whether `-string` blocks until the user answers — if it
    /// does, it blocks this whole synchronous dispatch, and the page's
    /// 30-second request timeout can fire before the tap.
    fn readClipboard(self: *Self) !void {
        if (!clipboard_enabled) return bridge_error.BridgeError.PermissionDenied;

        const pasteboard = try generalPasteboard();
        if (!try hasStrings(pasteboard)) {
            bridge_error.sendResultToJS(self.allocator, A.clipboard_read, reply_no_text);
            return;
        }

        const text = try pasteboardString(pasteboard) orelse
            return bridge_error.BridgeError.PermissionDenied;

        const json = try quoteAsJsonString(self.allocator, text);
        defer self.allocator.free(json);
        bridge_error.sendResultToJS(self.allocator, A.clipboard_read, json);
    }

    /// Write `text` to the pasteboard. Requires the field; does not invent it.
    ///
    /// An explicitly-sent empty `text` is written and acknowledged. Clearing the
    /// clipboard is a legitimate request, and `bridge_clipboard.zig`'s
    /// `if (text.len == 0) return;` is a silent drop the caller cannot tell from
    /// a success. Only an *absent* `text` is an error.
    ///
    /// A non-string `text` is `InvalidParameter`, not coerced. The legacy JS
    /// posts whatever the caller passed without a `String(...)` — unlike
    /// `craft-bridge.js:565` — so a page handing in a number reaches here, and
    /// guessing what it meant would put a stringified guess on the user's
    /// clipboard.
    fn writeClipboard(self: *Self, data: []const u8) !void {
        if (!clipboard_enabled) return bridge_error.BridgeError.PermissionDenied;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch |err| switch (err) {
            // An allocation failure is not a malformed payload, and telling the
            // page INVALID_JSON about its own perfectly good JSON sends whoever
            // debugs it to the wrong side of the bridge.
            error.OutOfMemory => return err,
            else => return bridge_error.BridgeError.InvalidJSON,
        };
        defer parsed.deinit();

        const text = try requiredText(parsed.value);
        try putString(self.allocator, text);
        bridge_error.sendResultToJS(self.allocator, A.clipboard_write, reply_true);
    }
};

/// The `text` field, or the reason it cannot be used. Pure, so the host tests
/// can pin the three outcomes that the Swift `as? String` collapsed into one
/// silent fall-through.
fn requiredText(payload: std.json.Value) ![]const u8 {
    const object = switch (payload) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
    const field = object.get("text") orelse return bridge_error.BridgeError.MissingData;
    return switch (field) {
        .string => |s| s,
        else => bridge_error.BridgeError.InvalidParameter,
    };
}

/// Render `s` as a complete JSON string literal, quotes included.
///
/// `bridge_error.appendJsonEscaped` rather than the hand-rolled loop in
/// `bridge_clipboard.zig:200`, which misses every control byte below 0x20.
/// Clipboard contents are arbitrary user bytes and this string is interpolated
/// into JavaScript that `evaluateJavaScript:` then parses as source.
///
/// Allocated rather than built in a stack buffer: unlike a device description,
/// clipboard text has no ceiling, and a fixed buffer would truncate the paste
/// into a syntax error in the page.
fn quoteAsJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, s);
    try out.append(allocator, '"');

    return out.toOwnedSlice(allocator);
}

/// `+[UIPasteboard generalPasteboard]`.
///
/// Both nulls are real conditions and neither is skipped: `objc_getClass`
/// answers null when UIKit is not in the process, and `generalPasteboard`
/// answers nil in an app extension, where `UIPasteboard` is unavailable
/// outright.
fn generalPasteboard() !objc.id {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const UIPasteboard = objc.objc_getClass("UIPasteboard") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("generalPasteboard") orelse return error.SelectorNotFound;
    const pasteboard = objc.msgSendId(UIPasteboard, sel);
    if (pasteboard == null) return error.NoPasteboard;
    return pasteboard;
}

/// `-[UIPasteboard hasStrings]` — whether there is any text to ask for.
fn hasStrings(pasteboard: objc.id) !bool {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel = objc.sel_registerName("hasStrings") orelse return error.SelectorNotFound;
    return objc.msgSendBool(pasteboard, sel);
}

/// `-[UIPasteboard changeCount]`.
///
/// No helper for this in `objc_runtime.zig`, which stops at id/bool/stret, so
/// the cast is local. `NSInteger` is 64-bit on every supported iOS target,
/// hence `isize`.
fn changeCount(pasteboard: objc.id) !isize {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel = objc.sel_registerName("changeCount") orelse return error.SelectorNotFound;
    const Fn = *const fn (objc.id, objc.SEL) callconv(.c) isize;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(pasteboard, sel);
}

/// `-[UIPasteboard string]`, borrowed as UTF-8. Null means the pasteboard
/// returned nil — which the caller, not this function, decides the meaning of.
///
/// The bytes belong to the autoreleased NSString and live until the pool drains
/// at the end of this run-loop turn; every caller here copies or compares
/// before returning.
fn pasteboardString(pasteboard: objc.id) !?[]const u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const sel = objc.sel_registerName("string") orelse return error.SelectorNotFound;
    const ns = objc.msgSendId(pasteboard, sel);
    if (ns == null) return null;
    return try nsStringUTF8(ns);
}

/// The UTF-8 bytes of an NSString.
///
/// The length comes from `-lengthOfBytesUsingEncoding:` rather than from
/// scanning for the terminator: an NSString may legitimately contain U+0000,
/// and `std.mem.span` would truncate there without saying so — the same quiet
/// data loss as a dropped payload field, on bytes the user chose. A zero length
/// means empty or not representable as UTF-8, and both answer `""`.
fn nsStringUTF8(ns: objc.id) ![]const u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const utf8 = objc.getNSStringUTF8(ns) orelse return error.NilString;

    const sel_len = objc.sel_registerName("lengthOfBytesUsingEncoding:") orelse
        return error.SelectorNotFound;
    const Fn = *const fn (objc.id, objc.SEL, usize) callconv(.c) usize;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    const len = func(ns, sel_len, ns_utf8_string_encoding);

    return utf8[0..len];
}

/// `-[UIPasteboard setString:]`, then evidence that it landed.
///
/// `setString:` returns void, so "the call did not crash" is not evidence, and
/// replying `true` on that alone is the fabricated success this migration
/// exists to remove. `-changeCount` is the one real observation available: a
/// bump means the pasteboard genuinely changed.
///
/// A stationary count is not immediately a failure, though. I could not confirm
/// that writing text identical to the current contents still bumps the count,
/// and rejecting a correct "copy pressed twice" would be its own false report —
/// so no bump falls back to reading the contents back and comparing bytes. Only
/// *unchanged count and contents that are not what we asked for* is reported as
/// `NativeCallFailed`. A nil read-back counts as "there is no text on the
/// pasteboard", which matches a request to write an empty string and nothing
/// else.
///
/// The fallback read can itself raise the iOS 16+ paste prompt, in the one case
/// where it runs: the write appears not to have landed, so another app may
/// still own the contents. That is rare enough to be worth the certainty, and
/// the alternative is answering with a guess.
fn putString(allocator: std.mem.Allocator, text: []const u8) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const pasteboard = try generalPasteboard();
    const before = try changeCount(pasteboard);

    // Autoreleased by `+stringWithUTF8String:`; releasing it here would
    // over-release something the pasteboard has retained.
    const ns_text = try objc.createNSString(text, allocator);
    const sel_set = objc.sel_registerName("setString:") orelse return error.SelectorNotFound;
    objc.msgSendVoid1(pasteboard, sel_set, ns_text);

    if (try changeCount(pasteboard) != before) return;

    const current = try pasteboardString(pasteboard);
    const landed = if (current) |c| std.mem.eql(u8, c, text) else text.len == 0;
    if (!landed) return bridge_error.BridgeError.NativeCallFailed;
}

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    try testing.expectEqualStrings(A.clipboard_read, capability_actions[0].name);
    try testing.expectEqualStrings(A.clipboard_write, capability_actions[1].name);

    // `.result` for both, including the write. A `.none` write would let a
    // page's `await craft.clipboard.write(x)` sit until the request timeout.
    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these strings against the labels in
    // `CraftApp.swift`. A prettier spelling here would leave the Swift arm live
    // and register the migration as having served an action nobody asked for.
    try testing.expectEqualStrings("clipboardRead", A.clipboard_read);
    try testing.expectEqualStrings("clipboardWrite", A.clipboard_write);
}

test "every declared action dispatches to something" {
    // It may well fail for want of UIKit on the host — that is fine and is not
    // what this asserts. What it rules out is a name in the table that
    // `handleMessage` does not compare against, which is the drift the
    // capabilities mechanism exists to prevent.
    var bridge = ClipboardBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != bridge_error.BridgeError.UnknownAction);
        };
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = ClipboardBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("clipboardClear", "{}"),
    );
    // Near-misses too: the desktop spelling is a different action on a
    // different namespace and must not be quietly accepted here.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("writeText", "{\"text\":\"x\"}"),
    );
}

test "an absent text field is refused rather than defaulted to empty" {
    // The single highest-risk case in this migration: a page still posting the
    // flat legacy shape (`text` beside `action`, no `d`) arrives as `{}`. A
    // default would wipe the user's clipboard and report success.
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();

    try testing.expectError(bridge_error.BridgeError.MissingData, requiredText(parsed.value));
}

test "a legacy top-level text field does not count as the payload" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"action\":\"clipboardWrite\",\"callbackId\":\"cb_1\"}",
        .{},
    );
    defer parsed.deinit();

    try testing.expectError(bridge_error.BridgeError.MissingData, requiredText(parsed.value));
}

test "text is read from the field the page actually sends" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"text\":\"hello \\\"world\\\"\"}",
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("hello \"world\"", try requiredText(parsed.value));
}

test "an explicitly empty text is a value, not a missing field" {
    // Clearing the clipboard is a legitimate request. `bridge_clipboard.zig`
    // returns early on a zero-length string and acknowledges nothing, which the
    // caller cannot tell from success.
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"text\":\"\"}", .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("", try requiredText(parsed.value));
}

test "a non-string text is refused rather than coerced" {
    // The legacy JS posts whatever the caller passed, with no `String(...)`.
    const allocator = testing.allocator;
    for ([_][]const u8{
        "{\"text\":42}",
        "{\"text\":null}",
        "{\"text\":true}",
        "{\"text\":{\"a\":1}}",
        "{\"text\":[\"a\"]}",
    }) |payload| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        try testing.expectError(bridge_error.BridgeError.InvalidParameter, requiredText(parsed.value));
    }
}

test "a payload that is not an object is refused" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "\"hello\"", .{});
    defer parsed.deinit();

    try testing.expectError(bridge_error.BridgeError.InvalidJSON, requiredText(parsed.value));
}

test "malformed payload JSON is reported as such, not as a missing field" {
    var bridge = ClipboardBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.clipboard_write, "{\"text\":"),
    );
}

test "the read reply is a bare JSON string, not an object" {
    // `test-bridges.html` concatenates the result: `'Clipboard: ' + result`.
    // An object would render as `[object Object]`.
    const allocator = testing.allocator;
    const json = try quoteAsJsonString(allocator, "hello");
    defer allocator.free(json);
    try testing.expectEqualStrings("\"hello\"", json);
}

test "read replies survive quotes, backslashes, newlines, and control bytes" {
    // Clipboard contents are arbitrary user bytes and this lands inside
    // JavaScript source. The escape loop in `bridge_clipboard.zig` passes
    // control bytes through untouched, which produces invalid JSON.
    const allocator = testing.allocator;
    const json = try quoteAsJsonString(allocator, "a\"b\\c\nd\te\x01f");
    defer allocator.free(json);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001f\"", json);

    // And it is still parseable as the string it started as.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("a\"b\\c\nd\te\x01f", parsed.value.string);
}

test "an empty clipboard is reported as an empty string, and it parses" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply_no_text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("", parsed.value.string);
}

test "the write reply is bare true, which is what the page resolves with" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply_true, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.bool);
}

test "a disabled clipboard rejects both actions rather than falling silent" {
    // The Swift gate's failure mode was a promise that never settled. Whatever
    // is decided about `enableClipboard`, that must not come back.
    var bridge = ClipboardBridge.init(testing.allocator);
    defer bridge.deinit();

    setEnabled(false);
    defer setEnabled(true);

    try testing.expectError(
        bridge_error.BridgeError.PermissionDenied,
        bridge.handleMessage(A.clipboard_read, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.PermissionDenied,
        bridge.handleMessage(A.clipboard_write, "{\"text\":\"x\"}"),
    );
}

test "UIKit work is refused explicitly off Darwin instead of being skipped" {
    if (builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    try testing.expectError(error.UnsupportedPlatform, generalPasteboard());
    try testing.expectError(error.UnsupportedPlatform, putString(testing.allocator, "x"));
}
