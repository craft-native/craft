//! The `mobile` namespace's Bluetooth scan pair: `startBluetoothScan` and
//! `stopBluetoothScan`.
//!
//! ## The reply does not come from the call
//!
//! `startBluetoothScan` creates a `CBCentralManager` and returns. Nothing has
//! happened yet: Core Bluetooth powers the radio up asynchronously and then
//! calls `centralManagerDidUpdateState:`, and *that* is where Swift both starts
//! the scan and answers the page. So the action needs an `ios_async` ticket
//! even though its own body cannot fail in an interesting way, and the
//! delegate — not the handler — decides whether the page sees success.
//!
//! `queue: nil` in the Swift means the main queue, so every callback below
//! arrives on the thread the dispatch already ran on. That is why this module
//! has no mutex: there is exactly one thread involved, and adding a lock would
//! suggest otherwise.
//!
//! ## What a refusal means, and why it is not one code
//!
//! Swift rejects every non-`poweredOn` state with the single string
//! "Bluetooth not available". Five states reach that branch and they are not
//! the same fact: `unsupported` is a device that has no radio (every
//! simulator), `unauthorized` is a user who said no, `poweredOff` is a switch
//! the user can flip. The first is permanent, the second is a settings trip,
//! the third is a toggle — and a page that retries on all three is wrong twice.
//! So the state is mapped to three codes rather than one, and the state's raw
//! value is logged either way.
//!
//! ## Deduplication is a belt, not the mechanism
//!
//! Swift keeps every discovered `CBPeripheral` in an array and checks
//! membership before emitting. That array grows for the life of a scan and is
//! only cleared by `stopBluetoothScan`. It is also nearly redundant: the scan
//! is started with `CBCentralManagerScanOptionAllowDuplicatesKey: false`, which
//! is Core Bluetooth's own instruction to report each peripheral once. This
//! module keeps a bounded set for the same purpose and says what happens when
//! it fills — past `max_tracked`, a device may be re-announced. An unbounded
//! set that a long scan grows without limit would be the worse trade.
//!
//! ## `stopBluetoothScan` answers a call the spec leaves hanging
//!
//! It is ungated, and its Swift arm resolves `true` from the dispatcher rather
//! than from the function. If it runs while a `startBluetoothScan` is still
//! waiting for its first state callback, Swift's `pendingCallbackId` is simply
//! dropped — the start promise never settles. That is not carried across: the
//! pending ticket is answered `CANCELLED`, which is what actually happened.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const ios_events = @import("ios_events.zig");
const ios_delegate = @import("ios_delegate.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;
const Id = ?*anyopaque;
const is_darwin = builtin.target.os.tag.isDarwin();

pub const A = struct {
    pub const start_bluetooth_scan = "startBluetoothScan";
    pub const stop_bluetooth_scan = "stopBluetoothScan";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.start_bluetooth_scan, .reply = .result },
    .{ .name = A.stop_bluetooth_scan, .reply = .result },
};

/// `CBManagerState`. Only `poweredOn` starts a scan.
const CBManagerState = enum(c_long) {
    unknown = 0,
    resetting = 1,
    unsupported = 2,
    unauthorized = 3,
    powered_off = 4,
    powered_on = 5,
    _,

    /// The code a page gets for a state that cannot scan.
    ///
    /// Swift says "Bluetooth not available" for all of them. These three are
    /// different enough to branch on: only `unauthorized` is fixed by a trip to
    /// Settings, only `powered_off` is fixed by a toggle, and `unsupported` is
    /// never fixed at all.
    fn refusal(self: CBManagerState) BridgeError {
        return switch (self) {
            .unsupported => BridgeError.PlatformNotSupported,
            .unauthorized => BridgeError.PermissionDenied,
            // `unknown` and `resetting` are transient — Core Bluetooth will
            // call back again — but the page asked now and there is no scan
            // now, so it is told so rather than left waiting for a second
            // callback that may never come.
            else => BridgeError.NotFound,
        };
    }
};

/// `stopBluetoothScan`'s reply: the bare JSON `true`, resolved by the Swift
/// dispatcher rather than by the function it calls.
const stop_reply = "true";

/// `startBluetoothScan`'s reply once the radio reports `poweredOn`.
const start_reply = "true";

/// How many peripherals are remembered for deduplication.
///
/// Past this a device may be announced twice. That is the bounded failure;
/// Swift's unbounded array has no bound to exceed and grows for the length of
/// the scan instead. `allowDuplicates: false` means Core Bluetooth is already
/// suppressing repeats, so this set is a belt and reaching its limit is not
/// expected in a session a person is watching.
const max_tracked = 256;

/// A peripheral's `identifier.uuidString` is a canonical 36-character UUID.
const uuid_len = 36;

var tracked: [max_tracked][uuid_len]u8 = undefined;
var tracked_count: usize = 0;

/// Everything Core Bluetooth needs kept alive, and the call it will answer.
///
/// `CBCentralManager` holds its delegate weakly, so a released delegate is a
/// message to freed memory on the first state change rather than a leak. The
/// manager itself is retained because nothing else refers to it once
/// `startBluetoothScan` returns.
var manager: Id = null;
var delegate: Id = null;
var pending: ?ios_async.Ticket = null;

pub const BluetoothBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, _: []const u8) !void {
        if (std.mem.eql(u8, action, A.start_bluetooth_scan)) {
            try self.startScan();
        } else if (std.mem.eql(u8, action, A.stop_bluetooth_scan)) {
            try self.stopScan();
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// Power up the radio and answer from the state callback.
    ///
    /// Neither action takes a payload — the injected JS posts both with no
    /// second argument — so there is nothing to parse and nothing to refuse
    /// before the ticket.
    fn startScan(self: *Self) !void {
        _ = self;
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        const CBCentralManager = objc.objc_getClass("CBCentralManager") orelse {
            std.log.warn(
                "startBluetoothScan: CBCentralManager is not in this process; " ++
                    "the app does not link CoreBluetooth",
                .{},
            );
            return BridgeError.PlatformNotSupported;
        };

        // A second start while one is in flight would strand the first
        // ticket. Swift overwrites `pendingCallbackId` and does exactly that.
        if (pending) |existing| {
            std.log.warn(
                "startBluetoothScan: a scan is already starting; answering the first call " ++
                    "rather than replacing it",
                .{},
            );
            ios_async.deliverErrorCode(existing, BridgeError.Cancelled);
            pending = null;
        }

        // Before anything touches Core Bluetooth. iOS 13+ terminates a process
        // that creates a `CBCentralManager` without this key — not an
        // exception to catch, a kill — so the plist is checked first and the
        // refusal happens while refusing is still possible. Same hazard and
        // same guard as `bridge_mobile_location`'s usage-description check and
        // `bridge_mobile_imagepicker`'s camera one.
        try requireBluetoothUsageDescription();

        const instance = try delegateInstance();

        const ticket = ios_async.acquire(A.start_bluetooth_scan) orelse {
            std.log.warn(
                "startBluetoothScan: no free reply slot; {d} native calls are already awaiting one",
                .{ios_async.max_in_flight},
            );
            return BridgeError.NativeCallFailed;
        };
        errdefer ios_async.abandon(ticket);
        pending = ticket;

        const sel_alloc = objc.sel_registerName("alloc") orelse return BridgeError.NativeCallFailed;
        const sel_init = objc.sel_registerName("initWithDelegate:queue:") orelse
            return BridgeError.NativeCallFailed;
        const allocated = objc.msgSendId(CBCentralManager, sel_alloc) orelse
            return BridgeError.NativeCallFailed;

        // `queue: nil` is the main queue, which is the thread this already runs
        // on — so every callback lands here and the module needs no lock.
        releaseObject(manager);
        manager = objc.msgSendId2(allocated, sel_init, instance, @as(Id, null)) orelse {
            pending = null;
            return BridgeError.NativeCallFailed;
        };
    }

    /// Stop scanning, forget what was found, and resolve.
    ///
    /// Resolves even when no scan is running, because Swift's arm is
    /// `stopBluetoothScan(); resolveCallback(callbackId, result: true)` with
    /// the optional-chained calls inside doing nothing on nil.
    fn stopScan(self: *Self) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        stopAndForget();
        bridge_error.sendResultToJS(self.allocator, A.stop_bluetooth_scan, stop_reply);
    }
};

/// The shared teardown, so `stopBluetoothScan` and a failed start agree.
fn stopAndForget() void {
    if (manager) |live| {
        const sel_stop = objc.sel_registerName("stopScan");
        if (sel_stop) |sel| objc.msgSend(live, sel);
        releaseObject(live);
        manager = null;
    }
    tracked_count = 0;

    // A start still waiting for its first state callback is answered here
    // rather than dropped. Swift drops it, and the page's promise never
    // settles.
    if (pending) |ticket| {
        pending = null;
        ios_async.deliverErrorCode(ticket, BridgeError.Cancelled);
    }
}

/// The key iOS demands before a process may touch Core Bluetooth.
const key_bluetooth_usage = "NSBluetoothAlwaysUsageDescription";

/// Refuse unless this app declared why it wants Bluetooth.
///
/// The generator writes the key from `config.enableBluetooth`, so in a
/// generated app its presence and the flag agree — and the flag has already
/// been checked by `ios_dispatch` before this module runs. The check is still
/// here because the consequence of being wrong is a terminated process rather
/// than an error, and because a hand-edited plist can disagree with the config
/// that the dispatcher read.
fn requireBluetoothUsageDescription() !void {
    if (!is_darwin) return BridgeError.PlatformNotSupported;

    const NSBundle = objc.objc_getClass("NSBundle") orelse return BridgeError.NativeCallFailed;
    const sel_main = objc.sel_registerName("mainBundle") orelse return BridgeError.NativeCallFailed;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return BridgeError.NativeCallFailed;

    const NSString = objc.objc_getClass("NSString") orelse return BridgeError.NativeCallFailed;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse
        return BridgeError.NativeCallFailed;
    const ns_key = objc.msgSendId1(NSString, sel_string, @as([*:0]const u8, key_bluetooth_usage)) orelse
        return BridgeError.NativeCallFailed;

    const sel_lookup = objc.sel_registerName("objectForInfoDictionaryKey:") orelse
        return BridgeError.NativeCallFailed;
    if (objc.msgSendId1(bundle, sel_lookup, ns_key) != null) return;

    std.log.warn(
        "startBluetoothScan refused: Info.plist has no {s}, and creating a CBCentralManager " ++
            "without it terminates the process rather than failing",
        .{key_bluetooth_usage},
    );
    return BridgeError.PermissionDenied;
}

const delegate_class_name = "CraftBluetoothDelegate";

/// The delegate instance, built once and kept.
fn delegateInstance() !Id {
    if (delegate) |existing| return existing;

    const class = ios_delegate.defineClass(delegate_class_name, "NSObject", &.{
        .{
            .selector = "centralManagerDidUpdateState:",
            .imp = @ptrCast(&craftBluetoothDidUpdateState),
            .types = ios_delegate.enc.void_one_object,
        },
        .{
            .selector = "centralManager:didDiscoverPeripheral:advertisementData:RSSI:",
            .imp = @ptrCast(&craftBluetoothDidDiscover),
            .types = ios_delegate.enc.void_four_objects,
        },
    }) catch |err| {
        std.log.warn("startBluetoothScan: could not build the delegate class: {}", .{err});
        return BridgeError.NativeCallFailed;
    };

    // +1 and never released: `CBCentralManager` holds its delegate weakly, and
    // one instance serves every scan for the life of the process.
    delegate = ios_delegate.instantiate(class) catch |err| {
        std.log.warn("startBluetoothScan: could not instantiate the delegate: {}", .{err});
        return BridgeError.NativeCallFailed;
    };
    return delegate;
}

/// The radio reported a state. Start scanning, or refuse.
export fn craftBluetoothDidUpdateState(_: objc.id, _: objc.SEL, central: objc.id) callconv(.c) void {
    if (!is_darwin) return;

    const state = readState(central);

    // Core Bluetooth calls this on every state change for the life of the
    // manager, not only the first. A later change with no call waiting is not
    // an error — it is a user toggling the radio — so it is silent.
    const ticket = pending orelse {
        if (state == .powered_on) startScanning(central);
        return;
    };
    pending = null;

    if (state != .powered_on) {
        std.log.warn(
            "startBluetoothScan refused: CBManagerState is {d} ({s})",
            .{ @backingInt(state), @tagName(state) },
        );
        ios_async.deliverErrorCode(ticket, state.refusal());
        return;
    }

    startScanning(central);
    ios_async.deliverJson(ticket, start_reply);
}

fn readState(central: objc.id) CBManagerState {
    const sel = objc.sel_registerName("state") orelse return .unknown;
    const StateFn = *const fn (objc.id, objc.SEL) callconv(.c) c_long;
    const stateFn: StateFn = @ptrCast(&objc.objc_msgSend);
    return @fromBackingInt(@intCast(stateFn(central, sel)));
}

/// `scanForPeripheralsWithServices:options:` — every service, no duplicates.
fn startScanning(central: objc.id) void {
    const sel = objc.sel_registerName("scanForPeripheralsWithServices:options:") orelse return;
    const options = scanOptions();
    const ScanFn = *const fn (objc.id, objc.SEL, Id, Id) callconv(.c) void;
    const scan: ScanFn = @ptrCast(&objc.objc_msgSend);
    scan(central, sel, null, options);
}

/// `@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}`.
///
/// Null when the key symbol is missing, which Core Bluetooth reads as "no
/// options" — the same default. Rebuilding the key from its own spelling would
/// silently produce an unrecognised option instead, and an unrecognised option
/// means duplicates.
fn scanOptions() Id {
    const symbol = dlsym(RTLD_DEFAULT, "CBCentralManagerScanOptionAllowDuplicatesKey") orelse {
        std.log.warn(
            "startBluetoothScan: CBCentralManagerScanOptionAllowDuplicatesKey is not in this " ++
                "process; scanning with default options, which may report duplicates",
            .{},
        );
        return null;
    };
    const key_cell: *const Id = @ptrCast(@alignCast(symbol));
    const key = key_cell.* orelse return null;

    const NSNumber = objc.objc_getClass("NSNumber") orelse return null;
    const sel_bool = objc.sel_registerName("numberWithBool:") orelse return null;
    const NumberFn = *const fn (objc.Class, objc.SEL, bool) callconv(.c) Id;
    const numberWith: NumberFn = @ptrCast(&objc.objc_msgSend);
    const no = numberWith(NSNumber, sel_bool, false) orelse return null;

    const NSDictionary = objc.objc_getClass("NSDictionary") orelse return null;
    const sel_with = objc.sel_registerName("dictionaryWithObject:forKey:") orelse return null;
    return objc.msgSendId2(NSDictionary, sel_with, no, key);
}

/// A peripheral was seen. Announce it once.
export fn craftBluetoothDidDiscover(
    _: objc.id,
    _: objc.SEL,
    _: objc.id,
    peripheral: objc.id,
    _: objc.id,
    rssi: objc.id,
) callconv(.c) void {
    if (!is_darwin) return;

    const identifier = readIdentifier(peripheral) orelse return;
    if (alreadySeen(identifier)) return;
    remember(identifier);

    const allocator = std.heap.c_allocator;
    const detail = shapeDevice(allocator, identifier, peripheral, rssi) catch |err| {
        std.log.warn("bluetooth: could not shape a discovered device: {}", .{err});
        return;
    };
    defer allocator.free(detail);

    ios_events.emit(.bluetooth_device, detail);
}

/// `{"id":…,"name":…,"rssi":…}` — Swift's three keys.
fn shapeDevice(
    allocator: std.mem.Allocator,
    identifier: []const u8,
    peripheral: objc.id,
    rssi: objc.id,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"id\":");
    try appendJsonString(allocator, &out, identifier);
    try out.appendSlice(allocator, ",\"name\":");
    // Swift's `peripheral.name ?? "Unknown"`. Most peripherals do not
    // advertise a name, so this is the common case rather than the edge.
    try appendJsonString(allocator, &out, readName(peripheral) orelse "Unknown");
    try out.appendSlice(allocator, ",\"rssi\":");
    try out.print(allocator, "{d}", .{readRssi(rssi)});
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

fn readIdentifier(peripheral: objc.id) ?[]const u8 {
    const sel_identifier = objc.sel_registerName("identifier") orelse return null;
    const uuid = objc.msgSendId(peripheral, sel_identifier) orelse return null;
    const sel_string = objc.sel_registerName("UUIDString") orelse return null;
    const ns_string = objc.msgSendId(uuid, sel_string) orelse return null;
    const utf8 = objc.getNSStringUTF8(ns_string) orelse return null;
    return std.mem.span(utf8);
}

fn readName(peripheral: objc.id) ?[]const u8 {
    const sel = objc.sel_registerName("name") orelse return null;
    const ns_name = objc.msgSendId(peripheral, sel) orelse return null;
    const utf8 = objc.getNSStringUTF8(ns_name) orelse return null;
    return std.mem.span(utf8);
}

/// `RSSI.intValue` — Swift reads the NSNumber as an `Int`.
fn readRssi(rssi: objc.id) i64 {
    const sel = objc.sel_registerName("intValue") orelse return 0;
    const IntFn = *const fn (objc.id, objc.SEL) callconv(.c) c_int;
    const intFn: IntFn = @ptrCast(&objc.objc_msgSend);
    return intFn(rssi, sel);
}

fn alreadySeen(identifier: []const u8) bool {
    if (identifier.len != uuid_len) return false;
    var i: usize = 0;
    while (i < tracked_count) : (i += 1) {
        if (std.mem.eql(u8, &tracked[i], identifier)) return true;
    }
    return false;
}

fn remember(identifier: []const u8) void {
    if (identifier.len != uuid_len) return;
    if (tracked_count >= max_tracked) return;
    @memcpy(&tracked[tracked_count], identifier);
    tracked_count += 1;
}

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, out, s);
    try out.append(allocator, '"');
}

fn releaseObject(object: Id) void {
    const target = object orelse return;
    const sel = objc.sel_registerName("release") orelse return;
    objc.msgSend(target, sel);
}

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// `RTLD_DEFAULT` — search every image already loaded into the process.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

const testing = std.testing;

test "the action names match the Swift case labels exactly" {
    try testing.expectEqualStrings("startBluetoothScan", A.start_bluetooth_scan);
    try testing.expectEqualStrings("stopBluetoothScan", A.stop_bluetooth_scan);
}

test "both replies are the bare JSON true" {
    // `stopBluetoothScan` is resolved by the dispatcher, not by the function
    // it calls; `startBluetoothScan` is resolved from the state callback. Both
    // are `.fragmentsAllowed` booleans rather than objects.
    try testing.expectEqualStrings("true", start_reply);
    try testing.expectEqualStrings("true", stop_reply);
}

test "each unusable radio state gets the code that fits it" {
    // Swift says "Bluetooth not available" for all five. They are not the same
    // fact: unsupported is permanent, unauthorized is a settings trip,
    // poweredOff is a toggle — and a page that retries on all three is wrong
    // twice.
    try testing.expectEqual(BridgeError.PlatformNotSupported, CBManagerState.unsupported.refusal());
    try testing.expectEqual(BridgeError.PermissionDenied, CBManagerState.unauthorized.refusal());
    try testing.expectEqual(BridgeError.NotFound, CBManagerState.powered_off.refusal());
    try testing.expectEqual(BridgeError.NotFound, CBManagerState.unknown.refusal());
    try testing.expectEqual(BridgeError.NotFound, CBManagerState.resetting.refusal());
}

test "the state values are Core Bluetooth's, not a guess" {
    // These are read from `-[CBCentralManager state]` and compared against
    // `powered_on`. A wrong number here starts a scan on a radio that is off,
    // or refuses one that is on, with no diagnostic either way.
    try testing.expectEqual(@as(c_long, 0), @backingInt(CBManagerState.unknown));
    try testing.expectEqual(@as(c_long, 2), @backingInt(CBManagerState.unsupported));
    try testing.expectEqual(@as(c_long, 3), @backingInt(CBManagerState.unauthorized));
    try testing.expectEqual(@as(c_long, 4), @backingInt(CBManagerState.powered_off));
    try testing.expectEqual(@as(c_long, 5), @backingInt(CBManagerState.powered_on));
}

test "a device is announced once and then remembered" {
    tracked_count = 0;
    const a = "01234567-89AB-CDEF-0123-456789ABCDEF";
    const b = "FEDCBA98-7654-3210-FEDC-BA9876543210";

    try testing.expect(!alreadySeen(a));
    remember(a);
    try testing.expect(alreadySeen(a));
    try testing.expect(!alreadySeen(b));
    remember(b);
    try testing.expect(alreadySeen(b));
    try testing.expectEqual(@as(usize, 2), tracked_count);

    // A malformed identifier is neither matched nor stored: a short string
    // compared against a fixed-width slot would read past its end.
    try testing.expect(!alreadySeen("too-short"));
    remember("too-short");
    try testing.expectEqual(@as(usize, 2), tracked_count);

    tracked_count = 0;
}

test "the dedup set is bounded, and says so by re-announcing rather than growing" {
    // Swift's array grows for the life of the scan. This one stops at
    // max_tracked, past which a device may be announced twice — the bounded
    // failure, chosen over an unbounded one.
    tracked_count = max_tracked;
    const fresh = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
    remember(fresh);
    try testing.expectEqual(@as(usize, max_tracked), tracked_count);
    try testing.expect(!alreadySeen(fresh));
    tracked_count = 0;
}

test "a discovered device is shaped with Swift's three keys" {
    // The `name` fallback is the common case, not the edge: most peripherals
    // advertise no name at all.
    const json = try shapeDevice(testing.allocator, "01234567-89AB-CDEF-0123-456789ABCDEF", null, null);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"id\":\"01234567-89AB-CDEF-0123-456789ABCDEF\",\"name\":\"Unknown\",\"rssi\":0}",
        json,
    );
}

test "every declared action dispatches to something" {
    var bridge = BluetoothBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            continue;
        };
    }
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("getDeviceInfo", "{}"));
}

test "stopping with nothing running still answers, and strands no ticket" {
    // Swift's arm is `stopBluetoothScan(); resolveCallback(true)` with the
    // calls inside doing nothing on nil, so a stop with no scan is a success.
    if (!is_darwin) return error.SkipZigTest;

    manager = null;
    pending = null;
    stopAndForget();
    try testing.expect(pending == null);
    try testing.expectEqual(@as(usize, 0), tracked_count);
}

test "a process with no usage description is refused before Core Bluetooth is touched" {
    // The refusal has to happen before `CBCentralManager` is created, because
    // iOS kills the process rather than raising something catchable. The host
    // test binary has no such key, so this exercises the real path.
    if (!is_darwin) return error.SkipZigTest;

    try testing.expectError(BridgeError.PermissionDenied, requireBluetoothUsageDescription());
}

test "the discovery selector uses the four-object encoding" {
    // `RSSI:` is an NSNumber, not a primitive, so all four arguments are
    // objects. A narrower encoding registers fine and reads the signal
    // strength from the wrong register — a plausible number, silently wrong.
    try testing.expectEqualStrings("v@:@@@@", ios_delegate.enc.void_four_objects);
}
