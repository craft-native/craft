import { existsSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

export function pinnedZigVersion(root: string): string {
  const lock = JSON.parse(readFileSync(join(root, 'pantry.lock'), 'utf8'))
  const version = lock.workspaces?.['']?.system?.['ziglang.org']
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+(?:-dev\.\d+[+_][a-f0-9]+)?$/.test(version))
    throw new Error('pantry.lock must contain an exact Zig version in the root workspace system dependencies')
  return version.replace('_', '+')
}

export function pinnedPantryZigPath(root: string, expected: string, env: NodeJS.ProcessEnv, hostPlatform: string): string | null {
  if (env.CRAFT_ZIG) return null
  const versions = [...new Set([expected.replace('+', '_'), expected])]
  const packageDirs = versions.flatMap(version => [
    join(root, 'pantry', 'ziglang.org', `v${version}`),
    join(root, 'pantry', 'ziglang-org', version),
  ])
  // The native installer uses domain/v<version>; the SDK uses the slug.
  // The official ZIP has zig.exe at its root; registry mirrors can use bin/.
  // Invoke the package binary with its adjacent standard library in either layout.
  for (const packageDir of packageDirs) {
    const candidates = hostPlatform === 'win32'
      ? [join(packageDir, 'zig.exe'), join(packageDir, 'bin', 'zig.exe')]
      : [join(packageDir, 'bin', 'zig'), join(packageDir, 'zig')]
    for (const installed of candidates) {
      if (existsSync(installed)) return installed
    }
  }
  return null
}

export function resolveZig(root: string, env: NodeJS.ProcessEnv = process.env, hostPlatform = process.platform): { path: string, version: string, overridden: boolean } {
  const expected = pinnedZigVersion(root)
  const executable = env.CRAFT_ZIG || 'zig'
  // Prefer the exact local package on every host. A global PATH may contain
  // another snapshot, and the Windows .bin shim also breaks stdlib discovery.
  const path = pinnedPantryZigPath(root, expected, env, hostPlatform) ?? Bun.which(executable, { PATH: env.PATH, cwd: root })
  const remedy = 'Activate the pinned Pantry toolchain, or set CRAFT_ZIG to its executable. To intentionally test a different snapshot, also set CRAFT_ALLOW_UNPINNED_ZIG=1.'
  if (!path)
    throw new Error(`Zig ${expected} was not found (${executable}). ${remedy}`)
  const result = Bun.spawnSync([path, 'version'], { cwd: root, env, stdout: 'pipe', stderr: 'pipe' })
  if (result.exitCode !== 0)
    throw new Error(`Cannot read Zig version from ${path}: ${result.stderr.toString().trim()}. ${remedy}`)
  const version = result.stdout.toString().trim()
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.+-]+)?$/.test(version))
    throw new Error(`Invalid Zig version from ${path}: ${JSON.stringify(version)}`)
  const overridden = version !== expected
  if (overridden && env.CRAFT_ALLOW_UNPINNED_ZIG !== '1')
    throw new Error(`Zig version mismatch: ${path} reports ${version}; pantry.lock requires ${expected}. ${remedy}`)
  return { path, version, overridden }
}

export function runZig(root: string, args: string[], env: NodeJS.ProcessEnv = process.env): number {
  const command = [...args]
  const core = command[0] === '--core'
  if (core) command.shift()
  const versioned = command[0] === '--versioned'
  if (versioned) command.shift()
  if (versioned) {
    const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
    command.push(`-Dversion=${version}`)
  }
  if (core && command[0] === 'build') {
    // Select the core project explicitly. A monorepo has another build.zig
    // at its root; compiler build discovery must not select that wrapper.
    command.splice(1, 0, '--build-file', join(root, 'packages/zig/build.zig'))
  }
  const zig = resolveZig(root, env)
  const cwd = core ? join(root, 'packages/zig') : root
  console.error(`Zig ${zig.version}: ${zig.path}${zig.overridden ? ' (explicit unpinned override)' : ''}`)
  console.error(`Zig project directory: ${cwd}`)
  const result = Bun.spawnSync([zig.path, ...command], {
    cwd,
    env,
    stdin: 'inherit',
    stdout: 'inherit',
    stderr: 'inherit',
  })
  return result.exitCode
}

if (import.meta.main) {
  try {
    process.exitCode = runZig(resolve(import.meta.dir, '..'), process.argv.slice(2))
  }
  catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
