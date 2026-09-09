//! `updateWidget` and `reloadWidgets` on Android.
//!
//! A widget cannot be drawn from here — that is `CraftWidgetProvider`'s job,
//! in the app's own process, when the system asks. These two actions are the
//! page's side of that: write what the widget should say into a preferences
//! file the provider reads, then broadcast so it reads it now rather than at
//! the next scheduled update.
//!
//! ## The broadcast action is passed in rather than built
//!
//! The shim broadcasts `"{{PACKAGE_NAME}}.WIDGET_UPDATE"`, and
//! `CraftWidgetProvider` filters on the same templated constant — both are
//! compile-time strings in the generated app.
//!
//! Zig could build it from `activity.getPackageName()`, and today that is the
//! same string: the generated `build.gradle.kts` sets
//! `applicationId = "{{PACKAGE_NAME}}"` with no suffix. But an app author who
//! adds `applicationIdSuffix = ".debug"` to a build type moves the runtime
//! package name and leaves the constant where it was — and then Zig would
//! broadcast an action no filter matches. Nothing throws, nothing logs, and
//! the widget silently stops updating in debug builds only.
//!
//! So the Kotlin passes its own constant across, the way it passes the
//! database connection. The two cannot disagree if only one of them decides.
//!
//! ## `has` and `getString` are not the same question
//!
//! `updateWidget` writes a key only when `data.has(name)`, so a field the page
//! left out keeps whatever the widget last showed rather than being cleared.
//! `has` is true for an explicit null, and `getString` then returns the four
//! characters "null" — so `{"title": null}` sets the widget's title to the
//! word null rather than clearing it. That is the shim's behaviour and it is
//! reproduced.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const update_widget = "updateWidget";
    pub const reload_widgets = "reloadWidgets";
};

pub const resolve_global = "_craftWidgetResolve";
pub const reject_global = "_craftWidgetReject";

/// What each action resolves with, exactly as the shim writes it.
pub const updated_result = "{\"updated\":true}";
pub const reloaded_result = "{\"reloaded\":true}";

/// `activity.getSharedPreferences("craft_widget_prefs", MODE_PRIVATE)`.
const prefs_name = "craft_widget_prefs";
const mode_private: i32 = 0;

/// The four fields, and the preference key each is written to.
///
/// The names differ on the two sides — `title` in, `widget_title` out — which
/// is the sort of mapping that goes wrong silently, so it lives in one table
/// rather than in four `if` blocks.
pub const fields = [_]Field{
    .{ .name = "title", .key = "widget_title" },
    .{ .name = "subtitle", .key = "widget_subtitle" },
    .{ .name = "value", .key = "widget_value" },
    .{ .name = "icon", .key = "widget_icon" },
};

pub const Field = struct {
    name: []const u8,
    key: [:0]const u8,
};

/// What to write, one slot per `fields` entry; null means the page did not
/// mention that field and the widget keeps what it had.
pub const Update = [fields.len]?[]const u8;

/// Read the declared shape, or null where only `org.json` would.
///
/// `getString` coerces a number or a nested object into its string form, and
/// `Double.toString` and `JSONObject.toString` are not things to reproduce
/// from memory — those payloads go back to the shim. An explicit null is the
/// one coercion carried over: `has` says the key is there, and `getString`
/// returns the four characters "null".
pub fn parseUpdate(value: std.json.Value) ?Update {
    const object = switch (value) {
        .object => |o| o,
        else => return null,
    };

    var update: Update = @splat(null);
    inline for (fields, 0..) |field, i| {
        if (object.get(field.name)) |found| {
            update[i] = switch (found) {
                .string => |text| text,
                .null => "null",
                else => return null,
            };
        }
    }
    return update;
}

/// Write the mentioned fields and apply.
pub fn writeUpdate(j: Jni, allocator: std.mem.Allocator, activity: jobject, update: Update) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const prefs = try j.callObjectMethodA(
        activity,
        try j.methodId(
            try j.objectClass(activity),
            "getSharedPreferences",
            "(Ljava/lang/String;I)Landroid/content/SharedPreferences;",
        ),
        &.{ .{ .l = try j.newStringUtf(prefs_name) }, .{ .i = mode_private } },
    );

    const editor = try j.callObjectMethod(
        prefs,
        try j.methodId(
            try j.objectClass(prefs),
            "edit",
            "()Landroid/content/SharedPreferences$Editor;",
        ),
    );
    const editor_cls = try j.objectClass(editor);
    const put_string = try j.methodId(
        editor_cls,
        "putString",
        "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;",
    );

    inline for (fields, 0..) |field, i| {
        if (update[i]) |text| {
            try j.pushLocalFrame(4);
            defer _ = j.popLocalFrame(null);
            _ = try j.callObjectMethodA(editor, put_string, &.{
                .{ .l = try j.newStringUtf(field.key) },
                .{ .l = try javaString(j, allocator, text) },
            });
        }
    }

    // `apply`, as the shim does — the write lands on a background thread and
    // the resolve is a promise about having asked.
    try j.callVoidMethodA(editor, try j.methodId(editor_cls, "apply", "()V"), &.{});
}

/// `Intent(action).setPackage(activity.packageName)`, then `sendBroadcast`.
pub fn broadcast(j: Jni, allocator: std.mem.Allocator, activity: jobject, action: []const u8) !void {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const intent_cls = try j.findClass("android/content/Intent");
    const intent = try j.newObjectA(
        intent_cls,
        try j.methodId(intent_cls, "<init>", "(Ljava/lang/String;)V"),
        &.{.{ .l = try javaString(j, allocator, action) }},
    );

    const activity_cls = try j.objectClass(activity);
    const package_name = try j.callObjectMethod(
        activity,
        try j.methodId(activity_cls, "getPackageName", "()Ljava/lang/String;"),
    );

    // `setPackage` keeps the broadcast inside this app. It is a delivery
    // restriction and not the action, which is why the runtime package name is
    // safe here and would not be safe as the action itself.
    _ = try j.callObjectMethodA(
        intent,
        try j.methodId(intent_cls, "setPackage", "(Ljava/lang/String;)Landroid/content/Intent;"),
        &.{.{ .l = package_name }},
    );

    try j.callVoidMethodA(
        activity,
        try j.methodId(activity_cls, "sendBroadcast", "(Landroid/content/Intent;)V"),
        &.{.{ .l = intent }},
    );
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

fn parsed(json: []const u8) !?Update {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var doc = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    defer doc.deinit();

    const update = parseUpdate(doc.value) orelse return null;

    // Copied out, because the slices borrow from the arena.
    var copy: Update = @splat(null);
    for (update, 0..) |slot, i| {
        if (slot) |text| copy[i] = try testing.allocator.dupe(u8, text);
    }
    return copy;
}

fn freeUpdate(update: Update) void {
    for (update) |slot| {
        if (slot) |text| testing.allocator.free(text);
    }
}

test "every field maps to its widget_ key" {
    const update = (try parsed(
        \\{"title":"Sales","subtitle":"today","value":"42","icon":"chart"}
    )).?;
    defer freeUpdate(update);

    try testing.expectEqualStrings("Sales", update[0].?);
    try testing.expectEqualStrings("today", update[1].?);
    try testing.expectEqualStrings("42", update[2].?);
    try testing.expectEqualStrings("chart", update[3].?);

    // The mapping itself, which is what a rewrite would get subtly wrong.
    try testing.expectEqualStrings("title", fields[0].name);
    try testing.expectEqualStrings("widget_title", fields[0].key);
    try testing.expectEqualStrings("subtitle", fields[1].name);
    try testing.expectEqualStrings("widget_subtitle", fields[1].key);
    try testing.expectEqualStrings("value", fields[2].name);
    try testing.expectEqualStrings("widget_value", fields[2].key);
    try testing.expectEqualStrings("icon", fields[3].name);
    try testing.expectEqualStrings("widget_icon", fields[3].key);
}

test "an unmentioned field is left alone rather than cleared" {
    // `if (data.has("title"))` — a page updating only the value keeps the
    // title the widget is already showing.
    const update = (try parsed(
        \\{"value":"42"}
    )).?;
    defer freeUpdate(update);

    try testing.expect(update[0] == null);
    try testing.expect(update[1] == null);
    try testing.expectEqualStrings("42", update[2].?);
    try testing.expect(update[3] == null);
}

test "an empty string clears the field, where an absent one does not" {
    // The distinction the null above exists to preserve: "" is a value the
    // page chose, and it is written.
    const update = (try parsed(
        \\{"title":""}
    )).?;
    defer freeUpdate(update);

    try testing.expect(update[0] != null);
    try testing.expectEqualStrings("", update[0].?);
}

test "an explicit null sets the field to the word null" {
    // `has` is true for a JSON null and `getString` returns "null", so this
    // does not clear the title — it sets it to four characters. Reproduced
    // because `JSON.stringify({title: null})` is an ordinary thing to send.
    const update = (try parsed(
        \\{"title":null}
    )).?;
    defer freeUpdate(update);

    try testing.expectEqualStrings("null", update[0].?);
}

test "a shape only org.json would stringify is handed back" {
    for ([_][]const u8{
        \\{"title":1.5}
        ,
        \\{"value":42}
        ,
        \\{"icon":true}
        ,
        \\{"title":{"a":1}}
        ,
        \\{"title":["a"]}
        ,
        \\[]
        ,
        \\"Sales"
        ,
    }) |payload| {
        if (try parsed(payload)) |update| {
            freeUpdate(update);
            std.debug.print("payload was served rather than handed back: {s}\n", .{payload});
            return error.CoercedShapeAccepted;
        }
    }
}

test "an empty object writes nothing and still resolves" {
    const update = (try parsed("{}")).?;
    defer freeUpdate(update);
    for (update) |slot| try testing.expect(slot == null);
}

test "the results are the shim's constants" {
    try testing.expectEqualStrings("{\"updated\":true}", updated_result);
    try testing.expectEqualStrings("{\"reloaded\":true}", reloaded_result);

    inline for (.{ updated_result, reloaded_result }) |result| {
        var doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
        defer doc.deinit();
        try testing.expectEqual(@as(usize, 1), doc.value.object.count());
    }
}

test "the preferences file is the one CraftWidgetProvider reads" {
    try testing.expectEqualStrings("craft_widget_prefs", prefs_name);
    try testing.expectEqual(@as(i32, 0), mode_private);
}

test "the actions and globals match the shim exactly" {
    try testing.expectEqualStrings("updateWidget", A.update_widget);
    try testing.expectEqualStrings("reloadWidgets", A.reload_widgets);
    try testing.expectEqualStrings("_craftWidgetResolve", resolve_global);
    try testing.expectEqualStrings("_craftWidgetReject", reject_global);
}
