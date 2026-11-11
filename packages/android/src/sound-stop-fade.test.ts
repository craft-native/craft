import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { soundsProgram } from './sound-testing'
import { runKotlinFixture } from './testing'

/**
 * `audio.stop` stops the sound, whatever it was given for a fade.
 *
 * Android refused a `fadeOut` that was not a duration:
 *
 *   craft.audio.stop('music', { fadeOut: Math.min(500, remaining - 100) })
 *
 * Near the end of a track that is negative. `stop` answered `false`, which
 * is the answer for a sound that does not exist, and the sound went on
 * playing. UIKit and the browser host stop it at once. `stopAll` did the
 * same for every sound the screen had.
 *
 * The fade was also read with `optDouble`, which takes "500" for a number.
 * UIKit reads only a number as one, so the same call faded on one host and
 * stopped at once on the other.
 *
 * The class under test is the shipped one, on the harness in
 * `sound-testing.ts`.
 */
const activity = readFileSync(join(import.meta.dir, '../templates/MainActivityNative.kt.template'), 'utf8')

test('the dispatcher reads the fade through the function this tests', () => {
  expect(activity).toContain('screen.sounds.stop(id, screen.sounds.fadeOut(args.optJSONObject(1)))')
  expect(activity).toContain('screen.sounds.stopAll(screen.sounds.fadeOut(args.optJSONObject(0)))')
  expect(activity).not.toContain('optDouble("fadeOut"')
})

test('stop stops a sound whatever its fade, and a fade is a positive JSON number or none', async () => {
  await runKotlinFixture(soundsProgram(`
fun near(actual: Float, wanted: Float) = kotlin.math.abs(actual - wanted) < 0.02f
fun check(condition: Boolean, message: String) { if (!condition) throw AssertionError(message) }

internal fun started(): Triple<CraftNativeSounds, MediaPlayer, Handler> {
    MediaPlayer.players.clear()
    val sounds = CraftNativeSounds(Context())
    sounds.play("tone", "https://example.test/tone.mp3", JSONObject("{\\"volume\\":1}")) {}
    val player = MediaPlayer.players.single()
    player.finishPreparing()
    return Triple(sounds, player, Handler.last)
}

fun main() {
    // What crosses the bridge, and the fade it asks for.
    val reader = CraftNativeSounds(Context())
    val readings = listOf(
        "{\\"fadeOut\\":500}" to 500.0, "{\\"fadeOut\\":0.5}" to 0.5, "{\\"fadeOut\\":0}" to 0.0, "{}" to 0.0,
        "{\\"fadeOut\\":-500}" to 0.0, "{\\"fadeOut\\":\\"500\\"}" to 0.0, "{\\"fadeOut\\":true}" to 0.0,
        "{\\"fadeOut\\":null}" to 0.0, "{\\"fadeOut\\":{\\"ms\\":500}}" to 0.0, "{\\"fadeOut\\":[500]}" to 0.0,
    )
    for ((options, wanted) in readings) {
        val got = reader.fadeOut(JSONObject(options))
        check(got == wanted, "a stop given " + options + " should fade for " + wanted + " ms, read " + got)
    }
    check(reader.fadeOut(null) == 0.0, "a stop with no options has no fade")

    // A fade that is not a duration, given to stop directly: the sound stops now.
    for (fade in listOf(-500.0, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
        started().let { (sounds, player, handler) ->
            check(sounds.stop("tone", fade), "stop with a fade of " + fade + " answered false, the answer for a sound that does not exist")
            check(!player.isPlaying, "stop with a fade of " + fade + " left the sound playing")
            check(!sounds.pause("tone"), "stop with a fade of " + fade + " left the sound owned")
            handler.advance(5000)
            check(!player.isPlaying, "and it stays stopped")
        }
    }
    // stopAll too.
    started().let { (sounds, player, _) ->
        check(sounds.stopAll(-500.0), "stopAll with a negative fade answered false")
        check(!player.isPlaying && !sounds.pause("tone"), "stopAll with a negative fade left a sound playing")
    }
    // A real fade still fades, and still ends in a stop.
    started().let { (sounds, player, handler) ->
        check(sounds.stop("tone", 2000.0), "stop")
        handler.advance(1000)
        check(player.isPlaying && near(player.volume, 0.5f), "half way through a 2000 ms fade-out should be playing at 0.5, was " + player.volume)
        handler.advance(1500)
        check(!player.isPlaying && !sounds.pause("tone"), "a fade-out must end in a stop")
    }
    // And a sound that does not exist is still false.
    check(!reader.stop("missing", 0.0), "stop of a sound that does not exist answers false")
    println("stop stops")
}
`), ['org.json:json:20240303'])
}, 300_000)
