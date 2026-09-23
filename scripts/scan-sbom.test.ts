import { afterEach, expect, test } from 'bun:test'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { scanSbom, summarizeVulnerabilities } from './scan-sbom'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })
const report = (matches: unknown[] = []) => ({ descriptor: { name: 'grype', version: '0.119.0', db: { status: { valid: true } } }, matches })
const match = (severity: string) => ({ vulnerability: { severity, id: 'CVE-2026-1234' }, artifact: { name: 'fixture', version: '1.0.0' } })

test('counts all supported severities without mistaking absent results for zero', () => {
  expect(summarizeVulnerabilities(report()).counts.Critical).toBe(0)
  const result = summarizeVulnerabilities(report(['Critical', 'High', 'High', 'Medium', 'Low', 'Negligible', 'Unknown'].map(match)))
  expect(result.counts).toEqual({ Critical: 1, High: 2, Medium: 1, Low: 1, Negligible: 1, Unknown: 1 })
  expect(result.text).toContain('High\tfixture\t1.0.0\tCVE-2026-1234')
  for (const invalid of [null, {}, { matches: [] }, { ...report(), matches: null }, { ...report(), descriptor: { name: 'grype', version: '0.119.0' } }, report([{}]), report([match('new severity')])])
    expect(() => summarizeVulnerabilities(invalid)).toThrow()
})

function fixture(source: string) {
  const root = mkdtempSync(join(tmpdir(), 'craft-grype-test-'))
  roots.push(root)
  const executable = join(root, 'grype')
  const sbom = join(root, 'sbom.json')
  writeFileSync(sbom, JSON.stringify({ bomFormat: 'CycloneDX', components: [{ name: 'fixture' }] }))
  writeFileSync(executable, `#!${process.execPath}\n${source}\n`)
  chmodSync(executable, 0o755)
  return { root, executable, sbom }
}

test('scanner execution failures cannot pass even with an old valid report', () => {
  const f = fixture('process.exit(7)')
  writeFileSync(join(f.root, 'vulnerabilities.json'), JSON.stringify(report()))
  expect(() => scanSbom(f.sbom, f.root, f.executable)).toThrow('exit code 7')
})

test('successful exit without valid output cannot reuse stale or malformed reports', () => {
  for (const source of ['process.exit(0)', 'await Bun.write(process.argv[process.argv.indexOf("--file") + 1], "not json")', 'await Bun.write(process.argv[process.argv.indexOf("--file") + 1], "{}")']) {
    const f = fixture(source)
    writeFileSync(join(f.root, 'vulnerabilities.json'), JSON.stringify(report()))
    expect(() => scanSbom(f.sbom, f.root, f.executable)).toThrow()
  }
})

test('valid scanner output produces a matching text report; empty SBOMs are refused', () => {
  const f = fixture(`await Bun.write(process.argv[process.argv.indexOf('--file') + 1], ${JSON.stringify(JSON.stringify(report([match('High')])))});`)
  expect(scanSbom(f.sbom, f.root, f.executable).counts.High).toBe(1)
  expect(readFileSync(join(f.root, 'vulnerabilities.txt'), 'utf8')).toContain('High\tfixture')
  writeFileSync(f.sbom, JSON.stringify({ bomFormat: 'CycloneDX', components: [] }))
  expect(() => scanSbom(f.sbom, f.root, f.executable)).toThrow('populated CycloneDX')
})
