const std = @import("std");
const macos = @import("../macos.zig");
const sf_symbols = @import("../macos/sf_symbols.zig");
const datasource = @import("outline_view_datasource.zig");

/// NSOutlineViewDelegate implementation in Zig
/// Handles cell views, selection, and user interactions
pub const OutlineViewDelegate = struct {
    objc_class: macos.objc.Class,
    instance: macos.objc.id,
    callback_data: *CallbackData,
    allocator: std.mem.Allocator,

    pub const CallbackData = struct {
        /// Called with the selected item's *id* (never its label) and the
        /// context it was registered with - the sidebar, so it can tell its
        /// own web view.
        on_select: ?*const fn (context: ?*anyopaque, item_id: []const u8) void = null,
        select_context: ?*anyopaque = null,
        /// Set while code (not the person) changes the selection, so a
        /// programmatic selection is not reported back as a click.
        suppress_select: bool = false,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) CallbackData {
            return .{ .allocator = allocator };
        }
    };

    pub fn init(allocator: std.mem.Allocator) !OutlineViewDelegate {
        const callback_data = try allocator.create(CallbackData);
        callback_data.* = CallbackData.init(allocator);

        const NSObject = macos.getClass("NSObject");
        const class_name = "CraftOutlineViewDelegate";

        var objc_class = macos.objc.objc_getClass(class_name);
        if (objc_class == null) {
            objc_class = macos.objc.objc_allocateClassPair(NSObject, class_name, 0);

            // Add outlineView:viewForTableColumn:item: for view-based rendering
            const viewForTableColumn = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id, macos.objc.id) callconv(.c) macos.objc.id,
                @ptrCast(@constCast(&outlineViewViewForTableColumnItem)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineView:viewForTableColumn:item:"),
                @ptrCast(@constCast(viewForTableColumn)),
                "@@:@@@",
            );

            // Add outlineView:shouldSelectItem:
            const shouldSelectItem = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id) callconv(.c) c_int,
                @ptrCast(@constCast(&outlineViewShouldSelectItem)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineView:shouldSelectItem:"),
                @ptrCast(@constCast(shouldSelectItem)),
                "c@:@@",
            );

            // Add outlineViewSelectionDidChange:
            const selectionDidChange = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id) callconv(.c) void,
                @ptrCast(@constCast(&outlineViewSelectionDidChange)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineViewSelectionDidChange:"),
                @ptrCast(@constCast(selectionDidChange)),
                "v@:@",
            );

            // Add outlineView:heightOfRowByItem:
            const heightOfRowByItem = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id) callconv(.c) f64,
                @ptrCast(@constCast(&outlineViewHeightOfRowByItem)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineView:heightOfRowByItem:"),
                @ptrCast(@constCast(heightOfRowByItem)),
                "d@:@@",
            );

            // Add outlineView:isGroupItem: - CRITICAL for source list headers
            const isGroupItem = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id) callconv(.c) c_int,
                @ptrCast(@constCast(&outlineViewIsGroupItem)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineView:isGroupItem:"),
                @ptrCast(@constCast(isGroupItem)),
                "c@:@@",
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
            @ptrFromInt(0x9ABC), // unique key
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

    pub fn deinit(self: *OutlineViewDelegate) void {
        // Release the Objective-C instance
        if (self.instance != @as(macos.objc.id, null)) {
            _ = macos.msgSend0(self.instance, "release");
        }
        self.allocator.destroy(self.callback_data);
    }

    pub fn getInstance(self: *OutlineViewDelegate) macos.objc.id {
        return self.instance;
    }

    pub fn setOnSelectCallback(self: *OutlineViewDelegate, context: ?*anyopaque, callback: *const fn (context: ?*anyopaque, item_id: []const u8) void) void {
        self.callback_data.on_select = callback;
        self.callback_data.select_context = context;
    }

    pub fn setSuppressSelect(self: *OutlineViewDelegate, suppress: bool) void {
        self.callback_data.suppress_select = suppress;
    }
};

fn getCallbackData(instance: macos.objc.id) ?*OutlineViewDelegate.CallbackData {
    const associated = macos.objc.objc_getAssociatedObject(instance, @ptrFromInt(0x9ABC));
    if (associated == @as(macos.objc.id, null)) return null;

    const ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(ptr) == 0) return null;

    return @ptrCast(@alignCast(ptr));
}

/// The data item behind a row, through the outline view's data source.
fn itemForRow(outlineView: macos.objc.id, item: macos.objc.id) ?*datasource.OutlineViewDataSource.DataStore.Section.Item {
    const store = datasource.storeOf(macos.msgSend0(outlineView, "dataSource")) orelse return null;
    const location = store.locate(item) orelse return null;
    return store.itemAt(location);
}

/// Tag of the right-aligned count in an item row, like Mail's unread counts.
const badge_tag: c_long = 7701;

/// NSOutlineViewDelegate method: viewForTableColumn:item
export fn outlineViewViewForTableColumnItem(
    self: macos.objc.id,
    _: macos.objc.SEL,
    outlineView: macos.objc.id,
    tableColumn: macos.objc.id, // CRITICAL: This is NULL for group rows!
    item: macos.objc.id,
) callconv(.c) macos.objc.id {
    if (item == @as(macos.objc.id, null)) return null;

    // CRITICAL CHECK: Group rows have NO tableColumn (it's null)
    // We must check this first to determine if this is a header
    const is_group_item = outlineViewIsGroupItem(self, macos.sel("outlineView:isGroupItem:"), outlineView, item);
    const is_header = (tableColumn == @as(macos.objc.id, null)) or (is_group_item != 0);

    // Get cell identifier based on whether this is a header or data row
    const identifier = if (is_header) "HeaderCell" else "DataCell";
    const identifierStr = macos.createNSString(identifier);

    // Get the text value from the data source
    const dataSource = macos.msgSend0(outlineView, "dataSource");
    if (dataSource == @as(macos.objc.id, null)) return null;

    const objectValue = macos.msgSend3(
        dataSource,
        "outlineView:objectValueForTableColumn:byItem:",
        outlineView,
        @as(macos.objc.id, null),
        item,
    );

    if (objectValue == @as(macos.objc.id, null)) return null;

    // Convert NSString to C string
    const cstr = macos.msgSend0(objectValue, "UTF8String");
    if (@intFromPtr(cstr) == 0) return null;

    const text: [*:0]const u8 = @ptrCast(cstr);
    const text_slice = std.mem.span(text);

    // Icon and badge for this item (headers have neither)
    const data_item = if (!is_header) itemForRow(outlineView, item) else null;
    const icon_name = if (data_item) |entry| entry.icon else null;
    const badge_text = if (data_item) |entry| entry.badge else null;

    // Try to reuse an existing cell
    var cellView = macos.msgSend2(outlineView, "makeViewWithIdentifier:owner:", identifierStr, @as(?*anyopaque, null));

    const NSRect = extern struct {
        origin: extern struct { x: f64, y: f64 },
        size: extern struct { width: f64, height: f64 },
    };

    // If no reusable cell, create new one
    if (cellView == @as(macos.objc.id, null)) {
        const NSTableCellView = macos.getClass("NSTableCellView");
        cellView = macos.msgSend0(macos.msgSend0(NSTableCellView, "alloc"), "init");
        _ = macos.msgSend1(cellView, "setIdentifier:", identifierStr);

        const row_height: f64 = if (is_header) 20.0 else 24.0;
        const icon_size: f64 = 16.0;
        const icon_padding: f64 = 4.0;
        const text_x: f64 = if (!is_header and icon_name != null) icon_size + icon_padding + 4.0 else 2.0;

        // Create image view for icon (non-header items only)
        if (!is_header) {
            const NSImageView = macos.getClass("NSImageView");
            const imageView = macos.msgSend0(macos.msgSend0(NSImageView, "alloc"), "init");

            const icon_frame = NSRect{
                .origin = .{ .x = 4, .y = (row_height - icon_size) / 2.0 },
                .size = .{ .width = icon_size, .height = icon_size },
            };
            _ = macos.msgSend1(imageView, "setFrame:", icon_frame);
            _ = macos.msgSend1(imageView, "setImageScaling:", @as(c_long, 2)); // NSImageScaleProportionallyUpOrDown

            _ = macos.msgSend1(cellView, "setImageView:", imageView);
            _ = macos.msgSend1(cellView, "addSubview:", imageView);
        }

        // Create text field with MINIMAL styling - let macOS handle the rest
        const NSTextField = macos.getClass("NSTextField");
        const textField = macos.msgSend0(macos.msgSend0(NSTextField, "alloc"), "init");
        _ = macos.msgSend1(textField, "setBordered:", @as(c_int, 0));
        _ = macos.msgSend1(textField, "setDrawsBackground:", @as(c_int, 0));
        _ = macos.msgSend1(textField, "setEditable:", @as(c_int, 0));
        _ = macos.msgSend1(textField, "setSelectable:", @as(c_int, 0));

        // Add to cell view
        _ = macos.msgSend1(cellView, "setTextField:", textField);
        _ = macos.msgSend1(cellView, "addSubview:", textField);

        // Frame-based layout with space for icon (and, on item rows, the
        // count). The cell spans the column; the text resizes with it rather
        // than stopping at a fixed 180pt.
        const column_width: f64 = if (tableColumn != @as(macos.objc.id, null)) macos.msgSend0Double(tableColumn, "width") else 240.0;
        const badge_width: f64 = if (is_header) 0 else 34.0;
        _ = macos.msgSend1(cellView, "setFrame:", NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = column_width, .height = row_height } });
        const frame = NSRect{
            .origin = .{ .x = text_x, .y = 0 },
            .size = .{ .width = @max(40.0, column_width - text_x - badge_width - 6.0), .height = row_height },
        };
        _ = macos.msgSend1(textField, "setFrame:", frame);
        _ = macos.msgSend1(textField, "setAutoresizingMask:", @as(c_ulong, 2)); // NSViewWidthSizable
        _ = macos.msgSend1(textField, "setLineBreakMode:", @as(c_ulong, 4)); // NSLineBreakByTruncatingTail

        if (!is_header) {
            const badge = macos.msgSend0(macos.msgSend0(NSTextField, "alloc"), "init");
            _ = macos.msgSend1(badge, "setBordered:", @as(c_int, 0));
            _ = macos.msgSend1(badge, "setDrawsBackground:", @as(c_int, 0));
            _ = macos.msgSend1(badge, "setEditable:", @as(c_int, 0));
            _ = macos.msgSend1(badge, "setSelectable:", @as(c_int, 0));
            _ = macos.msgSend1(badge, "setAlignment:", @as(c_long, 1)); // NSTextAlignmentRight
            _ = macos.msgSend1(badge, "setTag:", badge_tag);
            const NSFontClass = macos.getClass("NSFont");
            _ = macos.msgSend1(badge, "setFont:", macos.msgSend2(NSFontClass, "monospacedDigitSystemFontOfSize:weight:", @as(f64, 11.0), @as(f64, 0.0)));
            _ = macos.msgSend1(badge, "setTextColor:", macos.msgSend0(macos.getClass("NSColor"), "secondaryLabelColor"));
            _ = macos.msgSend1(badge, "setFrame:", NSRect{
                .origin = .{ .x = column_width - badge_width - 8.0, .y = (row_height - 15.0) / 2.0 },
                .size = .{ .width = badge_width, .height = 15.0 },
            });
            _ = macos.msgSend1(badge, "setAutoresizingMask:", @as(c_ulong, 1)); // NSViewMinXMargin: stays at the right edge
            _ = macos.msgSend1(cellView, "addSubview:", badge);
            _ = macos.msgSend0(badge, "release");
        }

        // Set header font style
        if (is_header) {
            const NSFont = macos.getClass("NSFont");
            const font = macos.msgSend2(NSFont, "systemFontOfSize:weight:", @as(f64, 11.0), @as(f64, 0.4)); // semibold
            _ = macos.msgSend1(textField, "setFont:", font);

            const NSColor = macos.getClass("NSColor");
            const headerColor = macos.msgSend0(NSColor, "secondaryLabelColor");
            _ = macos.msgSend1(textField, "setTextColor:", headerColor);
        }
    }

    // Update the text
    const textField = macos.msgSend0(cellView, "textField");
    if (textField != @as(macos.objc.id, null)) {
        const nsString = macos.createNSString(text_slice);
        _ = macos.msgSend1(textField, "setStringValue:", nsString);
    }

    // Update the count: reused cells must not keep another row's number.
    if (!is_header) {
        const badge = macos.msgSend1(cellView, "viewWithTag:", badge_tag);
        if (badge != @as(macos.objc.id, null))
            _ = macos.msgSend1(badge, "setStringValue:", macos.createNSString(badge_text orelse ""));
    }

    // Update the icon (for non-header items)
    if (!is_header) {
        const imageView = macos.msgSend0(cellView, "imageView");
        if (imageView != @as(macos.objc.id, null)) {
            if (icon_name) |icon| {
                // Create SF Symbol image
                var icon_buf: [64]u8 = undefined;
                const icon_z = @import("../memory.zig").bufPrintZ(&icon_buf, "{s}", .{icon}) catch "folder";
                const symbol_config = sf_symbols.SymbolConfiguration{
                    .point_size = 14.0,
                    .weight = .regular,
                    .scale = .medium,
                };
                if (sf_symbols.createSFSymbol(icon_z, symbol_config)) |image| {
                    _ = macos.msgSend1(imageView, "setImage:", image);

                    // Set template rendering for proper theme support
                    _ = macos.msgSend1(image, "setTemplate:", @as(c_int, 1));
                }
            } else {
                // Default folder icon
                const symbol_config = sf_symbols.SymbolConfiguration{
                    .point_size = 14.0,
                    .weight = .regular,
                };
                if (sf_symbols.createSFSymbol("folder", symbol_config)) |image| {
                    _ = macos.msgSend1(imageView, "setImage:", image);
                    _ = macos.msgSend1(image, "setTemplate:", @as(c_int, 1));
                }
            }
        }
    }

    return cellView;
}

/// NSOutlineViewDelegate method: shouldSelectItem
export fn outlineViewShouldSelectItem(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    outlineView: macos.objc.id,
    item: macos.objc.id,
) callconv(.c) c_int {
    // Don't allow section headers to be selected, only regular items
    const isExpandable = macos.msgSend1(outlineView, "isExpandable:", item);
    const expandable: c_int = @intCast(@intFromPtr(isExpandable));

    // Return 0 (false) for headers, 1 (true) for items
    return if (expandable != 0) 0 else 1;
}

/// NSOutlineViewDelegate method: selectionDidChange
export fn outlineViewSelectionDidChange(
    self: macos.objc.id,
    _: macos.objc.SEL,
    notification: macos.objc.id,
) callconv(.c) void {
    const callback_data = getCallbackData(self) orelse return;

    // Get the outline view from notification
    const outlineView = macos.msgSend0(notification, "object");
    if (outlineView == @as(macos.objc.id, null)) return;

    // Get selected row
    const selectedRow = macos.msgSend0(outlineView, "selectedRow");
    const row: c_long = @intCast(@intFromPtr(selectedRow));

    if (row < 0) return;

    // Get the item at the selected row
    const item = macos.msgSend1(outlineView, "itemAtRow:", row);
    if (item == @as(macos.objc.id, null)) return;

    if (callback_data.suppress_select) return;

    // The item's id, looked up through its row object - not the text the
    // row displays, which is what the data source's object value is.
    const entry = itemForRow(outlineView, item) orelse return;
    if (callback_data.on_select) |callback| {
        callback(callback_data.select_context, entry.id);
    }
}

/// NSOutlineViewDelegate method: isGroupItem
/// Returns YES for section headers (expandable items with children)
export fn outlineViewIsGroupItem(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    outlineView: macos.objc.id,
    item: macos.objc.id,
) callconv(.c) c_int {
    if (item == @as(macos.objc.id, null)) return 0;

    // Check if this item is expandable (has children) - those are group headers
    const isExpandable = macos.msgSend1(outlineView, "isExpandable:", item);
    const expandable: c_int = @intCast(@intFromPtr(isExpandable));

    return expandable; // Return 1 for group headers, 0 for regular items
}

/// NSOutlineViewDelegate method: heightOfRowByItem
export fn outlineViewHeightOfRowByItem(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    outlineView: macos.objc.id,
    item: macos.objc.id,
) callconv(.c) f64 {
    // Check if item is a group/header (parent) or regular item (child)
    const isExpandable = macos.msgSend1(outlineView, "isExpandable:", item);
    const expandable: c_int = @intCast(@intFromPtr(isExpandable));

    // Headers are shorter (20px), items are taller (24px)
    return if (expandable != 0) 20.0 else 24.0;
}
