//! Android audio-recording replies.
//!
//! `MediaRecorder` and the temporary `File` remain Kotlin-owned Java objects;
//! they have to survive from one bridge call to another and their lifecycle is
//! entirely platform-specific. The actions enter Zig, which owns permission
//! policy and every promise payload. On stop, Kotlin hands the recorded bytes
//! back and Zig creates the exact `data:audio/m4a;base64,` result.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const start_audio_recording = "startAudioRecording";
    pub const stop_audio_recording = "stopAudioRecording";
};

pub const start_resolve_global = "_craftAudioResolve";
pub const start_reject_global = "_craftAudioReject";
pub const stop_resolve_global = "_craftAudioStopResolve";
pub const stop_reject_global = "_craftAudioStopReject";
pub const no_recording = "No recording";
pub const request_audio: i32 = 1007;

pub fn stringPayload(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, text);
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

/// Android's `Base64.NO_WRAP` is the standard padded alphabet without line
/// breaks, exactly what Zig's standard encoder emits.
pub fn recordingPayload(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const prefix = "data:audio/m4a;base64,";
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, prefix.len + encoded_len + 2);
    errdefer allocator.free(out);

    out[0] = '"';
    @memcpy(out[1 .. 1 + prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(
        out[1 + prefix.len .. 1 + prefix.len + encoded_len],
        bytes,
    );
    out[out.len - 1] = '"';
    return out;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "recorded bytes become the shim's no-wrap data URL" {
    const payload = try recordingPayload(testing.allocator, "hello");
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"data:audio/m4a;base64,aGVsbG8=\"", payload);
}

test "an empty recording still has a data URL" {
    const payload = try recordingPayload(testing.allocator, "");
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"data:audio/m4a;base64,\"", payload);
}

test "an exception message survives as one JavaScript string" {
    const payload = try stringPayload(testing.allocator, "Recorder's \"busy\"");
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"Recorder's \\\"busy\\\"\"", payload);
}

test "the actions, globals and request code match the shim" {
    try testing.expectEqualStrings("startAudioRecording", A.start_audio_recording);
    try testing.expectEqualStrings("stopAudioRecording", A.stop_audio_recording);
    try testing.expectEqualStrings("_craftAudioResolve", start_resolve_global);
    try testing.expectEqualStrings("_craftAudioReject", start_reject_global);
    try testing.expectEqualStrings("_craftAudioStopResolve", stop_resolve_global);
    try testing.expectEqualStrings("_craftAudioStopReject", stop_reject_global);
    try testing.expectEqual(@as(i32, 1007), request_audio);
}
