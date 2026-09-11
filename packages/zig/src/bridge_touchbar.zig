const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");

const BridgeError = bridge_error.BridgeError;

/// Touch Bar item types
pub const TouchBarItemType = enum {
    button,
    label,
    slider,
    popover,
    colorPicker,
    scrubber,
    group,
    spacer,
};

/// Touch Bar item configuration
pub const TouchBarItem = struct {
    id: []const u8,
    item_type: TouchBarItemType,
    label: ?[]const u8 = null,
    icon: ?[]const u8 = null, // SF Symbol name
    color: ?[]const u8 = null, // Hex color for background
    callback_id: ?[]const u8 = null,
    min_value: f64 = 0,
    max_value: f64 = 100,
    value: f64 = 0,
};

/// Touch Bar bridge for MacBook Pro Touch Bar customization
pub const TouchBarBridge = struct {
    allocator: std.mem.Allocator,
    touch_bar: ?*anyopaque = null,
    items: std.StringHashMap(TouchBarItem),
    delegate: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .items = std.StringHashMap(TouchBarItem).init(allocator),
        };
    }

    /// Handle touch bar-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            self.reportError(action, err);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "setItems")) {
            try self.setItems(data);
        } else if (std.mem.eql(u8, action, "addItem")) {
            try self.addItem(data);
        } else if (std.mem.eql(u8, action, "removeItem")) {
            try self.removeItem(data);
        } else if (std.mem.eql(u8, action, "updateItem")) {
            try self.updateItem(data);
        } else if (std.mem.eql(u8, action, "setItemLabel")) {
            try self.setItemLabel(data);
        } else if (std.mem.eql(u8, action, "setItemIcon")) {
            try self.setItemIcon(data);
        } else if (std.mem.eql(u8, action, "setItemEnabled")) {
            try self.setItemEnabled(data);
        } else if (std.mem.eql(u8, action, "setSliderValue")) {
            try self.setSliderValue(data);
        } else if (std.mem.eql(u8, action, "clear")) {
            try self.clear();
        } else if (std.mem.eql(u8, action, "show")) {
            try self.show();
        } else if (std.mem.eql(u8, action, "hide")) {
            try self.hide();
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

    /// Set all touch bar items at once
    /// JSON: {"items": [{"id": "play", "type": "button", "label": "Play", "icon": "play.fill"}]}
    fn setItems(self: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            // Touch Bar is macOS-only hardware
            const bridge = @import("bridge.zig");
            var not_supported_buf: [128]u8 = undefined;
            const not_supported_js = std.fmt.bufPrint(&not_supported_buf,
                \\if(window.__craftTouchBarError)window.__craftTouchBarError('PLATFORM_NOT_SUPPORTED','Touch Bar is only available on macOS');
            , .{}) catch return;
            bridge.evalJS(not_supported_js) catch |err| {
                std.log.debug("JS eval failed for Touch Bar not-supported callback: {}", .{err});
            };
            return;
        }

        // Clear existing items first
        self.clearItems();

        // Parse items array
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, data, pos, "{\"id\":\"")) |start| {
            // Find end of this item object
            var brace_count: i32 = 0;
            const item_start = start;
            var item_end = start;
            for (data[start..], 0..) |c, i| {
                if (c == '{') brace_count += 1;
                if (c == '}') {
                    brace_count -= 1;
                    if (brace_count == 0) {
                        item_end = start + i + 1;
                        break;
                    }
                }
            }

            if (item_end > item_start) {
                try self.parseAndAddItem(data[item_start..item_end]);
            }
            pos = item_end;
        }

        // Rebuild touch bar
        try self.rebuildTouchBar();
    }

    /// Add a single item to the touch bar
    /// JSON: {"id": "pause", "type": "button", "label": "Pause", "icon": "pause.fill"}
    fn addItem(self: *Self, data: []const u8) !void {
        try self.parseAndAddItem(data);
        try self.rebuildTouchBar();
    }

    /// Parse item JSON and add to items map
    fn parseAndAddItem(self: *Self, data: []const u8) !void {
        var item = TouchBarItem{
            .id = "",
            .item_type = .button,
        };

        // Parse id
        if (std.mem.indexOf(u8, data, "\"id\":\"")) |idx| {
            const start = idx + 6;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item.id = try self.allocator.dupe(u8, data[start..end]);
            }
        }

        if (item.id.len == 0) return BridgeError.MissingData;

        // Parse type
        if (std.mem.indexOf(u8, data, "\"type\":\"")) |idx| {
            const start = idx + 8;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                const type_str = data[start..end];
                if (std.mem.eql(u8, type_str, "button")) {
                    item.item_type = .button;
                } else if (std.mem.eql(u8, type_str, "label")) {
                    item.item_type = .label;
                } else if (std.mem.eql(u8, type_str, "slider")) {
                    item.item_type = .slider;
                } else if (std.mem.eql(u8, type_str, "popover")) {
                    item.item_type = .popover;
                } else if (std.mem.eql(u8, type_str, "colorPicker")) {
                    item.item_type = .colorPicker;
                } else if (std.mem.eql(u8, type_str, "scrubber")) {
                    item.item_type = .scrubber;
                } else if (std.mem.eql(u8, type_str, "group")) {
                    item.item_type = .group;
                } else if (std.mem.eql(u8, type_str, "spacer")) {
                    item.item_type = .spacer;
                }
            }
        }

        // Parse label
        if (std.mem.indexOf(u8, data, "\"label\":\"")) |idx| {
            const start = idx + 9;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item.label = try self.allocator.dupe(u8, data[start..end]);
            }
        }

        // Parse icon (SF Symbol name)
        if (std.mem.indexOf(u8, data, "\"icon\":\"")) |idx| {
            const start = idx + 8;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item.icon = try self.allocator.dupe(u8, data[start..end]);
            }
        }

        // Parse color
        if (std.mem.indexOf(u8, data, "\"color\":\"")) |idx| {
            const start = idx + 9;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item.color = try self.allocator.dupe(u8, data[start..end]);
            }
        }

        // Parse callback
        if (std.mem.indexOf(u8, data, "\"callback\":\"")) |idx| {
            const start = idx + 12;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                item.callback_id = try self.allocator.dupe(u8, data[start..end]);
            }
        }

        // Parse slider values
        if (item.item_type == .slider) {
            if (std.mem.indexOf(u8, data, "\"min\":")) |idx| {
                const start = idx + 6;
                var end = start;
                while (end < data.len and (data[end] >= '0' and data[end] <= '9' or data[end] == '.' or data[end] == '-')) : (end += 1) {}
                item.min_value = std.fmt.parseFloat(f64, data[start..end]) catch 0;
            }
            if (std.mem.indexOf(u8, data, "\"max\":")) |idx| {
                const start = idx + 6;
                var end = start;
                while (end < data.len and (data[end] >= '0' and data[end] <= '9' or data[end] == '.' or data[end] == '-')) : (end += 1) {}
                item.max_value = std.fmt.parseFloat(f64, data[start..end]) catch 100;
            }
            if (std.mem.indexOf(u8, data, "\"value\":")) |idx| {
                const start = idx + 8;
                var end = start;
                while (end < data.len and (data[end] >= '0' and data[end] <= '9' or data[end] == '.' or data[end] == '-')) : (end += 1) {}
                item.value = std.fmt.parseFloat(f64, data[start..end]) catch 0;
            }
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[TouchBarBridge] Adding item: id={s}, type={}\n", .{ item.id, item.item_type });
        try self.items.put(item.id, item);
    }

    /// Remove an item from the touch bar
    /// JSON: {"id": "pause"}
    fn removeItem(self: *Self, data: []const u8) !void {
        var id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"id\":\"")) |idx| {
            const start = idx + 6;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                id = data[start..end];
            }
        }

        if (id.len == 0) return BridgeError.MissingData;

        if (self.items.fetchRemove(id)) |kv| {
            self.freeItem(&kv.value);
        }

        try self.rebuildTouchBar();
    }

    /// Update an item's properties
    /// JSON: {"id": "play", "label": "Playing..."}
    fn updateItem(self: *Self, data: []const u8) !void {
        var id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"id\":\"")) |idx| {
            const start = idx + 6;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                id = data[start..end];
            }
        }

        if (id.len == 0) return BridgeError.MissingData;

        if (self.items.getPtr(id)) |item| {
            // Update label if provided
            if (std.mem.indexOf(u8, data, "\"label\":\"")) |idx| {
                const start = idx + 9;
                if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                    if (item.label) |old| self.allocator.free(old);
                    item.label = try self.allocator.dupe(u8, data[start..end]);
                }
            }

            // Update icon if provided
            if (std.mem.indexOf(u8, data, "\"icon\":\"")) |idx| {
                const start = idx + 8;
                if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                    if (item.icon) |old| self.allocator.free(old);
                    item.icon = try self.allocator.dupe(u8, data[start..end]);
                }
            }

            try self.rebuildTouchBar();
        }
    }

    /// Set label of a specific item
    /// JSON: {"id": "status", "label": "Recording..."}
    fn setItemLabel(self: *Self, data: []const u8) !void {
        try self.updateItem(data);
    }

    /// Set icon of a specific item
    /// JSON: {"id": "play", "icon": "pause.fill"}
    fn setItemIcon(self: *Self, data: []const u8) !void {
        try self.updateItem(data);
    }

    /// Enable/disable an item
    /// JSON: {"id": "save", "enabled": false}
    fn setItemEnabled(_: *Self, data: []const u8) !void {
        if (comptime builtin.os.tag != .macos) {
            // Touch Bar is macOS-only hardware
            const bridge = @import("bridge.zig");
            var not_supported_buf: [128]u8 = undefined;
            const not_supported_js = std.fmt.bufPrint(&not_supported_buf,
                \\if(window.__craftTouchBarError)window.__craftTouchBarError('PLATFORM_NOT_SUPPORTED','Touch Bar is only available on macOS');
            , .{}) catch return;
            bridge.evalJS(not_supported_js) catch |err| {
                std.log.debug("JS eval failed for Touch Bar not-supported callback: {}", .{err});
            };
            return;
        }

        var id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"id\":\"")) |idx| {
            const start = idx + 6;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                id = data[start..end];
            }
        }

        const enabled = std.mem.indexOf(u8, data, "\"enabled\":true") != null;

        // Would need to track NSButton instances to enable/disable
        if (comptime builtin.mode == .Debug)
            std.debug.print("[TouchBarBridge] setItemEnabled: id={s}, enabled={}\n", .{ id, enabled });
    }

    /// Set slider value
    /// JSON: {"id": "volume", "value": 75}
    fn setSliderValue(self: *Self, data: []const u8) !void {
        var id: []const u8 = "";
        if (std.mem.indexOf(u8, data, "\"id\":\"")) |idx| {
            const start = idx + 6;
            if (std.mem.indexOfPos(u8, data, start, "\"")) |end| {
                id = data[start..end];
            }
        }

        if (id.len == 0) return BridgeError.MissingData;

        if (self.items.getPtr(id)) |item| {
            if (std.mem.indexOf(u8, data, "\"value\":")) |idx| {
                const start = idx + 8;
                var end = start;
                while (end < data.len and (data[end] >= '0' and data[end] <= '9' or data[end] == '.' or data[end] == '-')) : (end += 1) {}
                item.value = std.fmt.parseFloat(f64, data[start..end]) catch item.value;
            }

            // Would need to track NSSlider instance to update value
            if (comptime builtin.mode == .Debug)
                std.debug.print("[TouchBarBridge] Slider value updated: {s} = {d}\n", .{ id, item.value });
        }
    }

    /// Clear all touch bar items
    fn clear(self: *Self) !void {
        self.clearItems();
        try self.rebuildTouchBar();
    }

    fn clearItems(self: *Self) void {
        var it = self.items.iterator();
        while (it.next()) |entry| {
            self.freeItem(entry.value_ptr);
        }
        self.items.clearAndFree();
    }

    fn freeItem(self: *Self, item: *const TouchBarItem) void {
        self.allocator.free(item.id);
        if (item.label) |l| self.allocator.free(l);
        if (item.icon) |i| self.allocator.free(i);
        if (item.color) |c| self.allocator.free(c);
        if (item.callback_id) |cb| self.allocator.free(cb);
    }

    /// Show the touch bar
    fn show(_: *Self) !void {
        if (comptime builtin.os.tag != .macos) {
            // Touch Bar is macOS-only hardware
            const bridge = @import("bridge.zig");
            var not_supported_buf: [128]u8 = undefined;
            const not_supported_js = std.fmt.bufPrint(&not_supported_buf,
                \\if(window.__craftTouchBarError)window.__craftTouchBarError('PLATFORM_NOT_SUPPORTED','Touch Bar is only available on macOS');
            , .{}) catch return;
            bridge.evalJS(not_supported_js) catch |err| {
                std.log.debug("JS eval failed for Touch Bar not-supported callback: {}", .{err});
            };
            return;
        }

        const macos = @import("macos.zig");

        // Make touch bar visible by presenting it
        const NSApp = macos.msgSend0(macos.getClass("NSApplication"), "sharedApplication");
        _ = macos.msgSend1Bool(NSApp, "setAutomaticCustomizeTouchBarMenuItemEnabled:", true);

        if (comptime builtin.mode == .Debug)
            std.debug.print("[TouchBarBridge] Touch bar shown\n", .{});
    }

    /// Hide the touch bar
    fn hide(self: *Self) !void {
        _ = self;
        if (comptime builtin.os.tag != .macos) {
            // Touch Bar is macOS-only hardware
            const bridge = @import("bridge.zig");
            var not_supported_buf: [128]u8 = undefined;
            const not_supported_js = std.fmt.bufPrint(&not_supported_buf,
                \\if(window.__craftTouchBarError)window.__craftTouchBarError('PLATFORM_NOT_SUPPORTED','Touch Bar is only available on macOS');
            , .{}) catch return;
            bridge.evalJS(not_supported_js) catch |err| {
                std.log.debug("JS eval failed for Touch Bar not-supported callback: {}", .{err});
            };
            return;
        }

        if (comptime builtin.mode == .Debug)
            std.debug.print("[TouchBarBridge] Touch bar hidden\n", .{});
    }

    /// Rebuild the touch bar with current items
    fn rebuildTouchBar(self: *Self) !void {
        if (comptime builtin.os.tag != .macos) {
            // Touch Bar is macOS-only hardware
            const bridge = @import("bridge.zig");
            var not_supported_buf: [128]u8 = undefined;
            const not_supported_js = std.fmt.bufPrint(&not_supported_buf,
                \\if(window.__craftTouchBarError)window.__craftTouchBarError('PLATFORM_NOT_SUPPORTED','Touch Bar is only available on macOS');
            , .{}) catch return;
            bridge.evalJS(not_supported_js) catch |err| {
                std.log.debug("JS eval failed for Touch Bar not-supported callback: {}", .{err});
            };
            return;
        }

        const macos = @import("macos.zig");

        // Get the main window
        const NSApp = macos.msgSend0(macos.getClass("NSApplication"), "sharedApplication");
        const window = macos.msgSend0(NSApp, "mainWindow");
        if (window == null) {
            if (comptime builtin.mode == .Debug)
                std.debug.print("[TouchBarBridge] No main window\n", .{});
            return;
        }

        // Create NSTouchBar
        const NSTouchBar = macos.getClass("NSTouchBar");
        if (NSTouchBar == null) {
            if (comptime builtin.mode == .Debug)
                std.debug.print("[TouchBarBridge] NSTouchBar not available\n", .{});
            return;
        }

        const touch_bar = macos.msgSend0(macos.msgSend0(NSTouchBar, "alloc"), "init");
        if (touch_bar == null) return;

        self.touch_bar = touch_bar;

        // Create identifier array for default items
        const NSMutableArray = macos.getClass("NSMutableArray");
        const identifiers = macos.msgSend0(macos.msgSend0(NSMutableArray, "alloc"), "init");

        var it = self.items.iterator();
        while (it.next()) |entry| {
            const item = entry.value_ptr.*;

            // Create identifier string
            const NSString = macos.getClass("NSString");
            const identifier = macos.msgSend1(
                NSString,
                "stringWithUTF8String:",
                @as([*c]const u8, @ptrCast(item.id.ptr)),
            );

            // Add to identifiers array
            _ = macos.msgSend1(identifiers, "addObject:", identifier);

            // Create the actual touch bar item
            _ = self.createTouchBarItem(item, identifier);
        }

        // Set default item identifiers
        _ = macos.msgSend1(touch_bar, "setDefaultItemIdentifiers:", identifiers);

        // Set touch bar on window
        _ = macos.msgSend1(window, "setTouchBar:", touch_bar);

        if (comptime builtin.mode == .Debug)
            std.debug.print("[TouchBarBridge] Touch bar rebuilt with {d} items\n", .{self.items.count()});
    }

    /// Create a native touch bar item
    fn createTouchBarItem(self: *Self, item: TouchBarItem, identifier: ?*anyopaque) ?*anyopaque {
        _ = self;
        if (comptime builtin.os.tag != .macos) return null;

        const macos = @import("macos.zig");

        return switch (item.item_type) {
            .button => blk: {
                const NSCustomTouchBarItem = macos.getClass("NSCustomTouchBarItem");
                const touch_item = macos.msgSend1(
                    macos.msgSend0(NSCustomTouchBarItem, "alloc"),
                    "initWithIdentifier:",
                    identifier,
                );

                // Create button
                const NSButton = macos.getClass("NSButton");
                var button: ?*anyopaque = null;

                if (item.icon) |icon_name| {
                    // Button with image
                    const NSImage = macos.getClass("NSImage");
                    const icon_str = macos.msgSend1(
                        macos.getClass("NSString"),
                        "stringWithUTF8String:",
                        @as([*c]const u8, @ptrCast(icon_name.ptr)),
                    );
                    const image = macos.msgSend1(NSImage, "imageWithSystemSymbolName:accessibilityDescription:", icon_str);

                    if (item.label) |label| {
                        const label_str = macos.msgSend1(
                            macos.getClass("NSString"),
                            "stringWithUTF8String:",
                            @as([*c]const u8, @ptrCast(label.ptr)),
                        );
                        button = macos.msgSend3(NSButton, "buttonWithTitle:image:target:action:", label_str, image, @as(?*anyopaque, null));
                    } else {
                        button = macos.msgSend2(NSButton, "buttonWithImage:target:action:", image, @as(?*anyopaque, null));
                    }
                } else if (item.label) |label| {
                    // Button with title only
                    const label_str = macos.msgSend1(
                        macos.getClass("NSString"),
                        "stringWithUTF8String:",
                        @as([*c]const u8, @ptrCast(label.ptr)),
                    );
                    button = macos.msgSend2(NSButton, "buttonWithTitle:target:action:", label_str, @as(?*anyopaque, null));
                }

                if (button != null) {
                    _ = macos.msgSend1(touch_item, "setView:", button);
                }

                break :blk touch_item;
            },
            .label => blk: {
                const NSCustomTouchBarItem = macos.getClass("NSCustomTouchBarItem");
                const touch_item = macos.msgSend1(
                    macos.msgSend0(NSCustomTouchBarItem, "alloc"),
                    "initWithIdentifier:",
                    identifier,
                );

                // Create text field
                const NSTextField = macos.getClass("NSTextField");
                const label_view = macos.msgSend0(macos.msgSend0(NSTextField, "alloc"), "init");

                if (item.label) |label| {
                    const label_str = macos.msgSend1(
                        macos.getClass("NSString"),
                        "stringWithUTF8String:",
                        @as([*c]const u8, @ptrCast(label.ptr)),
                    );
                    _ = macos.msgSend1(label_view, "setStringValue:", label_str);
                }

                _ = macos.msgSend1Bool(label_view, "setEditable:", false);
                _ = macos.msgSend1Bool(label_view, "setBezeled:", false);
                _ = macos.msgSend1Bool(label_view, "setDrawsBackground:", false);

                _ = macos.msgSend1(touch_item, "setView:", label_view);
                break :blk touch_item;
            },
            .slider => blk: {
                const NSSliderTouchBarItem = macos.getClass("NSSliderTouchBarItem");
                if (NSSliderTouchBarItem == null) break :blk null;

                const touch_item = macos.msgSend1(
                    macos.msgSend0(NSSliderTouchBarItem, "alloc"),
                    "initWithIdentifier:",
                    identifier,
                );

                // Configure slider
                const slider = macos.msgSend0(touch_item, "slider");
                if (slider != null) {
                    _ = macos.msgSend1Double(slider, "setMinValue:", item.min_value);
                    _ = macos.msgSend1Double(slider, "setMaxValue:", item.max_value);
                    _ = macos.msgSend1Double(slider, "setDoubleValue:", item.value);
                }

                if (item.label) |label| {
                    const label_str = macos.msgSend1(
                        macos.getClass("NSString"),
                        "stringWithUTF8String:",
                        @as([*c]const u8, @ptrCast(label.ptr)),
                    );
                    _ = macos.msgSend1(touch_item, "setLabel:", label_str);
                }

                break :blk touch_item;
            },
            .colorPicker => blk: {
                const NSColorPickerTouchBarItem = macos.getClass("NSColorPickerTouchBarItem");
                if (NSColorPickerTouchBarItem == null) break :blk null;

                const touch_item = macos.msgSend1(
                    NSColorPickerTouchBarItem,
                    "colorPickerWithIdentifier:",
                    identifier,
                );

                break :blk touch_item;
            },
            .spacer => blk: {
                // Use fixed space identifier
                const NSTouchBarItem = macos.getClass("NSTouchBarItem");
                _ = NSTouchBarItem;
                // Return nil - spacers are handled via special identifiers
                break :blk null;
            },
            else => null,
        };
    }

    /// Trigger callback for touch bar item
    fn triggerCallback(self: *Self, item_id: []const u8) void {
        _ = self;
        if (comptime builtin.os.tag != .macos) {
            // Touch Bar is macOS-only hardware
            const bridge = @import("bridge.zig");
            var not_supported_buf: [128]u8 = undefined;
            const not_supported_js = std.fmt.bufPrint(&not_supported_buf,
                \\if(window.__craftTouchBarError)window.__craftTouchBarError('PLATFORM_NOT_SUPPORTED','Touch Bar is only available on macOS');
            , .{}) catch return;
            bridge.evalJS(not_supported_js) catch |err| {
                std.log.debug("JS eval failed for Touch Bar not-supported callback: {}", .{err});
            };
            return;
        }

        const bridge = @import("bridge.zig");

        // Escape `item_id` before embedding — caller-supplied Touch Bar item
        // identifiers could otherwise close the JS string literal.
        var id_buf: [128]u8 = undefined;
        const id_esc = bridge_error.escapeJsSingleQuoted(&id_buf, item_id) catch return;

        var buf: [256]u8 = undefined;
        const js = std.fmt.bufPrint(&buf,
            \\if(window.__craftTouchBarCallback)window.__craftTouchBarCallback('{s}');
        , .{id_esc}) catch return;

        bridge.evalJS(js) catch |err| {
            std.log.debug("JS eval failed for Touch Bar callback: {}", .{err});
        };
    }

    pub fn deinit(self: *Self) void {
        self.clearItems();
        self.items.deinit();
    }
};

/// Global touch bar bridge instance
var global_touchbar_bridge: ?*TouchBarBridge = null;

pub fn getGlobalTouchBarBridge() ?*TouchBarBridge {
    return global_touchbar_bridge;
}

pub fn setGlobalTouchBarBridge(bridge: *TouchBarBridge) void {
    global_touchbar_bridge = bridge;
}
