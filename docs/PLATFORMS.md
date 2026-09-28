# Platform Support Guide

Craft 0.0.40 treats macOS as the tier-1 desktop target. Linux and Windows
are experimental: their window/WebView foundations build, but bridge, tray,
packaging, and advanced native API coverage are incomplete. Do not treat an
experimental target as production-ready without application-specific testing.

## Platform Overview

| Platform | Status | WebView Technology | Binary Size | Notes |
|----------|--------|-------------------|-------------|-------|
| **macOS** | ✅ Production | WKWebView (Native) | ~297 KB | Full native support |
| **Linux** | 🧪 Experimental | WebKit2GTK 4.1 | Untracked | Requires GTK3 + WebKit2GTK |
| **Windows** | 🧪 Experimental | WebView2 (Edge) | Untracked | Requires WebView2 Runtime |

## macOS

### Requirements

- **OS Version**: macOS 10.15 (Catalina) or later
- **WebView**: WKWebView (built-in)
- **Frameworks**: Cocoa, WebKit
- **Build Tools**: Xcode Command Line Tools

### Installation

```bash
# Install pantry dependencies and use Craft's pantry-aware runner
pantry install

# Clone and build
git clone https://github.com/stacksjs/stx
cd stx/packages/craft
bun run build:core

# Run
./zig-out/bin/craft http://localhost:3000
```

### Building for macOS

```bash
# Native build (current arch)
eval "$(pantry env)"
cd packages/zig
zig build

# Cross-compile for macOS (Apple Silicon)
eval "$(pantry env)"
cd packages/zig
zig build build-macos

# Create .app bundle
eval "$(pantry env)"
cd packages/zig
zig build -Doptimize=ReleaseFast
./scripts/create-app-bundle.sh
```

### Features

macOS is the only tier-1 target. The following areas have production coverage:

- ✅ Native window management
- ✅ WKWebView with full JavaScript bridge
- ✅ System tray integration
- ✅ Native notifications
- ✅ Hot reload
- ✅ Developer tools (WebKit Inspector)
- ✅ Multi-window support
- ✅ Fullscreen, frameless, transparent windows
- ✅ Clipboard access
- ✅ File dialogs
- ✅ All performance features

### Deployment

See [DEPLOYMENT.md](DEPLOYMENT.md#macos-deployment) for:

- Code signing
- Notarization
- DMG creation
- App Store distribution

---

## Linux

### Requirements

- **Distribution**: Ubuntu 20.04+, Fedora 35+, Debian 11+, or compatible
- **WebView**: WebKit2GTK 4.1
- **GUI**: GTK 3
- **Build Tools**: GCC or Clang

### Installation

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y \
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    build-essential

# Fedora
sudo dnf install -y \
    gtk3-devel \
    webkit2gtk4.1-devel \
    gcc

# Arch Linux
sudo pacman -S \
    gtk3 \
    webkit2gtk-4.1 \
    base-devel

# Install pantry dependencies and use Craft's pantry-aware runner
pantry install

# Clone and build
git clone https://github.com/stacksjs/stx
cd stx/packages/craft
bun run build:core

# Run
./zig-out/bin/craft http://localhost:3000
```

### Building for Linux

```bash
# Native build
eval "$(pantry env)"
cd packages/zig
zig build

# Cross-compile for Linux (from macOS/Windows)
eval "$(pantry env)"
cd packages/zig
zig build build-linux

# Release build
eval "$(pantry env)"
cd packages/zig
zig build -Doptimize=ReleaseFast
```

### Features

Currently implemented foundations (experimental):

- 🧪 GTK3 native windows
- ✅ WebKit2GTK web rendering
- 🚧 Notifications, tray, clipboard, and dialogs require further integration testing
- ✅ Hot reload via WebSocket
- ✅ Developer tools (WebKit Inspector)
- ✅ Named runtime windows, addressed controls, and scoped window events (GUI smoke in CI)
- 🚧 Other bridge parity and advanced window behavior remain incomplete

The Xvfb smoke covers named create, addressed replies, close, and reopen; it
does not establish full desktop bridge parity for a particular application.

### Known Limitations

- **Transparency**: Requires compositor (e.g., Picom, Compton)
- **System Tray**: May vary by desktop environment (GNOME, KDE, XFCE)
- **Wayland/X11**: support depends on the GTK3/WebKit2GTK environment and is experimental

### Deployment

See [DEPLOYMENT.md](DEPLOYMENT.md#linux-deployment) for:

- AppImage creation
- .deb package creation
- .rpm package creation
- Flatpak packaging
- Snap packaging

---

## Windows

### Requirements

- **OS Version**: Windows 10 (1809+) or Windows 11
- **WebView**: Microsoft Edge WebView2
- **Build Tools**: Visual Studio 2022 or MinGW-w64

### Installation

#### Prerequisites

1. **Install WebView2 Runtime**
   - Download from: <https://developer.microsoft.com/en-us/microsoft-edge/webview2/>
   - Or install via: `winget install Microsoft.EdgeWebView2Runtime`

2. **Install Zig**

   ```powershell
# Using winget
   winget install -e --id ziglang.zig

# Or download manually
# https://ziglang.org/download/
   ```

3. **Install Build Tools**
   - **Option A**: Visual Studio 2022 (Community Edition)
     - Select "Desktop development with C++"
   - **Option B**: MinGW-w64

     ```powershell
     winget install -e --id Msys2.Msys2
# Then in MSYS2: pacman -S mingw-w64-x86_64-gcc
     ```

#### Building

```powershell
# Clone repository
git clone https://github.com/stacksjs/stx
cd stx\packages\craft

# Build
zig build

# Run
.\zig-out\bin\craft.exe http://localhost:3000
```

### Building for Windows

```bash
# Native build (on Windows)
zig build

# Cross-compile for Windows (from macOS/Linux)
zig build build-windows

# Release build
zig build -Doptimize=ReleaseFast
```

### Features

Currently implemented foundations (experimental):

- ✅ Win32 native windows
- ✅ WebView2 (Edge Chromium) rendering
- 🚧 Notifications, tray, clipboard, and dialogs require further integration testing
- ✅ Hot reload via WebSocket
- ✅ Developer tools (Edge DevTools)
- ✅ Named runtime windows, addressed controls, and scoped window events (WebView2 GUI smoke in CI)
- 🚧 Other bridge parity and advanced window behavior remain incomplete

The native WebView2 smoke also exercises concurrent child creation and cleanup;
it does not establish full desktop bridge parity for a particular application.

### Known Limitations

- **WebView2 Required**: End users must have WebView2 Runtime installed; release archives include the app-local loader DLL
- **Transparency**: Requires DWM (Desktop Window Manager) enabled
- **System Tray**: Icon must be .ico format
- **UWP Apps**: Limited support for UWP features

### Deployment

See [DEPLOYMENT.md](DEPLOYMENT.md#windows-deployment) for:

- WebView2 bundling
- NSIS installer creation
- MSI package creation
- Code signing
- Windows Store submission

---

## Cross-Platform Development

### Unified API

Craft provides a stable, unified API across all platforms:

```zig
const craft = @import("craft");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = craft.App.init(gpa.allocator());
    defer app.deinit();

    // Works on macOS, Linux, and Windows
    _ = try app.createWindow(
        "My Cross-Platform App",
        1200,
        800,
        "http://localhost:3000",
        .{},
    );

    try app.run();
}
```

### Platform Detection

```zig
const craft = @import("craft");

// Check current platform
const platform = craft.Platform.name(); // "macOS", "Linux", or "Windows"

// Check if platform is supported
if (!craft.Platform.isSupported()) {
    return error.UnsupportedPlatform;
}

// Feature detection
if (craft.Features.hasSystemTray()) {
    // Enable system tray
}
```

### Platform-Specific Code

When you need platform-specific functionality:

```zig
const builtin = @import("builtin");

switch (builtin.target.os.tag) {
    .macos => {
        // macOS-specific code
        const macos = @import("macos.zig");
        // ...
    },
    .linux => {
        // Linux-specific code
        const linux = @import("linux.zig");
        // ...
    },
    .windows => {
        // Windows-specific code
        const windows = @import("windows.zig");
        // ...
    },
    else => return error.UnsupportedPlatform,
}
```

### Build Scripts

Create platform-specific builds:

```bash
# Build for all platforms
zig build build-all

# Build for specific platform
zig build build-linux
zig build build-windows
zig build build-macos
```

---

## Performance Comparison

| Metric | macOS | Linux | Windows |
|--------|-------|-------|---------|
| **Binary Size** | ~297 KB | 1.5MB | 1.6MB |
| **Startup Time** | ~168 ms | <120ms | <150ms |
| **Memory (idle)** | ~86 MB | ~95MB | ~98MB |
| **CPU (idle)** | <1% | <1% | <1% |

---

## Troubleshooting

### macOS

**Issue**: "craft cannot be opened because the developer cannot be verified"
```bash
# Solution: Remove quarantine attribute
xattr -d com.apple.quarantine ./zig-out/bin/craft
```

**Issue**: WebKit Inspector not showing
```bash
# Solution: Enable developer extras
defaults write NSGlobalDomain WebKitDeveloperExtras -bool true
```

### Linux

**Issue**: Failed to load shared library libwebkit2gtk
```bash
# Solution: Install WebKit2GTK
sudo apt-get install libwebkit2gtk-4.1-0
```

**Issue**: Window transparency not working
```bash
# Solution: Enable compositor
# For XFCE: Settings → Window Manager Tweaks → Compositor
# For i3: Install picom
sudo apt-get install picom
picom &
```

### Windows

**Issue**: WebView2 not found
```powershell
# Solution: Install WebView2 Runtime
winget install Microsoft.EdgeWebView2Runtime
```

**Issue**: Cannot find vcruntime140.dll
```powershell
# Solution: Install Visual C++ Redistributable
winget install Microsoft.VCRedist.2015+.x64
```

---

## Platform-Specific APIs

### macOS Only

```zig
const macos = @import("macos.zig");

// Touch Bar support
try macos.createTouchBar(window, items);

// Dark mode detection
const is_dark = macos.isDarkMode();

// App Store receipt validation
try macos.validateReceipt();
```

### Linux Only

```zig
const linux = @import("linux.zig");

// GTK theme detection
const theme_name = linux.getGtkTheme();

// Desktop notification actions
try linux.showNotificationWithActions(title, message, actions);

// D-Bus integration
try linux.registerDBusService("com.example.app");
```

### Windows Only

```zig
const windows = @import("windows.zig");

// Windows Registry access
const value = try windows.registryRead(key, name);

// Jump list support
try windows.setJumpList(items);

// Windows Hello authentication
const authenticated = try windows.authenticateWithHello();
```

---

## Migration Guide

### From Electron

Craft apps are 1351x smaller and start 2.4x faster than Electron:

| Aspect | Electron | Craft |
|--------|----------|------|
| Binary | ~392 MB | ~297 KB |
| Startup | ~412 ms | ~168 ms |
| Memory | ~369 MB | ~86 MB |
| Language | JavaScript | Zig + Web |

### From Tauri

Craft provides similar performance with simpler architecture:

| Aspect | Tauri | Craft |
|--------|-------|------|
| Binary | ~7.69 MB | ~297 KB |
| Language | Rust + Web | Zig + Web |
| Features | 50+ | 67 |
| Platform | Rust bridge | Native |

---

## License

MIT - See [LICENSE](../LICENSE) for details.

## Support

- **Issues**: <https://github.com/stacksjs/stx/issues>
- **Discussions**: <https://github.com/stacksjs/stx/discussions>
- **Discord**: <https://discord.gg/stacks>
