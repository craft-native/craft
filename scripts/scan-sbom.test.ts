import { afterEach, expect, test } from 'bun:test'
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { enforceScanPolicy, scanSbom, summarizeVulnerabilities } from './scan-sbom'

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

test('High findings block release scans and Critical findings block every scan', () => {
  const high = summarizeVulnerabilities(report([match('High')])).counts
  expect(() => enforceScanPolicy(high, false)).not.toThrow()
  expect(() => enforceScanPolicy(high, true)).toThrow('High vulnerabilities block this release')
  const critical = summarizeVulnerabilities(report([match('Critical')])).counts
  expect(() => enforceScanPolicy(critical, false)).toThrow('Critical vulnerabilities')
  expect(() => enforceScanPolicy(critical, true)).toThrow('Critical vulnerabilities')
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
  writeFileSync(join(f.root, 'vulnerabilities.txt'), 'stale successful summary')
  expect(() => scanSbom(f.sbom, f.root, f.executable)).toThrow('exit code 7')
  expect(existsSync(join(f.root, 'vulnerabilities.txt'))).toBe(false)
})

test('successful exit without valid output cannot reuse stale or malformed reports', () => {
  for (const source of ['process.exit(0)', 'await Bun.write(process.argv[process.argv.indexOf("--file") + 1], "not json")', 'await Bun.write(process.argv[process.argv.indexOf("--file") + 1], "{}")']) {
    const f = fixture(source)
    writeFileSync(join(f.root, 'vulnerabilities.json'), JSON.stringify(report()))
    writeFileSync(join(f.root, 'vulnerabilities.txt'), 'stale successful summary')
    expect(() => scanSbom(f.sbom, f.root, f.executable)).toThrow()
    expect(existsSync(join(f.root, 'vulnerabilities.txt'))).toBe(false)
  }
})

test('valid scanner output produces a matching text report; empty SBOMs are refused', () => {
  const f = fixture(`await Bun.write(process.argv[process.argv.indexOf('--file') + 1], ${JSON.stringify(JSON.stringify(report([match('High')])))});`)
  expect(scanSbom(f.sbom, f.root, f.executable).counts.High).toBe(1)
  expect(readFileSync(join(f.root, 'vulnerabilities.txt'), 'utf8')).toContain('High\tfixture')
  writeFileSync(f.sbom, JSON.stringify({ bomFormat: 'CycloneDX', components: [] }))
  expect(() => scanSbom(f.sbom, f.root, f.executable)).toThrow('populated CycloneDX')
  expect(existsSync(join(f.root, 'vulnerabilities.json'))).toBe(false)
  expect(existsSync(join(f.root, 'vulnerabilities.txt'))).toBe(false)
})

test('invalid input clears previous reports before failing', () => {
  const f = fixture('throw new Error("scanner must not run")')
  for (const input of ['{', '{}']) {
    writeFileSync(f.sbom, input)
    for (const name of ['vulnerabilities.json', 'vulnerabilities.txt']) writeFileSync(join(f.root, name), 'stale report')
    expect(() => scanSbom(f.sbom, f.root, f.executable)).toThrow()
    expect(existsSync(join(f.root, 'vulnerabilities.json'))).toBe(false)
    expect(existsSync(join(f.root, 'vulnerabilities.txt'))).toBe(false)
  }
})

test('refuses an input that aliases a scanner output without deleting it', () => {
  const f = fixture('process.exit(0)')
  const input = join(f.root, 'vulnerabilities.json')
  const content = readFileSync(f.sbom, 'utf8')
  writeFileSync(input, content)
  expect(() => scanSbom(input, f.root, f.executable)).toThrow('must not be a scanner output')
  expect(readFileSync(input, 'utf8')).toBe(content)
})
