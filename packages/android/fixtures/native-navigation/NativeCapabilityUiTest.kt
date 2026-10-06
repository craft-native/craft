package dev.craft.navigationtest

import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeCapabilityUiTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun find(view: View, id: String): View? {
        if (view.tag?.toString() == id || view.contentDescription?.toString() == id) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) find(view.getChildAt(index), id)?.let { return it }
        }
        return null
    }

    private fun await(activity: MainActivity, id: String): View {
        repeat(100) {
            var found: View? = null
            instrumentation.runOnMainSync { found = find(activity.window.decorView, id) }
            if (found != null) return found!!
            SystemClock.sleep(100)
        }
        throw AssertionError("Timed out waiting for native control $id")
    }

    private fun awaitText(activity: MainActivity, id: String, text: String) {
        repeat(100) {
            var match = false
            instrumentation.runOnMainSync {
                match = (find(activity.window.decorView, id) as? TextView)?.text?.toString() == text
            }
            if (match) return
            SystemClock.sleep(100)
        }
        throw AssertionError("Timed out waiting for $id to read $text")
    }

    private fun click(activity: MainActivity, id: String) {
        val view = await(activity, id)
        assertTrue("$id is not a Button", view is Button)
        instrumentation.runOnMainSync { view.performClick() }
    }

    private fun launch(): MainActivity = instrumentation.startActivitySync(
        Intent(instrumentation.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
    ) as MainActivity

    @Test
    fun persistentCapabilitiesSurviveActivityRelaunch() {
        var activity = launch()
        try {
            click(activity, "open-capabilities")
            assertEquals("Platform: android", (await(activity, "capabilities-platform") as TextView).text.toString())
            click(activity, "save-capabilities")
            awaitText(activity, "capabilities-status", "Saved Ada and Grace")
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()

            activity = launch()
            click(activity, "open-capabilities")
            click(activity, "load-capabilities")
            awaitText(activity, "capabilities-status", "Loaded Ada and Grace")
        }
        finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }
}
