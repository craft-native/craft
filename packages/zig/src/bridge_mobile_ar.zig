//! The five `startAR` / `stopAR` / `placeARObject` / `removeARObject` /
//! `getARPlanes` actions of the `mobile` namespace.
//!
//! This is the last group whose deferral reason was an effort judgement rather
//! than a wall — "SceneKit node-graph glue; miserable and low-value through
//! `objc_msgSend`" — so it is worth being precise about what was actually hard,
//! because it was not the node graph.
//!
//! ## Three struct returns, and why they are the whole risk
//!
//! Every other migrated module passes and returns pointers and integers. This
//! one passes and returns *structs by value*, in floating-point registers,
//! three times:
//!
//!  - `CGRect` (`UIScreen.main.bounds`, `-initWithFrame:`) — four `CGFloat`s,
//!    a homogeneous float aggregate returned in `v0`-`v3`.
//!  - `SCNVector3` (`SCNNode.position`) — three components in `v0`-`v2`.
//!  - `simd_float3` (`ARPlaneAnchor.center` / `.extent`) — sixteen bytes in a
//!    *single* 128-bit vector register, which is a different rule from the
//!    other two and the one most likely to be got wrong.
//!
//! Getting any of them wrong does not crash. It yields plausible coordinates
//! that are not the ones ARKit measured — a wrong answer delivered as a right
//! one, which is the failure this migration exists to remove. So the three are
//! not asserted from the headers and hoped for; they are exercised on a host,
//! against real SceneKit objects, in the tests at the bottom of this file.
//!
//! **`SCNVector3` is not the same type on the two platforms.** macOS declares
//! it as three `CGFloat`s and iOS as three `float`s
//! (`SceneKitTypes.h` in each SDK, checked in both). The alias below follows
//! the target; a host test therefore verifies the *mechanism* — a
//! three-element homogeneous aggregate through `objc_msgSend` — at double
//! width, not the exact iOS layout. That is a real limit on what the tests
//! below prove, and it is why the alias is derived from the target rather than
//! written out once.
//!
//! ## What cannot be verified here at all
//!
//! ARKit is device-only: `ARWorldTrackingConfiguration.isSupported` is false in
//! the simulator, so `startAR` refuses there and every line past the guard is
//! unreachable without hardware. The tests below cover the argument parsing,
//! the reply shapes, the plane JSON and the three ABI mechanisms; they do not
//! cover a running AR session, and no test in this repository can.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_events = @import("ios_events.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();
const is_ios = builtin.target.os.tag == .ios;

/// The same type as `objc.id` — `?*anyopaque` — spelled locally, so a
/// `callconv(.c)` signature stays legal off Darwin.
const Id = ?*anyopaque;

// =============================================================================
// The three struct types that cross the ABI boundary.
// =============================================================================

/// `CGFloat`: 64-bit on every target this ships to (arm64 and x86_64 alike).
const CGFloat = f64;

const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
const CGSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };

/// `SCNVector3`'s component type, which the two SDKs disagree about.
///
/// `SceneKitTypes.h` declares `CGFloat x, y, z` on macOS and `float x, y, z`
/// on iOS. Both are homogeneous three-element aggregates, so the calling
/// convention is the same shape at two widths — but a single hardcoded width
/// would silently misread every coordinate on one of the two.
const ScnFloat = if (is_ios) f32 else CGFloat;

const SCNVector3 = extern struct { x: ScnFloat = 0, y: ScnFloat = 0, z: ScnFloat = 0 };

/// `simd_float3`: three floats in sixteen bytes, returned in one 128-bit
/// vector register rather than as a float aggregate.
///
/// `@Vector(4, f32)` rather than a four-field struct on purpose. An
/// `extern struct { f32, f32, f32, f32 }` is a homogeneous aggregate and comes
/// back in `v0`-`v3`; `simd_float3` comes back in `v0` alone. The two disagree
/// about everything but `x`, which is exactly the kind of bug that reads as
/// "the y coordinate is always zero" rather than as a crash.
const SimdFloat3 = @Vector(4, f32);

fn simdX(v: SimdFloat3) f32 {
    return v[0];
}
fn simdY(v: SimdFloat3) f32 {
    return v[1];
}
fn simdZ(v: SimdFloat3) f32 {
    return v[2];
}

/// The typed `objc_msgSend` casts for the three struct shapes.
///
/// `objc_msgSend` and not `objc_msgSend_stret` for every one of them: on arm64
/// a homogeneous float aggregate of four or fewer members, and a 16-byte
/// vector, are all returned in registers, and `_stret` does not exist on that
/// architecture at all. This is arm64-only reasoning, which is what both the
/// device and the host run.
fn selector(name: [*:0]const u8) !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    return objc.sel_registerName(name) orelse error.SelectorNotFound;
}

fn msgSendRect(target: Id, sel: Id) CGRect {
    const Fn = *const fn (Id, Id) callconv(.c) CGRect;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(target, sel);
}

fn msgSendIdWithRect(target: Id, sel: Id, rect: CGRect) Id {
    const Fn = *const fn (Id, Id, CGRect) callconv(.c) Id;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(target, sel, rect);
}

fn msgSendVector3(target: Id, sel: Id) SCNVector3 {
    const Fn = *const fn (Id, Id) callconv(.c) SCNVector3;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(target, sel);
}

fn msgSendSetVector3(target: Id, sel: Id, value: SCNVector3) void {
    const Fn = *const fn (Id, Id, SCNVector3) callconv(.c) void;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    f(target, sel, value);
}

fn msgSendSimd3(target: Id, sel: Id) SimdFloat3 {
    const Fn = *const fn (Id, Id) callconv(.c) SimdFloat3;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(target, sel);
}

fn msgSendCGFloat(target: Id, sel: Id) CGFloat {
    const Fn = *const fn (Id, Id) callconv(.c) CGFloat;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(target, sel);
}

// =============================================================================
// The actions.
// =============================================================================

pub const A = struct {
    pub const start_ar = "startAR";
    pub const stop_ar = "stopAR";
    pub const place_ar_object = "placeARObject";
    pub const remove_ar_object = "removeARObject";
    pub const get_ar_planes = "getARPlanes";
};

/// `.result` throughout: each of the five Swift paths ends in exactly one
/// `resolveCallback` or one `rejectCallback`, and each is awaited by the page.
///
/// `.live`, not `.unavailable`: these dispatch and do the thing. A device
/// without world tracking is refused at run time by
/// `ARWorldTrackingConfiguration.isSupported`, which is a fact about the
/// hardware rather than about this build.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.start_ar, .reply = .result },
    .{ .name = A.stop_ar, .reply = .result },
    .{ .name = A.place_ar_object, .reply = .result },
    .{ .name = A.remove_ar_object, .reply = .result },
    .{ .name = A.get_ar_planes, .reply = .result },
};

const Route = enum { start, stop, place, remove, planes };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.start_ar)) return .start;
    if (std.mem.eql(u8, action, A.stop_ar)) return .stop;
    if (std.mem.eql(u8, action, A.place_ar_object)) return .place;
    if (std.mem.eql(u8, action, A.remove_ar_object)) return .remove;
    if (std.mem.eql(u8, action, A.get_ar_planes)) return .planes;
    return null;
}

/// `[.horizontal, .vertical]`. `ARPlaneDetectionHorizontal` is `1 << 0` and
/// `ARPlaneDetectionVertical` is `1 << 1` (`ARPlaneDetectionTypes.h`), read out
/// of the iphoneos SDK rather than guessed.
const ar_plane_detection_horizontal_and_vertical: c_ulong = 3;

/// `AREnvironmentTexturingAutomatic`: the third member of an
/// `NS_ENUM(NSInteger)` that begins at `None` (`ARConfiguration.h`).
const ar_environment_texturing_automatic: c_long = 2;

/// `ARPlaneAnchorAlignmentHorizontal` is 0, `…Vertical` is 1
/// (`ARPlaneAnchor.h`). Swift's ternary is `== .horizontal ? … : …`, so
/// everything that is not 0 reads as vertical — including a value neither
/// constant covers, which is why this is a comparison and not a lookup.
const ar_plane_alignment_horizontal: c_long = 0;

/// `arView.tag = 9999`, which Swift sets under the comment "For removal later"
/// and then never reads — `stopAR` holds the view directly. Carried across
/// anyway: it is visible to anything else walking the view hierarchy, and
/// dropping it would be a silent change to what that sees.
const ar_view_tag: c_long = 9999;

/// `SCNVector3(0, 0, -0.5)`, and the `?? -0.5` in `pos["z"]`.
const default_z: f64 = -0.5;

// =============================================================================
// The session, and the two collections that outlive a dispatch.
//
// Unguarded, as Swift's are. `ios_dispatch` delivers page messages from
// `craftDidReceiveScriptMessage`, a WebKit main-thread callback, and SceneKit
// delivers `renderer:didAdd:` on the main thread as well, so writer and reader
// are the same thread.
// =============================================================================

var ar_view: Id = null;
var ar_session: Id = null;

/// `arObjects: [String: SCNNode]`. Keys owned by the map, values retained.
var ar_objects: std.StringHashMapUnmanaged(Id) = .empty;

/// `detectedPlanes: [UUID: ARPlaneAnchor]`, keyed by `UUIDString`.
///
/// The anchors are stored retained and read at `getARPlanes` time rather than
/// flattened to numbers when they arrive, because that is what Swift does: its
/// dictionary holds the anchor objects, and `getARPlanes` reads `.center` and
/// `.extent` off them at the moment it is asked. Flattening on arrival would
/// answer with a plane's first measurement forever.
var ar_planes: std.StringHashMapUnmanaged(Id) = .empty;

/// Module-level collections outlive every dispatch frame, so they cannot borrow
/// a bridge's allocator.
const ar_allocator = std.heap.c_allocator;

// =============================================================================
// Small Objective-C helpers.
// =============================================================================

fn retain(object: Id) void {
    if (!is_darwin) return;
    const sel = objc.sel_registerName("retain") orelse return;
    _ = objc.msgSendId(object, sel);
}

fn release(object: Id) void {
    if (!is_darwin) return;
    const sel = objc.sel_registerName("release") orelse return;
    objc.msgSend(object, sel);
}

/// An autoreleased `NSString` for a Zig slice.
fn makeNSString(text: []const u8) ?Id {
    if (!is_darwin) return null;

    var buf: [4096]u8 = undefined;
    if (text.len >= buf.len) return null;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;

    const NSString = objc.objc_getClass("NSString") orelse return null;
    const sel = objc.sel_registerName("stringWithUTF8String:") orelse return null;
    return objc.msgSendId1(NSString, sel, @as([*:0]const u8, @ptrCast(&buf)));
}

/// An owned copy of a zero-argument `NSString`-returning property.
fn copyNSStringProperty(allocator: std.mem.Allocator, object: Id, comptime name: [*:0]const u8) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const sel = objc.sel_registerName(name) orelse return error.SelectorNotFound;
    const value = objc.msgSendId(object, sel) orelse return error.NotFound;
    const utf8 = objc.getNSStringUTF8(value) orelse return error.NotFound;
    return allocator.dupe(u8, std.mem.span(utf8));
}

/// `UUID().uuidString`, through `NSUUID`.
fn newObjectId(allocator: std.mem.Allocator) ![]u8 {
    if (!is_darwin) return error.UnsupportedPlatform;

    const NSUUID = objc.objc_getClass("NSUUID") orelse return error.ClassNotFound;
    const sel_uuid = try selector("UUID");
    const uuid = objc.msgSendId(NSUUID, sel_uuid) orelse return error.NativeCallFailed;
    return copyNSStringProperty(allocator, uuid, "UUIDString");
}

fn msgSendLong(target: Id, sel: Id) c_long {
    const Fn = *const fn (Id, Id) callconv(.c) c_long;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(target, sel);
}

fn msgSendVoidLong(target: Id, sel: Id, value: c_long) void {
    const Fn = *const fn (Id, Id, c_long) callconv(.c) void;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    f(target, sel, value);
}

fn msgSendVoidULong(target: Id, sel: Id, value: c_ulong) void {
    const Fn = *const fn (Id, Id, c_ulong) callconv(.c) void;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    f(target, sel, value);
}

fn msgSendVoidBool(target: Id, sel: Id, value: bool) void {
    const Fn = *const fn (Id, Id, bool) callconv(.c) void;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    f(target, sel, value);
}

/// A class-method `BOOL` with no arguments, e.g.
/// `+[ARWorldTrackingConfiguration isSupported]`.
fn classBool(class_name: [*:0]const u8, comptime sel_name: [*:0]const u8) bool {
    if (!is_darwin) return false;
    const cls = objc.objc_getClass(class_name) orelse return false;
    const sel = objc.sel_registerName(sel_name) orelse return false;
    return objc.msgSendBool(cls, sel);
}

// =============================================================================
// The plane shape, kept pure so the JSON the page reads is pinnable on a host.
// =============================================================================

/// One entry of `getARPlanes`, and the body of a `craftARPlane` event.
///
/// The seven numbers Swift reads off an `ARPlaneAnchor`, flattened at the point
/// of use. `extent` contributes **x and z** — Swift maps them to `width` and
/// `height`, so a plane's `y` extent never reaches the page.
const Plane = struct {
    id: []const u8,
    horizontal: bool,
    center_x: f32,
    center_y: f32,
    center_z: f32,
    extent_x: f32,
    extent_z: f32,
};

fn appendPlaneObject(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), plane: Plane) !void {
    try out.append(allocator, '{');
    try appendPlaneFields(allocator, out, plane);
    try out.append(allocator, '}');
}

/// The four keys, without the braces, so `getARPlanes` and the `craftARPlane`
/// event cannot drift apart: the event is the same object with a `type` in
/// front of it.
fn appendPlaneFields(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), plane: Plane) !void {
    try out.appendSlice(allocator, "\"id\":\"");
    try bridge_error.appendJsonEscaped(allocator, out, plane.id);
    try out.appendSlice(allocator, "\",\"alignment\":\"");
    try out.appendSlice(allocator, if (plane.horizontal) "horizontal" else "vertical");
    try out.appendSlice(allocator, "\",\"center\":{\"x\":");
    try appendFloat(allocator, out, plane.center_x);
    try out.appendSlice(allocator, ",\"y\":");
    try appendFloat(allocator, out, plane.center_y);
    try out.appendSlice(allocator, ",\"z\":");
    try appendFloat(allocator, out, plane.center_z);
    try out.appendSlice(allocator, "},\"extent\":{\"width\":");
    try appendFloat(allocator, out, plane.extent_x);
    try out.appendSlice(allocator, ",\"height\":");
    try appendFloat(allocator, out, plane.extent_z);
    try out.append(allocator, '}');
}

/// `allocPrint`, not a stack buffer: an `f32` rendered with `{d}` has no small
/// bound, and a `NoSpaceLeft` here would turn a measured plane into a refusal.
fn appendFloat(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: f32) !void {
    const rendered = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(rendered);
    try out.appendSlice(allocator, rendered);
}

/// The bare JSON array `getARPlanes` resolves.
///
/// `resolveCallback(callbackId, result: planes)` through `.fragmentsAllowed`
/// puts the array on the wire unwrapped, so `[]` — not `{"planes":[]}` — is the
/// answer when nothing has been detected.
fn shapePlanes(allocator: std.mem.Allocator, planes: []const Plane) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (planes, 0..) |plane, i| {
        if (i != 0) try out.append(allocator, ',');
        try appendPlaneObject(allocator, &out, plane);
    }
    try out.append(allocator, ']');

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// The bridge.
// =============================================================================

pub const ARBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const route = routeFor(action) orelse return bridge_error.BridgeError.UnknownAction;
        // Exhaustive, so a `Route` without a handler is a compile error.
        return switch (route) {
            .start => self.startAR(data),
            .stop => self.stopAR(data),
            .place => self.placeARObject(data),
            .remove => self.removeARObject(data),
            .planes => self.getARPlanes(data),
        };
    }

    /// Put an `ARSCNView` on the app's window and run world tracking on it.
    ///
    /// `data` is accepted and ignored, which is not laziness: the Swift
    /// dispatcher parses `body["options"]` into a dictionary and hands it to
    /// `startAR(options:callbackId:)`, whose body never reads it. Parsing it
    /// here would invent a rejection for a malformed field the shim accepts.
    ///
    /// Swift wraps the whole body in `DispatchQueue.main.async`. This does not,
    /// because dispatch already arrives on the main thread — the hop would only
    /// defer the reply by a runloop turn. See the ordering note on
    /// `getARPlanes`, which is the one place that is observable.
    fn startAR(self: *Self, data: []const u8) !void {
        _ = data;
        if (!is_darwin) return error.UnsupportedPlatform;

        // `guard ARWorldTrackingConfiguration.isSupported else { reject }`.
        // Also the answer on a host and in the simulator, where the class is
        // absent or reports false — `classBool` gives the same `false` either
        // way, which is the honest answer for both.
        if (!classBool("ARWorldTrackingConfiguration", "isSupported")) {
            std.log.warn("startAR: ARWorldTrackingConfiguration reports unsupported; refusing, as the shim does", .{});
            return bridge_error.BridgeError.PlatformNotSupported;
        }

        const ARSCNView = objc.objc_getClass("ARSCNView") orelse return error.ClassNotFound;
        const ARWorldTrackingConfiguration = objc.objc_getClass("ARWorldTrackingConfiguration") orelse
            return error.ClassNotFound;

        const bounds = try screenBounds();

        const allocated = objc.msgSendId(ARSCNView, try selector("alloc")) orelse
            return error.NativeCallFailed;
        const view = msgSendIdWithRect(allocated, try selector("initWithFrame:"), bounds) orelse
            return error.NativeCallFailed;

        msgSendVoidBool(view, try selector("setAutoenablesDefaultLighting:"), true);
        msgSendVoidLong(view, try selector("setTag:"), ar_view_tag);
        objc.msgSendVoid1(view, try selector("setDelegate:"), try ensureDelegate());

        const configuration = (try objc.allocInit(ARWorldTrackingConfiguration)) orelse
            return error.NativeCallFailed;
        msgSendVoidULong(
            configuration,
            try selector("setPlaneDetection:"),
            ar_plane_detection_horizontal_and_vertical,
        );
        msgSendVoidLong(
            configuration,
            try selector("setEnvironmentTexturing:"),
            ar_environment_texturing_automatic,
        );

        const session = objc.msgSendId(view, try selector("session")) orelse
            return error.NativeCallFailed;

        // Swift's `if let windowScene = …, let window = … { window.addSubview }`
        // is a soft failure: the session still runs, the view is just not
        // visible. Kept soft here, and logged, because refusing would be a
        // different answer from the shim's.
        addViewToKeyWindow(view);

        objc.msgSendVoid1(session, try selector("runWithConfiguration:"), configuration);

        ar_view = view;
        ar_session = session;

        bridge_error.sendResultToJS(self.allocator, A.start_ar, "{\"started\":true}");
    }

    /// Pause the session, take the view off the window, and forget everything.
    ///
    /// No guard: `stopAR` has none in Swift, so stopping a session that never
    /// started answers `{"stopped":true}` rather than an error. "There is no
    /// session" and "the session is stopped" are the same state to a caller.
    fn stopAR(self: *Self, data: []const u8) !void {
        _ = data;
        if (!is_darwin) return error.UnsupportedPlatform;

        if (ar_session) |session| {
            objc.msgSend(session, try selector("pause"));
        }
        if (ar_view) |view| {
            objc.msgSend(view, try selector("removeFromSuperview"));
            release(view);
        }
        ar_view = null;
        ar_session = null;

        clearObjects();
        clearPlanes();

        bridge_error.sendResultToJS(self.allocator, A.stop_ar, "{\"stopped\":true}");
    }

    /// Add a node to the running session's scene.
    fn placeARObject(self: *Self, data: []const u8) !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return bridge_error.BridgeError.InvalidJSON;
        defer parsed.deinit();

        const object = switch (parsed.value) {
            .object => |o| o,
            else => return invalidArgument("placeARObject"),
        };

        // `if let model = body["model"] as? String` — a missing or non-string
        // `model` is INVALID_ARGUMENT, and the position is read only after.
        const model = switch (object.get("model") orelse return invalidArgument("placeARObject")) {
            .string => |s| s,
            else => return invalidArgument("placeARObject"),
        };

        const view = ar_view orelse {
            std.log.warn("placeARObject: no AR session is running", .{});
            return bridge_error.BridgeError.InvalidParameter;
        };

        const position = readPosition(object.get("position"));

        const node = try buildNode(model);

        const object_id = try newObjectId(ar_allocator);
        errdefer ar_allocator.free(object_id);

        try setNodePosition(node, position);

        const ns_id = makeNSString(object_id) orelse return error.NativeCallFailed;
        objc.msgSendVoid1(node, try selector("setName:"), ns_id);

        const scene = objc.msgSendId(view, try selector("scene")) orelse return error.NativeCallFailed;
        const root = objc.msgSendId(scene, try selector("rootNode")) orelse return error.NativeCallFailed;
        objc.msgSendVoid1(root, try selector("addChildNode:"), node);

        retain(node);
        try ar_objects.put(ar_allocator, object_id, node);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"objectId\":\"");
        try bridge_error.appendJsonEscaped(self.allocator, &out, object_id);
        try out.appendSlice(self.allocator, "\",\"placed\":true}");

        bridge_error.sendResultToJS(self.allocator, A.place_ar_object, out.items);
    }

    /// Take a node back out of the scene.
    fn removeARObject(self: *Self, data: []const u8) !void {
        if (!is_darwin) return error.UnsupportedPlatform;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return bridge_error.BridgeError.InvalidJSON;
        defer parsed.deinit();

        const object = switch (parsed.value) {
            .object => |o| o,
            else => return invalidArgument("removeARObject"),
        };
        const object_id = switch (object.get("objectId") orelse return invalidArgument("removeARObject")) {
            .string => |s| s,
            else => return invalidArgument("removeARObject"),
        };

        // `if let node = self.arObjects[objectId] … else { reject("Object not found") }`.
        const entry = ar_objects.fetchRemove(object_id) orelse {
            std.log.warn("removeARObject: no object with that id is placed", .{});
            return bridge_error.BridgeError.InvalidParameter;
        };
        defer ar_allocator.free(entry.key);

        objc.msgSend(entry.value, try selector("removeFromParentNode"));
        release(entry.value);

        bridge_error.sendResultToJS(self.allocator, A.remove_ar_object, "{\"removed\":true}");
    }

    /// Every plane the session has detected, as a bare JSON array.
    ///
    /// One ordering divergence, and it is a fix rather than a loss: Swift's
    /// `getARPlanes` is the only one of the five *not* wrapped in
    /// `DispatchQueue.main.async`, so a `startAR` immediately followed by a
    /// `getARPlanes` has the planes reply first. Both are synchronous here, so
    /// replies keep the order the page sent them in.
    fn getARPlanes(self: *Self, data: []const u8) !void {
        _ = data;
        if (!is_darwin) return error.UnsupportedPlatform;

        var planes: std.ArrayListUnmanaged(Plane) = .empty;
        defer {
            for (planes.items) |plane| self.allocator.free(plane.id);
            planes.deinit(self.allocator);
        }

        var it = ar_planes.iterator();
        while (it.next()) |entry| {
            const plane = readPlane(self.allocator, entry.key_ptr.*, entry.value_ptr.*) catch |err| {
                // One unreadable anchor must not cost the page the others.
                std.log.warn("getARPlanes: could not read a plane anchor ({}); it is left out", .{err});
                continue;
            };
            try planes.append(self.allocator, plane);
        }

        const json = try shapePlanes(self.allocator, planes.items);
        defer self.allocator.free(json);

        bridge_error.sendResultToJS(self.allocator, A.get_ar_planes, json);
    }
};

/// `rejectCallback(callbackId, error: "… was called without the values it needs", code: "INVALID_ARGUMENT")`.
///
/// `BridgeError` carries an enum rather than free text, so the page sees
/// `INVALID_PARAMETER` where Swift sent `INVALID_ARGUMENT` — the same trade
/// `bridge_mobile_misc.zig` and `bridge_mobile_watch.zig` document. The
/// rejection itself, which is what the promise needs, is not lost.
fn invalidArgument(comptime action: []const u8) bridge_error.BridgeError {
    std.log.warn(action ++ ": called without the values it needs", .{});
    return bridge_error.BridgeError.InvalidParameter;
}

// =============================================================================
// Building a node, and reading a plane.
// =============================================================================

/// `SCNVector3(Float(pos["x"] ?? 0), Float(pos["y"] ?? 0), Float(pos["z"] ?? -0.5))`.
const Position = struct { x: f64 = 0, y: f64 = 0, z: f64 = default_z };

/// Swift's cast is `body["position"] as? [String: Double]`, and a
/// **dictionary** cast fails as a whole when any one value is not a `Double`.
/// So `{"x": 1, "y": "up"}` is not "x with a bad y", it is no position at all,
/// and the node lands at the default. Ported exactly: one non-number anywhere
/// discards the whole dictionary.
fn readPosition(value: ?std.json.Value) Position {
    const object = switch (value orelse return .{}) {
        .object => |o| o,
        else => return .{},
    };

    var position: Position = .{};
    var it = object.iterator();
    while (it.next()) |entry| {
        const number: f64 = switch (entry.value_ptr.*) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            // The whole cast fails, so nothing survives from this dictionary.
            else => return .{},
        };
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "x")) position.x = number;
        if (std.mem.eql(u8, key, "y")) position.y = number;
        if (std.mem.eql(u8, key, "z")) position.z = number;
    }
    return position;
}

fn setNodePosition(node: Id, position: Position) !void {
    msgSendSetVector3(node, try selector("setPosition:"), .{
        .x = @floatCast(position.x),
        .y = @floatCast(position.y),
        .z = @floatCast(position.z),
    });
}

/// `model.hasSuffix(".usdz") || model.hasSuffix(".scn")` picks the loader;
/// everything else is a named primitive, with an unrecognised name falling to
/// the same box as `"box"` — Swift's `default:`, not an error.
fn buildNode(model: []const u8) !Id {
    if (std.mem.endsWith(u8, model, ".usdz") or std.mem.endsWith(u8, model, ".scn")) {
        return loadModelNode(model);
    }
    return primitiveNode(model);
}

fn loadModelNode(model: []const u8) !Id {
    const NSURL = objc.objc_getClass("NSURL") orelse return error.ClassNotFound;
    const ns_model = makeNSString(model) orelse return error.NativeCallFailed;

    // `URL(string: model)`, which answers nil for a string that is not a URL —
    // Swift's "Invalid model URL" rejection.
    const url = objc.msgSendId1(NSURL, try selector("URLWithString:"), ns_model) orelse {
        std.log.warn("placeARObject: the model string is not a URL", .{});
        return bridge_error.BridgeError.InvalidParameter;
    };

    const SCNScene = objc.objc_getClass("SCNScene") orelse return error.ClassNotFound;

    // `SCNScene(url:options:)` throws; the Objective-C spelling takes an
    // `NSError **` and answers nil. Both are "Failed to load model".
    var err_object: Id = null;
    const SceneFn = *const fn (Id, Id, Id, Id, *Id) callconv(.c) Id;
    const scene_with: SceneFn = @ptrCast(&objc.objc_msgSend);
    const scene = scene_with(
        SCNScene,
        try selector("sceneWithURL:options:error:"),
        url,
        null,
        &err_object,
    ) orelse {
        std.log.warn("placeARObject: SCNScene could not load the model", .{});
        return bridge_error.BridgeError.NativeCallFailed;
    };

    // `let node = SCNNode(); for child in scene.rootNode.childNodes { node.addChildNode(child) }`
    //
    // A wrapper node, not the scene's root: `addChildNode` re-parents, so
    // handing the page the loaded root would move the scene's own graph.
    const SCNNode = objc.objc_getClass("SCNNode") orelse return error.ClassNotFound;
    const node = objc.msgSendId(SCNNode, try selector("node")) orelse return error.NativeCallFailed;

    const root = objc.msgSendId(scene, try selector("rootNode")) orelse return error.NativeCallFailed;
    const children = objc.msgSendId(root, try selector("childNodes")) orelse return error.NativeCallFailed;

    const count: c_ulong = @intCast(msgSendLong(children, try selector("count")));
    const sel_at = try selector("objectAtIndex:");
    const sel_add = try selector("addChildNode:");
    const AtFn = *const fn (Id, Id, c_ulong) callconv(.c) Id;
    const object_at: AtFn = @ptrCast(&objc.objc_msgSend);

    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        const child = object_at(children, sel_at, i) orelse continue;
        objc.msgSendVoid1(node, sel_add, child);
    }

    return node;
}

fn primitiveNode(model: []const u8) !Id {
    const geometry = try namedGeometry(model);

    // `geometry.firstMaterial?.diffuse.contents = UIColor.systemBlue`. Optional
    // the whole way in Swift, so a geometry with no material is not an error.
    if (objc.msgSendId(geometry, try selector("firstMaterial"))) |material| {
        if (objc.msgSendId(material, try selector("diffuse"))) |property| {
            if (systemBlue()) |color| {
                objc.msgSendVoid1(property, try selector("setContents:"), color);
            }
        }
    }

    const SCNNode = objc.objc_getClass("SCNNode") orelse return error.ClassNotFound;
    return objc.msgSendId1(SCNNode, try selector("nodeWithGeometry:"), geometry) orelse
        error.NativeCallFailed;
}

/// The four named primitives, at Swift's dimensions.
fn namedGeometry(model: []const u8) !Id {
    const Two = *const fn (Id, Id, CGFloat, CGFloat) callconv(.c) Id;
    const Three = *const fn (Id, Id, CGFloat, CGFloat, CGFloat) callconv(.c) Id;
    const Four = *const fn (Id, Id, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) Id;

    if (std.mem.eql(u8, model, "sphere")) {
        const SCNSphere = objc.objc_getClass("SCNSphere") orelse return error.ClassNotFound;
        const f: *const fn (Id, Id, CGFloat) callconv(.c) Id = @ptrCast(&objc.objc_msgSend);
        return f(SCNSphere, try selector("sphereWithRadius:"), 0.05) orelse error.NativeCallFailed;
    }
    if (std.mem.eql(u8, model, "cylinder")) {
        const SCNCylinder = objc.objc_getClass("SCNCylinder") orelse return error.ClassNotFound;
        const f: Two = @ptrCast(&objc.objc_msgSend);
        return f(SCNCylinder, try selector("cylinderWithRadius:height:"), 0.05, 0.1) orelse
            error.NativeCallFailed;
    }
    if (std.mem.eql(u8, model, "cone")) {
        const SCNCone = objc.objc_getClass("SCNCone") orelse return error.ClassNotFound;
        const f: Three = @ptrCast(&objc.objc_msgSend);
        return f(SCNCone, try selector("coneWithTopRadius:bottomRadius:height:"), 0, 0.05, 0.1) orelse
            error.NativeCallFailed;
    }

    // `case "box"` and `default:` are the same geometry in Swift.
    const SCNBox = objc.objc_getClass("SCNBox") orelse return error.ClassNotFound;
    const f: Four = @ptrCast(&objc.objc_msgSend);
    return f(SCNBox, try selector("boxWithWidth:height:length:chamferRadius:"), 0.1, 0.1, 0.1, 0.01) orelse
        error.NativeCallFailed;
}

fn systemBlue() ?Id {
    const UIColor = objc.objc_getClass("UIColor") orelse return null;
    const sel = objc.sel_registerName("systemBlueColor") orelse return null;
    return objc.msgSendId(UIColor, sel);
}

/// `UIScreen.main.bounds`.
fn screenBounds() !CGRect {
    const UIScreen = objc.objc_getClass("UIScreen") orelse return error.ClassNotFound;
    const screen = objc.msgSendId(UIScreen, try selector("mainScreen")) orelse
        return error.NativeCallFailed;
    return msgSendRect(screen, try selector("bounds"));
}

/// `UIApplication.shared.connectedScenes.first as? UIWindowScene` →
/// `.windows.first` → `addSubview`.
///
/// Every step is optional in Swift and the whole thing is an `if let`, so a
/// failure anywhere means the view is simply not added — the session still
/// runs. Logged rather than refused, because refusing would be a different
/// answer from the shim's.
fn addViewToKeyWindow(view: Id) void {
    const missing = "startAR: could not reach a window to attach the AR view to; the session runs without a visible view";

    const UIApplication = objc.objc_getClass("UIApplication") orelse return;
    const sel_shared = objc.sel_registerName("sharedApplication") orelse return;
    const app = objc.msgSendId(UIApplication, sel_shared) orelse return;

    const sel_scenes = objc.sel_registerName("connectedScenes") orelse return;
    const scenes = objc.msgSendId(app, sel_scenes) orelse {
        std.log.warn(missing, .{});
        return;
    };

    // `Set.first` in Swift is an arbitrary member; `-anyObject` is the same
    // choice made by the same collection.
    const sel_any = objc.sel_registerName("anyObject") orelse return;
    const scene = objc.msgSendId(scenes, sel_any) orelse {
        std.log.warn(missing, .{});
        return;
    };

    const sel_windows = objc.sel_registerName("windows") orelse return;
    const sel_responds = objc.sel_registerName("respondsToSelector:") orelse return;
    const RespondsFn = *const fn (Id, Id, Id) callconv(.c) bool;
    const responds: RespondsFn = @ptrCast(&objc.objc_msgSend);

    // `as? UIWindowScene` in one question: a scene that is not a window scene
    // has no `windows`, and asking beats sending an unrecognised selector.
    if (!responds(scene, sel_responds, sel_windows)) {
        std.log.warn(missing, .{});
        return;
    }

    const windows = objc.msgSendId(scene, sel_windows) orelse return;
    const sel_first = objc.sel_registerName("firstObject") orelse return;
    const window = objc.msgSendId(windows, sel_first) orelse {
        std.log.warn(missing, .{});
        return;
    };

    const sel_add = objc.sel_registerName("addSubview:") orelse return;
    objc.msgSendVoid1(window, sel_add, view);
    retain(view);
}

/// The seven numbers `getARPlanes` reads off one anchor.
fn readPlane(allocator: std.mem.Allocator, id: []const u8, anchor: Id) !Plane {
    const center = msgSendSimd3(anchor, try selector("center"));
    const extent = msgSendSimd3(anchor, try selector("extent"));
    const alignment = msgSendLong(anchor, try selector("alignment"));

    return .{
        .id = try allocator.dupe(u8, id),
        .horizontal = alignment == ar_plane_alignment_horizontal,
        .center_x = simdX(center),
        .center_y = simdY(center),
        .center_z = simdZ(center),
        .extent_x = simdX(extent),
        .extent_z = simdZ(extent),
    };
}

fn clearObjects() void {
    var it = ar_objects.iterator();
    while (it.next()) |entry| {
        release(entry.value_ptr.*);
        ar_allocator.free(entry.key_ptr.*);
    }
    ar_objects.clearAndFree(ar_allocator);
}

fn clearPlanes() void {
    var it = ar_planes.iterator();
    while (it.next()) |entry| {
        release(entry.value_ptr.*);
        ar_allocator.free(entry.key_ptr.*);
    }
    ar_planes.clearAndFree(ar_allocator);
}

// =============================================================================
// The ARSCNViewDelegate, which is where planes come from.
// =============================================================================

const delegate_class_name = "CraftARDelegate";

var delegate_instance: Id = null;

/// Register the delegate class once, and keep one instance alive.
///
/// `ARSCNView` holds its delegate **weakly**, so a released instance is a
/// session that silently stops reporting planes. Module-level, for the same
/// reason `bridge_mobile_location.zig` keeps its own.
fn ensureDelegate() !Id {
    if (!is_darwin) return error.UnsupportedPlatform;
    if (delegate_instance) |existing| return existing;

    var cls = objc.objc_getClass(delegate_class_name);
    if (cls == null) {
        // All three selectors resolved before the class pair is allocated: a
        // failure between `objc_allocateClassPair` and `objc_registerClassPair`
        // leaves an unregistered class behind that nothing can dispose of.
        const sel_add = try selector("renderer:didAddNode:forAnchor:");
        const sel_update = try selector("renderer:didUpdateNode:forAnchor:");
        const sel_remove = try selector("renderer:didRemoveNode:forAnchor:");

        const NSObject = objc.objc_getClass("NSObject") orelse return error.ClassNotFound;
        cls = objc.objc_allocateClassPair(NSObject, delegate_class_name, 0) orelse
            return error.ClassAllocationFailed;

        // v@:@@@ — void, self, _cmd, the renderer, the node, the anchor.
        if (!objc.class_addMethod(cls, sel_add, @ptrCast(&rendererDidAddNode), "v@:@@@")) {
            return error.MethodNotAdded;
        }
        if (!objc.class_addMethod(cls, sel_update, @ptrCast(&rendererDidUpdateNode), "v@:@@@")) {
            return error.MethodNotAdded;
        }
        if (!objc.class_addMethod(cls, sel_remove, @ptrCast(&rendererDidRemoveNode), "v@:@@@")) {
            return error.MethodNotAdded;
        }
        objc.objc_registerClassPair(cls);
    }

    const instance = (try objc.allocInit(cls)) orelse return error.NativeCallFailed;
    delegate_instance = instance;
    return instance;
}

fn isKindOf(object: Id, class_name: [*:0]const u8) bool {
    if (!is_darwin) return false;
    const cls = objc.objc_getClass(class_name) orelse return false;
    const sel = objc.sel_registerName("isKindOfClass:") orelse return false;
    const Fn = *const fn (Id, Id, Id) callconv(.c) bool;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    return f(object, sel, cls);
}

/// The anchor's `identifier.uuidString`, owned by the caller.
fn anchorId(allocator: std.mem.Allocator, anchor: Id) ![]u8 {
    const identifier = objc.msgSendId(anchor, try selector("identifier")) orelse
        return error.NativeCallFailed;
    return copyNSStringProperty(allocator, identifier, "UUIDString");
}

/// Store or replace the anchor under its id, keeping one retain per entry.
fn rememberPlane(id: []const u8, anchor: Id) !void {
    if (ar_planes.getEntry(id)) |entry| {
        // `detectedPlanes[anchor.identifier] = planeAnchor` on an existing key
        // replaces the value; the key is already ours and stays.
        release(entry.value_ptr.*);
        retain(anchor);
        entry.value_ptr.* = anchor;
        return;
    }

    const owned = try ar_allocator.dupe(u8, id);
    errdefer ar_allocator.free(owned);
    retain(anchor);
    try ar_planes.put(ar_allocator, owned, anchor);
}

fn rendererDidAddNode(_: Id, _: Id, _: Id, node: Id, anchor: Id) callconv(.c) void {
    if (!is_darwin) return;

    // `guard let planeAnchor = anchor as? ARPlaneAnchor else { return }`.
    if (!isKindOf(anchor, "ARPlaneAnchor")) return;

    const allocator = std.heap.c_allocator;

    const id = anchorId(allocator, anchor) catch |err| {
        std.log.warn("ar: a plane anchor arrived with no readable identifier ({}); it is not recorded", .{err});
        return;
    };
    defer allocator.free(id);

    rememberPlane(id, anchor) catch |err| {
        std.log.warn("ar: could not record the plane anchor ({}); getARPlanes will not report it", .{err});
        return;
    };

    // The visualisation is decoration: a failure here costs the page a grey
    // rectangle, not a plane, so it is logged and the event still goes out.
    addPlaneVisualisation(node, anchor) catch |err| {
        std.log.warn("ar: could not build the plane visualisation ({}); the plane is still reported", .{err});
    };

    const plane = readPlane(allocator, id, anchor) catch |err| {
        std.log.warn("ar: could not read the new plane's geometry ({}); no event is emitted", .{err});
        return;
    };
    defer allocator.free(plane.id);

    const json = shapePlaneEvent(allocator, "added", plane) catch return;
    defer allocator.free(json);

    ios_events.emit(.ar_plane, json);
}

fn rendererDidUpdateNode(_: Id, _: Id, _: Id, node: Id, anchor: Id) callconv(.c) void {
    if (!is_darwin) return;

    if (!isKindOf(anchor, "ARPlaneAnchor")) return;

    const allocator = std.heap.c_allocator;

    const id = anchorId(allocator, anchor) catch return;
    defer allocator.free(id);

    rememberPlane(id, anchor) catch |err| {
        std.log.warn("ar: could not update the stored plane anchor ({})", .{err});
    };

    // `if let planeNode = node.childNodes.first, let plane = planeNode.geometry as? SCNPlane`
    // — both optional, so nothing here is an error.
    updatePlaneVisualisation(node, anchor) catch {};

    // Swift emits no event on update. Neither does this: a page that wants
    // live extents polls `getARPlanes`, which reads the anchor this just
    // replaced.
}

fn rendererDidRemoveNode(_: Id, _: Id, _: Id, _: Id, anchor: Id) callconv(.c) void {
    if (!is_darwin) return;

    if (!isKindOf(anchor, "ARPlaneAnchor")) return;

    const allocator = std.heap.c_allocator;

    const id = anchorId(allocator, anchor) catch return;
    defer allocator.free(id);

    if (ar_planes.fetchRemove(id)) |entry| {
        release(entry.value);
        ar_allocator.free(entry.key);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    out.appendSlice(allocator, "{\"type\":\"removed\",\"id\":\"") catch return;
    bridge_error.appendJsonEscaped(allocator, &out, id) catch return;
    out.appendSlice(allocator, "\"}") catch return;

    ios_events.emit(.ar_plane, out.items);
}

/// `{"type":"added", …the same fields `getARPlanes` reports…}`.
fn shapePlaneEvent(allocator: std.mem.Allocator, comptime kind: []const u8, plane: Plane) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"type\":\"" ++ kind ++ "\",");
    try appendPlaneFields(allocator, &out, plane);
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

/// The grey rectangle Swift draws over a detected plane.
fn addPlaneVisualisation(node: Id, anchor: Id) !void {
    const extent = msgSendSimd3(anchor, try selector("extent"));
    const center = msgSendSimd3(anchor, try selector("center"));

    const SCNPlane = objc.objc_getClass("SCNPlane") orelse return error.ClassNotFound;
    const PlaneFn = *const fn (Id, Id, CGFloat, CGFloat) callconv(.c) Id;
    const plane_with: PlaneFn = @ptrCast(&objc.objc_msgSend);
    const plane = plane_with(
        SCNPlane,
        try selector("planeWithWidth:height:"),
        @floatCast(simdX(extent)),
        @floatCast(simdZ(extent)),
    ) orelse return error.NativeCallFailed;

    // `UIColor.systemBlue.withAlphaComponent(0.3)`.
    if (objc.msgSendId(plane, try selector("firstMaterial"))) |material| {
        if (objc.msgSendId(material, try selector("diffuse"))) |property| {
            if (systemBlue()) |color| {
                const AlphaFn = *const fn (Id, Id, CGFloat) callconv(.c) Id;
                const with_alpha: AlphaFn = @ptrCast(&objc.objc_msgSend);
                if (with_alpha(color, try selector("colorWithAlphaComponent:"), 0.3)) |faded| {
                    objc.msgSendVoid1(property, try selector("setContents:"), faded);
                }
            }
        }
    }

    const SCNNode = objc.objc_getClass("SCNNode") orelse return error.ClassNotFound;
    const plane_node = objc.msgSendId1(SCNNode, try selector("nodeWithGeometry:"), plane) orelse
        return error.NativeCallFailed;

    // `SCNVector3(planeAnchor.center.x, 0, planeAnchor.center.z)` — y is
    // dropped on purpose: the rectangle sits in the anchor's own plane.
    msgSendSetVector3(plane_node, try selector("setPosition:"), .{
        .x = @floatCast(simdX(center)),
        .y = 0,
        .z = @floatCast(simdZ(center)),
    });

    // `planeNode.eulerAngles.x = -.pi / 2`, which in Objective-C is a whole
    // vector read, one component changed, and the vector written back —
    // Swift's property-of-a-property assignment does exactly that too.
    const sel_euler = try selector("eulerAngles");
    var euler = msgSendVector3(plane_node, sel_euler);
    euler.x = -std.math.pi / 2.0;
    msgSendSetVector3(plane_node, try selector("setEulerAngles:"), euler);

    objc.msgSendVoid1(node, try selector("addChildNode:"), plane_node);
}

/// Resize and re-centre the rectangle a previous `didAdd` built.
fn updatePlaneVisualisation(node: Id, anchor: Id) !void {
    const children = objc.msgSendId(node, try selector("childNodes")) orelse return;
    const plane_node = objc.msgSendId(children, try selector("firstObject")) orelse return;
    const geometry = objc.msgSendId(plane_node, try selector("geometry")) orelse return;

    // `as? SCNPlane`: a child that is not one is left alone rather than sent a
    // selector it does not have.
    if (!isKindOf(geometry, "SCNPlane")) return;

    const extent = msgSendSimd3(anchor, try selector("extent"));
    const center = msgSendSimd3(anchor, try selector("center"));

    const SetFn = *const fn (Id, Id, CGFloat) callconv(.c) void;
    const set_dimension: SetFn = @ptrCast(&objc.objc_msgSend);
    set_dimension(geometry, try selector("setWidth:"), @floatCast(simdX(extent)));
    set_dimension(geometry, try selector("setHeight:"), @floatCast(simdZ(extent)));

    msgSendSetVector3(plane_node, try selector("setPosition:"), .{
        .x = @floatCast(simdX(center)),
        .y = 0,
        .z = @floatCast(simdZ(center)),
    });
}

// =============================================================================
// Tests.
//
// The three ABI mechanisms, exercised against real objects rather than read off
// the headers. SceneKit ships on macOS, so `SCNNode` and `SCNBox` are reachable
// from a host test even though ARKit is not; `NSView` supplies the `CGRect`
// round trip. What these cannot reach is a running AR session — see the module
// comment.
// =============================================================================

const testing = std.testing;

test "a CGRect survives the trip out and back" {
    if (!is_darwin) return error.SkipZigTest;

    // `-initWithFrame:` takes it in v0-v3 and `-frame` returns it the same way.
    // A mismatch here would misplace the AR view rather than fail.
    const NSView = objc.objc_getClass("NSView") orelse return error.SkipZigTest;
    const sel_alloc = try selector("alloc");
    const sel_init_frame = try selector("initWithFrame:");
    const sel_frame = try selector("frame");

    const allocated = objc.msgSendId(NSView, sel_alloc) orelse return error.SkipZigTest;
    const sent: CGRect = .{
        .origin = .{ .x = 12.5, .y = -3.25 },
        .size = .{ .width = 640, .height = 480.75 },
    };
    const view = msgSendIdWithRect(allocated, sel_init_frame, sent) orelse return error.SkipZigTest;

    const got = msgSendRect(view, sel_frame);
    try testing.expectEqual(sent.origin.x, got.origin.x);
    try testing.expectEqual(sent.origin.y, got.origin.y);
    try testing.expectEqual(sent.size.width, got.size.width);
    try testing.expectEqual(sent.size.height, got.size.height);
}

test "an SCNVector3 survives being set and read back" {
    if (!is_darwin) return error.SkipZigTest;

    // The mechanism `placeARObject`'s `node.position = …` depends on. At host
    // width, because macOS declares the members as CGFloat and iOS as float —
    // the shape is what is being checked, not the width.
    const SCNNode = objc.objc_getClass("SCNNode") orelse return error.SkipZigTest;
    const sel_node = try selector("node");
    const sel_set_position = try selector("setPosition:");
    const sel_position = try selector("position");

    const node = objc.msgSendId(SCNNode, sel_node) orelse return error.SkipZigTest;

    const sent: SCNVector3 = .{ .x = 1.5, .y = -2.25, .z = -0.5 };
    msgSendSetVector3(node, sel_set_position, sent);

    const got = msgSendVector3(node, sel_position);
    try testing.expectEqual(sent.x, got.x);
    try testing.expectEqual(sent.y, got.y);
    try testing.expectEqual(sent.z, got.z);
}

test "a simd_float3 comes back in one vector register, not as four floats" {
    if (!is_darwin) return error.SkipZigTest;

    // `ARPlaneAnchor.center` and `.extent` are `simd_float3`, and this is the
    // return rule they use. `SCNNode.simdPosition` is the same type and is
    // reachable without ARKit, so the rule is checked here rather than assumed
    // on a device nobody can run in CI.
    //
    // Read against `position`, which carries the same three numbers through the
    // *other* convention: if this were being decoded as a float aggregate, x
    // would still agree and y and z would not.
    const SCNNode = objc.objc_getClass("SCNNode") orelse return error.SkipZigTest;
    const sel_node = try selector("node");
    const sel_set_position = try selector("setPosition:");
    const sel_simd_position = try selector("simdPosition");

    const node = objc.msgSendId(SCNNode, sel_node) orelse return error.SkipZigTest;
    msgSendSetVector3(node, sel_set_position, .{ .x = 1.5, .y = -2.25, .z = -0.5 });

    const got = msgSendSimd3(node, sel_simd_position);
    try testing.expectApproxEqAbs(@as(f32, 1.5), simdX(got), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -2.25), simdY(got), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), simdZ(got), 0.0001);
}

test "a CGFloat-returning geometry property reads back what it was built with" {
    if (!is_darwin) return error.SkipZigTest;

    // The four-CGFloat constructor `placeARObject` uses for "box".
    const SCNBox = objc.objc_getClass("SCNBox") orelse return error.SkipZigTest;
    const sel_box = try selector("boxWithWidth:height:length:chamferRadius:");
    const Fn = *const fn (Id, Id, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) Id;
    const box_with: Fn = @ptrCast(&objc.objc_msgSend);

    const box = box_with(SCNBox, sel_box, 0.1, 0.2, 0.3, 0.01) orelse return error.SkipZigTest;

    try testing.expectApproxEqAbs(@as(CGFloat, 0.1), msgSendCGFloat(box, try selector("width")), 0.0001);
    try testing.expectApproxEqAbs(@as(CGFloat, 0.2), msgSendCGFloat(box, try selector("height")), 0.0001);
    try testing.expectApproxEqAbs(@as(CGFloat, 0.3), msgSendCGFloat(box, try selector("length")), 0.0001);
}

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 5), capability_actions.len);
    try testing.expectEqualStrings(A.start_ar, capability_actions[0].name);
    try testing.expectEqualStrings(A.stop_ar, capability_actions[1].name);
    try testing.expectEqualStrings(A.place_ar_object, capability_actions[2].name);
    try testing.expectEqualStrings(A.remove_ar_object, capability_actions[3].name);
    try testing.expectEqualStrings(A.get_ar_planes, capability_actions[4].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
        try testing.expect(decl.reason == null);
        try testing.expect(routeFor(decl.name) != null);
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = ARBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Casing is how a real typo arrives, and `startAr` is a plausible one.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("startAr", "{}"),
    );
}

test "no planes is the bare array, not null and not a wrapper" {
    // `resolveCallback(callbackId, result: planes)` through `.fragmentsAllowed`
    // puts the array on the wire unwrapped, so a page doing `planes.length`
    // keeps working when nothing has been detected.
    const json = try shapePlanes(testing.allocator, &.{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("[]", json);
}

test "a plane carries extent's x and z as width and height" {
    // The mapping is easy to get wrong and impossible to see: Swift reads
    // `extent.x` into `width` and **`extent.z`** into `height`, so a plane's y
    // extent never reaches the page at all.
    const json = try shapePlanes(testing.allocator, &.{
        .{
            .id = "AAA",
            .horizontal = true,
            .center_x = 1,
            .center_y = 2,
            .center_z = 3,
            .extent_x = 4,
            .extent_z = 5,
        },
    });
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\[{"id":"AAA","alignment":"horizontal","center":{"x":1,"y":2,"z":3},"extent":{"width":4,"height":5}}]
    , json);
}

test "alignment is horizontal or vertical, and nothing else" {
    const json = try shapePlanes(testing.allocator, &.{
        .{ .id = "A", .horizontal = true, .center_x = 0, .center_y = 0, .center_z = 0, .extent_x = 0, .extent_z = 0 },
        .{ .id = "B", .horizontal = false, .center_x = 0, .center_y = 0, .center_z = 0, .extent_x = 0, .extent_z = 0 },
    });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"alignment\":\"horizontal\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"alignment\":\"vertical\"") != null);
    // Two objects, one separator.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "},{"));
}

test "the craftARPlane event is the same object with a type in front" {
    // `getARPlanes` and the event have to agree about a plane, so they share
    // the field writer. This is what pins that they still do.
    const plane: Plane = .{
        .id = "AAA",
        .horizontal = false,
        .center_x = 1,
        .center_y = 2,
        .center_z = 3,
        .extent_x = 4,
        .extent_z = 5,
    };

    const event = try shapePlaneEvent(testing.allocator, "added", plane);
    defer testing.allocator.free(event);

    const array = try shapePlanes(testing.allocator, &.{plane});
    defer testing.allocator.free(array);

    // The array element's fields, unwrapped from its brackets and braces.
    const fields = array[2 .. array.len - 2];

    const expected = try std.fmt.allocPrint(testing.allocator, "{{\"type\":\"added\",{s}}}", .{fields});
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, event);
}

fn positionOf(json: []const u8) !Position {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return readPosition(parsed.value.object.get("position"));
}

test "a missing position is the same as an empty one: (0, 0, -0.5)" {
    // Both arms of Swift's `if let pos = position` land on z = -0.5, one
    // through `SCNVector3(0, 0, -0.5)` and the other through `pos["z"] ?? -0.5`.
    const absent = try positionOf("{}");
    try testing.expectEqual(@as(f64, 0), absent.x);
    try testing.expectEqual(@as(f64, 0), absent.y);
    try testing.expectEqual(default_z, absent.z);

    const empty = try positionOf("{\"position\":{}}");
    try testing.expectEqual(default_z, empty.z);
}

test "a position is read component by component, integers included" {
    const p = try positionOf("{\"position\":{\"x\":1.5,\"y\":-2,\"z\":0}}");
    try testing.expectEqual(@as(f64, 1.5), p.x);
    try testing.expectEqual(@as(f64, -2), p.y);
    try testing.expectEqual(@as(f64, 0), p.z);
}

test "one non-number discards the whole position, as a dictionary cast does" {
    // `body["position"] as? [String: Double]` is a cast of the *dictionary*.
    // It fails whole when any value is not a Double, so `{"x":1,"y":"up"}` is
    // not "x with a bad y" — it is no position, and the node lands at the
    // default. A reader that kept x would put the object somewhere Swift
    // never would.
    const p = try positionOf("{\"position\":{\"x\":1.5,\"y\":\"up\"}}");
    try testing.expectEqual(@as(f64, 0), p.x);
    try testing.expectEqual(@as(f64, 0), p.y);
    try testing.expectEqual(default_z, p.z);

    const nested = try positionOf("{\"position\":{\"x\":1.5,\"z\":{\"deep\":1}}}");
    try testing.expectEqual(@as(f64, 0), nested.x);
    try testing.expectEqual(default_z, nested.z);
}

test "a position that is not an object at all is no position" {
    try testing.expectEqual(default_z, (try positionOf("{\"position\":[1,2,3]}")).z);
    try testing.expectEqual(default_z, (try positionOf("{\"position\":\"1,2,3\"}")).z);
    try testing.expectEqual(default_z, (try positionOf("{\"position\":null}")).z);
}

test "startAR refuses where world tracking is unavailable rather than reaching for it" {
    // On a host — and in the simulator — `ARWorldTrackingConfiguration` is
    // absent or answers false, and `classBool` gives `false` for both. That is
    // Swift's `guard … isSupported else { reject }`, and it is the only AR
    // path any test in this repository can reach.
    var bridge = ARBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.PlatformNotSupported,
        bridge.handleMessage(A.start_ar, "{}"),
    );
}

test "placeARObject needs a model before it needs a session" {
    var bridge = ARBridge.init(testing.allocator);
    defer bridge.deinit();

    // Swift checks `body["model"] as? String` in the dispatcher, before
    // `placeARObject` ever looks at `self.arView` — so a call with no model is
    // INVALID_ARGUMENT whether or not a session is running.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.place_ar_object, "{}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.place_ar_object, "{\"model\":42}"),
    );
}

test "removeARObject with an id nothing was placed under is a rejection" {
    var bridge = ARBridge.init(testing.allocator);
    defer bridge.deinit();

    // Swift's `else { rejectCallback(… "Object not found") }`. Reachable on a
    // host because the map is empty, which is the same state a real device is
    // in before anything is placed.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.remove_ar_object, "{\"objectId\":\"nope\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.remove_ar_object, "{}"),
    );
}
