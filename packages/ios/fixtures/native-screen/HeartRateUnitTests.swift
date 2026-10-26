import CryptoKit
import UIKit
import XCTest
@testable import NativeRender

/// Heart Rate Measurement (0x2A37) decoding, and the HeartRate module's gate.
/// A real strap needs a phone; the payloads here are the ones straps send.
@MainActor
final class HeartRateUnitTests: XCTestCase {
    private func recordingCall(_ monitor: CraftHeartRate, _ method: String, _ options: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            monitor.perform(method: method, args: [options]) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    func testPersistedPlannedIdentityRecoversAfterLostStartResponseAndFullCheckpointDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planned = UUID().uuidString
        let prefix = "planned-intent-" + UUID().uuidString
        let intent: [String: Any] = ["owner": "A", "workout": "W", "heartRecordingId": planned]
        // Register the owner and exact native ID before invoking the recorder.
        try CraftPersistentStorage.set("draft", data: JSONSerialization.data(withJSONObject: intent), prefix: prefix, storageDirectory: directory)
        let monitor = CraftHeartRate(recordingDirectory: directory)
        _ = try await recordingCall(monitor, "startRecording", ["recordingId": planned])
        // Deliberately discard the start response. A later write cannot be the
        // only place where the app learns which native recording it owns.
        let samples = Data("{\"timestamp\":1000,\"bpm\":140}\n".utf8)
        let track = directory.appendingPathComponent("craft-heart-rate-recording.jsonl")
        try samples.write(to: track)
        XCTAssertThrowsError(try CraftPersistentStorage.compareAndSet("draft", expected: intent, value: ["owner": "A", "completed": true], prefix: prefix, storageDirectory: directory, writer: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }))
        let saved = try XCTUnwrap(CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory))
        let reopened = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(reopened["heartRecordingId"] as? String, planned)
        let restored = CraftHeartRate(recordingDirectory: directory)
        let state = try await recordingCall(restored, "getRecordingState", ["expectedId": planned]) as? [String: Any]
        XCTAssertEqual(state?["id"] as? String, planned)
        let read = try await recordingCall(restored, "readRecording", ["expectedId": planned]) as? [[String: Any]]
        XCTAssertEqual(read?.first?["bpm"] as? Int, 140)
        _ = try await recordingCall(restored, "stopRecording", ["expectedId": planned])
        _ = try await recordingCall(restored, "acknowledgeRecording", ["expectedId": planned])
        do { _ = try await recordingCall(restored, "startRecording", ["recordingId": planned]); XCTFail("reused acknowledged ID") }
        catch let error as CraftHeartRateError { XCTAssertEqual(error.code, "RECORDING_CONFLICT") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: track.path))
    }

    func testStartingAgainPreservesTheActiveRecordingAndItsPersistedSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CraftHeartRate(recordingDirectory: directory)
        let initial = try await recordingCall(first, "startRecording") as? [String: Any]
        let id = try XCTUnwrap(initial?["id"] as? String)
        let samples = Data("{\"timestamp\":1000,\"bpm\":140}\n".utf8)
        let file = directory.appendingPathComponent("craft-heart-rate-recording.jsonl")
        try samples.write(to: file)
        // Restore through the production disk reader, as after account handoff or relaunch.
        let restored = CraftHeartRate(recordingDirectory: directory)
        do {
            _ = try await recordingCall(restored, "startRecording")
            XCTFail("a second start replaced an active recording")
        } catch let error as CraftHeartRateError {
            XCTAssertEqual(error.code, "RECORDING_ALREADY_ACTIVE")
        }
        let state = try await recordingCall(restored, "getRecordingState") as? [String: Any]
        XCTAssertEqual(state?["id"] as? String, id)
        XCTAssertEqual(state?["active"] as? Bool, true)
        XCTAssertEqual(state?["sampleCount"] as? Int, 1)
        XCTAssertEqual(try Data(contentsOf: file), samples)
    }

    func testStaleIdentityCannotReadPauseResumeOrStopAnotherRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = CraftHeartRate(recordingDirectory: directory)
        let first = try await recordingCall(monitor, "startRecording") as? [String: Any]
        let oldId = try XCTUnwrap(first?["id"] as? String)
        _ = try await recordingCall(monitor, "stopRecording", ["expectedId": oldId])
        let second = try await recordingCall(monitor, "startRecording") as? [String: Any]
        let newId = try XCTUnwrap(second?["id"] as? String)
        XCTAssertNotEqual(oldId, newId)
        let samples = Data("{\"timestamp\":2000,\"bpm\":150}\n".utf8)
        let file = directory.appendingPathComponent("craft-heart-rate-recording.jsonl")
        try samples.write(to: file)
        let restored = CraftHeartRate(recordingDirectory: directory)
        for method in ["pauseRecording", "resumeRecording"] {
            do {
                _ = try await recordingCall(restored, method, ["expectedId": oldId])
                XCTFail("\(method) accepted a stale owner")
            } catch let error as CraftHeartRateError {
                XCTAssertEqual(error.code, "RECORDING_CONFLICT", method)
            }
            let state = try await recordingCall(restored, "getRecordingState") as? [String: Any]
            XCTAssertEqual(state?["id"] as? String, newId, method)
            XCTAssertEqual(state?["active"] as? Bool, true, method)
            XCTAssertEqual(state?["paused"] as? Bool, false, method)
            XCTAssertEqual(try Data(contentsOf: file), samples, method)
        }
        _ = try await recordingCall(restored, "pauseRecording", ["expectedId": newId])
        _ = try await recordingCall(restored, "resumeRecording", ["expectedId": newId])
        let read = try await recordingCall(restored, "readRecording", ["expectedId": newId]) as? [[String: Any]]
        XCTAssertEqual(read?.first?["bpm"] as? Int, 150)
        let stopped = try await recordingCall(restored, "stopRecording", ["expectedId": newId]) as? [String: Any]
        XCTAssertEqual(stopped?["id"] as? String, newId)
        XCTAssertEqual(stopped?["active"] as? Bool, false)
        XCTAssertEqual((stopped?["samples"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), samples)
        let completed = CraftHeartRate(recordingDirectory: directory)
        let recovered = try await recordingCall(completed, "getRecordingState") as? [String: Any]
        XCTAssertEqual(recovered?["id"] as? String, newId)
        XCTAssertEqual(recovered?["active"] as? Bool, false)
        let retry = try await recordingCall(completed, "stopRecording", ["expectedId": newId]) as? [String: Any]
        XCTAssertEqual((retry?["samples"] as? [[String: Any]])?.count, 1)
        _ = try await recordingCall(completed, "startRecording")
    }

    func testAUint8RateWithNothingElse() {
        XCTAssertEqual(CraftHeartRateMeasurement.parse([0x00, 72]), CraftHeartRateMeasurement(bpm: 72, sensorContact: nil, energyExpended: nil, rrIntervals: []))
    }

    func testAUint16Rate() {
        XCTAssertEqual(CraftHeartRateMeasurement.parse([0x01, 0x2C, 0x01])?.bpm, 300)
    }

    func testSensorContactOnlyWhenTheStrapReportsIt() {
        XCTAssertEqual(CraftHeartRateMeasurement.parse([0x06, 80])?.sensorContact, true)
        XCTAssertEqual(CraftHeartRateMeasurement.parse([0x04, 80])?.sensorContact, false)
        XCTAssertNil(CraftHeartRateMeasurement.parse([0x02, 80])?.sensorContact)
    }

    func testEnergyThenRRIntervalsInMilliseconds() {
        // 150 bpm, 258 kJ, RR 1024/1024 s and 512/1024 s.
        let reading = CraftHeartRateMeasurement.parse([0x18, 150, 0x02, 0x01, 0x00, 0x04, 0x00, 0x02])
        XCTAssertEqual(reading?.bpm, 150)
        XCTAssertEqual(reading?.energyExpended, 258)
        XCTAssertEqual(reading?.rrIntervals, [1000, 500])
        // A trailing odd byte is not half an interval.
        XCTAssertEqual(CraftHeartRateMeasurement.parse([0x10, 60, 0x00, 0x04, 0x01])?.rrIntervals, [1000])
    }

    func testAPayloadShorterThanItsFlagsSayIsNoReading() {
        XCTAssertNil(CraftHeartRateMeasurement.parse([UInt8]()))
        XCTAssertNil(CraftHeartRateMeasurement.parse([0x01, 0x2C]))
        XCTAssertNil(CraftHeartRateMeasurement.parse([0x08, 60, 0x01]))
    }

    func testTheSimulatorsPayloadsDecodeLikeAStraps() {
        let reading = CraftHeartRateMeasurement.parse(CraftHeartRateMeasurement.encode(bpm: 142, sensorContact: true, rrIntervals: [422.5]))
        XCTAssertEqual(reading?.bpm, 142)
        XCTAssertEqual(reading?.sensorContact, true)
        XCTAssertEqual(reading?.rrIntervals.first ?? 0, 422.5, accuracy: 1)
        XCTAssertEqual(CraftHeartRateMeasurement.parse(CraftHeartRateMeasurement.encode(bpm: 260))?.bpm, 260)
    }

    func testTheSimulatorsBeatsVaryWithTheBreathAndGiveItsRate() {
        var reached: Double = 0
        let intervals = CraftHeartRate.simulatedIntervals(rate: 60, from: &reached, until: 30_000, noise: { 0 })
        XCTAssertGreaterThanOrEqual(reached, 30_000)
        XCTAssertEqual(intervals.reduce(0, +), reached, accuracy: 0.001)
        // About a second apart at 60 bpm, closer on the in-breath and wider on the out-breath.
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        XCTAssertEqual(mean, 1000, accuracy: 15)
        XCTAssertGreaterThan((intervals.max() ?? 0) - (intervals.min() ?? 0), 50)
        XCTAssertLessThan((intervals.max() ?? 0) - (intervals.min() ?? 0), 90)
        // Successive beats differ, so RMSSD is not zero.
        let squares = zip(intervals.dropFirst(), intervals).map { ($0 - $1) * ($0 - $1) }
        XCTAssertGreaterThan((squares.reduce(0, +) / Double(squares.count)).squareRoot(), 5)
    }

    func testReconnectRecoversAQuietBroadcastWithoutReplacingItsRecording() async throws {
        let defaults = UserDefaults.standard
        let previousFake = defaults.object(forKey: "CraftFakeHeartRateMonitor")
        let previousDevice = defaults.object(forKey: "CraftHeartRate.lastDevice")
        defaults.set(true, forKey: "CraftFakeHeartRateMonitor")
        defer {
            defaults.set(previousFake, forKey: "CraftFakeHeartRateMonitor")
            defaults.set(previousDevice, forKey: "CraftHeartRate.lastDevice")
        }
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let monitor = CraftHeartRate(now: { time })
        var connections: [String] = []
        monitor.pageSink = { event in
            if let connection = event["connection"] as? String { connections.append(connection) }
            return true
        }
        func call(_ method: String, _ args: [Any] = []) async throws -> [String: Any] {
            try await withCheckedThrowingContinuation { continuation in
                monitor.perform(method: method, args: args) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? [String: Any] ?? [:])
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        _ = try await call("connect", [["id": "00000000-0000-4000-8000-00000000180D"]])
        let recording = try await call("startRecording")
        connections.removeAll()
        _ = try await call("reconnect")
        XCTAssertFalse(connections.contains("reconnecting"), "a healthy subscription must be retained")
        // The link remains connected, but Garmin's broadcast stops delivering.
        time = time.addingTimeInterval(31)
        _ = try await call("reconnect")
        XCTAssertTrue(connections.contains("reconnecting"))
        let continued = try await call("getRecordingState")
        XCTAssertEqual(continued["active"] as? Bool, true)
        XCTAssertEqual(continued["id"] as? String, recording["id"] as? String)
        let recovered = expectation(description: "fresh readings resume after rebuilding the subscription")
        recovered.assertForOverFulfill = false
        monitor.pageSink = { event in
            if event["type"] as? String == "reading" { recovered.fulfill() }
            return true
        }
        await fulfillment(of: [recovered], timeout: 5)
        let restored = try await call("getState")
        XCTAssertNotNil(restored["bpm"] as? Int)
        let saved = try await call("stopRecording")
        XCTAssertGreaterThan((saved["samples"] as? [[String: Any]])?.count ?? 0, 0)
        _ = try await call("disconnect", [["forget": true]])
        time = time.addingTimeInterval(31)
        let forgotten = try await call("getState")
        XCTAssertEqual(forgotten["connection"] as? String, "disconnected")
        XCTAssertTrue(forgotten["lastDevice"] is NSNull)
    }

    func testTheModuleAnswersOnlyWhenTheAppReadsAStrap() async {
        let off = await withCheckedContinuation { continuation in
            CraftNativeActions.perform(requestToken: UUID().uuidString, version: craftNativeCapabilityProtocolVersion, module: "HeartRate", method: "getState", args: [], config: CraftConfig()) { continuation.resume(returning: $0) }
        }
        guard case .failure(let error) = off else { return XCTFail("a build without enableHeartRate answered") }
        XCTAssertEqual(error.code, "CAPABILITY_DISABLED")

        var config = CraftConfig()
        config.enableHeartRate = true
        XCTAssertTrue(CraftNativeActions.capabilities(config: config).contains("heartRate"))
        let on = await withCheckedContinuation { continuation in
            CraftNativeActions.perform(requestToken: UUID().uuidString, version: craftNativeCapabilityProtocolVersion, module: "HeartRate", method: "getRecordingState", args: [], config: config) { continuation.resume(returning: $0) }
        }
        guard case .success(let value) = on, let state = value as? [String: Any] else { return XCTFail("getRecordingState failed") }
        XCTAssertNotNil(state["active"] as? Bool)
    }
}

/// The actual native Location capability, backed by the coordinator's disk
/// store in a private disposable directory. No account/container is touched.
@MainActor
final class LocationRecordingOwnershipUnitTests: XCTestCase {
    private func call(_ method: String, _ options: [String: Any] = [:]) async throws -> Any {
        var config = CraftConfig()
        config.enableGeolocation = true
        return try await withCheckedThrowingContinuation { continuation in
            CraftNativeActions.perform(requestToken: UUID().uuidString, version: craftNativeCapabilityProtocolVersion,
                module: "Location", method: method, args: [options], config: config) { result in
                continuation.resume(with: result)
            }
        }
    }

    func testPlannedLocationIdentitySurvivesLostResponseAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = CraftConfig()
        config.enableGeolocation = true
        let previous = CraftSwiftShim.coordinator
        defer { CraftSwiftShim.coordinator = previous }
        let initial = CraftWebView.Coordinator(config: config, recordingDirectory: directory)
        defer { withExtendedLifetime(initial) {} }
        CraftSwiftShim.coordinator = initial
        let planned = UUID().uuidString
        _ = try await call("startRecording", ["recordingId": planned])
        let track = directory.appendingPathComponent("craft-location-recording.jsonl")
        let sample = Data("{\"latitude\":1,\"longitude\":2,\"timestamp\":2000}\n".utf8)
        try sample.write(to: track)
        let restored = CraftWebView.Coordinator(config: config, recordingDirectory: directory)
        defer { withExtendedLifetime(restored) {} }
        CraftSwiftShim.coordinator = restored
        let state = try await call("getRecordingState", ["expectedId": planned]) as? [String: Any]
        XCTAssertEqual(state?["id"] as? String, planned)
        let read = try await call("readRecording", ["expectedId": planned]) as? [[String: Any]]
        XCTAssertEqual(read?.count, 1)
        _ = try await call("stopRecording", ["expectedId": planned])
        do { _ = try await call("startRecording", ["recordingId": planned]); XCTFail("reused completed location ID") }
        catch let error as CraftNativeActionError { XCTAssertEqual(error.code, "RECORDING_CONFLICT") }
        XCTAssertEqual(try Data(contentsOf: track), sample)
        _ = try await call("acknowledgeRecording", ["expectedId": planned])
        do { _ = try await call("startRecording", ["recordingId": planned]); XCTFail("reused acknowledged location ID") }
        catch let error as CraftNativeActionError { XCTAssertEqual(error.code, "RECORDING_CONFLICT") }
    }

    func testStaleNativeLocationCallsPreserveTheRestoredOwnerAndTrack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("craft-location-recording-state.json")
        let trackURL = directory.appendingPathComponent("craft-location-recording.jsonl")
        let state: [String: Any] = ["id": "recording-B", "active": true, "paused": true, "startedAt": 1000]
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        let track = Data("{\"latitude\":1,\"longitude\":2,\"timestamp\":2000}\n".utf8)
        try track.write(to: trackURL)
        var config = CraftConfig()
        config.enableGeolocation = true
        let coordinator = CraftWebView.Coordinator(config: config, recordingDirectory: directory)
        let previous = CraftSwiftShim.coordinator
        CraftSwiftShim.coordinator = coordinator
        defer { CraftSwiftShim.coordinator = previous }
        for method in ["pauseRecording", "resumeRecording", "stopRecording", "readRecording"] {
            do {
                _ = try await call(method, ["expectedId": "recording-A"])
                XCTFail("\(method) accepted a stale owner")
            } catch let error as CraftNativeActionError { XCTAssertEqual(error.code, "RECORDING_CONFLICT", method) }
            XCTAssertEqual(try Data(contentsOf: trackURL), track, method)
        }
        do { _ = try await call("startRecording"); XCTFail("start replaced a restored recording") }
        catch let error as CraftNativeActionError { XCTAssertEqual(error.code, "RECORDING_ALREADY_ACTIVE") }
        XCTAssertEqual(try Data(contentsOf: trackURL), track)
        let read = try await call("readRecording", ["expectedId": "recording-B"]) as? [[String: Any]]
        XCTAssertEqual(read?.count, 1)
        let stopped = try await call("stopRecording", ["expectedId": "recording-B"]) as? [String: Any]
        XCTAssertEqual(stopped?["id"] as? String, "recording-B")
        XCTAssertEqual(stopped?["active"] as? Bool, false)
    }
}

@MainActor
final class CompletedRecordingRecoveryUnitTests: XCTestCase {
    private func call(_ monitor: CraftHeartRate, _ method: String, _ options: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            monitor.perform(method: method, args: [options]) { continuation.resume(with: $0) }
        }
    }

    func testCompletedOwnerSurvivesAnotherStartAndRelaunchUntilAcknowledged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CraftHeartRate(recordingDirectory: directory)
        let started = try await call(first, "startRecording") as? [String: Any]
        let a = try XCTUnwrap(started?["id"] as? String)
        let file = directory.appendingPathComponent("craft-heart-rate-recording.jsonl")
        try Data("{\"timestamp\":1000,\"bpm\":140}\n".utf8).write(to: file)
        _ = try await call(first, "stopRecording", ["expectedId": a])
        // The app dies before it durably checkpoints A's stop response.
        let second = CraftHeartRate(recordingDirectory: directory)
        let next = try await call(second, "startRecording") as? [String: Any]
        let b = try XCTUnwrap(next?["id"] as? String)
        XCTAssertNotEqual(a, b)
        let dataB = Data("{\"timestamp\":2000,\"bpm\":170}\n".utf8)
        try dataB.write(to: file)
        let restored = CraftHeartRate(recordingDirectory: directory)
        let stateA = try await call(restored, "getRecordingState", ["expectedId": a]) as? [String: Any]
        XCTAssertEqual(stateA?["id"] as? String, a)
        XCTAssertEqual(stateA?["active"] as? Bool, false)
        let readA = try await call(restored, "readRecording", ["expectedId": a]) as? [[String: Any]]
        XCTAssertEqual(readA?.first?["bpm"] as? Int, 140)
        let stoppedA = try await call(restored, "stopRecording", ["expectedId": a]) as? [String: Any]
        XCTAssertEqual(stoppedA?["id"] as? String, a)
        XCTAssertEqual(try Data(contentsOf: file), dataB)
        for method in ["pauseRecording", "resumeRecording"] {
            do { _ = try await call(restored, method, ["expectedId": a]); XCTFail("stale owner changed B") }
            catch let error as CraftHeartRateError { XCTAssertEqual(error.code, "RECORDING_CONFLICT") }
        }
        let firstAcknowledgement = try await call(restored, "acknowledgeRecording", ["expectedId": a]) as? Bool
        let repeatedAcknowledgement = try await call(restored, "acknowledgeRecording", ["expectedId": a]) as? Bool
        XCTAssertEqual(firstAcknowledgement, true)
        XCTAssertEqual(repeatedAcknowledgement, true)
        do { _ = try await call(restored, "readRecording", ["expectedId": a]); XCTFail("acknowledged data reappeared") }
        catch let error as CraftHeartRateError { XCTAssertEqual(error.code, "RECORDING_NOT_FOUND") }
        let stateB = try await call(restored, "getRecordingState", ["expectedId": b]) as? [String: Any]
        XCTAssertEqual(stateB?["active"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: file), dataB)
    }

    func testArchiveFailureRefusesReplacementAndPreservesTheOldSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let state: [String: Any] = ["id": id, "active": false, "paused": false, "startedAt": 1000]
        try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("craft-heart-rate-recording-state.json"))
        let samples = Data("{\"timestamp\":1000,\"bpm\":140}\n".utf8)
        let file = directory.appendingPathComponent("craft-heart-rate-recording.jsonl")
        try samples.write(to: file)
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        // A real failed archive-file read/write, rather than a successful empty backup.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("craft-heart-rate-completed-\(hash).json"), withIntermediateDirectories: true)
        let monitor = CraftHeartRate(recordingDirectory: directory)
        do { _ = try await call(monitor, "startRecording"); XCTFail("replacement ignored archive failure") }
        catch let error as CraftHeartRateError { XCTAssertEqual(error.code, "RECORDING_STORAGE_ERROR") }
        XCTAssertEqual(try Data(contentsOf: file), samples)
        let restored = try await call(monitor, "getRecordingState") as? [String: Any]
        XCTAssertEqual(restored?["id"] as? String, id)
        XCTAssertEqual(restored?["active"] as? Bool, false)
    }
}

@MainActor
final class PersistentRecordingCheckpointUnitTests: XCTestCase {
    func testSecureUuidUsesTheNativePlatformWithoutJavaScriptEntropy() async throws {
        XCTAssertTrue(CraftNativeActions.capabilities(config: CraftConfig()).contains("crypto"))
        func create() async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                CraftNativeActions.perform(requestToken: UUID().uuidString, version: craftNativeCapabilityProtocolVersion, module: "Crypto", method: "randomUUID", args: [], config: CraftConfig()) { result in
                    switch result {
                    case .success(let value):
                        guard let id = value as? String, UUID(uuidString: id) != nil else { return continuation.resume(throwing: NSError(domain: "UUID", code: 1)) }
                        continuation.resume(returning: id)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        let first = try await create()
        let second = try await create()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Array(first)[14], "4")
        XCTAssertTrue("89ab".contains(Array(first)[19]))
    }

    @MainActor
    func testCancelledQueuedStorageWritePreservesThePreviousCheckpoint() async throws {
        let key = "checkpoint-cancel-" + UUID().uuidString
        defer { try? CraftPersistentStorage.set(key, data: nil, prefix: "craft.native.storage.") }
        func call(_ method: String, _ args: [Any]) async throws -> Any {
            try await withCheckedThrowingContinuation { continuation in
                CraftNativeActions.perform(requestToken: UUID().uuidString, version: craftNativeCapabilityProtocolVersion, module: "Storage", method: method, args: args, config: CraftConfig()) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        _ = try await call("set", [key, ["generation": 1]])
        let token = UUID().uuidString
        var answered = false
        // Both calls execute on main before its queued storage write can run.
        CraftNativeActions.perform(requestToken: token, version: craftNativeCapabilityProtocolVersion, module: "Storage", method: "set", args: [key, ["generation": 2]], config: CraftConfig()) { _ in answered = true }
        CraftNativeActions.cancel(requestToken: token)
        let restored = try await call("get", [key]) as? [String: Any]
        XCTAssertEqual(restored?["generation"] as? Int, 1)
        XCTAssertFalse(answered, "Cancelled requests must not acknowledge a checkpoint")
    }

    func testDisposedRetainedScreenCannotCommitItsQueuedCheckpoint() async throws {
        let key = "checkpoint-screen-close-" + UUID().uuidString
        defer { try? CraftPersistentStorage.set(key, data: nil, prefix: "craft.native.storage.") }
        func call(_ method: String, _ args: [Any]) async throws -> Any {
            try await withCheckedThrowingContinuation { continuation in
                CraftNativeActions.perform(requestToken: UUID().uuidString, version: craftNativeCapabilityProtocolVersion, module: "Storage", method: method, args: args, config: CraftConfig()) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        _ = try await call("set", [key, ["generation": 1]])
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.evaluateScript("typeof craftNativePostMessage")?.toString(), "function")
        let message: [String: Any] = ["type": "API_REQUEST", "id": UUID().uuidString, "payload": ["version": craftNativeCapabilityProtocolVersion, "module": "Storage", "method": "set", "args": [key, ["generation": 2]]]]
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: message), encoding: .utf8))
        controller.evaluateScript("craftNativePostMessage(JSON.stringify(\(json)))")
        if CraftNativeScriptThread.isBackground {
            // The script's request reaches main before this disappearance,
            // while the request's own queued write comes after it.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { controller.viewDidDisappear(false); continuation.resume() }
            }
        } else {
            controller.viewDidDisappear(false)
        }
        let restored = try await call("get", [key]) as? [String: Any]
        XCTAssertEqual(restored?["generation"] as? Int, 1)
        controller.evaluateScript("craftNativePostMessage(JSON.stringify(\(json)))")
        let afterClose = try await call("get", [key]) as? [String: Any]
        XCTAssertEqual(afterClose?["generation"] as? Int, 1, "A closed retained context cannot start another storage request")
        let syncResult = controller.evaluateScript("(function() { try { craft.storage.setSync((\(json)).payload.args[0], { generation: 3 }); return 'accepted'; } catch (error) { return 'closed'; } })()")?.toString()
        XCTAssertEqual(syncResult, "closed", "The synchronous storage API also belongs to the native screen lifetime")
        let syncReadResult = controller.evaluateScript("(function() { try { craft.storage.getSync((\(json)).payload.args[0]); return 'accepted'; } catch (error) { return 'closed'; } })()")?.toString()
        XCTAssertEqual(syncReadResult, "closed", "A closed screen cannot read synchronous storage either")
        let afterSyncClose = try await call("get", [key]) as? [String: Any]
        XCTAssertEqual(afterSyncClose?["generation"] as? Int, 1, "A closed synchronous host must preserve the checkpoint")
        withExtendedLifetime(controller) {}
    }

    func testPublicStorageCapabilityRoutesAtomicCheckpointsAndDeletion() async throws {
        let key = "checkpoint-wire-" + UUID().uuidString
        defer { try? CraftPersistentStorage.set(key, data: nil, prefix: "craft.native.storage.") }
        func call(_ method: String, _ args: [Any]) async throws -> Any {
            try await withCheckedThrowingContinuation { continuation in
                CraftNativeActions.perform(requestToken: UUID().uuidString, version: craftNativeCapabilityProtocolVersion, module: "Storage", method: method, args: args, config: CraftConfig()) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        XCTAssertTrue(CraftNativeActions.capabilities(config: CraftConfig()).contains("storageCompareAndSet"))
        XCTAssertTrue(CraftNativeActions.capabilities(config: CraftConfig()).contains("storageSetIfAbsent"))
        async let first = call("setIfAbsent", [key, ["owner": "A"]])
        async let second = call("setIfAbsent", [key, ["owner": "A"]])
        let responses = try await (first, second)
        let created = [responses.0, responses.1].compactMap { $0 as? Bool }
        XCTAssertEqual(created.filter { $0 }.count, 1)
        XCTAssertEqual(created.filter { !$0 }.count, 1)
        let saved = try await call("compareAndSet", [key, ["owner": "A"], ["owner": "A", "completed": true]])
        XCTAssertEqual(saved as? Bool, true)
        _ = try await call("remove", [key])
        let deleted = try await call("compareAndSet", [key, ["owner": "A", "completed": true], ["owner": "A"]])
        XCTAssertEqual(deleted as? Bool, false)
        let absent = try await call("get", [key])
        XCTAssertTrue(absent is NSNull)
        _ = try await call("setIfAbsent", [key, NSNull()])
        let existingNull = try await call("setIfAbsent", [key, ["owner": "B"]])
        XCTAssertEqual(existingNull as? Bool, false)
    }

    func testConditionalCheckpointRespectsDeletionFeedbackTypesAndDiskFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefix = "craft-cas-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removeObject(forKey: prefix + "draft") }
        let old: [String: Any] = ["owner": "A", "feedback": "latest", "visits": 1]
        let next: [String: Any] = ["owner": "A", "feedback": "latest", "visits": 2]
        XCTAssertFalse(try CraftPersistentStorage.compareAndSet("draft", expected: NSNull(), value: next, prefix: prefix, storageDirectory: directory))
        try CraftPersistentStorage.set("draft", data: JSONSerialization.data(withJSONObject: old), prefix: prefix, storageDirectory: directory)
        XCTAssertFalse(try CraftPersistentStorage.compareAndSet("draft", expected: ["owner": "A", "feedback": "stale", "visits": 1], value: next, prefix: prefix, storageDirectory: directory))
        XCTAssertThrowsError(try CraftPersistentStorage.compareAndSet("draft", expected: old, value: next, prefix: prefix, storageDirectory: directory, writer: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }))
        let stillOld = try JSONSerialization.jsonObject(with: XCTUnwrap(CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory)))
        XCTAssertTrue(CraftPersistentStorage.jsonEqual(stillOld, old))
        XCTAssertTrue(try CraftPersistentStorage.compareAndSet("draft", expected: ["visits": 1, "feedback": "latest", "owner": "A"], value: next, prefix: prefix, storageDirectory: directory))
        try CraftPersistentStorage.set("draft", data: nil, prefix: prefix, storageDirectory: directory)
        XCTAssertFalse(try CraftPersistentStorage.compareAndSet("draft", expected: next, value: old, prefix: prefix, storageDirectory: directory))
        XCTAssertNil(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory))
        XCTAssertThrowsError(try CraftPersistentStorage.setIfAbsent("draft", value: old, prefix: prefix, storageDirectory: directory, writer: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }))
        XCTAssertNil(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory))
        XCTAssertFalse(CraftPersistentStorage.jsonEqual(true, 1))
        XCTAssertFalse(CraftPersistentStorage.jsonEqual([1, 2], [2, 1]))
    }

    func testCorruptLegacyValueDoesNotBecomeAMissingDraft() throws {
        let prefix = "craft-corrupt-test-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { UserDefaults.standard.removeObject(forKey: prefix + "draft"); try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.set(Data("not JSON".utf8), forKey: prefix + "draft")
        XCTAssertThrowsError(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory))
    }

    func testFailedLegacyMigrationKeepsTheReadableCheckpointAndRejectsNewWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefix = "craft-checkpoint-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removeObject(forKey: prefix + "draft") }
        // A real filesystem refusal: the destination directory is a file.
        try Data("occupied".utf8).write(to: directory)
        let old = Data("{\"owner\":\"A\"}".utf8)
        UserDefaults.standard.set(old, forKey: prefix + "draft")
        XCTAssertEqual(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory), old)
        XCTAssertThrowsError(try CraftPersistentStorage.set("draft", data: Data("{\"owner\":\"B\"}".utf8), prefix: prefix, storageDirectory: directory))
        XCTAssertEqual(UserDefaults.standard.data(forKey: prefix + "draft"), old)
        try FileManager.default.removeItem(at: directory)
        XCTAssertEqual(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testFailedDurableCheckpointLeavesPreviousValueAndLegacyCacheIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefix = "craft-checkpoint-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removeObject(forKey: prefix + "draft") }
        let old = Data("{\"owner\":\"A\"}".utf8)
        let next = Data("{\"owner\":\"A-complete\"}".utf8)
        try CraftPersistentStorage.set("draft", data: old, prefix: prefix, storageDirectory: directory)
        XCTAssertThrowsError(try CraftPersistentStorage.set("draft", data: next, prefix: prefix, storageDirectory: directory, writer: { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }))
        XCTAssertEqual(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory), old)
        XCTAssertEqual(UserDefaults.standard.data(forKey: prefix + "draft"), old)
        // A successful return has already persisted the authoritative bytes.
        try CraftPersistentStorage.set("draft", data: next, prefix: prefix, storageDirectory: directory)
        UserDefaults.standard.removeObject(forKey: prefix + "draft")
        XCTAssertEqual(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory), next)
    }

    func testMigrationIsDurableAndRemovalTombstonePreventsLegacyResurrection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefix = "craft-checkpoint-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removeObject(forKey: prefix + "draft") }
        let old = Data("{\"owner\":\"A\"}".utf8)
        UserDefaults.standard.set(old, forKey: prefix + "draft")
        XCTAssertEqual(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
        UserDefaults.standard.removeObject(forKey: prefix + "draft")
        XCTAssertEqual(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory), old)
        try CraftPersistentStorage.set("draft", data: nil, prefix: prefix, storageDirectory: directory)
        UserDefaults.standard.set(old, forKey: prefix + "draft")
        XCTAssertNil(try CraftPersistentStorage.get("draft", prefix: prefix, storageDirectory: directory))
    }
}
