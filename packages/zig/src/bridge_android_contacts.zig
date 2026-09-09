//! `getContacts` on Android.
//!
//! ## The column names are literals, and that is the faithful choice
//!
//! `ContactsContract.Contacts.DISPLAY_NAME` and its neighbours are
//! `public static final String` — compile-time constants, so javac folds them
//! into the shim's DEX and the shim never reads those fields at runtime
//! either. The `CONTENT_URI`s are `Uri` objects and so are still read through
//! JNI, the same split the calendar module makes.
//!
//! Two of them are the same string and it is not a mistake: `Phone.NUMBER` and
//! `Email.ADDRESS` are both `DATA1`, because a data row's meaning comes from
//! its MIMETYPE and the generic `data1` column holds whichever value that row
//! is. Writing "data1" twice is what the shim compiles to.
//!
//! ## One query per contact, twice over
//!
//! The shim runs a query for the contact list and then two more *per contact*,
//! one for phones and one for emails, each on the JavaBridge thread. A device
//! with two thousand contacts makes four thousand and one queries for a single
//! `craft.contacts.getAll()`. Reproduced rather than improved: the same rows
//! could be fetched in three queries and grouped, but that changes what a
//! concurrent edit to the address book produces, and this port is meant to be
//! auditable against the Kotlin line by line. See #165.
//!
//! ## A null is not the same absence twice
//!
//! `put("id", id)` with a null **removes** the key, so a contact with no `_id`
//! arrives without one. `put("displayName", name ?: "")` turns the same null
//! into an empty string. And a null phone number is appended to its array as a
//! JSON `null`, because `JSONArray.put` stores it and `JSONStringer` writes it
//! out. Three different answers to the same missing value, all of them the
//! shim's.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const get_contacts = "getContacts";
};

pub const resolve_global = "_craftContactsResolve";
pub const reject_global = "_craftContactsReject";

const col_id = "_id";
const col_display_name = "display_name";

/// `Phone.CONTACT_ID` and `Email.CONTACT_ID`, the join back to the contact.
const col_contact_id = "contact_id";

/// `Phone.NUMBER` and `Email.ADDRESS`, both of which are `DATA1`.
const col_data1 = "data1";

const contacts_sort_order = col_display_name ++ " ASC";
const data_selection = col_contact_id ++ " = ?";

/// One contact, as the two cursors give it.
pub const Contact = struct {
    id: ?[]const u8,
    display_name: ?[]const u8,
    phone_numbers: []const ?[]const u8,
    email_addresses: []const ?[]const u8,
};

/// One contact as the shim's `JSONObject` would print it.
pub fn appendContact(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    contact: Contact,
) !void {
    try out.append(allocator, '{');

    // `put("id", null)` removes the mapping, so a null id is an absent key
    // rather than a JSON null — and the comma has to go with it.
    if (contact.id) |id| {
        try appendStringMember(allocator, out, "id", id);
        try out.append(allocator, ',');
    }

    // `?: ""` — the same null, answered differently one line later.
    try appendStringMember(allocator, out, "displayName", contact.display_name orelse "");

    try out.appendSlice(allocator, ",\"phoneNumbers\":");
    try appendStrings(allocator, out, contact.phone_numbers);
    try out.appendSlice(allocator, ",\"emailAddresses\":");
    try appendStrings(allocator, out, contact.email_addresses);

    try out.append(allocator, '}');
}

/// A `JSONArray` of strings, where a null element is a JSON null.
///
/// `JSONArray.put(Object)` stores the null and `JSONStringer` writes `null`
/// for it, so unlike a `JSONObject` member the element is not dropped — the
/// array keeps its length and the page sees a hole.
fn appendStrings(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    values: []const ?[]const u8,
) !void {
    try out.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i != 0) try out.append(allocator, ',');
        if (value) |text| {
            try out.append(allocator, '"');
            try bridge_error.appendJsonEscaped(allocator, out, text);
            try out.append(allocator, '"');
        } else {
            try out.appendSlice(allocator, "null");
        }
    }
    try out.append(allocator, ']');
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

/// The whole address book, appended to `out` as a JSON array.
pub fn queryContacts(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    try j.pushLocalFrame(24);
    defer _ = j.popLocalFrame(null);

    const resolver = try contentResolver(j, activity);
    const contacts_cls = try j.findClass("android/provider/ContactsContract$Contacts");
    const content_uri = try j.staticObjectField(
        contacts_cls,
        try j.staticFieldId(contacts_cls, "CONTENT_URI", "Landroid/net/Uri;"),
    );

    // `query(uri, null, null, null, "display_name ASC")` — a null projection
    // selects every column of a wide table, which is the shim's call and is
    // half of why #165 exists.
    const cursor = try queryUri(j, allocator, resolver, content_uri, null, null, contacts_sort_order);

    try out.append(allocator, '[');
    defer out.append(allocator, ']') catch {};

    if (cursor == null) return;

    const cursor_cls = try j.objectClass(cursor);
    const move_to_next = try j.methodId(cursor_cls, "moveToNext", "()Z");
    const get_string = try j.methodId(cursor_cls, "getString", "(I)Ljava/lang/String;");
    const close = try j.methodId(cursor_cls, "close", "()V");
    defer j.callVoidMethodA(cursor, close, &.{}) catch {};

    // `getColumnIndexOrThrow` is resolved once rather than per row. The shim
    // calls it inside the loop; the answer cannot change while a cursor is
    // open, and the difference is not observable.
    const id_index = try columnIndex(j, allocator, cursor, col_id);
    const name_index = try columnIndex(j, allocator, cursor, col_display_name);

    var count: usize = 0;
    while (try j.callBooleanMethodA(cursor, move_to_next, &.{})) {
        try j.pushLocalFrame(8);
        defer _ = j.popLocalFrame(null);

        const id = try columnText(j, allocator, cursor, get_string, id_index);
        const name = try columnText(j, allocator, cursor, get_string, name_index);

        // The two extra queries per contact. They need the id as text, and a
        // contact without one cannot be joined to — the shim passes the null
        // straight to `arrayOf(contactId)`, where it becomes a selection
        // argument of null and the provider matches nothing.
        const phones = try relatedValues(j, allocator, resolver, "Phone", id);
        const emails = try relatedValues(j, allocator, resolver, "Email", id);

        if (count != 0) try out.append(allocator, ',');
        try appendContact(allocator, out, .{
            .id = id,
            .display_name = name,
            .phone_numbers = phones,
            .email_addresses = emails,
        });
        count += 1;
    }
}

/// `getContactPhones` / `getContactEmails`, which differ only in the class
/// holding the `CONTENT_URI`.
fn relatedValues(
    j: Jni,
    allocator: std.mem.Allocator,
    resolver: jobject,
    comptime kind: []const u8,
    contact_id: ?[]const u8,
) ![]const ?[]const u8 {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const cls = try j.findClass("android/provider/ContactsContract$CommonDataKinds$" ++ kind);
    const content_uri = try j.staticObjectField(
        cls,
        try j.staticFieldId(cls, "CONTENT_URI", "Landroid/net/Uri;"),
    );

    const args = [_]?[]const u8{contact_id};
    const cursor = try queryUri(j, allocator, resolver, content_uri, data_selection, &args, null);

    var values: std.ArrayListUnmanaged(?[]const u8) = .empty;
    errdefer values.deinit(allocator);

    if (cursor == null) return values.toOwnedSlice(allocator);

    const cursor_cls = try j.objectClass(cursor);
    const move_to_next = try j.methodId(cursor_cls, "moveToNext", "()Z");
    const get_string = try j.methodId(cursor_cls, "getString", "(I)Ljava/lang/String;");
    const close = try j.methodId(cursor_cls, "close", "()V");
    defer j.callVoidMethodA(cursor, close, &.{}) catch {};

    const value_index = try columnIndex(j, allocator, cursor, col_data1);

    while (try j.callBooleanMethodA(cursor, move_to_next, &.{})) {
        try j.pushLocalFrame(8);
        defer _ = j.popLocalFrame(null);
        try values.append(allocator, try columnText(j, allocator, cursor, get_string, value_index));
    }
    return values.toOwnedSlice(allocator);
}

fn contentResolver(j: Jni, activity: jobject) !jobject {
    return j.callObjectMethod(
        activity,
        try j.methodId(
            try j.objectClass(activity),
            "getContentResolver",
            "()Landroid/content/ContentResolver;",
        ),
    );
}

/// `resolver.query(uri, null, selection, selectionArgs, sortOrder)`.
///
/// The projection is always null here because both of the shim's queries pass
/// null; a caller wanting one would pass the array rather than this taking a
/// parameter nothing sets.
fn queryUri(
    j: Jni,
    allocator: std.mem.Allocator,
    resolver: jobject,
    uri: jobject,
    selection: ?[]const u8,
    selection_args: ?[]const ?[]const u8,
    sort_order: ?[]const u8,
) !jobject {
    const args_array: jobject = if (selection_args) |args| blk: {
        const string_cls = try j.findClass("java/lang/String");
        const array = try j.newObjectArray(args.len, string_cls);
        for (args, 0..) |arg, i| {
            // A null argument is a null element, which is what
            // `arrayOf(contactId)` produces when the id was null.
            const value: jni.jstring = if (arg) |text| try javaString(j, allocator, text) else null;
            try j.setObjectArrayElement(array, i, value);
        }
        break :blk array;
    } else null;

    return j.callObjectMethodA(
        resolver,
        try j.methodId(
            try j.objectClass(resolver),
            "query",
            "(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;)Landroid/database/Cursor;",
        ),
        &.{
            .{ .l = uri },
            .{ .l = null },
            .{ .l = if (selection) |text| try javaString(j, allocator, text) else null },
            .{ .l = args_array },
            .{ .l = if (sort_order) |text| try javaString(j, allocator, text) else null },
        },
    );
}

fn columnIndex(j: Jni, allocator: std.mem.Allocator, cursor: jobject, name: []const u8) !i32 {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    return j.callIntMethodA(
        cursor,
        try j.methodId(try j.objectClass(cursor), "getColumnIndexOrThrow", "(Ljava/lang/String;)I"),
        &.{.{ .l = try javaString(j, allocator, name) }},
    );
}

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

fn javaString(j: Jni, allocator: std.mem.Allocator, text: []const u8) !jni.jstring {
    const terminated = try allocator.allocSentinel(u8, text.len, 0);
    defer allocator.free(terminated);
    @memcpy(terminated, text);
    return j.newStringUtf(terminated.ptr);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn renderContacts(contacts: []const Contact) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try out.append(testing.allocator, '[');
    for (contacts, 0..) |contact, i| {
        if (i != 0) try out.append(testing.allocator, ',');
        try appendContact(testing.allocator, &out, contact);
    }
    try out.append(testing.allocator, ']');
    return out.toOwnedSlice(testing.allocator);
}

test "a contact prints the keys the shim's JSONObject prints, in that order" {
    const json = try renderContacts(&.{.{
        .id = "7",
        .display_name = "Ada Lovelace",
        .phone_numbers = &.{ "+441234567890", "555" },
        .email_addresses = &.{"ada@example.com"},
    }});
    defer testing.allocator.free(json);

    // JSONObject is a LinkedHashMap, so this is the order of the shim's
    // `apply` block. Asserted whole, because the order is what a rewrite loses.
    try testing.expectEqualStrings(
        \\[{"id":"7","displayName":"Ada Lovelace","phoneNumbers":["+441234567890","555"],"emailAddresses":["ada@example.com"]}]
    , json);
}

test "a contact with no phones or emails still carries both arrays" {
    // `getContactPhones` always returns a JSONArray, so the keys are present
    // and empty rather than missing — a page can iterate without checking.
    const json = try renderContacts(&.{.{
        .id = "7",
        .display_name = "Nobody",
        .phone_numbers = &.{},
        .email_addresses = &.{},
    }});
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\[{"id":"7","displayName":"Nobody","phoneNumbers":[],"emailAddresses":[]}]
    , json);
}

test "the same null is answered three different ways" {
    // `put("id", null)` removes the key; `?: ""` makes the name empty; and a
    // null array element is written as JSON null rather than dropped, so the
    // array keeps its length.
    const json = try renderContacts(&.{.{
        .id = null,
        .display_name = null,
        .phone_numbers = &.{ null, "555" },
        .email_addresses = &.{null},
    }});
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\[{"displayName":"","phoneNumbers":[null,"555"],"emailAddresses":[null]}]
    , json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const first = parsed.value.array.items[0].object;
    try testing.expect(first.get("id") == null);
    try testing.expectEqual(@as(usize, 2), first.get("phoneNumbers").?.array.items.len);
}

test "a name or number carrying a quote survives as JSON" {
    // Contact names are arbitrary user text and go to the page through the
    // reply channel — the shape that hung the promise before #154.
    const json = try renderContacts(&.{.{
        .id = "it's",
        .display_name = "O'Brien \"Bob\"",
        .phone_numbers = &.{"+1 (555) \"x\""},
        .email_addresses = &.{"a\nb@example.com"},
    }});
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const first = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("it's", first.get("id").?.string);
    try testing.expectEqualStrings("O'Brien \"Bob\"", first.get("displayName").?.string);
    try testing.expectEqualStrings("+1 (555) \"x\"", first.get("phoneNumbers").?.array.items[0].string);
    try testing.expectEqualStrings("a\nb@example.com", first.get("emailAddresses").?.array.items[0].string);
}

test "an empty address book is an empty array" {
    const json = try renderContacts(&.{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("[]", json);
}

test "the query strings are the shim's, character for character" {
    try testing.expectEqualStrings("display_name ASC", contacts_sort_order);
    try testing.expectEqualStrings("contact_id = ?", data_selection);

    // Phone.NUMBER and Email.ADDRESS really are the same column: a data row's
    // meaning comes from its MIMETYPE, and data1 holds whichever value it is.
    try testing.expectEqualStrings("data1", col_data1);
    try testing.expectEqualStrings("_id", col_id);
    try testing.expectEqualStrings("display_name", col_display_name);
}

test "getContacts names its action and globals as the shim does" {
    try testing.expectEqualStrings("getContacts", A.get_contacts);
    try testing.expectEqualStrings("_craftContactsResolve", resolve_global);
    try testing.expectEqualStrings("_craftContactsReject", reject_global);
}
