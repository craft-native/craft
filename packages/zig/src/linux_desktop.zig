//! GTK3 halves of the desktop bridge: the application menu bar and its
//! accelerators, context menus, file and message dialogs, and file drop.
//!
//! `linux.zig` owns windows and routes page messages; this file owns what
//! those messages build. The request and reply shapes are decided in
//! `desktop_menu.zig`, `desktop_dialog.zig` and `desktop_instance.zig`, which
//! the Windows bridge shares, so nothing here parses a payload of its own.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");
const desktop_dialog = @import("desktop_dialog.zig");
const desktop_instance = @import("desktop_instance.zig");
const desktop_menu = @import("desktop_menu.zig");
const request_context = @import("request_context.zig");
const window_context = @import("window_context.zig");

const allocator = std.heap.c_allocator;

const GdkRectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
const GSList = extern struct { data: ?*anyopaque, next: ?*GSList };
const GValue = extern struct { g_type: usize, data: [2]u64 };
/// The fields every `GdkEvent` starts with.
const GdkEventAny = extern struct { event_type: c_int, window: ?*anyopaque, send_event: i8 };

extern "c" fn g_free(mem: ?*anyopaque) void;
extern "c" fn g_idle_add(function: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
extern "c" fn g_object_ref_sink(object: *anyopaque) *anyopaque;
extern "c" fn g_object_unref(object: *anyopaque) void;
extern "c" fn g_signal_connect_data(instance: *anyopaque, signal: [*:0]const u8, handler: *const anyopaque, data: ?*anyopaque, destroy: ?*anyopaque, flags: c_int) c_ulong;
extern "c" fn g_signal_lookup(name: [*:0]const u8, instance_type: usize) c_uint;
extern "c" fn g_signal_add_emission_hook(signal_id: c_uint, detail: u32, hook: *const fn (*anyopaque, c_uint, [*]const GValue, ?*anyopaque) callconv(.c) c_int, data: ?*anyopaque, destroy: ?*anyopaque) c_ulong;
extern "c" fn g_value_get_object(value: *const GValue) ?*anyopaque;
extern "c" fn g_slist_free(list: ?*GSList) void;
extern "c" fn g_strfreev(strings: ?[*:null]?[*:0]u8) void;
extern "c" fn g_filename_from_uri(uri: [*:0]const u8, hostname: ?*?[*:0]u8, err: ?*?*anyopaque) ?[*:0]u8;
extern "c" fn g_application_get_default() ?*anyopaque;
extern "c" fn g_application_quit(app: *anyopaque) void;

extern "c" fn gtk_widget_get_type() usize;
extern "c" fn gtk_widget_destroy(widget: *anyopaque) void;
extern "c" fn gtk_widget_show_all(widget: *anyopaque) void;
extern "c" fn gtk_widget_set_sensitive(widget: *anyopaque, sensitive: c_int) void;
extern "c" fn gtk_widget_get_window(widget: *anyopaque) ?*anyopaque;
extern "c" fn gtk_widget_show(widget: *anyopaque) void;
extern "c" fn gdk_keyval_to_lower(keyval: c_uint) c_uint;
extern "c" fn gtk_bin_get_child(bin: *anyopaque) ?*anyopaque;
extern "c" fn gtk_box_pack_start(box: *anyopaque, child: *anyopaque, expand: c_int, fill: c_int, padding: c_uint) void;
extern "c" fn gtk_box_reorder_child(box: *anyopaque, child: *anyopaque, position: c_int) void;
extern "c" fn gtk_menu_bar_new() *anyopaque;
extern "c" fn gtk_menu_new() *anyopaque;
extern "c" fn gtk_menu_item_new_with_label(label: [*:0]const u8) *anyopaque;
extern "c" fn gtk_separator_menu_item_new() *anyopaque;
extern "c" fn gtk_menu_item_set_submenu(item: *anyopaque, submenu: ?*anyopaque) void;
extern "c" fn gtk_menu_shell_append(shell: *anyopaque, child: *anyopaque) void;
extern "c" fn gtk_menu_attach_to_widget(menu: *anyopaque, widget: *anyopaque, detacher: ?*anyopaque) void;
extern "c" fn gtk_menu_popup_at_rect(menu: *anyopaque, rect_window: *anyopaque, rect: *const GdkRectangle, rect_anchor: c_int, menu_anchor: c_int, trigger_event: ?*anyopaque) void;
extern "c" fn gtk_accel_label_set_accel(label: *anyopaque, key: c_uint, modifiers: c_uint) void;
extern "c" fn gtk_window_close(window: *anyopaque) void;
extern "c" fn gtk_window_iconify(window: *anyopaque) void;
extern "c" fn gtk_window_maximize(window: *anyopaque) void;
extern "c" fn gtk_window_unmaximize(window: *anyopaque) void;
extern "c" fn gtk_window_is_maximized(window: *anyopaque) c_int;
extern "c" fn gtk_window_fullscreen(window: *anyopaque) void;
extern "c" fn gtk_window_unfullscreen(window: *anyopaque) void;
extern "c" fn gtk_window_get_title(window: *anyopaque) ?[*:0]const u8;
extern "c" fn gtk_window_set_title(window: *anyopaque, title: [*:0]const u8) void;
extern "c" fn gdk_window_get_state(window: *anyopaque) c_uint;
extern "c" fn gdk_window_get_display(window: *anyopaque) *anyopaque;
extern "c" fn gdk_display_get_default_seat(display: *anyopaque) ?*anyopaque;
extern "c" fn gdk_seat_get_pointer(seat: *anyopaque) ?*anyopaque;
extern "c" fn gdk_event_new(event_type: c_int) *GdkEventAny;
extern "c" fn gdk_event_free(event: *GdkEventAny) void;
extern "c" fn gdk_event_set_device(event: *GdkEventAny, device: *anyopaque) void;
extern "c" fn g_object_ref(object: *anyopaque) *anyopaque;

extern "c" fn gtk_file_chooser_native_new(title: ?[*:0]const u8, parent: ?*anyopaque, action: c_int, accept_label: ?[*:0]const u8, cancel_label: ?[*:0]const u8) *anyopaque;
extern "c" fn gtk_native_dialog_run(dialog: *anyopaque) c_int;
extern "c" fn gtk_file_chooser_set_select_multiple(chooser: *anyopaque, multiple: c_int) void;
extern "c" fn gtk_file_chooser_set_current_folder(chooser: *anyopaque, folder: [*:0]const u8) c_int;
extern "c" fn gtk_file_chooser_set_current_name(chooser: *anyopaque, name: [*:0]const u8) void;
extern "c" fn gtk_file_chooser_set_do_overwrite_confirmation(chooser: *anyopaque, confirm: c_int) void;
extern "c" fn gtk_file_chooser_get_filenames(chooser: *anyopaque) ?*GSList;
extern "c" fn gtk_message_dialog_new(parent: ?*anyopaque, flags: c_uint, message_type: c_int, buttons: c_int, format: ?[*:0]const u8, ...) *anyopaque;
extern "c" fn gtk_message_dialog_format_secondary_text(dialog: *anyopaque, format: ?[*:0]const u8, ...) void;
extern "c" fn gtk_dialog_add_button(dialog: *anyopaque, text: [*:0]const u8, response: c_int) *anyopaque;
extern "c" fn gtk_dialog_set_default_response(dialog: *anyopaque, response: c_int) void;
extern "c" fn gtk_dialog_run(dialog: *anyopaque) c_int;

extern "c" fn gtk_selection_data_get_uris(data: *anyopaque) ?[*:null]?[*:0]u8;

extern "c" fn webkit_web_view_run_javascript(webview: *anyopaque, script: [*:0]const u8, cancellable: ?*anyopaque, callback: ?*anyopaque, user_data: ?*anyopaque) void;
extern "c" fn webkit_web_view_execute_editing_command(webview: *anyopaque, command: [*:0]const u8) void;
extern "c" fn webkit_web_view_reload(webview: *anyopaque) void;
extern "c" fn webkit_web_view_reload_bypass_cache(webview: *anyopaque) void;

/// A live window, as `linux.zig`'s registry knows it.
pub const Target = struct { window: usize, webview: usize };

/// Resolves a registry id to its live window. Requests that finish later (a
/// dialog, a context menu) hold the id, never the pointers, so a window closed
/// in the meantime is found to be gone instead of being written to.
pub var lookup: *const fn (id: u32) ?Target = &noWindow;

fn noWindow(_: u32) ?Target {
    return null;
}

fn eval(webview: usize, script: []const u8) void {
    const script_z = @import("memory.zig").dupeZ(allocator, u8, script) catch return;
    defer allocator.free(script_z);
    webkit_web_view_run_javascript(@ptrFromInt(webview), script_z, null, null, null);
}

fn dupeZ(text: []const u8) ?[:0]u8 {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return null;
    return @import("memory.zig").dupeZ(allocator, u8, text) catch null;
}

// ---------------------------------------------------------------------------
// Application menu
// ---------------------------------------------------------------------------

var model: ?desktop_menu.Model = null;
var menu_host: ?u32 = null;
var menu_bar: ?*anyopaque = null;

fn removeMenuWidgets() void {
    if (menu_bar) |bar| {
        gtk_widget_destroy(bar);
        menu_bar = null;
    }
}

/// Forget menu state that belonged to a window being destroyed. GTK destroys
/// the widgets with it.
pub fn windowDestroyed(id: u32) void {
    if (menu_host != null and menu_host.? == id) {
        menu_bar = null;
        menu_host = null;
    }
    drop_cache.clear();
}

fn onMenuItemActivate(_: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    activateCommand(@intCast(@intFromPtr(user_data)));
}

fn activateCommand(command: u16) void {
    const host = lookup(menu_host orelse return) orelse return;
    const current = if (model) |*value| value else return;
    const item = current.byCommand(command) orelse return;
    switch (desktop_menu.activationFor(item)) {
        .action => |id| {
            const script = desktop_menu.actionScript(allocator, id) catch return;
            defer allocator.free(script);
            eval(host.webview, script);
        },
        .settings => eval(host.webview, desktop_menu.settings_script),
        .role => |role| performRole(host, role),
    }
}

fn performRole(host: Target, role: desktop_menu.Role) void {
    const window: *anyopaque = @ptrFromInt(host.window);
    const webview: *anyopaque = @ptrFromInt(host.webview);
    switch (role) {
        .quit => if (g_application_get_default()) |app| g_application_quit(app),
        .close => gtk_window_close(window),
        .minimize => gtk_window_iconify(window),
        .zoom => if (gtk_window_is_maximized(window) != 0) gtk_window_unmaximize(window) else gtk_window_maximize(window),
        .fullscreen => {
            const gdk_window = gtk_widget_get_window(window) orelse return;
            // GDK_WINDOW_STATE_FULLSCREEN
            if ((gdk_window_get_state(gdk_window) & 16) != 0) gtk_window_unfullscreen(window) else gtk_window_fullscreen(window);
        },
        .reload => webkit_web_view_reload(webview),
        .forceReload => webkit_web_view_reload_bypass_cache(webview),
        .undo => webkit_web_view_execute_editing_command(webview, "Undo"),
        .redo => webkit_web_view_execute_editing_command(webview, "Redo"),
        .cut => webkit_web_view_execute_editing_command(webview, "Cut"),
        .copy => webkit_web_view_execute_editing_command(webview, "Copy"),
        .paste => webkit_web_view_execute_editing_command(webview, "Paste"),
        .delete => webkit_web_view_execute_editing_command(webview, "Delete"),
        .selectAll => webkit_web_view_execute_editing_command(webview, "SelectAll"),
        // Reported to the page by `activationFor`, never performed here.
        .about, .settings => {},
    }
}

/// The start of a `GdkEventKey`.
const GdkEventKey = extern struct { event_type: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint };

/// Menu accelerators, matched against the model before the key reaches the
/// page. Connected to each window's `key-press-event`; a key that is not an
/// accelerator of the window showing the menu bar goes on untouched.
fn onWindowKeyPress(_: *anyopaque, event: *const GdkEventKey, user_data: ?*anyopaque) callconv(.c) c_int {
    const id: u32 = @intCast(@intFromPtr(user_data));
    if (menu_host == null or menu_host.? != id) return 0;
    const current = if (model) |*value| value else return 0;
    const key = gdk_keyval_to_lower(event.keyval);
    // Shift, Control and Mod1 (Alt): the modifiers an accelerator can name.
    const modifiers = event.state & 0b1101;
    for (current.menus.items) |*menu| {
        for (menu.items.items) |*item| {
            const shortcut = item.shortcut orelse continue;
            if (item.separator or !item.enabled) continue;
            if (item.role) |role| if (role.isEditing()) continue;
            if (shortcut.gdkKeyval() != key or shortcut.gdkModifiers() != modifiers) continue;
            activateCommand(item.command);
            return 1; // handled: the page does not also see it
        }
    }
    return 0;
}

/// Watch a window's keys for menu accelerators.
pub fn attachWindow(window: *anyopaque, id: u32) void {
    _ = g_signal_connect_data(window, "key-press-event", @ptrCast(&onWindowKeyPress), @ptrFromInt(@as(usize, id)), null, 0);
}

fn buildMenuItem(item: *const desktop_menu.Item) ?*anyopaque {
    if (item.separator) {
        const separator = gtk_separator_menu_item_new();
        gtk_widget_show(separator);
        return separator;
    }
    // GTK's check item toggles itself when chosen. The page decides what is
    // checked, so the mark is drawn from the model and never by the toolkit.
    var label_buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer label_buffer.deinit(allocator);
    if (item.checked) label_buffer.appendSlice(allocator, "\u{2713} ") catch return null;
    label_buffer.appendSlice(allocator, item.label) catch return null;
    const label = dupeZ(label_buffer.items) orelse return null;
    defer allocator.free(label);
    const widget = gtk_menu_item_new_with_label(label);
    gtk_widget_set_sensitive(widget, if (item.enabled) 1 else 0);
    if (item.shortcut) |shortcut| {
        // Drawn beside the item. The binding itself is `onWindowKeyPress`.
        if (gtk_bin_get_child(widget)) |accel_label|
            gtk_accel_label_set_accel(accel_label, shortcut.gdkKeyval(), shortcut.gdkModifiers());
    }
    gtk_widget_show(widget);
    _ = g_signal_connect_data(widget, "activate", @ptrCast(&onMenuItemActivate), @ptrFromInt(@as(usize, item.command)), null, 0);
    return widget;
}

fn rebuildMenu() void {
    removeMenuWidgets();
    const current = if (model) |*value| value else return;
    if (current.isEmpty()) return;
    const host = lookup(menu_host orelse return) orelse return;
    const window: *anyopaque = @ptrFromInt(host.window);
    // `linux.zig` places every web view inside a vertical box so a menu bar
    // has somewhere to go.
    const box = gtk_bin_get_child(window) orelse return;

    const bar = gtk_menu_bar_new();
    for (current.menus.items) |*menu| {
        const title = dupeZ(menu.label) orelse continue;
        defer allocator.free(title);
        const top = gtk_menu_item_new_with_label(title);
        const submenu = gtk_menu_new();
        for (menu.items.items) |*item| {
            if (buildMenuItem(item)) |widget| gtk_menu_shell_append(submenu, widget);
        }
        gtk_menu_item_set_submenu(top, submenu);
        gtk_menu_shell_append(bar, top);
    }
    gtk_box_pack_start(box, bar, 0, 0, 0);
    gtk_box_reorder_child(box, bar, 0);
    gtk_widget_show_all(bar);
    menu_bar = bar;
}

/// `craft.menu.*`. The sender's window becomes the one that shows the bar.
pub fn handleMenu(action: []const u8, data: ?[]const u8, sender: u32) !void {
    const payload = data orelse "{}";
    if (model == null) model = desktop_menu.Model.init(allocator);
    const current = &model.?;
    const eql = std.mem.eql;
    var changed = false;
    if (eql(u8, action, "setAppMenu") or eql(u8, action, "setApplicationMenu")) {
        try current.set(payload);
        if (menu_host == null or menu_host.? != sender) {
            removeMenuWidgets();
            menu_host = sender;
        }
        changed = true;
    } else if (eql(u8, action, "addMenuItem")) {
        changed = try current.addItem(payload);
    } else if (eql(u8, action, "removeMenuItem")) {
        changed = try current.removeItem(payload);
    } else if (eql(u8, action, "enableMenuItem")) {
        changed = try current.setEnabled(payload, true);
    } else if (eql(u8, action, "disableMenuItem")) {
        changed = try current.setEnabled(payload, false);
    } else if (eql(u8, action, "checkMenuItem")) {
        changed = try current.setChecked(payload, true);
    } else if (eql(u8, action, "uncheckMenuItem")) {
        changed = try current.setChecked(payload, false);
    } else if (eql(u8, action, "setMenuItemLabel")) {
        changed = try current.setLabel(payload);
    } else if (eql(u8, action, "setDockMenu") or eql(u8, action, "clearDockMenu")) {
        // The Dock is a macOS surface. Accepted so one menu setup runs
        // everywhere; there is nothing to draw.
        return;
    } else return error.UnknownAction;
    if (changed) rebuildMenu();
}

// ---------------------------------------------------------------------------
// Deferred requests
// ---------------------------------------------------------------------------

const Request = struct {
    sender: u32,
    request_id: ?u64,
    action_name: []const u8,
    data: ?[]u8,

    fn create(sender: u32, action_name: []const u8, data: ?[]const u8) !*Request {
        const request = try allocator.create(Request);
        errdefer allocator.destroy(request);
        const name = try allocator.dupe(u8, action_name);
        errdefer allocator.free(name);
        request.* = .{
            .sender = sender,
            .request_id = request_context.current(),
            .action_name = name,
            .data = if (data) |text| try allocator.dupe(u8, text) else null,
        };
        return request;
    }

    fn destroy(self: *Request) void {
        if (self.data) |text| allocator.free(text);
        allocator.free(self.action_name);
        allocator.destroy(self);
    }

    /// Answer the page that asked, if its window is still open.
    fn reply(self: *const Request, json: []const u8) void {
        const target = lookup(self.sender) orelse return;
        window_context.push(target.window, target.webview);
        defer window_context.pop();
        request_context.push(self.request_id);
        defer request_context.pop();
        bridge_error.sendResultToJS(allocator, self.action_name, json);
    }

    fn fail(self: *const Request, err: anyerror) void {
        const target = lookup(self.sender) orelse return;
        window_context.push(target.window, target.webview);
        defer window_context.pop();
        request_context.push(self.request_id);
        defer request_context.pop();
        bridge_error.sendErrorToJS(allocator, self.action_name, bridge_error.fromHandlerError(err));
    }
};

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

/// `craft.dialog.*`. The panel runs from an idle callback, after the WebKit
/// message that asked for it has returned: a modal dialog spins its own main
/// loop, and that must not happen inside WebKit's message delivery.
pub fn queueDialog(action_name: []const u8, data: ?[]const u8, sender: u32) !void {
    if (desktop_dialog.Action.parse(action_name) == null) return error.UnknownAction;
    const request = try Request.create(sender, action_name, data);
    if (g_idle_add(&runDialog, request) == 0) {
        request.destroy();
        return error.NativeCallFailed;
    }
}

fn runDialog(user_data: ?*anyopaque) callconv(.c) c_int {
    const request: *Request = @ptrCast(@alignCast(user_data.?));
    defer request.destroy();
    const target = lookup(request.sender) orelse return 0;
    const action = desktop_dialog.Action.parse(request.action_name) orelse return 0;
    const parent: *anyopaque = @ptrFromInt(target.window);
    const data: ?[]const u8 = if (request.data) |text| text else null;
    switch (action) {
        .open_file, .open_files, .open_folder, .save_file => runFileDialog(request, parent, action, data) catch |err| request.fail(err),
        .show_alert, .show_confirm => runMessageDialog(request, parent, action == .show_confirm, data) catch |err| request.fail(err),
    }
    return 0; // G_SOURCE_REMOVE
}

fn runFileDialog(request: *const Request, parent: *anyopaque, action: desktop_dialog.Action, data: ?[]const u8) !void {
    var options = desktop_dialog.parse(desktop_dialog.FileOptions, allocator, data);
    defer options.deinit();
    const title = if (options.value.title.len > 0) dupeZ(options.value.title) else null;
    defer if (title) |text| allocator.free(text);
    const accept = if (options.value.buttonLabel.len > 0) dupeZ(options.value.buttonLabel) else null;
    defer if (accept) |text| allocator.free(text);
    // GTK_FILE_CHOOSER_ACTION_OPEN, _SAVE, _SELECT_FOLDER
    const chooser_action: c_int = switch (action) {
        .save_file => 1,
        .open_folder => 2,
        else => 0,
    };
    const chooser = gtk_file_chooser_native_new(
        if (title) |text| text.ptr else null,
        parent,
        chooser_action,
        if (accept) |text| text.ptr else null,
        null,
    );
    defer g_object_unref(chooser);
    if (action == .open_files) gtk_file_chooser_set_select_multiple(chooser, 1);
    if (options.value.defaultPath.len > 0) {
        if (dupeZ(options.value.defaultPath)) |folder| {
            defer allocator.free(folder);
            _ = gtk_file_chooser_set_current_folder(chooser, folder);
        }
    }
    if (action == .save_file) {
        gtk_file_chooser_set_do_overwrite_confirmation(chooser, 1);
        if (options.value.defaultName.len > 0) {
            if (dupeZ(options.value.defaultName)) |name| {
                defer allocator.free(name);
                gtk_file_chooser_set_current_name(chooser, name);
            }
        }
    }

    // GTK_RESPONSE_ACCEPT
    const accepted = gtk_native_dialog_run(chooser) == -3;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    if (accepted) {
        const list = gtk_file_chooser_get_filenames(chooser);
        defer g_slist_free(list);
        var node = list;
        while (node) |entry| : (node = entry.next) {
            const raw: [*:0]u8 = @ptrCast(entry.data orelse continue);
            defer g_free(raw);
            const copy = allocator.dupe(u8, std.mem.span(raw)) catch continue;
            paths.append(allocator, copy) catch allocator.free(copy);
        }
    }
    const json = if (action == .save_file)
        try desktop_dialog.saveResult(allocator, if (paths.items.len > 0) paths.items[0] else null)
    else
        try desktop_dialog.openResult(allocator, paths.items);
    defer allocator.free(json);
    request.reply(json);
}

fn runMessageDialog(request: *const Request, parent: *anyopaque, confirm: bool, data: ?[]const u8) !void {
    var options = desktop_dialog.parse(desktop_dialog.MessageOptions, allocator, data);
    defer options.deinit();
    const buttons = desktop_dialog.buttonsFor(options.value, confirm);
    // With only one of the two texts, it is the heading.
    const heading_text = if (options.value.title.len > 0) options.value.title else options.value.message;
    const body_text = if (options.value.title.len > 0) options.value.message else "";
    const heading = dupeZ(heading_text) orelse return error.InvalidParameter;
    defer allocator.free(heading);

    // GTK_MESSAGE_INFO, _WARNING, _QUESTION, _ERROR
    const message_type: c_int = switch (desktop_dialog.styleOf(options.value)) {
        .warning => 1,
        .critical => 3,
        .info => if (confirm) 2 else 0,
    };
    // GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, GTK_BUTTONS_NONE
    const dialog = gtk_message_dialog_new(parent, 3, message_type, 0, "%s", heading.ptr);
    defer gtk_widget_destroy(dialog);
    if (body_text.len > 0) {
        if (dupeZ(body_text)) |body| {
            defer allocator.free(body);
            gtk_message_dialog_format_secondary_text(dialog, "%s", body.ptr);
        }
    }
    if (gtk_window_get_title(parent)) |parent_title| gtk_window_set_title(dialog, parent_title);
    // Added last to first: GTK lays buttons out left to right, and the first
    // button is the affirmative one, which belongs at the trailing edge.
    var index = buttons.len;
    while (index > 0) {
        index -= 1;
        const label = dupeZ(buttons[index]) orelse continue;
        defer allocator.free(label);
        _ = gtk_dialog_add_button(dialog, label, @intCast(index));
    }
    gtk_dialog_set_default_response(dialog, 0);

    const response = gtk_dialog_run(dialog);
    const chosen: usize = if (response >= 0 and response < buttons.len)
        @intCast(response)
    else
        desktop_dialog.dismissedIndex(buttons);
    var buffer: [48]u8 = undefined;
    request.reply(desktop_dialog.messageResult(&buffer, confirm, chosen));
}

// ---------------------------------------------------------------------------
// Context menus
// ---------------------------------------------------------------------------

const ContextRequest = struct {
    request: *Request,
    menu: desktop_menu.ContextMenu,
    widget: *anyopaque,
    chosen: usize = 0,
    finishing: bool = false,
};

fn onContextItemActivate(_: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    // The item's number was packed beside the request pointer's owner: each
    // item carries its own small heap cell.
    const cell: *ContextCell = @ptrCast(@alignCast(user_data.?));
    cell.owner.chosen = cell.number;
}

const ContextCell = struct { owner: *ContextRequest, number: usize };

fn freeContextCell(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const cell: *ContextCell = @ptrCast(@alignCast(data.?));
    allocator.destroy(cell);
}

fn appendContextItems(owner: *ContextRequest, shell: *anyopaque, items: []const desktop_menu.ContextItem, counter: *usize) void {
    for (items) |*item| {
        counter.* += 1;
        if (item.separator) {
            const separator = gtk_separator_menu_item_new();
            gtk_widget_show(separator);
            gtk_menu_shell_append(shell, separator);
            continue;
        }
        var label_buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer label_buffer.deinit(allocator);
        if (item.checked) label_buffer.appendSlice(allocator, "\u{2713} ") catch continue;
        label_buffer.appendSlice(allocator, item.title) catch continue;
        const label = dupeZ(label_buffer.items) orelse continue;
        defer allocator.free(label);
        const widget = gtk_menu_item_new_with_label(label);
        gtk_widget_set_sensitive(widget, if (item.enabled) 1 else 0);
        if (item.shortcut) |shortcut| {
            if (gtk_bin_get_child(widget)) |accel_label|
                gtk_accel_label_set_accel(accel_label, shortcut.gdkKeyval(), shortcut.gdkModifiers());
        }
        if (item.submenu.len > 0) {
            const submenu = gtk_menu_new();
            appendContextItems(owner, submenu, item.submenu, counter);
            gtk_menu_item_set_submenu(widget, submenu);
        } else {
            const cell = allocator.create(ContextCell) catch continue;
            cell.* = .{ .owner = owner, .number = counter.* };
            _ = g_signal_connect_data(widget, "activate", @ptrCast(&onContextItemActivate), cell, @ptrCast(@constCast(&freeContextCell)), 0);
        }
        gtk_widget_show(widget);
        gtk_menu_shell_append(shell, widget);
    }
}

fn onContextDeactivate(_: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const owner: *ContextRequest = @ptrCast(@alignCast(user_data.?));
    if (owner.finishing) return;
    owner.finishing = true;
    // GTK closes the menu before it activates the chosen item. Finish on the
    // next turn of the loop, once the item has had its say.
    if (g_idle_add(&finishContextMenu, owner) == 0) _ = finishContextMenu(owner);
}

fn finishContextMenu(user_data: ?*anyopaque) callconv(.c) c_int {
    const owner: *ContextRequest = @ptrCast(@alignCast(user_data.?));
    defer {
        gtk_widget_destroy(owner.widget);
        g_object_unref(owner.widget);
        owner.menu.deinit();
        owner.request.destroy();
        allocator.destroy(owner);
    }
    const chosen = if (owner.chosen > 0) owner.menu.idFor(owner.chosen) else null;
    const json = owner.menu.resultJson(allocator, chosen) catch return 0;
    defer allocator.free(json);
    owner.request.reply(json);
    if (lookup(owner.request.sender)) |target| {
        const script = desktop_menu.contextEventScript(allocator, json) catch return 0;
        defer allocator.free(script);
        eval(target.webview, script);
    }
    return 0;
}

/// `craft.nativeUI.showContextMenu`. Replies when the menu closes, with the
/// chosen item's id or null.
pub fn showContextMenu(data: ?[]const u8, sender: u32) !void {
    const target = lookup(sender) orelse return error.WindowHandleNotSet;
    var menu = try desktop_menu.parseContextMenu(allocator, data orelse return error.MissingData);
    errdefer menu.deinit();
    const webview: *anyopaque = @ptrFromInt(target.webview);
    const gdk_window = gtk_widget_get_window(webview) orelse return error.NativeCallFailed;
    const request = try Request.create(sender, "showContextMenu", null);
    errdefer request.destroy();
    const owner = try allocator.create(ContextRequest);
    errdefer allocator.destroy(owner);

    const widget = g_object_ref_sink(gtk_menu_new());
    owner.* = .{ .request = request, .menu = menu, .widget = widget };
    var counter: usize = 0;
    appendContextItems(owner, widget, owner.menu.items, &counter);
    gtk_menu_attach_to_widget(widget, webview, null);
    _ = g_signal_connect_data(widget, "deactivate", @ptrCast(&onContextDeactivate), owner, null, 0);
    gtk_widget_show_all(widget);
    const rect = GdkRectangle{ .x = owner.menu.x, .y = owner.menu.y, .width = 1, .height = 1 };
    // The request arrived as a page message, not as the click that prompted
    // it, so GTK has no current event to take the pointer and the window
    // from. Give it one: a press on this web view by the seat's pointer.
    const trigger = gdk_event_new(4); // GDK_BUTTON_PRESS
    defer gdk_event_free(trigger);
    trigger.window = g_object_ref(gdk_window);
    if (gdk_display_get_default_seat(gdk_window_get_display(gdk_window))) |seat| {
        if (gdk_seat_get_pointer(seat)) |pointer| gdk_event_set_device(trigger, pointer);
    }
    // GDK_GRAVITY_NORTH_WEST for both anchors: the menu's corner at the point.
    gtk_menu_popup_at_rect(widget, gdk_window, &rect, 1, 1, trigger);
}

// ---------------------------------------------------------------------------
// File drop
// ---------------------------------------------------------------------------

/// WebKit asks the drag source for its data while the pointer is still over
/// the view, and GTK tells us about the drop itself in a signal WebKit's own
/// handler ends before a later handler runs. So the paths are remembered when
/// they arrive, and an emission hook (which runs before any handler) delivers
/// them when the drop for that same drag begins.
const DropCache = struct {
    widget: usize = 0,
    context: usize = 0,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,

    fn clear(self: *DropCache) void {
        for (self.paths.items) |path| allocator.free(path);
        self.paths.clearRetainingCapacity();
        self.widget = 0;
        self.context = 0;
    }
};

var drop_cache: DropCache = .{};
var drop_hook_installed = false;

fn onDragDataReceived(widget: *anyopaque, context: *anyopaque, _: c_int, _: c_int, selection: *anyopaque, _: c_uint, _: c_uint, _: ?*anyopaque) callconv(.c) void {
    const uris = gtk_selection_data_get_uris(selection) orelse return;
    defer g_strfreev(uris);
    drop_cache.clear();
    var index: usize = 0;
    while (uris[index]) |uri| : (index += 1) {
        const path = g_filename_from_uri(uri, null, null) orelse continue;
        defer g_free(path);
        const copy = allocator.dupe(u8, std.mem.span(path)) catch continue;
        drop_cache.paths.append(allocator, copy) catch allocator.free(copy);
    }
    if (drop_cache.paths.items.len == 0) return;
    drop_cache.widget = @intFromPtr(widget);
    drop_cache.context = @intFromPtr(context);
}

fn onDragDropEmission(_: *anyopaque, count: c_uint, values: [*]const GValue, _: ?*anyopaque) callconv(.c) c_int {
    // Stay installed whatever happens: returning 0 removes the hook.
    if (count < 2 or drop_cache.widget == 0) return 1;
    const widget = g_value_get_object(&values[0]) orelse return 1;
    const context = g_value_get_object(&values[1]) orelse return 1;
    if (@intFromPtr(widget) != drop_cache.widget or @intFromPtr(context) != drop_cache.context) return 1;
    defer drop_cache.clear();
    const script = desktop_instance.fileDropScript(allocator, drop_cache.paths.items) catch return 1;
    defer allocator.free(script);
    eval(drop_cache.widget, script);
    return 1;
}

/// Watch a web view for files dropped on it.
pub fn attachFileDrop(webview: *anyopaque) void {
    _ = g_signal_connect_data(webview, "drag-data-received", @ptrCast(&onDragDataReceived), null, null, 0);
    if (drop_hook_installed) return;
    const signal = g_signal_lookup("drag-drop", gtk_widget_get_type());
    if (signal == 0) return;
    drop_hook_installed = g_signal_add_emission_hook(signal, 0, &onDragDropEmission, null, null) != 0;
}
