type Strategy = 'patch' | 'minor' | 'major' | 'all'
interface Update {
  name: string
  currentVersion: string
  newVersion: string
  updateType: string
  [key: string]: unknown
}

export function updateOptions(env: Record<string, string | undefined>) {
  const strategy = env.BUDDY_STRATEGY || 'patch'
  if (!['patch', 'minor', 'major', 'all'].includes(strategy))
    throw new Error(`Unknown update strategy: ${strategy}`)
  const dryRun = env.BUDDY_DRY_RUN ?? 'true'
  if (!['true', 'false'].includes(dryRun))
    throw new Error('BUDDY_DRY_RUN must be true or false')
  const packages = (env.BUDDY_PACKAGES || '').split(',').map(name => name.trim()).filter(Boolean)
  return { strategy: strategy as Strategy, dryRun: dryRun === 'true', packages }
}

function versionParts(value: string): number[] | null {
  // Ambiguous ranges, prereleases, git refs and SHA/digest pins need manual
  // review. Never replace a pinned action with an unpinned version tag.
  const match = /^[~^]?v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(value)
  if (!match) return null
  const parts = match.slice(1).map(Number)
  return parts.every(Number.isSafeInteger) ? parts : null
}

export function selectUpdates(updates: Update[], options: ReturnType<typeof updateOptions>): Update[] {
  return updates.flatMap((update) => {
    if (!update || ['name', 'currentVersion', 'newVersion'].some(key => typeof update[key] !== 'string' || !update[key]))
      throw new Error('Buddy Bot returned a malformed update')
    if (options.packages.length && !options.packages.includes(update.name)) return []
    const before = versionParts(update.currentVersion)
    const after = versionParts(update.newVersion)
    if (!before || !after) return []
    const index = before.findIndex((part, index) => part !== after[index])
    if (index < 0 || after[index] < before[index]) return []
    const kind = ['major', 'minor', 'patch'][index]
    const allowed = options.strategy === 'all'
      || (options.strategy === 'minor' ? index >= 1 : kind === options.strategy)
    // Do not trust a scanner's classification to enforce the version limit.
    return allowed ? [{ ...update, updateType: kind }] : []
  })
}

export async function runUpdates(
  buddy: { scanForUpdates: () => Promise<any>, createPullRequests: (scan: any) => Promise<void> },
  regroup: (updates: any[]) => any[],
  options: ReturnType<typeof updateOptions>,
) {
  const scan = await buddy.scanForUpdates()
  if (!Array.isArray(scan?.updates)) throw new Error('Buddy Bot returned no updates array')
  const updates = selectUpdates(scan.updates, options)
  // Discard the broad scanner groups: passing them through would bypass the
  // guard even if the top-level updates list was filtered correctly.
  const selected = { ...scan, updates, groups: regroup(updates) }
  if (!options.dryRun && updates.length) await buddy.createPullRequests(selected)
  return selected
}

if (import.meta.main) {
  const options = updateOptions(process.env)
  const repository = (process.env.GITHUB_REPOSITORY || '').split('/')
  if (repository.length !== 2 || repository.some(part => !/^[\w.-]+$/.test(part)))
    throw new Error('GITHUB_REPOSITORY must identify the target owner/repository')
  if (!options.dryRun && !process.env.GITHUB_TOKEN && !process.env.BUDDY_BOT_TOKEN)
    throw new Error('Applying updates requires the configured Buddy Bot token')
  const { Buddy, groupUpdates } = await import('buddy-bot')
  const buddy = new Buddy({
    repository: { provider: 'github', owner: repository[0], name: repository[1], baseBranch: process.env.BUDDY_BASE_BRANCH || 'main' },
    packages: { strategy: 'all', respectLatest: true },
    verbose: process.env.BUDDY_VERBOSE === 'true',
  })
  const selected = await runUpdates(buddy, groupUpdates, options)
  console.log(`${options.dryRun ? 'Dry run: selected' : 'Processed'} ${selected.updates.length} updates in ${selected.groups.length} groups (${options.strategy}).`)
  for (const update of selected.updates)
    console.log(JSON.stringify({ name: update.name, from: update.currentVersion, to: update.newVersion }))
}
