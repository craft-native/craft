import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { runKotlinFixture } from './testing'

/**
 * `craft.files.download` on Android answers as the other hosts do, and leaves
 * nothing behind when it fails.
 *
 * Four things, each found by reading the three hosts side by side:
 *
 * - **A finished download did not say it had finished.** The contract is that
 *   a refused download resolves `{ ok: false, status, body }`, so a screen
 *   tells the two apart with `result.ok`. UIKit and the browser host answer
 *   `{ …file, ok: true, status }`. Android answered the bare file, so
 *   `if (!result.ok)` took every successful download for a refusal.
 * - **The server's name for the file was ignored.** UIKit uses
 *   `Content-Disposition` and then the address; Android used the address's
 *   last segment exactly as written, percent signs included, so
 *   `My%20Report.csv` was the file's name.
 * - **A name longer than the disk allows failed the download.** 255 bytes is
 *   the limit, and a percent-encoded name reaches it at 28 Japanese
 *   characters. UIKit cuts a long name to fit.
 * - **A download that failed part-way left its bytes on disk.** A dropped
 *   connection, a timeout and a cancellation each returned from inside the
 *   copy with the partial file still there, in a folder nothing pointed at,
 *   until the daily sweep. UIKit only ever moves a complete body into place.
 *
 * The functions under test are the shipped ones, lifted out of the template
 * by name and run on a JVM against a real `HttpURLConnection` and a socket
 * server that can stop half-way through a body or keep one arriving. Only the members the functions
 * reach for — the folder, the cancelled set, the two result constructors — are
 * supplied by the fixture.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeCapabilities.kt.template'), 'utf8')

/** One member function of the capabilities class, as shipped. */
function lift(name: string): string {
  const lines = template.split('\n')
  const start = lines.findIndex(line => line.startsWith(`    private fun ${name}(`))
  expect(start, `${name} must still be a member of CraftNativeCapabilities`).toBeGreaterThan(0)
  const body = [lines[start]!]
  for (let at = start + 1; at < lines.length; at += 1) {
    const line = lines[at]!
    // A deeper line belongs to the function, whichever kind of body it has,
    // and so does a blank line with more of the body after it.
    if (line.startsWith('        ') || (line === '' && lines[at + 1]?.startsWith('        '))) { body.push(line); continue }
    // The end of a signature that ran over several lines.
    if (line.startsWith('    )')) { body.push(line); continue }
    // A block body ends on its own brace; an expression body just stops.
    if (line === '    }') body.push(line)
    break
  }
  return body.join('\n')
}

const lifted = ['download', 'refusedDownload', 'downloadName', 'percentDecoded', 'removePartial', 'descriptor', 'safeFileName', 'validURL', 'success', 'failure']

const fixture = `
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

internal data class CraftNativeCapabilityResult(val data: Any? = null, val code: String? = null, val message: String? = null)
private const val CRAFT_NATIVE_FETCH_TIMEOUT_MS = 5_000
private const val CRAFT_NATIVE_FILE_ERROR_BODY_BYTES = 64 * 1024

internal class Files(val fileRoot: File) {
    val cancelled: MutableSet<String> = ConcurrentHashMap.newKeySet<String>()
    val fetchConnections = ConcurrentHashMap<String, HttpURLConnection>()

${lifted.map(lift).join('\n\n')}

    fun run(token: String, address: String, options: JSONObject? = null): CraftNativeCapabilityResult =
        download(token, JSONArray().put(address).apply { if (options != null) put(options) })

    /** What the host's own cancel does for a download. */
    fun cancel(token: String) { cancelled.add(token); fetchConnections.remove(token)?.disconnect() }
}

/** Answers each path as the scenario needs, a dropped or stalled body included. */
class Server {
    private val socket = ServerSocket(0)
    val port: Int get() = socket.localPort
    val arriving = CountDownLatch(1)
    private val release = CountDownLatch(1)
    private val chunk = ByteArray(5_000) { 'x'.code.toByte() }

    init {
        thread(isDaemon = true) {
            while (true) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                thread(isDaemon = true) {
                    runCatching {
                        client.use {
                            val reader = it.getInputStream().bufferedReader()
                            val path = reader.readLine().split(" ")[1]
                            while (reader.readLine().isNotEmpty()) { /* headers */ }
                            val out = it.getOutputStream()
                            fun head(status: String, length: Int, extra: String = "") =
                                out.write(("HTTP/1.1 " + status + "\\r\\nContent-Length: " + length + "\\r\\nConnection: close\\r\\n" + extra + "\\r\\n").toByteArray())
                            when {
                                path == "/named" -> { head("200 OK", 3, "Content-Type: application/pdf\\r\\nContent-Disposition: attachment; filename=\\"quarterly report.pdf\\"\\r\\n"); out.write("pdf".toByteArray()) }
                                path == "/star" -> { head("200 OK", 3, "Content-Disposition: attachment; filename=\\"fallback.txt\\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf\\r\\n"); out.write("pdf".toByteArray()) }
                                path == "/missing" -> { head("404 Not Found", 7); out.write("missing".toByteArray()) }
                                path == "/dropped" -> { head("200 OK", 100_000); out.write(chunk); out.flush() }
                                // Keeps arriving, slowly, until the test is done with it.
                                path == "/arriving" -> {
                                    head("200 OK", 10_000_000); out.write(chunk); out.flush(); arriving.countDown()
                                    while (!release.await(20, TimeUnit.MILLISECONDS)) { out.write(chunk, 0, 100); out.flush() }
                                }
                                else -> { head("200 OK", 8, "Content-Type: text/csv\\r\\n"); out.write("a,b\\n1,2\\n".toByteArray()) }
                            }
                            out.flush()
                        }
                    }
                }
            }
        }
    }

    fun close() { release.countDown(); socket.close() }
}

fun must(condition: Boolean, message: () -> String) { if (!condition) throw AssertionError(message()) }

fun main() {
    val root = File(System.getProperty("java.io.tmpdir"), "craft-files-" + UUID.randomUUID()).apply { mkdirs() }
    val server = Server()
    val files = Files(root)
    val base = "http://127.0.0.1:" + server.port
    fun leftovers(): List<String> = root.walk().filter { it != root }.map { it.relativeTo(root).path }.toList()
    fun finished(result: CraftNativeCapabilityResult, label: String): JSONObject {
        must(result.code == null) { label + " failed with " + result.code + ": " + result.message }
        return result.data as JSONObject
    }
    try {
        // A finished download says so, and the file is the address's last
        // segment as a person would read it.
        val plain = finished(files.run("plain", base + "/exports/My%20Report.csv"), "a plain download")
        must(plain.opt("ok") == true) { "a finished download answered ok=" + plain.opt("ok") + ", so a screen cannot tell it from a refusal" }
        must(plain.opt("status") == 200) { "a finished download answered status=" + plain.opt("status") }
        must(plain.getString("name") == "My Report.csv") { "the address's name was kept as written: " + plain.getString("name") }
        must(File(plain.getString("path")).readText() == "a,b\\n1,2\\n") { "the body did not reach the file" }
        must(plain.getLong("size") == 8L) { "size was " + plain.getLong("size") }

        // The server's name for it wins over the address, and the name the
        // screen asked for wins over both.
        val named = finished(files.run("named", base + "/named"), "a named download")
        must(named.getString("name") == "quarterly report.pdf") { "Content-Disposition was ignored: " + named.getString("name") }
        val star = finished(files.run("star", base + "/star"), "an encoded name")
        must(star.getString("name") == "r\\u00e9sum\\u00e9.pdf") { "filename* was ignored: " + star.getString("name") }
        val asked = finished(files.run("asked", base + "/named", JSONObject().put("name", "mine.pdf")), "a download with a name")
        must(asked.getString("name") == "mine.pdf") { "the name that was asked for lost to the server's: " + asked.getString("name") }

        // Forty Japanese characters are 360 once percent-encoded, past the
        // 255 bytes a file name may be.
        val title = "\\u65e5\\u672c\\u8a9e\\u306e\\u8cc7\\u6599".repeat(8)
        val encoded = finished(files.run("encoded", base + "/" + URLEncoder.encode(title, "UTF-8") + ".pdf"), "a long encoded name")
        must(encoded.getString("name") == title + ".pdf") { "the encoded name was not decoded: " + encoded.getString("name") }

        // A name too long for the disk is cut to fit and keeps its extension.
        val long = finished(files.run("long", base + "/" + "a".repeat(300) + ".pdf"), "a name longer than the disk allows")
        must(long.getString("name").toByteArray().size <= 255) { "the name is " + long.getString("name").toByteArray().size + " bytes" }
        must(long.getString("name").endsWith(".pdf")) { "the extension was cut off: " + long.getString("name").takeLast(12) }
        val wide = finished(files.run("wide", base + "/x", JSONObject().put("name", "\\u6f22".repeat(200) + ".csv")), "a wide name")
        must(wide.getString("name").toByteArray().size <= 255) { "the wide name is " + wide.getString("name").toByteArray().size + " bytes" }
        must(wide.getString("name").endsWith(".csv")) { "the wide name lost its extension" }
        must(File(wide.getString("path")).isFile) { "the wide name was not written" }

        // A name that is only dots is no name: it is the folder itself.
        val dots = finished(files.run("dots", base + "/x", JSONObject().put("name", "..")), "a name of dots")
        must(File(dots.getString("path")).isFile && File(dots.getString("path")).parentFile.parentFile.canonicalFile == root.canonicalFile) { "a name of dots escaped its folder: " + dots.getString("path") }

        // A refusal is still an answer, and keeps no file.
        root.listFiles()?.forEach { it.deleteRecursively() }
        val refused = finished(files.run("refused", base + "/missing"), "a refused download")
        must(refused.opt("ok") == false && refused.opt("status") == 404 && refused.opt("body") == "missing") { "a refusal answered " + refused }
        must(leftovers().isEmpty()) { "a refusal left " + leftovers() }

        // The connection drops part-way: an error, and nothing on disk.
        val dropped = files.run("dropped", base + "/dropped")
        must(dropped.code == "NETWORK_ERROR") { "a dropped body answered " + dropped.code + " " + dropped.data }
        must(leftovers().isEmpty()) { "a dropped download left " + leftovers() + " on disk" }

        // Cancelled while the body is arriving: the same. The body keeps
        // coming rather than stalling, because what a cancel does to a read
        // that is blocked is the platform's business: Android's connection
        // fails it at once, the JDK's waits for it. A read that returns is
        // the same on both.
        var cancelledResult: CraftNativeCapabilityResult? = null
        val running = thread { cancelledResult = files.run("arriving", base + "/arriving") }
        must(server.arriving.await(10, TimeUnit.SECONDS)) { "the body never started arriving" }
        val deadline = System.currentTimeMillis() + 5_000
        while (root.walk().none { it.isFile && it.length() > 0 } && System.currentTimeMillis() < deadline) Thread.sleep(10)
        must(root.walk().any { it.isFile && it.length() > 0 }) { "no bytes reached the disk before the cancel, so the cancel would prove nothing" }
        files.cancel("arriving")
        running.join(10_000)
        must(!running.isAlive) { "the cancelled download never returned" }
        must(cancelledResult?.code == "CANCELLED") { "a cancelled download answered " + cancelledResult?.code }
        must(leftovers().isEmpty()) { "a cancelled download left " + leftovers() + " on disk" }
        println("download fixture passed")
    } finally {
        server.close()
        root.deleteRecursively()
    }
}
`

test('a download answers as the other hosts do and leaves nothing behind when it fails', async () => {
  await runKotlinFixture(fixture, ['org.json:json:20240303'])
}, 300_000)
