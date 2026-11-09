import XCTest

@testable import NotesKit

/// "Delete the last N minutes" on the notes folder (cut or delete notes, keep each .json in step) and on the
/// Dictations list; and the first-run flag for old settings files.
final class ForgetTests: XCTestCase {
    var root: URL!
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sona-forget-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// A note starting at `start`, one word per (text, seconds in), speakers taking turns every two words (or all
    /// `speaker`'s).
    @discardableResult
    func note(_ start: Date, _ said: [(String, Double)], speaker: String? = nil) throws -> URL {
        let words = said.enumerated().map { i, w in
            Word(word: w.0, start: w.1, end: w.1 + 0.4, speaker: speaker ?? "Speaker \(i / 2 % 2 + 1)")
        }
        let end = (said.last?.1 ?? 0) + 1
        let t = Transcript(
            startedAt: start, duration: end, text: words.map(\.word).joined(separator: " "), words: words,
            turns: words.map { Turn(speaker: $0.speaker, start: $0.start, end: $0.end) }, asrSeconds: 0.1,
            diarizationSeconds: 0.1, model: "test")
        return try NoteWriter.write(t, to: root)
    }

    func sidecar(_ md: URL) throws -> NoteWriter.Sidecar {
        try JSONDecoder().decode(NoteWriter.Sidecar.self, from: Data(contentsOf: md.deletingPathExtension().appendingPathExtension("json")))
    }

    func allFiles() -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.contains(".") }
    }

    private func mode(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    func testForgetCutsAndDeletesNotes() throws {
        let cut = t0.addingTimeInterval(30)
        // Runs past the cut, and its title comes from words after it: cut, and renamed.
        let renamed = try note(t0, [
            ("Yeah.", 0), ("Okay.", 2), ("The", 40), ("secret", 40.5), ("launch", 41), ("plan", 41.5), ("is", 42), ("Friday.", 42.5),
        ])
        // Runs past the cut, title from before it: cut in place.
        let kept = try note(t0.addingTimeInterval(5), [("Budget", 0), ("talk", 0.5), ("for", 1), ("March.", 1.5), ("Moreover", 35)])
        // Started after the cut: deleted.
        let after = try note(t0.addingTimeInterval(120), [("Later", 0), ("words", 1), ("here", 2)])
        // Runs past the cut but its .json is gone: cut by whole lines instead.
        let bare = try note(t0.addingTimeInterval(10), [("Nothing", 0), ("timed", 1), ("here", 2), ("Zanzibar", 40)])
        try FileManager.default.removeItem(at: bare.deletingPathExtension().appendingPathExtension("json"))
        // Ended an hour before: untouched.
        let old = try note(t0.addingTimeInterval(-3600), [("An", 0), ("old", 1), ("chat", 2)])
        let oldBytes = try Data(contentsOf: old)

        let index = root.appendingPathComponent("index.sqlite")
        let store = NoteStore(root: root, indexURL: index)
        if SearchIndex.fts5Available { XCTAssertEqual(store.search("secret").total, 1) }

        let done = NoteStore(root: root).forget(from: cut)
        XCTAssertEqual(done.deleted, 1)
        XCTAssertEqual(done.trimmed, 3)
        XCTAssertEqual(done.failed, 0)

        // Nothing said from the cut on is left anywhere: not in a note, a .json or a file name.
        let notes = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".md") || $0.hasSuffix(".json") }
        for file in notes {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for word in ["secret", "Friday", "Moreover", "Later", "Zanzibar"] {
                XCTAssertFalse(text.contains(word) || file.contains(word), "\(word) in \(file)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: after.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: after.deletingPathExtension().appendingPathExtension("json").path))
        XCTAssertEqual(try Data(contentsOf: old), oldBytes)

        // Without its .json: whole lines that had ended before the cut ("here" goes too: its end isn't known).
        let noJSON = try XCTUnwrap(NoteStore(root: root).conversations().first { $0.startedAt == t0.addingTimeInterval(10) })
        XCTAssertEqual(noJSON.lines.map(\.text), ["Nothing timed"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.path), "renamed: its title came from words that went")

        // The renamed one: its new title, only the words from before, and its .json in step.
        let notesLeft = NoteStore(root: root).conversations()
        XCTAssertEqual(notesLeft.count, 4)
        let first = try XCTUnwrap(notesLeft.first { $0.startedAt == t0 })
        XCTAssertEqual(first.title, "Conversation")
        XCTAssertTrue(first.url.lastPathComponent.hasSuffix(" Conversation.md"), first.url.lastPathComponent)
        XCTAssertEqual(first.lines.map(\.text), ["Yeah. Okay."])
        let side = try sidecar(first.url)
        XCTAssertEqual(side.words.map(\.word), ["Yeah.", "Okay."])
        XCTAssertEqual(side.text, "Yeah. Okay.")
        XCTAssertEqual(side.speakers, ["Speaker 1"])
        XCTAssertTrue(side.turns.allSatisfy { $0.start < 29 && $0.end <= 29 })
        XCTAssertEqual(side.durationSeconds, 29, accuracy: 0.001, "up to the cut (a second early: saved starts are whole seconds)")
        XCTAssertEqual(first.end, NoteWriter.timeString(t0.addingTimeInterval(29), "HH:mm:ss"))

        // Cut in place: same file, the words before the cut, private as ever.
        let second = try NoteStore(root: root).read(url: kept)
        XCTAssertEqual(second.lines.map(\.text), ["Budget talk", "for March."])
        XCTAssertEqual(try sidecar(kept).words.count, 4)
        XCTAssertEqual(mode(kept), 0o600)
        XCTAssertEqual(mode(first.url), 0o600)
        XCTAssertEqual(mode(first.url.deletingPathExtension().appendingPathExtension("json")), 0o600)
        XCTAssertEqual(allFiles().filter { ($0 as NSString).lastPathComponent.hasPrefix(".") }, [], "no temp files left")

        // Run again: nothing more to do.
        XCTAssertEqual(NoteStore(root: root).forget(from: cut), NoteStore.Forgotten())

        // The search index is thrown away and rebuilt without the deleted words.
        SearchIndex.discard(at: index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        if SearchIndex.fts5Available {
            XCTAssertEqual(store.search("secret").total, 0)
            XCTAssertEqual(store.search("Budget").total, 1)
        }
    }

    /// A line that runs over the cut keeps only its words from before it.
    /// Kept audio (the room's, this Mac's and the iPhone's .m4a) never outlives what was cut or deleted.
    func testKeptAudioGoesWithItsNote() throws {
        // Started after the cut: deleted. Runs past it, title from before: cut in place. An old one: removed.
        let after = try note(t0.addingTimeInterval(120), [("Later", 0), ("words", 1), ("here", 2)])
        let cut = try note(t0.addingTimeInterval(5), [("Budget", 0), ("talk", 0.5), ("for", 1), ("March.", 1.5), ("Moreover", 35)])
        let old = try note(t0.addingTimeInterval(-3600), [("An", 0), ("old", 1), ("chat", 2)])
        for md in [after, cut, old] {
            for audio in NoteStore.keptAudio(of: md) { try Data([1, 2]).write(to: audio) }
        }
        XCTAssertEqual(allFiles().filter { $0.hasSuffix(".mac.wav") }.count, 3)
        XCTAssertEqual(allFiles().filter { $0.hasSuffix(".m4a") }.count, 3)
        let done = NoteStore(root: root).forget(from: t0.addingTimeInterval(30))
        XCTAssertEqual(done.deleted, 1)
        XCTAssertEqual(done.trimmed, 1)
        XCTAssertTrue(NoteStore.remove(old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cut.path))
        XCTAssertEqual(
            allFiles().filter { $0.hasSuffix(".wav") || $0.hasSuffix(".m4a") }, [], "no audio left, the Mac's and the iPhone's included")
        XCTAssertEqual(NoteStore.files(of: cut).map(\.lastPathComponent).filter { $0.hasSuffix(".wav") }.count, 2)
        XCTAssertEqual(NoteStore.files(of: cut).map(\.lastPathComponent).filter { $0.hasSuffix(".m4a") }.count, 1)
    }

    func testALineAcrossTheCutKeepsItsFirstWords() throws {
        try note(t0, [("We", 0), ("ship", 0.5), ("on", 1), ("Friday", 1.5), ("and", 21.6), ("then", 22.0)])
        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(2.4)).trimmed, 1)
        // `keep` is 1.4 s: "We ship on" stay, "Friday" (1.5 s) goes with the rest, and from the title too.
        let left = NoteStore(root: root).conversations()
        XCTAssertEqual(left.map(\.title), ["We ship on"])
        XCTAssertEqual(left.first?.lines.map(\.text), ["We ship", "on"])
    }

    /// Without its .json, a note (hand-edited, say) is cut by whole lines, and the rest of the file stays: its
    /// summary, model and tags; its title (made from its lines), end, duration and speakers follow what's left.
    func testANoteWithoutItsJSONIsCutByWholeLines() throws {
        let day = root.appendingPathComponent(NoteWriter.dayString(t0))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let start = NoteWriter.timeString(t0, "HH:mm:ss")
        let md = """
            ---
            title: "How was the weekend"
            date: \(NoteWriter.dayString(t0))
            start: "\(start)"
            end: "\(NoteWriter.timeString(t0.addingTimeInterval(95), "HH:mm:ss"))"
            duration: 1m 35s
            speakers: ["Ana", "Speaker 2"]
            model: parakeet-tdt-0.6b-v2
            tags: [sona]
            ---

            # How was the weekend

            ## Summary

            Written by hand.

            ## Transcript

            [00:00] Ana: Morning. Quick one.

            [00:10] Ana: How was the weekend?

            [00:30] Ana: Good, thanks.

            [00:50] Speaker 2: The roadmap for next year is ready.

            """
        let url = day.appendingPathComponent("\(NoteWriter.timeString(t0, "HH-mm")) The roadmap for next year.md")
        try Data(md.utf8).write(to: url)

        // Cut 40 s in. "[00:10]" ended before "[00:30]" began; "[00:30]" may have gone on past the cut (the next
        // line is after it), so it goes too.
        let done = NoteStore(root: root).forget(from: t0.addingTimeInterval(40))
        XCTAssertEqual(done.trimmed, 1)
        let notes = NoteStore(root: root).conversations()
        XCTAssertEqual(notes.count, 1)
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(note.lines.map(\.text), ["Morning. Quick one.", "How was the weekend?"])
        XCTAssertEqual(note.title, "How was the weekend")
        XCTAssertEqual(note.speakers, ["Ana"])
        XCTAssertEqual(note.duration, "30s")
        XCTAssertEqual(note.end, NoteWriter.timeString(t0.addingTimeInterval(30), "HH:mm:ss"))
        let text = try String(contentsOf: note.url, encoding: .utf8)
        XCTAssertTrue(text.contains("# How was the weekend\n"), text)
        XCTAssertTrue(text.contains("## Summary\n\nWritten by hand."), text)
        XCTAssertTrue(text.contains("model: parakeet-tdt-0.6b-v2\ntags: [sona]\n"), text)
        XCTAssertFalse(text.contains("roadmap") || text.contains("Good, thanks"), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(mode(note.url), 0o600)
    }

    /// A note that can't be written again is left as it was and reported, never deleted to make up for it.
    func testANoteThatCantBeWrittenIsKeptAndReported() throws {
        let url = try note(t0, [("Keep", 0), ("this", 0.5), ("please.", 1), ("Later", 40)])
        let before = try Data(contentsOf: url)
        let day = url.deletingLastPathComponent()
        chmod(day.path, 0o500)
        defer { chmod(day.path, 0o700) }
        let done = NoteStore(root: root).forget(from: t0.addingTimeInterval(30))
        XCTAssertEqual(done.failed, 1)
        XCTAssertEqual(done.changed, 0)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testANoteLeftWithNothingIsDeleted() throws {
        let url = try note(t0, [("Hello", 5), ("there", 6)])
        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(1)), { var f = NoteStore.Forgotten(); f.deleted = 1; return f }())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(allFiles().filter { $0.hasSuffix(".md") || $0.hasSuffix(".json") }, [])
    }

    /// A note edited by hand since it was written (no longer what its .json makes) is cut by whole lines, so the
    /// edits before the cut stay; its .json still loses everything from the cut on.
    func testAnEditedNoteKeepsItsEdits() throws {
        let url = try note(t0, [
            ("Morning", 0), ("everyone.", 0.5), ("Budget", 10), ("talk", 10.5), ("for", 20), ("March.", 20.5), ("Secret", 40), ("plan.", 40.5),
        ])
        let edited = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "for March.", with: "for May.")
            .replacingOccurrences(of: "# Budget talk for March\n\n", with: "# Budget talk for March\n\n## Summary\n\nWritten by hand.\n\n## Transcript\n\n")
        try Data(edited.utf8).write(to: url)

        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(41)).trimmed, 1)
        let left = try XCTUnwrap(NoteStore(root: root).conversations().first)
        XCTAssertEqual(left.lines.map(\.text), ["Morning everyone.", "Budget talk", "for May."])
        XCTAssertEqual(left.title, "Budget talk for May")
        let text = try String(contentsOf: left.url, encoding: .utf8)
        XCTAssertTrue(text.contains("## Summary\n\nWritten by hand.\n\n## Transcript\n\n"), text)
        let side = try sidecar(left.url)
        XCTAssertEqual(side.words.map(\.word), ["Morning", "everyone.", "Budget", "talk", "for", "March."])
        XCTAssertLessThanOrEqual(side.durationSeconds, 40)
        for file in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let text = (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains("Secret") || text.contains("plan."), file)
        }
        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(41)), NoteStore.Forgotten(), "nothing more to do")
    }

    /// One that wasn't edited is still cut word by word when it started part way through a second (its .json keeps
    /// whole seconds). By whole lines it would be only "We ship".
    func testAnUneditedNoteIsCutWordByWord() throws {
        try note(t0.addingTimeInterval(0.7), [("We", 0), ("ship", 0.5), ("on", 1), ("Friday", 1.5), ("and", 21.6), ("then", 22.0)])
        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(2.5)).trimmed, 1)
        XCTAssertEqual(NoteStore(root: root).conversations().first?.lines.map(\.text), ["We ship", "on"])
    }

    /// The .json goes into place before the note. If the note then can't be replaced it still has what was said, and
    /// is reported. Trying again a minute later (so from a later cut) cuts it where the .json was cut, not later.
    func testTheJSONIsReplacedBeforeTheNote() throws {
        let url = try note(t0, [("Keep", 0), ("this", 0.5), ("please.", 1), ("Later", 40), ("Even", 60), ("later", 60.5), ("Last", 100)])
        let before = try Data(contentsOf: url)
        XCTAssertEqual(chflags(url.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(url.path, 0) }
        let done = NoteStore(root: root).forget(from: t0.addingTimeInterval(30))
        XCTAssertEqual(done.failed, 1)
        XCTAssertEqual(done.changed, 0)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try sidecar(url).words.map(\.word), ["Keep", "this", "please."])
        XCTAssertEqual(allFiles().filter { ($0 as NSString).lastPathComponent.hasPrefix(".") }, [], "no temp files left")

        chflags(url.path, 0)
        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(90)).trimmed, 1)
        XCTAssertEqual(NoteStore(root: root).conversations().first?.lines.first?.text, "Keep this")
        let files = allFiles().filter { $0.hasSuffix(".md") || $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 2, "\(files)")
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for word in ["Later", "Even", "Last"] { XCTAssertFalse(text.contains(word), "\(word) in \(file)") }
        }
    }

    /// A note renamed by its cut, whose old .json can't be removed, is reported rather than counted as cut.
    func testAnOldJSONThatCantBeRemovedIsReported() throws {
        let url = try note(t0, [("Yeah.", 0), ("Okay.", 2), ("The", 40), ("secret", 40.5), ("launch", 41), ("plan", 41.5)])
        let json = url.deletingPathExtension().appendingPathExtension("json")
        XCTAssertEqual(chflags(json.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(json.path, 0) }
        let done = NoteStore(root: root).forget(from: t0.addingTimeInterval(30))
        XCTAssertEqual(done.failed, 1)
        XCTAssertEqual(done.changed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "renamed: its title came from words that went")
    }

    /// Text after the first line that goes is never kept, timed or not (a line split in two by hand). A note whose lines
    /// have lost their times, while its .json has words from then, can't be cut: it's reported, and nothing changes.
    func testTextAfterTheFirstLineThatGoesIsNeverKept() throws {
        let split = try note(t0, [("Hello", 0), ("there.", 0.5), ("Secret", 40), ("plan,", 40.5), ("Zanzibar.", 41)], speaker: "Speaker 1")
        let text = try String(contentsOf: split, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "plan, Zanzibar.", with: "plan,\nZanzibar.").utf8).write(to: split)
        let untimed = try note(t0.addingTimeInterval(1), [("Good", 0), ("morning", 0.5), ("all.", 1), ("Moreover", 40)], speaker: "Speaker 2")
        let stamps = #"(?m)^\[\d\d:\d\d\] "#
        let plain = try String(contentsOf: untimed, encoding: .utf8).replacingOccurrences(of: stamps, with: "", options: .regularExpression)
        try Data(plain.utf8).write(to: untimed)
        let untimedJSON = untimed.deletingPathExtension().appendingPathExtension("json")
        let untimedBytes = try [Data(contentsOf: untimed), Data(contentsOf: untimedJSON)]

        let done = NoteStore(root: root).forget(from: t0.addingTimeInterval(30))
        XCTAssertEqual(done.trimmed, 1)
        XCTAssertEqual(done.failed, 1)
        XCTAssertEqual(try [Data(contentsOf: untimed), Data(contentsOf: untimedJSON)], untimedBytes)
        let left = try XCTUnwrap(NoteStore(root: root).conversations().first { $0.url.path != untimed.path })
        XCTAssertEqual(left.lines.map(\.text), ["Hello there."])
        for file in allFiles() where file.hasSuffix(".md") || file.hasSuffix(".json") {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("Zanzibar") || text.contains("Secret") || file.contains("Zanzibar"), file)
        }
    }

    /// An edited note keeps the lines said before the cut, worked out from its .json's words (not only those followed
    /// by a line that began before the cut). A line that runs over the cut goes whole, its words from before staying in
    /// the .json; a note left with no lines isn't deleted while its .json has words.
    func testAnEditedNoteKeepsTheLinesBeforeTheCut() throws {
        let two = try note(t0, [("Helo", 0), ("there.", 0.5), ("Secret", 40)], speaker: "Speaker 1")
        let fixed = try String(contentsOf: two, encoding: .utf8).replacingOccurrences(of: "Helo there.", with: "Hello there.")
        try Data(fixed.utf8).write(to: two)
        let long = try note(t0, (0...20).map { ("word\($0)", Double($0) * 2) }, speaker: "Speaker 2")  // one line, 0 to 40 s
        let summary = try String(contentsOf: long, encoding: .utf8)
            .replacingOccurrences(of: "\n\n[00:00]", with: "\n\n## Summary\n\nWritten by hand.\n\n[00:00]")
        try Data(summary.utf8).write(to: long)

        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(30)).trimmed, 2)
        let notes = NoteStore(root: root).conversations()
        XCTAssertEqual(notes.count, 2)
        let first = try XCTUnwrap(notes.first { !$0.lines.isEmpty })
        XCTAssertEqual(first.lines.map(\.text), ["Hello there."])
        XCTAssertEqual(try sidecar(first.url).words.map(\.word), ["Helo", "there."])
        let second = try XCTUnwrap(notes.first { $0.lines.isEmpty })
        XCTAssertTrue(try String(contentsOf: second.url, encoding: .utf8).contains("## Summary\n\nWritten by hand.\n"))
        XCTAssertEqual(try sidecar(second.url).words.map(\.word), (0...14).map { "word\($0)" }, "said before the cut (29 s)")
        for file in allFiles() where file.hasSuffix(".md") || file.hasSuffix(".json") {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("Secret") || text.contains("word15") || text.contains("word20"), file)
        }
    }

    /// A title set by hand stays, and so does the file name that has it; only a title made from the note's own words
    /// is made again from what's left.
    func testATitleSetByHandStays() throws {
        let written = try note(t0, [
            ("Morning", 0), ("everyone.", 0.5), ("Budget", 10), ("talk", 10.5), ("for", 20), ("March.", 20.5), ("Secret", 40), ("plan.", 40.5),
        ])
        let url = written.deletingLastPathComponent().appendingPathComponent(NoteWriter.timeString(t0, "HH-mm") + " Call with Sam.md")
        let renamed = try String(contentsOf: written, encoding: .utf8)
            .replacingOccurrences(of: "title: \"Budget talk for March\"", with: "title: \"Call with Sam\"")
            .replacingOccurrences(of: "# Budget talk for March\n", with: "# Call with Sam\n")
        try Data(renamed.utf8).write(to: url)
        try FileManager.default.moveItem(
            at: written.deletingPathExtension().appendingPathExtension("json"), to: url.deletingPathExtension().appendingPathExtension("json"))
        try FileManager.default.removeItem(at: written)

        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(41)).trimmed, 1)
        let note = try NoteStore(root: root).read(url: url)
        XCTAssertEqual(note.title, "Call with Sam")
        XCTAssertEqual(note.lines.map(\.text), ["Morning everyone.", "Budget talk", "for March."])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\n# Call with Sam\n"))
        XCTAssertEqual(try sidecar(url).words.count, 6)
    }

    /// A body heading made from the words is made again even under a title set by hand (it may hold what was said from
    /// the cut on); one written by hand would stay.
    func testAHeadingMadeFromTheWordsIsMadeAgain() throws {
        let url = try note(t0, [("Yeah.", 0), ("Okay.", 2), ("The", 40), ("secret", 40.5), ("launch", 41), ("plan", 41.5)])
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "title: \"The secret launch plan\"", with: "title: \"Call with Sam\"")
        try Data(text.utf8).write(to: url)
        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(30)).trimmed, 1)
        let note = try XCTUnwrap(NoteStore(root: root).conversations().first)
        XCTAssertEqual(note.title, "Call with Sam")
        XCTAssertEqual(note.lines.map(\.text), ["Yeah. Okay."])
        XCTAssertTrue(try String(contentsOf: note.url, encoding: .utf8).contains("\n# Conversation\n"))
        for file in allFiles() {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("secret") || file.contains("secret"), file)
        }
    }

    /// A section the user added under the transcript ("## My notes") stays when the lines above it go.
    func testTheUsersOwnSectionUnderTheTranscriptStays() throws {
        let url = try note(t0, [("Hello", 0), ("there.", 0.5), ("Secret", 40)], speaker: "Speaker 1")
        try Data((try String(contentsOf: url, encoding: .utf8) + "\n## My notes\n\nCall Sam back.\n").utf8).write(to: url)
        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(30)).trimmed, 1)
        let md = try String(contentsOf: try XCTUnwrap(NoteStore(root: root).conversations().first).url, encoding: .utf8)
        XCTAssertTrue(md.hasSuffix("Speaker 1: Hello there.\n\n## My notes\n\nCall Sam back.\n"), md)
        XCTAssertFalse(md.contains("Secret"), md)
    }

    /// Notes made from an audio file (`sona file`) carry the time they were made, not when it was said: a delete
    /// never touches them, with or without their .json.
    func testNotesFromAnAudioFileAreNeverTouched() throws {
        let words = [Word(word: "Imported", start: 0, end: 0.4, speaker: "Speaker 1"), Word(word: "talk.", start: 50, end: 50.4, speaker: "Speaker 1")]
        func imported(_ start: Date) throws -> URL {
            let t = Transcript(
                startedAt: start, duration: 51, text: "Imported talk.", words: words, turns: [], asrSeconds: 0.1,
                diarizationSeconds: 0.1, model: "test")
            return try NoteWriter.write(t, to: root, source: "meeting.m4a")
        }
        let across = try imported(t0)  // runs past the cut
        let after = try imported(t0.addingTimeInterval(60))  // made after it
        let bare = try imported(t0.addingTimeInterval(120))
        try FileManager.default.removeItem(at: bare.deletingPathExtension().appendingPathExtension("json"))
        let notes = [across, after, bare, after.deletingPathExtension().appendingPathExtension("json")]
        let bytes = try notes.map { try Data(contentsOf: $0) }
        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(30)), NoteStore.Forgotten())
        XCTAssertEqual(try notes.map { try Data(contentsOf: $0) }, bytes)
    }

    /// The iPhone's and the watch's notes are live recordings like the Mac's: a delete reaches them by their real time,
    /// their audio (.m4a) with them, and cuts one that runs past it.
    func testPhoneAndWatchNotesAreForgottenLikeTheMacs() throws {
        func recorded(_ start: Date, source: String, words: [(String, Double)]) throws -> URL {
            let w = words.map { Word(word: $0.0, start: $0.1, end: $0.1 + 0.4, speaker: "Speaker 1") }
            let t = Transcript(
                startedAt: start, duration: (words.last?.1 ?? 0) + 1, text: w.map(\.word).joined(separator: " "), words: w,
                turns: [], asrSeconds: 0.1, diarizationSeconds: 0.1, model: "test")
            let md = try NoteWriter.write(t, to: root, source: source)
            try Data("audio".utf8).write(to: md.deletingPathExtension().appendingPathExtension("m4a"))
            return md
        }
        let before = try recorded(t0.addingTimeInterval(-600), source: NoteSource.iPhone, words: [("Earlier", 0), ("talk.", 1)])
        let after = try recorded(t0.addingTimeInterval(60), source: NoteSource.watch, words: [("Secret", 0), ("memo.", 1)])
        let across = try recorded(t0, source: NoteSource.iPhone, words: [("Hello", 0), ("there.", 1), ("Secret", 40), ("bit.", 41)])

        let done = NoteStore(root: root).forget(from: t0.addingTimeInterval(30))
        XCTAssertEqual(done.deleted, 1)
        XCTAssertEqual(done.trimmed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: before.path))
        for gone in NoteStore.files(of: after) { XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), gone.lastPathComponent) }
        let cut = try XCTUnwrap(NoteStore(root: root).conversations().first { $0.startedAt == NoteStore(root: root).conversations().last?.startedAt })
        let text = try String(contentsOf: cut.url, encoding: .utf8)
        XCTAssertFalse(text.contains("Secret"), text)
        // The cut note's audio still has what was cut: it goes.
        XCTAssertFalse(FileManager.default.fileExists(atPath: across.deletingPathExtension().appendingPathExtension("m4a").path))
    }

    /// A note written in another time zone (the Mac has travelled since): what's in the window comes from its .json's
    /// exact start, not its header read in this zone, and the cut note keeps its zone's times and its file name.
    func testANoteFromAnotherTimeZone() throws {
        let here = TimeZone.current.secondsFromGMT(for: t0)
        let there = try XCTUnwrap(TimeZone(secondsFromGMT: here == -5 * 3600 ? 19_800 : -5 * 3600))
        let written = try note(t0, [("Budget", 0), ("talk", 0.5), ("for", 1), ("March.", 1.5), ("Secret", 40), ("plan.", 40.5)])
        // As it would have been written there: its header in that zone's time, the .json's start with that offset,
        // and that zone's day folder.
        var side = try sidecar(written)
        let iso = ISO8601DateFormatter()
        iso.timeZone = there
        side.startedAt = iso.string(from: t0)
        let title = "Budget talk for March"
        let t = Transcript(
            startedAt: t0, duration: side.durationSeconds, text: side.text, words: side.words, turns: side.turns, asrSeconds: 0.1,
            diarizationSeconds: 0.1, model: "test")
        let day = root.appendingPathComponent(NoteWriter.dayString(t0, zone: there))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let url = day.appendingPathComponent(NoteWriter.timeString(t0, "HH-mm", zone: there) + " " + title + ".md")
        NoteStore.remove(written)
        try Data(NoteWriter.markdown(t, lines: Lines.from(side.words), title: title, source: nil, zone: there).utf8).write(to: url)
        try NoteWriter.writeSidecar(side, to: url.deletingPathExtension().appendingPathExtension("json"))

        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(30)).trimmed, 1)
        let note = try NoteStore(root: root).read(url: url)
        XCTAssertEqual(note.lines.map(\.text), ["Budget talk", "for March."])
        XCTAssertEqual(note.start, NoteWriter.timeString(t0, "HH:mm:ss", zone: there))
        XCTAssertEqual(note.end, NoteWriter.timeString(t0.addingTimeInterval(29), "HH:mm:ss", zone: there))
        let cut = try sidecar(url)
        XCTAssertEqual(cut.words.map(\.word), ["Budget", "talk", "for", "March."])
        XCTAssertEqual(cut.startedAt, side.startedAt)
    }

    // MARK: what's added to a note later

    /// What the iPhone adds to a note after it's written, as NoteFrontMatter writes it.
    func addLater(_ url: URL, aiTitle: String) throws {
        try NoteFrontMatter.update(fileAt: url, set: [
            "ai_title": aiTitle, "place": "4 Main St", "geo": "-27.4698,153.0251", "place_end": "10 Queen St",
            "geo_end": "-27.4710,153.0234", "keep_audio": "true",
        ])
    }

    func assertKeptPlace(_ note: ConversationNote, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(note.place, "4 Main St", file: file, line: line)
        XCTAssertEqual(note.geo, "-27.4698,153.0251", file: file, line: line)
        XCTAssertEqual(note.placeEnd, "10 Queen St", file: file, line: line)
        XCTAssertEqual(note.geoEnd, "-27.4710,153.0234", file: file, line: line)
        XCTAssertTrue(note.keepAudio, file: file, line: line)
    }

    /// Keys added after a note was written (its place, AI title, Keep audio) don't make it edited by hand; editing it
    /// still does.
    func testKeysAddedLaterArentAnEdit() throws {
        let url = try note(t0, [("Budget", 0), ("talk", 0.5), ("for", 1), ("March.", 1.5)])
        let written = try String(contentsOf: url, encoding: .utf8)
        try addLater(url, aiTitle: "March budget")
        let added = try String(contentsOf: url, encoding: .utf8)
        XCTAssertNotEqual(added, written)
        XCTAssertTrue(NoteStore.unedited(added, written))
        XCTAssertFalse(NoteStore.unedited(added.replacingOccurrences(of: "for March.", with: "for May."), written))
    }

    /// A note cut word by word keeps its place and Keep audio, whether it's cut in place or renamed (its title came
    /// from what was cut); its AI title, which may describe what was cut, goes.
    func testACutKeepsThePlaceAndDropsTheAITitle() throws {
        let cut = t0.addingTimeInterval(30)
        let inPlace = try note(t0.addingTimeInterval(5), [("Budget", 0), ("talk", 0.5), ("for", 1), ("March.", 1.5), ("Moreover", 35)])
        try addLater(inPlace, aiTitle: "Budget and the Moreover plan")
        let renamed = try note(t0, [
            ("Yeah.", 0), ("Okay.", 2), ("The", 40), ("secret", 40.5), ("launch", 41), ("plan", 41.5), ("is", 42), ("Friday.", 42.5),
        ])
        try addLater(renamed, aiTitle: "The secret launch plan")

        XCTAssertEqual(NoteStore(root: root).forget(from: cut).trimmed, 2)
        let notes = NoteStore(root: root).conversations()
        XCTAssertEqual(notes.count, 2)
        let first = try XCTUnwrap(notes.first { $0.startedAt == t0 })
        XCTAssertNotEqual(first.url, renamed)
        XCTAssertEqual(first.lines.map(\.text), ["Yeah. Okay."])
        XCTAssertNil(first.aiTitle)
        XCTAssertEqual(first.displayTitle, "Conversation")
        assertKeptPlace(first)
        let second = try NoteStore(root: root).read(url: inPlace)
        XCTAssertEqual(second.lines.map(\.text), ["Budget talk", "for March."])
        XCTAssertNil(second.aiTitle)
        XCTAssertEqual(second.displayTitle, "Budget talk for March")
        assertKeptPlace(second)
        for file in allFiles() where file.hasSuffix(".md") || file.hasSuffix(".json") {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("ai_title") || text.contains("Moreover") || text.contains("secret"), file)
        }
        // Run again: nothing more to do.
        XCTAssertEqual(NoteStore(root: root).forget(from: cut), NoteStore.Forgotten())
    }

    /// The added keys don't send a note down the whole-lines path: a line across the cut keeps its first words.
    func testANoteWithAPlaceIsStillCutWordByWord() throws {
        let url = try note(t0, [("We", 0), ("ship", 0.5), ("on", 1), ("Friday", 1.5), ("and", 21.6), ("then", 22.0)])
        try addLater(url, aiTitle: "Shipping on Friday")
        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(2.4)).trimmed, 1)
        let left = try XCTUnwrap(NoteStore(root: root).conversations().first)
        XCTAssertEqual(left.lines.map(\.text), ["We ship", "on"], "by whole lines it would be only \"We ship\"")
        XCTAssertEqual(left.title, "We ship on")
        XCTAssertNil(left.aiTitle)
        assertKeptPlace(left)
        XCTAssertFalse(try String(contentsOf: left.url, encoding: .utf8).contains("Friday"))
    }

    /// A note edited by hand is cut by whole lines: its place stays as it was, and its AI title goes.
    func testAnEditedNoteLosesItsAITitleToo() throws {
        let url = try note(t0, [
            ("Morning", 0), ("everyone.", 0.5), ("Budget", 10), ("talk", 10.5), ("for", 20), ("March.", 20.5), ("Secret", 40), ("plan.", 40.5),
        ])
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "for March.", with: "for May.")
        try Data(edited.utf8).write(to: url)
        try addLater(url, aiTitle: "Secret plan for March")

        XCTAssertEqual(NoteStore(root: root).forget(from: t0.addingTimeInterval(41)).trimmed, 1)
        let left = try XCTUnwrap(NoteStore(root: root).conversations().first)
        XCTAssertEqual(left.lines.map(\.text), ["Morning everyone.", "Budget talk", "for May."], "by whole lines: the edit stays")
        XCTAssertNil(left.aiTitle)
        XCTAssertEqual(left.displayTitle, "Budget talk for May")
        assertKeptPlace(left)
        for file in allFiles() where file.hasSuffix(".md") || file.hasSuffix(".json") {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("ai_title") || text.contains("Secret"), file)
        }
    }

    // MARK: dictations

    func testDictationsAreKeptPrivateNewestFirst() throws {
        let notes = root.appendingPathComponent("Notes")
        try Dictations.append("First one.", at: t0.addingTimeInterval(-600), notes: notes)
        try Dictations.append("Second\none.", at: t0.addingTimeInterval(-60), notes: notes)
        try Dictations.append("Third one.", at: t0, notes: notes)
        try Dictations.append("   ", at: t0, notes: notes)
        let day = NoteWriter.dayString(t0)
        XCTAssertEqual(Dictations.days(notes: notes), [day])
        let entries = Dictations.entries(day: day, notes: notes)
        XCTAssertEqual(entries.map(\.text), ["Third one.", "Second one.", "First one."])
        XCTAssertEqual(entries[0].clock, NoteWriter.timeString(t0, "HH:mm:ss"))
        let file = Dictations.folder(notes: notes).appendingPathComponent(day + ".md")
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(mode(Dictations.folder(notes: notes)), 0o700)

        XCTAssertEqual(Dictations.forget(from: t0.addingTimeInterval(-120), to: t0, notes: notes), 2)
        XCTAssertEqual(Dictations.entries(day: day, notes: notes).map(\.text), ["First one."])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[\(NoteWriter.timeString(t0.addingTimeInterval(-600), "HH:mm:ssxxx"))] First one.\n\n")
        XCTAssertEqual(mode(file), 0o600)

        XCTAssertEqual(Dictations.forget(from: t0.addingTimeInterval(-3600), to: t0, notes: notes), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a day left with nothing is deleted")
        XCTAssertEqual(Dictations.days(notes: notes), [])
    }

    /// Each line has its UTC offset (older ones without it are this Mac's time), and a delete takes only those from
    /// the cut to the click: one pasted while it ran stays.
    func testDictationsBetweenTheCutAndTheClickGo() throws {
        let notes = root.appendingPathComponent("Notes")
        try Dictations.append("Before.", at: t0.addingTimeInterval(-600), notes: notes)
        try Dictations.append("Inside.", at: t0.addingTimeInterval(-60), notes: notes)
        try Dictations.append("After the click.", at: t0.addingTimeInterval(5), notes: notes)
        let file = Dictations.folder(notes: notes).appendingPathComponent(NoteWriter.dayString(t0) + ".md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertNotNil(text.range(of: #"^\[\d\d:\d\d:\d\d[+-]\d\d:\d\d\] Before\.\n\n"#, options: .regularExpression), text)

        // A line from before the offsets, and one written in another time zone (in that zone's day file).
        func appendLine(_ line: String, day: String) throws {
            let url = Dictations.folder(notes: notes).appendingPathComponent(day + ".md")
            try Data((((try? String(contentsOf: url, encoding: .utf8)) ?? "") + line + "\n\n").utf8).write(to: url)
        }
        try appendLine("[\(NoteWriter.timeString(t0.addingTimeInterval(-30), "HH:mm:ss"))] Old style.", day: NoteWriter.dayString(t0))
        let there = try XCTUnwrap(TimeZone(secondsFromGMT: TimeZone.current.secondsFromGMT(for: t0) == -5 * 3600 ? 19_800 : -5 * 3600))
        let elsewhere = t0.addingTimeInterval(-20)
        try appendLine(
            "[\(NoteWriter.timeString(elsewhere, "HH:mm:ssxxx", zone: there))] Elsewhere.", day: NoteWriter.dayString(elsewhere, zone: there))
        func all() -> [Dictations.Entry] { Dictations.days(notes: notes).flatMap { Dictations.entries(day: $0, notes: notes) } }
        XCTAssertEqual(all().first { $0.text == "Old style." }?.time, t0.addingTimeInterval(-30))
        XCTAssertEqual(all().first { $0.text == "Elsewhere." }?.time, elsewhere)

        XCTAssertEqual(Dictations.forget(from: t0.addingTimeInterval(-120), to: t0, notes: notes), 3)
        XCTAssertEqual(Set(all().map(\.text)), ["Before.", "After the click."])
    }

    // MARK: first run

    /// A settings file from before the first-run screen counts as done; a new one doesn't.
    func testOlderSettingsFilesAreOnboarded() throws {
        let old = #"{"alwaysOn": true, "notesFolder": "/tmp/x", "quietMinutes": 3}"#
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: Data(old.utf8)).onboarded)
        XCTAssertFalse(Settings().onboarded)
        let fresh = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(Settings()))
        XCTAssertFalse(fresh.onboarded, "a new install's file stays not done until Start")
        var done = Settings()
        done.onboarded = true
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(done)).onboarded)

        // From disk: no file is a new install; a file that can't be read is still a Mac that was set up.
        let previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        setenv("SONA_HOME", root.path, 1)
        defer { if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") } }
        XCTAssertFalse(Settings.load().onboarded)
        XCTAssertFalse(Settings.aiAccessAllowed, "no file: the app was never set up")
        try Data("{ not json".utf8).write(to: Paths.settingsFile)
        XCTAssertTrue(Settings.load().onboarded)
        try Data(old.utf8).write(to: Paths.settingsFile)
        XCTAssertTrue(Settings.load().onboarded)
        XCTAssertTrue(Settings.aiAccessAllowed, "an older file: AI access was on by default")
    }

    /// A settings file that can't be read never turns recording or AI access on (the defaults would), and is left
    /// as it is for the user to fix.
    func testUnreadableSettingsAreOffAndKept() throws {
        let previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        setenv("SONA_HOME", root.path, 1)
        defer { if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") } }
        XCTAssertFalse(Settings.loadChecked().unreadable, "no file is a new install, not one that can't be read")
        let broken = Data(#"{"alwaysOn": true, "mcp": tru"#.utf8)
        try broken.write(to: Paths.settingsFile)
        // What the app checks before copying the iPhone's notes into the default folder.
        XCTAssertTrue(Settings.loadChecked().unreadable)
        let settings = Settings.load()
        XCTAssertTrue(settings.onboarded)
        XCTAssertFalse(settings.alwaysOn)
        XCTAssertFalse(settings.mcp)
        XCTAssertFalse(settings.macAudio)
        XCTAssertFalse(Settings.aiAccessAllowed)
        XCTAssertEqual(try Data(contentsOf: Paths.settingsFile), broken)

        // Saved (a setting changed): readable again, this user's only.
        var changed = settings
        changed.mcp = true
        try changed.save()
        XCTAssertEqual(Settings.load(), changed)
        XCTAssertFalse(Settings.loadChecked().unreadable)
        XCTAssertTrue(Settings.aiAccessAllowed)
        XCTAssertEqual(mode(Paths.settingsFile), 0o600)
    }
}
