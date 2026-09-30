import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { previewChangelog } from './changelog-preview'

const header = '# Changelog\n\n'

function previousTag(cwd: string): string {
  const result = Bun.spawnSync(['git', 'describe', '--tags', '--abbrev=0'], { cwd, stdout: 'pipe', stderr: 'pipe' })
  if (result.exitCode !== 0)
    throw new Error(`Cannot find the previous release tag: ${result.stderr.toString().trim()}`)
  return result.stdout.toString().trim()
}

/** Generate the next release section before bumpx commits and tags it. */
export function generateReleaseChangelog(cwd: string): string {
  const version = JSON.parse(readFileSync(join(cwd, 'package.json'), 'utf8')).version
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(version))
    throw new Error('The root package must have a valid release version')

  const from = previousTag(cwd)
  const to = `v${version}`
  if (from === to)
    throw new Error(`Release ${to} is already tagged`)

  const preview = previewChangelog(cwd, from)
  if (!preview.startsWith(header))
    throw new Error('Generated changelog has an unexpected header')

  const compare = preview.match(/^\[Compare changes\]\((https?:\/\/[^)]+\/compare\/)[^)]+\)$/m)
  if (!compare)
    throw new Error('Generated changelog has no compare link')

  const changelogPath = join(cwd, 'CHANGELOG.md')
  const existing = readFileSync(changelogPath, 'utf8')
  if (!existing.startsWith(header))
    throw new Error('Existing changelog has an unexpected header')
  if (existing.includes(`${compare[1]}${from}...${to})`))
    throw new Error(`Release ${to} is already in the changelog`)

  const section = preview.slice(header.length).replace(compare[0], `[Compare changes](${compare[1]}${from}...${to})`).trim()
  const content = `${header}${section}\n\n${existing.slice(header.length).trimStart()}`
  writeFileSync(changelogPath, content)
  return content
}

if (import.meta.main)
  generateReleaseChangelog(process.cwd())
