const std = @import("std");
const macos = @import("../macos.zig");

/// NSTableViewDataSource implementation in Zig
/// Creates a dynamic Objective-C class for table view data source
pub const TableViewDataSource = struct {
    objc_class: macos.objc.Class,
    instance: macos.objc.id,
    data: *DataStore,
    allocator: std.mem.Allocator,

    /// Data structure for file list
    pub const DataStore = struct {
        files: std.ArrayList(FileItem),
        allocator: std.mem.Allocator,

        pub const FileItem = struct {
            id: []const u8,
            name: []const u8,
            icon: ?[]const u8 = null,
            date_modified: ?[]const u8 = null,
            size: ?[]const u8 = null,
            kind: ?[]const u8 = null,

            pub fn deinit(self: *const FileItem, allocator: std.mem.Allocator) void {
                allocator.free(self.id);
                allocator.free(self.name);
                if (self.icon) |icon| allocator.free(icon);
                if (self.date_modified) |date| allocator.free(date);
                if (self.size) |size| allocator.free(size);
                if (self.kind) |kind| allocator.free(kind);
            }
        };

        pub fn init(allocator: std.mem.Allocator) DataStore {
            return .{
                .files = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *DataStore) void {
            self.clear();
            self.files.deinit(self.allocator);
        }

        pub fn clear(self: *DataStore) void {
            for (self.files.items) |file| {
                file.deinit(self.allocator);
            }
            self.files.clearRetainingCapacity();
        }
    };

    /// Create data source with dynamic class
    pub fn init(allocator: std.mem.Allocator) !TableViewDataSource {
        const data = try allocator.create(DataStore);
        data.* = DataStore.init(allocator);

        const NSObject = macos.getClass("NSObject");
        const class_name = "CraftTableViewDataSource";

        var objc_class = macos.objc.objc_getClass(class_name);
        if (objc_class == null) {
            objc_class = macos.objc.objc_allocateClassPair(NSObject, class_name, 0);

            // Add numberOfRowsInTableView:
            const numberOfRowsInTableView = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id) callconv(.c) c_long,
                @ptrCast(@constCast(&tableViewNumberOfRows)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("numberOfRowsInTableView:"),
                @ptrCast(@constCast(numberOfRowsInTableView)),
                "l@:@", // returns long, takes self, _cmd, tableView
            );

            // Add tableView:objectValueForTableColumn:row:
            const objectValueForTableColumnRow = @as(
                *const fn (macos.objc.id, macos.objc.SEL, macos.objc.id, macos.objc.id, c_long) callconv(.c) macos.objc.id,
                @ptrCast(@constCast(&tableViewObjectValueForTableColumnRow)),
            );
            _ = macos.objc.class_addMethod(
                objc_class,
                macos.sel("tableView:objectValueForTableColumn:row:"),
                @ptrCast(@constCast(objectValueForTableColumnRow)),
                "@@:@@l", // returns id, takes self, _cmd, tableView, column, row
            );

            macos.objc.objc_registerClassPair(objc_class);
        }

        const instance = macos.msgSend0(macos.msgSend0(objc_class.?, "alloc"), "init");

        // Store data pointer
        const data_ptr_value = @intFromPtr(data);
        const NSValue = macos.getClass("NSValue");
        const data_value = macos.msgSend1(
            NSValue,
            "valueWithPointer:",
            @as(?*anyopaque, @ptrFromInt(data_ptr_value)),
        );
        macos.objc.objc_setAssociatedObject(
            instance,
            @ptrFromInt(0x5678), // unique key
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

    pub fn deinit(self: *TableViewDataSource) void {
        // Release the Objective-C instance
        if (self.instance != @as(macos.objc.id, null)) {
            _ = macos.msgSend0(self.instance, "release");
        }
        self.data.deinit();
        self.allocator.destroy(self.data);
    }

    pub fn getInstance(self: *TableViewDataSource) macos.objc.id {
        return self.instance;
    }
};

test "table data store clear and deinit release owned files" {
    const allocator = std.testing.allocator;
    var store = TableViewDataSource.DataStore.init(allocator);
    defer store.deinit();

    try store.files.append(allocator, .{
        .id = try allocator.dupe(u8, "readme"),
        .name = try allocator.dupe(u8, "README.md"),
        .icon = try allocator.dupe(u8, "doc.text"),
        .date_modified = try allocator.dupe(u8, "today"),
        .size = try allocator.dupe(u8, "4 KB"),
        .kind = try allocator.dupe(u8, "Markdown"),
    });
    store.clear();
    try std.testing.expectEqual(@as(usize, 0), store.files.items.len);
}

fn getDataStore(instance: macos.objc.id) ?*TableViewDataSource.DataStore {
    const associated = macos.objc.objc_getAssociatedObject(instance, @ptrFromInt(0x5678));
    if (associated == @as(macos.objc.id, null)) return null;

    const ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(ptr) == 0) return null;

    return @ptrCast(@alignCast(ptr));
}

/// NSTableViewDataSource method: numberOfRowsInTableView
export fn tableViewNumberOfRows(
    self: macos.objc.id,
    _: macos.objc.SEL,
    _: macos.objc.id, // tableView
) callconv(.c) c_long {
    const data = getDataStore(self) orelse return 0;
    return @intCast(data.files.items.len);
}

/// NSTableViewDataSource method: objectValueForTableColumn:row
export fn tableViewObjectValueForTableColumnRow(
    self: macos.objc.id,
    _: macos.objc.SEL,
    _: macos.objc.id, // tableView
    column: macos.objc.id,
    row: c_long,
) callconv(.c) macos.objc.id {
    const data = getDataStore(self) orelse return null;

    const row_idx: usize = @intCast(row);
    if (row_idx >= data.files.items.len) return null;

    const file = &data.files.items[row_idx];

    // Get column identifier
    const identifier = macos.msgSend0(column, "identifier");

    // Convert to C string to compare
    const cstr = macos.msgSend0(identifier, "UTF8String");
    if (@intFromPtr(cstr) == 0) return null;

    const col_name: [*:0]const u8 = @ptrCast(cstr);

    // Return appropriate value based on column
    if (std.mem.eql(u8, std.mem.span(col_name), "name")) {
        return macos.createNSString(file.name);
    } else if (std.mem.eql(u8, std.mem.span(col_name), "dateModified")) {
        if (file.date_modified) |date| {
            return macos.createNSString(date);
        }
    } else if (std.mem.eql(u8, std.mem.span(col_name), "size")) {
        if (file.size) |size| {
            return macos.createNSString(size);
        }
    } else if (std.mem.eql(u8, std.mem.span(col_name), "kind")) {
        if (file.kind) |kind| {
            return macos.createNSString(kind);
        }
    }

    return macos.createNSString("--");
}
