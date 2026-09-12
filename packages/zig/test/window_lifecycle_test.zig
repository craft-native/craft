//! Every window craft opens must be reopenable.
//!
//! This test exists because of a bug that nothing else could have caught.
//! `isCraftWindow` decided whether a window was craft's by asking whether its
//! content view was a `WKWebView`. That is true of the plain window and false
//! of the other three: `--web-sidebar-material` installs a backdrop container,
//! `createWindowWithSidebar` sets a split view controller, and
//! `createWindowWithSidebarURL` installs its own container. All three keep
//! their closed window alive, so the reopen handler found them, skipped them,
//! and left the app activated with nothing on screen — the exact dead end the
//! handler was added to remove.
//!
//! It compiled. Every test passed. It failed only against a real
//! `kAEReopenApplication` on a window style no test constructs, and **no test
//! in this repository constructs a window at all**.
//!
//! ## Why this is a source test
//!
//! Constructing a window means a live `NSApplication`, a `WKWebView` and the
//! WebContent process behind it — heavy, and flaky on a runner with no
//! display. The properties worth defending do not need any of that:
//!
//!   1. every window constructor registers its window transactionally, and
//!   2. nothing infers craft-ness from the window's appearance again.
//!
//! Both are properties of the source, and they are only checkable *because*
//! the fix replaced an inference with a registration. "Does this window look
//! like ours?" can only be answered by holding a window. "Did every
//! constructor register?" can be answered by reading. Making the property
//! checkable was worth as much as fixing the bug.
//!
//! Each check carries a floor, because a scan that finds nothing passes
//! vacuously, and a vacuous pass is how this class of bug returns.

const std = @import("std");
const testing = std.testing;

const macos_source = @embedFile("src/macos.zig");
const window_bridge_source = @embedFile("src/bridge_window.zig");
const native_ui_bridge_source = @embedFile("src/bridge_native_ui.zig");
const space_switcher_source = @embedFile("src/components/native_space_switcher.zig");
const keyboard_handler_source = @embedFile("src/components/keyboard_handler.zig");
const native_sidebar_source = @embedFile("src/components/native_sidebar.zig");
const native_file_browser_source = @embedFile("src/components/native_file_browser.zig");
const native_split_view_source = @embedFile("src/components/native_split_view.zig");
const tray_menu_source = @embedFile("src/tray_menu.zig");

/// The Objective-C initialiser every `NSWindow` in craft goes through.
const window_init = "initWithContentRect:styleMask:backing:defer:";

/// What a constructor must call on the window it just made.
const register_call = "keepWindowAfterClose(";

/// Whether `body` really calls `needle`, ignoring commented-out occurrences.
///
/// Substring matching alone cannot tell a call from a mention. Commenting a
/// registration out would leave the text in place and satisfy a naive scan —
/// which is exactly how this check was first found to be toothless, by
/// commenting one out and watching it pass.
fn callsFunction(body: []const u8, needle: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, body, search, needle)) |hit| {
        search = hit + needle.len;
        const start = lineStart(body, hit);
        const before = std.mem.trimStart(u8, body[start..hit], " \t");
        // `//` anywhere before it on the line makes it a comment, and `///`
        // makes it documentation.
        if (std.mem.startsWith(u8, before, "//")) continue;
        if (std.mem.indexOf(u8, body[start..hit], "//") != null) continue;
        return true;
    }
    return false;
}

/// Start of the line containing `needle`.
fn lineStart(source: []const u8, at: usize) usize {
    var i = at;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

/// The `fn` declaration enclosing byte `at`.
///
/// Zig indents declarations at column zero inside a file, so the nearest
/// preceding line beginning with `fn ` or `pub fn ` is the enclosing
/// top-level function. Container-level methods are indented and belong to a
/// struct whose own declaration is found the same way.
fn enclosingFn(source: []const u8, at: usize) ?[]const u8 {
    var i = lineStart(source, at);
    while (true) {
        const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        const line = source[i..line_end];
        if (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "pub fn ")) return line;
        if (i == 0) return null;
        i = lineStart(source, i - 1);
    }
}

/// Byte range of the function body enclosing `at`, from its `fn` line to the
/// next top-level `fn` line (or end of file).
fn enclosingFnBody(source: []const u8, at: usize) []const u8 {
    var start = lineStart(source, at);
    while (start > 0) {
        const line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..line_end];
        if (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "pub fn ")) break;
        start = lineStart(source, start - 1);
    }

    var end = at;
    while (end < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, end, '\n') orelse source.len;
        const line = source[end..line_end];
        if (end != start and (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "pub fn "))) break;
        if (line_end >= source.len) {
            end = source.len;
            break;
        }
        end = line_end + 1;
    }
    return source[start..end];
}

test "every window craft constructs is registered as one of its own" {
    // The check that would have caught the bug this file exists for — had the
    // answer been recorded rather than inferred. It is recorded now, so this
    // is the property that keeps it recorded.
    var constructors: usize = 0;
    var unregistered: usize = 0;

    var search: usize = 0;
    while (std.mem.indexOfPos(u8, macos_source, search, window_init)) |hit| {
        search = hit + window_init.len;

        // The name is mentioned in prose as well as called. Only a real
        // `msgSend4(...)` call constructs a window.
        const line = macos_source[lineStart(macos_source, hit)..hit];
        if (std.mem.indexOf(u8, line, "msgSend4") == null) continue;

        constructors += 1;
        const body = enclosingFnBody(macos_source, hit);
        if (!callsFunction(body, register_call)) {
            unregistered += 1;
            const name = enclosingFn(macos_source, hit) orelse "(unknown)";
            std.debug.print(
                "\nwindow constructor does not call {s}: {s}\n",
                .{ register_call, name },
            );
        }
    }

    // Floor: craft has three window constructors. If a refactor renames the
    // initialiser this scan finds none and would otherwise pass having checked
    // nothing at all.
    try testing.expect(constructors >= 3);
    try testing.expectEqual(@as(usize, 0), unregistered);
}

test "window construction fails cleanly when registration is refused" {
    var constructors: usize = 0;

    var search: usize = 0;
    while (std.mem.indexOfPos(u8, macos_source, search, window_init)) |hit| {
        search = hit + window_init.len;
        const line = macos_source[lineStart(macos_source, hit)..hit];
        if (std.mem.indexOf(u8, line, "msgSend4") == null) continue;

        constructors += 1;
        const body = enclosingFnBody(macos_source, hit);
        try testing.expect(std.mem.indexOf(u8, body, "errdefer destroyWindow(window);") != null);
        try testing.expect(std.mem.indexOf(u8, body, "try keepWindowAfterClose(window);") != null);
    }

    try testing.expect(constructors >= 3);
}

test "typed open allocates its reply before creating a native window" {
    const start = std.mem.indexOf(u8, window_bridge_source, "fn open(self: *Self") orelse
        return error.WindowOpenHandlerNotFound;
    const end = std.mem.indexOfPos(u8, window_bridge_source, start, "    fn show(") orelse
        return error.WindowShowHandlerNotFound;
    const body = window_bridge_source[start..end];
    const format_at = std.mem.indexOf(u8, body, "try formatOpenResult(") orelse
        return error.WindowOpenResultAllocationNotFound;
    const native_at = std.mem.indexOf(u8, body, "macos.openNamedWindow(") orelse
        return error.NativeWindowOpenNotFound;

    try testing.expect(format_at < native_at);
}

test "typed window names are decoded before registry lookup and creation" {
    const handle_start = std.mem.indexOf(u8, window_bridge_source, "fn requireWindowHandle(") orelse
        return error.WindowHandleResolverNotFound;
    const handle_end = std.mem.indexOfPos(u8, window_bridge_source, handle_start, "    /// The webview this action applies to.") orelse
        return error.WindowHandleResolverEndNotFound;
    const handle_body = window_bridge_source[handle_start..handle_end];
    try testing.expect(callsFunction(handle_body, "getStringDecoded("));

    const webview_start = std.mem.indexOf(u8, window_bridge_source, "fn requireWebViewHandle(") orelse
        return error.WindowWebViewResolverNotFound;
    const webview_end = std.mem.indexOfPos(u8, window_bridge_source, webview_start, "    /// Open a second window") orelse
        return error.WindowWebViewResolverEndNotFound;
    const webview_body = window_bridge_source[webview_start..webview_end];
    try testing.expect(callsFunction(webview_body, "getStringDecoded("));

    const open_start = std.mem.indexOf(u8, window_bridge_source, "fn open(self: *Self") orelse
        return error.WindowOpenHandlerNotFound;
    const open_end = std.mem.indexOfPos(u8, window_bridge_source, open_start, "    fn show(") orelse
        return error.WindowShowHandlerNotFound;
    const open_body = window_bridge_source[open_start..open_end];
    try testing.expect(std.mem.count(u8, open_body, "getStringDecoded(") >= 6);
}

test "whether a window is craft's is recorded, never inferred from the window" {
    // The specific regression. `isCraftWindow` asked the window what its
    // content view was; three of craft's four window styles answer with a
    // container rather than the webview, so those windows were silently
    // skipped by reopen.
    //
    // Any re-introduction reads the window instead of the registry, and every
    // way of doing that goes through one of these.
    const start = std.mem.indexOf(u8, macos_source, "fn isCraftWindow(") orelse {
        // Renamed or removed: this test can no longer defend anything and must
        // say so rather than pass.
        return error.IsCraftWindowNotFound;
    };
    const body = enclosingFnBody(macos_source, start);

    for ([_][]const u8{
        "contentView",
        "isKindOfClass:",
        "contentViewController",
        "subviews",
    }) |inference| {
        if (std.mem.indexOf(u8, body, inference) != null) {
            std.debug.print("\nisCraftWindow inspects the window ({s}) instead of the registry\n", .{inference});
            return error.WindowIdentityInferred;
        }
    }

    // And it must actually consult the registry, rather than being stubbed to
    // a constant that passes the check above.
    try testing.expect(callsFunction(body, "window_registry.isKnown"));
}

test "titlebar controls resolve the webview in their own window" {
    // The button callbacks used to read `getGlobalWebView()`. After opening a
    // Settings window, Back in the main window therefore navigated Settings —
    // the button itself already knew which window it belonged to, but that
    // identity was discarded.
    const helper_start = std.mem.indexOf(u8, macos_source, "fn webViewForChromeControl(") orelse
        return error.ChromeControlResolverNotFound;
    const helper = enclosingFnBody(macos_source, helper_start);
    try testing.expect(std.mem.indexOf(u8, helper, "msgSend0(sender, \"window\")") != null);
    try testing.expect(std.mem.indexOf(u8, helper, "webViewForWindow(window)") != null);
    try testing.expect(std.mem.indexOf(u8, helper, "getGlobalWebView") == null);

    for ([_][]const u8{
        "fn webChromeToggleSidebarCallback(",
        "fn webChromeBackCallback(",
        "fn webChromeForwardCallback(",
    }) |declaration| {
        const start = std.mem.indexOf(u8, macos_source, declaration) orelse
            return error.ChromeControlCallbackNotFound;
        const body = enclosingFnBody(macos_source, start);
        try testing.expect(std.mem.indexOf(u8, body, "webViewForChromeControl(sender)") != null);
        try testing.expect(std.mem.indexOf(u8, body, "getGlobalWebView") == null);
    }
}

test "page-driven native surfaces use the sending webview" {
    const resolver_start = std.mem.indexOf(u8, macos_source, "pub fn getMessageWebView(") orelse
        return error.MessageWebViewResolverNotFound;
    const resolver = enclosingFnBody(macos_source, resolver_start);
    try testing.expect(callsFunction(resolver, "window_context.currentWebView()"));

    // `tryEvalJS` is the shared reply path. Keep it on the same resolver as
    // direct native surfaces so the two cannot drift back to different ideas
    // of which page owns the operation.
    const eval_start = std.mem.indexOf(u8, macos_source, "pub fn tryEvalJS(") orelse
        return error.TryEvalJSNotFound;
    const eval_body = enclosingFnBody(macos_source, eval_start);
    try testing.expect(callsFunction(eval_body, "getMessageWebView()"));
}

test "opening a child does not replace sender-less primary fallbacks" {
    // Every constructor runs the shared setup path. These four setters used to
    // assign unconditionally, so opening Settings made app-wide notifications,
    // menu items and any native callback without a message sender jump from the
    // main page to Settings merely because it was constructed later.
    for ([_]struct { source: []const u8, declaration: []const u8, slot: []const u8 }{
        .{ .source = macos_source, .declaration = "pub fn setGlobalWebView(", .slot = "global_webview" },
        .{ .source = tray_menu_source, .declaration = "pub fn setGlobalWebView(", .slot = "global_webview" },
        .{ .source = tray_menu_source, .declaration = "pub fn setGlobalWindow(", .slot = "global_window_handle" },
        .{ .source = window_bridge_source, .declaration = "    pub fn setWindowHandle(", .slot = "self.window_handle" },
        .{ .source = window_bridge_source, .declaration = "    pub fn setWebViewHandle(", .slot = "self.webview_handle" },
    }) |contract| {
        const start = std.mem.indexOf(u8, contract.source, contract.declaration) orelse
            return error.PrimaryFallbackSetterNotFound;
        const body = enclosingFnBody(contract.source, start);
        var guard_buf: [96]u8 = undefined;
        const guard = try std.fmt.bufPrint(&guard_buf, "if ({s} == null)", .{contract.slot});
        try testing.expect(std.mem.indexOf(u8, body, guard) != null);
    }
}

test "window events never fall back to an unrelated global webview" {
    const events_source = @embedFile("src/macos_window_events.zig");
    const start = std.mem.indexOf(u8, events_source, "fn fire(") orelse
        return error.WindowEventEmitterNotFound;
    const body = enclosingFnBody(events_source, start);
    try testing.expect(callsFunction(body, "webViewForWindow(window)"));
    try testing.expect(std.mem.indexOf(u8, body, "getGlobalWebView") == null);
}

test "typed child events return only to their creator page" {
    const events_source = @embedFile("src/macos_window_events.zig");
    const start = std.mem.indexOf(u8, events_source, "fn fire(") orelse
        return error.WindowEventEmitterNotFound;
    const body = enclosingFnBody(events_source, start);
    try testing.expect(callsFunction(body, "window_registry.ownerWebViewOf("));
    try testing.expect(callsFunction(body, "window_registry.nameOf("));
    try testing.expect(callsFunction(body, "deliver("));

    const open_start = std.mem.indexOf(u8, window_bridge_source, "fn open(") orelse
        return error.WindowOpenHandlerNotFound;
    const open_body = enclosingFnBody(window_bridge_source, open_start);
    try testing.expect(callsFunction(open_body, "window_context.currentWebView()"));
}

test "window construction balances its WebKit creator retains" {
    for ([_][]const u8{
        "pub fn createWindowWithStyle(",
        "pub fn createWindowWithSidebar(",
        "pub fn createWindowWithSidebarURL(",
    }) |declaration| {
        const start = std.mem.indexOf(u8, macos_source, declaration) orelse
            return error.WindowConstructorNotFound;
        const body = enclosingFnBody(macos_source, start);

        for ([_][]const u8{
            "defer msgSendVoid0(config, \"release\")",
            "defer msgSendVoid0(prefs, \"release\")",
            "defer msgSendVoid0(userContentController, \"release\")",
            "defer msgSendVoid0(webview, \"release\")",
        }) |contract| {
            try testing.expect(std.mem.indexOf(u8, body, contract) != null);
        }
    }

    const script_start = std.mem.indexOf(u8, macos_source, "fn addUserScriptSource(") orelse
        return error.UserScriptInstallerNotFound;
    const script_body = enclosingFnBody(macos_source, script_start);
    try testing.expect(std.mem.indexOf(u8, script_body, "msgSendVoid0(script, \"release\")") != null);
}

test "the native delegate emits both fullscreen transitions" {
    const events_source = @embedFile("src/macos_window_events.zig");
    for ([_][]const u8{
        "windowDidEnterFullScreen:",
        "windowDidExitFullScreen:",
        "fire(notification, \"enter-fullscreen\"",
        "fire(notification, \"leave-fullscreen\"",
    }) |contract| {
        try testing.expect(std.mem.indexOf(u8, events_source, contract) != null);
    }
}

test "window-state selectors receive their required sender argument" {
    // These AppKit selectors end in `:` and therefore take one object
    // argument. Calling them through the zero-argument wrapper is undefined
    // ABI behavior even when AppKit currently ignores the sender.
    for ([_][]const u8{
        "pub fn minimizeWindow(",
        "pub fn maximizeWindow(",
        "pub fn toggleFullscreen(",
    }) |declaration| {
        const start = std.mem.indexOf(u8, macos_source, declaration) orelse
            return error.WindowStateHelperNotFound;
        const body = enclosingFnBody(macos_source, start);
        try testing.expect(callsFunction(body, "msgSendVoid1("));
        try testing.expect(std.mem.indexOf(u8, body, "msgSendVoid0(") == null);
    }

    // The initial-fullscreen path is outside `toggleFullscreen`, so guard it
    // independently. This selector has one Objective-C argument everywhere it
    // is called, including while a newly created window is being configured.
    try testing.expect(std.mem.indexOf(u8, macos_source, "msgSendVoid0(window, \"toggleFullScreen:\")") == null);
}

test "hide and force reload selectors receive their sender argument" {
    for ([_][]const u8{
        "pub fn hideWindow(",
        "pub fn reloadWindowIgnoringCache(",
    }) |declaration| {
        const start = std.mem.indexOf(u8, macos_source, declaration) orelse
            return error.WindowHelperNotFound;
        const body = enclosingFnBody(macos_source, start);
        try testing.expect(callsFunction(body, "msgSendVoid1("));
        try testing.expect(std.mem.indexOf(u8, body, "msgSendVoid0(") == null);
    }
}

test "runtime window creation applies the typed appearance and size constraints" {
    const start = std.mem.indexOf(u8, window_bridge_source, "fn open(") orelse
        return error.WindowOpenHandlerNotFound;
    const end = std.mem.indexOfPos(u8, window_bridge_source, start, "    fn show(") orelse
        return error.WindowShowHandlerNotFound;
    const body = window_bridge_source[start..end];

    for ([_][]const u8{
        "\"frameless\"",
        "\"transparent\"",
        "\"fullscreen\"",
        "\"maxWidth\"",
        "\"maxHeight\"",
        "\"setMaxSize:\"",
        "\"movable\"",
        "\"setMovable:\"",
        "\"maximizable\"",
        "\"standardWindowButton:\"",
        "\"backgroundColor\"",
        "\"setBackgroundColor:\"",
    }) |contract| {
        try testing.expect(std.mem.indexOf(u8, body, contract) != null);
    }
}

test "content replacement updates the addressed webview recovery source" {
    for ([_][]const u8{
        "pub fn loadURLInWebView(",
        "pub fn loadHTMLInWebView(",
    }) |declaration| {
        const start = std.mem.indexOf(u8, macos_source, declaration) orelse
            return error.WindowContentLoaderNotFound;
        const body = enclosingFnBody(macos_source, start);
        try testing.expect(callsFunction(body, "rememberContent("));
    }

    const remember_start = std.mem.indexOf(u8, macos_source, "fn rememberContent(") orelse
        return error.ContentMemoryNotFound;
    const remember_body = enclosingFnBody(macos_source, remember_start);
    try testing.expect(callsFunction(remember_body, "retainContent("));
    try testing.expect(callsFunction(remember_body, "releaseContent("));
}

test "JavaScript evaluation preserves target request and reply webview" {
    const bridge_start = std.mem.indexOf(u8, window_bridge_source, "fn executeJavaScript(") orelse
        return error.ExecuteJavaScriptHandlerNotFound;
    const bridge_end = std.mem.indexOfPos(u8, window_bridge_source, bridge_start, "    fn loadHTML(") orelse
        return error.ExecuteJavaScriptHandlerEndNotFound;
    const bridge_body = window_bridge_source[bridge_start..bridge_end];
    for ([_][]const u8{
        "requireWebViewHandle(",
        "getStringDecoded(",
        "indexOfScalar(u8, decoded, 0)",
        "window_context.currentWebView()",
        "request_context.zig",
        "evaluateJavaScriptWithReply(",
    }) |contract| {
        try testing.expect(std.mem.indexOf(u8, bridge_body, contract) != null);
    }

    const native_start = std.mem.indexOf(u8, macos_source, "pub fn evaluateJavaScriptWithReply(") orelse
        return error.NativeJavaScriptEvaluatorNotFound;
    const native_body = enclosingFnBody(macos_source, native_start);
    try testing.expect(std.mem.indexOf(u8, native_body, "reply_webview") != null);
    try testing.expect(std.mem.indexOf(u8, native_body, "request_id") != null);
    try testing.expect(std.mem.indexOf(u8, native_body, "msgSend0(reply_webview, \"retain\")") != null);

    const callback_start = std.mem.indexOf(u8, macos_source, "fn javascriptDidFinish(") orelse
        return error.JavaScriptCallbackNotFound;
    const callback_body = enclosingFnBody(macos_source, callback_start);
    try testing.expect(callsFunction(callback_body, "formatResultJS("));
    try testing.expect(std.mem.indexOf(u8, callback_body, "block.request_id") != null);
    try testing.expect(std.mem.indexOf(u8, callback_body, "block.reply_webview") != null);
    try testing.expect(callsFunction(callback_body, "sendJavaScriptEvaluationError("));
    try testing.expect(std.mem.indexOf(u8, callback_body, "isValidJSONObject:") != null);
}

test "native UI state follows the authenticated sending window" {
    const setter_start = std.mem.indexOf(u8, native_ui_bridge_source, "pub fn setWindow(") orelse
        return error.NativeUIWindowSetterNotFound;
    const setter_end = std.mem.indexOfPos(u8, native_ui_bridge_source, setter_start, "    fn currentState(") orelse
        return error.NativeUIWindowSetterEndNotFound;
    const setter_body = native_ui_bridge_source[setter_start..setter_end];
    try testing.expect(std.mem.indexOf(u8, setter_body, "self.primary_window == null") != null);
    try testing.expect(std.mem.indexOf(u8, setter_body, "window_context.current()") != null);

    const state_start = std.mem.indexOf(u8, native_ui_bridge_source, "fn currentState(") orelse
        return error.NativeUIStateResolverNotFound;
    const state_end = std.mem.indexOfPos(u8, native_ui_bridge_source, state_start, "    /// Forget only the UI") orelse
        return error.NativeUIStateResolverEndNotFound;
    const state_body = native_ui_bridge_source[state_start..state_end];
    try testing.expect(std.mem.indexOf(u8, state_body, "self.window_states.get(key)") != null);
    try testing.expect(std.mem.indexOf(u8, state_body, "WindowState.init(self.allocator, window)") != null);
}

test "native UI teardown and delayed control events stay window-scoped" {
    const destroy_start = std.mem.indexOf(u8, macos_source, "pub fn destroyWindow(") orelse
        return error.NativeWindowDestroyNotFound;
    const destroy_body = enclosingFnBody(macos_source, destroy_start);
    try testing.expect(std.mem.indexOf(u8, destroy_body, "bridge.forgetWindow(window)") != null);

    const callback_start = std.mem.indexOf(u8, space_switcher_source, "fn spaceSelectedCallback(") orelse
        return error.SpaceSwitcherCallbackNotFound;
    const callback_body = enclosingFnBody(space_switcher_source, callback_start);
    try testing.expect(std.mem.indexOf(u8, callback_body, "switcherForResponder(responder)") != null);
    try testing.expect(std.mem.indexOf(u8, callback_body, "self.webview") != null);

    const emit_start = std.mem.indexOf(u8, space_switcher_source, "fn emitSpaceChange(") orelse
        return error.SpaceSwitcherEmitterNotFound;
    const emit_body = enclosingFnBody(space_switcher_source, emit_start);
    try testing.expect(std.mem.indexOf(u8, emit_body, "tryEvalJSInWebView(webview") != null);
}

test "native UI keyboard callbacks are associated with their source view" {
    for ([_][]const u8{
        "global_keyboard_callback_data",
        "global_outline_spacebar_callback",
        "global_table_spacebar_callback",
        "global_outline_return_callback",
        "global_table_return_callback",
    }) |retired_global| {
        try testing.expect(std.mem.indexOf(u8, keyboard_handler_source, retired_global) == null);
    }

    const outline_start = std.mem.indexOf(u8, keyboard_handler_source, "export fn craftOutlineViewKeyDown(") orelse
        return error.OutlineKeyHandlerNotFound;
    const outline_end = std.mem.indexOfPos(u8, keyboard_handler_source, outline_start, "/// keyDown: handler for CraftTableView") orelse
        return error.OutlineKeyHandlerEndNotFound;
    const outline_body = keyboard_handler_source[outline_start..outline_end];
    try testing.expect(std.mem.indexOf(u8, outline_body, "viewCallback(self, &outline_spacebar_association_key)") != null);
    try testing.expect(std.mem.indexOf(u8, outline_body, "viewCallback(self, &outline_return_association_key)") != null);

    const table_start = std.mem.indexOf(u8, keyboard_handler_source, "export fn craftTableViewKeyDown(") orelse
        return error.TableKeyHandlerNotFound;
    const table_end = std.mem.indexOfPos(u8, keyboard_handler_source, table_start, "/// Set the spacebar callback") orelse
        return error.TableKeyHandlerEndNotFound;
    const table_body = keyboard_handler_source[table_start..table_end];
    try testing.expect(std.mem.indexOf(u8, table_body, "viewCallback(self, &table_spacebar_association_key)") != null);
    try testing.expect(std.mem.indexOf(u8, table_body, "viewCallback(self, &table_return_association_key)") != null);
}

test "legacy native sidebar data and controls are window-scoped" {
    for ([_][]const u8{
        "var dynamic_sections:",
        "var sidebar_webview:",
        "var sidebar_container:",
        "var sidebar_content_webview:",
        "var sidebar_toggle_btn:",
        "var sidebar_collapsed:",
    }) |retired_global| {
        try testing.expect(std.mem.indexOf(u8, macos_source, retired_global) == null);
    }

    const data_source_start = std.mem.indexOf(u8, macos_source, "fn setupSidebarDataSource(") orelse
        return error.LegacySidebarDataSourceNotFound;
    const data_source_body = enclosingFnBody(macos_source, data_source_start);
    try testing.expect(std.mem.indexOf(u8, data_source_body, "associateLegacySidebarState(instance, state)") != null);

    const toggle_start = std.mem.indexOf(u8, macos_source, "fn sidebarToggleCallback(") orelse
        return error.LegacySidebarToggleNotFound;
    const toggle_body = enclosingFnBody(macos_source, toggle_start);
    try testing.expect(std.mem.indexOf(u8, toggle_body, "legacySidebarState(window, false)") != null);

    const destroy_start = std.mem.indexOf(u8, macos_source, "pub fn destroyWindow(") orelse
        return error.NativeWindowDestroyNotFound;
    const destroy_body = enclosingFnBody(macos_source, destroy_start);
    try testing.expect(callsFunction(destroy_body, "forgetLegacySidebar("));
}

test "scroll gestures keep independent state and target their event window" {
    try testing.expect(std.mem.indexOf(u8, macos_source, "var scroll_state:") == null);

    const callback_start = std.mem.indexOf(u8, macos_source, "fn scrollMonitorInvoke(") orelse
        return error.ScrollMonitorCallbackNotFound;
    const callback_end = std.mem.indexOfPos(u8, macos_source, callback_start, "const scroll_block_descriptor") orelse
        return error.ScrollMonitorCallbackEndNotFound;
    const callback_body = macos_source[callback_start..callback_end];
    try testing.expect(std.mem.indexOf(u8, callback_body, "msgSend0(event, \"window\")") != null);
    try testing.expect(std.mem.indexOf(u8, callback_body, "scrollGestureState(window, true)") != null);
    try testing.expect(std.mem.indexOf(u8, callback_body, "webViewForWindow(window)") != null);
    try testing.expect(std.mem.indexOf(u8, callback_body, "emitSwipe(webview, emit)") != null);

    const destroy_start = std.mem.indexOf(u8, macos_source, "pub fn destroyWindow(") orelse
        return error.NativeWindowDestroyNotFound;
    const destroy_body = enclosingFnBody(macos_source, destroy_start);
    try testing.expect(callsFunction(destroy_body, "forgetScrollGesture("));
}

test "retained content covers the full window registry" {
    try testing.expect(std.mem.indexOf(
        u8,
        macos_source,
        "var content_slots: [window_registry.capacity]ContentSlot",
    ) != null);
}

test "native UI creation publishes only fully initialized components" {
    const cases = [_]struct {
        start: []const u8,
        end: []const u8,
        map: []const u8,
        installed: []const u8,
    }{
        .{
            .start = "    fn createSidebar(",
            .end = "    /// Add a section to an existing sidebar",
            .map = "sidebars",
            .installed = "setContentViewController:",
        },
        .{
            .start = "    fn createFileBrowser(",
            .end = "    /// Add a single file to file browser",
            .map = "file_browsers",
            .installed = "addSubview:",
        },
        .{
            .start = "    fn createSplitView(",
            .end = "    /// Destroy a component",
            .map = "split_views",
            .installed = "addSubview:",
        },
    };

    for (cases) |case| {
        const start = std.mem.indexOf(u8, native_ui_bridge_source, case.start) orelse
            return error.NativeUICreatorNotFound;
        const end = std.mem.indexOfPos(u8, native_ui_bridge_source, start, case.end) orelse
            return error.NativeUICreatorEndNotFound;
        const body = native_ui_bridge_source[start..end];
        const reserve = std.mem.indexOf(u8, body, ".ensureUnusedCapacity(1)") orelse
            return error.NativeUIRegistryReservationNotFound;
        const install = std.mem.indexOf(u8, body, case.installed) orelse
            return error.NativeUIInstallationNotFound;
        const publish_needle = try std.fmt.allocPrint(testing.allocator, "state.{s}.putAssumeCapacityNoClobber", .{case.map});
        defer testing.allocator.free(publish_needle);
        const publish = std.mem.indexOf(u8, body, publish_needle) orelse
            return error.NativeUIRegistryPublicationNotFound;

        try testing.expect(reserve < install);
        try testing.expect(install < publish);
    }
}

test "window-scoped native UI mutations validate JSON shapes" {
    const start = std.mem.indexOf(u8, native_ui_bridge_source, "    fn createSidebar(") orelse
        return error.NativeUISidebarCreatorNotFound;
    const end = std.mem.indexOfPos(u8, native_ui_bridge_source, start, "    /// Show a context menu") orelse
        return error.NativeUIContextMenuNotFound;
    const body = native_ui_bridge_source[start..end];

    for ([_][]const u8{
        "parsed.value.object",
        ".?.object",
        ".?.array",
        ".?.string",
    }) |unchecked_access| {
        try testing.expect(std.mem.indexOf(u8, body, unchecked_access) == null);
    }

    for ([_][]const u8{
        "objectValue(",
        "arrayValue(",
        "requiredObject(",
        "requiredArray(",
        "requiredString(",
        "optionalString(",
    }) |checked_access| {
        try testing.expect(std.mem.indexOf(u8, body, checked_access) != null);
    }
}

test "window-scoped context menus validate JSON shapes" {
    const start = std.mem.indexOf(u8, native_ui_bridge_source, "    fn showContextMenu(") orelse
        return error.NativeUIContextMenuNotFound;
    const end = std.mem.indexOfPos(u8, native_ui_bridge_source, start, "    /// Show Quick Look panel") orelse
        return error.NativeUIQuickLookNotFound;
    const body = native_ui_bridge_source[start..end];

    for ([_][]const u8{
        "parsed.value.object",
        ".?.object",
        ".?.array",
        ".?.string",
        ".?.bool",
    }) |unchecked_access| {
        try testing.expect(std.mem.indexOf(u8, body, unchecked_access) == null);
    }

    for ([_][]const u8{
        "objectValue(",
        "arrayValue(",
        "requiredArray(",
        "requiredString(",
        "requiredNumber(",
        "optionalString(",
        "optionalBool(",
    }) |checked_access| {
        try testing.expect(std.mem.indexOf(u8, body, checked_access) != null);
    }
}

test "Quick Look validates a complete replacement before publishing it" {
    const start = std.mem.indexOf(u8, native_ui_bridge_source, "    fn showQuickLook(") orelse
        return error.NativeUIQuickLookNotFound;
    const end = std.mem.indexOfPos(u8, native_ui_bridge_source, start, "    /// Close Quick Look panel") orelse
        return error.NativeUIQuickLookEndNotFound;
    const body = native_ui_bridge_source[start..end];

    for ([_][]const u8{
        "objectValue(",
        "requiredArray(",
        "previewItem(",
        "optionalIndex(",
        "setPreviewItems(",
    }) |contract| {
        try testing.expect(std.mem.indexOf(u8, body, contract) != null);
    }
    for ([_][]const u8{
        "parsed.value.object",
        ".?.object",
        ".?.array",
        ".?.string",
        "@intCast(i)",
        "clearItems()",
        "addPreviewItem(",
    }) |unsafe_or_partial| {
        try testing.expect(std.mem.indexOf(u8, body, unsafe_or_partial) == null);
    }
}

test "spaces switcher replacement is transactional and transfers view ownership" {
    const create_start = std.mem.indexOf(u8, native_ui_bridge_source, "fn createSpacesSidebar(") orelse
        return error.SpacesSidebarCreatorNotFound;
    const create_end = std.mem.indexOfPos(u8, native_ui_bridge_source, create_start, "    fn setSpaces(") orelse
        return error.SpacesSidebarCreatorEndNotFound;
    const create_body = native_ui_bridge_source[create_start..create_end];
    const replacement_at = std.mem.indexOf(u8, create_body, "const replacement = try space_switcher.create(") orelse
        return error.SpacesSidebarReplacementNotFound;
    const retire_at = std.mem.indexOf(u8, create_body, "previous.deinit()") orelse
        return error.SpacesSidebarRetirementNotFound;
    const publish_at = std.mem.indexOf(u8, create_body, "state.space_switcher = replacement") orelse
        return error.SpacesSidebarPublicationNotFound;
    try testing.expect(replacement_at < retire_at);
    try testing.expect(retire_at < publish_at);

    const attach_start = std.mem.indexOf(u8, space_switcher_source, "fn attach(") orelse
        return error.SpaceSwitcherAttachNotFound;
    const attach_end = std.mem.indexOfPos(u8, space_switcher_source, attach_start, "// Public surface") orelse
        return error.SpaceSwitcherAttachEndNotFound;
    const attach_body = space_switcher_source[attach_start..attach_end];
    for ([_][]const u8{ "msgSendVoid0(responder, \"release\")", "msgSendVoid0(control, \"release\")" }) |release| {
        try testing.expect(std.mem.indexOf(u8, attach_body, release) != null);
    }

    const switcher_create_start = std.mem.indexOf(u8, space_switcher_source, "pub fn create(") orelse
        return error.SpaceSwitcherCreatorNotFound;
    const switcher_create_body = space_switcher_source[switcher_create_start..];
    try testing.expect(std.mem.indexOf(u8, switcher_create_body, "errdefer allocator.free(self.id)") != null);
}

test "native file batches reserve and roll back as one mutation" {
    const start = std.mem.indexOf(u8, native_file_browser_source, "pub fn addFiles(") orelse
        return error.NativeFileBatchMethodNotFound;
    const end = std.mem.indexOfPos(u8, native_file_browser_source, start, "    pub fn clearFiles(") orelse
        return error.NativeFileClearMethodNotFound;
    const body = native_file_browser_source[start..end];

    try testing.expect(callsFunction(body, "ensureUnusedCapacity("));
    try testing.expect(std.mem.indexOf(u8, body, "errdefer") != null);
    try testing.expect(callsFunction(body, "shrinkRetainingCapacity("));
    try testing.expect(callsFunction(body, "appendAssumeCapacity("));
}

test "native UI teardown detaches views before freeing callback state" {
    const destroy_start = std.mem.indexOf(u8, native_ui_bridge_source, "    fn destroyComponent(") orelse
        return error.NativeUIDestroyNotFound;
    const destroy_end = std.mem.indexOfPos(u8, native_ui_bridge_source, destroy_start, "    /// Show a context menu") orelse
        return error.NativeUIDestroyEndNotFound;
    const destroy_body = native_ui_bridge_source[destroy_start..destroy_end];
    try testing.expect(std.mem.indexOf(u8, destroy_body, "state.destroySplitViewsUsingSidebar(sidebar)") != null);
    try testing.expect(std.mem.indexOf(u8, destroy_body, "state.destroySplitViewsUsingFileBrowser(browser)") != null);
    try testing.expect(std.mem.indexOf(u8, destroy_body, "state.restoreOriginalContent()") != null);

    for ([_]struct {
        source: []const u8,
        start: []const u8,
        detached: []const u8,
        freed: []const u8,
    }{
        .{
            .source = native_sidebar_source,
            .start = "    pub fn deinit(self: *NativeSidebar)",
            .detached = "setDataSource:",
            .freed = "self.data_source.deinit()",
        },
        .{
            .source = native_file_browser_source,
            .start = "    pub fn deinit(self: *NativeFileBrowser)",
            .detached = "setDataSource:",
            .freed = "self.data_source.deinit()",
        },
        .{
            .source = native_split_view_source,
            .start = "    pub fn deinit(self: *NativeSplitView)",
            .detached = "removeFromSuperview",
            .freed = "self.allocator.destroy(self)",
        },
    }) |case| {
        const start = std.mem.indexOf(u8, case.source, case.start) orelse
            return error.NativeUIComponentDeinitNotFound;
        const body = case.source[start..];
        const detached = std.mem.indexOf(u8, body, case.detached) orelse
            return error.NativeUIViewDetachNotFound;
        const freed = std.mem.indexOf(u8, body, case.freed) orelse
            return error.NativeUIStateFreeNotFound;
        try testing.expect(detached < freed);
    }
}

test "native UI restoration retains the webview across controller teardown" {
    const start = std.mem.indexOf(u8, native_ui_bridge_source, "fn restoreOriginalContent(") orelse
        return error.NativeUIRestoreNotFound;
    const end = std.mem.indexOfPos(u8, native_ui_bridge_source, start, "    fn destroySplitView(") orelse
        return error.NativeUIRestoreEndNotFound;
    const body = native_ui_bridge_source[start..end];
    const retain_at = std.mem.indexOf(u8, body, "msgSend0(original_webview, \"retain\")") orelse
        return error.NativeUIWebViewRetainNotFound;
    const deinit_at = std.mem.indexOf(u8, body, "controller.deinit()") orelse
        return error.NativeUIControllerDeinitNotFound;
    const restore_at = std.mem.indexOf(u8, body, "setContentView:\", original_webview") orelse
        return error.NativeUIWebViewRestoreNotFound;
    const release_at = std.mem.indexOf(u8, body, "msgSend0(original_webview, \"release\")") orelse
        return error.NativeUIWebViewReleaseNotFound;

    try testing.expect(retain_at < deinit_at);
    try testing.expect(deinit_at < restore_at);
    try testing.expect(restore_at < release_at);
}

test "destroy releases every retained runtime-window resource" {
    const bridge_start = std.mem.indexOf(u8, window_bridge_source, "fn destroy(") orelse
        return error.WindowDestroyHandlerNotFound;
    const bridge_end = std.mem.indexOfPos(u8, window_bridge_source, bridge_start, "    fn focus(") orelse
        return error.WindowDestroyHandlerEndNotFound;
    const bridge_body = window_bridge_source[bridge_start..bridge_end];
    try testing.expect(std.mem.indexOf(u8, bridge_body, "window_registry.nameOf(") != null);
    try testing.expect(callsFunction(bridge_body, "destroyWindow("));

    const native_start = std.mem.indexOf(u8, macos_source, "pub fn destroyWindow(") orelse
        return error.NativeWindowDestroyNotFound;
    const native_end = std.mem.indexOfPos(u8, macos_source, native_start, "pub fn hideWindow(") orelse
        return error.NativeWindowDestroyEndNotFound;
    const native_body = macos_source[native_start..native_end];
    for ([_][]const u8{
        "forgetWindowChrome(",
        "forgetWebMaterial(",
        "forgetContent(",
        "webview_recovery.zig",
        "window_registry.forgetOwner(",
        "window_registry.forget(",
        "setDelegate:",
        "setReleasedWhenClosed:",
    }) |contract| {
        try testing.expect(std.mem.indexOf(u8, native_body, contract) != null);
    }
}

test "web material state and collapse actions stay with their window" {
    // Material views used to live in six process globals. Constructing a
    // second window overwrote them, so the next collapse from main mutated the
    // second window. Both construction and mutation must now resolve a slot
    // from the window they were handed.
    const create_start = std.mem.indexOf(u8, macos_source, "fn createWebMaterialBackdrop(") orelse
        return error.WebMaterialConstructorNotFound;
    const create_body = enclosingFnBody(macos_source, create_start);
    try testing.expect(std.mem.indexOf(u8, create_body, "window: objc.id") != null);
    try testing.expect(callsFunction(create_body, "webMaterialSlot(window, true)"));

    const collapse_start = std.mem.indexOf(u8, macos_source, "pub fn setWebSidebarCollapsed(") orelse
        return error.WebMaterialCollapseNotFound;
    const collapse_body = enclosingFnBody(macos_source, collapse_start);
    try testing.expect(std.mem.indexOf(u8, collapse_body, "window: objc.id") != null);
    try testing.expect(callsFunction(collapse_body, "webMaterialSlot(window, false)"));

    for ([_][]const u8{
        "web_sidebar_material_container",
        "web_sidebar_material_view",
        "web_sidebar_material_tint",
        "web_sidebar_content_surface",
        "web_sidebar_toggle_button",
        "web_sidebar_width_stored",
    }) |old_global| {
        try testing.expect(std.mem.indexOf(u8, macos_source, old_global) == null);
    }
}

test "the reopen handler filters by that answer" {
    // Registration is worth nothing if the reopen loop stops asking. This
    // pins the one place the two meet.
    const start = std.mem.indexOf(u8, macos_source, "fn appShouldHandleReopen(") orelse
        return error.ReopenHandlerNotFound;
    const body = enclosingFnBody(macos_source, start);

    try testing.expect(callsFunction(body, "isCraftWindow("));
    try testing.expect(callsFunction(body, "makeKeyAndOrderFront:"));
}

test "a closed window survives long enough to be reopened" {
    // `releasedWhenClosed` defaults to YES for a window built with
    // `initWithContentRect:`, so without this the window is deallocated on
    // close and reopening it is a use-after-free rather than a missing
    // feature. It is set in the same helper that registers, so that a
    // constructor cannot get one without the other.
    const start = std.mem.indexOf(u8, macos_source, "fn keepWindowAfterClose(") orelse
        return error.HelperNotFound;
    const body = enclosingFnBody(macos_source, start);

    try testing.expect(callsFunction(body, "setReleasedWhenClosed:"));
    try testing.expect(callsFunction(body, "rememberCraftWindow("));
    try testing.expect(std.mem.indexOf(u8, body, "!void") != null);
}

test "retained window chrome observers are removed and reinstalled" {
    const observe_start = std.mem.indexOf(u8, macos_source, "pub fn observeWindowChrome(") orelse
        return error.WindowChromeObserverNotFound;
    const observe_body = enclosingFnBody(macos_source, observe_start);
    try testing.expect(std.mem.indexOf(u8, observe_body, "observer_tokens[index] = msgSend4(") != null);

    const forget_start = std.mem.indexOf(u8, macos_source, "fn forgetWindowChrome(") orelse
        return error.WindowChromeCleanupNotFound;
    const forget_body = enclosingFnBody(macos_source, forget_start);
    try testing.expect(callsFunction(forget_body, "removeObserver:"));

    // `windowWillClose` clears the slot, but close is not destruction: named
    // windows keep their DOM and can be shown again. Reopen must therefore
    // reinstall what close deliberately removed.
    const open_start = std.mem.indexOf(u8, macos_source, "pub fn openNamedWindow(") orelse
        return error.NamedWindowOpenNotFound;
    const open_body = enclosingFnBody(macos_source, open_start);
    try testing.expect(callsFunction(open_body, "observeWindowChrome(existing)"));
    try testing.expect(callsFunction(open_body, "window_registry.rememberNamedOwned("));
}

test "webview delegate ownership ends with its webview" {
    for ([_]struct { declaration: []const u8, association: []const u8 }{
        .{ .declaration = "pub fn setupUIDelegate(", .association = "ui_delegate_association_key" },
        .{ .declaration = "pub fn setupNavigationDelegate(", .association = "navigation_delegate_association_key" },
    }) |contract| {
        const start = std.mem.indexOf(u8, macos_source, contract.declaration) orelse
            return error.WebViewDelegateSetupNotFound;
        const body = enclosingFnBody(macos_source, start);
        try testing.expect(callsFunction(body, "objc.objc_setAssociatedObject("));
        try testing.expect(std.mem.indexOf(u8, body, contract.association) != null);
        try testing.expect(callsFunction(body, "msgSendVoid0(delegate, \"release\")"));
    }

    // The content controller retains a registered script-message handler. The
    // creator must drop its own +1 or controller teardown still leaves one.
    const handler_start = std.mem.indexOf(u8, macos_source, "pub fn setupScriptMessageHandler(") orelse
        return error.ScriptMessageHandlerSetupNotFound;
    const handler_body = enclosingFnBody(macos_source, handler_start);
    try testing.expect(callsFunction(handler_body, "addScriptMessageHandler:name:"));
    try testing.expect(callsFunction(handler_body, "msgSendVoid0(handler, \"release\")"));
}

test "the scan can actually find the constructors it claims to check" {
    // Guards the guard: every test above depends on `enclosingFnBody` locating
    // real function bodies. If the file's formatting changes such that it
    // returns the whole file, the checks above pass regardless of the code.
    const start = std.mem.indexOf(u8, macos_source, "fn isCraftWindow(").?;
    const body = enclosingFnBody(macos_source, start);

    try testing.expect(body.len > 0);
    // A body that large means the scan lost its bearings and every check above
    // is now looking at unrelated code.
    try testing.expect(body.len < macos_source.len / 10);
    try testing.expect(std.mem.startsWith(u8, body, "fn isCraftWindow("));
}

test "a commented-out call does not count as a call" {
    // The weakness that made the constructor check toothless: substring
    // matching cannot tell a call from a mention, so commenting a registration
    // out satisfied it. Found by doing exactly that and watching the test pass.
    try testing.expect(callsFunction("    keepWindowAfterClose(window);", "keepWindowAfterClose("));
    try testing.expect(!callsFunction("    // keepWindowAfterClose(window);", "keepWindowAfterClose("));
    try testing.expect(!callsFunction("    /// keepWindowAfterClose(window);", "keepWindowAfterClose("));
    try testing.expect(!callsFunction("    _ = x; // keepWindowAfterClose(window);", "keepWindowAfterClose("));
    // A real call on a line that also carries a trailing comment still counts.
    try testing.expect(callsFunction("    keepWindowAfterClose(window); // why", "keepWindowAfterClose("));
}
