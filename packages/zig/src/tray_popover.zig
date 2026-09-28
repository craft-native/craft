//! `--tray-popover`: a tray app's window, opened, placed and dismissed the way
//! a menubar extra's popover is.
//!
//! Without it a tray app faked one from JavaScript, and it showed. The page
//! heard about the click through a 100ms poll that an unshown window's timer
//! throttling stretches to about a second, so the popover opened late. It could
//! not know where its status item was, so it pinned itself to the right edge of
//! the screen wherever the item really sat. And it was a frameless square with
//! nothing behind it: no rounded corners, no material, no shadow, and a status
//! item that did not stay highlighted while it was open.
//!
//! Here the status item's own click opens and closes the window with no
//! JavaScript in between. The window sits centred under the item, on that
//! item's screen (`popover_geometry.zig`), draws the popover material with
//! rounded corners and a shadow, and keeps the item highlighted while open.
//! Clicking anywhere else closes it, as does `craft.window.hide()` from the page
//! - which is how a page adds Escape. `craft.window.show()` opens it in place,
//! so a page can still open itself (to finish setup, say), and a page that
//! calls `craft.window.setSize()` to fit its content stays hung from the item.
//!
//! The page does not receive `craft:tray:click` in this mode: the click has
//! already been acted on, and a page that toggled on it too would close the
//! popover it just opened. It hears `craft:window:focus` and `:blur` instead.

const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos.zig");
const geometry = @import("popover_geometry.zig");
const logging = @import("logging.zig");

const log = logging.tray;
const objc = macos.objc;

/// NSStatusWindowLevel: above ordinary and floating windows, where the system
/// puts its own status menus.
const status_window_level: c_long = 25;
/// canJoinAllSpaces | ignoresCycle | fullScreenAuxiliary: present on whichever
/// Space is active and over a full-screen app, and never in the Cmd-` cycle.
const collection_behavior: c_ulong = (1 << 0) | (1 << 6) | (1 << 8);
/// NSVisualEffectMaterialMenu: what the status items' own menus draw, and the
/// one that reads as translucent beside them. The popover material renders
/// near-opaque white on current macOS.
const popover_material: c_long = 5;
/// What NSPopover and the system's status menus use.
const corner_radius: f64 = 10;
/// A click on the status item that lands this soon after the popover closed
/// itself is the click that closed it (the item sits outside the window), so it
/// must not open it again.
const reopen_guard_seconds: f64 = 0.3;

var enabled: bool = false;
var status_item: objc.id = null;
var popover: objc.id = null;
var dismissed_at: f64 = -1;
/// Whether the popover has had the keyboard since it was last opened.
var became_key: bool = false;

/// Turn the mode on. Before the window is created, which is when it is adopted.
pub fn enable() void {
    enabled = true;
}

pub fn isEnabled() bool {
    return enabled;
}

/// Whether a window about to be built is the popover, and so a panel. The
/// tray's window only, and only the first.
pub fn wantsPanel(system_tray: bool) bool {
    return enabled and system_tray and popover == null;
}

/// The item the popover hangs from. Recorded whether or not the mode is on,
/// because the tray is created before the flag's window.
pub fn setStatusItem(item: objc.id) void {
    status_item = item;
}

/// Whether `window` is the popover, so window calls from the page open and
/// close it the popover's way.
pub fn owns(window: anytype) bool {
    if (!enabled or popover == null) return false;
    return @intFromPtr(window) == @intFromPtr(popover);
}

/// Make the tray's window the popover. The first window only: an app that opens
/// a second one (Settings, say) wants an ordinary window for it.
pub fn adopt(window: objc.id) void {
    if (builtin.target.os.tag != .macos) return;
    if (!enabled or popover != null or window == null) return;
    popover = window;

    // A panel hides whenever its app is not active, which for a popover that
    // never activates the app would be always.
    _ = macos.msgSend1(window, "setHidesOnDeactivate:", @as(c_int, 0));
    _ = macos.msgSend1(window, "setLevel:", status_window_level);
    macos.msgSendVoid1Ulong(window, "setCollectionBehavior:", collection_behavior);
    _ = macos.msgSend1(window, "setMovable:", @as(c_int, 0));
    _ = macos.msgSend1(window, "setHasShadow:", @as(c_int, 1));

    // `--web-window-material` draws the sidebar material; a menu's is lighter
    // and is what the system's own status items open onto. Rounded on the
    // material itself: the page above it is clear, so its corners need no
    // mask, and the shadow AppKit derives from the window's alpha follows.
    macos.setWebMaterial(window, popover_material);
    macos.setWebMaterialCornerRadius(window, corner_radius);

    log.debug("tray popover adopted its window", .{});
}

fn isVisible() bool {
    return popover != null and macos.msgSendBool(popover, "isVisible");
}

fn uptime() f64 {
    const info = macos.msgSend0(macos.getClass("NSProcessInfo"), "processInfo");
    return macos.msgSend0Double(info, "systemUptime");
}

var highlight_wanted: bool = false;
var highlighter: objc.id = null;

fn applyHighlight() void {
    const item = status_item orelse return;
    const button = macos.msgSend0(item, "button");
    if (button == null) return;
    const on = @as(c_int, @intFromBool(highlight_wanted));
    _ = macos.msgSend1(button, "highlight:", on);
    _ = macos.msgSend1(button, "setHighlighted:", on);
}

export fn craftPopoverApplyHighlight(_: objc.id, _: objc.SEL) callconv(.c) void {
    applyHighlight();
}

/// Keep the status item drawn pressed while the popover is open, as the
/// system's own items are.
///
/// Set now and again on the next turn of the run loop. A click opens the
/// popover from inside the button's own mouse tracking, and when that tracking
/// ends the button puts its highlight back the way it found it - so a highlight
/// set only from the click handler was undone before it was ever drawn.
///
/// Whether the bar draws it is up to macOS. The release this was written on
/// (macOS 27) draws its pressed capsule only while an attached menu is open,
/// and ignores both calls; they are kept for the releases that honour them.
fn setItemHighlighted(highlighted: bool) void {
    highlight_wanted = highlighted;
    applyHighlight();

    if (highlighter == null) {
        const NSObject = macos.getClass("NSObject");
        var cls = objc.objc_getClass("CraftPopoverHighlighter");
        if (cls == null) {
            cls = objc.objc_allocateClassPair(NSObject, "CraftPopoverHighlighter", 0);
            if (cls == null) return;
            _ = objc.class_addMethod(cls, macos.sel("apply"), @ptrCast(@constCast(&craftPopoverApplyHighlight)), "v@:");
            objc.objc_registerClassPair(cls);
        }
        highlighter = macos.msgSend0(macos.msgSend0(cls, "alloc"), "init");
    }
    _ = macos.msgSend3(highlighter, "performSelector:withObject:afterDelay:", macos.sel("apply"), @as(objc.id, null), @as(f64, 0));
}

/// Move the popover under its status item. Left where it is if the item cannot
/// be measured, which beats guessing.
fn place() void {
    const window = popover orelse return;
    const item = status_item orelse return;
    const button = macos.msgSend0(item, "button");
    if (button == null) return;
    const item_window = macos.msgSend0(button, "window");
    if (item_window == null) return;

    var screen = macos.msgSend0(item_window, "screen");
    if (screen == null) screen = macos.msgSend0(macos.getClass("NSScreen"), "mainScreen");
    if (screen == null) return;

    const item_frame = macos.msgSendRect(item_window, "frame");
    const visible = macos.msgSendRect(screen, "visibleFrame");
    const size = macos.msgSendRect(window, "frame").size;

    const origin = geometry.anchor(
        .{ .x = item_frame.origin.x, .y = item_frame.origin.y, .width = item_frame.size.width, .height = item_frame.size.height },
        .{ .x = visible.origin.x, .y = visible.origin.y, .width = visible.size.width, .height = visible.size.height },
        size.width,
        size.height,
    );
    macos.msgSendVoid1(window, "setFrameOrigin:", macos.NSPoint{ .x = origin.x, .y = origin.y });
}

pub fn show() void {
    const window = popover orelse return;
    place();
    // An accessory app is not active until asked, and an inactive app's window
    // cannot take the keyboard.
    became_key = false;
    // No activation: the popover is a non-activating panel, so it takes the
    // keyboard while the app in front stays in front, as the system's own
    // status menus do. (Asking to activate was declined on current macOS
    // anyway, which is how typing into the popover reached the other app.)
    macos.msgSendVoid0(window, "orderFrontRegardless");
    macos.msgSendVoid0(window, "makeKeyWindow");
    // The shadow is computed from what the window has drawn; recompute it now
    // the rounded content is on screen, or it keeps a square outline.
    macos.msgSendVoid0(window, "invalidateShadow");
    setItemHighlighted(true);
}

pub fn hide() void {
    const window = popover orelse return;
    macos.msgSendVoid1(window, "orderOut:", @as(objc.id, null));
    setItemHighlighted(false);
}

pub fn toggle() void {
    if (isVisible()) hide() else show();
}

/// A left click on the status item.
pub fn handleClick() void {
    if (isVisible()) {
        hide();
        return;
    }
    if (dismissed_at >= 0 and uptime() - dismissed_at < reopen_guard_seconds) return;
    show();
}

/// The popover lost the keyboard: the person clicked another app, the desktop,
/// or another item in the menu bar. That closes it.
pub fn windowResignedKey(window: objc.id) void {
    // Only a popover that had the keyboard was clicked away from. One opened
    // while another app kept the keyboard never had it, and closing it on that
    // app's behalf would close it the moment it opened.
    if (!owns(window) or !isVisible() or !became_key) return;
    hide();
    dismissed_at = uptime();
}

pub fn windowBecameKey(window: objc.id) void {
    if (owns(window)) became_key = true;
}

/// The page resized its window (to fit its content, say). A resize keeps the
/// bottom-left corner, which would pull the popover's top edge away from the
/// menu bar, so hang it from the item again and redraw the shadow to the new
/// outline.
pub fn windowResized(window: objc.id) void {
    if (!owns(window) or !isVisible()) return;
    place();
    macos.msgSendVoid0(popover, "invalidateShadow");
}

/// The status item's menu is about to open. It and the popover are two ways
/// into the same app, and never both at once.
pub fn menuWillOpen() void {
    if (enabled and isVisible()) hide();
}
