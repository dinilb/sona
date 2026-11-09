import Foundation
import SonaEngine
import Testing
@testable import Sona

/// The redesigned Home and note page (8 Nov 2026), without SwiftUI: how a row's when, where and length read, the one
/// list's order, search, the note's date line, and the recording's wave resampled for the page.
@MainActor
struct HomeScreenTests {
    static let calendar = V1ScreensTests.calendar
    static let au = V1ScreensTests.au
    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date { V1ScreensTests.at(y, m, d, h, min) }

    @Test func rowsSayWhenLikeVoiceMemos() {
        let now = Self.at(2026, 11, 8, 15, 0)
        func day(_ date: Date) -> String { Format.listDay(date, now: now, calendar: Self.calendar, locale: Self.au) }
        // Today: the time, in the locale's own style.
        #expect(day(Self.at(2026, 11, 8, 15, 35)).hasPrefix("3:35"))
        #expect(day(Self.at(2026, 11, 7, 23, 59)) == "Yesterday")
        // Within the week: the weekday; before that the date; another year adds the year.
        #expect(day(Self.at(2026, 11, 5, 9, 0)) == "Thursday")
        #expect(day(Self.at(2026, 11, 2, 9, 0)) == "Monday")
        #expect(day(Self.at(2026, 11, 1, 9, 0)) == "1 Nov")
        #expect(day(Self.at(2025, 11, 4, 9, 0)) == "4 Nov 2025")
    }

    @Test func lengthsReadLikeAClock() {
        #expect(Format.clock(11) == "0:11")
        #expect(Format.clock(265) == "4:25")
        #expect(Format.clock(3729) == "1:02:09")
        #expect(V1ScreensTests.note("a", Date()).lengthClock == "1:00")
        var unknown = V1ScreensTests.note("b", Date())
        unknown.length = ""
        #expect(unknown.lengthClock == nil)
        #expect(unknown.lengthSpoken == nil)
        // VoiceOver hears a length with its units, not "four twenty-five" like a time of day.
        let spoken = Format.spokenLength(265, locale: Self.au)
        #expect(spoken.contains("4 minutes") && spoken.contains("25 seconds") && !spoken.contains(":"))
        #expect(Format.spokenLength(3729, locale: Self.au).contains("1 hour"))
        #expect(V1ScreensTests.note("a", Date()).lengthSpoken?.contains("1 minute") == true)
    }

    @Test func aRowsGreyLineIsWhenThenWhereThenSync() {
        let now = Self.at(2026, 11, 8, 15, 0)
        func parts(_ row: NoteRow, _ choice: NotesChoice? = .icloud) -> [String] {
            row.listParts(notesChoice: choice, now: now, calendar: Self.calendar, locale: Self.au)
        }
        let yesterday = Self.at(2026, 11, 7, 9, 0)
        #expect(parts(V1ScreensTests.note("a", yesterday, place: "Queen St", placeEnd: "Park Rd")) == ["Yesterday", "Queen St"])
        #expect(parts(V1ScreensTests.note("b", yesterday)) == ["Yesterday"])
        var staged = V1ScreensTests.note("c", yesterday)
        staged.isSynced = false
        #expect(parts(staged) == ["Yesterday", "Not synced yet"])
        // Notes that stay on this iPhone anyway don't say so on every row.
        #expect(parts(staged, .iphone) == ["Yesterday"])
        staged.keptOnIPhone = true
        #expect(parts(staged) == ["Yesterday", "On this iPhone"])
        // A recording that isn't a note yet says what's happening, never with a middle dot.
        func recording(_ state: NoteRow.State) -> NoteRow {
            NoteRow.recording(
                id: "r", startedAt: yesterday, seconds: 30, length: "30s", isWatch: true, state: state, modelReady: true)
        }
        #expect(parts(recording(.transcribing)) == ["Yesterday", "Transcribing"])
        #expect(parts(recording(.waiting)) == ["Yesterday", "Waiting to transcribe"])
        #expect(parts(recording(.failed)) == ["Yesterday", "Couldn't transcribe. Tap to try again."])
        #expect(!parts(recording(.failed)).joined().contains("·"))
    }

    @Test func homeIsOneListWithWhatsHappeningFirst() {
        let a = V1ScreensTests.note("a", Self.at(2026, 11, 8, 9, 0))
        let b = V1ScreensTests.note("b", Self.at(2026, 11, 8, 15, 0))
        let old = V1ScreensTests.note("old", Self.at(2026, 11, 1, 9, 0))
        let waiting = NoteRow.recording(
            id: "w", startedAt: Self.at(2026, 11, 7, 9, 0), seconds: 5, length: "5s", isWatch: false, state: .waiting,
            modelReady: true)
        #expect(HomeOrder.rows([old, a, waiting, b]).map(\.id) == ["spool:w", "b", "a", "old"])
    }

    @Test func searchFindsEveryWordAnywhere() {
        var row = V1ScreensTests.note("Plan for exam week", Date(), place: "Queen St")
        #expect(NoteSearch.matches("", in: NoteSearch.fields(row)))
        #expect(NoteSearch.matches("exam", in: NoteSearch.fields(row)))
        #expect(NoteSearch.matches("queen EXAM", in: NoteSearch.fields(row)))
        #expect(!NoteSearch.matches("exam park", in: NoteSearch.fields(row)))
        // Accents and case don't matter, and words match inside other words, like the Mac's search.
        #expect(NoteSearch.matches("café", in: ["Cafe on Queen St"]))
        #expect(NoteSearch.matches("ona", in: ["Sona"]))
        row.isWatch = true
        #expect(NoteSearch.matches("watch", in: NoteSearch.fields(row)))
    }

    /// A note as the iPhone writes it: front matter (with a place, its coordinates and Keep audio), the heading, then
    /// the lines.
    static func noteFile(_ lines: [String]) -> String {
        """
        ---
        title: "First exam is Tuesday"
        ai_title: "Plan for exam week"
        date: 2026-11-08
        start: "15:40:02"
        end: "15:44:27"
        duration: 4m 25s
        speakers: ["Speaker 1", "Speaker 2"]
        model: parakeet-tdt-0.6b-v2
        source: "iPhone"
        place: "Queen St"
        geo: "-27.4698, 153.0251"
        tags: [sona]
        keep_audio: true
        ---

        # First exam is Tuesday


        """ + lines.enumerated().map { i, line in "[00:\(String(format: "%02d", i * 7))] Speaker \(i % 2 + 1): \(line)\n\n" }.joined()
    }

    @Test func searchReadsWhatWasSaidNotTheNotesHeader() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exam = dir.appendingPathComponent("15-40 First exam is Tuesday.md")
        let other = dir.appendingPathComponent("09-00 Quick round.md")
        try Self.noteFile(["Library after lunch every day this week.", "Practice papers on Thursday?"])
            .write(to: exam, atomically: true, encoding: .utf8)
        try Self.noteFile(["Groceries and coffee beans."]).write(to: other, atomically: true, encoding: .utf8)
        let notes = [
            TranscriptCache.Searched(id: "exam", url: exam, fields: ["Plan for exam week", "Queen St"]),
            TranscriptCache.Searched(id: "other", url: other, fields: ["Quick round"]),
        ]
        let cache = TranscriptCache()
        func found(_ query: String) async -> Set<String> { await cache.matching(query, in: notes) }

        #expect(await found("library LUNCH") == ["exam"])
        #expect(await found("coffee") == ["other"])
        // The header and each line's prefix are in every note: none of their words or numbers find anything.
        for query in ["speaker", "start", "end", "date", "duration", "model", "parakeet", "phone", "source", "sona",
                      "tags", "keep", "geo", "153", "2026", "15", "4", "00:07", "first exam"] {
            #expect(await found(query).isEmpty, "\(query)")
        }
        // Every word has to be somewhere, the row's fields and the words together: one in the title, one said.
        #expect(await found("exam lunch") == ["exam"])
        #expect(await found("queen thursday") == ["exam"])
        #expect(await found("exam groceries").isEmpty)
    }

    @Test func searchReadsANoteAgainWhenItChangesAndForgetsOneThatsGone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("15-40 First exam is Tuesday.md")
        let note = [TranscriptCache.Searched(id: "exam", url: url, fields: ["Plan for exam week"])]
        let cache = TranscriptCache()

        // Not here yet (iCloud took it off this iPhone, or it's moving): no match, and nothing kept, so once it's back
        // its words are found.
        #expect(await cache.matching("lunch", in: note).isEmpty)
        try Self.noteFile(["Library after lunch."]).write(to: url, atomically: true, encoding: .utf8)
        // A key typed before the note was ever read only uses what's read already.
        #expect(await cache.matching("lunch", in: note, readingNew: false).isEmpty)
        #expect(await cache.matching("lunch", in: note) == ["exam"])
        #expect(await cache.matching("lunch", in: note, readingNew: false) == ["exam"])

        // Edited (on the Mac, say): the new words are found and the old ones aren't.
        try Self.noteFile(["Groceries and coffee beans, then the gym."]).write(to: url, atomically: true, encoding: .utf8)
        #expect(await cache.matching("lunch", in: note).isEmpty)
        #expect(await cache.matching("gym", in: note) == ["exam"])

        // Deleted: gone from the results, even from what's kept for typing.
        try FileManager.default.removeItem(at: url)
        #expect(await cache.matching("gym", in: note).isEmpty)
        #expect(await cache.matching("gym", in: note, readingNew: false).isEmpty)
    }

    @Test func aSearchShowsTheLastQuerysMatchesOnlyWhileTheyStillApply() {
        let last = TextMatches(query: "libr", ids: ["a"])
        #expect(last.ids(for: "libr") == ["a"])
        // A letter more or less: shown for the moment until the new query's own answer.
        #expect(last.ids(for: "libra") == ["a"])
        #expect(last.ids(for: "lib") == ["a"])
        // Another query entirely, or none: nothing from the last one.
        #expect(last.ids(for: "coffee").isEmpty)
        #expect(last.ids(for: "").isEmpty)
        #expect(TextMatches().ids(for: "libr").isEmpty)
    }

    @Test func aNotesDateLineSaysTheDayAndTime() {
        let now = Self.at(2026, 11, 8, 15, 0)
        func when(_ date: Date) -> String { Format.noteWhen(date, now: now, calendar: Self.calendar, locale: Self.au) }
        #expect(when(Self.at(2026, 11, 8, 15, 35)).hasPrefix("Today, 3:35"))
        #expect(when(Self.at(2026, 11, 7, 9, 10)).hasPrefix("Yesterday, 9:10"))
        #expect(when(Self.at(2026, 11, 5, 7, 5)).hasPrefix("Thursday 5 Nov, 7:05"))
        #expect(when(Self.at(2025, 11, 5, 7, 5)).hasPrefix("5 Nov 2025, 7:05"))
    }

    @Test func theRecordingsWaveKeepsShortLoudBitsWhenSqueezed() {
        let levels: [Float] = [0, 0, 0.9, 0, 0, 0, 0.5, 0]
        #expect(AudioPeaks.resample(levels, to: 4) == [0, 0.9, 0, 0.5])
        #expect(AudioPeaks.resample(levels, to: 8) == levels)
        #expect(AudioPeaks.resample([0.3], to: 3) == [0.3, 0.3, 0.3])
        #expect(AudioPeaks.resample([], to: 3).isEmpty)
    }

    @Test func theRecordingsWaveIsReadFromItsAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // One second of silence, then one of a loud tone, at 16 kHz.
        let rate = 16_000
        let samples: [Float] = (0..<rate).map { _ in 0 } + (0..<rate).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        let wav = try WavFile(creating: url)
        try wav.append(samples)
        try wav.finish()
        let peaks = try #require(AudioPeaks.load(url, count: 4))
        #expect(peaks.count == 4)
        #expect(peaks[0] == 0 && peaks[1] == 0)
        #expect(peaks[2] > 0.5 && peaks[3] > 0.5)
    }
}
