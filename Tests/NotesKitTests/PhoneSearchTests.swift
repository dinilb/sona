import XCTest

@testable import NotesKit

/// What the title-or-place search adds to the MCP `search` tool, beyond `SearchIndexTests`: a note listed from the
/// index keeps its likely-media mark, and a search for one speaker's lines lists no notes by title or place.
final class PhoneSearchTests: XCTestCase {
    var dir: URL!
    var root: URL { dir.appendingPathComponent("Conversations", isDirectory: true) }
    var dbURL: URL { dir.appendingPathComponent("support/search.sqlite") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-phone-search-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ day: String, _ stem: String, front: String, line: String) throws {
        let folder = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = """
            ---
            title: "\(stem.dropFirst(6))"
            date: \(day)
            start: "\(stem.prefix(5).replacingOccurrences(of: "-", with: ":")):00"
            end: "\(stem.prefix(5).replacingOccurrences(of: "-", with: ":")):59"
            duration: 59s
            speakers: ["Speaker 1"]
            \(front)
            ---

            # \(stem.dropFirst(6))

            [00:00] Speaker 1: \(line)

            """
        try text.write(to: folder.appendingPathComponent(stem + ".md"), atomically: true, encoding: .utf8)
    }

    func call(_ server: MCPServer, _ args: String) throws -> String {
        try XCTUnwrap(server.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":"# + args + "}}"))
    }

    func testANoteListedFromTheIndexKeepsItsMediaMark() throws {
        try write("2026-11-01", "20-00 Podcast about budgets", front: "media: true\nmedia_reason: \"played on this Mac\"",
                  line: "Welcome back to the show.")
        for store in [NoteStore(root: root, indexURL: dbURL), NoteStore(root: root)] {
            let found = store.notesMatching("podcast")
            XCTAssertEqual(found.map(\.media), ["played on this Mac"])
            let reply = try call(MCPServer(store: store), #"{"query":"podcast"}"#)
            XCTAssertTrue(reply.contains("| (likely media: played on this Mac)"), reply)
        }
    }

    func testASpeakerSearchListsNoNotesByTitleOrPlace() throws {
        try write("2026-11-02", "09-00 Main St walk", front: "source: \"iPhone\"\nplace: \"4 Main St\"",
                  line: "Walking down Main St now.")
        let server = MCPServer(store: NoteStore(root: root, indexURL: dbURL))
        let all = try call(server, #"{"query":"Main St"}"#)
        XCTAssertTrue(all.contains(#"1 conversation(s) with \"Main St\" in the title or place:"#), all)
        let bySpeaker = try call(server, #"{"query":"Main St","speaker":"Speaker 1"}"#)
        XCTAssertFalse(bySpeaker.contains("in the title or place"), bySpeaker)
        XCTAssertTrue(bySpeaker.contains("1 matching line(s):"), bySpeaker)
    }
}
