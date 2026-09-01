//! The `mobile` namespace's PDF viewer: `openPDF` and `closePDF`.
//!
//! ## They migrate together, or not at all
//!
//! `openPDF` is gated on `config.enablePDFViewer`; `closePDF` is ungated. That
//! asymmetry is a trap, because the two share one piece of state: Swift stores
//! the presented controller in `pdfViewController` and `closePDF` is nothing
//! but `pdfViewController?.dismiss()`. Migrating only the gated one would put
//! the controller in Zig and the dismiss in Swift, where the field is nil — so
//! `closePDF` would resolve `true` having dismissed nothing, and the user would
//! be left holding a full-screen PDF with no way out but the close button.
//!
//! This is the same shape as the recorded blocker in
//! `bridge_mobile_locrecording.zig`, and the opposite outcome: there the state
//! is re-adopted by Swift on every launch and Zig cannot take it, here it is
//! in-memory for one presentation and both halves move at once.
//!
//! ## Presenting
//!
//! Through `bridge_mobile_system.uikit.topmostViewController()`, not Swift's
//! `windows.first?.rootViewController`. The difference is the walk up
//! `presentedViewController`: presenting on a controller that is already
//! presenting logs "which is already presenting" and does nothing, which in
//! Swift's version means the reply below is sent for a PDF that never
//! appeared. Same reasoning as `bridge_mobile_contactpicker.zig`.
//!
//! ## The close button is not decoration
//!
//! `modalPresentationStyle = .fullScreen` disables the swipe-to-dismiss that a
//! sheet would have, so the button is the only way a user can leave the viewer
//! without the page calling `closePDF`. Dropping it — the tempting
//! simplification, since it costs a runtime class, four constraints and an SF
//! Symbol — would trap the user in the document.
//!
//! Its target is a class built by `ios_delegate.defineClass`, and the instance
//! is retained for as long as the controller is: `addTarget:action:forControlEvents:`
//! does **not** retain its target, so a released one is a message to freed
//! memory on the first tap rather than a leak.
//!
//! ## What is carried across exactly
//!
//!  - **`openPDF` resolves `{"opened":true,"pageCount":N}`** and `closePDF`
//!    the bare JSON `true`.
//!  - **`closePDF` succeeds when nothing is open.** Swift's
//!    `pdfViewController?.dismiss()` is a no-op on nil and still resolves, so
//!    a page that closes twice gets two successes rather than an error.
//!  - **The `data:` handling, including its sharp edge.** Swift tests
//!    `hasPrefix("data:")` but then strips with
//!    `replacingOccurrences(of: "data:application/pdf;base64,", with: "")` —
//!    every occurrence, anywhere in the string, not the prefix. So a source of
//!    `data:image/png;base64,…` takes the base64 branch, has nothing stripped,
//!    fails to decode and is refused as an unreadable PDF. That is preserved:
//!    the alternative is accepting sources the Swift arm rejects, which is a
//!    behaviour change dressed as a bug fix.
//!  - **`page` is 1-based-ish, and wrong.** Swift does
//!    `if page > 0, let targetPage = document.page(at: page)`, and
//!    `page(at:)` is 0-based — so `page: 1` shows the *second* page and there
//!    is no way to ask for the first that is not also "no navigation". Copied
//!    exactly, because a page passing 1 today lands on sheet two and a
//!    "corrected" version would silently move it.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_delegate = @import("ios_delegate.zig");
const bridge_mobile_system = @import("bridge_mobile_system.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;
const Id = ?*anyopaque;
const is_darwin = builtin.target.os.tag.isDarwin();

pub const A = struct {
    pub const open_pdf = "openPDF";
    pub const close_pdf = "closePDF";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.open_pdf, .reply = .result },
    .{ .name = A.close_pdf, .reply = .result },
};

/// The exact prefix Swift strips, and only this one.
const data_url_prefix = "data:application/pdf;base64,";

/// `kPDFDisplaySinglePageContinuous`.
const display_mode_single_page_continuous: c_long = 1;
/// `kPDFDisplayDirectionVertical`.
const display_direction_vertical: c_long = 0;
/// `UIModalPresentationFullScreen`.
const modal_presentation_full_screen: c_long = 0;
/// `UIButtonTypeSystem`.
const button_type_system: c_long = 1;
/// `UIControlEventTouchUpInside`.
const control_event_touch_up_inside: c_ulong = 1 << 6;
/// `UIControlStateNormal`.
const control_state_normal: c_ulong = 0;

const close_button_inset: f64 = 16;
const close_button_size: f64 = 32;

/// `closePDF`'s reply: the bare JSON `true`, per `.fragmentsAllowed`.
const close_reply = "true";

/// The presented controller and the object its close button targets.
///
/// Both retained. `addTarget:action:forControlEvents:` holds its target
/// weakly, so the closer has to outlive the presentation on its own; and the
/// controller reference is what `closePDF` dismisses.
var presented_controller: Id = null;
var close_target: Id = null;

pub const PdfBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.open_pdf)) {
            try self.openPdf(data);
        } else if (std.mem.eql(u8, action, A.close_pdf)) {
            try self.closePdf();
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// Load the document, present it, and answer — all synchronously.
    ///
    /// Swift wraps the body in `DispatchQueue.main.async`, but
    /// `didReceiveScriptMessage` already runs on the main thread and
    /// `present:animated:` returns immediately, so there is no completion to
    /// wait for and no `ios_async` ticket. The reply goes out inside the
    /// dispatch frame that holds this call's id.
    fn openPdf(self: *Self, data: []const u8) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        const request = try readRequest(self.allocator, data);
        defer self.allocator.free(request.source);

        const document = try loadDocument(self.allocator, request.source);
        defer release(document);

        const host = bridge_mobile_system.uikit.topmostViewController() catch |err| {
            std.log.warn("openPDF: nowhere to present from: {}", .{err});
            return BridgeError.NativeCallFailed;
        };

        const view = try buildPdfView(document, request.page);
        const controller = try buildViewController(view);

        // Replace rather than refuse, matching Swift: a second open while one
        // is up stacks on top of the first, and the reference kept here is the
        // newer one. Releasing the older reference is safe because UIKit
        // retains anything it is presenting.
        release(presented_controller);
        presented_controller = controller;

        const sel_present = objc.sel_registerName("presentViewController:animated:completion:") orelse
            return BridgeError.NativeCallFailed;
        const PresentFn = *const fn (Id, objc.SEL, Id, bool, Id) callconv(.c) void;
        const present: PresentFn = @ptrCast(&objc.objc_msgSend);
        present(host, sel_present, controller, true, null);

        const count = pageCount(document);
        var buf: [64]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"opened\":true,\"pageCount\":{d}}}", .{count});
        bridge_error.sendResultToJS(self.allocator, A.open_pdf, json);
    }

    /// Dismiss whatever is up and say so.
    ///
    /// Resolves even when nothing was open, because Swift's optional-chained
    /// `dismiss()` is a no-op on nil and still calls `resolveCallback`. A page
    /// that closes twice gets two successes.
    fn closePdf(self: *Self) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;
        dismissPresented();
        bridge_error.sendResultToJS(self.allocator, A.close_pdf, close_reply);
    }
};

const Request = struct {
    /// Owned.
    source: []u8,
    page: i64,
};

/// `source` is required; `page` defaults to 0.
///
/// Swift's arm is `if config.enablePDFViewer, let source = body["source"] as?
/// String` with no `else`, so a missing source settles nothing and the page
/// waits out its timeout. Not carried across.
fn readRequest(allocator: std.mem.Allocator, data: []const u8) !Request {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return BridgeError.InvalidJSON,
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |o| o,
        else => return BridgeError.InvalidJSON,
    };

    const source_value = object.get("source") orelse return BridgeError.MissingData;
    const source_text = switch (source_value) {
        .string => |s| s,
        else => return BridgeError.InvalidParameter,
    };
    if (source_text.len == 0) return BridgeError.InvalidParameter;

    // `body["page"] as? Int ?? 0`: absent defaults, and a non-integer is
    // refused here rather than silently rewritten to 0.
    const page: i64 = switch (object.get("page") orelse std.json.Value{ .integer = 0 }) {
        .integer => |i| i,
        .null => 0,
        else => return BridgeError.InvalidParameter,
    };

    return .{
        .source = allocator.dupe(u8, source_text) catch return BridgeError.AllocationFailed,
        .page = page,
    };
}

/// A `PDFDocument`, +1, from either a `data:` source or a URL.
fn loadDocument(allocator: std.mem.Allocator, source: []const u8) !Id {
    const PDFDocument = objc.objc_getClass("PDFDocument") orelse {
        std.log.warn("openPDF: PDFDocument is not in this process; the app does not link PDFKit", .{});
        return BridgeError.PlatformNotSupported;
    };
    const sel_alloc = objc.sel_registerName("alloc") orelse return BridgeError.NativeCallFailed;
    const allocated = objc.msgSendId(PDFDocument, sel_alloc) orelse return BridgeError.NativeCallFailed;

    const document = if (std.mem.startsWith(u8, source, "data:"))
        try documentFromBase64(allocator, allocated, source)
    else
        try documentFromUrl(allocator, allocated, source);

    return document orelse {
        std.log.warn("openPDF: the source did not load as a PDF", .{});
        return BridgeError.InvalidParameter;
    };
}

fn documentFromBase64(allocator: std.mem.Allocator, allocated: Id, source: []const u8) !Id {
    const stripped = try stripDataPrefix(allocator, source);
    defer allocator.free(stripped);

    const ns_base64 = objc.createNSString(stripped, allocator) catch return BridgeError.AllocationFailed;
    const NSData = objc.objc_getClass("NSData") orelse return BridgeError.NativeCallFailed;
    const sel_alloc = objc.sel_registerName("alloc") orelse return BridgeError.NativeCallFailed;
    const sel_init_b64 = objc.sel_registerName("initWithBase64EncodedString:options:") orelse
        return BridgeError.NativeCallFailed;
    const data_alloc = objc.msgSendId(NSData, sel_alloc) orelse return BridgeError.NativeCallFailed;

    const InitB64Fn = *const fn (Id, objc.SEL, Id, c_ulong) callconv(.c) Id;
    const initB64: InitB64Fn = @ptrCast(&objc.objc_msgSend);
    const ns_data = initB64(data_alloc, sel_init_b64, ns_base64, 0) orelse return null;
    defer release(ns_data);

    const sel_init = objc.sel_registerName("initWithData:") orelse return BridgeError.NativeCallFailed;
    return objc.msgSendId1(allocated, sel_init, ns_data);
}

fn documentFromUrl(allocator: std.mem.Allocator, allocated: Id, source: []const u8) !Id {
    const url = objc.createNSURL(source, allocator) catch return BridgeError.AllocationFailed;
    if (url == null) return null;
    const sel_init = objc.sel_registerName("initWithURL:") orelse return BridgeError.NativeCallFailed;
    return objc.msgSendId1(allocated, sel_init, url);
}

/// Swift's `replacingOccurrences(of: data_url_prefix, with: "")`, faithfully.
///
/// Every occurrence, not the prefix — see the module comment. A source that
/// begins `data:` but carries a different media type keeps its whole header
/// and then fails to decode, which is the refusal Swift produces.
fn stripDataPrefix(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var rest = source;
    while (std.mem.indexOf(u8, rest, data_url_prefix)) |at| {
        try out.appendSlice(allocator, rest[0..at]);
        rest = rest[at + data_url_prefix.len ..];
    }
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

fn pageCount(document: Id) u64 {
    const sel = objc.sel_registerName("pageCount") orelse return 0;
    const CountFn = *const fn (Id, objc.SEL) callconv(.c) c_ulong;
    const countFn: CountFn = @ptrCast(&objc.objc_msgSend);
    return @intCast(countFn(document, sel));
}

/// A configured `PDFView`, +1.
fn buildPdfView(document: Id, page: i64) !Id {
    const PDFView = objc.objc_getClass("PDFView") orelse return BridgeError.PlatformNotSupported;
    const sel_alloc = objc.sel_registerName("alloc") orelse return BridgeError.NativeCallFailed;
    const sel_init_frame = objc.sel_registerName("initWithFrame:") orelse
        return BridgeError.NativeCallFailed;

    const allocated = objc.msgSendId(PDFView, sel_alloc) orelse return BridgeError.NativeCallFailed;
    const InitFrameFn = *const fn (Id, objc.SEL, objc.CGRect) callconv(.c) Id;
    const initFrame: InitFrameFn = @ptrCast(&objc.objc_msgSend);
    const zero = objc.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const view = initFrame(allocated, sel_init_frame, zero) orelse return BridgeError.NativeCallFailed;

    try setObject(view, "setDocument:", document);
    try setBool(view, "setAutoScales:", true);
    try setLong(view, "setDisplayMode:", display_mode_single_page_continuous);
    try setLong(view, "setDisplayDirection:", display_direction_vertical);

    // `page(at:)` is 0-based and Swift guards on `page > 0`, so 1 shows the
    // second sheet. Copied rather than corrected — see the module comment.
    if (page > 0) {
        const sel_page_at = objc.sel_registerName("pageAtIndex:") orelse
            return BridgeError.NativeCallFailed;
        const PageAtFn = *const fn (Id, objc.SEL, c_ulong) callconv(.c) Id;
        const pageAt: PageAtFn = @ptrCast(&objc.objc_msgSend);
        if (pageAt(document, sel_page_at, @intCast(page))) |target| {
            try setObject(view, "goToPage:", target);
        }
    }

    return view;
}

/// A full-screen `UIViewController` hosting `view`, with a close button, +1.
fn buildViewController(view: Id) !Id {
    const UIViewController = objc.objc_getClass("UIViewController") orelse
        return BridgeError.PlatformNotSupported;
    const controller = objc.allocInit(UIViewController) catch return BridgeError.NativeCallFailed;
    errdefer release(controller);

    try setObject(controller, "setView:", view);
    try setLong(controller, "setModalPresentationStyle:", modal_presentation_full_screen);

    if (systemBackgroundColor()) |colour| try setObject(view, "setBackgroundColor:", colour);

    try addCloseButton(view);
    return controller;
}

fn systemBackgroundColor() ?Id {
    const UIColor = objc.objc_getClass("UIColor") orelse return null;
    const sel = objc.sel_registerName("systemBackgroundColor") orelse return null;
    return objc.msgSendId(UIColor, sel);
}

/// The only way out of a full-screen presentation that has no swipe-to-dismiss.
fn addCloseButton(parent: Id) !void {
    const UIButton = objc.objc_getClass("UIButton") orelse return BridgeError.PlatformNotSupported;
    const sel_with_type = objc.sel_registerName("buttonWithType:") orelse
        return BridgeError.NativeCallFailed;
    const ButtonFn = *const fn (objc.Class, objc.SEL, c_long) callconv(.c) Id;
    const buttonWithType: ButtonFn = @ptrCast(&objc.objc_msgSend);
    const button = buttonWithType(UIButton, sel_with_type, button_type_system) orelse
        return BridgeError.NativeCallFailed;

    if (systemImage("xmark.circle.fill")) |image| {
        const sel_set_image = objc.sel_registerName("setImage:forState:") orelse
            return BridgeError.NativeCallFailed;
        const SetImageFn = *const fn (Id, objc.SEL, Id, c_ulong) callconv(.c) void;
        const setImage: SetImageFn = @ptrCast(&objc.objc_msgSend);
        setImage(button, sel_set_image, image, control_state_normal);
    }

    if (systemGrayColor()) |colour| try setObject(button, "setTintColor:", colour);

    const target = try closeTarget();
    const sel_add_target = objc.sel_registerName("addTarget:action:forControlEvents:") orelse
        return BridgeError.NativeCallFailed;
    const sel_action = objc.sel_registerName(close_selector) orelse
        return BridgeError.NativeCallFailed;
    const AddTargetFn = *const fn (Id, objc.SEL, Id, objc.SEL, c_ulong) callconv(.c) void;
    const addTarget: AddTargetFn = @ptrCast(&objc.objc_msgSend);
    addTarget(button, sel_add_target, target, sel_action, control_event_touch_up_inside);

    try setBool(button, "setTranslatesAutoresizingMaskIntoConstraints:", false);
    try setObject(parent, "addSubview:", button);
    try pinCloseButton(parent, button);
}

fn systemImage(comptime name: [*:0]const u8) ?Id {
    const UIImage = objc.objc_getClass("UIImage") orelse return null;
    const sel = objc.sel_registerName("systemImageNamed:") orelse return null;
    const NSString = objc.objc_getClass("NSString") orelse return null;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse return null;
    const ns_name = objc.msgSendId1(NSString, sel_string, name) orelse return null;
    return objc.msgSendId1(UIImage, sel, ns_name);
}

fn systemGrayColor() ?Id {
    const UIColor = objc.objc_getClass("UIColor") orelse return null;
    const sel = objc.sel_registerName("systemGrayColor") orelse return null;
    return objc.msgSendId(UIColor, sel);
}

/// Swift's four constraints: inset from the safe area's top, inset from the
/// trailing edge, and a fixed 32-point square.
fn pinCloseButton(parent: Id, button: Id) !void {
    const sel_safe_area = objc.sel_registerName("safeAreaLayoutGuide") orelse
        return BridgeError.NativeCallFailed;
    const safe_area = objc.msgSendId(parent, sel_safe_area) orelse
        return BridgeError.NativeCallFailed;

    const top = try constraintToAnchor(button, "topAnchor", safe_area, "topAnchor", close_button_inset);
    const trailing = try constraintToAnchor(button, "trailingAnchor", parent, "trailingAnchor", -close_button_inset);
    const width = try constraintToConstant(button, "widthAnchor", close_button_size);
    const height = try constraintToConstant(button, "heightAnchor", close_button_size);

    var items = [_]Id{ top, trailing, width, height };
    const NSArray = objc.objc_getClass("NSArray") orelse return BridgeError.NativeCallFailed;
    const sel_with_objects = objc.sel_registerName("arrayWithObjects:count:") orelse
        return BridgeError.NativeCallFailed;
    const ArrayFn = *const fn (objc.Class, objc.SEL, [*]Id, c_ulong) callconv(.c) Id;
    const arrayWith: ArrayFn = @ptrCast(&objc.objc_msgSend);
    const array = arrayWith(NSArray, sel_with_objects, &items, items.len) orelse
        return BridgeError.NativeCallFailed;

    const NSLayoutConstraint = objc.objc_getClass("NSLayoutConstraint") orelse
        return BridgeError.NativeCallFailed;
    const sel_activate = objc.sel_registerName("activateConstraints:") orelse
        return BridgeError.NativeCallFailed;
    objc.msgSendVoid1(NSLayoutConstraint, sel_activate, array);
}

fn constraintToAnchor(
    view: Id,
    comptime anchor: [*:0]const u8,
    other: Id,
    comptime other_anchor: [*:0]const u8,
    constant: f64,
) !Id {
    const a = try anchorOf(view, anchor);
    const b = try anchorOf(other, other_anchor);
    const sel = objc.sel_registerName("constraintEqualToAnchor:constant:") orelse
        return BridgeError.NativeCallFailed;
    const Fn = *const fn (Id, objc.SEL, Id, f64) callconv(.c) Id;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(a, sel, b, constant) orelse BridgeError.NativeCallFailed;
}

fn constraintToConstant(view: Id, comptime anchor: [*:0]const u8, constant: f64) !Id {
    const a = try anchorOf(view, anchor);
    const sel = objc.sel_registerName("constraintEqualToConstant:") orelse
        return BridgeError.NativeCallFailed;
    const Fn = *const fn (Id, objc.SEL, f64) callconv(.c) Id;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(a, sel, constant) orelse BridgeError.NativeCallFailed;
}

fn anchorOf(view: Id, comptime anchor: [*:0]const u8) !Id {
    const sel = objc.sel_registerName(anchor) orelse return BridgeError.NativeCallFailed;
    return objc.msgSendId(view, sel) orelse BridgeError.NativeCallFailed;
}

// ---------------------------------------------------------------------------
// The close button's target
// ---------------------------------------------------------------------------

const close_class_name = "CraftPdfCloser";
/// One argument, so the existing `enc.void_one_object` covers it: UIKit passes
/// the sender to a one-argument action. A zero-argument action would need an
/// encoding `ios_delegate` does not carry, for no gain.
const close_selector = "craftDismissPDF:";

export fn craftPdfCloserDismiss(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    dismissPresented();
}

/// The retained instance the button targets, built once.
fn closeTarget() !Id {
    if (close_target) |existing| return existing;

    const class = ios_delegate.defineClass(close_class_name, "NSObject", &.{
        .{
            .selector = close_selector,
            .imp = @ptrCast(&craftPdfCloserDismiss),
            .types = ios_delegate.enc.void_one_object,
        },
    }) catch |err| {
        std.log.warn("openPDF: could not build the close button's target: {}", .{err});
        return BridgeError.NativeCallFailed;
    };

    // +1 and never released: `addTarget:` does not retain, and one instance
    // serves every presentation for the life of the process.
    close_target = ios_delegate.instantiate(class) catch |err| {
        std.log.warn("openPDF: could not instantiate the close button's target: {}", .{err});
        return BridgeError.NativeCallFailed;
    };
    return close_target;
}

/// Dismiss whatever this module has presented, from either route.
///
/// Shared by `closePDF` and the button, and idempotent: Swift's
/// `pdfViewController?.dismiss(); pdfViewController = nil` is the same pair,
/// and clearing first is what stops a second tap dismissing a controller that
/// has already gone.
fn dismissPresented() void {
    const controller = presented_controller orelse return;
    presented_controller = null;

    const sel = objc.sel_registerName("dismissViewControllerAnimated:completion:") orelse return;
    const DismissFn = *const fn (Id, objc.SEL, bool, Id) callconv(.c) void;
    const dismiss: DismissFn = @ptrCast(&objc.objc_msgSend);
    dismiss(controller, sel, true, null);

    release(controller);
}

fn setObject(target: Id, comptime selector: [*:0]const u8, value: Id) !void {
    const sel = objc.sel_registerName(selector) orelse return BridgeError.NativeCallFailed;
    objc.msgSendVoid1(target, sel, value);
}

fn setBool(target: Id, comptime selector: [*:0]const u8, value: bool) !void {
    const sel = objc.sel_registerName(selector) orelse return BridgeError.NativeCallFailed;
    const Fn = *const fn (Id, objc.SEL, bool) callconv(.c) void;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    f(target, sel, value);
}

fn setLong(target: Id, comptime selector: [*:0]const u8, value: c_long) !void {
    const sel = objc.sel_registerName(selector) orelse return BridgeError.NativeCallFailed;
    const Fn = *const fn (Id, objc.SEL, c_long) callconv(.c) void;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    f(target, sel, value);
}

fn release(object: Id) void {
    const target = object orelse return;
    const sel = objc.sel_registerName("release") orelse return;
    objc.msgSend(target, sel);
}

const testing = std.testing;

test "the action names match the Swift case labels exactly" {
    try testing.expectEqualStrings("openPDF", A.open_pdf);
    try testing.expectEqualStrings("closePDF", A.close_pdf);
}

test "closePDF resolves the bare JSON true" {
    try testing.expectEqualStrings("true", close_reply);
}

test "the UIKit and PDFKit constants are the ones Swift names" {
    // Each of these is an integer passed to a setter that accepts any
    // integer, so a wrong value configures something plausible and different:
    // display mode 0 is single-page rather than continuous, and a modal
    // presentation style of 2 is a sheet that *can* be swiped away, which
    // would quietly make the close button optional.
    try testing.expectEqual(@as(c_long, 1), display_mode_single_page_continuous);
    try testing.expectEqual(@as(c_long, 0), display_direction_vertical);
    try testing.expectEqual(@as(c_long, 0), modal_presentation_full_screen);
    try testing.expectEqual(@as(c_long, 1), button_type_system);
    try testing.expectEqual(@as(c_ulong, 64), control_event_touch_up_inside);
}

test "the data prefix is stripped everywhere it appears, as Swift strips it" {
    // `replacingOccurrences(of:with:)` is not `hasPrefix`. Copying the loose
    // behaviour matters because the *observable* consequence is which sources
    // are refused, and a stricter prefix-only strip would accept a source with
    // a repeated header that Swift turns into garbage and rejects.
    const one = try stripDataPrefix(testing.allocator, data_url_prefix ++ "QUJD");
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("QUJD", one);

    const twice = try stripDataPrefix(testing.allocator, data_url_prefix ++ "AA" ++ data_url_prefix ++ "BB");
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings("AABB", twice);

    // The sharp edge: `data:` prefix, different media type. Nothing is
    // stripped, so the header stays in the base64 and the decode fails —
    // which is exactly the refusal Swift produces.
    const wrong_type = try stripDataPrefix(testing.allocator, "data:image/png;base64,QUJD");
    defer testing.allocator.free(wrong_type);
    try testing.expectEqualStrings("data:image/png;base64,QUJD", wrong_type);

    const untouched = try stripDataPrefix(testing.allocator, "https://example.com/a.pdf");
    defer testing.allocator.free(untouched);
    try testing.expectEqualStrings("https://example.com/a.pdf", untouched);
}

test "source is required and page defaults to zero" {
    // Swift's arm has no else, so a missing source settles nothing at all.
    const ok = try readRequest(testing.allocator, "{\"source\":\"https://a/b.pdf\"}");
    testing.allocator.free(ok.source);
    try testing.expectEqual(@as(i64, 0), ok.page);

    const paged = try readRequest(testing.allocator, "{\"source\":\"x\",\"page\":3}");
    testing.allocator.free(paged.source);
    try testing.expectEqual(@as(i64, 3), paged.page);

    try testing.expectError(BridgeError.MissingData, readRequest(testing.allocator, "{}"));
    try testing.expectError(
        BridgeError.InvalidParameter,
        readRequest(testing.allocator, "{\"source\":\"\"}"),
    );
    try testing.expectError(
        BridgeError.InvalidParameter,
        readRequest(testing.allocator, "{\"source\":5}"),
    );
    // A non-integer page is refused rather than rewritten to 0, which is where
    // this diverges from `as? Int ?? 0` silently substituting.
    try testing.expectError(
        BridgeError.InvalidParameter,
        readRequest(testing.allocator, "{\"source\":\"x\",\"page\":\"2\"}"),
    );
    try testing.expectError(BridgeError.InvalidJSON, readRequest(testing.allocator, "[]"));
}

test "every declared action dispatches to something" {
    var bridge = PdfBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            continue;
        };
    }
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("getDeviceInfo", "{}"));
}

test "dismissing when nothing is presented is a no-op" {
    // Both `closePDF` and the close button land here, and Swift's
    // `pdfViewController?.dismiss()` is a no-op on nil. Clearing before
    // dismissing is what stops a second tap messaging a controller that has
    // already gone.
    presented_controller = null;
    dismissPresented();
    dismissPresented();
    try testing.expect(presented_controller == null);
}
