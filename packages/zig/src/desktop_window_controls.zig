//! Validated, platform-neutral inputs for the portable window controls.
const std = @import("std");

pub const Bounds = struct {
    x: ?i32 = null,
    y: ?i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

pub const Size = struct { width: u32, height: u32 };
pub const Position = struct { x: i32, y: i32 };
pub const Workarea = struct { x: i32, y: i32, width: u32, height: u32 };

pub fn centerIn(area: Workarea, size: Size) !Position {
    const x = @as(i64, area.x) + @divTrunc(@as(i64, area.width) - @as(i64, size.width), 2);
    const y = @as(i64, area.y) + @divTrunc(@as(i64, area.height) - @as(i64, size.height), 2);
    return .{
        .x = std.math.cast(i32, x) orelse return error.InvalidParameter,
        .y = std.math.cast(i32, y) orelse return error.InvalidParameter,
    };
}

pub const Limits = struct {
    minimum: ?Size = null,
    maximum: ?Size = null,

    pub fn withMinimum(self: Limits, size: Size) !Limits {
        if (self.maximum) |max| {
            if (size.width > max.width or size.height > max.height) return error.InvalidParameter;
        }
        var next = self;
        next.minimum = size;
        return next;
    }

    pub fn withMaximum(self: Limits, size: Size) !Limits {
        if (self.minimum) |min| {
            if (size.width < min.width or size.height < min.height) return error.InvalidParameter;
        }
        var next = self;
        next.maximum = size;
        return next;
    }

    pub fn clamp(self: Limits, size: Size) Size {
        var result = size;
        if (self.minimum) |min| {
            result.width = @max(result.width, min.width);
            result.height = @max(result.height, min.height);
        }
        if (self.maximum) |max| {
            result.width = @min(result.width, max.width);
            result.height = @min(result.height, max.height);
        }
        return result;
    }
};

fn object(data: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return error.InvalidParameter;
    if (parsed.value != .object) {
        parsed.deinit();
        return error.InvalidParameter;
    }
    return parsed;
}

fn integer(comptime T: type, value: std.json.Value) !T {
    if (value != .integer) return error.InvalidParameter;
    return std.math.cast(T, value.integer) orelse error.InvalidParameter;
}

fn optionalInteger(comptime T: type, value: std.json.Value, key: []const u8) !?T {
    const field = value.object.get(key) orelse return null;
    return try integer(T, field);
}

pub fn parseBounds(data: ?[]const u8) !Bounds {
    var parsed = try object(data orelse return error.MissingData);
    defer parsed.deinit();
    const value = parsed.value;
    const result: Bounds = .{
        .x = try optionalInteger(i32, value, "x"),
        .y = try optionalInteger(i32, value, "y"),
        .width = try optionalInteger(u32, value, "width"),
        .height = try optionalInteger(u32, value, "height"),
    };
    if (result.width == 0 or result.height == 0) return error.InvalidParameter;
    if (result.width) |width| {
        if (width > std.math.maxInt(c_int)) return error.InvalidParameter;
    }
    if (result.height) |height| {
        if (height > std.math.maxInt(c_int)) return error.InvalidParameter;
    }
    return result;
}

pub fn parseSize(data: ?[]const u8) !Size {
    var parsed = try object(data orelse return error.MissingData);
    defer parsed.deinit();
    const value = parsed.value;
    const width = try integer(u32, value.object.get("width") orelse return error.InvalidParameter);
    const height = try integer(u32, value.object.get("height") orelse return error.InvalidParameter);
    if (width == 0 or height == 0 or width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int))
        return error.InvalidParameter;
    return .{ .width = width, .height = height };
}

/// Creation options may constrain one axis without constraining the other.
/// Use effective no-op limits on omitted axes so both GTK and Win32 can keep
/// a single pair of minimum/maximum dimensions per native window.
pub fn parseCreateLimits(data: ?[]const u8) !Limits {
    var parsed = try object(data orelse return error.MissingData);
    defer parsed.deinit();
    const value = parsed.value;
    const min_width = try optionalInteger(u32, value, "minWidth");
    const min_height = try optionalInteger(u32, value, "minHeight");
    const max_width = try optionalInteger(u32, value, "maxWidth");
    const max_height = try optionalInteger(u32, value, "maxHeight");
    const limit: u32 = std.math.maxInt(c_int);
    var limits: Limits = .{};
    if (min_width != null or min_height != null) {
        const size: Size = .{ .width = min_width orelse 1, .height = min_height orelse 1 };
        if (size.width == 0 or size.height == 0 or size.width > limit or size.height > limit) return error.InvalidParameter;
        limits = try limits.withMinimum(size);
    }
    if (max_width != null or max_height != null) {
        const size: Size = .{ .width = max_width orelse limit, .height = max_height orelse limit };
        if (size.width == 0 or size.height == 0 or size.width > limit or size.height > limit) return error.InvalidParameter;
        limits = try limits.withMaximum(size);
    }
    return limits;
}

pub fn parseBool(data: ?[]const u8, key: []const u8) !bool {
    var parsed = try object(data orelse return error.MissingData);
    defer parsed.deinit();
    const value = parsed.value.object.get(key) orelse return error.InvalidParameter;
    if (value != .bool) return error.InvalidParameter;
    return value.bool;
}

test "partial bounds preserve missing fields and reject invalid dimensions" {
    const only_x = try parseBounds("{\"x\":-12,\"animate\":true}");
    try std.testing.expectEqual(@as(?i32, -12), only_x.x);
    try std.testing.expect(only_x.y == null and only_x.width == null and only_x.height == null);
    try std.testing.expectError(error.InvalidParameter, parseBounds("{\"width\":0}"));
    try std.testing.expectError(error.InvalidParameter, parseBounds("{\"width\":1.5}"));
    try std.testing.expectError(error.InvalidParameter, parseBounds("{\"x\":2147483648}"));
}

test "size limits reject crossing and clamp programmatic sizes" {
    var limits: Limits = .{};
    limits = try limits.withMinimum(.{ .width = 320, .height = 240 });
    limits = try limits.withMaximum(.{ .width = 1024, .height = 768 });
    try std.testing.expectError(error.InvalidParameter, limits.withMinimum(.{ .width = 1200, .height = 240 }));
    try std.testing.expectError(error.InvalidParameter, limits.withMaximum(.{ .width = 100, .height = 768 }));
    try std.testing.expectEqualDeep(Size{ .width = 320, .height = 768 }, limits.clamp(.{ .width = 100, .height = 900 }));
    try std.testing.expectError(error.InvalidParameter, parseSize("{\"width\":-1,\"height\":200}"));
}

test "portable control inputs require actual JSON booleans and integers" {
    try std.testing.expect(try parseBool("{\"fullscreen\":true}", "fullscreen"));
    try std.testing.expect(!(try parseBool("{\"resizable\":false}", "resizable")));
    try std.testing.expectError(error.InvalidParameter, parseBool("{\"fullscreen\":1}", "fullscreen"));
    try std.testing.expectError(error.InvalidParameter, parseBool("{\"fullscreen\":null}", "fullscreen"));
    try std.testing.expectError(error.InvalidParameter, parseSize("{\"width\":640.5,\"height\":480}"));
    try std.testing.expectError(error.InvalidParameter, parseSize("{\"width\":640,\"height\":0}"));
}

test "centering uses the selected monitor workarea including negative origins" {
    try std.testing.expectEqualDeep(Position{ .x = -1360, .y = 300 }, try centerIn(
        .{ .x = -1920, .y = 0, .width = 1920, .height = 1080 },
        .{ .width = 800, .height = 480 },
    ));
    try std.testing.expectEqualDeep(Position{ .x = 200, .y = 150 }, try centerIn(
        .{ .x = 0, .y = 0, .width = 1200, .height = 900 },
        .{ .width = 800, .height = 600 },
    ));
}

test "creation limits preserve unconstrained axes and reject conflicts" {
    const width_only = try parseCreateLimits("{\"minWidth\":320,\"maxWidth\":1024}");
    try std.testing.expectEqualDeep(Size{ .width = 320, .height = 1 }, width_only.minimum.?);
    try std.testing.expectEqualDeep(Size{ .width = 1024, .height = std.math.maxInt(c_int) }, width_only.maximum.?);
    try std.testing.expectError(error.InvalidParameter, parseCreateLimits("{\"minWidth\":900,\"maxWidth\":800}"));
    try std.testing.expectError(error.InvalidParameter, parseCreateLimits("{\"maxHeight\":0}"));
    try std.testing.expectError(error.InvalidParameter, parseCreateLimits("{\"minWidth\":1.5}"));
}
