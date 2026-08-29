const std = @import("std");
const ios = @import("../src/ios.zig");

// Test *collection*, distinct from the analysis the gate below forces.
// `refAllDeclsRecursive` makes the compiler check every declaration, which is
// what catches compile errors — but it does not enroll imported files' `test`
// blocks. Only this idiom does. Without it, every test in ios.zig,
// ios_dispatch.zig, and the mobile modules was silently absent from the run:
// found with a canary — a deliberately failing test in a module, and a green
// build.
test {
    _ = ios;
}
const objc = ios.objc;

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

// `run()` is now `noreturn` — it hands control to `UIApplicationMain` and
// never comes back — so it cannot be called from a test. What can be checked
// on the host is the part that used to be inline in `run` and is now the
// launch callback's body.
//
// On macOS this fails at `createWindow`, because `objc_getClass("UIScreen")`
// is null: UIScreen is UIKit, and this is AppKit's platform. The specific
// error is not asserted — that would pin the host rather than the property.
// What is asserted is that it reports *something*. A startup path that builds
// no window and says nothing is the failure this file exists to prevent, and
// it is what shipped here for three months.
test "the launch callback never reports success without building anything" {
    if (!@import("builtin").target.os.tag.isDarwin()) return error.SkipZigTest;

    var app = ios.CraftAppDelegate.init(std.testing.allocator, .{
        .name = "Surface Test",
        .initial_content = .{ .html = "<h1>hi</h1>" },
    });

    if (app.didFinishLaunching()) |_| {
        return error.LaunchClaimedSuccessOnAHostWithoutUIKit;
    } else |_| {
        // Any error is correct. Silence is not.
    }
}

// The delegate class UIKit is asked to instantiate must actually exist by the
// time `UIApplicationMain` is told its name. Registering it is pure
// Objective-C runtime work — `objc_allocateClassPair`, `class_addMethod`,
// `objc_registerClassPair` — with nothing from UIKit in it, so it can be
// exercised on the host even though the app it serves cannot launch here.
//
// A silent failure here would surface on a device as an app that launches to
// a black screen with no delegate callbacks and no error, which is among the
// least diagnosable failures iOS has.
test "the app delegate class registers, and registering twice is harmless" {
    if (!@import("builtin").target.os.tag.isDarwin()) return error.SkipZigTest;

    try ios.registerAppDelegateClass();
    try std.testing.expect(objc.objc_getClass("CraftAppDelegate") != null);

    // Idempotent: `UIApplicationMain` is called once, but nothing in the
    // runtime stops a second registration attempt, and `objc_allocateClassPair`
    // returns null for a name already taken rather than erroring usefully.
    try ios.registerAppDelegateClass();
}
