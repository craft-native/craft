import { cp, mkdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import process from 'node:process'
import { assertZigJsEngine } from './engine.js'
import { resolveMacOSToolchain } from './toolchain.js'

export { assertZigJsEngine, systemEngineUse } from './engine.js'
export { macosToolchain, pantryExecutable, resolveMacOSToolchain, resolveZig, toolchainCacheDir } from './toolchain.js'
export type { MacOSToolchain } from './toolchain.js'

export interface MacOSNativeBuildOptions {
  outdir: string
  /** A compiled stx native route bundle, never HTML. */
  nativeBundle: string
  /** Defaults to the pinned compiler, installed by Pantry (see `resolveMacOSToolchain`). */
  zig?: string
  /** zig-js checkout and its public static archive. Default: the pinned revision, fetched and built once. No system JSC fallback. */
  zigJS?: { source: string, library: string }
  /** Where the toolchain is cached; default `~/.cache/craft/toolchain`. */
  toolchainDir?: string
  /**
   * Link WebKit so screens can show web pages in a `<WebView tab="...">` and drive
   * tabs through `craft.web` (a browser, a help viewer). Off by default: the host
   * then links no WebKit at all, and `WebView` reports itself unsupported.
   */
  webkit?: boolean
}

/** Compile Craft's AppKit host and the shared Zig layout core. No WebKit unless `webkit` is set. */
export async function buildMacOSNative(options: MacOSNativeBuildOptions): Promise<{ executable: string, bundle: string }> {
  if (process.platform !== 'darwin') throw new Error('The AppKit host must be built on macOS.')
  const outdir = resolve(options.outdir)
  const templates = join(import.meta.dir, '../templates')
  const sourceRoot = join(import.meta.dir, '../..')
  const layout = existsSync(join(sourceRoot, 'zig/src/native_layout.zig'))
    ? join(sourceRoot, 'zig/src/native_layout.zig') : join(templates, 'native_layout.zig')
  const mutation = existsSync(join(sourceRoot, 'ios/templates/CraftNativeMutation.swift'))
    ? join(sourceRoot, 'ios/templates/CraftNativeMutation.swift') : join(templates, 'CraftNativeMutation.swift')
  if (!existsSync(options.nativeBundle)) throw new Error(`Native STX bundle not found: ${options.nativeBundle}`)
  await mkdir(outdir, { recursive: true })
  async function run(args: string[]): Promise<void> {
    const child = Bun.spawn(args, { stdout: 'inherit', stderr: 'inherit' })
    if (await child.exited !== 0) throw new Error(`Native build failed: ${args[0]}`)
  }
  const toolchain = options.zig && options.zigJS ? undefined : await resolveMacOSToolchain({ cacheDir: options.toolchainDir, log: line => console.log(line) })
  const zig = options.zig || toolchain!.zig
  const layoutLibrary = join(outdir, 'libcraft-layout.a')
  await run([zig, 'build-lib', layout, '-O', 'ReleaseSafe', '-static', '-lc', `-femit-bin=${layoutLibrary}`])
  const executable = join(outdir, 'craft-native-macos')
  const engine = options.zigJS || toolchain!.zigJS
  if (!existsSync(engine.library)) throw new Error(`Build zig-js first: ${engine.library}`)
  if (!existsSync(join(engine.source, 'include/module.modulemap'))) throw new Error('zig-js must expose its owned ZigJS Swift module.')
  const bridge = join(outdir, 'zig-js-objc.o')
  const dispatch = join(outdir, 'zig-js-dispatch.o')
  const assembly = join(engine.source, `src/objc_abi_${process.arch === 'arm64' ? 'aarch64' : 'x86_64'}.S`)
  await run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-incomplete-implementation', '-I', join(engine.source, 'include'), '-include', join(engine.source, 'include/ZigJS.h'), '-c', join(engine.source, 'src/objc_bridge.m'), '-o', bridge])
  await run([zig, 'build-obj', join(engine.source, 'src/objc_abi_dispatch.zig'), assembly, '-O', 'ReleaseFast', `-femit-bin=${dispatch}`])
  const web = options.webkit ? ['-D', 'CRAFT_WEBKIT', '-framework', 'WebKit', join(templates, 'CraftMacWebView.swift')] : []
  await run(['swiftc', '-O', '-swift-version', '5', '-I', join(engine.source, 'include'), '-framework', 'Cocoa', '-framework', 'AVKit', '-framework', 'UserNotifications', ...web,
    join(templates, 'CraftMacRuntime.swift'), join(templates, 'CraftMacRenderer.swift'), join(templates, 'CraftMacApplication.swift'), mutation,
    bridge, dispatch, engine.library,
    '-Xlinker', '-force_load', '-Xlinker', layoutLibrary, '-Xlinker', '-export_dynamic', '-o', executable])
  await assertZigJsEngine(executable)
  const bundle = join(outdir, 'native-screen.js')
  if (resolve(options.nativeBundle) !== bundle) await cp(options.nativeBundle, bundle)
  return { executable, bundle }
}
