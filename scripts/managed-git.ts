import { appendFileSync, realpathSync } from 'node:fs'
import { isAbsolute, relative, resolve, sep, toNamespacedPath } from 'node:path'

/** A sibling prefix or another Windows drive is never a managed provider. */
export function insideManagedRoot(root: string, provider: string, paths = { relative, isAbsolute, sep, toNamespacedPath }): boolean {
  if (!paths.isAbsolute(root) || !paths.isAbsolute(provider)) return false
  const location = paths.relative(paths.toNamespacedPath(root), paths.toNamespacedPath(provider))
  return location !== '' && !paths.isAbsolute(location) && location !== '..' && !location.startsWith(`..${paths.sep}`)
}

/** Git Bash may prepend its own Git; select only the declared toolchain bin. */
export function verifyManagedGit(cwd = process.cwd()): { executable: string, provider: string, version: string } {
  const root = realpathSync(resolve(cwd, 'pantry'))
  const found = Bun.which('git', { PATH: resolve(root, '.bin') })
  if (!found) throw new Error('The declared Git executable is missing')
  const provider = realpathSync(found)
  if (!insideManagedRoot(root, provider)) throw new Error(`Git must resolve inside the declared Pantry toolchain: ${JSON.stringify({ root, provider })}`)
  const version = process.platform === 'win32' ? 'git version 2.53.0.windows.1' : 'git version 2.56.0'
  const result = Bun.spawnSync([provider, '--version'], { stdout: 'pipe', stderr: 'pipe' })
  if (result.exitCode !== 0 || result.stdout.toString().trim() !== version) throw new Error('The declared Git version did not execute')
  return { executable: provider, provider, version }
}

if (import.meta.main) {
  const identity = verifyManagedGit()
  const args = process.argv.slice(2)
  if (args.length === 0 || args[0] === '--verify') {
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `executable=${identity.executable.replaceAll('\\', '/')}\n`)
    console.log(JSON.stringify(identity))
  }
  else process.exit(Bun.spawnSync([identity.executable, ...args], { stdout: 'inherit', stderr: 'inherit' }).exitCode)
}
