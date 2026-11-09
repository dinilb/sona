import XCTest

@testable import NotesKit

/// The text rules of dictation: the space in front of a paste, and the latest words that fit the pill's line.
final class DictationTextTests: XCTestCase {
    private func space(_ before: Character?, recently: Bool = false) -> Bool {
        DictationText.leadingSpace(before: before, sameAppRecently: recently)
    }

    /// "...opened the lid.Yeah" and "Pubbergy" + "Yeah": a letter, a full stop, a comma or a closing mark before the
    /// caret all need a space.
    func testSpaceAfterWordsAndPunctuation() {
        for c: Character in ["d", "Z", "7", ".", ",", "!", "?", ":", ")", "”", "’", "»", "é", "👍"] {
            XCTAssertTrue(space(c), "after \(c)")
        }
    }

    func testNoSpaceAfterWhitespace() {
        for c: Character in [" ", "\n", "\t", "\u{00A0}", "\r\n"] {
            XCTAssertFalse(space(c), "after \(c.unicodeScalars.map(\.value))")
        }
    }

    func testNoSpaceAfterAnOpeningBracketOrQuote() {
        for c: Character in ["(", "[", "{", "<", "\"", "'", "“", "‘", "«", "‹", "„", "（", "「"] {
            XCTAssertFalse(space(c), "after \(c)")
        }
    }

    /// When the field can say what's before the caret, that alone decides; the fallback is only for when it can't.
    func testACharacterBeforeTheCaretOverridesTheFallback() {
        XCTAssertFalse(space(" ", recently: true))
        XCTAssertFalse(space("(", recently: true))
        XCTAssertTrue(space("a", recently: false))
        XCTAssertTrue(space(".", recently: false))
    }

    func testWhenTheFieldCantSayItFollowsALastPasteToTheSameApp() {
        XCTAssertTrue(space(nil, recently: true))
        XCTAssertFalse(space(nil, recently: false))
    }

    // MARK: a text box to paste into

    private func target(_ role: String?, editable: Bool = false, settable: Bool = false) -> DictationText.PasteTarget {
        DictationText.pasteTarget(for: .element(role: role, editable: editable, settableText: settable))
    }

    func testTextFieldsTakeAPaste() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertEqual(target(role), .textBox, role)
        }
    }

    /// Web editors and custom fields don't always say AXTextArea: editable, or a text or selection that can be set, will do.
    func testEditableOrSettableElementsTakeAPaste() {
        XCTAssertEqual(target("AXGroup", editable: true), .textBox)
        XCTAssertEqual(target("AXWebArea", settable: true), .textBox)
        XCTAssertEqual(target(nil, editable: true), .textBox)
    }

    func testButtonsAndListsDoNotEvenWhenTheirValueCanBeSet() {
        for role in ["AXButton", "AXCheckBox", "AXList", "AXOutline", "AXMenuItem", "AXPopUpButton", "AXSlider"] {
            XCTAssertEqual(target(role), .noTextBox, role)
            XCTAssertEqual(target(role, settable: true), .noTextBox, role + " with a value that can be set")
        }
    }

    func testNothingFocusedIsNoTextBox() {
        XCTAssertEqual(DictationText.pasteTarget(for: .nothing), .noTextBox)
    }

    /// When it can't be told, the paste is still tried and the words stay on the clipboard.
    func testWhenItCantBeToldThePasteIsTried() {
        XCTAssertEqual(DictationText.pasteTarget(for: .unreadable), .unknown)
        XCTAssertEqual(target(nil), .unknown)
        XCTAssertEqual(target("AXGroup"), .unknown)
        XCTAssertEqual(target("AXWebArea"), .unknown)
        XCTAssertEqual(target("AXUnknown"), .unknown)
        // Chromium and Electron apps that hide their text can answer with the window.
        XCTAssertEqual(target("AXWindow"), .unknown)
        XCTAssertEqual(target("AXApplication"), .unknown)
        XCTAssertEqual(target("AXCell"), .unknown, "a selected spreadsheet cell takes a paste")
    }

    // MARK: the pill's line

    /// A pretend pill that holds 20 characters.
    private let twenty: (String) -> Bool = { $0.count <= 20 }

    func testShortTextIsShownWhole() {
        XCTAssertEqual(DictationText.tail(of: "Yeah, it shows up", fits: twenty), "Yeah, it shows up")
        XCTAssertEqual(DictationText.tail(of: "", fits: twenty), "")
    }

    func testLongTextKeepsTheLatestWordsCutAtAWordWithAnEllipsis() {
        let text = "one two three four five six seven"
        // "…four five six seven" is 20 characters, "…three four five six seven" is 26.
        XCTAssertEqual(DictationText.tail(of: text, fits: twenty), "…four five six seven")
    }

    /// Talking on: the line always fits, always ends with the newest word, and the oldest words fall off the front.
    func testTheLineFollowsTheNewestWord() {
        var words: [String] = []
        var shown = ""
        for word in "I like Fortnite Pubbergy and then we went to the shops and bought some bread".split(separator: " ") {
            words.append(String(word))
            shown = DictationText.tail(of: words.joined(separator: " "), fits: twenty)
            XCTAssertTrue(twenty(shown), shown)
            XCTAssertTrue(shown.hasSuffix(String(word)), "the newest word is always last: \(shown)")
        }
        XCTAssertEqual(shown, "…bought some bread")
    }

    func testAWordWiderThanTheLineIsStillKept() {
        XCTAssertEqual(DictationText.tail(of: "see https://example.com/a-very-long-address", fits: twenty), "…https://example.com/a-very-long-address")
    }

    func testOneUnbreakableWordIsLeftAlone() {
        let word = String(repeating: "a", count: 40)
        XCTAssertEqual(DictationText.tail(of: word, fits: twenty), word)
    }

    func testWordCountIgnoresSpacing() {
        XCTAssertEqual(DictationText.wordCount(""), 0)
        XCTAssertEqual(DictationText.wordCount("  one   two\nthree "), 3)
    }

    // MARK: the end of a hold

    /// Quiet before the release skips the tail; a word still going at the very end doesn't, even when the whole
    /// stretch averages under the floor.
    func testOnlyAQuietEndSkipsTheTail() {
        let floor: Float = 0.003
        let silence = [Float](repeating: 0, count: 1_600)
        let room = (0..<1_600).map { Float(sin(Double($0) * 0.7)) * 0.001 }
        XCTAssertTrue(DictationText.endsQuiet(silence, floor: floor))
        XCTAssertTrue(DictationText.endsQuiet(room, floor: floor), "a quiet room")
        let speech = (0..<1_600).map { Float(sin(Double($0) * 0.2)) * 0.05 }
        XCTAssertFalse(DictationText.endsQuiet(speech, floor: floor))
        // The last 20 ms start a word: 0.006 RMS there, about 0.0027 over all 100 ms.
        let starting = silence.prefix(1_280) + (0..<320).map { Float(sin(Double($0) * 0.3)) * 0.0085 }
        XCTAssertFalse(DictationText.endsQuiet(Array(starting), floor: floor))
        XCTAssertFalse(DictationText.endsQuiet([], floor: floor), "no audio isn't quiet")
    }

    // MARK: the clipboard around a paste

    func testPasswordManagersMarkersAreKeptAndTheirSecretsNeverComeBack() {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"] {
            XCTAssertTrue(DictationText.isClipboardMarker(marker), marker)
        }
        XCTAssertFalse(DictationText.isClipboardMarker("public.utf8-plain-text"))
        XCTAssertTrue(DictationText.isSecret(clipboardTypes: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(DictationText.isSecret(clipboardTypes: ["public.utf8-plain-text", "com.agilebits.onepassword"]))
        XCTAssertFalse(DictationText.isSecret(clipboardTypes: ["public.utf8-plain-text", "org.nspasteboard.TransientType"]))
        XCTAssertFalse(DictationText.isSecret(clipboardTypes: []))
    }
}
