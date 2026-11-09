import Foundation
import NotesKit

/// Edits and deletes of a note's files in any notes folder: the app's iCloud container, a picked folder or this
/// iPhone. Each goes through NSFileCoordinator, so iCloud never uploads half an edit or misses a delete. Blocking:
/// call these off the main thread.
nonisolated enum NoteFiles {
    /// Sets keys in the note's front matter (nil removes one) in one coordinated, atomic write. The coordinated read
    /// waits for a note iCloud hasn't downloaded yet. A note without front matter is left as it is.
    static func updateFrontMatter(_ note: URL, set changes: [String: String?]) throws {
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: note, options: [], writingItemAt: note, options: .forReplacing, error: &coordination
        ) { _, url in
            do { try NoteFrontMatter.update(fileAt: url, set: changes) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// Deletes the note and its own files beside it (its .json and its audio, an .m4a or a WAV not converted yet),
    /// each with a coordinated delete. The .md goes last: a delete cut short leaves the note listed, so it can be
    /// deleted again, never its words or audio without it. Throws `fileNoSuchFile` and deletes nothing when the note
    /// isn't there (neither its .md nor iCloud's stub of it): a URL from before the note moved must never pass for a
    /// delete that worked.
    static func delete(_ note: URL) throws {
        guard exists(note) else { throw CocoaError(.fileNoSuchFile) }
        let dir = note.deletingLastPathComponent(), stem = note.deletingPathExtension().lastPathComponent
        let others = NotesLocation.noteExtensions.filter { $0 != "md" }.map { dir.appendingPathComponent("\(stem).\($0)") }
        for file in others + [note] { try deleteIfThere(file) }
    }

    /// `file` is on this iPhone, or iCloud evicted it and only its hidden `.<name>.icloud` stub is here.
    static func exists(_ file: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: file.path) || fm.fileExists(atPath: stub(of: file).path)
    }

    private static func stub(of file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
    }

    /// Deletes `file` if it's there, or if iCloud evicted it (only a hidden `.<name>.icloud` stub is here): deleting it
    /// by its own name deletes it from iCloud, and the stub goes too if that left it.
    private static func deleteIfThere(_ file: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { try NotesLocation.coordinatedDelete(file) }
        let stub = stub(of: file)
        guard fm.fileExists(atPath: stub.path) else { return }
        try? NotesLocation.coordinatedDelete(file)
        if fm.fileExists(atPath: stub.path) { try NotesLocation.coordinatedDelete(stub) }
    }
}
