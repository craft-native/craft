import JavaScriptCore
import AVFoundation
import XCTest
@testable import NativeRender

/// Web Audio on a native screen (CraftWebAudio.swift), rendered by hand: the
/// script builds a graph through the standard API and the test reads the
/// samples the engine would play.
@MainActor
final class NativeAudioUnitTests: XCTestCase {
    private func withSound(_ test: (CraftNativeSounds) -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sound-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 16000)
        do {
            let output = try AVAudioFile(forWriting: file, settings: format.settings)
            try output.write(from: buffer)
        }
        let service = CraftNativeSounds()
        defer { service.close() }
        service.play(id: "tone", url: file, options: ["loop": true]) { _ in }
        test(service)
    }

    private func interrupt(_ type: AVAudioSession.InterruptionType, resume: Bool = false) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: [
            AVAudioSessionInterruptionTypeKey: NSNumber(value: type.rawValue),
            AVAudioSessionInterruptionOptionKey: NSNumber(value: resume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0),
        ])
    }

    func testSoundWithoutAutomaticResumePermissionCanBeResumedExplicitly() throws {
        try withSound { service in
            interrupt(.began)
            interrupt(.ended)
            // Another unrelated interruption must not auto-resume this handle.
            interrupt(.began)
            interrupt(.ended, resume: true)
            XCTAssertTrue(service.resume(id: "tone"))
            XCTAssertFalse(service.resume(id: "tone"))
        }
    }

    func testExplicitSoundPauseSurvivesInterruptionResumePermission() throws {
        try withSound { service in
            interrupt(.began)
            XCTAssertTrue(service.pause(id: "tone"))
            interrupt(.ended, resume: true)
            XCTAssertTrue(service.resume(id: "tone"))
        }
    }

    func testSoundAutomaticallyResumesOnlyWithSystemPermission() throws {
        try withSound { service in
            interrupt(.began)
            interrupt(.ended, resume: true)
            XCTAssertFalse(service.resume(id: "tone"), "already resumed automatically")
            XCTAssertFalse(service.resume(id: "missing"))
        }
    }

    private final class VoiceRecorder: CraftVoiceRecorder {
        private let lock = NSLock()
        private var records = 0
        private var stops = 0
        var recordCount: Int { lock.withLock { records } }
        var stopCount: Int { lock.withLock { stops } }
        func record(forDuration duration: TimeInterval) -> Bool { lock.withLock { records += 1 }; return true }
        func stop() { lock.withLock { stops += 1 } }
    }

    func testBlockedVoiceStartupKeepsMainResponsiveAndCancellationPreventsRecording() async {
        let entered = expectation(description: "encoder started on audio queue")
        let startFinished = expectation(description: "start cancelled immediately")
        let cancelled = expectation(description: "cancel acknowledged")
        let drained = expectation(description: "audio queue cleaned")
        let release = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "voice-cancellation-test")
        let recorder = VoiceRecorder()
        var recordingFile: URL?
        let service = CraftVoiceRecording(audioQueue: queue, permission: { $0(true) }, makeRecorder: { file in
            XCTAssertFalse(Thread.isMainThread)
            recordingFile = file
            try Data([1, 2, 3]).write(to: file)
            entered.fulfill()
            release.wait()
            return recorder
        }, deactivate: {})
        let key = UUID().uuidString
        service.perform(method: "start", args: [key]) { result in
            if case .failure(let error) = result { XCTAssertEqual(error.code, "RECORDING_CANCELLED") }
            else { XCTFail("cancelled startup must not succeed") }
            startFinished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        // Reaching this main-actor continuation while the factory is held is
        // the responsiveness regression, not a longer microphone deadline.
        XCTAssertTrue(Thread.isMainThread)
        service.perform(method: "cancel", args: [key]) { _ in cancelled.fulfill() }
        await fulfillment(of: [cancelled, startFinished], timeout: 2)
        let erased = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            recordingFile.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        }, object: nil)
        await fulfillment(of: [erased], timeout: 2)
        release.signal()
        queue.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(recorder.recordCount, 0)
        XCTAssertGreaterThanOrEqual(recorder.stopCount, 1)
    }

    func testVoiceStartupTimeoutSettlesOnceAndErasesTheLateRecorder() async {
        let entered = expectation(description: "encoder started")
        let timedOut = expectation(description: "bounded startup")
        let drained = expectation(description: "late encoder cleaned")
        let release = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "voice-timeout-test")
        let recorder = VoiceRecorder()
        var completions = 0
        var recordingFile: URL?
        let service = CraftVoiceRecording(audioQueue: queue, startupTimeout: 0.05, permission: { $0(true) }, makeRecorder: { file in
            recordingFile = file
            try Data([1, 2, 3]).write(to: file)
            entered.fulfill()
            release.wait()
            return recorder
        }, deactivate: {})
        service.perform(method: "start", args: [UUID().uuidString]) { result in
            completions += 1
            if case .failure(let error) = result { XCTAssertEqual(error.code, "RECORDING_TIMEOUT") }
            else { XCTFail("blocked startup must time out") }
            timedOut.fulfill()
        }
        await fulfillment(of: [entered, timedOut], timeout: 2)
        release.signal()
        queue.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(recorder.recordCount, 0)
        XCTAssertFalse(recordingFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
    }

    func testCancelledPermissionAnswerCannotStartVoiceRecording() async {
        let asked = expectation(description: "permission requested")
        let cancelled = expectation(description: "pending permission cancelled")
        let completed = expectation(description: "start settled")
        var answer: ((Bool) -> Void)?
        let service = CraftVoiceRecording(permission: { answer = $0; asked.fulfill() }, makeRecorder: { _ in
            XCTFail("late permission must never construct a recorder")
            return VoiceRecorder()
        }, deactivate: {})
        let key = UUID().uuidString
        service.perform(method: "start", args: [key]) { result in
            if case .failure(let error) = result { XCTAssertEqual(error.code, "RECORDING_CANCELLED") }
            else { XCTFail("cancelled permission must fail") }
            completed.fulfill()
        }
        await fulfillment(of: [asked], timeout: 2)
        service.perform(method: "cancel", args: [key]) { _ in cancelled.fulfill() }
        await fulfillment(of: [cancelled, completed], timeout: 2)
        answer?(true)
        let lateAnswer = expectation(description: "late permission processed")
        DispatchQueue.main.async { lateAnswer.fulfill() }
        await fulfillment(of: [lateAnswer], timeout: 2)
    }

    func testAbandonedVoiceFilesAreErasedWithoutFollowingLinksOrRemovingOtherFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("voice-cleanup-\(UUID().uuidString)", isDirectory: true)
        let outside = fm.temporaryDirectory.appendingPathComponent("voice-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        let legacyFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let voiceFolder = root.appendingPathComponent("voice-recordings/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: voiceFolder, withIntermediateDirectories: true)
        let legacy = legacyFolder.appendingPathComponent("voice-feedback.m4a")
        let voice = voiceFolder.appendingPathComponent("voice-feedback.m4a")
        let unrelated = legacyFolder.appendingPathComponent("route.gpx")
        let protected = outside.appendingPathComponent("voice-feedback.m4a")
        for file in [legacy, voice, unrelated, protected] { try Data([1, 2, 3]).write(to: file) }
        try fm.createSymbolicLink(at: root.appendingPathComponent(UUID().uuidString), withDestinationURL: outside)
        let linkedFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedFolder.appendingPathComponent("voice-feedback.m4a"), withDestinationURL: protected)
        CraftVoiceRecording.discardAbandonedRecordings(in: root, includeLegacy: false)
        XCTAssertTrue(fm.fileExists(atPath: legacy.path))
        XCTAssertFalse(fm.fileExists(atPath: voice.path))
        CraftVoiceRecording.discardAbandonedRecordings(in: root)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertFalse(fm.fileExists(atPath: voice.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
        XCTAssertTrue(fm.fileExists(atPath: protected.path))
        XCTAssertTrue(fm.fileExists(atPath: linkedFolder.appendingPathComponent("voice-feedback.m4a").path))
    }

    private let rate = 48_000.0
    private var audio: CraftWebAudio!
    private var script: JSContext!

    override func setUp() {
        super.setUp()
        audio = CraftWebAudio(live: false)
        script = JSContext()
        script.exceptionHandler = { _, exception in
            XCTFail("script threw: \(exception?.toString() ?? "unknown")")
        }
        audio.install(in: script)
        run("var context = new AudioContext({ sampleRate: \(rate) });")
    }

    override func tearDown() {
        audio.close()
        audio = nil
        script = nil
        super.tearDown()
    }

    @discardableResult
    private func run(_ code: String) -> JSValue {
        script.evaluateScript(code)
    }

    private var context: Int { Int(run("context._id").toInt32()) }

    /// JSGarbageCollect only hints that a collection would be welcome, so a
    /// test that waits on FinalizationRegistry needs JavaScriptCore's own
    /// synchronous collector (exported, though not in the public headers).
    private static let synchronousCollect: (@convention(c) (JSContextRef) -> Void)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSSynchronousGarbageCollectForDebugging") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (JSContextRef) -> Void).self)
    }()

    /// Collects everything the script let go of and waits until the
    /// finalizers that collection scheduled have run (a sentinel registered
    /// just before it reports in the same batch), so their releases are queued.
    private func collectGarbage() {
        run("""
            globalThis.__collected = false;
            globalThis.__sentinel = globalThis.__sentinel || new FinalizationRegistry(function() { globalThis.__collected = true; });
            (function() { globalThis.__sentinel.register({}, 0); })();
        """)
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let collect = Self.synchronousCollect { collect(script.jsGlobalContextRef) }
            else { JSGarbageCollect(script.jsGlobalContextRef) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            // Drains the microtask that sends the queued releases.
            run("0")
        } while !run("__collected").toBool() && Date() < deadline
        XCTAssertTrue(run("__collected").toBool(), "the collection's finalizers never ran")
    }

    private func render(_ seconds: Double) -> (left: [Float], right: [Float]) {
        audio.renderForTesting(context, frames: Int(seconds * rate))
    }

    private func frame(_ seconds: Double) -> Int { Int(seconds * rate) }

    private func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    private func crossings(_ samples: ArraySlice<Float>) -> Int {
        var count = 0
        var previous = samples.first ?? 0
        for sample in samples.dropFirst() {
            if (previous < 0) != (sample < 0) { count += 1 }
            previous = sample
        }
        return count
    }

    /// A looped buffer of ones: a steady signal to shape with gains.
    private let ones = """
        var ones = context.createBuffer(1, 128, context.sampleRate);
        ones.getChannelData(0).fill(1);
        var steady = context.createBufferSource();
        steady.buffer = ones;
        steady.loop = true;
    """

    func testASineOscillatorThroughAGainPlaysAtItsPitchAndLevel() {
        run("""
            var tone = context.createOscillator();
            tone.frequency.value = 1000;
            var gain = context.createGain();
            gain.gain.value = 0.5;
            tone.connect(gain).connect(context.destination);
            tone.start(0);
        """)
        let out = render(1)
        XCTAssertEqual(peak(out.left[...]), 0.5, accuracy: 0.01)
        XCTAssertEqual(crossings(out.left[...]), 2000, accuracy: 4)
        XCTAssertEqual(out.left, out.right)
        XCTAssertEqual(run("context.currentTime").toDouble(), 1, accuracy: 0.01)
    }

    func testEveryOscillatorShapeIsBandLimitedAndInRange() {
        for (shape, level) in [("square", Float(1)), ("sawtooth", 1), ("triangle", 1)] {
            run("""
                var shaped = context.createOscillator();
                shaped.type = '\(shape)';
                shaped.frequency.value = 440;
                shaped.connect(context.destination);
                shaped.start(context.currentTime);
                shaped.stop(context.currentTime + 0.5);
            """)
            let out = render(0.5)
            // The middle of the half second: the clock runs a part of a
            // quantum ahead of what was rendered, so the last shape's end
            // and this one's start fall inside the edges.
            let middle = out.left[frame(0.1)..<frame(0.4)]
            XCTAssertEqual(peak(middle), level, accuracy: 0.15, shape)
            XCTAssertEqual(crossings(middle), 264, accuracy: 6, shape)
        }
    }

    func testRampsAndTargetsFollowTheSpec() {
        run(ones + """
            var linear = context.createGain();
            linear.gain.setValueAtTime(0, 0);
            linear.gain.linearRampToValueAtTime(1, 1);
            steady.connect(linear).connect(context.destination);
            steady.start(0);
        """)
        var out = render(1)
        XCTAssertEqual(out.left[frame(0.25)], 0.25, accuracy: 0.001)
        XCTAssertEqual(out.left[frame(0.75)], 0.75, accuracy: 0.001)

        run("""
            linear.gain.cancelScheduledValues(0);
            linear.gain.setValueAtTime(1, 1);
            linear.gain.exponentialRampToValueAtTime(0.001, 2);
        """)
        out = render(1)
        XCTAssertEqual(out.left[frame(0.5)], 0.0316, accuracy: 0.001)

        run("""
            linear.gain.setValueAtTime(1, 2);
            linear.gain.setTargetAtTime(0, 2, 0.25);
        """)
        out = render(1)
        XCTAssertEqual(out.left[frame(0.25)], Float(exp(-1.0)), accuracy: 0.002)
        XCTAssertEqual(out.left[frame(0.5)], Float(exp(-2.0)), accuracy: 0.002)

        run("""
            linear.gain.cancelScheduledValues(3);
            linear.gain.setValueCurveAtTime([0, 1, 0.5], 3, 1);
        """)
        out = render(1.5)
        XCTAssertEqual(out.left[frame(0.25)], 0.5, accuracy: 0.002)
        XCTAssertEqual(out.left[frame(0.75)], 0.75, accuracy: 0.002)
        XCTAssertEqual(out.left[frame(1.25)], 0.5, accuracy: 0.002)
        // The param reads back what the timeline gave.
        XCTAssertEqual(run("linear.gain.value").toDouble(), 0.5, accuracy: 0.002)
    }

    func testSourcesStartAndStopOnTheirFrameAndTellTheScriptTheyEnded() {
        run("""
            var ended = 0;
            var blip = context.createOscillator();
            blip.connect(context.destination);
            blip.onended = function() { ended++; };
            blip.start(0.1);
            blip.stop(0.2);
        """)
        let before = audio.nodeCountForTesting(context)
        let out = render(0.4)
        XCTAssertEqual(peak(out.left[0..<frame(0.1)]), 0)
        XCTAssertGreaterThan(peak(out.left[frame(0.1)..<frame(0.2)]), 0.9)
        XCTAssertEqual(peak(out.left[frame(0.2)...]), 0)
        XCTAssertEqual(run("ended").toInt32(), 1)
        // An ended source is gone from the graph.
        XCTAssertEqual(audio.nodeCountForTesting(context), before - 1)
        XCTAssertEqual(run("Object.keys(context._playing).length").toInt32(), 0)
    }

    func testABufferSourcePlaysItsOffsetLoopAndDuration() {
        run("""
            var ramp = context.createBuffer(1, 4800, context.sampleRate);
            var data = ramp.getChannelData(0);
            for (var i = 0; i < data.length; i++) data[i] = i / data.length;
            var once = context.createBufferSource();
            once.buffer = ramp;
            once.connect(context.destination);
            var ended = false;
            once.onended = function() { ended = true; };
            once.start(0, 0.05);
        """)
        var out = render(0.1)
        XCTAssertEqual(out.left[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(out.left[frame(0.025)], 0.75, accuracy: 0.001)
        XCTAssertEqual(peak(out.left[frame(0.051)...]), 0)
        XCTAssertTrue(run("ended").toBool())

        run("""
            var looped = context.createBufferSource();
            looped.buffer = ramp;
            looped.loop = true;
            looped.connect(context.destination);
            looped.start(0.2, 0, 0.25);
        """)
        out = render(0.5)
        // Round and round (0.1 s a lap) for the quarter second asked for;
        // this render began at 0.1 s.
        XCTAssertEqual(peak(out.left[0..<frame(0.1)]), 0)
        XCTAssertEqual(out.left[frame(0.25)], 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(peak(out.left[frame(0.3)..<frame(0.349)]), 0.4)
        XCTAssertEqual(peak(out.left[frame(0.351)...]), 0)
    }

    func testABiquadLowpassKeepsTheLowAndCutsTheHigh() {
        func level(_ hz: Double) -> Float {
            run("""
                var probe = context.createOscillator();
                probe.frequency.value = \(hz);
                var low = context.createBiquadFilter();
                low.type = 'lowpass';
                low.frequency.value = 200;
                low.Q.value = 0.6;
                probe.connect(low).connect(context.destination);
                probe.start(context.currentTime);
                probe.stop(context.currentTime + 0.5);
            """)
            let out = render(0.5)
            return rms(out.left[frame(0.1)..<frame(0.5)]) / Float(0.5.squareRoot())
        }
        XCTAssertGreaterThan(level(50), 0.9)
        XCTAssertLessThan(level(5000), 0.01)
    }

    func testADelayInAFeedbackLoopEchoesAndDecays() {
        run("""
            var click = context.createBuffer(1, 1, context.sampleRate);
            click.getChannelData(0)[0] = 1;
            var source = context.createBufferSource();
            source.buffer = click;
            var echo = context.createDelay(1);
            echo.delayTime.value = 0.1;
            var feedback = context.createGain();
            feedback.gain.value = 0.5;
            source.connect(echo);
            echo.connect(feedback).connect(echo);
            echo.connect(context.destination);
            source.start(0);
        """)
        let out = render(0.45)
        XCTAssertEqual(out.left[frame(0.1)], 1, accuracy: 0.001)
        XCTAssertEqual(out.left[frame(0.2)], 0.5, accuracy: 0.001)
        XCTAssertEqual(out.left[frame(0.3)], 0.25, accuracy: 0.001)
        XCTAssertEqual(peak(out.left[0..<frame(0.1)]), 0)
    }

    func testAConvolverPlaysItsImpulseResponseWithoutLatency() {
        run("""
            var impulse = context.createBuffer(2, 3000, context.sampleRate);
            impulse.getChannelData(0)[10] = 0.5;
            impulse.getChannelData(0)[700] = 1;
            impulse.getChannelData(1)[2000] = -1;
            var room = context.createConvolver();
            room.normalize = false;
            room.buffer = impulse;
            var click = context.createBuffer(1, 1, context.sampleRate);
            click.getChannelData(0)[0] = 1;
            var source = context.createBufferSource();
            source.buffer = click;
            source.connect(room).connect(context.destination);
            source.start(100 / context.sampleRate);
        """)
        let out = render(0.1)
        XCTAssertEqual(out.left[110], 0.5, accuracy: 0.0005)
        XCTAssertEqual(out.left[800], 1, accuracy: 0.0005)
        XCTAssertEqual(out.right[2100], -1, accuracy: 0.0005)
        XCTAssertEqual(peak(out.left[0..<110]), 0, accuracy: 0.0005)
        XCTAssertEqual(peak(out.left[111..<800]), 0, accuracy: 0.0005)
        XCTAssertEqual(peak(out.left[801...]), 0, accuracy: 0.0005)
    }

    func testAConvolverNormalisesItsImpulseAsTheSpecDoes() {
        run("""
            var impulse = context.createBuffer(1, 4800, context.sampleRate);
            impulse.getChannelData(0)[0] = 1;
            var room = context.createConvolver();
            room.buffer = impulse;
            var click = context.createBuffer(1, 1, context.sampleRate);
            click.getChannelData(0)[0] = 1;
            var source = context.createBufferSource();
            source.buffer = click;
            source.connect(room).connect(context.destination);
            source.start(0);
        """)
        let out = render(0.05)
        // 1 / RMS power x 0.00125 x 44100 / rate.
        let expected = Float(1 / (1 / 4800.0).squareRoot() * 0.00125 * 44_100 / rate)
        XCTAssertEqual(out.left[0], expected, accuracy: expected * 0.001)
    }

    func testACompressorTurnsLoudSoundDown() {
        run("""
            var loud = context.createOscillator();
            loud.frequency.value = 220;
            var squeeze = context.createDynamicsCompressor();
            squeeze.threshold.value = -18;
            squeeze.ratio.value = 3;
            loud.connect(squeeze).connect(context.destination);
            loud.start(0);
        """)
        let out = render(1)
        XCTAssertLessThan(run("squeeze.reduction").toDouble(), -2)
        XCTAssertLessThan(peak(out.left[frame(0.5)...]), 0.95)
        XCTAssertGreaterThan(peak(out.left[frame(0.5)...]), 0.2)
    }

    func testANodeDrivesAnotherNodesParam() {
        run(ones + """
            var swell = context.createGain();
            swell.gain.value = 0;
            var lfo = context.createOscillator();
            lfo.frequency.value = 1;
            var depth = context.createGain();
            depth.gain.value = 0.5;
            lfo.connect(depth).connect(swell.gain);
            steady.connect(swell).connect(context.destination);
            steady.start(0);
            lfo.start(0);
        """)
        let out = render(1)
        XCTAssertEqual(out.left[frame(0.25)], 0.5, accuracy: 0.002)
        XCTAssertEqual(out.left[frame(0.75)], -0.5, accuracy: 0.002)
    }

    func testSuspendStopsTheClockAndCloseEndsTheContext() {
        render(0.5)
        run("context.suspend()")
        let out = render(0.5)
        XCTAssertEqual(peak(out.left[...]), 0)
        XCTAssertEqual(run("context.currentTime").toDouble(), 0.5, accuracy: 0.01)
        run("context.resume()")
        render(0.5)
        XCTAssertEqual(run("context.currentTime").toDouble(), 1, accuracy: 0.01)
        run("context.close()")
        XCTAssertFalse(audio.contextIdsForTesting.contains(context))
    }

    /// The real engine: the context's clock moves only as AVAudioEngine pulls
    /// the graph, so a clock that moves is the render callback running.
    func testTheLiveEngineRendersTheGraphAndKeepsItsClock() {
        let live = CraftWebAudio()
        let page = JSContext()!
        live.install(in: page)
        page.evaluateScript("""
            var live = new AudioContext();
            var tone = live.createOscillator();
            var quiet = live.createGain();
            quiet.gain.value = 0.001;
            tone.connect(quiet).connect(live.destination);
            tone.start();
        """)
        XCTAssertGreaterThan(page.evaluateScript("live.sampleRate").toDouble(), 8_000)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertGreaterThan(page.evaluateScript("live.currentTime").toDouble(), 0.2)
        page.evaluateScript("live.suspend()")
        let held = page.evaluateScript("live.currentTime").toDouble()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(page.evaluateScript("live.currentTime").toDouble(), held, accuracy: 0.05)
        page.evaluateScript("live.close()")
        live.close()
    }

    /// The breathing studio's music, in the shape stx's useAmbientSound
    /// builds it: a compressed bus with a 3.2 s generated reverb, pads,
    /// filtered noise swelling under an LFO, a step sequencer's drums and
    /// plucks through a feedback delay. A minute of it stays sound and bounded.
    func testAnAmbientMusicBedPlaysOnAndLetsItsNodesGo() {
        run("""
            var music = context.createGain();
            music.gain.value = 0;
            var tones = context.createGain();
            var compressor = context.createDynamicsCompressor();
            compressor.threshold.value = -18;
            compressor.ratio.value = 3;
            music.connect(compressor);
            tones.connect(compressor);
            compressor.connect(context.destination);
            var reverb = context.createConvolver();
            var length = Math.floor(context.sampleRate * 3.2);
            var impulse = context.createBuffer(2, length, context.sampleRate);
            for (var c = 0; c < 2; c++) {
                var d = impulse.getChannelData(c);
                for (var i = 0; i < length; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / length, 3);
            }
            reverb.buffer = impulse;
            var wet = context.createGain();
            wet.gain.value = 0.35;
            reverb.connect(wet).connect(music);
            var noise = context.createBuffer(1, context.sampleRate * 4, context.sampleRate);
            var brown = 0, nd = noise.getChannelData(0);
            for (var i = 0; i < nd.length; i++) { brown = (brown + (Math.random() * 2 - 1) * 0.02) / 1.02; nd[i] = brown * 3.5; }
            var white = context.createBuffer(1, context.sampleRate, context.sampleRate);
            var wd = white.getChannelData(0);
            for (var i = 0; i < wd.length; i++) wd[i] = Math.random() * 2 - 1;
            music.gain.setValueAtTime(0, context.currentTime);
            music.gain.linearRampToValueAtTime(0.5, context.currentTime + 1.5);

            function hz(midi) { return 440 * Math.pow(2, (midi - 69) / 12); }
            function pad(midi, start, len, level, type, cutoff) {
                var out = context.createGain();
                out.gain.setValueAtTime(0, start);
                out.gain.linearRampToValueAtTime(level, start + Math.min(3, len / 3));
                out.gain.setValueAtTime(level, start + len - Math.min(3, len / 3));
                out.gain.linearRampToValueAtTime(0, start + len);
                var filter = context.createBiquadFilter();
                filter.type = 'lowpass';
                filter.frequency.value = cutoff;
                filter.Q.value = 0.6;
                filter.connect(out);
                out.connect(music);
                out.connect(reverb);
                [-7, 7].forEach(function(cents) {
                    var o = context.createOscillator();
                    o.type = type;
                    o.frequency.value = hz(midi);
                    o.detune.value = cents;
                    o.connect(filter);
                    o.start(start);
                    o.stop(start + len + 0.1);
                });
            }
            (function noiseBed() {
                var source = context.createBufferSource();
                source.buffer = noise;
                source.loop = true;
                var filter = context.createBiquadFilter();
                filter.type = 'lowpass';
                filter.frequency.value = 700;
                var gain = context.createGain();
                gain.gain.value = 0.22;
                var lfo = context.createOscillator();
                lfo.frequency.value = 1 / 9;
                var lfoGain = context.createGain();
                lfoGain.gain.value = 0.22 * 0.85;
                lfo.connect(lfoGain).connect(gain.gain);
                source.connect(filter).connect(gain).connect(music);
                source.start(context.currentTime, Math.random() * 3);
                lfo.start(context.currentTime);
            })();
            var echo = context.createDelay(1);
            echo.delayTime.value = 0.45;
            var feedback = context.createGain();
            feedback.gain.value = 0.32;
            var echoWet = context.createGain();
            echoWet.gain.value = 0.5;
            echo.connect(feedback).connect(echo);
            echo.connect(echoWet).connect(music);
            var arp = context.createGain();
            arp.connect(music);
            arp.connect(echo);
            function kick(at) {
                var o = context.createOscillator();
                o.frequency.setValueAtTime(140, at);
                o.frequency.exponentialRampToValueAtTime(45, at + 0.18);
                var g = context.createGain();
                g.gain.setValueAtTime(0.4, at);
                g.gain.exponentialRampToValueAtTime(0.001, at + 0.35);
                o.connect(g).connect(music);
                o.start(at);
                o.stop(at + 0.4);
            }
            function hat(at) {
                var s = context.createBufferSource();
                s.buffer = white;
                var f = context.createBiquadFilter();
                f.type = 'highpass';
                f.frequency.value = 7000;
                var g = context.createGain();
                g.gain.setValueAtTime(0.06, at);
                g.gain.exponentialRampToValueAtTime(0.001, at + 0.04);
                s.connect(f).connect(g).connect(music);
                s.start(at, Math.random() * 0.8, 0.06);
            }
            function pluck(midi, at) {
                var o = context.createOscillator();
                o.type = 'square';
                o.frequency.value = hz(midi);
                var f = context.createBiquadFilter();
                f.type = 'lowpass';
                f.frequency.setValueAtTime(2400, at);
                f.frequency.exponentialRampToValueAtTime(400, at + 0.18);
                var g = context.createGain();
                g.gain.setValueAtTime(0, at);
                g.gain.linearRampToValueAtTime(0.035, at + 0.005);
                g.gain.exponentialRampToValueAtTime(0.001, at + 0.18);
                o.connect(f).connect(g).connect(arp);
                o.start(at);
                o.stop(at + 0.23);
            }
            function breathTone(kind, seconds) {
                var now = context.currentTime;
                var o = context.createOscillator();
                o.frequency.setValueAtTime(kind === 'in' ? 196 : 294, now);
                o.frequency.exponentialRampToValueAtTime(kind === 'in' ? 294 : 196, now + seconds);
                var g = context.createGain();
                g.gain.setValueAtTime(0, now);
                g.gain.linearRampToValueAtTime(0.07, now + Math.min(0.6, seconds / 3));
                g.gain.setValueAtTime(0.07, now + seconds * 0.75);
                g.gain.linearRampToValueAtTime(0, now + seconds);
                o.connect(g).connect(tones);
                o.start(now);
                o.stop(now + seconds + 0.05);
            }
            var next = context.currentTime + 0.1, index = 0, sixteenth = 60 / 118 / 4, chord = 0;
            function step() {
                while (next < context.currentTime + 0.12) {
                    if (index % 4 === 0) kick(next);
                    if (index % 4 === 2) hat(next);
                    pluck([62, 66, 69, 74][index % 4], next);
                    if (index % 32 === 0) { [50, 57, 62].forEach(function(n) { pad(n + 12, next, 4, 0.02, 'sawtooth', 1400); }); }
                    if (index % 16 === 0) breathTone(index % 32 === 0 ? 'in' : 'out', 2);
                    next += sixteenth;
                    index++;
                }
            }
        """)
        let id = context
        var loudest: Float = 0
        var energy: Float = 0
        var most = 0
        var settled: [Int] = []
        // A minute, the sequencer running every 25 ms as setInterval would.
        // Every five seconds the script's garbage is collected for certain,
        // so the count measures the engine, not when JavaScriptCore felt
        // like collecting.
        for tick in 0..<Int(60 / 0.025) {
            run("step()")
            let out = audio.renderForTesting(id, frames: Int(0.025 * rate))
            XCTAssertFalse(out.left.contains { !$0.isFinite }, "a sample went NaN at \(tick)")
            loudest = max(loudest, peak(out.left[...]))
            energy += rms(out.left[...])
            if tick % 200 == 199 {
                collectGarbage()
                // The releases reach the engine with the next render, and
                // what has gone quiet leaves the graph then.
                let tail = audio.renderForTesting(id, frames: Int(0.025 * rate))
                loudest = max(loudest, peak(tail.left[...]))
                settled.append(audio.nodeCountForTesting(id))
            }
            most = max(most, audio.nodeCountForTesting(id))
        }
        XCTAssertGreaterThan(energy / Float(60 / 0.025), 0.01)
        XCTAssertLessThan(loudest, 2)
        // A few hundred notes a minute come and go; the graph does not grow.
        // Collected, it is the long-lived graph plus what still sounds (about
        // 40 nodes); between collections, five seconds of notes (about 150).
        XCTAssertEqual(settled.count, 12)
        XCTAssertLessThan(settled.max() ?? .max, 120, "settled counts \(settled)")
        XCTAssertLessThan(most, 400, "settled counts \(settled)")
        // The last half of the minute holds no more than the first half did.
        let firstHalf = settled.prefix(6).max() ?? 0
        let lastHalf = settled.suffix(6).max() ?? .max
        XCTAssertLessThanOrEqual(lastHalf, firstHalf + 20, "settled counts \(settled)")
    }
}
