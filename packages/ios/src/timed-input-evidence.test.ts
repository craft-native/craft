import { describe, expect, it } from 'bun:test'
import { readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir } from '../../typescript/src/temp-dir'
import { analyzeTimedInput } from '../scripts/analyze-timed-input'

const names = Array.from({ length: 24 }, (_, i) => ['One', 'Two', 'Three', 'Four'][i % 4]!)
const schedule = names.map((_, i) => [{ x: 0.2, y: 0.9, at: i * 0.08 }, { x: 0.2, y: 0.9, at: i * 0.08 + 0.025 }])
function fixture(interval = 0.08, hold = 0.025) {
  const events = names.flatMap((name, index) => [
    { kind: 'touch', phase: 'began', timestamp: 100 + index * interval, deliveredAt: 100 + index * interval + 0.005 },
    { kind: 'touch', phase: 'ended', timestamp: 100 + index * interval + hold, deliveredAt: 100 + index * interval + hold + 0.005 },
    { kind: 'callback', name, before: names.slice(0, index), after: names.slice(0, index + 1), deliveredAt: 100 + index * interval + hold + 0.005 },
  ])
  return events
}
function values(events: object[], callbacks = names) {
  const json = JSON.stringify(events)
  return [
    { id: 'native-touch-counts', value: 'began=24;ended=24;cancelled=0' },
    { id: 'received-callbacks', value: callbacks.join(',') },
    ...Array.from({ length: Math.ceil(json.length / 400) }, (_, index) => ({ id: `native-input-journal-${index}`, value: json.slice(index * 400, (index + 1) * 400) })),
  ]
}

describe('independent timed input evidence', () => {
  it('accepts all phases, callbacks, state and native offsets from one complete attempt', () => {
    const report = analyzeTimedInput(schedule, values(fixture()).reverse())
    expect(report.passed).toBe(true)
    expect(report.timing.observedSpanSeconds).toBeCloseTo(1.865)
  })
  it('detects compressed timing in the retained passing CI attempt', () => {
    const receipt = JSON.parse(readFileSync(join(import.meta.dir, '../fixtures/timed-input/compressed-ci-receipt.json'), 'utf8'))
    const report = analyzeTimedInput(receipt.schedule, receipt.values)
    expect(report.counts).toEqual({ began: 24, ended: 24, cancelled: 0, callbacks: 24 })
    expect(report.passed).toBe(false)
    expect(report.issues).toHaveLength(1)
    expect(report.timing.observedSpanSeconds).toBeCloseTo(0.8)
    expect(report.timing.maxOffsetErrorSeconds).toBeGreaterThan(1)
  })
  it('rejects the observed 33 ms compressed schedule even when all 24 callbacks arrive', () => {
    const report = analyzeTimedInput(schedule, values(fixture(1 / 30, 1 / 30)))
    expect(report.counts.callbacks).toBe(24)
    expect(report.passed).toBe(false)
    expect(report.timing.observedSpanSeconds).toBeCloseTo(0.8)
    expect(report.issues).toContainEqual(expect.stringContaining('Native schedule differs'))
  })
  it('allows frame quantization without hiding cumulative drift', () => {
    const events = fixture()
    for (const event of events) {
      if ('timestamp' in event && event.timestamp !== undefined) event.timestamp = Math.round(event.timestamp * 60) / 60
    }
    expect(analyzeTimedInput(schedule, values(events)).passed).toBe(true)
  })
  it('detects missing first callbacks independently of all 24 native touches', () => {
    const events = fixture().filter(event => event.kind !== 'callback' || event.before!.length >= 2)
    const report = analyzeTimedInput(schedule, values(events, names.slice(2)))
    expect(report.counts.began).toBe(24)
    expect(report.counts.callbacks).toBe(22)
    expect(report.issues).toContain('Callbacks do not match all 24 names in order')
  })
  it('rejects missing touches, cancellations and inconsistent state', () => {
    const events = fixture()
    events[0]!.phase = 'cancelled'
    events[2]!.after = []
    const report = analyzeTimedInput(schedule, values(events))
    expect(report.passed).toBe(false)
    expect(report.timing.maxOffsetErrorSeconds).toBeNull()
    expect(report.issues).toContain('Receiver state does not match callback history')
  })
  it('rejects incomplete and duplicate evidence instead of reporting a pass', () => {
    const receipt = values(fixture())
    expect(() => analyzeTimedInput(schedule, receipt.filter(value => value.id !== 'native-input-journal-1'))).toThrow('chunks')
    expect(() => analyzeTimedInput(schedule, [...receipt, receipt[2]!])).toThrow('Duplicate')
    expect(() => analyzeTimedInput(schedule, receipt.slice(0, 2))).toThrow('chunks')
  })
  it('rejects changed schedules and malformed native timestamps', () => {
    const changed = structuredClone(schedule)
    changed[1]![0]!.at = 0.033
    expect(() => analyzeTimedInput(changed, values(fixture()))).toThrow('canonical')
    const events = fixture()
    events[0]!.timestamp = Number.NaN
    expect(() => analyzeTimedInput(schedule, values(events))).toThrow('timestamp')
  })
  it('reports delivery lag separately from native timestamps', () => {
    const events = fixture()
    for (const event of events) event.deliveredAt += 0.2
    const report = analyzeTimedInput(schedule, values(events))
    expect(report.passed).toBe(true)
    expect(report.timing.maxDeliveryLagSeconds).toBeCloseTo(0.205)
  })
  it('returns a failing CLI exit status for compressed timing and malformed input', () => {
    const folder = createTempDir('craft-input-evidence-')
    try {
      const scheduled = join(folder, 'schedule.json')
      const received = join(folder, 'values.json')
      writeFileSync(scheduled, JSON.stringify(schedule))
      const run = () => Bun.spawnSync([process.execPath, join(import.meta.dir, '../scripts/analyze-timed-input.ts'), scheduled, received], { stdout: 'pipe', stderr: 'pipe' })
      writeFileSync(received, JSON.stringify(values(fixture())))
      expect(run().exitCode).toBe(0)
      writeFileSync(received, JSON.stringify(values(fixture(1 / 30, 1 / 30))))
      const compressed = run()
      expect(compressed.exitCode).toBe(1)
      expect(JSON.parse(compressed.stdout.toString()).passed).toBe(false)
      writeFileSync(received, '{broken')
      expect(run().exitCode).toBe(1)
    }
    finally {
      rmSync(folder, { recursive: true, force: true })
    }
  })

})
