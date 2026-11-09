import NotesKit
import XCTest

@testable import SonaEngine

/// The "is this Mac playing the media itself?" decision, with the Core Audio samples injected.
final class PlaybackTests: XCTestCase {
    let playing = Playback.Sample(playing: true, call: false)
    let quiet = Playback.Sample(playing: false, call: false)
    let call = Playback.Sample(playing: true, call: true)

    func tally(_ samples: [Playback.Sample?]) -> Playback.Tally {
        var t = Playback.Tally()
        for s in samples { t.add(speechWith: s) }
        return t
    }

    func testVideoPlayingAllAlongIsMedia() {
        let t = tally(Array(repeating: playing, count: 100))
        XCTAssertEqual(t.fraction, 1)
        XCTAssertEqual(Playback.mediaReason(fraction: t.fraction), "this Mac was playing audio during 100% of the speech")
    }

    func testPeopleTalkingIsNot() {
        XCTAssertEqual(tally(Array(repeating: quiet, count: 50)).fraction, 0)
        XCTAssertNil(Playback.mediaReason(fraction: 0))
    }

    /// A call on speakers plays audio the whole time, but someone's recording too: real people.
    func testCallIsNotMedia() {
        let t = tally(Array(repeating: call, count: 100))
        XCTAssertEqual(t.fraction, 0)
        XCTAssertNil(Playback.mediaReason(fraction: t.fraction))
    }

    /// A song for a bit of a long chat isn't enough: it takes 80% of the speech.
    func testThreshold() {
        let some = tally(Array(repeating: playing, count: 70) + Array(repeating: quiet, count: 30))
        XCTAssertEqual(some.fraction!, 0.7, accuracy: 1e-9)
        XCTAssertNil(Playback.mediaReason(fraction: some.fraction))
        let most = tally(Array(repeating: playing, count: 85) + Array(repeating: quiet, count: 15))
        XCTAssertEqual(Playback.mediaReason(fraction: most.fraction), "this Mac was playing audio during 85% of the speech")
    }

    /// No samples (a file in `simulate`, an old entry) means unknown, never media.
    func testUnknownIsNotMedia() {
        XCTAssertNil(tally([nil, nil]).fraction)
        XCTAssertNil(Playback.mediaReason(fraction: nil))
    }

    /// The real probe runs and answers (whatever this Mac is doing right now), fast.
    func testRealSampleIsCheap() {
        _ = Playback.sample()  // first call connects to the audio server
        let t0 = Date()
        for _ in 0..<20 { _ = Playback.sample() }
        let ms = Date().timeIntervalSince(t0) * 1000 / 20
        print(String(format: "Playback.sample: %.3f ms per call", ms))
        XCTAssertLessThan(ms, 50)
    }
}

/// The spool keeps the fraction; the processor turns a high one into a marked note, never a dropped one.
final class MediaNoteTests: XCTestCase {
    var home: URL!
    var previousHome: String?

    override func setUp() {
        previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sona-media-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SONA_HOME", home.path, 1)
    }

    override func tearDown() {
        if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    func process(playback: Double?) async throws -> String {
        let spool = Spool()
        let started = Date(timeIntervalSince1970: 1_790_000_000 + (playback ?? 0) * 1000)
        var entry = SpoolEntry(id: Spool.newID(for: started), startedAt: started)
        let wav = try WavFile(creating: spool.wav(entry.id))
        try wav.append((0..<48_000).map { Float(sin(Double($0) * 0.05)) * 0.3 })
        try wav.finish()
        entry.speechEnd = 3
        entry.speechSeconds = 3
        entry.closed = true
        entry.playback = playback
        spool.save(entry)
        XCTAssertEqual(spool.load(entry.id)?.playback, playback)

        let settings = Settings(notesFolder: home.appendingPathComponent("Notes").path)
        let processor = Processor(spool: spool, settings: settings)
        await processor.useTranscriber { _, startedAt in
            let said = ["Welcome", "back", "to", "the", "show", "everyone."]
            let words = said.enumerated().map { Word(word: $1, start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25, speaker: "Speaker 1") }
            return Transcript(
                startedAt: startedAt, duration: 3, text: said.joined(separator: " "), words: words,
                turns: [Turn(speaker: "Speaker 1", start: 0, end: 3)], asrSeconds: 0.01, diarizationSeconds: 0.01, model: "test")
        }
        await processor.enqueue(entry.id)
        await processor.waitUntilIdle()
        let written = await processor.written
        let note = try XCTUnwrap(written.first)
        XCTAssertNil(spool.load(entry.id))  // processed, not left behind
        return try String(contentsOf: note, encoding: .utf8)
            + (try String(contentsOf: note.deletingPathExtension().appendingPathExtension("json"), encoding: .utf8))
    }

    func testMediaIsMarkedNotDropped() async throws {
        let text = try await process(playback: 0.93)
        XCTAssertTrue(text.contains("media: true\n"), text)
        XCTAssertTrue(text.contains("media_reason: \"this Mac was playing audio during 93% of the speech\""), text)
        XCTAssertTrue(text.contains("tags: [sona, likely-media]"), text)
        XCTAssertTrue(text.contains("\"media\" : true"), text)
        XCTAssertTrue(text.contains("Welcome back to the show"), text)
    }

    func testTalkIsNotMarked() async throws {
        for playback in [0.2, nil] {
            let text = try await process(playback: playback)
            XCTAssertFalse(text.contains("media"), text)
            XCTAssertTrue(text.contains("tags: [sona]"), text)
        }
    }

    /// Entries written before this field existed still load.
    func testOldEntriesDecode() throws {
        let spool = Spool()
        let json = #"{"attempts":0,"closed":true,"id":"old","speechEnd":2,"speechSeconds":2,"startedAt":"2026-10-27T10:00:00Z"}"#
        try Data(json.utf8).write(to: spool.dir.appendingPathComponent("old.json"))
        XCTAssertNil(try XCTUnwrap(spool.load("old")).playback)
    }
}
