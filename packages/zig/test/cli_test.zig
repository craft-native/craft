const std = @import("std");
const testing = std.testing;
const cli = @import("../src/cli.zig");

test "WindowOptions - default values" {
    const options = cli.WindowOptions{};

    try testing.expect(options.url == null);
    try testing.expect(options.html == null);
    try testing.expectEqualStrings("Craft App", options.title);
    try testing.expectEqual(@as(u32, 1200), options.width);
    try testing.expectEqual(@as(u32, 800), options.height);
    try testing.expect(options.x == null);
    try testing.expect(options.y == null);
    try testing.expect(!options.frameless);
    try testing.expect(!options.transparent);
    try testing.expect(!options.always_on_top);
    try testing.expect(options.resizable);
    try testing.expect(!options.fullscreen);
    try testing.expect(!options.dev_tools); // CLI defaults to false; enable via --dev-tools flag
    try testing.expect(options.dark_mode == null);
    try testing.expect(!options.hot_reload);
    try testing.expect(!options.system_tray);
}

test "WindowOptions - custom values" {
    const options = cli.WindowOptions{
        .url = "http://example.com",
        .html = "<h1>Test</h1>",
        .title = "Custom Title",
        .width = 800,
        .height = 600,
        .x = 100,
        .y = 50,
        .frameless = true,
        .transparent = true,
        .always_on_top = true,
        .resizable = false,
        .fullscreen = true,
        .dev_tools = false,
        .dark_mode = true,
        .hot_reload = true,
        .system_tray = true,
    };

    try testing.expectEqualStrings("http://example.com", options.url.?);
    try testing.expectEqualStrings("<h1>Test</h1>", options.html.?);
    try testing.expectEqualStrings("Custom Title", options.title);
    try testing.expectEqual(@as(u32, 800), options.width);
    try testing.expectEqual(@as(u32, 600), options.height);
    try testing.expectEqual(@as(i32, 100), options.x.?);
    try testing.expectEqual(@as(i32, 50), options.y.?);
    try testing.expect(options.frameless);
    try testing.expect(options.transparent);
    try testing.expect(options.always_on_top);
    try testing.expect(!options.resizable);
    try testing.expect(options.fullscreen);
    try testing.expect(!options.dev_tools);
    try testing.expectEqual(true, options.dark_mode.?);
    try testing.expect(options.hot_reload);
    try testing.expect(options.system_tray);
}

test "CliError - error types exist" {
    // Verify error types can be assigned to CliError
    const err1: cli.CliError = error.InvalidArgument;
    const err2: cli.CliError = error.MissingValue;
    const err3: cli.CliError = error.InvalidNumber;

    // Just verify they are the expected error values
    try testing.expectEqual(cli.CliError.InvalidArgument, err1);
    try testing.expectEqual(cli.CliError.MissingValue, err2);
    try testing.expectEqual(cli.CliError.InvalidNumber, err3);
}

test "version output includes the release and platform" {
    var buffer: [128]u8 = undefined;
    const output = try cli.formatVersion(&buffer, "1.2.3", "macOS");

    try testing.expectEqualStrings(
        "craft version 1.2.3\nBuilt with Zig 0.17.0-dev\nPlatform: macOS\n\n",
        output,
    );
}

test "WindowOptions - position coordinates" {
    const options = cli.WindowOptions{
        .x = -100,
        .y = 2000,
    };

    try testing.expectEqual(@as(i32, -100), options.x.?);
    try testing.expectEqual(@as(i32, 2000), options.y.?);
}

test "WindowOptions - minimum dimensions" {
    const options = cli.WindowOptions{
        .width = 1,
        .height = 1,
    };

    try testing.expectEqual(@as(u32, 1), options.width);
    try testing.expectEqual(@as(u32, 1), options.height);
}

test "WindowOptions - large dimensions" {
    const options = cli.WindowOptions{
        .width = 4096,
        .height = 2160,
    };

    try testing.expectEqual(@as(u32, 4096), options.width);
    try testing.expectEqual(@as(u32, 2160), options.height);
}

test "WindowOptions - dark_mode three states" {
    const options1 = cli.WindowOptions{ .dark_mode = true };
    const options2 = cli.WindowOptions{ .dark_mode = false };
    const options3 = cli.WindowOptions{ .dark_mode = null };

    try testing.expectEqual(true, options1.dark_mode.?);
    try testing.expectEqual(false, options2.dark_mode.?);
    try testing.expect(options3.dark_mode == null);
}

test "WindowOptions - url and html mutually exclusive usage" {
    const options1 = cli.WindowOptions{
        .url = "http://example.com",
        .html = null,
    };

    const options2 = cli.WindowOptions{
        .url = null,
        .html = "<h1>Test</h1>",
    };

    try testing.expectEqualStrings("http://example.com", options1.url.?);
    try testing.expect(options1.html == null);

    try testing.expect(options2.url == null);
    try testing.expectEqualStrings("<h1>Test</h1>", options2.html.?);
}

test "WindowOptions - boolean flags combinations" {
    const options = cli.WindowOptions{
        .frameless = true,
        .transparent = true,
        .always_on_top = true,
        .fullscreen = false,
    };

    try testing.expect(options.frameless);
    try testing.expect(options.transparent);
    try testing.expect(options.always_on_top);
    try testing.expect(!options.fullscreen);
}

test "WindowOptions - feature flags" {
    const options = cli.WindowOptions{
        .dev_tools = false,
        .hot_reload = true,
        .system_tray = true,
    };

    try testing.expect(!options.dev_tools);
    try testing.expect(options.hot_reload);
    try testing.expect(options.system_tray);
}

test "WindowOptions - title variations" {
    const options1 = cli.WindowOptions{ .title = "" };
    const options2 = cli.WindowOptions{ .title = "A" };
    const options3 = cli.WindowOptions{ .title = "Very Long Title With Many Words And Special Characters !@#$%^&*()" };

    try testing.expectEqualStrings("", options1.title);
    try testing.expectEqualStrings("A", options2.title);
    try testing.expect(options3.title.len > 50);
}

test "WindowOptions - coordinate extremes" {
    const options = cli.WindowOptions{
        .x = -32768,
        .y = 32767,
    };

    try testing.expectEqual(@as(i32, -32768), options.x.?);
    try testing.expectEqual(@as(i32, 32767), options.y.?);
}

test "WindowOptions - all boolean flags false" {
    const options = cli.WindowOptions{
        .frameless = false,
        .transparent = false,
        .always_on_top = false,
        .resizable = false,
        .fullscreen = false,
        .dev_tools = false,
        .hot_reload = false,
        .system_tray = false,
    };

    try testing.expect(!options.frameless);
    try testing.expect(!options.transparent);
    try testing.expect(!options.always_on_top);
    try testing.expect(!options.resizable);
    try testing.expect(!options.fullscreen);
    try testing.expect(!options.dev_tools);
    try testing.expect(!options.hot_reload);
    try testing.expect(!options.system_tray);
}

test "WindowOptions - all boolean flags true" {
    const options = cli.WindowOptions{
        .frameless = true,
        .transparent = true,
        .always_on_top = true,
        .resizable = true,
        .fullscreen = true,
        .dev_tools = true,
        .hot_reload = true,
        .system_tray = true,
    };

    try testing.expect(options.frameless);
    try testing.expect(options.transparent);
    try testing.expect(options.always_on_top);
    try testing.expect(options.resizable);
    try testing.expect(options.fullscreen);
    try testing.expect(options.dev_tools);
    try testing.expect(options.hot_reload);
    try testing.expect(options.system_tray);
}

// =============================================================================
// parseArgs
// =============================================================================
//
// These drive the real parser rather than constructing a `WindowOptions` by
// hand, which is what the tests above do. A flag that is declared but never
// wired into the argument loop passes every struct-shaped test in this file
// and does nothing at all on the command line.

fn parse(args: []const [:0]const u8) !cli.WindowOptions {
    return cli.parseArgs(testing.allocator, args);
}

fn freeOptions(options: *cli.WindowOptions) void {
    cli.freeOptionStrings(testing.allocator, options);
}

test "parseArgs - --app-name is read and owned" {
    var options = try parse(&.{ "craft", "--app-name", "Harness" });
    defer freeOptions(&options);
    try testing.expectEqualStrings("Harness", options.app_name.?);
    // The window title is a separate thing and must not be touched by it.
    try testing.expectEqualStrings("Craft App", options.title);
}

test "parseArgs - --app-name and --title are independent" {
    var options = try parse(&.{ "craft", "--app-name", "Hush", "--title", "Untitled" });
    defer freeOptions(&options);
    try testing.expectEqualStrings("Hush", options.app_name.?);
    try testing.expectEqualStrings("Untitled", options.title);
}

test "parseArgs - --app-name defaults to absent" {
    var options = try parse(&.{ "craft", "http://localhost:3000" });
    defer freeOptions(&options);
    try testing.expect(options.app_name == null);
}

test "parseArgs - --app-name without a value is an error, not a silent skip" {
    try testing.expectError(cli.CliError.MissingValue, parse(&.{ "craft", "--app-name" }));
}

test "parseArgs - a name with spaces survives as one argument" {
    var options = try parse(&.{ "craft", "--app-name", "My Great App" });
    defer freeOptions(&options);
    try testing.expectEqualStrings("My Great App", options.app_name.?);
}

test "parseArgs - --frame-autosave is read and owned" {
    var options = try parse(&.{ "craft", "--frame-autosave", "main" });
    defer freeOptions(&options);
    try testing.expectEqualStrings("main", options.frame_autosave.?);
}

test "parseArgs - --frame-autosave defaults to absent" {
    // Absent means the window forgets its geometry, which is what craft did
    // before this flag existed and must keep doing for apps that never ask.
    var options = try parse(&.{ "craft", "http://localhost:3000" });
    defer freeOptions(&options);
    try testing.expect(options.frame_autosave == null);
}

test "parseArgs - --frame-autosave leaves the explicit geometry alone" {
    // The two are not alternatives: the geometry flags are what the window
    // opens at the first time, before anything has been saved to restore.
    var options = try parse(&.{
        "craft",           "--frame-autosave", "main", "--width", "900",
        "--height",        "700",              "--x",  "40",      "--y",
        "60",
    });
    defer freeOptions(&options);
    try testing.expectEqualStrings("main", options.frame_autosave.?);
    try testing.expectEqual(@as(u32, 900), options.width);
    try testing.expectEqual(@as(u32, 700), options.height);
    try testing.expectEqual(@as(i32, 40), options.x.?);
    try testing.expectEqual(@as(i32, 60), options.y.?);
}

test "parseArgs - --frame-autosave without a value is an error, not a silent skip" {
    try testing.expectError(cli.CliError.MissingValue, parse(&.{ "craft", "--frame-autosave" }));
}
