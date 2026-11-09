import AVFoundation
import Foundation

/// What an engine just recognised. Times are seconds into the session's audio.
public struct LiveUpdate: Sendable {
    /// Text that won't change any more, appended to the transcript.
    public var appendFinal = ""
    /// The tentative tail that replaces the previous one (nil leaves it alone). Only Apple's engine has one.
    public var volatile: String?
    /// Audio end time of each word (or token) shown for the first time in this update.
    public var heard: [Double] = []
    /// Audio end time of each word that just became final.
    public var locked: [Double] = []
    /// The same new text as timed tokens, for engines that have honest timings (the Parakeet ones).
    public var tokens: [LiveToken] = []
    /// New 10 ms frames from the diarizer: who's talking (-1 for nobody).
    public var speakerFrames: [Int8] = []
    /// The diarizer failed; words carry on without speakers for the rest of the session.
    public var speakersFailed = false

    public init(
        appendFinal: String = "", volatile: String? = nil, heard: [Double] = [], locked: [Double] = [],
        tokens: [LiveToken] = [], speakerFrames: [Int8] = [], speakersFailed: Bool = false
    ) {
        self.speakersFailed = speakersFailed
        self.appendFinal = appendFinal
        self.volatile = volatile
        self.heard = heard
        self.locked = locked
        self.tokens = tokens
        self.speakerFrames = speakerFrames
    }
}


/// A streaming speech-to-text engine. Fed 16 kHz mono audio in order, it calls back as words appear.
public protocol LiveEngine: AnyObject, Sendable {
    var name: String { get }
    /// Built-in delay of the model itself, before any compute.
    var modelDelay: String { get }
    /// Audio past a word the engine must hear before that word comes out (chunk plus right context).
    var lookaheadSeconds: Double { get }
    /// Downloads (once) and loads the model. Safe to call again.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws
    /// Starts a fresh session. `onUpdate` is called on an arbitrary thread.
    func start(onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws
    /// 16 kHz mono samples, in order, from sample 0 of the session.
    func feed(_ samples: [Float]) async throws
    /// Flushes what's left and ends the session.
    func stop() async
    /// Someone is dictating through this engine (on) or stopped (off). Only a shared engine cares: it lets this
    /// track feed first.
    func prioritize(_ on: Bool)
    /// Samples it must still be fed, after the `fed` fed since `start`, before its next step can produce words.
    /// The session holds audio until then, so a model that works in 160 ms steps isn't woken for every 10 ms
    /// of it. 0: any sample might (the default).
    func samplesUntilStep(fed: Int) -> Int
}

extension LiveEngine {
    public func prioritize(_ on: Bool) {}
    public func samplesUntilStep(fed: Int) -> Int { 0 }
}

/// Where a model that takes `first` samples before its first step, then `step` more for each one after, can next
/// run: how many samples past `fed` that is.
public func samplesUntilStep(fed: Int, first: Int, step: Int) -> Int {
    guard step > 0 else { return 0 }
    if fed < first { return first - fed }
    return step - (fed - first) % step
}

/// 16 kHz mono float audio, the format every engine and the mic share.
public enum PCM {
    public static let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
