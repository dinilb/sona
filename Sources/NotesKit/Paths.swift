import Foundation
import os

/// Where Sona keeps things. Everything lives in two places:
/// - the notes folder (default `~/Sona`), plain markdown the user owns;
/// - the support folder (`~/Library/Application Support/Sona`): settings, models, the audio spool, logs.
///
/// `SONA_HOME` moves the support folder (and the default notes folder) somewhere else, for tests.
public enum Paths {
    public static var support: URL {
        if let home = ProcessInfo.processInfo.environment["SONA_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sona", isDirectory: true)
    }

    public static var isTestHome: Bool {
        !(ProcessInfo.processInfo.environment["SONA_HOME"] ?? "").isEmpty
    }

    public static var defaultNotesFolder: URL {
        if isTestHome { return support.appendingPathComponent("Notes", isDirectory: true) }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sona", isDirectory: true)
        #else
        // The iPhone has no home folder: notes are written here first, then moved to iCloud Drive.
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sona", isDirectory: true)
        #endif
    }

    /// Downloaded once on first run, then never touched again.
    public static var models: URL { support.appendingPathComponent("Models", isDirectory: true) }
    /// Audio of conversations not yet turned into notes. Survives crashes and quits.
    public static var spool: URL { support.appendingPathComponent("Spool", isDirectory: true) }
    public static var settingsFile: URL { support.appendingPathComponent("settings.json") }
    /// What the app is doing right now, for the MCP server's `recent` tool.
    public static var statusFile: URL { support.appendingPathComponent("status.json") }
    /// Full-text index of the notes for the MCP `search` tool. A cache: safe to delete.
    public static var searchIndex: URL { support.appendingPathComponent("search.sqlite") }
    public static var logFile: URL { support.appendingPathComponent("sona.log") }
    /// Held by the running app, so only one copy listens and the CLI doesn't touch its spool.
    public static var lockFile: URL { support.appendingPathComponent("app.lock") }

    /// Creates the folder if it's missing, private to this user (0700), like everything Sona makes.
    public static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// At launch: the support folder this user's only (0700), and the files in it that older versions made readable
    /// by everyone (0644) made 0600: settings, status, the log, the search index and the spool's audio. A few
    /// chmods. Never through a symlink.
    public static func tightenSupport() {
        let root = support.standardizedFileURL.path
        guard NoteWriter.isRealDirectory(root) else { return }
        chmod(root, 0o700)
        func file(_ path: String) {
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_mode & 0o077 != 0 { chmod(path, 0o600) }
        }
        for name in ["settings.json", "status.json", "sona.log", "sona.old.log", "app.lock", "search.sqlite", "search.sqlite-wal", "search.sqlite-shm"] {
            file(root + "/" + name)
        }
        for dir in [spool.path, spool.appendingPathComponent("failed").path] where NoteWriter.isRealDirectory(dir) {
            chmod(dir, 0o700)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] { file(dir + "/" + name) }
        }
    }
}

/// An error whose text is fixed by Sona (a model name or a system status at most) and never holds a title, what was
/// said, a file name or a path: `Log.describe` keeps its words. Every other error is logged by domain and code.
public protocol LogSafeError: Error {}

/// A one-line log at `Paths.logFile` (and stderr for the CLI). Nothing from transcripts goes in: no titles,
/// no note file names (they start with the title), no words. Name a conversation with `ref`.
public enum Log {
    public static var echoToStderr: Bool {
        get { echo.withLock { $0 } }
        set { echo.withLock { $0 = newValue } }
    }
    private static let echo = OSAllocatedUnfairLock(initialState: false)
    private static let lock = NSLock()

    /// Called after each line is written, on whatever thread logged it, with nothing from the line. The iPhone copies
    /// its log into its iCloud folder from here (`DiagnosticsLog`); nil (the Mac, the CLI) does nothing.
    public static var didWrite: (@Sendable () -> Void)? {
        get { hook.withLock { $0 } }
        set { hook.withLock { $0 = newValue } }
    }
    private static let hook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// A conversation in the log: its day and start minute ("2026-10-29/14-03"), the time part of its note id.
    public static func ref(_ startedAt: Date) -> String {
        NoteWriter.dayString(startedAt) + "/" + NoteWriter.timeString(startedAt, "HH-mm")
    }

    /// An error for the log: its domain and code, and the codes of the errors under it (iCloud's wrap a file error).
    /// Words only for Sona's own errors that can't hold a title, what was said, a file name or a path (`LogSafeError`):
    /// any other error's text can (a file error's path holds the note's title, a Swift error prints its payload), and
    /// on the iPhone the log leaves the phone (`DiagnosticsLog`).
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if error is any LogSafeError, !carriesPath(ns) { return "\(error)" }
        let under = underlying(ns).map { "\($0.domain) \($0.code)" }
        return "\(ns.domain) error \(ns.code)" + (under.isEmpty ? "" : " (\(under.joined(separator: ", ")))")
    }

    /// A path or URL anywhere in the error's user info, or in an error under it.
    static func carriesPath(_ ns: NSError) -> Bool {
        let keys: Set<String> = [
            NSFilePathErrorKey, NSURLErrorKey, NSURLErrorFailingURLErrorKey, NSURLErrorFailingURLStringErrorKey,
        ]
        for error in [ns] + underlying(ns) {
            if error.domain == NSCocoaErrorDomain { return true }
            for (key, value) in error.userInfo {
                if keys.contains(key) || value is URL || value is NSURL { return true }
                if let text = value as? String, text.hasPrefix("/") || text.hasPrefix("file:") { return true }
            }
        }
        return false
    }

    /// The errors under `ns` (`NSUnderlyingErrorKey`, `NSMultipleUnderlyingErrorsKey`), a few levels down at most.
    private static func underlying(_ ns: NSError) -> [NSError] {
        var found: [NSError] = []
        var level = [ns]
        for _ in 0..<4 {
            let next = level.flatMap { error -> [NSError] in
                let one = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { [$0] } ?? []
                return one + (error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? [])
            }
            if next.isEmpty { break }
            found += next
            level = next
        }
        return found
    }

    public static func note(_ message: String) {
        write("\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(message)\n", message: message)
        didWrite?()
    }

    private static func write(_ line: String, message: String) {
        if echoToStderr { FileHandle.standardError.write(Data(message.utf8 + [10])) }
        lock.lock()
        defer { lock.unlock() }
        Paths.ensure(Paths.support)
        let url = Paths.logFile
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            (attrs[.size] as? Int ?? 0) > 2_000_000
        {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            // The throwing calls: the old seekToEndOfFile()/write(_:) raise an exception nothing can catch when the disk
            // is full, and a log line must never crash the app (it's the first thing the out-of-space path does).
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            // A new log is this user's only, like the rest of the support folder.
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}
