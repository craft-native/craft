//! The application menu, as the Windows and Linux bridges hold it.
//!
//! macOS hands a `craft.menu.set()` payload straight to AppKit and lets
//! `NSMenu` be the model. Win32 and GTK have no equivalent to walk back
//! through by item id, so the model lives here: the payload is parsed once
//! into this structure, each platform draws a menu bar from it, and every
//! later `craft.menu.*` call edits the model and asks the platform to draw
//! again. The platforms never parse JSON and never disagree about what an
//! item is.
//!
//! Pure: no Win32, no GTK. That is what lets the contract with
//! `craft-bridge.js` be tested on any host, including the macOS one that
//! never runs this code in a shipped binary.

const std = @import("std");
const key_codes = @import("key_codes.zig");

/// Menu commands are numbered from here. Win32 delivers a 16-bit command id
/// in `WM_COMMAND`; starting above the dialog ids (`IDOK` and friends) keeps
/// a stray dialog notification from ever naming a menu item.
pub const first_command: u16 = 0x1000;
pub const max_commands: usize = 2048;

/// What the operating system performs for an item, without asking the page.
pub const Role = enum {
    about,
    settings,
    quit,
    undo,
    redo,
    cut,
    copy,
    paste,
    delete,
    selectAll,
    close,
    minimize,
    zoom,
    fullscreen,
    reload,
    forceReload,

    /// Roles the focused web content performs itself. Their accelerator is
    /// drawn beside the item but never intercepted: Ctrl+C has to reach the
    /// page exactly as it does in a browser, or a text field stops copying.
    pub fn isEditing(self: Role) bool {
        return switch (self) {
            .undo, .redo, .cut, .copy, .paste, .delete, .selectAll => true,
            else => false,
        };
    }
};

const role_names = [_]struct { name: []const u8, role: Role }{
    .{ .name = "about", .role = .about },
    .{ .name = "settings", .role = .settings },
    .{ .name = "preferences", .role = .settings },
    .{ .name = "quit", .role = .quit },
    .{ .name = "undo", .role = .undo },
    .{ .name = "redo", .role = .redo },
    .{ .name = "cut", .role = .cut },
    .{ .name = "copy", .role = .copy },
    .{ .name = "paste", .role = .paste },
    .{ .name = "delete", .role = .delete },
    .{ .name = "selectAll", .role = .selectAll },
    .{ .name = "close", .role = .close },
    .{ .name = "minimize", .role = .minimize },
    .{ .name = "zoom", .role = .zoom },
    .{ .name = "fullscreen", .role = .fullscreen },
    .{ .name = "reload", .role = .reload },
    .{ .name = "forceReload", .role = .forceReload },
};

/// Roles that only mean something on macOS: an application that hides, a
/// window list to bring forward. An item naming one is left out of the menu
/// bar here, where there is nothing for it to do.
const mac_only_roles = [_][]const u8{ "hide", "hideOthers", "showAll", "front" };

pub fn roleFor(name: []const u8) ?Role {
    for (role_names) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry.role;
    }
    return null;
}

fn isMacOnlyRole(name: []const u8) bool {
    for (mac_only_roles) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry)) return true;
    }
    return false;
}

pub const NamedKey = enum {
    enter,
    tab,
    space,
    backspace,
    escape,
    forward_delete,
    home,
    end,
    page_up,
    page_down,
    left,
    right,
    up,
    down,
};

pub const Key = union(enum) {
    /// An uppercase ASCII letter, a digit, or a punctuation character.
    char: u8,
    named: NamedKey,
    /// F1 is 1.
    function: u8,

    pub fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .char => |value| b == .char and b.char == value,
            .named => |value| b == .named and b.named == value,
            .function => |value| b == .function and b.function == value,
        };
    }
};

/// A menu accelerator. There is no separate command modifier: `cmd`,
/// `CmdOrCtrl` and `ctrl` all mean Control here, so a menu written once for
/// macOS as `cmd+n` is Ctrl+N on Windows and Linux without the app saying so.
pub const Shortcut = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    key: Key,

    pub fn eql(a: Shortcut, b: Shortcut) bool {
        return a.ctrl == b.ctrl and a.alt == b.alt and a.shift == b.shift and a.key.eql(b.key);
    }

    /// `Ctrl+Shift+N`, the way both platforms draw it beside the item.
    pub fn format(self: Shortcut, buffer: []u8) []const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        if (self.ctrl) writer.writeAll("Ctrl+") catch return "";
        if (self.alt) writer.writeAll("Alt+") catch return "";
        if (self.shift) writer.writeAll("Shift+") catch return "";
        switch (self.key) {
            .char => |value| writer.writeByte(value) catch return "",
            .function => |value| writer.print("F{d}", .{value}) catch return "",
            .named => |value| writer.writeAll(switch (value) {
                .enter => "Enter",
                .tab => "Tab",
                .space => "Space",
                .backspace => "Backspace",
                .escape => "Esc",
                .forward_delete => "Del",
                .home => "Home",
                .end => "End",
                .page_up => "PgUp",
                .page_down => "PgDn",
                .left => "Left",
                .right => "Right",
                .up => "Up",
                .down => "Down",
            }) catch return "",
        }
        return writer.buffered();
    }

    /// The Win32 virtual-key code.
    pub fn windowsVirtualKey(self: Shortcut) u16 {
        return switch (self.key) {
            .char => |value| switch (value) {
                'A'...'Z', '0'...'9' => value,
                ';' => 0xBA,
                '=' => 0xBB,
                ',' => 0xBC,
                '-' => 0xBD,
                '.' => 0xBE,
                '/' => 0xBF,
                '`' => 0xC0,
                '[' => 0xDB,
                '\\' => 0xDC,
                ']' => 0xDD,
                '\'' => 0xDE,
                else => 0,
            },
            .function => |value| 0x70 + @as(u16, value) - 1,
            .named => |value| switch (value) {
                .enter => 0x0D,
                .tab => 0x09,
                .space => 0x20,
                .backspace => 0x08,
                .escape => 0x1B,
                .forward_delete => 0x2E,
                .home => 0x24,
                .end => 0x23,
                .page_up => 0x21,
                .page_down => 0x22,
                .left => 0x25,
                .right => 0x27,
                .up => 0x26,
                .down => 0x28,
            },
        };
    }

    /// The GDK key value. Letters are lowercase: GTK matches an accelerator
    /// against the unshifted symbol and carries Shift as a modifier.
    pub fn gdkKeyval(self: Shortcut) u32 {
        return switch (self.key) {
            .char => |value| std.ascii.toLower(value),
            .function => |value| 0xFFBE + @as(u32, value) - 1,
            .named => |value| switch (value) {
                .enter => 0xFF0D,
                .tab => 0xFF09,
                .space => 0x20,
                .backspace => 0xFF08,
                .escape => 0xFF1B,
                .forward_delete => 0xFFFF,
                .home => 0xFF50,
                .end => 0xFF57,
                .page_up => 0xFF55,
                .page_down => 0xFF56,
                .left => 0xFF51,
                .right => 0xFF53,
                .up => 0xFF52,
                .down => 0xFF54,
            },
        };
    }

    /// GDK modifier mask: Shift is bit 0, Control bit 2, Mod1 (Alt) bit 3.
    pub fn gdkModifiers(self: Shortcut) u32 {
        var mask: u32 = 0;
        if (self.shift) mask |= 1 << 0;
        if (self.ctrl) mask |= 1 << 2;
        if (self.alt) mask |= 1 << 3;
        return mask;
    }
};

fn keyFromCanonical(name: []const u8) ?Key {
    if (name.len == 1) {
        const value = std.ascii.toUpper(name[0]);
        return switch (value) {
            'A'...'Z', '0'...'9', ';', '=', ',', '-', '.', '/', '`', '[', '\\', ']', '\'' => .{ .char = value },
            else => null,
        };
    }
    if (name.len >= 2 and name[0] == 'F') {
        if (std.fmt.parseInt(u8, name[1..], 10)) |number| {
            if (number >= 1 and number <= 20) return .{ .function = number };
        } else |_| {}
    }
    const named = [_]struct { name: []const u8, key: NamedKey }{
        .{ .name = "Return", .key = .enter },
        .{ .name = "Tab", .key = .tab },
        .{ .name = "Space", .key = .space },
        // key_codes.zig names the Backspace key "Delete", as a Mac keyboard does.
        .{ .name = "Delete", .key = .backspace },
        .{ .name = "Escape", .key = .escape },
        .{ .name = "ForwardDelete", .key = .forward_delete },
        .{ .name = "Home", .key = .home },
        .{ .name = "End", .key = .end },
        .{ .name = "PageUp", .key = .page_up },
        .{ .name = "PageDown", .key = .page_down },
        .{ .name = "Left", .key = .left },
        .{ .name = "Right", .key = .right },
        .{ .name = "Up", .key = .up },
        .{ .name = "Down", .key = .down },
    };
    for (named) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return .{ .named = entry.key };
    }
    return null;
}

/// Parse `cmd+shift+n`. Null for anything that names no key this menu can
/// bind: the item is still drawn, without an accelerator, rather than refused.
pub fn parseShortcut(text: []const u8) ?Shortcut {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    var shortcut: Shortcut = .{ .key = .{ .char = 0 } };
    var key_part: ?[]const u8 = null;
    // `cmd++` is how "command and plus" is written when `+` is the separator.
    const body = if (std.mem.endsWith(u8, trimmed, "++")) blk: {
        key_part = "plus";
        break :blk trimmed[0 .. trimmed.len - 2];
    } else trimmed;
    var parts = std.mem.splitScalar(u8, body, '+');
    var pending: ?[]const u8 = null;
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) return null;
        if (pending) |modifier| {
            if (!applyModifier(modifier, &shortcut)) return null;
        }
        pending = part;
    }
    if (key_part == null) {
        key_part = pending;
    } else if (pending) |modifier| {
        if (!applyModifier(modifier, &shortcut)) return null;
    }
    const code = key_codes.codeFor(key_part orelse return null) orelse return null;
    shortcut.key = keyFromCanonical(key_codes.nameFor(code) orelse return null) orelse return null;
    return shortcut;
}

fn applyModifier(name: []const u8, shortcut: *Shortcut) bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "cmd") or eq(name, "command") or eq(name, "cmdorctrl") or eq(name, "commandorcontrol") or
        eq(name, "mod") or eq(name, "meta") or eq(name, "super") or eq(name, "win") or
        eq(name, "ctrl") or eq(name, "control"))
    {
        shortcut.ctrl = true;
    } else if (eq(name, "alt") or eq(name, "option") or eq(name, "opt")) {
        shortcut.alt = true;
    } else if (eq(name, "shift")) {
        shortcut.shift = true;
    } else return false;
    return true;
}

pub const Item = struct {
    /// Zero for a separator.
    command: u16 = 0,
    /// What `craft.menu.onAction` reports. Empty for a separator.
    id: []const u8 = "",
    label: []const u8 = "",
    shortcut: ?Shortcut = null,
    role: ?Role = null,
    separator: bool = false,
    enabled: bool = true,
    checked: bool = false,
};

pub const Menu = struct {
    label: []const u8,
    items: std.ArrayListUnmanaged(Item) = .empty,
};

const ParsedItem = struct {
    id: ?[]const u8 = null,
    label: ?[]const u8 = null,
    shortcut: ?[]const u8 = null,
    separator: ?bool = null,
    role: ?[]const u8 = null,
    enabled: ?bool = null,
    checked: ?bool = null,
};
const ParsedMenu = struct {
    label: ?[]const u8 = null,
    items: ?[]const ParsedItem = null,
};
const ParsedAppMenu = struct {
    menus: ?[]const ParsedMenu = null,
};
const ParsedAdd = struct {
    menuId: []const u8 = "",
    itemId: []const u8 = "",
    label: []const u8 = "",
    shortcut: ?[]const u8 = null,
    index: i64 = -1,
};
const ParsedTarget = struct {
    itemId: []const u8 = "",
    label: ?[]const u8 = null,
};

pub const Error = error{ InvalidJSON, MissingData, OutOfMemory, TooManyItems };

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    menus: std.ArrayListUnmanaged(Menu) = .empty,
    next_command: u16 = first_command,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn isEmpty(self: *const Model) bool {
        return self.menus.items.len == 0;
    }

    fn allocateCommand(self: *Model) Error!u16 {
        if (self.next_command - first_command >= max_commands) return error.TooManyItems;
        defer self.next_command += 1;
        return self.next_command;
    }

    fn buildItem(self: *Model, parsed: ParsedItem) Error!?Item {
        const allocator = self.arena.allocator();
        if (parsed.separator orelse false) return .{ .separator = true };
        if (parsed.role) |name| {
            if (isMacOnlyRole(name)) return null;
        }
        const role: ?Role = if (parsed.role) |name| roleFor(name) else null;
        // A role item needs no id: nothing is reported back for it. An item
        // naming a role this build does not know falls back to an ordinary
        // item identified by that name, so a newer page degrades to an event.
        const id = parsed.id orelse parsed.role orelse return null;
        return .{
            .command = try self.allocateCommand(),
            .id = try allocator.dupe(u8, id),
            .label = try allocator.dupe(u8, parsed.label orelse id),
            .shortcut = if (parsed.shortcut) |text| parseShortcut(text) else null,
            .role = role,
            .enabled = parsed.enabled orelse true,
            .checked = parsed.checked orelse false,
        };
    }

    /// Replace the whole menu bar from a `setAppMenu` payload.
    pub fn set(self: *Model, data: []const u8) Error!void {
        const backing = self.arena.child_allocator;
        const parsed = std.json.parseFromSlice(ParsedAppMenu, backing, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidJSON;
        defer parsed.deinit();

        // Build into a fresh arena and swap, so a payload that fails half way
        // leaves the menu bar that was already showing.
        var next = Model.init(backing);
        errdefer next.arena.deinit();
        const allocator = next.arena.allocator();
        for (parsed.value.menus orelse &[_]ParsedMenu{}) |menu_def| {
            const label = menu_def.label orelse continue;
            var menu: Menu = .{ .label = try allocator.dupe(u8, label) };
            for (menu_def.items orelse &[_]ParsedItem{}) |item_def| {
                if (try next.buildItem(item_def)) |item| try menu.items.append(allocator, item);
            }
            try next.menus.append(allocator, menu);
        }
        self.arena.deinit();
        self.* = next;
    }

    fn findMenu(self: *Model, label: []const u8) ?*Menu {
        for (self.menus.items) |*menu| {
            if (std.mem.eql(u8, menu.label, label)) return menu;
        }
        return null;
    }

    fn findItem(self: *Model, id: []const u8) ?*Item {
        if (id.len == 0) return null;
        for (self.menus.items) |*menu| {
            for (menu.items.items) |*item| {
                if (!item.separator and std.mem.eql(u8, item.id, id)) return item;
            }
        }
        return null;
    }

    /// `addMenuItem`: `{menuId, itemId, label, shortcut?, index}`. `menuId` is
    /// the label of the menu to add to, as on macOS. True if the bar changed.
    pub fn addItem(self: *Model, data: []const u8) Error!bool {
        const backing = self.arena.child_allocator;
        const parsed = std.json.parseFromSlice(ParsedAdd, backing, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidJSON;
        defer parsed.deinit();
        const value = parsed.value;
        if (value.itemId.len == 0) return error.MissingData;
        const menu = self.findMenu(value.menuId) orelse return false;
        const item = (try self.buildItem(.{
            .id = value.itemId,
            .label = if (value.label.len > 0) value.label else null,
            .shortcut = value.shortcut,
        })) orelse return false;
        const allocator = self.arena.allocator();
        const count = menu.items.items.len;
        const at: usize = if (value.index < 0 or value.index > count) count else @intCast(value.index);
        try menu.items.insert(allocator, at, item);
        return true;
    }

    fn target(self: *Model, data: []const u8) Error!?struct { item: *Item, label: ?[]const u8 } {
        const backing = self.arena.child_allocator;
        const parsed = std.json.parseFromSlice(ParsedTarget, backing, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidJSON;
        defer parsed.deinit();
        const item = self.findItem(parsed.value.itemId) orelse return null;
        const label: ?[]const u8 = if (parsed.value.label) |text|
            try self.arena.allocator().dupe(u8, text)
        else
            null;
        return .{ .item = item, .label = label };
    }

    pub fn removeItem(self: *Model, data: []const u8) Error!bool {
        const found = (try self.target(data)) orelse return false;
        for (self.menus.items) |*menu| {
            for (menu.items.items, 0..) |*item, index| {
                if (item == found.item) {
                    _ = menu.items.orderedRemove(index);
                    return true;
                }
            }
        }
        return false;
    }

    pub fn setEnabled(self: *Model, data: []const u8, enabled: bool) Error!bool {
        const found = (try self.target(data)) orelse return false;
        found.item.enabled = enabled;
        return true;
    }

    pub fn setChecked(self: *Model, data: []const u8, checked: bool) Error!bool {
        const found = (try self.target(data)) orelse return false;
        found.item.checked = checked;
        return true;
    }

    pub fn setLabel(self: *Model, data: []const u8) Error!bool {
        const found = (try self.target(data)) orelse return false;
        found.item.label = found.label orelse return error.MissingData;
        return true;
    }

    pub fn byCommand(self: *const Model, command: u16) ?*const Item {
        if (command < first_command) return null;
        for (self.menus.items) |*menu| {
            for (menu.items.items) |*item| {
                if (item.command == command) return item;
            }
        }
        return null;
    }

    /// The item a Win32 key press activates: a virtual-key code and the
    /// modifiers held with it.
    pub fn byVirtualKey(self: *const Model, virtual_key: u16, ctrl: bool, alt: bool, shift: bool) ?*const Item {
        if (virtual_key == 0) return null;
        for (self.menus.items) |*menu| {
            for (menu.items.items) |*item| {
                const shortcut = item.shortcut orelse continue;
                if (item.separator or !item.enabled) continue;
                if (item.role) |role| if (role.isEditing()) continue;
                if (shortcut.windowsVirtualKey() == virtual_key and shortcut.ctrl == ctrl and
                    shortcut.alt == alt and shortcut.shift == shift) return item;
            }
        }
        return null;
    }

    /// The enabled item a key press activates, if any. Editing roles never
    /// match: those keys belong to the focused web content.
    pub fn byShortcut(self: *const Model, pressed: Shortcut) ?*const Item {
        for (self.menus.items) |*menu| {
            for (menu.items.items) |*item| {
                const shortcut = item.shortcut orelse continue;
                if (item.separator or !item.enabled) continue;
                if (item.role) |role| if (role.isEditing()) continue;
                if (shortcut.eql(pressed)) return item;
            }
        }
        return null;
    }
};

/// What choosing an item does, decided once for both platforms.
pub const Activation = union(enum) {
    /// Report the id to the page as `craft:menu:action`.
    action: []const u8,
    /// Dispatch `craft:settings:open`.
    settings,
    /// The platform performs it.
    role: Role,
};

pub fn activationFor(item: *const Item) Activation {
    const role = item.role orelse return .{ .action = item.id };
    return switch (role) {
        // No standard About panel exists on either platform. The page gets
        // the item's id and shows its own.
        .about => .{ .action = item.id },
        .settings => .settings,
        else => .{ .role = role },
    };
}

/// The script that reports a chosen item to the page.
pub fn actionScript(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    const literal = try std.json.Stringify.valueAlloc(allocator, id, .{});
    defer allocator.free(literal);
    return std.fmt.allocPrint(allocator, "if (window.__craftMenuCallback) window.__craftMenuCallback({s});", .{literal});
}

pub const settings_script = "if (window.__craftSettingsOpen) window.__craftSettingsOpen();";

// ---------------------------------------------------------------------------
// Context menus
// ---------------------------------------------------------------------------

pub const ContextItem = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    separator: bool = false,
    enabled: bool = true,
    checked: bool = false,
    shortcut: ?Shortcut = null,
    submenu: []const ContextItem = &.{},
};

/// A parsed `nativeUI.showContextMenu` request. Owns its strings.
pub const ContextMenu = struct {
    arena: std.heap.ArenaAllocator,
    target_id: []const u8,
    target_type: []const u8,
    x: i32,
    y: i32,
    items: []const ContextItem,

    pub fn deinit(self: *ContextMenu) void {
        self.arena.deinit();
    }

    /// Items are numbered depth-first from 1, separators included, so the
    /// number a platform gets back from its popup names exactly one item.
    pub fn idFor(self: *const ContextMenu, number: usize) ?[]const u8 {
        var counter: usize = 0;
        return findNumbered(self.items, number, &counter);
    }

    fn findNumbered(items: []const ContextItem, number: usize, counter: *usize) ?[]const u8 {
        for (items) |*item| {
            counter.* += 1;
            if (counter.* == number) return if (item.separator or item.submenu.len > 0) null else item.id;
            if (findNumbered(item.submenu, number, counter)) |id| return id;
            if (counter.* >= number) return null;
        }
        return null;
    }

    /// The reply and event detail, in the shape macOS sends.
    pub fn resultJson(self: *const ContextMenu, allocator: std.mem.Allocator, chosen: ?[]const u8) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, .{
            .id = chosen,
            .targetId = self.target_id,
            .targetType = self.target_type,
        }, .{});
    }
};

fn numberField(value: std.json.Value) ?i32 {
    return switch (value) {
        .integer => |number| std.math.cast(i32, number),
        .float => |number| if (std.math.isFinite(number) and @abs(number) < 1_000_000) @intFromFloat(number) else null,
        else => null,
    };
}

fn parseContextItems(allocator: std.mem.Allocator, value: std.json.Value, depth: u8, budget: *usize) Error![]const ContextItem {
    if (value != .array) return error.InvalidJSON;
    var items: std.ArrayListUnmanaged(ContextItem) = .empty;
    for (value.array.items) |entry| {
        if (entry != .object) return error.InvalidJSON;
        if (budget.* == 0) return error.TooManyItems;
        budget.* -= 1;
        const object = entry.object;
        const kind: []const u8 = if (object.get("type")) |kind_value|
            (if (kind_value == .string) kind_value.string else return error.InvalidJSON)
        else
            "standard";
        if (std.mem.eql(u8, kind, "separator")) {
            try items.append(allocator, .{ .separator = true });
            continue;
        }
        const id = object.get("id") orelse return error.MissingData;
        const title = object.get("title") orelse return error.MissingData;
        if (id != .string or title != .string) return error.InvalidJSON;
        var item: ContextItem = .{
            .id = try allocator.dupe(u8, id.string),
            .title = try allocator.dupe(u8, title.string),
        };
        if (object.get("enabled")) |flag| if (flag == .bool) {
            item.enabled = flag.bool;
        };
        if (object.get("checked")) |flag| if (flag == .bool) {
            item.checked = flag.bool;
        };
        if (object.get("shortcut")) |text| if (text == .string) {
            item.shortcut = parseShortcut(text.string);
        };
        if (std.mem.eql(u8, kind, "submenu")) {
            // One level, as on macOS.
            if (object.get("submenu")) |nested| {
                if (depth == 0) item.submenu = try parseContextItems(allocator, nested, depth + 1, budget);
            }
        }
        try items.append(allocator, item);
    }
    return items.toOwnedSlice(allocator);
}

pub fn parseContextMenu(backing: std.mem.Allocator, data: []const u8) Error!ContextMenu {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{}) catch return error.InvalidJSON;
    if (parsed != .object) return error.InvalidJSON;
    const root = parsed.object;
    const target_id = root.get("targetId") orelse std.json.Value{ .string = "" };
    const target_type = root.get("targetType") orelse std.json.Value{ .string = "general" };
    if (target_id != .string or target_type != .string) return error.InvalidJSON;
    var budget: usize = 256;
    const items = try parseContextItems(allocator, root.get("items") orelse return error.MissingData, 0, &budget);
    if (items.len == 0) return error.MissingData;
    return .{
        .arena = arena,
        .target_id = target_id.string,
        .target_type = target_type.string,
        .x = if (root.get("x")) |value| numberField(value) orelse 0 else 0,
        .y = if (root.get("y")) |value| numberField(value) orelse 0 else 0,
        .items = items,
    };
}

pub fn contextEventScript(allocator: std.mem.Allocator, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "window.dispatchEvent(new CustomEvent('craft:contextmenu:action',{{detail:{s}}}))",
        .{result_json},
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a menu written for macOS binds Control on Windows and Linux" {
    const shortcut = parseShortcut("cmd+shift+n").?;
    try testing.expect(shortcut.ctrl and shortcut.shift and !shortcut.alt);
    try testing.expect(shortcut.key.eql(.{ .char = 'N' }));
    try testing.expectEqual(@as(u16, 'N'), shortcut.windowsVirtualKey());
    try testing.expectEqual(@as(u32, 'n'), shortcut.gdkKeyval());
    try testing.expectEqual(@as(u32, 0b101), shortcut.gdkModifiers());
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+N", shortcut.format(&buffer));
    try testing.expect(parseShortcut("CmdOrCtrl+N").?.eql(parseShortcut("ctrl+n").?));
}

test "named keys, function keys and the plus key resolve" {
    try testing.expectEqual(@as(u16, 0x08), parseShortcut("cmd+delete").?.windowsVirtualKey());
    try testing.expectEqual(@as(u32, 0xFFFF), parseShortcut("ForwardDelete").?.gdkKeyval());
    try testing.expectEqual(@as(u16, 0x74), parseShortcut("F5").?.windowsVirtualKey());
    try testing.expectEqual(@as(u32, 0xFFC8), parseShortcut("F11").?.gdkKeyval());
    try testing.expectEqual(@as(u16, 0xBB), parseShortcut("cmd++").?.windowsVirtualKey());
    try testing.expectEqual(@as(u16, 0xBD), parseShortcut("cmd+minus").?.windowsVirtualKey());
    try testing.expectEqual(@as(u16, 0x26), parseShortcut("alt+up").?.windowsVirtualKey());
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("Alt+Up", parseShortcut("alt+up").?.format(&buffer));
}

test "an unusable shortcut leaves the item without an accelerator" {
    try testing.expect(parseShortcut("") == null);
    try testing.expect(parseShortcut("cmd+") == null);
    try testing.expect(parseShortcut("hyper+n") == null);
    try testing.expect(parseShortcut("cmd+nosuchkey") == null);
}

test "the model is built from the payload craft.menu.set posts" {
    var model = Model.init(testing.allocator);
    defer model.deinit();
    try model.set(
        \\{"menus":[{"label":"File","items":[
        \\  {"id":"new","label":"New","shortcut":"cmd+n"},
        \\  {"separator":true},
        \\  {"label":"Copy","role":"copy","shortcut":"cmd+c"},
        \\  {"role":"hide","label":"Hide"},
        \\  {"role":"quit","label":"Quit","shortcut":"cmd+q"},
        \\  {"label":"No id and no role"}
        \\]},{"items":[{"id":"orphan","label":"Unlabelled menu"}]}]}
    );
    try testing.expectEqual(@as(usize, 1), model.menus.items.len);
    const items = model.menus.items[0].items.items;
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("new", items[0].id);
    try testing.expectEqual(first_command, items[0].command);
    try testing.expect(items[1].separator);
    try testing.expectEqual(Role.copy, items[2].role.?);
    try testing.expectEqualStrings("copy", items[2].id);
    try testing.expectEqual(Role.quit, items[3].role.?);

    try testing.expectEqualStrings("new", model.byCommand(first_command).?.id);
    try testing.expect(model.byCommand(first_command - 1) == null);
    // Ctrl+C is drawn but stays with the page; Ctrl+Q and Ctrl+N are ours.
    try testing.expect(model.byShortcut(parseShortcut("ctrl+c").?) == null);
    try testing.expectEqualStrings("quit", model.byShortcut(parseShortcut("ctrl+q").?).?.id);
    try testing.expectEqualStrings("new", model.byShortcut(parseShortcut("ctrl+n").?).?.id);
}

test "a rejected payload keeps the menu that was showing" {
    var model = Model.init(testing.allocator);
    defer model.deinit();
    try model.set("{\"menus\":[{\"label\":\"File\",\"items\":[{\"id\":\"a\",\"label\":\"A\"}]}]}");
    try testing.expectError(error.InvalidJSON, model.set("{\"menus\":"));
    try testing.expectEqualStrings("a", model.menus.items[0].items.items[0].id);
    try model.set("{}");
    try testing.expect(model.isEmpty());
}

test "items are added, relabelled, toggled and removed by id" {
    var model = Model.init(testing.allocator);
    defer model.deinit();
    try model.set("{\"menus\":[{\"label\":\"File\",\"items\":[{\"id\":\"a\",\"label\":\"A\"},{\"id\":\"c\",\"label\":\"C\"}]}]}");
    try testing.expect(try model.addItem("{\"menuId\":\"File\",\"itemId\":\"b\",\"label\":\"B\",\"index\":1,\"shortcut\":\"cmd+b\"}"));
    try testing.expect(!try model.addItem("{\"menuId\":\"Edit\",\"itemId\":\"x\",\"label\":\"X\",\"index\":-1}"));
    try testing.expect(try model.addItem("{\"menuId\":\"File\",\"itemId\":\"d\",\"label\":\"D\",\"index\":-1}"));
    const items = model.menus.items[0].items.items;
    try testing.expectEqualStrings("b", items[1].id);
    try testing.expectEqualStrings("d", items[3].id);

    try testing.expect(try model.setEnabled("{\"itemId\":\"b\"}", false));
    try testing.expect(model.byShortcut(parseShortcut("ctrl+b").?) == null);
    try testing.expect(try model.setEnabled("{\"itemId\":\"b\"}", true));
    try testing.expect(model.byShortcut(parseShortcut("ctrl+b").?) != null);
    try testing.expect(try model.setChecked("{\"itemId\":\"a\"}", true));
    try testing.expect(model.menus.items[0].items.items[0].checked);
    try testing.expect(try model.setLabel("{\"itemId\":\"a\",\"label\":\"Alpha\"}"));
    try testing.expectEqualStrings("Alpha", model.menus.items[0].items.items[0].label);
    try testing.expect(!try model.setLabel("{\"itemId\":\"missing\",\"label\":\"x\"}"));
    try testing.expect(try model.removeItem("{\"itemId\":\"b\"}"));
    try testing.expect(!try model.removeItem("{\"itemId\":\"b\"}"));
    try testing.expectEqual(@as(usize, 3), model.menus.items[0].items.items.len);
}

test "activation separates page actions, settings and platform roles" {
    var model = Model.init(testing.allocator);
    defer model.deinit();
    try model.set(
        \\{"menus":[{"label":"App","items":[
        \\  {"id":"custom","label":"Custom"},{"role":"about","label":"About"},
        \\  {"role":"settings","label":"Settings"},{"role":"reload","label":"Reload"}]}]}
    );
    const items = model.menus.items[0].items.items;
    try testing.expectEqualStrings("custom", activationFor(&items[0]).action);
    try testing.expectEqualStrings("about", activationFor(&items[1]).action);
    try testing.expect(activationFor(&items[2]) == .settings);
    try testing.expectEqual(Role.reload, activationFor(&items[3]).role);
    const script = try actionScript(testing.allocator, "a\"b");
    defer testing.allocator.free(script);
    try testing.expectEqualStrings("if (window.__craftMenuCallback) window.__craftMenuCallback(\"a\\\"b\");", script);
}

test "a context menu numbers its items and answers in the macOS shape" {
    var menu = try parseContextMenu(testing.allocator,
        \\{"targetId":"row \"1\"","targetType":"file","x":12.6,"y":40,"items":[
        \\  {"id":"open","title":"Open","shortcut":"cmd+o"},
        \\  {"id":"s1","title":"","type":"separator"},
        \\  {"id":"more","title":"More","type":"submenu","submenu":[{"id":"deep","title":"Deep"}]},
        \\  {"id":"off","title":"Off","enabled":false}]}
    );
    defer menu.deinit();
    try testing.expectEqual(@as(i32, 12), menu.x);
    try testing.expectEqualStrings("open", menu.idFor(1).?);
    try testing.expect(menu.idFor(2) == null);
    try testing.expect(menu.idFor(3) == null);
    try testing.expectEqualStrings("deep", menu.idFor(4).?);
    try testing.expectEqualStrings("off", menu.idFor(5).?);
    try testing.expect(menu.idFor(6) == null);
    try testing.expect(!menu.items[3].enabled);

    const chosen = try menu.resultJson(testing.allocator, "open");
    defer testing.allocator.free(chosen);
    try testing.expectEqualStrings("{\"id\":\"open\",\"targetId\":\"row \\\"1\\\"\",\"targetType\":\"file\"}", chosen);
    const dismissed = try menu.resultJson(testing.allocator, null);
    defer testing.allocator.free(dismissed);
    try testing.expectEqualStrings("{\"id\":null,\"targetId\":\"row \\\"1\\\"\",\"targetType\":\"file\"}", dismissed);
}

test "a context menu without items is refused" {
    try testing.expectError(error.MissingData, parseContextMenu(testing.allocator, "{\"items\":[]}"));
    try testing.expectError(error.MissingData, parseContextMenu(testing.allocator, "{}"));
    try testing.expectError(error.InvalidJSON, parseContextMenu(testing.allocator, "[]"));
}
