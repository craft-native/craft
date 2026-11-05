import { expect, test } from 'bun:test'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { anchorCanQualify, HELD_GESTURE_SECONDS, selectHeldVideoFrame, validateHeldVideoFrame } from '../scripts/held-viewer-video'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

const window = { recordSpawnWall: 100, recordingStartedObservedWall: 100.5, synthesisWall: 102, releasedWall: 108 }
const firstPTS = { value: 0, timescale: 600 }
const selectedPTS = { value: 2400, timescale: 600 }

test('actual decoded frame qualifies only when both first-frame wall bounds fit inside the real hold', () => {
  expect(validateHeldVideoFrame({ ...window, firstPTS, selectedPTS, actualPTS: { value: 4000, timescale: 1000 } }))
    .toEqual({ frameWallEarliest: 104, frameWallLatest: 104.5, frameOffsetFromFirstPTS: 4 })
  expect(selectHeldVideoFrame(window, [firstPTS, { value: 600, timescale: 600 }, selectedPTS])).toEqual(selectedPTS)
})

test('static frame zero cannot qualify as a middle-of-recording image', () => {
  expect(() => selectHeldVideoFrame(window, [firstPTS])).toThrow('No decoded frame')
  expect(() => validateHeldVideoFrame({ ...window, firstPTS, selectedPTS: firstPTS, actualPTS: firstPTS })).toThrow('whole frame capture interval')
})

test('requested time cannot replace extractor actualTime or exact rational equivalence', () => {
  expect(() => validateHeldVideoFrame({ ...window, firstPTS, selectedPTS, actualPTS: firstPTS })).toThrow('actual PTS differs')
  expect(() => validateHeldVideoFrame({ ...window, firstPTS, selectedPTS, actualPTS: { value: 2401, timescale: 600 } })).toThrow('actual PTS differs')
})

test('first-frame uncertainty must fit completely, with strict synthesis and release boundaries', () => {
  const input = { ...window, firstPTS, selectedPTS, actualPTS: selectedPTS }
  expect(() => validateHeldVideoFrame({ ...input, recordingStartedObservedWall: 102, releasedWall: 106 })).toThrow('six-second')
  expect(() => validateHeldVideoFrame({ ...input, recordSpawnWall: 98 })).toThrow('whole frame')
  expect(() => validateHeldVideoFrame({ ...input, recordingStartedObservedWall: 102, releasedWall: 108, selectedPTS: { value: 3600, timescale: 600 }, actualPTS: { value: 3600, timescale: 600 } })).toThrow('whole frame')
  expect(() => validateHeldVideoFrame({ ...input, recordingStartedObservedWall: 102.1 })).toThrow('before')
})

test('invalid clocks and media times fail closed, including unsafe integers and nonzero source origins', () => {
  const input = { ...window, firstPTS, selectedPTS, actualPTS: selectedPTS }
  for (const bad of [Number.NaN, Number.POSITIVE_INFINITY, -1])
    expect(() => validateHeldVideoFrame({ ...input, synthesisWall: bad })).toThrow()
  for (const bad of [{ value: 1, timescale: 0 }, { value: 1.5, timescale: 600 }, { value: Number.MAX_SAFE_INTEGER + 1, timescale: 600 }])
    expect(() => validateHeldVideoFrame({ ...input, actualPTS: bad })).toThrow('rational')
  expect(validateHeldVideoFrame({ ...input, firstPTS: { value: 6000, timescale: 600 }, selectedPTS: { value: 8400, timescale: 600 }, actualPTS: { value: 14000, timescale: 1000 } }).frameOffsetFromFirstPTS).toBe(4)
  expect(() => selectHeldVideoFrame(window, [])).toThrow('no decoded')
})

test('sparse viewer frame before 750ms remains valid when its whole interval is strictly within the hold', () => {
  const frame = { value: 1350, timescale: 600 }
  expect(validateHeldVideoFrame({ ...window, firstPTS, selectedPTS: frame, actualPTS: frame }))
    .toEqual({ frameWallEarliest: 102.25, frameWallLatest: 102.75, frameOffsetFromFirstPTS: 2.25 })
})

test.skipIf(process.platform !== 'darwin')('public AVFoundation extractor verifies actual media frames and rejects static footage', () => {
  const dir = createTempDir('craft-held-video-test-')
  const run = (args: string[]) => Bun.spawnSync(args, { stdout: 'pipe', stderr: 'pipe', timeout: 20_000 })
  try {
    const generator = join(dir, 'media.swift'), movieTool = join(dir, 'media'), extractor = join(dir, 'extract')
    // Synthetic media only: these pixels test source-frame identity, not a
    // native Large Content Viewer, an app, a gesture, or simulator acceptance.
    // Use software H.264 explicitly; the dense sample-table regression must
    // not depend on a virtual runner's hardware video encoder.
    writeFileSync(generator, `import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox
let mode = CommandLine.arguments[2]
// Keep progress on a separate queue: a stalled media callback must not also
// silence the diagnostic heartbeat. These are synthetic fixture counters only.
final class EncodingProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var appended = 0, callbacks = 0
    private var phase = "configuring"
    private var terminal = false
    func update(appended: Int? = nil, callback: Bool = false, phase: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let appended { self.appended = appended }
        if callback { callbacks += 1 }
        if let phase { self.phase = phase }
    }
    func emit(_ event: String, writer: AVAssetWriter, input: AVAssetWriterInput) {
        lock.lock(); defer { lock.unlock() }
        if terminal { return }
        if event == "completed" || event == "failed" || event == "append-failed" { terminal = true }
        let record: [String: Any] = ["event": event, "mode": mode, "phase": phase,
            "elapsedMs": Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
            "appended": appended, "callbacks": callbacks, "status": writer.status.rawValue,
            "ready": input.isReadyForMoreMediaData, "error": writer.error?.localizedDescription ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            FileHandle.standardError.write(data + Data([10]))
        }
    }
}
let progress = EncodingProgress()
let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: CommandLine.arguments[1]), fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64, AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]])
// Supply the encoder's native NV12 planes directly, without a GPU colour conversion.
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
writer.add(input)
progress.emit("configured", writer: writer, input: input)
guard writer.startWriting() else { fatalError("Cannot write synthetic media") }
writer.startSession(atSourceTime: .zero)
let heartbeat = DispatchSource.makeTimerSource(queue: .global())
heartbeat.schedule(deadline: .now() + 1, repeating: 1)
heartbeat.setEventHandler { progress.emit("progress", writer: writer, input: input) }
heartbeat.resume()
defer { heartbeat.cancel() }
let originalSamples = mode == "static" ? [0] : mode == "dense-late" ? Array(0..<15013) : mode == "late" ? [0, 1104, 1106] : mode == "sparse" ? [0, 4, 6] : Array(0..<7)
let timescale: CMTimeScale = mode == "dense-late" ? 12 : 1
guard let pool = adaptor.pixelBufferPool else { fatalError("No pixel buffer pool") }
// Immutable source pictures can be retained by multiple pending encodes.
// The dense fixture tests original sample timing, not repeated allocation.
let pictures: [CVPixelBuffer] = (0..<7).map { index in
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { fatalError("No pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), Int32(20 + index * 30), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
    memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}
await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    let queue = DispatchQueue(label: "craft.held-frame-fixture")
    var next = 0, finished = false
    input.requestMediaDataWhenReady(on: queue) {
        if finished { return }
        progress.update(callback: true, phase: "appending")
        while input.isReadyForMoreMediaData {
            if next == originalSamples.count {
                finished = true
                writer.endSession(atSourceTime: CMTime(value: mode == "dense-late" ? 15013 : mode == "late" ? 1107 : 7, timescale: timescale))
                input.markAsFinished()
                progress.update(phase: "finishing")
                progress.emit("input-finished", writer: writer, input: input)
                continuation.resume()
                return
            }
            let index = originalSamples[next]
            guard adaptor.append(pictures[index % 7], withPresentationTime: CMTime(value: Int64(index), timescale: timescale)) else {
                progress.emit("append-failed", writer: writer, input: input)
                fatalError("Cannot append synthetic frame")
            }
            next += 1
            progress.update(appended: next)
        }
    }
}
await writer.finishWriting()
heartbeat.cancel()
progress.emit(writer.status == .completed ? "completed" : "failed", writer: writer, input: input)
guard writer.status == .completed else { fatalError("Synthetic movie incomplete") }
`)
    for (const args of [['xcrun', '--sdk', 'macosx', 'swiftc', generator, '-o', movieTool], ['xcrun', '--sdk', 'macosx', 'swiftc', join(import.meta.dir, '../scripts/held-viewer-frame.swift'), '-o', extractor]]) {
      const result = run(args)
      expect(result.exitCode, result.stderr.toString()).toBe(0)
    }
    for (const mode of ['sparse', 'moving', 'late', 'dense-late', 'static']) {
      const movie = join(dir, `${mode}.mov`), png = join(dir, `${mode}.png`), receipt = join(dir, `${mode}.json`)
      const generatedAt = performance.now()
      const media = run([movieTool, movie, mode])
      console.log(`Generated ${mode} native H.264 fixture in ${(performance.now() - generatedAt).toFixed(0)}ms`)
      expect(media.exitCode, `${mode} generation (${media.signalCode || 'normal exit'}): ${media.stderr.toString()}`).toBe(0)
      const progress = media.stderr.toString().trim().split('\n').filter(line => line.startsWith('{')).map(line => JSON.parse(line))
      expect(progress.at(-1)).toMatchObject({ event: 'completed', mode, status: 2, appended: mode === 'dense-late' ? 15013 : mode === 'static' ? 1 : mode === 'sparse' || mode === 'late' ? 3 : 7 })
      expect(progress.at(-1).callbacks).toBeGreaterThan(0)
      const dense = mode === 'dense-late', late = mode === 'late' || dense
      const result = run([extractor, movie, png, receipt, '100', '100.25', dense ? '1201.125' : late ? '1201' : '101', dense ? '1207.125' : late ? '1207' : '107'])
      const evidence = JSON.parse(readFileSync(receipt, 'utf8'))
      // Trimming a sparse source to a hold range can invent a boundary PTS
      // for the old picture. Retain original stored times even when the
      // hold happens eighteen minutes into a long test-suite recording.
      expect(evidence.samplePTS.map((time: { value: number, timescale: number }) => time.value / time.timescale))
        .toEqual(mode === 'static' ? [0] : dense ? Array.from({ length: 15013 }, (_, index) => index / 12) : late ? [0, 1104, 1106] : mode === 'sparse' ? [0, 4, 6] : [0, 1, 2, 3, 4, 5, 6])
      if (mode !== 'static') {
        expect(result.exitCode, result.stderr.toString()).toBe(0)
        expect(evidence.verified).toBe(true)
        expect(evidence.decodedPTS.map((time: { value: number, timescale: number }) => time.value / time.timescale)).toEqual([0, late ? 1104 : 4])
        expect(validateHeldVideoFrame(evidence)).toMatchObject({ frameWallEarliest: late ? 1204 : 104, frameWallLatest: late ? 1204.25 : 104.25 })
        expect(evidence.actualPTS.value / evidence.actualPTS.timescale).toBe(late ? 1104 : 4)
        expect(evidence.pngSha256).toBe(new Bun.CryptoHasher('sha256').update(readFileSync(png)).digest('hex'))
        expect(evidence.movieSha256).toBe(new Bun.CryptoHasher('sha256').update(readFileSync(movie)).digest('hex'))
      }
      else {
        expect(result.exitCode).toBe(1)
        expect(evidence.verified).toBe(false)
        expect(evidence.error).toContain('No decoded frame')
        expect(existsSync(png)).toBe(false)
      }
    }
  }
  finally { removeTempDir(dir) }
}, 45_000)

// Craft 468's navigation-ui-core failure (#486). Every candidate frame's wall
// interval is exactly as wide as the first-frame bracket, so once that bracket
// is wider than the hold there is nothing to select at any PTS.
const impossible = {
  recordSpawnWall: 1793853473.611,
  recordingStartedObservedWall: 1793853481.376,
  synthesisWall: 1793854651.760,
  releasedWall: 1793854659.450077,
}

test('a first-frame bracket wider than the hold disqualifies every sample', () => {
  const bracket = impossible.recordingStartedObservedWall - impossible.recordSpawnWall
  const hold = impossible.releasedWall - impossible.synthesisWall
  expect(bracket).toBeGreaterThan(hold)
  expect(anchorCanQualify(impossible.recordSpawnWall, impossible.recordingStartedObservedWall)).toBe(false)
  // Not a selection problem: no PTS anywhere in the recording can satisfy it.
  const decoded = Array.from({ length: 240 }, (_, index) => ({ value: index * 600, timescale: 600 }))
  expect(() => selectHeldVideoFrame(impossible, decoded)).toThrow('No decoded frame has its whole capture interval inside the hold')
})

test('the anchor check measures the bracket against the nominal gesture', () => {
  expect(HELD_GESTURE_SECONDS).toBe(6)
  // Strictly inside: a bracket equal to the hold still leaves no room.
  expect(anchorCanQualify(100, 106)).toBe(false)
  expect(anchorCanQualify(100, 105.999)).toBe(true)
  expect(anchorCanQualify(100, 101.2)).toBe(true)
  // An explicit hold overrides the nominal gesture.
  expect(anchorCanQualify(100, 107, 8)).toBe(true)
  expect(anchorCanQualify(100, 107, 6)).toBe(false)
  expect(() => anchorCanQualify(106, 100)).toThrow('ordered first-frame bracket')
  expect(() => anchorCanQualify(100, 106, 0)).toThrow('positive hold')
})
