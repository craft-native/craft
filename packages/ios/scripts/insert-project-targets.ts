/** Insert generated test targets before the shared schemes block in project.yml. */
export function insertProjectTargetsBeforeSchemes(project: string, targets: string): string {
  const marker = '\nschemes:\n'
  const schemes = project.indexOf(marker)
  if (schemes < 0) throw new Error('Generated iOS project is missing its schemes block')
  const normalizedTargets = targets.replace(/^\n/, '').trimEnd()
  return `${project.slice(0, schemes)}\n${normalizedTargets}\n${project.slice(schemes + 1)}`
}
