//! Tucking menu bar items away, in the manner of Hidden Bar.
//!
//! macOS gives no API for hiding another app's menu bar item, so the trick is
//! to take up the room instead: a status item that grows very wide shoves the
//! items to its left off the front of the bar.
//!
//!   |    the marker: the boundary, and the item that grows
//!   ☕️   the app's own tray icon
//!
//!   expanded:  [items to hide] [|] [☕️]
//!   collapsed: [······················] [☕️]
//!
//! The user decides what gets hidden by cmd-dragging icons to the left of `|`.
//! Collapsed, the marker covers the space it just cleared, so clicking anywhere
//! in the emptied stretch brings the icons back. That is deliberately the only
//! affordance: a separate always-visible toggle button would be one more item
//! in a bar the user is trying to empty, and — being just another status item —
//! could itself end up left of the boundary and vanish with everything else.
//!
//! Three things about the growing are easy to get wrong, and each of them looks
//! like the feature doing nothing at all:
//!
//!   - A status item may only grow into the stretch of bar that is actually
//!     free, and an ask longer than that is refused outright rather than
//!     trimmed down to fit. The ports of this trick ask for a flat 10,000pt,
//!     which is over that everywhere, so nothing ever moves. Since the size of
//!     that stretch is not knowable up front, `collapse` asks for the whole
//!     distance and `settleCollapse` comes down until the bar really moves.
//!
//!     Coming down costs nothing, because the free stretch is precisely the gap
//!     the hidden icons have to cross — they sit immediately to its right — so
//!     the widest ask the system accepts is also exactly the one that clears
//!     them off. One marker is therefore always enough, and a chain of them
//!     buys nothing: extra status items only make the bar overflow, which macOS
//!     answers with a `«` of its own.
//!
//!   - The width has to be set before the button's title, or AppKit lays the
//!     button out against the old width and the growth is lost.
//!
//!   - Reading a frame back straight after setting a width still reports the
//!     old geometry, because the system resizes status windows asynchronously.
//!     Anything checking its own work has to wait a turn of the run loop.

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("logging.zig");

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

var early_initialized: bool = false;
var is_initialized: bool = false;
var is_collapsed: bool = false;

/// The `|`: the boundary the user arranges icons around, and the item that
/// widens to carry everything behind it off the bar.
var separator_item: objc.id = if (builtin.target.os.tag == .macos) null else null;

var saved_tray_menu: objc.id = if (builtin.target.os.tag == .macos) null else null;
/// The app's own icon. Nothing may be widened to its right, or the collapse
/// would carry it off the bar along with the icons it is meant to be hiding —
/// and with it the menu that turns the collapse back off.
var tray_item: objc.id = if (builtin.target.os.tag == .macos) null else null;
var click_target: objc.id = if (builtin.target.os.tag == .macos) null else null;
var class_registered: bool = false;

var separator_hidden: bool = false;

/// A marker being widened, and the bookkeeping needed to find out how far it
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
    fn begin(self: *Widening, item: objc.id) void {
        const origin = markerOriginX(item) orelse return;
        self.* = .{
            .origin = origin,
            .ask = origin + SEPARATOR_LENGTH,
            .settled = false,
            .started_ns = nanoTimestamp(),
        };
        setMarkerWidth(item, self.ask);
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

var collapse_widening: Widening = .{};

var auto_collapse_delay: u32 = 0;
var auto_collapse_timer_active: bool = false;
var last_expand_ns: ?u64 = null;

// Debounce: matches Hidden's isToggle with 0.3s cooldown
var toggle_debounce_active: bool = false;
var toggle_debounce_ns: ?u64 = null;
const DEBOUNCE_INTERVAL_NS: u64 = 300_000_000;

const SEPARATOR_LENGTH: f64 = 20.0; // matches Hidden's btnHiddenLength

/// Positions are remembered under these names, so they have to stay stable
/// across releases or everyone's arrangement resets.
const MARKER_AUTOSAVE_NAME = "craft_menubar_marker";

/// How long to let the system get round to applying the widths before reading
/// back what it did. This is a duration rather than a number of checks because
/// the checks are driven by a poll from JavaScript that can fire many times a
/// second — counting them would give up in a few milliseconds, long before any
/// relayout could have happened.
const SETTLE_GRACE_NS: u64 = 400 * std.time.ns_per_ms;

/// How much of the requested distance has to materialise for the widths to
/// count as accepted, and how much to come down by when they were not.
const ACCEPTED_FRACTION: f64 = 0.9;
const TARGET_BACKOFF: f64 = 0.75;

/// Below this there is not enough room to tuck anything away, so the bar goes
/// back to how it was rather than shuffling icons a few points sideways.
const MIN_TRAVEL: f64 = 80.0;

/// A plain divider rather than a chevron. macOS draws its own `«` when the bar
/// runs out of room, which a chevron here would be mistaken for — and the two
/// mean different things: that one appears on any crowded bar, whether or not
/// anything is tucked away.
const MARKER_GLYPH = "|";

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

/// Called after tray is created. Creates the separator (the width-changer).
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

    // The system drops each new status item to the left of the ones already
    separator_item = msgSend1(getSystemStatusBar(), "statusItemWithLength:", SEPARATOR_LENGTH);
    _ = msgSend0(separator_item, "retain");
    msgSendVoid1(separator_item, "setAutosaveName:", createNSString(MARKER_AUTOSAVE_NAME));
    drawMarker(separator_item, false);
    routeClicks(msgSend0(separator_item, "button"));
    suppressHighlight(separator_item);

    is_initialized = true;
    is_collapsed = false;

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Menubar] Ready — separator created\n", .{});
}

pub fn collapse() void {
    if (builtin.target.os.tag != .macos) return;
    if (!is_initialized) {
        init();
        if (!is_initialized) return;
    }
    if (is_collapsed) return;
    if (separator_item == null) return;

    // Carry the chain off the front of the bar; everything to its left travels
    // with it. No single item can stretch that far — past some width the system
    // ignores the request rather than trimming it down — so the distance is
    // split evenly between the links, which keeps each ask as small as it can
    // be and so as likely as possible to be honoured.
    const boundary = markerOriginX(separator_item) orelse return;

    // The `|` marks what gets hidden: everything to its left. If it has been
    // dragged past the app's own icon then the app's icon is on the wrong side
    // of that line, and collapsing would take away the very menu that turns the
    // collapse back off. Leave the bar alone and say so.
    if (boundary >= trayOriginX()) {
        log.debug("not collapsing: the marker sits right of the tray icon", .{});
        notifyJS();
        return;
    }

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Menubar] collapsing: boundary={d} tray={d}\n", .{ boundary, trayOriginX() });
    collapse_widening.begin(separator_item);

    is_collapsed = true;
    auto_collapse_timer_active = false;

    if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
        std.debug.print("[Menubar] Collapsed\n", .{});
    notifyJS();
}

pub fn expand() void {
    if (builtin.target.os.tag != .macos) return;
    if (!is_initialized) {
        init();
        if (!is_initialized) return;
    }
    if (!is_collapsed) return;
    if (separator_item == null) return;

    // Shrink the marker back, which brings the hidden icons along with it.
    collapse_widening.reset();
    setMarkerWidth(separator_item, SEPARATOR_LENGTH);

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
    if (!is_initialized) {
        init();
        if (!is_initialized) return;
    }
    if (is_collapsed) expand() else collapse();
}

pub fn cleanup() void {
    if (is_collapsed) expand();
}

pub fn isCollapsed() bool {
    return is_collapsed;
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

pub fn checkAutoCollapse() void {
    settleCollapse();

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
        collapse();
    }
}

// ============================================================================
// Separator Visibility
// ============================================================================

pub fn setSeparatorHidden(hidden: bool) void {
    if (builtin.target.os.tag != .macos) return;
    separator_hidden = hidden;

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

/// The divider the user arranges icons around: whatever ends up to its left is
/// what a collapse tucks away.
///
/// Only drawn at its resting size. A widened marker covers the stretch it just
/// cleared, and AppKit draws no title on a status button that wide anyway.
fn drawMarker(item: objc.id, widened: bool) void {
    if (item == null) return;
    const button = msgSend0(item, "button");
    if (button == null) return;

    const visible = !widened and !separator_hidden;
    msgSendVoid1(button, "setTitle:", createNSString(if (visible) MARKER_GLYPH else ""));
    clearHighlight(button);
}

/// Widen a marker as far as the system will let it, pushing the items to its
/// left off the end of the menu bar — or restore it to its normal width.
///
/// macOS caps how wide a status item may become, and a `setLength:` past that
/// cap is not clamped to the maximum: the item degenerates to nothing and the
/// bar lays out as if the marker were not there at all. Ports of the original
/// Hidden Bar trick ask for a flat 10,000pt, which lands past the cap on every
/// display this was measured on and so hides nothing.
///
/// Set a marker's width, and draw its `|` only at its resting size — a widened
/// marker spans most of the bar, so a dot centred in it would float somewhere
/// out in the empty space.
///
/// The width goes on before the title: a status button sizes itself to its own
/// content, so touching the title first makes AppKit lay the button out against
/// the width it had before, and the change is lost.
fn setMarkerWidth(item: objc.id, width: f64) void {
    if (item == null) return;
    msgSendVoid1(item, "setLength:", width);
    if (item == separator_item) drawMarker(item, width > SEPARATOR_LENGTH);
}

fn trayOriginX() f64 {
    return markerOriginX(tray_item) orelse screenWidth();
}

/// Confirm the widening actually moved the bar, and undo it if it did not.
///
/// The system resizes status item windows asynchronously, so this has to run a
/// turn of the run loop after the widths were set — never straight after them,
/// where the frames still read as they did before. It may take a few turns, so
/// a short run of quiet checks is normal; only a persistent shortfall means the
/// widths were refused outright.
fn settleCollapse() void {
    if (is_collapsed and !collapse_widening.settle(separator_item)) {
        // Nothing worth doing fits. Half a collapse strands icons in the middle
        // of the bar, which is worse than not collapsing at all.
        log.debug("menu bar collapse: no room to tuck anything away — restoring", .{});
        expand();
    }
}

/// The x of the marker's own status window. Read before widening: the system
/// resizes status item windows asynchronously, so a frame read straight after a
/// `setLength:` still reports the old geometry.
fn markerOriginX(item: objc.id) ?f64 {
    if (item == null) return null;
    const button = msgSend0(item, "button");
    if (button == null) return null;
    const window = msgSend0(button, "window");
    if (window == null) return null;
    return msgSendRect(window, "frame").origin.x;
}

fn screenWidth() f64 {
    const screen = msgSend0(getClass("NSScreen"), "mainScreen");
    if (screen == null) return 0;
    return msgSendRect(screen, "frame").size.width;
}

/// A status button flashes a highlight behind itself while pressed. Across a
/// widened marker that is a slab of colour over half the menu bar, so the
/// markers opt out of it and stay invisible whether or not they are being
/// clicked.
fn suppressHighlight(item: objc.id) void {
    clearHighlight(msgSend0(item, "button"));
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
    if (saved_tray_menu == null) return;
    const NSApp = msgSend0(getClass("NSApplication"), "sharedApplication");
    const event = msgSend0(NSApp, "currentEvent");
    if (event == null) return;
    msgSendVoid3(getClass("NSMenu"), "popUpContextMenu:withEvent:forView:", saved_tray_menu, event, view);
}

fn notifyJS() void {
    const macos = @import("macos.zig");
    var buf: [320]u8 = undefined;
    const js = std.fmt.bufPrint(&buf, "window.dispatchEvent(new CustomEvent('craft:menubar:stateChange',{{detail:{{collapsed:{s},separatorHidden:{s}}}}}));", .{
        if (is_collapsed) "true" else "false",
        if (separator_hidden) "true" else "false",
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
