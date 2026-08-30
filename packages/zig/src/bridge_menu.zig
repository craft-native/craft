const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const icons = @import("icons.zig");
const menu_roles = @import("menu_roles.zig");
const logging = @import("logging.zig");
const capabilities = @import("capabilities.zig");

const BridgeError = bridge_error.BridgeError;
const log = logging.menu;

/// Menu item type
pub const MenuItemType = enum {
    normal,
    separator,
    checkbox,
    radio,
};

/// Menu item structure for menu building
pub const MenuItem = struct {
    id: []const u8,
    label: []const u8,
    menu_type: MenuItemType = .normal,
    checked: bool = false,
    enabled: bool = true,
    action: ?[]const u8 = null,
    shortcut: ?[]const u8 = null,
    icon: ?[]const u8 = null, // Icon name from icons.zig
    submenu: ?[]MenuItem = null,
};

/// The action `craft-bridge.js` posts for `craft.menu.set`, named once so the
/// dispatcher below and the contract test in `test/injected_js_test.zig` compare
/// against the same bytes. A copy on each side is what #27 was: the JS said
/// `setApplicationMenu`, the dispatcher said `setAppMenu`, and because an
/// unrecognized action only logs, every call looked like it had worked.
pub const action_set_app_menu = "setAppMenu";

/// Shape parsed from JSON: a single item in an items array.
pub const ParsedItem = struct {
    id: ?[]const u8 = null,
    label: ?[]const u8 = null,
    shortcut: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    separator: ?bool = null,
    /// A standard-behavior item ("copy", "quit", "minimize"): the item is
    /// wired to the matching AppKit selector with a nil target, so the
    /// responder chain — not JS — performs it. Cut/copy/paste MUST take
    /// this path: a JS round-trip cannot reach the field editor or the
    /// WKWebView's own clipboard actions.
    role: ?[]const u8 = null,
};

/// The identifier an item is built with, or null for one that cannot be built.
///
/// Separators never reach here — they are added before this is consulted.
///
/// A role item needs no caller-supplied id: its selector comes from the role
/// and nothing is ever reported back for it. Requiring one anyway meant
/// `{label: "Copy", role: "copy"}` — the obvious way to write it, and the way
/// `@stacksjs/desktop`'s standard menus wrote it — was skipped in silence, so a
/// menu of nothing but role items rendered as a menu of nothing but separators.
/// Nothing was logged, and the payload inspected correctly on the JS side.
pub fn identifierFor(item: ParsedItem) ?[]const u8 {
    return item.id orelse item.role;
}

/// Shape parsed from JSON: a top-level menu (bar / dock root).
pub const ParsedMenu = struct {
    label: ?[]const u8 = null,
    items: ?[]const ParsedItem = null,
};

/// Shape parsed from JSON for `setAppMenu`.
pub const ParsedAppMenu = struct {
    menus: ?[]const ParsedMenu = null,
};

/// Decode a `setAppMenu` payload.
///
/// Split out of `setAppMenu`, which goes straight on to talk to AppKit and so
/// can only run inside a real app. This half is the JS/native contract itself
/// — the field names `craft-bridge.js` writes and the ones native reads — and
/// it is the half that drifted in #27, silently, because a key native does not
/// recognize is indistinguishable from one the caller omitted. Keeping it
/// AppKit-free means the contract can be tested against the real injected
/// script instead of against a hand-built message: see
/// `test/injected_js_test.zig`.
///
/// Caller owns the returned `Parsed` and must `deinit()` it.
pub fn parseAppMenu(allocator: std.mem.Allocator, data: []const u8) BridgeError!std.json.Parsed(ParsedAppMenu) {
    return std.json.parseFromSlice(ParsedAppMenu, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch BridgeError.InvalidJSON;
}

/// Bridge handler for application menu and dock menu
pub const MenuBridge = struct {
    allocator: std.mem.Allocator,
    app_menu: ?*anyopaque = null,
    dock_menu: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Handle menu-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            self.reportError(action, err);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        // `setAppMenu` is the canonical action (the bridge JS and .d.ts both
        // say so since #27). The old bridge name `setApplicationMenu` stays
        // accepted for callers that post raw bridge messages against the old
        // contract — one string compare buys them a working menu instead of
        // the silent no-op #27 fixed.
        if (std.mem.eql(u8, action, action_set_app_menu) or std.mem.eql(u8, action, "setApplicationMenu")) {
            try self.setAppMenu(data);
        } else if (std.mem.eql(u8, action, "setDockMenu")) {
            try self.setDockMenu(data);
        } else if (std.mem.eql(u8, action, "addMenuItem")) {
            try self.addMenuItem(data);
        } else if (std.mem.eql(u8, action, "removeMenuItem")) {
            try self.removeMenuItem(data);
        } else if (std.mem.eql(u8, action, "enableMenuItem")) {
            try self.enableMenuItem(data);
        } else if (std.mem.eql(u8, action, "disableMenuItem")) {
            try self.disableMenuItem(data);
        } else if (std.mem.eql(u8, action, "checkMenuItem")) {
            try self.checkMenuItem(data);
        } else if (std.mem.eql(u8, action, "uncheckMenuItem")) {
            try self.uncheckMenuItem(data);
        } else if (std.mem.eql(u8, action, "setMenuItemLabel")) {
            try self.setMenuItemLabel(data);
        } else if (std.mem.eql(u8, action, "clearDockMenu")) {
            try self.clearDockMenu();
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn reportError(self: *Self, action: []const u8, err: anyerror) void {
        const bridge_err: BridgeError = switch (err) {
            BridgeError.MissingData => BridgeError.MissingData,
            BridgeError.InvalidJSON => BridgeError.InvalidJSON,
            else => BridgeError.NativeCallFailed,
        };
        bridge_error.sendErrorToJS(self.allocator, action, bridge_err);
    }

    /// Set the application menu bar
    /// JSON: {"menus": [{"label": "File", "items": [{"id": "new", "label": "New", "shortcut": "cmd+n"}]}]}
    fn setAppMenu(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            log.debug("menu: not supported on this platform", .{});
            return;
        }

        const macos = @import("macos.zig");

        log.debug("setAppMenu", .{});

        // Parse the whole structure with std.json. Previously we walked the
        // JSON by hand with arbitrary byte-window heuristics (e.g. "is the
        // label within 100 bytes of the id?"), which misattributed fields in
        // pretty-printed payloads and silently dropped long labels.
        const parsed = try parseAppMenu(self.allocator, data);
        defer parsed.deinit();

        const NSApplication = macos.getClass("NSApplication");
        const app = macos.msgSend0(NSApplication, "sharedApplication");

        const NSMenu = macos.getClass("NSMenu");
        const main_menu = macos.msgSend0(macos.msgSend0(NSMenu, "alloc"), "init");

        var menu_count: usize = 0;
        const menus = parsed.value.menus orelse &[_]ParsedMenu{};
        for (menus) |menu_def| {
            const menu_label = menu_def.label orelse continue;
            const items = menu_def.items orelse &[_]ParsedItem{};

            const menu = try self.createMenuFromItems(menu_label, items);
            if (menu) |m| {
                const menu_item = macos.msgSend0(macos.msgSend0(macos.getClass("NSMenuItem"), "alloc"), "init");

                const label_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, menu_label);
                defer self.allocator.free(label_cstr);
                const NSString = macos.getClass("NSString");
                const ns_label = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", label_cstr.ptr);
                _ = macos.msgSend1(menu_item, "setTitle:", ns_label);
                _ = macos.msgSend1(m, "setTitle:", ns_label);

                _ = macos.msgSend1(menu_item, "setSubmenu:", m);
                _ = macos.msgSend1(main_menu, "addItem:", menu_item);
                menu_count += 1;
            }
        }

        _ = macos.msgSend1(app, "setMainMenu:", main_menu);
        self.app_menu = main_menu;

        log.debug("Created app menu with {} menus", .{menu_count});
    }

    /// Build an NSMenu from a pre-parsed items slice. The old byte-walking
    /// variant (`createMenuWithItems`) is kept as a thin wrapper so existing
    /// call sites (`setDockMenu`, `createMenu`) keep working without a wider
    /// refactor — it now re-parses its input JSON through the typed helpers.
    fn createMenuFromItems(self: *Self, title: []const u8, items: []const ParsedItem) !?*anyopaque {
        if (comptime builtin.os.tag != .macos) return null;

        const macos = @import("macos.zig");

        const NSMenu = macos.getClass("NSMenu");
        const menu = macos.msgSend0(macos.msgSend0(NSMenu, "alloc"), "init");

        const title_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, title);
        defer self.allocator.free(title_cstr);
        const NSString = macos.getClass("NSString");
        const ns_title = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", title_cstr.ptr);
        _ = macos.msgSend1(menu, "setTitle:", ns_title);

        for (items) |it| {
            if (it.separator orelse false) {
                const sep_item = macos.msgSend0(macos.getClass("NSMenuItem"), "separatorItem");
                _ = macos.msgSend1(menu, "addItem:", sep_item);
                continue;
            }

            const id = identifierFor(it) orelse continue;
            const label = it.label orelse id;
            const shortcut = it.shortcut orelse "";
            const item = try self.createMenuItemFull(id, label, shortcut, it.icon, it.role);
            if (item) |i| {
                _ = macos.msgSend1(menu, "addItem:", i);
            }
        }

        return menu;
    }

    /// Legacy JSON-blob variant, retained for callers that pass raw JSON
    /// (e.g. `setDockMenu`). Decodes into the same typed schema rather than
    /// walking the bytes by hand.
    fn createMenuWithItems(self: *Self, title: []const u8, items_data: []const u8) !?*anyopaque {
        if (comptime builtin.os.tag != .macos) return null;

        // Accept either a bare array or an object with an `items` array so
        // dock menus (`{"items":[...]}`) and raw arrays both work.
        const Wrapped = struct { items: ?[]const ParsedItem = null };
        if (std.json.parseFromSlice(Wrapped, self.allocator, items_data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        })) |parsed| {
            defer parsed.deinit();
            const items = parsed.value.items orelse &[_]ParsedItem{};
            return try self.createMenuFromItems(title, items);
        } else |_| {}

        if (std.json.parseFromSlice([]const ParsedItem, self.allocator, items_data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        })) |parsed| {
            defer parsed.deinit();
            return try self.createMenuFromItems(title, parsed.value);
        } else |_| {}

        return null;
    }

    /// Create a single menu item with optional icon. Kept as the two-behavior
    /// wrapper existing callers (`addMenuItemImpl`) use: id-actions only.
    fn createMenuItem(self: *Self, id: []const u8, label: []const u8, shortcut: []const u8, icon_name: ?[]const u8) !?*anyopaque {
        return self.createMenuItemFull(id, label, shortcut, icon_name, null);
    }

    /// The real builder. Two kinds of item come out of it:
    ///
    /// - role items: action = the AppKit selector for the role, target = nil,
    ///   so the responder chain performs the standard behavior (copy:,
    ///   terminate:, performMiniaturize:, …) exactly as a nib-built menu
    ///   would.
    /// - id items: action = craftMenuAction: on the registered target below,
    ///   which reads the id back out of representedObject and forwards it to
    ///   the page as a `craft:menu:action` event. Before the target existed,
    ///   every bridge-built item pointed at a selector nobody implemented, so
    ///   AppKit auto-disabled the entire menu — `craft.menu.set()` produced
    ///   grey text.
    fn createMenuItemFull(self: *Self, id: []const u8, label: []const u8, shortcut: []const u8, icon_name: ?[]const u8, role: ?[]const u8) !?*anyopaque {
        if (comptime builtin.os.tag != .macos) return null;

        const macos = @import("macos.zig");

        // Create label NSString
        const label_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, label);
        defer self.allocator.free(label_cstr);
        const NSString = macos.getClass("NSString");
        const ns_label = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", label_cstr.ptr);

        // Parse shortcut by splitting on `+` and matching each token exactly.
        // Using `indexOf(shortcut, "cmd")` instead would accept spurious
        // substrings like "ccmd" or "salt", and it can't distinguish a
        // modifier name from the key name.
        var key_equiv: []const u8 = "";
        var modifier_mask: c_ulong = 0;

        if (shortcut.len > 0) {
            var it = std.mem.splitScalar(u8, shortcut, '+');
            while (it.next()) |tok| {
                // The token after the last `+` is the key; everything else is
                // a modifier (cmd/ctrl/alt/opt/shift, case-insensitive).
                if (it.peek() == null) {
                    key_equiv = tok;
                    break;
                }
                if (std.ascii.eqlIgnoreCase(tok, "cmd")) {
                    modifier_mask |= (1 << 20);
                } else if (std.ascii.eqlIgnoreCase(tok, "ctrl")) {
                    modifier_mask |= (1 << 18);
                } else if (std.ascii.eqlIgnoreCase(tok, "alt") or std.ascii.eqlIgnoreCase(tok, "opt")) {
                    modifier_mask |= (1 << 19);
                } else if (std.ascii.eqlIgnoreCase(tok, "shift")) {
                    modifier_mask |= (1 << 17);
                }
            }
        }

        // Create key equivalent string
        const key_cstr = if (key_equiv.len > 0) try @import("memory.zig").dupeZ(self.allocator, u8, key_equiv) else try @import("memory.zig").dupeZ(self.allocator, u8, "");
        defer self.allocator.free(key_cstr);
        const ns_key = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", key_cstr.ptr);

        // "settings" is craft's own role, not an AppKit one. `menu_roles.zig`
        // can only hold real action selectors and AppKit publishes none for the
        // Settings item, so this routes to the same target the default menu
        // bar uses — which is what lets an app that replaces the whole bar with
        // `craft.menu.set()` keep a working Cmd+, and the same
        // `craft:settings:open` event.
        const is_settings = if (role) |r|
            std.ascii.eqlIgnoreCase(r, "settings") or std.ascii.eqlIgnoreCase(r, "preferences")
        else
            false;

        // Role items act through the responder chain; id items through the
        // registered target. An unknown role falls back to an id item rather
        // than a dead one, so a newer JS surface degrades to an event the
        // page can still handle.
        const role_sel = if (is_settings) null else if (role) |r| roleSelector(r) else null;
        const action_sel = if (is_settings)
            macos.sel(macos.settings_action_selector)
        else if (role_sel) |s|
            macos.sel(s)
        else
            macos.sel("craftMenuAction:");

        const NSMenuItem = macos.getClass("NSMenuItem");
        const item = macos.msgSend3(macos.msgSend0(NSMenuItem, "alloc"), "initWithTitle:action:keyEquivalent:", ns_label, action_sel, ns_key);

        if (is_settings) {
            if (macos.ensureSettingsTarget()) |target| {
                _ = macos.msgSend1(item, "setTarget:", target);
            }
        } else if (role_sel == null) {
            if (ensureMenuTarget()) |target| {
                _ = macos.msgSend1(item, "setTarget:", target);
            }
        }

        // Set modifier mask
        if (modifier_mask > 0) {
            _ = macos.msgSend1(item, "setKeyEquivalentModifierMask:", modifier_mask);
        }

        // Store item ID as represented object
        const id_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, id);
        defer self.allocator.free(id_cstr);
        const ns_id = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", id_cstr.ptr);
        _ = macos.msgSend1(item, "setRepresentedObject:", ns_id);

        // Apply icon if specified
        if (icon_name) |name| {
            // Resolve through cross-platform icons module
            const resolved_name = if (icons.getIconByName(name)) |icon| blk: {
                const platform_icon = icons.getPlatformIcon(icon);
                if (platform_icon.kind == .sf_symbol and platform_icon.value.len > 0) {
                    break :blk platform_icon.value;
                }
                break :blk name;
            } else name;

            const NSImage = macos.getClass("NSImage");
            const icon_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, resolved_name);
            defer self.allocator.free(icon_cstr);
            const ns_icon_name = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", icon_cstr.ptr);
            const image = macos.msgSend2(NSImage, "imageWithSystemSymbolName:accessibilityDescription:", ns_icon_name, @as(?*anyopaque, null));

            if (image != null) {
                _ = macos.msgSend1(item, "setImage:", image);
            }
        }

        return item;
    }

    /// Set the dock menu (right-click on dock icon)
    /// JSON: {"items": [{"id": "show", "label": "Show Window"}, {"separator": true}, {"id": "quit", "label": "Quit"}]}
    fn setDockMenu(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            log.debug("menu: not supported on this platform", .{});
            return;
        }

        log.debug("setDockMenu", .{});

        // Create dock menu
        const menu = try self.createMenuWithItems("Dock", data) orelse return;
        self.dock_menu = menu;
        global_dock_menu = menu;

        log.debug("Dock menu created", .{});
    }

    /// Add a single menu item to existing menu
    /// JSON: {"menuId": "file", "itemId": "save", "label": "Save", "shortcut": "cmd+s", "index": -1}
    /// If menuId is omitted, adds to app menu. index -1 means append at end.
    fn addMenuItem(self: *Self, data: []const u8) !void {
        try addMenuItemImpl(self, data);
    }

    /// Remove a menu item
    /// JSON: {"itemId": "save"} or {"menuId": "file", "itemId": "save"}
    fn removeMenuItem(self: *Self, data: []const u8) !void {
        removeMenuItemImpl(self, data);
    }

    /// Enable a menu item
    fn enableMenuItem(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            log.debug("menu: not supported on this platform", .{});
            return;
        }
        _ = self;

        var item_id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"itemId\":\"")) |idx| {
            const start = idx + 10;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item_id = data[start..end];
            }
        }

        log.debug("enableMenuItem: {s}", .{item_id});

        if (findMenuItemById(item_id)) |item| {
            const macos = @import("macos.zig");
            _ = macos.msgSend1(item, "setEnabled:", @as(c_int, 1));
        }
    }

    /// Disable a menu item
    fn disableMenuItem(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            log.debug("menu: not supported on this platform", .{});
            return;
        }
        _ = self;

        var item_id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"itemId\":\"")) |idx| {
            const start = idx + 10;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item_id = data[start..end];
            }
        }

        log.debug("disableMenuItem: {s}", .{item_id});

        if (findMenuItemById(item_id)) |item| {
            const macos = @import("macos.zig");
            _ = macos.msgSend1(item, "setEnabled:", @as(c_int, 0));
        }
    }

    /// Check (add checkmark to) a menu item
    fn checkMenuItem(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            log.debug("menu: not supported on this platform", .{});
            return;
        }
        _ = self;

        var item_id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"itemId\":\"")) |idx| {
            const start = idx + 10;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item_id = data[start..end];
            }
        }

        log.debug("checkMenuItem: {s}", .{item_id});

        if (findMenuItemById(item_id)) |item| {
            const macos = @import("macos.zig");
            _ = macos.msgSend1(item, "setState:", @as(c_long, 1));
        }
    }

    /// Uncheck a menu item
    fn uncheckMenuItem(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            log.debug("menu: not supported on this platform", .{});
            return;
        }
        _ = self;

        var item_id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"itemId\":\"")) |idx| {
            const start = idx + 10;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item_id = data[start..end];
            }
        }

        log.debug("uncheckMenuItem: {s}", .{item_id});

        if (findMenuItemById(item_id)) |item| {
            const macos = @import("macos.zig");
            _ = macos.msgSend1(item, "setState:", @as(c_long, 0));
        }
    }

    /// Update menu item label
    fn setMenuItemLabel(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            log.debug("menu: not supported on this platform", .{});
            return;
        }

        var item_id: []const u8 = "";
        var new_label: []const u8 = "";

        if (std.mem.indexOf(u8, data, "\"itemId\":\"")) |idx| {
            const start = idx + 10;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item_id = data[start..end];
            }
        }

        if (std.mem.indexOf(u8, data, "\"label\":\"")) |idx| {
            const start = idx + 9;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                new_label = data[start..end];
            }
        }

        log.debug("setMenuItemLabel: {s} = {s}", .{ item_id, new_label });

        if (findMenuItemById(item_id)) |item| {
            const macos = @import("macos.zig");
            const label_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, new_label);
            defer self.allocator.free(label_cstr);
            const NSString = macos.getClass("NSString");
            const ns_label = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", label_cstr.ptr);
            _ = macos.msgSend1(item, "setTitle:", ns_label);
        }
    }

    /// Clear the dock menu
    fn clearDockMenu(self: *Self) !void {
        if (comptime builtin.os.tag != .macos) {
            log.debug("menu: not supported on this platform", .{});
            return;
        }

        log.debug("clearDockMenu", .{});

        if (self.dock_menu) |menu| {
            const macos = @import("macos.zig");
            _ = macos.msgSend0(menu, "removeAllItems");
        }
        self.dock_menu = null;
        global_dock_menu = null;
    }

    /// Legacy createMenu for compatibility
    pub fn createMenu(self: *Self, menu_json: []const u8) !?*anyopaque {
        return try self.createMenuWithItems("Menu", menu_json);
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        global_dock_menu = null;
    }
};

/// Global dock menu for delegate callback
var global_dock_menu: ?*anyopaque = null;

/// The AppKit selector a role stands for, or null for a role this build does
/// not know. Names follow Electron's role vocabulary where one exists — the
/// audience for this API has usually met it there first.
///
/// The table moved to `menu_roles.zig` so the default menu bar in `macos.zig`
/// resolves roles the same way an app-declared one does; an app that overrides
/// the bar should not get a different idea of what "copy" means.
const roleSelector = menu_roles.selectorFor;

/// One target for every id item in every bridge-built menu. A single retained
/// NSObject is enough: the clicked item arrives as `sender`, carrying its own
/// id in `representedObject`.
var menu_target: ?*anyopaque = null;

fn menuActionCallback(_: ?*anyopaque, _: ?*anyopaque, sender: ?*anyopaque) callconv(.c) void {
    if (comptime builtin.os.tag != .macos) return;
    if (sender == null) return;

    const macos = @import("macos.zig");
    const rep = macos.msgSend0(sender, "representedObject");
    if (rep == null) return;
    const cstr = macos.msgSend0(rep, "UTF8String");
    if (cstr == null) return;
    handleMenuItemClick(std.mem.span(@as([*:0]const u8, @ptrCast(cstr))));
}

fn ensureMenuTarget() ?*anyopaque {
    _ = capabilities.registerEmitter(.menu_action);
    if (comptime builtin.os.tag != .macos) return null;
    if (menu_target != null) return menu_target;

    const macos = @import("macos.zig");
    const objc = macos.objc;

    const NSObject = macos.getClass("NSObject");
    const cls = objc.objc_allocateClassPair(NSObject, "CraftMenuTarget", 0);
    if (cls == null) return null;

    _ = objc.class_addMethod(
        cls,
        macos.sel("craftMenuAction:"),
        @ptrCast(@constCast(&menuActionCallback)),
        "v@:@",
    );
    objc.objc_registerClassPair(cls);

    menu_target = macos.msgSend0(macos.msgSend0(cls, "alloc"), "init");
    return menu_target;
}

/// Get dock menu for applicationDockMenu: delegate
pub fn getDockMenu() ?*anyopaque {
    return global_dock_menu;
}

/// Implementation of addMenuItem (platform-specific)
fn addMenuItemImpl(self: *MenuBridge, data: []const u8) !void {
    if (comptime builtin.os.tag == .macos) {
        const macos = @import("macos.zig");

        // Parse menuId (target menu)
        var menu_id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"menuId\":\"")) |idx| {
            const start = idx + 10;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                menu_id = data[start..end];
            }
        }

        // Parse item details
        var item_id: []const u8 = "";
        var item_label: []const u8 = "";
        var shortcut: []const u8 = "";
        var index: i32 = -1;

        if (std.mem.indexOf(u8, data, "\"itemId\":\"")) |idx| {
            const start = idx + 10;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item_id = data[start..end];
            }
        }

        if (std.mem.indexOf(u8, data, "\"label\":\"")) |idx| {
            const start = idx + 9;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item_label = data[start..end];
            }
        }

        if (std.mem.indexOf(u8, data, "\"shortcut\":\"")) |idx| {
            const start = idx + 12;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                shortcut = data[start..end];
            }
        }

        if (std.mem.indexOf(u8, data, "\"index\":")) |idx| {
            const start = idx + 8;
            var end = start;
            while (end < data.len and (data[end] == '-' or (data[end] >= '0' and data[end] <= '9'))) : (end += 1) {}
            if (end > start) {
                index = std.fmt.parseInt(i32, data[start..end], 10) catch -1;
            }
        }

        // Parse icon
        var icon_name: ?[]const u8 = null;
        if (std.mem.indexOf(u8, data, "\"icon\":\"")) |idx| {
            const start = idx + 8;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                icon_name = data[start..end];
            }
        }

        // Check for separator
        const is_separator = std.mem.indexOf(u8, data, "\"separator\":true") != null;

        log.debug("addMenuItem: menu={s}, id={s}, label={s}", .{ menu_id, item_id, item_label });

        // Find target menu
        var target_menu: ?*anyopaque = null;

        if (menu_id.len > 0) {
            const app = macos.msgSend0(macos.getClass("NSApplication"), "sharedApplication");
            const main_menu = macos.msgSend0(app, "mainMenu");
            if (main_menu) |menu| {
                target_menu = findSubmenuByTitle(menu, menu_id);
            }
        } else if (self.app_menu) |menu| {
            target_menu = menu;
        }

        if (target_menu == null) {
            log.warn("Target menu not found: {s}", .{menu_id});
            return;
        }

        // Create menu item
        var new_item: ?*anyopaque = null;
        if (is_separator) {
            new_item = macos.msgSend0(macos.getClass("NSMenuItem"), "separatorItem");
        } else {
            new_item = try self.createMenuItem(item_id, item_label, shortcut, icon_name);
        }

        if (new_item) |item| {
            if (index < 0) {
                _ = macos.msgSend1(target_menu.?, "addItem:", item);
            } else {
                _ = macos.msgSend2(target_menu.?, "insertItem:atIndex:", item, @as(c_long, index));
            }
            log.debug("Added menu item: {s}", .{item_id});
        }
    } else {
        // Linux/Windows: Menu APIs not yet implemented
        _ = &self;
        _ = &data;
    }
}

/// Implementation of removeMenuItem (platform-specific)
fn removeMenuItemImpl(self: *MenuBridge, data: []const u8) void {
    _ = &self;
    if (comptime builtin.os.tag == .macos) {
        const macos = @import("macos.zig");

        // Parse itemId to remove
        var item_id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"itemId\":\"")) |idx| {
            const start = idx + 10;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item_id = data[start..end];
            }
        }

        if (item_id.len == 0) {
            log.warn("removeMenuItem: no itemId provided", .{});
            return;
        }

        log.debug("removeMenuItem: {s}", .{item_id});

        // Find and remove the item
        if (findMenuItemById(item_id)) |item| {
            const parent_menu = macos.msgSend0(item, "menu");
            if (parent_menu) |menu| {
                _ = macos.msgSend1(menu, "removeItem:", item);
                log.debug("Removed menu item: {s}", .{item_id});
            }
        } else {
            log.warn("Menu item not found: {s}", .{item_id});
        }
    } else {
        // Linux/Windows: Menu APIs not yet implemented
        _ = &data;
    }
}

/// Find submenu by title (case-insensitive search)
fn findSubmenuByTitle(menu: *anyopaque, title: []const u8) ?*anyopaque {
    if (comptime builtin.os.tag != .macos) return null;

    const macos = @import("macos.zig");

    // `numberOfItems` returns NSInteger (signed). Read it as isize so a
    // negative return (or pointer value) doesn't wrap to a huge usize and
    // loop the menu iteration effectively forever.
    const count_ptr = macos.msgSend0(menu, "numberOfItems");
    const count_signed: isize = @bitCast(@intFromPtr(count_ptr));
    if (count_signed <= 0) return null;
    const count: usize = @intCast(count_signed);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const item = macos.msgSend1(menu, "itemAtIndex:", @as(c_long, @intCast(i)));
        if (item == null) continue;

        // Check if this item has a submenu
        const submenu = macos.msgSend0(item, "submenu");
        if (submenu) |sub| {
            // Get submenu title
            const ns_title = macos.msgSend0(sub, "title");
            if (ns_title != null) {
                const cstr = macos.msgSend0(ns_title, "UTF8String");
                if (cstr != null) {
                    const title_str = std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));
                    if (std.ascii.eqlIgnoreCase(title_str, title)) {
                        return sub;
                    }
                }
            }

            // Also check item title (menu bar items)
            const item_title = macos.msgSend0(item, "title");
            if (item_title != null) {
                const item_cstr = macos.msgSend0(item_title, "UTF8String");
                if (item_cstr != null) {
                    const item_str = std.mem.span(@as([*:0]const u8, @ptrCast(item_cstr)));
                    if (std.ascii.eqlIgnoreCase(item_str, title)) {
                        return sub;
                    }
                }
            }

            // Recursively search nested submenus
            if (findSubmenuByTitle(sub, title)) |found| {
                return found;
            }
        }
    }

    return null;
}

/// Find menu item by ID (searches app menu and dock menu)
fn findMenuItemById(item_id: []const u8) ?*anyopaque {
    if (comptime builtin.os.tag != .macos) return null;

    const macos = @import("macos.zig");

    // Search app main menu
    const app = macos.msgSend0(macos.getClass("NSApplication"), "sharedApplication");
    const main_menu = macos.msgSend0(app, "mainMenu");

    if (main_menu) |menu| {
        if (searchMenuForItem(menu, item_id)) |found| {
            return found;
        }
    }

    // Search dock menu
    if (global_dock_menu) |dock_menu| {
        if (searchMenuForItem(dock_menu, item_id)) |found| {
            return found;
        }
    }

    return null;
}

/// Recursively search menu for item with ID
fn searchMenuForItem(menu: *anyopaque, item_id: []const u8) ?*anyopaque {
    if (comptime builtin.os.tag != .macos) return null;

    const macos = @import("macos.zig");

    const count_ptr = macos.msgSend0(menu, "numberOfItems");
    const count_signed: isize = @bitCast(@intFromPtr(count_ptr));
    if (count_signed <= 0) return null;
    const count: usize = @intCast(count_signed);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const item = macos.msgSend1(menu, "itemAtIndex:", @as(c_long, @intCast(i)));
        if (item == null) continue;

        // Check represented object for ID
        const rep_obj = macos.msgSend0(item, "representedObject");
        if (rep_obj != null) {
            const cstr = macos.msgSend0(rep_obj, "UTF8String");
            if (cstr != null) {
                const id_str = std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));
                if (std.mem.eql(u8, id_str, item_id)) {
                    return item;
                }
            }
        }

        // Check submenu recursively
        const submenu = macos.msgSend0(item, "submenu");
        if (submenu) |sub| {
            if (searchMenuForItem(sub, item_id)) |found| {
                return found;
            }
        }
    }

    return null;
}

/// Handle menu item click - called from app delegate.
/// Escapes `item_id` before injecting it into JS so that a menu id containing
/// `'`, `\`, or newline cannot break out of the string literal and execute
/// attacker-controlled code. Previously this was a JS-injection vector.
pub fn handleMenuItemClick(item_id: []const u8) void {
    const bridge = @import("bridge.zig");

    log.debug("Menu item clicked: {s}", .{item_id});

    // Escape `item_id` into a caller-owned buffer. We reserve half of the
    // 512-byte JS buffer for the escaped identifier and bail out cleanly if
    // the escaped form doesn't fit rather than smuggling truncated JS.
    var esc_buf: [240]u8 = undefined;
    var esc_len: usize = 0;
    for (item_id) |c| {
        const repl: []const u8 = switch (c) {
            '\\' => "\\\\",
            '\'' => "\\'",
            '\n' => "\\n",
            '\r' => "\\r",
            '<' => "\\x3c",
            else => &[_]u8{c},
        };
        if (esc_len + repl.len > esc_buf.len) return;
        @memcpy(esc_buf[esc_len..][0..repl.len], repl);
        esc_len += repl.len;
    }

    var buf: [512]u8 = undefined;
    const js = std.fmt.bufPrint(&buf,
        \\if(window.__craftMenuCallback)window.__craftMenuCallback('{s}');
    , .{esc_buf[0..esc_len]}) catch return;

    bridge.evalJS(js) catch |err| {
        log.err("Failed to trigger callback: {}", .{err});
    };
}

test "a role item builds without a caller-supplied id" {
    // What `{label: "Copy", role: "copy"}` parses to. This used to return null
    // and the item was skipped, so Edit shipped with only its separators.
    const copy = ParsedItem{ .label = "Copy", .role = "copy" };
    try std.testing.expectEqualStrings("copy", identifierFor(copy).?);
}

test "an explicit id still wins, so ids keep reporting back under their own name" {
    const item = ParsedItem{ .id = "app.copy", .label = "Copy", .role = "copy" };
    try std.testing.expectEqualStrings("app.copy", identifierFor(item).?);
}

test "an item with neither is the one thing that cannot be built" {
    try std.testing.expect(identifierFor(ParsedItem{ .label = "Orphan" }) == null);
}
