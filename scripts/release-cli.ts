type ReleaseMode = 'prompt' | 'patch' | 'version'
type Execute = (args: string[]) => Promise<void>

export function bumpxReleaseCommand(mode: ReleaseMode, args: string[]): string[] {
  return [process.execPath, 'x', '--bun', '@stacksjs/bumpx', ...(mode === 'version' ? [] : [mode]),
    '--recursive', '--commit', '--tag', '--push', ...(mode === 'patch' ? ['--yes'] : []), '--no-changelog',
    '--execute', 'bun scripts/release-version.ts --pending && bun scripts/generate-release-changelog.ts && git add CHANGELOG.md',
    ...args]
}

const execute: Execute = async args => {
  const child = Bun.spawn(args, { stdin: 'inherit', stdout: 'inherit', stderr: 'inherit' })
  if (await child.exited !== 0) throw new Error(`Release stopped at ${args[1]}; no later release step was run`)
}

/** Keep Bun's forwarded arguments on Bumpx, never on the completion watcher. */
export async function runRelease(mode: ReleaseMode, args: string[], run: Execute = execute): Promise<void> {
  await run([process.execPath, 'scripts/release-version.ts', '--preflight'])
  await run(bumpxReleaseCommand(mode, args))
  const localOnly = ['--dry-run', '--no-commit', '--no-tag', '--no-push', '--help', '-h', '--version', '-v']
  if (args.some(arg => localOnly.includes(arg))) {
    console.log('No publication wait requested; Bumpx completed with preview or local-only options.')
    return
  }
  await run([process.execPath, 'scripts/release-complete.ts'])
}

if (import.meta.main) {
  const [mode, ...args] = Bun.argv.slice(2)
  if (mode !== 'prompt' && mode !== 'patch' && mode !== 'version')
    throw new Error('Use release, release:patch or release:version [version]')
  await runRelease(mode, args)
}
