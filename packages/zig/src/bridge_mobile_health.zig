//! All three of the `mobile` namespace's HealthKit actions:
//! `requestHealthAuthorization`, `getHealthData` and `saveHealthWorkout`.
//!
//! ## What the split cost, and why it is closed
//!
//! `saveHealthWorkout` was deferred one round, and the reason was cost rather
//! than correctness
//!
//! — unlike `openPDF`/`closePDF` and the audio pair, which shared *module
//! state* and had to move whole. The only thing these three share is an
//! `HKHealthStore`, a stateless handle whose authorization lives in the system
//! database, so a split was never at risk of dividing state.
//!
//! The cost was a third asynchronous stage: `save:withCompletion:`, then
//! `insertRouteData:completion:`, then
//! `finishRouteWithWorkout:metadata:completion:` — each able to fail after the
//! previous succeeded, and none able to carry what the next needs, since all
//! three blocks are global and capture nothing. `WorkoutChain` is what rides
//! the slot between them.
//!
//! Two places diverge from Swift, both in the same direction. Swift *rejects*
//! when a route fails to build, insert or finish — after the workout has
//! already been written to HealthKit. That tells a page nothing was saved when
//! something was, and leaves it unable to reference a workout that exists. Here
//! a route failure still resolves the workout's id, with the reason logged.
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
    pub const save_health_workout = "saveHealthWorkout";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.request_health_authorization, .reply = .result },
    .{ .name = A.get_health_data, .reply = .result },
    .{ .name = A.save_health_workout, .reply = .result },
};

/// Nothing in this family is unserved any more.
///
/// `saveHealthWorkout` was the last entry, deferred one round for its third
/// asynchronous stage. The empty list is kept rather than deleted so the test
/// that walks it keeps compiling and the next deferral has somewhere to go.
pub const deliberately_unserved = [_][]const u8{};

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
        } else if (std.mem.eql(u8, action, A.save_health_workout)) {
            try self.saveWorkout(data);
        } else {
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

    /// Save a workout, then optionally attach a GPS route to it.
    ///
    /// Three asynchronous stages, each able to fail after the previous
    /// succeeded: `save:withCompletion:`, then — only when the page sent
    /// locations — `insertRouteData:completion:` and
    /// `finishRouteWithWorkout:metadata:completion:`. Everything the later
    /// stages need is parked on the slot at dispatch, because none of the
    /// three blocks can carry it.
    ///
    /// A workout with no usable locations resolves after stage one, matching
    /// Swift's early `guard !locations.isEmpty`. That is not an error: the
    /// workout really was saved, and a route is optional.
    fn saveWorkout(self: *Self, data: []const u8) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        const store = try healthStore();

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return BridgeError.InvalidJSON,
        };
        defer parsed.deinit();

        const request = try readWorkoutRequest(parsed.value);

        const workout = try buildWorkout(self.allocator, request);
        errdefer releaseObject(workout);

        const locations = try buildLocations(self.allocator, parsed.value, request);

        const activity_id = std.heap.c_allocator.dupe(u8, request.activity_id) catch
            return BridgeError.AllocationFailed;
        errdefer std.heap.c_allocator.free(activity_id);

        const ticket = ios_async.acquire(A.save_health_workout) orelse {
            std.log.warn(
                "saveHealthWorkout: no free reply slot; {d} native calls are already awaiting one",
                .{ios_async.max_in_flight},
            );
            return BridgeError.NativeCallFailed;
        };
        errdefer ios_async.abandon(ticket);

        publishWorkoutCall(ticket, .{
            .workout = workout,
            .activity_id = activity_id,
            .locations = locations,
            .store = store,
        });

        const sel = objc.sel_registerName("saveObject:withCompletion:") orelse
            return BridgeError.NativeCallFailed;
        const SaveFn = *const fn (Id, objc.SEL, Id, *anyopaque) callconv(.c) void;
        const save: SaveFn = @ptrCast(&objc.objc_msgSend);
        save(store, sel, workout, @ptrCast(&save_blocks[ticket.index]));
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

// ===========================================================================
// saveHealthWorkout
// ===========================================================================

/// `HKWorkoutActivityType`, read from `HKWorkout.h`'s enum rather than
/// guessed.
///
/// The enum numbers most members implicitly, so the values are only obtainable
/// by counting from the last explicit one. Every value here was wrong on
/// instinct — running reads as 37 if you assume it is near walking — and a
/// wrong number saves a real workout under the wrong activity, which HealthKit
/// accepts without complaint. Same lesson as
/// `statistics_option_cumulative_sum` above, applied before the mistake
/// instead of after it.
const WorkoutActivity = struct {
    name: []const u8,
    value: c_ulong,
};

const workout_activities = [_]WorkoutActivity{
    .{ .name = "running", .value = 34 },
    .{ .name = "walking", .value = 49 },
    .{ .name = "hiking", .value = 22 },
    .{ .name = "cycling", .value = 13 },
};

fn workoutActivityFor(name: []const u8) ?c_ulong {
    for (workout_activities) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

/// `CLLocationCoordinate2D` — two doubles, passed by value.
const CLLocationCoordinate2D = extern struct {
    latitude: f64,
    longitude: f64,
};

/// Swift's defaults for the two optional per-location fields.
const default_altitude: f64 = 0;
const default_horizontal_accuracy: f64 = 10;
/// Swift passes -1, which is CoreLocation's "unknown".
const unknown_vertical_accuracy: f64 = -1;

const WorkoutRequest = struct {
    activity_id: []const u8,
    activity: c_ulong,
    /// Seconds since 1970.
    start: f64,
    end: f64,
    distance_meters: ?f64,
    energy_calories: ?f64,
};

/// Swift's four-clause guard, plus `endValue > startValue`.
///
/// Every clause rejects with one message there, so the codes here are the
/// distinction the page could not previously make: a missing field is
/// `MissingData`, a mistyped or out-of-order one is `InvalidParameter`.
fn readWorkoutRequest(payload: std.json.Value) !WorkoutRequest {
    const object = switch (payload) {
        .object => |o| o,
        else => return BridgeError.InvalidJSON,
    };

    const activity_id = try requiredString(object, "activityId");
    const type_name = try requiredString(object, "type");
    const activity = workoutActivityFor(type_name) orelse {
        std.log.warn("saveHealthWorkout refused: unsupported workout type '{s}'", .{type_name});
        return BridgeError.InvalidParameter;
    };

    const start = (try optionalMilliseconds(object, "startDate")) orelse return BridgeError.MissingData;
    const end = (try optionalMilliseconds(object, "endDate")) orelse return BridgeError.MissingData;
    if (!(end > start)) {
        std.log.warn("saveHealthWorkout refused: endDate is not after startDate", .{});
        return BridgeError.InvalidParameter;
    }

    return .{
        .activity_id = activity_id,
        .activity = activity,
        .start = start,
        .end = end,
        // Swift's `.flatMap { $0 > 0 ? … : nil }`: a non-positive value is
        // dropped rather than saved as zero, because a workout with an
        // explicit zero distance reads as "measured none" where nil reads as
        // "did not measure".
        .distance_meters = try positiveNumber(object, "distanceMeters"),
        .energy_calories = try positiveNumber(object, "activeEnergyCalories"),
    };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return BridgeError.MissingData;
    const text = switch (value) {
        .string => |t| t,
        else => return BridgeError.InvalidParameter,
    };
    if (text.len == 0) return BridgeError.InvalidParameter;
    return text;
}

fn positiveNumber(object: std.json.ObjectMap, key: []const u8) !?f64 {
    const value = object.get(key) orelse return null;
    const number: f64 = switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .null => return null,
        else => return BridgeError.InvalidParameter,
    };
    return if (number > 0) number else null;
}

/// `+[HKWorkout workoutWithActivityType:startDate:endDate:workoutEvents:totalEnergyBurned:totalDistance:metadata:]`,
/// retained.
fn buildWorkout(allocator: std.mem.Allocator, request: WorkoutRequest) !Id {
    const HKWorkout = objc.objc_getClass("HKWorkout") orelse return BridgeError.PlatformNotSupported;
    const sel = objc.sel_registerName(
        "workoutWithActivityType:startDate:endDate:workoutEvents:totalEnergyBurned:totalDistance:metadata:",
    ) orelse return BridgeError.NativeCallFailed;

    const start_date = try dateFromInterval(request.start);
    const end_date = try dateFromInterval(request.end);

    const energy = if (request.energy_calories) |c|
        try quantityWith("kcal", c)
    else
        null;
    const distance = if (request.distance_meters) |m|
        try quantityWith("m", m)
    else
        null;

    const metadata = try workoutMetadata(allocator, request.activity_id);

    const WorkoutFn = *const fn (objc.Class, objc.SEL, c_ulong, Id, Id, Id, Id, Id, Id) callconv(.c) Id;
    const workoutWith: WorkoutFn = @ptrCast(&objc.objc_msgSend);
    const workout = workoutWith(
        HKWorkout,
        sel,
        request.activity,
        start_date,
        end_date,
        null,
        energy,
        distance,
        metadata,
    ) orelse return BridgeError.NativeCallFailed;

    // Autoreleased by the class method; retained because it has to survive
    // two more asynchronous stages.
    return retainObject(workout);
}

fn quantityWith(unit: [*:0]const u8, value: f64) !Id {
    const HKQuantity = objc.objc_getClass("HKQuantity") orelse return BridgeError.PlatformNotSupported;
    const sel = objc.sel_registerName("quantityWithUnit:doubleValue:") orelse
        return BridgeError.NativeCallFailed;
    const resolved_unit = try unitFromString(unit);
    const QuantityFn = *const fn (objc.Class, objc.SEL, Id, f64) callconv(.c) Id;
    const quantityWithFn: QuantityFn = @ptrCast(&objc.objc_msgSend);
    return quantityWithFn(HKQuantity, sel, resolved_unit, value) orelse BridgeError.NativeCallFailed;
}

/// `@{HKMetadataKeyExternalUUID: activityId, HKMetadataKeyIndoorWorkout: @NO}`.
fn workoutMetadata(allocator: std.mem.Allocator, activity_id: []const u8) !Id {
    const NSMutableDictionary = objc.objc_getClass("NSMutableDictionary") orelse
        return BridgeError.NativeCallFailed;
    const metadata = objc.allocInit(NSMutableDictionary) catch return BridgeError.NativeCallFailed;

    const sel_set = objc.sel_registerName("setObject:forKey:") orelse
        return BridgeError.NativeCallFailed;

    const external_key = try healthConstant("HKMetadataKeyExternalUUID");
    const ns_activity = objc.createNSString(activity_id, allocator) catch
        return BridgeError.AllocationFailed;
    objc.msgSendVoid2(metadata, sel_set, ns_activity, external_key);

    const indoor_key = try healthConstant("HKMetadataKeyIndoorWorkout");
    const NSNumber = objc.objc_getClass("NSNumber") orelse return BridgeError.NativeCallFailed;
    const sel_bool = objc.sel_registerName("numberWithBool:") orelse
        return BridgeError.NativeCallFailed;
    const BoolFn = *const fn (objc.Class, objc.SEL, bool) callconv(.c) Id;
    const numberWith: BoolFn = @ptrCast(&objc.objc_msgSend);
    const no = numberWith(NSNumber, sel_bool, false) orelse return BridgeError.NativeCallFailed;
    objc.msgSendVoid2(metadata, sel_set, no, indoor_key);

    return metadata;
}

/// The `locations` array as an `NSArray<CLLocation *>`, or null when there is
/// nothing usable in it.
///
/// Null and empty are the same thing to the caller — both take Swift's early
/// `guard !locations.isEmpty` exit — so a page that sends ten malformed
/// locations gets its workout saved with no route rather than an error. That
/// is Swift's `compactMap`, which drops what it cannot read.
fn buildLocations(
    allocator: std.mem.Allocator,
    payload: std.json.Value,
    request: WorkoutRequest,
) !Id {
    const object = switch (payload) {
        .object => |o| o,
        else => return null,
    };
    const field = object.get("locations") orelse return null;
    const items = switch (field) {
        .array => |a| a,
        else => return null,
    };

    const CLLocation = objc.objc_getClass("CLLocation") orelse return null;
    const sel_alloc = objc.sel_registerName("alloc") orelse return null;
    const sel_init = objc.sel_registerName(
        "initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:timestamp:",
    ) orelse return null;
    const InitFn = *const fn (Id, objc.SEL, CLLocationCoordinate2D, f64, f64, f64, Id) callconv(.c) Id;
    const initFn: InitFn = @ptrCast(&objc.objc_msgSend);

    var built: std.ArrayListUnmanaged(Id) = .empty;
    defer built.deinit(allocator);

    for (items.items) |item| {
        const fields = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const latitude = numberField(fields, "latitude") orelse continue;
        const longitude = numberField(fields, "longitude") orelse continue;
        const timestamp_ms = numberField(fields, "timestamp") orelse continue;
        const seconds = timestamp_ms / 1000.0;

        // Swift filters the built list to the workout's window; doing it
        // before construction is the same set without the allocations.
        if (seconds < request.start or seconds > request.end) continue;

        const allocated = objc.msgSendId(CLLocation, sel_alloc) orelse continue;
        const location = initFn(
            allocated,
            sel_init,
            .{ .latitude = latitude, .longitude = longitude },
            numberField(fields, "altitude") orelse default_altitude,
            numberField(fields, "accuracy") orelse default_horizontal_accuracy,
            unknown_vertical_accuracy,
            try dateFromInterval(seconds),
        ) orelse continue;

        try built.append(allocator, location);
    }

    if (built.items.len == 0) return null;

    const NSArray = objc.objc_getClass("NSArray") orelse return null;
    const sel_array = objc.sel_registerName("arrayWithObjects:count:") orelse return null;
    const ArrayFn = *const fn (objc.Class, objc.SEL, [*]const Id, c_ulong) callconv(.c) Id;
    const arrayWith: ArrayFn = @ptrCast(&objc.objc_msgSend);
    const array = arrayWith(NSArray, sel_array, built.items.ptr, built.items.len) orelse return null;
    return retainObject(array);
}

fn numberField(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn uuidStringOf(object: Id) ?[]const u8 {
    const sel_uuid = objc.sel_registerName("UUID") orelse return null;
    const uuid = objc.msgSendId(object, sel_uuid) orelse return null;
    const sel_string = objc.sel_registerName("UUIDString") orelse return null;
    const ns = objc.msgSendId(uuid, sel_string) orelse return null;
    const utf8 = objc.getNSStringUTF8(ns) orelse return null;
    return std.mem.span(utf8);
}

fn retainObject(object: Id) Id {
    const target = object orelse return null;
    const sel = objc.sel_registerName("retain") orelse return object;
    return objc.msgSendId(target, sel);
}

fn releaseObject(object: Id) void {
    const target = object orelse return;
    const sel = objc.sel_registerName("release") orelse return;
    objc.msgSend(target, sel);
}

// ---------------------------------------------------------------------------
// The two completions
// ---------------------------------------------------------------------------

/// What a slot's block needs that the block itself cannot carry.
const PendingCall = struct {
    ticket: ios_async.Ticket,
    /// The `HKUnit` the statistics reply reports in, or null for the calls
    /// that report none.
    unit: Id = null,
    /// Everything the three-stage workout chain carries between its blocks.
    workout: ?WorkoutChain = null,
};

/// What survives from `saveHealthWorkout`'s dispatch into its later stages.
///
/// None of the three blocks can carry any of it: they are global, so they
/// capture nothing, and the two later ones do not even receive the workout
/// they are attaching a route to.
const WorkoutChain = struct {
    /// Retained; released when the chain ends, however it ends.
    workout: Id,
    /// Retained `NSArray<CLLocation *>`, or null when there is no route.
    locations: Id,
    /// The `HKHealthStore` the route builder is created against.
    store: Id,
    /// Owned, `c_allocator`. The route's `HKMetadataKeyExternalUUID`.
    activity_id: []u8,
    /// Retained once stage two begins.
    builder: Id = null,

    /// Free everything this chain owns. Idempotent by construction: the entry
    /// is cleared from the slot before this runs.
    fn deinit(self: WorkoutChain) void {
        releaseObject(self.workout);
        releaseObject(self.locations);
        releaseObject(self.builder);
        std.heap.c_allocator.free(self.activity_id);
    }
};

var pending_calls: [ios_async.max_in_flight]?PendingCall = @splat(null);
var pending_mutex: compat_mutex.Mutex = .{};

fn publishCall(ticket: ios_async.Ticket, unit: Id) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls[ticket.index] = .{ .ticket = ticket, .unit = unit };
}

fn publishWorkoutCall(ticket: ios_async.Ticket, chain: WorkoutChain) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls[ticket.index] = .{ .ticket = ticket, .workout = chain };
}

/// Put a chain back for its next stage, keeping the same slot and ticket.
///
/// The entry is taken at the top of every stage so a duplicate fire finds
/// nothing; a stage that intends to continue has to put it back explicitly,
/// which is what makes "this stage is done with the chain" and "the chain
/// continues" different statements rather than the same silence.
fn republishWorkoutCall(call: PendingCall, chain: WorkoutChain) void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    pending_calls[call.ticket.index] = .{ .ticket = call.ticket, .workout = chain };
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

fn makeSaveInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const HealthBlock, success: bool, err: Id) callconv(.c) void {
            workoutSaved(index, success, err);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeInsertInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const HealthBlock, success: bool, err: Id) callconv(.c) void {
            routeInserted(index, success, err);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeFinishInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const HealthBlock, route: Id, err: Id) callconv(.c) void {
            routeFinished(index, route, err);
        }
    };
    return @ptrCast(&S.invoke);
}

var save_blocks: [ios_async.max_in_flight]HealthBlock =
    if (is_darwin) makeBlocks(makeSaveInvoke) else undefined;
var insert_blocks: [ios_async.max_in_flight]HealthBlock =
    if (is_darwin) makeBlocks(makeInsertInvoke) else undefined;
var finish_blocks: [ios_async.max_in_flight]HealthBlock =
    if (is_darwin) makeBlocks(makeFinishInvoke) else undefined;

/// Stage one: the workout is in the store.
fn workoutSaved(index: u5, success: bool, err: Id) void {
    if (!is_darwin) return;

    const call = takeCall(index) orelse {
        std.log.warn("saveHealthWorkout: stage one fired for slot {d} with no call; ignored", .{index});
        return;
    };
    const chain = call.workout orelse {
        std.log.warn("saveHealthWorkout: stage one fired for a slot holding no workout chain", .{});
        return;
    };

    if (!success) {
        logNSError(A.save_health_workout, err);
        chain.deinit();
        ios_async.deliverErrorCode(call.ticket, BridgeError.PermissionDenied);
        return;
    }

    // Swift's early exit. The workout is saved either way; a route is
    // optional, so having none is not a failure.
    if (chain.locations == null) {
        replyWithWorkout(call.ticket, chain, null);
        chain.deinit();
        return;
    }

    var next = chain;
    next.builder = routeBuilder(chain.store) catch |build_err| {
        std.log.warn("saveHealthWorkout: could not build a route builder: {}", .{build_err});
        // The workout is already saved, so answering with its id is truer
        // than reporting a failure — Swift rejects here, and would tell a page
        // nothing was written when something was.
        replyWithWorkout(call.ticket, chain, null);
        chain.deinit();
        return;
    };
    republishWorkoutCall(call, next);

    const sel = objc.sel_registerName("insertRouteData:completion:") orelse return;
    const InsertFn = *const fn (Id, objc.SEL, Id, *anyopaque) callconv(.c) void;
    const insert: InsertFn = @ptrCast(&objc.objc_msgSend);
    insert(next.builder, sel, next.locations, @ptrCast(&insert_blocks[index]));
}

/// Stage two: the fixes are in the builder.
fn routeInserted(index: u5, success: bool, err: Id) void {
    if (!is_darwin) return;

    const call = takeCall(index) orelse return;
    const chain = call.workout orelse return;

    if (!success) {
        // Rejects, as the spec does. Resolving here reported a workout with
        // `"routeId":""`, which is the shape a *successful* finish with a nil
        // route produces — so a page could not tell "the route saved and had no
        // id" from "the route did not save at all", and would file the workout
        // as complete with its locations silently missing.
        //
        // The id is not lost, it is logged: a fabricated success costs more
        // than a rejection, and this module refuses one everywhere else.
        logNSError(A.save_health_workout, err);
        std.log.info(
            "saveHealthWorkout: route insert failed; the workout itself was saved as {s}",
            .{uuidStringOf(chain.workout) orelse "<no uuid>"},
        );
        ios_async.deliverErrorCode(call.ticket, bridge_error.BridgeError.NativeCallFailed);
        chain.deinit();
        return;
    }

    republishWorkoutCall(call, chain);

    const metadata = routeMetadata(chain.activity_id) catch null;
    const sel = objc.sel_registerName("finishRouteWithWorkout:metadata:completion:") orelse return;
    const FinishFn = *const fn (Id, objc.SEL, Id, Id, *anyopaque) callconv(.c) void;
    const finish: FinishFn = @ptrCast(&objc.objc_msgSend);
    finish(chain.builder, sel, chain.workout, metadata, @ptrCast(&finish_blocks[index]));
}

/// Stage three: the route is attached.
fn routeFinished(index: u5, route: Id, err: Id) void {
    if (!is_darwin) return;

    const call = takeCall(index) orelse return;
    const chain = call.workout orelse return;
    defer chain.deinit();

    if (err != null) {
        // Same reasoning as `routeInserted`: the spec rejects on a finish
        // error, and resolving would be indistinguishable from the nil-route
        // success below.
        logNSError(A.save_health_workout, err);
        std.log.info(
            "saveHealthWorkout: route finish failed; the workout itself was saved as {s}",
            .{uuidStringOf(chain.workout) orelse "<no uuid>"},
        );
        ios_async.deliverErrorCode(call.ticket, bridge_error.BridgeError.NativeCallFailed);
        return;
    }
    replyWithWorkout(call.ticket, chain, route);
}

/// `{"id":…}` or `{"id":…,"routeId":…}`.
///
/// Swift emits the second shape only when a route was finished, and its
/// `routeId` is `route?.uuid.uuidString ?? ""` — so a finished-but-nil route
/// carries an empty string rather than a missing key.
///
/// Only reached on success now. The two failure stages reject instead, because
/// an empty `routeId` here already means "finished, no id" and cannot also mean
/// "did not finish".
fn replyWithWorkout(ticket: ios_async.Ticket, chain: WorkoutChain, route: Id) void {
    const allocator = std.heap.c_allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    out.appendSlice(allocator, "{\"id\":") catch return ios_async.deliverError(ticket);
    appendQuoted(allocator, &out, uuidStringOf(chain.workout) orelse "") catch
        return ios_async.deliverError(ticket);

    if (route != null or chain.locations != null) {
        out.appendSlice(allocator, ",\"routeId\":") catch return ios_async.deliverError(ticket);
        appendQuoted(allocator, &out, uuidStringOf(route) orelse "") catch
            return ios_async.deliverError(ticket);
    }
    out.append(allocator, '}') catch return ios_async.deliverError(ticket);

    ios_async.deliverJson(ticket, out.items);
}

fn appendQuoted(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
) !void {
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, out, text);
    try out.append(allocator, '"');
}

/// `[[HKWorkoutRouteBuilder alloc] initWithHealthStore:device:]`, retained.
fn routeBuilder(store: Id) !Id {
    const HKWorkoutRouteBuilder = objc.objc_getClass("HKWorkoutRouteBuilder") orelse
        return error.ClassNotFound;
    const sel_alloc = objc.sel_registerName("alloc") orelse return error.SelectorNotFound;
    const sel_init = objc.sel_registerName("initWithHealthStore:device:") orelse
        return error.SelectorNotFound;
    const allocated = objc.msgSendId(HKWorkoutRouteBuilder, sel_alloc) orelse
        return error.NativeCallFailed;

    // `HKDevice.localDevice` is Swift's `.local()`.
    const HKDevice = objc.objc_getClass("HKDevice");
    const device = if (HKDevice) |cls| blk: {
        const sel_local = objc.sel_registerName("localDevice") orelse break :blk null;
        break :blk objc.msgSendId(cls, sel_local);
    } else null;

    return objc.msgSendId2(allocated, sel_init, store, device) orelse error.NativeCallFailed;
}

fn routeMetadata(activity_id: []const u8) !Id {
    const NSDictionary = objc.objc_getClass("NSDictionary") orelse return error.ClassNotFound;
    const sel = objc.sel_registerName("dictionaryWithObject:forKey:") orelse
        return error.SelectorNotFound;
    const key = try healthConstant("HKMetadataKeyExternalUUID");
    const value = objc.createNSString(activity_id, std.heap.c_allocator) catch
        return error.AllocationFailed;
    return objc.msgSendId2(NSDictionary, sel, value, key) orelse error.NativeCallFailed;
}

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

test "nothing in this family is unserved any more" {
    // This test used to assert the opposite. The split was always about cost
    // rather than correctness — the three share only a stateless
    // HKHealthStore, so no divided state was ever at risk — and the cost was
    // the third asynchronous stage, which now exists.
    try testing.expectEqual(@as(usize, 0), deliberately_unserved.len);

    var bridge = HealthBridge.init(testing.allocator);
    defer bridge.deinit();
    bridge.handleMessage(A.save_health_workout, "{}") catch |err| {
        try testing.expect(err != BridgeError.UnknownAction);
    };
}

test "the workout activity values are the SDK's, not instinct" {
    // Every one of these reads wrong on instinct — running looks like it
    // should sit beside walking, and it does not. The enum in HKWorkout.h
    // numbers most members implicitly, so the values are only obtainable by
    // counting from the last explicit one. A wrong number saves a real
    // workout under the wrong activity, which HealthKit accepts silently.
    try testing.expectEqual(@as(c_ulong, 34), workoutActivityFor("running").?);
    try testing.expectEqual(@as(c_ulong, 49), workoutActivityFor("walking").?);
    try testing.expectEqual(@as(c_ulong, 22), workoutActivityFor("hiking").?);
    try testing.expectEqual(@as(c_ulong, 13), workoutActivityFor("cycling").?);
    try testing.expect(workoutActivityFor("swimming") == null);
    try testing.expectEqual(@as(usize, 4), workout_activities.len);
}

test "the workout guard refuses each way it can be refused" {
    // Swift's four-clause guard rejects all of them with one message. These
    // codes are the distinction a page could not previously make.
    try expectWorkoutRefused("{}", BridgeError.MissingData);
    try expectWorkoutRefused("{\"activityId\":\"a\"}", BridgeError.MissingData);
    try expectWorkoutRefused(
        "{\"activityId\":\"a\",\"type\":\"swimming\",\"startDate\":1,\"endDate\":2}",
        BridgeError.InvalidParameter,
    );
    try expectWorkoutRefused(
        "{\"activityId\":\"a\",\"type\":\"running\",\"startDate\":2000,\"endDate\":1000}",
        BridgeError.InvalidParameter,
    );
    // Equal dates are refused too: Swift's guard is `endValue > startValue`.
    try expectWorkoutRefused(
        "{\"activityId\":\"a\",\"type\":\"running\",\"startDate\":1000,\"endDate\":1000}",
        BridgeError.InvalidParameter,
    );
}

fn expectWorkoutRefused(comptime json: []const u8, expected: anyerror) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, readWorkoutRequest(parsed.value));
}

test "a non-positive distance or energy is dropped, not saved as zero" {
    // Swift's `.flatMap { $0 > 0 ? … : nil }`. A workout carrying an explicit
    // zero distance reads as "measured none"; nil reads as "did not measure".
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"activityId\":\"a\",\"type\":\"running\",\"startDate\":1000,\"endDate\":2000," ++
            "\"distanceMeters\":0,\"activeEnergyCalories\":12.5}",
        .{},
    );
    defer parsed.deinit();

    const request = try readWorkoutRequest(parsed.value);
    try testing.expect(request.distance_meters == null);
    try testing.expectEqual(@as(f64, 12.5), request.energy_calories.?);
    // Milliseconds in, seconds out.
    try testing.expectEqual(@as(f64, 1), request.start);
    try testing.expectEqual(@as(f64, 2), request.end);
}

test "the three workout stages have distinct invokes per slot" {
    // Stage two and stage three take different argument types — (BOOL,
    // NSError*) and (HKWorkoutRoute*, NSError*) — so a shared invoke would
    // read the route out of a boolean register.
    if (!is_darwin) return error.SkipZigTest;

    for (&save_blocks, &insert_blocks, &finish_blocks) |*save, *insert, *finish| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, save.isa);
        try testing.expect(save.invoke != insert.invoke);
        try testing.expect(insert.invoke != finish.invoke);
        try testing.expect(save.invoke != finish.invoke);
    }
    try testing.expect(save_blocks[0].invoke != save_blocks[1].invoke);
}

test "a workout stage firing for a slot with no chain is ignored" {
    // Each stage takes the entry and a continuing stage puts it back, so a
    // duplicate fire finds nothing rather than releasing the workout twice.
    if (!is_darwin) return error.SkipZigTest;

    pending_mutex.lock();
    for (&pending_calls) |*entry| entry.* = null;
    pending_mutex.unlock();

    workoutSaved(0, true, null);
    routeInserted(0, true, null);
    routeFinished(0, null, null);
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
