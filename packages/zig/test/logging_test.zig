const std = @import("std");
const testing = std.testing;
const logging = @import("../src/logging.zig");

test "LogLevel ordering" {
    try testing.expect(@backingInt(logging.LogLevel.trace) < @backingInt(logging.LogLevel.debug));
    try testing.expect(@backingInt(logging.LogLevel.debug) < @backingInt(logging.LogLevel.info));
    try testing.expect(@backingInt(logging.LogLevel.info) < @backingInt(logging.LogLevel.warn));
    try testing.expect(@backingInt(logging.LogLevel.warn) < @backingInt(logging.LogLevel.err));
    try testing.expect(@backingInt(logging.LogLevel.err) < @backingInt(logging.LogLevel.fatal));
    try testing.expect(@backingInt(logging.LogLevel.fatal) < @backingInt(logging.LogLevel.off));
}

test "LogLevel asText" {
    try testing.expectEqualStrings("TRACE", logging.LogLevel.trace.asText());
    try testing.expectEqualStrings("DEBUG", logging.LogLevel.debug.asText());
    try testing.expectEqualStrings("INFO", logging.LogLevel.info.asText());
    try testing.expectEqualStrings("WARN", logging.LogLevel.warn.asText());
    try testing.expectEqualStrings("ERROR", logging.LogLevel.err.asText());
    try testing.expectEqualStrings("FATAL", logging.LogLevel.fatal.asText());
    try testing.expectEqualStrings("OFF", logging.LogLevel.off.asText());
}

test "LogLevel asColor" {
    // Colors should be non-empty except for 'off'
    try testing.expect(logging.LogLevel.trace.asColor().len > 0);
    try testing.expect(logging.LogLevel.debug.asColor().len > 0);
    try testing.expect(logging.LogLevel.info.asColor().len > 0);
    try testing.expect(logging.LogLevel.warn.asColor().len > 0);
    try testing.expect(logging.LogLevel.err.asColor().len > 0);
    try testing.expect(logging.LogLevel.fatal.asColor().len > 0);
    try testing.expectEqual(@as(usize, 0), logging.LogLevel.off.asColor().len);
}

test "LogTarget enum" {
    // Just verify the enum values exist
    _ = logging.LogTarget.stderr;
    _ = logging.LogTarget.stdout;
    _ = logging.LogTarget.file;
    _ = logging.LogTarget.callback;
    _ = logging.LogTarget.none;
}

test "LogConfig defaults" {
    const config = logging.LogConfig{};

    // Verify defaults
    try testing.expect(config.colored == true);
    try testing.expect(config.show_timestamp == true);
    try testing.expect(config.show_module == true);
    try testing.expect(config.file_path == null);
    try testing.expect(config.callback == null);
}

test "scoped logger creation" {
    const myLog = logging.scoped("TestModule");

    // Just verify it compiles and the type has expected functions
    _ = &myLog.trace;
    _ = &myLog.debug;
    _ = &myLog.info;
    _ = &myLog.warn;
    _ = &myLog.err;
    _ = &myLog.fatal;
}

test "predefined module loggers exist" {
    // Verify all predefined loggers are accessible
    _ = &logging.bridge.debug;
    _ = &logging.dialog.debug;
    _ = &logging.clipboard.debug;
    _ = &logging.notification.debug;
    _ = &logging.menu.debug;
    _ = &logging.tray.debug;
    _ = &logging.fs.debug;
    _ = &logging.network.debug;
    _ = &logging.power.debug;
    _ = &logging.window.debug;
    _ = &logging.system.debug;
    _ = &logging.webview.debug;
    _ = &logging.marketplace.debug;
    _ = &logging.shortcuts.debug;
}

test "setLevel and getLevel" {
    // Save original level
    const original = logging.getLevel();

    logging.setLevel(.warn);
    try testing.expectEqual(logging.LogLevel.warn, logging.getLevel());

    logging.setLevel(.debug);
    try testing.expectEqual(logging.LogLevel.debug, logging.getLevel());

    // Restore original
    logging.setLevel(original);
}

test "init and deinit" {
    // Test initialization with various configs
    logging.init(.{
        .level = .debug,
        .target = .none, // Use 'none' for testing to avoid output
        .colored = false,
    });

    try testing.expectEqual(logging.LogLevel.debug, logging.getLevel());

    logging.deinit();
}

test "init with callback" {
    var callback_called = false;

    const testCallback = struct {
        fn callback(level: logging.LogLevel, module: []const u8, message: []const u8) void {
            _ = level;
            _ = module;
            _ = message;
            // Note: Can't modify callback_called from here due to capture limitations
            // This test just verifies the callback signature is correct
        }
    }.callback;

    logging.init(.{
        .level = .info,
        .target = .callback,
        .callback = testCallback,
    });

    // Just verify it doesn't crash
    _ = callback_called;

    logging.deinit();
}

test "convenience functions exist" {
    // Just verify these compile - don't actually log in tests
    _ = &logging.trace;
    _ = &logging.debug;
    _ = &logging.info;
    _ = &logging.warn;
    _ = &logging.err;
    _ = &logging.fatal;
}
