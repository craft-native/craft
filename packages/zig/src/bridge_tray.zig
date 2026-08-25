const std = @import("std");
const builtin = @import("builtin");
const tray_menu = @import("tray_menu.zig");
const bridge_error = @import("bridge_error.zig");
const logging = @import("logging.zig");
const icons = @import("icons.zig");
const capabilities = @import("capabilities.zig");

/// The action names this bridge dispatches on.
///
/// Declared once, here, and referenced by both the dispatch chain below and the
/// capability table beside it — so the two cannot disagree. That is enforced:
/// `test/capabilities_test.zig` fails if a declared bridge compares `action`
/// against a bare string literal anywhere, which makes it impossible to add an
/// action without also declaring it.
pub const A = struct {
    pub const set_title = "setTitle";
    pub const set_tooltip = "setTooltip";
    pub const set_menu = "setMenu";
    pub const poll_actions = "pollActions";
    pub const hide = "hide";
    pub const show = "show";
    pub const set_icon = "setIcon";
    pub const set_badge = "setBadge";
};

/// What craft serves on the `tray` namespace.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.set_title, .reply = .none },
    .{ .name = A.set_tooltip, .reply = .none },
    .{ .name = A.set_menu, .reply = .none },
    .{ .name = A.poll_actions, .reply = .none },
    .{ .name = A.hide, .reply = .none },
    .{ .name = A.show, .reply = .none },
    .{ .name = A.set_icon, .reply = .none },
    .{ .name = A.set_badge, .reply = .none },
    // Reachable from JS, dispatched nowhere. `_send` resolves the moment the
    // message is posted, so an app calling this gets a resolved promise and a
    // tray icon that is still there. Declared rather than quietly fixed:
    // whether "destroy" should remove the status item or is just `hide` under
    // another name is an API question, not an introspection one.
    .{
        .name = "destroy",
        .reply = .none,
        .status = .unavailable,
        .reason = "not implemented; call craft.tray.hide() instead",
    },
};

const log = logging.tray;

const BridgeError = bridge_error.BridgeError;

/// Decode Unicode escape sequences like \Ud83c\Udf45 to actual UTF-8
/// Unicode emoji are represented as surrogate pairs in UTF-16:
/// 🍅 (U+1F345) = \Ud83c\Udf45 (high surrogate d83c + low surrogate df45)
fn decodeUnicodeEscapes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Check for \Uxxxx pattern (6 chars total)
        if (i + 6 <= input.len and input[i] == '\\' and (input[i + 1] == 'U' or input[i + 1] == 'u')) {
            const hex_str = input[i + 2 .. i + 6];
            const codepoint = std.fmt.parseInt(u16, hex_str, 16) catch {
                // If parsing fails, just copy the backslash and continue
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };

            // Check if this is a high surrogate (start of surrogate pair)
            if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                // This is a high surrogate, check for low surrogate
                if (i + 12 <= input.len and
                    input[i + 6] == '\\' and
                    (input[i + 7] == 'U' or input[i + 7] == 'u'))
                {
                    const low_hex = input[i + 8 .. i + 12];
                    const low_surrogate = std.fmt.parseInt(u16, low_hex, 16) catch {
                        // Failed to parse low surrogate, copy high as-is
                        try result.append(allocator, input[i]);
                        i += 1;
                        continue;
                    };

                    if (low_surrogate >= 0xDC00 and low_surrogate <= 0xDFFF) {
                        // Valid surrogate pair! Convert to UTF-32 codepoint
                        const high: u32 = codepoint;
                        const low: u32 = low_surrogate;
                        const utf32: u21 = @intCast(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00));

                        // Encode as UTF-8
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(utf32, &utf8_buf) catch {
                            // Encoding failed, skip both surrogates
                            i += 12;
                            continue;
                        };
                        try result.appendSlice(allocator, utf8_buf[0..len]);
                        i += 12; // Skip both \Uxxxx\Uxxxx
                        continue;
                    }
                }
            }

            // Not a surrogate pair, treat as single codepoint
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(codepoint), &utf8_buf) catch {
                // Encoding failed, skip this escape
                i += 6;
                continue;
            };
            try result.appendSlice(allocator, utf8_buf[0..len]);
            i += 6;
            continue;
        }

        try result.append(allocator, input[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

/// Point size for status item icons.
///
/// Matches the menu bar's own font metrics rather than the status item's full
/// height: a glyph sized to the item fills it edge to edge and reads as
/// oversized next to the system's icons, which carry padding.
const MENU_BAR_ICON_POINT_SIZE: f64 = 16.0;

/// Bridge handler for system tray messages from JavaScript
pub const TrayBridge = struct {
    allocator: std.mem.Allocator,
    tray_handle: ?*anyopaque = null,
    current_menu: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn setTrayHandle(self: *Self, handle: *anyopaque) void {
        self.tray_handle = handle;
    }

    /// Handle tray-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            self.reportError(action, err);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.set_title)) {
            try self.setTitle(data);
        } else if (std.mem.eql(u8, action, A.set_tooltip)) {
            try self.setTooltip(data);
        } else if (std.mem.eql(u8, action, A.set_menu)) {
            try self.setMenu(data);
        } else if (std.mem.eql(u8, action, A.poll_actions)) {
            try self.pollActions();
        } else if (std.mem.eql(u8, action, A.hide)) {
            try self.hide();
        } else if (std.mem.eql(u8, action, A.show)) {
            try self.showTray();
        } else if (std.mem.eql(u8, action, A.set_icon)) {
            try self.setIcon(data);
        } else if (std.mem.eql(u8, action, A.set_badge)) {
            try self.setBadge(data);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// Report error to JavaScript and log
    fn reportError(self: *Self, action: []const u8, err: anyerror) void {
        const bridge_err: BridgeError = switch (err) {
            BridgeError.TrayHandleNotSet => BridgeError.TrayHandleNotSet,
            BridgeError.MissingData => BridgeError.MissingData,
            BridgeError.InvalidJSON => BridgeError.InvalidJSON,
            else => BridgeError.NativeCallFailed,
        };
        bridge_error.sendErrorToJS(self.allocator, action, bridge_err);
    }

    /// Get tray handle or return error
    fn requireTrayHandle(self: *Self) BridgeError!*anyopaque {
        return self.tray_handle orelse BridgeError.TrayHandleNotSet;
    }

    fn pollActions(self: *Self) !void {
        _ = self;

        // A left click on the status item, which JavaScript turns into a
        // craft:tray:click event. Right clicks open the menu natively and never
        // reach here.
        if (@import("tray_click.zig").takePendingClick()) {
            const bridge = @import("bridge.zig");
            bridge.evalJS("if(window.__craftDeliverTrayClick)window.__craftDeliverTrayClick('left');") catch |err| {
                log.debug("Failed to deliver tray click: {}", .{err});
            };
        }

        // Pop the next action from the queue
        if (tray_menu.getPendingAction()) |action| {
            log.debug("Polling found action: {s}", .{action});

            // Escape `action` so that a payload containing `'`, `\`, or a
            // newline cannot close out the string literal and inject JS.
            var esc_buf: [200]u8 = undefined;
            var esc_len: usize = 0;
            for (action) |c| {
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

            // Call the JavaScript global function to deliver the action
            const bridge = @import("bridge.zig");
            var buf: [256]u8 = undefined;
            const js = try std.fmt.bufPrint(&buf,
                \\if(window.__craftDeliverAction)window.__craftDeliverAction('{s}');
            , .{esc_buf[0..esc_len]});

            bridge.evalJS(js) catch |err| {
                log.debug("Failed to deliver action: {}", .{err});
            };
        }
    }

    fn setTitle(self: *Self, title: []const u8) !void {
        log.debug("setTitle called with: {s}", .{title});
        log.debug("setTitle: tray_handle = {*}", .{self.tray_handle});

        const handle = try self.requireTrayHandle();
        log.debug("setTitle: got handle = {*}", .{handle});

        if (builtin.os.tag == .macos) {
            // Decode Unicode escapes like \Ud83c\Udf45 to actual UTF-8
            const decoded_title = try decodeUnicodeEscapes(self.allocator, title);
            defer self.allocator.free(decoded_title);

            log.debug("setTitle: decoded = {s}", .{decoded_title});

            const macos = @import("tray.zig");
            try macos.macosSetTitle(handle, decoded_title);
            log.debug("setTitle: macosSetTitle completed", .{});

            // Clearing the title on an icon-only item, or adding one back beside
            // an icon, both change where the image belongs.
            syncImagePosition(@import("macos.zig").msgSend0(handle, "button"));
        }
    }

    fn setTooltip(self: *Self, tooltip: []const u8) !void {
        const handle = try self.requireTrayHandle();

        if (builtin.os.tag == .macos) {
            const macos = @import("tray.zig");
            try macos.macosSetTooltip(handle, tooltip);
        }
    }

    fn setMenu(self: *Self, menu_json: []const u8) !void {
        log.debug("setMenu called with json: {s}", .{menu_json});

        const handle = try self.requireTrayHandle();
        log.debug("setMenu: got handle", .{});

        // Parse the menu JSON directly - the outer JSON parsing already unescaped it
        log.debug("setMenu: parsing JSON...", .{});
        const menu_items = try tray_menu.parseMenuJSON(self.allocator, menu_json);
        defer self.allocator.free(menu_items);
        log.debug("setMenu: parsed {} items", .{menu_items.len});

        // Create NSMenu (macOS)
        if (builtin.os.tag == .macos) {
            // Clean up previous menu if exists
            if (self.current_menu) |old_menu| {
                log.debug("setMenu: destroying old menu", .{});
                tray_menu.destroyNSMenu(old_menu);
            }

            // Create new menu
            log.debug("setMenu: creating NSMenu...", .{});
            const menu = try tray_menu.createNSMenu(self.allocator, menu_items);
            self.current_menu = menu;
            log.debug("setMenu: NSMenu created", .{});

            // Attach to tray
            const macos = @import("tray.zig");
            log.debug("setMenu: attaching to tray...", .{});
            try macos.macosSetMenu(handle, menu);
            log.debug("setMenu: completed successfully", .{});
        }
    }

    fn hide(self: *Self) !void {
        const handle = try self.requireTrayHandle();

        log.debug("hide", .{});

        if (builtin.os.tag == .macos) {
            const tray = @import("tray.zig");
            tray.macosHide(handle);
        }
    }

    fn showTray(self: *Self) !void {
        const handle = try self.requireTrayHandle();

        log.debug("show", .{});

        if (builtin.os.tag == .macos) {
            const tray = @import("tray.zig");
            tray.macosShow(handle);
        }
    }

    /// Reconcile a status item button's imagePosition with what it actually has.
    ///
    /// AppKit defaults the position to NSNoImage, which silently discards any
    /// image the app sets, and leaving it on NSImageOnly would hide a title the
    /// app sets later. Deriving it from the button's current contents keeps both
    /// setIcon and setTitle correct regardless of the order they are called in.
    fn syncImagePosition(button: ?*anyopaque) void {
        if (builtin.os.tag != .macos) return;

        const macos = @import("macos.zig");
        if (macos.msgSend0(button, "image") == null) return;

        var has_title = false;
        const title = macos.msgSend0(button, "title");
        if (title != null) {
            const utf8 = macos.msgSend0(title, "UTF8String");
            if (utf8 != null) {
                const cstr: [*:0]const u8 = @ptrCast(utf8);
                has_title = cstr[0] != 0;
            }
        }

        const NSImageOnly: c_long = 1;
        const NSImageLeading: c_long = 7;
        _ = macos.msgSend1(button, "setImagePosition:", if (has_title) NSImageLeading else NSImageOnly);
    }

    /// Extract the icon name from the bridge payload.
    ///
    /// The JS side sends `{"icon":"name"}`, and this handler used to hand that
    /// whole JSON string to AppKit as the symbol name — so every lookup missed
    /// and no icon was ever drawn. A bare string is still accepted, since the
    /// CLI and older callers pass one.
    fn parseIconName(allocator: std.mem.Allocator, data: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len == 0) return null;
        if (trimmed[0] != '{') return trimmed;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| {
            log.debug("setIcon: could not parse payload: {}", .{err});
            return null;
        };
        defer parsed.deinit();

        const icon = parsed.value.object.get("icon") orelse return null;
        if (icon != .string or icon.string.len == 0) return null;

        // The parsed tree is freed above, so hand back a copy the caller owns.
        return allocator.dupe(u8, icon.string) catch null;
    }

    fn setIcon(self: *Self, data: []const u8) !void {
        const handle = try self.requireTrayHandle();

        log.debug("setIcon: {s}", .{data});

        const owns_name = data.len > 0 and std.mem.trim(u8, data, " \t\r\n")[0] == '{';
        const icon_name = parseIconName(self.allocator, data) orelse {
            log.debug("setIcon: no icon name in payload", .{});
            return;
        };
        defer if (owns_name) self.allocator.free(icon_name);

        // First try to resolve icon through cross-platform icons module
        const resolved_name = if (icons.getIconByName(icon_name)) |icon| blk: {
            const platform_icon = icons.getPlatformIcon(icon);
            if (platform_icon.kind == .sf_symbol and platform_icon.value.len > 0) {
                break :blk platform_icon.value;
            }
            break :blk icon_name;
        } else icon_name;

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Get NSStatusItem button
            const button = macos.msgSend0(handle, "button");
            if (button == null) return;

            // Try to load SF Symbol
            const NSImage = macos.getClass("NSImage");

            // Use resolved SF Symbol name. Allocate through the bridge's own
            // allocator rather than `std.heap.c_allocator` so lifecycle and
            // failure paths match the rest of the bridges.
            const icon_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, resolved_name);
            defer self.allocator.free(icon_cstr);

            const NSString = macos.getClass("NSString");
            const str_alloc = macos.msgSend0(NSString, "alloc");
            const ns_name = macos.msgSend1(str_alloc, "initWithUTF8String:", icon_cstr.ptr);

            // A path loads that file as the icon; anything else is an SF Symbol
            // name. Apps whose mark is not in the system set — a particular cup,
            // a logo — ship a PDF or PNG and point at it, and still get the
            // template tinting the symbols get.
            const from_file = std.mem.indexOfScalar(u8, resolved_name, '/') != null;
            const image = if (from_file)
                macos.msgSend1(macos.msgSend0(NSImage, "alloc"), "initWithContentsOfFile:", ns_name)
            else
                macos.msgSend2(NSImage, "imageWithSystemSymbolName:accessibilityDescription:", ns_name, @as(?*anyopaque, null));

            if (image != null and from_file) {
                // A file-backed image carries its own artwork, so it only needs
                // sizing and template tinting.
                _ = macos.msgSend1(image, "setTemplate:", @as(c_int, 1));
                macos.msgSendVoid1Size(image, "setSize:", .{
                    .width = MENU_BAR_ICON_POINT_SIZE,
                    .height = MENU_BAR_ICON_POINT_SIZE,
                });
                _ = macos.msgSend1(button, "setImage:", image);
                syncImagePosition(button);
                log.debug("Set icon from file: {s}", .{resolved_name});
            } else if (image != null) {
                // An SF Symbol with no configuration inherits a point size from
                // the control's font, which in a status item button renders as a
                // few-pixel speck. Ask for the menu bar's own metrics — 16pt at
                // the large scale — so the glyph matches what AppKit and other
                // menu bar apps draw.
                const NSImageSymbolConfiguration = macos.getClass("NSImageSymbolConfiguration");
                const NSImageSymbolScaleMedium: c_long = 2;
                const NSFontWeightRegular: f64 = 0.0;
                const configuration = macos.msgSendSymbolConfiguration(
                    NSImageSymbolConfiguration,
                    "configurationWithPointSize:weight:scale:",
                    MENU_BAR_ICON_POINT_SIZE,
                    NSFontWeightRegular,
                    NSImageSymbolScaleMedium,
                );

                const configured = if (configuration != null)
                    macos.msgSend1(image, "imageWithSymbolConfiguration:", configuration)
                else
                    image;
                const final_image = if (configured != null) configured else image;

                // Template rendering lets macOS tint the glyph for light mode,
                // dark mode and the highlighted menu bar.
                _ = macos.msgSend1(final_image, "setTemplate:", @as(c_int, 1));
                _ = macos.msgSend1(button, "setImage:", final_image);

                // An NSButton whose imagePosition is NSNoImage — the default for
                // a status item button created with a title — draws no image at
                // all, so the assignment above was invisible.
                syncImagePosition(button);

                log.debug("Set SF Symbol icon: {s}", .{resolved_name});
            } else {
                log.debug("SF Symbol not found: {s}", .{resolved_name});
            }
        }
    }

    /// Set dock badge (macOS only)
    /// JSON: {"badge": "42"} or {"badge": ""} to clear
    fn setBadge(self: *Self, badge_text: []const u8) !void {
        _ = try self.requireTrayHandle();

        log.debug("setBadge: {s}", .{badge_text});

        if (builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Get NSApplication dock tile
            const NSApplication = macos.getClass("NSApplication");
            const app = macos.msgSend0(NSApplication, "sharedApplication");
            const dock_tile = macos.msgSend0(app, "dockTile");

            // Create NSString for badge
            const NSString = macos.getClass("NSString");
            const str_alloc = macos.msgSend0(NSString, "alloc");

            if (badge_text.len == 0) {
                // Clear badge with empty string
                const empty_cstr = @as([*:0]const u8, @ptrCast("".ptr));
                const ns_badge = macos.msgSend1(str_alloc, "initWithUTF8String:", empty_cstr);
                _ = macos.msgSend1(dock_tile, "setBadgeLabel:", ns_badge);
            } else {
                const badge_cstr = try @import("memory.zig").dupeZ(self.allocator, u8, badge_text);
                defer self.allocator.free(badge_cstr);

                const ns_badge = macos.msgSend1(str_alloc, "initWithUTF8String:", badge_cstr.ptr);
                _ = macos.msgSend1(dock_tile, "setBadgeLabel:", ns_badge);
            }

            log.debug("Badge set to: {s}", .{badge_text});
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.current_menu) |menu| {
            tray_menu.destroyNSMenu(menu);
        }
    }
};
