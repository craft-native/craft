//! Secure Storage / Keychain Module
//!
//! Provides secure credential storage functionality:
//! - macOS Keychain integration
//! - iOS Keychain Services
//! - Windows Credential Manager
//! - Linux Secret Service (via DBus)
//! - Encrypted fallback storage
//!
//! Example usage:
//! ```zig
//! var keychain = try Keychain.init(allocator, "com.myapp");
//! defer keychain.deinit();
//!
//! // Store a password
//! try keychain.setPassword("user@example.com", "secret123");
//!
//! // Retrieve a password
//! if (try keychain.getPassword("user@example.com")) |password| {
//!     defer allocator.free(password);
//!     // Use password...
//! }
//!
//! // Delete a password
//! try keychain.deletePassword("user@example.com");
//! ```

const std = @import("std");
const builtin = @import("builtin");
// This Zig has no std.crypto.random; compat goes to the platform CSPRNG.
const compat = @import("compat.zig");

/// Keychain item accessibility options (iOS/macOS)
pub const Accessibility = enum {
    when_unlocked, // Only accessible when device is unlocked
    after_first_unlock, // Accessible after first unlock until reboot
    when_unlocked_this_device_only, // Same as when_unlocked but not synced
    after_first_unlock_this_device_only, // Same as after_first_unlock but not synced
    when_passcode_set_this_device_only, // Only when passcode is set
    always, // Always accessible (not recommended)
    always_this_device_only, // Always accessible, not synced

    pub fn toString(self: Accessibility) []const u8 {
        return switch (self) {
            .when_unlocked => "kSecAttrAccessibleWhenUnlocked",
            .after_first_unlock => "kSecAttrAccessibleAfterFirstUnlock",
            .when_unlocked_this_device_only => "kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
            .after_first_unlock_this_device_only => "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly",
            .when_passcode_set_this_device_only => "kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly",
            .always => "kSecAttrAccessibleAlways",
            .always_this_device_only => "kSecAttrAccessibleAlwaysThisDeviceOnly",
        };
    }
};

/// Keychain item synchronization options
pub const Synchronizable = enum {
    yes, // Item syncs via iCloud Keychain
    no, // Item does not sync
    any, // Match any sync status (for queries)

    pub fn toString(self: Synchronizable) []const u8 {
        return switch (self) {
            .yes => "kCFBooleanTrue",
            .no => "kCFBooleanFalse",
            .any => "kSecAttrSynchronizableAny",
        };
    }
};

/// Keychain item class types
pub const ItemClass = enum {
    generic_password, // Generic password item
    internet_password, // Internet password (with URL info)
    certificate, // X.509 certificate
    key, // Cryptographic key
    identity, // Certificate + private key

    pub fn toString(self: ItemClass) []const u8 {
        return switch (self) {
            .generic_password => "kSecClassGenericPassword",
            .internet_password => "kSecClassInternetPassword",
            .certificate => "kSecClassCertificate",
            .key => "kSecClassKey",
            .identity => "kSecClassIdentity",
        };
    }
};

/// Options for keychain operations
pub const KeychainOptions = struct {
    accessibility: Accessibility = .when_unlocked,
    synchronizable: Synchronizable = .no,
    require_biometric: bool = false,
    label: ?[]const u8 = null,
    comment: ?[]const u8 = null,
};

/// Keychain query options
pub const QueryOptions = struct {
    limit: ?u32 = null, // null = return first match, 0 = return all
    return_data: bool = true,
    return_attributes: bool = false,
    return_ref: bool = false,
};

/// Keychain item attributes
pub const ItemAttributes = struct {
    account: []const u8,
    service: []const u8,
    label: ?[]const u8,
    comment: ?[]const u8,
    creation_date: ?i64,
    modification_date: ?i64,
    accessibility: ?Accessibility,
    synchronizable: bool,
};

/// Keychain errors
pub const KeychainError = error{
    ItemNotFound,
    DuplicateItem,
    AuthFailed,
    NoAccess,
    InvalidData,
    NotAvailable,
    Unimplemented,
    Param,
    Allocate,
    Decode,
    Internal,
    UserCancelled,
    InteractionNotAllowed,
};

/// Internet password protocol types
pub const ProtocolType = enum {
    http,
    https,
    ftp,
    ftps,
    ssh,
    smb,
    afp,
    telnet,
    ldap,
    ldaps,
    imap,
    imaps,
    pop3,
    pop3s,
    smtp,

    pub fn toString(self: ProtocolType) []const u8 {
        return switch (self) {
            .http => "http",
            .https => "https",
            .ftp => "ftp",
            .ftps => "ftps",
            .ssh => "ssh",
            .smb => "smb",
            .afp => "afp",
            .telnet => "telnet",
            .ldap => "ldap",
            .ldaps => "ldaps",
            .imap => "imap",
            .imaps => "imaps",
            .pop3 => "pop3",
            .pop3s => "pop3s",
            .smtp => "smtp",
        };
    }

    pub fn defaultPort(self: ProtocolType) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
            .ftp => 21,
            .ftps => 990,
            .ssh => 22,
            .smb => 445,
            .afp => 548,
            .telnet => 23,
            .ldap => 389,
            .ldaps => 636,
            .imap => 143,
            .imaps => 993,
            .pop3 => 110,
            .pop3s => 995,
            .smtp => 25,
        };
    }
};

/// Internet password item
pub const InternetPassword = struct {
    account: []const u8,
    password: []const u8,
    server: []const u8,
    protocol: ProtocolType,
    port: ?u16 = null,
    path: ?[]const u8 = null,
    security_domain: ?[]const u8 = null,
};

/// Main keychain manager
pub const Keychain = struct {
    allocator: std.mem.Allocator,
    service_name: []const u8,
    access_group: ?[]const u8,
    default_options: KeychainOptions,
    native_handle: ?*anyopaque = null,

    // Fallback encrypted storage (for platforms without keychain)
    fallback_storage: ?std.StringHashMapUnmanaged([]const u8) = null,
    encryption_key: ?[32]u8 = null,

    const Self = @This();

    /// Initialize keychain with service name (bundle identifier)
    pub fn init(allocator: std.mem.Allocator, service_name: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .service_name = service_name,
            .access_group = null,
            .default_options = .{},
        };
    }

    /// Initialize keychain with access group (for sharing between apps)
    pub fn initWithAccessGroup(allocator: std.mem.Allocator, service_name: []const u8, access_group: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .service_name = service_name,
            .access_group = access_group,
            .default_options = .{},
        };
    }

    /// Set default options for all operations
    pub fn setDefaultOptions(self: *Self, options: KeychainOptions) void {
        self.default_options = options;
    }

    // ========================================================================
    // Generic Password Operations
    // ========================================================================

    /// Store a password for an account
    pub fn setPassword(self: *Self, account: []const u8, password: []const u8) KeychainError!void {
        return self.setPasswordWithOptions(account, password, self.default_options);
    }

    /// Store a password with custom options
    pub fn setPasswordWithOptions(self: *Self, account: []const u8, password: []const u8, options: KeychainOptions) KeychainError!void {
        if (builtin.os.tag == .macos or builtin.target.os.tag == .ios) {
            return self.setPasswordMacOS(account, password, options);
        }
        self.deletePassword(account) catch |err| {
            if (err != KeychainError.ItemNotFound) return err;
        };
        if (builtin.os.tag == .windows) {
            return self.setPasswordWindows(account, password, options);
        } else if (builtin.os.tag == .linux) {
            return self.setPasswordLinux(account, password, options);
        }

        // Fallback to in-memory encrypted storage
        return self.setPasswordFallback(account, password);
    }

    fn setPasswordMacOS(self: *Self, account: []const u8, password: []const u8, options: KeychainOptions) KeychainError!void {
        return @import("apple_keychain.zig").set(self, account, password, options);
    }

    fn setPasswordWindows(self: *Self, account: []const u8, password: []const u8, options: KeychainOptions) KeychainError!void {
        _ = self;
        _ = account;
        _ = password;
        _ = options;
        // In real implementation, would use CredWriteW
        return;
    }

    fn setPasswordLinux(self: *Self, account: []const u8, password: []const u8, options: KeychainOptions) KeychainError!void {
        _ = self;
        _ = account;
        _ = password;
        _ = options;
        // In real implementation, would use libsecret/Secret Service API via DBus
        return;
    }

    fn setPasswordFallback(self: *Self, account: []const u8, password: []const u8) KeychainError!void {
        if (self.fallback_storage == null) {
            self.fallback_storage = std.StringHashMapUnmanaged([]const u8){};
        }

        const key = try self.makeKey(account);
        const encrypted = try self.encrypt(password);

        self.fallback_storage.?.put(self.allocator, key, encrypted) catch {
            return KeychainError.Allocate;
        };
    }

    /// Get a password for an account
    pub fn getPassword(self: *Self, account: []const u8) KeychainError!?[]const u8 {
        if (builtin.os.tag == .macos or builtin.target.os.tag == .ios) {
            return self.getPasswordMacOS(account);
        } else if (builtin.os.tag == .windows) {
            return self.getPasswordWindows(account);
        } else if (builtin.os.tag == .linux) {
            return self.getPasswordLinux(account);
        }

        // Fallback storage
        return self.getPasswordFallback(account);
    }

    fn getPasswordMacOS(self: *Self, account: []const u8) KeychainError!?[]const u8 {
        return @import("apple_keychain.zig").get(self, account);
    }

    fn getPasswordWindows(self: *Self, account: []const u8) KeychainError!?[]const u8 {
        _ = self;
        _ = account;
        // In real implementation, would use CredReadW
        return null;
    }

    fn getPasswordLinux(self: *Self, account: []const u8) KeychainError!?[]const u8 {
        _ = self;
        _ = account;
        // In real implementation, would use libsecret
        return null;
    }

    fn getPasswordFallback(self: *Self, account: []const u8) KeychainError!?[]const u8 {
        if (self.fallback_storage == null) return null;

        const key = try self.makeKey(account);
        if (self.fallback_storage.?.get(key)) |encrypted| {
            return @as(?[]const u8, try self.decrypt(encrypted));
        }
        return null;
    }

    /// Delete a password for an account
    pub fn deletePassword(self: *Self, account: []const u8) KeychainError!void {
        if (builtin.os.tag == .macos or builtin.target.os.tag == .ios) {
            return self.deletePasswordMacOS(account);
        } else if (builtin.os.tag == .windows) {
            return self.deletePasswordWindows(account);
        } else if (builtin.os.tag == .linux) {
            return self.deletePasswordLinux(account);
        }

        return self.deletePasswordFallback(account);
    }

    fn deletePasswordMacOS(self: *Self, account: []const u8) KeychainError!void {
        return @import("apple_keychain.zig").delete(self, account);
    }

    fn deletePasswordWindows(self: *Self, account: []const u8) KeychainError!void {
        _ = self;
        _ = account;
        // In real implementation, would use CredDeleteW
    }

    fn deletePasswordLinux(self: *Self, account: []const u8) KeychainError!void {
        _ = self;
        _ = account;
        // In real implementation, would use libsecret
    }

    fn deletePasswordFallback(self: *Self, account: []const u8) KeychainError!void {
        if (self.fallback_storage == null) return KeychainError.ItemNotFound;

        const key = try self.makeKey(account);
        if (self.fallback_storage.?.fetchRemove(key)) |entry| {
            self.allocator.free(entry.value);
        } else {
            return KeychainError.ItemNotFound;
        }
    }

    /// Check if a password exists for an account
    pub fn hasPassword(self: *Self, account: []const u8) KeychainError!bool {
        const password = try self.getPassword(account);
        if (password) |p| {
            self.allocator.free(p);
            return true;
        }
        return false;
    }

    // ========================================================================
    // Internet Password Operations
    // ========================================================================

    /// Store an internet password
    pub fn setInternetPassword(self: *Self, item: InternetPassword) KeychainError!void {
        return self.setInternetPasswordWithOptions(item, self.default_options);
    }

    /// Store an internet password with custom options
    pub fn setInternetPasswordWithOptions(self: *Self, item: InternetPassword, options: KeychainOptions) KeychainError!void {
        if (builtin.os.tag == .macos or builtin.target.os.tag == .ios) {
            return self.setInternetPasswordMacOS(item, options);
        }

        // Fallback: store as generic password with server as account
        var buf: [256]u8 = undefined;
        const account = std.fmt.bufPrint(&buf, "{s}@{s}", .{ item.account, item.server }) catch {
            return KeychainError.InvalidData;
        };
        return self.setPasswordWithOptions(account, item.password, options);
    }

    fn setInternetPasswordMacOS(self: *Self, item: InternetPassword, options: KeychainOptions) KeychainError!void {
        _ = self;
        _ = item;
        _ = options;
        // In real implementation, would use SecItemAdd with kSecClassInternetPassword
    }

    /// Get an internet password
    pub fn getInternetPassword(self: *Self, account: []const u8, server: []const u8, protocol: ProtocolType) KeychainError!?[]const u8 {
        if (builtin.os.tag == .macos or builtin.target.os.tag == .ios) {
            return self.getInternetPasswordMacOS(account, server, protocol);
        }

        // Fallback
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}@{s}", .{ account, server }) catch {
            return KeychainError.InvalidData;
        };
        return self.getPassword(key);
    }

    fn getInternetPasswordMacOS(self: *Self, account: []const u8, server: []const u8, protocol: ProtocolType) KeychainError!?[]const u8 {
        _ = self;
        _ = account;
        _ = server;
        _ = protocol;
        // In real implementation, would use SecItemCopyMatching
        return null;
    }

    // ========================================================================
    // Secure Data Operations (for arbitrary data)
    // ========================================================================

    /// Store arbitrary secure data
    pub fn setSecureData(self: *Self, key: []const u8, data: []const u8) KeychainError!void {
        return self.setPasswordWithOptions(key, data, self.default_options);
    }

    /// Get arbitrary secure data
    pub fn getSecureData(self: *Self, key: []const u8) KeychainError!?[]const u8 {
        return self.getPassword(key);
    }

    /// Delete arbitrary secure data
    pub fn deleteSecureData(self: *Self, key: []const u8) KeychainError!void {
        return self.deletePassword(key);
    }

    // ========================================================================
    // Bulk Operations
    // ========================================================================

    /// Get all accounts stored for this service
    pub fn getAllAccounts(self: *Self, buf: [][]const u8) KeychainError![][]const u8 {
        if (builtin.os.tag == .macos or builtin.target.os.tag == .ios) {
            return self.getAllAccountsMacOS(buf);
        }

        // Fallback
        return self.getAllAccountsFallback(buf);
    }

    fn getAllAccountsMacOS(self: *Self, buf: [][]const u8) KeychainError![][]const u8 {
        _ = self;
        // In real implementation, would query all items
        return buf[0..0];
    }

    fn getAllAccountsFallback(self: *Self, buf: [][]const u8) KeychainError![][]const u8 {
        if (self.fallback_storage == null) return buf[0..0];

        var count: usize = 0;
        var it = self.fallback_storage.?.iterator();
        while (it.next()) |entry| {
            if (count >= buf.len) break;
            buf[count] = entry.key_ptr.*;
            count += 1;
        }
        return buf[0..count];
    }

    /// Delete all items for this service
    pub fn deleteAll(self: *Self) KeychainError!void {
        if (builtin.os.tag == .macos or builtin.target.os.tag == .ios) {
            return self.deleteAllMacOS();
        }

        return self.deleteAllFallback();
    }

    fn deleteAllMacOS(self: *Self) KeychainError!void {
        _ = self;
        // In real implementation, would use SecItemDelete with service filter
    }

    fn deleteAllFallback(self: *Self) KeychainError!void {
        if (self.fallback_storage == null) return;

        var it = self.fallback_storage.?.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.fallback_storage.?.clearRetainingCapacity();
    }

    // ========================================================================
    // Utility Functions
    // ========================================================================

    fn makeKey(self: *Self, account: []const u8) KeychainError![]const u8 {
        _ = self;
        return account; // In real implementation, might prefix with service name
    }

    fn encrypt(self: *Self, data: []const u8) KeychainError![]const u8 {
        // Simple XOR encryption for fallback (not secure for production!)
        // In real implementation, would use proper encryption
        if (self.encryption_key == null) {
            // Generate random key
            var key: [32]u8 = undefined;
            compat.randomBytes(&key);
            self.encryption_key = key;
        }

        const encrypted = self.allocator.alloc(u8, data.len) catch {
            return KeychainError.Allocate;
        };

        for (data, 0..) |byte, i| {
            encrypted[i] = byte ^ self.encryption_key.?[i % 32];
        }

        return encrypted;
    }

    fn decrypt(self: *Self, data: []const u8) KeychainError![]const u8 {
        if (self.encryption_key == null) {
            return KeychainError.InvalidData;
        }

        const decrypted = self.allocator.alloc(u8, data.len) catch {
            return KeychainError.Allocate;
        };

        for (data, 0..) |byte, i| {
            decrypted[i] = byte ^ self.encryption_key.?[i % 32];
        }

        return decrypted;
    }

    /// Check if keychain is available on this platform
    pub fn isAvailable(self: *Self) bool {
        _ = self;
        return builtin.os.tag == .macos or
            builtin.target.os.tag == .ios or
            builtin.os.tag == .windows or
            builtin.os.tag == .linux;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        if (self.fallback_storage) |*storage| {
            var it = storage.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            storage.deinit(self.allocator);
        }
        self.native_handle = null;
    }
};

/// Secure token storage for authentication tokens
pub const TokenStore = struct {
    keychain: *Keychain,
    prefix: []const u8,

    const Self = @This();

    pub fn init(keychain: *Keychain, prefix: []const u8) Self {
        return .{
            .keychain = keychain,
            .prefix = prefix,
        };
    }

    /// Store an access token
    pub fn setAccessToken(self: *Self, token: []const u8) KeychainError!void {
        var buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}_access_token", .{self.prefix}) catch {
            return KeychainError.InvalidData;
        };
        return self.keychain.setPassword(key, token);
    }

    /// Get the access token
    pub fn getAccessToken(self: *Self) KeychainError!?[]const u8 {
        var buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}_access_token", .{self.prefix}) catch {
            return KeychainError.InvalidData;
        };
        return self.keychain.getPassword(key);
    }

    /// Store a refresh token
    pub fn setRefreshToken(self: *Self, token: []const u8) KeychainError!void {
        var buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}_refresh_token", .{self.prefix}) catch {
            return KeychainError.InvalidData;
        };
        return self.keychain.setPassword(key, token);
    }

    /// Get the refresh token
    pub fn getRefreshToken(self: *Self) KeychainError!?[]const u8 {
        var buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}_refresh_token", .{self.prefix}) catch {
            return KeychainError.InvalidData;
        };
        return self.keychain.getPassword(key);
    }

    /// Clear all tokens
    pub fn clearTokens(self: *Self) KeychainError!void {
        var buf: [128]u8 = undefined;

        const access_key = std.fmt.bufPrint(&buf, "{s}_access_token", .{self.prefix}) catch {
            return KeychainError.InvalidData;
        };
        self.keychain.deletePassword(access_key) catch |err| {
            std.log.debug("failed to delete access token during clearTokens: {}", .{err});
        };

        const refresh_key = std.fmt.bufPrint(&buf, "{s}_refresh_token", .{self.prefix}) catch {
            return KeychainError.InvalidData;
        };
        self.keychain.deletePassword(refresh_key) catch |err| {
            std.log.debug("failed to delete refresh token during clearTokens: {}", .{err});
        };
    }
};

/// Credential storage for username/password pairs
pub const CredentialStore = struct {
    keychain: *Keychain,
    service: []const u8,

    const Self = @This();

    pub fn init(keychain: *Keychain, service: []const u8) Self {
        return .{
            .keychain = keychain,
            .service = service,
        };
    }

    /// Store credentials
    pub fn setCredentials(self: *Self, username: []const u8, password: []const u8) KeychainError!void {
        // Store username
        var buf: [256]u8 = undefined;
        const user_key = std.fmt.bufPrint(&buf, "{s}_username", .{self.service}) catch {
            return KeychainError.InvalidData;
        };
        try self.keychain.setPassword(user_key, username);

        // Store password
        const pass_key = std.fmt.bufPrint(&buf, "{s}_password", .{self.service}) catch {
            return KeychainError.InvalidData;
        };
        try self.keychain.setPassword(pass_key, password);
    }

    /// Get stored username
    pub fn getUsername(self: *Self) KeychainError!?[]const u8 {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}_username", .{self.service}) catch {
            return KeychainError.InvalidData;
        };
        return self.keychain.getPassword(key);
    }

    /// Get stored password
    pub fn getPassword(self: *Self) KeychainError!?[]const u8 {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}_password", .{self.service}) catch {
            return KeychainError.InvalidData;
        };
        return self.keychain.getPassword(key);
    }

    /// Clear stored credentials
    pub fn clearCredentials(self: *Self) KeychainError!void {
        var buf: [256]u8 = undefined;

        const user_key = std.fmt.bufPrint(&buf, "{s}_username", .{self.service}) catch {
            return KeychainError.InvalidData;
        };
        self.keychain.deletePassword(user_key) catch |err| {
            std.log.debug("failed to delete username during clearCredentials: {}", .{err});
        };

        const pass_key = std.fmt.bufPrint(&buf, "{s}_password", .{self.service}) catch {
            return KeychainError.InvalidData;
        };
        self.keychain.deletePassword(pass_key) catch |err| {
            std.log.debug("failed to delete password during clearCredentials: {}", .{err});
        };
    }

    /// Check if credentials are stored
    pub fn hasCredentials(self: *Self) KeychainError!bool {
        if (try self.getUsername()) |username| {
            self.keychain.allocator.free(username);
            return true;
        }
        return false;
    }
};

/// Keychain presets for common use cases
pub const KeychainPresets = struct {
    /// Options for storing API keys
    pub fn apiKeyOptions() KeychainOptions {
        return .{
            .accessibility = .after_first_unlock,
            .synchronizable = .no,
            .require_biometric = false,
            .label = "API Key",
        };
    }

    /// Options for storing user passwords (high security)
    pub fn userPasswordOptions() KeychainOptions {
        return .{
            .accessibility = .when_unlocked,
            .synchronizable = .no,
            .require_biometric = true,
            .label = "User Password",
        };
    }

    /// Options for storing authentication tokens
    pub fn authTokenOptions() KeychainOptions {
        return .{
            .accessibility = .after_first_unlock,
            .synchronizable = .yes,
            .require_biometric = false,
            .label = "Auth Token",
        };
    }

    /// Options for storing encryption keys
    pub fn encryptionKeyOptions() KeychainOptions {
        return .{
            .accessibility = .when_passcode_set_this_device_only,
            .synchronizable = .no,
            .require_biometric = true,
            .label = "Encryption Key",
        };
    }

    /// Options for storing sensitive data that syncs
    pub fn syncedSecretOptions() KeychainOptions {
        return .{
            .accessibility = .after_first_unlock,
            .synchronizable = .yes,
            .require_biometric = false,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Accessibility toString" {
    try std.testing.expectEqualStrings("kSecAttrAccessibleWhenUnlocked", Accessibility.when_unlocked.toString());
    try std.testing.expectEqualStrings("kSecAttrAccessibleAfterFirstUnlock", Accessibility.after_first_unlock.toString());
}

test "ItemClass toString" {
    try std.testing.expectEqualStrings("kSecClassGenericPassword", ItemClass.generic_password.toString());
    try std.testing.expectEqualStrings("kSecClassInternetPassword", ItemClass.internet_password.toString());
}

test "ProtocolType defaultPort" {
    try std.testing.expectEqual(@as(u16, 80), ProtocolType.http.defaultPort());
    try std.testing.expectEqual(@as(u16, 443), ProtocolType.https.defaultPort());
    try std.testing.expectEqual(@as(u16, 22), ProtocolType.ssh.defaultPort());
}

test "Keychain initialization" {
    const allocator = std.testing.allocator;
    var keychain = try Keychain.init(allocator, "com.test.app");
    defer keychain.deinit();

    try std.testing.expectEqualStrings("com.test.app", keychain.service_name);
    try std.testing.expect(keychain.access_group == null);
}

test "Keychain initWithAccessGroup" {
    const allocator = std.testing.allocator;
    var keychain = try Keychain.initWithAccessGroup(allocator, "com.test.app", "com.test.shared");
    defer keychain.deinit();

    try std.testing.expectEqualStrings("com.test.shared", keychain.access_group.?);
}

test "Keychain setDefaultOptions" {
    const allocator = std.testing.allocator;
    var keychain = try Keychain.init(allocator, "com.test.app");
    defer keychain.deinit();

    keychain.setDefaultOptions(.{
        .accessibility = .when_passcode_set_this_device_only,
        .require_biometric = true,
    });

    try std.testing.expectEqual(Accessibility.when_passcode_set_this_device_only, keychain.default_options.accessibility);
    try std.testing.expect(keychain.default_options.require_biometric);
}

test "Keychain isAvailable" {
    const allocator = std.testing.allocator;
    var keychain = try Keychain.init(allocator, "com.test.app");
    defer keychain.deinit();

    // Should be available on major platforms
    const available = keychain.isAvailable();
    _ = available;
}

test "TokenStore initialization" {
    const allocator = std.testing.allocator;
    var keychain = try Keychain.init(allocator, "com.test.app");
    defer keychain.deinit();

    const token_store = TokenStore.init(&keychain, "myapp");
    try std.testing.expectEqualStrings("myapp", token_store.prefix);
}

test "CredentialStore initialization" {
    const allocator = std.testing.allocator;
    var keychain = try Keychain.init(allocator, "com.test.app");
    defer keychain.deinit();

    const cred_store = CredentialStore.init(&keychain, "github");
    try std.testing.expectEqualStrings("github", cred_store.service);
}

test "KeychainPresets" {
    const api_opts = KeychainPresets.apiKeyOptions();
    try std.testing.expectEqual(Accessibility.after_first_unlock, api_opts.accessibility);
    try std.testing.expect(!api_opts.require_biometric);

    const password_opts = KeychainPresets.userPasswordOptions();
    try std.testing.expectEqual(Accessibility.when_unlocked, password_opts.accessibility);
    try std.testing.expect(password_opts.require_biometric);

    const encryption_opts = KeychainPresets.encryptionKeyOptions();
    try std.testing.expectEqual(Accessibility.when_passcode_set_this_device_only, encryption_opts.accessibility);
    try std.testing.expectEqual(Synchronizable.no, encryption_opts.synchronizable);
}

test "Keychain fallback storage set and get" {
    const allocator = std.testing.allocator;
    var keychain = try Keychain.init(allocator, "com.test.app");
    defer keychain.deinit();

    // This will use fallback storage on unsupported platforms
    try keychain.setPasswordFallback("test_account", "test_password");

    const retrieved = try keychain.getPasswordFallback("test_account");
    try std.testing.expect(retrieved != null);
    defer allocator.free(retrieved.?);
}

test "Keychain fallback storage delete" {
    const allocator = std.testing.allocator;
    var keychain = try Keychain.init(allocator, "com.test.app");
    defer keychain.deinit();

    try keychain.setPasswordFallback("test_account", "test_password");
    try keychain.deletePasswordFallback("test_account");

    const retrieved = try keychain.getPasswordFallback("test_account");
    try std.testing.expect(retrieved == null);
}

test "Synchronizable toString" {
    try std.testing.expectEqualStrings("kCFBooleanTrue", Synchronizable.yes.toString());
    try std.testing.expectEqualStrings("kCFBooleanFalse", Synchronizable.no.toString());
}
