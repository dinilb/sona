import Foundation

/// The live transcript right now, written by the Sona app (`Live/now.json`) as words come in (at most 3 times a second) so the MCP
/// server can answer "what was just said" without waiting for a note. Holds the last ~10 minutes only.
public struct LiveFeed: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        /// "Speaker 1", ... or nil when speakers are off or nobody was clearly talking.
        public var speaker: String?
        /// False while the speaker label may still change (the last second or so).
        public var settled: Bool
        /// ISO 8601 times of the first and last word.
        public var start: String
        public var end: String
        public var text: String

        public init(speaker: String?, settled: Bool, start: Date, end: Date, text: String) {
            self.speaker = speaker
            self.settled = settled
            self.start = NoteWriter.iso(start)
            self.end = NoteWriter.iso(end)
            self.text = text
        }
    }

    public var listening: Bool
    public var engine: String
    public var speakers: Bool
    public var updatedAt: String
    public var pid: Int32
    public var lines: [Line]

    public init(listening: Bool, engine: String, speakers: Bool, lines: [Line]) {
        self.listening = listening
        self.engine = engine
        self.speakers = speakers
        self.updatedAt = NoteWriter.iso(Date())
        self.pid = getpid()
        self.lines = lines
    }

    /// Same feed apart from when it was written.
    public func sameContent(as other: LiveFeed) -> Bool {
        var copy = self
        copy.updatedAt = other.updatedAt
        return copy == other
    }

    public static var file: URL { Paths.support.appendingPathComponent("Live/now.json") }

    /// AI access was turned off: nothing of the live transcript stays on disk.
    public static func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    /// A temp file renamed over the old one, so a reader never sees half of it, but without the fsync of `.atomic`:
    /// it's rewritten a few times a second and only ever says what's happening right now. Private to this user.
    public func write() {
        let dir = Self.file.deletingLastPathComponent()
        Paths.ensure(dir)
        guard let data = try? JSONEncoder().encode(self) else { return }
        let temp = dir.appendingPathComponent(".now-\(getpid()).json.tmp").path
        let fd = Darwin.open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        fchmod(fd, 0o600)  // a temp file left by a crash keeps whatever mode it had
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == $0.count }
        Darwin.close(fd)
        if !wrote || Darwin.rename(temp, Self.file.path) != 0 { Darwin.unlink(temp) }
    }

    /// The feed, with `running` false if the app that wrote it has quit.
    public static func read() -> (feed: LiveFeed, running: Bool)? {
        guard let data = try? Data(contentsOf: file), let feed = try? JSONDecoder().decode(LiveFeed.self, from: data)
        else { return nil }
        return (feed, kill(feed.pid, 0) == 0)
    }
}
