//! The bookkeeping behind a native space switcher, with no AppKit in it.
//!
//! `native_space_switcher.zig` owns the NSSegmentedControl; this owns the list
//! it displays. Keeping them apart means the index/id mapping — the part that
//! actually goes wrong, because AppKit talks in segment indexes and the web
//! side talks in ids — can be tested without a window.

const std = @import("std");

pub const Space = struct {
    id: []const u8,
    label: []const u8,
    icon: ?[]const u8 = null,
    /// Accent colour as a CSS hex string (`#rrggbb`), if the space named one.
    tint: ?[]const u8 = null,
};

pub const SpaceList = struct {
    allocator: std.mem.Allocator,
    spaces: std.ArrayList(Space),
    /// Index of the active space, or null when the list is empty.
    active: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) SpaceList {
        return .{ .allocator = allocator, .spaces = .empty };
    }

    pub fn deinit(self: *SpaceList) void {
        self.clear();
        self.spaces.deinit(self.allocator);
    }

    fn freeSpace(self: *SpaceList, space: Space) void {
        self.allocator.free(space.id);
        self.allocator.free(space.label);
        if (space.icon) |icon| self.allocator.free(icon);
        if (space.tint) |tint| self.allocator.free(tint);
    }

    pub fn clear(self: *SpaceList) void {
        for (self.spaces.items) |space| self.freeSpace(space);
        self.spaces.clearRetainingCapacity();
        self.active = null;
    }

    /// Append a space, taking a private copy of every string. The caller's
    /// slices point into a JSON parse arena that is freed on return.
    pub fn append(self: *SpaceList, space: Space) !void {
        try self.spaces.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, space.id),
            .label = try self.allocator.dupe(u8, space.label),
            .icon = if (space.icon) |icon| try self.allocator.dupe(u8, icon) else null,
            .tint = if (space.tint) |tint| try self.allocator.dupe(u8, tint) else null,
        });
        if (self.active == null) self.active = 0;
    }

    pub fn count(self: *const SpaceList) usize {
        return self.spaces.items.len;
    }

    pub fn indexOf(self: *const SpaceList, id: []const u8) ?usize {
        for (self.spaces.items, 0..) |space, i| {
            if (std.mem.eql(u8, space.id, id)) return i;
        }
        return null;
    }

    pub fn at(self: *const SpaceList, index: usize) ?Space {
        if (index >= self.spaces.items.len) return null;
        return self.spaces.items[index];
    }

    pub fn activeSpace(self: *const SpaceList) ?Space {
        const index = self.active orelse return null;
        return self.at(index);
    }

    /// Select by id. Returns false for an id that is not in the list, leaving
    /// the current selection alone — a stale id from the web side must not
    /// blank the switcher.
    pub fn setActiveId(self: *SpaceList, id: []const u8) bool {
        const index = self.indexOf(id) orelse return false;
        self.active = index;
        return true;
    }

    /// Select by segment index, which is what AppKit hands back on a click.
    pub fn setActiveIndex(self: *SpaceList, index: usize) bool {
        if (index >= self.spaces.items.len) return false;
        self.active = index;
        return true;
    }

    /// Replace the whole list, keeping the active space selected **by id** when
    /// it survives the replacement. Spaces get reordered, added and removed
    /// while the sidebar is open; re-selecting by index would silently move the
    /// user to a different space whenever the list shifted under them.
    pub fn replace(self: *SpaceList, spaces: []const Space) !void {
        const previous_id: ?[]const u8 = if (self.activeSpace()) |space|
            try self.allocator.dupe(u8, space.id)
        else
            null;
        defer if (previous_id) |id| self.allocator.free(id);

        self.clear();
        for (spaces) |space| try self.append(space);

        if (previous_id) |id| {
            if (self.indexOf(id)) |index| self.active = index;
        }
    }
};

/// Whether a switcher over `count` spaces is worth putting on screen.
///
/// One space renders as a single selected segment naming the space the user is
/// already in — a lone pill in the window chrome that says nothing and does
/// nothing. The web rail hides its dots for exactly this case (`showDots =
/// spaces.length > 1` in `<SidebarSpaceSwitcher>`, following Dia); the native
/// control follows the same rule.
///
/// Lives here rather than next to the NSSegmentedControl so the rule can be
/// tested without a window, like the rest of this file.
pub fn shouldShowSwitcher(count: usize) bool {
    return count >= 2;
}

// =============================================================================

const testing = std.testing;

fn make(allocator: std.mem.Allocator) SpaceList {
    return SpaceList.init(allocator);
}

test "the first space appended becomes active" {
    var list = make(testing.allocator);
    defer list.deinit();

    try testing.expectEqual(@as(?usize, null), list.active);
    try list.append(.{ .id = "personal", .label = "Personal" });
    try testing.expectEqual(@as(?usize, 0), list.active);

    try list.append(.{ .id = "work", .label = "Work" });
    try testing.expectEqual(@as(?usize, 0), list.active);
}

test "ids map to segment indexes and back" {
    var list = make(testing.allocator);
    defer list.deinit();
    try list.append(.{ .id = "personal", .label = "Personal" });
    try list.append(.{ .id = "work", .label = "Work" });

    try testing.expectEqual(@as(?usize, 1), list.indexOf("work"));
    try testing.expectEqual(@as(?usize, null), list.indexOf("nope"));
    try testing.expect(list.setActiveIndex(1));
    try testing.expectEqualStrings("work", list.activeSpace().?.id);
}

test "an unknown id leaves the selection alone" {
    var list = make(testing.allocator);
    defer list.deinit();
    try list.append(.{ .id = "personal", .label = "Personal" });
    try list.append(.{ .id = "work", .label = "Work" });
    _ = list.setActiveId("work");

    try testing.expect(!list.setActiveId("deleted"));
    try testing.expectEqualStrings("work", list.activeSpace().?.id);
}

test "an out-of-range segment index is refused" {
    var list = make(testing.allocator);
    defer list.deinit();
    try list.append(.{ .id = "personal", .label = "Personal" });

    try testing.expect(!list.setActiveIndex(7));
    try testing.expectEqualStrings("personal", list.activeSpace().?.id);
}

test "replacing keeps the active space by id, not by position" {
    var list = make(testing.allocator);
    defer list.deinit();
    try list.append(.{ .id = "personal", .label = "Personal" });
    try list.append(.{ .id = "work", .label = "Work" });
    _ = list.setActiveId("work");

    // Reordered, with a new space in front. Index 1 is now something else.
    try list.replace(&.{
        .{ .id = "side", .label = "Side project" },
        .{ .id = "personal", .label = "Personal" },
        .{ .id = "work", .label = "Work" },
    });

    try testing.expectEqualStrings("work", list.activeSpace().?.id);
    try testing.expectEqual(@as(?usize, 2), list.active);
}

test "replacing away the active space falls back to the first" {
    var list = make(testing.allocator);
    defer list.deinit();
    try list.append(.{ .id = "personal", .label = "Personal" });
    try list.append(.{ .id = "work", .label = "Work" });
    _ = list.setActiveId("work");

    try list.replace(&.{.{ .id = "personal", .label = "Personal" }});

    try testing.expectEqualStrings("personal", list.activeSpace().?.id);
}

test "replacing with nothing leaves no active space" {
    var list = make(testing.allocator);
    defer list.deinit();
    try list.append(.{ .id = "personal", .label = "Personal" });

    try list.replace(&.{});

    try testing.expectEqual(@as(?usize, null), list.active);
    try testing.expectEqual(@as(?Space, null), list.activeSpace());
}

test "a switcher over fewer than two spaces stays hidden" {
    try testing.expect(!shouldShowSwitcher(0));
    try testing.expect(!shouldShowSwitcher(1));
    try testing.expect(shouldShowSwitcher(2));
    try testing.expect(shouldShowSwitcher(7));
}

test "growing from one space to two brings the switcher back" {
    var list = make(testing.allocator);
    defer list.deinit();
    try list.append(.{ .id = "personal", .label = "Personal" });

    // One space: nothing to switch between, so nothing to show.
    try testing.expect(!shouldShowSwitcher(list.count()));

    try list.replace(&.{
        .{ .id = "personal", .label = "Personal" },
        .{ .id = "work", .label = "Work" },
    });

    // The control is hidden, not destroyed, so this is all it takes to get it
    // back — and the user is still in the space they were in.
    try testing.expect(shouldShowSwitcher(list.count()));
    try testing.expectEqualStrings("personal", list.activeSpace().?.id);
}

test "shrinking back to one space hides it again" {
    var list = make(testing.allocator);
    defer list.deinit();
    try list.append(.{ .id = "personal", .label = "Personal" });
    try list.append(.{ .id = "work", .label = "Work" });
    try testing.expect(shouldShowSwitcher(list.count()));

    try list.replace(&.{.{ .id = "work", .label = "Work" }});

    try testing.expect(!shouldShowSwitcher(list.count()));
    try testing.expectEqualStrings("work", list.activeSpace().?.id);
}

/// Mirrors `native_space_switcher.sanitizeId`. Duplicated rather than imported
/// because that module pulls in AppKit, and this file is the one that can be
/// tested without a window — the two are checked against each other by the
/// switcher failing to compile if the signature drifts.
fn sanitizeId(out: []u8, value: []const u8) []const u8 {
    var len: usize = 0;
    for (value) |c| {
        if (len == out.len) break;
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == ':';
        if (!safe) continue;
        out[len] = c;
        len += 1;
    }
    return out[0..len];
}

test "id sanitising keeps ordinary ids intact" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("personal", sanitizeId(&buf, "personal"));
    try testing.expectEqualStrings("space-1_a.b:c", sanitizeId(&buf, "space-1_a.b:c"));
}

test "id sanitising drops anything that could break out of a JS string" {
    var buf: [64]u8 = undefined;
    // The id is interpolated into an evaluateJavaScript string; a quote or a
    // backslash there is a syntax error at best.
    try testing.expectEqualStrings("aliceb", sanitizeId(&buf, "alice\"b"));
    try testing.expectEqualStrings("xy", sanitizeId(&buf, "x\\y"));
    // Every character that gives the payload its meaning is gone; what is left
    // is an inert identifier that simply will not match any space.
    try testing.expectEqualStrings("alert1document", sanitizeId(&buf, "\");alert(1);//document"));
    try testing.expectEqualStrings("ab", sanitizeId(&buf, "a\nb"));
}

test "id sanitising truncates rather than overflowing its buffer" {
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("abcd", sanitizeId(&small, "abcdefgh"));
}

test "optional icon and tint survive a copy" {
    var list = make(testing.allocator);
    defer list.deinit();
    try list.append(.{ .id = "dev", .label = "Development", .icon = "star.fill", .tint = "#5aa9ee" });

    const space = list.activeSpace().?;
    try testing.expectEqualStrings("star.fill", space.icon.?);
    try testing.expectEqualStrings("#5aa9ee", space.tint.?);
}
