import Foundation
import Testing
@testable import Sona

/// The v1 screens' logic, without SwiftUI: how days and times read, how rows group into days and places, what the
/// speech model's bar says in each state, where onboarding starts, and what a widget's link does after a crash.
@MainActor
struct V1ScreensTests {
    static let brisbane = TimeZone(identifier: "Australia/Brisbane")!
    static let au = Locale(identifier: "en_AU")

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = brisbane
        return calendar
    }

    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func note(_ id: String, _ start: Date, place: String? = nil, placeEnd: String? = nil) -> NoteRow {
        NoteRow(id: id, state: .note, title: id, startedAt: start, length: "1m 0s", place: place, placeEnd: placeEnd)
    }

    // MARK: days and times

    @Test func dayLabelsReadLikeNotes() {
        let now = Self.at(2026, 11, 6, 15, 0)
        func label(_ date: Date) -> String { Format.dayLabel(date, now: now, calendar: Self.calendar, locale: Self.au) }
        #expect(label(Self.at(2026, 11, 6, 7, 5)) == "Today, 6 Nov")
        #expect(label(Self.at(2026, 11, 5, 23, 59)) == "Yesterday, 5 Nov")
        #expect(label(Self.at(2026, 11, 4, 9, 0)) == "Wed 4 Nov")
        #expect(label(Self.at(2025, 11, 4, 9, 0)) == "Tue 4 Nov 2025")
    }

    @Test func timeRangesDropZeroMinutesAndRepeats() {
        func range(_ start: Date, _ end: Date?, _ locale: Locale = V1ScreensTests.au) -> String {
            Format.timeRange(start, end, locale: locale, timeZone: Self.brisbane)
        }
        #expect(range(Self.at(2026, 11, 6, 7, 5), Self.at(2026, 11, 6, 11, 0)) == "7:05am – 11am")
        #expect(range(Self.at(2026, 11, 6, 12, 0), Self.at(2026, 11, 6, 13, 30)) == "12pm – 1:30pm")
        // Within the same minute, or with no end: just the start.
        #expect(range(Self.at(2026, 11, 6, 7, 5), Self.at(2026, 11, 6, 7, 5, 40)) == "7:05am")
        #expect(range(Self.at(2026, 11, 6, 7, 5), nil) == "7:05am")
        // US English writes AM; it reads the same here.
        #expect(range(Self.at(2026, 11, 6, 7, 5), Self.at(2026, 11, 6, 11, 0), Locale(identifier: "en_US")) == "7:05am – 11am")
        // A 24-hour locale keeps its own clock.
        #expect(range(Self.at(2026, 11, 6, 7, 5), Self.at(2026, 11, 6, 11, 0), Locale(identifier: "en_GB")) == "07:05 – 11:00")
    }

    @Test func lengthsAsNotesWriteThem() {
        #expect(Format.seconds(fromLength: "18m 28s") == 1108)
        #expect(Format.seconds(fromLength: "1h 12m") == 4320)
        #expect(Format.seconds(fromLength: "40s") == 40)
        #expect(Format.seconds(fromLength: "") == nil)
        #expect(Format.seconds(fromLength: "soon") == nil)
    }

    @Test func placesShowBothEndsOnlyWhenTheyDiffer() {
        #expect(Format.places("4 Main St", "10 King St") == "4 Main St → 10 King St")
        #expect(Format.places("4 Main St", "4 Main St") == "4 Main St")
        #expect(Format.places("4 Main St", nil) == "4 Main St")
        #expect(Format.places(nil, "10 King St") == "10 King St")
        #expect(Format.places(nil, nil) == nil)
    }

    // MARK: grouping

    @Test func daysNewestFirstAndEachDayReadsLikeTheDay() {
        let rows = [
            Self.note("2026-11-06/12-00 Lunch", Self.at(2026, 11, 6, 12, 0)),
            Self.note("2026-11-06/07-05 Walk", Self.at(2026, 11, 6, 7, 5)),
            NoteRow.recording(
                id: "r1", startedAt: Self.at(2026, 11, 6, 14, 0), seconds: 60, length: "1m 0s", isWatch: true, state: .waiting,
                modelReady: true),
            Self.note("2026-11-05/09-00 Call", Self.at(2026, 11, 5, 9, 0)),
            Self.note("2026-11-05/00-10 Late", Self.at(2026, 11, 5, 0, 10)),
        ]
        let days = DayList.days(rows, calendar: Self.calendar)
        #expect(days.map(\.id) == ["2026-11-06", "2026-11-05"])
        // Recordings that aren't notes yet first, then the notes oldest first.
        #expect(days[0].rows.map(\.id) == ["spool:r1", "2026-11-06/07-05 Walk", "2026-11-06/12-00 Lunch"])
        #expect(days[0].count == 3)
        #expect(days[0].waiting == 1)
        #expect(days[1].rows.map(\.id) == ["2026-11-05/00-10 Late", "2026-11-05/09-00 Call"])
        #expect(days[1].date == Self.at(2026, 11, 5, 0, 0))
    }

    @Test func aPlaceListsNotesThatStartedOrStoppedThere() {
        let rows = [
            Self.note("a", Self.at(2026, 11, 6, 7, 0), place: "4 Main St"),
            Self.note("b", Self.at(2026, 11, 6, 9, 0), place: "1 King St", placeEnd: "4 Main St"),
            Self.note("c", Self.at(2026, 11, 6, 10, 0), place: "1 King St"),
            Self.note("d", Self.at(2026, 11, 4, 10, 0), place: "4 Main St"),
        ]
        let days = DayList.days(at: "4 Main St", in: rows, calendar: Self.calendar)
        #expect(days.map(\.id) == ["2026-11-06", "2026-11-04"])
        #expect(days[0].rows.map(\.id) == ["a", "b"])
        #expect(rows[1].places == ["1 King St", "4 Main St"])
        #expect(Self.note("e", Date(), place: "X", placeEnd: "X").places == ["X"])
    }

    @Test func aNoteWithNoTimeFallsOnItsFoldersDay() {
        #expect(DayList.date(ofNoteID: "2026-11-02/14-03 Title", calendar: Self.calendar) == Self.at(2026, 11, 2, 0, 0))
        #expect(DayList.date(ofNoteID: "not a note", calendar: Self.calendar) == nil)
    }

    @Test func recordingRowsSayWhereTheyAre() {
        func row(_ state: NoteRow.State, ready: Bool = true) -> NoteRow {
            NoteRow.recording(
                id: "abc", startedAt: Self.at(2026, 11, 6, 7, 0), seconds: 252, length: "4m 12s", isWatch: false, state: state,
                modelReady: ready)
        }
        #expect(row(.waiting).status == "waiting to transcribe")
        #expect(row(.waiting, ready: false).status == "waits for the speech model")
        #expect(row(.transcribing).status == "transcribing")
        #expect(row(.failed).status == "couldn't transcribe · tap to try again")
        #expect(row(.waiting).spoolID == "abc")
        #expect(row(.waiting).title == "Recording")
        #expect(row(.waiting).endedAt == Self.at(2026, 11, 6, 7, 4, 12))
        #expect(Self.note("2026-11-06/07-05 Walk", Date()).spoolID == nil)
    }

    // MARK: the speech model's bar

    @Test func theModelBarForEachState() throws {
        #expect(ModelProgress(.ready, allowed: true) == nil)
        // Before the welcome screen's Continue there's nothing to show (that screen says it all).
        #expect(ModelProgress(.missing, allowed: false) == nil)

        let starting = try #require(ModelProgress(.missing, allowed: true))
        #expect(starting.text == "Downloading the local speech model, please wait...")
        #expect(starting.fraction == 0)

        let downloading = try #require(ModelProgress(.downloading(fraction: 0.429, phrase: "Downloading the speech model..."), allowed: true))
        #expect(downloading.text == "Downloading the local speech model, please wait... 42%")
        #expect(downloading.fraction == 0.429)
        #expect(!downloading.stopped)

        let preparing = try #require(
            ModelProgress(.downloading(fraction: 0.92, phrase: "Preparing the speech model for the Neural Engine..."), allowed: true))
        #expect(preparing.text == "Getting the speech model ready, please wait...")
        #expect(preparing.fraction == 0.92)

        // Stopped: no bar and no button, it tries again by itself.
        let failed = try #require(ModelProgress(.failed("The Internet connection appears to be offline."), allowed: true))
        #expect(failed.stopped)
        #expect(failed.fraction == nil)
        #expect(failed.text.contains("tries again by itself"))
        #expect(!failed.text.contains("offline"))
    }

    // MARK: onboarding

    @Test func onboardingStartsFromWhatIsThere() {
        // A choice already saved wins.
        #expect(OnboardingDefaults.notesChoice(saved: .iphone, hasPickedFolder: true, iCloudSignedIn: true) == .iphone)
        // An install from before v1 with a picked folder keeps it.
        #expect(OnboardingDefaults.notesChoice(saved: nil, hasPickedFolder: true, iCloudSignedIn: true) == .folder)
        // iCloud is the default when the phone is signed in to it.
        #expect(OnboardingDefaults.notesChoice(saved: nil, hasPickedFolder: false, iCloudSignedIn: true) == .icloud)
        #expect(OnboardingDefaults.notesChoice(saved: nil, hasPickedFolder: false, iCloudSignedIn: false) == .iphone)
        #expect(OnboardingStep.allCases.map(\.rawValue) == [1, 2, 3])
    }

    // MARK: links (R3-5)

    @Test func aRecordLinkRightAfterACrashMidRecordingStartsNothing() {
        let launched = Date(timeIntervalSince1970: 1_794_000_000)
        func action(
            _ link: DeepLink?, onboarded: Bool = true, recording: Bool = false, cutShort: Date? = nil, after seconds: TimeInterval = 1
        ) -> AppModel.LinkAction {
            AppModel.linkAction(
                link, onboardingDone: onboarded, isRecording: recording, cutShortAt: cutShort, launchedAt: launched,
                now: launched + seconds)
        }
        let crashed = launched - 600
        #expect(action(.record) == .start)
        // The widget still showed the recording the app died in: tapping it only opens the app.
        #expect(action(.record, cutShort: crashed) == .nothing)
        // Later, a record link is one he meant.
        #expect(action(.record, cutShort: crashed, after: AppModel.cutShortGrace + 1) == .start)
        // A record link never stops a recording, and a stop link never starts one.
        #expect(action(.record, recording: true) == .nothing)
        #expect(action(.stop, recording: true) == .stop)
        #expect(action(.stop) == .nothing)
        #expect(action(nil) == .nothing)
    }

    @Test func nothingFromOutsideRecordsBeforeOnboardingIsDone() {
        let launched = Date(timeIntervalSince1970: 1_794_000_000)
        func action(_ link: DeepLink?, onboarded: Bool, recording: Bool = false) -> AppModel.LinkAction {
            AppModel.linkAction(
                link, onboardingDone: onboarded, isRecording: recording, cutShortAt: nil, launchedAt: launched,
                now: launched + 60)
        }
        // A fresh install whose first tap is the widget: the link only opens the app, at the welcome.
        #expect(action(.record, onboarded: false) == .nothing)
        #expect(action(.record, onboarded: true) == .start)
        // A recording that somehow runs can still be stopped.
        #expect(action(.stop, onboarded: false, recording: true) == .stop)

        // The Record control, Siri, the Action button.
        func start(_ onboarded: Bool, offScreen: Bool = true, canOpenApp: Bool = true) -> AppModel.OutsideStart {
            AppModel.outsideStart(onboardingDone: onboarded, offScreen: offScreen, canOpenApp: canOpenApp)
        }
        #expect(start(true) == .record)
        #expect(start(true, offScreen: false) == .record)
        #expect(start(true, canOpenApp: false) == .record)
        #expect(start(false) == .openApp)
        #expect(start(false, offScreen: false) == .stay)
        #expect(start(false, canOpenApp: false) == .refuse)
        #expect(RecordingError.notSetUp.errorDescription?.isEmpty == false)
    }
}
