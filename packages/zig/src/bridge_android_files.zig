//! `downloadFile` and `saveFile` on Android.
//!
//! Neither needs the main thread, a listener, or an Activity result — the
//! download is queued with the system's own manager and the save is ordinary
//! file I/O — so both are served whole rather than in halves.
//!
//! ## saveFile can report a path it never wrote
//!
//! The shim's data-URL branch is:
//!
//! ```kotlin
//! if (data.startsWith("data:")) {
//!     val parts = data.split(",")
//!     if (parts.size == 2) { ...decode and write... }
//! } else {
//!     file.writeText(data)
//! }
//! ...resolve(file.absolutePath)
//! ```
//!
//! `split(",")` splits on *every* comma, so a data URL whose payload contains
//! one — base64 does not produce commas, but `data:text/plain,a,b` is a legal
//! data URL — yields three parts, the `if` is skipped, **nothing is written**,
//! and the resolve still hands the page a path. The file may not exist at all.
//!
//! Reproduced rather than corrected, because the reply is what a page acts on
//! and changing it is a behaviour change. Recorded as `Plan.nothing` so the
//! case has a name instead of being an absent `else`. See #175.
//!
//! ## The decoding is Java's
//!
//! `android.util.Base64.decode` rather than a decoder here, for the reason
//! `bridge_android_notifications` hashes ids in Java: what matters is not
//! decoding base64 but decoding it the way the shim does, including which
//! inputs it throws on. A Zig decoder would be a second implementation whose
//! disagreements only ever show up on a device.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const download_file = "downloadFile";
    pub const save_file = "saveFile";
};

pub const download_resolve_global = "_craftDownloadResolve";
pub const download_reject_global = "_craftDownloadReject";
pub const save_resolve_global = "_craftSaveResolve";
pub const save_reject_global = "_craftSaveReject";

/// What the shim's notification says while a download runs.
const download_description = "Downloading...";

/// What `saveFile` will do with the data it was given.
pub const Plan = union(enum) {
    /// `file.writeText(data)` — anything not starting with `data:`.
    text: []const u8,
    /// `Base64.decode(parts[1])` — a data URL with exactly one comma.
    base64: []const u8,
    /// A data URL with any other number of commas. The shim writes nothing
    /// and resolves with the path anyway.
    nothing,
};

/// The shim's branch, comma counting included.
pub fn planFor(data: []const u8) Plan {
    if (!std.mem.startsWith(u8, data, "data:")) return .{ .text = data };

    // `split(",")` gives `count + 1` parts, so "exactly one comma" is the
    // whole of `parts.size == 2`.
    const first = std.mem.indexOfScalar(u8, data, ',') orelse return .nothing;
    if (std.mem.indexOfScalarPos(u8, data, first + 1, ',') != null) return .nothing;

    return .{ .base64 = data[first + 1 ..] };
}

/// `downloadManager.enqueue(request)`, and the id it returns.
pub fn download(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    url: []const u8,
    filename: []const u8,
) !i64 {
    try j.pushLocalFrame(32);
    defer _ = j.popLocalFrame(null);

    const uri_cls = try j.findClass("android/net/Uri");
    const uri = try j.callStaticObjectMethodA(
        uri_cls,
        try j.staticMethodId(uri_cls, "parse", "(Ljava/lang/String;)Landroid/net/Uri;"),
        &.{.{ .l = try j.newStringUtf8(allocator, url) }},
    );

    const request_cls = try j.findClass("android/app/DownloadManager$Request");
    const request = try j.newObjectA(
        request_cls,
        try j.methodId(request_cls, "<init>", "(Landroid/net/Uri;)V"),
        &.{.{ .l = uri }},
    );

    _ = try j.callObjectMethodA(
        request,
        try j.methodId(
            request_cls,
            "setTitle",
            "(Ljava/lang/CharSequence;)Landroid/app/DownloadManager$Request;",
        ),
        &.{.{ .l = try j.newStringUtf8(allocator, filename) }},
    );

    _ = try j.callObjectMethodA(
        request,
        try j.methodId(
            request_cls,
            "setDescription",
            "(Ljava/lang/CharSequence;)Landroid/app/DownloadManager$Request;",
        ),
        &.{.{ .l = try j.newStringUtf(download_description) }},
    );

    // Read rather than written down: a wrong visibility does not throw, it
    // just silently stops the user seeing the download.
    const visibility = try j.staticIntField(
        request_cls,
        try j.staticFieldId(request_cls, "VISIBILITY_VISIBLE_NOTIFY_COMPLETED", "I"),
    );
    _ = try j.callObjectMethodA(
        request,
        try j.methodId(request_cls, "setNotificationVisibility", "(I)Landroid/app/DownloadManager$Request;"),
        &.{.{ .i = visibility }},
    );

    const environment_cls = try j.findClass("android/os/Environment");
    const downloads_dir = try j.staticObjectField(
        environment_cls,
        try j.staticFieldId(environment_cls, "DIRECTORY_DOWNLOADS", "Ljava/lang/String;"),
    );
    _ = try j.callObjectMethodA(
        request,
        try j.methodId(
            request_cls,
            "setDestinationInExternalPublicDir",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/app/DownloadManager$Request;",
        ),
        &.{ .{ .l = downloads_dir }, .{ .l = try j.newStringUtf8(allocator, filename) } },
    );

    const context_cls = try j.findClass("android/content/Context");
    const service_name = try j.staticObjectField(
        context_cls,
        try j.staticFieldId(context_cls, "DOWNLOAD_SERVICE", "Ljava/lang/String;"),
    );
    const manager = try j.callObjectMethodA(
        activity,
        try j.methodId(
            try j.objectClass(activity),
            "getSystemService",
            "(Ljava/lang/String;)Ljava/lang/Object;",
        ),
        &.{.{ .l = service_name }},
    );

    return j.callLongMethodA(
        manager,
        try j.methodId(
            try j.objectClass(manager),
            "enqueue",
            "(Landroid/app/DownloadManager$Request;)J",
        ),
        &.{.{ .l = request }},
    );
}

/// Write the file and return its absolute path.
///
/// The path is produced whether or not anything was written, because that is
/// what the shim resolves with — see the note at the top of this file.
pub fn save(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    filename: []const u8,
    plan: Plan,
) ![]u8 {
    try j.pushLocalFrame(32);
    defer _ = j.popLocalFrame(null);

    const environment_cls = try j.findClass("android/os/Environment");
    const documents_dir = try j.staticObjectField(
        environment_cls,
        try j.staticFieldId(environment_cls, "DIRECTORY_DOCUMENTS", "Ljava/lang/String;"),
    );
    const parent = try j.callObjectMethodA(
        activity,
        try j.methodId(
            try j.objectClass(activity),
            "getExternalFilesDir",
            "(Ljava/lang/String;)Ljava/io/File;",
        ),
        &.{.{ .l = documents_dir }},
    );

    const file_cls = try j.findClass("java/io/File");
    const file = try j.newObjectA(
        file_cls,
        try j.methodId(file_cls, "<init>", "(Ljava/io/File;Ljava/lang/String;)V"),
        &.{ .{ .l = parent }, .{ .l = try j.newStringUtf8(allocator, filename) } },
    );

    switch (plan) {
        .nothing => {},
        .text => |text| try writeBytes(j, file, try utf8Bytes(j, allocator, text)),
        .base64 => |encoded| try writeBytes(j, file, try decodeBase64(j, allocator, encoded)),
    }

    const path = try j.callObjectMethod(
        file,
        try j.methodId(file_cls, "getAbsolutePath", "()Ljava/lang/String;"),
    );
    return j.stringToUtf8(allocator, path);
}

/// `Base64.decode(encoded, Base64.DEFAULT)`.
fn decodeBase64(j: Jni, allocator: std.mem.Allocator, encoded: []const u8) !jobject {
    const base64_cls = try j.findClass("android/util/Base64");

    // Read rather than written down: `URL_SAFE` is a different alphabet, and
    // decoding with the wrong one produces bytes rather than an error.
    const default_flags = try j.staticIntField(
        base64_cls,
        try j.staticFieldId(base64_cls, "DEFAULT", "I"),
    );

    return j.callStaticObjectMethodA(
        base64_cls,
        try j.staticMethodId(base64_cls, "decode", "(Ljava/lang/String;I)[B"),
        &.{ .{ .l = try j.newStringUtf8(allocator, encoded) }, .{ .i = default_flags } },
    );
}

/// `text.toByteArray()` — Kotlin's `writeText` uses UTF-8.
fn utf8Bytes(j: Jni, allocator: std.mem.Allocator, text: []const u8) !jobject {
    const string = try j.newStringUtf8(allocator, text);
    const charset_cls = try j.findClass("java/nio/charset/StandardCharsets");
    const utf8 = try j.staticObjectField(
        charset_cls,
        try j.staticFieldId(charset_cls, "UTF_8", "Ljava/nio/charset/Charset;"),
    );
    return j.callObjectMethodA(
        string,
        try j.methodId(
            try j.objectClass(string),
            "getBytes",
            "(Ljava/nio/charset/Charset;)[B",
        ),
        &.{.{ .l = utf8 }},
    );
}

/// `FileOutputStream(file).use { it.write(bytes) }`.
fn writeBytes(j: Jni, file: jobject, bytes: jobject) !void {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const stream_cls = try j.findClass("java/io/FileOutputStream");
    const stream = try j.newObjectA(
        stream_cls,
        try j.methodId(stream_cls, "<init>", "(Ljava/io/File;)V"),
        &.{.{ .l = file }},
    );

    // Resolved before the write, so the close below can be a plain `defer`.
    // A stream left open holds its file descriptor until the GC gets to it,
    // which on a device is long enough to matter — so it closes however this
    // leaves, error included.
    const close = try j.methodId(stream_cls, "close", "()V");
    defer j.callVoidMethodA(stream, close, &.{}) catch {};

    try j.callVoidMethodA(
        stream,
        try j.methodId(stream_cls, "write", "([B)V"),
        &.{.{ .l = bytes }},
    );
}

/// `text` as a JSON string.
pub fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, text);
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "anything not a data URL is written as text" {
    const plan = planFor("hello, world");
    try testing.expectEqualStrings("hello, world", plan.text);

    // Including text that merely contains "data:" later on.
    try testing.expectEqualStrings("x data:y", planFor("x data:y").text);

    // And the empty string, which writes an empty file rather than nothing.
    try testing.expectEqualStrings("", planFor("").text);
}

test "a data URL with exactly one comma decodes the tail" {
    const plan = planFor("data:image/png;base64,iVBORw0KGgo=");
    try testing.expectEqualStrings("iVBORw0KGgo=", plan.base64);

    // The payload can be empty — `Base64.decode("")` is an empty array, so
    // this writes an empty file rather than skipping the write.
    try testing.expectEqualStrings("", planFor("data:,").base64);
}

test "a data URL with any other number of commas writes nothing at all" {
    // The shim's `if (parts.size == 2)` with no else. The resolve still hands
    // the page `file.absolutePath`, so a page is told where a file is that may
    // not exist. See #175.
    try testing.expectEqual(Plan.nothing, planFor("data:text/plain,a,b"));
    try testing.expectEqual(Plan.nothing, planFor("data:image/png;base64,AAA,BBB"));

    // No comma at all is the same skipped branch.
    try testing.expectEqual(Plan.nothing, planFor("data:image/png;base64"));
    try testing.expectEqual(Plan.nothing, planFor("data:"));
}

test "the prefix test is the shim's startsWith, not a contains" {
    // `data` alone is text; only the colon makes it a URL.
    try testing.expectEqualStrings("data", planFor("data").text);
    try testing.expect(planFor("data:") == .nothing);

    // Case matters: `startsWith` is not case-insensitive, so `DATA:` is text
    // and is written verbatim.
    try testing.expectEqualStrings("DATA:x,y", planFor("DATA:x,y").text);
}

test "the actions and globals match the shim exactly" {
    try testing.expectEqualStrings("downloadFile", A.download_file);
    try testing.expectEqualStrings("saveFile", A.save_file);
    try testing.expectEqualStrings("_craftDownloadResolve", download_resolve_global);
    try testing.expectEqualStrings("_craftDownloadReject", download_reject_global);
    try testing.expectEqualStrings("_craftSaveResolve", save_resolve_global);
    try testing.expectEqualStrings("_craftSaveReject", save_reject_global);
}

test "a path carrying a quote comes back as JSON" {
    // `file.absolutePath` contains the filename the page chose, so it is page
    // text arriving back through the reply channel.
    const payload = try jsonString(testing.allocator, "/sdcard/it's \"here\".txt");
    defer testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/sdcard/it's \"here\".txt", parsed.value.string);
}
