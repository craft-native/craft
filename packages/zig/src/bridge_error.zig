const std = @import("std");
const request_context = @import("request_context.zig");
const builtin = @import("builtin");

/// Common error types for all bridge operations
pub const BridgeError = error{
    /// Window handle is not set or invalid
    WindowHandleNotSet,
    /// WebView handle is not set or invalid
    WebViewHandleNotSet,
    /// Tray handle is not set or invalid
    TrayHandleNotSet,
    /// The requested action is not recognized
    UnknownAction,
    /// JSON data is missing when required
    MissingData,
    /// JSON parsing failed
    InvalidJSON,
    /// Invalid parameter value
    InvalidParameter,
    /// Platform not supported for this operation
    PlatformNotSupported,
    /// Native API call failed
    NativeCallFailed,
    /// Memory allocation failed
    AllocationFailed,
    /// Operation was cancelled by user
    Cancelled,
    /// File or resource not found
    NotFound,
    /// Permission denied
    PermissionDenied,
    /// Operation timed out
    Timeout,
    /// Command contains unsafe shell metacharacters
    UnsafeCommand,
    /// The app's configuration did not enable this capability.
    ///
    /// Distinct from `PermissionDenied`, which is the *user* or the system
    /// refusing at request time. This one is decided before anything is
    /// requested, by the `enable*` flag the app was generated with, and no
    /// prompt the user could answer would change it — so a page that retries
    /// on `PERMISSION_DENIED` must not retry on this.
    CapabilityDisabled,
};

/// Result type for bridge operations that return data
pub fn BridgeResult(comptime T: type) type {
    return union(enum) {
        success: T,
        err: BridgeError,

        pub fn ok(value: T) @This() {
            return .{ .success = value };
        }

        pub fn fail(e: BridgeError) @This() {
            return .{ .err = e };
        }

        pub fn isOk(self: @This()) bool {
            return self == .success;
        }

        pub fn unwrap(self: @This()) !T {
            return switch (self) {
                .success => |v| v,
                .err => |e| e,
            };
        }
    };
}

/// Error context with additional information
pub const ErrorContext = struct {
    err: BridgeError,
    action: []const u8,
    message: []const u8,
    /// The page's id for the call that failed, when the failure happened while
    /// serving one. Lets `craft-bridge.js` reject exactly that caller instead
    /// of every caller queued under the same action name — which matters most
    /// here, because six action names are served by more than one bridge, so
    /// draining by name rejects unrelated calls with an error from a bridge
    /// they never touched.
    request_id: ?u64 = null,

    pub fn init(err: BridgeError, action: []const u8, message: []const u8) ErrorContext {
        return .{
            .err = err,
            .action = action,
            .message = message,
        };
    }

    /// Format error as JSON for sending to JavaScript.
    /// Builds into a dynamic ArrayList so long action/message strings can't
    /// overflow the previously fixed 1024-byte stack buffer. Escapes both
    /// `"` and `\` plus control bytes that would produce invalid JSON.
    pub fn toJSON(self: ErrorContext, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "{\"error\":true,\"code\":\"");
        try out.appendSlice(allocator, errorCodeString(self.err));
        try out.appendSlice(allocator, "\",\"action\":\"");
        try appendJsonEscaped(allocator, &out, self.action);
        try out.appendSlice(allocator, "\",\"message\":\"");
        try appendJsonEscaped(allocator, &out, self.message);
        try out.append(allocator, '"');
        if (self.request_id) |id| {
            try out.appendSlice(allocator, ",\"id\":");
            try out.print(allocator, "{d}", .{id});
        }
        try out.append(allocator, '}');

        return out.toOwnedSlice(allocator);
    }
};

/// Append `s` to `out` with JSON-string escaping for `"`, `\`, and control
/// characters below 0x20. Exported at module scope so other bridge modules
/// can reuse the same escaping rules.
pub fn appendJsonEscaped(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var hex_buf: [6]u8 = undefined;
                const hex = try std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c});
                try out.appendSlice(allocator, hex);
            },
            else => try out.append(allocator, c),
        }
    }
}

/// Convert BridgeError to string code for JavaScript
pub fn errorCodeString(err: BridgeError) []const u8 {
    return switch (err) {
        BridgeError.WindowHandleNotSet => "WINDOW_HANDLE_NOT_SET",
        BridgeError.WebViewHandleNotSet => "WEBVIEW_HANDLE_NOT_SET",
        BridgeError.TrayHandleNotSet => "TRAY_HANDLE_NOT_SET",
        BridgeError.UnknownAction => "UNKNOWN_ACTION",
        BridgeError.MissingData => "MISSING_DATA",
        BridgeError.InvalidJSON => "INVALID_JSON",
        BridgeError.InvalidParameter => "INVALID_PARAMETER",
        BridgeError.PlatformNotSupported => "PLATFORM_NOT_SUPPORTED",
        BridgeError.NativeCallFailed => "NATIVE_CALL_FAILED",
        BridgeError.AllocationFailed => "ALLOCATION_FAILED",
        BridgeError.Cancelled => "CANCELLED",
        BridgeError.NotFound => "NOT_FOUND",
        BridgeError.PermissionDenied => "PERMISSION_DENIED",
        BridgeError.Timeout => "TIMEOUT",
        BridgeError.UnsafeCommand => "UNSAFE_COMMAND",
        BridgeError.CapabilityDisabled => "CAPABILITY_DISABLED",
    };
}

/// Convert BridgeError to human-readable message
pub fn errorMessage(err: BridgeError) []const u8 {
    return switch (err) {
        BridgeError.WindowHandleNotSet => "Window handle is not initialized",
        BridgeError.WebViewHandleNotSet => "WebView handle is not initialized",
        BridgeError.TrayHandleNotSet => "Tray handle is not initialized",
        BridgeError.UnknownAction => "The requested action is not recognized",
        BridgeError.MissingData => "Required data is missing",
        BridgeError.InvalidJSON => "Failed to parse JSON data",
        BridgeError.InvalidParameter => "Invalid parameter value",
        BridgeError.PlatformNotSupported => "This operation is not supported on the current platform",
        BridgeError.NativeCallFailed => "Native API call failed",
        BridgeError.AllocationFailed => "Memory allocation failed",
        BridgeError.Cancelled => "Operation was cancelled",
        BridgeError.NotFound => "Resource not found",
        BridgeError.PermissionDenied => "Permission denied",
        BridgeError.Timeout => "Operation timed out",
        BridgeError.UnsafeCommand => "Command contains unsafe shell metacharacters",
        BridgeError.CapabilityDisabled => "Capability is disabled",
    };
}

/// Send error to JavaScript via eval
pub fn sendErrorToJS(allocator: std.mem.Allocator, action: []const u8, err: BridgeError) void {
    var ctx = ErrorContext.init(err, action, errorMessage(err));
    ctx.request_id = request_context.current();
    const json = ctx.toJSON(allocator) catch {
        if (comptime builtin.mode == .debug)
            std.debug.print("[BridgeError] Failed to serialize error\n", .{});
        return;
    };
    defer allocator.free(json);

    const bridge = @import("bridge.zig");

    // Allocate the JS string so long action/message strings (which the new
    // `toJSON` will faithfully include) can't overflow a fixed stack buffer.
    const js = std.fmt.allocPrint(
        allocator,
        "if(window.__craftBridgeError)window.__craftBridgeError({s});",
        .{json},
    ) catch {
        if (comptime builtin.mode == .debug)
            std.debug.print("[BridgeError] Failed to format JS\n", .{});
        return;
    };
    defer allocator.free(js);

    bridge.evalJS(js) catch |eval_err| {
        if (comptime builtin.mode == .debug)
            std.debug.print("[BridgeError] Failed to send error to JS: {}\n", .{eval_err});
    };

    // Always log to console
    if (comptime builtin.mode == .debug)
        std.debug.print("[BridgeError] {s}: {s} - {s}\n", .{ action, errorCodeString(err), errorMessage(err) });
}

/// Render the JS call that hands `result_json` back to the page as the answer
/// to `request_id`.
///
/// Split out from `sendResultToJS` so the exact string that reaches the page
/// can be asserted in a test. It could not be before, and the shape of this
/// string is the whole reply contract.
pub fn formatResultJS(
    allocator: std.mem.Allocator,
    action: []const u8,
    result_json: []const u8,
    request_id: ?u64,
) ![]u8 {
    // Null, not 0 or -1, for "no id": JSON has a real absent value and zero is
    // a perfectly good id. A sentinel here is how the page ends up treating
    // some real call as unidentified.
    var id_buf: [24]u8 = undefined;
    const id_text: []const u8 = if (request_id) |id|
        try std.fmt.bufPrint(&id_buf, "{d}", .{id})
    else
        "null";

    return std.fmt.allocPrint(
        allocator,
        "if(window.__craftBridgeResult)window.__craftBridgeResult('{s}',{s},{s});",
        .{ action, result_json, id_text },
    );
}

/// Send success result to JavaScript
pub fn sendResultToJS(allocator: std.mem.Allocator, action: []const u8, result_json: []const u8) void {
    const bridge = @import("bridge.zig");

    // Which call this answers. Null when there is no call to name: a reply
    // raised outside any dispatch, or a message the page sent without an `i`
    // (the tray and menubar polling `_post`s, which nobody awaits). The page
    // then matches by action name exactly as it did before ids.
    const js = formatResultJS(allocator, action, result_json, request_context.current()) catch {
        if (comptime builtin.mode == .debug)
            std.debug.print("[BridgeResult] Failed to format JS\n", .{});
        return;
    };
    defer allocator.free(js);

    bridge.evalJS(js) catch |err| {
        // Was misleadingly logged as "failed to send error to JS" — this
        // function delivers success results, not errors.
        std.log.warn("failed to send bridge result to JS for '{s}': {}", .{ action, err });
    };
}

/// Escape `s` for embedding inside a JSON string (i.e. between double
/// quotes in a JSON payload). Writes to `out` and returns the written
/// slice, or `error.BufferTooSmall` if the buffer is too small. Use this
/// for attacker-controlled bytes like Bluetooth device names or filenames
/// before interpolating them into a JSON literal — the previous approach
/// of embedding such strings with `{s}` produced broken or injectable JSON
/// whenever the input contained `"`, `\`, or control bytes.
pub fn escapeJsonString(out: []u8, s: []const u8) ![]const u8 {
    var pos: usize = 0;
    for (s) |c| {
        const repl: []const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0C => "\\f",
            0x00...0x07, 0x0B, 0x0E...0x1F => blk: {
                // JSON requires \uXXXX for control bytes not covered above.
                var hex: [6]u8 = undefined;
                const slice = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}) catch return error.BufferTooSmall;
                if (pos + slice.len > out.len) return error.BufferTooSmall;
                @memcpy(out[pos..][0..slice.len], slice);
                pos += slice.len;
                break :blk "";
            },
            else => &[_]u8{c},
        };
        if (repl.len == 0) continue;
        if (pos + repl.len > out.len) return error.BufferTooSmall;
        @memcpy(out[pos..][0..repl.len], repl);
        pos += repl.len;
    }
    return out[0..pos];
}

/// Escape `s` for embedding inside a single-quoted JavaScript string literal.
/// Writes to `out` and returns the written slice, or `error.BufferTooSmall`
/// if `out` can't hold the escaped form. Callers that need to pass
/// user-controlled strings into generated JS should use this helper — prior
/// to its introduction every bridge module rolled its own escaping inline
/// (and several forgot to escape at all, creating JS-injection vectors).
pub fn escapeJsSingleQuoted(out: []u8, s: []const u8) ![]const u8 {
    var pos: usize = 0;
    for (s) |c| {
        const repl: []const u8 = switch (c) {
            '\\' => "\\\\",
            '\'' => "\\'",
            '\n' => "\\n",
            '\r' => "\\r",
            // Escaping `<` keeps the string from prematurely closing an
            // inline `</script>` if the JS is ever rendered into HTML.
            '<' => "\\x3c",
            else => &[_]u8{c},
        };
        if (pos + repl.len > out.len) return error.BufferTooSmall;
        @memcpy(out[pos..][0..repl.len], repl);
        pos += repl.len;
    }
    return out[0..pos];
}

/// Helper to validate required handle
pub fn requireHandle(handle: ?*anyopaque, err: BridgeError) BridgeError!*anyopaque {
    return handle orelse err;
}

/// Helper to validate required data
pub fn requireData(data: ?[]const u8) BridgeError![]const u8 {
    return data orelse BridgeError.MissingData;
}

// Unit tests
test "errorCodeString returns correct codes" {
    const testing = std.testing;
    try testing.expectEqualStrings("WINDOW_HANDLE_NOT_SET", errorCodeString(BridgeError.WindowHandleNotSet));
    try testing.expectEqualStrings("UNKNOWN_ACTION", errorCodeString(BridgeError.UnknownAction));
    try testing.expectEqualStrings("MISSING_DATA", errorCodeString(BridgeError.MissingData));
}

test "ErrorContext.toJSON produces valid JSON" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = ErrorContext.init(BridgeError.WindowHandleNotSet, "setSize", "Window handle is not initialized");
    const json = try ctx.toJSON(allocator);
    defer allocator.free(json);

    // Verify JSON structure
    try testing.expect(std.mem.indexOf(u8, json, "\"error\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"code\":\"WINDOW_HANDLE_NOT_SET\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\":\"setSize\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"message\":\"Window handle is not initialized\"") != null);
}

test "requireHandle returns error when null" {
    const testing = std.testing;

    const result = requireHandle(null, BridgeError.WindowHandleNotSet);
    try testing.expectError(BridgeError.WindowHandleNotSet, result);
}

test "requireData returns error when null" {
    const testing = std.testing;

    const result = requireData(null);
    try testing.expectError(BridgeError.MissingData, result);
}

test "requireData returns data when present" {
    const testing = std.testing;

    const data = "test data";
    const result = try requireData(data);
    try testing.expectEqualStrings("test data", result);
}

test "escapeJsSingleQuoted handles quotes, backslashes, newlines, and <" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const got = try escapeJsSingleQuoted(&buf, "a'b\\c\nd</script>");
    try testing.expectEqualStrings("a\\'b\\\\c\\nd\\x3c/script>", got);
}

test "escapeJsSingleQuoted returns BufferTooSmall when output buffer is full" {
    const testing = std.testing;
    var buf: [3]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, escapeJsSingleQuoted(&buf, "abcd"));
}

test "escapeJsonString handles quotes, backslashes, control bytes" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const got = try escapeJsonString(&buf, "a\"b\\c\n\x01\x08\x0c");
    try testing.expectEqualStrings("a\\\"b\\\\c\\n\\u0001\\b\\f", got);
}

test "escapeJsonString BufferTooSmall" {
    const testing = std.testing;
    var buf: [3]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, escapeJsonString(&buf, "abcd"));
}

test "ErrorContext.toJSON escapes quotes, backslashes, and control bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = ErrorContext.init(
        BridgeError.InvalidJSON,
        "parse",
        "broken: \"quote\" \\slash\n\tnewline\x01ctrl",
    );
    const json = try ctx.toJSON(allocator);
    defer allocator.free(json);

    // Quotes, backslashes, \n, \t escaped. Control bytes go via \uXXXX.
    try testing.expect(std.mem.indexOf(u8, json, "\\\"quote\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\\\slash") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\n\\tnewline") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\u0001ctrl") != null);
}

test "ErrorContext.toJSON handles long messages without overflow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Build a 4096-byte message; old code had a 1024-byte stack buffer that
    // would have overflowed. New code grows dynamically.
    var long_msg_buf: [4096]u8 = undefined;
    @memset(&long_msg_buf, 'a');

    const ctx = ErrorContext.init(BridgeError.InvalidJSON, "parse", &long_msg_buf);
    const json = try ctx.toJSON(allocator);
    defer allocator.free(json);

    try testing.expect(json.len > 4096);
}

test "a reply names the call it answers" {
    const allocator = std.testing.allocator;
    const js = try formatResultJS(allocator, "getDisplays", "{\"displays\":[]}", 7);
    defer allocator.free(js);
    try std.testing.expectEqualStrings(
        "if(window.__craftBridgeResult)window.__craftBridgeResult('getDisplays',{\"displays\":[]},7);",
        js,
    );
}

test "a reply with no call to name says null, not a sentinel" {
    // An old page, or a reply raised outside dispatch. The page falls back to
    // matching by action name; it must not read this as "call number 0".
    const allocator = std.testing.allocator;
    const js = try formatResultJS(allocator, "getPrimary", "{}", null);
    defer allocator.free(js);
    try std.testing.expectEqualStrings(
        "if(window.__craftBridgeResult)window.__craftBridgeResult('getPrimary',{},null);",
        js,
    );
}

test "call zero is answered as zero" {
    const allocator = std.testing.allocator;
    const js = try formatResultJS(allocator, "a", "{}", 0);
    defer allocator.free(js);
    try std.testing.expect(std.mem.endsWith(u8, js, "('a',{},0);"));
}

test "the largest id JavaScript can hold survives the round trip" {
    // Number.MAX_SAFE_INTEGER. The page counts up from 1 and will never reach
    // it, but a buffer sized for a small id is the kind of thing that only
    // fails in the field.
    const allocator = std.testing.allocator;
    const js = try formatResultJS(allocator, "a", "{}", 9007199254740991);
    defer allocator.free(js);
    try std.testing.expect(std.mem.endsWith(u8, js, "('a',{},9007199254740991);"));
}

test "a failure names the call that failed" {
    const allocator = std.testing.allocator;
    var ctx = ErrorContext.init(BridgeError.NotFound, "get", "Resource not found");
    ctx.request_id = 42;
    const json = try ctx.toJSON(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"error\":true,\"code\":\"NOT_FOUND\",\"action\":\"get\",\"message\":\"Resource not found\",\"id\":42}",
        json,
    );

    // Still valid JSON with the field appended, not just string-equal.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("id").?.integer);
}

test "a failure outside any call carries no id at all" {
    // Not `"id":null` — absent. The page tells the two apart: an id it does not
    // recognise is a call that already settled and the error is dropped, while
    // no id at all is the old whole-action drain.
    const allocator = std.testing.allocator;
    const ctx = ErrorContext.init(BridgeError.NotFound, "get", "Resource not found");
    const json = try ctx.toJSON(allocator);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "id") == null);
}

test "the id survives an action name that needs escaping" {
    const allocator = std.testing.allocator;
    var ctx = ErrorContext.init(BridgeError.InvalidJSON, "we\"ird\\", "boom\nboom");
    ctx.request_id = 5;
    const json = try ctx.toJSON(allocator);
    defer allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 5), parsed.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("we\"ird\\", parsed.value.object.get("action").?.string);
}

test "the reply to a dispatched message names that message's call" {
    // The seam this whole change turns on, walked end to end: the id is read
    // out of the envelope the way `handleBridgeMessageJSON` reads it, recorded
    // the way the dispatcher records it, and read back the way
    // `sendResultToJS` reads it — without any of the 267 reply sites in
    // between being told about it.
    const allocator = std.testing.allocator;
    request_context.resetForTesting();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"t":"tags","a":"get","d":"{\"path\":\"/a\"}","i":12}
    ,
        .{},
    );
    defer parsed.deinit();

    request_context.push(request_context.fromEnvelope(parsed.value.object));
    defer request_context.pop();

    const js = try formatResultJS(allocator, "get", "{\"tags\":[]}", request_context.current());
    defer allocator.free(js);
    try std.testing.expect(std.mem.endsWith(u8, js, ",12);"));
}

test "a dialog's reply is not stamped with the call it dispatched while it waited" {
    // `runModal` spins a nested run loop that keeps delivering bridge
    // messages, so a second call is served in the middle of the first. The
    // dialog's own reply, sent after the inner one, still belongs to the outer
    // call — this is why the dispatcher keeps a stack.
    const allocator = std.testing.allocator;
    request_context.resetForTesting();

    request_context.push(4); // showOpenDialog, now blocked in runModal
    defer request_context.pop();
    {
        request_context.push(5); // a getState the nested run loop delivered
        defer request_context.pop();
        const inner = try formatResultJS(allocator, "getState", "{}", request_context.current());
        defer allocator.free(inner);
        try std.testing.expect(std.mem.endsWith(u8, inner, ",5);"));
    }

    const outer = try formatResultJS(allocator, "showOpenDialog", "{}", request_context.current());
    defer allocator.free(outer);
    try std.testing.expect(std.mem.endsWith(u8, outer, ",4);"));
}
