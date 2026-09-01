//! Two of the `mobile` namespace's three HealthKit actions:
//! `requestHealthAuthorization` and `getHealthData`.
//!
//! ## Why two and not three, when the last two pairs moved whole
//!
//! `saveHealthWorkout` stays with the Swift shim this round, and the reason is
//! the opposite of the one that kept `openPDF`/`closePDF` and the audio pair
//! together. Those shared *module state*: a controller one stored and the other
//! dismissed, a recorder one built and the other stopped. Splitting them left
//! half a state machine in each language.
//!
//! Nothing flows between these three. The only thing they share is an
//! `HKHealthStore`, which is a stateless handle — authorization lives in the
//! system database, not in the object, and Apple supports more than one store
//! per process. So Zig owning two of them and Swift the third produces no
//! divided state and no wrong answer, only a smaller diff.
//!
//! What `saveHealthWorkout` costs is a third asynchronous stage:
//! `HKWorkout` construction, then `save:withCompletion:`, then an
//! `HKWorkoutRouteBuilder` chain for the optional `locations` array — each with
//! its own completion, each able to fail after the previous succeeded. That is
//! a round of its own, not a tail on this one.
//!
//! ## The store is created here, not inherited
//!
//! Swift builds its `HKHealthStore` in `Coordinator.init` behind
//! `config.enableHealthKit && HKHealthStore.isHealthDataAvailable()`. This
//! module builds its own, lazily, behind the same availability check — the
//! config half is already applied by `ios_dispatch` before any handler runs.
//! A second store is not a second authorization: both read the same system
//! state, which is what makes the split above safe.
//!
//! ## Neither action can be exercised without a person
//!
//! `requestAuthorization(toShare:read:)` presents a system sheet, and no
//! `simctl privacy` service covers HealthKit — unlike the microphone, which is
//! why `bridge_mobile_audiorec.zig` could be proved end to end and this cannot.
//! The fixture therefore asserts what a simulator *can* establish: that both
//! actions are served by Zig and refuse honestly on a device with no health
//! data, rather than hanging as the spec's gated arms do.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;
const Id = ?*anyopaque;
const is_darwin = builtin.target.os.tag.isDarwin();

pub const A = struct {
    pub const request_health_authorization = "requestHealthAuthorization";
    pub const get_health_data = "getHealthData";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.request_health_authorization, .reply = .result },
    .{ .name = A.get_health_data, .reply = .result },
};

/// The action this module was scoped to and, on purpose, does not serve.
///
/// Recorded as data rather than prose so a test can hold both properties the
/// decision rests on: it is not declared, and it still falls out of
/// `handleMessage` as `UnknownAction` — the one return `ios_dispatch.route`
/// turns into a Swift-shim hand-off.
pub const deliberately_unserved = [_][]const u8{
    "saveHealthWorkout",
};

/// `requestHealthAuthorization`'s reply on success: the bare JSON `true`.
const authorized_reply = "true";

/// The four data types Swift's `getHealthData` switch recognises, with the
/// HealthKit identifier and unit each maps to.
///
/// The identifiers are `HKQuantityTypeIdentifier` constants — plain
/// `NSString`s whose values happen to equal their own names, which is *not*
/// guaranteed and is why they are read through `dlsym` rather than spelled.
/// The unit strings are the ones `HKUnit unitFromString:` parses, and they are
/// also what comes back in the reply's `unit` field, so a change here is a
/// change to the wire.
const HealthType = struct {
    /// The name the page sends.
    name: []const u8,
    /// The `HKQuantityTypeIdentifier*` symbol to resolve.
    identifier_symbol: [*:0]const u8,
    /// What `HKUnit unitFromString:` is given, and what the reply reports.
    unit: [*:0]const u8,
};

const health_types = [_]HealthType{
    .{ .name = "steps", .identifier_symbol = "HKQuantityTypeIdentifierStepCount", .unit = "count" },
    .{ .name = "heartRate", .identifier_symbol = "HKQuantityTypeIdentifierHeartRate", .unit = "count/min" },
    .{ .name = "activeEnergy", .identifier_symbol = "HKQuantityTypeIdentifierActiveEnergyBurned", .unit = "kcal" },
    .{ .name = "distance", .identifier_symbol = "HKQuantityTypeIdentifierDistanceWalkingRunning", .unit = "m" },
};

fn healthTypeFor(name: []const u8) ?HealthType {
    for (health_types) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// `HKStatisticsOptionCumulativeSum`, read from
/// `HealthKit.framework/Headers/HKStatistics.h:42`.
///
/// This was `1 << 2` on the first attempt, which is
/// `HKStatisticsOptionDiscreteMin` — an option HealthKit rejects for a
/// cumulative type like step count, by *raising* inside
/// `+[HKStatistics _validateOptions:forDataType:]`. The fixture caught it as a
/// process abort, which was luck: had the wrong bit been a legal one for the
/// type, the query would have computed a minimum and reported it as a sum.
const statistics_option_cumulative_sum: c_ulong = 1 << 4;

/// `HKQueryOptionStrictStartDate`, from `HKQuery.h:50`.
const query_option_strict_start_date: c_ulong = 1 << 0;

/// Swift's default window when the page sends no dates: the last seven days.
const default_window_seconds: f64 = 7 * 24 * 60 * 60;

pub const HealthBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, A.request_health_authorization)) {
            try self.requestAuthorization(data);
        } else if (std.mem.eql(u8, action, A.get_health_data)) {
            try self.getHealthData(data);
        } else {
            // `saveHealthWorkout` lands here on purpose. See the module
            // comment and `deliberately_unserved`.
            return BridgeError.UnknownAction;
        }
    }

    /// Ask for read and share permission on the types the page named.
    fn requestAuthorization(self: *Self, data: []const u8) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        const store = try healthStore();

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return BridgeError.InvalidJSON,
        };
        defer parsed.deinit();

        const requested = try readTypeNames(parsed.value);

        const share = try shareTypeSet(self.allocator, requested);
        const read = try readTypeSet(self.allocator, requested);

        const ticket = ios_async.acquire(A.request_health_authorization) orelse {
            std.log.warn(
                "requestHealthAuthorization: no free reply slot; {d} native calls are already awaiting one",
                .{ios_async.max_in_flight},
            );
            return BridgeError.NativeCallFailed;
        };
        errdefer ios_async.abandon(ticket);
        publishCall(ticket, null);

        const sel = objc.sel_registerName("requestAuthorizationToShareTypes:readTypes:completion:") orelse
            return BridgeError.NativeCallFailed;
        const RequestFn = *const fn (Id, objc.SEL, Id, Id, *anyopaque) callconv(.c) void;
        const request: RequestFn = @ptrCast(&objc.objc_msgSend);
        request(store, sel, share, read, @ptrCast(&auth_blocks[ticket.index]));
    }

    /// Sum one quantity type over a window and answer `{value, unit}`.
    fn getHealthData(self: *Self, data: []const u8) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        const store = try healthStore();

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return BridgeError.InvalidJSON,
        };
        defer parsed.deinit();

        const request = try readDataRequest(parsed.value);

        const quantity_type = try quantityType(request.type.identifier_symbol);
        const unit = try unitFromString(request.type.unit);
        const predicate = try samplePredicate(request.start, request.end);

        const ticket = ios_async.acquire(A.get_health_data) orelse {
            std.log.warn(
                "getHealthData: no free reply slot; {d} native calls are already awaiting one",
                .{ios_async.max_in_flight},
            );
            return BridgeError.NativeCallFailed;
        };
        errdefer ios_async.abandon(ticket);
        publishCall(ticket, unit);

        const HKStatisticsQuery = objc.objc_getClass("HKStatisticsQuery") orelse
            return BridgeError.PlatformNotSupported;
        const sel_alloc = objc.sel_registerName("alloc") orelse return BridgeError.NativeCallFailed;
        const sel_init = objc.sel_registerName(
            "initWithQuantityType:quantitySamplePredicate:options:completionHandler:",
        ) orelse return BridgeError.NativeCallFailed;
        const allocated = objc.msgSendId(HKStatisticsQuery, sel_alloc) orelse
            return BridgeError.NativeCallFailed;

        const InitFn = *const fn (Id, objc.SEL, Id, Id, c_ulong, *anyopaque) callconv(.c) Id;
        const initFn: InitFn = @ptrCast(&objc.objc_msgSend);
        const query = initFn(
            allocated,
            sel_init,
            quantity_type,
            predicate,
            statistics_option_cumulative_sum,
            @ptrCast(&stats_blocks[ticket.index]),
        ) orelse return BridgeError.NativeCallFailed;

        const sel_execute = objc.sel_registerName("executeQuery:") orelse
            return BridgeError.NativeCallFailed;
        objc.msgSendVoid1(store, sel_execute, query);
    }
};

/// The lazily-created `HKHealthStore`, or the reason there is none.
///
/// `+[HKHealthStore isHealthDataAvailable]` is Swift's own guard, and it is
/// false on iPad and on any simulator that is not an iPhone. Creating the
/// store anyway would give every later call a store that answers nothing.
var store_instance: Id = null;

fn healthStore() !Id {
    if (store_instance) |existing| return existing;

    const HKHealthStore = objc.objc_getClass("HKHealthStore") orelse {
        std.log.warn(
            "health: HKHealthStore is not in this process; the app does not link HealthKit",
            .{},
        );
        return BridgeError.PlatformNotSupported;
    };

    const sel_available = objc.sel_registerName("isHealthDataAvailable") orelse
        return BridgeError.NativeCallFailed;
    if (!objc.msgSendBool(HKHealthStore, sel_available)) {
        std.log.warn("health refused: this device has no health data store", .{});
        return BridgeError.PlatformNotSupported;
    }

    // +1 and kept for the life of the process, matching the single store Swift
    // builds once in `Coordinator.init`.
    store_instance = objc.allocInit(HKHealthStore) catch return BridgeError.NativeCallFailed;
    return store_instance;
}

/// The `types` array, defaulting to empty.
///
/// Swift's `body["types"] as? [String] ?? []` accepts a missing array and a
/// mistyped one alike. A non-array is refused here rather than silently read
/// as "no types", because the two produce different authorization sheets and
/// the page cannot tell which it got.
fn readTypeNames(payload: std.json.Value) !?std.json.Array {
    const object = switch (payload) {
        .object => |o| o,
        else => return BridgeError.InvalidJSON,
    };
    const field = object.get("types") orelse return null;
    return switch (field) {
        .array => |a| a,
        .null => null,
        else => BridgeError.InvalidParameter,
    };
}

/// Whether the page named `name` among the types it wants.
///
/// Null is an absent or explicitly null `types`, which matches nothing — the
/// empty-set case Swift's `?? []` produces. Spelled as an optional rather than
/// an empty `std.json.Array`, because an `Array` this file did not build has
/// no allocator behind it and nothing here should be inspecting the fields of
/// one it invented.
fn hasType(requested: ?std.json.Array, name: []const u8) bool {
    const items = requested orelse return false;
    for (items.items) |item| {
        switch (item) {
            .string => |s| if (std.mem.eql(u8, s, name)) return true,
            else => {},
        }
    }
    return false;
}

/// `NSSet` of the types the app may write.
///
/// Always contains the workout type and, when HealthKit offers it, the workout
/// route series — Swift seeds both unconditionally, before looking at what the
/// page asked for.
fn shareTypeSet(allocator: std.mem.Allocator, requested: ?std.json.Array) !Id {
    var members: std.ArrayListUnmanaged(Id) = .empty;
    defer members.deinit(allocator);

    if (try workoutType()) |workout| try members.append(allocator, workout);
    if (try workoutRouteType()) |route| try members.append(allocator, route);

    // Swift adds these two to *both* sets when named.
    if (hasType(requested, "activeEnergy")) {
        if (quantityType("HKQuantityTypeIdentifierActiveEnergyBurned")) |t| {
            try members.append(allocator, t);
        } else |_| {}
    }
    if (hasType(requested, "distance")) {
        if (quantityType("HKQuantityTypeIdentifierDistanceWalkingRunning")) |t| {
            try members.append(allocator, t);
        } else |_| {}
    }

    return setWith(members.items);
}

/// `NSSet` of the types the app may read.
fn readTypeSet(allocator: std.mem.Allocator, requested: ?std.json.Array) !Id {
    var members: std.ArrayListUnmanaged(Id) = .empty;
    defer members.deinit(allocator);

    inline for (health_types) |entry| {
        if (hasType(requested, entry.name)) {
            if (quantityType(entry.identifier_symbol)) |t| {
                try members.append(allocator, t);
            } else |_| {}
        }
    }
    if (hasType(requested, "workouts")) {
        if (try workoutType()) |workout| try members.append(allocator, workout);
    }

    return setWith(members.items);
}

fn setWith(members: []const Id) !Id {
    const NSSet = objc.objc_getClass("NSSet") orelse return BridgeError.NativeCallFailed;
    if (members.len == 0) {
        const sel = objc.sel_registerName("set") orelse return BridgeError.NativeCallFailed;
        return objc.msgSendId(NSSet, sel) orelse BridgeError.NativeCallFailed;
    }
    const sel = objc.sel_registerName("setWithObjects:count:") orelse
        return BridgeError.NativeCallFailed;
    const SetFn = *const fn (objc.Class, objc.SEL, [*]const Id, c_ulong) callconv(.c) Id;
    const setWithObjects: SetFn = @ptrCast(&objc.objc_msgSend);
    return setWithObjects(NSSet, sel, members.ptr, members.len) orelse BridgeError.NativeCallFailed;
}

fn workoutType() !?Id {
    const HKObjectType = objc.objc_getClass("HKObjectType") orelse return null;
    const sel = objc.sel_registerName("workoutType") orelse return null;
    return objc.msgSendId(HKObjectType, sel);
}

fn workoutRouteType() !?Id {
    const HKSeriesType = objc.objc_getClass("HKSeriesType") orelse return null;
    const sel = objc.sel_registerName("workoutRouteType") orelse return null;
    return objc.msgSendId(HKSeriesType, sel);
}

/// `+[HKQuantityType quantityTypeForIdentifier:]` for a `dlsym`'d identifier.
fn quantityType(identifier_symbol: [*:0]const u8) !Id {
    const identifier = try healthConstant(identifier_symbol);

    const HKQuantityType = objc.objc_getClass("HKQuantityType") orelse
        return BridgeError.PlatformNotSupported;
    const sel = objc.sel_registerName("quantityTypeForIdentifier:") orelse
        return BridgeError.NativeCallFailed;
    return objc.msgSendId1(HKQuantityType, sel, identifier) orelse {
        std.log.warn("health: HealthKit does not know {s}", .{std.mem.span(identifier_symbol)});
        return BridgeError.InvalidParameter;
    };
}

/// An `extern NSString * const` from HealthKit, read through its symbol.
///
/// Every `HKQuantityTypeIdentifier` happens to equal its own name today. That
/// is not documented and not API, and a hand-spelled identifier that stops
/// matching would make `quantityTypeForIdentifier:` answer nil — a refusal
/// blamed on the page's `type` rather than on this file.
fn healthConstant(symbol: [*:0]const u8) !Id {
    const found = dlsym(RTLD_DEFAULT, symbol) orelse {
        std.log.warn("health: {s} is not in this process", .{std.mem.span(symbol)});
        return BridgeError.PlatformNotSupported;
    };
    const cell: *const Id = @ptrCast(@alignCast(found));
    return cell.* orelse BridgeError.PlatformNotSupported;
}

fn unitFromString(unit: [*:0]const u8) !Id {
    const HKUnit = objc.objc_getClass("HKUnit") orelse return BridgeError.PlatformNotSupported;
    const sel = objc.sel_registerName("unitFromString:") orelse return BridgeError.NativeCallFailed;

    const NSString = objc.objc_getClass("NSString") orelse return BridgeError.NativeCallFailed;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse
        return BridgeError.NativeCallFailed;
    const ns_unit = objc.msgSendId1(NSString, sel_string, unit) orelse
        return BridgeError.NativeCallFailed;

    return objc.msgSendId1(HKUnit, sel, ns_unit) orelse BridgeError.NativeCallFailed;
}

/// `+[HKQuery predicateForSamplesWithStartDate:endDate:options:]`.
fn samplePredicate(start: f64, end: f64) !Id {
    const HKQuery = objc.objc_getClass("HKQuery") orelse return BridgeError.PlatformNotSupported;
    const sel = objc.sel_registerName("predicateForSamplesWithStartDate:endDate:options:") orelse
        return BridgeError.NativeCallFailed;

    const start_date = try dateFromInterval(start);
    const end_date = try dateFromInterval(end);

    const PredicateFn = *const fn (objc.Class, objc.SEL, Id, Id, c_ulong) callconv(.c) Id;
    const predicateFn: PredicateFn = @ptrCast(&objc.objc_msgSend);
    return predicateFn(
        HKQuery,
        sel,
        start_date,
        end_date,
        query_option_strict_start_date,
    ) orelse BridgeError.NativeCallFailed;
}

fn dateFromInterval(interval: f64) !Id {
    const NSDate = objc.objc_getClass("NSDate") orelse return BridgeError.NativeCallFailed;
    const sel = objc.sel_registerName("dateWithTimeIntervalSince1970:") orelse
        return BridgeError.NativeCallFailed;
    const DateFn = *const fn (objc.Class, objc.SEL, f64) callconv(.c) Id;
    const dateFn: DateFn = @ptrCast(&objc.objc_msgSend);
    return dateFn(NSDate, sel, interval) orelse BridgeError.NativeCallFailed;
}

fn nowInterval() f64 {
    const NSDate = objc.objc_getClass("NSDate") orelse return 0;
    const sel_date = objc.sel_registerName("date") orelse return 0;
    const now = objc.msgSendId(NSDate, sel_date) orelse return 0;
    const sel_interval = objc.sel_registerName("timeIntervalSince1970") orelse return 0;
    const IntervalFn = *const fn (Id, objc.SEL) callconv(.c) f64;
    const intervalFn: IntervalFn = @ptrCast(&objc.objc_msgSend);
    return intervalFn(now, sel_interval);
}

const DataRequest = struct {
    type: HealthType,
    /// Seconds since 1970, already converted from the page's milliseconds.
    start: f64,
    end: f64,
};

/// `type` is required; the dates are optional and in **milliseconds**.
///
/// Swift divides both by 1000, so the page's contract is milliseconds and the
/// conversion is part of the wire format rather than an implementation detail.
/// An absent window is the last seven days, which is Swift's
/// `Calendar.current.date(byAdding: .day, value: -7, to: Date())` — computed
/// here as a flat 604800 seconds, which differs from a calendar subtraction
/// only across a daylight-saving boundary, and only by an hour.
fn readDataRequest(payload: std.json.Value) !DataRequest {
    const object = switch (payload) {
        .object => |o| o,
        else => return BridgeError.InvalidJSON,
    };

    const type_value = object.get("type") orelse return BridgeError.MissingData;
    const type_name = switch (type_value) {
        .string => |s| s,
        else => return BridgeError.InvalidParameter,
    };
    const health_type = healthTypeFor(type_name) orelse {
        // Swift's `default: rejectCallback("Unknown health data type")`.
        std.log.warn("getHealthData refused: unknown type '{s}'", .{type_name});
        return BridgeError.InvalidParameter;
    };

    const now = nowInterval();
    const start = try optionalMilliseconds(object, "startDate") orelse (now - default_window_seconds);
    const end = try optionalMilliseconds(object, "endDate") orelse now;

    return .{ .type = health_type, .start = start, .end = end };
}

/// A millisecond timestamp as seconds, or null when the field is absent.
fn optionalMilliseconds(object: std.json.ObjectMap, key: []const u8) !?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .float => |f| f / 1000.0,
        .integer => |i| @as(f64, @floatFromInt(i)) / 1000.0,
        .null => null,
        // Swift's `as? Double` turns a string into nil and silently uses the
        // default window. Refused here: a page that sent a date meant to
        // constrain the query, and answering over a different window is a
        // wrong number rather than a missing one.
        else => BridgeError.InvalidParameter,
    };
}

// ---------------------------------------------------------------------------
// The two completions
// ---------------------------------------------------------------------------

/// What a slot's block needs that the block itself cannot carry.
const PendingCall = struct {
    ticket: ios_async.Ticket,
    /// The `HKUnit` the statistics reply reports in, or null for the
    /// authorization call which reports none.
    unit: Id,
};

var pending_calls: [ios_async.max_in_flight]?PendingCall = @splat(null);
var pending_mutex: compat_mutex.Mutex = .{};

fn publishCall(ticket: ios_async.Ticket, unit: Id) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls[ticket.index] = .{ .ticket = ticket, .unit = unit };
}

/// Read and clear, so a second fire is a no-op rather than a second reply.
fn takeCall(index: u5) ?PendingCall {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const call = pending_calls[index];
    pending_calls[index] = null;
    return call;
}

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// `void (^)(BOOL, NSError *)` for authorization, and
/// `void (^)(HKStatisticsQuery *, HKStatistics *, NSError *)` for the query.
/// Same layout, different invokes.
const HealthBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// 1 << 28 — a global block is never copied.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

const health_block_descriptor = BlockDescriptor{ .size = @sizeOf(HealthBlock) };

extern var _NSConcreteGlobalBlock: anyopaque;

fn makeAuthInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const HealthBlock, success: bool, err: Id) callconv(.c) void {
            authorizationAnswered(index, success, err);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeStatsInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const HealthBlock, _: Id, result: Id, err: Id) callconv(.c) void {
            statisticsAnswered(index, result, err);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeBlocks(comptime maker: fn (comptime u5) *const anyopaque) [ios_async.max_in_flight]HealthBlock {
    var out: [ios_async.max_in_flight]HealthBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = maker(@intCast(i)),
            .descriptor = &health_block_descriptor,
        };
    }
    return out;
}

var auth_blocks: [ios_async.max_in_flight]HealthBlock =
    if (is_darwin) makeBlocks(makeAuthInvoke) else undefined;
var stats_blocks: [ios_async.max_in_flight]HealthBlock =
    if (is_darwin) makeBlocks(makeStatsInvoke) else undefined;

fn authorizationAnswered(index: u5, success: bool, err: Id) void {
    if (!is_darwin) return;

    const call = takeCall(index) orelse {
        std.log.warn(
            "requestHealthAuthorization answered for slot {d} with no call recorded; ignored",
            .{index},
        );
        return;
    };

    if (success) {
        ios_async.deliverJson(call.ticket, authorized_reply);
        return;
    }
    logNSError(A.request_health_authorization, err);
    ios_async.deliverErrorCode(call.ticket, BridgeError.PermissionDenied);
}

fn statisticsAnswered(index: u5, result: Id, err: Id) void {
    if (!is_darwin) return;

    const call = takeCall(index) orelse {
        std.log.warn("getHealthData answered for slot {d} with no call recorded; ignored", .{index});
        return;
    };

    if (err != null) {
        logNSError(A.get_health_data, err);
        ios_async.deliverErrorCode(call.ticket, BridgeError.NativeCallFailed);
        return;
    }

    const allocator = std.heap.c_allocator;
    const json = shapeStatistics(allocator, result, call.unit) catch |shape_err| {
        std.log.warn("getHealthData: could not shape the reply: {}", .{shape_err});
        ios_async.deliverError(call.ticket);
        return;
    };
    defer allocator.free(json);

    ios_async.deliverJson(call.ticket, json);
}

/// `{"value":…,"unit":…}`.
///
/// Swift's `result?.sumQuantity()?.doubleValue(for: qUnit) ?? 0` — a window
/// with no samples is zero, not an error, and that is carried across. The unit
/// string comes from `HKUnit.unitString`, so the reply reports the unit
/// HealthKit actually used rather than the one this file asked for.
fn shapeStatistics(allocator: std.mem.Allocator, result: Id, unit: Id) ![]u8 {
    var value: f64 = 0;

    if (result) |statistics| {
        const sel_sum = objc.sel_registerName("sumQuantity") orelse return error.SelectorNotFound;
        if (objc.msgSendId(statistics, sel_sum)) |quantity| {
            const sel_double = objc.sel_registerName("doubleValueForUnit:") orelse
                return error.SelectorNotFound;
            const DoubleFn = *const fn (Id, objc.SEL, Id) callconv(.c) f64;
            const doubleFor: DoubleFn = @ptrCast(&objc.objc_msgSend);
            value = doubleFor(quantity, sel_double, unit);
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"value\":");
    if (std.math.isNan(value) or std.math.isInf(value)) {
        // Not JSON, and a bare `nan` in the source `evaluateJavaScript:` parses
        // loses the whole reply rather than one field.
        try out.append(allocator, '0');
    } else {
        var buf: [64]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}", .{value}));
    }
    try out.appendSlice(allocator, ",\"unit\":");
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, unitString(unit) orelse "");
    try out.append(allocator, '"');
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

fn unitString(unit: Id) ?[]const u8 {
    const sel = objc.sel_registerName("unitString") orelse return null;
    const ns = objc.msgSendId(unit, sel) orelse return null;
    const utf8 = objc.getNSStringUTF8(ns) orelse return null;
    return std.mem.span(utf8);
}

fn logNSError(action: []const u8, err: Id) void {
    const ns_error = err orelse return;
    const sel = objc.sel_registerName("localizedDescription") orelse return;
    const ns_description = objc.msgSendId(ns_error, sel) orelse return;
    const utf8 = objc.getNSStringUTF8(ns_description) orelse return;
    std.log.warn("{s}: {s}", .{ action, std.mem.span(utf8) });
}

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// `RTLD_DEFAULT` — search every image already loaded into the process.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

const testing = std.testing;

test "the action names match the Swift case labels exactly" {
    try testing.expectEqualStrings("requestHealthAuthorization", A.request_health_authorization);
    try testing.expectEqualStrings("getHealthData", A.get_health_data);
}

test "saveHealthWorkout stays with the shim, and is neither declared nor routed" {
    // The split is safe only because nothing flows between the three actions —
    // the HKHealthStore is a stateless handle and authorization lives in the
    // system database. `UnknownAction` is the one return `ios_dispatch.route`
    // turns into a hand-off; anything else would steal the action from the arm
    // that answers it today.
    var bridge = HealthBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectEqual(@as(usize, 1), deliberately_unserved.len);
    for (deliberately_unserved) |name| {
        try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage(name, "{}"));
        for (capability_actions) |decl| {
            try testing.expect(!std.mem.eql(u8, decl.name, name));
        }
    }
}

test "the four data types are the ones the Swift switch recognises" {
    // The names are the page's vocabulary and the units are the reply's, so
    // both halves are wire contract. A fifth entry here would answer an action
    // Swift rejects as "Unknown health data type".
    try testing.expectEqual(@as(usize, 4), health_types.len);
    try testing.expectEqualStrings("count", std.mem.span(healthTypeFor("steps").?.unit));
    try testing.expectEqualStrings("count/min", std.mem.span(healthTypeFor("heartRate").?.unit));
    try testing.expectEqualStrings("kcal", std.mem.span(healthTypeFor("activeEnergy").?.unit));
    try testing.expectEqualStrings("m", std.mem.span(healthTypeFor("distance").?.unit));
    try testing.expect(healthTypeFor("sleep") == null);
    try testing.expect(healthTypeFor("") == null);
}

test "the HealthKit option bits are the SDK's values, not a guess" {
    // The first version of this test asserted `4` — and passed, because it
    // pinned the same guess the code made. `4` is
    // HKStatisticsOptionDiscreteMin; CumulativeSum is `1 << 4`. A constant
    // test is only worth having when the value came from somewhere other than
    // the code it is checking, so these two cite their headers:
    // HKStatistics.h:42 and HKQuery.h:50.
    try testing.expectEqual(@as(c_ulong, 16), statistics_option_cumulative_sum);
    try testing.expectEqual(@as(c_ulong, 1), query_option_strict_start_date);

    // And it is not any of the neighbouring options, which are the values a
    // slip would land on.
    const discrete_average: c_ulong = 1 << 1;
    const discrete_min: c_ulong = 1 << 2;
    const discrete_max: c_ulong = 1 << 3;
    try testing.expect(statistics_option_cumulative_sum != discrete_average);
    try testing.expect(statistics_option_cumulative_sum != discrete_min);
    try testing.expect(statistics_option_cumulative_sum != discrete_max);
}

test "an unknown or missing type is refused rather than defaulted" {
    if (!is_darwin) return error.SkipZigTest;

    try expectDataRequestRefused("{}", BridgeError.MissingData);
    try expectDataRequestRefused("{\"type\":7}", BridgeError.InvalidParameter);
    try expectDataRequestRefused("{\"type\":\"sleep\"}", BridgeError.InvalidParameter);
    try expectDataRequestRefused("[]", BridgeError.InvalidJSON);
}

fn expectDataRequestRefused(comptime json: []const u8, expected: anyerror) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, readDataRequest(parsed.value));
}

test "the page's dates are milliseconds, and a mistyped one is refused" {
    // Swift divides both by 1000, so milliseconds are the contract rather than
    // an implementation detail. `as? Double` turns a string into nil and
    // silently queries the default window instead — a wrong number rather than
    // a missing one, which is why this refuses.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"startDate\":1600000000000,\"endDate\":1600000060000.0,\"bad\":\"x\"}",
        .{},
    );
    defer parsed.deinit();
    const object = parsed.value.object;

    try testing.expectEqual(@as(f64, 1600000000), (try optionalMilliseconds(object, "startDate")).?);
    try testing.expectEqual(@as(f64, 1600000060), (try optionalMilliseconds(object, "endDate")).?);
    try testing.expect((try optionalMilliseconds(object, "absent")) == null);
    try testing.expectError(BridgeError.InvalidParameter, optionalMilliseconds(object, "bad"));
}

test "the default window is Swift's seven days" {
    try testing.expectEqual(@as(f64, 604800), default_window_seconds);
}

test "an absent types list matches nothing, and is not read as an array" {
    // The empty-set case Swift's `?? []` produces. Spelled as an optional
    // rather than an invented `std.json.Array`, because a value this file did
    // not build has no allocator behind it and nothing should be inspecting
    // its fields.
    try testing.expect(!hasType(null, "steps"));

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"types\":[\"steps\",\"workouts\",3]}",
        .{},
    );
    defer parsed.deinit();
    const names = (try readTypeNames(parsed.value)).?;
    try testing.expect(hasType(names, "steps"));
    try testing.expect(hasType(names, "workouts"));
    // A non-string element is skipped rather than refused, matching `as?
    // [String]`'s element-wise behaviour.
    try testing.expect(!hasType(names, "heartRate"));

    const absent = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer absent.deinit();
    try testing.expect((try readTypeNames(absent.value)) == null);

    const wrong = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"types\":\"steps\"}", .{});
    defer wrong.deinit();
    try testing.expectError(BridgeError.InvalidParameter, readTypeNames(wrong.value));
}

test "every declared action dispatches to something" {
    var bridge = HealthBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            continue;
        };
    }
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("getDeviceInfo", "{}"));
}

test "both block families are global, distinct per slot, and distinct from each other" {
    if (!is_darwin) return error.SkipZigTest;

    for (&auth_blocks, &stats_blocks) |*auth, *stats| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, auth.isa);
        try testing.expectEqual(&_NSConcreteGlobalBlock, stats.isa);
        try testing.expectEqual(BLOCK_IS_GLOBAL, auth.flags);
        try testing.expectEqual(BLOCK_IS_GLOBAL, stats.flags);
        // The two families take different argument counts — (BOOL, NSError*)
        // and (query, statistics, NSError*) — so sharing an invoke would read
        // the error object out of the wrong register.
        try testing.expect(auth.invoke != stats.invoke);
    }
    try testing.expect(auth_blocks[0].invoke != auth_blocks[1].invoke);
    try testing.expect(stats_blocks[0].invoke != stats_blocks[1].invoke);
}

test "a completion for a slot with no recorded call is ignored" {
    if (!is_darwin) return error.SkipZigTest;

    pending_mutex.lock();
    for (&pending_calls) |*entry| entry.* = null;
    pending_mutex.unlock();

    authorizationAnswered(0, true, null);
    statisticsAnswered(0, null, null);
}

test "a window with no samples is zero, not an error" {
    // Swift's `?? 0`. A page asking for yesterday's steps on a device that
    // recorded none gets 0, and telling it the query failed would be a
    // different answer.
    if (!is_darwin) return error.SkipZigTest;

    const json = try shapeStatistics(testing.allocator, null, null);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"value\":0,\"unit\":\"\"}", json);
}
