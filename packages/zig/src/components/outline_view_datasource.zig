const std = @import("std");
const macos = @import("../macos.zig");

/// NSOutlineViewDataSource implementation in Zig
/// This creates a dynamic Objective-C class at runtime that implements the data source protocol
pub const OutlineViewDataSource = struct {
    objc_class: macos.objc.Class,
    instance: macos.objc.id,
    data: *DataStore,
    allocator: std.mem.Allocator,

    /// Data structure that holds the outline view hierarchy
    pub const DataStore = struct {
        sections: std.ArrayList(Section),
        allocator: std.mem.Allocator,

        pub const Section = struct {
            id: []const u8,
            header: ?[]const u8,
            items: std.ArrayList(Item),
            is_expanded: bool = true,

            pub const Item = struct {
                id: []const u8,
                label: []const u8,
                icon: ?[]const u8 = null,
                badge: ?[]const u8 = null,
            };
        };

        pub fn init(allocator: std.mem.Allocator) DataStore {
            return .{
                .sections = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *DataStore) void {
            self.sections.deinit(self.allocator);
        }
    };

    /// Create a new data source with dynamic Objective-C class
    pub fn init(allocator: std.mem.Allocator) !OutlineViewDataSource {
        // Allocate data store
        const data = try allocator.create(DataStore);
        data.* = DataStore.init(allocator);

        // Create dynamic Objective-C class
        const NSObject = macos.getClass("NSObject");
        const class_name = "CraftOutlineViewDataSource";

        // Check if class already exists
        var objc_class = macos.objc.objc_getClass(class_name);
        if (objc_class == null) {
            // Allocate new class
            objc_class = macos.objc.objc_allocateClassPair(NSObject, class_name, 0);

            // Add required NSOutlineViewDataSource methods
            const outlineView_numberOfChildrenOfItem = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id) callconv(.c) c_long,
                @ptrCast(@constCast(&outlineViewNumberOfChildrenOfItem)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineView:numberOfChildrenOfItem:"),
                @ptrCast(@constCast(outlineView_numberOfChildrenOfItem)),
                "l@:@@", // returns long, takes self, _cmd, outlineView, item
            );

            const outlineView_child_ofItem = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, c_long, macos.objc.id) callconv(.c) macos.objc.id,
                @ptrCast(@constCast(&outlineViewChildOfItem)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineView:child:ofItem:"),
                @ptrCast(@constCast(outlineView_child_ofItem)),
                "@@:@l@", // returns id, takes self, _cmd, outlineView, index, item
            );

            const outlineView_isItemExpandable = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id) callconv(.c) c_int,
                @ptrCast(@constCast(&outlineViewIsItemExpandable)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineView:isItemExpandable:"),
                @ptrCast(@constCast(outlineView_isItemExpandable)),
                "c@:@@", // returns BOOL (char), takes self, _cmd, outlineView, item
            );

            const outlineView_objectValueForTableColumn_byItem = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id, macos.objc.id) callconv(.c) macos.objc.id,
                @ptrCast(@constCast(&outlineViewObjectValueForTableColumnByItem)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("outlineView:objectValueForTableColumn:byItem:"),
                @ptrCast(@constCast(outlineView_objectValueForTableColumn_byItem)),
                "@@:@@@", // returns id, takes self, _cmd, outlineView, column, item
            );

            // Register the class
            macos.objc.objc_registerClassPair(objc_class);
        }

        // Create instance
        const instance = macos.msgSend0(macos.msgSend0(objc_class.?, "alloc"), "init");

        // Store data pointer in associated object
        const data_ptr_value = @intFromPtr(data);
        const NSValue = macos.getClass("NSValue");
        const data_value = macos.msgSend1(
            NSValue,
            "valueWithPointer:",
            @as(?*anyopaque, @ptrFromInt(data_ptr_value)),
        );
        macos.objc.objc_setAssociatedObject(
            instance,
            @ptrFromInt(0x1234), // unique key
            data_value,
            macos.objc.OBJC_ASSOCIATION_RETAIN,
        );

        return .{
            .objc_class = objc_class.?,
            .instance = instance,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OutlineViewDataSource) void {
        // Release the Objective-C instance
        if (self.instance != @as(macos.objc.id, null)) {
            _ = macos.msgSend0(self.instance, "release");
        }
        self.data.deinit();
        self.allocator.destroy(self.data);
    }

    /// Get the Objective-C instance to set as data source
    pub fn getInstance(self: *OutlineViewDataSource) macos.objc.id {
        return self.instance;
    }
};

/// Helper to get data store from Objective-C instance
fn getDataStore(instance: macos.objc.id) ?*OutlineViewDataSource.DataStore {
    const associated = macos.objc.objc_getAssociatedObject(instance, @ptrFromInt(0x1234));
    if (associated == @as(macos.objc.id, null)) return null;

    const ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(ptr) == 0) return null;

    // Convert pointer without alignment check - the allocator ensures proper alignment
    const data_ptr: *OutlineViewDataSource.DataStore = @ptrFromInt(@intFromPtr(ptr));
    return data_ptr;
}

/// NSOutlineViewDataSource method: numberOfChildrenOfItem
export fn outlineViewNumberOfChildrenOfItem(
    self: macos.objc.id,
    _: macos.objc.SEL,
    _: macos.objc.id, // outlineView
    item: macos.objc.id,
) callconv(.c) c_long {
    const data = getDataStore(self) orelse return 0;

    // If item is nil, return number of root items (sections)
    if (item == @as(macos.objc.id, null)) {
        return @intCast(data.sections.items.len);
    }

    // Decode the wrapper
    const decoded = decodeItemWrapper(item);

    // If item_idx is null, this is a section - return number of children
    if (decoded.item_idx == null) {
        if (decoded.section_idx >= data.sections.items.len) return 0;
        return @intCast(data.sections.items[decoded.section_idx].items.items.len);
    }

    // Items don't have children
    return 0;
}

/// Helper to create an NSNumber wrapper for indices
fn createItemWrapper(section_idx: usize, item_idx: ?usize) macos.objc.id {
    const NSMutableDictionary = macos.getClass("NSMutableDictionary");
    const dict = macos.msgSend0(macos.msgSend0(NSMutableDictionary, "alloc"), "init");

    const NSNumber = macos.getClass("NSNumber");
    const section_num = macos.msgSend1(NSNumber, "numberWithUnsignedLong:", @as(c_ulong, section_idx));
    _ = macos.msgSend2(dict, "setObject:forKey:", section_num, macos.createNSString("section"));

    if (item_idx) |idx| {
        const item_num = macos.msgSend1(NSNumber, "numberWithUnsignedLong:", @as(c_ulong, idx));
        _ = macos.msgSend2(dict, "setObject:forKey:", item_num, macos.createNSString("item"));
    }

    return dict;
}

/// Helper to decode indices from NSNumber wrapper
fn decodeItemWrapper(wrapper: macos.objc.id) struct { section_idx: usize, item_idx: ?usize } {
    const section_obj = macos.msgSend1(wrapper, "objectForKey:", macos.createNSString("section"));
    const section_val = macos.msgSend0(section_obj, "unsignedLongValue");
    const section_idx: usize = @intCast(@intFromPtr(section_val));

    const item_obj = macos.msgSend1(wrapper, "objectForKey:", macos.createNSString("item"));
    const item_idx: ?usize = if (item_obj != @as(macos.objc.id, null)) blk: {
        const item_val = macos.msgSend0(item_obj, "unsignedLongValue");
        break :blk @intCast(@intFromPtr(item_val));
    } else null;

    return .{ .section_idx = section_idx, .item_idx = item_idx };
}

/// NSOutlineViewDataSource method: child:ofItem
/// We use NSDictionary wrappers as item identifiers to avoid pointer issues
export fn outlineViewChildOfItem(
    self: macos.objc.id,
    _: macos.objc.SEL,
    _: macos.objc.id, // outlineView
    index: c_long,
    item: macos.objc.id,
) callconv(.c) macos.objc.id {
    const data = getDataStore(self) orelse return null;

    const idx: usize = @intCast(index);

    // If item is nil, return root item (section) at index
    if (item == @as(macos.objc.id, null)) {
        if (idx >= data.sections.items.len) return null;
        return createItemWrapper(idx, null);
    }

    // Decode the item to get section/item indices
    const decoded = decodeItemWrapper(item);

    // If item_idx is null, this is a section - return child at index
    if (decoded.item_idx == null) {
        if (decoded.section_idx >= data.sections.items.len) return null;
        if (idx >= data.sections.items[decoded.section_idx].items.items.len) return null;
        return createItemWrapper(decoded.section_idx, idx);
    }

    // Items don't have children
    return null;
}

/// NSOutlineViewDataSource method: isItemExpandable
export fn outlineViewIsItemExpandable(
    self: macos.objc.id,
    _: macos.objc.SEL,
    _: macos.objc.id, // outlineView
    item: macos.objc.id,
) callconv(.c) c_int {
    const data = getDataStore(self) orelse return 0;

    // Root items (nil) are not expandable
    if (item == @as(macos.objc.id, null)) return 0;

    // Decode the wrapper
    const decoded = decodeItemWrapper(item);

    // Sections are expandable if they have children
    if (decoded.item_idx == null) {
        if (decoded.section_idx >= data.sections.items.len) return 0;
        return if (data.sections.items[decoded.section_idx].items.items.len > 0) 1 else 0;
    }

    // Regular items are not expandable
    return 0;
}

/// NSOutlineViewDataSource method: objectValueForTableColumn:byItem
export fn outlineViewObjectValueForTableColumnByItem(
    self: macos.objc.id,
    _: macos.objc.SEL,
    _: macos.objc.id, // outlineView
    _: macos.objc.id, // tableColumn
    item: macos.objc.id,
) callconv(.c) macos.objc.id {
    const data = getDataStore(self) orelse return null;

    if (item == @as(macos.objc.id, null)) return null;

    // Decode the wrapper
    const decoded = decodeItemWrapper(item);

    // Bounds check
    if (decoded.section_idx >= data.sections.items.len) return null;

    const section = &data.sections.items[decoded.section_idx];

    // If it's a section header (item_idx is null)
    if (decoded.item_idx == null) {
        if (section.header) |header| {
            return macos.createNSString(header);
        }
        return macos.createNSString(section.id);
    }

    // It's an item within a section
    const item_index = decoded.item_idx.?;
    if (item_index >= section.items.items.len) return null;

    const child = &section.items.items[item_index];
    return macos.createNSString(child.label);
}
