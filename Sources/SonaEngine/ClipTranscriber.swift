import FluidAudio
import Foundation
import NotesKit

/// Parakeet TDT on one short clip: a dictation's own audio, transcribed whole once the key is let go. It's the
/// notes model (more accurate than the live one, and it hears the whole sentence at once), but its own copy: a note
/// being transcribed can hold the notes engine for minutes.
public actor ClipTranscriber {
    private let asr: AsrManager
    private let decoderLayers: Int

    private init(asr: AsrManager, decoderLayers: Int) {
        self.asr = asr
        self.decoderLayers = decoderLayers
    }

    /// From `Paths.models`, never downloading. Throws if the model isn't there.
    public static func load(model: String) async throws -> ClipTranscriber {
        guard Models.isReady(model: model) else { throw EngineError.modelsMissing(model) }
        let version = Models.version(model)
        let models = try await AsrModels.load(from: Models.asrDirectory(model), version: version)
        let asr = AsrManager(
            config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
        try await asr.loadModels(models)
        return ClipTranscriber(asr: asr, decoderLayers: await asr.decoderLayerCount)
    }

    /// 16 kHz mono samples to text. Short clips are padded with quiet to the model's 1 s minimum. No gain is applied:
    /// the model normalises its own input, and speech 20 dB quieter scored the same (scripts/dictation-bench.sh quiet).
    public func transcribe(_ samples: [Float]) async throws -> String {
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        return try await asr.transcribe(audio, decoderState: &state).text
    }
}
