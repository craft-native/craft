package dev.craft.navigationtest

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Every number a screen's script can put in a prop or a style, at sizes no
 * screen means: the host must draw something, or nothing, and carry on.
 *
 * The UIKit host has the same case (`HostileNumbersUnitTests`), which found
 * that one style number could end the app. Here each document is rendered by
 * the activity's own renderer, measured, laid out and drawn into a bitmap,
 * where anything thrown is recorded against the document that threw it. The
 * last document of each batch is then left on screen for a real frame, where
 * anything thrown ends the process and the case with it; the case that sets
 * everything at once gives every document a frame of its own.
 * `packages/android/src/hostile-numbers.test.ts` keeps the lists here
 * covering the keys the templates read.
 */
@RunWith(AndroidJUnit4::class)
class NativeHostileNumbersTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    companion object {
        val props = listOf(
            "accessibilityActions", "accessibilityHint", "accessibilityLabel", "accessibilityLanguage",
            "accessibilityRole", "accessibilityState", "accessibilityValue", "activeOpacity", "alt",
            "alwaysBounceHorizontal", "alwaysBounceVertical", "animating", "animationType", "attributeName",
            "autoCapitalize", "autoComplete", "autoCorrect", "autoFocus", "autoPlay", "autocomplete", "autoplay",
            "barStyle", "basemap", "behavior", "bounces", "cameraHeading", "cameraPitch", "celebration", "checked",
            "clearButtonMode", "color", "contentContainerStyle", "contextMenu", "contextmenu", "controls", "currentTime",
            "defaultSource", "defaultValue", "disabled", "dismissOnOutsideTap", "display", "duration", "edgePadding",
            "edges", "editable", "ellipsizeMode", "fill", "fitToBounds", "fontSize", "frameTimes", "frames",
            "grabberVisible", "hidden", "hidesWhenStopped", "horizontal", "href", "id", "image", "imageShape", "imageSize",
            "imageshape", "imagesize", "indeterminate", "initialRegion", "inverted", "items", "key",
            "keyboardDismissMode", "keyboardShouldPersistTaps", "keyboardType", "keyboardVerticalOffset", "label",
            "listRole", "loop", "mapType", "markers", "maxLength", "maximumDate", "maximumTrackTintColor",
            "maximumValue", "minimumDate", "minimumTrackTintColor", "minimumValue", "minuteInterval", "mode",
            "mostRecentEventCount", "multiline", "muted", "name", "nonModal", "numColumns", "numberOfLines",
            "objectFit", "objectPosition", "onEndReachedThreshold", "opacity", "pageIndex", "pagingEnabled", "passwordRules", "paused",
            "pictureInPicture", "pitchEnabled", "placeholder", "placeholderTextColor", "pointerEvents", "polylines",
            "presentationStyle", "preserveAspectRatio", "progressBackgroundColor", "progressViewOffset",
            "refreshControl", "refreshing", "region", "repeatCount",
            "resizeMode", "returnKeyType", "rotateEnabled", "scale", "scrollEnabled", "scrollTarget", "secureTextEntry",
            "selectable", "selectedDetent", "selectedValue", "selectionColor", "sheetDetents", "showsCompass",
            "showsHorizontalScrollIndicator", "showsScale", "showsUserLocation", "showsVerticalScrollIndicator", "size",
            "source", "src", "step", "stickyHeaderIndices", "stroke", "strokeWidth", "symbol", "testID", "textAnchor",
            "textContentType", "threshold", "thumbColor", "thumbTintColor", "tileOverlay", "tintColor", "title",
            "titleColor", "to", "trackColor", "transitionID", "transparent", "underlayColor", "value", "viewBox", "visible",
            "x", "y", "zoomEnabled",
        )

        val styles = listOf(
            "alignContent", "alignItems", "alignSelf", "aspectRatio", "backgroundColor", "borderColor", "borderRadius",
            "borderStyle", "borderWidth", "bottom", "color", "columnGap", "display", "elevation", "fill", "flex",
            "flexBasis", "flexDirection", "flexGrow", "flexShrink", "flexWrap", "fontFamily", "fontSize", "fontStyle",
            "fontWeight", "gap", "gradientDirection", "gradientFrom", "gradientTo", "gradientVia", "gridAutoRows",
            "gridColumns", "gridTemplateColumns", "gridTemplateRows", "height", "justifyContent", "left",
            "letterSpacing", "lineHeight", "margin", "marginBottom", "marginHorizontal", "marginLeft", "marginRight",
            "marginTop", "marginVertical", "maxHeight", "maxWidth", "minHeight", "minWidth", "objectFit", "objectPosition", "opacity", "order",
            "overflow", "padding", "paddingBottom", "paddingHorizontal", "paddingLeft", "paddingRight", "paddingTop",
            "paddingVertical", "pointerEvents", "position", "resizeMode", "right", "rowGap", "shadowColor",
            "shadowOffset", "shadowOpacity", "shadowRadius", "stroke", "strokeWidth", "textAlign", "textDecorationColor",
            "textDecorationLine", "textDecorationStyle", "textShadowColor", "textShadowOffset", "textShadowRadius",
            "textTransform", "tintColor", "top", "transform", "width", "zIndex",
        )

        val types = listOf(
            "View", "SafeAreaView", "KeyboardAvoidingView", "Text", "Button", "Link", "Checkbox", "TextInput",
            "SegmentedControl", "Picker", "DatePicker", "Switch", "Slider", "ActivityIndicator", "RefreshControl",
            "Image", "ImageBackground", "Icon", "ScrollView", "SectionList", "FlatList", "Svg",
            "TouchableOpacity", "TouchableHighlight", "Pressable",
        )

        val numbers = listOf(
            1e30, -1e30, Double.MAX_VALUE, -Double.MAX_VALUE, 4_294_967_296.5, -4_294_967_296.5,
            1e15, -1.0, 0.0, 0.5,
        )

        private const val TAG = "HostileNumbers"
    }

    private fun text(key: String, label: String, style: JSONObject? = null): JSONObject =
        JSONObject().put("type", "Text").put("props", JSONObject().put("key", key))
            .put("children", JSONArray().put(label)).apply { if (style != null) put("style", style) }

    /**
     * The subject beside a sibling in a row, so a flex factor is a share of
     * something, with two children of its own.
     */
    private fun node(type: String, props: Map<String, Any>, style: Map<String, Any>): JSONObject {
        val own = JSONObject(props).put("key", "subject")
        return JSONObject().put("type", "View")
            .put("style", JSONObject().put("width", 320).put("height", 480).put("flexDirection", "row"))
            .put("children", JSONArray()
                .put(JSONObject().put("type", type).put("props", own).put("style", JSONObject(style))
                    .put("children", JSONArray().put(text("first", "First")).put(text("second", "Second"))))
                .put(text("sibling", "Sibling", JSONObject().put("flex", 1))))
    }

    /**
     * The same numbers on a child of the subject instead: what a container
     * makes of a child it cannot place.
     */
    private fun parent(type: String, childStyle: Map<String, Any>): JSONObject =
        JSONObject().put("type", "View").put("style", JSONObject().put("width", 320).put("height", 480))
            .put("children", JSONArray().put(JSONObject().put("type", type)
                .put("props", JSONObject().put("key", "subject"))
                .put("style", JSONObject().put("flexDirection", "row").put("flexWrap", "wrap"))
                .put("children", JSONArray()
                    .put(JSONObject().put("type", "View").put("props", JSONObject().put("key", "child"))
                        .put("style", JSONObject(childStyle))
                        .put("children", JSONArray().put(JSONObject().put("type", "Text").put("children", JSONArray().put("Child")))))
                    .put(text("second", "Second", JSONObject().put("flex", 1))))))

    private fun find(view: View, id: String): View? {
        if (view.tag?.toString() == id) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) find(view.getChildAt(index), id)?.let { return it }
        return null
    }

    /** A real frame: traversal, and the draw the render thread makes of it. */
    private fun frame() {
        val drawn = CountDownLatch(1)
        instrumentation.runOnMainSync {
            Choreographer.getInstance().postFrameCallback {
                Choreographer.getInstance().postFrameCallback { drawn.countDown() }
            }
        }
        drawn.await(5, TimeUnit.SECONDS)
    }

    /**
     * Runs `body` with a function that draws one document, and fails with
     * every distinct thing a document made the host throw.
     */
    private fun drawing(body: (draw: (List<Pair<String, JSONObject>>) -> Unit) -> Unit) {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var activity: MainActivity
        val thrown = linkedMapOf<String, String>()
        try {
            scenario.onActivity { activity = it }
            val deadline = SystemClock.uptimeMillis() + 15_000
            var ready = false
            while (!ready && SystemClock.uptimeMillis() < deadline) {
                instrumentation.runOnMainSync { ready = find(activity.window.decorView, "navigation-home-state") != null }
                if (!ready) SystemClock.sleep(100)
            }
            check(ready) { "the fixture's home screen did not mount" }
            lateinit var screen: Any
            instrumentation.runOnMainSync {
                screen = requireNotNull((MainActivity::class.java.getDeclaredField("screens")
                    .apply { isAccessible = true }.get(activity) as List<*>).last())
            }
            val render = MainActivity::class.java.getDeclaredMethod("render", screen.javaClass, JSONObject::class.java)
                .apply { isAccessible = true }
            val plain = node("Text", mapOf("numberOfLines" to 2), mapOf("fontSize" to 17))
            val bitmap = Bitmap.createBitmap(270, 600, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val draw = { documents: List<Pair<String, JSONObject>> ->
                instrumentation.runOnMainSync {
                    for ((label, document) in documents) {
                        try {
                            render.invoke(activity, screen, document)
                            val decor = activity.window.decorView
                            decor.measure(
                                View.MeasureSpec.makeMeasureSpec(decor.width, View.MeasureSpec.EXACTLY),
                                View.MeasureSpec.makeMeasureSpec(decor.height, View.MeasureSpec.EXACTLY),
                            )
                            decor.layout(0, 0, decor.width, decor.height)
                            canvas.save()
                            canvas.scale(270f / decor.width.coerceAtLeast(1), 600f / decor.height.coerceAtLeast(1))
                            decor.draw(canvas)
                            canvas.restore()
                        }
                        catch (error: Throwable) {
                            val cause = (error as? InvocationTargetException)?.targetException ?: error
                            val at = cause.stackTrace.firstOrNull { it.className.startsWith("dev.craft") }
                                ?: cause.stackTrace.firstOrNull()
                            val what = "${cause.javaClass.simpleName}: ${cause.message?.take(140)} at ${at?.methodName}:${at?.lineNumber}"
                            if (what !in thrown) {
                                thrown[what] = label
                                Log.e(TAG, "$label threw", cause)
                            }
                            // Not left for the real frame, which would throw
                            // the same thing where nothing can record it.
                            runCatching { canvas.restoreToCount(1) }
                            runCatching { render.invoke(activity, screen, plain) }
                        }
                    }
                }
                Log.i(TAG, "drew ${documents.size}, ending with ${documents.lastOrNull()?.first}")
                frame()
            }
            body(draw)
            // And an ordinary screen still draws after all that.
            draw(listOf("an ordinary screen afterwards" to plain))
            var alive = false
            instrumentation.runOnMainSync { alive = activity.window.decorView.isAttachedToWindow }
            check(alive) { "the activity's window went away" }
        }
        finally {
            scenario.close()
        }
        assertEquals(
            "documents the host threw on, by what it threw",
            "",
            thrown.entries.joinToString("\n") { "${it.value} -> ${it.key}" },
        )
    }

    @Test
    fun everyPropAndStyleSetToAHostileNumberAtOnce() = drawing { draw ->
        for (type in types) for (number in numbers) {
            val everyProp = props.associateWith<String, Any> { number }
            val everyStyle = styles.associateWith<String, Any> { number }
            // One at a time: each is on screen for a frame of its own.
            draw(listOf("$type, every prop $number" to node(type, everyProp, emptyMap())))
            draw(listOf("$type, every style $number" to node(type, emptyMap(), everyStyle)))
            draw(listOf("$type, every prop and style $number" to node(type, everyProp, everyStyle)))
        }
    }

    @Test
    fun eachPropSetToAHostileNumberOnItsOwn() = drawing { draw ->
        for (type in types) draw(props.flatMap { name ->
            listOf(1e30, -1e30, Double.MAX_VALUE).map { number ->
                "$type, prop $name $number" to node(type, mapOf(name to number), emptyMap())
            }
        })
    }

    @Test
    fun eachStyleSetToAHostileNumberOnItsOwn() = drawing { draw ->
        for (type in types) draw(styles.flatMap { name ->
            listOf(1e30, -1e30, Double.MAX_VALUE).map { number ->
                "$type, style $name $number" to node(type, emptyMap(), mapOf(name to number))
            }
        })
    }

    @Test
    fun eachStyleOfAChildSetToAHostileNumberOnItsOwn() = drawing { draw ->
        for (type in listOf("View", "ScrollView", "Pressable", "FlatList")) draw(styles.flatMap { name ->
            listOf(1e30, -1e30, Double.MAX_VALUE).map { number ->
                "a child of $type, style $name $number" to parent(type, mapOf(name to number))
            }
        })
    }

    /**
     * A grid's tracks are counted, and the count is the script's: as a
     * number, or inside `repeat(…)`. Nothing above reaches them, because a
     * number is not `display: "grid"`.
     */
    @Test
    fun gridsOfAHostileNumberOfColumnsAndRows() = drawing { draw ->
        fun grid(type: String, style: Map<String, Any>): JSONObject =
            JSONObject().put("type", "View").put("style", JSONObject().put("width", 320).put("height", 480))
                .put("children", JSONArray().put(JSONObject().put("type", type)
                    .put("props", JSONObject().put("key", "subject"))
                    .put("style", JSONObject(style).put("display", "grid"))
                    .put("children", JSONArray()
                        .put(text("first", "First")).put(text("second", "Second")).put(text("third", "Third")))))
        val tracks = listOf("gridColumns", "gridTemplateColumns", "gridTemplateRows", "gridAutoRows", "gap", "rowGap", "columnGap")
        for (type in listOf("View", "ScrollView", "Pressable")) {
            for (number in numbers) {
                draw(tracks.map { name -> "a grid $type, $name $number" to grid(type, mapOf(name to number)) })
                draw(listOf("a grid $type, every track $number" to grid(type, tracks.associateWith<String, Any> { number })))
            }
            for (count in listOf("2147483647", "2147483648", "4294967296", "99999999999999999999", "0")) {
                draw(listOf("gridTemplateColumns", "gridTemplateRows").map { name ->
                    "a grid $type, $name repeat($count, 1fr)" to grid(type, mapOf(name to "repeat($count, 1fr)"))
                })
                draw(listOf("a grid $type, columns and rows repeat($count, 1fr)" to grid(type, mapOf(
                    "gridTemplateColumns" to "repeat($count, 1fr)", "gridTemplateRows" to "repeat($count, minmax(0, 1fr))",
                ))))
            }
        }
    }

    /**
     * Lengths written as text, transforms, and a drawing's own numbers: none
     * of them is a plain number in a style or a prop.
     */
    @Test
    fun hostileLengthsTransformsAndDrawings() = drawing { draw ->
        for (number in numbers) {
            val text = "$number"
            val documents = mutableListOf<Pair<String, JSONObject>>()
            for (length in listOf("$text%", "${text}px", text, "1e400", "1e400%", "-1e400px")) {
                for (name in listOf("width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight", "flexBasis", "gridAutoRows")) {
                    documents += "View, style $name '$length'" to node("View", emptyMap(), mapOf(name to length))
                    documents += "a child of View, style $name '$length'" to parent("View", mapOf(name to length))
                }
            }
            draw(documents)
            draw(listOf("translateX", "translateY", "scale", "scaleX", "scaleY").flatMap { transform ->
                listOf(
                    "View, transform $transform $number" to
                        node("View", emptyMap(), mapOf("transform" to JSONArray().put(JSONObject().put(transform, number)))),
                    "Text, transform $transform $number with a rotation and a skew" to
                        node("Text", emptyMap(), mapOf("transform" to JSONArray()
                            .put(JSONObject().put(transform, number))
                            .put(JSONObject().put("rotate", "${text}deg"))
                            .put(JSONObject().put("skewX", "${text}rad")))),
                )
            })
            val shapes = JSONArray()
                .put(JSONObject().put("type", "Path").put("props", JSONObject()
                    .put("geometry", JSONArray(listOf(0, number, number, 1, number, 0, 2, number, number, number, number, 0, 0, 3, number, number, 5, 5, 4)))
                    .put("stroke", "#ff0000").put("strokeWidth", number).put("fill", "#00ff00").put("opacity", number)
                    .put("fillOpacity", number).put("strokeOpacity", number).put("strokeDashoffset", number)
                    .put("strokeMiterlimit", number).put("strokeDasharray", JSONArray(listOf(number, number)))))
                .put(JSONObject().put("type", "Path").put("props", JSONObject()
                    .put("geometry", JSONArray(listOf(number, 0, 0, 1, 10, 10))).put("stroke", "#ff0000")))
                .put(JSONObject().put("type", "SvgText").put("props", JSONObject()
                    .put("x", number).put("y", number).put("fontSize", number).put("fill", "#000000"))
                    .put("children", JSONArray().put("Text")))
                .put(JSONObject().put("type", "G").put("props", JSONObject().put("opacity", number).put("strokeWidth", number))
                    .put("children", JSONArray().put(JSONObject().put("type", "Path").put("props", JSONObject()
                        .put("geometry", JSONArray(listOf(0, 0, 0, 1, number, number))).put("stroke", "#0000ff")))))
            // A celebration draws at the view's corner radius, and a chart's
            // inspection places its readings by a fraction of the width.
            draw(listOf(
                "View, a celebration of $number at a corner radius of $number" to node("View",
                    mapOf("celebration" to JSONObject().put("replay", number).put("enabled", true)),
                    mapOf("borderRadius" to number, "width" to 120, "height" to 120)),
                "Svg, an inspection with a reading at $number" to JSONObject().put("type", "View")
                    .put("style", JSONObject().put("width", 320).put("height", 480))
                    .put("children", JSONArray().put(JSONObject().put("type", "Svg")
                        .put("props", JSONObject().put("key", "chart").put("viewBox", JSONArray(listOf(0, 0, 24, 24)))
                            .put("inspection", JSONObject().put("title", "Pace").put("points", JSONArray()
                                .put(JSONObject().put("x", number).put("label", "Start"))
                                .put(JSONObject().put("x", 0.5).put("label", "Half")
                                    .put("rows", JSONArray().put(JSONObject().put("label", "Pace").put("value", number)))))))
                        .put("style", JSONObject().put("width", 120).put("height", 120))
                        .put("children", shapes))),
            ))
            val boxes = listOf(listOf(0, 0, 24, 24), listOf(0, 0, number, number), listOf(number, number, 24, 24), listOf(0, 0, 0, 0), listOf(0, 0, 24, number))
            for (viewBox in boxes) {
                draw(listOf("Svg, viewBox $viewBox with shapes of $number" to JSONObject().put("type", "View")
                    .put("style", JSONObject().put("width", 320).put("height", 480))
                    .put("children", JSONArray().put(JSONObject().put("type", "Svg")
                        .put("props", JSONObject().put("key", "drawing").put("viewBox", JSONArray(viewBox)))
                        .put("style", JSONObject().put("width", 120).put("height", 120))
                        .put("children", shapes)))))
            }
        }
    }
}
