package dev.craft.vulkantest

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Screenshots sample the actual Android-composited SurfaceView, not a CPU drawing. */
@RunWith(AndroidJUnit4::class)
class VulkanSurfaceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun output(): File {
        val path = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
            ?: throw AssertionError("Gradle native Vulkan evidence directory unavailable")
        return File(path, "vulkan-surface").apply { check(isDirectory || mkdirs()) }
    }
    private fun await(activity: VulkanActivity, message: String, predicate: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 30000
        while (SystemClock.uptimeMillis() < deadline) {
            activity.failure?.let { throw AssertionError(message, it) }
            if (predicate()) return
            SystemClock.sleep(20)
        }
        val metadata = "$message; frames=${activity.frames.get()}, sessions=${activity.sessions.get()}, nativeOwners=${NativeSurface.active()}, inputs=${activity.inputEvents.get()}, ${activity.timing}"
        runCatching {
            File(output(), "failure.txt").writeText(metadata)
            instrumentation.uiAutomation.takeScreenshot()?.let { image ->
                try { File(output(), "failure.png").outputStream().use { check(image.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
                finally { image.recycle() }
            }
        }
        fail("Timed out: $metadata")
    }
    private fun anchors(actual: IntArray, width: Int, height: Int, shift: Int, input: Boolean) {
        // Independent literals anchor the atlas, terrain triangle and glyphs.
        // A blank successful CPU renderer cannot qualify by matching itself.
        assertEquals(0xffe02040.toInt(), actual[(height / 4 + 8) * width + width / 4 + 8])
        assertEquals(0xff20c060.toInt(), actual[(height / 4) * width + 3 * width / 4])
        assertEquals(0xff2040e0.toInt(), actual[(3 * height / 4) * width + width / 4])
        assertEquals(0xffd0a020.toInt(), actual[(3 * height / 4) * width + 3 * width / 4])
        assertEquals(0xffffffff.toInt(), actual[9 * width + 9])
        assertEquals(0xffffffff.toInt(), actual[9 * width + 21])
        assertEquals(if (shift == 0) 0xffe02040.toInt() else 0xff000000.toInt(), actual[(height / 4) * width])
        assertEquals(0xffe02040.toInt(), actual[(height / 4) * width + 3])
        if (input) {
            // Requested click (40,30), independently of the coordinates the
            // handler forwards or its CPU oracle uses.
            for (y in 30..33) for (x in 40..43) assertEquals(0xffffffff.toInt(), actual[y * width + x])
            for ((x, y) in listOf(39 to 30, 44 to 30, 40 to 29, 40 to 34)) assertEquals(0xffe02040.toInt(), actual[y * width + x])
        }
    }
    private fun capture(activity: VulkanActivity, name: String, width: Int, height: Int, shift: Int = 0) {
        val position = IntArray(2)
        instrumentation.runOnMainSync {
            assertEquals(width, activity.surface.width)
            assertEquals(height, activity.surface.height)
            activity.surface.getLocationOnScreen(position)
        }
        val expected = activity.expectedPixels()
        assertEquals(width * height, expected.size)
        anchors(expected, width, height, shift, name == "input")
        // Rendering completion and display latch are separate. Require the
        // actual compositor to show the complete scene within the same
        // three-second display budget used by the Xlib native fixture.
        val deadline = SystemClock.uptimeMillis() + 3000
        do {
            val screenshot = instrumentation.uiAutomation.takeScreenshot()
            assertNotNull("Android display screenshot is unavailable", screenshot)
            var matches = false
            try {
                val actual = IntArray(width * height)
                screenshot.getPixels(actual, 0, width, position[0], position[1], width, height)
                val cropped = Bitmap.createBitmap(screenshot, position[0], position[1], width, height)
                try { File(output(), "$name.png").outputStream().use { check(cropped.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
                finally { cropped.recycle() }
                matches = expected.contentEquals(actual)
                if (matches) anchors(actual, width, height, shift, name == "input")
            } finally { screenshot.recycle() }
            if (matches) return
            SystemClock.sleep(10)
        } while (SystemClock.uptimeMillis() < deadline)
        fail("Actual displayed $name pixels differ from the independently anchored shared scene")
    }
    @Test fun actualVulkanFramesSurviveResizeBackgroundInputAndRepeatedDisposal() {
        val device = UiDevice.getInstance(instrumentation)
        var totalFrames = 0
        var sessions = 0
        var inputs = 0
        val artifacts = output()
        for (repetition in 0..1) {
            lateinit var activity: VulkanActivity
            ActivityScenario.launch(VulkanActivity::class.java).use { scenario ->
                scenario.onActivity { activity = it }
                await(activity, "61 changing native frames") { activity.frames.get() >= 61 }
                if (repetition == 0) capture(activity, "initial", 256, 192)
                val beforeShift = activity.frames.get()
                val next = device.wait(Until.findObject(By.text("Next frame")), 3000)
                assertNotNull("Native Next frame control is missing", next)
                next.click()
                await(activity, "a distinct frame selected through the native control") { activity.frames.get() > beforeShift }
                if (repetition == 0) capture(activity, "shifted", 256, 192, 1)
                val beforeResize = activity.frames.get()
                scenario.onActivity { it.resizeView() }
                await(activity, "native resize and new scene") { activity.frames.get() >= beforeResize + 61 }
                if (repetition == 0) capture(activity, "resized", 160, 120)
                val beforePause = activity.frames.get()
                val beforeSessions = activity.sessions.get()
                device.pressHome()
                await(activity, "background surface disposal") { NativeSurface.active() == 0 }
                instrumentation.targetContext.startActivity(android.content.Intent(instrumentation.targetContext, VulkanActivity::class.java)
                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                await(activity, "recreated native surface after foreground") {
                    activity.sessions.get() > beforeSessions && activity.frames.get() >= beforePause + 61
                }
                if (repetition == 0) capture(activity, "resumed", 160, 120)
                val position = IntArray(2)
                instrumentation.runOnMainSync { activity.surface.getLocationOnScreen(position) }
                val beforeInput = activity.frames.get()
                assertTrue(device.click(position[0] + 40, position[1] + 30))
                await(activity, "native pointer event and corresponding scene mark") {
                    activity.inputEvents.get() == 1 && activity.frames.get() > beforeInput
                }
                if (repetition == 0) capture(activity, "input", 160, 120, 2)
                totalFrames += activity.frames.get()
                sessions += activity.sessions.get()
                inputs += activity.inputEvents.get()
            }
            assertNull("Native lifecycle failed during disposal", activity.failure)
            assertEquals("A disposed Activity retained a native Vulkan/window owner", 0, NativeSurface.active())
        }
        assertEquals(2, inputs)
        assertTrue(sessions >= 4)
        assertTrue(totalFrames >= 370)
        File(artifacts, "verification.json").writeText(JSONObject()
            .put("status", "passed").put("nativeActivities", 2).put("nativeSessions", sessions)
            .put("actualGpuFrames", totalFrames).put("nativeInputEvents", inputs)
            .put("nativeCaptures", 5).put("fullDisplayedPixelsMatched", true)
            .put("webViewUsed", false).put("disposed", NativeSurface.active() == 0).toString(2))
    }
}
