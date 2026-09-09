//! `setShortcuts` and `clearShortcuts` on Android — the long-press menu on the
//! launcher icon.
//!
//! ## The version check is not symmetric, and that is the shim's choice
//!
//! Dynamic shortcuts arrived in API 25. Below it, `setShortcuts` **rejects**
//! with "App shortcuts require Android 7.1+" and `clearShortcuts` **resolves**
//! with `true`. Both are defensible on their own — there is nothing to set,
//! and nothing to clear is the same as having cleared it — and together they
//! mean a page cannot use one answer to predict the other. Ported as written.
//!
//! ## `getString` throws where `optString` would default
//!
//! `type` and `title` are read with `getString`, which raises `JSONException`
//! when the key is missing. So a shortcut without a title does not become a
//! shortcut with an empty title: the whole call rejects and *no* shortcut is
//! set, including the ones that parsed. `subtitle` is guarded by `has` and so
//! is genuinely optional.
//!
//! That all-or-nothing behaviour is worth stating because it is not obvious
//! from the call site — `setDynamicShortcuts` runs once, after the loop.
//!
//! ## The id and the extra are the same string
//!
//! `ShortcutInfo.Builder(activity, type)` uses `type` as the shortcut's id,
//! and `putExtra("shortcut_type", type)` puts it in the intent as well. So two
//! shortcuts sharing a `type` are one shortcut, silently — the second replaces
//! the first in a `List` the framework keys by id.

const std = @import("std");
const jni = @import("jni_runtime.zig");
const bridge_error = @import("bridge_error.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const set_shortcuts = "setShortcuts";
    pub const clear_shortcuts = "clearShortcuts";
};

pub const resolve_global = "_craftShortcutsResolve";
pub const reject_global = "_craftShortcutsReject";

/// `Build.VERSION_CODES.N_MR1`, where dynamic shortcuts arrived.
///
/// A compile-time constant in Java, so the shim's DEX holds the literal 25.
pub const n_mr1: i32 = 25;

/// What the shim rejects with below API 25.
pub const unsupported_message = "App shortcuts require Android 7.1+";

/// The extra `setShortcuts` puts on every intent it builds.
const extra_shortcut_type = "shortcut_type";

pub const Shortcut = struct {
    /// Both the shortcut's id and its `shortcut_type` extra.
    type: []const u8,
    title: []const u8,
    subtitle: ?[]const u8,
};

/// Read the declared shape, or null where only `org.json` would.
///
/// Distinct from the calendar's and the widget's version in one way: `type`
/// and `title` are *required*, because the shim reads them with `getString`
/// and that raises rather than defaulting. A payload missing either is not a
/// shape this declines — it is a payload the shim rejects, so it is an error
/// here rather than a null.
pub fn parseShortcuts(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !?[]Shortcut {
    const items = switch (value) {
        .array => |a| a.items,
        // `JSONArray(shortcutsJson)` throws on anything else, and the shim's
        // catch rejects. Declining sends it there.
        else => return null,
    };

    const shortcuts = try allocator.alloc(Shortcut, items.len);
    errdefer allocator.free(shortcuts);

    for (items, 0..) |item, i| {
        const object = switch (item) {
            .object => |o| o,
            else => return null,
        };

        shortcuts[i] = .{
            .type = (try required(object, "type")) orelse return null,
            .title = (try required(object, "title")) orelse return null,
            .subtitle = optional(object, "subtitle") orelse return null,
        };
    }
    return shortcuts;
}

/// `object.getString(name)` — an error when absent, null when only a
/// coercion would answer.
fn required(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .string => |text| text,
        // `JSON.toString(NULL)` is "null", and `getString` returns it rather
        // than throwing — a shortcut really can be titled "null".
        .null => "null",
        else => null,
    };
}

/// `if (has(name)) getString(name) else null`.
///
/// The outer null means "a shape this declines"; the inner one means the key
/// was absent and `setLongLabel` is never called.
fn optional(object: std.json.ObjectMap, name: []const u8) ??[]const u8 {
    const value = object.get(name) orelse return @as(?[]const u8, null);
    return switch (value) {
        .string => |text| @as(?[]const u8, text),
        .null => @as(?[]const u8, "null"),
        else => null,
    };
}

/// `Build.VERSION.SDK_INT`.
pub fn sdkInt(j: Jni) !i32 {
    try j.pushLocalFrame(4);
    defer _ = j.popLocalFrame(null);

    const version_cls = try j.findClass("android/os/Build$VERSION");
    return j.staticIntField(version_cls, try j.staticFieldId(version_cls, "SDK_INT", "I"));
}

/// `activity.getSystemService(ShortcutManager::class.java)`.
///
/// The `jclass` `FindClass` returns *is* the `java.lang.Class` object the
/// overload wants, so no extra call is needed to reach for one.
fn shortcutManager(j: Jni, activity: jobject) !jobject {
    const manager_cls = try j.findClass("android/content/pm/ShortcutManager");
    return j.callObjectMethodA(
        activity,
        try j.methodId(
            try j.objectClass(activity),
            "getSystemService",
            "(Ljava/lang/Class;)Ljava/lang/Object;",
        ),
        &.{.{ .l = manager_cls }},
    );
}

/// `shortcutManager?.removeAllDynamicShortcuts()`.
///
/// The `?.` matters: `getSystemService` can hand back null, and the shim then
/// does nothing and still resolves `true`.
pub fn clear(j: Jni, activity: jobject) !void {
    try j.pushLocalFrame(8);
    defer _ = j.popLocalFrame(null);

    const manager = try shortcutManager(j, activity);
    if (manager == null) return;

    try j.callVoidMethodA(
        manager,
        try j.methodId(try j.objectClass(manager), "removeAllDynamicShortcuts", "()V"),
        &.{},
    );
}

/// `shortcutManager?.dynamicShortcuts = shortcuts`.
pub fn set(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    shortcuts: []const Shortcut,
) !void {
    try j.pushLocalFrame(32);
    defer _ = j.popLocalFrame(null);

    const list_cls = try j.findClass("java/util/ArrayList");
    const list = try j.newObjectA(list_cls, try j.methodId(list_cls, "<init>", "()V"), &.{});
    const add = try j.methodId(list_cls, "add", "(Ljava/lang/Object;)Z");

    for (shortcuts) |shortcut| {
        try j.pushLocalFrame(16);
        defer _ = j.popLocalFrame(null);
        _ = try j.callBooleanMethodA(list, add, &.{
            .{ .l = try buildShortcut(j, allocator, activity, shortcut) },
        });
    }

    // The list is set once, after the loop — which is why a payload the shim
    // rejects part-way through leaves the previous shortcuts in place.
    const manager = try shortcutManager(j, activity);
    if (manager == null) return;

    try j.callVoidMethodA(
        manager,
        try j.methodId(
            try j.objectClass(manager),
            "setDynamicShortcuts",
            "(Ljava/util/List;)V",
        ),
        &.{.{ .l = list }},
    );
}

fn buildShortcut(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    shortcut: Shortcut,
) !jobject {
    const intent = try launchIntent(j, allocator, activity, shortcut.type);

    const builder_cls = try j.findClass("android/content/pm/ShortcutInfo$Builder");
    const builder = try j.newObjectA(
        builder_cls,
        try j.methodId(builder_cls, "<init>", "(Landroid/content/Context;Ljava/lang/String;)V"),
        &.{ .{ .l = activity }, .{ .l = try j.newStringUtf8(allocator, shortcut.type) } },
    );

    _ = try j.callObjectMethodA(
        builder,
        try j.methodId(
            builder_cls,
            "setShortLabel",
            "(Ljava/lang/CharSequence;)Landroid/content/pm/ShortcutInfo$Builder;",
        ),
        &.{.{ .l = try j.newStringUtf8(allocator, shortcut.title) }},
    );

    _ = try j.callObjectMethodA(
        builder,
        try j.methodId(
            builder_cls,
            "setIntent",
            "(Landroid/content/Intent;)Landroid/content/pm/ShortcutInfo$Builder;",
        ),
        &.{.{ .l = intent }},
    );

    if (shortcut.subtitle) |subtitle| {
        _ = try j.callObjectMethodA(
            builder,
            try j.methodId(
                builder_cls,
                "setLongLabel",
                "(Ljava/lang/CharSequence;)Landroid/content/pm/ShortcutInfo$Builder;",
            ),
            &.{.{ .l = try j.newStringUtf8(allocator, subtitle) }},
        );
    }

    return j.callObjectMethod(
        builder,
        try j.methodId(builder_cls, "build", "()Landroid/content/pm/ShortcutInfo;"),
    );
}

/// `Intent(activity, activity::class.java)` with `ACTION_VIEW` and the extra.
fn launchIntent(
    j: Jni,
    allocator: std.mem.Allocator,
    activity: jobject,
    shortcut_type: []const u8,
) !jobject {
    const intent_cls = try j.findClass("android/content/Intent");
    const intent = try j.newObjectA(
        intent_cls,
        try j.methodId(intent_cls, "<init>", "(Landroid/content/Context;Ljava/lang/Class;)V"),
        // `activity::class.java` — the activity's own class, so the shortcut
        // reopens the app rather than naming a class this library cannot know.
        &.{ .{ .l = activity }, .{ .l = try j.objectClass(activity) } },
    );

    // Read off `Intent` rather than spelled as a literal, the same way
    // `bridge_android_intents` reads it.
    const action_view = try j.staticObjectField(
        intent_cls,
        try j.staticFieldId(intent_cls, "ACTION_VIEW", "Ljava/lang/String;"),
    );
    _ = try j.callObjectMethodA(
        intent,
        try j.methodId(intent_cls, "setAction", "(Ljava/lang/String;)Landroid/content/Intent;"),
        &.{.{ .l = action_view }},
    );

    _ = try j.callObjectMethodA(
        intent,
        try j.methodId(
            intent_cls,
            "putExtra",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;",
        ),
        &.{
            .{ .l = try j.newStringUtf(extra_shortcut_type) },
            .{ .l = try j.newStringUtf8(allocator, shortcut_type) },
        },
    );

    return intent;
}

/// `{count: n}` — what `setShortcuts` resolves with.
pub fn countPayload(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"count\":{d}}}", .{count});
}

/// `message` as a JSON string.
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

fn parsedShortcuts(json: []const u8) !?[]Shortcut {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var doc = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    defer doc.deinit();

    const shortcuts = (try parseShortcuts(arena.allocator(), doc.value)) orelse return null;

    const copy = try testing.allocator.alloc(Shortcut, shortcuts.len);
    for (shortcuts, 0..) |s, i| {
        copy[i] = .{
            .type = try testing.allocator.dupe(u8, s.type),
            .title = try testing.allocator.dupe(u8, s.title),
            .subtitle = if (s.subtitle) |sub| try testing.allocator.dupe(u8, sub) else null,
        };
    }
    return copy;
}

fn freeShortcuts(shortcuts: []Shortcut) void {
    for (shortcuts) |s| {
        testing.allocator.free(s.type);
        testing.allocator.free(s.title);
        if (s.subtitle) |sub| testing.allocator.free(sub);
    }
    testing.allocator.free(shortcuts);
}

test "the declared shape reads straight through" {
    const shortcuts = (try parsedShortcuts(
        \\[{"type":"cart","title":"Cart","subtitle":"Your basket"},
        \\ {"type":"orders","title":"Orders"}]
    )).?;
    defer freeShortcuts(shortcuts);

    try testing.expectEqual(@as(usize, 2), shortcuts.len);
    try testing.expectEqualStrings("cart", shortcuts[0].type);
    try testing.expectEqualStrings("Cart", shortcuts[0].title);
    try testing.expectEqualStrings("Your basket", shortcuts[0].subtitle.?);

    // `has("subtitle")` is false, so `setLongLabel` is never called — which is
    // different from calling it with an empty string.
    try testing.expect(shortcuts[1].subtitle == null);
}

test "a missing type or title rejects the whole call rather than defaulting" {
    // `getString` raises JSONException where `optString` would default, and
    // `setDynamicShortcuts` runs once after the loop — so a payload missing a
    // title sets nothing at all, including the entries that parsed.
    for ([_][]const u8{
        \\[{"title":"Cart"}]
        ,
        \\[{"type":"cart"}]
        ,
        \\[{"type":"cart","title":"Cart"},{"type":"orders"}]
        ,
    }) |payload| {
        try testing.expectError(error.MissingField, parsedShortcuts(payload));
    }
}

test "an empty list is set rather than declined" {
    // `craft.shortcuts.set([])` is how a page removes them without reaching
    // for `clear`, and the shim resolves `{count: 0}`.
    const shortcuts = (try parsedShortcuts("[]")).?;
    defer freeShortcuts(shortcuts);
    try testing.expectEqual(@as(usize, 0), shortcuts.len);
}

test "a shape only org.json would coerce is handed back" {
    for ([_][]const u8{
        \\[{"type":1,"title":"Cart"}]
        ,
        \\[{"type":"cart","title":2.5}]
        ,
        \\[{"type":"cart","title":"Cart","subtitle":true}]
        ,
        \\[["cart","Cart"]]
        ,
        \\{"type":"cart"}
        ,
        \\"cart"
        ,
    }) |payload| {
        if (try parsedShortcuts(payload)) |shortcuts| {
            freeShortcuts(shortcuts);
            std.debug.print("payload was served rather than handed back: {s}\n", .{payload});
            return error.CoercedShapeAccepted;
        }
    }
}

test "an explicit null is the string null, here as everywhere else" {
    const shortcuts = (try parsedShortcuts(
        \\[{"type":"cart","title":null,"subtitle":null}]
    )).?;
    defer freeShortcuts(shortcuts);

    try testing.expectEqualStrings("null", shortcuts[0].title);
    // `has` is true, so `setLongLabel("null")` really is called.
    try testing.expectEqualStrings("null", shortcuts[0].subtitle.?);
}

test "the resolve carries the count the shim counts" {
    for ([_]usize{ 0, 1, 4 }) |count| {
        const payload = try countPayload(testing.allocator, count);
        defer testing.allocator.free(payload);

        var doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
        defer doc.deinit();
        try testing.expectEqual(@as(i64, @intCast(count)), doc.value.object.get("count").?.integer);
    }
}

test "the unsupported message is the shim's, character for character" {
    // A page may well be matching on it: there is no code in the rejection,
    // only this string.
    try testing.expectEqualStrings("App shortcuts require Android 7.1+", unsupported_message);

    const payload = try jsonString(testing.allocator, unsupported_message);
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings(
        \\"App shortcuts require Android 7.1+"
    , payload);
}

test "N_MR1 is 25, and the two actions disagree about what to do below it" {
    try testing.expectEqual(@as(i32, 25), n_mr1);

    // Recorded rather than reconciled: setShortcuts rejects below 25 and
    // clearShortcuts resolves true, so a page cannot use one answer to
    // predict the other.
    try testing.expectEqualStrings("shortcut_type", extra_shortcut_type);
}

test "the actions and globals match the shim exactly" {
    try testing.expectEqualStrings("setShortcuts", A.set_shortcuts);
    try testing.expectEqualStrings("clearShortcuts", A.clear_shortcuts);
    try testing.expectEqualStrings("_craftShortcutsResolve", resolve_global);
    try testing.expectEqualStrings("_craftShortcutsReject", reject_global);
}
