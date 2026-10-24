package dev.craft.navigationtest

import android.content.Intent
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
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeCapabilitiesTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

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
