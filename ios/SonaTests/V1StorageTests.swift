import Foundation
import NotesKit
import SonaEngine
import Testing
@testable import Sona

/// v1 storage: where notes go follows the choice (R3-1), the list reads where notes go and staging (R1-4, R3-10), and
/// the audio setting.
struct V1StorageTests {
    // MARK: where notes go follows the choice (R3-1, R1-7)

    /// A closure that says whether it was called: "On this iPhone" and "not chosen yet" never look for the container
    /// (it can block, and its answer must not matter).
    final class Called {
        var count = 0
    }

    @Test func onThisIPhoneStaysOnThisIPhoneWhenICloudAndAPickedFolderAreThere() {
        let iphone = makeTempDir(), called = Called()
        let location = NotesLocation.resolve(
            choice: .iphone, picked: { makeTempDir() }, container: { called.count += 1; return makeTempDir() },
            iphone: iphone, staging: makeTempDir())
        #expect(location.kind == .iphone)
        #expect(location.folder == iphone)
        #expect(location.waiting == nil)
        #expect(!location.reachesMac)
        #expect(location.displayName == "On this iPhone")
        #expect(called.count == 0)
    }

    @Test func nothingChosenNeverUsesTheContainer() {
        let staging = makeTempDir(), called = Called()
        let location = NotesLocation.resolve(
            choice: nil, picked: { nil }, container: { called.count += 1; return makeTempDir() }, staging: staging)
        #expect(location.kind == .local)
        #expect(location.folder == staging)
        #expect(location.waiting == nil)
        #expect(called.count == 0)
    }

    @Test func nothingChosenWithAnOlderPickedFolderKeepsIt() {
        let picked = makeTempDir()
        let location = NotesLocation.resolve(choice: nil, picked: { picked }, container: { makeTempDir() }, staging: makeTempDir())
        #expect(location.kind == .picked)
        #expect(location.folder == picked)
    }

    @Test func iCloudWinsOverAnOldPickedFolder() {
        let cloud = makeTempDir()
        let location = NotesLocation.resolve(choice: .icloud, picked: { makeTempDir() }, container: { cloud }, staging: makeTempDir())
        #expect(location.kind == .iCloudContainer)
        #expect(location.folder == cloud.appendingPathComponent("Documents", isDirectory: true))
    }

    @Test func iCloudOffWaitsInStagingAndSaysWhy() {
        let staging = makeTempDir()
        let location = NotesLocation.resolve(choice: .icloud, picked: { makeTempDir() }, container: { nil }, staging: staging)
        #expect(location.kind == .local)
        #expect(location.folder == staging)
        #expect(location.waiting == .iCloudOff)
    }

    @Test func aFolderThatCantBeReachedWaitsInStagingNotInICloud() {
        let staging = makeTempDir()
        let location = NotesLocation.resolve(choice: .folder, picked: { nil }, container: { makeTempDir() }, staging: staging)
        #expect(location.kind == .local)
        #expect(location.folder == staging)
        #expect(location.waiting == .folderUnreachable)
    }

    @Test func theOnThisIPhoneFolderIsNotStaging() {
        #expect(NotesLocation.iPhoneFolder != NotesLocation.stagingFolder)
        #expect(NotesLocation.iPhoneFolder.lastPathComponent != NotesLocation.stagingFolder.lastPathComponent)
    }

    /// Only the app's own folders need no security scope (R1-7): a folder elsewhere whose access didn't start isn't used.
    @Test func onlyTheAppsOwnFoldersNeedNoAccess() {
        #expect(PickedFolder.isInSandbox(makeTempDir()))
        #expect(!PickedFolder.isInSandbox(URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Sona")))
    }

    // MARK: the list reads where notes go and staging (R1-4, R3-10)

    static func write(
        _ dir: URL, _ stem: String, at start: Date, keepAudio: Bool = false, body: String = "Hello there."
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = "---\n"
        text += "title: \"\(stem.dropFirst(6))\"\n"
        text += "date: \(NoteWriter.dayString(start))\n"
        text += "start: \"\(NoteWriter.timeString(start, "HH:mm:ss"))\"\n"
        text += "end: \"\(NoteWriter.timeString(start.addingTimeInterval(60), "HH:mm:ss"))\"\n"
        text += "duration: 1m\n"
        text += "speakers: [\"Speaker 1\"]\n"
        if keepAudio { text += "keep_audio: true\n" }
        text += "---\n\n# \(stem.dropFirst(6))\n\n[00:00] Speaker 1: \(body)\n"
        let md = dir.appendingPathComponent("\(stem).md")
        try Data(text.utf8).write(to: md)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("\(stem).json"))
        return md
    }

    static func touch(_ url: URL) throws { try Data("x".utf8).write(to: url) }

    /// A day folder and a start time on it, `daysAgo` days back at 09:00.
    static func day(_ conversations: URL, daysAgo: Int) -> (dir: URL, start: Date) {
        let start = Calendar.current.date(
            bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(-Double(daysAgo) * 86_400))!
        return (conversations.appendingPathComponent(NoteWriter.dayString(start), isDirectory: true), start)
    }

    @Test func listsWhereNotesGoAndStagingMarkingStagedOnesNotSynced() throws {
        let destination = makeTempDir().appendingPathComponent("Conversations"), staging = makeTempDir().appendingPathComponent("Conversations")
        let there = Self.day(destination, daysAgo: 2), here = Self.day(staging, daysAgo: 1)
        let synced = try Self.write(there.dir, "09-00 Synced", at: there.start)
        try Self.touch(synced.deletingPathExtension().appendingPathExtension("m4a"))
        let staged = try Self.write(here.dir, "09-00 Staged", at: here.start)

        let notes = NoteSummary.list(destination: destination, staging: staging)
        #expect(notes.map(\.title) == ["Staged", "Synced"])  // newest first
        #expect(notes[0].isSynced == false)
        #expect(notes[0].hasAudio == false)
        #expect(notes[0].url == staged)
        #expect(notes[1].isSynced == true)
        #expect(notes[1].hasAudio == true)
        #expect(notes.allSatisfy { $0.isDownloaded })

        // While notes wait in staging (no destination), staged notes are the list.
        #expect(NoteSummary.list(destination: nil, staging: staging).map(\.title) == ["Staged"])
    }

    @Test func aNoteInBothPlacesIsListedOnceUnlessItsADifferentNote() throws {
        let destination = makeTempDir().appendingPathComponent("Conversations"), staging = makeTempDir().appendingPathComponent("Conversations")
        let there = Self.day(destination, daysAgo: 0), here = Self.day(staging, daysAgo: 0)
        // A move cut short: the same .md in both places.
        _ = try Self.write(there.dir, "09-00 Same", at: there.start)
        _ = try Self.write(here.dir, "09-00 Same", at: here.start)
        var notes = NoteSummary.list(destination: destination, staging: staging)
        #expect(notes.count == 1)
        #expect(notes.first?.isSynced == true)

        // A different note with the same name waiting in staging: both listed, ids unique.
        _ = try Self.write(here.dir, "09-00 Same", at: here.start, body: "Something else.")
        notes = NoteSummary.list(destination: destination, staging: staging)
        #expect(notes.count == 2)
        #expect(Set(notes.map(\.id)).count == 2)
        let local = try #require(notes.first { !$0.isSynced })
        #expect(local.id.hasPrefix(NoteSummary.stagedPrefix))
        #expect(local.url.path.hasPrefix(staging.path))
    }

    /// A note iCloud evicted (only `.<name>.md.icloud` is here) is still listed, from its file name.
    @Test func anEvictedNoteIsListedFromItsName() throws {
        let destination = makeTempDir().appendingPathComponent("Conversations")
        let there = Self.day(destination, daysAgo: 3)
        try FileManager.default.createDirectory(at: there.dir, withIntermediateDirectories: true)
        try Self.touch(there.dir.appendingPathComponent(".14-05 Lunch with Sam.md.icloud"))
        try Self.touch(there.dir.appendingPathComponent(".14-05 Lunch with Sam.m4a.icloud"))
        try Self.touch(there.dir.appendingPathComponent(".14-05 Lunch with Sam.json.icloud"))

        let notes = NoteSummary.all(in: destination)
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.title == "Lunch with Sam")
        #expect(note.isDownloaded == false)
        #expect(note.hasAudio)
        #expect(note.url.lastPathComponent == "14-05 Lunch with Sam.md")
        #expect(note.id == "\(there.dir.lastPathComponent)/14-05 Lunch with Sam")
        let start = try #require(note.startedAt)
        #expect(NoteWriter.timeString(start, "HH:mm") == "14:05")
        #expect(NoteWriter.dayString(start) == there.dir.lastPathComponent)
    }

    // MARK: audio setting

    @Test func whatEachSettingKeeps() {
        let now = Date()
        let old = now.addingTimeInterval(-31 * 86_400), recent = now.addingTimeInterval(-29 * 86_400)
        #expect(!AudioRetention.keeps(startedAt: old, keepAudio: false, policy: .thirtyDays, now: now))
        #expect(AudioRetention.keeps(startedAt: recent, keepAudio: false, policy: .thirtyDays, now: now))
        #expect(AudioRetention.keeps(startedAt: old, keepAudio: true, policy: .thirtyDays, now: now))
        #expect(AudioRetention.keeps(startedAt: old, keepAudio: false, policy: .forever, now: now))
        #expect(!AudioRetention.keeps(startedAt: recent, keepAudio: false, policy: .deleteAfterTranscribing, now: now))
        #expect(AudioRetention.keeps(startedAt: recent, keepAudio: true, policy: .deleteAfterTranscribing, now: now))
        // Can't tell its age: kept.
        #expect(AudioRetention.keeps(startedAt: nil, keepAudio: false, policy: .thirtyDays, now: now))
    }

    @Test func thirtyDaysDeletesOnlyOldAudioWithoutKeepAudioAndNeverTheNote() throws {
        let destination = makeTempDir().appendingPathComponent("Conversations"), staging = makeTempDir().appendingPathComponent("Conversations")
        let old = Self.day(destination, daysAgo: 40), kept = Self.day(destination, daysAgo: 45), recent = Self.day(staging, daysAgo: 5)
        let oldNote = try Self.write(old.dir, "09-00 Old", at: old.start)
        let oldAudio = oldNote.deletingPathExtension().appendingPathExtension("m4a")
        try Self.touch(oldAudio)
        let keptNote = try Self.write(kept.dir, "09-00 Kept", at: kept.start, keepAudio: true)
        let keptAudio = keptNote.deletingPathExtension().appendingPathExtension("m4a")
        try Self.touch(keptAudio)
        let recentNote = try Self.write(recent.dir, "09-00 Recent", at: recent.start)
        let recentWAV = recentNote.deletingPathExtension().appendingPathExtension("wav")
        try Self.touch(recentWAV)
        let folders = [staging, destination]

        #expect(AudioRetention.expired(in: folders, policy: .forever).isEmpty)
        #expect(AudioRetention.expired(in: folders, policy: .thirtyDays).count == 1)
        #expect(AudioRetention.expired(in: folders, policy: .deleteAfterTranscribing).count == 2)

        #expect(AudioRetention.sweep(folders, policy: .thirtyDays) == 1)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: oldAudio.path))
        #expect(fm.fileExists(atPath: oldNote.path))
        #expect(fm.fileExists(atPath: oldNote.deletingPathExtension().appendingPathExtension("json").path))
        #expect(fm.fileExists(atPath: keptAudio.path))
        #expect(fm.fileExists(atPath: recentWAV.path))
        // Again: nothing left to delete.
        #expect(AudioRetention.sweep(folders, policy: .thirtyDays) == 0)

        // Delete once transcribed: every note's audio but Keep audio's.
        #expect(AudioRetention.sweep(folders, policy: .deleteAfterTranscribing) == 1)
        #expect(!fm.fileExists(atPath: recentWAV.path))
        #expect(fm.fileExists(atPath: recentNote.path))
        #expect(fm.fileExists(atPath: keptAudio.path))
    }

    /// Audio iCloud evicted goes too (its stub with it), but never a note whose own .md isn't here to check.
    @Test func evictedAudioGoesButNotANoteThatCantBeRead() throws {
        let destination = makeTempDir().appendingPathComponent("Conversations")
        let old = Self.day(destination, daysAgo: 40)
        _ = try Self.write(old.dir, "09-00 Old", at: old.start)
        let stub = old.dir.appendingPathComponent(".09-00 Old.m4a.icloud")
        try Self.touch(stub)
        let unread = old.dir.appendingPathComponent(".10-00 Unread.md.icloud")
        try Self.touch(unread)
        let unreadAudio = old.dir.appendingPathComponent("10-00 Unread.m4a")
        try Self.touch(unreadAudio)

        #expect(AudioRetention.sweep([destination], policy: .thirtyDays) == 1)
        #expect(!FileManager.default.fileExists(atPath: stub.path))
        #expect(FileManager.default.fileExists(atPath: unreadAudio.path))
    }

    // MARK: recordings that aren't notes yet

    @MainActor @Test func retryBringsOneBackFromSpoolFailed() throws {
        let id = "20261103-090000-ABCD"
        let spool = try NotesLocationMoveTests.spoolWithAFailure(id)
        let service = NotesService(spool: spool)
        service.retry(id)
        #expect(spool.load(id)?.attempts == 0)
        #expect(spool.failedCount() == 0)
        #expect(service.queue == [id])
        #expect(service.failedIDs.isEmpty)
    }

    @MainActor @Test func aWaitingOrFailedRecordingCanBeDeleted() throws {
        let failedID = "20261103-090000-ABCD"
        let spool = try NotesLocationMoveTests.spoolWithAFailure(failedID)
        var entry = SpoolEntry(id: "20261103-100000-EFGH", startedAt: Date())
        entry.closed = true
        try makeSpoolWAV(spool.wav(entry.id), seconds: 1)
        spool.save(entry)
        let service = NotesService(spool: spool)
        service.enqueue(entry.id)

        #expect(service.deleteRecording(entry.id))
        #expect(spool.load(entry.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: spool.wav(entry.id).path))
        #expect(!service.queue.contains(entry.id))

        #expect(service.deleteRecording(failedID))
        #expect(spool.failedCount() == 0)
        #expect(!NotesService.isFailed(failedID, in: spool))

        // Never the one being recorded.
        spool.openID = "20261103-110000-IJKL"
        #expect(!service.deleteRecording("20261103-110000-IJKL"))
        spool.openID = nil
    }

    @MainActor @Test func theFailedBannersRecordingsCanBeDeleted() throws {
        let spool = try NotesLocationMoveTests.spoolWithAFailure("20261103-090000-ABCD")
        let service = NotesService(spool: spool)
        #expect(service.deleteFailedRecordings() == 1)
        #expect(spool.failedCount() == 0)
        #expect(service.failed == 0)
        #expect(service.deleteFailedRecordings() == 0)
    }
}
