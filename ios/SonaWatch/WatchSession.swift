import Foundation
import WatchConnectivity
import os

/// WatchConnectivity behind the transfer queue: sends the files, and passes on the iPhone's acknowledgements, its
/// inventory and how each transfer ended. Its delegate calls arrive on a background queue, so they hop to the main
/// actor with only plain values.
@MainActor
final class WatchSession: NSObject, TransferSession, WCSessionDelegate {
    weak var queue: TransferQueue?
    private let session = WCSession.default
    nonisolated private static let log = Logger(subsystem: "com.dinilb.sona.watchkitapp", category: "transfer")
    /// Delegate calls that have hopped to the main actor and not run there yet. A WatchConnectivity background task
    /// waits for these too, or the app could be suspended before an acknowledgement deletes anything.
    nonisolated private let hops = OSAllocatedUnfairLock(initialState: 0)

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    var canSend: Bool {
        #if targetEnvironment(simulator)
        // The simulator can't transfer files (Apple says so): recordings stay on the watch, "waiting for iPhone".
        false
        #else
        session.activationState == .activated
        #endif
    }

    var outstandingIDs: Set<String> {
        Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?["id"] as? String })
    }

    func sendFile(_ url: URL, metadata: [String: Any]) {
        session.transferFile(url, metadata: metadata)
    }

    func cancelTransfers(of id: String) {
        for transfer in session.outstandingFileTransfers where transfer.file.metadata?["id"] as? String == id {
            transfer.cancel()
        }
    }

    var isReachable: Bool { canSend && session.isReachable }

    func wakePhone(failed: @escaping @MainActor @Sendable () -> Void) {
        // Reachable means the iPhone is in range and this app runs in front (or in a background task that allows
        // it). The iPhone answers a wake, so one that never reached Sona there (it didn't launch in time, the link
        // dropped) comes back as an error and the queue tries once more. Otherwise the file still waits on the
        // iPhone, and the next stop or wrist raise nudges again.
        guard isReachable else { return }
        let handlers = Self.wakeHandlers(failed: failed)
        session.sendMessage(Wake.message, replyHandler: handlers.reply, errorHandler: handlers.error)
    }

    /// Made outside the main actor on purpose: WatchConnectivity calls these on its own queue, and a closure isolated
    /// to the main actor would crash there.
    nonisolated private static func wakeHandlers(
        failed: @escaping @MainActor @Sendable () -> Void
    ) -> (reply: @Sendable ([String: Any]) -> Void, error: @Sendable (any Error) -> Void) {
        (
            reply: { _ in },
            error: { error in
                log.notice("wake didn't reach the iPhone: \((error as NSError).code)")
                Task { @MainActor in failed() }
            }
        )
    }

    /// The iPhone became reachable: a moment after the app comes to the front, so a wake tried at that moment (a stop
    /// from the complication, say) may not have gone.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        onMain { $0.queue?.becameReachable() }
    }

    /// For the WatchConnectivity background task: waits (at most `limit`) until the session is activated, it has
    /// handed over everything pending, and what it handed over has run on the main actor. Returns early when the
    /// task is cancelled (out of time).
    func drain(limit: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            let settled = session.activationState == .activated && !session.hasContentPending && hops.withLock { $0 } == 0
            if settled { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        // The iPhone's last inventory, kept by the system across launches.
        let inventory = PhoneInventory(context: session.receivedApplicationContext)
        onMain { watch in
            if let inventory { watch.queue?.inventoryArrived(inventory) }
            watch.queue?.run()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        acknowledge(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        acknowledge(message)
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) {
        acknowledge(message)
        replyHandler([:])
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let inventory = PhoneInventory(context: applicationContext) else { return }
        onMain { $0.queue?.inventoryArrived(inventory) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard let id = fileTransfer.file.metadata?["id"] as? String else { return }
        let failed = error != nil
        onMain { $0.queue?.transferFinished(id: id, failed: failed) }
    }

    /// Passes an `Ack` on; anything else is ignored.
    private nonisolated func acknowledge(_ message: [String: Any]) {
        guard let id = Ack.id(in: message) else { return }
        onMain { $0.queue?.acknowledged(id: id) }
    }

    /// Runs `work` on the main actor, counted in `hops` until it has.
    private nonisolated func onMain(_ work: @escaping @MainActor @Sendable (WatchSession) -> Void) {
        hops.withLock { $0 += 1 }
        Task { @MainActor in
            work(self)
            self.hops.withLock { $0 -= 1 }
        }
    }
}
