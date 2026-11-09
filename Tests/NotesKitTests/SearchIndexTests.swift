import XCTest
import os

@testable import NotesKit

final class SearchIndexTests: XCTestCase {
    var dir: URL!
    var root: URL { dir.appendingPathComponent("Conversations", isDirectory: true) }
    var dbURL: URL { dir.appendingPathComponent("support/search.sqlite") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-search-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func note(_ day: String, _ time: String, _ title: String, _ lines: [(String, String)]) throws -> URL {
        let folder = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let speakers = Array(NSOrderedSet(array: lines.map(\.0))) as! [String]
        var text = """
            ---
            title: "\(title)"
            date: \(day)
            start: "\(time):00"
            end: "\(time):59"
            duration: 59s
            speakers: [\(speakers.map { "\"\($0)\"" }.joined(separator: ", "))]
            ---

            # \(title)

            """
        for (i, line) in lines.enumerated() { text += "\n[00:\(String(format: "%02d", i * 5))] \(line.0): \(line.1)\n" }
        let url = folder.appendingPathComponent("\(time.replacingOccurrences(of: ":", with: "-")) \(title).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func store() -> NoteStore { NoteStore(root: root, indexURL: dbURL) }

    func seed() throws {
        try note("2026-10-25", "09:00", "Pricing chat", [
            ("Speaker 1", "The pricing page needs work."), ("Speaker 2", "Agreed, let's ship Friday."),
        ])
        try note("2026-10-26", "10:30", "Cafe plans", [
            ("Speaker 1", "Meet at the café near the station?"), ("Sam", "Sure, pricing can wait until then."),
        ])
        try note("2026-10-27", "14:00", "Launch", [
            ("Alex", "We ship the pricing page Friday."), ("Sam", "Don't forget the follow-up email."),
        ])
    }

    func testIndexBuildFiltersAndRanking() throws {
        try seed()
        let s = store()
        let index = try XCTUnwrap(s.index)
        let r = try XCTUnwrap(index.search("pricing", from: nil, to: nil, speaker: nil, limit: 30))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertEqual(r.total, 3)
        XCTAssertEqual(r.total, s.scanSearch("pricing").total)
        XCTAssertEqual(Set(r.hits.map(\.note.id)), ["2026-10-25/09-00 Pricing chat", "2026-10-26/10-30 Cafe plans", "2026-10-27/14-00 Launch"])
        let launch = try XCTUnwrap(r.hits.first { $0.note.id.hasSuffix("Launch") })
        XCTAssertEqual(launch.line.speaker, "Alex")
        XCTAssertEqual(launch.line.clock, "00:00")
        XCTAssertEqual(launch.note.wallClock(launch.line), "14:00:00")

        // Filters: dates, speaker (case and accent insensitive), limit.
        XCTAssertEqual(s.search("pricing", from: "2026-10-26").total, 2)
        XCTAssertEqual(s.search("pricing", to: "2026-10-25").total, 1)
        XCTAssertEqual(s.search("pricing", from: "2026-10-26", to: "2026-10-26").hits.map(\.line.speaker), ["Sam"])
        XCTAssertEqual(s.search("pricing", speaker: "sam").total, 1)
        XCTAssertEqual(s.search("pricing", speaker: "Nobody").total, 0)
        let limited = s.search("pricing", limit: 2)
        XCTAssertEqual(limited.total, 3)
        XCTAssertEqual(limited.hits.count, 2)

        // Substrings, like the file scan: inside words, any word order, short words via the scan.
        XCTAssertEqual(s.search("ricin").total, 3)
        XCTAssertEqual(s.search("friday ship").total, 2)
        XCTAssertEqual(s.search("ip").total, s.scanSearch("ip").total)

        // All words required; case, accents; speaker names are searchable.
        XCTAssertEqual(s.search("SHIP friday").total, 2)
        XCTAssertEqual(s.search("cafe").total, 1)
        XCTAssertEqual(s.search("CAFÉ station").total, 1)
        XCTAssertEqual(s.search("pric").total, 3)
        XCTAssertEqual(s.search("sam email").total, 1)
        XCTAssertEqual(s.search("ship tuesday").total, 0)

        // Same score: the newer conversation first.
        try note("2026-10-20", "08:00", "Old", [("Speaker 1", "zebra crossing")])
        try note("2026-10-28", "08:00", "New", [("Speaker 1", "zebra crossing")])
        XCTAssertEqual(s.search("zebra").hits.map(\.note.id), ["2026-10-28/08-00 New", "2026-10-20/08-00 Old"])

        // Through the MCP tool: same output shape as before.
        let server = MCPServer(store: s)
        let reply = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"follow","speaker":"Sam"}}}"#))
        XCTAssertTrue(reply.contains(#"1 matching line(s):\n2026-10-27/14-00 Launch · 2026-10-27 [00:05] (14:00:05) Sam: Don't forget the follow-up email."#), reply)
    }

    /// The index holds every transcript line: it and its WAL are this user's only.
    func testIndexIsPrivate() throws {
        try seed()
        let s = store()
        XCTAssertEqual(s.search("pricing").total, 3)
        for suffix in ["", "-wal", "-shm"] {
            let mode = (try? FileManager.default.attributesOfItem(atPath: dbURL.path + suffix)[.posixPermissions] as? Int) ?? -1
            XCTAssertEqual(mode, 0o600, "search.sqlite\(suffix)")
        }
    }

    func testIncrementalUpdates() throws {
        try seed()
        let s = store()
        XCTAssertEqual(s.search("pricing").total, 3)

        // A user edit (e.g. in Obsidian), even within the same second and to the same file.
        let launch = root.appendingPathComponent("2026-10-27/14-00 Launch.md")
        var text = try String(contentsOf: launch, encoding: .utf8)
        text = text.replacingOccurrences(of: "pricing page", with: "pricing grid") + "\n[00:30] Alex: Kangaroo budget sorted.\n"
        try text.write(to: launch, atomically: false, encoding: .utf8)
        XCTAssertEqual(s.search("kangaroo").total, 1)
        XCTAssertEqual(s.search("pricing grid").total, 1)
        XCTAssertEqual(s.search("pricing page").total, 1)

        // rename_speaker rewrites the note.
        try s.renameSpeaker(in: "2026-10-25/09-00", from: "Speaker 2", to: "Ada")
        XCTAssertEqual(s.search("friday", speaker: "Ada").total, 1)
        XCTAssertEqual(s.search("friday", speaker: "Speaker 2").total, 0)
        XCTAssertEqual(s.search("ada").total, 1)

        // Deleted notes and new notes.
        try FileManager.default.removeItem(at: root.appendingPathComponent("2026-10-26/10-30 Cafe plans.md"))
        XCTAssertEqual(s.search("cafe").total, 0)
        try note("2026-10-29", "11:00", "New day", [("Speaker 1", "Cafe again tomorrow")])
        XCTAssertEqual(s.search("cafe").hits.map(\.note.id), ["2026-10-29/11-00 New day"])

        // A second process with its own connection sees the same, and a fresh index rebuilds from scratch.
        let other = NoteStore(root: root, indexURL: dbURL)
        XCTAssertEqual(other.search("pricing").total, s.scanSearch("pricing").total)
        try FileManager.default.removeItem(at: dbURL)
        XCTAssertEqual(store().search("kangaroo").total, 1)

        // Pointing the same index at another notes folder drops the old rows.
        let elsewhere = dir.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        XCTAssertEqual(NoteStore(root: elsewhere, indexURL: dbURL).search("kangaroo").total, 0)
        XCTAssertEqual(store().search("kangaroo").total, 1)
    }

    func testQueriesWithQuotesAndFTSSyntax() throws {
        try seed()
        let s = store()
        let index = try XCTUnwrap(s.index)
        // FTS5 syntax in user input is just text: none of these may error, and every answer matches the file
        // scan (queries with a word under 3 characters are answered by the scan itself).
        for q in [#"pricing""#, #""pricing"#, "pricing*", "NEAR(pricing page)", "pricing OR ship", "pricing AND", "NOT pricing",
                  "text:pricing", "-pricing", "(pricing", "pricing^", "{speaker} : pricing", "pricing'", "😀 pricing"]
        {
            XCTAssertEqual(s.search(q).total, s.scanSearch(q).total, q)
        }
        XCTAssertNotNil(index.search("NEAR(pricing page)", from: nil, to: nil, speaker: nil, limit: 5))
        XCTAssertEqual(s.search(#""pricing""#).total, 3)
        XCTAssertEqual(s.search("Don't").total, 1)
        XCTAssertEqual(s.search("follow-up").total, 1)
        // Nothing indexable: the index declines and the file scan answers.
        XCTAssertNil(index.search(#"""#, from: nil, to: nil, speaker: nil, limit: 5))
        XCTAssertEqual(s.search("?").total, s.scanSearch("?").total)
        XCTAssertEqual(s.search("?").total, 1)
    }

    func testFallsBackToScanWhenIndexUnusable() throws {
        try seed()
        // Not a database.
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 8192).write(to: dbURL)
        // It's only a cache, so it's thrown away and rebuilt.
        var s = store()
        XCTAssertEqual(s.index?.search("pricing", from: nil, to: nil, speaker: nil, limit: 5)?.total, 3)
        XCTAssertEqual(s.search("pricing").total, 3)
        // A path that can't be created.
        let blocker = dir.appendingPathComponent("file")
        try Data().write(to: blocker)
        s = NoteStore(root: root, indexURL: blocker.appendingPathComponent("search.sqlite"))
        XCTAssertNil(s.index?.search("pricing", from: nil, to: nil, speaker: nil, limit: 5))
        XCTAssertEqual(s.search("pricing", speaker: "Alex").total, 1)
        // No index at all.
        XCTAssertNil(NoteStore(root: root).index)
        XCTAssertEqual(NoteStore(root: root).search("pricing").total, 3)
    }

    func testFTS5Available() {
        XCTAssertTrue(SearchIndex.fts5Available)
    }

    /// Several processes share one index (one sona-mcp per AI app). Separate connections on separate
    /// threads search while notes keep changing: no search may fail or see a half-written index. A search
    /// that finds another connection writing answers from the file scan instead of waiting, which is fine.
    func testConcurrentConnections() throws {
        try seed()
        let group = DispatchGroup()
        let failures = OSAllocatedUnfairLock(initialState: [String]())
        for worker in 0..<4 {
            group.enter()
            Thread.detachNewThread { [root, dbURL] in
                defer { group.leave() }
                let s = NoteStore(root: root, indexURL: dbURL)
                for _ in 0..<25 {
                    let r = s.search("pricing", limit: 50)
                    if r.total < 3 { failures.withLock { $0.append("worker \(worker) saw \(r.total)") } }
                }
            }
        }
        for i in 0..<25 {
            try note("2026-10-28", "12:\(String(format: "%02d", i))", "Extra \(i)", [("Speaker 1", "more pricing talk \(i)")])
        }
        group.wait()
        XCTAssertEqual(failures.withLock { $0 }, [])
        XCTAssertEqual(store().search("pricing").total, 28)
    }

    /// `SONA_BENCH=1 swift test --filter SearchIndexTests/testBenchmark`: 2,000 synthetic notes.
    func testBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SONA_BENCH"] == "1" else { throw XCTSkip("set SONA_BENCH=1") }
        let words = "the a pricing page launch budget friday meeting design customer roadmap hiring coffee station email "
            + "investor deck demo sprint review bug crash release model audio speaker notes summary plan weekend"
        let vocab = words.split(separator: " ").map(String.init)
        var rng = SystemRandomNumberGenerator()
        let start = Date()
        for n in 0..<2_000 {
            let day = String(format: "2025-%02d-%02d", 1 + (n / 28) % 12, 1 + n % 28)
            let time = String(format: "%02d:%02d", 8 + n % 12, n % 60)
            let lines = (0..<60).map { _ in
                ("Speaker \(Int.random(in: 1...3, using: &rng))", (0..<12).map { _ in vocab.randomElement(using: &rng)! }.joined(separator: " "))
            }
            try note(day, time, "Note \(n)", lines)
        }
        try note("2025-06-15", "23:59", "Needle", [("Alex", "the zanzibar quokka contract")])
        print("bench: wrote 2,001 notes in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")

        func time(_ label: String, _ body: () -> Int) {
            let t = Date()
            let total = body()
            print("bench: \(label): \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) ms (\(total) hits)")
        }
        let scan = NoteStore(root: root)
        time("scan  'zanzibar quokka'") { scan.search("zanzibar quokka").total }
        time("scan  'pricing budget'") { scan.search("pricing budget").total }
        let s1 = store()
        time("index 'zanzibar quokka' cold (build)") { s1.search("zanzibar quokka").total }
        time("index 'zanzibar quokka' warm") { s1.search("zanzibar quokka").total }
        time("index 'pricing budget' warm") { s1.search("pricing budget").total }
        time("  of which: stat every note") { s1.index!.scanDisk().count }
        let s2 = store()
        time("index 'zanzibar quokka' new process, built") { s2.search("zanzibar quokka").total }
        try note("2025-06-16", "10:00", "Edit", [("Alex", "another quokka")])
        time("index 'quokka' after 1 new note") { s2.search("quokka").total }
    }

    func testLanguagesWithoutSpacesAndCorruptIndex() throws {
        try seed()
        try note("2026-10-29", "09:00", "Tokyo", [("Speaker 1", "明日の会議は十時からです")])
        do {
            let s = store()
            XCTAssertEqual(s.search("会議は").total, 1)
        }

        // A garbage index file is thrown away and rebuilt, not scanned around forever.
        let indexURL = dbURL
        let fresh = store()
        try Data("not a database at all".utf8).write(to: indexURL)
        XCTAssertEqual(fresh.search("pricing").total, 3)
        XCTAssertEqual(fresh.search("pricing").total, 3)
        let header = try FileHandle(forReadingFrom: indexURL).readData(ofLength: 15)
        XCTAssertEqual(String(decoding: header, as: UTF8.self), "SQLite format 3")
    }

    /// The iPhone's and the watch's notes: the index keeps their AI title, place and device, a search finds a note by
    /// its title or place (not just its lines), and the MCP tools say all of it.
    func testPhoneFieldsAreIndexedAndSearchable() throws {
        try seed()
        let phone = try note("2026-10-28", "08:30", "So the first thing", [("Speaker 1", "So the first thing is the budget.")])
        let text = try String(contentsOf: phone, encoding: .utf8)
        try text.replacingOccurrences(of: "speakers:", with: "source: \"iPhone\"\nspeakers:")
            .write(to: phone, atomically: true, encoding: .utf8)
        try NoteFrontMatter.update(fileAt: phone, set: [
            "ai_title": "Café budget review", "place": "4 Main St", "geo": "-27.4698,153.0251", "place_end": "10 Queen St",
            "geo_end": "-27.4710,153.0234",
        ])
        let watch = try note("2026-10-28", "09:30", "Remind me", [("Speaker 1", "Remind me to call about the budget.")])
        let watchText = try String(contentsOf: watch, encoding: .utf8)
        try watchText.replacingOccurrences(of: "speakers:", with: "source: \"Apple Watch\"\nspeakers:")
            .write(to: watch, atomically: true, encoding: .utf8)

        for s in [store(), NoteStore(root: root)] {
            // Lines found by the index carry the note's fields, as reading it does.
            let hit = try XCTUnwrap(s.search("first thing").hits.first)
            XCTAssertEqual(hit.note.displayTitle, "Café budget review")
            XCTAssertEqual(hit.note.place, "4 Main St")
            XCTAssertEqual(hit.note.placeEnd, "10 Queen St")
            XCTAssertEqual(hit.note.recordedOn, "iPhone")
            XCTAssertEqual(hit.note.placeText, "4 Main St → 10 Queen St")
            XCTAssertEqual(s.search("call about").hits.first?.note.recordedOn, "Apple Watch")

            // By title or place: case and accent insensitive, every word, start or end place, newest first.
            XCTAssertEqual(s.notesMatching("main st").map(\.id), ["2026-10-28/08-30 So the first thing"])
            XCTAssertEqual(s.notesMatching("QUEEN").map(\.id), ["2026-10-28/08-30 So the first thing"])
            XCTAssertEqual(s.notesMatching("cafe review").map(\.id), ["2026-10-28/08-30 So the first thing"])
            XCTAssertEqual(s.notesMatching("main pricing").count, 0)
            XCTAssertEqual(s.notesMatching("remind").map(\.id), ["2026-10-28/09-30 Remind me"])
            XCTAssertEqual(s.notesMatching("pricing").map(\.id), ["2026-10-25/09-00 Pricing chat"])
            XCTAssertEqual(s.notesMatching("main", to: "2026-10-27").count, 0)
            XCTAssertEqual(s.notesMatching("  ").count, 0)
        }

        let server = MCPServer(store: store())
        func call(_ name: String, _ args: String) throws -> String {
            try XCTUnwrap(server.handle(
                line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":""# + name + #"","arguments":"# + args + "}}"))
        }
        let list = try call("list_conversations", #"{"from":"2026-10-28"}"#)
        XCTAssertTrue(list.contains("Café budget review | 2026-10-28"), list)
        XCTAssertTrue(list.contains("| 1 lines | recorded on iPhone | at 4 Main St → 10 Queen St"), list)
        XCTAssertTrue(list.contains("| 1 lines | recorded on Apple Watch"), list)
        // A place finds its note even though no line says it.
        let found = try call("search", #"{"query":"Main St"}"#)
        XCTAssertTrue(found.contains(#"1 conversation(s) with \"Main St\" in the title or place:"#), found)
        XCTAssertTrue(found.contains("recorded on iPhone | at 4 Main St → 10 Queen St"), found)
        XCTAssertTrue(found.contains(#"No lines match \"Main St\"."#), found)
        XCTAssertFalse(found.contains("0 lines"), found)
    }
}
