import { expect } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * `CraftNativeSounds` as shipped, and stand-ins for the Android types it
 * touches, so its tests run the real class on a JVM: a player that records
 * what it was told, and a handler whose clock a test steps, so "500 ms into a
 * 2000 ms fade" is exact rather than slept for.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeSounds.kt.template'), 'utf8')

/** The class as shipped, minus the package line and the Android imports. */
export function soundsSource(): string {
  const body = template
    .replace(/^package [^\n]*\n/m, '')
    .replace(/^import android\.[^\n]*\n/gm, '')
    // Fully qualified in the template, so it cannot be shadowed by a fake.
    .replaceAll('android.os.SystemClock.uptimeMillis()', 'SystemClock.uptimeMillis()')
  expect(body, 'the class must still be here to test').toContain('internal class CraftNativeSounds(')
  expect(body, 'no Android import may survive into the JVM fixture').not.toMatch(/^import android\./m)
  return body
}

export const soundFakes = `
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


/** A whole fixture program: the fakes, the shipped class, then the scenario. */
export function soundsProgram(scenario: string): string {
  return `import org.json.JSONObject\nimport java.io.File\nimport kotlin.math.max\nimport kotlin.math.min\n${soundFakes}\n${soundsSource().replace(/^import [^\n]*\n/gm, '')}\n${scenario}`
}
