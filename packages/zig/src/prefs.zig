//! `window.craft.prefs` — a small preference store, minus the platform.
//!
//! Everything here is pure: key rules, the value model, the wire codec and the
//! read/write bookkeeping, over a `Backend` seam that a test can fill with a
//! hash map. The macOS half is `prefs_macos.zig`; the bridge adapter is
//! `bridge_prefs.zig`.
//!
//! **Scalars only — string, number, boolean.** That is not a corner cut, it is
//! what makes a whole class of crash unreachable. The preferences API raises
//! `NSInvalidArgumentException` for any value that is not a property-list type,
//! recursively, and Zig cannot catch an Objective-C exception — so a page that
//! passed `{fn: () => {}}` through a container-accepting bridge would take the
//! app down. With three scalar constructors there is no code path in craft that
//! *can* build a CFArray or CFDictionary out of page input. An app that needs
//! structure serialises it: `prefs.set(k, JSON.stringify(v))`.
//!
//! Every key craft owns is written under `prefix`, so `clear()` and `keys()`
//! cannot touch the AppKit and WebKit keys that share the same domain — a
//! dev-mode craft domain already holds `NSWindow Frame …` entries.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

/// Namespace for every key craft.prefs owns, inside a domain it shares with
/// AppKit, WebKit and the app itself.
pub const prefix = "craft.prefs.";

/// Longest key an app may use, before prefixing.
pub const max_key_len = 64;

/// Largest string value. Preferences are read into memory eagerly by the OS
/// and are the wrong place for documents; the refusal message says so and
/// names `craft.fs` instead.
pub const max_value_bytes = 8 * 1024;

pub const Error = error{
    InvalidKey,
    ValueTooLarge,
    UnsupportedValue,
    BackendFailure,
    OutOfMemory,
};

/// The only value types craft.prefs stores.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,

    pub fn eql(self: Value, other: Value) bool {
        return switch (self) {
            .string => |s| other == .string and std.mem.eql(u8, s, other.string),
            .int => |i| other == .int and i == other.int,
            .float => |f| other == .float and f == other.float,
            .boolean => |b| other == .boolean and b == other.boolean,
        };
    }
};

/// A value in the domain that craft cannot represent.
///
/// Only reachable by something outside craft writing the key — `defaults write
/// … -array`, a native settings pane, an older build. Reported as itself rather
/// than coerced, because silently turning an array into `undefined` is how an
/// app loses data without noticing.
pub const Foreign = struct {
    /// CoreFoundation's own name for the type, e.g. "CFArray".
    cf_type: []const u8,
    /// Set when the type was right but the value was too large to hand back.
    bytes: ?usize = null,
};

pub const Read = union(enum) {
    absent,
    value: Value,
    foreign: Foreign,
};

/// Where the values actually live.
///
/// Backends see **full** keys (`craft.prefs.theme`) and know nothing about the
/// prefix, the key rules or the wire format — all of that is tested up here,
/// against `MemoryBackend`, on any host.
pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// A returned `.value.string` is owned by `gpa`; the caller frees it.
        get: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, full_key: []const u8) Error!Read,
        set: *const fn (ctx: *anyopaque, full_key: []const u8, value: Value) Error!void,
        /// Returns whether the key was there to begin with.
        remove: *const fn (ctx: *anyopaque, full_key: []const u8) Error!bool,
        /// Every key in the domain, prefixed and unprefixed alike. The core
        /// filters, so a backend cannot accidentally hide one.
        keys: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) Error![][]u8,
        /// Flush to disk. Called once per mutating operation — not once per key.
        sync: *const fn (ctx: *anyopaque) Error!void,
    };
};

/// `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`
///
/// Narrow on purpose, and it pays for itself four times over: a leading `@`
/// can never reach a KVC path (`valueForKey:@"@sum"` throws); a key can never
/// contain a quote, backslash or control byte, so echoing it into reply JSON is
/// safe by construction; the bound sizes every buffer; and a key can never look
/// like a command-line flag.
pub fn validateKey(key: []const u8) Error!void {
    if (key.len == 0 or key.len > max_key_len) return Error.InvalidKey;
    if (!std.ascii.isAlphanumeric(key[0])) return Error.InvalidKey;
    for (key[1..]) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-';
        if (!ok) return Error.InvalidKey;
    }
}

pub const FullKeyBuf = [prefix.len + max_key_len]u8;

/// `theme` -> `craft.prefs.theme`, validating on the way.
pub fn fullKey(buf: *FullKeyBuf, key: []const u8) Error![]const u8 {
    try validateKey(key);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..key.len], key);
    return buf[0 .. prefix.len + key.len];
}

/// The app-visible key, or null if this key is not craft's.
pub fn stripPrefix(full: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, full, prefix)) return null;
    const rest = full[prefix.len..];
    if (rest.len == 0) return null;
    return rest;
}

pub fn validateValue(v: Value) Error!void {
    switch (v) {
        .string => |s| if (s.len > max_value_bytes) return Error.ValueTooLarge,
        // A non-finite double has no property-list representation: it would
        // round-trip through the plist as a corrupt number or fail the write.
        .float => |f| if (!std.math.isFinite(f)) return Error.UnsupportedValue,
        else => {},
    }
}

pub const Store = struct {
    backend: Backend,

    pub fn get(self: Store, gpa: std.mem.Allocator, key: []const u8) Error!Read {
        var buf: FullKeyBuf = undefined;
        const full = try fullKey(&buf, key);
        return self.backend.vtable.get(self.backend.ctx, gpa, full);
    }

    pub fn set(self: Store, key: []const u8, value: Value) Error!void {
        var buf: FullKeyBuf = undefined;
        const full = try fullKey(&buf, key);
        try validateValue(value);
        try self.backend.vtable.set(self.backend.ctx, full, value);
        try self.backend.vtable.sync(self.backend.ctx);
    }

    pub fn remove(self: Store, key: []const u8) Error!bool {
        var buf: FullKeyBuf = undefined;
        const full = try fullKey(&buf, key);
        const existed = try self.backend.vtable.remove(self.backend.ctx, full);
        try self.backend.vtable.sync(self.backend.ctx);
        return existed;
    }

    /// Every key the app has set, stripped of the prefix and sorted.
    ///
    /// Sorted so `keys()` is stable across launches: the backend's enumeration
    /// order is the preferences daemon's, which is not.
    pub fn keys(self: Store, gpa: std.mem.Allocator) Error![][]u8 {
        const all = try self.backend.vtable.keys(self.backend.ctx, gpa);
        defer {
            for (all) |k| gpa.free(k);
            gpa.free(all);
        }

        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |k| gpa.free(k);
            out.deinit(gpa);
        }

        for (all) |full| {
            const app_key = stripPrefix(full) orelse continue;
            const owned = gpa.dupe(u8, app_key) catch return Error.OutOfMemory;
            out.append(gpa, owned) catch {
                gpa.free(owned);
                return Error.OutOfMemory;
            };
        }

        const slice = out.toOwnedSlice(gpa) catch return Error.OutOfMemory;
        std.mem.sort([]u8, slice, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        return slice;
    }

    /// Remove every key craft owns, and only those.
    ///
    /// Not `removePersistentDomainForName:` or its CF equivalent: craft shares
    /// this domain with AppKit and WebKit, and a dev-mode domain demonstrably
    /// already holds `NSWindow Frame …` entries. Wiping it would throw away
    /// window positions and inspector state along with the app's preferences.
    pub fn clear(self: Store, gpa: std.mem.Allocator) Error!usize {
        const all = try self.backend.vtable.keys(self.backend.ctx, gpa);
        defer {
            for (all) |k| gpa.free(k);
            gpa.free(all);
        }

        var removed: usize = 0;
        for (all) |full| {
            if (stripPrefix(full) == null) continue;
            if (try self.backend.vtable.remove(self.backend.ctx, full)) removed += 1;
        }
        // Once, not once per key: a sync is a write to the preferences daemon.
        try self.backend.vtable.sync(self.backend.ctx);
        return removed;
    }
};

// =============================================================================
// The wire codec
// =============================================================================
//
// The type travels explicitly in both directions — `{"t":"i","i":42}`, never a
// bare `42` — so neither side has to infer, and a tag that disagrees with the
// field beside it is an error rather than a silent default. This is the half
// most likely to drift from craft-bridge.js, which is why it is tested against
// the real injected script in `test/injected_js_test.zig`.

/// `{"k":"theme","t":"s","s":"dark"}`
pub const SetShape = struct {
    k: []const u8 = "",
    t: []const u8 = "",
    s: ?[]const u8 = null,
    i: ?i64 = null,
    n: ?f64 = null,
    b: ?bool = null,
};

/// `{"k":"theme"}`
pub const KeyShape = struct {
    k: []const u8 = "",
};

pub const SetRequest = struct {
    key: []const u8,
    value: Value,
};

/// Turn a decoded payload into a key and a value, refusing any disagreement
/// between the tag and the fields carried beside it.
pub fn decodeSet(shape: SetShape) Error!SetRequest {
    try validateKey(shape.k);

    const value: Value = if (std.mem.eql(u8, shape.t, "s"))
        .{ .string = shape.s orelse return Error.UnsupportedValue }
    else if (std.mem.eql(u8, shape.t, "i"))
        .{ .int = shape.i orelse return Error.UnsupportedValue }
    else if (std.mem.eql(u8, shape.t, "d"))
        .{ .float = shape.n orelse return Error.UnsupportedValue }
    else if (std.mem.eql(u8, shape.t, "b"))
        .{ .boolean = shape.b orelse return Error.UnsupportedValue }
    else
        return Error.UnsupportedValue;

    try validateValue(value);
    return .{ .key = shape.k, .value = value };
}

/// The reply to `prefs:get`.
pub fn appendReadJson(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), r: Read) !void {
    switch (r) {
        .absent => try out.appendSlice(gpa, "{\"t\":\"none\"}"),
        .foreign => |f| {
            try out.appendSlice(gpa, "{\"t\":\"other\",\"cf\":\"");
            try bridge_error.appendJsonEscaped(gpa, out, f.cf_type);
            try out.appendSlice(gpa, "\"");
            if (f.bytes) |n| {
                const num = try std.fmt.allocPrint(gpa, ",\"bytes\":{d}", .{n});
                defer gpa.free(num);
                try out.appendSlice(gpa, num);
            }
            try out.appendSlice(gpa, "}");
        },
        .value => |v| switch (v) {
            .string => |s| {
                try out.appendSlice(gpa, "{\"t\":\"s\",\"s\":\"");
                try bridge_error.appendJsonEscaped(gpa, out, s);
                try out.appendSlice(gpa, "\"}");
            },
            .int => |i| {
                const text = try std.fmt.allocPrint(gpa, "{{\"t\":\"i\",\"i\":{d}}}", .{i});
                defer gpa.free(text);
                try out.appendSlice(gpa, text);
            },
            .float => |f| {
                const text = try std.fmt.allocPrint(gpa, "{{\"t\":\"d\",\"n\":{d}}}", .{f});
                defer gpa.free(text);
                try out.appendSlice(gpa, text);
            },
            .boolean => |b| try out.appendSlice(gpa, if (b)
                "{\"t\":\"b\",\"b\":true}"
            else
                "{\"t\":\"b\",\"b\":false}"),
        },
    }
}

/// The reply to `prefs:keys`.
pub fn appendKeysJson(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), key_list: []const []const u8) !void {
    try out.appendSlice(gpa, "{\"keys\":[");
    for (key_list, 0..) |k, index| {
        if (index > 0) try out.append(gpa, ',');
        try out.append(gpa, '"');
        // `validateKey` already rules out every byte JSON would need escaped,
        // but these come back from the preferences domain rather than from a
        // caller, so they are escaped anyway.
        try bridge_error.appendJsonEscaped(gpa, out, k);
        try out.append(gpa, '"');
    }
    try out.appendSlice(gpa, "]}");
}

// =============================================================================
// MemoryBackend
// =============================================================================

/// A backend in a hash map.
///
/// Not a production shim: it exists so every rule above is provable in
/// `zig build test` on a machine with no preferences daemon, and so the
/// sync-once-per-operation contract can be asserted with a counter.
pub const MemoryBackend = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Value) = .empty,
    syncs: usize = 0,

    pub fn init(gpa: std.mem.Allocator) MemoryBackend {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MemoryBackend) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            if (entry.value_ptr.* == .string) self.gpa.free(entry.value_ptr.string);
        }
        self.map.deinit(self.gpa);
    }

    pub fn backend(self: *MemoryBackend) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Backend.VTable{
        .get = getImpl,
        .set = setImpl,
        .remove = removeImpl,
        .keys = keysImpl,
        .sync = syncImpl,
    };

    fn self_(ctx: *anyopaque) *MemoryBackend {
        return @ptrCast(@alignCast(ctx));
    }

    fn getImpl(ctx: *anyopaque, gpa: std.mem.Allocator, full_key: []const u8) Error!Read {
        const me = self_(ctx);
        const found = me.map.get(full_key) orelse return .absent;
        return switch (found) {
            // Copied, because the caller owns and frees what it gets back —
            // the same contract the CoreFoundation backend has to honour.
            .string => |s| .{ .value = .{ .string = gpa.dupe(u8, s) catch return Error.OutOfMemory } },
            else => .{ .value = found },
        };
    }

    fn setImpl(ctx: *anyopaque, full_key: []const u8, value: Value) Error!void {
        const me = self_(ctx);
        const stored: Value = switch (value) {
            .string => |s| .{ .string = me.gpa.dupe(u8, s) catch return Error.OutOfMemory },
            else => value,
        };
        errdefer if (stored == .string) me.gpa.free(stored.string);

        if (me.map.getEntry(full_key)) |entry| {
            if (entry.value_ptr.* == .string) me.gpa.free(entry.value_ptr.string);
            entry.value_ptr.* = stored;
            return;
        }
        const owned_key = me.gpa.dupe(u8, full_key) catch return Error.OutOfMemory;
        errdefer me.gpa.free(owned_key);
        me.map.put(me.gpa, owned_key, stored) catch return Error.OutOfMemory;
    }

    fn removeImpl(ctx: *anyopaque, full_key: []const u8) Error!bool {
        const me = self_(ctx);
        const entry = me.map.fetchRemove(full_key) orelse return false;
        me.gpa.free(entry.key);
        if (entry.value == .string) me.gpa.free(entry.value.string);
        return true;
    }

    fn keysImpl(ctx: *anyopaque, gpa: std.mem.Allocator) Error![][]u8 {
        const me = self_(ctx);
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |k| gpa.free(k);
            out.deinit(gpa);
        }
        var it = me.map.keyIterator();
        while (it.next()) |k| {
            const owned = gpa.dupe(u8, k.*) catch return Error.OutOfMemory;
            out.append(gpa, owned) catch {
                gpa.free(owned);
                return Error.OutOfMemory;
            };
        }
        return out.toOwnedSlice(gpa) catch Error.OutOfMemory;
    }

    fn syncImpl(ctx: *anyopaque) Error!void {
        self_(ctx).syncs += 1;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn testStore(mem: *MemoryBackend) Store {
    return .{ .backend = mem.backend() };
}

test "keys are namespaced, so clear cannot touch what craft does not own" {
    var mem = MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = testStore(&mem);

    try store.set("theme", .{ .string = "dark" });
    // What AppKit and WebKit leave in the same domain. A dev-mode craft domain
    // really does hold entries like this.
    try mem.backend().vtable.set(&mem, "NSWindow Frame Main", .{ .string = "0 0 800 600" });

    try testing.expectEqual(@as(usize, 1), try store.clear(testing.allocator));

    const survivor = try mem.backend().vtable.get(&mem, testing.allocator, "NSWindow Frame Main");
    defer if (survivor == .value and survivor.value == .string) testing.allocator.free(survivor.value.string);
    try testing.expect(survivor == .value);
}

test "keys() reports app keys, stripped and sorted, and nothing else" {
    var mem = MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = testStore(&mem);

    try store.set("theme", .{ .string = "dark" });
    try store.set("fontSize", .{ .int = 13 });
    try mem.backend().vtable.set(&mem, "NSWindow Frame Main", .{ .string = "x" });

    const listed = try store.keys(testing.allocator);
    defer {
        for (listed) |k| testing.allocator.free(k);
        testing.allocator.free(listed);
    }
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("fontSize", listed[0]);
    try testing.expectEqualStrings("theme", listed[1]);
}

test "a clear syncs once, not once per key" {
    // A sync is a round trip to the preferences daemon. Doing one per key turns
    // clearing twenty preferences into twenty flushes.
    var mem = MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = testStore(&mem);

    try store.set("a", .{ .int = 1 });
    try store.set("b", .{ .int = 2 });
    try store.set("c", .{ .int = 3 });
    const before = mem.syncs;
    _ = try store.clear(testing.allocator);
    try testing.expectEqual(before + 1, mem.syncs);
}

test "every mutating call flushes before it returns" {
    // A resolved set() has to mean the bytes are on disk: craft's hot reload
    // kills the process abruptly, and an unflushed preference is a lost one.
    var mem = MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = testStore(&mem);

    try store.set("a", .{ .int = 1 });
    try testing.expectEqual(@as(usize, 1), mem.syncs);
    _ = try store.remove("a");
    try testing.expectEqual(@as(usize, 2), mem.syncs);
}

test "reading gives back an owned copy the caller frees" {
    // The whole suite runs under the testing allocator, so a backend that
    // handed out a borrowed slice — the bug storage.zig:266 shipped — would
    // show up as a leak or a use-after-free rather than as nothing.
    var mem = MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = testStore(&mem);

    try store.set("theme", .{ .string = "dark" });
    const read = try store.get(testing.allocator, "theme");
    defer testing.allocator.free(read.value.string);
    try testing.expectEqualStrings("dark", read.value.string);
}

test "an absent key is absent, not empty" {
    var mem = MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = testStore(&mem);

    try testing.expect(try store.get(testing.allocator, "nothing") == .absent);
    try testing.expect(!try store.remove("nothing"));
}

test "setting a key twice replaces rather than accumulating" {
    var mem = MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = testStore(&mem);

    try store.set("theme", .{ .string = "dark" });
    try store.set("theme", .{ .string = "light" });
    try store.set("theme", .{ .int = 3 });

    const read = try store.get(testing.allocator, "theme");
    try testing.expect(read.value.eql(.{ .int = 3 }));

    const listed = try store.keys(testing.allocator);
    defer {
        for (listed) |k| testing.allocator.free(k);
        testing.allocator.free(listed);
    }
    try testing.expectEqual(@as(usize, 1), listed.len);
}

test "key rules" {
    try validateKey("a");
    try validateKey("theme");
    try validateKey("window.main.width");
    try validateKey("font-size_2");
    try validateKey("0");

    try testing.expectError(Error.InvalidKey, validateKey(""));
    // A leading `@` would reach a KVC path: `valueForKey:@"@sum"` throws.
    try testing.expectError(Error.InvalidKey, validateKey("@media"));
    try testing.expectError(Error.InvalidKey, validateKey("-leading"));
    try testing.expectError(Error.InvalidKey, validateKey(".leading"));
    try testing.expectError(Error.InvalidKey, validateKey("has space"));
    try testing.expectError(Error.InvalidKey, validateKey("has\"quote"));
    try testing.expectError(Error.InvalidKey, validateKey("has\\backslash"));
    try testing.expectError(Error.InvalidKey, validateKey("has\nnewline"));
    try testing.expectError(Error.InvalidKey, validateKey("has\x00nul"));
    var long_key: [max_key_len + 1]u8 = undefined;
    @memset(&long_key, 'a');
    try testing.expectError(Error.InvalidKey, validateKey(&long_key));
    try validateKey(long_key[0..max_key_len]);
}

test "a key can never be mistaken for a command-line flag" {
    // Not decorative. The convenience preferences API reads argv as a domain:
    // `craft -theme dark` makes CFPreferencesCopyAppValue("theme") return
    // "dark". craft.prefs reads the exact domain instead, and the key rules
    // are the second lock on that door.
    try testing.expectError(Error.InvalidKey, validateKey("-theme"));
    try testing.expectError(Error.InvalidKey, validateKey("--theme"));
}

test "the prefix round-trips and is the only thing stripPrefix accepts" {
    var buf: FullKeyBuf = undefined;
    try testing.expectEqualStrings("craft.prefs.theme", try fullKey(&buf, "theme"));
    try testing.expectEqualStrings("theme", stripPrefix("craft.prefs.theme").?);

    try testing.expect(stripPrefix("theme") == null);
    try testing.expect(stripPrefix("NSWindow Frame Main") == null);
    // The bare prefix names no key.
    try testing.expect(stripPrefix(prefix) == null);
    try testing.expect(stripPrefix("craft.prefs") == null);
}

test "an invalid key is refused before it reaches the backend" {
    var mem = MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = testStore(&mem);

    try testing.expectError(Error.InvalidKey, store.set("has space", .{ .int = 1 }));
    try testing.expectError(Error.InvalidKey, store.get(testing.allocator, "@media"));
    try testing.expectError(Error.InvalidKey, store.remove(""));
    try testing.expectEqual(@as(usize, 0), mem.syncs);
}

test "value limits" {
    const big = try testing.allocator.alloc(u8, max_value_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try testing.expectError(Error.ValueTooLarge, validateValue(.{ .string = big }));
    try validateValue(.{ .string = big[0..max_value_bytes] });

    try testing.expectError(Error.UnsupportedValue, validateValue(.{ .float = std.math.inf(f64) }));
    try testing.expectError(Error.UnsupportedValue, validateValue(.{ .float = std.math.nan(f64) }));
    try validateValue(.{ .float = 1.5 });
    try validateValue(.{ .int = std.math.maxInt(i64) });
}

test "decodeSet refuses a tag that disagrees with the fields beside it" {
    try testing.expect((try decodeSet(.{ .k = "a", .t = "s", .s = "x" })).value.eql(.{ .string = "x" }));
    try testing.expect((try decodeSet(.{ .k = "a", .t = "i", .i = 42 })).value.eql(.{ .int = 42 }));
    try testing.expect((try decodeSet(.{ .k = "a", .t = "d", .n = 1.5 })).value.eql(.{ .float = 1.5 }));
    try testing.expect((try decodeSet(.{ .k = "a", .t = "b", .b = true })).value.eql(.{ .boolean = true }));

    // A tag with nothing behind it would otherwise decode to a zero value —
    // `{"t":"i"}` silently becoming 0 is the failure this rules out.
    try testing.expectError(Error.UnsupportedValue, decodeSet(.{ .k = "a", .t = "i" }));
    try testing.expectError(Error.UnsupportedValue, decodeSet(.{ .k = "a", .t = "s" }));
    try testing.expectError(Error.UnsupportedValue, decodeSet(.{ .k = "a", .t = "b" }));
    // A tag carrying the wrong field is the same mistake wearing a hat.
    try testing.expectError(Error.UnsupportedValue, decodeSet(.{ .k = "a", .t = "s", .b = true }));
    try testing.expectError(Error.UnsupportedValue, decodeSet(.{ .k = "a", .t = "q", .i = 1 }));
    try testing.expectError(Error.UnsupportedValue, decodeSet(.{ .k = "a", .t = "", .i = 1 }));
    // And the key is still checked.
    try testing.expectError(Error.InvalidKey, decodeSet(.{ .k = "has space", .t = "i", .i = 1 }));
}

fn readJson(r: Read) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try appendReadJson(testing.allocator, &out, r);
    return out.toOwnedSlice(testing.allocator);
}

test "the get reply names its own type" {
    const cases = [_]struct { r: Read, want: []const u8 }{
        .{ .r = .absent, .want = "{\"t\":\"none\"}" },
        .{ .r = .{ .value = .{ .boolean = true } }, .want = "{\"t\":\"b\",\"b\":true}" },
        .{ .r = .{ .value = .{ .boolean = false } }, .want = "{\"t\":\"b\",\"b\":false}" },
        .{ .r = .{ .value = .{ .int = 42 } }, .want = "{\"t\":\"i\",\"i\":42}" },
        .{ .r = .{ .value = .{ .int = -7 } }, .want = "{\"t\":\"i\",\"i\":-7}" },
        .{ .r = .{ .value = .{ .float = 1.5 } }, .want = "{\"t\":\"d\",\"n\":1.5}" },
        .{ .r = .{ .value = .{ .string = "dark" } }, .want = "{\"t\":\"s\",\"s\":\"dark\"}" },
        .{ .r = .{ .foreign = .{ .cf_type = "CFArray" } }, .want = "{\"t\":\"other\",\"cf\":\"CFArray\"}" },
        .{ .r = .{ .foreign = .{ .cf_type = "CFString", .bytes = 99 } }, .want = "{\"t\":\"other\",\"cf\":\"CFString\",\"bytes\":99}" },
    };
    for (cases) |c| {
        const json = try readJson(c.r);
        defer testing.allocator.free(json);
        try testing.expectEqualStrings(c.want, json);
    }
}

test "a stored value cannot break out of the reply it is delivered in" {
    const nasty = "a\"b\\c\nd\te\x00f\x1fg";
    const json = try readJson(.{ .value = .{ .string = nasty } });
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(nasty, parsed.value.object.get("s").?.string);
}

test "the keys reply is a JSON array" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendKeysJson(testing.allocator, &out, &.{});
    try testing.expectEqualStrings("{\"keys\":[]}", out.items);

    out.clearRetainingCapacity();
    try appendKeysJson(testing.allocator, &out, &.{ "fontSize", "theme" });
    try testing.expectEqualStrings("{\"keys\":[\"fontSize\",\"theme\"]}", out.items);
}

test "a whole round trip through the store keeps every scalar type" {
    var mem = MemoryBackend.init(testing.allocator);
    defer mem.deinit();
    const store = testStore(&mem);

    const cases = [_]struct { key: []const u8, value: Value }{
        .{ .key = "s", .value = .{ .string = "dark" } },
        .{ .key = "i", .value = .{ .int = -42 } },
        .{ .key = "d", .value = .{ .float = 1.5 } },
        .{ .key = "b", .value = .{ .boolean = true } },
    };
    for (cases) |c| try store.set(c.key, c.value);
    for (cases) |c| {
        const read = try store.get(testing.allocator, c.key);
        defer if (read == .value and read.value == .string) testing.allocator.free(read.value.string);
        // A boolean must not come back as 1, and an int must not come back as
        // 1.0 — which is exactly what a store that inferred types would do.
        try testing.expect(read == .value);
        try testing.expect(read.value.eql(c.value));
    }
}
