# Getting Started with Craft

## Installation

### 1. Install Pantry Dependencies

Craft uses Pantry to provide the current stable Zig toolchain:

```bash
pantry install
```

### 2. Verify Installation

```bash
eval "$(pantry env)" && zig version
# Should show Pantry's installed stable Zig version
```

## Building Craft

Build from the repository root:

```bash
bun run build:core
```

Run tests:

```bash
bun run test
```

Run the example app:

```bash
bun run run
```

## Creating Your First App

### Basic Example

Create a new file `my-app.zig`:

```zig
const std = @import("std");
const craft = @import("craft");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = craft.App.init(allocator);
    defer app.deinit();

    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>My First Craft App</title>
        \\    <style>
        \\        body {
        \\            font-family: system-ui;
        \\            display: flex;
        \\            justify-content: center;
        \\            align-items: center;
        \\            height: 100vh;
        \\            margin: 0;
        \\            background: #f0f0f0;
        \\        }
        \\        h1 { color: #333; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>Hello, Craft!</h1>
        \\</body>
        \\</html>
    ;

    _ = try app.createWindow("My First App", 800, 600, html);
    try app.run();
}
```

### Building Your App

Create a `build.zig` file:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const craft_module = b.dependency("craft", .{
        .target = target,
        .optimize = optimize,
    }).module("craft");

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("my-app.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("craft", craft_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

Then build and run:

```bash
zig build run
```

The exported `craft` module declares its native libraries. Applications should
not copy Craft's linker flags. The maintained
[graphics package consumer](../packages/zig/test/fixtures/graphics-package-consumer/)
uses this same dependency API to check exact CPU bitmap, textured terrain,
UTF-8 atlas glyph and complete-frame pixels, shared Canvas types, atomic frame
rejection and explicit unsupported shader/font-family text errors. Run
`bun scripts/verify-zig-package-consumer.ts` from the repository root, with the
pinned `CRAFT_ZIG`. It archives only the declared package paths and runs the
consumer against an unchanged extraction with fresh compiler caches. It selects `js-runtime=false` because it opens no window and
executes no JavaScript. This check does not prove native window presentation.

## Platform-Specific Setup

### macOS

On macOS, Craft uses WebKit framework which is included by default. No additional dependencies needed.

### Linux

Install required dependencies:

**Ubuntu/Debian:**

```bash
sudo apt-get install libgtk-3-dev libwebkit2gtk-4.1-dev
```

**Fedora:**

```bash
sudo dnf install gtk3-devel webkit2gtk3-devel
```

**Arch:**

```bash
sudo pacman -S gtk3 webkit2gtk
```

### Windows

On Windows, you need WebView2 Runtime:

1. Download from [Microsoft Edge WebView2](https://developer.microsoft.com/en-us/microsoft-edge/webview2/)
2. Install the Evergreen Runtime

## Project Structure

A typical Craft project:

```
my-craft-app/
├── build.zig          # Build configuration
├── src/
│   └── main.zig       # Your app code
├── assets/            # Static files (optional)
│   ├── index.html
│   ├── style.css
│   └── app.js
└── zig-out/           # Build output (generated)
```

## Next Steps

1. Check out the [examples](../../examples/desktop-app.zig)
2. Read the [API documentation](./README.md#api-reference)
3. Join the Stacks community

## Troubleshooting

### "command not found: zig"

Make sure Zig is installed and in your PATH. Try:

```bash
which zig  # macOS/Linux
where zig  # Windows
```

### Build errors on Linux

Make sure you have the required development libraries:

```bash
# Ubuntu/Debian
sudo apt-get install build-essential libgtk-3-dev libwebkit2gtk-4.1-dev
```

### WebView not showing on Windows

Install WebView2 Runtime from Microsoft's website.

## Development Status

⚠️ **Note**: Craft is in early development. The core API is ready, but platform-specific webview implementations are still being developed. Currently, the framework:

- ✅ Has a clean, working API
- ✅ Compiles successfully
- ✅ Passes tests
- 🚧 Needs platform-specific webview bindings (in progress)

You can use Craft today to design your app structure and UI, and full webview rendering will be available as platform bindings are completed.
