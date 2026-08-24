//! macOS virtual key codes, and the accelerator strings that name them.
//!
//! One table, read in both directions. `bridge_shortcuts.zig` needs the
//! name→code direction to hand a key to `RegisterEventHotKey`, and the
//! code→name direction to describe a shortcut back to JavaScript. Those used
//! to be two independent switch statements, one of which did not exist — so
//! there was nothing to keep them agreeing.
//!
//! The codes are the `kVK_*` constants from `<Carbon/HIToolbox/Events.h>`.
//! They are positions on the keyboard, not characters: `kVK_ANSI_A` is 0
//! whatever the active layout prints there. That is exactly what a global
//! hotkey wants — the user who set Cmd+Shift+H keeps it after switching to
//! Dvorak, because the physical key is what was registered.

const std = @import("std");

pub const Entry = struct {
    /// The name craft uses in accelerators and reports back to JS.
    name: []const u8,
    code: u16,
};

/// The canonical name for each key: the one `nameFor` returns.
///
/// Order matters only in that the first entry for a code wins in `nameFor`;
/// aliases live in `aliases` below so they can never shadow a canonical name.
pub const table = [_]Entry{
    // Letters, in keyboard order rather than alphabetical — this is the
    // order Events.h lists them in, and matching it makes the constants
    // checkable against the header by eye.
    .{ .name = "A", .code = 0x00 },
    .{ .name = "S", .code = 0x01 },
    .{ .name = "D", .code = 0x02 },
    .{ .name = "F", .code = 0x03 },
    .{ .name = "H", .code = 0x04 },
    .{ .name = "G", .code = 0x05 },
    .{ .name = "Z", .code = 0x06 },
    .{ .name = "X", .code = 0x07 },
    .{ .name = "C", .code = 0x08 },
    .{ .name = "V", .code = 0x09 },
    .{ .name = "B", .code = 0x0B },
    .{ .name = "Q", .code = 0x0C },
    .{ .name = "W", .code = 0x0D },
    .{ .name = "E", .code = 0x0E },
    .{ .name = "R", .code = 0x0F },
    .{ .name = "Y", .code = 0x10 },
    .{ .name = "T", .code = 0x11 },
    .{ .name = "1", .code = 0x12 },
    .{ .name = "2", .code = 0x13 },
    .{ .name = "3", .code = 0x14 },
    .{ .name = "4", .code = 0x15 },
    .{ .name = "6", .code = 0x16 },
    .{ .name = "5", .code = 0x17 },
    .{ .name = "=", .code = 0x18 },
    .{ .name = "9", .code = 0x19 },
    .{ .name = "7", .code = 0x1A },
    .{ .name = "-", .code = 0x1B },
    .{ .name = "8", .code = 0x1C },
    .{ .name = "0", .code = 0x1D },
    .{ .name = "]", .code = 0x1E },
    .{ .name = "O", .code = 0x1F },
    .{ .name = "U", .code = 0x20 },
    .{ .name = "[", .code = 0x21 },
    .{ .name = "I", .code = 0x22 },
    .{ .name = "P", .code = 0x23 },
    .{ .name = "Return", .code = 0x24 },
    .{ .name = "L", .code = 0x25 },
    .{ .name = "J", .code = 0x26 },
    .{ .name = "'", .code = 0x27 },
    .{ .name = "K", .code = 0x28 },
    .{ .name = ";", .code = 0x29 },
    .{ .name = "\\", .code = 0x2A },
    .{ .name = ",", .code = 0x2B },
    .{ .name = "/", .code = 0x2C },
    .{ .name = "N", .code = 0x2D },
    .{ .name = "M", .code = 0x2E },
    .{ .name = ".", .code = 0x2F },
    .{ .name = "Tab", .code = 0x30 },
    .{ .name = "Space", .code = 0x31 },
    .{ .name = "`", .code = 0x32 },
    // `kVK_Delete` is the key labelled Delete on a Mac keyboard, which sends
    // backspace. The one labelled Delete on a PC keyboard is
    // `kVK_ForwardDelete` below. Both spellings are accepted; see `aliases`.
    .{ .name = "Delete", .code = 0x33 },
    .{ .name = "Escape", .code = 0x35 },

    // Keypad. Distinct codes from the number row, so a shortcut bound to
    // keypad 5 does not fire on the 5 above the T.
    .{ .name = "KeypadDecimal", .code = 0x41 },
    .{ .name = "KeypadMultiply", .code = 0x43 },
    .{ .name = "KeypadPlus", .code = 0x45 },
    .{ .name = "KeypadClear", .code = 0x47 },
    .{ .name = "KeypadDivide", .code = 0x4B },
    .{ .name = "KeypadEnter", .code = 0x4C },
    .{ .name = "KeypadMinus", .code = 0x4E },
    .{ .name = "KeypadEquals", .code = 0x51 },
    .{ .name = "Keypad0", .code = 0x52 },
    .{ .name = "Keypad1", .code = 0x53 },
    .{ .name = "Keypad2", .code = 0x54 },
    .{ .name = "Keypad3", .code = 0x55 },
    .{ .name = "Keypad4", .code = 0x56 },
    .{ .name = "Keypad5", .code = 0x57 },
    .{ .name = "Keypad6", .code = 0x58 },
    .{ .name = "Keypad7", .code = 0x59 },
    .{ .name = "Keypad8", .code = 0x5B },
    .{ .name = "Keypad9", .code = 0x5C },

    // Function keys. Note that the codes are not in numeric order — F5 comes
    // before F3 — which is why writing them out beats computing them.
    .{ .name = "F1", .code = 0x7A },
    .{ .name = "F2", .code = 0x78 },
    .{ .name = "F3", .code = 0x63 },
    .{ .name = "F4", .code = 0x76 },
    .{ .name = "F5", .code = 0x60 },
    .{ .name = "F6", .code = 0x61 },
    .{ .name = "F7", .code = 0x62 },
    .{ .name = "F8", .code = 0x64 },
    .{ .name = "F9", .code = 0x65 },
    .{ .name = "F10", .code = 0x6D },
    .{ .name = "F11", .code = 0x67 },
    .{ .name = "F12", .code = 0x6F },
    .{ .name = "F13", .code = 0x69 },
    .{ .name = "F14", .code = 0x6B },
    .{ .name = "F15", .code = 0x71 },
    .{ .name = "F16", .code = 0x6A },
    .{ .name = "F17", .code = 0x40 },
    .{ .name = "F18", .code = 0x4F },
    .{ .name = "F19", .code = 0x50 },
    .{ .name = "F20", .code = 0x5A },

    // Navigation and editing.
    .{ .name = "Help", .code = 0x72 },
    .{ .name = "Home", .code = 0x73 },
    .{ .name = "PageUp", .code = 0x74 },
    .{ .name = "ForwardDelete", .code = 0x75 },
    .{ .name = "End", .code = 0x77 },
    .{ .name = "PageDown", .code = 0x79 },
    .{ .name = "Left", .code = 0x7B },
    .{ .name = "Right", .code = 0x7C },
    .{ .name = "Down", .code = 0x7D },
    .{ .name = "Up", .code = 0x7E },
};

/// Extra spellings accepted by `codeFor`, never returned by `nameFor`.
///
/// The point is that an accelerator copied out of an Electron app, a web
/// `KeyboardEvent.key`, or a Mac keyboard's own labelling all resolve to the
/// same key rather than failing registration.
const aliases = [_]Entry{
    .{ .name = "Backspace", .code = 0x33 },
    .{ .name = "Esc", .code = 0x35 },
    .{ .name = "Enter", .code = 0x24 },
    .{ .name = "Plus", .code = 0x18 },
    .{ .name = "Equal", .code = 0x18 },
    .{ .name = "Minus", .code = 0x1B },
    .{ .name = "Comma", .code = 0x2B },
    .{ .name = "Period", .code = 0x2F },
    .{ .name = "Slash", .code = 0x2C },
    .{ .name = "Backslash", .code = 0x2A },
    .{ .name = "Semicolon", .code = 0x29 },
    .{ .name = "Quote", .code = 0x27 },
    .{ .name = "Backquote", .code = 0x32 },
    .{ .name = "Grave", .code = 0x32 },
    .{ .name = "BracketLeft", .code = 0x21 },
    .{ .name = "BracketRight", .code = 0x1E },
    .{ .name = "Del", .code = 0x75 },
    .{ .name = "ArrowLeft", .code = 0x7B },
    .{ .name = "ArrowRight", .code = 0x7C },
    .{ .name = "ArrowDown", .code = 0x7D },
    .{ .name = "ArrowUp", .code = 0x7E },
    .{ .name = "PgUp", .code = 0x74 },
    .{ .name = "PgDn", .code = 0x79 },
};

/// The virtual key code named by `name`, or null if nothing is.
///
/// Case-insensitive: an app writing `cmd+shift+h` means the same key as one
/// writing `Cmd+Shift+H`, and neither should have to know which craft
/// prefers.
pub fn codeFor(name: []const u8) ?u16 {
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry.code;
    }
    for (aliases) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry.code;
    }
    return null;
}

/// The canonical name for `code`, or null if it is not a key craft names.
pub fn nameFor(code: u16) ?[]const u8 {
    for (table) |entry| {
        if (entry.code == code) return entry.name;
    }
    return null;
}

test "every canonical name resolves back to its own code" {
    for (table) |entry| {
        try std.testing.expectEqual(entry.code, codeFor(entry.name).?);
        try std.testing.expectEqualStrings(entry.name, nameFor(entry.code).?);
    }
}

test "lookup is case-insensitive" {
    try std.testing.expectEqual(@as(u16, 0x04), codeFor("h").?);
    try std.testing.expectEqual(@as(u16, 0x04), codeFor("H").?);
    try std.testing.expectEqual(@as(u16, 0x31), codeFor("space").?);
    try std.testing.expectEqual(@as(u16, 0x31), codeFor("SPACE").?);
}

test "aliases resolve, and every one of them names a real key" {
    for (aliases) |alias| {
        try std.testing.expectEqual(alias.code, codeFor(alias.name).?);
        // An alias pointing at a code no canonical entry claims would resolve
        // fine and then list itself as "Unknown".
        try std.testing.expect(nameFor(alias.code) != null);
    }
    // `nameFor` answers with the canonical spelling, so a shortcut registered
    // as "Backspace" lists itself as "Delete" rather than echoing whichever
    // spelling happened to arrive.
    try std.testing.expectEqualStrings("Delete", nameFor(codeFor("Backspace").?).?);
    try std.testing.expectEqualStrings("Escape", nameFor(codeFor("Esc").?).?);
}

test "no two canonical entries share a name or a code" {
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(a.name, b.name));
            try std.testing.expect(a.code != b.code);
        }
    }
}

test "an alias never collides with a canonical name" {
    // A duplicate here would be silently unreachable: `codeFor` checks the
    // canonical table first, so an alias shadowing one could disagree with it
    // forever without anything noticing.
    for (aliases) |alias| {
        for (table) |entry| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(alias.name, entry.name));
        }
    }
}

test "unknown keys are absent rather than guessed" {
    try std.testing.expect(codeFor("") == null);
    try std.testing.expect(codeFor("Meta") == null);
    try std.testing.expect(codeFor("F21") == null);
    // 0x34 is unassigned between Escape and kVK_Delete.
    try std.testing.expect(nameFor(0x34) == null);
    try std.testing.expect(nameFor(0xFFFF) == null);
}

test "the number row and the keypad are different keys" {
    // Bound to Keypad5, a shortcut must not fire on the 5 above the T — they
    // are distinct physical keys and macOS gives them distinct codes.
    try std.testing.expect(codeFor("5").? != codeFor("Keypad5").?);
    try std.testing.expect(codeFor("Return").? != codeFor("KeypadEnter").?);
}

test "Delete is backspace and ForwardDelete is not" {
    // The Mac key labelled Delete sends backspace; the PC key labelled Delete
    // is a different code. Getting these the wrong way round silently binds
    // the wrong key, so pin both.
    try std.testing.expectEqual(@as(u16, 0x33), codeFor("Delete").?);
    try std.testing.expectEqual(@as(u16, 0x75), codeFor("ForwardDelete").?);
    try std.testing.expectEqual(@as(u16, 0x33), codeFor("Backspace").?);
}
