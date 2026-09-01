//! Building an Objective-C delegate class at runtime.
//!
//! Three files now need one — the script message handler in `ios.zig`, the
//! `CLLocationManagerDelegate` in `bridge_mobile_location.zig`, and every
//! presented picker (image, document, contact), each of which answers through
//! a did-finish/did-cancel pair. The registration dance is the same every
//! time: `objc_getClass` first so a second call is a no-op, then
//! `objc_allocateClassPair`, then a `class_addMethod` per selector with its
//! type encoding, then `objc_registerClassPair`.
//!
//! ## What this deliberately does not own
//!
//! It does not route callbacks to pending requests. That was tempting and
//! would have been wrong: a location delegate serves a one-shot *and* a
//! running stream simultaneously, a picker is modal and serves exactly one
//! call, and a message handler serves none — it dispatches. Three different
//! lifetimes, and a factory that guessed at one would push the other two into
//! working around it. Each module keeps its own state and its own `ios_async`
//! ticket; this only makes the class exist.
//!
//! It also does not retain the delegate *instance*. `instantiate` returns a
//! +1 object and says so; the caller stores it in a module-level var, because
//! only the caller knows whether the framework holds the delegate weakly
//! (`CLLocationManager` and `UIImagePickerController` both do — a released
//! instance is a crash, not a leak).
//!
//! ## Type encodings, which are the part that fails silently
//!
//! `class_addMethod`'s encoding string is not checked against the IMP. Get it
//! wrong and the method still registers, still gets called, and reads its
//! arguments from the wrong registers. There is no compile error and often no
//! crash — just wrong values. The `enc` helpers below name the shapes these
//! delegates actually use so a caller picks one rather than spelling it.

const std = @import("std");
const builtin = @import("builtin");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;

/// Type encodings for the delegate signatures in use.
///
/// Every Objective-C method takes `self` (`@`) and `_cmd` (`:`) first; the
/// leading character is the return type. Named rather than spelled at call
/// sites because a typo here is invisible until an argument reads as garbage.
pub const enc = struct {
    /// `- (void)m:(id)a` — one object argument.
    pub const void_one_object: [:0]const u8 = "v@:@";
    /// `- (void)m:(id)a :(id)b` — two object arguments. The
    /// did-finish-picking pair and `userContentController:didReceiveScriptMessage:`
    /// are both this shape.
    pub const void_two_objects: [:0]const u8 = "v@:@@";
    /// `- (void)m:(id)a :(id)b :(id)c :(id)d` — four object arguments.
    /// `centralManager:didDiscoverPeripheral:advertisementData:RSSI:` is this
    /// shape, and it is the widest one any delegate here uses. `RSSI:` is an
    /// `NSNumber *`, not a primitive, so it counts as an object like the rest —
    /// getting that wrong would read the signal strength from the wrong
    /// register and report a plausible number.
    pub const void_four_objects: [:0]const u8 = "v@:@@@@";
    /// `- (BOOL)m:(id)a :(id)b` — `application:didFinishLaunchingWithOptions:`.
    ///
    /// `B` is C99 `_Bool`: on 64-bit Apple platforms `__OBJC_BOOL_IS_BOOL` is
    /// defined, so `BOOL` is `bool` rather than `signed char`.
    pub const bool_two_objects: [:0]const u8 = "B@:@@";
};

/// One method to add to a class.
pub const Method = struct {
    /// The selector, e.g. `"imagePickerControllerDidCancel:"`.
    selector: [:0]const u8,
    /// The implementation. Must be an `export fn ... callconv(.c)` whose first
    /// two parameters are `objc.id` (self) and `objc.SEL` (_cmd).
    imp: *const anyopaque,
    /// The type encoding. Use one of `enc`.
    types: [:0]const u8,
};

pub const Error = error{
    UnsupportedPlatform,
    ClassNotFound,
    ClassAllocationFailed,
    MethodNotAdded,
    SelectorNotFound,
    InstantiationFailed,
};

/// Register `name` as a subclass of `superclass_name` carrying `methods`.
///
/// Idempotent: a second call with the same name returns the existing class
/// without touching it. That matters because these registrations happen lazily
/// on first use, and "first use" can be reached from more than one action.
///
/// A partially-built class is not registered. If any `class_addMethod` fails
/// the pair is abandoned rather than registered with a missing method — a
/// class whose delegate method is absent silently does nothing when the
/// framework calls it, which is the failure this whole migration keeps
/// finding.
pub fn defineClass(
    name: [:0]const u8,
    superclass_name: [:0]const u8,
    methods: []const Method,
) Error!objc.Class {
    if (!builtin.target.os.tag.isDarwin()) return Error.UnsupportedPlatform;

    if (objc.objc_getClass(name.ptr)) |existing| return existing;

    const superclass = objc.objc_getClass(superclass_name.ptr) orelse return Error.ClassNotFound;
    const cls = objc.objc_allocateClassPair(superclass, name.ptr, 0) orelse
        return Error.ClassAllocationFailed;

    for (methods) |method| {
        const sel = objc.sel_registerName(method.selector.ptr) orelse return Error.SelectorNotFound;
        const imp: objc.IMP = @ptrCast(@constCast(method.imp));
        if (!objc.class_addMethod(cls, sel, imp, method.types.ptr)) {
            // Deliberately not registered. An unregistered class pair is
            // leaked, which is one allocation for the life of the process and
            // strictly better than a registered class that answers a delegate
            // callback by doing nothing.
            return Error.MethodNotAdded;
        }
    }

    objc.objc_registerClassPair(cls);
    return cls;
}

/// `[[cls alloc] init]`, +1.
///
/// The caller owns the reference and must keep it alive for as long as the
/// framework might call back. Every delegate protocol here is held weakly by
/// its owner, so storing this in a module-level var is not an optimisation —
/// dropping it is a use-after-free the first time the user taps Cancel.
pub fn instantiate(cls: objc.Class) Error!objc.id {
    if (!builtin.target.os.tag.isDarwin()) return Error.UnsupportedPlatform;
    return objc.allocInit(cls) catch Error.InstantiationFailed;
}

const testing = std.testing;

test "a class is registered once and re-registration returns the same class" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const first = try defineClass("CraftDelegateFactoryProbe", "NSObject", &.{});
    const second = try defineClass("CraftDelegateFactoryProbe", "NSObject", &.{});

    // Same pointer, not merely both non-null: a second allocateClassPair for a
    // taken name returns null, so a factory that did not check first would
    // fail on the second call rather than returning what exists.
    try testing.expectEqual(first, second);
    try testing.expect(objc.objc_getClass("CraftDelegateFactoryProbe") != null);
}

test "a method added by the factory is actually reachable by selector" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const S = struct {
        var called: bool = false;
        export fn craftDelegateFactoryProbeMethod(_: objc.id, _: objc.SEL, _: objc.id) void {
            called = true;
        }
    };

    const cls = try defineClass("CraftDelegateFactoryProbe2", "NSObject", &.{
        .{
            .selector = "craftProbe:",
            .imp = @ptrCast(&S.craftDelegateFactoryProbeMethod),
            .types = enc.void_one_object,
        },
    });

    const instance = try instantiate(cls);
    const sel = objc.sel_registerName("craftProbe:") orelse return error.SelectorNotFound;

    // The point of the test: registration is not enough, the runtime has to
    // dispatch to it. A wrong encoding still registers and still dispatches,
    // so this proves reachability rather than correctness of the encoding —
    // which nothing can check but a real call with real arguments.
    objc.msgSendVoid1(instance, sel, @as(objc.id, null));
    try testing.expect(S.called);
}

test "an unknown superclass is refused rather than silently subclassing NSObject" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    try testing.expectError(
        Error.ClassNotFound,
        defineClass("CraftDelegateFactoryProbe3", "NoSuchSuperclassExists", &.{}),
    );
    // And nothing was left half-built under that name.
    try testing.expect(objc.objc_getClass("CraftDelegateFactoryProbe3") == null);
}

test "the encodings name the shapes these delegates actually use" {
    // A typo in an encoding registers fine and reads arguments from the wrong
    // registers — no compile error, often no crash, just wrong values. Naming
    // them is the only defence available, so the names are pinned.
    try testing.expectEqualStrings("v@:@", enc.void_one_object);
    try testing.expectEqualStrings("v@:@@", enc.void_two_objects);
    try testing.expectEqualStrings("v@:@@@@", enc.void_four_objects);
    try testing.expectEqualStrings("B@:@@", enc.bool_two_objects);
}
