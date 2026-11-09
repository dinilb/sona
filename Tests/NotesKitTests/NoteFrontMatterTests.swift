import XCTest

@testable import NotesKit

/// Setting and removing keys in a note's front matter (its AI title, place, Keep audio): only those lines change,
/// NoteStore reads the values back as they were set, and everything after the front matter stays byte for byte.
final class NoteFrontMatterTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sona-frontmatter-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// An iPhone note as NoteWriter writes it, titled "Pitch practice with Sam before Friday".
    func written() throws -> URL {
        let said = ["Pitch", "practice", "with", "Sam", "before", "Friday."]
        let words = said.enumerated().map { Word(word: $1, start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4, speaker: "Speaker 1") }
        let t = Transcript(
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), duration: 4, text: said.joined(separator: " "), words: words,
            turns: [], asrSeconds: 0.1, diarizationSeconds: 0.1, model: "test")
        return try NoteWriter.write(t, to: root, source: NoteSource.iPhone)
    }

    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// Everything from the front matter's closing line on, found without NoteFrontMatter.
    func body(_ data: Data) throws -> Data {
        let close = try XCTUnwrap(data.range(of: Data("\n---".utf8), in: 4..<data.count))
        return data[close.lowerBound...]
    }

    private func mode(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    func testNewKeysGoBeforeTheTags() throws {
        let url = try written()
        let before = try text(url)
        try NoteFrontMatter.update(fileAt: url, set: [
            "keep_audio": "true", "geo": "-27.4698,153.0251", "place": "4 Main St", "ai_title": "Pitch practice with Sam",
        ])
        let after = try text(url)
        let added = """
            ai_title: "Pitch practice with Sam"
            place: "4 Main St"
            geo: -27.4698,153.0251
            keep_audio: true

            """
        XCTAssertTrue(after.contains("source: \"iPhone\"\n" + added + "tags: [sona]\n---\n"), after)
        XCTAssertEqual(after.replacingOccurrences(of: added, with: ""), before, "nothing else changed")

        let note = try NoteStore(root: root).read(url: url)
        XCTAssertEqual(note.title, "Pitch practice with Sam before Friday")
        XCTAssertEqual(note.aiTitle, "Pitch practice with Sam")
        XCTAssertEqual(note.displayTitle, "Pitch practice with Sam")
        XCTAssertEqual(note.place, "4 Main St")
        XCTAssertEqual(note.geo, "-27.4698,153.0251")
        XCTAssertNil(note.placeEnd)
        XCTAssertNil(note.geoEnd)
        XCTAssertTrue(note.keepAudio)
        XCTAssertEqual(note.source, NoteSource.iPhone)
        XCTAssertEqual(note.lines.map(\.text), ["Pitch practice with Sam before Friday."])
    }

    func testAKeyIsReplacedWhereItIs() throws {
        let url = try written()
        try NoteFrontMatter.update(fileAt: url, set: ["place": "4 Main St", "keep_audio": "true"])
        try NoteFrontMatter.update(fileAt: url, set: ["place": "10 Queen St", "place_end": "12 Queen St"])
        let after = try text(url)
        XCTAssertTrue(after.contains("place: \"10 Queen St\"\nkeep_audio: true\nplace_end: \"12 Queen St\"\ntags: [sona]\n"), after)
        XCTAssertEqual(after.components(separatedBy: "\nplace:").count, 2, "one place line")
        // A key NoteWriter wrote stays in its own place too.
        try NoteFrontMatter.update(fileAt: url, set: ["source": "Apple Watch"])
        XCTAssertTrue(try text(url).contains("model: test\nsource: \"Apple Watch\"\nplace: \"10 Queen St\"\n"))
        let note = try NoteStore(root: root).read(url: url)
        XCTAssertEqual(note.place, "10 Queen St")
        XCTAssertEqual(note.placeEnd, "12 Queen St")
        XCTAssertEqual(note.source, NoteSource.watch)
    }

    /// A key written twice (by hand, say) ends up once, with the new value: the reader keeps the last line, which
    /// would otherwise win.
    func testAKeyWrittenTwiceEndsUpOnce() {
        let text = "---\ntitle: \"Hello\"\nplace: \"A\"\ntags: [sona]\nplace: \"B\"\n---\n\n# Hello\n"
        let new = NoteFrontMatter.update(text, set: ["place": "C"])
        XCTAssertEqual(new, "---\ntitle: \"Hello\"\nplace: \"C\"\ntags: [sona]\n---\n\n# Hello\n")
        XCTAssertEqual(NoteStore.splitFrontmatter(new).0["place"], "C")
    }

    func testNilRemovesAKey() throws {
        let url = try written()
        let original = try Data(contentsOf: url)
        try NoteFrontMatter.update(fileAt: url, set: ["ai_title": "Pitch practice", "place": "4 Main St", "keep_audio": "true"])
        try NoteFrontMatter.update(fileAt: url, set: ["ai_title": nil, "keep_audio": nil])
        var note = try NoteStore(root: root).read(url: url)
        XCTAssertNil(note.aiTitle)
        XCTAssertEqual(note.displayTitle, note.title)
        XCTAssertFalse(note.keepAudio)
        XCTAssertEqual(note.place, "4 Main St")
        let stripped = try text(url)
        XCTAssertFalse(stripped.contains("ai_title") || stripped.contains("keep_audio"), stripped)

        // Removing one that isn't there changes nothing: the file isn't written at all.
        let stamp = NoteStore.stamp(url)
        try NoteFrontMatter.update(fileAt: url, set: ["ai_title": nil, "geo_end": nil])
        XCTAssertEqual(NoteStore.stamp(url), stamp)

        try NoteFrontMatter.update(fileAt: url, set: ["place": nil])
        XCTAssertEqual(try Data(contentsOf: url), original, "back to the note as it was written")
        note = try NoteStore(root: root).read(url: url)
        XCTAssertNil(note.place)
    }

    /// What's set is what NoteStore reads back, the header-only read included: quotes, backslashes, colons, spaces
    /// and accents as they were. A line break becomes a space, so it can never end the front matter or add a key.
    func testValuesComeBackAsTheyWereSet() throws {
        let values = [
            "He said \"hi\" \\ bye", "C:\\notes\\", "a: b: c", "  spaced out  ", "Café — 東京 🎙️", "\"quoted\"", "ends with \\",
            "\\\"", "---", "# heading", "[00:01] Speaker 1: not a line",
        ]
        let url = try written()
        for value in values {
            try NoteFrontMatter.update(fileAt: url, set: ["ai_title": value, "place": value, "place_end": value])
            let store = NoteStore(root: root)
            let whole = try store.read(url: url), header = try store.readHeader(url: url)
            for note in [whole, header] {
                XCTAssertEqual(note.aiTitle, value)
                XCTAssertEqual(note.place, value)
                XCTAssertEqual(note.placeEnd, value)
                XCTAssertEqual(note.title, "Pitch practice with Sam before Friday")
            }
            XCTAssertEqual(whole.lines.map(\.text), ["Pitch practice with Sam before Friday."], value)
        }
        try NoteFrontMatter.update(fileAt: url, set: ["ai_title": "Line one\nline two\r\n---\ntitle: \"Hijacked\""])
        let note = try NoteStore(root: root).read(url: url)
        XCTAssertEqual(note.aiTitle, "Line one line two  --- title: \"Hijacked\"")
        XCTAssertEqual(note.title, "Pitch practice with Sam before Friday")
        XCTAssertEqual(note.lines.map(\.text), ["Pitch practice with Sam before Friday."])
        // Raw keys are written as they are, and read back so.
        try NoteFrontMatter.update(fileAt: url, set: ["geo": "-27.4698,153.0251", "geo_end": "-27.4710,153.0234"])
        let text = try text(url)
        XCTAssertTrue(text.contains("\ngeo: -27.4698,153.0251\n") && text.contains("\ngeo_end: -27.4710,153.0234\n"), text)
        XCTAssertEqual(try NoteStore(root: root).read(url: url).geoEnd, "-27.4710,153.0234")
    }

    /// The transcript and anything else after the front matter (lines that look like front matter, a user's own
    /// section, Windows line ends, no newline at the end) stay byte for byte.
    func testTheBodyStaysByteForByte() throws {
        let url = try written()
        let extra = "\n## My notes\n\ntitle: \"Not this one\"\n---\ntags: [x]\r\nplace: here\n\nCafé ☕️ no newline at the end"
        try Data((try text(url) + extra).utf8).write(to: url)
        let before = try Data(contentsOf: url)
        try NoteFrontMatter.update(fileAt: url, set: [
            "ai_title": "Pitch practice", "place": "4 Main St", "geo": "-27.4698,153.0251", "keep_audio": "true", "tags": nil,
        ])
        let after = try Data(contentsOf: url)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(try body(after), try body(before))
        XCTAssertTrue(after.count > before.count)
        let note = try NoteStore(root: root).read(url: url)
        XCTAssertEqual(note.place, "4 Main St", "the body's own place line isn't the note's")
        XCTAssertEqual(note.title, "Pitch practice with Sam before Friday")
    }

    func testANoteWithoutFrontMatterIsLeftAlone() throws {
        for text in ["[00:00] Speaker 1: Just words.\n\ntitle: \"Not front matter\"\n", "---\ntitle: \"Never closed\"\n", "", "---"] {
            XCTAssertEqual(NoteFrontMatter.update(text, set: ["ai_title": "A title", "place": nil]), text)
        }
        let day = root.appendingPathComponent("2026-11-03", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let url = day.appendingPathComponent("09-00 Plain.md")
        try Data("[00:00] Speaker 1: Just words.\n".utf8).write(to: url)
        let stamp = NoteStore.stamp(url)
        try NoteFrontMatter.update(fileAt: url, set: ["ai_title": "A title"])
        XCTAssertEqual(NoteStore.stamp(url), stamp, "not written")
        XCTAssertEqual(try text(url), "[00:00] Speaker 1: Just words.\n")
    }

    func testWithoutATagsLineKeysGoAtTheEnd() {
        let text = "---\ntitle: \"Hello\"\ndate: 2026-11-06\n---\n\n# Hello\n"
        XCTAssertEqual(
            NoteFrontMatter.update(text, set: ["keep_audio": "true", "place": "4 Main St"]),
            "---\ntitle: \"Hello\"\ndate: 2026-11-06\nplace: \"4 Main St\"\nkeep_audio: true\n---\n\n# Hello\n")
    }

    /// Only flat names are keys: one with a space, a colon or a line break would break the front matter.
    func testKeysThatArentFlatNamesAreIgnored() {
        let text = "---\ntitle: \"Hello\"\ntags: [sona]\n---\n\n# Hello\n"
        XCTAssertEqual(NoteFrontMatter.update(text, set: ["bad key": "x", "a:b": "y", "": "z", "new\nline": "w", "---": "v"]), text)
    }

    /// The file is replaced in one step and keeps its permissions (0600 as NoteWriter makes it, or what iCloud gave
    /// it), with no temp file left behind.
    func testTheFileKeepsItsPermissions() throws {
        let url = try written()
        XCTAssertEqual(mode(url), 0o600)
        try NoteFrontMatter.update(fileAt: url, set: ["keep_audio": "true"])
        XCTAssertEqual(mode(url), 0o600)
        chmod(url.path, 0o644)
        let inode = NoteStore.stamp(url)?.inode
        try NoteFrontMatter.update(fileAt: url, set: ["keep_audio": nil])
        XCTAssertEqual(mode(url), 0o644)
        XCTAssertNotEqual(NoteStore.stamp(url)?.inode, inode, "a new file renamed into place, not written over")
        let left = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(left.filter { $0.hasPrefix(".") }, [], "no temp files left")
    }

    /// A file that isn't UTF-8 can't be written back as it was: it's left alone, and the caller hears.
    func testAFileThatIsntUTF8IsLeftAlone() throws {
        let url = root.appendingPathComponent("odd.md")
        let bytes = Data("---\ntitle: \"Caf".utf8) + Data([0xE9]) + Data("\"\n---\n".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try NoteFrontMatter.update(fileAt: url, set: ["place": "4 Main St"]))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
