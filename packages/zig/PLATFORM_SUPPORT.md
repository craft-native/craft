# Craft Platform Support

What Craft does on each platform, and how much of that is checked by something
other than a person reading the code.

## Supported Platforms

| Platform | Status | Min Version | Architecture | What you get |
|----------|--------|-------------|--------------|--------------|
| macOS | Production | 11.0 (Big Sur) | x86_64, arm64 | WKWebView window, the whole `window.craft` bridge, the AppKit native host |
| Windows | Experimental | 10 (1903) | x86_64 | WebView2 window and the bridge namespaces listed below |
| Linux | Experimental | Kernel 5.4+ | x86_64 | GTK3 + WebKit2GTK 4.1 window and the bridge namespaces listed below |
| iOS | Preview | 14.0 | arm64 | WKWebView shell and the mobile bridges |
| Android | Preview | API 26 (8.0) | arm64-v8a, armeabi-v7a | WebView shell and the mobile bridges |

On Windows and Linux, Craft is a webview window with a deliberately small
native bridge. Anything process-shaped (running programs, reading files,
storing secrets) belongs in your app's own backend process there, not in the
page bridge.

## Desktop page bridge (`window.craft.*`)

This table is the contract. The first column is the namespace a page message
carries, and `scripts/platform-support.test.ts` fails if the Windows or Linux
column stops matching what `windows.zig` and `linux.zig` route. A call into a
namespace marked "no" is rejected with `PLATFORM_NOT_SUPPORTED`; it does not
hang and it does not silently succeed.

<!-- desktop-bridge-table:start -->

| Namespace | What it covers | macOS | Windows | Linux |
|-----------|----------------|-------|---------|-------|
| `window` | Named windows, parent and modal ownership, size, position, state, fullscreen, `executeJavaScript`, window events | yes | yes | yes |
| `clipboard` | `readText`, `writeText` | yes | yes | yes |
| `notification` | `show`, `schedule`, `requestPermission` | yes | yes | yes |
| `menu` | `craft.menu.set`, `addItem`, `removeItem`, `enableItem`, `disableItem`, `checkItem`, `uncheckItem`, `setItemLabel`, `onAction`, roles, accelerators | yes | yes | yes |
| `dialog` | `showOpenDialog` (file, files, folder), `showSaveDialog`, `showAlert`, `showConfirm`, `showMessageBox` | yes | yes | yes |
| `nativeUI` | `showContextMenu`, `onContextMenuAction` | yes | yes | yes |
| `app` | `quit`, `relaunch`, `onSecondInstance` | yes | yes | yes |

<!-- desktop-bridge-table:end -->

Delivered to the page without a request, on all three: `craft.deepLink.onUrl`
and `getInitialUrl`, and `craft.onFileDrop`.

Every other namespace is macOS only: `fs`, `shell`, `keychain`, `tray`,
`shortcuts`, `updater`, `system`, `power`, `network`, `bluetooth`, `screen`,
`prefs`, `capabilities`, the rest of `nativeUI` (sidebars, split views, Quick
Look), the rest of `app` (`getInfo`, Dock icon, badge, bounce), the Dock menu,
and `dialog.showColorPicker`.

### Where the platforms differ

- **Accelerators.** A menu shortcut is written once. `cmd`, `CmdOrCtrl` and
  `ctrl` are Command on macOS and Control on Windows and Linux, so `cmd+n` is
  Ctrl+N there.
- **Menu bar placement.** macOS has one application menu bar. On Windows and
  Linux the bar belongs to the window whose page called `craft.menu.set`.
- **Roles.** `undo`, `redo`, `cut`, `copy`, `paste`, `delete` and `selectAll`
  are performed by the web content. Their accelerator is drawn but not
  intercepted, so the key reaches the page as it would in a browser. `hide`,
  `hideOthers`, `showAll` and `front` have no meaning off macOS and those
  items are left out. `about` has no standard panel off macOS: the item is
  shown and reported through `craft.menu.onAction` with its id (`about` when
  it has none).
- **Checked items.** Windows draws a native check mark. GTK draws a leading
  check character, because its own check item toggles itself when chosen and
  the page, not the toolkit, decides what is checked.
- **Message dialogs.** The reply is the same everywhere. Windows draws custom
  button labels with a task dialog, which needs version 6 of the common
  controls; `craft.exe` carries the manifest for it. A process that embeds
  Craft without that manifest gets a stock message box: OK, OK/Cancel or
  Yes/No/Cancel by button count, with the reply still an index into the list
  the page asked for.
- **File drop.** macOS and Linux report paths natively and leave the page's
  own drag handling alone. WebView2 only reveals paths for files the page
  hands back to the host, so on Windows Craft cancels `dragover` and `drop`
  for drags that carry files. A file dropped on a page that handles nothing
  therefore does not navigate the window there, as it would on the other two.
- **Context menus on Wayland.** GTK is asked to open the popup without an
  input event to anchor it to. X11 accepts that; a Wayland compositor may not.
- **Single instance.** `--single-instance <id>` keeps one running process per
  id on Windows and Linux. A later launch brings the first window forward,
  hands it its `--instance-arg` values and deep link as
  `craft.app.onSecondInstance`, and exits 0. macOS already keeps one instance
  of an app bundle and delivers URLs through `craft.deepLink`, so the event
  never fires there.
- **Relaunch.** `craft.app.relaunch()` takes no arguments. It starts this
  process's own command line again and quits, or, when the launcher that
  started Craft set `CRAFT_RELAUNCH_EXECUTABLE` (and optionally
  `CRAFT_RELAUNCH_ARGS`, a JSON array in which `{pid}` becomes the exiting
  process id), starts that instead. A page cannot choose the program.
- **Deep links.** The packager registers `urlSchemes` in the MSI (under
  `HKCR`) and in the `.desktop` file (`x-scheme-handler/…`), each launching
  the app with `--deep-link`.

### What is verified, and how

| Surface | Windows | Linux |
|---------|---------|-------|
| Menu bar structure, item text, check and gray state | Read back from the Win32 menu in CI | Bar presence only (it takes room above the page) |
| Choosing a menu item | `WM_COMMAND` in CI | Through accelerators in CI |
| Accelerators | Synthesized keys in CI, with focus on the window and in the page | xdotool keys in CI |
| Context menu: dismiss, choose, reply shape, event | CI | CI (X11) |
| Alert, confirm, custom buttons | CI, against the task dialog | CI for the default button and dismissal; custom labels are drawn but not read back |
| Open, multi-select, folder and save dialogs: cancel and accept | CI | CI |
| Single-instance hand-off, with arguments and deep link | CI | CI |
| Relaunch through a launcher override | CI | CI |
| Deep-link registration and cold and warm delivery of an installed app | CI (`verify-packaged-app.ts`) | CI (`verify-packaged-app.ts`) |
| File drop from another application | **Not verified.** Nothing in CI performs an OLE drag. | A real X11 drag in CI |
| Editing roles chosen from the menu (Copy, Paste, and so on) | **Not verified** | **Not verified** |
| Self-relaunch (no launcher override) | **Not verified** end to end; the command line it builds is unit tested | **Not verified** end to end; same |
| Wayland | n/a | **Not verified.** CI runs X11 under Xvfb. |

The CI run is `scripts/verify-desktop-bridge.ts`, on `windows-2025` and
`ubuntu-latest`. A row marked "not verified" compiles and has been reviewed,
and has never been seen working on a real desktop by anything automated.

## Native Zig modules

The tables below describe Craft's Zig library modules (`notifications.zig`,
`audio.zig`, `bluetooth.zig` and so on), which are a different thing from the
page bridge above. They have not been audited against the code the way the
bridge table has, most of the Windows and Linux entries are not exercised by
CI, and an entry here does not mean `window.craft` exposes that feature on
that platform. Treat the bridge table as what a webview app can rely on, and
these as a map of where native code exists.

### Window Management

| Feature | macOS | Windows | Linux | iOS | Android |
|---------|-------|---------|-------|-----|---------|
| Create/Destroy | ✅ | ✅ | ✅ | ✅ | ✅ |
| Show/Hide | ✅ | ✅ | ✅ | ✅ | ✅ |
| Minimize/Maximize | ✅ | ✅ | ✅ | ❌ | ❌ |
| Fullscreen | ✅ | ✅ | ✅ | ✅ | ✅ |
| Resize | ✅ | ✅ | ✅ | ❌ | ❌ |
| Always on Top | ✅ | ✅ | ✅ | ❌ | ❌ |
| Vibrancy/Blur | ✅ | ❌ | ❌ | ✅ | ✅ |
| Transparency | ✅ | ❌ | ❌ | ✅ | ✅ |

### Notifications

| Feature | macOS | Windows | Linux | iOS | Android |
|---------|-------|---------|-------|-----|---------|
| Show | ✅ UNUserNotification | ✅ WinRT Toast | ✅ libnotify | ✅ UNNotification | ✅ NotificationManager |
| Schedule | ✅ | ✅ | ⚠️ | ✅ | ✅ |
| Actions | ✅ | ✅ | ⚠️ | ✅ | ✅ |
| Badge | ✅ | ⚠️ | ❌ | ✅ | ✅ |
| Categories | ✅ | ⚠️ | ❌ | ✅ | ✅ |

### Audio

| Feature | macOS | Windows | Linux | iOS | Android |
|---------|-------|---------|-------|-----|---------|
| Playback | ✅ AVAudioPlayer | ✅ winmm | ✅ paplay/canberra | ✅ AVAudioPlayer | ✅ MediaPlayer |
| Recording | ✅ AVAudioRecorder | ⚠️ | ⚠️ | ✅ AVAudioRecorder | ✅ MediaRecorder |
| System Sounds | ✅ | ✅ | ✅ | ✅ | ✅ |
| Haptic | ✅ NSHapticFeedback | ⚠️ | ❌ | ✅ UIFeedbackGenerator | ✅ Vibrator |

### Camera

| Feature | macOS | Windows | Linux | iOS | Android |
|---------|-------|---------|-------|-----|---------|
| Capture | ✅ AVCaptureSession | ⚠️ MediaFoundation | ⚠️ V4L2 | ✅ AVCaptureSession | ✅ CameraX |
| Photo | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| Video | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| Barcode | ✅ AVMetadataObject | ⚠️ | ⚠️ | ✅ | ✅ ML Kit |

### Clipboard

| Feature | macOS | Windows | Linux | iOS | Android |
|---------|-------|---------|-------|-----|---------|
| Text | ✅ NSPasteboard | ✅ Clipboard API | ✅ xclip/wl-copy | ✅ UIPasteboard | ✅ ClipboardManager |
| HTML | ✅ | ✅ | ✅ | ⚠️ | ⚠️ |
| Image | ✅ | ✅ | ✅ | ✅ | ✅ |
| Files | ✅ | ✅ | ✅ | ⚠️ | ⚠️ |

### System Tray

| Feature | macOS | Windows | Linux | iOS | Android |
|---------|-------|---------|-------|-----|---------|
| Icon | ✅ NSStatusItem | ✅ Shell_NotifyIcon | ✅ AppIndicator | ❌ | ❌ |
| Menu | ✅ | ✅ | ✅ | ❌ | ❌ |
| Tooltip | ✅ | ✅ | ✅ | ❌ | ❌ |

### Internationalization

| Feature | macOS | Windows | Linux | iOS | Android |
|---------|-------|---------|-------|-----|---------|
| Locale Detection | ✅ NSLocale | ✅ GetUserDefaultLocaleName | ✅ env vars | ✅ NSLocale | ✅ Locale |
| Date Format | ✅ | ✅ | ✅ | ✅ | ✅ |
| Number Format | ✅ | ✅ | ✅ | ✅ | ✅ |
| RTL Support | ✅ | ✅ | ✅ | ✅ | ✅ |

### Bluetooth

| Feature | macOS | Windows | Linux | iOS | Android |
|---------|-------|---------|-------|-----|---------|
| Discovery | ✅ CoreBluetooth | ⚠️ | ⚠️ bluez | ✅ CoreBluetooth | ✅ BluetoothAdapter |
| Connect | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| GATT | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |

### Biometrics

| Feature | macOS | Windows | Linux | iOS | Android |
|---------|-------|---------|-------|-----|---------|
| Touch ID | ✅ LocalAuthentication | ❌ | ❌ | ✅ | ❌ |
| Face ID | ✅ | ❌ | ❌ | ✅ | ✅ |
| Windows Hello | ❌ | ✅ | ❌ | ❌ | ❌ |
| Fingerprint | ✅ | ⚠️ | ❌ | ✅ | ✅ |

## Platform-Specific APIs

### macOS

```zig
const macos = @import("macos.zig");

// Objective-C runtime
const class = macos.getClass("NSApplication");
const result = macos.msgSend0(class, "sharedApplication");

// Selectors
const sel = macos.sel("windowWithContentRect:styleMask:backing:defer:");
```

**Frameworks Used:**

- AppKit (windows, menus, dialogs)
- Foundation (strings, collections)
- AVFoundation (audio, camera)
- CoreBluetooth (Bluetooth)
- UserNotifications (notifications)
- LocalAuthentication (biometrics)

### Windows

```zig
const windows = @import("windows.zig");

// A WebView2 window
var window = try windows.Window.create(.{ .title = "App", .width = 800, .height = 600 });
try window.loadURL("https://example.com");
window.show();
windows.runApp();
```

**APIs Used:**

- Win32 (windows, menus, clipboard)
- WebView2 over COM (the web view, accelerator keys, dropped files)
- COM shell dialogs (`IFileOpenDialog`, `IFileSaveDialog`)
- comctl32 version 6 (`TaskDialogIndirect`, looked up at run time)
- WinRT (notifications, Bluetooth)
- winmm (audio)

### Linux

```zig
const linux = @import("linux.zig");

// A GTK3 + WebKit2GTK window
var window = try linux.Window.create(.{ .title = "App", .width = 800, .height = 600 });
try window.loadURL("https://example.com");
window.show();
linux.runApp();
```

**Libraries Used:**

- GTK3 (windows, menu bar, accelerators, context menus, file and message dialogs, drag and drop)
- WebKit2GTK 4.1 (the web view)
- GApplication over D-Bus (single-instance activation, deep links)
- libnotify (notifications)
- bluez/D-Bus (Bluetooth)
- ALSA/PulseAudio (audio)
- V4L2 (camera)
- GTK clipboard (clipboard)

### iOS

```zig
const ios = @import("ios.zig");

// UIKit via Objective-C runtime
const vc = ios.msgSend0(class, "topViewController");
ios.showAlert(title, message);
```

**Frameworks Used:**

- UIKit (UI components)
- AVFoundation (audio, camera)
- CoreBluetooth (Bluetooth)
- UserNotifications (notifications)
- LocalAuthentication (biometrics)

### Android

```zig
const android = @import("android.zig");

// JNI calls
const jni = android.getJNI();
const cls = jni.findClass("android/widget/Toast");
```

**APIs Used:**

- JNI (Java interop)
- Android SDK classes
- CameraX (camera)
- NotificationManager (notifications)
- BluetoothAdapter (Bluetooth)
- BiometricPrompt (biometrics)

## Adding Platform Support

### 1. Create Platform Module

```zig
// src/newplatform.zig
pub fn init() void {
    // Platform initialization
}

pub fn deinit() void {
    // Platform cleanup
}
```

### 2. Update Platform Detection

```zig
// src/platform.zig
const builtin = @import("builtin");

pub const current = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .windows => @import("windows.zig"),
    .linux => @import("linux.zig"),
    .newplatform => @import("newplatform.zig"),
    else => @compileError("Unsupported platform"),
};
```

### 3. Implement Feature Modules

```zig
// Feature implementation
pub fn showNotification(title: []const u8, body: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => try macos.showNotification(title, body),
        .windows => try windows.showNotification(title, body),
        .linux => try linux.showNotification(title, body),
        else => return error.NotSupported,
    }
}
```

## Legend

- ✅ Code exists for it (see the note above the native module tables on what that does and does not mean)
- ⚠️ Partial support / limitations
- 🚧 In development
- ❌ Not supported / not applicable
