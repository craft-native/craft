//! The set of global shortcuts an app has asked for, and what craft did about
//! each one.
//!
//! Separated from `bridge_shortcuts.zig` so that the whole lifecycle —
//! register, replace, disable, re-enable, unregister — can be tested against a
//! fake platform, without an app, a window or a key press. The bug this exists
//! to close (craft-native/craft#47) survived because the only thing that could
//! have caught it was pressing the key on a real Mac.
//!
//! The registry owns the bookkeeping and the JSON on both sides of it. Actually
//! reserving a key with the system is the one thing it delegates, through
//! `Platform`.

const std = @import("std");
const accel = @import("accelerator.zig");
const key_codes = @import("key_codes.zig");
const bridge_error = @import("bridge_error.zig");

const BridgeError = bridge_error.BridgeError;

/// The `a` field of a `shortcuts` bridge message. Shared constants rather than
/// literals on each side: a wrong action name is not an error on the native
/// side, only a log line, so a rename would otherwise silently stop a whole
/// verb working.
pub const action_register = "register";
pub const action_unregister = "unregister";
pub const action_unregister_all = "unregisterAll";
pub const action_enable = "enable";
pub const action_disable = "disable";
pub const action_is_registered = "isRegistered";
pub const action_list = "list";

/// An opaque handle from the platform, held so a reservation can be released.
pub const Ref = ?*anyopaque;

/// How the registry reserves a key with the operating system.
///
/// `register` returns null when the combination is unavailable — already taken
/// by another app, or by the system. That is an ordinary outcome, not a
/// failure of craft's, and it has to reach the app: the user must pick a
/// different key.
pub const Platform = struct {
    register: *const fn (keycode: u16, carbon_modifiers: u32, hotkey_id: u32) Ref,
    unregister: *const fn (ref: Ref) void,
};

/// A platform that reserves nothing. Used where global hotkeys have no
/// implementation, so `register` reports honestly instead of accepting a
/// shortcut that could never fire.
pub const unsupported_platform = Platform{
    .register = struct {
        fn f(_: u16, _: u32, _: u32) Ref {
            return null;
        }
    }.f,
    .unregister = struct {
        fn f(_: Ref) void {}
    }.f,
};

pub const Registration = struct {
    /// App-chosen identifier. Owned.
    id: []const u8,
    /// Canonical accelerator — what `format` renders, not necessarily the
    /// spelling that arrived. Owned.
    accelerator: []const u8,
    binding: accel.Binding,
    /// Identifier handed to the platform, and the only thing that comes back
    /// when the key is pressed.
    hotkey_id: u32,
    /// Null exactly when the key is not currently reserved — i.e. when the
    /// shortcut is disabled.
    ref: Ref = null,
    enabled: bool = true,
};

/// The payload `shortcuts.register` accepts.
///
/// `accelerator` is what the JS bridge sends. `key` + `modifiers` is the older
/// shape the SDK's message tests document; both are accepted so neither
/// caller has to change to get a shortcut that works.
const RegisterPayload = struct {
    id: []const u8 = "",
    accelerator: ?[]const u8 = null,
    key: ?[]const u8 = null,
    modifiers: ?PayloadModifiers = null,

    const PayloadModifiers = struct {
        cmd: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        shift: bool = false,
        /// Web keyboard events spell command `metaKey`.
        meta: bool = false,
    };
};

/// A payload naming only an id: unregister, enable, disable, isRegistered.
const IdPayload = struct {
    id: []const u8 = "",
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Registration) = .empty,
    platform: Platform,
    next_hotkey_id: u32 = 1,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, platform: Platform) Self {
        return .{ .allocator = allocator, .platform = platform };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*entry| {
            self.platform.unregister(entry.ref);
            self.allocator.free(entry.id);
            self.allocator.free(entry.accelerator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    /// The entry for `id`, or null.
    ///
    /// The pointer is into the backing array and is invalidated by any
    /// subsequent `register`, so callers must finish with it before the next
    /// one.
    pub fn find(self: *Self, id: []const u8) ?*Registration {
        const index = self.findIndex(id) orelse return null;
        return &self.entries.items[index];
    }

    fn findIndex(self: *const Self, id: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, id)) return index;
        }
        return null;
    }

    /// The shortcut a pressed hotkey belongs to, or null if the id is stale —
    /// which can happen for a key released between the press and its delivery.
    pub fn findByHotkeyId(self: *Self, hotkey_id: u32) ?*Registration {
        for (self.entries.items) |*entry| {
            if (entry.hotkey_id == hotkey_id) return entry;
        }
        return null;
    }

    /// Register the shortcut described by `data`, replacing any shortcut
    /// already using the same id.
    ///
    /// Returns the registration on success. The errors are all things the app
    /// needs to hear about, and every one of them used to be a silent success.
    pub fn register(self: *Self, data: []const u8) BridgeError!*Registration {
        const parsed = std.json.parseFromSlice(RegisterPayload, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();

        const payload = parsed.value;
        if (payload.id.len == 0) return BridgeError.MissingData;

        const binding = try bindingFor(payload);

        var rendered: [96]u8 = undefined;
        const canonical = accel.format(&rendered, binding) catch return BridgeError.InvalidParameter;

        // Registering over an existing id replaces it, and the old entry goes
        // first — reservation included. Two reasons, both load-bearing:
        // re-registering the *same* accelerator would otherwise fail against
        // craft's own outstanding reservation, and a reservation dropped on
        // the floor keeps that key dead system-wide for the life of the
        // process with nothing left pointing at it to release it.
        if (self.findIndex(payload.id)) |index| self.forget(index);

        const id_owned = self.allocator.dupe(u8, payload.id) catch return BridgeError.AllocationFailed;
        errdefer self.allocator.free(id_owned);
        const accel_owned = self.allocator.dupe(u8, canonical) catch return BridgeError.AllocationFailed;
        errdefer self.allocator.free(accel_owned);

        const hotkey_id = self.next_hotkey_id;
        const ref = self.platform.register(binding.keycode, binding.modifiers.toCarbonFlags(), hotkey_id);
        // A shortcut nobody can trigger is worse than a failed registration:
        // the app believes it has a hotkey and waits forever.
        if (ref == null) return BridgeError.NativeCallFailed;
        self.next_hotkey_id += 1;
        errdefer self.platform.unregister(ref);

        self.entries.append(self.allocator, .{
            .id = id_owned,
            .accelerator = accel_owned,
            .binding = binding,
            .hotkey_id = hotkey_id,
            .ref = ref,
        }) catch return BridgeError.AllocationFailed;
        return &self.entries.items[self.entries.items.len - 1];
    }

    /// Release the entry's reservation and drop it from the registry.
    fn forget(self: *Self, index: usize) void {
        const entry = &self.entries.items[index];
        self.release(entry);
        self.allocator.free(entry.id);
        self.allocator.free(entry.accelerator);
        _ = self.entries.orderedRemove(index);
    }

    /// Release the system reservation, leaving the entry in place. Idempotent.
    fn release(self: *Self, entry: *Registration) void {
        if (entry.ref == null) return;
        self.platform.unregister(entry.ref);
        entry.ref = null;
    }

    pub fn unregister(self: *Self, data: []const u8) BridgeError!void {
        const id = try self.idFrom(data);
        defer self.allocator.free(id);

        const index = self.findIndex(id) orelse return BridgeError.NotFound;
        self.forget(index);
    }

    pub fn unregisterAll(self: *Self) void {
        for (self.entries.items) |*entry| {
            self.release(entry);
            self.allocator.free(entry.id);
            self.allocator.free(entry.accelerator);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Enable or disable a shortcut.
    ///
    /// Disabling gives the key back to the rest of the system rather than
    /// holding the reservation and dropping the event: a disabled shortcut
    /// that still swallowed its key would make that combination dead in every
    /// other app for as long as craft ran.
    pub fn setEnabled(self: *Self, data: []const u8, enabled: bool) BridgeError!void {
        const id = try self.idFrom(data);
        defer self.allocator.free(id);

        const entry = self.find(id) orelse return BridgeError.NotFound;
        if (entry.enabled == enabled) return;
        entry.enabled = enabled;

        if (!enabled) {
            self.release(entry);
            return;
        }

        const ref = self.platform.register(
            entry.binding.keycode,
            entry.binding.modifiers.toCarbonFlags(),
            entry.hotkey_id,
        );
        if (ref == null) {
            // Someone else claimed the key while it was released. The app
            // asked for it back and cannot have it.
            entry.enabled = false;
            return BridgeError.NativeCallFailed;
        }
        entry.ref = ref;
    }

    pub fn isRegistered(self: *Self, data: []const u8) BridgeError!bool {
        const id = try self.idFrom(data);
        defer self.allocator.free(id);
        return self.find(id) != null;
    }

    /// `{"value":true}` — the shape `_req('shortcuts','isRegistered')` reads.
    pub fn isRegisteredJson(self: *Self, data: []const u8) BridgeError![]u8 {
        const registered = try self.isRegistered(data);
        return std.fmt.allocPrint(self.allocator, "{{\"value\":{}}}", .{registered}) catch
            BridgeError.AllocationFailed;
    }

    /// `{"shortcuts":[…]}` — the shape `_req('shortcuts','list')` reads.
    ///
    /// Caller frees.
    pub fn listJson(self: *Self) BridgeError![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        out.appendSlice(self.allocator, "{\"shortcuts\":[") catch return BridgeError.AllocationFailed;
        for (self.entries.items, 0..) |entry, index| {
            if (index > 0) out.append(self.allocator, ',') catch return BridgeError.AllocationFailed;

            // Ids come from app code and can contain anything. Interpolating
            // one unescaped produces either broken JSON or an injection.
            const id_escaped = try escapeId(self.allocator, entry.id);
            defer self.allocator.free(id_escaped);

            // `accelerator` and `key` need no escaping: both are craft's own
            // canonical spellings, out of a fixed table, never app input.
            const item = std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":\"{s}\",\"accelerator\":\"{s}\",\"key\":\"{s}\",\"enabled\":{}}}",
                .{ id_escaped, entry.accelerator, entry.binding.key, entry.enabled },
            ) catch return BridgeError.AllocationFailed;
            defer self.allocator.free(item);
            out.appendSlice(self.allocator, item) catch return BridgeError.AllocationFailed;
        }
        out.appendSlice(self.allocator, "]}") catch return BridgeError.AllocationFailed;

        return out.toOwnedSlice(self.allocator) catch BridgeError.AllocationFailed;
    }

    /// Copy the `id` out of a `{"id":"…"}` payload. Copied because the JSON
    /// arena it was parsed into does not outlive the call.
    fn idFrom(self: *Self, data: []const u8) BridgeError![]u8 {
        const parsed = std.json.parseFromSlice(IdPayload, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();

        if (parsed.value.id.len == 0) return BridgeError.MissingData;
        return self.allocator.dupe(u8, parsed.value.id) catch BridgeError.AllocationFailed;
    }
};

/// The `detail` of the event a triggered shortcut is delivered as.
///
/// Built as JSON and embedded straight into the script: JSON object syntax is
/// a subset of JavaScript's, so escaping once as JSON escapes it for the
/// script too. That matters because shortcut ids come from app code, and an
/// unescaped quote in one is an injection into every craft window.
pub fn triggeredDetail(allocator: std.mem.Allocator, id: []const u8, accelerator: []const u8) BridgeError![]u8 {
    const escaped = try escapeId(allocator, id);
    defer allocator.free(escaped);
    // `accelerator` is craft's own canonical spelling, out of a fixed table,
    // and never app input.
    return std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"accelerator\":\"{s}\"}}", .{ escaped, accelerator }) catch
        BridgeError.AllocationFailed;
}

/// The `detail` of the event a refused registration is reported as.
pub fn errorDetail(allocator: std.mem.Allocator, id: []const u8, code: []const u8, message: []const u8) BridgeError![]u8 {
    const escaped = try escapeId(allocator, id);
    defer allocator.free(escaped);
    // `code` and `message` are compile-time constants from `bridge_error`.
    return std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"code\":\"{s}\",\"message\":\"{s}\"}}", .{ escaped, code, message }) catch
        BridgeError.AllocationFailed;
}

/// Wrap a detail object in the `dispatchEvent` call that delivers it.
pub fn eventScript(allocator: std.mem.Allocator, name: []const u8, detail_json: []const u8) BridgeError![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "if(window.dispatchEvent)window.dispatchEvent(new CustomEvent('{s}',{{detail:{s}}}));",
        .{ name, detail_json },
    ) catch BridgeError.AllocationFailed;
}

/// Six bytes is the worst case per input byte (`\u001f`), plus a terminator.
fn escapeId(allocator: std.mem.Allocator, id: []const u8) BridgeError![]u8 {
    const buf = allocator.alloc(u8, id.len * 6 + 1) catch return BridgeError.AllocationFailed;
    errdefer allocator.free(buf);
    const escaped = bridge_error.escapeJsonString(buf, id) catch return BridgeError.InvalidParameter;
    return allocator.realloc(buf, escaped.len) catch buf[0..escaped.len];
}

/// Resolve whichever of the two accepted payload shapes arrived into a binding.
fn bindingFor(payload: RegisterPayload) BridgeError!accel.Binding {
    if (payload.accelerator) |text| {
        return accel.parse(text) catch |err| return translate(err);
    }

    const key = payload.key orelse return BridgeError.MissingData;
    const mods = payload.modifiers orelse RegisterPayload.PayloadModifiers{};
    const resolved = accel.Modifiers{
        .cmd = mods.cmd or mods.meta,
        .ctrl = mods.ctrl,
        .alt = mods.alt,
        .shift = mods.shift,
    };
    const keycode = key_codes.codeFor(key) orelse return BridgeError.InvalidParameter;
    const canonical = key_codes.nameFor(keycode).?;

    // The same guard `accel.parse` applies, for the same reason: a global
    // hotkey with no commanding modifier takes the key away system-wide.
    var probe: [96]u8 = undefined;
    const rendered = accel.format(&probe, .{
        .key = canonical,
        .keycode = keycode,
        .modifiers = resolved,
    }) catch return BridgeError.InvalidParameter;
    return accel.parse(rendered) catch |err| return translate(err);
}

fn translate(err: accel.ParseError) BridgeError {
    return switch (err) {
        error.MissingKey, error.EmptyComponent => BridgeError.MissingData,
        error.UnknownKey, error.UnknownModifier, error.DuplicateModifier => BridgeError.InvalidParameter,
        error.ModifierRequired => BridgeError.InvalidParameter,
    };
}

// =============================================================================
// Tests
// =============================================================================

/// A platform that hands out increasing fake refs and records every call, so
/// tests can assert on what the system was actually asked to reserve.
const FakePlatform = struct {
    var registrations: usize = 0;
    var releases: usize = 0;
    var last_keycode: u16 = 0;
    var last_modifiers: u32 = 0;
    var next_ref: usize = 0;
    /// When set, `register` refuses — standing in for a key another app owns.
    var refuse: bool = false;

    fn reset() void {
        registrations = 0;
        releases = 0;
        last_keycode = 0;
        last_modifiers = 0;
        next_ref = 0;
        refuse = false;
    }

    fn register(keycode: u16, modifiers: u32, _: u32) Ref {
        if (refuse) return null;
        registrations += 1;
        last_keycode = keycode;
        last_modifiers = modifiers;
        next_ref += 1;
        return @ptrFromInt(next_ref);
    }

    fn unregister(ref: Ref) void {
        if (ref != null) releases += 1;
    }

    fn platform() Platform {
        return .{ .register = register, .unregister = unregister };
    }
};

fn testRegistry() Registry {
    FakePlatform.reset();
    return Registry.init(std.testing.allocator, FakePlatform.platform());
}

test "registering reserves the key the accelerator names" {
    var registry = testRegistry();
    defer registry.deinit();

    const entry = try registry.register(
        \\{"id":"harness.summon","accelerator":"Cmd+Shift+H"}
    );
    try std.testing.expectEqualStrings("harness.summon", entry.id);
    try std.testing.expectEqualStrings("Cmd+Shift+H", entry.accelerator);
    try std.testing.expectEqual(@as(usize, 1), FakePlatform.registrations);
    try std.testing.expectEqual(@as(u16, 0x04), FakePlatform.last_keycode);
    try std.testing.expectEqual(@as(u32, 0x0100 | 0x0200), FakePlatform.last_modifiers);
    try std.testing.expect(entry.ref != null);
}

test "a key the system will not give up is reported, not accepted" {
    var registry = testRegistry();
    defer registry.deinit();

    FakePlatform.refuse = true;
    try std.testing.expectError(
        BridgeError.NativeCallFailed,
        registry.register(
            \\{"id":"spotlight","accelerator":"Cmd+Space"}
        ),
    );
    // Nothing is left behind claiming to be registered.
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expect(!try registry.isRegistered(
        \\{"id":"spotlight"}
    ));
}

test "re-registering an id releases the key it used to hold" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );
    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+J"}
    );

    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqual(@as(usize, 2), FakePlatform.registrations);
    // The old reservation must be handed back. Leaking it would keep
    // Cmd+Shift+H dead system-wide with nothing left to release it.
    try std.testing.expectEqual(@as(usize, 1), FakePlatform.releases);
    try std.testing.expectEqualStrings("Cmd+Shift+J", registry.find("toggle").?.accelerator);
}

test "disabling gives the key back to the rest of the system" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );
    try registry.setEnabled(
        \\{"id":"toggle"}
    , false);

    try std.testing.expectEqual(@as(usize, 1), FakePlatform.releases);
    try std.testing.expect(registry.find("toggle").?.ref == null);
    try std.testing.expect(!registry.find("toggle").?.enabled);
    // Still listed: disabled is not unregistered.
    try std.testing.expect(try registry.isRegistered(
        \\{"id":"toggle"}
    ));
}

test "re-enabling takes the key back" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );
    try registry.setEnabled(
        \\{"id":"toggle"}
    , false);
    try registry.setEnabled(
        \\{"id":"toggle"}
    , true);

    try std.testing.expectEqual(@as(usize, 2), FakePlatform.registrations);
    try std.testing.expect(registry.find("toggle").?.ref != null);
    try std.testing.expect(registry.find("toggle").?.enabled);
}

test "re-enabling a key someone else took in the meantime fails loudly" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );
    try registry.setEnabled(
        \\{"id":"toggle"}
    , false);

    FakePlatform.refuse = true;
    try std.testing.expectError(BridgeError.NativeCallFailed, registry.setEnabled(
        \\{"id":"toggle"}
    , true));
    // And it stays disabled rather than claiming to be on with no reservation.
    try std.testing.expect(!registry.find("toggle").?.enabled);
    try std.testing.expect(registry.find("toggle").?.ref == null);
}

test "enabling something already enabled does not double-reserve" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );
    try registry.setEnabled(
        \\{"id":"toggle"}
    , true);
    try std.testing.expectEqual(@as(usize, 1), FakePlatform.registrations);
}

test "unregistering releases the key and forgets the shortcut" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );
    try registry.unregister(
        \\{"id":"toggle"}
    );
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectEqual(@as(usize, 1), FakePlatform.releases);
    try std.testing.expectError(BridgeError.NotFound, registry.unregister(
        \\{"id":"toggle"}
    ));
}

test "unregisterAll releases every reservation" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"a","accelerator":"Cmd+Shift+A"}
    );
    _ = try registry.register(
        \\{"id":"b","accelerator":"Cmd+Shift+B"}
    );
    _ = try registry.register(
        \\{"id":"c","accelerator":"Cmd+Shift+C"}
    );
    registry.unregisterAll();

    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectEqual(@as(usize, 3), FakePlatform.releases);
}

test "a disabled shortcut is released once, not twice" {
    // Double-releasing an already-freed EventHotKeyRef is a use-after-free
    // against Carbon's own table.
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );
    try registry.setEnabled(
        \\{"id":"toggle"}
    , false);
    registry.unregisterAll();
    try std.testing.expectEqual(@as(usize, 1), FakePlatform.releases);
}

test "each shortcut gets its own hotkey id" {
    var registry = testRegistry();
    defer registry.deinit();

    const a = try registry.register(
        \\{"id":"a","accelerator":"Cmd+Shift+A"}
    );
    const first_id = a.hotkey_id;
    const b = try registry.register(
        \\{"id":"b","accelerator":"Cmd+Shift+B"}
    );
    try std.testing.expect(first_id != b.hotkey_id);
    try std.testing.expectEqualStrings("b", registry.findByHotkeyId(b.hotkey_id).?.id);
    try std.testing.expect(registry.findByHotkeyId(9999) == null);
}

test "a pressed hotkey still resolves after other shortcuts are removed" {
    // `findByHotkeyId` used to be an index into a list; removing an earlier
    // entry would then deliver the wrong shortcut's callback.
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"first","accelerator":"Cmd+Shift+A"}
    );
    const second = try registry.register(
        \\{"id":"second","accelerator":"Cmd+Shift+B"}
    );
    const second_hotkey = second.hotkey_id;

    try registry.unregister(
        \\{"id":"first"}
    );
    try std.testing.expectEqualStrings("second", registry.findByHotkeyId(second_hotkey).?.id);
}

test "the legacy key + modifiers payload still registers" {
    var registry = testRegistry();
    defer registry.deinit();

    const entry = try registry.register(
        \\{"id":"toggle","key":"Space","modifiers":{"cmd":true,"shift":true},"callback":"onToggle"}
    );
    try std.testing.expectEqualStrings("Cmd+Shift+Space", entry.accelerator);
    try std.testing.expectEqual(key_codes.codeFor("Space").?, FakePlatform.last_keycode);
}

test "metaKey is command" {
    var registry = testRegistry();
    defer registry.deinit();

    const entry = try registry.register(
        \\{"id":"toggle","key":"K","modifiers":{"meta":true}}
    );
    try std.testing.expectEqualStrings("Cmd+K", entry.accelerator);
}

test "the legacy shape gets the same bare-key guard" {
    var registry = testRegistry();
    defer registry.deinit();

    try std.testing.expectError(BridgeError.InvalidParameter, registry.register(
        \\{"id":"toggle","key":"H"}
    ));
    try std.testing.expectEqual(@as(usize, 0), FakePlatform.registrations);
}

test "bad payloads are refused without reserving anything" {
    var registry = testRegistry();
    defer registry.deinit();

    try std.testing.expectError(BridgeError.InvalidJSON, registry.register("not json"));
    try std.testing.expectError(BridgeError.MissingData, registry.register(
        \\{"accelerator":"Cmd+Shift+H"}
    ));
    try std.testing.expectError(BridgeError.MissingData, registry.register(
        \\{"id":"x"}
    ));
    try std.testing.expectError(BridgeError.InvalidParameter, registry.register(
        \\{"id":"x","accelerator":"Cmd+Nonsense"}
    ));
    try std.testing.expectError(BridgeError.InvalidParameter, registry.register(
        \\{"id":"x","accelerator":"H"}
    ));
    try std.testing.expectEqual(@as(usize, 0), FakePlatform.registrations);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "actions naming an unknown id say so" {
    var registry = testRegistry();
    defer registry.deinit();

    try std.testing.expectError(BridgeError.NotFound, registry.unregister(
        \\{"id":"nope"}
    ));
    try std.testing.expectError(BridgeError.NotFound, registry.setEnabled(
        \\{"id":"nope"}
    , false));
    try std.testing.expectError(BridgeError.MissingData, registry.unregister(
        \\{}
    ));
}

test "isRegistered answers in the shape the JS bridge reads" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );

    const yes = try registry.isRegisteredJson(
        \\{"id":"toggle"}
    );
    defer std.testing.allocator.free(yes);
    try std.testing.expectEqualStrings("{\"value\":true}", yes);

    const no = try registry.isRegisteredJson(
        \\{"id":"other"}
    );
    defer std.testing.allocator.free(no);
    try std.testing.expectEqualStrings("{\"value\":false}", no);
}

test "list answers in the shape the JS bridge reads" {
    var registry = testRegistry();
    defer registry.deinit();

    const empty = try registry.listJson();
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("{\"shortcuts\":[]}", empty);

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"cmd+shift+h"}
    );
    _ = try registry.register(
        \\{"id":"quit","accelerator":"Ctrl+Alt+Backspace"}
    );

    const json = try registry.listJson();
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"shortcuts\":[" ++
            "{\"id\":\"toggle\",\"accelerator\":\"Cmd+Shift+H\",\"key\":\"H\",\"enabled\":true}," ++
            "{\"id\":\"quit\",\"accelerator\":\"Ctrl+Alt+Delete\",\"key\":\"Delete\",\"enabled\":true}" ++
            "]}",
        json,
    );
}

test "an id full of quotes cannot break the reply out of its JSON" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"ev\"il\\","accelerator":"Cmd+Shift+H"}
    );

    const json = try registry.listJson();
    defer std.testing.allocator.free(json);
    // Re-parsing is the assertion: if the escaping were wrong this would fail
    // or would silently yield a different id.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const list = parsed.value.object.get("shortcuts").?.array;
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("ev\"il\\", list.items[0].object.get("id").?.string);
}

test "a disabled shortcut says so in the listing" {
    var registry = testRegistry();
    defer registry.deinit();

    _ = try registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    );
    try registry.setEnabled(
        \\{"id":"toggle"}
    , false);

    const json = try registry.listJson();
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":false") != null);
}

test "the triggered event carries the id and the canonical accelerator" {
    const detail = try triggeredDetail(std.testing.allocator, "harness.summon", "Cmd+Shift+H");
    defer std.testing.allocator.free(detail);
    try std.testing.expectEqualStrings(
        "{\"id\":\"harness.summon\",\"accelerator\":\"Cmd+Shift+H\"}",
        detail,
    );

    const script = try eventScript(std.testing.allocator, "craft:shortcut", detail);
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings(
        "if(window.dispatchEvent)window.dispatchEvent(new CustomEvent('craft:shortcut',{detail:{\"id\":\"harness.summon\",\"accelerator\":\"Cmd+Shift+H\"}}));",
        script,
    );
}

test "an id cannot break out of the event it is delivered in" {
    // `'); doSomething(); //` in an id would otherwise run in every window.
    const detail = try triggeredDetail(std.testing.allocator, "a'); alert(1); //", "Cmd+Shift+H");
    defer std.testing.allocator.free(detail);
    try std.testing.expect(std.mem.indexOf(u8, detail, "alert(1)") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, detail, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a'); alert(1); //", parsed.value.object.get("id").?.string);

    const script = try eventScript(std.testing.allocator, "craft:shortcut", detail);
    defer std.testing.allocator.free(script);
    // The single quotes that would have closed the event-name literal are
    // still literal quotes inside a JSON string, not syntax.
    try std.testing.expectEqualStrings(
        "if(window.dispatchEvent)window.dispatchEvent(new CustomEvent('craft:shortcut',{detail:" ++
            "{\"id\":\"a'); alert(1); //\",\"accelerator\":\"Cmd+Shift+H\"}}));",
        script,
    );
}

test "a quote in an id is escaped for the event, not just for the listing" {
    const detail = try triggeredDetail(std.testing.allocator, "ev\"il", "Cmd+K");
    defer std.testing.allocator.free(detail);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, detail, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ev\"il", parsed.value.object.get("id").?.string);
}

test "a refused registration names the shortcut it refused" {
    const detail = try errorDetail(std.testing.allocator, "toggle", "NATIVE_CALL_FAILED", "Native API call failed");
    defer std.testing.allocator.free(detail);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, detail, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("toggle", parsed.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("NATIVE_CALL_FAILED", parsed.value.object.get("code").?.string);
}

test "the unsupported platform refuses every registration" {
    // What a build with no global-hotkey implementation gets: an honest error
    // per call, rather than a shortcut that registers and never fires.
    var registry = Registry.init(std.testing.allocator, unsupported_platform);
    defer registry.deinit();

    try std.testing.expectError(BridgeError.NativeCallFailed, registry.register(
        \\{"id":"toggle","accelerator":"Cmd+Shift+H"}
    ));
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}
