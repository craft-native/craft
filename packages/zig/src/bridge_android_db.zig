//! `dbExecute` and `dbQuery` on Android.
//!
//! ## The connection stays Kotlin's
//!
//! The shim caches one `SQLiteDatabase` in a field and reuses it, which is
//! what makes `BEGIN` in one call and `COMMIT` in the next work at all. Zig
//! could open its own — `Context.openOrCreateDatabase` hands out a new
//! connection each call — and then a page that mixed a served call with a
//! declined one would have two connections to one file, taking each other's
//! locks for no reason a reader could see.
//!
//! So the database arrives as an argument, the way `SharedPreferences` does
//! for the secure store. The Kotlin opens it, the Kotlin owns it, and Zig
//! borrows it for the length of one call.
//!
//! ## Which parameter shapes this serves
//!
//! The shim turns every parameter into a string with `JSONArray.getString`,
//! which coerces: `1` becomes "1", `true` becomes "true", and an explicit null
//! becomes the four characters "null" — the same `JSONObject.NULL.toString()`
//! quirk the calendar module documents.
//!
//! Those four are reproduced. A float is not, because `Double.toString` picks
//! the shortest form that round-trips and matching it exactly is not something
//! to reproduce from memory; nor is a nested object or array, whose string
//! form is `org.json`'s own printer. Those make `bindArgs` return null, the
//! native returns false, and the shim binds them with the coercions it has.
//!
//! ## A NULL column disappears from its row
//!
//! `row.put(col, cursor.getString(index))` with a null value **removes** the
//! mapping rather than storing a JSON null, so a row with a NULL column comes
//! back with that key missing. It is not a rounding of the truth to say a page
//! cannot tell a NULL column from an absent one — that is what the shim sends.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const db_execute = "dbExecute";
    pub const db_query = "dbQuery";
};

pub const exec_resolve_global = "_craftDbExecResolve";
pub const exec_reject_global = "_craftDbExecReject";
pub const query_resolve_global = "_craftDbQueryResolve";
pub const query_reject_global = "_craftDbQueryReject";

/// What `dbExecute` resolves with, exactly as the shim writes it.
///
/// The 1 is a literal in the Kotlin, not a row count — `execSQL` returns void,
/// so nothing here knows how many rows were touched. A `DELETE` matching
/// nothing reports the same 1 as an `INSERT`. Ported rather than corrected,
/// because correcting it means a different number reaching pages that already
/// read this one. See #159.
pub const exec_result = "{\"rowsAffected\":1}";

/// `Array(params.length()) { params.getString(it) }`, or null to decline.
///
/// Most results borrow from `value`, which has to outlive the JNI calls that
/// bind them; an integer is printed and so is allocated. Nothing is freed
/// individually, because every caller is inside the per-call arena — passing a
/// tracking allocator here reports the printed integers as leaks.
pub fn bindArgs(allocator: std.mem.Allocator, value: std.json.Value) !?[][]const u8 {
    const items = switch (value) {
        .array => |a| a.items,
        // `JSONArray(paramsJson)` throws on anything that is not an array, and
        // the shim's catch rejects. Declining sends it there.
        else => return null,
    };

    const args = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(args);

    for (items, 0..) |item, i| {
        args[i] = switch (item) {
            .string => |text| text,
            .bool => |b| if (b) "true" else "false",
            // `JSONObject.NULL.toString()`. A page sending `[null]` binds the
            // four characters, not SQL NULL — which is worth knowing, and is
            // the shim's behaviour either way.
            .null => "null",
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            // Double.toString, org.json's printer, and a number too large for
            // an i64. Each has an exact answer that is not worth guessing.
            .float, .object, .array, .number_string => {
                allocator.free(args);
                return null;
            },
        };
    }
    return args;
}

/// One row of a query result, as the shim's `JSONObject` would print it.
///
/// A null value removes its key rather than storing a JSON null, so `values`
/// carrying a null emits an object without that column.
pub fn appendRow(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    columns: []const []const u8,
    values: []const ?[]const u8,
) !void {
    std.debug.assert(columns.len == values.len);

    try out.append(allocator, '{');
    var written: usize = 0;
    for (columns, values) |column, value| {
        const text = value orelse continue;
        if (written != 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try bridge_error.appendJsonEscaped(allocator, out, column);
        try out.appendSlice(allocator, "\":\"");
        try bridge_error.appendJsonEscaped(allocator, out, text);
        try out.append(allocator, '"');
        written += 1;
    }
    try out.append(allocator, '}');
}

/// `database.execSQL(sql, args)`.
pub fn execute(j: Jni, allocator: std.mem.Allocator, db: jobject, sql: []const u8, args: []const []const u8) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const bind = try stringArray(j, allocator, args);
    const db_cls = try j.objectClass(db);

    // `execSQL(String, Object[])` — a `String[]` is an `Object[]`, which is
    // what the Kotlin passes too.
    try j.callVoidMethodA(
        db,
        try j.methodId(db_cls, "execSQL", "(Ljava/lang/String;[Ljava/lang/Object;)V"),
        &.{ .{ .l = try j.newStringUtf8(allocator, sql) }, .{ .l = bind } },
    );
}

/// `database.rawQuery(sql, args)`, every row appended to `out` as JSON.
pub fn query(
    j: Jni,
    allocator: std.mem.Allocator,
    db: jobject,
    sql: []const u8,
    args: []const []const u8,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    try j.pushLocalFrame(24);
    defer _ = j.popLocalFrame(null);

    const bind = try stringArray(j, allocator, args);
    const db_cls = try j.objectClass(db);
    const cursor = try j.callObjectMethodA(
        db,
        try j.methodId(
            db_cls,
            "rawQuery",
            "(Ljava/lang/String;[Ljava/lang/String;)Landroid/database/Cursor;",
        ),
        &.{ .{ .l = try j.newStringUtf8(allocator, sql) }, .{ .l = bind } },
    );

    try out.append(allocator, '[');
    defer out.append(allocator, ']') catch {};

    if (cursor == null) return;

    const cursor_cls = try j.objectClass(cursor);
    const move_to_next = try j.methodId(cursor_cls, "moveToNext", "()Z");
    const get_string = try j.methodId(cursor_cls, "getString", "(I)Ljava/lang/String;");
    const close = try j.methodId(cursor_cls, "close", "()V");

    // `use` closes however the block leaves, error included.
    defer j.callVoidMethodA(cursor, close, &.{}) catch {};

    const names = try j.callObjectMethodA(
        cursor,
        try j.methodId(cursor_cls, "getColumnNames", "()[Ljava/lang/String;"),
        &.{},
    );
    const column_count: usize = @intCast(try j.arrayLength(names));

    const columns = try allocator.alloc([]const u8, column_count);
    defer allocator.free(columns);
    for (columns, 0..) |*column, i| {
        const element = try j.objectArrayElement(names, i);
        column.* = if (element == null) "" else try j.stringToUtf8(allocator, element);
    }

    const values = try allocator.alloc(?[]const u8, column_count);
    defer allocator.free(values);

    var row_count: usize = 0;
    while (try j.callBooleanMethodA(cursor, move_to_next, &.{})) {
        // Sixteen local slots is all the JVM guarantees, and a wide table
        // makes one reference per column.
        try j.pushLocalFrame(8);
        defer _ = j.popLocalFrame(null);

        for (values, 0..) |*slot, i| {
            const text = try j.callObjectMethodA(cursor, get_string, &.{.{ .i = @intCast(i) }});
            slot.* = if (text == null) null else try j.stringToUtf8(allocator, text);
        }

        if (row_count != 0) try out.append(allocator, ',');
        try appendRow(allocator, out, columns, values);
        row_count += 1;
    }
}

fn stringArray(j: Jni, allocator: std.mem.Allocator, values: []const []const u8) !jobject {
    const string_cls = try j.findClass("java/lang/String");
    const array = try j.newObjectArray(values.len, string_cls);
    for (values, 0..) |value, i| {
        try j.pushLocalFrame(4);
        defer _ = j.popLocalFrame(null);
        try j.setObjectArrayElement(array, i, try j.newStringUtf8(allocator, value));
    }
    return array;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn boundArgs(json: []const u8) !?[][]const u8 {
    // An arena, because that is what the native passes — `bindArgs` prints
    // integers into it and frees nothing individually.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const args = try bindArgs(allocator, parsed.value) orelse return null;

    // Copied out, because everything above dies with the arena.
    const copy = try testing.allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, i| copy[i] = try testing.allocator.dupe(u8, arg);
    return copy;
}

fn freeArgs(args: [][]const u8) void {
    for (args) |arg| testing.allocator.free(arg);
    testing.allocator.free(args);
}

test "the parameter shapes this serves are the strings getString would produce" {
    const args = (try boundArgs(
        \\["a", 1, -2, true, false, null, ""]
    )).?;
    defer freeArgs(args);

    try testing.expectEqual(@as(usize, 7), args.len);
    try testing.expectEqualStrings("a", args[0]);
    try testing.expectEqualStrings("1", args[1]);
    try testing.expectEqualStrings("-2", args[2]);
    try testing.expectEqualStrings("true", args[3]);
    try testing.expectEqualStrings("false", args[4]);
    // `JSONArray.getString` on an explicit null gives the text, not SQL NULL.
    try testing.expectEqualStrings("null", args[5]);
    try testing.expectEqualStrings("", args[6]);
}

test "an empty parameter list is served rather than declined" {
    // `execSQL(sql, arrayOf())` is the common case — a statement with no
    // placeholders — so this is the path most calls take.
    const args = (try boundArgs("[]")).?;
    defer freeArgs(args);
    try testing.expectEqual(@as(usize, 0), args.len);
}

test "a shape only org.json would stringify is handed back" {
    for ([_][]const u8{
        // Double.toString picks the shortest round-tripping form.
        \\[1.5]
        ,
        \\[1.0]
        ,
        // org.json's own printer, key order included.
        \\[{"a":1}]
        ,
        \\[[1,2]]
        ,
        // Past i64, where std.json hands back the text and org.json a Double.
        \\[99999999999999999999]
        ,
        // JSONArray(paramsJson) throws on anything that is not an array.
        \\{"0":"a"}
        ,
        \\"a"
        ,
        \\null
        ,
    }) |payload| {
        if (try boundArgs(payload)) |args| {
            freeArgs(args);
            std.debug.print("payload was served rather than handed back: {s}\n", .{payload});
            return error.CoercedShapeAccepted;
        }
    }
}

fn renderRow(columns: []const []const u8, values: []const ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try appendRow(testing.allocator, &out, columns, values);
    return out.toOwnedSlice(testing.allocator);
}

test "a row prints its columns in cursor order" {
    const json = try renderRow(
        &.{ "id", "name" },
        &.{ "1", "Ada" },
    );
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"id\":\"1\",\"name\":\"Ada\"}", json);
}

test "a NULL column is absent from the row rather than null" {
    // `put(col, null)` removes the mapping. A page cannot tell a NULL column
    // from one the query never selected, and that is what the shim sends.
    const json = try renderRow(
        &.{ "id", "name", "note" },
        &.{ "1", null, "hi" },
    );
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"id\":\"1\",\"note\":\"hi\"}", json);

    // Including when it is the first column, where a naive comma would show.
    const leading = try renderRow(&.{ "a", "b" }, &.{ null, "x" });
    defer testing.allocator.free(leading);
    try testing.expectEqualStrings("{\"b\":\"x\"}", leading);

    // And when every column is null.
    const all_null = try renderRow(&.{ "a", "b" }, &.{ null, null });
    defer testing.allocator.free(all_null);
    try testing.expectEqualStrings("{}", all_null);
}

test "a column name or value carrying a quote survives as JSON" {
    // Column names come from the caller's own SQL — `select 1 as "a\"b"` is
    // legal — and values are whatever is in the database.
    const json = try renderRow(
        &.{"a\"b"},
        &.{"it's \"fine\""},
    );
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("it's \"fine\"", parsed.value.object.get("a\"b").?.string);
}

test "dbExecute resolves with the shim's constant, not a row count" {
    // `execSQL` returns void, so the 1 is a literal in the Kotlin and stays a
    // literal here. Asserted as the exact bytes because the page parses them.
    try testing.expectEqualStrings("{\"rowsAffected\":1}", exec_result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, exec_result, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("rowsAffected").?.integer);
}

test "the actions and globals match the shim exactly" {
    try testing.expectEqualStrings("dbExecute", A.db_execute);
    try testing.expectEqualStrings("dbQuery", A.db_query);
    try testing.expectEqualStrings("_craftDbExecResolve", exec_resolve_global);
    try testing.expectEqualStrings("_craftDbExecReject", exec_reject_global);
    try testing.expectEqualStrings("_craftDbQueryResolve", query_resolve_global);
    try testing.expectEqualStrings("_craftDbQueryReject", query_reject_global);
}
