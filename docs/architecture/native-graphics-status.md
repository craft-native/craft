# Standalone native graphics status

The standalone Zig graphics interfaces are distinct from Craft's WebView
rendering and the maintained UIKit/Android UI hosts. A detected Metal or Vulkan
device does not establish that these interfaces have a draw backend.

## Executed behavior

| Interface | Supported behavior | Evidence |
| --- | --- | --- |
| `renderer.Canvas` | CPU pixel storage, clear, basic shapes, and unscaled RGBA8 atlas compositing | `test:renderer` checks actual pixels |
| `gpu.RenderPipeline` | Offscreen target selection and clear | `test:gpu` reads the resulting RGBA8 pixels |
| Offscreen target construction | Allocation failure cleanup | `test:gpu` fails every allocation in turn and checks for leaks |
| Native drawing and presentation | Not provided by the standalone GPU pipeline | Capability flags are false and unsupported operations return errors |
| Shader compilation | No compiler backend connected | `Shader.compile` returns `ShaderCompilationUnavailable`; readiness remains false |
| Canvas text | No font renderer connected | `Canvas.drawText` returns `TextRenderingUnavailable` |

`GPU.getRenderingCapabilities()` describes implemented rendering operations.
`GPU.detectBackend()` and `GPU.isAccelerationAvailable()` describe hardware
discovery; callers must not use them as substitutes for rendering capabilities.

## Vulkan API boundary

`src/vulkan_api.zig` is a private 64-bit API boundary derived from Khronos
Vulkan-Headers `vulkan-sdk-1.4.363.0`, commit
`6802bb4733b63ed5efd3adb308a6c885ef180ea1`. It does not yet provide a loader,
swapchain, native surface or presentation capability.

`zig build test:vulkan-abi -Dvulkan-headers=/absolute/path/to/Vulkan-Headers/include`
compiles an independent C++ probe against those actual headers. It compares
sizes, alignment, every structure field offset, nested scalar and array
representations, numeric constants and 54 function signatures. A callback with ten
arguments also crosses from C++ into Zig using the SDK's function pointer type.
CI is configured to execute this check on Linux, macOS and Windows. Linux uses real
Xlib headers; Windows uses its actual Windows header declarations. Android
surface declarations are checked, but this is not Android device execution.

The local arm64 macOS probe has executed successfully. Win64 cross-compilation
also passed; hosted native platform results remain separate evidence. Negative
controls with a wrong field size and a floating-point timeout parameter both
failed the ABI check. These checks do not establish Vulkan frame presentation.

## Atlas compositing

`Canvas.drawBitmap` accepts a caller-owned, tightly packed, straight-alpha RGBA8
bitmap, a source rectangle, and an unscaled destination point. It validates the
entire bitmap and source rectangle before writing. Destination clipping retains
the corresponding source coordinates. Source-over compositing accounts for both
source and destination alpha, including transparent destinations.

The canvas does not retain the bitmap. Its source bytes must remain immutable
and must not overlap destination pixel storage during the call. Scaling, tint,
textured triangles, font shaping, batching, and native surface presentation are
separate capabilities; this operation does not claim them.

## Error handling

Hardware canvas operations, mesh drawing, pipeline draw/indexed-draw commands,
and compute dispatch return `UnsupportedOperation` until a real backend exists.
`CanvasAccelerator` operations and `Canvas.drawText` previously returned `void`;
callers now handle their error unions. `Button.render` and `Label.render`
propagate unavailable text errors rather than silently omitting their labels.

A pipeline clear without a target returns `MissingRenderTarget`; selecting an
unready shader returns `ShaderNotReady`. Failed commands do not increase success
statistics. A failed deferred flush discards its remaining queue so retrying a
corrected batch cannot inadvertently replay an already executed prefix.

## Verification

Use the exact Zig version pinned in `pantry.lock`:

```sh
CRAFT_ZIG=/absolute/path/to/pinned/zig bun scripts/zig.ts --core build test:gpu test:renderer
```

These tests prove offscreen operations and error behavior. A future native
game-surface claim additionally requires presented pixels, actual input,
resize/display-scale behavior, lifecycle recovery, and resource teardown on each
claimed host. Source compilation, successful counters, or a blank window do not
provide that evidence.

## Documented package entrypoint

The exported Zig `craft` module now owns its selected target's native link
dependencies and exports `graphics`, `renderer` and `gpu`. The internal module
remains target-inheriting because native fixtures reuse it for distinct cross
compilation targets. A separate application under
`packages/zig/test/fixtures/graphics-package-consumer` uses only the documented
`b.dependency(...).module("craft")` API. It verifies exact bitmap pixels, a
shared translucent terrain edge without gaps or double blending, transformed
sprites, UTF-8/newline atlas glyphs and complete-frame atomic rejection. It
also checks one Canvas type and explicit unavailable shader/font-family text
errors, without consumer linker flags. The expanded scene fixture passed
native macOS Debug and ReleaseSafe execution and Windows GNU cross compilation
locally. Hosted execution is required independently on each matrix host. This source
check does not qualify a published Zig archive or native game presentation.
Run `bun scripts/verify-zig-package-consumer.ts` with the pinned `CRAFT_ZIG`
to build the fixture from an unchanged archive of the manifest's declared
package paths, with fresh dependency caches and no sibling checkouts.
