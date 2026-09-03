const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const logging = @import("logging.zig");

const BridgeError = bridge_error.BridgeError;
const log = logging.clipboard;

// Import GTK clipboard API from linux.zig (works on both X11 and Wayland)
const linux = if (builtin.os.tag == .linux) @import("linux.zig") else undefined;
const capabilities = @import("capabilities.zig");

/// The action names this bridge dispatches on.
///
/// Declared once, here, and referenced by both the dispatch chain below and the
/// capability table beside it — so the two cannot disagree. That is enforced:
/// `test/capabilities_test.zig` fails if a declared bridge compares `action`
/// against a bare string literal anywhere, which makes it impossible to add an
/// action without also declaring it.
pub const A = struct {
    pub const write_text = "writeText";
    pub const read_text = "readText";
    pub const write_h_t_m_l = "writeHTML";
    pub const read_h_t_m_l = "readHTML";
    pub const clear = "clear";
    pub const has_text = "hasText";
    pub const has_h_t_m_l = "hasHTML";
    pub const has_image = "hasImage";
};

/// What craft serves on the `clipboard` namespace.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.write_text, .reply = .none },
    .{ .name = A.read_text, .reply = .result },
    .{ .name = A.write_h_t_m_l, .reply = .none },
    .{ .name = A.read_h_t_m_l, .reply = .result },
    .{ .name = A.clear, .reply = .none },
    .{ .name = A.has_text, .reply = .result },
    .{ .name = A.has_h_t_m_l, .reply = .result },
    .{ .name = A.has_image, .reply = .result },
};

// Win32 symbols used by the Windows clipboard implementation. Declared at
// file scope as `extern` so the file parses on every platform — Zig 0.17
// removed `@cImport` from the build-exe path. The functions themselves
// only resolve at link time on Windows; non-Windows builds never reach
// them at runtime (the windowsXxx fns short-circuit via `builtin.os.tag`).
const HANDLE = ?*anyopaque;
const win32 = struct {
    extern "kernel32" fn GlobalAlloc(uFlags: c_uint, dwBytes: usize) HANDLE;
    extern "kernel32" fn GlobalLock(hMem: HANDLE) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(hMem: HANDLE) c_int;
    extern "user32" fn OpenClipboard(hWndNewOwner: HANDLE) c_int;
    extern "user32" fn CloseClipboard() c_int;
    extern "user32" fn EmptyClipboard() c_int;
    extern "user32" fn SetClipboardData(uFormat: c_uint, hMem: HANDLE) HANDLE;
    extern "user32" fn GetClipboardData(uFormat: c_uint) HANDLE;
    extern "user32" fn IsClipboardFormatAvailable(format: c_uint) c_int;
    extern "user32" fn RegisterClipboardFormatA(lpszFormat: [*:0]const u8) c_uint;
};

/// Bridge handler for clipboard operations
pub const ClipboardBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Handle clipboard-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8) !void {
        self.handleMessageWithData(action, null) catch |err| {
            self.reportError(action, err);
        };
    }

    pub fn handleMessageWithData(self: *Self, action: []const u8, data: ?[]const u8) !void {
        if (std.mem.eql(u8, action, A.write_text)) {
            try self.writeText(data);
        } else if (std.mem.eql(u8, action, A.read_text)) {
            try self.readText();
        } else if (std.mem.eql(u8, action, A.write_h_t_m_l)) {
            try self.writeHTML(data);
        } else if (std.mem.eql(u8, action, A.read_h_t_m_l)) {
            try self.readHTML();
        } else if (std.mem.eql(u8, action, A.clear)) {
            try self.clear();
        } else if (std.mem.eql(u8, action, A.has_text)) {
            try self.hasText();
        } else if (std.mem.eql(u8, action, A.has_h_t_m_l)) {
            try self.hasHTML();
        } else if (std.mem.eql(u8, action, A.has_image)) {
            try self.hasImage();
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// Report error to JavaScript and log
    fn reportError(self: *Self, action: []const u8, err: anyerror) void {
        const bridge_err: BridgeError = switch (err) {
            BridgeError.MissingData => BridgeError.MissingData,
            BridgeError.InvalidJSON => BridgeError.InvalidJSON,
            else => BridgeError.NativeCallFailed,
        };
        bridge_error.sendErrorToJS(self.allocator, action, bridge_err);
    }

    /// Write text to clipboard
    /// JSON: {"text": "Hello World"}
    fn writeText(self: *Self, data: ?[]const u8) !void {
        if (data == null) return;

        log.debug("writeText called", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxWriteText(data);
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsWriteText(data);
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // Replaced fragile indexOf("\"text\":\"") parse — that broke
            // on payloads where the text contained `\"` or even just
            // the substring `"text":"`. JSON parser handles all of that.
            const ParseShape = struct { text: []const u8 = "" };
            const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data.?, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return;
            defer parsed.deinit();
            const text = parsed.value.text;
            if (text.len == 0) return;

            const NSPasteboard = macos.getClass("NSPasteboard");
            const pasteboard = macos.msgSend0(NSPasteboard, "generalPasteboard");
            _ = macos.msgSend0(pasteboard, "clearContents");

            const text_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, text);
            defer std.heap.c_allocator.free(text_cstr);

            const NSString = macos.getClass("NSString");
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_text = macos.msgSend1(str_alloc, "initWithUTF8String:", text_cstr.ptr);

            const NSArray = macos.getClass("NSArray");
            const array = macos.msgSend1(NSArray, "arrayWithObject:", ns_text);

            _ = macos.msgSend1(pasteboard, "writeObjects:", array);

            log.debug("Wrote text to clipboard: {s}", .{text});
        }
    }

    /// Read text from clipboard and send result back to JavaScript
    fn readText(self: *Self) !void {
        log.debug("readText called", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxReadText();
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsReadText();
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSPasteboard = macos.getClass("NSPasteboard");
            const pasteboard = macos.msgSend0(NSPasteboard, "generalPasteboard");

            // Get string from pasteboard
            const NSString = macos.getClass("NSString");

            // NSPasteboardTypeString
            const type_str = "public.utf8-plain-text";
            const type_cstr = @as([*:0]const u8, @ptrCast(type_str.ptr));
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_type = macos.msgSend1(str_alloc, "initWithUTF8String:", type_cstr);

            const text = macos.msgSend1(pasteboard, "stringForType:", ns_type);

            var result_json: []const u8 = "{\"text\":\"\"}";

            if (text != null) {
                const text_cstr = macos.msgSend0(text, "UTF8String");
                if (text_cstr != null) {
                    const text_str = std.mem.span(@as([*:0]const u8, @ptrCast(text_cstr)));
                    log.debug("Read text from clipboard: {s}", .{text_str});

                    // Escape backslashes and quotes for safe JSON embedding
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(self.allocator);

                    try buf.appendSlice(self.allocator, "{\"text\":\"");
                    for (text_str) |ch| {
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
                    result_json = try buf.toOwnedSlice(self.allocator);
                }
            } else {
                log.debug("No text in clipboard", .{});
            }

            // Send result back to JS (action name matches clipboard action)
            bridge_error.sendResultToJS(self.allocator, "readText", result_json);

            // If we allocated a custom JSON buffer, free it
            if (!std.mem.eql(u8, result_json, "{\"text\":\"\"}")) {
                self.allocator.free(result_json);
            }
        }
    }

    /// Write HTML to clipboard
    /// JSON: {"html": "<h1>Hello</h1>"}
    fn writeHTML(self: *Self, data: ?[]const u8) !void {
        if (data == null) return;

        log.debug("writeHTML called", .{});

        if (builtin.os.tag == .linux) {
            // Linux: Use xclip with HTML target
            try self.linuxWriteHTML(data);
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsWriteHTML(data);
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");
            // Same JSON-parser refactor as writeText — handles escaped
            // quotes and HTML containing `"html":"` substring.
            const ParseShape = struct { html: []const u8 = "" };
            const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data.?, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return;
            defer parsed.deinit();
            const html = parsed.value.html;
            if (html.len == 0) return;

            const NSPasteboard = macos.getClass("NSPasteboard");
            const pasteboard = macos.msgSend0(NSPasteboard, "generalPasteboard");

            _ = macos.msgSend0(pasteboard, "clearContents");

            const html_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, html);
            defer std.heap.c_allocator.free(html_cstr);

            const NSString = macos.getClass("NSString");
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_html = macos.msgSend1(str_alloc, "initWithUTF8String:", html_cstr.ptr);

            const type_str = "public.html";
            const type_cstr = @as([*:0]const u8, @ptrCast(type_str.ptr));
            const type_alloc = macos.msgSend0(NSString, "alloc");
            const ns_type = macos.msgSend1(type_alloc, "initWithUTF8String:", type_cstr);

            _ = macos.msgSend2(pasteboard, "setString:forType:", ns_html, ns_type);

            log.debug("Wrote HTML to clipboard", .{});
        }
    }

    /// Read HTML from clipboard
    fn readHTML(self: *Self) !void {
        log.debug("readHTML called", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxReadHTML();
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsReadHTML();
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSPasteboard = macos.getClass("NSPasteboard");
            const pasteboard = macos.msgSend0(NSPasteboard, "generalPasteboard");

            const NSString = macos.getClass("NSString");
            const type_str = "public.html";
            const type_cstr = @as([*:0]const u8, @ptrCast(type_str.ptr));
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_type = macos.msgSend1(str_alloc, "initWithUTF8String:", type_cstr);

            const html = macos.msgSend1(pasteboard, "stringForType:", ns_type);

            var result_json: []const u8 = "{\"html\":\"\"}";

            if (html != null) {
                const html_cstr = macos.msgSend0(html, "UTF8String");
                if (html_cstr != null) {
                    const html_str = std.mem.span(@as([*:0]const u8, @ptrCast(html_cstr)));
                    log.debug("Read HTML from clipboard: {s}", .{html_str});

                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(self.allocator);

                    try buf.appendSlice(self.allocator, "{\"html\":\"");
                    for (html_str) |ch| {
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
                    result_json = try buf.toOwnedSlice(self.allocator);
                }
            } else {
                log.debug("No HTML in clipboard", .{});
            }

            bridge_error.sendResultToJS(self.allocator, "readHTML", result_json);

            if (!std.mem.eql(u8, result_json, "{\"html\":\"\"}")) {
                self.allocator.free(result_json);
            }
        }
    }

    /// Clear clipboard
    fn clear(self: *Self) !void {
        log.debug("clear called", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxClear();
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsClear();
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSPasteboard = macos.getClass("NSPasteboard");
            const pasteboard = macos.msgSend0(NSPasteboard, "generalPasteboard");
            _ = macos.msgSend0(pasteboard, "clearContents");

            log.debug("Clipboard cleared", .{});
        }
    }

    /// Check if clipboard has text
    fn hasText(self: *Self) !void {
        log.debug("hasText called", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxHasText();
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsHasText();
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSPasteboard = macos.getClass("NSPasteboard");
            const pasteboard = macos.msgSend0(NSPasteboard, "generalPasteboard");

            const NSString = macos.getClass("NSString");
            const type_str = "public.utf8-plain-text";
            const type_cstr = @as([*:0]const u8, @ptrCast(type_str.ptr));
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_type = macos.msgSend1(str_alloc, "initWithUTF8String:", type_cstr);

            const NSArray = macos.getClass("NSArray");
            const types = macos.msgSend1(NSArray, "arrayWithObject:", ns_type);

            const available = macos.msgSend1(pasteboard, "availableTypeFromArray:", types);
            const has_text = available != null;

            log.debug("hasText: {}", .{has_text});

            const json = if (has_text) "{\"value\":true}" else "{\"value\":false}";
            bridge_error.sendResultToJS(self.allocator, "hasText", json);
        }
    }

    /// Check if clipboard has HTML
    fn hasHTML(self: *Self) !void {
        log.debug("hasHTML called", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxHasHTML();
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsHasHTML();
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSPasteboard = macos.getClass("NSPasteboard");
            const pasteboard = macos.msgSend0(NSPasteboard, "generalPasteboard");

            const NSString = macos.getClass("NSString");
            const type_str = "public.html";
            const type_cstr = @as([*:0]const u8, @ptrCast(type_str.ptr));
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_type = macos.msgSend1(str_alloc, "initWithUTF8String:", type_cstr);

            const NSArray = macos.getClass("NSArray");
            const types = macos.msgSend1(NSArray, "arrayWithObject:", ns_type);

            const available = macos.msgSend1(pasteboard, "availableTypeFromArray:", types);
            const has_html = available != null;

            log.debug("hasHTML: {}", .{has_html});

            const json = if (has_html) "{\"value\":true}" else "{\"value\":false}";
            bridge_error.sendResultToJS(self.allocator, "hasHTML", json);
        }
    }

    /// Check if clipboard has image
    fn hasImage(self: *Self) !void {
        log.debug("hasImage called", .{});

        if (builtin.os.tag == .linux) {
            try self.linuxHasImage();
            return;
        } else if (builtin.os.tag == .windows) {
            try self.windowsHasImage();
            return;
        } else if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSPasteboard = macos.getClass("NSPasteboard");
            const pasteboard = macos.msgSend0(NSPasteboard, "generalPasteboard");

            const NSString = macos.getClass("NSString");
            const type_str = "public.png";
            const type_cstr = @as([*:0]const u8, @ptrCast(type_str.ptr));
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_type = macos.msgSend1(str_alloc, "initWithUTF8String:", type_cstr);

            const NSArray = macos.getClass("NSArray");
            const types = macos.msgSend1(NSArray, "arrayWithObject:", ns_type);

            const available = macos.msgSend1(pasteboard, "availableTypeFromArray:", types);
            const has_image = available != null;

            log.debug("hasImage: {}", .{has_image});

            const json = if (has_image) "{\"value\":true}" else "{\"value\":false}";
            bridge_error.sendResultToJS(self.allocator, "hasImage", json);
        }
    }

    // ============================================
    // Linux Clipboard Implementations
    // Uses GDK native clipboard (X11 + Wayland) with xclip/xsel fallback
    // ============================================

    fn linuxWriteText(self: *Self, data: ?[]const u8) !void {
        if (data == null) return;
        const json_data = data.?;

        // Parse text from JSON
        if (std.mem.indexOf(u8, json_data, "\"text\":\"")) |idx| {
            const start = idx + 8;
            if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                const text = json_data[start..end];

                // Try GDK clipboard first (works on both X11 and Wayland)
                if (self.linuxGdkWriteText(text)) {
                    log.debug("Linux: Wrote text to clipboard via GDK", .{});
                    return;
                }

                // Fall back to xclip subprocess
                log.debug("Linux: GDK clipboard unavailable, falling back to xclip", .{});
                var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard" }, self.allocator);
                child.stdin_behavior = .Pipe;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;

                try child.spawn();
                // Ensure stdin is closed even on error to avoid fd leak
                defer {
                    if (child.stdin) |*stdin| stdin.close();
                }
                if (child.stdin) |stdin| {
                    stdin.writeAll(text) catch |err| {
                        std.log.warn("clipboard: write to xclip failed: {}", .{err});
                    };
                    // Close stdin to signal EOF to the child
                    child.stdin.?.close();
                    child.stdin = null; // Prevent double close in defer
                }
                _ = child.wait() catch |err| {
                    std.log.warn("clipboard: waiting for xclip failed: {}", .{err});
                };

                log.debug("Linux: Wrote text to clipboard via xclip", .{});
            }
        }
    }

    /// Try to write text using GDK native clipboard API.
    /// Returns true on success, false if GDK is unavailable.
    fn linuxGdkWriteText(_: *Self, text: []const u8) bool {
        if (builtin.os.tag != .linux) return false;

        const display = linux.gdk_display_get_default() orelse return false;
        const clipboard = linux.gdk_display_get_clipboard(display) orelse return false;

        const text_z = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, text) catch return false;
        defer std.heap.c_allocator.free(text_z);

        linux.gdk_clipboard_set_text(clipboard, text_z);
        return true;
    }

    fn linuxReadText(self: *Self) !void {
        var result_json: []const u8 = "{\"text\":\"\"}";

        // Try GDK clipboard first (works on both X11 and Wayland)
        if (self.linuxGdkReadText()) |gdk_text| {
            defer linux.g_free(@ptrCast(@constCast(gdk_text.ptr)));
            const text_str = std.mem.span(gdk_text);

            if (text_str.len > 0) {
                log.debug("Linux: Read text from clipboard via GDK", .{});
                var buf = std.ArrayList(u8).init(self.allocator);
                defer buf.deinit();

                try buf.appendSlice("{\"text\":\"");
                try self.appendEscapedJson(&buf, text_str);
                try buf.appendSlice("\"}");
                result_json = try buf.toOwnedSlice();
            }
        } else {
            // Fall back to xclip subprocess
            log.debug("Linux: GDK clipboard unavailable, falling back to xclip", .{});
            var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard", "-o" }, self.allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;

            try child.spawn();
            // Ensure stdout is closed even on error to avoid fd leak
            defer {
                if (child.stdout) |*stdout| stdout.close();
            }
            const result = child.wait() catch |err| {
                std.log.warn("clipboard: waiting for xclip readText failed: {}", .{err});
                bridge_error.sendResultToJS(self.allocator, "readText", result_json);
                return;
            };

            if (result.Exited == 0) {
                if (child.stdout) |stdout| {
                    const output = stdout.reader().readAllAlloc(self.allocator, 1024 * 1024) catch |err| {
                        std.log.warn("clipboard: reading xclip stdout failed: {}", .{err});
                        bridge_error.sendResultToJS(self.allocator, "readText", result_json);
                        return;
                    };
                    defer self.allocator.free(output);

                    if (output.len > 0) {
                        log.debug("Linux: Read text from clipboard via xclip", .{});
                        var buf = std.ArrayList(u8).init(self.allocator);
                        defer buf.deinit();

                        try buf.appendSlice("{\"text\":\"");
                        try self.appendEscapedJson(&buf, output);
                        try buf.appendSlice("\"}");
                        result_json = try buf.toOwnedSlice();
                    }
                }
            }
        }

        bridge_error.sendResultToJS(self.allocator, "readText", result_json);

        if (!std.mem.eql(u8, result_json, "{\"text\":\"\"}")) {
            self.allocator.free(result_json);
        }
    }

    /// Try to read text using GDK native clipboard API.
    /// GDK's clipboard read is async-only (gdk_clipboard_read_text_async),
    /// so this always returns null to fall through to the xclip/xsel subprocess path.
    /// The write and clear paths use GDK directly since gdk_clipboard_set_text is synchronous.
    fn linuxGdkReadText(_: *Self) ?[*:0]const u8 {
        // GDK read is async-only; fall through to subprocess tools
        return null;
    }

    fn linuxWriteHTML(self: *Self, data: ?[]const u8) !void {
        if (data == null) return;
        const json_data = data.?;

        if (std.mem.indexOf(u8, json_data, "\"html\":\"")) |idx| {
            const start = idx + 8;
            if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                const html = json_data[start..end];

                // GDK clipboard only supports plain text natively;
                // for HTML content type, use xclip with HTML target
                var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard", "-t", "text/html" }, self.allocator);
                child.stdin_behavior = .Pipe;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;

                try child.spawn();
                // Ensure stdin is closed even on error to avoid fd leak
                defer {
                    if (child.stdin) |*stdin| stdin.close();
                }
                if (child.stdin) |stdin| {
                    stdin.writeAll(html) catch |err| {
                        std.log.warn("clipboard: write to xclip (HTML) failed: {}", .{err});
                    };
                    // Close stdin to signal EOF to the child
                    child.stdin.?.close();
                    child.stdin = null; // Prevent double close in defer
                }
                _ = child.wait() catch |err| {
                    std.log.warn("clipboard: waiting for xclip (HTML) failed: {}", .{err});
                };

                log.debug("Linux: Wrote HTML to clipboard via xclip", .{});
            }
        }
    }

    fn linuxReadHTML(self: *Self) !void {
        var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard", "-t", "text/html", "-o" }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        // Ensure stdout is closed even on error to avoid fd leak
        defer {
            if (child.stdout) |*stdout| stdout.close();
        }

        var result_json: []const u8 = "{\"html\":\"\"}";

        const result = child.wait() catch |err| {
            std.log.warn("clipboard: waiting for xclip readHTML failed: {}", .{err});
            bridge_error.sendResultToJS(self.allocator, "readHTML", result_json);
            return;
        };

        if (result.Exited == 0) {
            if (child.stdout) |stdout| {
                const output = stdout.reader().readAllAlloc(self.allocator, 1024 * 1024) catch |err| {
                    std.log.warn("clipboard: reading xclip HTML stdout failed: {}", .{err});
                    bridge_error.sendResultToJS(self.allocator, "readHTML", result_json);
                    return;
                };
                defer self.allocator.free(output);

                if (output.len > 0) {
                    var buf = std.ArrayList(u8).init(self.allocator);
                    defer buf.deinit();

                    try buf.appendSlice("{\"html\":\"");
                    try self.appendEscapedJson(&buf, output);
                    try buf.appendSlice("\"}");
                    result_json = try buf.toOwnedSlice();
                }
            }
        }

        bridge_error.sendResultToJS(self.allocator, "readHTML", result_json);

        if (!std.mem.eql(u8, result_json, "{\"html\":\"\"}")) {
            self.allocator.free(result_json);
        }
    }

    fn linuxClear(self: *Self) !void {
        // Try GDK clipboard first (set empty text to clear)
        if (builtin.os.tag == .linux) {
            if (linux.gdk_display_get_default()) |display| {
                if (linux.gdk_display_get_clipboard(display)) |clipboard| {
                    linux.gdk_clipboard_set_text(clipboard, "");
                    log.debug("Linux: Clipboard cleared via GDK", .{});
                    return;
                }
            }
        }

        // Fall back to xclip: clear by writing empty string
        log.debug("Linux: GDK unavailable, clearing clipboard via xclip", .{});
        var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard" }, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        // Ensure stdin is closed even on error to avoid fd leak
        defer {
            if (child.stdin) |*stdin| stdin.close();
        }
        if (child.stdin) |_| {
            // Close stdin to signal EOF to the child (empty input = clear)
            child.stdin.?.close();
            child.stdin = null; // Prevent double close in defer
        }
        _ = child.wait() catch |err| {
            std.log.warn("clipboard: waiting for xclip clear failed: {}", .{err});
        };

        log.debug("Linux: Clipboard cleared via xclip", .{});
    }

    fn linuxHasText(self: *Self) !void {
        var has_text = false;

        // Try reading via xclip (GDK async read is not suitable for sync check)
        var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard", "-o" }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch {
            // xclip not available, try xsel
            var child2 = std.process.Child.init(&.{ "xsel", "--clipboard", "--output" }, self.allocator);
            child2.stdout_behavior = .Pipe;
            child2.stderr_behavior = .Ignore;

            child2.spawn() catch {
                const json = "{\"value\":false}";
                bridge_error.sendResultToJS(self.allocator, "hasText", json);
                return;
            };
            // Ensure stdout is closed even on error to avoid fd leak
            defer {
                if (child2.stdout) |*stdout2| stdout2.close();
            }
            const result2 = child2.wait() catch |err| {
                std.log.warn("clipboard: waiting for xsel hasText failed: {}", .{err});
                bridge_error.sendResultToJS(self.allocator, "hasText", "{\"value\":false}");
                return;
            };
            if (result2.Exited == 0) {
                if (child2.stdout) |stdout2| {
                    const output2 = stdout2.reader().readAllAlloc(self.allocator, 1024) catch |err| {
                        std.log.warn("clipboard: reading xsel stdout failed: {}", .{err});
                        bridge_error.sendResultToJS(self.allocator, "hasText", "{\"value\":false}");
                        return;
                    };
                    defer self.allocator.free(output2);
                    has_text = output2.len > 0;
                }
            }
            const json = if (has_text) "{\"value\":true}" else "{\"value\":false}";
            bridge_error.sendResultToJS(self.allocator, "hasText", json);
            return;
        };

        // Ensure stdout is closed even on error to avoid fd leak
        defer {
            if (child.stdout) |*stdout| stdout.close();
        }
        const result = child.wait() catch |err| {
            std.log.warn("clipboard: waiting for xclip hasText failed: {}", .{err});
            bridge_error.sendResultToJS(self.allocator, "hasText", "{\"value\":false}");
            return;
        };
        if (result.Exited == 0) {
            if (child.stdout) |stdout| {
                const output = stdout.reader().readAllAlloc(self.allocator, 1024) catch |err| {
                    std.log.warn("clipboard: reading xclip stdout failed: {}", .{err});
                    bridge_error.sendResultToJS(self.allocator, "hasText", "{\"value\":false}");
                    return;
                };
                defer self.allocator.free(output);
                has_text = output.len > 0;
            }
        }

        const json = if (has_text) "{\"value\":true}" else "{\"value\":false}";
        bridge_error.sendResultToJS(self.allocator, "hasText", json);
    }

    fn linuxHasHTML(self: *Self) !void {
        var has_html = false;

        var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard", "-t", "text/html", "-o" }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch {
            const json = "{\"value\":false}";
            bridge_error.sendResultToJS(self.allocator, "hasHTML", json);
            return;
        };
        // Ensure stdout is closed even on error to avoid fd leak
        defer {
            if (child.stdout) |*stdout| stdout.close();
        }
        const result = child.wait() catch |err| {
            std.log.warn("clipboard: waiting for xclip hasHTML failed: {}", .{err});
            bridge_error.sendResultToJS(self.allocator, "hasHTML", "{\"value\":false}");
            return;
        };

        if (result.Exited == 0) {
            if (child.stdout) |stdout| {
                const output = stdout.reader().readAllAlloc(self.allocator, 1024) catch |err| {
                    std.log.warn("clipboard: reading xclip HTML stdout failed: {}", .{err});
                    bridge_error.sendResultToJS(self.allocator, "hasHTML", "{\"value\":false}");
                    return;
                };
                defer self.allocator.free(output);
                has_html = output.len > 0;
            }
        }

        const json = if (has_html) "{\"value\":true}" else "{\"value\":false}";
        bridge_error.sendResultToJS(self.allocator, "hasHTML", json);
    }

    fn linuxHasImage(self: *Self) !void {
        var has_image = false;

        var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch {
            const json = "{\"value\":false}";
            bridge_error.sendResultToJS(self.allocator, "hasImage", json);
            return;
        };
        // Ensure stdout is closed even on error to avoid fd leak
        defer {
            if (child.stdout) |*stdout| stdout.close();
        }
        const result = child.wait() catch |err| {
            std.log.warn("clipboard: waiting for xclip hasImage failed: {}", .{err});
            bridge_error.sendResultToJS(self.allocator, "hasImage", "{\"value\":false}");
            return;
        };

        if (result.Exited == 0) {
            if (child.stdout) |stdout| {
                const output = stdout.reader().readAllAlloc(self.allocator, 1024) catch |err| {
                    std.log.warn("clipboard: reading xclip image stdout failed: {}", .{err});
                    bridge_error.sendResultToJS(self.allocator, "hasImage", "{\"value\":false}");
                    return;
                };
                defer self.allocator.free(output);
                has_image = output.len > 0;
            }
        }

        const json = if (has_image) "{\"value\":true}" else "{\"value\":false}";
        bridge_error.sendResultToJS(self.allocator, "hasImage", json);
    }

    // ============================================
    // Windows Clipboard Implementations (Win32 API)
    // ============================================

    fn windowsWriteText(self: *Self, data: ?[]const u8) !void {
        if (comptime builtin.os.tag != .windows) {
            _ = &self;
            _ = &data;
            return;
        }

        if (data == null) return;
        const json_data = data.?;

        if (std.mem.indexOf(u8, json_data, "\"text\":\"")) |idx| {
            const start = idx + 8;
            if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                const text = json_data[start..end];

                const kernel32 = win32;
                const user32 = win32;

                const CF_TEXT = 1;
                const GMEM_MOVEABLE = 0x0002;

                if (user32.OpenClipboard(null) != 0) {
                    defer _ = user32.CloseClipboard();
                    _ = user32.EmptyClipboard();

                    const len = text.len + 1;
                    const hGlobal = kernel32.GlobalAlloc(GMEM_MOVEABLE, len);
                    if (hGlobal != null) {
                        const pGlobal = kernel32.GlobalLock(hGlobal);
                        if (pGlobal != null) {
                            @memcpy(@as([*]u8, @ptrCast(pGlobal))[0..text.len], text);
                            @as([*]u8, @ptrCast(pGlobal))[text.len] = 0;
                            _ = kernel32.GlobalUnlock(hGlobal);
                            _ = user32.SetClipboardData(CF_TEXT, hGlobal);
                        }
                    }

                    log.debug("Windows: Wrote text to clipboard", .{});
                }
            }
        }
    }

    fn windowsReadText(self: *Self) !void {
        if (builtin.os.tag != .windows) {
            _ = &self;
            return;
        }

        const kernel32 = win32;
        const user32 = win32;

        const CF_TEXT = 1;

        var result_json: []const u8 = "{\"text\":\"\"}";

        if (user32.OpenClipboard(null) != 0) {
            defer _ = user32.CloseClipboard();

            const hData = user32.GetClipboardData(CF_TEXT);
            if (hData != null) {
                const pData = kernel32.GlobalLock(hData);
                if (pData != null) {
                    const text = std.mem.span(@as([*:0]const u8, @ptrCast(pData)));

                    var buf = std.ArrayList(u8).init(self.allocator);
                    defer buf.deinit();

                    try buf.appendSlice("{\"text\":\"");
                    try self.appendEscapedJson(&buf, text);
                    try buf.appendSlice("\"}");
                    result_json = try buf.toOwnedSlice();

                    _ = kernel32.GlobalUnlock(hData);
                }
            }
        }

        bridge_error.sendResultToJS(self.allocator, "readText", result_json);

        if (!std.mem.eql(u8, result_json, "{\"text\":\"\"}")) {
            self.allocator.free(result_json);
        }
    }

    fn windowsWriteHTML(self: *Self, data: ?[]const u8) !void {
        if (builtin.os.tag != .windows) {
            _ = &self;
            _ = &data;
            return;
        }

        if (data == null) return;
        const json_data = data.?;

        if (std.mem.indexOf(u8, json_data, "\"html\":\"")) |idx| {
            const start = idx + 8;
            if (std.mem.indexOfPos(u8, json_data, start, "\"")) |end| {
                const html = json_data[start..end];

                const kernel32 = win32;
                const user32 = win32;

                // Register HTML clipboard format
                const cf_html = user32.RegisterClipboardFormatA("HTML Format");
                const GMEM_MOVEABLE = 0x0002;

                if (user32.OpenClipboard(null) != 0) {
                    defer _ = user32.CloseClipboard();
                    _ = user32.EmptyClipboard();

                    // Create CF_HTML format header
                    const header = "Version:0.9\r\nStartHTML:00000097\r\nEndHTML:00000000\r\nStartFragment:00000000\r\nEndFragment:00000000\r\n";
                    const total_len = header.len + html.len + 1;

                    const hGlobal = kernel32.GlobalAlloc(GMEM_MOVEABLE, total_len);
                    if (hGlobal != null) {
                        const pGlobal = kernel32.GlobalLock(hGlobal);
                        if (pGlobal != null) {
                            const dest = @as([*]u8, @ptrCast(pGlobal));
                            @memcpy(dest[0..header.len], header);
                            @memcpy(dest[header.len..][0..html.len], html);
                            dest[total_len - 1] = 0;
                            _ = kernel32.GlobalUnlock(hGlobal);
                            _ = user32.SetClipboardData(cf_html, hGlobal);
                        }
                    }

                    log.debug("Windows: Wrote HTML to clipboard", .{});
                }
            }
        }
    }

    fn windowsReadHTML(self: *Self) !void {
        if (builtin.os.tag != .windows) {
            _ = &self;
            return;
        }

        const kernel32 = win32;
        const user32 = win32;

        const cf_html = user32.RegisterClipboardFormatA("HTML Format");

        var result_json: []const u8 = "{\"html\":\"\"}";

        if (user32.OpenClipboard(null) != 0) {
            defer _ = user32.CloseClipboard();

            const hData = user32.GetClipboardData(cf_html);
            if (hData != null) {
                const pData = kernel32.GlobalLock(hData);
                if (pData != null) {
                    const html = std.mem.span(@as([*:0]const u8, @ptrCast(pData)));

                    var buf = std.ArrayList(u8).init(self.allocator);
                    defer buf.deinit();

                    try buf.appendSlice("{\"html\":\"");
                    try self.appendEscapedJson(&buf, html);
                    try buf.appendSlice("\"}");
                    result_json = try buf.toOwnedSlice();

                    _ = kernel32.GlobalUnlock(hData);
                }
            }
        }

        bridge_error.sendResultToJS(self.allocator, "readHTML", result_json);

        if (!std.mem.eql(u8, result_json, "{\"html\":\"\"}")) {
            self.allocator.free(result_json);
        }
    }

    fn windowsClear(self: *Self) !void {
        if (builtin.os.tag != .windows) {
            _ = &self;
            return;
        }

        const user32 = win32;

        if (user32.OpenClipboard(null) != 0) {
            _ = user32.EmptyClipboard();
            _ = user32.CloseClipboard();
            log.debug("Windows: Clipboard cleared", .{});
        }
    }

    fn windowsHasText(self: *Self) !void {
        if (builtin.os.tag != .windows) {
            _ = &self;
            return;
        }

        const user32 = win32;
        const CF_TEXT = 1;

        const has_text = user32.IsClipboardFormatAvailable(CF_TEXT) != 0;

        const json = if (has_text) "{\"value\":true}" else "{\"value\":false}";
        bridge_error.sendResultToJS(self.allocator, "hasText", json);
    }

    fn windowsHasHTML(self: *Self) !void {
        if (builtin.os.tag != .windows) {
            _ = &self;
            return;
        }

        const user32 = win32;
        const cf_html = user32.RegisterClipboardFormatA("HTML Format");

        const has_html = user32.IsClipboardFormatAvailable(cf_html) != 0;

        const json = if (has_html) "{\"value\":true}" else "{\"value\":false}";
        bridge_error.sendResultToJS(self.allocator, "hasHTML", json);
    }

    fn windowsHasImage(self: *Self) !void {
        if (builtin.os.tag != .windows) {
            _ = &self;
            return;
        }

        const user32 = win32;
        const CF_BITMAP = 2;
        const CF_DIB = 8;

        const has_image = user32.IsClipboardFormatAvailable(CF_BITMAP) != 0 or
            user32.IsClipboardFormatAvailable(CF_DIB) != 0;

        const json = if (has_image) "{\"value\":true}" else "{\"value\":false}";
        bridge_error.sendResultToJS(self.allocator, "hasImage", json);
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
