//! `craft.dialog.*` requests and replies, shared by the Windows and Linux
//! bridges.
//!
//! The option names and the reply shapes are the ones the macOS bridge
//! (`bridge_dialog.zig`) already reads and sends, so a page gets the same
//! object back on every desktop platform. Only the native panel differs, and
//! that lives in `windows_dialog.zig` and `linux_dialog.zig`.

const std = @import("std");

pub const Action = enum {
    open_file,
    open_files,
    open_folder,
    save_file,
    show_alert,
    show_confirm,

    pub fn parse(name: []const u8) ?Action {
        const names = [_]struct { name: []const u8, action: Action }{
            .{ .name = "openFile", .action = .open_file },
            .{ .name = "openFiles", .action = .open_files },
            .{ .name = "openFolder", .action = .open_folder },
            .{ .name = "saveFile", .action = .save_file },
            .{ .name = "showAlert", .action = .show_alert },
            .{ .name = "showConfirm", .action = .show_confirm },
        };
        for (names) |entry| {
            if (std.mem.eql(u8, name, entry.name)) return entry.action;
        }
        return null;
    }
};

pub const FileOptions = struct {
    title: []const u8 = "",
    defaultPath: []const u8 = "",
    /// Save panels only: the suggested file name.
    defaultName: []const u8 = "",
    buttonLabel: []const u8 = "",

    fn containsNul(self: FileOptions) bool {
        return hasNul(self.title) or hasNul(self.defaultPath) or hasNul(self.defaultName) or hasNul(self.buttonLabel);
    }
};

pub const MessageOptions = struct {
    title: []const u8 = "",
    message: []const u8 = "",
    /// `info`, `warning`, or `critical` (`error` is accepted as its alias).
    style: []const u8 = "info",
    buttons: ?[]const []const u8 = null,

    fn containsNul(self: MessageOptions) bool {
        if (self.buttons) |buttons| for (buttons) |label| {
            if (hasNul(label)) return true;
        };
        return hasNul(self.title) or hasNul(self.message) or hasNul(self.style);
    }
};

pub const Style = enum { info, warning, critical };

pub fn styleOf(options: MessageOptions) Style {
    if (std.mem.eql(u8, options.style, "warning")) return .warning;
    if (std.mem.eql(u8, options.style, "critical") or std.mem.eql(u8, options.style, "error")) return .critical;
    return .info;
}

/// Options that outlive the JSON they were read from.
pub fn Owned(comptime T: type) type {
    return struct {
        parsed: ?std.json.Parsed(T),
        value: T,

        pub fn deinit(self: *@This()) void {
            if (self.parsed) |parsed| parsed.deinit();
        }
    };
}

/// Read options the way the macOS bridge does: a payload that is missing or
/// does not parse means "no options", not a refused dialog. Text containing a
/// NUL cannot reach a native string intact, so it is treated the same way.
pub fn parse(comptime T: type, allocator: std.mem.Allocator, data: ?[]const u8) Owned(T) {
    const text = data orelse return .{ .parsed = null, .value = .{} };
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return .{ .parsed = null, .value = .{} };
    const parsed = std.json.parseFromSlice(T, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{ .parsed = null, .value = .{} };
    if (parsed.value.containsNul()) {
        parsed.deinit();
        return .{ .parsed = null, .value = .{} };
    }
    return .{ .parsed = parsed, .value = parsed.value };
}

fn hasNul(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, 0) != null;
}

/// The buttons a message dialog shows, first to last. `showAlert` defaults to
/// a single OK; `showConfirm` to OK and Cancel, where the first is "yes".
pub fn buttonsFor(options: MessageOptions, confirm: bool) []const []const u8 {
    const alert_default = [_][]const u8{"OK"};
    const confirm_default = [_][]const u8{ "OK", "Cancel" };
    if (options.buttons) |buttons| {
        if (buttons.len > 0 and buttons.len <= max_buttons) return buttons;
    }
    return if (confirm) &confirm_default else &alert_default;
}

pub const max_buttons = 8;

/// The index reported when a dialog is dismissed without choosing: the last
/// button, which is where Cancel conventionally sits.
pub fn dismissedIndex(buttons: []const []const u8) usize {
    return if (buttons.len == 0) 0 else buttons.len - 1;
}

pub const canceled_open = "{\"canceled\":true,\"filePaths\":[]}";
pub const canceled_save = "{\"canceled\":true}";

pub fn openResult(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    if (paths.len == 0) return allocator.dupe(u8, canceled_open);
    return std.json.Stringify.valueAlloc(allocator, .{ .canceled = false, .filePaths = paths }, .{});
}

pub fn saveResult(allocator: std.mem.Allocator, path: ?[]const u8) ![]u8 {
    const chosen = path orelse return allocator.dupe(u8, canceled_save);
    if (chosen.len == 0) return allocator.dupe(u8, canceled_save);
    return std.json.Stringify.valueAlloc(allocator, .{ .canceled = false, .filePath = chosen }, .{});
}

pub fn messageResult(buffer: []u8, confirm: bool, index: usize) []const u8 {
    if (confirm) return if (index == 0) "{\"ok\":true}" else "{\"ok\":false}";
    return std.fmt.bufPrint(buffer, "{{\"buttonIndex\":{d}}}", .{index}) catch "{\"buttonIndex\":0}";
}

const testing = std.testing;

test "dialog actions are the ones craft-bridge.js posts" {
    try testing.expectEqual(Action.open_folder, Action.parse("openFolder").?);
    try testing.expectEqual(Action.show_confirm, Action.parse("showConfirm").?);
    try testing.expect(Action.parse("showColorPicker") == null);
}

test "options survive the payload and unknown keys are ignored" {
    var owned = parse(FileOptions, testing.allocator,
        \\{"title":"Pick \"one\"","defaultPath":"/tmp","properties":["openFile"],"defaultName":"a.txt"}
    );
    defer owned.deinit();
    try testing.expectEqualStrings("Pick \"one\"", owned.value.title);
    try testing.expectEqualStrings("/tmp", owned.value.defaultPath);
    try testing.expectEqualStrings("a.txt", owned.value.defaultName);
}

test "a missing or broken payload means default options" {
    var none = parse(FileOptions, testing.allocator, null);
    defer none.deinit();
    try testing.expectEqualStrings("", none.value.title);
    var broken = parse(MessageOptions, testing.allocator, "{\"title\":");
    defer broken.deinit();
    try testing.expectEqualStrings("info", broken.value.style);
    var nul = parse(MessageOptions, testing.allocator, "{\"title\":\"a\\u0000b\"}");
    defer nul.deinit();
    try testing.expectEqualStrings("", nul.value.title);
}

test "buttons default per dialog and dismissal lands on the last one" {
    var plain = parse(MessageOptions, testing.allocator, "{\"message\":\"Sure?\"}");
    defer plain.deinit();
    try testing.expectEqual(@as(usize, 1), buttonsFor(plain.value, false).len);
    const confirm = buttonsFor(plain.value, true);
    try testing.expectEqualStrings("Cancel", confirm[1]);
    try testing.expectEqual(@as(usize, 1), dismissedIndex(confirm));

    var custom = parse(MessageOptions, testing.allocator, "{\"buttons\":[\"Save\",\"Discard\",\"Cancel\"],\"style\":\"error\"}");
    defer custom.deinit();
    try testing.expectEqualStrings("Discard", buttonsFor(custom.value, true)[1]);
    try testing.expectEqual(Style.critical, styleOf(custom.value));
}

test "replies match the macOS shapes" {
    const none = try openResult(testing.allocator, &.{});
    defer testing.allocator.free(none);
    try testing.expectEqualStrings(canceled_open, none);
    const picked = try openResult(testing.allocator, &.{ "/a \"b\"", "C:\\x" });
    defer testing.allocator.free(picked);
    try testing.expectEqualStrings("{\"canceled\":false,\"filePaths\":[\"/a \\\"b\\\"\",\"C:\\\\x\"]}", picked);
    const saved = try saveResult(testing.allocator, "/tmp/out.txt");
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("{\"canceled\":false,\"filePath\":\"/tmp/out.txt\"}", saved);
    const unsaved = try saveResult(testing.allocator, null);
    defer testing.allocator.free(unsaved);
    try testing.expectEqualStrings(canceled_save, unsaved);
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("{\"buttonIndex\":2}", messageResult(&buffer, false, 2));
    try testing.expectEqualStrings("{\"ok\":true}", messageResult(&buffer, true, 0));
    try testing.expectEqualStrings("{\"ok\":false}", messageResult(&buffer, true, 1));
}
