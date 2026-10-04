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
            /// The object NSOutlineView holds for this row. NSOutlineView keys
            /// selection, expansion and row reuse on item *identity*, so each
            /// row keeps one retained object for its whole life rather than a
            /// fresh wrapper per call (which also leaked one per call).
            handle: macos.objc.id = null,

            pub const Item = struct {
                id: []const u8,
                label: []const u8,
                icon: ?[]const u8 = null,
                badge: ?[]const u8 = null,
                handle: macos.objc.id = null,

                pub fn deinit(self: *const Item, allocator: std.mem.Allocator) void {
                    allocator.free(self.id);
                    allocator.free(self.label);
                    if (self.icon) |icon| allocator.free(icon);
                    if (self.badge) |badge| allocator.free(badge);
                    releaseHandle(self.handle);
                }
            };

            pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
                allocator.free(self.id);
                if (self.header) |header| allocator.free(header);
                for (self.items.items) |*item| item.deinit(allocator);
                self.items.deinit(allocator);
                releaseHandle(self.handle);
            }
        };

        /// Where a row's object sits: a section, or an item within one.
        pub const Location = struct { section: usize, item: ?usize };

        pub fn locate(self: *const DataStore, handle: macos.objc.id) ?Location {
            if (handle == null) return null;
            for (self.sections.items, 0..) |*section, s| {
                if (section.handle == handle) return .{ .section = s, .item = null };
                for (section.items.items, 0..) |*item, i| {
                    if (item.handle == handle) return .{ .section = s, .item = i };
                }
            }
            return null;
        }

        pub fn itemAt(self: *const DataStore, location: Location) ?*Section.Item {
            if (location.section >= self.sections.items.len) return null;
            const items = self.sections.items[location.section].items.items;
            const index = location.item orelse return null;
            return if (index < items.len) &items[index] else null;
        }

        pub fn findItem(self: *const DataStore, id: []const u8) ?*Section.Item {
            for (self.sections.items) |*section| {
                for (section.items.items) |*item| {
                    if (std.mem.eql(u8, item.id, id)) return item;
                }
            }
            return null;
        }

        /// Drop every section and item, releasing their row objects.
        pub fn clear(self: *DataStore) void {
            for (self.sections.items) |*section| section.deinit(self.allocator);
            self.sections.clearRetainingCapacity();
        }

        pub fn init(allocator: std.mem.Allocator) DataStore {
            return .{
                .sections = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *DataStore) void {
            for (self.sections.items) |*section| {
                section.deinit(self.allocator);
            }
            self.sections.deinit(self.allocator);
        }
    };

    /// A new retained row object. Its content only aids debugging; rows are
    /// compared by pointer.
    pub fn newHandle() macos.objc.id {
        handle_counter += 1;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "craft-row-{d}", .{handle_counter}) catch "craft-row";
        return macos.msgSend0(macos.createNSString(text), "retain");
    }

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

test "outline data store releases owned sections and items" {
    const allocator = std.testing.allocator;
    var store = OutlineViewDataSource.DataStore.init(allocator);
    defer store.deinit();

    var section = OutlineViewDataSource.DataStore.Section{
        .id = try allocator.dupe(u8, "library"),
        .header = try allocator.dupe(u8, "Library"),
        .items = .empty,
    };
    try section.items.append(allocator, .{
        .id = try allocator.dupe(u8, "recent"),
        .label = try allocator.dupe(u8, "Recent"),
        .icon = try allocator.dupe(u8, "clock"),
        .badge = try allocator.dupe(u8, "3"),
    });
    try store.sections.append(allocator, section);
}

var handle_counter: u64 = 0;

fn releaseHandle(handle: macos.objc.id) void {
    if (handle != null) _ = macos.msgSend0(handle, "release");
}

/// The data store behind a data source instance (also used by the delegate).
pub fn storeOf(instance: macos.objc.id) ?*OutlineViewDataSource.DataStore {
    if (instance == null) return null;
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
    const data = storeOf(self) orelse return 0;
    if (item == @as(macos.objc.id, null)) return @intCast(data.sections.items.len);
    const location = data.locate(item) orelse return 0;
    if (location.item != null) return 0;
    return @intCast(data.sections.items[location.section].items.items.len);
}

/// NSOutlineViewDataSource method: child:ofItem - the row's own retained object.
export fn outlineViewChildOfItem(
    self: macos.objc.id,
    _: macos.objc.SEL,
    _: macos.objc.id, // outlineView
    index: c_long,
    item: macos.objc.id,
) callconv(.c) macos.objc.id {
    const data = storeOf(self) orelse return null;
    if (index < 0) return null;
    const idx: usize = @intCast(index);

    if (item == @as(macos.objc.id, null)) {
        if (idx >= data.sections.items.len) return null;
        return data.sections.items[idx].handle;
    }
    const location = data.locate(item) orelse return null;
    if (location.item != null) return null;
    const items = data.sections.items[location.section].items.items;
    return if (idx < items.len) items[idx].handle else null;
}

/// NSOutlineViewDataSource method: isItemExpandable - sections with items.
export fn outlineViewIsItemExpandable(
    self: macos.objc.id,
    _: macos.objc.SEL,
    _: macos.objc.id, // outlineView
    item: macos.objc.id,
) callconv(.c) c_int {
    const data = storeOf(self) orelse return 0;
    const location = data.locate(item) orelse return 0;
    if (location.item != null) return 0;
    return if (data.sections.items[location.section].items.items.len > 0) 1 else 0;
}

/// NSOutlineViewDataSource method: objectValueForTableColumn:byItem - the
/// text shown: a section's header or an item's label. Never an id: code that
/// needs the item's id looks it up through `storeOf(...).locate(item)`.
export fn outlineViewObjectValueForTableColumnByItem(
    self: macos.objc.id,
    _: macos.objc.SEL,
    _: macos.objc.id, // outlineView
    _: macos.objc.id, // tableColumn
    item: macos.objc.id,
) callconv(.c) macos.objc.id {
    const data = storeOf(self) orelse return null;
    const location = data.locate(item) orelse return null;
    const section = &data.sections.items[location.section];
    if (location.item == null)
        return macos.createNSString(section.header orelse section.id);
    const child = data.itemAt(location) orelse return null;
    return macos.createNSString(child.label);
}
