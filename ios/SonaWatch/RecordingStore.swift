import AVFoundation
import Foundation

/// The watch's recordings: each a `<id>.aac` (ADTS, AAC 16 kHz mono, about 14 MB an hour) with a `<id>.json` (a
/// `WatchRecording`) beside it. Older builds, and the fallback when the AAC encoder won't start, leave a `<id>.wav`
/// (16 kHz mono 16-bit PCM, 115 MB an hour) instead; both are sent the same way, and the iPhone tells them apart by
/// their first bytes. The JSON is written when recording starts (duration 0) and again when it stops, so a duration
/// of 0 means it never stopped. A recording stays here until the iPhone has it.
struct RecordingStore {
    let dir: URL
    /// Writes a recording's JSON to its file. Tests swap it for one that fails.
    var write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }

    static let standard = RecordingStore(
        dir: URL.applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory))

    /// Where a new recording's AAC goes.
    func aacURL(_ id: String) -> URL { dir.appending(path: "\(id).aac") }
    /// Where a WAV recording is (an older build's, or the fallback).
    func wavURL(_ id: String) -> URL { dir.appending(path: "\(id).wav") }
    /// The recording's audio: its WAV if it has one, otherwise its AAC (which may not exist yet).
    func audioURL(_ id: String) -> URL {
        let wav = wavURL(id)
        return FileManager.default.fileExists(atPath: wav.path) ? wav : aacURL(id)
    }
    func infoURL(_ id: String) -> URL { dir.appending(path: "\(id).json") }

    static let audioExtensions: Set<String> = ["aac", "wav"]

    /// The recording an audio file belongs to: its name. Callable from any thread, for the recorder's callbacks.
    nonisolated static func id(ofAudio url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// Every recording here, newest first.
    func all() -> [WatchRecording] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(WatchRecording.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func load(_ id: String) -> WatchRecording? {
        guard let data = try? Data(contentsOf: infoURL(id)) else { return nil }
        return try? JSONDecoder().decode(WatchRecording.self, from: data)
    }

    func save(_ recording: WatchRecording) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(JSONEncoder().encode(recording), infoURL(recording.id))
    }

    func delete(_ id: String) {
        // Only ever our own UUID-named files, whatever an acknowledgement says.
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: aacURL(id))
        try? FileManager.default.removeItem(at: wavURL(id))
        try? FileManager.default.removeItem(at: infoURL(id))
    }

    /// The length of a recording's audio in seconds; nil if it can't be read as audio. `force` rebuilds what a
    /// recorder that never stopped left behind: a WAV's sizes from the file's length, an AAC's torn last frame cut
    /// off. Otherwise a WAV's sizes are only rewritten when they can't be right, and an AAC is only read. Throws when
    /// the file couldn't be opened or written, which says nothing about what it holds.
    func audioSeconds(_ id: String, force: Bool) throws -> Double? {
        let url = audioURL(id)
        guard url.pathExtension == "aac" else { return try WAVFile.repair(url, force: force) }
        if let seconds = try ADTSFile.scan(url, repair: force) { return seconds }
        // Not the ADTS this reader knows: ask AVFoundation, which the iPhone decodes it with.
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Puts right what a crash or a flat battery left behind; call it before anything records. A recording that
    /// never stopped gets its audio repaired (a WAV's header from the file's length, an AAC's torn last frame cut
    /// off) and its duration set, so it's sent like any other. Audio whose JSON is missing gets one (same id, so the
    /// iPhone keeps one copy however often it's sent). One with no audio at all is removed. Returns the ids it
    /// recovered.
    @discardableResult
    func recover() -> [String] {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for audio in files where Self.audioExtensions.contains(audio.pathExtension) {
            let id = audio.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil, !fileManager.fileExists(atPath: infoURL(id).path) else { continue }
            let created = (try? audio.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            try? save(WatchRecording(id: id, startedAt: created, duration: 0))
        }

        var recovered: [String] = []
        for recording in all() {
            guard fileManager.fileExists(atPath: audioURL(recording.id).path) else {
                delete(recording.id)
                continue
            }
            if recording.duration > 0 {
                _ = try? audioSeconds(recording.id, force: false)
            } else if finishUnstopped(recording) {
                recovered.append(recording.id)
            }
        }
        return recovered
    }

    /// Gives a recording that never got its length (duration 0) one: its audio is repaired (the recorder never
    /// finished it, or its last save failed) and the duration saved. A recording with no audio is removed. One whose
    /// audio couldn't be read or written this time (an I/O error) is kept as it is and tried again next run: it may
    /// be the only copy of hours of audio. True if it now has a duration saved. The one being made right now must not
    /// come here: its file is still growing.
    @discardableResult
    func finishUnstopped(_ recording: WatchRecording) -> Bool {
        guard FileManager.default.fileExists(atPath: audioURL(recording.id).path) else {
            delete(recording.id)
            return false
        }
        let repaired: Double?
        do {
            repaired = try audioSeconds(recording.id, force: true)
        } catch {
            return false
        }
        // Not audio we can read, or none at all: nothing to keep.
        guard let seconds = repaired, seconds > 0 else {
            delete(recording.id)
            return false
        }
        var finished = recording
        finished.duration = seconds
        return (try? save(finished)) != nil
    }
}
