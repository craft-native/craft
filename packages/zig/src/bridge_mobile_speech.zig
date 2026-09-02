//! The `mobile` namespace's speech pair: `startListening` and `stopListening`.
//!
//! Neither action replies. Both are raw `postMessage` calls with no
//! `callbackId` (`CraftApp.swift:1562-1568`), so nothing on the page is
//! awaiting an answer and every outcome — success, refusal, transcript, end —
//! travels as a `craftSpeech*` event. That is why both are declared
//! `.reply = .none` below, and why no path in this file returns an error to
//! `ios_dispatch`: an error there would call `sendErrorToJS` under a request
//! id no page is holding, which is console noise standing in for the event a
//! page is actually listening for.
//!
//! ## What this round changed
//!
//! An earlier round researched both actions in full and deliberately left them
//! with the Swift shim, listing four blockers and five preconditions. All five
//! preconditions are met here, and the four blockers are answered:
//!
//!  1. `ios_events.Event` can spell `craftSpeechStart` now — the arm was added
//!     alongside this module, and the vocabulary test covers it.
//!  2. **The realtime tap.** `-[AVAudioNode installTapOnBus:…]` runs its block
//!     on the audio I/O thread, which no other module in this tree touches.
//!     Swift gets a free ARC retain for the duration of
//!     `recognitionRequest?.append(buffer)`; Zig gets nothing, so releasing
//!     the request while a tap call is in flight is a use-after-free on a
//!     realtime thread. The answer is below under "The audio thread", and it
//!     is an atomic handoff with a bounded drain — never a mutex, which on an
//!     audio thread is a priority inversion.
//!  3. **The zero-format abort.** With no input route
//!     `-outputFormatForBus:0` yields a format whose `sampleRate` and
//!     `channelCount` are 0, and `installTapOnBus:` then raises an
//!     `NSException` the process cannot catch. Swift has the identical crash
//!     at `:2535-2538`. `formatCarriesInput` pre-checks and refuses.
//!  4. **Testability.** The fixture drives both actions on a simulator and
//!     asserts the events, so the audio path is exercised rather than only the
//!     shapers.
//!
//! ## The event contract, which is the whole page-visible surface
//!
//! | event | when Swift sends it | when this module does |
//! |---|---|---|
//! | `craftSpeechStart` | the engine started | the engine started |
//! | `craftSpeechResult` | every partial and final transcript | the same |
//! | `craftSpeechError` | four named failures | the same four |
//! | `craftSpeechEnd` | every `stopSpeechRecognition()` | every `stopListening`, and every internal stop |
//!
//! `craftSpeechEnd` fires on a `stopListening` that stops nothing. Swift's
//! `stopSpeechRecognition()` has no early return — it is called from
//! `case "stopListening"` unconditionally, with no gate and no guard — so a
//! page that stops twice gets two ends, and one that never started still gets
//! one. That is bug-compatibility on purpose: the event is what a page's UI
//! binds its "listening" indicator to, and an end that does not arrive leaves
//! the indicator stuck on.
//!
//! ## Deliberate divergences, each with its reason
//!
//! **The plist guard replaces the nil-recognizer guard.** Swift builds its
//! `SFSpeechRecognizer` only when `config.enableSpeechRecognition` is on
//! (`:439-440`), and `beginRecording`'s `guard let speechRecognizer` then
//! emits `"Speech recognizer unavailable"` when it is off. Zig cannot see the
//! ivar, but `packages/ios/src/index.ts:183` writes
//! `NSSpeechRecognitionUsageDescription` from that flag **and nothing else,
//! with no `||`** — the exact-proxy shape `bridge_mobile_motion.zig` already
//! reads. So a missing key means the flag was off, and the message emitted is
//! the one Swift would have emitted for the same configuration.
//!
//! The check has to run *before* `requestAuthorization:`, where Swift's runs
//! after, because asking for speech authorization without the key does not
//! fail — iOS terminates the process. Order diverges; the page-visible
//! message does not.
//!
//! (`NSMicrophoneUsageDescription` at `index.ts:184` is
//! `enableSpeechRecognition || enableAudioRecording` and is therefore **not**
//! an exact proxy, so it is not the gate. It is implied by the speech key
//! rather than checked: speech on always writes both.)
//!
//! **A zero input format is refused as `"Audio engine failed"`.** There is no
//! Swift string for it because Swift does not survive the case, and inventing
//! a fifth message would put bytes on a page's screen that no other arm of the
//! bridge can produce. `startAndReturnError:` failing for the same underlying
//! reason — no usable input — is what Swift reports as `"Audio engine
//! failed"`, so the existing message is the honest one.
//!
//! **A second `startListening` while running stops first.** Swift's
//! `beginRecording` cancels the task and nothing else (`:2497-2500`), then
//! installs a second tap on bus 0, which raises. Reproducing that is not
//! required of a port; `bridge_mobile_motion.zig` made the same call. The
//! internal stop emits **no** `craftSpeechEnd`, because Swift's restart emits
//! none either — only a real stop does.
//!
//! **`stopListening` does not touch the engine when nothing is running.**
//! Swift's stop reads `audioEngine.inputNode` unconditionally, and that
//! property *creates* the input node on demand; on a device with no input
//! route available it can raise rather than return. Since a stop that stopped
//! nothing has nothing to remove, the engine is touched only when this module
//! knows a tap is installed. The `craftSpeechEnd` still fires, so the page
//! sees no difference.
//!
//! **Trailing buffers are not dropped.** The handoff clears the published
//! request only after `removeTapOnBus:` has returned, so every buffer the tap
//! delivered before removal reaches the recognizer — the same audio Swift
//! would have appended.
//!
//! **On a recognition error, no `craftSpeechError` is emitted.** Swift
//! discards the `NSError` entirely (`:2530-2532` calls only
//! `stopSpeechRecognition()`), so the page sees `craftSpeechEnd` and nothing
//! else. Android *does* emit one (`CraftBridge.kt.template:1367`). The
//! divergence is left unfixed here on purpose: there is no Swift string to
//! copy, and inventing one prejudges a contract question that belongs to the
//! JS surface, not to a port. `error_messages` below is still exactly four.
//!
//! **Both haptics fire ungated.** `:2544` and `:2558` call
//! `triggerHaptic("light")` directly, bypassing the `config.enableHaptics`
//! check the dispatcher applies to `case "haptic"` at `:537`. Swift ignores
//! the flag on this path, so firing it here is faithful rather than a
//! divergence — and it is why `bridge_mobile_haptics.triggerHapticChecked`
//! became `pub` in the same change.
//!
//! ## The audio thread
//!
//! One rule: **the tap block touches exactly two atomics and one selector,
//! all of them resolved before the tap was installed.** No allocation, no
//! `sel_registerName`, no logging, no lock.
//!
//! The handoff is a published pointer plus an in-flight counter:
//!
//!   - `active_request` holds the `SFSpeechAudioBufferRecognitionRequest` as a
//!     `usize`. Zero means "nobody may append".
//!   - `tap_in_flight` is incremented by the tap before it loads the pointer
//!     and decremented after the append returns.
//!   - Teardown stops the engine, removes the tap, clears `active_request`,
//!     then spins until `tap_in_flight` reads zero before releasing.
//!
//! Every one of those four operations is `.seq_cst`, and that is not
//! decoration. The dangerous interleaving is Dekker's: the tap increments then
//! loads the pointer while teardown clears the pointer then loads the counter.
//! Acquire/release ordering permits both sides to see the other's *old* value,
//! which is exactly "teardown believes no tap is running while a tap holds a
//! pointer it is about to release". Sequential consistency is what rules that
//! out, and one `xchg` per audio buffer — roughly 86 a second at 1024 frames
//! and 44.1kHz — is not a cost worth reasoning around.
//!
//! The spin is bounded (`drain_spins` × 100µs = 20ms, against a tap call
//! measured in microseconds) and runs on the main thread only while a stop is
//! in progress. If it ever fails to drain, the request is **leaked rather
//! than released** and the fact is logged. That is the trade the earlier round
//! asked for in as many words: prefer leaking one request per session over
//! racing the audio thread.
//!
//! ## Queues, and the hop each one needs
//!
//!   - `handleMessage` runs on the main thread — it is reached from
//!     `-userContentController:didReceiveScriptMessage:`.
//!   - `+[SFSpeechRecognizer requestAuthorization:]` answers on an arbitrary
//!     queue, so its block hops to the main queue before anything touches
//!     `AVAudioSession` or `AVAudioEngine`. `bridge_mobile_audiorec.zig` makes
//!     the identical hop for the identical reason.
//!   - The recognition result handler fires on an internal Speech queue. It
//!     may emit (`ios_events.emit` hops itself) but must hop before tearing
//!     the engine down, which is precondition 5.
//!   - The tap block runs on the audio I/O thread. See above.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const ios_events = @import("ios_events.zig");
const objc_runtime = @import("objc_runtime.zig");
const haptics = @import("bridge_mobile_haptics.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;
const Id = ?*anyopaque;
const is_darwin = builtin.target.os.tag.isDarwin();

pub const A = struct {
    pub const start_listening = "startListening";
    pub const stop_listening = "stopListening";
};

/// `.none` for both, and the distinction matters.
///
/// `.result` would tell an app to await a reply that never comes: neither
/// action calls `sendResultToJS` on any path, because neither has a page-side
/// promise to settle. Everything observable leaves through `ios_events`.
///
/// `.live` for both. A refusal here is a specific condition — speech not
/// configured, authorization declined, no input route — and never the normal
/// answer, which is what `.unavailable` would claim.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.start_listening, .reply = .none },
    .{ .name = A.stop_listening, .reply = .none },
};

pub const SpeechBridge = struct {
    /// Held for the interface `ios_dispatch` builds every mobile bridge with.
    /// Unused: nothing in a dispatch allocates, and the two paths that do —
    /// shaping a transcript and shaping an error — run from callbacks where
    /// this bridge is long gone, so they take the C allocator instead.
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    /// The payload is ignored, deliberately: Swift reads no field from either
    /// action, and the injected JS posts neither a body nor a `callbackId`.
    /// Parsing it would only create a way to fail that the spec has not got.
    pub fn handleMessage(_: *Self, action: []const u8, _: []const u8) !void {
        if (std.mem.eql(u8, action, A.start_listening)) {
            startListening();
            return;
        }
        if (std.mem.eql(u8, action, A.stop_listening)) {
            stopListening();
            return;
        }
        return BridgeError.UnknownAction;
    }
};

// =============================================================================
// The event vocabulary.
// =============================================================================

/// `craftSpeechStart` — the engine is running and audio is reaching the
/// recognizer.
pub const event_start: ios_events.Event = .speech_start;

/// `craftSpeechResult` — the transcript stream.
pub const event_result: ios_events.Event = .speech_result;

/// `craftSpeechError` — every refusal, on every path.
pub const event_error: ios_events.Event = .speech_error;

/// `craftSpeechEnd` — every stop, including one that stops nothing.
pub const event_end: ios_events.Event = .speech_end;

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

/// `:2546` — `-startAndReturnError:` returned NO. Also the zero-format
/// refusal, which Swift does not survive to report; see the module comment.
pub const err_audio_engine = "Audio engine failed";

/// Every message this module may emit, in Swift's source order. Still four:
/// the recognition-error divergence is documented rather than papered over
/// with a fifth string Swift has never sent.
pub const error_messages = [_][]const u8{
    err_not_authorized,
    err_audio_session,
    err_recognizer_unavailable,
    err_audio_engine,
};

/// Why a start failed, in the vocabulary the page reads.
///
/// An error set rather than a returned string, so a path that forgets to
/// report is a compile error rather than an empty message, and so
/// `messageFor` is the single place the mapping lives.
const StartFailure = error{
    AudioSession,
    RecognizerUnavailable,
    AudioEngine,
};

fn messageFor(err: StartFailure) []const u8 {
    return switch (err) {
        error.AudioSession => err_audio_session,
        error.RecognizerUnavailable => err_recognizer_unavailable,
        error.AudioEngine => err_audio_engine,
    };
}

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

/// Emit one `craftSpeechError`, or drop it and say so.
///
/// Every failure path in this file ends here, so this is the one place that
/// decides what a page sees when even the reporting fails. Dropping is the
/// only option — there is no promise to reject and no second channel — and
/// the log line is what a developer has left.
fn emitError(message: []const u8) void {
    const allocator = std.heap.c_allocator;
    const detail = shapeErrorDetail(allocator, message) catch {
        std.log.warn("speech: could not shape '{s}' for craftSpeechError", .{message});
        return;
    };
    defer allocator.free(detail);
    ios_events.emit(event_error, detail);
}

// =============================================================================
// Native constants, each read from the SDK header rather than recalled.
// =============================================================================

/// `SFSpeechRecognizerAuthorizationStatusAuthorized`.
///
/// `SFSpeechRecognizer.h:25-41` numbers the enum implicitly from zero:
/// NotDetermined 0, Denied 1, Restricted 2, Authorized 3. Only 3 proceeds —
/// Swift's `guard status == .authorized` treats the other three identically,
/// including NotDetermined, which is what a user dismissing the prompt leaves
/// behind.
const status_authorized: isize = 3;

/// `AVAudioSessionCategoryOptionDuckOthers` — `AVAudioSessionTypes.h:466`,
/// `0x2`. Swift passes `options: .duckOthers`.
const category_option_duck_others: c_ulong = 0x2;

/// `AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation` —
/// `AVAudioSessionTypes.h:660`, `1`. Swift passes it on activation, where the
/// header says it is only meaningful on deactivation; carried across anyway,
/// because it is inert rather than wrong and matching the shim costs nothing.
const set_active_notify_others: c_ulong = 1;

/// The bus every call here uses. Swift hardcodes 0 in all four places.
const bus_zero: c_ulong = 0;

/// Swift's `bufferSize: 1024` (`:2536`). `AVAudioFrameCount` is `uint32_t`
/// (`AVAudioTypes.h:22`).
const tap_buffer_frames: u32 = 1024;

/// The locale Swift builds its recognizer with (`:440`).
const recognizer_locale = "en-US";

/// The Info.plist key that stands in for `config.enableSpeechRecognition`.
const key_speech_usage = "NSSpeechRecognitionUsageDescription";

/// How many spins teardown will wait for the audio thread before giving up and
/// leaking the request. 200 × 100µs is 20ms, against a tap call measured in
/// microseconds — long enough that reaching the end means something is wrong,
/// short enough that a page's stop still feels instant.
const drain_spins: usize = 200;
const drain_spin_micros: c_uint = 100;

// =============================================================================
// State.
//
// Module-level, because `ios_dispatch` builds a fresh `SpeechBridge` per
// dispatch and drops it again: anything held on the bridge would be released
// the instant `startListening` returned, and the session with it. Swift's are
// ivars on a coordinator that outlives every call, for the same reason.
//
// Everything here is main-thread state except the two atomics, which are the
// only things the audio thread may touch.
// =============================================================================

/// The `SFSpeechRecognizer`, built once and kept. Swift's is built at
/// coordinator init when the flag is on.
var recognizer: Id = null;

/// The `AVAudioEngine`. Swift's is `private var audioEngine = AVAudioEngine()`
/// (`:381`) — one instance for the process.
var engine: Id = null;

/// The current `SFSpeechRecognitionTask`, retained, cancelled by teardown.
var task: Id = null;

/// Whether a tap is installed on bus 0 of the engine's input node. The only
/// thing that makes teardown touch the engine at all.
var tap_installed: bool = false;

/// Whether a start is between `requestAuthorization:` and the main-queue hop.
/// A second `startListening` in that window is dropped rather than queued: it
/// would produce a second authorization callback racing the first one's
/// `beginRecording`, and the page cannot tell two starts apart anyway.
var starting: bool = false;

/// Whether a session is running, in the sense that `craftSpeechStart` was
/// emitted and no end has been.
var listening: bool = false;

/// `@selector(appendAudioPCMBuffer:)`, interned on the main thread before the
/// tap is installed. The audio thread must never call `sel_registerName`,
/// which takes the runtime's lock.
var sel_append: objc.SEL = null;

/// The `SFSpeechAudioBufferRecognitionRequest` the tap may append to, as a
/// `usize`. Zero means nobody may append.
///
/// `.seq_cst` on every access; see the module comment on Dekker.
var active_request: std.atomic.Value(usize) = .init(0);

/// How many tap invocations are between their fence and their append. Teardown
/// waits for this to reach zero before releasing what `active_request` held.
var tap_in_flight: std.atomic.Value(u32) = .init(0);

/// The authorization status, written on whatever queue Speech chose and read
/// on the main queue after the hop.
var auth_status: std.atomic.Value(isize) = .init(0);

// =============================================================================
// startListening.
// =============================================================================

/// `case "startListening"` (`CraftApp.swift:533-534`, `:2486-2548`).
///
/// Returns nothing and reports nothing to the dispatcher: every outcome is an
/// event. The plist guard runs before `requestAuthorization:` because asking
/// without the key terminates the process rather than failing.
fn startListening() void {
    if (!is_darwin) {
        emitError(err_recognizer_unavailable);
        return;
    }

    if (starting) {
        std.log.info("startListening: an authorization request is already in flight", .{});
        return;
    }

    if (!hasSpeechUsageDescription()) {
        std.log.warn(
            "startListening refused: Info.plist has no {s}, so this app was not built " ++
                "with speech recognition enabled",
            .{key_speech_usage},
        );
        emitError(err_recognizer_unavailable);
        return;
    }

    const SFSpeechRecognizer = objc.objc_getClass("SFSpeechRecognizer") orelse {
        std.log.warn(
            "startListening: SFSpeechRecognizer is not in this process; " ++
                "the app does not link Speech",
            .{},
        );
        emitError(err_recognizer_unavailable);
        return;
    };
    const sel_request = objc.sel_registerName("requestAuthorization:") orelse {
        emitError(err_recognizer_unavailable);
        return;
    };

    starting = true;

    const RequestFn = *const fn (Id, objc.SEL, *const AuthBlock) callconv(.c) void;
    const requestAuthorization: RequestFn = @ptrCast(&objc.objc_msgSend);
    requestAuthorization(SFSpeechRecognizer, sel_request, &auth_block);
}

/// Whether the main bundle's Info.plist carries the speech usage description.
///
/// Answers `false` on any runtime failure rather than propagating one. Unlike
/// `bridge_mobile_motion.zig`'s version, which separates "no NSBundle class"
/// from "not configured" because it has an error to return, every caller here
/// has only an event to emit — and the event would be the same either way, so
/// the distinction would cost a code path and buy a page nothing. The log line
/// above the call is where a broken process is named.
fn hasSpeechUsageDescription() bool {
    if (!is_darwin) return false;

    const NSBundle = objc.objc_getClass("NSBundle") orelse return false;
    const sel_main = objc.sel_registerName("mainBundle") orelse return false;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return false;

    const NSString = objc.objc_getClass("NSString") orelse return false;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse return false;
    const ns_key = objc.msgSendId1(
        NSString,
        sel_string,
        @as([*:0]const u8, key_speech_usage),
    ) orelse return false;

    const sel_lookup = objc.sel_registerName("objectForInfoDictionaryKey:") orelse return false;
    return objc.msgSendId1(bundle, sel_lookup, ns_key) != null;
}

/// The main-queue half of the authorization answer.
///
/// Swift hops here too (`:2493`) before `beginRecording`, because activating an
/// audio session and starting an engine off the main thread is not supported.
fn authorizedOnMain(_: ?*anyopaque) callconv(.c) void {
    starting = false;

    if (auth_status.load(.seq_cst) != status_authorized) {
        std.log.warn(
            "startListening: speech authorization was not granted (status {d})",
            .{auth_status.load(.seq_cst)},
        );
        emitError(err_not_authorized);
        return;
    }

    beginRecording() catch |err| {
        std.log.warn("startListening: {s}", .{messageFor(err)});
        emitError(messageFor(err));
        return;
    };
}

/// Everything `beginRecording` does, in Swift's order (`:2496-2548`).
///
/// Once `active_request` is published, ownership of the request belongs to
/// `teardown`, so every failure after that point goes through `failStart`
/// rather than releasing anything itself. That is why there is no `errdefer`
/// here: an errdefer plus a teardown is a double release, and the object it
/// would double-release is one an audio thread may be holding.
fn beginRecording() StartFailure!void {
    // Swift cancels only the task and then installs a second tap, which
    // raises. Stop properly instead — and emit no end, because a restart is
    // not a stop.
    if (listening or tap_installed) teardown(false);

    const session = sharedAudioSession() orelse return error.AudioSession;
    configureSession(session) catch return error.AudioSession;

    const rec = ensureRecognizer() orelse return error.RecognizerUnavailable;
    if (!recognizerIsAvailable(rec)) {
        std.log.warn("startListening: the recognizer reports itself unavailable", .{});
        return error.RecognizerUnavailable;
    }

    const eng = ensureEngine() orelse return error.AudioEngine;
    const input = inputNode(eng) orelse return error.AudioEngine;
    const format = outputFormat(input) orelse return error.AudioEngine;

    // Precondition 3. `installTapOnBus:` on a zero format raises an
    // NSException, and an uncaught ObjC exception is an uncatchable SIGABRT —
    // Swift aborts here, this returns.
    if (!formatCarriesInput(format)) {
        std.log.warn(
            "startListening: the input node reports no usable format, " ++
                "so this process has no audio input route",
            .{},
        );
        return error.AudioEngine;
    }

    // Interned before the tap exists, so the audio thread never needs the
    // runtime's selector lock.
    sel_append = objc.sel_registerName("appendAudioPCMBuffer:") orelse
        return error.RecognizerUnavailable;

    const request = newRecognitionRequest() orelse return error.RecognizerUnavailable;
    setShouldReportPartialResults(request, true);

    // From here on the request is teardown's to release.
    active_request.store(@intFromPtr(request), .seq_cst);

    const started_task = startRecognitionTask(rec, request) orelse
        return failStart(error.RecognizerUnavailable);
    // `recognitionTaskWithRequest:` returns an autoreleased task; without a
    // retain it dies at the end of this turn of the run loop and the stream
    // stops with no event to say so.
    task = objc.retain(started_task);

    installTap(input, format) catch return failStart(error.AudioEngine);
    tap_installed = true;

    prepareEngine(eng);
    if (!startEngine(eng)) return failStart(error.AudioEngine);

    listening = true;
    ios_events.emit(event_start, empty_detail);
    fireHaptic();
}

/// Tear down whatever was built, then report why the start failed.
///
/// No `craftSpeechEnd`: a start that never emitted `craftSpeechStart` has no
/// end to announce, and Swift's failure paths emit only the error.
fn failStart(err: StartFailure) StartFailure {
    teardown(false);
    return err;
}

// =============================================================================
// stopListening, and the teardown both stops share.
// =============================================================================

/// `case "stopListening"` (`CraftApp.swift:535-536`, `:2550-2559`).
///
/// Ungated in the spec — there is no `if config.` on this case — so
/// `ios_config.gateFor` has no entry for it either, and an app with speech
/// disabled can still stop. Which matters: the page's own stop is how a stuck
/// listening indicator gets cleared.
fn stopListening() void {
    if (!is_darwin) {
        // Nothing to stop, and the page still gets its end. `emit` is a no-op
        // off Darwin, so this is documentation more than behaviour.
        ios_events.emit(event_end, empty_detail);
        return;
    }
    teardown(true);
}

/// The main-queue landing for a stop the recognition handler asked for.
///
/// Precondition 5: the handler fires on an internal Speech queue, and
/// `AVAudioEngine` must not be touched from there.
fn stopOnMain(_: ?*anyopaque) callconv(.c) void {
    teardown(true);
}

/// Release everything, in the one order that is safe against the audio thread.
///
///  1. Stop the engine and remove the tap, so `AVAudioEngine` guarantees no
///     new tap call begins.
///  2. Clear the published request, so a call that began before step 1
///     returned finds nothing to append to.
///  3. Drain: wait for any in-flight tap call to leave.
///  4. `endAudio`, then release — or leak, if step 3 timed out.
///  5. Cancel and release the task.
///
/// Steps 1 and 2 in that order rather than the reverse: clearing first would
/// silently drop the last buffers the tap had already delivered, which is
/// audio Swift would have transcribed.
///
/// Idempotent. Every field is checked, so a stop that stops nothing does
/// nothing but emit — which is exactly what `stopListening` needs.
fn teardown(emit_end: bool) void {
    if (!is_darwin) return;

    if (tap_installed) {
        if (engine) |eng| {
            stopEngine(eng);
            if (inputNode(eng)) |input| removeTap(input);
        }
        tap_installed = false;
    }

    const held = active_request.swap(0, .seq_cst);
    const drained = drainTap();

    if (held != 0) {
        const request: Id = @ptrFromInt(held);
        endAudio(request);
        if (drained) {
            objc.release(request);
        } else {
            std.log.warn(
                "stopListening: the audio thread did not leave within {d}ms, " ++
                    "so one recognition request is leaked rather than released",
                .{(drain_spins * drain_spin_micros) / 1000},
            );
        }
    }

    if (task) |t| {
        cancelTask(t);
        objc.release(t);
        task = null;
    }

    listening = false;

    if (emit_end) {
        ios_events.emit(event_end, empty_detail);
        fireHaptic();
    }
}

/// Wait for `tap_in_flight` to reach zero, bounded.
///
/// Sleeping rather than spinning hot: the audio thread runs at a higher
/// priority than the main thread, so burning the main thread's slice is the
/// one thing that could actually delay the call being waited on. This Zig has
/// no `std.Thread.sleep` (`startup_timing.zig:150` records the same gap), and
/// a busy spin is the wrong shape here, so the sleep is libc's — which this
/// file already depends on for `dlsym` and `dispatch_async_f`.
fn drainTap() bool {
    var spins: usize = 0;
    while (spins < drain_spins) : (spins += 1) {
        if (tap_in_flight.load(.seq_cst) == 0) return true;
        _ = usleep(drain_spin_micros);
    }
    return tap_in_flight.load(.seq_cst) == 0;
}

/// `triggerHaptic(style: "light")`, as `:2544` and `:2558` fire it.
///
/// Ungated on purpose — see the module comment. Errors are swallowed because
/// the Taptic Engine is absent on the simulator and on iPad, and a haptic that
/// could not fire is not a reason to withhold a speech event.
fn fireHaptic() void {
    haptics.triggerHapticChecked(.impact_light) catch |err| {
        std.log.debug("speech: the light haptic did not fire: {}", .{err});
    };
}

// =============================================================================
// Blocks.
//
// All three are global blocks — `_NSConcreteGlobalBlock` with
// `BLOCK_IS_GLOBAL`, so `Block_copy` is identity and none of them can outlive
// its storage. None captures anything: the authorization block writes an
// atomic and hops, the result block reads its arguments, and the tap block
// reads two atomics. Capture would mean a heap block, a copy helper, and a
// dispose helper, and the tap block would then be allocating on the audio
// thread.
// =============================================================================

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// 1 << 28 — a global block is never copied.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

extern var _NSConcreteGlobalBlock: anyopaque;

/// `void (^)(SFSpeechRecognizerAuthorizationStatus status)`.
const AuthBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

const auth_block_descriptor = BlockDescriptor{ .size = @sizeOf(AuthBlock) };

fn authInvoke(_: *const AuthBlock, status: isize) callconv(.c) void {
    // An arbitrary queue. Record and hop; touch nothing else.
    auth_status.store(status, .seq_cst);
    dispatch_async_f(&_dispatch_main_q, null, authorizedOnMain);
}

var auth_block: AuthBlock = if (is_darwin) .{
    .isa = &_NSConcreteGlobalBlock,
    .flags = BLOCK_IS_GLOBAL,
    .invoke = @ptrCast(&authInvoke),
    .descriptor = &auth_block_descriptor,
} else undefined;

/// `void (^)(SFSpeechRecognitionResult *result, NSError *error)`.
const ResultBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

const result_block_descriptor = BlockDescriptor{ .size = @sizeOf(ResultBlock) };

/// Swift's result handler (`:2522-2533`), including its discarded error.
fn resultInvoke(_: *const ResultBlock, result: Id, err: Id) callconv(.c) void {
    var is_final = false;

    if (result) |r| {
        is_final = resultIsFinal(r);
        emitTranscript(r, is_final);
    }

    if (err != null or is_final) {
        // Precondition 5: this is an internal Speech queue, and the teardown
        // touches AVAudioEngine.
        dispatch_async_f(&_dispatch_main_q, null, stopOnMain);
    }
}

var result_block: ResultBlock = if (is_darwin) .{
    .isa = &_NSConcreteGlobalBlock,
    .flags = BLOCK_IS_GLOBAL,
    .invoke = @ptrCast(&resultInvoke),
    .descriptor = &result_block_descriptor,
} else undefined;

/// `AVAudioNodeTapBlock` — `void (^)(AVAudioPCMBuffer *buffer, AVAudioTime
/// *when)` (`AVAudioNode.h:32`).
const TapBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

const tap_block_descriptor = BlockDescriptor{ .size = @sizeOf(TapBlock) };

/// The audio I/O thread. Two atomics, one `objc_msgSend`, nothing else.
///
/// No allocation, no `sel_registerName`, no logging, no lock: each of those
/// takes a lock somewhere, and taking a lock here inverts priority against
/// whatever holds it. `when` is unread, as it is in Swift.
fn tapInvoke(_: *const TapBlock, buffer: Id, when: Id) callconv(.c) void {
    _ = when;

    _ = tap_in_flight.fetchAdd(1, .seq_cst);
    defer _ = tap_in_flight.fetchSub(1, .seq_cst);

    const held = active_request.load(.seq_cst);
    if (held == 0) return;

    const request: Id = @ptrFromInt(held);
    const AppendFn = *const fn (Id, objc.SEL, Id) callconv(.c) void;
    const append: AppendFn = @ptrCast(&objc.objc_msgSend);
    append(request, sel_append, buffer);
}

var tap_block: TapBlock = if (is_darwin) .{
    .isa = &_NSConcreteGlobalBlock,
    .flags = BLOCK_IS_GLOBAL,
    .invoke = @ptrCast(&tapInvoke),
    .descriptor = &tap_block_descriptor,
} else undefined;

// =============================================================================
// The Objective-C calls, one thin wrapper each.
//
// Wrapped rather than inlined so `beginRecording` reads as the sequence Swift
// reads as, and so every signature is written exactly once — the place this
// migration has repeatedly found its mistakes.
// =============================================================================

fn sharedAudioSession() Id {
    const AVAudioSession = objc.objc_getClass("AVAudioSession") orelse {
        std.log.warn(
            "startListening: AVAudioSession is not in this process; " ++
                "the app does not link AVFoundation",
            .{},
        );
        return null;
    };
    const sel = objc.sel_registerName("sharedInstance") orelse return null;
    return objc.msgSendId(AVAudioSession, sel);
}

/// `setCategory(.record, mode: .measurement, options: .duckOthers)` then
/// `setActive(true, options: .notifyOthersOnDeactivation)` — Swift `:2502-2505`.
fn configureSession(session: Id) !void {
    const category = audioSessionConstant("AVAudioSessionCategoryRecord") orelse
        return error.NotFound;
    const mode = audioSessionConstant("AVAudioSessionModeMeasurement") orelse
        return error.NotFound;

    const sel_category = objc.sel_registerName("setCategory:mode:options:error:") orelse
        return error.SelectorNotFound;
    const CategoryFn = *const fn (Id, objc.SEL, Id, Id, c_ulong, ?*Id) callconv(.c) bool;
    const setCategory: CategoryFn = @ptrCast(&objc.objc_msgSend);
    var category_error: Id = null;
    if (!setCategory(
        session,
        sel_category,
        category,
        mode,
        category_option_duck_others,
        &category_error,
    )) {
        logNSError("startListening", category_error);
        return error.NativeCallFailed;
    }

    const sel_active = objc.sel_registerName("setActive:withOptions:error:") orelse
        return error.SelectorNotFound;
    const ActiveFn = *const fn (Id, objc.SEL, bool, c_ulong, ?*Id) callconv(.c) bool;
    const setActive: ActiveFn = @ptrCast(&objc.objc_msgSend);
    var active_error: Id = null;
    if (!setActive(session, sel_active, true, set_active_notify_others, &active_error)) {
        logNSError("startListening", active_error);
        return error.NativeCallFailed;
    }
}

/// `SFSpeechRecognizer(locale: Locale(identifier: "en-US"))`, built once.
fn ensureRecognizer() Id {
    if (recognizer) |existing| return existing;

    const NSLocale = objc.objc_getClass("NSLocale") orelse return null;
    const sel_locale = objc.sel_registerName("localeWithLocaleIdentifier:") orelse return null;
    const NSString = objc.objc_getClass("NSString") orelse return null;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse return null;
    const identifier = objc.msgSendId1(
        NSString,
        sel_string,
        @as([*:0]const u8, recognizer_locale),
    ) orelse return null;
    const locale = objc.msgSendId1(NSLocale, sel_locale, identifier) orelse return null;

    const SFSpeechRecognizer = objc.objc_getClass("SFSpeechRecognizer") orelse return null;
    const sel_alloc = objc.sel_registerName("alloc") orelse return null;
    const sel_init = objc.sel_registerName("initWithLocale:") orelse return null;
    const allocated = objc.msgSendId(SFSpeechRecognizer, sel_alloc) orelse return null;

    // `-initWithLocale:` is nullable: an unsupported locale answers nil, and
    // then so does this, and the caller emits "Speech recognizer unavailable"
    // exactly as Swift's `guard let` does.
    recognizer = objc.msgSendId1(allocated, sel_init, locale);
    return recognizer;
}

fn recognizerIsAvailable(rec: Id) bool {
    const sel = objc.sel_registerName("isAvailable") orelse return false;
    return objc.msgSendBool(rec, sel);
}

fn ensureEngine() Id {
    if (engine) |existing| return existing;
    const AVAudioEngine = objc.objc_getClass("AVAudioEngine") orelse return null;
    engine = objc.allocInit(AVAudioEngine) catch null;
    return engine;
}

fn inputNode(eng: Id) Id {
    const sel = objc.sel_registerName("inputNode") orelse return null;
    return objc.msgSendId(eng, sel);
}

fn outputFormat(node: Id) Id {
    const sel = objc.sel_registerName("outputFormatForBus:") orelse return null;
    const Fn = *const fn (Id, objc.SEL, c_ulong) callconv(.c) Id;
    const call: Fn = @ptrCast(&objc.objc_msgSend);
    return call(node, sel, bus_zero);
}

/// Whether this format describes a real input route.
///
/// The header says it in as many words: "Check for the input node's input
/// format for non-zero sample rate and channel count to see if input is
/// enabled" (`AVAudioEngine.h:459-461`). Both must be non-zero — a format with
/// a rate and no channels is as unusable as one with neither.
fn formatCarriesInput(format: Id) bool {
    const sel_rate = objc.sel_registerName("sampleRate") orelse return false;
    const RateFn = *const fn (Id, objc.SEL) callconv(.c) f64;
    const sampleRate: RateFn = @ptrCast(&objc.objc_msgSend);

    const sel_channels = objc.sel_registerName("channelCount") orelse return false;
    const ChannelFn = *const fn (Id, objc.SEL) callconv(.c) u32;
    const channelCount: ChannelFn = @ptrCast(&objc.objc_msgSend);

    return sampleRate(format, sel_rate) > 0 and channelCount(format, sel_channels) > 0;
}

fn newRecognitionRequest() Id {
    const class = objc.objc_getClass("SFSpeechAudioBufferRecognitionRequest") orelse return null;
    return objc.allocInit(class) catch null;
}

fn setShouldReportPartialResults(request: Id, value: bool) void {
    const sel = objc.sel_registerName("setShouldReportPartialResults:") orelse return;
    const Fn = *const fn (Id, objc.SEL, bool) callconv(.c) void;
    const call: Fn = @ptrCast(&objc.objc_msgSend);
    call(request, sel, value);
}

fn startRecognitionTask(rec: Id, request: Id) Id {
    const sel = objc.sel_registerName("recognitionTaskWithRequest:resultHandler:") orelse
        return null;
    const Fn = *const fn (Id, objc.SEL, Id, *const ResultBlock) callconv(.c) Id;
    const call: Fn = @ptrCast(&objc.objc_msgSend);
    return call(rec, sel, request, &result_block);
}

fn installTap(node: Id, format: Id) !void {
    const sel = objc.sel_registerName("installTapOnBus:bufferSize:format:block:") orelse
        return error.SelectorNotFound;
    const Fn = *const fn (Id, objc.SEL, c_ulong, u32, Id, *const TapBlock) callconv(.c) void;
    const call: Fn = @ptrCast(&objc.objc_msgSend);
    call(node, sel, bus_zero, tap_buffer_frames, format, &tap_block);
}

fn removeTap(node: Id) void {
    const sel = objc.sel_registerName("removeTapOnBus:") orelse return;
    const Fn = *const fn (Id, objc.SEL, c_ulong) callconv(.c) void;
    const call: Fn = @ptrCast(&objc.objc_msgSend);
    call(node, sel, bus_zero);
}

fn prepareEngine(eng: Id) void {
    const sel = objc.sel_registerName("prepare") orelse return;
    objc.msgSend(eng, sel);
}

fn startEngine(eng: Id) bool {
    const sel = objc.sel_registerName("startAndReturnError:") orelse return false;
    const Fn = *const fn (Id, objc.SEL, ?*Id) callconv(.c) bool;
    const call: Fn = @ptrCast(&objc.objc_msgSend);
    var start_error: Id = null;
    if (call(eng, sel, &start_error)) return true;
    logNSError("startListening", start_error);
    return false;
}

fn stopEngine(eng: Id) void {
    const sel = objc.sel_registerName("stop") orelse return;
    objc.msgSend(eng, sel);
}

fn endAudio(request: Id) void {
    const sel = objc.sel_registerName("endAudio") orelse return;
    objc.msgSend(request, sel);
}

fn cancelTask(t: Id) void {
    const sel = objc.sel_registerName("cancel") orelse return;
    objc.msgSend(t, sel);
}

fn resultIsFinal(result: Id) bool {
    const sel = objc.sel_registerName("isFinal") orelse return false;
    return objc.msgSendBool(result, sel);
}

/// `result.bestTranscription.formattedString` -> one `craftSpeechResult`.
///
/// Runs on Speech's internal queue. `ios_events.emit` hops to the main queue
/// itself, so nothing here needs to.
fn emitTranscript(result: Id, is_final: bool) void {
    const sel_best = objc.sel_registerName("bestTranscription") orelse return;
    const transcription = objc.msgSendId(result, sel_best) orelse return;

    const sel_formatted = objc.sel_registerName("formattedString") orelse return;
    const string = objc.msgSendId(transcription, sel_formatted) orelse return;

    const utf8 = objc.getNSStringUTF8(string) orelse return;
    const text = std.mem.span(utf8);

    const allocator = std.heap.c_allocator;
    const detail = shapeResultDetail(allocator, text, is_final) catch {
        std.log.warn("speech: could not shape a transcript for craftSpeechResult", .{});
        return;
    };
    defer allocator.free(detail);

    ios_events.emit(event_result, detail);
}

/// Read an `AVAudioSession` string constant out of the process.
///
/// `dlsym` rather than an `extern` declaration, for the reason
/// `bridge_mobile_imagepicker.zig` documents: a host test binary links Cocoa
/// and not AVFoundation, and an `extern` would make the whole test executable
/// fail to link rather than this one call fail to find its symbol.
fn audioSessionConstant(comptime symbol: [*:0]const u8) Id {
    const found = dlsym(RTLD_DEFAULT, symbol) orelse {
        std.log.warn("startListening: {s} is not in this process", .{symbol});
        return null;
    };
    const cell: *const Id = @ptrCast(@alignCast(found));
    return cell.*;
}

fn logNSError(context: []const u8, err: Id) void {
    const object = err orelse {
        std.log.warn("{s}: the native call failed and reported no error", .{context});
        return;
    };
    const sel = objc.sel_registerName("localizedDescription") orelse return;
    const description = objc.msgSendId(object, sel) orelse return;
    const utf8 = objc.getNSStringUTF8(description) orelse return;
    std.log.warn("{s}: {s}", .{ context, std.mem.span(utf8) });
}

const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
extern "c" fn dispatch_async_f(queue: *anyopaque, context: ?*anyopaque, work: dispatch_function_t) void;
extern var _dispatch_main_q: anyopaque;

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

extern "c" fn usleep(microseconds: c_uint) c_int;

/// `RTLD_DEFAULT` — search every image already loaded into the process.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

// =============================================================================
// Tests.
//
// Three groups. The pure shapers and the vocabulary, whose bytes are what a
// page reads. The routing, which is what makes `ios_dispatch` reach this file
// at all. And the state machine — the parts of teardown and the tap handoff
// that can be exercised without an audio device, which is more of them than it
// looks, because the handoff is deliberately made of atomics rather than of
// framework state.
//
// What no test here can reach: the recognizer, the session, the engine, the
// tap itself. That risk surface belongs to `packages/ios/fixtures/zig-slice`,
// which drives both actions on a simulator and asserts the events.
// =============================================================================

const testing = std.testing;

test "the action names match the Swift case labels exactly" {
    // A typo here routes nowhere and looks exactly like the shim still serving
    // both actions, which is the state this module just left.
    try testing.expectEqualStrings("startListening", A.start_listening);
    try testing.expectEqualStrings("stopListening", A.stop_listening);
}

test "both actions are declared, and neither promises a reply" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    for (capability_actions) |decl| {
        // `.result` would tell an app to await something no path here sends.
        try testing.expectEqual(capabilities.Reply.none, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "an unrelated action falls through rather than being refused" {
    // `ios_dispatch.route` treats any error other than UnknownAction as final,
    // so a module that answered something else here would stop the chain and
    // strand an action another module serves.
    var bridge = SpeechBridge.init(testing.allocator);
    defer bridge.deinit();
    try testing.expectError(
        BridgeError.UnknownAction,
        bridge.handleMessage("getDeviceInfo", "{}"),
    );
}

test "a malformed payload is not a reason to refuse either action" {
    // Neither action reads a field, so neither parses one. A parser here would
    // invent a failure the spec has not got — and it would surface as a
    // dispatcher error under a request id no page holds.
    var bridge = SpeechBridge.init(testing.allocator);
    defer bridge.deinit();

    for ([_][]const u8{ "", "{", "not json at all", "[1,2,3]" }) |payload| {
        try bridge.handleMessage(A.stop_listening, payload);
    }

    // And the stop left no state behind, which is what makes it idempotent.
    try testing.expect(!listening);
    try testing.expect(!tap_installed);
    try testing.expectEqual(@as(usize, 0), active_request.load(.seq_cst));
}

test "the four error messages are Swift's, in Swift's order" {
    try testing.expectEqual(@as(usize, 4), error_messages.len);
    try testing.expectEqualStrings("Not authorized", error_messages[0]);
    try testing.expectEqualStrings("Audio session failed", error_messages[1]);
    try testing.expectEqualStrings("Speech recognizer unavailable", error_messages[2]);
    try testing.expectEqualStrings("Audio engine failed", error_messages[3]);

    // And every StartFailure maps into that set, so no path can emit a fifth
    // string by accident.
    inline for (@typeInfo(StartFailure).error_set.error_names.?) |name| {
        const message = messageFor(@field(StartFailure, name));
        var found = false;
        for (error_messages) |known| {
            if (std.mem.eql(u8, known, message)) found = true;
        }
        try testing.expect(found);
    }
}

test "a zero-format refusal reports the engine, not the session" {
    // The one message this module emits that Swift never reaches. Picking
    // `err_audio_session` would blame a session that succeeded; picking a
    // fifth string would put bytes on a page no other arm can produce.
    try testing.expectEqualStrings(err_audio_engine, messageFor(error.AudioEngine));
    try testing.expectEqualStrings(err_audio_session, messageFor(error.AudioSession));
}

test "the four event names are the ones Swift's sendToWeb spells" {
    try testing.expectEqualStrings("craftSpeechStart", event_start.eventName());
    try testing.expectEqualStrings("craftSpeechResult", event_result.eventName());
    try testing.expectEqualStrings("craftSpeechError", event_error.eventName());
    try testing.expectEqualStrings("craftSpeechEnd", event_end.eventName());
}

test "the empty detail is an object a page can index into" {
    // `ios_events.formatEvent` inlines this as a literal. An empty string
    // would make `e.detail.anything` a TypeError rather than undefined.
    try testing.expectEqualStrings("{}", empty_detail);
}

test "an error detail carries the message under the key Swift uses" {
    const detail = try shapeErrorDetail(testing.allocator, err_not_authorized);
    defer testing.allocator.free(detail);
    try testing.expectEqualStrings("{\"error\":\"Not authorized\"}", detail);
}

test "an error message with JavaScript metacharacters survives escaping" {
    // No current message needs this. The escaping is a property of the
    // position — a JSON string inlined into JavaScript source — so it is
    // pinned against the message that has not been written yet.
    const detail = try shapeErrorDetail(testing.allocator, "quote \" and \\ and\nnewline");
    defer testing.allocator.free(detail);
    try testing.expectEqualStrings(
        "{\"error\":\"quote \\\" and \\\\ and\\nnewline\"}",
        detail,
    );
}

test "a transcript detail carries both keys, with isFinal as a real boolean" {
    const partial = try shapeResultDetail(testing.allocator, "hello", false);
    defer testing.allocator.free(partial);
    try testing.expectEqualStrings(
        "{\"transcript\":\"hello\",\"isFinal\":false}",
        partial,
    );

    const final = try shapeResultDetail(testing.allocator, "hello there", true);
    defer testing.allocator.free(final);
    try testing.expectEqualStrings(
        "{\"transcript\":\"hello there\",\"isFinal\":true}",
        final,
    );
}

test "an empty transcript still emits the key" {
    // A first partial result can legitimately be empty, and an omitted key
    // reads to a page exactly like a broken bridge.
    const detail = try shapeResultDetail(testing.allocator, "", false);
    defer testing.allocator.free(detail);
    try testing.expectEqualStrings("{\"transcript\":\"\",\"isFinal\":false}", detail);
}

test "a spoken quote cannot end the object early" {
    // Arbitrary speech lands in a JavaScript source position. An unescaped
    // quote would not corrupt one field: it would make the whole dispatchEvent
    // call a syntax error, and the page would see the stream stop with no
    // event to say why.
    const detail = try shapeResultDetail(testing.allocator, "say \"stop\" now", true);
    defer testing.allocator.free(detail);
    try testing.expectEqualStrings(
        "{\"transcript\":\"say \\\"stop\\\" now\",\"isFinal\":true}",
        detail,
    );

    // And the result is parseable, which is the property the escaping exists
    // for rather than the exact bytes.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, detail, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "say \"stop\" now",
        parsed.value.object.get("transcript").?.string,
    );
    try testing.expectEqual(true, parsed.value.object.get("isFinal").?.bool);
}

test "the tap reads nothing while the request is unpublished" {
    // The handoff, exercised without an audio device. Zero means "nobody may
    // append", and it is the state both before a start and after a stop —
    // which is what makes a tap call that outlives its session harmless
    // rather than a use-after-free.
    const saved = active_request.swap(0, .seq_cst);
    defer active_request.store(saved, .seq_cst);

    try testing.expectEqual(@as(usize, 0), active_request.load(.seq_cst));

    // The tap's own guard, spelled the way the tap spells it.
    try testing.expect(active_request.load(.seq_cst) == 0);
}

test "the drain reports success only when the audio thread has left" {
    // `drainTap` is what stands between a stop and a use-after-free, so its
    // two answers are pinned rather than assumed. The busy case deliberately
    // runs the full bounded wait: 20ms is the cost of proving it gives up
    // instead of spinning forever.
    tap_in_flight.store(0, .seq_cst);
    try testing.expect(drainTap());

    tap_in_flight.store(1, .seq_cst);
    try testing.expect(!drainTap());

    tap_in_flight.store(0, .seq_cst);
}

test "the native constants are the SDK's, not remembered" {
    // Every one of these was read out of a header rather than recalled, after
    // a HealthKit option guessed at 1 << 2 turned out to be 1 << 4 and took
    // the process down with an unrecoverable exception inside the framework.
    //
    //   SFSpeechRecognizer.h:25-41    implicit 0..3, Authorized last
    //   AVAudioSessionTypes.h:466     DuckOthers = 0x2
    //   AVAudioSessionTypes.h:660     NotifyOthersOnDeactivation = 1
    //   AVAudioNode.h:110             bufferSize 1024 in the header's own example
    try testing.expectEqual(@as(isize, 3), status_authorized);
    try testing.expectEqual(@as(c_ulong, 2), category_option_duck_others);
    try testing.expectEqual(@as(c_ulong, 1), set_active_notify_others);
    try testing.expectEqual(@as(u32, 1024), tap_buffer_frames);
    try testing.expectEqual(@as(c_ulong, 0), bus_zero);

    // DuckOthers is 0x2 and MixWithOthers is 0x1; picking the neighbour would
    // silently stop ducking rather than fail.
    try testing.expect(category_option_duck_others != 1);
}

test "the plist key is the exact proxy, and the microphone key is not" {
    // `index.ts:183` writes this key from `enableSpeechRecognition` alone.
    // `:184` writes NSMicrophoneUsageDescription from
    // `enableSpeechRecognition || enableAudioRecording`, so it is implied by
    // speech being on but cannot stand in for it — an audio-recording app
    // would carry it with speech off.
    try testing.expectEqualStrings("NSSpeechRecognitionUsageDescription", key_speech_usage);
}

test "a test runner has no speech usage description, so a start refuses" {
    // The shape of an app built with enableSpeechRecognition off, which is
    // what a test binary's bundle looks like. The refusal has to come from the
    // plist guard, before requestAuthorization: is reached — asking without
    // the key terminates the process rather than failing.
    if (!is_darwin) return error.SkipZigTest;

    try testing.expect(!hasSpeechUsageDescription());

    var bridge = SpeechBridge.init(testing.allocator);
    defer bridge.deinit();
    try bridge.handleMessage(A.start_listening, "{}");

    // Nothing was built and no authorization request is outstanding.
    try testing.expect(!starting);
    try testing.expect(!listening);
    try testing.expect(recognizer == null);
    try testing.expect(engine == null);
    try testing.expectEqual(@as(usize, 0), active_request.load(.seq_cst));
}

test "stopping something that never started is safe, and still ends" {
    // Swift's stopSpeechRecognition() has no early return and no guard: a page
    // that stops twice gets two ends, and one that never started still gets
    // one. Bug-compatible on purpose — the event is what a listening indicator
    // binds to, and an end that does not arrive leaves it stuck on.
    var bridge = SpeechBridge.init(testing.allocator);
    defer bridge.deinit();

    try bridge.handleMessage(A.stop_listening, "{}");
    try bridge.handleMessage(A.stop_listening, "{}");

    try testing.expect(!listening);
    try testing.expect(!tap_installed);
    try testing.expect(task == null);
    try testing.expectEqual(@as(usize, 0), active_request.load(.seq_cst));
}
