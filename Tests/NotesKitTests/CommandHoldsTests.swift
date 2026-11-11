import XCTest

@testable import NotesKit

final class CommandHoldsTests: XCTestCase {
    func testCoversLinesOverAHold() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let holds = CommandHolds(ranges: [t.addingTimeInterval(10)...t.addingTimeInterval(14)])
        XCTAssertTrue(holds.covers(from: t.addingTimeInterval(11), to: t.addingTimeInterval(12)))
        XCTAssertTrue(holds.covers(from: t.addingTimeInterval(8), to: t.addingTimeInterval(10.2)))
        XCTAssertFalse(holds.covers(from: t.addingTimeInterval(1), to: t.addingTimeInterval(5)))
        XCTAssertFalse(holds.covers(from: t.addingTimeInterval(20), to: t.addingTimeInterval(22)))
    }

    func testOpenHoldCoversNewWords() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(CommandHolds().covers(from: t, to: t.addingTimeInterval(3), open: t.addingTimeInterval(1)))
        XCTAssertFalse(CommandHolds().covers(from: t, to: t.addingTimeInterval(3), open: t.addingTimeInterval(5)))
    }

    func testLiveLineCarriesTheMark() throws {
        let line = LiveFeed.Line(speaker: nil, settled: true, start: Date(), end: Date(), text: "hi", command: true)
        let back = try JSONDecoder().decode(LiveFeed.Line.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(back.command, true)
        XCTAssertNil(LiveFeed.Line(speaker: nil, settled: true, start: Date(), end: Date(), text: "hi").command)
    }
}

extension CommandHoldsTests {
    func testPiecesCutAtTheHold() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let holds = CommandHolds(ranges: [t.addingTimeInterval(4)...t.addingTimeInterval(6)])
        // 10 words over 10 s: words 5 and 6 (4-6 s) are the command, with slack a word either side may join.
        let p = holds.pieces(of: "a b c d e f g h i j", from: t, to: t.addingTimeInterval(10))
        XCTAssertEqual(p.map(\.command), [false, true, false])
        XCTAssertTrue(p[1].text.contains("e f"))
    }
}

extension CommandHoldsTests {
    func testWordsInAWindow() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let text = CommandHolds.words(of: "a b c d e f g h i j", lineStart: t, lineEnd: t.addingTimeInterval(10), from: t.addingTimeInterval(3), to: t.addingTimeInterval(6))
        XCTAssertEqual(text, "d e f")
    }
}
