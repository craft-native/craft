import { test } from 'bun:test'
import { soundsProgram } from './sound-testing'
import { runKotlinFixture } from './testing'

/**
 * A sound paused during a fade resumes at the volume that was asked for.
 *
 * `CraftNativeSounds` kept one number per sound, `volume`, and a fade wrote
 * its in-flight value into it on every tick. So "the volume asked for" stopped
 * existing the moment a fade began: pausing cancels the fade where it stands,
 * and `resume` then played at whatever fraction the fade had reached — for
 * the rest of the sound's life.
 *
 *   play({ volume: 1, fadeIn: 2000 }) → pause at 500 ms → resume
 *     Android: plays at 0.25, permanently        UIKit: plays at 1
 *
 * UIKit keeps the asked-for volume separately (`sound.volume`, documented as
 * "the volume asked for; a fade in or out moves toward or away from it") and
 * `resume` restores it with `player.volume = sound.volume`. This holds Android
 * to the same result for the three fades there are: fade-in, a faded
 * `setVolume`, and a fade-out `stop` that a pause abandons.
 *
 * The class under test is the real one, lifted from the template. Android's
 * types are replaced by fakes with the same members so it runs on a JVM: a
 * player that records what it was told, and a handler whose clock the test
 * steps, so "500 ms into a 2000 ms fade" is exact rather than slept for.
 */
const scenario = `
fun near(actual: Float, wanted: Float) = kotlin.math.abs(actual - wanted) < 0.02f
fun check(condition: Boolean, message: String) { if (!condition) throw AssertionError(message) }

/** A prepared, playing sound and the fakes that drive it. */
internal fun started(options: String): Triple<CraftNativeSounds, MediaPlayer, Handler> {
    MediaPlayer.players.clear()
    val sounds = CraftNativeSounds(Context())
    sounds.play("tone", "https://example.test/tone.mp3", JSONObject(options)) {}
    val player = MediaPlayer.players.single()
    player.finishPreparing()
    return Triple(sounds, player, Handler.last)
}

fun main() {
    // Fade-in, paused a quarter of the way through.
    started("{\\"volume\\":1,\\"fadeIn\\":2000}").let { (sounds, player, handler) ->
        handler.advance(500)
        check(near(player.volume, 0.25f), "500 ms into a 2000 ms fade-in should be a quarter up, was " + player.volume)
        check(sounds.pause("tone"), "pause")
        handler.advance(5000)
        check(near(player.volume, 0.25f), "a paused sound must not go on fading, was " + player.volume)
        check(sounds.resume("tone"), "resume")
        check(near(player.volume, 1f), "resumed after a pause mid fade-in at " + player.volume + ", not the 1.0 that was asked for")
        handler.advance(5000)
        check(near(player.volume, 1f), "and stays there, was " + player.volume)
    }
    // A faded setVolume, paused half way.
    started("{\\"volume\\":1}").let { (sounds, player, handler) ->
        check(sounds.setVolume("tone", 0.2, 2000.0), "setVolume")
        handler.advance(1000)
        check(near(player.volume, 0.6f), "half way from 1 to 0.2 should be 0.6, was " + player.volume)
        sounds.pause("tone")
        sounds.resume("tone")
        check(near(player.volume, 0.2f), "resumed after a pause mid setVolume fade at " + player.volume + ", not the 0.2 that was asked for")
    }
    // A fade-out stop that a pause abandons: the sound survives, at its volume.
    started("{\\"volume\\":0.8}").let { (sounds, player, handler) ->
        check(sounds.stop("tone", 2000.0), "stop")
        handler.advance(1000)
        check(near(player.volume, 0.4f), "half way out from 0.8 should be 0.4, was " + player.volume)
        sounds.pause("tone")
        check(sounds.resume("tone"), "the pause abandoned the stop, so the sound is still there to resume")
        check(near(player.volume, 0.8f), "resumed after an abandoned fade-out at " + player.volume + ", not the 0.8 that was asked for")
    }
    // An instant setVolume while paused is what resume lands on.
    started("{\\"volume\\":1}").let { (sounds, player, _) ->
        sounds.pause("tone")
        sounds.setVolume("tone", 0.3, 0.0)
        sounds.resume("tone")
        check(near(player.volume, 0.3f), "resumed at " + player.volume + " after setVolume(0.3) while paused")
    }
    // UIKit answers false for a sound that is not paused; so must this.
    started("{\\"volume\\":1}").let { (sounds, player, _) ->
        check(!sounds.resume("tone"), "resume of a sound that is already playing must answer false, as UIKit does")
        check(player.isPlaying, "and must leave it playing")
        check(!sounds.resume("missing"), "resume of a sound that does not exist answers false")
    }
    println("a sound paused during a fade resumes at the volume that was asked for")
}
`

test('a sound paused mid-fade resumes at the asked-for volume, and resume answers as UIKit does', async () => {
  await runKotlinFixture(soundsProgram(scenario), ['org.json:json:20240303'])
}, 300_000)
