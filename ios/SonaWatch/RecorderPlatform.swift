import AVFoundation
import UserNotifications
import WatchKit

// What WatchRecorder needs from the watch, behind small protocols so tests can stand in for the mic, the
// notification centre, the disk and the haptics. The real ones are further down.

/// A recording being written to disk (an AVAudioRecorder behind it).
protocol AudioCapture: AnyObject {
    /// Seconds recorded so far.
    var currentTime: TimeInterval { get }
    /// Still writing: false once it stopped, by itself or not.
    var isRecording: Bool { get }
    /// Stops: flushes the last frames (and writes a WAV's sizes).
    func stop()
    /// The input level in decibels (about -160 silent, 0 loudest).
    func decibels() -> Float
}

/// What the recorder reports by itself (not when it was told to stop).
nonisolated enum RecorderEvent: Equatable, Sendable {
    case finished
    case failed
}

/// The mic: its permission, the audio session and the recorder.
protocol MicHardware: AnyObject {
    func requestPermission() async -> Bool
    func activateSession() throws
    func deactivateSession()
    /// Starts writing AAC (ADTS) at `url`, an `.aac`; if that recorder won't start, a WAV beside it (the same name,
    /// `.wav`) instead. Throws if the mic didn't start at all.
    func startRecording(to url: URL) throws -> any AudioCapture
    /// Called when a recorder finishes or fails by itself, with the id of the recording it was making. That can
    /// be late, after the next recording has started: the receiver checks the id.
    var onEvent: (@MainActor (_ id: String, _ event: RecorderEvent) -> Void)? { get set }
}

/// Notifications for a stop he didn't ask for (UNUserNotificationCenter behind it).
protocol StopNotifier: AnyObject {
    /// Asks for permission to notify. Only the first call does anything, and it never waits for the answer.
    func askPermission()
    /// Posts it `delay` seconds from now (0 is now). A later call replaces an earlier one.
    func notify(_ stop: UnexpectedStop, after delay: TimeInterval)
    /// Takes back one that is still pending or already showing: the recording is going again.
    func clear()
    /// Schedules a reminder `delay` seconds from now, replacing the same one if it's pending.
    func schedule(_ reminder: RecordingReminder, after delay: TimeInterval)
    /// Takes back a pending reminder: the recording stopped.
    func cancel(_ reminder: RecordingReminder)
}

/// Everything WatchRecorder uses outside itself.
struct RecorderPlatform {
    var mic: any MicHardware
    var notifier: any StopNotifier
    /// Free bytes on the volume holding this folder; nil if unknown.
    var freeBytes: (URL) -> Int64?
    var haptic: (WKHapticType) -> Void
    var center: NotificationCenter

    static func live() -> RecorderPlatform {
        RecorderPlatform(
            mic: SystemMic(), notifier: SystemStopNotifier(), freeBytes: SystemDisk.freeBytes(at:),
            haptic: { WKInterfaceDevice.current().play($0) }, center: .default)
    }
}

// MARK: - The real ones

/// An AVAudioRecorder as an `AudioCapture`.
final class SystemCapture: AudioCapture {
    private let recorder: AVAudioRecorder

    init(_ recorder: AVAudioRecorder) { self.recorder = recorder }

    var currentTime: TimeInterval { recorder.currentTime }
    var isRecording: Bool { recorder.isRecording }
    func stop() { recorder.stop() }

    func decibels() -> Float {
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }
}

/// The watch's mic. It is the recorders' delegate, and tells the recording's id with each report (read from the file
/// the recorder was writing), so a late report from an earlier recording can't be taken for the current one.
final class SystemMic: NSObject, MicHardware, AVAudioRecorderDelegate {
    var onEvent: (@MainActor (_ id: String, _ event: RecorderEvent) -> Void)?

    /// AAC at 16 kHz mono, 32 kbps, the iPhone's own audio settings (AudioCompressor): about 14 MB an hour, so an
    /// hour's note is a short transfer over the watch's radio instead of 115 MB. The `.aac` extension makes it ADTS,
    /// which a crash leaves readable up to its last whole frame.
    static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    /// 16 kHz mono 16-bit PCM, what the iPhone's speech engine reads: only when the AAC recorder won't start.
    static var wavSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
    }

    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func startRecording(to url: URL) throws -> any AudioCapture {
        do {
            return try record(to: url, settings: Self.aacSettings)
        } catch {
            // The encoder wouldn't start: a WAV records all the same, it's only bigger to send.
            try? FileManager.default.removeItem(at: url)
            return try record(to: url.deletingPathExtension().appendingPathExtension("wav"), settings: Self.wavSettings)
        }
    }

    private func record(to url: URL, settings: [String: Any]) throws -> any AudioCapture {
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else { throw CocoaError(.fileWriteUnknown) }
        return SystemCapture(recorder)
    }

    // AVFoundation calls these on its own queue.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        report(RecordingStore.id(ofAudio: recorder.url), .finished)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        report(RecordingStore.id(ofAudio: recorder.url), .failed)
    }

    private nonisolated func report(_ id: String, _ event: RecorderEvent) {
        Task { @MainActor in self.onEvent?(id, event) }
    }
}

/// Local notifications on the watch. The stop notification's identifier is the same every time, so there's only ever
/// one (each `RecordingReminder` has its own). Every call goes
/// to one serial queue of its own: UNUserNotificationCenter can block its caller for many seconds when its daemon is
/// busy (23 s measured on a just-booted iPhone simulator), which on the main actor would freeze the watch's screen, and
/// one queue keeps a post and its clear in order.
final class SystemStopNotifier: StopNotifier {
    private static let identifier = "sona.stopped"
    private nonisolated static let queue = DispatchQueue(label: "com.dinilb.sona.watch.notices", qos: .utility)
    private var asked = false

    func askPermission() {
        guard !asked else { return }
        asked = true
        // Not awaited by anything: a recording never waits for this prompt.
        Self.queue.async {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else { return }
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    func notify(_ stop: UnexpectedStop, after delay: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = UnexpectedStop.title
        content.body = stop.body
        content.sound = .default
        // A trigger-less request is delivered at once; a delayed one fires even when the app is suspended.
        let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)
        Self.queue.async { UNUserNotificationCenter.current().add(request) { _ in } }
    }

    func clear() {
        let id = Self.identifier
        Self.queue.async {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    func schedule(_ reminder: RecordingReminder, after delay: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        // Same identifier: a pending one is replaced, so the watchdog keeps moving ahead while all is well.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        let request = UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
        Self.queue.async { UNUserNotificationCenter.current().add(request) { _ in } }
    }

    func cancel(_ reminder: RecordingReminder) {
        let id = reminder.identifier
        Self.queue.async { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id]) }
    }
}

nonisolated enum SystemDisk {
    /// What a new file here could use. The recordings folder is made when the first recording is saved, so the
    /// nearest folder above it that exists is asked.
    static func freeBytes(at url: URL) -> Int64? {
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder.deleteLastPathComponent()
        }
        // The plain free space: watchOS has no "for important usage" figure, which counts what could be purged.
        return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
            .map(Int64.init)
    }
}
