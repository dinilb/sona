import Foundation
import NotesKit
import SonaEngine
import Testing
@testable import Sona

/// Moving notes from this iPhone into the synced folder when a move is cut short or a note isn't whole yet, and the
/// folders that stay on this iPhone.
struct NotesLocationMoveTests {
    static let day = "2026-11-03"

    /// This iPhone's notes folder and the synced one, with today's folder in each (`from`, `to`).
    struct Folders {
        let local = makeTempDir(), target = makeTempDir()
        var from: URL { local.appendingPathComponent("Conversations/\(NotesLocationMoveTests.day)", isDirectory: true) }
        var to: URL { target.appendingPathComponent("Conversations/\(NotesLocationMoveTests.day)", isDirectory: true) }

        init() {
            try! FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        }

        func write(_ text: String, _ dir: URL, _ name: String) throws {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        }
        func read(_ dir: URL, _ name: String) throws -> String {
            try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        func names(_ dir: URL) -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") })
        }
        func moveNotes(_ move: (URL, URL) throws -> Void = NotesLocation.coordinatedMove) -> Int {
            NotesLocation.moveNotes(from: local, to: target, move: move)
        }
    }

    /// A mover that moves `succeeding` files, then throws (an error mid-move, or the app killed between files).
    nonisolated final class FailingMover: @unchecked Sendable {
        var left: Int
        init(succeeding: Int) { left = succeeding }
        func move(_ from: URL, _ to: URL) throws {
            guard left > 0 else { throw CocoaError(.fileWriteUnknown) }
            left -= 1
            try NotesLocation.coordinatedMove(from, to)
        }
    }

    // MARK: a move cut short (#3)

    /// The reviewer's case: the .json moved, then the m4a's move failed. The next try finishes the same note under its
    /// own name: no "2" copy without a .json that the Mac would wait on forever.
    @Test func aMoveCutShortIsFinishedUnderTheSameName() throws {
        let f = Folders()
        try f.write("note a", f.from, "09-00 First.md")
        try f.write("{\"a\":1}", f.from, "09-00 First.json")
        try f.write("audio a", f.from, "09-00 First.m4a")

        #expect(f.moveNotes(FailingMover(succeeding: 1).move) == 0)
        #expect(f.names(f.to) == ["09-00 First.json"])
        #expect(f.names(f.from) == ["09-00 First.md", "09-00 First.m4a"])

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["09-00 First.md", "09-00 First.json", "09-00 First.m4a"])
        #expect(try f.read(f.to, "09-00 First.md") == "note a")
        #expect(try f.read(f.to, "09-00 First.json") == "{\"a\":1}")
        #expect(try f.read(f.to, "09-00 First.m4a") == "audio a")
        #expect(!FileManager.default.fileExists(atPath: f.from.path))
        #expect(f.moveNotes() == 0)
    }

    /// Cut short just before the .md (the json and the m4a there): only the .md is left to move.
    @Test func aMoveCutShortBeforeTheNoteIsFinished() throws {
        let f = Folders()
        try f.write("note a", f.from, "09-00 First.md")
        try f.write("{}", f.from, "09-00 First.json")
        try f.write("audio a", f.from, "09-00 First.m4a")

        #expect(f.moveNotes(FailingMover(succeeding: 2).move) == 0)
        #expect(f.names(f.to) == ["09-00 First.json", "09-00 First.m4a"])
        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["09-00 First.md", "09-00 First.json", "09-00 First.m4a"])
        #expect(!FileManager.default.fileExists(atPath: f.from.path))
    }

    /// A copy cut short there (a file provider's move is a copy) differs from ours: ours, whole, replaces it, and a
    /// copy that did finish is dropped here.
    @Test func aCopyCutShortThereIsReplacedByOurs() throws {
        let f = Folders()
        try f.write("note a", f.from, "09-00 First.md")
        try f.write("{\"a\":1}", f.from, "09-00 First.json")
        try f.write("audio a, all of it", f.from, "09-00 First.m4a")
        try f.write("{\"a\":1}", f.to, "09-00 First.json")
        try f.write("audio a", f.to, "09-00 First.m4a")

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["09-00 First.md", "09-00 First.json", "09-00 First.m4a"])
        #expect(try f.read(f.to, "09-00 First.m4a") == "audio a, all of it")
        #expect(!FileManager.default.fileExists(atPath: f.from.path))
    }

    /// A different note took the name, and the move to "... 2" was cut short: finished as "... 2", no "... 3".
    @Test func aMoveUnderTheNextNameCutShortIsFinishedThere() throws {
        let f = Folders()
        try f.write("note c there", f.to, "11-00 Clash.md")
        try f.write("note c here", f.from, "11-00 Clash.md")
        try f.write("{\"c\":1}", f.from, "11-00 Clash.json")
        try f.write("audio c", f.from, "11-00 Clash.m4a")

        #expect(f.moveNotes(FailingMover(succeeding: 1).move) == 0)
        #expect(f.names(f.to) == ["11-00 Clash.md", "11-00 Clash 2.json"])
        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["11-00 Clash.md", "11-00 Clash 2.md", "11-00 Clash 2.json", "11-00 Clash 2.m4a"])
        #expect(try f.read(f.to, "11-00 Clash 2.md") == "note c here")
        #expect(try f.read(f.to, "11-00 Clash.md") == "note c there")
        #expect(!FileManager.default.fileExists(atPath: f.from.path))
    }

    /// The next free name is never one a note still here goes by: that name is its own to move into.
    @Test func theNextNameSkipsANoteStillHere() throws {
        let f = Folders()
        try f.write("note x there", f.to, "11-00 X.md")
        try f.write("note x here", f.from, "11-00 X.md")
        try f.write("{}", f.from, "11-00 X.json")
        try f.write("note x2 here", f.from, "11-00 X 2.md")  // no .json yet: stays

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["11-00 X.md", "11-00 X 3.md", "11-00 X 3.json"])
        #expect(f.names(f.from) == ["11-00 X 2.md"])
    }

    // MARK: only whole notes move (#4b)

    /// A WAV left beside a note (the app stopped before converting it) is made an m4a first; the WAV never moves.
    @Test func aWAVIsConvertedBeforeTheNoteMoves() throws {
        let f = Folders()
        try f.write("note w", f.from, "10-00 Wav.md")
        try f.write("{}", f.from, "10-00 Wav.json")
        try makeSpoolWAV(f.from.appendingPathComponent("10-00 Wav.wav"), seconds: 1.5)

        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["10-00 Wav.md", "10-00 Wav.json", "10-00 Wav.m4a"])
        #expect(abs(try AudioCompressor.duration(of: f.to.appendingPathComponent("10-00 Wav.m4a")) - 1.5) <= 0.1)
        #expect(!FileManager.default.fileExists(atPath: f.from.path))
    }

    /// A WAV that can't be converted keeps its note here, raw audio and all, and it's tried again next time.
    @Test func aWAVThatWontConvertStaysHere() throws {
        let f = Folders()
        try f.write("note w", f.from, "10-00 Wav.md")
        try f.write("{}", f.from, "10-00 Wav.json")
        try f.write("not audio", f.from, "10-00 Wav.wav")

        #expect(f.moveNotes() == 0)
        #expect(f.names(f.to).isEmpty)
        #expect(f.names(f.from) == ["10-00 Wav.md", "10-00 Wav.json", "10-00 Wav.wav"])
        // Tried again (and still kept) the next time.
        var tries = 0
        #expect(NotesLocation.moveNotes(from: f.local, to: f.target, move: NotesLocation.coordinatedMove) { _ in
            tries += 1
            throw CocoaError(.fileWriteOutOfSpace)
        } == 0)
        #expect(tries == 1)
        #expect(f.names(f.to).isEmpty)
    }

    /// The Mac's own audio as a WAV (never made on the iPhone, but never sent raw either).
    @Test func aMacWAVStaysHere() throws {
        let f = Folders()
        try f.write("note m", f.from, "10-00 Mac.md")
        try f.write("{}", f.from, "10-00 Mac.json")
        try f.write("audio m", f.from, "10-00 Mac.m4a")
        try f.write("raw", f.from, "10-00 Mac.mac.wav")

        #expect(f.moveNotes() == 0)
        #expect(f.names(f.to).isEmpty)
        #expect(f.names(f.from).count == 4)
    }

    /// No .json (the app was killed between the note and its words): stays until the Processor writes it again.
    @Test func aNoteWithoutItsJSONStaysHere() throws {
        let f = Folders()
        try f.write("note n", f.from, "11-00 Third.md")
        try f.write("audio n", f.from, "11-00 Third.m4a")

        #expect(f.moveNotes() == 0)
        #expect(f.names(f.to).isEmpty)
        #expect(f.names(f.from) == ["11-00 Third.md", "11-00 Third.m4a"])
        // Once it's there, it moves.
        try f.write("{}", f.from, "11-00 Third.json")
        #expect(f.moveNotes() == 1)
        #expect(f.names(f.to) == ["11-00 Third.md", "11-00 Third.json", "11-00 Third.m4a"])
    }

    /// An empty .md is a name the Processor reserved and hasn't written yet.
    @Test func anEmptyNoteStaysHere() throws {
        let f = Folders()
        try f.write("", f.from, "12-00 Empty.md")
        try f.write("{}", f.from, "12-00 Empty.json")

        #expect(f.moveNotes() == 0)
        #expect(f.names(f.to).isEmpty)
        #expect(f.names(f.from) == ["12-00 Empty.md", "12-00 Empty.json"])
    }

    /// The log names a note by its day and minute, never its title.
    @Test func theLogNamesANoteByItsTimeOnly() {
        #expect(NotesLocation.logRef(day: "2026-11-03", stem: "09-00 Lunch with Sam") == "2026-11-03/09-00")
        #expect(NotesLocation.logRef(day: "2026-11-03", stem: "Lunch") == "2026-11-03")
    }

    // MARK: what stays on this iPhone (#4a)

    @Test func theSpoolAndThisIPhonesNotesAreKeptOutOfBackups() throws {
        let root = makeTempDir()
        let spool = root.appendingPathComponent("Library/Application Support/Sona/Spool", isDirectory: true)
        let notes = root.appendingPathComponent("Documents/Sona", isDirectory: true)
        NotesService.protectPrivateFolders(spool: spool, notes: notes)

        for folder in [spool, spool.appendingPathComponent("failed", isDirectory: true), notes] {
            #expect(FileManager.default.fileExists(atPath: folder.path))
            let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true, "\(folder.lastPathComponent)")
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
            #if !targetEnvironment(simulator)
            // The simulator keeps no data protection classes (its files are the Mac's): this is checked on a phone.
            #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication, "\(folder.lastPathComponent)")
            #endif
            #expect(attributes[.posixPermissions] as? Int == 0o700)
        }
        // Again (at the next launch, after a note): no harm.
        NotesService.protectPrivateFolders(spool: spool, notes: notes)
        #expect(try notes.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    // MARK: Spool/failed tried again (#8)

    /// A spool with one recording in Spool/failed after its 3 attempts.
    static func spoolWithAFailure(_ id: String = "20261103-090000-ABCD") throws -> Spool {
        let spool = Spool(dir: makeTempDir())
        var entry = SpoolEntry(id: id, startedAt: Date())
        entry.closed = true
        entry.attempts = 3
        try makeSpoolWAV(spool.wav(id), seconds: 1)
        spool.save(entry)
        spool.fail(id)
        return spool
    }

    @MainActor @Test func aFailedRecordingComesBackWithNoAttemptsAndIsQueued() throws {
        let id = "20261103-090000-ABCD"
        let spool = try Self.spoolWithAFailure(id)
        #expect(spool.failedCount() == 1)

        let service = NotesService(spool: spool)
        #expect(service.retryFailed() == 1)
        #expect(spool.load(id)?.attempts == 0)
        #expect(FileManager.default.fileExists(atPath: spool.wav(id).path))
        #expect(spool.failedCount() == 0)
        #expect(!NotesService.isFailed(id, in: spool))
        #expect(service.queue == [id])
        #expect(service.failed == 0)
        // Nothing left to bring back.
        #expect(service.retryFailed() == 0)
        #expect(service.queue == [id])
    }

    @Test func aNewBuildTriesFailedRecordingsAgainOnce() throws {
        let id = "20261103-090000-ABCD"
        let suite = "sona-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let spool = try Self.spoolWithAFailure(id)

        #expect(NotesService.retryFailedIfNewBuild("2611030100", in: spool, defaults: defaults) == [id])
        // One more try, not three (one that still crashes the app costs one launch per build).
        #expect(spool.load(id)?.attempts == Processor.maxAttempts - 1)
        // It fails again: the same build doesn't bring it back.
        spool.fail(id)
        #expect(NotesService.retryFailedIfNewBuild("2611030100", in: spool, defaults: defaults).isEmpty)
        #expect(spool.failedCount() == 1)
        // The next build does, once.
        #expect(NotesService.retryFailedIfNewBuild("2611030200", in: spool, defaults: defaults) == [id])
        spool.fail(id)
        #expect(NotesService.retryFailedIfNewBuild("2611030200", in: spool, defaults: defaults).isEmpty)
        #expect(!NotesService.isNewBuild(nil, defaults: defaults))
    }
}
