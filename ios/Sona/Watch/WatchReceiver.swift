import Foundation
import NotesKit
import UIKit
import WatchConnectivity
import os

/// The iPhone's end of the watch link: the watch's recordings arrive as files (`transferFile`), go into the spool
/// through `WatchInbox` (a WAV at once, an AAC once it's decoded after the callback), are acknowledged, and queued to
/// become notes. Delegate callbacks come on WCSession's own queue, so this class isn't main-actor code; it hops there
/// only to queue the note.
///
/// The system moves a file to the iPhone on its own, but Sona only takes it when it runs. The watch app, while it's in
/// front, sends `Wake.message`, which launches Sona in the background; the files waiting are handed over in that
/// launch. A file that arrived while Sona was swiped away waits until Sona next runs.
nonisolated final class WatchReceiver: NSObject, WCSessionDelegate, WatchAcknowledging, @unchecked Sendable {
    static let shared = WatchReceiver()

    /// Set once in `activate`, read from WCSession's queue.
    private let inbox = OSAllocatedUnfairLock<WatchInbox?>(initialState: nil)
    /// Bumped by each request to publish the inventory, so only the last of a burst publishes.
    private let inventoryRequest = OSAllocatedUnfairLock(initialState: 0)
    private static let inventoryQueue = DispatchQueue(label: "com.dinilb.sona.watch.inventory", qos: .utility)

    /// At launch. Does nothing on a device without watch support.
    @MainActor
    func activate() {
        guard WCSession.isSupported() else { return }
        let inbox = WatchInbox(
            spool: Services.spool, receivedFile: Paths.support.appendingPathComponent("watch-received.json"), acknowledger: self)
        self.inbox.withLock { $0 = inbox }
        // What an earlier launch received but didn't get to decode.
        Self.convertStaged(inbox)
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Decodes the watch's staged AAC recordings into the spool, away from WCSession's queue and the main actor, then
    /// queues them to become notes. With background time asked for, so a launch from the watch's wake isn't suspended
    /// halfway through an hour's decode (it would carry on next time, but later).
    private nonisolated static func convertStaged(_ inbox: WatchInbox) {
        Task { @MainActor in
            let time = BackgroundTime(name: "Convert the watch's recordings")
            let added = await Task.detached(priority: .utility) { inbox.convertStaged() }.value
            for spoolID in added { NotesService.shared.enqueue(spoolID) }
            if countsForWake(added: added) { WatchWakeHold.shared.received() }
            time.end()
        }
    }

    /// Only a recording that came in counts for a wake: a launch's leftovers with nothing new would end its wait before
    /// the file it's waiting for has started across.
    nonisolated static func countsForWake(added: [String]) -> Bool {
        !added.isEmpty
    }

    func acknowledge(_ id: String) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        // Queued: reaches the watch even if neither app is running now.
        session.transferUserInfo(Ack.message(id))
        // And at once if the watch app is open, so it can tidy up right away.
        if session.isReachable { session.sendMessage(Ack.message(id), replyHandler: nil, errorHandler: nil) }
    }

    /// Publishes which watch recordings this iPhone has (`PhoneInventory`) as the application context, `delay`
    /// seconds from now, and only once WatchConnectivity has handed over everything pending: an inventory sent
    /// while files are still coming in would leave them out, and the watch would send them again. A burst of
    /// requests publishes once.
    func publishInventory(after delay: TimeInterval) {
        let request = inventoryRequest.withLock { value in
            value += 1
            return value
        }
        schedulePublish(request: request, after: delay, triesLeft: 30)
    }

    private func schedulePublish(request: Int, after delay: TimeInterval, triesLeft: Int) {
        Self.inventoryQueue.asyncAfter(deadline: .now() + delay) { [self] in
            guard inventoryRequest.withLock({ $0 }) == request else { return }  // a newer request took over
            let session = WCSession.default
            // No watch, or no Sona on it: nobody to tell.
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
                let inbox = inbox.withLock({ $0 })
            else { return }
            // Still receiving: wait for it (about a minute at most, then publish what there is).
            if session.hasContentPending, triesLeft > 0 {
                return schedulePublish(request: request, after: 2, triesLeft: triesLeft - 1)
            }
            let inventory = PhoneInventory(ids: inbox.receivedIDs(), at: Date())
            do { try session.updateApplicationContext(inventory.context) } catch {
                // No watch app installed, or not paired: nothing to tell.
                Log.note("the watch inventory wasn't sent: \(Log.describe(error))")
            }
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { Log.note("watch link didn't activate: \(Log.describe(error))") }
        // Once what was waiting has come in: a reinstalled Sona has nothing, and the watch sends it again.
        if activationState == .activated { publishInventory(after: 3) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to another watch: activate again for the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// The watch's `Wake`: its only job was to launch this app, so the files waiting come in. The launch is held until
    /// they're in, or a while if none comes (`WatchWakeHold`).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["kind"] as? String == Wake.kind { Task { @MainActor in WatchWakeHold.shared.hold() } }
    }

    func session(
        _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if message["kind"] as? String == Wake.kind { Task { @MainActor in WatchWakeHold.shared.hold() } }
        replyHandler([:])
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let inbox = inbox.withLock({ $0 }) else { return }
        do {
            switch try inbox.receive(file: file.fileURL, metadata: file.metadata) {
            case .added(let spoolID):
                Task { @MainActor in
                    NotesService.shared.enqueue(spoolID)
                    WatchWakeHold.shared.received()
                }
            case .staged: Self.convertStaged(inbox)
            case .duplicate, .tooShort, .ignored: Task { @MainActor in WatchWakeHold.shared.received() }
            }
            publishInventory(after: 2)
        } catch {
            Log.note("a watch recording couldn't be saved; the watch will send it again: \(Log.describe(error))")
        }
    }
}

/// Keeps a background launch from the watch's wake going until its files are in the spool and queued. The watch
/// wakes Sona at the stop, before the file has even started across, so it waits for the first one (up to
/// `WakeWait.firstFileWait`), then while more are pending. Once a recording is queued, its note holds background
/// time of its own until it's written, if it's short enough (`NotesService.enqueue`), so this one can go. When it
/// goes, the log's copy in iCloud catches up first (`DiagnosticsLog.flush`).
@MainActor
final class WatchWakeHold {
    static let shared = WatchWakeHold()
    private var waiting = WakeWait()
    private var time: BackgroundTime?

    func hold() {
        let offScreen = UIApplication.shared.applicationState == .background
        Log.note("the watch woke Sona for its recordings, \(offScreen ? "off" : "on") screen")
        guard let generation = waiting.wake(at: Self.now()) else { return }  // the hold running waits longer now
        time = BackgroundTime(name: "Take the watch's recordings") { [weak self] _ in self?.ranOut(generation) }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                // A newer hold (or iOS's time running out) owns this now: this loop never ends it.
                guard let self, self.waiting.isCurrent(generation) else { return }
                guard self.waiting.shouldEnd(at: Self.now(), pending: WCSession.default.hasContentPending) else { continue }
                // Let the last file's main-actor work (queueing the note) run, then look again: a second wake in
                // that second asks for a longer wait.
                try? await Task.sleep(for: .seconds(1))
                guard self.waiting.isCurrent(generation) else { return }
                if self.waiting.shouldEnd(at: Self.now(), pending: WCSession.default.hasContentPending) {
                    self.end(generation)
                    return
                }
            }
        }
    }

    /// A watch recording came in and was queued (or was one this iPhone already had): see `hold`.
    func received() {
        waiting.fileArrived(at: Self.now())
    }

    private func end(_ generation: Int) {
        guard waiting.isCurrent(generation) else { return }
        if !waiting.fileCame { Log.note("no watch recording came within \(Int(WakeWait.firstFileWait)) s of its wake") }
        waiting.ended()
        let time = self.time
        self.time = nil
        DiagnosticsLog.flush { time?.end() }
    }

    /// iOS says time is up: the hold goes now (BackgroundTime gives it back), with no wait for the log.
    private func ranOut(_ generation: Int) {
        guard waiting.isCurrent(generation) else { return }
        waiting.ended()
        time = nil
    }

    /// Seconds on a clock that only moves forward while Sona runs.
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// When a wake's hold ends, as plain decisions (unit tested in SonaTests/BackgroundNotesTests.swift). A wake waits for
/// a recording to come in (up to `firstFileWait`), then for nothing more pending. A second wake while it waits asks
/// for a new file and a fresh wait; a file that came just before a new hold's wake counts for it (the watch also wakes
/// Sona right after a delivery, so the file can come first). Each hold has its own generation, so a loop left from an
/// earlier one never ends a later.
nonisolated struct WakeWait: Equatable, Sendable {
    /// How long a wake waits for a recording to come in at all.
    static let firstFileWait: TimeInterval = 20
    /// A recording that came this soon before a new hold's wake counts for it. Short: a file from an earlier stop
    /// mustn't end the wait for the next one.
    static let earlyFile: TimeInterval = 3

    /// The current hold's, bumped by each new hold.
    private(set) var generation = 0
    /// When the wait for a file ends; nil while nothing holds.
    private(set) var deadline: TimeInterval?
    /// A recording came in for the current wake.
    private(set) var fileCame = false
    private var lastFileAt: TimeInterval?

    /// A wake at `now`: a new hold's generation, or nil when one is already holding (it now waits for a new file
    /// until a fresh deadline).
    mutating func wake(at now: TimeInterval) -> Int? {
        let starting = deadline == nil
        deadline = now + Self.firstFileWait
        fileCame = starting && (lastFileAt.map { now - $0 <= Self.earlyFile } ?? false)
        guard starting else { return nil }
        generation += 1
        return generation
    }

    mutating func fileArrived(at now: TimeInterval) {
        lastFileAt = now
        if deadline != nil { fileCame = true }
    }

    func isCurrent(_ generation: Int) -> Bool {
        deadline != nil && generation == self.generation
    }

    /// Time to let the hold go: a file came and nothing more is on its way, or no file came in time.
    func shouldEnd(at now: TimeInterval, pending: Bool) -> Bool {
        guard let deadline else { return false }
        return (fileCame && !pending) || now >= deadline
    }

    mutating func ended() {
        deadline = nil
        fileCame = false
    }
}
