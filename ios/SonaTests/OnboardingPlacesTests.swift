import CoreLocation
import Foundation
import Testing
@testable import Sona

/// Places in onboarding (7 Nov 2026: "the location should be in the regular onboarding"), asked once, and
/// "from watch" on the watch's notes. No location services here (`watchesPermission: false`), so nothing is asked.
@MainActor
struct OnboardingPlacesTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-places-\(UUID().uuidString)", isDirectory: true)

    func stamps(_ defaults: UserDefaults) -> PlaceStamps {
        PlaceStamps(
            store: PlaceStore(folder: folder), defaults: defaults, watchesPermission: false, looksUpNames: false,
            permission: .notDetermined)
    }

    @Test func threeScreensWithPlacesAskedOnTheLast() {
        // Welcome (the model download), your notes (where they go and how long audio stays), then what Sona asks
        // for: the microphone, notifications and location, one after another. Home comes straight after.
        #expect(OnboardingStep.allCases == [.welcome, .notes, .allow])
        // `-debugOnboardingStep N` numbers them in this order, and clamps to the last.
        #expect(OnboardingStep.allCases.map(\.rawValue) == Array(1...3))
        #expect(OnboardingStep.allow.rawValue == OnboardingStep.allCases.count)
        #expect(OnboardingStep.welcome.next == .notes)
        #expect(OnboardingStep.notes.next == .allow)
        #expect(OnboardingStep.allow.next == nil)
    }

    @Test func theLocationRowSaysWhatIsTrue() {
        #expect(OnboardingText.places(.notDetermined).contains("street"))
        #expect(OnboardingText.places(.authorizedWhenInUse).hasPrefix("On."))
        #expect(OnboardingText.places(.denied).contains("Settings"))
        #expect(OnboardingText.places(.restricted).contains("Not allowed"))
    }

    @Test func yourNotesShowsTheChoicesInUse() {
        #expect(OnboardingText.notesValue(.icloud, folderName: nil, hasPickedFolder: false) == "iCloud")
        #expect(OnboardingText.notesValue(.iphone, folderName: nil, hasPickedFolder: true) == "This iPhone")
        // Other folder: the folder's own name once picked, else the one picked before v1, else nothing yet.
        #expect(OnboardingText.notesValue(.folder, folderName: "Sona", hasPickedFolder: true) == "Sona")
        #expect(OnboardingText.notesValue(.folder, folderName: nil, hasPickedFolder: true) == "Your folder")
        #expect(OnboardingText.notesValue(.folder, folderName: nil, hasPickedFolder: false) == "Other folder")
        #expect(OnboardingText.notesDetail(.icloud, iCloudSignedIn: false).contains("not signed in"))
        #expect(OnboardingText.notesDetail(.iphone, iCloudSignedIn: true) == NotesChoiceText.iPhoneDetail)
        #expect(OnboardingText.audioValue(.thirtyDays) == "30 days")
        #expect(OnboardingText.audioValue(.forever) == "Forever")
        #expect(OnboardingText.audioValue(.deleteAfterTranscribing) == "Until transcribed")
    }

    @Test func keepAudioSavesExactlyWhatTheScreenShowed() {
        // A fresh install picks Other folder: the screen shows 30 days. Continue saves the folder's bookmark first,
        // and with a bookmark the suggested default turns into Forever. What's saved is the 30 days shown.
        var fresh = AudioChoice(OnboardingDefaults.audioPolicy(saved: nil, existingInstall: false))
        #expect(fresh.policy == .thirtyDays)
        let saved = fresh.take()
        fresh.suggest(OnboardingDefaults.audioPolicy(saved: nil, existingInstall: true))
        #expect(saved == .thirtyDays)
        #expect(fresh.policy == .thirtyDays)

        // An install from before v1 with a picked folder shows Forever and switches to iCloud: the bookmark goes, and
        // read again the default would be 30 days, deleting the audio of every note over 30 days old.
        var old = AudioChoice(OnboardingDefaults.audioPolicy(saved: nil, existingInstall: true))
        #expect(old.take() == .forever)
        old.suggest(OnboardingDefaults.audioPolicy(saved: nil, existingInstall: false))
        #expect(old.policy == .forever)

        // Before Continue the suggestion follows the notes as they're listed, until he picks one himself.
        var shown = AudioChoice(.thirtyDays)
        shown.suggest(.forever)
        #expect(shown.policy == .forever)
        shown.pick(.deleteAfterTranscribing)
        shown.suggest(.thirtyDays)
        #expect(shown.policy == .deleteAfterTranscribing)
        #expect(shown.take() == .deleteAfterTranscribing)
    }

    @Test func theDownloadLineIsShortAndCalm() throws {
        // The welcome states the size, which App Review 4.2.3(ii) asks for before anything downloads.
        #expect(OnboardingText.modelDisclosure.contains("480 MB"))
        #expect(OnboardingText.modelDisclosure.contains("starts when you continue"))
        let starting = try #require(ModelProgress(.missing, allowed: true))
        #expect(OnboardingText.download(starting) == "Downloading the speech model")
        let halfway = try #require(ModelProgress(.downloading(fraction: 0.429, phrase: "Downloading"), allowed: true))
        #expect(OnboardingText.download(halfway) == "Downloading the speech model, 42%")
        let preparing = try #require(ModelProgress(.downloading(fraction: 0.92, phrase: "Preparing the model"), allowed: true))
        #expect(OnboardingText.download(preparing) == "Getting the speech model ready")
        let stopped = try #require(ModelProgress(.failed("offline"), allowed: true))
        #expect(OnboardingText.download(stopped).contains("tries again by itself"))
    }

    @Test func onceOnboardingHasAskedNoQuestionComesAfterARecording() async {
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: "onboarding-places-\(UUID().uuidString)")!

        // Without onboarding's step (an install that finished onboarding before it): a kept recording leaves the
        // question for when the app is on screen.
        let old = stamps(defaults)
        #expect(!old.hasAsked)
        old.stampStop(recordingID: "rec-1")
        #expect(defaults.bool(forKey: "placesAskPending"))

        // Onboarding asked, whatever the answer: the leftover question goes, and recordings after it ask nothing.
        await old.askInOnboarding()
        #expect(old.hasAsked)
        #expect(!defaults.bool(forKey: "placesAskPending"))
        let nextLaunch = stamps(defaults)
        #expect(nextLaunch.hasAsked)
        nextLaunch.stampStop(recordingID: "rec-2")
        nextLaunch.appBecameActive()
        #expect(!defaults.bool(forKey: "placesAskPending"))
    }

    @Test func settingsSaysOffOnceTheQuestionWasUsed() {
        // Not asked yet (an install from before the step): the question still comes after a recording.
        #expect(SettingsView.describe(.notDetermined, asked: false) == "Asked after your next recording")
        // Asked in onboarding and never answered (or an Allow Once that ran out): Off, with Turn On beside it.
        #expect(SettingsView.describe(.notDetermined, asked: true) == "Off")
        #expect(SettingsView.describe(.denied, asked: true) == "Off")
        #expect(SettingsView.describe(.authorizedWhenInUse, asked: true) == "On")
    }

    @Test func watchNotesSayFromWatch() {
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        var row = NoteRow(
            id: "2026-11-07/07-05 Budget", state: .note, title: "Budget", startedAt: start,
            endedAt: start.addingTimeInterval(600), length: "10m 0s", isWatch: true)
        #expect(row.meta(notesChoice: .icloud) == "\(Format.timeRange(start, start.addingTimeInterval(600))) · 10m 0s · from watch")
        row.isWatch = false
        #expect(!row.meta(notesChoice: .icloud).contains("watch"))

        // A watch recording that isn't a note yet says so in its title, not twice.
        let waiting = NoteRow.recording(
            id: "r1", startedAt: start, seconds: 60, length: "1m 0s", isWatch: true, state: .waiting, modelReady: true)
        #expect(waiting.title == "Watch recording")
        #expect(!waiting.meta(notesChoice: .icloud).contains("from watch"))

        // The note's screen: "from watch" for the watch's, nothing for this iPhone's own.
        #expect(Format.origin("Apple Watch") == "from watch")
        #expect(Format.origin("iPhone") == nil)
        #expect(Format.origin(nil) == nil)
    }
}
