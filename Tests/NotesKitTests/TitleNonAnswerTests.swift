import XCTest

@testable import NotesKit

/// A model reply that says there's no title keeps the first-words title, on the iPhone and the Mac alike.
final class TitleNonAnswerTests: XCTestCase {
    func testAReplySayingThereIsNoTitleIsNotOne() {
        for reply in ["Untitled", "\"No title\"", "N/A", "None."] {
            XCTAssertNil(TitleText.check(reply), reply)
            XCTAssertFalse(TitleText.isAcceptable(reply), reply)
        }
        // Words that only start the same way are still titles.
        XCTAssertEqual(TitleText.check("Untitled album ideas"), "Untitled album ideas")
        XCTAssertEqual(TitleText.check("None of the above quiz"), "None of the above quiz")
    }
}
