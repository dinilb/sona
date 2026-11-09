import XCTest

@testable import NotesKit

final class NotesKitTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sona-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func words(_ spec: [(String, String, Double)]) -> [Word] {
        spec.map { Word(word: $0.1, start: $0.2, end: $0.2 + 0.3, speaker: $0.0) }
    }

    func sample(start: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> Transcript {
        let w = words([
            ("Speaker 1", "Um,", 0.0), ("Speaker 1", "okay.", 0.4), ("Speaker 1", "So", 1.0), ("Speaker 1", "the", 1.3),
            ("Speaker 1", "pricing", 1.6), ("Speaker 1", "page", 1.9), ("Speaker 1", "needs", 2.2), ("Speaker 1", "work.", 2.5),
            ("Speaker 2", "Agreed,", 3.5), ("Speaker 2", "let's", 3.8), ("Speaker 2", "ship", 4.1), ("Speaker 2", "Friday.", 4.4),
        ])
        return Transcript(
            startedAt: start, duration: 5, text: w.map(\.word).joined(separator: " "), words: w,
            turns: [Turn(speaker: "Speaker 1", start: 0, end: 3), Turn(speaker: "Speaker 2", start: 3.4, end: 5)],
            asrSeconds: 0.1, diarizationSeconds: 0.1, model: "parakeet-tdt-0.6b-v2")
    }

    func testTitleSkipsFiller() {
        let lines = Lines.from(sample().words)
        XCTAssertEqual(Title.make(from: lines), "The pricing page needs work")
        XCTAssertNil(Title.make(from: [Line(speaker: "Speaker 1", start: 0, end: 1, text: "Yeah. Okay.")]))
        XCTAssertEqual(Title.fileSafe("a/b: c?"), "a b c")
    }

    func testLinesSplitOnSpeakerAndPause() {
        let lines = Lines.from(sample().words)
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(lines[1].text, "Agreed, let's ship Friday.")
        XCTAssertEqual(Lines.clock(3725), "1:02:05")
        XCTAssertEqual(Lines.clock(65), "01:05")
    }

    func testWriteReadSearchRename() throws {
        let url = try NoteWriter.write(sample(), to: root)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(" The pricing page needs work.md"))
        let store = NoteStore(root: root)
        let notes = store.conversations()
        XCTAssertEqual(notes.count, 1)
        let note = notes[0]
        XCTAssertEqual(note.speakers, ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(note.lines.count, 2)
        XCTAssertEqual(note.lines[1].clock, "00:03")

        // Prefix ids resolve.
        XCTAssertEqual(try store.read(String(note.id.prefix(16))).id, note.id)

        let hits = store.search("SHIP friday")
        XCTAssertEqual(hits.total, 1)
        XCTAssertEqual(hits.hits[0].line.speaker, "Speaker 2")
        XCTAssertEqual(store.search("ship", speaker: "Speaker 1").total, 0)

        XCTAssertEqual(try store.renameSpeaker(in: note.id, from: "speaker 2", to: "Sam"), 1)
        let renamed = try store.read(note.id)
        XCTAssertEqual(renamed.speakers, ["Speaker 1", "Sam"])
        XCTAssertEqual(renamed.lines[1].speaker, "Sam")
        let sidecar = try JSONDecoder().decode(
            NoteWriter.Sidecar.self, from: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
        XCTAssertEqual(Set(sidecar.words.map(\.speaker)), ["Speaker 1", "Sam"])
        XCTAssertThrowsError(try store.renameSpeaker(in: note.id, from: "Speaker 9", to: "X"))
        XCTAssertThrowsError(try store.renameSpeaker(in: note.id, from: "Speaker 1", to: "Bad: name"))

        // Merging two speakers into one name.
        try store.renameSpeaker(in: note.id, from: "Speaker 1", to: "Sam")
        XCTAssertEqual(try store.read(note.id).speakers, ["Sam"])
    }

    /// The sidebar's listing: names only, newest first, the same files `conversations` reads.
    func testNamesListNewestFirstWithoutReadingNotes() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        try NoteWriter.write(sample(start: t0), to: root)
        try NoteWriter.write(sample(start: t0.addingTimeInterval(3_600)), to: root)
        try NoteWriter.write(sample(start: t0.addingTimeInterval(86_400)), to: root)
        let day = root.appendingPathComponent(NoteWriter.dayString(t0))
        try Data("x".utf8).write(to: day.appendingPathComponent(".hidden.md"))
        try FileManager.default.createSymbolicLink(
            at: day.appendingPathComponent("23-59 Link.md"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let store = NoteStore(root: root)
        let names = store.names()
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(names.map(\.id), store.conversations().reversed().map(\.id))
        XCTAssertEqual(names.first?.day, NoteWriter.dayString(t0.addingTimeInterval(86_400)))
        XCTAssertEqual(names.last?.time, NoteWriter.timeString(t0, "HH:mm"))
        XCTAssertEqual(names.last?.title, "The pricing page needs work")
    }

    func testSameMinuteNeverOverwrites() throws {
        let a = try NoteWriter.write(sample(), to: root)
        let b = try NoteWriter.write(sample(), to: root)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(NoteStore(root: root).conversations().count, 2)
    }

    private func mode(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
    }

    /// Notes are private: new folders 0700, notes and sidecars 0600, still after a rename.
    func testNotesArePrivate() throws {
        let conversations = root.appendingPathComponent("Notes/Conversations")
        let url = try NoteWriter.write(sample(), to: conversations)
        XCTAssertEqual(mode(root.appendingPathComponent("Notes").path), 0o700)
        XCTAssertEqual(mode(conversations.path), 0o700)
        XCTAssertEqual(mode(url.deletingLastPathComponent().path), 0o700)
        XCTAssertEqual(mode(url.path), 0o600)
        XCTAssertEqual(mode(url.deletingPathExtension().appendingPathExtension("json").path), 0o600)
        try NoteStore(root: conversations).renameSpeaker(in: NoteStore.relativeID(url, root: conversations), from: "Speaker 1", to: "Ana")
        XCTAssertEqual(mode(url.path), 0o600)
        XCTAssertEqual(mode(url.deletingPathExtension().appendingPathExtension("json").path), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    /// The support folder's own files are this user's only too, and launch tightens what an older version left open.
    func testSupportFilesArePrivate() throws {
        let previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        setenv("SONA_HOME", root.path, 1)
        defer { if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") } }
        try Settings().save()
        AppStatus(state: "listening").write()
        Log.note("test")
        for url in [Paths.settingsFile, Paths.statusFile, Paths.logFile] { XCTAssertEqual(mode(url.path), 0o600, url.lastPathComponent) }

        chmod(root.path, 0o755)
        for url in [Paths.settingsFile, Paths.statusFile, Paths.logFile] { chmod(url.path, 0o644) }
        try FileManager.default.createDirectory(at: Paths.spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let wav = Paths.spool.appendingPathComponent("old.wav")
        try Data("x".utf8).write(to: wav)
        chmod(wav.path, 0o644)
        Paths.tightenSupport()
        XCTAssertEqual(mode(root.path), 0o700)
        XCTAssertEqual(mode(Paths.spool.path), 0o700)
        for url in [Paths.settingsFile, Paths.statusFile, Paths.logFile, wav] { XCTAssertEqual(mode(url.path), 0o600, url.lastPathComponent) }
    }

    /// A rename never writes back a note (or its .json) that changed after it was read: that would undo the change,
    /// such as "delete the last N minutes" cutting it meanwhile.
    func testRenameRefusesANoteThatChanged() throws {
        let store = NoteStore(root: root)
        let url = try NoteWriter.write(sample(), to: root)
        let id = NoteStore.relativeID(url, root: root)
        func refused(_ id: String, _ change: @escaping () -> Void) {
            XCTAssertThrowsError(try store.renameSpeaker(in: id, from: "Speaker 1", to: "Ana", afterReading: change)) { error in
                guard let error = error as? NoteStoreError, case .changed = error else { return XCTFail("\(error)") }
            }
        }
        refused(id) { try? Data("cut".utf8).write(to: url) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "cut")

        // Its .json changing counts too; untouched, the same rename goes through.
        let other = try NoteWriter.write(sample(start: Date(timeIntervalSince1970: 1_790_100_000)), to: root)
        let otherID = NoteStore.relativeID(other, root: root)
        let json = other.deletingPathExtension().appendingPathExtension("json")
        let before = try String(contentsOf: other, encoding: .utf8)
        refused(otherID) {
            guard let handle = try? FileHandle(forWritingTo: json) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(" ".utf8))
            try? handle.close()
        }
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), before)
        XCTAssertNoThrow(try store.renameSpeaker(in: otherID, from: "Speaker 1", to: "Ana"))
        XCTAssertEqual(try store.read(otherID).speakers, ["Ana", "Speaker 2"])
    }

    /// Older notes: folders tightened every launch, files once (the marker remembers).
    func testTightenPermissions() throws {
        let day = root.appendingPathComponent("Conversations/2026-10-27")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let old = day.appendingPathComponent("09-00 Old.md")
        try Data("x".utf8).write(to: old)
        chmod(old.path, 0o644)
        let marker = root.appendingPathComponent("marker")
        NoteWriter.tightenPermissions(root.appendingPathComponent("Conversations"), marker: marker)
        XCTAssertEqual(mode(day.path), 0o700)
        XCTAssertEqual(mode(old.path), 0o600)
        XCTAssertEqual(mode(root.appendingPathComponent("Conversations").path), 0o700)

        chmod(day.path, 0o755)
        chmod(old.path, 0o644)
        NoteWriter.tightenPermissions(root.appendingPathComponent("Conversations"), marker: marker)
        XCTAssertEqual(mode(day.path), 0o700, "folders every time")
        XCTAssertEqual(mode(old.path), 0o644, "files only once")
    }

    /// A retry reuses the path it reserved: one note, overwritten, never "... 2".
    func testReuseOverwritesTheReservedNote() throws {
        var reserved: URL?
        let a = try NoteWriter.write(sample(), to: root) { reserved = $0 }
        XCTAssertEqual(reserved, a)
        let b = try NoteWriter.write(sample(), to: root, reuse: a) { _ in XCTFail("reuse never reserves") }
        XCTAssertEqual(a, b)
        XCTAssertEqual(NoteStore(root: root).conversations().count, 1)
    }

    /// Writes take only an exact id or a unique YYYY-MM-DD/HH-mm start; reads stay lenient.
    func testRenameNeedsAnExactID() throws {
        let url = try NoteWriter.write(sample(), to: root)
        let store = NoteStore(root: root)
        let id = NoteStore.relativeID(url, root: root)
        XCTAssertEqual(try store.read("pricing page").id, id)
        XCTAssertThrowsError(try store.renameSpeaker(in: "pricing page", from: "Speaker 1", to: "Ana"))
        XCTAssertThrowsError(try store.renameSpeaker(in: String(id.prefix(13)), from: "Speaker 1", to: "Ana"))
        XCTAssertEqual(try store.renameSpeaker(in: String(id.prefix(16)), from: "Speaker 1", to: "Ana"), 1)
        XCTAssertEqual(try store.renameSpeaker(in: id, from: "Ana", to: "Bea"), 1)
    }

    /// The file scan matches the index: accent-insensitive speaker filter, no `._` files, no symlinks.
    func testScanMatchesTheIndex() throws {
        let url = try NoteWriter.write(sample(), to: root)
        let store = NoteStore(root: root)
        try store.renameSpeaker(in: NoteStore.relativeID(url, root: root), from: "Speaker 2", to: "José")
        XCTAssertEqual(store.scanSearch("ship", speaker: "jose").total, 1)
        XCTAssertEqual(store.scanSearch("ship", speaker: "JOSÉ").total, 1)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("._" + url.lastPathComponent))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.md"), withDestinationURL: url)
        XCTAssertEqual(store.conversations().count, 1)
        XCTAssertEqual(store.scanSearch("ship").total, 1)
        let index = NoteStore(root: root, indexURL: root.appendingPathComponent("index.sqlite"))
        if SearchIndex.fts5Available { XCTAssertEqual(index.search("ship", speaker: "jose").total, 1) }
    }

    /// Big replies are cut at the character budget and say how to continue.
    func testMCPRepliesAreCapped() throws {
        let day = root.appendingPathComponent("2026-10-27")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let long = String(repeating: "word ", count: 40)
        var md = "---\ntitle: \"Long\"\ndate: 2026-10-27\nstart: \"09:00:00\"\nend: \"10:00:00\"\n---\n\n"
        for i in 0..<3_000 { md += "[\(Lines.clock(Double(i)))] Speaker 1: \(long)\(i)\n\n" }
        try Data(md.utf8).write(to: day.appendingPathComponent("09-00 Long.md"))
        let title = String(repeating: "t", count: 2_000)
        for i in 0..<60 {
            try Data("---\ntitle: \"\(title)\"\ndate: 2026-10-27\nstart: \"11:\(String(format: "%02d", i)):00\"\n---\n\n".utf8)
                .write(to: day.appendingPathComponent("11-\(String(format: "%02d", i)) T.md"))
        }
        let server = MCPServer(store: NoteStore(root: root))
        let read = try server.readConversation(["id": "2026-10-27/09-00", "limit": 5_000])
        XCTAssertLessThan(read.count, MCPServer.replyBudget + 1_000)
        XCTAssertTrue(read.contains("more lines. Call again with offset"), String(read.suffix(200)))
        let found = try server.search(["query": "word", "limit": 1_000])
        XCTAssertLessThan(found.count, MCPServer.replyBudget + 1_000)
        XCTAssertTrue(found.contains("Call again with offset"), String(found.suffix(200)))
        let list = try server.listConversations(["from": "2026-10-27", "limit": 10_000])
        XCTAssertLessThan(list.count, MCPServer.replyBudget + 3_000)
        XCTAssertTrue(list.contains("Call again with offset"), String(list.suffix(200)))
        let next = try server.listConversations(["from": "2026-10-27", "offset": 59])
        XCTAssertTrue(next.contains("showing 60-61"), String(next.prefix(200)))
    }

    /// A status file the app stopped updating (it quit and its pid was reused) isn't trusted.
    func testStaleAppStatusIsIgnored() {
        let previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        setenv("SONA_HOME", root.path, 1)
        defer { if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") } }
        AppStatus(state: "hearing", conversationStartedAt: Date()).write()  // our own pid: alive
        XCTAssertNotNil(AppStatus.read())
        XCTAssertNil(AppStatus.read(now: Date().addingTimeInterval(AppStatus.maxAge + 5)))
        let server = MCPServer(store: NoteStore(root: root), now: { Date().addingTimeInterval(AppStatus.maxAge + 5) })
        XCTAssertFalse(server.recent([:]).contains("In progress"))
        XCTAssertTrue(MCPServer(store: NoteStore(root: root)).recent([:]).contains("In progress"))
    }

    /// One copy only: a lock someone holds means another copy is running, but a lock file that can't even be opened
    /// doesn't (the app runs without it rather than quitting for good).
    func testOnlyAHeldLockMeansAnotherCopy() throws {
        let previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        setenv("SONA_HOME", root.path, 1)
        defer { if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") } }
        var held = AppLock.acquire()
        XCTAssertEqual(held?.isHeld, true)
        XCTAssertNil(AppLock.acquire(), "held: another copy")
        held = nil
        XCTAssertNotNil(AppLock.acquire(), "let go when its holder ends")
        try FileManager.default.removeItem(at: Paths.lockFile)
        try FileManager.default.createDirectory(at: Paths.lockFile, withIntermediateDirectories: false)
        let without = AppLock.acquire()
        XCTAssertNotNil(without, "can't be opened: not another copy")
        XCTAssertEqual(without?.isHeld, false, "but it can't tell")
    }

    func testMCPProtocol() throws {
        _ = try NoteWriter.write(sample(start: Date().addingTimeInterval(-600)), to: root)
        let server = MCPServer(store: NoteStore(root: root))

        func call(_ json: String) throws -> [String: Any] {
            let reply = try XCTUnwrap(server.handle(line: json))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        }

        let initReply = try call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual((initReply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))

        let list = try call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["live", "recent", "list_conversations", "read_conversation", "search", "rename_speaker"])

        func text(_ reply: [String: Any]) -> String {
            (((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        XCTAssertTrue(text(try call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"pricing"}}}"#)).contains("the pricing page needs work"))
        XCTAssertTrue(text(try call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"recent","arguments":{"minutes":30}}}"#)).contains("Agreed, let's ship Friday."))
        let bad = try call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_conversation","arguments":{"id":"nope"}}}"#)
        XCTAssertEqual((bad["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unknown = try call(#"{"jsonrpc":"2.0","id":6,"method":"nope"}"#)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    /// AI access off: the tools are still listed, but every call says it's off and returns nothing else.
    func testMCPOffAnswersEveryToolWithTheSwitch() throws {
        _ = try NoteWriter.write(sample(start: Date().addingTimeInterval(-600)), to: root)
        var on = false
        let server = MCPServer(store: NoteStore(root: root), enabled: { on })
        func call(_ name: String, _ args: String = "{}") throws -> (String, Bool) {
            let line = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(server.handle(line: line)).utf8)) as? [String: Any])
            let result = try XCTUnwrap(reply["result"] as? [String: Any])
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return (text, result["isError"] as? Bool ?? false)
        }
        for name in ["live", "recent", "list_conversations", "search", "read_conversation", "rename_speaker"] {
            let (text, isError) = try call(name, #"{"query":"pricing","id":"x","conversation":"x","from":"Speaker 1","to":"A"}"#)
            XCTAssertEqual(text, MCPServer.offMessage, name)
            XCTAssertTrue(isError)
        }
        let list = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        XCTAssertTrue(list.contains("read_conversation"), "still listed, so the AI can say why")
        // Turned back on: answers again, without restarting the server.
        on = true
        XCTAssertTrue(try call("search", #"{"query":"pricing"}"#).0.contains("the pricing page needs work"))
    }

    func testLiveTool() throws {
        let previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        setenv("SONA_HOME", root.path, 1)
        defer { if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") } }
        let server = MCPServer(store: NoteStore(root: root))
        XCTAssertTrue(server.live([:]).contains("never run"))

        let now = Date()
        LiveFeed(listening: true, engine: "Test", speakers: true, lines: [
            .init(speaker: "Speaker 1", settled: true, start: now.addingTimeInterval(-300), end: now.addingTimeInterval(-298), text: "old line"),
            .init(speaker: "Speaker 1", settled: true, start: now.addingTimeInterval(-8), end: now.addingTimeInterval(-6), text: "so the pricing page"),
            .init(speaker: "Speaker 2", settled: false, start: now.addingTimeInterval(-2), end: now, text: "agreed let's ship Friday"),
        ]).write()

        let recent = server.live(["seconds": 60])
        XCTAssertTrue(recent.contains("is listening"))
        XCTAssertFalse(recent.contains("old line"))
        XCTAssertTrue(recent.contains("Speaker 1: so the pricing page"))
        XCTAssertTrue(recent.contains("Speaker 2: agreed let's ship Friday (speaker may change)"))

        let last = server.live(["words": 5])
        XCTAssertTrue(last.contains("Speaker 1: … page"))
        XCTAssertTrue(last.contains("agreed let's ship Friday"))
        XCTAssertFalse(last.contains("old line"))
    }

    func testSpeakerHintParsing() {
        XCTAssertEqual(SpeakerHint(parsing: "3"), .exactly(3))
        XCTAssertEqual(SpeakerHint(parsing: "3")?.exact, 3)
        XCTAssertEqual(SpeakerHint(parsing: "2-4"), SpeakerHint(min: 2, max: 4))
        XCTAssertEqual(SpeakerHint(parsing: "2...4"), SpeakerHint(min: 2, max: 4))
        XCTAssertEqual(SpeakerHint(parsing: "2-"), SpeakerHint(min: 2))
        XCTAssertEqual(SpeakerHint(parsing: "-4"), SpeakerHint(max: 4))
        for bad in ["", "0", "-", "x", "2-x", "0-3", "1-2-3"] {
            XCTAssertNil(SpeakerHint(parsing: bad), bad)
        }
    }

    func testSpeakerHintAroundAndDescription() {
        XCTAssertNil(SpeakerHint(parsing: "11"))
        XCTAssertNil(SpeakerHint(parsing: "4-2"))
        XCTAssertNil(SpeakerHint(parsing: "2-20"))
        XCTAssertEqual(SpeakerHint(parsing: "2-4")?.description, "2-4")
        XCTAssertEqual(SpeakerHint.exactly(3).description, "3")
        XCTAssertEqual(SpeakerHint(max: 4).description, "-4")
        XCTAssertTrue(SpeakerHint().isEmpty)
    }

    func testSpeakerHintCodable() throws {
        let hint = SpeakerHint(min: 2, max: 4)
        let data = try JSONEncoder().encode(hint)
        XCTAssertEqual(try JSONDecoder().decode(SpeakerHint.self, from: data), hint)
    }

    /// A reservation that can't be saved leaves no empty note behind (a retry would otherwise add "... 2").
    func testFailedReservationLeavesNoGhostNote() throws {
        struct Nope: Error {}
        XCTAssertThrowsError(try NoteWriter.write(sample(), to: root, reserved: { _ in throw Nope() }))
        let files = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(files, [])
        // The retry then writes exactly one note.
        try NoteWriter.write(sample(), to: root)
        let after = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(after.count, 1)
    }
}
