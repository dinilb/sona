import Foundation
import NotesKit
import Testing
@testable import Sona

/// The iPhone's half of AI titles that runs without the model: the Mac's titles folded into notes with none, and
/// which notes a foreground tries again.
struct V1TitlesTests {
    let root = makeTempDir()
    var conversations: URL { root.appendingPathComponent("Conversations", isDirectory: true) }
    let today = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-11-02 in most zones
    var day: String { NoteWriter.timeString(today, "yyyy-MM-dd") }

    /// A note as the iPhone writes one: front matter, the heading and a line.
    @discardableResult
    func note(_ stem: String, day: String? = nil, aiTitle: String? = nil) throws -> URL {
        let dir = conversations.appendingPathComponent(day ?? self.day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(stem).md")
        var front = "title: \"Hello there\"\ndate: \(day ?? self.day)\nstart: \"09:30\"\n"
        if let aiTitle { front += "ai_title: \"\(aiTitle)\"\n" }
        try "---\n\(front)---\n\n# Hello there\n\n[00:00] Speaker 1: Hello there.\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func titles(_ titles: [String: String], day: String? = nil) throws {
        let url = TitlesFile.url(forConversations: conversations, day: day ?? self.day)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TitlesFile(titles: titles).encoded().write(to: url)
    }

    func aiTitle(_ url: URL) throws -> String? {
        try NoteStore(root: conversations).readHeader(url: url).aiTitle
    }

    @Test func theMacsTitleIsFoldedIntoANoteWithNone() throws {
        let plain = try note("09-30 Hello there")
        let titled = try note("10-00 Hello there", aiTitle: "Its own title")
        try titles(["09-30 Hello there": "Budget for March", "10-00 Hello there": "The Mac's other idea"])

        #expect(PhoneTitles.foldMacTitles(conversations: conversations, today: today) == 1)

        #expect(try aiTitle(plain) == "Budget for March")
        #expect(try aiTitle(titled) == "Its own title")  // the iPhone's own title wins
        // Only the front matter changed: the first-words title, heading and file name stay.
        let text = try String(contentsOf: plain, encoding: .utf8)
        #expect(text.contains("title: \"Hello there\""))
        #expect(text.contains("# Hello there"))
        // Folding again changes nothing.
        #expect(PhoneTitles.foldMacTitles(conversations: conversations, today: today) == 0)
    }

    @Test func aTitleThatIsNotOneOrAKeyThatIsAPathIsSkipped() throws {
        let plain = try note("09-30 Hello there")
        try titles([
            "09-30 Hello there": "Sorry, I can't help with that.",
            "../09-30 Hello there": "Escape",
            ".hidden": "Hidden",
            "09-45 Not here": "No such note",
        ])
        #expect(PhoneTitles.foldMacTitles(conversations: conversations, today: today) == 0)
        #expect(try aiTitle(plain) == nil)
    }

    @Test func oldDaysAreLeftAlone() throws {
        let oldDay = NoteWriter.timeString(today.addingTimeInterval(-Double(PhoneTitles.foldDays + 2) * 86_400), "yyyy-MM-dd")
        let old = try note("09-30 Hello there", day: oldDay)
        try titles(["09-30 Hello there": "Old title"], day: oldDay)
        #expect(PhoneTitles.foldMacTitles(conversations: conversations, today: today) == 0)
        #expect(try aiTitle(old) == nil)
    }

    @Test func noTitlesFolderIsNothingToDo() {
        #expect(PhoneTitles.foldMacTitles(conversations: conversations, today: today) == 0)
    }

    @Test func aForegroundTriesEachRecentUntitledNoteOnce() throws {
        let defaults = UserDefaults(suiteName: "sona-titles-\(UUID().uuidString)")!
        let untitled = try note("09-30 Hello there")
        try note("10-00 Hello there", aiTitle: "Has one")
        let oldDay = NoteWriter.timeString(today.addingTimeInterval(-Double(PhoneTitles.retryDays + 2) * 86_400), "yyyy-MM-dd")
        try note("09-30 Hello there", day: oldDay)

        let first = PhoneTitles.untitled(in: conversations, today: today, defaults: defaults)
        #expect(first.map(\.lastPathComponent) == [untitled.lastPathComponent])

        PhoneTitles.markRetried(untitled, defaults: defaults)
        #expect(PhoneTitles.untitled(in: conversations, today: today, defaults: defaults).isEmpty)
    }
}
