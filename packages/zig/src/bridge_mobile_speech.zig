//! The Speech + AVFoundation actions of the `mobile` namespace —
//! `startListening` and `stopListening` — **researched in full and
//! deliberately not served**. Both fall through to the working Swift shim.
//!
//! This is the outcome rule 6 exists for, and it is the cheapest one in the
//! migration: the shim answers both actions exactly as the app answers them
//! today, and — unlike `scheduleNotification`, `registerBackgroundTask` and
//! `sendToWatch` — **there is no promise to strand**, because neither action
//! has a `callbackId` and neither ever replies. Falling through costs the page
//! nothing at all. What is written below is the part a host can honestly
//! finish and pin: the event vocabulary, the four error messages, and the two
//! detail shapers. What is missing is named, not glossed.
//!
//! ## The contract, read rather than assumed
//!
//! **Payload: none, on both actions.** The injected JS is the whole surface
//! (`CraftApp.swift:1562-1568`):
//!
//! ```js
//! startListening: function() {
//!     window.webkit.messageHandlers.craft.postMessage({action: 'startListening'});
//! },
//! stopListening: function() {
//!     window.webkit.messageHandlers.craft.postMessage({action: 'stopListening'});
//! },
//! ```
//!
//! No fields, no `callbackId`, no return value. `ios_dispatch.payloadOf` would
//! hand a handler `"{}"`. There is no second page surface: the nested mobile
//! contract block (`:2297-2427`) has no speech methods, and `craft-bridge.js`
//! has no `mobile` namespace at all — its `window.craft.speech` is desktop TTS
//! over `AVSpeechSynthesizer`, namespace `t = "speech"`, unrelated. So is
//! `bridge_speech_recognition.zig`, which is the desktop `speechRecognition`
//! namespace with actions `isAvailable`/`start`/`stop`; it must not be
//! confused with this one.
//!
//! **Reply: none, on any path.** The dispatcher (`CraftApp.swift:533-536`) is
//!
//! ```swift
//! case "startListening":
//!     if config.enableSpeechRecognition { startSpeechRecognition() }
//! case "stopListening":
//!     stopSpeechRecognition()
//! ```
//!
//! and neither `startSpeechRecognition` (`:2486-2494`), `beginRecording`
//! (`:2496-2548`) nor `stopSpeechRecognition` (`:2550-2559`) touches
//! `resolveCallback`, `rejectCallback` or `resolveCallbackJSON` on any line.
//! `craft.d.ts:188` and `:193` both declare `(): void`, and
//! `test-bridges.html:785-795` awaits nothing. If this module ever serves
//! these, the declaration is `.reply = .none` — the same reading
//! `bridge_mobile_haptics.zig` made for `haptic`, and for the same reason.
//!
//! A denial does not reply either; it **emits**. Nor does the flag-off case
//! emit anything at all: `if config.enableSpeechRecognition { … }` has no
//! `else`, and `stopListening` is ungated and always runs.
//!
//! **Everything is events.** Four names, and the detail of each:
//!
//! | event | detail | when |
//! |---|---|---|
//! | `craftSpeechError` | `{"error":"Not authorized"}` | auth status is not `.authorized` (`:2489`) |
//! | `craftSpeechError` | `{"error":"Audio session failed"}` | `setCategory`/`setActive` threw (`:2507`) |
//! | `craftSpeechError` | `{"error":"Speech recognizer unavailable"}` | request nil, recognizer nil, or not `isAvailable` (`:2515`) |
//! | `craftSpeechError` | `{"error":"Audio engine failed"}` | `audioEngine.start()` threw (`:2546`) |
//! | `craftSpeechStart` | `{}` | after `audioEngine.start()` succeeded (`:2543`) |
//! | `craftSpeechResult` | `{"transcript": String, "isFinal": Bool}` | every partial and every final result (`:2525-2528`) |
//! | `craftSpeechEnd` | `{}` | every `stopSpeechRecognition()` (`:2557`) |
//!
//! The result detail is **exactly two keys**. No `confidence`, no
//! `alternatives`, no `segments`. Three independent consumers agree —
//! `test-bridges.html:384-387` reads `e.detail.transcript` and
//! `e.detail.isFinal`, `packages/ios/README.md:167-176` documents the same
//! pair, and Android emits the same four names with the same keys
//! (`CraftBridge.kt.template:1344-1383`). Unlike motion, there is no
//! doc/implementation mismatch here to report.
//!
//! `sendToWeb` (`:4835-4846`) builds
//! `window.dispatchEvent(new CustomEvent('<name>', {detail: <json>}));` — the
//! same form `ios_events.formatEvent` builds, so the detail bytes below are
//! the bytes that reach `e.detail` on either path.
//!
//! ## Why nothing is served
//!
//! Four blockers. Only the last three are load-bearing; the first is one line
//! of data that would unblock nothing on its own.
//!
//! **1. `craftSpeechStart` cannot be spelled.** `ios_events.Event` carries
//! `.speech_result`, `.speech_error` and `.speech_end`, and no
//! `.speech_start`. Serving `startListening` without it would drop the one
//! event that drives the page's state — `test-bridges.html:380-383` paints
//! "Listening..." from it and from nothing else — so a working session would
//! look to the page exactly like a session that never started. Adding the
//! enum member and its `switch` arm is data rather than mechanism, and the
//! existing test `"every event name is one an iOS page actually subscribes
//! to"` already accepts the shape (`startsWith "craft"`, no colon). It is not
//! left undone because a second file is off limits — landing this module
//! already edits `ios_dispatch.zig`, `build.zig` and
//! `test/ios_conformance_test.zig`. It is left undone because adding it alone
//! serves nothing: blocker 2 stops `startListening` by itself, and an `Event`
//! member no code emits is vocabulary for an event that never fires. So it is
//! precondition 1 below rather than a reason of its own — and a test trips
//! when it lands.
//!
//! **2. The realtime tap has no precedent in this tree.**
//! `-[AVAudioNode installTapOnBus:bufferSize:format:block:]` runs its block on
//! the audio I/O thread, which is not a queue any existing module touches.
//! `bridge_mobile_motion.zig`'s handler is an `NSOperationQueue.mainQueue`
//! callback and is **not** a precedent for it. Swift's
//! `self?.recognitionRequest?.append(buffer)` gets a free ARC retain for the
//! duration of the call; Zig has none, so `stopListening` releasing the
//! request while a tap call is in flight is a use-after-free on a realtime
//! thread. It is solvable — an atomic pointer, never a mutex (priority
//! inversion), plus stop-engine, remove-tap, clear-pointer, never-release
//! ordering — but solving it is building a new foundation, and this round was
//! asked to apply proven ones and to say so instead.
//!
//! **3. The guard the tap needs is asserted, not read.** With no active input
//! route, `-outputFormatForBus:0` yields a format whose `sampleRate` and
//! `channelCount` are 0, and `installTapOnBus:` then raises an
//! `NSException` — which Zig cannot catch, so the process aborts. Swift has
//! the identical crash at `:2535-2538`. The honest port pre-checks the format
//! and refuses with `craftSpeechError`; but that behaviour comes from API
//! knowledge, nothing in this repo documents it, and there is no simulator
//! here to verify it. Shipping an unverified guard against an unreproducible
//! abort is the one place rule 5 and rule 1 meet.
//!
//! **4. Nothing here can test the audio path.** Every host test that could be
//! written for a served version would exercise selector interning and block
//! flags, and nothing of the recognizer, the session, the engine or the tap.
//! That is a served action whose entire risk surface is untested.
//!
//! The gate is *not* among the blockers, because it is solved:
//! `config.enableSpeechRecognition` defaults to `false`
//! (`CraftApp.swift:189`, `packages/ios/src/index.ts:117`) and reaches Zig
//! through nothing, but `packages/ios/src/index.ts:183` writes
//! `NSSpeechRecognitionUsageDescription` from that flag **and nothing else,
//! with no `||`** — the exact-proxy shape `bridge_mobile_motion.zig` already
//! reads. (`NSMicrophoneUsageDescription` at `:184` is
//! `enableSpeechRecognition || enableAudioRecording` and is **not** an exact
//! proxy; it must not be used as the gate.) Here the proxy is mandatory
//! rather than an improvement: without those keys in Info.plist iOS
//! *terminates the process* on the authorization request or on mic access.
//!
//! ## Why falling through, and not `.unavailable`
//!
//! `.unavailable` makes `ios_dispatch` route the action into this module and
//! refuse it. For an action with a pending promise that is a nameable failure
//! and an improvement on silence. Here there is no pending promise on any
//! page surface, so the refusal would surface only as a console log — while
//! taking away a shim path that works completely. That is strictly worse, and
//! it is why `A` below is empty rather than carrying two `.unavailable` rows.
//!
//! Serving only `stopListening` is worse still, and is ruled out for the
//! reason `bridge_mobile_motion.zig` gives: a session started through the shim
//! would meet a Zig stop, which would stop Zig's own null engine and emit
//! `craftSpeechEnd` while Swift's recognizer kept pushing `craftSpeechResult`.
//! Fabricated success at the event layer. Either both or neither; neither.
//!
//! ## What is finished here
//!
//! The two shapers and the four messages — the half of the port that decides
//! page-visible bytes and that a host can pin. This is the precedent
//! `bridge_mobile_haptics.zig` set with `triggerHapticChecked`: the finished
//! half of a blocked action lives next to the admission, tested, so that
//! unblocking it is a small deliberate edit rather than a rewrite.
//!
//! `shapeResultDetail` is worth more than it looks. A transcript is arbitrary
//! spoken text, the detail is inlined into JavaScript source as a literal, and
//! `ios_events.zig`'s own module comment records what happens when a value
//! like that is concatenated with hand-rolled escaping: `bridge_iap.zig:362`
//! "works until a value contains a quote". Swift is safe here only because
//! `JSONSerialization` escapes for it. Any Zig port must, and this one does.
//!
//! ## What a future round still owes
//!
//! Five preconditions, all five, before either action moves into `A`:
//!
//!  1. `.speech_start => "craftSpeechStart"` in `ios_events.Event`.
//!  2. Refuse unless Info.plist carries `NSSpeechRecognitionUsageDescription`
//!     (`bridge_mobile_motion.zig:infoPlistHas` is the shape).
//!  3. Validate `-sampleRate` and `-channelCount` before `installTapOnBus:`,
//!     and emit `craftSpeechError` rather than installing on a zero format.
//!  4. Never release the recognition request while a tap call may be in
//!     flight — atomically clear the pointer after `removeTapOnBus:`, and
//!     prefer leaking one request per session over racing the audio thread.
//!  5. Hop to the main queue with `dispatch_async_f(&_dispatch_main_q, …)`
//!     before touching `AVAudioEngine` from the recognition task handler; it
//!     fires on an internal Speech queue. (`ios_events.emit` needs no hop —
//!     it hops itself.)
//!
//! And two decisions that are decisions, not facts, to be taken out loud:
//!
//!  - **The error-emission divergence.** On a recognition error Swift emits
//!    **no** `craftSpeechError` — `:2530-2532` only calls
//!    `stopSpeechRecognition()`, so the page gets `craftSpeechEnd` and the
//!    `NSError` is discarded entirely. Android *does* emit one
//!    (`CraftBridge.kt.template:1367`). Matching Swift makes a simulator
//!    failure look exactly like a stream that never fires; matching Android
//!    tells the truth but deviates from the emitter contract this migration
//!    preserves. `err_recognition_failed` below is deliberately absent: there
//!    is no Swift string to copy, so inventing one here would prejudge it.
//!  - **`beginRecording` never stops the engine or removes the old tap**
//!    (`:2497-2500` cancels only the task). A second `startListening` while
//!    running installs a second tap on bus 0, which raises on iOS.
//!    Reproducing that bug is not required; stopping first, as
//!    `bridge_mobile_motion.zig` chose to, is the defensible port.
//!
//! Also worth carrying: both `:2544` and `:2558` fire `triggerHaptic("light")`
//! directly, bypassing the `config.enableHaptics` gate the dispatcher applies
//! to `case "haptic"` at `:537`. Swift itself ignores the flag on this path,
//! so firing it from a served port would be faithful rather than a
//! divergence — but `triggerHapticChecked` in `bridge_mobile_haptics.zig` is
//! not `pub`, so reuse needs a visibility change there.
//!
//! ## Nothing in this file touches Objective-C
//!
//! No `objc_getClass`, no `sel_registerName`, no block, no delegate, no
//! `ios_async` ticket — there is no reply to correlate and no framework call
//! to make. So there is nothing to Darwin-gate: the module compiles and its
//! tests run identically on Linux and macOS, which is the one upside of
//! serving nothing.

const std = @import("std");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const ios_events = @import("ios_events.zig");

/// **Empty on purpose.** No action name here means `ios_dispatch` never routes
/// `startListening` or `stopListening` into this module, so both reach the
/// Swift shim that serves them correctly today. See the module comment for the
/// four blockers and the five preconditions.
///
/// `declared_count` is not decoration. `test/ios_conformance_test.zig` scans
/// this block line by line from `pub const A = struct {` to the first bare
/// `};`, and `zig fmt` collapses an empty struct onto one line — after which
/// the scan would never find its terminator and would collect every quoted
/// string in this file as an action name. A non-string member keeps the block
/// two-line-safe under `zig fmt --check`, which CI runs.
pub const A = struct {
    /// How many actions this module claims. Zero, deliberately.
    pub const declared_count: usize = 0;
};

/// Empty, and specifically not two `.unavailable` rows.
///
/// `.unavailable` is for an action that dispatches and refuses — honest when a
/// promise would otherwise hang, wrong here. Neither of these actions has a
/// promise on any page surface, so a refusal would show up only in the
/// console while removing a shim path that works end to end. Declaring
/// nothing is what lets the shim keep answering.
pub const capability_actions = [_]capabilities.ActionDecl{};

/// The two spec actions this module researched and left with the shim.
///
/// Kept as data so the tests can prove both fall through rather than asserting
/// it in prose, and so a future round has the exact spellings in one place.
/// These names deliberately live outside the `A` block: inside it, the
/// conformance scan would read them as served and the ratchet would drop for
/// actions nothing here answers.
pub const unserved_actions = [_][]const u8{ "startListening", "stopListening" };

pub const SpeechBridge = struct {
    /// Held but never used: `ios_dispatch` constructs every mobile bridge with
    /// `init(allocator)` and the shape is the interface. Nothing here
    /// allocates, because nothing here answers.
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    /// Always `UnknownAction` — "not mine, ask the next" — which is what makes
    /// the fall-through work.
    ///
    /// The payload is deliberately never parsed. `ios_dispatch.route` treats
    /// any error other than `UnknownAction` as final and stops the chain, so a
    /// module that parsed first and answered `InvalidJSON` on a malformed
    /// payload would strand an action it does not even serve. That is the
    /// failure this signature is shaped to make impossible, and a test below
    /// pins it with payloads that no parser would accept.
    pub fn handleMessage(_: *Self, action: []const u8, _: []const u8) !void {
        _ = action;
        return bridge_error.BridgeError.UnknownAction;
    }
};

// =============================================================================
// The event vocabulary, as far as it can be spelled today.
// =============================================================================

/// `craftSpeechResult` — the transcript stream.
pub const event_result: ios_events.Event = .speech_result;

/// `craftSpeechError` — every refusal, on every path.
pub const event_error: ios_events.Event = .speech_error;

/// `craftSpeechEnd` — every `stopSpeechRecognition()`, including one that
/// stops nothing.
pub const event_end: ios_events.Event = .speech_end;

/// `craftSpeechStart`, which `ios_events.Event` cannot currently spell.
///
/// A plain string, not an `Event`, because that is the whole point: there is
/// no member to name. Pinned here so the eventual enum arm is copied from the
/// contract rather than retyped from memory.
pub const event_start_name = "craftSpeechStart";

/// The `data: [:]` of `craftSpeechStart` and `craftSpeechEnd` — an empty
/// object, not an empty string and not `null`. `ios_events.formatEvent`
/// inlines the detail as a literal, so `e.detail` must still be an object the
/// page can index into.
pub const empty_detail = "{}";

// -----------------------------------------------------------------------------
// The four `craftSpeechError` messages, verbatim from the Swift.
//
// Verbatim matters: `test-bridges.html:391-394` paints `e.detail.error` into
// the page for a human to read, and `packages/ios/README.md:173-175` documents
// the key as the thing to log. Nothing downstream matches on the text, which
// is exactly why a paraphrase would change what a user reads without changing
// anything a test could see.
// -----------------------------------------------------------------------------

/// `CraftApp.swift:2489` — the authorization status was not `.authorized`.
/// A user declining is this, not a native call failing.
pub const err_not_authorized = "Not authorized";

/// `:2507` — `setCategory:mode:options:error:` or
/// `setActive:withOptions:error:` failed.
pub const err_audio_session = "Audio session failed";

/// `:2515` — the request is nil, the recognizer is nil (the
/// `enableSpeechRecognition` flag was off, `:439-440`), or `-isAvailable` is
/// NO. A simulator commonly answers NO here.
pub const err_recognizer_unavailable = "Speech recognizer unavailable";

/// `:2546` — `-startAndReturnError:` returned NO.
pub const err_audio_engine = "Audio engine failed";

/// Every message the port may emit, in Swift's source order. A future round
/// adding a fifth must add it to Swift's contract first, or document the
/// divergence — see the module comment on the recognition-error case.
pub const error_messages = [_][]const u8{
    err_not_authorized,
    err_audio_session,
    err_recognizer_unavailable,
    err_audio_engine,
};

// =============================================================================
// The detail shapers. Pure, and the bytes are the contract.
// =============================================================================

/// The `detail` of one `craftSpeechError`: `{"error":"<message>"}`.
///
/// Escaped even though all four current messages are plain ASCII, because the
/// escaping is a property of the position — a JSON string inlined into
/// JavaScript source — and not of today's inputs. A fifth message quoting a
/// framework error would otherwise be the bug.
///
/// Caller owns the returned slice.
pub fn shapeErrorDetail(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"error\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, message);
    try out.appendSlice(allocator, "\"}");

    return out.toOwnedSlice(allocator);
}

/// The `detail` of one `craftSpeechResult`:
/// `{"transcript":"<text>","isFinal":<bool>}`.
///
/// Two keys, Swift's two (`CraftApp.swift:2525-2528`), and no third. Swift
/// builds a `Dictionary`, so its own key order is arbitrary and no page can
/// depend on it; one order is fixed here so the bytes are testable.
///
/// `transcript` is escaped because it is arbitrary spoken text landing in a
/// JavaScript source position. An unescaped `"` would not corrupt one field —
/// it would end the object early and make the whole `dispatchEvent` call a
/// syntax error, so the page would see the stream stop rather than see a bad
/// transcript. That is the failure `ios_events.zig` records against
/// `bridge_iap.zig:362`, and the reason Swift is safe here is only that
/// `JSONSerialization` escapes on its behalf.
///
/// `isFinal` is a real JSON boolean, never the string `"true"`: the page
/// interpolates it into a template literal (`test-bridges.html:386`), where a
/// quoted `"false"` would render as `false` and read as correct while being a
/// truthy value to any code that branches on it.
///
/// An empty transcript still emits the key. Swift always writes it — a first
/// partial result can legitimately be empty — and omitting it would make
/// `e.detail.transcript` `undefined`, which a page cannot tell from a broken
/// bridge.
///
/// Caller owns the returned slice.
pub fn shapeResultDetail(
    allocator: std.mem.Allocator,
    transcript: []const u8,
    is_final: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"transcript\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, transcript);
    try out.appendSlice(allocator, "\",\"isFinal\":");
    try out.appendSlice(allocator, if (is_final) "true" else "false");
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Tests.
//
// Two things are under test. First, that this module really does serve
// nothing — declaring nothing is only half of it, since a module that
// answered anything other than `UnknownAction` would break the fall-through
// even with an empty table. Second, the finished half: the event names and the
// two detail shapers, whose bytes are what a page reads.
//
// Nothing here is Darwin-gated, because nothing in this file touches
// Objective-C.
// =============================================================================

const testing = std.testing;

test "this module declares no actions, so both fall through to the shim" {
    // Table -> dispatch, with the table empty. The shim serves both actions
    // correctly today and neither has a promise to strand, so an empty table
    // is the whole feature: `ios_dispatch.route` never enters this module and
    // `handOffToHost` answers.
    try testing.expectEqual(@as(usize, 0), capability_actions.len);
    try testing.expectEqual(@as(usize, 0), A.declared_count);
}

test "the two unserved actions are the spec's, spelled exactly" {
    // The spelling a future round will move into `A`. Pinned here so the move
    // is a copy rather than a retype — `startlistening` would route nowhere and
    // look exactly like this module still not serving it.
    try testing.expectEqual(@as(usize, 2), unserved_actions.len);
    try testing.expectEqualStrings("startListening", unserved_actions[0]);
    try testing.expectEqualStrings("stopListening", unserved_actions[1]);
}

test "neither unserved action is in the action table" {
    // The invariant that keeps the ratchet honest. An action listed in `A`
    // counts as migrated to `test/ios_conformance_test.zig` whether or not
    // anything answers it, so a name leaking from `unserved_actions` into the
    // table would lower the ratchet for work nobody did.
    for (unserved_actions) |name| {
        for (capability_actions) |decl| {
            try testing.expect(!std.mem.eql(u8, decl.name, name));
        }
    }
}

test "handleMessage refuses everything, including the actions it researched" {
    // Dispatch -> table, with both empty. `UnknownAction` is the only error
    // `ios_dispatch.route` reads as "not mine, ask the next"; any other error
    // is treated as final and would stop the chain before the shim.
    var bridge = SpeechBridge.init(testing.allocator);
    defer bridge.deinit();

    const E = bridge_error.BridgeError;

    for (unserved_actions) |name| {
        try testing.expectError(E.UnknownAction, bridge.handleMessage(name, "{}"));
    }

    // Casing, near misses, and the neighbouring namespaces' spellings — the
    // desktop `speechRecognition` actions in particular, which are a different
    // namespace and must never be answered from here.
    for ([_][]const u8{
        "startlistening",
        "StartListening",
        "startListen",
        "listen",
        "start",
        "stop",
        "isAvailable",
        "speak",
        "startMotionUpdates",
        "getDeviceInfo",
        "",
    }) |name| {
        try testing.expectError(E.UnknownAction, bridge.handleMessage(name, "{}"));
    }
}

test "no payload can turn the fall-through into a final error" {
    // The subtle way a serve-nothing module breaks the thing it is protecting.
    // `ios_dispatch.route` stops the chain on any error but `UnknownAction`, so
    // a module that parsed its payload before routing would answer
    // `InvalidJSON` for a malformed one and strand an action it does not
    // serve — the page would get a rejection where the shim would have worked.
    var bridge = SpeechBridge.init(testing.allocator);
    defer bridge.deinit();

    const E = bridge_error.BridgeError;

    for ([_][]const u8{
        "{not json",
        "",
        "null",
        "[1,2,3]",
        "{\"transcript\":\"hello\"}",
        "{\"callbackId\":\"cb_7\"}",
    }) |payload| {
        for (unserved_actions) |name| {
            try testing.expectError(E.UnknownAction, bridge.handleMessage(name, payload));
        }
    }
}

test "the three spellable events are the ones the page subscribes to" {
    // `test-bridges.html:384`, `:388`, `:391`, and Swift's `sendToWeb` call
    // sites. camelCase, no colon — the iOS vocabulary, which is why
    // `ios_events.Event` exists separately from `capabilities.Channel`.
    try testing.expectEqualStrings("craftSpeechResult", event_result.eventName());
    try testing.expectEqualStrings("craftSpeechError", event_error.eventName());
    try testing.expectEqualStrings("craftSpeechEnd", event_end.eventName());

    // And no desktop channel can spell any of them, so emitting through
    // `capabilities.Channel` would fire events with no subscriber.
    for (std.enums.values(capabilities.Channel)) |channel| {
        try testing.expect(!std.mem.eql(u8, channel.eventName(), event_result.eventName()));
        try testing.expect(!std.mem.eql(u8, channel.eventName(), event_error.eventName()));
        try testing.expect(!std.mem.eql(u8, channel.eventName(), event_end.eventName()));
        try testing.expect(!std.mem.eql(u8, channel.eventName(), event_start_name));
    }
    // Non-vacuity: the loop above proves nothing over an empty enum.
    try testing.expect(std.enums.values(capabilities.Channel).len >= 40);
}

test "craftSpeechStart is still unspellable, which is blocker one" {
    // A tripwire, not a preference. This module's first blocker is that
    // `ios_events.Event` has no `.speech_start`, and the moment somebody adds
    // it precondition 1 is met — which should be noticed here, in the file
    // that documents it, rather than in a later round rediscovering the
    // research. Blockers 2-4 still stand on their own, so this trip is a
    // prompt to re-read them, never a clearance to serve.
    if (@hasField(ios_events.Event, "speech_start")) {
        std.debug.print(
            "ios_events.Event now has .speech_start, so blocker 1 in " ++
                "bridge_mobile_speech.zig is lifted.\n" ++
                "  Emit it through the enum, delete event_start_name, and work " ++
                "through preconditions 2-5 before moving either action into `A`.\n",
            .{},
        );
        return error.SpeechStartBlockerLifted;
    }

    // Until then the name exists only as a string, and it is the right one.
    try testing.expectEqualStrings("craftSpeechStart", event_start_name);
}

test "start and end carry an empty object, not an empty string" {
    // `data: [:]` through `JSONSerialization` is `{}`. `ios_events.formatEvent`
    // inlines the detail as a literal, so `""` would produce
    // `{detail:}` — a syntax error that takes the whole event with it — and
    // `"null"` would make `e.detail` null where the page expects an object.
    try testing.expectEqualStrings("{}", empty_detail);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, empty_detail, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.count());
}

// -----------------------------------------------------------------------------
// craftSpeechError
// -----------------------------------------------------------------------------

test "the four error messages are Swift's, character for character" {
    // These strings are shown to a human (`test-bridges.html:392-393`) and
    // documented in README.md. A paraphrase changes what a user reads without
    // changing anything else a test can see.
    try testing.expectEqualStrings("Not authorized", err_not_authorized);
    try testing.expectEqualStrings("Audio session failed", err_audio_session);
    try testing.expectEqualStrings("Speech recognizer unavailable", err_recognizer_unavailable);
    try testing.expectEqualStrings("Audio engine failed", err_audio_engine);
    try testing.expectEqual(@as(usize, 4), error_messages.len);
}

test "an error detail is the single key the page reads" {
    // `e.detail.error` (`test-bridges.html:392`) and nothing else. A `code` or
    // `message` key alongside it would be a surface no consumer knows about.
    const json = try shapeErrorDetail(testing.allocator, err_not_authorized);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("{\"error\":\"Not authorized\"}", json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.object.count());
    try testing.expectEqualStrings("Not authorized", parsed.value.object.get("error").?.string);
}

test "every one of the four messages shapes and parses back" {
    for (error_messages) |message| {
        const json = try shapeErrorDetail(testing.allocator, message);
        defer testing.allocator.free(json);

        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(usize, 1), parsed.value.object.count());
        try testing.expectEqualStrings(message, parsed.value.object.get("error").?.string);
    }
}

test "an error message carrying a quote does not end the object early" {
    // No current message does. The escaping is a property of the position, not
    // of today's inputs, and a future round quoting a framework error is
    // exactly how the unescaped case arrives.
    const json = try shapeErrorDetail(testing.allocator, "recognizer said \"no\"\\ever");
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"error\":\"recognizer said \\\"no\\\"\\\\ever\"}",
        json,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "recognizer said \"no\"\\ever",
        parsed.value.object.get("error").?.string,
    );
}

// -----------------------------------------------------------------------------
// craftSpeechResult
// -----------------------------------------------------------------------------

test "a result detail is exactly transcript and isFinal" {
    // `CraftApp.swift:2525-2528`, and the two keys `test-bridges.html:386`
    // reads. These are the bytes `e.detail` receives either way, because
    // `sendToWeb` and `ios_events.formatEvent` inline the detail identically.
    const partial = try shapeResultDetail(testing.allocator, "hello world", false);
    defer testing.allocator.free(partial);
    try testing.expectEqualStrings(
        "{\"transcript\":\"hello world\",\"isFinal\":false}",
        partial,
    );

    const final = try shapeResultDetail(testing.allocator, "hello world", true);
    defer testing.allocator.free(final);
    try testing.expectEqualStrings(
        "{\"transcript\":\"hello world\",\"isFinal\":true}",
        final,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, final, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.count());
    try testing.expectEqualStrings("hello world", parsed.value.object.get("transcript").?.string);
    try testing.expectEqual(true, parsed.value.object.get("isFinal").?.bool);
}

test "the detail does not invent keys the recognizer could have supplied" {
    // `SFSpeechRecognitionResult` also carries `transcriptions`,
    // `bestTranscription.segments` and per-segment `confidence`, and Swift
    // reads none of them. Adding one would be a surface no consumer reads and
    // a divergence from the emitter contract this migration preserves.
    const json = try shapeResultDetail(testing.allocator, "x", true);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "confidence") == null);
    try testing.expect(std.mem.indexOf(u8, json, "alternatives") == null);
    try testing.expect(std.mem.indexOf(u8, json, "segments") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"transcript\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"isFinal\":") != null);
}

test "isFinal is a JSON boolean, never a quoted string" {
    // `${e.detail.isFinal}` renders `"false"` and `false` identically, so a
    // quoted value would read as correct on the test page while being truthy
    // to any code that branches on it.
    const json = try shapeResultDetail(testing.allocator, "", false);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"isFinal\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"false\"") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(false, parsed.value.object.get("isFinal").?.bool);
}

test "an empty transcript still emits the key" {
    // A first partial result can legitimately be empty. Omitting the key would
    // leave `e.detail.transcript` undefined, which a page cannot tell from a
    // bridge that stopped working.
    const json = try shapeResultDetail(testing.allocator, "", false);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("{\"transcript\":\"\",\"isFinal\":false}", json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.count());
    try testing.expectEqualStrings("", parsed.value.object.get("transcript").?.string);
}

test "a transcript with a quote does not truncate the event" {
    // The failure this shaper exists to prevent, and the one
    // `ios_events.zig` records against `bridge_iap.zig:362`: the detail is
    // inlined into JavaScript source, so an unescaped `"` does not corrupt one
    // field, it ends the object early and makes the whole `dispatchEvent` call
    // a syntax error. The page sees the stream stop, not a bad transcript.
    //
    // Dictation really does produce these: it transcribes spoken quotation
    // marks, and `formattedString` is not sanitised.
    const json = try shapeResultDetail(testing.allocator, "she said \"hello\"", true);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"transcript\":\"she said \\\"hello\\\"\",\"isFinal\":true}",
        json,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "she said \"hello\"",
        parsed.value.object.get("transcript").?.string,
    );
}

test "backslashes, newlines and control bytes survive as escapes" {
    // A literal newline inside a JavaScript string literal is a syntax error,
    // and a lone backslash would escape whatever followed it. Both reach the
    // page as a dead event rather than as bad text.
    const json = try shapeResultDetail(testing.allocator, "a\\b\nc\td\r\x01", false);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"transcript\":\"a\\\\b\\nc\\td\\r\\u0001\",\"isFinal\":false}",
        json,
    );

    // No raw control byte survived into the bytes that become JS source.
    for (json) |c| try testing.expect(c >= 0x20);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("a\\b\nc\td\r\x01", parsed.value.object.get("transcript").?.string);
}

test "an apostrophe passes through unescaped, and must" {
    // The opposite error, and an easy one to make while fixing the quote case.
    // `formatEvent` single-quotes the event *name* only; the detail is an
    // object literal, where `'` is an ordinary character inside a
    // double-quoted JSON string. Escaping it would put a literal backslash
    // into the transcript the page displays — and "don't" and "it's" are the
    // most common words dictation produces.
    const json = try shapeResultDetail(testing.allocator, "don't stop", true);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("{\"transcript\":\"don't stop\",\"isFinal\":true}", json);
    try testing.expect(std.mem.indexOfScalar(u8, json, '\\') == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("don't stop", parsed.value.object.get("transcript").?.string);
}

test "multi-byte UTF-8 is carried through unchanged" {
    // `formattedString` is whatever locale the recognizer was built with, and
    // even `en-US` produces curly apostrophes and em dashes. Escaping per byte
    // rather than per code point would split a sequence and hand the page
    // invalid JSON.
    const spoken = "café — naïve 日本語";
    const json = try shapeResultDetail(testing.allocator, spoken, true);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(spoken, parsed.value.object.get("transcript").?.string);
    try testing.expect(std.unicode.utf8ValidateSlice(json));
}

test "a shaped detail is a complete JSON value, which is what emit requires" {
    // `ios_events.emit` documents its argument as a complete JSON value and
    // inlines it verbatim. A shaper returning a fragment, or leaving a
    // trailing comma, would produce a `dispatchEvent` call the page cannot
    // parse — an event that silently never arrives.
    const details = [_][]u8{
        try shapeResultDetail(testing.allocator, "one", false),
        try shapeResultDetail(testing.allocator, "", true),
        try shapeErrorDetail(testing.allocator, err_audio_engine),
    };
    defer for (details) |d| testing.allocator.free(d);

    for (details) |detail| {
        try testing.expect(std.mem.startsWith(u8, detail, "{"));
        try testing.expect(std.mem.endsWith(u8, detail, "}"));
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, detail, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
    }
}
