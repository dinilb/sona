import AVFoundation
import CoreMedia
import Foundation
import LiveCore
import Speech

/// Apple's on-device SpeechAnalyzer (macOS 26+). Shows a tentative ("volatile") guess fast, then replaces it
/// with final text once it's sure. The model is managed by macOS, not downloaded by us.
@available(macOS 26, *)
// @unchecked: one LiveSession drives it in order (prepare, start, feed..., stop), never two calls at once.
final class AppleEngine: LiveEngine, @unchecked Sendable {
    let name = EngineKind.apple.title
    let modelDelay = "not published"
    /// Unknown (and it has no word timings for dictation anyway).
    let lookaheadSeconds = 0.0
    private var locale = Locale(identifier: "en-US")
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var fed: Int64 = 0
    private var heardThrough = 0.0
    private var onUpdate: (@Sendable (LiveUpdate) -> Void)?

    init() {}

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange])
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber()]) {
            progress(0, "Downloading Apple's speech model...")
            let watch = request.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted, "Downloading Apple's speech model...") }
            defer { watch.invalidate() }
            try await request.downloadAndInstall()
        }
    }

    func start(onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws {
        self.onUpdate = onUpdate
        fed = 0
        heardThrough = 0
        let transcriber = makeTranscriber()
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? PCM.format16k
        self.format = format
        converter = format == PCM.format16k ? nil : AVAudioConverter(from: PCM.format16k, to: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format, withProgressReadyHandler: nil)
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results { self?.handle(result) }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        var ends: [Double] = []
        for run in result.text.runs {
            if let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] { ends.append(range.end.seconds) }
        }
        let fresh = ends.filter { $0 > heardThrough + 0.001 }
        heardThrough = max(heardThrough, ends.max() ?? 0)
        let text = String(result.text.characters)
        if result.isFinal {
            onUpdate?(LiveUpdate(appendFinal: text, volatile: "", heard: fresh, locked: ends))
        } else {
            onUpdate?(LiveUpdate(volatile: text, heard: fresh))
        }
    }

    func feed(_ samples: [Float]) async throws {
        var buffer = PCM.buffer(samples)
        if let converter, let format {
            let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16_000) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            buffer = out
        }
        input?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: fed, timescale: 16_000)))
        fed += Int64(samples.count)
    }

    func stop() async {
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        analyzer = nil
        onUpdate = nil
    }
}
