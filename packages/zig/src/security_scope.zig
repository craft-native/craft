//! Folders the person granted a sandboxed app, kept across launches.
//!
//! The App Sandbox confines an app to its container. The supported way out is
//! for the person to choose a folder in an Open panel: Powerbox then extends
//! the sandbox to that folder for the life of the process, and a
//! security-scoped bookmark lets the app reopen it on later launches without
//! asking again.
//!
//! Only the UI process can show the panel, create the bookmark or resolve it.
//! A bundled backend runs as a child with `com.apple.security.inherit`, and a
//! child inherits the sandbox extensions its parent holds when it is spawned,
//! not ones the parent gains later. So access is restored here before the
//! backend starts, and a new grant restarts the backend (see
//! `bundle_backend.restartManaged`). The backend learns which folders it can
//! reach from `CRAFT_SECURITY_SCOPED_PATHS`, one absolute path per line.
const std = @import("std");
const builtin = @import("builtin");

/// The environment variable a managed backend reads its granted folders from.
pub const env_key = "CRAFT_SECURITY_SCOPED_PATHS";

/// The `NSUserDefaults` key holding the bookmarks, an array of `NSData`.
/// Defaults live inside the app's container, so they belong to this app alone.
const defaults_key = "CraftSecurityScopedBookmarks";

const NSURLBookmarkCreationWithSecurityScope: c_ulong = 1 << 11;
const NSURLBookmarkResolutionWithoutUI: c_ulong = 1 << 8;
const NSURLBookmarkResolutionWithSecurityScope: c_ulong = 1 << 10;

const Grant = struct {
    path: []u8,
    /// The resolved, retained `NSURL` whose scope this process is inside.
    url: ?*anyopaque,
};

var grants: std.ArrayList(Grant) = .empty;
var restored = false;

fn allocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

/// Reopen every saved folder, before a backend is spawned. Bookmarks that no
/// longer resolve (the folder was deleted, or the app moved to a new Mac) are
/// dropped; stale ones are refreshed. Safe to call more than once.
pub fn restore() void {
    if (comptime builtin.os.tag != .macos) return;
    if (restored) return;
    restored = true;
    const macos = @import("macos.zig");

    const defaults = macos.msgSend0(macos.getClass("NSUserDefaults"), "standardUserDefaults");
    const saved = macos.msgSend1(defaults, "arrayForKey:", macos.createNSString(defaults_key));
    if (saved == null) return;

    var changed = false;
    const count = macos.msgSend0Ulong(saved, "count");
    var index: c_ulong = 0;
    while (index < count) : (index += 1) {
        const data = macos.msgSend1(saved, "objectAtIndex:", index);
        var stale: i8 = 0;
        var err: ?*anyopaque = null;
        const resolve = @as(*const fn (?*anyopaque, macos.objc.SEL, ?*anyopaque, c_ulong, ?*anyopaque, *i8, *?*anyopaque) callconv(.c) ?*anyopaque, @ptrCast(&macos.objc.objc_msgSend));
        const url = resolve(
            macos.getClass("NSURL"),
            macos.sel("URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:"),
            data,
            NSURLBookmarkResolutionWithSecurityScope | NSURLBookmarkResolutionWithoutUI,
            null,
            &stale,
            &err,
        );
        if (url == null) {
            changed = true;
            continue;
        }
        if (!macos.msgSendBool(url, "startAccessingSecurityScopedResource")) {
            changed = true;
            continue;
        }
        if (stale != 0) changed = true;
        adopt(url) catch continue;
    }
    if (changed) save();
}

/// Hold a URL whose scope has been entered, unless that folder is held already.
fn adopt(url: ?*anyopaque) !void {
    const macos = @import("macos.zig");
    const path = try nsStringToOwned(macos.msgSend0(url, "path"));
    errdefer allocator().free(path);
    for (grants.items) |held| {
        if (std.mem.eql(u8, held.path, path)) {
            macos.msgSendVoid0(url, "stopAccessingSecurityScopedResource");
            allocator().free(path);
            return;
        }
    }
    _ = macos.msgSend0(url, "retain");
    try grants.append(allocator(), .{ .path = path, .url = url });
}

/// Rewrite the saved bookmarks from the folders held now. Creating a bookmark
/// from a URL inside its scope also refreshes one that had gone stale.
fn save() void {
    const macos = @import("macos.zig");
    const array = macos.msgSend0(macos.getClass("NSMutableArray"), "array");
    for (grants.items) |held| {
        if (bookmark(held.url)) |data| _ = macos.msgSend1(array, "addObject:", data);
    }
    const defaults = macos.msgSend0(macos.getClass("NSUserDefaults"), "standardUserDefaults");
    _ = macos.msgSend2(defaults, "setObject:forKey:", array, macos.createNSString(defaults_key));
}

fn bookmark(url: ?*anyopaque) ?*anyopaque {
    const macos = @import("macos.zig");
    var err: ?*anyopaque = null;
    const create = @as(*const fn (?*anyopaque, macos.objc.SEL, c_ulong, ?*anyopaque, ?*anyopaque, *?*anyopaque) callconv(.c) ?*anyopaque, @ptrCast(&macos.objc.objc_msgSend));
    return create(
        url,
        macos.sel("bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:"),
        NSURLBookmarkCreationWithSecurityScope,
        null,
        null,
        &err,
    );
}

/// Keep access to a folder the person just chose in an Open panel. Returns
/// false when macOS would not make a bookmark of it.
pub fn grant(url: ?*anyopaque) bool {
    if (comptime builtin.os.tag != .macos) return false;
    restore();
    const macos = @import("macos.zig");
    // A URL from the panel is already inside its scope for this process;
    // entering it again balances the stop a later revoke sends.
    _ = macos.msgSendBool(url, "startAccessingSecurityScopedResource");
    if (bookmark(url) == null) return false;
    adopt(url) catch return false;
    save();
    return true;
}

/// Forget a folder. Returns whether it was held.
pub fn revoke(path: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    restore();
    const macos = @import("macos.zig");
    for (grants.items, 0..) |held, index| {
        if (!std.mem.eql(u8, held.path, path)) continue;
        macos.msgSendVoid0(held.url, "stopAccessingSecurityScopedResource");
        _ = macos.msgSend0(held.url, "release");
        allocator().free(held.path);
        _ = grants.orderedRemove(index);
        save();
        return true;
    }
    return false;
}

/// The held folders, one per line, for `env_key`. Caller owns the slice.
pub fn joinedPaths(alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (grants.items, 0..) |held, index| {
        if (index > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, held.path);
    }
    return out.toOwnedSlice(alloc);
}

/// `{"paths":[...]}` plus any extra fields already formatted as `,"k":v`.
pub fn pathsJson(alloc: std.mem.Allocator, extra: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"paths\":[");
    for (grants.items, 0..) |held, index| {
        if (index > 0) try out.append(alloc, ',');
        try appendJsonString(alloc, &out, held.path);
    }
    try out.append(alloc, ']');
    try out.appendSlice(alloc, extra);
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

pub fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(alloc, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0...8, 11, 12, 14...0x1f => {
                var buf: [6]u8 = undefined;
                try out.appendSlice(alloc, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable);
            },
            else => try out.append(alloc, ch),
        }
    }
    try out.append(alloc, '"');
}

fn nsStringToOwned(ns: ?*anyopaque) ![]u8 {
    if (ns == null) return error.MissingPath;
    const macos = @import("macos.zig");
    const cstr = macos.msgSend0(ns, "UTF8String");
    if (cstr == null) return error.MissingPath;
    return allocator().dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(cstr))));
}

test "granted paths are escaped as JSON strings" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendJsonString(std.testing.allocator, &out, "/Users/a \"b\"\\c\n");
    try std.testing.expectEqualStrings("\"/Users/a \\\"b\\\"\\\\c\\n\"", out.items);
}
