# Android checkpoint interruption

This fixture tests the public native-screen `craft.snapshots.get/set` contract
against the unchanged generated Android checkpoint backend. Android's selected
WebView provider supplies JavaScriptSandbox as the script engine. The displayed
UI consists of native Android controls; the runner rejects a WebView hierarchy.
The hybrid-page SDK snapshot helper's boolean message handoff is not a durable
completion acknowledgement and is not used here.

Run from the Craft source root on macOS arm64 or Linux x86_64:

```sh
ANDROID_HOME=/absolute/android-sdk \
ANDROID_NDK_HOME=/absolute/android-sdk/ndk/27.2.12479018 \
bun packages/android/scripts/test-checkpoint-interruption.ts --output artifacts/android-checkpoints
```

Provide Bun, JDK 17, Gradle 8.11.1, SDK platform/build-tools 36.0.0, NDK
27.2.12479018 (clang 18), and absolute SDK/AVD manager executables on PATH.
The public emulator helper provisions a disposable API 35 Play image matching
the host ABI. Hardware CPU virtualization, a functioning stock provider and
enough temporary disk space are required. Missing capabilities fail the run;
there is no alternate image, provider installation, software CPU fallback or
acknowledged-save substitute. Do not select a shared AVD.

The runner uses fixed bounds: 300 seconds for native compilation, 600 seconds
for emulator boot, 30 seconds for each public UI expectation, ten seconds for
the rename boundary, and ten seconds for ordinary commands. APK installation
and the tiny interposer compilation each retain a 30-second command bound.
Activity intent acknowledgement keeps the ten-second command bound. Each
launch, its owned native UI readiness and its single-process identity share
one thirty-second public UI deadline. The runner does not use `am start -W`
to hide the native draw wait inside the shorter transport deadline. Every
launch records its elapsed time and the observed UI hash; the checkpoint,
negative-control and process/session requirements remain the same.
The emulator helper also bounds its SDK provisioning and cleanup commands.

The authored debug Gradle overlay adds `wrap.sh` and an NDK-built interposer
only to the disposable debug APK. It changes no generated Kotlin. The runner
compares the generated snapshot writer and shell with their templates after
normal package substitution, and checks those bytes remain unchanged after
compilation. The preload observes libc `rename` from the real atomic
`Files.move`, restricts itself to the fixture's exact armed checkpoint, records
the process/thread and paths, and holds only the worker thread.

The required sequence is:

1. Save generation 1 through public JS and await its acknowledgement.
2. Run pass-through mode. Require a valid worker rename record which fails the
   held-mode predicate, acknowledge generation 2, stop the process and recover
   its complete payload in a new process/session.
3. Save and acknowledge generation 1 again. Hold generation 2 immediately
   before rename; independently compare every staged and destination byte with
   the specified 256-KiB payloads. Require generation 2 to remain pending while
   native UI input increments a visible pulse counter.
4. Force-stop, confirm the process is absent, then relaunch. The public API and
   disk must recover the complete generation 1 in a new process/session.
5. Acknowledge generation 3 and require complete recovery after another restart.

Each invocation retains an independent `run-*` directory containing the original
command logs, APK, native screenshots, generated backend sources, authored inputs,
emulator logs and JSON receipt. The receipt records source/lock hashes, compiler
driver and actual executable, host tools, SDK/image/provider identities, whole
payload hashes, process/session identities, artifact sizes/SHA256 and cleanup.
Successful or failed evidence is sealed read-only after owned processes stop.
Cancellation and failures dispose owned command groups, app, emulator and
workspace; an unconfirmed disposal retains the workspace and fails acceptance.
Runner regressions use real subprocess failures/cancellation, not storage mocks.

The required Mobile E2E job runs on main, pull requests, full releases and the
`android` scope. Select `android-checkpoints` to run just this fixture plus the
harness checks. Its original artifacts are uploaded even on failure. The Linux
x86_64 stock Play image must actually pass hosted execution before its acceptance
can be claimed; a local arm64 pass does not qualify it.

This is the bounded child #440 of #396. It does not establish every interruption
point, OS eviction, power-loss durability, native game behavior or the complete
ordering/background/quota/cancellation matrix. Already-admitted writes can still
commit after screen disposal; rejected completion does not imply rollback.

A cold activity can acknowledge its intent before Android exposes an accessibility
root. The UI observer treats only the tool's explicit null-root result as no
observation and continues inside that same thirty-second phase. Each valid dump
uses a fresh owned path and must contain a complete XML hierarchy; transport
errors, unknown dump output and late observations fail. No previous dump can
stand in for the current surface.
