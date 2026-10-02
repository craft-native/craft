package dev.craft.navigationtest

import android.content.Intent
import android.os.SystemClock
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeNavigationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun find(view: View, id: String): View? {
        if (view.contentDescription?.toString() == id) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                find(view.getChildAt(index), id)?.let { return it }
            }
        }
        return null
    }

    private fun containsWebView(view: View): Boolean {
        if (view is WebView) return true
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                if (containsWebView(view.getChildAt(index))) return true
            }
        }
        return false
    }

    private fun awaitView(activity: MainActivity, id: String): View {
        repeat(75) {
            var found: View? = null
            instrumentation.runOnMainSync { found = find(activity.window.decorView, id) }
            if (found != null) return found!!
            SystemClock.sleep(200)
        }
        throw AssertionError("Timed out waiting for native control $id")
    }

    private fun click(activity: MainActivity, id: String) {
        val view = awaitView(activity, id)
        assertTrue("$id is not an Android Button", view is Button)
        instrumentation.runOnMainSync { view.performClick() }
    }

    private fun awaitText(activity: MainActivity, id: String, expected: String): TextView {
        repeat(75) {
            var matching: TextView? = null
            instrumentation.runOnMainSync {
                val view = find(activity.window.decorView, id)
                if (view is TextView && view.text.toString() == expected) matching = view
            }
            if (matching != null) return matching!!
            SystemClock.sleep(100)
        }
        throw AssertionError("Timed out waiting for $id to read $expected")
    }

    private fun assertNoWebView(activity: MainActivity) {
        var present = false
        instrumentation.runOnMainSync { present = containsWebView(activity.window.decorView) }
        assertFalse("Native STX route created a WebView instance", present)
    }

    @Test
    fun compiledBundleRendersNavigatesAndRetainsNativeControls() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ) as MainActivity
        try {
            val name = awaitView(activity, "name-input")
            assertTrue("View did not render as LinearLayout", awaitView(activity, "root") is LinearLayout)
            assertTrue(name is EditText)
            assertTrue(awaitView(activity, "home-title") is TextView)
            assertNoWebView(activity)

            instrumentation.runOnMainSync { (name as EditText).setText("Ada") }
            awaitText(activity, "greeting", "Hello Ada")
            assertSame("TextInput was replaced after typing", name, awaitView(activity, "name-input"))

            click(activity, "increment")
            click(activity, "increment")
            awaitText(activity, "count", "Count: 2")

            click(activity, "open-details")
            assertEquals("Details for Ada", (awaitView(activity, "details-title") as TextView).text.toString())
            assertEquals("Count: 2", (awaitView(activity, "details-count") as TextView).text.toString())
            assertNoWebView(activity)

            instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            assertSame("Returning rebuilt the home input", name, awaitView(activity, "name-input"))
            assertEquals("Ada", (name as EditText).text.toString())
            assertEquals("Count: 2", (awaitView(activity, "count") as TextView).text.toString())

            click(activity, "open-details")
            awaitView(activity, "details-title")
            click(activity, "details-back")
            assertSame(name, awaitView(activity, "name-input"))

            click(activity, "open-details")
            awaitView(activity, "details-title")
            click(activity, "open-summary")
            assertEquals("Summary for Ada", (awaitView(activity, "summary-title") as TextView).text.toString())
            assertNoWebView(activity)
            instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            assertSame("Replace kept details on the stack", name, awaitView(activity, "name-input"))
        }
        finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }
}
