package dev.craft.navigationtest

import android.content.Context
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * #565: a biometric credential read behind a real `BiometricPrompt`, with the
 * emulator's virtual fingerprint sensor.
 *
 * It needs an emulator with a PIN and fingerprint 1 enrolled, and the
 * emulator console's port and auth token as the instrumentation argument
 * `craftEmulatorConsole=<port>:<token>`, which the test uses to touch the
 * sensor (`finger touch <id>`) from inside the guest through 10.0.2.2. Without
 * either it is skipped, as on CI's emulator, which has no fingerprint.
 * `NativeCapabilitiesTest.aBiometricCredentialIsNeverKeptWithoutAnEnrolledBiometric`
 * covers that case.
 *
 * How it was run (API 35 emulator, 2026-11-25):
 * 1. `adb shell locksettings set-pin 1234`, then enrol fingerprint 1 in
 *    Settings (`am start -a android.settings.FINGERPRINT_ENROLL`), touching
 *    the sensor with `adb emu finger touch 1` until it says "Fingerprint added".
 * 2. Generate the fixture with `CRAFT_ANDROID_DEVICE_TESTS=1` (this file is
 *    left out otherwise: it skips on CI, whose suite allows no skips).
 *    Install both APKs once and run with `adb shell am instrument -e class …
 *    -e craftEmulatorConsole 5558:$(cat ~/.emulator_console_auth_token)`.
 *    Gradle's connected task uninstalls the app after each run, which would
 *    take the stored credential with it before the second test.
 * 3. Enrol another fingerprint (`finger touch 3`), then run
 *    [aNewFingerprintInvalidatesTheCredential] with `-e craftBiometricEnrolledAgain 1`.
 *
 * `adb shell dumpsys fingerprint` counts the decisions: the first test adds
 * one `rejectCrypto` (the unenrolled finger) and one `acceptCrypto`.
 */
@RunWith(AndroidJUnit4::class)
class NativeBiometricPromptTest {
    private companion object {
        /** Enrol fingers 1, 2, …; this one never is. */
        const val UNENROLLED_FINGER = 9
    }

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val arguments = InstrumentationRegistry.getArguments()

    private class Pending {
        val latch = CountDownLatch(1)
        @Volatile var result: CraftNativeCapabilityResult? = null
        fun await(seconds: Long): CraftNativeCapabilityResult? = if (latch.await(seconds, TimeUnit.SECONDS)) result else null
    }

    private fun start(host: CraftNativeCapabilities, method: String, args: JSONArray): Pending {
        val pending = Pending()
        host.perform(UUID.randomUUID().toString(), CRAFT_NATIVE_CAPABILITY_PROTOCOL_VERSION, "Biometrics", method, args) {
            pending.result = it
            pending.latch.countDown()
        }
        return pending
    }

    private fun call(host: CraftNativeCapabilities, method: String, args: JSONArray): CraftNativeCapabilityResult =
        requireNotNull(start(host, method, args).await(10)) { "Biometrics.$method did not settle" }

    /** The emulator console, reached from the guest: `finger touch <id>` is a sensor touch. */
    private fun touch(finger: Int) {
        val (port, token) = requireNotNull(arguments.getString("craftEmulatorConsole")).split(":", limit = 2)
        Socket().use { socket ->
            socket.connect(InetSocketAddress("10.0.2.2", port.toInt()), 5_000)
            socket.soTimeout = 5_000
            val reader = socket.getInputStream().bufferedReader()
            val writer = socket.getOutputStream().bufferedWriter()
            fun answer(): String {
                val lines = mutableListOf<String>()
                while (true) {
                    val line = reader.readLine() ?: error("the emulator console closed: $lines")
                    lines += line
                    if (line == "OK") return lines.joinToString("\n")
                    if (line.startsWith("KO")) error("the emulator console refused: $lines")
                }
            }
            answer()
            for (command in listOf("auth $token", "finger touch $finger")) {
                writer.write(command + "\n")
                writer.flush()
                answer()
            }
        }
    }

    private fun enrolledHost(scenario: ActivityScenario<MainActivity>): CraftNativeCapabilities {
        assumeTrue("needs craftEmulatorConsole=<port>:<token>", arguments.getString("craftEmulatorConsole") != null)
        assumeTrue("needs an enrolled fingerprint", CraftBiometricVault.available(instrumentation.targetContext))
        lateinit var host: CraftNativeCapabilities
        scenario.onActivity { host = CraftNativeCapabilities(it, JSONObject().put("enableBiometric", true)) }
        return host
    }

    private fun vault() = instrumentation.targetContext.getSharedPreferences("craft-biometric-vault", Context.MODE_PRIVATE)

    @Test
    fun aCredentialIsReleasedOnlyToTheEnrolledFingerAndACancelReleasesNothing() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            val host = enrolledHost(scenario)
            try {
                vault().edit().clear().commit()
                assertEquals(true, call(host, "storeCredential", JSONArray().put("session").put("secret-token")).data)
                assertEquals(true, call(host, "hasCredential", JSONArray().put("session")).data)
                assertTrue("only ciphertext is kept", vault().all.values.none { it.toString().contains("secret-token") })

                val read = start(host, "getCredential", JSONArray().put("session").put("Unlock the session"))
                Thread.sleep(2_000)
                touch(UNENROLLED_FINGER)
                assertEquals("a finger that is not enrolled releases nothing, and the prompt stays", null, read.await(2))
                var value: CraftNativeCapabilityResult? = null
                for (attempt in 1..5) {
                    touch(1)
                    value = read.await(4)
                    if (value != null) break
                }
                assertEquals(null, value?.code)
                assertEquals("secret-token", value?.data)

                val cancelled = start(host, "getCredential", JSONArray().put("session").put("Unlock the session"))
                Thread.sleep(2_000)
                instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_BACK").close()
                assertEquals("AUTHENTICATION_CANCELLED", cancelled.await(10)?.code)
                assertEquals("a cancel forgets nothing", true, call(host, "hasCredential", JSONArray().put("session")).data)
            } finally { host.close() }
        }
    }

    /**
     * Run after the test above and after enrolling another fingerprint
     * (`craftBiometricEnrolledAgain=1`): the key was invalidated with the new
     * enrolment, so the credential is gone without a prompt, as on iOS.
     */
    @Test
    fun aNewFingerprintInvalidatesTheCredential() {
        assumeTrue("needs craftBiometricEnrolledAgain=1", arguments.getString("craftBiometricEnrolledAgain") == "1")
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            val host = enrolledHost(scenario)
            try {
                assertTrue("the first test left a credential", vault().all.isNotEmpty())
                val read = call(host, "getCredential", JSONArray().put("session").put("Unlock the session"))
                assertEquals(null, read.code)
                assertEquals(JSONObject.NULL, read.data)
                assertEquals(false, call(host, "hasCredential", JSONArray().put("session")).data)
                assertFalse("the invalidated value is removed", vault().all.isNotEmpty())
            } finally { host.close() }
        }
    }
}
