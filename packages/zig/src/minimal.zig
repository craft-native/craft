const std = @import("std");
const builtin = @import("builtin");
const craft = @import("craft");
const cli = @import("cli.zig");
const io_context = craft.io_context;
// Reached through the craft module: a file cannot belong to both `root` and
// `craft`, and macos.zig already owns it there.
const timing = craft.startup_timing;

pub fn main(init: std.process.Init) !void {
    io_context.init(init.io);
    const allocator = init.gpa;

    // Parse CLI arguments
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Started before parsing, from the raw argv: the flag that turns timing on
    // is itself discovered during a phase we want to measure, so waiting for
    // the parsed options would hide argument parsing from its own report.
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--timing")) {
            timing.start();
            break;
        }
    }

    const options = cli.parseArgs(allocator, args) catch |err| {
        switch (err) {
            cli.CliError.InvalidArgument => std.debug.print("Error: Invalid argument\n", .{}),
            cli.CliError.MissingValue => std.debug.print("Error: Missing value for argument\n", .{}),
            cli.CliError.InvalidNumber => std.debug.print("Error: Invalid number format\n", .{}),
            else => std.debug.print("Error: {}\n", .{err}),
        }
        std.process.exit(1);
    };

    // parseArgs dupes every string option, and until now nothing freed them on
    // a successful run — invisible while `app.run()` never returned, but the
    // moment a path exits (benchmark mode) the allocator reports the leak.
    defer {
        var owned = options;
        cli.freeOptionStrings(allocator, &owned);
    }

    // Before anything builds a menu bar: `createApplicationMenu` reads the
    // process name once, and both branches below reach it.
    if (comptime builtin.os.tag == .macos) {
        if (options.app_name) |name| craft.macos.setProcessName(name);
    }

    // A menubar-only app has no window by definition, so asking for both is a
    // contradiction rather than a no-op. Saying so beats silently ignoring one
    // of them and leaving the operator to work out which.
    if (options.headless and options.menubar_only) {
        std.debug.print("Error: --headless and --menubar-only are contradictory — a menubar app has no window to hide\n", .{});
        std.process.exit(1);
    }

    // In benchmark mode, disable dev_tools for lower overhead
    const effective_dev_tools = if (options.benchmark) false else options.dev_tools;

    // Special handling for system tray apps - use direct approach like minimal test
    if (options.system_tray) {
        try runWithSystemTray(allocator, options);
        return;
    }

    timing.mark(.args_parsed);

    // Evaluate and exit, before any AppKit or WebKit setup. That ordering is
    // the feature: running a script costs a process, not a window and a
    // WebContent process behind it.
    if (options.eval_source != null or options.eval_file != null) {
        try runEval(allocator, options);
        return;
    }

    var app = craft.App.init(allocator);
    app.headless = options.headless;
    defer app.deinit();

    // Initialize platform FIRST (must be called before creating windows or system tray)
    // This calls finishLaunching on macOS which is required for menubar items
    app.initPlatform();
    timing.mark(.platform_init);

    // Determine what to load
    if (options.native_sidebar and options.url != null) {
        // Create window with native macOS sidebar loading a URL
        const url = options.url.?;
        if (!options.benchmark and !options.quiet) {
            std.debug.print("\n⚡ Creating window with native macOS sidebar (URL mode)\n", .{});
            std.debug.print("   Title: {s}\n", .{options.title});
            std.debug.print("   URL: {s}\n", .{url});
            std.debug.print("   Size: {d}x{d}\n", .{ options.width, options.height });
            std.debug.print("   Sidebar Width: {d}px\n", .{options.sidebar_width});
            if (options.dark_mode) |is_dark| std.debug.print("   Theme: {s}\n", .{if (is_dark) "Dark" else "Light"});
            std.debug.print("\n", .{});
        }

        _ = try app.createWindowWithNativeSidebarURL(
            options.title,
            options.width,
            options.height,
            url,
            options.sidebar_width,
            options.sidebar_config,
            .{
                .frameless = options.frameless,
                .transparent = options.transparent,
                .always_on_top = options.always_on_top,
                .resizable = options.resizable,
                .fullscreen = options.fullscreen,
                .x = options.x,
                .y = options.y,
                .dark_mode = options.dark_mode,
                .enable_hot_reload = options.hot_reload,
                .hide_dock_icon = options.hide_dock_icon,
                .titlebar_hidden = options.titlebar_hidden,
                .system_tray = options.system_tray,
                .dev_tools = effective_dev_tools,
                .native_sidebar = true,
                .benchmark = options.benchmark,
                .headless = options.headless,
                .frame_autosave = options.frame_autosave,
            },
        );
    } else if (options.native_sidebar and options.html != null) {
        // Create window with native macOS sidebar (inline HTML mode)
        const html = options.html.?;
        if (!options.benchmark and !options.quiet) {
            std.debug.print("\n⚡ Creating window with native macOS sidebar (HTML mode)\n", .{});
            std.debug.print("   Title: {s}\n", .{options.title});
            std.debug.print("   Size: {d}x{d}\n", .{ options.width, options.height });
            std.debug.print("   Sidebar Width: {d}px\n", .{options.sidebar_width});
            if (options.dark_mode) |is_dark| std.debug.print("   Theme: {s}\n", .{if (is_dark) "Dark" else "Light"});
            std.debug.print("\n", .{});
        }

        _ = try app.createWindowWithNativeSidebar(
            options.title,
            options.width,
            options.height,
            html,
            options.sidebar_width,
            options.sidebar_config,
            .{
                .frameless = options.frameless,
                .transparent = options.transparent,
                .always_on_top = options.always_on_top,
                .resizable = options.resizable,
                .fullscreen = options.fullscreen,
                .x = options.x,
                .y = options.y,
                .dark_mode = options.dark_mode,
                .enable_hot_reload = options.hot_reload,
                .hide_dock_icon = options.hide_dock_icon,
                .titlebar_hidden = options.titlebar_hidden,
                .system_tray = options.system_tray,
                .dev_tools = effective_dev_tools,
                .native_sidebar = true,
                .benchmark = options.benchmark,
                .headless = options.headless,
                .frame_autosave = options.frame_autosave,
            },
        );
    } else if (options.url) |url| {
        // Load URL directly (no iframe!)
        if (!options.benchmark and !options.quiet) {
            std.debug.print("\n⚡ Loading URL in native window: {s}\n", .{url});
            std.debug.print("   Title: {s}\n", .{options.title});
            std.debug.print("   Size: {d}x{d}\n", .{ options.width, options.height });
            if (options.frameless) std.debug.print("   Style: Frameless\n", .{});
            if (options.transparent) std.debug.print("   Style: Transparent\n", .{});
            if (options.always_on_top) std.debug.print("   Style: Always on top\n", .{});
            if (options.dark_mode) |is_dark| std.debug.print("   Theme: {s}\n", .{if (is_dark) "Dark" else "Light"});
            if (options.hot_reload) std.debug.print("   Hot Reload: Enabled\n", .{});
            if (options.system_tray) std.debug.print("   System Tray: Enabled\n", .{});
            if (options.hide_dock_icon) std.debug.print("   Dock Icon: Hidden (menubar-only mode)\n", .{});
            if (options.dev_tools) std.debug.print("   DevTools: Enabled (Right-click > Inspect Element)\n", .{});
            std.debug.print("\n", .{});
        }

        _ = try app.createWindowWithURL(
            options.title,
            options.width,
            options.height,
            url,
            .{
                .frameless = options.frameless,
                .transparent = options.transparent,
                .always_on_top = options.always_on_top,
                .resizable = options.resizable,
                .fullscreen = options.fullscreen,
                .x = options.x,
                .y = options.y,
                .dark_mode = options.dark_mode,
                .enable_hot_reload = options.hot_reload,
                .hide_dock_icon = options.hide_dock_icon,
                .titlebar_hidden = options.titlebar_hidden,
                .system_tray = options.system_tray,
                .dev_tools = effective_dev_tools,
                .benchmark = options.benchmark,
                .headless = options.headless,
                .frame_autosave = options.frame_autosave,
                .web_sidebar_material = options.web_sidebar_material,
                .web_sidebar_width = options.web_sidebar_width,
                .web_sidebar_material_opacity = options.web_sidebar_material_opacity,
            },
        );
    } else if (options.html) |html| {
        // Load HTML content
        if (!options.benchmark and !options.quiet) {
            std.debug.print("\n⚡ Loading HTML content in native window\n", .{});
            std.debug.print("   Title: {s}\n", .{options.title});
            std.debug.print("   Size: {d}x{d}\n\n", .{ options.width, options.height });
        }

        _ = try app.createWindowWithHTML(
            options.title,
            options.width,
            options.height,
            html,
            .{
                .frameless = options.frameless,
                .transparent = options.transparent,
                .resizable = options.resizable,
                .always_on_top = options.always_on_top,
                .fullscreen = options.fullscreen,
                .x = options.x,
                .y = options.y,
                .dark_mode = options.dark_mode,
                .enable_hot_reload = options.hot_reload,
                .hide_dock_icon = options.hide_dock_icon,
                .titlebar_hidden = options.titlebar_hidden,
                .system_tray = options.system_tray,
                .dev_tools = effective_dev_tools,
                .benchmark = options.benchmark,
                .headless = options.headless,
                .frame_autosave = options.frame_autosave,
                .web_sidebar_material = options.web_sidebar_material,
                .web_sidebar_width = options.web_sidebar_width,
                .web_sidebar_material_opacity = options.web_sidebar_material_opacity,
            },
        );
    } else {
        // Show default demo app
        if (!options.benchmark and !options.quiet) {
            std.debug.print("\n⚡ Launching Craft demo app\n", .{});
            std.debug.print("   Run with --help to see available options\n\n", .{});
        }

        const demo_html =
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\    <meta charset="UTF-8">
            \\    <title>Craft Demo</title>
            \\    <style>
            \\        * {
            \\            margin: 0;
            \\            padding: 0;
            \\            box-sizing: border-box;
            \\        }
            \\        body {
            \\            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            \\            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            \\            height: 100vh;
            \\            display: flex;
            \\            justify-content: center;
            \\            align-items: center;
            \\            color: white;
            \\        }
            \\        .container {
            \\            text-align: center;
            \\            padding: 3rem;
            \\            background: rgba(255, 255, 255, 0.1);
            \\            border-radius: 20px;
            \\            backdrop-filter: blur(10px);
            \\            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.1);
            \\        }
            \\        h1 {
            \\            font-size: 4rem;
            \\            margin-bottom: 1rem;
            \\            text-shadow: 2px 2px 4px rgba(0, 0, 0, 0.3);
            \\        }
            \\        p {
            \\            font-size: 1.5rem;
            \\            opacity: 0.9;
            \\        }
            \\        .emoji {
            \\            font-size: 6rem;
            \\            margin-bottom: 1rem;
            \\            animation: bounce 2s infinite;
            \\        }
            \\        @keyframes bounce {
            \\            0%, 100% { transform: translateY(0); }
            \\            50% { transform: translateY(-20px); }
            \\        }
            \\        code {
            \\            background: rgba(0, 0, 0, 0.3);
            \\            padding: 0.2rem 0.5rem;
            \\            border-radius: 4px;
            \\            font-family: monospace;
            \\        }
            \\    </style>
            \\</head>
            \\<body>
            \\    <div class="container">
            \\        <div class="emoji">⚡</div>
            \\        <h1>Craft</h1>
            \\        <p>Desktop apps with web languages</p>
            \\        <p style="margin-top: 2rem; font-size: 1rem; opacity: 0.7;">
            \\            Try: <code>craft --help</code>
            \\        </p>
            \\    </div>
            \\</body>
            \\</html>
        ;

        _ = try app.createWindow("Craft - Demo", 600, 400, demo_html);
    }

    // Benchmark mode: window created, print "ready" and exit immediately
    if (options.benchmark) {
        // Write "ready" to stdout to signal the parent process
        const msg = "ready\n";
        if (builtin.os.tag == .windows) {
            const k32 = struct {
                extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.c) ?*anyopaque;
                extern "kernel32" fn WriteFile(hFile: *anyopaque, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: ?*anyopaque) callconv(.c) c_int;
            };
            const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
            if (k32.GetStdHandle(STD_OUTPUT_HANDLE)) |handle| {
                _ = k32.WriteFile(handle, msg, msg.len, null, null);
            }
        } else {
            const write_fn = struct {
                extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
            };
            _ = write_fn.write(1, msg, msg.len);
        }
        std.process.exit(0);
    }

    // Create system tray if requested
    if (options.system_tray) {
        const sys_tray = try app.createSystemTray(options.title);

        // Set tooltip with additional info
        const tooltip = try std.fmt.allocPrint(
            allocator,
            "{s} - Craft Application",
            .{options.title},
        );
        defer allocator.free(tooltip);
        try sys_tray.setTooltip(tooltip);

        std.debug.print("   System Tray: Created successfully\n", .{});
    }

    // Apply the custom dock icon LAST — after the window is created (which
    // is where `setActivationPolicy:` lands for the various window paths).
    // `setApplicationIconImage:` only sticks once the app has a regular
    // activation policy; setting it earlier silently no-ops, leaving the
    // generic "exec" placeholder in the dock.
    if (builtin.os.tag == .macos) {
        if (options.icon) |icon_path| {
            craft.macos.setApplicationIcon(icon_path);
        }
    }

    try app.run();
}

/// Run with system tray using a modified App flow
/// Key difference: we create the system tray BEFORE calling initPlatform
fn runWithSystemTray(allocator: std.mem.Allocator, options: cli.WindowOptions) !void {
    std.debug.print("\n⚡ Creating system tray application\n", .{});
    std.debug.print("   Title: {s}\n", .{options.title});

    if (options.menubar_only) {
        std.debug.print("   Mode: Menubar-only (no window)\n", .{});
    } else if (options.url) |url| {
        std.debug.print("   URL: {s}\n", .{url});
        std.debug.print("   Size: {d}x{d}\n", .{ options.width, options.height });
    }

    if (options.hide_dock_icon) {
        std.debug.print("   Style: Menubar-only (no Dock icon)\n", .{});
    }
    std.debug.print("\n", .{});

    var app = craft.App.init(allocator);
    defer app.deinit();

    // Initialize platform for TRAY apps - uses Accessory policy AND calls finishLaunching
    // This MUST happen BEFORE creating the status bar item (proven by working test)
    app.initPlatformForTray();

    if (builtin.os.tag == .macos) {
        if (options.icon) |icon_path| {
            craft.macos.setApplicationIcon(icon_path);
        }
    }

    // Create system tray AFTER finishLaunching (this is the key!)
    const sys_tray = try app.createSystemTray(options.title);

    // Create window AFTER system tray (UNLESS menubar-only mode is enabled)
    if (!options.menubar_only) {
        if (options.url) |url| {
            _ = try app.createWindowWithURL(
                options.title,
                options.width,
                options.height,
                url,
                .{
                    .frameless = options.frameless,
                    .transparent = options.transparent,
                    .always_on_top = options.always_on_top,
                    .resizable = options.resizable,
                    .fullscreen = options.fullscreen,
                    .x = options.x,
                    .y = options.y,
                    .dark_mode = options.dark_mode,
                    .enable_hot_reload = options.hot_reload,
                    .hide_dock_icon = options.hide_dock_icon,
                    .titlebar_hidden = options.titlebar_hidden,
                    .system_tray = options.system_tray,
                    .dev_tools = options.dev_tools,
                    .frame_autosave = options.frame_autosave,
                    .headless = options.headless,
                },
            );
        } else if (options.html) |html| {
            _ = try app.createWindowWithHTML(
                options.title,
                options.width,
                options.height,
                html,
                .{
                    .frameless = options.frameless,
                    .transparent = options.transparent,
                    .resizable = options.resizable,
                    .always_on_top = options.always_on_top,
                    .fullscreen = options.fullscreen,
                    .x = options.x,
                    .y = options.y,
                    .dark_mode = options.dark_mode,
                    .enable_hot_reload = options.hot_reload,
                    .hide_dock_icon = options.hide_dock_icon,
                    .titlebar_hidden = options.titlebar_hidden,
                    .system_tray = options.system_tray,
                    .dev_tools = options.dev_tools,
                    .frame_autosave = options.frame_autosave,
                    .headless = options.headless,
                },
            );
        }
    }

    // Set tooltip with additional info
    const tooltip = try std.fmt.allocPrint(
        allocator,
        "{s} - Craft Application",
        .{options.title},
    );
    defer allocator.free(tooltip);
    try sys_tray.setTooltip(tooltip);

    std.debug.print("✅ System tray icon created\n", .{});
    std.debug.print("   Look for \"{s}\" in your menubar\n\n", .{options.title});

    // Show windows AFTER system tray is created but BEFORE running the event loop
    // Using orderFront (in showWindows) prevents app activation which would hide the tray
    // IMPORTANT: We must show windows even in menubar-only mode to trigger WebView loading
    // Without this, the WebView won't load its HTML/JavaScript content
    // The tray path shows its windows itself, after the status item exists.
    if (!options.headless) app.showWindows();

    // Benchmark mode measures time-to-ready and exits. The windowed paths
    // already honour it; the tray path did not, so `--benchmark` on a menubar
    // app ran the event loop forever — which is exactly the shape of a CI
    // smoke test, and it hung instead of reporting.
    if (options.benchmark) {
        std.debug.print("ready\n", .{});
        return;
    }

    try app.run();
}

/// Run a script on craft's own JavaScript runtime and print its result.
///
/// Exits non-zero on a script error so a shell or CI step notices — a script
/// that threw and a script that printed nothing must not look the same.
fn runEval(allocator: std.mem.Allocator, options: cli.WindowOptions) !void {
    const js_runtime = craft.js_runtime;

    if (!js_runtime.available) {
        std.debug.print("{s}\n", .{js_runtime.unavailable_message});
        std.process.exit(1);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = if (options.eval_source) |src| src else blk: {
        const path = options.eval_file.?;
        // Craft's own reader, so `--eval-file` inherits the same size ceiling
        // and IO conventions as `--html-file` rather than inventing a second.
        break :blk cli.readFileAlloc(arena.allocator(), path) catch {
            std.debug.print("could not read {s}\n", .{path});
            std.process.exit(1);
        };
    };

    const result = js_runtime.evalOnce(allocator, arena.allocator(), source) catch |err| {
        // Named distinctly: a syntax error and a thrown error are different
        // problems, and "it failed" sends the reader to the wrong place.
        const what = switch (err) {
            error.Parse => "syntax error",
            error.Throw => "uncaught error",
            error.Unavailable => js_runtime.unavailable_message,
            error.OutOfMemory => "out of memory",
        };
        std.debug.print("{s}\n", .{what});
        std.process.exit(1);
    };

    std.debug.print("{s}\n", .{result});
}
