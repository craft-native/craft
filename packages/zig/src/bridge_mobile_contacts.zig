//! `getContacts` and `addContact` — the address book itself, read and written
//! through `CNContactStore`.
//!
//! The Swift original is `CraftApp.swift:705-713` (dispatch), `3224-3258`
//! (`getContacts`), `3260-3287` (`addContact`), `1763-1780` (the injected JS
//! that decides the wire payload) and `402-403`/`449-451` (the one store
//! instance). Every claim below is measured against those lines.
//!
//! This is a sibling of `bridge_mobile_contactpicker.zig` and not a variation
//! on it: the picker runs out of process, needs no authorization and answers a
//! *selection*; these two ask TCC for access to the whole book and then read or
//! write it. The reply shapes differ too — see "Two writers" below.
//!
//! ## The payloads
//!
//! **`getContacts` sends nothing.** `craft.contacts.getAll()` posts
//! `{action:'getContacts', callbackId: id}` and Swift's case reads nothing off
//! `body`, so `d` arrives as `{}`. There is no limit, no offset and no paging
//! anywhere in the spec. The handler therefore takes no `data` parameter at
//! all — a test pins that signature — because a body this action never reads
//! must not be able to fail the call: rejecting a malformed `d` here would fail
//! a call the shim answers.
//!
//! **`addContact` sends one field, `contact`, and it is a nested object.**
//! `craft.contacts.add(contact)` posts `{action:'addContact', contact: contact,
//! callbackId: id}`, so the stringified `d` has a root key `contact` whose
//! value is an object. Swift reads exactly four keys out of it, each with
//! `as? String`:
//!
//!   `givenName`, `familyName` -> set directly on a `CNMutableContact`;
//!   `phone` -> one `CNLabeledValue(label: CNLabelPhoneNumberMain,
//!               value: CNPhoneNumber(stringValue:))`;
//!   `email` -> one `CNLabeledValue(label: CNLabelHome, value: email as NSString)`.
//!
//! `as? String` is ported exactly, and it is not a coercion: a non-string value
//! (`{"phone": 5551234}`, a bool, a null, an object) makes the `if let` fail and
//! leaves the property *unset*. It is not an error, and it is emphatically not
//! "stringify it anyway". `contactFieldFrom` below is that rule, and the tests
//! pin it.
//!
//! **`displayName` on the way in is dropped, deliberately.**
//! `craft.d.ts:1166-1172` declares `NewContact.displayName?` and
//! `test-bridges.html:816` sends it, but `CraftApp.swift:3267-3275` never reads
//! it and `CNMutableContact` has no settable `displayName` — it is derived from
//! the name components. Dropping it is spec parity, not a Zig regression, and
//! saying so here is the point: silently omitting it would read as an oversight
//! the next time somebody diffs the two.
//!
//! ## The replies, which are two different shapes
//!
//! `resolveCallback` serialises with `.fragmentsAllowed`, so bare fragments are
//! real answers rather than a mistake.
//!
//!   - **`getContacts` resolves a JSON array** of six-key objects:
//!     `{"id","givenName","familyName","displayName","phoneNumbers",
//!     "emailAddresses"}`, where `phoneNumbers` and `emailAddresses` are **flat
//!     arrays of strings** (`phone.value.stringValue`, `email.value as String`).
//!     An empty address book is `[]`, and `[]` **resolves** — a fresh Simulator
//!     answers exactly that, `test-bridges.html:804` prints `Found 0 contacts`,
//!     and reporting it as a failure would be a lie about a call that worked.
//!   - **`addContact` resolves a bare JSON string**: Swift passes
//!     `contact.identifier`, a `String`, through `.fragmentsAllowed`, which
//!     serialises to `"ABCD-1234-..."` *including the quotes*. The page does
//!     `'Contact created with ID: ' + id`. So the reply bytes are a quoted,
//!     escaped string literal — the same shape `ios_async` already sends for
//!     `"granted"`.
//!
//! Swift builds `[String: Any]`, whose key order is a `Dictionary`'s and
//! therefore arbitrary; one order is fixed here so the bytes are testable, the
//! same call `bridge_mobile_contactpicker.appendContact` makes.
//!
//! **Neither action emits anything.** There is no `sendToWeb` on any contacts
//! path in `CraftApp.swift` and no contacts listener in `test-bridges.html`.
//! `ios_events.Event` has no contacts member and must not grow one for this:
//! an event here would be a message the shim never sends.
//!
//! ## Two writers, on purpose
//!
//! `bridge_mobile_contactpicker.zig` also serialises `CNContact`s, and its
//! `formatContact` port emits `phoneNumbers: [{label, number}]` /
//! `emailAddresses: [{label, address}]`. This file emits flat `string[]`. Both
//! are correct: they are two Swift functions with two shapes
//! (`CraftApp.swift:3244-3251` here, `5106-5136` there), and
//! `craft.d.ts:1157-1164` — which declares `string[]` — agrees with *this* one
//! and is wrong for the picker. Unifying them would break one of the two pages
//! that consume them, so the two writers stay, and each names its Swift source.
//!
//! The reading layer is a different story and worth stating plainly: `Sels`,
//! `readString`, `infoPlistValue` and `requireContactsConfigured` here overlap
//! the picker's file-private versions. Sharing them is a one-line-per-decl
//! `pub` change in that file plus an import, and it was left undone only
//! because this round was scoped to one new file. Two things would still not
//! have been shared: the picker's `readLabeledValues` computes a localized
//! label via `+[CNLabeledValue localizedStringForLabel:]` that `getContacts`
//! throws away — once per value across an entire address book — and the
//! picker's `Sels.resolve` hard-fails when `CNContactFormatter` is absent, a
//! class neither of these actions uses. So the honest note is "duplicated, ~70
//! lines, remedy known", not "could not be shared".
//!
//! ## The Info.plist gate is a real precondition here
//!
//! `packages/ios/src/index.ts:189` writes `NSContactsUsageDescription` if and
//! only if `config.enableContacts`, which is what makes the key readable as
//! evidence of the flag Swift guards both cases with. But unlike the picker —
//! which qualifies its own gate as *only* evidence — this is also the
//! framework's own precondition: `requestAccessForEntityType:` in a process
//! without that key does not return an error, TCC **kills the process**. From
//! Zig that is an uncatchable SIGABRT, so the key is checked first on both
//! actions, before `CNContactStore` is touched.
//!
//! `CNContactStore` itself is guarded separately and named in the log, because
//! `packages/ios/fixtures/zig-slice` links neither Contacts nor ContactsUI and
//! the fix for that is a link line rather than anything in this file.
//!
//! ## What diverges from the shim, stated rather than smoothed over
//!
//! **A denial's code and message change.** Swift rejects with
//! `code: "CRAFT_ERROR"` and `error?.localizedDescription ?? "Permission
//! denied"` (3226) / `"Permission denied"` (3263). Here a denial is
//! `ios_async.deliverErrorCode(ticket, PermissionDenied)`, which the page sees
//! as `code:"PERMISSION_DENIED"`, `message:"Permission denied"`. The code is
//! *more* accurate — a user declining a prompt is not a native call failing —
//! and a page branching on `err.code` still sees a change.
//! `test-bridges.html:806/822` prints `e.message`.
//!
//! **`localizedDescription` cannot be carried.** `ios_async` transports a
//! `BridgeError` enum and nothing else, so an `NSError`'s domain, code and
//! description are logged where they happen and never reach the page. Inventing
//! a second reply channel to carry them would reach around the generation guard
//! that stops a stale completion answering somebody else's call.
//!
//! **A missing or non-object `contact` rejects where Swift hangs.**
//! `case "addContact"` has no `else` (709-713), and the promise it leaves
//! unanswered is hand-built (1772-1779) rather than made by `_createCallback`,
//! so it carries none of the 30-second timeout at 1196-1209: the page waits
//! forever. Here it is `MISSING_DATA` (absent) or `INVALID_PARAMETER` (present
//! but not an object). Everybody settles, which is strictly better, and it is a
//! difference a page can observe. The same is true of `enableContacts: false`,
//! which Swift answers with silence on both actions and this file answers with
//! `PERMISSION_DENIED`.
//!
//! **An embedded NUL is refused rather than truncated.** On the way *in*,
//! `objc.createNSString` goes through `stringWithUTF8String:`, which stops at
//! the first NUL — so a `givenName` containing U+0000 would be silently stored
//! as its prefix. That is a wrong value written to the user's address book, so
//! it is rejected as `INVALID_PARAMETER` instead; Swift would have stored the
//! whole string. On the way *out*, `readString`'s length check fails the whole
//! `getContacts` for one such contact, which is the picker's pre-existing
//! divergence inherited unchanged rather than a new one.
//!
//! **An unfetched key still crashes.** Touching a property outside
//! `keysToFetch` raises `CNContactPropertyNotFetchedException`, an uncatchable
//! SIGABRT from Zig. Swift cannot catch `NSException` either, so this is parity
//! — and there is deliberately no comment below claiming a guard, because there
//! is none. The five keys are fetched precisely because of it.
//!
//! **iOS 18 limited access is reported as what it returned.**
//! `requestAccessForEntityType:` can answer `granted = YES` with only a
//! user-chosen subset visible; enumeration then walks that subset. The array is
//! what was actually returned, and nothing here annotates it with a
//! completeness claim the framework did not make.
//!
//! ## Concurrency
//!
//! Unlike the picker, which owns one on-screen resource and refuses a second
//! call, nothing here is exclusive: two `getContacts` in flight are two reads.
//! So the pending state is one entry per `ios_async` slot — the
//! `bridge_mobile_notifications.zig` pattern — and each slot is leased
//! exclusively by its ticket, which is what makes a plain write to
//! `pending_calls[ticket.index]` safe. The mutex is still held on every access,
//! because "the completion should be on the main thread" is not a guard and
//! `requestAccessForEntityType:` promises no queue at all.
//!
//! `enumerateContactsWithFetchRequest:error:usingBlock:` is *synchronous* — its
//! block runs on the calling thread and the call returns when the walk ends —
//! so the enumeration state is a pointer to a stack frame that provably
//! outlives every fire, published under its own mutex for the duration of the
//! call and cleared immediately after.
//!
//! No reply is ever sent from a completion directly. `ios_async` is the only
//! channel, and its main-queue hop is not merely thread safety: it restores the
//! `request_context` captured at dispatch, so the reply names the call that is
//! waiting instead of falling back to action-name matching.
//!
//! ## A loose end that belongs to the page, not to this file
//!
//! `test-bridges.html:803/813` calls `window.craft.getContacts()` and
//! `window.craft.addContact({...})`, but the injected JS defines only
//! `window.craft.contacts.getAll()` and `.add(contact)`. As written the test
//! page throws `TypeError` into its own `catch` and never reaches the bridge,
//! so a green run of it proves nothing about either action. The wire contract
//! above comes from the injected JS (the only authority for what is posted) and
//! from Swift's resolve calls; `craft.d.ts:258/265`, `packages/ios/README.md`
//! and `examples/basic-app.ts` agree on the *shapes* even where they use the
//! flat names.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// The same type as `objc.id` — `?*anyopaque` — spelled locally, per the
/// picker/location/notifications precedent: `objc_runtime.objc` is an empty
/// struct off Darwin and a `callconv(.c)` function *signature* is analysed even
/// where a comptime platform guard prunes the body. A single optional pointer,
/// never `?objc.id`, which would be a double optional and illegal in
/// `callconv(.c)`.
const Id = ?*anyopaque;

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches this block against those labels in
/// both directions and fails the build if two modules declare one name.
pub const A = struct {
    pub const get_contacts = "getContacts";
    pub const add_contact = "addContact";
};

/// `.result` for both: every Swift path out of either action terminates in
/// exactly one `resolveCallback` or one `rejectCallback`. `.none` would claim
/// nothing answers, and on these hand-built promises — no `_createCallback`, no
/// `setTimeout` — that is a page parked for its lifetime rather than 30
/// seconds.
///
/// `.live`, not `.unavailable`: in an app built with `enableContacts` both work
/// end to end, on the Simulator included. Every refusal below is a specific
/// condition (not configured, Contacts unlinked, access declined, the async
/// pool full), never the normal answer.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.get_contacts, .reply = .result },
    .{ .name = A.add_contact, .reply = .result },
};

/// Which handler an action selects, split out from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host without touching
/// Contacts.framework.
const Route = enum { get_contacts, add_contact };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.get_contacts)) return .get_contacts;
    if (std.mem.eql(u8, action, A.add_contact)) return .add_contact;
    return null;
}

pub const ContactsBridge = struct {
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
            .get_contacts => self.getContacts(),
            .add_contact => self.addContact(data),
        };
    }

    /// Ask for access, then enumerate the whole book.
    ///
    /// No `data` parameter, and that is the contract rather than an omission:
    /// Swift reads nothing off the body, so there is no field to drop and no
    /// malformed payload that may fail this call.
    ///
    /// Ordering is load-bearing. Every fallible step — the Info.plist gate, the
    /// store, every selector the completion and the enumeration will need, the
    /// five key constants, the fetch request — runs *before*
    /// `ios_async.acquire`, because after the lease a failure can only be
    /// logged. No path leaves after the lease without reaching the framework
    /// call — `publishPendingCall` and the `msgSend` are both infallible — and
    /// a future edit that adds one must `ios_async.abandon` on its way out or
    /// the slot narrows the pool for the life of the process.
    fn getContacts(_: *Self) !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        try requireContactsConfigured(A.get_contacts);

        const store = try contactStore();
        const sels = try ReadSels.resolve();
        // +1. Released by the completion, on every path including denial.
        const request = try fetchRequest();
        errdefer objc.release(request);

        const ticket = ios_async.acquire(A.get_contacts) orelse return poolFull(A.get_contacts);

        // Published *before* the framework call, never after: a completion that
        // fired first would otherwise find no ticket to answer with.
        publishPendingCall(.{
            .ticket = ticket,
            .store = store.object,
            .work = .{ .get_contacts = .{ .request = request, .sels = sels } },
        });

        requestAccess(store, ticket);
    }

    /// Build the contact synchronously, then ask for access and save it.
    ///
    /// The `CNMutableContact` and its `CNSaveRequest` are assembled here rather
    /// than in the completion for the reason above: building them needs no
    /// authorization, and doing it at dispatch keeps every fallible
    /// Objective-C step ahead of the lease — while also avoiding a copy of four
    /// payload strings into slot storage that outlives this frame. Both objects
    /// are +1 and both are released by the completion, denial included.
    fn addContact(self: *Self, data: []const u8) !void {
        var fields = try parseNewContact(self.allocator, data);
        defer fields.deinit(self.allocator);

        if (!is_darwin) return error.UnsupportedPlatform;

        try requireContactsConfigured(A.add_contact);

        const store = try contactStore();
        const sels = try SaveSels.resolve();
        const build = try BuildSels.resolve();

        const contact = try buildContact(self.allocator, fields, build);
        errdefer objc.release(contact);

        const save = try buildSaveRequest(contact, build);
        errdefer objc.release(save);

        const ticket = ios_async.acquire(A.add_contact) orelse return poolFull(A.add_contact);

        publishPendingCall(.{
            .ticket = ticket,
            .store = store.object,
            .work = .{ .add_contact = .{ .contact = contact, .save = save, .sels = sels } },
        });

        requestAccess(store, ticket);
    }
};

/// The answer for a full block pool, copied from `bridge_mobile_location` and
/// the picker: `BridgeError` has no "Busy", `INVALID_PARAMETER` is the
/// migration notes' designated stand-in, and the point is that the caller gets
/// an explicit rejection instead of a promise that never settles.
fn poolFull(action: []const u8) bridge_error.BridgeError {
    std.log.warn(
        "{s} refused: all {d} async slots are in flight",
        .{ action, ios_async.max_in_flight },
    );
    return bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// Payload parsing. Pure — no Objective-C — so the exact `as? String` rule Swift
// applies is pinned by host tests on every platform.
// =============================================================================

/// The four fields Swift reads out of `contact`, each present only if it
/// arrived as a JSON string. `null` means "Swift's `if let` would not have
/// fired", which leaves the property unset — not empty, unset.
const NewContact = struct {
    given_name: ?[]const u8 = null,
    family_name: ?[]const u8 = null,
    phone: ?[]const u8 = null,
    email: ?[]const u8 = null,

    /// The strings are copies: the parsed JSON tree is freed before the
    /// `NSString`s are built from them.
    fn deinit(self: *NewContact, allocator: std.mem.Allocator) void {
        if (self.given_name) |s| allocator.free(s);
        if (self.family_name) |s| allocator.free(s);
        if (self.phone) |s| allocator.free(s);
        if (self.email) |s| allocator.free(s);
        self.* = .{};
    }
};

/// `body["contact"] as? [String: Any]`, plus the rejection Swift does not have.
///
/// A malformed `d`, a non-object `d`, an absent `contact` and a non-object
/// `contact` are four different facts and are reported as three different
/// errors. Swift collapses all of them into "answer nothing", on a promise with
/// no timeout — see the module comment.
fn parseNewContact(allocator: std.mem.Allocator, data: []const u8) !NewContact {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return bridge_error.BridgeError.InvalidJSON;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    const contact_value = root.get("contact") orelse {
        std.log.warn(
            "addContact refused: the message carries no `contact` object " ++
                "(Swift answers such a call with nothing at all)",
            .{},
        );
        return bridge_error.BridgeError.MissingData;
    };

    const contact = switch (contact_value) {
        .object => |obj| obj,
        else => {
            std.log.warn(
                "addContact refused: `contact` is not an object, so there is nothing to save",
                .{},
            );
            return bridge_error.BridgeError.InvalidParameter;
        },
    };

    var out = NewContact{};
    errdefer out.deinit(allocator);

    out.given_name = try contactFieldFrom(allocator, contact, "givenName");
    out.family_name = try contactFieldFrom(allocator, contact, "familyName");
    out.phone = try contactFieldFrom(allocator, contact, "phone");
    out.email = try contactFieldFrom(allocator, contact, "email");

    return out;
}

/// One `data["key"] as? String`, as a total function.
///
/// Absent is null. Present-but-not-a-string is *also* null, because that is
/// what `as? String` yields and what Swift's `if let` then skips: erroring on
/// `{"phone": 5551234}` would refuse a call the shim accepts, and stringifying
/// it would write a value the page never sent.
///
/// The one refusal is an embedded NUL, which `stringWithUTF8String:` would
/// truncate silently — a wrong value in the user's address book. See the module
/// comment.
fn contactFieldFrom(
    allocator: std.mem.Allocator,
    contact: std.json.ObjectMap,
    comptime key: []const u8,
) !?[]const u8 {
    const value = contact.get(key) orelse return null;

    const text = switch (value) {
        .string => |s| s,
        // A number (including `number_string`, which is still a number), a
        // bool, a null, an array, an object. `as? String` is nil for every one.
        else => {
            std.log.info(
                "addContact: `" ++ key ++ "` is not a string, so it is left unset — " ++
                    "the same thing Swift's `as? String` does with it",
                .{},
            );
            return null;
        },
    };

    if (std.mem.indexOfScalar(u8, text, 0) != null) {
        std.log.warn(
            "addContact refused: `" ++ key ++ "` contains an embedded NUL, which " ++
                "stringWithUTF8String: would silently truncate",
            .{},
        );
        return bridge_error.BridgeError.InvalidParameter;
    }

    return try allocator.dupe(u8, text);
}

// =============================================================================
// Reply shaping. Pure — no Objective-C — so the exact bytes the page receives
// are pinned by host tests.
// =============================================================================

/// One contact as `CraftApp.swift:3244-3251` assembles it.
///
/// `phones` and `emails` are flat strings, not `{label, ...}` pairs: this is
/// the `getContacts` shape, and the picker's is the other one. See "Two
/// writers" in the module comment before making these agree.
///
/// The strings borrow whatever buffer they were read from — on the native path
/// an `NSString`'s internal UTF-8 buffer, valid for the enclosing autorelease
/// pool — and every one of them is copied into the JSON before that pool ends.
const ContactRow = struct {
    id: []const u8,
    given_name: []const u8,
    family_name: []const u8,
    display_name: []const u8,
    phones: []const []const u8,
    emails: []const []const u8,
};

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    try out.append(allocator, '"');
    // Names, numbers and addresses are user data and will contain `"` and `\`
    // in the wild. The reply is replayed into the source `evaluateJavaScript:`
    // parses, so an unescaped quote is a syntax error in the page rather than a
    // wrong field.
    try bridge_error.appendJsonEscaped(allocator, out, s);
    try out.append(allocator, '"');
}

fn appendStringArray(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    items: []const []const u8,
) !void {
    try out.append(allocator, '[');
    for (items, 0..) |item, i| {
        if (i != 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, item);
    }
    try out.append(allocator, ']');
}

/// One contact as a JSON object, in a fixed key order.
///
/// Swift's `[String: Any]` has no order at all; fixing one here is what makes
/// the bytes testable. Both array keys are always written, so a page reading
/// `contact.phoneNumbers.length` never meets `undefined`.
fn appendContactRow(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    row: ContactRow,
) !void {
    try out.appendSlice(allocator, "{\"id\":");
    try appendJsonString(allocator, out, row.id);
    try out.appendSlice(allocator, ",\"givenName\":");
    try appendJsonString(allocator, out, row.given_name);
    try out.appendSlice(allocator, ",\"familyName\":");
    try appendJsonString(allocator, out, row.family_name);
    try out.appendSlice(allocator, ",\"displayName\":");
    try appendJsonString(allocator, out, row.display_name);
    try out.appendSlice(allocator, ",\"phoneNumbers\":");
    try appendStringArray(allocator, out, row.phones);
    try out.appendSlice(allocator, ",\"emailAddresses\":");
    try appendStringArray(allocator, out, row.emails);
    try out.append(allocator, '}');
}

/// The `getContacts` reply, built one contact at a time.
///
/// Incremental because the source is an enumeration callback rather than a
/// list: `enumerateContactsWithFetchRequest:` hands over one `CNContact` at a
/// time and there is no count to size anything from. The alternative — collect
/// every contact into a slice of borrowed slices first — would keep an entire
/// address book's worth of `NSString` buffers alive on the promise that the
/// autorelease pool outlives the walk, which is exactly the kind of claim this
/// file should not be making.
///
/// The bracket and comma bookkeeping lives here rather than at the call site so
/// the native path and the tests build the array through the same code.
const RowWriter = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    rows: usize = 0,

    fn begin(self: *RowWriter, allocator: std.mem.Allocator) !void {
        try self.out.append(allocator, '[');
    }

    fn append(self: *RowWriter, allocator: std.mem.Allocator, row: ContactRow) !void {
        if (self.rows != 0) try self.out.append(allocator, ',');
        try appendContactRow(allocator, &self.out, row);
        self.rows += 1;
    }

    /// `[]` for an empty address book, which **resolves**. See the module
    /// comment: a fresh Simulator answers exactly that and it is a correct
    /// answer, not a failure.
    fn finish(self: *RowWriter, allocator: std.mem.Allocator) ![]u8 {
        try self.out.append(allocator, ']');
        return self.out.toOwnedSlice(allocator);
    }

    fn deinit(self: *RowWriter, allocator: std.mem.Allocator) void {
        self.out.deinit(allocator);
    }
};

/// The `addContact` reply: a bare, quoted, escaped JSON string.
///
/// Not an object, and not the identifier raw. Swift resolves the `String`
/// itself under `.fragmentsAllowed`, so `{"id": ...}` here would make the
/// page's `'ID: ' + id` print `[object Object]`.
fn shapeIdentifier(allocator: std.mem.Allocator, identifier: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendJsonString(allocator, &out, identifier);
    return out.toOwnedSlice(allocator);
}

/// `"\(givenName) \(familyName)"` — always exactly one space, before trimming.
///
/// The trim itself is deliberately *not* done here. Swift's
/// `trimmingCharacters(in: .whitespaces)` is Unicode general category Zs plus
/// U+0009, both ends only, interior runs preserved, and a byte-wise `" \t"`
/// trim would be an approximation that diverges on a name padded with U+00A0.
/// `readDisplayName` hands this string to
/// `-[NSString stringByTrimmingCharactersInSet:]` with
/// `+[NSCharacterSet whitespaceCharacterSet]` — the same object
/// `CharacterSet.whitespaces` bridges to — so the result is Swift's, not an
/// imitation of it.
fn joinName(allocator: std.mem.Allocator, given: []const u8, family: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ given, family });
}

// =============================================================================
// Objective-C. Everything resolved at dispatch, where a failure can still be an
// ordinary rejection; nothing is looked up inside a completion.
//
// Every function below opens with the Darwin guard. That is not decoration: off
// Darwin `objc_runtime.objc` is an empty struct, and a comptime-false `if` that
// returns is what stops the rest of the body being analysed at all.
// =============================================================================

/// The Info.plist key `packages/ios/src/index.ts:189` writes if and only if
/// `config.enableContacts` — and the key `requestAccessForEntityType:` requires
/// on pain of process death. See the module comment.
const key_contacts_usage = "NSContactsUsageDescription";

/// `NSUTF8StringEncoding`. Used only to ask a string how long it really is, so
/// a NUL-truncated read can be told from a short string.
const ns_utf8_string_encoding: c_ulong = 4;

/// `CNEntityType.contacts` = 0. `CNEntityType` is `NSInteger`, hence `c_long`;
/// `bridge_mobile_permissions.zig:505` spells the same constant the same way.
const cn_entity_type_contacts: c_long = 0;

/// The five keys `CraftApp.swift:3230` fetches, in its order.
///
/// Resolved by `dlsym` rather than hardcoded. Their documented *values* are the
/// KVC names (`"givenName"`, `"identifier"`, ...), so a fallback would be
/// defensible — but a wrong or missing fetch key does not fail loudly: it
/// produces a contact whose property access raises
/// `CNContactPropertyNotFetchedException`, an uncatchable SIGABRT. Refusing
/// when `dlsym` misses trades a crash for a rejection, and if `CNContactStore`
/// resolved then Contacts.framework is loaded and these symbols are present.
const contact_key_symbols = [_][:0]const u8{
    "CNContactGivenNameKey",
    "CNContactFamilyNameKey",
    "CNContactPhoneNumbersKey",
    "CNContactEmailAddressesKey",
    "CNContactIdentifierKey",
};

/// The two labels `addContact` writes. Same `dlsym`-or-refuse policy, and here
/// the argument is stronger: a wrong label does not fail at all, it saves a
/// contact whose number is filed under the wrong heading in the user's address
/// book. Documented values are `"_$!<Main>!$_"` and `"_$!<Home>!$_"`, and
/// guessing them is exactly what this avoids.
const label_phone_main = "CNLabelPhoneNumberMain";
const label_email_home = "CNLabelHome";

fn selector(name: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.sel_registerName(name) orelse error.SelectorNotFound;
}

fn class(name: [*:0]const u8, action: []const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.objc_getClass(name) orelse {
        std.log.err(
            "{s} refused: this process has no {s}; Contacts.framework is not linked",
            .{ action, name },
        );
        return bridge_error.BridgeError.PlatformNotSupported;
    };
}

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// dyld's "search every image" pseudo-handle, `(void *)-2` on Darwin.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// One `NSString * const` out of Contacts.framework.
///
/// The symbol is the *variable*, so one dereference yields the object; a
/// resolved symbol holding nil is guarded, because nil in one of these
/// arguments is a fetch that silently omits a key or a labeled value with no
/// label.
fn contactsConstant(symbol: [:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const sym = dlsym(RTLD_DEFAULT, symbol) orelse {
        std.log.err(
            "contacts refused: {s} is not in this process; Contacts.framework is not linked",
            .{symbol},
        );
        return bridge_error.BridgeError.PlatformNotSupported;
    };
    const slot: *Id = @ptrCast(@alignCast(sym));
    return slot.* orelse {
        std.log.err("contacts refused: {s} resolved to nil", .{symbol});
        return bridge_error.BridgeError.PlatformNotSupported;
    };
}

/// The main bundle's Info.plist value for `key`, or null when it has none.
///
/// Errors rather than answering null when the runtime will not cooperate:
/// "there is no NSBundle" and "this app was not built with contacts enabled"
/// are different facts, and collapsing them would blame the app's
/// configuration for a broken process. Same shape as the picker's own gate,
/// which is private to that file.
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

/// Refuse before `requestAccessForEntityType:` can take the process down.
///
/// Checked first on both actions, matching Swift's `if config.enableContacts`
/// guarding both cases — and here it is genuinely the framework's precondition
/// rather than only evidence of the flag. Swift answers such a call with
/// silence; this answers `PERMISSION_DENIED`.
fn requireContactsConfigured(action: []const u8) !void {
    if (!is_darwin) return error.UnsupportedPlatform;

    if ((try infoPlistValue(key_contacts_usage)) == null) {
        std.log.warn(
            "{s} refused: Info.plist has no {s}, so this app was not built with contacts " ++
                "enabled — and requesting access without that key is a TCC process kill",
            .{ action, key_contacts_usage },
        );
        return bridge_error.BridgeError.PermissionDenied;
    }
}

/// The one `CNContactStore`, and the selector both actions send it first.
const Store = struct {
    object: Id,
    request_access: Id,
};

/// Created once for the process, mirroring the single store at
/// `CraftApp.swift:450`. Never released: it is the process's store, and a
/// per-call store would re-do Contacts' own setup on every read.
var store_object: Id = null;
var store_mutex: compat_mutex.Mutex = .{};

fn contactStore() !Store {
    if (!is_darwin) return error.UnsupportedPlatform;

    const sel_request = try selector("requestAccessForEntityType:completionHandler:");

    store_mutex.lock();
    defer store_mutex.unlock();

    if (store_object) |existing| return .{ .object = existing, .request_access = sel_request };

    const StoreClass = try class("CNContactStore", "contacts");
    const created = (try objc.allocInit(StoreClass)) orelse return error.NativeCallFailed;
    store_object = created;
    return .{ .object = created, .request_access = sel_request };
}

/// `-[CNContactStore requestAccessForEntityType:completionHandler:]` with this
/// slot's global block. Infallible by the time it is called: the store, the
/// selector and the ticket are all in hand.
fn requestAccess(store: Store, ticket: ios_async.Ticket) void {
    if (!is_darwin) return;

    const Fn = *const fn (Id, Id, c_long, *anyopaque) callconv(.c) void;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    func(store.object, store.request_access, cn_entity_type_contacts, accessBlock(ticket));
}

/// `UTF8String` and `lengthOfBytesUsingEncoding:`, the pair `readString` needs.
const TextSels = struct {
    utf8: Id,
    length_of_bytes: Id,

    fn resolve() !TextSels {
        if (!is_darwin) return error.UnsupportedPlatform;
        return .{
            .utf8 = try selector("UTF8String"),
            .length_of_bytes = try selector("lengthOfBytesUsingEncoding:"),
        };
    }
};

/// One `NSString` as bytes, or a refusal.
///
/// The truncation check is why this is not one line. `UTF8String` hands back a
/// NUL-terminated buffer, so a value containing U+0000 — which
/// `JSONSerialization` would have preserved on the Swift side — reads back as
/// its prefix, and reporting a prefix as a whole name is the one thing worse
/// than failing. Inherited unchanged from the picker, divergence included.
///
/// The returned slice borrows the string's internal buffer, valid for the
/// current autorelease pool; every caller copies it into the reply before
/// returning.
fn readString(ns: Id, text: TextSels) ![]const u8 {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (ns == null) return error.NilNativeString;

    const Utf8Fn = *const fn (Id, Id) callconv(.c) ?[*:0]const u8;
    const utf8: Utf8Fn = @ptrCast(&objc.objc_msgSend);
    const cstr = utf8(ns, text.utf8) orelse return error.NativeCallFailed;
    const bytes = std.mem.span(cstr);

    const LenFn = *const fn (Id, Id, c_ulong) callconv(.c) c_ulong;
    const len_of: LenFn = @ptrCast(&objc.objc_msgSend);
    if (len_of(ns, text.length_of_bytes, ns_utf8_string_encoding) != bytes.len) {
        return error.EmbeddedNulInNativeString;
    }

    return bytes;
}

fn nsString(s: []const u8, allocator: std.mem.Allocator) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return (try objc.createNSString(s, allocator)) orelse error.NSStringCreationFailed;
}

// -----------------------------------------------------------------------------
// getContacts: the fetch request, and everything the enumeration will need.
// -----------------------------------------------------------------------------

/// Every selector and class the `getContacts` completion touches, resolved
/// while a synchronous error can still reach the page.
///
/// Deliberately narrower than the picker's `Sels`: no `CNContactFormatter` and
/// no `+localizedStringForLabel:`, because this action's reply has no localized
/// labels in it and refusing over a class it never uses would be an over-broad
/// gate.
const ReadSels = struct {
    text: TextSels,

    /// `-[CNContactStore enumerateContactsWithFetchRequest:error:usingBlock:]`.
    /// Three parts, not two: a two-part spelling registers a selector nothing
    /// implements and the call goes to `doesNotRecognizeSelector:`.
    enumerate: Id,

    // NSArray
    count: Id,
    object_at: Id,

    // CNContact
    identifier: Id,
    given_name: Id,
    family_name: Id,
    phone_numbers: Id,
    email_addresses: Id,

    /// `-[CNLabeledValue value]`. One class for both arrays: the Swift generics
    /// `CNLabeledValue<CNPhoneNumber>` and `CNLabeledValue<NSString>` are the
    /// same Objective-C class.
    value: Id,

    /// `-[CNPhoneNumber stringValue]`, for phones only — see `LabeledKind`.
    string_value: Id,

    // The displayName trim.
    character_set_class: Id,
    whitespace_set: Id,
    trim: Id,

    fn resolve() !ReadSels {
        if (!is_darwin) return error.UnsupportedPlatform;

        const NSCharacterSet = objc.objc_getClass("NSCharacterSet") orelse return error.ClassNotFound;

        return .{
            .text = try TextSels.resolve(),
            .enumerate = try selector("enumerateContactsWithFetchRequest:error:usingBlock:"),

            .count = try selector("count"),
            .object_at = try selector("objectAtIndex:"),

            .identifier = try selector("identifier"),
            .given_name = try selector("givenName"),
            .family_name = try selector("familyName"),
            .phone_numbers = try selector("phoneNumbers"),
            .email_addresses = try selector("emailAddresses"),

            .value = try selector("value"),
            .string_value = try selector("stringValue"),

            .character_set_class = NSCharacterSet,
            .whitespace_set = try selector("whitespaceCharacterSet"),
            .trim = try selector("stringByTrimmingCharactersInSet:"),
        };
    }
};

/// `CNContactFetchRequest(keysToFetch:)` with Swift's five keys and nothing
/// else set — no predicate, no `unifyResults` change, no sort order, no limit,
/// because `CraftApp.swift:3231` sets none of them.
///
/// Returns +1; the completion releases it.
fn fetchRequest() !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSMutableArray = objc.objc_getClass("NSMutableArray") orelse return error.ClassNotFound;
    const sel_array = try selector("array");
    const sel_add = try selector("addObject:");
    const RequestClass = try class("CNContactFetchRequest", A.get_contacts);
    const sel_init = try selector("initWithKeysToFetch:");

    const keys = objc.msgSendId(NSMutableArray, sel_array) orelse return error.NativeCallFailed;
    for (contact_key_symbols) |symbol| {
        objc.msgSendVoid1(keys, sel_add, try contactsConstant(symbol));
    }

    // `alloc` then the designated initialiser, never `allocInit` first: `init`
    // on a `CNContactFetchRequest` is not the initialiser this class takes.
    // The keys array is autoreleased and the request retains it, so it outlives
    // this frame's pool exactly as long as the request does.
    const raw = (try objc.alloc(RequestClass)) orelse return error.NativeCallFailed;
    return objc.msgSendId1(raw, sel_init, keys) orelse error.NativeCallFailed;
}

// -----------------------------------------------------------------------------
// addContact: building the contact, and saving it.
// -----------------------------------------------------------------------------

/// Everything the `addContact` *dispatch* needs to assemble a
/// `CNMutableContact` and its save request.
const BuildSels = struct {
    mutable_contact_class: Id,
    set_given_name: Id,
    set_family_name: Id,
    set_phone_numbers: Id,
    set_email_addresses: Id,

    phone_number_class: Id,
    phone_number_with: Id,

    labeled_value_class: Id,
    labeled_value_with: Id,

    array_class: Id,
    array_with_object: Id,

    save_class: Id,
    save_add: Id,

    fn resolve() !BuildSels {
        if (!is_darwin) return error.UnsupportedPlatform;

        const NSArray = objc.objc_getClass("NSArray") orelse return error.ClassNotFound;

        return .{
            .mutable_contact_class = try class("CNMutableContact", A.add_contact),
            .set_given_name = try selector("setGivenName:"),
            .set_family_name = try selector("setFamilyName:"),
            .set_phone_numbers = try selector("setPhoneNumbers:"),
            .set_email_addresses = try selector("setEmailAddresses:"),

            .phone_number_class = try class("CNPhoneNumber", A.add_contact),
            .phone_number_with = try selector("phoneNumberWithStringValue:"),

            .labeled_value_class = try class("CNLabeledValue", A.add_contact),
            .labeled_value_with = try selector("labeledValueWithLabel:value:"),

            .array_class = NSArray,
            .array_with_object = try selector("arrayWithObject:"),

            .save_class = try class("CNSaveRequest", A.add_contact),
            .save_add = try selector("addContact:toContainerWithIdentifier:"),
        };
    }
};

/// Everything the `addContact` *completion* needs.
const SaveSels = struct {
    text: TextSels,
    /// `-[CNContactStore executeSaveRequest:error:]`.
    execute: Id,
    /// `-[CNContact identifier]`, read after the save, in Swift's order.
    identifier: Id,

    fn resolve() !SaveSels {
        if (!is_darwin) return error.UnsupportedPlatform;
        return .{
            .text = try TextSels.resolve(),
            .execute = try selector("executeSaveRequest:error:"),
            .identifier = try selector("identifier"),
        };
    }
};

/// `CNMutableContact()` plus Swift's four conditional setters, in Swift's
/// order. Returns +1.
///
/// A field the payload did not carry as a string is not set at all — see
/// `contactFieldFrom`. `displayName` is not settable and is not attempted.
fn buildContact(allocator: std.mem.Allocator, fields: NewContact, b: BuildSels) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const contact = (try objc.allocInit(b.mutable_contact_class)) orelse return error.NativeCallFailed;
    errdefer objc.release(contact);

    if (fields.given_name) |s| {
        objc.msgSendVoid1(contact, b.set_given_name, try nsString(s, allocator));
    }
    if (fields.family_name) |s| {
        objc.msgSendVoid1(contact, b.set_family_name, try nsString(s, allocator));
    }

    if (fields.phone) |s| {
        const number = objc.msgSendId1(
            b.phone_number_class,
            b.phone_number_with,
            try nsString(s, allocator),
        ) orelse return error.NativeCallFailed;
        const labeled = try labeledValue(b, try contactsConstant(label_phone_main), number);
        // `phoneNumbers` is a `copy` property, so the autoreleased one-element
        // array is retained by the contact and outlives this frame's pool.
        const array = objc.msgSendId1(b.array_class, b.array_with_object, labeled) orelse
            return error.NativeCallFailed;
        objc.msgSendVoid1(contact, b.set_phone_numbers, array);
    }

    if (fields.email) |s| {
        // An email's value is the `NSString` itself — no `CNPhoneNumber`
        // wrapper, and no `stringValue` on the way back out either.
        const labeled = try labeledValue(
            b,
            try contactsConstant(label_email_home),
            try nsString(s, allocator),
        );
        const array = objc.msgSendId1(b.array_class, b.array_with_object, labeled) orelse
            return error.NativeCallFailed;
        objc.msgSendVoid1(contact, b.set_email_addresses, array);
    }

    return contact;
}

/// `+[CNLabeledValue labeledValueWithLabel:value:]` — two object arguments, so
/// the signature is spelled out rather than left to a one-argument helper.
fn labeledValue(b: BuildSels, label: Id, value: Id) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const Fn = *const fn (Id, Id, Id, Id) callconv(.c) Id;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(b.labeled_value_class, b.labeled_value_with, label, value) orelse
        error.NativeCallFailed;
}

/// `CNSaveRequest()` with the contact added to the default container. Returns
/// +1.
fn buildSaveRequest(contact: Id, b: BuildSels) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;

    const save = (try objc.allocInit(b.save_class)) orelse return error.NativeCallFailed;
    errdefer objc.release(save);

    // `toContainerWithIdentifier: nil` — Swift's default container. The
    // parameter type is declared, so the bare `null` has a type to take.
    const Fn = *const fn (Id, Id, Id, Id) callconv(.c) void;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    func(save, b.save_add, contact, null);

    return save;
}

// -----------------------------------------------------------------------------
// NSError, for the log only.
// -----------------------------------------------------------------------------

/// Log an `NSError`'s domain, code and description.
///
/// This is the only channel `localizedDescription` has: `ios_async` carries a
/// `BridgeError` enum, so the text Swift put in the page's error message is
/// written to the device log instead of being invented into a reply shape the
/// page does not expect. Each lookup is guarded and a miss degrades the line
/// rather than the call — nothing here is on the reply path.
fn describeNSError(action: []const u8, call: []const u8, ns_error: Id, text: TextSels) void {
    if (!is_darwin) return;

    std.log.warn("{s}: {s} reported domain={s} code={?d} description={s}", .{
        action,
        call,
        nsErrorString(ns_error, "domain", text) orelse "(none)",
        nsErrorCode(ns_error),
        nsErrorString(ns_error, "localizedDescription", text) orelse "(none)",
    });
}

fn nsErrorString(ns_error: Id, comptime name: [*:0]const u8, text: TextSels) ?[]const u8 {
    if (!is_darwin) return null;

    const sel = objc.sel_registerName(name) orelse return null;
    const value = objc.msgSendId(ns_error, sel) orelse return null;
    return readString(value, text) catch null;
}

fn nsErrorCode(ns_error: Id) ?c_long {
    if (!is_darwin) return null;

    const sel = objc.sel_registerName("code") orelse return null;
    const Fn = *const fn (Id, Id) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(ns_error, sel);
}

// =============================================================================
// The per-slot blocks.
//
// `ios_async.boolErrorBlock` is the right *shape* for
// `requestAccessForEntityType:completionHandler:` and the wrong tool: its
// invoke replies `"granted"`/`"denied"` immediately, and both of these actions
// have to do their real work after the grant and answer with an array or an
// id. So each slot gets its own block here — the `bridge_mobile_notifications`
// pattern, applied rather than extended.
//
// A global block captures nothing, which is what makes `Block_copy` on it the
// identity function and removes every lifetime question. The price is that a
// block knows only its own slot index, baked in at comptime; the ticket, the
// selectors and the +1 objects are looked up in the side table below.
// =============================================================================

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// One layout for both blocks: a global block's literal is the same five words
/// whatever its invoke signature is, and only the invoke differs.
const Block = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// 1 << 28. A global block is never copied: `Block_copy` returns the same
/// pointer. No heap block, no copy/dispose pair, no descriptor lifetime.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

const block_descriptor = BlockDescriptor{ .size = @sizeOf(Block) };

extern var _NSConcreteGlobalBlock: anyopaque;

/// `void (^)(BOOL granted, NSError * _Nullable error)`.
fn makeAccessInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const Block, granted: bool, err: Id) callconv(.c) void {
            accessCompletionFired(index, granted, err);
        }
    };
    return @ptrCast(&S.invoke);
}

/// `void (^)(CNContact * _Nonnull contact, BOOL * _Nonnull stop)`.
///
/// **Returns void.** A `bool`-returning invoke would register and run and read
/// its result out of a register nobody wrote — the same silent class of bug as
/// a wrong method type encoding, with no crash and no compile error to say so.
fn makeEnumerationInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const Block, contact: Id, stop: *bool) callconv(.c) void {
            enumerationFired(index, contact, stop);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeBlocks(comptime maker: fn (comptime u5) *const anyopaque) [ios_async.max_in_flight]Block {
    var out: [ios_async.max_in_flight]Block = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = maker(@intCast(i)),
            .descriptor = &block_descriptor,
        };
    }
    return out;
}

var access_blocks: [ios_async.max_in_flight]Block =
    if (is_darwin) makeBlocks(makeAccessInvoke) else undefined;
var enumeration_blocks: [ios_async.max_in_flight]Block =
    if (is_darwin) makeBlocks(makeEnumerationInvoke) else undefined;

fn accessBlock(ticket: ios_async.Ticket) *anyopaque {
    return @ptrCast(&access_blocks[ticket.index]);
}

fn enumerationBlock(index: u5) *anyopaque {
    return @ptrCast(&enumeration_blocks[index]);
}

// =============================================================================
// The side table: one entry per async slot.
//
// One entry per slot rather than the picker's single `pending`, because nothing
// here is exclusive — two reads of the address book are two reads, and refusing
// the second would refuse a call the shim serves. The slot is leased
// exclusively by its ticket, so a publish can never displace a live call.
// =============================================================================

/// What the completion has to finish and free, per action.
const GetWork = struct {
    /// +1 `CNContactFetchRequest`. Released by the completion on every path.
    request: Id,
    sels: ReadSels,
};

const AddWork = struct {
    /// +1 `CNMutableContact`, built at dispatch.
    contact: Id,
    /// +1 `CNSaveRequest`, holding the contact.
    save: Id,
    sels: SaveSels,
};

const Work = union(Route) {
    get_contacts: GetWork,
    add_contact: AddWork,
};

const PendingCall = struct {
    ticket: ios_async.Ticket,
    store: Id,
    work: Work,
};

var pending_calls: [ios_async.max_in_flight]?PendingCall = @splat(null);
var pending_mutex: compat_mutex.Mutex = .{};

fn publishPendingCall(call: PendingCall) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls[call.ticket.index] = call;
}

/// Read and clear. Clearing is what makes a second fire of one completion a
/// no-op rather than a second reply to a promise that has already settled —
/// and, for the +1 objects, what stops a double release.
fn takePendingCall(index: u5) ?PendingCall {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const call = pending_calls[index];
    pending_calls[index] = null;
    return call;
}

// =============================================================================
// The enumeration's state.
//
// `enumerateContactsWithFetchRequest:error:usingBlock:` is synchronous: the
// block runs on the calling thread and the call returns when the walk ends. So
// this is a pointer to `collectContacts`'s frame, which provably outlives every
// fire, published for the duration of that one call and cleared immediately
// after. The mutex is held anyway — the completion that owns the frame runs on
// whatever queue Contacts chose, and slots are independent.
// =============================================================================

const Collector = struct {
    allocator: std.mem.Allocator,
    sels: ReadSels,
    /// `+[NSCharacterSet whitespaceCharacterSet]`, read once per walk rather
    /// than once per contact.
    whitespace: Id,
    writer: *RowWriter,
    /// The first failure, kept so the walk can stop and the call can reject
    /// instead of resolving a partial address book as if it were complete.
    failure: ?anyerror = null,
};

var collectors: [ios_async.max_in_flight]?*Collector = @splat(null);
var collectors_mutex: compat_mutex.Mutex = .{};

fn publishCollector(index: u5, collector: *Collector) void {
    collectors_mutex.lock();
    defer collectors_mutex.unlock();
    collectors[index] = collector;
}

fn collectorFor(index: u5) ?*Collector {
    collectors_mutex.lock();
    defer collectors_mutex.unlock();
    return collectors[index];
}

fn clearCollector(index: u5) void {
    collectors_mutex.lock();
    defer collectors_mutex.unlock();
    collectors[index] = null;
}

// =============================================================================
// The completions. None replies directly: `evaluateJavaScript:` is
// main-thread-only *and* the `request_context` naming the waiting call is long
// gone, so every answer goes through `ios_async`, which hops to the main queue
// and replies under the id captured at dispatch.
//
// Plain `fn`, never `export`: `@ptrCast(&f)` works either way and an exported
// name could collide with a desktop module in the same host-test binary.
// =============================================================================

fn accessCompletionFired(index: u5, granted: bool, err: Id) void {
    if (!is_darwin) return;

    const call = takePendingCall(index) orelse {
        std.log.warn(
            "contacts: an access completion fired for slot {d} with no call recorded; " ++
                "ignored rather than answered to whoever holds the slot next",
            .{index},
        );
        return;
    };

    const allocator = std.heap.c_allocator;

    switch (call.work) {
        .get_contacts => |work| {
            defer objc.release(work.request);

            if (!granted) return denied(call.ticket, A.get_contacts, err, work.sels.text);

            const json = collectContacts(allocator, call.store, work, call.ticket.index) catch |e| {
                std.log.err(
                    "getContacts: the address book could not be read ({}); rejecting rather " ++
                        "than replying with a list that was not read",
                    .{e},
                );
                ios_async.deliverErrorCode(call.ticket, failureCode(e));
                return;
            };
            defer allocator.free(json);

            // `[]` for an empty book, and it resolves. See `RowWriter.finish`.
            ios_async.deliverJson(call.ticket, json);
        },
        .add_contact => |work| {
            // Release order mirrors construction: the save request holds the
            // contact, so it goes first.
            defer objc.release(work.contact);
            defer objc.release(work.save);

            if (!granted) return denied(call.ticket, A.add_contact, err, work.sels.text);

            const json = saveContact(allocator, call.store, work) catch |e| {
                std.log.err(
                    "addContact: the contact was not saved ({}); rejecting rather than " ++
                        "replying with an identifier for a contact that does not exist",
                    .{e},
                );
                ios_async.deliverErrorCode(call.ticket, failureCode(e));
                return;
            };
            defer allocator.free(json);

            ios_async.deliverJson(call.ticket, json);
        },
    }
}

/// The user declined the prompt — or TCC had already declined it for them.
///
/// `PermissionDenied`, never the generic failure: the call worked perfectly and
/// the answer is "no". Reporting `NATIVE_CALL_FAILED` would send whoever reads
/// the error hunting a bug that is not there. Swift's code and message differ;
/// the module comment says how.
fn denied(ticket: ios_async.Ticket, action: []const u8, err: Id, text: TextSels) void {
    if (!is_darwin) return;

    // A declined prompt carries no NSError at all, which is normal and not
    // worth a line; an error object means something else happened and is.
    if (err != null) describeNSError(action, "requestAccessForEntityType:", err, text);

    std.log.info(
        "{s}: contacts access was not granted; rejecting as PERMISSION_DENIED " ++
            "(Swift sends CRAFT_ERROR with the NSError's description)",
        .{action},
    );
    ios_async.deliverErrorCode(ticket, bridge_error.BridgeError.PermissionDenied);
}

/// Which `BridgeError` a completion-side failure reports.
///
/// Only three of these are honest distinctions, so only three are made: a
/// declined permission never reaches here, an allocation failure is one, and
/// everything else genuinely is a native call that did not produce an answer.
fn failureCode(err: anyerror) bridge_error.BridgeError {
    return switch (err) {
        error.OutOfMemory, error.AllocationFailed => bridge_error.BridgeError.AllocationFailed,
        error.PermissionDenied => bridge_error.BridgeError.PermissionDenied,
        else => bridge_error.BridgeError.NativeCallFailed,
    };
}

/// Walk the whole address book into the reply array.
///
/// No predicate, no sort, no limit — `CraftApp.swift:3235` passes none, and
/// adding one would answer a different question than the page asked.
fn collectContacts(
    allocator: std.mem.Allocator,
    store: Id,
    work: GetWork,
    index: u5,
) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const whitespace = objc.msgSendId(work.sels.character_set_class, work.sels.whitespace_set) orelse
        return error.NativeCallFailed;

    var writer = RowWriter{};
    errdefer writer.deinit(allocator);
    try writer.begin(allocator);

    var collector = Collector{
        .allocator = allocator,
        .sels = work.sels,
        .whitespace = whitespace,
        .writer = &writer,
    };

    publishCollector(index, &collector);
    defer clearCollector(index);

    var err_out: Id = null;
    const EnumFn = *const fn (Id, Id, Id, ?*Id, *anyopaque) callconv(.c) bool;
    const enumerate: EnumFn = @ptrCast(&objc.objc_msgSend);
    const ok = enumerate(store, work.sels.enumerate, work.request, &err_out, enumerationBlock(index));

    // The collector's failure is checked first and on purpose: a block that
    // stopped the walk early leaves `ok` true, and returning the partial array
    // would report a truncated address book as a complete one.
    if (collector.failure) |failure| return failure;

    if (!ok) {
        if (err_out != null) {
            describeNSError(
                A.get_contacts,
                "enumerateContactsWithFetchRequest:error:usingBlock:",
                err_out,
                work.sels.text,
            );
        } else {
            std.log.warn(
                "getContacts: enumerateContactsWithFetchRequest: returned NO with no NSError",
                .{},
            );
        }
        return error.NativeCallFailed;
    }

    return writer.finish(allocator);
}

/// One `CNContact`, straight into the reply.
///
/// Runs on the thread that called `enumerateContacts...`, inside
/// `collectContacts`'s frame, which is why the collector pointer is valid.
///
/// `stop` is what Swift discards (`{ contact, _ in }`) and this file uses: on a
/// failure the walk stops instead of reading the rest of an address book whose
/// answer has already been given up on. That is a deliberate improvement over
/// the shim, not parity — Swift's `contacts.append` would trap rather than
/// unwind — and the reply is a rejection either way.
fn enumerationFired(index: u5, contact: Id, stop: *bool) void {
    if (!is_darwin) return;

    const collector = collectorFor(index) orelse {
        // No live walk owns this slot's writer, so nothing is being truncated
        // by stopping — there is simply nowhere to put a contact.
        std.log.warn(
            "getContacts: enumeration fired for slot {d} with no collector; stopping the walk",
            .{index},
        );
        stop.* = true;
        return;
    };

    if (collector.failure != null) {
        stop.* = true;
        return;
    }

    appendContact(collector, contact) catch |err| {
        collector.failure = err;
        stop.* = true;
    };
}

fn appendContact(collector: *Collector, contact: Id) !void {
    if (!is_darwin) return error.UnsupportedPlatform;
    // The block parameter is declared `_Nonnull`; a nil here would mean the
    // framework broke its own contract, and "a contact with no fields" is a
    // claim there would be no basis for.
    if (contact == null) return error.NativeCallFailed;

    const sels = collector.sels;
    const allocator = collector.allocator;

    const given = try readString(objc.msgSendId(contact, sels.given_name), sels.text);
    const family = try readString(objc.msgSendId(contact, sels.family_name), sels.text);
    const identifier = try readString(objc.msgSendId(contact, sels.identifier), sels.text);
    const display = try readDisplayName(allocator, given, family, sels, collector.whitespace);

    const phones = try readValueStrings(
        allocator,
        objc.msgSendId(contact, sels.phone_numbers),
        sels,
        .phone,
    );
    defer allocator.free(phones);

    const emails = try readValueStrings(
        allocator,
        objc.msgSendId(contact, sels.email_addresses),
        sels,
        .email,
    );
    defer allocator.free(emails);

    try collector.writer.append(allocator, .{
        .id = identifier,
        .given_name = given,
        .family_name = family,
        .display_name = display,
        .phones = phones,
        .emails = emails,
    });
}

/// `"\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)`, done by
/// Foundation rather than imitated. See `joinName`.
///
/// `given` and `family` have already been through `readString`, so neither can
/// contain the NUL that would truncate the joined string on the way into
/// `stringWithUTF8String:`.
fn readDisplayName(
    allocator: std.mem.Allocator,
    given: []const u8,
    family: []const u8,
    sels: ReadSels,
    whitespace: Id,
) ![]const u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const joined = try joinName(allocator, given, family);
    defer allocator.free(joined);

    const ns = try nsString(joined, allocator);
    const trimmed = objc.msgSendId1(ns, sels.trim, whitespace) orelse return error.NativeCallFailed;
    return readString(trimmed, sels.text);
}

/// Which kind of `CNLabeledValue` array is being walked.
///
/// The two differ in exactly one step: a phone's `value` is a `CNPhoneNumber`
/// and needs `stringValue`, while an email's `value` already *is* an
/// `NSString`. Sending `stringValue` to an `NSString` is an unrecognised
/// selector — a SIGABRT, not an error to map — so this is a comptime enum
/// rather than an optional selector that could arrive null.
const LabeledKind = enum { phone, email };

/// `NSArray<CNLabeledValue *>` into flat strings.
///
/// No labels are read at all: `getContacts` throws them away, so the picker's
/// `+[CNLabeledValue localizedStringForLabel:]` per value — across an entire
/// address book — would be work done for nothing.
fn readValueStrings(
    allocator: std.mem.Allocator,
    array: Id,
    sels: ReadSels,
    comptime kind: LabeledKind,
) ![][]const u8 {
    if (!is_darwin) return error.UnsupportedPlatform;
    // Both properties are declared non-null and answer an empty array for a
    // contact with none.
    if (array == null) return error.NativeCallFailed;

    const CountFn = *const fn (Id, Id) callconv(.c) c_ulong;
    const count_of: CountFn = @ptrCast(&objc.objc_msgSend);
    const total = count_of(array, sels.count);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var i: c_ulong = 0;
    while (i < total) : (i += 1) {
        const entry = objc.msgSendId1(array, sels.object_at, i) orelse return error.NativeCallFailed;
        const raw = objc.msgSendId(entry, sels.value) orelse return error.NativeCallFailed;
        const ns = switch (kind) {
            .phone => objc.msgSendId(raw, sels.string_value) orelse return error.NativeCallFailed,
            .email => raw,
        };
        try out.append(allocator, try readString(ns, sels.text));
    }

    return out.toOwnedSlice(allocator);
}

/// `try store.execute(saveRequest)` then `contact.identifier`, in Swift's
/// order: the identifier is only meaningful once the save has succeeded, and
/// reading it first would put a real-looking id on a contact that was never
/// written.
fn saveContact(allocator: std.mem.Allocator, store: Id, work: AddWork) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    var err_out: Id = null;
    const ExecFn = *const fn (Id, Id, Id, ?*Id) callconv(.c) bool;
    const execute: ExecFn = @ptrCast(&objc.objc_msgSend);

    if (!execute(store, work.sels.execute, work.save, &err_out)) {
        if (err_out != null) {
            describeNSError(A.add_contact, "executeSaveRequest:error:", err_out, work.sels.text);
        } else {
            std.log.warn("addContact: executeSaveRequest: returned NO with no NSError", .{});
        }
        return error.NativeCallFailed;
    }

    const identifier = try readString(
        objc.msgSendId(work.contact, work.sels.identifier),
        work.sels.text,
    );
    return shapeIdentifier(allocator, identifier);
}

// =============================================================================
// Tests — host-only.
//
// Everything that decides page-visible bytes is pure and pinned here: routing
// in both directions, the `as? String` rule, the six keys and their order, the
// flat string arrays that distinguish this reply from the picker's, the bare
// identifier string, the empty-book resolve, escaping, and the slot
// bookkeeping.
//
// Nothing here touches `CNContactStore`. On a developer's Mac those classes all
// exist and `requestAccessForEntityType:` would put a real TCC prompt on
// someone's screen — so no test calls `handleMessage` with a payload that would
// reach the native path, and the two that do call it use bodies that are
// refused during parsing, which is itself the assertion that parsing comes
// first.
// =============================================================================

const testing = std.testing;

fn resetSlotsForTesting() void {
    pending_mutex.lock();
    pending_calls = @splat(null);
    pending_mutex.unlock();

    collectors_mutex.lock();
    collectors = @splat(null);
    collectors_mutex.unlock();
}

fn fakeTicket(index: u5, generation: u32) ios_async.Ticket {
    return .{ .index = index, .generation = generation };
}

fn fakeGetWork() Work {
    // Every field is a plain `Id`; nothing below dereferences them, and the
    // bookkeeping under test does not care what they point at.
    return .{ .get_contacts = .{ .request = null, .sels = std.mem.zeroes(ReadSels) } };
}

// ---------------------------------------------------------------------------
// The action table, against the dispatcher, in both directions
// ---------------------------------------------------------------------------

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    try testing.expectEqualStrings(A.get_contacts, capability_actions[0].name);
    try testing.expectEqualStrings(A.add_contact, capability_actions[1].name);

    for (capability_actions) |decl| {
        // A `.result` whose handler never replies parks the caller on a promise
        // with no timeout; a `.none` that is awaited resolves immediately and
        // means nothing. Swift resolves or rejects every path, so `.result`.
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        // `.live` with a reason would be a contradiction the manifest shows apps.
        try testing.expect(decl.reason == null);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares this against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as Zig
    // serving an action the spec does not have. It cannot catch both sides
    // being renamed in step, which this holds.
    try testing.expectEqualStrings("getContacts", A.get_contacts);
    try testing.expectEqualStrings("addContact", A.add_contact);
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

test "both actions route to their own handler" {
    try testing.expectEqual(Route.get_contacts, routeFor("getContacts").?);
    try testing.expectEqual(Route.add_contact, routeFor("addContact").?);
}

test "an action this module does not serve is refused as UnknownAction" {
    // Not any other error: `ios_dispatch.route` reads UnknownAction as "not
    // mine, ask the next module" and anything else as a final answer. Getting
    // this wrong would make this file swallow another module's action — or the
    // shim's.
    var bridge = ContactsBridge.init(testing.allocator);
    defer bridge.deinit();

    for ([_][]const u8{
        // The picker's action, which is a different module and a different
        // reply shape.
        "pickContact",
        "getCalendarEvents",
        "requestPermission",
        // Casing and plurals are how a real typo arrives, and a miss does not
        // fail loudly: the action would quietly fall through to the Swift shim.
        "getcontacts",
        "GetContacts",
        "getContact",
        "addContacts",
        "addcontact",
        "",
    }) |action| {
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(action, "{}"),
        );
        try testing.expect(routeFor(action) == null);
    }
}

test "getContacts cannot fail on a payload it never reads" {
    // Swift's case reads nothing off `body`, so there is no field to drop and
    // no malformed `d` that may fail this call. The handler taking no `data`
    // parameter is what makes that structural rather than a promise: `self`
    // only, where `addContact` takes `self` and the payload.
    try testing.expectEqual(
        @as(usize, 1),
        @typeInfo(@TypeOf(ContactsBridge.getContacts)).@"fn".param_types.len,
    );
    try testing.expectEqual(
        @as(usize, 2),
        @typeInfo(@TypeOf(ContactsBridge.addContact)).@"fn".param_types.len,
    );
}

// ---------------------------------------------------------------------------
// addContact's payload
// ---------------------------------------------------------------------------

test "the four fields are read out of the nested contact object" {
    // The page posts `{action, contact: {...}, callbackId}`, so `d`'s root has
    // a `contact` key whose value is an object. Reading these off the root
    // instead would silently save an empty contact.
    var fields = try parseNewContact(testing.allocator,
        \\{"contact":{"givenName":"Ada","familyName":"Lovelace","phone":"+1 555 0100","email":"ada@example.com"}}
    );
    defer fields.deinit(testing.allocator);

    try testing.expectEqualStrings("Ada", fields.given_name.?);
    try testing.expectEqualStrings("Lovelace", fields.family_name.?);
    try testing.expectEqualStrings("+1 555 0100", fields.phone.?);
    try testing.expectEqualStrings("ada@example.com", fields.email.?);
}

test "an absent field is unset rather than empty" {
    // Unset and empty-string are different contacts: `givenName = ""` writes an
    // empty name over whatever the container would have derived.
    var fields = try parseNewContact(testing.allocator, "{\"contact\":{\"givenName\":\"Solo\"}}");
    defer fields.deinit(testing.allocator);

    try testing.expectEqualStrings("Solo", fields.given_name.?);
    try testing.expect(fields.family_name == null);
    try testing.expect(fields.phone == null);
    try testing.expect(fields.email == null);
}

test "a field that is not a string is left unset, exactly as as? String leaves it" {
    // `{"phone": 5551234}` is the case that decides this file's behaviour:
    // Swift's `if let phone = data["phone"] as? String` does not fire, the
    // property is not set, and the save proceeds. Erroring would refuse a call
    // the shim accepts; stringifying would write a number the page never sent
    // as text.
    var fields = try parseNewContact(testing.allocator,
        \\{"contact":{"givenName":5551234,"familyName":true,"phone":null,"email":{"a":1}}}
    );
    defer fields.deinit(testing.allocator);

    try testing.expect(fields.given_name == null);
    try testing.expect(fields.family_name == null);
    try testing.expect(fields.phone == null);
    try testing.expect(fields.email == null);
}

test "displayName is dropped, because CNMutableContact has nowhere to put it" {
    // `craft.d.ts` declares it and `test-bridges.html` sends it; Swift reads
    // four keys and this is not one of them. Parity, stated in a test so the
    // next reader does not "fix" it.
    var fields = try parseNewContact(
        testing.allocator,
        "{\"contact\":{\"displayName\":\"Test User\"}}",
    );
    defer fields.deinit(testing.allocator);

    try testing.expect(fields.given_name == null);
    try testing.expect(fields.family_name == null);
    try testing.expect(fields.phone == null);
    try testing.expect(fields.email == null);
    const field_names = @typeInfo(NewContact).@"struct".field_names;
    try testing.expectEqual(@as(usize, 4), field_names.len);
    for (field_names) |name| {
        try testing.expect(!std.mem.eql(u8, name, "display_name"));
        try testing.expect(!std.mem.eql(u8, name, "displayName"));
    }
}

test "a missing or non-object contact rejects, where Swift answers nothing at all" {
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        parseNewContact(testing.allocator, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        parseNewContact(testing.allocator, "{\"other\":1}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseNewContact(testing.allocator, "{\"contact\":\"Ada\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseNewContact(testing.allocator, "{\"contact\":null}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseNewContact(testing.allocator, "{\"contact\":[{\"givenName\":\"Ada\"}]}"),
    );
}

test "the payload is validated before anything native is touched" {
    // The refusal has to reach the page identically on every platform, and it
    // has to happen before `requestAccessForEntityType:` — which in an app
    // without NSContactsUsageDescription is a process kill, and in one with it
    // is a prompt on a user's screen for a call that was already malformed.
    // This is also why the suite can run these at all.
    var bridge = ContactsBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.add_contact, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.add_contact, "{\"contact\":"),
    );
}

test "a body that cannot be read is an error, not an empty contact" {
    // Acting on a default for a payload that failed to parse is how an empty
    // contact gets written to somebody's address book and reported as success.
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        parseNewContact(testing.allocator, "{\"contact\":{"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        parseNewContact(testing.allocator, "[{\"givenName\":\"Ada\"}]"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        parseNewContact(testing.allocator, "\"contact\""),
    );
}

test "an embedded NUL is refused rather than silently truncated" {
    // `stringWithUTF8String:` stops at the first NUL, so accepting this would
    // write "Ada" where the page sent "Ada\x00Lovelace" — a wrong value in the
    // user's address book, reported as success. Swift would have stored the
    // whole string; the divergence is the module comment's, and this is where
    // it is enforced.
    // `\u0000` in the JSON text, which is how a NUL legitimately arrives:
    // `JSON.stringify` emits exactly this escape and the parser decodes it to a
    // real NUL byte in the value.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseNewContact(testing.allocator, "{\"contact\":{\"givenName\":\"Ada\\u0000Lovelace\"}}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseNewContact(testing.allocator, "{\"contact\":{\"email\":\"a\\u0000b@example.com\"}}"),
    );

    // A raw NUL *byte* in the message is a different fault — an unescaped
    // control character is not JSON at all — and is reported as such rather
    // than as a bad field.
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        parseNewContact(testing.allocator, "{\"contact\":{\"givenName\":\"Ada\u{0000}Lovelace\"}}"),
    );
}

// ---------------------------------------------------------------------------
// getContacts' reply
// ---------------------------------------------------------------------------

fn shapeRowsForTesting(allocator: std.mem.Allocator, rows: []const ContactRow) ![]u8 {
    var writer = RowWriter{};
    errdefer writer.deinit(allocator);
    try writer.begin(allocator);
    for (rows) |row| try writer.append(allocator, row);
    return writer.finish(allocator);
}

test "one contact is the six-key object getContacts builds, in a fixed order" {
    const allocator = testing.allocator;
    const json = try shapeRowsForTesting(allocator, &.{.{
        .id = "AB12-CD34",
        .given_name = "Ada",
        .family_name = "Lovelace",
        .display_name = "Ada Lovelace",
        .phones = &.{"+1 555 0100"},
        .emails = &.{"ada@example.com"},
    }});
    defer allocator.free(json);

    try testing.expectEqualStrings(
        "[{\"id\":\"AB12-CD34\",\"givenName\":\"Ada\",\"familyName\":\"Lovelace\"," ++
            "\"displayName\":\"Ada Lovelace\"," ++
            "\"phoneNumbers\":[\"+1 555 0100\"]," ++
            "\"emailAddresses\":[\"ada@example.com\"]}]",
        json,
    );
}

test "phone numbers and email addresses are flat strings, not the picker's label pairs" {
    // The single easiest thing to get wrong here, because the sibling module
    // does the opposite and both parse. `getContacts` is
    // `phone.value.stringValue` into `[String]`; `pickContact` is
    // `{label, number}`. `craft.d.ts:1157-1164` agrees with this one.
    const allocator = testing.allocator;
    const json = try shapeRowsForTesting(allocator, &.{.{
        .id = "1",
        .given_name = "A",
        .family_name = "B",
        .display_name = "A B",
        .phones = &.{ "555", "556" },
        .emails = &.{"a@b.c"},
    }});
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"label\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"number\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"address\"") == null);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const one = parsed.value.array.items[0].object;
    const phones = one.get("phoneNumbers").?.array.items;
    try testing.expectEqual(@as(usize, 2), phones.len);
    try testing.expectEqualStrings("555", phones[0].string);
    try testing.expectEqualStrings("556", phones[1].string);
    try testing.expectEqualStrings("a@b.c", one.get("emailAddresses").?.array.items[0].string);
}

test "a contact with no numbers and no addresses keeps both keys as empty arrays" {
    // Swift always assigns both keys, so a page reading
    // `contact.phoneNumbers.length` must not meet `undefined`.
    const allocator = testing.allocator;
    const json = try shapeRowsForTesting(allocator, &.{.{
        .id = "1",
        .given_name = "Solo",
        .family_name = "",
        .display_name = "Solo",
        .phones = &.{},
        .emails = &.{},
    }});
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"phoneNumbers\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"emailAddresses\":[]") != null);
}

test "an empty address book is an empty array that resolves" {
    // A fresh Simulator answers exactly this, and `test-bridges.html:804`
    // prints `Found 0 contacts`. Turning it into an error or a `{}` would fail
    // a call the shim answers successfully. `[]` is also truthy, so the page's
    // `payload || {}` leaves it intact.
    const allocator = testing.allocator;
    const json = try shapeRowsForTesting(allocator, &.{});
    defer allocator.free(json);

    try testing.expectEqualStrings("[]", json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
}

test "several contacts are one comma-separated array, in enumeration order" {
    const allocator = testing.allocator;
    const json = try shapeRowsForTesting(allocator, &.{
        .{
            .id = "1",
            .given_name = "A",
            .family_name = "One",
            .display_name = "A One",
            .phones = &.{},
            .emails = &.{},
        },
        .{
            .id = "2",
            .given_name = "B",
            .family_name = "Two",
            .display_name = "B Two",
            .phones = &.{"555"},
            .emails = &.{},
        },
        .{
            .id = "3",
            .given_name = "C",
            .family_name = "Three",
            .display_name = "C Three",
            .phones = &.{},
            .emails = &.{"c@example.com"},
        },
    });
    defer allocator.free(json);

    try testing.expect(json[0] == '[');

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const items = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("1", items[0].object.get("id").?.string);
    try testing.expectEqualStrings("2", items[1].object.get("id").?.string);
    try testing.expectEqualStrings("3", items[2].object.get("id").?.string);
    try testing.expectEqualStrings("555", items[1].object.get("phoneNumbers").?.array.items[0].string);
}

test "user data that needs escaping stays valid JSON" {
    // A contact's name is user data. Before escaping, a single `"` in it would
    // close the string literal inside the `evaluateJavaScript:` source and turn
    // the whole reply into a syntax error in the page rather than a wrong field.
    const allocator = testing.allocator;
    const json = try shapeRowsForTesting(allocator, &.{.{
        .id = "x\\y",
        .given_name = "Ann \"Annie\"",
        .family_name = "O'Neil\nJr",
        .display_name = "Ann\t\"Annie\" O'Neil",
        .phones = &.{"+1\\555"},
        .emails = &.{"q\"@example.com"},
    }});
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const one = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("x\\y", one.get("id").?.string);
    try testing.expectEqualStrings("Ann \"Annie\"", one.get("givenName").?.string);
    try testing.expectEqualStrings("O'Neil\nJr", one.get("familyName").?.string);
    try testing.expectEqualStrings("Ann\t\"Annie\" O'Neil", one.get("displayName").?.string);
    try testing.expectEqualStrings("+1\\555", one.get("phoneNumbers").?.array.items[0].string);
    try testing.expectEqualStrings("q\"@example.com", one.get("emailAddresses").?.array.items[0].string);
}

test "the joined name puts exactly one space in and trims nothing itself" {
    // The trim is Foundation's — Zs plus U+0009, both ends, interior runs
    // preserved — so this half must not pre-empt it. A name with a double
    // space in it stays double-spaced in Swift too.
    const allocator = testing.allocator;

    const both = try joinName(allocator, "Ada", "Lovelace");
    defer allocator.free(both);
    try testing.expectEqualStrings("Ada Lovelace", both);

    // The cases the trim exists for: one half empty leaves a trailing or
    // leading space, and both empty leaves a lone space.
    const given_only = try joinName(allocator, "Solo", "");
    defer allocator.free(given_only);
    try testing.expectEqualStrings("Solo ", given_only);

    const family_only = try joinName(allocator, "", "Lovelace");
    defer allocator.free(family_only);
    try testing.expectEqualStrings(" Lovelace", family_only);

    const neither = try joinName(allocator, "", "");
    defer allocator.free(neither);
    try testing.expectEqualStrings(" ", neither);

    // Interior whitespace is the caller's data, not padding.
    const interior = try joinName(allocator, "John  Q", "Doe");
    defer allocator.free(interior);
    try testing.expectEqualStrings("John  Q Doe", interior);
}

// ---------------------------------------------------------------------------
// addContact's reply
// ---------------------------------------------------------------------------

test "the addContact reply is a bare quoted string, not an object" {
    // `resolveCallback(callbackId, result: contact.identifier)` with
    // `.fragmentsAllowed` puts a quoted string on the wire, and the page does
    // `'Contact created with ID: ' + id`. An object here prints
    // `[object Object]`.
    const allocator = testing.allocator;
    const json = try shapeIdentifier(allocator, "AB12-CD34-EF56");
    defer allocator.free(json);

    try testing.expectEqualStrings("\"AB12-CD34-EF56\"", json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("AB12-CD34-EF56", parsed.value.string);
}

test "an identifier that needs escaping stays a valid JSON string" {
    // A `CNContact` identifier is a UUID today. It is still the identifier
    // Contacts hands back rather than one this file mints, so it is escaped
    // like any other borrowed string.
    const allocator = testing.allocator;
    const json = try shapeIdentifier(allocator, "id\"with\\quotes");
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("id\"with\\quotes", parsed.value.string);
}

// ---------------------------------------------------------------------------
// Failure replies
// ---------------------------------------------------------------------------

test "a denial is a rejection, and these are the exact bytes it puts on the wire" {
    // `denied` calls `ios_async.deliverErrorCode(..., PermissionDenied)`, which
    // lands in `deliverOnMain` -> `sendErrorToJS`. This builds the same envelope
    // that path builds, so the page-visible result of a declined prompt is
    // pinned rather than described.
    //
    // Two things at once. First `"error":true` — it goes out through
    // `__craftBridgeError`, which *rejects*; a `{"granted":false}` resolve
    // would run the page's then-branch for a read that never happened. Second,
    // the divergence in bytes: Swift sends `code:"CRAFT_ERROR"` with the
    // NSError's `localizedDescription` (or `"Permission denied"`), and this is
    // what the page gets instead.
    const allocator = testing.allocator;
    var ctx = bridge_error.ErrorContext.init(
        bridge_error.BridgeError.PermissionDenied,
        A.get_contacts,
        bridge_error.errorMessage(bridge_error.BridgeError.PermissionDenied),
    );
    ctx.request_id = 7;

    const json = try ctx.toJSON(allocator);
    defer allocator.free(json);

    try testing.expectEqualStrings(
        "{\"error\":true,\"code\":\"PERMISSION_DENIED\",\"action\":\"getContacts\"," ++
            "\"message\":\"Permission denied\",\"id\":7}",
        json,
    );

    // And it is not a resolve shape: a rejection carries no contacts.
    try testing.expect(std.mem.indexOf(u8, json, "givenName") == null);
}

test "a completion-side failure reports its cause rather than the nearest word" {
    // The rule the migration keeps paying for: an accurate code sends the
    // reader to the right place. Allocation failure is not a native call
    // failing, and a native call failing is not a permission problem.
    try testing.expectEqual(
        bridge_error.BridgeError.AllocationFailed,
        failureCode(error.OutOfMemory),
    );
    try testing.expectEqual(
        bridge_error.BridgeError.PermissionDenied,
        failureCode(error.PermissionDenied),
    );
    try testing.expectEqual(
        bridge_error.BridgeError.NativeCallFailed,
        failureCode(error.EmbeddedNulInNativeString),
    );
    try testing.expectEqual(
        bridge_error.BridgeError.NativeCallFailed,
        failureCode(error.NativeCallFailed),
    );
}

// ---------------------------------------------------------------------------
// Slot bookkeeping
// ---------------------------------------------------------------------------

test "each async slot carries its own call, so concurrent reads do not collide" {
    // The difference from the picker, which owns one on-screen resource and
    // refuses a second call. Two `getContacts` are two reads and both must be
    // answerable; the slot is leased exclusively by its ticket, so publishing
    // one can never displace another.
    resetSlotsForTesting();
    defer resetSlotsForTesting();

    publishPendingCall(.{ .ticket = fakeTicket(3, 7), .store = null, .work = fakeGetWork() });
    publishPendingCall(.{ .ticket = fakeTicket(4, 9), .store = null, .work = fakeGetWork() });

    const first = takePendingCall(3) orelse return error.PendingWentMissing;
    try testing.expectEqual(@as(u5, 3), first.ticket.index);
    try testing.expectEqual(@as(u32, 7), first.ticket.generation);

    // Taking one leaves the other alone.
    const second = takePendingCall(4) orelse return error.PendingWentMissing;
    try testing.expectEqual(@as(u32, 9), second.ticket.generation);
}

test "a slot is handed over once, so a double-firing completion cannot reply twice" {
    resetSlotsForTesting();
    defer resetSlotsForTesting();

    publishPendingCall(.{ .ticket = fakeTicket(1, 2), .store = null, .work = fakeGetWork() });

    const taken = takePendingCall(1) orelse return error.PendingWentMissing;
    try testing.expectEqual(@as(u5, 1), taken.ticket.index);

    // A duplicate fire finds nothing. `ios_async` would drop the stale
    // generation anyway, but the entry has to be empty here so the second fire
    // never releases the +1 objects a second time either.
    try testing.expect(takePendingCall(1) == null);

    // And the slot is reusable rather than wedged.
    publishPendingCall(.{ .ticket = fakeTicket(1, 4), .store = null, .work = fakeGetWork() });
    try testing.expect(takePendingCall(1) != null);
}

test "a completion for a slot with no call takes nothing" {
    // The stray-completion path every invoke begins with. It has to be a no-op
    // rather than an answer, because the next call to occupy the slot would
    // otherwise receive this one's result.
    resetSlotsForTesting();
    defer resetSlotsForTesting();

    try testing.expect(takePendingCall(0) == null);
    try testing.expect(takePendingCall(ios_async.max_in_flight - 1) == null);
}

test "the collector is visible for one walk and gone after it" {
    // The enumeration block finds its writer through this table. Published
    // before `enumerateContacts…` and cleared the moment it returns, which is
    // what makes the pointer-to-a-stack-frame safe.
    resetSlotsForTesting();
    defer resetSlotsForTesting();

    var writer = RowWriter{};
    defer writer.deinit(testing.allocator);

    var collector = Collector{
        .allocator = testing.allocator,
        .sels = std.mem.zeroes(ReadSels),
        .whitespace = null,
        .writer = &writer,
    };

    try testing.expect(collectorFor(5) == null);
    publishCollector(5, &collector);
    try testing.expectEqual(&collector, collectorFor(5).?);
    // Slots are independent: publishing one does not make another visible.
    try testing.expect(collectorFor(6) == null);

    clearCollector(5);
    try testing.expect(collectorFor(5) == null);
}

test "a contact that cannot be read stops the walk instead of shortening the book" {
    // `collectContacts` checks `collector.failure` *before* the BOOL, because a
    // block that set `stop` leaves the enumeration returning YES. Reporting the
    // rows read so far would tell the page the user has three contacts when
    // they have three hundred.
    //
    // The half of that mechanism a host can drive is the block, so it is driven
    // for real rather than described: `enumerationFired` with a nil `CNContact`,
    // which `appendContact` refuses before it sends a single message. Nothing
    // here touches Contacts.framework. (Asserting a `failure` this test had
    // itself assigned would have asserted only the assignment.)
    if (!is_darwin) return error.SkipZigTest;

    resetSlotsForTesting();
    defer resetSlotsForTesting();

    const allocator = testing.allocator;

    var writer = RowWriter{};
    defer writer.deinit(allocator);
    try writer.begin(allocator);
    try writer.append(allocator, .{
        .id = "1",
        .given_name = "A",
        .family_name = "One",
        .display_name = "A One",
        .phones = &.{},
        .emails = &.{},
    });

    var collector = Collector{
        .allocator = allocator,
        .sels = std.mem.zeroes(ReadSels),
        .whitespace = null,
        .writer = &writer,
    };
    publishCollector(2, &collector);

    // The failure is recorded and the walk is told to stop. No row is appended:
    // half a contact in the array is the fabricated success this path exists to
    // prevent.
    var stop = false;
    enumerationFired(2, null, &stop);
    try testing.expect(stop);
    try testing.expect(collector.failure != null);
    try testing.expectEqual(@as(usize, 1), writer.rows);

    // The partial array exists and is well-formed — which is exactly why the
    // failure flag, and not the buffer's contents, decides the reply.
    try testing.expectEqual(
        bridge_error.BridgeError.NativeCallFailed,
        failureCode(collector.failure.?),
    );

    // A fire that lands before the enumeration notices `stop` keeps stopping,
    // and neither overwrites the first cause nor adds a row.
    const first_cause = collector.failure.?;
    stop = false;
    enumerationFired(2, null, &stop);
    try testing.expect(stop);
    try testing.expectEqual(first_cause, collector.failure.?);
    try testing.expectEqual(@as(usize, 1), writer.rows);

    // And a fire for a slot with no live walk stops rather than reaching for a
    // writer that is not there.
    clearCollector(2);
    stop = false;
    enumerationFired(2, null, &stop);
    try testing.expect(stop);
}

// ---------------------------------------------------------------------------
// Framework constants and blocks
// ---------------------------------------------------------------------------

test "the fetch keys are the five Swift asks for, in its order" {
    // A key missing from this list does not fail: it produces a contact whose
    // property access raises CNContactPropertyNotFetchedException, which is an
    // uncatchable SIGABRT. The list is the guard, so the list is pinned.
    try testing.expectEqual(@as(usize, 5), contact_key_symbols.len);
    try testing.expectEqualStrings("CNContactGivenNameKey", contact_key_symbols[0]);
    try testing.expectEqualStrings("CNContactFamilyNameKey", contact_key_symbols[1]);
    try testing.expectEqualStrings("CNContactPhoneNumbersKey", contact_key_symbols[2]);
    try testing.expectEqualStrings("CNContactEmailAddressesKey", contact_key_symbols[3]);
    try testing.expectEqualStrings("CNContactIdentifierKey", contact_key_symbols[4]);
}

test "the labels are resolved by symbol, never guessed" {
    // A wrong label does not fail — it files the number under the wrong heading
    // in somebody's address book. These are the symbol *names*; the values come
    // from Contacts.framework at runtime.
    try testing.expectEqualStrings("CNLabelPhoneNumberMain", label_phone_main);
    try testing.expectEqualStrings("CNLabelHome", label_email_home);
}

test "CNEntityType.contacts is 0, as an NSInteger" {
    // Passed in an integer register by a `callconv(.c)` signature that has to
    // name its width: `CNEntityType` is `NSInteger`, so `c_long`.
    try testing.expectEqual(@as(c_long, 0), cn_entity_type_contacts);
    try testing.expectEqual(c_long, @TypeOf(cn_entity_type_contacts));
}

test "every slot has its own block, so a completion cannot answer another call" {
    // The invoke is where a slot index is baked in. If `makeBlocks` handed
    // every slot the same invoke, sixteen callers would share one ticket and
    // fifteen promises would be answered with somebody else's data — silently,
    // because every one of those replies is well-formed.
    if (!is_darwin) return error.SkipZigTest;

    for (access_blocks, 0..) |a, i| {
        for (access_blocks[i + 1 ..]) |b| {
            try testing.expect(a.invoke != b.invoke);
        }
        // The two block kinds are different functions with different
        // signatures; sharing one would read arguments from the wrong
        // registers.
        try testing.expect(a.invoke != enumeration_blocks[i].invoke);
    }

    // A global block: never copied, so no heap lifetime and no copy/dispose
    // helpers. The size in the descriptor is the literal's, not a guess.
    try testing.expectEqual(@as(c_int, 1 << 28), BLOCK_IS_GLOBAL);
    try testing.expectEqual(BLOCK_IS_GLOBAL, access_blocks[0].flags);
    try testing.expectEqual(@as(c_ulong, @sizeOf(Block)), block_descriptor.size);

    // And the accessor really hands out the block belonging to the ticket.
    try testing.expectEqual(
        @as(*anyopaque, @ptrCast(&access_blocks[3])),
        accessBlock(fakeTicket(3, 1)),
    );
    try testing.expectEqual(
        @as(*anyopaque, @ptrCast(&enumeration_blocks[3])),
        enumerationBlock(3),
    );
}

test "nothing in this module emits an event" {
    // Neither action has a `sendToWeb` on any Swift path and `test-bridges.html`
    // registers no contacts listener, so an event from here would be a message
    // the shim never sends — and `ios_events.Event` has no name for one. This
    // is a source scan rather than prose because the import is the whole
    // mistake: adding it is what makes the rest possible.
    const source = @embedFile("bridge_mobile_contacts.zig");
    try testing.expect(std.mem.indexOf(u8, source, "@import(\"ios_events.zig\")") == null);

    // Non-vacuity: the same scan finds the two reply calls that *are* made, so
    // a needle that stopped matching anything could not pass unnoticed.
    //
    // Both needles carry an argument and are assembled from halves, and both
    // details are load-bearing. Spelled out whole, each needle would match the
    // very line asserting it; without the argument, each would match the prose
    // further up this file, which names both functions. The sibling modules get
    // the same property from an escaped quote inside their needle — these two
    // calls have nowhere to put one.
    const resolve_call = "ios_async.deliverJson(call" ++ ".ticket,";
    const reject_call = "ios_async.deliverErrorCode(call" ++ ".ticket,";
    try testing.expect(std.mem.indexOf(u8, source, resolve_call) != null);
    try testing.expect(std.mem.indexOf(u8, source, reject_call) != null);
}
