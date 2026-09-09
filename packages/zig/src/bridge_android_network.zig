//! `getNetworkStatus` on Android.
//!
//! ## The action iOS could not serve, for a reason that is genuinely platform-
//! specific
//!
//! `bridge_mobile_device.zig` declares this `.status = .unavailable` on iOS,
//! and the reason is not a shortcut: no synchronous iOS API can answer
//! `isConnected` without fabricating it. `NWPathMonitor` delivers on a
//! background queue, `SCNetworkReachability` is deprecated, cannot see wired
//! ethernet, and reports the *host Mac's* reachability on the simulator, and
//! `getifaddrs` knows which interfaces are up but not whether anything is
//! reachable. The alternative there is `{"isConnected":true,"type":"unknown"}`,
//! which a caller cannot tell from a real reading.
//!
//! Android has the API iOS lacks. `ConnectivityManager.getNetworkCapabilities`
//! is synchronous and answers null when nothing is connected, so `isConnected`
//! is a fact here rather than a guess. Same action name, opposite verdict, and
//! the difference is the platform rather than the effort.
//!
//! ## `isConnected` and `type` are not the same question
//!
//! `capabilities != null` means *something* is connected. The transport is a
//! separate lookup, and the Kotlin's `when` falls through to `"none"` when
//! none of WIFI, CELLULAR or ETHERNET matches — which happens on Bluetooth
//! tethering, on a VPN-only interface, and on emulators.
//!
//! So `{"isConnected":true,"type":"none"}` is a reachable and correct state,
//! not a contradiction to smooth over. A reading that forced `type` to
//! `"unknown"` whenever connected, or forced `isConnected` false whenever the
//! transport was unrecognised, would each be wrong in a way the page could not
//! detect.

const std = @import("std");
const jni = @import("jni_runtime.zig");

const Jni = jni.Jni;
const jobject = jni.jobject;

pub const A = struct {
    pub const get_network_status = "getNetworkStatus";
    pub const start_network_monitoring = "startNetworkMonitoring";
    pub const stop_network_monitoring = "stopNetworkMonitoring";
};

/// The global the injected JS assigns for network changes.
///
/// Not a promise: `onNetworkChange(cb)` stores the callback once and every
/// change calls it, so this global outlives any single reply — which is why
/// the guard in front of it matters more here than elsewhere. A change
/// arriving before the page has registered is dropped rather than throwing.
pub const change_global = "_craftNetworkChangeCallback";

/// The transports the Kotlin's `when` distinguishes, in its order.
///
/// Order is contract: `when` takes the first match, so a connection that is
/// both WIFI and ETHERNET — which a bridged emulator can report — answers
/// `"wifi"` on both sides only if the checks run in the same sequence.
pub const Transport = enum {
    wifi,
    cellular,
    ethernet,
    none,

    pub fn name(self: Transport) []const u8 {
        return switch (self) {
            .wifi => "wifi",
            .cellular => "cellular",
            .ethernet => "ethernet",
            .none => "none",
        };
    }
};

pub const NetworkStatus = struct {
    connected: bool,
    transport: Transport,
};

/// The reply bytes, in the Kotlin's `put` order.
///
/// `isWifi` and `isCellular` are derived from the transport rather than read
/// again — that is what the Kotlin does (`connectionType == "wifi"`), and
/// deriving them separately would let the three disagree.
pub fn render(allocator: std.mem.Allocator, status: NetworkStatus) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"isConnected\":");
    try out.appendSlice(allocator, if (status.connected) "true" else "false");
    try out.appendSlice(allocator, ",\"type\":\"");
    try out.appendSlice(allocator, status.transport.name());
    try out.appendSlice(allocator, "\",\"isWifi\":");
    try out.appendSlice(allocator, if (status.transport == .wifi) "true" else "false");
    try out.appendSlice(allocator, ",\"isCellular\":");
    try out.appendSlice(allocator, if (status.transport == .cellular) "true" else "false");
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

/// Ask `ConnectivityManager` what the active network can do.
pub fn read(j: Jni, activity: jobject) !NetworkStatus {
    try j.pushLocalFrame(16);
    defer _ = j.popLocalFrame(null);

    const context_cls = try j.findClass("android/content/Context");
    const service_name = try j.staticObjectField(
        context_cls,
        try j.staticFieldId(context_cls, "CONNECTIVITY_SERVICE", "Ljava/lang/String;"),
    );

    const activity_cls = try j.objectClass(activity);
    const manager = try j.callObjectMethodA(
        activity,
        try j.methodId(activity_cls, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;"),
        &.{.{ .l = service_name }},
    );

    const manager_cls = try j.objectClass(manager);
    const network = try j.callObjectMethod(
        manager,
        try j.methodId(manager_cls, "getActiveNetwork", "()Landroid/net/Network;"),
    );

    // `getNetworkCapabilities(null)` is legal and answers null, which is the
    // same "not connected" the Kotlin reads — so the null network needs no
    // branch of its own here, only the null capabilities below.
    const capabilities = try j.callObjectMethodA(
        manager,
        try j.methodId(
            manager_cls,
            "getNetworkCapabilities",
            "(Landroid/net/Network;)Landroid/net/NetworkCapabilities;",
        ),
        &.{.{ .l = network }},
    );
    if (capabilities == null) return .{ .connected = false, .transport = .none };

    const caps_cls = try j.findClass("android/net/NetworkCapabilities");
    const has_transport = try j.methodId(caps_cls, "hasTransport", "(I)Z");

    // Checked in the Kotlin's order, and stopping at the first match, because
    // `when` does.
    const probes = [_]struct { field: [*:0]const u8, transport: Transport }{
        .{ .field = "TRANSPORT_WIFI", .transport = .wifi },
        .{ .field = "TRANSPORT_CELLULAR", .transport = .cellular },
        .{ .field = "TRANSPORT_ETHERNET", .transport = .ethernet },
    };

    for (probes) |probe| {
        const value = try j.staticIntField(
            caps_cls,
            try j.staticFieldId(caps_cls, probe.field, "I"),
        );
        if (try j.callBooleanMethodA(capabilities, has_transport, &.{.{ .i = value }})) {
            return .{ .connected = true, .transport = probe.transport };
        }
    }

    // Connected over something else — Bluetooth tethering, a VPN-only
    // interface, an emulator. See the module comment: this is a real state.
    return .{ .connected = true, .transport = .none };
}

/// `NetworkCapabilities.NET_CAPABILITY_INTERNET`, the one capability the
/// shim's `NetworkRequest` asks for.
///
/// Written down rather than read, because it is the Kotlin holder that builds
/// the request — this constant is here only so the test can say what the
/// holder is expected to have asked for.
pub const net_capability_internet: i32 = 12;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn parsed(status: NetworkStatus) !std.json.Parsed(std.json.Value) {
    const json = try render(testing.allocator, status);
    defer testing.allocator.free(json);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
}

test "the reply carries every key the Kotlin puts" {
    var p = try parsed(.{ .connected = true, .transport = .wifi });
    defer p.deinit();
    const obj = p.value.object;

    try testing.expectEqual(@as(usize, 4), obj.count());
    try testing.expectEqual(true, obj.get("isConnected").?.bool);
    try testing.expectEqualStrings("wifi", obj.get("type").?.string);
    try testing.expectEqual(true, obj.get("isWifi").?.bool);
    try testing.expectEqual(false, obj.get("isCellular").?.bool);
}

test "isWifi and isCellular follow the transport rather than being read twice" {
    // The Kotlin derives both from `connectionType`, so they cannot disagree
    // with `type`. Deriving them independently is the bug this pins.
    {
        var p = try parsed(.{ .connected = true, .transport = .cellular });
        defer p.deinit();
        try testing.expectEqualStrings("cellular", p.value.object.get("type").?.string);
        try testing.expectEqual(false, p.value.object.get("isWifi").?.bool);
        try testing.expectEqual(true, p.value.object.get("isCellular").?.bool);
    }
    {
        var p = try parsed(.{ .connected = true, .transport = .ethernet });
        defer p.deinit();
        try testing.expectEqualStrings("ethernet", p.value.object.get("type").?.string);
        try testing.expectEqual(false, p.value.object.get("isWifi").?.bool);
        try testing.expectEqual(false, p.value.object.get("isCellular").?.bool);
    }
}

test "connected over an unrecognised transport is a real state, not a contradiction" {
    // Bluetooth tethering, a VPN-only interface, most emulators. The Kotlin's
    // `when` falls through to "none" while `capabilities != null` stays true,
    // and a reading that "corrected" either half would be wrong in a way the
    // page could not detect.
    var p = try parsed(.{ .connected = true, .transport = .none });
    defer p.deinit();
    try testing.expectEqual(true, p.value.object.get("isConnected").?.bool);
    try testing.expectEqualStrings("none", p.value.object.get("type").?.string);
}

test "no connection reports both halves as absent" {
    var p = try parsed(.{ .connected = false, .transport = .none });
    defer p.deinit();
    try testing.expectEqual(false, p.value.object.get("isConnected").?.bool);
    try testing.expectEqualStrings("none", p.value.object.get("type").?.string);
    try testing.expectEqual(false, p.value.object.get("isWifi").?.bool);
    try testing.expectEqual(false, p.value.object.get("isCellular").?.bool);
}

test "the transport names are the strings the page compares against" {
    // `craft.d.ts` types this as a union of these literals, and pages switch
    // on them. A rename here is a silent behaviour change for every consumer.
    try testing.expectEqualStrings("wifi", Transport.wifi.name());
    try testing.expectEqualStrings("cellular", Transport.cellular.name());
    try testing.expectEqualStrings("ethernet", Transport.ethernet.name());
    try testing.expectEqualStrings("none", Transport.none.name());
}

test "the action name matches the Kotlin method exactly" {
    try testing.expectEqualStrings("getNetworkStatus", A.get_network_status);
}

// --- A fake ConnectivityManager -------------------------------------------
//
// `read` makes the transport claim that the module comment calls contract:
// the checks run in the Kotlin's order and stop at the first match. Nothing
// above tests that, because `render` never sees it — so the fake is here to
// make the claim assertable rather than decorative.

var fake_storage: [8]u8 = undefined;
var fake_capabilities_null = false;
/// Which `TRANSPORT_*` values `hasTransport` answers true for. The fake
/// returns the field name's hash as the constant, so the set is by name.
var fake_transports: []const []const u8 = &.{};
var fake_last_field: [*:0]const u8 = "";

fn fobj(tag: usize) jobject {
    return @ptrCast(&fake_storage[tag]);
}

fn transportValue(name: []const u8) jni.jint {
    // Stable small integers standing in for the real constants. Their values
    // do not matter; that each is distinct does.
    if (std.mem.eql(u8, name, "TRANSPORT_WIFI")) return 1;
    if (std.mem.eql(u8, name, "TRANSPORT_CELLULAR")) return 0;
    if (std.mem.eql(u8, name, "TRANSPORT_ETHERNET")) return 3;
    return -1;
}

fn nFindClass(_: jni.JNIEnv, _: [*:0]const u8) callconv(.c) jni.jclass {
    return fobj(0);
}
fn nObjectClass(_: jni.JNIEnv, _: jobject) callconv(.c) jni.jclass {
    return fobj(0);
}
fn nStaticFieldId(_: jni.JNIEnv, _: jni.jclass, name: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jfieldID {
    fake_last_field = name;
    return @ptrCast(@constCast(name));
}
fn nStaticObjectField(_: jni.JNIEnv, _: jni.jclass, _: jni.jfieldID) callconv(.c) jobject {
    return fobj(1);
}
fn nStaticIntField(_: jni.JNIEnv, _: jni.jclass, id: jni.jfieldID) callconv(.c) jni.jint {
    return transportValue(std.mem.span(@as([*:0]const u8, @ptrCast(id.?))));
}
fn nMethodId(_: jni.JNIEnv, _: jni.jclass, name: [*:0]const u8, _: [*:0]const u8) callconv(.c) jni.jmethodID {
    return @ptrCast(@constCast(name));
}
fn nCallObjectMethod(_: jni.JNIEnv, _: jobject, _: jni.jmethodID) callconv(.c) jobject {
    return fobj(2); // getActiveNetwork
}
fn nCallObjectMethodA(_: jni.JNIEnv, _: jobject, id: jni.jmethodID, _: [*]const jni.jvalue) callconv(.c) jobject {
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(id.?)));
    if (std.mem.eql(u8, name, "getNetworkCapabilities"))
        return if (fake_capabilities_null) null else fobj(3);
    return fobj(4); // getSystemService
}
fn nCallBooleanMethodA(_: jni.JNIEnv, _: jobject, _: jni.jmethodID, args: [*]const jni.jvalue) callconv(.c) jni.jboolean {
    for (fake_transports) |t| {
        if (transportValue(t) == args[0].i) return jni.JNI_TRUE;
    }
    return jni.JNI_FALSE;
}
fn nExceptionOccurred(_: jni.JNIEnv) callconv(.c) jobject {
    return null;
}
fn nPush(_: jni.JNIEnv, _: jni.jint) callconv(.c) jni.jint {
    return 0;
}
fn nPop(_: jni.JNIEnv, keep: jobject) callconv(.c) jobject {
    return keep;
}

fn readWith(transports: []const []const u8, capabilities_null: bool) !NetworkStatus {
    fake_transports = transports;
    fake_capabilities_null = capabilities_null;

    var table = std.mem.zeroes(jni.JNINativeInterface);
    table.FindClass = @ptrCast(&nFindClass);
    table.GetObjectClass = @ptrCast(&nObjectClass);
    table.GetStaticFieldID = @ptrCast(&nStaticFieldId);
    table.GetStaticObjectField = @ptrCast(&nStaticObjectField);
    table.GetStaticIntField = @ptrCast(&nStaticIntField);
    table.GetMethodID = @ptrCast(&nMethodId);
    table.CallObjectMethod = @ptrCast(&nCallObjectMethod);
    table.CallObjectMethodA = @ptrCast(&nCallObjectMethodA);
    table.CallBooleanMethodA = @ptrCast(&nCallBooleanMethodA);
    table.ExceptionOccurred = @ptrCast(&nExceptionOccurred);
    table.PushLocalFrame = @ptrCast(&nPush);
    table.PopLocalFrame = @ptrCast(&nPop);

    const ptr: *const jni.JNINativeInterface = &table;
    return read(Jni.init(&ptr), fobj(5));
}

test "each transport is recognised as itself" {
    try testing.expectEqual(Transport.wifi, (try readWith(&.{"TRANSPORT_WIFI"}, false)).transport);
    try testing.expectEqual(Transport.cellular, (try readWith(&.{"TRANSPORT_CELLULAR"}, false)).transport);
    try testing.expectEqual(Transport.ethernet, (try readWith(&.{"TRANSPORT_ETHERNET"}, false)).transport);
}

test "a connection with two transports answers the first the Kotlin would check" {
    // The claim the module comment makes. `when` takes its first true branch,
    // so a bridged emulator reporting both WIFI and ETHERNET must answer
    // "wifi" — and it only does if the probes run in the Kotlin's order.
    // Reordering them here changes the answer without changing anything a
    // reader would look at.
    const both = try readWith(&.{ "TRANSPORT_ETHERNET", "TRANSPORT_WIFI" }, false);
    try testing.expectEqual(Transport.wifi, both.transport);

    const cell_and_eth = try readWith(&.{ "TRANSPORT_ETHERNET", "TRANSPORT_CELLULAR" }, false);
    try testing.expectEqual(Transport.cellular, cell_and_eth.transport);
}

test "null capabilities is not connected, and an unknown transport still is" {
    const offline = try readWith(&.{}, true);
    try testing.expectEqual(false, offline.connected);
    try testing.expectEqual(Transport.none, offline.transport);

    // Capabilities present, no transport matched — Bluetooth tethering or a
    // VPN-only interface. Connected, and honestly typed "none".
    const odd = try readWith(&.{}, false);
    try testing.expectEqual(true, odd.connected);
    try testing.expectEqual(Transport.none, odd.transport);
}

test "the monitoring pair names itself as the shim does" {
    try testing.expectEqualStrings("startNetworkMonitoring", A.start_network_monitoring);
    try testing.expectEqualStrings("stopNetworkMonitoring", A.stop_network_monitoring);
}

test "a change is delivered to the callback the page registered, not a promise" {
    // `onNetworkChange(cb)` assigns this once and every change calls it. A
    // promise global is assigned per call and consumed; this one is not, so a
    // page that never called `onNetworkChange` leaves it undefined and the
    // guard in `settle` is what stops a ReferenceError inside
    // evaluateJavascript, where nothing would see it.
    try testing.expectEqualStrings("_craftNetworkChangeCallback", change_global);
    try testing.expect(!std.mem.eql(u8, change_global, "_craftNetworkResolve"));
}

test "a change carries the same object getNetworkStatus returns" {
    // `sendNetworkChange` calls `getNetworkStatus()` and sends the result
    // verbatim, so the event payload and the polled answer cannot drift —
    // and here they are literally the same function.
    const json = try render(testing.allocator, .{ .connected = true, .transport = .wifi });
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\{"isConnected":true,"type":"wifi","isWifi":true,"isCellular":false}
    , json);
}
