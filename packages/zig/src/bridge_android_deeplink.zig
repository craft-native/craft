//! Android initial/deferred deep links.
//!
//! The initial URL used to be a `CraftBridge` field. It now lives here and is
//! explicitly reset when a new bridge instance is constructed, preserving the
//! old per-Activity lifetime rather than leaking one Activity's URL into the
//! next. Both the initial lookup and later event use Android's own `Uri` and
//! `JSONObject` through JNI, so query decoding and key order remain the
//! platform's rather than a second parser's approximation.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const get_initial_url = "getInitialURL";
};

pub const resolve_global = "_craftDeepLinkResolve";
pub const event_name = "craftDeepLink";

var locked: std.atomic.Value(bool) = .init(false);
var initial_url: ?[]u8 = null;

fn lock() void {
    while (locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    locked.store(false, .release);
}

pub fn reset() void {
    lock();
    defer unlock();
    if (initial_url) |old| std.heap.page_allocator.free(old);
    initial_url = null;
}

pub fn set(url: ?[]const u8) !void {
    const replacement = if (url) |text| try std.heap.page_allocator.dupe(u8, text) else null;
    lock();
    const old = initial_url;
    initial_url = replacement;
    unlock();
    if (old) |bytes| std.heap.page_allocator.free(bytes);
}

pub fn rememberFirst(url: []const u8) !void {
    const candidate = try std.heap.page_allocator.dupe(u8, url);
    lock();
    if (initial_url == null) {
        initial_url = candidate;
        unlock();
    } else {
        unlock();
        std.heap.page_allocator.free(candidate);
    }
}

pub fn snapshot(allocator: std.mem.Allocator) !?[]u8 {
    lock();
    defer unlock();
    return if (initial_url) |url| try allocator.dupe(u8, url) else null;
}

fn jsonPut(j: Jni, object: jobject, key: []const u8, value: jobject) !void {
    const result = try j.callObjectMethodA(
        object,
        try j.methodId(try j.objectClass(object), "put", "(Ljava/lang/String;Ljava/lang/Object;)Lorg/json/JSONObject;"),
        &.{ .{ .l = try j.newStringUtf8(std.heap.page_allocator, key) }, .{ .l = value } },
    );
    j.deleteLocalRef(result);
}

fn stringOrEmpty(j: Jni, value: jobject) !jobject {
    return if (value != null) value else try j.newStringUtf("");
}

/// Build the exact object both Kotlin paths built for one URL.
pub fn payload(j: Jni, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    try j.pushLocalFrame(32);
    defer _ = j.popLocalFrame(null);

    const uri_cls = try j.findClass("android/net/Uri");
    const url_string = try j.newStringUtf8(allocator, url);
    const uri = try j.callStaticObjectMethodA(
        uri_cls,
        try j.staticMethodId(uri_cls, "parse", "(Ljava/lang/String;)Landroid/net/Uri;"),
        &.{.{ .l = url_string }},
    );
    const uri_object_cls = try j.objectClass(uri);

    const json_cls = try j.findClass("org/json/JSONObject");
    const init = try j.methodId(json_cls, "<init>", "()V");
    const root = try j.newObjectA(json_cls, init, &.{});
    try jsonPut(j, root, "url", url_string);

    const fields = [_]struct { key: []const u8, method: [*:0]const u8 }{
        .{ .key = "scheme", .method = "getScheme" },
        .{ .key = "host", .method = "getHost" },
        .{ .key = "path", .method = "getPath" },
        .{ .key = "query", .method = "getQuery" },
    };
    for (fields) |field| {
        const value = try j.callObjectMethod(uri, try j.methodId(uri_object_cls, field.method, "()Ljava/lang/String;"));
        try jsonPut(j, root, field.key, try stringOrEmpty(j, value));
    }

    const query_params = try j.newObjectA(json_cls, init, &.{});
    const names = try j.callObjectMethod(
        uri,
        try j.methodId(uri_object_cls, "getQueryParameterNames", "()Ljava/util/Set;"),
    );
    const iterator = try j.callObjectMethod(
        names,
        try j.methodId(try j.objectClass(names), "iterator", "()Ljava/util/Iterator;"),
    );
    const iterator_cls = try j.objectClass(iterator);
    const has_next = try j.methodId(iterator_cls, "hasNext", "()Z");
    const next = try j.methodId(iterator_cls, "next", "()Ljava/lang/Object;");
    const query_value = try j.methodId(uri_object_cls, "getQueryParameter", "(Ljava/lang/String;)Ljava/lang/String;");
    while (try j.callBooleanMethodA(iterator, has_next, &.{})) {
        const name = try j.callObjectMethod(iterator, next);
        const value = try j.callObjectMethodA(uri, query_value, &.{.{ .l = name }});
        const put_result = try j.callObjectMethodA(
            query_params,
            try j.methodId(json_cls, "put", "(Ljava/lang/String;Ljava/lang/Object;)Lorg/json/JSONObject;"),
            &.{ .{ .l = name }, .{ .l = try stringOrEmpty(j, value) } },
        );
        j.deleteLocalRef(put_result);
        j.deleteLocalRef(name);
        j.deleteLocalRef(value);
    }
    try jsonPut(j, root, "queryParams", query_params);

    const rendered = try j.callObjectMethod(root, try j.methodId(json_cls, "toString", "()Ljava/lang/String;"));
    return j.stringToUtf8(allocator, rendered);
}

const testing = std.testing;

test "reset, set and first-only storage preserve the bridge lifetime" {
    reset();
    try testing.expect(try snapshot(testing.allocator) == null);
    try rememberFirst("craft://first");
    try rememberFirst("craft://second");
    const first = (try snapshot(testing.allocator)).?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("craft://first", first);
    try set("craft://replacement");
    const replacement = (try snapshot(testing.allocator)).?;
    defer testing.allocator.free(replacement);
    try testing.expectEqualStrings("craft://replacement", replacement);
    reset();
}

test "the action and delivery names match the shim" {
    try testing.expectEqualStrings("getInitialURL", A.get_initial_url);
    try testing.expectEqualStrings("_craftDeepLinkResolve", resolve_global);
    try testing.expectEqualStrings("craftDeepLink", event_name);
}
