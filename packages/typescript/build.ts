import { cp, mkdir, rm } from 'node:fs/promises'
import { resolve } from 'node:path'

const root = import.meta.dir
const dist = resolve(root, 'dist')

await rm(dist, { recursive: true, force: true })
await mkdir(dist, { recursive: true })

async function build(entrypoints: string[], outdir: string): Promise<void> {
  const result = await Bun.build({
    entrypoints: entrypoints.map(entry => resolve(root, entry)),
    outdir: resolve(root, outdir),
    target: 'bun',
    format: 'esm',
    sourcemap: 'none',
  })
  if (!result.success) {
    for (const log of result.logs) console.error(log)
    throw new Error(`Failed to build ${entrypoints.join(', ')}`)
  }
}

// Mobile builders are private workspace packages, so the public CLI carries
// their implementation and templates instead of importing unpublished peers.
await build(['../ios/src/index.ts'], 'dist/ios/src')
await build(['../android/src/index.ts'], 'dist/android/src')
await build(['../macos/src/index.ts'], 'dist/macos/src')
// scripts/tsc.ts, not `bunx tsc`: PATH is not trustworthy in CI. See that file.
await Bun.$`bun ${resolve(root, "scripts/tsc.ts")} ${resolve(root, '../ios/src/index.ts')} --declaration --emitDeclarationOnly --module esnext --target esnext --moduleResolution bundler --types bun --skipLibCheck --ignoreConfig --rootDir ${resolve(root, '..')} --outDir ${dist}`
await Bun.$`bun ${resolve(root, "scripts/tsc.ts")} ${resolve(root, '../android/src/index.ts')} --declaration --emitDeclarationOnly --module esnext --target esnext --moduleResolution bundler --types bun --skipLibCheck --ignoreConfig --rootDir ${resolve(root, '..')} --outDir ${dist}`
await cp(resolve(root, '../ios/templates'), resolve(dist, 'ios/templates'), { recursive: true })
await cp(resolve(root, '../android/templates'), resolve(dist, 'android/templates'), { recursive: true })
await Bun.$`bun ${resolve(root, "scripts/tsc.ts")} ${resolve(root, '../macos/src/index.ts')} --declaration --emitDeclarationOnly --module esnext --target esnext --moduleResolution bundler --types bun --skipLibCheck --ignoreConfig --outDir ${resolve(dist, 'macos/src')}`
await cp(resolve(root, '../macos/templates'), resolve(dist, 'macos/templates'), { recursive: true })
await cp(resolve(root, '../zig/src/native_layout.zig'), resolve(dist, 'macos/templates/native_layout.zig'))
await cp(resolve(root, '../ios/templates/CraftNativeMutation.swift'), resolve(dist, 'macos/templates/CraftNativeMutation.swift'))

// Project templates are runtime data used by `craft-sdk init`.
await cp(resolve(root, '../../templates/projects'), resolve(dist, 'templates/projects'), { recursive: true })
await cp(resolve(root, 'fixtures/media-cache'), resolve(dist, 'testing/media-cache'), { recursive: true })

await build(['src/index.ts'], 'dist')
await build(['src/mobile-testing.ts'], 'dist')
await Bun.$`bun ${resolve(root, "scripts/tsc.ts")} ${resolve(root, 'src/mobile-testing.ts')} --declaration --emitDeclarationOnly --module esnext --target esnext --moduleResolution bundler --types bun --skipLibCheck --ignoreConfig --outDir ${dist}`
const mobileResult = await Bun.build({
  entrypoints: [resolve(root, 'src/mobile.ts'), resolve(root, 'src/browser.ts')],
  outdir: dist,
  target: 'browser',
  format: 'esm',
  sourcemap: 'none',
})
if (!mobileResult.success) {
  for (const log of mobileResult.logs) console.error(log)
  throw new Error('Failed to build browser-safe mobile SDK')
}
await Bun.$`bun build ${resolve(root, 'src/index.ts')} --outfile ${resolve(dist, 'index.cjs')} --format cjs --target node`
await Bun.$`bun build ${resolve(root, 'bin/cli.ts')} --outfile ${resolve(dist, 'cli.js')} --format esm --target bun`
await Bun.$`chmod +x ${resolve(dist, 'cli.js')}`
