import Foundation
import NotesKit
import SonaEngine

/// One iPhone recording in the spool: `<id>.wav` appended to as frames come, and `<id>.json` (its `SpoolEntry`).
/// Writes run on its own queue, never the audio thread. What's written survives the app crashing or being killed;
/// every 10 s the entry and the audio are also flushed to the disk itself, so even a power cut loses at most the last
/// 10 s. `Processor.recover` finishes such a recording on the next launch. (Every 2 s cost 1,800 full flushes an hour
/// of recording, the one steady storage wake-up while recording.)
nonisolated final class SpoolRecording: @unchecked Sendable {
    static let defaultCheckpointSeconds = 10.0
    let checkpointSeconds: Double
    /// Shorter than this isn't a recording (a double tap): it's deleted when it stops.
    static let minSeconds = 0.5

    let id: String
    let startedAt: Date
    private let spool: Spool
    private let onFailure: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "com.dinilb.sona.spool-recording")

    // Only touched on `queue`.
    private var wav: WavFile?
    private var entry: SpoolEntry
    private var checkpointAt = 0
    private var failed = false
    /// The first frame's time (`AudioFrame.time`, a monotonic clock): where sample 0 sits, so a pause can be measured.
    private var firstFrameTime: TimeInterval?

    /// A hole longer than this between frames (a call had the mic) is filled with silence, so the words after it keep
    /// their real time in the note. Shorter ones are the clocks' own wobble.
    static let gapSeconds = 2.0
    /// A pause longer than this gets this much silence and no more (an hour of zeros is plenty of "something happened").
    static let maxGapSeconds = 3600.0

    /// Opens it: the spool's `openID` first (so the processor never takes a recording still going), then the WAV,
    /// then the entry. `onFailure`: a write failed (a full disk); nothing more is written.
    init(
        spool: Spool, startedAt: Date, source: String, checkpointSeconds: Double = defaultCheckpointSeconds,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        id = Spool.newID(for: startedAt)
        self.checkpointSeconds = checkpointSeconds
        self.startedAt = startedAt
        self.spool = spool
        self.onFailure = onFailure
        entry = SpoolEntry(id: id, startedAt: startedAt, source: source)
        spool.openID = id
        do {
            wav = try WavFile(creating: spool.wav(id))
        } catch {
            spool.openID = nil
            throw error
        }
        spool.save(entry, durable: true)
    }

    func append(_ frame: AudioFrame) {
        queue.async { [self] in
            guard let wav, !failed else { return }
            do {
                try fillPause(before: frame, in: wav)
                try wav.append(frame.floats)
            } catch {
                failed = true
                onFailure(error)
                return
            }
            if Double(wav.samples - checkpointAt) >= checkpointSeconds * Double(AudioFrame.sampleRate) {
                checkpointAt = wav.samples
                entry.speechEnd = seconds(wav)
                entry.speechSeconds = entry.speechEnd
                // The entry first, then one full sync for both (see Spool.save).
                spool.save(entry, durable: true)
                try? wav.checkpoint()
            }
        }
    }

    /// Closes it: the WAV's header written, the entry saved as closed, then `openID` cleared so the processor may take
    /// it. Returns its length in seconds, or nil if it was too short and was deleted.
    func finish() async -> Double? {
        await withCheckedContinuation { done in
            queue.async { [self] in done.resume(returning: close()) }
        }
    }

    /// Deletes it (the audio never started).
    func discard() {
        queue.sync {
            try? wav?.finish()
            wav = nil
            spool.remove(id)
            if spool.openID == id { spool.openID = nil }
        }
    }

    private func close() -> Double? {
        guard let wav else { return nil }
        self.wav = nil
        let duration = seconds(wav)
        do {
            try wav.finish()
        } catch {
            // Still hand it over: the processor fixes the header from the file's length. Never strand a recording.
            Log.note("recording \(Log.ref(startedAt)): couldn't finish the WAV cleanly: \(Log.describe(error))")
        }
        defer { if spool.openID == id { spool.openID = nil } }
        guard duration >= Self.minSeconds else {
            spool.remove(id)
            return nil
        }
        entry.closed = true
        entry.speechEnd = duration
        entry.speechSeconds = duration
        spool.save(entry, durable: true)
        return duration
    }

    private func seconds(_ wav: WavFile) -> Double { Double(wav.samples) / Double(AudioFrame.sampleRate) }

    /// Silence for the time the mic was away (a call, Siri), measured by the frames' times, so a line said
    /// after a 10-minute call isn't stamped 10 minutes early and the note ends when the recording did.
    private func fillPause(before frame: AudioFrame, in wav: WavFile) throws {
        guard let first = firstFrameTime else {
            firstFrameTime = frame.time
            return
        }
        let rate = Double(AudioFrame.sampleRate)
        let gap = frame.time - (first + Double(wav.samples) / rate)
        guard gap > Self.gapSeconds else { return }
        var missing = Int(min(gap, Self.maxGapSeconds) * rate)
        Log.note("recording \(Log.ref(startedAt)): the mic was away \(String(format: "%.0f", gap)) s, kept as silence")
        let second = [Float](repeating: 0, count: AudioFrame.sampleRate)
        while missing > 0 {
            let n = min(missing, second.count)
            try wav.append(n == second.count ? second : Array(second.prefix(n)))
            missing -= n
        }
    }
}
