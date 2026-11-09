import XCTest

@testable import NotesKit

/// Deleting a note on the iPhone takes the Mac's title for it out of `<root>/Titles/<day>.json`: the title was made
/// from the note's words, and the delete says its text is gone from iCloud.
final class TitlesFileRemoveTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("titles-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    var conversations: URL { root.appendingPathComponent("Conversations", isDirectory: true) }

    func note(_ stem: String, day: String = "2026-11-07") -> URL {
        conversations.appendingPathComponent(day, isDirectory: true).appendingPathComponent("\(stem).md")
    }

    func write(_ titles: [String: String], day: String = "2026-11-07") throws {
        let url = TitlesFile.url(forConversations: conversations, day: day)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TitlesFile(titles: titles).encoded().write(to: url)
    }

    func read(day: String = "2026-11-07") -> TitlesFile? {
        (try? Data(contentsOf: TitlesFile.url(forConversations: conversations, day: day))).flatMap(TitlesFile.decode)
    }

    func testTheDeletedNotesTitleGoesAndTheOthersStay() throws {
        try write(["14-03 Talked to the doctor": "Results discussion", "15-00 Lunch": "Lunch plans"])
        XCTAssertTrue(try TitlesFile.removeTitle(ofNote: note("14-03 Talked to the doctor")))
        XCTAssertEqual(read()?.titles, ["15-00 Lunch": "Lunch plans"])
    }

    func testAFileLeftWithNoTitlesGoes() throws {
        try write(["14-03 Talked to the doctor": "Results discussion"])
        XCTAssertTrue(try TitlesFile.removeTitle(ofNote: note("14-03 Talked to the doctor")))
        let url = TitlesFile.url(forConversations: conversations, day: "2026-11-07")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNothingHappensWithoutAFileOrAnEntry() throws {
        XCTAssertFalse(try TitlesFile.removeTitle(ofNote: note("09-00 Hello")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: TitlesFile.folder(forConversations: conversations).path))

        try write(["15-00 Lunch": "Lunch plans"])
        XCTAssertFalse(try TitlesFile.removeTitle(ofNote: note("09-00 Hello")))
        XCTAssertEqual(read()?.titles, ["15-00 Lunch": "Lunch plans"])
        // Another day's file is never touched.
        XCTAssertFalse(try TitlesFile.removeTitle(ofNote: note("15-00 Lunch", day: "2026-11-06")))
        XCTAssertEqual(read()?.titles, ["15-00 Lunch": "Lunch plans"])
    }

    func testAFileOfAnotherVersionIsLeftAsItIs() throws {
        let url = TitlesFile.url(forConversations: conversations, day: "2026-11-07")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = Data(#"{"version": 2, "titles": {"09-00 Hello": "Greeting"}}"#.utf8)
        try other.write(to: url)
        XCTAssertFalse(try TitlesFile.removeTitle(ofNote: note("09-00 Hello")))
        XCTAssertEqual(try Data(contentsOf: url), other)
    }
}
