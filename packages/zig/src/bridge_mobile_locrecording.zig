//! The on-disk half of a location recording: the track, the state mirror, and
//! the one action that only reads them — `readLocationRecording`.
//!
//! The other five live in `bridge_mobile_location.zig`, with the
//! `CLLocationManager` they share. That split follows the spec rather than
//! cutting across it: in `CraftWebView.Coordinator` a recording is not a device
//! of its own, it is a flag on the one delegate plus these two files, and the
//! flag belongs next to the delegate while the files belong here.
//!
//! This module keeps no manager, registers no Objective-C class and emits on no
//! channel. It does now *write*, which it did not when it only read the track,
//! so the format is stated once here and used from both sides.
//!
//! One JS surface reaches these six, `CraftApp.swift:2379-2384`:
//!
//! ```js
//! startRecording:     function() { return craft._invoke('startLocationRecording'); },
//! pauseRecording:     function() { return craft._invoke('pauseLocationRecording'); },
//! resumeRecording:    function() { return craft._invoke('resumeLocationRecording'); },
//! stopRecording:      function() { return craft._invoke('stopLocationRecording'); },
//! getRecordingState:  function() { return craft._invoke('getLocationRecordingState'); },
//! readRecording:      function() { return craft._invoke('readLocationRecording'); }
//! ```
//!
//! Every one is called with **no second argument**, so `_invoke`'s
//! `Object.assign({}, payload || {}, {action, callbackId})` posts the action
//! alone and `ios_dispatch.payloadOf` hands this module `"{}"`. There is no
//! payload field to carry, and none is invented. The SDK's
//! `startRecording(options)` does accept `enableHighAccuracy`/`timeout`/
//! `maximumAge`, but the injected `function()` takes no parameter, so those are
//! discarded *in the page* before the bridge sees them; Swift never reads them
//! either — accuracy is fixed once at `CraftApp.swift:444-446`. Honouring them
//! here would be an invention, not a port.
//!
//! ## What `readLocationRecording` owes the page, exactly
//!
//!  - **The reply is a bare JSON array**, never a wrapper object.
//!    `readLocationRecording` is `resolveCallback(callbackId, result:
//!    loadRecordedLocations())` (`CraftApp.swift:3026-3028`) and
//!    `resolveCallback` serialises with `[.fragmentsAllowed]`, which permits a
//!    bare value and never wraps a container. So the wire shape is
//!    `[{…},{…}]`, and `[]` when there is no track file. A `{"locations":[…]}`
//!    wrapper would be the `stopLocationRecording` shape, which is a different
//!    action this module does not serve.
//!  - **`sampleCount` is not part of this reply.** It appears on exactly one
//!    action, `getLocationRecordingState`. The SDK's *web fallback* adds it to
//!    start/pause/resume too (`mobile.ts:968,976,984`), but the iOS native path
//!    does not, and Swift is the contract being preserved.
//!  - **The samples keep the eight keys the writer wrote**: `latitude`,
//!    `longitude`, `altitude`, `accuracy`, `altitudeAccuracy`, `heading`,
//!    `speed`, `timestamp` (`CraftApp.swift:3072-3081`). This module never
//!    parses a sample into fields — it echoes the recorded line's bytes — so
//!    there is no field list here to drift out of step with the writer's, and
//!    no way for a key to be dropped or renamed on the way out.
//!  - **The file is `<AppSupport>/craft-location-recording.jsonl`**, directly
//!    in Application Support with no per-app subdirectory, which is where
//!    `locationRecordingTrackURL` (`CraftApp.swift:2908-2911`) puts it. Reading
//!    a different path would answer `[]` for a recording that exists.
//!
//! ## Echoing bytes rather than reparsing, and why that is the faithful route
//!
//! A sample is eight doubles. Parsing one to `f64` and re-rendering it with
//! `{d}` needs `std.fmt.float.bufferSize(.decimal, f64)` = 347 bytes *per
//! field* — 1e300 alone is 301 digits — and a too-small buffer would turn a
//! legal sample into a `NoSpaceLeft` refusal. More importantly the round trip
//! is lossy in a way nothing downstream can detect: a `heading` of
//! `1.7976931348623157e308` that comes back rounded is a wrong answer reported
//! as a right one.
//!
//! So the reader validates each line and then copies its **original bytes**
//! into the array. There is no float formatting anywhere in this module, so
//! the buffer-size hazard is structurally absent rather than merely handled —
//! and the test suite pins that by round-tripping a 301-digit magnitude
//! verbatim. This is also strictly closer to the recorded truth than Swift's
//! own path, which goes through `JSONSerialization` in both directions.
//!
//! ## Where this deliberately differs from `loadRecordedLocations()`
//!
//! Swift, `CraftApp.swift:3062-3068`:
//!
//! ```swift
//! guard let text = try? String(contentsOf: locationRecordingTrackURL, encoding: .utf8) else { return [] }
//! return text.split(separator: "\n").compactMap { line in
//!     guard let data = line.data(using: .utf8) else { return nil }
//!     return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
//! }
//! ```
//!
//! Three behaviours are carried across unchanged, and three are not:
//!
//!  - **Carried: a missing file is `[]`.** There is no recording, so there are
//!    no samples. That is a true answer, not a fabricated one.
//!  - **Carried: empty lines are dropped.** `split(separator:)` omits empty
//!    subsequences by default, and a trailing newline — which the appender
//!    always writes — is otherwise a phantom sample.
//!  - **Carried: a line that is not a JSON *object* is dropped, silently by
//!    Swift and with a counted log line here.** `as? [String: Any]` fails for
//!    an array, a number, a string or a torn half-line, and `compactMap` drops
//!    it. That drop is the *designed* recovery of an append-only NDJSON log: a
//!    crash mid-`write` leaves a partial tail line, and dropping it is how the
//!    format is meant to degrade.
//!  - **Not carried: one bad byte losing the whole file.**
//!    `String(contentsOf:encoding:)` returns nil for a file that is not valid
//!    UTF-8 anywhere, so a single torn multi-byte sequence at the tail makes
//!    Swift answer `[]` for a track full of real fixes. This module validates
//!    UTF-8 **per line**, so the torn line is dropped and the samples before it
//!    survive. Every element it emits is still a genuinely recorded sample —
//!    the divergence returns more of the page's own data and cannot invent any.
//!  - **Not carried: a file that exists and cannot be read answering `[]`.**
//!    Swift's `try?` flattens "there is no recording" and "the recording is
//!    there and I could not open it" into the same empty array. The second is a
//!    real possibility: the track file carries
//!    `NSFileProtectionCompleteUntilFirstUserAuthentication`, so a
//!    background launch before first unlock cannot open it. Answering `[]`
//!    there tells a page its route is empty when it is intact on disk — the
//!    fabricated-success shape, on the one action whose entire job is not to
//!    lose a route. An open or read failure is an error here, with the cause
//!    logged. Only `FileNotFound` is `[]`.
//!  - **Not carried: an unbounded read.** Swift materialises a track of any
//!    size; this module refuses one over `max_track_bytes` (32 MiB, roughly
//!    176,000 fixes) rather than truncate it, for the reason written out at
//!    that constant. This is the one divergence that answers *less* than
//!    Swift, and it is listed here rather than only at the constant because a
//!    section enumerating the differences has to enumerate all of them. It is
//!    reachable only past about 49 hours of continuous one-per-second
//!    recording, and the alternative — a track silently cut off at 32 MiB and
//!    reported as the whole one — is the failure this module exists to avoid.
//!
//! ## What it took to move the other five, and what had gone stale
//!
//! This section used to argue that the five could not move. Two of its three
//! blockers had already been removed by other work and nothing re-checked them;
//! the audit is #124, and the short version is worth keeping because the shape
//! of the mistake is more useful than the conclusion was.
//!
//!  - **"`enableGeolocation` has no mirror anywhere in `packages/zig/src`."**
//!    True when written. `ios_config.zig` now reads the same
//!    `craft.config.json` Swift decodes and exposes that flag, and its own
//!    header names this note as one of the two it closes. Only
//!    `startLocationRecording` is gated in the spec, so it is the only one of
//!    the five in `ios_config.gateFor`.
//!  - **"It needs an event channel that does not exist."** The paragraph
//!    checked `capabilities.Channel`, where `.location_update` really is
//!    `"craft:location:update"` and really is listened for by nothing on iOS.
//!    But the iOS event path is `ios_events.Event`, whose `.location_update`
//!    is `"craftLocationUpdate"` — the name the recorder needs — and
//!    `bridge_mobile_location.zig` was already emitting on it for
//!    `watchPosition`, one module away.
//!  - **"`getLocationRecordingState` answers from memory, and a file-reading
//!    Zig would diverge."** This one was correct, and it is the reason
//!    `decodeState` exists in the shape it does. Swift's restore guard,
//!    `state["active"] as? Bool == true`, means a *stopped* recording — whose
//!    file still carries the old `id` and `startedAt` — restores as nothing at
//!    all. Ported literally, so a stop-then-read in one launch still reports
//!    the id and a relaunch still reports null.
//!
//! The fourth obstacle was real and was never written down here: SwiftUI runs
//! `makeCoordinator()` before `makeUIView`, so `Coordinator.init` — and
//! `restoreLocationRecordingState()` inside it — ran before
//! `craft_ios_set_webview` had been called even once. Whichever runtime
//! restores first owns the manager for the rest of the launch. That is settled
//! by `craft_ios_adopt_location_recording`, which Swift consults *instead of*
//! its own restore and falls back from when `dlsym` finds no runtime.
//!
//! ## No delegate, no manager, no event, no async
//!
//! This module reads and writes two files. It registers no Objective-C class,
//! keeps no delegate alive, touches no `CLLocationManager`, emits on no
//! channel, and takes no `ios_async` ticket: every one of these operations is
//! synchronous, as `loadRecordedLocations()` and
//! `persistLocationRecordingState()` both are. `ios_dispatch.handleMessage` runs from
//! `craftDidReceiveScriptMessage`, a `WKScriptMessageHandler` callback WebKit
//! delivers on the main thread, so the reply is sent from the main thread with
//! no hop — the reasoning is written out at `bridge_mobile_display.zig`.
//!
//! No mutex either, and that is not an oversight. The premise of a
//! mutex-guarded in-memory buffer does not match this design: the writer is
//! `appendSample`, called from `didUpdateLocations`, which CoreLocation
//! delivers on the thread that created the manager — the main thread — and the
//! readers are dispatches, also on the main thread. The shared state is a file,
//! and the two never run concurrently. The recorder's *in-memory* state does
//! take a mutex, and it takes it where it lives, in
//! `bridge_mobile_location.zig`.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const io_context = @import("io_context.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The same type as `objc.id` — `?*anyopaque` — spelled locally.
///
/// `objc_runtime.objc` is an empty struct off Darwin, and a function
/// *signature* is analysed even when a comptime platform guard makes its body
/// unreachable, so naming `objc.id` in the `callconv(.c)` type below would
/// break the host build. It stays a single optional pointer, never `?objc.id`:
/// a double optional is illegal in a `callconv(.c)` type.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches the two lists by string in both
/// directions.
///
/// The other five are served by `bridge_mobile_location.zig`, which owns the
/// `CLLocationManager` they share with the watch. They are not absent from the
/// migration, only from this file — and `bridge_mobile_location.zig`'s own
/// routing test asserts this module does not answer them, so the split cannot
/// quietly become an overlap that makes `ios_dispatch`'s first-match order
/// significant.
pub const A = struct {
    pub const read_location_recording = "readLocationRecording";
};

/// `.result`: the Swift path terminates in exactly one `resolveCallback`, and
/// `craft.location.readRecording()` returns a promise the page awaits. `.none`
/// would strand that caller.
///
/// `.live`, not `.unavailable`: reading a file is synchronous, needs no
/// permission prompt and no entitlement. `.unavailable` is for an action that
/// dispatches and refuses, and this one does neither.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.read_location_recording, .reply = .result },
};

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host.
const Route = enum { read_recording };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.read_location_recording)) return .read_recording;
    return null;
}

/// The track file the recorder appends to, relative to Application Support.
///
/// `CraftApp.swift:2908-2911` puts it directly in Application Support with no
/// per-app subdirectory. The sibling `craft-location-recording-state.json` is
/// deliberately not read anywhere in this module: it is the summary's source,
/// and the summary is a shape this module does not serve.
const track_file_name = "craft-location-recording.jsonl";

/// The largest track this module will read into memory.
///
/// Matching `cli.zig`'s `max_html_file_bytes`. At the recorder's ~190 bytes per
/// sample this is roughly 176,000 fixes — about 49 hours at one per second.
/// Beyond it the read is **refused, never truncated**: a truncated track
/// reported as the whole one is a wrong answer delivered as a right one, and
/// the page has no way to tell.
const max_track_bytes: u64 = 32 * 1024 * 1024;

/// The reply for "there is no recording to read".
const empty_array = "[]";

pub const LocationRecordingBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        // The payload is ignored, because there is nothing in it. The injected
        // JS posts the action alone and the Swift dispatcher reads nothing out
        // of `body`, so parsing `d` here would turn a page that sends a stray
        // field — or nothing at all — into an `INVALID_JSON` rejection for a
        // call Swift answers. Ignored, not parsed: the same call
        // `bridge_mobile_notifications.zig` makes for `getPendingNotifications`.
        _ = data;

        const route = routeFor(action) orelse return bridge_error.BridgeError.UnknownAction;
        // Exhaustive, so a `Route` without a handler is a compile error.
        return switch (route) {
            .read_recording => self.readLocationRecording(),
        };
    }

    /// Reply with every sample the recorder has written, as a bare JSON array.
    ///
    /// `loadRecordedLocations()` in Zig: read the track file, split on newlines,
    /// keep the lines that are JSON objects, emit their bytes. A missing file is
    /// `[]`; an unreadable one is an error (see the module comment).
    fn readLocationRecording(self: *Self) !void {
        const path = try trackFilePath(self.allocator);
        defer self.allocator.free(path);

        const text = try readTrackBytes(self.allocator, path) orelse {
            // No track file: no recording has ever been started, or the app
            // container was cleared. Swift answers `[]` and so does this —
            // there genuinely are no samples, so it is not a fabricated answer.
            bridge_error.sendResultToJS(self.allocator, A.read_location_recording, empty_array);
            return;
        };
        defer self.allocator.free(text);

        const json = try shapeRecording(self.allocator, text);
        defer self.allocator.free(json);

        bridge_error.sendResultToJS(self.allocator, A.read_location_recording, json);
    }
};

// =============================================================================
// Shaping. Pure, so every line-level decision Swift made silently is pinnable
// on a host — on any platform, with no CoreLocation and no app container.
// =============================================================================

/// The recorded track as the bare JSON array `readLocationRecording` resolves.
///
/// Each surviving line's **original bytes** go into the array; nothing is
/// parsed into fields and re-rendered. A line is kept when it is valid UTF-8
/// and parses as a single JSON *object* — the two conditions
/// `line.data(using: .utf8)` and `as? [String: Any]` impose in Swift, applied
/// per line rather than per file.
///
/// Allocation failure propagates rather than being read as a corrupt line: an
/// OOM that silently dropped a sample would report a short track as the whole
/// one.
fn shapeRecording(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '[');

    var kept: usize = 0;
    var dropped: usize = 0;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        // `split(separator:)` omits empty subsequences, and the appender always
        // writes a trailing newline — without this every file would end in a
        // phantom sample.
        if (line.len == 0) continue;

        if (!try lineIsJsonObject(allocator, line)) {
            dropped += 1;
            continue;
        }

        if (kept > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, line);
        kept += 1;
    }

    try out.append(allocator, ']');

    if (dropped > 0) {
        // Swift drops these without a word. The drop itself is the format's
        // designed recovery for a torn tail, but a page reporting missing
        // samples deserves something to point at.
        std.log.warn(
            "readLocationRecording: {d} of {d} recorded lines were not JSON objects and were dropped",
            .{ dropped, dropped + kept },
        );
    }

    return out.toOwnedSlice(allocator);
}

/// Whether one line is a single JSON object, and therefore safe to copy into
/// the array verbatim.
///
/// UTF-8 is checked first: `std.json` would reject most invalid sequences
/// anyway, but the emitted bytes land in a JavaScript source position, and
/// "valid JSON" and "valid UTF-8" are worth establishing separately rather than
/// inferring one from the other.
///
/// `parseFromSlice` is whole-document, so a line holding two objects
/// (`{"a":1} {"b":2}` — what a torn concurrent write can leave) is refused
/// rather than copied, which would have produced an array that is not JSON at
/// all.
///
/// `duplicate_field_behavior` is `.use_last` rather than `std.json`'s default
/// of `.@"error"`. This check stands in for `as? [String: Any]`, and the
/// `JSONSerialization` behind it accepts a repeated key and keeps the last —
/// as does the `JSON.parse` that reads these bytes back out at the far end.
/// Leaving the default would drop a line both of the other two parsers accept,
/// which is a recorded sample lost to a Zig-only strictness the page never
/// asked for. `appendRecordedLocation` cannot write one (it serialises a Swift
/// dictionary, whose keys are unique by construction), so this is about not
/// losing a line some other native writer appended.
fn lineIsJsonObject(allocator: std.mem.Allocator, line: []const u8) !bool {
    if (!std.unicode.utf8ValidateSlice(line)) return false;

    const options: std.json.ParseOptions = .{ .duplicate_field_behavior = .use_last };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();

    return parsed.value == .object;
}

// =============================================================================
// The Objective-C and filesystem half.
//
// The Objective-C path is Darwin-gated: off Darwin there is no app container to
// look in, and saying so beats answering `[]` for a file nothing looked for.
// `readTrackBytes` is deliberately *not* gated — it takes a path rather than
// finding one, so the host tests drive every one of its outcomes against a real
// file on any platform.
// =============================================================================

/// `NSApplicationSupportDirectory`.
const ns_application_support_directory: c_ulong = 14;
/// `NSUserDomainMask`.
const ns_user_domain_mask: c_ulong = 1;
/// `NSUTF8StringEncoding`.
const ns_utf8_string_encoding: c_ulong = 4;

/// The absolute path of `<AppSupport>/craft-location-recording.jsonl`.
///
/// `NSFileManager` → `URLsForDirectory:inDomains:` → `firstObject` → `path`,
/// which is the chain `locationRecordingTrackURL` runs, with every step guarded
/// — a nil anywhere is a named error, never a message to nil read as a path.
///
/// Swift subscripts the array with `[0]`, which raises `NSRangeException` on an
/// empty result; `firstObject` answers nil instead, and nil here is a refusal
/// rather than an uncatchable SIGABRT. In every case where the two differ,
/// Swift crashed.
fn trackFilePath(allocator: std.mem.Allocator) ![]u8 {
    const directory = try applicationSupportPath(allocator);
    defer allocator.free(directory);

    return std.fmt.allocPrint(allocator, "{s}/" ++ track_file_name, .{directory});
}

fn applicationSupportPath(allocator: std.mem.Allocator) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSFileManager = objc.objc_getClass("NSFileManager") orelse return error.ClassNotFound;
    const sel_default = objc.sel_registerName("defaultManager") orelse return error.SelectorNotFound;
    const manager = objc.msgSendId(NSFileManager, sel_default) orelse return error.NativeCallFailed;

    const sel_urls = objc.sel_registerName("URLsForDirectory:inDomains:") orelse return error.SelectorNotFound;
    // NSUInteger arguments: explicit `c_ulong`, because the variadic msgSend
    // cast takes its argument types from what is passed.
    const urls = objc.msgSendId2(
        manager,
        sel_urls,
        ns_application_support_directory,
        ns_user_domain_mask,
    ) orelse return error.NativeCallFailed;

    const sel_first = objc.sel_registerName("firstObject") orelse return error.SelectorNotFound;
    const url = objc.msgSendId(urls, sel_first) orelse return error.NotFound;

    const sel_path = objc.sel_registerName("path") orelse return error.SelectorNotFound;
    const path_obj = objc.msgSendId(url, sel_path) orelse return error.NativeCallFailed;

    return copyNSString(allocator, path_obj);
}

/// An `NSString` as owned bytes, refusing a value `UTF8String` truncated.
///
/// `-[NSString UTF8String]` is NUL-terminated, so a path carrying an embedded
/// U+0000 would read back short — and a short path names a *different* file,
/// whose absence would then be reported as "this recording has no samples".
/// That is the fabricated-success shape, so the C-string length is checked
/// against `lengthOfBytesUsingEncoding:` and a mismatch fails the read.
/// (`bridge_mobile_notifications.zig` makes the same check for the same
/// reason.)
fn copyNSString(allocator: std.mem.Allocator, ns_string: Id) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const cstr = objc.getNSStringUTF8(ns_string) orelse return error.NativeCallFailed;
    const bytes = std.mem.span(cstr);

    const sel_len = objc.sel_registerName("lengthOfBytesUsingEncoding:") orelse return error.SelectorNotFound;
    const LenFn = *const fn (Id, objc.SEL, c_ulong) callconv(.c) c_ulong;
    const len_fn: LenFn = @ptrCast(&objc.objc_msgSend);
    const declared = len_fn(ns_string, sel_len, ns_utf8_string_encoding);

    if (declared != bytes.len) {
        std.log.warn(
            "readLocationRecording: Application Support path is {d} UTF-8 bytes but reads back as {d}; refusing rather than reading some other file",
            .{ declared, bytes.len },
        );
        return error.NativeCallFailed;
    }

    return allocator.dupe(u8, bytes);
}

/// The track file's bytes, or null when there is no track file.
///
/// Null is the only case that becomes `[]`. Everything else — a permission
/// failure under `NSFileProtectionCompleteUntilFirstUserAuthentication`, a
/// directory where the file should be, a short read — is an error with the
/// cause logged, because "I could not read it" and "it is empty" are different
/// answers and only one of them is true.
///
/// Takes the path as an argument so the host tests can drive it against a real
/// file on any platform, rather than only against the app container that exists
/// on exactly one.
fn readTrackBytes(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const io = io_context.get();

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            std.log.warn("readLocationRecording: could not open '{s}': {}", .{ path, err });
            return bridge_error.BridgeError.NativeCallFailed;
        },
    };
    defer file.close(io);

    const info = file.stat(io) catch |err| {
        std.log.warn("readLocationRecording: could not stat '{s}': {}", .{ path, err });
        return bridge_error.BridgeError.NativeCallFailed;
    };

    if (info.size > max_track_bytes) {
        std.log.warn(
            "readLocationRecording: track file is {d} bytes, over the {d}-byte ceiling; refusing rather than reporting a truncated route as the whole one",
            .{ info.size, max_track_bytes },
        );
        return bridge_error.BridgeError.NativeCallFailed;
    }

    var buf = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(buf);

    var read: usize = 0;
    while (read < buf.len) {
        const n = file.readStreaming(io, &.{buf[read..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                std.log.warn("readLocationRecording: could not read '{s}': {}", .{ path, err });
                return bridge_error.BridgeError.NativeCallFailed;
            },
        };
        if (n == 0) break;
        read += n;
    }

    if (read < buf.len) {
        // Not `startLocationRecording`'s truncation: that is
        // `Data().write(to:options:.atomic)`, which writes an auxiliary file
        // and renames it over the directory entry, so a descriptor already
        // open on the old inode never sees the file shrink. The resize is here
        // for the reason that holds whatever caused the short read — the tail
        // of this allocation was never written, and handing back undefined
        // bytes shaped like recorded samples is worse than any of the causes.
        //
        // Said out loud rather than absorbed: a short read means the reply is
        // missing samples the stat counted, and a truncated track reported as
        // a whole one is what `max_track_bytes` above refuses outright.
        std.log.warn(
            "readLocationRecording: '{s}' stat'd {d} bytes but only {d} could be read; the reply covers what was read",
            .{ path, buf.len, read },
        );
        buf = try allocator.realloc(buf, read);
    }

    return buf;
}

// =============================================================================
// The on-disk format of a recording.
//
// `bridge_mobile_location.zig` owns the `CLLocationManager`, the delegate and
// the lifecycle; it calls in here for every byte that reaches the disk. The
// dependency runs one way — nothing in this file imports that one — because a
// recording really is what `CraftWebView.Coordinator` makes it: a flag on the
// shared delegate plus two files. This is the half with a format to get wrong.
//
// Both files keep Swift's names, Swift's location and Swift's key spellings, so
// a build with the Zig recorder removed reads back a recording this one wrote.
// That is not hypothetical tidiness: `restoreLocationRecordingState` is still
// in the template and still runs whenever the adoption export is absent.
// =============================================================================

/// The lifecycle mirror, beside the track. `CraftApp.swift:3156-3159`.
const state_file_name = "craft-location-recording-state.json";

/// The absolute path of `<AppSupport>/craft-location-recording-state.json`.
fn stateFilePath(allocator: std.mem.Allocator) ![]u8 {
    const directory = try applicationSupportPath(allocator);
    defer allocator.free(directory);

    return std.fmt.allocPrint(allocator, "{s}/" ++ state_file_name, .{directory});
}

/// The largest state file worth reading. The document is four scalars; anything
/// approaching this is not a state file, and reading it into memory to discover
/// that is the wrong order.
const max_state_bytes: u64 = 64 * 1024;

/// What `persistLocationRecordingState` writes and `restoreLocationRecordingState`
/// reads back, with the same four keys and the same types.
///
/// `started_at` is milliseconds — `Date().timeIntervalSince1970 * 1000`
/// (`CraftApp.swift:3222`) — and stays an `f64` the whole way, because that is
/// what Swift wrote and rounding it to an integer here would change a value the
/// page compares against its own `Date.now()`.
pub const State = struct {
    active: bool = false,
    paused: bool = false,
    /// Owned by the `State`. Null is `NSNull` on the wire, which is what a
    /// recording that has never started has.
    id: ?[]const u8 = null,
    started_at: ?f64 = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        self.id = null;
    }
};

/// Read the persisted state, applying `restoreLocationRecordingState`'s own guard.
///
/// Swift opens with
/// `guard … state["active"] as? Bool == true else { return }`
/// (`CraftApp.swift:3197-3201`), and every `return` there leaves the four
/// instance variables at their defaults. So a file that says `active:false` —
/// which is exactly what a *stopped* recording leaves behind, `id` and
/// `startedAt` still populated — restores as nothing at all.
///
/// That guard is the whole reason this returns a `State` rather than the file's
/// contents. A reader that handed back the stopped recording's `id` would
/// answer `{"id":"ABC-…"}` where Swift answers `{"id":null}`, which was one of
/// the three blockers recorded against migrating this recorder (#124). It is a
/// rule, and this is the rule, ported rather than approximated.
///
/// A missing file is `.{}`, not an error: there has never been a recording.
pub fn readState(allocator: std.mem.Allocator) !State {
    const path = try stateFilePath(allocator);
    defer allocator.free(path);
    return readStateFrom(allocator, path);
}

/// `readState` against a named file, so the guard above is testable without a
/// test writing into `~/Library/Application Support`.
fn readStateFrom(allocator: std.mem.Allocator, path: []const u8) !State {
    const bytes = (try readSmallFile(allocator, path, max_state_bytes)) orelse return .{};
    defer allocator.free(bytes);

    // `JSONSerialization.jsonObject` throwing, or the cast to `[String: Any]`
    // failing, both land on Swift's `else { return }`. Unreadable state is no
    // state, not an error — the recording is gone either way, and saying so
    // beats refusing every later call because one file is torn.
    return decodeState(allocator, bytes) catch |err| {
        std.log.warn(
            "location recording: state file at '{s}' is unreadable ({}); treating it as no recording, exactly as restoreLocationRecordingState's guard does",
            .{ path, err },
        );
        return .{};
    };
}

/// The guard and the four reads, with no file anywhere near them.
fn decodeState(allocator: std.mem.Allocator, bytes: []const u8) !State {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return .{};
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |o| o,
        else => return .{},
    };

    // `as? Bool == true`: a missing key, a null, a number, a string all fail
    // the cast and land on the same `return`.
    const active = switch (object.get("active") orelse return .{}) {
        .bool => |b| b,
        else => return .{},
    };
    if (!active) return .{};

    var state: State = .{ .active = true };
    errdefer state.deinit(allocator);

    // Past the guard, Swift's reads are `as? Bool ?? false` and `as? String` /
    // `as? TimeInterval`, so a wrong type here is a default rather than a
    // refusal.
    if (object.get("paused")) |value| {
        state.paused = switch (value) {
            .bool => |b| b,
            else => false,
        };
    }
    if (object.get("id")) |value| {
        switch (value) {
            .string => |s| state.id = try allocator.dupe(u8, s),
            else => {},
        }
    }
    if (object.get("startedAt")) |value| {
        state.started_at = switch (value) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    return state;
}

/// Mirror the lifecycle to disk, atomically, then protect the file.
///
/// `persistLocationRecordingState` (`CraftApp.swift:3179-3195`) writes all four
/// keys every time, with `.atomic`, and then re-applies protection. Each of
/// those three is load-bearing and each is done here.
///
/// Unlike Swift, a failure is **returned**. Swift catches and prints, so memory
/// and file drift with nothing to signal it — a divergence its own recorder
/// comment calls out. A caller here can refuse the action instead of reporting
/// a recording that was never persisted.
pub fn writeState(allocator: std.mem.Allocator, state: State) !void {
    const path = try stateFilePath(allocator);
    defer allocator.free(path);

    const bytes = try encodeState(allocator, state);
    defer allocator.free(bytes);

    try writeFileAtomic(allocator, path, bytes);
    protectFile(path);
}

/// The four keys, in `persistLocationRecordingState`'s spelling.
fn encodeState(allocator: std.mem.Allocator, state: State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"active\":");
    try out.appendSlice(allocator, if (state.active) "true" else "false");
    try out.appendSlice(allocator, ",\"paused\":");
    try out.appendSlice(allocator, if (state.paused) "true" else "false");
    try out.appendSlice(allocator, ",\"id\":");
    if (state.id) |id| {
        // `appendJsonEscaped` escapes the contents and writes no delimiters, so
        // the quotes are this caller's job. Without them an id containing a
        // quote does not merely look wrong — it tears the document, and the
        // whole recording reads back as none.
        try out.append(allocator, '"');
        try bridge_error.appendJsonEscaped(allocator, &out, id);
        try out.append(allocator, '"');
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, ",\"startedAt\":");
    if (state.started_at) |started| {
        // `allocPrint`, not a stack buffer: an `f64` rendered with `{d}` can
        // need 347 bytes, and a `NoSpaceLeft` here would lose a live recording
        // to a formatting detail. Growing the allocation cannot overflow.
        const rendered = try std.fmt.allocPrint(allocator, "{d}", .{started});
        defer allocator.free(rendered);
        try out.appendSlice(allocator, rendered);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, "}");

    return out.toOwnedSlice(allocator);
}

/// Start a fresh track, replacing whatever the last recording left.
///
/// `startLocationRecording` writes an empty `Data()` with `.atomic` before it
/// touches any state (`CraftApp.swift:3213-3220`), so a new recording never
/// inherits the previous route's samples, and a failure refuses the start
/// rather than recording into the old file.
pub fn resetTrack(allocator: std.mem.Allocator) !void {
    const path = try trackFilePath(allocator);
    defer allocator.free(path);

    try writeFileAtomic(allocator, path, "");
    protectFile(path);
}

/// Append one already-shaped sample object, with the newline that separates it.
///
/// `appendRecordedLocation` (`CraftApp.swift:3288-3302`) opens the track, seeks
/// to the end and writes the JSON plus `0x0A`. `length` + `writePositionalAll`
/// is that pair, and it is the reason this is not a read-modify-write: a route
/// of 176,000 fixes rewritten once per second is not a recorder.
///
/// The sample arrives as bytes that `didUpdateLocations` already shaped for the
/// page, so the track holds exactly what the event carried. Nothing is
/// reparsed, and nothing can be rounded on the way in.
pub fn appendSample(allocator: std.mem.Allocator, sample_json: []const u8) !void {
    const path = try trackFilePath(allocator);
    defer allocator.free(path);
    return appendSampleTo(allocator, path, sample_json);
}

/// `appendSample` against a named track.
fn appendSampleTo(allocator: std.mem.Allocator, path: []const u8, sample_json: []const u8) !void {
    const io = io_context.get();

    // Swift's `FileHandle(forWritingTo:)` throws when the file is not there,
    // and its `catch` prints and drops the sample. Opening write-only without
    // creating keeps that: a track that does not exist means no recording is
    // running, and creating one here would start a route nobody asked for.
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch |err| {
        std.log.warn(
            "location recording: could not open the track at '{s}' to append a sample ({}); the fix is lost",
            .{ path, err },
        );
        return bridge_error.BridgeError.NativeCallFailed;
    };
    defer file.close(io);

    const end = file.length(io) catch |err| {
        std.log.warn("location recording: could not measure the track at '{s}' ({})", .{ path, err });
        return bridge_error.BridgeError.NativeCallFailed;
    };

    // One write, not two. A sample and its newline that reach the file
    // separately can be torn apart by a kill between them, and a half-written
    // line is the one thing the reader has to throw away.
    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{sample_json});
    defer allocator.free(line);

    file.writePositionalAll(io, line, end) catch |err| {
        std.log.warn("location recording: could not append to the track at '{s}' ({})", .{ path, err });
        return bridge_error.BridgeError.NativeCallFailed;
    };
}

/// Every sample as the bare JSON array `readLocationRecording` resolves.
///
/// `stopLocationRecording` puts this same array under a `locations` key
/// (`CraftApp.swift:3264-3267`), so the two actions cannot disagree about which
/// lines survive: they call the same reader.
///
/// Caller owns the result. A missing track is `[]`.
pub fn readTrackArray(allocator: std.mem.Allocator) ![]u8 {
    const path = try trackFilePath(allocator);
    defer allocator.free(path);

    const text = try readTrackBytes(allocator, path) orelse
        return allocator.dupe(u8, empty_array);
    defer allocator.free(text);

    return shapeRecording(allocator, text);
}

/// How many samples `readLocationRecording` would return.
///
/// `getLocationRecordingState` reports `loadRecordedLocations().count`
/// (`CraftApp.swift:3274`), so this has to agree with the reader line for line
/// — the same blank-line and non-object drops — or the page is told it has a
/// number of fixes it cannot then read back.
pub fn sampleCount(allocator: std.mem.Allocator) !usize {
    const path = try trackFilePath(allocator);
    defer allocator.free(path);
    return countSamplesIn(allocator, path);
}

/// `sampleCount` against a named track.
fn countSamplesIn(allocator: std.mem.Allocator, path: []const u8) !usize {
    const bytes = (try readTrackBytes(allocator, path)) orelse return 0;
    defer allocator.free(bytes);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (try lineIsJsonObject(allocator, line)) count += 1;
    }
    return count;
}

/// Read a small file whole, or null when it is not there.
fn readSmallFile(allocator: std.mem.Allocator, path: []const u8, ceiling: u64) !?[]u8 {
    const io = io_context.get();

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            std.log.warn("location recording: could not open '{s}': {}", .{ path, err });
            return bridge_error.BridgeError.NativeCallFailed;
        },
    };
    defer file.close(io);

    const size = file.length(io) catch |err| {
        std.log.warn("location recording: could not measure '{s}': {}", .{ path, err });
        return bridge_error.BridgeError.NativeCallFailed;
    };
    if (size > ceiling) {
        std.log.warn(
            "location recording: '{s}' is {d} bytes, over the {d}-byte ceiling; refusing to read it",
            .{ path, size, ceiling },
        );
        return bridge_error.BridgeError.NativeCallFailed;
    }

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    var read: usize = 0;
    while (read < buf.len) {
        const n = file.readStreaming(io, &.{buf[read..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                std.log.warn("location recording: could not read '{s}': {}", .{ path, err });
                return bridge_error.BridgeError.NativeCallFailed;
            },
        };
        if (n == 0) break;
        read += n;
    }

    return buf[0..read];
}

/// Write `bytes` to `path` so that a reader sees either the old file or the
/// whole new one, never a half-written document.
///
/// This is what `Data.write(options: .atomic)` does — a sibling temp file and a
/// rename — and it matters for the same reason it does there: the state file is
/// read at launch, and a launch that lands mid-write would restore a torn
/// recording.
fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const io = io_context.get();

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    {
        const file = std.Io.Dir.cwd().createFile(io, temp_path, .{}) catch |err| {
            std.log.warn("location recording: could not create '{s}': {}", .{ temp_path, err });
            return bridge_error.BridgeError.NativeCallFailed;
        };
        defer file.close(io);

        file.writeStreamingAll(io, bytes) catch |err| {
            std.log.warn("location recording: could not write '{s}': {}", .{ temp_path, err });
            return bridge_error.BridgeError.NativeCallFailed;
        };
    }

    const dir = std.Io.Dir.cwd();
    std.Io.Dir.rename(dir, temp_path, dir, path, io) catch |err| {
        std.log.warn("location recording: could not move '{s}' into place at '{s}': {}", .{ temp_path, path, err });
        // A temp file left behind is litter; a temp file left behind *and*
        // reported as success is a recording nobody can find.
        std.Io.Dir.deleteFile(dir, io, temp_path) catch {};
        return bridge_error.BridgeError.NativeCallFailed;
    };
}

/// Apply `protectLocationFile`'s two attributes: data protection, and exclusion
/// from backup. `CraftApp.swift:3304-3311`.
///
/// Best effort, and deliberately so — Swift's are both `try?`. A route that
/// records is better than a route refused because one attribute would not
/// stick, and the two failures differ in kind: without protection the file is
/// readable before first unlock, without the backup flag it leaves the device
/// in an iCloud backup. Both are logged by name so neither is silent.
///
/// Off Darwin this does nothing and says nothing: there is no data protection
/// to apply, and the host tests write their fixtures into the working
/// directory.
fn protectFile(path: []const u8) void {
    if (!is_darwin) return;

    const ns_path = makeNSString(path) orelse {
        std.log.warn("location recording: could not make an NSString for '{s}'; file attributes not applied", .{path});
        return;
    };

    setProtection(ns_path, path);
    excludeFromBackup(ns_path, path);
}

/// `NSFileProtectionKey` → `NSFileProtectionCompleteUntilFirstUserAuthentication`.
///
/// Both names are `extern NSString * const`, so their values are not in any
/// header and are read out of whatever loaded Foundation rather than spelled
/// out here — the same `dlsym` route `bestAccuracy` takes in
/// `bridge_mobile_location.zig`.
fn setProtection(ns_path: Id, path: []const u8) void {
    const key = nsStringConstant("NSFileProtectionKey") orelse {
        std.log.warn("location recording: NSFileProtectionKey is not in this process; '{s}' is unprotected", .{path});
        return;
    };
    const value = nsStringConstant("NSFileProtectionCompleteUntilFirstUserAuthentication") orelse {
        std.log.warn("location recording: NSFileProtectionCompleteUntilFirstUserAuthentication is not in this process; '{s}' is unprotected", .{path});
        return;
    };

    const NSDictionary = objc.objc_getClass("NSDictionary") orelse return;
    const sel_dict = objc.sel_registerName("dictionaryWithObject:forKey:") orelse return;
    const attributes = objc.msgSendId2(NSDictionary, sel_dict, value, key) orelse return;

    const NSFileManager = objc.objc_getClass("NSFileManager") orelse return;
    const sel_default = objc.sel_registerName("defaultManager") orelse return;
    const manager = objc.msgSendId(NSFileManager, sel_default) orelse return;

    const sel_set = objc.sel_registerName("setAttributes:ofItemAtPath:error:") orelse return;
    const SetFn = *const fn (Id, Id, Id, Id, ?*anyopaque) callconv(.c) bool;
    const set: SetFn = @ptrCast(&objc.objc_msgSend);

    if (!set(manager, sel_set, attributes, ns_path, null)) {
        std.log.warn("location recording: setAttributes: refused for '{s}'; the file is readable before first unlock", .{path});
    }
}

/// `NSURLIsExcludedFromBackupKey` = YES, via `NSURL`.
fn excludeFromBackup(ns_path: Id, path: []const u8) void {
    const key = nsStringConstant("NSURLIsExcludedFromBackupKey") orelse {
        std.log.warn("location recording: NSURLIsExcludedFromBackupKey is not in this process; '{s}' will be backed up", .{path});
        return;
    };

    const NSURL = objc.objc_getClass("NSURL") orelse return;
    const sel_file_url = objc.sel_registerName("fileURLWithPath:") orelse return;
    const url = objc.msgSendId1(NSURL, sel_file_url, ns_path) orelse return;

    const NSNumber = objc.objc_getClass("NSNumber") orelse return;
    const sel_with_bool = objc.sel_registerName("numberWithBool:") orelse return;
    const WithBoolFn = *const fn (Id, Id, bool) callconv(.c) Id;
    const with_bool: WithBoolFn = @ptrCast(&objc.objc_msgSend);
    const yes = with_bool(NSNumber, sel_with_bool, true) orelse return;

    const sel_set = objc.sel_registerName("setResourceValue:forKey:error:") orelse return;
    const SetFn = *const fn (Id, Id, Id, Id, ?*anyopaque) callconv(.c) bool;
    const set: SetFn = @ptrCast(&objc.objc_msgSend);

    if (!set(url, sel_set, yes, key, null)) {
        std.log.warn("location recording: setResourceValue: refused for '{s}'; the recording will be included in backups", .{path});
    }
}

/// Read an `extern NSString * const` out of the loaded frameworks.
///
/// The symbol is the *cell*, not the string: dereference it to get the object.
fn nsStringConstant(name: [*:0]const u8) ?Id {
    const symbol = dlsym(RTLD_DEFAULT, name) orelse return null;
    const cell: *const Id = @ptrCast(@alignCast(symbol));
    return cell.*;
}

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// dyld's "search every image" pseudo-handle, (void *)-2 on Darwin.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// An autoreleased `NSString` for a Zig slice, via `stringWithUTF8String:`.
fn makeNSString(text: []const u8) ?Id {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (text.len >= buf.len) return null;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;

    const NSString = objc.objc_getClass("NSString") orelse return null;
    const sel = objc.sel_registerName("stringWithUTF8String:") orelse return null;
    return objc.msgSendId1(NSString, sel, @as([*:0]const u8, @ptrCast(&buf)));
}

// =============================================================================
// Tests.
//
// Everything that decides what the page sees is pure and pinned here: routing
// in both directions, the five deliberate omissions, the ignored payload, and
// the whole of the shaping — bare array, verbatim bytes, extreme magnitudes,
// the line-level drops, and the round trip back through a JSON parser.
//
// The filesystem tier runs on every platform against a real file this test
// writes, so the missing-file, empty-file, torn-tail and shrink cases are
// exercised for real rather than described. The one Darwin-only tier resolves
// the app container path through live Objective-C. Nothing anywhere writes to
// the recorder's own files: this module is a reader, and a test that created
// `~/Library/Application Support/craft-location-recording.jsonl` on a
// developer's machine would be inventing a recording.
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 1), capability_actions.len);
    try testing.expectEqualStrings(A.read_location_recording, capability_actions[0].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        // `.reason` is only meaningful on an `.unavailable` row; a stray one
        // here would be shown to an app about an action that works.
        try testing.expect(decl.reason == null);
    }
}

test "the action name matches the Swift case label exactly" {
    // The conformance ratchet compares this against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("readLocationRecording", A.read_location_recording);
}

test "every declared action is one the dispatcher routes" {
    for (capability_actions) |decl| {
        if (routeFor(decl.name) == null) {
            std.debug.print("declared action '{s}' does not route\n", .{decl.name});
            return error.DeclaredActionDoesNotRoute;
        }
    }
}

test "every route the dispatcher has is a declared action" {
    // The other direction: a route with a handler and no declaration is an
    // action the page can call and the manifest denies exists. Each declaration
    // must claim a *distinct* route — counting alone would let two rows share
    // one route while another went undeclared.
    var claimed = std.mem.zeroes([std.enums.values(Route).len]bool);
    for (capability_actions) |decl| {
        const route = routeFor(decl.name) orelse return error.DeclaredActionDoesNotRoute;
        const slot = @backingInt(route);
        if (claimed[slot]) {
            std.debug.print("two declarations route to {s}\n", .{@tagName(route)});
            return error.TwoDeclarationsShareARoute;
        }
        claimed[slot] = true;
    }
    for (claimed, 0..) |taken, slot| {
        if (!taken) {
            std.debug.print(
                "route {s} has a handler but no capability_actions row\n",
                .{@tagName(@as(Route, @fromBackingInt(@intCast(slot))))},
            );
            return error.RouteNotDeclared;
        }
    }
}

test "the five stateful recording actions belong to the manager's module, not this one" {
    // Not a deferral any more — an ownership boundary, asserted from this side
    // so it cannot quietly become an overlap.
    //
    // `ios_dispatch` routes first-match, so two modules answering one action
    // would make the answer depend on the order of the module list. The five
    // lifecycle actions need the `CLLocationManager` and the delegate, which
    // live in `bridge_mobile_location.zig`; this file owns the two files they
    // read and write. `bridge_mobile_location.zig` asserts the converse.
    const unserved = [_][]const u8{
        "startLocationRecording",
        "pauseLocationRecording",
        "resumeLocationRecording",
        "stopLocationRecording",
        "getLocationRecordingState",
    };

    var bridge = LocationRecordingBridge.init(testing.allocator);
    defer bridge.deinit();

    for (unserved) |action| {
        try testing.expect(routeFor(action) == null);
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(action, "{}"),
        );
        for (capability_actions) |decl| {
            try testing.expect(!std.mem.eql(u8, decl.name, action));
        }
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = LocationRecordingBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Near misses — casing is how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("readlocationrecording", "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("ReadLocationRecording", "{}"),
    );
    // The JS surface method names, which are not action names.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("readRecording", "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("getRecordingState", "{}"),
    );
    // The Swift *helper* name, which is not a dispatcher case.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("loadRecordedLocations", "{}"),
    );
    // The sibling namespace's actions, which other modules serve.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("getCurrentPosition", "{}"),
    );
}

/// Run the served action and report only whether it failed, and how.
///
/// The payload tests below compare *outcomes* rather than pinning one, because
/// the outcome legitimately differs by platform: off Darwin there is no app
/// container to look in, and on a Darwin host the answer depends on whether the
/// developer happens to have a track file. What must not differ is the effect
/// of the payload, which is none.
fn outcomeFor(data: []const u8) ?anyerror {
    var bridge = LocationRecordingBridge.init(testing.allocator);
    defer bridge.deinit();

    bridge.handleMessage(A.read_location_recording, data) catch |err| return err;
    return null;
}

test "the payload is ignored, exactly as Swift ignores it" {
    // The injected JS posts `{action:'readLocationRecording', callbackId: id}`
    // and nothing else, and the Swift dispatcher reads nothing out of `body`.
    // A handler that parsed `d` would turn the malformed case into an
    // `INVALID_JSON` rejection for a call Swift answers — which is why these
    // are asserted *equal* rather than each asserted successful. A parsing
    // handler fails this test on every platform.
    const baseline = outcomeFor("{}");

    try testing.expectEqual(baseline, outcomeFor("{\"callbackId\":\"cb_7\"}"));
    try testing.expectEqual(baseline, outcomeFor("{not json"));
    try testing.expectEqual(baseline, outcomeFor("[]"));
    try testing.expectEqual(baseline, outcomeFor("null"));
    try testing.expectEqual(baseline, outcomeFor("{\"enableHighAccuracy\":true,\"timeout\":5000}"));
}

test "off Darwin the handler refuses rather than answering an empty recording" {
    if (is_darwin) return error.SkipZigTest;

    // Notably *not* `[]`: off Darwin there is no app container, so nothing
    // looked for a track file and "there are no samples" would be a claim
    // nothing checked.
    var bridge = LocationRecordingBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        error.UnsupportedPlatform,
        bridge.handleMessage(A.read_location_recording, "{}"),
    );
    try testing.expectError(error.UnsupportedPlatform, applicationSupportPath(testing.allocator));
}

// -----------------------------------------------------------------------------
// Shaping.
// -----------------------------------------------------------------------------

fn expectShape(text: []const u8, expected: []const u8) !void {
    const json = try shapeRecording(testing.allocator, text);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(expected, json);
}

/// One real sample, with the eight keys and the value magnitudes the recorder
/// actually writes: `CraftApp.swift:3072-3081`, a fix in Cupertino.
const real_sample =
    "{\"latitude\":37.33182,\"longitude\":-122.03118,\"altitude\":12.5," ++
    "\"accuracy\":5,\"altitudeAccuracy\":3,\"heading\":-1,\"speed\":-1," ++
    "\"timestamp\":1700000000000}";

test "an empty or absent recording is the bare array, not null and not a wrapper" {
    // `loadRecordedLocations()` returns `[]` for a missing file, and
    // `startLocationRecording` truncates the track with `Data().write`, so a
    // zero-byte file is the normal state of a recording that has not yet taken
    // a fix.
    try expectShape("", empty_array);
    try expectShape("\n", empty_array);
    try expectShape("\n\n\n", empty_array);
    try testing.expectEqualStrings("[]", empty_array);
}

test "the reply is a bare array of the recorded samples, not a wrapper object" {
    // The rule-4 regression test. `resolveCallback` serialises with
    // `.fragmentsAllowed`, which permits a bare value and never wraps a
    // container — so `readLocationRecording` resolves `[{…}]`. A
    // `{"locations":[…]}` shape is `stopLocationRecording`'s, a different
    // action this module does not serve, and `{"samples":…}` is nobody's.
    const json = try shapeRecording(testing.allocator, real_sample ++ "\n");
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("[" ++ real_sample ++ "]", json);
    try testing.expectEqual(@as(u8, '['), json[0]);
    try testing.expectEqual(@as(u8, ']'), json[json.len - 1]);
    try testing.expect(std.mem.indexOf(u8, json, "locations") == null);
    try testing.expect(std.mem.indexOf(u8, json, "samples") == null);
    // `sampleCount` belongs to `getLocationRecordingState` alone. The SDK's web
    // fallback adds it to more replies than iOS does; Swift is the contract.
    try testing.expect(std.mem.indexOf(u8, json, "sampleCount") == null);
}

test "every recorded key survives, spelled as the writer spelled it" {
    // `heading` is `-course` and `accuracy` is `-horizontalAccuracy` while
    // `altitudeAccuracy` is `-verticalAccuracy`; conflating any two would be a
    // silently wrong reading rather than a missing one. This module never names
    // the keys, which is exactly why: it copies the writer's bytes.
    const json = try shapeRecording(testing.allocator, real_sample ++ "\n");
    defer testing.allocator.free(json);

    for ([_][]const u8{
        "\"latitude\"",         "\"longitude\"", "\"altitude\"", "\"accuracy\"",
        "\"altitudeAccuracy\"", "\"heading\"",   "\"speed\"",    "\"timestamp\"",
    }) |key| {
        if (std.mem.indexOf(u8, json, key) == null) {
            std.debug.print("shaped reply lost the key {s}\n", .{key});
            return error.RecordedKeyDropped;
        }
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 8), parsed.value.array.items[0].object.count());
}

test "several samples come back in file order, comma separated" {
    try expectShape(
        "{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n",
        "[{\"a\":1},{\"a\":2},{\"a\":3}]",
    );
    // A final line with no trailing newline is still a sample: Swift's `split`
    // yields it, and dropping it would lose the most recent fix — the one a
    // page reading a live recording cares about most.
    try expectShape("{\"a\":1}\n{\"a\":2}", "[{\"a\":1},{\"a\":2}]");
}

test "blank lines are dropped rather than becoming phantom samples" {
    try expectShape("{\"a\":1}\n\n\n{\"a\":2}\n", "[{\"a\":1},{\"a\":2}]");
}

test "a line that is not a JSON object is dropped, as compactMap drops it" {
    // `as? [String: Any]` fails for each of these, and a torn tail line is the
    // reason the drop exists at all. Copying one through would produce an array
    // whose elements are not samples — or, for the unterminated case, bytes
    // that are not JSON.
    try expectShape("[1,2]\n", empty_array);
    try expectShape("\"a string\"\n", empty_array);
    try expectShape("42\n", empty_array);
    try expectShape("true\n", empty_array);
    try expectShape("null\n", empty_array);
    try expectShape("{\"latitude\":37.3\n", empty_array);
    try expectShape("{broken\n", empty_array);
    // And the neighbours survive: a torn tail must not cost the whole track,
    // which is the one behaviour of `loadRecordedLocations()` deliberately not
    // reproduced.
    try expectShape(
        "{\"a\":1}\n{\"a\":2}\n{\"latitude\":37.3",
        "[{\"a\":1},{\"a\":2}]",
    );
}

test "two objects on one line are refused, not concatenated into invalid JSON" {
    // What a torn concurrent write can leave. Copying the line verbatim would
    // emit `[{"a":1} {"b":2}]`, which is not JSON at all — the page's
    // `_resolveCallback` would take a syntax error instead of a result. This is
    // the load-bearing reason the check is a whole-document parse.
    try expectShape("{\"a\":1} {\"b\":2}\n", empty_array);
    try expectShape("{\"a\":1}{\"b\":2}\n", empty_array);
    try expectShape("{\"a\":1},\n", empty_array);
}

test "a repeated key keeps the line, because Foundation and JSON.parse both keep it" {
    // `std.json`'s default is `error.DuplicateField`, which would drop a line
    // `JSONSerialization` accepts — a recorded sample lost to a parser
    // difference rather than to anything wrong with the sample. The bytes go
    // out untouched and the page's `JSON.parse` resolves it last-wins, which
    // is the value Swift would have handed over.
    try expectShape(
        "{\"latitude\":1,\"latitude\":2}\n",
        "[{\"latitude\":1,\"latitude\":2}]",
    );
    // And it still has to be an object: a repeated key does not rescue a line
    // that is not one.
    try expectShape("[1,1]\n", empty_array);
}

test "a line that is not valid UTF-8 is dropped without costing its neighbours" {
    // Swift's `String(contentsOf:encoding:)` returns nil for the whole file
    // here, so a single torn multi-byte sequence loses a track of real fixes.
    // Per line, the torn line alone is lost.
    const torn = "{\"a\":1}\n{\"b\":\"\xff\xfe\"}\n{\"a\":2}\n";
    try expectShape(torn, "[{\"a\":1},{\"a\":2}]");

    // Whatever survives is valid UTF-8, because it lands in a JavaScript source
    // position.
    const json = try shapeRecording(testing.allocator, torn);
    defer testing.allocator.free(json);
    try testing.expect(std.unicode.utf8ValidateSlice(json));
}

test "non-ASCII in a sample is carried through byte for byte" {
    // Nothing in the recorder writes text today, but a native app appending its
    // own annotated samples would, and re-encoding is how a bridge loses an
    // accent.
    try expectShape(
        "{\"note\":\"caf\u{00e9} \u{1f4cd}\"}\n",
        "[{\"note\":\"caf\u{00e9} \u{1f4cd}\"}]",
    );
}

test "the shaped reply always parses back as an array of objects" {
    // The property that makes echoing raw bytes safe: whatever comes out is
    // JSON, and it is the array shape the page destructures.
    const text = real_sample ++ "\n" ++ real_sample ++ "\n[1,2]\n\n" ++ real_sample ++ "\n";
    const json = try shapeRecording(testing.allocator, text);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value == .array);
    try testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
    for (parsed.value.array.items) |item| {
        try testing.expect(item == .object);
    }
}

test "extreme magnitudes survive verbatim, with no formatting buffer to overflow" {
    // The doubles hazard, and why this module has no float formatting at all.
    //
    // A sample is eight f64s. Re-rendering one with `{d}` needs up to
    // `std.fmt.float.bufferSize(.decimal, f64)` bytes *per field* — 1e300 is
    // 301 digits — so a `[64]u8` would turn a legal sample into a NoSpaceLeft
    // refusal, and a rounded re-render would report a different position than
    // the device recorded. Copying the recorded bytes has neither failure mode,
    // and that is asserted here rather than asserted about.
    try testing.expect(std.fmt.float.bufferSize(.decimal, f64) > 300);

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(testing.allocator);
    try line.appendSlice(testing.allocator, "{\"latitude\":1");
    try line.appendNTimes(testing.allocator, '0', 300);
    try line.appendSlice(testing.allocator, ",\"speed\":-1.7976931348623157e+308}");

    const json = try shapeRecording(testing.allocator, line.items);
    defer testing.allocator.free(json);

    try testing.expect(json.len > 300);
    try testing.expectEqualStrings("[", json[0..1]);
    try testing.expectEqualStrings(line.items, json[1 .. json.len - 1]);

    // And the digits are the recorded digits, not a rounded re-render.
    try testing.expect(std.mem.indexOf(u8, json, "-1.7976931348623157e+308") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
}

test "a magnitude no f64 can hold is carried rather than rounded or dropped" {
    // `std.json` parses `1e400` into `.number_string`, keeping the source token
    // because no f64 holds it. Rendering it through `{d}` would emit `inf`,
    // which is not JSON; dropping the line would lose a sample. The bytes go
    // through untouched, which is both valid JSON and the only lossless answer.
    try expectShape(
        "{\"altitude\":1e400,\"latitude\":99999999999999999999}\n",
        "[{\"altitude\":1e400,\"latitude\":99999999999999999999}]",
    );
}

test "a sample carrying a quote or a backslash is not escaped twice" {
    // The recorded line is already JSON. Escaping it again on the way out —
    // which is what building the reply by string concatenation would do — turns
    // `"a\"b"` into a different string. This is the bridge_iap.zig failure in a
    // different place, and copying bytes is what makes it impossible.
    try expectShape(
        "{\"note\":\"a\\\"b\\\\c\"}\n",
        "[{\"note\":\"a\\\"b\\\\c\"}]",
    );
}

test "shaping does not choke on a large track" {
    // 5,000 real samples, which is about ninety minutes of recording. The
    // ArrayList growth path and the per-line parse both run; a quadratic or
    // fixed-buffer implementation shows up here.
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        try text.appendSlice(testing.allocator, real_sample);
        try text.append(testing.allocator, '\n');
    }

    const json = try shapeRecording(testing.allocator, text.items);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 5000), parsed.value.array.items.len);
}

// -----------------------------------------------------------------------------
// The filesystem tier — a real file, on every platform.
// -----------------------------------------------------------------------------

/// A file this test owns, in the working directory, named so it cannot collide
/// with the recorder's own track. Never `<AppSupport>/craft-location-recording.jsonl`:
/// creating that on a developer's machine would be inventing a recording.
const test_track_name = "craft-locrecording-test-track.jsonl";

fn writeTestTrack(contents: []const u8) !void {
    const io = io_context.get();
    const file = try std.Io.Dir.cwd().createFile(io, test_track_name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn removeTestTrack() void {
    std.Io.Dir.cwd().deleteFile(io_context.get(), test_track_name) catch |err| {
        std.log.debug("locrecording test track cleanup failed: {}", .{err});
    };
}

test "a missing track file reads as null, which is the only route to []" {
    // Null and "empty file" are different states that give the same answer, and
    // every *other* failure gives a different one. This pins the first half.
    const missing = try readTrackBytes(testing.allocator, "craft-locrecording-no-such-file.jsonl");
    try testing.expect(missing == null);
}

test "a real track file round-trips from disk to the page's array" {
    try writeTestTrack(real_sample ++ "\n" ++ real_sample ++ "\n");
    defer removeTestTrack();

    const text = try readTrackBytes(testing.allocator, test_track_name) orelse
        return error.TrackFileVanished;
    defer testing.allocator.free(text);

    const json = try shapeRecording(testing.allocator, text);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("[" ++ real_sample ++ "," ++ real_sample ++ "]", json);
}

test "a zero-byte track file is [] and not an error" {
    // `startLocationRecording` truncates the track before the first fix
    // arrives, so this is the normal state of a recording in progress.
    try writeTestTrack("");
    defer removeTestTrack();

    const text = try readTrackBytes(testing.allocator, test_track_name) orelse
        return error.TrackFileVanished;
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 0), text.len);

    try expectShape(text, empty_array);
}

test "a track whose last line is torn keeps every complete sample before it" {
    // A crash between `seekToEnd` and the end of `write` leaves exactly this.
    try writeTestTrack(real_sample ++ "\n" ++ real_sample ++ "\n{\"latitude\":37.3,\"longi");
    defer removeTestTrack();

    const text = try readTrackBytes(testing.allocator, test_track_name) orelse
        return error.TrackFileVanished;
    defer testing.allocator.free(text);

    const json = try shapeRecording(testing.allocator, text);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}

test "a directory where the track should be is an error, never an empty recording" {
    // The rule-1 case for the reader. Swift's `try?` answers `[]` for every
    // failure alike; telling a page its route is empty when the read failed is
    // a wrong answer delivered as a right one.
    const io = io_context.get();
    const dir_name = "craft-locrecording-test-dir.jsonl";
    std.Io.Dir.cwd().createDirPath(io, dir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.SkipZigTest,
    };
    defer std.Io.Dir.cwd().deleteDir(io, dir_name) catch {};

    try testing.expectError(
        bridge_error.BridgeError.NativeCallFailed,
        readTrackBytes(testing.allocator, dir_name),
    );
}

// -----------------------------------------------------------------------------
// The Darwin tier — live Objective-C, read-only.
// -----------------------------------------------------------------------------

test "the app container path resolves through live Objective-C" {
    if (!is_darwin) return error.SkipZigTest;

    // `NSFileManager` → `URLsForDirectory:inDomains:` → `firstObject` → `path`,
    // for real. On a macOS host this is `~/Library/Application Support`; in the
    // app it is the container's. Either way it must be an absolute path, or the
    // track file lookup below is relative to whatever the process's cwd happens
    // to be — which on iOS is `/`.
    const dir = try applicationSupportPath(testing.allocator);
    defer testing.allocator.free(dir);

    try testing.expect(dir.len > 0);
    try testing.expectEqual(@as(u8, '/'), dir[0]);
    try testing.expect(dir[dir.len - 1] != '/');
    try testing.expect(std.mem.indexOfScalar(u8, dir, 0) == null);
}

test "the track path is the file the Swift recorder appends to" {
    if (!is_darwin) return error.SkipZigTest;

    // `locationRecordingTrackURL` puts it directly in Application Support with
    // no per-app subdirectory. Reading anywhere else answers `[]` for a
    // recording that exists.
    const path = try trackFilePath(testing.allocator);
    defer testing.allocator.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "/craft-location-recording.jsonl"));
    try testing.expectEqual(@as(u8, '/'), path[0]);

    // And it is *not* the state file, which holds the summary shape this module
    // does not serve.
    try testing.expect(std.mem.indexOf(u8, path, "craft-location-recording-state.json") == null);
}

test "with no recording on the host, the handler answers rather than failing" {
    if (!is_darwin) return error.SkipZigTest;

    const path = try trackFilePath(testing.allocator);
    defer testing.allocator.free(path);

    // The developer's own machine decides this one: with a track file present
    // there is nothing deterministic to assert, and reading it is still safe
    // but proves less.
    if (try readTrackBytes(testing.allocator, path)) |existing| {
        testing.allocator.free(existing);
        return error.SkipZigTest;
    }

    // This runs a handler all the way to `sendResultToJS`, so it logs one
    // "failed to send bridge result to JS" warning: there is no webview in a
    // test runner. That warning is the evidence the reply was attempted — the
    // alternative, asserting only that no error came back, would also pass for
    // a handler that returned without replying at all.
    var bridge = LocationRecordingBridge.init(testing.allocator);
    defer bridge.deinit();

    try bridge.handleMessage(A.read_location_recording, "{}");
}

// =============================================================================
// The on-disk format.
//
// The guard in `decodeState` is the one that closes the third of the three
// blockers #124 lists, so it is pinned from both sides: a stopped recording's
// leftovers must read back as nothing, and a live one must read back whole.
// Everything here runs against bytes or against a file this test owns; nothing
// touches `~/Library/Application Support`.
// =============================================================================

const test_state_name = "craft-locrecording-test-state.json";

fn writeTestFile(name: []const u8, contents: []const u8) !void {
    const io = io_context.get();
    const file = try std.Io.Dir.cwd().createFile(io, name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn removeTestFile(name: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io_context.get(), name) catch |err| {
        std.log.debug("locrecording test file cleanup failed: {}", .{err});
    };
}

test "a stopped recording's leftovers read back as no recording at all" {
    // The exact divergence #124's third blocker names. `stopLocationRecording`
    // sets `active:false` but leaves `id` and `startedAt` in the file, and
    // Swift's `guard state["active"] as? Bool == true else { return }` means a
    // relaunch after a stop restores nothing. A reader that handed back the id
    // would answer `{"id":"ABC-123"}` where Swift answers `{"id":null}`.
    var state = try decodeState(
        testing.allocator,
        \\{"active":false,"paused":false,"id":"ABC-123","startedAt":1756900000000}
    );
    defer state.deinit(testing.allocator);

    try testing.expect(!state.active);
    try testing.expect(!state.paused);
    try testing.expect(state.id == null);
    try testing.expect(state.started_at == null);
}

test "an active recording restores all four fields" {
    var state = try decodeState(
        testing.allocator,
        \\{"active":true,"paused":true,"id":"ABC-123","startedAt":1756900000000}
    );
    defer state.deinit(testing.allocator);

    try testing.expect(state.active);
    try testing.expect(state.paused);
    try testing.expectEqualStrings("ABC-123", state.id.?);
    try testing.expectEqual(@as(f64, 1756900000000), state.started_at.?);
}

test "the active guard is a Bool cast, not a truthiness test" {
    // `as? Bool` fails for each of these, and every failure lands on the same
    // `return`. A JSON reader that coerced would restore a recording Swift
    // does not.
    const not_bools = [_][]const u8{
        \\{"active":"true","id":"ABC","startedAt":1}
        ,
        \\{"active":1,"id":"ABC","startedAt":1}
        ,
        \\{"active":null,"id":"ABC","startedAt":1}
        ,
        \\{"paused":false,"id":"ABC","startedAt":1}
        ,
        \\["active",true]
        ,
        \\not json at all
        ,
    };

    for (not_bools) |document| {
        var state = try decodeState(testing.allocator, document);
        defer state.deinit(testing.allocator);
        try testing.expect(!state.active);
        try testing.expect(state.id == null);
        try testing.expect(state.started_at == null);
    }
}

test "past the guard a wrong type is a default, not a refusal" {
    // Swift's remaining reads are `as? Bool ?? false`, `as? String` and
    // `as? TimeInterval`, all of which degrade rather than throw.
    var state = try decodeState(
        testing.allocator,
        \\{"active":true,"paused":"yes","id":42,"startedAt":"soon"}
    );
    defer state.deinit(testing.allocator);

    try testing.expect(state.active);
    try testing.expect(!state.paused);
    try testing.expect(state.id == null);
    try testing.expect(state.started_at == null);
}

test "the encoded state carries the four keys Swift's decoder looks for" {
    const encoded = try encodeState(testing.allocator, .{
        .active = true,
        .paused = false,
        .id = "ABC-123",
        .started_at = 1756900000000,
    });
    defer testing.allocator.free(encoded);

    try testing.expectEqualStrings(
        \\{"active":true,"paused":false,"id":"ABC-123","startedAt":1756900000000}
    , encoded);
}

test "a recording that has never started encodes its nulls, not empty strings" {
    const encoded = try encodeState(testing.allocator, .{});
    defer testing.allocator.free(encoded);

    try testing.expectEqualStrings(
        \\{"active":false,"paused":false,"id":null,"startedAt":null}
    , encoded);
}

test "state survives a round trip through the encoder and the guard" {
    const encoded = try encodeState(testing.allocator, .{
        .active = true,
        .paused = true,
        .id = "route-9",
        .started_at = 1756900123456,
    });
    defer testing.allocator.free(encoded);

    var state = try decodeState(testing.allocator, encoded);
    defer state.deinit(testing.allocator);

    try testing.expect(state.active);
    try testing.expect(state.paused);
    try testing.expectEqualStrings("route-9", state.id.?);
    try testing.expectEqual(@as(f64, 1756900123456), state.started_at.?);
}

test "an id with quotes in it survives rather than tearing the document" {
    const encoded = try encodeState(testing.allocator, .{
        .active = true,
        .id = "a\"b\\c",
    });
    defer testing.allocator.free(encoded);

    var state = try decodeState(testing.allocator, encoded);
    defer state.deinit(testing.allocator);

    try testing.expectEqualStrings("a\"b\\c", state.id.?);
}

test "a missing state file is no recording, not an error" {
    removeTestFile(test_state_name);

    var state = try readStateFrom(testing.allocator, test_state_name);
    defer state.deinit(testing.allocator);

    try testing.expect(!state.active);
}

test "appended samples land one per line, byte for byte" {
    removeTestFile(test_track_name);
    defer removeTestFile(test_track_name);

    // The track has to exist first: `FileHandle(forWritingTo:)` throws when it
    // does not, and appending would otherwise start a route nobody asked for.
    try writeTestFile(test_track_name, "");

    try appendSampleTo(testing.allocator, test_track_name, "{\"latitude\":1.5}");
    try appendSampleTo(testing.allocator, test_track_name, "{\"latitude\":2.5}");

    const text = try readTrackBytes(testing.allocator, test_track_name) orelse
        return error.TestExpectedTrack;
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("{\"latitude\":1.5}\n{\"latitude\":2.5}\n", text);
}

test "appending to a track that is not there loses the sample rather than creating one" {
    removeTestFile(test_track_name);

    // No recording is running, so there is no route for this fix to join.
    // Creating the file here would invent one.
    try testing.expectError(
        bridge_error.BridgeError.NativeCallFailed,
        appendSampleTo(testing.allocator, test_track_name, "{\"latitude\":1.5}"),
    );
}

test "the sample count agrees with the reader, drop for drop" {
    removeTestFile(test_track_name);
    defer removeTestFile(test_track_name);

    // `getLocationRecordingState` reports `loadRecordedLocations().count`, so a
    // blank line and a non-object have to be uncounted here exactly as they are
    // unread there — otherwise the page is told it has fixes it cannot read.
    try writeTestFile(test_track_name,
        \\{"latitude":1}
        \\
        \\[1,2]
        \\{"latitude":2}
        \\torn-half-
    );

    try testing.expectEqual(@as(usize, 2), try countSamplesIn(testing.allocator, test_track_name));

    const text = try readTrackBytes(testing.allocator, test_track_name) orelse
        return error.TestExpectedTrack;
    defer testing.allocator.free(text);

    const shaped = try shapeRecording(testing.allocator, text);
    defer testing.allocator.free(shaped);

    // Two objects in, two objects out: the count is the reader's own answer.
    try testing.expectEqualStrings("[{\"latitude\":1},{\"latitude\":2}]", shaped);
}

test "an absent track counts zero rather than refusing" {
    removeTestFile(test_track_name);
    try testing.expectEqual(@as(usize, 0), try countSamplesIn(testing.allocator, test_track_name));
}
