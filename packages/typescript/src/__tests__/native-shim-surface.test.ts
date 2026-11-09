/**
 * Every member the native-screen shims install on `craft.*` is declared.
 *
 * `craft.d.ts` types the injected global, and the shells install that global
 * from JavaScript embedded in `CraftNativeScreen.swift` and
 * `CraftNativeShell.kt.template`. Nothing connected the two, so six members
 * shipped with no declaration at all — the synchronous `storage` pair, the
 * synchronous `secureStorage` read, and the whole `snapshots` group a screen
 * uses to read its checkpoint before its first frame.
 *
 * That is how one checkpoint key came to be gated by four separate copies of
 * the same name rule: an undeclared API has no single place to describe it,
 * so each layer wrote its own.
 */
import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const sdk = resolve(import.meta.dir, '../..')
const host = (path: string) => readFileSync(resolve(sdk, '..', path), 'utf8')

/**
 * Members installed on the global and deliberately left undeclared, each with
 * the issue that tracks it. Empty, and meant to stay that way.
 *
 * `navigation.setOptions` was the last entry: typing it meant typing all
 * sixteen options it reads, which #493 did once the two hosts finally agreed
 * on what those options are. The checks below mean an entry here cannot
 * outlive the gap it describes — it fails if the member becomes declared, and
 * it fails if the member stops being installed.
 */
const undeclaredOnPurpose = new Map<string, number>()

/** The block starting just past an opening brace. */
function block(source: string, start: number): string {
  let depth = 1, index = start
  for (; index < source.length && depth > 0; index++) {
    if (source[index] === '{') depth++
    else if (source[index] === '}') depth--
  }
  return source.slice(start, index)
}

/** Members a shim installs through `keep('<group>', { … })`. */
function installed(source: string): Map<string, Set<string>> {
  const groups = new Map<string, Set<string>>()
  for (const open of source.matchAll(/keep\('([a-zA-Z]+)',\s*\{/g)) {
    const names = groups.get(open[1]!) ?? new Set<string>()
    let depth = 0
    for (const line of block(source, open.index + open[0].length).split('\n')) {
      // Only this object literal's own keys, not a nested one's.
      if (depth === 0) {
        const member = /^\s*([a-zA-Z][A-Za-z0-9]*)\s*:/.exec(line)
        if (member) names.add(member[1]!)
      }
      depth += (line.match(/[{[(]/g) ?? []).length - (line.match(/[}\])]/g) ?? []).length
      if (depth < 0) depth = 0
    }
    groups.set(open[1]!, names)
  }
  return groups
}

/** Members declared for each group, inline or through a named interface. */
function declaredGroups(): Map<string, Set<string>> {
  // Comments stripped: a `;` inside one truncates a non-greedy slice, which is
  // how an earlier version of a sibling check reported everything as missing.
  const types = readFileSync(resolve(sdk, 'types/craft.d.ts'), 'utf8').replace(/\/\/[^\n]*/g, '')
  const members = (body: string) => {
    const found = new Set<string>()
    let depth = 0
    for (const line of body.split('\n')) {
      // `<` as well as `(` and `:`, so a generic method is not missed.
      if (depth <= 1) {
        const member = /^\s{2,4}([a-zA-Z][A-Za-z0-9]*)\??\s*[(:<]/.exec(line)
        if (member) found.add(member[1]!)
      }
      depth += (line.match(/\{/g) ?? []).length - (line.match(/\}/g) ?? []).length
    }
    return found
  }
  const groups = new Map<string, Set<string>>()
  for (const found of types.matchAll(/^ {2}([a-zA-Z][A-Za-z0-9]*)\??:\s*(\{|([A-Z][A-Za-z0-9]*);)/gm)) {
    if (found[2] === '{') {
      groups.set(found[1]!, members(block(types, found.index + found[0].length)))
      continue
    }
    const at = types.search(new RegExp(`(?:export )?interface ${found[3]!}\\s*\\{`))
    groups.set(found[1]!, at < 0 ? new Set<string>() : members(block(types, types.indexOf('{', at) + 1)))
  }
  return groups
}

test('every member the native shims install is declared in craft.d.ts', () => {
  const declared = declaredGroups()
  expect(declared.size).toBeGreaterThan(30)
  expect(declared.get('snapshots'), 'the snapshots group must be declared').toBeTruthy()

  const shims: Array<[string, string]> = [
    ['iOS', host('ios/templates/CraftNativeScreen.swift')],
    ['Android', host('android/templates/CraftNativeShell.kt.template')],
  ]
  const gaps: string[] = []
  let total = 0
  for (const [label, source] of shims) {
    const groups = installed(source)
    expect(groups.size, `${label} must install at least a few groups`).toBeGreaterThan(3)
    for (const [group, names] of groups) {
      for (const name of names) {
        total++
        if (declared.get(group)?.has(name)) continue
        if (undeclaredOnPurpose.has(`${group}.${name}`)) continue
        gaps.push(`craft.${group}.${name} (${label})`)
      }
    }
  }
  expect(total).toBeGreaterThan(10)
  expect(gaps.sort(), 'these are installed on the global and declared nowhere').toEqual([])
})

test('a deliberate gap still names an open issue and is still a gap', () => {
  const declared = declaredGroups()
  for (const [member, issue] of undeclaredOnPurpose) {
    const [group, name] = member.split('.') as [string, string]
    expect(declared.get(group)?.has(name), `${member} is declared now, so its exemption is dead`).not.toBe(true)
    const installedSomewhere = [
      host('ios/templates/CraftNativeScreen.swift'),
      host('android/templates/CraftNativeShell.kt.template'),
    ].some(source => installed(source).get(group)?.has(name))
    expect(installedSomewhere, `${member} is no longer installed, so its exemption is dead`).toBe(true)
    expect(issue).toBeGreaterThan(0)
  }
})
