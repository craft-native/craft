/** Insert generated test targets before the shared schemes block in project.yml. */
export function insertProjectTargetsBeforeSchemes(project: string, targets: string): string {
  const marker = '\nschemes:\n'
  const schemes = project.indexOf(marker)
  if (schemes < 0) throw new Error('Generated iOS project is missing its schemes block')
  const normalizedTargets = targets.replace(/^\n/, '').trimEnd()
  return `${project.slice(0, schemes)}\n${normalizedTargets}\n${project.slice(schemes + 1)}`
}

/** Add generated test bundles to the explicit scheme's test action. */
export function addSchemeTestTargets(project: string, appName: string, testTargets: string[]): string {
  const schemes = project.indexOf('\nschemes:\n')
  const scheme = project.indexOf(`  ${appName}:\n`, schemes)
  const test = project.indexOf('    test:\n      config: Debug\n', scheme)
  if (schemes < 0 || scheme < 0 || test < 0) throw new Error(`Generated iOS project is missing the ${appName} scheme test action`)
  const targets = testTargets.map(target => `        - ${target}`).join('\n')
  const replacement = `    test:\n      config: Debug\n      targets:\n${targets}\n`
  return `${project.slice(0, test)}${replacement}${project.slice(test + '    test:\n      config: Debug\n'.length)}`
}

/** Add test bundles to the scheme's build action as well as its test action. */
export function addSchemeBuildTargets(project: string, appName: string, buildTargets: string[]): string {
  const schemes = project.indexOf('\nschemes:\n')
  const scheme = project.indexOf(`  ${appName}:\n`, schemes)
  const build = project.indexOf('    build:\n      targets:\n', scheme)
  if (schemes < 0 || scheme < 0 || build < 0) throw new Error(`Generated iOS project is missing the ${appName} scheme build action`)
  const anchor = `        ${appName}: all\n`
  const at = project.indexOf(anchor, build)
  if (at < 0) throw new Error(`Generated iOS project is missing the ${appName} scheme build target`)
  const targets = buildTargets.map(target => `        ${target}: [test]\n`).join('')
  return `${project.slice(0, at + anchor.length)}${targets}${project.slice(at + anchor.length)}`
}
