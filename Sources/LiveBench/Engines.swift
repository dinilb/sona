import AVFoundation
import FluidAudio
import Foundation
import LiveCore
import NotesKit

// The bench's engine choices. The app ships only Parakeet Unified (in LiveCore); the EOU and Apple engines
// live here so they can still be compared.

enum EngineKind: String, CaseIterable, Identifiable, Sendable {
    case unified320 = "unified320"
    case eou160 = "eou160"
    case apple = "apple"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unified320: return "Parakeet Unified 0.6B (320 ms)"
        case .eou160: return "Parakeet EOU 120M (160 ms)"
        case .apple: return "Apple on-device"
        }
    }

    /// Has per-token timings, so words can get speakers and lines.
    var hasTimings: Bool { self != .apple }

    var isAvailable: Bool {
        if self == .apple, #unavailable(macOS 26) { return false }
        return true
    }

    func make() -> LiveEngine {
        switch self {
        case .unified320: return UnifiedEngine()
        case .eou160: return EouEngine()
        case .apple:
            if #available(macOS 26, *) { return AppleEngine() }
            fatalError("Apple's SpeechAnalyzer needs macOS 26")
        }
    }
}

private func describe(_ p: DownloadProgress) -> String {
    switch p.phase {
    case .compiling: return "Preparing the model for the Neural Engine..."
    default: return "Downloading the model..."
    }
}

/// Parakeet EOU 120M, cache-aware streaming with 160 ms chunks. Smallest and fastest; less accurate.
// @unchecked: one LiveSession drives it in order (prepare, start, feed..., stop), never two calls at once.
final class EouEngine: LiveEngine, @unchecked Sendable {
    let name = EngineKind.eou160.title
    let modelDelay = "160 ms"
    /// 160 ms chunks that overlap by half; 0.32 s is a safe bound.
    let lookaheadSeconds = 0.32
    private let manager = StreamingEouAsrManager(chunkSize: .ms160)
    private var loaded = false
    private var onUpdate: (@Sendable (LiveUpdate) -> Void)?
    /// Tokens already shown since the last reset, and where that reset sits in the session.
    private var seen = 0
    private var fedSamples = 0
    private var resetAtSeconds = 0.0

    init() {}

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard !loaded else { return }
        Paths.ensure(Paths.models)
        progress(0, "Loading the model...")
        try await manager.loadModels(to: Paths.models, configuration: nil, progressHandler: { progress($0.fractionCompleted, describe($0)) })
        loaded = true
    }

    func start(onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws {
        await manager.reset()
        seen = 0
        fedSamples = 0
        resetAtSeconds = 0
        self.onUpdate = onUpdate
    }

    func feed(_ samples: [Float]) async throws {
        try await manager.appendAudio(PCM.buffer(samples))
        fedSamples += samples.count
        try await manager.processBufferedAudio()
        let pieces = await manager.getRawTokenStrings()
        let times = await manager.getTokenTimestampsMs()
        if pieces.count > seen {
            var text = ""
            var ends: [Double] = []
            var timed: [LiveToken] = []
            for i in seen..<pieces.count {
                let piece = pieces[i]
                if piece.hasPrefix("<") && piece.hasSuffix(">") { continue }
                let clean = piece.replacingOccurrences(of: "\u{2581}", with: " ")
                text += clean
                let ms = i < times.count ? Double(times[i]) : 0
                ends.append(resetAtSeconds + ms / 1000 + 0.04)
                timed.append(LiveToken(text: clean, start: resetAtSeconds + ms / 1000))
            }
            seen = pieces.count
            if !text.isEmpty { onUpdate?(LiveUpdate(appendFinal: text, heard: ends, locked: ends, tokens: timed)) }
        }
        // After a confirmed end of utterance (silence), start fresh so the token history stays small.
        if await manager.eouDetected {
            await manager.reset()
            seen = 0
            resetAtSeconds = Double(fedSamples) / AudioClock.sampleRate
        }
    }

    func stop() async {
        // A chunk of silence pushes the last buffered audio through, so the final words still show.
        try? await feed([Float](repeating: 0, count: 8_000))
        onUpdate = nil
        await manager.reset()
    }
}
