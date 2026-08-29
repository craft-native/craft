const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const bridge_log = @import("bridge_log.zig");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;

/// What a page can ask about the process it is running inside: how much memory
/// it holds, whether it is foregrounded, whether it has a network, and a way to
/// get a line into the host's log.
///
/// The four are grouped because they share a property the migration cares
/// about: each one has an answer that can be *checked*. `usedMB` moves when the
/// app allocates, `getAppState` flips when the home button is pressed, a log
/// line appears in `simctl launch --console-pty` or it does not. None of them
/// can be satisfied by a stub that resolves and means nothing — which is what
/// the fallback path did before any of this existed, and what nine deleted
/// Android handlers did after it.
///
/// `getNetworkStatus` is the one that cannot be answered honestly from Zig in
/// this build, and it is declared `.unavailable` rather than guessed at. See
/// `network_status_reason`.
pub const A = struct {
    pub const get_memory_usage = "getMemoryUsage";
    pub const get_app_state = "getAppState";
    pub const get_network_status = "getNetworkStatus";
    pub const log = "log";
};

/// Why `getNetworkStatus` is reachable and does not work.
///
/// There is no synchronous, non-deprecated iOS API that answers "is there a
/// network". `NWPathMonitor` is the one Swift uses and the one to port, but it
/// needs `-framework Network` linked into every consuming app — the iOS Zig
/// target is a static library, so an unlinked framework is an undefined symbol
/// at *app* link time, not a Zig build failure — plus a hand-built Objective-C
/// block and a mutex-guarded cache, because the path handler runs on a
/// background queue where `evaluateJavaScript:` is illegal and
/// `request_context` (thread-local) is empty.
///
/// `SCNetworkReachability` would avoid the block and is deprecated since 17.4,
/// cannot see wired ethernet, and on the simulator reports the *host Mac's*
/// reachability. `getifaddrs` can say which interfaces are up but not whether
/// anything is reachable, so it cannot fill a field named `isConnected`.
///
/// The alternative to this declaration is not "a working handler", it is
/// `{"isConnected":true,"type":"unknown"}` — which is both what Swift returns
/// before its first path callback lands and what `bridge_network.zig:81`
/// hardcodes. A caller cannot tell that apart from a real reading, which makes
/// it strictly worse than an error.
pub const network_status_reason =
    "NWPathMonitor needs -framework Network linked into the app; no synchronous " ++
    "iOS API can answer isConnected without fabricating it";

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.get_memory_usage, .reply = .result },
    .{ .name = A.get_app_state, .reply = .result },
    // `.reply` stays `.result` because that is the contract the page's promise
    // is written against; `.status` is the field that carries the bad news. A
    // `.none` here would tell an app this action is fire-and-forget, which is a
    // different and equally wrong claim.
    .{
        .name = A.get_network_status,
        .reply = .result,
        .status = .unavailable,
        .reason = network_status_reason,
    },
    .{ .name = A.log, .reply = .result },
};

/// Which handler an action selects, or null for one this namespace does not
/// serve.
///
/// Split out from `handleMessage` so the table-versus-dispatch agreement can be
/// asserted on a host, where `task_info` would answer about the test runner and
/// `UIApplication` does not exist at all. A test that had to *call* the
/// handlers to discover which names route could only run on a device, which is
/// to say it would never run.
const Route = enum { memory_usage, app_state, network_status, log };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.get_memory_usage)) return .memory_usage;
    if (std.mem.eql(u8, action, A.get_app_state)) return .app_state;
    if (std.mem.eql(u8, action, A.get_network_status)) return .network_status;
    if (std.mem.eql(u8, action, A.log)) return .log;
    return null;
}

pub const DeviceBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const route = routeFor(action) orelse return bridge_error.BridgeError.UnknownAction;
        // Switched exhaustively rather than with an `else`, so adding a `Route`
        // without a handler is a compile error instead of a silently
        // unreachable action.
        return switch (route) {
            .memory_usage => self.getMemoryUsage(),
            .app_state => self.getAppState(),
            .network_status => getNetworkStatus(),
            .log => self.log(data),
        };
    }

    fn getMemoryUsage(self: *Self) !void {
        const info = try readTaskBasicInfo();
        var buf: [160]u8 = undefined;
        const json = try formatMemoryUsage(&buf, info);
        bridge_error.sendResultToJS(self.allocator, A.get_memory_usage, json);
    }

    fn getAppState(self: *Self) !void {
        const json = try appStateJson(try readApplicationState());
        bridge_error.sendResultToJS(self.allocator, A.get_app_state, json);
    }

    /// Refuse, with the reason the capability table already carries.
    ///
    /// `PlatformNotSupported` rather than `NativeCallFailed`: no native call
    /// was attempted, and saying one failed would send an app looking for a
    /// device problem that is really a missing `-framework Network`.
    ///
    /// A dispatcher note, because this error is load-bearing on the way out:
    /// `ios_dispatch.route` hands an action to the Swift shim only when a Zig
    /// handler returns `UnknownAction`. `DeviceBridge` is in that router's
    /// `mobile_bridges`, so this refusal takes `getNetworkStatus` away from the
    /// shim, which does answer it — with `isConnected` hardcoded `true` and
    /// `type` `"unknown"` (CraftApp.swift:399) until `NWPathMonitor`'s first
    /// callback lands, and correctly after. That is the whole trade: an error
    /// always, against a fabricated reading in the startup window and a real
    /// one afterwards. `bridge_mobile_display.zig` makes the same call for
    /// `lockOrientation`. Undoing it means linking Network and making this
    /// live, or dropping the action from `A` so the shim keeps serving it.
    fn getNetworkStatus() !void {
        return bridge_error.BridgeError.PlatformNotSupported;
    }

    /// The page's own log line, forwarded to the host sink.
    ///
    /// Delegated to `bridge_log` rather than reimplemented: it already owns the
    /// level table, the case-insensitive matching that keeps an unrecognised
    /// level audible instead of dropped, the `[page]` tag, and the 1024-byte
    /// clamp. A second copy here is the one that would drift.
    ///
    /// It also replies `{"ok":true}` under this same action name, which is why
    /// the table says `.result`. Swift's `case "log"` replies with nothing and
    /// `craft-bridge.js`'s `_send` registers no pending call, so the reply is
    /// dropped at the page — but the declaration has to describe what the code
    /// does, not what the page happens to do with it.
    ///
    /// There is exactly one payload shape to accept: `{level, message}` inside
    /// the envelope's `d`. The Swift template's `craft.log(msg)` posts a flat
    /// `{action:'log', message:msg}` with no `t` and no `d` at all, so it never
    /// reaches a handler — `ios_dispatch.handleMessage` rejects it at
    /// `MissingType`. Treating that as a second shape to support here would
    /// mean reading `message` off the envelope, which this bridge never sees.
    ///
    /// `bridge_log` defaults a missing `message` to `""`, so a payload without
    /// one records an empty `[page]` line and still acks. That is the desktop
    /// contract, shared deliberately rather than forked; `craft-bridge.js`
    /// always sends `String(m)`, so only a hand-rolled `_post` can hit it.
    fn log(self: *Self, data: []const u8) !void {
        var host = bridge_log.LogBridge.init(self.allocator);
        defer host.deinit();
        try host.handleMessage(A.log, data);
    }
};

// =============================================================================
// getMemoryUsage
// =============================================================================

/// `mach_task_basic_info`, from `<mach/task_info.h>`.
///
/// Written out rather than `@cImport`ed because the iOS static library builds
/// without an SDK sysroot. The layout is load-bearing in a way that is easy to
/// miss: `task_info` validates the caller's element count against the flavour's
/// own *before* writing anything, so a struct that is one field short does not
/// come back truncated — it comes back `KERN_INVALID_ARGUMENT` with the buffer
/// untouched. `system_enhancements.zig:932` passes 10 for this 48-byte struct
/// and has therefore reported zero bytes used on every call it has ever made.
const MachTimeValue = extern struct {
    seconds: i32,
    microseconds: i32,
};

const MachTaskBasicInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    resident_size_max: u64,
    user_time: MachTimeValue,
    system_time: MachTimeValue,
    policy: i32,
    suspend_count: i32,
};

const MACH_TASK_BASIC_INFO: c_uint = 20;

/// Counted in 4-byte `integer_t` units, derived from the struct rather than
/// written as 12, so a field added or removed above cannot leave the count
/// behind.
const MACH_TASK_BASIC_INFO_COUNT: c_uint = @sizeOf(MachTaskBasicInfo) / @sizeOf(i32);

const KERN_SUCCESS: c_int = 0;

const mach = struct {
    /// `mach_task_self()` is a macro over this variable in `<mach/mach_init.h>`.
    /// Reading the variable rather than calling the function form keeps this
    /// off a libSystem symbol that only exists because the macro predates it.
    extern "c" var mach_task_self_: c_uint;

    /// `kern_return_t task_info(task_name_t, task_flavor_t, task_info_t, mach_msg_type_number_t *)`.
    /// `task_info_t` is `integer_t *`; the flavour decides what is actually
    /// written there, which is why the count argument exists.
    extern "c" fn task_info(
        target_task: c_uint,
        flavor: c_uint,
        task_info_out: *anyopaque,
        task_info_count: *c_uint,
    ) c_int;
};

/// Ask the kernel how much memory this process holds.
///
/// This is mach, not UIKit — there is no Objective-C on this path and no main
/// thread requirement.
///
/// Deliberately not `NSProcessInfo.processInfo.physicalMemory`: that is total
/// device RAM, not process usage, and substituting it would put a number in
/// `usedMB` that is right by units and wrong by three orders of magnitude.
fn readTaskBasicInfo() !MachTaskBasicInfo {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    // Zeroed rather than `undefined`: if a future flavour revision fills fewer
    // fields than this struct has, the tail reads as zero instead of as stack
    // garbage that would look like a plausible byte count.
    var info: MachTaskBasicInfo = std.mem.zeroes(MachTaskBasicInfo);
    var count: c_uint = MACH_TASK_BASIC_INFO_COUNT;

    const kr = mach.task_info(
        mach.mach_task_self_,
        MACH_TASK_BASIC_INFO,
        @ptrCast(&info),
        &count,
    );
    // Swift answers a failure with `["usedMB": 0, "error": ...]`, which
    // *resolves* the page's promise carrying a fabricated zero. An error is the
    // only answer that lets a caller tell "this app uses no memory" from "the
    // reading could not be taken".
    if (kr != KERN_SUCCESS) return bridge_error.BridgeError.NativeCallFailed;

    return info;
}

/// `resident_size` in hundredths of a megabyte, rounded half up.
///
/// Integer arithmetic rather than `round(usedMB * 100) / 100` on a float, so
/// the rounding is a property of this function — assertable in a host test —
/// rather than of whatever the formatter does at the second decimal place.
/// 1 MiB is 1048576 bytes and half of it is 524288, which is the bias added
/// before the divide.
fn residentHundredthsMB(resident_size: u64) u64 {
    // A resident set would have to reach 1.8e17 bytes for this multiply to
    // overflow u64, which is about six orders of magnitude past any device.
    return (resident_size * 100 + 524288) / 1048576;
}

/// Render the reading as the JSON the page receives.
///
/// `usedMB` is the only field anything reads by name today
/// (`test-bridges.html`); `startProfiling`/`stopProfiling` take the whole
/// object opaquely and diff it. The raw byte counts are kept anyway because
/// they are what was actually measured — `usedMB` is a rounded view of
/// `residentSize`, and a caller that wants the exact number should not have to
/// un-round it.
fn formatMemoryUsage(buf: []u8, info: MachTaskBasicInfo) ![]const u8 {
    const hundredths = residentHundredthsMB(info.resident_size);
    return std.fmt.bufPrint(
        buf,
        "{{\"usedMB\":{d}.{d:0>2},\"residentSize\":{d},\"virtualSize\":{d}}}",
        .{ hundredths / 100, hundredths % 100, info.resident_size, info.virtual_size },
    );
}

// =============================================================================
// getAppState
// =============================================================================

/// `UIApplicationState`, from `UIKit/UIApplication.h`.
const UIApplicationStateActive: c_long = 0;
const UIApplicationStateInactive: c_long = 1;
const UIApplicationStateBackground: c_long = 2;

/// The reply for a `UIApplicationState` raw value.
///
/// A bare JSON string, not an object: `craft.d.ts` declares
/// `getAppState(): 'active' | 'inactive' | 'background'`, and Swift resolves
/// the callback with the bare string too. Wrapping it in `{"state":...}` would
/// be a nicer shape and would break every existing caller.
///
/// An unrecognised value is an error rather than a default. Swift's ternary
/// (`active ? ... : (background ? ... : "inactive")`) folds anything new into
/// `"inactive"`, so a fourth state added by a future iOS would be reported as a
/// real, wrong reading instead of as something craft does not understand.
fn appStateJson(state: c_long) ![]const u8 {
    return switch (state) {
        UIApplicationStateActive => "\"active\"",
        UIApplicationStateInactive => "\"inactive\"",
        UIApplicationStateBackground => "\"background\"",
        else => error.UnknownApplicationState,
    };
}

/// `[[UIApplication sharedApplication] applicationState]`.
///
/// Called straight from the dispatcher and not hopped onto a queue, which is
/// the non-obvious part: `applicationState` is main-thread-only, and this is
/// already on it. `ios.zig:craftDidReceiveScriptMessage` is a
/// `WKScriptMessageHandler` callback, WebKit delivers those on the main thread,
/// and `ios_dispatch.handleMessage` runs synchronously from there. A
/// `dispatch_async` here would be the bug, not the fix: it would move the reply
/// off the frame that holds this call's id, and `request_context` is
/// thread-local.
fn readApplicationState() !c_long {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const UIApplication = objc.objc_getClass("UIApplication") orelse return error.ClassNotFound;
    const sel_shared = objc.sel_registerName("sharedApplication") orelse return error.SelectorNotFound;

    // Nil here is a real condition, not a failure to check for form's sake: an
    // app extension has no shared application, and neither does a process that
    // has not reached `UIApplicationMain` yet (`ios.zig:683` records the same).
    // Reporting "active" in either case would be a reading nobody took.
    const app = objc.msgSendId(UIApplication, sel_shared) orelse return error.NoSharedApplication;

    const sel_state = objc.sel_registerName("applicationState") orelse return error.SelectorNotFound;
    // `UIApplicationState` is an `NSInteger`, so `c_long` on every 64-bit Apple
    // target. A narrower return type here would not fail to compile; it would
    // read the low half of the register and be right by luck for 0, 1 and 2.
    const Fn = *const fn (objc.id, objc.SEL) callconv(.c) c_long;
    const func: Fn = @ptrCast(&objc.objc_msgSend);
    return func(app, sel_state);
}

// =============================================================================
// Tests
//
// Host-only, and that is the constraint that shaped the code above: the two
// readings that need a device are behind `readTaskBasicInfo` and
// `readApplicationState`, and everything that decides what the page sees —
// routing, rounding, formatting, state mapping — is a pure function beside
// them.
// =============================================================================

const testing = std.testing;

test "every declared action is one the dispatcher routes" {
    // The failure this whole mechanism exists to prevent: a name in the table
    // that `handleMessage` has never heard of, which the manifest then promises
    // to an app.
    for (capability_actions) |decl| {
        if (routeFor(decl.name) == null) {
            std.debug.print("declared action '{s}' does not route\n", .{decl.name});
            return error.DeclaredActionDoesNotRoute;
        }
    }
}

test "every route the dispatcher has is a declared action" {
    // The other direction. `handleMessage` switches exhaustively over `Route`,
    // so a route with no handler is a compile error; this is what catches a
    // route with a handler and no declaration, which would be an action the
    // page can call and the manifest denies exists.
    //
    // Counting alone would not: two table rows naming the same action still
    // total four while leaving one route undeclared. So each declaration has to
    // claim a *distinct* route, and every route has to be claimed.
    var claimed = std.mem.zeroes([std.enums.values(Route).len]bool);
    for (capability_actions) |decl| {
        const route = routeFor(decl.name) orelse return error.DeclaredActionDoesNotRoute;
        const slot = @backingInt(route);
        if (claimed[slot]) {
            std.debug.print("two declarations route to {s}\n", .{@tagName(route)});
            return error.TwoDeclarationsShareARoute;
        }
        claimed[slot] = true;
    }
    for (claimed, 0..) |taken, slot| {
        if (!taken) {
            std.debug.print(
                "route {s} has a handler but no capability_actions row\n",
                .{@tagName(@as(Route, @fromBackingInt(@intCast(slot))))},
            );
            return error.RouteNotDeclared;
        }
    }
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = DeviceBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("noSuchAction", "{}"),
    );
    // Near misses too — casing and namespacing are how a real typo arrives.
    try testing.expectError(
        bridge_error.BridgeError.UnknownAction,
        bridge.handleMessage("getmemoryusage", "{}"),
    );
}

test "getNetworkStatus refuses rather than answering" {
    // The whole point of declaring it. `{"isConnected":true}` would resolve the
    // caller's promise with something nothing measured.
    var bridge = DeviceBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.PlatformNotSupported,
        bridge.handleMessage(A.get_network_status, "{}"),
    );
}

test "an unavailable action carries the reason with it" {
    // `capabilities.ActionDecl` requires it, and the reason is the entire value
    // of the declaration: "getNetworkStatus is unavailable" sends an app
    // hunting its own bug, the framework note does not.
    for (capability_actions) |decl| {
        if (decl.status == .unavailable) {
            try testing.expect(decl.reason != null);
            try testing.expect(decl.reason.?.len > 0);
        }
    }
}

test "the task_info struct is the size the flavour expects" {
    // 48 bytes, so 12 `integer_t` elements. The count is what `task_info`
    // validates before it writes anything, and getting it wrong is silent:
    // `system_enhancements.zig` passes 10 and has returned zeros ever since.
    try testing.expectEqual(@as(usize, 48), @sizeOf(MachTaskBasicInfo));
    try testing.expectEqual(@as(c_uint, 12), MACH_TASK_BASIC_INFO_COUNT);
}

test "the kernel accepts the flavour and count, and answers with a real reading" {
    // The size check above is a proxy, and `system_enhancements.zig` would pass
    // it too — its struct is also 48 bytes; it is the *count* it gets wrong, so
    // `task_info` rejects the call and leaves the buffer as it found it. Only
    // making the call tells the two apart.
    //
    // It runs here because this path is mach, not UIKit: no shared application,
    // no main thread, no device. The answer is about the test runner, and that
    // is enough — what is under test is that the declarations link, the
    // argument types are right, and the kernel does not refuse.
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const info = try readTaskBasicInfo();
    // A process far enough along to run a test holds pages. Zero is the exact
    // signature of a rejected count, which is the failure this exists to catch.
    try testing.expect(info.resident_size > 0);
    try testing.expect(info.virtual_size >= info.resident_size);
}

test "a missing UIApplication is reported rather than read past" {
    // macOS has no `UIApplication`, which is the same shape as the two cases
    // that matter on a device: an app extension, and a process that has not
    // reached `UIApplicationMain`. Without this the null check is code nothing
    // has ever taken, and the alternative to taking it is reporting a state
    // nobody read.
    //
    // Pinned to macOS rather than Darwin: on iOS the class is present and the
    // right answer is a state, not an error.
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;

    try testing.expectError(error.ClassNotFound, readApplicationState());
}

test "megabytes are rounded to two places, half up" {
    try testing.expectEqual(@as(u64, 0), residentHundredthsMB(0));
    try testing.expectEqual(@as(u64, 100), residentHundredthsMB(1024 * 1024));
    try testing.expectEqual(@as(u64, 150), residentHundredthsMB(1536 * 1024));
    // 123456789 / 1048576 = 117.7376…, so 11773.76 hundredths, rounding up.
    try testing.expectEqual(@as(u64, 11774), residentHundredthsMB(123456789));
    // Half a hundredth, exactly at the boundary, goes up.
    try testing.expectEqual(@as(u64, 1), residentHundredthsMB(5243));
    // And a hair under it does not.
    try testing.expectEqual(@as(u64, 0), residentHundredthsMB(5242));
}

test "the memory reply is shaped the way the page reads it" {
    var buf: [160]u8 = undefined;
    const json = try formatMemoryUsage(&buf, .{
        .virtual_size = 400000000,
        .resident_size = 123456789,
        .resident_size_max = 123456789,
        .user_time = .{ .seconds = 0, .microseconds = 0 },
        .system_time = .{ .seconds = 0, .microseconds = 0 },
        .policy = 0,
        .suspend_count = 0,
    });
    try testing.expectEqualStrings(
        "{\"usedMB\":117.74,\"residentSize\":123456789,\"virtualSize\":400000000}",
        json,
    );

    // And it is JSON, not just the right characters — `usedMB` in particular
    // has to survive as a number, which a zero-padded fraction can break.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(f64, 117.74), parsed.value.object.get("usedMB").?.float);
    try testing.expectEqual(@as(i64, 123456789), parsed.value.object.get("residentSize").?.integer);
}

test "a fraction below ten keeps its leading zero" {
    // `{d}.{d}` would render 4 hundredths as `1.4` — a tenfold error that no
    // parser would reject.
    var buf: [160]u8 = undefined;
    const json = try formatMemoryUsage(&buf, .{
        .virtual_size = 0,
        .resident_size = 1024 * 1024 + 41943, // ~1.04 MiB
        .resident_size_max = 0,
        .user_time = .{ .seconds = 0, .microseconds = 0 },
        .system_time = .{ .seconds = 0, .microseconds = 0 },
        .policy = 0,
        .suspend_count = 0,
    });
    try testing.expect(std.mem.startsWith(u8, json, "{\"usedMB\":1.04,"));
}

test "app states map to the three strings the SDK type declares" {
    try testing.expectEqualStrings("\"active\"", try appStateJson(0));
    try testing.expectEqualStrings("\"inactive\"", try appStateJson(1));
    try testing.expectEqualStrings("\"background\"", try appStateJson(2));
}

test "an app state UIKit has not defined yet is not folded into inactive" {
    // Swift's ternary reports any unknown value as "inactive", which is a real
    // answer that happens to be wrong. This says it does not know.
    try testing.expectError(error.UnknownApplicationState, appStateJson(3));
    try testing.expectError(error.UnknownApplicationState, appStateJson(-1));
}

test "the app state reply is a bare JSON string, not an object" {
    // `craft.d.ts` declares `getAppState(): 'active' | 'inactive' | 'background'`
    // and `craft-bridge.js` resolves with `payload || {}`, so the reply has to
    // parse as a string and be non-empty.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        try appStateJson(2),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("background", parsed.value.string);
}

test "a page's message and level survive the trip to the host sink" {
    // The field-name trap, checked where it can actually fail.
    //
    // The version this replaces re-declared `bridge_log`'s parse shape locally
    // and asserted that `std.json` filled it in — which is true of any two
    // matching structs and says nothing about the code under test. Rename
    // `message` inside `bridge_log` and that test stayed green while every page
    // log became an empty line, which is the exact bug it claimed to guard.
    //
    // So: drive the real dispatcher, point the real sink at a file, and read
    // the record back.
    const host_log = @import("log.zig");
    const io = @import("io_context.zig").get();
    const path = "craft-device-log-test.txt";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    // Put the sink back for whatever runs next in this binary; the config is
    // process-global, and leaving it muted would hide other tests' output.
    defer host_log.init(.{}) catch {};

    try host_log.init(.{
        .output_file = path,
        .min_level = .Debug,
        .enable_colors = false,
        .enable_timestamps = false,
        .mirror_to_stderr = false,
    });

    var bridge = DeviceBridge.init(testing.allocator);
    defer bridge.deinit();
    try bridge.handleMessage(A.log,
        \\{"level":"warn","message":"a page said this"}
    );
    // Closes the file, so the read below sees everything written.
    host_log.deinit();

    var read_buf: [4096]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const contents = read_buf[0..try file.readPositionalAll(io, &read_buf, 0)];

    const at = std.mem.indexOf(u8, contents, "[page] a page said this") orelse {
        std.debug.print("the page's message never reached the sink:\n{s}\n", .{contents});
        return error.PageMessageNotRecorded;
    };
    // The level, on that same record rather than anywhere in the file — a
    // stray WARN from an unrelated line would otherwise pass this for free.
    const line_start = if (std.mem.lastIndexOfScalar(u8, contents[0..at], '\n')) |nl| nl + 1 else 0;
    try testing.expect(std.mem.indexOf(u8, contents[line_start..at], "WARN") != null);
}

test "a log payload that will not parse is refused, not acknowledged" {
    // Also proves the delegation is real: `InvalidJSON` is `bridge_log`'s
    // answer, so seeing it here means `A.log` reached `LogBridge` rather than
    // something local that shrugged and replied ok.
    var bridge = DeviceBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.log, "not json"),
    );
}

test "the action names are the ones the Swift dispatcher answers" {
    // Spelled out because these strings are the wire contract, and a rename
    // here is invisible until a page stops being answered.
    // `ios_conformance_test` scans this file's `A` block against
    // `CraftApp.swift` and would catch a name the spec does not have; it would
    // not catch all four being renamed in step, which is what this holds.
    try testing.expectEqualStrings("getMemoryUsage", A.get_memory_usage);
    try testing.expectEqualStrings("getAppState", A.get_app_state);
    try testing.expectEqualStrings("getNetworkStatus", A.get_network_status);
    try testing.expectEqualStrings("log", A.log);
}
