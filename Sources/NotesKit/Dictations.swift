import Foundation

/// Dictations pasted while always-on is off, so there's still a record of them: the text and the time, never
/// audio, in `<notes folder>/Dictations/YYYY-MM-DD.md`, one `[HH:mm:ss+10:00] text` line each (the local time and
/// its UTC offset; lines from before 30 Oct 2026 have no offset and are local time), oldest first. Private like
/// the notes (folder 0700, files 0600). With always-on on they're in the conversation notes already.
/// Not safe to call from two threads at once: the app uses one queue.
public enum Dictations {
    public struct Entry: Hashable, Sendable {
        public var time: Date
        /// "14:03:12".
        public var clock: String
        public var text: String
    }

    public static func folder(notes: URL) -> URL { notes.appendingPathComponent("Dictations", isDirectory: true) }

    static func file(_ day: String, notes: URL) -> URL { folder(notes: notes).appendingPathComponent(day + ".md") }

    public static func append(_ text: String, at time: Date, notes: URL) throws {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        try NoteWriter.makePrivateDirectory(folder(notes: notes))
        let fd = open(file(NoteWriter.dayString(time), notes: notes).path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw NoteWriter.posixError() }
        defer { close(fd) }
        let data = Data("[\(NoteWriter.timeString(time, "HH:mm:ssxxx"))] \(line)\n\n".utf8)
        guard data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count else { throw NoteWriter.posixError() }
    }

    /// Days that have dictations, newest first ("2026-10-29").
    public static func days(notes: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder(notes: notes).path)) ?? [])
            .filter { $0.hasSuffix(".md") && SearchIndex.isDay(String($0.dropLast(3))) }
            .map { String($0.dropLast(3)) }
            .sorted(by: >)
    }

    /// One day's dictations, newest first.
    public static func entries(day: String, notes: URL) -> [Entry] {
        guard let text = try? String(contentsOf: file(day, notes: notes), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { parse($0, day: day) }.reversed()
    }

    /// `[14:03:12+10:00] text`, or `[14:03:12] text` in this Mac's time zone.
    static func parse(_ line: Substring, day: String) -> Entry? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let stamp = String(line[line.index(after: line.startIndex)..<close])
        let time: Date?
        switch stamp.count {
        case 8: time = ConversationNote.parse(day, stamp)
        case 14: time = NoteWriter.formatter("yyyy-MM-dd HH:mm:ssxxx", zone: .current).date(from: "\(day) \(stamp)")
        default: time = nil
        }
        guard let time else { return nil }
        return Entry(time: time, clock: String(stamp.prefix(8)), text: line[line.index(after: close)...].trimmingCharacters(in: .whitespaces))
    }

    /// "Delete the last N minutes": dictations from `cut` to `end` (the click: one pasted while the rest of the
    /// delete ran stays) are removed. Times are whole seconds, so one in the second before `cut`, or in `end`'s
    /// second, goes too. Other lines stay; a day left with nothing is deleted. Returns how many went. Looks at days
    /// up to 26 hours before `cut` (each file is named in the time zone it was written in).
    @discardableResult
    public static func forget(from cut: Date, to end: Date, notes: URL) -> Int {
        var removed = 0
        for day in days(notes: notes) where day >= NoteWriter.dayString(cut.addingTimeInterval(-1 - 26 * 3600)) {
            let url = file(day, notes: notes)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var kept: [Substring] = []
            var dropped = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if let entry = parse(line, day: day), entry.time.addingTimeInterval(1) > cut, entry.time <= end {
                    removed += 1
                    dropped = true
                } else if line.isEmpty, dropped {
                    dropped = false  // the blank line after a removed one
                } else {
                    kept.append(line)
                    dropped = false
                }
            }
            let rest = kept.joined(separator: "\n")
            guard rest != text else { continue }
            if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try? NoteWriter.writePrivate(Data(rest.utf8), to: url)
            }
        }
        return removed
    }
}
