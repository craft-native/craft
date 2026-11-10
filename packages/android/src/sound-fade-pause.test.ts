import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
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
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeSounds.kt.template'), 'utf8')

/** The class as shipped, minus the package line and the Android imports. */
function soundsSource(): string {
  const body = template
    .replace(/^package [^\n]*\n/m, '')
    .replace(/^import android\.[^\n]*\n/gm, '')
    // Fully qualified in the template, so it cannot be shadowed by a fake.
    .replaceAll('android.os.SystemClock.uptimeMillis()', 'SystemClock.uptimeMillis()')
  expect(body, 'the class must still be here to test').toContain('internal class CraftNativeSounds(')
  expect(body, 'no Android import may survive into the JVM fixture').not.toMatch(/^import android\./m)
  return body
}

const fakes = `
object SystemClock { var now = 0L; fun uptimeMillis(): Long = now }
class Looper { companion object { private val main = Looper(); fun getMainLooper(): Looper = main } }
/** Runs what is due when the test advances the clock, in due order. */
class Handler(@Suppress("UNUSED_PARAMETER") looper: Looper) {
    private val queue = mutableListOf<Pair<Long, Runnable>>()
    fun post(task: Runnable): Boolean = postDelayed(task, 0)
    fun postDelayed(task: Runnable, delay: Long): Boolean { queue.add(SystemClock.now + delay to task); return true }
    fun removeCallbacks(task: Runnable) { queue.removeAll { it.second === task } }
    fun advance(milliseconds: Long) {
        val until = SystemClock.now + milliseconds
        while (true) {
            val next = queue.filter { it.first <= until }.minByOrNull { it.first } ?: break
            queue.remove(next)
            SystemClock.now = maxOf(SystemClock.now, next.first)
            next.second.run()
        }
        SystemClock.now = until
    }
    companion object { lateinit var last: Handler }
    init { last = this }
}
class Uri(val text: String) {
    val scheme: String? get() = text.substringBefore("://", "").ifEmpty { null }
    override fun toString() = text
    companion object { fun parse(text: String) = Uri(text); fun fromFile(file: File) = Uri("file://" + file.path) }
}
class AudioAttributes {
    class Builder { fun setUsage(value: Int) = this; fun setContentType(value: Int) = this; fun build() = AudioAttributes() }
    companion object { const val USAGE_GAME = 14; const val CONTENT_TYPE_MUSIC = 2 }
}
class AudioFocusRequest {
    class Builder(@Suppress("UNUSED_PARAMETER") gain: Int) {
        fun setAudioAttributes(value: AudioAttributes) = this
        fun setAcceptsDelayedFocusGain(value: Boolean) = this
        fun setOnAudioFocusChangeListener(listener: (Int) -> Unit, handler: Handler) = this
        fun build() = AudioFocusRequest()
    }
}
class AudioManager {
    fun requestAudioFocus(request: AudioFocusRequest): Int = AUDIOFOCUS_REQUEST_GRANTED
    fun abandonAudioFocusRequest(request: AudioFocusRequest): Int = AUDIOFOCUS_REQUEST_GRANTED
    companion object {
        const val AUDIOFOCUS_GAIN = 1; const val AUDIOFOCUS_LOSS = -1
        const val AUDIOFOCUS_LOSS_TRANSIENT = -2; const val AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK = -3
        const val AUDIOFOCUS_REQUEST_GRANTED = 1
    }
}
class Context {
    fun getSystemService(name: String): Any = AudioManager()
    companion object { const val AUDIO_SERVICE = "audio" }
}
object CraftNativeMedia { fun local(context: Context, address: String): File? = null }
data class CraftNativeCapabilityResult(val data: Any? = null, val code: String? = null, val message: String? = null)
/** Records the last volume it was given and whether it is playing. */
class MediaPlayer {
    var isLooping = false
    var isPlaying = false
    var volume = -1f
    private var prepared: (() -> Unit)? = null
    fun setAudioAttributes(value: AudioAttributes) {}
    fun setVolume(left: Float, right: Float) { volume = left }
    fun setOnPreparedListener(listener: ((MediaPlayer) -> Unit)?) { prepared = listener?.let { { it(this) } } }
    fun setOnCompletionListener(listener: ((MediaPlayer) -> Unit)?) {}
    fun setOnErrorListener(listener: ((MediaPlayer, Int, Int) -> Boolean)?) {}
    fun setDataSource(context: Context, uri: Uri) {}
    fun prepareAsync() { players.add(this) }
    fun start() { isPlaying = true }
    fun pause() { isPlaying = false }
    fun stop() { isPlaying = false }
    fun release() {}
    fun finishPreparing() { prepared?.invoke() }
    companion object { val players = mutableListOf<MediaPlayer>() }
}
`

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
  await runKotlinFixture(`import org.json.JSONObject\nimport java.io.File\nimport kotlin.math.max\nimport kotlin.math.min\n${fakes}\n${soundsSource().replace(/^import [^\n]*\n/gm, '')}\n${scenario}`, ['org.json:json:20240303'])
}, 300_000)
