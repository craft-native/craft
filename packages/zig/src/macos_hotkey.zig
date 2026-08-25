//! Global hotkeys on macOS, via Carbon's `RegisterEventHotKey`.
//!
//! This is the mechanism macOS provides for "fire even when my app is not
//! frontmost", and the reason craft uses it over the two obvious alternatives:
//!
//!   * `+[NSEvent addGlobalMonitorForEventsMatchingMask:handler:]` takes an
//!     Objective-C block. Zig cannot write one, which is where the previous
//!     attempt stopped — the mask was computed and then discarded, and no
//!     monitor was ever installed. See `bridge_shortcuts.zig`.
//!   * `CGEventTapCreate` takes a plain C callback and would work, but it is a
//!     keylogging-grade primitive: it demands Accessibility or Input
//!     Monitoring permission and sees every keystroke the user types. Asking
//!     for that to deliver one hotkey is a bad trade for craft's users.
//!
//! Carbon hotkeys take a plain C callback, require no permission prompt at
//! all, and the system only calls us for the exact combinations we asked for.
//! The API is old but is neither deprecated nor unavailable: it is what the
//! system's own hotkey UI is built on, and it is present on arm64.
//!
//! Registration is by *physical key*, not character. Cmd+Shift+H stays on the
//! same key after the user switches to Dvorak — see `key_codes.zig`.

const std = @import("std");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;

/// Opaque `EventHotKeyRef`. Held so the registration can be undone.
pub const Ref = ?*anyopaque;

/// Build a four-character code the way Carbon's headers do, so the constants
/// below read as the strings they are rather than as hex nobody can check.
fn fourCC(comptime s: *const [4:0]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

const k_event_class_keyboard = fourCC("keyb");
const k_event_hotkey_pressed: u32 = 5;
const k_event_param_direct_object = fourCC("----");
const type_event_hotkey_id = fourCC("hkid");

/// Signature for every hotkey craft registers, so ours are distinguishable
/// from another framework's inside the same process.
const craft_signature = fourCC("craf");

const noErr: i32 = 0;

const EventHotKeyID = extern struct {
    signature: u32,
    id: u32,
};

const EventTypeSpec = extern struct {
    eventClass: u32,
    eventKind: u32,
};

// `ItemCount`/`ByteCount` are `unsigned long` in MacTypes.h — 64-bit on every
// target craft builds for — and `OSStatus` is `SInt32`.
extern "c" fn GetApplicationEventTarget() ?*anyopaque;
extern "c" fn RegisterEventHotKey(
    inHotKeyCode: u32,
    inHotKeyModifiers: u32,
    inHotKeyID: EventHotKeyID,
    inTarget: ?*anyopaque,
    inOptions: u32,
    outRef: *Ref,
) i32;
extern "c" fn UnregisterEventHotKey(inHotKey: ?*anyopaque) i32;
extern "c" fn InstallEventHandler(
    inTarget: ?*anyopaque,
    inHandler: ?*const anyopaque,
    inNumTypes: usize,
    inList: [*]const EventTypeSpec,
    inUserData: ?*anyopaque,
    outRef: ?*?*anyopaque,
) i32;
extern "c" fn GetEventParameter(
    inEvent: ?*anyopaque,
    inName: u32,
    inDesiredType: u32,
    outActualType: ?*u32,
    inBufferSize: usize,
    outActualSize: ?*usize,
    outData: ?*anyopaque,
) i32;

/// Called on the main thread with the `id` a hotkey was registered under,
/// every time that combination is pressed anywhere in the system.
pub var on_pressed: ?*const fn (id: u32) void = null;

var handler_installed = false;

fn hotKeyHandler(_: ?*anyopaque, event: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
    var hotkey_id: EventHotKeyID = undefined;
    const status = GetEventParameter(
        event,
        k_event_param_direct_object,
        type_event_hotkey_id,
        null,
        @sizeOf(EventHotKeyID),
        null,
        &hotkey_id,
    );
    // Returning noErr regardless: the event was ours to handle either way, and
    // reporting failure here asks Carbon to keep looking for another handler
    // for a hotkey only craft registered.
    if (status != noErr) return noErr;
    if (hotkey_id.signature != craft_signature) return noErr;
    if (on_pressed) |cb| cb(hotkey_id.id);
    return noErr;
}

/// Install the one application-wide handler that every craft hotkey is
/// delivered through. Idempotent; safe to call before each registration.
///
/// Returns false if Carbon refused, in which case registering hotkeys is
/// pointless — they would be reserved system-wide and never delivered.
pub fn ensureHandler() bool {
    if (comptime !is_macos) return false;

    if (handler_installed) return true;

    const spec = [_]EventTypeSpec{.{
        .eventClass = k_event_class_keyboard,
        .eventKind = k_event_hotkey_pressed,
    }};
    const status = InstallEventHandler(
        GetApplicationEventTarget(),
        @ptrCast(&hotKeyHandler),
        spec.len,
        &spec,
        null,
        null,
    );
    if (status != noErr) return false;

    handler_installed = true;
    return true;
}

/// Reserve `keycode` + `modifiers` system-wide, delivered as `id`.
///
/// `modifiers` is a Carbon modifier mask — `accelerator.Modifiers.toCarbonFlags`
/// produces one — not the Cocoa `NSEventModifierFlag` set.
///
/// Returns null when the combination is already taken — by another app, or by
/// the system itself, which owns things like Cmd+Space. That is a normal
/// outcome and the caller should report it to the app rather than treat it as
/// a crash: the user has to pick a different key.
pub fn register(keycode: u16, modifiers: u32, id: u32) Ref {
    if (comptime !is_macos) return null;

    if (!ensureHandler()) return null;

    var ref: Ref = null;
    const status = RegisterEventHotKey(
        @intCast(keycode),
        modifiers,
        .{ .signature = craft_signature, .id = id },
        GetApplicationEventTarget(),
        0,
        &ref,
    );
    if (status != noErr or ref == null) return null;
    return ref;
}

/// Release a reservation so the combination reaches whoever wants it next.
pub fn unregister(ref: Ref) void {
    if (comptime !is_macos) return;

    if (ref) |r| _ = UnregisterEventHotKey(r);
}

// Carbon's event *construction* API, used only by the test below. Declared
// here rather than in the file's main body because craft never builds an event
// itself at runtime — it only ever receives them.
extern "c" fn CreateEvent(inAllocator: ?*anyopaque, inClassID: u32, inKind: u32, inWhen: f64, inAttributes: u32, outEvent: *?*anyopaque) i32;
extern "c" fn SetEventParameter(inEvent: ?*anyopaque, inName: u32, inType: u32, inSize: usize, inDataPtr: *const anyopaque) i32;
extern "c" fn SendEventToEventTarget(inEvent: ?*anyopaque, inTarget: ?*anyopaque) i32;
extern "c" fn ReleaseEvent(inEvent: ?*anyopaque) void;

var test_last_id: ?u32 = null;

fn recordPressed(id: u32) void {
    test_last_id = id;
}

/// Build the event Carbon sends on a hotkey press and put it through the real
/// dispatcher, so the handler runs exactly as it does for a real keystroke.
fn sendSyntheticHotKey(signature: u32, id: u32) !void {
    var event: ?*anyopaque = null;
    if (CreateEvent(null, k_event_class_keyboard, k_event_hotkey_pressed, 0, 0, &event) != noErr)
        return error.CreateEventFailed;
    defer ReleaseEvent(event);

    const payload = EventHotKeyID{ .signature = signature, .id = id };
    if (SetEventParameter(event, k_event_param_direct_object, type_event_hotkey_id, @sizeOf(EventHotKeyID), &payload) != noErr)
        return error.SetParameterFailed;
    if (SendEventToEventTarget(event, GetApplicationEventTarget()) != noErr)
        return error.SendFailed;
}

test "a hotkey event dispatched by Carbon reaches the callback" {
    // The one part of this file that cannot be reasoned about from the source:
    // whether the handler signature, the `EventHotKeyID` layout and the
    // `GetEventParameter` call are what Carbon actually expects. Getting any
    // of them wrong compiles, links, registers — and then silently never
    // delivers, which is the exact shape of the bug this file exists to fix.
    //
    // Everything here is real except the keystroke: a genuine `EventRef`, put
    // through Carbon's own dispatcher, decoded by the handler craft installs.
    if (comptime !is_macos) return error.SkipZigTest;

    // A build host with no Carbon event target — some headless CI images —
    // cannot install the handler, and there is nothing left to assert.
    if (!ensureHandler()) return error.SkipZigTest;

    const previous = on_pressed;
    defer on_pressed = previous;
    on_pressed = recordPressed;

    test_last_id = null;
    try sendSyntheticHotKey(craft_signature, 4242);
    try std.testing.expectEqual(@as(?u32, 4242), test_last_id);
}

test "a hotkey belonging to someone else is left alone" {
    // Another framework in the same process can register its own hotkeys, and
    // its events arrive at every handler installed on the application target.
    // Acting on one would fire an unrelated app's shortcut as if it were ours.
    if (comptime !is_macos) return error.SkipZigTest;
    if (!ensureHandler()) return error.SkipZigTest;

    const previous = on_pressed;
    defer on_pressed = previous;
    on_pressed = recordPressed;

    test_last_id = null;
    try sendSyntheticHotKey(fourCC("othr"), 4242);
    try std.testing.expectEqual(@as(?u32, null), test_last_id);
}

test "the four-character codes match the constants Carbon documents" {
    // These are the values every Carbon hotkey example hard-codes as hex.
    // Deriving them from the strings is what makes them readable; pinning the
    // hex is what makes the derivation checkable.
    try std.testing.expectEqual(@as(u32, 0x6B657962), fourCC("keyb"));
    try std.testing.expectEqual(@as(u32, 0x2D2D2D2D), fourCC("----"));
    try std.testing.expectEqual(@as(u32, 0x686B6964), fourCC("hkid"));
    try std.testing.expectEqual(@as(u32, 0x63726166), fourCC("craf"));
}

test "EventHotKeyID is laid out the way Carbon reads it" {
    // `GetEventParameter` writes straight into this struct, so a wrong size or
    // a reordered field is a silent memory-corruption bug rather than a
    // compile error.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(EventHotKeyID));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(EventHotKeyID, "signature"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(EventHotKeyID, "id"));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(EventTypeSpec));
}
