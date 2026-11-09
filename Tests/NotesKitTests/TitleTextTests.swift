import XCTest

@testable import NotesKit

/// The shared half of AI titles: the excerpt the model sees, the check on what it says back, and the Mac's titles
/// file the iPhone reads.
final class TitleTextTests: XCTestCase {
    func note(_ texts: [String]) -> ConversationNote {
        ConversationNote(
            id: "2026-11-07/09-30 Hello", url: URL(fileURLWithPath: "/tmp/x.md"), title: "Hello", date: "2026-11-07",
            start: "09:30", end: "09:40", duration: "10:00", speakers: ["Speaker 1", "Speaker 2"],
            lines: texts.enumerated().map {
                NoteLine(offset: Double($0.offset), clock: "00:0\($0.offset)", speaker: "Speaker \($0.offset % 2 + 1)", text: $0.element)
            })
    }

    // MARK: The prompt and the excerpt

    func testThePromptHasTheWordsWithoutTimesOrSpeakers() throws {
        let prompt = try XCTUnwrap(TitleText.prompt(for: note(["Let's go over the budget.", "  ", "Sure, March first."])))
        XCTAssertTrue(prompt.hasPrefix("Title this transcript in 2 to 6 words."))
        XCTAssertTrue(prompt.hasSuffix("Let's go over the budget.\nSure, March first."))
        XCTAssertFalse(prompt.contains("Speaker"))
        XCTAssertFalse(prompt.contains("00:0"))
    }

    func testANoteWithNoWordsHasNoPrompt() {
        XCTAssertNil(TitleText.prompt(for: note([])))
        XCTAssertNil(TitleText.prompt(for: note(["", "   "])))
    }

    func testAShortTranscriptIsSentWhole() {
        let text = "one two three"
        XCTAssertEqual(TitleText.excerpt(text, budget: 100), text)
    }

    func testALongTranscriptSendsItsStartMiddleAndEnd() {
        // Numbered words, so where each part came from shows.
        let text = (0..<5_000).map { "w\($0)" }.joined(separator: " ")
        let excerpt = TitleText.excerpt(text, budget: 6_000)
        let parts = excerpt.components(separatedBy: "\n...\n")
        XCTAssertEqual(parts.count, 3)
        XCTAssertLessThanOrEqual(excerpt.count, 6_000 + 10)
        XCTAssertTrue(parts[0].hasPrefix("w0 w1 w2"))
        XCTAssertGreaterThan(parts[0].count, 2_900)  // about half
        XCTAssertGreaterThan(parts[1].count, 1_400)  // about a quarter
        XCTAssertGreaterThan(parts[2].count, 1_400)
        XCTAssertTrue(parts[2].hasSuffix("w4999"))
        // The middle is from the middle.
        let middle = parts[1].split(separator: " ").compactMap { Int($0.dropFirst()) }
        XCTAssertFalse(middle.isEmpty)
        XCTAssertTrue((2_000...3_000).contains(middle[middle.count / 2]))
        // No word cut in half: every piece is a whole "w<number>".
        for part in parts {
            for word in part.split(separator: " ") {
                XCTAssertTrue(word.hasPrefix("w") && Int(word.dropFirst()) != nil, "cut word \(word)")
            }
        }
    }

    func testAnExcerptWithoutSpacesIsStillCut() {
        let text = String(repeating: "x", count: 10_000)
        XCTAssertEqual(TitleText.excerpt(text, budget: 6_000).replacingOccurrences(of: "\n...\n", with: "").count, 6_000)
    }

    // MARK: The check on the reply

    func testATitleComesBackClean() {
        XCTAssertEqual(TitleText.check("Pitch practice with Sam"), "Pitch practice with Sam")
        XCTAssertEqual(TitleText.check("\"Budget for the March launch.\""), "Budget for the March launch")
        XCTAssertEqual(TitleText.check("Title: Weekly sync"), "Weekly sync")
        XCTAssertEqual(TitleText.check("**Title:** Weekly sync"), "Weekly sync")
        XCTAssertEqual(TitleText.check("  Gym   plan\nand more on the next line"), "Gym plan")
        XCTAssertEqual(TitleText.check("\n\n# Rent and bills\n"), "Rent and bills")
    }

    func testRefusalsAndRamblingAreNotTitles() {
        XCTAssertNil(TitleText.check(""))
        XCTAssertNil(TitleText.check("   \n "))
        XCTAssertNil(TitleText.check("\"\""))
        XCTAssertNil(TitleText.check("Sorry, I can't help with that."))
        XCTAssertNil(TitleText.check("I cannot help with this request"))
        XCTAssertNil(TitleText.check("As an AI, I"))
        XCTAssertNil(TitleText.check("The transcript is about a meeting"))
        XCTAssertNil(TitleText.check("This is a long rambling reply that goes on and on about the whole note"))
        XCTAssertNil(TitleText.check(String(repeating: "Antidisestablishment", count: 4)))
    }

    func testOnlyACleanTitleIsAcceptableFromTheMac() {
        XCTAssertTrue(TitleText.isAcceptable("Pitch practice with Sam"))
        XCTAssertFalse(TitleText.isAcceptable("\"Quoted\""))
        XCTAssertFalse(TitleText.isAcceptable("Sorry, I can't"))
        XCTAssertFalse(TitleText.isAcceptable(""))
    }

    // MARK: The Mac's titles file

    func testTheTitlesFileRoundTripsAndSitsBesideConversations() throws {
        let file = TitlesFile(titles: ["09-30 Hello there": "Morning standup"])
        let data = try file.encoded()
        XCTAssertEqual(TitlesFile.decode(data), file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual((json["titles"] as? [String: String])?["09-30 Hello there"], "Morning standup")

        let conversations = URL(fileURLWithPath: "/x/Sona/Conversations", isDirectory: true)
        XCTAssertEqual(TitlesFile.url(forConversations: conversations, day: "2026-11-07").path, "/x/Sona/Titles/2026-11-07.json")
    }

    func testAnotherVersionIsNotRead() {
        XCTAssertNil(TitlesFile.decode(Data(#"{"version": 2, "titles": {}}"#.utf8)))
        XCTAssertNil(TitlesFile.decode(Data("not json".utf8)))
    }
}
