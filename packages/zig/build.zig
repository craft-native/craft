const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // macOS SDK path for cross-compilation — use -Dmacos-sdk instead of --sysroot
    // to avoid Zig bug where --sysroot breaks @cImport (ziglang/zig#22704, #25010)
    const macos_sdk = b.option([]const u8, "macos-sdk", "macOS SDK path for cross-compilation");

    // Set when the opt-in JavaScript tests are wired up, so `test` can include
    // them without the declaration being scoped inside the `if`.
    var js_test_run: ?*std.Build.Step.Run = null;

    // Version from -Dversion= flag or default
    const version_option = b.option([]const u8, "version", "Version string (from package.json)") orelse "0.0.0";

    // Create build options module for version
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version_option);

    // Craft's own JavaScript runtime, distinct from the page's: the page runs
    // on WebKit's JSC inside the WebContent process, which craft does not own.
    // This is for everything else — a tray handler, a scheduled task, a script
    // handed to the CLI — which previously had to create a whole WKWebView to
    // run, and in a menubar-only app could not run at all.
    //
    // On by default: zig-js is first-party, so craft's own JavaScript runs on
    // an engine we own rather than on whatever the platform ships.
    //
    // `-Djs-runtime=false` opts out, and is not decoration — it costs 6.5MB of
    // binary (1.15MB to 7.66MB, ReleaseFast), which matters for a menubar
    // utility that never evaluates anything. The null backend then reports its
    // own absence rather than pretending.
    const js_runtime_enabled = b.option(
        bool,
        "js-runtime",
        "Craft's first-party JavaScript runtime on zig-js (default true; false saves ~6.5MB)",
    ) orelse true;

    const js_backend_module = blk: {
        if (js_runtime_enabled) {
            const js_dep = b.dependency("zig_js", .{ .target = target, .optimize = optimize });
            break :blk b.createModule(.{
                .root_source_file = b.path("src/js_backend_zigjs.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "js", .module = js_dep.module("js") }},
            });
        }
        break :blk b.createModule(.{
            .root_source_file = b.path("src/js_backend_null.zig"),
            .target = target,
            .optimize = optimize,
        });
    };

    // Create the craft module (library module — does not own build_options;
    // each executable supplies build_options directly so there is no duplicate)
    const craft_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "js_backend", .module = js_backend_module },
        },
    });
    // Add vendored SQLite include path for any C compilation units.
    craft_module.addIncludePath(b.path("vendor/sqlite"));

    // Demo executable - simple hardcoded example
    const exe = b.addExecutable(.{
        .name = "craft-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });

    // Add system libraries based on platform
    const target_os = target.result.os.tag;
    linkPlatformLibraries(b, exe.root_module, target_os, macos_sdk);

    // Deliberately not installed. `zig-out/bin` is what the release packager
    // zips, whole and unfiltered, so anything installed here ships to users —
    // and the demo was riding along in every archive, unsigned on macOS next
    // to a notarized `craft`, because the signing loop names only `craft`.
    // `zig build run-demo` still builds and runs it; it just does not end up
    // in the install prefix.
    const run_cmd = b.addRunArtifact(exe);

    const run_step = b.step("run-demo", "Run the demo app");
    run_step.dependOn(&run_cmd.step);

    // Main CLI executable - full-featured command-line interface
    const craft_exe = b.addExecutable(.{
        .name = "craft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/minimal.zig"),
            .target = target,
            .optimize = optimize,
            // Single-threaded by default: craft's CLI has no use for threads
            // and it keeps the binary small. zig-js does spawn them, so the
            // constraint is relaxed only for builds that include the JS
            // runtime, rather than giving it up for everyone.
            .single_threaded = !js_runtime_enabled,
            .strip = if (optimize != .debug) true else null,
            // Never `.none` on Windows. The x64 ABI requires unwind data for
            // non-leaf functions, and zig passes this module option down into
            // the mingw-w64 CRT it builds for the target — where crtexe.c's
            // inline `.seh_handler` has no active `.seh_proc` frame to attach
            // to and the cross-compile dies on ".seh_ directive must appear
            // within an active frame". The release workflow cross-compiles
            // x86_64-windows from Linux, so this is the difference between a
            // release happening and not.
            .unwind_tables = if (optimize != .debug and target_os != .windows) .none else null,
            .omit_frame_pointer = if (optimize == .small) true else null,
            .error_tracing = if (optimize != .debug) false else null,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    linkPlatformLibraries(b, craft_exe.root_module, target_os, macos_sdk);
    b.installArtifact(craft_exe);

    const run_craft_cmd = b.addRunArtifact(craft_exe);
    run_craft_cmd.step.dependOn(b.getInstallStep());

    const run_craft_step = b.step("run", "Run the craft CLI");
    run_craft_step.dependOn(&run_craft_cmd.step);

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    // Link platform libraries for tests (needed for ObjC symbols etc.)
    linkPlatformLibraries(b, lib_unit_tests.root_module, target_os, macos_sdk);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Individual test files with proper imports
    // Create module for each source file
    const api_module = b.createModule(.{
        .root_source_file = b.path("src/api.zig"),
    });

    const mobile_module = b.createModule(.{
        .root_source_file = b.path("src/mobile.zig"),
    });

    // Rooted at `src/ios.zig`, which reaches `src/mobile.zig` through its own
    // relative import — so this module owns both files and must not be mixed
    // with `mobile_module` in one compilation.
    const ios_module = b.createModule(.{
        .root_source_file = b.path("src/ios.zig"),
    });

    const menubar_module = b.createModule(.{
        .root_source_file = b.path("src/menubar.zig"),
    });

    const components_module = b.createModule(.{
        .root_source_file = b.path("src/components.zig"),
    });

    const gpu_module = b.createModule(.{
        .root_source_file = b.path("src/gpu.zig"),
    });

    const system_module = b.createModule(.{
        .root_source_file = b.path("src/system.zig"),
    });

    const profiler_module = b.createModule(.{
        .root_source_file = b.path("src/profiler.zig"),
    });

    const memory_module = b.createModule(.{
        .root_source_file = b.path("src/memory.zig"),
    });

    const lifecycle_module = b.createModule(.{
        .root_source_file = b.path("src/lifecycle.zig"),
    });

    const shortcuts_module = b.createModule(.{
        .root_source_file = b.path("src/shortcuts.zig"),
    });

    const hotreload_module = b.createModule(.{
        .root_source_file = b.path("src/hotreload.zig"),
    });

    const async_module = b.createModule(.{
        .root_source_file = b.path("src/async.zig"),
    });

    const events_module = b.createModule(.{
        .root_source_file = b.path("src/events.zig"),
    });

    const bridge_module = b.createModule(.{
        .root_source_file = b.path("src/bridge.zig"),
    });

    const devmode_module = b.createModule(.{
        .root_source_file = b.path("src/devmode.zig"),
    });

    const renderer_module = b.createModule(.{
        .root_source_file = b.path("src/renderer.zig"),
    });

    const log_module = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
    });

    const theme_module = b.createModule(.{
        .root_source_file = b.path("src/theme.zig"),
    });

    const animation_module = b.createModule(.{
        .root_source_file = b.path("src/animation.zig"),
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    const native_sidebar_bootstrap_module = b.createModule(.{
        .root_source_file = b.path("src/native_sidebar_bootstrap.zig"),
    });

    const javascript_module = b.createModule(.{
        .root_source_file = b.path("src/javascript.zig"),
    });

    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
    });

    const ipc_module = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
    });

    // Note: performance_module not currently used by any tests
    _ = b.createModule(.{
        .root_source_file = b.path("src/performance.zig"),
    });

    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
    });

    const tray_module = b.createModule(.{
        .root_source_file = b.path("src/tray.zig"),
    });

    // Note: database_module available for imports that need SQLite access
    _ = b.createModule(.{
        .root_source_file = b.path("src/database.zig"),
    });

    const api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/api_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/api.zig", .module = api_module },
            },
        }),
    });

    const mobile_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/mobile_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/mobile.zig", .module = mobile_module },
            },
        }),
    });

    // The iOS surface gate. Rooted at `src/ios.zig` rather than sharing
    // `mobile_module`, because a file may belong to only one module per
    // compilation and `ios.zig` reaches `mobile.zig` through a relative
    // import of its own. The `mobile.iOS` half of the gate therefore lives in
    // `test/mobile_test.zig`, which already owns that module.
    //
    // This builds for the host, so it costs seconds and runs in `zig build
    // test` — which is the point. Cross-compiling to iOS is the truth, but it
    // is not a loop anyone iterates in locally.
    const ios_surface_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/ios_surface_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/ios.zig", .module = ios_module },
            },
        }),
    });
    // Forcing analysis of every declaration means the linker now sees every
    // `objc_msgSend`/`sel_registerName` reference too, so the ObjC runtime has
    // to be present. No frameworks are needed: nothing here calls UIKit or
    // AppKit, it only resolves classes by name at runtime — which is exactly
    // why `[UIScreen mainScreen]` returns null on the host rather than failing
    // to link.
    if (target.result.os.tag.isDarwin()) {
        ios_surface_tests.root_module.link_libc = true;
        ios_surface_tests.root_module.linkSystemLibrary("objc", .{});
        // `ios_dispatch` replies through `bridge_error`, which reaches
        // `bridge.evalJS`, which on a macOS *host* build resolves to the
        // desktop arm and drags in the AppKit/CoreFoundation surface behind it.
        // That is the price of the gate analysing the real reply path rather
        // than a stub of one, and it is the right trade: the alternative is a
        // test that compiles iOS code which never reaches the code it replies
        // through.
        ios_surface_tests.root_module.linkFramework("Cocoa", .{});
        ios_surface_tests.root_module.linkFramework("WebKit", .{});
        ios_surface_tests.root_module.linkFramework("CoreFoundation", .{});
        ios_surface_tests.root_module.linkFramework("CoreGraphics", .{});
        ios_surface_tests.root_module.linkFramework("CoreMIDI", .{});
        // The storage module is Keychain: SecItemAdd and the kSec* constants
        // live in Security.framework.
        ios_surface_tests.root_module.linkFramework("Security", .{});
        ios_surface_tests.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_JSON1" },
        });
        ios_surface_tests.root_module.addIncludePath(b.path("vendor/sqlite"));
    }

    // Tests are collected from the ROOT module only — a named-module import is
    // a different module, so `test { _ = ios; }` in the surface gate enrolls
    // nothing. This artifact makes src/ios.zig itself the root, which is the
    // only arrangement that runs the tests inside ios_dispatch.zig and the
    // mobile modules. Proven with a canary: a deliberately failing module test
    // stayed green under every other wiring.
    // A fresh module object rather than reusing `ios_module`: an artifact root
    // needs a resolved target, and the one-module-per-file rule only applies
    // within a single compilation — this artifact is its own.
    const ios_module_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ios.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag.isDarwin()) {
        ios_module_tests.root_module.link_libc = true;
        ios_module_tests.root_module.linkSystemLibrary("objc", .{});
        ios_module_tests.root_module.linkFramework("Cocoa", .{});
        ios_module_tests.root_module.linkFramework("WebKit", .{});
        ios_module_tests.root_module.linkFramework("CoreFoundation", .{});
        ios_module_tests.root_module.linkFramework("CoreGraphics", .{});
        ios_module_tests.root_module.linkFramework("CoreMIDI", .{});
        ios_module_tests.root_module.linkFramework("Security", .{});
        ios_module_tests.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_JSON1" },
        });
        ios_module_tests.root_module.addIncludePath(b.path("vendor/sqlite"));
        // Rooting at ios.zig compiles its exports, whose reply path reaches the
        // desktop bridge — including the Carbon hotkey machinery. Same linkage
        // macos_hotkey_tests already carries.
        ios_module_tests.root_module.linkFramework("Carbon", .{});
    }

    // The iOS conformance gate. It embeds the Swift template as the migration
    // spec and `bridge_mobile.zig` as what Zig currently serves, so an action
    // cannot be dropped on the way across without the build saying so.
    const ios_conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/ios_conformance_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ios_conformance_tests.root_module.addAnonymousImport("CraftApp.swift", .{
        .root_source_file = b.path("../ios/templates/CraftApp.swift"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile.zig", .{
        .root_source_file = b.path("src/bridge_mobile.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_clipboard.zig", .{
        .root_source_file = b.path("src/bridge_mobile_clipboard.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_haptics.zig", .{
        .root_source_file = b.path("src/bridge_mobile_haptics.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_device.zig", .{
        .root_source_file = b.path("src/bridge_mobile_device.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_system.zig", .{
        .root_source_file = b.path("src/bridge_mobile_system.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_display.zig", .{
        .root_source_file = b.path("src/bridge_mobile_display.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_storage.zig", .{
        .root_source_file = b.path("src/bridge_mobile_storage.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_misc.zig", .{
        .root_source_file = b.path("src/bridge_mobile_misc.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_shortcuts.zig", .{
        .root_source_file = b.path("src/bridge_mobile_shortcuts.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_securestore.zig", .{
        .root_source_file = b.path("src/bridge_mobile_securestore.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_biometric.zig", .{
        .root_source_file = b.path("src/bridge_mobile_biometric.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_permissions.zig", .{
        .root_source_file = b.path("src/bridge_mobile_permissions.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_db.zig", .{
        .root_source_file = b.path("src/bridge_mobile_db.zig"),
    });
    ios_conformance_tests.root_module.addAnonymousImport("src/bridge_mobile_notifcancel.zig", .{
        .root_source_file = b.path("src/bridge_mobile_notifcancel.zig"),
    });

    const menubar_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/menubar_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/menubar.zig", .module = menubar_module },
            },
        }),
    });

    const components_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/components.zig", .module = components_module },
            },
        }),
    });

    const gpu_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/gpu_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/gpu.zig", .module = gpu_module },
            },
        }),
    });
    // GPU module needs ObjC runtime + Metal framework on macOS
    linkPlatformLibraries(b, gpu_tests.root_module, target_os, macos_sdk);

    const system_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/system_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/system.zig", .module = system_module },
            },
        }),
    });

    // system.zig uses ObjC on macOS (Clipboard, etc.)
    switch (target_os) {
        .macos => {
            system_tests.root_module.linkFramework("Cocoa", .{});
            system_tests.root_module.linkFramework("WebKit", .{});
            applySdkPaths(b, system_tests.root_module, macos_sdk);
        },
        .linux => {
            system_tests.root_module.linkSystemLibrary("gtk+-3.0", .{});
        },
        else => {},
    }
    system_tests.root_module.link_libc = true;

    const profiler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/profiler_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/profiler.zig", .module = profiler_module },
            },
        }),
    });
    profiler_tests.root_module.link_libc = true;

    const memory_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/memory_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/memory.zig", .module = memory_module },
            },
        }),
    });

    const lifecycle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/lifecycle_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/lifecycle.zig", .module = lifecycle_module },
            },
        }),
    });

    const shortcuts_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/shortcuts_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/shortcuts.zig", .module = shortcuts_module },
            },
        }),
    });

    const hotreload_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/hotreload_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/hotreload.zig", .module = hotreload_module },
            },
        }),
    });
    hotreload_tests.root_module.link_libc = true;

    const async_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/async_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/async.zig", .module = async_module },
            },
        }),
    });

    const events_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/events_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/events.zig", .module = events_module },
            },
        }),
    });

    const bridge_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bridge_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/bridge.zig", .module = bridge_module },
            },
        }),
    });

    const devmode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/devmode_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/devmode.zig", .module = devmode_module },
            },
        }),
    });
    devmode_tests.root_module.link_libc = true;

    const renderer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/renderer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/renderer.zig", .module = renderer_module },
            },
        }),
    });

    const log_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/log_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/log.zig", .module = log_module },
            },
        }),
    });
    log_tests.root_module.link_libc = true;

    const theme_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/theme_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/theme.zig", .module = theme_module },
            },
        }),
    });

    const animation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/animation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/animation.zig", .module = animation_module },
            },
        }),
    });

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/cli_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/cli.zig", .module = cli_module },
            },
        }),
    });

    const native_sidebar_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/native_sidebar_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/cli.zig", .module = cli_module },
                .{ .name = "javascript", .module = javascript_module },
                .{ .name = "native_sidebar_bootstrap", .module = native_sidebar_bootstrap_module },
            },
        }),
    });

    // The space list is the AppKit-free half of the spaces switcher, so its
    // tests are the ones that can run anywhere. They root at the source file
    // itself: nothing else in the build reaches it, and Zig's lazy analysis
    // means tests in an unreferenced file are silently never compiled.
    const space_list_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/components/space_list.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The host-matching and opt-in rules behind the local development TLS
    // exception. Security-relevant and AppKit-free, so they are tested here
    // rather than only exercised through a window.
    const local_tls_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/local_tls.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The role -> AppKit selector table, shared by the bridge and by the
    // default menu bar. Pure data and pure lookups, so it is tested here
    // instead of by launching an app and reading the menus.
    const menu_roles_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/menu_roles.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Accelerator strings ("Cmd+Shift+H") and the Carbon hotkey binding they
    // are registered through. Both are pure enough to test without a window.
    const accelerator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/accelerator.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const macos_hotkey_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/macos_hotkey.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target_os == .macos) {
        // These tests put a real `EventRef` through Carbon's own dispatcher —
        // the only way to find out whether the handler signature and the
        // `EventHotKeyID` layout are what Carbon expects, short of pressing
        // the key on a Mac.
        macos_hotkey_tests.root_module.linkFramework("Carbon", .{});
        macos_hotkey_tests.root_module.link_libc = true;
    }

    // The global-shortcut registry: register / replace / disable / unregister,
    // driven against a fake platform so the whole lifecycle is covered without
    // an app, a window or a key press.
    const shortcut_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shortcut_registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The name <-> macOS virtual key code table that global shortcuts are
    // registered from. Pure data, so it is tested here rather than by pressing
    // keys at a running app.
    const key_codes_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/key_codes.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The preference store's pure core: key rules, the value model, the wire
    // codec and the read/write bookkeeping, driven against an in-memory backend
    // so all of it is provable on a host with no preferences daemon.
    const prefs_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prefs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The CoreFoundation backend. These touch the real preferences daemon, so
    // they run against a throwaway domain and remove every key they create.
    const prefs_macos_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prefs_macos.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target_os == .macos) {
        prefs_macos_tests.root_module.linkFramework("CoreFoundation", .{});
        prefs_macos_tests.root_module.link_libc = true;
    }

    // The capability registry: what native declares it serves, and which event
    // channels have a live emitter. Pure data plus a JSON renderer.
    const capabilities_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capabilities.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Where a link that asks for a new window is allowed to go. Pure policy,
    // so the whole drop list is provable without a browser.
    const external_link_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external_link.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Whether closing the last window quits the app. Pure rule, exhaustively
    // tested, so the default and its opt-out are stated once.
    const lifecycle_policy_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lifecycle_policy.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The reload budget that brings a window back after WebKit's content
    // process dies. Pure, and takes its clock as an argument, so a crash loop
    // is testable without crashing anything.
    const webview_recovery_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/webview_recovery.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Which bridge call a reply belongs to. A thread-local stack, so nesting
    // (a modal run loop re-entering dispatch) is part of what gets tested.
    const request_context_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/request_context.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The CLI's own tests. `src/cli.zig` was only ever built as a *module*, so
    // the tests inside it — flag parsing, and the manifest keys those flags
    // mirror — had no artifact to run in and never ran at all.
    const cli_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    cli_unit_tests.root_module.link_libc = true;

    // Notification action buttons: which category a set of buttons forms, and
    // what a response means. Pure, so the whole thing is provable without
    // posting a banner or clicking one.
    const notification_actions_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/notification_actions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Whether every window craft opens can be reopened. A source conformance
    // test: constructing a window needs a live NSApplication and a WebContent
    // process, but the two properties worth defending — every constructor
    // registers, and nothing infers craft-ness from a window again — are
    // properties of the source.
    const window_lifecycle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/window_lifecycle_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    window_lifecycle_tests.root_module.addAnonymousImport("src/macos.zig", .{
        .root_source_file = b.path("src/macos.zig"),
    });

    // The window registry itself, free of Objective-C so the whole lifecycle
    // is provable without AppKit.
    const window_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/window_registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The shell bridge's argv construction: what a `spawn` actually runs.
    // Untested until now, which is how it shipped parsing an `args` array and
    // throwing it away.
    const bridge_shell_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bridge_shell.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bridge_shell_tests.root_module.link_libc = true;

    // The host logger's own internals. `test/log_test.zig` already exercises it
    // through the module boundary, which cannot reach the config storage or the
    // formatter — the three places it was wrong. Rooted at the source file so
    // those are reachable.
    const log_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/log.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    log_unit_tests.root_module.link_libc = true;

    // The page-facing log bridge. It answered `{"ok":true}` and wrote nothing
    // at all on Linux and Windows, which no test noticed because it had none.
    const bridge_log_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bridge_log.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bridge_log_tests.root_module.link_libc = true;

    // The blocking primitives every other lock in craft is built on. They
    // spun without yielding until now, so this is the first time they have
    // been exercised at all.
    const compat_mutex_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compat_mutex.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compat_mutex_tests.root_module.link_libc = true;

    // The conformance test: what craft declares, against what it dispatches.
    const capability_conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/capabilities_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "capability_registry", .module = b.createModule(.{
                    .root_source_file = b.path("src/capability_registry.zig"),
                }) },
            },
        }),
    });
    // The registry imports the declared bridges, which reach the rest of the
    // native graph, so this needs the same libraries the binary links.
    linkPlatformLibraries(b, capability_conformance_tests.root_module, target_os, macos_sdk);
    // The sources it reads, embedded rather than opened at run time: the test
    // is then hermetic and looking at the same bytes the compiler saw.
    for ([_][]const u8{
        "src/macos.zig",
        "src/bridge_clipboard.zig",
        "src/bridge_tray.zig",
        "src/bridge_app.zig",
        "src/bridge_screen.zig",
        "src/bridge_capabilities.zig",
        "src/bridge_capabilities_actions.zig",
        "src/js/craft-bridge.js",
        // The bridges whose payload field names are checked against the page's
        // — see `field_checked` in the test.
        "src/bridge_fs.zig",
        "src/bridge_window.zig",
        "src/bridge_updater.zig",
        "src/bridge_bluetooth.zig",
        "src/bridge_serial.zig",
        "src/bridge_local_server.zig",
    }) |source_path| {
        capability_conformance_tests.root_module.addAnonymousImport(source_path, .{
            .root_source_file = b.path(source_path),
        });
    }
    const run_capability_conformance = b.addRunArtifact(capability_conformance_tests);

    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/config_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/config.zig", .module = config_module },
            },
        }),
    });
    config_tests.root_module.link_libc = true;

    const ipc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/ipc_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/ipc.zig", .module = ipc_module },
            },
        }),
    });

    const performance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/performance_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    performance_tests.root_module.link_libc = true;

    const button_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/button_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const text_input_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/text_input_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const chart_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/chart_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const media_player_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/media_player_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const code_editor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/code_editor_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const tabs_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/tabs_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const modal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/modal_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const progress_bar_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/progress_bar_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const dropdown_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/dropdown_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const toast_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/toast_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });
    toast_tests.root_module.link_libc = true;

    const tree_view_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/tree_view_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const date_picker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/date_picker_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const data_grid_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/data_grid_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const tooltip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/tooltip_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });
    tooltip_tests.root_module.link_libc = true;

    const slider_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/slider_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const autocomplete_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/autocomplete_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const color_picker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/components/color_picker_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "components", .module = craft_module },
            },
        }),
    });

    const error_context_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/error_context_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/error_context.zig", .module = b.createModule(.{
                    .root_source_file = b.path("src/error_context.zig"),
                }) },
            },
        }),
    });
    error_context_tests.root_module.link_libc = true;

    const benchmark_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/benchmark_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "benchmark", .module = benchmark_module },
            },
        }),
    });
    benchmark_tests.root_module.link_libc = true;

    const system_tray_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/system_tray_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/tray.zig", .module = tray_module },
            },
        }),
    });

    // Link platform libraries for tray tests (tray.zig uses ObjC on macOS)
    switch (target_os) {
        .macos => {
            system_tray_tests.root_module.linkFramework("Cocoa", .{});
            system_tray_tests.root_module.linkFramework("WebKit", .{});
            system_tray_tests.root_module.linkFramework("CoreMIDI", .{});
            applySdkPaths(b, system_tray_tests.root_module, macos_sdk);
        },
        .linux => {
            system_tray_tests.root_module.linkSystemLibrary("gtk+-3.0", .{});
        },
        else => {},
    }
    system_tray_tests.root_module.link_libc = true;

    const system_tray_benchmark = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/system_tray_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "../src/tray.zig", .module = tray_module },
            },
        }),
    });

    switch (target_os) {
        .macos => {
            system_tray_benchmark.root_module.linkFramework("Cocoa", .{});
            system_tray_benchmark.root_module.linkFramework("WebKit", .{});
            system_tray_benchmark.root_module.linkFramework("CoreMIDI", .{});
            applySdkPaths(b, system_tray_benchmark.root_module, macos_sdk);
        },
        .linux => {
            system_tray_benchmark.root_module.linkSystemLibrary("gtk+-3.0", .{});
        },
        else => {},
    }
    system_tray_benchmark.root_module.link_libc = true;

    const database_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/database.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    database_tests.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_JSON1" },
    });
    database_tests.root_module.addIncludePath(b.path("vendor/sqlite"));
    database_tests.root_module.link_libc = true;

    const run_api_tests = b.addRunArtifact(api_tests);
    const run_mobile_tests = b.addRunArtifact(mobile_tests);
    const run_ios_surface_tests = b.addRunArtifact(ios_surface_tests);
    const run_ios_conformance_tests = b.addRunArtifact(ios_conformance_tests);
    const run_ios_module_tests = b.addRunArtifact(ios_module_tests);
    const run_menubar_tests = b.addRunArtifact(menubar_tests);
    const run_components_tests = b.addRunArtifact(components_tests);
    const run_gpu_tests = b.addRunArtifact(gpu_tests);
    const run_system_tests = b.addRunArtifact(system_tests);
    const run_profiler_tests = b.addRunArtifact(profiler_tests);
    const run_memory_tests = b.addRunArtifact(memory_tests);
    const run_lifecycle_tests = b.addRunArtifact(lifecycle_tests);
    const run_shortcuts_tests = b.addRunArtifact(shortcuts_tests);
    const run_hotreload_tests = b.addRunArtifact(hotreload_tests);
    const run_async_tests = b.addRunArtifact(async_tests);
    const run_events_tests = b.addRunArtifact(events_tests);
    const run_bridge_tests = b.addRunArtifact(bridge_tests);
    const run_devmode_tests = b.addRunArtifact(devmode_tests);
    const run_renderer_tests = b.addRunArtifact(renderer_tests);
    const run_log_tests = b.addRunArtifact(log_tests);
    const run_theme_tests = b.addRunArtifact(theme_tests);
    const run_animation_tests = b.addRunArtifact(animation_tests);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const run_native_sidebar_tests = b.addRunArtifact(native_sidebar_tests);
    const run_space_list_tests = b.addRunArtifact(space_list_tests);
    const run_local_tls_tests = b.addRunArtifact(local_tls_tests);
    const run_menu_roles_tests = b.addRunArtifact(menu_roles_tests);
    const run_capabilities_tests = b.addRunArtifact(capabilities_tests);
    const run_compat_mutex_tests = b.addRunArtifact(compat_mutex_tests);
    const run_bridge_log_tests = b.addRunArtifact(bridge_log_tests);
    const run_log_unit_tests = b.addRunArtifact(log_unit_tests);
    const run_bridge_shell_tests = b.addRunArtifact(bridge_shell_tests);
    const run_window_lifecycle_tests = b.addRunArtifact(window_lifecycle_tests);
    const run_window_registry_tests = b.addRunArtifact(window_registry_tests);
    const run_external_link_tests = b.addRunArtifact(external_link_tests);
    const run_webview_recovery_tests = b.addRunArtifact(webview_recovery_tests);
    const run_request_context_tests = b.addRunArtifact(request_context_tests);
    const run_notification_actions_tests = b.addRunArtifact(notification_actions_tests);
    const run_cli_unit_tests = b.addRunArtifact(cli_unit_tests);
    const run_lifecycle_policy_tests = b.addRunArtifact(lifecycle_policy_tests);
    const run_prefs_tests = b.addRunArtifact(prefs_tests);
    const run_prefs_macos_tests = b.addRunArtifact(prefs_macos_tests);
    const run_key_codes_tests = b.addRunArtifact(key_codes_tests);
    const run_accelerator_tests = b.addRunArtifact(accelerator_tests);
    const run_macos_hotkey_tests = b.addRunArtifact(macos_hotkey_tests);
    const run_shortcut_registry_tests = b.addRunArtifact(shortcut_registry_tests);
    const run_config_tests = b.addRunArtifact(config_tests);
    const run_ipc_tests = b.addRunArtifact(ipc_tests);
    const run_performance_tests = b.addRunArtifact(performance_tests);
    const run_button_tests = b.addRunArtifact(button_tests);
    const run_text_input_tests = b.addRunArtifact(text_input_tests);
    const run_chart_tests = b.addRunArtifact(chart_tests);
    const run_media_player_tests = b.addRunArtifact(media_player_tests);
    const run_code_editor_tests = b.addRunArtifact(code_editor_tests);
    const run_tabs_tests = b.addRunArtifact(tabs_tests);
    const run_modal_tests = b.addRunArtifact(modal_tests);
    const run_progress_bar_tests = b.addRunArtifact(progress_bar_tests);
    const run_dropdown_tests = b.addRunArtifact(dropdown_tests);
    const run_toast_tests = b.addRunArtifact(toast_tests);
    const run_tree_view_tests = b.addRunArtifact(tree_view_tests);
    const run_date_picker_tests = b.addRunArtifact(date_picker_tests);
    const run_data_grid_tests = b.addRunArtifact(data_grid_tests);
    const run_tooltip_tests = b.addRunArtifact(tooltip_tests);
    const run_slider_tests = b.addRunArtifact(slider_tests);
    const run_autocomplete_tests = b.addRunArtifact(autocomplete_tests);
    const run_color_picker_tests = b.addRunArtifact(color_picker_tests);
    const run_error_context_tests = b.addRunArtifact(error_context_tests);
    const run_benchmark_tests = b.addRunArtifact(benchmark_tests);
    const run_system_tray_tests = b.addRunArtifact(system_tray_tests);
    const run_system_tray_benchmark = b.addRunArtifact(system_tray_benchmark);
    const run_database_tests = b.addRunArtifact(database_tests);

    // craft injects six JavaScript files into every webview and none of them
    // had a test: the only way to exercise `window.craft.gestures` was to
    // launch an app and swipe a trackpad. zig-js runs them headlessly.
    //
    // On whenever the runtime is: the engine is already a dependency, so there
    // is no reason for craft's own injected scripts to go untested.
    const js_tests_enabled = b.option(
        bool,
        "js-tests",
        "Test craft's injected JavaScript against zig-js (defaults to whether the JS runtime is built)",
    ) orelse js_runtime_enabled;

    if (js_tests_enabled) {
        {
            const js_dep = b.dependency("zig_js", .{ .target = target, .optimize = optimize });
            const injected_js_tests = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/injected_js_test.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "js", .module = js_dep.module("js") },
                        // The native halves of the contracts under test. The
                        // test drives the real craft-bridge.js and then decodes
                        // what it posted with the very code the bridge
                        // dispatches to, so a rename on either side fails the
                        // build rather than silently producing a menu nobody
                        // can click (#27, #31) or a hotkey that never fires
                        // (#47). One module, because both reach
                        // `bridge_error.zig` — see the file's own comment.
                        .{ .name = "bridge_contracts", .module = b.createModule(.{
                            .root_source_file = b.path("src/bridge_contracts.zig"),
                        }) },
                    },
                }),
            });
            // Passed in by name rather than reached with a relative
            // `@embedFile`: a test module cannot embed files outside its own
            // package path, and these are the same bytes the binary injects.
            injected_js_tests.root_module.addAnonymousImport("craft-gestures.js", .{
                .root_source_file = b.path("src/js/craft-gestures.js"),
            });
            injected_js_tests.root_module.addAnonymousImport("craft-bridge.js", .{
                .root_source_file = b.path("src/js/craft-bridge.js"),
            });
            injected_js_tests.root_module.addAnonymousImport("craft-window-chrome.js", .{
                .root_source_file = b.path("src/js/craft-window-chrome.js"),
            });

            const run_injected_js_tests = b.addRunArtifact(injected_js_tests);
            b.step("test-js", "Run craft's injected JavaScript against zig-js")
                .dependOn(&run_injected_js_tests.step);
            js_test_run = run_injected_js_tests;
        }
    }

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    if (js_test_run) |run| test_step.dependOn(&run.step);
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_mobile_tests.step);
    // Darwin only. `objc_runtime.zig` resolves `objc` to an empty struct off
    // Apple platforms, so `ios.zig` cannot compile on Linux at all — `objc.id`
    // is not a member of `struct {}`. Forcing analysis of every iOS
    // declaration there asks the compiler to check code that has no meaning on
    // the target, and CI is right to refuse.
    //
    // The conformance gate is not gated the same way: it scans source text and
    // touches no platform types, so it runs everywhere.
    if (target.result.os.tag.isDarwin()) {
        test_step.dependOn(&run_ios_surface_tests.step);
        test_step.dependOn(&run_ios_module_tests.step);
    }
    test_step.dependOn(&run_ios_conformance_tests.step);
    test_step.dependOn(&run_menubar_tests.step);
    test_step.dependOn(&run_components_tests.step);
    test_step.dependOn(&run_gpu_tests.step);
    test_step.dependOn(&run_system_tests.step);
    test_step.dependOn(&run_profiler_tests.step);
    test_step.dependOn(&run_memory_tests.step);
    test_step.dependOn(&run_lifecycle_tests.step);
    test_step.dependOn(&run_shortcuts_tests.step);
    test_step.dependOn(&run_hotreload_tests.step);
    test_step.dependOn(&run_async_tests.step);
    test_step.dependOn(&run_events_tests.step);
    test_step.dependOn(&run_bridge_tests.step);
    test_step.dependOn(&run_devmode_tests.step);
    test_step.dependOn(&run_renderer_tests.step);
    test_step.dependOn(&run_log_tests.step);
    test_step.dependOn(&run_theme_tests.step);
    test_step.dependOn(&run_animation_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_native_sidebar_tests.step);
    test_step.dependOn(&run_space_list_tests.step);
    test_step.dependOn(&run_local_tls_tests.step);
    test_step.dependOn(&run_menu_roles_tests.step);
    test_step.dependOn(&run_capabilities_tests.step);
    test_step.dependOn(&run_compat_mutex_tests.step);
    test_step.dependOn(&run_bridge_log_tests.step);
    test_step.dependOn(&run_log_unit_tests.step);
    test_step.dependOn(&run_bridge_shell_tests.step);
    test_step.dependOn(&run_window_lifecycle_tests.step);
    test_step.dependOn(&run_window_registry_tests.step);
    test_step.dependOn(&run_external_link_tests.step);
    test_step.dependOn(&run_webview_recovery_tests.step);
    test_step.dependOn(&run_request_context_tests.step);
    test_step.dependOn(&run_notification_actions_tests.step);
    test_step.dependOn(&run_cli_unit_tests.step);
    test_step.dependOn(&run_lifecycle_policy_tests.step);
    // macOS only: the registry describes the dispatch chain in macos.zig, and
    // compiling it elsewhere drags the whole native graph into a test binary
    // for a platform it does not describe.
    if (target_os == .macos) test_step.dependOn(&run_capability_conformance.step);
    test_step.dependOn(&run_prefs_tests.step);
    test_step.dependOn(&run_prefs_macos_tests.step);
    test_step.dependOn(&run_key_codes_tests.step);
    test_step.dependOn(&run_accelerator_tests.step);
    test_step.dependOn(&run_macos_hotkey_tests.step);
    test_step.dependOn(&run_shortcut_registry_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_performance_tests.step);
    test_step.dependOn(&run_button_tests.step);
    test_step.dependOn(&run_text_input_tests.step);
    test_step.dependOn(&run_chart_tests.step);
    test_step.dependOn(&run_media_player_tests.step);
    test_step.dependOn(&run_code_editor_tests.step);
    test_step.dependOn(&run_tabs_tests.step);
    test_step.dependOn(&run_modal_tests.step);
    test_step.dependOn(&run_progress_bar_tests.step);
    test_step.dependOn(&run_dropdown_tests.step);
    test_step.dependOn(&run_toast_tests.step);
    test_step.dependOn(&run_tree_view_tests.step);
    test_step.dependOn(&run_date_picker_tests.step);
    test_step.dependOn(&run_data_grid_tests.step);
    test_step.dependOn(&run_tooltip_tests.step);
    test_step.dependOn(&run_slider_tests.step);
    test_step.dependOn(&run_autocomplete_tests.step);
    test_step.dependOn(&run_color_picker_tests.step);
    test_step.dependOn(&run_error_context_tests.step);
    test_step.dependOn(&run_benchmark_tests.step);
    test_step.dependOn(&run_system_tray_tests.step);
    test_step.dependOn(&run_system_tray_benchmark.step);
    test_step.dependOn(&run_database_tests.step);

    // Individual test steps
    const test_api_step = b.step("test:api", "Run API tests");
    test_api_step.dependOn(&run_api_tests.step);

    const test_mobile_step = b.step("test:mobile", "Run Mobile tests");
    test_mobile_step.dependOn(&run_mobile_tests.step);

    const test_ios_step = b.step("test:ios", "Run the iOS surface gate");
    if (target.result.os.tag.isDarwin()) {
        test_ios_step.dependOn(&run_ios_surface_tests.step);
        test_ios_step.dependOn(&run_ios_module_tests.step);
    }
    test_ios_step.dependOn(&run_ios_conformance_tests.step);

    const test_menubar_step = b.step("test:menubar", "Run Menubar tests");
    test_menubar_step.dependOn(&run_menubar_tests.step);

    const test_components_step = b.step("test:components", "Run Components tests");
    test_components_step.dependOn(&run_components_tests.step);

    const test_gpu_step = b.step("test:gpu", "Run GPU tests");
    test_gpu_step.dependOn(&run_gpu_tests.step);

    const test_system_step = b.step("test:system", "Run System tests");
    test_system_step.dependOn(&run_system_tests.step);

    const test_profiler_step = b.step("test:profiler", "Run Profiler tests");
    test_profiler_step.dependOn(&run_profiler_tests.step);

    const test_memory_step = b.step("test:memory", "Run Memory tests");
    test_memory_step.dependOn(&run_memory_tests.step);

    const test_lifecycle_step = b.step("test:lifecycle", "Run Lifecycle tests");
    test_lifecycle_step.dependOn(&run_lifecycle_tests.step);

    const test_shortcuts_step = b.step("test:shortcuts", "Run Shortcuts tests");
    test_shortcuts_step.dependOn(&run_shortcuts_tests.step);

    const test_hotreload_step = b.step("test:hotreload", "Run Hot Reload tests");
    test_hotreload_step.dependOn(&run_hotreload_tests.step);

    const test_async_step = b.step("test:async", "Run Async tests");
    test_async_step.dependOn(&run_async_tests.step);

    const test_events_step = b.step("test:events", "Run Events tests");
    test_events_step.dependOn(&run_events_tests.step);

    const test_bridge_step = b.step("test:bridge", "Run Bridge tests");
    test_bridge_step.dependOn(&run_bridge_tests.step);

    const test_devmode_step = b.step("test:devmode", "Run Dev Mode tests");
    test_devmode_step.dependOn(&run_devmode_tests.step);

    const test_renderer_step = b.step("test:renderer", "Run Renderer tests");
    test_renderer_step.dependOn(&run_renderer_tests.step);

    const test_log_step = b.step("test:log", "Run Log tests");
    test_log_step.dependOn(&run_log_tests.step);

    const test_theme_step = b.step("test:theme", "Run Theme tests");
    test_theme_step.dependOn(&run_theme_tests.step);

    const test_animation_step = b.step("test:animation", "Run Animation tests");
    test_animation_step.dependOn(&run_animation_tests.step);

    const test_cli_step = b.step("test:cli", "Run CLI tests");
    test_cli_step.dependOn(&run_cli_tests.step);

    const test_native_sidebar_step = b.step("test:native-sidebar", "Run Native Sidebar tests");
    test_native_sidebar_step.dependOn(&run_native_sidebar_tests.step);

    const test_space_list_step = b.step("test:space-list", "Run Space List tests");
    test_space_list_step.dependOn(&run_space_list_tests.step);

    const test_local_tls_step = b.step("test:local-tls", "Run local development TLS tests");
    test_local_tls_step.dependOn(&run_local_tls_tests.step);

    const test_menu_roles_step = b.step("test:menu-roles", "Run menu role table tests");
    test_menu_roles_step.dependOn(&run_menu_roles_tests.step);

    const test_capabilities_step = b.step("test:capabilities", "Run capability registry tests");
    test_capabilities_step.dependOn(&run_capabilities_tests.step);
    test_capabilities_step.dependOn(&run_capability_conformance.step);

    const test_prefs_step = b.step("test:prefs", "Run preference store tests");
    test_prefs_step.dependOn(&run_prefs_tests.step);
    test_prefs_step.dependOn(&run_prefs_macos_tests.step);

    const test_key_codes_step = b.step("test:key-codes", "Run key code table tests");
    test_key_codes_step.dependOn(&run_key_codes_tests.step);

    const test_accelerator_step = b.step("test:accelerator", "Run accelerator parsing tests");
    test_accelerator_step.dependOn(&run_accelerator_tests.step);
    test_accelerator_step.dependOn(&run_macos_hotkey_tests.step);

    const test_shortcut_registry_step = b.step("test:shortcut-registry", "Run global shortcut registry tests");
    test_shortcut_registry_step.dependOn(&run_shortcut_registry_tests.step);

    const test_config_step = b.step("test:config", "Run Config tests");
    test_config_step.dependOn(&run_config_tests.step);

    const test_ipc_step = b.step("test:ipc", "Run IPC tests");
    test_ipc_step.dependOn(&run_ipc_tests.step);

    const test_performance_step = b.step("test:performance", "Run Performance tests");
    test_performance_step.dependOn(&run_performance_tests.step);

    const test_button_step = b.step("test:button", "Run Button component tests");
    test_button_step.dependOn(&run_button_tests.step);

    const test_text_input_step = b.step("test:text_input", "Run TextInput component tests");
    test_text_input_step.dependOn(&run_text_input_tests.step);

    const test_chart_step = b.step("test:chart", "Run Chart component tests");
    test_chart_step.dependOn(&run_chart_tests.step);

    const test_media_player_step = b.step("test:media_player", "Run MediaPlayer component tests");
    test_media_player_step.dependOn(&run_media_player_tests.step);

    const test_code_editor_step = b.step("test:code_editor", "Run CodeEditor component tests");
    test_code_editor_step.dependOn(&run_code_editor_tests.step);

    const test_tabs_step = b.step("test:tabs", "Run Tabs component tests");
    test_tabs_step.dependOn(&run_tabs_tests.step);

    const test_modal_step = b.step("test:modal", "Run Modal component tests");
    test_modal_step.dependOn(&run_modal_tests.step);

    const test_progress_bar_step = b.step("test:progress_bar", "Run ProgressBar component tests");
    test_progress_bar_step.dependOn(&run_progress_bar_tests.step);

    const test_dropdown_step = b.step("test:dropdown", "Run Dropdown component tests");
    test_dropdown_step.dependOn(&run_dropdown_tests.step);

    const test_toast_step = b.step("test:toast", "Run Toast component tests");
    test_toast_step.dependOn(&run_toast_tests.step);

    const test_tree_view_step = b.step("test:tree_view", "Run TreeView component tests");
    test_tree_view_step.dependOn(&run_tree_view_tests.step);

    const test_date_picker_step = b.step("test:date_picker", "Run DatePicker component tests");
    test_date_picker_step.dependOn(&run_date_picker_tests.step);

    const test_data_grid_step = b.step("test:data_grid", "Run DataGrid component tests");
    test_data_grid_step.dependOn(&run_data_grid_tests.step);

    const test_tooltip_step = b.step("test:tooltip", "Run Tooltip component tests");
    test_tooltip_step.dependOn(&run_tooltip_tests.step);

    const test_slider_step = b.step("test:slider", "Run Slider component tests");
    test_slider_step.dependOn(&run_slider_tests.step);

    const test_autocomplete_step = b.step("test:autocomplete", "Run Autocomplete component tests");
    test_autocomplete_step.dependOn(&run_autocomplete_tests.step);

    const test_color_picker_step = b.step("test:color_picker", "Run ColorPicker component tests");
    test_color_picker_step.dependOn(&run_color_picker_tests.step);

    const test_error_context_step = b.step("test:error_context", "Run ErrorContext tests");
    test_error_context_step.dependOn(&run_error_context_tests.step);

    const test_benchmark_step = b.step("test:benchmark", "Run Benchmark tests");
    test_benchmark_step.dependOn(&run_benchmark_tests.step);

    const test_database_step = b.step("test:database", "Run Database tests");
    test_database_step.dependOn(&run_database_tests.step);

    // Cross-compilation helpers
    const build_linux = b.step("build-linux", "Build for Linux");
    const build_windows = b.step("build-windows", "Build for Windows");
    const build_macos = b.step("build-macos", "Build for macOS");
    const build_all = b.step("build-all", "Build for all platforms");

    // Linux target
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });

    const linux_exe = b.addExecutable(.{
        .name = "craft-linux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/minimal.zig"),
            .target = linux_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    linkPlatformLibraries(b, linux_exe.root_module, .linux, null);

    const linux_install = b.addInstallArtifact(linux_exe, .{});
    build_linux.dependOn(&linux_install.step);
    build_all.dependOn(&linux_install.step);

    // Windows target
    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });

    const windows_exe = b.addExecutable(.{
        .name = "craft-windows",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/minimal.zig"),
            .target = windows_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    linkPlatformLibraries(b, windows_exe.root_module, .windows, null);

    const windows_install = b.addInstallArtifact(windows_exe, .{});
    build_windows.dependOn(&windows_install.step);
    build_all.dependOn(&windows_install.step);

    // macOS target
    const macos_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });

    const macos_exe = b.addExecutable(.{
        .name = "craft-macos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/minimal.zig"),
            .target = macos_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    linkPlatformLibraries(b, macos_exe.root_module, .macos, macos_sdk);

    const macos_install = b.addInstallArtifact(macos_exe, .{});
    build_macos.dependOn(&macos_install.step);
    build_all.dependOn(&macos_install.step);

    // ========================================================================
    // iOS Build Targets
    // ========================================================================

    const build_ios = b.step("build-ios", "Build for iOS (device)");
    const build_ios_simulator = b.step("build-ios-simulator", "Build for iOS Simulator");
    const build_ios_all = b.step("build-ios-all", "Build for iOS (device + simulator)");

    // iOS Device (arm64)
    const ios_device_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
    });

    const ios_device_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "craft-ios",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ios_main.zig"),
            .target = ios_device_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    // Linked by clang/swiftc, not by Zig, so the compiler-rt intrinsics Zig
    // code needs (f128 soft-float from std.json's number parsing, among
    // others) must travel inside the archive — no later link step provides
    // them, and the failure is undefined symbols in whoever consumes the lib.
    ios_device_lib.bundle_compiler_rt = true;
    // The db actions run on the vendored SQLite, same flags as every other
    // target — an iOS archive without it would push the whole amalgamation
    // onto the consuming app's build instead.
    if (iosSdkPath(b, "iphoneos")) |sdk_path| {
        ios_device_lib.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_JSON1" },
        });
        ios_device_lib.root_module.addIncludePath(b.path("vendor/sqlite"));
        ios_device_lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk_path}) });
    } else {
        // No xcrun: the archive ships without sqlite and the db actions
        // resolve as undefined symbols at app link — loud, not silent.
    }
    ios_device_lib.root_module.link_libc = true;
    // Frameworks are linked at the app level in Xcode, not in the static library
    const ios_device_install = b.addInstallArtifact(ios_device_lib, .{});
    build_ios.dependOn(&ios_device_install.step);
    build_ios_all.dependOn(&ios_device_install.step);

    // iOS Simulator (arm64 for Apple Silicon Macs)
    const ios_sim_arm64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .simulator,
    });

    const ios_sim_arm64_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "craft-ios-simulator-arm64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ios_main.zig"),
            .target = ios_sim_arm64_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    // Linked by clang/swiftc, not by Zig, so the compiler-rt intrinsics Zig
    // code needs (f128 soft-float from std.json's number parsing, among
    // others) must travel inside the archive — no later link step provides
    // them, and the failure is undefined symbols in whoever consumes the lib.
    ios_sim_arm64_lib.bundle_compiler_rt = true;
    // The db actions run on the vendored SQLite, same flags as every other
    // target — an iOS archive without it would push the whole amalgamation
    // onto the consuming app's build instead.
    if (iosSdkPath(b, "iphonesimulator")) |sdk_path| {
        ios_sim_arm64_lib.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_JSON1" },
        });
        ios_sim_arm64_lib.root_module.addIncludePath(b.path("vendor/sqlite"));
        ios_sim_arm64_lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk_path}) });
    } else {
        // No xcrun: the archive ships without sqlite and the db actions
        // resolve as undefined symbols at app link — loud, not silent.
    }
    ios_sim_arm64_lib.root_module.link_libc = true;
    const ios_sim_arm64_install = b.addInstallArtifact(ios_sim_arm64_lib, .{});
    build_ios_simulator.dependOn(&ios_sim_arm64_install.step);
    build_ios_all.dependOn(&ios_sim_arm64_install.step);

    // iOS Simulator (x86_64 for Intel Macs)
    const ios_sim_x64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .ios,
        .abi = .simulator,
    });

    const ios_sim_x64_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "craft-ios-simulator-x64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ios_main.zig"),
            .target = ios_sim_x64_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    // Linked by clang/swiftc, not by Zig, so the compiler-rt intrinsics Zig
    // code needs (f128 soft-float from std.json's number parsing, among
    // others) must travel inside the archive — no later link step provides
    // them, and the failure is undefined symbols in whoever consumes the lib.
    ios_sim_x64_lib.bundle_compiler_rt = true;
    // The db actions run on the vendored SQLite, same flags as every other
    // target — an iOS archive without it would push the whole amalgamation
    // onto the consuming app's build instead.
    if (iosSdkPath(b, "iphonesimulator")) |sdk_path| {
        ios_sim_x64_lib.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_JSON1" },
        });
        ios_sim_x64_lib.root_module.addIncludePath(b.path("vendor/sqlite"));
        ios_sim_x64_lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk_path}) });
    } else {
        // No xcrun: the archive ships without sqlite and the db actions
        // resolve as undefined symbols at app link — loud, not silent.
    }
    ios_sim_x64_lib.root_module.link_libc = true;
    const ios_sim_x64_install = b.addInstallArtifact(ios_sim_x64_lib, .{});
    build_ios_simulator.dependOn(&ios_sim_x64_install.step);
    build_ios_all.dependOn(&ios_sim_x64_install.step);

    // Web-to-native example for iOS
    const build_web_to_native_ios = b.step("build-web-to-native-ios", "Build web-to-native example for iOS");

    const web_to_native_ios_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "web-to-native-ios",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/web_to_native/main.zig"),
            .target = ios_device_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    const web_to_native_ios_install = b.addInstallArtifact(web_to_native_ios_lib, .{});
    build_web_to_native_ios.dependOn(&web_to_native_ios_install.step);

    // ========================================================================
    // File Dialogs Example
    // ========================================================================

    const run_dialogs = b.step("run-dialogs", "Run the file dialogs example");

    const dialogs_exe = b.addExecutable(.{
        .name = "file-dialogs-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/file_dialogs/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    dialogs_exe.root_module.linkFramework("Cocoa", .{});
    dialogs_exe.root_module.linkFramework("WebKit", .{});
    dialogs_exe.root_module.link_libc = true;

    const run_dialogs_cmd = b.addRunArtifact(dialogs_exe);
    run_dialogs.dependOn(&run_dialogs_cmd.step);

    // ========================================================================
    // Notifications Example
    // ========================================================================

    const run_notifications = b.step("run-notifications", "Run the notifications example");

    const notifications_exe = b.addExecutable(.{
        .name = "notifications-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/notifications/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    notifications_exe.root_module.linkFramework("Cocoa", .{});
    notifications_exe.root_module.linkFramework("WebKit", .{});
    notifications_exe.root_module.link_libc = true;

    const run_notifications_cmd = b.addRunArtifact(notifications_exe);
    run_notifications.dependOn(&run_notifications_cmd.step);

    // ========================================================================
    // System Tray Example
    // ========================================================================

    const run_tray = b.step("run-tray", "Run the system tray example");

    const tray_exe = b.addExecutable(.{
        .name = "tray-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/system_tray/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    tray_exe.root_module.linkFramework("Cocoa", .{});
    tray_exe.root_module.linkFramework("WebKit", .{});
    tray_exe.root_module.link_libc = true;

    const run_tray_cmd = b.addRunArtifact(tray_exe);
    run_tray.dependOn(&run_tray_cmd.step);

    // ========================================================================
    // Clipboard Example
    // ========================================================================

    const run_clipboard = b.step("run-clipboard", "Run the clipboard example");

    const clipboard_exe = b.addExecutable(.{
        .name = "clipboard-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/clipboard/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    clipboard_exe.root_module.linkFramework("Cocoa", .{});
    clipboard_exe.root_module.linkFramework("WebKit", .{});
    clipboard_exe.root_module.link_libc = true;

    const run_clipboard_cmd = b.addRunArtifact(clipboard_exe);
    run_clipboard.dependOn(&run_clipboard_cmd.step);

    // ========================================================================
    // Hot Reload Example
    // ========================================================================

    const run_hotreload = b.step("run-hotreload", "Run the hot reload example");

    const hotreload_exe = b.addExecutable(.{
        .name = "hotreload-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hot_reload/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    hotreload_exe.root_module.linkFramework("Cocoa", .{});
    hotreload_exe.root_module.linkFramework("WebKit", .{});
    hotreload_exe.root_module.link_libc = true;

    const run_hotreload_cmd = b.addRunArtifact(hotreload_exe);
    run_hotreload.dependOn(&run_hotreload_cmd.step);

    // ========================================================================
    // Android Build Targets
    // ========================================================================

    const build_android = b.step("build-android", "Build for Android (arm64)");
    const build_android_x86 = b.step("build-android-x86", "Build for Android (x86_64)");
    const build_android_all = b.step("build-android-all", "Build for Android (all architectures)");

    // Android Device (arm64)
    const android_arm64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_arm64_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "craft-android-arm64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/android.zig"),
            .target = android_arm64_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    android_arm64_lib.root_module.link_libc = true;

    const android_arm64_install = b.addInstallArtifact(android_arm64_lib, .{});
    build_android.dependOn(&android_arm64_install.step);
    build_android_all.dependOn(&android_arm64_install.step);

    // Android Emulator (x86_64)
    const android_x86_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_x86_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "craft-android-x86_64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/android.zig"),
            .target = android_x86_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "craft", .module = craft_module },
            },
        }),
    });
    android_x86_lib.root_module.link_libc = true;

    const android_x86_install = b.addInstallArtifact(android_x86_lib, .{});
    build_android_x86.dependOn(&android_x86_install.step);
    build_android_all.dependOn(&android_x86_install.step);

    // The `run-android` step and its `android-example` executable used to sit
    // here. It was not an Android artifact: it built for the *host* and linked
    // Cocoa/WebKit on macOS and GTK on Linux, so "running the Android example"
    // meant running a desktop printf demo. Its source called
    // `AndroidFeatures.getDeviceInfo()`, which returned a hardcoded
    // "Android Device" / SDK 34 no matter what, and printed the result as if
    // it had queried something.

    // ========================================================================
    // Android Tests
    // ========================================================================

    const android_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/android.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_android_tests = b.addRunArtifact(android_tests);

    const test_android_step = b.step("test:android", "Run Android tests");
    test_android_step.dependOn(&run_android_tests.step);

    // Add Android tests to the main test step
    test_step.dependOn(&run_android_tests.step);
}

/// Link platform-specific system libraries for a build module.
/// Centralizes the per-OS library linking that is shared across exe, craft_exe,
/// lib_unit_tests, and cross-compilation targets.
/// The iOS SDK sysroot, resolved through xcrun at configure time.
///
/// Needed because the iOS archives compile the vendored sqlite3.c, and C
/// compilation for an Apple target wants the SDK's libc headers — Zig's
/// bundled headers cover Zig code, not a C translation unit's <stdio.h>.
/// Absent xcrun (a non-mac host), returns null and the C source is skipped;
/// the cross-compile of *Zig* code still works, and CI's mac runners have
/// xcrun.
fn iosSdkPath(b: *std.Build, sdk_name: []const u8) ?[]const u8 {
    var exit_code: u8 = 0;
    const out = b.runAllowFail(
        &.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" },
        &exit_code,
        .ignore,
    ) catch return null;
    if (exit_code != 0) return null;
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn linkPlatformLibraries(b: *std.Build, module: *std.Build.Module, target_os: std.Target.Os.Tag, sdk_path: ?[]const u8) void {
    switch (target_os) {
        .macos => {
            module.linkFramework("Cocoa", .{});
            module.linkFramework("WebKit", .{});
            // CoreMIDI for `bridge_midi.zig` — symbols are macOS-only
            // and don't auto-resolve via Cocoa. CoreML and Vision
            // resolve through their own frameworks; not bundled here
            // because the bridges call them via objc msgSend rather
            // than direct C symbols, so the runtime resolves them
            // when the app dynamically loads them.
            module.linkFramework("CoreMIDI", .{});
            module.linkFramework("CoreSpotlight", .{});
            // CoreFoundation for `prefs_macos.zig`, which calls the
            // CFPreferences quad directly. The shipped binary resolves these
            // through Cocoa, but a test artifact that reaches the same code
            // does not always, so name it.
            module.linkFramework("CoreFoundation", .{});
            // Carbon for `macos_hotkey.zig`: `RegisterEventHotKey` is the only
            // route to a global hotkey that neither needs an Objective-C block
            // (which Zig cannot write) nor Accessibility permission (which a
            // CGEventTap would).
            module.linkFramework("Carbon", .{});
            applySdkPaths(b, module, sdk_path);
        },
        .linux => {
            module.linkSystemLibrary("gtk+-3.0", .{});
            module.linkSystemLibrary("webkit2gtk-4.1", .{});
        },
        .windows => {
            module.linkSystemLibrary("ole32", .{});
            module.linkSystemLibrary("user32", .{});
            module.linkSystemLibrary("gdi32", .{});
            module.linkSystemLibrary("shell32", .{});
        },
        else => {},
    }
    // Compile vendored SQLite amalgamation — works on all platforms without
    // requiring a system sqlite3 installation.
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_JSON1" },
    });
    module.addIncludePath(b.path("vendor/sqlite"));
    module.link_libc = true;
}

/// Add macOS SDK search paths for cross-compilation.
/// Uses -Dmacos-sdk instead of --sysroot to avoid Zig bugs where --sysroot
/// breaks @cImport and auto-prepends inconsistently (ziglang/zig#22704, #25010).
fn applySdkPaths(builder: *std.Build, module: *std.Build.Module, sdk_path: ?[]const u8) void {
    const sdk = sdk_path orelse return;
    module.addSystemFrameworkPath(.{
        .cwd_relative = builder.pathJoin(&.{ sdk, "System/Library/Frameworks" }),
    });
    module.addSystemIncludePath(.{
        .cwd_relative = builder.pathJoin(&.{ sdk, "usr/include" }),
    });
    module.addLibraryPath(.{
        .cwd_relative = builder.pathJoin(&.{ sdk, "usr/lib" }),
    });
}
