import Accelerate
import AVFoundation
import Foundation
import JavaScriptCore
import UIKit

// MARK: - Web Audio on native screens
//
// JavaScriptCore has no Web Audio. A native screen gets the standard
// `AudioContext` API anyway (the script at the end of this file), so code
// written for a page - synthesised music, breath tones, filtered noise - runs
// unchanged. The script sends the graph it builds here, and each context
// renders that graph itself, in 128-frame quanta as the Web Audio spec does,
// inside one AVAudioSourceNode on the screen's AVAudioEngine.
//
// Why not one AVAudioUnit per node: a Web Audio graph has cycles through
// delays (echo feedback), nodes that drive another node's parameter (an LFO
// on a gain) and a stream of short-lived nodes (a step sequencer makes a few
// dozen a second). AVAudioEngine allows none of those, so the graph is
// rendered here, with Accelerate for the heavy parts.
//
// Supported: AudioContext (currentTime, sampleRate, state, resume, suspend,
// close, statechange), AudioParam (value, setValueAtTime,
// linearRampToValueAtTime, exponentialRampToValueAtTime, setTargetAtTime,
// setValueCurveAtTime, cancelScheduledValues, cancelAndHoldAtTime, audio-rate
// connections into a param), GainNode, OscillatorNode (sine, square,
// sawtooth, triangle, frequency, detune), AudioBuffer + AudioBufferSourceNode
// (loop, loopStart/End, offset, duration, playbackRate, detune),
// BiquadFilterNode (all eight types), DelayNode (cycles clamp to one quantum,
// as the spec says), DynamicsCompressorNode, ConvolverNode (normalised as the
// spec says), connect/disconnect, start/stop, onended.
//
// Approximations, all inaudible for synthesis: square and sawtooth are
// PolyBLEP band-limited rather than the browser's wavetables; a biquad takes
// its coefficients once per quantum (2.9 ms); the compressor has no 6 ms
// look-ahead; a 4-channel ("true stereo") impulse response uses its first two
// channels; every node is stereo inside.
//
// The session is `.ambient` and mixes with other apps: the silent switch
// mutes it, as it mutes a web view's Web Audio, and it stops when the app
// leaves the screen.

let craftAudioQuantum = 128

/// Where in the timeline a quantum is.
struct CraftAudioRender {
    let quantum: Int64
    let sampleRate: Double

    var frame: Int64 { quantum * Int64(craftAudioQuantum) }
    var time: Double { Double(frame) / sampleRate }
}

/// An `AudioBuffer`'s samples as the script last handed them over. It never
/// changes, so a source that took it keeps playing it while the script
/// writes into its own copy.
final class CraftAudioBufferData {
    let sampleRate: Double
    let length: Int
    let channels: [UnsafeMutablePointer<Float>]

    init(sampleRate: Double, length: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        self.length = max(1, length)
        channels = (0..<max(1, channelCount)).map { _ in
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(1, length))
            data.initialize(repeating: 0, count: max(1, length))
            return data
        }
    }

    deinit { channels.forEach { $0.deallocate() } }
}

// MARK: - Automation

/// One AudioParam: its timeline of events and the values it takes in the
/// quantum being rendered.
final class CraftAudioParam {
    enum Kind { case set, linear, exponential, target, curve }

    struct Event {
        var kind: Kind
        var time: Double
        var value: Double
        var timeConstant = 0.0
        var duration = 0.0
        var curve: [Double] = []
        /// When the script asked for a ramp: where a ramp after a
        /// setTargetAtTime (or with nothing before it) starts.
        var scheduledAt = 0.0
        /// Where this event's segment starts, worked out once from the event
        /// before it, so the events before can be dropped as time passes.
        var fromTime = 0.0
        var fromValue = 0.0

        var isRamp: Bool { kind == .linear || kind == .exponential }
        var end: Double { kind == .curve ? time + duration : time }
    }

    static let largest = Double(Float.greatestFiniteMagnitude)

    let name: String
    let minValue: Double
    let maxValue: Double
    /// a-rate (a value per frame) or k-rate (one per quantum).
    let audioRate: Bool
    private(set) var events: [Event] = []
    private var intrinsic: Double
    /// Nodes connected into this param; their output is added to its value.
    var inputs: [CraftAudioNode] = []
    let values: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    /// Every frame of `values` holds the same number.
    private(set) var constant = true
    /// The value without its inputs at the start of the last quantum: what
    /// the script reads from `param.value`.
    private(set) var current: Double

    init(_ name: String, _ value: Double, min: Double = -largest, max: Double = largest, audioRate: Bool = true) {
        self.name = name
        minValue = min
        maxValue = max
        self.audioRate = audioRate
        intrinsic = value
        current = value
        values = .allocate(capacity: craftAudioQuantum)
        values.initialize(repeating: Float(value), count: craftAudioQuantum)
        scratch = .allocate(capacity: craftAudioQuantum)
        scratch.initialize(repeating: 0, count: craftAudioQuantum)
    }

    deinit {
        values.deallocate()
        scratch.deallocate()
    }

    /// Adds an event after any others at the same time, as the spec orders them.
    func schedule(_ event: Event) {
        var index = events.count
        while index > 0, events[index - 1].time > event.time { index -= 1 }
        events.insert(event, at: index)
        resolve(from: index)
    }

    /// cancelScheduledValues (and, holding, cancelAndHoldAtTime).
    func cancel(from time: Double, hold: Bool) {
        let held = value(at: time)
        events.removeAll { $0.time >= time || ($0.kind == .curve && $0.end > time) }
        if hold { schedule(Event(kind: .set, time: time, value: held)) }
    }

    /// The value the timeline gives at `time`, before inputs and clamping.
    func value(at time: Double) -> Double {
        var index = 0
        while index < events.count, events[index].time <= time { index += 1 }
        if index < events.count, events[index].isRamp, time >= events[index].fromTime {
            return Self.ramp(events[index], at: time)
        }
        return index == 0 ? intrinsic : Self.after(events[index - 1], at: time)
    }

    /// Fills `values` for this quantum and drops events it no longer needs.
    func compute(_ render: CraftAudioRender) {
        let frames = craftAudioQuantum
        let start = render.time
        let step = 1 / render.sampleRate
        let end = start + Double(frames) * step
        if !audioRate || constant(from: start, to: end) {
            let value = value(at: start)
            current = value
            values.update(repeating: Float(value), count: frames)
            constant = true
        } else {
            for frame in 0..<frames {
                values[frame] = Float(value(at: start + Double(frame) * step))
            }
            current = Double(values[0])
            constant = false
        }
        var modulated = false
        for input in inputs where input.pull(render) && !input.silent {
            // A param's input is mixed down to one channel.
            var half: Float = 0.5
            vDSP_vadd(input.left, 1, input.right, 1, scratch, 1, vDSP_Length(frames))
            vDSP_vsma(scratch, 1, &half, values, 1, values, 1, vDSP_Length(frames))
            modulated = true
        }
        if modulated {
            if audioRate { constant = false } else { values.update(repeating: values[0], count: frames) }
        }
        var low = Float(max(minValue, -Self.largest))
        var high = Float(min(maxValue, Self.largest))
        vDSP_vclip(values, 1, &low, &high, values, 1, vDSP_Length(frames))
        while events.count >= 2, events[1].time <= end {
            intrinsic = current
            events.removeFirst()
        }
    }

    private func constant(from start: Double, to end: Double) -> Bool {
        var index = 0
        while index < events.count, events[index].time <= start { index += 1 }
        if index < events.count {
            let next = events[index]
            if next.time < end || (next.isRamp && next.fromTime < end) { return false }
        }
        guard index > 0 else { return true }
        let previous = events[index - 1]
        switch previous.kind {
        case .target: return previous.timeConstant <= 0
        case .curve: return previous.end <= start
        default: return true
        }
    }

    private func resolve(from start: Int) {
        guard start < events.count else { return }
        for index in start..<events.count {
            var event = events[index]
            if index == 0 {
                event.fromTime = event.isRamp ? min(event.scheduledAt, event.time) : event.time
                event.fromValue = intrinsic
            } else {
                let previous = events[index - 1]
                if event.isRamp {
                    // After setTargetAtTime a ramp starts where the curve is
                    // when the ramp was asked for.
                    event.fromTime = previous.kind == .target
                        ? min(max(previous.time, event.scheduledAt), event.time)
                        : min(previous.end, event.time)
                } else {
                    event.fromTime = event.time
                }
                event.fromValue = Self.after(previous, at: event.fromTime)
            }
            events[index] = event
        }
    }

    /// An event's own segment, at or after its time.
    private static func after(_ event: Event, at time: Double) -> Double {
        switch event.kind {
        case .set, .linear, .exponential:
            return event.value
        case .target:
            guard event.timeConstant > 0 else { return event.value }
            return event.value + (event.fromValue - event.value) * exp(-(time - event.time) / event.timeConstant)
        case .curve:
            let curve = event.curve
            guard let last = curve.last else { return event.value }
            guard time < event.end, event.duration > 0, curve.count > 1 else { return last }
            let position = max(0, (time - event.time) / event.duration) * Double(curve.count - 1)
            let index = min(curve.count - 2, Int(position))
            return curve[index] + (curve[index + 1] - curve[index]) * (position - Double(index))
        }
    }

    private static func ramp(_ event: Event, at time: Double) -> Double {
        let span = event.time - event.fromTime
        guard span > 0 else { return event.value }
        let fraction = min(1, max(0, (time - event.fromTime) / span))
        if event.kind == .linear { return event.fromValue + (event.value - event.fromValue) * fraction }
        // The spec holds the start value when the ramp cannot be exponential.
        guard event.fromValue != 0, (event.fromValue > 0) == (event.value > 0) else { return event.fromValue }
        return event.fromValue * pow(event.value / event.fromValue, fraction)
    }
}

// MARK: - Nodes

/// A node of the graph. Every node renders stereo; a mono source writes the
/// same samples to both channels, which is what the spec's up-mixing makes
/// of it anyway.
class CraftAudioNode {
    let id: Int
    var inputs: [CraftAudioNode] = []
    var outputs: [CraftAudioNode] = []
    var paramOutputs: [CraftAudioParam] = []
    var params: [CraftAudioParam] = []
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    /// This quantum's output is silence (`left`/`right` are not read then).
    var silent = true
    /// The script let go of it: once nothing upstream can sound, it goes.
    var released = false
    var dead = false
    /// The last quantum it took in or gave out sound.
    var lastActive: Int64 = -1_000_000
    /// Quanta after `lastActive` before it is certainly quiet.
    var tail: Int64 { 2 }
    /// For graph searches.
    var mark = 0
    private var renderedQuantum: Int64 = -1
    private var busy = false

    init(id: Int) {
        self.id = id
        left = .allocate(capacity: craftAudioQuantum)
        left.initialize(repeating: 0, count: craftAudioQuantum)
        right = .allocate(capacity: craftAudioQuantum)
        right.initialize(repeating: 0, count: craftAudioQuantum)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func param(_ name: String) -> CraftAudioParam? {
        params.first { $0.name == name }
    }

    /// Renders this quantum once, however many nodes read it. False when a
    /// cycle came back to a node still working on it: a cycle without a delay
    /// is silent, as in the spec.
    @discardableResult
    final func pull(_ render: CraftAudioRender) -> Bool {
        if renderedQuantum == render.quantum { return busy ? reenter(render) : true }
        renderedQuantum = render.quantum
        busy = true
        process(render)
        busy = false
        if !silent { lastActive = render.quantum }
        return true
    }

    func reenter(_ render: CraftAudioRender) -> Bool { false }

    func process(_ render: CraftAudioRender) {
        silent = !mix(render, into: left, right)
    }

    /// Sums the inputs into `l`/`r`; false (and the buffers untouched) when
    /// every input is silent.
    final func mix(_ render: CraftAudioRender, into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>) -> Bool {
        let frames = vDSP_Length(craftAudioQuantum)
        var audible = false
        for input in inputs where input.pull(render) && !input.silent {
            if audible {
                vDSP_vadd(l, 1, input.left, 1, l, 1, frames)
                vDSP_vadd(r, 1, input.right, 1, r, 1, frames)
            } else {
                l.update(from: input.left, count: craftAudioQuantum)
                r.update(from: input.right, count: craftAudioQuantum)
                audible = true
            }
        }
        return audible
    }
}

final class CraftAudioGain: CraftAudioNode {
    let gain = CraftAudioParam("gain", 1)

    override init(id: Int) {
        super.init(id: id)
        params = [gain]
    }

    override func process(_ render: CraftAudioRender) {
        gain.compute(render)
        guard mix(render, into: left, right) else { silent = true; return }
        let frames = vDSP_Length(craftAudioQuantum)
        if gain.constant {
            var value = gain.values[0]
            guard value != 0 else { silent = true; return }
            if value != 1 {
                vDSP_vsmul(left, 1, &value, left, 1, frames)
                vDSP_vsmul(right, 1, &value, right, 1, frames)
            }
        } else {
            vDSP_vmul(left, 1, gain.values, 1, left, 1, frames)
            vDSP_vmul(right, 1, gain.values, 1, right, 1, frames)
        }
        silent = false
    }
}

/// OscillatorNode and AudioBufferSourceNode: start, stop, ended.
class CraftAudioSource: CraftAudioNode {
    var started = false
    var startTime = 0.0
    var stopTime = Double.infinity
    var ended = false

    /// The frames of this quantum the source plays, [begin, end).
    final func window(_ render: CraftAudioRender) -> (begin: Int, end: Int) {
        guard started, !ended else { return (0, 0) }
        let quantum = Int64(craftAudioQuantum)
        let first = frame(startTime, render.sampleRate)
        let last = stopTime.isFinite ? frame(stopTime, render.sampleRate) : Int64.max
        let begin = Int(min(max(first - render.frame, 0), quantum))
        let end = Int(min(max(last - render.frame, 0), quantum))
        return (begin, max(begin, end))
    }

    /// Whether `stop` takes effect by the end of this quantum.
    final func stops(_ render: CraftAudioRender) -> Bool {
        started && stopTime.isFinite && frame(stopTime, render.sampleRate) <= render.frame + Int64(craftAudioQuantum)
    }

    /// The first frame at or after `time`. A time a whole frame in seconds
    /// (100 / 48000) lands on that frame despite rounding.
    private func frame(_ time: Double, _ sampleRate: Double) -> Int64 {
        Int64(min(9e18, max(0, time * sampleRate - 1e-6).rounded(.up)))
    }

    final func clear(outside window: (begin: Int, end: Int)) {
        if window.begin > 0 {
            left.update(repeating: 0, count: window.begin)
            right.update(repeating: 0, count: window.begin)
        }
        if window.end < craftAudioQuantum {
            (left + window.end).update(repeating: 0, count: craftAudioQuantum - window.end)
            (right + window.end).update(repeating: 0, count: craftAudioQuantum - window.end)
        }
    }
}

final class CraftAudioOscillator: CraftAudioSource {
    /// sine, square, sawtooth, triangle.
    var shape = 0
    let frequency: CraftAudioParam
    let detune = CraftAudioParam("detune", 0, min: -153_600, max: 153_600)
    private var phase = 0.0

    init(id: Int, sampleRate: Double) {
        frequency = CraftAudioParam("frequency", 440, min: -sampleRate / 2, max: sampleRate / 2)
        super.init(id: id)
        params = [frequency, detune]
    }

    override func process(_ render: CraftAudioRender) {
        frequency.compute(render)
        detune.compute(render)
        let window = window(render)
        if stops(render) { ended = true }
        guard window.begin < window.end else { silent = true; return }
        clear(outside: window)
        let rate = render.sampleRate
        let nyquist = rate / 2
        let fixedDetune = detune.constant ? pow(2, Double(detune.values[0]) / 1200) : 1
        for frame in window.begin..<window.end {
            let cents = detune.constant ? fixedDetune : pow(2, Double(detune.values[frame]) / 1200)
            let step = min(nyquist, max(-nyquist, Double(frequency.values[frame]) * cents)) / rate
            left[frame] = Float(Self.sample(shape, phase, step))
            phase += step
            phase -= phase.rounded(.down)
        }
        (right + window.begin).update(from: left + window.begin, count: window.end - window.begin)
        silent = false
    }

    /// One sample at `phase` (0..<1 of a cycle), starting at 0 and rising as
    /// the browser's waves do. Square and sawtooth are PolyBLEP band-limited.
    static func sample(_ shape: Int, _ phase: Double, _ step: Double) -> Double {
        switch shape {
        case 1:
            var value = phase < 0.5 ? 1.0 : -1.0
            value += blep(phase, step)
            let half = phase + 0.5
            value -= blep(half - half.rounded(.down), step)
            return value
        case 2:
            let shifted = phase + 0.5
            let saw = shifted - shifted.rounded(.down)
            return 2 * saw - 1 - blep(saw, step)
        case 3:
            let shifted = phase + 0.75
            return 4 * abs(shifted - shifted.rounded(.down) - 0.5) - 1
        default:
            return sin(2 * Double.pi * phase)
        }
    }

    private static func blep(_ t: Double, _ step: Double) -> Double {
        let dt = abs(step)
        guard dt > 0 else { return 0 }
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }
}

final class CraftAudioBufferSource: CraftAudioSource {
    var buffer: CraftAudioBufferData?
    var loop = false
    var loopStart = 0.0
    var loopEnd = 0.0
    var offset = 0.0
    /// Seconds of the buffer to play; negative is all of it.
    var duration = -1.0
    let playbackRate = CraftAudioParam("playbackRate", 1, audioRate: false)
    let detune = CraftAudioParam("detune", 0, audioRate: false)
    private var position = 0.0
    private var played = 0.0
    private var began = false

    override init(id: Int) {
        super.init(id: id)
        params = [playbackRate, detune]
    }

    override func process(_ render: CraftAudioRender) {
        playbackRate.compute(render)
        detune.compute(render)
        let window = window(render)
        if stops(render) { ended = true }
        guard window.begin < window.end, let buffer else { silent = true; return }
        clear(outside: window)
        let length = Double(buffer.length)
        var loopFrom = 0.0
        var loopTo = length
        if loopStart >= 0, loopEnd > 0, loopStart < loopEnd {
            loopFrom = min(length, loopStart * buffer.sampleRate)
            loopTo = min(length, loopEnd * buffer.sampleRate)
        }
        let span = loopTo - loopFrom
        if !began {
            began = true
            position = max(0, offset) * buffer.sampleRate
            if loop, span > 0, position >= loopTo {
                position = loopFrom + (position - loopFrom).truncatingRemainder(dividingBy: span)
            }
        }
        let rate = buffer.sampleRate / render.sampleRate * Double(playbackRate.values[0]) * pow(2, Double(detune.values[0]) / 1200)
        let first = buffer.channels[0]
        let second = buffer.channels.count > 1 ? buffer.channels[1] : first
        let frames = buffer.length
        var finishedAt: Int?
        for frame in window.begin..<window.end {
            if duration >= 0, played >= duration { finishedAt = frame; break }
            if loop, span > 0 {
                if position >= loopTo { position = loopFrom + (position - loopTo).truncatingRemainder(dividingBy: span) }
                else if position < loopFrom, rate < 0 { position = loopTo - (loopFrom - position).truncatingRemainder(dividingBy: span) }
            } else if position >= length || position < 0 {
                finishedAt = frame
                break
            }
            let index = Int(position)
            let fraction = Float(position - Double(index))
            var next = index + 1
            if loop, span > 0, Double(next) >= loopTo { next = Int(loopFrom) }
            let a0 = index < frames ? first[index] : 0
            let a1 = next < frames ? first[next] : 0
            let b0 = index < frames ? second[index] : 0
            let b1 = next < frames ? second[next] : 0
            left[frame] = a0 + (a1 - a0) * fraction
            right[frame] = b0 + (b1 - b0) * fraction
            position += rate
            played += abs(rate) / buffer.sampleRate
        }
        if let finishedAt {
            (left + finishedAt).update(repeating: 0, count: craftAudioQuantum - finishedAt)
            (right + finishedAt).update(repeating: 0, count: craftAudioQuantum - finishedAt)
            ended = true
        }
        silent = false
    }
}

final class CraftAudioBiquad: CraftAudioNode {
    /// lowpass, highpass, bandpass, lowshelf, highshelf, peaking, notch, allpass.
    var type = 0
    let frequency: CraftAudioParam
    let detune = CraftAudioParam("detune", 0, min: -153_600, max: 153_600)
    let q = CraftAudioParam("Q", 1)
    let gain = CraftAudioParam("gain", 0, max: 1541)
    /// x1, x2, y1, y2 for each channel.
    private var state = [Double](repeating: 0, count: 8)

    init(id: Int, sampleRate: Double) {
        frequency = CraftAudioParam("frequency", 350, min: 0, max: sampleRate / 2)
        super.init(id: id)
        params = [frequency, detune, q, gain]
    }

    override func process(_ render: CraftAudioRender) {
        frequency.compute(render)
        detune.compute(render)
        q.compute(render)
        gain.compute(render)
        let audible = mix(render, into: left, right)
        if !audible {
            if state.allSatisfy({ abs($0) < 1e-12 }) {
                state = [Double](repeating: 0, count: 8)
                silent = true
                return
            }
            left.update(repeating: 0, count: craftAudioQuantum)
            right.update(repeating: 0, count: craftAudioQuantum)
        }
        let c = coefficients(render.sampleRate)
        filter(left, c, 0)
        filter(right, c, 4)
        silent = false
    }

    private func filter(_ samples: UnsafeMutablePointer<Float>, _ c: (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double), _ at: Int) {
        var x1 = state[at], x2 = state[at + 1], y1 = state[at + 2], y2 = state[at + 3]
        for frame in 0..<craftAudioQuantum {
            let x = Double(samples[frame])
            var y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            // Flush denormals (and anything that blew up) to zero.
            if !y.isFinite || abs(y) < 1e-30 { y = 0 }
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            samples[frame] = Float(y)
        }
        state[at] = x1
        state[at + 1] = x2
        state[at + 2] = y1
        state[at + 3] = y2
    }

    /// The spec's formulas (the Audio EQ Cookbook, with lowpass and highpass
    /// Q in dB), normalised by a0.
    func coefficients(_ sampleRate: Double) -> (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        let nyquist = sampleRate / 2
        let hz = min(nyquist, max(0, Double(frequency.values[0]) * pow(2, Double(detune.values[0]) / 1200)))
        let normalized = hz / nyquist
        let quality = Double(q.values[0])
        let a = pow(10, Double(gain.values[0]) / 40)
        let pass = (b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)
        let mute = (b0: 0.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)
        let gainOnly = (b0: a * a, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)
        switch type {
        case 0 where normalized >= 1: return pass
        case 0 where normalized <= 0: return mute
        case 1 where normalized >= 1: return mute
        case 1 where normalized <= 0: return pass
        case 2 where normalized <= 0 || normalized >= 1: return mute
        case 2 where quality <= 0: return pass
        case 3 where normalized >= 1, 4 where normalized <= 0: return gainOnly
        case 3 where normalized <= 0, 4 where normalized >= 1: return pass
        case 5 where normalized <= 0 || normalized >= 1: return pass
        case 5 where quality <= 0: return gainOnly
        case 6 where normalized <= 0 || normalized >= 1: return pass
        case 6 where quality <= 0: return mute
        case 7 where normalized <= 0 || normalized >= 1: return pass
        case 7 where quality <= 0: return (b0: -1, b1: 0, b2: 0, a1: 0, a2: 0)
        default: break
        }
        let w0 = Double.pi * normalized
        let cosine = cos(w0)
        let alphaQ = sin(w0) / (2 * quality)
        let alphaDB = sin(w0) / (2 * pow(10, quality / 20))
        let alphaS = sin(w0) / 2 * sqrt(2.0)
        let root = sqrt(a)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch type {
        case 1:
            b0 = (1 + cosine) / 2; b1 = -(1 + cosine); b2 = (1 + cosine) / 2
            a0 = 1 + alphaDB; a1 = -2 * cosine; a2 = 1 - alphaDB
        case 2:
            b0 = alphaQ; b1 = 0; b2 = -alphaQ
            a0 = 1 + alphaQ; a1 = -2 * cosine; a2 = 1 - alphaQ
        case 3:
            b0 = a * ((a + 1) - (a - 1) * cosine + 2 * alphaS * root)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosine)
            b2 = a * ((a + 1) - (a - 1) * cosine - 2 * alphaS * root)
            a0 = (a + 1) + (a - 1) * cosine + 2 * alphaS * root
            a1 = -2 * ((a - 1) + (a + 1) * cosine)
            a2 = (a + 1) + (a - 1) * cosine - 2 * alphaS * root
        case 4:
            b0 = a * ((a + 1) + (a - 1) * cosine + 2 * alphaS * root)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosine)
            b2 = a * ((a + 1) + (a - 1) * cosine - 2 * alphaS * root)
            a0 = (a + 1) - (a - 1) * cosine + 2 * alphaS * root
            a1 = 2 * ((a - 1) - (a + 1) * cosine)
            a2 = (a + 1) - (a - 1) * cosine - 2 * alphaS * root
        case 5:
            b0 = 1 + alphaQ * a; b1 = -2 * cosine; b2 = 1 - alphaQ * a
            a0 = 1 + alphaQ / a; a1 = -2 * cosine; a2 = 1 - alphaQ / a
        case 6:
            b0 = 1; b1 = -2 * cosine; b2 = 1
            a0 = 1 + alphaQ; a1 = -2 * cosine; a2 = 1 - alphaQ
        case 7:
            b0 = 1 - alphaQ; b1 = -2 * cosine; b2 = 1 + alphaQ
            a0 = 1 + alphaQ; a1 = -2 * cosine; a2 = 1 - alphaQ
        default:
            b0 = (1 - cosine) / 2; b1 = 1 - cosine; b2 = (1 - cosine) / 2
            a0 = 1 + alphaDB; a1 = -2 * cosine; a2 = 1 - alphaDB
        }
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }
}

final class CraftAudioDelay: CraftAudioNode {
    let delayTime: CraftAudioParam
    private let capacity: Int
    private let ringLeft: UnsafeMutablePointer<Float>
    private let ringRight: UnsafeMutablePointer<Float>
    private let inLeft: UnsafeMutablePointer<Float>
    private let inRight: UnsafeMutablePointer<Float>
    /// Frames written since the start.
    private var written = 0
    /// A cycle needed this quantum's output before the input was in.
    private var early = false
    /// Frames since the input last sounded.
    private var quiet = Int.max / 2

    override var tail: Int64 { Int64(capacity / craftAudioQuantum) + 2 }

    init(id: Int, sampleRate: Double, maxDelay: Double) {
        delayTime = CraftAudioParam("delayTime", 0, min: 0, max: maxDelay)
        capacity = Int((maxDelay * sampleRate).rounded(.up)) + 2 * craftAudioQuantum + 2
        ringLeft = .allocate(capacity: capacity)
        ringLeft.initialize(repeating: 0, count: capacity)
        ringRight = .allocate(capacity: capacity)
        ringRight.initialize(repeating: 0, count: capacity)
        inLeft = .allocate(capacity: craftAudioQuantum)
        inLeft.initialize(repeating: 0, count: craftAudioQuantum)
        inRight = .allocate(capacity: craftAudioQuantum)
        inRight.initialize(repeating: 0, count: craftAudioQuantum)
        super.init(id: id)
        params = [delayTime]
    }

    deinit {
        ringLeft.deallocate()
        ringRight.deallocate()
        inLeft.deallocate()
        inRight.deallocate()
    }

    /// In a cycle the delay is at least one quantum (the spec's clamp), so its
    /// output comes from what was written before this quantum.
    override func reenter(_ render: CraftAudioRender) -> Bool {
        if !early {
            early = true
            if quiet > capacity { silent = true } else { read(render, minimum: Double(craftAudioQuantum)) }
        }
        return true
    }

    override func process(_ render: CraftAudioRender) {
        early = false
        delayTime.compute(render)
        let audible = mix(render, into: inLeft, inRight)
        quiet = audible ? 0 : quiet + craftAudioQuantum
        if audible { lastActive = render.quantum }
        if quiet > capacity {
            // Nothing has gone in for longer than the line: it holds zeros.
            if !early { silent = true }
            return
        }
        if !audible {
            inLeft.update(repeating: 0, count: craftAudioQuantum)
            inRight.update(repeating: 0, count: craftAudioQuantum)
        }
        for frame in 0..<craftAudioQuantum {
            let slot = (written + frame) % capacity
            ringLeft[slot] = inLeft[frame]
            ringRight[slot] = inRight[frame]
        }
        if !early { read(render, minimum: 0) }
        written += craftAudioQuantum
    }

    private func read(_ render: CraftAudioRender, minimum: Double) {
        let limit = Double(capacity - craftAudioQuantum - 2)
        for frame in 0..<craftAudioQuantum {
            let delay = min(limit, max(minimum, Double(delayTime.values[frame]) * render.sampleRate))
            let position = Double(written + frame) - delay
            let base = position.rounded(.down)
            let fraction = Float(position - base)
            let index = Int(base)
            left[frame] = sample(ringLeft, index) * (1 - fraction) + sample(ringLeft, index + 1) * fraction
            right[frame] = sample(ringRight, index) * (1 - fraction) + sample(ringRight, index + 1) * fraction
        }
        silent = false
    }

    private func sample(_ ring: UnsafeMutablePointer<Float>, _ index: Int) -> Float {
        index < 0 ? 0 : ring[index % capacity]
    }
}

final class CraftAudioCompressor: CraftAudioNode {
    let threshold = CraftAudioParam("threshold", -24, min: -100, max: 0, audioRate: false)
    let knee = CraftAudioParam("knee", 30, min: 0, max: 40, audioRate: false)
    let ratio = CraftAudioParam("ratio", 12, min: 1, max: 20, audioRate: false)
    let attack = CraftAudioParam("attack", 0.003, min: 0, max: 1, audioRate: false)
    let release = CraftAudioParam("release", 0.25, min: 0, max: 1, audioRate: false)
    /// The gain reduction now, in dB (zero or below): `reduction`.
    private(set) var reduction = 0.0
    private var envelope = 0.0

    override init(id: Int) {
        super.init(id: id)
        params = [threshold, knee, ratio, attack, release]
    }

    override func process(_ render: CraftAudioRender) {
        params.forEach { $0.compute(render) }
        let rate = render.sampleRate
        let attackTime = Double(attack.values[0])
        let releaseTime = Double(release.values[0])
        let attackCoefficient = attackTime > 0 ? exp(-1 / (attackTime * rate)) : 0
        let releaseCoefficient = releaseTime > 0 ? exp(-1 / (releaseTime * rate)) : 0
        guard mix(render, into: left, right) else {
            envelope *= pow(releaseCoefficient, Double(craftAudioQuantum))
            reduction = envelope
            silent = true
            return
        }
        let t = Double(threshold.values[0])
        let k = Double(knee.values[0])
        let r = Double(ratio.values[0])
        // The spec's makeup gain: (1 / the curve's gain at 0 dBFS) ^ 0.6.
        let makeup = pow(1 / pow(10, Self.curve(0, t, k, r) / 20), 0.6)
        for frame in 0..<craftAudioQuantum {
            let level = Double(max(abs(left[frame]), abs(right[frame])))
            let decibels = level > 1e-6 ? 20 * log10(level) : -120
            let target = Self.curve(decibels, t, k, r) - decibels
            let coefficient = target < envelope ? attackCoefficient : releaseCoefficient
            envelope = coefficient * envelope + (1 - coefficient) * target
            let gain = Float(pow(10, envelope / 20) * makeup)
            left[frame] *= gain
            right[frame] *= gain
        }
        reduction = envelope
        silent = false
    }

    /// The static curve in dB: straight to the threshold, a quadratic knee
    /// above it, then 1:ratio.
    static func curve(_ x: Double, _ threshold: Double, _ knee: Double, _ ratio: Double) -> Double {
        if x <= threshold { return x }
        let slope = 1 / ratio - 1
        if knee > 0, x < threshold + knee {
            let over = x - threshold
            return x + slope * over * over / (2 * knee)
        }
        return threshold + knee + slope * knee / 2 + (x - threshold - knee) / ratio
    }
}

final class CraftAudioConvolver: CraftAudioNode {
    var convolution: CraftAudioConvolution?
    private let inLeft: UnsafeMutablePointer<Float>
    private let inRight: UnsafeMutablePointer<Float>

    override var tail: Int64 { Int64((convolution?.tailFrames ?? 0) / craftAudioQuantum) + 2 }

    override init(id: Int) {
        inLeft = .allocate(capacity: craftAudioQuantum)
        inLeft.initialize(repeating: 0, count: craftAudioQuantum)
        inRight = .allocate(capacity: craftAudioQuantum)
        inRight.initialize(repeating: 0, count: craftAudioQuantum)
        super.init(id: id)
    }

    deinit {
        inLeft.deallocate()
        inRight.deallocate()
    }

    override func process(_ render: CraftAudioRender) {
        let audible = mix(render, into: inLeft, inRight)
        if audible { lastActive = render.quantum }
        guard let convolution else { silent = true; return }
        silent = !convolution.process(inLeft, inRight, audible: audible, into: left, right)
    }
}

/// A ConvolverNode's impulse response, ready to run: the first 512 taps
/// directly (no latency), the rest as uniformly partitioned FFT convolution
/// whose one-block latency the first 512 taps cover exactly.
final class CraftAudioConvolution {
    static let block = 512
    private static let log2n = vDSP_Length(10)
    private static let setup: FFTSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!

    /// How long it rings after the input stops, in frames.
    let tailFrames: Int
    private let partitions: Int
    private let responses: Int
    private let direct: [UnsafeMutablePointer<Float>]
    private let spectraReal: [UnsafeMutablePointer<Float>]
    private let spectraImag: [UnsafeMutablePointer<Float>]
    private let history: [UnsafeMutablePointer<Float>]
    private let windows: [UnsafeMutablePointer<Float>]
    private let delayReal: [UnsafeMutablePointer<Float>]
    private let delayImag: [UnsafeMutablePointer<Float>]
    private let tails: [UnsafeMutablePointer<Float>]
    private let sumReal: UnsafeMutablePointer<Float>
    private let sumImag: UnsafeMutablePointer<Float>
    private let time: UnsafeMutablePointer<Float>
    private let allocations: [UnsafeMutablePointer<Float>]
    private var fill = 0
    private var head = 0
    private var quiet = Int.max / 2

    /// The spec's normalisation: 1 / RMS power, calibrated (0.00125) and
    /// scaled for the sample rate.
    static func normalization(_ buffer: CraftAudioBufferData) -> Float {
        var power = 0.0
        for channel in buffer.channels {
            var sum: Float = 0
            vDSP_svesq(channel, 1, &sum, vDSP_Length(buffer.length))
            power += Double(sum)
        }
        power = sqrt(power / Double(buffer.channels.count * buffer.length))
        if !power.isFinite || power < 0.000125 { power = 0.000125 }
        var scale = 1 / power * 0.00125
        if buffer.sampleRate > 0 { scale *= 44_100 / buffer.sampleRate }
        if buffer.channels.count == 4 { scale *= 0.5 }
        return Float(scale)
    }

    init(buffer: CraftAudioBufferData, normalize: Bool) {
        let block = Self.block
        let size = block * 2
        let length = buffer.length
        let responses = min(2, buffer.channels.count)
        let partitions = length > block ? (length - block + block - 1) / block : 0
        let scale = normalize ? Self.normalization(buffer) : 1
        var made: [UnsafeMutablePointer<Float>] = []
        func zeros(_ count: Int) -> UnsafeMutablePointer<Float> {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
            data.initialize(repeating: 0, count: max(1, count))
            made.append(data)
            return data
        }
        let time = zeros(size)
        var direct: [UnsafeMutablePointer<Float>] = []
        var spectraReal: [UnsafeMutablePointer<Float>] = []
        var spectraImag: [UnsafeMutablePointer<Float>] = []
        // The FFT's own scale: a forward real FFT is 2x, the inverse N x, so a
        // product of two forward transforms comes back 4N x too large.
        let fftScale = scale / Float(4 * size)
        for channel in 0..<responses {
            let source = buffer.channels[channel]
            let taps = zeros(block)
            var factor = scale
            vDSP_vsmul(source, 1, &factor, taps, 1, vDSP_Length(min(block, length)))
            direct.append(taps)
            let real = zeros(partitions * block)
            let imag = zeros(partitions * block)
            for partition in 0..<partitions {
                time.update(repeating: 0, count: size)
                let start = block + partition * block
                var tapsScale = fftScale
                vDSP_vsmul(source + start, 1, &tapsScale, time, 1, vDSP_Length(min(block, length - start)))
                var split = DSPSplitComplex(realp: real + partition * block, imagp: imag + partition * block)
                time.withMemoryRebound(to: DSPComplex.self, capacity: block) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(block)) }
                vDSP_fft_zrip(Self.setup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
            }
            spectraReal.append(real)
            spectraImag.append(imag)
        }
        self.responses = responses
        self.partitions = partitions
        self.time = time
        tailFrames = length + block
        self.direct = direct
        self.spectraReal = spectraReal
        self.spectraImag = spectraImag
        sumReal = zeros(block)
        sumImag = zeros(block)
        history = (0..<2).map { _ in zeros(block - 1 + craftAudioQuantum) }
        windows = (0..<2).map { _ in zeros(size) }
        delayReal = (0..<2).map { _ in zeros(partitions * block) }
        delayImag = (0..<2).map { _ in zeros(partitions * block) }
        tails = (0..<2).map { _ in zeros(block) }
        allocations = made
    }

    deinit { allocations.forEach { $0.deallocate() } }

    /// One quantum. False once it has rung out and the output is silence.
    func process(_ inLeft: UnsafeMutablePointer<Float>, _ inRight: UnsafeMutablePointer<Float>, audible: Bool, into outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>) -> Bool {
        let block = Self.block
        let frames = craftAudioQuantum
        quiet = audible ? 0 : quiet + frames
        // Every buffer holds zeros by then, so skipping keeps them right.
        if quiet > tailFrames + 3 * block { return false }
        for channel in 0..<2 {
            let input = channel == 0 ? inLeft : inRight
            let output = channel == 0 ? outLeft : outRight
            let response = min(channel, responses - 1)
            let past = history[channel]
            let current = past + (block - 1)
            if audible { current.update(from: input, count: frames) } else { current.update(repeating: 0, count: frames) }
            vDSP_conv(past, 1, direct[response] + (block - 1), -1, output, 1, vDSP_Length(frames), vDSP_Length(block))
            if partitions > 0 {
                (windows[channel] + block + fill).update(from: current, count: frames)
                vDSP_vadd(output, 1, tails[channel] + fill, 1, output, 1, vDSP_Length(frames))
            }
            memmove(past, past + frames, (block - 1) * MemoryLayout<Float>.size)
        }
        fill += frames
        if fill == block {
            fill = 0
            if partitions > 0 {
                runBlock(0)
                runBlock(1)
                head = (head + 1) % partitions
            }
        }
        return true
    }

    /// A whole block is in: its spectrum joins the delay line, and the tail
    /// partitions' sum becomes the next block's tail output.
    private func runBlock(_ channel: Int) {
        let block = Self.block
        let window = windows[channel]
        let slotReal = delayReal[channel] + head * block
        let slotImag = delayImag[channel] + head * block
        var input = DSPSplitComplex(realp: slotReal, imagp: slotImag)
        window.withMemoryRebound(to: DSPComplex.self, capacity: block) { vDSP_ctoz($0, 2, &input, 1, vDSP_Length(block)) }
        vDSP_fft_zrip(Self.setup, &input, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
        sumReal.update(repeating: 0, count: block)
        sumImag.update(repeating: 0, count: block)
        var sum = DSPSplitComplex(realp: sumReal, imagp: sumImag)
        let response = min(channel, responses - 1)
        // Packed real spectra keep DC in real[0] and Nyquist in imag[0]:
        // they multiply on their own.
        var dc: Float = 0
        var nyquist: Float = 0
        for partition in 0..<partitions {
            let slot = ((head - partition) % partitions + partitions) % partitions
            var x = DSPSplitComplex(realp: delayReal[channel] + slot * block, imagp: delayImag[channel] + slot * block)
            var h = DSPSplitComplex(realp: spectraReal[response] + partition * block, imagp: spectraImag[response] + partition * block)
            dc += x.realp[0] * h.realp[0]
            nyquist += x.imagp[0] * h.imagp[0]
            withUnsafeMutablePointer(to: &sum) { total in
                vDSP_zvma(&x, 1, &h, 1, total, 1, total, 1, vDSP_Length(block))
            }
        }
        sumReal[0] = dc
        sumImag[0] = nyquist
        vDSP_fft_zrip(Self.setup, &sum, 1, Self.log2n, FFTDirection(kFFTDirection_Inverse))
        time.withMemoryRebound(to: DSPComplex.self, capacity: block) { vDSP_ztoc(&sum, 1, $0, 2, vDSP_Length(block)) }
        tails[channel].update(from: time + block, count: block)
        window.update(from: window + block, count: block)
    }
}

// MARK: - Graph

enum CraftAudioOp {
    case connect(CraftAudioNode, CraftAudioNode)
    case connectParam(CraftAudioNode, CraftAudioParam, owner: CraftAudioNode)
    case disconnect(CraftAudioNode, CraftAudioNode?)
    case disconnectParam(CraftAudioNode, CraftAudioParam)
    case schedule(CraftAudioParam, CraftAudioParam.Event)
    case cancel(CraftAudioParam, Double, hold: Bool)
    case start(CraftAudioSource, when: Double, offset: Double, duration: Double)
    case stop(CraftAudioSource, Double)
    case shape(CraftAudioOscillator, Int)
    case filter(CraftAudioBiquad, Int)
    case buffer(CraftAudioBufferSource, CraftAudioBufferData?)
    case loop(CraftAudioBufferSource, Bool, Double, Double)
    case convolution(CraftAudioConvolver, CraftAudioConvolution?)
    case release(CraftAudioNode)
}

enum CraftAudioNotice {
    case ended(Int)
    case removed(Int)
}

/// One AudioContext's graph. The main thread hands it ops and collects
/// notices through a mailbox; the render thread owns everything else and
/// never waits for the mailbox (it tries the lock and comes back next time).
final class CraftAudioGraph {
    let sampleRate: Double
    let destination = CraftAudioNode(id: 0)
    private var quantum: Int64 = 0
    private var sources: [CraftAudioSource] = []
    private var released: [CraftAudioNode] = []
    private var notices: [CraftAudioNotice] = []
    private var ops: [CraftAudioOp] = []
    private let carryLeft: UnsafeMutablePointer<Float>
    private let carryRight: UnsafeMutablePointer<Float>
    private var carried = craftAudioQuantum
    private var searchMark = 0
    private var rendering = true
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var inbox: [CraftAudioOp] = []
    private var outbox: [CraftAudioNotice] = []
    private var publishedQuantum: Int64 = 0
    private var wantsRunning = true

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        carryLeft = .allocate(capacity: craftAudioQuantum)
        carryLeft.initialize(repeating: 0, count: craftAudioQuantum)
        carryRight = .allocate(capacity: craftAudioQuantum)
        carryRight.initialize(repeating: 0, count: craftAudioQuantum)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        ops.reserveCapacity(512)
        notices.reserveCapacity(512)
        released.reserveCapacity(512)
        sources.reserveCapacity(256)
    }

    deinit {
        carryLeft.deallocate()
        carryRight.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: Main thread

    func enqueue(_ batch: [CraftAudioOp]) {
        guard !batch.isEmpty else { return }
        os_unfair_lock_lock(lock)
        inbox.append(contentsOf: batch)
        os_unfair_lock_unlock(lock)
    }

    /// Suspended or running: a suspended context renders nothing and its
    /// clock stands still.
    func setRunning(_ running: Bool) {
        os_unfair_lock_lock(lock)
        wantsRunning = running
        os_unfair_lock_unlock(lock)
    }

    /// The context's clock: the start of the next quantum to render.
    var currentTime: Double {
        os_unfair_lock_lock(lock)
        let quantum = publishedQuantum
        os_unfair_lock_unlock(lock)
        return Double(quantum * Int64(craftAudioQuantum)) / sampleRate
    }

    func collect() -> [CraftAudioNotice] {
        os_unfair_lock_lock(lock)
        let collected = outbox
        outbox.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(lock)
        return collected
    }

    // MARK: Render thread

    /// Renders `frames` into the engine's buffers. True when it was all silence.
    func render(_ frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) -> Bool {
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return true }
        let second = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        return render(frames, left: first, right: second)
    }

    @discardableResult
    func render(_ frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?) -> Bool {
        receive()
        guard rendering else {
            left.update(repeating: 0, count: frames)
            right?.update(repeating: 0, count: frames)
            return true
        }
        var done = 0
        var audible = false
        while done < frames {
            if carried == craftAudioQuantum {
                renderQuantum()
                carried = 0
            }
            if !destination.silent { audible = true }
            let count = min(craftAudioQuantum - carried, frames - done)
            (left + done).update(from: carryLeft + carried, count: count)
            (right.map { $0 + done })?.update(from: carryRight + carried, count: count)
            carried += count
            done += count
        }
        publish()
        return !audible
    }

    private func receive() {
        guard os_unfair_lock_trylock(lock) else { return }
        swap(&inbox, &ops)
        rendering = wantsRunning
        os_unfair_lock_unlock(lock)
        for op in ops { apply(op) }
        ops.removeAll(keepingCapacity: true)
    }

    private func publish() {
        guard os_unfair_lock_trylock(lock) else { return }
        publishedQuantum = quantum
        outbox.append(contentsOf: notices)
        os_unfair_lock_unlock(lock)
        notices.removeAll(keepingCapacity: true)
    }

    private func renderQuantum() {
        let render = CraftAudioRender(quantum: quantum, sampleRate: sampleRate)
        destination.pull(render)
        if destination.silent {
            carryLeft.update(repeating: 0, count: craftAudioQuantum)
            carryRight.update(repeating: 0, count: craftAudioQuantum)
        } else {
            carryLeft.update(from: destination.left, count: craftAudioQuantum)
            carryRight.update(from: destination.right, count: craftAudioQuantum)
        }
        // A playing source keeps time even when nothing it feeds is heard.
        for source in sources { source.pull(render) }
        var index = 0
        while index < sources.count {
            let source = sources[index]
            if source.ended {
                sources.remove(at: index)
                notices.append(.ended(source.id))
                remove(source)
            } else {
                index += 1
            }
        }
        if quantum % 8 == 0 { sweep(render) }
        quantum += 1
    }

    private func apply(_ op: CraftAudioOp) {
        switch op {
        case .connect(let from, let to):
            guard !from.dead, !to.dead, !from.outputs.contains(where: { $0 === to }) else { return }
            from.outputs.append(to)
            to.inputs.append(from)
        case .connectParam(let from, let param, let owner):
            guard !from.dead, !owner.dead, !from.paramOutputs.contains(where: { $0 === param }) else { return }
            from.paramOutputs.append(param)
            param.inputs.append(from)
        case .disconnect(let from, let to):
            if let to {
                from.outputs.removeAll { $0 === to }
                to.inputs.removeAll { $0 === from }
            } else {
                for output in from.outputs { output.inputs.removeAll { $0 === from } }
                for param in from.paramOutputs { param.inputs.removeAll { $0 === from } }
                from.outputs.removeAll(keepingCapacity: true)
                from.paramOutputs.removeAll(keepingCapacity: true)
            }
        case .disconnectParam(let from, let param):
            from.paramOutputs.removeAll { $0 === param }
            param.inputs.removeAll { $0 === from }
        case .schedule(let param, let event):
            param.schedule(event)
        case .cancel(let param, let time, let hold):
            param.cancel(from: time, hold: hold)
        case .start(let source, let time, let offset, let duration):
            guard !source.dead, !source.started else { return }
            source.started = true
            source.startTime = time
            if let buffered = source as? CraftAudioBufferSource {
                buffered.offset = offset
                buffered.duration = duration
            }
            sources.append(source)
        case .stop(let source, let time):
            guard !source.dead, source.started else { return }
            source.stopTime = time
        case .shape(let oscillator, let shape):
            oscillator.shape = shape
        case .filter(let biquad, let type):
            biquad.type = type
        case .buffer(let source, let data):
            source.buffer = data
        case .loop(let source, let loop, let start, let end):
            source.loop = loop
            source.loopStart = start
            source.loopEnd = end
        case .convolution(let node, let convolution):
            node.convolution = convolution
        case .release(let node):
            guard !node.dead, !node.released else { return }
            node.released = true
            released.append(node)
        }
    }

    /// Removes the released nodes that can never sound again: everything
    /// upstream of them is released too (the script holds none of it, so
    /// nothing new can be connected) and has gone quiet.
    private func sweep(_ render: CraftAudioRender) {
        var index = 0
        while index < released.count {
            let node = released[index]
            if node.dead {
                released.remove(at: index)
                continue
            }
            searchMark += 1
            if finished(node, render) {
                released.remove(at: index)
                remove(node)
            } else {
                index += 1
            }
        }
    }

    private func finished(_ node: CraftAudioNode, _ render: CraftAudioRender) -> Bool {
        if node.mark == searchMark { return true }
        node.mark = searchMark
        if node.dead { return true }
        guard node.released, render.quantum - node.lastActive > node.tail else { return false }
        if let source = node as? CraftAudioSource, source.started, !source.ended { return false }
        for input in node.inputs where !finished(input, render) { return false }
        for param in node.params {
            for input in param.inputs where !finished(input, render) { return false }
        }
        return true
    }

    private func remove(_ node: CraftAudioNode) {
        guard !node.dead else { return }
        node.dead = true
        for output in node.outputs { output.inputs.removeAll { $0 === node } }
        for param in node.paramOutputs { param.inputs.removeAll { $0 === node } }
        for input in node.inputs { input.outputs.removeAll { $0 === node } }
        for param in node.params {
            for input in param.inputs { input.paramOutputs.removeAll { $0 === param } }
            param.inputs.removeAll(keepingCapacity: true)
        }
        node.inputs.removeAll(keepingCapacity: true)
        node.outputs.removeAll(keepingCapacity: true)
        node.paramOutputs.removeAll(keepingCapacity: true)
        // The main thread drops its reference, so the node is freed there.
        notices.append(.removed(node.id))
    }
}

// MARK: - The screen's audio

/// Every AudioContext a native screen makes, on one AVAudioEngine that the
/// screen owns and stops when it closes.
final class CraftWebAudio {
    private final class Context {
        let graph: CraftAudioGraph
        var source: AVAudioSourceNode?
        var nodes: [Int: CraftAudioNode] = [:]
        var running = true

        init(graph: CraftAudioGraph) {
            self.graph = graph
        }
    }

    /// False in tests: no engine, the graph is rendered by hand.
    private let live: Bool
    private var contexts: [Int: Context] = [:]
    private var buffers: [Int: CraftAudioBufferData] = [:]
    private var engine: AVAudioEngine?
    private var claimedSession = false
    private var pump: Timer?
    /// Notifications about the audio session and the app, registered once and
    /// outliving any one engine.
    private var observers: [NSObjectProtocol] = []
    /// And the one about this engine's configuration, which does not: a
    /// rebuilt engine is a different object (`rebuildEngine`).
    private var engineObserver: NSObjectProtocol?
    private weak var script: JSContext?

    init(live: Bool = true) {
        self.live = live
    }

    deinit {
        pump?.invalidate()
    }

    /// Installs the native half and the `AudioContext` API in a screen's
    /// JavaScript, before its bundle runs.
    func install(in context: JSContext) {
        script = context
        // The graph lives on the main thread. A script on its own thread
        // (CraftNativeScriptThread) reaches it there, waiting for the answer
        // its synchronous calls return; arguments are read off the JSValues
        // where the script runs.
        let open: @convention(block) (Int, Double) -> NSDictionary? = { [weak self] id, rate in
            CraftNativeScriptThread.onMain { self?.open(id, requestedRate: rate) as NSDictionary? }
        }
        let send: @convention(block) (JSValue) -> Void = { [weak self] batch in
            let commands = batch.toArray() ?? []
            CraftNativeScriptThread.onMain { self?.receive(commands) }
        }
        let time: @convention(block) (Int) -> Double = { [weak self] id in
            CraftNativeScriptThread.onMain { self?.contexts[id]?.graph.currentTime ?? 0 }
        }
        let read: @convention(block) (Int, Int, String) -> Double = { [weak self] contextId, nodeId, key in
            CraftNativeScriptThread.onMain { self?.read(contextId, nodeId, key) ?? .nan }
        }
        let state: @convention(block) (Int, String) -> Bool = { [weak self] id, state in
            CraftNativeScriptThread.onMain { self?.setState(id, state) ?? false }
        }
        let buffer: @convention(block) (Int, Double, Int, JSValue) -> Bool = { [weak self] id, rate, length, channels in
            // The samples are copied out of the script's typed arrays where
            // the script runs, then kept beside the graph.
            guard let data = Self.copyBuffer(rate, length, channels) else { return false }
            CraftNativeScriptThread.onMain { self?.buffers[id] = data }
            return true
        }
        context.setObject(open, forKeyedSubscript: "craftNativeAudioOpen" as NSString)
        context.setObject(send, forKeyedSubscript: "craftNativeAudioSend" as NSString)
        context.setObject(time, forKeyedSubscript: "craftNativeAudioTime" as NSString)
        context.setObject(read, forKeyedSubscript: "craftNativeAudioRead" as NSString)
        context.setObject(state, forKeyedSubscript: "craftNativeAudioState" as NSString)
        context.setObject(buffer, forKeyedSubscript: "craftNativeAudioBuffer" as NSString)
        context.evaluateScript(Self.script)
    }

    /// The screen closed: every context stops and the session is handed back.
    func close() {
        for id in Array(contexts.keys) { closeContext(id) }
        buffers.removeAll()
        stopEngine()
    }

    // MARK: Contexts

    private func open(_ id: Int, requestedRate: Double) -> [String: Any]? {
        let session = AVAudioSession.sharedInstance()
        let hardware = session.sampleRate > 0 ? session.sampleRate : 44_100
        let rate = (3_000...768_000).contains(requestedRate) ? requestedRate : hardware
        let graph = CraftAudioGraph(sampleRate: rate)
        let context = Context(graph: graph)
        contexts[id] = context
        context.nodes[0] = graph.destination
        if live {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
                contexts[id] = nil
                return nil
            }
            attachSource(context, format: format, to: self.engine ?? makeEngine())
            refreshEngine()
        }
        startPump()
        return ["sampleRate": rate, "outputLatency": live ? session.outputLatency : 0]
    }

    private func setState(_ id: Int, _ state: String) -> Bool {
        guard let context = contexts[id] else { return false }
        switch state {
        case "running", "suspended":
            context.running = state == "running"
            context.graph.setRunning(context.running)
            refreshEngine()
        case "closed":
            closeContext(id)
        default:
            return false
        }
        return true
    }

    private func closeContext(_ id: Int) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        if let source = context.source, let engine {
            engine.disconnectNodeOutput(source)
            engine.detach(source)
        }
        context.graph.setRunning(false)
        if contexts.isEmpty {
            stopEngine()
            pump?.invalidate()
            pump = nil
        } else {
            refreshEngine()
        }
    }

    // MARK: Engine and session

    /// A context's graph reaches the engine through a source node. Attached
    /// when the context opens, and again on a fresh engine for every live
    /// context after the media server restarts.
    private func attachSource(_ context: Context, format: AVAudioFormat, to engine: AVAudioEngine) {
        let graph = context.graph
        let source = AVAudioSourceNode(format: format) { silence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            silence.pointee = ObjCBool(graph.render(Int(frameCount), into: buffers))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        context.source = source
    }

    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        self.engine = engine
        let center = NotificationCenter.default
        // A route change (headphones) or an interruption (a call) stops the
        // engine; it starts again when the context still plays. This one is
        // scoped to the engine, so a rebuilt engine replaces it.
        if let engineObserver { center.removeObserver(engineObserver) }
        engineObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.refreshEngine()
        }
        // The rest are about the session and the app, not this engine.
        guard observers.isEmpty else { return engine }
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            if type == AVAudioSession.InterruptionType.ended.rawValue { self?.refreshEngine() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildEngine()
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshEngine()
        })
        return engine
    }

    /// The media server restarted, which orphans every audio object the
    /// process holds — this engine and the source nodes attached to it. An
    /// orphaned engine can be told to start and still produce no sound, and
    /// no configuration-change notification is posted for it, so
    /// `refreshEngine` cannot recover from this. Apple's requirement is to
    /// discard the orphans and make new ones.
    ///
    /// A context does survive, because `CraftAudioGraph` is pure synthesis
    /// holding no AVFoundation object: it is given a fresh source node on a
    /// fresh engine and keeps playing from where its own clock is. That is
    /// why this recovers where a file-backed sound reports the loss instead
    /// (`CraftNativeSounds.handleMediaReset`) — a player's playhead does not
    /// survive the reset, a synthesised graph does. Starting the new engine
    /// reactivates the session, so the claim this screen already holds does
    /// not need to be taken again.
    private func rebuildEngine() {
        guard live, let orphaned = engine else { return }
        for context in contexts.values {
            if let source = context.source {
                orphaned.disconnectNodeOutput(source)
                orphaned.detach(source)
            }
            context.source = nil
        }
        orphaned.stop()
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine = nil
        guard !contexts.isEmpty else { return }
        let engine = makeEngine()
        for context in contexts.values {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: context.graph.sampleRate, channels: 2) else { continue }
            attachSource(context, format: format, to: engine)
        }
        refreshEngine()
    }

    private func refreshEngine() {
        guard live, let engine else { return }
        let playing = contexts.values.contains { $0.running }
        if playing {
            if !claimedSession {
                claimedSession = true
                CraftNativeSounds.claimSession(respectSilentSwitch: true)
            }
            guard !engine.isRunning else { return }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                NSLog("[craft native] Web Audio could not start: %@", error.localizedDescription)
            }
        } else if engine.isRunning {
            engine.pause()
        }
    }

    private func stopEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        engine?.stop()
        engine = nil
        if claimedSession {
            claimedSession = false
            CraftNativeSounds.releaseSession()
        }
    }

    // MARK: Commands

    private func receive(_ commands: [Any]) {
        var batches: [Int: [CraftAudioOp]] = [:]
        for case let command as [Any] in commands {
            guard let name = command.first as? String else { continue }
            if name == "releaseBuffer" {
                buffers[int(command, 2)] = nil
                continue
            }
            let contextId = int(command, 1)
            guard let context = contexts[contextId] else { continue }
            if let op = op(name, command, context) { batches[contextId, default: []].append(op) }
        }
        for (id, ops) in batches { contexts[id]?.graph.enqueue(ops) }
    }

    private func op(_ name: String, _ command: [Any], _ context: Context) -> CraftAudioOp? {
        let id = int(command, 2)
        if name == "create" {
            create(id, kind: command.count > 3 ? command[3] as? String ?? "" : "", extra: double(command, 4), in: context)
            return nil
        }
        guard let node = context.nodes[id] else { return nil }
        switch name {
        case "connect":
            guard let target = context.nodes[int(command, 3)] else { return nil }
            return .connect(node, target)
        case "connectParam":
            guard let owner = context.nodes[int(command, 3)], let param = owner.param(string(command, 4)) else { return nil }
            return .connectParam(node, param, owner: owner)
        case "disconnect":
            if command.count <= 3 || command[3] is NSNull { return .disconnect(node, nil) }
            guard let target = context.nodes[int(command, 3)] else { return nil }
            if command.count > 4, let paramName = command[4] as? String {
                guard let param = target.param(paramName) else { return nil }
                return .disconnectParam(node, param)
            }
            return .disconnect(node, target)
        case "param":
            guard let param = node.param(string(command, 3)) else { return nil }
            let value = double(command, 5)
            let time = max(0, double(command, 6))
            let extra = double(command, 7)
            switch string(command, 4) {
            case "set": return .schedule(param, .init(kind: .set, time: time, value: value))
            case "linear": return .schedule(param, .init(kind: .linear, time: time, value: value, scheduledAt: extra))
            case "exponential": return .schedule(param, .init(kind: .exponential, time: time, value: value, scheduledAt: extra))
            case "target": return .schedule(param, .init(kind: .target, time: time, value: value, timeConstant: max(0, extra)))
            case "curve":
                let curve = (command.count > 5 ? command[5] as? [Any] : nil)?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                guard curve.count > 1 else { return nil }
                return .schedule(param, .init(kind: .curve, time: time, value: curve.last ?? 0, duration: max(0, extra), curve: curve))
            case "cancel": return .cancel(param, time, hold: false)
            case "hold": return .cancel(param, time, hold: true)
            default: return nil
            }
        case "start":
            guard let source = node as? CraftAudioSource else { return nil }
            return .start(source, when: max(0, double(command, 3)), offset: max(0, double(command, 4)), duration: double(command, 5))
        case "stop":
            guard let source = node as? CraftAudioSource else { return nil }
            return .stop(source, max(0, double(command, 3)))
        case "type":
            if let oscillator = node as? CraftAudioOscillator { return .shape(oscillator, int(command, 3)) }
            if let biquad = node as? CraftAudioBiquad { return .filter(biquad, int(command, 3)) }
            return nil
        case "buffer":
            guard let source = node as? CraftAudioBufferSource else { return nil }
            return .buffer(source, buffers[int(command, 3)])
        case "loop":
            guard let source = node as? CraftAudioBufferSource else { return nil }
            return .loop(source, (command.count > 3 ? command[3] as? Bool : nil) ?? false, double(command, 4), double(command, 5))
        case "convolver":
            guard let convolver = node as? CraftAudioConvolver else { return nil }
            let normalize = (command.count > 4 ? command[4] as? Bool : nil) ?? true
            let data = command.count > 3 && !(command[3] is NSNull) ? buffers[int(command, 3)] : nil
            // The FFTs of the impulse response are worked out here, off the
            // render thread.
            return .convolution(convolver, data.map { CraftAudioConvolution(buffer: $0, normalize: normalize) })
        case "release":
            return .release(node)
        default:
            return nil
        }
    }

    private func create(_ id: Int, kind: String, extra: Double, in context: Context) {
        guard id > 0, context.nodes[id] == nil else { return }
        let rate = context.graph.sampleRate
        let node: CraftAudioNode
        switch kind {
        case "destination":
            context.nodes[id] = context.graph.destination
            return
        case "gain": node = CraftAudioGain(id: id)
        case "oscillator": node = CraftAudioOscillator(id: id, sampleRate: rate)
        case "bufferSource": node = CraftAudioBufferSource(id: id)
        case "biquad": node = CraftAudioBiquad(id: id, sampleRate: rate)
        case "delay": node = CraftAudioDelay(id: id, sampleRate: rate, maxDelay: min(180, max(1 / rate, extra > 0 ? extra : 1)))
        case "compressor": node = CraftAudioCompressor(id: id)
        case "convolver": node = CraftAudioConvolver(id: id)
        default: return
        }
        context.nodes[id] = node
    }

    private func read(_ contextId: Int, _ nodeId: Int, _ key: String) -> Double {
        guard let node = contexts[contextId]?.nodes[nodeId] else { return .nan }
        if key == "reduction" { return (node as? CraftAudioCompressor)?.reduction ?? .nan }
        return node.param(key)?.current ?? .nan
    }

    /// An AudioBuffer's channels, copied straight out of its Float32Arrays.
    private static func copyBuffer(_ rate: Double, _ length: Int, _ channels: JSValue) -> CraftAudioBufferData? {
        guard length > 0, rate > 0, let context = JSContext.current() else { return nil }
        let count = Int(channels.objectForKeyedSubscript("length")?.toInt32() ?? 0)
        guard count > 0 else { return nil }
        let data = CraftAudioBufferData(sampleRate: rate, length: length, channelCount: count)
        let script = context.jsGlobalContextRef
        for index in 0..<count {
            guard let channel = channels.atIndex(index), !channel.isNull, !channel.isUndefined,
                  JSValueGetTypedArrayType(script, channel.jsValueRef, nil) == kJSTypedArrayTypeFloat32Array,
                  let object = JSValueToObject(script, channel.jsValueRef, nil),
                  let bytes = JSObjectGetTypedArrayBytesPtr(script, object, nil) else { continue }
            let available = JSObjectGetTypedArrayLength(script, object, nil)
            data.channels[index].update(from: bytes.assumingMemoryBound(to: Float.self), count: min(length, available))
        }
        return data
    }

    // MARK: Notices

    private func startPump() {
        guard pump == nil else { return }
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.deliver() }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer
    }

    /// Ended sources to their `onended`, removed nodes out of the table.
    func deliver() {
        var ended: [[Any]] = []
        for (id, context) in contexts {
            for notice in context.graph.collect() {
                switch notice {
                case .ended(let node): ended.append([id, node, "ended"])
                case .removed(let node): context.nodes[node] = nil
                }
            }
        }
        guard !ended.isEmpty, let script else { return }
        CraftNativeScriptThread.run { script.objectForKeyedSubscript("__craftNativeAudioEvents")?.call(withArguments: [ended]) }
    }

    // MARK: Tests

    /// Renders a context by hand (no engine), as `live: false` tests do.
    func renderForTesting(_ contextId: Int, frames: Int) -> (left: [Float], right: [Float]) {
        guard let graph = contexts[contextId]?.graph else { return ([], []) }
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var done = 0
                while done < frames {
                    let count = min(512, frames - done)
                    graph.render(count, left: l.baseAddress! + done, right: r.baseAddress! + done)
                    done += count
                }
            }
        }
        deliver()
        return (left, right)
    }

    /// The nodes a context still keeps, the destination included.
    func nodeCountForTesting(_ contextId: Int) -> Int {
        contexts[contextId]?.nodes.count ?? 0
    }

    var contextIdsForTesting: [Int] { Array(contexts.keys).sorted() }
    /// The engine and a context's source node, so a test can see that a
    /// media-services reset replaced them rather than restarting orphans
    /// (`rebuildEngine`). Posting the notification cannot really orphan them,
    /// so identity is the only observable; the clock moving afterwards is
    /// what shows the replacements actually render.
    var engineForTesting: AVAudioEngine? { engine }
    func sourceForTesting(_ contextId: Int) -> AVAudioSourceNode? { contexts[contextId]?.source }

    // MARK: Helpers

    private func int(_ command: [Any], _ index: Int) -> Int {
        index < command.count ? (command[index] as? NSNumber)?.intValue ?? 0 : 0
    }

    private func double(_ command: [Any], _ index: Int) -> Double {
        index < command.count ? (command[index] as? NSNumber)?.doubleValue ?? 0 : 0
    }

    private func string(_ command: [Any], _ index: Int) -> String {
        index < command.count ? command[index] as? String ?? "" : ""
    }
}

// MARK: - The script's half

extension CraftWebAudio {
    /// The standard Web Audio API for a native screen's JavaScript. Calls are
    /// queued and sent once per turn of the script; the clock and param reads
    /// are synchronous. A node the script lets go of (FinalizationRegistry)
    /// is released here and freed once it can no longer sound.
    static let script = #"""
    (function() {
        if (typeof globalThis.AudioContext === 'function' || typeof craftNativeAudioOpen !== 'function') return;
        var FLT = 3.4028234663852886e38;
        var nextId = 0;
        var queue = [];
        var pending = false;
        var contexts = {};

        function flush() {
            pending = false;
            if (!queue.length) return;
            var batch = queue;
            queue = [];
            craftNativeAudioSend(batch);
        }
        function send(command) {
            queue.push(command);
            if (!pending) {
                pending = true;
                Promise.resolve().then(flush);
            }
        }
        var finalizer = typeof FinalizationRegistry === 'function'
            ? new FinalizationRegistry(function(held) { send(held); })
            : null;
        function track(object, held) {
            if (finalizer) finalizer.register(object, held);
        }
        function failure(name, message) {
            if (typeof DOMException === 'function') return new DOMException(message, name);
            var error = new Error(message);
            error.name = name;
            return error;
        }
        function finite(value, what) {
            var number = Number(value);
            if (!isFinite(number)) throw new TypeError(what + ' must be a finite number');
            return number;
        }
        function when(value, what) {
            var number = finite(value === undefined ? 0 : value, what);
            if (number < 0) throw new RangeError(what + ' must not be negative');
            return number;
        }
        function define(prototype, name, get, set) {
            Object.defineProperty(prototype, name, { configurable: true, enumerable: true, get: get, set: set });
        }
        function inherit(Child, Parent) {
            Child.prototype = Object.create(Parent.prototype);
            Child.prototype.constructor = Child;
        }
        function makeEvent(type, target) {
            return {
                type: type, target: target, currentTarget: target, timeStamp: Date.now(),
                bubbles: false, cancelable: false, defaultPrevented: false,
                preventDefault: function() {}, stopPropagation: function() {}, stopImmediatePropagation: function() {}
            };
        }
        function report(error) {
            if (typeof console !== 'undefined' && console.error) console.error(error && error.stack ? error.stack : String(error));
        }
        function eventTarget(prototype) {
            prototype.addEventListener = function(type, listener) {
                if (!listener) return;
                var all = this._listeners || (this._listeners = {});
                var list = all[type] || (all[type] = []);
                if (list.indexOf(listener) < 0) list.push(listener);
            };
            prototype.removeEventListener = function(type, listener) {
                var list = this._listeners && this._listeners[type];
                var index = list ? list.indexOf(listener) : -1;
                if (index >= 0) list.splice(index, 1);
            };
            prototype.dispatchEvent = function(event) {
                var listeners = [];
                var handler = this['on' + event.type];
                if (typeof handler === 'function') listeners.push(handler);
                var list = this._listeners && this._listeners[event.type];
                if (list) listeners = listeners.concat(list);
                for (var i = 0; i < listeners.length; i++) {
                    try {
                        if (typeof listeners[i] === 'function') listeners[i].call(this, event);
                        else if (listeners[i] && typeof listeners[i].handleEvent === 'function') listeners[i].handleEvent(event);
                    } catch (error) {
                        report(error);
                    }
                }
                return true;
            };
        }

        // AudioParam --------------------------------------------------------

        function AudioParam(node, name, value, min, max, rate) {
            this._context = node.context;
            this._node = node._id;
            this._name = name;
            this._value = value;
            this._automated = false;
            this._fresh = true;
            this.defaultValue = value;
            this.minValue = min;
            this.maxValue = max;
            this.automationRate = rate;
        }
        define(AudioParam.prototype, 'value', function() {
            if (this._automated && !this._fresh) {
                flush();
                var read = craftNativeAudioRead(this._context._id, this._node, this._name);
                if (typeof read === 'number' && isFinite(read)) return read;
            }
            return this._value;
        }, function(value) {
            var number = finite(value, 'AudioParam.value');
            this._value = number;
            this._fresh = true;
            send(['param', this._context._id, this._node, this._name, 'set', number, this._context.currentTime, 0]);
        });
        AudioParam.prototype._schedule = function(kind, value, time, extra) {
            this._automated = true;
            this._fresh = false;
            send(['param', this._context._id, this._node, this._name, kind, value, time, extra]);
            return this;
        };
        AudioParam.prototype.setValueAtTime = function(value, startTime) {
            return this._schedule('set', finite(value, 'value'), when(startTime, 'startTime'), 0);
        };
        AudioParam.prototype.linearRampToValueAtTime = function(value, endTime) {
            return this._schedule('linear', finite(value, 'value'), when(endTime, 'endTime'), this._context.currentTime);
        };
        AudioParam.prototype.exponentialRampToValueAtTime = function(value, endTime) {
            var number = finite(value, 'value');
            if (number === 0) throw new RangeError('exponentialRampToValueAtTime needs a value other than 0');
            return this._schedule('exponential', number, when(endTime, 'endTime'), this._context.currentTime);
        };
        AudioParam.prototype.setTargetAtTime = function(target, startTime, timeConstant) {
            var constant = finite(timeConstant, 'timeConstant');
            if (constant < 0) throw new RangeError('timeConstant must not be negative');
            return this._schedule('target', finite(target, 'target'), when(startTime, 'startTime'), constant);
        };
        AudioParam.prototype.setValueCurveAtTime = function(values, startTime, duration) {
            var curve = Array.prototype.slice.call(values || []).map(function(value) { return finite(value, 'curve value'); });
            if (curve.length < 2) throw failure('InvalidStateError', 'setValueCurveAtTime needs at least two values');
            var length = finite(duration, 'duration');
            if (length <= 0) throw new RangeError('duration must be above 0');
            return this._schedule('curve', curve, when(startTime, 'startTime'), length);
        };
        AudioParam.prototype.cancelScheduledValues = function(cancelTime) {
            return this._schedule('cancel', 0, when(cancelTime, 'cancelTime'), 0);
        };
        AudioParam.prototype.cancelAndHoldAtTime = function(cancelTime) {
            return this._schedule('hold', 0, when(cancelTime, 'cancelTime'), 0);
        };

        // Nodes -------------------------------------------------------------

        function BaseAudioContext() { throw new TypeError('Illegal constructor'); }
        eventTarget(BaseAudioContext.prototype);

        function AudioNode(context, kind, inputs, outputs, extra) {
            if (!(context instanceof BaseAudioContext)) throw new TypeError('An audio node needs its AudioContext');
            this.context = context;
            this._id = ++nextId;
            this.numberOfInputs = inputs;
            this.numberOfOutputs = outputs;
            this.channelCount = 2;
            this.channelCountMode = 'max';
            this.channelInterpretation = 'speakers';
            send(['create', context._id, this._id, kind, extra === undefined ? 0 : extra]);
            if (kind !== 'destination') track(this, ['release', context._id, this._id]);
        }
        eventTarget(AudioNode.prototype);
        AudioNode.prototype.connect = function(destination, output, input) {
            if (destination instanceof AudioParam) {
                if (destination._context !== this.context) throw failure('InvalidAccessError', 'The AudioParam belongs to another AudioContext');
                send(['connectParam', this.context._id, this._id, destination._node, destination._name]);
                return undefined;
            }
            if (!(destination instanceof AudioNode)) throw new TypeError('connect needs an AudioNode or an AudioParam');
            if (destination.context !== this.context) throw failure('InvalidAccessError', 'The AudioNode belongs to another AudioContext');
            if ((output || 0) >= this.numberOfOutputs) throw failure('IndexSizeError', 'The node has no output ' + output);
            if ((input || 0) >= destination.numberOfInputs) throw failure('IndexSizeError', 'The node has no input ' + input);
            send(['connect', this.context._id, this._id, destination._id]);
            return destination;
        };
        AudioNode.prototype.disconnect = function(destination) {
            if (destination === undefined || typeof destination === 'number') send(['disconnect', this.context._id, this._id, null, null]);
            else if (destination instanceof AudioParam) send(['disconnect', this.context._id, this._id, destination._node, destination._name]);
            else if (destination instanceof AudioNode) send(['disconnect', this.context._id, this._id, destination._id, null]);
            else throw new TypeError('disconnect needs an AudioNode or an AudioParam');
        };
        function param(node, name, value, min, max, rate) {
            var created = new AudioParam(node, name, value, min, max, rate || 'a-rate');
            Object.defineProperty(node, name, { value: created, enumerable: true });
            return created;
        }
        function apply(node, given, names) {
            names.forEach(function(name) {
                if (given && given[name] !== undefined) node[name].value = given[name];
            });
        }

        function AudioDestinationNode(context) {
            AudioNode.call(this, context, 'destination', 1, 0);
            this.maxChannelCount = 2;
        }
        inherit(AudioDestinationNode, AudioNode);

        function GainNode(context, given) {
            AudioNode.call(this, context, 'gain', 1, 1);
            param(this, 'gain', 1, -FLT, FLT);
            apply(this, given, ['gain']);
        }
        inherit(GainNode, AudioNode);

        function AudioScheduledSourceNode(context, kind) {
            AudioNode.call(this, context, kind, 0, 1);
            this.onended = null;
            this._started = false;
        }
        inherit(AudioScheduledSourceNode, AudioNode);
        AudioScheduledSourceNode.prototype._begin = function(time, offset, duration) {
            if (this._started) throw failure('InvalidStateError', 'start() may be called only once');
            var at = when(time, 'when');
            this._started = true;
            // Playing keeps the node alive until it ends, as in a browser.
            if (this.context._state !== 'closed') this.context._playing[this._id] = this;
            send(['start', this.context._id, this._id, at, offset, duration]);
        };
        AudioScheduledSourceNode.prototype.start = function(time) {
            this._begin(time, 0, -1);
        };
        AudioScheduledSourceNode.prototype.stop = function(time) {
            if (!this._started) throw failure('InvalidStateError', 'stop() needs start() first');
            send(['stop', this.context._id, this._id, when(time, 'when')]);
        };

        var oscillatorTypes = ['sine', 'square', 'sawtooth', 'triangle'];
        function OscillatorNode(context, given) {
            AudioScheduledSourceNode.call(this, context, 'oscillator');
            var nyquist = context.sampleRate / 2;
            param(this, 'frequency', 440, -nyquist, nyquist);
            param(this, 'detune', 0, -153600, 153600);
            this._type = 'sine';
            if (given && given.type !== undefined) this.type = given.type;
            apply(this, given, ['frequency', 'detune']);
        }
        inherit(OscillatorNode, AudioScheduledSourceNode);
        define(OscillatorNode.prototype, 'type', function() { return this._type; }, function(value) {
            if (value === 'custom') throw failure('InvalidStateError', 'A custom oscillator needs setPeriodicWave');
            var index = oscillatorTypes.indexOf(value);
            if (index < 0 || value === this._type) return;
            this._type = value;
            send(['type', this.context._id, this._id, index]);
        });
        OscillatorNode.prototype.setPeriodicWave = function() {
            throw failure('NotSupportedError', 'Native screens play sine, square, sawtooth and triangle oscillators');
        };

        function AudioBufferSourceNode(context, given) {
            AudioScheduledSourceNode.call(this, context, 'bufferSource');
            param(this, 'playbackRate', 1, -FLT, FLT, 'k-rate');
            param(this, 'detune', 0, -FLT, FLT, 'k-rate');
            this._buffer = null;
            this._loop = false;
            this._loopStart = 0;
            this._loopEnd = 0;
            given = given || {};
            if (given.buffer) this.buffer = given.buffer;
            if (given.loop !== undefined) this.loop = given.loop;
            if (given.loopStart !== undefined) this.loopStart = given.loopStart;
            if (given.loopEnd !== undefined) this.loopEnd = given.loopEnd;
            apply(this, given, ['playbackRate', 'detune']);
        }
        inherit(AudioBufferSourceNode, AudioScheduledSourceNode);
        define(AudioBufferSourceNode.prototype, 'buffer', function() { return this._buffer; }, function(value) {
            if (value === undefined) value = null;
            if (value !== null && !(value instanceof AudioBuffer)) throw new TypeError('buffer must be an AudioBuffer');
            if (value !== null && this._buffer !== null) throw failure('InvalidStateError', 'The buffer may be set only once');
            this._buffer = value;
            if (value && this._started) this._acquire();
        });
        AudioBufferSourceNode.prototype._acquire = function() {
            upload(this._buffer);
            send(['buffer', this.context._id, this._id, this._buffer._id]);
        };
        AudioBufferSourceNode.prototype._sendLoop = function() {
            send(['loop', this.context._id, this._id, this._loop, this._loopStart, this._loopEnd]);
        };
        define(AudioBufferSourceNode.prototype, 'loop', function() { return this._loop; }, function(value) {
            this._loop = !!value;
            this._sendLoop();
        });
        define(AudioBufferSourceNode.prototype, 'loopStart', function() { return this._loopStart; }, function(value) {
            this._loopStart = finite(value, 'loopStart');
            this._sendLoop();
        });
        define(AudioBufferSourceNode.prototype, 'loopEnd', function() { return this._loopEnd; }, function(value) {
            this._loopEnd = finite(value, 'loopEnd');
            this._sendLoop();
        });
        AudioBufferSourceNode.prototype.start = function(time, offset, duration) {
            if (this._started) throw failure('InvalidStateError', 'start() may be called only once');
            var from = offset === undefined ? 0 : when(offset, 'offset');
            var length = duration === undefined ? -1 : when(duration, 'duration');
            if (this._buffer) this._acquire();
            this._begin(time, from, length);
        };

        var filterTypes = ['lowpass', 'highpass', 'bandpass', 'lowshelf', 'highshelf', 'peaking', 'notch', 'allpass'];
        function BiquadFilterNode(context, given) {
            AudioNode.call(this, context, 'biquad', 1, 1);
            param(this, 'frequency', 350, 0, context.sampleRate / 2);
            param(this, 'detune', 0, -153600, 153600);
            param(this, 'Q', 1, -FLT, FLT);
            param(this, 'gain', 0, -FLT, 1541);
            this._type = 'lowpass';
            if (given && given.type !== undefined) this.type = given.type;
            apply(this, given, ['frequency', 'detune', 'Q', 'gain']);
        }
        inherit(BiquadFilterNode, AudioNode);
        define(BiquadFilterNode.prototype, 'type', function() { return this._type; }, function(value) {
            var index = filterTypes.indexOf(value);
            if (index < 0 || value === this._type) return;
            this._type = value;
            send(['type', this.context._id, this._id, index]);
        });

        function DelayNode(context, given) {
            var max = given && given.maxDelayTime !== undefined ? Number(given.maxDelayTime) : 1;
            if (!(max > 0 && max < 180)) throw failure('NotSupportedError', 'maxDelayTime must be above 0 and under 180 seconds');
            AudioNode.call(this, context, 'delay', 1, 1, max);
            param(this, 'delayTime', 0, 0, max);
            apply(this, given, ['delayTime']);
        }
        inherit(DelayNode, AudioNode);

        function DynamicsCompressorNode(context, given) {
            AudioNode.call(this, context, 'compressor', 1, 1);
            param(this, 'threshold', -24, -100, 0, 'k-rate');
            param(this, 'knee', 30, 0, 40, 'k-rate');
            param(this, 'ratio', 12, 1, 20, 'k-rate');
            param(this, 'attack', 0.003, 0, 1, 'k-rate');
            param(this, 'release', 0.25, 0, 1, 'k-rate');
            apply(this, given, ['threshold', 'knee', 'ratio', 'attack', 'release']);
        }
        inherit(DynamicsCompressorNode, AudioNode);
        define(DynamicsCompressorNode.prototype, 'reduction', function() {
            flush();
            var value = craftNativeAudioRead(this.context._id, this._id, 'reduction');
            return typeof value === 'number' && isFinite(value) ? value : 0;
        });

        function ConvolverNode(context, given) {
            AudioNode.call(this, context, 'convolver', 1, 1);
            this._buffer = null;
            this.normalize = !(given && given.disableNormalization);
            if (given && given.buffer) this.buffer = given.buffer;
        }
        inherit(ConvolverNode, AudioNode);
        define(ConvolverNode.prototype, 'buffer', function() { return this._buffer; }, function(value) {
            if (value === undefined) value = null;
            if (value !== null) {
                if (!(value instanceof AudioBuffer)) throw new TypeError('buffer must be an AudioBuffer');
                var channels = value.numberOfChannels;
                if (channels !== 1 && channels !== 2 && channels !== 4) throw failure('NotSupportedError', 'A convolver takes an impulse response of 1, 2 or 4 channels');
                if (value.sampleRate !== this.context.sampleRate) throw failure('NotSupportedError', "The impulse response must have the context's sample rate");
                upload(value);
            }
            this._buffer = value;
            send(['convolver', this.context._id, this._id, value ? value._id : null, !!this.normalize]);
        });

        // AudioBuffer -------------------------------------------------------

        function AudioBuffer(given) {
            if (!given || typeof given !== 'object') throw new TypeError('AudioBuffer needs { length, sampleRate }');
            var channels = given.numberOfChannels === undefined ? 1 : Math.floor(Number(given.numberOfChannels));
            var length = Math.floor(Number(given.length));
            var rate = Number(given.sampleRate);
            if (!(channels >= 1 && channels <= 32)) throw failure('NotSupportedError', 'An AudioBuffer has 1 to 32 channels');
            if (!(length >= 1)) throw failure('NotSupportedError', 'An AudioBuffer needs at least one frame');
            if (!(rate >= 3000 && rate <= 768000)) throw failure('NotSupportedError', 'An AudioBuffer sample rate is 3000 to 768000');
            this._id = ++nextId;
            this._length = length;
            this._rate = rate;
            this._channels = [];
            for (var i = 0; i < channels; i++) this._channels.push(null);
            this._dirty = false;
            this._uploaded = false;
            track(this, ['releaseBuffer', 0, this._id]);
        }
        define(AudioBuffer.prototype, 'length', function() { return this._length; });
        define(AudioBuffer.prototype, 'sampleRate', function() { return this._rate; });
        define(AudioBuffer.prototype, 'numberOfChannels', function() { return this._channels.length; });
        define(AudioBuffer.prototype, 'duration', function() { return this._length / this._rate; });
        AudioBuffer.prototype._channel = function(channel) {
            var index = Number(channel);
            if (!(index >= 0 && index < this._channels.length) || Math.floor(index) !== index) throw failure('IndexSizeError', 'The AudioBuffer has no channel ' + channel);
            return index;
        };
        AudioBuffer.prototype.getChannelData = function(channel) {
            var index = this._channel(channel);
            var data = this._channels[index] || (this._channels[index] = new Float32Array(this._length));
            // The caller may write into it: send it again when next used.
            this._dirty = true;
            return data;
        };
        AudioBuffer.prototype.copyFromChannel = function(destination, channel, start) {
            if (!(destination instanceof Float32Array)) throw new TypeError('copyFromChannel needs a Float32Array');
            var from = start === undefined ? 0 : Math.max(0, Math.floor(Number(start)) || 0);
            var data = this._channels[this._channel(channel)];
            var count = Math.max(0, Math.min(destination.length, this._length - from));
            if (!data) destination.fill(0, 0, count);
            else destination.set(data.subarray(from, from + count));
        };
        AudioBuffer.prototype.copyToChannel = function(source, channel, start) {
            if (!(source instanceof Float32Array)) throw new TypeError('copyToChannel needs a Float32Array');
            var from = start === undefined ? 0 : Math.max(0, Math.floor(Number(start)) || 0);
            var data = this.getChannelData(channel);
            var count = Math.max(0, Math.min(source.length, this._length - from));
            data.set(source.subarray(0, count), from);
        };
        function upload(buffer) {
            if (buffer._uploaded && !buffer._dirty) return;
            buffer._uploaded = true;
            buffer._dirty = false;
            craftNativeAudioBuffer(buffer._id, buffer._rate, buffer._length, buffer._channels);
        }

        // AudioContext ------------------------------------------------------

        function AudioContext(given) {
            var requested = 0;
            if (given && given.sampleRate !== undefined) {
                requested = Number(given.sampleRate);
                if (!(requested >= 3000 && requested <= 768000)) throw failure('NotSupportedError', 'sampleRate must be 3000 to 768000');
            }
            var id = ++nextId;
            var info = craftNativeAudioOpen(id, requested);
            if (!info) throw failure('NotSupportedError', 'Audio could not start on this device');
            this._id = id;
            this._state = 'running';
            this._playing = {};
            this._closedTime = 0;
            this.sampleRate = info.sampleRate;
            this.baseLatency = 128 / info.sampleRate;
            this.outputLatency = info.outputLatency || 0;
            this.onstatechange = null;
            this.listener = {};
            contexts[id] = this;
            this.destination = new AudioDestinationNode(this);
        }
        AudioContext.prototype = Object.create(BaseAudioContext.prototype);
        AudioContext.prototype.constructor = AudioContext;
        define(BaseAudioContext.prototype, 'currentTime', function() {
            return this._state === 'closed' ? this._closedTime : craftNativeAudioTime(this._id);
        });
        define(BaseAudioContext.prototype, 'state', function() { return this._state; });
        BaseAudioContext.prototype._change = function(state) {
            flush();
            if (state === 'closed') this._closedTime = craftNativeAudioTime(this._id);
            craftNativeAudioState(this._id, state);
            if (this._state === state) return;
            this._state = state;
            var context = this;
            Promise.resolve().then(function() { context.dispatchEvent(makeEvent('statechange', context)); });
        };
        AudioContext.prototype.resume = function() {
            if (this._state === 'closed') return Promise.reject(failure('InvalidStateError', 'The AudioContext is closed'));
            this._change('running');
            return Promise.resolve();
        };
        AudioContext.prototype.suspend = function() {
            if (this._state === 'closed') return Promise.reject(failure('InvalidStateError', 'The AudioContext is closed'));
            this._change('suspended');
            return Promise.resolve();
        };
        AudioContext.prototype.close = function() {
            if (this._state === 'closed') return Promise.reject(failure('InvalidStateError', 'The AudioContext is already closed'));
            this._change('closed');
            delete contexts[this._id];
            this._playing = {};
            return Promise.resolve();
        };
        AudioContext.prototype.getOutputTimestamp = function() {
            var now = typeof performance !== 'undefined' && performance.now ? performance.now() : Date.now();
            return { contextTime: this.currentTime, performanceTime: now };
        };
        BaseAudioContext.prototype.createGain = function() { return new GainNode(this); };
        BaseAudioContext.prototype.createOscillator = function() { return new OscillatorNode(this); };
        BaseAudioContext.prototype.createBufferSource = function() { return new AudioBufferSourceNode(this); };
        BaseAudioContext.prototype.createBiquadFilter = function() { return new BiquadFilterNode(this); };
        BaseAudioContext.prototype.createDelay = function(maxDelayTime) {
            return new DelayNode(this, { maxDelayTime: maxDelayTime === undefined ? 1 : maxDelayTime });
        };
        BaseAudioContext.prototype.createDynamicsCompressor = function() { return new DynamicsCompressorNode(this); };
        BaseAudioContext.prototype.createConvolver = function() { return new ConvolverNode(this); };
        BaseAudioContext.prototype.createBuffer = function(numberOfChannels, length, sampleRate) {
            return new AudioBuffer({ numberOfChannels: numberOfChannels, length: length, sampleRate: sampleRate });
        };
        BaseAudioContext.prototype.decodeAudioData = function(data, success, error) {
            var problem = failure('NotSupportedError', 'Native screens decode no audio files: synthesise the sound, or play a file with craft.audio');
            if (typeof error === 'function') error(problem);
            return Promise.reject(problem);
        };

        // Ended sources, from the host.
        globalThis.__craftNativeAudioEvents = function(events) {
            for (var i = 0; i < events.length; i++) {
                var entry = events[i];
                var context = contexts[entry[0]];
                var node = context && context._playing[entry[1]];
                if (!node) continue;
                delete context._playing[entry[1]];
                if (entry[2] === 'ended') node.dispatchEvent(makeEvent('ended', node));
            }
        };

        globalThis.AudioContext = AudioContext;
        globalThis.webkitAudioContext = AudioContext;
        globalThis.BaseAudioContext = BaseAudioContext;
        globalThis.AudioNode = AudioNode;
        globalThis.AudioParam = AudioParam;
        globalThis.AudioBuffer = AudioBuffer;
        globalThis.AudioScheduledSourceNode = AudioScheduledSourceNode;
        globalThis.AudioDestinationNode = AudioDestinationNode;
        globalThis.GainNode = GainNode;
        globalThis.OscillatorNode = OscillatorNode;
        globalThis.AudioBufferSourceNode = AudioBufferSourceNode;
        globalThis.BiquadFilterNode = BiquadFilterNode;
        globalThis.DelayNode = DelayNode;
        globalThis.DynamicsCompressorNode = DynamicsCompressorNode;
        globalThis.ConvolverNode = ConvolverNode;
    })();
    """#
}
