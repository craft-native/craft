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
var validated_layout: bool = false;
var reorder_pending: bool = false;
var reorder_released_ns: ?u64 = null;
var reorder_drag: layout.DragTracker = .{};
var layout_access_url: objc.id = null;
var cached_layout_owner: objc.id = null;
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
const NSEventModifierFlagCommand: usize = 1 << 20;

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
    validated_layout = false;
    reorder_pending = false;
    reorder_released_ns = null;
    reorder_drag = .{};

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
    if (builtin.target.os.tag != .macos) return;
    if (native_visibility) {
        visibility.craft_menubar_visibility_request_permission();
        return;
    }
    if (layoutAvailable()) requestLayoutAccess();
}

const layout_preferences = struct {
    extern fn craft_menubar_layout_available() bool;
    extern fn craft_menubar_copy_layout_positions() objc.id;
    extern fn craft_menubar_request_layout_access(selected: *const fn (objc.id) callconv(.c) void) void;
};

fn layoutAvailable() bool {
    if (builtin.target.os.tag != .macos) return false;
    return layout_preferences.craft_menubar_layout_available();
}

const LAYOUT_BOOKMARK_KEY = "craft_menubar_layout_readonly_bookmark";
const LAYOUT_FILE = "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist";

fn layoutFileURL() objc.id {
    const home = msgSend0(msgSend0(getClass("NSFileManager"), "defaultManager"), "homeDirectoryForCurrentUser");
    const component = createNSString(LAYOUT_FILE);
    defer _ = msgSend0(component, "release");
    return msgSend1(home, "URLByAppendingPathComponent:", component);
}

fn isLayoutURL(url: objc.id) bool {
    if (url == null) return false;
    const equal = @as(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) bool, @ptrCast(&objc.objc_msgSend));
    return equal(msgSend0(url, "path"), objc.sel_registerName("isEqualToString:"), msgSend0(layoutFileURL(), "path"));
}

fn restoreLayoutAccess(data: objc.id) bool {
    if (data == null) return false;
    const resolve = @as(*const fn (objc.id, objc.SEL, objc.id, c_ulong, objc.id, ?*bool, ?*objc.id) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    var stale = false;
    const url = resolve(getClass("NSURL"), objc.sel_registerName("URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:"), data, (1 << 10) | (1 << 8), null, &stale, null);
    if (!isLayoutURL(url)) return false;
    if (layout_access_url != null) {
        _ = msgSend0(layout_access_url, "stopAccessingSecurityScopedResource");
        _ = msgSend0(layout_access_url, "release");
    }
    layout_access_url = msgSend0(url, "retain");
    _ = msgSend0(layout_access_url, "startAccessingSecurityScopedResource");
    return msgSend1(getClass("NSData"), "dataWithContentsOfURL:", layout_access_url) != null;
}

fn requestLayoutAccess() void {
    if (ensureLayoutAccess()) return;
    layout_preferences.craft_menubar_request_layout_access(layoutAccessSelected);
}

fn layoutAccessSelected(selected: objc.id) callconv(.c) void {
    if (!isLayoutURL(selected)) return;
    const bookmark = @as(*const fn (objc.id, objc.SEL, c_ulong, objc.id, objc.id, ?*objc.id) callconv(.c) objc.id, @ptrCast(&objc.objc_msgSend));
    // Resolve only a read-only bookmark; never retain the chooser's broader URL.
    const data = bookmark(selected, objc.sel_registerName("bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:"), (1 << 11) | (1 << 12), null, null, null);
    if (restoreLayoutAccess(data)) {
        const key = createNSString(LAYOUT_BOOKMARK_KEY);
        defer _ = msgSend0(key, "release");
        msgSendVoid2(msgSend0(getClass("NSUserDefaults"), "standardUserDefaults"), "setObject:forKey:", data, key);
    }
}

fn isObjectKind(value: objc.id, class_name: [*:0]const u8) bool {
    if (value == null) return false;
    const call = @as(*const fn (objc.id, objc.SEL, objc.id) callconv(.c) bool, @ptrCast(&objc.objc_msgSend));
    return call(value, objc.sel_registerName("isKindOfClass:"), getClass(class_name));
}

fn ensureLayoutAccess() bool {
    if (!layoutAvailable()) return false;
    if (layout_access_url == null) {
        const bookmark_key = createNSString(LAYOUT_BOOKMARK_KEY);
        defer _ = msgSend0(bookmark_key, "release");
        const saved = msgSend1(msgSend0(getClass("NSUserDefaults"), "standardUserDefaults"), "objectForKey:", bookmark_key);
        if (!restoreLayoutAccess(saved)) return false;
    }
    // Use the current path under the held scope; preferences are atomically replaced.
    return msgSend1(getClass("NSData"), "dataWithContentsOfURL:", layoutFileURL()) != null;
}

fn layoutPositions() objc.id {
    if (!ensureLayoutAccess()) return null;
    const positions = layout_preferences.craft_menubar_copy_layout_positions() orelse return null;
    return msgSend0(positions, "autorelease");
}

const code_identity = struct {
    extern "Security" fn SecCodeCopySelf(flags: u32, code: *objc.id) c_int;
    extern "Security" fn SecCodeCopySigningInformation(code: objc.id, flags: u32, info: *objc.id) c_int;
    extern "Security" var kSecCodeInfoFlags: objc.id;
    extern "Security" var kSecCodeInfoIdentifier: objc.id;
    extern "CoreFoundation" fn CFRelease(value: objc.id) void;
};

fn layoutOwner() objc.id {
    if (cached_layout_owner != null) return cached_layout_owner;
    var code: objc.id = null;
    if (code_identity.SecCodeCopySelf(0, &code) == 0 and code != null) {
        defer code_identity.CFRelease(code);
        var info: objc.id = null;
        if (code_identity.SecCodeCopySigningInformation(code, 0, &info) == 0 and info != null) {
            defer code_identity.CFRelease(info);
            const flags = msgSend1(info, "objectForKey:", code_identity.kSecCodeInfoFlags);
            // MenuBarAgent namespaces ad-hoc/unbundled clients by executable
            // name; trusted application clients use their signing identifier.
            if (flags != null and msgSendUsize(flags, "unsignedIntegerValue") & 2 == 0) {
                const identifier = msgSend1(info, "objectForKey:", code_identity.kSecCodeInfoIdentifier);
                if (isObjectKind(identifier, "NSString")) cached_layout_owner = msgSend0(identifier, "retain");
            }
        }
    }
    if (cached_layout_owner == null) {
        const arguments = msgSend0(msgSend0(getClass("NSProcessInfo"), "processInfo"), "arguments");
        const executable = msgSend1(arguments, "objectAtIndex:", @as(usize, 0));
        cached_layout_owner = msgSend0(msgSend0(executable, "lastPathComponent"), "retain");
    }
    return cached_layout_owner;
}

const ControlSlot = struct { position: f64, limit: f64 };

fn controlSlot() ?ControlSlot {
    const positions = layoutPositions() orelse return null;
    const owner = layoutOwner();
    const bytes = msgSend0(owner, "UTF8String") orelse return null;
    var buffer: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "status:{s}::{s}", .{ std.mem.span(@as([*:0]const u8, @ptrCast(bytes))), MARKER_AUTOSAVE_NAME }) catch return null;
    const native_key = createNSString(key);
    defer _ = msgSend0(native_key, "release");
    const value = msgSend1(positions, "objectForKey:", native_key);
    if (!isObjectKind(value, "NSNumber")) return null;
    const number = @as(*const fn (objc.id, objc.SEL) callconv(.c) f64, @ptrCast(&objc.objc_msgSend));
    const position = number(value, objc.sel_registerName("doubleValue"));
    if (!std.math.isFinite(position) or position < 0) return null;
    var limit = position + 32;
    const keys = msgSend0(positions, "allKeys");
    for (0..msgSendUsize(keys, "count")) |index| {
        const candidate_key = msgSend1(keys, "objectAtIndex:", index);
        if (msgSend0(candidate_key, "UTF8String")) |candidate_bytes| {
            const candidate_name = std.mem.span(@as([*:0]const u8, @ptrCast(candidate_bytes)));
            // Retired internal identities must not shrink the next available slot.
            if (std.mem.indexOf(u8, candidate_name, "::craft_menubar_spacer_") != null) continue;
        }
        const candidate = msgSend1(positions, "objectForKey:", candidate_key);
        if (!isObjectKind(candidate, "NSNumber")) continue;
        const next = number(candidate, objc.sel_registerName("doubleValue"));
        if (std.math.isFinite(next) and next > position) limit = @min(limit, next);
    }
    return .{ .position = position, .limit = limit };
}

pub fn layoutAuthorized() bool {
    if (builtin.target.os.tag != .macos) return false;
    return ensureLayoutAccess();
}

pub fn layoutPosition() ?f64 {
    if (builtin.target.os.tag != .macos) return null;
    const slot = controlSlot() orelse return null;
    return slot.position;
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
    beginLayoutUpdates();
    defer endLayoutUpdates();
    reorder_pending = false;
    reorder_released_ns = null;
    const reuse_layout = plan.count > 1 and validated_layout and spacer_count == plan.count and spacer_width == plan.width and
        @abs(marker.origin.x + marker.size.width - control_anchor_edge) <= 1;
    validated_layout = false;
    spacer_count = plan.count;
    spacer_width = plan.width;
    placement_display_width = screen.size.width;
    for (0..layout.MAX_SPACERS) |index| {
        if (index < spacer_count) {
            const item = spacer_items[index];
            if (spacer_count > 1) hideSpacer(index) else setMarkerWidth(item, SEPARATOR_LENGTH);
        } else removeSpacer(index);
    }
    collapse_settled = false;
    single_widening.reset();
    widening_started_ns = null;
    drawMarker(separator_item, true);

    is_collapsed = true;
    auto_collapse_timer_active = false;
    if (reuse_layout) {
        if (!beginWidening(now)) {
            restoreCompactLayout();
            return;
        }
    } else if (if (spacer_count > 1) controlSlot() else null) |slot| {
        control_anchor_edge = marker.origin.x + marker.size.width;
        if (!placeModernSpacers(now, slot)) {
            restoreCompactLayout();
            return;
        }
    } else {
        if (!beginSpacerPlacement(0, now)) {
            restoreCompactLayout();
            return;
        }
        placement_deadline_ns = now;
    }

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

    beginLayoutUpdates();
    defer endLayoutUpdates();
    // Keep its native identity and ordering. Removing and recreating the
    // spacer makes macOS intermittently insert it on the control's right.
    if (!collapse_settled) validated_layout = false;
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
    if (builtin.target.os.tag == .macos and cached_layout_owner != null) {
        _ = msgSend0(cached_layout_owner, "release");
        cached_layout_owner = null;
    }
    if (builtin.target.os.tag == .macos and layout_access_url != null) {
        _ = msgSend0(layout_access_url, "stopAccessingSecurityScopedResource");
        _ = msgSend0(layout_access_url, "release");
        layout_access_url = null;
    }
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
    if (builtin.target.os.tag != .macos) return;
    const buttons = msgSendUsize(getClass("NSEvent"), "pressedMouseButtons");
    if (buttons != 0) {
        const left_down = buttons & 1 != 0;
        const command = msgSendUsize(getClass("NSEvent"), "modifierFlags") & NSEventModifierFlagCommand != 0;
        const point_fn = @as(*const fn (objc.id, objc.SEL) callconv(.c) CGPoint, @ptrCast(&objc.objc_msgSend));
        const point = point_fn(getClass("NSEvent"), objc.sel_registerName("mouseLocation"));
        const in_menu_bar = left_down and command and !reorder_drag.pressed and mouseInMenuBar(point);
        if (reorder_drag.update(left_down, command, in_menu_bar, point.x, point.y)) {
            validated_layout = false;
            reorder_pending = true;
            reorder_released_ns = null;
        }
        // Native reordering must finish before geometry or visibility changes.
        return;
    }
    _ = reorder_drag.update(false, false, false, 0, 0);
    if (reorder_pending) {
        const now = nanoTimestamp() orelse return;
        const released = reorder_released_ns orelse {
            reorder_released_ns = now;
            return;
        };
        if (now - released < 200 * std.time.ns_per_ms) return;
        reorder_pending = false;
        reorder_released_ns = null;
        if (is_collapsed) {
            restoreCompactLayout();
            return;
        }
    }
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

fn mouseInMenuBar(point: CGPoint) bool {
    const double_fn = @as(*const fn (objc.id, objc.SEL) callconv(.c) f64, @ptrCast(&objc.objc_msgSend));
    const thickness = double_fn(getSystemStatusBar(), objc.sel_registerName("thickness"));
    const responds = @as(*const fn (objc.id, objc.SEL, objc.SEL) callconv(.c) bool, @ptrCast(&objc.objc_msgSend));
    const screens = msgSend0(getClass("NSScreen"), "screens");
    for (0..msgSendUsize(screens, "count")) |index| {
        const screen = msgSend1(screens, "objectAtIndex:", index);
        const frame = msgSendRect(screen, "frame");
        const visible = msgSendRect(screen, "visibleFrame");
        const top = frame.origin.y + frame.size.height;
        var height = @max(thickness, top - visible.origin.y - visible.size.height);
        // Notched and automatically hidden bars can be taller than the
        // status item's content area. This public rectangle describes the
        // extra top region without observing other apps' accessibility trees.
        const auxiliary = objc.sel_registerName("auxiliaryTopRightArea");
        if (responds(screen, objc.sel_registerName("respondsToSelector:"), auxiliary)) {
            height = @max(height, msgSendRect(screen, "auxiliaryTopRightArea").size.height);
        }
        if (point.x >= frame.origin.x and point.x <= frame.origin.x + frame.size.width and
            point.y >= top - height and point.y <= top) return true;
    }
    return false;
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

fn beginLayoutUpdates() void {
    const animation = getClass("NSAnimationContext");
    _ = msgSend0(animation, "beginGrouping");
    const context = msgSend0(animation, "currentContext");
    msgSendVoid1(context, "setDuration:", @as(f64, 0));
    msgSendVoid1(context, "setAllowsImplicitAnimation:", @as(c_int, 0));
}

fn endLayoutUpdates() void {
    _ = msgSend0(getClass("NSAnimationContext"), "endGrouping");
}

fn usesModernOverflow() bool {
    const Version = extern struct { major: isize, minor: isize, patch: isize };
    const test_version = @as(*const fn (objc.id, objc.SEL, Version) callconv(.c) bool, @ptrCast(&objc.objc_msgSend));
    return test_version(msgSend0(getClass("NSProcessInfo"), "processInfo"), objc.sel_registerName("isOperatingSystemAtLeastVersion:"), .{ .major = 27, .minor = 0, .patch = 0 });
}

fn planSpacers() ?layout.SpacerPlan {
    const modern = usesModernOverflow();
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
    return layout.planSpacers(shortest, longest, modern);
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

fn hideSpacer(index: usize) void {
    const item = spacer_items[index] orelse return;
    setMarkerWidth(item, 0);
    msgSendVoid1(item, "setVisible:", @as(c_int, 0));
}

fn removeSpacer(index: usize) void {
    const item = spacer_items[index] orelse return;
    const name = msgSend0(item, "autosaveName");
    _ = msgSend0(name, "retain");
    msgSendVoid1(getSystemStatusBar(), "removeStatusItem:", item);
    _ = msgSend0(item, "release");
    spacer_items[index] = null;
    clearSpacerPreference(name, "NSStatusItem Preferred Position ");
    clearSpacerPreference(name, "NSStatusItem VisibleCC ");
    _ = msgSend0(name, "release");
}

fn writeSpacerPosition(index: usize, position: f64) bool {
    const item = spacer_items[index] orelse return false;
    return writeNamedSpacerPosition(msgSend0(item, "autosaveName"), position);
}

fn spacerPreferenceKey(name: objc.id, prefix: []const u8, buffer: []u8) ?objc.id {
    if (name == null) return null;
    const bytes = msgSend0(name, "UTF8String") orelse return null;
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(bytes)));
    const key = std.fmt.bufPrint(buffer, "{s}{s}", .{ prefix, text }) catch return null;
    return createNSString(key);
}

fn clearSpacerPreference(name: objc.id, prefix: []const u8) void {
    var key_buffer: [192]u8 = undefined;
    const key = spacerPreferenceKey(name, prefix, &key_buffer) orelse return;
    defer _ = msgSend0(key, "release");
    msgSendVoid1(msgSend0(getClass("NSUserDefaults"), "standardUserDefaults"), "removeObjectForKey:", key);
}

fn writeNamedSpacerPosition(name: objc.id, position: f64) bool {
    var key_buffer: [192]u8 = undefined;
    const key = spacerPreferenceKey(name, "NSStatusItem Preferred Position ", &key_buffer) orelse return false;
    defer _ = msgSend0(key, "release");
    const defaults = msgSend0(getClass("NSUserDefaults"), "standardUserDefaults");
    const set_double = @as(*const fn (objc.id, objc.SEL, f64, objc.id) callconv(.c) void, @ptrCast(&objc.objc_msgSend));
    set_double(defaults, objc.sel_registerName("setDouble:forKey:"), position, key);
    return true;
}

fn createSpacer(index: usize, position: f64) bool {
    return createSpacerWithWidth(index, position, SEPARATOR_LENGTH);
}

fn createSpacerWithWidth(index: usize, position: f64, width: f64) bool {
    removeSpacer(index);
    // Native overflow can remember a retired item's placement independently
    // of its preferred position. A replacement needs a fresh internal identity;
    // the user's draggable arrow keeps its stable identity throughout.
    const identifier = msgSend0(msgSend0(getClass("NSUUID"), "UUID"), "UUIDString");
    const bytes = msgSend0(identifier, "UTF8String") orelse return false;
    const unique = std.mem.span(@as([*:0]const u8, @ptrCast(bytes)));
    var name_buffer: [96]u8 = undefined;
    const name_text = std.fmt.bufPrint(&name_buffer, "craft_menubar_spacer_{d}_{s}", .{ index, unique }) catch return false;
    const name = createNSString(name_text);
    defer _ = msgSend0(name, "release");
    if (!writeNamedSpacerPosition(name, position)) return false;
    const item = msgSend1(getSystemStatusBar(), "statusItemWithLength:", @as(f64, 0));
    if (item == null) return false;
    spacer_items[index] = item;
    _ = msgSend0(item, "retain");
    msgSendVoid1(item, "setVisible:", @as(c_int, 0));
    msgSendVoid1(item, "setAutosaveName:", name);
    msgSendVoid1(item, "setLength:", width);
    msgSendVoid1(item, "setVisible:", @as(c_int, 1));
    spacer_positions[index] = position;
    return true;
}

fn placeModernSpacers(now: u64, slot: ControlSlot) bool {
    // Reordering invalidates the old positions. Give each replacement its
    // final width and a fresh identity beside the live boundary in one
    // run-loop turn, rather than visibly probing compact items one by one.
    for (0..spacer_count) |index| {
        const position = layout.spacerPosition(slot.position, slot.limit, index, spacer_count) orelse return false;
        if (!createSpacerWithWidth(index, position, spacer_width)) return false;
    }
    placement_started_ns = null;
    placement_deadline_ns = null;
    widening_started_ns = now;
    return true;
}

fn beginSpacerPlacement(index: usize, now: u64) bool {
    placement_index = index;
    const defaults = msgSend0(getClass("NSUserDefaults"), "standardUserDefaults");
    const saved = msgSend1(defaults, "objectForKey:", createNSString("NSStatusItem Preferred Position craft_menubar_control"));
    const double_fn = @as(*const fn (objc.id, objc.SEL) callconv(.c) f64, @ptrCast(&objc.objc_msgSend));
    const preferred = if (saved != null) double_fn(saved, objc.sel_registerName("doubleValue")) else 1;
    const initial = if (index == 0) preferred + 1 else spacer_positions[index - 1] + 1;
    const position = if (index == 0 and spacer_items[index] != null) spacer_positions[index] else initial;
    placement_reuses_spacer = spacer_items[index] != null and spacer_positions[index] == position;
    spacer_placement = layout.SpacerPlacement.init(position, placement_display_width);
    if (!placement_reuses_spacer and !createSpacer(index, spacer_placement.position)) return false;
    if (placement_reuses_spacer and spacer_count > 1) {
        if (!writeSpacerPosition(index, position)) return false;
        setMarkerWidth(spacer_items[index], SEPARATOR_LENGTH);
        msgSendVoid1(spacer_items[index], "setVisible:", @as(c_int, 1));
    }
    placement_started_ns = now;
    return true;
}

/// A failed collapse must not reschedule itself forever.
fn restoreCompactLayout() void {
    validated_layout = false;
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
        const anchor = markerFrame(separator_item) orelse {
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
                    // Near a notch there is no room for a whole compact
                    // chain. Calibrate each item beside the arrow, then hide
                    // it until the complete reservation can be restored.
                    if (spacer_count > 1) hideSpacer(placement_index);
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
        if (!beginWidening(now)) restoreCompactLayout();
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
        validated_layout = true;
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
        validated_layout = true;
        drawMarker(separator_item, true);
        notifyJS();
    }
}

fn beginWidening(now: u64) bool {
    const marker = markerFrame(separator_item) orelse return false;
    control_anchor_edge = marker.origin.x + marker.size.width;
    placement_started_ns = null;
    placement_deadline_ns = null;
    if (spacer_count == 1) return single_widening.begin(spacer_items[0]);
    hideSpacer(placement_index);
    for (0..spacer_count) |index| {
        if (!writeSpacerPosition(index, spacer_positions[index])) return false;
        setMarkerWidth(spacer_items[index], spacer_width);
        msgSendVoid1(spacer_items[index], "setVisible:", @as(c_int, 1));
    }
    widening_started_ns = now;
    return true;
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
    if (event != null and msgSendUsize(event, "modifierFlags") & NSEventModifierFlagCommand != 0) {
        validated_layout = false;
        clearHighlight(sender);
        return;
    }
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

    if (!native_visibility and !is_collapsed and layoutAvailable() and !layoutAuthorized()) {
        requestLayoutAccess();
        if (!layoutAuthorized()) {
            clearHighlight(sender);
            return;
        }
    }
    toggle();
    clearHighlight(sender);
}
