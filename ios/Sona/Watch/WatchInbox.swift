import Foundation
import NotesKit
import SonaEngine

/// Tells the watch "got it" for a recording. WCSession in the app (WatchReceiver), a fake in tests.
nonisolated protocol WatchAcknowledging: Sendable {
    func acknowledge(_ id: String)
}

/// The iPhone's side of the watch-to-iPhone contract (Shared/WatchTransfer.swift), without WCSession: a file the
/// watch sent becomes one closed recording in the spool however many times it arrives, and every copy is acknowledged
/// so the watch can delete its own. A WAV goes into the spool inside the callback; the watch's AAC is kept as it came
/// (staged) inside it, and decoded into the spool after (`convertStaged`).
nonisolated final class WatchInbox: @unchecked Sendable {  // lets, and the received ids behind a lock
    enum Outcome: Equatable, Sendable {
        /// New: now in the spool under this id.
        case added(spoolID: String)
        /// New and compressed (the watch's AAC): kept as it came, safely on disk, and acknowledged. `convertStaged()`
        /// turns it into a spool recording after the callback, since decoding an hour takes a while.
        case staged
        /// Received before: acknowledged again, nothing added.
        case duplicate
        /// Under half a second: acknowledged (the watch lets it go), not kept.
        case tooShort
        /// Not a recording of ours.
        case ignored
    }

    static let source = NoteSource.watch
    /// Watch ids remembered (oldest forgotten first). The watch resends within hours, so a thousand is plenty.
    static let remembered = 1000

    let spool: Spool
    let receivedFile: URL
    /// The watch's AAC recordings between the callback and the spool: `<watch id>.aac` with a `<watch id>.json` (its
    /// `WatchRecording`), the JSON written last, so a listed pair is whole. Beside `receivedFile`, out of backups like
    /// the spool.
    let stagingDir: URL
    let acknowledger: WatchAcknowledging
    /// Held while receiving, and while staged recordings are listed or put in the spool, so a pair is never looked at
    /// half staged and two spool ids are never picked at once.
    private let lock = NSLock()
    /// Held for a whole pass of `convertStaged`, so two passes never decode the same recording.
    private let convertLock = NSLock()
    private var received: [String]?

    init(spool: Spool, receivedFile: URL, acknowledger: WatchAcknowledging, stagingDir: URL? = nil) {
        self.spool = spool
        self.receivedFile = receivedFile
        self.stagingDir =
            stagingDir ?? receivedFile.deletingLastPathComponent().appendingPathComponent("WatchStaging", isDirectory: true)
        self.acknowledger = acknowledger
    }

    /// Runs inside WCSession's callback, which deletes `file` when it returns, so all of it is synchronous. Throws
    /// (and acknowledges nothing, so the watch sends it again) if the recording couldn't be saved.
    @discardableResult
    func receive(file: URL, metadata: [String: Any]?) throws -> Outcome {
        guard let recording = WatchRecording(metadata: metadata) else { return .ignored }
        let outcome = try lock.withLock { () throws -> Outcome in
            var ids = received ?? loadReceived()
            received = ids
            if ids.contains(recording.id) { return .duplicate }
            let result: Outcome
            if Self.isWAV(file) {
                // An older watch build's, or its fallback: its samples are copied, not decoded, so it fits in here.
                let spoolID = try add(file, startedAt: recording.startedAt)  // nil: too short to keep
                result = spoolID.map { Outcome.added(spoolID: $0) } ?? .tooShort
            } else {
                // The watch's AAC: decoding it here could outlast the callback.
                try stage(file, recording: recording)
                result = .staged
            }
            // Remembered only once it's safely on disk: a crash before this means a duplicate, never a loss.
            ids.append(recording.id)
            if ids.count > Self.remembered { ids.removeFirst(ids.count - Self.remembered) }
            received = ids
            saveReceived(ids)
            return result
        }
        acknowledger.acknowledge(recording.id)
        return outcome
    }

    /// The newest `count` watch recordings received, for the inventory the watch reads (`PhoneInventory`).
    func receivedIDs(last count: Int = PhoneInventory.kept) -> [String] {
        lock.withLock {
            let ids = received ?? loadReceived()
            received = ids
            return Array(ids.suffix(count))
        }
    }

    /// Puts the watch's WAV in the spool as a new closed entry. Returns its spool id, or nil if it's too short to keep.
    private func add(_ file: URL, startedAt: Date) throws -> String? {
        let fm = FileManager.default
        // Made whole in a temporary file first: the spool adopts any WAV it finds (as a recording a crash left open), so
        // one must never appear there half written.
        let incoming = fm.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: incoming) }
        if Self.isSpoolFormat(file) {
            try fm.moveItem(at: file, to: incoming)
            try WavFile.repair(incoming)
        } else if let samples = Self.spoolSamples(in: file) {
            // The watch's WAVs (older builds, or its fallback): 16 kHz mono 16-bit already, behind AVAudioRecorder's
            // 4 KB header (FLLR padding). Its samples are copied as they are behind the spool's 44-byte header: nothing
            // decoded, so an hour from the watch takes a second, not the whole callback (and the samples stay bit for
            // bit).
            try Self.rewrap(file, samples: samples, to: incoming)
        } else {
            // Any other WAV (another rate or layout): decoded and converted.
            try Self.convert(file, to: incoming)
        }
        return try adopt(incoming, startedAt: startedAt)
    }

    /// Moves a whole spool-format WAV into the spool as a new closed entry. Returns its spool id, or nil if it's too
    /// short to keep. Called with `lock` held.
    private func adopt(_ incoming: URL, startedAt: Date) throws -> String? {
        let fm = FileManager.default
        // Under half a second isn't a recording (a double tap): acknowledged, so the watch lets it go, but not kept.
        guard WavFile.duration(of: incoming) >= 0.5 else {
            Log.note("watch recording \(Log.ref(startedAt)) under half a second, not kept")
            return nil
        }
        var spoolID = Spool.newID(for: startedAt)
        while spool.load(spoolID) != nil || fm.fileExists(atPath: spool.wav(spoolID).path) { spoolID = Spool.newID(for: startedAt) }
        let wav = spool.wav(spoolID)
        do {
            chmod(incoming.path, 0o600)
            try Self.sync(incoming)
            // Atomic: the temporary folder is on the same volume.
            try fm.moveItem(at: incoming, to: wav)
            var entry = SpoolEntry(id: spoolID, startedAt: startedAt, source: Self.source)
            entry.closed = true
            entry.speechEnd = WavFile.duration(of: wav)
            entry.speechSeconds = entry.speechEnd
            guard spool.save(entry, durable: true) else { throw CocoaError(.fileWriteUnknown) }
            Log.note("watch recording \(Log.ref(startedAt)) received (spool \(spoolID), \(String(format: "%.1f", entry.speechEnd)) s)")
            return spoolID
        } catch {
            spool.remove(spoolID)
            throw error
        }
    }

    // MARK: The watch's AAC

    /// Keeps a compressed recording as it came, inside the callback: a move and an fsync, nothing decoded. The JSON
    /// goes last, and is on disk for real before the watch is told it may delete its copy. Audio left without its JSON
    /// (a crash in between) was never acknowledged, so the watch sends it again and the copy here is replaced.
    private func stage(_ file: URL, recording: WatchRecording) throws {
        let fm = FileManager.default
        prepareStaging()
        let audio = stagedAudio(recording.id)
        try? fm.removeItem(at: audio)
        try fm.moveItem(at: file, to: audio)
        chmod(audio.path, 0o600)
        try Self.sync(audio)
        let info = stagedInfo(recording.id)
        try NoteWriter.writePrivate(JSONEncoder().encode(recording), to: info)
        try Self.sync(info)
        Log.note("watch recording \(Log.ref(recording.startedAt)) received, to convert")
    }

    private func stagedAudio(_ id: String) -> URL { stagingDir.appendingPathComponent("\(id).aac") }
    private func stagedInfo(_ id: String) -> URL { stagingDir.appendingPathComponent("\(id).json") }

    /// Raw audio, like the spool: out of iCloud Backup and computer backups, and readable once the phone has been
    /// unlocked since it started (it's received with the phone locked).
    private func prepareStaging() {
        guard !FileManager.default.fileExists(atPath: stagingDir.path) else { return }
        Paths.ensure(stagingDir)
        var url = stagingDir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stagingDir.path)
    }

    /// The whole staged pairs. A JSON whose audio is gone has nothing to convert and is removed. Called with `lock`
    /// held, so nothing is half staged.
    private func stagedRecordings() -> [WatchRecording] {
        let fm = FileManager.default
        let infos = ((try? fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        return infos.compactMap { info in
            guard let data = try? Data(contentsOf: info),
                let recording = try? JSONDecoder().decode(WatchRecording.self, from: data),
                fm.fileExists(atPath: stagedAudio(recording.id).path)
            else {
                try? fm.removeItem(at: info)
                return nil
            }
            return recording
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    /// Turns the staged recordings into spool recordings, decoding each to the spool's 16 kHz mono 16-bit WAV. Runs off
    /// WCSession's queue and the main actor (it decodes), at launch and after each one arrives. Returns the spool ids
    /// added, to queue for notes. One that fails stays staged and is tried again next time: it was acknowledged, so
    /// this is its only copy.
    func convertStaged() -> [String] {
        convertLock.withLock {
            let fm = FileManager.default
            var added: [String] = []
            for recording in lock.withLock({ stagedRecordings() }) {
                let audio = stagedAudio(recording.id)
                let info = stagedInfo(recording.id)
                let incoming = fm.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).wav")
                defer { try? fm.removeItem(at: incoming) }
                do {
                    // The watch cuts a torn last frame off before it sends, but a crashed or older build may not have:
                    // cut it here too, or the file may never decode, and the watch has already let its copy go.
                    _ = try? ADTSFile.scan(audio, repair: true)
                    try Self.convert(audio, to: incoming)
                    if let spoolID = try lock.withLock({ try adopt(incoming, startedAt: recording.startedAt) }) {
                        added.append(spoolID)
                    }
                    // The JSON first: without it the audio is never converted twice.
                    try? fm.removeItem(at: info)
                    try? fm.removeItem(at: audio)
                } catch {
                    Log.note("a watch recording couldn't be converted yet; it stays on this iPhone: \(Log.describe(error))")
                }
            }
            return added
        }
    }

    /// A WAV of any layout (the watch's older recordings, or its fallback), by its first bytes.
    static func isWAV(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return false }
        return header.prefix(4) == Data("RIFF".utf8) && header.dropFirst(8).prefix(4) == Data("WAVE".utf8)
    }

    /// The spool's own WAV: a 44-byte header, 16-bit PCM, mono, 16 kHz, the samples right after.
    static func isSpoolFormat(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 44), data.count == 44 else { return false }
        let h = [UInt8](data)
        func text(_ at: Int) -> String { String(decoding: h[at..<at + 4], as: UTF8.self) }
        func u16(_ at: Int) -> Int { Int(h[at]) | Int(h[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        return text(0) == "RIFF" && text(8) == "WAVE" && text(12) == "fmt " && u32(16) == 16 && u16(20) == 1
            && u16(22) == 1 && u32(24) == 16_000 && u16(34) == 16 && text(36) == "data"
    }

    /// Where the samples are, if the file is the spool's own format (16 kHz, mono, 16-bit PCM) whatever its header
    /// holds; nil for anything else.
    static func spoolSamples(in url: URL) -> Range<Int>? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: WAVFile.headerLimit), let info = WAVFile.info(of: header),
            info.sampleRate == 16_000, info.channels == 1, info.bitsPerSample == 16,
            let length = try? handle.seekToEnd()
        else { return nil }
        // The header's size can be 0 (a recording a crash cut off) or past the end: the file's length decides then.
        let onDisk = Int(length) - info.dataStart
        let claimed = Int(info.dataSize)
        var bytes = claimed > 0 && claimed <= onDisk ? claimed : onDisk
        bytes -= bytes % 2  // whole samples
        return bytes > 0 ? info.dataStart..<(info.dataStart + bytes) : nil
    }

    /// The samples of `file` behind a fresh 44-byte header, streamed a megabyte at a time.
    static func rewrap(_ file: URL, samples: Range<Int>, to wav: URL) throws {
        let writer = try WavFile(creating: wav)
        try writer.finish()  // the header, sizes 0 for now
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: wav)
        defer { try? output.close() }
        try output.seekToEnd()
        try input.seek(toOffset: UInt64(samples.lowerBound))
        var left = samples.count
        while left > 0 {
            guard let chunk = try input.read(upToCount: min(left, 1 << 20)), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            left -= chunk.count
        }
        try output.close()
        try WavFile.repair(wav)  // the sizes, from what was copied
    }

    /// Any audio AVFoundation reads, as the spool's 16 kHz mono 16-bit WAV.
    static func convert(_ file: URL, to wav: URL) throws {
        let reader = try AudioFileReader(url: file)
        let writer = try WavFile(creating: wav)
        while let chunk = try reader.next() { try writer.append(chunk) }
        try writer.finish()
    }

    /// On disk for real before the watch is told it may delete its copy.
    private static func sync(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
    }

    private func loadReceived() -> [String] {
        guard let data = try? Data(contentsOf: receivedFile) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func saveReceived(_ ids: [String]) {
        Paths.ensure(receivedFile.deletingLastPathComponent())
        do { try NoteWriter.writePrivate(JSONEncoder().encode(ids), to: receivedFile) } catch {
            Log.note("couldn't save the watch recordings received: \(Log.describe(error))")
        }
    }
}
