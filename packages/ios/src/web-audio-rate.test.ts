import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * A buffer source's rate is always one the engine can play.
 *
 * The rate is the buffer's sample rate over the context's, times
 * `playbackRate`, times two to the power of `detune` in octaves, and for a
 * buffer source neither param is bounded:
 *
 *   source.loop = true
 *   source.detune.value = 2_000_000   // 2^1666: infinite
 *
 * A looping source wrapped an infinite position into one that is not a
 * number, and the render thread trapped converting it to an index: `Fatal
 * error: Double value cannot be converted to Int because it is either
 * infinite or NaN`. The process ended. With a `playbackRate` of 0 beside that
 * detune the rate itself is not a number.
 *
 * WebKit clamps the rate to `MaxRate` (1024) either side of zero and plays a
 * rate that is not a number at 1.0 (`AudioBufferSourceNode::totalPitchRate`).
 * The function under test is the shipped one, compiled against Foundation;
 * the graph itself is rendered on a simulator in
 * testABufferSourceWhoseRateOverflowsPlaysOnInsteadOfEndingTheProcess.
 */
const audio = readFileSync(join(import.meta.dir, '../templates/CraftWebAudio.swift'), 'utf8')

// ratio, playbackRate, detune in cents, and the rate.
const rates: [number, number, number, string][] = [
  // What ended the process, and its relatives.
  [1, 1, 2_000_000, '1024.0'],
  [1, -1, 2_000_000, '-1024.0'],
  [1, 0, 2_000_000, '1.0'],
  [1, 3.4e38, 0, '1024.0'],
  [1, -3.4e38, 0, '-1024.0'],
  [1, 3.4e38, 3.4e38, '1024.0'],
  // Ordinary rates are as they were.
  [1, 1, 0, '1.0'],
  [1, 2, 0, '2.0'],
  [0.5, 1, 1200, '1.0'],
  [1, 1, -1200, '0.5'],
  [1, -1, 0, '-1.0'],
  [1, 0, 0, '0.0'],
  [1, 1, -2_000_000, '0.0'],
  [1, 1024, 0, '1024.0'],
  [1, 1023.5, 0, '1023.5'],
]

test.skipIf(process.platform !== 'darwin')('a buffer source\'s rate is clamped as WebKit clamps it, and never not a number', () => {
  const limit = audio.indexOf('    static let maximumRate = 1024.0')
  const start = audio.indexOf('    static func rate(ratio: Double, playbackRate: Double, detune: Double) -> Double {')
  expect(limit, 'maximumRate must still be here to test').toBeGreaterThan(-1)
  expect(start, 'rate(ratio:playbackRate:detune:) must still be here to test').toBeGreaterThan(limit)
  const end = audio.indexOf('\n    }\n', start)
  const dir = createTempDir('craft-audio-rate-')
  try {
    const main = join(dir, 'main.swift'), binary = join(dir, 'probe')
    writeFileSync(main, `import Foundation
enum CraftAudioBufferSource {
    static let maximumRate = 1024.0
${audio.slice(start, end + '\n    }\n'.length)}}
let numbers = CommandLine.arguments.dropFirst().map { Double($0)! }
print(CraftAudioBufferSource.rate(ratio: numbers[0], playbackRate: numbers[1], detune: numbers[2]))
`)
    const build = Bun.spawnSync(['swiftc', main, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 180_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const wrong: string[] = []
    for (const [ratio, playbackRate, detune, expected] of rates) {
      const run = Bun.spawnSync([binary, String(ratio), String(playbackRate), String(detune)], { stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
      const got = run.exitCode === 0 ? run.stdout.toString().trim() : `the process ended (${run.signalCode ?? run.exitCode}): ${run.stderr.toString().split('\n')[0]}`
      if (got !== expected) wrong.push(`${ratio} x ${playbackRate} x 2^(${detune}/1200): expected ${expected}, got ${got}`)
    }
    expect(wrong).toEqual([])
  }
  finally { removeTempDir(dir) }
}, 300_000)

test('the buffer source plays at the rate that function returns', () => {
  expect(audio).toContain('let rate = Self.rate(ratio: buffer.sampleRate / render.sampleRate, playbackRate: Double(playbackRate.values[0]), detune: Double(detune.values[0]))')
  // The unbounded product must not come back as the rate.
  expect(audio).not.toContain('let rate = buffer.sampleRate / render.sampleRate * Double(playbackRate.values[0])')
})
