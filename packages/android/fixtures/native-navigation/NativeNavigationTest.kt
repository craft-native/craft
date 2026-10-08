package dev.craft.navigationtest

import android.content.Intent
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.SystemClock
import android.text.InputFilter
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.webkit.WebView
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.recyclerview.widget.RecyclerView
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

    private fun containsType(view: View, type: Class<out View>): Boolean {
        if (type.isInstance(view)) return true
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                if (containsType(view.getChildAt(index), type)) return true
            }
        }
        return false
    }

    private fun <T : View> findType(view: View, type: Class<T>): T? {
        if (type.isInstance(view)) return type.cast(view)
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                findType(view.getChildAt(index), type)?.let { return it }
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

    private fun assertScrolls(scroll: ScrollView) {
        var viewportHeight = 0
        var contentHeight = 0
        repeat(50) {
            var moved = false
            instrumentation.runOnMainSync {
                viewportHeight = scroll.height
                contentHeight = scroll.getChildAt(0)?.height ?: 0
                if (contentHeight > viewportHeight) {
                    scroll.scrollTo(0, contentHeight - viewportHeight)
                    moved = scroll.scrollY > 0
                }
            }
            if (moved) return
            SystemClock.sleep(100)
        }
        throw AssertionError(
            "native ScrollView did not move through overflow content " +
                "(viewport=$viewportHeight, content=$contentHeight, offset=${scroll.scrollY})"
        )
    }

    @Test
    fun compiledBundleRendersNavigatesAndRetainsNativeControls() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            val name = awaitView(activity, "name-input")
            val root = awaitView(activity, "root")
            assertTrue("View did not render as LinearLayout", root is LinearLayout)
            assertTrue(name is EditText)
            val nameInput = name as EditText
            assertEquals(Color.rgb(0x94, 0xa3, 0xb8), nameInput.hintTextColors.defaultColor)
            assertEquals(Color.rgb(0x22, 0xc5, 0x5e), nameInput.highlightColor)
            assertTrue(nameInput.filters.any { it is InputFilter.LengthFilter })
            val notes = awaitView(activity, "notes-input")
            assertTrue("multiline TextInput should be an EditText", notes is EditText)
            assertFalse("multiline TextInput should not be single line", (notes as EditText).isSingleLine)
            assertEquals(3, notes.maxLines)
            assertEquals("Notes", notes.hint.toString())
            assertEquals(Color.rgb(0x22, 0xc5, 0x5e), notes.highlightColor)
            val title = awaitView(activity, "home-title")
            assertTrue(title is TextView)
            assertEquals(Color.WHITE, (title as TextView).currentTextColor)
            val disabled = awaitView(activity, "disabled-button") as Button
            assertFalse(disabled.isEnabled)
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
            awaitView(activity, "grid-wrap")
            val gridFirst = awaitView(activity, "grid-first")
            val gridSecond = awaitView(activity, "grid-second")
            val gridThird = awaitView(activity, "grid-third")
            assertEquals(gridFirst.top, gridSecond.top)
            assertTrue("grid columns did not lay out side by side", gridSecond.left > gridFirst.left)
            assertTrue("grid rows did not advance after the first track", gridThird.top > gridFirst.top)
            val growFirst = awaitView(activity, "flex-grow-first")
            val growSecond = awaitView(activity, "flex-grow-second")
            assertTrue("flexGrow did not consume remaining main-axis space", growFirst.width > growSecond.width)
            val link = awaitView(activity, "native-link")
            assertTrue("native link should be a TextView", link is TextView)
            assertEquals("Open native link", (link as TextView).text.toString())
            instrumentation.runOnMainSync { link.performClick() }
            assertEquals("link pressed", (awaitView(activity, "native-link-status") as TextView).text.toString())
            val toggle = awaitView(activity, "native-switch")
            assertTrue("native switch should be an Android Switch", toggle is Switch)
            val nativeSwitch = toggle as Switch
            assertTrue("native switch should start off", !nativeSwitch.isChecked)
            assertTrue("native switch should apply track tint", nativeSwitch.trackTintList != null)
            assertTrue("native switch should apply thumb tint", nativeSwitch.thumbTintList != null)
            instrumentation.runOnMainSync { nativeSwitch.performClick() }
            assertEquals("switch on", (awaitView(activity, "native-link-status") as TextView).text.toString())
            val slider = awaitView(activity, "native-slider")
            assertTrue("native slider should be a SeekBar", slider is SeekBar)
            instrumentation.runOnMainSync { (slider as SeekBar).progress = 800 }
            assertEquals("slider moved", (awaitView(activity, "native-link-status") as TextView).text.toString())
            assertEquals("0.8", (awaitView(activity, "slider-value") as TextView).text.toString())
            assertTrue("native indicator should be a ProgressBar", awaitView(activity, "native-indicator") is ProgressBar)
            val wrapped = awaitView(activity, "layout-wrap") as LinearLayout
            assertEquals("layout measured", (awaitView(activity, "layout-status") as TextView).text.toString())
            val bounded = awaitView(activity, "layout-min")
            val absolute = awaitView(activity, "layout-absolute")
            assertEquals((140 * density).toInt(), bounded.width)
            assertTrue(
                "absolute child ignored its local insets",
                absolute.left >= (8 * density).toInt() && absolute.top >= (8 * density).toInt()
            )
            assertTrue("wrapped child did not wrap", bounded.top < awaitView(activity, "layout-stretch").top)
            val scroll = awaitView(activity, "native-scroll")
            val image = awaitView(activity, "native-image")
            assertTrue("ScrollView did not render an Android ScrollView", containsType(scroll, ScrollView::class.java))
            val nativeScroller = findType(scroll, ScrollView::class.java)!!
            assertScrolls(nativeScroller)
            assertTrue("Image did not render as ImageView", image is ImageView)
            assertTrue("Image data did not decode", (image as ImageView).drawable != null)
            assertEquals("Native pixel", image.contentDescription.toString())
            awaitText(activity, "image-status", "image loaded")
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
            instrumentation.runOnMainSync { (name as EditText).onEditorAction(EditorInfo.IME_ACTION_DONE) }
            awaitText(activity, "name-submits", "Submits: 1")
            assertSame("View container was replaced after typing", root, awaitView(activity, "root"))
            assertSame("TextInput was replaced after typing", name, awaitView(activity, "name-input"))
            assertTrue("TextInput lost focus after typing", name.isFocused)

            click(activity, "increment")
            click(activity, "increment")
            awaitText(activity, "count", "Count: 2")

            click(activity, "open-details")
            assertEquals("Details for Ada", (awaitView(activity, "details-title") as TextView).text.toString())
            assertEquals("Count: 2", (awaitView(activity, "details-count") as TextView).text.toString())
            val people = awaitView(activity, "people-list") as RecyclerView
            val personZero = awaitView(activity, "person-label-person-0") as TextView
            val personInput = awaitView(activity, "person-input-person-0") as EditText
            instrumentation.runOnMainSync {
                personInput.requestFocus()
                personInput.setText("draft")
            }
            click(activity, "shuffle-people")
            awaitText(activity, "person-label-person-0", "1: Person zero updated")
            assertSame("keyed list update replaced a visible row", personZero, awaitView(activity, "person-label-person-0"))
            assertSame("keyed list update replaced a focused input", personInput, awaitView(activity, "person-input-person-0"))
            assertEquals("draft", personInput.text.toString())
            assertTrue("keyed list update dropped input focus", personInput.isFocused)
            instrumentation.runOnMainSync { people.scrollToPosition(people.adapter!!.itemCount - 1) }
            awaitText(activity, "people-count", "People: 41; events: 2")
            click(activity, "clear-people")
            assertEquals("Nobody here", (awaitView(activity, "people-empty") as TextView).text.toString())
            assertEquals("End of people", (awaitView(activity, "people-footer") as TextView).text.toString())
            awaitText(activity, "people-count", "People: 0; events: 3")
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
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }
}
