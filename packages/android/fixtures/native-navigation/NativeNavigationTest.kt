package dev.craft.navigationtest

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.provider.Settings
import android.text.InputFilter
import android.text.InputType
import android.text.Layout
import android.text.Spanned
import android.text.style.ReplacementSpan
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.EditorInfo
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.accessibility.AccessibilityNodeInfo
import android.webkit.WebView
import android.widget.Button
import android.widget.CheckBox
import android.widget.DatePicker
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.widget.TimePicker
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import androidx.core.view.ViewCompat
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs
import kotlin.math.roundToInt

@RunWith(AndroidJUnit4::class)
class NativeNavigationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private var initialButtonNavigationSurface: Int? = null
    private var navigationSystemAppearance = "unchanged"

    private fun find(view: View, id: String): View? {
        if (view.tag?.toString() == id || view.contentDescription?.toString() == id) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                find(view.getChildAt(index), id)?.let { return it }
            }
        }
        return null
    }

    private fun findAll(view: View, id: String, matches: MutableList<View>) {
        if (view.tag?.toString() == id || view.contentDescription?.toString() == id) matches += view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) findAll(view.getChildAt(index), id, matches)
        }
    }

    private fun screenTop(view: View): Int {
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        return location[1]
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

    private fun awaitHorizontalScroller(activity: MainActivity, id: String): android.widget.HorizontalScrollView {
        repeat(75) {
            var matching: android.widget.HorizontalScrollView? = null
            instrumentation.runOnMainSync {
                val host = find(activity.window.decorView, id)
                val scroller = host?.let { findType(it, android.widget.HorizontalScrollView::class.java) }
                val child = scroller?.getChildAt(0)
                if (scroller != null && child != null && scroller.width > 0 && scroller.height > 0 && child.width > 0) {
                    matching = scroller
                }
            }
            if (matching != null) return matching!!
            SystemClock.sleep(100)
        }
        val host = awaitView(activity, id)
        val scroller = findType(host, android.widget.HorizontalScrollView::class.java)
            ?: throw AssertionError("$id did not contain an Android HorizontalScrollView")
        val child = scroller.getChildAt(0)
        throw AssertionError(
            "$id horizontal scroller did not lay out " +
                "(viewport=${scroller.width}x${scroller.height}, " +
                "content=${child?.width ?: 0}x${child?.height ?: 0})"
        )
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

    private fun awaitView(activity: MainActivity, id: String, matches: (View) -> Boolean = { true }): View {
        repeat(75) {
            var found: View? = null
            instrumentation.runOnMainSync { found = find(activity.window.decorView, id)?.takeIf(matches) }
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

    private fun pullToRefresh(host: SwipeRefreshLayout) {
        var ready = false
        for (attempt in 0 until 75) {
            instrumentation.runOnMainSync { ready = host.isLaidOut && host.width > 0 && host.height > 0 }
            if (ready) break
            SystemClock.sleep(100)
        }
        assertTrue("pull-to-refresh host did not lay out", ready)
        instrumentation.runOnMainSync {
            val downTime = SystemClock.uptimeMillis()
            val x = host.width / 2f
            val startY = 2f
            val endY = (host.height * 0.9f).coerceAtLeast(240f * host.resources.displayMetrics.density)
            val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, startY, 0)
            host.dispatchTouchEvent(down)
            down.recycle()
            for (step in 1..8) {
                val y = startY + (endY - startY) * step / 8f
                val move = MotionEvent.obtain(downTime, downTime + step * 16, MotionEvent.ACTION_MOVE, x, y, 0)
                host.dispatchTouchEvent(move)
                move.recycle()
            }
            val up = MotionEvent.obtain(downTime, downTime + 144, MotionEvent.ACTION_UP, x, endY, 0)
            host.dispatchTouchEvent(up)
            up.recycle()
        }
    }

    private fun swipeTab(activity: MainActivity, left: Boolean) {
        val chrome = findType(activity.window.decorView, CraftNativeChrome::class.java)
            ?: throw AssertionError("native chrome did not mount")
        // The hosted emulator cannot inject a window-targeted touchscreen
        // sequence reliably. Drive the same public callbacks that the shell's
        // touch interceptor invokes, retaining the real interactive transition
        // and leaving touch ownership covered by the source contract.
        val y = chrome.content.top + chrome.content.height * 0.85f
        val startX = if (left) chrome.width * 0.8f else chrome.width * 0.2f
        val endX = if (left) chrome.width * 0.2f else chrome.width * 0.8f
        val deltaX = endX - startX
        instrumentation.runOnMainSync {
            val started = chrome.onTabSwipeStart?.invoke(deltaX, startX, y) == true
            assertTrue("native tab swipe did not start", started)
            if (left) {
                val roots = mutableListOf<View>()
                findAll(chrome.content, "root", roots)
                val incoming = roots.maxByOrNull { kotlin.math.abs((it.parent as? View)?.translationX ?: 0f) }
                assertTrue(
                    "incoming SafeAreaView did not receive window insets before tab swipe movement",
                    incoming != null && incoming.paddingTop >= (16 * activity.resources.displayMetrics.density).toInt(),
                )
            }
            listOf(0.25f, 0.5f, 0.75f, 1f).forEach { fraction ->
                chrome.onTabSwipeMove?.invoke(deltaX * fraction)
            }
            chrome.onTabSwipeEnd?.invoke(deltaX, false)
        }
    }

    private fun awaitText(activity: MainActivity, id: String, expected: String): TextView {
        var actual = "<missing>"
        repeat(75) {
            var matching: TextView? = null
            instrumentation.runOnMainSync {
                val view = find(activity.window.decorView, id)
                actual = (view as? TextView)?.text?.toString() ?: "<missing>"
                if (view is TextView && view.text.toString() == expected) matching = view
            }
            if (matching != null) return matching!!
            SystemClock.sleep(100)
        }
        throw AssertionError("Timed out waiting for $id to read $expected (actual: $actual)")
    }

    private fun awaitLayoutWidth(activity: MainActivity, id: String, expected: Double): Double {
        val density = activity.resources.displayMetrics.density.toDouble()
        var actual = ""
        repeat(75) {
            var reported: Double? = null
            instrumentation.runOnMainSync {
                actual = (find(activity.window.decorView, id) as? TextView)?.text?.toString().orEmpty()
                reported = actual.substringAfterLast(": ").toDoubleOrNull()
            }
            // Native layout uses whole physical pixels. At fractional display
            // densities, a logical 180dp need not report the integer 180.
            if (reported != null && kotlin.math.abs(reported!! - expected) < 1.0 / density) return reported!!
            SystemClock.sleep(100)
        }
        throw AssertionError("Timed out waiting for $id near $expected dp; got '$actual' at density $density")
    }

    private fun awaitProgressBar(
        activity: MainActivity,
        id: String,
        expected: String,
        predicate: (ProgressBar) -> Boolean,
    ): ProgressBar {
        repeat(75) {
            var matching: ProgressBar? = null
            instrumentation.runOnMainSync {
                val view = find(activity.window.decorView, id)
                if (view is ProgressBar && predicate(view)) matching = view
            }
            if (matching != null) return matching!!
            SystemClock.sleep(100)
        }
        throw AssertionError("Timed out waiting for $id to be $expected")
    }

    private fun awaitImageTintCleared(activity: MainActivity, id: String): ImageView {
        repeat(75) {
            var matching: ImageView? = null
            instrumentation.runOnMainSync {
                val view = find(activity.window.decorView, id)
                if (view is ImageView && view.colorFilter == null) matching = view
            }
            if (matching != null) return matching!!
            SystemClock.sleep(100)
        }
        throw AssertionError("Timed out waiting for $id tint to clear")
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

    private fun awaitWidthDecrease(view: View, from: Int, amount: Int, density: Float) {
        repeat(75) {
            var settled = false
            instrumentation.runOnMainSync {
                settled = view.width < from - (amount * density).toInt()
            }
            if (settled) return
            SystemClock.sleep(100)
        }
        throw AssertionError("width did not settle below ${from - (amount * density).toInt()}, was ${view.width}")
    }

    private fun backgroundColor(view: View): Int? = when (val background = view.background) {
        is GradientDrawable -> background.color?.defaultColor
        is ColorDrawable -> background.color
        else -> null
    }

    private fun awaitReferenceWindowReturn(activity: MainActivity) {
        // finish() precedes WindowManager's focus callback. Complete this
        // test-only reference teardown before the next real screen check.
        repeat(30) {
            var focused = false
            instrumentation.runOnMainSync {
                focused = activity.hasWindowFocus() && activity.window.decorView.isShown
            }
            if (focused) return
            SystemClock.sleep(100)
        }
        throw AssertionError("Native reference did not return focus to the original screen")
    }

    @Suppress("DEPRECATION")
    private fun assertSystemInsetBackground(activity: MainActivity, color: Int?, message: String) {
        instrumentation.runOnMainSync {
            assertTrue("system bar evidence requires the focused visible native screen",
                activity.hasWindowFocus() && activity.window.decorView.isShown)
        }
        assertEquals(message, color, backgroundColor(activity.findViewById<View>(R.id.native_root)))
        if (android.os.Build.VERSION.SDK_INT < 35) {
            assertEquals("$message (legacy status bar)", color, activity.window.statusBarColor)
            assertEquals("$message (legacy navigation bar)", color, activity.window.navigationBarColor)
        } else {
            // Appearance flags alone cannot establish contrast on Android 15.
            // Check the actual protected surface and every native button.
            val authored = color ?: throw AssertionError("missing screen background")
            // Finding a protocol view and receiving window focus both precede
            // the first inset dispatch after an activity or appearance change.
            // Wait for that actual system measurement before taking pixels.
            var measured: androidx.core.view.WindowInsetsCompat? = null
            for (attempt in 0 until 50) {
                instrumentation.runOnMainSync {
                    val next = ViewCompat.getRootWindowInsets(activity.window.decorView)
                    if (activity.hasWindowFocus() && next?.getInsets(
                            androidx.core.view.WindowInsetsCompat.Type.navigationBars())?.bottom?.let { it > 0 } == true) {
                        measured = next
                    }
                }
                if (measured != null) break
                SystemClock.sleep(100)
            }
            val insets = measured ?: throw AssertionError(
                "navigation-bar screenshot coverage requires a visible system bar after window layout")
            val tappable = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.tappableElement()).bottom
            val buttonNavigation = tappable > 0
            var expected = authored
            val inset = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.navigationBars()).bottom
            assertTrue("navigation-bar screenshot coverage requires a visible system bar", inset > 0)
            var actual: Int? = null
            var glyphContrast = 1.0
            var glyphColor = 0
            var glyphX = 0
            var glyphY = 0
            for (attempt in 0 until 30) {
                val image = instrumentation.uiAutomation.takeScreenshot()
                    ?: throw AssertionError("system screenshot unavailable")
                actual = image.getPixel(image.width / 2, image.height - 2)
                if (buttonNavigation) {
                    // Device-themed buttons need a stable protected surface
                    // even when the app changes its own local appearance.
                    expected = initialButtonNavigationSurface ?: actual!!
                }
                glyphColor = expected
                val backgroundLuminance = Color.luminance(actual!!)
                val buttonContrasts = MutableList(if (buttonNavigation) 3 else 1) { 1.0 }
                // Exclude divider/border pixels; inspect the area occupied
                // by the native buttons or gesture handle themselves.
                for (y in image.height - inset * 3 / 4 until image.height - inset / 4 step 2) {
                    for (x in 2 until image.width - 2 step 2) {
                        val luminance = Color.luminance(image.getPixel(x, y))
                        val contrast = (maxOf(luminance, backgroundLuminance) + 0.05) /
                            (minOf(luminance, backgroundLuminance) + 0.05)
                        val region = if (buttonNavigation) (x * 3 / image.width).coerceAtMost(2) else 0
                        if (contrast > buttonContrasts[region]) {
                            buttonContrasts[region] = contrast
                            glyphColor = image.getPixel(x, y)
                            glyphX = x
                            glyphY = y
                        }
                    }
                }
                glyphContrast = buttonContrasts.minOrNull() ?: 1.0
                if (buttonNavigation && initialButtonNavigationSurface == null && glyphContrast >= 3.0) {
                    initialButtonNavigationSurface = actual
                }
                if ((actual == expected && glyphContrast >= 3.0) || attempt == 29) {
                    val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
                        ?: throw AssertionError("Gradle system-bar evidence directory unavailable")
                    val directory = java.io.File(output, "native-navigation-bars")
                    directory.mkdirs()
                    val name = (navigationSystemAppearance + "-" + message).replace(Regex("[^A-Za-z0-9_-]"), "_")
                    java.io.File(directory, "$name.png").outputStream().use {
                        image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                    }
                    val appearance = androidx.core.view.WindowCompat
                        .getInsetsController(activity.window, activity.window.decorView)
                    val metadata = "size=${image.width}x${image.height} inset=$inset background=$actual expected=$expected authored=$authored " +
                            "glyph=$glyphColor at=$glyphX,$glyphY contrast=$glyphContrast eachButton=$buttonContrasts navigationLight=${appearance.isAppearanceLightNavigationBars} " +
                            "windowBackground=${backgroundColor(activity.window.decorView)} nativeAppearance=${activity.window.insetsController?.systemBarsAppearance} " +
                            "brightness=${activity.window.attributes.screenBrightness} flags=${activity.window.attributes.flags} format=${activity.window.attributes.format} " +
                            "navigationMode=${Settings.Secure.getString(activity.contentResolver, "navigation_mode")} focused=${activity.hasWindowFocus()}\n"
                    java.io.File(directory, "$name.txt").writeText(metadata)
                    android.util.Log.i("CraftNativeBarProbe", metadata)
                    if (actual != expected || glyphContrast < 3.0) {
                        // Preserve the original failure, then compare the same
                        // display/sampling with literal native Android windows.
                        val observedBar = IntArray(image.width * inset)
                        image.getPixels(observedBar, 0, image.width, 0, image.height - inset, image.width, inset)
                        var matchingNativeBars = 0
                        for ((stockTheme, opaqueNav) in listOf(false to false, false to true, true to false, true to true)) {
                            val reference = instrumentation.startActivitySync(
                                Intent(activity, NativeSystemBarsReferenceActivity::class.java)
                                    .putExtra("background", expected)
                                    .putExtra("stockTheme", stockTheme)
                                    .putExtra("opaqueNav", opaqueNav)
                                    .putExtra("brightness", activity.window.attributes.screenBrightness)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            ) as NativeSystemBarsReferenceActivity
                            try {
                                SystemClock.sleep(500)
                                instrumentation.runOnMainSync {
                                    assertTrue("system bar reference must be focused and visible",
                                        reference.hasWindowFocus() && reference.window.decorView.isShown)
                                }
                                val comparison = instrumentation.uiAutomation.takeScreenshot()
                                    ?: throw AssertionError("native reference screenshot unavailable")
                                java.io.File(directory, "$name-reference-$stockTheme-opaque-$opaqueNav.png").outputStream().use {
                                    comparison.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                                }
                                val attributes = reference.window.attributes
                                java.io.File(directory, "$name-reference-$stockTheme-opaque-$opaqueNav.txt").writeText(
                                    "background=${backgroundColor(reference.window.decorView)} " +
                                        "appearance=${reference.window.insetsController?.systemBarsAppearance} " +
                                        "brightness=${attributes.screenBrightness} flags=${attributes.flags} format=${attributes.format} focused=${reference.hasWindowFocus()}\n"
                                )
                                // Stock parity is diagnostic only. A matching
                                // low-contrast native bar still fails this test.
                                if (comparison.width == image.width && comparison.height == image.height) {
                                    val nativeBar = IntArray(observedBar.size)
                                    comparison.getPixels(nativeBar, 0, image.width, 0, image.height - inset, image.width, inset)
                                    if (observedBar.contentEquals(nativeBar)) matchingNativeBars++
                                }
                                comparison.recycle()
                            } finally {
                                instrumentation.runOnMainSync { reference.finish() }
                            }
                        }
                        awaitReferenceWindowReturn(activity)
                        val parity = "contrast=$glyphContrast target=3.0 exactNativeBars=$matchingNativeBars/4\n"
                        java.io.File(directory, "$name-native-parity.txt").writeText(parity)
                        android.util.Log.i("CraftNativeBarProbe", parity)
                    }
                }
                image.recycle()
                if (actual == expected && glyphContrast >= 3.0) break
                if (attempt < 29) SystemClock.sleep(100)
            }
            assertEquals("$message (composed bottom system bar)", expected, actual)
            val statusImage = instrumentation.uiAutomation.takeScreenshot()
                ?: throw AssertionError("status screenshot unavailable")
            try {
                assertEquals("navigation protection must not recolour the authored status inset", authored,
                    statusImage.getPixel(statusImage.width / 2, 2))
            } finally { statusImage.recycle() }
            assertTrue("navigation glyphs must remain readable even when the stock platform has low contrast: $glyphContrast",
                glyphContrast >= 3.0)
            assertEquals("Android 15 navigation surface must be transparent",
                Color.TRANSPARENT, activity.window.navigationBarColor)
            assertFalse("Android 15 must not add a second contrast scrim",
                activity.window.isNavigationBarContrastEnforced)
        }
    }

    private fun chromeBackgroundColor(activity: MainActivity, childIndex: Int): Int? =
        findType(activity.window.decorView, CraftNativeChrome::class.java)
            ?.getChildAt(childIndex)
            ?.let(::backgroundColor)

    private fun awaitBackgroundColor(view: View, previous: Int?): Int {
        repeat(75) {
            var current: Int? = null
            instrumentation.runOnMainSync { current = backgroundColor(view) }
            if (current != null && current != previous) return current!!
            SystemClock.sleep(100)
        }
        throw AssertionError("native theme probe did not change background")
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

    private fun assertTabTapInterruptsSettlingSwipe(index: Int, id: String, expected: String) {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        val previousScale = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        fun animatorScale(value: Float) {
            android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
                "settings put global animator_duration_scale $value",
            )).use { it.readBytes() }
        }
        try {
            animatorScale(1f)
            awaitText(activity, "navigation-home-state", "Home state: Ada/0")
            click(activity, "navigation-increment")
            awaitText(activity, "navigation-home-state", "Home state: Ada/1")
            assertTrue("interruption coverage requires real animator timing", Settings.Global.getFloat(
                context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f,
            ) > 0f)
            val chrome = findType(activity.window.decorView, CraftNativeChrome::class.java)
                ?: throw AssertionError("native chrome did not mount")
            instrumentation.runOnMainSync {
                val dx = -chrome.content.width * 0.65f
                assertTrue("native swipe did not start", chrome.onTabSwipeStart?.invoke(
                    dx, chrome.width * 0.85f, chrome.content.top + chrome.content.height * 0.85f,
                ) == true)
                chrome.onTabSwipeMove?.invoke(dx)
                chrome.onTabSwipeEnd?.invoke(dx, false)
                // Same UI turn, before the 180ms completion callback runs.
                chrome.onTab?.invoke(index)
            }
            SystemClock.sleep(500)
            awaitText(activity, id, expected)
            instrumentation.runOnMainSync {
                assertEquals("an interrupted preview remained attached", 1, chrome.content.childCount)
                assertEquals(0f, chrome.content.getChildAt(0).translationX, 0.01f)
                val title = if (index == 0) "Home" else "Summary"
                assertTrue("the owning tab lacks native selected accessibility state", find(activity.window.decorView, title)?.isSelected == true)
            }
            instrumentation.runOnMainSync {
                val dx = chrome.content.width * if (index == 0) -0.1f else 0.1f
                assertTrue("an interrupted swipe blocked the next gesture", chrome.onTabSwipeStart?.invoke(
                    dx, chrome.width * 0.5f, chrome.content.top + chrome.content.height * 0.85f,
                ) == true)
                chrome.onTabSwipeMove?.invoke(dx)
                chrome.onTabSwipeEnd?.invoke(dx, true)
            }
            SystemClock.sleep(400)
            awaitText(activity, id, expected)
            assertNoWebView(activity)
        } finally {
            animatorScale(previousScale)
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun firstInterceptedMoveAdvancesTabBeforeAnotherTouchArrives() {
        instrumentation.runOnMainSync {
            val chrome = CraftNativeChrome(instrumentation.targetContext, listOf(
                CraftNativeTab("/", "Home", "house"),
                CraftNativeTab("/details", "Details", "doc.text"),
            ))
            chrome.content.addView(Button(instrumentation.targetContext), ViewGroup.LayoutParams(-1, -1))
            chrome.measure(
                View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(2000, View.MeasureSpec.EXACTLY),
            )
            chrome.layout(0, 0, 1000, 2000)
            val moved = mutableListOf<Float>()
            var starts = 0
            var cancelled = false
            chrome.onTabSwipeStart = { _, _, _ -> starts++; true }
            chrome.onTabSwipeMove = { moved += it }
            chrome.onTabSwipeEnd = { _, wasCancelled -> cancelled = wasCancelled }
            val downTime = SystemClock.uptimeMillis()
            fun touch(action: Int, x: Float, offset: Long) {
                val event = MotionEvent.obtain(downTime, downTime + offset, action, x, 500f, 0)
                try { chrome.dispatchTouchEvent(event) } finally { event.recycle() }
            }
            touch(MotionEvent.ACTION_DOWN, 800f, 0)
            touch(MotionEvent.ACTION_MOVE, 400f, 16)
            assertEquals("one move should acquire the native tab gesture", 1, starts)
            assertEquals("interception must apply the distance already travelled", listOf(-400f), moved)
            touch(MotionEvent.ACTION_MOVE, 300f, 32)
            assertEquals(listOf(-400f, -500f), moved)
            touch(MotionEvent.ACTION_CANCEL, 300f, 48)
            assertTrue("cancel must still finish the acquired gesture", cancelled)
        }
    }

    @Test
    fun selectedTabIconPolicyFollowsNativeSelectionAndSurvivesLiveReadingCleanup() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        val previousScale = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        fun animatorScale(value: Float) {
            android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
                "settings put global animator_duration_scale $value",
            )).use { it.readBytes() }
        }
        try {
            animatorScale(1f)
            awaitView(activity, "navigation-home-state")
            var ready = false
            repeat(30) {
                if (!ready) {
                    instrumentation.runOnMainSync {
                        ready = activity.hasWindowFocus() && android.animation.ValueAnimator.areAnimatorsEnabled()
                    }
                    if (!ready) SystemClock.sleep(100)
                }
            }
            assertTrue("pulse coverage requires the focused native window and enabled animations", ready)
            instrumentation.runOnMainSync {
                val chrome = findType(activity.window.decorView, CraftNativeChrome::class.java)
                    ?: throw AssertionError("native chrome did not mount")
                val configured = CraftNativeRoutes(org.json.JSONObject().put("tabs", org.json.JSONArray().put(
                    org.json.JSONObject().put("id", "/health").put("title", "Health").put("symbol", "heart")
                        .put("selectedSymbol", "heart.fill").put("selectedIconTint", "#ff3b30").put("selectedIconPulse", false),
                ))).tabs.single()
                val configuredChrome = CraftNativeChrome(activity, listOf(configured))
                assertEquals(CraftTabIconAppearance("heart.fill", Color.parseColor("#ff3b30"), false), configuredChrome.tabIconAppearance(0, true))
                val blankChrome = CraftNativeChrome(activity, listOf(configured.copy(selectedSymbol = " \n ")))
                assertEquals("heart", blankChrome.tabIconAppearance(0, true).symbol)
                fun patch(item: org.json.JSONObject) {
                    chrome.apply(org.json.JSONObject().put("tabItem", item.put("id", "/")), 0, "Home")
                }
                patch(org.json.JSONObject().put("selectedSymbol", "heart.fill").put("selectedIconTint", "#ff3b30").put("selectedIconPulse", true))
                chrome.selectTab(0)
                val cell = find(chrome, "craft-tab-/") as LinearLayout
                val icon = cell.getChildAt(0) as TextView
                assertEquals(CraftTabIconAppearance("heart.fill", Color.parseColor("#ff3b30"), true), chrome.tabIconAppearance(0, true))
                assertEquals(Color.parseColor("#ff3b30"), icon.currentTextColor)
                assertTrue("selected filled icon was not rendered", icon.foreground != null || icon.text.toString() == "♥")
                assertTrue("the selected native icon never started its pulse", icon.animation is android.view.animation.AlphaAnimation)
                assertFalse("reduced motion must suppress animation", chrome.tabIconAppearance(0, false).pulse)
                chrome.selectTab(1)
                assertFalse("inactive tab kept its selection pulse", chrome.tabIconAppearance(0, true).pulse)
                assertTrue("inactive tab kept its selected symbol", chrome.tabIconAppearance(0, true).symbol != "heart.fill")
                assertTrue("inactive tab retained its animation", icon.animation == null)
                chrome.selectTab(0)
                val resumedPulse = icon.animation
                assertTrue("returning to the owning tab did not resume its pulse", resumedPulse is android.view.animation.AlphaAnimation)
                patch(org.json.JSONObject().put("selectedSymbol", " \n "))
                assertTrue("blank overrides must restore the base symbol", chrome.tabIconAppearance(0, true).symbol != "heart.fill")
                patch(org.json.JSONObject().put("selectedSymbol", " heart.fill "))
                assertEquals("heart.fill", chrome.tabIconAppearance(0, true).symbol)
                patch(org.json.JSONObject().put("title", "145 bpm").put("iconTint", "#ff3b30").put("iconPulse", true))
                assertSame("a live caption restarted the native pulse", resumedPulse, icon.animation)
                patch(org.json.JSONObject().put("title", org.json.JSONObject.NULL).put("iconTint", org.json.JSONObject.NULL).put("iconPulse", false))
                assertSame("caption cleanup interrupted the selected pulse", resumedPulse, icon.animation)
                assertEquals("Home", (cell.getChildAt(1) as TextView).text.toString())
                assertEquals(CraftTabIconAppearance("heart.fill", Color.parseColor("#ff3b30"), true), chrome.tabIconAppearance(0, true))
                assertTrue("caption cleanup changed the owning native tab", cell.isSelected)
                patch(org.json.JSONObject().put("iconPulse", true).put("selectedIconPulse", false))
                assertFalse("explicit false must override legacy pulse", chrome.tabIconAppearance(0, true).pulse)
                assertTrue(icon.animation == null)
                patch(org.json.JSONObject().put("selectedSymbol", org.json.JSONObject.NULL).put("selectedIconTint", "invalid").put("selectedIconPulse", org.json.JSONObject.NULL))
                assertTrue("null must restore the legacy pulse", chrome.tabIconAppearance(0, true).pulse)
                assertTrue(chrome.tabIconAppearance(0, true).symbol != "heart.fill")
                assertTrue(chrome.tabIconAppearance(0, true).tint == null)
            }
        } finally {
            animatorScale(previousScale)
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun selectableTextUsesNativeTextSelection() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            val text = awaitView(activity, "selectable-native-text") as TextView
            instrumentation.runOnMainSync {
                assertTrue("selectable Text must expose Android's selection model", text.isTextSelectable)
                assertTrue("selectable Text must be focusable for the copy menu", text.isFocusable)
            }
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun liveTabUpdatesRetainToolbarViewsAndActionsUntilTheirSpecsChange() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            awaitView(activity, "navigation-home-state")
            instrumentation.runOnMainSync {
                val chrome = findType(activity.window.decorView, CraftNativeChrome::class.java)
                    ?: throw AssertionError("native chrome did not mount")
                val options = org.json.JSONObject().put("title", "Home")
                    .put("leftButtons", org.json.JSONArray().put(org.json.JSONObject()
                        .put("id", "perf-leading").put("title", "Lead").put("accessibilityLabel", "Perf leading")))
                    .put("rightButtons", org.json.JSONArray().put(org.json.JSONObject()
                        .put("id", "perf-action").put("title", "Save").put("accessibilityLabel", "Perf action")))
                chrome.apply(options, 0, "Home")
                val leading = find(chrome, "Perf leading") ?: throw AssertionError("missing leading action")
                val action = find(chrome, "Perf action") ?: throw AssertionError("missing trailing action")
                for (beat in 1..120) {
                    options.put("tabItem", org.json.JSONObject().put("id", "/").put("title", "$beat bpm"))
                    chrome.apply(options, 0, "Home")
                    assertSame("a live tab update recreated the leading toolbar", leading, find(chrome, "Perf leading"))
                    assertSame("a live tab update recreated the trailing toolbar", action, find(chrome, "Perf action"))
                }
                var pressed = ""
                val previous = chrome.onButton
                try {
                    chrome.onButton = { pressed = it }
                    action.performClick()
                    assertEquals("perf-action", pressed)
                } finally { chrome.onButton = previous }
                options.put("rightButtons", org.json.JSONArray())
                chrome.apply(options, 0, "Home")
                assertTrue("an explicit clear retained a stale action", find(chrome, "Perf action") == null)
            }
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun liveTabCaptionKeepsItsSymbolAndResetsWithoutChangingSelection() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            awaitView(activity, "navigation-home-state")
            instrumentation.runOnMainSync {
                val chrome = findType(activity.window.decorView, CraftNativeChrome::class.java)
                    ?: throw AssertionError("native chrome did not mount")
                chrome.apply(org.json.JSONObject().put("tabItem", org.json.JSONObject()
                    .put("id", "/").put("title", "123 bpm").put("iconText", org.json.JSONObject.NULL)
                    .put("iconTint", "#ff3b30").put("iconPulse", true).put("accessibilityLabel", "Live reading, 123 bpm")), 0, "Home")
                val cell = find(chrome, "Live reading, 123 bpm") as LinearLayout
                val icon = cell.getChildAt(0) as TextView
                val label = cell.getChildAt(1) as TextView
                assertSame("a live caption lost its stable tab identity", cell, find(chrome, "craft-tab-/"))
                assertEquals("123 bpm", label.text.toString())
                assertEquals(Color.parseColor("#ff3b30"), icon.currentTextColor)
                assertTrue("updating a caption changed tab selection", cell.isSelected)
                chrome.apply(org.json.JSONObject().put("tabItem", org.json.JSONObject()
                    .put("id", "/").put("title", org.json.JSONObject.NULL).put("iconTint", org.json.JSONObject.NULL)
                    .put("iconPulse", false).put("accessibilityLabel", org.json.JSONObject.NULL)), 0, "Home")
                assertEquals("Home", label.text.toString())
                assertEquals("Home", cell.contentDescription.toString())
                assertTrue("the pulse was not stopped", icon.animation == null)
                assertTrue("resetting a caption changed tab selection", cell.isSelected)
            }
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun nativeTestIdsRemainQueryableWithoutReplacingVisibleLabels() {
        val automation = instrumentation.uiAutomation
        val previousServiceInfo = automation.serviceInfo
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        }
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        fun matching(root: AccessibilityNodeInfo, id: String): AccessibilityNodeInfo? {
            if (root.viewIdResourceName == id) return root
            for (index in 0 until root.childCount) {
                val child = root.getChild(index) ?: continue
                matching(child, id)?.let { return it }
            }
            return null
        }
        fun node(id: String): AccessibilityNodeInfo {
            repeat(100) {
                // Native automation consumes node metadata. Android's direct
                // find-by-view-ID RPC instead resolves an AAPT resource ID,
                // which authored STX identities deliberately do not allocate.
                automation.rootInActiveWindow?.let { matching(it, id) }?.let { return it }
                SystemClock.sleep(100)
            }
            throw AssertionError("The native accessibility tree did not expose STX testID $id")
        }
        try {
            awaitView(activity, "home-title")
            val homeTab = node("craft-tab-/")
            assertEquals("Home", homeTab.contentDescription.toString())
            assertEquals(Button::class.java.name, homeTab.className.toString())
            assertTrue(homeTab.isSelected)
            val detailsTab = node("craft-tab-/details")
            assertEquals("Details", detailsTab.contentDescription.toString())
            assertFalse(detailsTab.isSelected)
            assertTrue("The native tab did not accept its accessibility click",
                detailsTab.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            awaitView(activity, "details-title")
            assertTrue(node("craft-tab-/details").isSelected)
            assertTrue(node("craft-tab-/").performAction(AccessibilityNodeInfo.ACTION_CLICK))
            awaitView(activity, "home-title")
            val title = node("home-title")
            assertEquals("Home", title.text.toString())
            assertEquals("The test identity must not become a spoken label", null, title.contentDescription)
            val toggle = node("toggle-safe-area")
            assertEquals("Toggle safe edges", toggle.text.toString())
            assertEquals("link", node("native-linked-pressable").extras
                .getCharSequence("AccessibilityNodeInfo.roleDescription")?.toString())
            assertEquals("button", node("native-raw-pressable").extras
                .getCharSequence("AccessibilityNodeInfo.roleDescription")?.toString())
            assertTrue("The identified native button did not accept its accessibility click",
                toggle.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            awaitText(activity, "safe-area-status", "Safe edges: bottom")
            assertEquals("The identity disappeared after native reconciliation", "Toggle safe edges",
                node("toggle-safe-area").text.toString())
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            automation.serviceInfo = previousServiceInfo
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun repeatedTestIdsKeepDistinctProtocolViewsAcrossReorders() {
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        fun rows(): List<View> {
            val list = awaitView(activity, "identity-list") { candidate ->
                val rendered = mutableListOf<View>()
                findAll(candidate, "identity-row", rendered)
                rendered.size == 2
            }
            val matches = mutableListOf<View>()
            instrumentation.runOnMainSync {
                findAll(list, "identity-row", matches)
            }
            assertEquals("Repeated test selectors must identify two separate rows", 2, matches.size)
            return matches
        }
        try {
            click(activity, "open-identity")
            awaitView(activity, "identity-title")
            val original = rows()
            val alpha = original[0]
            val beta = original[1]
            val alphaInput = find(alpha, "identity-input") as EditText
            val betaInput = find(beta, "identity-input") as EditText
            assertTrue("Repeated selectors aliased separate inputs", alphaInput !== betaInput)
            instrumentation.runOnMainSync {
                betaInput.requestFocus()
                betaInput.setText("Beta private draft")
            }
            instrumentation.waitForIdleSync()
            click(activity, "identity-reverse")
            awaitView(activity, "identity-list") { list ->
                find(list, "identity-row")?.let { find(it, "identity-label-beta") != null } == true
            }
            instrumentation.waitForIdleSync()
            val reversed = rows()
            assertSame("Reordered Beta row lost its protocol identity", beta, reversed[0])
            assertSame("Reordered Alpha row lost its protocol identity", alpha, reversed[1])
            assertSame("Reordering replaced the focused native input", betaInput, find(reversed[0], "identity-input"))
            assertEquals("Beta private draft", betaInput.text.toString())
            assertEquals("The second row received another row's draft", "", alphaInput.text.toString())
            assertTrue("Reordering dropped native focus", betaInput.isFocused)
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun outgoingTabTapWinsOverSettlingSwipe() {
        assertTabTapInterruptsSettlingSwipe(0, "navigation-home-state", "Home state: Ada/1")
    }

    @Test
    fun thirdTabTapWinsOverSettlingSwipe() {
        assertTabTapInterruptsSettlingSwipe(2, "summary-title", "Summary for ")
    }

    private fun assertRetainedTabVisibleAfterSwipe(cancelledPreview: Boolean) {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        val previousScale = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        fun animatorScale(value: Float) {
            android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
                "settings put global animator_duration_scale $value",
            )).use { it.readBytes() }
        }
        try {
            animatorScale(1f)
            awaitText(activity, "navigation-home-state", "Home state: Ada/0")
            val chrome = findType(activity.window.decorView, CraftNativeChrome::class.java)
                ?: throw AssertionError("native chrome did not mount")
            fun swipe(left: Boolean, cancelled: Boolean) {
                instrumentation.runOnMainSync {
                    val dx = chrome.content.width * if (left) -0.65f else 0.65f
                    assertTrue("retained-tab swipe did not start", chrome.onTabSwipeStart?.invoke(
                        dx, chrome.width * if (left) 0.85f else 0.15f,
                        chrome.content.top + chrome.content.height * 0.85f,
                    ) == true)
                    chrome.onTabSwipeMove?.invoke(dx)
                    chrome.onTabSwipeEnd?.invoke(dx, cancelled)
                }
                // Keep real animator completions in the reproduction: these
                // can write a final offset after removing the retained view.
                SystemClock.sleep(400)
            }
            fun assertVisibleViewport() {
                instrumentation.runOnMainSync {
                    val screen = chrome.content.getChildAt(0)
                        ?: throw AssertionError("selected tab did not attach its native screen")
                    val bounds = android.graphics.Rect()
                    assertTrue("selected retained tab is outside the visible viewport", screen.getGlobalVisibleRect(bounds))
                    assertEquals("selected retained tab is horizontally displaced", 0f, screen.translationX, 0.01f)
                    assertEquals("retained tab does not fill the visible viewport", chrome.content.width, bounds.width())
                    assertTrue("retained tab has no visible content height", bounds.height() > 0)
                }
            }
            if (cancelledPreview) {
                swipe(left = true, cancelled = true)
                awaitText(activity, "navigation-home-state", "Home state: Ada/0")
            } else {
                swipe(left = true, cancelled = false)
                awaitText(activity, "details-title", "Details for ")
                assertVisibleViewport()
                swipe(left = false, cancelled = false)
                awaitText(activity, "navigation-home-state", "Home state: Ada/0")
            }
            assertVisibleViewport()
            instrumentation.runOnMainSync { chrome.onTab?.invoke(1) }
            awaitText(activity, "details-title", "Details for ")
            assertVisibleViewport()
            instrumentation.runOnMainSync { chrome.onTab?.invoke(0) }
            awaitText(activity, "navigation-home-state", "Home state: Ada/0")
            assertVisibleViewport()
            assertNoWebView(activity)
        } finally {
            animatorScale(previousScale)
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun cancelledSwipeTargetIsVisibleWhenSelectedLater() {
        assertRetainedTabVisibleAfterSwipe(cancelledPreview = true)
    }

    @Test
    fun completedReverseSwipeKeepsRetainedTabVisible() {
        assertRetainedTabVisibleAfterSwipe(cancelledPreview = false)
    }

    @Test
    fun nativeTeardownRecordsSynchronousStorageBeforeReturning() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            val retained = awaitText(activity, "navigation-home-state", "Home state: Ada/0")
            for (increments in 1..2) {
                click(activity, "navigation-open-details")
                awaitText(activity, "details-count", "Count: 0")
                repeat(increments) { click(activity, "details-increment") }
                awaitText(activity, "details-count", "Count: $increments")
                if (increments == 1) click(activity, "details-back")
                else instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
                assertSame(retained, awaitText(activity, "navigation-home-state", "Home state: Ada/0"))
                click(activity, "navigation-check-lifecycle")
                awaitText(activity, "navigation-lifecycle", "Disposed Ada/$increments")
                assertNoWebView(activity)
            }
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun compiledBundleRendersNavigatesAndRetainsNativeControls() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            val homeState = awaitText(activity, "navigation-home-state", "Home state: Ada/0")
            click(activity, "navigation-increment")
            awaitText(activity, "navigation-home-state", "Home state: Ada/1")
            click(activity, "navigation-open-details")
            awaitText(activity, "details-title", "Details for Ada")
            click(activity, "details-back")
            awaitText(activity, "navigation-home-state", "Home state: Ada/1")
            assertEquals("Home state: Ada/1", homeState.text.toString())

            val carousel = awaitHorizontalScroller(activity, "tab-swipe-carousel")
            val carouselContent = carousel.getChildAt(0)
                ?: throw AssertionError("carousel did not mount a content child")
            assertTrue(
                "carousel content was not wider than its viewport (content=${carouselContent.width}, viewport=${carousel.width})",
                carouselContent.width > carousel.width,
            )
            assertTrue(
                "carousel should be able to consume a left swipe before the tab shell",
                carousel.canScrollHorizontally(1),
            )
            // Instrumentation cannot inject a targeted touchscreen event into
            // the app window on the hosted emulator. Exercise the same native
            // scroll range deterministically; the shell's gesture ownership is
            // covered by the source contract and the real device path.
            carousel.scrollTo(carousel.width, 0)
            assertTrue("carousel content did not scroll within its native range", carousel.scrollX > 0)
            swipeTab(activity, left = true)
            awaitText(activity, "details-title", "Details for ")
            swipeTab(activity, left = false)
            val name = awaitView(activity, "name-input")
            val root = awaitView(activity, "root")
            assertTrue("View did not render as LinearLayout", root is LinearLayout)
            val authoredRootPadding = (16 * activity.resources.displayMetrics.density).roundToInt()
            val initialRootTop = root.paddingTop
            val initialRootBottom = root.paddingBottom
            assertTrue("SafeAreaView did not retain its authored top padding", initialRootTop >= authoredRootPadding)
            click(activity, "toggle-safe-area")
            awaitText(activity, "safe-area-status", "Safe edges: bottom")
            assertSame("SafeAreaView edge updates replaced the root", root, awaitView(activity, "root"))
            assertEquals("Removing the top edge did not remove the window inset", authoredRootPadding, root.paddingTop)
            assertTrue("Removing the top edge changed the bottom inset", root.paddingBottom >= initialRootBottom)
            click(activity, "toggle-safe-area")
            awaitText(activity, "safe-area-status", "Safe edges: top,bottom")
            assertEquals("Restoring the top edge changed the original native safe-area padding", initialRootTop, root.paddingTop)
            val retained = awaitView(activity, "retained-safe-area")
            val retainedAuthoredPadding = (4 * activity.resources.displayMetrics.density).roundToInt()
            val plainRetainedPadding = retained.paddingTop
            assertEquals("plain retained container did not keep its authored padding", retainedAuthoredPadding, plainRetainedPadding)
            click(activity, "toggle-retained-safe-area")
            awaitText(activity, "retained-safe-area-status", "Retained: safe")
            assertSame("type-switched retained container was replaced", retained, awaitView(activity, "retained-safe-area"))
            assertEquals("SafeAreaView type switch did not apply the received top inset", plainRetainedPadding + initialRootTop - authoredRootPadding, retained.paddingTop)
            click(activity, "toggle-retained-safe-area")
            awaitText(activity, "retained-safe-area-status", "Retained: plain")
            assertSame("retained container changed identity on the way back", retained, awaitView(activity, "retained-safe-area"))
            assertEquals("View type switch retained a stale window inset", plainRetainedPadding, retained.paddingTop)
            val rootHost = awaitView(activity, "native-root-scroll")
            val rootScroll = findType(rootHost, ScrollView::class.java)
                ?: throw AssertionError("native-root-scroll did not contain an Android ScrollView")
            val rootOverlay = awaitView(activity, "native-root-overlay")
            val overlayTopBeforeScroll = rootOverlay.top
            val overlayRightBeforeScroll = rootOverlay.right
            assertScrolls(rootScroll)
            assertEquals("root absolute sibling moved with ScrollView content", overlayTopBeforeScroll, rootOverlay.top)
            assertEquals("root absolute sibling changed horizontal position", overlayRightBeforeScroll, rootOverlay.right)
            instrumentation.runOnMainSync { rootScroll.scrollTo(0, 0) }
            val bubble = awaitView(activity, "max-content-bubble") as ViewGroup
            val bubbleText = awaitView(activity, "max-content-bubble-text") as TextView
            assertEquals("text took min-content width and wrapped unexpectedly", 1, bubbleText.lineCount)
            assertTrue("bubble did not retain its authored horizontal padding", bubble.width > bubbleText.width)
            assertTrue(name is EditText)
            val nameInput = name as EditText
            assertEquals("email keyboard must retain the text input class", InputType.TYPE_CLASS_TEXT, nameInput.inputType and InputType.TYPE_MASK_CLASS)
            assertEquals(Color.rgb(0x94, 0xa3, 0xb8), nameInput.hintTextColors.defaultColor)
            assertEquals(Color.rgb(0x22, 0xc5, 0x5e), nameInput.highlightColor)
            assertTrue(nameInput.filters.any { it is InputFilter.LengthFilter })
            assertEquals(
                InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
                nameInput.inputType and InputType.TYPE_MASK_VARIATION,
            )
            assertEquals(EditorInfo.IME_ACTION_DONE, nameInput.imeOptions and EditorInfo.IME_MASK_ACTION)
            click(activity, "toggle-input-colors")
            awaitText(activity, "input-style-status", "input colors off")
            assertSame("Removing input colors replaced the native field", nameInput, awaitView(activity, "name-input"))
            val defaultHintColor = nameInput.hintTextColors.defaultColor
            val defaultHighlightColor = nameInput.highlightColor
            click(activity, "toggle-input-colors")
            awaitText(activity, "input-style-status", "input colors on")
            assertSame("Restoring input colors replaced the native field", nameInput, awaitView(activity, "name-input"))
            click(activity, "toggle-invalid-input-colors")
            awaitText(activity, "invalid-input-style-status", "invalid input colors on")
            assertEquals("Invalid placeholder color should retain the native default", defaultHintColor, nameInput.hintTextColors.defaultColor)
            assertEquals("Invalid selection color should retain the native default", defaultHighlightColor, nameInput.highlightColor)
            click(activity, "toggle-invalid-input-colors")
            awaitText(activity, "invalid-input-style-status", "invalid input colors off")
            assertEquals(Color.rgb(0x94, 0xa3, 0xb8), nameInput.hintTextColors.defaultColor)
            assertEquals(Color.rgb(0x22, 0xc5, 0x5e), nameInput.highlightColor)
            val notes = awaitView(activity, "notes-input")
            assertTrue("multiline TextInput should be an EditText", notes is EditText)
            assertFalse("multiline TextInput should not be single line", (notes as EditText).isSingleLine)
            assertEquals(3, notes.maxLines)
            assertEquals("Draft", (notes as EditText).text.toString())
            assertEquals("Notes", notes.hint.toString())
            assertEquals(Color.rgb(0x22, 0xc5, 0x5e), notes.highlightColor)
            val booleanMaxLength = awaitView(activity, "boolean-max-length") as EditText
            instrumentation.runOnMainSync { booleanMaxLength.setText("AB") }
            assertEquals("Boolean maxLength was treated as numeric", "AB", booleanMaxLength.text.toString())
            val booleanInputLines = awaitView(activity, "boolean-input-lines") as EditText
            assertEquals("Boolean TextInput numberOfLines was treated as numeric", Int.MAX_VALUE, booleanInputLines.maxLines)
            val readonly = awaitView(activity, "readonly-input") as EditText
            assertTrue("editable=false should disable the native input", !readonly.isEnabled)
            assertEquals("Read only", readonly.text.toString())
            val password = awaitView(activity, "password-input") as EditText
            assertEquals(InputType.TYPE_TEXT_VARIATION_PASSWORD, password.inputType and InputType.TYPE_MASK_VARIATION)
            val title = awaitView(activity, "home-title")
            assertTrue(title is TextView)
            assertEquals(Color.WHITE, (title as TextView).currentTextColor)
            assertEquals("Text accessibility should use visible content, not its test identity", null, title.contentDescription)
            click(activity, "native-audio-context")
            awaitText(activity, "audio-context-status", "AudioContext ready")
            val disabled = awaitView(activity, "disabled-button") as Button
            assertFalse(disabled.isEnabled)
            val styled = awaitView(activity, "styled-row") as LinearLayout
            val styledFirst = awaitView(activity, "styled-first") as TextView
            val styledSecond = awaitView(activity, "styled-second") as TextView
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                assertTrue("explicit shadow offset did not install an outline", styled.outlineProvider !== ViewOutlineProvider.BACKGROUND)
            }
            val density = activity.resources.displayMetrics.density
            assertEquals(LinearLayout.HORIZONTAL, styled.orientation)
            assertTrue(styled.indexOfChild(styledSecond) < styled.indexOfChild(styledFirst))
            assertEquals((10 * density).roundToInt(), styled.paddingLeft)
            assertEquals((5 * density).roundToInt(), styled.paddingTop)
            assertEquals(0.75f, styled.alpha)
            assertEquals("transform translateX was not applied", (4 * density), styled.translationX, 1f)
            assertEquals("transform scaleX was not applied", 0.9f, styled.scaleX, 0.01f)
            assertEquals("transform rotate was not applied", 2f, styled.rotation, 0.1f)
            assertTrue("styled row should have laid out before skew drawing", styled.width > 0 && styled.height > 0)
            assertEquals("FIRST", styledFirst.text.toString())
            assertEquals(Color.rgb(0xfe, 0xdc, 0xba), styledFirst.currentTextColor)
            assertEquals(21f, styledFirst.textSize / density)
            assertTrue(styledFirst.typeface.style and Typeface.BOLD != 0)
            assertTrue(styledFirst.typeface.style and Typeface.ITALIC != 0)
            val decorations = (styledFirst.text as? Spanned)?.getSpans(0, styledFirst.text.length, ReplacementSpan::class.java).orEmpty()
            assertTrue("text decoration span was not applied", decorations.isNotEmpty())
            assertEquals((70 * density).toInt(), styledFirst.layoutParams.width)
            val gradient = awaitView(activity, "gradient-box")
            val gradientBackground = gradient.background as? GradientDrawable
            assertTrue("gradient fixture did not use a GradientDrawable", gradientBackground != null)
            assertEquals(GradientDrawable.Orientation.TL_BR, gradientBackground?.orientation)
            assertEquals(3, gradientBackground?.colors?.size)
            awaitView(activity, "grid-wrap")
            val gridFirst = awaitView(activity, "grid-first")
            val gridSecond = awaitView(activity, "grid-second")
            val gridThird = awaitView(activity, "grid-third")
            assertEquals(gridFirst.top, gridSecond.top)
            assertTrue("grid columns did not lay out side by side", gridSecond.left > gridFirst.left)
            assertTrue("grid rows did not advance after the first track", gridThird.top > gridFirst.top)
            awaitView(activity, "grid-template-rows")
            val templateFirst = awaitView(activity, "grid-template-rows-first")
            val templateThird = awaitView(activity, "grid-template-rows-third")
            assertEquals(templateFirst.height, templateThird.height)
            assertEquals("explicit grid rows did not fill the definite height", 44.0 * density, (templateThird.top - templateFirst.top).toDouble(), 1.0)
            val fractionalGrid = awaitView(activity, "grid-fractional-wrap")
            val fractionalFirst = awaitView(activity, "grid-fractional-first")
            val fractionalSecond = awaitView(activity, "grid-fractional-second")
            val fractionalThird = awaitView(activity, "grid-fractional-third")
            assertEquals(fractionalFirst.width, fractionalSecond.width)
            assertTrue("fractional grid columns overlapped", fractionalSecond.left > fractionalFirst.right)
            assertTrue("fractional grid overflowed its container", fractionalThird.right <= fractionalGrid.right)
            // A child's top and left are in its container's coordinates.
            val gridAlign = awaitView(activity, "grid-align-wrap")
            val gridAlignFirst = awaitView(activity, "grid-align-first")
            val gridAlignThird = awaitView(activity, "grid-align-third")
            assertTrue("grid alignContent did not center its rows", gridAlignFirst.top > (20 * density).toInt())
            val gridAspect = awaitView(activity, "grid-aspect-ratio-box")
            assertEquals((80 * density).toInt(), gridAspect.width)
            assertEquals((40 * density).toInt(), gridAspect.height)
            val gridPercentHeight = awaitView(activity, "grid-percent-height")
            assertEquals((40 * density).toInt(), gridPercentHeight.height)
            val gridEvenly = awaitView(activity, "grid-align-evenly-wrap")
            val gridEvenlyFirst = awaitView(activity, "grid-evenly-first")
            val gridEvenlyThird = awaitView(activity, "grid-evenly-third")
            assertTrue("grid space-evenly missed the leading slot", gridEvenlyFirst.top > (10 * density).toInt())
            assertTrue("grid space-evenly missed the inter-row slot", gridEvenlyThird.top - gridEvenlyFirst.top > (35 * density).toInt())
            val aspectRatioBox = awaitView(activity, "aspect-ratio-box")
            // 100 points is 262.5 pixels at 2.625: a pixel either way is rounding.
            assertEquals("aspectRatio width", 100.0 * density, aspectRatioBox.width.toDouble(), 1.0)
            assertEquals("aspectRatio height", 50.0 * density, aspectRatioBox.height.toDouble(), 1.0)
            val alignFirst = awaitView(activity, "align-content-first")
            val alignThird = awaitView(activity, "align-content-third")
            assertTrue("alignContent did not distribute wrapped lines", alignThird.top - alignFirst.top > (50 * density).toInt())
            awaitView(activity, "align-content-stretch-wrap")
            val stretchFirst = awaitView(activity, "align-stretch-first")
            val stretchThird = awaitView(activity, "align-stretch-third")
            assertTrue("alignContent stretch did not expand the first line", stretchFirst.height > (35 * density).toInt())
            assertTrue("alignContent stretch did not expand the line height", stretchThird.top - stretchFirst.top > (35 * density).toInt())
            val evenly = awaitView(activity, "align-content-evenly-wrap")
            val evenlyFirst = awaitView(activity, "align-evenly-first")
            val evenlyThird = awaitView(activity, "align-evenly-third")
            assertTrue("alignContent space-evenly missed the leading slot", evenlyFirst.top > (10 * density).toInt())
            assertTrue("alignContent space-evenly missed the inter-line slot", evenlyThird.top - evenlyFirst.top > (35 * density).toInt())
            val growFirst = awaitView(activity, "flex-grow-first")
            val growSecond = awaitView(activity, "flex-grow-second")
            assertTrue("flexGrow did not consume remaining main-axis space", growFirst.width > growSecond.width)
            val capped = awaitView(activity, "flex-bound-first")
            val redistributed = awaitView(activity, "flex-bound-second")
            assertEquals("maxWidth did not freeze the capped flex item", 64.0 * density, capped.width.toDouble(), 2.0 * density)
            assertTrue("remaining flex space was not redistributed", redistributed.width > capped.width + (40 * density).toInt())
            val justifyCenter = awaitView(activity, "justify-center-wrap")
            val justifyCenterFirst = awaitView(activity, "justify-center-first")
            val justifyCenterSecond = awaitView(activity, "justify-center-second")
            assertTrue("shared justify-center position was not applied", justifyCenterFirst.left > (20 * density).toInt())
            assertTrue("shared justify-center gap was not applied", justifyCenterSecond.left > justifyCenterFirst.right)
            val justifyBetween = awaitView(activity, "justify-between-wrap")
            val justifyBetweenFirst = awaitView(activity, "justify-between-first")
            val justifyBetweenSecond = awaitView(activity, "justify-between-second")
            assertTrue("shared space-between leading position was not applied", justifyBetweenFirst.left <= (20 * density).toInt())
            assertTrue("shared space-between trailing position was not applied", justifyBetweenSecond.right >= justifyBetween.width - (20 * density).toInt())
            val crossAxis = awaitView(activity, "cross-axis-wrap")
            val crossCenter = awaitView(activity, "cross-axis-center")
            val crossEnd = awaitView(activity, "cross-axis-end")
            assertTrue("alignItems center did not center the child", abs(crossCenter.top + crossCenter.height / 2 - crossAxis.height / 2) <= (3 * density).toInt())
            assertTrue("alignSelf flex-end did not move the child to the line end", crossEnd.top > crossCenter.top)
            val baseline = awaitView(activity, "baseline-wrap")
            val baselineLarge = awaitView(activity, "baseline-large")
            val baselineSmall = awaitView(activity, "baseline-small")
            assertTrue("baseline alignment did not lower the smaller label", baselineLarge.top < baselineSmall.top)
            val reverseColumn = awaitView(activity, "reverse-column") as LinearLayout
            val reverseColumnFirst = awaitView(activity, "reverse-column-first")
            val reverseColumnSecond = awaitView(activity, "reverse-column-second")
            assertEquals(LinearLayout.VERTICAL, reverseColumn.orientation)
            assertTrue("column-reverse did not invert the main axis", reverseColumnFirst.top > reverseColumnSecond.top)
            val reverseWrap = awaitView(activity, "reverse-wrap")
            val reverseWrapFirst = awaitView(activity, "reverse-wrap-first")
            val reverseWrapSecond = awaitView(activity, "reverse-wrap-second")
            val reverseWrapThird = awaitView(activity, "reverse-wrap-third")
            val reverseWrapFourth = awaitView(activity, "reverse-wrap-fourth")
            assertTrue("row-reverse did not reverse the first wrapped line", reverseWrapFirst.left > reverseWrapSecond.left)
            assertTrue("row-reverse did not reverse the second wrapped line", reverseWrapThird.left > reverseWrapFourth.left)
            assertTrue("row-reverse reversed wrapped line order", reverseWrapThird.top > reverseWrapFirst.top)
            assertTrue("row-reverse wrapped line escaped its container", reverseWrapFourth.bottom <= reverseWrap.bottom)
            val link = awaitView(activity, "native-link")
            assertTrue("native link should be a TextView", link is TextView)
            assertEquals("Open native link", (link as TextView).text.toString())
            assertTrue(link.contentDescription.toString().contains("ready"))
            assertEquals("Opens status", link.tooltipText)
            instrumentation.runOnMainSync { link.performClick() }
            awaitText(activity, "native-link-status", "link pressed")
            click(activity, "toggle-link-accessibility")
            awaitText(activity, "native-link-status", "link accessibility disabled")
            assertTrue("accessibilityState.disabled should disable the link", !link.isEnabled)
            click(activity, "toggle-link-accessibility")
            awaitText(activity, "native-link-status", "link accessibility enabled")
            assertTrue("clearing accessibilityState.disabled should restore the link", link.isEnabled)
            instrumentation.runOnMainSync { link.performClick() }
            awaitText(activity, "native-link-status", "link pressed")
            val panel = awaitView(activity, "native-panel")
            instrumentation.runOnMainSync { panel.performClick() }
            awaitText(activity, "native-link-status", "panel pressed")
            click(activity, "toggle-panel-accessibility")
            awaitText(activity, "native-link-status", "panel accessibility disabled")
            assertFalse("accessibilityState.disabled should disable a generic pressable", panel.isEnabled)
            click(activity, "toggle-panel-accessibility")
            awaitText(activity, "native-link-status", "panel accessibility enabled")
            assertTrue("clearing accessibilityState.disabled should restore a generic pressable", panel.isEnabled)
            instrumentation.runOnMainSync { panel.performClick() }
            awaitText(activity, "native-link-status", "panel pressed")
            val pressable = awaitView(activity, "native-pressable")
            assertTrue("native Pressable should be a container", pressable is ViewGroup)
            instrumentation.runOnMainSync { pressable.performClick() }
            awaitText(activity, "native-link-status", "pressable pressed")
            val rawPressable = awaitView(activity, "native-raw-pressable") as ViewGroup
            val rawLabel = (0 until rawPressable.childCount)
                .map { rawPressable.getChildAt(it) }
                .filterIsInstance<TextView>()
                .firstOrNull { it.text.toString() == "RAW PRESSABLE" }
            assertTrue("raw native text child was not created", rawLabel != null)
            assertEquals("raw native text did not inherit its parent colour", Color.rgb(0xef, 0x44, 0x44), rawLabel!!.currentTextColor)
            assertEquals("raw native text did not inherit its parent font size", 18f, rawLabel.textSize / activity.resources.displayMetrics.scaledDensity, 0.1f)
            instrumentation.runOnMainSync {
                val downTime = SystemClock.uptimeMillis()
                val x = pressable.width / 2f
                val y = pressable.height / 2f
                val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0)
                val up = MotionEvent.obtain(downTime, downTime + 32, MotionEvent.ACTION_UP, x, y, 0)
                pressable.dispatchTouchEvent(down)
                pressable.dispatchTouchEvent(up)
                down.recycle()
                up.recycle()
            }
            awaitText(activity, "pressable-lifecycle", "Press lifecycle: 1/1")
            val disabledPressable = awaitView(activity, "disabled-pressable")
            assertFalse("disabled Pressable should be disabled", disabledPressable.isEnabled)
            instrumentation.runOnMainSync { disabledPressable.performClick() }
            awaitText(activity, "native-link-status", "pressable pressed")
            val longPressPanel = awaitView(activity, "long-press-panel")
            assertTrue("generic onLongPress view was not long-clickable", longPressPanel.performLongClick())
            awaitText(activity, "long-press-status", "panel long pressed")
            click(activity, "toggle-long-press-accessibility")
            awaitText(activity, "long-press-status", "long press disabled")
            assertTrue("disabled long-press view remained enabled", !longPressPanel.isEnabled)
            assertTrue("disabled long-press view still accepted a click", !longPressPanel.performLongClick())
            click(activity, "toggle-long-press-accessibility")
            awaitText(activity, "long-press-status", "long press enabled")
            assertTrue("re-enabled long-press view did not accept a click", longPressPanel.performLongClick())
            awaitText(activity, "long-press-status", "panel long pressed")
            val initiallyTintedBackground = awaitView(activity, "native-image-background") as ViewGroup
            assertTrue("initial ImageBackground tint was not applied", (initiallyTintedBackground.getChildAt(0) as ImageView).colorFilter != null)
            click(activity, "toggle-image-tint")
            awaitText(activity, "image-tint-status", "image tint off")
            awaitImageTintCleared(activity, "native-image")
            val dynamicResizeImage = awaitView(activity, "dynamic-resize-image") as ImageView
            assertEquals("dynamic image should start in cover mode", ImageView.ScaleType.CENTER_CROP, dynamicResizeImage.scaleType)
            click(activity, "toggle-image-resize-mode")
            awaitText(activity, "image-resize-mode-status", "contain")
            assertEquals("dynamic image resize mode was not reconciled", ImageView.ScaleType.CENTER_INSIDE, dynamicResizeImage.scaleType)
            click(activity, "toggle-image-resize-mode")
            awaitText(activity, "image-resize-mode-status", "cover")
            assertEquals("dynamic image resize mode did not restore cover", ImageView.ScaleType.CENTER_CROP, dynamicResizeImage.scaleType)
            val clearedBackgroundImage = (awaitView(activity, "native-image-background") as ViewGroup).getChildAt(0) as ImageView
            assertTrue("ImageBackground tint was not cleared", clearedBackgroundImage.colorFilter == null)
            val tintedUnsupported = awaitView(activity, "unsupported-image") as ImageView
            assertEquals(1, tintedUnsupported.contentDescription.toString().split("Unsupported image source").size - 1)
            val paddingButton = awaitView(activity, "toggle-button-padding") as Button
            val initialButtonPadding = paddingButton.paddingLeft
            click(activity, "toggle-button-padding")
            repeat(75) {
                if (paddingButton.paddingLeft > initialButtonPadding) return@repeat
                SystemClock.sleep(100)
            }
            assertTrue("button padding style was not applied", paddingButton.paddingLeft > initialButtonPadding)
            click(activity, "toggle-button-padding")
            repeat(75) {
                if (paddingButton.paddingLeft == initialButtonPadding) return@repeat
                SystemClock.sleep(100)
            }
            assertEquals("removed button padding style was retained", initialButtonPadding, paddingButton.paddingLeft)
            val paddedNameInput = awaitView(activity, "name-input") as EditText
            val initialInputPadding = paddedNameInput.paddingLeft
            click(activity, "toggle-input-padding")
            repeat(75) {
                if (paddedNameInput.paddingLeft > initialInputPadding) return@repeat
                SystemClock.sleep(100)
            }
            assertTrue("input padding style was not applied", paddedNameInput.paddingLeft > initialInputPadding)
            click(activity, "toggle-input-padding")
            repeat(75) {
                if (paddedNameInput.paddingLeft == initialInputPadding) return@repeat
                SystemClock.sleep(100)
            }
            assertEquals("removed input padding style was retained", initialInputPadding, paddedNameInput.paddingLeft)
            val styleToggle = awaitView(activity, "toggle-button-style") as Button
            var styleInfo: AccessibilityNodeInfo? = null
            instrumentation.runOnMainSync { styleInfo = styleToggle.createAccessibilityNodeInfo() }
            assertTrue("selected accessibility state should start clear", styleInfo?.isSelected == false)
            click(activity, "toggle-button-style")
            awaitText(activity, "native-link-status", "button style accented")
            val accentedButton = awaitView(activity, "toggle-button-style") as Button
            assertEquals(Color.rgb(0xef, 0x44, 0x44), accentedButton.currentTextColor)
            instrumentation.runOnMainSync { styleInfo = accentedButton.createAccessibilityNodeInfo() }
            assertTrue("selected accessibility state was not exposed", styleInfo?.isSelected == true)
            click(activity, "toggle-button-style")
            awaitText(activity, "native-link-status", "button style default")
            val restoredButton = awaitView(activity, "toggle-button-style") as Button
            assertEquals("removing the authored button color did not restore the theme color", Color.rgb(0x22, 0xc5, 0x5e), restoredButton.currentTextColor)
            instrumentation.runOnMainSync { styleInfo = restoredButton.createAccessibilityNodeInfo() }
            assertTrue("clearing the selected state was not exposed", styleInfo?.isSelected == false)
            val propColorToggle = awaitView(activity, "toggle-button-prop-color") as Button
            val defaultPropColor = propColorToggle.currentTextColor
            click(activity, "toggle-button-prop-color")
            awaitText(activity, "native-link-status", "button prop accented")
            assertEquals(Color.rgb(0xef, 0x44, 0x44), propColorToggle.currentTextColor)
            click(activity, "toggle-button-prop-color")
            awaitText(activity, "native-link-status", "button prop default")
            assertEquals("removing the direct button color did not restore the baseline", defaultPropColor, propColorToggle.currentTextColor)
            val dynamicStyleBox = awaitView(activity, "dynamic-style-box")
            assertTrue("custom panel style should use a GradientDrawable", dynamicStyleBox.background is GradientDrawable)
            click(activity, "toggle-panel-style")
            awaitText(activity, "panel-style-status", "panel style off")
            assertTrue("removing panel style should restore the default background", dynamicStyleBox.background == null)
            click(activity, "toggle-panel-style")
            awaitText(activity, "panel-style-status", "panel style on")
            assertTrue("restoring panel style should recreate its drawable", dynamicStyleBox.background is GradientDrawable)
            val dynamicShadowBox = awaitView(activity, "dynamic-shadow-box")
            click(activity, "toggle-shadow-style")
            awaitText(activity, "shadow-style-status", "shadow style off")
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                assertEquals("removed shadow style retained ambient color", Color.BLACK, dynamicShadowBox.outlineAmbientShadowColor)
                assertEquals("removed shadow style retained spot color", Color.BLACK, dynamicShadowBox.outlineSpotShadowColor)
                assertEquals("removed shadow style retained elevation", 0f, dynamicShadowBox.elevation)
            }
            click(activity, "toggle-shadow-style")
            awaitText(activity, "shadow-style-status", "shadow style on")
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                assertTrue("restoring shadow style did not apply a custom ambient color", dynamicShadowBox.outlineAmbientShadowColor != Color.BLACK)
                assertTrue("restoring shadow style did not install an outline", dynamicShadowBox.outlineProvider !== ViewOutlineProvider.BACKGROUND)
            }
            val nullWidthText = awaitView(activity, "null-width-text")
            val explicitTextWidth = nullWidthText.width
            assertTrue("explicit text width was not applied", explicitTextWidth > (150 * density).toInt())
            click(activity, "toggle-null-width")
            awaitWidthDecrease(nullWidthText, explicitTextWidth, 20, density)
            val percentWidth = awaitView(activity, "percent-width")
            assertEquals((120 * density).toInt(), percentWidth.width)
            val percentBasisFirst = awaitView(activity, "percent-basis-first")
            val percentBasisSecond = awaitView(activity, "percent-basis-second")
            assertEquals((120 * density).toInt(), percentBasisFirst.width)
            assertEquals((120 * density).toInt(), percentBasisSecond.width)
            val independentGapFirst = awaitView(activity, "independent-gap-first")
            val independentGapSecond = awaitView(activity, "independent-gap-second")
            val independentGapThird = awaitView(activity, "independent-gap-third")
            assertEquals(
                "column gap was not shared through the native layout ABI",
                50.0 * density,
                (independentGapSecond.left - independentGapFirst.left).toDouble(),
                1.0,
            )
            assertEquals(
                "row gap was not shared through the native layout ABI",
                22.0 * density,
                (independentGapThird.top - independentGapFirst.top).toDouble(),
                1.0,
            )
            val nestedSharedColumn = awaitView(activity, "nested-shared-column")
            val nestedSharedFirst = awaitView(activity, "nested-shared-first")
            val nestedSharedSecond = awaitView(activity, "nested-shared-second")
            val nestedSharedSibling = awaitView(activity, "nested-shared-sibling")
            assertEquals(
                "nested column gap was not preserved",
                18.0 * density,
                (nestedSharedSecond.top - nestedSharedFirst.top).toDouble(),
                1.0,
            )
            assertEquals(
                "nested row gap was not preserved",
                80.0 * density,
                (nestedSharedSibling.left - nestedSharedColumn.left).toDouble(),
                1.0,
            )
            val nestedPercentParent = awaitView(activity, "nested-percent-parent")
            val nestedPercentChild = awaitView(activity, "nested-percent-child")
            assertEquals((80 * density).toInt(), nestedPercentParent.width)
            assertEquals(
                "nested percentage width used the outer parent",
                36.0 * density,
                nestedPercentChild.width.toDouble(),
                1.0,
            )
            assertEquals(
                "nested percentage height used the outer parent",
                26.0 * density,
                nestedPercentChild.height.toDouble(),
                1.0,
            )
            val booleanWidthText = awaitView(activity, "boolean-width-text")
            assertTrue(
                "boolean width was treated as a numeric layout length",
                booleanWidthText.width > 20.0 * density,
            )
            val booleanFontSizeText = awaitView(activity, "boolean-font-size-text") as TextView
            assertTrue(
                "boolean font size was treated as a numeric style",
                booleanFontSizeText.textSize > 10.0f * density,
            )
            val booleanNumberLines = awaitView(activity, "boolean-number-lines") as TextView
            assertTrue(
                "boolean numberOfLines was treated as numeric",
                booleanNumberLines.height > 24.0 * density,
            )
            val nestedShrinkRowText = awaitView(activity, "nested-shrink-row-text")
            val nestedShrinkColumnText = awaitView(activity, "nested-shrink-column-text")
            assertEquals(
                "nested horizontal text did not use its parent flex-shrink default",
                60.0 * density,
                nestedShrinkRowText.width.toDouble(),
                1.0,
            )
            assertEquals(
                "nested vertical text incorrectly used a horizontal flex-shrink default",
                80.0 * density,
                nestedShrinkColumnText.height.toDouble(),
                1.0,
            )
            val nestedGrid = awaitView(activity, "nested-grid")
            val nestedGridFirst = awaitView(activity, "nested-grid-first")
            val nestedGridSecond = awaitView(activity, "nested-grid-second")
            val nestedGridThird = awaitView(activity, "nested-grid-third")
            val nestedGridSibling = awaitView(activity, "nested-grid-sibling")
            assertEquals(
                "nested grid columns were not shared through the tree ABI",
                52.0 * density,
                (nestedGridSecond.left - nestedGridFirst.left).toDouble(),
                1.0,
            )
            assertEquals(
                "nested grid rows were not shared through the tree ABI",
                26.0 * density,
                (nestedGridThird.top - nestedGridFirst.top).toDouble(),
                1.0,
            )
            assertEquals(
                "nested grid parent placement was not preserved",
                110.0 * density,
                (nestedGridSibling.left - nestedGrid.left).toDouble(),
                1.0,
            )
            val nestedReverse = awaitView(activity, "nested-reverse")
            val nestedReverseFirst = awaitView(activity, "nested-reverse-first")
            val nestedReverseSecond = awaitView(activity, "nested-reverse-second")
            val nestedReverseSibling = awaitView(activity, "nested-reverse-sibling")
            assertTrue("nested reverse flow did not use the shared v2 tree ABI", nestedReverseFirst.top > nestedReverseSecond.top)
            assertEquals("nested reverse parent placement was not preserved", (56 * density).toInt(), nestedReverseSibling.left - nestedReverse.left)
            val nestedWrapReverse = awaitView(activity, "nested-wrap-reverse")
            val nestedWrapReverseFirst = awaitView(activity, "nested-wrap-reverse-first")
            val nestedWrapReverseSecond = awaitView(activity, "nested-wrap-reverse-second")
            val nestedWrapReverseSibling = awaitView(activity, "nested-wrap-reverse-sibling")
            assertTrue("nested wrap-reverse flow did not use the shared v3 tree ABI", nestedWrapReverseFirst.top > nestedWrapReverseSecond.top)
            assertEquals("nested wrap-reverse parent placement was not preserved", (56 * density).toInt(), nestedWrapReverseSibling.left - nestedWrapReverse.left)
            val toggle = awaitView(activity, "native-switch")
            assertTrue("native switch should be an Android Switch", toggle is Switch)
            val nativeSwitch = toggle as Switch
            assertTrue("native switch should start off", !nativeSwitch.isChecked)
            assertTrue("native switch should apply track tint", nativeSwitch.trackTintList != null)
            assertTrue("native switch should apply thumb tint", nativeSwitch.thumbTintList != null)
            val uncontrolledSwitch = awaitView(activity, "uncontrolled-switch") as Switch
            assertTrue("uncontrolled switch should start off", !uncontrolledSwitch.isChecked)
            instrumentation.runOnMainSync { uncontrolledSwitch.performClick() }
            assertTrue("uncontrolled switch should keep its native toggle", uncontrolledSwitch.isChecked)
            val nullableSwitch = awaitView(activity, "nullable-switch") as Switch
            assertTrue("null switch value should fall back to checked", nullableSwitch.isChecked)
            val precedenceSwitch = awaitView(activity, "switch-value-precedence") as Switch
            assertTrue("non-null switch value should take precedence over checked", !precedenceSwitch.isChecked)
            var nullableSwitchInfo: AccessibilityNodeInfo? = null
            instrumentation.runOnMainSync { nullableSwitchInfo = nullableSwitch.createAccessibilityNodeInfo() }
            assertTrue("native checked state should remain accessible without accessibilityState", nullableSwitchInfo?.isChecked == true)
            click(activity, "toggle-invalid-switch-colors")
            awaitText(activity, "invalid-control-style-status", "invalid switch colors on")
            assertTrue("uncontrolled switch should survive reconciliation", uncontrolledSwitch.isChecked)
            assertTrue("Invalid switch track colors should restore the native default", nativeSwitch.trackTintList == null)
            assertTrue("Invalid switch thumb color should restore the native default", nativeSwitch.thumbTintList == null)
            click(activity, "toggle-invalid-switch-colors")
            awaitText(activity, "invalid-control-style-status", "invalid switch colors off")
            assertTrue("Restored switch track colors should be applied", nativeSwitch.trackTintList != null)
            assertTrue("Restored switch thumb color should be applied", nativeSwitch.thumbTintList != null)
            val picker = awaitView(activity, "native-picker")
            assertTrue("native picker should be an Android Spinner", picker is Spinner)
            // Spinner finishes adapter initialization on the UI queue. Drain
            // that work before simulating a choice, as a real picker tap does.
            instrumentation.waitForIdleSync()
            awaitText(activity, "picker-value", "one")
            assertEquals("initial picker selection must not emit onChange", "button prop default", (awaitView(activity, "native-link-status") as TextView).text.toString())
            instrumentation.runOnMainSync { (picker as Spinner).setSelection(1) }
            awaitText(activity, "picker-value", "two")
            awaitText(activity, "native-link-status", "picker two")
            val itemsPicker = awaitView(activity, "native-items-picker")
            assertTrue("items picker should be an Android Spinner", itemsPicker is Spinner)
            instrumentation.waitForIdleSync()
            awaitText(activity, "items-picker-value", "one")
            assertEquals("reconciling another picker must not emit onChange", "picker two", (awaitView(activity, "native-link-status") as TextView).text.toString())
            assertEquals("selectedValue should take precedence over value", 0, (itemsPicker as Spinner).selectedItemPosition)
            instrumentation.runOnMainSync { (itemsPicker as Spinner).setSelection(1) }
            // Both native hosts serialize a numeric option through Double.
            awaitText(activity, "items-picker-value", "2.0")
            awaitText(activity, "native-link-status", "items picker 2.0")
            val dateRoot = awaitView(activity, "native-date-picker")
            val nativeDatePicker = findType(dateRoot, DatePicker::class.java)
            assertTrue("native date picker should contain an Android DatePicker", nativeDatePicker != null)
            assertEquals("date picker minimum bound", "2026-10-01", java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date(nativeDatePicker!!.minDate)))
            assertEquals("date picker maximum bound", "2026-12-31", java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date(nativeDatePicker.maxDate)))
            instrumentation.runOnMainSync { nativeDatePicker.updateDate(2026, 10, 15) }
            awaitText(activity, "date-value", "2026-11-15")
            awaitText(activity, "date-event-status", "2026-11-15|event complete")
            val timeRoot = awaitView(activity, "native-time-picker")
            val nativeTimePicker = findType(timeRoot, TimePicker::class.java)
            assertTrue("native time picker should contain an Android TimePicker", nativeTimePicker != null)
            assertEquals(7, nativeTimePicker!!.hour)
            assertEquals(30, nativeTimePicker.minute)
            instrumentation.runOnMainSync { nativeTimePicker.minute = 33 }
            awaitText(activity, "time-value", "07:35")
            awaitText(activity, "date-event-status", "07:35|event complete")
            val countdownRoot = awaitView(activity, "native-countdown")
            val nativeCountdown = findType(countdownRoot, TimePicker::class.java)
            assertTrue("native countdown should contain an Android TimePicker", nativeCountdown != null)
            assertEquals(1, nativeCountdown!!.hour)
            assertEquals(30, nativeCountdown.minute)
            instrumentation.runOnMainSync { nativeCountdown.minute = 31 }
            awaitText(activity, "countdown-value", "01:31:45")
            awaitText(activity, "date-event-status", "01:31:45|duration complete")
            val checkbox = awaitView(activity, "native-checkbox")
            assertTrue("native checkbox should be an Android CheckBox", checkbox is CheckBox)
            assertFalse("native checkbox should start unchecked", (checkbox as CheckBox).isChecked)
            instrumentation.runOnMainSync { checkbox.performClick() }
            awaitText(activity, "checkbox-status", "checkbox on")
            var checkboxInfo: AccessibilityNodeInfo? = null
            instrumentation.runOnMainSync { checkboxInfo = checkbox.createAccessibilityNodeInfo() }
            assertTrue("native checkbox checked state should remain accessible without accessibilityState", checkboxInfo?.isChecked == true)
            // Prop updates must retain the dedicated change handler too.
            instrumentation.runOnMainSync { checkbox.performClick() }
            awaitText(activity, "checkbox-status", "checkbox off")
            instrumentation.runOnMainSync { checkbox.performClick() }
            awaitText(activity, "checkbox-status", "checkbox on")
            val indeterminateCheckbox = awaitView(activity, "native-checkbox-indeterminate") as CheckBox
            assertFalse("indeterminate checkbox should not report checked", indeterminateCheckbox.isChecked)
            assertTrue("indeterminate checkbox should retain its mixed state", indeterminateCheckbox.isActivated)
            assertEquals("mixed", ViewCompat.getStateDescription(indeterminateCheckbox))
            instrumentation.runOnMainSync { indeterminateCheckbox.performClick() }
            assertTrue("indeterminate checkbox should become checked on first toggle", indeterminateCheckbox.isChecked)
            val precedenceCheckbox = awaitView(activity, "checkbox-checked-precedence") as CheckBox
            assertTrue("checked should take precedence over value", !precedenceCheckbox.isChecked)
            val styledIndicator = awaitView(activity, "native-indicator") as ProgressBar
            assertTrue("authored activity-indicator color should be applied", styledIndicator.indeterminateTintList != null)
            click(activity, "toggle-invalid-control-colors")
            awaitText(activity, "invalid-control-style-status", "invalid control colors on")
            assertTrue("Invalid checkbox color should restore the native default", (checkbox as CheckBox).buttonTintList == null)
            assertTrue("Invalid activity-indicator color should restore the native default", styledIndicator.indeterminateTintList == null)
            click(activity, "toggle-invalid-control-colors")
            awaitText(activity, "invalid-control-style-status", "invalid control colors off")
            assertTrue("Restored checkbox color should be applied", (checkbox as CheckBox).buttonTintList != null)
            assertTrue("Restored activity-indicator color should be applied", styledIndicator.indeterminateTintList != null)
            val modal = awaitView(activity, "native-modal")
            assertTrue("native modal should be a container", modal is ViewGroup)
            assertEquals("modal should start hidden", View.GONE, modal.visibility)
            click(activity, "toggle-modal")
            repeat(20) {
                if (modal.visibility == View.VISIBLE) return@repeat
                SystemClock.sleep(100)
            }
            assertEquals("modal should become visible", View.VISIBLE, modal.visibility)
            awaitText(activity, "modal-content", "Modal content")
            // onShow is delivered after native reconciliation returns to the queue.
            awaitText(activity, "modal-status", "modal shown")
            awaitText(activity, "modal-opacity", "1")
            click(activity, "toggle-modal-opacity")
            awaitText(activity, "modal-opacity", "0.45")
            assertEquals("visible modal opacity should update in place", 0.45f, modal.alpha, 0.01f)
            click(activity, "toggle-modal")
            awaitText(activity, "modal-status", "modal dismissed")
            click(activity, "toggle-modal")
            awaitText(activity, "modal-status", "modal shown")
            instrumentation.runOnMainSync { activity.onBackPressed() }
            awaitText(activity, "modal-request-status", "modal requested back")
            awaitText(activity, "modal-status", "modal dismissed")
            click(activity, "toggle-modal")
            awaitText(activity, "modal-status", "modal shown")
            click(activity, "toggle-nested-popup")
            val popupDensity = activity.resources.displayMetrics.density
            val nestedPopup = awaitView(activity, "nested-popup") {
                it.width == (160 * popupDensity).roundToInt() && it.height == (64 * popupDensity).roundToInt()
                    && it.left == (48 * popupDensity).roundToInt() && it.top == (72 * popupDensity).roundToInt()
            }
            awaitText(activity, "nested-popup-content", "Nested popup")
            // Modal overlays are promoted beside the authored root. Dispatch
            // through their actual screen viewport, as real touch input does.
            val popupRoot = nestedPopup.parent as ViewGroup
            assertSame("nested popup should share its modal's screen viewport", modal.parent, popupRoot)
            assertSame("authored root should remain inside that viewport", awaitView(activity, "root").parent, popupRoot)
            assertTrue("nested popup should remain above its parent modal (popup=${popupRoot.indexOfChild(nestedPopup)}, modal=${popupRoot.indexOfChild(modal)})", popupRoot.indexOfChild(nestedPopup) > popupRoot.indexOfChild(modal))
            instrumentation.runOnMainSync {
                val downTime = SystemClock.uptimeMillis()
                val x = (popupRoot.width - 20).toFloat()
                val y = (popupRoot.height - 20).toFloat()
                val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0)
                popupRoot.dispatchTouchEvent(down)
                down.recycle()
                val up = MotionEvent.obtain(downTime, downTime + 32, MotionEvent.ACTION_UP, x, y, 0)
                popupRoot.dispatchTouchEvent(up)
                up.recycle()
            }
            awaitText(activity, "nested-popup-request-status", "nested popup requested backdrop")
            var nestedPopupRemoved = false
            repeat(25) {
                instrumentation.runOnMainSync { nestedPopupRemoved = find(activity.window.decorView, "nested-popup") == null }
                if (nestedPopupRemoved) return@repeat
                SystemClock.sleep(100)
            }
            assertTrue("dismissed nested popup should be removed", nestedPopupRemoved || nestedPopup.visibility != View.VISIBLE)
            assertEquals("dismissing a nested popup should retain its parent modal", View.VISIBLE, modal.visibility)
            // Close the parent before the independent popup test. Otherwise
            // the later reopen can incorrectly pass on a stale onShow label.
            click(activity, "toggle-modal")
            awaitText(activity, "modal-status", "modal dismissed")
            click(activity, "toggle-popup")
            val popup = awaitView(activity, "native-popup") {
                it.width == (180 * popupDensity).roundToInt() && it.height == (72 * popupDensity).roundToInt()
                    && it.left == (24 * popupDensity).roundToInt() && it.top == (36 * popupDensity).roundToInt()
            }
            awaitText(activity, "popup-content", "Popup content")
            assertEquals(
                "non-modal top should use the screenViewport origin, not a second safe-area offset",
                (36 * popupDensity).roundToInt(), popup.top,
            )
            instrumentation.runOnMainSync {
                val downTime = SystemClock.uptimeMillis()
                val x = (popupRoot.width - 20).toFloat()
                val y = (popupRoot.height - 20).toFloat()
                val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0)
                popupRoot.dispatchTouchEvent(down)
                down.recycle()
                val up = MotionEvent.obtain(downTime, downTime + 32, MotionEvent.ACTION_UP, x, y, 0)
                popupRoot.dispatchTouchEvent(up)
                up.recycle()
            }
            awaitText(activity, "popup-request-status", "popup requested backdrop")
            var popupRemoved = false
            repeat(25) {
                instrumentation.runOnMainSync { popupRemoved = find(activity.window.decorView, "native-popup") == null }
                if (popupRemoved) return@repeat
                SystemClock.sleep(100)
            }
            assertTrue("dismissed non-modal popup should be removed", popupRemoved || popup.visibility != View.VISIBLE)
            click(activity, "toggle-modal")
            awaitText(activity, "modal-status", "modal shown")
            click(activity, "remove-modal")
            var removed = false
            repeat(25) {
                instrumentation.runOnMainSync { removed = find(activity.window.decorView, "native-modal") == null }
                if (removed) return@repeat
                SystemClock.sleep(100)
            }
            assertTrue("unmounted modal should be removed from the screen overlay", removed)
            val justifiedText = awaitView(activity, "justified-text") as TextView
            assertEquals("justified text should use the Android inter-word mode", Layout.JUSTIFICATION_MODE_INTER_WORD, justifiedText.justificationMode)
            instrumentation.runOnMainSync { nativeSwitch.performClick() }
            awaitText(activity, "native-link-status", "switch on")
            var switchInfo: AccessibilityNodeInfo? = null
            instrumentation.runOnMainSync { switchInfo = nativeSwitch.createAccessibilityNodeInfo() }
            assertTrue("checked accessibility state was not exposed", switchInfo?.isChecked == true)
            val slider = awaitView(activity, "native-slider")
            assertTrue("native slider should be a SeekBar", slider is SeekBar)
            // One native position represents each authored 0.1 step.
            assertEquals("stepped slider should expose ten positions", 10, (slider as SeekBar).max)
            instrumentation.runOnMainSync { slider.progress = 8 }
            awaitText(activity, "native-link-status", "slider moved")
            awaitText(activity, "slider-value", "0.8")
            val nativeSlider = slider as SeekBar
            assertEquals("slider thumb should retain its selected step", 8, nativeSlider.progress)
            assertEquals("slider minimum tint was not applied", Color.rgb(0x22, 0xc5, 0x5e), nativeSlider.progressTintList?.getColorForState(intArrayOf(), Color.TRANSPARENT))
            assertEquals("slider maximum tint was not applied", Color.rgb(0x64, 0x74, 0x8b), nativeSlider.progressBackgroundTintList?.getColorForState(intArrayOf(), Color.TRANSPARENT))
            assertEquals("slider thumb tint was not applied", Color.rgb(0x16, 0xa3, 0x4a), nativeSlider.thumbTintList?.getColorForState(intArrayOf(), Color.TRANSPARENT))
            val booleanSlider = awaitView(activity, "boolean-slider") as SeekBar
            assertEquals("Boolean slider minimum was treated as numeric", 500, booleanSlider.progress)
            click(activity, "toggle-invalid-slider-colors")
            awaitText(activity, "invalid-slider-style-status", "invalid slider colors on")
            assertTrue("Invalid minimum slider tint should restore the native default", nativeSlider.progressTintList == null)
            assertTrue("Invalid maximum slider tint should restore the native default", nativeSlider.progressBackgroundTintList == null)
            assertTrue("Invalid thumb slider tint should restore the native default", nativeSlider.thumbTintList == null)
            click(activity, "toggle-invalid-slider-colors")
            awaitText(activity, "invalid-slider-style-status", "invalid slider colors off")
            assertEquals(Color.rgb(0x22, 0xc5, 0x5e), nativeSlider.progressTintList?.getColorForState(intArrayOf(), Color.TRANSPARENT))
            assertEquals(Color.rgb(0x64, 0x74, 0x8b), nativeSlider.progressBackgroundTintList?.getColorForState(intArrayOf(), Color.TRANSPARENT))
            assertEquals(Color.rgb(0x16, 0xa3, 0x4a), nativeSlider.thumbTintList?.getColorForState(intArrayOf(), Color.TRANSPARENT))
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
            val nativeIndicator = awaitView(activity, "native-indicator") as ProgressBar
            assertEquals("authored activity-indicator color was not applied", Color.rgb(0x22, 0xc5, 0x5e), nativeIndicator.indeterminateTintList?.getColorForState(intArrayOf(), Color.TRANSPARENT))
            val booleanIndicator = awaitProgressBar(activity, "boolean-indicator", "Boolean size fallback") { it.isShown }
            assertEquals("Boolean ActivityIndicator size was treated as numeric", 1f, booleanIndicator.scaleX)
            assertEquals(1f, booleanIndicator.scaleY)
            val stoppedIndicator = awaitProgressBar(activity, "stopped-indicator", "visible and stopped") {
                it.isShown && !it.isIndeterminate
            }
            assertTrue("stopped indicator should stay visible when requested", stoppedIndicator.isShown)
            assertTrue("stopped indicator should not animate", !stoppedIndicator.isIndeterminate)
            assertEquals(0.75f, stoppedIndicator.scaleX)
            assertEquals(0.75f, stoppedIndicator.scaleY)
            click(activity, "toggle-indicator-hide")
            awaitProgressBar(activity, "stopped-indicator", "hidden after dynamic prop change") { it.visibility == View.GONE }
            click(activity, "toggle-indicator-hide")
            awaitProgressBar(activity, "stopped-indicator", "visible after clearing hide prop") { it.isShown && !it.isIndeterminate }
            click(activity, "toggle-indicator-size")
            val enlargedIndicator = awaitProgressBar(activity, "stopped-indicator", "large size") { it.scaleX == 1.35f }
            assertEquals(1.35f, enlargedIndicator.scaleY)
            click(activity, "toggle-indicator-size")
            val resizedIndicator = awaitProgressBar(activity, "stopped-indicator", "small size restored") { it.scaleX == 0.75f }
            assertEquals(0.75f, resizedIndicator.scaleY)
            val scaledIndicator = awaitProgressBar(activity, "scaled-indicator", "numeric size with authored transform") { it.isShown }
            assertEquals(1f, scaledIndicator.scaleX)
            assertEquals(1f, scaledIndicator.scaleY)
            val hiddenIndicator = awaitProgressBar(activity, "hidden-indicator", "hidden") { it.visibility == View.GONE }
            assertEquals("hidesWhenStopped should hide a stopped indicator", View.GONE, hiddenIndicator.visibility)
            val displayNoneIndicator = awaitProgressBar(activity, "display-none-indicator", "hidden") { it.visibility == View.GONE }
            assertEquals("display:none should hide an activity indicator", View.GONE, displayNoneIndicator.visibility)
            val wrapped = awaitView(activity, "layout-wrap") as LinearLayout
            awaitLayoutWidth(activity, "layout-status", 240.0)
            click(activity, "toggle-layout-width")
            val reportedWidth = awaitLayoutWidth(activity, "layout-status", 180.0)
            assertEquals("layout event must describe the actual native frame", wrapped.width.toDouble() / density.toDouble(), reportedWidth, 0.000001)
            assertEquals("native frame must resize within one physical pixel", 180.0 * density.toDouble(), wrapped.width.toDouble(), 1.0)
            awaitLayoutWidth(activity, "layout-transform-status", 100.0)
            awaitText(activity, "hidden-layout-status", "Hidden layout events: 0")
            val bounded = awaitView(activity, "layout-min")
            val absolute = awaitView(activity, "layout-absolute")
            val absoluteRatio = awaitView(activity, "layout-absolute-ratio")
            val absoluteHeightRatio = awaitView(activity, "layout-absolute-height-ratio")
            assertEquals("constrained width should snap to the nearest physical pixel", 140.0 * density.toDouble(), bounded.width.toDouble(), 0.500001)
            assertTrue(
                "absolute child ignored its trailing insets",
                absolute.right <= wrapped.width - (8 * density).toInt() && absolute.bottom <= wrapped.height - (8 * density).toInt()
            )
            assertEquals("absolute aspect ratio should resolve from anchored width", 156.0 * density, absoluteRatio.width.toDouble(), 1.0)
            assertEquals("absolute aspect ratio should remeasure from anchored width", 39.0 * density, absoluteRatio.height.toDouble(), 1.0)
            assertEquals("absolute aspect ratio should derive width from authored height", 40.0 * density, absoluteHeightRatio.width.toDouble(), 1.0)
            assertEquals("absolute authored height should remain fixed", 20.0 * density, absoluteHeightRatio.height.toDouble(), 1.0)
            assertTrue("wrapped child did not wrap", bounded.top < awaitView(activity, "layout-stretch").top)
            val scroll = awaitView(activity, "native-scroll")
            val image = awaitView(activity, "native-image")
            assertTrue("Intrinsic image did not mount", awaitView(activity, "intrinsic-image") is ImageView)
            awaitText(activity, "intrinsic-image-status", "intrinsic image ready")
            click(activity, "toggle-intrinsic-image")
            awaitText(activity, "intrinsic-image-status", "intrinsic image resized")
            val imageBackground = awaitView(activity, "native-image-background")
            val unsupportedBackground = awaitView(activity, "unsupported-image-background")
            val keyboardAvoiding = awaitView(activity, "native-keyboard-avoiding")
            val svg = awaitView(activity, "native-svg")
            val icon = awaitView(activity, "native-icon")
            val video = awaitView(activity, "native-video")
            val sectionList = awaitView(activity, "native-section-list")
            assertTrue("ScrollView did not render an Android ScrollView", containsType(scroll, ScrollView::class.java))
            val nativeScroller = findType(scroll, ScrollView::class.java)!!
            assertTrue("ScrollView contentContainerStyle did not add top padding", image.top >= nativeScroller.top + (12 * density).toInt())
            assertScrolls(nativeScroller)
            assertTrue("Image did not render as ImageView", image is ImageView)
            assertTrue("Image borderRadius must clip its pixels without overflow:hidden", image.clipToOutline)
            assertEquals("CraftNativeImageBackgroundView", imageBackground.javaClass.simpleName)
            assertTrue("ImageBackground child did not reconcile", awaitView(activity, "native-image-background-label") is TextView)
            assertTrue("ImageBackground image did not decode", (imageBackground as ViewGroup).getChildAt(0) is ImageView)
            val backgroundImage = imageBackground.getChildAt(0) as ImageView
            assertEquals("ImageBackground resizeMode prop did not select cover", ImageView.ScaleType.CENTER_CROP, backgroundImage.scaleType)
            assertTrue("ImageBackground image is empty", backgroundImage.drawable != null)
            assertTrue("ImageBackground lost its cleared tint state", backgroundImage.colorFilter == null)
            awaitText(activity, "image-background-error-status", "background failed")
            assertTrue("ImageBackground accessibility label was lost on failure", unsupportedBackground.contentDescription.toString().contains("Unsupported background"))
            assertTrue("ImageBackground error did not reach accessibility metadata", unsupportedBackground.contentDescription.toString().contains("Unsupported image source"))
            assertEquals("CraftNativeKeyboardAvoidingView", keyboardAvoiding.javaClass.simpleName)
            assertTrue("KeyboardAvoidingView child did not reconcile", awaitView(activity, "native-keyboard-avoiding-input") is EditText)
            assertEquals("CraftNativeSvgView", svg.javaClass.simpleName)
            assertEquals("SVG accessibility metadata did not survive native mounting", "Native vector", svg.contentDescription?.toString())
            assertTrue("SVG fixture did not receive a laid-out native surface", svg.width > 0 && svg.height > 0)
            val svgBitmap = Bitmap.createBitmap(svg.width, svg.height, Bitmap.Config.ARGB_8888)
            try {
                instrumentation.runOnMainSync { svg.draw(Canvas(svgBitmap)) }
                var bluePixels = 0
                var darkPixels = 0
                for (x in 0 until svgBitmap.width) {
                    for (y in 0 until svgBitmap.height) {
                        val pixel = svgBitmap.getPixel(x, y)
                        if (Color.alpha(pixel) > 20 && Color.blue(pixel) > Color.red(pixel) + 20) bluePixels++
                        if (Color.alpha(pixel) > 20 && Color.red(pixel) < 80 && Color.green(pixel) < 100 && Color.blue(pixel) < 160) darkPixels++
                    }
                }
                assertTrue("SVG group did not draw its inherited blue stroke", bluePixels > 5)
                assertTrue("SVG text did not draw its authored dark fill", darkPixels > 5)
            } finally {
                svgBitmap.recycle()
            }
            assertEquals("CraftNativeIconView", icon.javaClass.simpleName)
            assertEquals("Native icon", icon.contentDescription?.toString())
            assertTrue("Icon fixture should expose a visible glyph", (icon as TextView).text.isNotBlank())
            var iconInfo: AccessibilityNodeInfo? = null
            instrumentation.runOnMainSync { iconInfo = icon.createAccessibilityNodeInfo() }
            assertEquals(ImageView::class.java.name, iconInfo?.className?.toString())
            val implicitIconMinimum = icon.minimumWidth
            assertTrue("unsized icon did not receive its implicit box", implicitIconMinimum > 0)
            click(activity, "toggle-icon-size")
            repeat(75) {
                if (icon.minimumWidth == 0) return@repeat
                SystemClock.sleep(100)
            }
            assertEquals("explicit icon size retained the implicit minimum", 0, icon.minimumWidth)
            click(activity, "toggle-icon-size")
            repeat(75) {
                if (icon.minimumWidth == implicitIconMinimum) return@repeat
                SystemClock.sleep(100)
            }
            assertEquals("removing explicit icon size did not restore the implicit minimum", implicitIconMinimum, icon.minimumWidth)
            assertTrue("SectionList did not render an Android ScrollView", containsType(sectionList, ScrollView::class.java))
            assertTrue("SectionList header did not reconcile", awaitView(activity, "native-section-header") is TextView)
            assertTrue("SectionList row did not reconcile", awaitView(activity, "native-section-row") is TextView)
            assertTrue("SectionList overflow content did not reconcile", awaitView(activity, "native-section-footer") is TextView)
            assertScrolls(findType(sectionList, ScrollView::class.java)!!)
            awaitText(activity, "section-scroll-status", "Section scrolls: 1")
            assertEquals("CraftNativeVideoView", video.javaClass.simpleName)
            assertTrue("Image data did not decode", (image as ImageView).drawable != null)
            assertEquals("Native pixel", image.contentDescription.toString())
            awaitText(activity, "image-status", "image loaded")
            awaitText(activity, "image-load-end-status", "image load ended")
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
            awaitText(activity, "image-recovery-status", "image recovered")
            assertTrue("image source recovery did not decode", unsupported.drawable != null)
            assertEquals("image error metadata was not cleared on recovery", "Unsupported image", unsupported.contentDescription.toString())
            click(activity, "clear-image-source")
            awaitText(activity, "image-error-count", "2")
            click(activity, "toggle-image-tint")
            awaitText(activity, "image-tint-status", "image tint on")
            assertTrue("ImageBackground tint was not restored", backgroundImage.colorFilter != null)
            click(activity, "toggle-invalid-image-tint")
            awaitView(activity, "native-image-background") { container ->
                val child = (container as? ViewGroup)?.getChildAt(0) as? ImageView
                child != null && child.colorFilter == null
            }
            assertTrue("invalid ImageBackground tint should clear its color filter", backgroundImage.colorFilter == null)
            click(activity, "toggle-invalid-image-tint")
            awaitView(activity, "native-image-background") { container ->
                val child = (container as? ViewGroup)?.getChildAt(0) as? ImageView
                child != null && child.colorFilter != null
            }
            assertTrue("valid ImageBackground tint was not restored after invalid input", backgroundImage.colorFilter != null)
            assertEquals("missing image errors should be deduplicated", "2", (awaitView(activity, "image-error-count") as TextView).text.toString())
            assertNoWebView(activity)

            instrumentation.runOnMainSync {
                name.requestFocus()
                (name as EditText).setText("Ada")
            }
            awaitText(activity, "name-focuses", "Focuses: 1")
            awaitText(activity, "greeting", "Hello Ada")
            assertTrue("TextInput lost focus after typing", name.isFocused)
            click(activity, "toggle-name-mode")
            val multilineName = awaitView(activity, "name-input") { it is EditText && !it.isSingleLine } as EditText
            assertSame("multiline mode replaced the retained input", name, multilineName)
            assertFalse("multiline mode was not applied", multilineName.isSingleLine)
            assertTrue("email keyboard lost its multiline flag", multilineName.inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0)
            assertEquals(InputType.TYPE_CLASS_TEXT, multilineName.inputType and InputType.TYPE_MASK_CLASS)
            assertEquals(InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, multilineName.inputType and InputType.TYPE_MASK_VARIATION)
            assertEquals("Ada", multilineName.text.toString())
            awaitText(activity, "name-mode", "multiline")
            click(activity, "toggle-name-mode")
            val singleLineName = awaitView(activity, "name-input") { it is EditText && it.isSingleLine } as EditText
            assertSame("single-line mode replaced the retained input", name, singleLineName)
            assertTrue("single-line mode did not restore the input", singleLineName.isSingleLine)
            assertEquals("Ada", singleLineName.text.toString())
            // The field's dashed underline, on what was typed (an empty field has nothing to underline).
            val inputDecorations = (singleLineName.text as? Spanned)?.getSpans(0, singleLineName.text.length, ReplacementSpan::class.java).orEmpty()
            assertTrue("TextInput decoration span was not applied", inputDecorations.isNotEmpty())
            awaitText(activity, "name-mode", "single-line")
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
            assertSame("multiline TextInput was replaced after typing", notes, awaitView(activity, "notes-input"))
            assertTrue("multiline TextInput lost focus after typing", notes.isFocused)
            assertFalse("blurred TextInput regained focus while typing in notes", singleLineName.isFocused)
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
            awaitText(activity, "details-title", "Details for Ada")
            awaitText(activity, "details-count", "Count: 2")
            click(activity, "details-increment")
            awaitText(activity, "details-count", "Count: 3")
            val peopleHost = awaitView(activity, "people-list") as SwipeRefreshLayout
            val people = findType(peopleHost, ScrollView::class.java)!!
            assertTrue("ScrollView refresh host did not enable pull-to-refresh", peopleHost.isEnabled)
            pullToRefresh(peopleHost)
            awaitText(activity, "people-count", "People: 40; events: 1")
            val peopleHeader = awaitView(activity, "people-header") as TextView
            assertTrue("ScrollView contentContainerStyle did not add top padding", peopleHeader.top >= people.top + (8 * density).toInt())
            val peopleContent = people.getChildAt(0)
            assertTrue("people ScrollView did not lay out overflowing content", peopleContent != null && peopleContent.height > people.height)
            instrumentation.runOnMainSync {
                people.scrollTo(0, (peopleContent?.height ?: 0) - people.height)
            }
            SystemClock.sleep(150)
            instrumentation.runOnMainSync {
                // Sticky headers stay at the native host's effective viewport
                // edge, including its authored content inset.
                val headerTop = screenTop(peopleHeader)
                val viewportTop = screenTop(people) + peopleContent.paddingTop
                val firstChild = (peopleContent as? ViewGroup)?.getChildAt(0)
                val layout = "scrollY=${people.scrollY} headerTop=${peopleHeader.top} translationY=${peopleHeader.translationY} contentHeight=${peopleContent.height} viewportHeight=${people.height} firstChild=${firstChild?.tag} firstTranslation=${firstChild?.translationY} headerIsDirectChild=${peopleHeader.parent === peopleContent} focus=${activity.currentFocus?.tag} refreshing=${peopleHost.isRefreshing}"
                assertTrue("ScrollView did not retain the requested scroll: $layout", people.scrollY > 0)
                assertTrue(
                    "ScrollView sticky header did not remain pinned: header=$headerTop viewport=$viewportTop $layout",
                    kotlin.math.abs(headerTop - viewportTop) <= 1,
                )
            }
            val peopleLayouts = awaitView(activity, "people-layout-status") as TextView
            val initialRowLayouts = peopleLayouts.text.toString().substringAfterLast(": ").toInt()
            assertTrue("ScrollView rows did not report layout", initialRowLayouts > 0)
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
            click(activity, "load-more-people")
            awaitText(activity, "people-count", "People: 41; events: 3")
            awaitLayoutIncrease(activity, "people-layout-status", initialRowLayouts)
            click(activity, "clear-people")
            awaitText(activity, "people-empty", "Nobody here")
            awaitText(activity, "people-footer", "End of people")
            awaitText(activity, "people-count", "People: 0; events: 4")
            assertNoWebView(activity)

            instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            assertSame("Returning rebuilt the home input", name, awaitView(activity, "name-input"))
            assertEquals("Ada", (name as EditText).text.toString())
            awaitText(activity, "count", "Count: 2")
            click(activity, "navigation-check-lifecycle")
            awaitText(activity, "navigation-lifecycle", "Disposed Ada/3")

            click(activity, "open-details")
            awaitView(activity, "details-title")
            awaitText(activity, "details-count", "Count: 2")
            click(activity, "details-back")
            assertSame(name, awaitView(activity, "name-input"))

            click(activity, "open-details")
            awaitView(activity, "details-title")
            click(activity, "open-summary")
            awaitText(activity, "summary-title", "Summary for Ada")
            assertNoWebView(activity)
            instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            assertSame("Replace kept details on the stack", name, awaitView(activity, "name-input"))
            click(activity, "navigation-check-lifecycle")
            awaitText(activity, "navigation-lifecycle", "Disposed Ada/2")
        }
        finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun nativePullToRefreshSurvivesViewReattachment() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            click(activity, "navigation-open-details")
            val host = awaitView(activity, "people-list") { it.width > 0 && it.height > 0 } as SwipeRefreshLayout
            assertTrue("default refresh travel collapsed", host.progressViewEndOffset > host.progressViewStartOffset)
            assertTrue("native refresh indicator was detached", findType(host, ImageView::class.java) != null)
            instrumentation.runOnMainSync {
                val parent = host.parent as ViewGroup
                val index = parent.indexOfChild(host)
                parent.removeView(host)
                parent.addView(host, index)
            }
            pullToRefresh(host)
            awaitText(activity, "people-count", "People: 40; events: 1")
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun nativeLinkOpensRoute() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            click(activity, "navigation-increment")
            awaitText(activity, "navigation-home-state", "Home state: Ada/1")
            val link = awaitView(activity, "native-route-link")
            instrumentation.runOnMainSync { link.performClick() }
            awaitText(activity, "details-title", "Details for ")
            click(activity, "details-back")
            awaitView(activity, "native-route-link")
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }

    @Test
    fun nativeDatePickerKeepsFollowingControlsMounted() {
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        ) as MainActivity
        try {
            val picker = awaitView(activity, "native-date-picker")
            assertTrue("native date picker was not mounted", findType(picker, DatePicker::class.java) != null)
            assertTrue("date picker removed its following input", awaitView(activity, "name-input") is EditText)
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
        }
    }

    @Test
    fun nativePickerCanBeDisposedWithoutAdapterViewClickCrash() {
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        ) as MainActivity
        try {
            assertTrue("native picker was not mounted", awaitView(activity, "native-picker") is Spinner)
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun pushedScreenTabAccessoryOpensNativeRouteAndClearsOnBack() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        ) as MainActivity
        try {
            click(activity, "navigation-open-details")
            val details = awaitText(activity, "details-title", "Details for Ada")
            val accessory = awaitView(activity, "Open capabilities")
            instrumentation.runOnMainSync { accessory.performClick() }
            awaitView(activity, "capabilities-title")
            // The shell retains its accessory view and hides it with GONE.
            awaitView(activity, "Open capabilities") { !it.isShown }
            instrumentation.runOnMainSync { activity.onBackPressedDispatcher.onBackPressed() }
            assertFalse("system Back finished the native activity", activity.isFinishing)
            assertSame("system Back replaced the retained screen", details, awaitText(activity, "details-title", "Details for Ada"))
            awaitView(activity, "Open capabilities")
            click(activity, "details-back")
            awaitView(activity, "home-title")
            awaitView(activity, "Open capabilities") { !it.isShown }
        } finally {
            activity.finishAndRemoveTask()
        }
    }

    @Test
    fun systemBackDismissesPushedDetailsModalBeforeRoutePop() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        ) as MainActivity
        try {
            click(activity, "navigation-open-details")
            val details = awaitText(activity, "details-title", "Details for Ada")
            click(activity, "toggle-details-modal")
            awaitView(activity, "details-modal") { it.isShown }

            instrumentation.runOnMainSync { activity.onBackPressedDispatcher.onBackPressed() }
            awaitText(activity, "details-modal-request-status", "details modal requested back")
            assertFalse("system Back finished the native activity", activity.isFinishing)
            assertSame("system Back popped the route instead of dismissing its modal", details, awaitText(activity, "details-title", "Details for Ada"))
        } finally {
            activity.finishAndRemoveTask()
        }
    }

    @Test
    fun nativeAppearanceReconcilesTraitDefaults() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            val themeProbe = awaitView(activity, "theme-probe")
            val initialThemeColor = backgroundColor(themeProbe)
            assertTrue("theme probe did not receive a native background", initialThemeColor != null)
            // The way light and dark change for real: through AppCompat, which
            // owns the activity's night mode (a configuration set by hand is
            // put back by it). The manifest handles uiMode, so the activity
            // hears onConfigurationChanged rather than being recreated.
            val currentNight = activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
            instrumentation.runOnMainSync {
                activity.delegate.localNightMode = if (currentNight == Configuration.UI_MODE_NIGHT_YES) {
                    androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_NO
                } else {
                    androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_YES
                }
            }
            awaitBackgroundColor(themeProbe, initialThemeColor)
            assertTrue("theme probe label disappeared during trait refresh", awaitView(activity, "theme-probe-label") is TextView)
        }
        finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun safeAreaInsetsPreserveAuthoredPaddingWhenRetained() {
        lateinit var layout: CraftNativeFlexLayout
        instrumentation.runOnMainSync {
            layout = CraftNativeFlexLayout(instrumentation.targetContext)
            layout.setPadding(3, 5, 7, 11)
            layout.setSafeAreaEdges(JSONArray().put("top").put("bottom"))
            layout.setWindowSafeInsets(13, 17, 19, 23)
        }
        assertEquals("left edge should keep authored padding", 3, layout.paddingLeft)
        assertEquals("top edge should add the current window inset", 22, layout.paddingTop)
        assertEquals("right edge should keep authored padding", 7, layout.paddingRight)
        assertEquals("bottom edge should add the current window inset", 34, layout.paddingBottom)
    }

    private fun systemCommand(command: String): String =
        android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
            .bufferedReader().use { it.readText().trim() }

    @Test
    fun nativeScreenBackgroundOptionAppliesAndResets() {
        // Only this owned emulator fixture changes device appearance, and it
        // restores the original setting even when a strict pixel assertion fails.
        val original = Regex("Night mode: (\\w+)").find(systemCommand("cmd uimode night"))?.groupValues?.get(1)
            ?: throw AssertionError("Cannot read the original device appearance")
        assertTrue("Only a known device appearance may be changed",
            original in setOf("no", "yes", "auto", "custom_schedule", "custom_bedtime"))
        try {
            for ((mode, night) in listOf("no" to Configuration.UI_MODE_NIGHT_NO, "yes" to Configuration.UI_MODE_NIGHT_YES)) {
                systemCommand("cmd uimode night $mode")
                val deadline = SystemClock.uptimeMillis() + 5000
                while (android.content.res.Resources.getSystem().configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK != night
                    && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(100)
                assertEquals("device appearance must actually change", night,
                    android.content.res.Resources.getSystem().configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK)
                navigationSystemAppearance = if (mode == "yes") "system-dark" else "system-light"
                initialButtonNavigationSurface = null
                exerciseScreenBackgroundOption()
            }
        } finally {
            systemCommand("cmd uimode night $original")
            assertTrue("The original device appearance must be restored",
                systemCommand("cmd uimode night").contains("Night mode: $original"))
        }
    }

    private fun exerciseScreenBackgroundOption() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        try {
            val root = awaitView(activity, "root")
            val screen = root.parent as? View
                ?: throw AssertionError("native root is not attached to a screen host")
            val initial = backgroundColor(screen)
            val themeProbe = awaitView(activity, "theme-probe")
            val initialTraitBackground = backgroundColor(themeProbe)
            assertTrue("screen host did not receive a dynamic background", initial != null)
            assertEquals(initial, chromeBackgroundColor(activity, 0))
            assertSystemInsetBackground(activity, initial, "initial system inset background")

            click(activity, "toggle-screen-background")
            repeat(75) {
                if (backgroundColor(screen) == Color.rgb(0x12, 0x34, 0x56)
                    && chromeBackgroundColor(activity, 0) == Color.rgb(0x12, 0x34, 0x56)
                    && chromeBackgroundColor(activity, 1) == Color.rgb(0x12, 0x34, 0x56)
                ) return@repeat
                SystemClock.sleep(100)
            }
            assertEquals(Color.rgb(0x12, 0x34, 0x56), backgroundColor(screen))
            assertEquals(Color.rgb(0x12, 0x34, 0x56), chromeBackgroundColor(activity, 0))
            assertEquals(Color.rgb(0x12, 0x34, 0x56), chromeBackgroundColor(activity, 1))
            assertSystemInsetBackground(activity, Color.rgb(0x12, 0x34, 0x56),
                "system inset surface ignored the active screen background")

            click(activity, "black-screen-background")
            awaitBackgroundColor(screen, Color.rgb(0x12, 0x34, 0x56))
            assertEquals("the focus screen must stay black", Color.BLACK, backgroundColor(screen))
            assertSystemInsetBackground(activity, Color.BLACK, "black focus timer navigation")

            // A retained screen can still receive timer/state updates. Its
            // authored colour must not leak into the screen pushed above it.
            click(activity, "background-open-details")
            awaitText(activity, "details-title", "Details for Ada")
            awaitBackgroundColor(screen, Color.BLACK)
            assertEquals(Color.rgb(0x65, 0x43, 0x21), backgroundColor(screen))
            assertSystemInsetBackground(activity, initial,
                "offscreen options recoloured the visible system insets")

            val currentNight = activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
            instrumentation.runOnMainSync {
                activity.delegate.localNightMode = if (currentNight == Configuration.UI_MODE_NIGHT_YES) {
                    androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_NO
                } else {
                    androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_YES
                }
            }
            // An app may configure the same background in both appearances.
            // Wait for an actual trait-driven view change, then compare the
            // inset surface with the current configured system fallback.
            awaitBackgroundColor(themeProbe, initialTraitBackground)
            val themedDefault = androidx.core.content.ContextCompat.getColor(activity, R.color.background)
            assertSystemInsetBackground(activity, themedDefault,
                "theme refresh used a retained screen's authored colour")
            click(activity, "details-back")
            awaitView(activity, "home-title")
            assertSystemInsetBackground(activity, Color.rgb(0x65, 0x43, 0x21),
                "pop did not restore the retained screen's inset background")

            click(activity, "toggle-screen-background")
            awaitBackgroundColor(screen, Color.rgb(0x65, 0x43, 0x21))
            assertEquals(themedDefault, backgroundColor(screen))
            assertEquals(themedDefault, chromeBackgroundColor(activity, 0))
            assertEquals(themedDefault, chromeBackgroundColor(activity, 1))
            assertSystemInsetBackground(activity, themedDefault,
                "clearing the option did not restore dynamic system insets")
        } finally {
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }
}
