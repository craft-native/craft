package dev.craft.navigationtest

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.Point
import kotlin.math.roundToInt

/** The actual generated host and GL renderer, installed on an Android device. */
@RunWith(AndroidJUnit4::class)
class NativeMapTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun <T> main(block: () -> T): T {
        val result = AtomicReference<Result<T>>()
        instrumentation.runOnMainSync { result.set(runCatching(block)) }
        return result.get().getOrThrow()
    }

    private fun awaitState(message: String, block: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 45_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (main(block)) return
            SystemClock.sleep(100)
        }
        assertTrue(message, main(block))
    }

    private fun props() = JSONObject().put("fitToBounds", true).put("showsCompass", true).put("showsScale", true)
        .put("pitchEnabled", false).put("rotateEnabled", true)
        .put("edgePadding", JSONObject().put("top", 88).put("bottom", 180).put("left", 32).put("right", 32))

    private fun overlays(color: String = "#24724b") = JSONArray("""[
        {"type":"MapPolyline","props":{"id":"route","geometry":[47,11,47.01,11.01],"strokeColor":"#24724b","strokeWidth":5}},
        {"type":"MapMarker","props":{"id":"start","geometry":[47,11],"pinColor":"$color","title":"Trailhead"}},
        {"type":"MapMarker","props":{"id":"direction","geometry":[47.005,11.005],"bearing":90,"title":"Recorded direction"}}
    ]""")

    private fun features(map: MapLibreMap): List<Feature> = map.style?.getSourceAs<GeoJsonSource>("craft-map-overlays")
        ?.querySourceFeatures(null).orEmpty().distinctBy { it.getStringProperty("craftOverlayId") }

    private fun textViews(view: View): List<TextView> = (if (view is TextView) listOf(view) else emptyList()) +
        (if (view is ViewGroup) (0 until view.childCount).flatMap { textViews(view.getChildAt(it)) } else emptyList())

    private fun evidence(name: String) {
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
            ?: throw AssertionError("Gradle native map evidence directory unavailable")
        val directory = File(output, "native-maps").apply { mkdirs() }
        val image = instrumentation.uiAutomation.takeScreenshot() ?: throw AssertionError("Native screenshot unavailable")
        File(directory, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }

    private fun awaitBasemapPixels(host: CraftNativeMapView, label: String) {
        val deadline = SystemClock.uptimeMillis() + 45_000
        do {
            val bounds = main {
                val origin = IntArray(2).also { host.getLocationOnScreen(it) }
                intArrayOf(origin[0], origin[1], host.width, host.height)
            }
            val image = instrumentation.uiAutomation.takeScreenshot() ?: throw AssertionError("Native screenshot unavailable")
            val visible = try {
                // Sample across the map, away from controls/credits and the thin
                // route. A rendered overlay over an empty black surface fails.
                var painted = 0
                for (row in 1..8) for (column in 1..8) {
                    val pixel = image.getPixel(bounds[0] + bounds[2] * column / 9, bounds[1] + bounds[3] * row / 9)
                    if (Color.red(pixel) + Color.green(pixel) + Color.blue(pixel) > 60) painted++
                }
                painted >= 58
            } finally { image.recycle() }
            if (visible) return
            SystemClock.sleep(100)
        } while (SystemClock.uptimeMillis() < deadline)
        evidence("$label-basemap-not-visible")
        fail("$label did not paint native basemap tiles across the viewport")
    }

    private fun withMap(block: (MainActivity, CraftNativeMapView, MapView, MapLibreMap, AtomicInteger) -> Unit) {
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as MainActivity
        lateinit var host: CraftNativeMapView
        var hostCreated = false
        lateinit var widget: MapView
        lateinit var map: MapLibreMap
        val ready = CountDownLatch(1)
        val loaded = AtomicInteger()
        try {
            main {
                host = CraftNativeMapView(activity)
                hostCreated = true
                widget = host.getChildAt(0) as MapView
                widget.addOnDidFinishLoadingMapListener { loaded.incrementAndGet() }
                host.configure(props(), overlays()) {}
                activity.setContentView(host)
                widget.getMapAsync { map = it; ready.countDown() }
            }
            assertTrue("The real native map did not initialize", ready.await(20, TimeUnit.SECONDS))
            awaitState("Native map did not render its recorded overlays") {
                features(map).map { it.getStringProperty("craftOverlayId") }.toSet() == setOf("route", "start", "direction") &&
                    map.queryRenderedFeatures(map.projection.toScreenLocation(LatLng(47.005, 11.005)), "craft-map-directions").isNotEmpty()
            }
            block(activity, host, widget, map, loaded)
        } finally {
            main { if (hostCreated) { host.destroy(); host.destroy() }; activity.finish() }
        }
    }

    @Test
    fun markerPhotoPropsAcceptCompilerSpellingsAndRejectUnsafeAddresses() {
        for ((sizeKey, shapeKey) in listOf("imageSize" to "imageShape", "imagesize" to "imageshape", "image-size" to "image-shape")) {
            val props = JSONObject().put("image", "https://example.com/avatar.png").put(sizeKey, 500).put(shapeKey, "square")
            assertEquals(CraftMarkerPhoto("https://example.com/avatar.png", 96f, false), CraftMarkerPhoto.from(props))
            props.put(sizeKey, -2)
            assertEquals(16f, requireNotNull(CraftMarkerPhoto.from(props)).size, 0f)
        }
        for (address in listOf("http://example.com/avatar.png", "file:///avatar.png", "data:image/png;base64,AAAA", "https://", "https://user:secret@example.com/avatar.png")) {
            assertNull(CraftMarkerPhoto.from(JSONObject().put("image", address)))
        }
    }

    @Test
    fun markerPhotosCropClampAndKeepTapIdentityAcrossMutations() = withMap { activity, host, _, map, _ ->
        val address = "https://marker-photo.invalid/${java.util.UUID.randomUUID()}.png"
        val file = CraftNativeMedia.file(activity, address)
        file.parentFile!!.mkdirs()
        val source = Bitmap.createBitmap(80, 40, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.RED) }
        file.outputStream().use { assertTrue(source.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        source.recycle()
        val pressed = AtomicReference<String?>()
        val key = "craft-map-photo-${CraftNativeMedia.digest("start")}"
        fun update(url: String, size: Int, shape: String) = main {
            val children = overlays()
            children.getJSONObject(1).getJSONObject("props").put("image", url).put("imageSize", size).put("imageShape", shape)
            children.getJSONObject(1).put("events", JSONObject().put("onPress", "runner-tap"))
            host.configure(props(), children) { pressed.set(it) }
        }
        try {
            update(address, 30, "circle")
            awaitState("Marker photo never reached the native renderer") {
                map.queryRenderedFeatures(map.projection.toScreenLocation(LatLng(47.0, 11.0)), "craft-map-photos")
                    .any { it.getStringProperty("craftMarkerId") == "start" }
            }
            main {
                val image = requireNotNull(map.style?.getImage(key))
                assertEquals((30 * host.resources.displayMetrics.density).roundToInt(), image.width)
                assertEquals(0, Color.alpha(image.getPixel(0, 0)))
                assertEquals(Color.RED, image.getPixel(image.width / 2, image.height / 2))
                assertEquals("runner-tap", host.markerHandler("start"))
            }
            val point = main {
                val screen = map.projection.toScreenLocation(LatLng(47.0, 11.0))
                val origin = IntArray(2).also { host.getLocationOnScreen(it) }
                (screen.x + origin[0]) to (screen.y + origin[1])
            }
            val now = SystemClock.uptimeMillis()
            for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
                val event = android.view.MotionEvent.obtain(now, now + action * 50L, action, point.first, point.second, 0)
                try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
            }
            awaitState("Photo tap lost the marker ID") { pressed.get() == "start" }
            update(address, 500, "square")
            awaitState("Photo size mutation did not reach the existing style") {
                map.style?.getImage(key)?.width == (96 * host.resources.displayMetrics.density).roundToInt()
            }
            main { assertEquals(255, Color.alpha(requireNotNull(map.style?.getImage(key)).getPixel(0, 0))) }
            evidence("marker-photo-square")
            update("http://marker-photo.invalid/avatar.png", 30, "circle")
            awaitState("Invalid photo URL did not restore the pin") {
                features(map).first { it.getStringProperty("craftOverlayId") == "start" }.getStringProperty("kind") == "marker" &&
                    map.style?.getImage(key) == null
            }
            update(address, 40, "circle")
            update("file:///private/avatar.png", 30, "circle")
            SystemClock.sleep(200)
            main { assertNull("Late photo replaced fallback", map.style?.getImage(key)) }
        } finally { file.delete() }
    }

    @Test
    fun keyFreeBasemapsKeepTheRecordedRouteAndDirectionSignsVisible() = withMap { _, host, widget, map, loaded ->
        for (type in listOf("outdoors", "standard", "satellite", "hybrid")) {
            val before = loaded.get()
            val rendered = AtomicInteger()
            val listener = MapView.OnDidFinishRenderingFrameListener { fully, _, _ -> if (fully) rendered.incrementAndGet() }
            main {
                widget.addOnDidFinishRenderingFrameListener(listener)
                val options = props().put("mapType", if (type == "outdoors") "standard" else type)
                if (type == "outdoors") options.put("tileOverlay", JSONObject()
                    .put("urlTemplate", "https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}")
                    .put("attribution", "Topography: Esri, USGS, NOAA, OpenStreetMap contributors"))
                host.configure(options, overlays()) {}
            }
            awaitState("$type did not finish loading its real native basemap") {
                loaded.get() > before && rendered.get() > 0 && features(map).size == 3 &&
                    map.queryRenderedFeatures(map.projection.toScreenLocation(LatLng(47.005, 11.005)), "craft-map-directions").isNotEmpty()
            }
            awaitBasemapPixels(host, type)
            main { widget.removeOnDidFinishRenderingFrameListener(listener) }
            main {
                val start = features(map).first { it.getStringProperty("craftOverlayId") == "start" }.geometry() as Point
                assertEquals(47.0, start.latitude(), 0.000001)
                assertEquals(11.0, start.longitude(), 0.000001)
                assertEquals(90.0, features(map).first { it.getStringProperty("craftOverlayId") == "direction" }.getNumberProperty("bearing").toDouble(), 0.001)
                assertTrue("Provider attribution must remain visible", textViews(host).any { it.visibility == View.VISIBLE && (it.text.contains("Esri") || it.text.contains("OpenStreetMap")) })
                val credit = textViews(host).first { it.text.contains("Esri") || it.text.contains("OpenStreetMap") }
                assertTrue("Floating profiles must not cover provider attribution", credit.bottom <= host.height - 180 * host.resources.displayMetrics.density)
                for (point in listOf(LatLng(47.0, 11.0), LatLng(47.01, 11.01))) {
                    val screen = map.projection.toScreenLocation(point)
                    val density = host.resources.displayMetrics.density
                    assertTrue("Route must stay below floating top controls", screen.y >= 88 * density - 8)
                    assertTrue("Route must stay above the floating profile", screen.y <= host.height - 180 * density + 8)
                }
            }
            evidence("map-$type")
        }
    }

    @Test
    fun nativeMapStrokeWidthsStayInLogicalPointsAcrossDensities() = withMap { _, host, _, map, _ ->
        awaitState("The native route did not publish its stroke width") {
            features(map).firstOrNull { it.getStringProperty("craftOverlayId") == "route" }
                ?.getNumberProperty("width") != null
        }
        val density = main { host.resources.displayMetrics.density.toDouble() }
        val width = main {
            features(map).first { it.getStringProperty("craftOverlayId") == "route" }
                .getNumberProperty("width").toDouble()
        }
        assertEquals("MapLibre must scale logical stroke points by display density", 5.0 * density, width, 0.001)
    }

    @Test
    fun nativeMapWorkerThreadConfigurationIsMarshalledToTheUiThread() = withMap { _, host, _, map, _ ->
        val worker = Executors.newSingleThreadExecutor()
        try {
            worker.submit {
                host.configure(props().put("mapType", "terrain"), overlays("#2878c8")) {}
            }.get(10, TimeUnit.SECONDS)
        } finally {
            worker.shutdownNow()
        }
        awaitState("Worker-thread map configuration did not update the native source") {
            features(map).firstOrNull { it.getStringProperty("craftOverlayId") == "start" }
                ?.getStringProperty("color") == "rgba(40,120,200,1.0)"
        }
    }

    @Test
    fun nativeMapMutationsUpdateThePinAndCameraWithoutReloadingTheStyle() = withMap { _, host, _, map, _ ->
        val style = main { map.style }
        val pressed = AtomicReference<String?>()
        main { host.configure(props().put("pitchEnabled", true).put("cameraPitch", 30).put("cameraHeading", 90), overlays("#2878c8")) { pressed.set(it) } }
        awaitState("The native map did not apply camera and pin mutations") {
            val pin = features(map).firstOrNull { it.getStringProperty("craftOverlayId") == "start" }
            pin?.getStringProperty("color") == "rgba(40,120,200,1.0)" &&
                kotlin.math.abs(map.cameraPosition.bearing - 90) < 1 && kotlin.math.abs(map.cameraPosition.tilt - 30) < 1 &&
                map.queryRenderedFeatures(map.projection.toScreenLocation(LatLng(47.0, 11.0)), "craft-map-markers").any { it.getStringProperty("color") == "rgba(40,120,200,1.0)" }
        }
        awaitBasemapPixels(host, "mutated-map")
        main {
            assertSame("Overlay updates must not reload the native basemap", style, map.style)
            assertTrue(map.uiSettings.isTiltGesturesEnabled)
            assertTrue(map.uiSettings.isCompassEnabled)
            assertEquals(3, features(map).size)
        }
        // Inspect the actual rendered pin, not just the JSON property sent to GL.
        // A native source query can observe new feature properties before the
        // compositor presents that frame. Require the actual requested color,
        // using a fresh projection for each capture while the camera settles.
        val deadline = SystemClock.uptimeMillis() + 45_000
        var location: Pair<Int, Int>? = null
        var lastPixel = Color.TRANSPARENT
        while (SystemClock.uptimeMillis() < deadline && location == null) {
            val candidate = main {
                val screen = map.projection.toScreenLocation(LatLng(47.0, 11.0))
                val origin = IntArray(2).also { host.getLocationOnScreen(it) }
                (screen.x.toInt() + origin[0]) to (screen.y.toInt() + origin[1])
            }
            val image = instrumentation.uiAutomation.takeScreenshot() ?: throw AssertionError("Native screenshot unavailable")
            try {
                lastPixel = image.getPixel(candidate.first, candidate.second)
                if (kotlin.math.abs(Color.red(lastPixel) - 40) <= 8 &&
                    kotlin.math.abs(Color.green(lastPixel) - 120) <= 8 &&
                    kotlin.math.abs(Color.blue(lastPixel) - 200) <= 8) location = candidate
            } finally { image.recycle() }
            if (location == null) SystemClock.sleep(100)
        }
        if (location == null) evidence("map-mutated-pin-not-visible")
        assertEquals("The compositor must show the new pin red channel", 40.0, Color.red(lastPixel).toDouble(), 8.0)
        assertEquals("The compositor must show the new pin green channel", 120.0, Color.green(lastPixel).toDouble(), 8.0)
        assertEquals("The compositor must show the new pin blue channel", 200.0, Color.blue(lastPixel).toDouble(), 8.0)
        val tap = location ?: throw AssertionError("The updated native pin was never visible")
        val downAt = SystemClock.uptimeMillis()
        for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
            val touch = android.view.MotionEvent.obtain(downAt, SystemClock.uptimeMillis(), action, tap.first.toFloat(), tap.second.toFloat(), 0)
            try { assertTrue(instrumentation.uiAutomation.injectInputEvent(touch, true)) } finally { touch.recycle() }
        }
        awaitState("Tapping the actual native pin must dispatch its stable marker ID") { pressed.get() == "start" }
        evidence("map-mutated-pin-and-camera")
    }

    @Test
    fun controlledRegionEchoPreservesTheCameraAfterANativeDrag() = withMap { _, host, _, map, _ ->
        val before = AtomicReference<org.maplibre.android.camera.CameraPosition>()
        val after = AtomicReference<org.maplibre.android.camera.CameraPosition>()
        val settled = CountDownLatch(1)
        val origin = main {
            host.onRegionChangeComplete = { region ->
                before.set(map.cameraPosition)
                host.configure(props().put("region", region), overlays()) {}
                host.postDelayed({ after.set(map.cameraPosition); settled.countDown() }, 500)
            }
            IntArray(2).also { host.getLocationOnScreen(it) } to (host.width to host.height)
        }
        val downAt = SystemClock.uptimeMillis()
        for (step in 0..8) {
            val action = if (step == 0) android.view.MotionEvent.ACTION_DOWN else if (step == 8) android.view.MotionEvent.ACTION_UP else android.view.MotionEvent.ACTION_MOVE
            val touch = android.view.MotionEvent.obtain(downAt, SystemClock.uptimeMillis(), action,
                origin.first[0] + origin.second.first * (0.3f + step * 0.025f),
                origin.first[1] + origin.second.second * (0.3f + step * 0.01f), 0)
            try { assertTrue(instrumentation.uiAutomation.injectInputEvent(touch, true)) } finally { touch.recycle() }
            SystemClock.sleep(35)
        }
        assertTrue("The native drag did not publish a settled region", settled.await(15, TimeUnit.SECONDS))
        main {
            assertEquals("Echoing a native region must preserve zoom", before.get().zoom, after.get().zoom, 0.001)
            assertEquals("Echoing a native region must preserve latitude", before.get().target!!.latitude, after.get().target!!.latitude, 0.000001)
            assertEquals("Echoing a native region must preserve longitude", before.get().target!!.longitude, after.get().target!!.longitude, 0.000001)
        }
        evidence("map-controlled-region-after-drag")
        main {
            host.configure(props().put("region", JSONObject()
                .put("center", JSONObject().put("latitude", 47.04).put("longitude", 11.04))
                .put("span", JSONObject().put("latitudeDelta", 0.004).put("longitudeDelta", 0.004))), overlays()) {}
        }
        awaitState("A new controlled region must still move the native camera") {
            val target = map.cameraPosition.target
            target != null && kotlin.math.abs(target.latitude - before.get().target!!.latitude) > 0.01 &&
                kotlin.math.abs(target.longitude - before.get().target!!.longitude) > 0.01
        }
    }

    @Test
    fun backgroundAndResumeKeepTheNativeMapAndCamera() = withMap { activity, host, _, map, _ ->
        awaitBasemapPixels(host, "before-background")
        val camera = main { map.cameraPosition }
        assertTrue("The system Home action must succeed", instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME))
        awaitState("Home must stop the native map activity before testing its restoration") {
            activity.lifecycle.currentState == androidx.lifecycle.Lifecycle.State.CREATED && !activity.hasWindowFocus()
        }
        instrumentation.uiAutomation.waitForIdle(500, 5_000)
        assertNotEquals("The Home action must actually background the app", activity.packageName, instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString())
        // startActivitySync waits for a new Activity creation; this Intent
        // deliberately resumes the existing instance instead.
        instrumentation.targetContext.startActivity(Intent(instrumentation.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        awaitState("Returning must resume the retained native map activity") {
            activity.lifecycle.currentState == androidx.lifecycle.Lifecycle.State.RESUMED && activity.hasWindowFocus()
        }
        awaitState("The resumed native map must render its retained route and arrows") {
            features(map).size == 3 && map.queryRenderedFeatures(map.projection.toScreenLocation(LatLng(47.005, 11.005)), "craft-map-directions").isNotEmpty()
        }
        awaitBasemapPixels(host, "after-background")
        main {
            assertEquals(camera.zoom, map.cameraPosition.zoom, 0.001)
            assertEquals(camera.target!!.latitude, map.cameraPosition.target!!.latitude, 0.000001)
            assertEquals(camera.target!!.longitude, map.cameraPosition.target!!.longitude, 0.000001)
        }
        evidence("map-resumed-after-home")
    }

    @Test
    fun mapUtilityChromeRefreshesForNightMode() = withMap { activity, host, _, _, _ ->
        val originalMode = activity.resources.configuration.uiMode
        fun setNightMode(mode: Int): Int {
            return main {
                val configuration = Configuration(activity.resources.configuration)
                configuration.uiMode = (configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or mode
                activity.resources.updateConfiguration(configuration, activity.resources.displayMetrics)
                host.refreshThemeDefaults()
                (host.getChildAt(1).background as ColorDrawable).color
            }
        }
        try {
            val lightSurface = setNightMode(Configuration.UI_MODE_NIGHT_NO)
            val darkSurface = setNightMode(Configuration.UI_MODE_NIGHT_YES)
            assertNotEquals("Map scale chrome must change surface for dark mode", lightSurface, darkSurface)
        } finally {
            setNightMode(originalMode and Configuration.UI_MODE_NIGHT_MASK)
        }
    }

    @Test
    fun dynamicMapOverlayColorsRefreshForNightMode() = withMap { activity, host, _, map, _ ->
        val originalMode = activity.resources.configuration.uiMode
        try {
            main {
                val light = Configuration(activity.resources.configuration)
                light.uiMode = (light.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or Configuration.UI_MODE_NIGHT_NO
                activity.resources.updateConfiguration(light, activity.resources.displayMetrics)
                host.configure(props(), overlays("label")) {}
                host.refreshThemeDefaults()
            }
            awaitState("The native map must resolve label markers in light mode") {
                features(map).firstOrNull { it.getStringProperty("craftOverlayId") == "start" }
                    ?.getStringProperty("color") == "rgba(0,0,0,1.0)"
            }
            main {
                val dark = Configuration(activity.resources.configuration)
                dark.uiMode = (dark.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or Configuration.UI_MODE_NIGHT_YES
                activity.resources.updateConfiguration(dark, activity.resources.displayMetrics)
                host.refreshThemeDefaults()
            }
            awaitState("The native map must refresh label markers in dark mode") {
                features(map).firstOrNull { it.getStringProperty("craftOverlayId") == "start" }
                    ?.getStringProperty("color") == "rgba(255,255,255,1.0)"
            }
        } finally {
            main {
                val restore = Configuration(activity.resources.configuration)
                restore.uiMode = (restore.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or (originalMode and Configuration.UI_MODE_NIGHT_MASK)
                activity.resources.updateConfiguration(restore, activity.resources.displayMetrics)
                host.refreshThemeDefaults()
            }
        }
    }

    @Test
    fun showingTheLocationDotDoesNotRequestPermissionDuringRendering() = withMap { activity, host, _, map, _ ->
        assertEquals(PackageManager.PERMISSION_DENIED, activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION))
        main {
            host.configure(props().put("showsUserLocation", true), overlays()) {}
            assertFalse(map.locationComponent.isLocationComponentActivated)
        }
        instrumentation.uiAutomation.waitForIdle(500, 5_000)
        assertEquals("Rendering a map must not open a permission dialog", activity.packageName, instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString())
        evidence("map-location-permission-not-requested")
    }
    @Test fun pointerModesTreatMapImplementationViewsAsOneLeafControl() {
        val scenario = androidx.test.core.app.ActivityScenario.launch(MainActivity::class.java)
        lateinit var host: android.widget.FrameLayout
        lateinit var map: CraftNativeMapView
        var last = ""
        try {
            scenario.onActivity { activity ->
                host = android.widget.FrameLayout(activity)
                val under = android.widget.Button(activity).apply { stateListAnimator = null; elevation = 0f; setOnClickListener { last = "under" } }
                host.addView(under, ViewGroup.LayoutParams(200, 200))
                map = CraftNativeMapView(activity)
                // An unmarked native implementation view belongs to the Map;
                // it is not an authored STX descendant for box-only targeting.
                map.addView(View(activity).apply { setOnClickListener { last = "map" } }, ViewGroup.LayoutParams(200, 200))
                host.addView(map, ViewGroup.LayoutParams(200, 200))
                activity.setContentView(host)
            }
            instrumentation.waitForIdleSync()
            for (mode in listOf("none", "box-none", "box-only", "auto")) {
                scenario.onActivity {
                    CraftNativePointers.configure(map, JSONObject().put("pointerEvents", mode), JSONObject(), false)
                    last = ""
                    val now = SystemClock.uptimeMillis()
                    for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
                        val event = android.view.MotionEvent.obtain(now, now + 50, action, 50f, 50f, 0)
                        try { host.dispatchTouchEvent(event) } finally { event.recycle() }
                    }
                }
                instrumentation.waitForIdleSync()
                scenario.onActivity { assertEquals(mode, if (mode == "none" || mode == "box-none") "under" else "map", last) }
            }
        } finally {
            scenario.onActivity { map.destroy() }
            scenario.close()
        }
    }

}
