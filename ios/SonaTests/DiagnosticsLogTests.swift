import Foundation
import NotesKit
import Testing
@testable import Sona

/// The copy of this iPhone's log in the app's iCloud folder (`DiagnosticsLog`): what goes in it, where, and when.
/// Temp folders stand in for the log and the container.
struct DiagnosticsLogTests {
    /// Log lines like `Log.note` writes, numbered, each `width` bytes with its newline.
    private func lines(_ range: Range<Int>, width: Int = 50) -> String {
        range.map { i in
            let head = "2026-11-08T05:00:00Z [1] line \(i) "
            return head + String(repeating: "x", count: max(0, width - head.utf8.count - 1)) + "\n"
        }.joined()
    }

    private func write(_ text: String, _ url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func logs() -> (log: URL, old: URL) {
        let dir = makeTempDir()
        return (dir.appendingPathComponent("sona.log"), dir.appendingPathComponent("sona.old.log"))
    }

    @Test func goesInTheContainersDocumentsDiagnosticsFolder() {
        let cloud = makeTempDir()
        let file = DiagnosticsLog.destination(choice: .icloud, container: { cloud })
        #expect(file == cloud.appendingPathComponent("Documents/Diagnostics/iPhone.log"))
    }

    @Test func noCopyUnlessNotesGoToTheAppsICloudFolder() {
        var asked = 0
        let container: () -> URL? = {
            asked += 1
            return makeTempDir()
        }
        #expect(DiagnosticsLog.destination(choice: .iphone, container: container) == nil)
        #expect(DiagnosticsLog.destination(choice: .folder, container: container) == nil)
        #expect(DiagnosticsLog.destination(choice: nil, container: container) == nil)
        // On this iPhone, a picked folder or no choice yet never even looks for the container.
        #expect(asked == 0)
        #expect(DiagnosticsLog.destination(choice: .icloud, container: { nil }) == nil)
    }

    @Test func aShortLogIsCopiedWhole() throws {
        let (log, old) = logs()
        let text = lines(0..<10)
        try write(text, log)
        #expect(DiagnosticsLog.tail(log: log, old: old, limit: 10_000) == Data(text.utf8))
    }

    @Test func aLongLogKeepsItsNewestWholeLines() throws {
        let (log, old) = logs()
        try write(lines(0..<1000), log)  // 50 KB
        let tail = String(decoding: DiagnosticsLog.tail(log: log, old: old, limit: 1_025), as: UTF8.self)
        // 1,025 bytes reach 25 bytes into line 979: from line 980 on, whole.
        #expect(tail == lines(980..<1000))
        #expect(!tail.contains("line 979 "))
    }

    @Test func theRolledOverLogFillsInFrontWhenTheNewOneIsShort() throws {
        let (log, old) = logs()
        try write(lines(0..<100), old)
        try write(lines(100..<110), log)  // 500 bytes
        let tail = String(decoding: DiagnosticsLog.tail(log: log, old: old, limit: 1_000), as: UTF8.self)
        // 500 bytes of the old log: its last 10 lines, then the new log.
        #expect(tail == lines(90..<110))
    }

    @Test func theOldLogIsLeftOutWhenTheNewOneFillsTheCopy() throws {
        let (log, old) = logs()
        try write(lines(0..<100), old)
        try write(lines(100..<200), log)
        let tail = String(decoding: DiagnosticsLog.tail(log: log, old: old, limit: 1_000), as: UTF8.self)
        #expect(tail == lines(180..<200))
    }

    @Test func aLineStillBeingWrittenIsLeftOut() throws {
        let (log, old) = logs()
        try write(lines(0..<3) + "2026-11-08T05:00:00Z [1] half a li", log)
        #expect(DiagnosticsLog.tail(log: log, old: old) == Data(lines(0..<3).utf8))
    }

    @Test func noLogNoCopy() throws {
        let (log, old) = logs()
        let cloud = makeTempDir()
        #expect(DiagnosticsLog.tail(log: log, old: old).isEmpty)
        #expect(try DiagnosticsLog.copy(choice: .icloud, container: { cloud }, log: log, old: old) == false)
        #expect(!FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Documents/Diagnostics").path))
    }

    @Test func copiesIntoICloudAndReplacesTheLastCopy() throws {
        let (log, old) = logs()
        let cloud = makeTempDir()
        let file = cloud.appendingPathComponent("Documents/Diagnostics/iPhone.log")
        try write(lines(0..<5), log)
        #expect(try DiagnosticsLog.copy(choice: .icloud, container: { cloud }, log: log, old: old))
        #expect(try Data(contentsOf: file) == Data(lines(0..<5).utf8))

        try write(lines(0..<8), log)
        #expect(try DiagnosticsLog.copy(choice: .icloud, container: { cloud }, log: log, old: old))
        #expect(try Data(contentsOf: file) == Data(lines(0..<8).utf8))
    }

    @Test func nothingIsWrittenForOnThisIPhone() throws {
        let (log, old) = logs()
        let cloud = makeTempDir()
        try write(lines(0..<5), log)
        #expect(try DiagnosticsLog.copy(choice: .iphone, container: { cloud }, log: log, old: old) == false)
        #expect(try DiagnosticsLog.copy(choice: .folder, container: { cloud }, log: log, old: old) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cloud.path).isEmpty)
    }

    @Test func onScreenNewLinesCopyAtMostOnceAMinute() {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // Never copied this launch: at once.
        #expect(DiagnosticsLog.wait(last: nil, pending: false, now: t0) == 0)
        // 20 s after a copy: the rest of the minute.
        #expect(DiagnosticsLog.wait(last: t0, pending: false, now: t0.addingTimeInterval(20)) == 40)
        // Over a minute after: at once.
        #expect(DiagnosticsLog.wait(last: t0, pending: false, now: t0.addingTimeInterval(90)) == 0)
        // One on its way already takes these lines too.
        #expect(DiagnosticsLog.wait(last: t0, pending: true, now: t0.addingTimeInterval(90)) == nil)
    }

    /// Off screen iOS may suspend Sona any time: new lines go in seconds, not a minute (one copy for a burst).
    @Test func offScreenNewLinesCopyInSeconds() {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let soon = DiagnosticsLog.offScreenDelay
        #expect(soon < DiagnosticsLog.interval)
        #expect(DiagnosticsLog.wait(last: t0, pending: false, now: t0.addingTimeInterval(1), onScreen: false) == soon)
        #expect(DiagnosticsLog.wait(last: nil, pending: false, now: t0, onScreen: false) == soon)
        #expect(DiagnosticsLog.wait(last: t0, pending: true, now: t0, onScreen: false) == nil)
        // Whatever keeps Sona running waits a few seconds at most for its copy.
        #expect(DiagnosticsLog.flushWait <= 3)
    }

    @Test func theCopyIsAtMost256KB() throws {
        #expect(DiagnosticsLog.tailBytes == 256_000)
        let (log, old) = logs()
        try write(lines(0..<10_000, width: 50), log)  // 500 KB
        #expect(DiagnosticsLog.tail(log: log, old: old).count <= 256_000)
    }

    /// The last copy's signature outlives the launch, so a cold launch (a watch wake, a background task) with nothing
    /// new logged doesn't upload the same log again; a new line does.
    @Test func aLaunchWithNothingNewDoesntCopyAgain() throws {
        let (log, _) = logs()
        let defaults = try #require(UserDefaults(suiteName: "sona-diagnostics-\(UUID().uuidString)"))
        try write(lines(0..<5), log)
        // The copy that worked keeps the log's signature.
        DiagnosticsLog.store(DiagnosticsLog.Signature(log), in: defaults)
        // Next launch: read back, the same log needs no copy.
        let saved = DiagnosticsLog.loadSignature(from: defaults)
        #expect(saved == DiagnosticsLog.Signature(log))
        #expect(!DiagnosticsLog.needsCopy(log: log, last: saved))
        // A new line: copied.
        try write(lines(0..<6), log)
        #expect(DiagnosticsLog.needsCopy(log: log, last: saved))
        // Never copied (or the copy was deleted): copied.
        DiagnosticsLog.store(nil, in: defaults)
        #expect(DiagnosticsLog.loadSignature(from: defaults) == nil)
        #expect(DiagnosticsLog.needsCopy(log: log, last: nil))
    }

    @Test func aSignatureSurvivesBeingStored() {
        let full = DiagnosticsLog.Signature(size: 12_345, modified: Date(timeIntervalSinceReferenceDate: 800_000_123.456))
        #expect(DiagnosticsLog.Signature(stored: full.stored) == full)
        let noDate = DiagnosticsLog.Signature(size: 0, modified: nil)
        #expect(DiagnosticsLog.Signature(stored: noDate.stored) == noDate)
        #expect(DiagnosticsLog.Signature(stored: "garbage") == nil)
        #expect(DiagnosticsLog.Signature(stored: nil) == nil)
    }

    /// Notes stop going to iCloud: the copy goes from iCloud (and so from the Mac), with its folder once it's empty.
    @Test func leavingICloudDeletesTheCopy() throws {
        let (log, old) = logs()
        let cloud = makeTempDir()
        try write(lines(0..<5), log)
        #expect(try DiagnosticsLog.copy(choice: .icloud, container: { cloud }, log: log, old: old))
        let file = DiagnosticsLog.file(in: cloud)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try DiagnosticsLog.remove(from: cloud)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        // Nothing there is fine too.
        try DiagnosticsLog.remove(from: cloud)
        // Something else of ours in that folder stays.
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = file.deletingLastPathComponent().appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: other)
        #expect(try DiagnosticsLog.copy(choice: .icloud, container: { cloud }, log: log, old: old))
        try DiagnosticsLog.remove(from: cloud)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func theOldLogIsWhereLogRollsItOver() {
        let log = URL(fileURLWithPath: "/tmp/Sona/sona.log")
        #expect(DiagnosticsLog.oldLog(log).lastPathComponent == "sona.old.log")
    }
}
