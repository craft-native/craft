package dev.craft.navigationtest

import android.content.Context
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeFlatListTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun row(index: Int): JSONObject = JSONObject()
        .put("id", "row-$index")
        .put("type", "Text")
        .put("children", JSONArray().put("Row $index"))

    private fun chrome(id: String, role: String): JSONObject = JSONObject()
        .put("id", id)
        .put("type", "Text")
        .put("props", JSONObject().put("listRole", role))
        .put("children", JSONArray().put(role))

    private fun awaitCount(list: CraftNativeFlatList, expected: Int) {
        repeat(100) {
            if (list.adapter?.itemCount == expected) return
            SystemClock.sleep(50)
        }
        throw AssertionError("Timed out waiting for $expected FlatList cells; found ${list.adapter?.itemCount}")
    }

    private fun attach(list: CraftNativeFlatList) {
        list.layoutParams = FrameLayout.LayoutParams(320, 480)
        val width = View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY)
        val height = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        list.measure(width, height)
        list.layout(0, 0, 320, 480)
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
            list.apply(rows, false, 1, false, 0.1, renderer(context, renders), { _ -> }, null)
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
            list.apply(moved, false, 1, false, 0.1, renderer(context, renders), { _ -> }, null)
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
        val context = instrumentation.targetContext
        lateinit var list: CraftNativeFlatList
        val scrollCount = AtomicInteger()
        val momentumBeginCount = AtomicInteger()
        val momentumEndCount = AtomicInteger()
        val rows = (0 until 100).map(::row)
        instrumentation.runOnMainSync {
            list = CraftNativeFlatList(context)
            attach(list)
            list.onScrollEvent = { scrollCount.incrementAndGet() }
            list.onMomentumScrollBegin = { momentumBeginCount.incrementAndGet() }
            list.onMomentumScrollEnd = { momentumEndCount.incrementAndGet() }
            list.apply(rows, false, 1, false, 0.1, renderer(context, AtomicInteger()), { _ -> }, null)
        }
        awaitCount(list, 100)
        instrumentation.runOnMainSync {
            attach(list)
            list.smoothScrollToPosition(99)
        }
        repeat(50) {
            if (momentumEndCount.get() > 0) return@repeat
            SystemClock.sleep(50)
        }
        assertTrue("RecyclerView did not emit scroll callbacks", scrollCount.get() > 0)
        assertEquals(1, momentumBeginCount.get())
        assertEquals(1, momentumEndCount.get())
    }

    @Test
    fun configuresHorizontalGridInvertedAndChromeOnlyLists() {
        val context = instrumentation.targetContext
        lateinit var list: CraftNativeFlatList
        val renders = AtomicInteger()
        val nodes = listOf(chrome("header", "header")) + (0 until 8).map(::row)
        instrumentation.runOnMainSync {
            list = CraftNativeFlatList(context)
            attach(list)
            list.apply(nodes, true, 1, true, 0.1, renderer(context, renders), { _ -> }, null)
        }
        awaitCount(list, 9)
        val horizontal = list.layoutManager as LinearLayoutManager
        assertEquals(LinearLayoutManager.HORIZONTAL, horizontal.orientation)

        instrumentation.runOnMainSync {
            list.apply(nodes, false, 3, false, 0.1, renderer(context, renders), { _ -> }, null)
        }
        awaitCount(list, 9)
        SystemClock.sleep(200)
        val grid = list.layoutManager as GridLayoutManager
        assertEquals(3, grid.spanCount)
        assertEquals(3, grid.spanSizeLookup.getSpanSize(0))
        assertEquals(1, grid.spanSizeLookup.getSpanSize(1))

        val updated = listOf(chrome("header", "header"), row(0).put("children", JSONArray().put("Updated"))) +
            (1 until 8).map(::row)
        instrumentation.runOnMainSync {
            list.apply(updated, false, 3, false, 0.1, renderer(context, renders), { _ -> }, null)
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
            list.apply(chromeOnly, false, 1, false, 0.1, renderer(context, renders), { _ -> }, {
                chromeEndReached.incrementAndGet()
            })
        }
        awaitCount(list, 3)
        SystemClock.sleep(300)
        assertEquals("chrome-only lists must not reach the data end", 0, chromeEndReached.get())
    }
}
