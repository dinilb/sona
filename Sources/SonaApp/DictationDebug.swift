import Foundation
import LiveCore
import NotesKit
import SonaEngine

extension Dictation {
    /// Seconds of quiet put before the saved audio, so a test run (`LIVE_FILE`, `LIVE_DICTATE`) has started listening
    /// before the press comes round.
    static let replayLead = 2.0

    /// Where "Save Last Dictation for Debugging" puts its files.
    static var debugFolder: URL { Paths.support.appendingPathComponent("Debug", isDirectory: true) }

    /// "Delete the last N minutes": the debugging saves written from `cut` on (their audio and text) go too. Returns
    /// how many files were deleted.
    static func forgetDebugFiles(from cut: Date) -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: debugFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var deleted = 0
        for url in files where url.lastPathComponent.hasPrefix("dictation-") {
            guard let written = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                written >= cut
            else { continue }
            if (try? fm.removeItem(at: url)) != nil { deleted += 1 }
        }
        return deleted
    }

    /// "Save Last Dictation for Debugging": the last dictation's audio (a 16 kHz WAV, from 1.5 s before the press to
    /// 0.5 s after the release) and what happened to it (a JSON: the live words, the clip's text, what was pasted,
    /// timings, and the `LIVE_DICTATE` line that replays it) in `Debug/` in the support folder. Only on that click;
    /// nothing is kept on disk otherwise. Returns the JSON's URL.
    func saveLastForDebugging() throws -> URL {
        guard let last else { throw CocoaError(.fileNoSuchFile) }
        let folder = Self.debugFolder
        Paths.ensure(folder)
        let name = "dictation-" + NoteWriter.timeString(Date(), "yyyy-MM-dd-HHmmss")
        let wav = folder.appendingPathComponent(name + ".wav"), json = folder.appendingPathComponent(name + ".json")
        let file = try WavFile(creating: wav)
        try file.append([Float](repeating: 0, count: Int(Self.replayLead * AudioClock.sampleRate)) + last.audio)
        try file.finish()
        let press = Self.replayLead + last.audioPress, release = Self.replayLead + last.audioRelease
        let fields: [String: Any] = [
            "pasted": last.text, "outcome": last.outcome, "live": last.live, "clip": last.clip ?? NSNull(),
            "heldSeconds": last.released - last.pressed, "micWasOnAtPress": last.micWasOn,
            "readySecondsAfterRelease": last.done - last.released,
            "liveSecondsAfterRelease": last.liveDone.map { $0 - last.released } ?? NSNull(),
            "clipSecondsAfterRelease": last.clipDone.map { $0 - last.released } ?? NSNull(),
            "replay": String(format: "LIVE_FILE=%@ LIVE_DICTATE=%.3f-%.3f", wav.lastPathComponent, press, release),
        ]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: json)
        for url in [wav, json] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        Log.note("saved the last dictation for debugging (\(name))")
        return json
    }
}
