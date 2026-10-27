package dev.craft.navigationtest

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

// Debug-only provider: exercise ContentResolver streams, denial and cancellation
// without automating the system picker or reading any user documents.
class NativeImportProvider : ContentProvider() {
    companion object {
        val bytes = ByteArray(128 * 1024 + 17) { (it % 251).toByte() }
        @Volatile var started = CountDownLatch(1)
        @Volatile var release = CountDownLatch(1)
        fun reset() {
            started = CountDownLatch(1)
            release = CountDownLatch(1)
        }
    }

    override fun onCreate() = true
    override fun getType(uri: Uri) = "application/gpx+xml"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply {
            addRow(columns.map { if (it == OpenableColumns.DISPLAY_NAME) "route.gpx" else bytes.size })
        }
    }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (uri.lastPathSegment == "denied") throw SecurityException("Fixture denies document access")
        val pipe = ParcelFileDescriptor.createPipe()
        val ready = started
        val resume = release
        thread(name = "native-import-provider") {
            runCatching {
                ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { output ->
                    output.write(bytes, 0, 64 * 1024)
                    if (uri.lastPathSegment == "blocked") {
                        ready.countDown()
                        check(resume.await(10, TimeUnit.SECONDS)) { "Import fixture was not released" }
                    }
                    output.write(bytes, 64 * 1024, bytes.size - 64 * 1024)
                }
            } // Reader cancellation intentionally closes the pipe early.
        }
        return pipe[0]
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
}
