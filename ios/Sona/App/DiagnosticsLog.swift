import Foundation
import NotesKit
import os
import UIKit

/// A copy of this iPhone's log in the app's own iCloud folder, `Documents/Diagnostics/iPhone.log`, so the Mac (and
/// whoever helps there with a sync problem) can see when each note was recorded, reached this iPhone, was
/// transcribed and was written, without the iPhone. Only while notes go to that folder: with On this iPhone or a
/// picked folder, nothing goes to iCloud that wasn't going there already, and a copy left from before is deleted. The
/// log holds no titles, words, file names or places (`Log`), and the copy is its newest 256 KB.
nonisolated enum DiagnosticsLog {
    static let folderName = "Diagnostics"
    static let fileName = "iPhone.log"
    /// How much of the log the copy keeps, from the end. Each copy uploads it whole, so not more.
    static let tailBytes = 256_000
    /// On screen, new log lines are copied at most this often; launch and going off screen copy at once.
    static let interval: TimeInterval = 60
    /// Off screen, new lines are copied this soon, one copy for a burst of lines (each copy uploads the whole tail).
    /// Everything that keeps Sona running off screen also copies before it's given back (`flush`).
    static let offScreenDelay: TimeInterval = 10
    /// The longest anything that keeps Sona running off screen waits for a copy before it's given back (`flush`).
    static let flushWait: TimeInterval = 3
    /// A copy that iCloud holds up longer than this is dropped; the next one tries again.
    static let coordinationTimeout: TimeInterval = 10
    /// Where the last copy's `Signature` is kept, so a launch with nothing new doesn't upload the same log again.
    static let signatureKey = "diagnosticsLogCopied"

    /// At launch (foreground or not): each new log line leads to a copy (`soon`), and one goes now.
    static func start() {
        Log.didWrite = { DiagnosticsLog.soon() }
        copyNow()
    }

    /// The app is going off screen: a copy now, with a little background time so iOS doesn't stop it halfway.
    @MainActor static func copyGoingOffScreen() {
        let time = BackgroundTime(name: "Copy the log to iCloud")
        flush(always: true) { time.end() }
    }

    /// Off screen: a copy now, then `done` once it's written or after `flushWait`, whichever comes first. Whatever keeps
    /// Sona running (held background time, a background task, the watch's wake) is given back in `done`, so the Mac's
    /// copy has caught up before iOS suspends the app. On screen nothing is about to be suspended: `done` at once.
    @MainActor static func flush(always: Bool = false, then done: @escaping @MainActor () -> Void) {
        guard always || !NotesService.onScreen.withLock({ $0 }) else { return done() }
        let once = Once(done)
        copyNow { Task { @MainActor in once.run() } }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(flushWait))
            once.run()
        }
    }

    // MARK: When

    private nonisolated struct State: Sendable {
        var lastCopy: Date?
        /// A copy for new lines is on its way already.
        var pending = false
        /// The app's iCloud container, once found (finding it can take a while the first time).
        var container: URL?
        /// The log as it was at the last copy that worked (kept across launches, `signatureKey`): unchanged, there's
        /// nothing to copy.
        var copied: Signature?
        var copiedLoaded = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let queue = DispatchQueue(label: "com.dinilb.sona.diagnostics-log", qos: .utility)
    private static let logger = Logger(subsystem: "com.dinilb.sona", category: "diagnostics-log")

    /// After a log line, from whatever thread wrote it: on screen a copy a minute after the last one (now, if that was
    /// longer ago), off screen one `offScreenDelay` later, unless one is on its way already.
    static func soon(now: Date = Date()) {
        let onScreen = NotesService.onScreen.withLock { $0 }
        let delay = state.withLock { state -> TimeInterval? in
            guard let delay = wait(last: state.lastCopy, pending: state.pending, now: now, onScreen: onScreen) else {
                return nil
            }
            state.pending = true
            return delay
        }
        guard let delay else { return }
        queue.asyncAfter(deadline: .now() + delay) { copyIfChanged(endingPending: true) }
    }

    /// How long until a copy for a new log line: none while one is on its way; on screen a minute after the last copy;
    /// off screen `offScreenDelay`.
    static func wait(last: Date?, pending: Bool, now: Date, onScreen: Bool = true) -> TimeInterval? {
        guard !pending else { return nil }
        guard onScreen else { return offScreenDelay }
        guard let last else { return 0 }
        return max(0, interval - now.timeIntervalSince(last))
    }

    /// A copy now, off the main thread. `done` runs after it, whether it wrote or not.
    static func copyNow(done: (@Sendable () -> Void)? = nil) {
        queue.async {
            copyIfChanged(endingPending: false)
            done?()
        }
    }

    /// Notes stopped going to the app's iCloud folder: the copy there goes (iCloud Drive and the Mac lose it too), and
    /// the next copy, if notes go back there, starts fresh.
    static func notesLeftICloud() {
        queue.async {
            forgetContainer()
            saveSignature(nil)
            guard let cloud = NotesLocation.iCloudContainer() else { return }
            do {
                try remove(from: cloud)
            } catch {
                logger.error("the log's copy in iCloud couldn't be deleted: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            }
        }
    }

    /// Where notes go changed (or the iCloud account did): the container is looked up again at the next copy.
    static func forgetContainer() {
        state.withLock { $0.container = nil }
    }

    /// On `queue`. Never blocks on iCloud for long, and never writes to the log itself: a line there would ask for
    /// another copy. `endingPending`: the copy `soon` scheduled, so new lines can schedule the next one.
    private static func copyIfChanged(endingPending: Bool) {
        state.withLock { state in
            state.lastCopy = Date()
            if endingPending { state.pending = false }
        }
        let log = Paths.logFile
        guard needsCopy(log: log, last: lastSignature()) else { return }
        let now = Signature(log)
        do {
            if try copy(choice: V1Settings.notesChoice, container: container, log: log, old: oldLog(log)) {
                saveSignature(now)
            }
        } catch {
            logger.error("the log couldn't be copied to iCloud: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
        }
    }

    /// The container, looked up once per notes location (`forgetContainer`), and again while there's none.
    private static func container() -> URL? {
        if let known = state.withLock({ $0.container }) { return known }
        let found = NotesLocation.iCloudContainer()
        state.withLock { $0.container = found }
        return found
    }

    /// Where `Log` moves the log when it rolls over (`sona.old.log`).
    static func oldLog(_ log: URL) -> URL { log.deletingPathExtension().appendingPathExtension("old.log") }

    /// The log's size and last change: a copy only when either moved.
    nonisolated struct Signature: Equatable, Sendable {
        var size: Int
        var modified: Date?

        init(size: Int, modified: Date?) {
            self.size = size
            self.modified = modified
        }

        init(_ log: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: log.path)
            size = attributes?[.size] as? Int ?? 0
            modified = attributes?[.modificationDate] as? Date
        }

        /// As kept in `UserDefaults`.
        var stored: [String: Double] {
            var out = ["size": Double(size)]
            if let modified { out["modified"] = modified.timeIntervalSinceReferenceDate }
            return out
        }

        init?(stored: Any?) {
            guard let stored = stored as? [String: Double], let size = stored["size"] else { return nil }
            self.size = Int(size)
            modified = stored["modified"].map(Date.init(timeIntervalSinceReferenceDate:))
        }
    }

    /// The last copy's signature, read from the defaults the first time this launch.
    private static func lastSignature() -> Signature? {
        let (loaded, value) = state.withLock { ($0.copiedLoaded, $0.copied) }
        if loaded { return value }
        let saved = loadSignature(from: .standard)
        state.withLock { state in
            if !state.copiedLoaded {
                state.copied = saved
                state.copiedLoaded = true
            }
        }
        return state.withLock { $0.copied }
    }

    private static func saveSignature(_ signature: Signature?) {
        state.withLock { state in
            state.copied = signature
            state.copiedLoaded = true
        }
        store(signature, in: .standard)
    }

    static func loadSignature(from defaults: UserDefaults) -> Signature? {
        Signature(stored: defaults.object(forKey: signatureKey))
    }

    static func store(_ signature: Signature?, in defaults: UserDefaults) {
        defaults.set(signature?.stored, forKey: signatureKey)
    }

    /// Whether `log` needs copying, given the last copy's signature (from this launch or an earlier one).
    static func needsCopy(log: URL, last: Signature?) -> Bool {
        Signature(log) != last
    }

    // MARK: What and where

    /// One copy: the log's newest `limit` bytes to `Documents/Diagnostics/iPhone.log` in the container, when
    /// `choice` sends notes there. Returns whether it wrote.
    @discardableResult
    static func copy(choice: NotesChoice?, container: () -> URL?, log: URL, old: URL, limit: Int = tailBytes) throws -> Bool {
        guard let file = destination(choice: choice, container: container) else { return false }
        let data = tail(log: log, old: old, limit: limit)
        guard !data.isEmpty else { return false }
        try write(data, to: file)
        return true
    }

    /// The copy's place: only for notes in the app's iCloud container (and only if there is one now).
    static func destination(choice: NotesChoice?, container: () -> URL?) -> URL? {
        guard choice == .icloud, let cloud = container() else { return nil }
        return file(in: cloud)
    }

    static func file(in cloud: URL) -> URL {
        cloud.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The log's newest `limit` bytes: the end of `log`, with the end of `old` (the log before it last rolled over)
    /// in front while `log` alone is shorter. Whole lines only: a line cut at the front, or one still being written
    /// at the end, is left out.
    static func tail(log: URL, old: URL, limit: Int = tailBytes) -> Data {
        let current = lastBytes(of: log, limit)
        var data = current.data
        if !current.cut, data.count < limit {
            data = lastBytes(of: old, limit - data.count).data + data
        }
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return Data() }
        return Data(data[...end])
    }

    /// The last `count` bytes of `url` or fewer, from the start of a line. `cut`: the file was longer than that.
    private static func lastBytes(of url: URL, _ count: Int) -> (data: Data, cut: Bool) {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), false) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return (Data(), false) }
        guard size > UInt64(count) else {
            guard (try? handle.seek(toOffset: 0)) != nil, let data = try? handle.readToEnd() else { return (Data(), false) }
            return (data, false)
        }
        // One byte before the cut too: if it's a newline the cut is at a line's start, and that line stays whole.
        let start = size - UInt64(count) - 1
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(),
            let newline = data.firstIndex(of: UInt8(ascii: "\n"))
        else { return (Data(), true) }
        return (Data(data[data.index(after: newline)...]), true)
    }

    /// `data` to `file` through NSFileCoordinator (it's iCloud's file too), its folder made first. Gives up after
    /// `coordinationTimeout` rather than wait on iCloud.
    static func write(_ data: Data, to file: URL) throws {
        var coordination: NSError?
        var failure: Error?
        let coordinator = NSFileCoordinator()
        let deadline = NotesLocation.giveUp(coordinator, after: coordinationTimeout)
        defer { deadline.cancel() }
        coordinator.coordinate(writingItemAt: file, options: .forReplacing, error: &coordination) { url in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// Deletes the copy in `cloud` through NSFileCoordinator, and its folder once it's empty. Nothing there is fine.
    static func remove(from cloud: URL) throws {
        let file = file(in: cloud)
        let folder = file.deletingLastPathComponent()
        var coordination: NSError?
        var failure: Error?
        let coordinator = NSFileCoordinator()
        let deadline = NotesLocation.giveUp(coordinator, after: coordinationTimeout)
        defer { deadline.cancel() }
        coordinator.coordinate(writingItemAt: folder, options: .forDeleting, error: &coordination) { url in
            let fm = FileManager.default
            let copy = url.appendingPathComponent(fileName)
            do {
                if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
                // iCloud's stub of a copy it took off this iPhone goes too.
                let stub = url.appendingPathComponent(".\(fileName).icloud")
                if fm.fileExists(atPath: stub.path) { try fm.removeItem(at: stub) }
                if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try fm.removeItem(at: url) }
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// Runs its closure once, whichever of its callers comes first.
    @MainActor private final class Once {
        private var action: (@MainActor () -> Void)?

        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func run() {
            let action = self.action
            self.action = nil
            action?()
        }
    }
}
