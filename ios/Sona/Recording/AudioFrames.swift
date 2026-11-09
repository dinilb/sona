import AVFoundation
import Foundation

// Everything here runs off the main thread (the mic's tap thread, the debug file's queue), so it's all nonisolated.

/// 100 ms of audio: 1600 samples of 16 kHz mono Int16, with its loudness.
nonisolated struct AudioFrame: Sendable {
    static let sampleRate = 16_000
    static let samples = 1600  // 100 ms

    let samples: [Int16]
    /// When the first sample was heard, in seconds on a clock that only counts forward: the monotonic clock for the
    /// mic (it keeps counting while the iPhone sleeps, and changing the time of day doesn't move it), the wall clock for
    /// the debug file. Only differences within one recording mean anything: the gap a call left
    /// (`SpoolRecording.fillPause`).
    let time: TimeInterval
    /// Loudness in dBFS, -100 for silence.
    let levelDB: Double

    /// The samples as -1...1, for `WavFile.append`.
    var floats: [Float] { samples.map { Float($0) / 32768 } }
}

/// What a capture tells its owner. Both are called off the main thread.
nonisolated struct CaptureHandlers: Sendable {
    var frame: @Sendable (AudioFrame) -> Void
    var state: @Sendable (CaptureState, String?) -> Void
}

nonisolated enum CaptureState: String, Sendable {
    case running
    /// A call, Siri or an alarm has the mic; it comes back by itself.
    case interrupted
    /// Several tries to get the mic back failed: opening the app usually fixes it (retries carry on meanwhile).
    case needsResume
    case stopped
    case error
}

/// Something that turns audio into frames: the mic, or a file in debug builds.
nonisolated protocol AudioSource: AnyObject, Sendable {
    func start() throws
    func stop()
}

nonisolated enum AudioLevel {
    /// dBFS of the samples' RMS; -100 for silence.
    static func decibels(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return -100 }
        var sum: Double = 0
        for s in samples {
            let v = Double(s) / 32768
            sum += v * v
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms > 0 ? max(-100, 20 * log10(rms)) : -100
    }

    /// 0...1 for the live waveform: -50 dBFS (a quiet room) is 0, -10 dBFS (talking close) is 1.
    static func unit(_ db: Double) -> Float {
        Float(min(1, max(0, (db + 50) / 40)))
    }
}

/// Cuts a stream of 16 kHz samples into 100 ms frames, carrying the remainder to the next call.
nonisolated struct FrameChunker {
    private(set) var pending: [Int16] = []
    private var pendingStart: TimeInterval = 0

    /// `time`: when the first of these samples was heard (see `AudioFrame.time`).
    mutating func append(_ samples: UnsafeBufferPointer<Int16>, at time: TimeInterval) -> [AudioFrame] {
        if pending.isEmpty { pendingStart = time }
        pending.append(contentsOf: samples)
        var frames: [AudioFrame] = []
        while pending.count >= AudioFrame.samples {
            let chunk = Array(pending[0..<AudioFrame.samples])
            pending.removeFirst(AudioFrame.samples)
            frames.append(AudioFrame(samples: chunk, time: pendingStart, levelDB: AudioLevel.decibels(chunk)))
            pendingStart += Double(AudioFrame.samples) / Double(AudioFrame.sampleRate)
        }
        return frames
    }

    mutating func append(_ samples: [Int16], at time: TimeInterval) -> [AudioFrame] {
        samples.withUnsafeBufferPointer { append($0, at: time) }
    }
}

/// Converts buffers of any format (the mic's 48 kHz, a file's) to 16 kHz mono Int16 and cuts them into frames. The
/// mic and the debug file both go through it. Used from one thread at a time (the tap's, or the file's queue).
nonisolated final class FrameMaker: @unchecked Sendable {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(AudioFrame.sampleRate), channels: 1, interleaved: true)!

    private let converter: AVAudioConverter
    private var chunker = FrameChunker()
    private let onFrame: @Sendable (AudioFrame) -> Void

    init?(from input: AVAudioFormat, onFrame: @escaping @Sendable (AudioFrame) -> Void) {
        guard let converter = AVAudioConverter(from: input, to: Self.format) else { return nil }
        converter.downmix = true  // stereo files: both channels, not just the left
        self.converter = converter
        self.onFrame = onFrame
    }

    /// The mic's buffers: now on the monotonic clock, less how long ago the host clock says the buffer was heard. Not
    /// the wall clock: a time change or a network time fix mid-recording would read as a call-sized gap (up to an hour
    /// of silence put in) or hide a real one.
    func process(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        var start = Self.monotonicNow()
        if when.isHostTimeValid {
            let age = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: when.hostTime)
            start -= max(0, age)
        }
        process(buffer, startingAt: start)
    }

    /// Seconds on CLOCK_MONOTONIC, which on Darwin keeps counting while the device sleeps (mach_absolute_time and
    /// CLOCK_UPTIME_RAW stop), so a call gap with the phone locked is measured in full.
    static func monotonicNow() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
    }

    /// `time`: when the buffer's first sample was heard, on one clock for the whole recording (see `AudioFrame.time`).
    func process(_ buffer: AVAudioPCMBuffer, startingAt time: TimeInterval) {
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        for frame in chunker.append(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)), at: time) {
            onFrame(frame)
        }
    }
}
