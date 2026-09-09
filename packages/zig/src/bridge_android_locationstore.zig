//! `getLocationRecordingState` and `readLocationRecording` on Android.
//!
//! Both are the *read* side of `CraftLocationRecordingStore`, which a
//! foreground service writes while a recording runs. Neither starts, stops or
//! samples anything — those need the service, and the service needs a
//! `LocationCallback`, which is a Java interface Zig cannot implement.
//!
//! So this migrates the half that is a file and a preferences read, and leaves
//! the half that is a service alone.
//!
//! ## Both return a String rather than answering through the channel
//!
//! `fun getLocationRecordingState(): String` — synchronous, like
//! `clipboardRead`. So a null from the native means "ask the shim" and a
//! string means "this is the answer", with no promise involved at either end.
//!
//! ## A malformed line makes this decline rather than skip
//!
//! The store's reader is `forEachLine { if (line.isNotBlank()) runCatching {
//! result.put(JSONObject(line)) } }` — a line that does not parse is dropped
//! silently and the rest are kept.
//!
//! Zig does not reproduce the dropping. `std.json` is stricter than
//! `JSONTokener`, so a line one accepts and the other refuses would make the
//! two disagree about how many samples there are — and `sampleCount` is a
//! number a page shows to a user. Declining hands the whole read back to the
//! shim, which drops the line the way it always did.
//!
//! ## Lines are passed through, not re-serialized
//!
//! The shim parses each line and prints it again, and `append` wrote each line
//! with the same printer — so re-printing is the identity for every file this
//! app produced. Passing the bytes through avoids reproducing `org.json`'s
//! number formatting, which is the `Double.toString` problem the calendar and
//! database modules both decline to guess at.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const prefs_api = @import("android_prefs.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const get_location_recording_state = "getLocationRecordingState";
    pub const read_location_recording = "readLocationRecording";
};

/// `CraftLocationRecordingStore.PREFS` and `FILE`.
const prefs_name = "craft_location_recording";
const file_name = "craft-location-recording.jsonl";

/// What a recording's preferences hold.
pub const State = struct {
    /// Absent rather than null when the key has never been written — the
    /// store's `put("id", getString("id", null))` *removes* the mapping.
    id: ?[]const u8,
    active: bool,
    paused: bool,
    /// `getLong("startedAt", 0).takeIf { it > 0 } ?: JSONObject.NULL` — so
    /// zero and every negative become an explicit JSON null, and the key
    /// stays.
    started_at: ?i64,
    sample_count: usize,
};

/// `state(context)` as `org.json` would print it.
///
/// The two nulls are not the same null, which is the whole reason this is a
/// function with a test rather than a format string: a missing `id` has no
/// key at all, and a missing `startedAt` is present and null.
pub fn renderState(allocator: std.mem.Allocator, state: State) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '{');
    if (state.id) |id| {
        try out.appendSlice(allocator, "\"id\":\"");
        try bridge_error.appendJsonEscaped(allocator, &out, id);
        try out.appendSlice(allocator, "\",");
    }
    try out.appendSlice(allocator, "\"active\":");
    try out.appendSlice(allocator, if (state.active) "true" else "false");
    try out.appendSlice(allocator, ",\"paused\":");
    try out.appendSlice(allocator, if (state.paused) "true" else "false");

    try out.appendSlice(allocator, ",\"startedAt\":");
    if (state.started_at) |started_at| {
        try out.print(allocator, "{d}", .{started_at});
    } else {
        try out.appendSlice(allocator, "null");
    }

    try out.print(allocator, ",\"sampleCount\":{d}}}", .{state.sample_count});
    return out.toOwnedSlice(allocator);
}

/// The array and how many samples are in it.
///
/// One function rather than two, so `sampleCount` and the array a page reads
/// next cannot disagree — that agreement is a property of the code here
/// rather than something a test has to keep checking.
pub const Locations = struct { json: []u8, count: usize };

/// `locations(context)` as a JSON array, or null if any line does not parse.
///
/// The lines are emitted as they were stored — see the note at the top about
/// why this does not re-serialize them.
pub fn renderLocations(allocator: std.mem.Allocator, contents: []const u8) !?Locations {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '[');

    var written: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        // `isNotBlank()` — a line of spaces is skipped, not parsed. Kotlin's
        // definition is "no non-whitespace character", and `\r` from a file
        // written on another platform is whitespace to both.
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            out.deinit(allocator);
            return null;
        };
        parsed.deinit();

        if (written != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, line);
        written += 1;
    }

    try out.append(allocator, ']');
    return Locations{ .json = try out.toOwnedSlice(allocator), .count = written };
}

/// The recording file's contents, or an empty slice when it does not exist.
///
/// Read through Java rather than with Zig's own file API, which on this
/// toolchain needs an `Io` a JNI native has nowhere to get.
pub fn readFile(j: Jni, allocator: std.mem.Allocator, activity: jobject) ![]u8 {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const files_dir = try j.callObjectMethod(
        activity,
        try j.methodId(try j.objectClass(activity), "getFilesDir", "()Ljava/io/File;"),
    );

    const file_cls = try j.findClass("java/io/File");
    const file = try j.newObjectA(
        file_cls,
        try j.methodId(file_cls, "<init>", "(Ljava/io/File;Ljava/lang/String;)V"),
        &.{ .{ .l = files_dir }, .{ .l = try j.newStringUtf(file_name) } },
    );

    // `if (!source.exists()) return result` — an empty array rather than an
    // error, because a recording that never started has no file.
    const exists = try j.callBooleanMethodA(
        file,
        try j.methodId(file_cls, "exists", "()Z"),
        &.{},
    );
    if (!exists) return allocator.alloc(u8, 0);

    const stream_cls = try j.findClass("java/io/FileInputStream");
    const stream = try j.newObjectA(
        stream_cls,
        try j.methodId(stream_cls, "<init>", "(Ljava/io/File;)V"),
        &.{.{ .l = file }},
    );
    const close = try j.methodId(stream_cls, "close", "()V");
    defer j.callVoidMethodA(stream, close, &.{}) catch {};

    // `readAllBytes` is API 33. `File.length()` plus one `read` is the form
    // that works everywhere this app runs, and a short read is a truncated
    // file rather than an error — which is what `forEachLine` would also see.
    const length = try j.callLongMethod(file, try j.methodId(file_cls, "length", "()J"));
    if (length <= 0) return allocator.alloc(u8, 0);

    const buffer = try j.newByteArray(@intCast(length));
    const read = try j.callIntMethodA(
        stream,
        try j.methodId(stream_cls, "read", "([B)I"),
        &.{.{ .l = buffer }},
    );
    if (read <= 0) return allocator.alloc(u8, 0);

    const bytes = try j.byteArrayToOwned(allocator, buffer);
    return allocator.realloc(bytes, @intCast(read));
}

/// Read the four preference values a state is built from.
pub fn readState(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    sample_count: usize,
) !State {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const prefs = try prefs_api.open(j, allocator, activity, prefs_name);
    const started_at = try prefs_api.getLong(j, allocator, prefs, "startedAt", 0);

    return .{
        .id = try prefs_api.getString(j, allocator, prefs, "id"),
        .active = try prefs_api.getBoolean(j, allocator, prefs, "active", false),
        .paused = try prefs_api.getBoolean(j, allocator, prefs, "paused", false),
        .started_at = if (started_at > 0) started_at else null,
        .sample_count = sample_count,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "a state that has never recorded has no id and a null startedAt" {
    // The two nulls the store produces are different nulls: `put("id", null)`
    // removes the mapping, and `startedAt` is set to JSONObject.NULL
    // explicitly, so its key stays.
    const json = try renderState(testing.allocator, .{
        .id = null,
        .active = false,
        .paused = false,
        .started_at = null,
        .sample_count = 0,
    });
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\{"active":false,"paused":false,"startedAt":null,"sampleCount":0}
    , json);
}

test "a running recording carries every field, in the store's order" {
    const json = try renderState(testing.allocator, .{
        .id = "run-7",
        .active = true,
        .paused = true,
        .started_at = 1_700_000_000_000,
        .sample_count = 42,
    });
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\{"id":"run-7","active":true,"paused":true,"startedAt":1700000000000,"sampleCount":42}
    , json);
}

test "startedAt of zero or below is the same null as never having started" {
    // `takeIf { it > 0 } ?: JSONObject.NULL`. A clock that went backwards
    // writes a negative, and the store reports null rather than the number.
    for ([_]?i64{
        null,
    }) |started_at| {
        const json = try renderState(testing.allocator, .{
            .id = "run-7",
            .active = true,
            .paused = false,
            .started_at = started_at,
            .sample_count = 1,
        });
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"startedAt\":null") != null);
    }
}

test "an id carrying a quote survives as JSON" {
    const json = try renderState(testing.allocator, .{
        .id = "it's \"run\"",
        .active = false,
        .paused = false,
        .started_at = null,
        .sample_count = 0,
    });
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("it's \"run\"", parsed.value.object.get("id").?.string);
}

test "locations are the file's lines, in order, with the blanks dropped" {
    const contents =
        "{\"latitude\":1,\"longitude\":2}\n" ++
        "\n" ++
        "   \n" ++
        "{\"latitude\":3,\"longitude\":4}\n";

    const locations = (try renderLocations(testing.allocator, contents)).?;
    defer testing.allocator.free(locations.json);

    try testing.expectEqualStrings(
        \\[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4}]
    , locations.json);
    try testing.expectEqual(@as(usize, 2), locations.count);
}

test "an empty or missing file is an empty array" {
    const empty = (try renderLocations(testing.allocator, "")).?;
    defer testing.allocator.free(empty.json);
    try testing.expectEqualStrings("[]", empty.json);
    try testing.expectEqual(@as(usize, 0), empty.count);

    const blank = (try renderLocations(testing.allocator, "\n\n  \n")).?;
    defer testing.allocator.free(blank.json);
    try testing.expectEqualStrings("[]", blank.json);
}

test "a malformed line makes the whole read decline" {
    // The store drops it and keeps the rest. Zig does not reproduce the
    // dropping, because std.json and JSONTokener disagree about what parses —
    // and disagreeing about how many samples there are is worse than handing
    // the read back.
    try testing.expect(try renderLocations(testing.allocator, "{\"a\":1}\nnot json\n") == null);
    try testing.expect(try renderLocations(testing.allocator, "{oops}\n") == null);

    // A truncated final line, which is what a file cut off mid-write looks
    // like — the case most likely to actually happen.
    try testing.expect(try renderLocations(testing.allocator, "{\"a\":1}\n{\"b\":") == null);
}

test "sampleCount is the length of the array it was counted from" {
    // A page showing `sampleCount` and then reading the samples must not see
    // two different numbers, so the count comes back from the same pass.
    const contents = "{\"a\":1}\n\n{\"b\":2}\n  \n{\"c\":3}\n";

    const locations = (try renderLocations(testing.allocator, contents)).?;
    defer testing.allocator.free(locations.json);
    try testing.expectEqual(@as(usize, 3), locations.count);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, locations.json, .{});
    defer parsed.deinit();
    try testing.expectEqual(locations.count, parsed.value.array.items.len);
}

test "the store's names are the ones the service writes" {
    // A different preferences file or filename here reads an empty recording
    // and reports it as an empty one, which looks exactly like a recording
    // that has not started.
    try testing.expectEqualStrings("craft_location_recording", prefs_name);
    try testing.expectEqualStrings("craft-location-recording.jsonl", file_name);
}

test "the actions match the shim exactly" {
    try testing.expectEqualStrings("getLocationRecordingState", A.get_location_recording_state);
    try testing.expectEqualStrings("readLocationRecording", A.read_location_recording);
}
