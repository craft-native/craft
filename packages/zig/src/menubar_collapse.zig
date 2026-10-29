//! Opt-in native menu-bar grouping. A compact arrow defines the boundary.
//! A chain of modest blank items to its left reserves the hidden space on
//! differently sized displays, without growing the arrow into system overflow.
//! AppKit owns Cmd-drag routing; unsafe placement restores the visible group.

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("logging.zig");
const layout = @import("menubar_layout.zig");

const log = logging.menu;

// ============================================================================
// Objective-C runtime
// ============================================================================

const objc = if (builtin.target.os.tag == .macos) struct {
    pub const id = ?*anyopaque;
    pub const Class = ?*anyopaque;
    pub const SEL = ?*anyopaque;
    pub const IMP = ?*anyopaque;
    pub const BOOL = bool;

    pub extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
    pub extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
    pub extern "objc" fn objc_msgSend() void;
    pub extern "objc" fn objc_msgSend_stret() void;
    pub extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extraBytes: usize) Class;
    pub extern "objc" fn objc_registerClassPair(cls: Class) void;
    pub extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) BOOL;
} else struct {
    pub const id = *anyopaque;
    pub const Class = *anyopaque;
    pub const SEL = *anyopaque;
};

// ============================================================================
// ObjC message sending helpers
// ============================================================================

fn getClass(name: [*:0]const u8) objc.id {
    if (builtin.target.os.tag != .macos) unreachable;
    return @ptrCast(@alignCast(objc.objc_getClass(name)));
}

fn msgSend0(target: anytype, sel: [*:0]const u8) objc.id {
    if (builtin.target.os.tag != .macos) unreachable;
    const f = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return f(target, objc.sel_registerName(sel));
}

fn msgSend1(target: anytype, sel: [*:0]const u8, a1: anytype) objc.id {
    if (builtin.target.os.tag != .macos) unreachable;
    const f = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(a1)) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    return f(target, objc.sel_registerName(sel), a1);
}

fn msgSendVoid1(target: anytype, sel: [*:0]const u8, a1: anytype) void {
    if (builtin.target.os.tag != .macos) unreachable;
    const f = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(a1)) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    f(target, objc.sel_registerName(sel), a1);
}

fn msgSendVoid2(target: anytype, sel: [*:0]const u8, a1: anytype, a2: anytype) void {
    if (builtin.target.os.tag != .macos) unreachable;
    const f = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(a1), @TypeOf(a2)) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    f(target, objc.sel_registerName(sel), a1, a2);
}

fn msgSendVoid3(target: anytype, sel: [*:0]const u8, a1: anytype, a2: anytype, a3: anytype) void {
    if (builtin.target.os.tag != .macos) unreachable;
    const f = @as(*const fn (@TypeOf(target), objc.SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3)) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    f(target, objc.sel_registerName(sel), a1, a2, a3);
}

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

/// `-frame` and friends return a 32-byte struct, which both macOS ABIs hand
/// back through a caller-provided pointer. On x86_64 that is a different entry
/// point; arm64 routes every return shape through `objc_msgSend`.
fn msgSendRect(target: anytype, sel: [*:0]const u8) CGRect {
    if (builtin.target.os.tag != .macos) unreachable;
    const entry = if (comptime builtin.target.cpu.arch == .x86_64)
        &objc.objc_msgSend_stret
    else
        &objc.objc_msgSend;
    const f = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) CGRect, @ptrCast(entry));
    return f(target, objc.sel_registerName(sel));
}

fn msgSendUsize(target: anytype, sel: [*:0]const u8) usize {
    if (builtin.target.os.tag != .macos) unreachable;
    const f = @as(*const fn (@TypeOf(target), objc.SEL) callconv(.c) usize, @ptrCast(&objc.objc_msgSend));
    return f(target, objc.sel_registerName(sel));
}

fn createNSString(str: []const u8) objc.id {
    const NSString = getClass("NSString");
    const alloc = msgSend0(NSString, "alloc");
    const allocator = std.heap.c_allocator;
    const z = @import("memory.zig").dupeZ(allocator, u8, str) catch return null;
    defer allocator.free(z);
    return msgSend1(alloc, "initWithUTF8String:", z.ptr);
}

fn getSystemStatusBar() objc.id {
    return msgSend0(getClass("NSStatusBar"), "systemStatusBar");
}

// ============================================================================
// Global State
// ============================================================================

const visibility = struct {
    extern fn craft_menubar_visibility_available() bool;
    extern fn craft_menubar_visibility_init(item: objc.id, changed: *const fn () callconv(.c) void, preserve_system_items: bool) void;
    extern fn craft_menubar_visibility_collapse() void;
    extern fn craft_menubar_visibility_expand() void;
    extern fn craft_menubar_visibility_cleanup() void;
    extern fn craft_menubar_visibility_request_permission() void;
    extern fn craft_menubar_visibility_collapsed() bool;
    extern fn craft_menubar_visibility_busy() bool;
    extern fn craft_menubar_visibility_state() [*:0]const u8;
};
var native_visibility: bool = false;
var early_initialized: bool = false;
var is_initialized: bool = false;
var is_collapsed: bool = false;

/// The compact arrow that the user arranges icons around.
var separator_item: objc.id = if (builtin.target.os.tag == .macos) null else null;
var spacer_items: [layout.MAX_SPACERS]objc.id = @splat(null);
var spacer_positions: [layout.MAX_SPACERS]f64 = @splat(0);
var spacer_count: usize = 0;
var spacer_width: f64 = 0;
var placement_index: usize = 0;
var placement_display_width: f64 = 0;
var placement_started_ns: ?u64 = null;
var placement_deadline_ns: ?u64 = null;
var control_anchor_edge: f64 = 0;
var spacer_placement: layout.SpacerPlacement = .{ .high = 0, .position = 0 };
var placement_reuses_spacer: bool = false;
var widening_started_ns: ?u64 = null;
var collapse_settled: bool = true;

var saved_tray_menu: objc.id = if (builtin.target.os.tag == .macos) null else null;
/// The app's own icon supplies the context menu; its position does not define
/// the group. The arrow remains available to reveal icons on either side of it.
var tray_item: objc.id = if (builtin.target.os.tag == .macos) null else null;
var click_target: objc.id = if (builtin.target.os.tag == .macos) null else null;
var class_registered: bool = false;
var native_timer: objc.id = null;

var separator_hidden: bool = false;
var reflow_started_ns: ?u64 = null;

/// A spacer being widened, and the bookkeeping needed to find out how far it
/// was allowed to go.
const Widening = struct {
    /// Where the marker stood before it started growing.
    origin: f64 = 0,
    /// What is currently being asked for. Comes down until it is granted.
    ask: f64 = 0,
    /// Cleared once the ask has been granted, or given up on.
    settled: bool = true,
    started_ns: ?u64 = null,

    /// Ask for the whole distance to the front of the bar. Whether that is
    /// allowed is not knowable up front, so `settle` finds out.
    fn begin(self: *Widening, item: objc.id) bool {
        const frame = markerFrame(item) orelse return false;
        const screen = markerScreenFrame(item) orelse return false;
        const started = nanoTimestamp() orelse return false;
        const origin = frame.origin.x;
        self.* = .{
            .origin = origin,
            .ask = origin - screen.origin.x + SEPARATOR_LENGTH,
            .settled = false,
            .started_ns = started,
        };
        setMarkerWidth(item, self.ask);
        return true;
    }

    /// Read back what the system actually did, and come down if it refused.
    /// Returns false once nothing worth doing is left to try.
    fn settle(self: *Widening, item: objc.id) bool {
        if (self.settled) return true;

        const started = self.started_ns orelse return true;
        const now = nanoTimestamp() orelse return true;
        if (now - started < SETTLE_GRACE_NS) return true;

        const moved = self.origin - (markerOriginX(item) orelse self.origin);
        if (moved >= self.ask * ACCEPTED_FRACTION) {
            self.settled = true;
            if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
                std.debug.print("[Menubar] Settled — moved {d}pt of {d}pt\n", .{ moved, self.ask });
            return true;
        }

        // Refused. An item only grows into whatever stretch of bar is actually
        // free, so an ask longer than that is turned down flat rather than
        // trimmed — and asking for less is the only way to find out how much
        // there is.
        //
        // Coming down is not a compromise. The free stretch is precisely the
        // gap the hidden icons have to cross, since they sit immediately to the
        // right of it, so the largest ask the system grants is also exactly the
        // one that clears them off.
        self.ask *= TARGET_BACKOFF;
        if (self.ask < MIN_TRAVEL) {
            self.settled = true;
            return false;
        }

        self.started_ns = now;
        setMarkerWidth(item, self.ask);
        return true;
    }

    fn reset(self: *Widening) void {
        self.* = .{};
    }
};

var single_widening: Widening = .{};

var auto_collapse_delay: u32 = 0;
var auto_collapse_timer_active: bool = false;
var last_expand_ns: ?u64 = null;

// Debounce: matches Hidden's isToggle with 0.3s cooldown
var toggle_debounce_active: bool = false;
var toggle_debounce_ns: ?u64 = null;
const DEBOUNCE_INTERVAL_NS: u64 = 300_000_000;

const SEPARATOR_LENGTH: f64 = 20.0; // matches Hidden's btnHiddenLength

/// The compact control gets a new identity: macOS can retain the old widening
/// separator's overflow placement independently of its saved position. Keep
/// this identity stable after that one-time migration.
const MARKER_AUTOSAVE_NAME = "craft_menubar_control";

/// How long to let the system get round to applying the widths before reading
/// back what it did. This is a duration rather than a number of checks because
/// the checks are driven by a poll from JavaScript that can fire many times a
/// second — counting them would give up in a few milliseconds, long before any
/// relayout could have happened.
const SETTLE_GRACE_NS: u64 = 400 * std.time.ns_per_ms;
const ACCEPTED_FRACTION: f64 = 0.9;
const TARGET_BACKOFF: f64 = 0.75;
const MIN_TRAVEL: f64 = 80.0;

/// Point toward the visible group when expanded; collapse reverses the arrow.
const MARKER_GLYPH = "›";

/// NSEvent types and masks. A status button reports left clicks only unless it
/// is told otherwise, so a right click would never reach `toggleClicked:`.
const NSEventTypeLeftMouseUp: usize = 2;
const NSEventTypeRightMouseDown: usize = 3;
const NSEventTypeRightMouseUp: usize = 4;
const NSEventMaskLeftMouseUp: c_ulong = 1 << 2;
const NSEventMaskRightMouseUp: c_ulong = 1 << 4;
const NSEventModifierFlagControl: usize = 1 << 18;

// ============================================================================
// Public API
// ============================================================================

/// Called from tray.zig before the tray item is created, to register the click
/// target the markers share.
pub fn earlyInit() void {
    if (builtin.target.os.tag != .macos) return;
    if (early_initialized) return;

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Menubar] earlyInit — registering click target...\n", .{});

    if (!class_registered) {
        const NSObject = getClass("NSObject");
        const className: [*:0]const u8 = "CraftMenubarCollapseTarget";
        var targetClass = objc.objc_getClass(className);

        if (targetClass == null) {
            targetClass = objc.objc_allocateClassPair(
                @ptrCast(@alignCast(NSObject)),
                className,
                0,
            );
            _ = objc.class_addMethod(
                @ptrCast(@alignCast(targetClass)),
                objc.sel_registerName("toggleClicked:"),
                @ptrCast(@constCast(&toggleClicked)),
                "v@:@",
            );
            _ = objc.class_addMethod(
                @ptrCast(@alignCast(targetClass)),
                objc.sel_registerName("collapseTimer:"),
                @ptrCast(@constCast(&collapseTimer)),
                "v@:@",
            );
            objc.objc_registerClassPair(@ptrCast(@alignCast(targetClass)));
        }

        const cls_id: objc.id = @ptrCast(@alignCast(targetClass));
        click_target = msgSend0(msgSend0(cls_id, "alloc"), "init");
        _ = msgSend0(click_target, "retain");
        class_registered = true;
    }

    early_initialized = true;

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Menubar] earlyInit done\n", .{});
}

/// Called after tray is created. Creates the compact boundary control.
pub fn init() void {
    if (builtin.target.os.tag != .macos) return;
    if (is_initialized) return;
    if (!early_initialized) earlyInit();

    const macos = @import("macos.zig");
    if (macos.getGlobalTrayHandle()) |tray_handle| {
        const statusItem: objc.id = @ptrFromInt(@intFromPtr(tray_handle));
        tray_item = statusItem;
        const menu = msgSend0(statusItem, "menu");
        if (menu != null) {
            saved_tray_menu = menu;
            _ = msgSend0(saved_tray_menu, "retain");
        }
    }

    // Configure the saved position before exposing the item to native layout.
    // Creating it at its final width first makes macOS ignore the autosave key.
    const defaults = msgSend0(getClass("NSUserDefaults"), "standardUserDefaults");
    const key = createNSString("NSStatusItem Preferred Position craft_menubar_control");
    if (msgSend1(defaults, "objectForKey:", key) == null) {
        const set_double = @as(*const fn (objc.id, objc.SEL, f64, objc.id) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
        set_double(defaults, objc.sel_registerName("setDouble:forKey:"), 1, key);
    }
    separator_item = msgSend1(getSystemStatusBar(), "statusItemWithLength:", @as(f64, 0));
    _ = msgSend0(separator_item, "retain");
    msgSendVoid1(separator_item, "setVisible:", @as(c_int, 0));
    msgSendVoid1(separator_item, "setAutosaveName:", createNSString(MARKER_AUTOSAVE_NAME));
    msgSendVoid1(separator_item, "setLength:", SEPARATOR_LENGTH);
    msgSendVoid1(separator_item, "setVisible:", @as(c_int, 1));
    drawMarker(separator_item, false);
    routeClicks(msgSend0(separator_item, "button"));

    // Native run-loop scheduling keeps collapse independent of hidden WebKit timers.
    const NSTimer = getClass("NSTimer");
    const schedule = @as(*const fn (objc.id, objc.SEL, f64, objc.id, objc.SEL, objc.id, bool) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    native_timer = schedule(NSTimer, objc.sel_registerName("timerWithTimeInterval:target:selector:userInfo:repeats:"), 0.1, click_target, objc.sel_registerName("collapseTimer:"), null, true);
    const run_loop = msgSend0(getClass("NSRunLoop"), "mainRunLoop");
    msgSendVoid2(run_loop, "addTimer:forMode:", native_timer, createNSString("kCFRunLoopCommonModes"));

    is_initialized = true;
    is_collapsed = false;

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Menubar] Ready — separator created\n", .{});
}

/// Explicit opt-in. Failure never selects the legacy width-based backend.
pub fn initNativeVisibility(preserve_system_items: bool) void {
    if (builtin.target.os.tag != .macos) return;
    if (is_initialized) {
        destroy();
    }
    native_visibility = true;
    visibility.craft_menubar_visibility_init(null, &visibilityChanged, preserve_system_items);
    if (!visibility.craft_menubar_visibility_available()) return;
    init();
    visibility.craft_menubar_visibility_init(separator_item, &visibilityChanged, preserve_system_items);
    drawMarker(separator_item, false);
}

pub fn nativeVisibilityState() ?[]const u8 {
    if (builtin.target.os.tag != .macos or !native_visibility) return null;
    return std.mem.span(visibility.craft_menubar_visibility_state());
}

pub fn requestPermission() void {
    if (builtin.target.os.tag == .macos and native_visibility)
        visibility.craft_menubar_visibility_request_permission();
}

fn visibilityChanged() callconv(.c) void {
    is_collapsed = visibility.craft_menubar_visibility_collapsed();
    auto_collapse_timer_active = false;
    drawMarker(separator_item, is_collapsed);
    notifyJS();
}

pub fn collapse() void {
    if (builtin.target.os.tag != .macos) return;
    if (native_visibility) {
        visibility.craft_menubar_visibility_collapse();
        return;
    }
    if (!is_initialized) {
        init();
        if (!is_initialized) return;
    }
    if (is_collapsed) return;
    if (separator_item == null) return;

    // The arrow remains the reveal control even if the app's own tray icon
    // has been arranged on its left. Only the divider defines the group.
    const marker = markerFrame(separator_item) orelse return;
    const screen = markerScreenFrame(separator_item) orelse return;
    const plan = planSpacers() orelse return;
    const now = nanoTimestamp() orelse return;
    control_anchor_edge = marker.origin.x + marker.size.width;
    spacer_count = plan.count;
    spacer_width = plan.width;
    placement_display_width = screen.size.width;
    for (0..layout.MAX_SPACERS) |index| {
        if (index < spacer_count) {
            const item = spacer_items[index];
            if (spacer_count > 1 and item != null and !writeSpacerPosition(index, spacer_positions[index])) {
                revealSpacers();
                return;
            }
            setMarkerWidth(item, SEPARATOR_LENGTH);
            if (spacer_count > 1 and item != null) msgSendVoid1(item, "setVisible:", @as(c_int, 1));
        } else removeSpacer(index);
    }
    if (!beginSpacerPlacement(0, now)) {
        revealSpacers();
        return;
    }
    placement_deadline_ns = now;
    collapse_settled = false;
    single_widening.reset();
    widening_started_ns = null;
    drawMarker(separator_item, true);

    is_collapsed = true;
    auto_collapse_timer_active = false;

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Menubar] Collapsed\n", .{});
    notifyJS();
}

pub fn expand() void {
    if (builtin.target.os.tag != .macos) return;
    if (native_visibility) {
        visibility.craft_menubar_visibility_expand();
        last_expand_ns = nanoTimestamp();
        auto_collapse_timer_active = auto_collapse_delay > 0;
        return;
    }
    if (!is_initialized) {
        init();
        if (!is_initialized) return;
    }
    if (!is_collapsed) return;
    if (separator_item == null) return;

    // Keep its native identity and ordering. Removing and recreating the
    // spacer makes macOS intermittently insert it on the control's right.
    collapse_settled = true;
    single_widening.reset();
    widening_started_ns = null;
    placement_deadline_ns = null;
    reflow_started_ns = null;
    placement_started_ns = null;
    placement_reuses_spacer = false;
    revealSpacers();
    drawMarker(separator_item, false);

    is_collapsed = false;
    last_expand_ns = nanoTimestamp();
    if (auto_collapse_delay > 0) {
        auto_collapse_timer_active = true;
    }

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Menubar] Expanded\n", .{});
    notifyJS();
}

pub fn toggle() void {
    if (builtin.target.os.tag != .macos) return;
    if (native_visibility) {
        if (is_collapsed or visibility.craft_menubar_visibility_busy()) expand() else collapse();
        return;
    }
    if (!is_initialized) {
        init();
        if (!is_initialized) return;
    }
    if (is_collapsed or (native_visibility and visibility.craft_menubar_visibility_busy())) expand() else collapse();
}

pub fn cleanup() void {
    if (builtin.target.os.tag == .macos and native_visibility) visibility.craft_menubar_visibility_cleanup();
    if (is_collapsed) expand();
    if (builtin.target.os.tag == .macos) for (0..layout.MAX_SPACERS) |index| {
        removeSpacer(index);
    };
    if (builtin.target.os.tag == .macos and native_timer != null) {
        _ = msgSend0(native_timer, "invalidate");
        native_timer = null;
    }
}

/// Disable grouping and remove its status item. No assertion survives it.
pub fn destroy() void {
    if (builtin.target.os.tag != .macos) return;
    cleanup();
    if (separator_item != null) {
        msgSendVoid1(getSystemStatusBar(), "removeStatusItem:", separator_item);
        _ = msgSend0(separator_item, "release");
        separator_item = null;
    }
    if (saved_tray_menu != null) {
        _ = msgSend0(saved_tray_menu, "release");
        saved_tray_menu = null;
    }
    is_initialized = false;
    is_collapsed = false;
    native_visibility = false;
    auto_collapse_timer_active = false;
}

pub fn isCollapsed() bool {
    return is_collapsed and (native_visibility or collapse_settled);
}

pub fn isBusy() bool {
    if (builtin.target.os.tag == .macos and native_visibility) return visibility.craft_menubar_visibility_busy();
    return is_collapsed and !collapse_settled;
}

pub fn markerWidth() f64 {
    if (builtin.target.os.tag != .macos) return 0;
    const frame = markerFrame(separator_item) orelse return 0;
    return frame.size.width;
}

pub fn isInitialized() bool {
    return is_initialized;
}

pub fn setAutoCollapse(delay_seconds: u32) void {
    auto_collapse_delay = delay_seconds;
    if (delay_seconds > 0 and !is_collapsed) {
        auto_collapse_timer_active = true;
        last_expand_ns = nanoTimestamp();
    } else {
        auto_collapse_timer_active = false;
    }
}

fn collapseTimer(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    checkAutoCollapse();
}

pub fn checkAutoCollapse() void {
    if (!native_visibility) {
        settleCollapse();
        restoreOnSystemReflow();
    }

    if (toggle_debounce_active) {
        if (toggle_debounce_ns) |start| {
            if (nanoTimestamp()) |now| {
                if (now - start >= DEBOUNCE_INTERVAL_NS) {
                    toggle_debounce_active = false;
                }
            }
        }
    }

    if (!auto_collapse_timer_active or auto_collapse_delay == 0 or is_collapsed) {
        if (is_collapsed) auto_collapse_timer_active = false;
        return;
    }
    const start = last_expand_ns orelse return;
    const now = nanoTimestamp() orelse return;
    const elapsed_ns = now - start;
    const delay_ns: u64 = @as(u64, auto_collapse_delay) * std.time.ns_per_s;
    if (elapsed_ns >= delay_ns) {
        // Let a Cmd-drag finish before changing the status bar geometry.
        if (builtin.target.os.tag == .macos and msgSendUsize(getClass("NSEvent"), "pressedMouseButtons") != 0) return;
        collapse();
    }
}

// ============================================================================
// Separator Visibility
// ============================================================================

pub fn setSeparatorHidden(hidden: bool) void {
    if (builtin.target.os.tag != .macos) return;
    separator_hidden = hidden and !native_visibility;

    drawMarker(separator_item, is_collapsed);
}

pub fn isSeparatorHidden() bool {
    return separator_hidden;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Send both mouse buttons through the item's action instead of letting AppKit
/// swallow the right click. Pair this with holding the menu rather than calling
/// `setMenu:` — an item with a menu attached opens it on either button and never
/// runs its action, so left click could not toggle.
fn routeClicks(button: objc.id) void {
    if (button == null) return;
    msgSendVoid1(button, "setTarget:", click_target);
    msgSendVoid1(button, "setAction:", objc.sel_registerName("toggleClicked:"));
    msgSendVoid1(button, "sendActionOn:", NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp);
}

/// The control stays compact; the separate spacer carries no content or action.
fn drawMarker(item: objc.id, widened: bool) void {
    if (item == null) return;
    const button = msgSend0(item, "button");
    if (button == null) return;
    const pending = native_visibility and visibility.craft_menubar_visibility_busy();
    const label = if (pending) "Cancel hiding menu bar items" else if (widened) "Show menu bar items" else "Hide menu bar items";
    msgSendVoid1(button, "setTitle:", createNSString(if (pending) "…" else if (widened) "‹" else if (native_visibility) "›" else if (separator_hidden) "" else MARKER_GLYPH));
    msgSendVoid1(button, "setToolTip:", createNSString(label));
    msgSendVoid1(button, "setAccessibilityLabel:", createNSString(label));
    clearHighlight(button);
}

/// AppKit applies status-item widths asynchronously. Set width before content.
fn setMarkerWidth(item: objc.id, width: f64) void {
    if (item == null) return;
    msgSendVoid1(item, "setLength:", width);
}

fn usesModernOverflow() bool {
    const Version = extern struct { major: isize, minor: isize, patch: isize };
    const test_version = @as(*const fn (objc.id, objc.SEL, Version) callconv(.c) bool, @ptrCast(&objc.objc_msgSend));
    return test_version(msgSend0(getClass("NSProcessInfo"), "processInfo"), objc.sel_registerName("isOperatingSystemAtLeastVersion:"), .{ .major = 27, .minor = 0, .patch = 0 });
}

fn planSpacers() ?layout.SpacerPlan {
    const screens = msgSend0(getClass("NSScreen"), "screens");
    const count = msgSendUsize(screens, "count");
    if (count == 0) return null;
    var shortest: f64 = std.math.inf(f64);
    var longest: f64 = 0;
    for (0..count) |index| {
        const screen = msgSend1(screens, "objectAtIndex:", index);
        const width = msgSendRect(screen, "frame").size.width;
        if (!std.math.isFinite(width) or width <= 0) return null;
        shortest = @min(shortest, width);
        longest = @max(longest, width);
    }
    return layout.planSpacers(shortest, longest, usesModernOverflow());
}

fn revealSpacers() void {
    for (spacer_items) |item| {
        if (item == null) continue;
        setMarkerWidth(item, 0);
        // The scene-based bar reserves padding even for a zero-width item.
        // Hide it while revealed without discarding its native identity.
        if (spacer_count > 1) msgSendVoid1(item, "setVisible:", @as(c_int, 0));
    }
}

fn removeSpacer(index: usize) void {
    const item = spacer_items[index] orelse return;
    msgSendVoid1(getSystemStatusBar(), "removeStatusItem:", item);
    _ = msgSend0(item, "release");
    spacer_items[index] = null;
}

fn writeSpacerPosition(index: usize, position: f64) bool {
    var key_buffer: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "NSStatusItem Preferred Position craft_menubar_spacer_{d}", .{index}) catch return false;
    const defaults = msgSend0(getClass("NSUserDefaults"), "standardUserDefaults");
    const set_double = @as(*const fn (objc.id, objc.SEL, f64, objc.id) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    set_double(defaults, objc.sel_registerName("setDouble:forKey:"), position, createNSString(key));
    return true;
}

fn createSpacer(index: usize, position: f64) bool {
    removeSpacer(index);
    var name_buffer: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "craft_menubar_spacer_{d}", .{index}) catch return false;
    if (!writeSpacerPosition(index, position)) return false;
    const item = msgSend1(getSystemStatusBar(), "statusItemWithLength:", @as(f64, 0));
    if (item == null) return false;
    spacer_items[index] = item;
    _ = msgSend0(item, "retain");
    msgSendVoid1(item, "setVisible:", @as(c_int, 0));
    msgSendVoid1(item, "setAutosaveName:", createNSString(name));
    msgSendVoid1(item, "setLength:", SEPARATOR_LENGTH);
    msgSendVoid1(item, "setVisible:", @as(c_int, 1));
    spacer_positions[index] = position;
    return true;
}

fn spacerAnchor(index: usize) objc.id {
    return if (index == 0) separator_item else spacer_items[index - 1];
}

fn beginSpacerPlacement(index: usize, now: u64) bool {
    placement_index = index;
    const defaults = msgSend0(getClass("NSUserDefaults"), "standardUserDefaults");
    const saved = msgSend1(defaults, "objectForKey:", createNSString("NSStatusItem Preferred Position craft_menubar_control"));
    const double_fn = @as(*const fn (objc.id, objc.SEL) callconv(.c) f64, @ptrCast(&objc.objc_msgSend));
    const preferred = if (saved != null) double_fn(saved, objc.sel_registerName("doubleValue")) else 1;
    const initial = if (index == 0) preferred + 1 else spacer_positions[index - 1] + 1;
    placement_reuses_spacer = spacer_items[index] != null;
    spacer_placement = layout.SpacerPlacement.init(if (placement_reuses_spacer) spacer_positions[index] else initial, placement_display_width);
    if (!placement_reuses_spacer and !createSpacer(index, spacer_placement.position)) return false;
    placement_started_ns = now;
    return true;
}

/// A failed collapse must not reschedule itself forever.
fn restoreCompactLayout() void {
    expand();
    auto_collapse_timer_active = false;
}

fn settleCollapse() void {
    if (!is_collapsed) return;
    if (placement_started_ns) |started| {
        const now = nanoTimestamp() orelse return;
        if (placement_deadline_ns) |begin| {
            if (now - begin > 8 * std.time.ns_per_s) {
                restoreCompactLayout();
                return;
            }
        }
        if (now - started < SETTLE_GRACE_NS) return;
        const anchor = markerFrame(spacerAnchor(placement_index)) orelse {
            restoreCompactLayout();
            return;
        };
        const spacer = markerFrame(spacer_items[placement_index]) orelse {
            restoreCompactLayout();
            return;
        };
        // A Cmd-drag can move the boundary while revealed. Reposition only
        // when a retained spacer is no longer beside the preceding control.
        if (placement_reuses_spacer and !layout.spacerPrecedesControl(anchor.origin.x, spacer.origin.x, spacer.size.width)) {
            placement_reuses_spacer = false;
            if (!createSpacer(placement_index, spacer_placement.position)) {
                restoreCompactLayout();
                return;
            }
            placement_started_ns = now;
            return;
        }
        placement_reuses_spacer = false;
        switch (spacer_placement.observe(anchor.origin.x, spacer.origin.x, spacer.size.width)) {
            .ready => {
                log.debug("menu bar spacer {d} placed at {d}", .{ placement_index, spacer_placement.position });
                if (placement_index + 1 < spacer_count) {
                    if (!beginSpacerPlacement(placement_index + 1, now)) restoreCompactLayout();
                    return;
                }
            },
            .retry => |position| {
                if (!createSpacer(placement_index, position)) {
                    restoreCompactLayout();
                    return;
                }
                placement_started_ns = now;
                return;
            },
            .failed => {
                log.debug("menu bar spacer {d} placement exhausted at {d}; anchor {d}, spacer {d}", .{ placement_index, spacer_placement.position, anchor.origin.x, spacer.origin.x });
                restoreCompactLayout();
                return;
            },
        }
        // Validate the complete compact chain before reserving any space. No
        // spacer may land to the right of the arrow or straddle an app icon.
        for (0..spacer_count) |index| {
            const previous = markerFrame(spacerAnchor(index)) orelse {
                restoreCompactLayout();
                return;
            };
            const item = markerFrame(spacer_items[index]) orelse {
                restoreCompactLayout();
                return;
            };
            if (!layout.spacerPrecedesControl(previous.origin.x, item.origin.x, item.size.width)) {
                restoreCompactLayout();
                return;
            }
        }
        const marker = markerFrame(separator_item) orelse {
            restoreCompactLayout();
            return;
        };
        control_anchor_edge = marker.origin.x + marker.size.width;
        placement_started_ns = null;
        placement_deadline_ns = null;
        if (spacer_count == 1) {
            if (!single_widening.begin(spacer_items[0])) restoreCompactLayout();
            return;
        }
        for (spacer_items[0..spacer_count]) |item| setMarkerWidth(item, spacer_width);
        widening_started_ns = now;
        return;
    }
    if (spacer_count == 1 and !collapse_settled) {
        if (!single_widening.settle(spacer_items[0])) {
            restoreCompactLayout();
            return;
        }
        if (!single_widening.settled) return;
        const marker = markerFrame(separator_item) orelse {
            restoreCompactLayout();
            return;
        };
        if (layout.markerEdgeDisplaced(control_anchor_edge, marker.origin.x, marker.size.width)) {
            restoreCompactLayout();
            return;
        }
        collapse_settled = true;
        drawMarker(separator_item, true);
        notifyJS();
        return;
    }
    if (widening_started_ns) |started| {
        const now = nanoTimestamp() orelse return;
        if (now - started < SETTLE_GRACE_NS) return;
        const marker = markerFrame(separator_item) orelse {
            restoreCompactLayout();
            return;
        };
        if (layout.markerEdgeDisplaced(control_anchor_edge, marker.origin.x, marker.size.width)) {
            log.debug("menu bar control moved while widening: expected edge {d}, actual {d}", .{ control_anchor_edge, marker.origin.x + marker.size.width });
            restoreCompactLayout();
            return;
        }
        widening_started_ns = null;
        collapse_settled = true;
        drawMarker(separator_item, true);
        notifyJS();
    }
}

/// The system's overflow can move the spacer away from the items it anchors.
/// Leave native overflow tracking to AppKit and release the reserved space.
/// A short grace period ignores intermediate frames during native relayout.
fn restoreOnSystemReflow() void {
    if (!is_collapsed or !collapse_settled) return;
    const marker = markerFrame(separator_item) orelse return;
    if (!layout.markerEdgeDisplaced(control_anchor_edge, marker.origin.x, marker.size.width)) {
        reflow_started_ns = null;
        return;
    }
    const now = nanoTimestamp() orelse return;
    const start = reflow_started_ns orelse {
        reflow_started_ns = now;
        return;
    };
    if (now - start >= 200 * std.time.ns_per_ms) {
        log.debug("menu bar control reflowed: expected edge {d}, actual {d}", .{ control_anchor_edge, marker.origin.x + marker.size.width });
        restoreCompactLayout();
    }
}

fn markerScreenFrame(item: objc.id) ?CGRect {
    if (item == null) return null;
    const button = msgSend0(item, "button");
    if (button == null) return null;
    const window = msgSend0(button, "window");
    if (window == null) return null;
    const screen = msgSend0(window, "screen");
    if (screen == null) return null;
    return msgSendRect(screen, "frame");
}

fn markerFrame(item: objc.id) ?CGRect {
    if (item == null) return null;
    const view = msgSend0(item, "button");
    if (view == null) return null;
    const window = msgSend0(view, "window");
    if (window == null) return null;
    // macOS 27 hosts several status buttons in the same native window. Its
    // frame cannot locate the divider relative to the app's tray button.
    const entry = if (comptime builtin.target.cpu.arch == .x86_64)
        &objc.objc_msgSend_stret
    else
        &objc.objc_msgSend;
    const convert_view = @as(*const fn (objc.id, objc.SEL, CGRect, objc.id) callconv(.c) CGRect, @ptrCast(entry));
    const convert_screen = @as(*const fn (objc.id, objc.SEL, CGRect) callconv(.c) CGRect, @ptrCast(entry));
    const bounds = msgSendRect(view, "bounds");
    const in_window = convert_view(view, objc.sel_registerName("convertRect:toView:"), bounds, null);
    return convert_screen(window, objc.sel_registerName("convertRectToScreen:"), in_window);
}

fn markerOriginX(item: objc.id) ?f64 {
    const frame = markerFrame(item) orelse return null;
    return frame.origin.x;
}

/// Take the pressed look back off a status button.
///
/// AppKit lights one up on mouse-down and leaves it lit for as long as it
/// assumes a menu is open. These buttons run an action instead, so nothing ever
/// comes along to put it out, and the marker sits there as a lozenge of
/// highlight in the middle of the bar. Telling the cell not to highlight is not
/// enough on its own — the state is already set by the time the action runs.
fn clearHighlight(button: objc.id) void {
    if (button == null) return;

    const cell = msgSend0(button, "cell");
    if (cell != null) msgSendVoid1(cell, "setHighlightsBy:", @as(c_ulong, 0));
    msgSendVoid1(button, "setHighlighted:", @as(c_int, 0));
}

fn nanoTimestamp() ?u64 {
    // Direct libc call — Zig 0.17 stripped `std.time.nanoTimestamp` and the
    // replacement `Io.Clock.now` requires plumbing an `Io` through this code
    // path, which isn't worth it for a debounce timer. CLOCK_MONOTONIC stays
    // monotonic across NTP adjustments which is what we need for diffing
    // intervals.
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return null;
    const sec_ns = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s;
    return sec_ns + @as(u64, @intCast(ts.nsec));
}

/// Whether the click that triggered the action asked for the menu rather than a
/// toggle. Control held during a left click is the long-standing macOS synonym
/// for a right click.
fn wantsMenu(event: objc.id) bool {
    if (event == null) return false;

    const event_type = msgSendUsize(event, "type");
    if (event_type == NSEventTypeRightMouseDown or event_type == NSEventTypeRightMouseUp) return true;

    const modifiers = msgSendUsize(event, "modifierFlags");
    return event_type == NSEventTypeLeftMouseUp and (modifiers & NSEventModifierFlagControl) != 0;
}

fn showTrayMenu(view: objc.id) void {
    const current_menu = msgSend0(tray_item, "menu");
    if (current_menu == null) return;
    const NSApp = msgSend0(getClass("NSApplication"), "sharedApplication");
    const event = msgSend0(NSApp, "currentEvent");
    if (event == null) return;
    msgSendVoid3(getClass("NSMenu"), "popUpContextMenu:withEvent:forView:", current_menu, event, view);
}

fn notifyJS() void {
    const macos = @import("macos.zig");
    if (nativeVisibilityState()) |state| {
        var native_buf: [2048]u8 = undefined;
        const native_js = std.fmt.bufPrint(&native_buf, "window.dispatchEvent(new CustomEvent('craft:menubar:stateChange',{{detail:{s}}}));", .{state}) catch return;
        macos.tryEvalJS(native_js) catch {};
        return;
    }
    var buf: [320]u8 = undefined;
    const js = std.fmt.bufPrint(&buf, "window.dispatchEvent(new CustomEvent('craft:menubar:stateChange',{{detail:{{backend:'legacy',initialized:{s},collapsed:{s},busy:{s},separatorHidden:{s},markerWidth:{d}}}}}));", .{
        if (is_initialized) "true" else "false",
        if (isCollapsed()) "true" else "false",
        if (isBusy()) "true" else "false",
        if (separator_hidden) "true" else "false",
        markerWidth(),
    }) catch return;
    macos.tryEvalJS(js) catch |err| {
        std.log.debug("JS eval failed for menubar collapse state callback: {}", .{err});
    };
}

fn toggleClicked(_: objc.id, _: objc.SEL, sender: objc.id) callconv(.c) void {
    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Menubar] Toggle clicked\n", .{});

    const NSApp = msgSend0(getClass("NSApplication"), "sharedApplication");
    const event = msgSend0(NSApp, "currentEvent");
    if (wantsMenu(event)) {
        if (sender != null) showTrayMenu(sender);
        clearHighlight(sender);
        return;
    }

    // Debounce rapid clicks (matches Hidden's isToggle)
    if (toggle_debounce_active) {
        if (toggle_debounce_ns) |start| {
            if (nanoTimestamp()) |now| {
                if (now - start < DEBOUNCE_INTERVAL_NS) return;
            }
        }
    }
    toggle_debounce_active = true;
    toggle_debounce_ns = nanoTimestamp();

    toggle();
    clearHighlight(sender);
}
