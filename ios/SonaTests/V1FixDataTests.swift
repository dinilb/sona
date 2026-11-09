import Foundation
import NotesKit
import SonaEngine
import Testing
@testable import Sona

/// Review fixes for notes on disk: a delete or Keep audio that waited while its note moved acts on it where it is
/// now (#4, #8), a delete that finds nothing says so, notes kept "On this iPhone" stay listed after notes go
/// elsewhere (#5, #12), and the audio count before a stricter setting looks where the new choice puts notes (#10).
struct V1FixDataTests {
    static let day = "2026-11-03"

    /// A whole note (.md, .json, .m4a) in `<root>/Conversations/<day>/`, returning its .md.
    static func wholeNote(_ root: URL, _ stem: String, text: String = "note") throws -> URL {
        let dir = root.appendingPathComponent("Conversations/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("\(stem).md"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("\(stem).json"))
        try Data("audio".utf8).write(to: dir.appendingPathComponent("\(stem).m4a"))
        return dir.appendingPathComponent("\(stem).md")
    }

    static func names(_ dir: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") })
    }

    /// Moves staging into `target` the way `publishLocalNotes` does, keeping where each note went.
    static func publish(_ staging: URL, to target: URL) -> [String: URL] {
        var moved: [String: URL] = [:]
        NotesLocation.moveNotes(
            from: staging, to: target, move: NotesLocation.coordinatedMove,
            moved: { from, to in moved[from.standardizedFileURL.path] = to })
        return moved
    }

    // MARK: a note that moved while the delete waited (#4, #8)

    /// The reviewers' case: the row was listed from staging, the feed moved the note while the delete waited for
    /// staging, and the delete then had only the staging URL. It finds the note where it went and deletes it there.
    @Test func deleteFindsANoteThatMovedOutOfStaging() throws {
        let staging = makeTempDir(), target = makeTempDir()
        let listed = try Self.wholeNote(staging, "09-00 Private")

        let moved = Self.publish(staging, to: target)
        #expect(!FileManager.default.fileExists(atPath: listed.path))
        let now = try #require(NotesService.whereNow(listed, moved: moved))
        #expect(now.path.hasPrefix(target.path))
        #expect(now.lastPathComponent == "09-00 Private.md")

        try NoteFiles.delete(now)
        #expect(Self.names(now.deletingLastPathComponent()).isEmpty)
        // The stale staging URL itself finds nothing, and says so.
        #expect(throws: CocoaError.self) { try NoteFiles.delete(listed) }
    }

    /// A different note with the same name was already there, so this one moved as "... 2": the delete finds that
    /// one, never the other note.
    @Test func deleteFindsANoteThatMovedUnderTheNextFreeName() throws {
        let staging = makeTempDir(), target = makeTempDir()
        let other = try Self.wholeNote(target, "09-00 Hello", text: "the other note")
        let listed = try Self.wholeNote(staging, "09-00 Hello", text: "this note")

        let moved = Self.publish(staging, to: target)
        let now = try #require(NotesService.whereNow(listed, moved: moved))
        #expect(now.lastPathComponent == "09-00 Hello 2.md")

        try NoteFiles.delete(now)
        #expect(Self.names(other.deletingLastPathComponent()) == ["09-00 Hello.md", "09-00 Hello.json", "09-00 Hello.m4a"])
        #expect(try String(contentsOf: other, encoding: .utf8) == "the other note")
    }

    /// A note still where it was listed is acted on there, whatever moved before.
    @Test func aNoteStillWhereItWasListedStaysPut() throws {
        let staging = makeTempDir(), elsewhere = makeTempDir()
        let listed = try Self.wholeNote(staging, "10-00 Still here")
        let moved = [listed.standardizedFileURL.path: elsewhere.appendingPathComponent("10-00 Still here.md")]
        #expect(NotesService.whereNow(listed, moved: moved) == listed)
        #expect(NotesService.whereNow(staging.appendingPathComponent("gone.md"), moved: [:]) == nil)
    }

    @Test func deletingANoteThatIsntThereThrowsAndDeletesNothing() throws {
        let root = makeTempDir()
        let md = try Self.wholeNote(root, "11-00 Gone")
        try FileManager.default.removeItem(at: md)

        let error = #expect(throws: CocoaError.self) { try NoteFiles.delete(md) }
        #expect(error?.code == .fileNoSuchFile)
        // Its .json and audio stay: nothing is deleted on a URL whose note isn't there.
        #expect(Self.names(md.deletingLastPathComponent()) == ["11-00 Gone.json", "11-00 Gone.m4a"])
    }

    /// A note iCloud evicted (only its stub is here) still counts as there.
    @Test func anEvictedNoteCanStillBeDeleted() throws {
        let root = makeTempDir()
        let dir = root.appendingPathComponent("Conversations/\(Self.day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stub = dir.appendingPathComponent(".12-00 Away.md.icloud")
        try Data("x".utf8).write(to: stub)
        let md = dir.appendingPathComponent("12-00 Away.md")

        #expect(NoteFiles.exists(md))
        #expect(NotesService.whereNow(md, moved: [:]) == md)
        try NoteFiles.delete(md)
        #expect(!FileManager.default.fileExists(atPath: stub.path))
    }

    // MARK: notes kept "On this iPhone" after notes go elsewhere (#5, #12)

    @Test func notesKeptOnThisIPhoneStayListedNotSyncedWithUniqueIDs() throws {
        let destination = makeTempDir().appendingPathComponent("Conversations")
        let staging = makeTempDir().appendingPathComponent("Conversations")
        let kept = makeTempDir().appendingPathComponent("Conversations")
        let old = V1StorageTests.day(kept, daysAgo: 5), today = V1StorageTests.day(destination, daysAgo: 0)
        let keptNote = try V1StorageTests.write(old.dir, "09-00 From before", at: old.start)
        _ = try V1StorageTests.write(today.dir, "09-00 New", at: today.start)

        var notes = NoteSummary.list(destination: destination, staging: staging, kept: kept)
        #expect(notes.map(\.title) == ["New", "From before"])
        let listed = try #require(notes.last)
        #expect(listed.isSynced == false)
        #expect(listed.url == keptNote)
        #expect(listed.id == "\(old.dir.lastPathComponent)/09-00 From before")

        // Without `kept` (notes go "On this iPhone" now, so that folder is the destination) nothing extra shows.
        #expect(NoteSummary.list(destination: destination, staging: staging).map(\.title) == ["New"])

        // A kept note with a name that's listed already keeps a unique id.
        let clash = V1StorageTests.day(kept, daysAgo: 0)
        _ = try V1StorageTests.write(clash.dir, "09-00 New", at: clash.start, body: "Something else.")
        notes = NoteSummary.list(destination: destination, staging: staging, kept: kept)
        #expect(notes.count == 3)
        #expect(Set(notes.map(\.id)).count == 3)
        #expect(notes.contains { $0.id.hasPrefix(NoteSummary.keptPrefix) && !$0.isSynced })

        // And it can be deleted from there.
        try NoteFiles.delete(keptNote)
        notes = NoteSummary.list(destination: destination, staging: staging, kept: kept)
        #expect(!notes.contains { $0.url == keptNote })
    }

    // MARK: the audio count looks where the new choice puts notes (#10)

    /// Before v1 notes went to the iCloud container; on the first v1 launch notes wait in staging until the feed
    /// switches, so a count of staging alone missed every old note's audio.
    @Test func theAudioCountAddsWhereTheNewChoicePutsNotes() throws {
        let staging = makeTempDir().appendingPathComponent("Conversations")
        let container = makeTempDir()
        let target = NotesLocation(kind: .iCloudContainer, folder: container)
        let folders = NotesService.audioFolders([staging], adding: target)
        #expect(folders == [staging, target.conversations])
        // Once, and never for staging alone.
        #expect(NotesService.audioFolders(folders, adding: target) == folders)
        #expect(NotesService.audioFolders([staging], adding: NotesLocation(kind: .local, folder: makeTempDir())) == [staging])

        let old = V1StorageTests.day(target.conversations, daysAgo: 45)
        let md = try V1StorageTests.write(old.dir, "09-00 Old note", at: old.start)
        try V1StorageTests.touch(md.deletingPathExtension().appendingPathExtension("m4a"))
        #expect(AudioRetention.expired(in: [staging], policy: .thirtyDays).count == 0)
        #expect(AudioRetention.expired(in: folders, policy: .thirtyDays).count == 1)
    }
}
