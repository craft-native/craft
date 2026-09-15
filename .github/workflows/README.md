# GitHub Actions

| Workflow | What it proves |
|---|---|
| [CI](./ci.yml) | Lint, typecheck, the Zig and TypeScript suites, and that the generated iOS, Watch, Live Activity and Android projects still **compile** |
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
ok   ios-shim — 4/4 cases, no zig
ok   ios-runtime — 4/4 cases, zig served clipboardRead, clipboardWrite, getCurrentPosition, getDeviceInfo, log
```

Android needs JDK 17, Gradle 8.11.1, an Android SDK with `platforms;android-36`
and `build-tools;36.0.0`, a booted emulator or attached device, and the Zig
Android libraries — it runs twice as well, once with `libcraft.so` packaged
into the APK and once without:

```bash
cd packages/zig && zig build build-android-all -Doptimize=ReleaseSafe && cd -
bun run test:mobile-e2e:android
```

```
ok   android-shim    — 4/4 cases, no zig
ok   android-runtime — 4/4 cases, zig served registered:59
```

Both write everything they saw — console logs, build logs, a screenshot, the
exact page that ran and a `report.json` — to
`artifacts/mobile-e2e/<label>/`, which is what CI uploads.

The cases themselves are in [`scripts/mobile-e2e/driver.html`](../../scripts/mobile-e2e/driver.html);
which of them are mandatory is in [`scripts/mobile-e2e/protocol.ts`](../../scripts/mobile-e2e/protocol.ts).
