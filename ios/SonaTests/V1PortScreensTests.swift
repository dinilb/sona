import Foundation
import Testing
@testable import Sona

/// What came over from the other v1 build for the screens: where onboarding's audio step starts, what the notes
/// choices say about Sona on a Mac, and the licences Settings lists.
@MainActor
struct V1PortScreensTests {
    /// An install that already has notes (from before v1, when audio was always kept) starts on Keep forever, so
    /// going straight on deletes nothing; a new one starts on 30 days; a saved setting always wins.
    @Test func audioStepStartsFromWhatIsThere() {
        #expect(OnboardingDefaults.audioPolicy(saved: nil, existingInstall: true) == .forever)
        #expect(OnboardingDefaults.audioPolicy(saved: nil, existingInstall: false) == .thirtyDays)
        #expect(OnboardingDefaults.audioPolicy(saved: .deleteAfterTranscribing, existingInstall: true) == .deleteAfterTranscribing)
        #expect(OnboardingDefaults.audioPolicy(saved: .thirtyDays, existingInstall: true) == .thirtyDays)
    }

    /// The Mac reads only iCloud Drive's Sona folder and the app's iCloud folder, so the other two choices say so.
    @Test func notesChoicesSayWhatTheMacSees() {
        #expect(NotesChoiceText.iPhoneDetail.contains("Sona on a Mac doesn't see them"))
        #expect(NotesChoiceText.folderDetail.contains("only if it's iCloud Drive › Sona"))
    }

    /// Everything the app links or downloads is credited, with FluidAudio's own notices (VBx, fastcluster), and each
    /// opens its licence's text.
    @Test func settingsCreditsEveryLicence() {
        let names = Licence.all.map(\.name)
        for part in ["FluidAudio", "VBx", "fastcluster", "Parakeet TDT 0.6B v2", "pyannote", "Silero VAD", "hearsay"] {
            #expect(names.contains { $0.contains(part) }, "missing \(part)")
        }
        #expect(Set(names).count == names.count)
        #expect(Licence.all.allSatisfy { $0.url.scheme == "https" })
    }

    /// The Apache-2.0, BSD-2-Clause and MIT texts and the credits are inside the app, not only linked.
    @Test func licenceTextsShipInTheApp() {
        for item in LicenceText.all {
            let text = item.text()
            #expect(text?.isEmpty == false, "missing \(item.file)")
        }
        #expect(LicenceText.all.first { $0.file == "THIRD_PARTY.md" }?.text()?.contains("hearsay") == true)
        #expect(LicenceText.all.first { $0.file == "vbx-LICENSE.md" }?.text()?.contains("Apache") == true)
    }
}
