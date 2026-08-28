const std = @import("std");
const builtin = @import("builtin");
const objc_runtime = @import("objc_runtime.zig");
const request_context = @import("request_context.zig");
const bridge_error = @import("bridge_error.zig");
const bridge_mobile = @import("bridge_mobile.zig");

const objc = objc_runtime.objc;

/// The iOS end of the bridge: what a page's `postMessage` reaches, and how a
/// reply gets back to it.
///
/// The envelope is the desktop one — `{t, a, d, i}` — and the reply goes out
/// through `bridge_error.sendResultToJS`, which is the same function every
/// `bridge_*.zig` module already calls. That is the whole reason for choosing
/// this envelope over the one the Swift template speaks: reply correlation is
/// the hardest part of a bridge, and `craft-bridge.js` plus `request_context`
/// plus `formatResultJS` already implement it, with per-call ids, a timeout,
/// and a guard so a late reply cannot settle someone else's call.
///
/// Before this, `ios.zig` had a bridge that parsed JSON by substring search
/// and a `handleMessage` with no caller anywhere in the tree — because nothing
/// ever registered a `WKScriptMessageHandler`. A page's
/// `webkit.messageHandlers.craft` was undefined, so every call took the
/// fallback branch and resolved `{success:true, browser:true}`. "The bridge
/// worked" and "there is no bridge" were the same value.
/// The webview a reply is evaluated against.
///
/// One slot, because iOS has one webview. When multi-window arrives this
/// becomes a lookup keyed by the same request id the reply already carries —
/// the id is threaded through `request_context` for exactly that reason.
var global_webview: ?objc.id = null;

pub fn setWebView(webview: objc.id) void {
    global_webview = webview;
}

pub fn getWebView() ?objc.id {
    return global_webview;
}

/// Evaluate JavaScript in the page. `bridge.evalJS`'s `.ios` arm.
///
/// The completion handler is nil, which is legal and is what a reply wants:
/// nothing awaits the result of delivering a result. The block machinery that
/// a *callback-taking* evaluation needs is a separate problem, and the version
/// that used to sit in `mobile.zig` got it wrong in four ways at once — see
/// the note there.
pub fn evalJS(script: []const u8) !void {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const webview = global_webview orelse return error.NoWebView;

    // `createNSString` allocates rather than copying into a fixed buffer, which
    // matters: a reply's size is set by whatever the handler returns, and a
    // stack ceiling here would truncate JavaScript into a syntax error in the
    // page with nothing to point at.
    const ns_script = try objc.createNSString(script, std.heap.c_allocator);

    const sel_eval = objc.sel_registerName("evaluateJavaScript:completionHandler:") orelse return error.SelectorNotFound;
    const Fn = *const fn (objc.id, objc.SEL, objc.id, ?*anyopaque) callconv(.c) void;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    func(webview, sel_eval, ns_script, null);
}

/// Route one `{t, a, d, i}` message.
///
/// Mirrors `macos.zig:handleBridgeMessageJSON`, including the detail that cost
/// the desktop a bug: the payload `d` is handed to the namespace, not dropped.
pub fn handleMessage(allocator: std.mem.Allocator, json_str: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidBridgeMessage;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidBridgeMessage,
    };

    const msg_type = switch (root.get("t") orelse return error.MissingType) {
        .string => |value| value,
        else => return error.InvalidBridgeMessage,
    };
    const action = switch (root.get("a") orelse return error.MissingAction) {
        .string => |value| value,
        else => return error.InvalidBridgeMessage,
    };

    // Which call this is, so the reply can name it rather than leaving the page
    // to guess by action name. Pushed unconditionally: a message with no `i`
    // pushes null and so shadows any enclosing request instead of inheriting an
    // id that is not its own. Deferred pop because dispatch can fail anywhere.
    request_context.push(request_context.fromEnvelope(root));
    defer request_context.pop();

    // One line per dispatch, naming the call. On a device this is the only
    // window into the bridge — there is no console to watch — and it is what
    // lets a harness observe that a message arrived at all, separately from
    // whether it was answered correctly.
    std.log.info("craft-bridge dispatch t={s} a={s} i={?d}", .{
        msg_type,
        action,
        request_context.current(),
    });

    const data = try payloadOf(root);

    try route(allocator, msg_type, action, data);
}

/// The payload `d`, as a JSON string the namespace can parse.
///
/// `craft-bridge.js` sends `d` already stringified — `_post` builds
/// `{t, a, d: d || ''}` — and omits it for the many actions that need none. So
/// the string and absent cases are the real ones, and both are handled here.
///
/// An absent `d` becomes `{}` rather than `""`. An empty string would clear a
/// handler's `orelse MissingData` guard and then fail JSON parsing instead,
/// which reports the wrong cause — the same trap `macos.zig` documents at its
/// own payload extraction.
///
/// A structured `d` (object or array) is rejected rather than quietly dropped.
/// The desktop re-renders it with a `jsonValueToString` that is private to
/// `macos.zig`; sharing that is part of extracting the common dispatcher, and
/// until then an explicit error is the honest answer. Silently substituting
/// `{}` here would hand the handler an empty payload and let it act on
/// defaults, which is how `craft.fs.writeFile` came to write empty files.
fn payloadOf(root: std.json.ObjectMap) ![]const u8 {
    const data_val = root.get("d") orelse return "{}";
    return switch (data_val) {
        .string => |s| if (s.len == 0) "{}" else s,
        .object, .array => error.StructuredPayloadNotSupported,
        .null => "{}",
        else => error.InvalidPayload,
    };
}

/// Namespace routing.
///
/// One arm today. Every action not served here answers with an error rather
/// than silence — a page awaiting a reply that never comes is
/// indistinguishable from a slow one until its timeout fires, and thirty
/// seconds of nothing is the worst diagnostic a bridge can give.
fn route(allocator: std.mem.Allocator, msg_type: []const u8, action: []const u8, data: []const u8) !void {
    if (std.mem.eql(u8, msg_type, "mobile")) {
        var bridge = bridge_mobile.MobileBridge.init(allocator);
        defer bridge.deinit();
        bridge.handleMessage(action, data) catch |err| {
            bridge_error.sendErrorToJS(allocator, action, bridge_error.BridgeError.UnknownAction);
            return err;
        };
        return;
    }

    bridge_error.sendErrorToJS(allocator, action, bridge_error.BridgeError.UnknownAction);
    return error.UnknownNamespace;
}

const testing = std.testing;

test "an envelope without a type is rejected" {
    try testing.expectError(
        error.MissingType,
        handleMessage(testing.allocator, "{\"a\":\"getDeviceInfo\"}"),
    );
}

test "an envelope without an action is rejected" {
    try testing.expectError(
        error.MissingAction,
        handleMessage(testing.allocator, "{\"t\":\"mobile\"}"),
    );
}

test "malformed JSON is rejected rather than parsed by guesswork" {
    // The bridge this replaces searched for `"method":"` as a substring, which
    // would happily "parse" this and act on whatever followed.
    try testing.expectError(
        error.InvalidBridgeMessage,
        handleMessage(testing.allocator, "{\"t\":\"mobile\", \"a\":"),
    );
}

test "an absent payload becomes an empty object, not an empty string" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"t\":\"mobile\",\"a\":\"x\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("{}", try payloadOf(parsed.value.object));
}

test "a string payload is passed through unchanged" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"t\":\"mobile\",\"a\":\"x\",\"d\":\"{\\\"k\\\":1}\"}",
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("{\"k\":1}", try payloadOf(parsed.value.object));
}

test "a structured payload is refused, not silently emptied" {
    // Substituting `{}` here would hand the handler an empty payload and let it
    // proceed on defaults. That is precisely the shape of the bug where
    // `craft.fs.writeFile` wrote empty files: a field the page sent, dropped on
    // the way in, with success reported anyway.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"t\":\"mobile\",\"a\":\"x\",\"d\":{\"k\":1}}",
        .{},
    );
    defer parsed.deinit();
    try testing.expectError(error.StructuredPayloadNotSupported, payloadOf(parsed.value.object));
}

test "evalJS without a webview reports it rather than crashing" {
    const saved = global_webview;
    defer global_webview = saved;
    global_webview = null;

    try testing.expectError(error.NoWebView, evalJS("void 0"));
}
