//! Android ML Kit image actions.
//!
//! Bitmap/InputImage construction, ML Kit clients and Task listeners are Java
//! objects and remain in the fixed holder. The three actions enter Zig and all
//! success/failure callbacks return here, so the generated bridge no longer
//! owns their promise behavior. Results remain Android `JSONObject` output to
//! preserve float spelling, nullable tracking ids, and field omission exactly.

const std = @import("std");
const bridge_error = @import("bridge_error.zig");

pub const A = struct {
    pub const classify_image = "classifyImage";
    pub const detect_objects = "detectObjects";
    pub const recognize_text = "recognizeText";
};

pub const resolve_global = "_craftMLResolve";
pub const reject_global = "_craftMLReject";

pub fn errorPayload(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, &out, message);
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "ML Kit errors remain one JavaScript string" {
    const payload = try errorPayload(testing.allocator, "Model's \"missing\"");
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("\"Model's \\\"missing\\\"\"", payload);
}

test "the actions and shared globals match the injected promises" {
    try testing.expectEqualStrings("classifyImage", A.classify_image);
    try testing.expectEqualStrings("detectObjects", A.detect_objects);
    try testing.expectEqualStrings("recognizeText", A.recognize_text);
    try testing.expectEqualStrings("_craftMLResolve", resolve_global);
    try testing.expectEqualStrings("_craftMLReject", reject_global);
}
