const std = @import("std");
const builtin = @import("builtin");

/// Objective-C Runtime Wrapper for iOS/macOS
/// Provides type-safe Zig wrappers around the Objective-C runtime
const is_darwin = builtin.target.os.tag == .macos or builtin.target.os.tag == .ios or builtin.target.os.tag == .tvos or builtin.target.os.tag == .watchos;

pub const objc = if (is_darwin) struct {
    // Core runtime functions
    pub extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn class_getName(cls: ?*anyopaque) [*:0]const u8;
    pub extern "c" fn objc_allocateClassPair(superclass: ?*anyopaque, name: [*:0]const u8, extraBytes: usize) ?*anyopaque;
    pub extern "c" fn objc_registerClassPair(cls: ?*anyopaque) void;
    pub extern "c" fn class_addMethod(cls: ?*anyopaque, name: ?*anyopaque, imp: *const anyopaque, types: [*:0]const u8) bool;
    pub extern "c" fn object_getClass(obj: ?*anyopaque) ?*anyopaque;
    pub extern "c" fn class_createInstance(cls: ?*anyopaque, extraBytes: usize) ?*anyopaque;
    pub extern "c" fn class_getInstanceSize(cls: ?*anyopaque) usize;
    pub extern "c" fn objc_setAssociatedObject(obj: ?*anyopaque, key: ?*const anyopaque, value: ?*anyopaque, policy: c_uint) void;
    pub extern "c" fn objc_getAssociatedObject(obj: ?*anyopaque, key: ?*const anyopaque) ?*anyopaque;
    pub extern "c" fn objc_removeAssociatedObjects(obj: ?*anyopaque) void;
    pub extern "c" fn object_setClass(obj: ?*anyopaque, cls: ?*anyopaque) ?*anyopaque;

    // Associated object policies
    pub const OBJC_ASSOCIATION_ASSIGN: c_uint = 0;
    pub const OBJC_ASSOCIATION_RETAIN_NONATOMIC: c_uint = 1;
    pub const OBJC_ASSOCIATION_COPY_NONATOMIC: c_uint = 3;
    pub const OBJC_ASSOCIATION_RETAIN: c_uint = 769;
    pub const OBJC_ASSOCIATION_COPY: c_uint = 771;

    // Opaque types
    pub const id = ?*anyopaque;
    pub const SEL = ?*anyopaque;
    pub const Class = ?*anyopaque;
    pub const IMP = *const anyopaque;
    pub const Method = ?*anyopaque;
    pub const Ivar = ?*anyopaque;
    pub const Category = ?*anyopaque;
    pub const Protocol = ?*anyopaque;

    // NSRect/CGRect
    pub const CGFloat = f64;
    pub const CGPoint = extern struct {
        x: CGFloat,
        y: CGFloat,
    };
    pub const CGSize = extern struct {
        width: CGFloat,
        height: CGFloat,
    };
    pub const CGRect = extern struct {
        origin: CGPoint,
        size: CGSize,
    };

    // Message sending functions
    pub extern "c" fn objc_msgSend() void;
    pub extern "c" fn objc_msgSend_stret() void;
    pub extern "c" fn objc_msgSend_fpret() void;

    /// Send message with no return value
    pub fn msgSend(target: anytype, selector: SEL) void {
        const Fn = *const fn (@TypeOf(target), SEL) callconv(.c) void;
        const func: Fn = @ptrCast(&objc_msgSend);
        func(target, selector);
    }

    /// Send message returning id
    pub fn msgSendId(target: anytype, selector: SEL) id {
        const Fn = *const fn (@TypeOf(target), SEL) callconv(.c) id;
        const func: Fn = @ptrCast(&objc_msgSend);
        return func(target, selector);
    }

    /// Send message with 1 object argument, returning id
    pub fn msgSendId1(target: anytype, selector: SEL, arg1: anytype) id {
        const Fn = *const fn (@TypeOf(target), SEL, @TypeOf(arg1)) callconv(.c) id;
        const func: Fn = @ptrCast(&objc_msgSend);
        return func(target, selector, arg1);
    }

    /// Send message with 2 object arguments, returning id
    pub fn msgSendId2(target: anytype, selector: SEL, arg1: anytype, arg2: anytype) id {
        const Fn = *const fn (@TypeOf(target), SEL, @TypeOf(arg1), @TypeOf(arg2)) callconv(.c) id;
        const func: Fn = @ptrCast(&objc_msgSend);
        return func(target, selector, arg1, arg2);
    }

    /// Send message with 1 argument, no return
    pub fn msgSendVoid1(target: anytype, selector: SEL, arg1: anytype) void {
        const Fn = *const fn (@TypeOf(target), SEL, @TypeOf(arg1)) callconv(.c) void;
        const func: Fn = @ptrCast(&objc_msgSend);
        func(target, selector, arg1);
    }

    /// Send message with 2 arguments, no return
    pub fn msgSendVoid2(target: anytype, selector: SEL, arg1: anytype, arg2: anytype) void {
        const Fn = *const fn (@TypeOf(target), SEL, @TypeOf(arg1), @TypeOf(arg2)) callconv(.c) void;
        const func: Fn = @ptrCast(&objc_msgSend);
        func(target, selector, arg1, arg2);
    }

    /// Send message returning bool
    pub fn msgSendBool(target: anytype, selector: SEL) bool {
        const Fn = *const fn (@TypeOf(target), SEL) callconv(.c) bool;
        const func: Fn = @ptrCast(&objc_msgSend);
        return func(target, selector);
    }

    /// Send message with struct return (uses stret on some architectures)
    pub fn msgSendStret(comptime T: type, target: anytype, selector: SEL) T {
        if (@sizeOf(T) <= 16) {
            // Small structs can use regular msgSend on arm64
            const Fn = *const fn (@TypeOf(target), SEL) callconv(.c) T;
            const func: Fn = @ptrCast(&objc_msgSend);
            return func(target, selector);
        } else {
            // Large structs use msgSend_stret
            const Fn = *const fn (@TypeOf(target), SEL) callconv(.c) T;
            const func: Fn = @ptrCast(&objc_msgSend_stret);
            return func(target, selector);
        }
    }

    /// Helper to create NSString from Zig string
    pub fn createNSString(str: []const u8, allocator: std.mem.Allocator) !id {
        const str_z = try @import("memory.zig").dupeZ(allocator, u8, str);
        defer allocator.free(str_z);

        const NSStringClass = objc_getClass("NSString") orelse return error.ClassNotFound;
        const sel = sel_registerName("stringWithUTF8String:") orelse return error.SelectorNotFound;

        return msgSendId1(NSStringClass, sel, str_z.ptr);
    }

    /// Helper to get C string from NSString
    pub fn getNSStringUTF8(ns_string: id) ?[*:0]const u8 {
        const sel = sel_registerName("UTF8String") orelse return null;
        const Fn = *const fn (id, SEL) callconv(.c) [*:0]const u8;
        const func: Fn = @ptrCast(&objc_msgSend);
        return func(ns_string, sel);
    }

    /// Helper to create NSURL from string
    pub fn createNSURL(url_string: []const u8, allocator: std.mem.Allocator) !id {
        const ns_string = try createNSString(url_string, allocator);
        const NSURLClass = objc_getClass("NSURL") orelse return error.ClassNotFound;
        const sel = sel_registerName("URLWithString:") orelse return error.SelectorNotFound;

        return msgSendId1(NSURLClass, sel, ns_string);
    }

    /// How many bytes an instance of `class` occupies, as the runtime reports
    /// it. Useful for memory accounting, where `@sizeOf` on a Zig `opaque{}`
    /// handle would report zero and `@sizeOf(@TypeOf(ptr))` the width of a
    /// pointer.
    pub fn classInstanceSize(class: Class) usize {
        return class_getInstanceSize(@ptrCast(class));
    }

    /// Allocate an instance without initialising it.
    ///
    /// Separate from `allocInit` because a caller that has its own designated
    /// initialiser — `initWithFrame:`, `initWithFrame:configuration:` — must
    /// not have `init` sent first. `ios.zig` needs exactly this half, and
    /// `mobile.zig` open-coded it rather than reach for a helper that did too
    /// much.
    pub fn alloc(class: Class) !id {
        const sel_alloc = sel_registerName("alloc") orelse return error.SelectorNotFound;
        return msgSendId(class, sel_alloc);
    }

    /// Helper to alloc and init an object
    pub fn allocInit(class: Class) !id {
        const sel_alloc = sel_registerName("alloc") orelse return error.SelectorNotFound;
        const sel_init = sel_registerName("init") orelse return error.SelectorNotFound;

        const obj = msgSendId(class, sel_alloc);
        return msgSendId(obj, sel_init);
    }

    /// Helper to release an object
    pub fn release(obj: id) void {
        const sel = sel_registerName("release") orelse return;
        msgSend(obj, sel);
    }

    /// Helper to retain an object
    pub fn retain(obj: id) id {
        const sel = sel_registerName("retain") orelse return obj;
        return msgSendId(obj, sel);
    }

    /// Helper to autorelease an object
    pub fn autorelease(obj: id) id {
        const sel = sel_registerName("autorelease") orelse return obj;
        return msgSendId(obj, sel);
    }
} else struct {};

// Tests
test "NSString creation" {
    if (!@import("builtin").target.os.tag.isDarwin()) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const ns_string = try objc.createNSString("Hello, World!", allocator);
    try std.testing.expect(ns_string != null);

    const c_str = objc.getNSStringUTF8(ns_string);
    try std.testing.expect(c_str != null);
}

test "NSURL creation" {
    if (!@import("builtin").target.os.tag.isDarwin()) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const ns_url = try objc.createNSURL("https://example.com", allocator);
    try std.testing.expect(ns_url != null);
}
