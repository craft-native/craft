//! The calendar actions on Android, both of which answer through the reply
//! channel rather than by returning.
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
    pub const get_calendar_events = "getCalendarEvents";
    pub const create_calendar_event = "createCalendarEvent";
};

/// The globals the injected JS assigns for each action.
///
/// `getCalendarEvents` uses `_craftCalendar*` rather than a name of its own,
/// which is worth noticing rather than tidying: the injected JS assigns them,
/// and renaming one side is a promise that never settles.
pub const resolve_global = "_craftDeleteEventResolve";
pub const reject_global = "_craftDeleteEventReject";
pub const list_resolve_global = "_craftCalendarResolve";
pub const list_reject_global = "_craftCalendarReject";
pub const create_resolve_global = "_craftCreateEventResolve";
pub const create_reject_global = "_craftCreateEventReject";

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
    try rejectOn(allocator, reject_global, message);
}

/// `text` as a JSON string, quotes included.
///
/// Used for a rejection message and for the id `createCalendarEvent` resolves
/// with, both of which are page-visible text that has to survive a quote.
///
/// Split out so the test exercises this rather than a copy of it. An earlier
/// version inlined the escaping at the call site and asserted on the same
/// three lines rewritten in the test — which passed happily when the escaping
/// was removed from the code, because the test was not calling the code.
pub fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);

    // The quotes are this caller's job: `appendJsonEscaped` escapes the
    // contents and writes no delimiters.
    try payload.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &payload, text);
    try payload.append(allocator, '"');

    return payload.toOwnedSlice(allocator);
}

// =============================================================================
// getCalendarEvents
// =============================================================================
//
// The column names are literals rather than static field reads, and that is
// the faithful choice rather than the lazy one: `CalendarContract.Events.TITLE`
// is `public static final String TITLE = "title"`, a compile-time constant, so
// javac folds it into the shim's DEX. The shim never reads those fields at
// runtime either. `CONTENT_URI` is a `Uri` object and so is read through JNI,
// the way `deleteEvent` reads it.

const col_id = "_id";
const col_title = "title";
const col_description = "description";
const col_dtstart = "dtstart";
const col_dtend = "dtend";
const col_event_location = "eventLocation";
const col_all_day = "allDay";

/// The projection, in the order the shim lists it — which is also the order
/// the cursor indices below depend on.
const projection = [_][:0]const u8{
    col_id,
    col_title,
    col_description,
    col_dtstart,
    col_dtend,
    col_event_location,
    col_all_day,
};

const selection = "(" ++ col_dtstart ++ " >= ?) AND (" ++ col_dtstart ++ " <= ?)";
const sort_order = col_dtstart ++ " ASC";

/// Thirty days, the shim's default window: `30L * 24 * 60 * 60 * 1000`.
const thirty_days_ms: i64 = 30 * 24 * 60 * 60 * 1000;

pub const Window = struct { start: i64, end: i64 };

/// The shim's defaulting, including the arithmetic that can wrap.
///
/// `startTime + (30L * 24 * 60 * 60 * 1000)` is Kotlin `Long` addition, which
/// wraps silently rather than throwing — so `+%` is the faithful operator and
/// `+` would panic in a debug build where the shim quietly returns nothing.
pub fn windowFor(start_ms: i64, end_ms: i64, now_ms: i64) Window {
    const start = if (start_ms > 0) start_ms else now_ms;
    return .{
        .start = start,
        // A caller passing an end before the start gets an empty result rather
        // than an error, because that is what the query does. Not corrected
        // here: the shim does not correct it either.
        .end = if (end_ms > 0) end_ms else start +% thirty_days_ms,
    };
}

/// One row, as the cursor gives it.
///
/// The strings are optional because `Cursor.getString` returns null for a null
/// column, and the shim treats that differently per field — `?: ""` for five of
/// them, and nothing at all for the id.
pub const Event = struct {
    id: ?[]const u8,
    title: ?[]const u8,
    notes: ?[]const u8,
    start_date: i64,
    end_date: i64,
    location: ?[]const u8,
    all_day: i32,
};

/// One event as the shim's `JSONObject` would print it.
///
/// Two behaviours here are `org.json`'s rather than anything chosen:
///
///  - `put(name, null)` **removes** the mapping, so a null id leaves the key
///    out of the object entirely rather than emitting `"id":null`;
///  - insertion order is preserved, because `JSONObject` is backed by a
///    `LinkedHashMap` — so the key order is the order of the shim's `apply`
///    block and not alphabetical.
pub fn appendEvent(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), event: Event) !void {
    try out.append(allocator, '{');

    if (event.id) |id| {
        try appendStringMember(allocator, out, "id", id);
        try out.append(allocator, ',');
    }
    try appendStringMember(allocator, out, "title", event.title orelse "");
    try out.append(allocator, ',');
    try appendStringMember(allocator, out, "notes", event.notes orelse "");
    try out.append(allocator, ',');
    try out.appendSlice(allocator, "\"startDate\":");
    try appendInt(allocator, out, event.start_date);
    try out.appendSlice(allocator, ",\"endDate\":");
    try appendInt(allocator, out, event.end_date);
    try out.append(allocator, ',');
    try appendStringMember(allocator, out, "location", event.location orelse "");

    // `it.getInt(6) == 1`, so 0 and 2 are both false. Reproduced rather than
    // relaxed to `!= 0`: `allDay` is only ever 0 or 1, and a bridge that
    // disagreed with the shim about a third value would disagree silently.
    try out.appendSlice(allocator, ",\"isAllDay\":");
    try out.appendSlice(allocator, if (event.all_day == 1) "true" else "false");

    try out.append(allocator, '}');
}

fn appendStringMember(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    value: []const u8,
) !void {
    try out.append(allocator, '"');
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\":\"");
    try bridge_error.appendJsonEscaped(allocator, out, value);
    try out.append(allocator, '"');
}

fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: i64) !void {
    var buf: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{value}));
}

/// `Long.toString(value)` as a NUL-terminated string, for `NewStringUTF`.
///
/// Decimal with a leading `-` and nothing else, which is what `Long.toString`
/// produces and what the provider parses back out of a selection argument.
fn decimalZ(buf: []u8, value: i64) ![*:0]const u8 {
    const text = try std.fmt.bufPrint(buf[0 .. buf.len - 1], "{d}", .{value});
    buf[text.len] = 0;
    return @ptrCast(text.ptr);
}

/// `System.currentTimeMillis()`.
///
/// Through JNI rather than a host clock, because it is what the shim's default
/// window is measured from — and because `std.time` on this toolchain has no
/// wall-clock call that works without libc. Belongs in a shared Android helper
/// the moment a second action needs it.
pub fn currentTimeMillis(j: Jni) !i64 {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    const system_cls = try j.findClass("java/lang/System");
    return j.callStaticLongMethodA(
        system_cls,
        try j.staticMethodId(system_cls, "currentTimeMillis", "()J"),
        &.{},
    );
}

/// `contentResolver.query(...)`, every row appended to `out` as JSON.
///
/// `out` receives the array including its brackets, so a query returning no
/// cursor at all produces `[]` — which is what `cursor?.use` does in the shim
/// when the provider hands back null.
pub fn queryEvents(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    window: Window,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    try j.pushLocalFrame(24);
    defer _ = j.popLocalFrame(null);

    const string_cls = try j.findClass("java/lang/String");

    const projection_array = try j.newObjectArray(projection.len, string_cls);
    inline for (projection, 0..) |name, i| {
        try j.setObjectArrayElement(projection_array, i, try j.newStringUtf(name));
    }

    // `startTime.toString()` — `Long.toString`, which is decimal with a
    // leading `-` and nothing else, so `bufPrintIntToSlice` matches it.
    var start_buf: [24]u8 = undefined;
    var end_buf: [24]u8 = undefined;
    const args_array = try j.newObjectArray(2, string_cls);
    try j.setObjectArrayElement(args_array, 0, try j.newStringUtf(try decimalZ(&start_buf, window.start)));
    try j.setObjectArrayElement(args_array, 1, try j.newStringUtf(try decimalZ(&end_buf, window.end)));

    const events_cls = try j.findClass("android/provider/CalendarContract$Events");
    const content_uri = try j.staticObjectField(
        events_cls,
        try j.staticFieldId(events_cls, "CONTENT_URI", "Landroid/net/Uri;"),
    );

    const activity_cls = try j.objectClass(activity);
    const resolver = try j.callObjectMethod(
        activity,
        try j.methodId(activity_cls, "getContentResolver", "()Landroid/content/ContentResolver;"),
    );

    const resolver_cls = try j.objectClass(resolver);
    const cursor = try j.callObjectMethodA(
        resolver,
        try j.methodId(
            resolver_cls,
            "query",
            "(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;)Landroid/database/Cursor;",
        ),
        &.{
            .{ .l = content_uri },
            .{ .l = projection_array },
            .{ .l = try j.newStringUtf(selection) },
            .{ .l = args_array },
            .{ .l = try j.newStringUtf(sort_order) },
        },
    );

    try out.append(allocator, '[');
    defer out.append(allocator, ']') catch {};

    // A provider that cannot answer returns null rather than an empty cursor,
    // and `cursor?.use` skips the loop. An empty array is the honest reply:
    // the shim resolves with one too.
    if (cursor == null) return;

    const cursor_cls = try j.objectClass(cursor);
    const move_to_next = try j.methodId(cursor_cls, "moveToNext", "()Z");
    const get_string = try j.methodId(cursor_cls, "getString", "(I)Ljava/lang/String;");
    const get_long = try j.methodId(cursor_cls, "getLong", "(I)J");
    const get_int = try j.methodId(cursor_cls, "getInt", "(I)I");
    const close = try j.methodId(cursor_cls, "close", "()V");

    // `use` closes the cursor however the block leaves — including on the way
    // out of an error, which is what leaks a provider connection otherwise.
    defer j.callVoidMethodA(cursor, close, &.{}) catch {};

    var count: usize = 0;
    while (try j.callBooleanMethodA(cursor, move_to_next, &.{})) {
        // Each row's strings are local references, and the JVM guarantees only
        // sixteen slots. A frame per row is what keeps a long calendar from
        // overflowing the table, which aborts the process rather than throwing.
        try j.pushLocalFrame(8);
        defer _ = j.popLocalFrame(null);

        const event: Event = .{
            .id = try columnText(j, allocator, cursor, get_string, 0),
            .title = try columnText(j, allocator, cursor, get_string, 1),
            .notes = try columnText(j, allocator, cursor, get_string, 2),
            .start_date = try j.callLongMethodA(cursor, get_long, &.{.{ .i = 3 }}),
            .end_date = try j.callLongMethodA(cursor, get_long, &.{.{ .i = 4 }}),
            .location = try columnText(j, allocator, cursor, get_string, 5),
            .all_day = try j.callIntMethodA(cursor, get_int, &.{.{ .i = 6 }}),
        };

        if (count != 0) try out.append(allocator, ',');
        try appendEvent(allocator, out, event);
        count += 1;
    }
}

/// `cursor.getString(index)`, null included.
///
/// The allocation outlives the row's local frame because `stringToUtf8` copies
/// into `allocator` — the `jstring` itself does not.
fn columnText(
    j: Jni,
    allocator: std.mem.Allocator,
    cursor: jobject,
    get_string: jni.jmethodID,
    index: i32,
) !?[]const u8 {
    const value = try j.callObjectMethodA(cursor, get_string, &.{.{ .i = index }});
    if (value == null) return null;
    return try j.stringToUtf8(allocator, value);
}

// =============================================================================
// createCalendarEvent
// =============================================================================
//
// ## Which payloads this serves, and which it hands back
//
// The shim reads the event through `org.json`, whose accessors coerce: a
// `startDate` sent as the string "1700000000000" is a number to `optLong`, a
// `title` sent as `1.5` is the string "1.5" to `optString`, and reproducing
// `Double.toString` exactly is not something to guess at.
//
// So the rule here is narrow and stated rather than approximated: Zig serves
// the shape `NewCalendarEvent` declares — strings for the text, numbers for
// the dates, a boolean for the flag — plus absent keys and explicit nulls. A
// payload of any other shape makes `parseNewEvent` return null, the native
// returns false, and the shim reads it with the coercions it already has. The
// page sees no difference; nothing has been settled at that point.
//
// The one coercion that *is* reproduced is the surprising one. `optString` on
// an explicit JSON null returns the four characters "null", because
// `JSONObject.NULL.toString()` is "null" and `JSON.toString` reaches for
// `toString` on anything that is not already a String. `{"location":null}` is
// an ordinary thing for `JSON.stringify` to produce, so this is a live path
// and not a curiosity.

/// `CalendarContract.Events.CALENDAR_ID`, `EVENT_TIMEZONE` — the two columns
/// the shim fills without being asked.
const col_calendar_id = "calendar_id";
const col_event_timezone = "eventTimezone";

/// The shim writes calendar 1 unconditionally.
///
/// Not the primary calendar, not the first visible one — the row whose `_id`
/// is 1, whatever that happens to be on the device. Reproduced because it is
/// what the shim does, and because an event landing in a different calendar
/// than before would be a behaviour change nobody asked for.
const default_calendar_id: i32 = 1;

/// The event to insert, in the shape `NewCalendarEvent` declares.
pub const NewEvent = struct {
    title: []const u8,
    notes: []const u8,
    location: []const u8,
    start_date: i64,
    end_date: i64,
    all_day: bool,
};

/// Read the declared shape, or null where only `org.json`'s coercions would.
///
/// `default_start` and `default_end` are the shim's two separate
/// `System.currentTimeMillis()` calls — separate because Kotlin evaluates each
/// argument as its `put` runs, so the default end really can be a millisecond
/// more than `start + 3600000`.
pub fn parseNewEvent(value: std.json.Value, default_start: i64, default_end: i64) ?NewEvent {
    const object = switch (value) {
        .object => |o| o,
        else => return null,
    };

    return .{
        .title = optString(object, "title") orelse return null,
        .notes = optString(object, "notes") orelse return null,
        .location = optString(object, "location") orelse return null,
        .start_date = optLong(object, "startDate", default_start) orelse return null,
        .end_date = optLong(object, "endDate", default_end) orelse return null,
        .all_day = optBoolean(object, "isAllDay") orelse return null,
    };
}

/// `event.optString(name, "")`, for the shapes this serves.
///
/// Outer null means "a shape the shim would coerce and this will not".
fn optString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return "";
    return switch (value) {
        .string => |text| text,
        // `JSONObject.NULL.toString()`. Not a typo and not a fallback: the
        // shim really does store the four characters.
        .null => "null",
        else => null,
    };
}

/// `event.optLong(name, fallback)`, for the shapes this serves.
fn optLong(object: std.json.ObjectMap, name: []const u8, fallback: i64) ?i64 {
    const value = object.get(name) orelse return fallback;
    return switch (value) {
        .integer => |n| n,
        // `JSON.toLong(NULL)` is null, so the fallback wins — unlike
        // `optString`, where the same null becomes text.
        .null => fallback,
        else => null,
    };
}

/// `event.optBoolean(name, false)`, for the shapes this serves.
fn optBoolean(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return false;
    return switch (value) {
        .bool => |b| b,
        .null => false,
        else => null,
    };
}

/// `contentResolver.insert(Events.CONTENT_URI, values)`, and the id it lands at.
///
/// Returns `uri?.lastPathSegment ?: ""` — so a provider that refuses the insert
/// resolves the page's promise with an empty string rather than rejecting,
/// which is the shim's answer and not an improvement on it.
pub fn insertEvent(j: Jni, allocator: std.mem.Allocator, activity: jobject, event: NewEvent) ![]u8 {
    try j.pushLocalFrame(32);
    defer _ = j.popLocalFrame(null);

    const values_cls = try j.findClass("android/content/ContentValues");
    const values = try j.newObjectA(values_cls, try j.methodId(values_cls, "<init>", "()V"), &.{});

    // `ContentValues.put` is overloaded on the *boxed* types, so each number
    // has to be boxed before it can be put.
    const put_string = try j.methodId(values_cls, "put", "(Ljava/lang/String;Ljava/lang/String;)V");
    const put_long = try j.methodId(values_cls, "put", "(Ljava/lang/String;Ljava/lang/Long;)V");
    const put_int = try j.methodId(values_cls, "put", "(Ljava/lang/String;Ljava/lang/Integer;)V");

    try putString(j, allocator, values, put_string, col_title, event.title);
    try putString(j, allocator, values, put_string, col_description, event.notes);
    try putString(j, allocator, values, put_string, col_event_location, event.location);
    try putLong(j, values, put_long, col_dtstart, event.start_date);
    try putLong(j, values, put_long, col_dtend, event.end_date);
    try putInt(j, values, put_int, col_all_day, if (event.all_day) 1 else 0);
    try putInt(j, values, put_int, col_calendar_id, default_calendar_id);

    // `TimeZone.getDefault().id`. The provider needs one, and an event
    // inserted without it reads back at the wrong hour.
    const timezone_cls = try j.findClass("java/util/TimeZone");
    const timezone = try j.callStaticObjectMethodA(
        timezone_cls,
        try j.staticMethodId(timezone_cls, "getDefault", "()Ljava/util/TimeZone;"),
        &.{},
    );
    const timezone_id = try j.callObjectMethod(
        timezone,
        try j.methodId(try j.objectClass(timezone), "getID", "()Ljava/lang/String;"),
    );
    try j.callVoidMethodA(values, put_string, &.{
        .{ .l = try j.newStringUtf(col_event_timezone) },
        .{ .l = timezone_id },
    });

    const events_cls = try j.findClass("android/provider/CalendarContract$Events");
    const content_uri = try j.staticObjectField(
        events_cls,
        try j.staticFieldId(events_cls, "CONTENT_URI", "Landroid/net/Uri;"),
    );

    const activity_cls = try j.objectClass(activity);
    const resolver = try j.callObjectMethod(
        activity,
        try j.methodId(activity_cls, "getContentResolver", "()Landroid/content/ContentResolver;"),
    );

    const uri = try j.callObjectMethodA(
        resolver,
        try j.methodId(
            try j.objectClass(resolver),
            "insert",
            "(Landroid/net/Uri;Landroid/content/ContentValues;)Landroid/net/Uri;",
        ),
        &.{ .{ .l = content_uri }, .{ .l = values } },
    );

    if (uri == null) return allocator.dupe(u8, "");

    const segment = try j.callObjectMethod(
        uri,
        try j.methodId(try j.objectClass(uri), "getLastPathSegment", "()Ljava/lang/String;"),
    );
    if (segment == null) return allocator.dupe(u8, "");
    return j.stringToUtf8(allocator, segment);
}

fn putString(
    j: Jni,
    allocator: std.mem.Allocator,
    values: jobject,
    put: jni.jmethodID,
    column: [:0]const u8,
    text: []const u8,
) !void {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    // `NewStringUTF` needs a NUL terminator, and a title is arbitrary page
    // text — so it is copied rather than pointed at.
    const terminated = try allocator.allocSentinel(u8, text.len, 0);
    defer allocator.free(terminated);
    @memcpy(terminated, text);

    try j.callVoidMethodA(values, put, &.{
        .{ .l = try j.newStringUtf(column) },
        .{ .l = try j.newStringUtf(terminated.ptr) },
    });
}

fn putLong(j: Jni, values: jobject, put: jni.jmethodID, column: [:0]const u8, value: i64) !void {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    const long_cls = try j.findClass("java/lang/Long");
    const boxed = try j.callStaticObjectMethodA(
        long_cls,
        try j.staticMethodId(long_cls, "valueOf", "(J)Ljava/lang/Long;"),
        &.{.{ .j = value }},
    );
    try j.callVoidMethodA(values, put, &.{ .{ .l = try j.newStringUtf(column) }, .{ .l = boxed } });
}

fn putInt(j: Jni, values: jobject, put: jni.jmethodID, column: [:0]const u8, value: i32) !void {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    const integer_cls = try j.findClass("java/lang/Integer");
    const boxed = try j.callStaticObjectMethodA(
        integer_cls,
        try j.staticMethodId(integer_cls, "valueOf", "(I)Ljava/lang/Integer;"),
        &.{.{ .i = value }},
    );
    try j.callVoidMethodA(values, put, &.{ .{ .l = try j.newStringUtf(column) }, .{ .l = boxed } });
}

/// `message` as a JSON string, for whichever reject global the caller owns.
pub fn rejectOn(allocator: std.mem.Allocator, global: []const u8, message: []const u8) !void {
    const payload = try jsonString(allocator, message);
    defer allocator.free(payload);
    try events.settle(allocator, global, payload);
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
    const payload = try jsonString(testing.allocator, "For input string: \"1'x\"");
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

test "an absent window falls back the way the shim's does" {
    const now: i64 = 1_700_000_000_000;

    // Both supplied: used as given, including an end before the start. The
    // shim does not correct that and neither does this.
    try testing.expectEqual(Window{ .start = 10, .end = 20 }, windowFor(10, 20, now));
    try testing.expectEqual(Window{ .start = 30, .end = 20 }, windowFor(30, 20, now));

    // `if (startDateMs > 0)` — zero and negative both mean "now", which is why
    // this is not `>= 0`.
    try testing.expectEqual(now, windowFor(0, 20, now).start);
    try testing.expectEqual(now, windowFor(-1, 20, now).start);

    // Thirty days, in milliseconds.
    try testing.expectEqual(now + 2_592_000_000, windowFor(0, 0, now).end);
    try testing.expectEqual(@as(i64, 10 + 2_592_000_000), windowFor(10, 0, now).end);
}

test "a window whose default end overflows wraps rather than trapping" {
    // Kotlin `Long` addition wraps. A page passing a start near Long.MAX_VALUE
    // gets a nonsensical window and an empty result from the shim; a `+` here
    // would instead panic in a debug build, which is a different bug.
    const near_max: i64 = std.math.maxInt(i64) - 5;
    try testing.expectEqual(near_max +% 2_592_000_000, windowFor(near_max, 0, 0).end);
}

fn renderEvents(events_in: []const Event) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try out.append(testing.allocator, '[');
    for (events_in, 0..) |event, i| {
        if (i != 0) try out.append(testing.allocator, ',');
        try appendEvent(testing.allocator, &out, event);
    }
    try out.append(testing.allocator, ']');
    return out.toOwnedSlice(testing.allocator);
}

const sample: Event = .{
    .id = "17",
    .title = "Standup",
    .notes = "",
    .start_date = 1_700_000_000_000,
    .end_date = 1_700_000_900_000,
    .location = "Room 2",
    .all_day = 0,
};

test "an event prints the keys the shim's JSONObject prints, in that order" {
    const json = try renderEvents(&.{sample});
    defer testing.allocator.free(json);

    // JSONObject is a LinkedHashMap, so the shim emits insertion order — the
    // order of its `apply` block. Asserted as a whole string rather than key
    // by key, because the order is the part that a rewrite would lose.
    try testing.expectEqualStrings(
        \\[{"id":"17","title":"Standup","notes":"","startDate":1700000000000,"endDate":1700000900000,"location":"Room 2","isAllDay":false}]
    , json);
}

test "a null id leaves the key out, and null text becomes empty" {
    // `put(name, null)` removes the mapping rather than storing JSON null, so
    // the shim's object has no `id` at all. The other five columns are read
    // with `?: ""`, which is a different answer to the same null.
    const json = try renderEvents(&.{.{
        .id = null,
        .title = null,
        .notes = null,
        .start_date = 0,
        .end_date = 0,
        .location = null,
        .all_day = 1,
    }});
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\[{"title":"","notes":"","startDate":0,"endDate":0,"location":"","isAllDay":true}]
    , json);
}

test "isAllDay is the shim's == 1 and not a truthiness test" {
    for ([_]struct { value: i32, expected: []const u8 }{
        .{ .value = 0, .expected = "\"isAllDay\":false" },
        .{ .value = 1, .expected = "\"isAllDay\":true" },
        // `getInt(6) == 1` says false here, and a `!= 0` would say true. The
        // column only ever holds 0 or 1, so this row is the one that would go
        // unnoticed — which is why it is written down.
        .{ .value = 2, .expected = "\"isAllDay\":false" },
        .{ .value = -1, .expected = "\"isAllDay\":false" },
    }) |case| {
        var event = sample;
        event.all_day = case.value;
        const json = try renderEvents(&.{event});
        defer testing.allocator.free(json);

        try testing.expect(std.mem.indexOf(u8, json, case.expected) != null);
    }
}

test "a title carrying a quote survives as JSON rather than breaking the reply" {
    // The payload goes to `events.settle`, which sends it as written. An event
    // called `Bob's "1:1"` is ordinary, and it is exactly what an unescaped
    // build would turn into a script that does not parse.
    var event = sample;
    event.title = "Bob's \"1:1\"";
    event.location = "line\nbreak";

    const json = try renderEvents(&.{event});
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const first = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("Bob's \"1:1\"", first.get("title").?.string);
    try testing.expectEqualStrings("line\nbreak", first.get("location").?.string);
    try testing.expect(first.get("id") != null);
}

test "an empty calendar and a full one both parse" {
    const empty = try renderEvents(&.{});
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("[]", empty);

    var second = sample;
    second.id = "18";
    const two = try renderEvents(&.{ sample, second });
    defer testing.allocator.free(two);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, two, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}

test "the query strings are the shim's, character for character" {
    // The selection and sort order are built from the same column constants
    // the projection uses, so a typo would have to be in one place. Asserted
    // against literals anyway: these are what the provider parses, and the
    // constants they are built from are not independently checked.
    try testing.expectEqualStrings("(dtstart >= ?) AND (dtstart <= ?)", selection);
    try testing.expectEqualStrings("dtstart ASC", sort_order);
    try testing.expectEqual(@as(usize, 7), projection.len);
    try testing.expectEqualStrings("_id", projection[0]);
    try testing.expectEqualStrings("eventLocation", projection[5]);
    try testing.expectEqualStrings("allDay", projection[6]);
}

test "getCalendarEvents names its action and globals as the shim does" {
    try testing.expectEqualStrings("getCalendarEvents", A.get_calendar_events);
    try testing.expectEqualStrings("_craftCalendarResolve", list_resolve_global);
    try testing.expectEqualStrings("_craftCalendarReject", list_reject_global);
}

// --- createCalendarEvent ---------------------------------------------------

fn parseEvent(json: []const u8, default_start: i64, default_end: i64) !?NewEvent {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    // The strings borrow from `parsed`, so anything a caller keeps has to be
    // read before this returns. Every test below asserts inside its own call.
    const event = parseNewEvent(parsed.value, default_start, default_end) orelse return null;
    return NewEvent{
        .title = try testing.allocator.dupe(u8, event.title),
        .notes = try testing.allocator.dupe(u8, event.notes),
        .location = try testing.allocator.dupe(u8, event.location),
        .start_date = event.start_date,
        .end_date = event.end_date,
        .all_day = event.all_day,
    };
}

fn freeEvent(event: NewEvent) void {
    testing.allocator.free(event.title);
    testing.allocator.free(event.notes);
    testing.allocator.free(event.location);
}

test "the declared shape reads straight through" {
    const event = (try parseEvent(
        \\{"title":"Standup","notes":"daily","location":"Room 2",
        \\ "startDate":1700000000000,"endDate":1700000900000,"isAllDay":false}
    , 1, 2)).?;
    defer freeEvent(event);

    try testing.expectEqualStrings("Standup", event.title);
    try testing.expectEqualStrings("daily", event.notes);
    try testing.expectEqualStrings("Room 2", event.location);
    try testing.expectEqual(@as(i64, 1700000000000), event.start_date);
    try testing.expectEqual(@as(i64, 1700000900000), event.end_date);
    try testing.expect(!event.all_day);
}

test "absent keys take the shim's defaults" {
    // `optString(name, "")`, `optLong(name, now)`, `optBoolean(name, false)`.
    // The two date defaults are separate arguments because the shim calls
    // System.currentTimeMillis() twice, once per put.
    const event = (try parseEvent("{}", 111, 222)).?;
    defer freeEvent(event);

    try testing.expectEqualStrings("", event.title);
    try testing.expectEqualStrings("", event.notes);
    try testing.expectEqualStrings("", event.location);
    try testing.expectEqual(@as(i64, 111), event.start_date);
    try testing.expectEqual(@as(i64, 222), event.end_date);
    try testing.expect(!event.all_day);
}

test "an explicit null is text to optString and a fallback to optLong" {
    // The org.json quirk, and the reason it is worth a test rather than a
    // comment: `JSONObject.NULL.toString()` is "null", so `optString` hands
    // back four characters where every other accessor hands back the default.
    // `JSON.stringify({location: null})` produces this every day.
    const event = (try parseEvent(
        \\{"title":null,"notes":null,"location":null,"startDate":null,"endDate":null,"isAllDay":null}
    , 111, 222)).?;
    defer freeEvent(event);

    try testing.expectEqualStrings("null", event.title);
    try testing.expectEqualStrings("null", event.notes);
    try testing.expectEqualStrings("null", event.location);
    try testing.expectEqual(@as(i64, 111), event.start_date);
    try testing.expectEqual(@as(i64, 222), event.end_date);
    try testing.expect(!event.all_day);
}

test "a shape only org.json would coerce is handed back rather than guessed at" {
    // Each of these is something `optString`/`optLong`/`optBoolean` reads
    // happily and this does not. Returning null sends the native down its
    // false path, the shim reads it, and the page cannot tell — which is the
    // whole reason the rule can be this narrow.
    for ([_][]const u8{
        // A number where NewCalendarEvent declares a string: optString would
        // give "1.5", and reproducing Double.toString is not a guess to make.
        \\{"title":1.5}
        ,
        \\{"title":7}
        ,
        \\{"location":true}
        ,
        // A string where it declares a number: optLong parses it as a double
        // and truncates, so "1.9" is 1.
        \\{"startDate":"1700000000000"}
        ,
        \\{"endDate":"1.9"}
        ,
        // A float where it declares a number: optLong truncates toward zero.
        \\{"startDate":1.9}
        ,
        // optBoolean reads "true" and "false" case-insensitively.
        \\{"isAllDay":"true"}
        ,
        \\{"isAllDay":1}
        ,
        // Not an object at all.
        \\[]
        ,
        \\"title"
        ,
    }) |payload| {
        const event = try parseEvent(payload, 1, 2);
        if (event) |kept| {
            freeEvent(kept);
            std.debug.print("payload was served rather than handed back: {s}\n", .{payload});
            return error.CoercedShapeAccepted;
        }
    }
}

test "the columns createCalendarEvent fills are the shim's" {
    try testing.expectEqualStrings("calendar_id", col_calendar_id);
    try testing.expectEqualStrings("eventTimezone", col_event_timezone);

    // The shim writes calendar 1 unconditionally — not the primary calendar,
    // the row whose _id is 1. Written down because it looks like a bug and is
    // instead a faithful port of one.
    try testing.expectEqual(@as(i32, 1), default_calendar_id);
}

test "createCalendarEvent names its action and globals as the shim does" {
    try testing.expectEqualStrings("createCalendarEvent", A.create_calendar_event);
    try testing.expectEqualStrings("_craftCreateEventResolve", create_resolve_global);
    try testing.expectEqualStrings("_craftCreateEventReject", create_reject_global);
}

test "an id carrying a quote resolves as JSON rather than breaking the reply" {
    // `uri.lastPathSegment` is provider-controlled text, and it goes to the
    // page through the same channel a rejection does.
    const payload = try jsonString(testing.allocator, "17'x");
    defer testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("17'x", parsed.value.string);
}
