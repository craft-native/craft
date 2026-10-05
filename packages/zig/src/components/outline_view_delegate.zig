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

            const shouldShowOutlineCell = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id) callconv(.c) c_int,
                @ptrCast(@constCast(&outlineViewShouldShowOutlineCellForItem)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineView:shouldShowOutlineCellForItem:"),
                @ptrCast(@constCast(shouldShowOutlineCell)),
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

/// Tag of the badge label inside an item's cell, so a reused cell's badge
/// can be found and rewritten.
const badge_tag: c_long = 7701;

/// Whether this row is a section (heading) rather than an item. By the data
/// store, not by `isExpandable:` - a section with no items is not expandable
/// and was drawn, and selectable, as if it were an item.
fn isSectionRow(outlineView: macos.objc.id, item: macos.objc.id) bool {
    const store = datasource.storeOf(macos.msgSend0(outlineView, "dataSource")) orelse return false;
    const location = store.locate(item) orelse return false;
    return location.item == null;
}

/// A section that has no heading: its row is only a little space above it.
fn isHeadlessSection(outlineView: macos.objc.id, item: macos.objc.id) bool {
    const store = datasource.storeOf(macos.msgSend0(outlineView, "dataSource")) orelse return false;
    const location = store.locate(item) orelse return false;
    if (location.item != null) return false;
    return store.sections.items[location.section].header == null;
}

fn anchor(view: macos.objc.id, name: [*:0]const u8) macos.objc.id {
    return macos.msgSend0(view, name);
}

fn activate(constraint: macos.objc.id) void {
    _ = macos.msgSend1(constraint, "setActive:", @as(c_int, 1));
}

fn pinEqual(a: macos.objc.id, a_anchor: [*:0]const u8, b: macos.objc.id, b_anchor: [*:0]const u8, constant: f64) void {
    activate(macos.msgSend2(anchor(a, a_anchor), "constraintEqualToAnchor:constant:", anchor(b, b_anchor), constant));
}

fn label(text_color: ?[*:0]const u8) macos.objc.id {
    const field = macos.msgSend1(macos.getClass("NSTextField"), "labelWithString:", macos.createNSString(""));
    _ = macos.msgSend1(field, "setTranslatesAutoresizingMaskIntoConstraints:", @as(c_int, 0));
    _ = macos.msgSend1(field, "setLineBreakMode:", @as(c_ulong, 4)); // NSLineBreakByTruncatingTail
    if (text_color) |color|
        _ = macos.msgSend1(field, "setTextColor:", macos.msgSend0(macos.getClass("NSColor"), color));
    return field;
}

/// A sidebar cell laid out the way Xcode's source-list template lays one out:
/// symbol, label, and a right-aligned count, held by constraints so they
/// follow the row as the sidebar is resized. Fixed frames computed from the
/// column's width at creation went stale the moment it changed, which is how
/// the counts ended up drawn outside the row.
fn makeCell(identifier: macos.objc.id, is_header: bool) macos.objc.id {
    const cell = macos.msgSend0(macos.msgSend0(macos.getClass("NSTableCellView"), "alloc"), "init");
    _ = macos.msgSend1(cell, "setIdentifier:", identifier);

    const text = label(if (is_header) "secondaryLabelColor" else null);
    _ = macos.msgSend1(cell, "addSubview:", text);
    _ = macos.msgSend1(cell, "setTextField:", text);
    pinEqual(text, "centerYAnchor", cell, "centerYAnchor", 0);

    if (is_header) {
        const font = macos.msgSend2(macos.getClass("NSFont"), "systemFontOfSize:weight:", @as(f64, 11.0), @as(f64, 0.4)); // semibold
        _ = macos.msgSend1(text, "setFont:", font);
        pinEqual(text, "leadingAnchor", cell, "leadingAnchor", 2);
        activate(macos.msgSend2(anchor(text, "trailingAnchor"), "constraintLessThanOrEqualToAnchor:constant:", anchor(cell, "trailingAnchor"), @as(f64, -4)));
        return cell;
    }

    const image = macos.msgSend0(macos.msgSend0(macos.getClass("NSImageView"), "alloc"), "init");
    _ = macos.msgSend1(image, "setTranslatesAutoresizingMaskIntoConstraints:", @as(c_int, 0));
    _ = macos.msgSend1(image, "setImageScaling:", @as(c_long, 0)); // NSImageScaleProportionallyDown: symbols at their own size
    _ = macos.msgSend1(cell, "addSubview:", image);
    _ = macos.msgSend1(cell, "setImageView:", image);
    _ = macos.msgSend0(image, "release");
    pinEqual(image, "leadingAnchor", cell, "leadingAnchor", 3);
    pinEqual(image, "centerYAnchor", cell, "centerYAnchor", 0);
    activate(macos.msgSend1(anchor(image, "widthAnchor"), "constraintEqualToConstant:", @as(f64, 18)));

    const badge = label("secondaryLabelColor");
    _ = macos.msgSend1(badge, "setTag:", badge_tag);
    _ = macos.msgSend1(badge, "setAlignment:", @as(c_long, 2)); // NSTextAlignmentRight
    _ = macos.msgSend1(badge, "setFont:", macos.msgSend2(macos.getClass("NSFont"), "monospacedDigitSystemFontOfSize:weight:", @as(f64, 12.0), @as(f64, 0.0)));
    // The count keeps its full width; the label is what truncates.
    _ = macos.msgSend2(badge, "setContentCompressionResistancePriority:forOrientation:", @as(f32, 751), @as(c_long, 0));
    _ = macos.msgSend2(badge, "setContentHuggingPriority:forOrientation:", @as(f32, 751), @as(c_long, 0));
    _ = macos.msgSend2(text, "setContentCompressionResistancePriority:forOrientation:", @as(f32, 250), @as(c_long, 0));
    _ = macos.msgSend1(cell, "addSubview:", badge);
    pinEqual(badge, "trailingAnchor", cell, "trailingAnchor", -6);
    pinEqual(badge, "centerYAnchor", cell, "centerYAnchor", 0);

    pinEqual(text, "leadingAnchor", image, "trailingAnchor", 6);
    activate(macos.msgSend2(anchor(text, "trailingAnchor"), "constraintLessThanOrEqualToAnchor:constant:", anchor(badge, "leadingAnchor"), @as(f64, -6)));
    return cell;
}

/// NSOutlineViewDelegate method: viewForTableColumn:item
export fn outlineViewViewForTableColumnItem(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    outlineView: macos.objc.id,
    _: macos.objc.id, // tableColumn: NULL for group rows
    item: macos.objc.id,
) callconv(.c) macos.objc.id {
    if (item == @as(macos.objc.id, null)) return null;

    const is_header = isSectionRow(outlineView, item);
    const identifier = macos.createNSString(if (is_header) "HeaderCell" else "DataCell");

    const dataSource = macos.msgSend0(outlineView, "dataSource");
    if (dataSource == @as(macos.objc.id, null)) return null;
    const objectValue = macos.msgSend3(dataSource, "outlineView:objectValueForTableColumn:byItem:", outlineView, @as(macos.objc.id, null), item);
    if (objectValue == @as(macos.objc.id, null)) return null;

    var cell = macos.msgSend2(outlineView, "makeViewWithIdentifier:owner:", identifier, @as(?*anyopaque, null));
    if (cell == @as(macos.objc.id, null)) cell = makeCell(identifier, is_header);

    const textField = macos.msgSend0(cell, "textField");
    if (textField != @as(macos.objc.id, null))
        _ = macos.msgSend1(textField, "setStringValue:", objectValue);
    if (is_header) return cell;

    const entry = itemForRow(outlineView, item);
    const badge = macos.msgSend1(cell, "viewWithTag:", badge_tag);
    if (badge != @as(macos.objc.id, null))
        _ = macos.msgSend1(badge, "setStringValue:", macos.createNSString(if (entry) |e| e.badge orelse "" else ""));

    const imageView = macos.msgSend0(cell, "imageView");
    if (imageView != @as(macos.objc.id, null)) {
        var icon_buf: [64]u8 = undefined;
        const name = if (entry) |e| e.icon orelse "folder" else "folder";
        const icon_z = @import("../memory.zig").bufPrintZ(&icon_buf, "{s}", .{name}) catch "folder";
        const config = sf_symbols.SymbolConfiguration{ .point_size = 14.0, .weight = .regular, .scale = .medium };
        // A template symbol, so the sidebar tints it as Finder's are.
        if (sf_symbols.createSFSymbol(icon_z, config) orelse sf_symbols.createSFSymbol("folder", config)) |image| {
            _ = macos.msgSend1(image, "setTemplate:", @as(c_int, 1));
            _ = macos.msgSend1(imageView, "setImage:", image);
        }
    }
    return cell;
}

/// NSOutlineViewDelegate method: shouldSelectItem - items, never headings.
export fn outlineViewShouldSelectItem(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    outlineView: macos.objc.id,
    item: macos.objc.id,
) callconv(.c) c_int {
    return if (isSectionRow(outlineView, item)) 0 else 1;
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

/// NSOutlineViewDelegate method: isGroupItem - every section is a group row.
export fn outlineViewIsGroupItem(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    outlineView: macos.objc.id,
    item: macos.objc.id,
) callconv(.c) c_int {
    if (item == @as(macos.objc.id, null)) return 0;
    return if (isSectionRow(outlineView, item)) 1 else 0;
}

/// NSOutlineViewDelegate method: shouldShowOutlineCellForItem. A heading
/// offers the sidebar's Show/Hide on hover; a section without one cannot be
/// collapsed, since nothing would be left to expand it again.
export fn outlineViewShouldShowOutlineCellForItem(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    outlineView: macos.objc.id,
    item: macos.objc.id,
) callconv(.c) c_int {
    return if (isHeadlessSection(outlineView, item)) 0 else 1;
}

/// NSOutlineViewDelegate method: heightOfRowByItem - the system sidebar's
/// row and heading heights, and a sliver for a section without a heading.
export fn outlineViewHeightOfRowByItem(
    _: macos.objc.id, // self
    _: macos.objc.SEL,
    outlineView: macos.objc.id,
    item: macos.objc.id,
) callconv(.c) f64 {
    if (!isSectionRow(outlineView, item)) return 28.0;
    return if (isHeadlessSection(outlineView, item)) 4.0 else 26.0;
}
