import NotesKit
import XCTest

@testable import SonaEngine

final class SpoolTests: XCTestCase {
    var home: URL!
    var previousHome: String?

    override func setUp() {
        previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sona-engine-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SONA_HOME", home.path, 1)
    }

    override func tearDown() {
        if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    /// A conversation left open by a crash goes through the processor; the log names it by time, never by its words.
    func testLogNeverHoldsTranscriptWords() async throws {
        let spool = Spool()
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let entry = SpoolEntry(id: Spool.newID(for: started), startedAt: started)
        let wav = try WavFile(creating: spool.wav(entry.id))
        spool.save(entry, durable: true)
        try wav.append((0..<32_000).map { Float(sin(Double($0) * 0.05)) * 0.3 })
        try wav.checkpoint()  // then "crash": never finished, entry still open

        let said = ["Zebra", "marmalade", "quantum", "pineapple", "lighthouse", "budget"]
        let processor = Processor(spool: spool, settings: Settings())
        await processor.useTranscriber { _, startedAt in
            let words = said.enumerated().map { Word(word: $1, start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25, speaker: "Speaker 1") }
            return Transcript(
                startedAt: startedAt, duration: 2, text: said.joined(separator: " "), words: words,
                turns: [Turn(speaker: "Speaker 1", start: 0, end: 2)], asrSeconds: 0.01, diarizationSeconds: 0.01, model: "test")
        }
        await processor.recover()
        await processor.waitUntilIdle()

        let written = await processor.written
        let note = try XCTUnwrap(written.first)
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("marmalade"))
        XCTAssertTrue(note.lastPathComponent.contains("Zebra"))  // the title is the first words: exactly what must stay out

        Log.note("write failed: \(Log.describe(CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: note.path])))")

        let log = try String(contentsOf: Paths.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("note written: \(Log.ref(started))"), log)
        XCTAssertTrue(log.contains("recovered unfinished (spool \(entry.id))"), log)
        for word in said { XCTAssertFalse(log.lowercased().contains(word.lowercased()), "log has \"\(word)\":\n\(log)") }
    }

    /// What a durable 5 s checkpoint costs (entry JSON + F_FULLFSYNC on the WAV), printed for the report.
    func testCheckpointCost() throws {
        let spool = Spool()
        var entry = SpoolEntry(id: Spool.newID(for: Date()), startedAt: Date())
        let wav = try WavFile(creating: spool.wav(entry.id))
        let fiveSeconds = [Float](repeating: 0.1, count: 5 * 16_000)
        var times: [Double] = []
        for i in 0..<30 {
            try wav.append(fiveSeconds)
            entry.speechEnd = Double(i * 5)
            let t0 = Date()
            spool.save(entry, durable: true)
            try wav.checkpoint()
            times.append(Date().timeIntervalSince(t0) * 1000)
        }
        let sorted = times.sorted()
        print(String(format: "checkpoint cost over %d: avg %.2f ms, p50 %.2f ms, max %.2f ms",
            times.count, times.reduce(0, +) / Double(times.count), sorted[times.count / 2], sorted.last!))
        XCTAssertEqual(spool.load(entry.id)?.speechEnd, 145)
        XCTAssertLessThan(sorted[times.count / 2], 250)  // must stay far below the 5 s between checkpoints
    }

    // MARK: Save, load, pending, remove, fail

    private func spoolDir() -> URL { home.appendingPathComponent("Spool-\(UUID().uuidString.prefix(6))", isDirectory: true) }

    private func entry(_ seconds: TimeInterval) -> SpoolEntry {
        let started = Date(timeIntervalSince1970: 1_790_000_000 + seconds)
        return SpoolEntry(id: Spool.newID(for: started), startedAt: started)
    }

    func testSaveLoadRoundTripsEveryField() {
        let spool = Spool(dir: spoolDir())
        var e = entry(0)
        e.speechEnd = 12.5
        e.speechSeconds = 9.25
        e.closed = true
        e.attempts = 2
        e.source = "meeting.m4a"
        e.speakers = SpeakerHint(min: 2, max: 4)
        spool.save(e)
        XCTAssertEqual(spool.load(e.id), e)

        e.attempts = 3
        spool.save(e, durable: true)
        XCTAssertEqual(spool.load(e.id), e, "durable save replaces the old entry")
        let leftovers = try? FileManager.default.contentsOfDirectory(atPath: spool.dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "no temp file left behind")
    }

    func testLoadMissingOrCorruptIsNil() throws {
        let spool = Spool(dir: spoolDir())
        XCTAssertNil(spool.load("nope"))
        try Data("{ not json".utf8).write(to: spool.meta("broken"))
        XCTAssertNil(spool.load("broken"))
    }

    /// Entries written before `speakers` existed still load.
    func testOlderEntryWithoutSpeakersLoads() throws {
        let spool = Spool(dir: spoolDir())
        let json = #"{"id":"old","startedAt":"2026-10-27T04:00:00Z","speechEnd":3,"speechSeconds":2,"closed":true,"attempts":0}"#
        try Data(json.utf8).write(to: spool.meta("old"))
        let loaded = try XCTUnwrap(spool.load("old"))
        XCTAssertNil(loaded.speakers)
        XCTAssertNil(loaded.source)
        XCTAssertEqual(loaded.speechEnd, 3)
    }

    func testPendingIsOldestFirstAndOnlyCountsAudio() throws {
        let spool = Spool(dir: spoolDir())
        let late = entry(600), early = entry(0), orphanMeta = entry(300)
        for e in [late, early] {
            _ = try WavFile(creating: spool.wav(e.id))
            spool.save(e)
        }
        spool.save(orphanMeta)  // JSON with no audio: nothing to process
        XCTAssertEqual(spool.pending().map(\.id), [early.id, late.id])
    }

    /// A crash before the first JSON write: the WAV alone still comes back, with an entry made from its length.
    func testPendingRecoversWavWithoutMetadata() throws {
        let spool = Spool(dir: spoolDir())
        let wav = try WavFile(creating: spool.wav("crashed"))
        try wav.append([Float](repeating: 0.2, count: 3 * 16_000))
        try wav.checkpoint()  // never finished: header still says 0 bytes

        let pending = spool.pending()
        XCTAssertEqual(pending.map(\.id), ["crashed"])
        XCTAssertEqual(pending[0].speechEnd, 3, accuracy: 0.001)
        XCTAssertEqual(pending[0].speechSeconds, 3, accuracy: 0.001)
        XCTAssertFalse(pending[0].closed)
        let saved = try XCTUnwrap(spool.load("crashed"), "the made-up entry is saved")
        XCTAssertEqual(saved.speechEnd, pending[0].speechEnd)
        XCTAssertEqual(saved.startedAt.timeIntervalSince(pending[0].startedAt), 0, accuracy: 1)
    }

    func testRemoveDeletesAudioMetadataAndTempFile() throws {
        let spool = Spool(dir: spoolDir())
        let e = entry(0)
        _ = try WavFile(creating: spool.wav(e.id))
        spool.save(e)
        let tmp = spool.dir.appendingPathComponent(".\(e.id).json.tmp")
        try Data("half".utf8).write(to: tmp)
        spool.remove(e.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spool.dir.path), [])
        XCTAssertEqual(spool.pending(), [])
    }

    func testFailKeepsTheAudioOutOfTheWay() throws {
        let spool = Spool(dir: spoolDir())
        let e = entry(0)
        let wav = try WavFile(creating: spool.wav(e.id))
        try wav.append([Float](repeating: 0.1, count: 16_000))
        try wav.finish()
        spool.save(e)
        XCTAssertEqual(spool.failedCount(), 0)

        spool.fail(e.id)
        XCTAssertEqual(spool.pending(), [])
        XCTAssertEqual(spool.failedCount(), 1)
        let failed = spool.failedDir()
        XCTAssertEqual(WavFile.duration(of: failed.appendingPathComponent(e.id + ".wav")), 1, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.appendingPathComponent(e.id + ".json").path))
    }

    /// What's waiting to become a note is what was said: its audio and entry are this user's only, after a cut too.
    func testSpoolFilesArePrivate() throws {
        let spool = Spool(dir: spoolDir())
        let e = entry(0)
        let wav = try WavFile(creating: spool.wav(e.id))
        try wav.append([Float](repeating: 0.1, count: 16_000))
        try wav.finish()
        func mode(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
        spool.save(e)
        XCTAssertEqual(mode(spool.wav(e.id)), 0o600)
        XCTAssertEqual(mode(spool.meta(e.id)), 0o600)
        spool.save(e, durable: true)
        XCTAssertEqual(mode(spool.meta(e.id)), 0o600)
        try WavFile.cut(spool.wav(e.id), to: 0.5)
        XCTAssertEqual(mode(spool.wav(e.id)), 0o600)
    }

    // MARK: WavFile

    private func header(_ url: URL) throws -> (riff: UInt32, data: UInt32, size: Int) {
        let d = try Data(contentsOf: url)
        func u32(_ at: Int) -> UInt32 { d[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        return (u32(4), u32(40), d.count)
    }

    func testFinishWritesRealSizesAndTruncates() throws {
        let url = home.appendingPathComponent("t.wav")
        let wav = try WavFile(creating: url)
        try wav.append([Float](repeating: 0.5, count: 16_000 * 4))
        XCTAssertEqual(wav.samples, 64_000)
        try wav.finish(truncatingTo: 2.5)
        let h = try header(url)
        XCTAssertEqual(h.data, 80_000)  // 2.5 s * 16 kHz * 2 bytes
        XCTAssertEqual(h.riff, 36 + 80_000)
        XCTAssertEqual(h.size, 44 + 80_000)
        XCTAssertEqual(WavFile.duration(of: url), 2.5)
        // Reads back as real audio.
        let reader = try AudioFileReader(url: url)
        XCTAssertEqual(reader.duration, 2.5, accuracy: 0.001)
    }

    /// After a crash the header says 0 bytes; repair fixes it from the file length (and drops a torn last byte).
    func testRepairAfterCrash() throws {
        let url = home.appendingPathComponent("crash.wav")
        let wav = try WavFile(creating: url)
        try wav.append([Float](repeating: -0.3, count: 1000))
        try wav.checkpoint()
        XCTAssertEqual(try header(url).data, 0)
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(Data([0x7f]))  // half a sample
        try h.close()

        try WavFile.repair(url)
        let fixed = try header(url)
        XCTAssertEqual(fixed.data, 2000)
        XCTAssertEqual(fixed.size, 2044)
        try WavFile.repair(url)
        XCTAssertEqual(try header(url).data, 2000, "safe to run twice")
    }

    // MARK: Processor: repair, the open entry, retries, privacy

    /// A stand-in transcriber that reports the audio length the WAV header claims.
    private func processor(_ spool: Spool, settings: Settings = Settings(), headerSeconds: Locked? = nil) async -> Processor {
        let p = Processor(spool: spool, settings: settings)
        await p.useTranscriber { url, startedAt in
            let d = try Data(contentsOf: url)
            let bytes = d[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            headerSeconds?.set(Double(bytes) / 32_000)
            let words = ["Budget", "talk", "for", "March"].enumerated().map {
                Word(word: $1, start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25, speaker: "Speaker 1")
            }
            return Transcript(
                startedAt: startedAt, duration: 2, text: "Budget talk for March", words: words,
                turns: [Turn(speaker: "Speaker 1", start: 0, end: 2)], asrSeconds: 0.01, diarizationSeconds: 0.01, model: "test")
        }
        return p
    }

    final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double?
        func set(_ v: Double) { lock.withLock { value = v } }
        var get: Double? { lock.withLock { value } }
    }

    /// A closed entry whose WAV header still says 0 bytes (finishing it threw, a full disk say) is repaired
    /// and cut at its recorded end, not failed three times.
    func testClosedEntryWithEmptyHeaderIsRepaired() async throws {
        let spool = Spool()
        var e = entry(0)
        let wav = try WavFile(creating: spool.wav(e.id))
        try wav.append([Float](repeating: 0.2, count: 3 * 16_000))
        try wav.checkpoint()  // header still 0 bytes
        XCTAssertEqual(try header(spool.wav(e.id)).data, 0)
        e.closed = true
        e.speechEnd = 2
        e.speechSeconds = 2
        spool.save(e)

        let seen = Locked()
        let p = await processor(spool, headerSeconds: seen)
        await p.enqueue(e.id)
        await p.waitUntilIdle()
        XCTAssertEqual(seen.get ?? 0, 2, accuracy: 0.001, "repaired and cut at speechEnd before transcribing")
        let written = await p.written
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(spool.pending(), [])
    }

    /// A recording from somewhere else (the iPhone, the watch, `sona file`) that's under half a second is dropped, not
    /// tried three times and failed: the model can't take one that short.
    func testSourcedRecordingUnderHalfASecondIsDropped() async throws {
        let spool = Spool()
        var e = SpoolEntry(id: Spool.newID(for: Date()), startedAt: Date(), source: "Apple Watch")
        let wav = try WavFile(creating: spool.wav(e.id))
        try wav.append([Float](repeating: 0.2, count: 3_200))  // 0.2 s
        try wav.finish()
        e.closed = true
        e.speechEnd = 0.2
        e.speechSeconds = 0.2
        spool.save(e)

        let p = await processor(spool)
        await p.enqueue(e.id)
        await p.waitUntilIdle()
        let written = await p.written
        XCTAssertEqual(written.count, 0)
        XCTAssertEqual(spool.pending(), [])
        XCTAssertEqual(spool.failedCount(), 0)
    }

    /// No words: dropped when the Mac's always-on mic heard it, kept (note + audio) when someone recorded it on the
    /// iPhone or the watch.
    func testNoWordsIsKeptOnlyForDeliberateRecordings() async throws {
        let spool = Spool()
        var settings = Settings(notesFolder: home.appendingPathComponent("Notes").path)
        settings.keepAudio = true
        func entry(_ source: String?, _ offset: Double) throws -> SpoolEntry {
            var e = SpoolEntry(id: Spool.newID(for: Date().addingTimeInterval(offset)), startedAt: Date().addingTimeInterval(offset), source: source)
            let wav = try WavFile(creating: spool.wav(e.id))
            try wav.append([Float](repeating: 0.01, count: 3 * 16_000))
            try wav.finish()
            e.closed = true
            e.speechEnd = 3
            e.speechSeconds = 3
            spool.save(e)
            return e
        }
        let mac = try entry(nil, -120)
        let watch = try entry(NoteSource.watch, -60)
        let p = Processor(spool: spool, settings: settings)
        await p.useTranscriber { _, startedAt in
            Transcript(startedAt: startedAt, duration: 3, text: "", words: [], turns: [], asrSeconds: 0.01, diarizationSeconds: 0.01, model: "test")
        }
        await p.enqueue(mac.id)
        await p.enqueue(watch.id)
        await p.waitUntilIdle()
        let written = await p.written
        XCTAssertEqual(written.count, 1, "only the watch's")
        let note = try XCTUnwrap(written.first)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.contains("_(no speech transcribed)_"), text)
        XCTAssertTrue(text.contains("title: \"No speech transcribed\""), text)
        XCTAssertTrue(text.contains("source: \"Apple Watch\""), text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.deletingPathExtension().appendingPathExtension("wav").path), "its audio is kept")
        XCTAssertEqual(spool.pending(), [])
        XCTAssertEqual(spool.failedCount(), 0)
    }

    /// The live pass's speaker count rides with the entry into processing; a hint already there (from
    /// `sona file --speakers`) wins.
    func testLiveSpeakerHintIsStoredWithTheEntry() async throws {
        let spool = Spool()
        let live = entry(0), given = entry(60)
        for e in [live, given] {
            var e = e
            let wav = try WavFile(creating: spool.wav(e.id))
            try wav.append([Float](repeating: 0.2, count: 3 * 16_000))
            try wav.finish()
            e.closed = true
            e.speechEnd = 3
            e.speechSeconds = 3
            if e.id == given.id { e.speakers = SpeakerHint(min: 2, max: 4) }
            spool.save(e)
        }
        let seen = HintBox()
        let p = Processor(spool: spool, settings: Settings())
        await p.useTranscriber { _, startedAt in
            let id = startedAt == live.startedAt ? live.id : given.id
            seen.set(id, spool.load(id)?.speakers)
            let words = [Word(word: "Hello", start: 0, end: 0.3, speaker: "Speaker 1")]
            return Transcript(
                startedAt: startedAt, duration: 1, text: "Hello", words: words,
                turns: [Turn(speaker: "Speaker 1", start: 0, end: 1)], asrSeconds: 0.01, diarizationSeconds: 0.01, model: "test")
        }
        await p.enqueue(live.id, speakers: .exactly(2))
        await p.enqueue(given.id, speakers: .exactly(3))
        await p.waitUntilIdle()
        XCTAssertEqual(seen.get(live.id), .exactly(2))
        XCTAssertEqual(seen.get(given.id), SpeakerHint(min: 2, max: 4))
        let log = try String(contentsOf: Paths.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("\(Log.ref(live.startedAt)): live pass heard 2 speaker(s), passed on as a hint"), log)
        XCTAssertTrue(log.contains("(hint 2)"), log)
    }

    final class HintBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hints: [String: SpeakerHint?] = [:]
        func set(_ id: String, _ hint: SpeakerHint?) { lock.withLock { hints[id] = hint } }
        func get(_ id: String) -> SpeakerHint? { lock.withLock { hints[id] ?? nil } }
    }

    /// The conversation the Listener is recording into is never recovered or processed while open.
    func testRecoverSkipsTheOpenConversation() async throws {
        let spool = Spool()
        let open = entry(0), done = entry(60)
        for e in [open, done] {
            let wav = try WavFile(creating: spool.wav(e.id))
            try wav.append([Float](repeating: 0.2, count: 3 * 16_000))
            try wav.checkpoint()
            spool.save(e)  // both still open (closed = false)
        }
        spool.openID = open.id
        let p = await processor(spool)
        let n = await p.recover()
        XCTAssertEqual(n, 1)
        await p.enqueue(open.id)  // even if someone enqueues it
        await p.waitUntilIdle()
        XCTAssertEqual(spool.pending().map(\.id), [open.id], "the open one is untouched")
        XCTAssertEqual(spool.load(open.id)?.closed, false)
    }

    /// A crash after the note was written but before the spool was cleared: the retry overwrites the same
    /// note (reserved in the entry) instead of writing "... 2". Notes and kept audio are private.
    func testRetryReusesTheReservedNote() async throws {
        var settings = Settings()
        settings.keepAudio = true
        let spool = Spool()
        let e = entry(0)
        let wav = try WavFile(creating: spool.wav(e.id))
        try wav.append([Float](repeating: 0.2, count: 3 * 16_000))
        try wav.finish()
        var closed = e
        closed.closed = true
        closed.speechEnd = 3
        closed.speechSeconds = 3
        spool.save(closed)

        // First attempt writes the note; then "crash" by putting the spool entry back as it was after reserving.
        let p = await processor(spool, settings: settings)
        await p.enqueue(e.id)
        await p.waitUntilIdle()
        let firstWritten = await p.written
        let first = try XCTUnwrap(firstWritten.first)
        let kept = first.deletingPathExtension().appendingPathExtension("wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        func mode(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
        XCTAssertEqual(mode(first), 0o600)
        XCTAssertEqual(mode(first.deletingPathExtension().appendingPathExtension("json")), 0o600)
        XCTAssertEqual(mode(kept), 0o600)
        XCTAssertEqual(mode(first.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(mode(settings.conversationsURL), 0o700)

        try FileManager.default.moveItem(at: kept, to: spool.wav(e.id))
        closed.note = first.path
        spool.save(closed)
        let retry = await processor(spool, settings: settings)
        await retry.enqueue(e.id)
        await retry.waitUntilIdle()
        let retried = await retry.written
        XCTAssertEqual(retried, [first])
        let md = try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(md.count, 1, "one note per conversation: \(md)")
    }

    /// A recording that was started 3 times and never came back (the app was killed or crashed each time) goes to
    /// Spool/failed with its audio before the models load, instead of crashing every launch and blocking newer ones.
    func testARecordingThatNeverFinishedThreeTimesIsFailedNotRetried() async throws {
        let spool = Spool()
        var e = entry(0)
        let wav = try WavFile(creating: spool.wav(e.id))
        try wav.append([Float](repeating: 0.2, count: 2 * 16_000))
        try wav.finish()
        e.closed = true
        e.speechEnd = 2
        e.speechSeconds = 2
        e.attempts = Processor.maxAttempts
        spool.save(e)

        let called = Locked()
        let p = Processor(spool: spool, settings: Settings())
        await p.useTranscriber { _, startedAt in
            called.set(1)
            return Transcript(startedAt: startedAt, duration: 2, text: "", words: [], turns: [], asrSeconds: 0, diarizationSeconds: 0, model: "test")
        }
        await p.enqueue(e.id)
        await p.waitUntilIdle()
        XCTAssertNil(called.get, "never transcribed again")
        XCTAssertEqual(spool.failedCount(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.failedDir().appendingPathComponent(e.id + ".wav").path))
        XCTAssertEqual(spool.pending(), [])
        let written = await p.written
        XCTAssertEqual(written, [])
    }

    /// If the kept audio can't be moved beside its note, the spool keeps it and the note's .json goes (so it isn't
    /// whole and never syncs without its audio); the retry writes the same note again with its audio.
    func testKeptAudioThatCantMoveStaysInTheSpool() async throws {
        var settings = Settings()
        settings.keepAudio = true
        let spool = Spool()
        let e = entry(0)
        let wav = try WavFile(creating: spool.wav(e.id))
        try wav.append([Float](repeating: 0.2, count: 3 * 16_000))
        try wav.finish()
        var closed = e
        closed.closed = true
        closed.speechEnd = 3
        closed.speechSeconds = 3
        spool.save(closed)

        // A first run tells the note's name; its audio goes back to the spool as if that run never happened.
        let first = await processor(spool, settings: settings)
        await first.enqueue(e.id)
        await first.waitUntilIdle()
        let firstWritten = await first.written
        let note = try XCTUnwrap(firstWritten.first)
        let kept = note.deletingPathExtension().appendingPathExtension("wav")
        let json = note.deletingPathExtension().appendingPathExtension("json")
        try FileManager.default.moveItem(at: kept, to: spool.wav(e.id))
        closed.note = note.deletingLastPathComponent().lastPathComponent + "/" + note.lastPathComponent
        spool.save(closed)

        // Something at the kept audio's name that can't be removed: the move fails.
        let locked = kept.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("file"))
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o700) }

        let failing = await processor(spool, settings: settings)
        await failing.enqueue(e.id)
        await failing.waitUntilIdle()
        let none = await failing.written
        XCTAssertEqual(none, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.wav(e.id).path), "the audio stays in the spool")
        XCTAssertEqual(spool.load(e.id)?.attempts, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path), "not whole without its audio")

        chmod(locked.path, 0o700)
        try FileManager.default.removeItem(at: kept)
        let retry = await processor(spool, settings: settings)
        await retry.enqueue(e.id)
        await retry.waitUntilIdle()
        let again = await retry.written
        XCTAssertEqual(again, [note], "the same note, not \"... 2\"")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        XCTAssertEqual(spool.pending(), [])
    }

    /// `sona status` only looks: a WAV without metadata gets none written.
    func testReadOnlyPendingWritesNothing() throws {
        let dir = spoolDir()
        let spool = Spool(dir: dir)
        let wav = try WavFile(creating: spool.wav("crashed"))
        try wav.append([Float](repeating: 0.2, count: 16_000))
        XCTAssertEqual(Spool(dir: dir, create: false).pending(readOnly: true).map(\.id), ["crashed"])
        XCTAssertNil(spool.load("crashed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("never").path))
        _ = Spool(dir: home.appendingPathComponent("never"), create: false).pending(readOnly: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("never").path))
    }

    func testSamplesAreClippedNotWrapped() throws {
        let url = home.appendingPathComponent("clip.wav")
        let wav = try WavFile(creating: url)
        try wav.append([2, -2, 0])
        try wav.finish()
        let d = try Data(contentsOf: url)
        let pcm = (0..<3).map { i in Int16(bitPattern: UInt16(d[44 + 2 * i]) | UInt16(d[45 + 2 * i]) << 8) }
        XCTAssertEqual(pcm, [32767, -32767, 0])
    }
}
