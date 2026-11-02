# Native Vulkan source consumer

This fixture consumes `craft.vulkan_surface` and `craft.graphics.scene` from an
unchanged archive of the package's declared source paths. The test-only C
transport calls the same public Zig methods available to native applications.
It does not duplicate the graphics implementation or use a web renderer.
The dependency selects `desktop-host = false`: the caller supplies its native
window, so the public module keeps SQLite and graphics dependencies while
omitting Craft's GTK/WebKit desktop host. The default profile still supplies
all normal window-host dependencies.

The Xlib host creates an owned window on an isolated X11 display. It presents
61 changing atlas/triangle/glyph frames, compares every GPU readback pixel with
the shared CPU scene, then compares every actual window pixel. It resizes,
unmaps and resumes with a fresh swapchain, receives real XTest pointer input,
and compares the corresponding scene mark. Captures contain only first-party
test colors. Two complete sessions must dispose successfully. A disposal timeout
retains the context and native window until process exit and fails acceptance.

Run on a Linux host with the pinned compiler, X11/XTest, Xvfb/Openbox and a
Vulkan1.1 driver supporting KHR or EXT swapchain maintenance:

```sh
bun scripts/test-vulkan-surface-linux.ts --output artifacts/native-vulkan-linux
```

The existing `zig-core` Linux job requires the native display test with the
Khronos validation layer enabled. It retains original logs, source/compiler and
executable identities, process disposal and four real PPM captures. Validation
errors, blank or stale frames, missing input, incomplete sessions and resource
ownership failures cannot pass. The runner bounds each command and cleans only
its unique generated consumer after its process groups have exited.

The public surface owns Vulkan resources; the caller owns the window and
serializes calls on the creating thread. Frames contain opaque 0xAARRGGBB
pixels. Upload/readback allocations have an explicit byte budget; swapchain
extent and image count are bounded separately. Resize errors leave presentation
unavailable when replacement cannot be created. Retry resize or dispose; do not
continue as though the old swapchain still exists. Timeout disposal retains all
resources until its pending acquisition, render and presentation fences finish.

The Win32 host uses the same public C transport and graphics implementation.
It creates real DPI-aware windows, captures their actually displayed client
rectangles from the desktop, resizes and hides/resumes them, then receives
native cursor/button input. It never repaints an expected frame into the window
or asks a synthetic print handler to produce a capture. Windows command trees
belong to a native Job Object before their primary threads start. Timeout,
cancellation, parent death and normal completion all require complete disposal.

The Windows CI job builds an unchanged, pinned Khronos Vulkan loader and Google
SwiftShader CPU ICD. The genuine loader is bundled beside the owned fixture;
`VK_DRIVER_FILES` explicitly selects the source-built ICD. This proves software
Vulkan presentation on Win32 and does not claim physical GPU acceleration.
Loader and driver are separate original build outputs; the ICD is never
renamed to impersonate the loader. Production accepts the normal system or
application-bundled Vulkan loader and does not search the current directory.

Each host is qualified by its actual retained native execution and original
source/release artifacts. Cross-compilation and ownership unit tests alone do
not establish successful native presentation.

The Android core adapter accepts an acquired `ANativeWindow` through
`NativeWindow.android` on 64-bit little-endian targets. It uses `libvulkan.so`
and `VK_KHR_android_surface`, not Xlib. The C transport's `window` argument is
that native pointer on Android (`display` is unused). The caller owns the
reference: a Java `Surface`/JNI object is not interchangeable with it. Serialize
creation, resize, presentation and disposal on the owning render thread; do not
release the window while a disposal timeout still retains Vulkan resources.
Like the desktop adapters, this requires Vulkan 1.1 and KHR/EXT surface and
swapchain maintenance. Unsupported drivers fail explicitly; no blank fallback
is reported as successful presentation.

Android swapchain dimensions use the requested pixel extent clamped to the
surface image bounds. Its `currentExtent` is a preferred consumer size and can
lag a real SurfaceView resize; it does not override valid requested dimensions.
Fixed desktop min/max image bounds still force the native desktop extent.

The authored Android Activity/JNI fixture lives in
`packages/android/fixtures/vulkan-surface`. It acquires the real SurfaceView's
ANativeWindow, serializes native calls on one render thread and drives
Choreographer frames, real native Button/pointer input, a View resize,
Home/background disposal, foreground surface recreation and two Activity
sessions. Every GPU readback pixel must match the shared scene. Five actual
Android compositor captures also require independent literal atlas, triangle,
glyph, changing-frame and touch-marker anchors. Blank or stale rendering
cannot qualify by matching a blank CPU oracle. Acceptance requires at least 370
frames, 4 native sessions, 2 pointer events and complete native/process disposal,
with unchanged 1000ms native waits and 61-frame/30-second stage deadlines.

Run with Java 17, Gradle 8.11.1, Android platform/build-tools 35, NDK 27.2.12479018,
the pinned compiler, SDK command-line tools and hardware CPU virtualization:

```sh
ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018" \
  bun packages/android/scripts/test-vulkan-surface.ts \
  --image 'system-images;android-35;google_apis;arm64-v8a' \
  --output artifacts/native-vulkan-android
```

Use `x86_64` instead of `arm64-v8a` on an x86 host. The maintained
`mobile-e2e.yml` Android Vulkan job runs the Google APIs 35 image on Linux x86
with a software Vulkan GPU and KVM CPU virtualization; the focused manual
scope is `android-vulkan`. A missing, failed or skipped selected native job
fails the workflow summary. It retains original APKs, native library/source
archive, every command/disposal result, compiler/NDK/Gradle/emulator/image
identities and all five PNGs. Failing native stages retain their original
JUnit/logcat/capture output before the owned emulator is disposed.

The local macOS arm64 matrix for [#435](https://github.com/craft-native/craft/issues/435)
used the identical consumed source and decompressed public archive:

| Android 35 image | Actual result |
| --- | --- |
| Google APIs revision 9 | Passed 370 frames, 4 native sessions, 2 native pointer events and 5 complete displayed captures. |
| Default revision 2 | Failed the original 61-frame/30-second initial stage at 31 frames; native presentation took about 984ms per frame. |

The [default-image gate](https://github.com/craft-native/craft/issues/437) remains
open. Its external-fence worker finishes promptly while its enclosing
Vulkan wait often returns near a full second later. This failed row remains
unqualified; no polling, resize retry, shorter scene or larger budget hides it.
The local passing row establishes software-emulator execution only. Linux CI,
physical GPUs/devices, failure-path coverage and verified publication/adoption
retain their own evidence requirements. This fixture does not establish full
native game rendering or Gold Edition fidelity.
