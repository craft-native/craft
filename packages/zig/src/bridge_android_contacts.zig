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
    pub const add_contact = "addContact";
};

pub const resolve_global = "_craftContactsResolve";
pub const reject_global = "_craftContactsReject";
pub const add_resolve_global = "_craftAddContactResolve";
pub const add_reject_global = "_craftAddContactReject";

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
// addContact
// =============================================================================
//
// ## The MIME types are read, where the column names are written
//
// Every constant elsewhere in this file is a literal, because a wrong column
// name fails loudly — the provider throws or the cursor comes back empty. A
// wrong MIMETYPE does not: `applyBatch` accepts it, the row is written, and it
// simply never shows up as a name or a phone number anywhere. There is no
// error and nothing to notice until someone opens the address book.
//
// So `CONTENT_ITEM_TYPE` is read through JNI. The value is identical to what
// javac folded into the shim, and reading it is one static field access that
// cannot be misremembered.
//
// ## What the batch builds
//
// A raw contact with a null account, then up to three data rows pointing back
// at it by index rather than by id — `withValueBackReference(RAW_CONTACT_ID,
// 0)` means "whatever the first operation inserted", which is the only way to
// reference a row that does not exist yet.
//
// Each data row is skipped when its field is empty, so a contact with no phone
// gets no phone row rather than an empty one.

const col_account_type = "account_type";
const col_account_name = "account_name";
const col_raw_contact_id = "raw_contact_id";
const col_mimetype = "mimetype";

/// `Phone.TYPE` and `Email.TYPE`, both of which are `DATA2`.
const col_data2 = "data2";

/// `Phone.TYPE_MOBILE` and `Email.TYPE_HOME`.
const phone_type_mobile: i32 = 2;
const email_type_home: i32 = 1;

/// `ContactsContract.AUTHORITY`.
const contacts_authority = "com.android.contacts";

/// The three optional fields the shim reads out of the payload.
pub const NewContact = struct {
    display_name: []const u8,
    phone: []const u8,
    email: []const u8,
};

/// Read the declared shape, or null where only `org.json` would.
///
/// The same rule `createCalendarEvent` uses and for the same reason: the shim
/// reads these with `optString`, which coerces a number or a boolean into its
/// string form, and `Double.toString` is not something to reproduce from
/// memory. An explicit null is the one coercion carried over — it becomes the
/// four characters "null", which then passes `isNotEmpty()` and is written to
/// the address book as a contact named "null". That is what the shim does.
pub fn parseNewContact(value: std.json.Value) ?NewContact {
    const object = switch (value) {
        .object => |o| o,
        else => return null,
    };

    return .{
        .display_name = optString(object, "displayName") orelse return null,
        .phone = optString(object, "phone") orelse return null,
        .email = optString(object, "email") orelse return null,
    };
}

fn optString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return "";
    return switch (value) {
        .string => |text| text,
        .null => "null",
        else => null,
    };
}

/// `contentResolver.applyBatch(AUTHORITY, ops)`, and the id it lands at.
///
/// Returns `ContentUris.parseId(results[0].uri!!)`. A batch that produced no
/// result, or a first result with no uri, is the Kotlin's `!!` throwing — an
/// error here, a rejection there, the same outcome for the page.
pub fn addContact(j: Jni, allocator: std.mem.Allocator, activity: jobject, contact: NewContact) !i64 {
    try j.pushLocalFrame(32);
    defer _ = j.popLocalFrame(null);

    const list_cls = try j.findClass("java/util/ArrayList");
    const ops = try j.newObjectA(list_cls, try j.methodId(list_cls, "<init>", "()V"), &.{});
    const add = try j.methodId(list_cls, "add", "(Ljava/lang/Object;)Z");

    const raw_contacts_cls = try j.findClass("android/provider/ContactsContract$RawContacts");
    const raw_uri = try j.staticObjectField(
        raw_contacts_cls,
        try j.staticFieldId(raw_contacts_cls, "CONTENT_URI", "Landroid/net/Uri;"),
    );

    {
        // The raw contact itself, with a null account — a local-only contact,
        // which is what the shim creates.
        try j.pushLocalFrame(8);
        defer _ = j.popLocalFrame(null);

        const builder = try newInsert(j, raw_uri);
        _ = try withValue(j, allocator, builder, col_account_type, null);
        _ = try withValue(j, allocator, builder, col_account_name, null);
        _ = try j.callBooleanMethodA(ops, add, &.{.{ .l = try build(j, builder) }});
    }

    const data_cls = try j.findClass("android/provider/ContactsContract$Data");
    const data_uri = try j.staticObjectField(
        data_cls,
        try j.staticFieldId(data_cls, "CONTENT_URI", "Landroid/net/Uri;"),
    );

    if (contact.display_name.len != 0) {
        try appendDataRow(j, allocator, ops, add, data_uri, "StructuredName", .{
            .value_column = col_data1,
            .value = contact.display_name,
            .type_value = null,
        });
    }

    if (contact.phone.len != 0) {
        try appendDataRow(j, allocator, ops, add, data_uri, "Phone", .{
            .value_column = col_data1,
            .value = contact.phone,
            .type_value = phone_type_mobile,
        });
    }

    if (contact.email.len != 0) {
        try appendDataRow(j, allocator, ops, add, data_uri, "Email", .{
            .value_column = col_data1,
            .value = contact.email,
            .type_value = email_type_home,
        });
    }

    const resolver = try contentResolver(j, activity);
    const results = try j.callObjectMethodA(
        resolver,
        try j.methodId(
            try j.objectClass(resolver),
            "applyBatch",
            "(Ljava/lang/String;Ljava/util/ArrayList;)[Landroid/content/ContentProviderResult;",
        ),
        &.{
            .{ .l = try javaString(j, allocator, contacts_authority) },
            .{ .l = ops },
        },
    );

    if (results == null) return error.BatchProducedNothing;
    if (try j.arrayLength(results) == 0) return error.BatchProducedNothing;

    const first = try j.objectArrayElement(results, 0);
    if (first == null) return error.BatchProducedNothing;

    // `ContentProviderResult.uri` is a public field, not a getter.
    const uri = try j.objectField(
        first,
        try j.fieldId(try j.objectClass(first), "uri", "Landroid/net/Uri;"),
    );
    if (uri == null) return error.BatchProducedNothing;

    const content_uris_cls = try j.findClass("android/content/ContentUris");
    return j.callStaticLongMethodA(
        content_uris_cls,
        try j.staticMethodId(content_uris_cls, "parseId", "(Landroid/net/Uri;)J"),
        &.{.{ .l = uri }},
    );
}

const DataRow = struct {
    value_column: []const u8,
    value: []const u8,
    /// `Phone.TYPE` / `Email.TYPE`, absent for a structured name.
    type_value: ?i32,
};

fn appendDataRow(
    j: Jni,
    allocator: std.mem.Allocator,
    ops: jobject,
    add: jni.jmethodID,
    data_uri: jobject,
    comptime kind: []const u8,
    row: DataRow,
) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    // Comptime, so the class name is a string literal the linker holds rather
    // than something assembled per call.
    const kind_cls = try j.findClass("android/provider/ContactsContract$CommonDataKinds$" ++ kind);
    const item_type = try j.staticObjectField(
        kind_cls,
        try j.staticFieldId(kind_cls, "CONTENT_ITEM_TYPE", "Ljava/lang/String;"),
    );

    const builder = try newInsert(j, data_uri);

    // Index 0 is the raw contact this batch opened with; the row it inserts
    // has no id until the batch runs, so it is referenced by position.
    _ = try j.callObjectMethodA(
        builder,
        try j.methodId(
            try j.objectClass(builder),
            "withValueBackReference",
            "(Ljava/lang/String;I)Landroid/content/ContentProviderOperation$Builder;",
        ),
        &.{ .{ .l = try javaString(j, allocator, col_raw_contact_id) }, .{ .i = 0 } },
    );

    _ = try withValue(j, allocator, builder, col_mimetype, item_type);
    _ = try withValue(j, allocator, builder, row.value_column, try javaString(j, allocator, row.value));

    if (row.type_value) |type_value| {
        const integer_cls = try j.findClass("java/lang/Integer");
        const boxed = try j.callStaticObjectMethodA(
            integer_cls,
            try j.staticMethodId(integer_cls, "valueOf", "(I)Ljava/lang/Integer;"),
            &.{.{ .i = type_value }},
        );
        _ = try withValue(j, allocator, builder, col_data2, boxed);
    }

    _ = try j.callBooleanMethodA(ops, add, &.{.{ .l = try build(j, builder) }});
}

fn newInsert(j: Jni, uri: jobject) !jobject {
    const op_cls = try j.findClass("android/content/ContentProviderOperation");
    return j.callStaticObjectMethodA(
        op_cls,
        try j.staticMethodId(
            op_cls,
            "newInsert",
            "(Landroid/net/Uri;)Landroid/content/ContentProviderOperation$Builder;",
        ),
        &.{.{ .l = uri }},
    );
}

fn withValue(
    j: Jni,
    allocator: std.mem.Allocator,
    builder: jobject,
    column: []const u8,
    value: jobject,
) !jobject {
    return j.callObjectMethodA(
        builder,
        try j.methodId(
            try j.objectClass(builder),
            "withValue",
            "(Ljava/lang/String;Ljava/lang/Object;)Landroid/content/ContentProviderOperation$Builder;",
        ),
        &.{ .{ .l = try javaString(j, allocator, column) }, .{ .l = value } },
    );
}

fn build(j: Jni, builder: jobject) !jobject {
    return j.callObjectMethod(
        builder,
        try j.methodId(
            try j.objectClass(builder),
            "build",
            "()Landroid/content/ContentProviderOperation;",
        ),
    );
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

// --- addContact ------------------------------------------------------------

fn parsedContact(json: []const u8) !?NewContact {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    defer parsed.deinit();

    const contact = parseNewContact(parsed.value) orelse return null;
    return NewContact{
        .display_name = try testing.allocator.dupe(u8, contact.display_name),
        .phone = try testing.allocator.dupe(u8, contact.phone),
        .email = try testing.allocator.dupe(u8, contact.email),
    };
}

fn freeContact(contact: NewContact) void {
    testing.allocator.free(contact.display_name);
    testing.allocator.free(contact.phone);
    testing.allocator.free(contact.email);
}

test "the declared shape reads straight through" {
    const contact = (try parsedContact(
        \\{"displayName":"Ada","phone":"+441234567890","email":"ada@example.com"}
    )).?;
    defer freeContact(contact);

    try testing.expectEqualStrings("Ada", contact.display_name);
    try testing.expectEqualStrings("+441234567890", contact.phone);
    try testing.expectEqualStrings("ada@example.com", contact.email);
}

test "absent fields are empty, and an empty field writes no row" {
    // `optString(name, "")`, and then `if (x.isNotEmpty())` decides whether the
    // batch gets a row at all. An empty phone is not a phone row with an empty
    // number — it is no phone row.
    const contact = (try parsedContact("{}")).?;
    defer freeContact(contact);

    try testing.expectEqualStrings("", contact.display_name);
    try testing.expectEqualStrings("", contact.phone);
    try testing.expectEqualStrings("", contact.email);
}

test "an explicit null becomes a contact named null" {
    // Not a joke and not a rounding: `optString` on JSON null returns the four
    // characters "null", which passes `isNotEmpty()` and is written to the
    // address book. `JSON.stringify({displayName: null})` produces it, and the
    // shim behaves this way today.
    const contact = (try parsedContact(
        \\{"displayName":null}
    )).?;
    defer freeContact(contact);

    try testing.expectEqualStrings("null", contact.display_name);
    try testing.expectEqualStrings("", contact.phone);
}

test "a shape only org.json would coerce is handed back" {
    for ([_][]const u8{
        \\{"displayName":1.5}
        ,
        \\{"phone":447700900000}
        ,
        \\{"email":true}
        ,
        \\[]
        ,
        \\"Ada"
        ,
    }) |payload| {
        if (try parsedContact(payload)) |contact| {
            freeContact(contact);
            std.debug.print("payload was served rather than handed back: {s}\n", .{payload});
            return error.CoercedShapeAccepted;
        }
    }
}

test "the batch's column names and types are the shim's" {
    try testing.expectEqualStrings("account_type", col_account_type);
    try testing.expectEqualStrings("account_name", col_account_name);
    try testing.expectEqualStrings("raw_contact_id", col_raw_contact_id);
    try testing.expectEqualStrings("mimetype", col_mimetype);
    try testing.expectEqualStrings("com.android.contacts", contacts_authority);

    // Phone.TYPE and Email.TYPE are both DATA2, the same way NUMBER and
    // ADDRESS are both DATA1.
    try testing.expectEqualStrings("data2", col_data2);

    // Phone.TYPE_MOBILE and Email.TYPE_HOME. Different numbers in different
    // enumerations that happen to sit in the same column.
    try testing.expectEqual(@as(i32, 2), phone_type_mobile);
    try testing.expectEqual(@as(i32, 1), email_type_home);
}

test "addContact names its action and globals as the shim does" {
    try testing.expectEqualStrings("addContact", A.add_contact);
    try testing.expectEqualStrings("_craftAddContactResolve", add_resolve_global);
    try testing.expectEqualStrings("_craftAddContactReject", add_reject_global);
}
