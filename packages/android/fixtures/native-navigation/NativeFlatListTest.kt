package dev.craft.navigationtest

import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.widget.FrameLayout
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

    private fun attach(activity: MainActivity, list: CraftNativeFlatList) {
        activity.addContentView(list, FrameLayout.LayoutParams(320, 480))
        val width = View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY)
        val height = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        list.measure(width, height)
        list.layout(0, 0, 320, 480)
    }

    private fun renderer(activity: MainActivity, renders: AtomicInteger): CraftNativeRenderItem =
        { node, _, previous ->
            renders.incrementAndGet()
            (previous as? TextView ?: TextView(activity)).apply {
                text = node.optJSONArray("children")?.optString(0).orEmpty()
                minHeight = 44
            }
        }

    @Test
    fun recyclesTenThousandRowsAndRetainsTheViewport() {
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ) as MainActivity
        try {
            val list = CraftNativeFlatList(activity)
            val renders = AtomicInteger()
            val rows = (0 until 10_000).map(::row)
            instrumentation.runOnMainSync {
                attach(activity, list)
                list.apply(rows, false, 1, false, 0.1, renderer(activity, renders), { _ -> }, null)
            }
            awaitCount(list, 10_000)
            instrumentation.runOnMainSync { list.scrollToPosition(5_000) }
            SystemClock.sleep(300)

            val before = (list.layoutManager as LinearLayoutManager).findFirstVisibleItemPosition()
            assertTrue("RecyclerView materialized too many of 10,000 rows", renders.get() < 200)
            assertTrue("RecyclerView did not reach the requested viewport", before >= 4_900)

            val moved = listOf(rows[1], rows[0]) + rows.drop(2)
            instrumentation.runOnMainSync {
                list.apply(moved, false, 1, false, 0.1, renderer(activity, renders), { _ -> }, null)
            }
            awaitCount(list, 10_000)
            SystemClock.sleep(500)
            val after = (list.layoutManager as LinearLayoutManager).findFirstVisibleItemPosition()
            assertTrue("keyed update reset the viewport", after >= 4_900)
            assertTrue("keyed update rendered the full data set", renders.get() < 400)
        }
        finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }

    @Test
    fun configuresHorizontalGridInvertedAndChromeOnlyLists() {
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ) as MainActivity
        try {
            val list = CraftNativeFlatList(activity)
            val renders = AtomicInteger()
            val nodes = listOf(chrome("header", "header")) + (0 until 8).map(::row)
            instrumentation.runOnMainSync {
                attach(activity, list)
                list.apply(nodes, true, 1, true, 0.1, renderer(activity, renders), { _ -> }, null)
            }
            awaitCount(list, 9)
            val horizontal = list.layoutManager as LinearLayoutManager
            assertEquals(LinearLayoutManager.HORIZONTAL, horizontal.orientation)

            instrumentation.runOnMainSync {
                list.apply(nodes, false, 3, false, 0.1, renderer(activity, renders), { _ -> }, null)
            }
            awaitCount(list, 9)
            SystemClock.sleep(200)
            val grid = list.layoutManager as GridLayoutManager
            assertEquals(3, grid.spanCount)
            assertEquals(3, grid.spanSizeLookup.getSpanSize(0))
            assertEquals(1, grid.spanSizeLookup.getSpanSize(1))

            val chromeEndReached = AtomicInteger()
            val chromeOnly = listOf(
                chrome("header", "header"),
                chrome("empty", "empty"),
                chrome("footer", "footer"),
            )
            instrumentation.runOnMainSync {
                list.apply(chromeOnly, false, 1, false, 0.1, renderer(activity, renders), { _ -> }, {
                    chromeEndReached.incrementAndGet()
                })
            }
            awaitCount(list, 3)
            SystemClock.sleep(300)
            assertEquals("chrome-only lists must not reach the data end", 0, chromeEndReached.get())
        }
        finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }
}
