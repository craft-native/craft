const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos.zig");
const window_context = @import("window_context.zig");
const NativeSidebar = @import("components/native_sidebar.zig").NativeSidebar;
const NativeFileBrowser = @import("components/native_file_browser.zig").NativeFileBrowser;
const NativeSplitView = @import("components/native_split_view.zig").NativeSplitView;
const NativeSplitViewController = @import("components/native_split_view_controller.zig").NativeSplitViewController;
const space_switcher = @import("components/native_space_switcher.zig");
const context_menu = @import("components/context_menu.zig");
const quick_look = @import("components/quick_look.zig");

const WindowState = struct {
    allocator: std.mem.Allocator,
    window: macos.objc.id,
    sidebars: std.StringHashMap(*NativeSidebar),
    file_browsers: std.StringHashMap(*NativeFileBrowser),
    split_views: std.StringHashMap(*NativeSplitView),
    split_view_controller: ?*NativeSplitViewController = null,
    original_webview: macos.objc.id = null,
    active_context_menu_delegate: ?*context_menu.ContextMenuDelegate = null,
    space_switcher: ?*space_switcher.SpaceSwitcher = null,

    fn init(allocator: std.mem.Allocator, window: macos.objc.id) WindowState {
        return .{
            .allocator = allocator,
            .window = window,
            .sidebars = std.StringHashMap(*NativeSidebar).init(allocator),
            .file_browsers = std.StringHashMap(*NativeFileBrowser).init(allocator),
            .split_views = std.StringHashMap(*NativeSplitView).init(allocator),
        };
    }

    fn deinit(self: *WindowState) void {
        if (self.space_switcher) |switcher| switcher.deinit();
        if (self.active_context_menu_delegate) |delegate| delegate.deinit();
        self.restoreOriginalContent();

        var split_iter = self.split_views.iterator();
        while (split_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.split_views.deinit();

        var sidebar_iter = self.sidebars.iterator();
        while (sidebar_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.sidebars.deinit();

        var browser_iter = self.file_browsers.iterator();
        while (browser_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.file_browsers.deinit();
    }

    fn restoreOriginalContent(self: *WindowState) void {
        const controller = self.split_view_controller orelse return;
        const original_webview = self.original_webview;
        // The content view controller is what keeps the displaced WKWebView
        // alive after it leaves NSWindow. Hold a temporary +1 across removing
        // and destroying that controller, then transfer it back to the window.
        // Without this handoff the pointer can be deallocated one statement
        // before `setContentView:` tries to reuse it.
        if (original_webview != null) _ = macos.msgSend0(original_webview, "retain");
        _ = macos.msgSend1(self.window, "setContentViewController:", @as(?*anyopaque, null));
        controller.deinit();
        self.split_view_controller = null;

        if (original_webview != null) {
            _ = macos.msgSend1(self.window, "setContentView:", original_webview);
            _ = macos.msgSend0(original_webview, "release");
        }
        self.original_webview = null;
    }

    fn destroySplitView(self: *WindowState, id: []const u8) bool {
        const entry = self.split_views.fetchRemove(id) orelse return false;
        self.allocator.free(entry.key);
        entry.value.deinit();
        return true;
    }

    fn destroySplitViewsUsingSidebar(self: *WindowState, sidebar: *NativeSidebar) void {
        while (true) {
            var matching_id: ?[]const u8 = null;
            var iter = self.split_views.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.*.usesSidebar(sidebar)) {
                    matching_id = entry.key_ptr.*;
                    break;
                }
            }
            if (matching_id) |id| {
                _ = self.destroySplitView(id);
            } else return;
        }
    }

    fn destroySplitViewsUsingFileBrowser(self: *WindowState, browser: *NativeFileBrowser) void {
        while (true) {
            var matching_id: ?[]const u8 = null;
            var iter = self.split_views.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.*.usesFileBrowser(browser)) {
                    matching_id = entry.key_ptr.*;
                    break;
                }
            }
            if (matching_id) |id| {
                _ = self.destroySplitView(id);
            } else return;
        }
    }
};

/// Bridge handler for native UI components
/// Routes messages from JavaScript to native AppKit components
pub const NativeUIBridge = struct {
    allocator: std.mem.Allocator,
    primary_window: macos.objc.id,
    window_states: std.AutoHashMap(usize, *WindowState),
    is_destroyed: bool,
    // QLPreviewPanel is process-global by AppKit design, so its controller is
    // deliberately app-scoped rather than pretending each window owns a panel.
    quick_look_controller: ?*quick_look.QuickLookController,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) NativeUIBridge {
        return .{
            .allocator = allocator,
            .primary_window = null,
            .window_states = std.AutoHashMap(usize, *WindowState).init(allocator),
            .is_destroyed = false,
            .quick_look_controller = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.is_destroyed = true;

        // Clean up Quick Look controller
        if (self.quick_look_controller) |controller| {
            controller.deinit();
            self.quick_look_controller = null;
        }

        var state_iter = self.window_states.valueIterator();
        while (state_iter.next()) |state| {
            state.*.deinit();
            self.allocator.destroy(state.*);
        }
        self.window_states.deinit();
        self.primary_window = null;

        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Bridge destroyed and all components cleaned up\n", .{});
    }

    pub fn setWindow(self: *Self, window: macos.objc.id) void {
        if (self.primary_window == null) self.primary_window = window;
    }

    fn currentWindow(self: *Self) macos.objc.id {
        if (window_context.current()) |handle| return @ptrFromInt(handle);
        return self.primary_window;
    }

    fn currentState(self: *Self) !*WindowState {
        const window = self.currentWindow() orelse return error.NoWindow;
        const key = @intFromPtr(window);
        if (self.window_states.get(key)) |state| return state;

        const state = try self.allocator.create(WindowState);
        errdefer self.allocator.destroy(state);
        state.* = WindowState.init(self.allocator, window);
        errdefer state.deinit();
        try self.window_states.put(key, state);
        return state;
    }

    /// Forget only the UI owned by a permanently destroyed window. Ordinary
    /// close/reopen intentionally keeps this state alive with the retained page.
    pub fn forgetWindow(self: *Self, window: macos.objc.id) void {
        if (window == null) return;
        if (self.window_states.fetchRemove(@intFromPtr(window))) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
    }

    /// Handle incoming messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        // Edge case: Bridge is destroyed
        if (self.is_destroyed) {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] WARNING: Message received after bridge destroyed. Ignoring.\n", .{});
            return;
        }

        // Edge case: Empty action
        if (action.len == 0) {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] WARNING: Empty action received. Ignoring.\n", .{});
            return;
        }

        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Action: {s}, Data length: {d}\n", .{ action, data.len });

        if (std.mem.eql(u8, action, "createSidebar")) {
            self.createSidebar(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR creating sidebar: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "createSpacesSidebar")) {
            self.createSpacesSidebar(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR creating spaces switcher: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "setSpaces")) {
            self.setSpaces(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR setting spaces: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "setActiveSpace")) {
            self.setActiveSpace(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR setting active space: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "addSidebarSection")) {
            self.addSidebarSection(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR adding sidebar section: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "setSelectedItem")) {
            self.setSelectedItem(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR setting selected item: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "createFileBrowser")) {
            self.createFileBrowser(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR creating file browser: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "addFile")) {
            self.addFile(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR adding file: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "addFiles")) {
            self.addFiles(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR adding files: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "clearFiles")) {
            self.clearFiles(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR clearing files: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "createSplitView")) {
            self.createSplitView(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR creating split view: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "destroyComponent")) {
            self.destroyComponent(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR destroying component: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "showContextMenu")) {
            self.showContextMenu(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR showing context menu: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "showQuickLook")) {
            self.showQuickLook(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR showing Quick Look: {any}\n", .{err});
            };
        } else if (std.mem.eql(u8, action, "closeQuickLook")) {
            self.closeQuickLook();
        } else if (std.mem.eql(u8, action, "toggleQuickLook")) {
            self.toggleQuickLook(data) catch |err| {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] ERROR toggling Quick Look: {any}\n", .{err});
            };
        } else {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] Unknown action: {s}\n", .{action});
        }
    }

    /// Parse a `spaces` array into the switcher's own shape.
    ///
    /// The returned slice borrows every string from `parsed`, so it must be
    /// consumed before the parse arena is freed — `SpaceList.append` copies.
    fn objectValue(value: std.json.Value) !std.json.ObjectMap {
        return switch (value) {
            .object => |object| object,
            else => error.InvalidFieldType,
        };
    }

    fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
        const value = object.get(name) orelse return error.MissingRequiredField;
        return switch (value) {
            .string => |string| string,
            else => error.InvalidFieldType,
        };
    }

    fn optionalString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
        const value = object.get(name) orelse return null;
        return switch (value) {
            .string => |string| string,
            .null => null,
            else => error.InvalidFieldType,
        };
    }

    fn parseSpaces(allocator: std.mem.Allocator, value: std.json.Value) !std.ArrayList(space_switcher.Space) {
        var spaces: std.ArrayList(space_switcher.Space) = .empty;
        errdefer spaces.deinit(allocator);

        const values = switch (value) {
            .array => |array| array.items,
            else => return error.InvalidFieldType,
        };
        for (values) |entry| {
            const obj = try objectValue(entry);
            const space_id = try requiredString(obj, "id");
            try spaces.append(allocator, .{
                .id = space_id,
                .label = try optionalString(obj, "label") orelse space_id,
                .icon = try optionalString(obj, "icon"),
                .tint = try optionalString(obj, "tint"),
            });
        }

        return spaces;
    }

    /// Create the native switcher for Arc-style sidebar spaces.
    ///
    /// Deliberately *not* a second `NativeSidebar`: the spaces and their rows
    /// stay in the webview, and this only puts a real control in the window
    /// chrome. That keeps it clear of the one-sidebar-per-window restriction in
    /// `createSidebar`, so a window can have both.
    fn createSpacesSidebar(self: *Self, data: []const u8) !void {
        if (data.len == 0) return error.EmptyData;
        const state = try self.currentState();

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return error.MalformedJSON;
        defer parsed.deinit();

        const root = try objectValue(parsed.value);
        const id_str = try requiredString(root, "id");

        var spaces = if (root.get("spaces")) |v|
            try parseSpaces(self.allocator, v)
        else
            std.ArrayList(space_switcher.Space).empty;
        defer spaces.deinit(self.allocator);

        const active = try optionalString(root, "activeSpace");

        // Build and attach the replacement before retiring the live control.
        // Allocation failure must leave the window's current switcher usable,
        // just like the registry-backed component creation paths below.
        const replacement = try space_switcher.create(
            self.allocator,
            state.window,
            if (window_context.currentWebView()) |webview| @ptrFromInt(webview) else macos.webViewForWindow(state.window) orelse null,
            id_str,
            spaces.items,
            active,
        );
        if (state.space_switcher) |previous| previous.deinit();
        state.space_switcher = replacement;

        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Spaces switcher '{s}' with {d} space(s)\n", .{ id_str, spaces.items.len });
    }

    fn setSpaces(self: *Self, data: []const u8) !void {
        if (data.len == 0) return error.EmptyData;
        const state = try self.currentState();

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return error.MalformedJSON;
        defer parsed.deinit();

        const root = try objectValue(parsed.value);
        const spaces_value = root.get("spaces") orelse return error.MissingRequiredField;
        var spaces = try parseSpaces(self.allocator, spaces_value);
        defer spaces.deinit(self.allocator);

        const switcher = state.space_switcher orelse return error.SpacesSidebarNotFound;
        try space_switcher.setSpaces(switcher, spaces.items);
    }

    fn setActiveSpace(self: *Self, data: []const u8) !void {
        if (data.len == 0) return error.EmptyData;
        const state = try self.currentState();

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return error.MalformedJSON;
        defer parsed.deinit();

        const root = try objectValue(parsed.value);
        const space_id = try requiredString(root, "spaceId");
        const switcher = state.space_switcher orelse return error.SpacesSidebarNotFound;
        space_switcher.setActiveSpace(switcher, space_id);
    }

    /// Create a new sidebar component using NSSplitViewController with native Liquid Glass
    fn createSidebar(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        // Edge case: Empty data
        if (data.len == 0) {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] ERROR: Empty data for createSidebar\n", .{});
            return error.EmptyData;
        }

        // Edge case: Missing window reference
        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Parsing JSON: {s}\n", .{data});

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch |err| {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] JSON parse error: {any}\n", .{err});
            return error.MalformedJSON;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const id = root.get("id") orelse {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] ERROR: Missing 'id' field in createSidebar data\n", .{});
            return error.MissingRequiredField;
        };
        const id_str = id.string;

        // Check if a sidebar already exists
        if (state.sidebars.count() > 0) {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] WARNING: Sidebar already exists. Only one sidebar is supported. Ignoring request for: {s}\n", .{id_str});
            return;
        }

        // Reserve the registry slot before creating AppKit state. From this
        // point on, every allocation is covered by an errdefer and the final
        // insertion cannot fail, so callers never inherit a half-created
        // sidebar or a dangling registry entry after an allocation failure.
        try state.sidebars.ensureUnusedCapacity(1);
        const id_copy = try self.allocator.dupe(u8, id_str);
        errdefer self.allocator.free(id_copy);

        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[LiquidGlass] Creating sidebar with NSSplitViewController: {s}\n", .{id_str});

        // Create sidebar
        const sidebar = try NativeSidebar.init(self.allocator);
        errdefer sidebar.deinit();

        if (root.get("sections")) |sections_value| {
            for (sections_value.array.items) |section_value| {
                const section_obj = section_value.object;
                const section_id = if (section_obj.get("id")) |v| v.string else "section";
                const section_label = if (section_obj.get("label")) |v| v.string else if (section_obj.get("title")) |v| v.string else section_id;
                const items_value = section_obj.get("items") orelse continue;

                var items: std.ArrayList(NativeSidebar.SidebarItem) = .empty;
                defer items.deinit(self.allocator);

                for (items_value.array.items) |item_value| {
                    const item_obj = item_value.object;
                    const item_id = if (item_obj.get("id")) |v| v.string else "item";
                    const item_label = if (item_obj.get("label")) |v| v.string else item_id;
                    try items.append(self.allocator, .{
                        .id = item_id,
                        .label = item_label,
                        .icon = if (item_obj.get("icon")) |icon| icon.string else null,
                        .badge = if (item_obj.get("badge")) |badge| switch (badge) {
                            .string => |s| s,
                            else => null,
                        } else null,
                    });
                }

                try sidebar.addSection(.{
                    .id = section_id,
                    .header = section_label,
                    .items = items.items,
                });
            }
        }

        // Add to the window that sent this bridge message.
        const window = state.window;
        {
            // Save the original webview (current content view)
            const original_webview = macos.msgSend0(window, "contentView");
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[LiquidGlass] Saved original webview: {*}\n", .{original_webview});

            // Create NSSplitViewController
            const split_vc = try NativeSplitViewController.init(self.allocator);
            errdefer split_vc.deinit();

            // CRITICAL: Add sidebar FIRST (AppKit applies Liquid Glass automatically)
            try split_vc.setSidebar(sidebar.getView());
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[LiquidGlass] Sidebar added with native Liquid Glass material\n", .{});

            // CRITICAL: Add content SECOND (extends full-width under sidebar)
            try split_vc.setContent(original_webview);
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[LiquidGlass] Content extends under floating sidebar\n", .{});

            // Set split view controller as window's content view controller
            _ = macos.msgSend1(window, "setContentViewController:", split_vc.getSplitViewController());
            state.original_webview = original_webview;
            state.split_view_controller = split_vc;
            state.sidebars.putAssumeCapacityNoClobber(id_copy, sidebar);
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[LiquidGlass] Set NSSplitViewController as window content view controller\n", .{});

            // Reposition the traffic lights to float over the sidebar.
            //
            // The height is read from the window rather than assumed. It used
            // to be written `const traffic_light_y: f64 = 787.0; // 800
            // (window height) - 13`, which is only right for a window that
            // happens to be 800pt tall; every other size put the buttons off
            // the intended row, and the further from 800 the worse.
            //
            // Whether any of this takes effect is a separate question, and the
            // answer on the titlebar-hidden path is no: rebuilding that one
            // with deliberately different constants produced pixel-identical
            // output, because AppKit re-lays out the standard buttons after
            // window configuration and overwrites a one-shot origin. That code
            // has been removed from `macos.zig`. This path is the native-sidebar
            // bridge and is not exercised by a plain titlebar-hidden window, so
            // it is corrected rather than deleted — if it is dead too, it is at
            // least no longer dead AND wrong.
            const window_frame = macos.msgSendRect(window, "frame");
            const traffic_light_y: f64 = window_frame.size.height - 13.0;

            const closeButton = macos.msgSend1(window, "standardWindowButton:", @as(c_ulong, 0));
            if (closeButton != null) {
                _ = macos.msgSend2(closeButton, "setFrameOrigin:", @as(f64, 13.0), traffic_light_y);
            }

            const miniButton = macos.msgSend1(window, "standardWindowButton:", @as(c_ulong, 1));
            if (miniButton != null) {
                _ = macos.msgSend2(miniButton, "setFrameOrigin:", @as(f64, 33.0), traffic_light_y);
            }

            const zoomButton = macos.msgSend1(window, "standardWindowButton:", @as(c_ulong, 2));
            if (zoomButton != null) {
                _ = macos.msgSend2(zoomButton, "setFrameOrigin:", @as(f64, 53.0), traffic_light_y);
            }

            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug")) {
                std.debug.print("[LiquidGlass] Repositioned traffic lights over sidebar at y={d}\n", .{traffic_light_y});
                std.debug.print("[LiquidGlass] Native Liquid Glass sidebar created successfully\n", .{});
            }
        }
    }

    /// Add a section to an existing sidebar
    fn addSidebarSection(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const sidebar_id = root.get("sidebarId").?.string;
        const section_data = root.get("section").?.object;

        // Get sidebar from registry
        const sidebar = state.sidebars.get(sidebar_id) orelse return error.SidebarNotFound;

        const section_id = section_data.get("id").?.string;
        const header = if (section_data.get("header")) |h| h.string else null;
        const items_json = section_data.get("items").?.array;

        // Build items array
        var items: std.ArrayList(NativeSidebar.SidebarItem) = .empty;
        defer items.deinit(self.allocator);

        for (items_json.items) |item_json| {
            const item_obj = item_json.object;
            try items.append(self.allocator, .{
                .id = item_obj.get("id").?.string,
                .label = item_obj.get("label").?.string,
                .icon = if (item_obj.get("icon")) |icon| icon.string else null,
                .badge = if (item_obj.get("badge")) |badge| badge.string else null,
            });
        }

        // Add section to sidebar
        try sidebar.addSection(.{
            .id = section_id,
            .header = header,
            .items = items.items,
        });

        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Added section '{s}' to sidebar '{s}'\n", .{ section_id, sidebar_id });
    }

    /// Set selected item in sidebar
    fn setSelectedItem(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const sidebar_id = root.get("sidebarId").?.string;
        const item_id = root.get("itemId").?.string;

        const sidebar = state.sidebars.get(sidebar_id) orelse return error.SidebarNotFound;
        sidebar.setSelectedItem(item_id);

        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Selected item '{s}' in sidebar '{s}'\n", .{ item_id, sidebar_id });
    }

    /// Create a new file browser component
    fn createFileBrowser(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const id = root.get("id").?.string;
        if (state.file_browsers.contains(id)) return error.ComponentAlreadyExists;
        try state.file_browsers.ensureUnusedCapacity(1);

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Creating file browser: {s}\n", .{id});

        // Create file browser
        const browser = try NativeFileBrowser.init(self.allocator);
        errdefer browser.deinit();

        // Add to the window that sent this bridge message.
        const window = state.window;
        {
            const content_view = macos.msgSend0(window, "contentView");
            const browser_view = browser.getView();

            // Get window frame
            const frame = macos.msgSend0(window, "frame");
            const frame_ptr: [*]const f64 = @ptrCast(@alignCast(&frame));
            const window_width = frame_ptr[2];
            const window_height = frame_ptr[3];

            browser.setFrame(240, 0, window_width - 240, window_height);
            browser.setAutoresizingMask(18); // Width + Height resizable

            _ = macos.msgSend1(content_view, "addSubview:", browser_view);
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] File browser added to window\n", .{});
        }

        state.file_browsers.putAssumeCapacityNoClobber(id_copy, browser);
    }

    /// Add a single file to file browser
    fn addFile(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const browser_id = root.get("browserId").?.string;
        const file_data = root.get("file").?.object;

        const browser = state.file_browsers.get(browser_id) orelse return error.BrowserNotFound;

        const file = NativeFileBrowser.FileItem{
            .id = file_data.get("id").?.string,
            .name = file_data.get("name").?.string,
            .icon = if (file_data.get("icon")) |icon| icon.string else null,
            .date_modified = if (file_data.get("dateModified")) |date| date.string else null,
            .size = if (file_data.get("size")) |size| size.string else null,
            .kind = if (file_data.get("kind")) |kind| kind.string else null,
        };

        try browser.addFile(file);
        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Added file '{s}' to browser '{s}'\n", .{ file.name, browser_id });
    }

    /// Add multiple files to file browser
    fn addFiles(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const browser_id = root.get("browserId").?.string;
        const files_json = root.get("files").?.array;

        const browser = state.file_browsers.get(browser_id) orelse return error.BrowserNotFound;

        var files: std.ArrayList(NativeFileBrowser.FileItem) = .empty;
        defer files.deinit(self.allocator);

        for (files_json.items) |file_json| {
            const file_obj = file_json.object;
            try files.append(self.allocator, .{
                .id = file_obj.get("id").?.string,
                .name = file_obj.get("name").?.string,
                .icon = if (file_obj.get("icon")) |icon| icon.string else null,
                .date_modified = if (file_obj.get("dateModified")) |date| date.string else null,
                .size = if (file_obj.get("size")) |size| size.string else null,
                .kind = if (file_obj.get("kind")) |kind| kind.string else null,
            });
        }

        try browser.addFiles(files.items);
        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Added {d} files to browser '{s}'\n", .{ files.items.len, browser_id });
    }

    /// Clear all files from file browser
    fn clearFiles(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const browser_id = root.get("browserId").?.string;

        const browser = state.file_browsers.get(browser_id) orelse return error.BrowserNotFound;
        browser.clearFiles();

        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Cleared files from browser '{s}'\n", .{browser_id});
    }

    /// Create a split view combining sidebar and file browser
    fn createSplitView(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const id = root.get("id").?.string;
        const sidebar_id = root.get("sidebarId").?.string;
        const browser_id = root.get("browserId").?.string;
        if (state.split_views.contains(id)) return error.ComponentAlreadyExists;
        try state.split_views.ensureUnusedCapacity(1);

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Creating split view: {s}\n", .{id});

        // Get sidebar and browser
        const sidebar = state.sidebars.get(sidebar_id) orelse return error.SidebarNotFound;
        const browser = state.file_browsers.get(browser_id) orelse return error.BrowserNotFound;

        // Create split view
        const split_view = try NativeSplitView.init(self.allocator, .{});
        errdefer split_view.deinit();

        // Add components to split view
        split_view.setSidebar(sidebar);
        split_view.setFileBrowser(browser);

        // Add to the window that sent this bridge message.
        const window = state.window;
        {
            const content_view = macos.msgSend0(window, "contentView");
            const split_view_obj = split_view.getView();

            // Get window frame
            const frame = macos.msgSend0(window, "frame");
            const frame_ptr: [*]const f64 = @ptrCast(@alignCast(&frame));
            const window_width = frame_ptr[2];
            const window_height = frame_ptr[3];

            split_view.setFrame(0, 0, window_width, window_height);
            split_view.setAutoresizingMask(18); // Width + Height resizable

            _ = macos.msgSend1(content_view, "addSubview:", split_view_obj);
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] Split view added to window\n", .{});
        }

        state.split_views.putAssumeCapacityNoClobber(id_copy, split_view);
    }

    /// Destroy a component
    fn destroyComponent(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const id = root.get("id").?.string;
        const component_type = root.get("type").?.string;

        if (std.mem.eql(u8, component_type, "sidebar")) {
            if (state.sidebars.get(id)) |sidebar| {
                state.destroySplitViewsUsingSidebar(sidebar);
                state.restoreOriginalContent();
            }
            if (state.sidebars.fetchRemove(id)) |entry| {
                self.allocator.free(entry.key);
                entry.value.deinit();
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] Destroyed sidebar '{s}'\n", .{id});
            }
        } else if (std.mem.eql(u8, component_type, "fileBrowser")) {
            if (state.file_browsers.get(id)) |browser| {
                state.destroySplitViewsUsingFileBrowser(browser);
            }
            if (state.file_browsers.fetchRemove(id)) |entry| {
                self.allocator.free(entry.key);
                entry.value.deinit();
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] Destroyed file browser '{s}'\n", .{id});
            }
        } else if (std.mem.eql(u8, component_type, "splitView")) {
            if (state.destroySplitView(id)) {
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] Destroyed split view '{s}'\n", .{id});
            }
        } else if (std.mem.eql(u8, component_type, "spacesSidebar")) {
            // Guarded by id: a second consumer tearing down its own switcher
            // must not remove the one that is currently installed.
            if (state.space_switcher) |switcher| {
                if (!space_switcher.isActive(switcher, id)) return;
                switcher.deinit();
                state.space_switcher = null;
                if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                    std.debug.print("[NativeUI] Destroyed spaces switcher '{s}'\n", .{id});
            }
        }
    }

    /// Show a context menu at a specific position
    /// Expected JSON format:
    /// {
    ///   "targetId": "item-id",
    ///   "targetType": "sidebar" | "file",
    ///   "x": 100,
    ///   "y": 200,
    ///   "items": [
    ///     { "id": "open", "title": "Open", "icon": "arrow.up.forward.square", "shortcut": "cmd+o" },
    ///     { "id": "separator", "title": "", "type": "separator" },
    ///     { "id": "delete", "title": "Move to Trash", "icon": "trash" }
    ///   ]
    /// }
    fn showContextMenu(self: *Self, data: []const u8) !void {
        const state = try self.currentState();
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const target_id = root.get("targetId").?.string;
        const target_type = root.get("targetType").?.string;

        // Get position
        const x = switch (root.get("x").?) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => 0.0,
        };
        const y = switch (root.get("y").?) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => 0.0,
        };

        // Parse menu items
        const items_json = root.get("items").?.array;
        var items: std.ArrayList(context_menu.MenuItem) = .empty;
        defer items.deinit(self.allocator);
        var owned_submenus: std.ArrayList([]const context_menu.MenuItem) = .empty;
        defer {
            for (owned_submenus.items) |submenu| self.allocator.free(submenu);
            owned_submenus.deinit(self.allocator);
        }

        for (items_json.items) |item_json| {
            const item_obj = item_json.object;
            const item_type_str = if (item_obj.get("type")) |t| t.string else "standard";

            const item_type: context_menu.MenuItemType = if (std.mem.eql(u8, item_type_str, "separator"))
                .separator
            else if (std.mem.eql(u8, item_type_str, "submenu"))
                .submenu
            else
                .standard;

            // Parse nested submenu items if present
            var submenu_items: ?[]const context_menu.MenuItem = null;
            if (item_type == .submenu) {
                if (item_obj.get("submenu")) |submenu_json| {
                    if (submenu_json == .array) {
                        var submenu_list: std.ArrayList(context_menu.MenuItem) = .empty;
                        defer submenu_list.deinit(self.allocator);
                        for (submenu_json.array.items) |sub_item_json| {
                            if (sub_item_json == .object) {
                                const sub_obj = sub_item_json.object;
                                const sub_type_str = if (sub_obj.get("type")) |t| t.string else "standard";
                                const sub_type: context_menu.MenuItemType = if (std.mem.eql(u8, sub_type_str, "separator"))
                                    .separator
                                else
                                    .standard;

                                try submenu_list.append(self.allocator, .{
                                    .id = if (sub_obj.get("id")) |id| id.string else "",
                                    .title = if (sub_obj.get("title")) |title| title.string else "",
                                    .icon = if (sub_obj.get("icon")) |icon| icon.string else null,
                                    .shortcut = if (sub_obj.get("shortcut")) |shortcut| shortcut.string else null,
                                    .enabled = if (sub_obj.get("enabled")) |enabled| enabled.bool else true,
                                    .item_type = sub_type,
                                    .submenu_items = null, // Only one level deep
                                });
                            }
                        }
                        if (submenu_list.items.len > 0) {
                            const owned = try submenu_list.toOwnedSlice(self.allocator);
                            errdefer self.allocator.free(owned);
                            try owned_submenus.append(self.allocator, owned);
                            submenu_items = owned;
                        }
                    }
                }
            }

            try items.append(self.allocator, .{
                .id = item_obj.get("id").?.string,
                .title = item_obj.get("title").?.string,
                .icon = if (item_obj.get("icon")) |icon| icon.string else null,
                .shortcut = if (item_obj.get("shortcut")) |shortcut| shortcut.string else null,
                .enabled = if (item_obj.get("enabled")) |enabled| enabled.bool else true,
                .item_type = item_type,
                .submenu_items = submenu_items,
            });
        }

        // Get the view to show the menu in
        var view: macos.objc.id = null;
        if (std.mem.eql(u8, target_type, "sidebar")) {
            // Use the sidebar's view
            var sidebar_iter = state.sidebars.valueIterator();
            if (sidebar_iter.next()) |sidebar| {
                view = sidebar.*.getView();
            }
        } else if (std.mem.eql(u8, target_type, "file")) {
            // Use the file browser's view
            var browser_iter = state.file_browsers.valueIterator();
            if (browser_iter.next()) |browser| {
                view = browser.*.getView();
            }
        }

        // Fallback to window's content view
        if (view == null) {
            view = macos.msgSend0(state.window, "contentView");
        }

        if (view == null) {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] ERROR: No view available for context menu\n", .{});
            return error.NoViewAvailable;
        }

        // Do not disturb the previous valid delegate until every fallible part
        // of the replacement is ready. The popup call below is synchronous, so
        // releasing the menu afterwards is safe while the delegate stays owned
        // by this window until its next menu or permanent teardown.
        const delegate = try context_menu.ContextMenuDelegate.init(self.allocator, target_id, target_type);
        errdefer delegate.deinit();
        const menu = try context_menu.createMenu(self.allocator, "", items.items, delegate);
        defer _ = macos.msgSend0(menu, "release");

        if (state.active_context_menu_delegate) |prev_delegate| prev_delegate.deinit();
        state.active_context_menu_delegate = delegate;

        // Show the menu
        context_menu.showContextMenu(menu, view, .{ .x = x, .y = y });
        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Showed context menu for {s} '{s}' at ({d}, {d})\n", .{ target_type, target_id, x, y });
    }

    /// Show Quick Look panel for files
    /// Expected JSON format:
    /// {
    ///   "files": [
    ///     { "id": "file-1", "path": "/path/to/file.pdf", "title": "Document.pdf" },
    ///     { "id": "file-2", "path": "/path/to/image.png" }
    ///   ],
    ///   "currentIndex": 0  // Optional, defaults to 0
    /// }
    fn showQuickLook(self: *Self, data: []const u8) !void {
        // Check if Quick Look is available
        if (!quick_look.isQuickLookAvailable()) {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] ERROR: Quick Look is not available on this system\n", .{});
            return error.QuickLookNotAvailable;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const files_json = root.get("files").?.array;

        // Create or reuse Quick Look controller
        if (self.quick_look_controller == null) {
            self.quick_look_controller = try quick_look.QuickLookController.init(self.allocator);
        }

        const controller = self.quick_look_controller.?;

        // Clear existing items and add new ones
        controller.callback_data.clearItems();

        for (files_json.items) |file_json| {
            const file_obj = file_json.object;
            const file_id = file_obj.get("id").?.string;
            const file_path = file_obj.get("path").?.string;
            const file_title = if (file_obj.get("title")) |t| t.string else null;

            try controller.addPreviewItem(.{
                .id = file_id,
                .path = file_path,
                .title = file_title,
            });
        }

        // Set current index if provided
        if (root.get("currentIndex")) |idx| {
            const index: usize = switch (idx) {
                .integer => |i| @intCast(i),
                else => 0,
            };
            controller.setCurrentPreviewIndex(index);
        }

        // Show the panel
        controller.showPanel();
        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Showed Quick Look with {d} files\n", .{files_json.items.len});
    }

    /// Close Quick Look panel
    fn closeQuickLook(self: *Self) void {
        if (self.quick_look_controller) |controller| {
            controller.closePanel();
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] Closed Quick Look panel\n", .{});
        }
    }

    /// Toggle Quick Look panel (show/hide)
    /// Expected JSON format: same as showQuickLook
    fn toggleQuickLook(self: *Self, data: []const u8) !void {
        // Check if Quick Look is available
        if (!quick_look.isQuickLookAvailable()) {
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[NativeUI] ERROR: Quick Look is not available on this system\n", .{});
            return error.QuickLookNotAvailable;
        }

        // If controller exists and panel is visible, close it
        if (self.quick_look_controller) |controller| {
            const QLPreviewPanel = macos.getClass("QLPreviewPanel");
            if (QLPreviewPanel != null) {
                const panel = macos.msgSend0(QLPreviewPanel, "sharedPreviewPanel");
                const isVisible = @as(
                    *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) bool,
                    @ptrCast(&macos.objc.objc_msgSend),
                );

                if (isVisible(panel, macos.sel("isVisible"))) {
                    controller.closePanel();
                    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                        std.debug.print("[NativeUI] Toggled Quick Look OFF\n", .{});
                    return;
                }
            }
        }

        // Otherwise, show the panel with provided data
        try self.showQuickLook(data);
        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[NativeUI] Toggled Quick Look ON\n", .{});
    }
};

test "native UI component registries are isolated by sending window" {
    var bridge = NativeUIBridge.init(std.testing.allocator);
    defer bridge.deinit();
    window_context.resetForTesting();
    defer window_context.resetForTesting();

    window_context.push(0x1000, 0x1001);
    const first = try bridge.currentState();
    window_context.pop();

    window_context.push(0x2000, 0x2001);
    const second = try bridge.currentState();
    window_context.pop();

    window_context.push(0x1000, 0x1001);
    defer window_context.pop();
    try std.testing.expectEqual(first, try bridge.currentState());
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), bridge.window_states.count());
}

test "forgetting a window preserves other native UI state" {
    var bridge = NativeUIBridge.init(std.testing.allocator);
    defer bridge.deinit();
    window_context.resetForTesting();
    defer window_context.resetForTesting();

    window_context.push(0x1000, 0x1001);
    _ = try bridge.currentState();
    window_context.pop();
    window_context.push(0x2000, 0x2001);
    const survivor = try bridge.currentState();
    window_context.pop();

    bridge.forgetWindow(@ptrFromInt(0x1000));
    try std.testing.expectEqual(@as(usize, 1), bridge.window_states.count());
    try std.testing.expectEqual(survivor, bridge.window_states.get(0x2000).?);
}

test "spaces parser rejects malformed shapes without unchecked union access" {
    const cases = [_][]const u8{
        "{}",
        "[1]",
        "[{\"id\":1}]",
        "[{\"id\":\"work\",\"label\":false}]",
        "[{\"id\":\"work\",\"icon\":[]}]",
    };

    for (cases) |source| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidFieldType,
            NativeUIBridge.parseSpaces(std.testing.allocator, parsed.value),
        );
    }
}

test "spaces parser preserves valid optional strings and nulls" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[{\"id\":\"work\",\"label\":\"Work\",\"icon\":null,\"tint\":\"#4488ff\"}]",
        .{},
    );
    defer parsed.deinit();

    var spaces = try NativeUIBridge.parseSpaces(std.testing.allocator, parsed.value);
    defer spaces.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), spaces.items.len);
    try std.testing.expectEqualStrings("work", spaces.items[0].id);
    try std.testing.expectEqualStrings("Work", spaces.items[0].label);
    try std.testing.expect(spaces.items[0].icon == null);
    try std.testing.expectEqualStrings("#4488ff", spaces.items[0].tint.?);
}
