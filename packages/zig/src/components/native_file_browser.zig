const std = @import("std");
const macos = @import("../macos.zig");
const TableViewDataSource = @import("table_view_datasource.zig").TableViewDataSource;
const TableViewDelegate = @import("table_view_delegate.zig").TableViewDelegate;
const keyboard_handler = @import("keyboard_handler.zig");

fn cloneFileItem(allocator: std.mem.Allocator, file: NativeFileBrowser.FileItem) !TableViewDataSource.DataStore.FileItem {
    const id = try allocator.dupe(u8, file.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, file.name);
    errdefer allocator.free(name);
    const icon = if (file.icon) |value| try allocator.dupe(u8, value) else null;
    errdefer if (icon) |value| allocator.free(value);
    const date_modified = if (file.date_modified) |value| try allocator.dupe(u8, value) else null;
    errdefer if (date_modified) |value| allocator.free(value);
    const size = if (file.size) |value| try allocator.dupe(u8, value) else null;
    errdefer if (size) |value| allocator.free(value);
    const kind = if (file.kind) |value| try allocator.dupe(u8, value) else null;

    return .{
        .id = id,
        .name = name,
        .icon = icon,
        .date_modified = date_modified,
        .size = size,
        .kind = kind,
    };
}

/// High-level wrapper for NSTableView-based file browser
/// Integrates data source and delegate into a complete multi-column table
pub const NativeFileBrowser = struct {
    table_view: macos.objc.id,
    scroll_view: macos.objc.id,
    data_source: TableViewDataSource,
    delegate: TableViewDelegate,
    allocator: std.mem.Allocator,

    pub const FileItem = struct {
        id: []const u8,
        name: []const u8,
        icon: ?[]const u8 = null,
        date_modified: ?[]const u8 = null,
        size: ?[]const u8 = null,
        kind: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) !*NativeFileBrowser {
        const self = try allocator.create(NativeFileBrowser);
        errdefer allocator.destroy(self);

        // Create data source and delegate
        var data_source = try TableViewDataSource.init(allocator);
        errdefer data_source.deinit();

        var delegate = try TableViewDelegate.init(allocator);
        errdefer delegate.deinit();

        // Create CraftTableView (custom subclass with keyboard handling)
        // Falls back to NSTableView if subclass creation fails
        const table_view = blk: {
            if (keyboard_handler.createCraftTableViewClass()) |CraftTableViewClass| {
                break :blk macos.msgSend0(macos.msgSend0(CraftTableViewClass, "alloc"), "init");
            } else |_| {
                const NSTableView = macos.getClass("NSTableView");
                break :blk macos.msgSend0(macos.msgSend0(NSTableView, "alloc"), "init");
            }
        };

        // Configure table view
        _ = macos.msgSend1(table_view, "setDataSource:", data_source.getInstance());
        _ = macos.msgSend1(table_view, "setDelegate:", delegate.getInstance());

        // Create columns
        const columns = [_]struct { id: []const u8, title: []const u8, width: f64 }{
            .{ .id = "name", .title = "Name", .width = 300.0 },
            .{ .id = "dateModified", .title = "Date Modified", .width = 180.0 },
            .{ .id = "size", .title = "Size", .width = 100.0 },
            .{ .id = "kind", .title = "Kind", .width = 120.0 },
        };

        const NSTableColumn = macos.getClass("NSTableColumn");
        for (columns) |col| {
            const column = macos.msgSend0(macos.msgSend0(NSTableColumn, "alloc"), "init");

            const identifier = macos.createNSString(col.id);
            _ = macos.msgSend1(column, "setIdentifier:", identifier);

            const title = macos.createNSString(col.title);
            const headerCell = macos.msgSend0(column, "headerCell");
            _ = macos.msgSend1(headerCell, "setStringValue:", title);

            _ = macos.msgSend1(column, "setWidth:", col.width);
            _ = macos.msgSend1(column, "setMinWidth:", @as(f64, 50.0));
            _ = macos.msgSend1(column, "setMaxWidth:", @as(f64, 1000.0));
            _ = macos.msgSend1(column, "setResizingMask:", @as(c_ulong, 1)); // NSTableColumnAutoresizingMask

            _ = macos.msgSend1(table_view, "addTableColumn:", column);
            _ = macos.msgSend0(column, "release");
        }

        // Configure appearance
        _ = macos.msgSend1(table_view, "setRowSizeStyle:", @as(c_long, 1)); // NSTableViewRowSizeStyleDefault
        _ = macos.msgSend1(table_view, "setSelectionHighlightStyle:", @as(c_long, 1)); // NSTableViewSelectionHighlightStyleRegular
        _ = macos.msgSend1(table_view, "setAllowsColumnResizing:", @as(c_int, 1));
        _ = macos.msgSend1(table_view, "setAllowsColumnReordering:", @as(c_int, 0));
        _ = macos.msgSend1(table_view, "setAllowsColumnSelection:", @as(c_int, 0));
        _ = macos.msgSend1(table_view, "setUsesAlternatingRowBackgroundColors:", @as(c_int, 0));

        // Enable grid lines
        _ = macos.msgSend1(table_view, "setGridStyleMask:", @as(c_ulong, 2)); // NSTableViewSolidHorizontalGridLineMask

        // Set grid color
        const NSColor = macos.getClass("NSColor");
        const gridColor = macos.msgSend0(NSColor, "separatorColor");
        _ = macos.msgSend1(table_view, "setGridColor:", gridColor);

        // Set background color
        const bgColor = macos.msgSend0(NSColor, "controlBackgroundColor");
        _ = macos.msgSend1(table_view, "setBackgroundColor:", bgColor);

        // Create NSScrollView to wrap the table view
        const NSScrollView = macos.getClass("NSScrollView");
        const scroll_view = macos.msgSend0(macos.msgSend0(NSScrollView, "alloc"), "init");

        _ = macos.msgSend1(scroll_view, "setDocumentView:", table_view);
        _ = macos.msgSend1(scroll_view, "setHasVerticalScroller:", @as(c_int, 1));
        _ = macos.msgSend1(scroll_view, "setHasHorizontalScroller:", @as(c_int, 1));
        _ = macos.msgSend1(scroll_view, "setBorderType:", @as(c_long, 0)); // NSNoBorder

        self.* = .{
            .table_view = table_view,
            .scroll_view = scroll_view,
            .data_source = data_source,
            .delegate = delegate,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *NativeFileBrowser) void {
        keyboard_handler.clearTableViewCallbacks(self.table_view);
        _ = macos.msgSend1(self.table_view, "setDelegate:", @as(?*anyopaque, null));
        _ = macos.msgSend1(self.table_view, "setDataSource:", @as(?*anyopaque, null));
        _ = macos.msgSend0(self.scroll_view, "removeFromSuperview");
        _ = macos.msgSend1(self.scroll_view, "setDocumentView:", @as(?*anyopaque, null));
        self.delegate.deinit();
        self.data_source.deinit();
        _ = macos.msgSend0(self.table_view, "release");
        _ = macos.msgSend0(self.scroll_view, "release");
        self.allocator.destroy(self);
    }

    /// Get the scroll view (top-level view to add to window)
    pub fn getView(self: *NativeFileBrowser) macos.objc.id {
        return self.scroll_view;
    }

    /// Add a single file to the browser
    pub fn addFile(self: *NativeFileBrowser, file: FileItem) !void {
        const new_file = try cloneFileItem(self.allocator, file);
        self.data_source.data.files.append(self.allocator, new_file) catch |err| {
            new_file.deinit(self.allocator);
            return err;
        };

        // Reload data
        _ = macos.msgSend0(self.table_view, "reloadData");
    }

    /// Add multiple files at once (more efficient)
    pub fn addFiles(self: *NativeFileBrowser, files: []const FileItem) !void {
        for (files) |file| {
            const new_file = try cloneFileItem(self.allocator, file);
            self.data_source.data.files.append(self.allocator, new_file) catch |err| {
                new_file.deinit(self.allocator);
                return err;
            };
        }

        // Reload data once after all files added
        _ = macos.msgSend0(self.table_view, "reloadData");
    }

    /// Clear all files from the browser
    pub fn clearFiles(self: *NativeFileBrowser) void {
        self.data_source.data.clear();

        // Reload data
        _ = macos.msgSend0(self.table_view, "reloadData");
    }

    /// Register callback for selection events
    pub fn setOnSelectCallback(self: *NativeFileBrowser, callback: *const fn (file_id: []const u8) void) void {
        self.delegate.setOnSelectCallback(callback);
    }

    /// Register callback for double-click events
    pub fn setOnDoubleClickCallback(self: *NativeFileBrowser, callback: *const fn (file_id: []const u8) void) void {
        self.delegate.setOnDoubleClickCallback(callback);

        // Set double action on table view
        // Note: This requires additional method implementation in delegate
        // For now, we'll use the selection callback
    }

    /// Register callback for spacebar key (Quick Look)
    pub fn setOnSpacebarCallback(self: *NativeFileBrowser, callback: *const fn () void) void {
        keyboard_handler.setTableViewSpacebarCallback(self.table_view, callback);
    }

    /// Register callback for return key (open file)
    pub fn setOnReturnCallback(self: *NativeFileBrowser, callback: *const fn () void) void {
        keyboard_handler.setTableViewReturnCallback(self.table_view, callback);
    }

    /// Set frame for the file browser view
    pub fn setFrame(self: *NativeFileBrowser, x: f64, y: f64, width: f64, height: f64) void {
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
    pub fn setAutoresizingMask(self: *NativeFileBrowser, mask: c_ulong) void {
        _ = macos.msgSend1(self.scroll_view, "setAutoresizingMask:", mask);
    }

    /// Get number of files currently in the browser
    pub fn getFileCount(self: *NativeFileBrowser) usize {
        return self.data_source.data.files.items.len;
    }
};
