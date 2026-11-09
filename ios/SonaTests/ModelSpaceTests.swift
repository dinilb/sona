import Foundation
import Testing
@testable import Sona

/// The speech model download only starts with room for what's left of it and the 200 MB a recording needs, and says
/// how much to free up when there isn't.
struct ModelSpaceTests {
    private let mb: Int64 = 1_000_000

    @Test func itNeedsWhatIsLeftPlusRoomToRecord() {
        let left: Int64 = 400 * mb
        // ~600 MB free, the audit's case: 400 MB to go plus 200 MB to record is just over it.
        #expect(NotesService.spaceShortfall(free: 600 * mb - 1, left: left) == 1)
        #expect(NotesService.spaceShortfall(free: 600 * mb, left: left) == nil)
        #expect(NotesService.spaceShortfall(free: 2_000 * mb, left: left) == nil)
        // A fresh download on a nearly full phone.
        #expect(NotesService.spaceShortfall(free: 300 * mb, left: 487 * mb) == 387 * mb)
        // Nearly all there already: only the room to record counts.
        #expect(NotesService.spaceShortfall(free: 150 * mb, left: 0) == 50 * mb)
        // Free space unknown: it tries, as before.
        #expect(NotesService.spaceShortfall(free: nil, left: left) == nil)
    }

    @Test func theBarSaysHowMuchToFreeUp() throws {
        let progress = try #require(ModelProgress(.noSpace(bytes: 387 * mb), allowed: true))
        #expect(progress.text == "Free up 387 MB to download the speech model.")
        #expect(progress.fraction == nil)
        #expect(progress.stopped)
        // Onboarding's shorter line says the same, not "tries again by itself" (it waits for the next time Sona opens).
        #expect(OnboardingText.download(progress) == "Free up 387 MB to download the speech model.")
        // Rounded up, so freeing what it says is always enough.
        #expect(ModelProgress(.noSpace(bytes: 1), allowed: true)?.text == "Free up 1 MB to download the speech model.")
        #expect(ModelProgress(.noSpace(bytes: 50 * mb + 1), allowed: true)?.text == "Free up 51 MB to download the speech model.")
    }
}
