import Foundation
import NotesKit
import Testing
@testable import Sona

/// A temp folder per test, never the app's own folders.
func makeTempDir(_ name: String = #function) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sona-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct NotesLocationTests {
    @Test func waitsInStagingWithNoChoiceAndNoPickedFolder() {
        let local = makeTempDir().appendingPathComponent("Sona", isDirectory: true)
        let location = NotesLocation.resolve(choice: nil, picked: { nil }, container: { nil }, staging: local)
        #expect(location.kind == .local)
        #expect(location.folder == local)
        #expect(location.waiting == nil)
        #expect(location.conversations == local.appendingPathComponent("Conversations", isDirectory: true))
        #expect(location.displayName == "On this iPhone")
    }

    @Test func usesTheICloudContainersDocuments() {
        let cloud = makeTempDir()
        let location = NotesLocation.resolve(choice: .icloud, picked: { nil }, container: { cloud }, staging: makeTempDir())
        #expect(location.kind == .iCloudContainer)
        #expect(location.folder == cloud.appendingPathComponent("Documents", isDirectory: true))
    }

    @Test func aPickedFolderForTheFolderChoice() {
        let picked = makeTempDir()
        let location = NotesLocation.resolve(choice: .folder, picked: { picked }, container: { makeTempDir() }, staging: makeTempDir())
        #expect(location.kind == .picked)
        #expect(location.folder == picked)
    }

    @Test func pickedFolderBookmarkRoundTrips() throws {
        let folder = makeTempDir()
        let file = makeTempDir().appendingPathComponent("notes-folder.bookmark")
        #expect(PickedFolder.resolve(from: file) == nil)
        try PickedFolder.save(folder, to: file)
        let back = try #require(PickedFolder.resolve(from: file))
        #expect(back.standardizedFileURL.resolvingSymlinksInPath().path == folder.standardizedFileURL.resolvingSymlinksInPath().path)
        PickedFolder.forget(file)
        #expect(PickedFolder.resolve(from: file) == nil)
    }

    /// Notes written on this iPhone move with all their files; none lost, none doubled.
    @Test func movesLocalNotesWithoutLosingOrDoublingAny() throws {
        let local = makeTempDir(), target = makeTempDir()
        let day = "2026-11-02"
        let from = local.appendingPathComponent("Conversations/\(day)", isDirectory: true)
        let to = target.appendingPathComponent("Conversations/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        func write(_ text: String, _ dir: URL, _ name: String) throws { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
        // A new note with its words and audio.
        try write("note a", from, "09-00 First.md")
        try write("{}", from, "09-00 First.json")
        try write("audio", from, "09-00 First.m4a")
        // The same note already there (an earlier move cut short): ours goes, nothing doubles.
        try write("note b", from, "10-00 Same.md")
        try write("note b", to, "10-00 Same.md")
        try write("{\"b\":1}", from, "10-00 Same.json")
        // A different note under the same name: moves as "... 2".
        try write("note c here", from, "11-00 Clash.md")
        try write("{\"c\":1}", from, "11-00 Clash.json")
        try write("note c there", to, "11-00 Clash.md")

        let moved = NotesLocation.moveNotes(from: local, to: target, move: NotesLocation.coordinatedMove)
        #expect(moved == 3)

        let there = Set(try FileManager.default.contentsOfDirectory(atPath: to.path))
        #expect(there == [
            "09-00 First.md", "09-00 First.json", "09-00 First.m4a", "10-00 Same.md", "10-00 Same.json",
            "11-00 Clash.md", "11-00 Clash 2.md", "11-00 Clash 2.json",
        ])
        #expect(try String(contentsOf: to.appendingPathComponent("11-00 Clash 2.md"), encoding: .utf8) == "note c here")
        #expect(try String(contentsOf: to.appendingPathComponent("11-00 Clash.md"), encoding: .utf8) == "note c there")
        // The local day folder is empty, so it's gone.
        #expect(!FileManager.default.fileExists(atPath: from.path))
        // Running it again changes nothing.
        #expect(NotesLocation.moveNotes(from: local, to: target, move: NotesLocation.coordinatedMove) == 0)
    }
}
