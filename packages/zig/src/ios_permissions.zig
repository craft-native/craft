//! Compile-time permission surface of an iOS runtime archive (#424).
//! Runtime configuration may narrow this set, but cannot compile an API back in.
const std = @import("std");

pub const Permission = enum(u4) {
    speech,
    microphone,
    camera,
    photos,
    location,
    contacts,
    calendar,
    bluetooth,
    motion,
    biometric,
    music,
    health,
    nfc,

    pub fn bit(self: Permission) u16 {
        return @as(u16, 1) << @backingInt(self);
    }
};

pub const all: u16 = (1 << std.meta.fieldNames(Permission).len) - 1;
pub const mask: u16 = if (@hasDecl(@import("root"), "craft_ios_permission_mask"))
    @import("root").craft_ios_permission_mask
else
    all; // Host tests and legacy embedders retain their existing surface.

pub fn includes(value: u16, permission: Permission) bool {
    return value & permission.bit() != 0;
}

pub fn enabled(comptime permission: Permission) bool {
    return includes(mask, permission);
}

pub fn parse(value: []const u8) error{InvalidPermission}!u16 {
    if (std.mem.eql(u8, value, "all")) return all;
    if (std.mem.eql(u8, value, "none")) return 0;
    var result: u16 = 0;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |name| {
        const permission = std.meta.stringToEnum(Permission, name) orelse return error.InvalidPermission;
        if (includes(result, permission)) return error.InvalidPermission;
        result |= permission.bit();
    }
    return result;
}

test "permission profiles are exact, fail closed on typos, and keep independent bits" {
    const expect = std.testing.expect;
    try std.testing.expectEqual(@as(u16, 0), try parse("none"));
    try std.testing.expectEqual(all, try parse("all"));
    const selected = try parse("camera,photos");
    try expect(includes(selected, .camera));
    try expect(includes(selected, .photos));
    try expect(!includes(selected, .microphone));
    inline for (comptime std.meta.fieldNames(Permission)) |name| {
        const permission = @field(Permission, name);
        try std.testing.expectEqual(permission.bit(), try parse(name));
    }
    for ([_][]const u8{ "", "camera,", "camera,camera", "Camera", "camera, contacts", "all,camera", "none,camera", "unknown" }) |invalid| {
        try std.testing.expectError(error.InvalidPermission, parse(invalid));
    }
}
