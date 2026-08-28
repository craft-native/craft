const std = @import("std");
const ios = @import("../src/ios.zig");

// `std.testing.refAllDeclsRecursive` is gone in 0.17 — only the shallow
// `refAllDecls` survives, and shallow is not enough here. Everything that
// matters on the iOS surface lives one level down, inside `CraftAppDelegate`,
// so a top-level-only sweep would walk straight past the code that broke.
//
// `decl_names` reports only public declarations, which is what keeps this from
// recursing forever on the `const Self = @This();` that most of these structs
// carry.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl_name| {
        if (@TypeOf(@field(T, decl_name)) == type) {
            switch (@typeInfo(@field(T, decl_name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl_name)),
                else => {},
            }
        }
        _ = &@field(T, decl_name);
    }
}

// iOS compiled for nobody, for three months, and the test suite stayed green.
//
// The reason is worth stating, because it is the whole point of this file.
// Zig analyses function bodies lazily: a declaration nothing references is
// never checked. `test/mobile_test.zig` touches enums and struct literals —
// `HapticType.selection`, an `AppConfig{...}` — and never calls a function
// that reaches the Objective-C runtime. So `zig build test` passed while
// `zig build build-ios-simulator` failed with nine errors, and neither
// result contradicted the other.
//
// `refAllDeclsRecursive` forces analysis of every declaration reachable from
// the root. That turns "does iOS compile" into a host build that takes
// seconds, instead of a cross-compilation nobody runs locally.
//
// Cross-compiling remains the source of truth — this cannot catch a target
// specific ABI problem, and two of the nine original errors were exactly
// that. It catches the other seven, and it catches them in the loop you are
// already running.
test "every declaration reachable from ios.zig compiles" {
    refAllDeclsRecursive(ios);
}

// `CraftAppDelegate.run` is the startup path, and every private helper that
// survives into the real one is reachable only through it. Referencing the
// type explicitly means a helper cannot be quietly orphaned — dropped from
// `run` and left to rot uncompiled — without this failing.
test "the app delegate and its startup helpers compile" {
    refAllDeclsRecursive(ios.CraftAppDelegate);
}

// Not a smoke test — an assertion about honesty.
//
// `run()` cannot start an iOS app yet: UIKit owns the run loop and only hands
// it over through `UIApplicationMain`, which this file does not yet call. The
// previous version spun a bare `NSRunLoop` and returned no error, so a caller
// could not tell "running" apart from "did nothing".
//
// What this pins is only that: **it must not report success.** The specific
// error is deliberately not asserted, because which one comes back depends on
// where the host gives out. Running on macOS, `createWindow` fails first —
// `objc_getClass("UIScreen")` is null, since UIScreen is UIKit and this is
// AppKit's platform — so the error is `ClassNotFound`, not the
// `RunLoopNotImplemented` at the end of the function. Pinning the exact tag
// would be pinning the host, not the property.
//
// When `UIApplicationMain` lands, this test should be revisited rather than
// deleted: the property it protects — that a startup path which did not start
// anything says so — is the one that failed here for three months.
test "run never reports success while it cannot start an app" {
    if (!@import("builtin").target.os.tag.isDarwin()) return error.SkipZigTest;

    var app = ios.CraftAppDelegate.init(std.testing.allocator, .{
        .name = "Surface Test",
        .initial_content = .{ .html = "<h1>hi</h1>" },
    });

    if (app.run()) |_| {
        return error.RunClaimedSuccessWithoutStartingAnApp;
    } else |_| {
        // Any error is correct. Silence is not.
    }
}
