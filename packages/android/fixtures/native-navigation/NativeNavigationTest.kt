package dev.craft.navigationtest

import android.content.Intent
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.text.InputFilter
import android.text.InputType
import android.text.Layout
import android.view.KeyEvent
import android.view.MotionEvent
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
import android.widget.Spinner
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

    private fun awaitLayoutIncrease(activity: MainActivity, id: String, baseline: Int): TextView {
        repeat(75) {
            var matching: TextView? = null
            instrumentation.runOnMainSync {
                val view = find(activity.window.decorView, id)
                if (view is TextView && view.text.toString().substringAfterLast(": ").toIntOrNull()?.let { it > baseline } == true) {
                    matching = view
                }
            }
            if (matching != null) return matching!!
            SystemClock.sleep(100)
        }
        throw AssertionError("Timed out waiting for $id layout count to exceed $baseline")
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
            assertEquals(
                InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
                nameInput.inputType and InputType.TYPE_MASK_VARIATION,
            )
            assertEquals(EditorInfo.IME_ACTION_DONE, nameInput.imeOptions and EditorInfo.IME_MASK_ACTION)
            click(activity, "toggle-input-colors")
            assertEquals("input colors off", (awaitView(activity, "input-style-status") as TextView).text.toString())
            assertSame("Removing input colors replaced the native field", nameInput, awaitView(activity, "name-input"))
            click(activity, "toggle-input-colors")
            assertEquals("input colors on", (awaitView(activity, "input-style-status") as TextView).text.toString())
            assertSame("Restoring input colors replaced the native field", nameInput, awaitView(activity, "name-input"))
            val notes = awaitView(activity, "notes-input")
            assertTrue("multiline TextInput should be an EditText", notes is EditText)
            assertFalse("multiline TextInput should not be single line", (notes as EditText).isSingleLine)
            assertEquals(3, notes.maxLines)
            assertEquals("Draft", (notes as EditText).text.toString())
            assertEquals("Notes", notes.hint.toString())
            assertEquals(Color.rgb(0x22, 0xc5, 0x5e), notes.highlightColor)
            val readonly = awaitView(activity, "readonly-input") as EditText
            assertTrue("editable=false should disable the native input", !readonly.isEnabled)
            assertEquals("Read only", readonly.text.toString())
            val password = awaitView(activity, "password-input") as EditText
            assertEquals(InputType.TYPE_TEXT_VARIATION_PASSWORD, password.inputType and InputType.TYPE_MASK_VARIATION)
            val title = awaitView(activity, "home-title")
            assertTrue(title is TextView)
            assertEquals(Color.WHITE, (title as TextView).currentTextColor)
            assertEquals("Text accessibility should use visible content, not its test identity", null, title.contentDescription)
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
            assertTrue(link.contentDescription.toString().contains("ready"))
            assertEquals("Opens status", link.tooltipText)
            instrumentation.runOnMainSync { link.performClick() }
            assertEquals("link pressed", (awaitView(activity, "native-link-status") as TextView).text.toString())
            click(activity, "toggle-link-accessibility")
            awaitText(activity, "native-link-status", "link accessibility disabled")
            assertTrue("accessibilityState.disabled should disable the link", !link.isEnabled)
            click(activity, "toggle-link-accessibility")
            awaitText(activity, "native-link-status", "link accessibility enabled")
            assertTrue("clearing accessibilityState.disabled should restore the link", link.isEnabled)
            instrumentation.runOnMainSync { link.performClick() }
            assertEquals("link pressed", (awaitView(activity, "native-link-status") as TextView).text.toString())
            val panel = awaitView(activity, "native-panel")
            instrumentation.runOnMainSync { panel.performClick() }
            assertEquals("panel pressed", (awaitView(activity, "native-link-status") as TextView).text.toString())
            click(activity, "toggle-panel-accessibility")
            awaitText(activity, "native-link-status", "panel accessibility disabled")
            assertFalse("accessibilityState.disabled should disable a generic pressable", panel.isEnabled)
            click(activity, "toggle-panel-accessibility")
            awaitText(activity, "native-link-status", "panel accessibility enabled")
            assertTrue("clearing accessibilityState.disabled should restore a generic pressable", panel.isEnabled)
            instrumentation.runOnMainSync { panel.performClick() }
            assertEquals("panel pressed", (awaitView(activity, "native-link-status") as TextView).text.toString())
            val pressable = awaitView(activity, "native-pressable")
            assertTrue("native Pressable should be a container", pressable is ViewGroup)
            instrumentation.runOnMainSync { pressable.performClick() }
            assertEquals("pressable pressed", (awaitView(activity, "native-link-status") as TextView).text.toString())
            val disabledPressable = awaitView(activity, "disabled-pressable")
            assertFalse("disabled Pressable should be disabled", disabledPressable.isEnabled)
            instrumentation.runOnMainSync { disabledPressable.performClick() }
            assertEquals("pressable pressed", (awaitView(activity, "native-link-status") as TextView).text.toString())
            val longPressPanel = awaitView(activity, "long-press-panel")
            assertTrue("generic onLongPress view was not long-clickable", longPressPanel.performLongClick())
            assertEquals("panel long pressed", (awaitView(activity, "long-press-status") as TextView).text.toString())
            click(activity, "toggle-long-press-accessibility")
            assertEquals("long press disabled", (awaitView(activity, "long-press-status") as TextView).text.toString())
            assertTrue("disabled long-press view remained enabled", !longPressPanel.isEnabled)
            assertTrue("disabled long-press view still accepted a click", !longPressPanel.performLongClick())
            click(activity, "toggle-long-press-accessibility")
            assertEquals("long press enabled", (awaitView(activity, "long-press-status") as TextView).text.toString())
            assertTrue("re-enabled long-press view did not accept a click", longPressPanel.performLongClick())
            assertEquals("panel long pressed", (awaitView(activity, "long-press-status") as TextView).text.toString())
            click(activity, "toggle-image-tint")
            assertEquals("image tint off", (awaitView(activity, "image-status") as TextView).text.toString())
            val image = awaitView(activity, "native-image") as ImageView
            assertTrue("image tint did not clear on style update", image.colorFilter == null)
            val unsupported = awaitView(activity, "unsupported-image") as ImageView
            assertEquals(1, unsupported.contentDescription.toString().split("Unsupported image source").size - 1)
            val styleToggle = awaitView(activity, "toggle-button-style") as Button
            var styleInfo: AccessibilityNodeInfo? = null
            instrumentation.runOnMainSync { styleInfo = styleToggle.createAccessibilityNodeInfo() }
            assertTrue("selected accessibility state should start clear", styleInfo?.isSelected == false)
            click(activity, "toggle-button-style")
            assertEquals("button style accented", (awaitView(activity, "native-link-status") as TextView).text.toString())
            val accentedButton = awaitView(activity, "toggle-button-style") as Button
            assertEquals(Color.rgb(0xef, 0x44, 0x44), accentedButton.currentTextColor)
            instrumentation.runOnMainSync { styleInfo = accentedButton.createAccessibilityNodeInfo() }
            assertTrue("selected accessibility state was not exposed", styleInfo?.isSelected == true)
            val dynamicStyleBox = awaitView(activity, "dynamic-style-box")
            assertTrue("custom panel style should use a GradientDrawable", dynamicStyleBox.background is GradientDrawable)
            click(activity, "toggle-panel-style")
            awaitText(activity, "panel-style-status", "panel style off")
            assertTrue("removing panel style should restore the default background", dynamicStyleBox.background == null)
            click(activity, "toggle-panel-style")
            awaitText(activity, "panel-style-status", "panel style on")
            assertTrue("restoring panel style should recreate its drawable", dynamicStyleBox.background is GradientDrawable)
            val nullWidthText = awaitView(activity, "null-width-text")
            val explicitTextWidth = nullWidthText.width
            assertTrue("explicit text width was not applied", explicitTextWidth > (150 * density).toInt())
            click(activity, "toggle-null-width")
            repeat(20) {
                if (nullWidthText.width < explicitTextWidth - (20 * density).toInt()) return@repeat
                SystemClock.sleep(100)
            }
            assertTrue("null width should restore intrinsic text sizing", nullWidthText.width < explicitTextWidth - (20 * density).toInt())
            val toggle = awaitView(activity, "native-switch")
            assertTrue("native switch should be an Android Switch", toggle is Switch)
            val nativeSwitch = toggle as Switch
            assertTrue("native switch should start off", !nativeSwitch.isChecked)
            assertTrue("native switch should apply track tint", nativeSwitch.trackTintList != null)
            assertTrue("native switch should apply thumb tint", nativeSwitch.thumbTintList != null)
            assertTrue("null switch value should fall back to checked", (awaitView(activity, "nullable-switch") as Switch).isChecked)
            val picker = awaitView(activity, "native-picker")
            assertTrue("native picker should be an Android Spinner", picker is Spinner)
            assertEquals("one", (awaitView(activity, "picker-value") as TextView).text.toString())
            instrumentation.runOnMainSync { (picker as Spinner).setSelection(1) }
            awaitText(activity, "picker-value", "two")
            assertEquals("picker two", (awaitView(activity, "native-link-status") as TextView).text.toString())
            val modal = awaitView(activity, "native-modal")
            assertTrue("native modal should be a container", modal is ViewGroup)
            assertEquals("modal should start hidden", View.GONE, modal.visibility)
            click(activity, "toggle-modal")
            repeat(20) {
                if (modal.visibility == View.VISIBLE) return@repeat
                SystemClock.sleep(100)
            }
            assertEquals("modal should become visible", View.VISIBLE, modal.visibility)
            assertEquals("Modal content", (awaitView(activity, "modal-content") as TextView).text.toString())
            assertEquals("modal shown", (awaitView(activity, "modal-status") as TextView).text.toString())
            click(activity, "toggle-modal")
            awaitText(activity, "modal-status", "modal dismissed")
            click(activity, "toggle-modal")
            awaitText(activity, "modal-status", "modal shown")
            instrumentation.runOnMainSync { activity.onBackPressed() }
            awaitText(activity, "modal-status", "modal requested")
            val justifiedText = awaitView(activity, "justified-text") as TextView
            assertEquals("justified text should use the Android inter-word mode", Layout.JUSTIFICATION_MODE_INTER_WORD, justifiedText.justificationMode)
            instrumentation.runOnMainSync { nativeSwitch.performClick() }
            assertEquals("switch on", (awaitView(activity, "native-link-status") as TextView).text.toString())
            var switchInfo: AccessibilityNodeInfo? = null
            instrumentation.runOnMainSync { switchInfo = nativeSwitch.createAccessibilityNodeInfo() }
            assertTrue("checked accessibility state was not exposed", switchInfo?.isChecked == true)
            val slider = awaitView(activity, "native-slider")
            assertTrue("native slider should be a SeekBar", slider is SeekBar)
            instrumentation.runOnMainSync { (slider as SeekBar).progress = 845 }
            assertEquals("slider moved", (awaitView(activity, "native-link-status") as TextView).text.toString())
            assertEquals("0.8", (awaitView(activity, "slider-value") as TextView).text.toString())
            val nativeSlider = slider as SeekBar
            assertEquals("slider thumb should snap to its step", 800, nativeSlider.progress)
            instrumentation.runOnMainSync {
                val downTime = SystemClock.uptimeMillis()
                val y = nativeSlider.height / 2f
                val end = nativeSlider.width.toFloat().coerceAtLeast(1f) * 0.8f
                val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, 0f, y, 0)
                val move = MotionEvent.obtain(downTime, downTime + 16, MotionEvent.ACTION_MOVE, end, y, 0)
                val up = MotionEvent.obtain(downTime, downTime + 32, MotionEvent.ACTION_UP, end, y, 0)
                try {
                    nativeSlider.dispatchTouchEvent(down)
                    nativeSlider.dispatchTouchEvent(move)
                    nativeSlider.dispatchTouchEvent(up)
                } finally {
                    down.recycle()
                    move.recycle()
                    up.recycle()
                }
            }
            awaitText(activity, "slider-completions", "Slider completions: 1")
            assertTrue("native indicator should be a ProgressBar", awaitView(activity, "native-indicator") is ProgressBar)
            val stoppedIndicator = awaitView(activity, "stopped-indicator") as ProgressBar
            assertTrue("stopped indicator should stay visible when requested", stoppedIndicator.isShown)
            assertTrue("stopped indicator should not animate", !stoppedIndicator.isIndeterminate)
            assertEquals(0.75f, stoppedIndicator.scaleX)
            val wrapped = awaitView(activity, "layout-wrap") as LinearLayout
            assertEquals("Layout width: 240", (awaitView(activity, "layout-status") as TextView).text.toString())
            click(activity, "toggle-layout-width")
            awaitText(activity, "layout-status", "Layout width: 180")
            val bounded = awaitView(activity, "layout-min")
            val absolute = awaitView(activity, "layout-absolute")
            assertEquals((140 * density).toInt(), bounded.width)
            assertTrue(
                "absolute child ignored its trailing insets",
                absolute.right <= wrapped.width - (8 * density).toInt() && absolute.bottom <= wrapped.height - (8 * density).toInt()
            )
            assertTrue("wrapped child did not wrap", bounded.top < awaitView(activity, "layout-stretch").top)
            val scroll = awaitView(activity, "native-scroll")
            val image = awaitView(activity, "native-image")
            assertTrue("ScrollView did not render an Android ScrollView", containsType(scroll, ScrollView::class.java))
            val nativeScroller = findType(scroll, ScrollView::class.java)!!
            assertTrue("ScrollView contentContainerStyle did not add top padding", image.top >= nativeScroller.top + (12 * density).toInt())
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
            assertTrue("image accessibility label was lost on failure", unsupported.contentDescription.toString().contains("Unsupported image"))
            assertTrue(unsupported.contentDescription.toString().contains("Unsupported image source"))
            awaitText(activity, "image-error-status", "image failed")
            click(activity, "toggle-image-source")
            awaitText(activity, "image-status", "image loaded")
            assertTrue("image source recovery did not decode", unsupported.drawable != null)
            assertEquals("image error metadata was not cleared on recovery", "Unsupported image", unsupported.contentDescription.toString())
            assertNoWebView(activity)

            instrumentation.runOnMainSync {
                name.requestFocus()
                (name as EditText).setText("Ada")
            }
            awaitText(activity, "name-focuses", "Focuses: 1")
            awaitText(activity, "greeting", "Hello Ada")
            click(activity, "toggle-name-mode")
            val multilineName = awaitView(activity, "name-input") as EditText
            assertFalse("multiline mode did not replace the single-line input", multilineName.isSingleLine)
            assertEquals("Ada", multilineName.text.toString())
            assertEquals("multiline", (awaitView(activity, "name-mode") as TextView).text.toString())
            click(activity, "toggle-name-mode")
            val singleLineName = awaitView(activity, "name-input") as EditText
            assertTrue("single-line mode did not restore the input", singleLineName.isSingleLine)
            assertEquals("Ada", singleLineName.text.toString())
            assertEquals("single-line", (awaitView(activity, "name-mode") as TextView).text.toString())
            instrumentation.runOnMainSync { singleLineName.onEditorAction(EditorInfo.IME_ACTION_DONE) }
            awaitText(activity, "name-submits", "Submits: 1")
            instrumentation.runOnMainSync {
                notes.requestFocus()
            }
            awaitText(activity, "notes-focus-text", "Notes focus: Draft")
            awaitText(activity, "name-blurs", "Blurs: 1")
            awaitText(activity, "name-end-editings", "End edits: 1")
            instrumentation.runOnMainSync {
                (notes as EditText).setText("Note")
                (notes as EditText).onEditorAction(EditorInfo.IME_ACTION_DONE)
            }
            awaitText(activity, "name-submits", "Submits: 2")
            assertSame("View container was replaced after typing", root, awaitView(activity, "root"))
            assertSame("TextInput was replaced after typing", singleLineName, awaitView(activity, "name-input"))
            assertTrue("TextInput lost focus after typing", singleLineName.isFocused)
            instrumentation.runOnMainSync {
                notes.requestFocus()
                notes.clearFocus()
            }
            awaitText(activity, "notes-blurs", "Notes blurs: 1")
            awaitText(activity, "notes-end-editings", "Notes end edits: 1")

            click(activity, "increment")
            click(activity, "increment")
            awaitText(activity, "count", "Count: 2")

            click(activity, "open-details")
            assertEquals("Details for Ada", (awaitView(activity, "details-title") as TextView).text.toString())
            assertEquals("Count: 2", (awaitView(activity, "details-count") as TextView).text.toString())
            val people = awaitView(activity, "people-list") as RecyclerView
            val peopleHeader = awaitView(activity, "people-header") as TextView
            val peopleLayouts = awaitView(activity, "people-layout-status") as TextView
            val initialRowLayouts = peopleLayouts.text.toString().substringAfterLast(": ").toInt()
            assertTrue("FlatList rows did not report layout", initialRowLayouts > 0)
            var peopleHeaderInfo: AccessibilityNodeInfo? = null
            instrumentation.runOnMainSync { peopleHeaderInfo = peopleHeader.createAccessibilityNodeInfo() }
            assertTrue("FlatList header did not expose heading semantics", peopleHeaderInfo?.isHeading == true)
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
            awaitLayoutIncrease(activity, "people-layout-status", initialRowLayouts)
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
