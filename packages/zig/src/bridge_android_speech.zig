//! Android speech-recognition behavior.
//!
//! `SpeechRecognizer` requires calls on the main thread and a Java
//! `RecognitionListener`, so `CraftNative` owns those two Java-shaped pieces
//! and the recognizer reference. Zig owns availability, error mapping, event
//! payloads, and the decision to haptically acknowledge terminal callbacks.
//!
//! The shim's `isListening` field is written on ready, error, result and stop,
//! but never read. Moving the live recognizer state without copying that dead
//! bookkeeping therefore changes nothing observable.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const start_listening = "startListening";
    pub const stop_listening = "stopListening";
};

pub const start_event = "craftSpeechStart";
pub const result_event = "craftSpeechResult";
pub const end_event = "craftSpeechEnd";
pub const error_event = "craftSpeechError";
pub const unavailable = "Speech recognition not available";

/// Android's `SpeechRecognizer.ERROR_*` constants, mapped in the same order
/// as the shim's `when`. Any new platform value remains "Unknown error".
pub fn errorMessage(code: i32) []const u8 {
    return switch (code) {
        3 => "Audio recording error",
        5 => "Client error",
        9 => "Insufficient permissions",
        2 => "Network error",
        1 => "Network timeout",
        7 => "No match",
        8 => "Recognizer busy",
        4 => "Server error",
        6 => "Speech timeout",
        else => "Unknown error",
    };
}

pub fn errorDetail(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"error\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, message);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

pub fn resultDetail(
    allocator: std.mem.Allocator,
    transcript: []const u8,
    is_final: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"transcript\":\"");
    try bridge_error.appendJsonEscaped(allocator, &out, transcript);
    try out.appendSlice(allocator, "\",\"isFinal\":");
    try out.appendSlice(allocator, if (is_final) "true}" else "false}");
    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "every Android speech error keeps the shim's wording" {
    try testing.expectEqualStrings("Network timeout", errorMessage(1));
    try testing.expectEqualStrings("Network error", errorMessage(2));
    try testing.expectEqualStrings("Audio recording error", errorMessage(3));
    try testing.expectEqualStrings("Server error", errorMessage(4));
    try testing.expectEqualStrings("Client error", errorMessage(5));
    try testing.expectEqualStrings("Speech timeout", errorMessage(6));
    try testing.expectEqualStrings("No match", errorMessage(7));
    try testing.expectEqualStrings("Recognizer busy", errorMessage(8));
    try testing.expectEqualStrings("Insufficient permissions", errorMessage(9));
    try testing.expectEqualStrings("Unknown error", errorMessage(10));
}

test "a transcript and its finality form the shim's event detail" {
    const partial = try resultDetail(testing.allocator, "say \"hi\"", false);
    defer testing.allocator.free(partial);
    try testing.expectEqualStrings("{\"transcript\":\"say \\\"hi\\\"\",\"isFinal\":false}", partial);

    const final = try resultDetail(testing.allocator, "done", true);
    defer testing.allocator.free(final);
    try testing.expectEqualStrings("{\"transcript\":\"done\",\"isFinal\":true}", final);
}

test "the actions and event names match the shim exactly" {
    try testing.expectEqualStrings("startListening", A.start_listening);
    try testing.expectEqualStrings("stopListening", A.stop_listening);
    try testing.expectEqualStrings("craftSpeechStart", start_event);
    try testing.expectEqualStrings("craftSpeechResult", result_event);
    try testing.expectEqualStrings("craftSpeechEnd", end_event);
    try testing.expectEqualStrings("craftSpeechError", error_event);
}
