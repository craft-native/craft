import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * A background script's `requestAnimationFrame` counts from its own first
 * frame, as a screen's does.
 *
 * `requestAnimationFrame` hands its callback milliseconds from the script's
 * own origin, so the first is near zero. UIKit subtracts an origin and so
 * does an Android screen (#395). The Android background host, the script
 * started for a refresh or a silent push with no activity, was left out and
 * sent `SystemClock.uptimeMillis()`: milliseconds from boot. Code shared
 * between a screen and the app script read `0` on one and a figure in the
 * billions on the other, on the same device at the same moment.
 *
 * The function under test is the shipped one, lifted from the template. The
 * readings are a clock that has been running for thirty days.
 */
const background = readFileSync(join(import.meta.dir, '../templates/CraftNativeBackground.kt.template'), 'utf8')

test('the background host sends frame times from its own origin, not from boot', async () => {
  const origin = liftKotlinMember(background, 'var frameTimeOrigin')
  const frameTime = liftKotlinMember(background, 'fun frameTime')
  const source = `
class Host {
${origin}

${frameTime}

    fun at(now: Long): Double = frameTime(now)
}

fun main() {
    val boot = 30L * 24 * 60 * 60 * 1_000_000_000L
    val host = Host()
    // Three frames at the background pace, the last a fraction of a millisecond late.
    val times = listOf(boot, boot + 100_000_000L, boot + 200_250_000L).map(host::at)
    check(times == listOf(0.0, 100.0, 200.25)) { "frame times from boot or rounded: $times" }
    // A second script has its own origin.
    val other = Host().at(boot + 5_000_000_000L)
    check(other == 0.0) { "a second script shared the first one's origin: $other" }
}
`
  await runKotlinFixture(source)
}, 300_000)

test('the frame the background host answers is the one that function measures', () => {
  expect(background).toContain('"FRAME" -> main.postDelayed({ send("FRAME_FIRE", JSONObject().put("time", frameTime(System.nanoTime()))) }, 100)')
  // The boot clock must not come back as a frame time.
  expect(background).not.toContain('uptimeMillis()')
})
