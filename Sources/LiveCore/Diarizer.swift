import CoreML
import FluidAudio
import Foundation
import NotesKit

/// NVIDIA Nemotron 3 streaming diarization (up to 8 speakers, arrival order). The published presets both
/// settle about 1.04 s after the audio: `fast` is ~3x cheaper per call, which leaves the Neural Engine to
/// the transcriber; `low` is a bit more accurate.
// @unchecked: prepare runs before a session; then only the session's diarizer task calls reset/feed/finish, under
// `shared` (a sibling uses the same loaded model and its buffers).
public final class LiveDiarizer: @unchecked Sendable {
    public let preset: String
    private let config: Nemotron3Config
    private var diarizer: Nemotron3Diarizer?
    private var models: Nemotron3Models?
    /// Held for every call into the model, by this diarizer and its siblings.
    private let shared: NSLock

    public init(preset: String = "fast") {
        self.preset = preset
        config = preset == "low" ? .low : .fast
        shared = NSLock()
    }

    private init(preset: String, models: Nemotron3Models, lock: NSLock) {
        self.preset = preset
        config = preset == "low" ? .low : .fast
        self.models = models
        shared = lock
        diarizer = Nemotron3Diarizer(config: config, models: models)
    }

    /// Another stream (the Mac's audio) on the same loaded model: no second copy. Its calls take turns with this
    /// one's. Nil before `prepare`.
    public func sibling() -> LiveDiarizer? {
        models.map { LiveDiarizer(preset: preset, models: $0, lock: shared) }
    }

    public var delay: String { String(format: "%.2f s", Double(config.chunkLen + config.chunkRightContext) * 0.08) }

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard diarizer == nil else { return }
        Paths.ensure(Paths.models)
        progress(0, "Loading the speaker model...")
        let models = try await Nemotron3Models.loadFromHuggingFace(
            config: config, cacheDirectory: Paths.models, computeUnits: .cpuAndNeuralEngine,
            progressHandler: { p in
                if case .compiling = p.phase {
                    progress(p.fractionCompleted, "Preparing the speaker model...")
                } else {
                    progress(p.fractionCompleted, "Downloading the speaker model...")
                }
            })
        self.models = models
        diarizer = Nemotron3Diarizer(config: config, models: models)
    }

    public func reset() {
        shared.withLock {
            diarizer?.reset()
            fed = 0
        }
    }

    /// Samples fed since `reset` (under `shared`).
    private var fed = 0

    /// 16 kHz mono in order. Returns the dominant speaker for each new 10 ms frame (-1 for nobody).
    public func feed(_ samples: [Float]) throws -> [Int8] {
        guard let diarizer else { return [] }
        return try shared.withLock {
            fed += samples.count
            diarizer.appendAudio(samples)
            return try dominant(diarizer.processBufferedAudio())
        }
    }

    /// Samples still to feed before its next chunk can run, so the session only wakes it then (every 0.72 s with
    /// `fast`, not every 10 ms).
    public var samplesUntilStep: Int {
        let sub = config.subsamplingFactor
        return shared.withLock {
            Self.samplesUntilStep(fed: fed, core: config.chunkLen * sub, right: config.chunkRightContext * sub)
        }
    }

    /// FluidAudio's streaming front end runs a chunk once the mel frames for it and its right context are in; a
    /// frame needs its 10 ms hop plus half its 512-sample window. If that ever changes, a wrong guess only wakes
    /// the diarizer a feed early (it does nothing and is asked again) or late.
    static func samplesUntilStep(fed: Int, core: Int, right: Int, hop: Int = 160, half: Int = 256) -> Int {
        let frames = fed >= half ? (fed - half) / hop + 1 : 0
        let done = frames >= core + right ? (frames - right) / core : 0
        let next = ((done + 1) * core + right - 1) * hop + half
        return max(next - fed, 1)
    }

    public func finish() throws -> [Int8] {
        guard let diarizer else { return [] }
        return try shared.withLock { try dominant(diarizer.finishStream()) }
    }

    private func dominant(_ chunks: [Nemotron3ChunkResult]) -> [Int8] {
        var out: [Int8] = []
        for chunk in chunks {
            let n = chunk.numSpeakers
            for f in 0..<chunk.frameCount {
                var best = -1
                var bestP: Float = 0.5
                for s in 0..<n where chunk.probabilities[f * n + s] > bestP {
                    best = s
                    bestP = chunk.probabilities[f * n + s]
                }
                out.append(Int8(best))
            }
        }
        return out
    }
}
