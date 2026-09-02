const std = @import("std");
const macos = @import("../macos.zig");
const OutlineViewDataSource = @import("outline_view_datasource.zig").OutlineViewDataSource;
const OutlineViewDelegate = @import("outline_view_delegate.zig").OutlineViewDelegate;
const keyboard_handler = @import("keyboard_handler.zig");

/// High-level wrapper for NSOutlineView-based sidebar
/// Integrates data source and delegate into a complete component
pub const NativeSidebar = struct {
    outline_view: macos.objc.id,
    scroll_view: macos.objc.id,
    data_source: OutlineViewDataSource,
    delegate: OutlineViewDelegate,
    allocator: std.mem.Allocator,

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
        self.delegate.deinit();
        self.data_source.deinit();
        self.allocator.destroy(self);
    }

    /// Get the scroll view (top-level view to add to window)
    pub fn getView(self: *NativeSidebar) macos.objc.id {
        return self.scroll_view;
    }

    /// Add a section to the sidebar
    pub fn addSection(self: *NativeSidebar, section: SidebarSection) !void {
        var new_section = OutlineViewDataSource.DataStore.Section{
            .id = try self.allocator.dupe(u8, section.id),
            .header = if (section.header) |h| try self.allocator.dupe(u8, h) else null,
            .items = .empty,
            .is_expanded = true,
        };

        // Add items to section
        for (section.items) |item| {
            const new_item = OutlineViewDataSource.DataStore.Section.Item{
                .id = try self.allocator.dupe(u8, item.id),
                .label = try self.allocator.dupe(u8, item.label),
                .icon = if (item.icon) |icon| try self.allocator.dupe(u8, icon) else null,
                .badge = if (item.badge) |badge| try self.allocator.dupe(u8, badge) else null,
            };
            try new_section.items.append(self.allocator, new_item);
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

    /// Set the selected item programmatically
    pub fn setSelectedItem(self: *NativeSidebar, item_id: []const u8) void {
        // Find the item in the data structure
        var row_index: c_long = 0;

        for (self.data_source.data.sections.items) |*section| {
            row_index += 1; // Section itself takes a row

            for (section.items.items) |*item| {
                if (std.mem.eql(u8, item.id, item_id)) {
                    // Create NSIndexSet for the row
                    const NSIndexSet = macos.getClass("NSIndexSet");
                    const index_set = macos.msgSend1(NSIndexSet, "indexSetWithIndex:", @as(c_ulong, @intCast(row_index)));

                    // Select this row (NO = don't extend selection)
                    _ = macos.msgSend2(self.outline_view, "selectRowIndexes:byExtendingSelection:", index_set, @as(c_int, 0));
                    return;
                }
                row_index += 1;
            }
        }
    }

    /// Register callback for selection events
    pub fn setOnSelectCallback(self: *NativeSidebar, callback: *const fn (item_id: []const u8) void) void {
        self.delegate.setOnSelectCallback(callback);
    }

    /// Register callback for spacebar key (Quick Look)
    pub fn setOnSpacebarCallback(_: *NativeSidebar, callback: *const fn () void) void {
        keyboard_handler.setOutlineViewSpacebarCallback(callback);
    }

    /// Register callback for return key
    pub fn setOnReturnCallback(_: *NativeSidebar, callback: *const fn () void) void {
        keyboard_handler.setOutlineViewReturnCallback(callback);
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
