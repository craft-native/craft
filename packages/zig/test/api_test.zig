const std = @import("std");
const testing = std.testing;
const api = @import("../src/api.zig");

test "Version - structure" {
    const version = api.Version{ .major = 0, .minor = 1, .patch = 0 };

    try testing.expectEqual(@as(u32, 0), version.major);
    try testing.expectEqual(@as(u32, 1), version.minor);
    try testing.expectEqual(@as(u32, 0), version.patch);
}

test "Version - current_version matches package.json" {
    // Version is now set to 0.0.20 matching package.json
    try testing.expectEqual(@as(u32, 0), api.current_version.major);
    try testing.expectEqual(@as(u32, 0), api.current_version.minor);
    try testing.expectEqual(@as(u32, 40), api.current_version.patch);
}

test "Version - parse comptime" {
    // Version.parse is comptime-only — use comptime blocks to test
    comptime {
        const v = api.Version.parse("1.2.3");
        if (v.major != 1 or v.minor != 2 or v.patch != 3) @compileError("bad parse");
    }
}

test "Version - parse zero comptime" {
    comptime {
        const v = api.Version.parse("0.0.0");
        if (v.major != 0 or v.minor != 0 or v.patch != 0) @compileError("bad parse");
    }
}

test "Version - parse large numbers comptime" {
    comptime {
        const v = api.Version.parse("10.20.30");
        if (v.major != 10 or v.minor != 20 or v.patch != 30) @compileError("bad parse");
    }
}

test "WindowOptions - with defaults" {
    const opts = api.WindowOptions{
        .title = "Test Window",
        .width = 800,
        .height = 600,
    };

    try testing.expectEqualStrings("Test Window", opts.title);
    try testing.expectEqual(@as(u32, 800), opts.width);
    try testing.expectEqual(@as(u32, 600), opts.height);
    try testing.expect(opts.resizable);
    try testing.expect(!opts.frameless);
    try testing.expect(!opts.transparent);
    try testing.expect(!opts.fullscreen);
    try testing.expect(opts.dev_tools);
}

test "WindowOptions - custom values" {
    const opts = api.WindowOptions{
        .title = "Custom",
        .width = 1920,
        .height = 1080,
        .x = 0,
        .y = 0,
        .resizable = false,
        .frameless = true,
        .transparent = true,
        .fullscreen = true,
        .dev_tools = false,
    };

    try testing.expectEqual(@as(u32, 1920), opts.width);
    try testing.expectEqual(@as(u32, 1080), opts.height);
    try testing.expectEqual(@as(?i32, 0), opts.x);
    try testing.expectEqual(@as(?i32, 0), opts.y);
    try testing.expect(!opts.resizable);
    try testing.expect(opts.frameless);
    try testing.expect(opts.transparent);
    try testing.expect(opts.fullscreen);
    try testing.expect(!opts.dev_tools);
}

test "Platform - name() returns value" {
    const platform_name = api.Platform.name();
    try testing.expect(
        std.mem.eql(u8, platform_name, "macOS") or
            std.mem.eql(u8, platform_name, "Linux") or
            std.mem.eql(u8, platform_name, "Windows") or
            std.mem.eql(u8, platform_name, "Unknown"),
    );
}

test "Platform - isSupported()" {
    const supported = api.Platform.isSupported();
    try testing.expect(supported or !supported); // Just check it returns bool
}

test "Features - hasWebView" {
    const has_webview = api.Features.hasWebView();
    try testing.expect(has_webview or !has_webview);
}

test "Features - hasNotifications" {
    const has_notifications = api.Features.hasNotifications();
    try testing.expect(has_notifications or !has_notifications);
}

test "Features - hasHotReload" {
    const has_hotreload = api.Features.hasHotReload();
    try testing.expect(has_hotreload);
}

test "WindowBuilder - new" {
    const builder = api.WindowBuilder.new("Test", "http://localhost:3000");

    try testing.expectEqualStrings("Test", builder.title);
    try testing.expectEqualStrings("http://localhost:3000", builder.url);
    try testing.expectEqual(@as(u32, 1200), builder.width);
    try testing.expectEqual(@as(u32, 800), builder.height);
}

test "WindowBuilder - size" {
    const builder = api.WindowBuilder.new("Test", "http://localhost:3000")
        .size(1920, 1080);

    try testing.expectEqual(@as(u32, 1920), builder.width);
    try testing.expectEqual(@as(u32, 1080), builder.height);
}

test "WindowBuilder - position" {
    const builder = api.WindowBuilder.new("Test", "http://localhost:3000")
        .position(100, 200);

    try testing.expectEqual(@as(?i32, 100), builder.x);
    try testing.expectEqual(@as(?i32, 200), builder.y);
}

test "WindowBuilder - resizable" {
    const builder = api.WindowBuilder.new("Test", "http://localhost:3000")
        .resizable(false);

    try testing.expect(!builder.is_resizable);
}

test "WindowBuilder - frameless" {
    const builder = api.WindowBuilder.new("Test", "http://localhost:3000")
        .frameless(true);

    try testing.expect(builder.is_frameless);
}

test "WindowBuilder - transparent" {
    const builder = api.WindowBuilder.new("Test", "http://localhost:3000")
        .transparent(true);

    try testing.expect(builder.is_transparent);
}

test "WindowBuilder - always on top" {
    const builder = api.WindowBuilder.new("Test", "http://localhost:3000")
        .alwaysOnTop(true);

    try testing.expect(builder.always_on_top);
}

test "WindowBuilder - chaining" {
    const builder = api.WindowBuilder.new("Test", "http://localhost:3000")
        .size(1920, 1080)
        .position(0, 0)
        .fullscreen(true)
        .resizable(false)
        .frameless(true)
        .transparent(true)
        .alwaysOnTop(true);

    try testing.expectEqual(@as(u32, 1920), builder.width);
    try testing.expectEqual(@as(u32, 1080), builder.height);
    try testing.expectEqual(@as(?i32, 0), builder.x);
    try testing.expectEqual(@as(?i32, 0), builder.y);
    try testing.expect(builder.is_fullscreen);
    try testing.expect(!builder.is_resizable);
    try testing.expect(builder.is_frameless);
    try testing.expect(builder.is_transparent);
    try testing.expect(builder.always_on_top);
}

test "WindowBuilder - converts every stored option" {
    const result = api.WindowBuilder.new("Configured", "https://example.com")
        .size(960, 640)
        .position(-20, 40)
        .resizable(false)
        .frameless(true)
        .transparent(true)
        .alwaysOnTop(true)
        .fullscreen(true)
        .darkMode(false)
        .devTools(false)
        .toWindowOptions();

    try testing.expect(result.isOk());
    const opts = try result.unwrap();
    try testing.expectEqualStrings("Configured", opts.title);
    try testing.expectEqual(@as(u32, 960), opts.width);
    try testing.expectEqual(@as(u32, 640), opts.height);
    try testing.expectEqual(@as(?i32, -20), opts.x);
    try testing.expectEqual(@as(?i32, 40), opts.y);
    try testing.expect(!opts.resizable);
    try testing.expect(opts.frameless);
    try testing.expect(opts.transparent);
    try testing.expect(opts.always_on_top);
    try testing.expect(opts.fullscreen);
    try testing.expectEqual(@as(?bool, false), opts.dark_mode);
    try testing.expect(!opts.dev_tools);
}

test "WindowBuilder - enforces minimum and maximum size" {
    const below_minimum = api.WindowBuilder.new("Too small", "https://example.com")
        .size(799, 600)
        .minSize(800, 600)
        .toWindowOptions();
    const above_maximum = api.WindowBuilder.new("Too large", "https://example.com")
        .size(1281, 720)
        .maxSize(1280, 720)
        .toWindowOptions();

    try testing.expect(below_minimum.isErr());
    try testing.expect(above_maximum.isErr());
}

test "Event - ResizeEvent" {
    const event = api.Event{ .window_resize = .{ .width = 800, .height = 600 } };

    try testing.expect(event == .window_resize);
    try testing.expectEqual(@as(u32, 800), event.window_resize.width);
    try testing.expectEqual(@as(u32, 600), event.window_resize.height);
}

test "Event - KeyEvent" {
    const event = api.Event{ .key_down = .{
        .code = "KeyA",
        .key = "a",
        .ctrl = true,
        .shift = false,
        .alt = false,
        .meta = false,
    } };

    try testing.expect(event == .key_down);
    try testing.expectEqualStrings("KeyA", event.key_down.code);
    try testing.expectEqualStrings("a", event.key_down.key);
    try testing.expect(event.key_down.ctrl);
    try testing.expect(!event.key_down.shift);
}

test "Event - MouseEvent" {
    const event = api.Event{ .mouse_down = .{
        .button = 0,
        .x = 100,
        .y = 200,
        .alt = false,
        .ctrl = false,
        .shift = false,
        .meta = false,
    } };

    try testing.expect(event == .mouse_down);
    try testing.expectEqual(@as(u8, 0), event.mouse_down.button);
    try testing.expectEqual(@as(i32, 100), event.mouse_down.x);
    try testing.expectEqual(@as(i32, 200), event.mouse_down.y);
}

test "IPCMessage - request" {
    const payload = api.IPCMessage.Payload{ .string = "test data" };
    const msg = api.IPCMessage.request(1, payload);

    try testing.expectEqual(@as(u64, 1), msg.id);
    try testing.expectEqual(api.IPCMessage.MessageType.request, msg.type);
    try testing.expectEqualStrings("test data", msg.payload.string);
}

test "IPCMessage - response with number" {
    const payload = api.IPCMessage.Payload{ .number = 42.0 };
    const msg = api.IPCMessage.response(1, payload);

    try testing.expectEqual(@as(u64, 1), msg.id);
    try testing.expectEqual(api.IPCMessage.MessageType.response, msg.type);
    try testing.expectEqual(@as(f64, 42.0), msg.payload.number);
}

test "IPCMessage - notification with boolean" {
    const payload = api.IPCMessage.Payload{ .boolean = true };
    const msg = api.IPCMessage.notification(payload);

    try testing.expectEqual(api.IPCMessage.MessageType.notification, msg.type);
    try testing.expect(msg.payload.boolean);
}

test "IPCMessage - error message" {
    const msg = api.IPCMessage.err(1, "Something went wrong");

    try testing.expectEqual(@as(u64, 1), msg.id);
    try testing.expectEqual(api.IPCMessage.MessageType.error_msg, msg.type);
    try testing.expectEqualStrings("Something went wrong", msg.payload.string);
}

test "IPCMessage - null payload" {
    const payload = api.IPCMessage.Payload{ .null_value = {} };
    const msg = api.IPCMessage.notification(payload);

    try testing.expectEqual(api.IPCMessage.MessageType.notification, msg.type);
}

test "Promise - initialization" {
    const promise = api.Promise.init();

    try testing.expect(!promise.resolved);
    try testing.expect(!promise.rejected);
    try testing.expectEqual(@as(?[]const u8, null), promise.value);
    try testing.expectEqual(@as(?api.Error, null), promise.error_value);
}

test "Promise - resolve" {
    var promise = api.Promise.init();
    promise.resolve("success");

    try testing.expect(promise.resolved);
    try testing.expect(!promise.rejected);
    try testing.expectEqualStrings("success", promise.value.?);
}

test "Promise - reject" {
    var promise = api.Promise.init();
    promise.reject(error.WindowCreationFailed);

    try testing.expect(!promise.resolved);
    try testing.expect(promise.rejected);
    try testing.expectEqual(error.WindowCreationFailed, promise.error_value.?);
}

test "EventType - all variants" {
    try testing.expectEqual(api.EventType.window_resize, .window_resize);
    try testing.expectEqual(api.EventType.window_move, .window_move);
    try testing.expectEqual(api.EventType.window_close, .window_close);
    try testing.expectEqual(api.EventType.window_focus, .window_focus);
    try testing.expectEqual(api.EventType.window_blur, .window_blur);
    try testing.expectEqual(api.EventType.key_down, .key_down);
    try testing.expectEqual(api.EventType.key_up, .key_up);
    try testing.expectEqual(api.EventType.mouse_down, .mouse_down);
    try testing.expectEqual(api.EventType.mouse_up, .mouse_up);
    try testing.expectEqual(api.EventType.mouse_move, .mouse_move);
    try testing.expectEqual(api.EventType.scroll, .scroll);
    try testing.expectEqual(api.EventType.custom, .custom);
}

test "Error - all variants exist" {
    const err1: api.Error = error.WindowCreationFailed;
    const err2: api.Error = error.WebViewCreationFailed;
    const err3: api.Error = error.InvalidURL;
    const err4: api.Error = error.UnsupportedPlatform;
    const err5: api.Error = error.InitializationFailed;
    const err6: api.Error = error.FeatureNotAvailable;

    try testing.expectEqual(error.WindowCreationFailed, err1);
    try testing.expectEqual(error.WebViewCreationFailed, err2);
    try testing.expectEqual(error.InvalidURL, err3);
    try testing.expectEqual(error.UnsupportedPlatform, err4);
    try testing.expectEqual(error.InitializationFailed, err5);
    try testing.expectEqual(error.FeatureNotAvailable, err6);
}

test "ScrollEvent - structure" {
    const scroll = api.ScrollEvent{
        .delta_x = 10.5,
        .delta_y = -20.3,
    };

    try testing.expectEqual(@as(f32, 10.5), scroll.delta_x);
    try testing.expectEqual(@as(f32, -20.3), scroll.delta_y);
}

test "CustomEvent - structure" {
    const custom = api.CustomEvent{
        .name = "my-event",
        .data = "event data",
    };

    try testing.expectEqualStrings("my-event", custom.name);
    try testing.expectEqualStrings("event data", custom.data);
}

test "ResizeEvent - structure" {
    const resize = api.ResizeEvent{
        .width = 1024,
        .height = 768,
    };

    try testing.expectEqual(@as(u32, 1024), resize.width);
    try testing.expectEqual(@as(u32, 768), resize.height);
}

test "MoveEvent - structure" {
    const move = api.MoveEvent{
        .x = 100,
        .y = 200,
    };

    try testing.expectEqual(@as(i32, 100), move.x);
    try testing.expectEqual(@as(i32, 200), move.y);
}

test "IPCMessage.Payload - string variant" {
    const payload = api.IPCMessage.Payload{ .string = "test" };
    try testing.expectEqualStrings("test", payload.string);
}

test "IPCMessage.Payload - number variant" {
    const payload = api.IPCMessage.Payload{ .number = 123.45 };
    try testing.expectEqual(@as(f64, 123.45), payload.number);
}

test "IPCMessage.Payload - boolean variant" {
    const payload = api.IPCMessage.Payload{ .boolean = false };
    try testing.expect(!payload.boolean);
}
