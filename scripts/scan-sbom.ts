import { appendFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const severities = ['Critical', 'High', 'Medium', 'Low', 'Negligible', 'Unknown'] as const
type Severity = typeof severities[number]

export function summarizeVulnerabilities(report: unknown) {
  const document = report as any
  if (document?.descriptor?.name !== 'grype' || typeof document.descriptor.version !== 'string' || !document.descriptor.version.trim())
    throw new Error('Missing Grype scanner identity')
  if (document.descriptor.db?.status?.valid !== true)
    throw new Error('Grype vulnerability database is missing or invalid')
  if (!Array.isArray(document.matches))
    throw new Error('Grype report must contain a matches array; absent results are not a clean scan')
  const counts = { Critical: 0, High: 0, Medium: 0, Low: 0, Negligible: 0, Unknown: 0 }
  const lines = ['Severity\tPackage\tVersion\tVulnerability']
  for (const match of document.matches) {
    const severity = match?.vulnerability?.severity as Severity
    if (!severities.includes(severity))
      throw new Error(`Unknown vulnerability severity: ${JSON.stringify(severity)}`)
    const fields = [severity, match?.artifact?.name, match?.artifact?.version, match?.vulnerability?.id]
    if (fields.some(value => typeof value !== 'string' || !value.trim()))
      throw new Error('Malformed Grype match: package name/version and vulnerability id are required')
    counts[severity]++
    lines.push(fields.map(value => value.replace(/[\r\n\t]/g, ' ')).join('\t'))
  }
  return { counts, text: `${lines.join('\n')}\n` }
}

export function scanSbom(sbom: string, output: string, executable = 'grype') {
  // Validate input before invoking the scanner. Missing inventory must not look clean.
  const inventory = JSON.parse(readFileSync(sbom, 'utf8'))
  if (inventory.bomFormat !== 'CycloneDX' || !Array.isArray(inventory.components) || !inventory.components.length)
    throw new Error('A populated CycloneDX SBOM is required for vulnerability scanning')
  mkdirSync(output, { recursive: true })
  const reportPath = join(output, 'vulnerabilities.json')
  rmSync(reportPath, { force: true })
  const scan = Bun.spawnSync([executable, `sbom:${resolve(sbom)}`, '--output', 'json', '--file', reportPath], { stdout: 'inherit', stderr: 'inherit' })
  if (scan.exitCode !== 0)
    throw new Error(`Grype failed with exit code ${scan.exitCode}; vulnerability counts are unavailable`)
  const summary = summarizeVulnerabilities(JSON.parse(readFileSync(reportPath, 'utf8')))
  writeFileSync(join(output, 'vulnerabilities.txt'), summary.text)
  return summary
}

if (import.meta.main) {
  try {
    const { counts } = scanSbom(process.argv[2] || 'sbom/full-sbom.cyclonedx.json', process.argv[3] || 'scan-results')
    const summary = ['## Vulnerability scan results', '', '| Severity | Count |', '| --- | --- |', ...severities.map(severity => `| ${severity} | ${counts[severity]} |`), '', 'Policy: Critical findings fail this check. High findings remain unresolved release-review items (#279); this report is not a release approval.', ''].join('\n')
    console.log(summary)
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary)
    if (counts.High > 0) console.warn('::warning::High vulnerability findings require review under #279')
    if (counts.Critical > 0) throw new Error('Critical vulnerabilities found in dependencies')
  }
  catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
