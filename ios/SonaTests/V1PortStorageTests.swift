import Foundation
import NotesKit
import Testing
@testable import Sona

/// What came over from the other v1 build for storage: moves with iCloud stubs and other devices' files, staging in
/// backups while notes wait, the audio confirm counting notes not downloaded, end times, exact note ids, a delete
/// taking what a cut-short move left, and titles tried kept without their words.
struct V1PortStorageTests {
    typealias Folders = NotesLocationMoveTests.Folders

    // MARK: moves

    /// An evicted note there can't be compared, so a note here with its name goes to "... 2", never over it.
    @Test func anEvictedNoteThereKeepsItsName() throws {
        let f = Folders()
        try f.write("", f.to, ".09-00 First.md.icloud")
        try f.write("note a", f.from, "09-00 First.md")
        try f.write("{}", f.from, "09-00 First.json")

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["09-00 First 2.md", "09-00 First 2.json"])
        #expect(FileManager.default.fileExists(atPath: f.to.appendingPathComponent(".09-00 First.md.icloud").path))
    }

    /// The .json moved and iCloud evicted it since (only its stub is there): the note still has its words there, so
    /// the rest moves instead of waiting for a .json forever.
    @Test func aMovedJSONThatWasEvictedStillCounts() throws {
        let f = Folders()
        try f.write("", f.to, ".09-00 First.json.icloud")
        try f.write("note a", f.from, "09-00 First.md")
        try f.write("audio a", f.from, "09-00 First.m4a")

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["09-00 First.md", "09-00 First.m4a"])
        #expect(FileManager.default.fileExists(atPath: f.to.appendingPathComponent(".09-00 First.json.icloud").path))
        #expect(!FileManager.default.fileExists(atPath: f.from.path))
    }

    /// A move cut short after the .json, and the m4a moved there was evicted since: ours, whole, replaces the stub.
    @Test func anEvictedStubOfOurOwnMoveIsReplaced() throws {
        let f = Folders()
        try f.write("{\"a\":1}", f.to, "09-00 First.json")
        try f.write("", f.to, ".09-00 First.m4a.icloud")
        try f.write("note a", f.from, "09-00 First.md")
        try f.write("audio a", f.from, "09-00 First.m4a")

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["09-00 First.md", "09-00 First.json", "09-00 First.m4a"])
        #expect(try f.read(f.to, "09-00 First.m4a") == "audio a")
        #expect(!FileManager.default.fileExists(atPath: f.to.appendingPathComponent(".09-00 First.m4a.icloud").path))
    }

    /// Files there with no .md and this note's .json still here: none of this note moved (its .json goes first), so
    /// they may be another device's move in progress. Nothing of them is touched; the note goes to "... 2".
    @Test func filesThereWithNoMDAreNeverDeletedWhileOurJSONIsHere() throws {
        let f = Folders()
        try f.write("{\"old\":1}", f.to, "09-00 First.json")
        try f.write("old audio", f.to, "09-00 First.m4a")
        try f.write("note a", f.from, "09-00 First.md")
        try f.write("{\"a\":1}", f.from, "09-00 First.json")

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["09-00 First.json", "09-00 First.m4a", "09-00 First 2.md", "09-00 First 2.json"])
        #expect(try f.read(f.to, "09-00 First.json") == "{\"old\":1}")
        #expect(try f.read(f.to, "09-00 First.m4a") == "old audio")
        #expect(try f.read(f.to, "09-00 First 2.json") == "{\"a\":1}")
        #expect(!FileManager.default.fileExists(atPath: f.from.path))
    }

    /// The same, with that .json evicted there: it can't be compared, so it's left alone too.
    @Test func anEvictedJSONThereIsLeftAloneWhileOurJSONIsHere() throws {
        let f = Folders()
        try f.write("", f.to, ".09-00 First.json.icloud")
        try f.write("note a", f.from, "09-00 First.md")
        try f.write("{\"a\":1}", f.from, "09-00 First.json")

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["09-00 First 2.md", "09-00 First 2.json"])
        #expect(FileManager.default.fileExists(atPath: f.to.appendingPathComponent(".09-00 First.json.icloud").path))
    }

    /// The note is there already (its .md, the same), edited since: an older copy left here never replaces what's
    /// there, it's dropped.
    @Test func aNoteThatLandedKeepsItsNewerFilesThere() throws {
        let f = Folders()
        try f.write("note a", f.from, "09-00 First.md")
        try f.write("{\"a\":1}", f.from, "09-00 First.json")
        try f.write("note a", f.to, "09-00 First.md")
        try f.write("{\"a\":2}", f.to, "09-00 First.json")

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["09-00 First.md", "09-00 First.json"])
        #expect(try f.read(f.to, "09-00 First.json") == "{\"a\":2}")
        #expect(!FileManager.default.fileExists(atPath: f.from.path))
    }

    // MARK: staging in backups while notes wait

    @Test func stagingIsBackedUpOnlyWhileNotesWaitThere() throws {
        let staging = makeTempDir()
        #expect(NotesService.stagingBackedUp(NotesLocation(kind: .local, folder: staging, waiting: .iCloudOff)))
        #expect(NotesService.stagingBackedUp(NotesLocation(kind: .local, folder: staging)))  // nothing chosen yet
        #expect(!NotesService.stagingBackedUp(NotesLocation(kind: .iCloudContainer, folder: makeTempDir())))
        #expect(!NotesService.stagingBackedUp(NotesLocation(kind: .iphone, folder: makeTempDir())))
        #expect(!NotesService.stagingBackedUp(nil))

        let root = makeTempDir()
        let spool = root.appendingPathComponent("Spool", isDirectory: true)
        let notes = root.appendingPathComponent("Documents/Sona", isDirectory: true)
        func excluded(_ url: URL) throws -> Bool? { try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup }
        NotesService.protectPrivateFolders(spool: spool, notes: notes, notesBackedUp: true)
        #expect(try excluded(notes) == false)
        // The spool's raw audio is never backed up.
        #expect(try excluded(spool) == true)
        #expect(try excluded(spool.appendingPathComponent("failed", isDirectory: true)) == true)
        // Once notes can move, staging is out again.
        NotesService.protectPrivateFolders(spool: spool, notes: notes)
        #expect(try excluded(notes) == true)
    }

    // MARK: the audio confirm

    /// Notes iCloud took off this iPhone can't say whether they keep their audio: the confirm counts the ones that
    /// may lose it (by the start in their name) as "up to".
    @Test func theAudioConfirmCountsNotesNotDownloaded() throws {
        let conversations = makeTempDir().appendingPathComponent("Conversations", isDirectory: true)
        let fm = FileManager.default
        func stub(_ day: String, _ name: String) throws {
            let dir = conversations.appendingPathComponent(day, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(name))
        }
        try stub("2026-09-01", ".09-00 Old.md.icloud")
        try stub("2026-09-01", ".09-00 Old.m4a.icloud")
        try stub("2026-09-01", ".10-00 No audio.md.icloud")
        try stub("2026-11-06", ".09-00 New.md.icloud")
        try stub("2026-11-06", "09-00 New.m4a")
        let now = try #require(ConversationNote.parse("2026-11-07", "12:00"))

        #expect(AudioRetention.notDownloaded(in: [conversations], policy: .thirtyDays, now: now) == 1)
        #expect(AudioRetention.notDownloaded(in: [conversations], policy: .deleteAfterTranscribing, now: now) == 2)
        #expect(AudioRetention.notDownloaded(in: [conversations], policy: .forever, now: now) == 0)
        let removal = AudioRetention.removal(by: .thirtyDays, in: [conversations], now: now)
        #expect(removal == AudioRetention.Removal(notes: 0, notDownloaded: 1))
        #expect(removal.upTo == 1)
    }

    // MARK: lists

    /// A note's summary ends at its header's end time, past midnight when that's before the start.
    @Test func aNoteEndsWhenItsHeaderSays() throws {
        let conversations = makeTempDir().appendingPathComponent("Conversations", isDirectory: true)
        let dir = conversations.appendingPathComponent("2026-11-06", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func note(_ name: String, _ start: String, _ end: String?) throws {
            var front = ["title: \"Standup\"", "date: 2026-11-06", "start: \"\(start)\"", "duration: 2h"]
            if let end { front.append("end: \"\(end)\"") }
            try Data(("---\n" + front.joined(separator: "\n") + "\n---\n\n# Standup\n").utf8)
                .write(to: dir.appendingPathComponent(name))
        }
        try note("07-05 Standup.md", "07:05:00", "11:00:30")
        try note("23-30 Late.md", "23:30:00", "00:15:00")
        try note("06-00 Old.md", "06:00:00", nil)

        let byID = Dictionary(uniqueKeysWithValues: NoteSummary.all(in: conversations).map { ($0.id, $0) })
        #expect(byID["2026-11-06/07-05 Standup"]?.endedAt == ConversationNote.parse("2026-11-06", "11:00:30"))
        #expect(byID["2026-11-06/23-30 Late"]?.endedAt == ConversationNote.parse("2026-11-07", "00:15:00"))
        #expect(byID["2026-11-06/06-00 Old"]?.endedAt == nil)
    }

    /// An id that isn't listed opens only that very note, never one whose name starts the same.
    @Test func aNoteIDMatchesOnlyThatNote() throws {
        let root = makeTempDir()
        let dir = root.appendingPathComponent("2026-11-06", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("09-00 Conversation 2.md"))

        #expect(NotesService.exactNote("2026-11-06/09-00 Conversation", in: root) == nil)
        #expect(NotesService.exactNote("2026-11-06/09-00 Conversation 2", in: root)?.lastPathComponent == "09-00 Conversation 2.md")
        #expect(NotesService.exactNote("../2026-11-06/09-00 Conversation 2", in: root) == nil)
        #expect(NotesService.exactNote("/etc/hosts", in: root) == nil)
        #expect(NotesService.exactNote("", in: root) == nil)
    }

    // MARK: delete

    /// Staging and the notes folder, each with the day's folder.
    struct Places {
        let staging = makeTempDir().appendingPathComponent("Conversations", isDirectory: true)
        let notes = makeTempDir().appendingPathComponent("Conversations", isDirectory: true)
        var here: URL { staging.appendingPathComponent("2026-11-06", isDirectory: true) }
        var there: URL { notes.appendingPathComponent("2026-11-06", isDirectory: true) }

        init() throws {
            try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: there, withIntermediateDirectories: true)
        }
        func write(_ dir: URL, _ name: String) throws { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }
        func names(_ dir: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) }
    }

    /// A staged note whose move was cut short after its .json went: deleting it takes what the move left there too
    /// (its words and audio, which nothing lists).
    @Test func deletingAStagedNoteTakesWhatACutShortMoveLeft() throws {
        let p = try Places()
        try p.write(p.here, "09-00 A.md")
        try p.write(p.there, "09-00 A.json")
        try p.write(p.there, "09-00 A.m4a")
        try p.write(p.there, "10-00 B.json")  // another note's

        try NotesService.deleteNote(at: p.here.appendingPathComponent("09-00 A.md"), staging: p.staging, notesFolder: p.notes)
        #expect(p.names(p.here).isEmpty)
        #expect(p.names(p.there) == ["10-00 B.json"])
    }

    /// With its .json still in staging none of it moved: files there under its name are another note's, and stay.
    /// A note that's there (its .md) is never touched either.
    @Test func deletingAStagedNoteLeavesOtherNotesThere() throws {
        let p = try Places()
        try p.write(p.here, "09-00 A.md")
        try p.write(p.here, "09-00 A.json")
        try p.write(p.there, "09-00 A.json")
        try NotesService.deleteNote(at: p.here.appendingPathComponent("09-00 A.md"), staging: p.staging, notesFolder: p.notes)
        #expect(p.names(p.here).isEmpty)
        #expect(p.names(p.there) == ["09-00 A.json"])

        try p.write(p.here, "11-00 C.md")
        try p.write(p.there, "11-00 C.md")
        try p.write(p.there, "11-00 C.json")
        try NotesService.deleteNote(at: p.here.appendingPathComponent("11-00 C.md"), staging: p.staging, notesFolder: p.notes)
        #expect(p.names(p.there) == ["09-00 A.json", "11-00 C.md", "11-00 C.json"])

        // A note that isn't anywhere still throws, and nothing there goes.
        #expect(throws: (any Error).self) {
            try NotesService.deleteNote(at: p.here.appendingPathComponent("12-00 Gone.md"), staging: p.staging, notesFolder: p.notes)
        }
        #expect(p.names(p.there).count == 3)
    }

    // MARK: titles tried

    /// The titles a foreground tried are kept by day and minute, never the note's file name (its first words), and
    /// entries an earlier build kept by name are dropped.
    @Test func titlesTriedAreKeptWithoutTheirWords() throws {
        let defaults = try #require(UserDefaults(suiteName: "sona-titles-\(UUID().uuidString)"))
        let note = URL(fileURLWithPath: "/tmp/Conversations/2026-11-06/09-05 Lunch with Sam.md")
        #expect(PhoneTitles.key(note) == "2026-11-06/09-05")
        #expect(PhoneTitles.key(URL(fileURLWithPath: "/tmp/Conversations/2026-11-06/Lunch.md")) == nil)

        defaults.set(["2026-11-05/08-00 Old words"], forKey: PhoneTitles.retriedKey)
        PhoneTitles.markRetried(note, defaults: defaults)
        #expect(defaults.stringArray(forKey: PhoneTitles.retriedKey) == ["2026-11-06/09-05"])

        defaults.set(["2026-11-05/08-00 Old words", "2026-11-06/09-05"], forKey: PhoneTitles.retriedKey)
        PhoneTitles.tidyRetried(defaults: defaults)
        #expect(defaults.stringArray(forKey: PhoneTitles.retriedKey) == ["2026-11-06/09-05"])
    }
}
