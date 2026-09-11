import { readFileSync, writeFileSync } from 'node:fs'

type DependencySection = Record<string, string>

interface PackageManifest {
  dependencies?: DependencySection
  devDependencies?: DependencySection
}

/**
 * Replace monorepo-only or floating Craft SDK ranges in a scaffolded app with
 * the version shipped by the CLI that created it.
 */
export function pinCraftNativeDependency(packagePath: string, craftVersion: string): void {
  const manifest = JSON.parse(readFileSync(packagePath, 'utf-8')) as PackageManifest
  const sections = [manifest.dependencies, manifest.devDependencies]
  let found = false

  for (const dependencies of sections) {
    if (dependencies && Object.hasOwn(dependencies, 'craft-native')) {
      dependencies['craft-native'] = `^${craftVersion}`
      found = true
    }
  }

  if (!found) {
    manifest.dependencies ??= {}
    manifest.dependencies['craft-native'] = `^${craftVersion}`
  }

  writeFileSync(packagePath, `${JSON.stringify(manifest, null, 2)}\n`)
}
