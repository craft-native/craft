import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import process from 'node:process'

/**
 * What the AppKit host is built with. Pinned here, beside the Swift that needs
 * it, so an app never copies a lock file of its own: the Zig compiler (installed
 * by Pantry, which mirrors Zig dev builds) and the zig-js engine with the two
 * libraries it builds against (fetched at an exact revision).
 */
export const macosToolchain = {
  zig: '0.18.0-dev.252+86dc5ce25',
  sources: {
    'zig-js': { repository: 'zig-utils/zig-js', revision: 'f0072c95780712d1bb789280e08e7e390e83ab94', paths: ['src', 'include', 'tests', 'tools', 'docs', 'bench', 'conformance'] },
    'zig-regex': { repository: 'zig-utils/zig-regex', revision: 'fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b', paths: ['src'] },
    'zig-gc': { repository: 'zig-utils/zig-gc', revision: '0285ef801dd221a4ae8e88b31a09ae31627657a3', paths: ['src'] },
  },
} as const

export interface MacOSToolchain {
  zig: string
  zigJS: { source: string, library: string }
}

export type ToolchainRunner = (args: string[], cwd?: string) => Promise<{ exitCode: number, stdout: string, stderr?: string }>

export interface ResolveToolchainOptions {
  /** Where the compiler and sources are kept. Default: `$CRAFT_TOOLCHAIN_DIR`, else `~/.cache/craft/toolchain`. */
  cacheDir?: string
  env?: Record<string, string | undefined>
  run?: ToolchainRunner
  log?: (line: string) => void
}

const defaultRun: ToolchainRunner = async (args, cwd) => {
  const child = Bun.spawn(args, { cwd, stdout: 'pipe', stderr: 'pipe' })
  const [exitCode, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
  return { exitCode, stdout, stderr }
}

export function toolchainCacheDir(env: Record<string, string | undefined> = process.env): string {
  return env.CRAFT_TOOLCHAIN_DIR || join(env.XDG_CACHE_HOME || join(env.HOME || homedir(), '.cache'), 'craft', 'toolchain')
}

/** The Pantry executable: PANTRY_BIN, the project's own, the user's, else `pantry` on PATH. */
export function pantryExecutable(env: Record<string, string | undefined> = process.env, exists: (path: string) => boolean = existsSync): string {
  const home = env.HOME || homedir()
  return [env.PANTRY_BIN, join(process.cwd(), 'pantry/.bin/pantry'), join(home, '.local/bin/pantry')].find(path => path && exists(path)) ?? 'pantry'
}

/**
 * The pinned Zig compiler. `CRAFT_ZIG` wins when set (a deliberate override,
 * e.g. CI); otherwise Pantry installs exactly the pinned version into the
 * cache. Zig is never taken from PATH: the wrong snapshot builds nothing.
 */
export async function resolveZig(options: ResolveToolchainOptions = {}): Promise<string> {
  const env = options.env ?? process.env
  if (env.CRAFT_ZIG) return env.CRAFT_ZIG
  const cache = options.cacheDir ?? toolchainCacheDir(env)
  const zig = join(cache, 'pantry/ziglang.org', `v${macosToolchain.zig}`, 'bin/zig')
  if (existsSync(zig)) return zig
  const run = options.run ?? defaultRun
  mkdirSync(cache, { recursive: true })
  options.log?.(`Installing Zig ${macosToolchain.zig} with Pantry`)
  const result = await run([pantryExecutable(env), 'install', `ziglang.org@${macosToolchain.zig}`, '--no-save', '--ignore-scripts'], cache)
  if (result.exitCode !== 0 || !existsSync(zig)) throw new Error(`Pantry could not install ziglang.org@${macosToolchain.zig} into ${cache}: ${result.stderr?.trim().slice(-400) ?? ''}. Install Pantry (https://pantry.dev) or set CRAFT_ZIG.`)
  return zig
}

/** Fetch `name` at its pinned revision, as a sibling of the others (zig-js finds its libraries at ../zig-regex and ../zig-gc). */
async function fetchSource(name: keyof typeof macosToolchain.sources, cache: string, run: ToolchainRunner, log?: (line: string) => void): Promise<string> {
  const pin = macosToolchain.sources[name]
  const directory = join(cache, 'sources', name)
  const git = async (args: string[]): Promise<string> => {
    const result = await run(['git', ...args], directory)
    if (result.exitCode !== 0) throw new Error(`git ${args.join(' ')} failed in ${directory}: ${result.stderr?.trim() ?? ''}`)
    return result.stdout.trim()
  }
  mkdirSync(directory, { recursive: true })
  if (!existsSync(join(directory, '.git'))) {
    await git(['init', '--quiet'])
    await git(['remote', 'add', 'origin', `https://github.com/${pin.repository}.git`])
    await git(['sparse-checkout', 'set', ...pin.paths])
  }
  const head = await run(['git', 'rev-parse', 'HEAD'], directory)
  if (head.exitCode !== 0 || head.stdout.trim() !== pin.revision) {
    log?.(`Fetching ${name} ${pin.revision.slice(0, 8)}`)
    await git(['fetch', '--quiet', '--filter=blob:none', '--depth=1', 'origin', pin.revision])
    await git(['checkout', '--quiet', '--detach', 'FETCH_HEAD'])
  }
  return directory
}

/** Zig, the zig-js checkout at its pinned revision and its built static library; everything missing is fetched and built once. */
export async function resolveMacOSToolchain(options: ResolveToolchainOptions = {}): Promise<MacOSToolchain> {
  const env = options.env ?? process.env
  const run = options.run ?? defaultRun
  const cache = options.cacheDir ?? toolchainCacheDir(env)
  const zig = await resolveZig({ ...options, cacheDir: cache })
  const source = await fetchSource('zig-js', cache, run, options.log)
  await fetchSource('zig-regex', cache, run, options.log)
  await fetchSource('zig-gc', cache, run, options.log)
  const library = join(source, 'zig-out/lib/libzig-js.a')
  const stamp = join(source, 'zig-out/.craft-toolchain')
  const wanted = `${macosToolchain.zig}\n${macosToolchain.sources['zig-js'].revision}\n${macosToolchain.sources['zig-regex'].revision}\n${macosToolchain.sources['zig-gc'].revision}\n`
  if (!existsSync(library) || !existsSync(stamp) || readFileSync(stamp, 'utf8') !== wanted) {
    options.log?.('Building the zig-js engine')
    const result = await run([zig, 'build', 'home-tool-bootstrap', '-Doptimize=ReleaseFast'], source)
    if (result.exitCode !== 0 || !existsSync(library)) throw new Error(`zig-js did not build (${library}): ${result.stderr?.trim() ?? ''}`)
    writeFileSync(stamp, wanted)
  }
  return { zig, zigJS: { source, library } }
}
