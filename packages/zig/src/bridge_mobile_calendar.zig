//! `getCalendarEvents`, `createCalendarEvent`, `deleteCalendarEvent` — EventKit,
//! ported from `CraftApp.swift:716-731` (dispatch) and `3289-3361` (the three
//! implementations). Every claim below is measured against those lines.
//!
//! Three actions, three different reply shapes, and one of them is not even
//! asynchronous. Nothing here emits: there is no `sendToWeb(` anywhere in
//! `CraftApp.swift:3289-3361`, no calendar member in `ios_events.Event`, and no
//! `craftCalendar*` event name on the iOS side at all — the one
//! `_craftCalendarResolve` the repo does contain is the *Android* template's
//! promise holder (`packages/android/templates/CraftBridge.kt.template:397`),
//! not something `dispatchEvent` ever carries. So `ios_events` is deliberately
//! not imported. There is no runtime delegate either — EventKit answers through a
//! completion block, not a protocol — so `ios_delegate` is not imported.
//!
//! ## The payloads, field by field, from the injected JS
//!
//! The only page surface is `window.craft.calendar.*` (`CraftApp.swift:1783-1808`).
//! There are no flat aliases; `packages/ios/README.md:329-341`,
//! `packages/typescript/types/craft.d.ts:282-295` and both
//! `templates/test-bridges.html:831,842` document and call a
//! `window.craft.getCalendarEvents(...)` that has never existed. Those harness
//! tests throw `TypeError` inside their own `try` and never reach the bridge, so
//! the harness gives **zero** evidence about anything here. The contract below
//! comes from `resolveCallback`/`rejectCallback` and `.fragmentsAllowed`, which
//! is what actually runs.
//!
//!   - `getCalendarEvents` posts `{startDate, endDate}` **top-level**, read as
//!     `body["startDate"] as? Double`. They are **milliseconds**: Swift divides
//!     by 1000 to make an `NSTimeInterval` (3297-3298).
//!   - `createCalendarEvent` posts `{event: {...}}` — a **nested object**, whose
//!     keys are `title`, `location`, `notes`, `startDate`, `endDate`, `isAllDay`.
//!   - `deleteCalendarEvent` posts `{eventId}` top-level, a string.
//!
//! `callbackId` is the shim's own correlation and never reaches a Zig module;
//! `ios_async` owns the request id here.
//!
//! **None of these promises has a timeout.** All three are hand-built
//! `new Promise` (1788, 1796, 1804) rather than going through `_createCallback`
//! (1196-1210, the only thing carrying the 30-second `setTimeout`). An
//! unanswered call parks the page forever, which is why every path in this file
//! ends in a reply or an error.
//!
//! ## One rule for wrong-typed fields, applied everywhere
//!
//! Swift reads every field through `as? T`, which yields nil for the wrong type
//! and then falls back to a default — `?? ""`, `?? false`, `Date()`, or "leave
//! the property unset". That means `craft.calendar.getEvents('2024-01-01')`
//! silently returns events from **now to now + 1 month**, and the page cannot
//! tell. So:
//!
//!   - **Absent, or JSON `null`** → Swift's documented default, reproduced
//!     exactly. That is the real contract and it is honoured.
//!   - **Present and of a type `as? T` accepts** → accepted identically,
//!     including the `NSNumber`-as-`Bool` rule where only `0` and `1` are
//!     booleans (the same rule `bridge_mobile_contactpicker.zig:448-460` spells
//!     out for `multiple`).
//!   - **Present and of a type `as? T` rejects** → `INVALID_PARAMETER`, naming
//!     the field, rather than the shim's silent default. This is a divergence
//!     and it is deliberate: a range the page did not ask for, answered as
//!     success, is the wrong-answer-reported-as-success class this migration
//!     exists to remove. `bridge_mobile_motion.zig:760-775` made the same call
//!     for `interval`.
//!
//! One case is not a preference but a limit: `true as? Double` on a
//! `__NSCFBoolean` is a genuine wart whose answer differs between Foundation
//! versions and is not settled here. `{"startDate":true}` is refused rather than
//! guessed at in either direction; it is nonsense on any reading.
//!
//! A string containing an embedded NUL is also refused. `stringWithUTF8String:`
//! stops at the NUL, so carrying it across would silently create an event with a
//! truncated title, where Swift's `as? String` preserves the whole thing.
//!
//! The same refusal applies in the *outbound* direction, and it is coarser
//! there: `readString` compares `UTF8String`'s NUL-terminated bytes against
//! `lengthOfBytesUsingEncoding:`, so an existing calendar event whose title
//! contains U+0000 fails the whole `getCalendarEvents` call rather than one row.
//! Swift's `JSONSerialization` would have carried it. Reporting a prefix as the
//! whole title is the one thing worse than failing, and a partial list is the
//! other; this is the same call `bridge_mobile_notifications.zig` and
//! `bridge_mobile_contactpicker.zig` already made.
//!
//! ## The three reply shapes, from `resolveCallback` + `.fragmentsAllowed`
//!
//!   - **`getCalendarEvents` resolves a bare JSON array of objects** (3303-3315),
//!     seven keys each, **always all seven present**: `id`, `title`, `location`,
//!     `notes`, `startDate`, `endDate`, `isAllDay`. `location` and `notes` are
//!     `""` when the event has none — never omitted and never `null`, whatever
//!     `craft.d.ts:1174-1183` says with its `location?: string`. The runtime is
//!     the contract. `startDate`/`endDate` are **fractional milliseconds**.
//!     Swift's `[String: Any]` has no key order at all, so one is fixed here to
//!     make the bytes testable — the same call `shapeFix` makes in
//!     `bridge_mobile_location.zig:611`. An empty result is `[]` and **resolves**.
//!   - **`createCalendarEvent` resolves a bare JSON string** — the new
//!     `eventIdentifier` (3342) — **or bare `null`**. `EKEvent.eventIdentifier`
//!     is `String!`, and a nil implicitly-unwrapped optional coerced to `Any`
//!     becomes `Optional<String>.none`, which `.fragmentsAllowed` renders as
//!     `null`. Same path `bridge_mobile_securestore.zig:23-24` documents for
//!     `secureGet`.
//!   - **`deleteCalendarEvent` resolves bare `true`** (3357), not `undefined`.
//!     `craft.d.ts:295` declares `Promise<void>`; the wire value is `true`.
//!
//! ### The `payload || {}` hazard, which bites exactly one value
//!
//! Zig replies through `bridge_error.sendResultToJS` →
//! `window.__craftBridgeResult`, and `js/craft-bridge.js:80` resolves
//! `payload || {}`. Through **this** route a falsy fragment is coerced:
//! `null → {}`. Swift's own `window.craft._resolveCallback` route does not do
//! that. So a `createCalendarEvent` whose save succeeded but whose
//! `eventIdentifier` came back nil hands the page `{}` rather than `null`.
//!
//! `null` is still sent, deliberately. The alternatives are worse: rejecting
//! would tell the page the event was **not** created when it **was** — the
//! mirror image of fabricated success — and substituting `""` is swallowed by
//! `|| {}` just the same while also being a lie about the identifier. A
//! synthetic id would be a lie the page could act on. This is written down
//! rather than papered over.
//!
//! ## What each action actually does, and where it diverges
//!
//! **Both read paths request access with the deprecated
//! `requestAccessToEntityType:completion:`**, matching Swift 3291/3320, which has
//! **no `if #available` fork** — unlike `requestPermission`
//! (`CraftApp.swift:2852-2867`, which does fork to
//! `requestFullAccessToEvents`). Matching is not laziness: `packages/ios/src/index.ts:190`
//! writes **only** `NSCalendarsUsageDescription`, and
//! `requestFullAccessToEventsWithCompletion:` requires
//! `NSCalendarsFullAccessUsageDescription`, which nothing in this repo ever
//! writes. Calling the iOS 17 API would terminate the app. (Swift's own
//! `requestPermission("calendar")` arm has that latent crash; it is not
//! replicated here.)
//!
//! **The Info.plist key is a hard precondition for the two async actions, not
//! merely evidence of a config flag.** `requestAccessToEntityType:` in a process
//! whose Info.plist lacks the usage description raises
//! `NSInternalInconsistencyException`, which from Zig is an uncatchable SIGABRT.
//! So the gate runs **before** the store is ever touched. This is where the
//! wording deliberately differs from `bridge_mobile_contactpicker.zig`, whose
//! `CNContactPickerViewController` genuinely needs no authorization. For
//! `deleteCalendarEvent` — which requests nothing (3350) — the key is only
//! evidence of `config.enableCalendar`, and it is checked for that reason.
//!
//! **`config.enableCalendar` has no Zig mirror**, the same gap
//! `bridge_mobile_contactpicker.zig` records for `enableContacts`. The plist key
//! `packages/ios/src/index.ts:190` writes iff that flag is the stand-in, and the
//! mapping is exact — nothing else writes or shares it.
//!
//! **Behaviour changes on every disabled or malformed path, in Zig's favour.**
//! Swift's three cases have no `else` (717-731): an app with
//! `enableCalendar: false`, a `createCalendarEvent` with no `event` object, and a
//! `deleteCalendarEvent` with no `eventId` string all answer the page with
//! **nothing**, on a promise with no timeout — a hang for the life of the page.
//! Here they are `PERMISSION_DENIED`, `MISSING_DATA` and `MISSING_DATA`.
//! Everybody settles, which is strictly better, and it is observable.
//!
//! **A permission denial rejects `PERMISSION_DENIED`, not `NATIVE_CALL_FAILED`.**
//! `ios_async.deliverErrorCode` exists for exactly this. The message is
//! byte-identical to `createCalendarEvent`'s (3322) and to `getCalendarEvents`'
//! fallback (3293); the code changes from Swift's default `CRAFT_ERROR`, which is
//! the accurate cause rather than the historical one.
//! `getCalendarEvents`' other variant — `error?.localizedDescription`, a
//! localised EventKit string — is **not** reproducible through `BridgeError` and
//! is not claimed: it goes to the log instead.
//!
//! **`deleteCalendarEvent` requests no permission, and that is reproduced
//! faithfully even though it is misleading.** `eventWithIdentifier:` returns nil
//! both for an absent event and for an unauthorized store, so on a fresh install
//! every delete says "Event not found" (`NOT_FOUND` here). Adding a permission
//! request would show the user a prompt at a moment the shim never shows one.
//!
//! **A save that fails is refused with the reason logged, never pre-empted.**
//! `defaultCalendarForNewEvents` can be nil on a freshly-erased simulator or a
//! device with no writable calendar; Swift assigns it unconditionally (3338) and
//! lets `saveEvent:span:error:` fail with "No calendar has been set". The same
//! happens for a missing start or end date, which is why absent nested dates are
//! **not** given a default here. In every case the `NSError` goes to the log and
//! the page gets `NATIVE_CALL_FAILED`; there is no fallback to "the first
//! writable calendar", which would write the event somewhere the shim would not.
//!
//! **A fetched event with a nil `startDate` or `endDate` rejects rather than
//! crashing.** Swift's `event.startDate.timeIntervalSince1970` force-unwraps an
//! implicitly-unwrapped optional. Zig cannot fabricate a `0` there — that would
//! be an event dated 1970 reported as real — so the whole reply is refused with
//! the event's id in the log.
//!
//! `CraftApp.swift:3301` also force-unwraps `predicate!` inside a `[weak self]`
//! closure, which crashes if the coordinator died first. Zig has no `self` and
//! no such hazard; the nil is checked instead of translated.
//!
//! ## Concurrency: a side table, not a single slot
//!
//! The completion block is global (`BLOCK_IS_GLOBAL`, so `Block_copy` is the
//! identity and escaping it to EventKit costs no heap lifetime), which means it
//! captures nothing and knows only the slot index baked into its comptime
//! invoke. Two things therefore live in a per-slot side table: the ticket, and
//! the request parameters the completion still needs — the millisecond range for
//! a fetch, or the parsed event for a save. That is
//! `bridge_mobile_notifications.zig:481-533`'s pattern exactly.
//!
//! A *single* pending slot, as `bridge_mobile_contactpicker.zig` uses, would be
//! wrong here: there is no on-screen picker making concurrency impossible, and
//! two `getCalendarEvents` in flight is an ordinary page. The table is one entry
//! per `ios_async` slot, mutex-guarded, and a full pool is an explicit refusal
//! rather than silence.
//!
//! The strings a pending `createCalendarEvent` owns are allocated from
//! `std.heap.c_allocator` at dispatch and freed by the completion, because the
//! dispatcher's allocator is not guaranteed to outlive the frame and the
//! completion runs long after it is gone.
//!
//! No reply is ever sent from the completion directly. `ios_async` is the only
//! channel, and its main-queue hop is not merely thread safety: it restores the
//! `request_context` captured at dispatch, so the reply names the call that is
//! waiting instead of falling back to action-name matching.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const compat_mutex = @import("compat_mutex.zig");
const memory = @import("memory.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The same type as `objc.id` — `?*anyopaque` — spelled locally, per the
/// location/notifications/contactpicker precedent: `objc_runtime.objc` is an
/// empty struct off Darwin and a function *signature* is analysed even when a
/// comptime platform guard prunes the body, so naming `objc.id` in the
/// `callconv(.c)` types below would break the host build. A single optional
/// pointer, never `?objc.id` — a double optional is illegal in `callconv(.c)`.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches this block against those labels in
/// both directions, and fails the build if two modules declare one name.
pub const A = struct {
    pub const get_calendar_events = "getCalendarEvents";
    pub const create_calendar_event = "createCalendarEvent";
    pub const delete_calendar_event = "deleteCalendarEvent";
};

/// All three are `.result`: every Swift path out of every one of them ends in
/// exactly one `resolveCallback` or one `rejectCallback`. `.none` would be a
/// claim that nothing answers, and on these particular promises — hand-built, no
/// `setTimeout` — that is a page parked forever rather than for thirty seconds.
///
/// All three are `.live`, not `.unavailable`: in an app built with
/// `enableCalendar` all three work. A refusal here is always a specific
/// condition (calendar not configured, EventKit not linked, permission denied,
/// the async pool full), never the normal answer. `.unavailable` would make Zig
/// dispatch and then refuse an action the shim serves.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.get_calendar_events, .reply = .result },
    .{ .name = A.create_calendar_event, .reply = .result },
    .{ .name = A.delete_calendar_event, .reply = .result },
};

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host without touching
/// EventKit.
const Route = enum { get_events, create_event, delete_event };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.get_calendar_events)) return .get_events;
    if (std.mem.eql(u8, action, A.create_calendar_event)) return .create_event;
    if (std.mem.eql(u8, action, A.delete_calendar_event)) return .delete_event;
    return null;
}

pub const CalendarBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const route = routeFor(action) orelse return bridge_error.BridgeError.UnknownAction;
        // Exhaustive, so a `Route` without a handler is a compile error.
        return switch (route) {
            .get_events => self.getCalendarEvents(data),
            .create_event => self.createCalendarEvent(data),
            .delete_event => self.deleteCalendarEvent(data),
        };
    }

    /// `eventStore.requestAccess(to: .event) { … predicateForEvents … }`.
    ///
    /// Ordering is load-bearing. The payload is parsed **first**, so a malformed
    /// body is reported the same on any platform and before any framework is
    /// consulted. Then the Info.plist precondition, then every class and
    /// selector the completion will need — all of it **before**
    /// `ios_async.acquire`, because a completion has no way to report a failed
    /// `sel_registerName` as anything but a log line. After the lease there are
    /// exactly two statements, both infallible: publish the side-table entry
    /// (which the completion reads), then make the framework call. A lease that
    /// escaped without either would narrow the pool for the life of the process.
    ///
    /// The two `NSDate`s are built **inside** the completion rather than here,
    /// which is where Swift builds them (3297-3298). It matters: the user may
    /// spend seconds on the permission sheet, and "now" means now-when-granted
    /// in the shim.
    fn getCalendarEvents(self: *Self, data: []const u8) !void {
        const range = try parseRange(self.allocator, data);

        if (!is_darwin) return error.UnsupportedPlatform;

        try requireCalendarConfigured(A.get_calendar_events);

        const sels = try Sels.resolve(A.get_calendar_events);
        const store = try ensureStore(A.get_calendar_events);

        const ticket = ios_async.acquire(A.get_calendar_events) orelse
            return poolFull(A.get_calendar_events);

        // Published *before* the framework call, never after:
        // `requestAccessToEntityType:` may invoke its completion synchronously
        // when access is already granted, and a completion that found an empty
        // entry would have no ticket to reply with.
        publishPendingCall(ticket, sels, store, .{ .fetch = range });

        requestAccess(store, sels, ticket);
    }

    /// `eventStore.requestAccess(to: .event) { … EKEvent … save … }`.
    ///
    /// Same ordering discipline as the fetch, plus one ownership rule: the
    /// parsed event's strings are allocated from `std.heap.c_allocator` — the
    /// allocator the completion frees them with — and the `errdefer` releases
    /// them on every path that leaves before the side table takes ownership.
    ///
    /// That is also why `self.allocator` goes unused here, unlike in the other
    /// two handlers: the dispatcher's allocator is not promised to outlive this
    /// frame, and the completion runs long after it is gone.
    fn createCalendarEvent(_: *Self, data: []const u8) !void {
        // Not `self.allocator`: this outlives the dispatch frame, and
        // `ios_async` delivers on `std.heap.c_allocator` too.
        const owner = std.heap.c_allocator;
        const new_event = try parseNewEvent(owner, data);
        errdefer new_event.deinit(owner);

        if (!is_darwin) return error.UnsupportedPlatform;

        try requireCalendarConfigured(A.create_calendar_event);

        const sels = try Sels.resolve(A.create_calendar_event);
        const store = try ensureStore(A.create_calendar_event);

        const ticket = ios_async.acquire(A.create_calendar_event) orelse
            return poolFull(A.create_calendar_event);

        // Ownership of `new_event`'s strings moves into the side table here.
        publishPendingCall(ticket, sels, store, .{ .create = new_event });

        requestAccess(store, sels, ticket);
    }

    /// `eventStore.event(withIdentifier:)` then `remove(_:span:)`.
    ///
    /// Fully synchronous — Swift requests no access here (3350) — so there is no
    /// ticket, no block and no side table. The reply goes out on this frame,
    /// where `request_context` still names the call, exactly as
    /// `bridge_mobile_clipboard.zig` replies.
    fn deleteCalendarEvent(self: *Self, data: []const u8) !void {
        const event_id = try parseEventId(self.allocator, data);
        defer self.allocator.free(event_id);

        if (!is_darwin) return error.UnsupportedPlatform;

        try requireCalendarConfigured(A.delete_calendar_event);

        const sels = try Sels.resolve(A.delete_calendar_event);
        const store = try ensureStore(A.delete_calendar_event);

        const ns_id = try makeString(sels, self.allocator, event_id);

        const FindFn = *const fn (Id, Id, Id) callconv(.c) Id;
        const find: FindFn = @ptrCast(&objc.objc_msgSend);
        const event = find(store, sels.event_with_identifier, ns_id) orelse {
            // Also what an *unauthorized* store answers, because this path never
            // requests access. Misleading, and the shim's exact behaviour; see
            // the module comment for why a prompt is not added here.
            std.log.info(
                "deleteCalendarEvent: no event with that identifier (an unauthorized " ++
                    "store answers the same way, since this action requests no access)",
                .{},
            );
            return bridge_error.BridgeError.NotFound;
        };

        var ns_error: Id = null;
        const RemoveFn = *const fn (Id, Id, Id, c_long, ?*Id) callconv(.c) bool;
        const remove: RemoveFn = @ptrCast(&objc.objc_msgSend);
        if (!remove(store, sels.remove_event, event, ek_span_this_event, &ns_error)) {
            logNativeError("deleteCalendarEvent: removeEvent:span:error: failed", ns_error, sels);
            return bridge_error.BridgeError.NativeCallFailed;
        }

        bridge_error.sendResultToJS(self.allocator, A.delete_calendar_event, true_fragment);
    }
};

/// `-[EKEventStore requestAccessToEntityType:completion:]` with this ticket's
/// pre-built global block. Infallible by construction: the store, the selector
/// and the block all exist by the time this is reached.
fn requestAccess(store: Id, sels: Sels, ticket: ios_async.Ticket) void {
    if (!is_darwin) return;

    const RequestFn = *const fn (Id, Id, c_ulong, ?*anyopaque) callconv(.c) void;
    const request: RequestFn = @ptrCast(&objc.objc_msgSend);
    request(store, sels.request_access, ek_entity_type_event, accessBlock(ticket));
}

/// The answer for a full block pool, copied from `bridge_mobile_location`:
/// `BridgeError` has no "Busy", `INVALID_PARAMETER` is the migration notes'
/// designated stand-in, and the point is that the caller gets an explicit
/// rejection instead of a promise that never settles.
fn poolFull(action: []const u8) bridge_error.BridgeError {
    std.log.warn(
        "{s} refused: all {d} async slots are in flight",
        .{ action, ios_async.max_in_flight },
    );
    return bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// Payload parsing. Pure — no Objective-C — so the exact coercions Swift performs
// are pinned by host tests on every platform.
// =============================================================================

/// `getCalendarEvents`' two top-level fields, still in **milliseconds**.
///
/// Kept as milliseconds rather than converted here because the division by 1000
/// is Swift's (3297-3298) and belongs next to the `NSDate` it feeds; a struct
/// holding "seconds" that was filled from a millisecond wire value is exactly
/// the kind of unit slip nothing catches.
const Range = struct {
    start_ms: ?f64 = null,
    end_ms: ?f64 = null,
};

/// The nested `event` object, with every string owned by the caller's allocator.
///
/// The optionals are three-state on the wire and two-state here: absent and
/// JSON `null` both become `null`, which is what Swift's `as? String` produces
/// and what sets the `EKEvent` property to nil. A *wrongly typed* value never
/// reaches this struct — `parseNewEvent` refuses it.
const NewEvent = struct {
    /// `data["title"] as? String ?? ""` — never null.
    title: []const u8,
    location: ?[]const u8,
    notes: ?[]const u8,
    /// Absent stays absent. Swift's `if let` leaves `EKEvent.startDate` nil and
    /// `saveEvent:span:error:` then fails with "No start date has been set";
    /// inventing a default here would create an event the shim refuses to.
    start_ms: ?f64,
    end_ms: ?f64,
    all_day: bool,

    fn deinit(self: NewEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.location) |s| allocator.free(s);
        if (self.notes) |s| allocator.free(s);
    }
};

/// A malformed or non-object `d` is `InvalidJSON` rather than a silent default.
/// It is a Zig-only failure mode — `WKScriptMessage.body` is always a dictionary,
/// so Swift never meets it — but guessing for a body that could not be read
/// would be acting on values the page did not send.
fn parseRange(allocator: std.mem.Allocator, data: []const u8) !Range {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return bridge_error.BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    return .{
        .start_ms = try millisecondsFrom(root.get("startDate"), "startDate"),
        .end_ms = try millisecondsFrom(root.get("endDate"), "endDate"),
    };
}

fn parseNewEvent(allocator: std.mem.Allocator, data: []const u8) !NewEvent {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return bridge_error.BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    // `body["event"] as? [String: Any]` failing makes Swift's whole `case` body
    // not run, which answers the page with nothing on an untimed promise. Two
    // distinct causes, reported distinctly rather than collapsed.
    const event_value = root.get("event") orelse {
        std.log.warn("createCalendarEvent refused: the message carried no 'event' object", .{});
        return bridge_error.BridgeError.MissingData;
    };
    const event = switch (event_value) {
        .object => |obj| obj,
        .null => {
            std.log.warn("createCalendarEvent refused: 'event' was null", .{});
            return bridge_error.BridgeError.MissingData;
        },
        else => {
            std.log.warn("createCalendarEvent refused: 'event' is not an object", .{});
            return bridge_error.BridgeError.InvalidParameter;
        },
    };

    // Built field by field with an errdefer per owned string, so a refusal in a
    // later field does not leak an earlier one.
    const title = (try ownedStringFrom(allocator, event.get("title"), "event.title")) orelse
        try allocator.dupe(u8, "");
    errdefer allocator.free(title);

    const location = try ownedStringFrom(allocator, event.get("location"), "event.location");
    errdefer if (location) |s| allocator.free(s);

    const notes = try ownedStringFrom(allocator, event.get("notes"), "event.notes");
    errdefer if (notes) |s| allocator.free(s);

    return .{
        .title = title,
        .location = location,
        .notes = notes,
        .start_ms = try millisecondsFrom(event.get("startDate"), "event.startDate"),
        .end_ms = try millisecondsFrom(event.get("endDate"), "event.endDate"),
        .all_day = try allDayFrom(event.get("isAllDay")),
    };
}

/// `body["eventId"] as? String`, owned by the caller.
///
/// An empty string is *accepted*: Swift passes it to `event(withIdentifier: "")`,
/// which answers nil, which is "Event not found". Refusing it here would answer a
/// different question than the shim answers.
fn parseEventId(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return bridge_error.BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    const value = root.get("eventId") orelse {
        std.log.warn("deleteCalendarEvent refused: the message carried no 'eventId'", .{});
        return bridge_error.BridgeError.MissingData;
    };

    return switch (value) {
        .null => {
            std.log.warn("deleteCalendarEvent refused: 'eventId' was null", .{});
            return bridge_error.BridgeError.MissingData;
        },
        .string => |s| blk: {
            if (std.mem.indexOfScalar(u8, s, 0) != null) {
                std.log.warn(
                    "deleteCalendarEvent refused: 'eventId' contains an embedded NUL, which " ++
                        "stringWithUTF8String: would silently truncate",
                    .{},
                );
                return bridge_error.BridgeError.InvalidParameter;
            }
            break :blk try allocator.dupe(u8, s);
        },
        else => {
            std.log.warn("deleteCalendarEvent refused: 'eventId' is not a string", .{});
            return bridge_error.BridgeError.InvalidParameter;
        },
    };
}

/// `as? Double`, as a partial function: null for absent, an error for a value
/// `as? Double` would reject.
///
/// `std.json` parks a literal that overflows `i64`, or one written in a form it
/// keeps verbatim, in `.number_string` with scanner-validated source bytes. It is
/// still a number the page sent, so it is read rather than refused for its
/// spelling — the same call `bridge_mobile_motion.zig:785` makes.
///
/// Non-finite is refused: `1e400` parses to `inf`, and an infinite
/// `NSTimeInterval` is not a date. `.bool` is refused too — see the module
/// comment on the `__NSCFBoolean` wart.
fn millisecondsFrom(value: ?std.json.Value, comptime field: []const u8) !?f64 {
    const v = value orelse return null;

    const ms: f64 = switch (v) {
        .null => return null,
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch {
            std.log.warn(
                "calendar refused: '" ++ field ++ "' is a number craft cannot read",
                .{},
            );
            return bridge_error.BridgeError.InvalidParameter;
        },
        else => {
            std.log.warn(
                "calendar refused: '" ++ field ++ "' is not a number; Swift would silently " ++
                    "use its default instead, which the page cannot see",
                .{},
            );
            return bridge_error.BridgeError.InvalidParameter;
        },
    };

    if (!std.math.isFinite(ms)) {
        std.log.warn("calendar refused: '" ++ field ++ "' is not a finite number", .{});
        return bridge_error.BridgeError.InvalidParameter;
    }
    return ms;
}

/// `as? String`, copied into caller-owned memory. Null for absent or JSON null.
fn ownedStringFrom(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    comptime field: []const u8,
) !?[]const u8 {
    const v = value orelse return null;

    return switch (v) {
        .null => null,
        .string => |s| blk: {
            if (std.mem.indexOfScalar(u8, s, 0) != null) {
                std.log.warn(
                    "createCalendarEvent refused: '" ++ field ++ "' contains an embedded NUL, " ++
                        "which stringWithUTF8String: would silently truncate",
                    .{},
                );
                return bridge_error.BridgeError.InvalidParameter;
            }
            break :blk try allocator.dupe(u8, s);
        },
        else => {
            std.log.warn(
                "createCalendarEvent refused: '" ++ field ++ "' is not a string; Swift would " ++
                    "silently use its default instead",
                .{},
            );
            return bridge_error.BridgeError.InvalidParameter;
        },
    };
}

/// `data["isAllDay"] as? Bool ?? false`.
///
/// The accepted set is exactly what a bridged `NSNumber as? Bool` accepts — a
/// real boolean, or the numbers `0` and `1`, the rule
/// `bridge_mobile_contactpicker.zig:448-460` spells out. `2` is truthy in
/// JavaScript and is *not* a Bool to Foundation; Swift turns it into `false`,
/// and here it is refused rather than silently creating a timed event for a page
/// that asked for an all-day one.
fn allDayFrom(value: ?std.json.Value) !bool {
    const v = value orelse return false;

    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |i| switch (i) {
            0 => false,
            1 => true,
            else => return allDayRefused(),
        },
        .float => |f| if (f == 0.0) false else if (f == 1.0) true else return allDayRefused(),
        else => return allDayRefused(),
    };
}

/// Always an error. Split out so the four refusing arms above say the same
/// thing once, and so each arm stays an expression.
fn allDayRefused() bridge_error.BridgeError {
    std.log.warn(
        "createCalendarEvent refused: 'event.isAllDay' is not a boolean Foundation would " ++
            "accept (only true/false and the numbers 0 and 1 are); Swift would silently use " ++
            "false instead",
        .{},
    );
    return bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// Reply shaping. Pure — no Objective-C — so the exact bytes the page receives
// are pinned by host tests.
// =============================================================================

/// `resolveCallback(callbackId, result: true)` under `.fragmentsAllowed`.
/// Static, so the delete reply allocates nothing.
const true_fragment = "true";

/// One `EKEvent` as Swift's `eventData` map reads it (3304-3312).
///
/// The four strings are already `?? ""`-collapsed: nil `location` is `""` on the
/// wire, not a missing key and not `null`, whichever way `craft.d.ts` declares
/// it. The strings borrow whatever buffer they were read from — on the native
/// path an `NSString`'s internal UTF-8, valid for the completion's autorelease
/// pool — and every one is copied into the JSON before that returns.
const CalEvent = struct {
    id: []const u8,
    title: []const u8,
    location: []const u8,
    notes: []const u8,
    /// `timeIntervalSince1970 * 1000` — fractional milliseconds, not an integer.
    start_ms: f64,
    end_ms: f64,
    all_day: bool,
};

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    try out.append(allocator, '"');
    // Titles, locations and notes are user data and will contain `"` and `\` in
    // the wild. This reply is replayed into the source `evaluateJavaScript:`
    // parses, so an unescaped quote is a syntax error in the page rather than a
    // wrong field.
    try bridge_error.appendJsonEscaped(allocator, out, s);
    try out.append(allocator, '"');
}

/// One `f64` as a JSON number.
///
/// `{d}` renders decimal notation, never scientific, and a finite `f64` can need
/// up to `std.fmt.float.bufferSize(.decimal, f64)` (347) bytes. Non-finite is
/// refused rather than printed: `inf` and `nan` are not JSON, Swift's own
/// `JSONSerialization` refuses them too, and printing them would produce a
/// syntax error inside the reply script with nothing to point at.
///
/// A benign divergence, stated rather than hidden: Zig's shortest-round-trip
/// `{d}` and `JSONSerialization`'s renderer can print different digit strings
/// for the same `f64`. Both parse back to the same JavaScript number.
fn appendNumber(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: f64,
) !void {
    if (!std.math.isFinite(value)) return bridge_error.BridgeError.InvalidParameter;
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{value}));
}

/// The `getCalendarEvents` reply: a bare array of seven-key objects.
///
/// Key order is fixed at id, title, location, notes, startDate, endDate,
/// isAllDay — Swift's literal order, which as a `Dictionary` it does not
/// actually preserve. A caller cannot depend on order, but a *test* can only pin
/// bytes that are deterministic.
///
/// An empty list is `[]` and **resolves**. `events.map` over nothing is `[]` in
/// Swift, so turning "no events in that range" into an error would break a path
/// the shim answers successfully.
fn shapeEvents(allocator: std.mem.Allocator, events: []const CalEvent) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '[');
    for (events, 0..) |event, i| {
        if (i != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"id\":");
        try appendJsonString(allocator, &out, event.id);
        try out.appendSlice(allocator, ",\"title\":");
        try appendJsonString(allocator, &out, event.title);
        try out.appendSlice(allocator, ",\"location\":");
        try appendJsonString(allocator, &out, event.location);
        try out.appendSlice(allocator, ",\"notes\":");
        try appendJsonString(allocator, &out, event.notes);
        try out.appendSlice(allocator, ",\"startDate\":");
        try appendNumber(allocator, &out, event.start_ms);
        try out.appendSlice(allocator, ",\"endDate\":");
        try appendNumber(allocator, &out, event.end_ms);
        try out.appendSlice(allocator, ",\"isAllDay\":");
        try out.appendSlice(allocator, if (event.all_day) "true" else "false");
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');

    return out.toOwnedSlice(allocator);
}

/// The `createCalendarEvent` reply: a bare JSON string, or bare `null`.
///
/// `null` is what a nil `eventIdentifier` reaches the page as through Swift, and
/// it is what is sent here — even though `craft-bridge.js:80`'s `payload || {}`
/// turns it into `{}` on the Zig route. See the module comment: rejecting a save
/// that succeeded would be the worse lie, and `""` is swallowed by `|| {}` just
/// the same while additionally being false about the identifier.
fn shapeCreatedId(allocator: std.mem.Allocator, identifier: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (identifier) |id| {
        try appendJsonString(allocator, &out, id);
    } else {
        try out.appendSlice(allocator, "null");
    }

    return out.toOwnedSlice(allocator);
}

/// Swift's `startDate! / 1000` — the wire carries milliseconds and
/// `NSTimeInterval` is seconds. One function so the division has one place to be
/// wrong in, and one test.
fn secondsFromMilliseconds(ms: f64) f64 {
    return ms / 1000.0;
}

// =============================================================================
// Framework constants — transcribed, so pinned by the tests below. This is the
// `bridge_mobile_permissions.zig` convention: a constant nobody can look up at
// runtime is a constant a test has to hold.
// =============================================================================

/// `EKEntityType`: `NSUInteger`. event = 0, reminder = 1. Already pinned once at
/// `bridge_mobile_permissions.zig:497`; pinned again here because a wrong value
/// would request access to reminders and report it as calendar access.
const ek_entity_type_event: c_ulong = 0;

/// `EKSpan`: `NSInteger`. `EKSpanThisEvent` = 0, `EKSpanFutureEvents` = 1.
/// Swift passes `.thisEvent` to both `save` and `remove`; the future-events span
/// would edit or delete every occurrence of a recurring event.
const ek_span_this_event: c_long = 0;

/// `NSCalendarUnitMonth` = `1 << 3` — `NSCalendarUnit`, an `NSUInteger`.
/// Nothing in this repo pinned it before. It is what makes
/// `Calendar.current.date(byAdding: .month, value: 1, to: Date())` (3298) a
/// **calendar month in the user's calendar and time zone** — 28, 29, 30 or 31
/// days depending on when it is called. "+30 days" is a different default range
/// and is not substituted.
const ns_calendar_unit_month: c_ulong = 1 << 3;

/// The `options:` argument of `dateByAddingUnit:value:toDate:options:`.
/// `Calendar.current.date(byAdding:value:to:)` passes no
/// `NSCalendarOptions`, which is 0.
const ns_calendar_options_none: c_ulong = 0;

/// `NSUTF8StringEncoding`. Used only to ask a string how long it really is, so a
/// NUL-truncated read can be told from a short string.
const ns_utf8_string_encoding: c_ulong = 4;

/// The Info.plist key `packages/ios/src/index.ts:190` writes if and only if
/// `config.enableCalendar`.
const key_calendars_usage = "NSCalendarsUsageDescription";

// =============================================================================
// Objective-C: everything looked up once at dispatch, then a completion that
// cannot look anything up.
// =============================================================================

fn selector(name: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.sel_registerName(name) orelse error.SelectorNotFound;
}

/// The main bundle's Info.plist value for `key`, or null when it has none.
///
/// Errors rather than answering null when the runtime itself will not cooperate:
/// "there is no NSBundle class" and "this app was not built with calendar
/// enabled" are different facts, and collapsing them would blame the app's
/// configuration for a broken process.
fn infoPlistValue(comptime key: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSBundle = objc.objc_getClass("NSBundle") orelse return error.ClassNotFound;
    const sel_main = objc.sel_registerName("mainBundle") orelse return error.SelectorNotFound;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return error.NoMainBundle;

    const NSString = objc.objc_getClass("NSString") orelse return error.ClassNotFound;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse
        return error.SelectorNotFound;
    const ns_key = objc.msgSendId1(NSString, sel_string, key) orelse return error.NativeCallFailed;

    const sel_lookup = objc.sel_registerName("objectForInfoDictionaryKey:") orelse
        return error.SelectorNotFound;
    return objc.msgSendId1(bundle, sel_lookup, ns_key);
}

/// Refuse when the app was not built with `enableCalendar`.
///
/// Checked first, matching Swift's `if config.enableCalendar` guarding all three
/// cases, and — for the two actions that request access — checked **before** the
/// store is touched, because `requestAccessToEntityType:` without this key raises
/// `NSInternalInconsistencyException`, which from Zig is an uncatchable SIGABRT.
/// That is the difference from `bridge_mobile_contactpicker.zig`'s gate, which
/// guards a picker needing no authorization at all: here the key is a genuine
/// precondition of the API and not merely evidence of a config flag.
/// `deleteCalendarEvent` requests nothing, so for that one action it *is* only
/// evidence of the flag — which is why it is still checked.
fn requireCalendarConfigured(action: []const u8) !void {
    if (!is_darwin) return error.UnsupportedPlatform;

    if ((try infoPlistValue(key_calendars_usage)) == null) {
        std.log.warn(
            "{s} refused: Info.plist has no {s}, so this app was not built with calendar " ++
                "enabled (and requesting access without it would terminate the process)",
            .{ action, key_calendars_usage },
        );
        return bridge_error.BridgeError.PermissionDenied;
    }
}

/// Everything the completion needs, resolved while a synchronous error can still
/// reach the page.
///
/// The completion runs long after the dispatch frame is gone, where a failed
/// `sel_registerName` could only be logged. Resolving here turns that whole class
/// of failure into an ordinary rejection.
///
/// Four *class* objects ride along for the same reason. `EKEvent` is guarded
/// with a message naming EventKit.framework, because the fix is a link line
/// rather than anything in this file — the zig-slice fixture
/// (`packages/ios/fixtures/zig-slice/build-and-run.sh:65`) links only UIKit,
/// WebKit, Foundation and Security, so this is exactly what it hits.
const Sels = struct {
    // Classes used as receivers of class methods.
    event_class: Id,
    date_class: Id,
    calendar_class: Id,
    string_class: Id,

    // EKEventStore
    request_access: Id,
    predicate_for_events: Id,
    events_matching: Id,
    default_calendar: Id,
    save_event: Id,
    event_with_identifier: Id,
    remove_event: Id,

    // EKEvent (class method, then getters, then setters)
    event_with_event_store: Id,
    event_identifier: Id,
    title: Id,
    location: Id,
    notes: Id,
    start_date: Id,
    end_date: Id,
    /// The property is `allDay` with `getter=isAllDay`; the selector really is
    /// `isAllDay` and the setter really is `setAllDay:`.
    is_all_day: Id,
    set_title: Id,
    set_location: Id,
    set_notes: Id,
    set_start_date: Id,
    set_end_date: Id,
    set_all_day: Id,
    set_calendar: Id,

    // NSDate
    date_with_interval: Id,
    time_interval_since_1970: Id,
    date_now: Id,

    // NSCalendar
    current_calendar: Id,
    date_by_adding_unit: Id,

    // NSArray
    count: Id,
    object_at: Id,

    // NSString
    utf8: Id,
    length_of_bytes: Id,
    string_with_utf8: Id,

    // NSError, for the log line a BridgeError cannot carry.
    localized_description: Id,

    fn resolve(action: []const u8) !Sels {
        if (!is_darwin) return error.UnsupportedPlatform;

        const event_class = objc.objc_getClass("EKEvent") orelse {
            std.log.err(
                "{s} refused: this process has no EKEvent; EventKit.framework is not linked",
                .{action},
            );
            return bridge_error.BridgeError.PlatformNotSupported;
        };
        const date_class = objc.objc_getClass("NSDate") orelse return error.ClassNotFound;
        const calendar_class = objc.objc_getClass("NSCalendar") orelse return error.ClassNotFound;
        const string_class = objc.objc_getClass("NSString") orelse return error.ClassNotFound;

        return .{
            .event_class = event_class,
            .date_class = date_class,
            .calendar_class = calendar_class,
            .string_class = string_class,

            .request_access = try selector("requestAccessToEntityType:completion:"),
            .predicate_for_events = try selector("predicateForEventsWithStartDate:endDate:calendars:"),
            .events_matching = try selector("eventsMatchingPredicate:"),
            .default_calendar = try selector("defaultCalendarForNewEvents"),
            .save_event = try selector("saveEvent:span:error:"),
            .event_with_identifier = try selector("eventWithIdentifier:"),
            .remove_event = try selector("removeEvent:span:error:"),

            .event_with_event_store = try selector("eventWithEventStore:"),
            .event_identifier = try selector("eventIdentifier"),
            .title = try selector("title"),
            .location = try selector("location"),
            .notes = try selector("notes"),
            .start_date = try selector("startDate"),
            .end_date = try selector("endDate"),
            .is_all_day = try selector("isAllDay"),
            .set_title = try selector("setTitle:"),
            .set_location = try selector("setLocation:"),
            .set_notes = try selector("setNotes:"),
            .set_start_date = try selector("setStartDate:"),
            .set_end_date = try selector("setEndDate:"),
            .set_all_day = try selector("setAllDay:"),
            .set_calendar = try selector("setCalendar:"),

            .date_with_interval = try selector("dateWithTimeIntervalSince1970:"),
            .time_interval_since_1970 = try selector("timeIntervalSince1970"),
            .date_now = try selector("date"),

            .current_calendar = try selector("currentCalendar"),
            .date_by_adding_unit = try selector("dateByAddingUnit:value:toDate:options:"),

            .count = try selector("count"),
            .object_at = try selector("objectAtIndex:"),

            .utf8 = try selector("UTF8String"),
            .length_of_bytes = try selector("lengthOfBytesUsingEncoding:"),
            .string_with_utf8 = try selector("stringWithUTF8String:"),

            .localized_description = try selector("localizedDescription"),
        };
    }
};

/// The one `EKEventStore`, created on first use and never released.
///
/// `bridge_mobile_permissions.zig:33-38` names this as the exact reason it left
/// calendar's `requestPermission` with the shim: the store has to outlive the
/// dispatch frame, because the completion is what answers. Swift keeps one as a
/// coordinator property for the life of the app (`CraftApp.swift:406, 452-453`)
/// and so does this — a lazily created, never-released singleton, which is the
/// same object graph rather than a new mechanism.
///
/// Creating a store neither prompts nor requires authorization; only
/// `requestAccessToEntityType:` does, and the Info.plist gate runs before this.
var event_store: Id = null;
var store_mutex: compat_mutex.Mutex = .{};

fn ensureStore(action: []const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    store_mutex.lock();
    defer store_mutex.unlock();

    if (event_store) |existing| return existing;

    const StoreClass = objc.objc_getClass("EKEventStore") orelse {
        std.log.err(
            "{s} refused: this process has no EKEventStore; EventKit.framework is not linked",
            .{action},
        );
        return bridge_error.BridgeError.PlatformNotSupported;
    };

    const store = (try objc.allocInit(StoreClass)) orelse return error.NativeCallFailed;
    event_store = store;
    return store;
}

/// `+[NSString stringWithUTF8String:]` over caller bytes.
///
/// The classes and selectors come from `Sels`, resolved at dispatch, so this
/// performs no lookups and can be called from the completion. A nil result means
/// the bytes were not valid UTF-8 — refused, never substituted.
fn makeString(sels: Sels, allocator: std.mem.Allocator, text: []const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const z = try memory.dupeZ(allocator, u8, text);
    defer allocator.free(z);

    return objc.msgSendId1(sels.string_class, sels.string_with_utf8, z.ptr) orelse
        error.NativeCallFailed;
}

/// One `NSString` as bytes, or a refusal.
///
/// The truncation check is why this is not one line. `UTF8String` hands back a
/// NUL-terminated buffer, so a value containing U+0000 — which
/// `JSONSerialization` would have preserved on the Swift side — reads back as its
/// prefix. `lengthOfBytesUsingEncoding:` counts the real encoded bytes, so a
/// mismatch is exactly that case, and reporting a prefix as the whole title is
/// the one thing worse than failing.
///
/// The returned slice borrows the string's internal buffer, valid for the
/// current autorelease pool; every caller copies it into the reply before
/// returning.
fn readString(ns: Id, sels: Sels) ![]const u8 {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (ns == null) return error.NilNativeString;

    const Utf8Fn = *const fn (Id, Id) callconv(.c) ?[*:0]const u8;
    const utf8: Utf8Fn = @ptrCast(&objc.objc_msgSend);
    const cstr = utf8(ns, sels.utf8) orelse return error.NativeCallFailed;
    const text = std.mem.span(cstr);

    const LenFn = *const fn (Id, Id, c_ulong) callconv(.c) c_ulong;
    const len_of: LenFn = @ptrCast(&objc.objc_msgSend);
    if (len_of(ns, sels.length_of_bytes, ns_utf8_string_encoding) != text.len) {
        return error.EmbeddedNulInNativeString;
    }

    return text;
}

/// `readString` for the four `EKEvent` properties that are genuinely nullable.
/// Null is not a failure here — `title`, `location`, `notes` and
/// `eventIdentifier` are all `nullable` and Swift coalesces every one of them.
fn readOptionalString(ns: Id, sels: Sels) !?[]const u8 {
    if (ns == null) return null;
    return try readString(ns, sels);
}

/// The `NSError`'s `localizedDescription`, for a log line.
///
/// Never for a reply: `BridgeError` carries a fixed code and message, so a
/// localised EventKit string has nowhere to go on the wire. Saying it in the log
/// is the honest half of that, and claiming it reached the page would be the
/// dishonest one.
fn errorText(err: Id, sels: Sels) ?[]const u8 {
    if (!is_darwin) return null;
    if (err == null) return null;

    const description = objc.msgSendId(err, sels.localized_description) orelse return null;
    return readString(description, sels) catch null;
}

fn logNativeError(comptime prefix: []const u8, err: Id, sels: Sels) void {
    if (errorText(err, sels)) |text| {
        std.log.err(prefix ++ ": {s}", .{text});
    } else {
        // Possible in principle, and said rather than asserted: `NO` with a nil
        // `NSError` gets `NATIVE_CALL_FAILED` and a log line admitting there was
        // no message, instead of a message that was never received.
        std.log.err(prefix ++ " (no NSError was provided)", .{});
    }
}

/// `+[NSDate dateWithTimeIntervalSince1970:]` on the wire's milliseconds.
fn dateFromMilliseconds(sels: Sels, ms: f64) Id {
    if (!is_darwin) return null;

    const DateFn = *const fn (Id, Id, f64) callconv(.c) Id;
    const make: DateFn = @ptrCast(&objc.objc_msgSend);
    return make(sels.date_class, sels.date_with_interval, secondsFromMilliseconds(ms));
}

/// `+[NSDate date]` — Swift's `Date()`, evaluated inside the completion exactly
/// where Swift evaluates it.
fn nowDate(sels: Sels) Id {
    if (!is_darwin) return null;
    return objc.msgSendId(sels.date_class, sels.date_now);
}

/// `Calendar.current.date(byAdding: .month, value: 1, to: Date())!` (3298).
///
/// A **calendar month**, not thirty days: the length depends on the month and on
/// the user's calendar and time zone. Swift force-unwraps the result; here a nil
/// is checked, which is the same hazard `CraftApp.swift:3301` has with
/// `predicate!` and the reason neither force-unwrap is translated.
fn defaultEndDate(sels: Sels) Id {
    if (!is_darwin) return null;

    const calendar = objc.msgSendId(sels.calendar_class, sels.current_calendar) orelse return null;
    const now = nowDate(sels) orelse return null;

    const AddFn = *const fn (Id, Id, c_ulong, c_long, Id, c_ulong) callconv(.c) Id;
    const add: AddFn = @ptrCast(&objc.objc_msgSend);
    return add(
        calendar,
        sels.date_by_adding_unit,
        ns_calendar_unit_month,
        1,
        now,
        ns_calendar_options_none,
    );
}

/// Read one `EKEvent` the way Swift's `eventData` map reads it (3304-3312).
///
/// Every string is `?? ""`-collapsed, including the identifier — that is the
/// fetch shape, and it is *not* the create shape, where a nil identifier is bare
/// `null`. The two are deliberately not shared.
///
/// `startDate` and `endDate` are the exception: Swift force-unwraps them
/// (`event.startDate.timeIntervalSince1970`) and would crash on nil. There is no
/// `?? ""` to copy and no honest substitute — `0` would be an event dated 1 Jan
/// 1970 reported as real — so a nil date refuses the whole reply.
fn readEvent(event: Id, sels: Sels) !CalEvent {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (event == null) return error.NativeCallFailed;

    const DoubleFn = *const fn (Id, Id) callconv(.c) f64;
    const send_double: DoubleFn = @ptrCast(&objc.objc_msgSend);
    const BoolFn = *const fn (Id, Id) callconv(.c) bool;
    const send_bool: BoolFn = @ptrCast(&objc.objc_msgSend);

    const start = objc.msgSendId(event, sels.start_date) orelse {
        logEventMissingDate(event, sels, "startDate");
        return error.EventHasNoStartDate;
    };
    const end = objc.msgSendId(event, sels.end_date) orelse {
        logEventMissingDate(event, sels, "endDate");
        return error.EventHasNoEndDate;
    };

    return .{
        .id = (try readOptionalString(objc.msgSendId(event, sels.event_identifier), sels)) orelse "",
        .title = (try readOptionalString(objc.msgSendId(event, sels.title), sels)) orelse "",
        .location = (try readOptionalString(objc.msgSendId(event, sels.location), sels)) orelse "",
        .notes = (try readOptionalString(objc.msgSendId(event, sels.notes), sels)) orelse "",
        .start_ms = send_double(start, sels.time_interval_since_1970) * 1000.0,
        .end_ms = send_double(end, sels.time_interval_since_1970) * 1000.0,
        .all_day = send_bool(event, sels.is_all_day),
    };
}

/// Name the event a nil date refused, which is the only thing that makes the
/// refusal actionable: "one of your events has no start date" cannot be looked
/// up, and `getCalendarEvents` fails as a whole rather than per row.
///
/// Best-effort on the id itself. An event broken enough to have a nil
/// `startDate` may have an unreadable `eventIdentifier` too, and the *cause*
/// matters more than the id, so an unreadable one degrades to a placeholder
/// rather than replacing the log line with a different failure.
fn logEventMissingDate(event: Id, sels: Sels, comptime which: []const u8) void {
    if (!is_darwin) return;

    const id_ns = objc.msgSendId(event, sels.event_identifier);
    const id_text = (readOptionalString(id_ns, sels) catch null) orelse "<unreadable>";
    std.log.err(
        "getCalendarEvents: event '{s}' has no " ++ which ++ "; refusing the whole reply " ++
            "rather than dating it 1970",
        .{id_text},
    );
}

/// Walk `NSArray<EKEvent *>` into `CalEvent` entries.
///
/// A nil array is refused rather than answered `[]`. `events(matching:)` returns
/// a non-optional `[EKEvent]`; Swift's `?? []` guards `self?` being nil, not the
/// array, so nil here would mean the framework broke its own contract and "there
/// are no events in that range" is a claim with no basis.
fn readEvents(allocator: std.mem.Allocator, array: Id, sels: Sels) ![]CalEvent {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (array == null) return error.NativeCallFailed;

    const CountFn = *const fn (Id, Id) callconv(.c) c_ulong;
    const count_of: CountFn = @ptrCast(&objc.objc_msgSend);
    const total = count_of(array, sels.count);

    var out: std.ArrayListUnmanaged(CalEvent) = .empty;
    errdefer out.deinit(allocator);

    var i: c_ulong = 0;
    while (i < total) : (i += 1) {
        const event = objc.msgSendId1(array, sels.object_at, i) orelse return error.NativeCallFailed;
        try out.append(allocator, try readEvent(event, sels));
    }

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// The per-slot completion block, and the side table that gives it a ticket.
//
// A global block captures nothing, which is what makes `Block_copy` on it the
// identity function and removes every lifetime question. The price is that the
// block knows only its own slot index, baked in at comptime — so the ticket, the
// selectors resolved at dispatch, the store, and the request's own parameters
// are looked up here.
// =============================================================================

/// What the completion still has to do, and everything it needs to do it.
const Request = union(enum) {
    fetch: Range,
    create: NewEvent,

    fn deinit(self: Request, allocator: std.mem.Allocator) void {
        switch (self) {
            .fetch => {},
            .create => |event| event.deinit(allocator),
        }
    }
};

const PendingCall = struct {
    ticket: ios_async.Ticket,
    sels: Sels,
    store: Id,
    request: Request,
};

/// One entry per `ios_async` slot, not one entry total.
///
/// `bridge_mobile_contactpicker.zig`'s single `pending` is right for a modal
/// picker, where a second call cannot happen while the first is on screen.
/// Nothing here is modal: two `getCalendarEvents` in flight is an ordinary page,
/// and a single slot would refuse the second for no reason.
var pending_calls: [ios_async.max_in_flight]?PendingCall = @splat(null);
var pending_mutex: compat_mutex.Mutex = .{};

/// Record the call a slot's block will answer. The slot is leased exclusively by
/// this ticket, so the entry is ours to write.
fn publishPendingCall(ticket: ios_async.Ticket, sels: Sels, store: Id, request: Request) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls[ticket.index] = .{
        .ticket = ticket,
        .sels = sels,
        .store = store,
        .request = request,
    };
}

/// Read and clear a slot's entry. Clearing is what makes a second fire of the
/// same completion a no-op rather than a second reply — and, here, rather than a
/// double free of the pending event's strings.
fn takePendingCall(index: u5) ?PendingCall {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const call = pending_calls[index];
    pending_calls[index] = null;
    return call;
}

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// `void (^)(BOOL granted, NSError *error)` — the shape of
/// `-[EKEventStore requestAccessToEntityType:completion:]`.
///
/// `ios_async.boolErrorBlock` has this exact invoke shape and is still the wrong
/// block for two of these three actions: it replies the strings
/// `"granted"`/`"denied"`, and the page is owed the *events* or the new
/// *identifier*. A grant is the beginning of the work here, not the answer.
const AccessBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// 1 << 28. `Block_copy` on a global block returns the same pointer, so a
/// module-level block can be handed to an API that escapes it with no heap copy,
/// no copy/dispose helpers, and no descriptor lifetime.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

const access_block_descriptor = BlockDescriptor{ .size = @sizeOf(AccessBlock) };

extern var _NSConcreteGlobalBlock: anyopaque;

/// One invoke per slot, comptime-generated so each block knows which slot it is
/// without capturing anything.
fn makeAccessInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const AccessBlock, granted: bool, err: Id) callconv(.c) void {
            accessCompletionFired(index, granted, err);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeAccessBlocks() [ios_async.max_in_flight]AccessBlock {
    var out: [ios_async.max_in_flight]AccessBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = makeAccessInvoke(@intCast(i)),
            .descriptor = &access_block_descriptor,
        };
    }
    return out;
}

var access_blocks: [ios_async.max_in_flight]AccessBlock =
    if (is_darwin) makeAccessBlocks() else undefined;

fn accessBlock(ticket: ios_async.Ticket) *anyopaque {
    return @ptrCast(&access_blocks[ticket.index]);
}

/// Runs on whatever queue EventKit chose.
///
/// Nothing replies from here: `evaluateJavaScript:` is main-thread-only *and* the
/// `request_context` that names the waiting call is long gone, so every answer
/// goes through `ios_async`, which copies the payload, hops to the main queue,
/// and replies under the id captured back at dispatch.
///
/// The blocking EventKit work — `eventsMatchingPredicate:`, `saveEvent:` — is
/// deliberately done *here*, on the background queue, which is where Swift does
/// it too.
fn accessCompletionFired(index: u5, granted: bool, err: Id) void {
    if (!is_darwin) return;

    const allocator = std.heap.c_allocator;

    const call = takePendingCall(index) orelse {
        std.log.warn(
            "calendar: an access completion fired for slot {d} with no call recorded; ignored " ++
                "rather than answered to whoever holds the slot next",
            .{index},
        );
        return;
    };
    // The pending event's strings belong to this call whichever way it ends.
    defer call.request.deinit(allocator);

    if (!granted) {
        if (errorText(err, call.sels)) |text| {
            std.log.warn(
                "calendar: access to events was not granted ({s}); rejecting as PERMISSION_DENIED " ++
                    "(Swift sends CRAFT_ERROR with this text, which BridgeError cannot carry)",
                .{text},
            );
        } else {
            std.log.warn(
                "calendar: access to events was not granted; rejecting as PERMISSION_DENIED",
                .{},
            );
        }
        // A user declining a prompt is not a native call failing — the call
        // worked and the answer is "no". `deliverError`'s NATIVE_CALL_FAILED
        // would send whoever reads it looking for a bug that is not there.
        ios_async.deliverErrorCode(call.ticket, bridge_error.BridgeError.PermissionDenied);
        return;
    }

    switch (call.request) {
        .fetch => |range| runFetch(call.ticket, call.sels, call.store, range),
        .create => |event| runCreate(call.ticket, call.sels, call.store, event),
    }
}

/// The granted half of `getCalendarEvents` (3297-3315).
fn runFetch(ticket: ios_async.Ticket, sels: Sels, store: Id, range: Range) void {
    if (!is_darwin) return;

    const allocator = std.heap.c_allocator;

    const start = (if (range.start_ms) |ms| dateFromMilliseconds(sels, ms) else nowDate(sels)) orelse {
        std.log.err("getCalendarEvents: the start date could not be built; rejecting", .{});
        ios_async.deliverError(ticket);
        return;
    };
    const end = (if (range.end_ms) |ms| dateFromMilliseconds(sels, ms) else defaultEndDate(sels)) orelse {
        std.log.err(
            "getCalendarEvents: the end date could not be built (Calendar.current + 1 month " ++
                "answered nil); rejecting rather than substituting a range the page did not ask for",
            .{},
        );
        ios_async.deliverError(ticket);
        return;
    };

    const PredicateFn = *const fn (Id, Id, Id, Id, Id) callconv(.c) Id;
    const make_predicate: PredicateFn = @ptrCast(&objc.objc_msgSend);
    // `calendars: nil` — every calendar, as Swift passes (3300).
    const predicate = make_predicate(
        store,
        sels.predicate_for_events,
        start,
        end,
        @as(Id, null),
    ) orelse {
        std.log.err("getCalendarEvents: predicateForEventsWithStartDate: answered nil; rejecting", .{});
        ios_async.deliverError(ticket);
        return;
    };

    const array = objc.msgSendId1(store, sels.events_matching, predicate);

    const events = readEvents(allocator, array, sels) catch |read_err| {
        std.log.err(
            "getCalendarEvents: could not read the matched events ({}); rejecting rather than " ++
                "replying with a list that was not read",
            .{read_err},
        );
        ios_async.deliverError(ticket);
        return;
    };
    defer allocator.free(events);

    const json = shapeEvents(allocator, events) catch |shape_err| {
        std.log.err("getCalendarEvents: could not shape the reply ({}); rejecting", .{shape_err});
        ios_async.deliverError(ticket);
        return;
    };
    defer allocator.free(json);

    // An empty range is `[]` and resolves — see `shapeEvents`.
    ios_async.deliverJson(ticket, json);
}

/// The granted half of `createCalendarEvent` (3326-3346).
///
/// Field for field with Swift, including the two things that look like
/// omissions and are not: `location`/`notes` are assigned even when nil (Swift
/// assigns the result of `as? String` unconditionally), and `startDate`/`endDate`
/// are assigned only when present (Swift's `if let`), which is what lets
/// `saveEvent:` fail with "No start date has been set" instead of this file
/// inventing a date.
fn runCreate(ticket: ios_async.Ticket, sels: Sels, store: Id, new_event: NewEvent) void {
    if (!is_darwin) return;

    const allocator = std.heap.c_allocator;

    const EventFn = *const fn (Id, Id, Id) callconv(.c) Id;
    const make_event: EventFn = @ptrCast(&objc.objc_msgSend);
    const event = make_event(sels.event_class, sels.event_with_event_store, store) orelse {
        std.log.err("createCalendarEvent: +[EKEvent eventWithEventStore:] answered nil; rejecting", .{});
        ios_async.deliverError(ticket);
        return;
    };

    const ns_title = makeString(sels, allocator, new_event.title) catch |err| {
        std.log.err("createCalendarEvent: the title could not be bridged to NSString ({}); rejecting", .{err});
        ios_async.deliverError(ticket);
        return;
    };
    objc.msgSendVoid1(event, sels.set_title, ns_title);

    // Assigned even when absent: Swift writes `event.location = data["location"]
    // as? String`, which stores nil. Skipping the message would be a different
    // call, not a shortcut.
    const ns_location: Id = if (new_event.location) |text| makeString(sels, allocator, text) catch |err| {
        std.log.err("createCalendarEvent: the location could not be bridged to NSString ({}); rejecting", .{err});
        ios_async.deliverError(ticket);
        return;
    } else null;
    objc.msgSendVoid1(event, sels.set_location, ns_location);

    const ns_notes: Id = if (new_event.notes) |text| makeString(sels, allocator, text) catch |err| {
        std.log.err("createCalendarEvent: the notes could not be bridged to NSString ({}); rejecting", .{err});
        ios_async.deliverError(ticket);
        return;
    } else null;
    objc.msgSendVoid1(event, sels.set_notes, ns_notes);

    if (new_event.start_ms) |ms| {
        const date = dateFromMilliseconds(sels, ms) orelse {
            std.log.err("createCalendarEvent: the start date could not be built; rejecting", .{});
            ios_async.deliverError(ticket);
            return;
        };
        objc.msgSendVoid1(event, sels.set_start_date, date);
    }
    if (new_event.end_ms) |ms| {
        const date = dateFromMilliseconds(sels, ms) orelse {
            std.log.err("createCalendarEvent: the end date could not be built; rejecting", .{});
            ios_async.deliverError(ticket);
            return;
        };
        objc.msgSendVoid1(event, sels.set_end_date, date);
    }

    objc.msgSendVoid1(event, sels.set_all_day, new_event.all_day);

    // Unconditional, exactly as Swift's 3338. `defaultCalendarForNewEvents` is
    // nullable — a freshly erased simulator, or a device with no writable
    // calendar, answers nil — and assigning nil is what lets `saveEvent:` fail
    // with "No calendar has been set". Pre-empting that with a synthetic check
    // would claim a different cause, and falling back to the first writable
    // calendar would write the event somewhere the shim would not.
    objc.msgSendVoid1(event, sels.set_calendar, objc.msgSendId(store, sels.default_calendar));

    var ns_error: Id = null;
    const SaveFn = *const fn (Id, Id, Id, c_long, ?*Id) callconv(.c) bool;
    const save: SaveFn = @ptrCast(&objc.objc_msgSend);
    if (!save(store, sels.save_event, event, ek_span_this_event, &ns_error)) {
        logNativeError("createCalendarEvent: saveEvent:span:error: failed", ns_error, sels);
        ios_async.deliverError(ticket);
        return;
    }

    const identifier = readOptionalString(objc.msgSendId(event, sels.event_identifier), sels) catch |err| {
        std.log.err(
            "createCalendarEvent: the event was saved but its identifier could not be read ({}); " ++
                "rejecting rather than replying with an identifier that was not read",
            .{err},
        );
        ios_async.deliverError(ticket);
        return;
    };

    if (identifier == null) {
        std.log.warn(
            "createCalendarEvent: the event was saved but eventIdentifier was nil; replying " ++
                "bare null, which craft-bridge.js's `payload || {{}}` turns into {{}} on this route",
            .{},
        );
    }

    const json = shapeCreatedId(allocator, identifier) catch |err| {
        std.log.err("createCalendarEvent: could not shape the reply ({}); rejecting", .{err});
        ios_async.deliverError(ticket);
        return;
    };
    defer allocator.free(json);

    ios_async.deliverJson(ticket, json);
}

// =============================================================================
// Tests — host-only.
//
// Everything that decides page-visible bytes is pure and pinned here: routing in
// both directions, every `as? T` coercion and every refusal, the seven keys and
// their order, the empty-array resolve, the bare-null create reply, the bare-true
// delete reply, escaping, the transcribed constants, and the per-slot side table
// that makes two calls in flight possible.
//
// Nothing here creates an `EKEventStore` or matches a predicate. The one
// Objective-C path a host *does* reach is the Info.plist gate, and it is
// exercised for real, because the test runner is exactly the process without a
// usage description that the gate exists for — the same call
// `bridge_mobile_notifications.zig` makes with the bundle identifier.
// =============================================================================

const testing = std.testing;

/// The side table is module state, and a test that left an entry behind would
/// make the next one read someone else's call.
fn resetPendingForTesting() void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls = @splat(null);
}

fn fakeTicket(index: u5, generation: u32) ios_async.Ticket {
    return .{ .index = index, .generation = generation };
}

fn fakeSels() Sels {
    // Every field is a plain `Id`; nothing below dereferences them, and the
    // side-table behaviour under test does not care what they point at.
    return std.mem.zeroes(Sels);
}

// ---------------------------------------------------------------------------
// The table, and the dispatch it claims to describe
// ---------------------------------------------------------------------------

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 3), capability_actions.len);
    try testing.expectEqualStrings(A.get_calendar_events, capability_actions[0].name);
    try testing.expectEqualStrings(A.create_calendar_event, capability_actions[1].name);
    try testing.expectEqualStrings(A.delete_calendar_event, capability_actions[2].name);

    for (capability_actions) |decl| {
        // A `.result` whose handler never replies parks the caller on a promise
        // with no timeout; a `.none` that is awaited resolves immediately and
        // means nothing. Swift resolves or rejects every path, so `.result`.
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        // `.unavailable` would make Zig dispatch and then refuse an action the
        // shim serves correctly.
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        // `.live` with a reason would be a contradiction the manifest shows apps.
        try testing.expect(decl.reason == null);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares this block against the `case "…":` labels
    // in `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("getCalendarEvents", A.get_calendar_events);
    try testing.expectEqualStrings("createCalendarEvent", A.create_calendar_event);
    try testing.expectEqualStrings("deleteCalendarEvent", A.delete_calendar_event);
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

test "each calendar action routes to its own handler" {
    try testing.expectEqual(Route.get_events, routeFor("getCalendarEvents").?);
    try testing.expectEqual(Route.create_event, routeFor("createCalendarEvent").?);
    try testing.expectEqual(Route.delete_event, routeFor("deleteCalendarEvent").?);
}

test "an action this module does not serve is refused as UnknownAction" {
    // Not any other error: `ios_dispatch.route` reads UnknownAction as "not mine,
    // ask the next module" and anything else as a final answer. Getting this
    // wrong would make this file swallow another module's action — or the shim's.
    var bridge = CalendarBridge.init(testing.allocator);
    defer bridge.deinit();

    for ([_][]const u8{
        // Neighbours in the same tier, and the reminders actions EventKit also
        // serves — none of which this module implements.
        "getContacts",
        "addContact",
        "pickContact",
        "getReminders",
        "createReminder",
        "requestPermission",
        // Casing and pluralisation are how a real typo arrives, and a miss does
        // not fail loudly: the action would quietly fall through to the shim.
        "getcalendarevents",
        "GetCalendarEvents",
        "getCalendarEvent",
        "createCalendarEvents",
        "deleteCalendarEvents",
        "",
    }) |action| {
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(action, "{}"),
        );
        try testing.expect(routeFor(action) == null);
    }
}

// ---------------------------------------------------------------------------
// Payload parsing: getCalendarEvents
// ---------------------------------------------------------------------------

test "an absent range is absent, so the native side can apply Swift's defaults" {
    // `ios_dispatch.payloadOf` hands an absent `d` through as `{}`, which is the
    // first case. Both fields must come back null rather than 0 — a zero would be
    // 1 Jan 1970 and would fetch a range nobody asked for.
    const empty = try parseRange(testing.allocator, "{}");
    try testing.expect(empty.start_ms == null);
    try testing.expect(empty.end_ms == null);

    const other = try parseRange(testing.allocator, "{\"unrelated\":1}");
    try testing.expect(other.start_ms == null);
    try testing.expect(other.end_ms == null);

    // JSON null is the same as absent — `NSNull as? Double` is nil, and Swift
    // defaults.
    const nulls = try parseRange(testing.allocator, "{\"startDate\":null,\"endDate\":null}");
    try testing.expect(nulls.start_ms == null);
    try testing.expect(nulls.end_ms == null);
}

test "a numeric range is carried through in milliseconds, undivided" {
    // The wire is milliseconds and `NSTimeInterval` is seconds; the division
    // belongs next to the NSDate, not here. A struct holding "seconds" filled
    // from a millisecond value is the unit slip nothing catches.
    const range = try parseRange(
        testing.allocator,
        "{\"startDate\":1700000000000,\"endDate\":1700003600000.5}",
    );
    try testing.expectEqual(@as(f64, 1700000000000), range.start_ms.?);
    try testing.expectEqual(@as(f64, 1700003600000.5), range.end_ms.?);
}

test "a wrong-typed range field is refused rather than silently defaulted" {
    // This is the divergence the module comment argues for. Swift's `as? Double`
    // answers nil and then uses `Date()` / `Date() + 1 month`, so
    // `getEvents('2024-01-01')` resolves with events from a range the page never
    // asked for and cannot detect. Refusing is observable.
    for ([_][]const u8{
        "{\"startDate\":\"2024-01-01\"}",
        "{\"endDate\":\"2024-01-01\"}",
        "{\"startDate\":[1,2]}",
        "{\"endDate\":{\"ms\":1}}",
        // The `__NSCFBoolean` wart: whether Foundation would read this as 1.0 is
        // genuinely unsettled, and it is nonsense on either reading.
        "{\"startDate\":true}",
        "{\"endDate\":false}",
    }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            parseRange(testing.allocator, body),
        );
    }
}

test "a range literal too wide for i64 is read, and a non-finite one is refused" {
    // `std.json` parks both in `.number_string`: one is a number the page really
    // sent, the other is not a date at all.
    const wide = try parseRange(testing.allocator, "{\"startDate\":123456789012345678901}");
    try testing.expectEqual(@as(f64, 123456789012345678901.0), wide.start_ms.?);

    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseRange(testing.allocator, "{\"startDate\":1e400}"),
    );
}

test "a body that is not a JSON object is InvalidJSON, never a default range" {
    for ([_][]const u8{ "[]", "5", "\"nope\"", "{", "" }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidJSON,
            parseRange(testing.allocator, body),
        );
    }
}

// ---------------------------------------------------------------------------
// Payload parsing: createCalendarEvent
// ---------------------------------------------------------------------------

test "a message with no event object is MissingData, not the shim's silence" {
    // Swift's `case` is `if config.enableCalendar, let eventData = body["event"]
    // as? [String: Any]`, with no `else` — the page's hand-built promise never
    // settles. An explicit rejection is strictly better and is observable.
    for ([_][]const u8{ "{}", "{\"title\":\"no wrapper\"}", "{\"event\":null}" }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.MissingData,
            parseNewEvent(testing.allocator, body),
        );
    }
}

test "an event that is not an object is InvalidParameter, distinct from absent" {
    for ([_][]const u8{
        "{\"event\":\"Standup\"}",
        "{\"event\":42}",
        "{\"event\":[{\"title\":\"a\"}]}",
        "{\"event\":true}",
    }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            parseNewEvent(testing.allocator, body),
        );
    }
}

test "an empty event object takes Swift's defaults exactly" {
    // `title` is `?? ""`; `location` and `notes` are plain `as? String`, so nil;
    // `isAllDay` is `?? false`; and both dates are left **unset**, which is what
    // makes `saveEvent:` fail with "No start date has been set" instead of this
    // file inventing one.
    const event = try parseNewEvent(testing.allocator, "{\"event\":{}}");
    defer event.deinit(testing.allocator);

    try testing.expectEqualStrings("", event.title);
    try testing.expect(event.location == null);
    try testing.expect(event.notes == null);
    try testing.expect(event.start_ms == null);
    try testing.expect(event.end_ms == null);
    try testing.expect(!event.all_day);
}

test "every event field the page sends is carried, none of them dropped" {
    const event = try parseNewEvent(
        testing.allocator,
        "{\"event\":{\"title\":\"Standup\",\"location\":\"Room 2\",\"notes\":\"bring laptop\"," ++
            "\"startDate\":1700000000000,\"endDate\":1700003600000,\"isAllDay\":true}}",
    );
    defer event.deinit(testing.allocator);

    try testing.expectEqualStrings("Standup", event.title);
    try testing.expectEqualStrings("Room 2", event.location.?);
    try testing.expectEqualStrings("bring laptop", event.notes.?);
    try testing.expectEqual(@as(f64, 1700000000000), event.start_ms.?);
    try testing.expectEqual(@as(f64, 1700003600000), event.end_ms.?);
    try testing.expect(event.all_day);
}

test "an explicitly null location or notes is nil, which is not the empty string" {
    // Three states on the wire collapse to two here, exactly as `as? String`
    // collapses them: nil sets the EKEvent property to nil, and `""` sets it to
    // an empty string. They are different events.
    const nulled = try parseNewEvent(
        testing.allocator,
        "{\"event\":{\"location\":null,\"notes\":null}}",
    );
    defer nulled.deinit(testing.allocator);
    try testing.expect(nulled.location == null);
    try testing.expect(nulled.notes == null);

    const empty = try parseNewEvent(
        testing.allocator,
        "{\"event\":{\"location\":\"\",\"notes\":\"\"}}",
    );
    defer empty.deinit(testing.allocator);
    try testing.expectEqualStrings("", empty.location.?);
    try testing.expectEqualStrings("", empty.notes.?);
}

test "a wrong-typed event string is refused rather than silently defaulted" {
    for ([_][]const u8{
        "{\"event\":{\"title\":42}}",
        "{\"event\":{\"title\":true}}",
        "{\"event\":{\"location\":[\"Room 2\"]}}",
        "{\"event\":{\"notes\":{\"text\":\"x\"}}}",
    }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            parseNewEvent(testing.allocator, body),
        );
    }
}

test "a wrong-typed nested date is refused before any framework call" {
    // Swift's `if let … as? Double` leaves the property unset and `saveEvent:`
    // rejects with "No start date has been set". Both end in a rejection; this
    // one names the actual cause and happens before EventKit is touched.
    for ([_][]const u8{
        "{\"event\":{\"startDate\":\"2024-01-01T09:00:00Z\"}}",
        "{\"event\":{\"endDate\":\"2024-01-01T10:00:00Z\"}}",
        "{\"event\":{\"startDate\":1e400}}",
    }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            parseNewEvent(testing.allocator, body),
        );
    }
}

test "isAllDay accepts exactly what NSNumber-as-Bool accepts" {
    // `as? Bool` on a bridged NSNumber succeeds for a real boolean and for the
    // numbers 0 and 1, and for nothing else. `2` is truthy in JavaScript and is
    // still not a Bool.
    const cases = [_]struct { body: []const u8, expected: bool }{
        .{ .body = "{\"event\":{\"isAllDay\":true}}", .expected = true },
        .{ .body = "{\"event\":{\"isAllDay\":false}}", .expected = false },
        .{ .body = "{\"event\":{\"isAllDay\":1}}", .expected = true },
        .{ .body = "{\"event\":{\"isAllDay\":0}}", .expected = false },
        .{ .body = "{\"event\":{\"isAllDay\":1.0}}", .expected = true },
        .{ .body = "{\"event\":{\"isAllDay\":0.0}}", .expected = false },
        .{ .body = "{\"event\":{\"isAllDay\":null}}", .expected = false },
    };
    for (cases) |case| {
        const event = try parseNewEvent(testing.allocator, case.body);
        defer event.deinit(testing.allocator);
        try testing.expectEqual(case.expected, event.all_day);
    }

    for ([_][]const u8{
        "{\"event\":{\"isAllDay\":2}}",
        "{\"event\":{\"isAllDay\":0.5}}",
        "{\"event\":{\"isAllDay\":\"yes\"}}",
        "{\"event\":{\"isAllDay\":[]}}",
    }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            parseNewEvent(testing.allocator, body),
        );
    }
}

test "an embedded NUL in an event string is refused rather than truncated" {
    // `stringWithUTF8String:` stops at the NUL, so carrying this across would
    // create an event titled "Stand" and report success. Swift's `as? String`
    // keeps the whole thing.
    for ([_][]const u8{
        "{\"event\":{\"title\":\"Stand\\u0000up\"}}",
        "{\"event\":{\"location\":\"Room\\u00002\"}}",
        "{\"event\":{\"notes\":\"a\\u0000b\"}}",
    }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            parseNewEvent(testing.allocator, body),
        );
    }
}

// ---------------------------------------------------------------------------
// Payload parsing: deleteCalendarEvent
// ---------------------------------------------------------------------------

test "an eventId that is absent is MissingData and one that is mistyped is InvalidParameter" {
    for ([_][]const u8{ "{}", "{\"id\":\"E1\"}", "{\"eventId\":null}" }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.MissingData,
            parseEventId(testing.allocator, body),
        );
    }
    for ([_][]const u8{
        "{\"eventId\":42}",
        "{\"eventId\":true}",
        "{\"eventId\":[\"E1\"]}",
        // A NUL would make `eventWithIdentifier:` look up a different string
        // than the page sent.
        "{\"eventId\":\"E\\u00001\"}",
    }) |body| {
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            parseEventId(testing.allocator, body),
        );
    }
}

test "an empty eventId is accepted, because the shim accepts it and answers not-found" {
    // Refusing it here would answer a different question than the shim answers:
    // `event(withIdentifier: "")` is nil, which is "Event not found".
    const id = try parseEventId(testing.allocator, "{\"eventId\":\"\"}");
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("", id);
}

test "an eventId is copied, so it survives the parse tree being freed" {
    const id = try parseEventId(testing.allocator, "{\"eventId\":\"E-1234-ABCD\"}");
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("E-1234-ABCD", id);
}

// ---------------------------------------------------------------------------
// Reply shaping
// ---------------------------------------------------------------------------

const sample_event = CalEvent{
    .id = "E1",
    .title = "Standup",
    .location = "Room 2",
    .notes = "bring laptop",
    .start_ms = 1700000000000,
    .end_ms = 1700003600000,
    .all_day = false,
};

test "one event carries all seven keys, in a fixed order, as a bare array" {
    const json = try shapeEvents(testing.allocator, &.{sample_event});
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "[{\"id\":\"E1\",\"title\":\"Standup\",\"location\":\"Room 2\"," ++
            "\"notes\":\"bring laptop\",\"startDate\":1700000000000," ++
            "\"endDate\":1700003600000,\"isAllDay\":false}]",
        json,
    );
}

test "an event with no location or notes still carries both keys, as empty strings" {
    // `craft.d.ts:1174-1183` declares them optional; the runtime emits
    // `event.location ?? ""` unconditionally, and the runtime is the contract. A
    // page reading `e.location.length` must not meet undefined.
    var event = sample_event;
    event.location = "";
    event.notes = "";

    const json = try shapeEvents(testing.allocator, &.{event});
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"location\":\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"notes\":\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "null") == null);
}

test "an empty result is [] and resolves, rather than being an error" {
    const json = try shapeEvents(testing.allocator, &.{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("[]", json);
}

test "several events are separated, and every one is complete" {
    var second = sample_event;
    second.id = "E2";
    second.title = "Retro";
    second.all_day = true;

    const json = try shapeEvents(testing.allocator, &.{ sample_event, second });
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const array = parsed.value.array;
    try testing.expectEqual(@as(usize, 2), array.items.len);
    for (array.items) |item| {
        const object = item.object;
        try testing.expectEqual(@as(usize, 7), object.count());
        for ([_][]const u8{ "id", "title", "location", "notes", "startDate", "endDate", "isAllDay" }) |key| {
            try testing.expect(object.get(key) != null);
        }
    }
    try testing.expectEqualStrings("E2", array.items[1].object.get("id").?.string);
    try testing.expect(array.items[1].object.get("isAllDay").?.bool);
}

test "isAllDay is a JSON boolean, not the string \"true\"" {
    // `"false"` is truthy in JavaScript, so a quoted flag would make every timed
    // event read as all-day.
    var event = sample_event;
    event.all_day = true;

    const json = try shapeEvents(testing.allocator, &.{event});
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(std.json.Value.bool, std.meta.activeTag(parsed.value.array.items[0].object.get("isAllDay").?));
}

test "user text is escaped rather than breaking the reply script" {
    // Titles, locations and notes are user data and will contain quotes and
    // backslashes in the wild. The reply is replayed into the source
    // `evaluateJavaScript:` parses, so an unescaped quote is a syntax error in
    // the page rather than a wrong field.
    var event = sample_event;
    event.id = "E\"1";
    event.title = "1:1 with \"Sam\"";
    event.location = "C:\\Rooms\\2";
    event.notes = "line one\nline two\ttabbed";

    const json = try shapeEvents(testing.allocator, &.{event});
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const object = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("E\"1", object.get("id").?.string);
    try testing.expectEqualStrings("1:1 with \"Sam\"", object.get("title").?.string);
    try testing.expectEqualStrings("C:\\Rooms\\2", object.get("location").?.string);
    try testing.expectEqualStrings("line one\nline two\ttabbed", object.get("notes").?.string);
}

test "the timestamps keep their fraction rather than being truncated to a millisecond" {
    // `timeIntervalSince1970 * 1000` is a fractional double. Rounding it would be
    // a quiet change to a value pages use to order and place events.
    var event = sample_event;
    event.start_ms = 1700000000123.456;
    event.end_ms = 1700003600987.5;

    const json = try shapeEvents(testing.allocator, &.{event});
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"startDate\":1700000000123.456") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"endDate\":1700003600987.5") != null);
}

test "a non-finite timestamp is refused, not printed" {
    // `inf` and `nan` are not JSON. Printing either would produce a syntax error
    // inside the reply script with nothing to point at; `JSONSerialization`
    // refuses them too. Both fields are checked, because one unguarded call site
    // is all it takes.
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |bad| {
        var start_bad = sample_event;
        start_bad.start_ms = bad;
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            shapeEvents(testing.allocator, &.{start_bad}),
        );

        var end_bad = sample_event;
        end_bad.end_ms = bad;
        try testing.expectError(
            bridge_error.BridgeError.InvalidParameter,
            shapeEvents(testing.allocator, &.{end_bad}),
        );
    }
}

test "the created event's reply is a bare JSON string" {
    const json = try shapeCreatedId(testing.allocator, "E-1234-ABCD");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("\"E-1234-ABCD\"", json);
}

test "a nil identifier is bare null, not an empty string and not a rejection" {
    // Swift's `resolveCallback(id, result: event.eventIdentifier)` on a nil
    // implicitly-unwrapped optional renders `null` under `.fragmentsAllowed`.
    // Rejecting would tell the page the event was not created when it was;
    // `""` is swallowed by `payload || {}` just the same *and* is false about the
    // identifier. See the module comment.
    const json = try shapeCreatedId(testing.allocator, null);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("null", json);
}

test "an identifier is escaped like any other user-visible string" {
    const json = try shapeCreatedId(testing.allocator, "E\"1\\2");
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("\"E\\\"1\\\\2\"", json);
}

test "the delete reply is bare true, which is what the page resolves" {
    // `craft.d.ts:295` declares `Promise<void>`; `resolveCallback(id, result:
    // true)` puts `true` on the wire. `payload || {}` passes `true` through
    // unchanged, so this is the one reply here the coercion does not touch.
    try testing.expectEqualStrings("true", true_fragment);
}

test "milliseconds become seconds exactly once" {
    // Swift divides at the NSDate (3297-3298, 3332, 3335). Doing it twice, or
    // not at all, moves every event by a factor of a thousand — 1970 or the year
    // 55000, both of which look like data rather than a bug.
    try testing.expectEqual(@as(f64, 1700000000), secondsFromMilliseconds(1700000000000));
    try testing.expectEqual(@as(f64, 0), secondsFromMilliseconds(0));
    try testing.expectEqual(@as(f64, -1.5), secondsFromMilliseconds(-1500));
    try testing.expectEqual(@as(f64, 1700000000.1234), secondsFromMilliseconds(1700000000123.4));
}

// ---------------------------------------------------------------------------
// Transcribed constants
// ---------------------------------------------------------------------------

test "the framework constants are the ones the headers give" {
    // Transcribed from headers rather than read from the runtime, so a test is
    // the only thing holding them. A wrong entity type requests reminders and
    // reports it as calendar access; a wrong span edits or deletes every
    // occurrence of a recurring event; a wrong calendar unit changes the default
    // range from a month to a day or a year.
    try testing.expectEqual(@as(c_ulong, 0), ek_entity_type_event);
    try testing.expectEqual(@as(c_long, 0), ek_span_this_event);
    try testing.expectEqual(@as(c_ulong, 8), ns_calendar_unit_month);
    try testing.expectEqual(@as(c_ulong, 0), ns_calendar_options_none);
    try testing.expectEqual(@as(c_ulong, 4), ns_utf8_string_encoding);
    try testing.expectEqualStrings("NSCalendarsUsageDescription", key_calendars_usage);
}

test "the deprecated access request is the one this file makes" {
    // Swift 3291/3320 call `requestAccessToEntityType:` with no availability
    // fork, and `packages/ios/src/index.ts:190` writes only
    // NSCalendarsUsageDescription. The iOS 17 replacement needs
    // NSCalendarsFullAccessUsageDescription, which nothing in this repo writes,
    // so calling it would terminate the app.
    //
    // The needle is the *call* form rather than the bare API name, so the prose
    // in this file cannot match itself and the assertion keeps meaning
    // something — which is why the needle is not spelled out in any comment,
    // including this one.
    const source = @embedFile("bridge_mobile_calendar.zig");
    try testing.expect(std.mem.indexOf(u8, source, "selector(\"requestFullAccess") == null);
    // Non-vacuity: the same scan finds the call that is present, so a needle
    // that stopped matching anything could not pass unnoticed.
    try testing.expect(std.mem.indexOf(u8, source, "selector(\"requestAccessToEntityType") != null);
}

// ---------------------------------------------------------------------------
// The side table
// ---------------------------------------------------------------------------

test "a second completion for the same slot finds nothing to answer" {
    // Clearing on read is what makes a duplicate fire a no-op rather than a
    // second reply to a promise that has already settled — and, for a pending
    // create, rather than a double free of its strings.
    resetPendingForTesting();
    defer resetPendingForTesting();

    const ticket = fakeTicket(3, 7);
    publishPendingCall(ticket, fakeSels(), null, .{ .fetch = .{} });

    const first = takePendingCall(3);
    try testing.expect(first != null);
    try testing.expectEqual(@as(u32, 7), first.?.ticket.generation);

    try testing.expect(takePendingCall(3) == null);
}

test "two calls in flight keep separate entries" {
    // The reason this is a per-slot table rather than contactpicker's single
    // `pending`: nothing here is modal, so two getCalendarEvents at once is an
    // ordinary page, and one slot would refuse the second for no reason.
    resetPendingForTesting();
    defer resetPendingForTesting();

    publishPendingCall(fakeTicket(0, 1), fakeSels(), null, .{ .fetch = .{ .start_ms = 1 } });
    publishPendingCall(fakeTicket(1, 1), fakeSels(), null, .{ .fetch = .{ .start_ms = 2 } });

    const second = takePendingCall(1) orelse return error.EntryMissing;
    try testing.expectEqual(@as(f64, 2), second.request.fetch.start_ms.?);

    // Taking one must not disturb the other.
    const first = takePendingCall(0) orelse return error.EntryMissing;
    try testing.expectEqual(@as(f64, 1), first.request.fetch.start_ms.?);
}

test "a pending create owns its strings and frees them all" {
    // The strings outlive the dispatch frame, so they are allocated from the
    // allocator the completion frees with. Running it under the testing
    // allocator is what proves the ownership is complete rather than asserted.
    const event = try parseNewEvent(
        testing.allocator,
        "{\"event\":{\"title\":\"Standup\",\"location\":\"Room 2\",\"notes\":\"bring laptop\"}}",
    );

    resetPendingForTesting();
    defer resetPendingForTesting();

    publishPendingCall(fakeTicket(2, 4), fakeSels(), null, .{ .create = event });

    const call = takePendingCall(2) orelse return error.EntryMissing;
    try testing.expectEqualStrings("Standup", call.request.create.title);
    call.request.deinit(testing.allocator);
}

// ---------------------------------------------------------------------------
// The gates, exercised for real
// ---------------------------------------------------------------------------

test "a process without the calendar usage description is refused before EventKit is touched" {
    // The test runner is exactly the process the gate exists for: no bundle
    // Info.plist, so no NSCalendarsUsageDescription. On a device that is an app
    // built with `enableCalendar: false`, and requesting access there would raise
    // NSInternalInconsistencyException — an uncatchable SIGABRT — which is why
    // this runs before the store is ever created.
    //
    // Off Darwin the same call is refused one step earlier, at the platform
    // guard. Either way the answer is a rejection and never silence, and neither
    // path reaches EventKit.
    var bridge = CalendarBridge.init(testing.allocator);
    defer bridge.deinit();

    const expected = if (is_darwin)
        bridge_error.BridgeError.PermissionDenied
    else
        error.UnsupportedPlatform;

    try testing.expectError(expected, bridge.handleMessage(A.get_calendar_events, "{}"));
    try testing.expectError(
        expected,
        bridge.handleMessage(A.create_calendar_event, "{\"event\":{\"title\":\"x\"}}"),
    );
    // Delete is gated too. It requests no access, so for that one action the key
    // is only evidence of `config.enableCalendar` — but the flag guards all three
    // Swift cases, so it guards all three here.
    try testing.expectError(
        expected,
        bridge.handleMessage(A.delete_calendar_event, "{\"eventId\":\"E1\"}"),
    );
}

test "a malformed payload is refused before any platform or permission gate" {
    // Parsing first is what makes a bad body report the same cause on every
    // platform, and report it before a framework is consulted. These three
    // assertions hold identically on a host with no EventKit and on a device.
    var bridge = CalendarBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.get_calendar_events, "not json"),
    );
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.create_calendar_event, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.delete_calendar_event, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.get_calendar_events, "{\"startDate\":\"2024-01-01\"}"),
    );
}
