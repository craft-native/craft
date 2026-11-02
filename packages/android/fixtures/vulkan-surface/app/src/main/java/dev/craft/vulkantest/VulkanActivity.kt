package dev.craft.vulkantest

import android.app.Activity
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Choreographer
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowInsets
import android.widget.FrameLayout
import android.widget.Button
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

object NativeSurface {
    init { System.loadLibrary("craft-vulkan-acceptance") }
    external fun create(surface: Surface, width: Int, height: Int): Long
    external fun resize(handle: Long, surface: Surface, width: Int, height: Int)
    external fun draw(handle: Long, frame: Int, x: Int, y: Int)
    external fun suspend(handle: Long, suspended: Boolean)
    external fun pixels(handle: Long): IntArray
    external fun close(handle: Long)
    external fun diagnostics(handle: Long): String
    external fun active(): Int
}

/** A caller-owned SurfaceView, using the published native surface interface. */
class VulkanActivity : Activity(), SurfaceHolder.Callback {
    lateinit var surface: SurfaceView
        private set
    val frames = AtomicInteger()
    val sessions = AtomicInteger()
    val inputEvents = AtomicInteger()
    @Volatile var timing = "not created"
        private set
    @Volatile var failure: Throwable? = null
        private set
    private val thread = HandlerThread("Craft Vulkan owner")
    private lateinit var renderer: Handler
    private var handle = 0L // accessed only on the owning render thread
    private var generation = 0 // accessed only on the main thread
    private var frame = 0
    private var requested = false
    private var paused = false
    private var destroyed = false
    private var surfaceReady = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        thread.start()
        renderer = Handler(thread.looper)
        surface = SurfaceView(this)
        surface.holder.addCallback(this)
        surface.setOnTouchListener { _, event ->
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                val x = event.x.toInt(); val y = event.y.toInt()
                inputEvents.incrementAndGet()
                owned { if (handle != 0L) { NativeSurface.draw(handle, 66, x, y); frames.incrementAndGet() } }
                true
            } else true
        }
        setContentView(FrameLayout(this).apply {
            // Android35 enforces edge-to-edge. Keep real native controls clear
            // of the system navigation gesture/button region.
            setOnApplyWindowInsetsListener { view, insets ->
                if (Build.VERSION.SDK_INT >= 30) {
                    val bars = insets.getInsets(WindowInsets.Type.systemBars())
                    view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                } else {
                    view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                        insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                }
                insets
            }
            addView(surface, FrameLayout.LayoutParams(256, 192, Gravity.CENTER))
            addView(Button(this@VulkanActivity).apply {
                text = "Next frame"
                isAllCaps = false
                setOnClickListener {
                    owned {
                        if (handle != 0L) { NativeSurface.draw(handle, 61, -1, -1); timing = NativeSurface.diagnostics(handle); frames.incrementAndGet() }
                    }
                }
            }, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
        })
    }
    private fun owned(work: () -> Unit) {
        renderer.post {
            if (failure == null) try { work() } catch (error: Throwable) { failure = error }
        }
    }
    fun <T> read(work: () -> T): T {
        val task = FutureTask<T> { work() }
        renderer.post(task)
        return task.get(5, TimeUnit.SECONDS)
    }
    fun expectedPixels(): IntArray = read { check(handle != 0L); NativeSurface.pixels(handle) }
    fun resizeView() {
        surface.layoutParams = FrameLayout.LayoutParams(160, 120, Gravity.CENTER)
    }
    override fun surfaceCreated(holder: SurfaceHolder) = Unit
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        val surface = holder.surface
        val callback = "callback=${width}x${height}, view=${this.surface.width}x${this.surface.height}, measured=${this.surface.measuredWidth}x${this.surface.measuredHeight}, holderFrame=${holder.surfaceFrame}"
        val suspended = paused
        val selected = ++generation
        requested = false
        surfaceReady = false
        owned {
            if (handle == 0L) { handle = NativeSurface.create(surface, width, height); sessions.incrementAndGet() }
            else try { NativeSurface.resize(handle, surface, width, height) } catch (error: Throwable) { throw IllegalStateException(callback, error) }
            timing = NativeSurface.diagnostics(handle)
            NativeSurface.suspend(handle, suspended)
            runOnUiThread {
                if (selected == generation && !destroyed) {
                    surfaceReady = true
                    frame = 0
                    scheduleFrame()
                }
            }
        }
    }
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        generation++
        requested = false
        surfaceReady = false
        try { read { if (handle != 0L) { NativeSurface.close(handle); handle = 0L } } }
        catch (error: Throwable) { failure = error }
    }
    private fun scheduleFrame() {
        if (!surfaceReady || requested || paused || destroyed || frame > 60) return
        requested = true
        val selected = generation
        Choreographer.getInstance().postFrameCallback {
            if (selected != generation) return@postFrameCallback
            requested = false
            if (paused || destroyed || !surface.holder.surface.isValid) return@postFrameCallback
            val next = frame++
            owned {
                if (handle != 0L) { NativeSurface.draw(handle, next, -1, -1); timing = NativeSurface.diagnostics(handle); frames.incrementAndGet() }
                runOnUiThread { scheduleFrame() }
            }
        }
    }
    override fun onPause() {
        paused = true
        owned { if (handle != 0L) NativeSurface.suspend(handle, true) }
        super.onPause()
    }
    override fun onResume() {
        super.onResume()
        paused = false
        owned { if (handle != 0L) NativeSurface.suspend(handle, false) }
        scheduleFrame()
    }
    override fun onDestroy() {
        destroyed = true
        surface.holder.removeCallback(this)
        generation++
        try { read { if (handle != 0L) { NativeSurface.close(handle); handle = 0L } } }
        catch (error: Throwable) { failure = error }
        thread.quitSafely()
        thread.join(5000)
        if (thread.isAlive) failure = IllegalStateException("Native render thread did not stop")
        super.onDestroy()
    }
}
