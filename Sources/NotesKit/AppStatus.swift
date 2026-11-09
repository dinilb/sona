import Foundation

/// What the menu bar app is doing, written to `status.json` whenever it changes, so the MCP server can say
/// "a conversation is in progress since 14:02" instead of pretending nothing is happening.
public struct AppStatus: Codable, Sendable {
    /// listening, hearing, processing, paused, error, setup
    public var state: String
    public var detail: String?
    /// When the open (not yet transcribed) conversation started, ISO 8601.
    public var conversationStartedAt: String?
    /// Conversations waiting to be transcribed.
    public var pending: Int
    public var updatedAt: String
    public var pid: Int32

    public init(state: String, detail: String? = nil, conversationStartedAt: Date? = nil, pending: Int = 0) {
        self.state = state
        self.detail = detail
        self.conversationStartedAt = conversationStartedAt.map(NoteWriter.iso)
        self.pending = pending
        self.updatedAt = NoteWriter.iso(Date())
        self.pid = getpid()
    }

    public func write() {
        Paths.ensure(Paths.support)
        if let data = try? JSONEncoder().encode(self) { try? NoteWriter.writePrivate(data, to: Paths.statusFile) }
    }

    /// The running app rewrites the file at least once a minute, so older than this means it's gone, even
    /// if its pid now belongs to something else.
    public static let maxAge: TimeInterval = 180

    /// The app's last status, or nil if the app isn't running.
    public static func read(now: Date = Date()) -> AppStatus? {
        guard let data = try? Data(contentsOf: Paths.statusFile),
            let status = try? JSONDecoder().decode(AppStatus.self, from: data),
            kill(status.pid, 0) == 0,
            let updated = ISO8601DateFormatter().date(from: status.updatedAt),
            now.timeIntervalSince(updated) < maxAge
        else { return nil }
        return status
    }
}
