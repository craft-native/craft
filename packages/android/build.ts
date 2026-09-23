/**
 * Build script for @craft-native/android
 */

import { rm } from 'node:fs/promises'

await rm('./dist', { recursive: true, force: true })

const result = await Bun.build({
  entrypoints: ['./src/index.ts'],
  outdir: './dist',
  target: 'bun',
  format: 'esm',
  minify: false,
  sourcemap: 'external',
})

if (!result.success)
  throw new AggregateError(result.logs, 'Android builder compilation failed')

// Use the locked compiler, as the SDK build does, rather than Pantry's PATH tsc.
await Bun.$`bun ../typescript/scripts/tsc.ts src/index.ts --declaration --emitDeclarationOnly --module esnext --target esnext --moduleResolution bundler --types bun --skipLibCheck --ignoreConfig --outDir dist`

console.log('✅ Build complete')
