import XCTest

@testable import NotesKit

/// The header-only listing (the iPhone's notes list) says the same about each note as reading it whole, without
/// reading the transcript.
final class NoteHeaderTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sona-headers-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func transcript(_ said: [String], speakers: [String], start: Date) -> Transcript {
        let words = said.enumerated().map {
            Word(word: $1, start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25, speaker: speakers[$0 % speakers.count])
        }
        return Transcript(
            startedAt: start, duration: Double(said.count) * 0.3, text: said.joined(separator: " "), words: words,
            turns: [], asrSeconds: 0.01, diarizationSeconds: 0.01, model: "test")
    }

    func testHeadersMatchTheWholeNotes() throws {
        let now = Date()
        // A long one: its header is still read from the first few KB.
        let long = (0..<3000).map { "word\($0)" }
        _ = try NoteWriter.write(transcript(long, speakers: ["Speaker 1", "Speaker 2"], start: now.addingTimeInterval(-3600)), to: root, source: "Apple Watch")
        let phone = try NoteWriter.write(transcript(["Remind", "me", "to", "call", "\"Mum\"."], speakers: ["Speaker 1"], start: now.addingTimeInterval(-60)), to: root, source: "iPhone")
        // What the iPhone adds later: its title, its place, Keep audio.
        try NoteFrontMatter.update(fileAt: phone, set: [
            "ai_title": "Call \"Mum\"", "place": "4 Main St", "geo": "-27.4698,153.0251", "place_end": "10 Queen St",
            "geo_end": "-27.4710,153.0234", "keep_audio": "true",
        ])

        let store = NoteStore(root: root)
        let whole = store.conversations()
        let headers = store.headers()
        XCTAssertEqual(headers.count, 2)
        for (h, w) in zip(headers, whole) {
            XCTAssertEqual(h.id, w.id)
            XCTAssertEqual(h.title, w.title)
            XCTAssertEqual(h.date, w.date)
            XCTAssertEqual(h.start, w.start)
            XCTAssertEqual(h.duration, w.duration)
            XCTAssertEqual(h.speakers, w.speakers)
            XCTAssertEqual(h.source, w.source)
            XCTAssertEqual(h.startedAt, w.startedAt)
            XCTAssertEqual(h.aiTitle, w.aiTitle)
            XCTAssertEqual(h.displayTitle, w.displayTitle)
            XCTAssertEqual(h.place, w.place)
            XCTAssertEqual(h.geo, w.geo)
            XCTAssertEqual(h.placeEnd, w.placeEnd)
            XCTAssertEqual(h.geoEnd, w.geoEnd)
            XCTAssertEqual(h.keepAudio, w.keepAudio)
            XCTAssertTrue(h.lines.isEmpty)
            XCTAssertFalse(w.lines.isEmpty)
        }
        XCTAssertEqual(headers.map(\.source), ["Apple Watch", "iPhone"])
        XCTAssertEqual(headers.map(\.displayTitle), [headers[0].title, "Call \"Mum\""])
        XCTAssertEqual(headers.map(\.place), [nil, "4 Main St"])
        XCTAssertEqual(headers.map(\.keepAudio), [false, true])
    }

    func testANoteWithoutFrontMatterStillLists() throws {
        let day = root.appendingPathComponent("2026-11-03", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data("[00:00] Speaker 1: Just words.\n".utf8).write(to: day.appendingPathComponent("09-00 Plain.md"))
        let headers = NoteStore(root: root).headers()
        XCTAssertEqual(headers.map(\.title), ["09-00 Plain"])
        XCTAssertTrue(headers[0].lines.isEmpty)
    }
}
