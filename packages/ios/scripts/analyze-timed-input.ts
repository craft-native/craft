import { readFileSync } from 'node:fs'

const sequence = Array.from({ length: 24 }, (_, index) => ['One', 'Two', 'Three', 'Four'][index % 4]!)
const tolerance = 0.05 // Allow native frame quantization, not cumulative schedule compression.
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value)
const finite = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value)
const equal = (left: unknown, right: unknown): boolean => JSON.stringify(left) === JSON.stringify(right)

/** Analyze one canonical 24-tap attempt, never combine receipts from retries. */
export function analyzeTimedInput(schedule: unknown, values: unknown) {
  if (!Array.isArray(schedule) || schedule.length !== 24)
    throw new Error('Expected the canonical 24-path schedule')
  for (const [index, path] of schedule.entries()) {
    if (!Array.isArray(path) || path.length !== 2 || path.some(point => !object(point)
      || !finite(point.x) || point.x < 0 || point.x > 1 || !finite(point.y) || point.y < 0 || point.y > 1 || !finite(point.at)))
      throw new Error(`Malformed scheduled path ${index}`)
    if (Math.abs(path[0].at - index * 0.08) > 1e-9 || Math.abs(path[1].at - (index * 0.08 + 0.025)) > 1e-9
      || path[0].x !== path[1].x || path[0].y !== path[1].y)
      throw new Error(`Path ${index} changes the canonical 80 ms / 25 ms schedule`)
  }
  if (!Array.isArray(values)) throw new Error('Expected the receiver values attachment')
  const entries = new Map<string, string>()
  for (const value of values) {
    if (!object(value) || typeof value.id !== 'string' || typeof value.value !== 'string')
      throw new Error('Malformed accessibility value')
    if (entries.has(value.id)) throw new Error(`Duplicate accessibility identifier: ${value.id}`)
    entries.set(value.id, value.value)
  }
  const chunks = [...entries].filter(([id]) => id.startsWith('native-input-journal-'))
    .map(([id, value]) => ({ index: Number(id.slice('native-input-journal-'.length)), value }))
    .sort((a, b) => a.index - b.index)
  if (!chunks.length || chunks.some((chunk, index) => chunk.index !== index || !chunk.value.length || chunk.value.length > 400))
    throw new Error('Missing, duplicated, or invalid journal chunks')
  const journal: unknown = JSON.parse(chunks.map(chunk => chunk.value).join(''))
  if (!Array.isArray(journal) || journal.length > 256 || journal.some(event => !object(event) || !finite(event.deliveredAt)))
    throw new Error('Malformed native input journal')
  const events = journal as Record<string, unknown>[]
  const touches = events.filter(event => event.kind === 'touch')
  const callbacks = events.filter(event => event.kind === 'callback')
  if (touches.length + callbacks.length !== events.length || touches.some(event => !finite(event.timestamp)
    || !['began', 'ended', 'cancelled'].includes(String(event.phase))))
    throw new Error('Unknown event or invalid native timestamp')
  const began = touches.filter(event => event.phase === 'began')
  const ended = touches.filter(event => event.phase === 'ended')
  const cancelled = touches.filter(event => event.phase === 'cancelled')
  const issues: string[] = []
  if (began.length !== 24 || ended.length !== 24 || cancelled.length)
    issues.push(`Native delivery: ${began.length} began, ${ended.length} ended, ${cancelled.length} cancelled`)
  const counts = `began=${began.length};ended=${ended.length};cancelled=${cancelled.length}`
  if (entries.get('native-touch-counts') !== counts) issues.push('Native counters disagree with the journal')
  const names = callbacks.map(event => event.name)
  if (!equal(names, sequence)) issues.push('Callbacks do not match all 24 names in order')
  if (entries.get('received-callbacks') !== names.join(',')) issues.push('Callback value disagrees with the journal')
  if (callbacks.some((event, index) => !equal(event.before, names.slice(0, index)) || !equal(event.after, names.slice(0, index + 1))))
    issues.push('Receiver state does not match callback history')
  if (events.some((event, index) => index > 0 && Number(event.deliveredAt) < Number(events[index - 1]!.deliveredAt)))
    issues.push('Delivery clock goes backwards')
  if (touches.some((event, index) => index > 0 && Number(event.timestamp) < Number(touches[index - 1]!.timestamp)))
    issues.push('Native event clock goes backwards')
  if (touches.some((event, index) => event.phase !== (index % 2 === 0 ? 'began' : 'ended')))
    issues.push('Native phases do not alternate began/ended')

  const origin = began.length ? Number(began[0]!.timestamp) : null
  const starts = origin === null ? [] : began.map(event => Number(event.timestamp) - origin)
  const ends = origin === null ? [] : ended.map(event => Number(event.timestamp) - origin)
  const comparable = began.length === 24 && ended.length === 24 && cancelled.length === 0
  const maxOffsetErrorSeconds = comparable
    ? Math.max(...starts.map((at, index) => Math.abs(at - index * 0.08)), ...ends.map((at, index) => Math.abs(at - (index * 0.08 + 0.025))))
    : null
  if (maxOffsetErrorSeconds !== null && maxOffsetErrorSeconds > tolerance)
    issues.push(`Native schedule differs by up to ${maxOffsetErrorSeconds.toFixed(6)}s (limit ${tolerance}s)`)
  return {
    passed: issues.length === 0,
    issues,
    counts: { began: began.length, ended: ended.length, cancelled: cancelled.length, callbacks: callbacks.length },
    timing: {
      toleranceSeconds: tolerance,
      expectedSpanSeconds: 1.865,
      observedSpanSeconds: ends.at(-1) ?? null,
      maxOffsetErrorSeconds,
      startOffsetsSeconds: starts,
      endOffsetsSeconds: ends,
      maxDeliveryLagSeconds: touches.length ? Math.max(...touches.map(event => Number(event.deliveredAt) - Number(event.timestamp))) : null,
    },
  }
}

if (import.meta.main) {
  try {
    const args = process.argv.slice(2)
    if (args.length !== 2) throw new Error('Usage: bun packages/ios/scripts/analyze-timed-input.ts <scheduled.json> <receiver-values.json>')
    const report = analyzeTimedInput(JSON.parse(readFileSync(args[0]!, 'utf8')), JSON.parse(readFileSync(args[1]!, 'utf8')))
    console.log(JSON.stringify(report, null, 2))
    process.exitCode = report.passed ? 0 : 1
  }
  catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
