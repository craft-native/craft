# GitHub Actions

| Workflow | What it proves |
|---|---|
| [CI](./ci.yml) | Lint, typecheck, the Zig and TypeScript suites, and that the generated iOS, Watch, Live Activity and Android projects still **compile**; that a Watch-enabled iOS app **installs** on a simulator; and that release builds sign the production APNs environment |
| [Mobile E2E Testing](./mobile-e2e.yml) | That a generated app **runs**: a call from JavaScript reaches native code and comes back, on a real simulator and a real emulator |
| [Native Package Lifecycle](./native-lifecycle.yml) | Install, update, rollback and uninstall of the packaged app on macOS, Linux and Windows |
| [Benchmark](./benchmarks.yml) | Startup and runtime numbers, tracked over time |
| [Binary Size](./binary-size.yml) | The shipped binary has not grown unexpectedly |
| [SBOM](./sbom.yml) | A software bill of materials for each build |
| [Release](./release.yml) | Tagging, changelog, pantry publish and npm publish |

## Running the mobile E2E locally

The harness generates an app, drops a self-driving page into its web assets,
builds it, installs it on a device and reads the page's report back off the
console. It asserts a required list of cases per platform — at least one
success path and one rejection path — and nothing in it skips: a missing
toolchain or an app that printed nothing is a failure with a named cause.

iOS needs Xcode, `xcodegen` (`brew install xcodegen`), and the Zig archives,
because the suite runs twice — once with the Zig runtime linked and once
without. `build-ios-all` rather than `build-ios-simulator`: the generated
project links a device slice too, and project generation refuses a runtime
directory that has none.

```bash
cd packages/zig && zig build build-ios-all -Doptimize=ReleaseSafe && cd -
bun run test:mobile-e2e:ios
```

```
ok   ios-shim — 12/12 cases, no zig
ok   ios-runtime — 12/12 cases, zig served checkPermission, clearWatch, clipboardRead, clipboardWrite, getCurrentPosition, getDeviceInfo, haptic, log, requestPermission, share, startListening, stopListening, vibrate, watchPosition
```

After the suite, each leg cold-starts the app through a link twice, from an
XCUITest (`scripts/mobile-e2e/ios-uitests`). Only a UI test can answer the
"Open in …?" prompt iOS shows for a custom scheme, and read the page back from
an app SpringBoard launched, since that app has no console. One page only
subscribes to `onLink`, seconds late, and must be handed the launch link once.
The other also calls `getInitialURL`, and must not get the link twice.

Before launch the harness grants the app location permission with
`simctl privacy` and puts the simulator at a fixed coordinate with
`simctl location`. The page must report that coordinate back from
`getCurrentPosition`. On the runtime leg, Zig must also serve every action
under test itself: its log names each action it hands back to Swift, and only
`requestPermission`, whose location answer Swift owns, may appear there.

Android needs JDK 17, Gradle 8.11.1, an Android SDK with `platforms;android-36`
and `build-tools;36.0.0`, a booted emulator or attached device, and the Zig
Android libraries — it runs twice as well, once with `libcraft.so` packaged
into the APK and once without:

The Zig Android library links bionic, so building it needs the NDK —
`sdkmanager --install "ndk;26.1.10909125"`. Without it `build-android` refuses
rather than producing a library that installs and then fails to load. The NDK's
`llvm-objcopy` also strips each release library's DWARF into
`zig-out/android-symbols/`, and the suite refuses to start on a `libcraft.so`
that still carries any.

```bash
cd packages/zig && zig build build-android-all -Doptimize=ReleaseSafe -Dandroid-ndk="$ANDROID_NDK_HOME" && cd -
bun run test:mobile-e2e:android
```

```
ok   android-shim    — 7/7 cases, no zig
ok   android-runtime — 7/7 cases, zig served registered:103, declines:0
```

One Android case needs a person: `share.dismissed.resolvesFalse` opens the
real share menu and expects `false` once it is dismissed. The harness plays
that part. It waits until `dumpsys window` shows the chooser holding input
focus, saves `share-menu.png`, presses Back, and fails the run if the page asked
for a dismissal and no menu ever appeared.

After the suite, each leg also cold-starts the app through a link twice, the
same two ways as iOS, with `adb shell am start -W -a android.intent.action.VIEW
-d '<link>' <package>`. Naming the package rather than the activity means the
link is resolved through the generated manifest's intent filter, and `-W` must
report `LaunchState: COLD`, so a link delivered to an app that was still
running cannot pass for one that launched it. The page writes its report to
logcat, and each launch keeps its own `deeplink-<mode>-logcat.txt`.

The runtime leg fails on any line where a Zig native gave up — "fell through
to the shim", "failed with no fallback" or "could not reach the page" — because
Kotlin answering in its place is invisible to the page, and a runtime that has
loaded but is not answering would otherwise pass.

Both write everything they saw — console logs, build logs, a screenshot, the
exact page that ran and a `report.json` — to
`artifacts/mobile-e2e/<label>/`, which is what CI uploads.

The cases themselves are in [`scripts/mobile-e2e/driver.html`](../../scripts/mobile-e2e/driver.html);
which of them are mandatory is in [`scripts/mobile-e2e/protocol.ts`](../../scripts/mobile-e2e/protocol.ts).
