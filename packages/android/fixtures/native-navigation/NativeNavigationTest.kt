package dev.craft.navigationtest

import android.content.Intent
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.SystemClock
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.webkit.WebView
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
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
        if (view.tag?.toString() == id || view.contentDescription?.toString() == id) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                find(view.getChildAt(index), id)?.let { return it }
            }
        }
        return null
    }

    private inline fun <reified T : View> containsType(view: View): Boolean {
        if (view is T) return true
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) if (containsType<T>(view.getChildAt(index))) return true
        }
        return false
    }

    private inline fun <reified T : View> findType(view: View): T? {
        if (view is T) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) findType<T>(view.getChildAt(index))?.let { return it }
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
        var tree = ""
        instrumentation.runOnMainSync { tree = describe(activity.window.decorView) }
        throw AssertionError("Timed out waiting for native control $id. View tree: $tree")
    }

    private fun describe(view: View): String {
        val own = "${view.javaClass.simpleName}[${view.contentDescription}]" +
            if (view is TextView) "=${view.text}" else ""
        if (view !is ViewGroup) return own
        return own + (0 until view.childCount).joinToString(prefix = "(", postfix = ")") {
            describe(view.getChildAt(it))
        }
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
            val root = awaitView(activity, "root")
            assertTrue("View did not render as LinearLayout", root is LinearLayout)
            assertTrue(name is EditText)
            val title = awaitView(activity, "home-title")
            assertTrue(title is TextView)
            assertEquals(Color.WHITE, (title as TextView).currentTextColor)
            val styled = awaitView(activity, "styled-row") as LinearLayout
            val styledFirst = awaitView(activity, "styled-first") as TextView
            val styledSecond = awaitView(activity, "styled-second") as TextView
            val density = activity.resources.displayMetrics.density
            assertEquals(LinearLayout.HORIZONTAL, styled.orientation)
            assertTrue(styled.indexOfChild(styledSecond) < styled.indexOfChild(styledFirst))
            assertEquals((10 * density).toInt(), styled.paddingLeft)
            assertEquals((5 * density).toInt(), styled.paddingTop)
            assertEquals(0.75f, styled.alpha)
            assertEquals("FIRST", styledFirst.text.toString())
            assertEquals(Color.rgb(0xfe, 0xdc, 0xba), styledFirst.currentTextColor)
            assertEquals(21f, styledFirst.textSize / density)
            assertTrue(styledFirst.typeface.style and Typeface.BOLD != 0)
            assertTrue(styledFirst.typeface.style and Typeface.ITALIC != 0)
            assertTrue(styledFirst.paintFlags and Paint.UNDERLINE_TEXT_FLAG != 0)
            assertEquals((70 * density).toInt(), styledFirst.layoutParams.width)
            val scroll = awaitView(activity, "native-scroll")
            val image = awaitView(activity, "native-image")
            assertTrue("ScrollView did not render an Android ScrollView", containsType<ScrollView>(scroll))
            val nativeScroller = findType<ScrollView>(scroll)!!
            instrumentation.runOnMainSync { nativeScroller.fullScroll(View.FOCUS_DOWN) }
            instrumentation.waitForIdleSync()
            assertTrue("native ScrollView did not move through overflow content", nativeScroller.scrollY > 0)
            assertTrue("Image did not render as ImageView", image is ImageView)
            assertTrue("Image data did not decode", (image as ImageView).drawable != null)
            assertEquals("Native pixel", image.contentDescription.toString())
            var imageInfo: AccessibilityNodeInfo? = null
            instrumentation.runOnMainSync { imageInfo = image.createAccessibilityNodeInfo() }
            assertEquals(ImageView::class.java.name, imageInfo?.className?.toString())
            instrumentation.runOnMainSync { image.performClick() }
            awaitText(activity, "native-caption", "Image taps: 1")
            val unsupported = awaitView(activity, "unsupported-image") as ImageView
            assertTrue(unsupported.drawable == null)
            assertTrue(unsupported.contentDescription.toString().contains("Unsupported image source"))
            assertNoWebView(activity)

            instrumentation.runOnMainSync {
                name.requestFocus()
                (name as EditText).setText("Ada")
            }
            awaitText(activity, "greeting", "Hello Ada")
            assertSame("View container was replaced after typing", root, awaitView(activity, "root"))
            assertSame("TextInput was replaced after typing", name, awaitView(activity, "name-input"))
            assertTrue("TextInput lost focus after typing", name.isFocused)

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
