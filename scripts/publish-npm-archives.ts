import { join, resolve } from 'node:path'
import { readArchiveManifest } from './scan-release-artifacts'

type Command = (args: string[]) => { exitCode: number | null, stdout: string, stderr: string }

const npmCommand: Command = args => {
  const result = Bun.spawnSync(['npm', ...args], { stdout: 'pipe', stderr: 'pipe' })
  return { exitCode: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString() }
}

export function publishNpmArchives(directory: string, command: Command = npmCommand, dryRun = false): void {
  const root = resolve(directory)
  const archives = readArchiveManifest(root)
  for (const archive of archives) {
    const path = join(root, archive.file)
    if (!dryRun) {
      const lookup = command(['view', `${archive.name}@${archive.version}`, 'version', '--json'])
      if (lookup.exitCode === 0) {
        if (JSON.parse(lookup.stdout) !== archive.version)
          throw new Error(`${archive.name}: npm returned an unexpected published version`)
        console.log(`${archive.name}@${archive.version} already published; skipping`)
        continue
      }
      if (!lookup.stderr.includes('E404'))
        throw new Error(`${archive.name}: npm version lookup failed: ${lookup.stderr}`)
    }
    // A failed or changed archive must never be published after the scan.
    readArchiveManifest(root)
    const args = ['publish', path, '--access', 'public', '--ignore-scripts', '--provenance']
    if (dryRun) args.push('--dry-run')
    const publish = command(args)
    if (publish.exitCode !== 0)
      throw new Error(`${archive.name}: npm publish failed: ${publish.stderr}`)
    console.log(`${dryRun ? 'Dry-run checked' : 'Published'} ${archive.name}@${archive.version}`)
  }
}

if (import.meta.main) {
  const directory = Bun.argv[2]
  if (!directory) throw new Error('Usage: publish-npm-archives.ts <archive-dir> [--dry-run]')
  publishNpmArchives(directory, npmCommand, Bun.argv.includes('--dry-run'))
}
