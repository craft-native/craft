package dev.craft.navigationtest

import android.graphics.BitmapFactory
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * #595: files.exportVideo on Android. The sources are clips as a phone hands
 * them over, written by AVFoundation: 3840x2160 HEVC under a 90° rotation,
 * 60 fps, AAC, with a GPS tag and a device make. sdr-portrait.mov is 8-bit
 * BT.709; hdr-portrait.mov is Main10 HLG BT.2020.
 */
@RunWith(AndroidJUnit4::class)
class NativeVideoExportTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val root = File(context.cacheDir, "craft-files")
    private val enabled = JSONObject().put("enableVideoExport", true)

    // The cache is shared with the other test classes in this APK, which leave
    // their own files in it; each test here starts from an empty one.
    @Before fun empty() { root.deleteRecursively() }
    @After fun clean() { root.deleteRecursively() }

    private fun clip(name: String = "IMG_0001.MOV", asset: String = "sdr-portrait.mov"): File {
        val file = File(root, UUID.randomUUID().toString()).apply { mkdirs() }.resolve(name)
        instrumentation.context.assets.open(asset).use { input -> file.outputStream().use { input.copyTo(it) } }
        return file
    }

    private fun ownedFiles(): List<File> = root.walkTopDown().filter { it.isFile }.toList()

    private class Run(val token: String) {
        val done = CountDownLatch(1)
        var result: CraftNativeCapabilityResult? = null
        val progress: MutableList<JSONObject> = Collections.synchronizedList(mutableListOf())
    }

    private fun start(capabilities: CraftNativeCapabilities, source: File, options: JSONObject): Run {
        val run = Run("export-${UUID.randomUUID()}")
        instrumentation.runOnMainSync {
            capabilities.perform(run.token, 1, "Files", "exportVideo", JSONArray().put(JSONObject().put("path", source.path)).put(options),
                completion = { run.result = it; run.done.countDown() },
                onUploadProgress = { run.progress.add(it) })
        }
        return run
    }

    /** Top-level MP4 atom names in order. */
    private fun atoms(file: File): List<String> {
        val bytes = file.readBytes()
        val names = mutableListOf<String>()
        var offset = 0
        while (offset + 8 <= bytes.size) {
            var size = ((bytes[offset].toLong() and 0xff) shl 24) or ((bytes[offset + 1].toLong() and 0xff) shl 16) or
                ((bytes[offset + 2].toLong() and 0xff) shl 8) or (bytes[offset + 3].toLong() and 0xff)
            names += String(bytes, offset + 4, 4, Charsets.ISO_8859_1)
            if (size == 1L) size = (0 until 8).fold(0L) { value, index -> (value shl 8) or (bytes[offset + 8 + index].toLong() and 0xff) }
            if (size < 8) break
            offset += size.toInt()
        }
        return names
    }

    private fun contains(haystack: ByteArray, needle: String): Boolean {
        val target = needle.toByteArray(Charsets.UTF_8)
        outer@ for (start in 0..haystack.size - target.size) {
            for (index in target.indices) if (haystack[start + index] != target[index]) continue@outer
            return true
        }
        return false
    }

    @Test fun aPhonesPortraitClipExportsAsAnUprightH264MP4AndPoster() {
        val capabilities = CraftNativeCapabilities(context, enabled)
        try {
            assertTrue(capabilities.names().toString().contains("\"videoExport\""))
            val source = clip()
            val original = source.readBytes()
            val run = start(capabilities, source, JSONObject().put("progressId", "clip"))
            assertTrue("the export did not settle", run.done.await(240, TimeUnit.SECONDS))
            val result = run.result!!
            assertNull("${result.code}: ${result.message}", result.code)
            val data = result.data as JSONObject
            val video = data.getJSONObject("video")
            val output = File(video.getString("path"))
            assertTrue(output.path, output.name == "IMG_0001.mp4")
            assertEquals("video/mp4", video.getString("type"))
            assertEquals(720, data.getInt("width"))
            assertEquals(1280, data.getInt("height"))
            assertEquals("60 fps capped at 30", 30.0, data.getDouble("frameRate"), 1.5)
            assertEquals(1.0, data.getDouble("duration"), 0.15)
            assertEquals("measured from the written file", output.length(), data.getLong("bytes"))
            assertArrayEquals("the original is untouched", original, source.readBytes())

            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(output.path)
                assertEquals("the rotation is in the pixels", "0", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) ?: "0")
                assertEquals("720", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH))
                assertEquals("1280", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT))
                assertNull("no location", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION))
            } finally { retriever.release() }

            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(output.path)
                val formats = (0 until extractor.trackCount).map(extractor::getTrackFormat)
                val videoFormat = formats.first { it.getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
                assertEquals(MediaFormat.MIMETYPE_VIDEO_AVC, videoFormat.getString(MediaFormat.KEY_MIME))
                assertEquals("audio/mp4a-latm", formats.first { it.getString(MediaFormat.KEY_MIME)!!.startsWith("audio/") }.getString(MediaFormat.KEY_MIME))
                // High where the device's H.264 encoder has it (phones do; the
                // emulator's software encoder offers only Baseline).
                val high = android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
                val encoderHasHigh = android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS).codecInfos
                    .filter { it.isEncoder && MediaFormat.MIMETYPE_VIDEO_AVC in it.supportedTypes }
                    .any { info -> info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).profileLevels.any { it.profile == high } }
                if (encoderHasHigh && videoFormat.containsKey(MediaFormat.KEY_PROFILE)) {
                    assertEquals("H.264 High", high, videoFormat.getInteger(MediaFormat.KEY_PROFILE))
                }
                assertTrue("BT.709 colour is tagged", videoFormat.containsKey(MediaFormat.KEY_COLOR_STANDARD))
                assertEquals(MediaFormat.COLOR_STANDARD_BT709, videoFormat.getInteger(MediaFormat.KEY_COLOR_STANDARD))
                assertEquals("tone-mapped, not tagged HLG", MediaFormat.COLOR_TRANSFER_SDR_VIDEO, videoFormat.getInteger(MediaFormat.KEY_COLOR_TRANSFER))
            } finally { extractor.release() }

            val bytes = output.readBytes()
            for (marker in listOf("+37.7749", "CraftTestPhone", "©xyz", "ISO6709")) assertFalse("$marker was copied into the export", contains(bytes, marker))
            val order = atoms(output)
            assertTrue("faststart: $order", order.indexOf("moov") in 0 until order.indexOf("mdat"))

            val poster = data.getJSONObject("poster")
            assertEquals("image/jpeg", poster.getString("type"))
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(poster.getString("path"), bounds)
            assertEquals(720, bounds.outWidth)
            assertEquals(1280, bounds.outHeight)

            val fractions = run.progress.map {
                assertEquals("FILES_EXPORT_PROGRESS", it.optString("_event"))
                assertEquals("clip", it.optString("id"))
                it.getDouble("progress")
            }
            assertEquals(1.0, fractions.last(), 0.0)
            assertEquals("progress only goes forward", fractions.sorted(), fractions)
        } finally { capabilities.close() }
    }

    /**
     * An HLG clip is tone-mapped to BT.709 SDR, or, on a device that can't
     * (OpenGL needs GL ES 3 with EXT_YUV_target, MediaCodec needs a decoder
     * that tone-maps; the emulator has neither), rejected with EXPORT_FAILED
     * and nothing kept. Never an MP4 still tagged HDR.
     */
    @Test fun anHDRClipIsToneMappedOrRefusedNeverPassedOnAsHDR() {
        val capabilities = CraftNativeCapabilities(context, enabled)
        try {
            val source = clip("IMG_0002.MOV", "hdr-portrait.mov")
            val run = start(capabilities, source, JSONObject())
            assertTrue("the export did not settle", run.done.await(240, TimeUnit.SECONDS))
            val result = run.result!!
            if (result.code != null) {
                android.util.Log.i("NativeVideoExportTest", "HDR export refused on this device: ${result.code}: ${result.message}")
                assertEquals(result.message, "EXPORT_FAILED", result.code)
                assertTrue(result.message, result.message!!.contains("tone-map"))
                assertTrue("nothing half-written is kept", ownedFiles().none { it.extension == "mp4" || it.extension == "jpg" })
                return
            }
            val output = File((result.data as JSONObject).getJSONObject("video").getString("path"))
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(output.path)
                val format = (0 until extractor.trackCount).map(extractor::getTrackFormat).first { it.getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
                assertEquals(MediaFormat.COLOR_STANDARD_BT709, format.getInteger(MediaFormat.KEY_COLOR_STANDARD))
                assertEquals("tone-mapped, not tagged HLG", MediaFormat.COLOR_TRANSFER_SDR_VIDEO, format.getInteger(MediaFormat.KEY_COLOR_TRANSFER))
            } finally { extractor.release() }
        } finally { capabilities.close() }
    }

    @Test fun aCancelledVideoExportKeepsNoFiles() {
        val capabilities = CraftNativeCapabilities(context, enabled)
        try {
            val source = clip("long.mov")
            val run = start(capabilities, source, JSONObject().put("progressId", "c"))
            val deadline = android.os.SystemClock.uptimeMillis() + 120_000
            while (run.progress.isEmpty() && run.done.count > 0 && android.os.SystemClock.uptimeMillis() < deadline) Thread.sleep(20)
            assertTrue("the export never got under way", run.progress.isNotEmpty())
            capabilities.cancel(run.token)
            val gone = android.os.SystemClock.uptimeMillis() + 30_000
            while (ownedFiles() != listOf(source) && android.os.SystemClock.uptimeMillis() < gone) Thread.sleep(50)
            instrumentation.waitForIdleSync()
            assertEquals("only the original is left", listOf(source), ownedFiles())
            assertFalse("a cancelled request is answered by the cancel, not twice", run.done.await(500, TimeUnit.MILLISECONDS))
        } finally { capabilities.close() }
    }

    @Test fun aVideoExportRefusesWhatItCannotUseAndNeedsItsSwitch() {
        val disabled = CraftNativeCapabilities(context, JSONObject())
        try {
            assertFalse(disabled.names().toString().contains("\"videoExport\""))
            val off = start(disabled, clip(), JSONObject())
            assertTrue(off.done.await(10, TimeUnit.SECONDS))
            assertEquals("CAPABILITY_DISABLED", off.result?.code)
        } finally { disabled.close() }
        val capabilities = CraftNativeCapabilities(context, enabled)
        try {
            val outside = start(capabilities, File(context.filesDir, "elsewhere.mov").apply { writeText("x") }, JSONObject())
            assertTrue(outside.done.await(10, TimeUnit.SECONDS))
            assertEquals("INVALID_ARGUMENT", outside.result?.code)
            val text = File(root, UUID.randomUUID().toString()).apply { mkdirs() }.resolve("notes.mov").apply { writeText("not a movie") }
            val unreadable = start(capabilities, text, JSONObject())
            assertTrue(unreadable.done.await(30, TimeUnit.SECONDS))
            assertEquals("UNSUPPORTED_SOURCE", unreadable.result?.code)
            assertTrue("no half-written export is left", ownedFiles().none { it.extension == "mp4" || it.extension == "jpg" })
            val badOptions = start(capabilities, text, JSONObject().put("fps", 0))
            assertTrue(badOptions.done.await(10, TimeUnit.SECONDS))
            assertEquals("INVALID_ARGUMENT", badOptions.result?.code)
            assertNotNull(CraftVideoExportOptions.parse(JSONObject().put("maxBox", JSONArray().put(1280).put(720))).first)
            assertEquals(720 to 1280, CraftVideoExportOptions.fittedSize(2160, 3840, 1280 to 720))
            assertEquals(640 to 360, CraftVideoExportOptions.fittedSize(640, 360, 1280 to 720))
            assertEquals(1278 to 720, CraftVideoExportOptions.fittedSize(1919, 1081, 1280 to 720))
            assertEquals(1_200_000, CraftVideoExportOptions.targetBitrate(3_000_000, 1_200_000))
        } finally { capabilities.close(); File(context.filesDir, "elsewhere.mov").delete() }
    }
}
