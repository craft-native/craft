import { existsSync } from 'node:fs'
import { join } from 'node:path'

/** A plist as JSON, or null when it cannot be read. */
export type PlistReader = (path: string) => Record<string, unknown> | null

/**
 * `plutil`, which reads the binary plists Xcode writes into a built bundle.
 * macOS only, like the builds whose output it reads.
 */
export const readPlistWithPlutil: PlistReader = (path) => {
  const converted = Bun.spawnSync(['plutil', '-convert', 'json', '-o', '-', path])
  if (converted.exitCode !== 0) return null
  try {
    return JSON.parse(converted.stdout.toString()) as Record<string, unknown>
  }
  catch {
    return null
  }
}

/**
 * Why a built iOS app's embedded Watch companion would not install, one line
 * per reason.
 *
 * Each line is a message `simctl install` gave for a generated app (#194,
 * #195), checked in the bundle first so a failure names the missing piece
 * rather than only quoting simctl. The install itself still runs afterwards;
 * this does not replace it.
 */
export function watchCompanionProblems(app: string, name: string, readPlist: PlistReader = readPlistWithPlutil): string[] {
  const watch = join(app, 'Watch', `${name}Watch.app`)
  if (!existsSync(watch))
    return [`${name}.app embeds no Watch/${name}Watch.app`]

  const problems: string[] = []
  const watchInfo = readPlist(join(watch, 'Info.plist'))
  if (!watchInfo)
    problems.push(`Watch/${name}Watch.app has no readable Info.plist`)
  else if (watchInfo.WKWatchKitApp !== true && watchInfo.WKApplication !== true)
    problems.push(`Watch/${name}Watch.app sets neither WKWatchKitApp nor WKApplication to true, so iOS will not install it (#194)`)

  const extension = join(watch, 'PlugIns', `${name}WatchExtension.appex`)
  if (!existsSync(extension)) {
    problems.push(`Watch/${name}Watch.app has no PlugIns/${name}WatchExtension.appex, so it is not a WatchKit 2 app (#195)`)
    return problems
  }

  const extensionInfo = readPlist(join(extension, 'Info.plist'))
  const point = (extensionInfo?.NSExtension as Record<string, unknown> | undefined)?.NSExtensionPointIdentifier
  if (point !== 'com.apple.watchkit')
    problems.push(`${name}WatchExtension.appex declares extension point ${JSON.stringify(point)}, not com.apple.watchkit`)

  return problems
}
