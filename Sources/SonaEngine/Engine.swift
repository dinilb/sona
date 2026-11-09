import CoreML
import FluidAudio
import Foundation
import NotesKit

/// Parakeet + the offline diarizer, loaded once, running the accurate batch pass over a whole conversation.
/// Started from an earlier prototype (parakeet-always-on-note, Engine.swift).
// @unchecked: every stored property is a `let`; AsrManager is an actor and the diarizer only writes its
// state in initialize() (during init here), read-only after that, as FluidAudio documents.
public final class Engine: @unchecked Sendable {
    public let model: String
    /// Loaded for the CPU alone (`load(model:cpuOnly:)`).
    public let cpuOnly: Bool
    let asr: AsrManager
    /// Diarizer with the base config, for conversations without a speaker hint.
    let diarizer: OfflineDiarizerManager
    /// Loaded once and shared by every diarizer this engine makes (a hint needs its own config).
    private let diarizerModels: OfflineDiarizerModels
    private let decoderLayers: Int

    private init(model: String, cpuOnly: Bool, asr: AsrManager, diarizerModels: OfflineDiarizerModels, decoderLayers: Int) {
        self.model = model
        self.cpuOnly = cpuOnly
        self.asr = asr
        self.diarizerModels = diarizerModels
        self.diarizer = OfflineDiarizerManager(config: Self.diarizerConfig)
        self.diarizer.initialize(models: diarizerModels)
        self.decoderLayers = decoderLayers
    }

    /// The offline diarizer's config: FluidAudio's pyannote community-1 defaults. Tuning on our test clips
    /// (29 Oct 2026): a lower clustering threshold changed nothing; a higher VBx Fa (0.15-0.2) split the
    /// three similar voices on the short clip but over-split the 6-minute one (4 speakers for 3), so the
    /// defaults stay and similar voices rely on a speaker-count hint instead.
    static let diarizerConfig = OfflineDiarizerConfig.default

    /// Loads from `Paths.models`. Throws if the models aren't downloaded: it never downloads by itself, so the
    /// always-on path can't make a network call. (The app and the CLI go offline at launch; this doesn't touch
    /// that switch, so it can't cut short a download running at the same time.)
    /// `cpuOnly`: every model on the CPU, never the Neural Engine (an iPhone app in the background on iOS 27; slower).
    public static func load(model: String, cpuOnly: Bool = false) async throws -> Engine {
        guard Models.isReady(model: model) else { throw EngineError.modelsMissing(model) }
        let version = Models.version(model)
        let t0 = Date()
        let models =
            cpuOnly
            ? try await AsrModels.load(
                from: Models.asrDirectory(model), configuration: Models.cpuConfig, version: version, encoderComputeUnits: .cpuOnly)
            : try await AsrModels.load(from: Models.asrDirectory(model), version: version)
        let asr = AsrManager(
            config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
        try await asr.loadModels(models)
        let decoderLayers = await asr.decoderLayerCount

        let diarizerModels = try await OfflineDiarizerModels.load(
            from: Paths.models, configuration: cpuOnly ? Models.cpuConfig : Models.computeConfig)
        Log.note("engine loaded (\(model)\(cpuOnly ? ", CPU only" : "")) in \(fmt(Date().timeIntervalSince(t0)))s")
        return Engine(model: model, cpuOnly: cpuOnly, asr: asr, diarizerModels: diarizerModels, decoderLayers: decoderLayers)
    }

    /// The accurate pass over a whole conversation WAV (16 kHz mono 16-bit). Both models read the file
    /// memory-mapped in chunks, so a 2-hour conversation runs in constant memory. Diarization sees the
    /// whole conversation at once, so speaker numbers stay consistent from start to end.
    /// `speakers`: an optional prior on the speaker count for this conversation (say from the live pass).
    public func process(wav: URL, startedAt: Date, speakers: SpeakerHint? = nil) async throws -> Transcript {
        let duration = WavFile.duration(of: wav)

        let t0 = Date()
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribeDiskBacked(wav, decoderState: &state)
        let asrSeconds = Date().timeIntervalSince(t0)

        let t1 = Date()
        let segments: [TimedSpeakerSegment]
        do {
            segments = try await diarizer(for: speakers).process(wav).segments
        } catch OfflineDiarizationError.noSpeechDetected {
            // Too little speech to tell voices apart (a word or two in minutes of room noise). Not a failure:
            // the words (if any) get one speaker, and no words at all means no note.
            segments = []
        }
        let diarizationSeconds = Date().timeIntervalSince(t1)

        let rawWords = buildWordTimings(from: result.tokenTimings ?? [])
        let (words, turns) =
            segments.isEmpty ? Merge.oneSpeaker(rawWords) : Merge.assignSpeakers(words: rawWords, segments: segments)

        return Transcript(
            startedAt: startedAt, duration: duration, text: result.text, words: words, turns: turns,
            asrSeconds: asrSeconds, diarizationSeconds: diarizationSeconds,
            model: "parakeet-tdt-0.6b-\(model)")
    }
}

extension Engine {
    /// A diarizer for this hint: exact when min == max, else a min/max range. Same loaded models, its own
    /// clustering config (cheap to make).
    func diarizer(for speakers: SpeakerHint?) -> OfflineDiarizerManager {
        guard let speakers, !speakers.isEmpty else { return diarizer }
        let config =
            speakers.exact.map { Self.diarizerConfig.withSpeakers(exactly: $0) }
            ?? Self.diarizerConfig.withSpeakers(min: speakers.min, max: speakers.max)
        let hinted = OfflineDiarizerManager(config: config)
        hinted.initialize(models: diarizerModels)
        return hinted
    }
}

public enum EngineError: Error, CustomStringConvertible, LogSafeError {
    case modelsMissing(String)

    public var description: String {
        switch self {
        case .modelsMissing(let model):
            return "The \(model) models aren't downloaded yet. Open Sona (or run `sona models`) once while online."
        }
    }
}

func fmt(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }
