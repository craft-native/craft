const std = @import("std");

/// The AppKit key equivalent for the key token of a shortcut string like
/// `"cmd+delete"` or `"cmd+shift+up"`.
///
/// A menu item's key equivalent is the character the key produces, which is
/// fine for `"cmd+n"` and useless for the keys that produce no printable
/// character. Passing the token through literally gave `"cmd+delete"` the key
/// equivalent `"delete"`: AppKit takes the first character, so the item was
/// bound to Cmd+D and drew as ⌘D. Arrows, Return, Escape and the function keys
/// had the same fate. Those keys are spelled by name here and translated to
/// the characters AppKit actually matches against: the ASCII control
/// characters for Backspace, Return, Tab and Escape, and the private-use
/// function-key code points (`NSUpArrowFunctionKey` = U+F700 and friends) as
/// UTF-8 for the rest.
///
/// `"plus"` and `"minus"` exist because `+` is the separator, so `"cmd++"`
/// cannot be written. Anything unrecognised is returned unchanged, which keeps
/// every existing single-character shortcut working exactly as before.
pub fn keyEquivalent(token: []const u8) []const u8 {
    for (named_keys) |entry| {
        if (std.ascii.eqlIgnoreCase(token, entry.name)) return entry.chars;
    }
    return token;
}

const NamedKey = struct { name: []const u8, chars: []const u8 };

const named_keys = [_]NamedKey{
    // On a Mac keyboard the key labelled "delete" is Backspace (⌫).
    .{ .name = "delete", .chars = "\x08" },
    .{ .name = "backspace", .chars = "\x08" },
    .{ .name = "forwarddelete", .chars = "\u{F728}" },
    .{ .name = "return", .chars = "\r" },
    .{ .name = "enter", .chars = "\r" },
    .{ .name = "escape", .chars = "\x1b" },
    .{ .name = "esc", .chars = "\x1b" },
    .{ .name = "tab", .chars = "\t" },
    .{ .name = "space", .chars = " " },
    .{ .name = "plus", .chars = "+" },
    .{ .name = "minus", .chars = "-" },
    .{ .name = "up", .chars = "\u{F700}" },
    .{ .name = "down", .chars = "\u{F701}" },
    .{ .name = "left", .chars = "\u{F702}" },
    .{ .name = "right", .chars = "\u{F703}" },
    .{ .name = "home", .chars = "\u{F729}" },
    .{ .name = "end", .chars = "\u{F72B}" },
    .{ .name = "pageup", .chars = "\u{F72C}" },
    .{ .name = "pagedown", .chars = "\u{F72D}" },
    .{ .name = "f1", .chars = "\u{F704}" },
    .{ .name = "f2", .chars = "\u{F705}" },
    .{ .name = "f3", .chars = "\u{F706}" },
    .{ .name = "f4", .chars = "\u{F707}" },
    .{ .name = "f5", .chars = "\u{F708}" },
    .{ .name = "f6", .chars = "\u{F709}" },
    .{ .name = "f7", .chars = "\u{F70A}" },
    .{ .name = "f8", .chars = "\u{F70B}" },
    .{ .name = "f9", .chars = "\u{F70C}" },
    .{ .name = "f10", .chars = "\u{F70D}" },
    .{ .name = "f11", .chars = "\u{F70E}" },
    .{ .name = "f12", .chars = "\u{F70F}" },
};

test "named keys become the characters AppKit matches" {
    try std.testing.expectEqualStrings("\x08", keyEquivalent("delete"));
    try std.testing.expectEqualStrings("\x08", keyEquivalent("Backspace"));
    try std.testing.expectEqualStrings("\r", keyEquivalent("enter"));
    try std.testing.expectEqualStrings("\x1b", keyEquivalent("ESC"));
    try std.testing.expectEqualStrings("+", keyEquivalent("plus"));
}

test "arrows and function keys are the private-use code points as UTF-8" {
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0x9C, 0x80 }, keyEquivalent("up"));
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0x9C, 0x83 }, keyEquivalent("right"));
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0x9C, 0xA8 }, keyEquivalent("forwarddelete"));
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0x9C, 0x8F }, keyEquivalent("f12"));
}

test "single characters and unknown names pass through unchanged" {
    try std.testing.expectEqualStrings("n", keyEquivalent("n"));
    try std.testing.expectEqualStrings(",", keyEquivalent(","));
    try std.testing.expectEqualStrings("N", keyEquivalent("N"));
    try std.testing.expectEqualStrings("hyper", keyEquivalent("hyper"));
}
