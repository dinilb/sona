import AVFoundation
import CoreML
import FluidAudio
import Foundation
import NotesKit

private func describe(_ p: DownloadProgress) -> String {
    switch p.phase {
    case .compiling: return "Preparing the model for the Neural Engine..."
    default: return "Downloading the model..."
    }
}

/// Parakeet Unified 0.6B with a [70, 2, 2] window: 160 ms chunks plus 160 ms look-ahead. Greedy RNN-T, so a
/// token is final the moment it's emitted: nothing on screen ever gets rewritten.
// @unchecked: one LiveSession drives it in order (prepare, start, feed..., stop), never two calls at once.
public final class UnifiedEngine: LiveEngine, @unchecked Sendable {
    public let name = "Parakeet Unified 0.6B (320 ms)"
    public let modelDelay = "160-320 ms"
    /// A 160 ms chunk plus 160 ms of right context.
    public let lookaheadSeconds = 0.32
    private let manager: StreamingUnifiedAsrManager
    private let secondsPerFrame = 0.08
    /// FluidAudio's windower: the first step once a chunk and its right context are in, then one per chunk.
    private let firstStep: Int
    private let step: Int
    private var loaded = false
    private var onUpdate: (@Sendable (LiveUpdate) -> Void)?

    /// `LIVE_UNIFIED=fp16-gpu|fp16-ane|int8-ane` to compare encoder setups (default int8 on the Neural Engine).
    public init() {
        let setup = ProcessInfo.processInfo.environment["LIVE_UNIFIED"] ?? "int8-ane"
        let config = MLModelConfiguration()
        config.computeUnits = setup.hasSuffix("gpu") ? .cpuAndGPU : setup.hasSuffix("all") ? .all : .cpuAndNeuralEngine
        let unified = StreamingModelVariant.parakeetUnified320ms.unifiedConfig!
        firstStep = unified.chunkSamples + unified.rightSamples
        step = unified.chunkSamples
        manager = StreamingUnifiedAsrManager(
            configuration: config, config: unified, encoderPrecision: setup.hasPrefix("fp16") ? .fp16 : .int8)
    }

    public func samplesUntilStep(fed: Int) -> Int { LiveCore.samplesUntilStep(fed: fed, first: firstStep, step: step) }

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard !loaded else { return }
        Paths.ensure(Paths.models)
        progress(0, "Loading the model...")
        try await manager.loadModels(to: Paths.models, configuration: nil, progressHandler: { progress($0.fractionCompleted, describe($0)) })
        loaded = true
    }

    public func start(onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws {
        try await manager.reset()
        self.onUpdate = onUpdate
    }

    public func feed(_ samples: [Float]) async throws {
        try await manager.appendAudio(PCM.buffer(samples))
        try await manager.processBufferedAudio()
        let tokens = await manager.consumeTokenTimings()
        guard !tokens.isEmpty else { return }
        // The emission frame's end: the audio the model had heard when it produced the token.
        let ends = tokens.map { $0.startTime + secondsPerFrame }
        onUpdate?(LiveUpdate(
            appendFinal: tokens.map(\.token).joined(), heard: ends, locked: ends,
            tokens: tokens.map { LiveToken(text: $0.token, start: $0.startTime) }))
    }

    public func stop() async {
        _ = try? await manager.finish()
        let tokens = await manager.consumeTokenTimings()
        if !tokens.isEmpty {
            onUpdate?(LiveUpdate(
                appendFinal: tokens.map(\.token).joined(), tokens: tokens.map { LiveToken(text: $0.token, start: $0.startTime) }))
        }
        onUpdate = nil
    }
}
