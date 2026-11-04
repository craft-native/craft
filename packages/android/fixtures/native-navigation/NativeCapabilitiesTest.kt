package dev.craft.navigationtest

import android.content.Intent
import android.media.AudioManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.MediaPlayer
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
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
class NativeCapabilitiesTest {
    @Test fun notificationReplyRunsInHeadlessAppAndRejectsForgedLaunchExtras() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.executeShellCommand("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS").use {
                java.io.FileInputStream(it.fileDescriptor).use { stream -> stream.readBytes() }
            }
            assertEquals("A local-only app must declare and obtain notification permission",
                android.content.pm.PackageManager.PERMISSION_GRANTED,
                context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS))
        }
        // No Activity is launched by this test; the worker must load __app.
        assertNull("The test must exercise a headless app, not a retained Activity", CraftNativeBackground.foreground)
        val storage = context.getSharedPreferences("craft-native-storage", android.content.Context.MODE_PRIVATE)
        storage.edit().remove("fixture-notification-action").commit()
        val manager = context.getSystemService(android.content.Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        val id = "fixture-reply-${UUID.randomUUID()}"
        try {
            val forged = Intent(context, MainActivity::class.java).putExtra("craft.actionToken", "not-minted")
            instrumentation.runOnMainSync { assertTrue(CraftNativeNotifications.receiveAction(context, forged)) }
            assertNull(storage.getString("fixture-notification-action", null))
            val value = JSONObject().put("title", "Fixture message").put("body", "Reply without opening a screen")
                .put("categoryId", "fixture-message").put("threadIdentifier", "fixture-thread")
                .put("data", JSONObject().put("thread", 42))
            val deadline = android.os.SystemClock.uptimeMillis() + 30000
            instrumentation.runOnMainSync { CraftNativeNotifications.show(context, value, id, "craft-fixture-actions") }
            // The system enqueues publication; observe the single submission
            // within the same deadline used for the headless reply below.
            var visible: android.service.notification.StatusBarNotification? = null
            while (visible == null && android.os.SystemClock.uptimeMillis() < deadline) {
                visible = manager.activeNotifications.firstOrNull { it.tag == id }
                if (visible == null) android.os.SystemClock.sleep(50)
            }
            val posted = requireNotNull(visible) { "The permitted local notification was not published" }
            assertEquals("fixture-thread", posted.notification.group)
            val reply = posted.notification.actions.first { it.title.toString() == "Reply" }
            assertTrue(!reply.remoteInputs.isNullOrEmpty())
            val fillIn = Intent()
            val results = android.os.Bundle().apply { putCharSequence("craft.reply", "Hello 👋") }
            androidx.core.app.RemoteInput.addResultsToIntent(
                arrayOf(androidx.core.app.RemoteInput.Builder("craft.reply").build()), fillIn, results)
            reply.actionIntent.send(context, 0, fillIn)
            var delivered: JSONObject? = null
            while (delivered == null && android.os.SystemClock.uptimeMillis() < deadline) {
                delivered = storage.getString("fixture-notification-action", null)?.let { JSONObject(it) }
                if (delivered == null) android.os.SystemClock.sleep(50)
            }
            val detail = requireNotNull(delivered) { "Notification reply did not reach the headless app script" }
            assertEquals("reply", detail.getString("actionId"))
            assertEquals(id, detail.getString("notificationId"))
            assertEquals("Hello 👋", detail.getString("userText"))
            assertEquals(42, detail.getJSONObject("data").getInt("thread"))
            assertTrue(detail.getString("id").isNotEmpty())
            while (manager.activeNotifications.any { it.tag == "craft.group:fixture-thread" } &&
                android.os.SystemClock.uptimeMillis() < deadline) android.os.SystemClock.sleep(50)
            assertFalse("The last handled child must not leave an empty notification group",
                manager.activeNotifications.any { it.tag == "craft.group:fixture-thread" })
            // A cancelled notification invalidates every remaining action token.
            instrumentation.runOnMainSync {
                CraftNativeNotifications.show(context, value, id, "craft-fixture-actions")
                CraftNativeNotifications.cancel(context, id)
            }
            while (manager.activeNotifications.any { it.tag == id || it.tag == "craft.group:fixture-thread" } &&
                android.os.SystemClock.uptimeMillis() < deadline) android.os.SystemClock.sleep(50)
            assertFalse(manager.activeNotifications.any { it.tag == id || it.tag == "craft.group:fixture-thread" })
            val tokens = context.getSharedPreferences("craft-native-notification-actions", android.content.Context.MODE_PRIVATE)
            assertFalse(tokens.all.values.any { raw ->
                runCatching { JSONObject(raw as String).optJSONObject("value")?.optString("id") == id }.getOrDefault(false)
            })
        } finally {
            instrumentation.runOnMainSync { CraftNativeNotifications.cancel(context, id) }
            manager.cancel(id, 0)
            manager.cancel("craft.group:fixture-thread", 1)
            androidx.work.WorkManager.getInstance(context).cancelUniqueWork("craft-native-background-once").result.get(10, TimeUnit.SECONDS)
        }
    }

    @Test fun notificationGroupMembershipSurvivesQueuedRemovalReplacementAndDismissal() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.executeShellCommand("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS").use {
                java.io.FileInputStream(it.fileDescriptor).use { stream -> stream.readBytes() }
            }
            assertEquals(android.content.pm.PackageManager.PERMISSION_GRANTED,
                context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS))
        }
        val manager = context.getSystemService(android.content.Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        val prefix = "fixture-groups-${UUID.randomUUID()}"
        val first = "$prefix-first"
        val second = "$prefix-second"
        val probe = "$prefix-probe"
        val left = "$prefix-left"
        val right = "$prefix-right"
        val deadline = android.os.SystemClock.uptimeMillis() + 30000
        fun value(thread: String = "") = JSONObject().put("title", "Group membership")
            .put("body", "Native notification ownership").put("threadIdentifier", thread)
        fun awaitState(message: String, matches: (Array<android.service.notification.StatusBarNotification>) -> Boolean) {
            while (android.os.SystemClock.uptimeMillis() < deadline) {
                if (matches(manager.activeNotifications)) return
                android.os.SystemClock.sleep(50)
            }
            assertTrue(message, matches(manager.activeNotifications))
        }
        try {
            instrumentation.runOnMainSync {
                CraftNativeNotifications.show(context, value(left), first, "craft-fixture-actions")
                CraftNativeNotifications.show(context, value(left), second, "craft-fixture-actions")
            }
            awaitState("Both children and their group must be published") { entries ->
                listOf(first, second, "craft.group:$left").all { tag -> entries.any { it.tag == tag } }
            }
            instrumentation.runOnMainSync {
                CraftNativeNotifications.cancel(context, first)
                CraftNativeNotifications.cancel(context, second)
                CraftNativeNotifications.show(context, value(), probe, "craft-fixture-actions")
            }
            awaitState("Consecutive cancellations must remove the final group before the later probe") { entries ->
                entries.any { it.tag == probe } && entries.none { it.tag in listOf(first, second, "craft.group:$left") }
            }
            instrumentation.runOnMainSync {
                CraftNativeNotifications.show(context, value(left), first, "craft-fixture-actions")
                CraftNativeNotifications.show(context, value(right), first, "craft-fixture-actions")
                CraftNativeNotifications.show(context, value(left), second, "craft-fixture-actions")
            }
            awaitState("Replacing a queued child must move it to its new group without losing its sibling") { entries ->
                entries.any { it.tag == first && it.notification.group == right } &&
                    entries.any { it.tag == second && it.notification.group == left } &&
                    listOf(left, right).all { group -> entries.any { it.tag == "craft.group:$group" } }
            }
            instrumentation.runOnMainSync { CraftNativeNotifications.cancel(context, first) }
            awaitState("Removing one group must preserve the other child's group") { entries ->
                entries.none { it.tag == first || it.tag == "craft.group:$right" } &&
                    entries.any { it.tag == second } && entries.any { it.tag == "craft.group:$left" }
            }
            val child = requireNotNull(manager.activeNotifications.firstOrNull { it.tag == second })
            child.notification.deleteIntent.send()
            awaitState("The system dismissal receiver must remove the last group") { entries ->
                entries.none { it.tag == second || it.tag == "craft.group:$left" }
            }
            instrumentation.runOnMainSync {
                CraftNativeNotifications.show(context, value(left), first, "craft-fixture-actions")
                CraftNativeNotifications.cancel(context, first)
                CraftNativeNotifications.show(context, value(right), second, "craft-fixture-actions")
                CraftNativeNotifications.cancelAll(context)
                CraftNativeNotifications.show(context, value(), probe, "craft-fixture-actions")
            }
            awaitState("Immediate cancel and cancel-all must also remove notifications still being published") { entries ->
                entries.any { it.tag == probe } && entries.none {
                    it.tag in listOf(first, second, "craft.group:$left", "craft.group:$right")
                }
            }
        } finally {
            instrumentation.runOnMainSync {
                listOf(first, second, probe).forEach { CraftNativeNotifications.cancel(context, it) }
            }
        }
    }

    private class MotionSourceProbe : CraftMotionSource {
        val requests = mutableListOf<Triple<Int, Int, (FloatArray, Long, Int) -> Unit>>()
        val stopped = mutableListOf<Int>()
        var present = true
        var reject = false
        var throwOnRegister = false
        override fun available(type: Int) = present
        override fun register(type: Int, periodUs: Int, sample: (FloatArray, Long, Int) -> Unit): CraftMotionRegistration? {
            if (throwOnRegister) throw SecurityException("fixture denied")
            if (reject) return null
            val index = requests.size
            requests.add(Triple(type, periodUs, sample))
            return object : CraftMotionRegistration { override fun close() { stopped.add(index) } }
        }
        fun deliver(index: Int, values: FloatArray = floatArrayOf(1f, 2f, 3f)) {
            requests[index].third(values, 12_345_678_900L, 3)
        }
    }

    private fun motionStart(sensor: String, interval: Any = 100): JSONArray =
        JSONArray().put(JSONObject().put("sensor", sensor).put("intervalMs", interval))

    @Test fun rawMotionReportsHardwareAvailabilityAndRegistrationFailure() {
        val source = MotionSourceProbe()
        val host = CraftNativeMotion(source)
        try {
            source.present = false
            val availability = host.perform("getAvailability", JSONArray()).data as JSONObject
            for (name in listOf("accelerometer", "gyroscope", "magnetometer", "rotationVector")) {
                assertFalse(availability.getBoolean(name))
                assertEquals("UNAVAILABLE", host.perform("start", motionStart(name)).code)
            }
            assertTrue(source.requests.isEmpty())
            source.present = true
            source.reject = true
            assertEquals("UNAVAILABLE", host.perform("start", motionStart("gyroscope")).code)
            source.reject = false
            source.throwOnRegister = true
            assertEquals("SENSOR_ERROR", host.perform("start", motionStart("gyroscope")).code)
        } finally { host.close() }
    }

    @Test fun rawMotionRejectsInvalidReplacementWithoutDroppingWorkingStream() {
        val source = MotionSourceProbe()
        val host = CraftNativeMotion(source)
        val events = mutableListOf<JSONObject>()
        host.emit = events::add
        try {
            assertNull(host.perform("start", motionStart("accelerometer", 20)).code)
            assertEquals(20_000, source.requests.single().second)
            for (interval in listOf<Any>(0, -1, 4, 60_001, 20.5, "20", true, JSONObject.NULL)) {
                assertEquals("INVALID_ARGUMENT", host.perform("start", motionStart("accelerometer", interval)).code)
            }
            assertEquals("INVALID_ARGUMENT", host.perform("start", motionStart("attitude")).code)
            source.reject = true
            assertEquals("UNAVAILABLE", host.perform("start", motionStart("accelerometer")).code)
            assertTrue(source.stopped.isEmpty())
            source.deliver(0)
            assertEquals(1, events.size)
        } finally { host.close() }
    }

    @Test fun rawMotionNamesUnitsAndKeepsQuaternionSeparateFromAngularVelocity() {
        val source = MotionSourceProbe()
        val host = CraftNativeMotion(source)
        val events = mutableListOf<JSONObject>()
        host.emit = events::add
        try {
            val names = listOf("accelerometer", "gyroscope", "magnetometer", "rotationVector")
            val units = listOf("m/s²", "rad/s", "µT", "quaternion")
            names.forEachIndexed { index, name ->
                assertNull(host.perform("start", motionStart(name, 5)).code)
                source.deliver(index, if (name == "rotationVector") floatArrayOf(0f, 0f, 0f, 1f) else floatArrayOf(1f, 2f, 3f))
                val event = events.last()
                assertEquals(name, event.getString("sensor"))
                assertEquals(units[index], event.getString("unit"))
                assertEquals(12345.6789, event.getDouble("timestampMs"), 0.00001)
                assertEquals(3, event.getInt("accuracy"))
                if (name == "rotationVector") {
                    assertEquals(1.0, event.getJSONObject("values").getDouble("w"), 0.0)
                    assertEquals(0.0, event.getJSONObject("values").getDouble("x"), 0.0)
                } else assertFalse(event.getJSONObject("values").has("w"))
            }
        } finally { host.close() }
    }

    @Test fun rawMotionDiscardsRetiredSamplesAndClosesOnlyItsOwnRegistrations() {
        val source = MotionSourceProbe()
        val host = CraftNativeMotion(source)
        val events = mutableListOf<JSONObject>()
        host.emit = events::add
        assertNull(host.perform("start", motionStart("gyroscope")).code)
        assertNull(host.perform("start", motionStart("gyroscope", 40)).code)
        assertEquals(listOf(0), source.stopped)
        source.deliver(0)
        assertTrue(events.isEmpty())
        source.deliver(1)
        assertEquals(1, events.size)
        assertEquals(true, host.perform("stop", JSONArray().put("gyroscope")).data)
        assertEquals(false, host.perform("stop", JSONArray().put("gyroscope")).data)
        source.deliver(1)
        assertEquals(1, events.size)
        host.perform("start", motionStart("magnetometer"))
        host.stopAll() // Activity pause uses exactly this teardown.
        source.deliver(2)
        assertEquals(1, events.size)
        host.perform("start", motionStart("magnetometer"))
        host.close()
        host.close()
        source.deliver(3)
        assertEquals(listOf(0, 1, 2, 3), source.stopped)
        assertEquals(1, events.size)
        assertEquals("HOST_CLOSED", host.perform("start", motionStart("gyroscope")).code)
    }

    @Test fun rawMotionRegistersWithThePlatformAndStopsDelivery() {
        val context = importContext()
        val events = java.util.concurrent.atomic.AtomicInteger()
        val arrived = CountDownLatch(1)
        lateinit var host: CraftNativeMotion
        instrumentation.runOnMainSync {
            host = CraftNativeMotion(CraftAndroidMotionSource(context))
            host.emit = { events.incrementAndGet(); arrived.countDown() }
            val available = host.perform("getAvailability", JSONArray()).data as JSONObject
            assertTrue("emulator fixture must provide an accelerometer", available.getBoolean("accelerometer"))
            assertNull(host.perform("start", motionStart("accelerometer", 20)).code)
        }
        try {
            assertTrue("SensorManager must deliver a real sample", arrived.await(10, TimeUnit.SECONDS))
            instrumentation.runOnMainSync { host.stopAll() }
            val stoppedAt = events.get()
            Thread.sleep(150)
            assertEquals(stoppedAt, events.get())
        } finally { instrumentation.runOnMainSync { host.close() } }
    }

    @Test fun barometerConvertsPressureToSessionRelativeAltitude() {
        val source = MotionSourceProbe()
        val host = CraftNativeBarometer(source)
        val events = mutableListOf<JSONObject>()
        host.emit = events::add
        try {
            assertNull(host.perform("start", JSONArray()).code)
            assertEquals(android.hardware.Sensor.TYPE_PRESSURE, source.requests.single().first)
            source.deliver(0, floatArrayOf(1013.25f))
            assertEquals(0.0, events.last().getDouble("relativeAltitudeMeters"), 0.001)
            source.deliver(0, floatArrayOf(1000f))
            val sample = events.last()
            assertEquals("sample", sample.getString("state"))
            assertEquals(1000.0, sample.getDouble("pressureHpa"), 0.0)
            assertEquals(1013.25, sample.getDouble("referencePressureHpa"), 0.0)
            assertEquals(android.hardware.SensorManager.getAltitude(1013.25f, 1000f).toDouble(), sample.getDouble("relativeAltitudeMeters"), 0.001)
            assertTrue(sample.getDouble("relativeAltitudeMeters") > 100)
            assertEquals(12345.6789, sample.getDouble("timestampMs"), 0.00001)
        } finally { host.close() }
    }

    @Test fun barometerRejectsBackgroundAndBadReplacementsWithoutLosingBaseline() {
        val source = MotionSourceProbe()
        val host = CraftNativeBarometer(source)
        val events = mutableListOf<JSONObject>()
        host.emit = events::add
        try {
            val availability = host.perform("getAvailability", JSONArray()).data as JSONObject
            assertTrue(availability.getBoolean("relativeAltitude"))
            assertFalse(availability.getBoolean("absoluteAltitude"))
            assertFalse(availability.getBoolean("background"))
            host.perform("start", JSONArray())
            source.deliver(0, floatArrayOf(1000f))
            assertEquals("UNSUPPORTED", host.perform("start", JSONArray().put(JSONObject().put("background", true))).code)
            for (args in listOf(JSONArray().put("bad"), JSONArray().put(JSONObject().put("background", "false")),
                JSONArray().put(JSONObject().put("intervalMs", 0)), JSONArray().put(JSONObject().put("intervalMs", 0.5)))) {
                assertEquals("INVALID_ARGUMENT", host.perform("start", args).code)
            }
            source.reject = true
            assertEquals("UNAVAILABLE", host.perform("start", JSONArray()).code)
            assertTrue(source.stopped.isEmpty())
            source.deliver(0, floatArrayOf(995f))
            assertEquals(1000.0, events.last().getDouble("referencePressureHpa"), 0.0)
        } finally { host.close() }
    }

    @Test fun barometerAnnouncesBackgroundGapsAndResetsBaselineOnRestart() {
        val source = MotionSourceProbe()
        val host = CraftNativeBarometer(source)
        val events = mutableListOf<JSONObject>()
        host.emit = events::add
        host.perform("start", JSONArray())
        source.deliver(0, floatArrayOf(1000f))
        host.stop("background")
        assertEquals("stopped", events.last().getString("state"))
        assertEquals("background", events.last().getString("reason"))
        source.deliver(0, floatArrayOf(900f))
        assertEquals(2, events.size)
        host.perform("start", JSONArray())
        source.deliver(1, floatArrayOf(900f))
        assertEquals(0.0, events.last().getDouble("relativeAltitudeMeters"), 0.001)
        host.perform("start", JSONArray())
        source.deliver(1, floatArrayOf(850f))
        assertEquals(3, events.size)
        source.deliver(2, floatArrayOf(850f))
        assertEquals(0.0, events.last().getDouble("relativeAltitudeMeters"), 0.001)
        host.close()
        source.deliver(2, floatArrayOf(800f))
        assertEquals("disposed", events.last().getString("reason"))
        assertEquals(listOf(0, 1, 2), source.stopped)
        assertEquals("HOST_CLOSED", host.perform("start", JSONArray()).code)
    }

    @Test fun barometerHandlesMissingHardwareAndInvalidPressureWithoutFakeAltitude() {
        val source = MotionSourceProbe()
        val host = CraftNativeBarometer(source)
        val events = mutableListOf<JSONObject>()
        host.emit = events::add
        try {
            source.present = false
            assertFalse((host.perform("getAvailability", JSONArray()).data as JSONObject).getBoolean("relativeAltitude"))
            assertEquals("UNAVAILABLE", host.perform("start", JSONArray()).code)
            source.present = true
            for (pressure in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY)) {
                host.perform("start", JSONArray())
                source.deliver(source.requests.lastIndex, floatArrayOf(pressure))
                assertEquals("sensorError", events.last().getString("reason"))
                assertFalse(events.last().has("relativeAltitudeMeters"))
            }
        } finally { host.close() }
    }

    @Test fun pedometerPermissionCancellationCannotResolveTheNextRequest() {
        var granted = false
        val launched = mutableListOf<Int>()
        val replies = mutableListOf<Pair<String, CraftNativeCapabilityResult>>()
        val host = CraftNativeCapabilities(instrumentation.targetContext, JSONObject().put("enablePedometer", true),
            requestPedometerPermission = { launched.add(it) }, checkPedometerPermission = { granted })
        try {
            instrumentation.runOnMainSync {
                fun ask(token: String) { host.perform(token, 1, "Pedometer", "requestPermission", JSONArray()) { replies.add(token to it) } }
                ask("old")
                assertEquals(1, launched.size)
                host.cancel("old")
                ask("busy")
                assertEquals("PERMISSION_BUSY", replies.single().second.code)
                host.onPedometerPermissions(999)
                assertEquals(1, replies.size)
                host.onPedometerPermissions(launched.single())
                assertEquals(1, replies.size)
                ask("next")
                assertEquals(2, launched.size)
                granted = true
                host.onPedometerPermissions(launched.last())
                assertEquals("next", replies.last().first)
                assertEquals("granted", replies.last().second.data)
                granted = false
                ask("disposed")
                host.close()
                host.onPedometerPermissions(launched.last())
                assertEquals(2, replies.size)
            }
        } finally { host.close() }
        val disabled = CraftNativeCapabilities(instrumentation.targetContext, JSONObject(),
            requestPedometerPermission = { error("disabled must never prompt") })
        try { assertEquals("CAPABILITY_DISABLED", call(disabled, "Pedometer", "requestPermission").code) }
        finally { disabled.close() }
    }

    @Test fun pedometerKeepsSinceBootCountsSeparateFromDetectorEvents() {
        val source = MotionSourceProbe()
        val host = CraftNativePedometer(source) { true }
        val events = mutableListOf<JSONObject>()
        host.emit = events::add
        try {
            assertNull(host.perform("start", JSONArray()).code)
            assertEquals(android.hardware.Sensor.TYPE_STEP_COUNTER, source.requests.last().first)
            source.deliver(0, floatArrayOf(1234f))
            assertEquals("counter", events.last().getString("kind"))
            assertEquals(1234.0, events.last().getDouble("stepsSinceBoot"), 0.0)
            assertFalse(events.last().has("steps"))
            assertFalse(events.last().has("startDate"))
            host.perform("start", JSONArray().put(JSONObject().put("sensor", "detector")))
            assertEquals(android.hardware.Sensor.TYPE_STEP_DETECTOR, source.requests.last().first)
            source.deliver(1, floatArrayOf(1f))
            assertEquals("step", events.last().getString("kind"))
            assertEquals(1, events.last().getInt("count"))
            assertFalse(events.last().has("stepsSinceBoot"))
            assertEquals(12345.6789, events.last().getDouble("timestampMs"), 0.00001)
            source.deliver(0, floatArrayOf(9999f))
            assertEquals(2, events.size)
        } finally { host.close() }
    }

    @Test fun pedometerRejectsMissingPermissionAndUnsupportedIntervalHistory() {
        val source = MotionSourceProbe()
        var granted = false
        val host = CraftNativePedometer(source) { granted }
        try {
            assertEquals("denied", host.perform("getPermissionStatus", JSONArray()).data)
            assertEquals("PERMISSION_DENIED", host.perform("start", JSONArray()).code)
            assertTrue(source.requests.isEmpty())
            granted = true
            assertEquals("granted", host.perform("getPermissionStatus", JSONArray()).data)
            assertEquals("UNSUPPORTED", host.perform("query", JSONArray()).code)
            assertEquals("UNSUPPORTED", host.perform("start", JSONArray().put(JSONObject().put("startDate", 0))).code)
            assertEquals("UNSUPPORTED", host.perform("start", JSONArray().put(JSONObject().put("background", true))).code)
            val availability = host.perform("getAvailability", JSONArray()).data as JSONObject
            assertFalse(availability.getBoolean("history"))
            assertFalse(availability.getBoolean("background"))
            assertFalse(availability.getBoolean("floors"))
            source.present = false
            assertEquals("UNAVAILABLE", host.perform("start", JSONArray()).code)
        } finally { host.close() }
    }

    @Test fun pedometerBackgroundAndRevocationStopDeliveryWithoutSyntheticCounts() {
        val source = MotionSourceProbe()
        var granted = true
        val host = CraftNativePedometer(source) { granted }
        val events = mutableListOf<JSONObject>()
        host.emit = events::add
        host.perform("start", JSONArray())
        source.deliver(0, floatArrayOf(100f))
        assertEquals("INVALID_ARGUMENT", host.perform("start", JSONArray().put(JSONObject().put("sensor", "invalid"))).code)
        assertTrue(source.stopped.isEmpty())
        granted = false
        source.deliver(0, floatArrayOf(101f))
        assertEquals("permissionDenied", events.last().getString("reason"))
        granted = true
        host.perform("start", JSONArray())
        host.stop("background")
        assertEquals("background", events.last().getString("reason"))
        source.deliver(1, floatArrayOf(102f))
        assertEquals(3, events.size)
        host.close()
        assertEquals(listOf(0, 1), source.stopped)
        assertEquals("HOST_CLOSED", host.perform("start", JSONArray()).code)
    }

    private class PickerHostProbe : CraftNativePickerHost {
        val launched = mutableListOf<Int>()
        val dismissed = mutableListOf<Int>()
        var refuseLaunch = false
        override fun launch(intent: Intent, requestCode: Int) {
            check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
            launched.add(requestCode)
            if (refuseLaunch) throw android.content.ActivityNotFoundException("fixture launch refused")
        }
        override fun dismiss(requestCode: Int) {
            check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
            dismissed.add(requestCode)
        }
    }

    @Test
    fun pickerCodesRestoreWithoutRewindingOrWrappingIntoStaleResults() {
        val codes = CraftNativePickerCodes()
        val first = codes.allocate()!!
        val saved = codes.snapshot()
        val recreated = CraftNativePickerCodes()
        recreated.restore(saved)
        assertTrue(recreated.allocate()!! > first)
        recreated.restore(first)
        assertTrue(recreated.allocate()!! > saved)
        val exhausted = CraftNativePickerCodes(0xffff)
        assertEquals(0xffff, exhausted.allocate())
        assertNull("exhaustion must not reuse a result identity", exhausted.allocate())
    }

    @Test
    fun cancellationBeforeQueuedPickerLaunchDoesNotOpenUiOrRetainToken() {
        val context = importContext()
        val host = PickerHostProbe()
        val capabilities = CraftNativeCapabilities(context, JSONObject(), host)
        try {
            for (method in listOf("pickFile", "pickImage", "pickVideo")) {
                instrumentation.runOnMainSync {
                    capabilities.perform(method, 1, "Files", method, JSONArray()) { throw AssertionError("cancelled admission replied") }
                    capabilities.cancel(method)
                }
                instrumentation.waitForIdleSync()
            }
            assertTrue(host.launched.isEmpty())
            assertTrue(host.dismissed.isEmpty())
            val cancelled = CraftNativeCapabilities::class.java.getDeclaredField("cancelled").apply { isAccessible = true }.get(capabilities) as Set<*>
            assertTrue("pre-launch cancellation tokens leaked", cancelled.isEmpty())
        } finally { capabilities.close(); instrumentation.waitForIdleSync(); context.cacheDir.deleteRecursively() }
    }

    @Test
    fun cancelledPickerResultsCannotCompleteRetryOrReadOldFiles() {
        for (method in listOf("pickFile", "pickImage", "pickVideo")) {
            val context = importContext()
            val host = PickerHostProbe()
            val capabilities = CraftNativeCapabilities(context, JSONObject(), host)
            val replies = java.util.concurrent.atomic.AtomicInteger()
            try {
                capabilities.perform("old", 1, "Files", method, JSONArray()) { replies.incrementAndGet() }
                instrumentation.waitForIdleSync()
                val old = host.launched.single()
                capabilities.cancel("old") // off-main caller, as with script teardown
                instrumentation.waitForIdleSync()
                assertEquals(listOf(old), host.dismissed)
                val done = CountDownLatch(1)
                var result: CraftNativeCapabilityResult? = null
                capabilities.perform("retry", 1, "Files", method, JSONArray()) { result = it; done.countDown() }
                instrumentation.waitForIdleSync()
                val retry = host.launched.last()
                assertTrue(old != retry)
                instrumentation.runOnMainSync {
                    // A denied URI would fail immediately if the stale result
                    // were accidentally assigned to the new request.
                    val oldData = Intent().setData(android.net.Uri.parse("content://dev.craft.navigationtest.imports/denied"))
                    assertTrue(capabilities.onActivityResult(old, android.app.Activity.RESULT_OK, oldData))
                    assertTrue(capabilities.onActivityResult(old, android.app.Activity.RESULT_CANCELED, null))
                    assertFalse(capabilities.onActivityResult(8411, android.app.Activity.RESULT_CANCELED, null))
                }
                instrumentation.waitForIdleSync()
                assertEquals(0, replies.get())
                assertEquals(1L, done.count)
                assertTrue(java.io.File(context.cacheDir, "craft-files").listFiles().isNullOrEmpty())
                instrumentation.runOnMainSync {
                    capabilities.onActivityResult(retry, android.app.Activity.RESULT_CANCELED, null)
                    capabilities.onActivityResult(retry, android.app.Activity.RESULT_OK, Intent())
                }
                assertTrue(done.await(5, TimeUnit.SECONDS))
                assertNull(result?.code)
                if (method == "pickFile") assertEquals(0, (result?.data as JSONArray).length())
                else assertEquals(JSONObject.NULL, result?.data)
            } finally { capabilities.close(); instrumentation.waitForIdleSync(); context.cacheDir.deleteRecursively() }
        }
    }

    @Test
    fun closedPickerAndLaunchFailureDoNotStealNewHostResults() {
        val context = importContext()
        val host = PickerHostProbe()
        val old = CraftNativeCapabilities(context, JSONObject(), host)
        val next = CraftNativeCapabilities(context, JSONObject(), host)
        try {
            old.perform("closed", 1, "Files", "pickFile", JSONArray()) { throw AssertionError("closed picker replied") }
            instrumentation.waitForIdleSync()
            val oldCode = host.launched.single()
            val saved = android.os.Bundle()
            old.savePickerState(saved)
            old.close()
            next.restorePickerState(saved)
            instrumentation.waitForIdleSync()
            assertEquals(listOf(oldCode), host.dismissed)
            host.refuseLaunch = true
            assertEquals("PICKER_UNAVAILABLE", call(next, "Files", "pickFile").code)
            val failedCode = host.launched.last()
            host.refuseLaunch = false
            val done = CountDownLatch(1)
            var result: CraftNativeCapabilityResult? = null
            next.perform("current", 1, "Files", "pickFile", JSONArray()) { result = it; done.countDown() }
            instrumentation.waitForIdleSync()
            val current = host.launched.last()
            assertTrue(current > failedCode && failedCode > oldCode)
            instrumentation.runOnMainSync {
                val data = Intent().setData(android.net.Uri.parse("content://dev.craft.navigationtest.imports/ok"))
                old.onActivityResult(oldCode, android.app.Activity.RESULT_OK, data)
                next.onActivityResult(oldCode, android.app.Activity.RESULT_OK, data)
                next.onActivityResult(failedCode, android.app.Activity.RESULT_OK, data)
                assertEquals(1L, done.count)
                next.onActivityResult(current, android.app.Activity.RESULT_OK, data)
            }
            assertTrue(done.await(5, TimeUnit.SECONDS))
            assertNull(result?.code)
            val file = (result?.data as JSONArray).getJSONObject(0).getString("path")
            assertTrue(NativeImportProvider.bytes.contentEquals(java.io.File(file).readBytes()))
            assertNull(call(next, "Files", "remove", JSONArray().put(file)).code)
        } finally { old.close(); next.close(); instrumentation.waitForIdleSync(); context.cacheDir.deleteRecursively() }
    }

    @Test
    fun systemDocumentPickerDismissesOnCancellationAndCanRetry() {
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as MainActivity
        val capabilities = MainActivity::class.java.getDeclaredField("capabilities").apply { isAccessible = true }.get(activity) as CraftNativeCapabilities
        // AOSP and Google API 34/35 images use these DocumentsUI packages.
        // Inspect the visible UI, not package queries filtered by app visibility.
        val pickerPackages = setOf("com.android.documentsui", "com.google.android.documentsui")
        fun awaitPackage(expected: Set<String>) {
            val deadline = android.os.SystemClock.uptimeMillis() + 10_000
            while (instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString() !in expected && android.os.SystemClock.uptimeMillis() < deadline)
                android.os.SystemClock.sleep(100)
            assertTrue("expected visible package in $expected", instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString() in expected)
        }
        val token = "system-picker-${UUID.randomUUID()}"
        val replies = java.util.concurrent.atomic.AtomicInteger()
        try {
            capabilities.perform(token, 1, "Files", "pickFile", JSONArray()) { replies.incrementAndGet() }
            awaitPackage(pickerPackages)
            capabilities.cancel(token)
            awaitPackage(setOf(activity.packageName))
            assertEquals(0, replies.get())
            val done = CountDownLatch(1)
            var result: CraftNativeCapabilityResult? = null
            capabilities.perform("retry-$token", 1, "Files", "pickFile", JSONArray()) { result = it; done.countDown() }
            awaitPackage(pickerPackages)
            assertTrue(instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK))
            assertTrue(done.await(10, TimeUnit.SECONDS))
            assertNull(result?.code)
            assertEquals(0, (result?.data as JSONArray).length())
            awaitPackage(setOf(activity.packageName))
        } finally {
            capabilities.cancel(token)
            capabilities.cancel("retry-$token")
            instrumentation.runOnMainSync { activity.finish() }
        }
    }

    @Test
    fun networkStatusIsAvailableWithoutAWebViewAndClosesCleanly() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val capabilities = CraftNativeCapabilities(context, JSONObject())
        try {
            assertTrue(capabilities.names().toString().contains("\"network\""))
            val done = CountDownLatch(1)
            var answer: CraftNativeCapabilityResult? = null
            capabilities.perform("network-status", 1, "Network", "getStatus", JSONArray()) { result ->
                answer = result
                done.countDown()
            }
            assertTrue("network status did not settle", done.await(5, TimeUnit.SECONDS))
            assertNull(answer?.code)
            val status = answer?.data as JSONObject
            assertTrue(status.get("isConnected") is Boolean)
            assertTrue(setOf("none", "unknown", "wifi", "cellular", "ethernet").contains(status.getString("type")))
        } finally {
            capabilities.close()
        }
    }

    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    // A real local PCM file keeps these playback regressions independent of
    // networking, codecs downloaded by the device, and the user's media.
    private fun silentWav(): java.io.File {
        val samples = 8000 * 2
        val bytes = java.nio.ByteBuffer.allocate(44 + samples * 2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        bytes.put("RIFF".toByteArray()).putInt(36 + samples * 2).put("WAVEfmt ".toByteArray())
        bytes.putInt(16).putShort(1.toShort()).putShort(1.toShort()).putInt(8000).putInt(16000)
        bytes.putShort(2.toShort()).putShort(16.toShort()).put("data".toByteArray()).putInt(samples * 2)
        return java.io.File(instrumentation.targetContext.cacheDir, "sound-${UUID.randomUUID()}.wav").apply { writeBytes(bytes.array()) }
    }

    private fun sound(service: CraftNativeSounds, id: String = "tone"): Any =
        (CraftNativeSounds::class.java.getDeclaredField("sounds").apply { isAccessible = true }.get(service) as Map<*, *>)[id]!!

    private fun outputVolume(service: CraftNativeSounds, id: String): Float {
        val handle = sound(service, id)
        return CraftNativeSounds::class.java.getDeclaredMethod("outputVolume", handle.javaClass)
            .apply { isAccessible = true }.invoke(service, handle) as Float
    }

    private fun field(sound: Any, name: String): Any? =
        sound.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(sound)

    private fun focus(service: CraftNativeSounds, change: Int) {
        CraftNativeSounds::class.java.getDeclaredMethod("onAudioFocusChange", Int::class.javaPrimitiveType)
            .apply { isAccessible = true }.invoke(service, change)
    }

    @Test
    fun overlappingMusicAndEffectsStayDuckedThroughVolumeChangesAndFades() {
        val file = silentWav()
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                lateinit var service: CraftNativeSounds
                val ready = CountDownLatch(2)
                try {
                    scenario.onActivity { activity ->
                        service = CraftNativeSounds(activity)
                        for (id in listOf("music", "effect")) {
                            service.play(id, file.toURI().toString(), JSONObject().put("loop", true).put("volume", 0.8)) {
                                assertNull(it.message, it.code)
                                ready.countDown()
                            }
                        }
                    }
                    assertTrue("both players must prepare", ready.await(10, TimeUnit.SECONDS))
                    scenario.onActivity {
                        for (id in listOf("music", "effect")) assertTrue((field(sound(service, id), "player") as MediaPlayer).isPlaying)
                        focus(service, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
                        assertEquals(0.16f, outputVolume(service, "music"), 0.001f)
                        service.setVolume("music", 0.5, 0.0)
                        assertEquals(0.1f, outputVolume(service, "music"), 0.001f)
                        service.setVolume("effect", 0.4, 100.0)
                    }
                    android.os.SystemClock.sleep(250)
                    scenario.onActivity {
                        assertEquals(0.4f, field(sound(service, "effect"), "volume") as Float, 0.001f)
                        assertEquals(0.08f, outputVolume(service, "effect"), 0.001f)
                        focus(service, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
                        for (id in listOf("music", "effect")) {
                            assertFalse((field(sound(service, id), "player") as MediaPlayer).isPlaying)
                            assertFalse("resume must not bypass focus loss", service.resume(id))
                        }
                        service.pause("effect")
                        assertFalse(service.resume("effect"))
                        focus(service, AudioManager.AUDIOFOCUS_GAIN)
                        assertTrue((field(sound(service, "music"), "player") as MediaPlayer).isPlaying)
                        assertFalse((field(sound(service, "effect"), "player") as MediaPlayer).isPlaying)
                        assertEquals(0.5f, outputVolume(service, "music"), 0.001f)
                        assertEquals(0.4f, outputVolume(service, "effect"), 0.001f)
                        assertTrue(service.resume("effect"))
                        assertTrue((field(sound(service, "effect"), "player") as MediaPlayer).isPlaying)
                        service.stop("effect", 0.0)
                        assertTrue((field(sound(service, "music"), "player") as MediaPlayer).isPlaying)
                        focus(service, AudioManager.AUDIOFOCUS_LOSS)
                        assertFalse(service.resume("music"))
                        assertFalse(service.resume("effect"))
                    }
                } finally { scenario.onActivity { service.close() } }
            }
        } finally { file.delete() }
    }

    @Test
    fun systemAudioFocusInterruptionResumesMusicButKeepsUserPausedEffectsPaused() {
        val file = silentWav()
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                lateinit var service: CraftNativeSounds
                lateinit var manager: AudioManager
                lateinit var competitor: AudioFocusRequest
                val ready = CountDownLatch(2)
                val results = mutableListOf<CraftNativeCapabilityResult>()
                lateinit var music: MediaPlayer
                lateinit var effect: MediaPlayer
                fun awaitState(description: String, predicate: () -> Boolean) {
                    val deadline = android.os.SystemClock.uptimeMillis() + 5000
                    var matched = false
                    while (!matched && android.os.SystemClock.uptimeMillis() < deadline) {
                        scenario.onActivity { matched = predicate() }
                        if (!matched) android.os.SystemClock.sleep(20)
                    }
                    assertTrue(description, matched)
                }
                try {
                    scenario.onActivity { activity ->
                        manager = activity.getSystemService(android.content.Context.AUDIO_SERVICE) as AudioManager
                        // A distinct owned client goes through Android's real
                        // focus stack. Never call the service's callback here.
                        competitor = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                            .setAudioAttributes(AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                            .setOnAudioFocusChangeListener({ _ -> }, android.os.Handler(android.os.Looper.getMainLooper()))
                            .build()
                        service = CraftNativeSounds(activity)
                        for (id in listOf("music", "effect")) {
                            service.play(id, file.toURI().toString(), JSONObject().put("loop", true)) {
                                results.add(it)
                                ready.countDown()
                            }
                        }
                        music = field(sound(service, "music"), "player") as MediaPlayer
                        effect = field(sound(service, "effect"), "player") as MediaPlayer
                    }
                    assertTrue("both real players must prepare", ready.await(10, TimeUnit.SECONDS))
                    scenario.onActivity { results.forEach { assertNull(it.message, it.code) } }
                    awaitState("both sounds must initially play") { music.isPlaying && effect.isPlaying }
                    repeat(2) {
                        scenario.onActivity {
                            assertEquals("competing focus request must be admitted", AudioManager.AUDIOFOCUS_REQUEST_GRANTED,
                                manager.requestAudioFocus(competitor))
                        }
                        awaitState("system focus loss must pause both real players") {
                            !music.isPlaying && !effect.isPlaying && field(sound(service, "music"), "interrupted") == true
                                && field(sound(service, "effect"), "interrupted") == true
                        }
                        scenario.onActivity {
                            assertFalse("manual resume must respect the active system interruption", service.resume("music"))
                            assertTrue(service.pause("effect"))
                            assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, manager.abandonAudioFocusRequest(competitor))
                        }
                        awaitState("system focus gain must resume only the interrupted music") {
                            music.isPlaying && !effect.isPlaying && field(sound(service, "music"), "interrupted") == false
                        }
                        scenario.onActivity {
                            assertSame(music, field(sound(service, "music"), "player"))
                            assertSame(effect, field(sound(service, "effect"), "player"))
                            assertEquals("interruption must not settle the loads again", 2, results.size)
                            assertTrue(service.resume("effect"))
                        }
                        awaitState("an explicitly resumed effect must play") { effect.isPlaying }
                    }
                } finally {
                    scenario.onActivity {
                        try { manager.abandonAudioFocusRequest(competitor) } finally { service.close() }
                    }
                }
            }
        } finally { file.delete() }
    }

    @Test
    fun deniedAudioFocusSettlesOnceAndLeavesNoPlayerBeforeRetry() {
        val file = silentWav()
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                lateinit var service: CraftNativeSounds
                var allowFocus = false
                var refused = 0
                val ready = CountDownLatch(1)
                try {
                    scenario.onActivity { activity ->
                        // Inject only the OS focus decision; use real MediaPlayer
                        // construction, disposal, and the platform focus path on retry.
                        service = CraftNativeSounds(activity) { manager, request ->
                            if (allowFocus) manager.requestAudioFocus(request) else AudioManager.AUDIOFOCUS_REQUEST_FAILED
                        }
                        service.play("tone", file.toURI().toString(), JSONObject()) {
                            assertEquals("AUDIO_FOCUS_DENIED", it.code)
                            refused++
                        }
                        assertEquals(1, refused)
                        assertFalse(service.pause("tone"))
                        allowFocus = true
                        service.play("tone", file.toURI().toString(), JSONObject().put("loop", true)) {
                            assertNull(it.message, it.code)
                            ready.countDown()
                        }
                    }
                    assertTrue("retry must prepare", ready.await(10, TimeUnit.SECONDS))
                    scenario.onActivity {
                        assertEquals(1, refused)
                        assertTrue((field(sound(service), "player") as MediaPlayer).isPlaying)
                    }
                } finally { scenario.onActivity { service.close(); service.close() } }
            }
        } finally { file.delete() }
    }

    @Test
    fun closingOverlappingPreparingSoundsSettlesEveryLoadOnce() {
        val file = silentWav()
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    val service = CraftNativeSounds(activity)
                    val answers = mutableMapOf<String, Int>()
                    try {
                        for (id in listOf("music", "effect")) service.play(id, file.toURI().toString(), JSONObject()) {
                            assertEquals("CANCELLED", it.code)
                            answers[id] = (answers[id] ?: 0) + 1
                        }
                        service.close()
                        service.close()
                        assertEquals(mapOf("music" to 1, "effect" to 1), answers)
                        assertFalse(service.resume("music"))
                        assertFalse(service.resume("effect"))
                    } finally { service.close() }
                }
                instrumentation.waitForIdleSync()
            }
        } finally { file.delete() }
    }

    @Test
    fun invalidReplacementDoesNotCancelAPreparingSound() = invalidReplacementKeepsSound(false)

    @Test
    fun invalidReplacementDoesNotStopAPlayingSound() = invalidReplacementKeepsSound(true)

    private fun invalidReplacementKeepsSound(awaitReady: Boolean) {
        val file = silentWav()
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                // Strings permit non-finite values to reach native validation
                // through valid JSON; JSONObject rejects non-finite Doubles.
                for (options in listOf(
                    JSONObject().put("volume", "NaN"),
                    JSONObject().put("fadeIn", -1),
                    JSONObject().put("fadeIn", "Infinity"),
                )) {
                    lateinit var service: CraftNativeSounds
                    lateinit var original: Any
                    lateinit var cancelOriginal: () -> Unit
                    val results = mutableListOf<CraftNativeCapabilityResult>()
                    val ready = CountDownLatch(1)
                    try {
                        scenario.onActivity { activity ->
                            service = CraftNativeSounds(activity)
                            service.play("tone", file.toURI().toString(), JSONObject().put("loop", true).put("volume", 0.6)) {
                                results.add(it)
                                ready.countDown()
                            }
                            original = sound(service)
                            cancelOriginal = service.cancellation("tone")
                            if (!awaitReady) {
                                assertTrue("readiness must still be pending", results.isEmpty())
                                assertInvalidReplacement(service, file, options, original)
                                assertTrue("invalid replacement cancelled the pending play", results.isEmpty())
                            }
                        }
                        assertTrue("original sound did not prepare", ready.await(10, TimeUnit.SECONDS))
                        scenario.onActivity {
                            assertEquals(1, results.size)
                            assertNull(results.single().message, results.single().code)
                            if (awaitReady) assertInvalidReplacement(service, file, options, original)
                            assertSame(original, sound(service))
                            assertTrue("invalid replacement stopped playback", (field(original, "player") as MediaPlayer).isPlaying)
                            assertEquals(0.6f, outputVolume(service, "tone"), 0.001f)
                            cancelOriginal()
                            assertFalse("the original cancellation must still own the player", service.resume("tone"))
                            assertEquals("late callbacks must not settle the original again", 1, results.size)
                        }
                    } finally { scenario.onActivity { service.close() } }
                }
            }
        } finally { file.delete() }
    }

    private fun assertInvalidReplacement(service: CraftNativeSounds, file: java.io.File, options: JSONObject, original: Any) {
        val rejected = mutableListOf<CraftNativeCapabilityResult>()
        service.play("tone", file.toURI().toString(), options) { rejected.add(it) }
        assertEquals("invalid options must settle once: $options", 1, rejected.size)
        assertEquals("INVALID_ARGUMENT", rejected.single().code)
        val retained = CraftNativeSounds::class.java.getDeclaredField("sounds").apply { isAccessible = true }.get(service) as Map<*, *>
        assertSame("invalid options removed or replaced the existing sound: $options", original, retained["tone"])
    }

    @Test
    fun replacingAPreparingSoundSettlesItAndItsOldCancellationCannotStopTheReplacement() {
        val file = silentWav()
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                lateinit var service: CraftNativeSounds
                val ready = CountDownLatch(1)
                var replacement: CraftNativeCapabilityResult? = null
                var cancelled = 0
                try {
                    scenario.onActivity { activity ->
                        service = CraftNativeSounds(activity)
                        service.play("tone", file.toURI().toString(), JSONObject()) {
                            assertEquals("CANCELLED", it.code)
                            cancelled++
                        }
                        val oldCancel = service.cancellation("tone")
                        service.play("tone", file.toURI().toString(), JSONObject().put("loop", true)) {
                            replacement = it
                            ready.countDown()
                        }
                        assertEquals(1, cancelled)
                        oldCancel()
                    }
                    assertTrue("replacement did not prepare", ready.await(10, TimeUnit.SECONDS))
                    assertNull(replacement?.message, replacement?.code)
                    scenario.onActivity {
                        assertTrue((field(sound(service), "player") as MediaPlayer).isPlaying)
                        assertEquals(1, cancelled)
                    }
                } finally { scenario.onActivity { service.close() } }
            }
        } finally { file.delete() }
    }

    @Test
    fun explicitPauseSurvivesFocusGainAndVolumeChangesStayCurrent() {
        val file = silentWav()
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                lateinit var service: CraftNativeSounds
                val ready = CountDownLatch(1)
                var result: CraftNativeCapabilityResult? = null
                try {
                    scenario.onActivity { activity ->
                        service = CraftNativeSounds(activity)
                        service.play("tone", file.toURI().toString(), JSONObject().put("loop", true).put("volume", 0.8).put("fadeIn", 1000)) {
                            result = it
                            ready.countDown()
                        }
                        assertEquals(0f, field(sound(service), "volume"))
                    }
                    assertTrue("sound did not prepare", ready.await(10, TimeUnit.SECONDS))
                    assertNull(result?.message, result?.code)
                    scenario.onActivity {
                        assertTrue(service.setVolume("tone", 0.25, 0.0))
                        assertEquals(0.25f, field(sound(service), "volume"))
                        focus(service, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
                        focus(service, AudioManager.AUDIOFOCUS_GAIN)
                        assertEquals(0.25f, field(sound(service), "volume"))
                        focus(service, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
                        assertTrue(service.pause("tone"))
                        focus(service, AudioManager.AUDIOFOCUS_GAIN)
                        assertFalse((field(sound(service), "player") as MediaPlayer).isPlaying)
                        assertTrue(service.resume("tone"))
                        assertTrue((field(sound(service), "player") as MediaPlayer).isPlaying)
                    }
                } finally { scenario.onActivity { service.close() } }
            }
        } finally { file.delete() }
    }

    @Test
    fun rejectedSnapshotReplacementPreservesDiskCacheAndTheOtherIsolates() {
        val base = instrumentation.targetContext
        val root = java.io.File(base.cacheDir, "snapshot-replace-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val destination = java.io.File(root, "craft-snapshots/campaign.json").apply {
            check(parentFile!!.mkdirs())
            writeText("{\"tick\":24}")
        }
        val context = object : android.content.ContextWrapper(base) {
            override fun getApplicationContext(): android.content.Context = this
            override fun getFilesDir() = root
        }
        val files = CraftSnapshotFile(replace = { _, _ -> throw java.io.IOException("atomic move refused") })
        val constructor = CraftNativeStores::class.java.getDeclaredConstructor(
            android.content.Context::class.java, Boolean::class.javaPrimitiveType, CraftSnapshotFile::class.java,
        ).apply { isAccessible = true }
        val stores = constructor.newInstance(context, false, files)
        val receiver = "snapshot-test-${UUID.randomUUID()}"
        val complete = CountDownLatch(1)
        val events = mutableListOf<String>()
        var accepted: Boolean? = null
        try {
            assertEquals("{\"tick\":24}", stores.snapshot("campaign"))
            CraftNativeHub.register(receiver) { type, payload ->
                if (type == "SYNC_UPDATE" && payload.optString("store") == "snapshots" && payload.optString("key") == "campaign")
                    events.add(payload.getString("value"))
            }
            stores.setSnapshot("campaign", "{\"tick\":25}", null) {
                accepted = it
                events.add("result:$it")
                complete.countDown()
            }
            assertTrue("snapshot failure did not settle", complete.await(5, TimeUnit.SECONDS))
            assertEquals(false, accepted)
            assertEquals("{\"tick\":24}", destination.readText())
            assertEquals("{\"tick\":24}", stores.snapshot("campaign"))
            assertEquals(listOf("{\"tick\":24}", "result:false"), events)
            assertEquals(listOf("campaign.json"), destination.parentFile!!.listFiles()!!.map { it.name })
        } finally {
            CraftNativeHub.unregister(receiver)
            root.deleteRecursively()
        }
    }

    @Test
    fun secureUuidUsesTheNativePlatformWithoutJavaScriptEntropy() {
        val capabilities = CraftNativeCapabilities(instrumentation.targetContext, JSONObject())
        try {
            assertTrue(capabilities.names().toString().contains("crypto"))
            val first = call(capabilities, "Crypto", "randomUUID").data as String
            val second = call(capabilities, "Crypto", "randomUUID").data as String
            assertEquals(4, UUID.fromString(first).version())
            assertEquals(2, UUID.fromString(first).variant())
            assertFalse(first == second)
        } finally { capabilities.close() }
    }

    @Test
    fun cancelledQueuedStorageWritePreservesThePreviousCheckpoint() {
        val base = instrumentation.targetContext
        val name = "checkpoint-cancel-${UUID.randomUUID()}"
        val values = base.getSharedPreferences(name, android.content.Context.MODE_PRIVATE)
        val context = object : android.content.ContextWrapper(base) {
            override fun getSharedPreferences(key: String, mode: Int) =
                if (key == "craft-native-storage") values else super.getSharedPreferences(key, mode)
        }
        val capabilities = CraftNativeCapabilities(context, JSONObject())
        val answered = java.util.concurrent.atomic.AtomicBoolean(false)
        val token = UUID.randomUUID().toString()
        try {
            assertEquals(true, call(capabilities, "Storage", "set", JSONArray().put("draft").put(JSONObject().put("generation", 1))).data)
            instrumentation.runOnMainSync {
                capabilities.perform(token, CRAFT_NATIVE_CAPABILITY_PROTOCOL_VERSION, "Storage", "set", JSONArray().put("draft").put(JSONObject().put("generation", 2))) { answered.set(true) }
                capabilities.cancel(token)
            }
            instrumentation.waitForIdleSync()
            val restored = call(capabilities, "Storage", "get", JSONArray().put("draft")).data as JSONObject
            assertEquals(1, restored.getInt("generation"))
            assertFalse("Cancelled requests must not acknowledge a checkpoint", answered.get())
        } finally { capabilities.close(); base.deleteSharedPreferences(name) }
    }

    @Test
    fun closingTheNativeHostCancelsItsQueuedCheckpointWrite() {
        val base = instrumentation.targetContext
        val name = "checkpoint-close-${UUID.randomUUID()}"
        val values = base.getSharedPreferences(name, android.content.Context.MODE_PRIVATE)
        val context = object : android.content.ContextWrapper(base) {
            override fun getSharedPreferences(key: String, mode: Int) =
                if (key == "craft-native-storage") values else super.getSharedPreferences(key, mode)
        }
        val capabilities = CraftNativeCapabilities(context, JSONObject())
        val reopened = CraftNativeCapabilities(context, JSONObject())
        val answered = java.util.concurrent.atomic.AtomicBoolean(false)
        try {
            assertEquals(true, call(capabilities, "Storage", "set", JSONArray().put("draft").put(JSONObject().put("generation", 1))).data)
            instrumentation.runOnMainSync {
                capabilities.perform(UUID.randomUUID().toString(), CRAFT_NATIVE_CAPABILITY_PROTOCOL_VERSION, "Storage", "set", JSONArray().put("draft").put(JSONObject().put("generation", 2))) { answered.set(true) }
                capabilities.close()
            }
            instrumentation.waitForIdleSync()
            val restored = call(reopened, "Storage", "get", JSONArray().put("draft")).data as JSONObject
            assertEquals(1, restored.getInt("generation"))
            assertFalse("A closed host must not acknowledge a checkpoint", answered.get())
            assertEquals("HOST_CLOSED", call(capabilities, "Storage", "set", JSONArray().put("draft").put(JSONObject().put("generation", 3))).code)
            assertEquals(1, (call(reopened, "Storage", "get", JSONArray().put("draft")).data as JSONObject).getInt("generation"))
        } finally { capabilities.close(); reopened.close(); base.deleteSharedPreferences(name) }
    }

    @Test
    fun conditionalCheckpointCannotResurrectDeletedDataOrOverwriteFeedback() {
        val base = instrumentation.targetContext
        val name = "cas-test-${UUID.randomUUID()}"
        val values = base.getSharedPreferences(name, android.content.Context.MODE_PRIVATE)
        val context = object : android.content.ContextWrapper(base) {
            override fun getSharedPreferences(key: String, mode: Int) =
                if (key == "craft-native-storage") values else super.getSharedPreferences(key, mode)
        }
        val capabilities = CraftNativeCapabilities(context, JSONObject())
        val old = JSONObject().put("owner", "A").put("feedback", "latest").put("visits", 1)
        val next = JSONObject(old.toString()).put("visits", 2)
        fun cas(expected: Any, value: Any) = call(capabilities, "Storage", "compareAndSet", JSONArray().put("draft").put(expected).put(value))
        try {
            assertTrue(capabilities.names().toString().contains("storageCompareAndSet"))
            assertTrue(capabilities.names().toString().contains("storageSetIfAbsent"))
            assertEquals(false, cas(JSONObject.NULL, next).data)
            assertEquals(true, call(capabilities, "Storage", "setIfAbsent", JSONArray().put("draft").put(old)).data)
            assertEquals(false, call(capabilities, "Storage", "setIfAbsent", JSONArray().put("draft").put(JSONObject().put("owner", "B"))).data)
            assertEquals(false, cas(JSONObject(old.toString()).put("feedback", "stale"), next).data)
            assertEquals(true, cas(JSONObject().put("visits", 1).put("feedback", "latest").put("owner", "A"), next).data)
            assertEquals(true, call(capabilities, "Storage", "remove", JSONArray().put("draft")).data)
            assertEquals(false, cas(next, old).data)
            assertNull(values.getString("draft", null))
            assertEquals(true, call(capabilities, "Storage", "setIfAbsent", JSONArray().put("draft").put(JSONObject.NULL)).data)
            assertEquals(false, call(capabilities, "Storage", "setIfAbsent", JSONArray().put("draft").put(old)).data)
            assertFalse(CraftNativeStorage.jsonEqual(true, 1))
            assertFalse(CraftNativeStorage.jsonEqual(JSONArray().put(1).put(2), JSONArray().put(2).put(1)))
        } finally { capabilities.close(); base.deleteSharedPreferences(name) }
    }

    @Test
    fun aNewIsolateCannotPreloadAnUncommittedCheckpoint() {
        val base = instrumentation.targetContext
        val name = "checkpoint-preload-${UUID.randomUUID()}"
        val root = java.io.File(base.cacheDir, name).apply { check(mkdirs()) }
        val values = base.getSharedPreferences(name, android.content.Context.MODE_PRIVATE)
        check(values.edit().putString("draft", "{\"owner\":\"A\"}").commit())
        val changedMemory = CountDownLatch(1)
        val releaseDisk = CountDownLatch(1)
        val first = java.util.concurrent.atomic.AtomicBoolean(true)
        val preloadReadWasLocked = java.util.concurrent.atomic.AtomicBoolean(false)
        val failing = object : android.content.SharedPreferences by values {
            override fun getAll(): MutableMap<String, *> {
                if (Thread.currentThread().name == "recording-checkpoint-preload")
                    preloadReadWasLocked.set(Thread.holdsLock(CraftNativeStorage.lock))
                return values.all.toMutableMap()
            }
            override fun edit(): android.content.SharedPreferences.Editor {
                val editor = values.edit()
                return object : android.content.SharedPreferences.Editor by editor {
                    override fun commit(): Boolean {
                        editor.commit()
                        if (first.getAndSet(false)) {
                            changedMemory.countDown()
                            check(releaseDisk.await(5, TimeUnit.SECONDS))
                        }
                        return false
                    }
                }
            }
        }
        val context = object : android.content.ContextWrapper(base) {
            override fun getApplicationContext(): android.content.Context = this
            override fun getFilesDir() = root
            override fun getSharedPreferences(key: String, mode: Int) =
                if (key == "craft-native-storage") failing else super.getSharedPreferences(key, mode)
        }
        val constructor = CraftNativeStores::class.java.getDeclaredConstructor(android.content.Context::class.java, Boolean::class.javaPrimitiveType)
        constructor.isAccessible = true
        val stores = constructor.newInstance(context, false)
        val capabilities = CraftNativeCapabilities(context, JSONObject())
        val completed = CountDownLatch(1)
        var answer: CraftNativeCapabilityResult? = null
        val preloaded = CountDownLatch(1)
        var snapshot: JSONObject? = null
        try {
            capabilities.perform(UUID.randomUUID().toString(), CRAFT_NATIVE_CAPABILITY_PROTOCOL_VERSION, "Storage", "set", JSONArray().put("draft").put(JSONObject().put("owner", "B"))) {
                answer = it; completed.countDown()
            }
            assertTrue(changedMemory.await(5, TimeUnit.SECONDS))
            thread(name = "recording-checkpoint-preload") { snapshot = stores.preload(); preloaded.countDown() }
            // A real preload races the production commit/rollback critical section.
            assertFalse(preloaded.await(100, TimeUnit.MILLISECONDS))
            releaseDisk.countDown()
            assertTrue(completed.await(5, TimeUnit.SECONDS))
            assertTrue(preloaded.await(5, TimeUnit.SECONDS))
            assertTrue("Preload must read inside the same commit/rollback boundary", preloadReadWasLocked.get())
            assertEquals("STORAGE_ERROR", answer?.code)
            assertEquals("A", JSONObject(requireNotNull(snapshot).getJSONObject("storage").getString("draft")).getString("owner"))
        } finally {
            releaseDisk.countDown()
            capabilities.close()
            base.deleteSharedPreferences(name)
            root.deleteRecursively()
        }
    }

    @Test
    fun failedStorageCheckpointRestoresMemoryBeforeRejecting() {
        val base = instrumentation.targetContext
        val name = "checkpoint-test-${UUID.randomUUID()}"
        val values = base.getSharedPreferences(name, android.content.Context.MODE_PRIVATE)
        check(values.edit().putString("draft", "{\"owner\":\"A\"}").commit())
        val failing = object : android.content.SharedPreferences by values {
            override fun edit(): android.content.SharedPreferences.Editor {
                val editor = values.edit()
                return object : android.content.SharedPreferences.Editor by editor {
                    override fun commit(): Boolean { editor.commit(); return false }
                }
            }
        }
        val context = object : android.content.ContextWrapper(base) {
            override fun getSharedPreferences(key: String, mode: Int) =
                if (key == "craft-native-storage") failing else super.getSharedPreferences(key, mode)
        }
        val capabilities = CraftNativeCapabilities(context, JSONObject())
        var notifications = 0
        capabilities.storeObserver = { _, _, _ -> notifications += 1 }
        try {
            val result = call(capabilities, "Storage", "set", JSONArray().put("draft").put(JSONObject().put("owner", "B")))
            assertEquals("STORAGE_ERROR", result.code)
            assertEquals(0, notifications)
            val conditional = call(capabilities, "Storage", "compareAndSet", JSONArray().put("draft").put(JSONObject().put("owner", "A")).put(JSONObject().put("owner", "B")))
            assertEquals("STORAGE_ERROR", conditional.code)
            assertEquals(0, notifications)
            val registration = call(capabilities, "Storage", "setIfAbsent", JSONArray().put("new-draft").put(JSONObject().put("owner", "B")))
            assertEquals("STORAGE_ERROR", registration.code)
            assertFalse(values.contains("new-draft"))
            assertEquals(0, notifications)
            val stored = call(capabilities, "Storage", "get", JSONArray().put("draft")).data as JSONObject
            assertEquals("A", stored.getString("owner"))
            assertEquals("{\"owner\":\"A\"}", values.getString("draft", null))
        } finally { capabilities.close(); base.deleteSharedPreferences(name) }
    }

    private fun call(
        capabilities: CraftNativeCapabilities,
        module: String,
        method: String,
        args: JSONArray = JSONArray(),
    ): CraftNativeCapabilityResult {
        val latch = CountDownLatch(1)
        var answer: CraftNativeCapabilityResult? = null
        capabilities.perform(
            UUID.randomUUID().toString(),
            CRAFT_NATIVE_CAPABILITY_PROTOCOL_VERSION,
            module,
            method,
            args,
        ) {
            answer = it
            latch.countDown()
        }
        assertTrue("native capability did not settle", latch.await(10, TimeUnit.SECONDS))
        return requireNotNull(answer)
    }

    @Test
    fun fetchUsesTheSameTextProtocolAsTheIosHost() {
        val server = ServerSocket(0)
        val received = mutableListOf<String>()
        val serving = thread(name = "native-fetch-fixture") {
            server.accept().use { socket ->
                val reader = socket.getInputStream().bufferedReader()
                val lines = mutableListOf<String>()
                while (true) {
                    val line = reader.readLine()
                    if (line.isNullOrEmpty()) break
                    lines += line
                }
                val length = lines.firstOrNull { it.startsWith("Content-Length:", ignoreCase = true) }
                    ?.substringAfter(':')?.trim()?.toIntOrNull() ?: 0
                val body = CharArray(length)
                var offset = 0
                while (offset < length) {
                    val count = reader.read(body, offset, length - offset)
                    if (count < 0) break
                    offset += count
                }
                received += lines.joinToString("\n") + "\n\n" + String(body, 0, offset)
                val response = "{\"activity\":{\"id\":42}}"
                socket.getOutputStream().bufferedWriter().use { writer ->
                    writer.write("HTTP/1.1 201 Created\r\n")
                    writer.write("Content-Type: application/json\r\n")
                    writer.write("X-Native-Test: android\r\n")
                    writer.write("Content-Length: ${response.toByteArray().size}\r\n")
                    writer.write("Connection: close\r\n\r\n")
                    writer.write(response)
                }
            }
        }
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        val capabilities = CraftNativeCapabilities(activity, JSONObject())
        try {
            assertTrue(capabilities.names().toString().contains("fetch"))
            assertEquals("INVALID_ARGUMENT", call(capabilities, "Network", "fetch", JSONArray()
                .put(JSONObject().put("url", "/api/activities"))).code)
            assertEquals("INVALID_ARGUMENT", call(capabilities, "Network", "fetch", JSONArray().put(JSONObject()
                .put("url", "http://127.0.0.1:${server.localPort}/api/activities")
                .put("method", "GET")
                .put("body", "not allowed"))).code)
            assertEquals("INVALID_ARGUMENT", call(capabilities, "Network", "fetch", JSONArray().put(JSONObject()
                .put("url", "http://127.0.0.1:${server.localPort}/api/activities")
                .put("body", 42))).code)
            assertEquals("INVALID_ARGUMENT", call(capabilities, "Network", "fetch", JSONArray().put(JSONObject()
                .put("url", "http://127.0.0.1:${server.localPort}/api/activities")
                .put("headers", JSONObject().put("X-Native-Test", 42)))).code)

            val result = call(capabilities, "Network", "fetch", JSONArray().put(JSONObject()
                .put("url", "http://127.0.0.1:${server.localPort}/api/activities")
                .put("method", "POST")
                .put("headers", JSONObject()
                    .put("Authorization", "Bearer native-token")
                    .put("Content-Type", "application/json"))
                .put("body", "{\"distance\":5}")))
            assertNull(result.code)
            val response = result.data as JSONObject
            assertEquals(201, response.getInt("status"))
            assertEquals("Created", response.getString("statusText"))
            assertEquals("android", response.getJSONObject("headers").getString("x-native-test"))
            assertEquals("{\"activity\":{\"id\":42}}", response.getString("body"))
            serving.join(5_000)
            assertTrue(received.single().contains("authorization: Bearer native-token", ignoreCase = true))
            assertTrue(received.single().endsWith("{\"distance\":5}"))
        }
        finally {
            server.close()
            capabilities.close()
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    private fun importContext(): android.content.ContextWrapper {
        val root = java.io.File(instrumentation.targetContext.cacheDir, "imports-${UUID.randomUUID()}").apply { mkdirs() }
        return object : android.content.ContextWrapper(instrumentation.targetContext) {
            override fun getCacheDir() = root
        }
    }

    private fun copyDocuments(capabilities: CraftNativeCapabilities, token: String, paths: List<String>, limit: Long = 1024 * 1024): CraftNativeCapabilityResult =
        CraftNativeCapabilities::class.java.getDeclaredMethod("copyDocuments", String::class.java, List::class.java, Long::class.javaPrimitiveType)
            .apply { isAccessible = true }.invoke(capabilities, token, paths.map { android.net.Uri.parse("content://dev.craft.navigationtest.imports/$it") }, limit) as CraftNativeCapabilityResult

    @Test
    fun documentImportsCopyBytesAndRollBackDeniedOrOversizedSelections() {
        val context = importContext()
        val capabilities = CraftNativeCapabilities(context, JSONObject())
        val root = java.io.File(context.cacheDir, "craft-files")
        try {
            for (attempt in 1..2) {
                assertEquals("READ_ERROR", copyDocuments(capabilities, "denied-$attempt", listOf("ok", "denied")).code)
                assertTrue("a denied selection must roll back earlier copies", root.listFiles().isNullOrEmpty())
                assertEquals("FILE_TOO_LARGE", copyDocuments(capabilities, "oversize-$attempt", listOf("ok"), 1024).code)
                assertTrue("oversized imports must remove staging directories", root.listFiles().isNullOrEmpty())
            }
            val result = copyDocuments(capabilities, "retry", listOf("ok"))
            assertNull(result.message, result.code)
            val descriptor = (result.data as JSONArray).getJSONObject(0)
            val file = java.io.File(descriptor.getString("path"))
            assertTrue(NativeImportProvider.bytes.contentEquals(file.readBytes()))
            assertEquals("application/gpx+xml", descriptor.getString("type"))
            assertNull(call(capabilities, "Files", "remove", JSONArray().put(file.path)).code)
            assertFalse(file.exists())
        } finally {
            capabilities.close()
            context.cacheDir.deleteRecursively()
        }
    }

    @Test
    fun cancelledAndClosedDocumentCopiesRemovePartialImports() {
        for (close in listOf(false, true)) {
            val context = importContext()
            val capabilities = CraftNativeCapabilities(context, JSONObject())
            NativeImportProvider.reset()
            val done = CountDownLatch(1)
            var result: CraftNativeCapabilityResult? = null
            val worker = thread(name = "native-import-copy") {
                try { result = copyDocuments(capabilities, "blocked", listOf("blocked")) }
                finally { done.countDown() }
            }
            try {
                assertTrue("provider never began copying", NativeImportProvider.started.await(5, TimeUnit.SECONDS))
                if (close) capabilities.close() else capabilities.cancel("blocked")
                NativeImportProvider.release.countDown()
                assertTrue("copy did not settle", done.await(5, TimeUnit.SECONDS))
                assertEquals("CANCELLED", result?.code)
                assertTrue(java.io.File(context.cacheDir, "craft-files").listFiles().isNullOrEmpty())
            } finally {
                NativeImportProvider.release.countDown()
                worker.join(5_000)
                capabilities.close()
                context.cacheDir.deleteRecursively()
            }
        }
    }

    @Test
    fun cancelledAndClosedFileRepliesDiscardUndeliveredOwnedFiles() {
        for (close in listOf(false, true)) {
            val context = importContext()
            val capabilities = CraftNativeCapabilities(context, JSONObject())
            val root = java.io.File(context.cacheDir, "craft-files")
            val replies = java.util.concurrent.atomic.AtomicInteger()
            try {
                // Hold the delivery queue until the real worker has created its file.
                instrumentation.runOnMainSync {
                    capabilities.perform("late-file", 1, "Files", "write", JSONArray().put("late.txt").put("payload")) { replies.incrementAndGet() }
                    val deadline = android.os.SystemClock.uptimeMillis() + 5_000
                    while (root.walkTopDown().none { it.isFile } && android.os.SystemClock.uptimeMillis() < deadline) android.os.SystemClock.sleep(10)
                    assertTrue("write worker never created its file", root.walkTopDown().any { it.isFile })
                    if (close) capabilities.close() else capabilities.cancel("late-file")
                }
                val deadline = android.os.SystemClock.uptimeMillis() + 5_000
                while (!root.listFiles().isNullOrEmpty() && android.os.SystemClock.uptimeMillis() < deadline) {
                    instrumentation.waitForIdleSync()
                    android.os.SystemClock.sleep(10)
                }
                assertEquals("cancelled replies must not reach a disposed screen", 0, replies.get())
                assertTrue("undelivered file and staging directory must be deleted", root.listFiles().isNullOrEmpty())
            } finally {
                capabilities.close()
                context.cacheDir.deleteRecursively()
            }
        }
    }

    @Test
    fun fileRemovalPrunesOnlyEmptyParentsAndRejectsDirectories() {
        val context = importContext()
        val capabilities = CraftNativeCapabilities(context, JSONObject())
        val root = java.io.File(context.cacheDir, "craft-files")
        try {
            val written = call(capabilities, "Files", "write", JSONArray().put("owned.txt").put("payload"))
            assertNull(written.message, written.code)
            val file = java.io.File((written.data as JSONObject).getString("path"))
            val parent = file.parentFile!!
            val sibling = java.io.File(parent, "keep.txt").apply { writeText("keep") }
            assertEquals(true, call(capabilities, "Files", "remove", JSONArray().put(file.path)).data)
            assertEquals("keep", sibling.readText())
            assertEquals(false, call(capabilities, "Files", "remove", JSONArray().put(file.path)).data)
            assertEquals(true, call(capabilities, "Files", "remove", JSONArray().put(sibling.path)).data)
            assertFalse("the last file must not leave its empty staging directory", parent.exists())
            assertTrue("the shared root must survive", root.isDirectory)

            val directory = java.io.File(root, "directory").apply { mkdirs() }
            assertEquals(false, call(capabilities, "Files", "remove", JSONArray().put(directory.path)).data)
            assertTrue("files.remove is not a directory remover", directory.isDirectory)
        } finally { capabilities.close(); context.cacheDir.deleteRecursively() }
    }

    @Test
    fun cancelledFileDeliveryPreservesSiblingsAndSharedRoot() {
        for (close in listOf(false, true)) {
            for (nested in listOf(false, true)) {
                val context = importContext()
                val capabilities = CraftNativeCapabilities(context, JSONObject())
                val root = java.io.File(context.cacheDir, "craft-files").apply { mkdirs() }
                val parent = if (nested) java.io.File(root, UUID.randomUUID().toString()).apply { mkdirs() } else root
                val file = java.io.File(parent, "undelivered.txt").apply { writeText("discard") }
                val sibling = java.io.File(parent, "delivered.txt").apply { writeText("keep") }
                val other = java.io.File(root, "other/content.txt").apply { parentFile!!.mkdirs(); writeText("other") }
                val replies = java.util.concurrent.atomic.AtomicInteger()
                try {
                    // Exercise the delivery boundary with actual files, after
                    // ownership has transferred from the copy worker.
                    instrumentation.runOnMainSync {
                        if (close) capabilities.close() else capabilities.cancel("discard")
                        val completion: (CraftNativeCapabilityResult) -> Unit = { replies.incrementAndGet() }
                        CraftNativeCapabilities::class.java.getDeclaredMethod("completeFile", String::class.java,
                            CraftNativeCapabilityResult::class.java, kotlin.jvm.functions.Function1::class.java)
                            .apply { isAccessible = true }.invoke(capabilities, "discard",
                                CraftNativeCapabilityResult(data = JSONObject().put("path", file.path)), completion)
                    }
                    instrumentation.waitForIdleSync()
                    assertEquals(0, replies.get())
                    assertFalse("undelivered file must be removed", file.exists())
                    assertTrue("cleanup must preserve a delivered sibling", sibling.isFile)
                    assertTrue("cleanup must preserve other imports", other.isFile)
                    assertTrue("cleanup must preserve the shared root", root.isDirectory)
                } finally { capabilities.close(); instrumentation.waitForIdleSync(); context.cacheDir.deleteRecursively() }
            }
        }
    }

    @Test
    fun fileRemovalReportsPermissionDenialAndAllowsRetry() {
        val context = importContext()
        val capabilities = CraftNativeCapabilities(context, JSONObject())
        val root = java.io.File(context.cacheDir, "craft-files").apply { mkdirs() }
        val parent = java.io.File(root, UUID.randomUUID().toString()).apply { mkdirs() }
        val file = java.io.File(parent, "denied.txt").apply { writeText("keep") }
        try {
            android.system.Os.chmod(parent.path, 0b101000000) // owner read/execute, no write
            assertEquals(false, call(capabilities, "Files", "remove", JSONArray().put(file.path)).data)
            assertEquals("keep", file.readText())
            android.system.Os.chmod(parent.path, 0b111000000)
            assertEquals(true, call(capabilities, "Files", "remove", JSONArray().put(file.path)).data)
            assertFalse(parent.exists())
        } finally {
            if (parent.exists()) android.system.Os.chmod(parent.path, 0b111000000)
            capabilities.close(); context.cacheDir.deleteRecursively()
        }
    }

    @Test
    fun nativeFilesStayOwnedAndUploadAsMultipart() {
        val server = ServerSocket(0)
        val errorServer = ServerSocket(0)
        var received = ""
        val serving = thread(name = "native-upload-fixture") {
            server.accept().use { socket ->
                val reader = socket.getInputStream().bufferedReader()
                val lines = mutableListOf<String>()
                while (true) {
                    val line = reader.readLine()
                    if (line.isNullOrEmpty()) break
                    lines += line
                }
                val length = lines.firstOrNull { it.startsWith("Content-Length:", ignoreCase = true) }
                    ?.substringAfter(':')?.trim()?.toIntOrNull() ?: 0
                val body = CharArray(length)
                var offset = 0
                while (offset < length) {
                    val count = reader.read(body, offset, length - offset)
                    if (count < 0) break
                    offset += count
                }
                received = lines.joinToString("\n") + "\n\n" + String(body, 0, offset)
                socket.getOutputStream().bufferedWriter().use { writer ->
                    writer.write("HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                }
            }
        }
        val errorServing = thread(name = "native-download-error-fixture") {
            errorServer.accept().use { socket ->
                socket.getInputStream().bufferedReader().readLine()
                socket.getOutputStream().bufferedWriter().use { writer ->
                    writer.write("HTTP/1.1 404 Not Found\r\nContent-Length: 7\r\nConnection: close\r\n\r\nmissing")
                }
            }
        }
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        val capabilities = CraftNativeCapabilities(activity, JSONObject())
        try {
            assertTrue(capabilities.names().toString().contains("files"))
            val file = call(capabilities, "Files", "write", JSONArray()
                .put("photo.txt")
                .put("photo bytes")
                .put(JSONObject().put("type", "text/plain"))).data as JSONObject
            assertTrue(file.getString("path").contains("craft-files"))
            assertEquals("INVALID_ARGUMENT", call(capabilities, "Files", "remove", JSONArray().put("/tmp/not-owned.txt")).code)
            assertEquals("INVALID_ARGUMENT", call(capabilities, "Files", "write", JSONArray()
                .put("invalid.txt")
                .put("data")
                .put(JSONObject().put("encoding", "hex"))).code)
            assertEquals("INVALID_ARGUMENT", call(capabilities, "Files", "download", JSONArray().put("file:///tmp/not-http" )).code)

            val result = call(capabilities, "Network", "fetch", JSONArray().put(JSONObject()
                .put("url", "http://127.0.0.1:${server.localPort}/upload")
                .put("method", "POST")
                .put("form", JSONArray()
                    .put(JSONObject().put("name", "caption").put("value", "native"))
                    .put(JSONObject().put("name", "photo").put("path", file.getString("path")).put("filename", "photo.txt").put("type", "text/plain")))))
            assertNull(result.code)
            assertEquals(201, (result.data as JSONObject).getInt("status"))
            serving.join(5_000)
            assertTrue(received.contains("name=\"caption\""))
            assertTrue(received.contains("name=\"photo\"; filename=\"photo.txt\""))
            assertTrue(received.contains("photo bytes"))
            val refused = call(capabilities, "Files", "download", JSONArray()
                .put("http://127.0.0.1:${errorServer.localPort}/missing"))
            assertNull(refused.code)
            assertFalse((refused.data as JSONObject).getBoolean("ok"))
            assertEquals(404, (refused.data as JSONObject).getInt("status"))
            assertEquals("missing", (refused.data as JSONObject).getString("body"))
            errorServing.join(5_000)
        }
        finally {
            server.close()
            errorServer.close()
            capabilities.close()
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test
    fun persistsStorageAndCommittedDatabaseTransactionsAcrossHosts() {
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ) as MainActivity
        val config = JSONObject()
            .put("enableLocalDatabase", true)
            .put("enableDeepLinks", true)
            .put("enableLocalNotifications", true)
            .put("enableSecureStorage", true)
            .put("enableBiometric", true)
        var capabilities = CraftNativeCapabilities(activity, config)
        try {
            call(capabilities, "Storage", "clear")
            assertNull(call(capabilities, "Storage", "set", JSONArray()
                .put("profile").put(JSONObject().put("name", "Ada").put("visits", 2))).code)
            assertEquals("INVALID_ARGUMENT", call(capabilities, "Storage", "set", JSONArray()
                .put("invalid").put(Any())).code)
            capabilities.close()
            capabilities = CraftNativeCapabilities(activity, config)
            val profile = call(capabilities, "Storage", "get", JSONArray().put("profile")).data as JSONObject
            assertEquals("Ada", profile.getString("name"))
            assertEquals(2, profile.getInt("visits"))

            assertNull(call(capabilities, "SecureStorage", "clear").code)
            assertNull(call(capabilities, "SecureStorage", "set", JSONArray().put("secret").put("keychain-value")).code)
            assertEquals("keychain-value", call(capabilities, "SecureStorage", "get", JSONArray().put("secret")).data)
            assertNull(call(capabilities, "SecureStorage", "remove", JSONArray().put("secret")).code)
            assertEquals(JSONObject.NULL, call(capabilities, "SecureStorage", "get", JSONArray().put("secret")).data)
            assertNull(call(capabilities, "Biometrics", "isAvailable").code)
            assertNull(call(capabilities, "Biometrics", "getBiometricType").code)

            val table = "capability_${UUID.randomUUID().toString().replace("-", "")}"
            assertNull(call(capabilities, "Database", "execute", JSONArray()
                .put("CREATE TABLE $table (id INTEGER PRIMARY KEY, name TEXT NOT NULL)").put(JSONArray())).code)
            assertNull(call(capabilities, "Database", "beginTransaction").code)
            assertNull(call(capabilities, "Database", "execute", JSONArray()
                .put("INSERT INTO $table (name) VALUES (?)").put(JSONArray().put("Grace"))).code)
            assertNull(call(capabilities, "Database", "commit").code)
            capabilities.close()
            capabilities = CraftNativeCapabilities(activity, config)
            val rows = call(capabilities, "Database", "query", JSONArray()
                .put("SELECT name FROM $table").put(JSONArray())).data as JSONArray
            assertEquals("Grace", rows.getJSONObject(0).getString("name"))
        }
        finally {
            capabilities.close()
            instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            instrumentation.waitForIdleSync()
        }
    }
}
