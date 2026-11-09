import Foundation
import NotesKit
import os

/// Conversations not yet turned into notes, kept on disk so a crash, quit or power cut never loses one.
///
/// Each conversation is `<id>.wav` (16 kHz mono 16-bit, appended as it's heard) plus `<id>.json` (when it
/// started, where the speech ends, whether it's closed). The WAV header's sizes are only right once it's
/// closed; `repair` fixes them from the file length after a crash. Next launch processes everything left here.
public struct SpoolEntry: Codable, Equatable, Sendable {
    public var id: String
    public var startedAt: Date
    /// Seconds into the audio just after the last speech. Updated as speech ends, so a crash still knows.
    public var speechEnd: Double
    /// Total seconds of speech (VAD), to drop blips.
    public var speechSeconds: Double
    public var closed: Bool
    public var attempts: Int
    /// For `sona file`: the original file name, shown in the note.
    public var source: String?
    /// Optional prior on how many people spoke (from `--speakers`, or the live pass). Absent in older entries.
    public var speakers: SpeakerHint?
    /// Share of the speech during which this Mac was itself playing audio (0...1); nil when unknown (a file,
    /// older entries). High means the "conversation" is likely media from this Mac.
    public var playback: Double?
    /// The note reserved for it on the first attempt to write one, relative to the Conversations folder
    /// (`2026-10-29/14-03 Title.md`, so a moved notes folder still works): a retry overwrites it, so a crash
    /// between writing the note and clearing the spool never makes a second note.
    public var note: String?
    /// What this Mac played during it (`<id>.mac.wav`), when it played anything. Absent otherwise.
    public var mac: MacTrack?

    /// The Mac's audio for a conversation: its own WAV, starting `offset` seconds into the conversation and
    /// sample-aligned with the mic's from there.
    public struct MacTrack: Codable, Equatable, Sendable {
        public var offset: Double
        /// Seconds of the conversation's speech the Mac track was speaking in.
        public var speechSeconds: Double

        public init(offset: Double, speechSeconds: Double = 0) {
            self.offset = offset
            self.speechSeconds = speechSeconds
        }
    }

    public init(id: String, startedAt: Date, source: String? = nil, speakers: SpeakerHint? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.speechEnd = 0
        self.speechSeconds = 0
        self.closed = false
        self.attempts = 0
        self.source = source
        self.speakers = speakers
    }
}

public final class Spool: @unchecked Sendable {  // an immutable dir and a locked id; the files are the state
    public let dir: URL
    static let sampleRate = 16_000
    private let recording = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The conversation the Listener is recording into right now (set by the Listener). The processor never
    /// touches it until it's closed, whatever order the app starts things in.
    public var openID: String? {
        get { recording.withLock { $0 } }
        set { recording.withLock { $0 = newValue } }
    }

    /// `create`: make the folder if it's missing (false to only look).
    public init(dir: URL = Paths.spool, create: Bool = true) {
        self.dir = dir
        if create { Paths.ensure(dir) }
    }

    public func wav(_ id: String) -> URL { dir.appendingPathComponent(id + ".wav") }
    /// The Mac's audio for that conversation, if it had any.
    public func macWav(_ id: String) -> URL { dir.appendingPathComponent(id + ".mac.wav") }
    func meta(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }
    public func failedDir() -> URL { dir.appendingPathComponent("failed", isDirectory: true) }

    public static func newID(for date: Date) -> String {
        NoteWriter.timeString(date, "yyyyMMdd-HHmmss") + "-" + String(UUID().uuidString.prefix(4))
    }

    /// `durable`: on disk for real before returning (the 5 s checkpoints and the close), so a power cut
    /// can't leave a half-written or missing entry. Otherwise a plain atomic write. Either way 0600, like the audio.
    /// Returns false if it couldn't be written (only checked where it matters: the note reservation).
    @discardableResult
    public func save(_ entry: SpoolEntry, durable: Bool = false) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entry) else { return false }
        guard durable else { return (try? NoteWriter.writePrivate(data, to: meta(entry.id))) != nil }
        // Temp file, fsync, rename over the old one, fsync the folder so the rename sticks. The caller's
        // F_FULLFSYNC (WavFile.checkpoint) then flushes the drive's cache for all of it at once.
        let tmp = tempMeta(entry.id)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return false }
        let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
        fsync(fd)
        close(fd)
        guard wrote, rename(tmp.path, meta(entry.id).path) == 0 else {
            unlink(tmp.path)
            return false
        }
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
        return true
    }

    public func load(_ id: String) -> SpoolEntry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: meta(id)) else { return nil }
        return try? decoder.decode(SpoolEntry.self, from: data)
    }

    /// Everything waiting, oldest first. A WAV with no metadata (crashed before it was written) gets some,
    /// saved unless `readOnly` (`sona status` looks while the app may be recording).
    public func pending(readOnly: Bool = false) -> [SpoolEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var entries: [SpoolEntry] = []
        for file in files where file.hasSuffix(".wav") && !file.hasSuffix(".mac.wav") {
            let id = String(file.dropLast(4))
            if let entry = load(id) {
                entries.append(entry)
            } else {
                let attrs = try? FileManager.default.attributesOfItem(atPath: wav(id).path)
                var entry = SpoolEntry(id: id, startedAt: attrs?[.creationDate] as? Date ?? Date())
                entry.speechEnd = WavFile.duration(of: wav(id))
                entry.speechSeconds = entry.speechEnd
                if !readOnly { save(entry) }
                entries.append(entry)
            }
        }
        return entries.sorted { $0.startedAt < $1.startedAt }
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: wav(id))
        try? FileManager.default.removeItem(at: macWav(id))
        try? FileManager.default.removeItem(at: meta(id))
        try? FileManager.default.removeItem(at: tempMeta(id))
    }

    /// Where `save` writes before renaming; only left behind by a crash mid-save.
    private func tempMeta(_ id: String) -> URL { dir.appendingPathComponent(".\(id).json.tmp") }

    /// Moves a conversation that keeps failing out of the way, keeping its audio. Never deleted silently.
    public func fail(_ id: String) {
        let failed = failedDir()
        Paths.ensure(failed)
        try? FileManager.default.moveItem(at: wav(id), to: failed.appendingPathComponent(id + ".wav"))
        try? FileManager.default.moveItem(at: macWav(id), to: failed.appendingPathComponent(id + ".mac.wav"))
        try? FileManager.default.moveItem(at: meta(id), to: failed.appendingPathComponent(id + ".json"))
        try? FileManager.default.removeItem(at: tempMeta(id))
    }

    public func failedCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: failedDir().path)) ?? []).filter { $0.hasSuffix(".wav") && !$0.hasSuffix(".mac.wav") }.count
    }
}

/// A 16 kHz mono 16-bit WAV that's appended to while it's being recorded. Readable by this user only (0600): it's
/// what was said.
public final class WavFile {
    public let url: URL
    private let handle: FileHandle
    public private(set) var samples = 0

    public init(creating url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: WavFile.header(dataBytes: 0), attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    public func append(_ floats: [Float]) throws {
        guard !floats.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: floats.count)
        for i in floats.indices {
            pcm[i] = Int16(max(-1, min(1, floats[i])) * 32767)
        }
        try pcm.withUnsafeBufferPointer { try handle.write(contentsOf: Data(buffer: $0)) }
        samples += floats.count
    }

    /// Makes everything appended so far (and the spool entry saved just before) survive a power cut:
    /// fsync, then F_FULLFSYNC so the drive empties its own cache too. Only at the 5 s checkpoints.
    public func checkpoint() throws {
        try handle.synchronize()
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    /// Cuts the audio at `seconds` (trailing quiet) and writes the real sizes into the header.
    public func finish(truncatingTo seconds: Double? = nil) throws {
        try handle.synchronize()
        try handle.close()
        try WavFile.repair(url, truncatingTo: seconds)
    }

    /// Fixes the header after a crash (and optionally truncates). Safe to run on a good file.
    public static func repair(_ url: URL, truncatingTo seconds: Double? = nil) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 44
        var dataBytes = max(0, size - 44) & ~1
        if let seconds {
            dataBytes = min(dataBytes, max(0, Int(seconds * Double(Spool.sampleRate))) * 2)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(44 + dataBytes))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataBytes: dataBytes))
    }

    /// Keeps only the first `seconds` ("delete the last N minutes") in a new file that replaces this one, so a
    /// transcription reading the old one right now isn't cut short under its feet (truncating would be).
    public static func cut(_ url: URL, to seconds: Double) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 44
        let dataBytes = min(max(0, size - 44) & ~1, max(0, Int(seconds * Double(Spool.sampleRate))) * 2)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).cut")
        guard FileManager.default.createFile(atPath: tmp.path, contents: header(dataBytes: dataBytes), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: tmp)
            defer { try? output.close() }
            try output.seekToEnd()
            try input.seek(toOffset: 44)
            var left = dataBytes
            while left > 0, let chunk = try input.read(upToCount: min(left, 1 << 22)), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                left -= chunk.count
            }
            try output.synchronize()
            guard rename(tmp.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(tmp.path)
            throw error
        }
    }

    public static func duration(of url: URL) -> Double {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 44
        return Double(max(0, size - 44) / 2) / Double(Spool.sampleRate)
    }

    static func header(dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(Spool.sampleRate); u32(Spool.sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}
