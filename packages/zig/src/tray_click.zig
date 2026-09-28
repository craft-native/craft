//! Left click acts, right click opens the menu.
//!
//! An `NSStatusItem` with a menu attached via `setMenu:` opens that menu on
//! either mouse button and never runs an action, so an app could not tell the
//! two apart — a caffeinate app wants left click to toggle and right click to
//! show options. Instead the menu is held here and attached only for the moment
//! it is being shown; a left click reaches JavaScript as a `craft:tray:click`
//! event, or, with `--tray-popover`, opens the popover itself.

const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos.zig");
const logging = @import("logging.zig");

const log = logging.tray;
const tray_popover = @import("tray_popover.zig");

const objc = macos.objc;
const msgSend0 = macos.msgSend0;
const msgSend1 = macos.msgSend1;
const getClass = macos.getClass;

/// NSEvent types and masks we care about.
const NSEventTypeLeftMouseUp: c_ulong = 2;
const NSEventTypeRightMouseUp: c_ulong = 4;
const NSEventMaskLeftMouseUp: c_ulong = 1 << NSEventTypeLeftMouseUp;
const NSEventMaskRightMouseUp: c_ulong = 1 << NSEventTypeRightMouseUp;
const NSEventModifierFlagControl: c_ulong = 1 << 18;

/// The status item whose clicks we handle, and the menu a right click shows.
var status_item: ?objc.id = null;
var menu: ?objc.id = null;

/// Whether a left click is waiting to be delivered to JavaScript, because the
/// page was not there to take it when it happened. A single flag rather than a
/// queue: clicks are user-paced, and coalescing a burst into one toggle is
/// friendlier than replaying every bounce.
var click_pending: bool = false;

const deliver_click_js = "if(window.__craftDeliverTrayClick)window.__craftDeliverTrayClick('left');";

/// Hand the click to the page now.
///
/// It used to wait for the page's 100ms `pollActions` timer to collect it. A
/// tray app's window is usually unshown, and WebKit throttles an unshown
/// page's timers to about once a second, so a click took up to a second to do
/// anything - on exactly the apps that exist to be clicked. Evaluating script
/// is not a timer and is not throttled.
fn deliverClick() void {
    const webview = @import("tray_menu.zig").getGlobalWebView() orelse {
        click_pending = true;
        return;
    };
    macos.tryEvalJSInWebView(@ptrCast(webview), deliver_click_js) catch {
        click_pending = true;
    };
}

pub fn setMenu(new_menu: ?objc.id) void {
    menu = new_menu;
}

pub fn takePendingClick() bool {
    if (!click_pending) return false;
    click_pending = false;
    return true;
}

/// Whether the event that triggered the action should open the menu. Control
/// held during a left click is the long-standing macOS synonym for right click.
fn wantsMenu(event: objc.id) bool {
    if (event == null) return false;

    const event_type = macos.msgSend0Ulong(event, "type");
    if (event_type == NSEventTypeRightMouseUp) return true;

    const modifiers = macos.msgSend0Ulong(event, "modifierFlags");
    return event_type == NSEventTypeLeftMouseUp and (modifiers & NSEventModifierFlagControl) != 0;
}

/// Show the menu for exactly one click, then detach it so the next left click
/// runs the action again rather than reopening the menu.
fn showMenu(item: objc.id, item_menu: objc.id) void {
    tray_popover.menuWillOpen();
    _ = msgSend1(item, "setMenu:", item_menu);
    const button = msgSend0(item, "button");
    if (button != null) _ = msgSend1(button, "performClick:", @as(objc.id, null));
    _ = msgSend1(item, "setMenu:", @as(objc.id, null));
}

/// Target action for the status item button, registered as `trayClick:`.
pub export fn trayClickCallback(_: objc.id, _: objc.SEL, _: objc.id) void {
    if (builtin.target.os.tag != .macos) return;

    const NSApplication = getClass("NSApplication");
    const app = msgSend0(NSApplication, "sharedApplication");
    const event = msgSend0(app, "currentEvent");

    if (wantsMenu(event)) {
        if (status_item) |item| {
            if (menu) |item_menu| {
                log.debug("tray right click: opening menu", .{});
                showMenu(item, item_menu);
                return;
            }
        }
        log.debug("tray right click: no menu set", .{});
        return;
    }

    if (tray_popover.isEnabled()) {
        log.debug("tray left click: toggling the popover", .{});
        tray_popover.handleClick();
        return;
    }

    log.debug("tray left click: delivering to JavaScript", .{});
    deliverClick();
}

/// Route the status item's button through `trayClickCallback` for both buttons.
pub fn install(item: objc.id) void {
    if (builtin.target.os.tag != .macos) return;

    status_item = item;
    tray_popover.setStatusItem(item);

    const button = msgSend0(item, "button");
    if (button == null) return;

    const NSObject = getClass("NSObject");
    const selector = objc.sel_registerName("trayClick:");
    _ = objc.class_addMethod(
        @ptrCast(@alignCast(NSObject)),
        selector,
        @as(objc.IMP, @ptrCast(@constCast(&trayClickCallback))),
        "v@:@",
    );

    const target = msgSend0(msgSend0(NSObject, "alloc"), "init");
    _ = msgSend0(target, "retain");

    _ = msgSend1(button, "setTarget:", target);
    _ = msgSend1(button, "setAction:", selector);
    // Without this the button only reports left clicks, so a right click would
    // fall through to AppKit's default (nothing) instead of opening the menu.
    macos.msgSendVoid1Ulong(button, "sendActionOn:", NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp);

    log.debug("tray click handling installed", .{});
}
