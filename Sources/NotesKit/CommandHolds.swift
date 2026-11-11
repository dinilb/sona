import Foundation

/// The stretches when the Command key was held while talking: "agent command" mode. Whatever is said over one is
/// meant for an AI agent. The app records each hold (`Commands/YYYY-MM-DD.jsonl` in the support folder, one
/// `{"start","end"}` line each, ISO 8601), and the live feed and the MCP server mark the lines said over one.
public struct CommandHolds: Sendable {
    public struct Hold: Codable, Equatable, Sendable {
        public var start: String
        public var end: String
        public init(start: Date, end: Date) {
            self.start = NoteWriter.iso(start)
            self.end = NoteWriter.iso(end)
        }
        public var range: ClosedRange<Date>? {
            guard let a = Self.parse(start), let b = Self.parse(end), a <= b else { return nil }
            return a...b
        }
        static func parse(_ s: String) -> Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
    }

    /// Holds shorter than this are a shortcut (⌘C), not talking.
    public static let minimumSeconds = 0.5
    /// Words come in a little after they're said, and a hold is let go a little after the last one.
    public static let slack = 0.4

    public var ranges: [ClosedRange<Date>]

    public init(ranges: [ClosedRange<Date>] = []) { self.ranges = ranges }

    static var folder: URL { Paths.support.appendingPathComponent("Commands") }

    /// The holds on one day (`2026-11-10`).
    public static func load(day: String) -> CommandHolds {
        let url = folder.appendingPathComponent("\(day).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return CommandHolds() }
        let decoder = JSONDecoder()
        return CommandHolds(ranges: text.split(separator: "\n").compactMap {
            (try? decoder.decode(Hold.self, from: Data($0.utf8)))?.range
        })
    }

    /// The holds on the days these two moments fall on.
    public static func load(around from: Date, to: Date) -> CommandHolds {
        var days = Set([NoteWriter.dayString(from), NoteWriter.dayString(to)])
        days.insert(NoteWriter.dayString(Date()))
        return CommandHolds(ranges: days.sorted().flatMap { load(day: $0).ranges })
    }

    /// Adds a finished hold to its day's file (private to this user). False if it was too short to count.
    @discardableResult
    public static func append(start: Date, end: Date) -> Bool {
        guard end.timeIntervalSince(start) >= minimumSeconds else { return false }
        Paths.ensure(folder)
        let url = folder.appendingPathComponent("\(NoteWriter.dayString(start)).jsonl")
        guard var line = try? JSONEncoder().encode(Hold(start: start, end: end)) else { return false }
        line.append(10)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
        return true
    }

    /// Was anything said between `from` and `to` while a hold was on (`open` is a hold still going)?
    public func covers(from: Date, to: Date, open: Date? = nil) -> Bool {
        if let open, to >= open.addingTimeInterval(-Self.slack) { return true }
        return ranges.contains { from <= $0.upperBound.addingTimeInterval(Self.slack) && to >= $0.lowerBound.addingTimeInterval(-Self.slack) }
    }
}

public extension CommandHolds {
    /// A line cut where holds start and stop: each piece with whether it was said over a hold. Words have no
    /// times of their own here, so they're spread evenly over the line (good to about a word).
    func pieces(of text: String, from start: Date, to end: Date, open: Date? = nil) -> [(text: String, command: Bool)] {
        let words = text.split(separator: " ")
        guard words.count > 1, end > start else { return [(text, covers(from: start, to: end, open: open))] }
        let step = end.timeIntervalSince(start) / Double(words.count)
        var out: [(text: String, command: Bool)] = []
        for (i, word) in words.enumerated() {
            let a = start.addingTimeInterval(step * Double(i)), b = a.addingTimeInterval(step)
            let on = covers(from: a, to: b, open: open)
            if let last = out.last, last.command == on {
                out[out.count - 1].text += " " + word
            } else {
                out.append((String(word), on))
            }
        }
        return out
    }
}

public extension CommandHolds {
    /// The words of a line said between `from` and `to` (spread evenly over the line, as in `pieces`).
    static func words(of text: String, lineStart: Date, lineEnd: Date, from: Date, to: Date) -> String {
        let words = text.split(separator: " ")
        guard words.count > 1, lineEnd > lineStart else {
            return lineEnd >= from && lineStart <= to ? text : ""
        }
        let step = lineEnd.timeIntervalSince(lineStart) / Double(words.count)
        return words.enumerated().filter { i, _ in
            let mid = lineStart.addingTimeInterval(step * (Double(i) + 0.5))
            return mid >= from && mid <= to
        }.map { String($0.element) }.joined(separator: " ")
    }
}

public extension LiveFeed.Line {
    static let commandMark = "[AGENT COMMAND]"
}
