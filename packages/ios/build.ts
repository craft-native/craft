import { rm } from 'node:fs/promises'
import { $ } from 'bun'

await rm('./dist', { recursive: true, force: true })

// Build TypeScript
await $`bun build src/index.ts --outdir dist --target bun`
await $`bun build src/cli.ts --outdir dist --target bun`
// The standalone package advertises this declaration independently of the SDK.
await $`bun ../typescript/scripts/tsc.ts src/index.ts --declaration --emitDeclarationOnly --module esnext --target esnext --moduleResolution bundler --types bun --skipLibCheck --ignoreConfig --outDir dist`

// Make CLI executable
await $`chmod +x dist/cli.js`

console.log('✅ Build complete')
