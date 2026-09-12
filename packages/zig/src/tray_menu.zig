const std = @import("std");
const builtin = @import("builtin");
const logging = @import("logging.zig");

const log = logging.menu;

/// System Tray Menu Implementation
/// Handles creation and management of context menus for system tray icons
/// Supports macOS, Windows, and Linux platforms

// Objective-C runtime types (manual declarations for Zig 0.16+ compatibility)
const objc = if (builtin.target.os.tag == .macos) struct {
    pub const id = ?*anyopaque;
    pub const Class = ?*anyopaque;
    pub const SEL = ?*anyopaque;
    pub const IMP = ?*anyopaque;
    pub const BOOL = bool;

    pub extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
    pub extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
    pub extern "objc" fn objc_msgSend() void;
    pub extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extraBytes: usize) Class;
    pub extern "objc" fn objc_registerClassPair(cls: Class) void;
    pub extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) BOOL;
} else struct {
    pub const id = *anyopaque;
    pub const Class = *anyopaque;
    pub const SEL = *anyopaque;
};

// Helper functions for Objective-C message sending
fn getClass(name: [*:0]const u8) if (builtin.target.os.tag == .macos) objc.id else *anyopaque {
    if (builtin.target.os.tag != .macos) unreachable;
    const class_ptr = objc.objc_getClass(name);
    return @ptrCast(@alignCast(class_ptr));
}

fn msgSend0(target: anytype, selector: [*:0]const u8) if (builtin.target.os.tag == .macos) objc.id else *anyopaque {
    if (builtin.target.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, objc.sel_registerName(selector));
}

fn msgSend1(target: anytype, selector: [*:0]const u8, arg1: anytype) if (builtin.target.os.tag == .macos) objc.id else *anyopaque {
    if (builtin.target.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1)) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, objc.sel_registerName(selector), arg1);
}

fn msgSend2(target: anytype, selector: [*:0]const u8, arg1: anytype, arg2: anytype) if (builtin.target.os.tag == .macos) objc.id else *anyopaque {
    if (builtin.target.os.tag != .macos) unreachable;
    const Arg1Type = if (@TypeOf(arg1) == @TypeOf(null)) ?*anyopaque else @TypeOf(arg1);
    const Arg2Type = if (@TypeOf(arg2) == @TypeOf(null)) ?*anyopaque else @TypeOf(arg2);
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, Arg1Type, Arg2Type) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    const typed_arg1: Arg1Type = if (@TypeOf(arg1) == @TypeOf(null)) null else arg1;
    const typed_arg2: Arg2Type = if (@TypeOf(arg2) == @TypeOf(null)) null else arg2;
    return msg(target, objc.sel_registerName(selector), typed_arg1, typed_arg2);
}

fn msgSendVoid1(target: anytype, selector: [*:0]const u8, arg1: anytype) void {
    if (builtin.target.os.tag != .macos) unreachable;
    const Arg1Type = if (@TypeOf(arg1) == @TypeOf(null)) ?*anyopaque else @TypeOf(arg1);
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, Arg1Type) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    const typed_arg1: Arg1Type = if (@TypeOf(arg1) == @TypeOf(null)) null else arg1;
    msg(target, objc.sel_registerName(selector), typed_arg1);
}

fn msgSend4(target: anytype, selector: [*:0]const u8, arg1: anytype, arg2: anytype, arg3: anytype) if (builtin.target.os.tag == .macos) objc.id else *anyopaque {
    if (builtin.target.os.tag != .macos) unreachable;
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1), @TypeOf(arg2), @TypeOf(arg3)) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, objc.sel_registerName(selector), arg1, arg2, arg3);
}

fn createNSString(str: []const u8) if (builtin.target.os.tag == .macos) objc.id else *anyopaque {
    if (builtin.target.os.tag != .macos) unreachable;
    const NSString = getClass("NSString");

    // Create a null-terminated copy for stringWithUTF8String:
    const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, str) catch {
        // If allocation fails, return empty string
        const empty: [*:0]const u8 = @ptrCast("");
        return msgSend1(NSString, "stringWithUTF8String:", empty);
    };
    defer std.heap.c_allocator.free(cstr);

    return msgSend1(NSString, "stringWithUTF8String:", cstr.ptr);
}

/// Menu item configuration from JavaScript
pub const MenuItemConfig = struct {
    id: ?[]const u8 = null,
    label: ?[]const u8 = null,
    type: []const u8 = "normal", // "normal", "separator", "checkbox", "radio"
    checked: bool = false,
    enabled: bool = true,
    action: ?[]const u8 = null,
    shortcut: ?[]const u8 = null,
    submenu: ?[]const MenuItemConfig = null,
};

/// Parse menu JSON from JavaScript
pub fn parseMenuJSON(allocator: std.mem.Allocator, json_str: []const u8) ![]MenuItemConfig {
    log.debug("parseMenuJSON: input len={}, str={s}", .{ json_str.len, json_str });

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch |err| {
        log.debug("parseMenuJSON: JSON parse error: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    log.debug("parseMenuJSON: JSON parsed successfully", .{});

    const root = parsed.value;
    if (root != .array) {
        log.debug("parseMenuJSON: root is not array", .{});
        return error.InvalidMenuJSON;
    }

    const items_array = root.array.items;
    log.debug("parseMenuJSON: array has {} items", .{items_array.len});

    var items = try allocator.alloc(MenuItemConfig, items_array.len);

    for (items_array, 0..) |item_value, i| {
        log.debug("parseMenuJSON: parsing item {}", .{i});
        items[i] = parseMenuItem(allocator, item_value) catch |err| {
            log.debug("parseMenuJSON: item {} parse error: {}", .{ i, err });
            return err;
        };
    }

    log.debug("parseMenuJSON: all items parsed successfully", .{});
    return items;
}

fn parseMenuItem(allocator: std.mem.Allocator, value: std.json.Value) !MenuItemConfig {
    if (value != .object) return error.InvalidMenuItem;

    const obj = value.object;
    var item = MenuItemConfig{};

    if (obj.get("id")) |id_val| {
        if (id_val == .string) {
            item.id = try allocator.dupe(u8, id_val.string);
        }
    }

    if (obj.get("label")) |label_val| {
        if (label_val == .string) {
            item.label = try allocator.dupe(u8, label_val.string);
        }
    }

    if (obj.get("type")) |type_val| {
        if (type_val == .string) {
            item.type = try allocator.dupe(u8, type_val.string);
        }
    }

    if (obj.get("checked")) |checked_val| {
        if (checked_val == .bool) {
            item.checked = checked_val.bool;
        }
    }

    if (obj.get("enabled")) |enabled_val| {
        if (enabled_val == .bool) {
            item.enabled = enabled_val.bool;
        }
    }

    if (obj.get("action")) |action_val| {
        if (action_val == .string) {
            item.action = try allocator.dupe(u8, action_val.string);
        }
    }

    if (obj.get("shortcut")) |shortcut_val| {
        if (shortcut_val == .string) {
            item.shortcut = try allocator.dupe(u8, shortcut_val.string);
        }
    }

    return item;
}

// Primary window references for menu actions. Runtime-created windows call the
// same setup path, but a window with no sender context must stay anchored to
// the app's first page rather than whichever child was constructed last.
var global_webview: ?*anyopaque = null;
var global_window_handle: ?*anyopaque = null;

pub fn setGlobalWebView(webview: *anyopaque) void {
    if (global_webview == null) global_webview = webview;
}

pub fn setGlobalWindow(window: *anyopaque) void {
    if (global_window_handle == null) global_window_handle = window;
}

pub fn getGlobalWindow() ?*anyopaque {
    return global_window_handle;
}

pub fn getGlobalWebView() ?*anyopaque {
    return global_webview;
}

/// Menu action callback - called when a menu item is clicked
pub export fn menuActionCallback(self: objc.id, _: objc.SEL, sender: objc.id) void {
    _ = self;

    if (builtin.target.os.tag != .macos) return;

    // Get the action string from the menu item's represented object
    const represented_object = msgSend0(sender, "representedObject");
    if (represented_object == null) return;

    // Get the C string from NSString
    const action_cstr = @as([*:0]const u8, @ptrCast(msgSend0(represented_object, "UTF8String")));
    const action_str = std.mem.span(action_cstr);

    log.debug("Triggered: {s}", .{action_str});

    // Handle built-in actions
    if (std.mem.eql(u8, action_str, "show")) {
        // If menu bar is collapsed, expand it first
        const menubar_collapse = @import("menubar_collapse.zig");
        if (menubar_collapse.isCollapsed()) {
            menubar_collapse.expand();
            log.debug("Menu bar expanded via show action", .{});
        }

        if (global_window_handle) |window| {
            const macos = @import("macos.zig");
            // Activate the app first (required for menubar-only/accessory apps)
            const NSApp = getClass("NSApplication");
            const nsapp = msgSend0(NSApp, "sharedApplication");
            msgSendVoid1(nsapp, "activateIgnoringOtherApps:", @as(c_int, 1));
            macos.showWindow(window);
            log.debug("Window shown", .{});
        } else {
            log.debug("WARNING: global_window_handle is null, cannot show window", .{});
        }
    } else if (std.mem.eql(u8, action_str, "hide")) {
        if (global_window_handle) |window| {
            const macos = @import("macos.zig");
            macos.hideWindow(window);
        }
    } else if (std.mem.eql(u8, action_str, "toggle")) {
        if (global_window_handle) |window| {
            const macos = @import("macos.zig");
            macos.toggleWindow(window);
        }
    } else if (std.mem.eql(u8, action_str, "quit")) {
        // Restore any hidden menubar items before quitting
        const menubar_collapse = @import("menubar_collapse.zig");
        menubar_collapse.cleanup();

        const NSApp = getClass("NSApplication");
        const app = msgSend0(NSApp, "sharedApplication");
        msgSendVoid1(app, "terminate:", null);
    } else if (std.mem.eql(u8, action_str, "preferences") or std.mem.eql(u8, action_str, "about")) {
        // Built-in actions that show the window
        if (global_window_handle) |window| {
            const macos = @import("macos.zig");
            // Activate the app first (required for menubar-only/accessory apps)
            const NSApp_pref = getClass("NSApplication");
            const nsapp_pref = msgSend0(NSApp_pref, "sharedApplication");
            msgSendVoid1(nsapp_pref, "activateIgnoringOtherApps:", @as(c_int, 1));
            macos.showWindow(window);
        }
        // Also dispatch to JS so the app can handle it (e.g., navigate to preferences view)
        if (global_webview) |webview| {
            const webview_id: objc.id = @ptrFromInt(@intFromPtr(webview));
            dispatchMenuActionToJS(webview_id, action_str) catch |err| {
                log.debug("Failed to dispatch to JS: {}", .{err});
            };
        }
    } else if (std.mem.eql(u8, action_str, "toggleMenubar")) {
        // Built-in: toggle menu bar collapse directly
        const menubar_collapse = @import("menubar_collapse.zig");
        menubar_collapse.toggle();
    } else {
        // Dispatch custom action to JavaScript
        log.debug("Custom action - dispatching to JS", .{});
        if (global_webview) |webview| {
            log.debug("Webview found, sending to JS", .{});
            const webview_id: objc.id = @ptrFromInt(@intFromPtr(webview));
            dispatchMenuActionToJS(webview_id, action_str) catch |err| {
                log.debug("Failed to dispatch to JS: {}", .{err});
            };
        } else {
            log.debug("ERROR: No global webview set!", .{});
        }
    }
}

// Queue for pending menu actions
const ActionQueue = struct {
    items: [16][]const u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn push(self: *ActionQueue, action: []const u8) void {
        if (self.count >= 16) return; // Queue full
        self.items[self.tail] = action;
        self.tail = (self.tail + 1) % 16;
        self.count += 1;
    }

    fn pop(self: *ActionQueue) ?[]const u8 {
        if (self.count == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % 16;
        self.count -= 1;
        return item;
    }
};

var action_queue = ActionQueue{};

pub fn hasPendingAction() bool {
    return action_queue.count > 0;
}

pub fn pollPendingActions(allocator: std.mem.Allocator) ![]const u8 {
    if (action_queue.pop()) |action| {
        log.debug("Polled action: {s}", .{action});
        return try allocator.dupe(u8, action);
    }
    return "";
}

pub fn getPendingAction() ?[]const u8 {
    return action_queue.pop();
}

fn dispatchMenuActionToJS(webview: objc.id, action: []const u8) !void {
    _ = webview;
    log.debug("Queuing action: {s}", .{action});

    // Add to queue for JavaScript to poll
    action_queue.push(action);
}

/// Create menu action target
fn createMenuTarget() objc.id {
    if (builtin.target.os.tag != .macos) unreachable;

    // Create a simple NSObject to act as the target
    const NSObject = getClass("NSObject");
    const target = msgSend0(msgSend0(NSObject, "alloc"), "init");

    return target;
}

// Store menu target globally so it doesn't get deallocated
var global_menu_target: ?objc.id = null;

/// Create NSMenu from menu configuration (macOS)
pub fn createNSMenu(allocator: std.mem.Allocator, items: []const MenuItemConfig) !*anyopaque {
    if (builtin.target.os.tag != .macos) return error.PlatformNotSupported;

    _ = allocator;

    // Create menu target if it doesn't exist
    if (global_menu_target == null) {
        global_menu_target = createMenuTarget();
    }

    const NSMenu = getClass("NSMenu");
    const menu = msgSend0(msgSend0(NSMenu, "alloc"), "init");

    for (items) |item| {
        try addMenuItem(menu, item);
    }

    return @ptrFromInt(@as(usize, @intCast(@intFromPtr(menu))));
}

fn addMenuItem(menu: objc.id, item: MenuItemConfig) !void {
    if (builtin.target.os.tag != .macos) return;

    // Handle separator
    if (std.mem.eql(u8, item.type, "separator")) {
        const NSMenuItem = getClass("NSMenuItem");
        const separator = msgSend0(NSMenuItem, "separatorItem");
        msgSendVoid1(menu, "addItem:", separator);
        return;
    }

    // Create regular menu item
    const NSMenuItem = getClass("NSMenuItem");
    const menu_item = msgSend0(msgSend0(NSMenuItem, "alloc"), "init");

    // Set title
    if (item.label) |label| {
        const title_str = createNSString(label);
        msgSendVoid1(menu_item, "setTitle:", title_str);
    }

    // Set enabled state
    const enabled_val: c_int = if (item.enabled) 1 else 0;
    msgSendVoid1(menu_item, "setEnabled:", enabled_val);

    // Set action if provided
    if (item.action) |action_str| {
        // Set target and action
        if (global_menu_target) |target| {
            msgSendVoid1(menu_item, "setTarget:", target);
        }

        // Register our C function as a method on NSObject
        // This is a bit of a hack - we're adding a method at runtime
        const NSObject = getClass("NSObject");
        const method_sel = objc.sel_registerName("menuAction:");
        const method_imp: objc.IMP = @ptrCast(@constCast(&menuActionCallback));
        const method_types: [*c]const u8 = "v@:@";
        const method_added = objc.class_addMethod(
            @ptrCast(@alignCast(NSObject)),
            method_sel,
            method_imp,
            method_types,
        );
        _ = method_added; // Ignore if already added

        const action_sel = objc.sel_registerName("menuAction:");
        msgSendVoid1(menu_item, "setAction:", action_sel);

        // Store the action string in the menu item's represented object
        const action_ns_str = createNSString(action_str);
        msgSendVoid1(menu_item, "setRepresentedObject:", action_ns_str);
    }

    // Set keyboard shortcut if provided
    if (item.shortcut) |shortcut| {
        const shortcut_str = createNSString(shortcut);
        msgSendVoid1(menu_item, "setKeyEquivalent:", shortcut_str);
    }

    // Add to menu
    msgSendVoid1(menu, "addItem:", menu_item);
}

/// Cleanup menu resources
pub fn destroyNSMenu(menu: *anyopaque) void {
    if (builtin.target.os.tag != .macos) return;

    const ns_menu: objc.id = @ptrFromInt(@intFromPtr(menu));
    _ = msgSend0(ns_menu, "release");
}
