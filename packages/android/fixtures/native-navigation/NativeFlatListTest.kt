package dev.craft.navigationtest

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.SystemClock
import android.view.View
import android.view.MotionEvent
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.HorizontalScrollView
import androidx.swiperefreshlayout.widget.CircularProgressDrawable
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeFlatListTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun horizontalScroller(view: View): HorizontalScrollView? {
        if (view is HorizontalScrollView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            horizontalScroller(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun layoutPager(pager: CraftNativeScrollView, width: Int) {
        pager.layoutParams = FrameLayout.LayoutParams(width, 180)
        pager.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(180, View.MeasureSpec.EXACTLY))
        pager.layout(0, 0, width, 180)
    }

    @Test
    fun pagerFillsViewportRetainsPagesClampsCommandsAndPreservesSelectionOnResize() {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var pager: CraftNativeScrollView
        val reports = mutableListOf<Pair<Int, Int>>()
        val handler: (Int, Int) -> Unit = { index, count -> reports.add(index to count) }
        fun awaitReport(expected: Pair<Int, Int>) {
            val deadline = SystemClock.uptimeMillis() + 5000
            while (SystemClock.uptimeMillis() < deadline) {
                var settled = false
                // Native quiescence callbacks need the main queue. Never wait
                // inside onActivity while its 80ms settle is still pending.
                scenario.onActivity { settled = reports.lastOrNull() == expected }
                if (settled) return
                SystemClock.sleep(25)
            }
            scenario.onActivity { assertEquals("Native pager did not settle within 5000ms", expected, reports.lastOrNull()) }
        }
        try {
            scenario.onActivity { activity ->
                val host = FrameLayout(activity)
                activity.setContentView(host)
                pager = CraftNativeScrollView(activity)
                host.addView(pager)
                pager.setHorizontal(true)
                pager.setPagingEnabled(true)
                repeat(3) { index ->
                    pager.content.addView(TextView(activity).apply {
                        text = "Page $index"
                        tag = "page-$index"
                        layoutParams = LinearLayout.LayoutParams(37, 22)
                    })
                }
                pager.configurePager(1, handler)
                layoutPager(pager, 320)
            }
            awaitReport(1 to 3)
            scenario.onActivity {
                layoutPager(pager, 320)
                val scroller = requireNotNull(horizontalScroller(pager))
                assertEquals(320, scroller.width)
                assertEquals(960, pager.content.width)
                assertEquals(320, scroller.scrollX)
                assertEquals(1 to 3, reports.last())
                repeat(3) { index ->
                    val page = pager.content.getChildAt(index)
                    assertEquals(320, page.width)
                    assertEquals(index * 320, page.left)
                    assertEquals(if (index == 1) View.IMPORTANT_FOR_ACCESSIBILITY_AUTO else View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, page.importantForAccessibility)
                }
                val kept = pager.content.getChildAt(1)
                val reported = reports.size
                pager.configurePager(1, handler)
                layoutPager(pager, 320)
                assertEquals(reported, reports.size)
                assertTrue(kept === pager.content.getChildAt(1))
                layoutPager(pager, 480)
                assertEquals(480, scroller.scrollX)
                assertEquals(1440, pager.content.width)
                assertEquals(480, kept.width)
                assertEquals(reported, reports.size)
                pager.configurePager(99, handler)
                layoutPager(pager, 480)
            }
            awaitReport(2 to 3)
            scenario.onActivity {
                assertEquals(960, requireNotNull(horizontalScroller(pager)).scrollX)
                assertEquals(2 to 3, reports.last())
                pager.content.removeViews(1, 2)
                layoutPager(pager, 480)
            }
            awaitReport(0 to 1)
            scenario.onActivity {
                assertEquals(0, requireNotNull(horizontalScroller(pager)).scrollX)
                assertEquals(480, pager.content.width)
                assertEquals(0 to 1, reports.last())
                pager.content.removeAllViews()
                pager.configurePager(-1, handler)
                layoutPager(pager, 480)
            }
            awaitReport(0 to 0)
            scenario.onActivity {
                assertEquals(0 to 0, reports.last())
                assertEquals("Reconciliation and resize must not add selected events",
                    listOf(1 to 3, 2 to 3, 0 to 1, 0 to 0), reports)
            }
        } finally { scenario.close() }
    }

    @Test
    fun pagerFingerDragReportsSettledPageAndHidesOtherPagesFromAccessibility() {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var pager: CraftNativeScrollView
        val selected = AtomicInteger(-1)
        val changes = AtomicInteger()
        try {
            scenario.onActivity { activity ->
                val host = FrameLayout(activity)
                activity.setContentView(host)
                pager = CraftNativeScrollView(activity)
                host.addView(pager)
                pager.setHorizontal(true)
                pager.setPagingEnabled(true)
                repeat(3) { pager.content.addView(TextView(activity).apply { text = "Page $it" }) }
                pager.configurePager(0) { index, _ -> selected.set(index); changes.incrementAndGet() }
                layoutPager(pager, 320)
            }
            instrumentation.waitForIdleSync()
            var downTime = SystemClock.uptimeMillis()
            fun touch(action: Int, x: Float) {
                instrumentation.runOnMainSync {
                    val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x, 90f, 0)
                    try { pager.dispatchTouchEvent(event) } finally { event.recycle() }
                }
            }
            touch(MotionEvent.ACTION_DOWN, 280f)
            for (step in 1..12) {
                SystemClock.sleep(16)
                touch(MotionEvent.ACTION_MOVE, 280f - step * 20f)
            }
            instrumentation.runOnMainSync {
                assertTrue("Hold must be beyond half a viewport", requireNotNull(horizontalScroller(pager)).scrollX > 160)
            }
            // More than the native 80ms quiescence window, while the finger is
            // still down: an apparent pause must not publish a selection.
            SystemClock.sleep(250)
            assertEquals("A held drag has not selected a page", 0, selected.get())
            assertEquals("A held drag must not emit an intermediate selection", 1, changes.get())
            touch(MotionEvent.ACTION_UP, 40f)
            val deadline = SystemClock.uptimeMillis() + 5000
            while (selected.get() != 1 && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(25)
            assertEquals("A real touch drag must select the next viewport page", 1, selected.get())
            instrumentation.runOnMainSync {
                assertEquals(320, requireNotNull(horizontalScroller(pager)).scrollX)
                assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO, pager.content.getChildAt(1).importantForAccessibility)
                assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, pager.content.getChildAt(0).importantForAccessibility)
                assertEquals(2, changes.get())
                pager.setScrollEnabled(false)
            }
            downTime = SystemClock.uptimeMillis()
            touch(MotionEvent.ACTION_DOWN, 280f)
            for (step in 1..12) {
                SystemClock.sleep(16)
                touch(MotionEvent.ACTION_MOVE, 280f - step * 20f)
            }
            touch(MotionEvent.ACTION_UP, 40f)
            SystemClock.sleep(250)
            instrumentation.runOnMainSync {
                assertEquals("A locked page must ignore another finger drag", 320, requireNotNull(horizontalScroller(pager)).scrollX)
                assertEquals(1, selected.get())
                assertEquals("Locked gestures must not emit selected events", 2, changes.get())
            }
        } finally { scenario.close() }
    }

    @Test
    fun cssGenericFamiliesUseRealAndroidTypefaceAndRespectFallbackOrder() {
        instrumentation.runOnMainSync {
            for (family in listOf("monospace", "ui-monospace", "'Missing Font', ui-monospace, serif")) {
                val view = TextView(instrumentation.targetContext)
                view.typeface = craftNativeFontFamily(family)
                assertEquals(Typeface.MONOSPACE, view.typeface)
                assertEquals(view.paint.measureText("iii"), view.paint.measureText("WWW"), 0.1f)
            }
            assertEquals(Typeface.SERIF, craftNativeFontFamily("'Missing Font', ui-serif"))
            assertEquals(Typeface.SANS_SERIF, craftNativeFontFamily("system-ui"))
            assertEquals(Typeface.SERIF, craftNativeFontFamily("Brand Font, monospace", mapOf("Brand Font" to Typeface.SERIF)))
        }
    }

    @Test
    fun chromeUsesThePackagedFaceAndKeepsTheSystemFaceForGenericStacks() {
        val brand = mapOf("Brand-Regular" to Typeface.SERIF)
        assertEquals(null, craftNativeChromeTypeface("system-ui, sans-serif", brand))
        assertEquals(null, craftNativeChromeTypeface("'Missing Font'", brand))
        assertEquals(null, craftNativeChromeTypeface("sans-serif, Brand-Regular", brand))
        assertEquals(Typeface.SERIF, craftNativeChromeTypeface("'Missing Font', Brand-Regular, system-ui", brand))
        assertEquals(null, craftNativeChromeTypeface(null, brand))
    }

    @Test
    fun fontFamilyIsInheritedOnlyByANodeWithoutItsOwn() {
        val bare = JSONObject().put("fontSize", 18)
        assertSame("nothing inherited: the node's own style, uncopied", bare, craftNativeInheritFontFamily(bare, null))
        val inherited = craftNativeInheritFontFamily(bare, "Barlow, sans-serif")
        assertEquals("Barlow, sans-serif", inherited.getString("fontFamily"))
        assertEquals(18, inherited.getInt("fontSize"))
        assertFalse("the protocol document's style is not written to", bare.has("fontFamily"))
        val own = JSONObject().put("fontFamily", "serif")
        assertSame("an explicit family wins", own, craftNativeInheritFontFamily(own, "Barlow"))
        assertEquals("Barlow", craftNativeInheritFontFamily(JSONObject().put("fontFamily", "inherit"), "Barlow").getString("fontFamily"))
        assertEquals("Barlow", craftNativeInheritFontFamily(JSONObject().put("fontFamily", JSONObject.NULL), "Barlow").getString("fontFamily"))
        assertEquals("serif", craftNativeInheritableFontFamily(own))
        assertNull(craftNativeInheritableFontFamily(JSONObject().put("fontFamily", "inherit")))
        assertNull(craftNativeInheritableFontFamily(JSONObject()))
    }

    @Test
    fun celebrationIsFiniteReplayableAndHonorsReducedMotion() {
        // The protocol CI leg removes system animations; native navigation
        // legs keep them on. Exercise the real policy in both configurations.
        val motionEnabled = android.animation.ValueAnimator.areAnimatorsEnabled()
        val firstStart = if (motionEnabled) 1 else 0
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var celebration: CraftNativeCelebration
        lateinit var card: View
        scenario.onActivity { activity ->
            val host = FrameLayout(activity)
            activity.setContentView(host)
            card = View(activity)
            host.addView(card, FrameLayout.LayoutParams(300, 240))
            celebration = CraftNativeCelebration(card)
        }
        instrumentation.waitForIdleSync()
        scenario.onActivity {
            val request = JSONObject().put("replay", 0)
            celebration.configure(request, 20f)
            celebration.layout()
            assertEquals(firstStart, celebration.starts)
            assertEquals(motionEnabled, celebration.isRunning)
            celebration.configure(request, 20f)
            celebration.layout()
            assertEquals(firstStart, celebration.starts)
            celebration.stop()
            assertTrue(!celebration.isRunning)
            celebration.configure(JSONObject().put("replay", 1), 20f)
            celebration.layout(false)
            assertEquals(firstStart, celebration.starts)
            celebration.layout(true)
            assertEquals(firstStart, celebration.starts)
            celebration.configure(JSONObject().put("replay", 2).put("enabled", false), 20f)
            celebration.layout(true)
            assertEquals(firstStart, celebration.starts)
            celebration.configure(JSONObject().put("replay", -1), 20f)
            celebration.layout(true)
            assertEquals(firstStart, celebration.starts)
            celebration.configure(JSONObject().put("replay", 3), 20f)
            celebration.layout()
            assertEquals(firstStart * 2, celebration.starts)
        }
        // The celebration's clock is a 3 s ValueAnimator on the Choreographer:
        // it starts on the first frame after start() and ends on the first
        // frame past its duration. A loaded emulator skips a second or more of
        // frames, so a fixed 3.3 s sleep could look before that frame arrived.
        // Wait for it to end on its own (nothing calls stop() here), bounded
        // far beyond its duration so an endless celebration still fails.
        val deadline = SystemClock.uptimeMillis() + 15_000
        var running = true
        while (running && SystemClock.uptimeMillis() < deadline) {
            scenario.onActivity { running = celebration.isRunning }
            if (running) SystemClock.sleep(50)
        }
        assertFalse("the celebration never ended on its own", running)
        scenario.close()
    }

    private fun findImage(view: View): ImageView? {
        if (view is ImageView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                findImage(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }

    private fun row(index: Int): JSONObject = JSONObject()
        .put("id", "row-$index")
        .put("type", "Text")
        .put("children", JSONArray().put("Row $index"))

    private fun chrome(id: String, role: String): JSONObject = JSONObject()
        .put("id", id)
        .put("type", "Text")
        .put("props", JSONObject().put("listRole", role))
        .put("children", JSONArray().put(role))

    private fun awaitCount(list: CraftNativeFlatList, expected: Int, committed: () -> Boolean = { true }) {
        repeat(100) {
            val ready = AtomicBoolean()
            instrumentation.runOnMainSync {
                ready.set(list.adapter?.itemCount == expected && committed())
            }
            if (ready.get()) return
            SystemClock.sleep(50)
        }
        throw AssertionError("Timed out waiting for $expected committed FlatList cells; found ${list.adapter?.itemCount}")
    }

    private fun attach(list: CraftNativeFlatList) {
        list.layoutParams = FrameLayout.LayoutParams(320, 480)
        val width = View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY)
        val height = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        list.measure(width, height)
        list.layout(0, 0, 320, 480)
    }

    private fun launchHost(): Pair<ActivityScenario<MainActivity>, CraftNativeFlatList> {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var list: CraftNativeFlatList
        scenario.onActivity { activity ->
            val host = FrameLayout(activity)
            activity.setContentView(host)
            list = CraftNativeFlatList(activity)
            host.addView(list)
            attach(list)
        }
        return scenario to list
    }

    private fun renderer(context: Context, renders: AtomicInteger): CraftNativeRenderItem =
        { node, _, previous ->
            renders.incrementAndGet()
            (previous as? TextView ?: TextView(context)).apply {
                text = node.optJSONArray("children")?.optString(0).orEmpty()
                minHeight = 44
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                )
            }
        }

    @Test
    fun recyclesTenThousandRowsAndRetainsTheViewport() {
        val context = instrumentation.targetContext
        lateinit var list: CraftNativeFlatList
        val renders = AtomicInteger()
        val rows = (0 until 10_000).map(::row)
        instrumentation.runOnMainSync {
            list = CraftNativeFlatList(context)
            attach(list)
            list.apply(rows, false, 1, false, 0.1, renderer(context, renders), { _ -> }, { _ -> }, null)
        }
        awaitCount(list, 10_000)
        instrumentation.runOnMainSync {
            attach(list)
            list.scrollToPosition(5_000)
            attach(list)
        }
        SystemClock.sleep(300)

        val before = (list.layoutManager as LinearLayoutManager).findFirstVisibleItemPosition()
        assertTrue("RecyclerView materialized too many of 10,000 rows", renders.get() < 200)
        assertTrue("RecyclerView did not reach the requested viewport", before >= 4_900)

        val moved = listOf(rows[1], rows[0]) + rows.drop(2)
        instrumentation.runOnMainSync {
            list.apply(moved, false, 1, false, 0.1, renderer(context, renders), { _ -> }, { _ -> }, null)
        }
        awaitCount(list, 10_000)
        instrumentation.runOnMainSync { attach(list) }
        SystemClock.sleep(500)
        val after = (list.layoutManager as LinearLayoutManager).findFirstVisibleItemPosition()
        assertTrue("keyed update reset the viewport", after >= 4_900)
        assertTrue("keyed update rendered the full data set", renders.get() < 400)
    }

    @Test
    fun forwardsScrollAndMomentumCallbacks() {
        val (scenario, list) = launchHost()
        val context = list.context
        val scrollCount = AtomicInteger()
        val momentumBeginCount = AtomicInteger()
        val momentumEndCount = AtomicInteger()
        val momentumEnded = CountDownLatch(1)
        val rows = (0 until 100).map(::row)
        try {
            instrumentation.runOnMainSync {
                list.onScrollEvent = { scrollCount.incrementAndGet() }
                list.onMomentumScrollBegin = { momentumBeginCount.incrementAndGet() }
                list.onMomentumScrollEnd = {
                    momentumEndCount.incrementAndGet()
                    momentumEnded.countDown()
                }
                list.apply(rows, false, 1, false, 0.1, renderer(context, AtomicInteger()), { _ -> }, { _ -> }, null)
            }
            awaitCount(list, 100)
            instrumentation.runOnMainSync {
                attach(list)
                // Exercise a real viewport-sized animation, rather than
                // coupling callback delivery to a 99-row traversal's duration.
                list.smoothScrollBy(0, list.height)
            }
            assertTrue("RecyclerView did not finish its native momentum animation", momentumEnded.await(2500, TimeUnit.MILLISECONDS))
            assertTrue("RecyclerView did not emit scroll callbacks", scrollCount.get() > 0)
            assertEquals(1, momentumBeginCount.get())
            assertEquals(1, momentumEndCount.get())
            instrumentation.runOnMainSync { assertEquals(RecyclerView.SCROLL_STATE_IDLE, list.scrollState) }
        } finally {
            scenario.close()
        }
    }

    @Test
    fun configuresHorizontalGridInvertedAndChromeOnlyLists() {
        val (scenario, list) = launchHost()
        val context = list.context
        try {
            val renders = AtomicInteger()
            val nodes = listOf(chrome("header", "header")) + (0 until 8).map(::row)
            instrumentation.runOnMainSync {
                list.apply(nodes, true, 1, true, 0.1, renderer(context, renders), { _ -> }, { _ -> }, null)
            }
            awaitCount(list, 9)
            instrumentation.runOnMainSync {
                attach(list)
                val horizontal = list.layoutManager as LinearLayoutManager
                assertEquals(LinearLayoutManager.HORIZONTAL, horizontal.orientation)
                val invertedIdentities = list.visibleItemIdentities
                assertTrue("the attached inverted list must mount rows", invertedIdentities.isNotEmpty())
                assertEquals("row-7", invertedIdentities.first())
                val adapterOrder = listOf("row-7", "row-6", "row-5", "row-4", "row-3", "row-2", "row-1", "row-0", "header")
                assertEquals("mounted identities must stay in adapter order", adapterOrder.filter { it in invertedIdentities }, invertedIdentities)
            }

            instrumentation.runOnMainSync {
                list.apply(nodes, false, 3, false, 0.1, renderer(context, renders), { _ -> }, { _ -> }, null)
            }
            // Both snapshots contain nine cells, so count alone can still
            // describe the previous inverted snapshot. Wait for the header
            // to occupy its committed grid position within the same budget.
            awaitCount(list, 9) {
                (list.layoutManager as? GridLayoutManager)?.spanSizeLookup?.getSpanSize(0) == 3
            }
            instrumentation.runOnMainSync {
                val grid = list.layoutManager as GridLayoutManager
                assertEquals(3, grid.spanCount)
                assertEquals(3, grid.spanSizeLookup.getSpanSize(0))
                assertEquals(1, grid.spanSizeLookup.getSpanSize(1))
            }

            val updated = listOf(chrome("header", "header"), row(0).put("children", JSONArray().put("Updated"))) +
                (1 until 8).map(::row)
            instrumentation.runOnMainSync {
                list.apply(updated, false, 3, false, 0.1, renderer(context, renders), { _ -> }, { _ -> }, null)
            }
            SystemClock.sleep(300)
            instrumentation.runOnMainSync { attach(list) }

            val chromeEndReached = AtomicInteger()
            val chromeOnly = listOf(
                chrome("header", "header"),
                chrome("empty", "empty"),
                chrome("footer", "footer"),
            )
            instrumentation.runOnMainSync {
                list.apply(chromeOnly, false, 1, false, 0.1, renderer(context, renders), { _ -> }, { _ -> }, {
                    chromeEndReached.incrementAndGet()
                })
            }
            awaitCount(list, 3)
            SystemClock.sleep(300)
            assertEquals("chrome-only lists must not reach the data end", 0, chromeEndReached.get())
        } finally {
            scenario.close()
        }
    }

    @Test
    fun appliesScrollIndicatorsAndBounceAxes() {
        val context = instrumentation.targetContext
        val list = CraftNativeFlatList(context)
        list.setScrollIndicators(vertical = false, horizontal = true)
        list.setBounceOptions(enabled = true, vertical = false, horizontal = true)
        assertTrue("vertical indicator should be hidden", !list.isVerticalScrollBarEnabled)
        assertTrue("horizontal indicator should be visible", list.isHorizontalScrollBarEnabled)
        assertEquals(View.OVER_SCROLL_NEVER, list.overScrollMode)
        list.apply(emptyList(), true, 1, false, 0.1, renderer(context, AtomicInteger()), { _ -> }, { _ -> }, null)
        list.setBounceOptions(enabled = true, vertical = false, horizontal = true)
        assertEquals(View.OVER_SCROLL_ALWAYS, list.overScrollMode)
        list.setBounceOptions(enabled = false, vertical = true, horizontal = true)
        assertEquals(View.OVER_SCROLL_NEVER, list.overScrollMode)
    }

    @Test
    fun preservesRowTouchTargetsWhenScrollingIsDisabled() {
        val list = CraftNativeFlatList(instrumentation.targetContext)
        list.setScrollEnabled(false)
        assertTrue("scrollEnabled should be false", !list.isScrollEnabledForTest)
        list.setScrollEnabled(true)
        assertTrue("scrollEnabled should be restored", list.isScrollEnabledForTest)
    }

    @Test
    fun nonScrollingListMeasuresItsFullContentHeight() {
        val (scenario, list) = launchHost()
        val context = list.context
        try {
            val rows = (0 until 3).map(::row)
            val contentSizeChanges = AtomicInteger()
            instrumentation.runOnMainSync {
                list.layoutParams = FrameLayout.LayoutParams(320, ViewGroup.LayoutParams.WRAP_CONTENT)
                list.setScrollEnabled(false)
                list.onContentSizeChanged = { contentSizeChanges.incrementAndGet() }
                list.apply(rows, false, 1, false, 0.1, renderer(context, AtomicInteger()), { _ -> }, { _ -> }, null)
            }
            awaitCount(list, rows.size)
            instrumentation.runOnMainSync {
                list.measure(
                    View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(1_000, View.MeasureSpec.AT_MOST),
                )
                list.layout(0, 0, list.measuredWidth, list.measuredHeight)
                assertTrue("non-scrolling FlatList should include every row", list.measuredHeight >= rows.size * 44)
            }
            repeat(100) {
                if (contentSizeChanges.get() > 0) return@repeat
                SystemClock.sleep(10)
            }
            assertTrue("non-scrolling FlatList should report content-size changes", contentSizeChanges.get() > 0)
        } finally {
            scenario.close()
        }
    }

    @Test
    fun appliesPagingToNativeList() {
        val list = CraftNativeFlatList(instrumentation.targetContext)
        list.setPagingEnabled(true)
        assertTrue("paging should be enabled", list.isPagingEnabledForTest)
        list.setPagingEnabled(false)
        assertTrue("paging should be disabled", !list.isPagingEnabledForTest)
    }

    @Test
    fun refreshAppearanceUsesTheScreenContrastFallback() {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var host: CraftNativeRefreshableFlatList
        lateinit var indicator: ImageView
        try {
            scenario.onActivity { activity ->
                val root = FrameLayout(activity)
                activity.setContentView(root)
                host = CraftNativeRefreshableFlatList(activity)
                root.addView(host, FrameLayout.LayoutParams(320, 480))
                host.measure(
                    View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY),
                )
                host.layout(0, 0, 320, 480)
                host.setRefreshAppearance(JSONObject(), Color.BLACK)
                indicator = findImage(host) ?: throw AssertionError("refresh indicator did not mount")
            }
            assertEquals(Color.BLACK, (indicator.drawable as CircularProgressDrawable).colorSchemeColors.single())
            instrumentation.runOnMainSync {
                host.setRefreshAppearance(JSONObject().put("tintColor", "#123456"), Color.WHITE)
            }
            assertEquals(Color.rgb(0x12, 0x34, 0x56), (indicator.drawable as CircularProgressDrawable).colorSchemeColors.single())
            instrumentation.runOnMainSync {
                host.setRefreshAppearance(JSONObject().put("tintColor", "not-a-color"), Color.WHITE)
            }
            assertEquals("invalid refresh tint should use the screen fallback", Color.WHITE, (indicator.drawable as CircularProgressDrawable).colorSchemeColors.single())
            instrumentation.runOnMainSync { host.setRefreshAppearance(JSONObject(), Color.WHITE) }
            assertEquals(Color.WHITE, (indicator.drawable as CircularProgressDrawable).colorSchemeColors.single())
        } finally {
            scenario.close()
        }
    }

    @Test
    fun acceptsVirtualizedScrollTargets() {
        val list = CraftNativeFlatList(instrumentation.targetContext)
        list.setScrollTarget(JSONObject().put("id", "row").put("key", "first"))
        assertTrue("scroll target should remain pending until rows mount", list.isScrollTargetPendingForTest)
        list.setScrollTarget(null)
        assertTrue("clearing the target should cancel pending work", !list.isScrollTargetPendingForTest)
    }

    @Test
    fun usesRenderedHeightsForVariableRows() {
        val context = instrumentation.targetContext
        lateinit var list: CraftNativeFlatList
        val rows = listOf(row(0), row(1).put("children", JSONArray().put("Tall\nrow\ncontent\ncontent")))
        instrumentation.runOnMainSync {
            list = CraftNativeFlatList(context)
            attach(list)
            list.apply(
                rows,
                false,
                1,
                false,
                0.1,
                { node, _, previous ->
                    (previous as? TextView ?: TextView(context)).apply {
                        text = node.optJSONArray("children")?.optString(0).orEmpty()
                        minHeight = 0
                        layoutParams = FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            if (text.contains('\n')) 120 else 24,
                        )
                    }
                },
                { _ -> },
                { _ -> },
                null,
            )
        }
        awaitCount(list, 2)
        instrumentation.runOnMainSync { attach(list) }
        val short = list.findViewHolderForAdapterPosition(0)?.itemView
            ?: throw AssertionError("short row did not mount")
        val tall = list.findViewHolderForAdapterPosition(1)?.itemView
            ?: throw AssertionError("tall row did not mount")
        assertTrue("rendered row height was not retained", tall.height > short.height + 20)
    }

    @Test
    fun verticalRowsFillTheListWidthWhenNoWidthIsAuthored() {
        val context = instrumentation.targetContext
        lateinit var list: CraftNativeFlatList
        val rows = listOf(row(0), row(1))
        instrumentation.runOnMainSync {
            list = CraftNativeFlatList(context)
            attach(list)
            list.apply(
                rows,
                false,
                1,
                false,
                0.1,
                { node, _, previous ->
                    (previous as? TextView ?: TextView(context)).apply {
                        text = node.optJSONArray("children")?.optString(0).orEmpty()
                        layoutParams = FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                        )
                    }
                },
                { _ -> },
                { _ -> },
                null,
            )
        }
        awaitCount(list, 2)
        instrumentation.runOnMainSync { attach(list) }
        val holder = list.findViewHolderForAdapterPosition(0)
            ?: throw AssertionError("first row did not mount")
        val hosted = (holder.itemView as ViewGroup).getChildAt(0)
            ?: throw AssertionError("first row root did not mount")
        assertEquals("vertical row root should fill its cell", list.width, hosted.width)
    }

    @Test
    fun horizontalRowsKeepIntrinsicWidthWhenNoWidthIsAuthored() {
        val context = instrumentation.targetContext
        lateinit var list: CraftNativeFlatList
        val rows = listOf(
            row(0).put("children", JSONArray().put("short")),
            row(1).put("children", JSONArray().put("a much longer horizontal row")),
        )
        instrumentation.runOnMainSync {
            list = CraftNativeFlatList(context)
            attach(list)
            list.apply(
                rows,
                true,
                1,
                false,
                0.1,
                { node, _, previous ->
                    (previous as? TextView ?: TextView(context)).apply {
                        text = node.optJSONArray("children")?.optString(0).orEmpty()
                        minWidth = 0
                        layoutParams = FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        )
                    }
                },
                { _ -> },
                { _ -> },
                null,
            )
        }
        awaitCount(list, 2)
        instrumentation.runOnMainSync { attach(list) }
        SystemClock.sleep(200)
        val short = list.findViewHolderForAdapterPosition(0)?.itemView
            ?: throw AssertionError("short horizontal row did not mount")
        val long = list.findViewHolderForAdapterPosition(1)?.itemView
            ?: throw AssertionError("long horizontal row did not mount")
        val shortHosted = (short as ViewGroup).getChildAt(0)
            ?: throw AssertionError("short horizontal row root did not mount")
        val longHosted = (long as ViewGroup).getChildAt(0)
            ?: throw AssertionError("long horizontal row root did not mount")
        assertTrue("short horizontal row was stretched to the viewport", shortHosted.width < list.width)
        assertTrue("long horizontal row did not grow intrinsically", longHosted.width > shortHosted.width + 20)
    }
}
