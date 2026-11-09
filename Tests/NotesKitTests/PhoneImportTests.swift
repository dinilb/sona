#if os(macOS)
import XCTest

@testable import NotesKit

/// Bringing the iPhone's notes into the Mac's notes folder. The iPhone's iCloud folder is a plain temp folder here.
final class PhoneImportTests: XCTestCase {
    var base: URL!
    /// What the iPhone app wrote (in iCloud Drive, on a real Mac).
    var inbox: URL { base.appendingPathComponent("PhoneInbox", isDirectory: true) }
    /// This Mac's `<notes>/Conversations`.
    var notes: URL { base.appendingPathComponent("Notes/Conversations", isDirectory: true) }
    var state: URL { base.appendingPathComponent("support/phone-import.json") }
    var logged: [String] = []
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sona-phone-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        logged = []
    }

    override func tearDown() {
        // A test may leave a file unreadable on purpose.
        chmodAll(base, files: 0o600, folders: 0o700)
        try? FileManager.default.removeItem(at: base)
    }

    private func chmodAll(_ root: URL, files: mode_t, folders: mode_t) {
        for path in (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? [] {
            let full = root.appendingPathComponent(path).path
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            chmod(full, (st.st_mode & S_IFMT) == S_IFDIR ? folders : files)
        }
    }

    // MARK: helpers

    /// A note as the iPhone app writes it: NoteWriter's own, with `source` set; `audio` adds the kept `.m4a`.
    /// `folder`: which of the iPhone's folders it lands in (default `inbox`).
    @discardableResult
    func phoneNote(
        _ start: Date? = nil, _ words: [String] = ["Budget", "for", "the", "March", "launch."], audio: Bool = false,
        in folder: URL? = nil, source: String = "iPhone"
    ) throws -> URL {
        let ws = words.enumerated().map { Word(word: $1, start: Double($0), end: Double($0) + 0.4, speaker: "Speaker 1") }
        let t = Transcript(
            startedAt: start ?? t0, duration: Double(words.count) + 1, text: words.joined(separator: " "), words: ws,
            turns: [Turn(speaker: "Speaker 1", start: 0, end: Double(words.count))], asrSeconds: 0.1, diarizationSeconds: 0.1,
            model: "test")
        let md = try NoteWriter.write(t, to: folder ?? inbox, source: source)
        if audio { try Data([1, 2, 3, 4]).write(to: sibling(md, "m4a")) }
        return md
    }

    func sibling(_ md: URL, _ ext: String) -> URL { md.deletingPathExtension().appendingPathExtension(ext) }

    /// The same file on this Mac (in the notes folder, or in `root` when another is given).
    func mac(_ source: URL, _ ext: String = "md", in root: URL? = nil) -> URL {
        (root ?? notes).appendingPathComponent(source.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent(sibling(source, ext).lastPathComponent)
    }

    @discardableResult
    func imp(from: URL? = nil) -> PhoneImport.Summary {
        PhoneImport.run(from: from ?? inbox, to: notes, statePath: state, log: { self.logged.append($0) })
    }

    /// Into another notes folder (Settings can point Sona at one), with the same list of what was copied.
    @discardableResult
    func imp(into folder: URL) -> PhoneImport.Summary {
        PhoneImport.run(from: inbox, to: folder, statePath: state, log: { self.logged.append($0) })
    }

    /// Another notes folder, next to the first.
    var otherNotes: URL { base.appendingPathComponent("Other/Conversations", isDirectory: true) }

    /// Several folders at once, like the app's own run.
    @discardableResult
    func imp(folders: [URL]) -> PhoneImport.Summary {
        PhoneImport.run(from: folders, to: notes, statePath: state, log: { self.logged.append($0) })
    }

    /// The iPhone's other folder (the app's own iCloud folder, next to the one the user picked).
    var inbox2: URL { base.appendingPathComponent("PhoneInbox2", isDirectory: true) }

    func mode(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    /// Every file under `root`, hidden ones too.
    func files(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { path in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDir)
            return !isDir.boolValue
        }.sorted()
    }

    func setDate(_ url: URL, _ seconds: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    /// The iPhone's note changed: new text, and a later modification date.
    func change(_ url: URL, to text: String, at seconds: Double = 1_790_000_100) throws {
        try Data(text.utf8).write(to: url)
        try setDate(url, seconds)
    }

    // MARK: copying

    func testFirstImportCopiesTheNoteItsJSONAndItsAudio() throws {
        let md = try phoneNote(audio: true)
        try Data([9, 8, 7]).write(to: sibling(md, "wav"))

        let first = imp()
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual([first.updated, first.unchanged, first.skipped], [0, 0, 0])
        // Same names, same bytes: .md, .json, .m4a and .wav.
        for ext in ["md", "json", "m4a", "wav"] {
            XCTAssertEqual(try Data(contentsOf: mac(md, ext)), try Data(contentsOf: sibling(md, ext)), ext)
        }
        // And it is a note as far as the Mac is concerned, with the iPhone as its source.
        let read = NoteStore(root: notes).conversations()
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.source, "iPhone")
        XCTAssertEqual(read.first?.title, "Budget for the March launch")
        // Nothing was taken from the iPhone's folder.
        XCTAssertEqual(files(inbox).count, 4)
        XCTAssertEqual(logged, ["phone import: 1 new, 0 updated"])
    }

    /// The app's iCloud folder as the iPhone fills it: `Documents/Conversations/<day>/` for notes, and its log's copy
    /// in `Documents/Diagnostics/iPhone.log`. Only the note comes over, whether the import reads Conversations (as
    /// it does) or is pointed one folder up.
    func testTheIPhonesLogCopyIsNeverImported() throws {
        let documents = base.appendingPathComponent("Documents", isDirectory: true)
        let conversations = documents.appendingPathComponent("Conversations", isDirectory: true)
        let md = try phoneNote(in: conversations)
        let diagnostics = documents.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try Data("2026-11-08T05:00:00Z [1] recording 2026-11-08/15-45 saved: 423.2 s\n".utf8)
            .write(to: diagnostics.appendingPathComponent("iPhone.log"))

        XCTAssertEqual(imp(from: conversations).imported, 1)
        XCTAssertEqual(imp(from: documents).changed, 0)
        XCTAssertEqual(files(notes), ["md", "json"].map { "\(md.deletingLastPathComponent().lastPathComponent)/\(sibling(md, $0).lastPathComponent)" }.sorted())
    }

    func testASecondRunChangesNothing() throws {
        let md = try phoneNote(audio: true)
        imp()
        let before = ["md", "json", "m4a"].map { NoteStore.stamp(mac(md, $0)) }
        let listBefore = NoteStore.stamp(state)
        logged = []

        let second = imp()
        XCTAssertEqual(second.unchanged, 1)
        XCTAssertEqual([second.imported, second.updated, second.skipped], [0, 0, 0])
        XCTAssertEqual(second.changed, 0)
        XCTAssertEqual(["md", "json", "m4a"].map { NoteStore.stamp(mac(md, $0)) }, before, "no file written again")
        XCTAssertEqual(NoteStore.stamp(state), listBefore, "nor the list of what was copied")
        XCTAssertEqual(logged, [], "and nothing logged")
    }

    func testAChangedNoteIsCopiedAgainWhenThisMacsCopyIsUntouched() throws {
        let md = try phoneNote(audio: true)
        imp()
        let newText = try String(contentsOf: md, encoding: .utf8) + "\n[00:09] Speaker 1: A late addition.\n"
        try change(md, to: newText)
        try change(sibling(md, "json"), to: "{\"changed\": true}")
        logged = []

        let again = imp()
        XCTAssertEqual(again.updated, 1)
        XCTAssertEqual([again.imported, again.unchanged, again.skipped], [0, 0, 0])
        XCTAssertEqual(try String(contentsOf: mac(md), encoding: .utf8), newText)
        XCTAssertEqual(try String(contentsOf: mac(md, "json"), encoding: .utf8), "{\"changed\": true}")
        XCTAssertEqual(logged, ["phone import: 0 new, 1 updated"])
        // And then it is settled.
        XCTAssertEqual(imp().unchanged, 1)
    }

    func testAFileOnlyTouchedOnTheiPhoneIsNotCopiedAgain() throws {
        let md = try phoneNote()
        imp()
        let before = NoteStore.stamp(mac(md))
        try setDate(md, 1_790_000_500)  // iCloud moved its date; the bytes are the same

        let again = imp()
        XCTAssertEqual(again.unchanged, 1)
        XCTAssertEqual(again.updated, 0)
        XCTAssertEqual(NoteStore.stamp(mac(md)), before)
        XCTAssertEqual(imp().unchanged, 1)
    }

    func testAudioThatComesLaterIsAdded() throws {
        let md = try phoneNote()
        XCTAssertEqual(imp().imported, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mac(md, "m4a").path))

        try Data([5, 5, 5]).write(to: sibling(md, "m4a"))
        let again = imp()
        XCTAssertEqual(again.updated, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md, "m4a")), Data([5, 5, 5]))
    }

    // MARK: this Mac's edits

    func testANoteEditedOnThisMacKeepsTheMacsCopy() throws {
        let md = try phoneNote()
        imp()
        // A speaker renamed through the MCP server rewrites the .md and the .json here.
        let id = try XCTUnwrap(NoteStore(root: notes).names().first?.id)
        try NoteStore(root: notes).renameSpeaker(in: id, from: "Speaker 1", to: "Alex")
        let edited = try Data(contentsOf: mac(md))
        XCTAssertTrue(String(decoding: edited, as: UTF8.self).contains("Alex"))
        // The iPhone's copy changes too.
        try change(md, to: "---\ntitle: \"Rewritten on the phone\"\n---\n\n[00:00] Speaker 1: New words.\n")
        logged = []

        let again = imp()
        XCTAssertEqual(again.kept, 1)
        XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual([again.imported, again.updated, again.unchanged], [0, 0, 0])
        XCTAssertEqual(try Data(contentsOf: mac(md)), edited, "this Mac's copy stays")
        XCTAssertEqual(logged.count, 1, "and it says so")
        XCTAssertTrue(logged[0].hasPrefix("phone import: 1 note changed on the iPhone"), logged[0])

        // Said once: the next runs leave it alone, until the iPhone changes it again.
        logged = []
        XCTAssertEqual(imp().unchanged, 1)
        XCTAssertEqual(logged, [])
        try change(md, to: "---\ntitle: \"Again\"\n---\n\n[00:00] Speaker 1: Newer words.\n", at: 1_790_000_900)
        XCTAssertEqual(imp().kept, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md)), edited)
    }

    func testAnEditToTheJSONAloneKeepsTheMarkdownToo() throws {
        let md = try phoneNote()
        imp()
        let edited = Data("{\"edited\": true}".utf8)
        try edited.write(to: mac(md, "json"))
        let macMarkdown = try Data(contentsOf: mac(md))
        try change(md, to: "---\ntitle: \"New\"\n---\n\n[00:00] Speaker 1: New words.\n")

        XCTAssertEqual(imp().kept, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md)), macMarkdown, "the pair stays together")
        XCTAssertEqual(try Data(contentsOf: mac(md, "json")), edited)
    }

    func testANoteDeletedOnThisMacStaysDeleted() throws {
        let md = try phoneNote(audio: true)
        imp()
        XCTAssertTrue(NoteStore.remove(mac(md)))
        XCTAssertEqual(files(notes), [])

        // The iPhone's copy is unchanged: not copied back.
        XCTAssertEqual(imp().unchanged, 1)
        XCTAssertEqual(files(notes), [])
        // The iPhone changes it, and an audio file arrives: still not.
        try change(md, to: "---\ntitle: \"Changed\"\n---\n\n[00:00] Speaker 1: Words.\n")
        try Data([1]).write(to: sibling(md, "wav"))
        let again = imp()
        XCTAssertEqual(again.kept, 1)
        XCTAssertEqual(files(notes), [])
    }

    func testAnotherNoteWithTheSameNameIsNeverOverwritten() throws {
        // This Mac heard the same words in the same minute: its own note has the same file name.
        let words = ["Budget", "for", "the", "March", "launch."]
        let ws = words.enumerated().map { Word(word: $1, start: Double($0), end: Double($0) + 0.4, speaker: "Speaker 1") }
        let t = Transcript(
            startedAt: t0, duration: 6, text: words.joined(separator: " "), words: ws,
            turns: [Turn(speaker: "Speaker 1", start: 0, end: 5)], asrSeconds: 0.1, diarizationSeconds: 0.1, model: "test")
        let own = try NoteWriter.write(t, to: notes)
        let ownBytes = try Data(contentsOf: own)
        let md = try phoneNote()
        XCTAssertEqual(md.lastPathComponent, own.lastPathComponent)

        XCTAssertEqual(imp().imported, 1)
        XCTAssertEqual(try Data(contentsOf: own), ownBytes)
        let copied = notes.appendingPathComponent(md.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent(String(md.lastPathComponent.dropLast(3)) + " 2.md")
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: md))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling(copied, "json").path))
        XCTAssertEqual(NoteStore(root: notes).conversations().count, 2)

        // And remembered: not copied a third time.
        XCTAssertEqual(imp().unchanged, 1)
        XCTAssertEqual(NoteStore(root: notes).conversations().count, 2)
    }

    func testALostListMatchesNotesAlreadyHereInsteadOfCopyingThemTwice() throws {
        let md = try phoneNote(audio: true)
        imp()
        try FileManager.default.removeItem(at: state)

        let again = imp()
        XCTAssertEqual(again.unchanged, 1)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(files(notes).count, 3, "no second copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path), "the list is back")
        XCTAssertEqual(imp().unchanged, 1)
        _ = md
    }

    // MARK: not ready yet

    func testAMarkdownWithoutItsJSONWaitsForBoth() throws {
        let md = try phoneNote(audio: true)
        let json = sibling(md, "json")
        let held = base.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: json, to: held)

        let first = imp()
        XCTAssertEqual(first.waiting, 1)
        XCTAssertEqual(first.skipped, 1)
        XCTAssertEqual([first.imported, first.updated, first.unchanged, first.kept], [0, 0, 0, 0])
        XCTAssertEqual(files(notes), [], "not even the .md or the audio")

        try FileManager.default.moveItem(at: held, to: json)
        let second = imp()
        XCTAssertEqual(second.imported, 1)
        XCTAssertEqual(second.waiting, 0)
        XCTAssertEqual(files(notes).count, 3)
    }

    func testAnICloudPlaceholderIsSkippedUntilTheFileIsHere() throws {
        // The audio is still a placeholder (".Name.m4a.icloud"): the whole note waits.
        let md = try phoneNote()
        let audio = sibling(md, "m4a")
        let placeholder = audio.deletingLastPathComponent().appendingPathComponent("." + audio.lastPathComponent + ".icloud")
        try Data("placeholder".utf8).write(to: placeholder)
        let first = imp()
        XCTAssertEqual(first.waiting, 1)
        XCTAssertEqual(first.imported, 0)
        XCTAssertEqual(files(notes), [])

        // Downloaded: the placeholder goes, the file is there.
        try FileManager.default.removeItem(at: placeholder)
        try Data([1, 2]).write(to: audio)
        let second = imp()
        XCTAssertEqual(second.imported, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md, "m4a")), Data([1, 2]))
    }

    func testANoteWhoseMarkdownIsOnlyAPlaceholderWaits() throws {
        let md = try phoneNote()
        let held = base.appendingPathComponent("held.md")
        try FileManager.default.moveItem(at: md, to: held)
        let placeholder = md.deletingLastPathComponent().appendingPathComponent("." + md.lastPathComponent + ".icloud")
        try Data("placeholder".utf8).write(to: placeholder)

        XCTAssertEqual(imp().waiting, 1)
        XCTAssertEqual(files(notes), [])
        try FileManager.default.removeItem(at: placeholder)
        try FileManager.default.moveItem(at: held, to: md)
        XCTAssertEqual(imp().imported, 1)
    }

    func testAFileThatCantBeReadYetIsTriedAgainNextRun() throws {
        try XCTSkipIf(geteuid() == 0, "root can read anything")
        let md = try phoneNote(audio: true)
        chmod(md.path, 0o000)  // like a download that hasn't finished
        let first = imp()
        XCTAssertEqual(first.waiting, 1)
        XCTAssertEqual(first.imported, 0)
        XCTAssertEqual(files(notes), [], "nothing half-copied, no temp files left")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("couldn't copy 1 note"), logged[0])

        chmod(md.path, 0o644)
        XCTAssertEqual(imp().imported, 1)
        XCTAssertEqual(files(notes).count, 3)
    }

    func testAnUnreadableNoteIsLoggedOnceNotEveryMinute() throws {
        try XCTSkipIf(geteuid() == 0, "root can read anything")
        let md = try phoneNote()
        chmod(md.path, 0o000)
        imp()
        imp()
        imp()
        XCTAssertEqual(logged.count, 1)
    }

    // MARK: files and folders

    func testNotesAreCopiedPrivately() throws {
        let md = try phoneNote(audio: true)
        // iCloud's files are readable by others; the Mac's notes never are.
        for file in files(inbox) { chmod(inbox.appendingPathComponent(file).path, 0o644) }
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        XCTAssertEqual(imp().imported, 1)
        for ext in ["md", "json", "m4a"] { XCTAssertEqual(mode(mac(md, ext)), 0o600, ext) }
        XCTAssertEqual(mode(mac(md).deletingLastPathComponent()), 0o700, "the day folder")
        XCTAssertEqual(mode(notes), 0o700, "Conversations")
        XCTAssertEqual(mode(state), 0o600, "the list of what was copied")
        XCTAssertEqual(mode(state.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(files(notes.deletingLastPathComponent()).filter { ($0 as NSString).lastPathComponent.hasPrefix(".") }, [], "no temp files")
    }

    func testOnlyNotesInDayFoldersAreImported() throws {
        let md = try phoneNote()
        let day = md.deletingLastPathComponent()
        // Hidden files (macOS copies, temp files) and folders that aren't days.
        try Data("x".utf8).write(to: day.appendingPathComponent("._" + md.lastPathComponent))
        try Data("x".utf8).write(to: day.appendingPathComponent(".hidden.md"))
        try Data("x".utf8).write(to: day.appendingPathComponent("readme.txt"))
        let other = inbox.appendingPathComponent("not-a-day")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("a.md"))
        try Data("x".utf8).write(to: other.appendingPathComponent("a.json"))
        // A symlink is never followed.
        let target = base.appendingPathComponent("secret.md")
        try Data("secret".utf8).write(to: target)
        try Data("{}".utf8).write(to: base.appendingPathComponent("secret.json"))
        try FileManager.default.createSymbolicLink(at: day.appendingPathComponent("link.md"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: day.appendingPathComponent("link.json"), withDestinationURL: base.appendingPathComponent("secret.json"))

        let summary = imp()
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(files(notes).count, 2)
    }

    func testNoPhoneFolderMeansNothingHappens() throws {
        let summary = imp(from: base.appendingPathComponent("nowhere"))
        XCTAssertEqual(summary, PhoneImport.Summary())
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.path), "no folders made for nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testTheNotesFolderItselfIsNotImportedFrom() throws {
        try phoneNote()
        let summary = PhoneImport.run(from: inbox, to: inbox, statePath: state, log: { self.logged.append($0) })
        XCTAssertEqual(summary, PhoneImport.Summary())
        XCTAssertEqual(files(inbox).count, 2)
    }

    func testOneImportAtATime() throws {
        try phoneNote()
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(state.path + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { close(fd) }

        let busy = imp()
        XCTAssertTrue(busy.busy)
        XCTAssertEqual(busy.imported, 0)
        XCTAssertEqual(files(notes), [])

        flock(fd, LOCK_UN)
        XCTAssertEqual(imp().imported, 1)
    }

    // MARK: what a stopped import leaves behind

    /// A hidden temp file as an import that was killed halfway leaves it in a day folder, `minutes` old.
    @discardableResult
    func leftover(_ name: String = ".1A2B3C4D.phone-import.tmp", in dir: URL, minutes: Double) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("half a note".utf8).write(to: url)
        age(url, minutes: minutes)
        return url
    }

    /// Dates the file itself (not what a link points to) `minutes` ago.
    func age(_ url: URL, minutes: Double) {
        let seconds = Int(Date().timeIntervalSince1970 - minutes * 60)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        lutimes(url.path, &times)
    }

    /// Whether anything (a link too) is at `url`.
    func present(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    func testTempCopiesLeftByAStoppedImportAreRemovedOnceTheyAreOldEnough() throws {
        let md = try phoneNote()
        let day = mac(md).deletingLastPathComponent()
        let old = try leftover(".1A2B3C4D.phone-import.tmp", in: day, minutes: 60)
        let older = try leftover(".5E6F7A8B.phone-import.tmp", in: day, minutes: 60 * 24)
        let fresh = try leftover(".9C8D7E6F.phone-import.tmp", in: day, minutes: 0.5)  // a copy that may be going on now

        let first = imp()
        XCTAssertEqual(first.imported, 1, "the import itself is as always")
        XCTAssertFalse(present(old))
        XCTAssertFalse(present(older))
        XCTAssertTrue(present(fresh), "a copy that may still be going is left alone")
        XCTAssertEqual(
            logged, ["phone import: cleared 2 half-copied files left by an import that was stopped", "phone import: 1 new, 0 updated"])
        XCTAssertTrue(present(mac(md)))
        XCTAssertTrue(present(mac(md, "json")))

        // Said once; and the fresh one goes when it has been there long enough.
        logged = []
        imp()
        XCTAssertEqual(logged, [])
        XCTAssertTrue(present(fresh))
        age(fresh, minutes: 30)
        imp()
        XCTAssertFalse(present(fresh))
        XCTAssertEqual(logged, ["phone import: cleared 1 half-copied file left by an import that was stopped"])
    }

    func testOnlyTheImportersOwnTempFilesAreRemoved() throws {
        let md = try phoneNote()
        let day = mac(md).deletingLastPathComponent()
        let mine = try leftover(".7F7F7F7F.phone-import.tmp", in: day, minutes: 600)
        // Everything else stays, however old: other names, other places.
        let others = [
            try leftover(".7F7F7F7F.tmp", in: day, minutes: 600),  // not this importer's name
            try leftover(".7F7F7F7F.phone-import.tmp.bak", in: day, minutes: 600),
            try leftover("7F7F7F7F.phone-import.tmp", in: day, minutes: 600),  // not hidden
            try leftover(".7F7F7F7.phone-import.tmp", in: day, minutes: 600),  // 7 characters, not 8
            try leftover(".7F7F7F7F7.phone-import.tmp", in: day, minutes: 600),  // 9
            try leftover(".NOTHEXAD.phone-import.tmp", in: day, minutes: 600),  // not hex
            try leftover(".07-30 Budget.md.7F7F7F7F.tmp", in: day, minutes: 600),  // a note being written has one like this
            try leftover("Budget.phone-import.tmp", in: day, minutes: 600),
            try leftover(in: notes, minutes: 600),  // the right name, but not in a day folder
            try leftover(in: notes.appendingPathComponent("not-a-day"), minutes: 600),
            try leftover(in: md.deletingLastPathComponent(), minutes: 600),  // the iPhone's own folder is never touched
        ]
        // A link with the right name isn't a plain file: it stays, and so does what it points at.
        let target = base.appendingPathComponent("target.txt")
        try Data("not a temp file".utf8).write(to: target)
        let link = day.appendingPathComponent(".AAAA1111.phone-import.tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        age(link, minutes: 600)

        imp()
        XCTAssertFalse(present(mine))
        for url in others + [link, target] { XCTAssertTrue(present(url), url.path) }
        XCTAssertEqual(logged.first, "phone import: cleared 1 half-copied file left by an import that was stopped")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "not a temp file")
    }

    func testNothingIsRemovedWhileAnotherImportIsRunning() throws {
        let md = try phoneNote()
        imp()
        let old = try leftover(in: mac(md).deletingLastPathComponent(), minutes: 600)
        let fd = open(state.path + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { close(fd) }

        XCTAssertTrue(imp().busy)
        XCTAssertTrue(present(old), "that import may be writing one like it")

        flock(fd, LOCK_UN)
        imp()
        XCTAssertFalse(present(old))
    }

    func testTheNameTheImporterGivesATempFileIsTheNameItClearsAgain() {
        for _ in 0..<100 {
            let name = PhoneImport.tempName()
            XCTAssertTrue(PhoneImport.isTempName(name), name)
        }
        XCTAssertFalse(PhoneImport.isTempName(""))
        XCTAssertFalse(PhoneImport.isTempName(".phone-import.tmp"))
    }

    // MARK: the list of what was copied

    func testAListThatCantBeReadIsStartedAgainWithoutCopyingNotesTwice() throws {
        try phoneNote(audio: true)
        imp()
        try Data("not json".utf8).write(to: state)
        logged = []

        let again = imp()
        XCTAssertEqual(again.unchanged, 1, "the note already here is recognised")
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(files(notes).count, 3)
        XCTAssertEqual(logged, ["phone import: its list of copied notes can't be read, so it starts a new one"])
        // The new list is a good one.
        logged = []
        XCTAssertEqual(imp().unchanged, 1)
        XCTAssertEqual(logged, [])
    }

    func testALongFirstImportCopiesEverythingAndRemembersIt() throws {
        for i in 0..<30 {
            try phoneNote(t0.addingTimeInterval(Double(i) * 120), ["Note", "number", "\(i)", "here", "now."], audio: i % 2 == 0)
        }
        let first = imp()
        XCTAssertEqual(first.imported, 30)
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(NoteStore(root: notes).conversations().count, 30)
        XCTAssertEqual(files(notes).filter { $0.hasSuffix(".m4a") }.count, 15)

        let list = try JSONDecoder().decode(PhoneImport.State.self, from: Data(contentsOf: state))
        XCTAssertEqual(list.notes.count, 30)
        let second = imp()
        XCTAssertEqual(second.unchanged, 30)
        XCTAssertEqual(second.changed, 0)
    }

    // MARK: the notes folder changes

    func testAnotherNotesFolderGetsTheNotesThatWereCopiedIntoTheOldOne() throws {
        let md = try phoneNote(audio: true)
        XCTAssertEqual(imp().imported, 1)
        logged = []

        // Settings points Sona at another notes folder. The list says this note was copied, but into the old folder.
        let moved = imp(into: otherNotes)
        XCTAssertEqual(moved.imported, 1)
        XCTAssertEqual([moved.updated, moved.unchanged, moved.skipped], [0, 0, 0])
        for ext in ["md", "json", "m4a"] {
            XCTAssertEqual(try Data(contentsOf: mac(md, ext, in: otherNotes)), try Data(contentsOf: sibling(md, ext)), ext)
        }
        XCTAssertEqual(files(notes).count, 3, "the old folder is left as it was")
        XCTAssertEqual(logged.count, 2)
        XCTAssertTrue(logged.first?.hasPrefix("phone import: the notes folder changed") == true, "\(logged)")
        XCTAssertEqual(logged.last, "phone import: 1 new, 0 updated")

        // The new folder is remembered: it is settled, nothing is said again, and a note deleted there stays deleted.
        logged = []
        XCTAssertEqual(imp(into: otherNotes).unchanged, 1)
        XCTAssertEqual(logged, [])
        let list = try JSONDecoder().decode(PhoneImport.State.self, from: Data(contentsOf: state))
        XCTAssertEqual(list.destination, otherNotes.standardizedFileURL.path)
        XCTAssertTrue(NoteStore.remove(mac(md, in: otherNotes)))
        XCTAssertEqual(imp(into: otherNotes).unchanged, 1)
        XCTAssertEqual(files(otherNotes), [])

        // And back to the first folder: its notes are recognised by what they say, not copied a second time.
        let back = imp(into: notes)
        XCTAssertEqual(back.unchanged, 1)
        XCTAssertEqual(back.imported, 0)
        XCTAssertEqual(files(notes).count, 3)
    }

    func testAListWrittenBeforeTheFolderWasRecordedIsKeptAndGainsIt() throws {
        let md = try phoneNote()
        imp()
        // Lists from before the folder was recorded don't have it.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        XCTAssertNotNil(json["destination"], "the list records its folder")
        json["destination"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: state)
        // The note was deleted here since: the list still knows.
        XCTAssertTrue(NoteStore.remove(mac(md)))
        logged = []

        let again = imp()
        XCTAssertEqual(again.unchanged, 1)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(files(notes), [], "it stays deleted")
        XCTAssertEqual(logged, [], "and nothing is said")
        let list = try JSONDecoder().decode(PhoneImport.State.self, from: Data(contentsOf: state))
        XCTAssertEqual(list.destination, notes.standardizedFileURL.path, "now it has the folder")
        XCTAssertEqual(list.notes.count, 1)
    }

    func testTheSameNotesFolderSpelledAnotherWayIsNotAChange() throws {
        let md = try phoneNote()
        imp()
        XCTAssertTrue(NoteStore.remove(mac(md)))
        logged = []

        let spelled = URL(fileURLWithPath: base.path + "/Notes/../Notes/./Conversations/", isDirectory: true)
        let again = PhoneImport.run(from: inbox, to: spelled, statePath: state, log: { self.logged.append($0) })
        XCTAssertEqual(again.unchanged, 1)
        XCTAssertEqual(files(notes), [], "the list still knows it was deleted")
        XCTAssertEqual(logged, [])
    }

    // MARK: logs

    func testTheLogHasCountsOnly() throws {
        let md = try phoneNote(t0, ["Confidential", "merger", "talks", "with", "Acme."], audio: true)
        imp()
        let id = try XCTUnwrap(NoteStore(root: notes).names().first?.id)
        try NoteStore(root: notes).renameSpeaker(in: id, from: "Speaker 1", to: "Alex")
        try change(md, to: "---\ntitle: \"Merger\"\n---\n\n[00:00] Speaker 1: Acme.\n")
        imp()
        try phoneNote(t0.addingTimeInterval(3600), ["Another", "private", "chat", "about", "salaries."])
        chmod(sibling(try phoneNote(t0.addingTimeInterval(7200), ["Unreadable", "hiring", "plans", "for", "May."]), "md").path, 0o000)
        imp()

        XCTAssertGreaterThanOrEqual(logged.count, 3)
        for line in logged {
            XCTAssertTrue(line.hasPrefix("phone import: "), line)
            for secret in ["Confidential", "merger", "Acme", "salaries", "hiring", "Alex", ".md", ".json", ".m4a", "/"] {
                XCTAssertFalse(line.localizedCaseInsensitiveContains(secret), "\(secret) in: \(line)")
            }
        }
    }

    // MARK: where from

    func testTheDefaultSourcesAreTheiPhoneAppsTwoICloudFoldersOrTheTestHomesInbox() throws {
        let previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        defer { if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") } }

        // The folder the user picked comes first, then the app's own.
        unsetenv("SONA_HOME")
        let real = PhoneImport.defaultSources.map(\.path)
        XCTAssertEqual(real.count, 2)
        XCTAssertTrue(real[0].hasSuffix("/Library/Mobile Documents/com~apple~CloudDocs/Sona/Conversations"), real[0])
        XCTAssertTrue(real[1].hasSuffix("/Library/Mobile Documents/iCloud~com~dinilb~sona/Documents/Conversations"), real[1])

        // In a test home it never reaches the real ones.
        setenv("SONA_HOME", base.path, 1)
        XCTAssertEqual(PhoneImport.defaultSources.map(\.path), [base.appendingPathComponent("PhoneInbox").path])
        XCTAssertEqual(PhoneImport.defaultStatePath.path, base.appendingPathComponent("phone-import.json").path)
    }

    func testEveryFolderThatExistsIsReadAndTheFirstWinsForANoteInBoth() throws {
        // A is only in the first, B only in the second. C is in both, written differently in each.
        let a = try phoneNote(t0, ["Alpha", "notes", "from", "the", "picked", "folder."], in: inbox)
        let b = try phoneNote(t0.addingTimeInterval(3600), ["Bravo", "notes", "from", "the", "app", "folder."], audio: true, in: inbox2)
        let c1 = try phoneNote(t0.addingTimeInterval(7200), ["Charlie", "was", "heard", "by", "both."], in: inbox, source: "iPhone")
        let c2 = try phoneNote(t0.addingTimeInterval(7200), ["Charlie", "was", "heard", "by", "both."], in: inbox2, source: "Apple Watch")
        XCTAssertEqual(c1.lastPathComponent, c2.lastPathComponent)
        XCTAssertNotEqual(try Data(contentsOf: c1), try Data(contentsOf: c2))
        let missing = base.appendingPathComponent("not-synced-yet")

        let first = imp(folders: [missing, inbox, inbox2])
        XCTAssertEqual(first.imported, 3)
        XCTAssertEqual(first.unchanged, 1, "C's second copy")
        XCTAssertEqual([first.updated, first.skipped], [0, 0])
        XCTAssertEqual(try Data(contentsOf: mac(a)), try Data(contentsOf: a))
        XCTAssertEqual(try Data(contentsOf: mac(b, "m4a")), Data([1, 2, 3, 4]))
        XCTAssertEqual(try Data(contentsOf: mac(c1)), try Data(contentsOf: c1), "from the first folder")
        XCTAssertEqual(NoteStore(root: notes).conversations().count, 3)
        XCTAssertEqual(logged, ["phone import: 3 new, 0 updated"])

        // Nothing more to do, and the same count again.
        logged = []
        let second = imp(folders: [missing, inbox, inbox2])
        XCTAssertEqual(second.unchanged, 4)
        XCTAssertEqual(second.changed, 0)
        XCTAssertEqual(logged, [])
    }

    // MARK: the same note in both folders: the copy that is all there

    /// The same note (same file name) in both of the iPhone's folders, written differently so that which one was copied
    /// shows: the picked folder's says "iPhone", the app's own says "Apple Watch". `hours` makes another note.
    func inBoth(_ words: [String], hours: Double = 0, audio: Bool = false) throws -> (picked: URL, own: URL) {
        let start = t0.addingTimeInterval(hours * 3600)
        let picked = try phoneNote(start, words, audio: audio, in: inbox, source: "iPhone")
        let own = try phoneNote(start, words, audio: audio, in: inbox2, source: "Apple Watch")
        XCTAssertEqual(picked.lastPathComponent, own.lastPathComponent)
        XCTAssertNotEqual(try Data(contentsOf: picked), try Data(contentsOf: own))
        return (picked, own)
    }

    func testACopyWithoutItsJSONDoesNotHoldBackTheOtherFoldersWholeOne() throws {
        let (picked, own) = try inBoth(["Delta", "came", "in", "pieces."])
        let held = base.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: sibling(picked, "json"), to: held)  // not here yet

        let first = imp(folders: [inbox, inbox2])
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(first.waiting, 0, "it isn't waiting for the first folder's .json")
        XCTAssertEqual(first.unchanged, 1, "the first folder's copy counts like any second copy")
        XCTAssertEqual(try Data(contentsOf: mac(own)), try Data(contentsOf: own), "from the folder that has all of it")
        XCTAssertEqual(try Data(contentsOf: mac(own, "json")), try Data(contentsOf: sibling(own, "json")))
        XCTAssertEqual(NoteStore(root: notes).conversations().first?.source, "Apple Watch")

        // Once the first folder has all of it too, it is the first again (as the iPhone changing the note).
        try FileManager.default.moveItem(at: held, to: sibling(picked, "json"))
        let later = imp(folders: [inbox, inbox2])
        XCTAssertEqual(later.updated, 1)
        XCTAssertEqual(try Data(contentsOf: mac(picked)), try Data(contentsOf: picked))
        XCTAssertEqual(NoteStore(root: notes).conversations().count, 1, "still one note")
    }

    func testACopyStillComingFromICloudDoesNotHoldBackTheOtherFoldersWholeOne() throws {
        let (picked, own) = try inBoth(["Echo", "waited", "for", "the", "audio."], audio: true)
        // The first folder's audio is only a placeholder so far.
        let audio = sibling(picked, "m4a")
        try FileManager.default.removeItem(at: audio)
        try Data("placeholder".utf8).write(
            to: audio.deletingLastPathComponent().appendingPathComponent("." + audio.lastPathComponent + ".icloud"))

        let summary = imp(folders: [inbox, inbox2])
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.waiting, 0)
        XCTAssertEqual(try Data(contentsOf: mac(own)), try Data(contentsOf: own))
        XCTAssertEqual(try Data(contentsOf: mac(own, "m4a")), Data([1, 2, 3, 4]))
    }

    func testACopyThatCantBeReadYetDoesNotHoldBackTheOtherFoldersWholeOne() throws {
        try XCTSkipIf(geteuid() == 0, "root can read anything")
        // One note whose first-folder .md can't be read yet, and one whose first-folder audio can't.
        let a = try inBoth(["Foxtrot", "was", "locked."], audio: true)
        let b = try inBoth(["Golf", "had", "a", "locked", "recording."], hours: 1, audio: true)
        chmod(a.picked.path, 0o000)
        chmod(sibling(b.picked, "m4a").path, 0o000)

        let summary = imp(folders: [inbox, inbox2])
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.waiting, 0)
        XCTAssertEqual(summary.unchanged, 2)
        XCTAssertEqual(logged, ["phone import: 2 new, 0 updated"], "nothing was tried from the locked copies")
        for note in [a, b] {
            for ext in ["md", "json", "m4a"] {
                XCTAssertEqual(try Data(contentsOf: mac(note.own, ext)), try Data(contentsOf: sibling(note.own, ext)), ext)
            }
        }
    }

    func testWhenNeitherCopyIsWholeTheFirstFolderWaitsUntilOneIs() throws {
        let (picked, own) = try inBoth(["Hotel", "was", "half", "here", "twice."])
        let heldPicked = base.appendingPathComponent("held-picked.json")
        let heldOwn = base.appendingPathComponent("held-own.json")
        try FileManager.default.moveItem(at: sibling(picked, "json"), to: heldPicked)
        try FileManager.default.moveItem(at: sibling(own, "json"), to: heldOwn)

        let none = imp(folders: [inbox, inbox2])
        XCTAssertEqual(none.waiting, 1)
        XCTAssertEqual([none.imported, none.updated, none.kept], [0, 0, 0])
        XCTAssertEqual(files(notes), [], "nothing half-copied from either")

        // The second folder's .json comes first: that copy is whole, so that one is taken.
        try FileManager.default.moveItem(at: heldOwn, to: sibling(own, "json"))
        let second = imp(folders: [inbox, inbox2])
        XCTAssertEqual(second.imported, 1)
        XCTAssertEqual(second.waiting, 0)
        XCTAssertEqual(try Data(contentsOf: mac(own)), try Data(contentsOf: own))
    }

    func testTheFirstWholeCopyWinsAmongSeveralFolders() throws {
        let inbox3 = base.appendingPathComponent("PhoneInbox3", isDirectory: true)
        let words = ["India", "was", "in", "three", "places."]
        let a = try phoneNote(t0, words, in: inbox, source: "iPhone")
        let b = try phoneNote(t0, words, in: inbox2, source: "Apple Watch")
        let c = try phoneNote(t0, words, in: inbox3, source: "iPad")
        try FileManager.default.removeItem(at: sibling(a, "json"))  // the first isn't all there

        let summary = imp(folders: [inbox, inbox2, inbox3])
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.unchanged, 2)
        XCTAssertEqual(try Data(contentsOf: mac(b)), try Data(contentsOf: b), "the first one that has all of it")
        XCTAssertNotEqual(try Data(contentsOf: mac(b)), try Data(contentsOf: c))
    }

    func testAFolderThatAppearsLaterIsPickedUp() throws {
        let a = try phoneNote(t0, ["Alpha", "notes", "from", "the", "picked", "folder."], in: inbox)
        XCTAssertEqual(imp(folders: [inbox, inbox2]).imported, 1, "the second folder isn't there")
        let b = try phoneNote(t0.addingTimeInterval(3600), ["Bravo", "notes", "from", "the", "app", "folder."], in: inbox2)
        let again = imp(folders: [inbox, inbox2])
        XCTAssertEqual(again.imported, 1)
        XCTAssertEqual(again.unchanged, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mac(a).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mac(b).path))
    }

    func testNoFolderThereMeansNothingHappens() throws {
        let summary = imp(folders: [base.appendingPathComponent("one"), base.appendingPathComponent("two")])
        XCTAssertEqual(summary, PhoneImport.Summary())
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    // MARK: search and the audio that goes with a note

    func testSearchSeesImportedAndUpdatedNotes() throws {
        try XCTSkipUnless(SearchIndex.fts5Available)
        let store = NoteStore(root: notes, indexURL: base.appendingPathComponent("search.sqlite"))
        XCTAssertEqual(store.search("launch").total, 0)

        let md = try phoneNote()
        imp()
        XCTAssertEqual(store.search("launch").total, 1, "found without anything telling the index")

        let text = try String(contentsOf: md, encoding: .utf8).replacingOccurrences(of: "launch.", with: "zeppelin.")
        try change(md, to: text)
        XCTAssertEqual(imp().updated, 1)
        XCTAssertEqual(store.search("zeppelin").total, 1)
        XCTAssertEqual(store.search("launch").total, 0)
    }

    func testKeptAudioIncludesTheiPhonesM4A() throws {
        let md = try phoneNote(audio: true)
        imp()
        let copied = mac(md)
        XCTAssertEqual(
            NoteStore.keptAudio(of: copied).map(\.lastPathComponent).sorted(),
            [sibling(copied, "m4a"), sibling(copied, "mac.wav"), sibling(copied, "wav")].map(\.lastPathComponent).sorted())
        // Deleting the note deletes its recording too.
        XCTAssertEqual(files(notes).count, 3)
        XCTAssertTrue(NoteStore.remove(copied))
        XCTAssertEqual(files(notes), [])
    }
}
#endif
