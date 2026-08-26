//! craft's injected JavaScript, tested without a window.
//!
//! Six JS files are spliced into every webview craft opens, and until now none
//! of them had a test. The only way to exercise `window.craft.gestures` was to
//! launch an app and swipe a trackpad — so a regression there is found by a
//! person noticing the feel is wrong, which is not a test strategy.
//!
//! zig-js runs them headlessly: no WebKit, no window, no WebContent process,
//! and deterministic. These are the same bytes `@embedFile`d into the binary,
//! not a copy that can drift.
//!
//! Opt-in (`zig build test -Djs-tests`) because it needs the sibling checkout
//! at `~/Code/Libraries/zig-js`, which a consumer installing craft from npm
//! will not have. The rest of the suite must keep working without it.

const std = @import("std");
const js = @import("js");
const testing = std.testing;
const contracts = @import("bridge_contracts");
const bridge_menu = contracts.menu;
const capabilities = contracts.capabilities;
const capability_actions = contracts.capabilities_actions;
const prefs = contracts.prefs;
const prefs_actions = contracts.prefs_actions;
const shortcut_registry = contracts.shortcuts;
const bridge_error = contracts.errors;

// Supplied by build.zig as named imports — a test module cannot embed
// files outside its own package path.
const GESTURES = @embedFile("craft-gestures.js");
const BRIDGE = @embedFile("craft-bridge.js");

/// A context with the globals a browser would supply.
///
/// Deliberately minimal: whatever these scripts need beyond it is a dependency
/// on the DOM, and finding that out is half the value of running them here.
fn browserContext(allocator: std.mem.Allocator) !*js.Context {
    const ctx = try js.Context.create(allocator);
    errdefer ctx.destroy();
    _ = try ctx.evaluate(
        \\var window = {};
        \\var globalThis = globalThis || window;
    );
    return ctx;
}

/// Evaluate and read the result as text.
///
/// `Value.toString` takes an **arena** — it allocates internally and the slice
/// it hands back is not a single freeable allocation, so passing the testing
/// allocator and freeing the result aborts on "free of invalid memory". The
/// arena is owned by the caller and released whole.
fn stringOf(arena: std.mem.Allocator, ctx: *js.Context, source: []const u8) ![]const u8 {
    const value = try ctx.evaluate(source);
    return try value.toString(arena);
}

/// A context plus the arena its string conversions allocate from.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    ctx: *js.Context,

    fn init() !Fixture {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const ctx = try browserContext(testing.allocator);
        return .{ .arena = arena, .ctx = ctx };
    }

    fn deinit(self: *Fixture) void {
        self.ctx.destroy();
        self.arena.deinit();
    }

    fn text(self: *Fixture, source: []const u8) ![]const u8 {
        return stringOf(self.arena.allocator(), self.ctx, source);
    }
};

test "the gesture registry installs even when no host ever emits" {
    // This is what makes unconditional injection safe: callers feature-detect
    // `onSwipe` once and keep their wheel fallback. If it were absent on a
    // host without gesture support, every caller would need two code paths.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(GESTURES);

    const kind = try fx.text("typeof window.craft.gestures.onSwipe");
    try testing.expectEqualStrings("function", kind);
}

test "a subscriber receives phases in order, with their deltas" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(GESTURES);
    _ = try ctx.evaluate(
        \\var seen = [];
        \\window.craft.gestures.onSwipe(function (s) { seen.push(s.phase + ':' + s.deltaX) });
        \\window.craft.gestures._emit({ axis: 'horizontal', phase: 'begin',  deltaX: 4, deltaY: 0 });
        \\window.craft.gestures._emit({ axis: 'horizontal', phase: 'change', deltaX: 9, deltaY: 0 });
        \\window.craft.gestures._emit({ axis: 'horizontal', phase: 'end',    deltaX: 0, deltaY: 0 });
    );

    const seen = try fx.text("seen.join('|')");
    try testing.expectEqualStrings("begin:4|change:9|end:0", seen);
}

test "unsubscribing stops delivery" {
    // A leak here costs one listener per mount and only shows up after
    // navigating a few times, by which point the cause is hard to see.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(GESTURES);
    _ = try ctx.evaluate(
        \\var count = 0;
        \\var off = window.craft.gestures.onSwipe(function () { count++ });
        \\window.craft.gestures._emit({ axis: 'horizontal', phase: 'begin', deltaX: 1, deltaY: 0 });
        \\off();
        \\window.craft.gestures._emit({ axis: 'horizontal', phase: 'change', deltaX: 1, deltaY: 0 });
        \\window.craft.gestures._emit({ axis: 'horizontal', phase: 'end', deltaX: 0, deltaY: 0 });
    );

    const count = try fx.text("String(count)");
    try testing.expectEqualStrings("1", count);
}

test "a non-function subscriber is ignored rather than breaking the next emit" {
    // `onSwipe` must always return something callable: callers store the result
    // and invoke it on teardown without checking.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(GESTURES);
    _ = try ctx.evaluate(
        \\var offBad = window.craft.gestures.onSwipe(null);
        \\var reached = 0;
        \\window.craft.gestures.onSwipe(function () { reached++ });
        \\offBad();
        \\window.craft.gestures._emit({ axis: 'horizontal', phase: 'begin', deltaX: 1, deltaY: 0 });
    );

    const kind = try fx.text("typeof offBad");
    try testing.expectEqualStrings("function", kind);

    const reached = try fx.text("String(reached)");
    try testing.expectEqualStrings("1", reached);
}

test "installing twice keeps the first registry and its subscribers" {
    // The script is injected as a document-start user script, and a page that
    // navigates within the same webview can run it again. Replacing the
    // registry would silently drop everyone who had already subscribed.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(GESTURES);
    _ = try ctx.evaluate(
        \\var hits = 0;
        \\window.craft.gestures.onSwipe(function () { hits++ });
    );
    _ = try ctx.evaluate(GESTURES);
    _ = try ctx.evaluate("window.craft.gestures._emit({ axis: 'horizontal', phase: 'begin', deltaX: 1, deltaY: 0 });");

    const hits = try fx.text("String(hits)");
    try testing.expectEqualStrings("1", hits);
}

test "the bridge script parses" {
    // Not a behaviour test — the bridge needs `webkit.messageHandlers`, which
    // only a real webview has. But a syntax error in an injected script fails
    // silently in a webview: the page loads, the bridge is simply absent, and
    // every craft.* call rejects with no clue why. Parsing it here turns that
    // into a build failure.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = ctx.evaluate(BRIDGE) catch |err| switch (err) {
        // A JS-level throw is expected and fine: it means the source parsed and
        // execution got far enough to miss a browser API. A parse error is not,
        // and that is the failure this test exists to catch.
        error.Throw => return,
        else => return err,
    };
}

/// The slice of a webview the bridge script touches while it loads, plus a
/// recorder in place of `webkit.messageHandlers.craft`.
///
/// Everything native would do with a posted message begins with these bytes,
/// so capturing them is capturing the whole JS half of the contract.
/// `addEventListener` and `dispatchEvent` are real rather than stubs, because
/// half of what native sends the page arrives as an event — and a listener
/// registered for a name nothing dispatches is exactly the failure being
/// tested for.
const WEBVIEW_HOST =
    \\var posted = [];
    \\window.webkit = { messageHandlers: { craft: { postMessage: function (m) { posted.push(m) } } } };
    \\var listeners = {};
    \\window.addEventListener = function (name, fn) { (listeners[name] = listeners[name] || []).push(fn) };
    \\window.removeEventListener = function (name, fn) {
    \\  var q = listeners[name] || [];
    \\  var i = q.indexOf(fn);
    \\  if (i >= 0) q.splice(i, 1);
    \\};
    \\window.dispatchEvent = function (e) {
    \\  (listeners[e.type] || []).slice().forEach(function (fn) { fn(e) });
    \\  return true;
    \\};
    \\function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail }
    \\var document = { readyState: 'complete', addEventListener: function () {} };
    \\globalThis.setTimeout = function () { return 0 };
    \\globalThis.clearTimeout = function () {};
;
// The timer stubs are load-bearing rather than cosmetic. `_req` arms a
// 30-second reaping timeout inside its Promise executor, so without a
// `setTimeout` the executor throws a ReferenceError and every request-shaped
// call rejects before it has posted anything — which is not a failure mode
// worth reproducing in a test, and is invisible if you only ever exercise the
// fire-and-forget half of the bridge. Stubs that never fire keep it
// deterministic: these tests resolve their own calls explicitly.

test "craft.menu.set posts what bridge_menu.zig's parser reads" {
    // The one path that matters, end to end and without a window: the real
    // injected script builds the message, and the real native parser decodes
    // it. Both halves of the #27 contract mismatch were individually
    // "covered" — bridge.test.ts hand-built its bridge messages and the zig
    // menu tests asserted against a struct nothing rendered — so six menu
    // methods could no-op with a green suite. Only a test that carries one
    // payload across the boundary can catch that.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\window.craft.menu.set({ menus: [
        \\  { label: 'Edit', items: [
        \\    { role: 'copy', label: 'Copy', shortcut: 'cmd+c' },
        \\    { separator: true },
        \\    { id: 'find', label: 'Find in Page', shortcut: 'cmd+f', icon: 'search' },
        \\  ] },
        \\] });
    );

    try testing.expectEqualStrings("1", try fx.text("String(posted.length)"));

    // `t` picks the bridge, `a` picks the branch inside it. A wrong `a` is not
    // an error on the native side, only a log line — hence the shared constant.
    try testing.expectEqualStrings("menu", try fx.text("posted[0].t"));
    try testing.expectEqualStrings(bridge_menu.action_set_app_menu, try fx.text("posted[0].a"));

    const payload = try fx.text("posted[0].d");
    const parsed = try bridge_menu.parseAppMenu(testing.allocator, payload);
    defer parsed.deinit();

    const menus = parsed.value.menus orelse return error.NoMenusParsed;
    try testing.expectEqual(@as(usize, 1), menus.len);
    try testing.expectEqualStrings("Edit", menus[0].label.?);

    const items = menus[0].items orelse return error.NoItemsParsed;
    try testing.expectEqual(@as(usize, 3), items.len);

    // A role item: native wires it to an AppKit selector with a nil target, so
    // the responder chain performs it. The id is absent and must stay optional.
    try testing.expectEqualStrings("copy", items[0].role.?);
    try testing.expectEqualStrings("Copy", items[0].label.?);
    try testing.expectEqualStrings("cmd+c", items[0].shortcut.?);
    try testing.expect(items[0].id == null);

    try testing.expect(items[1].separator.?);

    // An id item: native routes clicks back to the page as `craft:menu:action`.
    try testing.expectEqualStrings("find", items[2].id.?);
    try testing.expectEqualStrings("Find in Page", items[2].label.?);
    try testing.expectEqualStrings("cmd+f", items[2].shortcut.?);
    try testing.expectEqualStrings("search", items[2].icon.?);
    try testing.expect(items[2].role == null);
}

test "an empty menu bar is a parse, not a failure" {
    // `craft.menu.set()` with no argument sends `{}`. Clearing the bar is a
    // legitimate thing to ask for, and it must not come back as InvalidJSON —
    // which would reject the call and leave the previous bar in place.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate("window.craft.menu.set();");

    const payload = try fx.text("posted[0].d");
    const parsed = try bridge_menu.parseAppMenu(testing.allocator, payload);
    defer parsed.deinit();

    try testing.expect(parsed.value.menus == null);
}

// =============================================================================
// Global shortcuts (#47)
// =============================================================================

/// A registry over a platform that grants every key, so these tests are about
/// the payload contract rather than about what the machine will hand over.
const GrantingPlatform = struct {
    var granted: usize = 0;

    fn register(_: u16, _: u32, _: u32) shortcut_registry.Ref {
        granted += 1;
        return @ptrFromInt(granted);
    }
    fn unregister(_: shortcut_registry.Ref) void {}
};

fn grantingRegistry() shortcut_registry.Registry {
    GrantingPlatform.granted = 0;
    return shortcut_registry.Registry.init(testing.allocator, .{
        .register = GrantingPlatform.register,
        .unregister = GrantingPlatform.unregister,
    });
}

test "craft.shortcuts.register posts what the native registry reads" {
    // The mismatch that made #47 unfixable-looking: the JS side has always
    // posted `{id, accelerator}` and the native side has always read `key` and
    // `modifiers`, so every registration failed its own validation long before
    // reaching the event monitor that was also never installed. Neither half
    // was wrong on its own terms, and neither half's tests could see it.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate("window.craft.shortcuts.register('harness.summon', 'Cmd+Shift+H');");

    try testing.expectEqualStrings("1", try fx.text("String(posted.length)"));
    try testing.expectEqualStrings("shortcuts", try fx.text("posted[0].t"));
    try testing.expectEqualStrings(shortcut_registry.action_register, try fx.text("posted[0].a"));

    var registry = grantingRegistry();
    defer registry.deinit();

    const entry = try registry.register(try fx.text("posted[0].d"));
    try testing.expectEqualStrings("harness.summon", entry.id);
    try testing.expectEqualStrings("Cmd+Shift+H", entry.accelerator);
    try testing.expectEqual(@as(u16, 0x04), entry.binding.keycode); // kVK_ANSI_H
    try testing.expect(entry.binding.modifiers.cmd);
    try testing.expect(entry.binding.modifiers.shift);
}

test "unregister, enable and disable post the id the registry looks up" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\window.craft.shortcuts.register('toggle', 'Cmd+Shift+H');
        \\window.craft.shortcuts.disable('toggle');
        \\window.craft.shortcuts.enable('toggle');
        \\window.craft.shortcuts.unregister('toggle');
    );

    var registry = grantingRegistry();
    defer registry.deinit();

    _ = try registry.register(try fx.text("posted[0].d"));
    try testing.expectEqualStrings(shortcut_registry.action_disable, try fx.text("posted[1].a"));
    try registry.setEnabled(try fx.text("posted[1].d"), false);
    try testing.expectEqualStrings(shortcut_registry.action_enable, try fx.text("posted[2].a"));
    try registry.setEnabled(try fx.text("posted[2].d"), true);
    try testing.expectEqualStrings(shortcut_registry.action_unregister, try fx.text("posted[3].a"));
    try registry.unregister(try fx.text("posted[3].d"));

    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "the reply to list is the shape the JS facade unwraps" {
    // `list()` resolves through `__craftBridgeResult`, and native used to
    // answer by calling `window.__craftShortcutList` — which nothing defines.
    // The promise hung for the full 30-second request timeout and rejected.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var listed = null;
        \\window.craft.shortcuts.list().then(function (s) { listed = s });
    );

    var registry = grantingRegistry();
    defer registry.deinit();
    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );

    const reply = try registry.listJson();
    defer testing.allocator.free(reply);

    // Exactly what `sendResultToJS` evaluates in the page.
    const script = try std.fmt.allocPrint(
        testing.allocator,
        "window.__craftBridgeResult('{s}',{s});",
        .{ shortcut_registry.action_list, reply },
    );
    defer testing.allocator.free(script);
    _ = try ctx.evaluate(script);

    try testing.expectEqualStrings("1", try fx.text("String(listed.length)"));
    try testing.expectEqualStrings("toggle", try fx.text("listed[0].id"));
    try testing.expectEqualStrings("Cmd+Shift+H", try fx.text("listed[0].accelerator"));
    try testing.expectEqualStrings("true", try fx.text("String(listed[0].enabled)"));
}

test "the reply to isRegistered is the shape the JS facade unwraps" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var answer = null;
        \\window.craft.shortcuts.isRegistered('toggle').then(function (v) { answer = v });
    );

    var registry = grantingRegistry();
    defer registry.deinit();
    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );

    const reply = try registry.isRegisteredJson(
        \\{"id":"toggle"}
    );
    defer testing.allocator.free(reply);

    const script = try std.fmt.allocPrint(
        testing.allocator,
        "window.__craftBridgeResult('{s}',{s});",
        .{ shortcut_registry.action_is_registered, reply },
    );
    defer testing.allocator.free(script);
    _ = try ctx.evaluate(script);

    try testing.expectEqualStrings("true", try fx.text("String(answer)"));
}

test "a triggered shortcut reaches the listener craft.shortcuts.on installs" {
    // The third mismatch: native called `window.__craftShortcutCallback`,
    // which nothing defines, while the JS side listened for `craft:shortcut`,
    // which nothing dispatched. Both sides looked implemented.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var fired = [];
        \\window.craft.shortcuts.on(function (d) { fired.push(d.id + '@' + d.accelerator) });
    );

    // The exact bytes `deliver` evaluates in the page.
    const detail = try shortcut_registry.triggeredDetail(testing.allocator, "harness.summon", "Cmd+Shift+H");
    defer testing.allocator.free(detail);
    const script = try shortcut_registry.eventScript(testing.allocator, "craft:shortcut", detail);
    defer testing.allocator.free(script);
    _ = try ctx.evaluate(script);

    try testing.expectEqualStrings("harness.summon@Cmd+Shift+H", try fx.text("fired.join('|')"));
}

test "a refused registration reaches craft.shortcuts.onError" {
    // `register` cannot be a request — its action name collides with other
    // bridges' in the pending queue — so this event is the only way an app
    // hears that the key it asked for belongs to someone else.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var failures = [];
        \\window.craft.shortcuts.onError(function (d) { failures.push(d.id + ':' + d.code) });
    );

    const detail = try shortcut_registry.errorDetail(
        testing.allocator,
        "harness.summon",
        "NATIVE_CALL_FAILED",
        "Native API call failed",
    );
    defer testing.allocator.free(detail);
    const script = try shortcut_registry.eventScript(testing.allocator, "craft:shortcut:error", detail);
    defer testing.allocator.free(script);
    _ = try ctx.evaluate(script);

    try testing.expectEqualStrings("harness.summon:NATIVE_CALL_FAILED", try fx.text("failures.join('|')"));
}

test "an accelerator the native side cannot bind is refused, not accepted" {
    // A registration that can never fire is the worst of the three outcomes:
    // the app waits forever for a key that was never reserved.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate("window.craft.shortcuts.register('oops', 'Cmd+Nonsense');");

    var registry = grantingRegistry();
    defer registry.deinit();
    try testing.expectError(
        error.InvalidParameter,
        registry.register(try fx.text("posted[0].d")),
    );
}

// =============================================================================
// Settings and preferences (#51)
// =============================================================================

/// A store over an in-memory backend, so these tests are about the JS/native
/// contract rather than about the preferences daemon.
fn memoryStore(mem: *prefs.MemoryBackend) prefs.Store {
    return .{ .backend = mem.backend() };
}

test "craft.prefs.set posts what the native decoder reads, for every scalar" {
    // The contract that matters: the type travels explicitly, so neither side
    // has to infer it. A boolean must not arrive as the number 1, and an
    // integer must not arrive as a float.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\window.craft.prefs.set('theme', 'dark');
        \\window.craft.prefs.set('dark', true);
        \\window.craft.prefs.set('fontSize', 13);
        \\window.craft.prefs.set('scale', 1.5);
    );

    try testing.expectEqualStrings("4", try fx.text("String(posted.length)"));

    const expected = [_]prefs.Value{
        .{ .string = "dark" },
        .{ .boolean = true },
        .{ .int = 13 },
        .{ .float = 1.5 },
    };
    for (expected, 0..) |want, index| {
        // One buffer per expression: `bufPrint` returns a slice into the
        // buffer, so reusing it would leave the earlier slice pointing at the
        // later string.
        var t_buf: [64]u8 = undefined;
        var a_buf: [64]u8 = undefined;
        var d_buf: [64]u8 = undefined;
        try testing.expectEqualStrings("prefs", try fx.text(try std.fmt.bufPrint(&t_buf, "posted[{d}].t", .{index})));
        try testing.expectEqualStrings(prefs_actions.set, try fx.text(try std.fmt.bufPrint(&a_buf, "posted[{d}].a", .{index})));

        const payload = try fx.text(try std.fmt.bufPrint(&d_buf, "posted[{d}].d", .{index}));
        const parsed = try std.json.parseFromSlice(prefs.SetShape, testing.allocator, payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        const decoded = try prefs.decodeSet(parsed.value);
        try testing.expect(decoded.value.eql(want));
    }
}

test "every wire action the prefs facade posts is namespaced" {
    // The assertion that stops someone shortening these back to bare names.
    // A bare `get` would be drained by keychain.get and tags.get; a bare
    // `set`/`delete`/`clear` would be *resolved* by other bridges that emit a
    // result under those names without their own facades ever waiting.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\window.craft.prefs.get('a');
        \\window.craft.prefs.set('a', 1);
        \\window.craft.prefs.delete('a');
        \\window.craft.prefs.clear();
        \\window.craft.prefs.keys();
        \\window.craft.prefs.info();
    );

    try testing.expectEqualStrings("6", try fx.text("String(posted.length)"));
    try testing.expectEqualStrings(
        "true",
        try fx.text("String(posted.every(function (m) { return m.a.indexOf('prefs:') === 0 }))"),
    );
    for ([_][]const u8{
        prefs_actions.get,   prefs_actions.set,  prefs_actions.delete,
        prefs_actions.clear, prefs_actions.keys, prefs_actions.info,
    }, 0..) |want, index| {
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings(want, try fx.text(try std.fmt.bufPrint(&buf, "posted[{d}].a", .{index})));
    }
}

test "a value prefs cannot store is refused before anything is posted" {
    // The refusal has to happen in the page, because the alternative is an
    // Objective-C exception in a process that cannot catch one.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var codes = [];
        \\function refuse(p) { p.then(function () { codes.push('RESOLVED') }, function (e) { codes.push(e.code) }) }
        \\refuse(window.craft.prefs.set('k', {}));
        \\refuse(window.craft.prefs.set('k', []));
        \\refuse(window.craft.prefs.set('k', null));
        \\refuse(window.craft.prefs.set('k', undefined));
        \\refuse(window.craft.prefs.set('k', NaN));
        \\refuse(window.craft.prefs.set('k', Infinity));
        \\refuse(window.craft.prefs.set('k', 'x'.repeat(9000)));
        \\refuse(window.craft.prefs.set('@bad', 1));
        \\refuse(window.craft.prefs.get('has space'));
    );

    try testing.expectEqualStrings("0", try fx.text("String(posted.length)"));
    try testing.expectEqualStrings(
        "PREFS_UNSUPPORTED_VALUE,PREFS_UNSUPPORTED_VALUE,PREFS_UNSUPPORTED_VALUE," ++
            "PREFS_UNSUPPORTED_VALUE,PREFS_NON_FINITE,PREFS_NON_FINITE," ++
            "PREFS_VALUE_TOO_LARGE,PREFS_BAD_KEY,PREFS_BAD_KEY",
        try fx.text("codes.join(',')"),
    );
}

test "the get reply the native side builds is the shape the facade unwraps" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var got = {};
        \\window.craft.prefs.get('dark').then(function (v) { got.dark = v; got.darkType = typeof v });
    );

    var mem = prefs.MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = memoryStore(&mem);
    try store.set("dark", .{ .boolean = true });

    const read = try store.get(testing.allocator, "dark");
    var reply: std.ArrayListUnmanaged(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try prefs.appendReadJson(testing.allocator, &reply, read);

    // Exactly what `sendResultToJS` evaluates in the page.
    const script = try std.fmt.allocPrint(
        testing.allocator,
        "window.__craftBridgeResult('{s}',{s});",
        .{ prefs_actions.get, reply.items },
    );
    defer testing.allocator.free(script);
    _ = try ctx.evaluate(script);

    // A stored boolean must arrive as `true`, not as `1`.
    try testing.expectEqualStrings("true", try fx.text("String(got.dark)"));
    try testing.expectEqualStrings("boolean", try fx.text("got.darkType"));
}

test "an absent key falls back, and a foreign value is an error rather than a shrug" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var out = [];
        \\window.craft.prefs.get('missing', 'fallback').then(function (v) { out.push(v) });
    );

    var reply: std.ArrayListUnmanaged(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try prefs.appendReadJson(testing.allocator, &reply, .absent);
    const absent_script = try std.fmt.allocPrint(testing.allocator, "window.__craftBridgeResult('{s}',{s});", .{ prefs_actions.get, reply.items });
    defer testing.allocator.free(absent_script);
    _ = try ctx.evaluate(absent_script);
    try testing.expectEqualStrings("fallback", try fx.text("out.join(',')"));

    // Something outside craft wrote an array into the key. Coercing it to
    // `undefined` would lose data silently; the app is told instead.
    _ = try ctx.evaluate(
        \\var failure = null;
        \\window.craft.prefs.get('list').then(function () {}, function (e) { failure = e.code });
    );
    reply.clearRetainingCapacity();
    try prefs.appendReadJson(testing.allocator, &reply, .{ .foreign = .{ .cf_type = "CFArray" } });
    const foreign_script = try std.fmt.allocPrint(testing.allocator, "window.__craftBridgeResult('{s}',{s});", .{ prefs_actions.get, reply.items });
    defer testing.allocator.free(foreign_script);
    _ = try ctx.evaluate(foreign_script);
    try testing.expectEqualStrings("PREFS_FOREIGN_VALUE", try fx.text("String(failure)"));
}

test "the keys reply is the shape the facade unwraps" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var listed = null;
        \\window.craft.prefs.keys().then(function (k) { listed = k });
    );

    var mem = prefs.MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = memoryStore(&mem);
    try store.set("theme", .{ .string = "dark" });
    try store.set("fontSize", .{ .int = 13 });

    const listed = try store.keys(testing.allocator);
    defer {
        for (listed) |k| testing.allocator.free(k);
        testing.allocator.free(listed);
    }
    var reply: std.ArrayListUnmanaged(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try prefs.appendKeysJson(testing.allocator, &reply, listed);

    const script = try std.fmt.allocPrint(testing.allocator, "window.__craftBridgeResult('{s}',{s});", .{ prefs_actions.keys, reply.items });
    defer testing.allocator.free(script);
    _ = try ctx.evaluate(script);

    try testing.expectEqualStrings("fontSize,theme", try fx.text("listed.join(',')"));
}

test "the Settings menu item reaches craft.settings.onOpen" {
    // Native evaluates exactly this string when the item is chosen — the same
    // compile-time constant `craftOpenSettingsCallback` passes to evalJS.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var opened = [];
        \\window.craft.settings.onOpen(function (d) { opened.push(d.source) });
    );

    _ = try ctx.evaluate("if(window.__craftSettingsOpen)window.__craftSettingsOpen();");
    try testing.expectEqualStrings("menu", try fx.text("opened.join(',')"));
}

test "settings.open reaches the same handler without touching native" {
    // A gear button in the app's own UI should land in the same place as Cmd+,
    // rather than needing a second code path.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var opened = [];
        \\window.craft.settings.onOpen(function (d) { opened.push(d.source) });
        \\window.craft.settings.open('toolbar');
    );

    try testing.expectEqualStrings("toolbar", try fx.text("opened.join(',')"));
    // Page-local: nothing crosses the bridge for it.
    try testing.expectEqualStrings("0", try fx.text("String(posted.length)"));
}

test "unsubscribing from settings stops delivery, and does not double-count" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var hits = 0;
        \\var off = window.craft.settings.onOpen(function () { hits++ });
        \\window.craft.settings.open();
        \\off();
        \\off();
        \\window.craft.settings.open();
    );

    try testing.expectEqualStrings("1", try fx.text("String(hits)"));
    // The listener counter drives a console hint when nothing is listening;
    // an unsubscribe called twice must not push it negative and silence it.
    try testing.expectEqualStrings("0", try fx.text("String(window.__craftSettingsListeners)"));
}

// =============================================================================
// Capabilities (#49)
// =============================================================================

/// A manifest with one of each namespace status, rendered by the real
/// renderer. The registry's actual contents are checked against the actual
/// dispatch chain in `test/capabilities_test.zig`; what matters here is that
/// the JSON native produces is the JSON the facade reads.
fn fixtureManifest() ![]u8 {
    const registry = [_]capabilities.NamespaceDecl{
        .{ .name = "clipboard", .status = .declared, .actions = &.{
            .{ .name = "readText", .reply = .result },
        } },
        .{ .name = "tray", .status = .declared, .actions = &.{
            .{ .name = "setTitle", .reply = .none },
            .{ .name = "destroy", .reply = .none, .status = .unavailable, .reason = "not implemented; call craft.tray.hide() instead" },
        } },
        .{ .name = "updater", .status = .unavailable, .reason = "the Sparkle framework is not linked into this build" },
        .{ .name = "marketplace", .status = .unrouted, .reason = "implemented but not routed" },
        .{ .name = "midi", .status = .undeclared },
    };
    return capabilities.buildManifest(testing.allocator, &registry);
}

test "craft.capabilities posts the action the native bridge dispatches on" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate("window.craft.capabilities();");

    try testing.expectEqualStrings("1", try fx.text("String(posted.length)"));
    try testing.expectEqualStrings("capabilities", try fx.text("posted[0].t"));
    try testing.expectEqualStrings(capability_actions.get, try fx.text("posted[0].a"));
}

test "the manifest native builds is the shape the facade reads" {
    // The contract carried across the boundary: the real registry rendered by
    // the real renderer, handed to the real facade.
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);
    _ = try ctx.evaluate(
        \\var caps = null;
        \\window.craft.capabilities().then(function (c) { caps = c });
    );

    const manifest = try fixtureManifest();
    defer testing.allocator.free(manifest);

    const script = try std.fmt.allocPrint(
        testing.allocator,
        "window.__craftBridgeResult('{s}',{s});",
        .{ capability_actions.get, manifest },
    );
    defer testing.allocator.free(script);
    _ = try ctx.evaluate(script);

    try testing.expectEqualStrings("declared", try fx.text("caps.namespaces.clipboard.status"));
    try testing.expectEqualStrings("unavailable", try fx.text("caps.namespaces.updater.status"));
    // The reason is the difference between an app hunting a bug in its own code
    // and an app knowing the answer.
    try testing.expect(std.mem.indexOf(u8, try fx.text("caps.namespaces.updater.reason"), "Sparkle") != null);
    // Not "false" — craft cannot prove a channel has no emitter, and saying it
    // could is what made the shipped manifest tell pages to disable working
    // features. The only two answers are "live" and "unknown".
    try testing.expectEqualStrings("unknown", try fx.text("caps.channels['craft:fs:change']"));
}

test "craft.supports answers from the manifest, and fails open without one" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const ctx = fx.ctx;

    _ = try ctx.evaluate(WEBVIEW_HOST);
    _ = try ctx.evaluate(BRIDGE);

    // Before anything has asked, everything is supported. An older binary with
    // no capabilities support must not make working code stop calling.
    try testing.expectEqualStrings("true", try fx.text("String(window.craft.supports('updater.checkForUpdates'))"));
    try testing.expectEqualStrings("true", try fx.text("String(window.craft.capabilitiesSync() === null)"));

    _ = try ctx.evaluate("window.craft.capabilities();");
    const manifest = try fixtureManifest();
    defer testing.allocator.free(manifest);
    const script = try std.fmt.allocPrint(
        testing.allocator,
        "window.__craftBridgeResult('{s}',{s});",
        .{ capability_actions.get, manifest },
    );
    defer testing.allocator.free(script);
    _ = try ctx.evaluate(script);

    // Now it answers from the manifest.
    try testing.expectEqualStrings("false", try fx.text("String(window.craft.supports('updater'))"));
    try testing.expectEqualStrings("false", try fx.text("String(window.craft.supports('tray.destroy'))"));
    try testing.expectEqualStrings("true", try fx.text("String(window.craft.supports('tray.setTitle'))"));
    try testing.expectEqualStrings("true", try fx.text("String(window.craft.supports('clipboard.readText'))"));
    // An undeclared namespace is not a missing one: craft claims nothing, so
    // the app should try it rather than skip it.
    try testing.expectEqualStrings("true", try fx.text("String(window.craft.supports('midi'))"));
    try testing.expectEqualStrings("true", try fx.text("String(window.craft.supports('midi.anything'))"));
    // A declared namespace does know its own action list, so an unknown action
    // in one really is absent.
    try testing.expectEqualStrings("false", try fx.text("String(window.craft.supports('clipboard.noSuchAction'))"));
    // `unrouted` is not `unavailable`, and both must answer false. This case is
    // why the namespace-status check exists separately from the action one: a
    // control experiment that deleted it left every other assertion here
    // passing.
    try testing.expectEqualStrings("false", try fx.text("String(window.craft.supports('marketplace'))"));
    try testing.expectEqualStrings("false", try fx.text("String(window.craft.supports('marketplace.list'))"));
}

// =============================================================================
// Reply correlation (#66)
// =============================================================================

/// Answer a call the way native does: the exact string `sendResultToJS`
/// evaluates in the page, built by the same function, id and all.
fn answer(fx: *Fixture, action: []const u8, payload: []const u8, id: ?u64) !void {
    const script = try bridge_error.formatResultJS(testing.allocator, action, payload, id);
    defer testing.allocator.free(script);
    _ = try fx.ctx.evaluate(script);
}

test "a call carries an id, and the reply that names it resolves that call" {
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.ctx.evaluate(WEBVIEW_HOST);
    _ = try fx.ctx.evaluate(BRIDGE);

    _ = try fx.ctx.evaluate(
        \\var got = null;
        \\window.craft.tags.get('/a').then(function (t) { got = t.join(',') });
    );

    // The page put its own id on the message; native reads it back out of the
    // envelope in `handleBridgeMessageJSON` and hands it to `formatResultJS`.
    const id_text = try fx.text("String(posted[0].i)");
    const id = try std.fmt.parseInt(u64, id_text, 10);
    try testing.expect(id > 0);

    try answer(&fx, "get", "{\"tags\":[\"red\"]}", id);
    try testing.expectEqualStrings("red", try fx.text("String(got)"));
}

test "two bridges sharing an action name do not swap replies" {
    // `get` is served by keychain and tags both. Answered out of order, which
    // is what a modal run loop or any slower handler produces, the action-name
    // queue alone hands each caller the other's payload.
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.ctx.evaluate(WEBVIEW_HOST);
    _ = try fx.ctx.evaluate(BRIDGE);

    _ = try fx.ctx.evaluate(
        \\var secret = 'unset';
        \\var labels = 'unset';
        \\window.craft.keychain.get('svc', 'acct').then(function (v) { secret = String(v) });
        \\window.craft.tags.get('/a').then(function (t) { labels = t.join(',') });
    );

    try testing.expectEqualStrings("keychain", try fx.text("posted[0].t"));
    try testing.expectEqualStrings("tags", try fx.text("posted[1].t"));

    const keychain_id = try std.fmt.parseInt(u64, try fx.text("String(posted[0].i)"), 10);
    const tags_id = try std.fmt.parseInt(u64, try fx.text("String(posted[1].i)"), 10);
    try testing.expect(keychain_id != tags_id);

    // Tags answers first — the ordering that used to swap them.
    try answer(&fx, "get", "{\"tags\":[\"red\",\"blue\"]}", tags_id);
    try answer(&fx, "get", "{\"value\":\"hunter2\"}", keychain_id);

    try testing.expectEqualStrings("hunter2", try fx.text("secret"));
    try testing.expectEqualStrings("red,blue", try fx.text("labels"));
}

test "a reply for an id nobody is waiting on resolves nobody" {
    // A late reply, or a second reply to a call already answered. Without an id
    // to check against, this payload went to whoever was at the head of the
    // action queue — a different call's answer, delivered as correct.
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.ctx.evaluate(WEBVIEW_HOST);
    _ = try fx.ctx.evaluate(BRIDGE);

    _ = try fx.ctx.evaluate(
        \\var got = 'unset';
        \\window.craft.tags.get('/a').then(function (t) { got = t.join(',') });
    );
    const id = try std.fmt.parseInt(u64, try fx.text("String(posted[0].i)"), 10);

    try answer(&fx, "get", "{\"tags\":[\"ghost\"]}", id + 1000);
    try testing.expectEqualStrings("unset", try fx.text("got"));

    try answer(&fx, "get", "{\"tags\":[\"mine\"]}", id);
    try testing.expectEqualStrings("mine", try fx.text("got"));
}

test "a reply that arrives without an id still resolves its caller" {
    // The fallback path, for a reply raised outside any dispatch — native has
    // no request to name. `formatResultJS` renders `null` and the page matches
    // by action name, exactly as it did before ids.
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.ctx.evaluate(WEBVIEW_HOST);
    _ = try fx.ctx.evaluate(BRIDGE);

    _ = try fx.ctx.evaluate(
        \\var got = 'unset';
        \\window.craft.tags.get('/a').then(function (t) { got = t.join(',') });
    );
    try answer(&fx, "get", "{\"tags\":[\"ok\"]}", null);
    try testing.expectEqualStrings("ok", try fx.text("got"));
}

test "fire-and-forget messages carry an id too" {
    // So a failure can name the exact send it came from instead of rejecting
    // whatever request happens to share its action name.
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.ctx.evaluate(WEBVIEW_HOST);
    _ = try fx.ctx.evaluate(BRIDGE);

    _ = try fx.ctx.evaluate("window.craft.keychain.set('svc', 'acct', 'pw');");
    try testing.expectEqualStrings("keychain", try fx.text("posted[0].t"));
    try testing.expectEqualStrings("true", try fx.text("String(typeof posted[0].i === 'number' && posted[0].i > 0)"));
}

test "a failure rejects the call it names and leaves the others alone" {
    // `isEnabled` is served by autoLaunch, bluetooth and crashReporter.
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.ctx.evaluate(WEBVIEW_HOST);
    _ = try fx.ctx.evaluate(BRIDGE);

    _ = try fx.ctx.evaluate(
        \\var autoLaunch = 'pending';
        \\var bluetooth = 'pending';
        \\window.craft.autoLaunch.isEnabled().then(
        \\  function (v) { autoLaunch = 'ok:' + v }, function (e) { autoLaunch = 'rejected' });
        \\window.craft.bluetooth.isEnabled().then(
        \\  function (v) { bluetooth = 'ok:' + v }, function (e) { bluetooth = 'rejected:' + e.message });
    );

    const bluetooth_id = try std.fmt.parseInt(u64, try fx.text("String(posted[1].i)"), 10);

    var ctx = bridge_error.ErrorContext.init(
        bridge_error.BridgeError.NativeCallFailed,
        "isEnabled",
        "no bluetooth",
    );
    ctx.request_id = bluetooth_id;
    const json = try ctx.toJSON(testing.allocator);
    defer testing.allocator.free(json);
    const script = try std.fmt.allocPrint(testing.allocator, "window.__craftBridgeError({s});", .{json});
    defer testing.allocator.free(script);
    _ = try fx.ctx.evaluate(script);

    try testing.expectEqualStrings("rejected:no bluetooth", try fx.text("bluetooth"));
    // The other bridge never heard about it and still answers normally.
    try testing.expectEqualStrings("pending", try fx.text("autoLaunch"));

    const auto_id = try std.fmt.parseInt(u64, try fx.text("String(posted[0].i)"), 10);
    try answer(&fx, "isEnabled", "{\"value\":true}", auto_id);
    try testing.expectEqualStrings("ok:true", try fx.text("autoLaunch"));
}

test "the menubar state reply no longer needs a queue of its own" {
    // `getState` used to be answered under an invented reply key,
    // `menubarCollapse:getState`, with a hand-rolled pending entry on the JS
    // side that had no timeout. It is an ordinary request now, and the reply
    // is matched by id like every other — which also keeps it apart from
    // screenSharing's `getState`, the seventh action name two bridges share.
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.ctx.evaluate(WEBVIEW_HOST);
    _ = try fx.ctx.evaluate(BRIDGE);

    _ = try fx.ctx.evaluate(
        \\var menubar = 'pending';
        \\var sharing = 'pending';
        \\window.craft.menubar.getState().then(function (s) { menubar = String(s.collapsed) });
        \\window.craft.screenSharing.getState().then(function (s) { sharing = String(s.sharing) });
    );

    try testing.expectEqualStrings("menubarCollapse", try fx.text("posted[0].t"));
    try testing.expectEqualStrings("getState", try fx.text("posted[0].a"));
    try testing.expectEqualStrings("screenSharing", try fx.text("posted[1].t"));

    const menubar_id = try std.fmt.parseInt(u64, try fx.text("String(posted[0].i)"), 10);
    const sharing_id = try std.fmt.parseInt(u64, try fx.text("String(posted[1].i)"), 10);

    try answer(&fx, "getState", "{\"sharing\":true}", sharing_id);
    try answer(&fx, "getState", "{\"collapsed\":true,\"initialized\":true,\"separatorHidden\":false}", menubar_id);

    try testing.expectEqualStrings("true", try fx.text("menubar"));
    try testing.expectEqualStrings("true", try fx.text("sharing"));

    // And nothing is left queued under the key it used to invent.
    try testing.expectEqualStrings("undefined", try fx.text("String(window.__craftBridgePending['menubarCollapse:getState'])"));
}
