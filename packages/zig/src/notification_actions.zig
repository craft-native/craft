//! Notification action buttons, and what comes back when one is pressed.
//!
//! A `UNNotificationCategory` is what puts buttons on a banner: the content
//! names a category, the category holds the actions, and the response names
//! the action that was pressed. Categories are registered against the
//! notification centre as a **set** — `setNotificationCategories:` replaces
//! whatever was there — so they cannot be created per notification and thrown
//! away. They have to be identified by their shape and reused.
//!
//! That identity is the interesting part, and it is pure, so it lives here
//! with tests rather than inside the Objective-C. Same buttons in the same
//! order means the same category; a different label, a different id, or the
//! same two buttons the other way round means a different one, because the
//! order is what the user sees.

const std = @import("std");

/// One button on a banner.
pub const Action = struct {
    /// What comes back in `craft:notification:action`. The app's own name for
    /// the button.
    id: []const u8,
    /// What the button says.
    label: []const u8,
};

/// How many buttons a notification may declare.
///
/// macOS shows two on a banner and puts the rest behind an "Options"
/// disclosure, so past four the extra ones are effectively a menu the user has
/// to go looking for. Refusing beyond that is more honest than silently
/// registering buttons nobody will find.
pub const max_actions = 4;

pub const Error = error{
    TooManyActions,
    EmptyActionId,
    EmptyActionLabel,
    DuplicateActionId,
    ActionIdTooLong,
};

/// Longest action id accepted. Ids travel into a category identifier and back
/// out through a JSON event; a bound here keeps both sides off the heap.
pub const max_id_len = 64;

pub fn validate(actions: []const Action) Error!void {
    if (actions.len > max_actions) return Error.TooManyActions;
    for (actions, 0..) |action, i| {
        if (action.id.len == 0) return Error.EmptyActionId;
        if (action.id.len > max_id_len) return Error.ActionIdTooLong;
        // A button with no text is a button the user cannot read. Rendering it
        // blank and letting them guess is worse than saying no.
        if (action.label.len == 0) return Error.EmptyActionLabel;
        // Two buttons with one id means the response cannot say which was
        // pressed — for an Approve/Deny prompt that is the whole answer.
        for (actions[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.id, action.id)) return Error.DuplicateActionId;
        }
    }
}

/// A stable identifier for the category these actions form.
///
/// Derived from the actions themselves so an app that posts the same
/// Approve/Deny prompt a thousand times registers one category, not a
/// thousand. Written into `buf`, which must hold `category_id_len` bytes.
///
/// FNV-1a over the ids and labels, each length-prefixed. The prefixes are what
/// stop `{"ab","c"}` and `{"a","bc"}` hashing the same, which a plain
/// concatenation would allow — and that collision would put one notification's
/// buttons on another's banner.
pub const category_id_len = "craft.actions.".len + 16;

pub fn categoryId(actions: []const Action, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= category_id_len);

    var hash: u64 = 0xcbf29ce484222325;
    const prime: u64 = 0x100000001b3;

    const mix = struct {
        fn byte(h: *u64, p: u64, b: u8) void {
            h.* = (h.* ^ b) *% p;
        }
        fn slice(h: *u64, p: u64, s: []const u8) void {
            // Length first, so the boundary between fields is part of what is
            // hashed rather than something the reader has to infer.
            var len: u64 = s.len;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                byte(h, p, @truncate(len));
                len >>= 8;
            }
            for (s) |c| byte(h, p, c);
        }
    };

    mix.slice(&hash, prime, std.mem.asBytes(&actions.len));
    for (actions) |action| {
        mix.slice(&hash, prime, action.id);
        mix.slice(&hash, prime, action.label);
    }

    _ = std.fmt.bufPrint(buf, "craft.actions.{x:0>16}", .{hash}) catch unreachable;
    return buf[0..category_id_len];
}

// =============================================================================
// What came back
// =============================================================================

/// Apple's two built-in response identifiers. A response always names an
/// action; for a plain tap or a swipe-away it names one of these.
pub const default_action_id = "com.apple.UNNotificationDefaultActionIdentifier";
pub const dismiss_action_id = "com.apple.UNNotificationDismissActionIdentifier";

pub const Response = union(enum) {
    /// The banner itself was clicked. `craft:notification:click`.
    opened,
    /// Swiped away or cleared. Reported as an action so an app waiting on an
    /// answer hears that there will not be one, rather than waiting forever.
    dismissed,
    /// One of the app's own buttons. `craft:notification:action`.
    action: []const u8,
};

/// Classify the `actionIdentifier` of a `UNNotificationResponse`.
pub fn classify(action_identifier: []const u8) Response {
    if (std.mem.eql(u8, action_identifier, default_action_id)) return .opened;
    if (std.mem.eql(u8, action_identifier, dismiss_action_id)) return .dismissed;
    return .{ .action = action_identifier };
}

/// The `actionId` the page sees for a dismissal. Deliberately not Apple's
/// reverse-DNS constant: the page's vocabulary is the ids the app chose, and
/// `"dismiss"` belongs in it.
pub const dismiss_public_id = "dismiss";

const testing = std.testing;

test "the same buttons produce the same category" {
    var a: [category_id_len]u8 = undefined;
    var b: [category_id_len]u8 = undefined;
    const actions = [_]Action{
        .{ .id = "approve", .label = "Approve" },
        .{ .id = "deny", .label = "Deny" },
    };
    try testing.expectEqualStrings(categoryId(&actions, &a), categoryId(&actions, &b));
}

test "different buttons produce different categories" {
    var a: [category_id_len]u8 = undefined;
    var b: [category_id_len]u8 = undefined;
    const approve_deny = [_]Action{
        .{ .id = "approve", .label = "Approve" },
        .{ .id = "deny", .label = "Deny" },
    };
    const yes_no = [_]Action{
        .{ .id = "yes", .label = "Yes" },
        .{ .id = "no", .label = "No" },
    };
    try testing.expect(!std.mem.eql(u8, categoryId(&approve_deny, &a), categoryId(&yes_no, &b)));
}

test "the order of the buttons is part of the category" {
    // It is what the user sees, and a category reused across both orderings
    // would put Deny where the app drew Approve.
    var a: [category_id_len]u8 = undefined;
    var b: [category_id_len]u8 = undefined;
    const forward = [_]Action{
        .{ .id = "approve", .label = "Approve" },
        .{ .id = "deny", .label = "Deny" },
    };
    const reversed = [_]Action{
        .{ .id = "deny", .label = "Deny" },
        .{ .id = "approve", .label = "Approve" },
    };
    try testing.expect(!std.mem.eql(u8, categoryId(&forward, &a), categoryId(&reversed, &b)));
}

test "relabelling a button is a different category" {
    // Same ids, different text. Reusing the category would leave the old words
    // on the banner.
    var a: [category_id_len]u8 = undefined;
    var b: [category_id_len]u8 = undefined;
    const before = [_]Action{.{ .id = "ok", .label = "OK" }};
    const after = [_]Action{.{ .id = "ok", .label = "Got it" }};
    try testing.expect(!std.mem.eql(u8, categoryId(&before, &a), categoryId(&after, &b)));
}

test "a field boundary cannot be moved without changing the category" {
    // The classic concatenation collision: "ab"+"c" and "a"+"bc" are the same
    // bytes in a row. Length-prefixing is what separates them, and getting
    // this wrong would put one notification's buttons on another's banner.
    var a: [category_id_len]u8 = undefined;
    var b: [category_id_len]u8 = undefined;
    const one = [_]Action{.{ .id = "ab", .label = "c" }};
    const two = [_]Action{.{ .id = "a", .label = "bc" }};
    try testing.expect(!std.mem.eql(u8, categoryId(&one, &a), categoryId(&two, &b)));
}

test "no buttons still has a category, and it is its own" {
    var a: [category_id_len]u8 = undefined;
    var b: [category_id_len]u8 = undefined;
    const none = [_]Action{};
    const one = [_]Action{.{ .id = "x", .label = "X" }};
    try testing.expectEqual(category_id_len, categoryId(&none, &a).len);
    try testing.expect(!std.mem.eql(u8, categoryId(&none, &a), categoryId(&one, &b)));
}

test "a category identifier is always the same length" {
    // It is written into a fixed buffer on the Objective-C side, and a short
    // hash printed without padding would silently truncate the comparison.
    var buf: [category_id_len]u8 = undefined;
    for ([_][]const u8{ "a", "bb", "ccc", "dddd" }) |id| {
        const actions = [_]Action{.{ .id = id, .label = id }};
        try testing.expectEqual(category_id_len, categoryId(&actions, &buf).len);
        try testing.expect(std.mem.startsWith(u8, &buf, "craft.actions."));
    }
}

test "more buttons than macOS will show is refused" {
    const five = [_]Action{
        .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" },
        .{ .id = "c", .label = "C" }, .{ .id = "d", .label = "D" },
        .{ .id = "e", .label = "E" },
    };
    try testing.expectError(Error.TooManyActions, validate(&five));

    const four = five[0..4];
    try validate(four);
}

test "a button with no id or no label is refused" {
    try testing.expectError(Error.EmptyActionId, validate(&[_]Action{.{ .id = "", .label = "X" }}));
    try testing.expectError(Error.EmptyActionLabel, validate(&[_]Action{.{ .id = "x", .label = "" }}));
}

test "two buttons cannot share an id" {
    // The response would be unable to say which was pressed, which for
    // Approve/Deny is the entire answer.
    try testing.expectError(Error.DuplicateActionId, validate(&[_]Action{
        .{ .id = "same", .label = "First" },
        .{ .id = "same", .label = "Second" },
    }));
}

test "an id longer than the bound is refused" {
    var long: [max_id_len + 1]u8 = undefined;
    @memset(&long, 'x');
    try testing.expectError(Error.ActionIdTooLong, validate(&[_]Action{.{ .id = &long, .label = "X" }}));

    var at_limit: [max_id_len]u8 = undefined;
    @memset(&at_limit, 'x');
    try validate(&[_]Action{.{ .id = &at_limit, .label = "X" }});
}

test "no buttons at all is fine" {
    try validate(&[_]Action{});
}

test "a plain click is told apart from a button" {
    try testing.expectEqual(Response.opened, classify(default_action_id));
    try testing.expectEqual(Response.dismissed, classify(dismiss_action_id));
    switch (classify("approve")) {
        .action => |id| try testing.expectEqualStrings("approve", id),
        else => return error.TestUnexpectedResult,
    }
}

test "an app may name a button after Apple's constants without being mistaken for one" {
    // Only the exact reverse-DNS strings are Apple's. An app with a button
    // literally called "default" gets that id back, not an open event.
    switch (classify("default")) {
        .action => |id| try testing.expectEqualStrings("default", id),
        else => return error.TestUnexpectedResult,
    }
    switch (classify("dismiss")) {
        .action => |id| try testing.expectEqualStrings("dismiss", id),
        else => return error.TestUnexpectedResult,
    }
}
