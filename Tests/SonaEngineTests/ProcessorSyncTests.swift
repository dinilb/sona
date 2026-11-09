import XCTest

@testable import SonaEngine

/// With no audio kept, the Processor flushes the note's files to disk before the recording leaves the spool.
final class ProcessorSyncTests: XCTestCase {
    /// The files are flushed and left as they were; a file that isn't there stops it (the recording stays for the
    /// retry).
    func testTheNoteIsSyncedBeforeTheSpoolGoes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = dir.appendingPathComponent("09-00 Note.md"), json = dir.appendingPathComponent("09-00 Note.json")
        try Data("note".utf8).write(to: note)
        try Data("{}".utf8).write(to: json)
        // Private like a real note: the flush still opens it.
        chmod(note.path, 0o600)

        XCTAssertNoThrow(try Processor.syncToDisk([note, json]))
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "note")
        XCTAssertEqual(try String(contentsOf: json, encoding: .utf8), "{}")
        XCTAssertThrowsError(try Processor.syncToDisk([dir.appendingPathComponent("missing.md")]))
    }
}
