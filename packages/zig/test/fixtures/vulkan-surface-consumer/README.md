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

This source change is under development. Local ownership tests and cross
compilation do not prove Linux native execution. Actual retained window output
and complete source/release acceptance are required before publication claims.
The Win32 adapter and its native acceptance are under development; cross
compilation alone does not prove Windows execution.

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

Android is **not execution-qualified** by this fixture yet. An Android activity,
surface-recreation/input lifecycle harness, NDK build, actual displayed-frame
captures and emulator/device CI remain required for #393. Host-side driver-call
tests and Android cross-compilation establish only adapter routing and ABI
coverage, not successful native Android presentation or lifecycle acceptance.
The fixture does not establish full native game rendering or Gold Edition fidelity.
