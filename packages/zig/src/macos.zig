const std = @import("std");
const builtin = @import("builtin");
const javascript = @import("javascript.zig");
const native_sidebar_bootstrap = @import("native_sidebar_bootstrap.zig");
const local_tls = @import("local_tls.zig");
const menu_roles = @import("menu_roles.zig");

// Objective-C runtime types and functions (manual declarations to avoid @cImport issues)
pub const objc = struct {
    pub const id = ?*anyopaque;
    pub const Class = ?*anyopaque;
    pub const SEL = ?*anyopaque;
    pub const IMP = ?*anyopaque;
    pub const BOOL = bool;
    pub const Method = ?*anyopaque;
    pub const Ivar = ?*anyopaque;
    pub const Protocol = ?*anyopaque;

    // Objective-C runtime functions
    pub extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
    pub extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extraBytes: usize) Class;
    pub extern "objc" fn objc_registerClassPair(cls: Class) void;
    pub extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
    pub extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) BOOL;
    pub extern "objc" fn class_replaceMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) IMP;
    pub extern "objc" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) BOOL;
    pub extern "objc" fn object_getIvar(obj: id, ivar: Ivar) id;
    pub extern "objc" fn object_setIvar(obj: id, ivar: Ivar, value: id) void;
    pub extern "objc" fn class_getInstanceVariable(cls: Class, name: [*:0]const u8) Ivar;
    pub extern "objc" fn objc_msgSend() void; // Actual signature varies, cast as needed
    pub extern "objc" fn objc_msgSend_stret() void;
    pub extern "objc" fn object_getClass(obj: id) Class;
    pub extern "objc" fn class_getSuperclass(cls: Class) Class;
    pub extern "objc" fn class_getName(cls: Class) [*:0]const u8;
    pub extern "objc" fn method_getImplementation(m: Method) IMP;
    pub extern "objc" fn class_getInstanceMethod(cls: Class, sel: SEL) Method;
    pub extern "objc" fn class_getClassMethod(cls: Class, sel: SEL) Method;
    pub extern "objc" fn class_getMethodImplementation(cls: Class, sel: SEL) IMP;
    pub extern "objc" fn objc_setAssociatedObject(object: id, key: *const anyopaque, value: id, policy: usize) void;
    pub extern "objc" fn objc_getAssociatedObject(object: id, key: *const anyopaque) id;

    // Association policy constants
    pub const OBJC_ASSOCIATION_ASSIGN: usize = 0;
    pub const OBJC_ASSOCIATION_RETAIN_NONATOMIC: usize = 1;
    pub const OBJC_ASSOCIATION_COPY_NONATOMIC: usize = 3;
    pub const OBJC_ASSOCIATION_RETAIN: usize = 0x301;
    pub const OBJC_ASSOCIATION_COPY: usize = 0x303;
};

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub const NSPoint = extern struct {
    x: f64,
    y: f64,
};

pub const NSSize = extern struct {
    width: f64,
    height: f64,
};

pub const NSRange = extern struct {
    location: c_ulong,
    length: c_ulong,
};

// Window style options
const startup_timing = @import("startup_timing.zig");

pub const WindowStyle = struct {
    frameless: bool = false,
    transparent: bool = false,
    always_on_top: bool = false,
    resizable: bool = true,
    closable: bool = true,
    miniaturizable: bool = true,
    fullscreen: bool = false,
    x: ?i32 = null, // Window x position (null = center)
    y: ?i32 = null, // Window y position (null = center)
    dark_mode: ?bool = null, // null = system default, true = dark, false = light
    enable_hot_reload: bool = false, // Enable hot reload support
    hide_dock_icon: bool = false, // Hide dock icon (menubar-only mode)
    titlebar_hidden: bool = false, // Hide titlebar (content extends into titlebar area)
    system_tray: bool = false, // Show in system tray (menubar)
    system_tray_title: ?[]const u8 = null, // Initial title for system tray
    dev_tools: bool = true, // Enable WebKit DevTools (inspector)
    native_sidebar: bool = false, // Enable native sidebar (injects sidebar UI script)
    web_sidebar_material: bool = false, // Draw a native sidebar material behind web-rendered sidebars
    web_sidebar_width: u32 = 286,
    web_sidebar_material_opacity: f64 = 0.78,
    benchmark: bool = false, // Benchmark mode: skip bridge setup for fastest window creation
};

// Helper functions for Objective-C runtime
pub fn getClass(name: [*:0]const u8) objc.Class {
    return objc.objc_getClass(name);
}

pub fn sel(name: [*:0]const u8) objc.SEL {
    return objc.sel_registerName(name);
}

// Simple message send wrappers
pub fn msgSend0(target: anytype, selector: [*:0]const u8) objc.id {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector));
}

pub fn msgSend1(target: anytype, selector: [*:0]const u8, arg1: anytype) objc.id {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1)) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector), arg1);
}

pub fn msgSend2(target: anytype, selector: [*:0]const u8, arg1: anytype, arg2: anytype) objc.id {
    const Arg1Type = if (@TypeOf(arg1) == @TypeOf(null)) ?*anyopaque else @TypeOf(arg1);
    const Arg2Type = if (@TypeOf(arg2) == @TypeOf(null)) ?*anyopaque else @TypeOf(arg2);
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, Arg1Type, Arg2Type) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    const typed_arg1: Arg1Type = if (@TypeOf(arg1) == @TypeOf(null)) null else arg1;
    const typed_arg2: Arg2Type = if (@TypeOf(arg2) == @TypeOf(null)) null else arg2;
    return msg(target, sel(selector), typed_arg1, typed_arg2);
}

pub fn msgSend4(target: anytype, selector: [*:0]const u8, arg1: anytype, arg2: anytype, arg3: anytype, arg4: anytype) objc.id {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1), @TypeOf(arg2), @TypeOf(arg3), @TypeOf(arg4)) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector), arg1, arg2, arg3, arg4);
}

fn makeWindowTranslucent(window: objc.id) void {
    if (window == null) return;

    const clearColor = msgSend0(getClass("NSColor"), "clearColor");
    _ = msgSend1(window, "setOpaque:", @as(c_int, 0));
    _ = msgSend1(window, "setBackgroundColor:", clearColor);
}

fn makeViewLayerTransparent(view: objc.id) void {
    if (view == null) return;

    _ = msgSend1(view, "setWantsLayer:", @as(c_int, 1));
    const layer = msgSend0(view, "layer");
    if (layer != null) {
        const clearColor = msgSend0(getClass("NSColor"), "clearColor");
        const clearCGColor = msgSend0(clearColor, "CGColor");
        if (clearCGColor != null) {
            _ = msgSend1(layer, "setBackgroundColor:", clearCGColor);
        }
    }
}

fn makeWebViewTransparent(webview: objc.id) void {
    if (webview == null) return;

    _ = msgSend1(webview, "setOpaque:", @as(c_int, 0));

    const NSNumber = getClass("NSNumber");
    const drawsBackgroundKey = createNSString("drawsBackground");
    const noValue = msgSend1(NSNumber, "numberWithBool:", @as(c_int, 0));
    msgSendVoid2(webview, "setValue:forKey:", noValue, drawsBackgroundKey);
    makeViewLayerTransparent(webview);

    const canAccessScrollView = msgSend1(webview, "respondsToSelector:", sel("scrollView"));
    if (@intFromPtr(canAccessScrollView) != 0) {
        const scrollView = msgSend0(webview, "scrollView");
        if (scrollView == null) return;

        _ = msgSend1(scrollView, "setDrawsBackground:", @as(c_int, 0));
        _ = msgSend1(scrollView, "setBackgroundColor:", msgSend0(getClass("NSColor"), "clearColor"));
    }
}

fn createAppearance(name: []const u8) objc.id {
    const NSAppearance = getClass("NSAppearance");
    if (NSAppearance == null) return null;

    return msgSend1(NSAppearance, "appearanceNamed:", createNSString(name));
}

fn setViewAppearance(view: objc.id, name: []const u8) void {
    if (view == null) return;
    const appearance = createAppearance(name);
    if (appearance != null) {
        _ = msgSend1(view, "setAppearance:", appearance);
    }
}

fn createSidebarVisualEffectView(frame: NSRect, corner_radius: f64) objc.id {
    const NSVisualEffectView = getClass("NSVisualEffectView");
    if (NSVisualEffectView == null) return null;

    const effect_alloc = msgSend0(NSVisualEffectView, "alloc");
    const effect = msgSend1Rect(effect_alloc, "initWithFrame:", frame);
    if (effect == null) return null;

    _ = msgSend1(effect, "setMaterial:", @as(c_long, 7)); // NSVisualEffectMaterialSidebar
    _ = msgSend1(effect, "setBlendingMode:", @as(c_long, 0)); // NSVisualEffectBlendingModeBehindWindow
    _ = msgSend1(effect, "setState:", @as(c_long, 1)); // NSVisualEffectStateActive
    msgSendVoid1(effect, "setAutoresizingMask:", @as(c_ulong, 2 | 16));

    _ = msgSend1(effect, "setWantsLayer:", @as(c_int, 1));
    const layer = msgSend0(effect, "layer");
    if (layer != null) {
        _ = msgSend1(layer, "setCornerRadius:", corner_radius);
        _ = msgSend1(layer, "setMasksToBounds:", @as(c_int, 1));
    }

    return effect;
}

fn createColor(red: f64, green: f64, blue: f64, alpha: f64) objc.id {
    const NSColor = getClass("NSColor");
    if (NSColor == null) return null;

    return msgSend4Double(NSColor, "colorWithCalibratedRed:green:blue:alpha:", red, green, blue, alpha);
}

fn createTintedView(frame: NSRect, color: objc.id) objc.id {
    if (color == null) return null;

    const NSView = getClass("NSView");
    const view_alloc = msgSend0(NSView, "alloc");
    const view = msgSend1Rect(view_alloc, "initWithFrame:", frame);
    if (view == null) return null;

    msgSendVoid1(view, "setAutoresizingMask:", @as(c_ulong, 2 | 16));
    _ = msgSend1(view, "setWantsLayer:", @as(c_int, 1));

    const layer = msgSend0(view, "layer");
    if (layer != null) {
        const cgColor = msgSend0(color, "CGColor");
        if (cgColor != null) {
            _ = msgSend1(layer, "setBackgroundColor:", cgColor);
        }
    }

    return view;
}

fn createLightSidebarMaterialTint(frame: NSRect, opacity: f64) objc.id {
    const clampedOpacity = if (opacity < 0.0) 0.0 else if (opacity > 1.0) 1.0 else opacity;
    const color = createColor(246.0 / 255.0, 246.0 / 255.0, 244.0 / 255.0, clampedOpacity);
    return createTintedView(frame, color);
}

fn createSidebarMaterialTint(frame: NSRect, opacity: f64) objc.id {
    const clampedOpacity = if (opacity < 0.0) 0.0 else if (opacity > 1.0) 1.0 else opacity;
    const color = switch (sidebar_material_scheme) {
        .light => createColor(246.0 / 255.0, 246.0 / 255.0, 244.0 / 255.0, clampedOpacity),
        .dark => createColor(24.0 / 255.0, 24.0 / 255.0, 23.0 / 255.0, clampedOpacity),
        .system => blk: {
            const backgroundColor = msgSend0(getClass("NSColor"), "windowBackgroundColor");
            break :blk msgSend1Double(backgroundColor, "colorWithAlphaComponent:", clampedOpacity);
        },
    };
    return createTintedView(frame, color);
}

fn createWebContentSurface(frame: NSRect, sidebar_width: u32) objc.id {
    const sidebarWidth = @as(f64, @floatFromInt(sidebar_width));
    if (frame.size.width <= sidebarWidth) return null;

    const contentFrame = NSRect{
        .origin = .{ .x = sidebarWidth, .y = 0 },
        .size = .{ .width = frame.size.width - sidebarWidth, .height = frame.size.height },
    };
    const color = createColor(1.0, 1.0, 1.0, 1.0);
    const surface = createTintedView(contentFrame, color);
    if (surface != null) {
        msgSendVoid1(surface, "setAutoresizingMask:", @as(c_ulong, 2 | 16));
    }
    return surface;
}

fn createWebSidebarMaterialBackdrop(frame: NSRect, sidebar_width: u32, material_opacity: f64) objc.id {
    const NSView = getClass("NSView");
    const container_alloc = msgSend0(NSView, "alloc");
    const container = msgSend1Rect(container_alloc, "initWithFrame:", frame);
    if (container == null) return null;

    msgSendVoid1(container, "setAutoresizingMask:", @as(c_ulong, 2 | 16));
    makeViewLayerTransparent(container);
    web_sidebar_material_container = container;
    web_sidebar_width_stored = @as(f64, @floatFromInt(sidebar_width));

    const sidebarFrame = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @as(f64, @floatFromInt(sidebar_width)), .height = frame.size.height },
    };

    const contentSurface = createWebContentSurface(frame, sidebar_width);
    if (contentSurface != null) {
        web_sidebar_content_surface = contentSurface;
        _ = msgSend1(container, "addSubview:", contentSurface);
    }

    const material = createSidebarVisualEffectView(sidebarFrame, 0.0);
    if (material != null) {
        setViewAppearance(material, "NSAppearanceNameVibrantLight");
        msgSendVoid1(material, "setAutoresizingMask:", @as(c_ulong, 16));
        web_sidebar_material_view = material;
        _ = msgSend1(container, "addSubview:", material);
    }

    const overlay = createLightSidebarMaterialTint(sidebarFrame, material_opacity);
    if (overlay != null) {
        web_sidebar_material_tint = overlay;
        _ = msgSend1(container, "addSubview:", overlay);
    }

    return container;
}

pub fn setWebSidebarCollapsed(collapsed: bool) void {
    if (web_sidebar_material_container == null) return;

    updateWebSidebarToggleButton(collapsed);

    const hidden = @as(c_int, if (collapsed) 1 else 0);
    if (web_sidebar_material_view != null) {
        _ = msgSend1(web_sidebar_material_view, "setHidden:", hidden);
    }
    if (web_sidebar_material_tint != null) {
        _ = msgSend1(web_sidebar_material_tint, "setHidden:", hidden);
    }

    if (web_sidebar_content_surface != null) {
        const bounds = msgSendRect(web_sidebar_material_container, "bounds");
        const sidebarWidth = if (collapsed) 0.0 else web_sidebar_width_stored;
        msgSendVoid1Rect(web_sidebar_content_surface, "setFrame:", .{
            .origin = .{ .x = sidebarWidth, .y = 0 },
            .size = .{ .width = bounds.size.width - sidebarWidth, .height = bounds.size.height },
        });
    }
}

pub fn msgSendVoid0(target: anytype, selector: [*:0]const u8) void {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, sel(selector));
}

pub fn msgSendVoid1(target: anytype, selector: [*:0]const u8, arg1: anytype) void {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1)) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, sel(selector), arg1);
}

fn msgSendVoid2(target: anytype, selector: [*:0]const u8, arg1: anytype, arg2: anytype) void {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1), @TypeOf(arg2)) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, sel(selector), arg1, arg2);
}

pub fn msgSend3(target: anytype, selector: [*:0]const u8, arg1: anytype, arg2: anytype, arg3: anytype) objc.id {
    const Arg1Type = if (@TypeOf(arg1) == @TypeOf(null)) ?*anyopaque else @TypeOf(arg1);
    const Arg2Type = if (@TypeOf(arg2) == @TypeOf(null)) ?*anyopaque else @TypeOf(arg2);
    const Arg3Type = if (@TypeOf(arg3) == @TypeOf(null)) ?*anyopaque else @TypeOf(arg3);
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, Arg1Type, Arg2Type, Arg3Type) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    const typed_arg1: Arg1Type = if (@TypeOf(arg1) == @TypeOf(null)) null else arg1;
    const typed_arg2: Arg2Type = if (@TypeOf(arg2) == @TypeOf(null)) null else arg2;
    const typed_arg3: Arg3Type = if (@TypeOf(arg3) == @TypeOf(null)) null else arg3;
    return msg(target, sel(selector), typed_arg1, typed_arg2, typed_arg3);
}

/// Message send with 2 args + NSRange (for addAttribute:value:range:)
pub fn msgSend3Range(target: anytype, selector: [*:0]const u8, arg1: anytype, arg2: anytype, range: NSRange) void {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(arg1), @TypeOf(arg2), NSRange) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, sel(selector), arg1, arg2, range);
}

/// Message send that returns NSRect (for methods like -frame)
pub fn msgSendRect(target: anytype, selector: [*:0]const u8) NSRect {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) NSRect, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector));
}

/// Message send that takes NSRect and returns NSRect (for methods like -contentRectForFrameRect:)
pub fn msgSendRect1Rect(target: anytype, selector: [*:0]const u8, rect: NSRect) NSRect {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, NSRect) callconv(.c) NSRect, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector), rect);
}

/// Message send that returns CGFloat (f64)
pub fn msgSendFloat(target: anytype, selector: [*:0]const u8) f64 {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) f64, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector));
}

/// Message send that returns bool
pub fn msgSendBool(target: anytype, selector: [*:0]const u8) bool {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) bool, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector));
}

/// Message send that returns NSInteger (c_long)
fn msgSendNSInteger(target: anytype, selector: [*:0]const u8) c_long {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) c_long, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector));
}

/// Message send returning unsigned long (for methods like sectionIndex, itemIndex)
fn msgSendULong(target: anytype, selector: [*:0]const u8) c_ulong {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) c_ulong, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector));
}

/// Message send with one bool argument
pub fn msgSend1Bool(target: anytype, selector: [*:0]const u8, arg1: bool) objc.id {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, bool) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector), arg1);
}

/// Message send with one f64 argument
pub fn msgSend1Double(target: anytype, selector: [*:0]const u8, arg1: f64) objc.id {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, f64) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector), arg1);
}

fn msgSend4Double(target: anytype, selector: [*:0]const u8, arg1: f64, arg2: f64, arg3: f64, arg4: f64) objc.id {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, f64, f64, f64, f64) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector), arg1, arg2, arg3, arg4);
}

/// Message send that returns f64 with no arguments
pub fn msgSend0Double(target: anytype, selector: [*:0]const u8) f64 {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) f64, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector));
}

/// Message send returning NSUInteger, e.g. `type` or `modifierFlags` on NSEvent
pub fn msgSend0Ulong(target: anytype, selector: [*:0]const u8) c_ulong {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) c_ulong, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector));
}

/// Message send with one NSUInteger argument (void return), e.g. `sendActionOn:`
pub fn msgSendVoid1Ulong(target: anytype, selector: [*:0]const u8, arg1: c_ulong) void {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, c_ulong) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, sel(selector), arg1);
}

/// Message send with one NSSize argument (void return), e.g. `setSize:`
pub fn msgSendVoid1Size(target: anytype, selector: [*:0]const u8, size: NSSize) void {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, NSSize) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, sel(selector), size);
}

/// Message send for `configurationWithPointSize:weight:scale:` — two doubles and
/// an integer, which arm64 passes in different register banks, so the signature
/// has to be spelled out rather than reusing a generic wrapper.
pub fn msgSendSymbolConfiguration(target: anytype, selector: [*:0]const u8, point_size: f64, weight: f64, scale: c_long) objc.id {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, f64, f64, c_long) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector), point_size, weight, scale);
}

/// Message send with one NSRect argument (void return)
pub fn msgSendVoid1Rect(target: anytype, selector: [*:0]const u8, rect: NSRect) void {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, NSRect) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    msg(target, sel(selector), rect);
}

/// Message send with NSRect + 2 f64 arguments (for bezierPathWithRoundedRect:xRadius:yRadius:)
fn msgSendRect2Double(target: anytype, selector: [*:0]const u8, rect: NSRect, arg1: f64, arg2: f64) objc.id {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, NSRect, f64, f64) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector), rect, arg1, arg2);
}

/// Parse hex color string (e.g. "#ef4444" or "ef4444") and create NSColor
pub fn createColorFromHex(hex_str: []const u8) ?objc.id {
    // Skip leading # if present
    const hex = if (hex_str.len > 0 and hex_str[0] == '#') hex_str[1..] else hex_str;

    // Must be 6 characters (RRGGBB)
    if (hex.len != 6) return null;

    // Parse hex components
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;

    // Convert to 0.0-1.0 range
    const rf: f64 = @as(f64, @floatFromInt(r)) / 255.0;
    const gf: f64 = @as(f64, @floatFromInt(g)) / 255.0;
    const bf: f64 = @as(f64, @floatFromInt(b)) / 255.0;

    // Create NSColor using colorWithRed:green:blue:alpha:
    const NSColor = getClass("NSColor");
    const color = msgSend4(NSColor, "colorWithRed:green:blue:alpha:", rf, gf, bf, @as(f64, 1.0));

    return color;
}

// Custom borderless window class that can become key window
var BorderlessWindowClass: objc.Class = null;

fn getBorderlessWindowClass() objc.Class {
    if (BorderlessWindowClass != null) return BorderlessWindowClass;

    const NSWindow = getClass("NSWindow");
    BorderlessWindowClass = objc.objc_allocateClassPair(NSWindow, "CraftBorderlessWindow", 0);

    if (BorderlessWindowClass == null) {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Window] Failed to create CraftBorderlessWindow class\n", .{});
        return NSWindow;
    }

    // Override canBecomeKeyWindow to return YES
    const canBecomeKey = struct {
        fn impl(_: objc.id, _: objc.SEL) callconv(.c) bool {
            return true;
        }
    }.impl;
    _ = objc.class_addMethod(BorderlessWindowClass, sel("canBecomeKeyWindow"), @ptrCast(@constCast(&canBecomeKey)), "B@:");

    // Override canBecomeMainWindow to return YES
    const canBecomeMain = struct {
        fn impl(_: objc.id, _: objc.SEL) callconv(.c) bool {
            return true;
        }
    }.impl;
    _ = objc.class_addMethod(BorderlessWindowClass, sel("canBecomeMainWindow"), @ptrCast(@constCast(&canBecomeMain)), "B@:");

    objc.objc_registerClassPair(BorderlessWindowClass);

    return BorderlessWindowClass;
}

pub fn createWindow(title: []const u8, width: u32, height: u32, html: []const u8) !objc.id {
    return createWindowWithStyle(title, width, height, html, null, .{});
}

pub fn createWindowWithHTML(title: []const u8, width: u32, height: u32, html: []const u8, style: WindowStyle) !objc.id {
    return createWindowWithStyle(title, width, height, html, null, style);
}

pub fn createWindowWithURL(title: []const u8, width: u32, height: u32, url: []const u8, style: WindowStyle) !objc.id {
    return createWindowWithStyle(title, width, height, null, url, style);
}

pub fn createWindowWithStyle(title: []const u8, width: u32, height: u32, html: ?[]const u8, url: ?[]const u8, style: WindowStyle) !objc.id {
    // Get classes (skip unnecessary lookups in benchmark mode)
    const NSWindow = getClass("NSWindow");
    const NSString = getClass("NSString");
    const WKWebView = getClass("WKWebView");
    const WKPreferences = if (!style.benchmark) getClass("WKPreferences") else null;
    const WKWebViewConfiguration = getClass("WKWebViewConfiguration");
    const WKUserContentController = if (!style.benchmark) getClass("WKUserContentController") else null;

    // Note: Activation policy is set in initApp(), NOT here!

    // Create window frame
    const frame = NSRect{
        .origin = .{
            .x = if (style.x) |x| @as(f64, @floatFromInt(x)) else 100,
            .y = if (style.y) |y| @as(f64, @floatFromInt(y)) else 100,
        },
        .size = .{ .width = @as(f64, @floatFromInt(width)), .height = @as(f64, @floatFromInt(height)) },
    };

    // Build style mask based on options
    var styleMask: c_ulong = 1; // NSTitledWindowMask
    if (!style.frameless) {
        if (style.closable) styleMask |= 2; // NSClosableWindowMask
        if (style.miniaturizable) styleMask |= 4; // NSMiniaturizableWindowMask
        if (style.resizable) styleMask |= 8; // NSResizableWindowMask

        // Add full-size content view for hidden titlebar
        if (style.titlebar_hidden) {
            styleMask |= 32768; // NSWindowStyleMaskFullSizeContentView
        }
    } else {
        // Borderless window - use NSWindowStyleMaskBorderless (0)
        // Combined with NSWindowStyleMaskNonactivatingPanel behavior workaround
        styleMask = 0;
    }

    const backing: c_ulong = 2; // NSBackingStoreBuffered
    const defer_flag: bool = false;

    // For borderless windows, use custom class that can become key window
    const WindowClass = if (style.frameless) getBorderlessWindowClass() else NSWindow;

    // Allocate and initialize window
    const window_alloc = msgSend0(WindowClass, "alloc");
    const window = msgSend4(window_alloc, "initWithContentRect:styleMask:backing:defer:", frame, styleMask, backing, defer_flag);

    // Create title NSString
    const title_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title);
    defer std.heap.c_allocator.free(title_cstr);
    const title_str_alloc = msgSend0(NSString, "alloc");
    const title_str = msgSend1(title_str_alloc, "initWithUTF8String:", title_cstr.ptr);

    // Set window title
    _ = msgSend1(window, "setTitle:", title_str);
    startup_timing.mark(.window_created);

    if (style.web_sidebar_material) {
        setViewAppearance(window, "NSAppearanceNameAqua");
    }

    // Configure transparency
    if (style.transparent) {
        _ = msgSend1(window, "setOpaque:", false);
        _ = msgSend1(window, "setBackgroundColor:", msgSend0(getClass("NSColor"), "clearColor"));
    }

    // For frameless/borderless windows, ensure they can receive mouse events
    if (style.frameless) {
        // Accept mouse moved events
        _ = msgSend1(window, "setAcceptsMouseMovedEvents:", true);
        // Make sure the window can become key (receive keyboard/mouse input)
        _ = msgSend1(window, "setMovableByWindowBackground:", false);
    }

    // Configure always on top
    if (style.always_on_top) {
        const NSFloatingWindowLevel: c_int = 3;
        _ = msgSend1(window, "setLevel:", NSFloatingWindowLevel);
    }

    // A web-sidebar-material window draws its own chrome row into the theme
    // frame, starting 68pt right of the close button — and AppKit puts the
    // window title at x = 82. Left visible, the title prints underneath that
    // row. Hiding it is the whole fix; the rest of the titlebar treatment below
    // must NOT follow, because `setTitlebarAppearsTransparent:` hides
    // NSTitlebarBackgroundView, and on a window that did not also ask for
    // `titlebar_hidden` the content view stops 32pt short of the top, so with
    // the non-opaque background craft sets further down there would be nothing
    // left to paint that strip: a see-through hole where the titlebar was.
    if (style.web_sidebar_material and !style.titlebar_hidden) {
        _ = msgSend1(window, "setTitleVisibility:", @as(c_int, 1)); // NSWindowTitleHidden
    }

    // Configure titlebar transparency for full-size content view
    if (style.titlebar_hidden) {
        _ = msgSend1(window, "setTitlebarAppearsTransparent:", @as(c_int, 1)); // YES

        // CRITICAL: Hide the title text (NSWindowTitleHidden = 1)
        _ = msgSend1(window, "setTitleVisibility:", @as(c_int, 1)); // NSWindowTitleHidden

        // CRITICAL: Remove the titlebar separator line (NSWindowTitlebarSeparatorStyleNone = 2)
        // This makes the titlebar truly invisible - required for macOS Tahoe/Settings look
        _ = msgSend1(window, "setTitlebarSeparatorStyle:", @as(c_long, 2)); // NSWindowTitlebarSeparatorStyleNone

        // The traffic lights are left where AppKit puts them, deliberately.
        //
        // This block used to call `setFrameOrigin:` on each standard window
        // button — 20/40/60 across, `height - 28` up — and none of it had any
        // effect. Proven by experiment rather than argued: rebuilding with
        // 60/80/100 and measuring the rendered window at 2x produced pixel-
        // identical output. AppKit re-lays out the standard buttons after
        // window configuration, so a one-shot origin set at creation is
        // overwritten before anything is drawn. Moving them for real needs a
        // layout hook — an NSWindow subclass, or a titlebar accessory view —
        // not three messages here.
        //
        // What the system actually draws, measured on a titlebar-hidden window:
        // 12pt discs, 20pt apart, the leftmost 10pt from the window's left
        // edge and 8pt below its top. That is macOS's own placement for this
        // style, so an app that hides its titlebar still gets real, correctly
        // positioned window controls — which is the point.
        //
        // A web sidebar that wants to reserve room for them should do it in
        // its own layout. `@stacksjs/components`' SidebarHeader takes
        // `windowControls="native"` for exactly this.
    }

    // Configure toolbar style and vibrancy (skip in benchmark mode for faster startup)
    if (!style.benchmark) {
        // NSWindowToolbarStyleUnified = 1 - Creates unified toolbar that works with glass materials
        _ = msgSend1(window, "setToolbarStyle:", @as(c_long, 1));

        // Configure window for vibrancy - allow NSVisualEffectView to show through
        _ = msgSend1(window, "setOpaque:", @as(c_int, 0)); // NO - window is not opaque
        const clearColor = msgSend0(getClass("NSColor"), "clearColor");
        _ = msgSend1(window, "setBackgroundColor:", clearColor);
    }

    // Create WebView configuration
    const config_alloc = msgSend0(WKWebViewConfiguration, "alloc");
    const config = msgSend0(config_alloc, "init");

    // In benchmark mode, use bare default config (JS enabled by default, no bridge needed)
    if (!style.benchmark) {
        const prefs_alloc = msgSend0(WKPreferences, "alloc");
        const prefs = msgSend0(prefs_alloc, "init");

        // Enable JavaScript explicitly (should be enabled by default, but let's be explicit)
        msgSendVoid1(prefs, "setJavaScriptEnabled:", true);

        // Enable developer extras (DevTools) only when requested
        if (style.dev_tools) {
            const key_str = createNSString("developerExtrasEnabled");
            const value_obj = msgSend1(msgSend0(getClass("NSNumber"), "alloc"), "initWithBool:", true);
            msgSendVoid2(prefs, "setValue:forKey:", value_obj, key_str);
        }

        // Enable clipboard access only when dev tools / full features are enabled
        if (style.dev_tools) {
            const clipboard_key = createNSString("javaScriptCanAccessClipboard");
            const clipboard_value = msgSend1(msgSend0(getClass("NSNumber"), "alloc"), "initWithBool:", true);
            msgSendVoid2(prefs, "setValue:forKey:", clipboard_value, clipboard_key);
        }

        _ = msgSend1(config, "setPreferences:", prefs);

        // Note: allowsInlineMediaPlayback and mediaTypesRequiringUserActionForPlayback
        // are iOS-only properties and not available on macOS WKWebViewConfiguration

        // Set up user content controller for JavaScript bridge
        const userContentController = msgSend0(msgSend0(WKUserContentController, "alloc"), "init");

        // One injection path for both URL and HTML loads — see
        // `injectCraftScripts`. Scripts land at document-start and survive
        // navigation, which the old HTML-splicing path did not.
        injectCraftScripts(userContentController, .{
            .full_bridge = style.system_tray,
            .sidebar_bootstrap = style.web_sidebar_material,
            // Also for a web-sidebar window, not only a native one.
            //
            // The surface used to be sidebar-only — createSidebar,
            // createFileBrowser, createSplitView — so gating it on
            // `native_sidebar` was exactly right. `createSpacesSidebar` broke
            // that assumption: it puts a segmented control in the *titlebar*
            // while the web keeps rendering the spaces, which is precisely the
            // `web_sidebar_material` case. Leaving the old gate meant the one
            // window mode that wants a native space rail was the one mode that
            // could not reach it.
            .native_ui = style.native_sidebar or style.web_sidebar_material,
        });

        // Set up the script message handler
        setupScriptMessageHandler(userContentController) catch |err| {
            if (comptime builtin.mode == .debug)
                std.debug.print("[Bridge] Failed to setup message handler: {}\n", .{err});
        };

        _ = msgSend1(config, "setUserContentController:", userContentController);

        // Use non-persistent data store to avoid disk I/O overhead at startup
        const WKWebsiteDataStore = getClass("WKWebsiteDataStore");
        const nonPersistentStore = msgSend0(WKWebsiteDataStore, "nonPersistentDataStore");
        _ = msgSend1(config, "setWebsiteDataStore:", nonPersistentStore);

        // Suppress incremental rendering to reduce peak memory during page load
        msgSendVoid1(config, "setSuppressesIncrementalRendering:", true);
    }

    startup_timing.mark(.webview_config_built);

    // Create WKWebView with configuration
    const webview_alloc = msgSend0(WKWebView, "alloc");
    const webview = msgSend2(webview_alloc, "initWithFrame:configuration:", frame, config);
    startup_timing.mark(.webview_created);
    // Start the load before any cosmetic setup.
    //
    // `loadRequest:` hands the fetch to the networking and WebContent
    // processes immediately; everything below only matters once pixels exist.
    // Measured with `--timing`, the translucency, file-drop and UI-delegate
    // work between here and the load was ~50ms the network spent waiting on
    // work nothing was waiting for. Nothing can paint in between either, since
    // the run loop is not entered until later — so there is no flash to trade
    // for it.
    //
    // The bridge is unaffected: user scripts live on the content controller
    // inside `config`, which was built before the webview existed.
    // Load content - either URL or HTML
    if (url) |u| {
        // Load URL directly (no iframe!)
        const url_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, u);
        defer std.heap.c_allocator.free(url_cstr);
        const url_str_alloc = msgSend0(NSString, "alloc");
        const url_str = msgSend1(url_str_alloc, "initWithUTF8String:", url_cstr.ptr);

        const nsurl = msgSend1(getClass("NSURL"), "URLWithString:", url_str);
        const request = msgSend1(getClass("NSURLRequest"), "requestWithURL:", nsurl);
        _ = msgSend1(webview, "loadRequest:", request);
        startup_timing.mark(.load_started);
    } else if (html) |h| {
        if (style.benchmark) {
            // Benchmark mode: load raw HTML directly without bridge injection or ArrayList
            const html_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, h);
            defer std.heap.c_allocator.free(html_cstr);
            const html_str = msgSend1(msgSend0(NSString, "alloc"), "initWithUTF8String:", html_cstr.ptr);
            _ = msgSend2(webview, "loadHTMLString:baseURL:", html_str, @as(?*anyopaque, null));
        } else {
            // The bridge is already installed on the content controller as a
            // document-start user script, so the HTML loads unmodified.
            const html_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, h);
            defer std.heap.c_allocator.free(html_cstr);
            const html_str_alloc = msgSend0(NSString, "alloc");
            const html_str = msgSend1(html_str_alloc, "initWithUTF8String:", html_cstr.ptr);

            // A real baseURL matters twice over: without one, body scripts may
            // not execute, `evaluateJavaScript` from native code is restricted,
            // and `WKUserScript` injection into `loadHTMLString:` is unreliable.
            const base_url_string = createNSString("http://localhost/");
            const base_url = msgSend1(getClass("NSURL"), "URLWithString:", base_url_string);

            _ = msgSend2(webview, "loadHTMLString:baseURL:", html_str, base_url);
        }
    }

    // Cosmetic and lazily-needed setup, now overlapping the fetch.
    const wants_translucent_surface = style.transparent or style.titlebar_hidden or style.native_sidebar or style.web_sidebar_material;
    if (!style.benchmark and wants_translucent_surface) {
        makeWindowTranslucent(window);
        makeWebViewTransparent(webview);
    }

    // Install the native file-drop hook so JS gets real filesystem paths.
    // No-op in benchmark mode (no JS bridge to deliver to anyway).
    if (!style.benchmark) {
        @import("macos_file_drop.zig").install();
    }

    // Set up UI delegate for camera/microphone permission handling (skip if not needed)
    if (style.dev_tools) {
        setupUIDelegate(webview) catch |err| {
            if (comptime builtin.mode == .debug)
                std.debug.print("[Media] Failed to setup UI delegate: {}\n", .{err});
        };
    }

    // Not gated on dev_tools: whether the inspector is available and whether a
    // local certificate is trusted are unrelated questions. Before the load
    // below, so it is in place for the first request's challenge.
    setupNavigationDelegate(webview) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Nav] Failed to setup navigation delegate: {}\n", .{err});
    };

    if (style.benchmark) {
        // Benchmark mode: minimal setup — just set content view and return
        _ = msgSend1(window, "setContentView:", webview);
    } else {
        // CRITICAL FIX: Get the proper content rect BEFORE setting webview as content view
        // The window's frame includes the titlebar area, but the content view should only
        // fill the content area. We need to calculate the proper content rect.

        // Get the window's content rect (the area below the titlebar)
        const windowFrame: NSRect = msgSendRect(window, "frame");
        const contentRect: NSRect = msgSendRect1Rect(window, "contentRectForFrameRect:", windowFrame);

        if (comptime builtin.mode == .debug) {
            std.debug.print("[WebView] Window frame: {d}x{d}, Content rect: {d}x{d}\n", .{
                windowFrame.size.width,
                windowFrame.size.height,
                contentRect.size.width,
                contentRect.size.height,
            });
        }

        // Create the proper frame for the WebView - it should fill the content area
        // The origin should be (0, 0) relative to the content view
        const webviewSize = if (style.titlebar_hidden or style.web_sidebar_material) frame.size else contentRect.size;
        const webviewFrame = NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = webviewSize,
        };

        // Set the WebView's frame to the content area size
        msgSendVoid1Rect(webview, "setFrame:", webviewFrame);

        // Also set autoresizing mask to resize with window
        // NSViewWidthSizable = 2, NSViewHeightSizable = 16
        msgSendVoid1(webview, "setAutoresizingMask:", @as(c_ulong, 2 | 16));

        if (style.web_sidebar_material) {
            const materialContainer = createWebSidebarMaterialBackdrop(webviewFrame, style.web_sidebar_width, style.web_sidebar_material_opacity);
            if (materialContainer != null) {
                _ = msgSend1(materialContainer, "addSubview:", webview);
                _ = msgSend1(window, "setContentView:", materialContainer);
            } else {
                _ = msgSend1(window, "setContentView:", webview);
            }
        } else {
            // Now set webview as content view
            _ = msgSend1(window, "setContentView:", webview);
        }

        // Store webview and window references globally
        if (webview) |wv| {
            setGlobalWebView(wv);
            if (style.web_sidebar_material) {
                addWebSidebarChromeControls(window, wv);
            }
            // Also set references for tray menu actions
            const tray_menu = @import("tray_menu.zig");
            tray_menu.setGlobalWebView(wv);
            if (window) |win| {
                tray_menu.setGlobalWindow(win);
            }
        }

        // Setup bridge handlers (need allocator and handles)
        const allocator = std.heap.c_allocator;
        setupBridgeHandlers(allocator, null, window) catch |err| {
            if (comptime builtin.mode == .debug)
                std.debug.print("[Bridge] Failed to setup bridge handlers: {}\n", .{err});
        };

        // Apply dark mode if specified
        if (style.dark_mode) |is_dark| {
            setAppearance(window, is_dark);
        }

        // Center window if no custom position specified
        if (style.x == null or style.y == null) {
            msgSendVoid0(window, "center");
        }

        // Enter fullscreen if requested
        if (style.fullscreen) {
            msgSendVoid0(window, "toggleFullScreen:");
        }
    }

    // DON'T show window here - it will be shown in runApp() after system tray is created
    // This is critical: makeKeyAndOrderFront activates the app, which must happen AFTER
    // the system tray is created for the menubar item to appear
    // _ = msgSend1(window, "makeKeyAndOrderFront:", @as(?*anyopaque, null));

    return window;
}

// ============================================================================
// Native Sidebar Support (NSSplitViewController + NSVisualEffectView)
// ============================================================================

/// Sidebar item for native NSOutlineView
pub const SidebarItem = struct {
    id: []const u8,
    label: []const u8,
    icon: ?[]const u8 = null, // SF Symbol name
    badge: ?[]const u8 = null,
    tint_color: ?[]const u8 = null, // Hex color for tags
    children: ?[]const SidebarItem = null,
    is_section_header: bool = false,
};

// Global storage for sidebar data source class
var sidebarDataSourceClass: objc.Class = null;

/// Setup a simple data source for the sidebar outline view
/// Returns an Objective-C object that implements NSOutlineViewDataSource and NSOutlineViewDelegate
fn setupSidebarDataSource() !objc.id {
    const NSObject = getClass("NSObject");
    const className = "CraftSidebarDataSource";

    // Check if class already exists
    if (sidebarDataSourceClass == null) {
        sidebarDataSourceClass = objc.objc_getClass(className);
    }

    if (sidebarDataSourceClass == null) {
        if (comptime builtin.mode == .debug)
            std.debug.print("[NativeSidebar] Creating data source class...\n", .{});

        // Create the class
        sidebarDataSourceClass = objc.objc_allocateClassPair(NSObject, className, 0);
        if (sidebarDataSourceClass == null) {
            return error.ClassCreationFailed;
        }

        // Add NSOutlineViewDataSource methods
        // outlineView:numberOfChildrenOfItem:
        _ = objc.class_addMethod(
            sidebarDataSourceClass,
            sel("outlineView:numberOfChildrenOfItem:"),
            @ptrCast(@constCast(&sidebarNumberOfChildren)),
            "l@:@@",
        );

        // outlineView:child:ofItem:
        _ = objc.class_addMethod(
            sidebarDataSourceClass,
            sel("outlineView:child:ofItem:"),
            @ptrCast(@constCast(&sidebarChildOfItem)),
            "@@:@l@",
        );

        // outlineView:isItemExpandable:
        _ = objc.class_addMethod(
            sidebarDataSourceClass,
            sel("outlineView:isItemExpandable:"),
            @ptrCast(@constCast(&sidebarIsItemExpandable)),
            "B@:@@",
        );

        // NSOutlineViewDelegate method for view-based outline
        // outlineView:viewForTableColumn:item:
        _ = objc.class_addMethod(
            sidebarDataSourceClass,
            sel("outlineView:viewForTableColumn:item:"),
            @ptrCast(@constCast(&sidebarViewForItem)),
            "@@:@@@",
        );

        // outlineView:isGroupItem:
        _ = objc.class_addMethod(
            sidebarDataSourceClass,
            sel("outlineView:isGroupItem:"),
            @ptrCast(@constCast(&sidebarIsGroupItem)),
            "B@:@@",
        );

        // outlineViewSelectionDidChange: - Handle selection events
        _ = objc.class_addMethod(
            sidebarDataSourceClass,
            sel("outlineViewSelectionDidChange:"),
            @ptrCast(@constCast(&sidebarSelectionDidChange)),
            "v@:@",
        );

        // outlineView:shouldSelectItem: - Prevent selection of section headers
        _ = objc.class_addMethod(
            sidebarDataSourceClass,
            sel("outlineView:shouldSelectItem:"),
            @ptrCast(@constCast(&sidebarShouldSelectItem)),
            "B@:@@",
        );

        // outlineView:rowViewForItem: - Return custom row view for Finder-style selection
        _ = objc.class_addMethod(
            sidebarDataSourceClass,
            sel("outlineView:rowViewForItem:"),
            @ptrCast(@constCast(&sidebarRowViewForItem)),
            "@@:@@",
        );

        objc.objc_registerClassPair(sidebarDataSourceClass);
        if (comptime builtin.mode == .debug)
            std.debug.print("[NativeSidebar] Data source class registered\n", .{});
    }

    // Create instance
    const instance = msgSend0(msgSend0(sidebarDataSourceClass, "alloc"), "init");
    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Data source instance created\n", .{});

    return instance;
}

// Dynamic sidebar data structures
const DynamicSidebarItem = struct {
    id: []const u8,
    label: []const u8,
    icon: []const u8,
    badge: ?[]const u8 = null,
    tint_color: ?[]const u8 = null,
    url: ?[]const u8 = null, // URL to navigate to when item is selected
};

const DynamicSidebarSection = struct {
    id: []const u8,
    title: []const u8,
    items: []DynamicSidebarItem,
    collapsed: bool = false,
};

// Global dynamic sidebar data (parsed from JSON config)
var dynamic_sections: ?[]DynamicSidebarSection = null;
var sidebar_allocator: ?std.mem.Allocator = null;
var sidebar_arena: ?std.heap.ArenaAllocator = null;

// Global WebView reference for sending sidebar events
var sidebar_webview: objc.id = null;

// Global references for sidebar toggle
var sidebar_container: objc.id = null;
var sidebar_content_webview: objc.id = null;
var sidebar_toggle_btn: objc.id = null;
var sidebar_collapsed: bool = false;
var sidebar_width_stored: f64 = 240.0;
var sidebar_uses_desktop_material: bool = false;
var sidebar_uses_shimmer: bool = false;
var sidebar_allows_vibrancy: bool = false;
var sidebar_material_opacity: f64 = 0.90;
var sidebar_material_scheme: SidebarMaterialScheme = .system;
var webChromeResponderClass: objc.Class = null;
var web_sidebar_material_container: objc.id = null;
var web_sidebar_material_view: objc.id = null;
var web_sidebar_material_tint: objc.id = null;
var web_sidebar_content_surface: objc.id = null;
var web_sidebar_toggle_button: objc.id = null;
var web_sidebar_width_stored: f64 = 286.0;

fn updateWebSidebarToggleButton(collapsed: bool) void {
    if (web_sidebar_toggle_button == null) return;

    const NSImage = getClass("NSImage");
    const symbolName = createNSString(if (collapsed) "sidebar.right" else "sidebar.left");
    const image = msgSend2(NSImage, "imageWithSystemSymbolName:accessibilityDescription:", symbolName, @as(?*anyopaque, null));
    if (image != null) {
        _ = msgSend1(web_sidebar_toggle_button, "setImage:", image);
    }
    _ = msgSend1(web_sidebar_toggle_button, "setToolTip:", createNSString(if (collapsed) "Expand Sidebar" else "Collapse Sidebar"));
}

const SidebarMaterialScheme = enum {
    system,
    light,
    dark,
};

// Default demo sections (used when no config provided)
const default_sections = [_]DynamicSidebarSection{
    .{
        .id = "favorites",
        .title = "Favorites",
        .items = @constCast(&[_]DynamicSidebarItem{
            .{ .id = "home", .label = "Home", .icon = "house.fill" },
            .{ .id = "documents", .label = "Documents", .icon = "folder.fill" },
            .{ .id = "downloads", .label = "Downloads", .icon = "arrow.down.circle.fill" },
        }),
    },
    .{
        .id = "icloud",
        .title = "iCloud",
        .items = @constCast(&[_]DynamicSidebarItem{
            .{ .id = "icloud-drive", .label = "iCloud Drive", .icon = "externaldrive.fill.badge.icloud" },
            .{ .id = "shared", .label = "Shared", .icon = "person.2.fill" },
        }),
    },
    .{
        .id = "tags",
        .title = "Tags",
        .items = @constCast(&[_]DynamicSidebarItem{
            .{ .id = "tag-red", .label = "Red", .icon = "circle.fill", .tint_color = "#ef4444" },
            .{ .id = "tag-blue", .label = "Blue", .icon = "circle.fill", .tint_color = "#3b82f6" },
            .{ .id = "tag-green", .label = "Green", .icon = "circle.fill", .tint_color = "#22c55e" },
        }),
    },
};

/// Get the current sidebar sections (dynamic or default)
fn getSidebarSections() []const DynamicSidebarSection {
    if (dynamic_sections) |sections| {
        return sections;
    }
    return &default_sections;
}

/// Parse JSON sidebar configuration
fn parseSidebarConfig(json: []const u8) !void {
    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Parsing sidebar config ({d} bytes)\n", .{json.len});

    if (sidebar_arena) |*arena| arena.deinit();
    sidebar_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    const allocator = sidebar_arena.?.allocator();
    sidebar_allocator = allocator;

    // Parse JSON using std.json
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[NativeSidebar] JSON parse error: {}\n", .{err});
        return err;
    };
    const root = parsed.value;
    if (root != .object) return error.InvalidSidebarConfig;
    if (root.object.get("variant")) |v| {
        sidebar_uses_desktop_material = switch (v) {
            .string => |s| std.mem.eql(u8, s, "desktop"),
            else => false,
        };
    } else {
        sidebar_uses_desktop_material = false;
    }
    if (root.object.get("backgroundEffect")) |v| {
        sidebar_uses_shimmer = switch (v) {
            .string => |s| std.mem.eql(u8, s, "shimmer"),
            else => false,
        };
    } else {
        sidebar_uses_shimmer = false;
    }
    if (root.object.get("allowsVibrancy")) |v| {
        sidebar_allows_vibrancy = switch (v) {
            .bool => |b| b,
            else => false,
        };
    } else {
        sidebar_allows_vibrancy = sidebar_uses_desktop_material or (if (root.object.get("backgroundEffect")) |v| switch (v) {
            .string => |s| std.mem.eql(u8, s, "vibrancy"),
            else => false,
        } else false);
    }
    if (root.object.get("materialOpacity")) |v| {
        sidebar_material_opacity = switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0.90,
        };
    } else {
        sidebar_material_opacity = 0.90;
    }
    if (root.object.get("materialScheme")) |v| {
        sidebar_material_scheme = switch (v) {
            .string => |s| if (std.mem.eql(u8, s, "light"))
                .light
            else if (std.mem.eql(u8, s, "dark"))
                .dark
            else
                .system,
            else => .system,
        };
    } else {
        sidebar_material_scheme = .system;
    }

    // Extract sections array
    const sections_json = root.object.get("sections") orelse {
        if (comptime builtin.mode == .debug)
            std.debug.print("[NativeSidebar] No 'sections' field in config\n", .{});
        return;
    };

    if (sections_json != .array) return error.InvalidSidebarConfig;
    const sections_array = sections_json.array;
    var sections: std.ArrayList(DynamicSidebarSection) = .empty;

    for (sections_array.items) |section_val| {
        if (section_val != .object) continue;
        const section_obj = section_val.object;

        // Get section fields
        const id = if (section_obj.get("id")) |v| if (v == .string) v.string else "section" else "section";
        const title = if (section_obj.get("title")) |v| if (v == .string) v.string else "Section" else if (section_obj.get("label")) |v| if (v == .string) v.string else "Section" else "Section";
        const collapsed = if (section_obj.get("collapsed")) |v| if (v == .bool) v.bool else false else false;

        // Parse items
        const items_json = section_obj.get("items") orelse continue;
        if (items_json != .array) continue;
        const items_array = items_json.array;
        var items: std.ArrayList(DynamicSidebarItem) = .empty;

        for (items_array.items) |item_val| {
            if (item_val != .object) continue;
            const item_obj = item_val.object;

            try items.append(allocator, .{
                .id = if (item_obj.get("id")) |v| if (v == .string) v.string else "item" else "item",
                .label = if (item_obj.get("label")) |v| if (v == .string) v.string else "Item" else "Item",
                .icon = if (item_obj.get("icon")) |v| if (v == .string) v.string else "doc" else "doc",
                .badge = if (item_obj.get("badge")) |v| switch (v) {
                    .string => |s| s,
                    .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}) catch null,
                    else => null,
                } else null,
                .tint_color = if (item_obj.get("tintColor")) |v| if (v == .string) v.string else null else null,
                .url = if (item_obj.get("url")) |v| if (v == .string) v.string else null else if (item_obj.get("href")) |v| if (v == .string) v.string else null else null,
            });
        }

        try sections.append(allocator, .{
            .id = id,
            .title = title,
            .items = try items.toOwnedSlice(allocator),
            .collapsed = collapsed,
        });
    }

    dynamic_sections = try sections.toOwnedSlice(allocator);
    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Parsed {d} sections from config\n", .{dynamic_sections.?.len});
}

// NSOutlineViewDataSource: numberOfChildrenOfItem
fn sidebarNumberOfChildren(
    _: objc.id,
    _: objc.SEL,
    _: objc.id, // outlineView
    item: objc.id,
) callconv(.c) c_long {
    const sections = getSidebarSections();

    // If item is nil, return number of sections
    if (item == null) {
        return @intCast(sections.len);
    }

    // Check if it's a section (NSNumber with section index)
    const isSection = msgSend1(item, "respondsToSelector:", sel("isSection"));
    if (@intFromPtr(isSection) != 0) {
        // It's a section wrapper, get the children count
        const idx: usize = @intCast(msgSendULong(item, "sectionIndex"));
        if (idx < sections.len) {
            return @intCast(sections[idx].items.len);
        }
    }

    // Regular items have no children
    return 0;
}

// NSOutlineViewDataSource: child:ofItem
fn sidebarChildOfItem(
    _: objc.id,
    _: objc.SEL,
    _: objc.id, // outlineView
    index: c_long,
    item: objc.id,
) callconv(.c) objc.id {
    const sections = getSidebarSections();
    const idx: usize = @intCast(index);

    // If item is nil, return section wrapper
    if (item == null) {
        if (idx >= sections.len) return null;
        return createSectionWrapper(idx);
    }

    // Check if it's a section
    const isSection = msgSend1(item, "respondsToSelector:", sel("isSection"));
    if (@intFromPtr(isSection) != 0) {
        const section_idx: usize = @intCast(msgSendULong(item, "sectionIndex"));
        if (section_idx < sections.len) {
            const section = &sections[section_idx];
            if (idx < section.items.len) {
                return createItemWrapper(section_idx, idx);
            }
        }
    }

    return null;
}

// NSOutlineViewDataSource: isItemExpandable
fn sidebarIsItemExpandable(
    _: objc.id,
    _: objc.SEL,
    _: objc.id, // outlineView
    item: objc.id,
) callconv(.c) bool {
    if (item == null) return false;

    // Sections are expandable
    const isSection = msgSend1(item, "respondsToSelector:", sel("isSection"));
    return @intFromPtr(isSection) != 0;
}

// NSOutlineViewDelegate: isGroupItem (for section headers)
// Returns true for sections to get the right-side disclosure chevron
fn sidebarIsGroupItem(
    _: objc.id,
    _: objc.SEL,
    _: objc.id, // outlineView
    item: objc.id,
) callconv(.c) bool {
    if (item == null) return false;

    // Sections are group items - this gives us the right-side chevron
    const isSection = msgSend1(item, "respondsToSelector:", sel("isSection"));
    return @intFromPtr(isSection) != 0;
}

// NSOutlineViewDelegate: selectionDidChange - Handle selection events
fn sidebarSelectionDidChange(
    _: objc.id,
    _: objc.SEL,
    notification: objc.id,
) callconv(.c) void {
    // Get the outline view from the notification
    const outlineView = msgSend0(notification, "object");
    if (outlineView == null) return;

    // Get selected row (returns NSInteger, can be -1 if no selection)
    const rowIndex = msgSendNSInteger(outlineView, "selectedRow");

    // -1 means no selection (NSNotFound or deselected)
    if (rowIndex < 0) return;

    // Get the item at the selected row
    const item = msgSend1(outlineView, "itemAtRow:", rowIndex);
    if (item == null) return;

    // Check if it's a section (we don't send events for sections)
    const isSection = msgSend1(item, "respondsToSelector:", sel("isSection"));
    if (@intFromPtr(isSection) != 0) return;

    // Get item indices
    const isItem = msgSend1(item, "respondsToSelector:", sel("itemIndex"));
    if (@intFromPtr(isItem) == 0) return;

    const section_idx: usize = @intCast(msgSendULong(item, "sectionIndex"));
    const item_idx: usize = @intCast(msgSendULong(item, "itemIndex"));

    const sections = getSidebarSections();
    if (section_idx >= sections.len) return;

    const section = &sections[section_idx];
    if (item_idx >= section.items.len) return;

    const child = &section.items[item_idx];

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Selection changed: section={s}, item={s}\n", .{ section.id, child.id });

    // Navigate via window.navigate() for SPA routing, or fall back to location.href.
    // If the item has a URL, use it directly. Otherwise construct from section/item IDs.
    if (sidebar_webview != null) {
        const allocator = std.heap.c_allocator;
        const generated_url = if (child.url == null)
            std.fmt.allocPrint(allocator, "/{s}/{s}", .{ section.id, child.id }) catch return
        else
            null;
        defer if (generated_url) |url| allocator.free(url);

        const url = child.url orelse generated_url.?;
        const js = javascript.buildNavigationScript(allocator, url) catch return;
        defer allocator.free(js);

        const js_str = createNSString(js);
        _ = msgSend2(sidebar_webview, "evaluateJavaScript:completionHandler:", js_str, @as(?*anyopaque, null));

        if (comptime builtin.mode == .debug)
            std.debug.print("[NativeSidebar] Navigate: section={s}, item={s}\n", .{ section.id, child.id });
    }
}

// NSOutlineViewDelegate: shouldSelectItem - Prevent section headers from being selected
fn sidebarShouldSelectItem(
    _: objc.id,
    _: objc.SEL,
    _: objc.id, // outlineView
    item: objc.id,
) callconv(.c) bool {
    if (item == null) return false;

    // Section headers (group items) should not be selectable
    const isSection = msgSend1(item, "respondsToSelector:", sel("isSection"));
    if (@intFromPtr(isSection) != 0) {
        return false; // Don't allow selection of section headers
    }

    return true; // Allow selection of regular items
}

// NSOutlineViewDelegate: viewForTableColumn:item
fn sidebarViewForItem(
    _: objc.id,
    _: objc.SEL,
    outlineView: objc.id,
    _: objc.id, // tableColumn
    item: objc.id,
) callconv(.c) objc.id {
    const NSTableCellView = getClass("NSTableCellView");
    const NSTextField = getClass("NSTextField");
    const NSImageView = getClass("NSImageView");
    const NSImage = getClass("NSImage");

    // Determine if this is a section or item
    const isSection = msgSend1(item, "respondsToSelector:", sel("isSection"));
    const isSectionItem = @intFromPtr(isSection) != 0;

    // Get the appropriate identifier
    const identifier = if (isSectionItem) createNSString("HeaderCell") else createNSString("DataCell");

    // Try to reuse a cell
    var cellView = msgSend2(outlineView, "makeViewWithIdentifier:owner:", identifier, @as(?*anyopaque, null));

    if (cellView == null) {
        // Create new cell view
        const cellFrame = NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 200, .height = 24 },
        };

        const cellAlloc = msgSend0(NSTableCellView, "alloc");
        cellView = msgSend1Rect(cellAlloc, "initWithFrame:", cellFrame);
        _ = msgSend1(cellView, "setIdentifier:", identifier);

        // Create text field with proper frame
        const textX: f64 = if (isSectionItem) 4.0 else 28.0; // Offset for icon
        const textFrame = NSRect{
            .origin = .{ .x = textX, .y = 2 },
            .size = .{ .width = 200 - textX - 4, .height = 20 },
        };

        const textField = msgSend1Rect(msgSend0(NSTextField, "alloc"), "initWithFrame:", textFrame);
        _ = msgSend1(textField, "setBezeled:", @as(c_int, 0));
        _ = msgSend1(textField, "setDrawsBackground:", @as(c_int, 0));
        _ = msgSend1(textField, "setEditable:", @as(c_int, 0));
        _ = msgSend1(textField, "setSelectable:", @as(c_int, 0));
        _ = msgSend1(textField, "setLineBreakMode:", @as(c_long, 4)); // NSLineBreakByTruncatingTail

        if (isSectionItem) {
            // Section header style - uppercase, smaller, muted light color
            const font = msgSend1(getClass("NSFont"), "boldSystemFontOfSize:", @as(f64, 11.0));
            _ = msgSend1(textField, "setFont:", font);
            // Light gray for section headers on dark background
            const sectionColor = msgSend4(getClass("NSColor"), "colorWithRed:green:blue:alpha:", @as(f64, 0.6), @as(f64, 0.6), @as(f64, 0.7), @as(f64, 1.0));
            _ = msgSend1(textField, "setTextColor:", sectionColor);
        } else {
            // Regular item style - WHITE text on dark background
            const font = msgSend1(getClass("NSFont"), "systemFontOfSize:", @as(f64, 13.0));
            _ = msgSend1(textField, "setFont:", font);
            const whiteColor = msgSend0(getClass("NSColor"), "whiteColor");
            _ = msgSend1(textField, "setTextColor:", whiteColor);
        }

        _ = msgSend1(cellView, "setTextField:", textField);
        _ = msgSend1(cellView, "addSubview:", textField);

        // Create image view for icons (only for non-section items)
        if (!isSectionItem) {
            const imageFrame = NSRect{
                .origin = .{ .x = 4, .y = 2 },
                .size = .{ .width = 20, .height = 20 },
            };
            const imageView = msgSend1Rect(msgSend0(NSImageView, "alloc"), "initWithFrame:", imageFrame);
            _ = msgSend1(cellView, "setImageView:", imageView);
            _ = msgSend1(cellView, "addSubview:", imageView);
        }

        // Set autoresizing
        msgSendVoid1(textField, "setAutoresizingMask:", @as(c_ulong, 2)); // Width flexible
    }

    // Get the text field and set the text
    const textField = msgSend0(cellView, "textField");
    const sections = getSidebarSections();

    // Always set text color (in case cell is reused from different type)
    if (isSectionItem) {
        // Section header - light gray text
        const sectionColor = msgSend4(getClass("NSColor"), "colorWithRed:green:blue:alpha:", @as(f64, 0.6), @as(f64, 0.6), @as(f64, 0.7), @as(f64, 1.0));
        const font = msgSend1(getClass("NSFont"), "boldSystemFontOfSize:", @as(f64, 11.0));

        const section_idx: usize = @intCast(msgSendULong(item, "sectionIndex"));
        if (section_idx < sections.len) {
            const section = &sections[section_idx];

            // Set font first
            _ = msgSend1(textField, "setFont:", font);

            // Set string value
            _ = msgSend1(textField, "setStringValue:", createNSString(section.title));

            // Force text color using multiple methods to ensure it sticks
            _ = msgSend1(textField, "setTextColor:", sectionColor);

            // Also try KVC which might bypass system overrides
            _ = msgSend2(textField, "setValue:forKey:", sectionColor, createNSString("textColor"));
        }
    } else {
        // Regular item - white text
        const whiteColor = msgSend0(getClass("NSColor"), "whiteColor");
        _ = msgSend1(textField, "setTextColor:", whiteColor);
        const font = msgSend1(getClass("NSFont"), "systemFontOfSize:", @as(f64, 13.0));
        _ = msgSend1(textField, "setFont:", font);
        const isItem = msgSend1(item, "respondsToSelector:", sel("itemIndex"));
        if (@intFromPtr(isItem) != 0) {
            const section_idx: usize = @intCast(msgSendULong(item, "sectionIndex"));
            const item_idx: usize = @intCast(msgSendULong(item, "itemIndex"));

            if (section_idx < sections.len) {
                const section = &sections[section_idx];
                if (item_idx < section.items.len) {
                    const child = &section.items[item_idx];
                    _ = msgSend1(textField, "setStringValue:", createNSString(child.label));

                    // Set the icon using SF Symbols
                    const imageView = msgSend0(cellView, "imageView");
                    if (imageView != null) {
                        const symbolName = createNSString(child.icon);
                        const image = msgSend2(NSImage, "imageWithSystemSymbolName:accessibilityDescription:", symbolName, @as(?*anyopaque, null));
                        if (image != null) {
                            _ = msgSend1(imageView, "setImage:", image);

                            // Apply tint color - use custom color or default to white
                            if (child.tint_color) |tint_hex| {
                                if (createColorFromHex(tint_hex)) |tintColor| {
                                    _ = msgSend1(imageView, "setContentTintColor:", tintColor);
                                }
                            } else {
                                // Default to white/light color for icons on dark background
                                const defaultIconColor = msgSend4(getClass("NSColor"), "colorWithRed:green:blue:alpha:", @as(f64, 0.85), @as(f64, 0.85), @as(f64, 0.9), @as(f64, 1.0));
                                _ = msgSend1(imageView, "setContentTintColor:", defaultIconColor);
                            }
                        }
                    }
                }
            }
        }
    }

    return cellView;
}

// Custom row view class for Finder-style selection
var sidebarRowViewClass: objc.Class = null;

fn getSidebarRowViewClass() objc.Class {
    if (sidebarRowViewClass != null) return sidebarRowViewClass;

    const NSTableRowView = getClass("NSTableRowView");
    sidebarRowViewClass = objc.objc_allocateClassPair(NSTableRowView, "CraftSidebarRowView", 0);

    if (sidebarRowViewClass == null) {
        if (comptime builtin.mode == .debug)
            std.debug.print("[NativeSidebar] Failed to create CraftSidebarRowView class\n", .{});
        return NSTableRowView;
    }

    // Override drawSelectionInRect: to draw custom selection
    _ = objc.class_addMethod(
        sidebarRowViewClass,
        sel("drawSelectionInRect:"),
        @ptrCast(@constCast(&rowViewDrawSelection)),
        "v@:{CGRect=dddd}",
    );

    // Override isEmphasized to return NO for subtle selection
    _ = objc.class_addMethod(
        sidebarRowViewClass,
        sel("isEmphasized"),
        @ptrCast(@constCast(&rowViewIsEmphasized)),
        "B@:",
    );

    // Override drawBackgroundInRect: to make row backgrounds transparent
    _ = objc.class_addMethod(
        sidebarRowViewClass,
        sel("drawBackgroundInRect:"),
        @ptrCast(@constCast(&rowViewDrawBackground)),
        "v@:{CGRect=dddd}",
    );

    objc.objc_registerClassPair(sidebarRowViewClass);
    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Custom row view class registered\n", .{});

    return sidebarRowViewClass;
}

// Custom drawing for selection - Finder-style subtle gray pill
fn rowViewDrawSelection(
    self: objc.id,
    _: objc.SEL,
    dirtyRect: NSRect,
) callconv(.c) void {
    _ = dirtyRect;

    // Only draw if selected
    const isSelected = msgSendBool(self, "isSelected");
    if (!isSelected) return;

    // Get the bounds
    const bounds = msgSendRect(self, "bounds");

    // Create an inset rounded rect for the selection - macOS Tahoe style
    // More horizontal padding for narrower pill appearance
    const horizontal_inset: f64 = 8.0; // Left/right padding
    const vertical_inset: f64 = 2.0; // Top/bottom padding
    const selectionRect = NSRect{
        .origin = .{ .x = horizontal_inset, .y = vertical_inset },
        .size = .{ .width = bounds.size.width - (horizontal_inset * 2), .height = bounds.size.height - (vertical_inset * 2) },
    };

    // Create NSBezierPath for rounded rect
    const NSBezierPath = getClass("NSBezierPath");
    const cornerRadius: f64 = 6.0;
    const path = msgSendRect2Double(NSBezierPath, "bezierPathWithRoundedRect:xRadius:yRadius:", selectionRect, cornerRadius, cornerRadius);

    // Set the fill color - subtle gray like Finder
    // Light mode: rgba(0, 0, 0, 0.06), Dark mode: rgba(255, 255, 255, 0.10)
    const NSColor = getClass("NSColor");

    // Use a color that works for both light and dark mode
    // This creates a subtle selection similar to Finder
    const fillColor = msgSend2(NSColor, "colorWithWhite:alpha:", @as(f64, 0.5), @as(f64, 0.12));

    _ = msgSend0(fillColor, "setFill");
    _ = msgSend0(path, "fill");
}

// Return NO for isEmphasized to get the subtle (non-key window) selection style
fn rowViewIsEmphasized(
    _: objc.id,
    _: objc.SEL,
) callconv(.c) bool {
    return false;
}

// Draw transparent background for row views
fn rowViewDrawBackground(
    _: objc.id,
    _: objc.SEL,
    _: NSRect,
) callconv(.c) void {
    // Do nothing - let the container background show through
}

// NSOutlineViewDelegate: rowViewForItem - Return custom row view
fn sidebarRowViewForItem(
    _: objc.id,
    _: objc.SEL,
    _: objc.id, // outlineView
    _: objc.id, // item
) callconv(.c) objc.id {
    const rowViewClass = getSidebarRowViewClass();
    const rowView = msgSend0(msgSend0(rowViewClass, "alloc"), "init");
    return rowView;
}

// Global class for section wrappers
var sidebarSectionWrapperClass: objc.Class = null;
var sidebarItemWrapperClass: objc.Class = null;

// Create a wrapper object for a section
fn createSectionWrapper(section_idx: usize) objc.id {
    if (sidebarSectionWrapperClass == null) {
        const NSObject = getClass("NSObject");
        sidebarSectionWrapperClass = objc.objc_allocateClassPair(NSObject, "CraftSidebarSectionWrapper", 0);

        // Add isSection method that returns YES
        _ = objc.class_addMethod(
            sidebarSectionWrapperClass,
            sel("isSection"),
            @ptrCast(@constCast(&wrapperIsSection)),
            "B@:",
        );

        // Add sectionIndex method
        _ = objc.class_addMethod(
            sidebarSectionWrapperClass,
            sel("sectionIndex"),
            @ptrCast(@constCast(&wrapperSectionIndex)),
            "L@:",
        );

        // Add ivar to store section index
        _ = objc.class_addIvar(sidebarSectionWrapperClass, "_sectionIdx", @sizeOf(usize), @alignOf(usize), "L");

        objc.objc_registerClassPair(sidebarSectionWrapperClass);
    }

    const instance = msgSend0(msgSend0(sidebarSectionWrapperClass, "alloc"), "init");

    // Store the section index using associated objects (simpler than ivar)
    const key = @as(*const anyopaque, @ptrCast(&sidebarSectionWrapperClass));
    const NSNumber = getClass("NSNumber");
    const idx_num = msgSend1(NSNumber, "numberWithUnsignedLong:", @as(c_ulong, section_idx));
    objc.objc_setAssociatedObject(instance, key, idx_num, objc.OBJC_ASSOCIATION_RETAIN);

    return instance;
}

// Create a wrapper object for an item
fn createItemWrapper(section_idx: usize, item_idx: usize) objc.id {
    if (sidebarItemWrapperClass == null) {
        const NSObject = getClass("NSObject");
        sidebarItemWrapperClass = objc.objc_allocateClassPair(NSObject, "CraftSidebarItemWrapper", 0);

        // Add itemIndex method
        _ = objc.class_addMethod(
            sidebarItemWrapperClass,
            sel("itemIndex"),
            @ptrCast(@constCast(&wrapperItemIndex)),
            "L@:",
        );

        // Add sectionIndex method
        _ = objc.class_addMethod(
            sidebarItemWrapperClass,
            sel("sectionIndex"),
            @ptrCast(@constCast(&wrapperItemSectionIndex)),
            "L@:",
        );

        objc.objc_registerClassPair(sidebarItemWrapperClass);
    }

    const instance = msgSend0(msgSend0(sidebarItemWrapperClass, "alloc"), "init");

    // Store indices using associated objects
    const section_key = @as(*const anyopaque, @ptrCast(&sidebarItemWrapperClass));
    const item_key = @as(*const anyopaque, @ptrFromInt(@intFromPtr(section_key) + 1));

    const NSNumber = getClass("NSNumber");
    const section_num = msgSend1(NSNumber, "numberWithUnsignedLong:", @as(c_ulong, section_idx));
    const item_num = msgSend1(NSNumber, "numberWithUnsignedLong:", @as(c_ulong, item_idx));

    objc.objc_setAssociatedObject(instance, section_key, section_num, objc.OBJC_ASSOCIATION_RETAIN);
    objc.objc_setAssociatedObject(instance, item_key, item_num, objc.OBJC_ASSOCIATION_RETAIN);

    return instance;
}

// Wrapper methods
fn wrapperIsSection(_: objc.id, _: objc.SEL) callconv(.c) bool {
    return true;
}

fn wrapperSectionIndex(self: objc.id, _: objc.SEL) callconv(.c) c_ulong {
    const key = @as(*const anyopaque, @ptrCast(&sidebarSectionWrapperClass));
    const num = objc.objc_getAssociatedObject(self, key);
    if (num == null) return 0;
    return msgSendULong(num, "unsignedLongValue");
}

fn wrapperItemIndex(self: objc.id, _: objc.SEL) callconv(.c) c_ulong {
    const section_key = @as(*const anyopaque, @ptrCast(&sidebarItemWrapperClass));
    const item_key = @as(*const anyopaque, @ptrFromInt(@intFromPtr(section_key) + 1));
    const num = objc.objc_getAssociatedObject(self, item_key);
    if (num == null) return 0;
    return msgSendULong(num, "unsignedLongValue");
}

fn wrapperItemSectionIndex(self: objc.id, _: objc.SEL) callconv(.c) c_ulong {
    const section_key = @as(*const anyopaque, @ptrCast(&sidebarItemWrapperClass));
    const num = objc.objc_getAssociatedObject(self, section_key);
    if (num == null) return 0;
    return msgSendULong(num, "unsignedLongValue");
}

/// Create a window with a native macOS sidebar (Finder-style)
/// This uses NSSplitViewController, NSVisualEffectView, and NSOutlineView
pub fn createWindowWithSidebar(
    title: []const u8,
    width: u32,
    height: u32,
    html: []const u8,
    sidebar_width: u32,
    sidebar_config_json: ?[]const u8,
    style: WindowStyle,
) !objc.id {
    // Parse sidebar config if provided
    if (sidebar_config_json) |json| {
        parseSidebarConfig(json) catch |err| {
            if (comptime builtin.mode == .debug)
                std.debug.print("[NativeSidebar] Failed to parse sidebar config: {}\n", .{err});
        };
    }
    const NSApplication = getClass("NSApplication");
    const NSWindow = getClass("NSWindow");
    const NSString = getClass("NSString");
    const NSSplitViewController = getClass("NSSplitViewController");
    const NSSplitViewItem = getClass("NSSplitViewItem");
    const NSViewController = getClass("NSViewController");
    const NSScrollView = getClass("NSScrollView");
    const NSOutlineView = getClass("NSOutlineView");
    const NSTableColumn = getClass("NSTableColumn");
    const WKWebView = getClass("WKWebView");
    const WKWebViewConfiguration = getClass("WKWebViewConfiguration");
    const WKPreferences = getClass("WKPreferences");
    const WKUserContentController = getClass("WKUserContentController");

    _ = NSApplication;
    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Creating window with native macOS sidebar...\n", .{});

    // Create window frame
    const frame = NSRect{
        .origin = .{
            .x = if (style.x) |x| @as(f64, @floatFromInt(x)) else 200,
            .y = if (style.y) |y| @as(f64, @floatFromInt(y)) else 200,
        },
        .size = .{ .width = @as(f64, @floatFromInt(width)), .height = @as(f64, @floatFromInt(height)) },
    };

    // Style mask with full-size content view for proper toolbar integration
    var styleMask: c_ulong = 1 | 2 | 4 | 8; // Titled, Closable, Miniaturizable, Resizable
    styleMask |= 32768; // NSWindowStyleMaskFullSizeContentView

    const backing: c_ulong = 2;
    const defer_flag: bool = false;

    // Create window
    const window_alloc = msgSend0(NSWindow, "alloc");
    const window = msgSend4(window_alloc, "initWithContentRect:styleMask:backing:defer:", frame, styleMask, backing, defer_flag);

    // Set window title
    const title_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title);
    defer std.heap.c_allocator.free(title_cstr);
    const title_str = msgSend1(msgSend0(NSString, "alloc"), "initWithUTF8String:", title_cstr.ptr);
    _ = msgSend1(window, "setTitle:", title_str);

    // Configure for native sidebar appearance
    _ = msgSend1(window, "setTitlebarAppearsTransparent:", @as(c_int, 1));
    _ = msgSend1(window, "setTitleVisibility:", @as(c_int, 1)); // NSWindowTitleHidden = 1

    // Configure window for native sidebar appearance
    _ = msgSend1(window, "setHasShadow:", @as(c_int, 1));
    // Set titlebar separator style to none so sidebar extends into titlebar
    _ = msgSend1(window, "setTitlebarSeparatorStyle:", @as(c_long, 0)); // NSTitlebarSeparatorStyleNone = 0

    // Apply dark mode appearance FIRST so sidebar inherits it
    // Use vibrant appearance for proper sidebar vibrancy
    const NSAppearance = getClass("NSAppearance");
    const is_dark = switch (sidebar_material_scheme) {
        .light => false,
        .dark => true,
        .system => if (style.dark_mode) |dm| dm else false,
    };
    const appearanceName = if (is_dark)
        createNSString("NSAppearanceNameVibrantDark")
    else
        createNSString("NSAppearanceNameVibrantLight");
    const appearance = msgSend1(NSAppearance, "appearanceNamed:", appearanceName);
    if (appearance != null) {
        _ = msgSend1(window, "setAppearance:", appearance);
    }

    // Create NSToolbar - this is REQUIRED for traffic lights to appear in sidebar
    const NSToolbar = getClass("NSToolbar");
    const toolbar_id = createNSString("MainToolbar");
    const toolbar_alloc = msgSend0(NSToolbar, "alloc");
    const toolbar = msgSend1(toolbar_alloc, "initWithIdentifier:", toolbar_id);
    _ = msgSend1(toolbar, "setShowsBaselineSeparator:", @as(c_int, 0));
    _ = msgSend1(window, "setToolbar:", toolbar);
    _ = msgSend1(window, "setToolbarStyle:", @as(c_long, 3)); // NSWindowToolbarStyleUnifiedCompact = 3

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Window created with toolbar for traffic lights\n", .{});

    // ========================================
    // Create NSSplitViewController
    // ========================================
    const splitVC_alloc = msgSend0(NSSplitViewController, "alloc");
    const splitVC = msgSend0(splitVC_alloc, "init");

    // ========================================
    // Create Sidebar View Controller
    // ========================================

    const sidebarFrame = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @as(f64, @floatFromInt(sidebar_width)), .height = @as(f64, @floatFromInt(height)) },
    };

    // Create NSScrollView for the outline view
    // Let the source list style handle the sidebar appearance
    const scrollView_alloc = msgSend0(NSScrollView, "alloc");
    const scrollView = msgSend1Rect(scrollView_alloc, "initWithFrame:", sidebarFrame);
    _ = msgSend1(scrollView, "setHasVerticalScroller:", @as(c_int, 1));
    _ = msgSend1(scrollView, "setHasHorizontalScroller:", @as(c_int, 0));
    _ = msgSend1(scrollView, "setAutohidesScrollers:", @as(c_int, 1));
    _ = msgSend1(scrollView, "setBorderType:", @as(c_long, 0)); // NSNoBorder = 0
    // Let the native material view draw the sidebar background.
    _ = msgSend1(scrollView, "setDrawsBackground:", @as(c_int, 0));
    _ = msgSend1(scrollView, "setBackgroundColor:", msgSend0(getClass("NSColor"), "clearColor"));
    msgSendVoid1(scrollView, "setAutoresizingMask:", @as(c_ulong, 2 | 16)); // Width + Height

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Created NSScrollView for sidebar\n", .{});

    // Create NSOutlineView with source list style
    const outlineView_alloc = msgSend0(NSOutlineView, "alloc");
    const outlineView = msgSend1Rect(outlineView_alloc, "initWithFrame:", sidebarFrame);

    // Configure source list style (NSTableViewStyleSourceList)
    // This style automatically participates in sidebar vibrancy
    _ = msgSend1(outlineView, "setStyle:", @as(c_long, 1)); // NSTableViewStyleSourceList = 1
    _ = msgSend1(outlineView, "setSelectionHighlightStyle:", @as(c_long, 1)); // NSTableViewSelectionHighlightStyleSourceList = 1
    _ = msgSend1(outlineView, "setRowSizeStyle:", @as(c_long, 2)); // NSTableViewRowSizeStyleDefault = 2
    _ = msgSend1(outlineView, "setFloatsGroupRows:", @as(c_int, 0)); // Disable floating to prevent first row special treatment
    _ = msgSend1(outlineView, "setIndentationPerLevel:", @as(f64, 13.0));
    _ = msgSend1(outlineView, "setHeaderView:", @as(?*anyopaque, null)); // No header

    // Let the source list style handle the background color naturally
    // The system will provide the appropriate sidebar appearance
    _ = msgSend1(outlineView, "setUsesAlternatingRowBackgroundColors:", @as(c_int, 0));
    _ = msgSend1(outlineView, "setBackgroundColor:", msgSend0(getClass("NSColor"), "clearColor"));

    // Create table column
    const columnId = createNSString("SidebarColumn");
    const column_alloc = msgSend0(NSTableColumn, "alloc");
    const column = msgSend1(column_alloc, "initWithIdentifier:", columnId);
    _ = msgSend1(column, "setWidth:", @as(f64, @floatFromInt(sidebar_width - 20)));
    _ = msgSend1(outlineView, "addTableColumn:", column);
    _ = msgSend1(outlineView, "setOutlineTableColumn:", column);

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Created NSOutlineView with source list style\n", .{});

    // Setup data source and delegate for the outline view
    const dataSource = try setupSidebarDataSource();
    _ = msgSend1(outlineView, "setDataSource:", dataSource);
    _ = msgSend1(outlineView, "setDelegate:", dataSource);

    // Reload data and expand all sections
    _ = msgSend0(outlineView, "reloadData");

    // Expand all root items (sections)
    const numRows = msgSendNSInteger(outlineView, "numberOfRows");
    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Number of rows after reload: {d}\n", .{numRows});

    // Expand root items
    var i: c_long = 0;
    while (i < numRows) : (i += 1) {
        const item = msgSend1(outlineView, "itemAtRow:", i);
        if (item != null) {
            _ = msgSend1(outlineView, "expandItem:", item);
        }
    }

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Data source configured with demo items\n", .{});

    // Set outline view as document view of scroll view
    _ = msgSend1(scrollView, "setDocumentView:", outlineView);

    // Create sidebar view controller with a real native material behind the outline view.
    const sidebarVC_alloc = msgSend0(NSViewController, "alloc");
    const sidebarVC = msgSend0(sidebarVC_alloc, "init");
    const sidebarMaterialView = createSidebarVisualEffectView(sidebarFrame, 0.0);
    if (sidebarMaterialView != null) {
        _ = msgSend1(sidebarMaterialView, "addSubview:", scrollView);
        _ = msgSend1(sidebarVC, "setView:", sidebarMaterialView);
    } else {
        _ = msgSend1(sidebarVC, "setView:", scrollView);
    }

    // Create sidebar split view item
    const sidebarItem = msgSend1(NSSplitViewItem, "sidebarWithViewController:", sidebarVC);
    _ = msgSend1(sidebarItem, "setCanCollapse:", @as(c_int, 0)); // Don't allow collapse initially
    _ = msgSend1(sidebarItem, "setMinimumThickness:", @as(f64, @floatFromInt(sidebar_width)));
    _ = msgSend1(sidebarItem, "setMaximumThickness:", @as(f64, 320.0));
    // Set holding priority to ensure sidebar doesn't shrink
    _ = msgSend1(sidebarItem, "setHoldingPriority:", @as(f32, 250.0));
    // Ensure sidebar is not collapsed
    _ = msgSend1(sidebarItem, "setCollapsed:", @as(c_int, 0));

    // Add sidebar to split view controller
    _ = msgSend1(splitVC, "addSplitViewItem:", sidebarItem);

    if (comptime builtin.mode == .debug) {
        std.debug.print("[NativeSidebar] Sidebar item added to split view controller\n", .{});
        std.debug.print("[NativeSidebar] Sidebar view controller configured\n", .{});
    }

    // ========================================
    // Create Content (WebView) View Controller
    // ========================================

    const contentFrame = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @as(f64, @floatFromInt(width - sidebar_width)), .height = @as(f64, @floatFromInt(height)) },
    };

    // Create WebView configuration
    const config_alloc = msgSend0(WKWebViewConfiguration, "alloc");
    const config = msgSend0(config_alloc, "init");

    const prefs_alloc = msgSend0(WKPreferences, "alloc");
    const prefs = msgSend0(prefs_alloc, "init");
    msgSendVoid1(prefs, "setJavaScriptEnabled:", true);

    // Enable developer extras
    const key_str = createNSString("developerExtrasEnabled");
    const value_obj = msgSend1(msgSend0(getClass("NSNumber"), "alloc"), "initWithBool:", true);
    msgSendVoid2(prefs, "setValue:forKey:", value_obj, key_str);
    _ = msgSend1(config, "setPreferences:", prefs);

    // Set up user content controller
    const userContentController = msgSend0(msgSend0(WKUserContentController, "alloc"), "init");
    setupScriptMessageHandler(userContentController) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Failed to setup message handler: {}\n", .{err});
    };
    // A sidebar window always takes the full bridge, the bootstrap and the
    // native UI surface — it has a native sidebar to drive by definition.
    injectCraftScripts(userContentController, .{
        .full_bridge = true,
        .sidebar_bootstrap = true,
        .native_ui = true,
    });
    _ = msgSend1(config, "setUserContentController:", userContentController);

    // Create WKWebView
    const webview_alloc = msgSend0(WKWebView, "alloc");
    const webview = msgSend2(webview_alloc, "initWithFrame:configuration:", contentFrame, config);
    makeWindowTranslucent(window);
    makeWebViewTransparent(webview);

    // Setup UI delegate
    setupUIDelegate(webview) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Media] Failed to setup UI delegate: {}\n", .{err});
    };

    // The HTML below is loaded against a localhost base URL, and anything it
    // fetches over HTTPS gets the same treatment as a directly loaded URL.
    setupNavigationDelegate(webview) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Nav] Failed to setup navigation delegate: {}\n", .{err});
    };

    // HTML loads unmodified — the scripts are user scripts on the controller.
    const html_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, html);
    defer std.heap.c_allocator.free(html_cstr);
    const html_str = msgSend1(msgSend0(NSString, "alloc"), "initWithUTF8String:", html_cstr.ptr);
    const base_url_string = createNSString("http://localhost/");
    const base_url = msgSend1(getClass("NSURL"), "URLWithString:", base_url_string);
    _ = msgSend2(webview, "loadHTMLString:baseURL:", html_str, base_url);

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] WebView created and HTML loaded\n", .{});

    // Store WebView reference for sidebar events
    sidebar_webview = webview;

    // Create content view controller with WebView
    const contentVC_alloc = msgSend0(NSViewController, "alloc");
    const contentVC = msgSend0(contentVC_alloc, "init");
    _ = msgSend1(contentVC, "setView:", webview);

    // Create content split view item
    const contentItem = msgSend1(NSSplitViewItem, "contentListWithViewController:", contentVC);
    _ = msgSend1(splitVC, "addSplitViewItem:", contentItem);

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Content view controller configured\n", .{});

    // ========================================
    // Set split view controller as window's content
    // ========================================

    _ = msgSend1(window, "setContentViewController:", splitVC);

    // Configure the NSSplitView divider style
    const splitView = msgSend0(splitVC, "splitView");
    if (splitView != null) {
        _ = msgSend1(splitView, "setDividerStyle:", @as(c_long, 1)); // NSSplitViewDividerStyleThin = 1
    }

    // Dark mode already applied at the start with vibrant appearance

    // Center window
    if (style.x == null or style.y == null) {
        msgSendVoid0(window, "center");
    }

    // Store references
    if (webview) |wv| {
        setGlobalWebView(wv);
        const tray_menu = @import("tray_menu.zig");
        tray_menu.setGlobalWebView(wv);
        if (window) |win| {
            tray_menu.setGlobalWindow(win);
        }
    }

    // Setup bridge handlers
    setupBridgeHandlers(std.heap.c_allocator, null, window) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Failed to setup bridge handlers: {}\n", .{err});
    };

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] ✓ Window with native sidebar created successfully\n", .{});

    return window;
}

/// Default fallback sidebar HTML (used when no config is provided or on parse error)
const default_sidebar_html =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\<meta charset="UTF-8">
    \\<style>
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body {
    \\  font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
    \\  background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f0f23 100%);
    \\  color: #fff;
    \\  height: 100vh;
    \\  overflow-y: auto;
    \\  padding: 60px 12px 12px 12px;
    \\  -webkit-user-select: none;
    \\  user-select: none;
    \\}
    \\.section { margin-bottom: 24px; }
    \\.section-title {
    \\  font-size: 11px;
    \\  font-weight: 600;
    \\  color: rgba(255,255,255,0.5);
    \\  text-transform: uppercase;
    \\  letter-spacing: 0.5px;
    \\  padding: 0 8px 8px 8px;
    \\}
    \\.item {
    \\  display: flex;
    \\  align-items: center;
    \\  gap: 10px;
    \\  padding: 8px 12px;
    \\  border-radius: 8px;
    \\  cursor: pointer;
    \\  font-size: 13px;
    \\  color: rgba(255,255,255,0.85);
    \\}
    \\.item:hover { background: rgba(255,255,255,0.08); }
    \\.item.selected { background: rgba(139, 92, 246, 0.25); }
    \\.item-icon {
    \\  width: 20px;
    \\  height: 20px;
    \\  display: flex;
    \\  align-items: center;
    \\  justify-content: center;
    \\  font-size: 14px;
    \\}
    \\.badge {
    \\  margin-left: auto;
    \\  background: rgba(139, 92, 246, 0.6);
    \\  padding: 2px 8px;
    \\  border-radius: 10px;
    \\  font-size: 11px;
    \\  font-weight: 500;
    \\}
    \\</style>
    \\</head>
    \\<body>
    \\<div class="section">
    \\  <div class="section-title">Inbox</div>
    \\  <div class="item selected"><span class="item-icon">📥</span>All Messages<span class="badge">68</span></div>
    \\  <div class="item"><span class="item-icon">📧</span>Unread<span class="badge">21</span></div>
    \\  <div class="item"><span class="item-icon">@</span>Mentions<span class="badge">3</span></div>
    \\  <div class="item"><span class="item-icon">📌</span>Pinned</div>
    \\</div>
    \\<div class="section">
    \\  <div class="section-title">Platforms</div>
    \\  <div class="item"><span class="item-icon">💬</span>iMessage<span class="badge">4</span></div>
    \\  <div class="item"><span class="item-icon">📱</span>WhatsApp</div>
    \\  <div class="item"><span class="item-icon">#</span>Slack<span class="badge">12</span></div>
    \\  <div class="item"><span class="item-icon">🎮</span>Discord<span class="badge">5</span></div>
    \\  <div class="item"><span class="item-icon">✈️</span>Telegram<span class="badge">47</span></div>
    \\  <div class="item"><span class="item-icon">🛡️</span>Signal</div>
    \\</div>
    \\<div class="section">
    \\  <div class="section-title">Channels</div>
    \\  <div class="item"><span class="item-icon">#</span>Design Team</div>
    \\  <div class="item"><span class="item-icon">#</span>General</div>
    \\  <div class="item"><span class="item-icon">#</span>Gaming Squad</div>
    \\</div>
    \\</body>
    \\</html>
;

/// Escape a string for safe inclusion in HTML content.
/// Replaces &, <, >, ", and ' with their HTML entity equivalents.
fn appendHtmlEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '&' => try list.appendSlice(allocator, "&amp;"),
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            '\'' => try list.appendSlice(allocator, "&#39;"),
            else => try list.append(allocator, c),
        }
    }
}

/// Map well-known SF Symbol names to emoji fallbacks for web rendering.
/// Returns null if no known mapping exists (caller should use a generic fallback).
fn sfSymbolToEmoji(icon: []const u8) ?[]const u8 {
    const mappings = [_]struct { name: []const u8, emoji: []const u8 }{
        .{ .name = "house", .emoji = "\xF0\x9F\x8F\xA0" },
        .{ .name = "house.fill", .emoji = "\xF0\x9F\x8F\xA0" },
        .{ .name = "folder", .emoji = "\xF0\x9F\x93\x81" },
        .{ .name = "folder.fill", .emoji = "\xF0\x9F\x93\x81" },
        .{ .name = "doc", .emoji = "\xF0\x9F\x93\x84" },
        .{ .name = "doc.fill", .emoji = "\xF0\x9F\x93\x84" },
        .{ .name = "star", .emoji = "\xE2\xAD\x90" },
        .{ .name = "star.fill", .emoji = "\xE2\xAD\x90" },
        .{ .name = "heart", .emoji = "\xE2\x9D\xA4\xEF\xB8\x8F" },
        .{ .name = "heart.fill", .emoji = "\xE2\x9D\xA4\xEF\xB8\x8F" },
        .{ .name = "gear", .emoji = "\xE2\x9A\x99\xEF\xB8\x8F" },
        .{ .name = "gearshape", .emoji = "\xE2\x9A\x99\xEF\xB8\x8F" },
        .{ .name = "gearshape.fill", .emoji = "\xE2\x9A\x99\xEF\xB8\x8F" },
        .{ .name = "magnifyingglass", .emoji = "\xF0\x9F\x94\x8D" },
        .{ .name = "bell", .emoji = "\xF0\x9F\x94\x94" },
        .{ .name = "bell.fill", .emoji = "\xF0\x9F\x94\x94" },
        .{ .name = "envelope", .emoji = "\xE2\x9C\x89\xEF\xB8\x8F" },
        .{ .name = "envelope.fill", .emoji = "\xE2\x9C\x89\xEF\xB8\x8F" },
        .{ .name = "paperplane", .emoji = "\xF0\x9F\x93\xA8" },
        .{ .name = "paperplane.fill", .emoji = "\xF0\x9F\x93\xA8" },
        .{ .name = "trash", .emoji = "\xF0\x9F\x97\x91\xEF\xB8\x8F" },
        .{ .name = "trash.fill", .emoji = "\xF0\x9F\x97\x91\xEF\xB8\x8F" },
        .{ .name = "tray", .emoji = "\xF0\x9F\x93\xA5" },
        .{ .name = "tray.fill", .emoji = "\xF0\x9F\x93\xA5" },
        .{ .name = "person", .emoji = "\xF0\x9F\x91\xA4" },
        .{ .name = "person.fill", .emoji = "\xF0\x9F\x91\xA4" },
        .{ .name = "person.2", .emoji = "\xF0\x9F\x91\xA5" },
        .{ .name = "person.2.fill", .emoji = "\xF0\x9F\x91\xA5" },
        .{ .name = "message", .emoji = "\xF0\x9F\x92\xAC" },
        .{ .name = "message.fill", .emoji = "\xF0\x9F\x92\xAC" },
        .{ .name = "bubble.left", .emoji = "\xF0\x9F\x92\xAC" },
        .{ .name = "bubble.left.fill", .emoji = "\xF0\x9F\x92\xAC" },
        .{ .name = "photo", .emoji = "\xF0\x9F\x96\xBC\xEF\xB8\x8F" },
        .{ .name = "photo.fill", .emoji = "\xF0\x9F\x96\xBC\xEF\xB8\x8F" },
        .{ .name = "music.note", .emoji = "\xF0\x9F\x8E\xB5" },
        .{ .name = "film", .emoji = "\xF0\x9F\x8E\xAC" },
        .{ .name = "book", .emoji = "\xF0\x9F\x93\x96" },
        .{ .name = "book.fill", .emoji = "\xF0\x9F\x93\x96" },
        .{ .name = "bookmark", .emoji = "\xF0\x9F\x94\x96" },
        .{ .name = "bookmark.fill", .emoji = "\xF0\x9F\x94\x96" },
        .{ .name = "tag", .emoji = "\xF0\x9F\x8F\xB7\xEF\xB8\x8F" },
        .{ .name = "tag.fill", .emoji = "\xF0\x9F\x8F\xB7\xEF\xB8\x8F" },
        .{ .name = "clock", .emoji = "\xF0\x9F\x95\x90" },
        .{ .name = "clock.fill", .emoji = "\xF0\x9F\x95\x90" },
        .{ .name = "calendar", .emoji = "\xF0\x9F\x93\x85" },
        .{ .name = "mappin", .emoji = "\xF0\x9F\x93\x8D" },
        .{ .name = "map", .emoji = "\xF0\x9F\x97\xBA\xEF\xB8\x8F" },
        .{ .name = "link", .emoji = "\xF0\x9F\x94\x97" },
        .{ .name = "pin", .emoji = "\xF0\x9F\x93\x8C" },
        .{ .name = "pin.fill", .emoji = "\xF0\x9F\x93\x8C" },
        .{ .name = "bolt", .emoji = "\xE2\x9A\xA1" },
        .{ .name = "bolt.fill", .emoji = "\xE2\x9A\xA1" },
        .{ .name = "circle.fill", .emoji = "\xE2\x97\x8F" },
        .{ .name = "arrow.down.circle", .emoji = "\xE2\xAC\x87\xEF\xB8\x8F" },
        .{ .name = "arrow.down.circle.fill", .emoji = "\xE2\xAC\x87\xEF\xB8\x8F" },
        .{ .name = "icloud", .emoji = "\xE2\x98\x81\xEF\xB8\x8F" },
        .{ .name = "externaldrive.fill.badge.icloud", .emoji = "\xE2\x98\x81\xEF\xB8\x8F" },
        .{ .name = "number", .emoji = "#" },
    };
    for (mappings) |entry| {
        if (std.mem.eql(u8, icon, entry.name)) return entry.emoji;
    }
    return null;
}

/// Generate HTML for the web-based sidebar.
/// If sidebar_config is provided (as a JSON string), parse it and generate dynamic HTML.
/// Falls back to default_sidebar_html on null config or parse errors.
fn generateSidebarHtml(allocator: std.mem.Allocator, sidebar_config: ?[]const u8) ![]const u8 {
    const config_json = sidebar_config orelse return default_sidebar_html;

    // Parse the JSON config
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[SidebarHTML] JSON parse error: {}, falling back to default\n", .{err});
        return default_sidebar_html;
    };
    defer parsed.deinit();
    const root = parsed.value;

    // Root must be an object with a "sections" array
    const root_obj = switch (root) {
        .object => |obj| obj,
        else => return default_sidebar_html,
    };

    const sections_val = root_obj.get("sections") orelse return default_sidebar_html;
    const sections_array = switch (sections_val) {
        .array => |arr| arr,
        else => return default_sidebar_html,
    };

    // Extract optional style configuration
    const style_obj = if (root_obj.get("style")) |s| switch (s) {
        .object => |obj| obj,
        else => null,
    } else null;

    const bg_color = if (style_obj) |s| if (s.get("backgroundColor")) |v| switch (v) {
        .string => |str| str,
        else => null,
    } else null else null;
    const text_color = if (style_obj) |s| if (s.get("textColor")) |v| switch (v) {
        .string => |str| str,
        else => null,
    } else null else null;
    const accent_color = if (style_obj) |s| if (s.get("accentColor")) |v| switch (v) {
        .string => |str| str,
        else => null,
    } else null else null;
    const hover_color = if (style_obj) |s| if (s.get("hoverColor")) |v| switch (v) {
        .string => |str| str,
        else => null,
    } else null else null;

    // Extract optional header
    const header_obj = if (root_obj.get("header")) |h| switch (h) {
        .object => |obj| obj,
        else => null,
    } else null;

    // Build the HTML dynamically using ArrayList
    var html = std.ArrayList(u8).init(allocator);
    errdefer html.deinit(allocator);

    // HTML preamble and CSS
    try html.appendSlice(allocator, "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"UTF-8\">\n<style>\n");
    try html.appendSlice(allocator, "* { margin: 0; padding: 0; box-sizing: border-box; }\n");

    // Body style - use config colors or sensible defaults
    try html.appendSlice(allocator, "body {\n");
    try html.appendSlice(allocator, "  font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;\n");
    try html.appendSlice(allocator, "  background: ");
    if (bg_color) |bg| {
        try appendHtmlEscaped(&html, allocator, bg);
    } else {
        try html.appendSlice(allocator, "linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f0f23 100%)");
    }
    try html.appendSlice(allocator, ";\n  color: ");
    if (text_color) |tc| {
        try appendHtmlEscaped(&html, allocator, tc);
    } else {
        try html.appendSlice(allocator, "#fff");
    }
    try html.appendSlice(allocator, ";\n  height: 100vh;\n  overflow-y: auto;\n  padding: 60px 12px 12px 12px;\n  -webkit-user-select: none;\n  user-select: none;\n}\n");

    // Section styles
    try html.appendSlice(allocator, ".section { margin-bottom: 24px; }\n");
    try html.appendSlice(allocator, ".section-title {\n  font-size: 11px;\n  font-weight: 600;\n  color: ");
    if (text_color) |tc| {
        try appendHtmlEscaped(&html, allocator, tc);
        // Approximate reduced opacity by appending hex alpha if it looks like a hex color
        if (tc.len > 0 and tc[0] == '#') {
            try html.appendSlice(allocator, "80");
        }
    } else {
        try html.appendSlice(allocator, "rgba(255,255,255,0.5)");
    }
    try html.appendSlice(allocator, ";\n  text-transform: uppercase;\n  letter-spacing: 0.5px;\n  padding: 0 8px 8px 8px;\n}\n");

    // Item styles
    try html.appendSlice(allocator, ".item {\n  display: flex;\n  align-items: center;\n  gap: 10px;\n  padding: 8px 12px;\n  border-radius: 8px;\n  cursor: pointer;\n  font-size: 13px;\n  color: ");
    if (text_color) |tc| {
        try appendHtmlEscaped(&html, allocator, tc);
    } else {
        try html.appendSlice(allocator, "rgba(255,255,255,0.85)");
    }
    try html.appendSlice(allocator, ";\n  transition: background 0.15s ease;\n}\n");

    // Hover style
    try html.appendSlice(allocator, ".item:hover { background: ");
    if (hover_color) |hc| {
        try appendHtmlEscaped(&html, allocator, hc);
    } else {
        try html.appendSlice(allocator, "rgba(255,255,255,0.08)");
    }
    try html.appendSlice(allocator, "; }\n");

    // Selected style
    try html.appendSlice(allocator, ".item.selected { background: ");
    if (accent_color) |ac| {
        try appendHtmlEscaped(&html, allocator, ac);
        if (ac.len > 0 and ac[0] == '#') {
            try html.appendSlice(allocator, "40");
        }
    } else {
        try html.appendSlice(allocator, "rgba(139, 92, 246, 0.25)");
    }
    try html.appendSlice(allocator, "; }\n");

    // Disabled style
    try html.appendSlice(allocator, ".item.disabled { opacity: 0.4; pointer-events: none; }\n");

    // Icon style
    try html.appendSlice(allocator, ".item-icon {\n  width: 20px;\n  height: 20px;\n  display: flex;\n  align-items: center;\n  justify-content: center;\n  font-size: 14px;\n}\n");

    // Badge style
    try html.appendSlice(allocator, ".badge {\n  margin-left: auto;\n  background: ");
    if (accent_color) |ac| {
        try appendHtmlEscaped(&html, allocator, ac);
        if (ac.len > 0 and ac[0] == '#') {
            try html.appendSlice(allocator, "99");
        }
    } else {
        try html.appendSlice(allocator, "rgba(139, 92, 246, 0.6)");
    }
    try html.appendSlice(allocator, ";\n  padding: 2px 8px;\n  border-radius: 10px;\n  font-size: 11px;\n  font-weight: 500;\n}\n");

    // Header styles
    try html.appendSlice(allocator, ".sidebar-header { padding: 0 8px 16px 8px; }\n");
    try html.appendSlice(allocator, ".sidebar-header-title { font-size: 15px; font-weight: 700; }\n");
    try html.appendSlice(allocator, ".sidebar-header-subtitle { font-size: 12px; opacity: 0.6; margin-top: 2px; }\n");

    try html.appendSlice(allocator, "</style>\n</head>\n<body>\n");

    // Render optional header
    if (header_obj) |hdr| {
        try html.appendSlice(allocator, "<div class=\"sidebar-header\">\n");
        if (hdr.get("title")) |t| {
            switch (t) {
                .string => |str| {
                    try html.appendSlice(allocator, "  <div class=\"sidebar-header-title\">");
                    try appendHtmlEscaped(&html, allocator, str);
                    try html.appendSlice(allocator, "</div>\n");
                },
                else => {},
            }
        }
        if (hdr.get("subtitle")) |t| {
            switch (t) {
                .string => |str| {
                    try html.appendSlice(allocator, "  <div class=\"sidebar-header-subtitle\">");
                    try appendHtmlEscaped(&html, allocator, str);
                    try html.appendSlice(allocator, "</div>\n");
                },
                else => {},
            }
        }
        try html.appendSlice(allocator, "</div>\n");
    }

    // Render each section
    for (sections_array.items) |section_val| {
        const section_obj = switch (section_val) {
            .object => |obj| obj,
            else => continue,
        };

        const section_title = if (section_obj.get("title")) |v| switch (v) {
            .string => |s| s,
            else => "Section",
        } else "Section";

        try html.appendSlice(allocator, "<div class=\"section\">\n");
        try html.appendSlice(allocator, "  <div class=\"section-title\">");
        try appendHtmlEscaped(&html, allocator, section_title);
        try html.appendSlice(allocator, "</div>\n");

        // Get items array
        const items_val = section_obj.get("items") orelse {
            try html.appendSlice(allocator, "</div>\n");
            continue;
        };
        const items_array = switch (items_val) {
            .array => |arr| arr,
            else => {
                try html.appendSlice(allocator, "</div>\n");
                continue;
            },
        };

        // Render each item
        for (items_array.items) |item_val| {
            const item_obj = switch (item_val) {
                .object => |obj| obj,
                else => continue,
            };

            const item_id = if (item_obj.get("id")) |v| switch (v) {
                .string => |s| s,
                else => "item",
            } else "item";

            const item_label = if (item_obj.get("label")) |v| switch (v) {
                .string => |s| s,
                else => "Item",
            } else "Item";

            const item_icon: ?[]const u8 = if (item_obj.get("icon")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null;

            const item_badge: ?[]const u8 = if (item_obj.get("badge")) |v| switch (v) {
                .string => |s| s,
                .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}) catch null,
                else => null,
            } else null;

            const item_selected: bool = if (item_obj.get("selected")) |v| switch (v) {
                .bool => |b| b,
                else => false,
            } else false;

            const item_disabled: bool = if (item_obj.get("disabled")) |v| switch (v) {
                .bool => |b| b,
                else => false,
            } else false;

            const item_tint: ?[]const u8 = if (item_obj.get("tintColor")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null;

            // Build item element with CSS classes and data attribute
            try html.appendSlice(allocator, "  <div class=\"item");
            if (item_selected) try html.appendSlice(allocator, " selected");
            if (item_disabled) try html.appendSlice(allocator, " disabled");
            try html.appendSlice(allocator, "\" data-id=\"");
            try appendHtmlEscaped(&html, allocator, item_id);
            try html.appendSlice(allocator, "\" onclick=\"handleSidebarClick(this)\">");

            // Icon span - apply tint color if provided, map SF Symbol to emoji
            try html.appendSlice(allocator, "<span class=\"item-icon\"");
            if (item_tint) |tint| {
                try html.appendSlice(allocator, " style=\"color:");
                try appendHtmlEscaped(&html, allocator, tint);
                try html.appendSlice(allocator, "\"");
            }
            try html.appendSlice(allocator, ">");

            if (item_icon) |icon| {
                if (sfSymbolToEmoji(icon)) |emoji| {
                    try html.appendSlice(allocator, emoji);
                } else {
                    // Check if icon is already an emoji (contains non-ASCII bytes)
                    var has_non_ascii = false;
                    for (icon) |c| {
                        if (c > 127) {
                            has_non_ascii = true;
                            break;
                        }
                    }
                    if (has_non_ascii) {
                        // Likely an emoji, use directly
                        try appendHtmlEscaped(&html, allocator, icon);
                    } else if (icon.len <= 2) {
                        // Short text like "#" or "@", use as-is
                        try appendHtmlEscaped(&html, allocator, icon);
                    } else {
                        // Unknown SF Symbol name, use generic document icon
                        try html.appendSlice(allocator, "\xF0\x9F\x93\x84");
                    }
                }
            } else {
                // No icon specified, use generic document icon
                try html.appendSlice(allocator, "\xF0\x9F\x93\x84");
            }

            try html.appendSlice(allocator, "</span>");

            // Label text
            try appendHtmlEscaped(&html, allocator, item_label);

            // Badge (optional)
            if (item_badge) |badge| {
                try html.appendSlice(allocator, "<span class=\"badge\">");
                try appendHtmlEscaped(&html, allocator, badge);
                try html.appendSlice(allocator, "</span>");
            }

            try html.appendSlice(allocator, "</div>\n");
        }

        try html.appendSlice(allocator, "</div>\n");
    }

    // Click handler JavaScript - sends sidebar_select messages to the native bridge
    try html.appendSlice(allocator,
        \\<script>
        \\function handleSidebarClick(el) {
        \\  var id = el.getAttribute('data-id');
        \\  document.querySelectorAll('.item.selected').forEach(function(item) {
        \\    item.classList.remove('selected');
        \\  });
        \\  el.classList.add('selected');
        \\  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.craftBridge) {
        \\    window.webkit.messageHandlers.craftBridge.postMessage(JSON.stringify({
        \\      type: 'sidebar_select',
        \\      id: id,
        \\      label: el.textContent.trim()
        \\    }));
        \\  }
        \\}
        \\</script>
        \\
    );

    try html.appendSlice(allocator, "</body>\n</html>");

    if (comptime builtin.mode == .debug)
        std.debug.print("[SidebarHTML] Generated dynamic sidebar HTML ({d} bytes) from config\n", .{html.items.len});

    return try html.toOwnedSlice(allocator);
}

// ============================================================================
// Sidebar Toggle via NSToolbarItem with toggleSidebar: responder
// ============================================================================

/// Toggle sidebar visibility with animation. Called via responder chain from toolbar button.
fn sidebarToggleCallback(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    if (sidebar_container == null or sidebar_content_webview == null) return;

    sidebar_collapsed = !sidebar_collapsed;

    // Animate
    const NSAnimationContext = getClass("NSAnimationContext");
    _ = msgSend0(NSAnimationContext, "beginGrouping");
    const ctx = msgSend0(NSAnimationContext, "currentContext");
    _ = msgSend1(ctx, "setDuration:", @as(f64, 0.2));
    _ = msgSend1(ctx, "setAllowsImplicitAnimation:", @as(c_int, 1));

    if (sidebar_collapsed) {
        _ = msgSend1(sidebar_container, "setHidden:", @as(c_int, 1));
        const f = msgSendRect(sidebar_content_webview, "frame");
        msgSendVoid1Rect(sidebar_content_webview, "setFrame:", .{
            .origin = .{ .x = 0, .y = f.origin.y },
            .size = .{ .width = f.size.width + f.origin.x, .height = f.size.height },
        });
    } else {
        _ = msgSend1(sidebar_container, "setHidden:", @as(c_int, 0));
        const f = msgSendRect(sidebar_content_webview, "frame");
        msgSendVoid1Rect(sidebar_content_webview, "setFrame:", .{
            .origin = .{ .x = sidebar_width_stored, .y = f.origin.y },
            .size = .{ .width = f.size.width - sidebar_width_stored, .height = f.size.height },
        });
    }

    // Reposition toggle button: right-aligned when expanded, left (after traffic lights) when collapsed
    if (sidebar_toggle_btn != null) {
        const btnFrame = msgSendRect(sidebar_toggle_btn, "frame");
        const newX: f64 = if (sidebar_collapsed) 88.0 else sidebar_width_stored - 28.0 - 12.0;
        msgSendVoid1Rect(sidebar_toggle_btn, "setFrame:", .{
            .origin = .{ .x = newX, .y = btnFrame.origin.y },
            .size = btnFrame.size,
        });
    }

    // Tell the webview about collapsed state so it can show/hide the home icon
    // Also inject CSS to add left padding so content clears the traffic lights + toggle button
    if (sidebar_webview != null) {
        const js = if (sidebar_collapsed)
            \\window.__craftSidebarCollapsed = true;
            \\document.documentElement.setAttribute('data-sidebar-collapsed', 'true');
            \\if (!document.getElementById('craft-collapsed-pad')) {
            \\  var s = document.createElement('style');
            \\  s.id = 'craft-collapsed-pad';
            \\  s.textContent = 'html[data-sidebar-collapsed] body { padding-left: 128px; }';
            \\  document.head.appendChild(s);
            \\}
        else
            \\window.__craftSidebarCollapsed = false;
            \\document.documentElement.removeAttribute('data-sidebar-collapsed');
            \\var ps = document.getElementById('craft-collapsed-pad');
            \\if (ps) ps.remove();
        ;
        const jsStr = createNSString(js);
        _ = msgSend2(sidebar_webview, "evaluateJavaScript:completionHandler:", jsStr, @as(?*anyopaque, null));
    }

    _ = msgSend0(NSAnimationContext, "endGrouping");
}

var sidebarToggleResponderClass: objc.Class = null;

/// Register a custom responder class that handles toggleSidebar: from the toolbar button
fn ensureSidebarToggleResponder() void {
    if (sidebarToggleResponderClass != null) return;

    const NSView = getClass("NSView");
    sidebarToggleResponderClass = objc.objc_allocateClassPair(NSView, "CraftSidebarToggleView", 0);
    if (sidebarToggleResponderClass == null) return;

    _ = objc.class_addMethod(
        sidebarToggleResponderClass,
        sel("toggleSidebar:"),
        @ptrCast(@constCast(&sidebarToggleCallback)),
        "v@:@",
    );

    objc.objc_registerClassPair(sidebarToggleResponderClass);
}

// =============================================================================
// Titlebar geometry
//
// Anything craft draws into the window chrome — the web-sidebar chrome row, the
// spaces switcher — has to answer the same two questions: how far down the
// theme frame does the titlebar band reach, and which autoresizing bits keep a
// control up there when the window grows. Both used to be answered inline, and
// wrongly, wherever they came up.
//
// The native-sidebar toggle button in `createWindowWithSidebarURL` still has
// its own hand-rolled 52pt titlebar constant for y; it takes the mask from here
// but not the band. Migrating it moves a button in a feature this change has
// not otherwise touched, so it is left for its own commit.
// =============================================================================

/// Height of the titlebar band, in points.
///
/// `contentLayoutRect` is the part of the window AppKit leaves to content, so
/// the difference against the theme frame is the band — 32pt for a standard
/// window, and still 32pt when `fullSizeContentView` lets the webview draw
/// underneath it. A borderless window has no band at all and reports 0.
fn titlebarBandHeight(window: objc.id, themeFrame: objc.id) f64 {
    const themeHeight = msgSendRect(themeFrame, "bounds").size.height;
    const layoutHeight = msgSendRect(window, "contentLayoutRect").size.height;
    return themeHeight - layoutHeight;
}

/// Where to put a `height`-point control so it sits centred in the titlebar,
/// in theme-frame coordinates.
///
/// The obvious-looking alternative — read `standardWindowButton:`'s frame and
/// mirror it through the theme frame's height — is what the switcher and the
/// chrome row both used to do, and it is wrong twice over. Those frames are in
/// *NSTitlebarView* coordinates, not the theme frame's, and the arithmetic then
/// mirrors an already-top-relative y a second time. The two errors cancel
/// exactly while the buttons sit at their default position (the band is 32 and
/// the button is centred in it: 2*9 + 14 == 32), which is why it looked correct
/// for so long. Move the traffic lights — the native-UI bridge still tries to —
/// and the control lands at the far edge: measured at y = -6 on an 800pt window
/// against a correct 772.
///
/// `createWindowWithStyle` no longer tries: its `setFrameOrigin:` calls were
/// measured to have no effect at all, since AppKit re-lays out the standard
/// buttons after window configuration. Anchoring to the band rather than to the
/// buttons is what makes this function immune to either fact.
///
/// Anchoring to the band instead is immune to where the buttons are, agrees
/// with today's value to the point in every case where today's value was right,
/// and keeps the control on screen when `standardWindowButton:` returns nothing
/// at all.
pub fn titlebarControlY(window: objc.id, themeFrame: objc.id, height: f64) f64 {
    const themeHeight = msgSendRect(themeFrame, "bounds").size.height;
    const measured = titlebarBandHeight(window, themeFrame);
    // A window that reports no band has no titlebar to centre in — a borderless
    // one, most obviously. Fall back to a nominal titlebar's worth so the
    // control lands just inside the top of the content rather than off-window,
    // which is where the old arithmetic put it.
    const band: f64 = if (measured > 1.0) measured else 28.0;
    return themeHeight - band + ((band - height) / 2.0);
}

/// Autoresizing mask that keeps a titlebar control pinned to the window's
/// top-left corner as the window resizes.
///
/// NSViewMaxXMargin (4) holds the left edge by letting the right margin absorb
/// the extra width; NSViewMinYMargin (8) holds the top edge by letting the
/// *bottom* margin absorb the extra height — NSThemeFrame is not a flipped
/// view, so the bottom margin is the one below the control. 4 on its own, which
/// is what every one of these controls used to be given (under a comment
/// claiming it was the min-Y bit), has no vertical effect whatsoever: measured,
/// a control set that way stayed put while the window grew 100pt taller, ending
/// up 100pt further from the titlebar it belongs to.
pub const titlebar_control_autoresizing_mask: c_ulong = 4 | 8;

fn webChromeToggleSidebarCallback(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    const webview = getGlobalWebView() orelse return;
    const js = createNSString("document.querySelector('[data-sidebar-collapse]')?.click()");
    _ = msgSend2(webview, "evaluateJavaScript:completionHandler:", js, @as(?*anyopaque, null));
}

fn webChromeBackCallback(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    const webview = getGlobalWebView() orelse return;
    msgSendVoid0(webview, "goBack");
}

fn webChromeForwardCallback(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    const webview = getGlobalWebView() orelse return;
    msgSendVoid0(webview, "goForward");
}

fn ensureWebChromeResponder() void {
    if (webChromeResponderClass != null) return;

    const NSView = getClass("NSView");
    webChromeResponderClass = objc.objc_allocateClassPair(NSView, "CraftWebChromeControlView", 0);
    if (webChromeResponderClass == null) return;

    _ = objc.class_addMethod(
        webChromeResponderClass,
        sel("toggleWebSidebar:"),
        @ptrCast(@constCast(&webChromeToggleSidebarCallback)),
        "v@:@",
    );
    _ = objc.class_addMethod(
        webChromeResponderClass,
        sel("goWebBack:"),
        @ptrCast(@constCast(&webChromeBackCallback)),
        "v@:@",
    );
    _ = objc.class_addMethod(
        webChromeResponderClass,
        sel("goWebForward:"),
        @ptrCast(@constCast(&webChromeForwardCallback)),
        "v@:@",
    );

    objc.objc_registerClassPair(webChromeResponderClass);
}

fn addWebSidebarChromeControls(window: objc.id, webview: objc.id) void {
    if (window == null or webview == null) return;

    ensureWebChromeResponder();
    if (webChromeResponderClass == null) return;

    const contentView = msgSend0(window, "contentView");
    const themeFrame = if (contentView != null) msgSend0(contentView, "superview") else null;
    if (themeFrame == null) return;

    const NSButton = getClass("NSButton");
    const NSImage = getClass("NSImage");
    const responder_alloc = msgSend0(webChromeResponderClass, "alloc");
    const responder = msgSend1Rect(responder_alloc, "initWithFrame:", .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 0, .height = 0 },
    });
    _ = msgSend1(themeFrame, "addSubview:", responder);

    // Only the button's x is read from its frame; see `titlebarControlY` for
    // why its y cannot be mixed with the theme frame's.
    const closeButton = msgSend1(window, "standardWindowButton:", @as(c_ulong, 0));
    const closeX: f64 = if (closeButton != null) msgSendRect(closeButton, "frame").origin.x else 20.0;
    const buttonSize = NSSize{ .width = 28.0, .height = 28.0 };
    const buttonY = titlebarControlY(window, themeFrame, buttonSize.height);
    const firstButtonX = closeX + 68.0;
    const buttonGap = 42.0;

    const buttons = [_]struct {
        symbol: []const u8,
        action: [*:0]const u8,
        tooltip: []const u8,
        x: f64,
    }{
        .{ .symbol = "sidebar.left", .action = "toggleWebSidebar:", .tooltip = "Toggle Sidebar", .x = firstButtonX },
        .{ .symbol = "chevron.left", .action = "goWebBack:", .tooltip = "Go Back", .x = firstButtonX + buttonGap },
        .{ .symbol = "chevron.right", .action = "goWebForward:", .tooltip = "Go Forward", .x = firstButtonX + (buttonGap * 2.0) },
    };

    for (buttons) |button| {
        const symbolName = createNSString(button.symbol);
        const image = msgSend2(NSImage, "imageWithSystemSymbolName:accessibilityDescription:", symbolName, @as(?*anyopaque, null));
        const btn_alloc = msgSend0(NSButton, "alloc");
        const btn = msgSend1Rect(btn_alloc, "initWithFrame:", .{
            .origin = .{ .x = button.x, .y = buttonY },
            .size = buttonSize,
        });
        _ = msgSend1(btn, "setImage:", image);
        _ = msgSend1(btn, "setBezelStyle:", @as(c_long, 0));
        _ = msgSend1(btn, "setBordered:", @as(c_int, 0));
        _ = msgSend1(btn, "setTarget:", responder);
        _ = msgSend1(btn, "setAction:", sel(button.action));
        _ = msgSend1(btn, "setToolTip:", createNSString(button.tooltip));
        msgSendVoid1(btn, "setAutoresizingMask:", titlebar_control_autoresizing_mask);
        _ = msgSend1(themeFrame, "addSubview:", btn);
        if (std.mem.eql(u8, button.symbol, "sidebar.left")) {
            web_sidebar_toggle_button = btn;
        }
    }
}

/// Create a window with native sidebar loading a URL instead of inline HTML
pub fn createWindowWithSidebarURL(
    title: []const u8,
    width: u32,
    height: u32,
    url: []const u8,
    sidebar_width: u32,
    sidebar_config: ?[]const u8,
    style: WindowStyle,
) !objc.id {
    // Parse sidebar config if provided
    if (sidebar_config) |config| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[NativeSidebar] Parsing sidebar config ({d} bytes)\n", .{config.len});
        parseSidebarConfig(config) catch |err| {
            if (comptime builtin.mode == .debug)
                std.debug.print("[NativeSidebar] Failed to parse config: {}\n", .{err});
        };
    }

    // Import the necessary classes
    const NSApplication = getClass("NSApplication");
    const NSWindow = getClass("NSWindow");
    const WKWebView = getClass("WKWebView");
    const WKWebViewConfiguration = getClass("WKWebViewConfiguration");
    const WKPreferences = getClass("WKPreferences");
    const WKUserContentController = getClass("WKUserContentController");
    const NSURL = getClass("NSURL");

    // Get shared application
    const app = msgSend0(NSApplication, "sharedApplication");
    _ = msgSend1(app, "setActivationPolicy:", @as(c_long, 0));

    // Create window frame
    const frame = NSRect{
        .origin = .{
            .x = if (style.x) |x| @floatFromInt(x) else 100,
            .y = if (style.y) |y| @floatFromInt(y) else 100,
        },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    };

    var styleMask: c_ulong = 1 | 2 | 4 | 8; // Titled, Closable, Miniaturizable, Resizable
    styleMask |= 32768; // NSWindowStyleMaskFullSizeContentView

    const backing: c_ulong = 2;
    const defer_flag: bool = false;

    const window_alloc = msgSend0(NSWindow, "alloc");
    const window = msgSend4(window_alloc, "initWithContentRect:styleMask:backing:defer:", frame, styleMask, backing, defer_flag);

    // Set window title
    const title_str = createNSString(title);
    _ = msgSend1(window, "setTitle:", title_str);

    // Simple window configuration - no transparent titlebar or toolbar
    _ = msgSend1(window, "setHasShadow:", @as(c_int, 1));

    // Apply dark mode appearance with VibrantDark for proper sidebar vibrancy
    const NSAppearance = getClass("NSAppearance");
    const is_dark = if (style.dark_mode) |dm| dm else false;
    const appearanceName = if (is_dark)
        createNSString("NSAppearanceNameVibrantDark")
    else
        createNSString("NSAppearanceNameVibrantLight");
    const dark_appearance = msgSend1(NSAppearance, "appearanceNamed:", appearanceName);
    if (dark_appearance != null) {
        _ = msgSend1(window, "setAppearance:", dark_appearance);
    }

    // Configure for native sidebar appearance
    _ = msgSend1(window, "setTitlebarAppearsTransparent:", @as(c_int, 1));
    _ = msgSend1(window, "setTitleVisibility:", @as(c_int, 1)); // NSWindowTitleHidden = 1
    _ = msgSend1(window, "setHasShadow:", @as(c_int, 1));
    _ = msgSend1(window, "setTitlebarSeparatorStyle:", @as(c_long, 0)); // NSTitlebarSeparatorStyleNone = 0

    // Create NSToolbar - REQUIRED for traffic lights to appear in sidebar
    const NSToolbar = getClass("NSToolbar");
    const toolbar_id = createNSString("MainToolbar");
    const toolbar_alloc = msgSend0(NSToolbar, "alloc");
    const toolbar = msgSend1(toolbar_alloc, "initWithIdentifier:", toolbar_id);
    _ = msgSend1(toolbar, "setShowsBaselineSeparator:", @as(c_int, 0));
    _ = msgSend1(window, "setToolbar:", toolbar);
    _ = msgSend1(window, "setToolbarStyle:", @as(c_long, 3)); // NSWindowToolbarStyleUnifiedCompact = 3

    // Store sidebar width for toggle animation
    sidebar_width_stored = @floatFromInt(sidebar_width);

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Window created with toolbar\n", .{});

    // ========================================
    // TAHOE-STYLE FLOATING SIDEBAR
    // Left side: purple background with floating sidebar
    // Right side: WebView content
    // ========================================

    const NSViewClass = getClass("NSView");
    const NSScrollView = getClass("NSScrollView");
    const NSOutlineView = getClass("NSOutlineView");
    const NSTableColumn = getClass("NSTableColumn");
    const NSColor = getClass("NSColor");

    // Set window background so translucent desktop sidebars can let the surface shimmer through.
    const bgRed: f64 = if (sidebar_uses_desktop_material) 244.0 / 255.0 else 15.0 / 255.0;
    const bgGreen: f64 = if (sidebar_uses_desktop_material) 244.0 / 255.0 else 15.0 / 255.0;
    const bgBlue: f64 = if (sidebar_uses_desktop_material) 243.0 / 255.0 else 35.0 / 255.0;
    const windowBgColor = msgSend4(
        NSColor,
        "colorWithRed:green:blue:alpha:",
        bgRed,
        bgGreen,
        bgBlue,
        @as(f64, 1.0),
    );
    _ = msgSend1(window, "setBackgroundColor:", windowBgColor);

    // Main container fills the window
    const containerFrame = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    };
    const mainContainer_alloc = msgSend0(NSViewClass, "alloc");
    const mainContainer = msgSend1Rect(mainContainer_alloc, "initWithFrame:", containerFrame);
    msgSendVoid1(mainContainer, "setAutoresizingMask:", @as(c_ulong, 2 | 16)); // Width + Height

    // ========================================
    // Content WebView - positioned to the RIGHT of sidebar area
    // ========================================
    const contentFrame = NSRect{
        .origin = .{ .x = @floatFromInt(sidebar_width), .y = 0 },
        .size = .{ .width = @floatFromInt(width - sidebar_width), .height = @floatFromInt(height) },
    };

    const config_alloc = msgSend0(WKWebViewConfiguration, "alloc");
    const config = msgSend0(config_alloc, "init");

    const prefs_alloc = msgSend0(WKPreferences, "alloc");
    const prefs = msgSend0(prefs_alloc, "init");
    msgSendVoid1(prefs, "setJavaScriptEnabled:", true);

    const key_str = createNSString("developerExtrasEnabled");
    const value_obj = msgSend1(msgSend0(getClass("NSNumber"), "alloc"), "initWithBool:", true);
    msgSendVoid2(prefs, "setValue:forKey:", value_obj, key_str);
    _ = msgSend1(config, "setPreferences:", prefs);

    const userContentController = msgSend0(msgSend0(WKUserContentController, "alloc"), "init");
    setupScriptMessageHandler(userContentController) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Failed to setup message handler: {}\n", .{err});
    };

    // Minimal bridge (no menubar/tray polling), plus the native UI surface and
    // the sidebar bootstrap this window type needs.
    injectCraftScripts(userContentController, .{
        .full_bridge = false,
        .sidebar_bootstrap = true,
        .native_ui = true,
    });

    _ = msgSend1(config, "setUserContentController:", userContentController);

    const webview_alloc = msgSend0(WKWebView, "alloc");
    const webview = msgSend2(webview_alloc, "initWithFrame:configuration:", contentFrame, config);
    makeWindowTranslucent(window);
    makeViewLayerTransparent(mainContainer);
    makeWebViewTransparent(webview);

    setupUIDelegate(webview) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Media] Failed to setup UI delegate: {}\n", .{err});
    };

    // This is the path that loads a URL straight into a sidebar window — the
    // one a local dashboard actually goes through.
    setupNavigationDelegate(webview) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Nav] Failed to setup navigation delegate: {}\n", .{err});
    };

    msgSendVoid1(webview, "setAutoresizingMask:", @as(c_ulong, 2 | 16 | 4)); // Width + Height + Left margin flexible

    // Load URL
    const url_str = createNSString(url);
    const nsurl = msgSend1(NSURL, "URLWithString:", url_str);
    const request = msgSend1(getClass("NSURLRequest"), "requestWithURL:", nsurl);
    _ = msgSend1(webview, "loadRequest:", request);

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] WebView loading URL (full window): {s}\n", .{url});

    sidebar_webview = webview;

    // Add webview to main container FIRST (it goes behind)
    _ = msgSend1(mainContainer, "addSubview:", webview);

    // ========================================
    // FLOATING SIDEBAR - Tahoe style with rounded corners and shadow
    // Extends into titlebar area so traffic lights are inside
    // ========================================
    const sidebar_margin: f64 = 12.0; // Visible gap around sidebar (left, right, bottom)
    const sidebar_top_margin: f64 = 8.0; // Small top margin (traffic lights will be inside)
    const corner_radius: f64 = 14.0;

    const sidebarFrame = NSRect{
        .origin = .{ .x = sidebar_margin, .y = sidebar_margin },
        .size = .{
            .width = @as(f64, @floatFromInt(sidebar_width)) - (sidebar_margin * 2),
            .height = @as(f64, @floatFromInt(height)) - sidebar_top_margin - sidebar_margin,
        },
    };

    // Create sidebar container with rounded corners
    const sidebarContainer_alloc = msgSend0(NSViewClass, "alloc");
    const sidebarContainer = msgSend1Rect(sidebarContainer_alloc, "initWithFrame:", sidebarFrame);
    msgSendVoid1(sidebarContainer, "setAutoresizingMask:", @as(c_ulong, 16)); // Height sizable only

    // Enable layer backing for rounded corners, background, and SHADOW
    _ = msgSend1(sidebarContainer, "setWantsLayer:", @as(c_int, 1));
    const sidebarLayer = msgSend0(sidebarContainer, "layer");
    if (sidebarLayer != null) {
        // Set corner radius for Tahoe-style rounded corners
        _ = msgSend1(sidebarLayer, "setCornerRadius:", corner_radius);
        // Don't mask to bounds so shadow can show
        _ = msgSend1(sidebarLayer, "setMasksToBounds:", @as(c_int, 0));

        const sidebarRed: f64 = if (sidebar_allows_vibrancy) 1.0 else 26.0 / 255.0;
        const sidebarGreen: f64 = if (sidebar_allows_vibrancy) 1.0 else 26.0 / 255.0;
        const sidebarBlue: f64 = if (sidebar_allows_vibrancy) 1.0 else 46.0 / 255.0;
        const sidebarAlpha: f64 = if (sidebar_allows_vibrancy) 0.0 else 0.90;
        const customBgColor = msgSend4(
            NSColor,
            "colorWithRed:green:blue:alpha:",
            sidebarRed,
            sidebarGreen,
            sidebarBlue,
            sidebarAlpha,
        );
        const cgColor = msgSend0(customBgColor, "CGColor");
        if (cgColor != null) {
            _ = msgSend1(sidebarLayer, "setBackgroundColor:", cgColor);
        }

        // Add shadow for floating effect
        _ = msgSend1(sidebarLayer, "setShadowOpacity:", if (sidebar_uses_desktop_material) @as(f32, 0.16) else @as(f32, 0.4));
        _ = msgSend1(sidebarLayer, "setShadowRadius:", if (sidebar_uses_desktop_material) @as(f64, 20.0) else @as(f64, 8.0));
        const shadowOffset = NSSize{ .width = 0, .height = -2 };
        _ = msgSend1(sidebarLayer, "setShadowOffset:", shadowOffset);
        const shadowColor = msgSend4(NSColor, "colorWithRed:green:blue:alpha:", @as(f64, 0.0), @as(f64, 0.0), @as(f64, 0.0), @as(f64, 1.0));
        _ = msgSend1(sidebarLayer, "setShadowColor:", msgSend0(shadowColor, "CGColor"));

        if (comptime builtin.mode == .debug)
            std.debug.print("[NativeSidebar] Floating sidebar with shadow created\n", .{});
    }

    if (sidebar_allows_vibrancy) {
        const materialFrame = NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = sidebarFrame.size,
        };
        const materialView = createSidebarVisualEffectView(materialFrame, corner_radius);
        if (materialView != null) {
            _ = msgSend1(sidebarContainer, "addSubview:", materialView);
        }
        const materialTint = createSidebarMaterialTint(materialFrame, sidebar_material_opacity);
        if (materialTint != null) {
            _ = msgSend1(sidebarContainer, "addSubview:", materialTint);
        }
    }

    // Create scroll view for sidebar content
    const scrollViewFrame = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = sidebarFrame.size,
    };
    const scrollView_alloc = msgSend0(NSScrollView, "alloc");
    const scrollView = msgSend1Rect(scrollView_alloc, "initWithFrame:", scrollViewFrame);
    _ = msgSend1(scrollView, "setHasVerticalScroller:", @as(c_int, 1));
    _ = msgSend1(scrollView, "setHasHorizontalScroller:", @as(c_int, 0));
    _ = msgSend1(scrollView, "setAutohidesScrollers:", @as(c_int, 1));
    _ = msgSend1(scrollView, "setBorderType:", @as(c_long, 0));
    _ = msgSend1(scrollView, "setDrawsBackground:", @as(c_int, 0));
    _ = msgSend1(scrollView, "setBackgroundColor:", msgSend0(getClass("NSColor"), "clearColor"));
    msgSendVoid1(scrollView, "setAutoresizingMask:", @as(c_ulong, 2 | 16));

    // Create outline view
    const outlineView_alloc = msgSend0(NSOutlineView, "alloc");
    const outlineView = msgSend1Rect(outlineView_alloc, "initWithFrame:", scrollViewFrame);
    _ = msgSend1(outlineView, "setStyle:", @as(c_long, 1)); // Source list style
    _ = msgSend1(outlineView, "setSelectionHighlightStyle:", @as(c_long, 1));
    _ = msgSend1(outlineView, "setRowSizeStyle:", @as(c_long, 2));
    _ = msgSend1(outlineView, "setFloatsGroupRows:", @as(c_int, 0)); // Disable floating to prevent first row special treatment
    _ = msgSend1(outlineView, "setIndentationPerLevel:", @as(f64, 13.0));
    _ = msgSend1(outlineView, "setHeaderView:", @as(?*anyopaque, null));
    _ = msgSend1(outlineView, "setUsesAlternatingRowBackgroundColors:", @as(c_int, 0));
    _ = msgSend1(outlineView, "setBackgroundColor:", msgSend0(getClass("NSColor"), "clearColor"));

    // Create table column
    const columnId = createNSString("SidebarColumn");
    const column_alloc = msgSend0(NSTableColumn, "alloc");
    const column = msgSend1(column_alloc, "initWithIdentifier:", columnId);
    _ = msgSend1(column, "setWidth:", sidebarFrame.size.width - 20);
    _ = msgSend1(outlineView, "addTableColumn:", column);
    _ = msgSend1(outlineView, "setOutlineTableColumn:", column);

    // Setup data source
    const dataSource = try setupSidebarDataSource();
    _ = msgSend1(outlineView, "setDataSource:", dataSource);
    _ = msgSend1(outlineView, "setDelegate:", dataSource);
    _ = msgSend0(outlineView, "reloadData");

    // Expand sections
    const numRows = msgSendNSInteger(outlineView, "numberOfRows");
    var i: c_long = 0;
    while (i < numRows) : (i += 1) {
        const item = msgSend1(outlineView, "itemAtRow:", i);
        if (item != null) {
            _ = msgSend1(outlineView, "expandItem:", item);
        }
    }

    _ = msgSend1(scrollView, "setDocumentView:", outlineView);
    _ = msgSend1(sidebarContainer, "addSubview:", scrollView);

    // Add floating sidebar ON TOP of webview
    _ = msgSend1(mainContainer, "addSubview:", sidebarContainer);

    // Store references for sidebar toggle
    sidebar_container = sidebarContainer;
    sidebar_content_webview = webview;
    sidebar_collapsed = false;

    // Set main container as window content view
    _ = msgSend1(window, "setContentView:", mainContainer);

    // Add sidebar toggle button directly to the titlebar area
    ensureSidebarToggleResponder();
    if (sidebarToggleResponderClass != null) {
        const NSButton = getClass("NSButton");
        const NSImage = getClass("NSImage");

        // Create the responder that handles toggleSidebar:
        const responder_alloc = msgSend0(sidebarToggleResponderClass, "alloc");
        const responderFrame = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
        const responder = msgSend1Rect(responder_alloc, "initWithFrame:", responderFrame);
        _ = msgSend1(mainContainer, "addSubview:", responder);

        // Create toggle button with sidebar.left SF Symbol
        const symbolName = createNSString("sidebar.left");
        const image = msgSend2(NSImage, "imageWithSystemSymbolName:accessibilityDescription:", symbolName, @as(?*anyopaque, null));

        const btnFrame = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 28, .height = 22 } };
        const toggleBtn_alloc = msgSend0(NSButton, "alloc");
        const toggleBtn = msgSend1Rect(toggleBtn_alloc, "initWithFrame:", btnFrame);
        _ = msgSend1(toggleBtn, "setImage:", image);
        _ = msgSend1(toggleBtn, "setBezelStyle:", @as(c_long, 0)); // NSBezelStyleAutomatic
        _ = msgSend1(toggleBtn, "setBordered:", @as(c_int, 0));
        _ = msgSend1(toggleBtn, "setTarget:", responder);
        _ = msgSend1(toggleBtn, "setAction:", sel("toggleSidebar:"));
        _ = msgSend1(toggleBtn, "setToolTip:", createNSString("Toggle Sidebar"));

        // Store reference for repositioning on toggle
        sidebar_toggle_btn = toggleBtn;

        // Position it in the titlebar by adding to the window's contentView's superview (themeFrame)
        // Traffic lights are at roughly x=7..67, y centered in titlebar (38px high)
        const contentView = msgSend0(window, "contentView");
        const themeFrame = msgSend0(contentView, "superview");
        if (themeFrame != null) {
            // Position at the right edge of the sidebar area
            const btnX: f64 = @as(f64, @floatFromInt(sidebar_width)) - 28.0 - 12.0;
            const themeFrameHeight = msgSendRect(themeFrame, "frame").size.height;
            const titlebarHeight: f64 = 52.0;
            const btnH: f64 = 22.0;
            const btnY: f64 = themeFrameHeight - titlebarHeight + (titlebarHeight - btnH) / 2.0;
            msgSendVoid1Rect(toggleBtn, "setFrame:", .{
                .origin = .{ .x = btnX, .y = btnY },
                .size = .{ .width = 28, .height = 22 },
            });
            msgSendVoid1(toggleBtn, "setAutoresizingMask:", titlebar_control_autoresizing_mask);
            _ = msgSend1(themeFrame, "addSubview:", toggleBtn);
        }
    }

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] Tahoe-style floating sidebar configured\n", .{});

    // Center window
    if (style.x == null or style.y == null) {
        msgSendVoid0(window, "center");
    }

    // Store references
    if (webview) |wv| {
        setGlobalWebView(wv);
        const tray_menu = @import("tray_menu.zig");
        tray_menu.setGlobalWebView(wv);
        if (window) |win| {
            tray_menu.setGlobalWindow(win);
        }
    }

    setupBridgeHandlers(std.heap.c_allocator, null, window) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Failed to setup bridge handlers: {}\n", .{err});
    };

    if (comptime builtin.mode == .debug)
        std.debug.print("[NativeSidebar] ✓ Window with native sidebar (URL mode) created\n", .{});

    // Make visible
    _ = msgSend1(window, "makeKeyAndOrderFront:", @as(?*anyopaque, null));
    _ = msgSend1(app, "activateIgnoringOtherApps:", @as(c_int, 1));

    return window;
}

// Helper to send message with NSRect parameter
pub fn msgSend1Rect(target: anytype, selector: [*:0]const u8, rect: NSRect) objc.id {
    const msg = @as(*const fn (@TypeOf(target), objc.SEL, NSRect) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return msg(target, sel(selector), rect);
}

// Helper to create NSString
pub fn createNSString(str: []const u8) objc.id {
    const NSString = getClass("NSString");
    const cstr = @import("memory.zig").dupeZ(std.heap.c_allocator, u8, str) catch |err| {
        std.log.warn("createNSString: failed to allocate null-terminated string: {}", .{err});
        return msgSend1(NSString, "stringWithUTF8String:", @as([*:0]const u8, ""));
    };
    defer std.heap.c_allocator.free(cstr);
    return msgSend1(NSString, "stringWithUTF8String:", cstr.ptr);
}

// Clipboard functions
pub fn setClipboard(text: []const u8) !void {
    const NSPasteboard = getClass("NSPasteboard");
    const pasteboard = msgSend0(NSPasteboard, "generalPasteboard");
    msgSendVoid0(pasteboard, "clearContents");

    const text_str = createNSString(text);
    const pasteboard_type = createNSString("public.utf8-plain-text");
    _ = msgSend2(pasteboard, "setString:forType:", text_str, pasteboard_type);
}

pub fn getClipboard(allocator: std.mem.Allocator) ![]const u8 {
    const NSPasteboard = getClass("NSPasteboard");
    const pasteboard = msgSend0(NSPasteboard, "generalPasteboard");
    const pasteboard_type = createNSString("public.utf8-plain-text");
    const str = msgSend1(pasteboard, "stringForType:", pasteboard_type);

    if (str == null) return error.NoClipboardContent;

    const cstr: [*:0]const u8 = @ptrCast(msgSend0(str, "UTF8String"));
    return allocator.dupe(u8, std.mem.span(cstr));
}

// Native dialog support
pub fn showOpenDialog(title: []const u8, allow_multiple: bool) !?[]const u8 {
    const NSOpenPanel = getClass("NSOpenPanel");
    const panel = msgSend0(NSOpenPanel, "openPanel");

    // Set title
    const title_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title);
    defer std.heap.c_allocator.free(title_cstr);
    const title_str_alloc = msgSend0(getClass("NSString"), "alloc");
    const title_str = msgSend1(title_str_alloc, "initWithUTF8String:", title_cstr.ptr);
    _ = msgSend1(panel, "setTitle:", title_str);

    // Set options
    _ = msgSend1(panel, "setCanChooseFiles:", true);
    _ = msgSend1(panel, "setCanChooseDirectories:", false);
    _ = msgSend1(panel, "setAllowsMultipleSelection:", allow_multiple);

    // Run modal
    const result = msgSend0(panel, "runModal");
    const NSModalResponseOK: c_long = 1;

    if (@as(c_long, @intCast(@intFromPtr(result))) != NSModalResponseOK) {
        return null;
    }

    // Get selected URL
    const urls = msgSend0(panel, "URLs");
    const count = @as(usize, @intCast(@intFromPtr(msgSend0(urls, "count"))));

    if (count == 0) return null;

    const url = msgSend1(urls, "objectAtIndex:", @as(c_ulong, 0));
    const path = msgSend0(url, "path");
    const cstr: [*:0]const u8 = @ptrCast(msgSend0(path, "UTF8String"));

    return std.heap.c_allocator.dupe(u8, std.mem.span(cstr));
}

pub fn showSaveDialog(title: []const u8, default_name: ?[]const u8) !?[]const u8 {
    const NSSavePanel = getClass("NSSavePanel");
    const panel = msgSend0(NSSavePanel, "savePanel");

    // Set title
    const title_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title);
    defer std.heap.c_allocator.free(title_cstr);
    const title_str_alloc = msgSend0(getClass("NSString"), "alloc");
    const title_str = msgSend1(title_str_alloc, "initWithUTF8String:", title_cstr.ptr);
    _ = msgSend1(panel, "setTitle:", title_str);

    // Set default name if provided
    if (default_name) |name| {
        const name_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, name);
        defer std.heap.c_allocator.free(name_cstr);
        const name_str_alloc = msgSend0(getClass("NSString"), "alloc");
        const name_str = msgSend1(name_str_alloc, "initWithUTF8String:", name_cstr.ptr);
        _ = msgSend1(panel, "setNameFieldStringValue:", name_str);
    }

    // Run modal
    const result = msgSend0(panel, "runModal");
    const NSModalResponseOK: c_long = 1;

    if (@as(c_long, @intCast(@intFromPtr(result))) != NSModalResponseOK) {
        return null;
    }

    // Get selected URL
    const url = msgSend0(panel, "URL");
    const path = msgSend0(url, "path");
    const cstr: [*:0]const u8 = @ptrCast(msgSend0(path, "UTF8String"));

    return std.heap.c_allocator.dupe(u8, std.mem.span(cstr));
}

// Window control functions
pub fn minimizeWindow(window_handle: anytype) void {
    const window: objc.id = if (@TypeOf(window_handle) == objc.id) window_handle else @ptrFromInt(@intFromPtr(window_handle));
    msgSendVoid0(window, "miniaturize:");
}

pub fn maximizeWindow(window: objc.id) void {
    msgSendVoid0(window, "zoom:");
}

pub fn toggleFullscreen(window: objc.id) void {
    msgSendVoid0(window, "toggleFullScreen:");
}

pub fn closeWindow(window_handle: anytype) void {
    const window: objc.id = if (@TypeOf(window_handle) == objc.id) window_handle else @ptrFromInt(@intFromPtr(window_handle));
    msgSendVoid0(window, "close");
}

pub fn hideWindow(window_handle: anytype) void {
    const window: objc.id = if (@TypeOf(window_handle) == objc.id) window_handle else @ptrFromInt(@intFromPtr(window_handle));
    msgSendVoid0(window, "orderOut:");
}

pub fn showWindow(window_handle: anytype) void {
    const window: objc.id = if (@TypeOf(window_handle) == objc.id) window_handle else @ptrFromInt(@intFromPtr(window_handle));
    _ = msgSend1(window, "makeKeyAndOrderFront:", @as(?*anyopaque, null));
}

pub fn toggleWindow(window_handle: anytype) void {
    const window: objc.id = if (@TypeOf(window_handle) == objc.id) window_handle else @ptrFromInt(@intFromPtr(window_handle));
    const is_visible = msgSend0(window, "isVisible");
    const visible_int = @as(c_int, @intCast(@intFromPtr(is_visible)));

    if (visible_int != 0) {
        hideWindow(window);
    } else {
        showWindow(window);
    }
}

pub fn setWindowPosition(window: objc.id, x: i32, y: i32) void {
    const point = NSPoint{ .x = @as(f64, @floatFromInt(x)), .y = @as(f64, @floatFromInt(y)) };
    msgSendVoid1(window, "setFrameTopLeftPoint:", point);
}

pub fn moveWindowBy(window: objc.id, dx: f64, dy: f64) void {
    var frame = msgSendRect(window, "frame");
    frame.origin.x += dx;
    frame.origin.y -= dy;
    msgSendVoid1(window, "setFrameOrigin:", frame.origin);
}

pub fn startWindowDrag(window: objc.id) void {
    const app = msgSend0(getClass("NSApplication"), "sharedApplication");
    if (app == null) return;

    const event = msgSend0(app, "currentEvent");
    if (event == null) return;

    _ = msgSend1(window, "performWindowDragWithEvent:", event);
}

pub fn setWindowSize(window: objc.id, width: u32, height: u32) void {
    var frame = msgSendRect(window, "frame");
    frame.size.width = @as(f64, @floatFromInt(width));
    frame.size.height = @as(f64, @floatFromInt(height));
    msgSendVoid2(window, "setFrame:display:", frame, true);
}

// Notification support
pub fn showNotification(title: []const u8, message: []const u8) !void {
    const NSUserNotification = getClass("NSUserNotification");
    const NSUserNotificationCenter = getClass("NSUserNotificationCenter");

    const notification = msgSend0(msgSend0(NSUserNotification, "alloc"), "init");

    // Set title
    const title_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title);
    defer std.heap.c_allocator.free(title_cstr);
    const title_str_alloc = msgSend0(getClass("NSString"), "alloc");
    const title_str = msgSend1(title_str_alloc, "initWithUTF8String:", title_cstr.ptr);
    _ = msgSend1(notification, "setTitle:", title_str);

    // Set message
    const msg_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, message);
    defer std.heap.c_allocator.free(msg_cstr);
    const msg_str_alloc = msgSend0(getClass("NSString"), "alloc");
    const msg_str = msgSend1(msg_str_alloc, "initWithUTF8String:", msg_cstr.ptr);
    _ = msgSend1(notification, "setInformativeText:", msg_str);

    // Deliver notification
    const center = msgSend0(NSUserNotificationCenter, "defaultUserNotificationCenter");
    msgSendVoid1(center, "deliverNotification:", notification);
}

// Hot reload - reload URL in webview
pub fn reloadWindow(webview: objc.id) void {
    msgSendVoid0(webview, "reload:");
}

pub fn reloadWindowIgnoringCache(webview: objc.id) void {
    msgSendVoid0(webview, "reloadFromOrigin:");
}

// System tray integration
pub const SystemTray = struct {
    status_item: objc.id,

    pub fn create(title: []const u8) !SystemTray {
        const NSStatusBar = getClass("NSStatusBar");
        const status_bar = msgSend0(NSStatusBar, "systemStatusBar");

        const status_item = msgSend1(status_bar, "statusItemWithLength:", -1.0);

        // Set title
        const title_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title);
        defer std.heap.c_allocator.free(title_cstr);
        const title_str_alloc = msgSend0(getClass("NSString"), "alloc");
        const title_str = msgSend1(title_str_alloc, "initWithUTF8String:", title_cstr.ptr);

        const button = msgSend0(status_item, "button");
        _ = msgSend1(button, "setTitle:", title_str);

        return .{ .status_item = status_item };
    }

    pub fn setTitle(self: SystemTray, title: []const u8) !void {
        const title_cstr = try @import("memory.zig").dupeZ(std.heap.c_allocator, u8, title);
        defer std.heap.c_allocator.free(title_cstr);
        const title_str_alloc = msgSend0(getClass("NSString"), "alloc");
        const title_str = msgSend1(title_str_alloc, "initWithUTF8String:", title_cstr.ptr);

        const button = msgSend0(self.status_item, "button");
        _ = msgSend1(button, "setTitle:", title_str);
    }

    pub fn remove(self: SystemTray) void {
        const NSStatusBar = getClass("NSStatusBar");
        const status_bar = msgSend0(NSStatusBar, "systemStatusBar");
        msgSendVoid1(status_bar, "removeStatusItem:", self.status_item);
    }
};

// Keyboard shortcuts/hotkeys
pub fn registerGlobalHotkey(key_code: u16, modifiers: u32) void {
    // This would require NSEvent monitoring
    // For now, we'll provide the structure
    _ = key_code;
    _ = modifiers;
}

// Multi-monitor awareness
pub const Monitor = struct {
    frame: NSRect,
    visible_frame: NSRect,
    name: []const u8,
};

pub fn getAllMonitors(allocator: std.mem.Allocator) ![]Monitor {
    const NSScreen = getClass("NSScreen");
    const screens = msgSend0(NSScreen, "screens");
    const count_obj = msgSend0(screens, "count");
    const count = @as(usize, @intCast(@as(i64, @bitCast(count_obj))));

    var monitors = try allocator.alloc(Monitor, count);

    for (0..count) |i| {
        const screen = msgSend1(screens, "objectAtIndex:", i);
        const frame = msgSend0(screen, "frame");
        const visible_frame = msgSend0(screen, "visibleFrame");

        monitors[i] = .{
            .frame = @as(NSRect, @bitCast(frame)),
            .visible_frame = @as(NSRect, @bitCast(visible_frame)),
            .name = "", // Would need to get from screen description
        };
    }

    return monitors;
}

pub fn getMainMonitor() Monitor {
    const NSScreen = getClass("NSScreen");
    const main_screen = msgSend0(NSScreen, "mainScreen");
    const frame = msgSend0(main_screen, "frame");
    const visible_frame = msgSend0(main_screen, "visibleFrame");

    return .{
        .frame = @as(NSRect, @bitCast(frame)),
        .visible_frame = @as(NSRect, @bitCast(visible_frame)),
        .name = "Main",
    };
}

// Screenshot/capture
pub fn captureWindow(window: objc.id, file_path: []const u8) !void {
    const window_id = msgSend0(window, "windowNumber");
    const CGWindowListCreateImage = @as(*const fn (NSRect, u32, u32, u32) callconv(.c) ?*anyopaque, @ptrFromInt(0)); // Placeholder
    _ = CGWindowListCreateImage;
    _ = window_id;
    _ = file_path;
    // Would need Core Graphics bindings for full implementation
}

pub fn captureScreen(file_path: []const u8) !void {
    _ = file_path;
    // Would need Core Graphics bindings
}

// Print support
pub fn printWindow(webview: objc.id) void {
    // Create print operation
    const print_op = msgSend0(webview, "printOperationWithPrintInfo:");
    msgSendVoid0(print_op, "runOperation");
}

pub fn showPrintDialog(webview: objc.id) void {
    const NSPrintInfo = getClass("NSPrintInfo");
    const print_info = msgSend0(NSPrintInfo, "sharedPrintInfo");

    const print_op_class = getClass("NSPrintOperation");
    const print_op = msgSend2(print_op_class, "printOperationWithView:printInfo:", webview, print_info);
    _ = msgSend1(print_op, "runOperationModalForWindow:delegate:didRunSelector:contextInfo:", @as(?*anyopaque, null));
}

// Download management
pub const Download = struct {
    url: []const u8,
    destination: []const u8,
    progress: f64 = 0.0,
};

pub fn startDownload(url: []const u8, destination: []const u8) !Download {
    return .{
        .url = url,
        .destination = destination,
        .progress = 0.0,
    };
}

// Theme support (dark/light mode)
pub fn setAppearance(window: objc.id, dark_mode: bool) void {
    const NSAppearanceClass = getClass("NSAppearance");
    const NSString = getClass("NSString");
    const appearance_name: [*:0]const u8 = if (dark_mode) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua";

    // appearanceNamed: expects an NSString, not a C string
    const name_str = msgSend1(msgSend0(NSString, "alloc"), "initWithUTF8String:", appearance_name);
    const appearance = msgSend1(NSAppearanceClass, "appearanceNamed:", name_str);

    if (appearance != null) {
        _ = msgSend1(window, "setAppearance:", appearance);
    }
}

pub fn getSystemAppearance() bool {
    const NSApp = getClass("NSApplication");
    const app = msgSend0(NSApp, "sharedApplication");
    const appearance = msgSend0(app, "effectiveAppearance");
    const name = msgSend0(appearance, "name");

    // Check if dark mode
    const dark_name_cstr: [*:0]const u8 = "NSAppearanceNameDarkAqua";
    const dark_str_alloc = msgSend0(getClass("NSString"), "alloc");
    const dark_str = msgSend1(dark_str_alloc, "initWithUTF8String:", dark_name_cstr);

    const is_equal = msgSend1(name, "isEqualToString:", dark_str);
    return @as(i64, @bitCast(is_equal)) != 0;
}

// Performance monitoring
pub const PerformanceMetrics = struct {
    memory_usage_mb: f64,
    cpu_usage_percent: f64,
    fps: f64,
};

pub fn getPerformanceMetrics() PerformanceMetrics {
    // Would need to integrate with task_info and mach APIs
    return .{
        .memory_usage_mb = 0.0,
        .cpu_usage_percent = 0.0,
        .fps = 60.0,
    };
}

// Window events
pub const WindowEventType = enum {
    close,
    resize,
    move,
    focus,
    blur,
    minimize,
    maximize,
};

pub const WindowEvent = struct {
    event_type: WindowEventType,
    window: objc.id,
    data: ?*anyopaque = null,
};

// Window event callback (simplified - would need delegate in real implementation)
pub const WindowEventCallback = *const fn (WindowEvent) void;

// Store webview reference for access by window
var global_webview: ?objc.id = null;

pub fn setGlobalWebView(webview: objc.id) void {
    global_webview = webview;
}

pub fn getGlobalWebView() ?objc.id {
    return global_webview;
}

// ============================================================================
// JavaScript Bridge Injection
// ============================================================================

/// Embedded JS bridge — see `js/craft-bridge.js` for the full source.
/// Both minimal and full builds use the same JS file; the only delta is
/// whether tray/menubar polling is enabled, gated by a flag we prepend.
fn getCraftBridgeScriptMinimal() []const u8 {
    return @embedFile("js/craft-bridge.js");
}

fn getCraftBridgeScriptFull() []const u8 {
    // Set the polling flag *before* the bridge IIFE runs so that the
    // setInterval calls at the bottom of craft-bridge.js know to start.
    return "window.__craftEnableTrayPolling = true;\n" ++ @embedFile("js/craft-bridge.js");
}

fn getNativeUIScript() []const u8 {
    return @embedFile("js/craft-native-ui.js");
}

fn getGesturesScript() []const u8 {
    return @embedFile("js/craft-gestures.js");
}

fn getNativeSidebarBootstrapScript() []const u8 {
    return native_sidebar_bootstrap.script;
}

// ============================================================================
// Trackpad swipe phases → window.craft.gestures
//
// A WKWebView's `wheel` stream has no phase information, so web code has to
// guess where a gesture starts and ends. The usual guess — end it after a short
// idle gap — cannot distinguish a finger still on the trackpad from the
// momentum macOS keeps delivering for over a second afterwards, so a web-side
// swipe settles at the end of momentum instead of at finger-up.
//
// We hold the real NSEvent, so we forward its phases instead. A local event
// monitor sees scroll wheels before they are dispatched; we read the phase and
// pass the event through untouched, so normal scrolling is unaffected.
// ============================================================================

const scroll_gesture = @import("scroll_gesture.zig");

/// Block ABI: { isa, flags, reserved, invoke, descriptor }. Same shape the
/// permissions and focus bridges already use; `_NSConcreteStackBlock` is what
/// Apple resolves a block's isa against, so we can hand AppKit a real block
/// without linking libBlocksRuntime.
const ScrollBlockLayout = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*const anyopaque, objc.id) callconv(.c) objc.id,
    descriptor: *const ScrollBlockDescriptor,
};

const ScrollBlockDescriptor = extern struct {
    reserved: usize = 0,
    size: usize,
};

extern var _NSConcreteStackBlock: anyopaque;

var scroll_state: scroll_gesture.State = .{};
var scroll_monitor: ?objc.id = null;

fn emitSwipe(emit: scroll_gesture.Emit) void {
    var buffer: [320]u8 = undefined;
    const js = std.fmt.bufPrint(
        &buffer,
        "window.craft&&window.craft.gestures&&window.craft.gestures._emit({{axis:'horizontal',phase:'{s}',deltaX:{d:.4},deltaY:{d:.4},velocityX:{d:.4},momentum:false}})",
        .{ @tagName(emit.phase), emit.delta_x, emit.delta_y, emit.velocity_x },
    ) catch return;

    // No webview yet (or already torn down) is normal, not an error.
    tryEvalJS(js) catch {};
}

fn scrollMonitorInvoke(_: *const anyopaque, event: objc.id) callconv(.c) objc.id {
    // Always return the event unmodified — we observe, we do not consume.
    // Swallowing it here would break vertical scrolling everywhere.
    if (event == null) return event;

    const emits = scroll_gesture.step(
        &scroll_state,
        msgSend0Ulong(event, "phase"),
        msgSend0Ulong(event, "momentumPhase"),
        msgSend0Double(event, "scrollingDeltaX"),
        msgSend0Double(event, "scrollingDeltaY"),
        msgSend0Double(event, "timestamp"),
    );

    for (emits.slice()) |emit| emitSwipe(emit);

    return event;
}

const scroll_block_descriptor = ScrollBlockDescriptor{ .size = @sizeOf(ScrollBlockLayout) };
var scroll_block = ScrollBlockLayout{
    .isa = &_NSConcreteStackBlock,
    .flags = 0,
    .reserved = 0,
    .invoke = scrollMonitorInvoke,
    .descriptor = &scroll_block_descriptor,
};

/// Install the scroll-wheel monitor once per process. Safe to call repeatedly;
/// a second monitor would deliver every gesture twice.
pub fn installScrollGestureMonitor() void {
    if (scroll_monitor != null) return;

    const NSEvent = getClass("NSEvent");
    scroll_monitor = msgSend2(
        NSEvent,
        "addLocalMonitorForEventsMatchingMask:handler:",
        scroll_gesture.NSEventMaskScrollWheel,
        @as(objc.id, @ptrCast(&scroll_block)),
    );
}

/// Which of the injected scripts a given window wants.
///
/// `bridge` is always injected; the rest are opt-in because a plain window has
/// no sidebar to bootstrap and no native UI to talk to.
pub const CraftScripts = struct {
    /// Full bridge enables tray/menubar polling. Minimal otherwise.
    full_bridge: bool = false,
    sidebar_bootstrap: bool = false,
    native_ui: bool = false,
    /// Install `window.craft.gestures` and the NSEvent scroll monitor behind
    /// it. On by default: the registry is inert until the host emits, and a
    /// swipeable sidebar in any window should feel native.
    gestures: bool = true,
};

/// Add one source string to a content controller as an at-document-start,
/// main-frame-only user script.
fn addUserScriptSource(userContentController: objc.id, source: []const u8) void {
    if (source.len == 0) return;
    const WKUserScript = getClass("WKUserScript");
    const source_str = createNSString(source);
    const script = msgSend3(
        msgSend0(WKUserScript, "alloc"),
        "initWithSource:injectionTime:forMainFrameOnly:",
        source_str,
        @as(c_long, 0), // WKUserScriptInjectionTimeAtDocumentStart
        @as(c_int, 1), // main frame only
    );
    _ = msgSend1(userContentController, "addUserScript:", script);
}

/// Install Craft's JS into a content controller.
///
/// Every window path goes through here, whether it loads a URL or an HTML
/// string. It used to be split: URL loads used `addUserScript:` while HTML
/// loads spliced `<script>` tags into the markup, because `WKUserScript` does
/// not inject reliably into `loadHTMLString:` when the baseURL is null. That
/// caveat no longer applies — every non-benchmark HTML load passes a real
/// `http://localhost/` baseURL — so the workaround outlived its cause while
/// leaving four copies of the injection logic behind.
///
/// Using `addUserScript:` everywhere also fixes a real bug: spliced tags belong
/// to the one document they were spliced into, so any navigation or reload in
/// an HTML-loaded window dropped `window.craft` entirely. A user script at
/// document-start is re-injected on every navigation.
/// Order is load-bearing: the bootstrap ends by dispatching `craft:ready`, and
/// that event means "the whole surface is installed". So the bootstrap goes
/// **last**, after `window.craft.nativeUI` exists. Three of the four call sites
/// this replaced had it the other way round and fired `craft:ready` before the
/// native UI surface was defined, so anything reacting to the event saw a
/// half-built `window.craft`.
pub fn injectCraftScripts(userContentController: objc.id, scripts: CraftScripts) void {
    addUserScriptSource(userContentController, if (scripts.full_bridge)
        getCraftBridgeScriptFull()
    else
        getCraftBridgeScriptMinimal());

    if (scripts.native_ui)
        addUserScriptSource(userContentController, getNativeUIScript());

    if (scripts.gestures) {
        addUserScriptSource(userContentController, getGesturesScript());
        installScrollGestureMonitor();
    }

    if (scripts.sidebar_bootstrap)
        addUserScriptSource(userContentController, getNativeSidebarBootstrapScript());
}

/// Storage for bridge handlers (global state)
var global_tray_bridge: ?*@import("bridge_tray.zig").TrayBridge = null;
var global_window_bridge: ?*@import("bridge_window.zig").WindowBridge = null;
var global_app_bridge: ?*@import("bridge_app.zig").AppBridge = null;
var global_dialog_bridge: ?*@import("bridge_dialog.zig").DialogBridge = null;
var global_native_ui_bridge: ?*@import("bridge_native_ui.zig").NativeUIBridge = null;
var global_notification_bridge: ?*@import("bridge_notification.zig").NotificationBridge = null;
var global_shortcuts_bridge: ?*@import("bridge_shortcuts.zig").ShortcutsBridge = null;
var global_menu_bridge: ?*@import("bridge_menu.zig").MenuBridge = null;
var global_updater_bridge: ?*@import("bridge_updater.zig").UpdaterBridge = null;
var global_touchbar_bridge: ?*@import("bridge_touchbar.zig").TouchBarBridge = null;
var global_fs_bridge: ?*@import("bridge_fs.zig").FSBridge = null;
var global_shell_bridge: ?*@import("bridge_shell.zig").ShellBridge = null;
var global_system_bridge: ?*@import("bridge_system.zig").SystemBridge = null;
var global_power_bridge: ?*@import("bridge_power.zig").PowerBridge = null;
var global_network_bridge: ?*@import("bridge_network.zig").NetworkBridge = null;
var global_bluetooth_bridge: ?*@import("bridge_bluetooth.zig").BluetoothBridge = null;
var global_tray_handle_for_bridge: ?*anyopaque = null;
var global_clipboard_bridge: ?*@import("bridge_clipboard.zig").ClipboardBridge = null;
var global_menubar_collapse_bridge: ?*@import("bridge_menubar.zig").MenubarCollapseBridge = null;
var global_keychain_bridge: ?*@import("bridge_keychain.zig").KeychainBridge = null;
var global_screen_bridge: ?*@import("bridge_screen.zig").ScreenBridge = null;
var global_autolaunch_bridge: ?*@import("bridge_autolaunch.zig").AutoLaunchBridge = null;
var global_permissions_bridge: ?*@import("bridge_permissions.zig").PermissionsBridge = null;
var global_printing_bridge: ?*@import("bridge_printing.zig").PrintingBridge = null;
var global_speech_bridge: ?*@import("bridge_speech.zig").SpeechBridge = null;
var global_crash_reporter_bridge: ?*@import("bridge_crash_reporter.zig").CrashReporterBridge = null;
var global_iap_bridge: ?*@import("bridge_iap.zig").IAPBridge = null;
var global_handoff_bridge: ?*@import("bridge_handoff.zig").HandoffBridge = null;
var global_location_bridge: ?*@import("bridge_location.zig").LocationBridge = null;
var global_screen_capture_bridge: ?*@import("bridge_screen_capture.zig").ScreenCaptureBridge = null;
var global_local_server_bridge: ?*@import("bridge_local_server.zig").LocalServerBridge = null;
var global_biometric_bridge: ?*@import("bridge_biometric.zig").BiometricBridge = null;
var global_audio_bridge: ?*@import("bridge_audio.zig").AudioBridge = null;
var global_apple_script_bridge: ?*@import("bridge_apple_script.zig").AppleScriptBridge = null;
var global_file_associations_bridge: ?*@import("bridge_file_associations.zig").FileAssociationsBridge = null;
var global_tags_bridge: ?*@import("bridge_tags.zig").TagsBridge = null;
var global_pdf_bridge: ?*@import("bridge_pdf.zig").PDFBridge = null;
var global_log_bridge: ?*@import("bridge_log.zig").LogBridge = null;
var global_bonjour_bridge: ?*@import("bridge_bonjour.zig").BonjourBridge = null;
var global_spotlight_bridge: ?*@import("bridge_spotlight.zig").SpotlightBridge = null;
var global_speech_recognition_bridge: ?*@import("bridge_speech_recognition.zig").SpeechRecognitionBridge = null;
var global_vision_bridge: ?*@import("bridge_vision.zig").VisionBridge = null;
var global_midi_bridge: ?*@import("bridge_midi.zig").MIDIBridge = null;
var global_coreml_bridge: ?*@import("bridge_coreml.zig").CoreMLBridge = null;
var global_continuity_camera_bridge: ?*@import("bridge_continuity_camera.zig").ContinuityCameraBridge = null;
var global_service_menu_bridge: ?*@import("bridge_service_menu.zig").ServiceMenuBridge = null;
var global_serial_bridge: ?*@import("bridge_serial.zig").SerialBridge = null;
var global_focus_bridge: ?*@import("bridge_focus.zig").FocusBridge = null;
var global_screen_sharing_bridge: ?*@import("bridge_screen_sharing.zig").ScreenSharingBridge = null;

pub fn setGlobalTrayHandle(handle: *anyopaque) void {
    global_tray_handle_for_bridge = handle;

    // Update bridge if it exists
    if (global_tray_bridge) |bridge| {
        bridge.setTrayHandle(handle);
    }
}

pub fn getGlobalTrayHandle() ?*anyopaque {
    return global_tray_handle_for_bridge;
}

pub fn setupBridgeHandlers(allocator: std.mem.Allocator, tray_handle: ?*anyopaque, window_handle: ?*anyopaque) !void {
    const TrayBridge = @import("bridge_tray.zig").TrayBridge;
    const WindowBridge = @import("bridge_window.zig").WindowBridge;
    const AppBridge = @import("bridge_app.zig").AppBridge;

    // Initialize bridges
    if (global_tray_bridge == null) {
        global_tray_bridge = try allocator.create(TrayBridge);
        global_tray_bridge.?.* = TrayBridge.init(allocator);
    }

    if (global_window_bridge == null) {
        global_window_bridge = try allocator.create(WindowBridge);
        global_window_bridge.?.* = WindowBridge.init(allocator);
    }

    if (global_app_bridge == null) {
        global_app_bridge = try allocator.create(AppBridge);
        global_app_bridge.?.* = AppBridge.init(allocator);
    }

    if (global_native_ui_bridge == null) {
        global_native_ui_bridge = try allocator.create(@import("bridge_native_ui.zig").NativeUIBridge);
        global_native_ui_bridge.?.* = @import("bridge_native_ui.zig").NativeUIBridge.init(allocator);
    }

    if (global_notification_bridge == null) {
        const NotificationBridge = @import("bridge_notification.zig").NotificationBridge;
        global_notification_bridge = try allocator.create(NotificationBridge);
        global_notification_bridge.?.* = NotificationBridge.init(allocator);
    }

    if (global_shortcuts_bridge == null) {
        const ShortcutsBridge = @import("bridge_shortcuts.zig").ShortcutsBridge;
        global_shortcuts_bridge = try allocator.create(ShortcutsBridge);
        global_shortcuts_bridge.?.* = ShortcutsBridge.init(allocator);
    }

    if (global_menu_bridge == null) {
        const MenuBridge = @import("bridge_menu.zig").MenuBridge;
        global_menu_bridge = try allocator.create(MenuBridge);
        global_menu_bridge.?.* = MenuBridge.init(allocator);
    }

    if (global_updater_bridge == null) {
        const UpdaterBridge = @import("bridge_updater.zig").UpdaterBridge;
        global_updater_bridge = try allocator.create(UpdaterBridge);
        global_updater_bridge.?.* = UpdaterBridge.init(allocator);
    }

    if (global_touchbar_bridge == null) {
        const TouchBarBridge = @import("bridge_touchbar.zig").TouchBarBridge;
        global_touchbar_bridge = try allocator.create(TouchBarBridge);
        global_touchbar_bridge.?.* = TouchBarBridge.init(allocator);
    }

    if (global_fs_bridge == null) {
        const FSBridge = @import("bridge_fs.zig").FSBridge;
        global_fs_bridge = try allocator.create(FSBridge);
        global_fs_bridge.?.* = FSBridge.init(allocator);
    }

    if (global_shell_bridge == null) {
        const ShellBridge = @import("bridge_shell.zig").ShellBridge;
        global_shell_bridge = try allocator.create(ShellBridge);
        global_shell_bridge.?.* = ShellBridge.init(allocator);
    }

    if (global_dialog_bridge == null) {
        const DialogBridge = @import("bridge_dialog.zig").DialogBridge;
        global_dialog_bridge = try allocator.create(DialogBridge);
        global_dialog_bridge.?.* = DialogBridge.init(allocator);
    }

    if (global_clipboard_bridge == null) {
        const ClipboardBridge = @import("bridge_clipboard.zig").ClipboardBridge;
        global_clipboard_bridge = try allocator.create(ClipboardBridge);
        global_clipboard_bridge.?.* = ClipboardBridge.init(allocator);
    }

    if (global_menubar_collapse_bridge == null) {
        const MenubarCollapseBridge = @import("bridge_menubar.zig").MenubarCollapseBridge;
        global_menubar_collapse_bridge = try allocator.create(MenubarCollapseBridge);
        global_menubar_collapse_bridge.?.* = MenubarCollapseBridge.init(allocator);
    }

    if (global_power_bridge == null) {
        const PowerBridge = @import("bridge_power.zig").PowerBridge;
        global_power_bridge = try allocator.create(PowerBridge);
        global_power_bridge.?.* = PowerBridge.init(allocator);
    }

    if (global_network_bridge == null) {
        const NetworkBridge = @import("bridge_network.zig").NetworkBridge;
        global_network_bridge = try allocator.create(NetworkBridge);
        global_network_bridge.?.* = NetworkBridge.init(allocator);
    }

    if (global_system_bridge == null) {
        const SystemBridge = @import("bridge_system.zig").SystemBridge;
        global_system_bridge = try allocator.create(SystemBridge);
        global_system_bridge.?.* = SystemBridge.init(allocator);
    }

    if (global_bluetooth_bridge == null) {
        const BluetoothBridge = @import("bridge_bluetooth.zig").BluetoothBridge;
        global_bluetooth_bridge = try allocator.create(BluetoothBridge);
        global_bluetooth_bridge.?.* = BluetoothBridge.init(allocator);
    }

    if (global_keychain_bridge == null) {
        const KeychainBridge = @import("bridge_keychain.zig").KeychainBridge;
        global_keychain_bridge = try allocator.create(KeychainBridge);
        global_keychain_bridge.?.* = KeychainBridge.init(allocator);
    }

    if (global_screen_bridge == null) {
        const ScreenBridge = @import("bridge_screen.zig").ScreenBridge;
        global_screen_bridge = try allocator.create(ScreenBridge);
        global_screen_bridge.?.* = ScreenBridge.init(allocator);
    }

    if (global_autolaunch_bridge == null) {
        const AutoLaunchBridge = @import("bridge_autolaunch.zig").AutoLaunchBridge;
        global_autolaunch_bridge = try allocator.create(AutoLaunchBridge);
        global_autolaunch_bridge.?.* = AutoLaunchBridge.init(allocator);
    }

    if (global_permissions_bridge == null) {
        const PermissionsBridge = @import("bridge_permissions.zig").PermissionsBridge;
        global_permissions_bridge = try allocator.create(PermissionsBridge);
        global_permissions_bridge.?.* = PermissionsBridge.init(allocator);
    }

    if (global_printing_bridge == null) {
        const PrintingBridge = @import("bridge_printing.zig").PrintingBridge;
        global_printing_bridge = try allocator.create(PrintingBridge);
        global_printing_bridge.?.* = PrintingBridge.init(allocator);
    }

    if (global_speech_bridge == null) {
        const SpeechBridge = @import("bridge_speech.zig").SpeechBridge;
        global_speech_bridge = try allocator.create(SpeechBridge);
        global_speech_bridge.?.* = SpeechBridge.init(allocator);
    }

    if (global_crash_reporter_bridge == null) {
        const CrashReporterBridge = @import("bridge_crash_reporter.zig").CrashReporterBridge;
        global_crash_reporter_bridge = try allocator.create(CrashReporterBridge);
        global_crash_reporter_bridge.?.* = CrashReporterBridge.init(allocator);
    }

    if (global_iap_bridge == null) {
        const IAPBridge = @import("bridge_iap.zig").IAPBridge;
        global_iap_bridge = try allocator.create(IAPBridge);
        global_iap_bridge.?.* = IAPBridge.init(allocator);
    }

    if (global_handoff_bridge == null) {
        const HandoffBridge = @import("bridge_handoff.zig").HandoffBridge;
        global_handoff_bridge = try allocator.create(HandoffBridge);
        global_handoff_bridge.?.* = HandoffBridge.init(allocator);
    }

    if (global_location_bridge == null) {
        const LocationBridge = @import("bridge_location.zig").LocationBridge;
        global_location_bridge = try allocator.create(LocationBridge);
        global_location_bridge.?.* = LocationBridge.init(allocator);
    }

    if (global_screen_capture_bridge == null) {
        const ScreenCaptureBridge = @import("bridge_screen_capture.zig").ScreenCaptureBridge;
        global_screen_capture_bridge = try allocator.create(ScreenCaptureBridge);
        global_screen_capture_bridge.?.* = ScreenCaptureBridge.init(allocator);
    }

    if (global_local_server_bridge == null) {
        const LocalServerBridge = @import("bridge_local_server.zig").LocalServerBridge;
        global_local_server_bridge = try allocator.create(LocalServerBridge);
        global_local_server_bridge.?.* = LocalServerBridge.init(allocator);
    }

    if (global_biometric_bridge == null) {
        const BiometricBridge = @import("bridge_biometric.zig").BiometricBridge;
        global_biometric_bridge = try allocator.create(BiometricBridge);
        global_biometric_bridge.?.* = BiometricBridge.init(allocator);
    }

    if (global_audio_bridge == null) {
        const AudioBridge = @import("bridge_audio.zig").AudioBridge;
        global_audio_bridge = try allocator.create(AudioBridge);
        global_audio_bridge.?.* = AudioBridge.init(allocator);
    }

    if (global_apple_script_bridge == null) {
        const T = @import("bridge_apple_script.zig").AppleScriptBridge;
        global_apple_script_bridge = try allocator.create(T);
        global_apple_script_bridge.?.* = T.init(allocator);
    }
    if (global_file_associations_bridge == null) {
        const T = @import("bridge_file_associations.zig").FileAssociationsBridge;
        global_file_associations_bridge = try allocator.create(T);
        global_file_associations_bridge.?.* = T.init(allocator);
    }
    if (global_tags_bridge == null) {
        const T = @import("bridge_tags.zig").TagsBridge;
        global_tags_bridge = try allocator.create(T);
        global_tags_bridge.?.* = T.init(allocator);
    }
    if (global_pdf_bridge == null) {
        const T = @import("bridge_pdf.zig").PDFBridge;
        global_pdf_bridge = try allocator.create(T);
        global_pdf_bridge.?.* = T.init(allocator);
    }
    if (global_log_bridge == null) {
        const T = @import("bridge_log.zig").LogBridge;
        global_log_bridge = try allocator.create(T);
        global_log_bridge.?.* = T.init(allocator);
    }
    if (global_bonjour_bridge == null) {
        const T = @import("bridge_bonjour.zig").BonjourBridge;
        global_bonjour_bridge = try allocator.create(T);
        global_bonjour_bridge.?.* = T.init(allocator);
    }
    if (global_spotlight_bridge == null) {
        const T = @import("bridge_spotlight.zig").SpotlightBridge;
        global_spotlight_bridge = try allocator.create(T);
        global_spotlight_bridge.?.* = T.init(allocator);
    }
    if (global_speech_recognition_bridge == null) {
        const T = @import("bridge_speech_recognition.zig").SpeechRecognitionBridge;
        global_speech_recognition_bridge = try allocator.create(T);
        global_speech_recognition_bridge.?.* = T.init(allocator);
    }
    if (global_vision_bridge == null) {
        const T = @import("bridge_vision.zig").VisionBridge;
        global_vision_bridge = try allocator.create(T);
        global_vision_bridge.?.* = T.init(allocator);
    }
    if (global_midi_bridge == null) {
        const T = @import("bridge_midi.zig").MIDIBridge;
        global_midi_bridge = try allocator.create(T);
        global_midi_bridge.?.* = T.init(allocator);
    }
    if (global_coreml_bridge == null) {
        const T = @import("bridge_coreml.zig").CoreMLBridge;
        global_coreml_bridge = try allocator.create(T);
        global_coreml_bridge.?.* = T.init(allocator);
    }
    if (global_continuity_camera_bridge == null) {
        const T = @import("bridge_continuity_camera.zig").ContinuityCameraBridge;
        global_continuity_camera_bridge = try allocator.create(T);
        global_continuity_camera_bridge.?.* = T.init(allocator);
    }
    if (global_service_menu_bridge == null) {
        const T = @import("bridge_service_menu.zig").ServiceMenuBridge;
        global_service_menu_bridge = try allocator.create(T);
        global_service_menu_bridge.?.* = T.init(allocator);
    }
    if (global_serial_bridge == null) {
        const T = @import("bridge_serial.zig").SerialBridge;
        global_serial_bridge = try allocator.create(T);
        global_serial_bridge.?.* = T.init(allocator);
    }
    if (global_focus_bridge == null) {
        const T = @import("bridge_focus.zig").FocusBridge;
        global_focus_bridge = try allocator.create(T);
        global_focus_bridge.?.* = T.init(allocator);
    }
    if (global_screen_sharing_bridge == null) {
        const T = @import("bridge_screen_sharing.zig").ScreenSharingBridge;
        global_screen_sharing_bridge = try allocator.create(T);
        global_screen_sharing_bridge.?.* = T.init(allocator);
    }

    // theme + dragOut + deepLink: native modules with their own state, no
    // shared bridge struct — they install handlers directly via init().
    @import("macos_theme.zig").install();
    @import("macos_drag_out.zig").install();
    @import("macos_deep_link.zig").install();

    // Set handles - use parameter or global
    const tray_h = tray_handle orelse global_tray_handle_for_bridge;
    if (comptime builtin.mode == .debug) {
        std.debug.print("[Bridge] setupBridgeHandlers: tray_handle param={*}, global={*}, resolved={*}\n", .{ @as(?*anyopaque, tray_handle), global_tray_handle_for_bridge, tray_h });
    }
    if (tray_h) |handle| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Setting tray handle on bridge: {*}\n", .{handle});
        global_tray_bridge.?.setTrayHandle(handle);

        // Auto-initialize menubar collapse system for tray apps
        const menubar_collapse = @import("menubar_collapse.zig");
        if (!menubar_collapse.isInitialized()) {
            if (comptime builtin.mode == .debug)
                std.debug.print("[Bridge] Auto-initializing menubar collapse for tray app\n", .{});
            menubar_collapse.init();
        }
    } else {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] WARNING: No tray handle available!\n", .{});
    }

    if (window_handle) |handle| {
        global_window_bridge.?.setWindowHandle(handle);
        // Also set window reference for native UI bridge
        if (global_native_ui_bridge) |bridge| {
            const window_id: objc.id = @ptrCast(@alignCast(handle));
            bridge.setWindow(window_id);
        }

        // Install window-events delegate so JS receives focus/blur/move/
        // resize/close. Idempotent at the class level; per-window the
        // delegate gets attached on every call.
        const window_id: objc.id = @ptrCast(@alignCast(handle));
        @import("macos_window_events.zig").install(window_id);
    }
}

/// Try to evaluate JavaScript (may fail silently)
pub fn tryEvalJS(js_code: []const u8) !void {
    const tray_menu = @import("tray_menu.zig");
    if (tray_menu.getGlobalWebView()) |webview| {
        const webview_id: objc.id = @ptrFromInt(@intFromPtr(webview));
        const js_str = createNSString(js_code);
        _ = msgSend2(webview_id, "evaluateJavaScript:completionHandler:", js_str, null);
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Executed JS: {s}\n", .{js_code});
    } else {
        return error.NoWebView;
    }
}

/// Handle incoming messages from JavaScript bridge
/// Convert a JSON Value to string
fn jsonValueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    errdefer buf.deinit(allocator);

    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var num_buf: [32]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch return error.OutOfMemory;
            try buf.appendSlice(allocator, num_str);
        },
        .float => |f| {
            var num_buf: [64]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{f}) catch return error.OutOfMemory;
            try buf.appendSlice(allocator, num_str);
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .string => |s| {
            try buf.append(allocator, '"');
            for (s) |char| {
                switch (char) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => try buf.append(allocator, char),
                }
            }
            try buf.append(allocator, '"');
        },
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                const item_str = try jsonValueToString(allocator, item);
                defer allocator.free(item_str);
                try buf.appendSlice(allocator, item_str);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, entry.key_ptr.*);
                try buf.appendSlice(allocator, "\":");
                const val_str = try jsonValueToString(allocator, entry.value_ptr.*);
                defer allocator.free(val_str);
                try buf.appendSlice(allocator, val_str);
            }
            try buf.append(allocator, '}');
        },
    }

    return allocator.dupe(u8, buf.items);
}

/// Handle properly formatted JSON messages
pub fn handleBridgeMessageJSON(json_str: []const u8) !void {
    // Skip logging pollActions to reduce noise
    if (comptime builtin.mode == .debug) {
        if (std.mem.indexOf(u8, json_str, "pollActions") == null) {
            std.debug.print("[Bridge] Received JSON message: {s}\n", .{json_str});
        }
    }

    // Parse JSON to extract type, action, and data
    const allocator = std.heap.c_allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] JSON parse error: {any}\n", .{err});
        return err;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidBridgeMessage,
    };

    // Extract type and action (short keys: t, a, d)
    const msg_type_val = root.get("t") orelse {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Missing 't' field in JSON\n", .{});
        return error.MissingType;
    };
    const action_val = root.get("a") orelse {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Missing 'a' field in JSON\n", .{});
        return error.MissingAction;
    };

    const msg_type = switch (msg_type_val) {
        .string => |value| value,
        else => return error.InvalidBridgeMessage,
    };
    const action = switch (action_val) {
        .string => |value| value,
        else => return error.InvalidBridgeMessage,
    };

    // Extract data if present - could be string, object, array, or missing
    var data_json_str: []const u8 = "";
    var data_needs_free: bool = false;
    if (root.get("d")) |data_val| {
        switch (data_val) {
            // If data is already a string, use it directly (common case for JSON data)
            .string => |s| {
                data_json_str = s;
                data_needs_free = false;
            },
            // For other types, convert to JSON string
            else => {
                data_json_str = try jsonValueToString(allocator, data_val);
                data_needs_free = true;
            },
        }
    }
    defer if (data_needs_free and data_json_str.len > 0) allocator.free(data_json_str);

    // The window and app bridges take their payload as an optional, and `d` is
    // absent for the many actions that need none. An empty string would clear
    // the `orelse MissingData` guard and then fail JSON parsing instead, which
    // reports the wrong cause.
    const data_opt: ?[]const u8 = if (data_json_str.len > 0) data_json_str else null;

    // Route to appropriate bridge
    if (std.mem.eql(u8, msg_type, "tray")) {
        if (global_tray_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "window")) {
        if (global_window_bridge) |bridge| {
            // `handleMessage` discards the payload — it exists for the actions
            // that take none. Routing every window message through it meant
            // every action that *does* take one (setSize, setTitle,
            // setWebSidebarCollapsed, and 15 more) received null and answered
            // MISSING_DATA, no matter what the page sent.
            try bridge.handleMessageWithData(action, data_opt);
        }
    } else if (std.mem.eql(u8, msg_type, "app")) {
        if (global_app_bridge) |bridge| {
            // Same bug, same shape: notify and setBadge could never see their
            // arguments.
            try bridge.handleMessageWithData(action, data_opt);
        }
    } else if (std.mem.eql(u8, msg_type, "nativeUI")) {
        if (global_native_ui_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "notification")) {
        if (global_notification_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "shortcuts")) {
        if (global_shortcuts_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "menu")) {
        if (global_menu_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "updater")) {
        if (global_updater_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "touchbar")) {
        if (global_touchbar_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "fs")) {
        if (global_fs_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "shell")) {
        if (global_shell_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "dialog")) {
        if (global_dialog_bridge) |bridge| {
            try bridge.handleMessageWithData(action, data_opt);
        }
    } else if (std.mem.eql(u8, msg_type, "clipboard")) {
        if (global_clipboard_bridge) |bridge| {
            try bridge.handleMessageWithData(action, data_opt);
        }
    } else if (std.mem.eql(u8, msg_type, "menubarCollapse")) {
        if (global_menubar_collapse_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "power")) {
        if (global_power_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "network")) {
        if (global_network_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "dragOut")) {
        try @import("macos_drag_out.zig").handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "system")) {
        if (global_system_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "bluetooth")) {
        if (global_bluetooth_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "keychain")) {
        if (global_keychain_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "screen")) {
        if (global_screen_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "autoLaunch")) {
        if (global_autolaunch_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "permissions")) {
        if (global_permissions_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "printing")) {
        if (global_printing_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "speech")) {
        if (global_speech_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "crashReporter")) {
        if (global_crash_reporter_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "iap")) {
        if (global_iap_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "handoff")) {
        if (global_handoff_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "location")) {
        if (global_location_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "screenCapture")) {
        if (global_screen_capture_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "localServer")) {
        if (global_local_server_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "biometric")) {
        if (global_biometric_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "audio")) {
        if (global_audio_bridge) |bridge| {
            try bridge.handleMessage(action, data_json_str);
        }
    } else if (std.mem.eql(u8, msg_type, "appleScript")) {
        if (global_apple_script_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "fileAssociations")) {
        if (global_file_associations_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "tags")) {
        if (global_tags_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "pdf")) {
        if (global_pdf_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "log")) {
        if (global_log_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "bonjour")) {
        if (global_bonjour_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "spotlight")) {
        if (global_spotlight_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "speechRecognition")) {
        if (global_speech_recognition_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "vision")) {
        if (global_vision_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "midi")) {
        if (global_midi_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "coreml")) {
        if (global_coreml_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "continuityCamera")) {
        if (global_continuity_camera_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "serviceMenu")) {
        if (global_service_menu_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "serial")) {
        if (global_serial_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "focus")) {
        if (global_focus_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "screenSharing")) {
        if (global_screen_sharing_bridge) |bridge| try bridge.handleMessage(action, data_json_str);
    } else if (std.mem.eql(u8, msg_type, "debug")) {
        // Handle debug messages
        if (comptime builtin.mode == .debug) {
            if (root.get("message")) |msg_val| {
                if (msg_val == .string) std.debug.print("[JS Debug] {s}\n", .{msg_val.string});
            } else if (root.get("msg")) |msg_val| {
                if (msg_val == .string) std.debug.print("[JS Debug] {s}\n", .{msg_val.string});
            }
        }
    } else {
        if (comptime builtin.mode == .debug)
            std.debug.print("Unknown message type: {s}\n", .{msg_type});
    }
}

pub fn handleBridgeMessage(message_json: []const u8) !void {
    // Parse NSDictionary description format (fallback for old code paths)
    // Expected format: { action = "setTitle"; data = "text"; type = "tray"; }
    // Or JSON format: {"type":"tray","action":"setTitle","data":"text"}

    // Skip logging pollActions to reduce noise
    if (comptime builtin.mode == .debug) {
        if (std.mem.indexOf(u8, message_json, "pollActions") == null) {
            std.debug.print("[Bridge] Received message: {s}\n", .{message_json});
        }
    }

    var type_start: usize = 0;
    var type_end: usize = 0;
    var action_start: usize = 0;
    var action_end: usize = 0;
    var data_start: usize = 0;
    var data_end: usize = 0;

    // Parse NSDictionary format: key = value; or key = "value";
    // Find type (unquoted)
    if (std.mem.indexOf(u8, message_json, "type")) |pos| {
        // Skip past "type" and find =
        if (std.mem.indexOfPos(u8, message_json, pos + 4, "=")) |eq_pos| {
            // Skip whitespace after =
            var start = eq_pos + 1;
            while (start < message_json.len and (message_json[start] == ' ' or message_json[start] == '\t')) : (start += 1) {}

            // Check if quoted
            if (start < message_json.len and message_json[start] == '"') {
                type_start = start + 1;
                if (std.mem.indexOfPos(u8, message_json, type_start, "\"")) |end| {
                    type_end = end;
                }
            } else {
                // Unquoted - find next ; or space or newline
                type_start = start;
                if (std.mem.indexOfPos(u8, message_json, start, ";")) |end| {
                    type_end = end;
                }
            }
        }
    }

    // Find action (unquoted)
    if (std.mem.indexOf(u8, message_json, "action")) |pos| {
        if (std.mem.indexOfPos(u8, message_json, pos + 6, "=")) |eq_pos| {
            var start = eq_pos + 1;
            while (start < message_json.len and (message_json[start] == ' ' or message_json[start] == '\t')) : (start += 1) {}

            if (start < message_json.len and message_json[start] == '"') {
                action_start = start + 1;
                if (std.mem.indexOfPos(u8, message_json, action_start, "\"")) |end| {
                    action_end = end;
                }
            } else {
                action_start = start;
                if (std.mem.indexOfPos(u8, message_json, start, ";")) |end| {
                    action_end = end;
                }
            }
        }
    }

    // Find data (usually quoted, may contain escaped quotes)
    if (std.mem.indexOf(u8, message_json, "data")) |pos| {
        if (std.mem.indexOfPos(u8, message_json, pos + 4, "=")) |eq_pos| {
            var start = eq_pos + 1;
            while (start < message_json.len and (message_json[start] == ' ' or message_json[start] == '\t')) : (start += 1) {}

            if (start < message_json.len and message_json[start] == '"') {
                data_start = start + 1;
                // Find closing quote, but skip escaped quotes (\")
                var i = data_start;
                while (i < message_json.len) : (i += 1) {
                    if (message_json[i] == '\\' and i + 1 < message_json.len) {
                        // Skip escaped character
                        i += 1;
                        continue;
                    }
                    if (message_json[i] == '"') {
                        data_end = i;
                        break;
                    }
                }
            } else {
                data_start = start;
                if (std.mem.indexOfPos(u8, message_json, start, ";")) |end| {
                    data_end = end;
                }
            }
        }
    }

    if (type_end == 0 or action_end == 0) {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Invalid message format (missing type or action)\n", .{});
        return;
    }

    const msg_type = message_json[type_start..type_end];
    const action = message_json[action_start..action_end];
    const data = if (data_end > 0) message_json[data_start..data_end] else "";

    // Route to appropriate bridge
    if (std.mem.eql(u8, msg_type, "tray")) {
        if (global_tray_bridge) |bridge| {
            try bridge.handleMessage(action, data);
        }
    } else if (std.mem.eql(u8, msg_type, "window")) {
        if (global_window_bridge) |bridge| {
            try bridge.handleMessage(action);
        }
    } else if (std.mem.eql(u8, msg_type, "app")) {
        if (global_app_bridge) |bridge| {
            try bridge.handleMessage(action);
        }
    } else if (std.mem.eql(u8, msg_type, "nativeUI")) {
        if (global_native_ui_bridge) |bridge| {
            try bridge.handleMessage(action, data);
        }
    } else if (std.mem.eql(u8, msg_type, "notification")) {
        if (global_notification_bridge) |bridge| {
            try bridge.handleMessage(action, data);
        }
    } else if (std.mem.eql(u8, msg_type, "shortcuts")) {
        if (global_shortcuts_bridge) |bridge| {
            try bridge.handleMessage(action, data);
        }
    } else if (std.mem.eql(u8, msg_type, "menu")) {
        if (global_menu_bridge) |bridge| {
            try bridge.handleMessage(action, data);
        }
    } else if (std.mem.eql(u8, msg_type, "updater")) {
        if (global_updater_bridge) |bridge| {
            try bridge.handleMessage(action, data);
        }
    } else if (std.mem.eql(u8, msg_type, "touchbar")) {
        if (global_touchbar_bridge) |bridge| {
            try bridge.handleMessage(action, data);
        }
    } else if (std.mem.eql(u8, msg_type, "fs")) {
        if (global_fs_bridge) |bridge| {
            try bridge.handleMessage(action, data);
        }
    } else if (std.mem.eql(u8, msg_type, "shell")) {
        if (global_shell_bridge) |bridge| {
            try bridge.handleMessage(action, data);
        }
    } else if (std.mem.eql(u8, msg_type, "debug")) {
        // Handle debug messages - look for "message" or "msg" field
        if (std.mem.indexOf(u8, message_json, "message")) |msg_pos| {
            if (std.mem.indexOfPos(u8, message_json, msg_pos + 7, "=")) |eq_pos| {
                var start = eq_pos + 1;
                while (start < message_json.len and (message_json[start] == ' ' or message_json[start] == '\t')) : (start += 1) {}
                if (start < message_json.len and message_json[start] == '"') {
                    const msg_start = start + 1;
                    if (std.mem.indexOfPos(u8, message_json, msg_start, "\"")) |msg_end| {
                        const debug_msg = message_json[msg_start..msg_end];
                        if (comptime builtin.mode == .debug)
                            std.debug.print("[JS Debug] {s}\n", .{debug_msg});
                    }
                }
            }
        } else if (std.mem.indexOf(u8, message_json, "msg")) |msg_pos| {
            if (std.mem.indexOfPos(u8, message_json, msg_pos + 3, "=")) |eq_pos| {
                var start = eq_pos + 1;
                while (start < message_json.len and (message_json[start] == ' ' or message_json[start] == '\t')) : (start += 1) {}
                if (start < message_json.len and message_json[start] == '"') {
                    const msg_start = start + 1;
                    if (std.mem.indexOfPos(u8, message_json, msg_start, "\"")) |msg_end| {
                        const debug_msg = message_json[msg_start..msg_end];
                        if (comptime builtin.mode == .debug)
                            std.debug.print("[JS Debug] {s}\n", .{debug_msg});
                    }
                }
            }
        }
    } else {
        if (comptime builtin.mode == .debug)
            std.debug.print("Unknown message type: {s}\n", .{msg_type});
    }
}

/// Callback for WKScriptMessageHandler
export fn didReceiveScriptMessage(self: objc.id, _: objc.SEL, userContentController: objc.id, message: objc.id) void {
    _ = self;
    _ = userContentController;

    // Get the message body (should be a dictionary/object from JavaScript)
    const body = msgSend0(message, "body");

    // Try to convert to JSON properly using NSJSONSerialization
    const NSJSONSerialization = getClass("NSJSONSerialization");
    const options: c_ulong = 0; // NSJSONWritingPrettyPrinted = 1, 0 for compact

    // Create JSON data from dictionary
    const json_data = msgSend3(NSJSONSerialization, "dataWithJSONObject:options:error:", body, options, null);

    if (json_data == null) {
        // Fallback to description format if JSON serialization fails
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Failed to serialize to JSON, using description format\n", .{});
        const description = msgSend0(body, "description");
        const cstr = @as([*:0]const u8, @ptrCast(msgSend0(description, "UTF8String")));
        const desc_str = std.mem.span(cstr);
        handleBridgeMessage(desc_str) catch |err| {
            if (comptime builtin.mode == .debug)
                std.debug.print("[Bridge] Error handling message: {}\n", .{err});
        };
        return;
    }

    // Convert NSData to NSString
    const NSString = getClass("NSString");
    const json_string = msgSend2(NSString, "alloc", null, null);
    const NSUTF8StringEncoding: c_ulong = 4;
    const initialized_string = msgSend2(json_string, "initWithData:encoding:", json_data, NSUTF8StringEncoding);

    if (initialized_string == null) {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Failed to convert JSON data to string\n", .{});
        return;
    }

    // Get C string from NSString
    const cstr = @as([*:0]const u8, @ptrCast(msgSend0(initialized_string, "UTF8String")));
    const json_str = std.mem.span(cstr);

    // Now handle the properly formatted JSON
    handleBridgeMessageJSON(json_str) catch |err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Error handling JSON message: {}\n", .{err});
    };

    // Release the NSString
    msgSendVoid0(initialized_string, "release");
}

/// Create and register the script message handler with WKUserContentController
pub fn setupScriptMessageHandler(userContentController: objc.id) !void {
    if (comptime builtin.mode == .debug)
        std.debug.print("[Bridge] Setting up WKScriptMessageHandler...\n", .{});

    // Create a custom class at runtime that implements WKScriptMessageHandler
    const superclass = getClass("NSObject");
    const className = "CraftScriptMessageHandler";

    // Try to get existing class first (in case we're called multiple times)
    var handlerClass = objc.objc_getClass(className);

    if (handlerClass == null) {
        // Allocate a new class pair
        handlerClass = objc.objc_allocateClassPair(@ptrCast(superclass), className, 0);

        if (handlerClass == null) {
            if (comptime builtin.mode == .debug)
                std.debug.print("[Bridge] Failed to allocate class pair\n", .{});
            return error.ClassAllocationFailed;
        }

        // Add the method: userContentController:didReceiveScriptMessage:
        const method_sel = objc.sel_registerName("userContentController:didReceiveScriptMessage:");
        const method_imp: objc.IMP = @ptrCast(@constCast(&didReceiveScriptMessage));
        const method_types: [*c]const u8 = "v@:@@";
        const method_added = objc.class_addMethod(
            @ptrCast(@alignCast(handlerClass)),
            method_sel,
            method_imp,
            method_types,
        );

        if (comptime builtin.mode == .debug) {
            if (!method_added) {
                std.debug.print("[Bridge] Failed to add method\n", .{});
            }
        }

        // Register the class
        objc.objc_registerClassPair(@ptrCast(handlerClass));
        if (comptime builtin.mode == .debug)
            std.debug.print("[Bridge] Registered CraftScriptMessageHandler class\n", .{});
    }

    // Create an instance of our handler
    const handler_class_id: objc.id = @ptrCast(@alignCast(handlerClass));
    const handler = msgSend0(msgSend0(handler_class_id, "alloc"), "init");

    // Add the handler to the user content controller
    const handler_name = createNSString("craft");
    msgSendVoid2(userContentController, "addScriptMessageHandler:name:", handler, handler_name);

    if (comptime builtin.mode == .debug)
        std.debug.print("[Bridge] Script message handler registered successfully\n", .{});
}

// ============================================================================
// WKUIDelegate for Camera/Microphone Permissions
// ============================================================================

/// Media capture permission callback - automatically grants camera/microphone access
/// This is called by WebKit when a webpage requests getUserMedia()
fn handleMediaCapturePermission(
    self: objc.id,
    _sel: objc.SEL,
    webView: objc.id,
    origin: objc.id,
    frame: objc.id,
    mediaType: c_long,
    decisionHandler: objc.id,
) callconv(.c) void {
    _ = self;
    _ = _sel;
    _ = webView;
    _ = origin;
    _ = frame;

    // WKMediaCaptureType:
    // 0 = WKMediaCaptureTypeCamera
    // 1 = WKMediaCaptureTypeMicrophone
    // 2 = WKMediaCaptureTypeCameraAndMicrophone
    const media_type_str = switch (mediaType) {
        0 => "camera",
        1 => "microphone",
        2 => "camera+microphone",
        else => "unknown",
    };
    if (comptime builtin.mode == .debug)
        std.debug.print("[Media] Permission requested for: {s}\n", .{media_type_str});

    // Grant permission by calling decisionHandler with WKPermissionDecisionGrant (1)
    // WKPermissionDecision:
    // 0 = WKPermissionDecisionDeny
    // 1 = WKPermissionDecisionGrant
    // 2 = WKPermissionDecisionPrompt
    const invoke_sel = sel("invokeWithTarget:");

    // The decisionHandler is a block that takes WKPermissionDecision
    // We need to call it with 1 (grant) to allow media access
    // Create an NSInvocation to call the block properly
    const NSNumber = getClass("NSNumber");
    const grant_decision = msgSend1(NSNumber, "numberWithInt:", @as(c_int, 1)); // WKPermissionDecisionGrant

    // Blocks in Objective-C can be invoked directly with objc_msgSend
    // The block signature is void(^)(WKPermissionDecision)
    const block_invoke = @as(
        *const fn (objc.id, c_long) callconv(.c) void,
        @ptrCast(@alignCast(decisionHandler)),
    );
    _ = block_invoke;
    _ = invoke_sel;
    _ = grant_decision;

    // Alternative: Use the block directly
    // Blocks have a specific layout: isa, flags, reserved, invoke, descriptor
    // The invoke function is at offset 16 (after isa, flags, reserved)
    if (decisionHandler) |handler| {
        const BlockLayout = extern struct {
            isa: ?*anyopaque,
            flags: c_int,
            reserved: c_int,
            invoke: *const fn (*anyopaque, c_long) callconv(.c) void,
        };
        const block: *BlockLayout = @ptrCast(@alignCast(handler));
        // Call the block with WKPermissionDecisionGrant (1)
        block.invoke(handler, 1);
        if (comptime builtin.mode == .debug)
            std.debug.print("[Media] Permission granted for {s}\n", .{media_type_str});
    }
}

/// Set up WKUIDelegate to handle media capture permission requests
pub fn setupUIDelegate(webview: objc.id) !void {
    if (comptime builtin.mode == .debug)
        std.debug.print("[Media] Setting up WKUIDelegate for media permissions...\n", .{});

    // Create a custom class at runtime that implements WKUIDelegate
    const superclass = getClass("NSObject");
    const className = "CraftUIDelegate";

    // Try to get existing class first (in case we're called multiple times)
    var delegateClass = objc.objc_getClass(className);

    if (delegateClass == null) {
        // Allocate a new class pair
        delegateClass = objc.objc_allocateClassPair(@ptrCast(superclass), className, 0);

        if (delegateClass == null) {
            if (comptime builtin.mode == .debug)
                std.debug.print("[Media] Failed to allocate UI delegate class pair\n", .{});
            return error.ClassAllocationFailed;
        }

        // Add the method: webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:
        // This is the macOS 12+ API for handling getUserMedia() permission requests
        const method_sel = objc.sel_registerName("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:");
        const method_imp: objc.IMP = @ptrCast(@constCast(&handleMediaCapturePermission));
        // Method signature: void return, self, _cmd, webView, origin, frame, type (long), decisionHandler (block)
        // v = void, @ = object, : = selector, @ = object, @ = object, @ = object, q = long long, @? = block
        const method_types: [*c]const u8 = "v@:@@@q@?";
        const method_added = objc.class_addMethod(
            @ptrCast(@alignCast(delegateClass)),
            method_sel,
            method_imp,
            method_types,
        );

        if (comptime builtin.mode == .debug) {
            if (!method_added) {
                std.debug.print("[Media] Failed to add media permission method\n", .{});
            } else {
                std.debug.print("[Media] Added webView:requestMediaCapturePermissionForOrigin:... method\n", .{});
            }
        }

        // Register the class
        objc.objc_registerClassPair(@ptrCast(delegateClass));
        if (comptime builtin.mode == .debug)
            std.debug.print("[Media] Registered CraftUIDelegate class\n", .{});
    }

    // Create an instance of our delegate
    const delegate_class_id: objc.id = @ptrCast(@alignCast(delegateClass));
    const delegate = msgSend0(msgSend0(delegate_class_id, "alloc"), "init");

    // Set the UI delegate on the webview
    msgSendVoid1(webview, "setUIDelegate:", delegate);

    if (comptime builtin.mode == .debug)
        std.debug.print("[Media] UI delegate set successfully - camera/microphone permissions enabled\n", .{});
}

// ============================================================================
// WKNavigationDelegate — local development TLS
// ============================================================================
//
// A development proxy such as rpx fronts local services over HTTPS with a
// certificate from a local CA (tlsx). That CA is not a public root, so
// WKWebView rejects the certificate, fails the provisional navigation, and
// leaves a blank window on something like `https://dashboard.stacks.localhost`
// with no visible explanation.
//
// The exception below is opt-in and narrow: nothing happens at all unless
// `CRAFT_ALLOW_LOCAL_TLS` is set, and even then only loopback and the
// `localhost` TLD skip validation. See `local_tls.zig` for both rules and the
// reasoning behind the environment variable; this file only wires them to
// AppKit.

/// Read once. A trust exception that could switch itself on part-way through a
/// process's life would be harder to reason about, not easier.
var local_tls_allowed: ?bool = null;

fn allowsLocalDevTLS() bool {
    if (local_tls_allowed) |cached| return cached;
    const raw = std.c.getenv(local_tls.env_var);
    const value: ?[]const u8 = if (raw) |v| std.mem.span(v) else null;
    const allowed = local_tls.allowedByEnv(value);
    local_tls_allowed = allowed;
    return allowed;
}

/// Enough of the Objective-C block ABI to reach `invoke`. The layout is fixed:
/// isa, flags, reserved, invoke, descriptor. Mirrors the block call in
/// `handleMediaCapturePermission`, which takes one argument where this takes
/// two.
const AuthChallengeBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*anyopaque, c_long, objc.id) callconv(.c) void,
};

/// `NSURLSessionAuthChallengeDisposition`.
const AuthDisposition = enum(c_long) {
    use_credential = 0,
    perform_default_handling = 1,
};

/// Answer the challenge. This must happen exactly once on every path out of
/// the delegate method: dropping the handler does not fail the load, it hangs
/// it, and WKWebView will sit on a blank window forever waiting for a reply.
fn finishAuthChallenge(handler: objc.id, disposition: AuthDisposition, credential: objc.id) void {
    const h = handler orelse return;
    const block: *AuthChallengeBlock = @ptrCast(@alignCast(h));
    block.invoke(h, @backingInt(disposition), credential);
}

fn hostIsLocalDev(host: objc.id) bool {
    const raw = msgSend0(host, "UTF8String") orelse return false;
    const cstr: [*:0]const u8 = @ptrCast(@alignCast(raw));
    return local_tls.isLocalHostName(std.mem.span(cstr));
}

/// `webView:didReceiveAuthenticationChallenge:completionHandler:`
///
/// Accepts the presented server trust for a local host, and takes default
/// handling for everything else — every host on the internet, and every
/// challenge that is not a TLS server trust (HTTP basic auth, client
/// certificates). Default handling is ordinary validation, so falling through
/// is always the safe answer.
fn handleAuthChallenge(
    _: objc.id,
    _: objc.SEL,
    _: objc.id,
    challenge: objc.id,
    completionHandler: objc.id,
) callconv(.c) void {
    const protectionSpace = msgSend0(challenge, "protectionSpace");
    if (protectionSpace == null)
        return finishAuthChallenge(completionHandler, .perform_default_handling, null);

    // Non-null only for server-trust challenges.
    const serverTrust = msgSend0(protectionSpace, "serverTrust");
    if (serverTrust == null)
        return finishAuthChallenge(completionHandler, .perform_default_handling, null);

    if (!hostIsLocalDev(msgSend0(protectionSpace, "host")))
        return finishAuthChallenge(completionHandler, .perform_default_handling, null);

    if (comptime builtin.mode == .debug)
        std.debug.print("[Nav] Trusting local development certificate\n", .{});

    const NSURLCredential = getClass("NSURLCredential");
    const credential = msgSend1(NSURLCredential, "credentialForTrust:", serverTrust);
    finishAuthChallenge(completionHandler, .use_credential, credential);
}

/// Attach a `WKNavigationDelegate` that trusts local development certificates.
///
/// A no-op unless the process opted in: without `CRAFT_ALLOW_LOCAL_TLS` craft
/// installs no navigation delegate at all, which is exactly the behaviour it
/// has always had. Implementing only the auth-challenge method leaves every
/// other navigation decision — policy, redirects, provisional failures — at its
/// AppKit default.
///
/// Call before loading, so the delegate is in place for the first request's
/// challenge.
pub fn setupNavigationDelegate(webview: objc.id) !void {
    if (!allowsLocalDevTLS()) return;

    const superclass = getClass("NSObject");
    const className = "CraftNavigationDelegate";

    // May already exist: one delegate class serves every window.
    var delegateClass = objc.objc_getClass(className);
    if (delegateClass == null) {
        delegateClass = objc.objc_allocateClassPair(@ptrCast(superclass), className, 0);
        if (delegateClass == null)
            return error.ClassAllocationFailed;

        const method_sel = objc.sel_registerName("webView:didReceiveAuthenticationChallenge:completionHandler:");
        const method_imp: objc.IMP = @ptrCast(@constCast(&handleAuthChallenge));
        // void; self, _cmd, webView, challenge, completionHandler (block)
        const method_types: [*c]const u8 = "v@:@@@?";
        if (!objc.class_addMethod(@ptrCast(@alignCast(delegateClass)), method_sel, method_imp, method_types))
            return error.MethodAdditionFailed;

        objc.objc_registerClassPair(@ptrCast(delegateClass));
    }

    // `navigationDelegate` is a weak reference, so the +1 from `alloc`/`init`
    // is what keeps this alive — one small object per window, deliberately
    // never released. Balancing it would leave the webview pointing at freed
    // memory the moment a challenge arrived.
    const delegate_class_id: objc.id = @ptrCast(@alignCast(delegateClass));
    const delegate = msgSend0(msgSend0(delegate_class_id, "alloc"), "init");
    msgSendVoid1(webview, "setNavigationDelegate:", delegate);

    if (comptime builtin.mode == .debug)
        std.debug.print("[Nav] Local development TLS enabled via {s}\n", .{local_tls.env_var});
}

// ============================================================================
// v0.5.0 Features
// ============================================================================

// WebSocket support for real-time communication
pub const WebSocket = struct {
    url: []const u8,
    connected: bool = false,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, url: []const u8) !WebSocket {
        return .{
            .url = try allocator.dupe(u8, url),
            .connected = false,
            .allocator = allocator,
        };
    }

    pub fn send(self: *WebSocket, message: []const u8) !void {
        _ = self;
        _ = message;
        // Would integrate with NSURLSession WebSocket task
    }

    pub fn receive(self: *WebSocket) ![]const u8 {
        _ = self;
        // Would receive from NSURLSession WebSocket task
        return "";
    }

    pub fn close(self: *WebSocket) void {
        if (self.connected) {
            self.connected = false;
        }
    }

    pub fn deinit(self: *WebSocket) void {
        self.allocator.free(self.url);
    }
};

// Custom protocol handler (craft://)
pub const ProtocolHandler = struct {
    scheme: []const u8,
    callback: *const fn ([]const u8) void,

    pub fn register(scheme: []const u8, callback: *const fn ([]const u8) void) !ProtocolHandler {
        // Would register with WKURLSchemeHandler
        return .{
            .scheme = scheme,
            .callback = callback,
        };
    }

    pub fn handle(self: ProtocolHandler, url: []const u8) void {
        self.callback(url);
    }
};

pub fn registerCustomProtocol(webview: objc.id, scheme: []const u8) !void {
    _ = webview;
    _ = scheme;
    // Would use WKWebViewConfiguration.setURLSchemeHandler
}

// Drag and drop file support
pub const DragDropEvent = struct {
    files: [][]const u8,
    x: f64,
    y: f64,
};

pub const DragDropCallback = *const fn (DragDropEvent) void;

pub fn enableDragDrop(window: objc.id, callback: DragDropCallback) void {
    _ = window;
    _ = callback;
    // Would register for NSDragOperation and implement NSDraggingDestination protocol
}

pub fn getDraggedFiles(drag_info: objc.id, allocator: std.mem.Allocator) ![][]const u8 {
    _ = drag_info;
    _ = allocator;
    // Would extract files from NSPasteboard
    return &[_][]const u8{};
}

// Context menu API
pub const MenuItem = struct {
    title: []const u8,
    action: *const fn () void,
    enabled: bool = true,
    separator: bool = false,
};

pub const ContextMenu = struct {
    items: []MenuItem,
    native_menu: objc.id,

    pub fn create(allocator: std.mem.Allocator, items: []const MenuItem) !ContextMenu {
        const NSMenu = getClass("NSMenu");
        const menu = msgSend0(msgSend0(NSMenu, "alloc"), "init");

        const items_copy = try allocator.alloc(MenuItem, items.len);
        @memcpy(items_copy, items);

        return .{
            .items = items_copy,
            .native_menu = menu,
        };
    }

    pub fn show(self: ContextMenu, window: objc.id, x: f64, y: f64) void {
        const point = NSPoint{ .x = x, .y = y };
        _ = msgSend2(self.native_menu, "popUpMenuPositioningItem:atLocation:inView:", @as(?*anyopaque, null), point, window);
    }

    pub fn deinit(self: ContextMenu, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

// Auto-updater
pub const UpdateInfo = struct {
    version: []const u8,
    download_url: []const u8,
    release_notes: []const u8,
    required: bool = false,
};

pub const Updater = struct {
    current_version: []const u8,
    update_url: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, version: []const u8, update_url: []const u8) !Updater {
        return .{
            .current_version = try allocator.dupe(u8, version),
            .update_url = try allocator.dupe(u8, update_url),
            .allocator = allocator,
        };
    }

    pub fn checkForUpdates(self: *Updater) !?UpdateInfo {
        _ = self;
        // Would fetch update manifest from update_url
        return null;
    }

    pub fn downloadUpdate(self: *Updater, info: UpdateInfo) !void {
        _ = self;
        _ = info;
        // Would download update package
    }

    pub fn installUpdate(self: *Updater) !void {
        _ = self;
        // Would install downloaded update and restart app
    }

    pub fn deinit(self: *Updater) void {
        self.allocator.free(self.current_version);
        self.allocator.free(self.update_url);
    }
};

// Crash reporting
pub const CrashReport = struct {
    timestamp: i64,
    exception: []const u8,
    stack_trace: []const u8,
    app_version: []const u8,
};

pub const CrashReporter = struct {
    endpoint: []const u8,
    app_version: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8, app_version: []const u8) !CrashReporter {
        return .{
            .endpoint = try allocator.dupe(u8, endpoint),
            .app_version = try allocator.dupe(u8, app_version),
            .allocator = allocator,
        };
    }

    pub fn reportCrash(self: *CrashReporter, report: CrashReport) !void {
        _ = self;
        _ = report;
        // Would send crash report to endpoint
    }

    pub fn enableAutomaticReporting(self: *CrashReporter) void {
        _ = self;
        // Would set up NSException handler
    }

    pub fn deinit(self: *CrashReporter) void {
        self.allocator.free(self.endpoint);
        self.allocator.free(self.app_version);
    }
};

// Enhanced keyboard shortcut API
pub const KeyModifier = packed struct {
    command: bool = false,
    shift: bool = false,
    option: bool = false,
    control: bool = false,
};

pub const KeyCode = enum(u16) {
    a = 0,
    s = 1,
    d = 2,
    f = 3,
    h = 4,
    g = 5,
    z = 6,
    x = 7,
    c = 8,
    v = 9,
    b = 11,
    q = 12,
    w = 13,
    e = 14,
    r = 15,
    y = 16,
    t = 17,
    n = 45,
    m = 46,
    space = 49,
    return_key = 36,
    escape = 53,
    delete = 51,
    tab = 48,
    f1 = 122,
    f2 = 120,
    f3 = 99,
    f4 = 118,
    f5 = 96,
    f6 = 97,
    f7 = 98,
    f8 = 100,
    f9 = 101,
    f10 = 109,
    f11 = 103,
    f12 = 111,
    _,
};

pub const Shortcut = struct {
    key: KeyCode,
    modifiers: KeyModifier,
    action: *const fn () void,
    global: bool = false,
};

pub fn registerShortcut(shortcut: Shortcut) !void {
    _ = shortcut;
    // Would use NSEvent.addLocalMonitorForEventsMatchingMask or
    // Carbon/Cocoa global hotkey registration
}

pub fn unregisterShortcut(shortcut: Shortcut) void {
    _ = shortcut;
    // Would remove event monitor or unregister hotkey
}

// Window snapshots/thumbnails
pub const WindowSnapshot = struct {
    data: []u8,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WindowSnapshot) void {
        self.allocator.free(self.data);
    }
};

pub fn captureWindowSnapshot(window: objc.id, allocator: std.mem.Allocator, scale: f64) !WindowSnapshot {
    _ = window;
    _ = scale;
    // Would use CGWindowListCreateImage to capture window
    const data = try allocator.alloc(u8, 0);
    return .{
        .data = data,
        .width = 0,
        .height = 0,
        .allocator = allocator,
    };
}

pub fn captureWindowThumbnail(window: objc.id, allocator: std.mem.Allocator, max_width: u32, max_height: u32) !WindowSnapshot {
    _ = window;
    _ = max_width;
    _ = max_height;
    // Would capture and scale down
    const data = try allocator.alloc(u8, 0);
    return .{
        .data = data,
        .width = 0,
        .height = 0,
        .allocator = allocator,
    };
}

pub fn saveSnapshot(snapshot: WindowSnapshot, file_path: []const u8) !void {
    _ = snapshot;
    _ = file_path;
    // Would save to PNG/JPEG file
}

// Screen recording
pub const RecordingOptions = struct {
    fps: u32 = 30,
    audio: bool = false,
    cursor: bool = true,
};

pub const ScreenRecorder = struct {
    recording: bool = false,
    output_path: []const u8,
    options: RecordingOptions,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, output_path: []const u8, options: RecordingOptions) !ScreenRecorder {
        return .{
            .recording = false,
            .output_path = try allocator.dupe(u8, output_path),
            .options = options,
            .allocator = allocator,
        };
    }

    pub fn startRecording(self: *ScreenRecorder) !void {
        if (self.recording) return error.AlreadyRecording;
        self.recording = true;
        // Would use AVFoundation to start screen recording
    }

    pub fn stopRecording(self: *ScreenRecorder) !void {
        if (!self.recording) return error.NotRecording;
        self.recording = false;
        // Would stop AVFoundation recording and save file
    }

    pub fn pauseRecording(self: *ScreenRecorder) !void {
        if (!self.recording) return error.NotRecording;
        // Would pause recording
    }

    pub fn resumeRecording(self: *ScreenRecorder) !void {
        if (!self.recording) return error.NotRecording;
        // Would resume recording
    }

    pub fn deinit(self: *ScreenRecorder) void {
        if (self.recording) {
            _ = self.stopRecording() catch |err| {
                std.log.debug("screen recording stop during cleanup failed: {}", .{err});
            };
        }
        self.allocator.free(self.output_path);
    }
};

pub fn recordWindow(window: objc.id, output_path: []const u8, options: RecordingOptions) !ScreenRecorder {
    _ = window;
    const allocator = std.heap.c_allocator;
    return ScreenRecorder.init(allocator, output_path, options);
}

pub fn recordScreen(output_path: []const u8, options: RecordingOptions) !ScreenRecorder {
    const allocator = std.heap.c_allocator;
    return ScreenRecorder.init(allocator, output_path, options);
}

// ============================================================================
// v0.6.0 Features - Cross-Platform & Enterprise
// ============================================================================

// Plugin system
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    path: []const u8,
    enabled: bool = true,
    handle: ?*anyopaque = null,
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Plugin {
        // Would use dlopen() to load dynamic library
        return .{
            .name = try allocator.dupe(u8, "plugin"),
            .version = try allocator.dupe(u8, "1.0.0"),
            .path = try allocator.dupe(u8, path),
            .enabled = true,
            .handle = null,
            .allocator = allocator,
        };
    }

    pub fn call(self: *Plugin, function_name: []const u8, args: []const u8) ![]const u8 {
        _ = self;
        _ = function_name;
        _ = args;
        // Would use dlsym() to get function and call it
        return "";
    }

    pub fn unload(self: *Plugin) void {
        if (self.handle) |_| {
            // Would use dlclose()
        }
        self.enabled = false;
    }

    pub fn deinit(self: *Plugin) void {
        self.unload();
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.allocator.free(self.path);
    }
};

pub const PluginManager = struct {
    plugins: std.ArrayList(Plugin),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return .{
            .plugins = std.ArrayList(Plugin).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn loadPlugin(self: *PluginManager, path: []const u8) !void {
        const plugin = try Plugin.load(self.allocator, path);
        try self.plugins.append(plugin);
    }

    pub fn getPlugin(self: *PluginManager, name: []const u8) ?*Plugin {
        for (self.plugins.items) |*plugin| {
            if (std.mem.eql(u8, plugin.name, name)) {
                return plugin;
            }
        }
        return null;
    }

    pub fn deinit(self: *PluginManager) void {
        for (self.plugins.items) |*plugin| {
            plugin.deinit();
        }
        self.plugins.deinit();
    }
};

// Native modules
pub const NativeModule = struct {
    name: []const u8,
    exports: std.StringHashMap(*const fn () void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !NativeModule {
        return .{
            .name = try allocator.dupe(u8, name),
            .exports = std.StringHashMap(*const fn () void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn registerFunction(self: *NativeModule, name: []const u8, func: *const fn () void) !void {
        try self.exports.put(name, func);
    }

    pub fn call(self: *NativeModule, name: []const u8) !void {
        if (self.exports.get(name)) |func| {
            func();
        } else {
            return error.FunctionNotFound;
        }
    }

    pub fn deinit(self: *NativeModule) void {
        self.allocator.free(self.name);
        self.exports.deinit();
    }
};

// Sandbox environment
pub const SandboxPermissions = struct {
    network: bool = false,
    file_system_read: bool = false,
    file_system_write: bool = false,
    clipboard: bool = false,
    notifications: bool = false,
    camera: bool = false,
    microphone: bool = false,
};

pub const Sandbox = struct {
    permissions: SandboxPermissions,
    enabled: bool = true,

    pub fn create(permissions: SandboxPermissions) Sandbox {
        return .{
            .permissions = permissions,
            .enabled = true,
        };
    }

    pub fn checkPermission(self: Sandbox, permission: []const u8) bool {
        if (!self.enabled) return true;

        if (std.mem.eql(u8, permission, "network")) return self.permissions.network;
        if (std.mem.eql(u8, permission, "file_read")) return self.permissions.file_system_read;
        if (std.mem.eql(u8, permission, "file_write")) return self.permissions.file_system_write;
        if (std.mem.eql(u8, permission, "clipboard")) return self.permissions.clipboard;
        if (std.mem.eql(u8, permission, "notifications")) return self.permissions.notifications;
        if (std.mem.eql(u8, permission, "camera")) return self.permissions.camera;
        if (std.mem.eql(u8, permission, "microphone")) return self.permissions.microphone;

        return false;
    }

    pub fn requestPermission(self: *Sandbox, permission: []const u8) !void {
        _ = self;
        _ = permission;
        // Would show native permission dialog
    }
};

// IPC (Inter-Process Communication) improvements
pub const IpcMessage = struct {
    channel: []const u8,
    data: []const u8,
    reply_channel: ?[]const u8 = null,
};

pub const IpcHandler = *const fn (IpcMessage) void;

pub const Ipc = struct {
    handlers: std.StringHashMap(IpcHandler),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Ipc {
        return .{
            .handlers = std.StringHashMap(IpcHandler).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn on(self: *Ipc, channel: []const u8, handler: IpcHandler) !void {
        try self.handlers.put(channel, handler);
    }

    pub fn send(self: *Ipc, channel: []const u8, data: []const u8) !void {
        if (self.handlers.get(channel)) |handler| {
            const msg = IpcMessage{
                .channel = channel,
                .data = data,
            };
            handler(msg);
        }
    }

    pub fn invoke(self: *Ipc, channel: []const u8, data: []const u8) ![]const u8 {
        _ = self;
        _ = channel;
        _ = data;
        // Would send and wait for reply
        return "";
    }

    pub fn deinit(self: *Ipc) void {
        self.handlers.deinit();
    }
};

// Accessibility support
pub const AccessibilityRole = enum {
    button,
    link,
    heading,
    text,
    image,
    list,
    list_item,
    table,
    menu,
    dialog,
};

pub const AccessibilityElement = struct {
    role: AccessibilityRole,
    label: []const u8,
    value: []const u8,
    enabled: bool = true,
};

pub fn setAccessibilityLabel(element: objc.id, label: []const u8) !void {
    _ = element;
    _ = label;
    // Would use NSAccessibility protocol
}

pub fn enableVoiceOver(window: objc.id) void {
    _ = window;
    // Would enable VoiceOver support
}

pub fn setAccessibilityRole(element: objc.id, role: AccessibilityRole) !void {
    _ = element;
    _ = role;
    // Would use setAccessibilityRole:
}

// Internationalization (i18n)
pub const Locale = struct {
    language: []const u8,
    region: []const u8,
    direction: enum { ltr, rtl } = .ltr,
};

pub const I18n = struct {
    current_locale: Locale,
    translations: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, locale: Locale) I18n {
        return .{
            .current_locale = locale,
            .translations = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn translate(self: *I18n, key: []const u8) []const u8 {
        return self.translations.get(key) orelse key;
    }

    pub fn loadTranslations(self: *I18n, file_path: []const u8) !void {
        _ = self;
        _ = file_path;
        // Would load JSON/TOML translation file
    }

    pub fn setLocale(self: *I18n, locale: Locale) void {
        self.current_locale = locale;
    }

    pub fn deinit(self: *I18n) void {
        self.translations.deinit();
    }
};

pub fn getSystemLocale() Locale {
    // Would use NSLocale
    return .{
        .language = "en",
        .region = "US",
        .direction = .ltr,
    };
}

// Code signing
pub const CodeSignature = struct {
    certificate_path: []const u8,
    identity: []const u8,
    entitlements_path: ?[]const u8 = null,
};

pub fn signApplication(app_path: []const u8, signature: CodeSignature) !void {
    _ = app_path;
    _ = signature;
    // Would use codesign tool on macOS
    // codesign --sign "Developer ID" --entitlements entitlements.plist app.app
}

pub fn verifySignature(app_path: []const u8) !bool {
    _ = app_path;
    // Would use codesign --verify
    return false;
}

pub fn notarizeApplication(app_path: []const u8, apple_id: []const u8, password: []const u8) !void {
    _ = app_path;
    _ = apple_id;
    _ = password;
    // Would use xcrun notarytool
}

// Installer generation
pub const InstallerOptions = struct {
    app_name: []const u8,
    app_version: []const u8,
    app_icon: ?[]const u8 = null,
    license_file: ?[]const u8 = null,
    background_image: ?[]const u8 = null,
    install_location: []const u8 = "/Applications",
};

pub const Installer = struct {
    options: InstallerOptions,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: InstallerOptions) Installer {
        return .{
            .options = options,
            .allocator = allocator,
        };
    }

    pub fn generateDmg(self: *Installer, app_path: []const u8, output_path: []const u8) !void {
        _ = self;
        _ = app_path;
        _ = output_path;
        // Would use hdiutil to create DMG on macOS
    }

    pub fn generatePkg(self: *Installer, app_path: []const u8, output_path: []const u8) !void {
        _ = self;
        _ = app_path;
        _ = output_path;
        // Would use pkgbuild/productbuild on macOS
    }

    pub fn generateMsi(self: *Installer, app_path: []const u8, output_path: []const u8) !void {
        _ = self;
        _ = app_path;
        _ = output_path;
        // Would use WiX Toolset on Windows
    }

    pub fn generateDeb(self: *Installer, app_path: []const u8, output_path: []const u8) !void {
        _ = self;
        _ = app_path;
        _ = output_path;
        // Would use dpkg-deb on Linux
    }

    pub fn generateRpm(self: *Installer, app_path: []const u8, output_path: []const u8) !void {
        _ = self;
        _ = app_path;
        _ = output_path;
        // Would use rpmbuild on Linux
    }

    pub fn generateAppImage(self: *Installer, app_path: []const u8, output_path: []const u8) !void {
        _ = self;
        _ = app_path;
        _ = output_path;
        // Would use appimagetool on Linux
    }
};

/// Initialize the NSApplication for regular apps (with Dock icon)
pub fn initApp() void {
    const NSApplication = getClass("NSApplication");
    const app = msgSend0(NSApplication, "sharedApplication");

    const NSApplicationActivationPolicyRegular: c_long = 0;
    _ = msgSend1(app, "setActivationPolicy:", NSApplicationActivationPolicyRegular);
}

/// Initialize without finishing launch - for apps that will set policy later
pub fn initAppWithoutLaunching() void {
    const NSApplication = getClass("NSApplication");
    const app = msgSend0(NSApplication, "sharedApplication");
    _ = app; // Just ensure app exists
}

/// Set the dock icon for the running NSApplication. `path` may point to any
/// image format Cocoa can decode (PNG/JPG/ICNS). A non-existent or
/// undecodable file is logged and ignored — we never want a broken icon
/// argument to bring the app down.
pub fn setApplicationIcon(path: []const u8) void {
    const NSApplication = getClass("NSApplication");
    const NSImage = getClass("NSImage");

    const path_str = createNSString(path);
    const image = msgSend1(msgSend0(NSImage, "alloc"), "initWithContentsOfFile:", path_str);
    if (image == null) {
        std.log.warn("setApplicationIcon: could not load image at '{s}'", .{path});
        return;
    }

    const app = msgSend0(NSApplication, "sharedApplication");
    msgSendVoid1(app, "setApplicationIconImage:", image);
}

// NSEventModifierFlags. A key equivalent implies Command already, so these
// name only what gets added on top of it.
const modifier_shift: c_ulong = 1 << 17;
const modifier_control: c_ulong = 1 << 18;
const modifier_option: c_ulong = 1 << 19;
const modifier_command: c_ulong = 1 << 20;

/// The AppKit selector for a role, resolved where the menu is declared.
///
/// A role `menu_roles.zig` does not define produces an item with a nil action,
/// which AppKit renders permanently greyed out — a failure you find by
/// launching the app and looking at it. The tables below are comptime-known, so
/// a typo is a build error instead.
fn menuRole(comptime name: []const u8) [*:0]const u8 {
    return comptime menu_roles.selectorFor(name) orelse
        @compileError("menu role \"" ++ name ++ "\" has no AppKit selector in menu_roles.zig");
}

/// One entry in the default menu bar.
///
/// Declaring the bar as data rather than as ~40 lines of msgSend per menu is
/// what keeps it readable at this size — and it keeps the default bar and an
/// app-declared one resolving roles through the same table.
const DefaultItem = struct {
    title: []const u8 = "",
    /// What the item performs. Null is a separator.
    selector: ?[*:0]const u8 = null,
    /// Key equivalent, lowercase. Empty means no shortcut.
    key: []const u8 = "",
    /// Modifiers beyond the Command a key equivalent already implies.
    extra_modifiers: c_ulong = 0,
    /// Append the app name to the title, as the App menu does: "Quit Craft".
    with_app_name: bool = false,
};

const DefaultMenu = struct {
    /// Fallback title, used when `use_app_name` is set but the name could not
    /// be read.
    title: []const u8,
    items: []const DefaultItem,
    /// Title this menu with the app's name. AppKit is documented to show the
    /// application name over the first menu whatever we title it, but setting
    /// it explicitly costs nothing and does not depend on that.
    use_app_name: bool = false,
    /// Hand this menu to `-[NSApplication setWindowsMenu:]`, which makes AppKit
    /// maintain the list of open windows underneath it.
    is_windows_menu: bool = false,
};

/// The App menu. AppKit renders the first menu in the bar under the app's own
/// name in bold, and everything here is what a Mac user expects to find there.
const app_menu_items = [_]DefaultItem{
    .{ .title = "About", .selector = menuRole("about"), .with_app_name = true },
    .{},
    .{ .title = "Hide", .selector = menuRole("hide"), .key = "h", .with_app_name = true },
    .{ .title = "Hide Others", .selector = menuRole("hideOthers"), .key = "h", .extra_modifiers = modifier_option },
    .{ .title = "Show All", .selector = menuRole("showAll") },
    .{},
    .{ .title = "Quit", .selector = menuRole("quit"), .key = "q", .with_app_name = true },
};

/// The Edit menu, and the reason this function grew.
///
/// On macOS a menu item's key equivalent is how Cmd+X/C/V/A reach the responder
/// chain at all. Without these items an app that never calls `craft.menu.set()`
/// has no menu-driven clipboard: text fields get only whatever the WKWebView
/// intercepts for itself, and Cmd+C over a native control does nothing.
const edit_menu_items = [_]DefaultItem{
    .{ .title = "Undo", .selector = menuRole("undo"), .key = "z" },
    .{ .title = "Redo", .selector = menuRole("redo"), .key = "z", .extra_modifiers = modifier_shift },
    .{},
    .{ .title = "Cut", .selector = menuRole("cut"), .key = "x" },
    .{ .title = "Copy", .selector = menuRole("copy"), .key = "c" },
    .{ .title = "Paste", .selector = menuRole("paste"), .key = "v" },
    .{ .title = "Delete", .selector = menuRole("delete") },
    .{ .title = "Select All", .selector = menuRole("selectAll"), .key = "a" },
};

/// Reload and Force Reload land on the focused WKWebView, which implements
/// `reload:` and `reloadFromOrigin:` as action selectors. Dev consoles stay
/// reachable by right-click when `dev_tools` is enabled (the webview sets
/// `setInspectable:YES`).
const view_menu_items = [_]DefaultItem{
    .{ .title = "Reload", .selector = menuRole("reload"), .key = "r" },
    .{ .title = "Force Reload", .selector = menuRole("forceReload"), .key = "r", .extra_modifiers = modifier_shift },
    .{},
    .{ .title = "Enter Full Screen", .selector = menuRole("fullscreen"), .key = "f", .extra_modifiers = modifier_control },
};

const window_menu_items = [_]DefaultItem{
    .{ .title = "Minimize", .selector = menuRole("minimize"), .key = "m" },
    .{ .title = "Zoom", .selector = menuRole("zoom") },
    .{},
    .{ .title = "Close Window", .selector = menuRole("close"), .key = "w" },
    .{},
    .{ .title = "Bring All to Front", .selector = menuRole("front") },
};

const default_menus = [_]DefaultMenu{
    .{ .title = "App", .items = &app_menu_items, .use_app_name = true },
    .{ .title = "Edit", .items = &edit_menu_items },
    .{ .title = "View", .items = &view_menu_items },
    .{ .title = "Window", .items = &window_menu_items, .is_windows_menu = true },
};

/// Set the name AppKit shows for this app.
///
/// `-[NSProcessInfo processName]` is what the App menu title and the
/// "About X" / "Hide X" / "Quit X" items are built from, and for a bare binary
/// it is the executable's name — so every app launched through the shared
/// `craft` binary called itself "craft" in the menu bar. Setting it is the
/// whole of `--app-name`, and it is what makes a dev-mode app look like itself
/// without a packaging step.
///
/// Not the *kernel's* idea of the process name: `ps` and Activity Monitor read
/// that from the executable, and nothing running inside the process can change
/// it. Renaming there needs either a real `.app` bundle or an exec under a
/// different name.
///
/// Must run before `createApplicationMenu`, which reads the name once.
pub fn setProcessName(name: []const u8) void {
    // An empty name would leave the menu bar with a blank App menu and no way
    // to tell it apart from a missing one.
    if (name.len == 0) return;

    const NSProcessInfo = getClass("NSProcessInfo");
    const info = msgSend0(NSProcessInfo, "processInfo");
    if (info == null) return;
    msgSendVoid1(info, "setProcessName:", createNSString(name));
}

/// The app's display name: `-[NSProcessInfo processName]`, which is the
/// executable name for a bare binary, CFBundleName inside a `.app`, and
/// whatever `--app-name` said if it was given.
///
/// Copied into `buf` because the titles built from it are formatted, and a
/// name too long to fit is reported as absent rather than truncated — a cut
/// mid-codepoint would make `stringWithUTF8String:` return nil and the menu
/// item lose its title entirely.
fn appDisplayName(buf: []u8) ?[]const u8 {
    const NSProcessInfo = getClass("NSProcessInfo");
    const info = msgSend0(NSProcessInfo, "processInfo");
    if (info == null) return null;
    const name = msgSend0(info, "processName");
    if (name == null) return null;
    const utf8 = msgSend0(name, "UTF8String");
    if (utf8 == null) return null;
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
    if (span.len == 0 or span.len > buf.len) return null;
    @memcpy(buf[0..span.len], span);
    return buf[0..span.len];
}

/// Create the default application menu bar: App, Edit, View and Window.
///
/// Every item is a role with a **nil target**, so AppKit walks the responder
/// chain to perform it — exactly as a nib-built menu would. That is what makes
/// Cmd+C reach the focused field editor or the WKWebView rather than a handler
/// of ours, which can see neither.
///
/// Replaced wholesale the moment an app calls `craft.menu.set()`.
pub fn createApplicationMenu() void {
    const NSApplication = getClass("NSApplication");
    const NSMenu = getClass("NSMenu");
    const NSMenuItem = getClass("NSMenuItem");

    const app = msgSend0(NSApplication, "sharedApplication");
    const main_menu = msgSend0(msgSend0(NSMenu, "alloc"), "init");

    var name_buf: [128]u8 = undefined;
    const app_name = appDisplayName(&name_buf);

    for (default_menus) |menu_def| {
        const menu_title = createNSString(if (menu_def.use_app_name) (app_name orelse menu_def.title) else menu_def.title);
        const menu_item = msgSend0(msgSend0(NSMenuItem, "alloc"), "init");
        msgSendVoid1(menu_item, "setTitle:", menu_title);
        const menu = msgSend1(msgSend0(NSMenu, "alloc"), "initWithTitle:", menu_title);

        for (menu_def.items) |item| {
            const selector = item.selector orelse {
                msgSendVoid1(menu, "addItem:", msgSend0(NSMenuItem, "separatorItem"));
                continue;
            };

            // "Quit" becomes "Quit Craft" when we could read a name, and stays
            // "Quit" when we could not — a bare verb is a worse label than the
            // full one, but it is still the right item.
            var title_buf: [160]u8 = undefined;
            const title = if (item.with_app_name) blk: {
                const name = app_name orelse break :blk item.title;
                break :blk std.fmt.bufPrint(&title_buf, "{s} {s}", .{ item.title, name }) catch item.title;
            } else item.title;

            const native_item = msgSend3(
                msgSend0(NSMenuItem, "alloc"),
                "initWithTitle:action:keyEquivalent:",
                createNSString(title),
                sel(selector),
                createNSString(item.key),
            );
            if (item.extra_modifiers != 0) {
                msgSendVoid1Ulong(native_item, "setKeyEquivalentModifierMask:", modifier_command | item.extra_modifiers);
            }
            msgSendVoid1(menu, "addItem:", native_item);
        }

        msgSendVoid1(menu_item, "setSubmenu:", menu);
        msgSendVoid1(main_menu, "addItem:", menu_item);

        // Told about the Window menu, AppKit keeps the list of open windows in
        // it and adds the checkmark for the active one.
        if (menu_def.is_windows_menu) msgSendVoid1(app, "setWindowsMenu:", menu);
    }

    msgSendVoid1(app, "setMainMenu:", main_menu);
}

/// Initialize for menubar/system tray apps (NO Dock icon)
pub fn initAppForTray() void {
    const NSApplication = getClass("NSApplication");
    const app = msgSend0(NSApplication, "sharedApplication");

    // Use Accessory policy for menubar-only apps
    const NSApplicationActivationPolicyAccessory: c_long = 1;
    _ = msgSend1(app, "setActivationPolicy:", NSApplicationActivationPolicyAccessory);

    // MUST call finishLaunching BEFORE creating status bar items!
    // This is the key - the working test does it in this order
    msgSendVoid0(app, "finishLaunching");

    // Create application menu for standard shortcuts (CMD+H, CMD+Q, etc.)
    createApplicationMenu();
}

/// Show all windows (call this AFTER creating system tray, BEFORE runApp)
pub fn showAllWindows() void {
    // Get all windows
    const NSApplication = getClass("NSApplication");
    const app = msgSend0(NSApplication, "sharedApplication");
    const windows = msgSend0(app, "windows");

    // Show each window WITHOUT making it key (don't activate yet)
    const count_obj = msgSend0(windows, "count");
    const count: c_ulong = @intCast(@intFromPtr(count_obj));
    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        const window = msgSend1(windows, "objectAtIndex:", i);
        // Use orderFront instead of makeKeyAndOrderFront - this shows the window
        // without activating the app
        _ = msgSend1(window, "orderFront:", @as(?*anyopaque, null));
    }
}

pub fn runApp() void {
    startup_timing.mark(.runloop_entered);
    // Reported before `run`, which never returns.
    startup_timing.report();

    const NSApplication = getClass("NSApplication");
    const app = msgSend0(NSApplication, "sharedApplication");

    // DON'T activate - let the app activate naturally
    // The working test (test-minimal-tray.zig) doesn't call activate and it works!
    // Calling activate might interfere with the status bar item visibility

    // Run event loop
    msgSendVoid0(app, "run");
}

/// Activate as a regular, foreground windowed app. Windowed (non-tray) apps
/// must call this before runApp(): without it the process keeps the default
/// activation policy when launched outside an .app bundle, so the window
/// stays behind other apps with no Dock icon and never becomes key.
/// Tray/menubar apps must NOT call this — see the runApp() comment above.
pub fn activateWindowedApp() void {
    const NSApplication = getClass("NSApplication");
    const app = msgSend0(NSApplication, "sharedApplication");

    // NSApplicationActivationPolicyRegular = 0 (Dock icon + can become active)
    _ = msgSend1(app, "setActivationPolicy:", @as(c_long, 0));

    // Bring the key (or first) window to front and activate the app.
    const key_window = msgSend0(app, "keyWindow");
    if (key_window) |w| {
        _ = msgSend1(w, "makeKeyAndOrderFront:", @as(?*anyopaque, null));
    } else {
        const windows = msgSend0(app, "windows");
        const count_obj = msgSend0(windows, "count");
        const count: c_ulong = @intCast(@intFromPtr(count_obj));
        if (count > 0) {
            const window = msgSend1(windows, "objectAtIndex:", @as(c_ulong, 0));
            _ = msgSend1(window, "makeKeyAndOrderFront:", @as(?*anyopaque, null));
        }
    }

    _ = msgSend1(app, "activateIgnoringOtherApps:", @as(c_int, 1));
    startup_timing.mark(.window_shown);
}
