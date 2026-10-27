//! Generic passwords through public Security.framework APIs. Values remain in
//! the OS keychain, never a process cache or a plaintext file.
const std = @import("std");
const builtin = @import("builtin");
const api = @import("keychain.zig");
const Ref = ?*const anyopaque;
extern "c" fn SecItemAdd(Ref, ?*Ref) i32;
extern "c" fn SecItemUpdate(Ref, Ref) i32;
extern "c" fn SecItemCopyMatching(Ref, *Ref) i32;
extern "c" fn SecItemDelete(Ref) i32;
extern "c" fn CFDictionaryCreate(Ref, [*]const Ref, [*]const Ref, isize, Ref, Ref) Ref;
extern "c" fn CFStringCreateWithBytes(Ref, [*]const u8, isize, u32, u8) Ref;
extern "c" fn CFDataCreate(Ref, [*]const u8, isize) Ref;
extern "c" fn CFDataGetLength(Ref) isize;
extern "c" fn CFDataGetBytePtr(Ref) ?[*]const u8;
extern "c" fn CFGetTypeID(Ref) usize;
extern "c" fn CFDataGetTypeID() usize;
extern "c" fn CFRelease(Ref) void;
extern "c" const kSecClass: Ref;
extern "c" const kSecClassGenericPassword: Ref;
extern "c" const kSecAttrService: Ref;
extern "c" const kSecAttrAccount: Ref;
extern "c" const kSecAttrAccessGroup: Ref;
extern "c" const kSecAttrAccessible: Ref;
extern "c" const kSecAttrAccessibleWhenUnlocked: Ref;
extern "c" const kSecAttrAccessibleAfterFirstUnlock: Ref;
extern "c" const kSecAttrAccessibleWhenUnlockedThisDeviceOnly: Ref;
extern "c" const kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: Ref;
extern "c" const kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly: Ref;
extern "c" const kSecAttrAccessibleAlways: Ref;
extern "c" const kSecAttrAccessibleAlwaysThisDeviceOnly: Ref;
extern "c" const kSecAttrSynchronizable: Ref;
extern "c" const kSecAttrSynchronizableAny: Ref;
extern "c" const kSecAttrLabel: Ref;
extern "c" const kSecAttrComment: Ref;
extern "c" const kSecValueData: Ref;
extern "c" const kSecReturnData: Ref;
extern "c" const kSecMatchLimit: Ref;
extern "c" const kSecMatchLimitOne: Ref;
extern "c" const kCFBooleanTrue: Ref;
extern "c" const kCFBooleanFalse: Ref;

pub fn check(status: i32) api.KeychainError!void {
    return switch (status) {
        0 => {},
        -25300 => error.ItemNotFound,
        -25299 => error.DuplicateItem,
        -25293 => error.AuthFailed,
        -25291 => error.NotAvailable,
        -25308 => error.InteractionNotAllowed,
        -128 => error.UserCancelled,
        -34018 => error.NoAccess,
        -50 => error.Param,
        -26275 => error.Decode,
        else => error.Internal,
    };
}

// No dictionary callbacks: Query owns its strings/data and keeps them alive
// through the synchronous Security call. Dictionaries never outlive Query.
const Query = struct {
    keys: [12]Ref = undefined,
    values: [12]Ref = undefined,
    owned: [8]Ref = undefined,
    count: usize = 0,
    owned_count: usize = 0,
    dictionary: Ref = null,
    fn add(self: *Query, key: Ref, value: Ref) void {
        self.keys[self.count] = key;
        self.values[self.count] = value;
        self.count += 1;
    }
    fn own(self: *Query, value: Ref) api.KeychainError!Ref {
        const result = value orelse return error.Allocate;
        self.owned[self.owned_count] = result;
        self.owned_count += 1;
        return result;
    }
    fn string(self: *Query, key: Ref, value: []const u8) api.KeychainError!void {
        self.add(key, try self.own(CFStringCreateWithBytes(null, value.ptr, @intCast(value.len), 0x08000100, 0)));
    }
    fn ref(self: *Query) api.KeychainError!Ref {
        self.dictionary = CFDictionaryCreate(null, &self.keys, &self.values, @intCast(self.count), null, null) orelse return error.Allocate;
        return self.dictionary;
    }
    fn deinit(self: *Query) void {
        if (self.dictionary) |value| CFRelease(value);
        for (self.owned[0..self.owned_count]) |value| CFRelease(value);
    }
};

fn identity(kc: *api.Keychain, account: []const u8) api.KeychainError!Query {
    if (kc.service_name.len == 0 or account.len == 0) return error.Param;
    var query: Query = .{};
    errdefer query.deinit();
    query.add(kSecClass, kSecClassGenericPassword);
    try query.string(kSecAttrService, kc.service_name);
    try query.string(kSecAttrAccount, account);
    if (kc.access_group) |group| try query.string(kSecAttrAccessGroup, group);
    return query;
}

pub fn set(kc: *api.Keychain, account: []const u8, password: []const u8, options: api.KeychainOptions) api.KeychainError!void {
    // Never claim biometric protection without a SecAccessControl policy.
    if (options.require_biometric) return error.Unimplemented;
    // The macOS file keychain can report success while ignoring an empty
    // replacement. Reject empty credentials consistently before any mutation.
    if (password.len == 0) return error.InvalidData;
    if (options.synchronizable == .any) return error.Param;
    var query = try identity(kc, account);
    defer query.deinit();
    query.add(kSecAttrSynchronizable, if (options.synchronizable == .yes) kCFBooleanTrue else kCFBooleanFalse);
    var attributes: Query = .{};
    defer attributes.deinit();
    attributes.add(kSecValueData, try attributes.own(CFDataCreate(null, password.ptr, @intCast(password.len))));
    attributes.add(kSecAttrAccessible, switch (options.accessibility) {
        .when_unlocked => kSecAttrAccessibleWhenUnlocked,
        .after_first_unlock => kSecAttrAccessibleAfterFirstUnlock,
        .when_unlocked_this_device_only => kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .after_first_unlock_this_device_only => kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        .when_passcode_set_this_device_only => kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
        .always => kSecAttrAccessibleAlways,
        .always_this_device_only => kSecAttrAccessibleAlwaysThisDeviceOnly,
    });
    if (options.label) |label| try attributes.string(kSecAttrLabel, label);
    if (options.comment) |comment| try attributes.string(kSecAttrComment, comment);
    const update_status = SecItemUpdate(try query.ref(), try attributes.ref());
    if (update_status != -25300) return check(update_status);
    // Adding does not delete an existing credential. A concurrent insert is
    // reported as DuplicateItem instead of overwriting another writer.
    var addition = try identity(kc, account);
    defer addition.deinit();
    addition.add(kSecAttrSynchronizable, if (options.synchronizable == .yes) kCFBooleanTrue else kCFBooleanFalse);
    for (attributes.keys[0..attributes.count], attributes.values[0..attributes.count]) |key, value| addition.add(key, value);
    try check(SecItemAdd(try addition.ref(), null));
}

pub fn get(kc: *api.Keychain, account: []const u8) api.KeychainError!?[]const u8 {
    var query = try identity(kc, account);
    defer query.deinit();
    query.add(kSecAttrSynchronizable, kSecAttrSynchronizableAny);
    query.add(kSecReturnData, kCFBooleanTrue);
    query.add(kSecMatchLimit, kSecMatchLimitOne);
    var result: Ref = null;
    const status = SecItemCopyMatching(try query.ref(), &result);
    if (status == -25300) return null;
    try check(status);
    const data = result orelse return error.Decode;
    defer CFRelease(data);
    if (CFGetTypeID(data) != CFDataGetTypeID()) return error.Decode;
    const length = CFDataGetLength(data);
    if (length < 0) return error.Decode;
    if (length == 0) return kc.allocator.dupe(u8, "") catch error.Allocate;
    const bytes = CFDataGetBytePtr(data) orelse return error.Decode;
    return kc.allocator.dupe(u8, bytes[0..@intCast(length)]) catch error.Allocate;
}

pub fn delete(kc: *api.Keychain, account: []const u8) api.KeychainError!void {
    var query = try identity(kc, account);
    defer query.deinit();
    query.add(kSecAttrSynchronizable, kSecAttrSynchronizableAny);
    const status = SecItemDelete(try query.ref());
    if (status != -25300) try check(status);
}

test "Keychain distinguishes missing values from access and authentication errors" {
    try check(0);
    try std.testing.expectError(error.ItemNotFound, check(-25300));
    try std.testing.expectError(error.NoAccess, check(-34018));
    try std.testing.expectError(error.InteractionNotAllowed, check(-25308));
    try std.testing.expectError(error.AuthFailed, check(-25293));
    try std.testing.expectError(error.Internal, check(-1));
}

test "native Keychain persistence, update, service isolation and deletion" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // Explicitly opt in to touching a real login keychain. A random service
    // scopes every operation and cleanup to this fixture's own items.
    const opt_in = std.c.getenv("CRAFT_TEST_KEYCHAIN") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(opt_in), "1")) return error.SkipZigTest;
    var nonce: [16]u8 = undefined;
    @import("compat.zig").randomBytes(&nonce);
    const service = try std.fmt.allocPrint(std.testing.allocator, "dev.craft.keychain-test.{x}", .{nonce});
    defer std.testing.allocator.free(service);
    var first = try api.Keychain.init(std.testing.allocator, service);
    defer first.deinit();
    defer first.deletePassword("fixture") catch {};
    try std.testing.expect(try first.getPassword("fixture") == null);
    try first.setPassword("fixture", "unicode é \\\n\x00");
    var second = try api.Keychain.init(std.testing.allocator, service);
    defer second.deinit();
    const persisted = (try second.getPassword("fixture")).?;
    defer std.testing.allocator.free(persisted);
    try std.testing.expectEqualStrings("unicode é \\\n\x00", persisted);
    try second.setPassword("fixture", "updated");
    try std.testing.expectError(error.Unimplemented, first.setPasswordWithOptions("fixture", "must not replace", .{ .require_biometric = true }));
    const updated = (try first.getPassword("fixture")).?;
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings("updated", updated);
    var isolated = try api.Keychain.init(std.testing.allocator, "dev.craft.keychain-test.other-service");
    defer isolated.deinit();
    try std.testing.expect(try isolated.getPassword("fixture") == null);
    try std.testing.expectError(error.InvalidData, first.setPassword("fixture", ""));
    const preserved = (try second.getPassword("fixture")).?;
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("updated", preserved);
    try first.deletePassword("fixture");
    try std.testing.expect(try second.getPassword("fixture") == null);
    try first.deletePassword("fixture");
}
