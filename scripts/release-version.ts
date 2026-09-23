import { appendFileSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

export function validateReleaseVersion(ref: string, version: string, manifests: Record<string, unknown>): void {
  const errors: string[] = []
  const identifier = '(?:0|[1-9]\\d*|[\\da-z-]*[a-z-][\\da-z-]*)'
  const semver = new RegExp(`^(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(?:-${identifier}(?:\\.${identifier})*)?(?:\\+[\\da-z-]+(?:\\.[\\da-z-]+)*)?$`, 'i')
  if (!semver.test(version))
    errors.push(`package.json: invalid release version ${JSON.stringify(version)}`)
  if (!ref.startsWith('refs/tags/'))
    errors.push(`Release requires a tag ref; received ${JSON.stringify(ref)}`)
  else if (ref !== `refs/tags/v${version}`)
    errors.push(`Tag ${ref.slice('refs/tags/'.length)} must equal v${version}`)
  for (const [path, value] of Object.entries(manifests)) {
    if (value !== version)
      errors.push(`${path}: expected ${version}, received ${JSON.stringify(value)}`)
  }
  if (errors.length > 0)
    throw new Error(`Release version validation failed:\n${errors.join('\n')}`)
}

export function checkReleaseVersion(root: string, ref: string): string {
  const canonical = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).version
  const versions: Record<string, unknown> = {}
  for (const path of new Bun.Glob('packages/*/package.json').scanSync({ cwd: root })) {
    const pkg = JSON.parse(readFileSync(join(root, path), 'utf8'))
    if (!pkg.private) versions[path] = pkg.version
  }
  const zigPath = 'packages/zig/build.zig.zon'
  versions[zigPath] = readFileSync(join(root, zigPath), 'utf8').match(/\.version\s*=\s*"([^"]+)"/)?.[1]
  const pantryPath = 'packages/zig/pantry.json'
  versions[pantryPath] = JSON.parse(readFileSync(join(root, pantryPath), 'utf8')).version
  validateReleaseVersion(ref, canonical, versions)
  return canonical
}

if (import.meta.main) {
  const version = checkReleaseVersion(resolve(import.meta.dir, '..'), process.env.GITHUB_REF ?? '')
  console.log(`Verified release v${version}`)
  if (process.env.GITHUB_OUTPUT)
    appendFileSync(process.env.GITHUB_OUTPUT, `version=${version}\n`)
}
