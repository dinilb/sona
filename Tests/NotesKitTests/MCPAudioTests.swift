import XCTest

@testable import NotesKit

/// The MCP tools that read audio not yet in a note (the conversation going on now), with a stand-in for the helper
/// that transcribes it.
final class MCPAudioTests: XCTestCase {
    var home: URL!
    var root: URL!
    var previousHome: String?

    override func setUp() {
        previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sona-mcp-audio-\(UUID().uuidString)")
        root = home.appendingPathComponent("Notes/Conversations")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("SONA_HOME", home.path, 1)
    }

    override func tearDown() {
        if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    /// 2026-11-09 18:30:00 in this Mac's time zone.
    let now = ConversationNote.parse("2026-11-09", "18:30:00")!

    /// What the stand-in helper was asked, and what it says.
    final class Helper {
        var asked: [(id: String, from: Double, to: Double, seconds: Double)] = []
        var stopped = 0
        /// Seconds into the recording, speaker, words.
        var said: [(Double, String, String)] = []
        var doneFrom: Double?
        var error: String?
        var throwing: Error?

        func access(_ recordings: [SpoolRecording]) -> SpoolAccess {
            SpoolAccess(
                recordings: { recordings },
                transcribe: { [self] id, from, to, seconds in
                    asked.append((id, from, to, seconds))
                    if let throwing { throw throwing }
                    let done = max(from, doneFrom ?? from)
                    var words: [Word] = []
                    for (at, speaker, text) in said where at >= done && at < to {
                        for (i, w) in text.split(separator: " ").enumerated() {
                            words.append(Word(word: String(w), start: at + Double(i) * 0.3, end: at + Double(i) * 0.3 + 0.25, speaker: speaker))
                        }
                    }
                    return SpoolSlice(words: error == nil ? words : [], from: from, to: to, doneFrom: done, duration: to, error: error)
                },
                stop: { [self] in stopped += 1 })
        }
    }

    /// Recording since 18:10:00, 20 minutes so far.
    func going() -> SpoolRecording {
        SpoolRecording(id: "20261109-181000-AAAA", startedAt: now.addingTimeInterval(-1_200), duration: 1_200, closed: false)
    }

    func server(_ helper: Helper, _ recordings: [SpoolRecording]) -> MCPServer {
        MCPServer(store: NoteStore(root: root), now: { [now] in now }, spool: helper.access(recordings))
    }

    /// A note from 17:00:00 to 17:00:05 with two lines.
    func writeNote() throws {
        let w = [
            Word(word: "the", start: 0, end: 0.3, speaker: "Speaker 1"), Word(word: "pricing", start: 0.4, end: 0.7, speaker: "Speaker 1"),
            Word(word: "page.", start: 0.8, end: 1.1, speaker: "Speaker 1"),
            Word(word: "Ship", start: 3.5, end: 3.8, speaker: "Speaker 2"), Word(word: "Friday.", start: 3.9, end: 4.2, speaker: "Speaker 2"),
        ]
        _ = try NoteWriter.write(
            Transcript(
                startedAt: now.addingTimeInterval(-5_400), duration: 5, text: "", words: w, turns: [], asrSeconds: 0, diarizationSeconds: 0,
                model: "test"), to: root)
    }

    func testCurrentConversationIsAllOfIt() throws {
        let helper = Helper()
        helper.said = [(2, "Speaker 1", "so where were we"), (600, "Speaker 2", "the logo files by Friday"), (1_190, "Speaker 1", "sounds good")]
        let reply = try server(helper, [going()]).call("current_conversation", [:])
        XCTAssertTrue(reply.contains("## Not a note yet: started 2026-11-09 18:10:00, 20m 0s so far"), reply)
        XCTAssertTrue(reply.contains("[00:02] (18:10:02) Speaker 1: so where were we"), reply)
        XCTAssertTrue(reply.contains("[10:00] (18:20:00) Speaker 2: the logo files by Friday"), reply)
        XCTAssertTrue(reply.contains("[19:50] (18:29:50) Speaker 1: sounds good"), reply)
        XCTAssertTrue(reply.contains("| Speaker 1, Speaker 2"), reply)
        XCTAssertEqual(helper.asked.count, 1)
        XCTAssertEqual(helper.asked[0].from, 0)
        XCTAssertEqual(helper.asked[0].to, 1_200)
        XCTAssertLessThanOrEqual(helper.asked[0].seconds, MCPServer.audioSeconds)
    }

    func testCurrentConversationSaysWhatIsntDoneYet() throws {
        let helper = Helper()
        helper.said = [(2, "Speaker 1", "early words"), (900, "Speaker 1", "late words")]
        helper.doneFrom = 600
        let reply = try server(helper, [going()]).call("current_conversation", [:])
        XCTAssertFalse(reply.contains("early words"))
        XCTAssertTrue(reply.contains("late words"))
        XCTAssertTrue(reply.contains("Not transcribed yet: 18:10:00 to 18:20:00"), reply)
        XCTAssertTrue(reply.contains("call again in a minute"), reply)
    }

    func testNothingGoingOn() throws {
        try writeNote()
        let reply = try server(Helper(), []).call("current_conversation", [:])
        XCTAssertTrue(reply.contains("Sona isn't running"), reply)
        XCTAssertTrue(reply.contains("The last conversation was 2026-11-09/17-00"), reply)
        XCTAssertTrue(reply.contains("read_conversation"), reply)
    }

    func testAFailedTranscriptionSaysWhy() throws {
        let helper = Helper()
        helper.error = "The v2 models aren't downloaded yet."
        XCTAssertTrue(try server(helper, [going()]).call("current_conversation", [:]).contains("Couldn't transcribe it: The v2 models aren't downloaded yet."))
        helper.error = nil
        helper.throwing = SpoolFailure("The transcriber stopped.")
        XCTAssertTrue(try server(helper, [going()]).call("current_conversation", [:]).contains("Couldn't transcribe it: The transcriber stopped."))
    }

    /// The notes and the audio not yet in a note, in one stretch, in time order, only what's inside it.
    func testTranscriptStitchesNotesAndAudio() throws {
        try writeNote()
        let helper = Helper()
        helper.said = [(400, "Speaker 1", "inside the stretch"), (700, "Speaker 1", "after the stretch")]
        let s = server(helper, [going()])
        let reply = try s.call("transcript", ["from": "17:00", "to": "18:20"])
        XCTAssertTrue(reply.contains("What was said 2026-11-09 17:00:00 to 2026-11-09 18:20:00:"), reply)
        let note = try XCTUnwrap(reply.range(of: "pricing page."))
        let audio = try XCTUnwrap(reply.range(of: "inside the stretch"))
        XCTAssertLessThan(note.lowerBound, audio.lowerBound, "in time order")
        XCTAssertTrue(reply.contains("(18:16:40) Speaker 1: inside the stretch"), reply)
        XCTAssertFalse(reply.contains("after the stretch"), reply)
        // Asked from 0 s (18:10, its start) to 600 s (18:20) of the recording.
        XCTAssertEqual(helper.asked.last?.from, 0)
        XCTAssertEqual(helper.asked.last?.to, 600)
        // Only lines inside the stretch: the note's second line starts at 17:00:03.
        let late = try s.call("transcript", ["from": "2026-11-09 17:00:03", "to": "17:30"])
        XCTAssertFalse(late.contains("Speaker 1: the pricing page."), late)
        XCTAssertTrue(late.contains("Ship Friday."), late)
        XCTAssertEqual(helper.asked.count, 1, "the recording started after this stretch")
        // Nothing then.
        XCTAssertTrue(try s.call("transcript", ["from": "2026-11-08 09:00", "to": "2026-11-08 10:00"]).contains("Nothing was heard then"))
    }

    func testTranscriptIsCutWithWhereToGoOn() throws {
        let helper = Helper()
        let long = String(repeating: "word ", count: 100)  // 30 s of words, then 10 s of quiet: a line each
        helper.said = (0..<200).map { (Double($0) * 40, "Speaker 1", long) }
        let hours = SpoolRecording(id: "x", startedAt: now.addingTimeInterval(-9_000), duration: 9_000, closed: false)
        let reply = try server(helper, [hours]).call("transcript", ["from": "16:00"])
        XCTAssertLessThan(reply.count, MCPServer.replyBudget + 2_000)
        XCTAssertTrue(reply.contains("cut off here. Call again with from=\"2026-11-09 17:14:40\" for the rest."), String(reply.suffix(300)))
        // One line longer than a whole reply is still shown, so going on always gets somewhere.
        helper.said = [(0, "Speaker 1", String(repeating: "word ", count: 20_000)), (9_000 - 60, "Speaker 1", "the end")]
        let huge = try server(helper, [hours]).call("transcript", ["from": "16:00"])
        XCTAssertTrue(huge.contains("Speaker 1: word word"), String(huge.prefix(300)))
        XCTAssertTrue(huge.contains("Call again with from=\"2026-11-09 18:29:00\""), String(huge.suffix(300)))
    }

    /// A recording whose note is already written (the spool lets go of it a moment later) is read from the note.
    func testARecordingWithItsNoteWrittenIsLeftToTheNote() throws {
        try writeNote()
        let note = try XCTUnwrap(NoteStore(root: root).conversations().first)
        var done = going()
        done.closed = true
        done.note = note.id + ".md"
        let helper = Helper()
        helper.said = [(400, "Speaker 1", "from the audio")]
        let reply = try server(helper, [done]).call("transcript", ["from": "17:00"])
        XCTAssertFalse(reply.contains("from the audio"))
        XCTAssertTrue(helper.asked.isEmpty)
    }

    func testLiveReachesPastTenMinutes() throws {
        let helper = Helper()
        helper.said = [(30, "Speaker 1", "twenty minutes ago")]
        let s = server(helper, [going()])
        let reply = try s.call("live", ["minutes": 30])
        XCTAssertTrue(reply.contains("The live transcript only keeps 10 minutes"), reply)
        XCTAssertTrue(reply.contains("(18:10:30) Speaker 1: twenty minutes ago"), reply)
        XCTAssertEqual(helper.asked.last?.from, 0)
        let since = try s.call("live", ["since": "18:05"])
        XCTAssertTrue(since.contains("What was said 2026-11-09 18:05:00 to 2026-11-09 18:30:00:"), since)
        // Up to 10 minutes it's still the live transcript (none here: the app never ran).
        XCTAssertTrue(try s.call("live", ["minutes": 5]).contains("never run"))
        XCTAssertEqual(helper.asked.count, 2)
        XCTAssertThrowsError(try s.call("live", ["since": "tomorrow-ish"]))
        XCTAssertThrowsError(try s.call("live", ["minutes": 0]))
    }

    func testSearchCoversAudioNotYetInANote() throws {
        try writeNote()
        let helper = Helper()
        helper.said = [(100, "Speaker 1", "the pricing is wrong"), (200, "Speaker 2", "pricing again")]
        let s = server(helper, [going()])
        let reply = try s.call("search", ["query": "pricing"])
        XCTAssertTrue(reply.contains("2 matching line(s) in audio not yet in a note"), reply)
        XCTAssertTrue(reply.contains("not a note yet (started 18:10:00) · 2026-11-09 [03:20] (18:13:20) Speaker 2: pricing again"), reply)
        XCTAssertTrue(reply.contains("2026-11-09/17-00"), "and the note's line")
        let newest = try XCTUnwrap(reply.range(of: "pricing again")), older = try XCTUnwrap(reply.range(of: "the pricing is wrong"))
        XCTAssertLessThan(newest.lowerBound, older.lowerBound, "newest first")
        // By speaker, and skipped on request or on later pages.
        let bySpeaker = try s.call("search", ["query": "pricing", "speaker": "speaker 1"])
        XCTAssertTrue(bySpeaker.contains("the pricing is wrong"))
        XCTAssertFalse(bySpeaker.contains("pricing again"))
        let asked = helper.asked.count
        XCTAssertFalse(try s.call("search", ["query": "pricing", "in_progress": false]).contains("not a note yet"))
        XCTAssertFalse(try s.call("search", ["query": "pricing", "offset": 1]).contains("not a note yet"))
        XCTAssertEqual(helper.asked.count, asked)
        // Only in the audio: the notes say they have none.
        let only = try s.call("search", ["query": "wrong"])
        XCTAssertTrue(only.contains("1 matching line(s) in audio not yet in a note"), only)
        XCTAssertTrue(only.contains("No lines in the notes match \"wrong\"."), only)
        // Outside the dates asked for: not transcribed at all.
        let before = helper.asked.count
        _ = try s.call("search", ["query": "pricing", "to": "2026-11-08"])
        XCTAssertEqual(helper.asked.count, before)
    }

    func testTurningAIAccessOffStopsTheHelper() throws {
        let helper = Helper()
        var on = true
        let s = MCPServer(store: NoteStore(root: root), now: { [now] in now }, enabled: { on }, spool: helper.access([going()]))
        on = false
        for name in ["current_conversation", "transcript", "live"] {
            let reply = try XCTUnwrap(s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":{"from":"18:00"}}}"#))
            XCTAssertTrue(reply.contains(MCPServer.offMessage), name)
        }
        XCTAssertEqual(helper.stopped, 3)
        XCTAssertTrue(helper.asked.isEmpty)
    }

    func testTimes() throws {
        let s = server(Helper(), [])
        XCTAssertEqual(try s.time("18:05"), now.addingTimeInterval(-1_500))
        XCTAssertEqual(try s.time("9:05:30"), ConversationNote.parse("2026-11-09", "09:05:30"))
        XCTAssertEqual(try s.time("18:29"), now.addingTimeInterval(-60))
        XCTAssertEqual(try s.time("23:00"), ConversationNote.parse("2026-11-08", "23:00:00"), "still to come today: yesterday")
        XCTAssertEqual(try s.time("2026-11-08 07:15"), ConversationNote.parse("2026-11-08", "07:15:00"))
        XCTAssertEqual(try s.time("2026-11-08T07:15:10"), ConversationNote.parse("2026-11-08", "07:15:10"))
        XCTAssertEqual(try s.time("2026-10-29T14:03:12+10:00"), Date(timeIntervalSince1970: 1_793_246_592))
        XCTAssertEqual(try s.time("2026-11-08"), ConversationNote.parse("2026-11-08", "00:00"))
        XCTAssertEqual(try s.time("2026-11-08", end: true), ConversationNote.parse("2026-11-09", "00:00"))
        XCTAssertEqual(try s.time("now"), now)
        XCTAssertNil(try s.time(nil))
        for bad in ["25:00", "18:61", "yesterday at 5", "2026-11-08 7", "18:05:00 2026-11-08"] {
            XCTAssertThrowsError(try s.time(bad), bad)
        }
        XCTAssertThrowsError(try s.call("transcript", [:]))
        XCTAssertThrowsError(try s.call("transcript", ["from": "18:20", "to": "18:10"]))
    }

    /// What the spool holds, from its files alone: the audio isn't opened.
    func testRecordingsAreReadFromTheSpool() throws {
        let dir = home.appendingPathComponent("Spool")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("failed"), withIntermediateDirectories: true)
        func wav(_ name: String, seconds: Double, in folder: URL? = nil) throws {
            try Data(count: 44 + Int(seconds * 32_000)).write(to: (folder ?? dir).appendingPathComponent(name))
        }
        try wav("20261109-181000-AAAA.wav", seconds: 2.5)
        try wav("20261109-181000-AAAA.mac.wav", seconds: 1)
        try Data(#"{"id":"20261109-181000-AAAA","startedAt":"2026-11-09T08:10:00Z","speechEnd":2,"speechSeconds":2,"closed":false,"attempts":0}"#.utf8)
            .write(to: dir.appendingPathComponent("20261109-181000-AAAA.json"))
        try wav("20261109-170000-BBBB.wav", seconds: 1)  // no .json: the app stopped before writing it
        try wav("20261109-160000-CCCC.wav", seconds: 1, in: dir.appendingPathComponent("failed"))
        let all = SpoolRecording.all(in: dir)
        XCTAssertEqual(all.map(\.id).sorted(), ["20261109-170000-BBBB", "20261109-181000-AAAA"])
        let going = try XCTUnwrap(all.first { $0.id == "20261109-181000-AAAA" })
        XCTAssertEqual(going.duration, 2.5)
        XCTAssertFalse(going.closed)
        XCTAssertEqual(going.startedAt, Date(timeIntervalSince1970: 1_794_211_800))
        XCTAssertTrue(SpoolRecording.all(in: home.appendingPathComponent("nope")).isEmpty)
    }
}
