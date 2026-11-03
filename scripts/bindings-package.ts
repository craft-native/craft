import { createHash } from 'node:crypto'
import { readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { createTempDir } from '../packages/typescript/src/temp-dir'

export interface BindingArchive { name: string, version: string, path: string }
const root = resolve(import.meta.dir, '..')

async function execute(args: string[], cwd: string) {
  const child = Bun.spawn(args, { cwd, stdout: 'pipe', stderr: 'pipe' })
  const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
  return { code, output: stdout + stderr }
}

async function run(args: string[], cwd: string): Promise<void> {
  const result = await execute(args, cwd)
  if (result.code !== 0) throw new Error(`${args.join(' ')} failed in ${cwd}\n${result.output}`)
}

/** Normal package-manager resolution against unchanged, newly packed archives. */
export async function verifyBindingPackages(archives: BindingArchive[]): Promise<void> {
  const names = ['craft-native', '@craft-native/react', '@craft-native/svelte', '@craft-native/vue']
  const packages = new Map(names.map(name => {
    const archive = archives.find(item => item.name === name)
    if (!archive) throw new Error(`Missing binding acceptance archive: ${name}`)
    const manifest = Bun.spawnSync(['tar', '-xOzf', archive.path, 'package/package.json'], { stdout: 'pipe', stderr: 'pipe' })
    if (manifest.exitCode !== 0) throw new Error(`Cannot read ${name} archive`)
    const pkg = JSON.parse(manifest.stdout.toString())
    if (pkg.name !== name || pkg.version !== archive.version) throw new Error(`Unexpected archive identity for ${name}`)
    return [name, { archive, pkg }]
  }))
  // Standalone adapters must resolve their declared core dependency normally.
  // A loopback registry serves the candidate archives, not aliases, overrides,
  // extracted node_modules patches or workspace links. Public peers pass through.
  const server: ReturnType<typeof Bun.serve> = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(request): Promise<Response> {
      const url = new URL(request.url)
      const name = decodeURIComponent(url.pathname.slice(1))
      const entry = packages.get(name)
      if (entry) {
        const bytes = readFileSync(entry.archive.path)
        return Response.json({ name, 'dist-tags': { latest: entry.archive.version }, versions: {
          [entry.archive.version]: { ...entry.pkg, dist: {
            tarball: `${server.url}archives/${encodeURIComponent(name)}`,
            shasum: createHash('sha1').update(bytes).digest('hex'),
            integrity: `sha512-${createHash('sha512').update(bytes).digest('base64')}`,
          } },
        } })
      }
      if (name.startsWith('archives/')) {
        const archived = packages.get(name.slice('archives/'.length))
        return archived ? new Response(Bun.file(archived.archive.path)) : new Response('Missing archive', { status: 404 })
      }
      const upstream = await fetch(`https://registry.npmjs.org${url.pathname}${url.search}`)
      // fetch decompresses the body; do not forward its original gzip headers.
      return new Response(await upstream.arrayBuffer(), { status: upstream.status, headers: { 'Content-Type': upstream.headers.get('Content-Type') ?? 'application/json' } })
    },
  })
  try {
    for (const framework of ['react', 'svelte', 'vue']) {
      const name = `@craft-native/${framework}`
      const entry = packages.get(name)!
      for (const withCore of [true, false]) {
        const temp = createTempDir(`craft-${framework}-${withCore ? 'core' : 'standalone'}-`)
        try {
          const dependencies: Record<string, string> = { [name]: entry.archive.version, [framework]: entry.pkg.devDependencies[framework] }
          if (withCore) dependencies['craft-native'] = packages.get('craft-native')!.archive.version
          writeFileSync(join(temp, 'package.json'), JSON.stringify({
            name: 'binding-consumer', private: true, type: 'module', dependencies,
            devDependencies: { 'bun-types': '1.4.4', ...(framework === 'react' ? { '@types/react': entry.pkg.devDependencies['@types/react'] } : {}) },
          }))
          writeFileSync(join(temp, 'bunfig.toml'), `[install]\nregistry = ${JSON.stringify(server.url.href)}\n`)
          await run([process.execPath, 'install'], temp)
          await run([process.execPath, 'install', '--frozen-lockfile'], temp)
          const coreImport = withCore ? "import type { CraftBridgeAPI, CraftEventEmitter } from 'craft-native'\nconst globalBridge: (CraftBridgeAPI & CraftEventEmitter) | undefined = window.craft\nvoid globalBridge\n" : ''
          const bridge = framework === 'svelte'
            ? `import { craft } from '${name}'\ncraft.subscribe(api => { if (api) { const result: Promise<{ platform: string, version: string }> = api.getPlatform(); void result } })`
            : `import { useCraft } from '${name}'\nconst api = useCraft().craft${framework === 'vue' ? '.value' : ''}\nif (api) { const result: Promise<{ platform: string, version: string }> = api.getPlatform(); void result }`
          writeFileSync(join(temp, 'positive.ts'), `${coreImport}${bridge}\nconst haptic: Promise<boolean> | undefined = window.craft?.haptic?.('alignment'); void haptic\nwindow.craft?.on('window:resize', size => { const width: number = size.width; void width })\n`)
          const options = { strict: true, skipLibCheck: false, noEmit: true, target: 'ESNext', module: 'ESNext', moduleResolution: 'Bundler', lib: ['ESNext', 'DOM', 'DOM.Iterable'], types: ['bun-types'], paths: {} }
          writeFileSync(join(temp, 'tsconfig.json'), JSON.stringify({ compilerOptions: options, files: ['positive.ts'] }))
          const compiler = [process.execPath, join(root, 'packages/typescript/scripts/tsc.ts'), '-p', 'tsconfig.json', '--pretty', 'false']
          await run(compiler, temp)
          const invalidPlatform = framework === 'svelte'
            ? 'craft.subscribe(api => { if (api) { const result: Promise<number> = api.getPlatform(); void result } })'
            : `const result: Promise<number> = useCraft().craft${framework === 'vue' ? '.value' : ''}!.getPlatform(); void result`
          writeFileSync(join(temp, 'negative.ts'), `import { ${framework === 'svelte' ? 'craft' : 'useCraft'} } from '${name}'
window.craft?.haptic?.(123)
window.craft?.emit('window:resize', { width: 'invalid', height: 10 })
${invalidPlatform}
`)
          writeFileSync(join(temp, 'tsconfig.json'), JSON.stringify({ compilerOptions: options, files: ['negative.ts'] }))
          const negative = await execute(compiler, temp)
          const errors = [...negative.output.matchAll(/([^\n]+)\((\d+),\d+\): error TS(\d+):/g)]
          if (negative.code !== 2 || errors.length !== 3 || errors.some((error, index) => error[1] !== 'negative.ts' || Number(error[2]) !== index + 2 || error[3] !== ['2345', '2322', '2322'][index]))
            throw new Error(`${name} negative type contract changed:\n${negative.output}`)
          console.log(`Verified ${name} ${withCore ? 'with core' : 'standalone'}: normal/frozen install, strict positive and negative types.`)
        }
        finally { rmSync(temp, { recursive: true, force: true }) }
      }
    }
  }
  finally { server.stop(true) }
}

if (import.meta.main) {
  const temp = createTempDir('craft-binding-archives-')
  try {
    const archives: BindingArchive[] = []
    for (const folder of ['typescript', 'react', 'svelte', 'vue']) {
      const dir = join(root, 'packages', folder)
      await run([process.execPath, 'run', 'build'], dir)
      const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
      const path = join(temp, `${folder}.tgz`)
      await run([process.execPath, 'pm', 'pack', '--filename', path], dir)
      archives.push({ name: pkg.name, version: pkg.version, path })
    }
    await verifyBindingPackages(archives)
  }
  finally { rmSync(temp, { recursive: true, force: true }) }
}
