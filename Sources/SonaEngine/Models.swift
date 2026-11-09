import CoreML
import FluidAudio
import Foundation
import NotesKit

/// The three models, downloaded once into `Paths.models` from Hugging Face (FluidInference's CoreML
/// conversions), then loaded from disk with no network. A marker file per model set records that the
/// download finished and loaded cleanly, so later launches never even look at the network.
public enum Models {
    /// Rough download sizes, shown before downloading.
    public static func downloadMB(model: String) -> Int { model == "v3" ? 500 : 465 }

    public static func version(_ model: String) -> AsrModelVersion { model == "v3" ? .v3 : .v2 }

    public static func displayName(_ model: String) -> String {
        model == "v3" ? "Parakeet TDT 0.6B v3 (25 languages)" : "Parakeet TDT 0.6B v2 (English)"
    }

    static func asrDirectory(_ model: String) -> URL {
        Paths.models.appendingPathComponent(model == "v3" ? "parakeet-tdt-0.6b-v3" : "parakeet-tdt-0.6b-v2", isDirectory: true)
    }

    static func marker(_ model: String) -> URL { Paths.models.appendingPathComponent(".ready-\(model)") }

    public static func isReady(model: String) -> Bool {
        let fm = FileManager.default
        let others = [
            "speaker-diarization/Segmentation.mlmodelc", "speaker-diarization/FBank.mlmodelc",
            "speaker-diarization/Embedding.mlmodelc", "speaker-diarization/PldaRho.mlmodelc",
            "speaker-diarization/plda-parameters.json", "silero-vad",
        ]
        return fm.fileExists(atPath: marker(model).path)
            && AsrModels.modelsExist(at: asrDirectory(model), version: version(model))
            && others.allSatisfy { fm.fileExists(atPath: Paths.models.appendingPathComponent($0).path) }
    }

    /// FluidAudio re-downloads a model whose files or revision look off, or after a failed load. Outside
    /// `prepare`, that's never allowed: a broken model is an error the user sees, not a silent download.
    public static func goOffline() { ModelHub.offlineMode = true }

    /// Lets FluidAudio download until it's turned off again: only around the live set's first load (Parakeet
    /// Unified, Nemotron 3, Silero), which the app first tries from disk alone.
    public static func allowDownloads(_ on: Bool) { ModelHub.offlineMode = !on }

    /// The Neural Engine, never the GPU: FluidAudio's diarizer defaults to `.all`.
    static var computeConfig: MLModelConfiguration {
        MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuAndNeuralEngine)
    }

    /// The CPU alone: for an iPhone app in the background, where iOS 27 refuses the Neural Engine to apps without the
    /// Background Inference entitlement (and the GPU to every iPhone app).
    static var cpuConfig: MLModelConfiguration {
        MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuOnly)
    }

    /// The three models' size on disk once downloaded (v2 measured 7 Nov 2026: 487,263,709 bytes), for the bar.
    static func expectedBytes(model: String) -> Int64 {
        model == "v3" ? Int64(downloadMB(model: "v3")) * 1_048_576 + 22_850_000 : 487_263_709
    }

    /// Bytes under `folder`, half-downloaded files (`.partial`) included.
    static func bytesOnDisk(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// The bar while downloading: the share of the models' bytes on disk, up to `downloadShare` (the rest is the
    /// Neural Engine prep). From bytes, not FluidAudio's own fractions: those give the 445 MB encoder file half the
    /// bar at most and stopped moving while it resumed (the bar sat at 46% for two minutes on 7 Nov 2026), and the
    /// bytes already there after the app was closed count from the start.
    static func downloadFraction(bytes: Int64, expected: Int64) -> Double {
        guard expected > 0 else { return 0 }
        return downloadShare * min(1, Double(max(0, bytes)) / Double(expected))
    }

    static let downloadShare = 0.9

    /// The bar for what's on disk now (`downloadFraction` of `Paths.models`), for the app to start a download from.
    /// It can be lower than before: FluidAudio deletes a model whose load failed. Blocking (walks the folder).
    public static func downloadFractionOnDisk(model: String) -> Double {
        downloadFraction(bytes: bytesOnDisk(Paths.models), expected: expectedBytes(model: model))
    }

    /// Downloads (if needed) and test-loads everything for `model`. `progress` gets 0...1 and a phrase.
    public static func prepare(model: String, progress report: @escaping @Sendable (Double, String) -> Void) async throws {
        Paths.ensure(Paths.models)
        // The one place the network is allowed, and only while this runs.
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        // FluidAudio reports some phases twice; never let the bar go backwards.
        let highest = Highest()
        let phrase = Phrase("Downloading the speech model...")
        let progress: @Sendable (Double, String) -> Void = { fraction, text in
            phrase.set(text)
            report(highest.raise(fraction), text)
        }
        // FluidAudio's own fractions only for the prep (compiling); while it downloads, the bytes on disk lead.
        @Sendable func reported(_ p: DownloadProgress, _ what: String) {
            if case .compiling = p.phase {
                // The bar holds where the bytes are; the phrase says what's happening. Jumping it to the prep's share
                // here held it at 90% for all of the speaker model's download after.
                progress(0, "Preparing \(what) for the Neural Engine...")
            } else {
                progress(0, "Downloading \(what)...")
            }
        }

        let expected = expectedBytes(model: model)
        progress(downloadFraction(bytes: bytesOnDisk(Paths.models), expected: expected), "Downloading the speech model...")
        // Twice a second, how much is on disk now.
        let watcher = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let text = phrase.get()
                guard !text.hasPrefix("Preparing") else { continue }
                report(highest.raise(downloadFraction(bytes: bytesOnDisk(Paths.models), expected: expected)), text)
            }
        }
        defer { watcher.cancel() }

        // A cancel (the iPhone app leaving the screen) stops before each step: FluidAudio itself only notices one in
        // its downloads, so once the files are on disk its loads (the Neural Engine prep) would all run regardless.
        try Task.checkCancellation()
        _ = try await AsrModels.download(
            to: asrDirectory(model), version: version(model),
            progressHandler: { p in reported(p, "the speech model") })

        try Task.checkCancellation()
        progress(0, "Downloading the speaker model...")
        _ = try await OfflineDiarizerModels.load(
            from: Paths.models, configuration: computeConfig,
            progressHandler: { p in reported(p, "the speaker model") })

        try Task.checkCancellation()
        progress(0, "Downloading the voice detector...")
        _ = try await VadManager(
            config: VadConfig(defaultThreshold: 0.6), modelDirectory: Paths.support,
            progressHandler: { p in reported(p, "the voice detector") })

        try Data(NoteWriter.iso(Date()).utf8).write(to: marker(model))
        progress(1, "Ready")
    }

    /// Silero from disk (offline unless a download is running: see `goOffline`, called at launch). On the CPU, like
    /// the live gate's: it's tiny, and its calls ran there anyway.
    public static func loadVAD(threshold: Float) async throws -> VadManager {
        try await VadManager(config: VadConfig(defaultThreshold: threshold, computeUnits: .cpuOnly), modelDirectory: Paths.support)
    }

    /// Silero is on disk (the live voice gate and the always-on listener share it).
    public static var vadOnDisk: Bool {
        FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent("silero-vad").path)
    }
}

/// The phrase the bar shows now, shared between FluidAudio's callbacks and the bytes watcher.
final class Phrase: @unchecked Sendable {
    private var text: String
    private let lock = NSLock()

    init(_ text: String) { self.text = text }

    func set(_ new: String) {
        lock.lock()
        defer { lock.unlock() }
        text = new
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

final class Highest: @unchecked Sendable {
    private var value = 0.0
    private let lock = NSLock()

    func raise(_ x: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        value = max(value, min(1, x))
        return value
    }
}
