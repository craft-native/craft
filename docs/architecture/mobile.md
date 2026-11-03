# Mobile Architecture

This document describes Craft's mobile platform architecture for iOS and Android.

## Renderer modes and ownership

Craft supports web, hybrid and native applications. The default is the web
renderer; native rendering is an explicit application configuration. A native
application is not a wrapper that reloads its website on every launch.

| Mode | UI source | Platform rendering |
|---|---|---|
| Web (`renderer: 'web'`) | Remote URL or bundled web assets | WKWebView on iOS, WebView on Android |
| Hybrid | Web renderer plus `nativeScreens` and a native bundle | Native controls on mapped routes, web view on other app routes |
| Native (`renderer: 'native'`) | Bundled stx screens and client setup | UIKit on iOS, Android views on Android; no application web view |

In native mode, stx owns component composition, slots, signals, bindings and
translation to native IR. Craft owns platform controls, navigation, permissions,
device services and bridge execution. The same compiled stx route bundle can be
used by both native hosts. Shared authoring does not imply that arbitrary browser
DOM APIs or CSS translate to native controls; inspect compiler diagnostics and
test interactions on each host.

```mermaid
flowchart LR
    STX[Shared stx components and client setup] --> WEB[HTML and browser runtime]
    STX --> IR[Native IR and shared signals runtime]
    IR --> IOS[Craft UIKit host]
    IR --> ANDROID[Craft Android host]
    IOS --> SERVICES[Native device services]
    ANDROID --> SERVICES
```

Native screen code and imported helpers are installed with the app. Updating
them, the Craft host or declared capabilities requires an app rebuild and
release. API data can refresh independently. A native config's site URL supplies
the API and navigation origin; it does not replace the bundled UI with a remote
website. Unmapped native-mode routes open in the platform's in-app browser or
Custom Tab, which has its own authentication context.

See [Native STX on iOS and Android](../guides/native-stx.md) for the native build
and verification contract. The web-view diagrams and integrations below describe
the web renderer and hybrid web routes; they are not the execution path for
native-only screens.

## Overview

Craft provides a unified mobile API through `mobile.zig` that abstracts iOS and Android platform differences while exposing platform-specific features when needed.

## Platform Abstraction

```mermaid
graph TB
    subgraph "Unified API"
        APP[MobileApp]
        WV[MobileWebView]
        PERM[Permissions]
        HAP[Haptics]
        DEV[Device Info]
    end

    subgraph "iOS Implementation"
        UI[UIKit]
        WK[WKWebView]
        HF[UIFeedbackGenerator]
        PH[PHPhotoLibrary]
        CL[CLLocationManager]
    end

    subgraph "Android Implementation"
        AA[Android Activity]
        AW[Android WebView]
        VB[Vibrator]
        PM[PermissionManager]
        LM[LocationManager]
    end

    APP --> UI
    APP --> AA

    WV --> WK
    WV --> AW

    HAP --> HF
    HAP --> VB

    PERM --> PH
    PERM --> CL
    PERM --> PM
    PERM --> LM
```

## iOS Architecture

### Application Lifecycle

```mermaid
stateDiagram-v2
    [*] --> NotRunning
    NotRunning --> Inactive: Launch
    Inactive --> Active: Foreground
    Active --> Inactive: Interruption
    Inactive --> Background: Enter Background
    Background --> Inactive: Enter Foreground
    Background --> Suspended: No Activity
    Suspended --> NotRunning: Terminate
    Inactive --> NotRunning: Terminate
```

### WKWebView Integration (web and hybrid routes)

```mermaid
graph TB
    subgraph "iOS App"
        VC[UIViewController]
        WK[WKWebView]
        CFG[WKWebViewConfiguration]
        UC[WKUserContentController]
        MH[WKScriptMessageHandler]
    end

    subgraph "Zig Bridge"
        IOS[ios.zig]
        BR[bridge.zig]
        CB[Callbacks]
    end

    VC --> WK
    WK --> CFG
    CFG --> UC
    UC --> MH
    MH --> IOS
    IOS --> BR
    BR --> CB
```

### iOS-Specific Features

```mermaid
graph LR
    subgraph "iOS Features"
        TB[Touch Bar<br/>macOS Catalyst]
        FI[Face ID / Touch ID]
        AP[Apple Pay]
        SI[Sign in with Apple]
        PN[Push Notifications]
        HC[HealthKit]
        WC[WatchKit]
    end
```

## Android Architecture

### Activity Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Created: onCreate
    Created --> Started: onStart
    Started --> Resumed: onResume
    Resumed --> Paused: onPause
    Paused --> Stopped: onStop
    Stopped --> Destroyed: onDestroy
    Destroyed --> [*]

    Paused --> Resumed: onResume
    Stopped --> Started: onRestart
```

### WebView Integration (web and hybrid routes)

```mermaid
graph TB
    subgraph "Android App"
        ACT[Activity]
        WV[WebView]
        WS[WebSettings]
        WC[WebViewClient]
        WCC[WebChromeClient]
        JI[JavaScriptInterface]
    end

    subgraph "Zig Bridge"
        AND[android.zig]
        JNI[JNI Helpers]
        BR[bridge.zig]
    end

    ACT --> WV
    WV --> WS
    WV --> WC
    WV --> WCC
    WV --> JI
    JI --> AND
    AND --> JNI
    JNI --> BR
```

### Android-Specific Features

```mermaid
graph LR
    subgraph "Android Features"
        INT[Intents]
        SVC[Services]
        BR[BroadcastReceiver]
        CP[ContentProvider]
        WG[Widgets]
        NFC[NFC]
        BIO[Biometric]
    end
```

## Permission System

### iOS Permissions

```mermaid
graph TB
    subgraph "iOS Permission Flow"
        REQ[Request Permission]
        INFO[Info.plist Entry]
        PROMPT[System Prompt]
        AUTH[Authorization Status]
    end

    subgraph "Permission Types"
        CAM[Camera<br/>NSCameraUsageDescription]
        MIC[Microphone<br/>NSMicrophoneUsageDescription]
        LOC[Location<br/>NSLocationWhenInUseUsageDescription]
        PHO[Photos<br/>NSPhotoLibraryUsageDescription]
        CON[Contacts<br/>NSContactsUsageDescription]
        NOT[Notifications<br/>requestAuthorization]
    end

    REQ --> INFO
    INFO --> PROMPT
    PROMPT --> AUTH

    CAM --> REQ
    MIC --> REQ
    LOC --> REQ
    PHO --> REQ
    CON --> REQ
    NOT --> REQ
```

### Android Permissions

```mermaid
graph TB
    subgraph "Android Permission Flow"
        MAN[Manifest Declaration]
        CHK[Check Permission]
        REQ[Request Permission]
        RES[Handle Result]
    end

    subgraph "Permission Types"
        CAM[CAMERA]
        MIC[RECORD*AUDIO]
        LOC[ACCESS*FINE*LOCATION]
        STO[READ*EXTERNAL*STORAGE]
        CON[READ*CONTACTS]
        NOT[POST*NOTIFICATIONS]
    end

    MAN --> CHK
    CHK --> REQ
    REQ --> RES

    CAM --> MAN
    MIC --> MAN
    LOC --> MAN
    STO --> MAN
    CON --> MAN
    NOT --> MAN
```

## Unified Permission API

```zig
pub const Permission = enum {
    camera,
    microphone,
    location,
    location*always,
    photos,
    contacts,
    notifications,
    calendar,
    reminders,
    bluetooth,
};

pub const PermissionStatus = enum {
    not*determined,
    restricted,
    denied,
    authorized,
    limited,
};

pub fn requestPermission(permission: Permission) !PermissionStatus {
    // Platform-specific implementation
}
```

## Haptic Feedback

```mermaid
graph TB
    subgraph "Haptic Types"
        IMP[Impact<br/>light, medium, heavy]
        NOT[Notification<br/>success, warning, error]
        SEL[Selection]
    end

    subgraph "iOS"
        UIH[UIImpactFeedbackGenerator]
        UIN[UINotificationFeedbackGenerator]
        UIS[UISelectionFeedbackGenerator]
    end

    subgraph "Android"
        VIB[Vibrator]
        VE[VibrationEffect]
    end

    IMP --> UIH
    IMP --> VIB
    NOT --> UIN
    NOT --> VIB
    SEL --> UIS
    SEL --> VIB
```

## Bridge Protocol (Mobile)

### iOS Message Handler

```mermaid
sequenceDiagram
    participant JS as JavaScript
    participant WK as WKWebView
    participant MH as Message Handler
    participant ZIG as Zig Code

    JS->>WK: webkit.messageHandlers.craft.postMessage(msg)
    WK->>MH: userContentController:didReceiveScriptMessage:
    MH->>ZIG: handleMessage(payload)
    ZIG-->>MH: Response
    MH->>WK: evaluateJavaScript("craftHandleResponse(...)")
    WK-->>JS: Promise resolved
```

### Android JavaScript Interface

```mermaid
sequenceDiagram
    participant JS as JavaScript
    participant WV as WebView
    participant JI as @JavascriptInterface
    participant JNI as JNI
    participant ZIG as Zig Code

    JS->>WV: CraftBridge.invoke(method, params)
    WV->>JI: invoke(String, String)
    JI->>JNI: CallStaticVoidMethod
    JNI->>ZIG: handleMessage
    ZIG-->>JNI: Response
    JNI-->>JI: Return
    JI->>WV: webView.evaluateJavascript
    WV-->>JS: Callback executed
```

## Native Object Management

```mermaid
graph TB
    subgraph "NativeObjectManager"
        REG[Register Object]
        GET[Get Object]
        REM[Remove Object]
        CLN[Cleanup All]
    end

    subgraph "Tracked Objects"
        WV[WebViews]
        VC[ViewControllers]
        OBS[Observers]
        TMR[Timers]
    end

    REG --> WV
    REG --> VC
    REG --> OBS
    REG --> TMR

    GET --> WV
    GET --> VC

    REM --> WV
    REM --> VC
    REM --> OBS
    REM --> TMR

    CLN --> WV
    CLN --> VC
    CLN --> OBS
    CLN --> TMR
```

## Build Configuration

### iOS Targets

```mermaid
graph LR
    subgraph "iOS Build Targets"
        DEV[aarch64-ios<br/>Device]
        SIM[aarch64-ios-simulator<br/>M1 Simulator]
        SIMX[x86*64-ios-simulator<br/>Intel Simulator]
    end
```

### Android Targets

```mermaid
graph LR
    subgraph "Android Build Targets"
        ARM64[aarch64-linux-android<br/>arm64-v8a]
        ARM[armv7a-linux-androideabi<br/>armeabi-v7a]
        X64[x86*64-linux-android<br/>x86*64]
        X86[i686-linux-android<br/>x86]
    end
```

## Project Templates

### iOS Template Structure

```
MyApp/
├── MyApp.xcodeproj/
├── MyApp/
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift
│   ├── ViewController.swift
│   ├── Info.plist
│   └── Assets.xcassets/
├── Frameworks/
│   └── libcraft.a
└── web/
    └── index.html
```

### Android Template Structure

```
MyApp/
├── app/
│   ├── build.gradle
│   ├── src/main/
│   │   ├── java/com/myapp/
│   │   │   └── MainActivity.java
│   │   ├── jniLibs/
│   │   │   ├── arm64-v8a/
│   │   │   └── x86*64/
│   │   ├── res/
│   │   └── AndroidManifest.xml
│   └── src/main/assets/
│       └── web/
│           └── index.html
├── build.gradle
└── settings.gradle
```

## Further Reading

- [mobile.zig](../../packages/zig/src/mobile.zig) - Mobile implementation
- [PLATFORM*SUPPORT.md](../../packages/zig/PLATFORM*SUPPORT.md) - Platform feature matrix
- [ios*template.zig](../../packages/zig/src/ios*template.zig) - iOS project template
- [android*template.zig](../../packages/zig/src/android_template.zig) - Android project template

## Package-owned native shells

Applications author TypeScript and STX. Craft publishes its Swift shell templates
inside `craft-native` (`dist/ios/templates`) and `@craft-native/ios` (`templates`).
The iOS builder generates sources from typed `CraftConfig`; generated Swift is
build output, including the optional watch and live activity extensions.
Configure capabilities, appearance, tabs, storage sharing, privacy and deployment
targets through TypeScript. Add reusable native capabilities to Craft and expose
typed bridge methods instead of patching an application's generated Swift.

An Xcode Cloud application may retain its Xcode project, configuration, assets
and compiled STX bundle in Git for project discovery, while ignoring `*.swift`.
After installing the locked dependencies, its `ci_scripts/ci_post_clone.sh` can
restore sources without regenerating the project or compiling application screens:

```ts
import { restoreShell } from 'craft-native/ios'
restoreShell('storage/framework/mobile/ios')
```

`restoreShell` uses the project's `craft.config.json` and the installed package's
templates. Keep that configuration, Xcode metadata and package lockfile from the
same build; rebuild the complete project after changing capabilities or upgrading
Craft. Restoration replaces generated Swift; application edits there do not persist.

To make the zero-Swift rule enforceable in an app's own checks, use the source audit
from the same package. It ignores dependency/build output and the standard Stacks
generated tree, but fails on any Swift the application owns:

```ts
import { assertNoApplicationSwiftSources } from 'craft-native/ios'

assertNoApplicationSwiftSources(process.cwd())
```

The same check is available without custom TypeScript through
`craft-ios audit-sources --app-root .`; it exits non-zero and prints each
application-owned path for CI logs.

Projects that keep generated iOS output somewhere else can pass that path through
`ignoredPaths`. The audit returns relative paths from `findApplicationSwiftSources`
when a CI job needs to report them instead of throwing.

## Simulator tests from TypeScript

The Bun-only `craft-native/ios` entrypoint also exports the reusable XCUITest host:

```ts
import { initSimulatorDriver, serializeSimulatorSteps } from 'craft-native/ios'

initSimulatorDriver({
  output: 'storage/framework/mobile/ios-driver',
  bundleId: 'org.example.app',
  tabs: ['Today', 'Calendar'],
  controlUrl: 'http://127.0.0.1:3401',
})
const script = serializeSimulatorSteps([
  { command: 'launch' },
  { command: 'expect', text: 'Today', seconds: 10 },
  { command: 'net', state: 'offline' },
  { command: 'tab', text: 'Calendar' },
])
```

Generate its Xcode project with xcodegen, then `xcodebuild build-for-testing` and
`test-without-building` on an iOS 17+ simulator. Serve `script` at `/script` on the
control URL. The driver posts `/note` and `/save?name=…` evidence and supports the
existing line-based journey protocol; network and hook steps require the control
server to implement those endpoints. Override the control URL per run through
`TEST_RUNNER_CRAFT_TEST_CONTROL`. Failed checks fail XCTest while allowing the
remaining journey to collect evidence. This harness drives an already installed
app; it does not install the app or operate a network switch itself.

`createNativeMutationValidator()` compiles Craft's actual Foundation mutation
host with `swiftc` on macOS. Its `validate(messages)` returns `exitCode`, `stdout`
and `stderr`; call `dispose()` when finished. This checks native update batches,
not UIKit layout or device capability behavior. These build/test APIs are Bun-only;
browser code continues to import `craft-native/mobile`.

The notification cold-start probe resolves a hittable permission button, then
sends input through a SpringBoard coordinate so a disappearing alert does not
cause a stale-element tap failure. Every unresolved iteration waits for the
page's reply, including after input. The original 90-second permission budget
still applies, and only the page reporting `granted` passes; disappearance alone
does not. Permission race regressions run with `NotificationTapColdStartTests`
in both iOS runtime legs. Banner delivery and cold-start launch assertions are
separate and remain required.
