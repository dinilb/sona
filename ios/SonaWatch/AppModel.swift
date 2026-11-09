import Foundation
import Observation
import SwiftUI
import WidgetKit

/// The watch app: the recorder, the queue that sends recordings to the iPhone, and the status the complications
/// read. One for the app's life, so the deep links and the App Intent reach the same recorder.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let recorder: WatchRecorder
    let queue: TransferQueue
    private let session: WatchSession
    private let complications = ComplicationStatus()

    private init() {
        let store = RecordingStore.standard
        // Before anything records: a recording a crash or a flat battery cut off is repaired and queued.
        store.recover()
        session = WatchSession()
        recorder = WatchRecorder(store: store)
        queue = TransferQueue(store: store, session: session)
        session.queue = queue
        Self.connect(recorder: recorder, queue: queue, complications: complications)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-debugFakeRecording") { recorder.startFake() }
        #endif
        session.activate()
        queue.run()
    }

    /// `sona://record` (the complication: one tap on the watch face starts a note) and `sona://stop`, each with this
    /// watch's key (`LinkKey`). A link without it only opens the app: nothing starts, nothing stops.
    func open(_ url: URL) {
        switch DeepLink.trusted(url: url) {
        case .record: Task { await recorder.start() }
        case .stop: recorder.stop()
        case nil: break
        }
    }

    func phaseChanged(_ phase: ScenePhase) {
        recorder.setVisible(phase == .active)
        if phase == .active { queue.cameForward() }
    }

    /// The WatchConnectivity background task: the session was set up when `shared` was made, so this only waits
    /// for what's pending (an acknowledgement, the iPhone's inventory) to be handed over and applied.
    static func drainConnectivity() async {
        await shared.session.drain()
    }

    /// The status line under the button.
    var status: String {
        if let message = recorder.message { return message }
        let waiting = queue.waiting
        return waiting == 0 ? "All on iPhone" : "\(waiting) waiting for iPhone"
    }

    /// The last few recordings for the list: the one recording now, those still on the watch, and those the
    /// iPhone has.
    var recent: [RecentRecording] {
        let onWatch = queue.recordings.map {
            RecentRecording(recording: $0, state: $0.id == recorder.currentID ? .recording : .waiting)
        }
        let sent = queue.sent.filter { done in !onWatch.contains { $0.id == done.id } }
            .map { RecentRecording(recording: $0, state: .sent) }
        return Array((onWatch + sent).sorted { $0.recording.startedAt > $1.recording.startedAt }.prefix(6))
    }

    /// A start or stop on this watch reaches the queue (the recording being made isn't sent), and every change of the
    /// queue reaches the complications: the watch's own start time and how many wait, saved in the App Group and
    /// reloaded only when that changes (reloads have a budget). Its own function so the tests wire it the same way.
    static func connect(recorder: WatchRecorder, queue: TransferQueue, complications: ComplicationStatus) {
        // A stop wakes the iPhone right then, while he's still looking at the watch (`TransferQueue.recordingChanged`).
        recorder.onChange = { [weak recorder, weak queue] in
            guard let recorder, let queue else { return }
            queue.recordingChanged(to: recorder.currentID)
        }
        recorder.onHealthy = { [weak complications] in complications?.heartbeat() }
        queue.onChange = { [weak recorder, weak queue, weak complications] in
            guard let recorder, let queue else { return }
            complications?.publish(recordingSince: recorder.startedAt, waiting: queue.waiting)
        }
    }
}

/// Tells the complications what to draw: whether a recording runs and how many wait. It saves that into the App Group
/// and asks WidgetKit to reload them (reloads have a budget) only when it differs from what this process last asked
/// them to draw, and always the first time. Not when it differs from what's saved: a reload iOS dropped is saved all
/// the same, and comparing with that would never ask again, so a complication could say "recording" for good after
/// the recording ended.
@MainActor
final class ComplicationStatus {
    /// Where the status lives: the App Group, or a stand-in for tests.
    struct Store {
        var load: () -> SharedStatus
        var save: (SharedStatus) -> Void
        var reload: () -> Void

        static let appGroup = Store(
            load: { SharedStatus.load() }, save: { $0.save() }, reload: { WidgetCenter.shared.reloadAllTimelines() })
    }

    /// The two things the watch's complications draw.
    private struct Drawn: Equatable {
        var recordingSince: Date?
        var waiting: Int
    }

    private let store: Store
    /// What this process last asked for; nil until the first publish.
    private var lastDrawn: Drawn?
    /// The clock, so tests can move it on.
    var now: () -> Date = { Date() }

    init(store: Store = .appGroup) {
        self.store = store
    }

    /// True if it asked the complications to reload.
    @discardableResult
    func publish(recordingSince: Date?, waiting: Int) -> Bool {
        let drawn = Drawn(recordingSince: recordingSince, waiting: waiting)
        guard drawn != lastDrawn else { return false }
        lastDrawn = drawn
        var status = store.load()
        status.recordingSince = recordingSince
        // In the same save: a reload at the start must not read the last recording's old heartbeat and draw this
        // one as stopped.
        status.aliveAt = recordingSince == nil ? nil : now()
        status.waiting = waiting
        store.save(status)
        store.reload()
        return true
    }

    /// The recording is still being written (the recorder's minute check): saved without a reload, so a
    /// complication that reloads later can tell a live recording from one whose app died
    /// (`SharedStatus.liveRecordingSince`).
    func heartbeat() {
        var status = store.load()
        guard status.recordingSince != nil else { return }
        status.aliveAt = now()
        store.save(status)
    }
}

struct RecentRecording: Identifiable {
    enum State { case recording, waiting, sent }
    var recording: WatchRecording
    var state: State
    var id: String { recording.id }
}
