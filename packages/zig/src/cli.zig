const std = @import("std");
const builtin = @import("builtin");

pub const WindowOptions = struct {
    url: ?[]const u8 = null,
    html: ?[]const u8 = null,
    title: []const u8 = "Craft App",
    width: u32 = 1200,
    height: u32 = 800,
    x: ?i32 = null,
    y: ?i32 = null,
    frameless: bool = false,
    transparent: bool = false,
    always_on_top: bool = false,
    resizable: bool = true,
    fullscreen: bool = false,
    dev_tools: bool = false,
    dark_mode: ?bool = null,
    hot_reload: bool = false,
    system_tray: bool = false,
    hide_dock_icon: bool = false,
    menubar_only: bool = false,
    titlebar_hidden: bool = false,
    native_sidebar: bool = false,
    sidebar_width: u32 = 220,
    web_sidebar_material: bool = false,
    web_sidebar_width: u32 = 286,
    web_sidebar_material_opacity: f64 = 0.78,
    sidebar_config: ?[]const u8 = null,
    quiet: bool = false,
    benchmark: bool = false,
    // Print where startup time went. Unlike --benchmark, which exits at window
    // creation, this keeps running and reports the phases a real launch pays.
    timing: bool = false,
    // Evaluate JavaScript on craft's own runtime and exit — no window, no
    // WebKit. The source itself, or a path to read it from.
    eval_source: ?[]const u8 = null,
    eval_file: ?[]const u8 = null,
    // Path to a PNG/JPG/ICNS file used as the dock icon for the running
    // process. NSImage decodes everything Cocoa can render, so any common
    // raster format works; .icns is preferred for crispness across sizes.
    icon: ?[]const u8 = null,
    // Build the window and never put it on screen. The page still loads, still
    // runs JavaScript, and can still be captured — what it loses is anything
    // that advances itself; see `--help`.
    headless: bool = false,
    // The name AppKit shows for the app: the App menu title and the
    // "About X" / "Hide X" / "Quit X" items. Without it those read
    // `NSProcessInfo.processName`, which for a bare binary is the executable
    // — so every app launched through the shared `craft` binary called itself
    // "craft". macOS only.
    app_name: ?[]const u8 = null,
    // Write craft's own log to this file, in addition to stderr. Null leaves
    // logging where it has always been: stderr only.
    log_file: ?[]const u8 = null,
    // Emit each record as a JSON object rather than a human-readable line.
    log_json: bool = false,
    // Lowest level that gets recorded: debug, info, warn, error, fatal.
    log_level: ?[]const u8 = null,
    // Send records only to the log file, leaving the terminal quiet.
    log_quiet: bool = false,
    // Keep the process alive after the last window closes, instead of quitting.
    // Null means craft decides from the shape of the app: a tray or
    // menubar-only app stays, an ordinary windowed app goes. See
    // `lifecycle_policy.zig`.
    keep_running: ?bool = null,
    // Name AppKit remembers this window's size and position under, so the app
    // opens where the user last left it. Null means it forgets every launch.
    frame_autosave: ?[]const u8 = null,
};

pub const CliError = error{
    InvalidArgument,
    MissingValue,
    InvalidNumber,
};

/// Enable debug logging via --debug flag
var debug_mode: bool = false;

/// Debug print helper - only prints when debug mode is enabled
fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (debug_mode) {
        std.debug.print(fmt, args);
    }
}

/// Release every string inside `options` that was allocated by `parseArgs`.
/// `title` defaults to a string literal, so only free it if it was replaced.
pub fn freeOptionStrings(allocator: std.mem.Allocator, options: *WindowOptions) void {
    if (options.url) |s| allocator.free(s);
    if (options.html) |s| allocator.free(s);
    if (!std.mem.eql(u8, options.title, "Craft App")) allocator.free(options.title);
    if (options.sidebar_config) |s| allocator.free(s);
    if (options.icon) |s| allocator.free(s);
    if (options.app_name) |s| allocator.free(s);
    if (options.frame_autosave) |s| allocator.free(s);
    if (options.log_file) |s| allocator.free(s);
    if (options.log_level) |s| allocator.free(s);
    if (options.eval_source) |s| allocator.free(s);
    if (options.eval_file) |s| allocator.free(s);
    options.* = WindowOptions{};
}

/// Largest document `--html-file` will load. Generous for a bundled app shell
/// while still refusing to read an arbitrarily large file into memory because
/// a path was mistyped.
const max_html_file_bytes: usize = 32 * 1024 * 1024;

fn readHtmlFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // A local Io rather than the global one: `cli.zig` is compiled into both
    // the `craft` module and the `root` module, so it cannot import anything
    // that belongs to only one of them. Argument parsing also runs before the
    // global Io is installed.
    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > max_html_file_bytes) return error.FileTooBig;

    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);

    var read: usize = 0;
    while (read < buf.len) {
        const n = file.readStreaming(io, &.{buf[read..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        read += n;
    }
    if (read < buf.len) return error.UnexpectedEndOfFile;
    return buf;
}

/// Read a whole file, subject to the same size ceiling as `--html-file`.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return readHtmlFile(allocator, path);
}

// =============================================================================
// Bundle configuration
// =============================================================================

/// `Contents/Resources/craft.json` — the manifest a packaged app describes
/// itself with.
///
/// A packaged app has nowhere to put command-line arguments: `LaunchServices`
/// starts `CFBundleExecutable` with none. The workaround has been to make the
/// bundle's executable a shell script that re-execs the real binary with flags,
/// but that costs a process, breaks on any path with a space, and — decisively
/// — is not something the Mac App Store accepts, because `CFBundleExecutable`
/// has to be a Mach-O image.
///
/// With this, craft *is* the executable. It reads the manifest sitting beside
/// it and configures itself, so the bundle contains exactly one program.
const BundleConfig = struct {
    /// Document to load, relative to `Resources/` (or absolute).
    html: ?[]const u8 = null,
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    appName: ?[]const u8 = null,
    frameAutosave: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    icon: ?[]const u8 = null,
    frameless: ?bool = null,
    transparent: ?bool = null,
    alwaysOnTop: ?bool = null,
    resizable: ?bool = null,
    fullscreen: ?bool = null,
    devTools: ?bool = null,
    darkMode: ?bool = null,
    systemTray: ?bool = null,
    hideDockIcon: ?bool = null,
    menubarOnly: ?bool = null,
    titlebarHidden: ?bool = null,
    headless: ?bool = null,
    keepRunning: ?bool = null,
    logFile: ?[]const u8 = null,
    logJson: ?bool = null,
    logLevel: ?[]const u8 = null,
};

/// Absolute path of the running executable's directory.
///
/// `std` has no self-exe helper in this Zig version, so this goes straight to
/// the platform call. macOS-only for now: it is the only platform with a bundle
/// layout to resolve against.
fn selfExeDir(allocator: std.mem.Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;

    var size: u32 = 0;
    _ = _NSGetExecutablePath(undefined, &size); // returns -1, sets required size
    if (size == 0 or size > 8192) return null;

    const buf = allocator.alloc(u8, size) catch return null;
    defer allocator.free(buf);
    if (_NSGetExecutablePath(buf.ptr, &size) != 0) return null;

    const exe_path = std.mem.sliceTo(buf, 0);
    const dir = std.fs.path.dirname(exe_path) orelse return null;
    return allocator.dupe(u8, dir) catch null;
}

extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

/// Load `../Resources/craft.json` relative to the executable, if it is there.
///
/// Returns options with only the manifest's fields set; `parseArgs` layers the
/// command line on top, so an argument always wins over the manifest.
fn loadBundleConfig(allocator: std.mem.Allocator) ?WindowOptions {
    if (comptime builtin.os.tag != .macos) return null;

    const exe_dir = selfExeDir(allocator) orelse return null;
    defer allocator.free(exe_dir);

    const resources = std.fs.path.join(allocator, &.{ exe_dir, "..", "Resources" }) catch return null;
    defer allocator.free(resources);

    const config_path = std.fs.path.join(allocator, &.{ resources, "craft.json" }) catch return null;
    defer allocator.free(config_path);

    const source = readFileAlloc(allocator, config_path) catch return null;
    defer allocator.free(source);

    const parsed = std.json.parseFromSlice(BundleConfig, allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        // A manifest that is present but malformed is a packaging mistake, and
        // silently opening a default window would hide it.
        std.debug.print("craft: ignoring malformed {s}: {t}\n", .{ config_path, err });
        return null;
    };
    defer parsed.deinit();
    const cfg = parsed.value;

    var options = WindowOptions{};

    if (cfg.html) |rel| {
        const doc_path = if (std.fs.path.isAbsolute(rel))
            allocator.dupe(u8, rel) catch return null
        else
            std.fs.path.join(allocator, &.{ resources, rel }) catch return null;
        defer allocator.free(doc_path);

        options.html = readFileAlloc(allocator, doc_path) catch |err| blk: {
            std.debug.print("craft: could not read {s}: {t}\n", .{ doc_path, err });
            break :blk null;
        };
    }
    if (cfg.url) |v| options.url = allocator.dupe(u8, v) catch null;
    if (cfg.title) |v| options.title = allocator.dupe(u8, v) catch options.title;
    if (cfg.appName) |v| options.app_name = allocator.dupe(u8, v) catch null;
    if (cfg.frameAutosave) |v| options.frame_autosave = allocator.dupe(u8, v) catch null;
    if (cfg.logFile) |v| options.log_file = allocator.dupe(u8, v) catch null;
    if (cfg.logLevel) |v| options.log_level = allocator.dupe(u8, v) catch null;
    if (cfg.icon) |v| options.icon = allocator.dupe(u8, v) catch null;
    applyScalarConfig(cfg, &options);

    return options;
}

/// Copy the manifest's non-allocating fields onto `options`.
///
/// Split out from `loadBundleConfig` so the mapping — including the way
/// `menubarOnly` implies the tray and a hidden dock icon — is testable without
/// a bundle on disk.
fn applyScalarConfig(cfg: BundleConfig, options: *WindowOptions) void {
    if (cfg.width) |v| options.width = v;
    if (cfg.height) |v| options.height = v;
    if (cfg.frameless) |v| options.frameless = v;
    if (cfg.transparent) |v| options.transparent = v;
    if (cfg.alwaysOnTop) |v| options.always_on_top = v;
    if (cfg.resizable) |v| options.resizable = v;
    if (cfg.fullscreen) |v| options.fullscreen = v;
    if (cfg.devTools) |v| options.dev_tools = v;
    if (cfg.darkMode) |v| options.dark_mode = v;
    if (cfg.systemTray) |v| options.system_tray = v;
    if (cfg.hideDockIcon) |v| options.hide_dock_icon = v;
    if (cfg.titlebarHidden) |v| options.titlebar_hidden = v;
    if (cfg.headless) |v| options.headless = v;
    if (cfg.keepRunning) |v| options.keep_running = v;
    if (cfg.logJson) |v| options.log_json = v;
    // A menubar app with a dock icon and no tray is not a menubar app, so the
    // one flag sets all three rather than making every manifest repeat them.
    if (cfg.menubarOnly) |v| {
        if (v) {
            options.menubar_only = true;
            options.system_tray = true;
            options.hide_dock_icon = true;
        }
    }
}

test "applyScalarConfig leaves untouched fields at their defaults" {
    var options = WindowOptions{};
    applyScalarConfig(.{ .width = 400 }, &options);
    try std.testing.expectEqual(@as(u32, 400), options.width);
    try std.testing.expectEqual(@as(u32, 800), options.height);
    try std.testing.expect(options.resizable);
    try std.testing.expect(!options.system_tray);
}

test "menubarOnly implies the tray and a hidden dock icon" {
    var options = WindowOptions{};
    applyScalarConfig(.{ .menubarOnly = true }, &options);
    try std.testing.expect(options.menubar_only);
    try std.testing.expect(options.system_tray);
    try std.testing.expect(options.hide_dock_icon);
}

test "menubarOnly false does not force the tray off" {
    // `systemTray: true, menubarOnly: false` is a real combination — a tray app
    // that also keeps its dock icon.
    var options = WindowOptions{};
    applyScalarConfig(.{ .menubarOnly = false, .systemTray = true }, &options);
    try std.testing.expect(!options.menubar_only);
    try std.testing.expect(options.system_tray);
    try std.testing.expect(!options.hide_dock_icon);
}

test "a manifest parses into the fields it names and no others" {
    const source =
        \\{"html":"index.html","title":"Hush","width":340,"height":560,"menubarOnly":true}
    ;
    const parsed = try std.json.parseFromSlice(BundleConfig, std.testing.allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("index.html", parsed.value.html.?);
    try std.testing.expectEqual(@as(u32, 340), parsed.value.width.?);
    try std.testing.expect(parsed.value.menubarOnly.?);
    // Absent stays null so `parseArgs` keeps craft's default rather than a zero.
    try std.testing.expect(parsed.value.url == null);
    try std.testing.expect(parsed.value.devTools == null);
}

test "a manifest can name the app without naming the window" {
    // Two different strings: `title` is the window's, `appName` is the one in
    // the menu bar. A packaged app usually gets the latter from CFBundleName,
    // but a manifest may override it.
    const source =
        \\{"title":"Untitled — Hush","appName":"Hush"}
    ;
    const parsed = try std.json.parseFromSlice(BundleConfig, std.testing.allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Untitled — Hush", parsed.value.title.?);
    try std.testing.expectEqualStrings("Hush", parsed.value.appName.?);
}

test "a manifest can ask for its window frame to be remembered" {
    const source =
        \\{"title":"Hush","frameAutosave":"main"}
    ;
    const parsed = try std.json.parseFromSlice(BundleConfig, std.testing.allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("main", parsed.value.frameAutosave.?);
}

test "a manifest can ask to run headless" {
    const source =
        \\{"title":"Probe","headless":true}
    ;
    const parsed = try std.json.parseFromSlice(BundleConfig, std.testing.allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.headless.?);

    var options = WindowOptions{};
    applyScalarConfig(parsed.value, &options);
    try std.testing.expect(options.headless);
}

test "unknown manifest keys are ignored rather than failing the launch" {
    const source =
        \\{"title":"Hush","somethingNewer":true}
    ;
    const parsed = try std.json.parseFromSlice(BundleConfig, std.testing.allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Hush", parsed.value.title.?);
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !WindowOptions {
    // First pass: check for --debug flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) {
            debug_mode = true;
            break;
        }
    }

    debugPrint("\n[CLI DEBUG] Total arguments received: {d}\n", .{args.len});
    for (args, 0..) |arg, idx| {
        debugPrint("[CLI DEBUG] arg[{d}] = '{s}'\n", .{ idx, arg });
    }
    debugPrint("\n", .{});

    // The bundle manifest is the base; every argument below layers on top, so
    // a command line always wins over what the packaged app declares.
    var options = loadBundleConfig(allocator) orelse WindowOptions{};
    // If we return an error partway through parsing, free any strings we've
    // already duped. Previously these allocations leaked on the error path
    // (e.g. `--width abc` triggers InvalidNumber with a duped `--title` value
    // still held by `options`).
    errdefer freeOptionStrings(allocator, &options);

    var i: usize = 1; // Skip program name

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            printVersion();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.url = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--html")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.html = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--html-file")) {
            // Packaged apps ship their document as a file inside the bundle.
            // Passing it through `--html` means the whole document travels as
            // a single argv entry: it has to survive the launcher's shell
            // quoting intact, and anything past ARG_MAX fails outright. Read
            // it here instead.
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.html = readHtmlFile(allocator, args[i]) catch |err| {
                std.debug.print("Error: could not read --html-file '{s}': {t}\n", .{ args[i], err });
                return CliError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.title = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "-w")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.width = std.fmt.parseInt(u32, args[i], 10) catch return CliError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--height")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.height = std.fmt.parseInt(u32, args[i], 10) catch return CliError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--x") or std.mem.eql(u8, arg, "-x")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.x = std.fmt.parseInt(i32, args[i], 10) catch return CliError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--y") or std.mem.eql(u8, arg, "-y")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.y = std.fmt.parseInt(i32, args[i], 10) catch return CliError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--frameless")) {
            options.frameless = true;
        } else if (std.mem.eql(u8, arg, "--transparent")) {
            options.transparent = true;
        } else if (std.mem.eql(u8, arg, "--always-on-top")) {
            options.always_on_top = true;
        } else if (std.mem.eql(u8, arg, "--fullscreen") or std.mem.eql(u8, arg, "-f")) {
            options.fullscreen = true;
        } else if (std.mem.eql(u8, arg, "--no-resize")) {
            options.resizable = false;
        } else if (std.mem.eql(u8, arg, "--titlebar-hidden")) {
            debugPrint("[CLI DEBUG] Found --titlebar-hidden flag, setting to true\n", .{});
            options.titlebar_hidden = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            // Already handled in first pass
        } else if (std.mem.eql(u8, arg, "--dev-tools") or std.mem.eql(u8, arg, "--devtools")) {
            // Until this existed there was no way to turn DevTools *on*: the
            // field defaults to false here, `--no-devtools` only sets it false
            // again, and the only other writer was the bundle manifest. So the
            // inspector was unreachable from the command line and from the SDK,
            // which pushes `--no-devtools` when it wants them off and nothing
            // when it wants them on.
            options.dev_tools = true;
        } else if (std.mem.eql(u8, arg, "--no-devtools")) {
            options.dev_tools = false;
        } else if (std.mem.eql(u8, arg, "--dark")) {
            options.dark_mode = true;
        } else if (std.mem.eql(u8, arg, "--light")) {
            options.dark_mode = false;
        } else if (std.mem.eql(u8, arg, "--hot-reload")) {
            options.hot_reload = true;
        } else if (std.mem.eql(u8, arg, "--system-tray")) {
            options.system_tray = true;
        } else if (std.mem.eql(u8, arg, "--hide-dock-icon")) {
            options.hide_dock_icon = true;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.log_file = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--log-json")) {
            options.log_json = true;
        } else if (std.mem.eql(u8, arg, "--log-quiet")) {
            options.log_quiet = true;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.log_level = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--keep-running")) {
            options.keep_running = true;
        } else if (std.mem.eql(u8, arg, "--quit-on-close")) {
            // The other direction, for a tray app that does want to go away
            // with its window. Without it, `--keep-running` would be a flag
            // whose default cannot be restored from the command line.
            options.keep_running = false;
        } else if (std.mem.eql(u8, arg, "--menubar-only")) {
            options.menubar_only = true;
            options.system_tray = true; // Menubar-only implies system tray
            options.hide_dock_icon = true; // And hiding dock icon
        } else if (std.mem.eql(u8, arg, "--native-sidebar")) {
            options.native_sidebar = true;
        } else if (std.mem.eql(u8, arg, "--web-sidebar-material")) {
            options.web_sidebar_material = true;
        } else if (std.mem.eql(u8, arg, "--web-sidebar-width")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.web_sidebar_width = std.fmt.parseInt(u32, args[i], 10) catch return CliError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--web-sidebar-material-opacity")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.web_sidebar_material_opacity = std.fmt.parseFloat(f64, args[i]) catch return CliError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--sidebar-width")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.sidebar_width = std.fmt.parseInt(u32, args[i], 10) catch return CliError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--eval")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.eval_source = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--eval-file")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.eval_file = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--timing")) {
            options.timing = true;
        } else if (std.mem.eql(u8, arg, "--benchmark")) {
            options.benchmark = true;
        } else if (std.mem.eql(u8, arg, "--sidebar-config")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.sidebar_config = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--icon")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.icon = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--app-name")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.app_name = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--frame-autosave")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            options.frame_autosave = try allocator.dupe(u8, args[i]);
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            // Treat as positional URL argument
            if (options.url == null) {
                options.url = try allocator.dupe(u8, arg);
            }
        }
    }

    debugPrint("[CLI DEBUG] Final options: titlebar_hidden={}, frameless={}, transparent={}\n", .{
        options.titlebar_hidden,
        options.frameless,
        options.transparent,
    });

    return options;
}

fn printHelp() void {
    writeStdout(
        \\
        \\⚡ Craft - Build desktop apps with web languages
        \\
        \\Usage: craft [OPTIONS] [URL]
        \\
        \\Window Content:
        \\  -u, --url <URL>          Load URL in the window
        \\      --html <HTML>        Load HTML content directly
        \\      --html-file <PATH>   Load HTML content from a file
        \\
        \\Window Appearance:
        \\  -t, --title <TITLE>      Window title (default: "Craft App")
        \\  -w, --width <WIDTH>      Window width (default: 1200)
        \\      --height <HEIGHT>    Window height (default: 800)
        \\  -x, --x <X>              Window x position (default: centered)
        \\  -y, --y <Y>              Window y position (default: centered)
        \\
        \\Window Style:
        \\      --frameless          Create frameless window
        \\      --transparent        Make window transparent
        \\      --always-on-top      Keep window always on top
        \\  -f, --fullscreen         Start in fullscreen mode
        \\      --no-resize          Disable window resizing
        \\
        \\Theme:
        \\      --dark               Force dark mode
        \\      --light              Force light mode
        \\
        \\Features:
        \\      --hot-reload         Enable hot reload support
        \\      --system-tray        Show system tray icon
        \\      --hide-dock-icon     Hide dock icon (menubar-only mode, macOS)
        \\      --menubar-only       Menubar-only mode (no window, system tray only)
        \\      --log-file <PATH>    Append craft's own log to this file as well as
        \\                           stderr. Captures everything craft logs through
        \\                           std.log; debug-mode std.debug.print tracing is
        \\                           not included.
        \\      --log-json           One JSON object per record instead of a line.
        \\      --log-level <LEVEL>  debug, info, warn, error, fatal or off
        \\                           (default info).
        \\      --log-quiet          Write only to --log-file, leaving stderr alone.
        \\      --keep-running       Stay running after the last window closes.
        \\                           The default for tray and menubar-only apps;
        \\                           an ordinary windowed app quits.
        \\      --quit-on-close      Quit when the last window closes, even for
        \\                           a tray app.
        \\      --dev-tools          Enable WebKit DevTools and make the webview
        \\                           inspectable from Safari's Develop menu
        \\      --no-devtools        Disable WebKit DevTools
        \\      --titlebar-hidden    Hide window titlebar
        \\      --native-sidebar     Use native macOS sidebar (Finder-style)
        \\      --web-sidebar-material
        \\                          Draw native macOS sidebar material behind web UI
        \\      --web-sidebar-width <W>
        \\                          Web sidebar material width in pixels (default: 286)
        \\      --web-sidebar-material-opacity <N>
        \\                          White/dark tint over web sidebar material, 0..1 (default: 0.78)
        \\      --sidebar-config <J> Sidebar JSON configuration
        \\      --sidebar-width <W>  Sidebar width in pixels (default: 220)
        \\      --icon <PATH>        Path to dock icon image (PNG/JPG/ICNS)
        \\      --headless           Build the window without showing it (macOS).
        \\                           The page loads and runs JavaScript as normal.
        \\                           It does NOT animate: an unshown window does
        \\                           not drive the compositor, so requestAnimation-
        \\                           Frame stops after one frame and page timers
        \\                           fall to roughly 1Hz. Drive the page with
        \\                           explicit calls; do not wait for it to settle.
        \\      --app-name <NAME>    Name in the menu bar and in About/Hide/Quit
        \\                           (macOS; defaults to the executable name)
        \\      --frame-autosave <NAME>
        \\                           Remember window size and position across
        \\                           launches under NAME (macOS). --width/--height/
        \\                           --x/--y become first-launch defaults.
        \\
        \\Debugging:
        \\      --debug              Enable debug output
        \\      --benchmark          Benchmark mode: create window, print "ready", exit
        \\
        \\Information:
        \\      --eval <SOURCE>      Run JavaScript on craft's own runtime and exit (no window)
        \\      --eval-file <FILE>   Same, reading the script from a file
        \\      --timing             Print startup phase timings (process, window, webview, load)
        \\  -h, --help               Show this help message
        \\  -v, --version            Show version information
        \\
        \\Examples:
        \\  craft http://localhost:3000
        \\  craft --url http://example.com --width 800 --height 600
        \\  craft --url http://localhost:3000 --title "My App" --frameless
        \\  craft --html "<h1>Hello, World!</h1>" --width 400 --height 300
        \\  craft --html-file ./dist/index.html --menubar-only
        \\  craft http://localhost:3000 --x 100 --y 100 --fullscreen
        \\  craft http://localhost:3000 --transparent --always-on-top
        \\  craft http://localhost:3000 --dark --hot-reload
        \\  craft http://localhost:3000 --system-tray --light
        \\  craft http://localhost:3000 --native-sidebar --sidebar-width 250
        \\  craft http://localhost:3000 --app-name "My App"
        \\  craft http://localhost:3000 --frame-autosave main
        \\
        \\For more information, visit: https://github.com/home-lang/craft
        \\
        \\
    , .{});
}

fn printVersion() void {
    const target = @import("builtin").target;
    const platform_name = switch (target.os.tag) {
        .macos => "macOS",
        .linux => "Linux",
        .windows => "Windows",
        else => "Unknown",
    };

    const build_opts = @import("build_options");
    const version = if (@hasDecl(build_opts, "version")) build_opts.version else "0.0.0";
    var buffer: [128]u8 = undefined;
    const output = formatVersion(&buffer, version, platform_name) catch {
        std.debug.print("craft: could not format version output\n", .{});
        return;
    };
    writeStdout("{s}", .{output});
}

fn writeStdout(comptime format: []const u8, args: anytype) void {
    var buffer: [8192]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, format, args) catch {
        std.debug.print("craft: output exceeded the CLI buffer\n", .{});
        return;
    };

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .environ = .empty });
    defer threaded.deinit();
    std.Io.File.stdout().writeStreamingAll(threaded.io(), output) catch |err| {
        std.debug.print("craft: stdout write failed: {}\n", .{err});
    };
}

pub fn formatVersion(buffer: []u8, version: []const u8, platform_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "craft version {s}\nBuilt with Zig 0.17.0-dev\nPlatform: {s}\n\n",
        .{ version, platform_name },
    );
}

test "a manifest can ask the app to outlive its window" {
    const source =
        \\{"title":"Tray thing","keepRunning":true}
    ;
    const parsed = try std.json.parseFromSlice(BundleConfig, std.testing.allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var options = WindowOptions{};
    // Null before, so the shape decides. That distinction is the whole point
    // of the optional: `false` is "quit", not "nobody said".
    try std.testing.expectEqual(@as(?bool, null), options.keep_running);
    applyScalarConfig(parsed.value, &options);
    try std.testing.expectEqual(@as(?bool, true), options.keep_running);
}

test "a manifest that says nothing about it leaves the decision to the shape" {
    const source =
        \\{"title":"Plain"}
    ;
    const parsed = try std.json.parseFromSlice(BundleConfig, std.testing.allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var options = WindowOptions{};
    applyScalarConfig(parsed.value, &options);
    try std.testing.expectEqual(@as(?bool, null), options.keep_running);
}

test "--keep-running and --quit-on-close both say so explicitly" {
    {
        var args = [_][:0]const u8{ "craft", "--keep-running" };
        const options = try parseArgs(std.testing.allocator, &args);
        try std.testing.expectEqual(@as(?bool, true), options.keep_running);
    }
    {
        var args = [_][:0]const u8{ "craft", "--quit-on-close" };
        const options = try parseArgs(std.testing.allocator, &args);
        // Not null: a tray app passing this has said something, and the shape
        // must not overrule it.
        try std.testing.expectEqual(@as(?bool, false), options.keep_running);
    }
    {
        var args = [_][:0]const u8{"craft"};
        const options = try parseArgs(std.testing.allocator, &args);
        try std.testing.expectEqual(@as(?bool, null), options.keep_running);
    }
}

test "the last of the two flags wins" {
    var args = [_][:0]const u8{ "craft", "--keep-running", "--quit-on-close" };
    const options = try parseArgs(std.testing.allocator, &args);
    try std.testing.expectEqual(@as(?bool, false), options.keep_running);
}

test "the logging flags are parsed" {
    var args = [_][:0]const u8{ "craft", "--log-file", "/tmp/craft.log", "--log-json", "--log-level", "debug", "--log-quiet" };
    const options = try parseArgs(std.testing.allocator, &args);
    defer {
        var o = options;
        freeOptionStrings(std.testing.allocator, &o);
    }
    try std.testing.expectEqualStrings("/tmp/craft.log", options.log_file.?);
    try std.testing.expect(options.log_json);
    try std.testing.expectEqualStrings("debug", options.log_level.?);
    try std.testing.expect(options.log_quiet);
}

test "logging is off unless asked for" {
    var args = [_][:0]const u8{"craft"};
    const options = try parseArgs(std.testing.allocator, &args);
    try std.testing.expectEqual(@as(?[]const u8, null), options.log_file);
    try std.testing.expectEqual(@as(?[]const u8, null), options.log_level);
    try std.testing.expect(!options.log_json);
    try std.testing.expect(!options.log_quiet);
}

test "--log-file without a value is an error, not a silent default" {
    var args = [_][:0]const u8{ "craft", "--log-file" };
    try std.testing.expectError(CliError.MissingValue, parseArgs(std.testing.allocator, &args));
}

test "a manifest can ask for a log file" {
    const source =
        \\{"title":"Probe","logFile":"/var/log/app.log","logLevel":"warn","logJson":true}
    ;
    const parsed = try std.json.parseFromSlice(BundleConfig, std.testing.allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    // The path and level are applied inside `loadBundleConfig`, which reads the
    // filesystem; what is checkable here is that the manifest keys decode and
    // that the scalar reaches the options.
    try std.testing.expectEqualStrings("/var/log/app.log", parsed.value.logFile.?);
    try std.testing.expectEqualStrings("warn", parsed.value.logLevel.?);

    var options = WindowOptions{};
    applyScalarConfig(parsed.value, &options);
    try std.testing.expect(options.log_json);
}
