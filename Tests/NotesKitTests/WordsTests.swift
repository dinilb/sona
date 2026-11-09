import XCTest

@testable import NotesKit

/// "Words it should know": whole words, any case, punctuation left alone, a sentence's capital kept.
final class WordsTests: XCTestCase {
    let fixer = WordFixer([
        WordFix(heard: "Sonar, Sonnar, Sonor", write: "Sona"),
        WordFix(heard: "whisperflow, whisper flow", write: "Wispr Flow"),
        WordFix(heard: "gonna", write: "going to"),
        WordFix(heard: "eye phone", write: "iPhone"),
    ])

    func testWholeWordsInAnyCase() {
        XCTAssertEqual(fixer.apply("I use sonar and SONAR and Sonor daily"), "I use Sona and Sona and Sona daily")
    }

    func testOnlyWholeWords() {
        XCTAssertEqual(fixer.apply("sonars exsonar sonarland sonar2 sonar"), "sonars exsonar sonarland sonar2 Sona")
    }

    func testPunctuationStays() {
        XCTAssertEqual(fixer.apply("Sonar, really? (sonar) sonar's \"sonar\" sonar."), "Sona, really? (Sona) Sona's \"Sona\" Sona.")
    }

    /// An apostrophe or hyphen inside a word doesn't end it: "won" → "Juan" never makes "Juan't" or "Juan-ton". A
    /// possessive 's may follow, and quotes or a dash around a word are still punctuation.
    func testContractionsAndHyphenatedWordsStayWhole() {
        let f = WordFixer([WordFix(heard: "won", write: "Juan"), WordFix(heard: "sonar", write: "Sona")])
        XCTAssertEqual(f.apply("I won't, she won’t, we won."), "I won't, she won’t, we Juan.")
        XCTAssertEqual(f.apply("Won-ton soup, a re-won game, Sonar-like, x-sonar"), "Won-ton soup, a re-won game, Sonar-like, x-sonar")
        XCTAssertEqual(f.apply("o'won d’won"), "o'won d’won")
        XCTAssertEqual(f.apply("won's sonar’s 'won' won- -won"), "Juan's Sona’s 'Juan' Juan- -Juan")
        XCTAssertEqual(f.apply([Word(word: "won't", start: 0, end: 0.3, speaker: "Speaker 1")]).map(\.word), ["won't"])
    }

    /// A capital at a sentence start stays; otherwise the written form is used exactly as typed.
    func testFirstLetterCapitalIsKept() {
        XCTAssertEqual(fixer.apply("Gonna go. I'm gonna go."), "Going to go. I'm going to go.")
        XCTAssertEqual(fixer.apply("sonar is here"), "Sona is here", "a name keeps its own capital")
        XCTAssertEqual(fixer.apply("Eye phone is fine, my eye phone"), "iPhone is fine, my iPhone", "mixed case is never changed")
    }

    func testPhrasesAndOneWordToTwo() {
        XCTAssertEqual(fixer.apply("I use Whisper  flow and whisperflow."), "I use Wispr Flow and Wispr Flow.")
        // The longer spelling wins over a shorter one it starts with.
        let both = WordFixer([WordFix(heard: "whisper", write: "Shh"), WordFix(heard: "whisper flow", write: "Wispr Flow")])
        XCTAssertEqual(both.apply("whisper flow, a whisper"), "Wispr Flow, a Shh")
    }

    func testRegexCharactersAreLiteral() {
        let f = WordFixer([WordFix(heard: "c++", write: "C plus plus"), WordFix(heard: "a.b", write: "AB")])
        XCTAssertEqual(f.apply("I like c++ a lot"), "I like C plus plus a lot")
        XCTAssertEqual(f.apply("axb a.b"), "axb AB")
    }

    /// Empty or half-typed lines do nothing; the first line for a spelling wins.
    func testEmptyLinesDoNothing() {
        let f = WordFixer([WordFix(heard: "", write: "x"), WordFix(heard: "sonar", write: " "), WordFix(heard: " , ", write: "y")])
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(f.apply("sonar"), "sonar")
        let first = WordFixer([WordFix(heard: "sonar", write: "One"), WordFix(heard: "Sonar", write: "Two")])
        XCTAssertEqual(first.apply("sonar"), "One")
    }

    /// On a note's words: replaced in place, and a phrase across words becomes one word spanning their times.
    func testWordsKeepTheirTimesAndSpeakers() {
        let words = [
            Word(word: "Hey", start: 0, end: 0.3, speaker: "Speaker 1"),
            Word(word: "sonar,", start: 0.4, end: 0.8, speaker: "Speaker 1"),
            Word(word: "use", start: 1.0, end: 1.2, speaker: "Speaker 2"),
            Word(word: "whisper", start: 1.3, end: 1.6, speaker: "Speaker 2"),
            Word(word: "flow.", start: 1.7, end: 2.0, speaker: "Speaker 2"),
        ]
        let fixed = fixer.apply(words)
        XCTAssertEqual(fixed.map(\.word), ["Hey", "Sona,", "use", "Wispr Flow."])
        XCTAssertEqual(fixed[3].start, 1.3)
        XCTAssertEqual(fixed[3].end, 2.0)
        XCTAssertEqual(fixed[3].speaker, "Speaker 2")
        XCTAssertEqual(fixed[1].start, 0.4)
        XCTAssertEqual(WordFixer.none.apply(words), words)
    }

    /// New notes: the lines, the title and the .json all say the same.
    func testNoteLinesTitleAndSidecarAgree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sona-words-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let said = ["Hey", "sonar,", "we", "should", "use", "whisper", "flow."]
        let words = said.enumerated().map { Word(word: $1, start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.3, speaker: "Speaker 1") }
        let t = Transcript(
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), duration: 3, text: said.joined(separator: " "), words: words,
            turns: [Turn(speaker: "Speaker 1", start: 0, end: 3)], asrSeconds: 0.1, diarizationSeconds: 0.1, model: "test")
        let url = try NoteWriter.write(t, to: root, words: fixer)
        let md = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(md.contains("Speaker 1: Hey Sona, we should use Wispr Flow."), md)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(" Sona we should use Wispr Flow.md"), url.lastPathComponent)
        XCTAssertFalse(md.lowercased().contains("sonar"))
        let side = try JSONDecoder().decode(
            NoteWriter.Sidecar.self, from: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
        XCTAssertEqual(side.words.map(\.word).joined(separator: " "), "Hey Sona, we should use Wispr Flow.")
        XCTAssertEqual(side.text, "Hey Sona, we should use Wispr Flow.")
        XCTAssertEqual(try NoteStore(root: root).read(url: url).lines.map(\.text), ["Hey Sona, we should use Wispr Flow."])
    }

    func testSettingsKeepTheList() throws {
        var s = Settings()
        s.words = [WordFix(heard: "Sonar, Sonnar", write: "Sona")]
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.words, s.words)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).words, [])
    }
}
