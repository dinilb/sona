import NotesKit
import XCTest

@testable import SonaEngine

/// "Delete the last N minutes" in the processor: conversations waiting in the spool, the one being transcribed,
/// and the notes it already wrote.
final class ForgetSpoolTests: XCTestCase {
    var home: URL!
    var previousHome: String?
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sona-forget-spool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SONA_HOME", home.path, 1)
    }

    override func tearDown() {
        if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    var settings: Settings { Settings(notesFolder: home.appendingPathComponent("Notes").path) }

    /// A closed conversation of `seconds` of audio, started `at` seconds after t0.
    func conversation(_ spool: Spool, at: Double, seconds: Double) throws -> SpoolEntry {
        var e = SpoolEntry(id: Spool.newID(for: t0.addingTimeInterval(at)), startedAt: t0.addingTimeInterval(at))
        let wav = try WavFile(creating: spool.wav(e.id))
        try wav.append([Float](repeating: 0.2, count: Int(seconds * 16_000)))
        try wav.finish()
        e.closed = true
        e.speechEnd = seconds
        e.speechSeconds = seconds
        spool.save(e)
        return e
    }

    /// Words every 0.3 s for as long as the audio it's given (so a cut file gives fewer words).
    static func words(_ url: URL, _ startedAt: Date) -> Transcript {
        let seconds = WavFile.duration(of: url)
        let said = ["Budget", "talk", "for", "March", "and", "the", "secret", "plan", "here", "now"]
        let words = said.enumerated().filter { Double($0.offset) * 0.3 < seconds }.map {
            Word(word: $1, start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25, speaker: "Speaker 1")
        }
        return Transcript(
            startedAt: startedAt, duration: seconds, text: words.map(\.word).joined(separator: " "), words: words,
            turns: [Turn(speaker: "Speaker 1", start: 0, end: seconds)], asrSeconds: 0.01, diarizationSeconds: 0.01, model: "test")
    }

    /// Waiting conversations: one is cut at the cut (its audio truncated, so its note has only what came
    /// before), one that started after it is gone, one from before is left alone.
    func testWaitingConversationsAreCutOrDropped() async throws {
        let spool = Spool()
        let before = try conversation(spool, at: -100, seconds: 3)
        let across = try conversation(spool, at: 0, seconds: 3)
        let after = try conversation(spool, at: 10, seconds: 3)
        let p = Processor(spool: spool, settings: settings)
        await p.useTranscriber { url, startedAt in Self.words(url, startedAt) }

        let done = await p.forget(from: t0.addingTimeInterval(1.5))
        XCTAssertEqual(done, NoteStore.Forgotten())
        XCTAssertEqual(WavFile.duration(of: spool.wav(before.id)), 3, accuracy: 0.001)
        XCTAssertEqual(WavFile.duration(of: spool.wav(across.id)), 1.5, accuracy: 0.001)
        XCTAssertEqual(spool.load(across.id)?.speechEnd ?? 0, 1.5, accuracy: 0.001)
        XCTAssertNil(spool.load(after.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.wav(after.id).path))

        await p.recover()
        await p.waitUntilIdle()
        let notes = NoteStore(root: settings.conversationsURL).conversations()
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.last?.lines.map(\.text), ["Budget talk for March and"], "1.5 s of audio: five words")
        XCTAssertEqual(spool.pending(), [])
    }

    /// The conversation being transcribed: its file is replaced by the cut one (never truncated under the
    /// reader), and the note leaves out the words from after the cut.
    func testTheConversationBeingTranscribedIsCutWhenItsWordsComeBack() async throws {
        let spool = Spool()
        let e = try conversation(spool, at: 0, seconds: 3)
        let inside = Flag(), release = Flag()
        let p = Processor(spool: spool, settings: settings)
        await p.useTranscriber { url, startedAt in
            // Read "the whole file" first, like the engine, then take a while.
            let words = Self.words(url, startedAt)
            inside.set()
            while !release.isSet { try await Task.sleep(nanoseconds: 5_000_000) }
            return words
        }
        await p.enqueue(e.id)
        while !inside.isSet { try await Task.sleep(nanoseconds: 5_000_000) }

        let done = await p.forget(from: t0.addingTimeInterval(1.0))
        XCTAssertEqual(done.changed, 0)
        XCTAssertEqual(WavFile.duration(of: spool.wav(e.id)), 1.0, accuracy: 0.001, "the file on disk is cut at once")
        XCTAssertEqual(spool.load(e.id)?.speechEnd ?? 0, 1.0, accuracy: 0.001)
        release.set()
        await p.waitUntilIdle()

        let note = try XCTUnwrap(NoteStore(root: settings.conversationsURL).conversations().first)
        XCTAssertEqual(note.lines.map(\.text), ["Budget talk for March"], "words from 1.0 s on are left out")
        let side = try JSONDecoder().decode(
            NoteWriter.Sidecar.self, from: Data(contentsOf: note.url.deletingPathExtension().appendingPathExtension("json")))
        XCTAssertFalse(side.text.contains("secret"))
        XCTAssertEqual(spool.pending(), [])
    }

    /// Deleted whole while it was being transcribed: no note at all.
    func testAConversationDeletedWhileTranscribedWritesNoNote() async throws {
        let spool = Spool()
        let e = try conversation(spool, at: 0, seconds: 3)
        let inside = Flag(), release = Flag()
        let p = Processor(spool: spool, settings: settings)
        await p.useTranscriber { url, startedAt in
            let words = Self.words(url, startedAt)
            inside.set()
            while !release.isSet { try await Task.sleep(nanoseconds: 5_000_000) }
            return words
        }
        await p.enqueue(e.id)
        while !inside.isSet { try await Task.sleep(nanoseconds: 5_000_000) }
        _ = await p.forget(from: t0.addingTimeInterval(-5))
        XCTAssertNil(spool.load(e.id))
        release.set()
        await p.waitUntilIdle()
        XCTAssertEqual(NoteStore(root: settings.conversationsURL).conversations().count, 0)
        XCTAssertEqual(spool.pending(), [])
    }

    /// Conversations that failed three times keep their audio in Spool/failed: the same rule applies there.
    func testFailedConversationsAreCutOrDroppedToo() async throws {
        let spool = Spool()
        let across = try conversation(spool, at: 0, seconds: 3)
        let after = try conversation(spool, at: 10, seconds: 3)
        spool.fail(across.id)
        spool.fail(after.id)
        let failed = Spool(dir: spool.failedDir(), create: false)
        let p = Processor(spool: spool, settings: settings)
        _ = await p.forget(from: t0.addingTimeInterval(2))
        XCTAssertEqual(WavFile.duration(of: failed.wav(across.id)), 2, accuracy: 0.001)
        XCTAssertEqual(failed.load(across.id)?.speechEnd ?? 0, 2, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.wav(after.id).path))
        XCTAssertNil(failed.load(after.id))
        XCTAssertEqual(spool.failedCount(), 1)
    }

    /// Notes already written go through `NoteStore.forget`.
    func testWrittenNotesAreCutToo() async throws {
        let spool = Spool()
        let e = try conversation(spool, at: 0, seconds: 3)
        let p = Processor(spool: spool, settings: settings)
        await p.useTranscriber { url, startedAt in Self.words(url, startedAt) }
        await p.enqueue(e.id)
        await p.waitUntilIdle()
        let done = await p.forget(from: t0.addingTimeInterval(2.0))
        XCTAssertEqual(done.trimmed, 1)
        let note = try XCTUnwrap(NoteStore(root: settings.conversationsURL).conversations().first)
        XCTAssertEqual(note.lines.map(\.text), ["Budget talk for March"], "cut a second early: 1.0 s")
    }

    /// The words list is applied when the note is written.
    func testWordsListAppliesToNewNotes() async throws {
        let spool = Spool()
        let e = try conversation(spool, at: 0, seconds: 3)
        var s = settings
        s.words = [WordFix(heard: "budget", write: "Budgie"), WordFix(heard: "secret plan", write: "surprise")]
        let p = Processor(spool: spool, settings: s)
        await p.useTranscriber { url, startedAt in Self.words(url, startedAt) }
        await p.enqueue(e.id)
        await p.waitUntilIdle()
        let note = try XCTUnwrap(NoteStore(root: settings.conversationsURL).conversations().first)
        XCTAssertEqual(note.lines.map(\.text), ["Budgie talk for March and the surprise here now"])
        XCTAssertTrue(note.url.lastPathComponent.contains("Budgie talk for March"), note.url.lastPathComponent)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.withLock { on = true } }
        var isSet: Bool { lock.withLock { on } }
    }
}
