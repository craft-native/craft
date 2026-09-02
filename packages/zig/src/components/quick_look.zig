const std = @import("std");
const macos = @import("../macos.zig");
const objc = macos.objc;

/// Quick Look support for native UI components
/// Implements QLPreviewPanel integration for file previews
/// Preview item representing a file to preview
pub const PreviewItem = struct {
    id: []const u8,
    path: []const u8, // File path (file:// URL will be created)
    title: ?[]const u8 = null,
};

/// Callback data for Quick Look delegate
pub const QuickLookCallbackData = struct {
    on_panel_will_close: ?*const fn () void = null,
    on_panel_did_close: ?*const fn () void = null,
    preview_items: std.ArrayList(PreviewItem),
    current_index: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*QuickLookCallbackData {
        const data = try allocator.create(QuickLookCallbackData);
        data.* = .{
            .preview_items = .empty,
            .current_index = 0,
            .allocator = allocator,
        };
        return data;
    }

    pub fn deinit(self: *QuickLookCallbackData) void {
        for (self.preview_items.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.path);
            if (item.title) |title| {
                self.allocator.free(title);
            }
        }
        self.preview_items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addItem(self: *QuickLookCallbackData, item: PreviewItem) !void {
        const id_copy = try self.allocator.dupe(u8, item.id);
        const path_copy = try self.allocator.dupe(u8, item.path);
        const title_copy = if (item.title) |t| try self.allocator.dupe(u8, t) else null;

        try self.preview_items.append(self.allocator, .{
            .id = id_copy,
            .path = path_copy,
            .title = title_copy,
        });
    }

    pub fn clearItems(self: *QuickLookCallbackData) void {
        for (self.preview_items.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.path);
            if (item.title) |title| {
                self.allocator.free(title);
            }
        }
        self.preview_items.clearRetainingCapacity();
        self.current_index = 0;
    }

    pub fn getItem(self: *QuickLookCallbackData, index: usize) ?PreviewItem {
        if (index < self.preview_items.items.len) {
            return self.preview_items.items[index];
        }
        return null;
    }

    pub fn itemCount(self: *QuickLookCallbackData) usize {
        return self.preview_items.items.len;
    }
};

/// Quick Look controller that manages the preview panel
pub const QuickLookController = struct {
    data_source_class: objc.Class,
    delegate_class: objc.Class,
    preview_item_class: objc.Class,
    data_source_instance: objc.id,
    delegate_instance: objc.id,
    callback_data: *QuickLookCallbackData,
    allocator: std.mem.Allocator,
    panel: objc.id,

    const DataSourceKey: usize = 0x0101;
    const DelegateKey: usize = 0x0102;

    pub fn init(allocator: std.mem.Allocator) !*QuickLookController {
        const callback_data = try QuickLookCallbackData.init(allocator);
        errdefer callback_data.deinit();

        // Create data source class
        const data_source_class = try createDataSourceClass();

        // Create delegate class
        const delegate_class = try createDelegateClass();

        // Create preview item class
        const preview_item_class = try createPreviewItemClass();

        // Create instances
        const data_source_instance = macos.msgSend0(macos.msgSend0(data_source_class, "alloc"), "init");
        const delegate_instance = macos.msgSend0(macos.msgSend0(delegate_class, "alloc"), "init");

        // Store callback data in data source
        storeCallbackData(data_source_instance, callback_data, DataSourceKey);
        storeCallbackData(delegate_instance, callback_data, DelegateKey);

        const controller = try allocator.create(QuickLookController);
        controller.* = .{
            .data_source_class = data_source_class,
            .delegate_class = delegate_class,
            .preview_item_class = preview_item_class,
            .data_source_instance = data_source_instance,
            .delegate_instance = delegate_instance,
            .callback_data = callback_data,
            .allocator = allocator,
            .panel = null,
        };

        std.debug.print("[QuickLook] Controller initialized\n", .{});
        return controller;
    }

    pub fn deinit(self: *QuickLookController) void {
        // Close panel if open
        if (self.panel != null) {
            self.closePanel();
        }

        // Release instances
        if (self.data_source_instance != @as(objc.id, null)) {
            _ = macos.msgSend0(self.data_source_instance, "release");
        }
        if (self.delegate_instance != @as(objc.id, null)) {
            _ = macos.msgSend0(self.delegate_instance, "release");
        }

        self.callback_data.deinit();
        self.allocator.destroy(self);

        std.debug.print("[QuickLook] Controller destroyed\n", .{});
    }

    /// Add a file to preview
    pub fn addPreviewItem(self: *QuickLookController, item: PreviewItem) !void {
        try self.callback_data.addItem(item);
        std.debug.print("[QuickLook] Added preview item: {s}\n", .{item.path});
    }

    /// Set items to preview (replaces existing items)
    pub fn setPreviewItems(self: *QuickLookController, items: []const PreviewItem) !void {
        self.callback_data.clearItems();
        for (items) |item| {
            try self.callback_data.addItem(item);
        }
        std.debug.print("[QuickLook] Set {d} preview items\n", .{items.len});
    }

    /// Show the Quick Look panel
    pub fn showPanel(self: *QuickLookController) void {
        // Get the shared panel
        const QLPreviewPanel = macos.getClass("QLPreviewPanel");
        if (QLPreviewPanel == null) {
            std.debug.print("[QuickLook] ERROR: QLPreviewPanel class not found. QuickLook.framework may not be linked.\n", .{});
            return;
        }

        self.panel = macos.msgSend0(QLPreviewPanel, "sharedPreviewPanel");
        if (self.panel == null) {
            std.debug.print("[QuickLook] ERROR: Could not get shared preview panel\n", .{});
            return;
        }

        // Set data source and delegate
        _ = macos.msgSend1(self.panel, "setDataSource:", self.data_source_instance);
        _ = macos.msgSend1(self.panel, "setDelegate:", self.delegate_instance);

        // Reload data
        _ = macos.msgSend0(self.panel, "reloadData");

        // Make key and order front
        _ = macos.msgSend1(self.panel, "makeKeyAndOrderFront:", @as(objc.id, null));

        std.debug.print("[QuickLook] Panel shown with {d} items\n", .{self.callback_data.itemCount()});
    }

    /// Close the Quick Look panel
    pub fn closePanel(self: *QuickLookController) void {
        if (self.panel != null) {
            _ = macos.msgSend1(self.panel, "orderOut:", @as(objc.id, null));
            self.panel = null;
            std.debug.print("[QuickLook] Panel closed\n", .{});
        }
    }

    /// Toggle the Quick Look panel
    pub fn togglePanel(self: *QuickLookController) void {
        const QLPreviewPanel = macos.getClass("QLPreviewPanel");
        if (QLPreviewPanel == null) return;

        // Check if panel is visible
        const panel = macos.msgSend0(QLPreviewPanel, "sharedPreviewPanel");
        const isVisible = @as(
            *const fn (objc.id, objc.SEL) callconv(.c) bool,
            @ptrCast(&objc.objc_msgSend),
        );

        if (isVisible(panel, macos.sel("isVisible"))) {
            self.closePanel();
        } else {
            self.showPanel();
        }
    }

    /// Update the current preview index
    pub fn setCurrentPreviewIndex(self: *QuickLookController, index: usize) void {
        if (index < self.callback_data.itemCount()) {
            self.callback_data.current_index = index;
            if (self.panel != null) {
                _ = macos.msgSend0(self.panel, "reloadData");
            }
        }
    }

    /// Refresh the preview panel
    pub fn refreshPanel(self: *QuickLookController) void {
        if (self.panel != null) {
            _ = macos.msgSend0(self.panel, "reloadData");
        }
    }

    pub fn setOnPanelCloseCallback(self: *QuickLookController, callback: *const fn () void) void {
        self.callback_data.on_panel_did_close = callback;
    }
};

/// Store callback data as associated object
fn storeCallbackData(instance: objc.id, data: *QuickLookCallbackData, key: usize) void {
    const data_ptr_value = @intFromPtr(data);
    const NSValue = macos.getClass("NSValue");
    const data_value = macos.msgSend1(
        NSValue,
        "valueWithPointer:",
        @as(?*anyopaque, @ptrFromInt(data_ptr_value)),
    );
    objc.objc_setAssociatedObject(
        instance,
        @ptrFromInt(key),
        data_value,
        objc.OBJC_ASSOCIATION_RETAIN,
    );
}

/// Get callback data from associated object
fn getCallbackData(instance: objc.id, key: usize) ?*QuickLookCallbackData {
    const associated = objc.objc_getAssociatedObject(instance, @ptrFromInt(key));
    if (associated == @as(objc.id, null)) return null;

    const ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(ptr) == 0) return null;

    return @ptrCast(@alignCast(ptr));
}

/// Create the QLPreviewPanelDataSource class
fn createDataSourceClass() !objc.Class {
    const class_name = "CraftQLPreviewPanelDataSource";

    var objc_class = objc.objc_getClass(class_name);
    if (objc_class != null) {
        return objc_class.?;
    }

    const NSObject = macos.getClass("NSObject");
    objc_class = objc.objc_allocateClassPair(NSObject, class_name, 0);

    // numberOfPreviewItemsInPreviewPanel:
    const numberOfItems = @as(
        *const fn (objc.id, objc.SEL, objc.id) callconv(.c) c_long,
        @ptrCast(@constCast(&numberOfPreviewItemsInPreviewPanel)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("numberOfPreviewItemsInPreviewPanel:"),
        @ptrCast(@constCast(numberOfItems)),
        "l@:@",
    );

    // previewPanel:previewItemAtIndex:
    const itemAtIndex = @as(
        *const fn (objc.id, objc.SEL, objc.id, c_long) callconv(.c) objc.id,
        @ptrCast(@constCast(&previewPanelPreviewItemAtIndex)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("previewPanel:previewItemAtIndex:"),
        @ptrCast(@constCast(itemAtIndex)),
        "@@:@l",
    );

    objc.objc_registerClassPair(objc_class);
    std.debug.print("[QuickLook] Registered data source class\n", .{});

    return objc_class.?;
}

/// Create the QLPreviewPanelDelegate class
fn createDelegateClass() !objc.Class {
    const class_name = "CraftQLPreviewPanelDelegate";

    var objc_class = objc.objc_getClass(class_name);
    if (objc_class != null) {
        return objc_class.?;
    }

    const NSObject = macos.getClass("NSObject");
    objc_class = objc.objc_allocateClassPair(NSObject, class_name, 0);

    // previewPanel:handleEvent:
    const handleEvent = @as(
        *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) bool,
        @ptrCast(@constCast(&previewPanelHandleEvent)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("previewPanel:handleEvent:"),
        @ptrCast(@constCast(handleEvent)),
        "c@:@@",
    );

    // previewPanelDidClose: (custom - may need NSWindowDelegate)
    const didClose = @as(
        *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
        @ptrCast(@constCast(&previewPanelDidClose)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("windowWillClose:"),
        @ptrCast(@constCast(didClose)),
        "v@:@",
    );

    objc.objc_registerClassPair(objc_class);
    std.debug.print("[QuickLook] Registered delegate class\n", .{});

    return objc_class.?;
}

/// Create the QLPreviewItem class (wraps file URL)
fn createPreviewItemClass() !objc.Class {
    const class_name = "CraftQLPreviewItem";

    var objc_class = objc.objc_getClass(class_name);
    if (objc_class != null) {
        return objc_class.?;
    }

    const NSObject = macos.getClass("NSObject");
    objc_class = objc.objc_allocateClassPair(NSObject, class_name, 0);

    // Add instance variable for URL
    _ = objc.class_addIvar(objc_class, "_previewItemURL", @sizeOf(objc.id), 3, "@");
    _ = objc.class_addIvar(objc_class, "_previewItemTitle", @sizeOf(objc.id), 3, "@");

    // previewItemURL (getter)
    const getURL = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) objc.id,
        @ptrCast(@constCast(&previewItemURL)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("previewItemURL"),
        @ptrCast(@constCast(getURL)),
        "@@:",
    );

    // previewItemTitle (getter)
    const getTitle = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) objc.id,
        @ptrCast(@constCast(&previewItemTitle)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("previewItemTitle"),
        @ptrCast(@constCast(getTitle)),
        "@@:",
    );

    // setPreviewItemURL: (setter)
    const setURL = @as(
        *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
        @ptrCast(@constCast(&setPreviewItemURL)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("setPreviewItemURL:"),
        @ptrCast(@constCast(setURL)),
        "v@:@",
    );

    // setPreviewItemTitle: (setter)
    const setTitle = @as(
        *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
        @ptrCast(@constCast(&setPreviewItemTitle)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("setPreviewItemTitle:"),
        @ptrCast(@constCast(setTitle)),
        "v@:@",
    );

    objc.objc_registerClassPair(objc_class);
    std.debug.print("[QuickLook] Registered preview item class\n", .{});

    return objc_class.?;
}

// ============================================================================
// Data Source Methods
// ============================================================================

/// Returns the number of preview items
export fn numberOfPreviewItemsInPreviewPanel(
    self: objc.id,
    _: objc.SEL,
    _: objc.id, // panel
) callconv(.c) c_long {
    const data = getCallbackData(self, QuickLookController.DataSourceKey) orelse return 0;
    return @intCast(data.itemCount());
}

/// Returns the preview item at the given index
export fn previewPanelPreviewItemAtIndex(
    self: objc.id,
    _: objc.SEL,
    _: objc.id, // panel
    index: c_long,
) callconv(.c) objc.id {
    const data = getCallbackData(self, QuickLookController.DataSourceKey) orelse return null;
    const item = data.getItem(@intCast(index)) orelse return null;

    // Create a preview item
    const previewItemClass = objc.objc_getClass("CraftQLPreviewItem");
    if (previewItemClass == null) return null;

    const previewItem = macos.msgSend0(macos.msgSend0(previewItemClass, "alloc"), "init");

    // Create file URL
    const NSURL = macos.getClass("NSURL");
    const pathString = macos.createNSString(item.path);
    const fileURL = macos.msgSend1(NSURL, "fileURLWithPath:", pathString);

    // Set URL
    _ = macos.msgSend1(previewItem, "setPreviewItemURL:", fileURL);

    // Set title if provided
    if (item.title) |title| {
        const titleString = macos.createNSString(title);
        _ = macos.msgSend1(previewItem, "setPreviewItemTitle:", titleString);
    }

    return previewItem;
}

// ============================================================================
// Delegate Methods
// ============================================================================

/// Handle keyboard events in the preview panel
export fn previewPanelHandleEvent(
    _: objc.id,
    _: objc.SEL,
    _: objc.id, // panel
    event: objc.id,
) callconv(.c) bool {
    // Get event type
    const eventType = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) c_ulong,
        @ptrCast(&objc.objc_msgSend),
    );
    const type_val = eventType(event, macos.sel("type"));

    // NSEventTypeKeyDown = 10
    if (type_val == 10) {
        // Get key code
        const keyCode = @as(
            *const fn (objc.id, objc.SEL) callconv(.c) u16,
            @ptrCast(&objc.objc_msgSend),
        );
        const code = keyCode(event, macos.sel("keyCode"));

        // Space bar = 49
        if (code == 49) {
            // Toggle panel (handled by caller)
            std.debug.print("[QuickLook] Space bar pressed in panel\n", .{});
            return true;
        }
    }

    return false; // Let panel handle other events
}

/// Called when the preview panel is about to close
export fn previewPanelDidClose(
    self: objc.id,
    _: objc.SEL,
    _: objc.id, // notification
) callconv(.c) void {
    const data = getCallbackData(self, QuickLookController.DelegateKey) orelse return;

    if (data.on_panel_did_close) |callback| {
        callback();
    }

    std.debug.print("[QuickLook] Panel closed\n", .{});
}

// ============================================================================
// Preview Item Methods
// ============================================================================

/// Get the preview item URL
export fn previewItemURL(
    self: objc.id,
    _: objc.SEL,
) callconv(.c) objc.id {
    const cls = objc.object_getClass(self);
    const ivar = objc.class_getInstanceVariable(cls, "_previewItemURL");
    if (ivar == null) return null;
    return objc.object_getIvar(self, ivar);
}

/// Get the preview item title
export fn previewItemTitle(
    self: objc.id,
    _: objc.SEL,
) callconv(.c) objc.id {
    const cls = objc.object_getClass(self);
    const ivar = objc.class_getInstanceVariable(cls, "_previewItemTitle");
    if (ivar == null) return null;
    return objc.object_getIvar(self, ivar);
}

/// Set the preview item URL
export fn setPreviewItemURL(
    self: objc.id,
    _: objc.SEL,
    url: objc.id,
) callconv(.c) void {
    const cls = objc.object_getClass(self);
    const ivar = objc.class_getInstanceVariable(cls, "_previewItemURL");
    if (ivar != null) {
        objc.object_setIvar(self, ivar, url);
    }
}

/// Set the preview item title
export fn setPreviewItemTitle(
    self: objc.id,
    _: objc.SEL,
    title: objc.id,
) callconv(.c) void {
    const cls = objc.object_getClass(self);
    const ivar = objc.class_getInstanceVariable(cls, "_previewItemTitle");
    if (ivar != null) {
        objc.object_setIvar(self, ivar, title);
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if Quick Look is available on this system
pub fn isQuickLookAvailable() bool {
    const QLPreviewPanel = macos.getClass("QLPreviewPanel");
    return QLPreviewPanel != null;
}

/// Create a preview item from a file path
pub fn createPreviewItemFromPath(path: []const u8, title: ?[]const u8) PreviewItem {
    return .{
        .id = path,
        .path = path,
        .title = title,
    };
}
