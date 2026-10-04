const std = @import("std");
const macos = @import("../macos.zig");
const sf_symbols = @import("../macos/sf_symbols.zig");

/// NSTableViewDelegate implementation in Zig
/// Handles cell views, selection, and double-click events
pub const TableViewDelegate = struct {
    objc_class: macos.objc.Class,
    instance: macos.objc.id,
    callback_data: *CallbackData,
    allocator: std.mem.Allocator,

    pub const CallbackData = struct {
        on_select: ?*const fn (file_id: []const u8) void = null,
        on_double_click: ?*const fn (file_id: []const u8) void = null,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) CallbackData {
            return .{ .allocator = allocator };
        }
    };

    pub fn init(allocator: std.mem.Allocator) !TableViewDelegate {
        const callback_data = try allocator.create(CallbackData);
        callback_data.* = CallbackData.init(allocator);

        const NSObject = macos.getClass("NSObject");
        const class_name = "CraftTableViewDelegate";

        var objc_class = macos.objc.objc_getClass(class_name);
        if (objc_class == null) {
            objc_class = macos.objc.objc_allocateClassPair(NSObject, class_name, 0);

            // Add tableView:viewForTableColumn:row:
            const viewForTableColumnRow = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id, c_long) callconv(.c) macos.objc.id,
                @ptrCast(@constCast(&tableViewViewForTableColumnRow)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("tableView:viewForTableColumn:row:"),
                @ptrCast(@constCast(viewForTableColumnRow)),
                "@@:@@l",
            );

            // Add tableView:shouldSelectRow:
            const shouldSelectRow = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, c_long) callconv(.c) c_int,
                @ptrCast(@constCast(&tableViewShouldSelectRow)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("tableView:shouldSelectRow:"),
                @ptrCast(@constCast(shouldSelectRow)),
                "c@:@l",
            );

            // Add tableViewSelectionDidChange:
            const selectionDidChange = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id) callconv(.c) void,
                @ptrCast(@constCast(&tableViewSelectionDidChange)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("tableViewSelectionDidChange:"),
                @ptrCast(@constCast(selectionDidChange)),
                "v@:@",
            );

            // Add tableView:heightOfRow:
            const heightOfRow = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, c_long) callconv(.c) f64,
                @ptrCast(@constCast(&tableViewHeightOfRow)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("tableView:heightOfRow:"),
                @ptrCast(@constCast(heightOfRow)),
                "d@:@l",
            );

            macos.objc.objc_registerClassPair(objc_class);
        }

        const instance = macos.msgSend0(macos.msgSend0(objc_class.?, "alloc"), "init");

        // Store callback data pointer
        const data_ptr_value = @intFromPtr(callback_data);
        const NSValue = macos.getClass("NSValue");
        const data_value = macos.msgSend1(
            NSValue,
            "valueWithPointer:",
            @as(?*anyopaque, @ptrFromInt(data_ptr_value)),
        );
        macos.objc.objc_setAssociatedObject(
            instance,
            @ptrFromInt(0x6789), // unique key
            data_value,
            macos.objc.OBJC_ASSOCIATION_RETAIN,
        );

        return .{
            .objc_class = objc_class.?,
            .instance = instance,
            .callback_data = callback_data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TableViewDelegate) void {
        // Release the Objective-C instance
        if (self.instance != @as(macos.objc.id, null)) {
            _ = macos.msgSend0(self.instance, "release");
        }
        self.allocator.destroy(self.callback_data);
    }

    pub fn getInstance(self: *TableViewDelegate) macos.objc.id {
        return self.instance;
    }

    pub fn setOnSelectCallback(self: *TableViewDelegate, callback: *const fn (file_id: []const u8) void) void {
        self.callback_data.on_select = callback;
    }

    pub fn setOnDoubleClickCallback(self: *TableViewDelegate, callback: *const fn (file_id: []const u8) void) void {
        self.callback_data.on_double_click = callback;
    }
};

fn getCallbackData(instance: macos.objc.id) ?*TableViewDelegate.CallbackData {
    const associated = macos.objc.objc_getAssociatedObject(instance, @ptrFromInt(0x6789));
    if (associated == @as(macos.objc.id, null)) return null;

    const ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(ptr) == 0) return null;

    return @ptrCast(@alignCast(ptr));
}

/// Helper to get icon name for file from data source
fn getFileIcon(tableView: macos.objc.id, row: c_long) ?[]const u8 {
    const dataSource = macos.msgSend0(tableView, "dataSource");
    if (dataSource == @as(macos.objc.id, null)) return null;

    // Get associated data
    const associated = macos.objc.objc_getAssociatedObject(dataSource, @ptrFromInt(0x5678));
    if (associated == @as(macos.objc.id, null)) return null;

    const ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(ptr) == 0) return null;

    const DataStore = @import("table_view_datasource.zig").TableViewDataSource.DataStore;
    const data: *DataStore = @ptrFromInt(@intFromPtr(ptr));

    const idx: usize = @intCast(row);
    if (idx >= data.files.items.len) return null;

    return data.files.items[idx].icon;
}

/// Create a cell view with icon and text for name column
fn createNameCellView(text: []const u8, icon_name: ?[]const u8) macos.objc.id {
    const NSTableCellView = macos.getClass("NSTableCellView");
    const cellView = macos.msgSend0(macos.msgSend0(NSTableCellView, "alloc"), "init");

    const NSRect = extern struct {
        origin: extern struct { x: f64, y: f64 },
        size: extern struct { width: f64, height: f64 },
    };

    const row_height: f64 = 22.0;
    const icon_size: f64 = 16.0;
    const icon_padding: f64 = 4.0;

    // Create image view for icon
    const NSImageView = macos.getClass("NSImageView");
    const imageView = macos.msgSend0(macos.msgSend0(NSImageView, "alloc"), "init");

    const icon_frame = NSRect{
        .origin = .{ .x = 4, .y = (row_height - icon_size) / 2.0 },
        .size = .{ .width = icon_size, .height = icon_size },
    };
    _ = macos.msgSend1(imageView, "setFrame:", icon_frame);
    _ = macos.msgSend1(imageView, "setImageScaling:", @as(c_long, 2)); // NSImageScaleProportionallyUpOrDown

    // Set icon image
    // The buffer lives at function scope: `symbol_name` points into it and is
    // read below, after an `if` block that owned it would already have ended.
    var icon_buf: [64]u8 = undefined;
    var symbol_name: [*:0]const u8 = "doc";
    if (icon_name) |icon| {
        symbol_name = @import("../memory.zig").bufPrintZ(&icon_buf, "{s}", .{icon}) catch "doc";
    }

    const symbol_config = sf_symbols.SymbolConfiguration{
        .point_size = 14.0,
        .weight = .regular,
        .scale = .medium,
    };
    if (sf_symbols.createSFSymbol(symbol_name, symbol_config)) |image| {
        _ = macos.msgSend1(imageView, "setImage:", image);
        _ = macos.msgSend1(image, "setTemplate:", @as(c_int, 1));
    }

    _ = macos.msgSend1(cellView, "setImageView:", imageView);
    _ = macos.msgSend1(cellView, "addSubview:", imageView);

    // Create text field
    const NSTextField = macos.getClass("NSTextField");
    const textField = macos.msgSend0(macos.msgSend0(NSTextField, "alloc"), "init");

    const nsString = macos.createNSString(text);
    _ = macos.msgSend1(textField, "setStringValue:", nsString);

    _ = macos.msgSend1(textField, "setBordered:", @as(c_int, 0));
    _ = macos.msgSend1(textField, "setDrawsBackground:", @as(c_int, 0));
    _ = macos.msgSend1(textField, "setEditable:", @as(c_int, 0));
    _ = macos.msgSend1(textField, "setSelectable:", @as(c_int, 0));

    const NSFont = macos.getClass("NSFont");
    const font = macos.msgSend1(NSFont, "systemFontOfSize:", @as(f64, 13.0));
    _ = macos.msgSend1(textField, "setFont:", font);

    const text_frame = NSRect{
        .origin = .{ .x = icon_size + icon_padding + 4.0, .y = 0 },
        .size = .{ .width = 260, .height = row_height },
    };
    _ = macos.msgSend1(textField, "setFrame:", text_frame);
    _ = macos.msgSend1(textField, "setAutoresizingMask:", @as(c_ulong, 2)); // NSViewWidthSizable

    _ = macos.msgSend1(cellView, "setTextField:", textField);
    _ = macos.msgSend1(cellView, "addSubview:", textField);

    return cellView;
}

/// Create a text field cell view for table columns
fn createTableCellView(text: []const u8, column_id: []const u8) macos.objc.id {
    const NSTextField = macos.getClass("NSTextField");
    const textField = macos.msgSend0(macos.msgSend0(NSTextField, "alloc"), "init");

    // Set text
    const nsString = macos.createNSString(text);
    _ = macos.msgSend1(textField, "setStringValue:", nsString);

    // Configure appearance
    _ = macos.msgSend1(textField, "setBordered:", @as(c_int, 0));
    _ = macos.msgSend1(textField, "setDrawsBackground:", @as(c_int, 0));
    _ = macos.msgSend1(textField, "setEditable:", @as(c_int, 0));
    _ = macos.msgSend1(textField, "setSelectable:", @as(c_int, 0));

    // Set font based on column type
    const NSFont = macos.getClass("NSFont");
    if (std.mem.eql(u8, column_id, "name")) {
        // Name column uses standard font at 13pt
        const font = macos.msgSend1(NSFont, "systemFontOfSize:", @as(f64, 13.0));
        _ = macos.msgSend1(textField, "setFont:", font);
    } else {
        // Other columns use smaller, secondary font at 12pt
        const font = macos.msgSend1(NSFont, "systemFontOfSize:", @as(f64, 12.0));
        _ = macos.msgSend1(textField, "setFont:", font);

        // Set secondary text color
        const NSColor = macos.getClass("NSColor");
        const secondaryColor = macos.msgSend0(NSColor, "secondaryLabelColor");
        _ = macos.msgSend1(textField, "setTextColor:", secondaryColor);
    }

    return textField;
}

/// NSTableViewDelegate method: viewForTableColumn:row
export fn tableViewViewForTableColumnRow(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    tableView: macos.objc.id,
    column: macos.objc.id,
    row: c_long,
) callconv(.c) macos.objc.id {
    if (column == @as(macos.objc.id, null)) return null;

    // Get the data source
    const dataSource = macos.msgSend0(tableView, "dataSource");
    if (dataSource == @as(macos.objc.id, null)) return null;

    // Get the cell value from data source
    const objectValue = macos.msgSend3(
        dataSource,
        "tableView:objectValueForTableColumn:row:",
        tableView,
        column,
        row,
    );

    if (objectValue == @as(macos.objc.id, null)) return null;

    // Get column identifier
    const identifier = macos.msgSend0(column, "identifier");
    const cstr = macos.msgSend0(identifier, "UTF8String");
    if (@intFromPtr(cstr) == 0) return null;

    const column_id: [*:0]const u8 = @ptrCast(cstr);
    const column_id_slice = std.mem.span(column_id);

    // Convert object value to string
    const value_cstr = macos.msgSend0(objectValue, "UTF8String");
    if (@intFromPtr(value_cstr) == 0) return null;

    const text: [*:0]const u8 = @ptrCast(value_cstr);
    const text_slice = std.mem.span(text);

    // For name column, create cell with icon
    if (std.mem.eql(u8, column_id_slice, "name")) {
        const icon_name = getFileIcon(tableView, row);
        return createNameCellView(text_slice, icon_name);
    }

    // Create and return cell view for other columns
    return createTableCellView(text_slice, column_id_slice);
}

/// NSTableViewDelegate method: shouldSelectRow
export fn tableViewShouldSelectRow(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    _: macos.objc.id, // tableView
    _: c_long, // row
) callconv(.c) c_int {
    // Allow all rows to be selected
    return 1;
}

/// NSTableViewDelegate method: selectionDidChange
export fn tableViewSelectionDidChange(
    self: macos.objc.id,
    _: macos.objc.SEL,
    notification: macos.objc.id,
) callconv(.c) void {
    const callback_data = getCallbackData(self) orelse return;

    // Get the table view from notification
    const tableView = macos.msgSend0(notification, "object");
    if (tableView == @as(macos.objc.id, null)) return;

    // Get selected row
    const selectedRow = macos.msgSend0(tableView, "selectedRow");
    const row: c_long = @intCast(@intFromPtr(selectedRow));

    if (row < 0) return;

    // Get file ID from data source
    const dataSource = macos.msgSend0(tableView, "dataSource");
    if (dataSource == @as(macos.objc.id, null)) return;

    // Get the "name" column to retrieve file identifier
    const columns = macos.msgSend0(tableView, "tableColumns");
    if (columns == @as(macos.objc.id, null)) return;

    const firstColumn = macos.msgSend1(columns, "objectAtIndex:", @as(c_long, 0));
    if (firstColumn == @as(macos.objc.id, null)) return;

    const objectValue = macos.msgSend3(
        dataSource,
        "tableView:objectValueForTableColumn:row:",
        tableView,
        firstColumn,
        row,
    );

    if (objectValue == @as(macos.objc.id, null)) return;

    // Convert to C string
    const cstr = macos.msgSend0(objectValue, "UTF8String");
    if (@intFromPtr(cstr) == 0) return;

    const file_id: [*:0]const u8 = @ptrCast(cstr);
    const file_id_slice = std.mem.span(file_id);

    // Call the callback if set
    if (callback_data.on_select) |callback| {
        callback(file_id_slice);
    }
}

/// NSTableViewDelegate method: heightOfRow
export fn tableViewHeightOfRow(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    _: macos.objc.id, // tableView
    _: c_long, // row
) callconv(.c) f64 {
    // Standard row height for macOS file browser (22px)
    return 22.0;
}
