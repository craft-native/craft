// Public-only extraction of an actual recorded frame during a synthesized hold.
// Encoding finishes later; capture timing comes from decoded PTS and both bounds
// on the recording's first frame, never the process launch timestamp alone.
import Foundation
import AVFoundation
import CoreVideo
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum FrameFailure: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): return message } }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw FrameFailure.invalid(message) }
}

func digest(_ path: String) throws -> String {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    var hash = SHA256()
    while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func timeData(_ time: CMTime) throws -> [String: Any] {
    try require(time.isNumeric && time.timescale > 0 && CMTimeGetSeconds(time).isFinite,
                "Decoded frame has an invalid media timestamp")
    try require(time.value >= -9_007_199_254_740_991 && time.value <= 9_007_199_254_740_991,
                "Decoded media timestamp exceeds the exact JSON integer range")
    return ["value": time.value, "timescale": time.timescale]
}

// Traverse the original sample table, without reading every compressed video
// payload in a long XCTest recording. A sample cursor preserves stored PTS;
// seeking or trimming an asset reader can instead invent a boundary timestamp.
// https://developer.apple.com/documentation/avfoundation/avsamplecursor
func recordedTimes(_ track: AVAssetTrack) throws -> [CMTime] {
    guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else {
        throw FrameFailure.invalid("Recording has no video sample cursor")
    }
    var times: [CMTime] = []
    while true {
        let pts = cursor.presentationTimeStamp
        _ = try timeData(pts)
        times.append(pts)
        let stepped = cursor.stepInDecodeOrder(byCount: 1)
        try require(stepped == 0 || stepped == 1, "Sample cursor could not advance through the original recording")
        if stepped == 0 { break }
    }
    // Stored H.264 samples arrive in decode order; presentation order can differ.
    return times.sorted { CMTimeCompare($0, $1) < 0 }
}

let arguments = CommandLine.arguments
guard arguments.count == 8 else {
    fputs("Expected movie, PNG, receipt, recordSpawnWall, recordingStartedObservedWall, synthesisWall, releasedWall\n", stderr)
    exit(2)
}
let movie = arguments[1], png = arguments[2], receiptPath = arguments[3]
var receipt: [String: Any] = ["verified": false, "movie": movie, "png": png,
                             "extractStartedWall": Date().timeIntervalSince1970,
                             "timingRule": "Both first-frame wall bounds plus actual decoded PTS offset must be strictly inside Synthesize to END."]
do {
    try require([movie, png, receiptPath].allSatisfy { ($0 as NSString).isAbsolutePath }, "Evidence paths must be absolute")
    try require(!FileManager.default.fileExists(atPath: png) && !FileManager.default.fileExists(atPath: receiptPath), "Refusing to overwrite retained frame evidence")
    let values = arguments[4...7].compactMap(Double.init)
    try require(values.count == 4 && values.allSatisfy { $0.isFinite && $0 > 0 }, "Invalid recording or hold wall clocks")
    let spawn = values[0], ready = values[1], synthesis = values[2], end = values[3]
    receipt.merge(["recordSpawnWall": spawn, "recordingStartedObservedWall": ready, "synthesisWall": synthesis, "releasedWall": end]) { _, next in next }
    try require(spawn <= ready && ready <= synthesis && end - synthesis >= 5.5,
                "Recording must acknowledge its first frame before the six-second synthesized hold")
    receipt["movieSha256"] = try digest(movie)
    let asset = AVURLAsset(url: URL(fileURLWithPath: movie), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { throw FrameFailure.invalid("Recording has no video track") }
    let timingStarted = ProcessInfo.processInfo.systemUptime
    let samples = try recordedTimes(track)
    let timingElapsed = ProcessInfo.processInfo.systemUptime - timingStarted
    receipt["sampleTimingMethod"] = "AVSampleCursor"
    receipt["sampleTimingElapsedSeconds"] = timingElapsed
    fputs("Read \(samples.count) original sample timestamps via AVSampleCursor in \(timingElapsed)s\n", stderr)
    receipt["samplePTS"] = try samples.map { try timeData($0) }
    guard let firstSample = samples.first else { throw FrameFailure.invalid("Recording has no video sample") }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    // Both the origin and the selected picture must really decode at their
    // original sample PTS. A requested timestamp alone is never evidence.
    let (_, firstPTS) = try await generator.image(at: firstSample)
    try require(CMTimeCompare(firstPTS, firstSample) == 0, "Decoded first frame differs from the original first sample")
    receipt["firstPTS"] = try timeData(firstPTS)
    receipt["decodedPTS"] = [try timeData(firstPTS)]
    let firstSeconds = CMTimeGetSeconds(firstPTS)
    var selected: CMTime?
    var closest = Double.infinity
    for pts in samples {
        let offset = CMTimeGetSeconds(pts) - firstSeconds
        let earliest = spawn + offset, latest = ready + offset
        if offset >= 0 && earliest > synthesis && latest < end {
            let distance = abs((earliest + latest) / 2 - (synthesis + end) / 2)
            if distance < closest { selected = pts; closest = distance }
        }
    }
    guard let selected else { throw FrameFailure.invalid("No decoded frame has its whole capture interval inside the hold") }
    receipt["selectedPTS"] = try timeData(selected)
    let (image, actual) = try await generator.image(at: selected)
    receipt["decodedPTS"] = [try timeData(firstPTS), try timeData(actual)]
    receipt["actualPTS"] = try timeData(actual)
    try require(CMTimeCompare(actual, selected) == 0, "Extracted actual PTS differs from the selected decoded frame")
    let offset = CMTimeGetSeconds(actual) - firstSeconds
    let earliest = spawn + offset, latest = ready + offset
    try require(earliest > synthesis && latest < end, "Extracted frame uncertainty is outside the synthesized hold")
    receipt.merge(["frameWallEarliest": earliest, "frameWallLatest": latest, "frameOffsetFromFirstPTS": offset,
                   "width": image.width, "height": image.height]) { _, next in next }
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: png) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw FrameFailure.invalid("Cannot create the extracted PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "Could not finalize the extracted PNG")
    receipt["pngSha256"] = try digest(png)
    receipt["verified"] = true
    receipt["visualReviewRequired"] = "The actual extracted PNG must show Apple's system Large Content Viewer."
}
catch { receipt["error"] = String(describing: error) }
receipt["extractFinishedWall"] = Date().timeIntervalSince1970
do {
    let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: URL(fileURLWithPath: receiptPath), options: .withoutOverwriting)
}
catch { fputs("Could not retain frame receipt: \(error)\n", stderr); exit(2) }
if receipt["verified"] as? Bool != true {
    fputs("\(receipt["error"] ?? "Frame evidence did not qualify")\n", stderr)
    exit(1)
}
