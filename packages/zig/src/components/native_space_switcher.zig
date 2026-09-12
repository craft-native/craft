//! A native switcher for Arc-style sidebar spaces.
//!
//! The web side (`<SidebarSpaces>` in @stacksjs/components) renders the spaces
//! and owns the swipe. What it cannot do is put a real control in the window
//! chrome, so it asks the host: `window.craft.nativeUI.createSpacesSidebar()`
//! publishes the space list here and follows whatever this selects.
//!
//! On macOS that is an NSSegmentedControl in the titlebar, placed beside the
//! traffic lights the same way the web-sidebar chrome buttons are. It is a
//! *switcher*, not a second sidebar — the rows stay in the webview, which is
//! why this does not go anywhere near `NativeSidebar` or its one-per-window
//! restriction.
//!
//! The list bookkeeping lives in `space_list.zig` so the id/index mapping can
//! be tested without a window.

const std = @import("std");
const builtin = @import("builtin");
const macos = @import("../macos.zig");
const space_list = @import("space_list.zig");

const objc = macos.objc;

pub const Space = space_list.Space;

var switcherClass: objc.Class = null;
var switcher_association_key: u8 = 0;

pub const SpaceSwitcher = struct {
    allocator: std.mem.Allocator,
    spaces: space_list.SpaceList,
    /// The NSSegmentedControl, or null when the window had no titlebar to
    /// attach to. The list still works; only the visible control is missing.
    control: objc.id = null,
    /// Retained so the control has a target to send its action to.
    responder: objc.id = null,
    /// The page that created the switcher. Target/action fires outside bridge
    /// dispatch, so there is no `window_context` left to route the event.
    webview: objc.id = null,
    /// Component id from JS, echoed back on every event so a page with more
    /// than one consumer can tell them apart.
    id: []const u8,

    pub fn deinit(self: *SpaceSwitcher) void {
        if (self.control != null) {
            _ = macos.msgSend0(self.control, "removeFromSuperview");
            self.control = null;
        }
        // The responder is a view too, and `create` destroys the old switcher
        // before building the new one — leaving it parented would strand a
        // zero-sized subview in the window chrome on every re-create.
        if (self.responder != null) {
            objc.objc_setAssociatedObject(
                self.responder,
                &switcher_association_key,
                null,
                objc.OBJC_ASSOCIATION_RETAIN,
            );
            _ = macos.msgSend0(self.responder, "removeFromSuperview");
            self.responder = null;
        }
        self.spaces.deinit();
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }
};

// =============================================================================
// Target/action
// =============================================================================

fn switcherForResponder(responder: objc.id) ?*SpaceSwitcher {
    const associated = objc.objc_getAssociatedObject(responder, &switcher_association_key);
    if (associated == @as(objc.id, null)) return null;

    const ptr = macos.msgSend0(associated, "pointerValue");
    if (@intFromPtr(ptr) == 0) return null;
    return @ptrCast(@alignCast(ptr));
}

fn spaceSelectedCallback(responder: objc.id, _: objc.SEL, sender: objc.id) callconv(.c) void {
    const self = switcherForResponder(responder) orelse return;
    if (sender == null) return;

    const selected = macos.msgSend0Ulong(sender, "selectedSegment");
    // NSSegmentedControl reports -1 as NSNotFound-ish when nothing is selected;
    // it arrives here as a very large unsigned value, which `setActiveIndex`
    // rejects along with any other out-of-range index.
    if (!self.spaces.setActiveIndex(@intCast(selected))) return;

    const space = self.spaces.activeSpace() orelse return;
    emitSpaceChange(self.webview, self.id, space.id);
}

fn ensureSwitcherClass() void {
    if (switcherClass != null) return;

    const NSView = macos.getClass("NSView");
    switcherClass = objc.objc_allocateClassPair(NSView, "CraftSpaceSwitcherView", 0);
    if (switcherClass == null) return;

    _ = objc.class_addMethod(
        switcherClass,
        macos.sel("craftSpaceSelected:"),
        @ptrCast(@constCast(&spaceSelectedCallback)),
        "v@:@",
    );

    objc.objc_registerClassPair(switcherClass);
}

/// Ids are interpolated straight into an `evaluateJavaScript` string, so a
/// stray quote or backslash would be a syntax error at best and an injection at
/// worst. Characters outside a conservative identifier set are dropped rather
/// than escaped: an id we cannot represent safely is a bug worth surfacing, not
/// a string worth mangling.
pub fn sanitizeId(out: []u8, value: []const u8) []const u8 {
    var len: usize = 0;
    for (value) |c| {
        if (len == out.len) break;
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == ':';
        if (!safe) continue;
        out[len] = c;
        len += 1;
    }
    return out[0..len];
}

/// Tell the web side which space the user picked.
///
/// `_emitSpaceChange` is defined by `craft-native-ui.js`; guarding on it means
/// an event that lands before the script has run, or after the page navigated
/// away, is a no-op rather than a console error.
fn emitSpaceChange(webview: objc.id, component_id: []const u8, space_id: []const u8) void {
    var component_buf: [128]u8 = undefined;
    var space_buf: [128]u8 = undefined;
    var js_buf: [512]u8 = undefined;

    const js = std.fmt.bufPrint(
        &js_buf,
        "window.craft&&window.craft.nativeUI&&window.craft.nativeUI._emitSpaceChange&&window.craft.nativeUI._emitSpaceChange(\"{s}\",\"{s}\")",
        .{ sanitizeId(&component_buf, component_id), sanitizeId(&space_buf, space_id) },
    ) catch return;

    macos.tryEvalJSInWebView(webview, js) catch {};
}

// =============================================================================
// The control
// =============================================================================

fn rebuildSegments(self: *SpaceSwitcher) void {
    const control = self.control;
    if (control == null) return;

    const count = self.spaces.count();
    macos.msgSendVoid1Ulong(control, "setSegmentCount:", @intCast(count));

    // Hidden rather than destroyed, and written in both directions on every
    // rebuild: `createSpacesSidebar()` with no options posts an empty list, so
    // create-empty-then-`setSpaces` is the ordinary flow from JS, and a list
    // that grows back to two has to bring the same control back with it.
    const hidden = @as(c_int, if (space_list.shouldShowSwitcher(count)) 0 else 1);
    _ = macos.msgSend1(control, "setHidden:", hidden);

    for (0..count) |i| {
        const space = self.spaces.at(i) orelse continue;
        const label = macos.createNSString(space.label);
        _ = macos.msgSend2(control, "setLabel:forSegment:", label, @as(c_long, @intCast(i)));
        _ = macos.msgSend2(control, "setWidth:forSegment:", @as(f64, 0), @as(c_long, @intCast(i)));
    }

    if (self.spaces.active) |active| {
        _ = macos.msgSend1(control, "setSelectedSegment:", @as(c_long, @intCast(active)));
    }

    applyTint(self);
    _ = macos.msgSend0(control, "sizeToFit");
}

/// Paint the control with the active space's accent, so the chrome agrees with
/// the pane instead of staying a neutral grey while the sidebar is deep blue.
fn applyTint(self: *SpaceSwitcher) void {
    const control = self.control;
    if (control == null) return;

    const space = self.spaces.activeSpace() orelse return;
    const tint = space.tint orelse return;
    const color = macos.createColorFromHex(tint) orelse return;

    // 10.14+. Older systems simply keep the default bezel rather than crashing
    // on an unrecognised selector.
    const responds = macos.msgSend1(control, "respondsToSelector:", macos.sel("setSelectedSegmentBezelColor:"));
    if (responds != null)
        _ = macos.msgSend1(control, "setSelectedSegmentBezelColor:", color);
}

fn attach(self: *SpaceSwitcher, window: objc.id) void {
    if (window == null) return;

    ensureSwitcherClass();
    if (switcherClass == null) return;

    const contentView = macos.msgSend0(window, "contentView");
    const themeFrame = if (contentView != null) macos.msgSend0(contentView, "superview") else null;
    if (themeFrame == null) {
        if (comptime std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug"))
            std.debug.print("[SpaceSwitcher] No theme frame; switcher list is live but has no control\n", .{});
        return;
    }

    // The responder exists only to be a target — a zero-sized view in the
    // titlebar, exactly like the web-chrome controls next to it.
    const responder_alloc = macos.msgSend0(switcherClass, "alloc");
    const responder = macos.msgSend1Rect(responder_alloc, "initWithFrame:", .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 0, .height = 0 },
    });
    _ = macos.msgSend1(themeFrame, "addSubview:", responder);
    self.responder = responder;
    // The theme frame now owns the responder. Keep only the borrowed pointer
    // used for target/action teardown; otherwise every re-create leaks the
    // creator's alloc/init retain after removeFromSuperview drops the parent.
    macos.msgSendVoid0(responder, "release");

    const NSValue = macos.getClass("NSValue");
    const pointer_value = macos.msgSend1(
        NSValue,
        "valueWithPointer:",
        @as(?*anyopaque, @ptrCast(self)),
    );
    objc.objc_setAssociatedObject(
        responder,
        &switcher_association_key,
        pointer_value,
        objc.OBJC_ASSOCIATION_RETAIN,
    );

    const NSSegmentedControl = macos.getClass("NSSegmentedControl");
    const control_alloc = macos.msgSend0(NSSegmentedControl, "alloc");

    // Sit clear of the traffic lights, centred in the titlebar band.
    //
    // Only the button's x is read from its frame. `standardWindowButton:`
    // answers in NSTitlebarView coordinates; that view spans the window at
    // x = 0, so its x is the theme frame's, but its y is not — see
    // `macos.titlebarControlY`, which takes the band instead.
    const closeButton = macos.msgSend1(window, "standardWindowButton:", @as(c_ulong, 0));
    const closeX: f64 = if (closeButton != null)
        macos.msgSendRect(closeButton, "frame").origin.x
    else
        20.0;
    const height: f64 = 24.0;
    const y = macos.titlebarControlY(window, themeFrame, height);

    const control = macos.msgSend1Rect(control_alloc, "initWithFrame:", .{
        .origin = .{ .x = closeX + 200.0, .y = y },
        .size = .{ .width = 240.0, .height = height },
    });

    _ = macos.msgSend1(control, "setSegmentStyle:", @as(c_long, 8)); // NSSegmentedControlStyleSeparated
    _ = macos.msgSend1(control, "setTrackingMode:", @as(c_long, 0)); // SelectOne
    _ = macos.msgSend1(control, "setTarget:", responder);
    _ = macos.msgSend1(control, "setAction:", macos.sel("craftSpaceSelected:"));
    macos.msgSendVoid1(control, "setAutoresizingMask:", macos.titlebar_control_autoresizing_mask);
    _ = macos.msgSend1(themeFrame, "addSubview:", control);

    self.control = control;
    // As above, transfer the creator retain to the titlebar hierarchy. The
    // stored pointer remains valid until deinit removes it from that parent.
    macos.msgSendVoid0(control, "release");
    rebuildSegments(self);
}

// =============================================================================
// Public surface, called from the native-UI bridge
// =============================================================================

pub fn create(allocator: std.mem.Allocator, window: objc.id, webview: objc.id, id: []const u8, spaces: []const Space, active_id: ?[]const u8) !*SpaceSwitcher {
    const self = try allocator.create(SpaceSwitcher);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .spaces = space_list.SpaceList.init(allocator),
        .id = try allocator.dupe(u8, id),
        .webview = webview,
    };
    errdefer allocator.free(self.id);
    errdefer self.spaces.deinit();

    for (spaces) |space| try self.spaces.append(space);
    if (active_id) |wanted| _ = self.spaces.setActiveId(wanted);

    attach(self, window);
    return self;
}

pub fn setSpaces(self: *SpaceSwitcher, spaces: []const Space) !void {
    try self.spaces.replace(spaces);
    rebuildSegments(self);
}

pub fn setActiveSpace(self: *SpaceSwitcher, id: []const u8) void {
    if (!self.spaces.setActiveId(id)) return;
    if (self.control != null and self.spaces.active != null)
        _ = macos.msgSend1(self.control, "setSelectedSegment:", @as(c_long, @intCast(self.spaces.active.?)));
    applyTint(self);
}

/// Whether a switcher is currently installed. Used by the bridge to answer
/// `destroyComponent` for an id it may or may not own.
pub fn isActive(self: *const SpaceSwitcher, id: []const u8) bool {
    return std.mem.eql(u8, self.id, id);
}
