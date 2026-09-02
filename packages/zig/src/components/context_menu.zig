const std = @import("std");
const macos = @import("../macos.zig");
const objc = macos.objc;

/// Context Menu support for native UI components
/// Implements NSMenu creation and NSMenuDelegate for handling right-click menus
/// Menu item types
pub const MenuItemType = enum {
    standard, // Regular clickable item
    separator, // Separator line
    submenu, // Item with submenu
};

/// Menu item configuration
pub const MenuItem = struct {
    id: []const u8,
    title: []const u8,
    icon: ?[]const u8 = null, // SF Symbol name
    shortcut: ?[]const u8 = null, // e.g., "cmd+c"
    enabled: bool = true,
    item_type: MenuItemType = .standard,
    submenu_items: ?[]const MenuItem = null,
};

/// Context menu configuration
pub const ContextMenuConfig = struct {
    items: []const MenuItem,
    target_id: []const u8, // ID of the item that was right-clicked
    target_type: []const u8, // "sidebar" or "file"
};

/// Callback data for menu delegate
pub const MenuCallbackData = struct {
    on_menu_action: ?*const fn (menu_item_id: []const u8, target_id: []const u8, target_type: []const u8) void = null,
    target_id: []const u8,
    target_type: []const u8,
    item_ids: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, target_id: []const u8, target_type: []const u8) !*MenuCallbackData {
        const data = try allocator.create(MenuCallbackData);
        data.* = .{
            .target_id = try allocator.dupe(u8, target_id),
            .target_type = try allocator.dupe(u8, target_type),
            .item_ids = .empty,
            .allocator = allocator,
        };
        return data;
    }

    pub fn deinit(self: *MenuCallbackData) void {
        self.allocator.free(self.target_id);
        self.allocator.free(self.target_type);
        for (self.item_ids.items) |id| {
            self.allocator.free(id);
        }
        self.item_ids.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addItemId(self: *MenuCallbackData, item_id: []const u8) !void {
        const id_copy = try self.allocator.dupe(u8, item_id);
        try self.item_ids.append(self.allocator, id_copy);
    }

    pub fn getItemId(self: *MenuCallbackData, index: usize) ?[]const u8 {
        if (index < self.item_ids.items.len) {
            return self.item_ids.items[index];
        }
        return null;
    }
};

/// Context menu delegate
pub const ContextMenuDelegate = struct {
    objc_class: objc.Class,
    instance: objc.id,
    callback_data: *MenuCallbackData,
    allocator: std.mem.Allocator,

    const AssociatedObjectKey: usize = 0xC0DE;

    pub fn init(allocator: std.mem.Allocator, target_id: []const u8, target_type: []const u8) !*ContextMenuDelegate {
        const callback_data = try MenuCallbackData.init(allocator, target_id, target_type);

        const NSObject = macos.getClass("NSObject");
        const class_name = "CraftContextMenuDelegate";

        var objc_class = objc.objc_getClass(class_name);
        if (objc_class == null) {
            objc_class = objc.objc_allocateClassPair(NSObject, class_name, 0);

            // menuItemClicked: (custom action)
            const menuItemClicked = @as(
                *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
                @ptrCast(@constCast(&menuItemClickedHandler)),
            );
            _ = objc.class_addMethod(
                objc_class,
                macos.sel("menuItemClicked:"),
                @ptrCast(@constCast(menuItemClicked)),
                "v@:@",
            );

            // menuWillOpen: (NSMenuDelegate)
            const menuWillOpen = @as(
                *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
                @ptrCast(@constCast(&menuWillOpenHandler)),
            );
            _ = objc.class_addMethod(
                objc_class,
                macos.sel("menuWillOpen:"),
                @ptrCast(@constCast(menuWillOpen)),
                "v@:@",
            );

            // menuDidClose: (NSMenuDelegate)
            const menuDidClose = @as(
                *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
                @ptrCast(@constCast(&menuDidCloseHandler)),
            );
            _ = objc.class_addMethod(
                objc_class,
                macos.sel("menuDidClose:"),
                @ptrCast(@constCast(menuDidClose)),
                "v@:@",
            );

            objc.objc_registerClassPair(objc_class);
        }

        const instance = macos.msgSend0(macos.msgSend0(objc_class.?, "alloc"), "init");

        // Store callback data as associated object
        const data_ptr_value = @intFromPtr(callback_data);
        const NSValue = macos.getClass("NSValue");
        const data_value = macos.msgSend1(
            NSValue,
            "valueWithPointer:",
            @as(?*anyopaque, @ptrFromInt(data_ptr_value)),
        );
        objc.objc_setAssociatedObject(
            instance,
            @ptrFromInt(AssociatedObjectKey),
            data_value,
            objc.OBJC_ASSOCIATION_RETAIN,
        );

        const delegate = try allocator.create(ContextMenuDelegate);
        delegate.* = .{
            .objc_class = objc_class.?,
            .instance = instance,
            .callback_data = callback_data,
            .allocator = allocator,
        };
        return delegate;
    }

    pub fn deinit(self: *ContextMenuDelegate) void {
        if (self.instance != @as(objc.id, null)) {
            _ = macos.msgSend0(self.instance, "release");
        }
        self.callback_data.deinit();
        self.allocator.destroy(self);
    }

    pub fn getInstance(self: *ContextMenuDelegate) objc.id {
        return self.instance;
    }

    pub fn setOnMenuActionCallback(self: *ContextMenuDelegate, callback: *const fn ([]const u8, []const u8, []const u8) void) void {
        self.callback_data.on_menu_action = callback;
    }
};

/// Get callback data from delegate instance
fn getMenuCallbackData(instance: objc.id) ?*MenuCallbackData {
    const associated = objc.objc_getAssociatedObject(instance, @ptrFromInt(ContextMenuDelegate.AssociatedObjectKey));
    if (associated == @as(objc.id, null)) return null;

    const ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(ptr) == 0) return null;

    return @ptrCast(@alignCast(ptr));
}

/// Menu item click handler
export fn menuItemClickedHandler(
    self: objc.id,
    _: objc.SEL,
    sender: objc.id,
) callconv(.c) void {
    const callback_data = getMenuCallbackData(self) orelse return;

    // Get the tag from the menu item (index into item_ids)
    const tag_fn = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) c_long,
        @ptrCast(&objc.objc_msgSend),
    );
    const tag: usize = @intCast(tag_fn(sender, macos.sel("tag")));

    // Get the item ID from our stored array
    const item_id = callback_data.getItemId(tag) orelse {
        std.debug.print("[ContextMenu] No item ID for tag {d}\n", .{tag});
        return;
    };

    std.debug.print("[ContextMenu] Menu item clicked: {s} (target: {s}, type: {s})\n", .{
        item_id,
        callback_data.target_id,
        callback_data.target_type,
    });

    if (callback_data.on_menu_action) |callback| {
        callback(item_id, callback_data.target_id, callback_data.target_type);
    }
}

/// Menu will open handler
export fn menuWillOpenHandler(
    _: objc.id,
    _: objc.SEL,
    _: objc.id, // menu
) callconv(.c) void {
    std.debug.print("[ContextMenu] Menu will open\n", .{});
}

/// Menu did close handler
export fn menuDidCloseHandler(
    _: objc.id,
    _: objc.SEL,
    _: objc.id, // menu
) callconv(.c) void {
    std.debug.print("[ContextMenu] Menu did close\n", .{});
}

/// Create an NSMenu with the given items
pub fn createMenu(allocator: std.mem.Allocator, title: []const u8, items: []const MenuItem, delegate: *ContextMenuDelegate) !objc.id {
    const NSMenu = macos.getClass("NSMenu");

    // Create menu
    const nsTitle = macos.createNSString(title);
    const menu = macos.msgSend1(
        macos.msgSend0(NSMenu, "alloc"),
        "initWithTitle:",
        nsTitle,
    );

    // Set delegate
    _ = macos.msgSend1(menu, "setDelegate:", delegate.getInstance());

    // Add items
    for (items, 0..) |item, index| {
        const menu_item = try createMenuItem(allocator, item, delegate, index);
        _ = macos.msgSend1(menu, "addItem:", menu_item);
    }

    std.debug.print("[ContextMenu] Created menu with {d} items\n", .{items.len});
    return menu;
}

/// Create an NSMenuItem
fn createMenuItem(_: std.mem.Allocator, item: MenuItem, delegate: *ContextMenuDelegate, index: usize) !objc.id {
    const NSMenuItem = macos.getClass("NSMenuItem");

    if (item.item_type == .separator) {
        // Create separator
        return macos.msgSend0(NSMenuItem, "separatorItem");
    }

    // Create regular item
    const nsTitle = macos.createNSString(item.title);

    // Parse keyboard shortcut
    var key_equivalent: objc.id = macos.createNSString("");
    var modifier_mask: c_ulong = 0;

    if (item.shortcut) |shortcut| {
        const parsed = parseShortcut(shortcut);
        key_equivalent = macos.createNSString(parsed.key);
        modifier_mask = parsed.modifiers;
    }

    // Create menu item
    const menu_item = macos.msgSend3(
        macos.msgSend0(NSMenuItem, "alloc"),
        "initWithTitle:action:keyEquivalent:",
        nsTitle,
        macos.sel("menuItemClicked:"),
        key_equivalent,
    );

    // Set target to delegate
    _ = macos.msgSend1(menu_item, "setTarget:", delegate.getInstance());

    // Set tag for identification
    const setTag = @as(
        *const fn (objc.id, objc.SEL, c_long) callconv(.c) void,
        @ptrCast(&objc.objc_msgSend),
    );
    setTag(menu_item, macos.sel("setTag:"), @intCast(index));

    // Store item ID in callback data
    try delegate.callback_data.addItemId(item.id);

    // Set modifier mask if shortcut was provided
    if (modifier_mask != 0) {
        const setKeyEquivalentModifierMask = @as(
            *const fn (objc.id, objc.SEL, c_ulong) callconv(.c) void,
            @ptrCast(&objc.objc_msgSend),
        );
        setKeyEquivalentModifierMask(menu_item, macos.sel("setKeyEquivalentModifierMask:"), modifier_mask);
    }

    // Set enabled state
    const setEnabled = @as(
        *const fn (objc.id, objc.SEL, bool) callconv(.c) void,
        @ptrCast(&objc.objc_msgSend),
    );
    setEnabled(menu_item, macos.sel("setEnabled:"), item.enabled);

    // Set icon if provided
    if (item.icon) |icon_name| {
        const sf_symbols = @import("../macos/sf_symbols.zig");
        if (sf_symbols.createSFSymbol(@ptrCast(icon_name.ptr), .{ .point_size = 14.0 })) |image| {
            _ = macos.msgSend1(menu_item, "setImage:", image);
        }
    }

    // Handle submenu - create nested NSMenu and attach it
    if (item.item_type == .submenu) {
        if (item.submenu_items) |submenu_items| {
            const NSMenu = macos.getClass("NSMenu");
            const submenu = macos.msgSend1(
                macos.msgSend0(NSMenu, "alloc"),
                "initWithTitle:",
                nsTitle,
            );

            // Add submenu items (non-recursive for simplicity - one level deep)
            for (submenu_items, 0..) |sub_item, sub_index| {
                const sub_menu_item = createSubmenuItem(sub_item, delegate, index * 100 + sub_index) catch |err| {
                    std.debug.print("[ContextMenu] Error creating submenu item: {any}\n", .{err});
                    continue;
                };
                _ = macos.msgSend1(submenu, "addItem:", sub_menu_item);
            }

            // Attach submenu to menu item
            _ = macos.msgSend1(menu_item, "setSubmenu:", submenu);
            std.debug.print("[ContextMenu] Created submenu with {d} items for: {s}\n", .{ submenu_items.len, item.title });
        } else {
            std.debug.print("[ContextMenu] Submenu item has no submenu_items: {s}\n", .{item.title});
        }
    }

    return menu_item;
}

/// Create a submenu item (simplified version for nested menus)
fn createSubmenuItem(item: MenuItem, delegate: *ContextMenuDelegate, index: usize) !objc.id {
    const NSMenuItem = macos.getClass("NSMenuItem");

    if (item.item_type == .separator) {
        return macos.msgSend0(NSMenuItem, "separatorItem");
    }

    const nsTitle = macos.createNSString(item.title);

    // Parse keyboard shortcut
    var key_equivalent: objc.id = macos.createNSString("");
    var modifier_mask: c_ulong = 0;

    if (item.shortcut) |shortcut| {
        const parsed = parseShortcut(shortcut);
        key_equivalent = macos.createNSString(parsed.key);
        modifier_mask = parsed.modifiers;
    }

    // Create menu item
    const menu_item = macos.msgSend3(
        macos.msgSend0(NSMenuItem, "alloc"),
        "initWithTitle:action:keyEquivalent:",
        nsTitle,
        macos.sel("menuItemClicked:"),
        key_equivalent,
    );

    // Set target to delegate
    _ = macos.msgSend1(menu_item, "setTarget:", delegate.getInstance());

    // Set tag for identification
    const setTag = @as(
        *const fn (objc.id, objc.SEL, c_long) callconv(.c) void,
        @ptrCast(&objc.objc_msgSend),
    );
    setTag(menu_item, macos.sel("setTag:"), @intCast(index));

    // Store item ID in callback data
    try delegate.callback_data.addItemId(item.id);

    // Set modifier mask if shortcut was provided
    if (modifier_mask != 0) {
        const setKeyEquivalentModifierMask = @as(
            *const fn (objc.id, objc.SEL, c_ulong) callconv(.c) void,
            @ptrCast(&objc.objc_msgSend),
        );
        setKeyEquivalentModifierMask(menu_item, macos.sel("setKeyEquivalentModifierMask:"), modifier_mask);
    }

    // Set enabled state
    const setEnabled = @as(
        *const fn (objc.id, objc.SEL, bool) callconv(.c) void,
        @ptrCast(&objc.objc_msgSend),
    );
    setEnabled(menu_item, macos.sel("setEnabled:"), item.enabled);

    // Set icon if provided
    if (item.icon) |icon_name| {
        const sf_symbols = @import("../macos/sf_symbols.zig");
        if (sf_symbols.createSFSymbol(@ptrCast(icon_name.ptr), .{ .point_size = 14.0 })) |image| {
            _ = macos.msgSend1(menu_item, "setImage:", image);
        }
    }

    return menu_item;
}

/// Parsed shortcut result
const ParsedShortcut = struct {
    key: []const u8,
    modifiers: c_ulong,
};

/// Parse shortcut string (e.g., "cmd+c", "cmd+shift+n")
fn parseShortcut(shortcut: []const u8) ParsedShortcut {
    var modifiers: c_ulong = 0;
    var key: []const u8 = "";

    // Modifier masks
    const NSEventModifierFlagCommand: c_ulong = 1 << 20;
    const NSEventModifierFlagShift: c_ulong = 1 << 17;
    const NSEventModifierFlagOption: c_ulong = 1 << 19;
    const NSEventModifierFlagControl: c_ulong = 1 << 18;

    var iter = std.mem.splitSequence(u8, shortcut, "+");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.eql(u8, trimmed, "cmd") or std.mem.eql(u8, trimmed, "command")) {
            modifiers |= NSEventModifierFlagCommand;
        } else if (std.mem.eql(u8, trimmed, "shift")) {
            modifiers |= NSEventModifierFlagShift;
        } else if (std.mem.eql(u8, trimmed, "opt") or std.mem.eql(u8, trimmed, "option") or std.mem.eql(u8, trimmed, "alt")) {
            modifiers |= NSEventModifierFlagOption;
        } else if (std.mem.eql(u8, trimmed, "ctrl") or std.mem.eql(u8, trimmed, "control")) {
            modifiers |= NSEventModifierFlagControl;
        } else {
            // This is the key
            key = trimmed;
        }
    }

    return .{
        .key = key,
        .modifiers = modifiers,
    };
}

/// Show context menu at the given point in a view
pub fn showContextMenu(menu: objc.id, view: objc.id, point: macos.NSPoint) void {
    // Convert point to a location for popup
    const location = macos.NSPoint{
        .x = point.x,
        .y = point.y,
    };

    // popUpContextMenu:withEvent:forView: needs an event, so use popUpMenuPositioningItem:atLocation:inView:
    const popUp = @as(
        *const fn (objc.id, objc.SEL, objc.id, macos.NSPoint, objc.id) callconv(.c) bool,
        @ptrCast(&objc.objc_msgSend),
    );
    _ = popUp(
        menu,
        macos.sel("popUpMenuPositioningItem:atLocation:inView:"),
        @as(objc.id, null), // nil = position based on location
        location,
        view,
    );

    std.debug.print("[ContextMenu] Showing menu at ({d}, {d})\n", .{ point.x, point.y });
}

/// Create and show a context menu for a sidebar item
pub fn showSidebarContextMenu(
    allocator: std.mem.Allocator,
    view: objc.id,
    point: macos.NSPoint,
    item_id: []const u8,
    items: []const MenuItem,
    callback: *const fn ([]const u8, []const u8, []const u8) void,
) !void {
    const delegate = try ContextMenuDelegate.init(allocator, item_id, "sidebar");
    delegate.setOnMenuActionCallback(callback);

    const menu = try createMenu(allocator, "", items, delegate);
    showContextMenu(menu, view, point);
}

/// Create and show a context menu for a file item
pub fn showFileContextMenu(
    allocator: std.mem.Allocator,
    view: objc.id,
    point: macos.NSPoint,
    file_id: []const u8,
    items: []const MenuItem,
    callback: *const fn ([]const u8, []const u8, []const u8) void,
) !void {
    const delegate = try ContextMenuDelegate.init(allocator, file_id, "file");
    delegate.setOnMenuActionCallback(callback);

    const menu = try createMenu(allocator, "", items, delegate);
    showContextMenu(menu, view, point);
}

/// Default sidebar context menu items
pub const defaultSidebarMenuItems = [_]MenuItem{
    .{ .id = "rename", .title = "Rename...", .icon = "pencil", .shortcut = null },
    .{ .id = "separator1", .title = "", .item_type = .separator },
    .{ .id = "new_folder", .title = "New Folder", .icon = "folder.badge.plus", .shortcut = "cmd+shift+n" },
    .{ .id = "separator2", .title = "", .item_type = .separator },
    .{ .id = "remove", .title = "Remove from Sidebar", .icon = "minus.circle", .shortcut = null },
};

/// Default file context menu items
pub const defaultFileMenuItems = [_]MenuItem{
    .{ .id = "open", .title = "Open", .icon = "arrow.up.forward.square", .shortcut = "cmd+o" },
    .{ .id = "open_with", .title = "Open With...", .icon = "arrow.up.forward.app", .item_type = .submenu, .submenu_items = null },
    .{ .id = "separator1", .title = "", .item_type = .separator },
    .{ .id = "get_info", .title = "Get Info", .icon = "info.circle", .shortcut = "cmd+i" },
    .{ .id = "rename", .title = "Rename", .icon = "pencil", .shortcut = null },
    .{ .id = "separator2", .title = "", .item_type = .separator },
    .{ .id = "copy", .title = "Copy", .icon = "doc.on.doc", .shortcut = "cmd+c" },
    .{ .id = "duplicate", .title = "Duplicate", .icon = "plus.square.on.square", .shortcut = "cmd+d" },
    .{ .id = "separator3", .title = "", .item_type = .separator },
    .{ .id = "move_to_trash", .title = "Move to Trash", .icon = "trash", .shortcut = "cmd+delete" },
};
