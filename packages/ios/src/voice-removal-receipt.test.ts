import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * The removal receipt can say where a slow deletion spent its time.
 *
 * #490's retained occurrence reports `queueMilliseconds: 7638` against
 * `removalMilliseconds: 3.29` — the unlink took three milliseconds and
 * waiting to start took seven and a half seconds. `queueMilliseconds` spans
 * three things, and they have different owners:
 *
 *  1. `trace`, which takes a process-wide `NSLock` shared with the page's own
 *     console bridge and then calls `os_log` synchronously;
 *  2. the `fileQueue.async` submission;
 *  3. the wait for GCD to admit the block to a thread.
 *
 * (1) would be a defect here — a diagnostic line delaying the deletion it
 * reports. (3) would not: the test that produced the occurrence deliberately
 * blocks the encoder, and libdispatch grows its pool slowly when threads are
 * blocked. The receipt could not tell them apart, which is where the
 * investigation stopped.
 *
 * `submitMilliseconds` covers (1) and (2) alone, so the next occurrence
 * decides it: near zero means the time went on thread admission, most of the
 * total means it went in `trace`.
 */
const recording = readFileSync(join(import.meta.dir, '../templates/CraftVoiceRecording.swift'), 'utf8')
/** Comments stripped: a note describing a measurement is not a measurement. */
const code = recording.replace(/^\s*\/\/[^\n]*$/gm, '')

test('the receipt carries the submission split as well as the total', () => {
  const struct = code.slice(code.indexOf('struct FileRemovalReceipt: Encodable {'))
    .slice(0, code.slice(code.indexOf('struct FileRemovalReceipt: Encodable {')).indexOf('}') + 1)
  for (const field of ['queueMilliseconds', 'submitMilliseconds', 'removalMilliseconds']) {
    expect(struct, `the receipt must report ${field}`).toContain(`let ${field}: Double`)
  }
})

test('the submission mark is taken after the trace and before the async', () => {
  // The whole value of the field is where it is sampled. Before the trace it
  // measures nothing; inside the block it measures the same thing as
  // queueMilliseconds.
  const trace = code.indexOf('Self.trace("cancel \\(session.key.prefix(8)): file removal queued")')
  const submitted = code.indexOf('let submitted = ProcessInfo.processInfo.systemUptime')
  const async = code.indexOf('Self.fileQueue.async {')
  expect(trace, 'the cancel path must still trace').toBeGreaterThan(0)
  expect(submitted, 'the submission must be marked').toBeGreaterThan(trace)
  expect(async, 'and marked before the block is submitted').toBeGreaterThan(submitted)
})

test('both spans are measured from the same origin', () => {
  // submitMilliseconds and queueMilliseconds must share `queued`, or
  // subtracting one from the other says nothing.
  expect(code).toContain('queueMilliseconds: (began - queued) * 1000')
  expect(code).toContain('submitMilliseconds: (submitted - queued) * 1000')
})

test('the deletion still runs off the caller and off the audio queue', () => {
  // #448's repair: a stalled encoder must not hold deletion behind its audio
  // queue. The new mark must not have moved the work back onto the caller.
  expect(code).toContain('private static let fileQueue = DispatchQueue(label: "craft.voice-recording-files", qos: .userInitiated)')
  const clear = code.slice(code.indexOf('private func clear('), code.indexOf('func perform('))
  expect(clear, 'the removal still happens on the file queue').toContain('Self.fileQueue.async {')
  expect(clear).toContain('CraftNativeFiles.remove(file.path)')
})
