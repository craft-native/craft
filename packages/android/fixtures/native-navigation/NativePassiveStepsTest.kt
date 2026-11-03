package dev.craft.navigationtest

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Instant

@RunWith(AndroidJUnit4::class)
class NativePassiveStepsTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun dailyTotalsReplaceDuplicatesAndPersistWithoutSummingTheSameDay() {
        context.getSharedPreferences("craft-passive-steps", 0).edit().clear().commit()
        val store = CraftPassiveStepStore(context)
        val midnight = Instant.parse("2026-11-01T00:00:00Z").toEpochMilli()
        try {
            assertFalse(store.save(10, midnight, midnight + 1000, "UTC"))
            assertTrue(store.setEnabled(true))
            assertTrue(store.save(10, midnight, midnight + 1000, "UTC"))
            assertTrue(store.save(20, midnight, midnight + 2000, "UTC"))
            assertFalse(store.save(5, midnight, midnight + 500, "UTC"))
            val reopened = CraftPassiveStepStore(context)
            assertEquals(1, reopened.history().length())
            val value = reopened.history().getJSONObject(0)
            assertEquals("daily", value.getString("kind"))
            assertEquals("healthServices", value.getString("source"))
            assertEquals(20, value.getInt("steps"))
            assertEquals(midnight, value.getLong("startDate"))
            store.setEnabled(false)
            assertFalse(reopened.save(30, midnight, midnight + 3000, "UTC"))
            assertEquals(20, reopened.history().getJSONObject(0).getInt("steps"))
        } finally { context.getSharedPreferences("craft-passive-steps", 0).edit().clear().commit() }
    }

    @Test fun aDailyIntervalEndingAtMidnightDoesNotOverwriteTheNextDay() {
        context.getSharedPreferences("craft-passive-steps", 0).edit().clear().commit()
        val store = CraftPassiveStepStore(context)
        val start = Instant.parse("2026-11-01T00:00:00Z").toEpochMilli()
        val midnight = start + 86_400_000
        try {
            store.setEnabled(true)
            assertTrue(store.save(9000, start, midnight, "UTC"))
            assertTrue(store.save(10, midnight, midnight + 1000, "UTC"))
            assertEquals(2, store.history().length())
            assertEquals("2026-11-01", store.history().getJSONObject(0).getString("day"))
            assertEquals(9000, store.history().getJSONObject(0).getInt("steps"))
            assertEquals("2026-11-02", store.history().getJSONObject(1).getString("day"))
        } finally { context.getSharedPreferences("craft-passive-steps", 0).edit().clear().commit() }
    }

    @Test fun historyIsBoundedAndRejectsMalformedMeasurements() {
        context.getSharedPreferences("craft-passive-steps", 0).edit().clear().commit()
        val store = CraftPassiveStepStore(context)
        try {
            store.setEnabled(true)
            val midnight = Instant.parse("2026-10-01T00:00:00Z").toEpochMilli()
            for (day in 0 until 12) {
                val start = midnight + day * 86_400_000L
                assertTrue(store.save(day.toLong(), start, start + 1000, "UTC"))
            }
            assertEquals(8, store.history().length())
            assertEquals(4, store.history().getJSONObject(0).getInt("steps"))
            assertFalse(store.save(-1, 0, 100, "UTC"))
            assertFalse(store.save(1, 100, 0, "UTC"))
            assertEquals(8, store.history().length())
        } finally { context.getSharedPreferences("craft-passive-steps", 0).edit().clear().commit() }
    }

    private class Provider : CraftPassiveStepProvider {
        var available = true
        var failStart = false
        var starts = 0
        var stops = 0
        override fun supported() = available
        override fun start() { starts++; if (failStart) throw IllegalStateException("temporary provider failure") }
        override fun stop() { stops++ }
    }
    private fun call(host: CraftPassiveSteps, method: String): CraftNativeCapabilityResult {
        val latch = java.util.concurrent.CountDownLatch(1)
        var result: CraftNativeCapabilityResult? = null
        host.perform(method) { result = it; latch.countDown() }
        assertTrue(latch.await(5, java.util.concurrent.TimeUnit.SECONDS))
        return requireNotNull(result)
    }

    @Test fun restorationRetriesTransientFailureButDoesNotReviveStoppedCollection() {
        context.getSharedPreferences("craft-passive-steps", 0).edit().clear().commit()
        val store = CraftPassiveStepStore(context)
        val provider = Provider()
        val host = CraftPassiveSteps(context, provider, { true })
        try {
            assertNull(call(host, "restore").code)
            assertEquals(0, provider.starts)
            assertNull(call(host, "start").code)
            assertTrue(store.enabled())
            provider.failStart = true
            assertEquals("UNAVAILABLE", call(host, "restore").code)
            assertTrue("a reboot retry must retain the user's collection intent", store.enabled())
            provider.failStart = false
            assertNull(call(host, "restore").code)
            assertNull(call(host, "stop").code)
            val starts = provider.starts
            assertNull(call(host, "restore").code)
            assertEquals(starts, provider.starts)
            assertFalse(store.enabled())
        } finally { store.setEnabled(false) }
    }

    @Test fun absentProviderOrDeniedPermissionNeverRegistersPassiveCollection() {
        context.getSharedPreferences("craft-passive-steps", 0).edit().clear().commit()
        val provider = Provider()
        val denied = CraftPassiveSteps(context, provider, { false })
        assertEquals("PERMISSION_DENIED", call(denied, "start").code)
        provider.available = false
        val missing = CraftPassiveSteps(context, provider, { true })
        assertEquals("UNAVAILABLE", call(missing, "start").code)
        assertEquals(0, provider.starts)
        assertFalse(CraftPassiveStepStore(context).enabled())
    }

    @Test fun serviceBindingRequiresTheHealthServicesSignaturePermission() {
        val name = android.content.ComponentName(context, CraftPassiveStepsService::class.java)
        val service = context.packageManager.getServiceInfo(name, 0)
        assertTrue(service.exported)
        assertEquals("com.google.android.wearable.healthservices.permission.PASSIVE_DATA_BINDING", service.permission)
        val receiver = context.packageManager.getReceiverInfo(android.content.ComponentName(context, CraftPassiveStepsBootReceiver::class.java), 0)
        assertTrue(receiver.exported)
    }
}
