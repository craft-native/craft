const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_dispatch = @import("ios_dispatch.zig");
const request_context = @import("request_context.zig");

const objc = objc_runtime.objc;

/// Whether this build can talk to UIKit at all.
///
/// `objc_runtime.zig` degrades `objc` to an empty struct off Darwin, so a
/// reference to `objc.objc_getClass` on a Linux host is a compile error, not a
/// runtime one. Every UIKit call in this file therefore sits behind a
/// *comptime* `if`/`else` — a bare `if (!is_darwin) return error.X;` would not
/// help, because Zig still analyses the code that follows it.
const is_darwin = builtin.target.os.tag.isDarwin();

/// Three system actions the page can ask the OS to perform on its behalf.
///
/// They share one property that separates them from `getDeviceInfo`: none of
/// them can answer immediately and truthfully. `openURL` only learns whether
/// the URL opened when iOS calls back; `share` only learns whether the user
/// picked an activity when the sheet closes; `requestReview` never learns
/// anything at all. The Swift implementations all resolved `true` at the point
/// of asking, before iOS had decided anything — which is the fabricated
/// success this migration exists to stop.
///
/// Two porting decisions are deliberate and are not accidents of translation:
///
/// **`openURL` applies no scheme filter**, matching Swift. `external_link.zig`
/// allows only `http:`/`https:`, but it governs *page-initiated* navigation on
/// content the app does not control; `craft.openURL` is an app-facing call
/// where the app chose the URL, and `tel:`, `mailto:`, `shortcuts://` and
/// custom app schemes are its main use. Filtering here would silently break
/// them.
///
/// **`share` is served unconditionally.** Swift gates it on
/// `config.enableShare` and replies `CAPABILITY_DISABLED`; `ios.zig`'s
/// `AppConfig` has no such field, so Zig cannot reproduce the gate. An app that
/// set `enableShare: false` will now get a share sheet. Restoring the gate
/// means adding the field to `AppConfig`, not adding a guess here.
pub const A = struct {
    pub const open_url = "openURL";
    pub const share = "share";
    pub const request_review = "requestReview";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.open_url, .reply = .result },
    .{ .name = A.share, .reply = .result },
    // Live, but only in a host app that links StoreKit: the framework is
    // resolved by name at runtime, and `objc_getClass` returning null produces
    // an explicit error rather than a silent success. The fixture's link line
    // (`packages/ios/fixtures/zig-slice/build-and-run.sh`) does not carry
    // `-framework StoreKit`, so the simulator harness will see that error until
    // it does.
    .{ .name = A.request_review, .reply = .result },
};

/// The exact reply bodies this file puts on the wire.
///
/// Named rather than written inline at each `sendResultToJS`, so the test that
/// pins their shape reads the same bytes the handlers send instead of a copy
/// of them that can drift. Every one is a JSON *object* carrying a boolean:
/// `craft-bridge.js` resolves with `payload || {}`, so a bare `false` and an
/// empty reply are the same value to the page — a fabricated success wearing
/// the shape of an honest one.
const R = struct {
    const opened = "{\"opened\":true}";
    const not_opened = "{\"opened\":false}";
    const completed = "{\"completed\":true}";
    const not_completed = "{\"completed\":false}";
    const requested = "{\"requested\":true}";

    const all = [_][]const u8{ opened, not_opened, completed, not_completed, requested };
};

pub const SystemBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.open_url)) {
            try self.openURL(data);
        } else if (std.mem.eql(u8, action, A.share)) {
            try self.share(data);
        } else if (std.mem.eql(u8, action, A.request_review)) {
            try self.requestReview();
        } else {
            return bridge_error.BridgeError.UnknownAction;
        }
    }

    /// `craft.openURL(url)` — hand a URL to iOS and report what iOS did with it.
    ///
    /// The reply is sent from the completion handler, not from here, so this
    /// function returning is *not* the call being answered. That is the whole
    /// difference from the Swift version, which resolved `true` before
    /// `open:` had decided anything and so reported success for an unhandled
    /// scheme.
    fn openURL(self: *Self, data: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return bridge_error.BridgeError.InvalidJSON;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return bridge_error.BridgeError.InvalidJSON,
        };

        // `url`, top level — the page's `openURL` posts it flat, not under
        // `options`. Swift's `if let` fell through when it was absent and never
        // settled the callback at all, leaving the page's promise to time out
        // with nothing to point at.
        const url = try stringField(root, "url");
        if (url.len == 0) return bridge_error.BridgeError.MissingData;

        try uikit.openURL(self.allocator, url, capturedRequestId());
    }

    /// `craft.share(text)` and `craft.share.share(options)` — the same action,
    /// two payload shapes, both of which have live callers.
    fn share(self: *Self, data: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch
            return bridge_error.BridgeError.InvalidJSON;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return bridge_error.BridgeError.InvalidJSON,
        };

        // The strings borrow `parsed`'s arena, which outlives this call: the
        // sheet is built and presented before `parsed.deinit()` runs, and
        // UIKit has copied everything it needs into NSStrings by then.
        var request = try parseShareRequest(self.allocator, root);
        defer request.deinit(self.allocator);

        try uikit.share(self.allocator, request, capturedRequestId());
    }

    /// `craft.requestReview()` — ask StoreKit to consider showing the rating
    /// prompt.
    ///
    /// Takes no payload; `ios_dispatch.payloadOf` hands this handler `"{}"` and
    /// there is nothing in it to read.
    fn requestReview(self: *Self) !void {
        try uikit.requestReview(self.allocator);
    }
};

/// The id of the call being served, frozen as a plain integer.
///
/// `request_context` is a threadlocal stack that `ios_dispatch.handleMessage`
/// pops on return, so a completion handler firing later sees it empty and
/// `sendResultToJS` would stamp the reply `id = null`. A null id sends the
/// reply down `craft-bridge.js`'s action-name FIFO instead of to the waiting
/// promise, which hands one caller's answer to another whenever two shares are
/// in flight. `handOffToHost` solves the same problem the same way, including
/// the negative sentinel for "the page sent no id".
fn capturedRequestId() i64 {
    return if (request_context.current()) |id| @intCast(id) else -1;
}

/// A string field, or `""` when the page did not send one.
///
/// A wrong *type* is an error rather than a miss: quietly treating
/// `{"url": 42}` as absent is how a payload field goes missing and the caller
/// is told everything went fine.
fn stringField(obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const v = obj.get(name) orelse return "";
    return switch (v) {
        .string => |s| s,
        // `JSON.stringify` keeps an explicit null where it drops an undefined,
        // so null is the page saying "no value", not a type error.
        .null => "",
        else => bridge_error.BridgeError.InvalidParameter,
    };
}

/// What the page wants to share, in the order `UIActivityViewController` must
/// receive it.
///
/// The order is load-bearing: an activity decides what it gets from the type
/// and position of each item, so title-then-text-then-url-then-files is the
/// behaviour being ported, not an arbitrary field ordering.
pub const ShareRequest = struct {
    title: []const u8 = "",
    text: []const u8 = "",
    url: []const u8 = "",
    files: []const []const u8 = &.{},

    /// Frees the `files` slice. The strings themselves belong to the JSON
    /// arena the request was parsed from.
    pub fn deinit(self: *ShareRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.files);
        self.files = &.{};
    }
};

/// Read a `share` payload in either of the two shapes that reach it.
///
/// `craft.share.share(options)` goes through `_invoke`, which nests everything
/// one level under `options`. The legacy `craft.share(text)` posts `text` flat
/// and is still live in the injected script. Reading only one of them breaks
/// the other half of the callers — the same field-name mismatch that had
/// `craft.fs.writeFile` writing empty files.
///
/// Where this is deliberately wider than Swift: when there is no `options`,
/// Swift rebuilds the payload as `["text": text]` and drops any `url`, `title`
/// or `files` that were sent alongside. Here the top-level object is read
/// whole. Nothing that works today stops working, and a field the page sent is
/// not thrown away.
///
/// Empty strings are skipped rather than shared, so `share({text: ''})` is
/// "nothing to share" and not an empty sheet.
pub fn parseShareRequest(allocator: std.mem.Allocator, root: std.json.ObjectMap) !ShareRequest {
    const source: std.json.ObjectMap = if (root.get("options")) |v| switch (v) {
        .object => |o| o,
        else => root,
    } else root;

    var request = ShareRequest{
        .title = try stringField(source, "title"),
        .text = try stringField(source, "text"),
        .url = try stringField(source, "url"),
    };

    if (source.get("files")) |v| switch (v) {
        .array => |entries| {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer list.deinit(allocator);
            for (entries.items) |entry| switch (entry) {
                .string => |s| if (s.len > 0) try list.append(allocator, s),
                // `files` is declared `string[]`. A non-string element is the
                // caller getting the type wrong, and saying so beats sharing a
                // shorter list than was asked for.
                else => return bridge_error.BridgeError.InvalidParameter,
            };
            request.files = try list.toOwnedSlice(allocator);
        },
        .null => {},
        else => return bridge_error.BridgeError.InvalidParameter,
    };
    errdefer request.deinit(allocator);

    // Swift's "Nothing to share" / INVALID_ARGUMENT. Checked here so an
    // obviously empty request fails before any UIKit object is built; the
    // authoritative check is on the assembled item array, because a `files`
    // entry that names nothing on disk contributes no item.
    if (request.title.len == 0 and request.text.len == 0 and
        request.url.len == 0 and request.files.len == 0)
    {
        return bridge_error.BridgeError.InvalidParameter;
    }

    return request;
}

// =============================================================================
// Objective-C block layouts
//
// `{ isa, flags, reserved, invoke, descriptor }` is the ABI every block on
// Apple platforms has; `_NSConcreteStackBlock` is the symbol the isa points at
// for a block that starts life on the stack. Same shape `bridge_permissions.zig`
// and `macos.zig` already hand to AppKit, with one addition: a trailing capture.
//
// The existing two are capture-free statics, which cannot carry a request id —
// and without the id an async reply cannot name the call it answers. A capture
// is just a field appended after `descriptor`, with `descriptor.size` grown to
// match: `_Block_copy` memcpys exactly that many bytes onto the heap and
// retargets `isa` to `_NSConcreteMallocBlock`. `flags = 0` (no
// `BLOCK_HAS_COPY_DISPOSE`) is right for a plain integer capture, which needs
// no copy/dispose helpers.
//
// The blocks are built on the handler's stack because both callees —
// `openURL:options:completionHandler:` and `setCompletionWithItemsHandler:` —
// copy the block before returning.
//
// The pointer fields are written `?*anyopaque` rather than `objc.id` even
// though `objc_runtime.zig:32` defines them as the same type, so these layouts
// still compile on a host where `objc` is an empty struct.
// =============================================================================

const BlockDescriptor = extern struct {
    reserved: usize = 0,
    size: usize,
};

extern var _NSConcreteStackBlock: anyopaque;

/// `void (^)(BOOL success)` — what `openURL:options:completionHandler:` calls.
const OpenURLBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*const anyopaque, bool) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    /// The captured `i` of the call this answers; negative for "the page sent
    /// none". `invoke` is handed a pointer to the block itself, so it reads
    /// this back out of its own storage.
    request_id: i64,
};

const open_url_block_descriptor = BlockDescriptor{ .size = @sizeOf(OpenURLBlock) };

/// `void (^)(UIActivityType, BOOL completed, NSArray *, NSError *)` — what
/// `UIActivityViewController.completionWithItemsHandler` calls.
const ShareBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*const anyopaque, ?*anyopaque, bool, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    request_id: i64,
};

const share_block_descriptor = BlockDescriptor{ .size = @sizeOf(ShareBlock) };

/// Deliver `json` as the answer to `request_id`, from outside any dispatch.
///
/// The dispatch frame is long gone by the time a completion handler runs, so
/// the id is pushed back before replying and popped after — the shape
/// `craft_ios_deliver_result` already uses. The allocator is
/// `std.heap.c_allocator` and not the bridge's, for the same reason: the
/// `SystemBridge` that started this call was destroyed when `handleMessage`
/// returned.
fn replyFromCallback(request_id: i64, action: []const u8, json: []const u8) void {
    request_context.push(if (request_id < 0) null else @intCast(request_id));
    defer request_context.pop();
    bridge_error.sendResultToJS(std.heap.c_allocator, action, json);
}

fn failFromCallback(request_id: i64, action: []const u8, err: bridge_error.BridgeError) void {
    request_context.push(if (request_id < 0) null else @intCast(request_id));
    defer request_context.pop();
    bridge_error.sendErrorToJS(std.heap.c_allocator, action, err);
}

// =============================================================================
// UIKit
// =============================================================================

/// Everything that touches UIKit, selected at comptime.
///
/// The non-Darwin arm is not a stub that pretends to work — it returns
/// `error.UnsupportedPlatform`, which `ios_dispatch.asBridgeError` turns into
/// `PLATFORM_NOT_SUPPORTED` for the page.
pub const uikit = if (is_darwin) struct {
    /// `[[UIApplication sharedApplication] openURL:options:completionHandler:]`
    ///
    /// The modern three-argument selector, never the deprecated one-argument
    /// `openURL:` — that one returns `BOOL` synchronously and casting
    /// `objc_msgSend` to the wrong shape is a runtime crash, not a compile
    /// error.
    ///
    /// No `canOpenURL:` pre-check: it answers `NO` for any custom scheme the
    /// app has not listed in `LSApplicationQueriesSchemes`, so gating on it
    /// would refuse URLs that `open:` would in fact have opened. The completion
    /// handler's BOOL is the only truthful answer available.
    fn openURL(allocator: std.mem.Allocator, url_string: []const u8, request_id: i64) !void {
        const UIApplication = objc.objc_getClass("UIApplication") orelse return error.ClassNotFound;
        const sel_shared = objc.sel_registerName("sharedApplication") orelse return error.SelectorNotFound;
        const app = objc.msgSendId(UIApplication, sel_shared);
        if (app == null) return error.NoApplication;

        // `+[NSURL URLWithString:]` returns nil for a string it cannot parse.
        // Swift hit the same nil and then settled nothing at all.
        const url = try objc.createNSURL(url_string, allocator);
        if (url == null) return bridge_error.BridgeError.InvalidParameter;

        // `options:` is declared nonnull; an empty dictionary is the documented
        // way to pass no options.
        const NSDictionary = objc.objc_getClass("NSDictionary") orelse return error.ClassNotFound;
        const sel_dictionary = objc.sel_registerName("dictionary") orelse return error.SelectorNotFound;
        const options = objc.msgSendId(NSDictionary, sel_dictionary);
        if (options == null) return error.NativeCallFailed;

        const sel_open = objc.sel_registerName("openURL:options:completionHandler:") orelse
            return error.SelectorNotFound;

        var block = OpenURLBlock{
            .isa = &_NSConcreteStackBlock,
            .flags = 0,
            .reserved = 0,
            .invoke = openURLDidFinish,
            .descriptor = &open_url_block_descriptor,
            .request_id = request_id,
        };

        const Fn = *const fn (objc.id, objc.SEL, objc.id, objc.id, objc.id) callconv(.c) void;
        const func: Fn = @ptrCast(&objc.objc_msgSend);
        func(app, sel_open, url, options, @as(objc.id, @ptrCast(&block)));
    }

    fn openURLDidFinish(block: *const anyopaque, opened: bool) callconv(.c) void {
        const self: *const OpenURLBlock = @ptrCast(@alignCast(block));
        replyFromCallback(self.request_id, A.open_url, if (opened) R.opened else R.not_opened);
    }

    /// Build the activity items, present the sheet, and answer when it closes.
    fn share(allocator: std.mem.Allocator, request: ShareRequest, request_id: i64) !void {
        const NSMutableArray = objc.objc_getClass("NSMutableArray") orelse return error.ClassNotFound;
        const sel_array = objc.sel_registerName("array") orelse return error.SelectorNotFound;
        const sel_add = objc.sel_registerName("addObject:") orelse return error.SelectorNotFound;

        const items = objc.msgSendId(NSMutableArray, sel_array);
        if (items == null) return error.NativeCallFailed;

        if (request.title.len > 0) try addString(allocator, items, sel_add, request.title);
        if (request.text.len > 0) try addString(allocator, items, sel_add, request.text);
        if (request.url.len > 0) {
            // The same condition `openURL` refuses, refused the same way. Swift
            // dropped an unparseable `url` and shared whatever else was in the
            // request, so a caller who asked to share a link got a sheet with
            // only its text and was told the share completed — a payload field
            // silently discarded under a success.
            const url = try objc.createNSURL(request.url, allocator);
            if (url == null) return bridge_error.BridgeError.InvalidParameter;
            objc.msgSendVoid1(items, sel_add, url);
        }
        if (request.files.len > 0) try appendFiles(allocator, items, sel_add, request.files);

        // The authoritative "Nothing to share": a `files` entry that is neither
        // a file URL nor an existing path contributes no item, so a request
        // that looked non-empty on the way in can still assemble to nothing.
        // An empty sheet is not the answer — an error is.
        const sel_count = objc.sel_registerName("count") orelse return error.SelectorNotFound;
        const CountFn = *const fn (objc.id, objc.SEL) callconv(.c) c_ulong;
        const count_fn: CountFn = @ptrCast(&objc.objc_msgSend);
        if (count_fn(items, sel_count) == 0) return bridge_error.BridgeError.InvalidParameter;

        // Resolved before the controller is built so a missing presenter is an
        // error rather than a leaked, never-presented view controller.
        const presenter = try topmostViewController();

        const UIActivityViewController = objc.objc_getClass("UIActivityViewController") orelse
            return error.ClassNotFound;
        const allocated = try objc.alloc(UIActivityViewController);
        const sel_init = objc.sel_registerName("initWithActivityItems:applicationActivities:") orelse
            return error.SelectorNotFound;
        const InitFn = *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.id;
        const init_fn: InitFn = @ptrCast(&objc.objc_msgSend);
        const activity_vc = init_fn(allocated, sel_init, items, null);
        if (activity_vc == null) return error.NativeCallFailed;
        // `alloc` gave us +1. The presenting controller retains the sheet for
        // the life of the presentation, so ours is the reference to drop —
        // and on the error paths below it is the only one there is.
        defer objc.release(activity_vc);

        var block = ShareBlock{
            .isa = &_NSConcreteStackBlock,
            .flags = 0,
            .reserved = 0,
            .invoke = shareDidFinish,
            .descriptor = &share_block_descriptor,
            .request_id = request_id,
        };
        const sel_set_handler = objc.sel_registerName("setCompletionWithItemsHandler:") orelse
            return error.SelectorNotFound;
        objc.msgSendVoid1(activity_vc, sel_set_handler, @as(objc.id, @ptrCast(&block)));

        try anchorPopover(activity_vc, presenter);

        const sel_present = objc.sel_registerName("presentViewController:animated:completion:") orelse
            return error.SelectorNotFound;
        const PresentFn = *const fn (objc.id, objc.SEL, objc.id, bool, objc.id) callconv(.c) void;
        const present_fn: PresentFn = @ptrCast(&objc.objc_msgSend);
        present_fn(presenter, sel_present, activity_vc, true, null);
    }

    /// `[items addObject:@"…"]`, refusing rather than passing nil.
    ///
    /// `+[NSString stringWithUTF8String:]` answers nil for bytes that are not
    /// valid UTF-8, and `-[NSMutableArray addObject:]` raises
    /// `NSInvalidArgumentException` on nil. That is an ObjC exception, so from
    /// Zig it is an uncatchable crash rather than something the page can be
    /// told about — which is why this is a check and not a comment.
    fn addString(allocator: std.mem.Allocator, items: objc.id, sel_add: objc.SEL, s: []const u8) !void {
        const ns = try objc.createNSString(s, allocator);
        if (ns == null) return bridge_error.BridgeError.InvalidParameter;
        objc.msgSendVoid1(items, sel_add, ns);
    }

    /// Turn each `files` entry into an NSURL the way Swift does: a string that
    /// parses as a file URL is used as-is, otherwise a file that exists at that
    /// literal path becomes a `fileURLWithPath:`.
    ///
    /// An entry that is neither is dropped, matching Swift. Unlike a `url` the
    /// page sent that will not parse, which is refused, this is a fact about
    /// the filesystem rather than about the payload — the path is well-formed
    /// and simply names nothing. The caller finds out only when *every* item
    /// was dropped and there was nothing else to share, because that is what
    /// the count check below catches. A files-plus-text request that loses its
    /// files still reports the share completed, which is the one place this
    /// file knowingly keeps Swift's silence; changing it means deciding whether
    /// a stale path should fail an otherwise valid share.
    fn appendFiles(
        allocator: std.mem.Allocator,
        items: objc.id,
        sel_add: objc.SEL,
        files: []const []const u8,
    ) !void {
        const NSURL = objc.objc_getClass("NSURL") orelse return error.ClassNotFound;
        const NSFileManager = objc.objc_getClass("NSFileManager") orelse return error.ClassNotFound;
        const sel_default_manager = objc.sel_registerName("defaultManager") orelse return error.SelectorNotFound;
        const sel_exists = objc.sel_registerName("fileExistsAtPath:") orelse return error.SelectorNotFound;
        const sel_is_file_url = objc.sel_registerName("isFileURL") orelse return error.SelectorNotFound;
        const sel_file_url = objc.sel_registerName("fileURLWithPath:") orelse return error.SelectorNotFound;

        const file_manager = objc.msgSendId(NSFileManager, sel_default_manager);
        if (file_manager == null) return error.NativeCallFailed;

        const ExistsFn = *const fn (objc.id, objc.SEL, objc.id) callconv(.c) bool;
        const exists_fn: ExistsFn = @ptrCast(&objc.objc_msgSend);

        for (files) |path| {
            const as_url: objc.id = objc.createNSURL(path, allocator) catch null;
            if (as_url != null and objc.msgSendBool(as_url, sel_is_file_url)) {
                objc.msgSendVoid1(items, sel_add, as_url);
                continue;
            }

            const ns_path = try objc.createNSString(path, allocator);
            if (!exists_fn(file_manager, sel_exists, ns_path)) continue;

            const file_url = objc.msgSendId1(NSURL, sel_file_url, ns_path);
            if (file_url != null) objc.msgSendVoid1(items, sel_add, file_url);
        }
    }

    /// Give the sheet an anchor before it is presented.
    ///
    /// On a regular size class — every iPad, and iPhone in some multitasking
    /// configurations — `UIActivityViewController` presents as a popover, and
    /// UIKit raises `NSGenericException` from `-viewWillAppear:` if neither
    /// `sourceView` nor `barButtonItem` is set. That is an ObjC exception, so
    /// from Zig it is an uncatchable crash. The Swift implementation sets
    /// neither and crashes on iPad today.
    ///
    /// `popoverPresentationController` is nil when UIKit did not choose a
    /// popover (iPhone), so the whole block is skipped there rather than
    /// guessed at. The rect is centred and `permittedArrowDirections` is set to
    /// 0 — the *empty* `UIPopoverArrowDirection` option set, Swift's `[]`, which
    /// draws no arrow. It is emphatically not `UIPopoverArrowDirectionUnknown`,
    /// which is `NSUIntegerMax`: passing that would permit every direction and
    /// point an arrow at the middle of the screen.
    pub fn anchorPopover(activity_vc: objc.id, presenter: objc.id) !void {
        const sel_popover = objc.sel_registerName("popoverPresentationController") orelse
            return error.SelectorNotFound;
        const popover = objc.msgSendId(activity_vc, sel_popover);
        if (popover == null) return;

        const sel_view = objc.sel_registerName("view") orelse return error.SelectorNotFound;
        const host_view = objc.msgSendId(presenter, sel_view);
        if (host_view == null) return error.NoPresenterView;

        const sel_set_source_view = objc.sel_registerName("setSourceView:") orelse
            return error.SelectorNotFound;
        objc.msgSendVoid1(popover, sel_set_source_view, host_view);

        const sel_bounds = objc.sel_registerName("bounds") orelse return error.SelectorNotFound;
        const BoundsFn = *const fn (objc.id, objc.SEL) callconv(.c) objc.CGRect;
        const bounds_fn: BoundsFn = @ptrCast(&objc.objc_msgSend);
        const bounds = bounds_fn(host_view, sel_bounds);

        const sel_set_source_rect = objc.sel_registerName("setSourceRect:") orelse
            return error.SelectorNotFound;
        const RectFn = *const fn (objc.id, objc.SEL, objc.CGRect) callconv(.c) void;
        const rect_fn: RectFn = @ptrCast(&objc.objc_msgSend);
        rect_fn(popover, sel_set_source_rect, .{
            .origin = .{ .x = bounds.size.width / 2, .y = bounds.size.height / 2 },
            .size = .{ .width = 0, .height = 0 },
        });

        const sel_set_arrows = objc.sel_registerName("setPermittedArrowDirections:") orelse
            return error.SelectorNotFound;
        const ArrowFn = *const fn (objc.id, objc.SEL, c_ulong) callconv(.c) void;
        const arrow_fn: ArrowFn = @ptrCast(&objc.objc_msgSend);
        arrow_fn(popover, sel_set_arrows, 0);
    }

    fn shareDidFinish(
        block: *const anyopaque,
        _: ?*anyopaque,
        completed: bool,
        _: ?*anyopaque,
        activity_error: ?*anyopaque,
    ) callconv(.c) void {
        const self: *const ShareBlock = @ptrCast(@alignCast(block));

        // An NSError from the activity is a failure, not a `completed:false`.
        // Resolving it would make the page's promise succeed with a
        // share that did not happen, and the app's catch block never runs.
        if (activity_error != null) {
            failFromCallback(self.request_id, A.share, bridge_error.BridgeError.NativeCallFailed);
            return;
        }

        replyFromCallback(self.request_id, A.share, if (completed) R.completed else R.not_completed);
    }

    /// `+[SKStoreReviewController requestReviewInScene:]`
    ///
    /// The reply says `requested`, not `shown`, because "shown" is a question
    /// the API cannot answer: the selector returns void and calls nothing back,
    /// and iOS suppresses the prompt on its own terms — roughly three per user
    /// per year, never in TestFlight, and off entirely if the user disabled it
    /// in Settings. `{"requested":true}` is the strongest true statement
    /// available. Anything that fails before the call is an error, never
    /// `{"requested":false}` dressed up as a success — which is what Swift did,
    /// resolving `true` from outside the `DispatchQueue.main.async` block that
    /// had not run yet and might have found no scene when it did.
    fn requestReview(allocator: std.mem.Allocator) !void {
        // StoreKit first, scene second. Both are required and either can be the
        // reason this cannot run, but only one of them is a *build* problem: an
        // app that has not linked the framework has to be told that, not sent
        // looking for a window scene it already has. Ordering is the only thing
        // that decides which of the two errors the page is given.
        const SKStoreReviewController = objc.objc_getClass("SKStoreReviewController") orelse
            return error.StoreKitNotLinked;

        // `sel_registerName` registers a selector whether or not anything
        // implements it, so it is not a guard. `requestReviewInScene:` is
        // deprecated as of iOS 18 in favour of `AppStore.requestReview(in:)`,
        // which is a SwiftUI environment action with no Objective-C
        // counterpart and so is unreachable from here. When a future SDK drops
        // the deprecated method this must fail loudly, not crash.
        const sel_request = objc.sel_registerName("requestReviewInScene:") orelse
            return error.SelectorNotFound;
        const sel_responds = objc.sel_registerName("respondsToSelector:") orelse
            return error.SelectorNotFound;
        const RespondsFn = *const fn (objc.id, objc.SEL, objc.SEL) callconv(.c) bool;
        const responds_fn: RespondsFn = @ptrCast(&objc.objc_msgSend);
        if (!responds_fn(SKStoreReviewController, sel_responds, sel_request)) {
            return error.ReviewPromptUnavailable;
        }

        const scene = try keyWindowScene();

        const Fn = *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void;
        const func: Fn = @ptrCast(&objc.objc_msgSend);
        func(SKStoreReviewController, sel_request, scene);

        // Synchronous: there is no callback to wait for, so the dispatch frame
        // is still live and `sendResultToJS` stamps the right id by itself.
        bridge_error.sendResultToJS(allocator, A.request_review, R.requested);
    }

    /// The view controller a modal should be presented from.
    ///
    /// Reached through the webview rather than `connectedScenes`: the webview
    /// is already held by `ios_dispatch`, `[[webview window] rootViewController]`
    /// is two messages instead of six, and it works the same in a pure-Zig app
    /// and in a Swift-hosted app that registered its webview. Every nil on the
    /// way is a real condition and gets its own error — a skipped presentation
    /// would leave the page's promise unsettled forever.
    ///
    /// The walk up `presentedViewController` is the part Swift is missing:
    /// presenting on a controller that is already presenting something logs
    /// "which is already presenting" and silently does nothing, so the
    /// completion handler never fires and the caller waits out its timeout.
    pub fn topmostViewController() !objc.id {
        // One `orelse`, not an `orelse` plus a null check. `getWebView` used to
        // answer a double optional, so the `orelse` unwrapped the outer level
        // and the second line was the guard that actually ran; now the slot is
        // a single `objc.id` and this catches both spellings of "no webview".
        const webview = ios_dispatch.getWebView() orelse
            return bridge_error.BridgeError.WebViewHandleNotSet;

        const sel_window = objc.sel_registerName("window") orelse return error.SelectorNotFound;
        const window = objc.msgSendId(webview, sel_window);
        if (window == null) return error.NoWindow;

        const sel_root = objc.sel_registerName("rootViewController") orelse return error.SelectorNotFound;
        var vc = objc.msgSendId(window, sel_root);
        if (vc == null) return error.NoRootViewController;

        const sel_presented = objc.sel_registerName("presentedViewController") orelse
            return error.SelectorNotFound;
        // Bounded: a cycle in the presentation chain should hang nothing.
        var hops: usize = 0;
        while (hops < 32) : (hops += 1) {
            const next = objc.msgSendId(vc, sel_presented);
            if (next == null) break;
            vc = next;
        }
        return vc;
    }

    /// The `UIWindowScene` the app's window belongs to.
    ///
    /// craft builds a classic `UIWindow` with `initWithFrame:` and declares no
    /// `UIApplicationSceneManifest`, so whether iOS attaches an implicit scene
    /// to it has not been verified on a device. If it did not, `windowScene` is
    /// nil and that is reported — it is not a reason to fall back to the
    /// pre-iOS-14 `+requestReview`, which is deprecated and may be gone, and it
    /// is certainly not a reason to reply success having done nothing.
    fn keyWindowScene() !objc.id {
        // One `orelse`, not an `orelse` plus a null check. `getWebView` used to
        // answer a double optional, so the `orelse` unwrapped the outer level
        // and the second line was the guard that actually ran; now the slot is
        // a single `objc.id` and this catches both spellings of "no webview".
        const webview = ios_dispatch.getWebView() orelse
            return bridge_error.BridgeError.WebViewHandleNotSet;

        const sel_window = objc.sel_registerName("window") orelse return error.SelectorNotFound;
        const window = objc.msgSendId(webview, sel_window);
        if (window == null) return error.NoWindow;

        const sel_scene = objc.sel_registerName("windowScene") orelse return error.SelectorNotFound;
        const scene = objc.msgSendId(window, sel_scene);
        if (scene == null) return error.NoWindowScene;
        return scene;
    }
} else struct {
    fn openURL(_: std.mem.Allocator, _: []const u8, _: i64) !void {
        return error.UnsupportedPlatform;
    }
    fn share(_: std.mem.Allocator, _: ShareRequest, _: i64) !void {
        return error.UnsupportedPlatform;
    }
    fn requestReview(_: std.mem.Allocator) !void {
        return error.UnsupportedPlatform;
    }
};

// =============================================================================
// Tests
//
// Host-only. Nothing here presents a sheet, opens a URL, or asks for a review;
// the payload shapes and the action table are what a host can check, and they
// are where the bugs being ported around actually lived.
// =============================================================================

const testing = std.testing;

/// Parse `json` and hand its root object to `parseShareRequest`.
///
/// The arena has to outlive the request, whose strings borrow it, so the caller
/// gets both back and frees them together.
fn shareRequestFrom(json: []const u8) !struct {
    parsed: std.json.Parsed(std.json.Value),
    request: ShareRequest,

    fn deinit(self: *@This()) void {
        self.request.deinit(testing.allocator);
        self.parsed.deinit();
    }
} {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    errdefer parsed.deinit();
    return .{ .parsed = parsed, .request = try parseShareRequest(testing.allocator, parsed.value.object) };
}

test "every declared action is one the handler serves" {
    try testing.expectEqual(@as(usize, 3), capability_actions.len);
    try testing.expectEqualStrings(A.open_url, capability_actions[0].name);
    try testing.expectEqualStrings(A.share, capability_actions[1].name);
    try testing.expectEqualStrings(A.request_review, capability_actions[2].name);
    for (capability_actions) |decl| {
        // All three answer a waiting caller. An action declared `.result` whose
        // handler never replies parks the page until its timeout, and a `.none`
        // that a caller awaits resolves immediately and means nothing.
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }

    // And the dispatcher agrees. The payloads are ones that fail before any
    // UIKit object is touched, so this is a routing check and not a device
    // test: `openURL` has no url, `share` has nothing to share, and
    // `requestReview` finds no webview registered on the host.
    var bridge = SystemBridge.init(testing.allocator);
    defer bridge.deinit();
    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != bridge_error.BridgeError.UnknownAction);
            continue;
        };
        // None of these can succeed on a host, so reaching here means a handler
        // reported success without doing anything.
        try testing.expect(false);
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = SystemBridge.init(testing.allocator);
    defer bridge.deinit();

    for ([_][]const u8{ "openurl", "openUrl", "sharing", "review", "" }) |action| {
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(action, "{}"),
        );
    }
}

test "openURL without a url reports it rather than settling nothing" {
    // Swift's `if let` fell through here and never resolved or rejected the
    // callback, so the page waited out a 30-second timeout with no cause to
    // report. Silence is the one answer ruled out.
    var bridge = SystemBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(bridge_error.BridgeError.MissingData, bridge.handleMessage(A.open_url, "{}"));
    try testing.expectError(
        bridge_error.BridgeError.MissingData,
        bridge.handleMessage(A.open_url, "{\"url\":\"\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.open_url, "{\"url\":42}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.open_url, "not json"),
    );
}

test "the url is read from the top level, which is where the page puts it" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"url\":\"tel:+15551234\",\"callbackId\":\"cb_1\"}",
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("tel:+15551234", try stringField(parsed.value.object, "url"));
}

test "share reads the nested options the SDK sends" {
    var got = try shareRequestFrom(
        \\{"options":{"title":"T","text":"X","url":"https://e.com","files":["/a","/b"]}}
    );
    defer got.deinit();

    try testing.expectEqualStrings("T", got.request.title);
    try testing.expectEqualStrings("X", got.request.text);
    try testing.expectEqualStrings("https://e.com", got.request.url);
    try testing.expectEqual(@as(usize, 2), got.request.files.len);
    try testing.expectEqualStrings("/a", got.request.files[0]);
    try testing.expectEqualStrings("/b", got.request.files[1]);
}

test "share still reads the flat text the legacy call sends" {
    // `craft.share('hello')` is live in the injected script and posts `text` at
    // the top level with no `options` wrapper. Reading only the nested shape
    // would break it silently, which is the `craft.fs.writeFile` failure.
    var got = try shareRequestFrom("{\"text\":\"hello\"}");
    defer got.deinit();

    try testing.expectEqualStrings("hello", got.request.text);
    try testing.expectEqualStrings("", got.request.title);
    try testing.expectEqual(@as(usize, 0), got.request.files.len);
}

test "a flat payload keeps every field it sent, not just text" {
    // Wider than Swift, which rebuilds the payload as `["text": text]` and
    // throws the rest away. Nothing that works today changes; a field the page
    // sent is not dropped on the floor.
    var got = try shareRequestFrom("{\"text\":\"X\",\"url\":\"https://e.com\"}");
    defer got.deinit();

    try testing.expectEqualStrings("X", got.request.text);
    try testing.expectEqualStrings("https://e.com", got.request.url);
}

test "an empty string is not something to share" {
    // `!title.isEmpty` / `!text.isEmpty` in Swift. Without it, `share({text:''})`
    // presents an empty sheet instead of telling the caller it asked for
    // nothing.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"options\":{\"text\":\"\",\"title\":\"\",\"url\":\"\",\"files\":[]}}",
        .{},
    );
    defer parsed.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseShareRequest(testing.allocator, parsed.value.object),
    );
}

test "an empty options object is nothing to share, not an empty sheet" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"options\":{}}",
        .{},
    );
    defer parsed.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseShareRequest(testing.allocator, parsed.value.object),
    );
}

test "a files entry of the wrong type is refused, not quietly skipped" {
    // `files` is declared `string[]`. Sharing a shorter list than was asked for
    // and calling it success is the bug class this file is being written to
    // avoid.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"options\":{\"files\":[\"/a\",7]}}",
        .{},
    );
    defer parsed.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        parseShareRequest(testing.allocator, parsed.value.object),
    );
}

test "an explicit null is the page sending no value, not a type error" {
    var got = try shareRequestFrom("{\"options\":{\"text\":\"X\",\"url\":null,\"files\":null}}");
    defer got.deinit();

    try testing.expectEqualStrings("X", got.request.text);
    try testing.expectEqualStrings("", got.request.url);
    try testing.expectEqual(@as(usize, 0), got.request.files.len);
}

test "files-only is a valid request" {
    // Nothing textual, but plenty to share. The final emptiness check happens
    // on the assembled item array, because a path that names nothing on disk
    // contributes no item.
    var got = try shareRequestFrom("{\"options\":{\"files\":[\"/tmp/a.png\"]}}");
    defer got.deinit();

    try testing.expectEqual(@as(usize, 1), got.request.files.len);
    try testing.expectEqualStrings("", got.request.text);
}

test "a url the page sent that iOS cannot parse is refused, not left out of the sheet" {
    // Swift shared the text, dropped the link, and reported the share
    // completed — the caller asked for a link and got a sheet without one, with
    // nothing to indicate anything was missing. `openURL` already refuses this
    // exact condition; `share` refuses it the same way.
    //
    // Runs on any Darwin host: `+[NSURL URLWithString:]` is Foundation, and
    // `share` reaches it before it needs anything from UIKit.
    if (!is_darwin) return error.SkipZigTest;

    var bridge = SystemBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        bridge.handleMessage(A.share, "{\"options\":{\"text\":\"hi\",\"url\":\"http://exa mple.com\"}}"),
    );
}

test "a request id survives being captured for a callback that fires later" {
    // The completion handlers run after `ios_dispatch.handleMessage` has popped
    // the dispatch frame, so the id has to be read while the frame is live and
    // pushed back before replying. Without it the reply is stamped `null` and
    // goes down the action-name FIFO, which hands one caller's answer to
    // another whenever two shares are in flight.
    request_context.resetForTesting();

    request_context.push(31);
    const captured = capturedRequestId();
    request_context.pop();

    try testing.expectEqual(@as(i64, 31), captured);
    try testing.expectEqual(@as(?u64, null), request_context.current());

    request_context.push(if (captured < 0) null else @intCast(captured));
    defer request_context.pop();
    try testing.expectEqual(@as(?u64, 31), request_context.current());
}

test "a message the page sent without an id captures the absent-id sentinel" {
    request_context.resetForTesting();
    request_context.push(null);
    defer request_context.pop();
    try testing.expectEqual(@as(i64, -1), capturedRequestId());
}

test "a block carries its capture without disturbing the ABI prefix" {
    // Pinned as absolute offsets, not as `descriptor.size == @sizeOf(TheBlock)`
    // — that compares the constant against the expression that defines it and
    // so cannot fail. These can: they catch a reordered field, a widened
    // `flags`, and an `extern` that went missing and let Zig pick its own
    // layout, each of which hands `_Block_copy` and `objc_msgSend` a block
    // whose `invoke` and `descriptor` are not where the runtime looks.
    //
    // The offsets are the 64-bit ABI. iOS is 64-bit only and so is every host
    // that runs this suite; a 32-bit host would pad `request_id` differently
    // and is skipped rather than asserted about wrongly.
    if (@sizeOf(usize) != 8) return error.SkipZigTest;

    inline for (.{ OpenURLBlock, ShareBlock }) |Block| {
        try testing.expectEqual(@as(usize, 0), @offsetOf(Block, "isa"));
        try testing.expectEqual(@as(usize, 8), @offsetOf(Block, "flags"));
        try testing.expectEqual(@as(usize, 12), @offsetOf(Block, "reserved"));
        try testing.expectEqual(@as(usize, 16), @offsetOf(Block, "invoke"));
        try testing.expectEqual(@as(usize, 24), @offsetOf(Block, "descriptor"));
        // The capture, after the five fields the ABI reserves.
        try testing.expectEqual(@as(usize, 32), @offsetOf(Block, "request_id"));
    }

    // `_Block_copy` memcpys exactly `descriptor->size` bytes onto the heap, so
    // a size that stopped at the ABI prefix would leave the callback reading a
    // truncated id out of uninitialised memory.
    try testing.expect(open_url_block_descriptor.size >=
        @offsetOf(OpenURLBlock, "request_id") + @sizeOf(i64));
    try testing.expect(share_block_descriptor.size >=
        @offsetOf(ShareBlock, "request_id") + @sizeOf(i64));
}

test "every reply is a JSON object naming what happened, never a bare boolean" {
    // Reads `R`, which is what the handlers actually send. Asserting against
    // copies of those literals would pass unchanged if a handler started
    // replying `true` — coverage that cannot fail is worse than none.
    //
    // `craft-bridge.js` resolves with `payload || {}`, so a bare `false` and an
    // empty reply are the same value to the page.
    for (R.all) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
        try testing.expectEqual(@as(usize, 1), parsed.value.object.count());

        // And the member is a boolean the caller can branch on, not a string or
        // a number that reads as truthy whatever it says.
        var it = parsed.value.object.iterator();
        try testing.expect(it.next().?.value_ptr.* == .bool);
    }

    // Non-vacuity: every assertion above is satisfied by an empty list.
    try testing.expectEqual(@as(usize, 5), R.all.len);
    try testing.expect(!std.mem.eql(u8, R.opened, R.not_opened));
    try testing.expect(!std.mem.eql(u8, R.completed, R.not_completed));
}
