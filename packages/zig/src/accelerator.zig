//! Accelerator strings — `"Cmd+Shift+H"` — parsed into a key and modifiers.
//!
//! This is the shape `window.craft.shortcuts.register(id, accelerator)` sends,
//! and it is deliberately the same spelling Electron and the web use, so an
//! accelerator copied out of existing app code means here what it meant there.
//!
//! Pure: no Objective-C, no Carbon, nothing platform-specific. That is what
//! lets the whole of it be tested without a window, a key press or a running
//! app — which matters, because the bug this file exists to fix
//! (craft-native/craft#47) was precisely that nothing between the JS call and
//! the keyboard was exercised by anything.

const std = @import("std");
const builtin = @import("builtin");
const key_codes = @import("key_codes.zig");

pub const Modifiers = struct {
    cmd: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    /// `NSEventModifierFlag` bits, for matching against a Cocoa event.
    pub fn toCocoaFlags(self: Modifiers) c_ulong {
        var flags: c_ulong = 0;
        if (self.shift) flags |= (1 << 17); // NSEventModifierFlagShift
        if (self.ctrl) flags |= (1 << 18); // NSEventModifierFlagControl
        if (self.alt) flags |= (1 << 19); // NSEventModifierFlagOption
        if (self.cmd) flags |= (1 << 20); // NSEventModifierFlagCommand
        return flags;
    }

    /// Carbon modifier bits, for `RegisterEventHotKey`. A different set of
    /// values entirely from the Cocoa ones above: Cocoa's command bit is
    /// 1<<20, Carbon's is 1<<8, and passing one where the other is expected
    /// registers a hotkey nobody can press.
    ///
    /// From `<Carbon/HIToolbox/Events.h>`.
    pub const carbon_command: u32 = 1 << 8;
    pub const carbon_shift: u32 = 1 << 9;
    pub const carbon_option: u32 = 1 << 11;
    pub const carbon_control: u32 = 1 << 12;

    pub fn toCarbonFlags(self: Modifiers) u32 {
        var flags: u32 = 0;
        if (self.cmd) flags |= carbon_command;
        if (self.shift) flags |= carbon_shift;
        if (self.alt) flags |= carbon_option;
        if (self.ctrl) flags |= carbon_control;
        return flags;
    }

    /// Whether any modifier that changes what a key *does*, rather than which
    /// character it produces, is held. Shift is excluded on purpose: Shift+H
    /// is just how you type H.
    pub fn hasCommandingModifier(self: Modifiers) bool {
        return self.cmd or self.ctrl or self.alt;
    }

    pub fn eql(self: Modifiers, other: Modifiers) bool {
        return self.cmd == other.cmd and self.ctrl == other.ctrl and
            self.alt == other.alt and self.shift == other.shift;
    }
};

pub const Binding = struct {
    /// Canonical name of the key, from `key_codes.zig` — so a shortcut
    /// registered as `"Cmd+Backspace"` reports itself as `Cmd+Delete`.
    key: []const u8,
    /// macOS virtual key code.
    keycode: u16,
    modifiers: Modifiers,

    pub fn eql(self: Binding, other: Binding) bool {
        return self.keycode == other.keycode and self.modifiers.eql(other.modifiers);
    }
};

pub const ParseError = error{
    /// The accelerator was empty, or was nothing but modifiers.
    MissingKey,
    /// A component was empty — `"Cmd++"`, `"+H"`, `"Cmd+ +H"`.
    EmptyComponent,
    /// The final component names no key craft knows.
    UnknownKey,
    /// A component before the key is neither a modifier nor a key.
    UnknownModifier,
    /// The same modifier was named twice.
    DuplicateModifier,
    /// A global hotkey with no commanding modifier would make the key
    /// untypeable in every app on the system.
    ModifierRequired,
};

/// Function keys are the exception to `ModifierRequired`: they produce no
/// text, so reserving F13 on its own costs the user nothing. Everything else
/// bare — `"H"`, `"Space"`, `"Shift+H"` — would take a key away system-wide.
fn isBareBindable(name: []const u8) bool {
    if (name.len < 2 or (name[0] != 'F' and name[0] != 'f')) return false;
    _ = std.fmt.parseInt(u8, name[1..], 10) catch return false;
    return true;
}

fn applyModifier(name: []const u8, mods: *Modifiers) ParseError!void {
    const Target = enum { cmd, ctrl, alt, shift };
    const target: Target = blk: {
        // `CmdOrCtrl` is the portable spelling: command where command is what
        // apps use, control everywhere else. Resolved here rather than being
        // carried through, so everything downstream sees a concrete modifier.
        if (eq(name, "cmdorctrl") or eq(name, "commandorcontrol") or eq(name, "mod"))
            break :blk if (builtin.os.tag == .macos) .cmd else .ctrl;
        if (eq(name, "cmd") or eq(name, "command") or eq(name, "meta") or
            eq(name, "super") or eq(name, "win") or eq(name, "\u{2318}")) break :blk .cmd;
        if (eq(name, "ctrl") or eq(name, "control") or eq(name, "\u{2303}")) break :blk .ctrl;
        if (eq(name, "alt") or eq(name, "option") or eq(name, "opt") or
            eq(name, "\u{2325}")) break :blk .alt;
        if (eq(name, "shift") or eq(name, "\u{21E7}")) break :blk .shift;
        return ParseError.UnknownModifier;
    };

    const slot = switch (target) {
        .cmd => &mods.cmd,
        .ctrl => &mods.ctrl,
        .alt => &mods.alt,
        .shift => &mods.shift,
    };
    // Naming a modifier twice is a typo, and silently accepting it hides which
    // half of `"Cmd+Cmd+Shift"` the author meant to write.
    if (slot.*) return ParseError.DuplicateModifier;
    slot.* = true;
}

fn eq(a: []const u8, comptime b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Parse `"Cmd+Shift+H"` into the key and modifiers it names.
///
/// The last `+`-separated component is the key; everything before it is a
/// modifier. Components are matched case-insensitively.
pub fn parse(input: []const u8) ParseError!Binding {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) return ParseError.MissingKey;

    var mods = Modifiers{};
    var key_part: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, trimmed, '+');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) return ParseError.EmptyComponent;

        // The key is whatever is last, so a component only becomes a modifier
        // once another component turns up behind it.
        if (key_part) |previous| try applyModifier(previous, &mods);
        key_part = part;
    }

    const key_name = key_part orelse return ParseError.MissingKey;
    const keycode = key_codes.codeFor(key_name) orelse return ParseError.UnknownKey;
    const canonical = key_codes.nameFor(keycode).?;

    if (!mods.hasCommandingModifier() and !isBareBindable(canonical)) {
        return ParseError.ModifierRequired;
    }

    return .{ .key = canonical, .keycode = keycode, .modifiers = mods };
}

/// Render a binding back into the canonical accelerator string, so what an
/// app reads out of `craft.shortcuts.list()` is something it could pass
/// straight back to `register()`.
pub fn format(buf: []u8, binding: Binding) ![]const u8 {
    var pos: usize = 0;
    const parts = [_]struct { on: bool, name: []const u8 }{
        .{ .on = binding.modifiers.cmd, .name = "Cmd" },
        .{ .on = binding.modifiers.ctrl, .name = "Ctrl" },
        .{ .on = binding.modifiers.alt, .name = "Alt" },
        .{ .on = binding.modifiers.shift, .name = "Shift" },
    };
    for (parts) |part| {
        if (!part.on) continue;
        if (pos + part.name.len + 1 > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[pos..][0..part.name.len], part.name);
        pos += part.name.len;
        buf[pos] = '+';
        pos += 1;
    }
    if (pos + binding.key.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[pos..][0..binding.key.len], binding.key);
    return buf[0 .. pos + binding.key.len];
}

// =============================================================================
// Tests
// =============================================================================

test "the accelerator the downstream bug report names parses" {
    // stacksjs/harness registers exactly this and has never received a key.
    const b = try parse("Cmd+Shift+H");
    try std.testing.expectEqualStrings("H", b.key);
    try std.testing.expectEqual(@as(u16, 0x04), b.keycode);
    try std.testing.expect(b.modifiers.cmd);
    try std.testing.expect(b.modifiers.shift);
    try std.testing.expect(!b.modifiers.ctrl);
    try std.testing.expect(!b.modifiers.alt);
}

test "modifier spellings are interchangeable" {
    const expected = try parse("Cmd+Alt+K");
    for ([_][]const u8{
        "cmd+alt+k",
        "Command+Option+K",
        "COMMAND+OPT+K",
        "Meta+Alt+K",
        "Super+Option+K",
        "\u{2318}+\u{2325}+K",
    }) |spelling| {
        const b = try parse(spelling);
        try std.testing.expect(b.eql(expected));
    }
}

test "CmdOrCtrl resolves to this platform's modifier" {
    const b = try parse("CmdOrCtrl+S");
    if (builtin.os.tag == .macos) {
        try std.testing.expect(b.modifiers.cmd);
        try std.testing.expect(!b.modifiers.ctrl);
    } else {
        try std.testing.expect(b.modifiers.ctrl);
        try std.testing.expect(!b.modifiers.cmd);
    }
}

test "the key reported back is canonical, not the spelling that arrived" {
    const b = try parse("Cmd+Backspace");
    try std.testing.expectEqualStrings("Delete", b.key);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Cmd+Delete", try format(&buf, b));
}

test "format round-trips through parse" {
    var buf: [64]u8 = undefined;
    for ([_][]const u8{
        "Cmd+Shift+H",
        "Ctrl+Alt+Delete",
        "Cmd+Ctrl+Alt+Shift+Space",
        "Alt+Left",
        "F13",
    }) |source| {
        const first = try parse(source);
        const rendered = try format(&buf, first);
        const again = try parse(rendered);
        try std.testing.expect(first.eql(again));
        try std.testing.expectEqualStrings(first.key, again.key);
    }
}

test "a bare key is refused rather than made untypeable everywhere" {
    // A global hotkey on `H` means no application on the system, craft's
    // included, ever sees the user type an h again. Failing the registration
    // is recoverable; that is not.
    try std.testing.expectError(ParseError.ModifierRequired, parse("H"));
    try std.testing.expectError(ParseError.ModifierRequired, parse("Space"));
    // Shift does not count: Shift+H is how you type a capital H.
    try std.testing.expectError(ParseError.ModifierRequired, parse("Shift+H"));
}

test "function keys may be bound bare" {
    // They produce no text, so reserving one costs the user nothing.
    const b = try parse("F13");
    try std.testing.expectEqualStrings("F13", b.key);
    try std.testing.expect(!b.modifiers.hasCommandingModifier());
    _ = try parse("F5");
    _ = try parse("Shift+F1");
}

test "malformed accelerators name what is wrong with them" {
    try std.testing.expectError(ParseError.MissingKey, parse(""));
    try std.testing.expectError(ParseError.MissingKey, parse("   "));
    try std.testing.expectError(ParseError.EmptyComponent, parse("Cmd+"));
    try std.testing.expectError(ParseError.EmptyComponent, parse("+H"));
    try std.testing.expectError(ParseError.EmptyComponent, parse("Cmd++H"));
    try std.testing.expectError(ParseError.UnknownKey, parse("Cmd+Nonsense"));
    try std.testing.expectError(ParseError.UnknownModifier, parse("Hyper+Cmd+H"));
    try std.testing.expectError(ParseError.DuplicateModifier, parse("Cmd+Cmd+H"));
}

test "surrounding whitespace is tolerated" {
    const spaced = try parse("  Cmd + Shift + H  ");
    const tight = try parse("Cmd+Shift+H");
    try std.testing.expect(spaced.eql(tight));
}

test "a modifier name in the key position is the key, not a modifier" {
    // `"Cmd+Shift"` names no key: Shift is the last component, so it is where
    // the key should be, and it is not one.
    try std.testing.expectError(ParseError.UnknownKey, parse("Cmd+Shift"));
}

test "Cocoa and Carbon flag sets do not agree, and both are right" {
    const mods = Modifiers{ .cmd = true, .shift = true };
    try std.testing.expectEqual(@as(c_ulong, (1 << 20) | (1 << 17)), mods.toCocoaFlags());
    try std.testing.expectEqual(@as(u32, 0x0100 | 0x0200), mods.toCarbonFlags());

    // Pin the Carbon values against the header. The two sets overlap in
    // meaning and in nothing else, and a hotkey registered with Cocoa's 1<<20
    // for command asks for a combination involving no modifier the user can
    // press.
    try std.testing.expectEqual(@as(u32, 0x0100), Modifiers.carbon_command);
    try std.testing.expectEqual(@as(u32, 0x0200), Modifiers.carbon_shift);
    try std.testing.expectEqual(@as(u32, 0x0800), Modifiers.carbon_option);
    try std.testing.expectEqual(@as(u32, 0x1000), Modifiers.carbon_control);
    try std.testing.expect(Modifiers.carbon_command != (1 << 20));
}

test "every modifier maps to a distinct bit in both sets" {
    const each = [_]Modifiers{
        .{ .cmd = true }, .{ .ctrl = true }, .{ .alt = true }, .{ .shift = true },
    };
    for (each, 0..) |a, i| {
        try std.testing.expect(a.toCocoaFlags() != 0);
        try std.testing.expect(a.toCarbonFlags() != 0);
        for (each[i + 1 ..]) |b| {
            try std.testing.expect(a.toCocoaFlags() != b.toCocoaFlags());
            try std.testing.expect(a.toCarbonFlags() != b.toCarbonFlags());
        }
    }
}

test "keypad keys are bindable and distinct from the number row" {
    const pad = try parse("Cmd+Keypad5");
    const row = try parse("Cmd+5");
    try std.testing.expect(!pad.eql(row));
}
