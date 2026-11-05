/** Holds a completed attempt in RUNNING, before WorkManager commits its result. */
class SettledMediaAttemptWorker(context: Context, parameters: androidx.work.WorkerParameters) : androidx.work.Worker(context, parameters) {
    private val released = java.util.concurrent.CountDownLatch(1)
    override fun doWork(): Result {
        setProgressAsync(androidx.work.workDataOf("craft.media.attemptSettled" to true)).get()
        released.await(30, java.util.concurrent.TimeUnit.SECONDS)
        return Result.retry()
    }
    override fun onStopped() { released.countDown() }
}

class DownloadProbe : android.app.Instrumentation() {
    override fun onCreate(arguments: android.os.Bundle?) {
        super.onCreate(arguments)
        args = arguments ?: android.os.Bundle()
        start()
    }
    private var args = android.os.Bundle()
    private var latestErrorCode: String? = null
    private val proof = StringBuilder()
    private fun check(yes: Boolean, message: String) {
        if (!yes) throw IllegalStateException(message)
        proof.append("PASS: ").append(message).append('\n')
        android.util.Log.i("CraftMediaProbe", "PASS: $message")
    }
    private fun keep(address: String, cacheKey: String? = null): Boolean {
        val done = java.util.concurrent.CountDownLatch(1)
        var ok = false
        CraftNativeMedia.keep(targetContext, address, JSONObject(), true, cacheKey = cacheKey) {
            latestErrorCode = it.code
            ok = (it.data as? JSONObject)?.optBoolean("ok") == true
            done.countDown()
        }
        check(done.await(25, java.util.concurrent.TimeUnit.SECONDS), "operation settled")
        return ok
    }
    private fun awaitCached(address: String) {
        // The worker authors a 30-second first retry. Allow that backoff plus
        // the existing 25-second transfer budget, without issuing another keep.
        val until = System.currentTimeMillis() + 60000
        while (CraftNativeMedia.local(targetContext, address) == null && System.currentTimeMillis() < until) Thread.sleep(25)
        check(CraftNativeMedia.local(targetContext, address) != null, "the durable worker recovers the complete file without another keep")
    }
    override fun onStart() {
        val result = android.os.Bundle()
        try {
            val base = args.getString("base")!!
            val restart = "$base/restart.mp4"
            when (args.getString("phase")) {
                "storage" -> {
                    CraftNativeMedia.prune(targetContext, emptyList())
                    val prefs = targetContext.getSharedPreferences("workout-recovery-probe", Context.MODE_PRIVATE)
                    val progress = """{"sets":["A1"],"note":"Keep this workout","rpe":7}"""
                    check(prefs.edit().putString("progress", progress).commit(), "workout progress is durable before storage failure")
                    val prefsDisk = File(targetContext.applicationInfo.dataDir, "shared_prefs/workout-recovery-probe.xml")
                    val savedPrefs = prefsDisk.readBytes()
                    val retained = "$base/retained.mp4"
                    check(keep(retained), "existing video is kept before storage pressure")
                    val original = CraftNativeMedia.local(targetContext, retained)!!.readBytes()
                    val fresh = "$base/storage.mp4"
                    val staging = CraftNativeMedia.part(targetContext, fresh)
                    val root = staging.parentFile!!
                    check(root.totalSpace in 1..(32L * 1024 * 1024), "storage pressure is confined to a bounded disposable volume")
                    val pressure = File(root, "pressure.mp4")
                    var written = 0L
                    pressure.outputStream().use { output ->
                        for (size in listOf(65536, 1024)) {
                            val chunk = ByteArray(size) { 0x5A.toByte() }
                            while (written < 32L * 1024 * 1024) {
                                try { output.write(chunk); written += size }
                                catch (error: java.io.IOException) { break }
                            }
                        }
                    }
                    check(written > 0 && root.usableSpace < 1024, "the probe cache filesystem is actually full")
                    check(!keep(fresh), "out-of-space write refuses a new video")
                    check(latestErrorCode == "NO_SPACE", "a full disk is reported as NO_SPACE, not a network failure")
                    check(CraftNativeMedia.local(targetContext, fresh) == null, "storage failure never publishes a partial video")
                    check(!staging.exists(), "storage failure removes staging files")
                    check(CraftNativeMedia.local(targetContext, retained)!!.readBytes().contentEquals(original), "storage failure preserves an existing video")
                    check(CraftNativeMedia.prune(targetContext, listOf(retained)) == 1, "cache cleanup frees the obsolete file and preserves the retained video")
                    check(prefs.getString("progress", null) == progress && prefsDisk.readBytes().contentEquals(savedPrefs), "cache cleanup preserves workout progress and feedback on disk")
                    check(keep(fresh), "same missing video downloads after cleanup")
                    val decoder = android.media.MediaMetadataRetriever()
                    try {
                        decoder.setDataSource(CraftNativeMedia.local(targetContext, fresh)!!.absolutePath)
                        check(decoder.getFrameAtTime(1000000) != null, "downloaded replacement plays from its local file")
                    } finally { decoder.release() }
                    check(prefs.getString("progress", null) == progress && prefsDisk.readBytes().contentEquals(savedPrefs), "redownloading leaves workout progress and feedback unchanged on disk")
                    CraftNativeMedia.prune(targetContext, emptyList())
                    prefs.edit().clear().commit()
                }
                "retire" -> {
                    val a = "$base/selective-a.mp4"
                    val b = "$base/selective-b.mp4"
                    check(keep(a) && keep(b), "two authorized videos are kept")
                    val oldGeneration = CraftNativeMedia.generation(targetContext)
                    check(targetContext.getSharedPreferences("media-probe", Context.MODE_PRIVATE).edit().putInt("old-generation", oldGeneration).commit(), "old worker generation is retained for restart verification")
                    val cacheRoot = CraftNativeMedia.file(targetContext, a).parentFile!!
                    android.system.Os.chmod(cacheRoot.absolutePath, 365) // 0555: read/search, no unlink
                    var unlinkFailed = false
                    try { CraftNativeMedia.remove(targetContext, a) } catch (error: java.io.IOException) { unlinkFailed = true }
                    finally { android.system.Os.chmod(cacheRoot.absolutePath, 448) } // 0700
                    check(unlinkFailed, "a real unlink failure is reported")
                    check(CraftNativeMedia.local(targetContext, a) == null && CraftNativeMedia.local(targetContext, b) != null, "failed unlink hides revoked A and preserves authorized B")
                    check(CraftNativeMedia.remove(targetContext, a) == 1, "removing A removes only its copy")
                    check(CraftNativeMedia.local(targetContext, a) == null && CraftNativeMedia.local(targetContext, b) != null, "B stays available after A is revoked")
                }
                "retired-recover" -> {
                    val a = "$base/selective-a.mp4"
                    val b = "$base/selective-b.mp4"
                    val oldGeneration = targetContext.getSharedPreferences("media-probe", Context.MODE_PRIVATE).getInt("old-generation", -1)
                    check(CraftNativeMedia.local(targetContext, a) == null && CraftNativeMedia.local(targetContext, b) != null, "selective revocation survives a fresh Android process")
                    fun obsoleteCompletion() {
                        val result = CraftNativeMedia.transfer(targetContext, a, JSONObject(), oldGeneration, 0, ownerRevision = "") { false }
                        check(result == CraftNativeMedia.Outcome.DONE, "obsolete worker retires without retry or publication")
                    }
                    obsoleteCompletion()
                    check(keep(a), "a new authorized keep can re-grant A")
                    val fresh = CraftNativeMedia.local(targetContext, a)!!.readBytes()
                    obsoleteCompletion()
                    check(CraftNativeMedia.local(targetContext, a)!!.readBytes().contentEquals(fresh), "obsolete worker cannot replace re-granted A")
                    val decoder = android.media.MediaMetadataRetriever()
                    try {
                        decoder.setDataSource(CraftNativeMedia.local(targetContext, b)!!.absolutePath)
                        check(decoder.getFrameAtTime(1000000) != null, "unrelated B still decodes offline after revocation and re-grant")
                    } finally { decoder.release() }
                    CraftNativeMedia.clear(targetContext)
                    targetContext.getSharedPreferences("media-probe", Context.MODE_PRIVATE).edit().clear().commit()
                }
                "interrupt" -> {
                    CraftNativeMedia.prune(targetContext, emptyList())
                    CraftNativeMedia.keep(targetContext, restart, JSONObject(), true) {}
                    val target = CraftNativeMedia.file(targetContext, restart)
                    fun partial() = target.parentFile!!.listFiles()?.any { it.name.startsWith(target.name + ".") && it.name.endsWith(".part") && it.length() > 0 } == true
                    val until = System.currentTimeMillis() + 25000
                    while (!partial() && System.currentTimeMillis() < until) Thread.sleep(25)
                    check(partial(), "download is in progress before process death")
                    check(CraftNativeMedia.local(targetContext, restart) == null, "interrupted process never published a partial video")
                    android.os.Process.killProcess(android.os.Process.myPid())
                }
                "recover" -> {
                    awaitCached(restart)
                    check(keep(restart), "retry after process death downloads a complete video")
                    val media = android.media.MediaMetadataRetriever()
                    try {
                        media.setDataSource(CraftNativeMedia.local(targetContext, restart)!!.absolutePath)
                        check(media.getFrameAtTime(1000000) != null, "recovered local video decodes a frame without network")
                    } finally { media.release() }
                    CraftNativeMedia.prune(targetContext, emptyList())
                }
                else -> {
                    CraftNativeMedia.prune(targetContext, emptyList())
                    val queuedKey = "account:one:lesson:8:version:a"
                    val expired = base + "/queued.mp4?token=expired"
                    val renewed = base + "/queued.mp4?token=renewed"
                    val queuedIdentity = CraftNativeMedia.identity(expired, JSONObject().put("cacheKey", queuedKey))
                    val queuedGeneration = CraftNativeMedia.generation(targetContext)
                    targetContext.getSharedPreferences("craft.media", Context.MODE_PRIVATE).edit().putString("source:${CraftNativeMedia.digest(queuedIdentity)}", CraftNativeMedia.digest(expired + "\n")).commit()
                    val queuedWork = androidx.work.OneTimeWorkRequestBuilder<CraftNativeMediaWorker>()
                        .setInputData(androidx.work.workDataOf("address" to queuedIdentity, "source" to expired, "headers" to "{}", "generation" to queuedGeneration))
                        .setInitialDelay(1, java.util.concurrent.TimeUnit.DAYS)
                        .addTag("craft-media:generation:$queuedGeneration")
                        .build()
                    androidx.work.WorkManager.getInstance(targetContext).enqueueUniqueWork("craft-media:${CraftNativeMedia.digest(queuedIdentity)}:any", androidx.work.ExistingWorkPolicy.REPLACE, queuedWork).result.get()
                    check(keep(renewed, queuedKey), "a renewed authorized source replaces expired queued work immediately")
                    val signed = base + "/keyed.mp4?token=first"
                    val key = "account:one:lesson:7:version:a"
                    check(keep(signed, key), "signed URL downloads under an account/version identity")
                    val identity = CraftNativeMedia.identity(signed, JSONObject().put("cacheKey", key))
                    val rotated = CraftNativeMedia.identity(base + "/keyed.mp4?token=second", JSONObject().put("cacheKey", key))
                    check(identity == rotated && CraftNativeMedia.local(targetContext, rotated) != null, "renewed signed URLs reuse the complete copy offline")
                    check(keep(base + "/keyed.mp4?token=second", key), "renewing authorization does not redownload unchanged content")
                    check(CraftNativeMedia.local(targetContext, CraftNativeMedia.identity(signed, JSONObject().put("cacheKey", "account:two:lesson:7:version:a"))) == null, "another account cannot address the copy")
                    check(CraftNativeMedia.local(targetContext, CraftNativeMedia.identity(signed, JSONObject().put("cacheKey", "account:one:lesson:7:version:b"))) == null, "a new version invalidates the copy")
                    CraftNativeMedia.prune(targetContext, listOf(rotated))
                    check(CraftNativeMedia.local(targetContext, rotated) != null, "key-aware prune retains the authorized source")
                    CraftNativeMedia.prune(targetContext, emptyList())
                    check(CraftNativeMedia.local(targetContext, rotated) == null, "revocation removes the keyed copy")
                    val broken = "$base/broken.mp4"
                    check(!keep(broken), "truncated transfer fails")
                    check(CraftNativeMedia.local(targetContext, broken) == null, "truncated transfer is not playable cache")
                    val root = CraftNativeMedia.file(targetContext, broken).parentFile!!
                    check(CraftNativeMedia.part(targetContext, broken).length() > 0, "a truncated transfer retains bytes for resumption")
                    awaitCached(broken)
                    check(keep(broken), "same URL retries successfully")
                    val retry = "$base/retry.mp4"
                    check(!keep(retry), "a separate interrupted transfer reports its failure")
                    check(keep(retry), "an explicit retry runs immediately, without waiting for backoff")
                    check(root.listFiles()?.none { it.name.endsWith(".part") } != false, "finished retries leave no staging files")
                    val work = androidx.work.WorkManager.getInstance(targetContext)
                    val settled = "$base/settled.mp4"
                    val settledName = "craft-media:${CraftNativeMedia.digest(settled)}:any"
                    val settledRequest = androidx.work.OneTimeWorkRequestBuilder<SettledMediaAttemptWorker>()
                        .addTag("craft-media").addTag("craft-media:${CraftNativeMedia.digest(settled)}")
                        .addTag("craft-media:generation:${CraftNativeMedia.generation(targetContext)}")
                        .addTag("craft-media:identity:${CraftNativeMedia.digest(settled)}:legacy").build()
                    work.enqueueUniqueWork(settledName, androidx.work.ExistingWorkPolicy.KEEP, settledRequest).result.get()
                    val settledDeadline = System.currentTimeMillis() + 10000
                    var settledInfo = work.getWorkInfoById(settledRequest.id).get()!!
                    while ((settledInfo.state != androidx.work.WorkInfo.State.RUNNING || !settledInfo.progress.getBoolean("craft.media.attemptSettled", false)) && System.currentTimeMillis() < settledDeadline) {
                        Thread.sleep(25)
                        settledInfo = work.getWorkInfoById(settledRequest.id).get()!!
                    }
                    check(settledInfo.state == androidx.work.WorkInfo.State.RUNNING && settledInfo.progress.getBoolean("craft.media.attemptSettled", false), "the settled attempt still has WorkManager's running identity")
                    check(keep(settled), "an explicit keep replaces a settled running attempt immediately")
                    // REPLACE can prune the old WorkSpec. Inspect the current
                    // unique chain rather than requiring the removed row.
                    val replacement = work.getWorkInfosForUniqueWork(settledName).get()
                    check(replacement.size == 1 && replacement.single().id != settledRequest.id && replacement.single().state != androidx.work.WorkInfo.State.CANCELLED, "the settled work identity was replaced, not joined")

                    val queued = "$base/queued.mp4"
                    val queuedName = "craft-media:${CraftNativeMedia.digest(queued)}:any"
                    val queuedRequest = androidx.work.OneTimeWorkRequestBuilder<CraftNativeMediaWorker>()
                        .setInitialDelay(10, java.util.concurrent.TimeUnit.SECONDS)
                        .setInputData(androidx.work.workDataOf("address" to queued, "headers" to "{}", "generation" to CraftNativeMedia.generation(targetContext)))
                        .addTag("craft-media").addTag("craft-media:${CraftNativeMedia.digest(queued)}")
                        .addTag("craft-media:generation:${CraftNativeMedia.generation(targetContext)}")
                        .addTag("craft-media:identity:${CraftNativeMedia.digest(queued)}:legacy").build()
                    work.enqueueUniqueWork(queuedName, androidx.work.ExistingWorkPolicy.KEEP, queuedRequest).result.get()
                    val beforeJoin = work.getWorkInfoById(queuedRequest.id).get()!!
                    check(beforeJoin.state == androidx.work.WorkInfo.State.ENQUEUED && beforeJoin.runAttemptCount == 0, "the coalescing regression starts with a fresh queued transfer")
                    check(keep(queued), "keep joins the fresh queued transfer")
                    val afterJoin = work.getWorkInfosForUniqueWork(queuedName).get()
                    check(afterJoin.size == 1 && afterJoin.single().id == queuedRequest.id && afterJoin.single().state != androidx.work.WorkInfo.State.CANCELLED, "a second keep retains the original queued work identity")

                    val locked = "$base/locked/slow.mp4"
                    val started = CraftNativeMedia.generation(targetContext)
                    var firstOutcome: CraftNativeMedia.Outcome? = null
                    var secondOutcome: CraftNativeMedia.Outcome? = null
                    val firstWriter = Thread { firstOutcome = CraftNativeMedia.transfer(targetContext, locked, JSONObject(), started, 0) { false } }
                    val secondWriter = Thread { secondOutcome = CraftNativeMedia.transfer(targetContext, locked, JSONObject(), started, 0) { false } }
                    firstWriter.start()
                    val writingDeadline = System.currentTimeMillis() + 25000
                    while (CraftNativeMedia.part(targetContext, locked).length() == 0L && System.currentTimeMillis() < writingDeadline) Thread.sleep(10)
                    check(CraftNativeMedia.part(targetContext, locked).length() > 0L, "the first writer owns an active partial download")
                    secondWriter.start()
                    val blockedDeadline = System.currentTimeMillis() + 5000
                    while (secondWriter.state != Thread.State.BLOCKED && secondWriter.isAlive && System.currentTimeMillis() < blockedDeadline) Thread.sleep(1)
                    check(secondWriter.state == Thread.State.BLOCKED, "the second writer waits on the same address lock")
                    java.net.URL("$base/locked/release").openConnection().getInputStream().use { it.readBytes() }
                    firstWriter.join(25000)
                    secondWriter.join(25000)
                    check(!firstWriter.isAlive && !secondWriter.isAlive && firstOutcome == CraftNativeMedia.Outcome.DONE && secondOutcome == CraftNativeMedia.Outcome.DONE, "both address writers finish from the same cached copy")
                    check(CraftNativeMedia.local(targetContext, locked) != null, "the coalesced writer leaves a complete local video")

                    val stale = "$base/stale/slow.mp4"
                    val staleGeneration = CraftNativeMedia.generation(targetContext)
                    CraftNativeMedia.clear(targetContext)
                    val currentDone = java.util.concurrent.CountDownLatch(1)
                    var currentOK = false
                    CraftNativeMedia.keep(targetContext, stale, JSONObject(), true) { currentOK = (it.data as? JSONObject)?.optBoolean("ok") == true; currentDone.countDown() }
                    val currentDeadline = System.currentTimeMillis() + 25000
                    while (CraftNativeMedia.part(targetContext, stale).length() == 0L && System.currentTimeMillis() < currentDeadline) Thread.sleep(10)
                    check(CraftNativeMedia.part(targetContext, stale).length() > 0L, "the next generation has its own active transfer")
                    check(CraftNativeMedia.transfer(targetContext, stale, JSONObject(), staleGeneration, 0) { false } == CraftNativeMedia.Outcome.DONE, "an obsolete worker exits without fetching")
                    check(currentDone.await(25, java.util.concurrent.TimeUnit.SECONDS) && currentOK, "an obsolete worker cannot cancel the next generation's waiters")

                    val inflight = "$base/inflight/slow.mp4"
                    // This fixture starts the old worker directly rather than through keep.
                    // Give it the same persisted grant keep records after a clear.
                    check(targetContext.getSharedPreferences("craft.media", Context.MODE_PRIVATE).edit().putBoolean("authorized:${CraftNativeMedia.digest(inflight)}", true).commit(), "the direct worker starts with an explicit grant")
                    val inflightGeneration = CraftNativeMedia.generation(targetContext)
                    var obsoleteOutcome: CraftNativeMedia.Outcome? = null
                    val obsoleteWriter = Thread { obsoleteOutcome = CraftNativeMedia.transfer(targetContext, inflight, JSONObject(), inflightGeneration, 0) { false } }
                    obsoleteWriter.start()
                    fun oldRequestReachedServer() = java.net.URL("$base/inflight/status").readText() == "1"
                    val inflightDeadline = System.currentTimeMillis() + 25000
                    while (!oldRequestReachedServer() && System.currentTimeMillis() < inflightDeadline) Thread.sleep(10)
                    check(oldRequestReachedServer(), "the obsolete generation is waiting for its HTTP response")
                    CraftNativeMedia.clear(targetContext)
                    val nextDone = java.util.concurrent.CountDownLatch(1)
                    var nextOK = false
                    CraftNativeMedia.keep(targetContext, inflight, JSONObject(), true) { nextOK = (it.data as? JSONObject)?.optBoolean("ok") == true; nextDone.countDown() }
                    java.net.URL("$base/inflight/release").openConnection().getInputStream().use { it.readBytes() }
                    obsoleteWriter.join(25000)
                    check(!obsoleteWriter.isAlive && obsoleteOutcome == CraftNativeMedia.Outcome.DONE, "the old generation's delayed refusal finishes")
                    check(nextDone.await(25, java.util.concurrent.TimeUnit.SECONDS) && nextOK, "an old in-flight refusal cannot consume the next generation's callback")

                    val late = "$base/late-queued.mp4"
                    val lateGeneration = CraftNativeMedia.generation(targetContext)
                    CraftNativeMedia.clear(targetContext)
                    val lateName = "craft-media:${CraftNativeMedia.digest(late)}:any"
                    // Reproduce an obsolete scheduler enqueue landing after clear's cancellation.
                    val lateRequest = androidx.work.OneTimeWorkRequestBuilder<CraftNativeMediaWorker>()
                        .setInitialDelay(10, java.util.concurrent.TimeUnit.SECONDS)
                        .setInputData(androidx.work.workDataOf("address" to late, "headers" to "{}", "generation" to lateGeneration))
                        .addTag("craft-media").addTag("craft-media:${CraftNativeMedia.digest(late)}")
                        .addTag("craft-media:generation:$lateGeneration").build()
                    work.enqueueUniqueWork(lateName, androidx.work.ExistingWorkPolicy.KEEP, lateRequest).result.get()
                    check(work.getWorkInfoById(lateRequest.id).get()!!.state == androidx.work.WorkInfo.State.ENQUEUED, "the obsolete queued request lands after clear")
                    check(keep(late), "a new generation replaces obsolete queued work")
                    val currentWork = work.getWorkInfosForUniqueWork(lateName).get()
                    check(currentWork.size == 1 && currentWork.single().id != lateRequest.id &&
                        "craft-media:generation:${CraftNativeMedia.generation(targetContext)}" in currentWork.single().tags &&
                        currentWork.single().state != androidx.work.WorkInfo.State.CANCELLED,
                        "obsolete queued work is replaced by a current-generation work identity")
                    check(!keep("$base/partial.mp4"), "unsolicited partial response is refused")
                    check(!keep("$base/empty.mp4"), "empty file is refused")
                    val slow = "$base/slow.mp4"
                    val done = java.util.concurrent.CountDownLatch(2)
                    val answers = java.util.Collections.synchronizedList(mutableListOf<Boolean>())
                    repeat(2) { CraftNativeMedia.keep(targetContext, slow, JSONObject(), true) { answers.add((it.data as? JSONObject)?.optBoolean("ok") == true); done.countDown() } }
                    Thread.sleep(150)
                    CraftNativeMedia.prune(targetContext, emptyList())
                    check(done.await(25, java.util.concurrent.TimeUnit.SECONDS), "coalesced downloads settled")
                    check(answers.size == 2 && answers.all { it }, "concurrent downloads coalesce and survive prune")
                    check(root.listFiles()?.none { it.name.endsWith(".part") } != false, "no abandoned staging files remain")
                    CraftNativeMedia.prune(targetContext, emptyList())
                    val privateVideo = "$base/account/slow.mp4"
                    val previous = java.util.concurrent.CountDownLatch(1)
                    var cancelled = false
                    CraftNativeMedia.keep(targetContext, privateVideo, JSONObject(), true) { cancelled = it.code == "CANCELLED"; previous.countDown() }
                    val privateTarget = CraftNativeMedia.file(targetContext, privateVideo)
                    fun downloading() = root.listFiles()?.any { it.name.startsWith(privateTarget.name + ".") && it.name.endsWith(".part") && it.length() > 0 } == true
                    val deadline = System.currentTimeMillis() + 25000
                    while (!downloading() && System.currentTimeMillis() < deadline) Thread.sleep(10)
                    check(downloading(), "the previous athlete's download is in progress before sign-out")
                    CraftNativeMedia.clear(targetContext)
                    check(previous.await(5, java.util.concurrent.TimeUnit.SECONDS) && cancelled, "sign-out cancels the previous athlete's download")
                    check(CraftNativeMedia.local(targetContext, privateVideo) == null, "signed-out video is not playable from cache")
                    check(keep(privateVideo), "the next athlete downloads the same URL in a new transfer")
                    val media = android.media.MediaMetadataRetriever()
                    try {
                        media.setDataSource(CraftNativeMedia.local(targetContext, privateVideo)!!.absolutePath)
                        check(media.getFrameAtTime(1000000) != null, "the next athlete's local video decodes after the old download settles")
                    } finally { media.release() }
                    CraftNativeMedia.clear(targetContext)
                    check(CraftNativeMedia.local(targetContext, privateVideo) == null, "sign-out removes the next athlete's cached copy too")
                }
            }
            result.putString("stream", "${proof}PASS: ${args.getString("phase")} native download probe")
            finish(-1, result)
        } catch (error: Throwable) {
            result.putString("stream", "${proof}FAIL: ${error.stackTraceToString()}")
            finish(1, result)
        }
    }
}
