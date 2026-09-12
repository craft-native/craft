const std = @import("std");
const macos = @import("../macos.zig");
const objc = macos.objc;

/// Keyboard event handler for native UI components
/// Provides arrow key navigation, spacebar Quick Look, and other shortcuts
/// Key codes for common keys
pub const KeyCode = struct {
    pub const Return: u16 = 36;
    pub const Tab: u16 = 48;
    pub const Space: u16 = 49;
    pub const Delete: u16 = 51;
    pub const Escape: u16 = 53;
    pub const UpArrow: u16 = 126;
    pub const DownArrow: u16 = 125;
    pub const LeftArrow: u16 = 123;
    pub const RightArrow: u16 = 124;
    pub const F: u16 = 3; // For Cmd+F find
    pub const I: u16 = 34; // For Cmd+I info
    pub const O: u16 = 31; // For Cmd+O open
    pub const C: u16 = 8; // For Cmd+C copy
    pub const V: u16 = 9; // For Cmd+V paste
    pub const A: u16 = 0; // For Cmd+A select all
};

/// Modifier flags
pub const ModifierFlag = struct {
    pub const Shift: c_ulong = 1 << 17;
    pub const Control: c_ulong = 1 << 18;
    pub const Option: c_ulong = 1 << 19;
    pub const Command: c_ulong = 1 << 20;
};

/// Keyboard event callback types
pub const KeyEventCallback = *const fn (key_code: u16, modifiers: c_ulong) bool;

/// Keyboard event data stored with the monitor
pub const KeyboardCallbackData = struct {
    on_key_down: ?KeyEventCallback = null,
    on_space_press: ?*const fn () void = null,
    on_return_press: ?*const fn () void = null,
    on_arrow_up: ?*const fn () void = null,
    on_arrow_down: ?*const fn () void = null,
    on_arrow_left: ?*const fn () void = null,
    on_arrow_right: ?*const fn () void = null,
    on_delete_press: ?*const fn () void = null,
    on_escape_press: ?*const fn () void = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*KeyboardCallbackData {
        const data = try allocator.create(KeyboardCallbackData);
        data.* = .{
            .allocator = allocator,
        };
        return data;
    }

    pub fn deinit(self: *KeyboardCallbackData) void {
        self.allocator.destroy(self);
    }
};

/// Global keyboard event monitor
pub const KeyboardMonitor = struct {
    monitor: objc.id,
    callback_data: *KeyboardCallbackData,
    allocator: std.mem.Allocator,

    /// Create a local event monitor (only receives events when app is active)
    pub fn initLocal(allocator: std.mem.Allocator) !*KeyboardMonitor {
        const callback_data = try KeyboardCallbackData.init(allocator);
        errdefer callback_data.deinit();

        // Create event monitor using NSEvent class method
        const NSEvent = macos.getClass("NSEvent");
        if (NSEvent == null) {
            return error.NSEventNotAvailable;
        }

        // NSEventMaskKeyDown = 1 << 10 = 1024
        const keyDownMask: c_ulonglong = 1 << 10;

        // Store callback data pointer for the block
        const data_ptr = @intFromPtr(callback_data);

        // Create the monitor with a block
        // addLocalMonitorForEventsMatchingMask:handler: returns an id
        const monitor = createLocalMonitor(NSEvent, keyDownMask, data_ptr);

        if (monitor == @as(objc.id, null)) {
            callback_data.deinit();
            return error.FailedToCreateMonitor;
        }

        const keyboard_monitor = try allocator.create(KeyboardMonitor);
        keyboard_monitor.* = .{
            .monitor = monitor,
            .callback_data = callback_data,
            .allocator = allocator,
        };

        std.debug.print("[Keyboard] Local event monitor created\n", .{});
        return keyboard_monitor;
    }

    pub fn deinit(self: *KeyboardMonitor) void {
        if (self.monitor != @as(objc.id, null)) {
            objc.objc_setAssociatedObject(
                self.monitor,
                &keyboard_monitor_association_key,
                null,
                objc.OBJC_ASSOCIATION_RETAIN,
            );
            const NSEvent = macos.getClass("NSEvent");
            if (NSEvent != null) {
                _ = macos.msgSend1(NSEvent, "removeMonitor:", self.monitor);
            }
        }
        self.callback_data.deinit();
        self.allocator.destroy(self);
        std.debug.print("[Keyboard] Event monitor destroyed\n", .{});
    }

    pub fn setOnSpacePress(self: *KeyboardMonitor, callback: *const fn () void) void {
        self.callback_data.on_space_press = callback;
    }

    pub fn setOnReturnPress(self: *KeyboardMonitor, callback: *const fn () void) void {
        self.callback_data.on_return_press = callback;
    }

    pub fn setOnArrowUp(self: *KeyboardMonitor, callback: *const fn () void) void {
        self.callback_data.on_arrow_up = callback;
    }

    pub fn setOnArrowDown(self: *KeyboardMonitor, callback: *const fn () void) void {
        self.callback_data.on_arrow_down = callback;
    }

    pub fn setOnArrowLeft(self: *KeyboardMonitor, callback: *const fn () void) void {
        self.callback_data.on_arrow_left = callback;
    }

    pub fn setOnArrowRight(self: *KeyboardMonitor, callback: *const fn () void) void {
        self.callback_data.on_arrow_right = callback;
    }

    pub fn setOnDeletePress(self: *KeyboardMonitor, callback: *const fn () void) void {
        self.callback_data.on_delete_press = callback;
    }

    pub fn setOnEscapePress(self: *KeyboardMonitor, callback: *const fn () void) void {
        self.callback_data.on_escape_press = callback;
    }

    pub fn setOnKeyDown(self: *KeyboardMonitor, callback: KeyEventCallback) void {
        self.callback_data.on_key_down = callback;
    }
};

var keyboard_monitor_association_key: u8 = 0;

/// Create a local event monitor
fn createLocalMonitor(NSEvent: objc.Class, mask: c_ulonglong, data_ptr: usize) objc.id {
    // We'll use a different approach - create an NSObject subclass that handles events
    // and use it with performSelector or similar

    // For now, use a polling approach with the event handler class
    const handler_class = createKeyboardHandlerClass() catch return null;

    const instance = macos.msgSend0(macos.msgSend0(handler_class, "alloc"), "init");

    // Store callback data
    const NSValue = macos.getClass("NSValue");
    const data_value = macos.msgSend1(
        NSValue,
        "valueWithPointer:",
        @as(?*anyopaque, @ptrFromInt(data_ptr)),
    );
    objc.objc_setAssociatedObject(
        instance,
        &keyboard_monitor_association_key,
        data_value,
        objc.OBJC_ASSOCIATION_RETAIN,
    );

    // Use addLocalMonitorForEventsMatchingMask with a handler block
    // Since Zig can't easily create ObjC blocks, we'll use a different approach:
    // Create an NSInvocation-based monitor or use method swizzling

    // Alternative: Return the instance and manually poll/check events
    // For now, return null and use direct key event handling in views
    _ = NSEvent;
    _ = mask;

    return instance;
}

/// Create the keyboard handler ObjC class
fn createKeyboardHandlerClass() !objc.Class {
    const class_name = "CraftKeyboardHandler";

    var objc_class = objc.objc_getClass(class_name);
    if (objc_class != null) {
        return objc_class.?;
    }

    const NSObject = macos.getClass("NSObject");
    objc_class = objc.objc_allocateClassPair(NSObject, class_name, 0);

    // handleKeyEvent: method
    const handleKeyEvent = @as(
        *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
        @ptrCast(@constCast(&keyboardHandleKeyEvent)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("handleKeyEvent:"),
        @ptrCast(@constCast(handleKeyEvent)),
        "v@:@",
    );

    objc.objc_registerClassPair(objc_class);
    return objc_class.?;
}

/// Handle key event method
export fn keyboardHandleKeyEvent(
    self: objc.id,
    _: objc.SEL,
    event: objc.id,
) callconv(.c) void {
    if (event == @as(objc.id, null)) return;

    // Get key code
    const keyCode = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) u16,
        @ptrCast(&objc.objc_msgSend),
    );
    const code = keyCode(event, macos.sel("keyCode"));

    // Get modifier flags
    const modifierFlags = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) c_ulong,
        @ptrCast(&objc.objc_msgSend),
    );
    const modifiers = modifierFlags(event, macos.sel("modifierFlags"));

    const associated = objc.objc_getAssociatedObject(self, &keyboard_monitor_association_key);
    if (associated == @as(objc.id, null)) return;
    const data_ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(data_ptr) == 0) return;
    const data: *KeyboardCallbackData = @ptrCast(@alignCast(data_ptr));
    {
        processKeyEvent(data, code, modifiers);
    }
}

/// Process a key event and call appropriate callbacks
pub fn processKeyEvent(data: *KeyboardCallbackData, key_code: u16, modifiers: c_ulong) void {
    // Call generic key down handler first
    if (data.on_key_down) |callback| {
        if (callback(key_code, modifiers)) {
            return; // Event was handled
        }
    }

    // Handle specific keys
    switch (key_code) {
        KeyCode.Space => {
            if (data.on_space_press) |callback| {
                callback();
            }
        },
        KeyCode.Return => {
            if (data.on_return_press) |callback| {
                callback();
            }
        },
        KeyCode.UpArrow => {
            if (data.on_arrow_up) |callback| {
                callback();
            }
        },
        KeyCode.DownArrow => {
            if (data.on_arrow_down) |callback| {
                callback();
            }
        },
        KeyCode.LeftArrow => {
            if (data.on_arrow_left) |callback| {
                callback();
            }
        },
        KeyCode.RightArrow => {
            if (data.on_arrow_right) |callback| {
                callback();
            }
        },
        KeyCode.Delete => {
            if (data.on_delete_press) |callback| {
                callback();
            }
        },
        KeyCode.Escape => {
            if (data.on_escape_press) |callback| {
                callback();
            }
        },
        else => {},
    }
}

/// Check if a modifier is pressed
pub fn hasModifier(modifiers: c_ulong, flag: c_ulong) bool {
    return (modifiers & flag) != 0;
}

/// Helper to check common key combinations
pub fn isCommandKey(modifiers: c_ulong, key_code: u16, expected_key: u16) bool {
    return hasModifier(modifiers, ModifierFlag.Command) and key_code == expected_key;
}

/// Setup key event handling for an NSView (makes it first responder capable)
pub fn enableKeyEventsForView(view: objc.id) void {
    if (view == @as(objc.id, null)) return;

    // Get the window and make the view first responder
    const window = macos.msgSend0(view, "window");
    if (window != @as(objc.id, null)) {
        _ = macos.msgSend1(window, "makeFirstResponder:", view);
    }
}

var outline_spacebar_association_key: u8 = 0;
var table_spacebar_association_key: u8 = 0;
var outline_return_association_key: u8 = 0;
var table_return_association_key: u8 = 0;

fn storeViewCallback(view: objc.id, key: *const anyopaque, callback: ?*const fn () void) void {
    const value = if (callback) |cb| blk: {
        const NSValue = macos.getClass("NSValue");
        break :blk macos.msgSend1(NSValue, "valueWithPointer:", @as(?*anyopaque, @ptrCast(@constCast(cb))));
    } else null;
    objc.objc_setAssociatedObject(view, key, value, objc.OBJC_ASSOCIATION_RETAIN);
}

fn viewCallback(view: objc.id, key: *const anyopaque) ?*const fn () void {
    const associated = objc.objc_getAssociatedObject(view, key);
    if (associated == @as(objc.id, null)) return null;
    const ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(ptr) == 0) return null;
    return @ptrCast(@alignCast(ptr));
}

/// Create a custom NSOutlineView subclass with keyboard handling
pub fn createCraftOutlineViewClass() !objc.Class {
    const class_name = "CraftOutlineView";

    var objc_class = objc.objc_getClass(class_name);
    if (objc_class != null) {
        return objc_class.?;
    }

    const NSOutlineView = macos.getClass("NSOutlineView");
    objc_class = objc.objc_allocateClassPair(NSOutlineView, class_name, 0);

    // Override keyDown: method
    const keyDown = @as(
        *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
        @ptrCast(@constCast(&craftOutlineViewKeyDown)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("keyDown:"),
        @ptrCast(@constCast(keyDown)),
        "v@:@",
    );

    // Override acceptsFirstResponder
    const acceptsFirstResponder = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) c_int,
        @ptrCast(@constCast(&craftViewAcceptsFirstResponder)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("acceptsFirstResponder"),
        @ptrCast(@constCast(acceptsFirstResponder)),
        "c@:",
    );

    objc.objc_registerClassPair(objc_class);
    return objc_class.?;
}

/// Create a custom NSTableView subclass with keyboard handling
pub fn createCraftTableViewClass() !objc.Class {
    const class_name = "CraftTableView";

    var objc_class = objc.objc_getClass(class_name);
    if (objc_class != null) {
        return objc_class.?;
    }

    const NSTableView = macos.getClass("NSTableView");
    objc_class = objc.objc_allocateClassPair(NSTableView, class_name, 0);

    // Override keyDown: method
    const keyDown = @as(
        *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
        @ptrCast(@constCast(&craftTableViewKeyDown)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("keyDown:"),
        @ptrCast(@constCast(keyDown)),
        "v@:@",
    );

    // Override acceptsFirstResponder
    const acceptsFirstResponder = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) c_int,
        @ptrCast(@constCast(&craftViewAcceptsFirstResponder)),
    );
    _ = objc.class_addMethod(
        objc_class,
        macos.sel("acceptsFirstResponder"),
        @ptrCast(@constCast(acceptsFirstResponder)),
        "c@:",
    );

    objc.objc_registerClassPair(objc_class);
    return objc_class.?;
}

/// acceptsFirstResponder override
export fn craftViewAcceptsFirstResponder(
    _: objc.id,
    _: objc.SEL,
) callconv(.c) c_int {
    return 1; // YES - always accept first responder
}

/// keyDown: handler for CraftOutlineView
export fn craftOutlineViewKeyDown(
    self: objc.id,
    sel: objc.SEL,
    event: objc.id,
) callconv(.c) void {
    if (event == @as(objc.id, null)) return;

    // Get key code
    const keyCode = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) u16,
        @ptrCast(&objc.objc_msgSend),
    );
    const code = keyCode(event, macos.sel("keyCode"));

    // Handle spacebar for Quick Look
    if (code == KeyCode.Space) {
        std.debug.print("[Keyboard] Spacebar pressed in outline view\n", .{});
        if (viewCallback(self, &outline_spacebar_association_key)) |callback| {
            callback();
            return;
        }
    }

    // Handle Return key
    if (code == KeyCode.Return) {
        std.debug.print("[Keyboard] Return pressed in outline view\n", .{});
        if (viewCallback(self, &outline_return_association_key)) |callback| {
            callback();
            return;
        }
    }

    // For other keys (including arrows), call super
    const superclass = objc.class_getSuperclass(objc.object_getClass(self));
    const super_impl = @as(
        *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
        @ptrCast(@alignCast(objc.class_getMethodImplementation(superclass, sel))),
    );
    super_impl(self, sel, event);
}

/// keyDown: handler for CraftTableView
export fn craftTableViewKeyDown(
    self: objc.id,
    sel: objc.SEL,
    event: objc.id,
) callconv(.c) void {
    if (event == @as(objc.id, null)) return;

    // Get key code
    const keyCode = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) u16,
        @ptrCast(&objc.objc_msgSend),
    );
    const code = keyCode(event, macos.sel("keyCode"));

    // Handle spacebar for Quick Look
    if (code == KeyCode.Space) {
        std.debug.print("[Keyboard] Spacebar pressed in table view\n", .{});
        if (viewCallback(self, &table_spacebar_association_key)) |callback| {
            callback();
            return;
        }
    }

    // Handle Return key for opening
    if (code == KeyCode.Return) {
        std.debug.print("[Keyboard] Return pressed in table view\n", .{});
        if (viewCallback(self, &table_return_association_key)) |callback| {
            callback();
            return;
        }
    }

    // For other keys (including arrows), call super
    const superclass = objc.class_getSuperclass(objc.object_getClass(self));
    const super_impl = @as(
        *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void,
        @ptrCast(@alignCast(objc.class_getMethodImplementation(superclass, sel))),
    );
    super_impl(self, sel, event);
}

/// Set the spacebar callback for outline view (sidebar)
pub fn setOutlineViewSpacebarCallback(view: objc.id, callback: ?*const fn () void) void {
    storeViewCallback(view, &outline_spacebar_association_key, callback);
}

/// Set the spacebar callback for table view (file browser)
pub fn setTableViewSpacebarCallback(view: objc.id, callback: ?*const fn () void) void {
    storeViewCallback(view, &table_spacebar_association_key, callback);
}

/// Set the return key callback for outline view (sidebar)
pub fn setOutlineViewReturnCallback(view: objc.id, callback: ?*const fn () void) void {
    storeViewCallback(view, &outline_return_association_key, callback);
}

/// Set the return key callback for table view (file browser)
pub fn setTableViewReturnCallback(view: objc.id, callback: ?*const fn () void) void {
    storeViewCallback(view, &table_return_association_key, callback);
}

/// Remove callbacks before an outline view's Zig owner is destroyed.
pub fn clearOutlineViewCallbacks(view: objc.id) void {
    storeViewCallback(view, &outline_spacebar_association_key, null);
    storeViewCallback(view, &outline_return_association_key, null);
}

/// Remove callbacks before a table view's Zig owner is destroyed.
pub fn clearTableViewCallbacks(view: objc.id) void {
    storeViewCallback(view, &table_spacebar_association_key, null);
    storeViewCallback(view, &table_return_association_key, null);
}

/// Install a key equivalent handler for a specific key combination
pub fn installKeyEquivalent(
    view: objc.id,
    key: []const u8,
    modifiers: c_ulong,
    action: objc.SEL,
    target: objc.id,
) void {
    _ = view;
    _ = key;
    _ = modifiers;
    _ = action;
    _ = target;
    // This would require creating an NSMenuItem with the key equivalent
    // and adding it to the responder chain - complex to implement directly
    std.debug.print("[Keyboard] Key equivalent installation not yet implemented\n", .{});
}
