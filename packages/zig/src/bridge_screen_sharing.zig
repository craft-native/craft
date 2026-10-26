const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const detect = @import("screen_sharing.zig");
const pending = @import("ios_async.zig");

const BridgeError = bridge_error.BridgeError;

/// Screen-sharing detection bridge.
///
/// Actions:
///   - `getState()`             — one-shot evaluation of every signal
///   - `watch({intervalMs})`    — poll and emit `craft:screenSharing:change`
///                                whenever the resolved state differs
///   - `unwatch()`              — stop polling
///
/// See `screen_sharing.zig` for what the signals are and why the indicator
/// table matches sharing *controls* rather than running applications.
///
/// Polling is the only option here: none of the four signals has a
/// notification. The default 2s cadence costs one `CGWindowListCopyWindowInfo`
/// call, which is a window-server round trip on the order of a millisecond, so
/// the idle cost is negligible; apps that want to trade latency for even less
/// work can raise the interval.
pub const ScreenSharingBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {
        stopWatching();
    }

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.dispatch(action, data) catch |err| {
            const mapped: BridgeError = switch (err) {
                BridgeError.InvalidJSON => BridgeError.InvalidJSON,
                BridgeError.InvalidParameter => BridgeError.InvalidParameter,
                BridgeError.UnknownAction => return err,
                else => BridgeError.NativeCallFailed,
            };
            bridge_error.sendErrorToJS(self.allocator, action, mapped);
        };
    }

    fn dispatch(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "getState")) {
            try self.getState();
        } else if (std.mem.eql(u8, action, "watch")) {
            try self.watch(data);
        } else if (std.mem.eql(u8, action, "unwatch")) {
            stopWatching();
            bridge_error.sendResultToJS(self.allocator, "unwatch", "{\"ok\":true}");
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn getState(self: *Self) !void {
        if (comptime builtin.os.tag != .macos) {
            const json = try buildStateJson(self.allocator, null);
            defer self.allocator.free(json);
            bridge_error.sendResultToJS(self.allocator, "getState", json);
            return;
        }
        const ticket = pending.acquire("getState") orelse return BridgeError.Busy;
        const allocator = std.heap.c_allocator;
        const work = allocator.create(CaptureWork) catch {
            pending.abandon(ticket);
            return error.OutOfMemory;
        };
        work.* = .{ .ticket = ticket };
        const thread = std.Thread.spawn(.{}, captureState, .{work}) catch {
            allocator.destroy(work);
            pending.abandon(ticket);
            return BridgeError.NativeCallFailed;
        };
        thread.detach();
    }

    fn watch(self: *Self, data: []const u8) !void {
        const Params = struct { intervalMs: u32 = 2000 };
        const parsed = std.json.parseFromSlice(Params, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();

        // Anything under 250ms is polling the window server hard enough to show
        // up in Activity Monitor for no perceptible gain; anything over a
        // minute stops being "detection".
        const interval = std.math.clamp(parsed.value.intervalMs, 250, 60_000);
        startWatching(interval);

        var buf: [64]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"intervalMs\":{d}}}", .{interval});
        bridge_error.sendResultToJS(self.allocator, "watch", json);
    }
};

// =============================================================================
// Detection
// =============================================================================

const State = struct {
    system: bool = false,
    remote: bool = false,
    conference: bool = false,
    recording: bool = false,
    digest: detect.Digest = .{},

    fn sharing(self: State) bool {
        return self.system or self.remote or self.conference or self.recording;
    }

    fn note(self: *State, kind: detect.Kind) void {
        switch (kind) {
            .system => self.system = true,
            .remote => self.remote = true,
            .conference => self.conference = true,
            .recording => self.recording = true,
        }
    }
};

// The watcher and one-shot callers share native AX servers and retained
// control-panel references. Serialize their bounded native evaluations.
var evaluation_mutex: @import("compat_mutex.zig").Mutex = .{};

/// Evaluate every signal, appending each matched window to `sources` (as JSON)
/// when a buffer is supplied. Returns the aggregate state.
fn evaluate(allocator: std.mem.Allocator, sources: ?*std.ArrayListUnmanaged(u8)) !State {
    var state: State = .{};
    if (comptime builtin.os.tag != .macos) return state;
    evaluation_mutex.lock();
    defer evaluation_mutex.unlock();

    readSessionSignals(&state);
    if (state.system) state.digest.add(.system, "CGSession", "screenIsShared");
    if (state.remote) state.digest.add(.remote, "CGSession", "offConsole");

    try readWindowSignals(allocator, &state, sources);
    var context = AccessibilityContext{ .allocator = allocator, .state = &state, .sources = sources };
    try @import("sharing_accessibility.zig").visit(&context, noteAccessibility);
    return state;
}

// A status check must never keep querying protected window metadata after
// macOS rejects the app's grant. Session signals and independently authorized
// Accessibility indicators remain available without Screen Recording access.
fn readWindowSignals(allocator: std.mem.Allocator, state: *State, sources: ?*std.ArrayListUnmanaged(u8)) !void {
    if (!CGPreflightScreenCaptureAccess()) return;
    const macos = @import("macos.zig");
    // kCGWindowListOptionOnScreenOnly (1) | kCGWindowListExcludeDesktopElements (16).
    // Conferencing clients retain hidden sharing windows after Stop Sharing.
    const list = CGWindowListCopyWindowInfo(0x11, 0) orelse return;
    defer CFRelease(list);

    const CountFn = *const fn (?*anyopaque, macos.objc.SEL) callconv(.c) c_ulong;
    const count_fn: CountFn = @ptrCast(&macos.objc.objc_msgSend);
    const count = count_fn(list, macos.sel("count"));

    const owner_key = macos.createNSString("kCGWindowOwnerName");
    const name_key = macos.createNSString("kCGWindowName");

    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        const dict = macos.msgSend1(@as(macos.objc.id, @ptrCast(@constCast(list))), "objectAtIndex:", i);
        if (@intFromPtr(dict) == 0) continue;

        const owner = nsStringSlice(macos.msgSend1(dict, "objectForKey:", owner_key)) orelse continue;
        const window = nsStringSlice(macos.msgSend1(dict, "objectForKey:", name_key)) orelse "";

        const kind = detect.matchWindow(&detect.default_indicators, owner, window) orelse continue;
        try noteSource(allocator, state, sources, kind, owner, window);
    }
}

const AccessibilityContext = struct {
    allocator: std.mem.Allocator,
    state: *State,
    sources: ?*std.ArrayListUnmanaged(u8),
};

fn noteAccessibility(context: *AccessibilityContext, app: []const u8, window: []const u8) !void {
    try noteSource(context.allocator, context.state, context.sources, .conference, app, window);
}

fn noteSource(allocator: std.mem.Allocator, state: *State, sources: ?*std.ArrayListUnmanaged(u8), kind: detect.Kind, app: []const u8, window: []const u8) !void {
    state.note(kind);
    state.digest.add(kind, app, window);
    if (sources) |out| {
        if (out.items.len > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"app\":\"");
        try bridge_error.appendJsonEscaped(allocator, out, app);
        try out.appendSlice(allocator, "\",\"window\":\"");
        try bridge_error.appendJsonEscaped(allocator, out, window);
        try out.appendSlice(allocator, "\",\"kind\":\"");
        try out.appendSlice(allocator, kind.name());
        try out.appendSlice(allocator, "\"}");
    }
}

const CaptureWork = struct {
    ticket: ?pending.Ticket = null,
    generation: u64 = 0,
    state: State = .{},
    json: ?[]u8 = null,
};

fn captureState(work: *CaptureWork) void {
    const allocator = std.heap.c_allocator;
    const macos = @import("macos.zig");
    const pool = macos.msgSend0(macos.msgSend0(macos.getClass("NSAutoreleasePool"), "alloc"), "init");
    defer _ = macos.msgSend0(pool, "drain");
    // Failed or incomplete native reads must not publish an idle state. The
    // watcher retries on its next tick; a one-shot caller receives an error.
    work.json = buildStateJson(allocator, &work.state) catch null;
    if (work.ticket) |ticket| {
        defer allocator.destroy(work);
        if (work.json) |json| {
            defer allocator.free(json);
            pending.deliverJson(ticket, json);
        } else pending.deliverErrorCode(ticket, BridgeError.NativeCallFailed);
    } else dispatch_async_f(&_dispatch_main_q, work, deliverWatch);
}

/// `CGSSessionScreenIsShared` only appears in the session dictionary while the
/// session is genuinely shared, so its absence is the "not shared" answer
/// rather than an error. `kCGSSessionOnConsoleKey` going false means the
/// session is being driven from somewhere other than this console.
fn readSessionSignals(state: *State) void {
    if (comptime builtin.os.tag != .macos) return;
    const macos = @import("macos.zig");

    const dict = CGSessionCopyCurrentDictionary() orelse return;
    defer CFRelease(dict);
    const dict_id: macos.objc.id = @ptrCast(@constCast(dict));

    if (dictBool(dict_id, "CGSSessionScreenIsShared")) |shared| {
        if (shared) state.system = true;
    }
    if (dictBool(dict_id, "kCGSSessionOnConsoleKey")) |on_console| {
        if (!on_console) state.remote = true;
    }
}

fn dictBool(dict: @import("macos.zig").objc.id, key: []const u8) ?bool {
    const macos = @import("macos.zig");
    const value = macos.msgSend1(dict, "objectForKey:", macos.createNSString(key));
    if (@intFromPtr(value) == 0) return null;
    const Fn = *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) bool;
    const f: Fn = @ptrCast(&macos.objc.objc_msgSend);
    return f(value, macos.sel("boolValue"));
}

fn nsStringSlice(str: @import("macos.zig").objc.id) ?[]const u8 {
    if (@intFromPtr(str) == 0) return null;
    const macos = @import("macos.zig");
    const utf8 = macos.msgSend0(str, "UTF8String");
    if (@intFromPtr(utf8) == 0) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
}

/// Build the full `getState` payload. `out_state` receives the evaluated state
/// so the watcher can reuse the same walk for its change check.
fn buildStateJson(allocator: std.mem.Allocator, out_state: ?*State) ![]u8 {
    var sources: std.ArrayListUnmanaged(u8) = .empty;
    defer sources.deinit(allocator);

    const state = try evaluate(allocator, &sources);
    if (out_state) |slot| slot.* = state;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"sharing\":");
    try out.appendSlice(allocator, if (state.sharing()) "true" else "false");
    try out.appendSlice(allocator, ",\"signals\":{\"systemScreenShare\":");
    try out.appendSlice(allocator, if (state.system) "true" else "false");
    try out.appendSlice(allocator, ",\"remoteSession\":");
    try out.appendSlice(allocator, if (state.remote) "true" else "false");
    try out.appendSlice(allocator, ",\"conferenceSharing\":");
    try out.appendSlice(allocator, if (state.conference) "true" else "false");
    try out.appendSlice(allocator, ",\"screenRecording\":");
    try out.appendSlice(allocator, if (state.recording) "true" else "false");
    try out.appendSlice(allocator, "},\"sources\":[");
    try out.appendSlice(allocator, sources.items);
    try out.appendSlice(allocator, "]}");

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Watcher — NSTimer on the main run loop
// =============================================================================

var watcher_instance: @import("macos.zig").objc.id = null;
var watcher_timer: @import("macos.zig").objc.id = null;
var watcher_activity: @import("macos.zig").objc.id = null;
var last_digest: u64 = 0;
var have_last_digest = false;
var watcher_generation: u64 = 0;
var watcher_busy = false;

fn startWatching(interval_ms: u32) void {
    if (comptime builtin.os.tag != .macos) return;
    const macos = @import("macos.zig");
    const objc = macos.objc;

    stopWatching();

    if (watcher_instance == null) {
        const class_name = "CraftScreenSharingWatcher";
        var cls = objc.objc_getClass(class_name);
        if (cls == null) {
            cls = objc.objc_allocateClassPair(macos.getClass("NSObject"), class_name, 0);
            if (cls == null) return;
            const imp: objc.IMP = @ptrCast(@constCast(&handleWatchTick));
            _ = objc.class_addMethod(cls, macos.sel("onScreenSharingTick:"), imp, "v@:@");
            objc.objc_registerClassPair(cls);
        }
        watcher_instance = macos.msgSend0(macos.msgSend0(cls, "alloc"), "init");
        if (@intFromPtr(watcher_instance) == 0) return;
    }

    // Monitoring is explicitly requested work that must continue while a tray
    // popover is hidden. Allow normal system/display sleep, but keep App Nap
    // from suspending the native watcher and its WebKit event consumer.
    watcher_activity = @import("background_activity.zig").begin("Monitor screen sharing requested by the application");

    // Emit the current state immediately so a subscriber never has to wait a
    // full interval to learn where things stand.
    have_last_digest = false;
    emitIfChanged();

    const NSTimer = macos.getClass("NSTimer");
    const Fn = *const fn (objc.id, objc.SEL, f64, objc.id, objc.SEL, objc.id, bool) callconv(.c) objc.id;
    const f: Fn = @ptrCast(&objc.objc_msgSend);
    watcher_timer = f(
        NSTimer,
        macos.sel("timerWithTimeInterval:target:selector:userInfo:repeats:"),
        @as(f64, @floatFromInt(interval_ms)) / 1000.0,
        watcher_instance,
        macos.sel("onScreenSharingTick:"),
        @as(objc.id, null),
        true,
    );
    // Menu tracking switches AppKit's run-loop mode. Sharing detection must
    // continue while a menubar menu is open or a window is being dragged.
    const run_loop = macos.msgSend0(macos.getClass("NSRunLoop"), "mainRunLoop");
    _ = macos.msgSend2(run_loop, "addTimer:forMode:", watcher_timer, macos.createNSString("kCFRunLoopCommonModes"));
}

fn stopWatching() void {
    if (comptime builtin.os.tag != .macos) return;
    const macos = @import("macos.zig");
    if (@intFromPtr(watcher_timer) != 0) {
        _ = macos.msgSend0(watcher_timer, "invalidate");
        watcher_timer = null;
    }
    @import("background_activity.zig").end(watcher_activity);
    watcher_activity = null;
    have_last_digest = false;
    watcher_generation +%= 1;
}

export fn handleWatchTick(
    _: @import("macos.zig").objc.id,
    _: @import("macos.zig").objc.SEL,
    _: @import("macos.zig").objc.id,
) callconv(.c) void {
    emitIfChanged();
}

/// Evaluate, and only touch the webview when the resolved state actually
/// differs. A share that stays up for an hour costs one window-list walk per
/// interval and zero JS evaluations.
fn emitIfChanged() void {
    if (comptime builtin.os.tag != .macos) return;
    if (watcher_busy) return;
    const allocator = std.heap.c_allocator;
    const work = allocator.create(CaptureWork) catch return;
    work.* = .{ .generation = watcher_generation };
    watcher_busy = true;
    const thread = std.Thread.spawn(.{}, captureState, .{work}) catch {
        watcher_busy = false;
        allocator.destroy(work);
        return;
    };
    thread.detach();
}

fn deliverWatch(raw: ?*anyopaque) callconv(.c) void {
    const work: *CaptureWork = @ptrCast(@alignCast(raw orelse return));
    const allocator = std.heap.c_allocator;
    defer allocator.destroy(work);
    defer if (work.json) |json| allocator.free(json);
    watcher_busy = false;
    if (work.generation != watcher_generation or watcher_timer == null) return;
    const json = work.json orelse return;
    const digest = work.state.digest.value;
    if (have_last_digest and digest == last_digest) return;
    last_digest = digest;
    have_last_digest = true;

    const macos = @import("macos.zig");
    const webview = macos.getGlobalWebView() orelse return;

    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(allocator);
    script.appendSlice(allocator, "if(window.dispatchEvent)window.dispatchEvent(new CustomEvent('craft:screenSharing:change',{detail:") catch return;
    script.appendSlice(allocator, json) catch return;
    script.appendSlice(allocator, "}));") catch return;
    script.append(allocator, 0) catch return;

    const NSString = macos.getClass("NSString");
    const js = macos.msgSend1(NSString, "stringWithUTF8String:", @as([*:0]const u8, @ptrCast(script.items.ptr)));
    _ = macos.msgSend2(webview, "evaluateJavaScript:completionHandler:", js, @as(?*anyopaque, null));
}

// =============================================================================
// CoreGraphics
// =============================================================================

extern "c" fn CGPreflightScreenCaptureAccess() bool;
extern "c" fn CGWindowListCopyWindowInfo(options: u32, relative_to: u32) ?*anyopaque;
extern "c" fn CGSessionCopyCurrentDictionary() ?*anyopaque;
extern "c" fn CFRelease(cf: ?*anyopaque) void;
extern "c" fn dispatch_async_f(queue: *anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern var _dispatch_main_q: anyopaque;

// =============================================================================
// Tests
// =============================================================================

test "State.sharing is the disjunction of every signal" {
    var s: State = .{};
    try std.testing.expect(!s.sharing());
    s.note(.conference);
    try std.testing.expect(s.sharing());
    try std.testing.expect(s.conference and !s.system and !s.remote and !s.recording);
}

test "State.note maps each kind to its own flag" {
    inline for (.{ .system, .remote, .conference, .recording }) |kind| {
        var s: State = .{};
        s.note(kind);
        try std.testing.expect(s.sharing());
    }
}
