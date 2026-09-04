//! The `mobile` namespace's one Sign in with Apple action: `signInWithApple`.
//!
//! Separate from `bridge_mobile_auth.zig`, which owns `authenticate` — that is
//! LocalAuthentication and a biometric prompt, this is AuthenticationServices
//! and an account. They share a word and nothing else.
//!
//! ## Why this one is reachable and `scanQRCode` is not
//!
//! Both were unmigrated with no recorded reason. AuthenticationServices has
//! Objective-C headers — `ASAuthorizationController.h:38` declares
//! `presentationAnchorForAuthorizationController:` — so every class and
//! selector here is reachable from the runtime. VisionKit's `DataScanner` is
//! not: its ObjC headers carry DocumentCamera and nothing else, and its
//! delegate takes a Swift enum with associated values. That one is recorded in
//! the deferral table instead.
//!
//! ## The delegate returns an object, which is new here
//!
//! Every other delegate in this migration is `void`. This one must answer
//! `presentationAnchorForAuthorizationController:` with the `UIWindow` to
//! present over, so `ios_delegate.enc.object_one_object` (`"@@:@"`) was added
//! for it. The leading character of an encoding is the return type; declaring
//! it `v@:@` would have the runtime read a window pointer out of a function
//! that returns nothing.
//!
//! ## The reply
//!
//! `{"userId":…}` always, plus `email`, `name` and `identityToken` only when
//! present — the spec builds the dictionary conditionally and this reproduces
//! that, because a page distinguishing "Apple withheld the email" from
//! `"email": ""` is reading a real difference. `name` is `givenName` and
//! `familyName` joined by a space, omitting whichever is absent, and omitted
//! entirely when both are.
//!
//! Apple sends `email` and `fullName` **only on the first authorization** for
//! an app. Every later sign-in omits them, which is the API's design and not a
//! failure — another reason the fields are omitted rather than emptied.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const ios_delegate = @import("ios_delegate.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();
const BridgeError = bridge_error.BridgeError;

/// `objc.id` spelled locally — see the notifcancel/securestore precedent.
const Id = ?*anyopaque;

pub const A = struct {
    pub const sign_in_with_apple = "signInWithApple";
};

/// `.result`: the spec resolves an object and the page's promise is the
/// untimed legacy kind, so `.none` would strand the caller.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.sign_in_with_apple, .reply = .result },
};

const Route = enum { sign_in };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.sign_in_with_apple)) return .sign_in;
    return null;
}

/// `ASAuthorizationScopeFullName` and `ASAuthorizationScopeEmail`.
///
/// These are `NSString *` constants, not an option set, so they are read with
/// `dlsym` rather than spelled — the route `bridge_mobile_imagepicker.zig`
/// documents for framework string constants. A wrong literal here would be a
/// scope the request silently does not ask for.
const scope_full_name = "ASAuthorizationScopeFullName";
const scope_email = "ASAuthorizationScopeEmail";

pub const AppleAuthBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        _ = data;
        const route = routeFor(action) orelse return BridgeError.UnknownAction;
        switch (route) {
            .sign_in => try self.signInWithApple(),
        }
    }

    /// Build the request and perform it.
    ///
    /// Every fallible step runs before `ios_async.acquire`, so no error path
    /// sits between leasing a slot and handing the controller its delegate.
    fn signInWithApple(self: *Self) !void {
        _ = self;
        if (!is_darwin) return error.UnsupportedPlatform;

        const ProviderClass = objc.objc_getClass("ASAuthorizationAppleIDProvider") orelse
            return BridgeError.PlatformNotSupported;
        const ControllerClass = objc.objc_getClass("ASAuthorizationController") orelse
            return BridgeError.PlatformNotSupported;

        const sel_alloc = objc.sel_registerName("alloc") orelse return error.SelectorNotFound;
        const sel_init = objc.sel_registerName("init") orelse return error.SelectorNotFound;
        const sel_create = objc.sel_registerName("createRequest") orelse return error.SelectorNotFound;
        const sel_scopes = objc.sel_registerName("setRequestedScopes:") orelse return error.SelectorNotFound;
        const sel_init_reqs = objc.sel_registerName("initWithAuthorizationRequests:") orelse
            return error.SelectorNotFound;
        const sel_set_delegate = objc.sel_registerName("setDelegate:") orelse return error.SelectorNotFound;
        const sel_set_ctx = objc.sel_registerName("setPresentationContextProvider:") orelse
            return error.SelectorNotFound;
        const sel_perform = objc.sel_registerName("performRequests") orelse return error.SelectorNotFound;

        const handler = try delegateInstance();

        const provider = objc.msgSendId(objc.msgSendId(ProviderClass, sel_alloc), sel_init);
        if (provider == null) return BridgeError.NativeCallFailed;
        const request = objc.msgSendId(provider, sel_create);
        if (request == null) return BridgeError.NativeCallFailed;

        if (try requestedScopes()) |scopes| objc.msgSendVoid1(request, sel_scopes, scopes);

        const requests = try arrayOf(request);
        const controller = objc.msgSendId1(objc.msgSendId(ControllerClass, sel_alloc), sel_init_reqs, requests);
        if (controller == null) return BridgeError.NativeCallFailed;

        const ticket = ios_async.acquire(A.sign_in_with_apple) orelse return poolFull();
        errdefer ios_async.abandon(ticket);

        objc.msgSendVoid1(controller, sel_set_delegate, handler);
        objc.msgSendVoid1(controller, sel_set_ctx, handler);

        // Published before `performRequests`: the delegate can fire before it
        // returns, and a callback at an empty slot has no ticket to answer.
        publishPending(ticket);
        objc.msgSend(controller, sel_perform);
    }
};

fn poolFull() BridgeError {
    std.log.warn("signInWithApple refused: all {d} async slots in flight", .{ios_async.max_in_flight});
    return BridgeError.InvalidParameter;
}

/// `@[ASAuthorizationScopeFullName, ASAuthorizationScopeEmail]`, or null when
/// neither constant is in the process — in which case the request simply asks
/// for no scopes, which is what an unscoped `createRequest` already does.
fn requestedScopes() !?Id {
    const full = dlsymString(scope_full_name);
    const email = dlsymString(scope_email);
    if (full == null and email == null) return null;

    const NSArray = objc.objc_getClass("NSArray") orelse return null;
    const sel = objc.sel_registerName("arrayWithObjects:count:") orelse return null;
    var items: [2]Id = undefined;
    var n: usize = 0;
    if (full) |f| {
        items[n] = f;
        n += 1;
    }
    if (email) |e| {
        items[n] = e;
        n += 1;
    }
    const Fn = *const fn (Id, objc.SEL, [*]const Id, usize) callconv(.c) Id;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(NSArray, sel, &items, n);
}

fn arrayOf(object: Id) !Id {
    const NSArray = objc.objc_getClass("NSArray") orelse return BridgeError.NativeCallFailed;
    const sel = objc.sel_registerName("arrayWithObject:") orelse return error.SelectorNotFound;
    const result = objc.msgSendId1(NSArray, sel, object);
    if (result == null) return BridgeError.NativeCallFailed;
    return result;
}

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// Read an `NSString *` framework constant. `dlsym` gives the address of the
/// variable, so the pointer has to be dereferenced to get the object.
fn dlsymString(name: [:0]const u8) ?Id {
    if (!is_darwin) return null;
    const addr = dlsym(rtld_default, name.ptr) orelse return null;
    const slot: *const Id = @ptrCast(@alignCast(addr));
    return slot.*;
}
// =============================================================================
// The pending sign-in, and the delegate that answers it.
// =============================================================================

var pending: ?ios_async.Ticket = null;
var pending_mutex: compat_mutex.Mutex = .{};

fn publishPending(ticket: ios_async.Ticket) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending = ticket;
}

/// Read and clear, so a second callback answers nobody rather than twice.
fn takePending() ?ios_async.Ticket {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const t = pending;
    pending = null;
    return t;
}

var delegate: ?Id = null;
const delegate_class_name = "CraftAppleAuthDelegate";

/// One instance, retained for the life of the process.
///
/// `ASAuthorizationController` holds both its `delegate` and its
/// `presentationContextProvider` weakly, so an instance built per call would
/// be gone before the sheet came up.
fn delegateInstance() !Id {
    if (delegate) |existing| return existing;

    const class = ios_delegate.defineClass(delegate_class_name, "NSObject", &.{
        .{
            .selector = "authorizationController:didCompleteWithAuthorization:",
            .imp = @ptrCast(&craftAppleDidComplete),
            .types = ios_delegate.enc.void_two_objects,
        },
        .{
            .selector = "authorizationController:didCompleteWithError:",
            .imp = @ptrCast(&craftAppleDidFail),
            .types = ios_delegate.enc.void_two_objects,
        },
        .{
            .selector = "presentationAnchorForAuthorizationController:",
            .imp = @ptrCast(&craftApplePresentationAnchor),
            .types = ios_delegate.enc.object_one_object,
        },
    }) catch |err| {
        std.log.warn("signInWithApple: could not build the delegate class: {}", .{err});
        return BridgeError.NativeCallFailed;
    };

    delegate = ios_delegate.instantiate(class) catch |err| {
        std.log.warn("signInWithApple: could not instantiate the delegate: {}", .{err});
        return BridgeError.NativeCallFailed;
    };
    return delegate.?;
}

fn craftAppleDidComplete(_: Id, _: objc.SEL, _: Id, authorization: Id) callconv(.c) void {
    if (!is_darwin) return;
    const ticket = takePending() orelse {
        std.log.warn("signInWithApple: an authorization arrived with no call recorded; ignored", .{});
        return;
    };

    const allocator = std.heap.c_allocator;
    const json = shapeCredential(allocator, authorization) catch |err| {
        std.log.err("signInWithApple could not shape its reply ({}); rejecting", .{err});
        ios_async.deliverError(ticket);
        return;
    };
    defer allocator.free(json);
    ios_async.deliverJson(ticket, json);
}

fn craftAppleDidFail(_: Id, _: objc.SEL, _: Id, err: Id) callconv(.c) void {
    if (!is_darwin) return;
    const ticket = takePending() orelse return;

    // 1001 is `ASAuthorizationError.canceled`. The spec rejects every failure
    // with the same localized string, so a page cannot tell a cancel from a
    // real error; a typed code can, and cancel is not a failure to report.
    const code = errorCode(err);
    if (code == as_authorization_error_canceled) {
        ios_async.deliverErrorCode(ticket, BridgeError.Cancelled);
        return;
    }
    std.log.warn("signInWithApple: the authorization failed with code {d}", .{code});
    ios_async.deliverErrorCode(ticket, BridgeError.NativeCallFailed);
}

/// `ASAuthorizationError.canceled`. `ASAuthorizationError.h` — the user
/// dismissed the sheet.
const as_authorization_error_canceled: i64 = 1001;

/// The window the sheet is presented over.
///
/// The spec walks `connectedScenes.first` → `windows.first` and returns a bare
/// `UIWindow()` when that misses. A fresh detached window is not presentable,
/// so that fallback shows nothing; returning nil is the same outcome and does
/// not allocate a window to throw away.
fn craftApplePresentationAnchor(_: Id, _: objc.SEL, _: Id) callconv(.c) Id {
    if (!is_darwin) return null;
    return keyWindow();
}

fn keyWindow() Id {
    const UIApplication = objc.objc_getClass("UIApplication") orelse return null;
    const sel_shared = objc.sel_registerName("sharedApplication") orelse return null;
    const app = objc.msgSendId(UIApplication, sel_shared);
    if (app == null) return null;

    const sel_scenes = objc.sel_registerName("connectedScenes") orelse return null;
    const scenes = objc.msgSendId(app, sel_scenes);
    if (scenes == null) return null;

    const sel_all = objc.sel_registerName("allObjects") orelse return null;
    const list = objc.msgSendId(scenes, sel_all);
    if (list == null) return null;

    const sel_count = objc.sel_registerName("count") orelse return null;
    const CountFn = *const fn (Id, objc.SEL) callconv(.c) usize;
    const count_fn: CountFn = @ptrCast(&objc.objc_msgSend);
    if (count_fn(list, sel_count) == 0) return null;

    const sel_at = objc.sel_registerName("objectAtIndex:") orelse return null;
    const AtFn = *const fn (Id, objc.SEL, usize) callconv(.c) Id;
    const at_fn: AtFn = @ptrCast(&objc.objc_msgSend);
    const scene = at_fn(list, sel_at, 0);

    const sel_windows = objc.sel_registerName("windows") orelse return null;
    const windows = objc.msgSendId(scene, sel_windows);
    if (windows == null) return null;
    if (count_fn(windows, sel_count) == 0) return null;
    return at_fn(windows, sel_at, 0);
}

fn errorCode(err: Id) i64 {
    const e = err orelse return 0;
    const sel = objc.sel_registerName("code") orelse return 0;
    const Fn = *const fn (Id, objc.SEL) callconv(.c) isize;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return @intCast(func(e, sel));
}

// =============================================================================
// Shaping the reply. Split out so the half that decides what the page sees is
// testable on a host with no AuthenticationServices in the process.
// =============================================================================

/// The credential as the page receives it. Absent fields are absent, not empty.
const Credential = struct {
    user_id: []const u8,
    email: ?[]const u8 = null,
    given_name: ?[]const u8 = null,
    family_name: ?[]const u8 = null,
    identity_token: ?[]const u8 = null,
};

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, out, s);
    try out.append(allocator, '"');
}

/// `{"userId":…}` plus whatever else Apple sent.
///
/// `name` is the spec's join: given, then family, separated by a space, with
/// whichever is absent skipped, and the key omitted when the result is empty.
fn appendCredential(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), c: Credential) !void {
    try out.appendSlice(allocator, "{\"userId\":");
    try appendJsonString(allocator, out, c.user_id);

    if (c.email) |e| {
        try out.appendSlice(allocator, ",\"email\":");
        try appendJsonString(allocator, out, e);
    }

    const given = c.given_name orelse "";
    const family = c.family_name orelse "";
    if (given.len != 0 or family.len != 0) {
        try out.appendSlice(allocator, ",\"name\":\"");
        try bridge_error.appendJsonEscaped(allocator, out, given);
        if (given.len != 0 and family.len != 0) try out.append(allocator, ' ');
        try bridge_error.appendJsonEscaped(allocator, out, family);
        try out.append(allocator, '"');
    }

    if (c.identity_token) |t| {
        try out.appendSlice(allocator, ",\"identityToken\":");
        try appendJsonString(allocator, out, t);
    }
    try out.append(allocator, '}');
}

fn shapeCredential(allocator: std.mem.Allocator, authorization: Id) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (!is_darwin or authorization == null) return BridgeError.NativeCallFailed;

    const sel_credential = objc.sel_registerName("credential") orelse return error.SelectorNotFound;
    const credential = objc.msgSendId(authorization, sel_credential);
    if (credential == null) return BridgeError.NativeCallFailed;

    // `as? ASAuthorizationAppleIDCredential` in the spec: a password
    // credential reaches the same delegate and has no `user`.
    const AppleIDCredential = objc.objc_getClass("ASAuthorizationAppleIDCredential") orelse
        return BridgeError.NativeCallFailed;
    const sel_is_kind = objc.sel_registerName("isKindOfClass:") orelse return error.SelectorNotFound;
    const KindFn = *const fn (Id, objc.SEL, Id) callconv(.c) bool;
    const kind_fn: KindFn = @ptrCast(&objc.objc_msgSend);
    if (!kind_fn(credential, sel_is_kind, AppleIDCredential)) return BridgeError.NativeCallFailed;

    const user_id = nsStringValue(credential, "user") orelse return BridgeError.NativeCallFailed;
    const email = nsStringValue(credential, "email");

    const sel_full_name = objc.sel_registerName("fullName") orelse return error.SelectorNotFound;
    const full_name = objc.msgSendId(credential, sel_full_name);
    const given = if (full_name != null) nsStringValue(full_name, "givenName") else null;
    const family = if (full_name != null) nsStringValue(full_name, "familyName") else null;

    const sel_token = objc.sel_registerName("identityToken") orelse return error.SelectorNotFound;
    const token_data = objc.msgSendId(credential, sel_token);
    const token = dataUtf8(token_data);

    try appendCredential(allocator, &out, .{
        .user_id = user_id,
        .email = email,
        .given_name = given,
        .family_name = family,
        .identity_token = token,
    });
    return out.toOwnedSlice(allocator);
}

fn nsStringValue(target: Id, comptime selector: [:0]const u8) ?[]const u8 {
    if (!is_darwin) return null;
    const t = target orelse return null;
    const sel = objc.sel_registerName(selector) orelse return null;
    const ns = objc.msgSendId(t, sel);
    if (ns == null) return null;
    const utf8 = objc.getNSStringUTF8(ns) orelse return null;
    return std.mem.span(utf8);
}

/// The identity token is an `NSData` of JWT bytes; the spec decodes it as
/// UTF-8 and omits the key when that fails.
fn dataUtf8(data: Id) ?[]const u8 {
    if (!is_darwin) return null;
    const d = data orelse return null;
    const sel_bytes = objc.sel_registerName("bytes") orelse return null;
    const sel_length = objc.sel_registerName("length") orelse return null;
    const BytesFn = *const fn (Id, objc.SEL) callconv(.c) ?[*]const u8;
    const bytes_fn: BytesFn = @ptrCast(&objc.objc_msgSend);
    const LenFn = *const fn (Id, objc.SEL) callconv(.c) usize;
    const len_fn: LenFn = @ptrCast(&objc.objc_msgSend);

    const len = len_fn(d, sel_length);
    if (len == 0) return null;
    const ptr = bytes_fn(d, sel_bytes) orelse return null;
    const slice = ptr[0..len];
    return if (std.unicode.utf8ValidateSlice(slice)) slice else null;
}

// =============================================================================
// Tests — host-only. AuthenticationServices is not in this process, so what is
// pinned is everything that decides what the page sees.
// =============================================================================

const testing = std.testing;

test "the declared action is the one the handler serves" {
    try testing.expectEqual(@as(usize, 1), capability_actions.len);
    try testing.expectEqualStrings(A.sign_in_with_apple, capability_actions[0].name);
    try testing.expectEqual(capabilities.Reply.result, capability_actions[0].reply);
    try testing.expectEqual(capabilities.ActionStatus.live, capability_actions[0].status);
    try testing.expect(routeFor(A.sign_in_with_apple) == .sign_in);
    try testing.expect(routeFor("authenticate") == null);
}

test "an action this namespace does not serve is reported, not ignored" {
    var bridge = AppleAuthBridge.init(testing.allocator);
    defer bridge.deinit();
    // `authenticate` belongs to bridge_mobile_auth.zig; claiming it here would
    // make dispatch order decide which implementation a page gets.
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("authenticate", "{}"));
}

test "a first authorization carries everything; a later one carries only the id" {
    const allocator = testing.allocator;

    var first: std.ArrayListUnmanaged(u8) = .empty;
    defer first.deinit(allocator);
    try appendCredential(allocator, &first, .{
        .user_id = "001234.abc",
        .email = "a@b.c",
        .given_name = "Ada",
        .family_name = "Lovelace",
        .identity_token = "ey.J.token",
    });
    try testing.expectEqualStrings(
        "{\"userId\":\"001234.abc\",\"email\":\"a@b.c\",\"name\":\"Ada Lovelace\",\"identityToken\":\"ey.J.token\"}",
        first.items,
    );

    // Apple sends email and fullName only on the *first* authorization for an
    // app; every later one omits them. Absent keys, not empty strings — a page
    // telling "Apple withheld it" from `""` is reading a real difference.
    var later: std.ArrayListUnmanaged(u8) = .empty;
    defer later.deinit(allocator);
    try appendCredential(allocator, &later, .{ .user_id = "001234.abc" });
    try testing.expectEqualStrings("{\"userId\":\"001234.abc\"}", later.items);
}

test "a half-present name joins without a stray space" {
    const allocator = testing.allocator;
    for ([_]struct { g: ?[]const u8, f: ?[]const u8, want: []const u8 }{
        .{ .g = "Ada", .f = null, .want = "{\"userId\":\"u\",\"name\":\"Ada\"}" },
        .{ .g = null, .f = "Lovelace", .want = "{\"userId\":\"u\",\"name\":\"Lovelace\"}" },
        .{ .g = null, .f = null, .want = "{\"userId\":\"u\"}" },
    }) |c| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        try appendCredential(allocator, &out, .{ .user_id = "u", .given_name = c.g, .family_name = c.f });
        try testing.expectEqualStrings(c.want, out.items);
    }
}

test "a name carrying a quote stays valid JSON" {
    const allocator = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try appendCredential(allocator, &out, .{ .user_id = "u", .given_name = "A\"B", .family_name = "C\\D" });

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("A\"B C\\D", parsed.value.object.get("name").?.string);
}

test "the cancel code is the framework's" {
    // `ASAuthorizationError.canceled` = 1001. The spec rejects every failure
    // with the same localized string, so a page cannot tell a dismissal from a
    // real error; this answers CANCELLED for that one.
    try testing.expectEqual(@as(i64, 1001), as_authorization_error_canceled);
}

test "the presentation anchor is object-returning, not void" {
    // The encoding's first character is the return type. Declaring this
    // delegate method `v@:@` would have the runtime read a window pointer out
    // of a function that returns nothing.
    try testing.expectEqualStrings("@@:@", ios_delegate.enc.object_one_object);
    try testing.expect(ios_delegate.enc.object_one_object[0] == '@');
    try testing.expect(ios_delegate.enc.void_one_object[0] == 'v');
}
