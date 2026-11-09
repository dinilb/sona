import Foundation
import os

/// Writes one conversation as `<Conversations>/YYYY-MM-DD/HH-MM <title>.md` plus a `.json` sidecar
/// (every word with its timestamps and speaker).
public enum NoteWriter {
    public struct Sidecar: Codable, Sendable {
        public struct Timing: Codable, Sendable {
            public var asrSeconds: Double
            public var diarizationSeconds: Double
            public var totalSeconds: Double
            public var realTimeFactor: Double
        }
        public var startedAt: String
        public var durationSeconds: Double
        public var model: String
        public var diarizer: String
        public var source: String?
        /// True, with the reason, when this is likely media this Mac played (a video, a podcast), not people
        /// talking. Absent otherwise.
        public var media: Bool?
        public var mediaReason: String?
        public var speakers: [String]
        public var text: String
        public var timing: Timing
        public var turns: [Turn]
        public var words: [Word]
    }

    /// Returns the markdown path it wrote. `summary` is the hook for an optional local summary later
    /// (v1 never passes one): it goes under "## Summary" above the transcript. `media`: why it's likely
    /// media; the note is then marked (`media: true`, tag `likely-media`) so AIs can skip it.
    ///
    /// `reuse`: the path an earlier attempt reserved for this conversation. It's overwritten, so a retry
    /// never makes a second note. Otherwise a new name is created exclusively (another process writing the
    /// same minute gets "... 2") and handed to `reserved` before anything goes into it.
    ///
    /// `words`: the words list ("Sonar" → "Sona"), applied to the words themselves, so the lines, the title and
    /// the .json all say the same.
    @discardableResult
    public static func write(
        _ t: Transcript, to conversations: URL, source: String? = nil, summary: String? = nil, media: String? = nil,
        words: WordFixer = .none, reuse: URL? = nil, reserved: (URL) throws -> Void = { _ in }
    ) throws -> URL {
        var t = t
        if !words.isEmpty {
            t.words = words.apply(t.words)
            t.text = words.apply(t.text)
        }
        let lines = Lines.from(t.words)
        // No words at all only happens to a recording made on purpose (the iPhone, the watch): the Mac drops those.
        let title = Title.make(from: lines) ?? (lines.isEmpty ? "No speech transcribed" : "Conversation")

        let md: URL
        var created = false
        if let reuse {
            md = reuse
            try makePrivateDirectory(md.deletingLastPathComponent())
        } else {
            let dir = conversations.appendingPathComponent(dayString(t.startedAt), isDirectory: true)
            try makePrivateDirectory(dir)
            if isRealDirectory(conversations.path) { chmod(conversations.path, 0o700) }  // not through a symlink
            md = try createExclusively(in: dir, stem: "\(timeString(t.startedAt, "HH-mm")) \(Title.fileSafe(title))")
            created = true
            do { try reserved(md) } catch {
                unlink(md.path)
                throw error
            }
        }
        let json = md.deletingPathExtension().appendingPathExtension("json")

        let text = markdown(t, lines: lines, title: title, source: source, summary: summary, media: media)
        do { try writePrivate(Data(text.utf8), to: md) } catch {
            // Never leave an empty "ghost" note behind (a full disk, say); the retry writes it again.
            if created, (try? FileManager.default.attributesOfItem(atPath: md.path)[.size] as? Int) == 0 { unlink(md.path) }
            throw error
        }

        let total = t.asrSeconds + t.diarizationSeconds
        let sidecar = Sidecar(
            startedAt: iso(t.startedAt),
            durationSeconds: round3(t.duration),
            model: t.model,
            diarizer: "pyannote-community-1 + VBx (FluidAudio offline)",
            source: source,
            media: media == nil ? nil : true,
            mediaReason: media,
            speakers: t.speakers,
            text: t.text,
            timing: .init(
                asrSeconds: round3(t.asrSeconds), diarizationSeconds: round3(t.diarizationSeconds),
                totalSeconds: round3(total), realTimeFactor: total > 0 ? round3(t.duration / total) : 0),
            turns: t.turns.map { Turn(speaker: $0.speaker, start: round3($0.start), end: round3($0.end)) },
            words: t.words.map {
                Word(word: $0.word, start: round3($0.start), end: round3($0.end), speaker: $0.speaker, track: $0.track, echo: $0.echo)
            }
        )
        try writeSidecar(sidecar, to: json)
        return md
    }

    /// `zone`: the time zone for its date, start and end (a note cut later keeps the one it was written in).
    public static func markdown(
        _ t: Transcript, lines: [Line], title: String, source: String?, summary: String? = nil, media: String? = nil,
        zone: TimeZone = .current
    ) -> String {
        let end = t.startedAt.addingTimeInterval(t.duration)
        var out = "---\n"
        out += "title: \(yamlString(title))\n"
        out += "date: \(dayString(t.startedAt, zone: zone))\n"
        out += "start: \"\(timeString(t.startedAt, "HH:mm:ss", zone: zone))\"\n"
        out += "end: \"\(timeString(end, "HH:mm:ss", zone: zone))\"\n"
        out += "duration: \(Lines.durationText(t.duration))\n"
        out += "speakers: [\(t.speakers.map(yamlString).joined(separator: ", "))]\n"
        out += "model: \(t.model)\n"
        if let source { out += "source: \(yamlString(source))\n" }
        if let media {
            out += "media: true\n"
            out += "media_reason: \(yamlString(media))\n"
        }
        var tags = ["sona"]
        if media != nil { tags.append("likely-media") }
        if mentionsReminder(t.text) { tags.append("reminder") }
        out += "tags: [\(tags.joined(separator: ", "))]\n"
        out += "---\n\n"
        out += "# \(title)\n\n"
        if let summary, !summary.isEmpty {
            out += "## Summary\n\n\(summary)\n\n## Transcript\n\n"
        }
        if lines.isEmpty { out += "_(no speech transcribed)_\n" }
        for line in lines {
            out += "[\(Lines.clock(line.start))] \(line.speaker): \(line.text)\n\n"
        }
        return out
    }

    /// "Remind me to...", said to the watch or the phone (or in a conversation): the note gets a `reminder` tag, so an
    /// AI reading the notes through MCP can find the reminders without reading everything.
    static func mentionsReminder(_ text: String) -> Bool {
        text.range(of: #"\bremind(?:er)?s? me\b|\breminders?\b|\bdon'?t (?:let me )?forget\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func writeSidecar(_ sidecar: Sidecar, to url: URL) throws {
        try writePrivate(try sidecarData(sidecar), to: url)
    }

    static func sidecarData(_ sidecar: Sidecar) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(sidecar)
    }

    /// `<stem>.md`, else `<stem> 2.md`, ...: the first free name, created empty (0600) in one step, so two
    /// processes writing a conversation from the same minute with the same title never overwrite each other.
    static func createExclusively(in dir: URL, stem: String) throws -> URL {
        var base = stem
        var n = 2
        while true {
            let md = dir.appendingPathComponent(base + ".md")
            let fd = open(md.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                close(fd)
                return md
            }
            guard errno == EEXIST else { throw posixError() }
            base = "\(stem) \(n)"
            n += 1
        }
    }

    // MARK: privacy
    // Transcripts and kept audio are private: folders 0700, files 0600, so other accounts on this Mac
    // can't read them.

    /// Creates `dir` (and any missing parents) 0700, and makes `dir` itself 0700 if it already existed.
    public static func makePrivateDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
    }

    /// Replaces `url` with `data` atomically (temp file, then rename); the file is readable by this user only.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let tmp = try privateTemp(data, for: url)
        do { try move(tmp, to: url) } catch {
            unlink(tmp.path)
            throw error
        }
    }

    /// `data` in a new hidden temp file (0600) next to `url`, for `move` to put in its place.
    static func privateTemp(_ data: Data, for url: URL) throws -> URL {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw posixError() }
        let failure: Int32 = data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                if n <= 0 { return errno == 0 ? EIO : errno }
                done += n
            }
            return 0
        }
        close(fd)
        guard failure == 0 else {
            unlink(tmp.path)
            throw posixError(failure)
        }
        return tmp
    }

    /// Renames `tmp` over `url`, in one step (they're in the same folder).
    static func move(_ tmp: URL, to url: URL) throws {
        guard rename(tmp.path, url.path) == 0 else { throw posixError() }
    }

    /// For notes written before they were private: `Conversations` and its day folders become 0700 on every
    /// launch (a few chmods), and the files in them 0600 once per notes folder (the marker in the support
    /// folder remembers it, so thousands of notes aren't walked every launch).
    public static func tightenPermissions(
        _ conversations: URL, marker: URL = Paths.support.appendingPathComponent(".private-notes")
    ) {
        let root = conversations.standardizedFileURL.path
        guard isRealDirectory(root) else { return }
        chmod(root, 0o700)
        let done = (try? String(contentsOf: marker, encoding: .utf8)) == root
        for day in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where SearchIndex.isDay(day) {
            let dir = root + "/" + day
            guard isRealDirectory(dir) else { continue }  // never chmod through a symlink
            chmod(dir, 0o700)
            guard !done else { continue }
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                var st = stat()
                if lstat(dir + "/" + file, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { chmod(dir + "/" + file, 0o600) }
            }
        }
        if !done {
            Paths.ensure(marker.deletingLastPathComponent())
            try? root.write(to: marker, atomically: true, encoding: .utf8)
        }
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func yamlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func dayString(_ date: Date, zone: TimeZone = .current) -> String { timeString(date, "yyyy-MM-dd", zone: zone) }

    public static func timeString(_ date: Date, _ format: String, zone: TimeZone = .current) -> String {
        formatter(format, zone: zone).string(from: date)
    }

    /// One formatter per format and zone, kept: making a DateFormatter costs ~0.1 ms (ICU), and callers format
    /// one per line (a note's wall-clock times, the MCP's live lines). Set up once, they're safe on any thread.
    static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        formatters.withLock { cache in
            let key = format + "|" + zone.identifier
            if let f = cache[key] { return f }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = format
            if cache.count >= 64 { cache.removeAll() }
            cache[key] = f
            return f
        }
    }
    private static let formatters = OSAllocatedUnfairLock(initialState: [String: DateFormatter]())

    /// With this Mac's UTC offset: "2026-10-29T14:03:12+10:00" ("Z" at UTC).
    public static func iso(_ date: Date) -> String { iso(date, zone: .current) }

    /// A format style, not a new ISO8601DateFormatter per call: making one costs ~0.2 ms in ICU, and the live feed
    /// formats hundreds of times a second. Same text as that formatter wrote, which rounds to whole milliseconds
    /// before dropping them (so 12.9996 s is "13").
    public static func iso(_ date: Date, zone: TimeZone) -> String {
        let whole = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
        return whole.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: zone))
    }

    /// The time zone an `iso` time was written in: this Mac's if it had the same UTC offset then (so summer time
    /// stays right), else that fixed offset. Nil without an offset.
    public static func zone(ofISO iso: String, at date: Date) -> TimeZone? {
        var offset = 0
        if !iso.hasSuffix("Z") {
            let tail = Array(iso.suffix(6))
            guard tail.count == 6, tail[0] == "+" || tail[0] == "-", tail[3] == ":",
                let h = Int(String(tail[1...2])), let m = Int(String(tail[4...5]))
            else { return nil }
            offset = (tail[0] == "-" ? -1 : 1) * (h * 3600 + m * 60)
        }
        if TimeZone.current.secondsFromGMT(for: date) == offset { return .current }
        return TimeZone(secondsFromGMT: offset)
    }

    private static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

/// A title from the first few meaningful words, no LLM needed.
public enum Title {
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "erm", "hmm", "mm", "mhm", "ah", "oh", "okay", "ok", "so", "yeah", "yep", "yes",
        "no", "nah", "like", "well", "right", "hey", "hi", "hello", "and", "but", "alright", "cool", "sure",
        "anyway", "anyways", "basically", "just",
    ]

    /// First sentence (in the first 2 minutes) that still has 3+ words once leading filler is dropped:
    /// its first 6 words. Nil if nothing qualifies.
    public static func make(from lines: [Line], maxWords: Int = 6) -> String? {
        let early = lines.prefix { $0.start < 120 }.map(\.text).joined(separator: " ")
        let sentences = early.split(whereSeparator: { ".?!".contains($0) })
        for sentence in sentences {
            var words = sentence.split(separator: " ").map { clean(String($0)) }.filter { !$0.isEmpty }
            while let first = words.first, fillers.contains(first.lowercased()) { words.removeFirst() }
            guard words.count >= 3 else { continue }
            var title = words.prefix(maxWords).joined(separator: " ")
            title = title.prefix(1).uppercased() + title.dropFirst()
            return title
        }
        return nil
    }

    /// Letters, digits, apostrophes and a few symbols; trailing punctuation goes.
    static func clean(_ word: String) -> String {
        let kept = word.filter { $0.isLetter || $0.isNumber || "'$%&-".contains($0) }
        return kept.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
    }

    /// Safe in a file name on macOS and in an Obsidian link.
    public static func fileSafe(_ title: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]\n\r\t")
        let cleaned = title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
        let squashed = cleaned.split(separator: " ").joined(separator: " ")
        return String(squashed.prefix(60)).trimmingCharacters(in: .whitespaces)
    }
}
