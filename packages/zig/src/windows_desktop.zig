//! Win32 halves of the desktop bridge: the application menu bar and its
//! accelerators, context menus, file and message dialogs, and file drop.
//!
//! `windows.zig` owns windows and the WebView2 plumbing; this file owns what
//! `craft.menu`, `craft.dialog`, `craft.nativeUI.showContextMenu` and
//! `craft.onFileDrop` build on top of it. The request and reply shapes are
//! decided in `desktop_menu.zig`, `desktop_dialog.zig` and
//! `desktop_instance.zig`, which the Linux bridge shares.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");
const desktop_dialog = @import("desktop_dialog.zig");
const desktop_instance = @import("desktop_instance.zig");
const desktop_menu = @import("desktop_menu.zig");
const request_context = @import("request_context.zig");
const window_context = @import("window_context.zig");
const win = @import("windows.zig");

const allocator = std.heap.c_allocator;

const HWND = win.HWND;
const HMENU = win.HMENU;
const HRESULT = win.HRESULT;
const GUID = win.GUID;
const LPCWSTR = win.LPCWSTR;
const LPWSTR = win.LPWSTR;
const BOOL = win.BOOL;
const UINT = win.UINT;
const POINT = win.POINT;

extern "user32" fn CreateMenu() callconv(.c) ?HMENU;
extern "user32" fn CreatePopupMenu() callconv(.c) ?HMENU;
extern "user32" fn AppendMenuW(menu: HMENU, flags: UINT, id: usize, text: ?LPCWSTR) callconv(.c) BOOL;
extern "user32" fn SetMenu(window: HWND, menu: ?HMENU) callconv(.c) BOOL;
extern "user32" fn GetMenu(window: HWND) callconv(.c) ?HMENU;
extern "user32" fn DestroyMenu(menu: HMENU) callconv(.c) BOOL;
extern "user32" fn DrawMenuBar(window: HWND) callconv(.c) BOOL;
extern "user32" fn TrackPopupMenu(menu: HMENU, flags: UINT, x: c_int, y: c_int, reserved: c_int, window: HWND, rect: ?*const win.RECT) callconv(.c) BOOL;
extern "user32" fn ClientToScreen(window: HWND, point: *POINT) callconv(.c) BOOL;
extern "user32" fn SetForegroundWindow(window: HWND) callconv(.c) BOOL;
extern "user32" fn GetKeyState(key: c_int) callconv(.c) c_short;
extern "user32" fn GetAncestor(window: HWND, flags: UINT) callconv(.c) ?HWND;
extern "user32" fn SendInput(count: UINT, inputs: [*]const INPUT, size: c_int) callconv(.c) UINT;
extern "user32" fn MessageBoxW(window: ?HWND, text: LPCWSTR, caption: LPCWSTR, flags: UINT) callconv(.c) c_int;
extern "ole32" fn CoCreateInstance(class: *const GUID, outer: ?*anyopaque, context: u32, interface: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT;
extern "shell32" fn SHCreateItemFromParsingName(path: LPCWSTR, bind_context: ?*anyopaque, interface: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT;

const MF_GRAYED: UINT = 0x0001;
const MF_CHECKED: UINT = 0x0008;
const MF_POPUP: UINT = 0x0010;
const MF_SEPARATOR: UINT = 0x0800;
const WM_NULL: UINT = 0x0000;
const WM_COMMAND: UINT = 0x0111;
const WM_KEYDOWN: UINT = 0x0100;
const WM_SYSKEYDOWN: UINT = 0x0104;
const VK_SHIFT: c_int = 0x10;
const VK_CONTROL: c_int = 0x11;
const VK_MENU: c_int = 0x12;
/// Posted to a window with work queued here. WM_APP + 2; `windows.zig` uses
/// WM_APP + 1 for queued window opens.
pub const WM_CRAFT_DESKTOP: UINT = 0x8002;

/// A live window, as `windows.zig`'s registry knows it.
pub const Target = struct { window: usize, webview: usize, controller: usize };

/// Resolves a registry id to its live window. Work that finishes later holds
/// the id, never the handles, so a window closed in the meantime is found to
/// be gone instead of being written to.
pub var lookup: *const fn (id: u32) ?Target = &noWindow;
/// Toggles borderless fullscreen through `windows.zig`, which owns that state.
pub var toggle_fullscreen: *const fn (id: u32) void = &noToggle;
/// Closes every window, which ends the message loop.
pub var quit: *const fn () void = &noQuit;

fn noWindow(_: u32) ?Target {
    return null;
}
fn noToggle(_: u32) void {}
fn noQuit() void {}

fn wide(text: []const u8) ?[:0]u16 {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return null;
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch null;
}

fn utf8(text: LPCWSTR) ?[]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(text)) catch null;
}

// ---------------------------------------------------------------------------
// Application menu
// ---------------------------------------------------------------------------

var model: ?desktop_menu.Model = null;
var menu_host: ?u32 = null;

/// The text Win32 draws for an item: `&` doubled so it is not read as a
/// mnemonic marker, and the accelerator after a tab so it is right-aligned.
fn menuText(label: []const u8, shortcut: ?desktop_menu.Shortcut) ?[:0]u16 {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    for (label) |byte| {
        if (byte == '&') text.append(allocator, '&') catch return null;
        text.append(allocator, byte) catch return null;
    }
    if (shortcut) |value| {
        var buffer: [32]u8 = undefined;
        const drawn = value.format(&buffer);
        if (drawn.len > 0) {
            text.append(allocator, '\t') catch return null;
            text.appendSlice(allocator, drawn) catch return null;
        }
    }
    return wide(text.items);
}

fn detachMenu(id: u32) void {
    const host = lookup(id) orelse return;
    const hwnd: HWND = @ptrFromInt(host.window);
    const old = GetMenu(hwnd);
    _ = SetMenu(hwnd, null);
    if (old) |menu| _ = DestroyMenu(menu);
    _ = DrawMenuBar(hwnd);
}

fn rebuildMenu() void {
    const id = menu_host orelse return;
    const host = lookup(id) orelse return;
    const hwnd: HWND = @ptrFromInt(host.window);
    const current = if (model) |*value| value else return;
    if (current.isEmpty()) return detachMenu(id);

    const bar = CreateMenu() orelse return;
    for (current.menus.items) |*menu| {
        const popup = CreatePopupMenu() orelse continue;
        for (menu.items.items) |*item| {
            if (item.separator) {
                _ = AppendMenuW(popup, MF_SEPARATOR, 0, null);
                continue;
            }
            const text = menuText(item.label, item.shortcut) orelse continue;
            defer allocator.free(text);
            var flags: UINT = 0;
            if (!item.enabled) flags |= MF_GRAYED;
            if (item.checked) flags |= MF_CHECKED;
            _ = AppendMenuW(popup, flags, item.command, text.ptr);
        }
        const title = menuText(menu.label, null) orelse {
            _ = DestroyMenu(popup);
            continue;
        };
        defer allocator.free(title);
        if (AppendMenuW(bar, MF_POPUP, @intFromPtr(popup), title.ptr) == 0) _ = DestroyMenu(popup);
    }
    const old = GetMenu(hwnd);
    if (SetMenu(hwnd, bar) == 0) {
        _ = DestroyMenu(bar);
        return;
    }
    // A menu bar that is no longer assigned to a window is not destroyed
    // with it.
    if (old) |menu| _ = DestroyMenu(menu);
    _ = DrawMenuBar(hwnd);
}

/// Forget menu state that belonged to a window being destroyed. Windows
/// destroys the menu assigned to it.
pub fn windowDestroyed(id: u32) void {
    if (menu_host != null and menu_host.? == id) menu_host = null;
    discardPending(id);
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
        if (menu_host) |previous| {
            if (previous != sender) detachMenu(previous);
        }
        menu_host = sender;
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

/// A `WM_COMMAND` from the menu bar of window `id`. True if it named an item.
pub fn onCommand(id: u32, command: u16) bool {
    if (menu_host == null or menu_host.? != id) return false;
    const host = lookup(id) orelse return false;
    const current = if (model) |*value| value else return false;
    const item = current.byCommand(command) orelse return false;
    switch (desktop_menu.activationFor(item)) {
        .action => |action_id| {
            const script = desktop_menu.actionScript(allocator, action_id) catch return true;
            defer allocator.free(script);
            win.evalInWebview(host.webview, script);
        },
        .settings => win.evalInWebview(host.webview, desktop_menu.settings_script),
        .role => |role| performRole(id, host, role),
    }
    return true;
}

const KEYBDINPUT = extern struct { wVk: u16, wScan: u16 = 0, dwFlags: u32 = 0, time: u32 = 0, dwExtraInfo: usize = 0 };
/// `INPUT` with its keyboard member. The union's largest member is the mouse
/// one, eight bytes longer, which the padding stands in for.
const INPUT = extern struct { type: u32 = 1, ki: KEYBDINPUT, padding: [8]u8 = @splat(0) };

comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(INPUT) == 40);
}

/// Type a key chord into the focused control. The editing commands have no
/// WebView2 API, and a script cannot paste; the web content already performs
/// them correctly for the keys a person would press.
fn sendChord(host: Target, ctrl: bool, key: u16) void {
    const controller: *win.ICoreWebView2Controller = @ptrFromInt(host.controller);
    // COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC
    _ = controller.lpVtbl.MoveFocus(controller, 0);
    const key_up: u32 = 0x0002;
    var inputs: [4]INPUT = undefined;
    var count: usize = 0;
    if (ctrl) {
        inputs[count] = .{ .ki = .{ .wVk = 0x11 } };
        count += 1;
    }
    inputs[count] = .{ .ki = .{ .wVk = key } };
    count += 1;
    inputs[count] = .{ .ki = .{ .wVk = key, .dwFlags = key_up } };
    count += 1;
    if (ctrl) {
        inputs[count] = .{ .ki = .{ .wVk = 0x11, .dwFlags = key_up } };
        count += 1;
    }
    _ = SendInput(@intCast(count), &inputs, @sizeOf(INPUT));
}

fn performRole(id: u32, host: Target, role: desktop_menu.Role) void {
    const hwnd: HWND = @ptrFromInt(host.window);
    const webview: *win.ICoreWebView2 = @ptrFromInt(host.webview);
    switch (role) {
        .quit => quit(),
        .close => _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0),
        .minimize => _ = win.ShowWindow(hwnd, win.SW_MINIMIZE),
        // SW_RESTORE
        .zoom => _ = win.ShowWindow(hwnd, if (win.IsZoomed(hwnd) != 0) 9 else win.SW_MAXIMIZE),
        .fullscreen => toggle_fullscreen(id),
        // WebView2 has one reload; both roles use it.
        .reload, .forceReload => _ = webview.lpVtbl.Reload(webview),
        .undo => sendChord(host, true, 'Z'),
        .redo => sendChord(host, true, 'Y'),
        .cut => sendChord(host, true, 'X'),
        .copy => sendChord(host, true, 'C'),
        .paste => sendChord(host, true, 'V'),
        .selectAll => sendChord(host, true, 'A'),
        .delete => sendChord(host, false, 0x2E),
        // Reported to the page by `activationFor`, never performed here.
        .about, .settings => {},
    }
}

fn keyHeld(key: c_int) bool {
    return GetKeyState(key) < 0;
}

/// The menu command a key press activates in window `id`, if any.
fn acceleratorCommand(id: u32, virtual_key: u16) ?u16 {
    if (menu_host == null or menu_host.? != id) return null;
    const current = if (model) |*value| value else return null;
    const item = current.byVirtualKey(virtual_key, keyHeld(VK_CONTROL), keyHeld(VK_MENU), keyHeld(VK_SHIFT)) orelse return null;
    return item.command;
}

/// A key message from the application's message loop. WebView2 reports keys
/// pressed inside the page through `AcceleratorKeyHandler` instead; this
/// covers focus resting on the window itself. True when the key was a menu
/// accelerator and has been dispatched.
pub fn translateKeyMessage(id_of: *const fn (window: usize) ?u32, message: *const win.MSG) bool {
    if (message.message != WM_KEYDOWN and message.message != WM_SYSKEYDOWN) return false;
    const hwnd = message.hwnd orelse return false;
    // GA_ROOT
    const root = GetAncestor(hwnd, 2) orelse hwnd;
    const id = id_of(@intFromPtr(root)) orelse return false;
    const command = acceleratorCommand(id, @truncate(message.wParam)) orelse return false;
    // Bit 30: the key was already down, so this is auto-repeat.
    if ((message.lParam & (1 << 30)) == 0) _ = win.PostMessageW(root, WM_COMMAND, command, 0);
    return true;
}

const ICoreWebView2AcceleratorKeyPressedEventArgs = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        get_KeyEventKind: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *c_int) callconv(.c) HRESULT,
        get_VirtualKey: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *UINT) callconv(.c) HRESULT,
        get_KeyEventLParam: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *c_int) callconv(.c) HRESULT,
        get_PhysicalKeyStatus: *const anyopaque,
        get_Handled: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, *BOOL) callconv(.c) HRESULT,
        put_Handled: *const fn (*ICoreWebView2AcceleratorKeyPressedEventArgs, BOOL) callconv(.c) HRESULT,
    },
};

/// Receives the accelerator keys WebView2 sees while the page has focus,
/// before the page does. A key that is a menu accelerator is marked handled
/// and turned into the same `WM_COMMAND` a click on the item sends.
pub const AcceleratorKeyHandler = extern struct {
    lpVtbl: *const Vtbl,
    ref_count: c_ulong,
    window_id: u32,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*AcceleratorKeyHandler, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*AcceleratorKeyHandler) callconv(.c) c_ulong,
        Release: *const fn (*AcceleratorKeyHandler) callconv(.c) c_ulong,
        Invoke: *const fn (*AcceleratorKeyHandler, *win.ICoreWebView2Controller, *ICoreWebView2AcceleratorKeyPressedEventArgs) callconv(.c) HRESULT,
    };

    const vtbl_instance = Vtbl{
        .QueryInterface = &queryInterface,
        .AddRef = &addRef,
        .Release = &release,
        .Invoke = &invoke,
    };

    pub fn create(window_id: u32) !*AcceleratorKeyHandler {
        const handler = try allocator.create(AcceleratorKeyHandler);
        handler.* = .{ .lpVtbl = &vtbl_instance, .ref_count = 1, .window_id = window_id };
        return handler;
    }

    fn queryInterface(self: *AcceleratorKeyHandler, _: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT {
        out.* = @ptrCast(self);
        _ = addRef(self);
        return win.S_OK;
    }

    fn addRef(self: *AcceleratorKeyHandler) callconv(.c) c_ulong {
        self.ref_count += 1;
        return self.ref_count;
    }

    pub fn release(self: *AcceleratorKeyHandler) callconv(.c) c_ulong {
        if (self.ref_count > 0) self.ref_count -= 1;
        const remaining = self.ref_count;
        if (remaining == 0) allocator.destroy(self);
        return remaining;
    }

    fn invoke(self: *AcceleratorKeyHandler, _: *win.ICoreWebView2Controller, args: *ICoreWebView2AcceleratorKeyPressedEventArgs) callconv(.c) HRESULT {
        var kind: c_int = 0;
        var key: UINT = 0;
        var key_lparam: c_int = 0;
        if (args.lpVtbl.get_KeyEventKind(args, &kind) < 0 or args.lpVtbl.get_VirtualKey(args, &key) < 0) return win.S_OK;
        // COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN and _SYSTEM_KEY_DOWN
        if (kind != 0 and kind != 2) return win.S_OK;
        const command = acceleratorCommand(self.window_id, @truncate(key)) orelse return win.S_OK;
        _ = args.lpVtbl.put_Handled(args, 1);
        _ = args.lpVtbl.get_KeyEventLParam(args, &key_lparam);
        if ((key_lparam & (1 << 30)) != 0) return win.S_OK;
        const host = lookup(self.window_id) orelse return win.S_OK;
        // Posted, not run here: an item may open a dialog, and a modal loop
        // must not start inside a WebView2 callback.
        _ = win.PostMessageW(@ptrFromInt(host.window), WM_COMMAND, command, 0);
        return win.S_OK;
    }
};

// ---------------------------------------------------------------------------
// Deferred requests
// ---------------------------------------------------------------------------

const Kind = enum { dialog, context_menu };

const Request = struct {
    next: ?*Request = null,
    kind: Kind,
    sender: u32,
    request_id: ?u64,
    action_name: []const u8,
    data: ?[]u8,

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

var pending_head: ?*Request = null;
var pending_tail: ?*Request = null;
var pending_count: usize = 0;
const max_pending = 32;

/// Queue work that opens a modal loop (a dialog, a popup menu). WebView2 must
/// not be re-entered from inside its own message callback, so the work runs
/// from a posted window message after that callback has returned.
fn enqueue(kind: Kind, action_name: []const u8, data: ?[]const u8, sender: u32) !void {
    if (pending_count >= max_pending) return error.TooManyRequests;
    const target = lookup(sender) orelse return error.WindowHandleNotSet;
    const request = try allocator.create(Request);
    errdefer allocator.destroy(request);
    const name = try allocator.dupe(u8, action_name);
    errdefer allocator.free(name);
    const copy: ?[]u8 = if (data) |text| try allocator.dupe(u8, text) else null;
    errdefer if (copy) |text| allocator.free(text);
    request.* = .{
        .kind = kind,
        .sender = sender,
        .request_id = request_context.current(),
        .action_name = name,
        .data = copy,
    };
    if (win.PostMessageW(@ptrFromInt(target.window), WM_CRAFT_DESKTOP, 0, 0) == 0) return error.NativeCallFailed;
    if (pending_tail) |tail| tail.next = request else pending_head = request;
    pending_tail = request;
    pending_count += 1;
}

fn discardPending(sender: u32) void {
    var previous: ?*Request = null;
    var current = pending_head;
    while (current) |request| {
        const next = request.next;
        if (request.sender == sender) {
            if (previous) |prior| prior.next = next else pending_head = next;
            if (pending_tail == request) pending_tail = previous;
            pending_count -= 1;
            request.destroy();
        } else previous = request;
        current = next;
    }
}

/// Run one queued request. Called for each `WM_CRAFT_DESKTOP`; every queued
/// request posted exactly one, so a dialog opened from inside another
/// dialog's modal loop is served by its own message.
pub fn processPending() void {
    const request = pending_head orelse return;
    pending_head = request.next;
    if (pending_head == null) pending_tail = null;
    pending_count -= 1;
    defer request.destroy();
    const target = lookup(request.sender) orelse return;
    const data: ?[]const u8 = if (request.data) |text| text else null;
    switch (request.kind) {
        .dialog => runDialog(request, target, data) catch |err| request.fail(err),
        .context_menu => runContextMenu(request, target, data) catch |err| request.fail(err),
    }
}

pub fn queueDialog(action_name: []const u8, data: ?[]const u8, sender: u32) !void {
    if (desktop_dialog.Action.parse(action_name) == null) return error.UnknownAction;
    try enqueue(.dialog, action_name, data, sender);
}

pub fn queueContextMenu(data: ?[]const u8, sender: u32) !void {
    // Refuse a malformed menu now, while the caller can still be told.
    var menu = try desktop_menu.parseContextMenu(allocator, data orelse return error.MissingData);
    menu.deinit();
    try enqueue(.context_menu, "showContextMenu", data, sender);
}

// ---------------------------------------------------------------------------
// Context menus
// ---------------------------------------------------------------------------

fn appendContextItems(popup: HMENU, items: []const desktop_menu.ContextItem, counter: *usize) void {
    for (items) |*item| {
        counter.* += 1;
        if (item.separator) {
            _ = AppendMenuW(popup, MF_SEPARATOR, 0, null);
            continue;
        }
        const text = menuText(item.title, item.shortcut) orelse continue;
        defer allocator.free(text);
        var flags: UINT = 0;
        if (!item.enabled) flags |= MF_GRAYED;
        if (item.checked) flags |= MF_CHECKED;
        if (item.submenu.len > 0) {
            const nested = CreatePopupMenu() orelse continue;
            appendContextItems(nested, item.submenu, counter);
            if (AppendMenuW(popup, flags | MF_POPUP, @intFromPtr(nested), text.ptr) == 0) _ = DestroyMenu(nested);
        } else {
            _ = AppendMenuW(popup, flags, counter.*, text.ptr);
        }
    }
}

fn runContextMenu(request: *const Request, target: Target, data: ?[]const u8) !void {
    var menu = try desktop_menu.parseContextMenu(allocator, data orelse return error.MissingData);
    defer menu.deinit();
    const hwnd: HWND = @ptrFromInt(target.window);
    const popup = CreatePopupMenu() orelse return error.NativeCallFailed;
    defer _ = DestroyMenu(popup);
    var counter: usize = 0;
    appendContextItems(popup, menu.items, &counter);

    // The page's coordinates are relative to the web view, which fills the
    // window's client area.
    var point = POINT{ .x = menu.x, .y = menu.y };
    _ = ClientToScreen(hwnd, &point);
    // A popup menu only closes on an outside click if its owner is the
    // foreground window, and needs a message afterwards to finish closing.
    _ = SetForegroundWindow(hwnd);
    // TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_RETURNCMD
    const chosen_number = TrackPopupMenu(popup, 0x0002 | 0x0080 | 0x0100, point.x, point.y, 0, hwnd, null);
    _ = win.PostMessageW(hwnd, WM_NULL, 0, 0);

    const chosen = if (chosen_number > 0) menu.idFor(@intCast(chosen_number)) else null;
    const json = try menu.resultJson(allocator, chosen);
    defer allocator.free(json);
    request.reply(json);
    const live = lookup(request.sender) orelse return;
    const script = try desktop_menu.contextEventScript(allocator, json);
    defer allocator.free(script);
    win.evalInWebview(live.webview, script);
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

fn runDialog(request: *const Request, target: Target, data: ?[]const u8) !void {
    const action = desktop_dialog.Action.parse(request.action_name) orelse return error.UnknownAction;
    const hwnd: HWND = @ptrFromInt(target.window);
    switch (action) {
        .open_file, .open_files, .open_folder, .save_file => try runFileDialog(request, hwnd, action, data),
        .show_alert, .show_confirm => try runMessageDialog(request, hwnd, action == .show_confirm, data),
    }
}

/// A COM object reached through its vtable by slot number. The shell dialog
/// interfaces have dozens of methods and this file calls nine of them.
const ComObject = extern struct {
    vtable: [*]const *const anyopaque,

    fn method(self: *ComObject, comptime slot: usize, comptime Function: type) *const Function {
        return @ptrCast(@alignCast(self.vtable[slot]));
    }

    fn release(self: *ComObject) void {
        _ = self.method(2, fn (*ComObject) callconv(.c) c_ulong)(self);
    }
};

// IFileDialog (after IUnknown and IModalWindow::Show at slot 3).
const slot_show = 3;
const slot_set_options = 9;
const slot_get_options = 10;
const slot_set_folder = 12;
const slot_set_file_name = 15;
const slot_set_title = 17;
const slot_set_ok_button_label = 18;
const slot_get_result = 20;
// IFileOpenDialog.
const slot_get_results = 27;
// IShellItem.
const slot_item_get_display_name = 5;
// IShellItemArray.
const slot_array_get_count = 7;
const slot_array_get_item_at = 8;

const clsid_file_open_dialog = GUID{ .Data1 = 0xDC1C5A9C, .Data2 = 0xE88A, .Data3 = 0x4DDE, .Data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };
const clsid_file_save_dialog = GUID{ .Data1 = 0xC0B4E2F3, .Data2 = 0xBA21, .Data3 = 0x4773, .Data4 = .{ 0x8D, 0xBA, 0x33, 0x5E, 0xC9, 0x46, 0xEB, 0x8B } };
const iid_file_open_dialog = GUID{ .Data1 = 0xD57C7288, .Data2 = 0xD4AD, .Data3 = 0x4768, .Data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };
const iid_file_save_dialog = GUID{ .Data1 = 0x84BCCD23, .Data2 = 0x5FDE, .Data3 = 0x4CDB, .Data4 = .{ 0xAE, 0xA4, 0xAF, 0x64, 0xB8, 0x3D, 0x78, 0xAB } };
const iid_shell_item = GUID{ .Data1 = 0x43826D1E, .Data2 = 0xE718, .Data3 = 0x42EE, .Data4 = .{ 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE } };

const FOS_PICKFOLDERS: u32 = 0x20;
const FOS_FORCEFILESYSTEM: u32 = 0x40;
const FOS_ALLOWMULTISELECT: u32 = 0x200;
const SIGDN_FILESYSPATH: u32 = 0x80058000;

fn shellItemPath(item: *ComObject) ?[]u8 {
    var name: ?LPWSTR = null;
    const get_display_name = item.method(slot_item_get_display_name, fn (*ComObject, u32, *?LPWSTR) callconv(.c) HRESULT);
    if (get_display_name(item, SIGDN_FILESYSPATH, &name) < 0) return null;
    const text = name orelse return null;
    defer win.CoTaskMemFree(@ptrCast(text));
    return utf8(text);
}

fn runFileDialog(request: *const Request, hwnd: HWND, action: desktop_dialog.Action, data: ?[]const u8) !void {
    var options = desktop_dialog.parse(desktop_dialog.FileOptions, allocator, data);
    defer options.deinit();
    const saving = action == .save_file;

    var raw: ?*anyopaque = null;
    // CLSCTX_INPROC_SERVER
    const created = CoCreateInstance(
        if (saving) &clsid_file_save_dialog else &clsid_file_open_dialog,
        null,
        1,
        if (saving) &iid_file_save_dialog else &iid_file_open_dialog,
        &raw,
    );
    if (created < 0) return error.NativeCallFailed;
    const dialog: *ComObject = @ptrCast(@alignCast(raw orelse return error.NativeCallFailed));
    defer dialog.release();

    var flags: u32 = 0;
    _ = dialog.method(slot_get_options, fn (*ComObject, *u32) callconv(.c) HRESULT)(dialog, &flags);
    flags |= FOS_FORCEFILESYSTEM;
    if (action == .open_folder) flags |= FOS_PICKFOLDERS;
    if (action == .open_files) flags |= FOS_ALLOWMULTISELECT;
    _ = dialog.method(slot_set_options, fn (*ComObject, u32) callconv(.c) HRESULT)(dialog, flags);

    const SetText = fn (*ComObject, LPCWSTR) callconv(.c) HRESULT;
    if (options.value.title.len > 0) if (wide(options.value.title)) |text| {
        defer allocator.free(text);
        _ = dialog.method(slot_set_title, SetText)(dialog, text.ptr);
    };
    if (options.value.buttonLabel.len > 0) if (wide(options.value.buttonLabel)) |text| {
        defer allocator.free(text);
        _ = dialog.method(slot_set_ok_button_label, SetText)(dialog, text.ptr);
    };
    if (saving and options.value.defaultName.len > 0) if (wide(options.value.defaultName)) |text| {
        defer allocator.free(text);
        _ = dialog.method(slot_set_file_name, SetText)(dialog, text.ptr);
    };
    if (options.value.defaultPath.len > 0) if (wide(options.value.defaultPath)) |text| {
        defer allocator.free(text);
        var folder_raw: ?*anyopaque = null;
        if (SHCreateItemFromParsingName(text.ptr, null, &iid_shell_item, &folder_raw) >= 0) {
            if (folder_raw) |pointer| {
                const folder: *ComObject = @ptrCast(@alignCast(pointer));
                defer folder.release();
                _ = dialog.method(slot_set_folder, fn (*ComObject, *ComObject) callconv(.c) HRESULT)(dialog, folder);
            }
        }
    };

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    // Any failure, including the user's cancel, leaves `paths` empty.
    if (dialog.method(slot_show, fn (*ComObject, ?HWND) callconv(.c) HRESULT)(dialog, hwnd) >= 0) {
        if (saving or action != .open_files) {
            var item_raw: ?*anyopaque = null;
            if (dialog.method(slot_get_result, fn (*ComObject, *?*anyopaque) callconv(.c) HRESULT)(dialog, &item_raw) >= 0) {
                if (item_raw) |pointer| {
                    const item: *ComObject = @ptrCast(@alignCast(pointer));
                    defer item.release();
                    if (shellItemPath(item)) |path| paths.append(allocator, path) catch allocator.free(path);
                }
            }
        } else {
            var array_raw: ?*anyopaque = null;
            if (dialog.method(slot_get_results, fn (*ComObject, *?*anyopaque) callconv(.c) HRESULT)(dialog, &array_raw) >= 0) {
                if (array_raw) |pointer| {
                    const array: *ComObject = @ptrCast(@alignCast(pointer));
                    defer array.release();
                    var count: u32 = 0;
                    _ = array.method(slot_array_get_count, fn (*ComObject, *u32) callconv(.c) HRESULT)(array, &count);
                    var index: u32 = 0;
                    while (index < count) : (index += 1) {
                        var item_raw: ?*anyopaque = null;
                        if (array.method(slot_array_get_item_at, fn (*ComObject, u32, *?*anyopaque) callconv(.c) HRESULT)(array, index, &item_raw) < 0) continue;
                        const item: *ComObject = @ptrCast(@alignCast(item_raw orelse continue));
                        defer item.release();
                        if (shellItemPath(item)) |path| paths.append(allocator, path) catch allocator.free(path);
                    }
                }
            }
        }
    }

    const json = if (saving)
        try desktop_dialog.saveResult(allocator, if (paths.items.len > 0) paths.items[0] else null)
    else
        try desktop_dialog.openResult(allocator, paths.items);
    defer allocator.free(json);
    request.reply(json);
}

const TASKDIALOG_BUTTON = extern struct {
    id: c_int align(1),
    text: LPCWSTR align(1),
};

/// `TASKDIALOGCONFIG`. The Windows header declares it with one-byte packing.
const TASKDIALOGCONFIG = extern struct {
    cbSize: UINT align(1) = 160,
    hwndParent: ?HWND align(1) = null,
    hInstance: ?*anyopaque align(1) = null,
    dwFlags: u32 align(1) = 0,
    dwCommonButtons: u32 align(1) = 0,
    pszWindowTitle: ?LPCWSTR align(1) = null,
    pszMainIcon: usize align(1) = 0,
    pszMainInstruction: ?LPCWSTR align(1) = null,
    pszContent: ?LPCWSTR align(1) = null,
    cButtons: UINT align(1) = 0,
    pButtons: ?[*]const TASKDIALOG_BUTTON align(1) = null,
    nDefaultButton: c_int align(1) = 0,
    cRadioButtons: UINT align(1) = 0,
    pRadioButtons: ?*const anyopaque align(1) = null,
    nDefaultRadioButton: c_int align(1) = 0,
    pszVerificationText: ?LPCWSTR align(1) = null,
    pszExpandedInformation: ?LPCWSTR align(1) = null,
    pszExpandedControlText: ?LPCWSTR align(1) = null,
    pszCollapsedControlText: ?LPCWSTR align(1) = null,
    pszFooterIcon: usize align(1) = 0,
    pszFooter: ?LPCWSTR align(1) = null,
    pfCallback: ?*const anyopaque align(1) = null,
    lpCallbackData: isize align(1) = 0,
    cxWidth: UINT align(1) = 0,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(TASKDIALOGCONFIG) == 160);
        std.debug.assert(@sizeOf(TASKDIALOG_BUTTON) == 12);
    }
}

const TaskDialogIndirectFn = *const fn (*const TASKDIALOGCONFIG, ?*c_int, ?*c_int, ?*BOOL) callconv(.c) HRESULT;
const first_button_id: c_int = 100;

/// `TaskDialogIndirect` lives in version 6 of the common controls, which a
/// process only gets when its manifest asks for it. The `craft` executable's
/// does; an embedder's may not, so it is looked up, never imported.
fn taskDialog() ?TaskDialogIndirectFn {
    const name = [_:0]u16{ 'c', 'o', 'm', 'c', 't', 'l', '3', '2', '.', 'd', 'l', 'l' };
    const library = win.LoadLibraryW(&name) orelse return null;
    const symbol = win.GetProcAddress(library, "TaskDialogIndirect") orelse return null;
    return @ptrCast(@alignCast(symbol));
}

fn windowTitle(hwnd: HWND) ?[:0]u16 {
    const length = win.GetWindowTextLengthW(hwnd);
    if (length <= 0) return null;
    const buffer = allocator.allocSentinel(u16, @intCast(length), 0) catch return null;
    const written = win.GetWindowTextW(hwnd, buffer.ptr, length + 1);
    if (written <= 0) {
        allocator.free(buffer);
        return null;
    }
    return buffer;
}

fn runMessageDialog(request: *const Request, hwnd: HWND, confirm: bool, data: ?[]const u8) !void {
    var options = desktop_dialog.parse(desktop_dialog.MessageOptions, allocator, data);
    defer options.deinit();
    const buttons = desktop_dialog.buttonsFor(options.value, confirm);
    // With only one of the two texts, it is the heading.
    const heading_text = if (options.value.title.len > 0) options.value.title else options.value.message;
    const body_text = if (options.value.title.len > 0) options.value.message else "";
    const heading = wide(heading_text) orelse return error.InvalidParameter;
    defer allocator.free(heading);
    const body = wide(body_text) orelse return error.InvalidParameter;
    defer allocator.free(body);
    const caption = windowTitle(hwnd);
    defer if (caption) |text| allocator.free(text);
    const empty = [_:0]u16{};
    const style = desktop_dialog.styleOf(options.value);

    var chosen: usize = desktop_dialog.dismissedIndex(buttons);
    if (taskDialog()) |show| {
        var labels: [desktop_dialog.max_buttons]?[:0]u16 = @splat(null);
        defer for (labels) |label| if (label) |text| allocator.free(text);
        var native_buttons: [desktop_dialog.max_buttons]TASKDIALOG_BUTTON = undefined;
        var count: usize = 0;
        for (buttons, 0..) |label, index| {
            const text = wide(label) orelse continue;
            labels[index] = text;
            native_buttons[count] = .{ .id = first_button_id + @as(c_int, @intCast(index)), .text = text.ptr };
            count += 1;
        }
        var config = TASKDIALOGCONFIG{
            .hwndParent = hwnd,
            // TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW | TDF_SIZE_TO_CONTENT
            .dwFlags = 0x0008 | 0x1000 | 0x01000000,
            .pszWindowTitle = if (caption) |text| text.ptr else &empty,
            // TD_WARNING_ICON, TD_ERROR_ICON, TD_INFORMATION_ICON
            .pszMainIcon = switch (style) {
                .warning => 0xFFFF,
                .critical => 0xFFFE,
                .info => 0xFFFD,
            },
            .pszMainInstruction = heading.ptr,
            .pszContent = if (body_text.len > 0) body.ptr else null,
            .cButtons = @intCast(count),
            .pButtons = &native_buttons,
            .nDefaultButton = first_button_id,
        };
        var pressed: c_int = 0;
        if (show(&config, &pressed, null, null) >= 0 and pressed >= first_button_id and
            pressed < first_button_id + @as(c_int, @intCast(buttons.len)))
            chosen = @intCast(pressed - first_button_id);
    } else {
        // Without the version 6 common controls there are only the stock
        // button sets, so custom labels are not drawn. The reply still
        // reports a position in the list the page asked for.
        const icon: UINT = switch (style) {
            .warning => 0x30,
            .critical => 0x10,
            .info => if (confirm) 0x20 else 0x40,
        };
        // MB_OK, MB_OKCANCEL, MB_YESNOCANCEL
        const set: UINT = if (buttons.len <= 1) 0 else if (buttons.len == 2) 1 else 3;
        var text: std.ArrayListUnmanaged(u16) = .empty;
        defer text.deinit(allocator);
        try text.appendSlice(allocator, heading);
        if (body_text.len > 0) {
            try text.appendSlice(allocator, &.{ '\n', '\n' });
            try text.appendSlice(allocator, body);
        }
        try text.append(allocator, 0);
        const message: LPCWSTR = @ptrCast(text.items.ptr);
        chosen = switch (MessageBoxW(hwnd, message, if (caption) |title| title.ptr else &empty, set | icon)) {
            1, 6 => 0, // IDOK, IDYES
            7 => 1, // IDNO
            else => desktop_dialog.dismissedIndex(buttons),
        };
    }
    var buffer: [48]u8 = undefined;
    request.reply(desktop_dialog.messageResult(&buffer, confirm, chosen));
}

// ---------------------------------------------------------------------------
// File drop
// ---------------------------------------------------------------------------

const iid_web_message_args2 = GUID{ .Data1 = 0x06FC7AB7, .Data2 = 0xC90C, .Data3 = 0x4297, .Data4 = .{ 0x93, 0x89, 0x33, 0xCA, 0x01, 0xCF, 0x6D, 0x5E } };
const iid_webview2_file = GUID{ .Data1 = 0xF2C19559, .Data2 = 0x6BC1, .Data3 = 0x4583, .Data4 = .{ 0xA7, 0x57, 0x90, 0x02, 0x1B, 0xE9, 0xAF, 0xEC } };

// ICoreWebView2WebMessageReceivedEventArgs2: three inherited getters, then this.
const slot_args_get_additional_objects = 6;
// ICoreWebView2ObjectCollectionView.
const slot_collection_get_count = 3;
const slot_collection_get_value_at = 4;
// ICoreWebView2File.
const slot_file_get_path = 3;

/// The page posted the files of a `drop` event with
/// `postMessageWithAdditionalObjects`. WebView2 is the only thing that knows
/// their paths; read them off the message and hand them to the page the way
/// macOS does.
pub fn deliverFileDrop(args: *win.ICoreWebView2WebMessageReceivedEventArgs, webview: usize) void {
    var raw: ?*anyopaque = null;
    if (args.lpVtbl.QueryInterface(args, &iid_web_message_args2, &raw) < 0) return;
    const args2: *ComObject = @ptrCast(@alignCast(raw orelse return));
    defer args2.release();
    var collection_raw: ?*anyopaque = null;
    if (args2.method(slot_args_get_additional_objects, fn (*ComObject, *?*anyopaque) callconv(.c) HRESULT)(args2, &collection_raw) < 0) return;
    const collection: *ComObject = @ptrCast(@alignCast(collection_raw orelse return));
    defer collection.release();

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var count: u32 = 0;
    _ = collection.method(slot_collection_get_count, fn (*ComObject, *u32) callconv(.c) HRESULT)(collection, &count);
    var index: u32 = 0;
    while (index < count and index < 4096) : (index += 1) {
        var object_raw: ?*anyopaque = null;
        if (collection.method(slot_collection_get_value_at, fn (*ComObject, u32, *?*anyopaque) callconv(.c) HRESULT)(collection, index, &object_raw) < 0) continue;
        const object: *ComObject = @ptrCast(@alignCast(object_raw orelse continue));
        defer object.release();
        var file_raw: ?*anyopaque = null;
        if (object.method(0, fn (*ComObject, *const GUID, *?*anyopaque) callconv(.c) HRESULT)(object, &iid_webview2_file, &file_raw) < 0) continue;
        const file: *ComObject = @ptrCast(@alignCast(file_raw orelse continue));
        defer file.release();
        var path_wide: ?LPWSTR = null;
        if (file.method(slot_file_get_path, fn (*ComObject, *?LPWSTR) callconv(.c) HRESULT)(file, &path_wide) < 0) continue;
        const text = path_wide orelse continue;
        defer win.CoTaskMemFree(@ptrCast(text));
        if (utf8(text)) |path| paths.append(allocator, path) catch allocator.free(path);
    }
    if (paths.items.len == 0) return;
    const script = desktop_instance.fileDropScript(allocator, paths.items) catch return;
    defer allocator.free(script);
    win.evalInWebview(webview, script);
}
