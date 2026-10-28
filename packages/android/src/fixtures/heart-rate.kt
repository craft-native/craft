// Runs after CraftHeartRateCore.kt.template (src/heart-rate.test.ts): the
// 0x2A37 decoder, the stand-in strap and the recording kept on disk, against
// the vectors and cases of iOS's HeartRateUnitTests.swift.

import java.io.File
import java.nio.file.Files
import kotlin.math.abs
import kotlin.math.sqrt

/** org.json stands in for this on a phone; the JVM has none, so a small codec. */
internal object FixtureJson : CraftHeartRateJson {
    override fun encode(value: Any?): String = when (value) {
        null -> "null"
        is String -> "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        is Boolean, is Int, is Long -> value.toString()
        is Double -> if (value == Math.floor(value) && abs(value) < 1e15) value.toLong().toString() else value.toString()
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") { encode(it.key.toString()) + ":" + encode(it.value) }
        is List<*> -> value.joinToString(",", "[", "]") { encode(it) }
        else -> error("Cannot encode ${value::class}")
    }

    override fun decode(text: String): Any? {
        var at = 0
        fun space() { while (at < text.length && text[at].isWhitespace()) at++ }
        fun value(): Any? {
            space()
            val c = text[at]
            return when {
                c == '{' -> {
                    at++
                    val map = linkedMapOf<String, Any?>()
                    space()
                    if (text[at] == '}') { at++; return map }
                    while (true) {
                        val key = value() as String
                        space(); check(text[at++] == ':')
                        map[key] = value()
                        space()
                        if (text[at++] == '}') break
                    }
                    map
                }
                c == '[' -> {
                    at++
                    val list = mutableListOf<Any?>()
                    space()
                    if (text[at] == ']') { at++; return list }
                    while (true) {
                        list.add(value())
                        space()
                        if (text[at++] == ']') break
                    }
                    list
                }
                c == '"' -> {
                    at++
                    val out = StringBuilder()
                    while (text[at] != '"') {
                        if (text[at] == '\\') at++
                        out.append(text[at++])
                    }
                    at++
                    out.toString()
                }
                text.startsWith("true", at) -> { at += 4; true }
                text.startsWith("false", at) -> { at += 5; false }
                text.startsWith("null", at) -> { at += 4; null }
                else -> {
                    val start = at
                    while (at < text.length && (text[at].isDigit() || text[at] in "+-.eE")) at++
                    val number = text.substring(start, at)
                    number.toLongOrNull() ?: number.toDouble()
                }
            }
        }
        return value()
    }
}

fun bytes(vararg values: Int) = IntArray(values.size) { values[it] }

fun expectCode(code: String, label: String, run: () -> Unit) {
    try {
        run()
    } catch (error: CraftHeartRateException) {
        check(error.code == code) { "$label: expected $code, got ${error.code} (${error.message})" }
        return
    }
    error("$label: expected $code, got an answer")
}

fun directory(): File = Files.createTempDirectory("craft-heart-rate-").toFile()

internal fun recorder(directory: File, writer: (ByteArray, File) -> Unit = ::craftHeartRateWriteAtomically) =
    CraftHeartRateRecording(directory, FixtureJson, { 1_800_000_000_000L }, writer)

@Suppress("UNCHECKED_CAST")
fun map(value: Any?) = value as Map<String, Any?>

@Suppress("UNCHECKED_CAST")
fun list(value: Any?) = value as List<Map<String, Any?>>

fun measurements() {
    // A uint8 rate with nothing else.
    check(CraftHeartRateMeasurement.parse(bytes(0x00, 72)) == CraftHeartRateMeasurement(72, null, null, emptyList()))
    // A uint16 rate.
    check(CraftHeartRateMeasurement.parse(bytes(0x01, 0x2C, 0x01))?.bpm == 300)
    // Sensor contact only when the strap reports it.
    check(CraftHeartRateMeasurement.parse(bytes(0x06, 80))?.sensorContact == true)
    check(CraftHeartRateMeasurement.parse(bytes(0x04, 80))?.sensorContact == false)
    check(CraftHeartRateMeasurement.parse(bytes(0x02, 80))?.sensorContact == null)
    // 150 bpm, 258 kJ, RR 1024/1024 s and 512/1024 s, in milliseconds.
    val reading = CraftHeartRateMeasurement.parse(bytes(0x18, 150, 0x02, 0x01, 0x00, 0x04, 0x00, 0x02))
    check(reading?.bpm == 150)
    check(reading?.energyExpended == 258)
    check(reading?.rrIntervals == listOf(1000.0, 500.0)) { "RR intervals: ${reading?.rrIntervals}" }
    // A trailing odd byte is not half an interval.
    check(CraftHeartRateMeasurement.parse(bytes(0x10, 60, 0x00, 0x04, 0x01))?.rrIntervals == listOf(1000.0))
    // A payload shorter than its flags say is no reading.
    check(CraftHeartRateMeasurement.parse(IntArray(0)) == null)
    check(CraftHeartRateMeasurement.parse(bytes(0x01, 0x2C)) == null)
    check(CraftHeartRateMeasurement.parse(bytes(0x08, 60, 0x01)) == null)
    // Bytes as Android hands them over: signed.
    check(CraftHeartRateMeasurement.parse(byteArrayOf(0x00, 0xC8.toByte()))?.bpm == 200)
    // The stand-in's payloads decode like a strap's.
    val simulated = CraftHeartRateMeasurement.parse(CraftHeartRateMeasurement.encode(142, sensorContact = true, rrIntervals = listOf(422.5)))
    check(simulated?.bpm == 142)
    check(simulated?.sensorContact == true)
    check(abs((simulated?.rrIntervals?.first() ?: 0.0) - 422.5) <= 1)
    check(CraftHeartRateMeasurement.parse(CraftHeartRateMeasurement.encode(260))?.bpm == 260)
    check(CraftHeartRateMeasurement.parse(CraftHeartRateMeasurement.encode(90, sensorContact = null, energyExpended = 12))
        == CraftHeartRateMeasurement(90, null, 12, emptyList()))
}

fun simulatedBeats() {
    val (intervals, reached) = craftHeartRateSimulatedIntervals(60.0, 0.0, 30_000.0) { 0.0 }
    check(reached >= 30_000)
    check(abs(intervals.sum() - reached) < 0.001)
    // About a second apart at 60 bpm, closer on the in-breath and wider on the out-breath.
    check(abs(intervals.average() - 1000) <= 15) { "mean ${intervals.average()}" }
    val spread = intervals.max() - intervals.min()
    check(spread > 50 && spread < 90) { "spread $spread" }
    // Successive beats differ, so RMSSD is not zero.
    val squares = intervals.zipWithNext { a, b -> (b - a) * (b - a) }
    check(sqrt(squares.average()) > 5)
}

fun decisions() {
    // A healthy subscription is kept; a connected link quiet for 20 s is rebuilt.
    check(!craftHeartRateShouldRestart("connected", true, 20_000))
    check(craftHeartRateShouldRestart("connected", true, 20_001))
    // A link that came up but never subscribed: after 30 s.
    check(!craftHeartRateShouldRestart("connecting", true, 30_000))
    check(craftHeartRateShouldRestart("reconnecting", true, 31_000))
    // A pending connection waits for the strap however long it takes.
    check(!craftHeartRateShouldRestart("reconnecting", false, 600_000))
    check((0..8).map(::craftHeartRateReconnectDelayMs) == listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 30_000L, 30_000L, 30_000L, 30_000L))
    check(craftHeartRateReconnectDelayMs(-3) == 1_000L)
    check(craftHeartRateAuthorizationName(granted = true, asked = false) == "authorized")
    check(craftHeartRateAuthorizationName(granted = false, asked = false) == "notDetermined")
    check(craftHeartRateAuthorizationName(granted = false, asked = true) == "denied")
    check(craftHeartRateBluetoothName(false, null, "authorized") == "unsupported")
    check(craftHeartRateBluetoothName(true, 12, "denied") == "unauthorized")
    check(craftHeartRateBluetoothName(true, 12, "notDetermined") == "poweredOn")
    check(craftHeartRateBluetoothName(true, 10, "authorized") == "poweredOff")
    check(craftHeartRateBluetoothName(true, 11, "authorized") == "resetting")
    check(craftHeartRateBluetoothName(true, 13, "authorized") == "resetting")
    check(craftHeartRateBluetoothName(true, null, "authorized") == "unknown")
}

fun ultraRecordingContinuesAfterRelaunch() {
    val dir = directory()
    try {
        val first = recorder(dir)
        val id = map(first.perform("startRecording", emptyMap()))["id"] as String
        File(dir, "craft-heart-rate-recording.jsonl").writeText("{\"timestamp\":1000,\"bpm\":140}\n".repeat(100_800))
        val restored = recorder(dir)
        check(map(restored.perform("getRecordingState", mapOf("expectedId" to id)))["sampleCount"] == 100_800)
        check(restored.append(mapOf("timestamp" to 100_801_000L, "bpm" to 151))) { "a 28-hour ultra must continue saving heart rate" }
        val finished = map(restored.perform("stopRecording", mapOf("expectedId" to id)))
        val samples = list(finished["samples"])
        check(samples.size == 100_801 && samples.last()["bpm"] == 151L)
    } finally { dir.deleteRecursively() }
}

fun startingAgainPreservesTheActiveRecording() {
    val dir = directory()
    val first = recorder(dir)
    val id = map(first.perform("startRecording", emptyMap()))["id"] as String
    val samples = "{\"timestamp\":1000,\"bpm\":140}\n"
    val file = File(dir, "craft-heart-rate-recording.jsonl")
    file.writeText(samples)
    // Restore through the disk reader, as after a relaunch.
    val restored = recorder(dir)
    expectCode("RECORDING_ALREADY_ACTIVE", "second start") { restored.perform("startRecording", emptyMap()) }
    val state = map(restored.perform("getRecordingState", emptyMap()))
    check(state["id"] == id && state["active"] == true && state["sampleCount"] == 1) { "state $state" }
    check(file.readText() == samples)
    dir.deleteRecursively()
}

fun staleIdentityCannotTouchAnotherRecording() {
    val dir = directory()
    val monitor = recorder(dir)
    val oldId = map(monitor.perform("startRecording", emptyMap()))["id"] as String
    monitor.perform("stopRecording", mapOf("expectedId" to oldId))
    val newId = map(monitor.perform("startRecording", emptyMap()))["id"] as String
    check(oldId != newId)
    val samples = "{\"timestamp\":2000,\"bpm\":150}\n"
    val file = File(dir, "craft-heart-rate-recording.jsonl")
    file.writeText(samples)
    val restored = recorder(dir)
    for (method in listOf("pauseRecording", "resumeRecording")) {
        expectCode("RECORDING_CONFLICT", method) { restored.perform(method, mapOf("expectedId" to oldId)) }
        val state = map(restored.perform("getRecordingState", emptyMap()))
        check(state["id"] == newId && state["active"] == true && state["paused"] == false) { "$method: $state" }
        check(file.readText() == samples)
    }
    restored.perform("pauseRecording", mapOf("expectedId" to newId))
    check(!restored.append(mapOf("timestamp" to 2500L, "bpm" to 151)))
    restored.perform("resumeRecording", mapOf("expectedId" to newId))
    check(list(restored.perform("readRecording", mapOf("expectedId" to newId))).first()["bpm"] == 150L)
    val stopped = map(restored.perform("stopRecording", mapOf("expectedId" to newId)))
    check(stopped["id"] == newId && stopped["active"] == false && list(stopped["samples"]).size == 1) { "stopped $stopped" }
    check(file.readText() == samples)
    val completed = recorder(dir)
    val recovered = map(completed.perform("getRecordingState", emptyMap()))
    check(recovered["id"] == newId && recovered["active"] == false)
    check(list(map(completed.perform("stopRecording", mapOf("expectedId" to newId)))["samples"]).size == 1)
    completed.perform("startRecording", emptyMap())
    // The old one was archived by the start and still reads back.
    check(list(completed.perform("readRecording", mapOf("expectedId" to newId))).size == 1)
    dir.deleteRecursively()
}

fun plannedIdentityAndSamples() {
    val dir = directory()
    val monitor = recorder(dir)
    expectCode("INVALID_ARGUMENT", "blank recordingId") { monitor.perform("startRecording", mapOf("recordingId" to " ")) }
    expectCode("INVALID_ARGUMENT", "acknowledge without expectedId") { monitor.perform("acknowledgeRecording", emptyMap()) }
    expectCode("NO_ACTIVE_RECORDING", "pause with nothing running") { monitor.perform("pauseRecording", emptyMap()) }
    val started = map(monitor.perform("startRecording", mapOf("recordingId" to "planned")))
    check(started["id"] == "planned" && started["startedAt"] == 1_800_000_000_000L && started["sampleCount"] == 0) { "started $started" }
    check(monitor.append(mapOf("timestamp" to 1000L, "bpm" to 140, "rr" to listOf(428.7, 431.2))))
    check(monitor.append(mapOf("timestamp" to 2000L, "bpm" to 141)))
    val since = list(monitor.perform("readRecording", mapOf("since" to 1000L)))
    check(since.size == 1 && since.first()["timestamp"] == 2000L) { "since $since" }
    expectCode("RECORDING_CONFLICT", "stale read") { monitor.perform("readRecording", mapOf("expectedId" to "other")) }
    expectCode("INVALID_ARGUMENT", "blank expectedId") { monitor.perform("getRecordingState", mapOf("expectedId" to "")) }
    expectCode("RECORDING_ALREADY_ACTIVE", "acknowledge a running one") { monitor.perform("acknowledgeRecording", mapOf("expectedId" to "planned")) }
    val stopped = map(monitor.perform("stopRecording", mapOf("expectedId" to "planned")))
    check(list(stopped["samples"]).first()["rr"] == listOf(428.7, 431.2)) { "rr ${stopped["samples"]}" }
    // An ID is never used twice, even after its recording ended.
    expectCode("RECORDING_CONFLICT", "reused ID") { monitor.perform("startRecording", mapOf("recordingId" to "planned")) }
    check(monitor.perform("acknowledgeRecording", mapOf("expectedId" to "planned")) == true)
    check(!File(dir, "craft-heart-rate-recording.jsonl").exists())
    expectCode("RECORDING_CONFLICT", "reused acknowledged ID") { recorder(dir).perform("startRecording", mapOf("recordingId" to "planned")) }
    expectCode("RECORDING_CONFLICT", "unknown acknowledgement") { monitor.perform("acknowledgeRecording", mapOf("expectedId" to "never")) }
    dir.deleteRecursively()
}

fun completedOwnerSurvivesAnotherStartUntilAcknowledged() {
    val dir = directory()
    val first = recorder(dir)
    val a = map(first.perform("startRecording", emptyMap()))["id"] as String
    val file = File(dir, "craft-heart-rate-recording.jsonl")
    file.writeText("{\"timestamp\":1000,\"bpm\":140}\n")
    first.perform("stopRecording", mapOf("expectedId" to a))
    // The app dies before it durably checkpoints A's stop response.
    val second = recorder(dir)
    val b = map(second.perform("startRecording", emptyMap()))["id"] as String
    check(a != b)
    val dataB = "{\"timestamp\":2000,\"bpm\":170}\n"
    file.writeText(dataB)
    val restored = recorder(dir)
    val stateA = map(restored.perform("getRecordingState", mapOf("expectedId" to a)))
    check(stateA["id"] == a && stateA["active"] == false && !stateA.containsKey("samples")) { "A $stateA" }
    check(list(restored.perform("readRecording", mapOf("expectedId" to a))).first()["bpm"] == 140L)
    check(map(restored.perform("stopRecording", mapOf("expectedId" to a)))["id"] == a)
    check(file.readText() == dataB)
    for (method in listOf("pauseRecording", "resumeRecording")) {
        expectCode("RECORDING_CONFLICT", "stale owner $method") { restored.perform(method, mapOf("expectedId" to a)) }
    }
    check(restored.perform("acknowledgeRecording", mapOf("expectedId" to a)) == true)
    check(restored.perform("acknowledgeRecording", mapOf("expectedId" to a)) == true)
    expectCode("RECORDING_NOT_FOUND", "acknowledged data reappeared") { restored.perform("readRecording", mapOf("expectedId" to a)) }
    check(map(restored.perform("getRecordingState", mapOf("expectedId" to b)))["active"] == true)
    check(file.readText() == dataB)
    dir.deleteRecursively()
}

fun archiveFailureRefusesReplacement() {
    val dir = directory()
    val id = "a-recording"
    File(dir, "craft-heart-rate-recording-state.json").writeText("{\"id\":\"$id\",\"active\":false,\"paused\":false,\"startedAt\":1000}")
    val samples = "{\"timestamp\":1000,\"bpm\":140}\n"
    val file = File(dir, "craft-heart-rate-recording.jsonl")
    file.writeText(samples)
    // A real failed archive write, rather than a successful empty backup.
    val failing = recorder(dir) { _, _ -> throw java.io.IOException("No space left on device") }
    expectCode("RECORDING_STORAGE_ERROR", "replacement ignored archive failure") { failing.perform("startRecording", emptyMap()) }
    check(file.readText() == samples)
    val state = map(failing.perform("getRecordingState", emptyMap()))
    check(state["id"] == id && state["active"] == false)
    // The archive's own name taken by a directory fails the same way.
    val digest = java.security.MessageDigest.getInstance("SHA-256").digest(id.toByteArray()).joinToString("") { "%02x".format(it) }
    File(dir, "craft-heart-rate-completed-$digest.json").mkdirs()
    expectCode("RECORDING_STORAGE_ERROR", "unreadable archive") { recorder(dir).perform("startRecording", emptyMap()) }
    check(file.readText() == samples)
    dir.deleteRecursively()
}

fun missingMetadataIsAnError() {
    val dir = directory()
    File(dir, "craft-heart-rate-recording.jsonl").writeText("{\"timestamp\":1000,\"bpm\":140}\n")
    expectCode("RECORDING_STORAGE_ERROR", "samples without state") { recorder(dir).perform("getRecordingState", emptyMap()) }
    dir.deleteRecursively()
}

fun main() {
    ultraRecordingContinuesAfterRelaunch()
    measurements()
    simulatedBeats()
    decisions()
    startingAgainPreservesTheActiveRecording()
    staleIdentityCannotTouchAnotherRecording()
    plannedIdentityAndSamples()
    completedOwnerSurvivesAnotherStartUntilAcknowledged()
    archiveFailureRefusesReplacement()
    missingMetadataIsAnError()
    println("Android heart rate: parser, stand-in, reconnect and recording passed")
}
