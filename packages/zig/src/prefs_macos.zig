//! The macOS backend for `prefs.zig`: CoreFoundation preferences, exact domain.
//!
//! Two choices here are load-bearing and were settled by experiment, not by
//! reading documentation.
//!
//! **1. The exact-domain quad, never `CFPreferencesCopyAppValue` and never
//! `NSUserDefaults`.** The convenience APIs consult a *search list*, and the
//! first entry in that list is `NSArgumentDomain` — the process's own command
//! line. Measured: a binary launched as `./probe -zinjected 99` gets the string
//! `"99"` back from `CFPreferencesCopyAppValue("zinjected")` while
//! `CFPreferencesCopyValue` on the same key returns null. craft's entire
//! interface is command-line flags, so under the convenience API
//! `craft --title Hello` would make `prefs.get("title")` return `"Hello"` — and
//! an argument-domain value cannot be removed at runtime, so the collision
//! would be permanent. The quad reads and writes one domain and nothing else.
//!
//! **2. `CFGetTypeID`, never `objCType`.** The usual idiom for telling a stored
//! boolean from the number 1 is `strcmp(objCType, @encode(BOOL))`, and it is
//! wrong on every Mac: `@YES` is the `kCFBooleanTrue` singleton, whose
//! `objCType` is `"c"`, while `@encode(BOOL)` is `"B"` on arm64. Measured:
//! comparing type IDs distinguishes a boolean from an integer from a float
//! correctly, in-process and after a round trip through the preferences daemon.
//! `boolForKey:`/`integerForKey:` are also out — they *coerce*, so the string
//! "YES" reads back as `true`, which is the wrong behaviour for a store whose
//! whole point is faithful types.

const std = @import("std");
const builtin = @import("builtin");
const prefs = @import("prefs.zig");

const is_macos = builtin.os.tag == .macos;

const CFTypeRef = ?*anyopaque;
const CFIndex = isize;
const CFTypeID = usize;

const kCFStringEncodingUTF8: u32 = 0x0800_0100;
const kCFNumberSInt64Type: CFIndex = 4;
const kCFNumberFloat64Type: CFIndex = 6;

extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFGetTypeID(cf: CFTypeRef) CFTypeID;
extern "c" fn CFBooleanGetTypeID() CFTypeID;
extern "c" fn CFNumberGetTypeID() CFTypeID;
extern "c" fn CFStringGetTypeID() CFTypeID;
extern "c" fn CFCopyTypeIDDescription(type_id: CFTypeID) CFTypeRef;

extern "c" fn CFStringCreateWithBytes(alloc: CFTypeRef, bytes: [*]const u8, num_bytes: CFIndex, encoding: u32, external: bool) CFTypeRef;
extern "c" fn CFStringGetLength(s: CFTypeRef) CFIndex;
extern "c" fn CFStringGetMaximumSizeForEncoding(len: CFIndex, encoding: u32) CFIndex;
extern "c" fn CFStringGetCString(s: CFTypeRef, buffer: [*]u8, size: CFIndex, encoding: u32) bool;

extern "c" fn CFNumberCreate(alloc: CFTypeRef, number_type: CFIndex, value_ptr: *const anyopaque) CFTypeRef;
extern "c" fn CFNumberGetValue(number: CFTypeRef, number_type: CFIndex, value_ptr: *anyopaque) bool;
extern "c" fn CFNumberIsFloatType(number: CFTypeRef) bool;
extern "c" fn CFBooleanGetValue(b: CFTypeRef) bool;

extern "c" fn CFArrayGetCount(array: CFTypeRef) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(array: CFTypeRef, index: CFIndex) CFTypeRef;

extern "c" fn CFPreferencesCopyValue(key: CFTypeRef, app_id: CFTypeRef, user: CFTypeRef, host: CFTypeRef) CFTypeRef;
extern "c" fn CFPreferencesSetValue(key: CFTypeRef, value: CFTypeRef, app_id: CFTypeRef, user: CFTypeRef, host: CFTypeRef) void;
extern "c" fn CFPreferencesCopyKeyList(app_id: CFTypeRef, user: CFTypeRef, host: CFTypeRef) CFTypeRef;
extern "c" fn CFPreferencesAppSynchronize(app_id: CFTypeRef) bool;

extern "c" fn CFBundleGetMainBundle() CFTypeRef;
extern "c" fn CFBundleGetIdentifier(bundle: CFTypeRef) CFTypeRef;

extern "c" const kCFBooleanTrue: CFTypeRef;
extern "c" const kCFBooleanFalse: CFTypeRef;
extern "c" const kCFPreferencesCurrentUser: CFTypeRef;
extern "c" const kCFPreferencesAnyHost: CFTypeRef;
extern "c" const kCFPreferencesCurrentApplication: CFTypeRef;

/// Which preferences domain to read and write.
pub const Domain = union(enum) {
    /// `kCFPreferencesCurrentApplication`: the bundle identifier inside a
    /// `.app`, the executable's name otherwise. What production uses.
    ///
    /// The dev/packaged difference is real and visible — an unbundled `craft`
    /// writes `~/Library/Preferences/craft.plist`, a packaged app writes its
    /// bundle id — which is why `prefs:info` reports the live domain rather
    /// than leaving an app to guess where its preferences went.
    current_application,
    /// A literal domain, so the native half can be tested against a throwaway
    /// domain instead of the developer's real one.
    named: []const u8,
};

pub const Backend = struct {
    domain: Domain,
    /// Owned CFString for `.named`; null for `.current_application`.
    domain_ref: CFTypeRef = null,

    pub fn init(domain: Domain) Backend {
        var self = Backend{ .domain = domain };
        if (comptime is_macos) {
            switch (domain) {
                .named => |name| self.domain_ref = cfString(name),
                .current_application => self.domain_ref = kCFPreferencesCurrentApplication,
            }
        }
        return self;
    }

    pub fn deinit(self: *Backend) void {
        if (comptime !is_macos) return;
        if (self.domain == .named) {
            if (self.domain_ref) |r| CFRelease(r);
        }
        self.domain_ref = null;
    }

    pub fn backend(self: *Backend) prefs.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = prefs.Backend.VTable{
        .get = getImpl,
        .set = setImpl,
        .remove = removeImpl,
        .keys = keysImpl,
        .sync = syncImpl,
    };

    fn self_(ctx: *anyopaque) *Backend {
        return @ptrCast(@alignCast(ctx));
    }

    fn getImpl(ctx: *anyopaque, gpa: std.mem.Allocator, full_key: []const u8) prefs.Error!prefs.Read {
        if (comptime !is_macos) return .absent;
        const me = self_(ctx);

        const key = cfString(full_key) orelse return prefs.Error.BackendFailure;
        defer CFRelease(key);

        const value = CFPreferencesCopyValue(key, me.domain_ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (value == null) return .absent;
        defer CFRelease(value);

        return readValue(gpa, value);
    }

    fn setImpl(ctx: *anyopaque, full_key: []const u8, value: prefs.Value) prefs.Error!void {
        if (comptime !is_macos) return prefs.Error.BackendFailure;
        const me = self_(ctx);

        const key = cfString(full_key) orelse return prefs.Error.BackendFailure;
        defer CFRelease(key);

        // Exactly three constructors exist here, and none of them can produce a
        // container. That is what makes the `NSInvalidArgumentException` path
        // unreachable rather than merely avoided — Zig could not catch it.
        const cf: CFTypeRef = switch (value) {
            .string => |s| cfString(s) orelse return prefs.Error.BackendFailure,
            .boolean => |b| if (b) kCFBooleanTrue else kCFBooleanFalse,
            .int => |i| blk: {
                var scratch: i64 = i;
                break :blk CFNumberCreate(null, kCFNumberSInt64Type, &scratch) orelse
                    return prefs.Error.BackendFailure;
            },
            .float => |f| blk: {
                var scratch: f64 = f;
                break :blk CFNumberCreate(null, kCFNumberFloat64Type, &scratch) orelse
                    return prefs.Error.BackendFailure;
            },
        };
        // The booleans are immortal singletons; the other two are ours to free.
        defer switch (value) {
            .boolean => {},
            else => CFRelease(cf),
        };

        CFPreferencesSetValue(key, cf, me.domain_ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    }

    fn removeImpl(ctx: *anyopaque, full_key: []const u8) prefs.Error!bool {
        if (comptime !is_macos) return false;
        const me = self_(ctx);

        const key = cfString(full_key) orelse return prefs.Error.BackendFailure;
        defer CFRelease(key);

        const existing = CFPreferencesCopyValue(key, me.domain_ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        const existed = existing != null;
        if (existing) |e| CFRelease(e);

        // A null value is how CoreFoundation spells "remove".
        CFPreferencesSetValue(key, null, me.domain_ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        return existed;
    }

    fn keysImpl(ctx: *anyopaque, gpa: std.mem.Allocator) prefs.Error![][]u8 {
        if (comptime !is_macos) return gpa.alloc([]u8, 0) catch prefs.Error.OutOfMemory;
        const me = self_(ctx);

        const list = CFPreferencesCopyKeyList(me.domain_ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        // Null rather than an empty array is what a domain with no keys yet
        // returns; it is not a failure.
        if (list == null) return gpa.alloc([]u8, 0) catch prefs.Error.OutOfMemory;
        defer CFRelease(list);

        const count = CFArrayGetCount(list);
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |k| gpa.free(k);
            out.deinit(gpa);
        }

        var index: CFIndex = 0;
        while (index < count) : (index += 1) {
            const item = CFArrayGetValueAtIndex(list, index);
            if (CFGetTypeID(item) != CFStringGetTypeID()) continue;
            const owned = copyCfString(gpa, item) catch continue orelse continue;
            out.append(gpa, owned) catch {
                gpa.free(owned);
                return prefs.Error.OutOfMemory;
            };
        }
        return out.toOwnedSlice(gpa) catch prefs.Error.OutOfMemory;
    }

    fn syncImpl(ctx: *anyopaque) prefs.Error!void {
        if (comptime !is_macos) return;
        const me = self_(ctx);
        // Flushed before the reply goes back, so a resolved `set()` means the
        // bytes are on disk. Not the deprecated `-[NSUserDefaults synchronize]`:
        // Apple names non-app command-line processes as the case that still
        // needs this, and an unbundled dev-mode craft is exactly that — and
        // craft's hot reload kills the process abruptly.
        if (!CFPreferencesAppSynchronize(me.domain_ref)) return prefs.Error.BackendFailure;
    }
};

/// Decide what a stored CoreFoundation value is. Boolean **before** number:
/// `kCFBooleanTrue` also answers to several number-ish tests.
fn readValue(gpa: std.mem.Allocator, value: CFTypeRef) prefs.Error!prefs.Read {
    const type_id = CFGetTypeID(value);

    if (type_id == CFBooleanGetTypeID()) {
        return .{ .value = .{ .boolean = CFBooleanGetValue(value) } };
    }

    if (type_id == CFNumberGetTypeID()) {
        if (CFNumberIsFloatType(value)) {
            var f: f64 = 0;
            if (!CFNumberGetValue(value, kCFNumberFloat64Type, &f)) return prefs.Error.BackendFailure;
            return .{ .value = .{ .float = f } };
        }
        var i: i64 = 0;
        if (!CFNumberGetValue(value, kCFNumberSInt64Type, &i)) return prefs.Error.BackendFailure;
        return .{ .value = .{ .int = i } };
    }

    if (type_id == CFStringGetTypeID()) {
        const owned = (copyCfString(gpa, value) catch return prefs.Error.OutOfMemory) orelse
            return prefs.Error.BackendFailure;
        if (owned.len > prefs.max_value_bytes) {
            // Something outside craft wrote a string larger than craft will
            // hand back. Reported as itself rather than truncated.
            defer gpa.free(owned);
            return .{ .foreign = .{ .cf_type = "CFString", .bytes = owned.len } };
        }
        return .{ .value = .{ .string = owned } };
    }

    return .{ .foreign = .{ .cf_type = typeName(type_id) } };
}

/// CoreFoundation's own name for a type id, for the `foreign` report.
///
/// Static strings for the types worth naming; `CFCopyTypeIDDescription` would
/// mean another allocation and another lifetime on a path that only exists
/// because someone hand-edited the domain.
fn typeName(type_id: CFTypeID) []const u8 {
    if (comptime !is_macos) return "unknown";
    if (type_id == CFStringGetTypeID()) return "CFString";
    if (type_id == CFNumberGetTypeID()) return "CFNumber";
    if (type_id == CFBooleanGetTypeID()) return "CFBoolean";
    const described = CFCopyTypeIDDescription(type_id);
    if (described == null) return "unknown";
    defer CFRelease(described);

    // Best effort into a static buffer: the caller only formats it into JSON.
    var buf: [64]u8 = undefined;
    const max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(described), kCFStringEncodingUTF8) + 1;
    if (max <= 0 or max > buf.len) return "unknown";
    if (!CFStringGetCString(described, &buf, @intCast(buf.len), kCFStringEncodingUTF8)) return "unknown";
    const span = std.mem.sliceTo(&buf, 0);
    // Copied into a comptime-known set so the returned slice outlives `buf`.
    for ([_][]const u8{ "CFArray", "CFDictionary", "CFData", "CFDate", "CFNull" }) |known| {
        if (std.mem.eql(u8, span, known)) return known;
    }
    return "unknown";
}

fn cfString(s: []const u8) CFTypeRef {
    if (comptime !is_macos) return null;
    // Length-explicit, so it needs no NUL scan and returns null on invalid
    // UTF-8 — unlike `stringWithUTF8String:`, whose nil return is how a menu
    // item silently loses its title elsewhere in this codebase.
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), kCFStringEncodingUTF8, false);
}

fn copyCfString(gpa: std.mem.Allocator, s: CFTypeRef) !?[]u8 {
    const max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    if (max <= 0) return null;

    const buf = try gpa.alloc(u8, @intCast(max));
    errdefer gpa.free(buf);
    if (!CFStringGetCString(s, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8)) {
        gpa.free(buf);
        return null;
    }
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return gpa.realloc(buf, len) catch buf[0..len];
}

/// The domain preferences are actually landing in, for `prefs:info`.
///
/// Bundle identifier inside a `.app`; the executable's name otherwise — which
/// is why two different dev-mode apps run through the same `craft` binary share
/// a domain, and why `info()` exists to make that visible instead of puzzling.
pub fn domainName(gpa: std.mem.Allocator) ![]u8 {
    if (comptime !is_macos) return gpa.dupe(u8, "unsupported");

    const bundle = CFBundleGetMainBundle();
    if (bundle != null) {
        const identifier = CFBundleGetIdentifier(bundle);
        if (identifier != null) {
            if (try copyCfString(gpa, identifier)) |owned| return owned;
        }
    }

    var size: u32 = 0;
    _ = _NSGetExecutablePath(undefined, &size);
    if (size == 0 or size > 8192) return gpa.dupe(u8, "craft");
    const path_buf = try gpa.alloc(u8, size);
    defer gpa.free(path_buf);
    if (_NSGetExecutablePath(path_buf.ptr, &size) != 0) return gpa.dupe(u8, "craft");
    const exe_path = std.mem.sliceTo(path_buf, 0);
    return gpa.dupe(u8, std.fs.path.basename(exe_path));
}

extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

// =============================================================================
// Tests
// =============================================================================
//
// These touch the real preferences daemon, so they run against a throwaway
// domain and remove every key they create. That is what `Domain.named` is for.

const testing = std.testing;
const test_domain = "dev.craft.prefs.selftest";

fn scratchBackend() Backend {
    return Backend.init(.{ .named = test_domain });
}

test "a value keeps its type through the preferences daemon" {
    if (comptime !is_macos) return error.SkipZigTest;

    var native = scratchBackend();
    defer native.deinit();
    const store = prefs.Store{ .backend = native.backend() };
    defer _ = store.clear(testing.allocator) catch {};

    // In-process, with no relaunch between the write and the read. That is the
    // load-bearing part: a plist round trip through a *fresh* process
    // normalises number types, so a test that relaunches passes even with a
    // wrong implementation, while craft's real read path is a long-running app
    // reading back what it just wrote.
    try store.set("aBool", .{ .boolean = true });
    try store.set("anInt", .{ .int = 42 });
    try store.set("aFloat", .{ .float = 1.5 });
    try store.set("aString", .{ .string = "dark" });

    const b = try store.get(testing.allocator, "aBool");
    try testing.expect(b.value.eql(.{ .boolean = true }));

    // The one that the usual `objCType == @encode(BOOL)` idiom gets wrong: a
    // stored boolean must not read back as the integer 1.
    try testing.expect(b.value != .int);

    const i = try store.get(testing.allocator, "anInt");
    try testing.expect(i.value.eql(.{ .int = 42 }));

    const f = try store.get(testing.allocator, "aFloat");
    try testing.expect(f.value.eql(.{ .float = 1.5 }));

    const s = try store.get(testing.allocator, "aString");
    defer testing.allocator.free(s.value.string);
    try testing.expectEqualStrings("dark", s.value.string);
}

test "delete removes the key, and reports whether it was there" {
    if (comptime !is_macos) return error.SkipZigTest;

    var native = scratchBackend();
    defer native.deinit();
    const store = prefs.Store{ .backend = native.backend() };
    defer _ = store.clear(testing.allocator) catch {};

    try store.set("goingAway", .{ .int = 1 });
    try testing.expect(try store.remove("goingAway"));
    try testing.expect(try store.get(testing.allocator, "goingAway") == .absent);
    try testing.expect(!try store.remove("goingAway"));
}

test "keys and clear see only craft's own keys in a shared domain" {
    if (comptime !is_macos) return error.SkipZigTest;

    var native = scratchBackend();
    defer native.deinit();
    const store = prefs.Store{ .backend = native.backend() };
    defer _ = store.clear(testing.allocator) catch {};

    try store.set("theme", .{ .string = "dark" });

    // What AppKit leaves in the same domain, written past the store so it has
    // no craft prefix.
    try native.backend().vtable.set(&native, "NSWindow Frame Selftest", .{ .string = "0 0 8 6" });
    defer _ = native.backend().vtable.remove(&native, "NSWindow Frame Selftest") catch false;

    const listed = try store.keys(testing.allocator);
    defer {
        for (listed) |k| testing.allocator.free(k);
        testing.allocator.free(listed);
    }
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("theme", listed[0]);

    try testing.expectEqual(@as(usize, 1), try store.clear(testing.allocator));

    const survivor = try native.backend().vtable.get(&native, testing.allocator, "NSWindow Frame Selftest");
    defer if (survivor == .value and survivor.value == .string) testing.allocator.free(survivor.value.string);
    try testing.expect(survivor == .value);
}

test "a value craft cannot represent is reported, not coerced" {
    if (comptime !is_macos) return error.SkipZigTest;

    var native = scratchBackend();
    defer native.deinit();

    // An array, which only something outside craft could have written.
    const key = cfString(prefs.prefix ++ "foreign").?;
    defer CFRelease(key);
    const one = cfString("a").?;
    defer CFRelease(one);
    var values = [_]CFTypeRef{one};
    const array = CFArrayCreate(null, &values, 1, null);
    defer CFRelease(array);

    const domain = cfString(test_domain).?;
    defer CFRelease(domain);
    CFPreferencesSetValue(key, array, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    defer CFPreferencesSetValue(key, null, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    const store = prefs.Store{ .backend = native.backend() };
    const read = try store.get(testing.allocator, "foreign");
    try testing.expect(read == .foreign);
    try testing.expectEqualStrings("CFArray", read.foreign.cf_type);
}

extern "c" fn CFArrayCreate(alloc: CFTypeRef, values: [*]const CFTypeRef, count: CFIndex, callbacks: ?*const anyopaque) CFTypeRef;

test "the reported domain is a real one" {
    if (comptime !is_macos) return error.SkipZigTest;

    const name = try domainName(testing.allocator);
    defer testing.allocator.free(name);
    try testing.expect(name.len > 0);
    // Unbundled, this is the executable's name — which is the whole reason
    // `prefs:info` reports it.
    try testing.expect(std.mem.indexOfScalar(u8, name, '/') == null);
}
