const std = @import("std");
const macos = @import("../macos.zig");
const OutlineViewDataSource = @import("outline_view_datasource.zig").OutlineViewDataSource;
const OutlineViewDelegate = @import("outline_view_delegate.zig").OutlineViewDelegate;
const keyboard_handler = @import("keyboard_handler.zig");

/// NSInteger-returning messages, typed so the result is read as a signed long.
fn rowForItem(outline_view: macos.objc.id, item: macos.objc.id) c_long {
    const send: *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id) callconv(.c) c_long = @ptrCast(&macos.objc.objc_msgSend);
    return send(outline_view, macos.sel("rowForItem:"), item);
}

fn selectedRow(outline_view: macos.objc.id) c_long {
    const send: *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) c_long = @ptrCast(&macos.objc.objc_msgSend);
    return send(outline_view, macos.sel("selectedRow"));
}

fn cloneSidebarItem(allocator: std.mem.Allocator, item: NativeSidebar.SidebarItem) !OutlineViewDataSource.DataStore.Section.Item {
    const id = try allocator.dupe(u8, item.id);
    errdefer allocator.free(id);
    const label = try allocator.dupe(u8, item.label);
    errdefer allocator.free(label);
    const icon = if (item.icon) |value| try allocator.dupe(u8, value) else null;
    errdefer if (icon) |value| allocator.free(value);
    const badge = if (item.badge) |value| try allocator.dupe(u8, value) else null;

    return .{ .id = id, .label = label, .icon = icon, .badge = badge, .handle = OutlineViewDataSource.newHandle() };
}

fn initOwnedSection(allocator: std.mem.Allocator, section: NativeSidebar.SidebarSection) !OutlineViewDataSource.DataStore.Section {
    const id = try allocator.dupe(u8, section.id);
    errdefer allocator.free(id);
    const header = if (section.header) |value| try allocator.dupe(u8, value) else null;

    return .{ .id = id, .header = header, .items = .empty, .is_expanded = true, .handle = OutlineViewDataSource.newHandle() };
}

/// High-level wrapper for NSOutlineView-based sidebar
/// Integrates data source and delegate into a complete component
pub const NativeSidebar = struct {
    outline_view: macos.objc.id,
    scroll_view: macos.objc.id,
    data_source: OutlineViewDataSource,
    delegate: OutlineViewDelegate,
    allocator: std.mem.Allocator,
    /// The bridge's id for this sidebar, and the web view its selections are
    /// reported to (see `reportSelectionsTo`).
    id: []const u8 = "",
    webview: macos.objc.id = null,

    pub const SidebarSection = struct {
        id: []const u8,
        header: ?[]const u8,
        items: []const SidebarItem,
    };

    pub const SidebarItem = struct {
        id: []const u8,
        label: []const u8,
        icon: ?[]const u8 = null,
        badge: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) !*NativeSidebar {
        const self = try allocator.create(NativeSidebar);
        errdefer allocator.destroy(self);

        // Create data source and delegate
        var data_source = try OutlineViewDataSource.init(allocator);
        errdefer data_source.deinit();

        var delegate = try OutlineViewDelegate.init(allocator);
        errdefer delegate.deinit();

        // Create CraftOutlineView (custom subclass with keyboard handling)
        // Falls back to NSOutlineView if subclass creation fails
        const outline_view = blk: {
            if (keyboard_handler.createCraftOutlineViewClass()) |CraftOutlineViewClass| {
                break :blk macos.msgSend0(macos.msgSend0(CraftOutlineViewClass, "alloc"), "init");
            } else |_| {
                const NSOutlineView = macos.getClass("NSOutlineView");
                break :blk macos.msgSend0(macos.msgSend0(NSOutlineView, "alloc"), "init");
            }
        };

        // Configure outline view for SOURCE LIST style (native sidebar)
        _ = macos.msgSend1(outline_view, "setDataSource:", data_source.getInstance());
        _ = macos.msgSend1(outline_view, "setDelegate:", delegate.getInstance());

        // Add single column for the outline view
        const NSTableColumn = macos.getClass("NSTableColumn");
        const column = macos.msgSend0(macos.msgSend0(NSTableColumn, "alloc"), "init");

        const identifier = macos.createNSString("MainColumn");
        _ = macos.msgSend1(column, "setIdentifier:", identifier);
        _ = macos.msgSend1(column, "setWidth:", @as(f64, 240.0));
        _ = macos.msgSend1(outline_view, "addTableColumn:", column);
        _ = macos.msgSend1(outline_view, "setOutlineTableColumn:", column);
        _ = macos.msgSend0(column, "release");

        // CRITICAL: Enable native source list style
        _ = macos.msgSend1(outline_view, "setSelectionHighlightStyle:", @as(c_long, 1)); // NSTableViewSelectionHighlightStyleSourceList

        // CRITICAL: Make outline view transparent for Liquid Glass effect
        const NSColor = macos.getClass("NSColor");
        const clearColor = macos.msgSend0(NSColor, "clearColor");
        _ = macos.msgSend1(outline_view, "setBackgroundColor:", clearColor);

        // Remove header
        _ = macos.msgSend1(outline_view, "setHeaderView:", @as(?*anyopaque, null));

        // Enable group rows for section headers
        _ = macos.msgSend1(outline_view, "setFloatsGroupRows:", @as(c_int, 1)); // YES - float group rows

        // Use default row sizing
        _ = macos.msgSend1(outline_view, "setRowSizeStyle:", @as(c_long, 2)); // NSTableViewRowSizeStyleMedium

        // Enable autosave to remember expanded state
        const autosaveName = macos.createNSString("CraftSidebarOutlineView");
        _ = macos.msgSend1(outline_view, "setAutosaveName:", autosaveName);
        _ = macos.msgSend1(outline_view, "setAutosaveExpandedItems:", @as(c_int, 1));

        // Create NSScrollView to wrap the outline view
        const NSScrollView = macos.getClass("NSScrollView");
        const scroll_view = macos.msgSend0(macos.msgSend0(NSScrollView, "alloc"), "init");

        // CRITICAL: Set initial frame - NSScrollView needs a frame to have non-zero size
        // NSSplitViewController will resize this based on min/max thickness settings
        const NSRect = extern struct {
            origin: extern struct { x: f64, y: f64 },
            size: extern struct { width: f64, height: f64 },
        };
        const initial_frame = NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 240.0, .height = 100.0 }, // Initial size, will be resized by split view
        };
        _ = macos.msgSend1(scroll_view, "setFrame:", initial_frame);

        // CRITICAL: Enable layer backing for proper rendering
        _ = macos.msgSend1(scroll_view, "setWantsLayer:", @as(c_int, 1)); // YES

        // CRITICAL: Keep autoresizing mask enabled (default) - NSSplitViewController needs this
        // The min/max thickness settings on NSSplitViewItem work with autoresizing masks
        const NSViewWidthSizable: c_ulong = 2; // 1 << 1
        const NSViewHeightSizable: c_ulong = 16; // 1 << 4
        _ = macos.msgSend1(scroll_view, "setAutoresizingMask:", NSViewWidthSizable | NSViewHeightSizable);

        _ = macos.msgSend1(scroll_view, "setDocumentView:", outline_view);
        _ = macos.msgSend1(scroll_view, "setHasVerticalScroller:", @as(c_int, 1));
        _ = macos.msgSend1(scroll_view, "setHasHorizontalScroller:", @as(c_int, 0));
        _ = macos.msgSend1(scroll_view, "setBorderType:", @as(c_long, 0)); // NSNoBorder

        // CRITICAL: Make scroll view transparent so NSVisualEffectView glass shows through
        _ = macos.msgSend1(scroll_view, "setDrawsBackground:", @as(c_int, 0)); // NO - don't draw background

        // Get NSColor to set transparent backgrounds
        const NSColorClass = macos.getClass("NSColor");
        const clearColorObj = macos.msgSend0(NSColorClass, "clearColor");
        _ = macos.msgSend1(scroll_view, "setBackgroundColor:", clearColorObj);

        std.debug.print("[NativeSidebar] ✓ Scroll view created with initial frame (240x100)\\n", .{});

        self.* = .{
            .outline_view = outline_view,
            .scroll_view = scroll_view,
            .data_source = data_source,
            .delegate = delegate,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *NativeSidebar) void {
        if (self.id.len > 0) self.allocator.free(self.id);
        keyboard_handler.clearOutlineViewCallbacks(self.outline_view);
        _ = macos.msgSend1(self.outline_view, "setDelegate:", @as(?*anyopaque, null));
        _ = macos.msgSend1(self.outline_view, "setDataSource:", @as(?*anyopaque, null));
        _ = macos.msgSend0(self.scroll_view, "removeFromSuperview");
        _ = macos.msgSend1(self.scroll_view, "setDocumentView:", @as(?*anyopaque, null));
        self.delegate.deinit();
        self.data_source.deinit();
        _ = macos.msgSend0(self.outline_view, "release");
        _ = macos.msgSend0(self.scroll_view, "release");
        self.allocator.destroy(self);
    }

    /// Get the scroll view (top-level view to add to window)
    pub fn getView(self: *NativeSidebar) macos.objc.id {
        return self.scroll_view;
    }

    /// Add a section to the sidebar
    pub fn addSection(self: *NativeSidebar, section: SidebarSection) !void {
        var new_section = try initOwnedSection(self.allocator, section);
        errdefer new_section.deinit(self.allocator);

        // Add items to section
        for (section.items) |item| {
            const new_item = try cloneSidebarItem(self.allocator, item);
            new_section.items.append(self.allocator, new_item) catch |err| {
                new_item.deinit(self.allocator);
                return err;
            };
        }

        const section_index = self.data_source.data.sections.items.len;
        try self.data_source.data.sections.append(self.allocator, new_section);

        std.debug.print("[NativeSidebar-DEBUG] Section added to data. Total sections: {d}\n", .{self.data_source.data.sections.items.len});
        std.debug.print("[NativeSidebar-DEBUG] Section '{s}' has {d} items\n", .{ section.id, new_section.items.items.len });

        // Reload data to show the new section
        _ = macos.msgSend0(self.outline_view, "reloadData");
        std.debug.print("[NativeSidebar-DEBUG] Called reloadData on outline view\n", .{});

        // Get the number of rows to verify data loaded
        const row_count = macos.msgSend0(self.outline_view, "numberOfRows");
        std.debug.print("[NativeSidebar-DEBUG] Outline view now has {*} rows\n", .{row_count});

        // Auto-expand the newly added section
        // Get the item at row index (which corresponds to the section we just added)
        const section_row_idx: c_long = @intCast(section_index);
        const section_item = macos.msgSend1(self.outline_view, "itemAtRow:", section_row_idx);
        if (section_item != @as(macos.objc.id, null)) {
            _ = macos.msgSend1(self.outline_view, "expandItem:", section_item);
            std.debug.print("[NativeSidebar-DEBUG] Expanded section at row {d}\n", .{section_row_idx});
        }
    }

    /// Select an item by id, without reporting it as a selection the
    /// person made. Found by its row object, so collapsed sections and
    /// changed contents do not shift it onto the wrong row.
    pub fn setSelectedItem(self: *NativeSidebar, item_id: []const u8) void {
        const item = self.data_source.data.findItem(item_id) orelse return;
        const row = rowForItem(self.outline_view, item.handle);
        if (row < 0) return;
        const NSIndexSet = macos.getClass("NSIndexSet");
        const index_set = macos.msgSend1(NSIndexSet, "indexSetWithIndex:", @as(c_ulong, @intCast(row)));
        self.delegate.setSuppressSelect(true);
        defer self.delegate.setSuppressSelect(false);
        _ = macos.msgSend2(self.outline_view, "selectRowIndexes:byExtendingSelection:", index_set, @as(c_int, 0));
        _ = macos.msgSend1(self.outline_view, "scrollRowToVisible:", row);
    }

    /// The selected item's id, if an item (not a header) is selected.
    pub fn selectedItemId(self: *NativeSidebar) ?[]const u8 {
        const row = selectedRow(self.outline_view);
        if (row < 0) return null;
        const handle = macos.msgSend1(self.outline_view, "itemAtRow:", row);
        const location = self.data_source.data.locate(handle) orelse return null;
        const item = self.data_source.data.itemAt(location) orelse return null;
        return item.id;
    }

    /// Replace every section at once - what a live sidebar does as its
    /// counts and sources change. The selection is kept by id when the item
    /// is still there.
    pub fn setSections(self: *NativeSidebar, sections: []const SidebarSection) !void {
        var keep: ?[]u8 = null;
        if (self.selectedItemId()) |current| keep = try self.allocator.dupe(u8, current);
        defer if (keep) |value| self.allocator.free(value);

        var fresh: std.ArrayList(OutlineViewDataSource.DataStore.Section) = .empty;
        errdefer {
            for (fresh.items) |*section| section.deinit(self.allocator);
            fresh.deinit(self.allocator);
        }
        for (sections) |section| {
            var owned = try initOwnedSection(self.allocator, section);
            errdefer owned.deinit(self.allocator);
            for (section.items) |item| {
                const new_item = try cloneSidebarItem(self.allocator, item);
                owned.items.append(self.allocator, new_item) catch |err| {
                    new_item.deinit(self.allocator);
                    return err;
                };
            }
            try fresh.append(self.allocator, owned);
        }

        // Swap only once everything is built, so a failure leaves the sidebar as it was.
        self.delegate.setSuppressSelect(true);
        defer self.delegate.setSuppressSelect(false);
        self.data_source.data.clear();
        self.data_source.data.sections.deinit(self.allocator);
        self.data_source.data.sections = fresh;
        fresh = .empty;
        _ = macos.msgSend0(self.outline_view, "reloadData");
        for (self.data_source.data.sections.items) |*section|
            _ = macos.msgSend1(self.outline_view, "expandItem:", section.handle);
        if (keep) |id| self.setSelectedItem(id);
    }

    /// Change one item's label, icon or badge in place (null leaves a field
    /// as it is; an empty badge clears it), redrawing only that row.
    pub fn updateItem(self: *NativeSidebar, item_id: []const u8, label: ?[]const u8, icon: ?[]const u8, badge: ?[]const u8) !void {
        const item = self.data_source.data.findItem(item_id) orelse return error.ItemNotFound;
        if (label) |value| {
            const copy = try self.allocator.dupe(u8, value);
            self.allocator.free(item.label);
            item.label = copy;
        }
        if (icon) |value| {
            const copy = try self.allocator.dupe(u8, value);
            if (item.icon) |old| self.allocator.free(old);
            item.icon = copy;
        }
        if (badge) |value| {
            const copy: ?[]const u8 = if (value.len == 0) null else try self.allocator.dupe(u8, value);
            if (item.badge) |old| self.allocator.free(old);
            item.badge = copy;
        }
        _ = macos.msgSend1(self.outline_view, "reloadItem:", item.handle);
    }

    /// Report every selection the person makes to `webview` as
    /// `craft.nativeUI._emitSidebarSelect(<id>, <itemId>)`.
    pub fn reportSelectionsTo(self: *NativeSidebar, id: []const u8, webview: macos.objc.id) !void {
        if (self.id.len > 0) self.allocator.free(self.id);
        self.id = try self.allocator.dupe(u8, id);
        self.webview = webview;
        self.delegate.setOnSelectCallback(@ptrCast(self), emitSelect);
    }

    fn emitSelect(context: ?*anyopaque, item_id: []const u8) void {
        const self: *NativeSidebar = @ptrCast(@alignCast(context orelse return));
        if (self.webview == null) return;
        var id_buf: [128]u8 = undefined;
        var item_buf: [128]u8 = undefined;
        var js_buf: [512]u8 = undefined;
        const sanitize = @import("native_space_switcher.zig").sanitizeId;
        // Guarded like _emitSpaceChange: an event racing a navigation is a no-op.
        const js = std.fmt.bufPrint(
            &js_buf,
            "window.craft&&window.craft.nativeUI&&window.craft.nativeUI._emitSidebarSelect&&window.craft.nativeUI._emitSidebarSelect(\"{s}\",\"{s}\")",
            .{ sanitize(&id_buf, self.id), sanitize(&item_buf, item_id) },
        ) catch return;
        macos.tryEvalJSInWebView(self.webview, js) catch {};
    }

    /// Register callback for selection events (receives the item's id).
    pub fn setOnSelectCallback(self: *NativeSidebar, context: ?*anyopaque, callback: *const fn (context: ?*anyopaque, item_id: []const u8) void) void {
        self.delegate.setOnSelectCallback(context, callback);
    }

    /// Register callback for spacebar key (Quick Look)
    pub fn setOnSpacebarCallback(self: *NativeSidebar, callback: *const fn () void) void {
        keyboard_handler.setOutlineViewSpacebarCallback(self.outline_view, callback);
    }

    /// Register callback for return key
    pub fn setOnReturnCallback(self: *NativeSidebar, callback: *const fn () void) void {
        keyboard_handler.setOutlineViewReturnCallback(self.outline_view, callback);
    }

    /// Set frame for the sidebar view
    pub fn setFrame(self: *NativeSidebar, x: f64, y: f64, width: f64, height: f64) void {
        const NSRect = extern struct {
            origin: extern struct { x: f64, y: f64 },
            size: extern struct { width: f64, height: f64 },
        };

        const frame = NSRect{
            .origin = .{ .x = x, .y = y },
            .size = .{ .width = width, .height = height },
        };

        _ = macos.msgSend1(self.scroll_view, "setFrame:", frame);
    }

    /// Set Auto Layout constraints (alternative to setFrame)
    pub fn setAutoresizingMask(self: *NativeSidebar, mask: c_ulong) void {
        _ = macos.msgSend1(self.scroll_view, "setAutoresizingMask:", mask);
    }
};
