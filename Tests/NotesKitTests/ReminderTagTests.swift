import XCTest
@testable import NotesKit

final class ReminderTagTests: XCTestCase {
    func testFindsReminders() {
        XCTAssertTrue(NoteWriter.mentionsReminder("Hey, remind me to call Mum tomorrow."))
        XCTAssertTrue(NoteWriter.mentionsReminder("Reminder: the DECO reflection is due Monday."))
        XCTAssertTrue(NoteWriter.mentionsReminder("don't forget to pay rent"))
        XCTAssertTrue(NoteWriter.mentionsReminder("Dont let me forget the charger"))
    }

    func testIgnoresOtherTalk() {
        XCTAssertFalse(NoteWriter.mentionsReminder("We talked about the launch plan."))
        XCTAssertFalse(NoteWriter.mentionsReminder("That reminded him of Sydney."))
    }
}
