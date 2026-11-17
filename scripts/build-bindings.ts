import { mkdir, rm } from 'node:fs/promises'
import { resolve } from 'node:path'

const root = process.cwd()
const pkg = await Bun.file(resolve(root, 'package.json')).json()
if (!['@craft-native/react', '@craft-native/vue', '@craft-native/svelte'].includes(pkg.name))
  throw new Error('Run the binding builder from a framework package')

const outdir = resolve(root, 'dist')
await rm(outdir, { recursive: true, force: true })
await mkdir(outdir, { recursive: true })
// Keep framework peers external: consumers supply their own React/Vue/Svelte.
// Bun builds the fixed entrypoint directly, without a glob-parser dependency.
for (const format of ['cjs', 'esm'] as const) {
  const result = await Bun.build({
    entrypoints: [resolve(root, 'src/index.ts')],
    outdir,
    naming: format === 'cjs' ? 'index.js' : 'index.mjs',
    target: 'browser',
    format,
    packages: 'external',
  })
  if (!result.success) throw new AggregateError(result.logs, `Cannot build ${pkg.name} ${format}`)
}
