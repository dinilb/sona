import Foundation
import Testing
@testable import Sona

/// Fixes on the v1 screens: Share leaves out a note's exact coordinates, turning Keep audio off asks first when that
/// deletes the audio now, and the Settings footer says where notes kept On this iPhone go after a switch.
@MainActor
struct V1FixScreensTests {
    /// A note with both places and both fixes, like PlaceStamps leaves it.
    static let placed = """
        ---
        title: "Pitch practice with Sam"
        date: 2026-11-06T07:05:00+10:00
        duration: 18m 28s
        place: "4 Main St"
        geo: -27.4698,153.0251
        place_end: "10 King St"
        geo_end: -27.4710,153.0234
        keep_audio: true
        tags: [sona, conversation]
        ---

        # Pitch practice with Sam

        **0:00 Speaker 1:** geo: this line is the transcript, not front matter.

        """

    // MARK: share

    @Test func shareLeavesOutTheCoordinates() {
        let shared = NoteDetail.shareable(Self.placed)
        #expect(!shared.contains("-27.4698"))
        #expect(!shared.contains("-27.4710"))
        #expect(!shared.contains("\ngeo_end:"))
        // The place names the screen shows, and every other line, stay.
        #expect(shared.contains("\nplace: \"4 Main St\"\n"))
        #expect(shared.contains("\nplace_end: \"10 King St\"\n"))
        #expect(shared.contains("\nkeep_audio: true\n"))
        #expect(shared.hasPrefix("---\ntitle: \"Pitch practice with Sam\"\n"))
        // The transcript after the front matter stays byte for byte, a line starting "geo:" included.
        let body = "\n---\n\n# Pitch practice with Sam\n\n**0:00 Speaker 1:** geo: this line is the transcript, not front matter.\n"
        #expect(shared.hasSuffix(body))
        // Only the two lines went.
        #expect(shared.count(where: { $0 == "\n" }) == Self.placed.count(where: { $0 == "\n" }) - 2)
    }

    @Test func shareKeepsANoteWithoutCoordinatesAsItIs() {
        let plain = Self.placed
            .replacingOccurrences(of: "geo: -27.4698,153.0251\n", with: "")
            .replacingOccurrences(of: "geo_end: -27.4710,153.0234\n", with: "")
        #expect(NoteDetail.shareable(plain) == plain)
        // No front matter at all: as it is.
        #expect(NoteDetail.shareable("Just a title") == "Just a title")
    }

    // MARK: Keep audio off

    @Test func keepAudioOffDeletesNowOnlyWhenThePolicyWouldExpireIt() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let day = 86_400.0
        func deletes(_ age: Double?, _ policy: AudioPolicy) -> Bool {
            AppModel.deletesAudioWithoutKeep(startedAt: age.map { now.addingTimeInterval(-$0) }, policy: policy, now: now)
        }
        // 30 days: only a note that started over 30 days ago loses its audio now.
        #expect(deletes(31 * day, .thirtyDays))
        #expect(deletes(30 * day + 1, .thirtyDays))
        #expect(!deletes(30 * day, .thirtyDays))
        #expect(!deletes(2 * day, .thirtyDays))
        // A start that can't be read keeps its audio, as the sweep does.
        #expect(!deletes(nil, .thirtyDays))
        // Keep forever never deletes; Delete once transcribed always does.
        #expect(!deletes(365 * day, .forever))
        #expect(deletes(60, .deleteAfterTranscribing))
    }

    @Test func keepAudioOffConfirmSaysTheAudioGoesNow() {
        #expect(AppModel.keepAudioOffTitle == "Delete this note's audio now?")
        #expect(AppModel.keepAudioOffMessage.contains("can't be undone"))
    }

    // MARK: Settings footer

    @Test func footerSaysNotesOnThisIPhoneStayListed() {
        let iphone = SettingsView.notesFooter(.iphone)
        #expect(iphone.contains("Sona still lists them"))
        #expect(!iphone.contains("old place"))
        for choice in [NotesChoice.icloud, .folder] {
            #expect(SettingsView.notesFooter(choice).hasPrefix("Notes already in the old place stay there"))
        }
    }
}
