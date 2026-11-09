import XCTest

@testable import NotesKit

final class LiveFeedTests: XCTestCase {
    /// `NoteWriter.iso` is in now.json, status.json and the notes' sidecars: the exact text mustn't change.
    func testISOFormat() throws {
        func zone(_ id: String) throws -> TimeZone { try XCTUnwrap(TimeZone(identifier: id)) }
        let october = Date(timeIntervalSince1970: 1_793_246_592)  // 2026-10-29 04:03:12 UTC
        let july = Date(timeIntervalSince1970: 1_782_964_992)  // 2026-07-02 04:03:12 UTC
        let november = october.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(NoteWriter.iso(october, zone: try zone("Australia/Brisbane")), "2026-10-29T14:03:12+10:00")
        XCTAssertEqual(NoteWriter.iso(october, zone: try zone("UTC")), "2026-10-29T04:03:12Z")
        XCTAssertEqual(NoteWriter.iso(october, zone: TimeZone(secondsFromGMT: 0)!), "2026-10-29T04:03:12Z")
        // Half-hour offsets, with and without summer time.
        XCTAssertEqual(NoteWriter.iso(october, zone: try zone("Asia/Kolkata")), "2026-10-29T09:33:12+05:30")
        XCTAssertEqual(NoteWriter.iso(october, zone: try zone("Australia/Adelaide")), "2026-10-29T14:33:12+10:30")
        XCTAssertEqual(NoteWriter.iso(july, zone: try zone("Australia/Adelaide")), "2026-07-02T13:33:12+09:30")
        XCTAssertEqual(NoteWriter.iso(october, zone: try zone("America/St_Johns")), "2026-10-29T01:33:12-02:30")
        // Summer time and after it ends (1 November in New York).
        XCTAssertEqual(NoteWriter.iso(october, zone: try zone("America/New_York")), "2026-10-29T00:03:12-04:00")
        XCTAssertEqual(NoteWriter.iso(november, zone: try zone("America/New_York")), "2026-11-27T23:03:12-05:00")
        // Rounded to the millisecond, then cut to the second, as ISO8601DateFormatter did.
        XCTAssertEqual(NoteWriter.iso(october.addingTimeInterval(0.9994), zone: try zone("Australia/Brisbane")), "2026-10-29T14:03:12+10:00")
        XCTAssertEqual(NoteWriter.iso(october.addingTimeInterval(0.9996), zone: try zone("Australia/Brisbane")), "2026-10-29T14:03:13+10:00")
        // This Mac's zone by default.
        XCTAssertEqual(NoteWriter.iso(october), NoteWriter.iso(october, zone: .current))

        // The same text as the formatter it replaced, near whole seconds too.
        let old = ISO8601DateFormatter()
        var rng = SystemRandomNumberGenerator()
        for id in ["Australia/Brisbane", "Australia/Adelaide", "Asia/Kathmandu", "America/New_York", "Europe/London", "UTC"] {
            old.timeZone = try zone(id)
            for i in 0..<2_000 {
                var t = Double.random(in: 1_700_000_000...2_000_000_000, using: &rng)
                if i % 2 == 0 { t = t.rounded(.down) + 1 - Double.random(in: 0...0.002, using: &rng) }
                let date = Date(timeIntervalSince1970: t)
                XCTAssertEqual(NoteWriter.iso(date, zone: try zone(id)), old.string(from: date), "\(id) \(t)")
            }
        }
    }

    /// Formatters are kept per format and zone: the same format in another zone must not reuse one.
    func testTimeStringPerZone() throws {
        let october = Date(timeIntervalSince1970: 1_793_246_592)  // 2026-10-29 04:03:12 UTC
        let brisbane = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
        let adelaide = try XCTUnwrap(TimeZone(identifier: "Australia/Adelaide"))
        XCTAssertEqual(NoteWriter.timeString(october, "HH:mm:ss", zone: brisbane), "14:03:12")
        XCTAssertEqual(NoteWriter.timeString(october, "HH:mm:ss", zone: adelaide), "14:33:12")
        XCTAssertEqual(NoteWriter.timeString(october, "HH:mm", zone: brisbane), "14:03")
        XCTAssertEqual(NoteWriter.dayString(october, zone: TimeZone(secondsFromGMT: -12 * 3600)!), "2026-10-28")
        XCTAssertEqual(ConversationNote.parse("2026-10-29", "14:33:12", zone: adelaide), october)
        XCTAssertEqual(ConversationNote.parse("2026-10-29", "14:03", zone: brisbane), october.addingTimeInterval(-12))
        XCTAssertEqual(MCPServer.parseISO("2026-10-29T14:03:12+10:00"), october)
        XCTAssertEqual(MCPServer.parseISO("2026-10-29T04:03:12Z"), october)
        XCTAssertNil(MCPServer.parseISO("2026-10-29 14:03:12"))
    }

    /// What the app's `publish()` does up to 3 times a second in a long conversation: 400 lines into a feed, compared
    /// with the last one, then encoded for `now.json`. Prints the cost; fails only if it's grossly slow again (it was
    /// ~200 ms when every time made its own ISO8601DateFormatter).
    func testPublishCost() throws {
        let now = Date()
        let text = "so the pricing page needs work before we ship it on Friday"
        func lines(_ n: Int) -> [LiveFeed.Line] {
            (0..<n).map { i in
                let start = now.addingTimeInterval(Double(i - n) * 1.5)
                return LiveFeed.Line(
                    speaker: "Speaker \(i % 2 + 1)", settled: i < n - 2, start: start, end: start.addingTimeInterval(1.2), text: text)
            }
        }
        var last = LiveFeed(listening: true, engine: "Test", speakers: true, lines: lines(400))
        let rounds = 20
        var build = 0.0, encode = 0.0
        for _ in 0..<rounds {
            let t0 = Date()
            let feed = LiveFeed(listening: true, engine: "Test", speakers: true, lines: lines(400))
            XCTAssertTrue(feed.sameContent(as: last))
            last = feed
            let t1 = Date()
            _ = try JSONEncoder().encode(feed)
            build += t1.timeIntervalSince(t0)
            encode += Date().timeIntervalSince(t1)
        }
        let ms = { (s: Double) in s / Double(rounds) * 1000 }
        print(String(format: "publish of 400 lines: %.2f ms to build and compare, %.2f ms to encode, %.2f ms in all",
            ms(build), ms(encode), ms(build + encode)))
        XCTAssertLessThan(ms(build + encode), 50)
    }

    /// now.json is replaced whole (never half-written), readable by this user only, with no temp file left over.
    func testWriteReplacesTheFilePrivately() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sona-feed-\(UUID().uuidString)")
        let previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        setenv("SONA_HOME", home.path, 1)
        defer {
            if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") }
            try? FileManager.default.removeItem(at: home)
        }
        let now = Date()
        for text in ["first", "second"] {
            LiveFeed(listening: true, engine: "Test", speakers: false, lines: [
                .init(speaker: nil, settled: true, start: now, end: now, text: text)
            ]).write()
        }
        XCTAssertEqual(LiveFeed.read()?.feed.lines.map(\.text), ["second"])
        XCTAssertEqual(LiveFeed.read()?.running, true)
        let mode = try FileManager.default.attributesOfItem(atPath: LiveFeed.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let dir = LiveFeed.file.deletingLastPathComponent().path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["now.json"])
    }
}
