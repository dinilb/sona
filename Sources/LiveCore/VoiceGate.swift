import CoreML
import FluidAudio
import Foundation
import NotesKit

/// Lets audio through to the transcriber and diarizer only while someone is talking, so silence costs
/// almost nothing. Silero VAD decides every `hop` samples (128 ms by default).
///
/// FluidAudio's Silero model only takes 256 ms chunks (4096 samples), which would make a decision every
/// 256 ms. Instead the gate runs `4096 / hop` interleaved Silero streams (2 by default), each on its own
/// back-to-back 256 ms chunks with its own LSTM state, offset by one hop: a stateful decision every 128 ms
/// for 2 small model calls per 256 ms. Finer timing buys little: it only moves the first word of each
/// stretch of speech, and the pre-roll means nothing is clipped either way.
///
/// While open, audio passes straight through (no added delay); the VAD only decides when to close.
/// While closed, audio waits in a short history; once speech is detected, the pre-roll before the detecting
/// window and everything since go out in one piece, so the first word isn't clipped.
/// Not thread-safe: one owner (the session's pump) calls `accept` and `decide` in order.
public final class VoiceGate: @unchecked Sendable {
    public struct Config: Sendable {
        /// Samples between decisions. Must divide 4096.
        public var hop = 2_048
        /// Audio fed from before the window that first heard speech.
        public var preRollSeconds = 0.5
        /// Silence (below `exit`) that closes the gate. Long enough for the diarizer (~1.04 s) and the
        /// transcriber's look-ahead to finish the last words from real audio, so no flush is needed.
        public var hangoverSeconds = 1.2
        /// Silero probability that opens the gate.
        public var enter: Float = 0.5
        /// Below this counts as silence for the hangover (Silero's usual hysteresis).
        public var exit: Float = 0.35
        /// A window quieter than this (RMS, about -50 dBFS) counts as silence without running Silero, so a
        /// quiet room costs next to nothing. Speech, even across a room, is louder.
        public var floor: Float = 0.003
        public init() {}
    }

    /// Session-indexed audio to feed.
    public struct Piece: Sendable, Equatable {
        public let start: Int
        public let samples: [Float]
    }

    public static let window = VadManager.chunkSize
    public let config: Config
    private let vad: VadManager?
    private let hop: Int
    private let preRoll: Int
    private let hangover: Int

    /// Recent session audio; `history[0]` is session sample `historyStart`.
    private var history: [Float] = []
    private var historyStart = 0
    /// Session samples received.
    public private(set) var received = 0
    /// Every hop ending at or before this has a decision.
    public private(set) var decided = 0
    /// Session index just after the last sample let through.
    private var fedUntil = 0
    private var lastSpeech = 0
    public private(set) var isOpen = false
    /// LSTM state of each interleaved Silero stream.
    private var phases: [(hidden: [Float], cell: [Float])]
    /// Seconds spent in the VAD model.
    public private(set) var vadSeconds = 0.0
    /// Open for good because the VAD failed: nothing decides any more, so history is kept only to `fedUntil`.
    private var forced = false

    /// `vad` nil is for tests that drive `step` with their own probabilities.
    public init(vad: VadManager?, config: Config = Config()) {
        precondition(Self.window % config.hop == 0, "hop must divide 4096")
        self.vad = vad
        self.config = config
        hop = config.hop
        preRoll = Int(config.preRollSeconds * AudioClock.sampleRate)
        hangover = Int(config.hangoverSeconds * AudioClock.sampleRate)
        let initial = VadState.initial()
        phases = Array(repeating: (initial.hiddenState, initial.cellState), count: Self.window / config.hop)
    }

    /// Loads Silero once per process (it's small: the first load compiles it, later ones are instant).
    public static func loadModel() async throws -> VadManager {
        try await shared.get()
    }

    private static let shared = SharedVad()
    private actor SharedVad {
        var task: Task<VadManager, Error>?
        func get() async throws -> VadManager {
            if let task, let vad = try? await task.value { return vad }
            // `LIVE_VAD=ane|cpu` to compare where Silero runs.
            let units: MLComputeUnits = ProcessInfo.processInfo.environment["LIVE_VAD"] == "ane" ? .cpuAndNeuralEngine : .cpuOnly
            let t = Task {
                try await VadManager(
                    config: VadConfig(defaultThreshold: 0.5, computeUnits: units), modelDirectory: Paths.support)
            }
            task = t
            return try await t.value
        }
    }

    /// Takes new audio. While open it comes straight back out to feed.
    public func accept(_ samples: [Float]) -> Piece? {
        guard !samples.isEmpty else { return nil }
        history.append(contentsOf: samples)
        received += samples.count
        trim()
        guard isOpen else { return nil }
        return release()
    }

    /// Runs the VAD on every whole hop received so far. Returns what to feed if the gate just opened.
    public func decide() async throws -> Piece? {
        var out: Piece?
        while received - decided >= hop {
            let end = decided + hop
            let p = try await probability(windowEndingAt: end)
            decided = end
            if let piece = step(probability: p, hopEnd: end) { out = piece }
        }
        return out
    }

    /// The gate's state machine for one decision on the window ending at session sample `hopEnd`.
    /// Returns the backlog to feed when it opens.
    @discardableResult
    public func step(probability p: Float, hopEnd: Int) -> Piece? {
        if isOpen {
            if p >= config.exit || held {
                lastSpeech = hopEnd
            } else if hopEnd - lastSpeech >= hangover {
                isOpen = false
            }
            return nil
        }
        guard p >= config.enter else { return nil }
        isOpen = true
        lastSpeech = hopEnd
        fedUntil = max(fedUntil, hopEnd - Self.window - preRoll, historyStart, 0)
        return release()
    }

    /// Someone is holding the dictation key: they're about to talk, so don't wait for the VAD to hear them.
    /// Stays open while held (then the usual hangover applies).
    public var held = false

    /// Opens right now (for `held`), releasing the pre-roll and anything waiting. Nil if already open.
    public func openNow() -> Piece? {
        guard !isOpen else { return nil }
        isOpen = true
        lastSpeech = received
        fedUntil = max(fedUntil, received - preRoll, historyStart, 0)
        return release()
    }

    /// Opens for good (the VAD failed), releasing the pre-roll and anything waiting.
    public func forceOpen() -> Piece? {
        guard !isOpen else { return nil }
        isOpen = true
        forced = true
        lastSpeech = .max / 2
        fedUntil = max(fedUntil, received - preRoll, historyStart)
        return release()
    }

    /// Everything from `fedUntil` to what's been received.
    private func release() -> Piece? {
        let from = max(fedUntil, historyStart)
        guard received > from else { return nil }
        let piece = Piece(start: from, samples: Array(history[(from - historyStart)...]))
        fedUntil = received
        return piece
    }

    private func trim() {
        // Keep the window, its 64-sample context and the pre-roll behind the next undecided hop.
        let keepFrom = forced ? fedUntil : min(decided - Self.window - VadState.contextLength - preRoll, isOpen ? fedUntil : .max)
        let n = keepFrom - historyStart
        guard n > 32_000 else { return }
        history.removeFirst(n)
        historyStart += n
    }

    private func samples(_ from: Int, _ to: Int) -> [Float] {
        var out = [Float](repeating: 0, count: to - from)
        let a = max(from, historyStart), b = min(to, received)
        if a < b {
            for i in a..<b { out[i - from] = history[i - historyStart] }
        }
        return out
    }

    private func rms(_ x: [Float]) -> Float {
        var sum: Float = 0
        for v in x { sum += v * v }
        return (sum / Float(max(x.count, 1))).squareRoot()
    }

    private func probability(windowEndingAt end: Int) async throws -> Float {
        guard let vad else { return 0 }
        let window = samples(end - Self.window, end)
        let phase = (end / hop) % phases.count
        guard rms(window) >= config.floor else {
            // Quiet: this stream's memory would be stale by the next sound, so start it fresh.
            let initial = VadState.initial()
            phases[phase] = (initial.hiddenState, initial.cellState)
            return 0
        }
        let state = VadState(
            hiddenState: phases[phase].hidden, cellState: phases[phase].cell,
            context: samples(end - Self.window - VadState.contextLength, end - Self.window))
        let t = hostNow()
        let result = try await vad.processStreamingChunk(window, state: VadStreamState(modelState: state))
        vadSeconds += hostNow() - t
        phases[phase] = (result.state.modelState.hiddenState, result.state.modelState.cellState)
        return result.probability
    }
}
