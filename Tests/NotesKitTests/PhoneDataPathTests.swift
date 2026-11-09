#if os(macOS)
import XCTest

@testable import NotesKit

/// The whole path of an iPhone note to this Mac, as far as a test can go without devices: the note written the way the
/// iPhone writes it (NoteWriter, then NoteFrontMatter for what it adds after), in folders laid out like the app's own
/// iCloud container (`iCloud~com~dinilb~sona/Documents/Conversations`) and the picked `iCloud Drive/Sona`, brought over
/// by PhoneImport, then read back by the store, search and the MCP server. Temp folders only.
final class PhoneDataPathTests: XCTestCase {
    var base: URL!
    /// Stands in for `~/Library/Mobile Documents`.
    var cloud: URL { base.appendingPathComponent("Mobile Documents", isDirectory: true) }
    /// The app's own iCloud folder: its root (where `Titles` goes) and its `Conversations`.
    var containerRoot: URL { cloud.appendingPathComponent("iCloud~com~dinilb~sona/Documents", isDirectory: true) }
    var container: URL { containerRoot.appendingPathComponent("Conversations", isDirectory: true) }
    /// The folder the user picked in iCloud Drive.
    var pickedRoot: URL { cloud.appendingPathComponent("com~apple~CloudDocs/Sona", isDirectory: true) }
    var picked: URL { pickedRoot.appendingPathComponent("Conversations", isDirectory: true) }
    /// This Mac's `<notes>/Conversations`.
    var notes: URL { base.appendingPathComponent("Sona/Conversations", isDirectory: true) }
    var state: URL { base.appendingPathComponent("support/phone-import.json") }
    var logged: [String] = []
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let words = ["We", "rehearsed", "the", "pitch", "for", "Sam."]
    let audio = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sona-phone-path-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        logged = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: helpers

    /// A note exactly as the iPhone writes it: NoteWriter's `.md` and `.json` with its `source`, then the keys it adds
    /// once the note is written (`NoteFiles.updateFrontMatter`, which is NoteFrontMatter in a coordinated write), and
    /// its audio as an `.m4a`.
    @discardableResult
    func phoneNote(
        in folder: URL, at start: Date? = nil, source: String = NoteSource.iPhone, added: [String: String?] = [:],
        audio: Bool = true
    ) throws -> URL {
        let ws = words.enumerated().map { Word(word: $1, start: Double($0), end: Double($0) + 0.4, speaker: "Speaker 1") }
        let t = Transcript(
            startedAt: start ?? t0, duration: Double(words.count) + 1, text: words.joined(separator: " "), words: ws,
            turns: [Turn(speaker: "Speaker 1", start: 0, end: Double(words.count))], asrSeconds: 0.1, diarizationSeconds: 0.1,
            model: "parakeet-tdt-0.6b-v2")
        let md = try NoteWriter.write(t, to: folder, source: source)
        if !added.isEmpty { try NoteFrontMatter.update(fileAt: md, set: added) }
        if audio { try self.audio.write(to: sibling(md, "m4a")) }
        return md
    }

    /// Everything the iPhone adds to a note: its AI title, both places, Keep audio.
    let everything: [String: String?] = [
        "ai_title": "Pitch practice with Sam", "place": "4 Main St", "geo": "-27.4698,153.0251",
        "place_end": "10 Queen St", "geo_end": "-27.4710,153.0234", "keep_audio": "true",
    ]

    func sibling(_ md: URL, _ ext: String) -> URL { md.deletingPathExtension().appendingPathExtension(ext) }

    /// The same file in this Mac's notes folder.
    func mac(_ phone: URL, _ ext: String = "md") -> URL {
        notes.appendingPathComponent(phone.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent(sibling(phone, ext).lastPathComponent)
    }

    func day(_ md: URL) -> String { md.deletingLastPathComponent().lastPathComponent }
    func stem(_ md: URL) -> String { md.deletingPathExtension().lastPathComponent }
    func id(_ md: URL) -> String { day(md) + "/" + stem(md) }

    /// Like the app's run: the picked folder first, then the app's own.
    @discardableResult
    func imp() -> PhoneImport.Summary {
        PhoneImport.run(from: [picked, container], to: notes, statePath: state, log: { self.logged.append($0) })
    }

    /// The iPhone changed the note: the keys set as it sets them, and a later date (iCloud's copy is newer).
    func phoneSets(_ md: URL, _ changes: [String: String?], at seconds: Double) throws {
        try NoteFrontMatter.update(fileAt: md, set: changes)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: md.path)
    }

    /// A title in `Titles/<day>.json` beside `conversations`, as MacTitles leaves it (the others in the file kept).
    func saveMacTitle(_ title: String, for md: URL, beside conversations: URL) throws {
        let url = TitlesFile.url(forConversations: conversations, day: day(md))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var file = loadTitles(url) ?? TitlesFile()
        file.titles[stem(md)] = title
        try file.encoded().write(to: url, options: .atomic)
    }

    /// The titles file at `url` as this Mac and the iPhone read it; nil when it isn't one they read.
    func loadTitles(_ url: URL) -> TitlesFile? { (try? Data(contentsOf: url)).flatMap(TitlesFile.decode) }

    /// Every file under `root`, hidden ones too.
    func files(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { path in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDir)
            return !isDir.boolValue
        }.sorted()
    }

    // MARK: a whole note, every reader

    func testANoteAsTheiPhoneWritesItReachesTheStoreSearchAndTheMCPServer() throws {
        // One from the watch with everything, in the app's own container; one from the iPhone with nothing added, in
        // the picked folder, an hour later.
        let watch = try phoneNote(in: container, source: NoteSource.watch, added: everything)
        let phone = try phoneNote(in: picked, at: t0.addingTimeInterval(3600))
        XCTAssertTrue(watch.path.contains("iCloud~com~dinilb~sona/Documents/Conversations/\(day(watch))/"))

        let first = imp()
        XCTAssertEqual(first.imported, 2)
        XCTAssertEqual([first.updated, first.unchanged, first.waiting, first.kept], [0, 0, 0, 0])
        // Byte for byte, all three files, under the same names.
        for md in [watch, phone] {
            for ext in ["md", "json", "m4a"] {
                XCTAssertEqual(try Data(contentsOf: mac(md, ext)), try Data(contentsOf: sibling(md, ext)), "\(ext)")
            }
        }

        // Every field, as the Mac reads it.
        let store = NoteStore(root: notes)
        let w = try store.read(id(watch))
        XCTAssertEqual(w.source, "Apple Watch")
        XCTAssertEqual(w.recordedOn, "Apple Watch")
        XCTAssertEqual(w.title, "We rehearsed the pitch for Sam")
        XCTAssertEqual(w.aiTitle, "Pitch practice with Sam")
        XCTAssertEqual(w.displayTitle, "Pitch practice with Sam")
        XCTAssertEqual(w.place, "4 Main St")
        XCTAssertEqual(w.geo, "-27.4698,153.0251")
        XCTAssertEqual(w.placeEnd, "10 Queen St")
        XCTAssertEqual(w.geoEnd, "-27.4710,153.0234")
        XCTAssertEqual(w.placeText, "4 Main St → 10 Queen St")
        XCTAssertTrue(w.keepAudio)
        XCTAssertEqual(w.lines.map(\.text), ["We rehearsed the pitch for Sam."])
        XCTAssertTrue(NoteStore.keptAudio(of: mac(watch)).map(\.lastPathComponent).contains(mac(watch, "m4a").lastPathComponent))
        let p = try store.read(id(phone))
        XCTAssertEqual([p.source, p.recordedOn], ["iPhone", "iPhone"])
        XCTAssertEqual(p.displayTitle, "We rehearsed the pitch for Sam")
        XCTAssertNil(p.aiTitle)
        XCTAssertNil(p.placeText)
        XCTAssertFalse(p.keepAudio)
        // The header alone (what lists read) says the same.
        let header = try store.readHeader(url: mac(watch))
        XCTAssertEqual([header.displayTitle, header.placeText, header.recordedOn], ["Pitch practice with Sam", "4 Main St → 10 Queen St", "Apple Watch"])

        // Found by its AI title and by either place, but not by words only its transcript has.
        XCTAssertEqual(store.notesMatching("practice").map(\.id), [id(watch)])
        XCTAssertEqual(store.notesMatching("main st").map(\.id), [id(watch)])
        XCTAssertEqual(store.notesMatching("Queen").map(\.id), [id(watch)])
        XCTAssertEqual(store.notesMatching("rehearsed").map(\.id), [id(phone), id(watch)], "the first-words title, newest first")
        XCTAssertEqual(store.notesMatching("Sam rehearsed").count, 2)
        XCTAssertEqual(store.search("rehearsed").total, 2, "and its lines")

        // The MCP server: the AI title, the device and the place in each header.
        let server = MCPServer(store: store)
        let list = try server.call("list_conversations", ["from": day(watch), "to": day(phone)])
        XCTAssertTrue(list.hasPrefix("2 conversation(s):"), list)
        XCTAssertTrue(list.contains("## \(id(watch)) | Pitch practice with Sam | "), list)
        XCTAssertTrue(list.contains(" | recorded on Apple Watch | at 4 Main St → 10 Queen St"), list)
        XCTAssertTrue(list.contains("## \(id(phone)) | We rehearsed the pitch for Sam | "), list)
        XCTAssertTrue(list.contains(" | recorded on iPhone"), list)
        let read = try server.call("read_conversation", ["id": id(watch)])
        let lines = read.components(separatedBy: "\n")
        XCTAssertTrue(lines.first?.hasPrefix("## \(id(watch)) | Pitch practice with Sam | ") == true, read)
        XCTAssertTrue(lines.first?.hasSuffix(" | 1 lines | recorded on Apple Watch | at 4 Main St → 10 Queen St") == true, read)
        XCTAssertTrue(read.contains("Speaker 1: We rehearsed the pitch for Sam."), read)
        let found = try server.call("search", ["query": "Main"])
        XCTAssertTrue(found.hasPrefix("1 conversation(s) with \"Main\" in the title or place:\n## \(id(watch)) | Pitch practice with Sam | "), found)
        XCTAssertTrue(found.contains("No lines match \"Main\"."), found)
    }

    func testSearchThroughTheIndexFindsAnImportedNoteByTitleAndPlace() throws {
        try XCTSkipUnless(SearchIndex.fts5Available)
        let store = NoteStore(root: notes, indexURL: base.appendingPathComponent("support/search.sqlite"))
        let watch = try phoneNote(in: container, source: NoteSource.watch, added: everything)
        XCTAssertEqual(store.notesMatching("practice").count, 0)
        imp()
        XCTAssertEqual(store.notesMatching("practice").map(\.id), [id(watch)], "found without anything telling the index")
        XCTAssertEqual(store.notesMatching("Main").map(\.id), [id(watch)])
        XCTAssertEqual(store.notesMatching("Queen").map(\.id), [id(watch)])
        let found = try XCTUnwrap(store.notesMatching("Queen").first)
        XCTAssertEqual([found.displayTitle, found.placeText, found.recordedOn], ["Pitch practice with Sam", "4 Main St → 10 Queen St", "Apple Watch"])
        XCTAssertEqual(store.search("rehearsed").total, 1)
        let reply = try MCPServer(store: store).call("search", ["query": "practice"])
        XCTAssertTrue(reply.contains("in the title or place:\n## \(id(watch)) | Pitch practice with Sam | "), reply)
        XCTAssertTrue(reply.contains("recorded on Apple Watch | at 4 Main St → 10 Queen St"), reply)
    }

    // MARK: what the iPhone does later

    func testWhatTheiPhoneDoesLaterReachesThisMacAndNothingHereIsDeleted() throws {
        // Written with its place only: the title and Keep audio come later.
        let md = try phoneNote(in: container, added: ["place": "4 Main St", "geo": "-27.4698,153.0251"])
        XCTAssertEqual(imp().imported, 1)
        let store = NoteStore(root: notes)
        XCTAssertNil(try store.read(id(md)).aiTitle)

        // Its title, made on the iPhone after the first import.
        try phoneSets(md, ["ai_title": "Pitch practice with Sam"], at: 1_790_000_100)
        XCTAssertEqual(imp().updated, 1)
        XCTAssertEqual(try store.read(id(md)).displayTitle, "Pitch practice with Sam")
        XCTAssertEqual(store.notesMatching("practice").map(\.id), [id(md)])
        XCTAssertEqual(imp().unchanged, 1, "and then settled")

        // Keep audio on, then off again.
        try phoneSets(md, ["keep_audio": "true"], at: 1_790_000_200)
        XCTAssertEqual(imp().updated, 1)
        XCTAssertTrue(try store.read(id(md)).keepAudio)
        try phoneSets(md, ["keep_audio": nil], at: 1_790_000_300)
        XCTAssertEqual(imp().updated, 1)
        var read = try store.read(id(md))
        XCTAssertFalse(read.keepAudio)
        XCTAssertEqual([read.aiTitle, read.place], ["Pitch practice with Sam", "4 Main St"], "the rest stays")
        XCTAssertEqual(try Data(contentsOf: mac(md)), try Data(contentsOf: md))

        // The 30-day sweep takes the iPhone's audio: this Mac's copy keeps it.
        try FileManager.default.removeItem(at: sibling(md, "m4a"))
        XCTAssertEqual(imp().unchanged, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md, "m4a")), audio)

        // The iPhone deletes the note: this Mac's copy stays, whole, and nothing is said about it.
        logged = []
        for ext in ["md", "json"] { try FileManager.default.removeItem(at: sibling(md, ext)) }
        XCTAssertEqual(imp(), PhoneImport.Summary())
        XCTAssertEqual(files(notes), [day(md) + "/" + stem(md) + ".json", day(md) + "/" + stem(md) + ".m4a", day(md) + "/" + stem(md) + ".md"])
        read = try store.read(id(md))
        XCTAssertEqual([read.displayTitle, read.place, read.recordedOn], ["Pitch practice with Sam", "4 Main St", "iPhone"])
        XCTAssertEqual(logged, [])
        // And a later run brings back nothing and takes nothing away.
        XCTAssertEqual(imp(), PhoneImport.Summary())
        XCTAssertEqual(files(notes).count, 3)
    }

    // MARK: this Mac's titles (MacTitles' file)

    func testATitlesFileWrittenAsMacTitlesWritesItIsFoldedIntoThisMacsCopy() throws {
        // One note in each of the iPhone's folders, each titled by this Mac beside its own Conversations.
        let inContainer = try phoneNote(in: container)
        let inPicked = try phoneNote(in: picked, at: t0.addingTimeInterval(3600))
        try saveMacTitle("Pitch practice with Sam", for: inContainer, beside: container)
        try saveMacTitle("Sam's pitch, take two", for: inPicked, beside: picked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: containerRoot.appendingPathComponent("Titles/\(day(inContainer)).json").path))
        let phoneBytes = try Data(contentsOf: inContainer)

        XCTAssertEqual(imp().imported, 2)
        let store = NoteStore(root: notes)
        XCTAssertEqual(try store.read(id(inContainer)).displayTitle, "Pitch practice with Sam")
        XCTAssertEqual(try store.read(id(inPicked)).displayTitle, "Sam's pitch, take two")
        XCTAssertEqual(try Data(contentsOf: inContainer), phoneBytes, "the iPhone's note is never edited")
        XCTAssertNil(try NoteStore(root: container).read(url: inContainer).aiTitle)
        // Titled here, the copy still counts as untouched: a second run leaves it, and the iPhone's next change replaces it.
        XCTAssertEqual(imp().unchanged, 2)
        try phoneSets(inContainer, ["ai_title": "Pitch practice with Sam", "place": "4 Main St"], at: 1_790_000_100)
        XCTAssertEqual(imp().updated, 1)
        XCTAssertEqual(try Data(contentsOf: mac(inContainer)), try Data(contentsOf: inContainer))
        XCTAssertEqual(try store.read(id(inContainer)).place, "4 Main St")
    }

    func testATitleTheiPhoneAlreadyHasWinsOverThisMacs() throws {
        let md = try phoneNote(in: container, added: ["ai_title": "The iPhone's title"])
        try saveMacTitle("This Mac's title", for: md, beside: container)
        XCTAssertEqual(imp().imported, 1)
        XCTAssertEqual(try NoteStore(root: notes).read(id(md)).aiTitle, "The iPhone's title")
        XCTAssertEqual(try Data(contentsOf: mac(md)), try Data(contentsOf: md))
    }

    func testAMalformedTitlesFileIsIgnored() throws {
        let broken = try phoneNote(in: container)
        let later = try phoneNote(in: picked, at: t0.addingTimeInterval(3600))
        let titles = TitlesFile.url(forConversations: container, day: day(broken))
        try FileManager.default.createDirectory(at: titles.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\": 1, \"titles\": {\"\(stem(broken))\": ".utf8).write(to: titles)  // cut off
        // A later version's file is not read either.
        let future = TitlesFile.url(forConversations: picked, day: day(later))
        try FileManager.default.createDirectory(at: future.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\": 2, \"titles\": {\"\(stem(later))\": \"From the future\"}}".utf8).write(to: future)
        XCTAssertNil(loadTitles(titles))
        XCTAssertNil(loadTitles(future))

        let summary = imp()
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.waiting, 0)
        for md in [broken, later] {
            XCTAssertNil(try NoteStore(root: notes).read(id(md)).aiTitle)
            XCTAssertEqual(try Data(contentsOf: mac(md)), try Data(contentsOf: md))
        }
        // The titles files aren't notes and aren't copied.
        XCTAssertFalse(files(notes).contains { $0.contains("Titles") })
    }

    func testTitlesWhoseValuesArentStringsAreIgnored() throws {
        let md = try phoneNote(in: container)
        let titles = TitlesFile.url(forConversations: container, day: day(md))
        try FileManager.default.createDirectory(at: titles.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\": 1, \"titles\": {\"\(stem(md))\": 42}}".utf8).write(to: titles)
        XCTAssertEqual(imp().imported, 1)
        XCTAssertNil(try NoteStore(root: notes).read(id(md)).aiTitle)
    }

    // MARK: not all there

    func testAJSONWithoutItsMarkdownAndAnEvictedNoteAreNotImported() throws {
        // A partial set: the .json (and audio) came, the .md hasn't.
        let partial = try phoneNote(in: container)
        let heldMD = base.appendingPathComponent("held.md")
        try FileManager.default.moveItem(at: partial, to: heldMD)
        // Evicted by iCloud: only the hidden stub of its .md is here, beside its .json.
        let evicted = try phoneNote(in: picked, at: t0.addingTimeInterval(3600))
        let heldEvicted = base.appendingPathComponent("held-evicted.md")
        try FileManager.default.moveItem(at: evicted, to: heldEvicted)
        let stub = evicted.deletingLastPathComponent().appendingPathComponent("." + evicted.lastPathComponent + ".icloud")
        try Data("bplist00".utf8).write(to: stub)

        let first = imp()
        XCTAssertEqual(first.imported, 0)
        XCTAssertEqual(first.waiting, 1, "the evicted note waits; the .json alone isn't a note")
        XCTAssertEqual(files(notes), [])
        XCTAssertEqual(NoteStore(root: notes).conversations().count, 0)
        let list = (try? String(contentsOf: state, encoding: .utf8)) ?? ""
        XCTAssertFalse(list.contains(stem(partial)), "nor remembered as copied")
        // The stub is never copied or taken for a note.
        XCTAssertEqual(imp().imported, 0)

        // Downloaded, and the .md arrived: both come over whole.
        try FileManager.default.removeItem(at: stub)
        try FileManager.default.moveItem(at: heldEvicted, to: evicted)
        try FileManager.default.moveItem(at: heldMD, to: partial)
        let second = imp()
        XCTAssertEqual(second.imported, 2)
        XCTAssertEqual(second.waiting, 0)
        for md in [partial, evicted] {
            for ext in ["md", "json", "m4a"] {
                XCTAssertEqual(try Data(contentsOf: mac(md, ext)), try Data(contentsOf: sibling(md, ext)), ext)
            }
        }
        XCTAssertFalse(files(notes).contains { $0.hasSuffix(".icloud") })
    }

    func testAnEvictedAudioFileHoldsBackTheWholeNote() throws {
        let md = try phoneNote(in: container, added: everything, audio: false)
        let stub = md.deletingLastPathComponent().appendingPathComponent("." + sibling(md, "m4a").lastPathComponent + ".icloud")
        try Data("bplist00".utf8).write(to: stub)
        XCTAssertEqual(imp().waiting, 1)
        XCTAssertEqual(files(notes), [], "not the .md without its audio")

        try FileManager.default.removeItem(at: stub)
        try audio.write(to: sibling(md, "m4a"))
        XCTAssertEqual(imp().imported, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md, "m4a")), audio)
    }
}
#endif
