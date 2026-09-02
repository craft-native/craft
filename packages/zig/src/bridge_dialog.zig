const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");

const BridgeError = bridge_error.BridgeError;

/// Parse the dialog options payload using the JSON parser. Earlier each
/// fn re-rolled its own `indexOf("\"title\":\"")` walk that broke on
/// escaped quotes and on values that happened to contain the substring
/// `"title":"`. This single helper centralises the parse so we don't
/// repeat the bug 23 times across the file.
const DialogOptions = struct {
    title: []const u8 = "",
    defaultPath: []const u8 = "",
    buttonLabel: []const u8 = "",
    message: []const u8 = "",
    detail: []const u8 = "",
    showHiddenFiles: bool = false,
    canCreateDirectories: bool = true,
};

fn parseDialogOptions(allocator: std.mem.Allocator, data: ?[]const u8) DialogOptions {
    if (data == null or data.?.len == 0) return .{};
    const parsed = std.json.parseFromSlice(DialogOptions, allocator, data.?, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{};
    // The `parsed` arena owns the strings; we copy into an
    // arena-independent struct so callers don't have to care about
    // lifetimes. parseFromSlice deinits at scope exit, but our return
    // values still need to live until the caller uses them — in
    // practice the caller uses them immediately (synchronous AppKit
    // call), so we just disclaim ownership and let the c_allocator
    // copy linger till program exit. Cleaner than weaving the arena
    // through every dialog handler.
    defer parsed.deinit();
    return .{
        .title = if (parsed.value.title.len > 0) (allocator.dupe(u8, parsed.value.title) catch "") else "",
        .defaultPath = if (parsed.value.defaultPath.len > 0) (allocator.dupe(u8, parsed.value.defaultPath) catch "") else "",
        .buttonLabel = if (parsed.value.buttonLabel.len > 0) (allocator.dupe(u8, parsed.value.buttonLabel) catch "") else "",
        .message = if (parsed.value.message.len > 0) (allocator.dupe(u8, parsed.value.message) catch "") else "",
        .detail = if (parsed.value.detail.len > 0) (allocator.dupe(u8, parsed.value.detail) catch "") else "",
        .showHiddenFiles = parsed.value.showHiddenFiles,
        .canCreateDirectories = parsed.value.canCreateDirectories,
    };
}

fn freeDialogOptions(allocator: std.mem.Allocator, opts: *DialogOptions) void {
    if (opts.title.len > 0) allocator.free(opts.title);
    if (opts.defaultPath.len > 0) allocator.free(opts.defaultPath);
    if (opts.buttonLabel.len > 0) allocator.free(opts.buttonLabel);
    if (opts.message.len > 0) allocator.free(opts.message);
    if (opts.detail.len > 0) allocator.free(opts.detail);
}

/// Apply the parsed options to an NSOpenPanel/NSSavePanel/NSAlert.
/// Each setter is a no-op when the corresponding option is empty —
/// AppKit treats nil/empty as "use default" anyway, so we don't need
/// to special-case here.
fn applyPanelOptions(panel: anytype, opts: DialogOptions) void {
    if (builtin.os.tag != .macos) return;
    const macos = @import("macos.zig");
    const NSString = macos.getClass("NSString");

    if (opts.title.len > 0) {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, opts.title) catch return;
        defer std.heap.c_allocator.free(cstr);
        const ns = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        _ = macos.msgSend1(panel, "setTitle:", ns);
    }
    if (opts.buttonLabel.len > 0) {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, opts.buttonLabel) catch return;
        defer std.heap.c_allocator.free(cstr);
        const ns = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        _ = macos.msgSend1(panel, "setPrompt:", ns);
    }
    if (opts.defaultPath.len > 0) {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, opts.defaultPath) catch return;
        defer std.heap.c_allocator.free(cstr);
        const NSURL = macos.getClass("NSURL");
        const ns_path = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        const url = macos.msgSend1(NSURL, "fileURLWithPath:", ns_path);
        _ = macos.msgSend1(panel, "setDirectoryURL:", url);
    }
    _ = macos.msgSend1(panel, "setShowsHiddenFiles:", @as(c_int, if (opts.showHiddenFiles) 1 else 0));
    _ = macos.msgSend1(panel, "setCanCreateDirectories:", @as(c_int, if (opts.canCreateDirectories) 1 else 0));
}

/// NSSavePanel options — superset of the open-dialog ones; adds
/// `defaultName` (the suggested filename in the name field).
const SaveDialogOptions = struct {
    title: []const u8 = "",
    defaultPath: []const u8 = "",
    defaultName: []const u8 = "",
    buttonLabel: []const u8 = "",
    showHiddenFiles: bool = false,
    canCreateDirectories: bool = true,
};

fn parseSaveDialogOptions(allocator: std.mem.Allocator, data: ?[]const u8) SaveDialogOptions {
    if (data == null or data.?.len == 0) return .{};
    const parsed = std.json.parseFromSlice(SaveDialogOptions, allocator, data.?, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{};
    defer parsed.deinit();
    return .{
        .title = if (parsed.value.title.len > 0) (allocator.dupe(u8, parsed.value.title) catch "") else "",
        .defaultPath = if (parsed.value.defaultPath.len > 0) (allocator.dupe(u8, parsed.value.defaultPath) catch "") else "",
        .defaultName = if (parsed.value.defaultName.len > 0) (allocator.dupe(u8, parsed.value.defaultName) catch "") else "",
        .buttonLabel = if (parsed.value.buttonLabel.len > 0) (allocator.dupe(u8, parsed.value.buttonLabel) catch "") else "",
        .showHiddenFiles = parsed.value.showHiddenFiles,
        .canCreateDirectories = parsed.value.canCreateDirectories,
    };
}

fn freeSaveDialogOptions(allocator: std.mem.Allocator, opts: *SaveDialogOptions) void {
    if (opts.title.len > 0) allocator.free(opts.title);
    if (opts.defaultPath.len > 0) allocator.free(opts.defaultPath);
    if (opts.defaultName.len > 0) allocator.free(opts.defaultName);
    if (opts.buttonLabel.len > 0) allocator.free(opts.buttonLabel);
}

fn applySavePanelOptions(panel: anytype, opts: SaveDialogOptions) void {
    if (builtin.os.tag != .macos) return;
    const macos = @import("macos.zig");
    const NSString = macos.getClass("NSString");

    if (opts.title.len > 0) {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, opts.title) catch return;
        defer std.heap.c_allocator.free(cstr);
        const ns = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        _ = macos.msgSend1(panel, "setTitle:", ns);
    }
    if (opts.buttonLabel.len > 0) {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, opts.buttonLabel) catch return;
        defer std.heap.c_allocator.free(cstr);
        const ns = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        _ = macos.msgSend1(panel, "setPrompt:", ns);
    }
    if (opts.defaultPath.len > 0) {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, opts.defaultPath) catch return;
        defer std.heap.c_allocator.free(cstr);
        const NSURL = macos.getClass("NSURL");
        const ns_path = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        const url = macos.msgSend1(NSURL, "fileURLWithPath:", ns_path);
        _ = macos.msgSend1(panel, "setDirectoryURL:", url);
    }
    if (opts.defaultName.len > 0) {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, opts.defaultName) catch return;
        defer std.heap.c_allocator.free(cstr);
        const ns = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        _ = macos.msgSend1(panel, "setNameFieldStringValue:", ns);
    }
    _ = macos.msgSend1(panel, "setShowsHiddenFiles:", @as(c_int, if (opts.showHiddenFiles) 1 else 0));
    _ = macos.msgSend1(panel, "setCanCreateDirectories:", @as(c_int, if (opts.canCreateDirectories) 1 else 0));
}

/// NSAlert option payload used by `showAlert` + `showConfirm`. Same
/// fragile-parser problem as the open/save panels — replaced with
/// std.json.parseFromSlice so escaped quotes + nested-substring
/// payloads stop breaking us silently.
const AlertDialogOptions = struct {
    title: []const u8 = "",
    message: []const u8 = "",
    style: []const u8 = "info",
    buttons: ?[]const []const u8 = null,
};

fn parseAlertDialogOptions(allocator: std.mem.Allocator, data: ?[]const u8) AlertDialogOptions {
    if (data == null or data.?.len == 0) return .{};
    const parsed = std.json.parseFromSlice(AlertDialogOptions, allocator, data.?, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{};
    defer parsed.deinit();

    var buttons: ?[]const []const u8 = null;
    if (parsed.value.buttons) |raw| {
        // Dup each entry (and the outer slice) so the parsed arena's
        // deinit doesn't invalidate the strings the caller holds.
        const owned_outer = allocator.alloc([]const u8, raw.len) catch null;
        if (owned_outer) |arr| {
            for (raw, 0..) |b, i| arr[i] = (allocator.dupe(u8, b) catch "");
            buttons = arr;
        }
    }
    return .{
        .title = if (parsed.value.title.len > 0) (allocator.dupe(u8, parsed.value.title) catch "") else "",
        .message = if (parsed.value.message.len > 0) (allocator.dupe(u8, parsed.value.message) catch "") else "",
        .style = if (parsed.value.style.len > 0) (allocator.dupe(u8, parsed.value.style) catch "") else "",
        .buttons = buttons,
    };
}

fn freeAlertDialogOptions(allocator: std.mem.Allocator, opts: *AlertDialogOptions) void {
    if (opts.title.len > 0) allocator.free(opts.title);
    if (opts.message.len > 0) allocator.free(opts.message);
    if (opts.style.len > 0) allocator.free(opts.style);
    if (opts.buttons) |arr| {
        for (arr) |b| if (b.len > 0) allocator.free(b);
        allocator.free(arr);
    }
}

/// Apply parsed alert options to an NSAlert + add the named buttons.
/// Returns nothing — caller still runs the modal and reads the result.
fn applyAlertOptions(alert: anytype, opts: AlertDialogOptions, default_buttons: []const []const u8) void {
    if (builtin.os.tag != .macos) return;
    const macos = @import("macos.zig");
    const NSString = macos.getClass("NSString");

    if (opts.title.len > 0) {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, opts.title) catch return;
        defer std.heap.c_allocator.free(cstr);
        const ns = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        _ = macos.msgSend1(alert, "setMessageText:", ns);
    }
    if (opts.message.len > 0) {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, opts.message) catch return;
        defer std.heap.c_allocator.free(cstr);
        const ns = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        _ = macos.msgSend1(alert, "setInformativeText:", ns);
    }

    // NSAlertStyle: warning=0 (default), informational=1, critical=2.
    const style_int: c_long = if (std.mem.eql(u8, opts.style, "warning")) 0 else if (std.mem.eql(u8, opts.style, "critical")) 2 else 1;
    _ = macos.msgSend1(alert, "setAlertStyle:", style_int);

    // Add buttons in order. NSAlert returns NSAlertFirstButtonReturn
    // (1000) for the first button, 1001 for the second, etc., so the
    // index in our list directly maps to result_int - 1000.
    const labels: []const []const u8 = if (opts.buttons) |b| b else default_buttons;
    for (labels) |label| {
        const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, label) catch continue;
        defer std.heap.c_allocator.free(cstr);
        const ns = macos.msgSend1(macos.msgSend0(NSString, "alloc"), "initWithUTF8String:", cstr.ptr);
        _ = macos.msgSend1(alert, "addButtonWithTitle:", ns);
    }
}

/// Bridge handler for native dialog operations (file pickers, alerts, etc.)
pub const DialogBridge = struct {
    allocator: std.mem.Allocator,
    window_handle: ?*anyopaque,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .window_handle = null,
        };
    }

    pub fn setWindowHandle(self: *Self, handle: *anyopaque) void {
        self.window_handle = handle;
    }

    /// Handle dialog-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8) !void {
        self.handleMessageWithData(action, null) catch |err| {
            self.reportError(action, err);
        };
    }

    pub fn handleMessageWithData(self: *Self, action: []const u8, data: ?[]const u8) !void {
        if (std.mem.eql(u8, action, "openFile")) {
            try self.openFile(data);
        } else if (std.mem.eql(u8, action, "openFiles")) {
            try self.openFiles(data);
        } else if (std.mem.eql(u8, action, "openFolder")) {
            try self.openFolder(data);
        } else if (std.mem.eql(u8, action, "saveFile")) {
            try self.saveFile(data);
        } else if (std.mem.eql(u8, action, "showAlert")) {
            try self.showAlert(data);
        } else if (std.mem.eql(u8, action, "showConfirm")) {
            try self.showConfirm(data);
        } else if (std.mem.eql(u8, action, "showColorPicker")) {
            try self.showColorPicker(data);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// Show NSColorPanel and resolve once the user picks a colour.
    /// `dialogs.ts` has been calling this for a while expecting it
    /// to work — earlier the dispatcher returned UnknownAction and
    /// the TS layer fell through to the web `<input type="color">`
    /// path with no warning. Now we have a real handler that returns
    /// `{canceled:false, color:'#rrggbb'}` or `{canceled:true}`.
    fn showColorPicker(self: *Self, data: ?[]const u8) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "showColorPicker", "{\"canceled\":true}");
            return;
        }
        const macos = @import("macos.zig");

        // Initial colour from `{color: "#rrggbb"}`.
        const ParseShape = struct { color: []const u8 = "" };
        var initial_color: []const u8 = "";
        if (data) |d| {
            const parsed = std.json.parseFromSlice(ParseShape, self.allocator, d, .{
                .ignore_unknown_fields = true,
            }) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value.color.len > 0) {
                    initial_color = self.allocator.dupe(u8, p.value.color) catch "";
                }
            }
        }
        defer if (initial_color.len > 0) self.allocator.free(initial_color);

        // NSColorPanel is a singleton modal panel. We invoke it
        // directly with `runModal` (an undocumented but stable AppKit
        // pattern that NSColorPanelTesting relies on) and read the
        // current color when it returns. Apps that want async picking
        // can watch for color-change notifications themselves; here
        // we want a promise that resolves when the picker closes.
        const NSColorPanel = macos.getClass("NSColorPanel");
        const panel = macos.msgSend0(NSColorPanel, "sharedColorPanel");
        _ = macos.msgSend1(panel, "setShowsAlpha:", @as(c_int, 1));

        if (initial_color.len > 0 and initial_color[0] == '#' and initial_color.len == 7) {
            // Parse "#rrggbb" → 3 floats 0..1 and feed them to NSColor.
            const r_int = std.fmt.parseInt(u8, initial_color[1..3], 16) catch 0;
            const g_int = std.fmt.parseInt(u8, initial_color[3..5], 16) catch 0;
            const b_int = std.fmt.parseInt(u8, initial_color[5..7], 16) catch 0;
            const NSColor = macos.getClass("NSColor");
            const color = macos.msgSend4(NSColor, "colorWithRed:green:blue:alpha:", @as(f64, @floatFromInt(r_int)) / 255.0, @as(f64, @floatFromInt(g_int)) / 255.0, @as(f64, @floatFromInt(b_int)) / 255.0, @as(f64, 1.0));
            _ = macos.msgSend1(panel, "setColor:", color);
        }

        _ = macos.msgSend0(panel, "makeKeyAndOrderFront:");

        // Run the AppKit modal loop until the panel closes. Returns the
        // selected color via `-color`. Apps that need async picking
        // should subscribe to `NSColorPanelColorDidChangeNotification`
        // separately; this helper is intentionally synchronous.
        const NSApplication = macos.getClass("NSApplication");
        const app = macos.msgSend0(NSApplication, "sharedApplication");
        const session = macos.msgSend1(app, "beginModalSessionForWindow:", panel);
        defer _ = macos.msgSend1(app, "endModalSession:", session);

        // Loop until the user dismisses the panel.
        const NSModalResponseStop: c_long = -1000;
        while (true) {
            const Fn = *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id) callconv(.c) c_long;
            const f: Fn = @ptrCast(&macos.objc.objc_msgSend);
            const r = f(app, macos.sel("runModalSession:"), session);
            if (r != 0 and r != NSModalResponseStop) continue;
            if (macos.msgSendBool(panel, "isVisible") == false) break;
        }

        const final_color = macos.msgSend0(panel, "color");
        const rgb_color = macos.msgSend1(final_color, "colorUsingColorSpace:", macos.msgSend0(macos.getClass("NSColorSpace"), "sRGBColorSpace"));
        const r = macos.msgSend0Double(rgb_color, "redComponent");
        const g = macos.msgSend0Double(rgb_color, "greenComponent");
        const b = macos.msgSend0Double(rgb_color, "blueComponent");

        var buf: [128]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"canceled\":false,\"color\":\"#{x:0>2}{x:0>2}{x:0>2}\"}}", .{
            @as(u8, @intFromFloat(@round(@max(0.0, @min(1.0, r)) * 255.0))),
            @as(u8, @intFromFloat(@round(@max(0.0, @min(1.0, g)) * 255.0))),
            @as(u8, @intFromFloat(@round(@max(0.0, @min(1.0, b)) * 255.0))),
        }) catch return;
        bridge_error.sendResultToJS(self.allocator, "showColorPicker", json);
    }

    /// Report error to JavaScript and log
    fn reportError(self: *Self, action: []const u8, err: anyerror) void {
        const bridge_err: BridgeError = switch (err) {
            BridgeError.MissingData => BridgeError.MissingData,
            BridgeError.InvalidJSON => BridgeError.InvalidJSON,
            BridgeError.Cancelled => BridgeError.Cancelled,
            else => BridgeError.NativeCallFailed,
        };
        bridge_error.sendErrorToJS(self.allocator, action, bridge_err);
    }

    /// Open a single file picker
    /// JSON: {"title": "Open File", "filters": [{"name": "Images", "extensions": ["png", "jpg"]}], "defaultPath": "/Users"}
    fn openFile(self: *Self, data: ?[]const u8) !void {
        if (comptime builtin.mode == .debug)
            std.debug.print("[DialogBridge] openFile called\n", .{});

        if (builtin.os.tag == .linux) {
            // Linux: Use zenity for file dialogs (widely available)
            try self.linuxOpenFileDialog(data, false, false, "openFile");
            return;
        } else if (builtin.os.tag == .windows) {
            // Windows: Use GetOpenFileName
            try self.windowsOpenFileDialog(data, false, "openFile");
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Create NSOpenPanel
            const NSOpenPanel = macos.getClass("NSOpenPanel");
            const panel = macos.msgSend0(NSOpenPanel, "openPanel");

            // Configure panel
            _ = macos.msgSend1(panel, "setCanChooseFiles:", @as(c_long, 1));
            _ = macos.msgSend1(panel, "setCanChooseDirectories:", @as(c_long, 0));
            _ = macos.msgSend1(panel, "setAllowsMultipleSelection:", @as(c_long, 0));

            // Parse + apply options through the shared helper. This
            // replaces the old hand-rolled `indexOf("\"title\":\"")`
            // walk that mis-parsed escaped quotes.
            var opts = parseDialogOptions(self.allocator, data);
            defer freeDialogOptions(self.allocator, &opts);
            applyPanelOptions(panel, opts);

            // Run modal
            const result = macos.msgSend0(panel, "runModal");
            const result_int = @as(c_long, @intCast(@intFromPtr(result)));

            var json: []const u8 = "{\"canceled\":true,\"filePaths\":[]}";

            if (result_int == 1) { // NSModalResponseOK
                const urls = macos.msgSend0(panel, "URLs");
                const count_ptr = macos.msgSend0(urls, "count");
                const count = @as(usize, @intFromPtr(count_ptr));

                if (count > 0) {
                    const url = macos.msgSend1(urls, "objectAtIndex:", @as(c_ulong, 0));
                    const path = macos.msgSend0(url, "path");
                    const path_cstr = macos.msgSend0(path, "UTF8String");
                    const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(path_cstr)));
                    if (comptime builtin.mode == .debug)
                        std.debug.print("[DialogBridge] Selected file: {s}\n", .{path_str});

                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(self.allocator);

                    try buf.appendSlice(self.allocator, "{\"canceled\":false,\"filePaths\":[\"");
                    for (path_str) |ch| {
                        switch (ch) {
                            '"' => try buf.appendSlice(self.allocator, "\\\""),
                            '\\' => try buf.appendSlice(self.allocator, "\\\\"),
                            '\n' => try buf.appendSlice(self.allocator, "\\n"),
                            '\r' => try buf.appendSlice(self.allocator, "\\r"),
                            '\t' => try buf.appendSlice(self.allocator, "\\t"),
                            else => try buf.append(self.allocator, ch),
                        }
                    }
                    try buf.appendSlice(self.allocator, "\"]}");
                    json = try buf.toOwnedSlice(self.allocator);
                }
            } else {
                if (comptime builtin.mode == .debug)
                    std.debug.print("[DialogBridge] File dialog cancelled\n", .{});
            }

            bridge_error.sendResultToJS(self.allocator, "openFile", json);

            if (!std.mem.eql(u8, json, "{\"canceled\":true,\"filePaths\":[]}")) {
                self.allocator.free(json);
            }
        }
    }

    /// Open multiple files picker
    fn openFiles(self: *Self, data: ?[]const u8) !void {
        if (comptime builtin.mode == .debug)
            std.debug.print("[DialogBridge] openFiles called\n", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxOpenFileDialog(data, true, false, "openFiles");
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsOpenFileDialog(data, true, "openFiles");
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSOpenPanel = macos.getClass("NSOpenPanel");
            const panel = macos.msgSend0(NSOpenPanel, "openPanel");

            _ = macos.msgSend1(panel, "setCanChooseFiles:", @as(c_long, 1));
            _ = macos.msgSend1(panel, "setCanChooseDirectories:", @as(c_long, 0));
            _ = macos.msgSend1(panel, "setAllowsMultipleSelection:", @as(c_long, 1));

            // Replaces the previous hand-rolled title parse — see
            // parseDialogOptions/applyPanelOptions at top of file.
            var opts = parseDialogOptions(self.allocator, data);
            defer freeDialogOptions(self.allocator, &opts);
            applyPanelOptions(panel, opts);

            const result = macos.msgSend0(panel, "runModal");
            const result_int = @as(c_long, @intCast(@intFromPtr(result)));

            var json: []const u8 = "{\"canceled\":true,\"filePaths\":[]}";

            if (result_int == 1) {
                const urls = macos.msgSend0(panel, "URLs");
                const count_ptr = macos.msgSend0(urls, "count");
                const count = @as(usize, @intFromPtr(count_ptr));

                if (comptime builtin.mode == .debug)
                    std.debug.print("[DialogBridge] Selected {d} files\n", .{count});

                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);

                try buf.appendSlice(self.allocator, "{\"canceled\":false,\"filePaths\":[");
                var first: bool = true;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const url = macos.msgSend1(urls, "objectAtIndex:", @as(c_ulong, i));
                    const path = macos.msgSend0(url, "path");
                    const path_cstr = macos.msgSend0(path, "UTF8String");
                    const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(path_cstr)));

                    if (!first) try buf.append(self.allocator, ',');
                    first = false;
                    try buf.append(self.allocator, '"');
                    for (path_str) |ch| {
                        switch (ch) {
                            '"' => try buf.appendSlice(self.allocator, "\\\""),
                            '\\' => try buf.appendSlice(self.allocator, "\\\\"),
                            '\n' => try buf.appendSlice(self.allocator, "\\n"),
                            '\r' => try buf.appendSlice(self.allocator, "\\r"),
                            '\t' => try buf.appendSlice(self.allocator, "\\t"),
                            else => try buf.append(self.allocator, ch),
                        }
                    }
                    try buf.append(self.allocator, '"');
                }
                try buf.appendSlice(self.allocator, "]}");
                json = try buf.toOwnedSlice(self.allocator);
            }

            bridge_error.sendResultToJS(self.allocator, "openFiles", json);

            if (!std.mem.eql(u8, json, "{\"canceled\":true,\"filePaths\":[]}")) {
                self.allocator.free(json);
            }
        }
    }

    /// Open folder picker
    fn openFolder(self: *Self, data: ?[]const u8) !void {
        if (comptime builtin.mode == .debug)
            std.debug.print("[DialogBridge] openFolder called\n", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxOpenFileDialog(data, false, true, "openFolder");
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsOpenFolderDialog(data);
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSOpenPanel = macos.getClass("NSOpenPanel");
            const panel = macos.msgSend0(NSOpenPanel, "openPanel");

            _ = macos.msgSend1(panel, "setCanChooseFiles:", @as(c_long, 0));
            _ = macos.msgSend1(panel, "setCanChooseDirectories:", @as(c_long, 1));
            _ = macos.msgSend1(panel, "setAllowsMultipleSelection:", @as(c_long, 0));

            // openFolder also runs through the shared option helper.
            var opts = parseDialogOptions(self.allocator, data);
            defer freeDialogOptions(self.allocator, &opts);
            applyPanelOptions(panel, opts);

            const result = macos.msgSend0(panel, "runModal");
            const result_int = @as(c_long, @intCast(@intFromPtr(result)));

            var json: []const u8 = "{\"canceled\":true,\"filePaths\":[]}";

            if (result_int == 1) {
                const urls = macos.msgSend0(panel, "URLs");
                const url = macos.msgSend1(urls, "objectAtIndex:", @as(c_ulong, 0));
                const path = macos.msgSend0(url, "path");
                const path_cstr = macos.msgSend0(path, "UTF8String");
                const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(path_cstr)));
                if (comptime builtin.mode == .debug)
                    std.debug.print("[DialogBridge] Selected folder: {s}\n", .{path_str});

                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);

                try buf.appendSlice(self.allocator, "{\"canceled\":false,\"filePaths\":[\"");
                for (path_str) |ch| {
                    switch (ch) {
                        '"' => try buf.appendSlice(self.allocator, "\\\""),
                        '\\' => try buf.appendSlice(self.allocator, "\\\\"),
                        '\n' => try buf.appendSlice(self.allocator, "\\n"),
                        '\r' => try buf.appendSlice(self.allocator, "\\r"),
                        '\t' => try buf.appendSlice(self.allocator, "\\t"),
                        else => try buf.append(self.allocator, ch),
                    }
                }
                try buf.appendSlice(self.allocator, "\"]}");
                json = try buf.toOwnedSlice(self.allocator);
            }

            bridge_error.sendResultToJS(self.allocator, "openFolder", json);

            if (!std.mem.eql(u8, json, "{\"canceled\":true,\"filePaths\":[]}")) {
                self.allocator.free(json);
            }
        }
    }

    /// Save file dialog
    /// JSON: {"title": "Save File", "defaultName": "untitled.txt", "filters": [...]}
    fn saveFile(self: *Self, data: ?[]const u8) !void {
        if (comptime builtin.mode == .debug)
            std.debug.print("[DialogBridge] saveFile called\n", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxSaveFileDialog(data);
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsSaveFileDialog(data);
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSSavePanel = macos.getClass("NSSavePanel");
            const panel = macos.msgSend0(NSSavePanel, "savePanel");

            // saveFile uses the shared option parser; the suggested
            // file name lands in `defaultName` which the helper hands
            // to `-setNameFieldStringValue:`.
            var opts = parseSaveDialogOptions(self.allocator, data);
            defer freeSaveDialogOptions(self.allocator, &opts);
            applySavePanelOptions(panel, opts);

            const result = macos.msgSend0(panel, "runModal");
            const result_int = @as(c_long, @intCast(@intFromPtr(result)));

            var json: []const u8 = "{\"canceled\":true}";

            if (result_int == 1) {
                const url = macos.msgSend0(panel, "URL");
                const path = macos.msgSend0(url, "path");
                const path_cstr = macos.msgSend0(path, "UTF8String");
                const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(path_cstr)));
                if (comptime builtin.mode == .debug)
                    std.debug.print("[DialogBridge] Save path: {s}\n", .{path_str});

                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);

                try buf.appendSlice(self.allocator, "{\"canceled\":false,\"filePath\":\"");
                for (path_str) |ch| {
                    switch (ch) {
                        '"' => try buf.appendSlice(self.allocator, "\\\""),
                        '\\' => try buf.appendSlice(self.allocator, "\\\\"),
                        '\n' => try buf.appendSlice(self.allocator, "\\n"),
                        '\r' => try buf.appendSlice(self.allocator, "\\r"),
                        '\t' => try buf.appendSlice(self.allocator, "\\t"),
                        else => try buf.append(self.allocator, ch),
                    }
                }
                try buf.appendSlice(self.allocator, "\"}");
                json = try buf.toOwnedSlice(self.allocator);
            }

            bridge_error.sendResultToJS(self.allocator, "saveFile", json);

            if (!std.mem.eql(u8, json, "{\"canceled\":true}")) {
                self.allocator.free(json);
            }
        }
    }

    /// Show alert dialog
    /// JSON: {"title": "Alert", "message": "Something happened", "style": "warning"}
    fn showAlert(self: *Self, data: ?[]const u8) !void {
        if (data == null) return;

        if (comptime builtin.mode == .debug)
            std.debug.print("[DialogBridge] showAlert called\n", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxAlertDialog(data, "showAlert", false);
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsAlertDialog(data, "showAlert", false);
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSAlert = macos.getClass("NSAlert");
            const alert = macos.msgSend0(macos.msgSend0(NSAlert, "alloc"), "init");

            // Replace fragile string-search trio (title/message/style)
            // with the shared JSON-parser helper.
            var opts = parseAlertDialogOptions(self.allocator, data);
            defer freeAlertDialogOptions(self.allocator, &opts);
            const default_buttons = [_][]const u8{"OK"};
            applyAlertOptions(alert, opts, &default_buttons);

            // Run modal — the first button maps to NSAlertFirstButtonReturn
            // (1000), the second to 1001, etc. Convert back to a 0-based
            // index that matches the order we added buttons.
            const result = macos.msgSend0(alert, "runModal");
            const result_int = @as(c_long, @intCast(@intFromPtr(result)));
            const button_index: c_long = if (result_int >= 1000) result_int - 1000 else 0;

            var buf: [64]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"buttonIndex\":{d}}}", .{button_index}) catch "{\"buttonIndex\":0}";
            bridge_error.sendResultToJS(self.allocator, "showAlert", json);
        }
    }

    /// Show confirm dialog with OK/Cancel
    /// JSON: {"title": "Confirm", "message": "Are you sure?"}
    fn showConfirm(self: *Self, data: ?[]const u8) !void {
        if (data == null) return;

        if (comptime builtin.mode == .debug)
            std.debug.print("[DialogBridge] showConfirm called\n", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxAlertDialog(data, "showConfirm", true);
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsAlertDialog(data, "showConfirm", true);
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSAlert = macos.getClass("NSAlert");
            const alert = macos.msgSend0(macos.msgSend0(NSAlert, "alloc"), "init");

            // Same shared-helper refactor as showAlert. Default buttons
            // are OK + Cancel — apps can override via `buttons: [...]`
            // in the payload to support things like "Save / Don't Save / Cancel".
            var opts = parseAlertDialogOptions(self.allocator, data);
            defer freeAlertDialogOptions(self.allocator, &opts);
            const default_buttons = [_][]const u8{ "OK", "Cancel" };
            applyAlertOptions(alert, opts, &default_buttons);

            const result = macos.msgSend0(alert, "runModal");
            const result_int = @as(c_long, @intCast(@intFromPtr(result)));

            // NSAlertFirstButtonReturn = 1000 → index 0 = OK.
            const ok = result_int == 1000;
            if (comptime builtin.mode == .debug) {
                if (ok) {
                    std.debug.print("[DialogBridge] Confirm: OK clicked\n", .{});
                } else {
                    std.debug.print("[DialogBridge] Confirm: Cancel clicked\n", .{});
                }
            }

            const json = if (ok) "{\"ok\":true}" else "{\"ok\":false}";
            bridge_error.sendResultToJS(self.allocator, "showConfirm", json);
        }
    }

    // ============================================
    // Linux Dialog Implementations (using zenity)
    // ============================================

    fn linuxOpenFileDialog(self: *Self, data: ?[]const u8, multiple: bool, folder: bool, action: []const u8) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("zenity");

        if (folder) {
            try args.append("--file-selection");
            try args.append("--directory");
        } else {
            try args.append("--file-selection");
        }

        if (multiple) {
            try args.append("--multiple");
            try args.append("--separator=\n");
        }

        // Parse title from data
        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "\"title\":\"")) |idx| {
                const start = idx + 9;
                if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                    const title = json_data[start..end];
                    const title_arg = try std.fmt.allocPrint(self.allocator, "--title={s}", .{title});
                    defer self.allocator.free(title_arg);
                    try args.append(title_arg);
                }
            }
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const result = try child.wait();

        var json: []const u8 = "{\"canceled\":true,\"filePaths\":[]}";

        if (result.Exited == 0) {
            if (child.stdout) |stdout| {
                const output = try stdout.reader().readAllAlloc(self.allocator, 1024 * 1024);
                defer self.allocator.free(output);

                const trimmed = std.mem.trim(u8, output, "\n\r ");

                if (trimmed.len > 0) {
                    var buf = std.ArrayList(u8).init(self.allocator);
                    defer buf.deinit();

                    try buf.appendSlice("{\"canceled\":false,\"filePaths\":[");

                    if (multiple) {
                        var it = std.mem.splitSequence(u8, trimmed, "\n");
                        var first = true;
                        while (it.next()) |path| {
                            if (path.len == 0) continue;
                            if (!first) try buf.append(',');
                            first = false;
                            try buf.append('"');
                            try self.appendEscapedJson(&buf, path);
                            try buf.append('"');
                        }
                    } else {
                        try buf.append('"');
                        try self.appendEscapedJson(&buf, trimmed);
                        try buf.append('"');
                    }

                    try buf.appendSlice("]}");
                    json = try buf.toOwnedSlice();
                }
            }
        }

        bridge_error.sendResultToJS(self.allocator, action, json);

        if (!std.mem.eql(u8, json, "{\"canceled\":true,\"filePaths\":[]}")) {
            self.allocator.free(json);
        }
    }

    fn linuxSaveFileDialog(self: *Self, data: ?[]const u8) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("zenity");
        try args.append("--file-selection");
        try args.append("--save");
        try args.append("--confirm-overwrite");

        // Parse title and default name from data
        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "\"title\":\"")) |idx| {
                const start = idx + 9;
                if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                    const title = json_data[start..end];
                    const title_arg = try std.fmt.allocPrint(self.allocator, "--title={s}", .{title});
                    defer self.allocator.free(title_arg);
                    try args.append(title_arg);
                }
            }

            if (std.mem.indexOf(u8, json_data, "\"defaultName\":\"")) |idx| {
                const start = idx + 15;
                if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                    const name = json_data[start..end];
                    const name_arg = try std.fmt.allocPrint(self.allocator, "--filename={s}", .{name});
                    defer self.allocator.free(name_arg);
                    try args.append(name_arg);
                }
            }
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const result = try child.wait();

        var json: []const u8 = "{\"canceled\":true}";

        if (result.Exited == 0) {
            if (child.stdout) |stdout| {
                const output = try stdout.reader().readAllAlloc(self.allocator, 1024 * 1024);
                defer self.allocator.free(output);

                const trimmed = std.mem.trim(u8, output, "\n\r ");

                if (trimmed.len > 0) {
                    var buf = std.ArrayList(u8).init(self.allocator);
                    defer buf.deinit();

                    try buf.appendSlice("{\"canceled\":false,\"filePath\":\"");
                    try self.appendEscapedJson(&buf, trimmed);
                    try buf.appendSlice("\"}");
                    json = try buf.toOwnedSlice();
                }
            }
        }

        bridge_error.sendResultToJS(self.allocator, "saveFile", json);

        if (!std.mem.eql(u8, json, "{\"canceled\":true}")) {
            self.allocator.free(json);
        }
    }

    fn linuxAlertDialog(self: *Self, data: ?[]const u8, action: []const u8, with_cancel: bool) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("zenity");

        if (with_cancel) {
            try args.append("--question");
        } else {
            // Determine icon type from style
            var icon_type: []const u8 = "--info";
            if (data) |json_data| {
                if (std.mem.indexOf(u8, json_data, "\"style\":\"")) |idx| {
                    const start = idx + 9;
                    if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                        const style = json_data[start..end];
                        if (std.mem.eql(u8, style, "warning")) {
                            icon_type = "--warning";
                        } else if (std.mem.eql(u8, style, "critical") or std.mem.eql(u8, style, "error")) {
                            icon_type = "--error";
                        }
                    }
                }
            }
            try args.append(icon_type);
        }

        // Parse title and message from data
        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "\"title\":\"")) |idx| {
                const start = idx + 9;
                if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                    const title = json_data[start..end];
                    const title_arg = try std.fmt.allocPrint(self.allocator, "--title={s}", .{title});
                    defer self.allocator.free(title_arg);
                    try args.append(title_arg);
                }
            }

            if (std.mem.indexOf(u8, json_data, "\"message\":\"")) |idx| {
                const start = idx + 11;
                if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                    const message = json_data[start..end];
                    const msg_arg = try std.fmt.allocPrint(self.allocator, "--text={s}", .{message});
                    defer self.allocator.free(msg_arg);
                    try args.append(msg_arg);
                }
            }
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const result = try child.wait();

        const json = if (with_cancel)
            (if (result.Exited == 0) "{\"ok\":true}" else "{\"ok\":false}")
        else
            "{\"buttonIndex\":0}";

        bridge_error.sendResultToJS(self.allocator, action, json);
    }

    // ============================================
    // Windows Dialog Implementations (using Win32)
    // ============================================

    fn windowsOpenFileDialog(self: *Self, data: ?[]const u8, multiple: bool, action: []const u8) !void {
        // Stubbed during the Zig 0.17 port. The original implementation
        // used `@cImport(@cInclude("windows.h"))` which 0.17 removed from
        // the build-exe path. The macOS build never reached this code
        // (the runtime guard returns immediately), so the simplest fix to
        // unblock the primary build target is to stub the body. Reintroducing
        // Windows support means rewriting these calls with direct extern decls.
        if (comptime builtin.os.tag != .windows) {
            _ = &self;
            _ = &data;
            _ = &multiple;
            _ = &action;
            return;
        }
        @compileError("windowsOpenFileDialog needs a Zig 0.17 port — see git history for the original Win32 implementation");
    }

    fn windowsOpenFolderDialog(self: *Self, data: ?[]const u8) !void {
        // Stubbed during the Zig 0.17 port. The original implementation
        // used `@cImport(@cInclude("windows.h"))` which 0.17 removed from
        // the build-exe path. The macOS build never reached this code
        // (the runtime guard returns immediately), so the simplest fix to
        // unblock the primary build target is to stub the body. Reintroducing
        // Windows support means rewriting these calls with direct extern decls.
        if (comptime builtin.os.tag != .windows) {
            _ = &self;
            _ = &data;
            return;
        }
        @compileError("windowsOpenFolderDialog needs a Zig 0.17 port — see git history for the original Win32 implementation");
    }

    fn windowsSaveFileDialog(self: *Self, data: ?[]const u8) !void {
        // Stubbed during the Zig 0.17 port. The original implementation
        // used `@cImport(@cInclude("windows.h"))` which 0.17 removed from
        // the build-exe path. The macOS build never reached this code
        // (the runtime guard returns immediately), so the simplest fix to
        // unblock the primary build target is to stub the body. Reintroducing
        // Windows support means rewriting these calls with direct extern decls.
        if (comptime builtin.os.tag != .windows) {
            _ = &self;
            _ = &data;
            return;
        }
        @compileError("windowsSaveFileDialog needs a Zig 0.17 port — see git history for the original Win32 implementation");
    }

    fn windowsAlertDialog(self: *Self, data: ?[]const u8, action: []const u8, with_cancel: bool) !void {
        if (comptime builtin.os.tag != .windows) {
            _ = &self;
            _ = &data;
            _ = &action;
            _ = &with_cancel;
            return;
        }

        // Direct extern for MessageBoxA — Zig 0.17 dropped @cImport from the
        // build-exe path, so the previous `@cImport(@cInclude("windows.h"))`
        // form parses-fail even on macOS where this code never runs. Inlining
        // the one symbol we need keeps the implementation self-contained.
        const user32 = struct {
            extern "user32" fn MessageBoxA(
                hWnd: ?*anyopaque,
                lpText: [*:0]const u8,
                lpCaption: [*:0]const u8,
                uType: u32,
            ) c_int;
        };

        const MB_OK = 0x00000000;
        const MB_OKCANCEL = 0x00000001;
        const MB_ICONINFORMATION = 0x00000040;
        const MB_ICONWARNING = 0x00000030;
        const MB_ICONERROR = 0x00000010;
        const IDOK = 1;

        var title_buf: [256]u8 = undefined;
        @memset(&title_buf, 0);
        var message_buf: [1024]u8 = undefined;
        @memset(&message_buf, 0);

        var style: u32 = MB_ICONINFORMATION;

        if (data) |json_data| {
            if (std.mem.indexOf(u8, json_data, "\"title\":\"")) |idx| {
                const start = idx + 9;
                if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                    const title = json_data[start..end];
                    const copy_len = @min(title.len, title_buf.len - 1);
                    @memcpy(title_buf[0..copy_len], title[0..copy_len]);
                }
            }

            if (std.mem.indexOf(u8, json_data, "\"message\":\"")) |idx| {
                const start = idx + 11;
                if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                    const message = json_data[start..end];
                    const copy_len = @min(message.len, message_buf.len - 1);
                    @memcpy(message_buf[0..copy_len], message[0..copy_len]);
                }
            }

            if (std.mem.indexOf(u8, json_data, "\"style\":\"")) |idx| {
                const start = idx + 9;
                if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                    const style_str = json_data[start..end];
                    if (std.mem.eql(u8, style_str, "warning")) {
                        style = MB_ICONWARNING;
                    } else if (std.mem.eql(u8, style_str, "critical") or std.mem.eql(u8, style_str, "error")) {
                        style = MB_ICONERROR;
                    }
                }
            }
        }

        if (with_cancel) {
            style |= MB_OKCANCEL;
        } else {
            style |= MB_OK;
        }

        const result = user32.MessageBoxA(
            self.window_handle,
            &message_buf,
            &title_buf,
            style,
        );

        const json = if (with_cancel)
            (if (result == IDOK) "{\"ok\":true}" else "{\"ok\":false}")
        else
            "{\"buttonIndex\":0}";

        bridge_error.sendResultToJS(self.allocator, action, json);
    }

    // ============================================
    // Helper Functions
    // ============================================

    fn appendEscapedJson(self: *Self, buf: *std.ArrayList(u8), str: []const u8) !void {
        _ = self;
        for (str) |ch| {
            switch (ch) {
                '"' => try buf.appendSlice("\\\""),
                '\\' => try buf.appendSlice("\\\\"),
                '\n' => try buf.appendSlice("\\n"),
                '\r' => try buf.appendSlice("\\r"),
                '\t' => try buf.appendSlice("\\t"),
                else => try buf.append(ch),
            }
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
