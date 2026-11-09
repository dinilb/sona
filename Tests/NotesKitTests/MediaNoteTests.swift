import XCTest

@testable import NotesKit

/// A note marked as likely media reads back as such, and the MCP tools say so and keep its lines out of `recent`.
final class MediaMCPTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sona-media-mcp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func transcript(_ said: [String], start: Date) -> Transcript {
        let words = said.enumerated().map { Word(word: $1, start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25, speaker: "Speaker 1") }
        return Transcript(
            startedAt: start, duration: 3, text: said.joined(separator: " "), words: words,
            turns: [Turn(speaker: "Speaker 1", start: 0, end: 3)], asrSeconds: 0.01, diarizationSeconds: 0.01, model: "test")
    }

    func testMediaMarkedInMCP() throws {
        let now = Date()
        _ = try NoteWriter.write(
            transcript(["Welcome", "back", "to", "the", "show."], start: now.addingTimeInterval(-900)), to: root,
            media: "this Mac was playing audio during 97% of the speech")
        _ = try NoteWriter.write(transcript(["Let's", "ship", "it", "on", "Friday."], start: now.addingTimeInterval(-300)), to: root)

        let store = NoteStore(root: root)
        let notes = store.conversations()
        XCTAssertEqual(notes.map { $0.media != nil }, [true, false])
        XCTAssertEqual(notes[0].media, "this Mac was playing audio during 97% of the speech")

        let server = MCPServer(store: store)
        let list = try server.listConversations([:])
        XCTAssertTrue(list.contains("| (likely media: this Mac was playing audio during 97% of the speech)"), list)
        XCTAssertEqual(list.components(separatedBy: "likely media").count, 2, list)  // only the one

        let recent = server.recent(["minutes": 60])
        // Marked, never hidden: a wrong mark must not lose a real conversation.
        XCTAssertTrue(recent.contains("(likely media: "), recent)
        XCTAssertTrue(recent.contains("Speaker 1: Welcome back to the show."), recent)
        XCTAssertTrue(recent.contains("Speaker 1: Let's ship it on Friday."), recent)

        // Still readable on purpose, and a speaker rename keeps the mark.
        XCTAssertTrue(try server.readConversation(["id": notes[0].id]).contains("Welcome back to the show"))
        _ = try store.renameSpeaker(in: notes[0].id, from: "Speaker 1", to: "Host")
        XCTAssertNotNil(try store.read(notes[0].id).media)
    }
}
