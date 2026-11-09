import Foundation
import Observation

/// What the transfer queue needs from WatchConnectivity, so tests can stand in for it.
protocol TransferSession: AnyObject {
    /// The session is activated and can take file transfers. Never in the simulator, which can't send files.
    var canSend: Bool { get }
    /// Ids of the recordings the system is still sending.
    var outstandingIDs: Set<String> { get }
    func sendFile(_ url: URL, metadata: [String: Any])
    /// Drops transfers still queued for a recording the iPhone already has.
    func cancelTransfers(of id: String)
    /// The iPhone is in range and this app runs in front (WatchConnectivity's `isReachable`): only then does a `Wake`
    /// launch Sona there.
    var isReachable: Bool { get }
    /// Launches Sona on the iPhone in the background so it takes the files waiting for it (`Wake`). Does nothing when
    /// the iPhone isn't reachable. `failed` runs on the main actor if the nudge didn't reach Sona there.
    func wakePhone(failed: @escaping @MainActor @Sendable () -> Void)
}

/// The watch half of WatchTransfer.swift: hands every finished recording to WatchConnectivity, sends it again when
/// the transfer failed, was never delivered, or the iPhone says it hasn't got it, and deletes it once the iPhone says
/// it has it (an acknowledgement, or its inventory).
@MainActor @Observable
final class TransferQueue {
    let store: RecordingStore
    let session: any TransferSession
    /// The clock, so tests can move it on.
    @ObservationIgnored var now: () -> Date = { Date() }
    /// The recording being made, which isn't sent until it stops.
    var recordingID: String?
    /// Acknowledgements the iPhone queued while this app wasn't running arrive just after it starts. A recording sent
    /// before isn't sent again until they've had this long to: resending an hour's audio for nothing is a lot of radio.
    @ObservationIgnored var ackGrace: TimeInterval = 30
    /// When this queue first ran (its grace counts from there).
    @ObservationIgnored private var firstRun: Date?
    /// Called after the recordings change (the complications' count follows).
    @ObservationIgnored var onChange: @MainActor () -> Void = {}
    /// The newest list of what the iPhone has (`PhoneInventory`); nil until one arrives in this process.
    @ObservationIgnored private(set) var phoneInventory: PhoneInventory?
    /// When the iPhone was last nudged (`wake`), for `WakePolicy`'s quiet spell.
    @ObservationIgnored private(set) var lastWake: Date?
    /// Runs a failed wake's one retry a little later (tests run it at once).
    @ObservationIgnored var scheduleRetry: (@escaping @MainActor @Sendable () -> Void) -> Void = { retry in
        Task { @MainActor in
            try? await Task.sleep(for: WakePolicy.retryAfter)
            retry()
        }
    }

    /// On the watch, newest first.
    private(set) var recordings: [WatchRecording] = []
    /// The last few the iPhone acknowledged (their audio is gone from the watch), newest first, for the list.
    private(set) var sent: [WatchRecording] = []

    private let defaults: UserDefaults
    private static let sentKey = "sona.sent"
    static let sentKept = 5

    init(store: RecordingStore, session: any TransferSession, defaults: UserDefaults = .standard) {
        self.store = store
        self.session = session
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.sentKey),
            let sent = try? JSONDecoder().decode([WatchRecording].self, from: data)
        {
            self.sent = sent
        }
        recordings = store.all()
    }

    /// Finished recordings still on the watch: not yet on the iPhone.
    var waiting: Int { recordings.filter { $0.id != recordingID && $0.duration > 0 }.count }

    /// Sends what hasn't been sent, and again what failed or was never acknowledged, then wakes the iPhone if anything
    /// waits (`reason` says why it runs). Run at launch, on activation, after each recording and when the app comes
    /// to the front.
    func run(waking reason: WakePolicy.Reason = .run) {
        defer { reload() }
        // Before the session check: a recording stuck at 0 should show as waiting even when nothing can be sent yet.
        repairStranded()
        guard session.canSend else { return }
        let outstanding = session.outstandingIDs
        let firstRun = self.firstRun ?? now()
        if self.firstRun == nil {
            self.firstRun = firstRun
            // Once the grace is over, what it held back goes.
            let grace = ackGrace
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(grace))
                self?.run()
            }
        }
        let inGrace = (0..<ackGrace).contains(now().timeIntervalSince(firstRun))
        // A duration of 0 is now only the one recording being made.
        var anyWaiting = false
        for var recording in store.all() where recording.id != recordingID && recording.duration > 0 {
            anyWaiting = true
            guard !outstanding.contains(recording.id) else { continue }
            // A sentAt in the future (the clock was set back) counts as stale, or it'd never be sent again.
            if let sentAt = recording.sentAt,
                (0..<WatchTransferPolicy.resendAfter).contains(now().timeIntervalSince(sentAt))
            {
                continue
            }
            // Delivered: it's waiting on the iPhone for Sona to run. Sending an hour's audio again would only queue
            // another copy behind it, so only an inventory that should list it and doesn't sends it again.
            if recording.deliveredAt != nil, !phoneLost(recording) { continue }
            // Sent before (it reached the iPhone, or it may have): its acknowledgement may be on its way.
            if recording.sentAt != nil, inGrace { continue }
            let audio = store.audioURL(recording.id)
            guard FileManager.default.fileExists(atPath: audio.path) else { continue }
            recording.sentAt = now()
            recording.deliveredAt = nil
            try? store.save(recording)
            session.sendFile(audio, metadata: recording.metadata)
        }
        // Whatever still waits, a file on the iPhone or one on its way, needs Sona there to run.
        if anyWaiting { wake(reason) }
    }

    /// The recorder started or stopped one. A stop wakes the iPhone even right after another wake: he's looking at the
    /// watch, so the message gets through, and the file is on its way.
    func recordingChanged(to id: String?) {
        let stopped = recordingID != nil && recordingID != id
        recordingID = id
        run(waking: stopped ? .stopped : .run)
    }

    /// The app came to the front: anything still waiting is sent and the iPhone woken for it.
    func cameForward() {
        run(waking: .cameForward)
    }

    /// The iPhone became reachable (it does a moment after the app comes to the front, so a wake tried then may not
    /// have gone).
    func becameReachable() {
        wake(.cameForward)
    }

    /// Nudges Sona on the iPhone to launch and take what waits, when `WakePolicy` says it gets through and isn't one of
    /// a burst. One that doesn't reach Sona while the iPhone is still reachable is tried once more, and no more.
    func wake(_ reason: WakePolicy.Reason) {
        // The store, not `recordings`: a run reloads those only after it's done.
        let waiting = store.all().contains { $0.id != recordingID && $0.duration > 0 }
        guard
            WakePolicy.shouldWake(
                reason, canSend: session.canSend, reachable: session.isReachable, waiting: waiting, lastWake: lastWake,
                now: now())
        else { return }
        lastWake = now()
        session.wakePhone { [weak self] in
            guard let self, reason != .retry else { return }
            self.scheduleRetry { [weak self] in self?.wake(.retry) }
        }
    }

    /// True if the iPhone said, well after this recording was delivered, that it doesn't have it: the delivered file
    /// never reached Sona (it was deleted and installed again, say). Without such a list, a delivered recording waits.
    private func phoneLost(_ recording: WatchRecording) -> Bool {
        guard let deliveredAt = recording.deliveredAt, let inventory = phoneInventory else { return false }
        return inventory.at > deliveredAt.addingTimeInterval(WatchTransferPolicy.inventoryMargin)
            && !inventory.ids.contains(recording.id)
    }

    /// A duration of 0 on any recording but the one being made means it never got its length: the final save
    /// failed, or the app was cut off. Its audio is repaired and its duration rebuilt from the file, so it's sent
    /// like any other instead of staying hidden until the next cold launch (which is when `recover()` would do this).
    /// The recording being made is left alone: its file is still growing.
    private func repairStranded() {
        for recording in store.all() where recording.id != recordingID && recording.duration <= 0 {
            store.finishUnstopped(recording)
        }
    }

    /// A transfer is over. A failed one is sent again on the next run, not straight away, so a lasting failure
    /// (no iPhone app, say) doesn't spin. A delivered one is on the iPhone now: it's marked so it isn't sent again on
    /// the hourly timer, and Sona there is woken to take it (a wake when the transfer was queued may have come before
    /// the file did).
    func transferFinished(id: String, failed: Bool) {
        guard var recording = store.load(id) else { return }
        if failed {
            recording.sentAt = nil
            recording.deliveredAt = nil
        } else {
            recording.deliveredAt = now()
        }
        try? store.save(recording)
        reload()
        if !failed { wake(.delivered) }
    }

    /// The iPhone's list of what it has. Each recording on it is as good as acknowledged (its acknowledgement may
    /// have been lost); the rest is checked on the next run.
    func inventoryArrived(_ inventory: PhoneInventory) {
        if let known = phoneInventory, known.at >= inventory.at { return }
        phoneInventory = inventory
        for recording in store.all() where recording.id != recordingID && inventory.ids.contains(recording.id) {
            acknowledged(id: recording.id)
        }
        run()
    }

    /// The iPhone has this recording in its spool: the watch's copy can go.
    func acknowledged(id: String) {
        session.cancelTransfers(of: id)
        if let recording = store.load(id) {
            sent.removeAll { $0.id == id }
            sent.insert(recording, at: 0)
            sent = Array(sent.prefix(Self.sentKept))
            defaults.set(try? JSONEncoder().encode(sent), forKey: Self.sentKey)
        }
        store.delete(id)
        reload()
    }

    func reload() {
        recordings = store.all()
        onChange()
    }
}

/// When the watch nudges Sona on the iPhone to launch (`Wake`). Only a message from this app while it's in front and
/// the iPhone is reachable launches Sona there, so a wake goes only then, and only while something on the watch waits
/// for the iPhone. The moments that matter always send one: a stop (he's looking at the watch, and the file is on its
/// way) and a delivery (the file is on the iPhone now, waiting for Sona to run). The rest come in bursts (a launch and
/// its activation, a wrist raise and the iPhone becoming reachable), so one within `quietFor` of the last is left out:
/// the iPhone holds its launch longer than that anyway.
nonisolated enum WakePolicy {
    enum Reason: Equatable, Sendable {
        /// A recording on this watch just stopped.
        case stopped
        /// A transfer reached the iPhone.
        case delivered
        /// The app came to the front, or the iPhone became reachable.
        case cameForward
        /// Any other run of the queue (launch, activation, the iPhone's inventory, a start).
        case run
        /// The one retry of a wake that didn't reach Sona.
        case retry
    }

    static let quietFor: TimeInterval = 3
    /// A failed wake is tried again after this, if the iPhone is still reachable.
    static let retryAfter: Duration = .seconds(2)

    static func shouldWake(
        _ reason: Reason, canSend: Bool, reachable: Bool, waiting: Bool, lastWake: Date?, now: Date
    ) -> Bool {
        guard canSend, reachable, waiting else { return false }
        switch reason {
        case .stopped, .delivered, .retry:
            return true
        case .cameForward, .run:
            // A last wake in the future (the clock was set back) doesn't hold the next one off.
            guard let lastWake else { return true }
            return !(0..<quietFor).contains(now.timeIntervalSince(lastWake))
        }
    }
}
