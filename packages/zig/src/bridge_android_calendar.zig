//! `deleteCalendarEvent` on Android — the first action here that answers
//! through the reply channel rather than by returning.
//!
//! ## What the shim does
//!
//! The Kotlin builds a content URI from the event id, deletes through the
//! `ContentResolver`, and resolves `true`; on any exception it rejects with
//! the message. That is all ported.
//!
//! The rejection is built as JSON through `bridge_error.appendJsonEscaped`
//! rather than pasted into a quoted string. When this module was written the
//! shim did the latter —
//!
//!     "window._craftDeleteEventReject && window._craftDeleteEventReject('${e.message}')"
//!
//! — and `eventId.toLong()` puts the caller's own text in that message, so
//! `craft.calendar.delete("1'x")` produced a script that did not parse:
//! `evaluateJavascript` ran nothing, neither the resolve nor the reject fired,
//! and the hand-built promise had no timeout to notice. #154 fixed all
//! fifty-eight such emissions, and `android_reply_escaping_test` now keeps
//! them fixed, so this is no longer a divergence — but the escaping stays
//! here, because `events.settle` takes a payload that is already JSON and this
//! module is what has to produce it.
//!
//! ## `toLong()` is reproduced exactly, including what it refuses
//!
//! `Long.parseLong` accepts an optional sign and decimal digits, and nothing
//! else — no whitespace, no underscores, no hex, no `+1_000`. Zig's
//! `parseInt(i64, s, 10)` is more permissive about underscores, so the digits
//! are checked before parsing. An id the shim would reject must reject here,
//! or Zig would delete an event the shim would have refused to look up.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const events = @import("android_events.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const delete_calendar_event = "deleteCalendarEvent";
};

/// The globals the injected JS assigns for this action.
pub const resolve_global = "_craftDeleteEventResolve";
pub const reject_global = "_craftDeleteEventReject";

/// `Long.parseLong(text)`, or null where Java would throw.
///
/// Deliberately stricter than `std.fmt.parseInt`, which accepts `1_000`.
/// Java does not, and an id this accepted but the shim would not is an id Zig
/// would act on and the shim would refuse.
pub fn parseEventId(text: []const u8) ?i64 {
    if (text.len == 0) return null;

    var digits = text;
    if (digits[0] == '+' or digits[0] == '-') digits = digits[1..];
    if (digits.len == 0) return null;

    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

/// `contentResolver.delete(ContentUris.withAppendedId(Events.CONTENT_URI, id), null, null)`.
pub fn deleteEvent(j: Jni, activity: jobject, id: i64) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    // `CalendarContract$Events` — a nested class, so the binary name takes the
    // dollar. `android/provider/CalendarContract/Events` finds nothing.
    const events_cls = try j.findClass("android/provider/CalendarContract$Events");
    const base_uri = try j.staticObjectField(
        events_cls,
        try j.staticFieldId(events_cls, "CONTENT_URI", "Landroid/net/Uri;"),
    );

    const content_uris_cls = try j.findClass("android/content/ContentUris");
    const uri = try j.callStaticObjectMethodA(
        content_uris_cls,
        try j.staticMethodId(
            content_uris_cls,
            "withAppendedId",
            "(Landroid/net/Uri;J)Landroid/net/Uri;",
        ),
        &.{ .{ .l = base_uri }, .{ .j = id } },
    );

    const activity_cls = try j.objectClass(activity);
    const resolver = try j.callObjectMethod(
        activity,
        try j.methodId(activity_cls, "getContentResolver", "()Landroid/content/ContentResolver;"),
    );

    // The row count is discarded, as the Kotlin discards it. Deleting an event
    // that is not there returns 0 and is not an error on either side — a page
    // removing something already gone has done nothing wrong.
    const resolver_cls = try j.objectClass(resolver);
    _ = try j.callIntMethodA(
        resolver,
        try j.methodId(
            resolver_cls,
            "delete",
            "(Landroid/net/Uri;Ljava/lang/String;[Ljava/lang/String;)I",
        ),
        &.{ .{ .l = uri }, .{ .l = null }, .{ .l = null } },
    );
}

/// Reject with `message`, escaped.
///
/// The escaping is the whole point of this function existing rather than the
/// call being inline — `events.settle` sends the payload as written, so a raw
/// message would emit a script that does not parse. See the module comment.
pub fn rejectWith(allocator: std.mem.Allocator, message: []const u8) !void {
    const payload = try rejectPayload(allocator, message);
    defer allocator.free(payload);
    try events.settle(allocator, reject_global, payload);
}

/// `message` as a JSON string, quotes included.
///
/// Split out so the test exercises this rather than a copy of it. An earlier
/// version inlined the escaping here and asserted on the same three lines
/// rewritten in the test — which passed happily when the escaping was removed
/// from the code, because the test was not calling the code.
pub fn rejectPayload(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);

    // The quotes are this caller's job: `appendJsonEscaped` escapes the
    // contents and writes no delimiters.
    try payload.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &payload, message);
    try payload.append(allocator, '"');

    return payload.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "an id parses exactly where Long.parseLong would" {
    try testing.expectEqual(@as(i64, 42), parseEventId("42").?);
    try testing.expectEqual(@as(i64, -42), parseEventId("-42").?);
    try testing.expectEqual(@as(i64, 42), parseEventId("+42").?);
    try testing.expectEqual(@as(i64, 0), parseEventId("0").?);
    try testing.expectEqual(@as(i64, 9_223_372_036_854_775_807), parseEventId("9223372036854775807").?);
}

test "an id Java would refuse is refused here too" {
    // Each of these throws NumberFormatException on the shim, so each must
    // reject here. An id Zig accepted and the shim did not is an id Zig would
    // delete an event for that the shim would never have looked up.
    for ([_][]const u8{
        "",      "abc",                 "1'x", " 42", "42 ", "4 2", "0x2a", "1e3", "42L", "+", "-",
        "٤٢",
        // Zig's parseInt accepts this and Java does not.
        "1_000",
        // Past Long.MAX_VALUE.
        "9223372036854775808",
    }) |bad| {
        try testing.expect(parseEventId(bad) == null);
    }
}

test "a rejection message with a quote is escaped rather than emitted raw" {
    // The bug that used to be one line away. Before #154 the shim turned an id
    // of `1'x` into `…Reject('For input string: "1'x"')`, which does not parse
    // — so evaluateJavascript ran nothing and the promise never settled.
    const payload = try rejectPayload(testing.allocator, "For input string: \"1'x\"");
    defer testing.allocator.free(payload);

    // Valid JSON, and it round-trips to exactly the original message.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("For input string: \"1'x\"", parsed.value.string);

    // And the apostrophe survives as itself rather than as an escape, which is
    // what makes the emitted script parse where the shim's does not.
    try testing.expect(std.mem.indexOf(u8, payload, "'") != null);
}

test "the action name and its globals match the shim exactly" {
    // The globals are assigned by the injected JS, and a rename on either side
    // is a promise that never settles.
    try testing.expectEqualStrings("deleteCalendarEvent", A.delete_calendar_event);
    try testing.expectEqualStrings("_craftDeleteEventResolve", resolve_global);
    try testing.expectEqualStrings("_craftDeleteEventReject", reject_global);
}
