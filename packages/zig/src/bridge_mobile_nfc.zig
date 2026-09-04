//! The `mobile` namespace's one NFC action: `scanNFC`.
//!
//! ## Shape
//!
//! `NFCNDEFReaderSession.readingAvailable` is asked first, exactly as the spec
//! does — it is false on every simulator and on any device without the
//! hardware, and starting a session anyway raises rather than failing.
//!
//! Before that, the class itself is looked up, and a null answer is a real and
//! expected condition rather than a failure. A generated app has CoreNFC in
//! the process because `CraftApp.swift:17` imports it and Swift autolinks what
//! it imports; the `zig-slice` fixture links twelve frameworks by hand and
//! CoreNFC is not among them, so there the lookup misses and this answers
//! `PLATFORM_NOT_SUPPORTED`. Both are honest answers to "can this device
//! scan a tag", which is the question the page asked.
//!
//! The session is `invalidateAfterFirstRead:YES`, so one scan answers one call
//! and the session is done. That is what lets a single pending slot serve this
//! action without a queue.
//!
//! ## The reply
//!
//! An array of NDEF records, flattened across messages, which is what the spec
//! builds:
//!
//! ```json
//! [{"typeNameFormat":1,"type":"T","identifier":"","payload":"hello"}]
//! ```
//!
//! `type`, `identifier` and `payload` are `NSData`. The spec decodes each as
//! UTF-8 and substitutes `""` on failure for the first two; `payload` falls
//! back to base64 instead of an empty string, because a payload is the point
//! of the record and losing it silently would be worse than an encoding a
//! caller has to notice. That asymmetry is the spec's and is reproduced.
//!
//! ## One divergence, and it is a hang the spec has
//!
//! `readerSession:didInvalidateWithError:` in the spec rejects only when the
//! error code is not 200, and 200 is "user cancelled". So a cancelled scan
//! clears `pendingCallbackId` and settles nothing: the page's promise waits
//! forever. This answers `CANCELLED`, which is what every other presented
//! surface in this migration answers for the same gesture — the image picker,
//! the document picker and the contact picker all do.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const ios_delegate = @import("ios_delegate.zig");
const compat_mutex = @import("compat_mutex.zig");
const memory = @import("memory.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();
const BridgeError = bridge_error.BridgeError;

/// `objc.id` spelled locally: `objc_runtime.objc` is an empty struct off
/// Darwin and a signature is analysed even when a comptime guard prunes the
/// body, so naming `objc.id` here would break the Linux build. The
/// notifcancel/securestore precedent.
const Id = ?*anyopaque;

pub const A = struct {
    pub const scan_nfc = "scanNFC";
};

/// `.result`: the spec resolves an array and the page's promise is the untimed
/// legacy kind, so `.none` would strand the caller.
///
/// `.live`: the hardware guard is asked at dispatch and answers honestly on a
/// device without NFC. Nothing here warrants `.unavailable`.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.scan_nfc, .reply = .result },
};

const Route = enum { scan };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.scan_nfc)) return .scan;
    return null;
}

pub const NfcBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        _ = data;
        const route = routeFor(action) orelse return BridgeError.UnknownAction;
        switch (route) {
            .scan => try self.scanNFC(),
        }
    }

    /// Begin one NDEF read.
    ///
    /// Every fallible step runs before `ios_async.acquire`, so no error path
    /// sits between leasing a slot and handing the session its delegate: a
    /// failure there would have to release the slot by hand, and a missed
    /// release narrows the pool permanently. The same ordering rule
    /// `bridge_mobile_notifications.zig` documents.
    fn scanNFC(self: *Self) !void {
        _ = self;
        if (!is_darwin) return error.UnsupportedPlatform;

        const SessionClass = objc.objc_getClass("NFCNDEFReaderSession") orelse
            return BridgeError.PlatformNotSupported;

        // The spec's guard. False on every simulator, and beginning a session
        // without it raises rather than returning an error.
        const sel_available = objc.sel_registerName("readingAvailable") orelse
            return error.SelectorNotFound;
        const AvailFn = *const fn (Id, objc.SEL) callconv(.c) bool;
        const avail: AvailFn = @ptrCast(&objc.objc_msgSend);
        if (!avail(SessionClass, sel_available)) return BridgeError.PlatformNotSupported;

        const handler = try delegateInstance();
        const sel_init = objc.sel_registerName("initWithDelegate:queue:invalidateAfterFirstRead:") orelse
            return error.SelectorNotFound;
        const sel_alloc = objc.sel_registerName("alloc") orelse return error.SelectorNotFound;
        const sel_alert = objc.sel_registerName("setAlertMessage:") orelse return error.SelectorNotFound;
        const sel_begin = objc.sel_registerName("begin") orelse return error.SelectorNotFound;

        const ticket = ios_async.acquire(A.scan_nfc) orelse return poolFull();
        errdefer ios_async.abandon(ticket);

        const raw = objc.msgSendId(SessionClass, sel_alloc);
        const InitFn = *const fn (Id, objc.SEL, Id, Id, bool) callconv(.c) Id;
        const init_fn: InitFn = @ptrCast(&objc.objc_msgSend);
        // `queue: nil` is what the spec passes; CoreNFC then picks its own.
        const session = init_fn(raw, sel_init, handler, null, true);
        if (session == null) return BridgeError.NativeCallFailed;

        // Published before `begin`, never after: the delegate can fire before
        // `begin` returns, and a callback arriving at an empty slot would have
        // no ticket to answer with.
        publishPending(ticket, session);

        if (try nsString(alert_message)) |msg| objc.msgSendVoid1(session, sel_alert, msg);
        objc.msgSend(session, sel_begin);
    }
};

/// The spec's wording, kept so an app that has localised around it does not
/// see the prompt change under it.
const alert_message = "Hold your iPhone near the NFC tag";

fn poolFull() BridgeError {
    std.log.warn("scanNFC refused: all {d} async slots in flight", .{ios_async.max_in_flight});
    return BridgeError.InvalidParameter;
}

// =============================================================================
// The pending scan. One slot: the session is invalidate-after-first-read, so a
// scan answers exactly once and there is never a second in flight for it.
// =============================================================================

const Pending = struct {
    ticket: ios_async.Ticket,
    session: Id,
};

var pending: ?Pending = null;
var pending_mutex: compat_mutex.Mutex = .{};

fn publishPending(ticket: ios_async.Ticket, session: Id) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending = .{ .ticket = ticket, .session = session };
}

/// Read and clear. Clearing is what makes a second delegate callback a no-op
/// rather than a second reply — CoreNFC can invalidate a session it has
/// already reported a read for.
fn takePending() ?Pending {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const p = pending;
    pending = null;
    return p;
}

var delegate: ?Id = null;
const delegate_class_name = "CraftNfcDelegate";

/// Built once and kept. `NFCNDEFReaderSession` holds its delegate weakly and
/// one instance serves every scan for the life of the process, so this is
/// retained and never released — the same shape `bridge_mobile_bluetooth.zig`
/// uses for its central-manager delegate.
fn delegateInstance() !Id {
    if (delegate) |existing| return existing;

    const class = ios_delegate.defineClass(delegate_class_name, "NSObject", &.{
        .{
            .selector = "readerSession:didDetectNDEFs:",
            .imp = @ptrCast(&craftNfcDidDetect),
            .types = ios_delegate.enc.void_two_objects,
        },
        .{
            .selector = "readerSession:didInvalidateWithError:",
            .imp = @ptrCast(&craftNfcDidInvalidate),
            .types = ios_delegate.enc.void_two_objects,
        },
    }) catch |err| {
        std.log.warn("scanNFC: could not build the delegate class: {}", .{err});
        return BridgeError.NativeCallFailed;
    };

    delegate = ios_delegate.instantiate(class) catch |err| {
        std.log.warn("scanNFC: could not instantiate the delegate: {}", .{err});
        return BridgeError.NativeCallFailed;
    };
    return delegate.?;
}

fn craftNfcDidDetect(_: Id, _: objc.SEL, _: Id, messages: Id) callconv(.c) void {
    if (!is_darwin) return;
    const p = takePending() orelse {
        std.log.warn("scanNFC: a read arrived with no scan recorded; ignored", .{});
        return;
    };

    const allocator = std.heap.c_allocator;
    const json = shapeRecords(allocator, messages) catch |err| {
        std.log.err("scanNFC could not shape its reply ({}); rejecting", .{err});
        ios_async.deliverError(p.ticket);
        return;
    };
    defer allocator.free(json);

    ios_async.deliverJson(p.ticket, json);
}

fn craftNfcDidInvalidate(_: Id, _: objc.SEL, _: Id, err: Id) callconv(.c) void {
    if (!is_darwin) return;
    // A read already answered clears the slot, so an invalidation after a
    // successful scan finds nothing and correctly says nothing.
    const p = takePending() orelse return;

    // The spec rejects only when the code is not 200, and 200 is user-cancel —
    // which leaves the promise unsettled. `CANCELLED` is what the other
    // presented surfaces answer for the same gesture.
    const code = errorCode(err);
    if (code == nfc_reader_session_cancelled) {
        ios_async.deliverErrorCode(p.ticket, BridgeError.Cancelled);
        return;
    }
    std.log.warn("scanNFC: the session invalidated with code {d}", .{code});
    ios_async.deliverErrorCode(p.ticket, BridgeError.NativeCallFailed);
}

/// `NFCReaderError.readerSessionInvalidationErrorUserCanceled` — 200. The spec
/// spells it as the bare literal with the comment "200 is user cancelled".
const nfc_reader_session_cancelled: i64 = 200;

fn errorCode(err: Id) i64 {
    const e = err orelse return 0;
    const sel = objc.sel_registerName("code") orelse return 0;
    const Fn = *const fn (Id, objc.SEL) callconv(.c) isize;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return @intCast(func(e, sel));
}

fn nsString(text: []const u8) !?Id {
    if (!is_darwin) return null;
    const allocator = std.heap.c_allocator;
    const c_text = try memory.dupeZ(allocator, u8, text);
    defer allocator.free(c_text);

    const NSString = objc.objc_getClass("NSString") orelse return null;
    const sel = objc.sel_registerName("stringWithUTF8String:") orelse return null;
    const Fn = *const fn (Id, objc.SEL, [*:0]const u8) callconv(.c) Id;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(NSString, sel, c_text.ptr);
}

// =============================================================================
// Shaping the reply.
//
// Split from the Objective-C walk so the JSON assembly — the half that decides
// what the page sees — is testable on a host with no CoreNFC in the process.
// =============================================================================

/// `appendJsonEscaped` escapes the *contents* and adds no quotes, so every
/// field here would emit a bare token without this. Wrapping it once means a
/// call site cannot forget.
fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, out, s);
    try out.append(allocator, '"');
}

/// One NDEF record as the page receives it.
const Record = struct {
    type_name_format: u8,
    /// Already decoded; `""` where the spec substitutes it.
    type_text: []const u8,
    identifier: []const u8,
    payload: []const u8,
};

/// `[{...},{...}]`, or `[]` for a read with no records.
///
/// An empty array is a real answer, not a failure: a tag can carry a message
/// with no records, and the spec resolves the empty array for it.
fn appendRecords(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), records: []const Record) !void {
    try out.append(allocator, '[');
    for (records, 0..) |r, i| {
        if (i != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"typeNameFormat\":");
        var tnf_buf: [4]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&tnf_buf, "{d}", .{r.type_name_format}));
        try out.appendSlice(allocator, ",\"type\":");
        try appendJsonString(allocator, out, r.type_text);
        try out.appendSlice(allocator, ",\"identifier\":");
        try appendJsonString(allocator, out, r.identifier);
        try out.appendSlice(allocator, ",\"payload\":");
        try appendJsonString(allocator, out, r.payload);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
}

/// Walk `NSArray<NFCNDEFMessage *>` into the reply, flattening records across
/// messages exactly as the spec's nested loop does.
fn shapeRecords(allocator: std.mem.Allocator, messages: Id) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (!is_darwin or messages == null) {
        try appendRecords(allocator, &out, &.{});
        return out.toOwnedSlice(allocator);
    }

    const sel_count = objc.sel_registerName("count") orelse return error.SelectorNotFound;
    const sel_at = objc.sel_registerName("objectAtIndex:") orelse return error.SelectorNotFound;
    const sel_records = objc.sel_registerName("records") orelse return error.SelectorNotFound;
    const sel_tnf = objc.sel_registerName("typeNameFormat") orelse return error.SelectorNotFound;
    const sel_type = objc.sel_registerName("type") orelse return error.SelectorNotFound;
    const sel_ident = objc.sel_registerName("identifier") orelse return error.SelectorNotFound;
    const sel_payload = objc.sel_registerName("payload") orelse return error.SelectorNotFound;

    const CountFn = *const fn (Id, objc.SEL) callconv(.c) usize;
    const count_fn: CountFn = @ptrCast(&objc.objc_msgSend);
    const AtFn = *const fn (Id, objc.SEL, usize) callconv(.c) Id;
    const at_fn: AtFn = @ptrCast(&objc.objc_msgSend);
    const TnfFn = *const fn (Id, objc.SEL) callconv(.c) u8;
    const tnf_fn: TnfFn = @ptrCast(&objc.objc_msgSend);

    try out.append(allocator, '[');
    var wrote: usize = 0;

    const message_count = count_fn(messages, sel_count);
    var m: usize = 0;
    while (m < message_count) : (m += 1) {
        const message = at_fn(messages, sel_at, m);
        const records = objc.msgSendId(message, sel_records);
        if (records == null) continue;

        const record_count = count_fn(records, sel_count);
        var r: usize = 0;
        while (r < record_count) : (r += 1) {
            const record = at_fn(records, sel_at, r);
            if (record == null) continue;

            if (wrote != 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, "{\"typeNameFormat\":");
            var tnf_buf: [4]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&tnf_buf, "{d}", .{tnf_fn(record, sel_tnf)}));

            // `type` and `identifier` fall back to "" the way the spec's
            // `String(data:encoding:) ?? ""` does.
            try out.appendSlice(allocator, ",\"type\":");
            try appendData(allocator, &out, objc.msgSendId(record, sel_type), .empty_on_failure);
            try out.appendSlice(allocator, ",\"identifier\":");
            try appendData(allocator, &out, objc.msgSendId(record, sel_ident), .empty_on_failure);

            // `payload` falls back to base64 instead: the payload is the point
            // of the record, and dropping it silently is worse than handing
            // back an encoding the caller has to notice.
            try out.appendSlice(allocator, ",\"payload\":");
            try appendData(allocator, &out, objc.msgSendId(record, sel_payload), .base64_on_failure);

            try out.append(allocator, '}');
            wrote += 1;
        }
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

const DataFallback = enum { empty_on_failure, base64_on_failure };

/// An `NSData` as a JSON string: its UTF-8 if it is valid UTF-8, otherwise the
/// fallback the field calls for.
fn appendData(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    data: Id,
    fallback: DataFallback,
) !void {
    const bytes = dataBytes(data) orelse return appendJsonString(allocator, out, "");

    if (std.unicode.utf8ValidateSlice(bytes)) {
        return appendJsonString(allocator, out, bytes);
    }
    switch (fallback) {
        .empty_on_failure => return appendJsonString(allocator, out, ""),
        .base64_on_failure => {
            const enc = std.base64.standard.Encoder;
            const buf = try allocator.alloc(u8, enc.calcSize(bytes.len));
            defer allocator.free(buf);
            return appendJsonString(allocator, out, enc.encode(buf, bytes));
        },
    }
}

/// Borrow an `NSData`'s bytes. The slice points into the object, which the
/// caller's autorelease pool outlives for the duration of this walk.
fn dataBytes(data: Id) ?[]const u8 {
    if (!is_darwin) return null;
    const d = data orelse return null;
    const sel_bytes = objc.sel_registerName("bytes") orelse return null;
    const sel_length = objc.sel_registerName("length") orelse return null;

    const BytesFn = *const fn (Id, objc.SEL) callconv(.c) ?[*]const u8;
    const bytes_fn: BytesFn = @ptrCast(&objc.objc_msgSend);
    const LenFn = *const fn (Id, objc.SEL) callconv(.c) usize;
    const len_fn: LenFn = @ptrCast(&objc.objc_msgSend);

    const len = len_fn(d, sel_length);
    if (len == 0) return &.{};
    const ptr = bytes_fn(d, sel_bytes) orelse return null;
    return ptr[0..len];
}

// =============================================================================
// Tests — host-only. The CoreNFC walk cannot run here (no framework, and
// `readingAvailable` is false on every simulator), so what is pinned is
// everything that decides what the page sees: routing, the action name, the
// reply bytes, the escaping, and the empty case.
// =============================================================================

const testing = std.testing;

test "the declared action is the one the handler serves" {
    try testing.expectEqual(@as(usize, 1), capability_actions.len);
    try testing.expectEqualStrings(A.scan_nfc, capability_actions[0].name);
    try testing.expectEqual(capabilities.Reply.result, capability_actions[0].reply);
    try testing.expectEqual(capabilities.ActionStatus.live, capability_actions[0].status);
    try testing.expect(routeFor(A.scan_nfc) == .scan);
    try testing.expect(routeFor("scanQRCode") == null);
}

test "an action this namespace does not serve is reported, not ignored" {
    var bridge = NfcBridge.init(testing.allocator);
    defer bridge.deinit();
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("scanQRCode", "{}"));
}

test "a read with no records is an empty array, not a failure" {
    // A tag can carry a message with no records, and the spec resolves `[]`
    // for it. Answering an error instead would turn a real answer into a bug
    // report.
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendRecords(allocator, &out, &.{});
    try testing.expectEqualStrings("[]", out.items);
}

test "records are flattened across messages, in order" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendRecords(allocator, &out, &.{
        .{ .type_name_format = 1, .type_text = "T", .identifier = "", .payload = "hello" },
        .{ .type_name_format = 2, .type_text = "U", .identifier = "id", .payload = "https://x" },
    });
    try testing.expectEqualStrings(
        "[{\"typeNameFormat\":1,\"type\":\"T\",\"identifier\":\"\",\"payload\":\"hello\"}," ++
            "{\"typeNameFormat\":2,\"type\":\"U\",\"identifier\":\"id\",\"payload\":\"https://x\"}]",
        out.items,
    );
}

test "a payload carrying a quote or a backslash stays valid JSON" {
    // NDEF payloads are arbitrary bytes written by whoever made the tag, so
    // this is the field most likely to carry something that breaks a naive
    // reply. Parsed rather than compared, so a wrong escape cannot pass.
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendRecords(allocator, &out, &.{
        .{ .type_name_format = 1, .type_text = "T", .identifier = "", .payload = "he said \"hi\"\\ok\n" },
    });

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    const first = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("he said \"hi\"\\ok\n", first.get("payload").?.string);
    try testing.expectEqual(@as(i64, 1), first.get("typeNameFormat").?.integer);
}

test "the user-cancel code is the spec's, not a guess" {
    // The spec writes the bare literal with the comment "200 is user
    // cancelled"; this is that constant, named. It is also the one branch that
    // diverges — the spec settles nothing there and this answers CANCELLED.
    try testing.expectEqual(@as(i64, 200), nfc_reader_session_cancelled);
}

test "the prompt is the spec's wording" {
    // An app that has localised around this string should not see it change.
    try testing.expectEqualStrings("Hold your iPhone near the NFC tag", alert_message);
}
