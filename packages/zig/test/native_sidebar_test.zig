const std = @import("std");
const testing = std.testing;
const cli = @import("../src/cli.zig");
const javascript = @import("javascript");
const native_sidebar_bootstrap = @import("native_sidebar_bootstrap");

// ============================================
// Native Sidebar CLI Options
// ============================================

test "WindowOptions - native_sidebar defaults to false" {
    const options = cli.WindowOptions{};
    try testing.expect(!options.native_sidebar);
}

test "WindowOptions - native_sidebar can be enabled" {
    const options = cli.WindowOptions{
        .native_sidebar = true,
    };
    try testing.expect(options.native_sidebar);
}

test "native sidebar bootstrap exposes a stable document marker" {
    try testing.expect(std.mem.indexOf(
        u8,
        native_sidebar_bootstrap.script,
        "data-craft-native-sidebar",
    ) != null);
}

test "native sidebar navigation serializes configured URLs as JavaScript data" {
    const script = try javascript.buildNavigationScript(
        testing.allocator,
        "/settings/\"quote\"\\path\nnext",
    );
    defer testing.allocator.free(script);

    try testing.expectEqualStrings(
        "(() => { const url = \"/settings/\\\"quote\\\"\\\\path\\nnext\"; return typeof window.navigate === 'function' ? window.navigate(url) : (window.location.href = url); })()",
        script,
    );
}

test "WindowOptions - sidebar_width defaults to 220" {
    const options = cli.WindowOptions{};
    try testing.expectEqual(@as(u32, 220), options.sidebar_width);
}

test "WindowOptions - sidebar_width can be customized" {
    const options = cli.WindowOptions{
        .sidebar_width = 240,
    };
    try testing.expectEqual(@as(u32, 240), options.sidebar_width);
}

test "WindowOptions - sidebar_width narrow" {
    const options = cli.WindowOptions{
        .sidebar_width = 150,
    };
    try testing.expectEqual(@as(u32, 150), options.sidebar_width);
}

test "WindowOptions - sidebar_width wide" {
    const options = cli.WindowOptions{
        .sidebar_width = 400,
    };
    try testing.expectEqual(@as(u32, 400), options.sidebar_width);
}

test "WindowOptions - sidebar_config defaults to null" {
    const options = cli.WindowOptions{};
    try testing.expect(options.sidebar_config == null);
}

test "WindowOptions - sidebar_config can be set" {
    const config = "{\"sections\":[]}";
    const options = cli.WindowOptions{
        .sidebar_config = config,
    };
    try testing.expect(options.sidebar_config != null);
    try testing.expectEqualStrings("{\"sections\":[]}", options.sidebar_config.?);
}

// ============================================
// Native Sidebar with URL mode
// ============================================

test "WindowOptions - native sidebar with URL" {
    const options = cli.WindowOptions{
        .url = "http://localhost:3456/app?native-sidebar=1",
        .native_sidebar = true,
        .sidebar_width = 240,
    };

    try testing.expect(options.native_sidebar);
    try testing.expectEqual(@as(u32, 240), options.sidebar_width);
    try testing.expectEqualStrings("http://localhost:3456/app?native-sidebar=1", options.url.?);
}

test "WindowOptions - native sidebar with HTML" {
    const options = cli.WindowOptions{
        .html = "<h1>Dashboard</h1>",
        .native_sidebar = true,
        .sidebar_width = 260,
    };

    try testing.expect(options.native_sidebar);
    try testing.expectEqual(@as(u32, 260), options.sidebar_width);
    try testing.expectEqualStrings("<h1>Dashboard</h1>", options.html.?);
}

// ============================================
// Full dashboard-like configuration
// ============================================

test "WindowOptions - full dashboard config" {
    const sidebar_json =
        \\{"sections":[{"id":"home","title":"Home","items":[{"id":"home","label":"Dashboard","icon":"house.fill","url":"/pages/index"}]}]}
    ;

    const options = cli.WindowOptions{
        .url = "http://localhost:3456/app?native-sidebar=1",
        .title = "Stacks Dashboard",
        .width = 1400,
        .height = 900,
        .titlebar_hidden = true,
        .native_sidebar = true,
        .sidebar_width = 240,
        .sidebar_config = sidebar_json,
    };

    try testing.expectEqualStrings("Stacks Dashboard", options.title);
    try testing.expectEqual(@as(u32, 1400), options.width);
    try testing.expectEqual(@as(u32, 900), options.height);
    try testing.expect(options.titlebar_hidden);
    try testing.expect(options.native_sidebar);
    try testing.expectEqual(@as(u32, 240), options.sidebar_width);
    try testing.expect(options.sidebar_config != null);
}

test "WindowOptions - native sidebar does not imply system tray" {
    const options = cli.WindowOptions{
        .native_sidebar = true,
    };

    try testing.expect(options.native_sidebar);
    try testing.expect(!options.system_tray);
    try testing.expect(!options.hide_dock_icon);
}

test "WindowOptions - native sidebar with dark mode" {
    const options = cli.WindowOptions{
        .native_sidebar = true,
        .dark_mode = true,
    };

    try testing.expect(options.native_sidebar);
    try testing.expectEqual(true, options.dark_mode.?);
}

test "WindowOptions - native sidebar with light mode" {
    const options = cli.WindowOptions{
        .native_sidebar = true,
        .dark_mode = false,
    };

    try testing.expect(options.native_sidebar);
    try testing.expectEqual(false, options.dark_mode.?);
}

// ============================================
// CLI argument parsing
// ============================================

test "parseArgs - native-sidebar flag" {
    const allocator = testing.allocator;
    const args = [_][:0]const u8{ "craft", "--native-sidebar", "--url", "http://localhost:3456" };
    const options = try cli.parseArgs(allocator, &args);

    try testing.expect(options.native_sidebar);
    try testing.expectEqualStrings("http://localhost:3456", options.url.?);

    allocator.free(options.url.?);
}

test "parseArgs - sidebar-width flag" {
    const allocator = testing.allocator;
    const args = [_][:0]const u8{ "craft", "--native-sidebar", "--sidebar-width", "240", "--url", "http://localhost:3456" };
    const options = try cli.parseArgs(allocator, &args);

    try testing.expect(options.native_sidebar);
    try testing.expectEqual(@as(u32, 240), options.sidebar_width);

    allocator.free(options.url.?);
}

test "parseArgs - sidebar-config flag" {
    const allocator = testing.allocator;
    const config_json = "{\"sections\":[]}";
    const args = [_][:0]const u8{ "craft", "--native-sidebar", "--sidebar-config", config_json, "--url", "http://localhost:3456" };
    const options = try cli.parseArgs(allocator, &args);

    try testing.expect(options.native_sidebar);
    try testing.expect(options.sidebar_config != null);
    try testing.expectEqualStrings("{\"sections\":[]}", options.sidebar_config.?);

    allocator.free(options.url.?);
    allocator.free(options.sidebar_config.?);
}

test "parseArgs - all native sidebar flags together" {
    const allocator = testing.allocator;
    const config_json = "{\"sections\":[{\"id\":\"home\"}]}";
    const args = [_][:0]const u8{
        "craft",
        "--url",
        "http://localhost:3456/app?native-sidebar=1",
        "--title",
        "Dashboard",
        "--width",
        "1400",
        "--height",
        "900",
        "--titlebar-hidden",
        "--native-sidebar",
        "--sidebar-width",
        "240",
        "--sidebar-config",
        config_json,
    };
    const options = try cli.parseArgs(allocator, &args);

    try testing.expectEqualStrings("http://localhost:3456/app?native-sidebar=1", options.url.?);
    try testing.expectEqualStrings("Dashboard", options.title);
    try testing.expectEqual(@as(u32, 1400), options.width);
    try testing.expectEqual(@as(u32, 900), options.height);
    try testing.expect(options.titlebar_hidden);
    try testing.expect(options.native_sidebar);
    try testing.expectEqual(@as(u32, 240), options.sidebar_width);
    try testing.expect(options.sidebar_config != null);

    allocator.free(options.url.?);
    allocator.free(options.title);
    allocator.free(options.sidebar_config.?);
}

test "parseArgs - sidebar-width without native-sidebar" {
    const allocator = testing.allocator;
    const args = [_][:0]const u8{ "craft", "--sidebar-width", "300", "--url", "http://localhost:3456" };
    const options = try cli.parseArgs(allocator, &args);

    // sidebar-width is set but native_sidebar is still false
    try testing.expect(!options.native_sidebar);
    try testing.expectEqual(@as(u32, 300), options.sidebar_width);

    allocator.free(options.url.?);
}

test "parseArgs - default sidebar-width when native-sidebar enabled" {
    const allocator = testing.allocator;
    const args = [_][:0]const u8{ "craft", "--native-sidebar", "--url", "http://localhost:3456" };
    const options = try cli.parseArgs(allocator, &args);

    try testing.expect(options.native_sidebar);
    try testing.expectEqual(@as(u32, 220), options.sidebar_width);

    allocator.free(options.url.?);
}

// ============================================
// Web material span
// ============================================

test "WindowOptions - the web material spans a sidebar strip by default" {
    const options = cli.WindowOptions{};
    try testing.expect(!options.web_sidebar_material);
    try testing.expect(!options.web_window_material);
}

test "the span marker names the shape the page has to lay itself out over" {
    // A page cannot infer this. `data-craft-native-sidebar` is true of both
    // spans, and the difference between them — whether there is an opaque
    // content pane beside the material — decides whether the page paints its
    // own background or leaves the material showing.
    try testing.expectEqualStrings(
        "document.documentElement.setAttribute('data-craft-web-material','sidebar');",
        native_sidebar_bootstrap.spanMarker(.sidebar),
    );
    try testing.expectEqualStrings(
        "document.documentElement.setAttribute('data-craft-web-material','window');",
        native_sidebar_bootstrap.spanMarker(.window),
    );
}
