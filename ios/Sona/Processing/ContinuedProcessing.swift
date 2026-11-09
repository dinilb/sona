import BackgroundTasks
import Foundation
import NotesKit

/// The note after a stop, carried on with the app off screen: a BGContinuedProcessingTask (iOS 26). iOS shows it in
/// the Dynamic Island and on the Lock Screen with a progress bar, and he can cancel it there.
///
/// iOS only runs one that the person asked for in the app on screen, so it's asked for when he taps Stop in Sona. A
/// stop from the Lock Screen, Siri or the watch can't have one: those notes are written on the ~30 s of background
/// time iOS gives if they're short enough (30 s of audio or less, `NotesService.gate`); a longer one waits for the
/// foreground or the charging task. iOS ends a task whose bar sits still for about 30 s, so `NotesService` moves it
/// every second (`ContinuedProgress`). The simulator never runs these.
///
/// Each request has its own identifier (`prefix` and a suffix, permitted in Info.plist as `com.dinilb.sona.finish.*`),
/// registered just before it's submitted: a handler can't be registered for the wildcard itself, and registering one
/// identifier twice ends the app.
nonisolated enum ContinuedProcessing {
    static let prefix = "com.dinilb.sona.finish"

    /// Asks iOS to carry the waiting notes on if he leaves the app. False if it refused (logged; nothing else changes).
    @concurrent static func request(recordings: Int) async -> Bool {
        let identifier = "\(prefix).\(UUID().uuidString.prefix(8).lowercased())"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let handle = BackgroundProcessing.Handle(task)
            task.expirationHandler = {
                // Cancelled from the Lock Screen, or iOS needs the time back: like the charging task, the cut-short
                // try is given back first, then it completes within iOS's grace period.
                NotesService.backgroundTaskExpiring()
                handle.complete(success: false)
                Task { @MainActor in NotesService.shared.continuedTaskExpired(handle) }
            }
            Task { @MainActor in NotesService.shared.runContinuedTask(handle) }
        }
        guard registered else {
            Log.note("couldn't register the off-screen transcription task")
            return false
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: title(recordings: recordings), subtitle: "Transcribing on this iPhone")
        do {
            if #available(iOS 27, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            return true
        } catch {
            // The simulator always refuses (unavailable), and so does iOS when the app isn't on screen.
            Log.note("couldn't carry the note on off screen: \(Log.describe(error))")
            return false
        }
    }

    static func title(recordings: Int) -> String {
        recordings > 1 ? "Writing \(recordings) notes" : "Writing your note"
    }
}

/// The off-screen task's bar. Nothing reports how far a note's transcription has got, so it's a guess from the audio's
/// length and a rough speed, made to keep moving (iOS ends a task whose bar sits still for about 30 s) and never to
/// claim the end before the note is written.
nonisolated enum ContinuedProgress {
    /// Units per note: fine enough that the slow tail of a long note still moves a unit every few seconds.
    static let unitsPerNote: Int64 = 1_000_000
    /// Rough multiples of real time: the Neural Engine with the app on screen, the CPU off it (iOS 27 keeps the
    /// Neural Engine from apps in the background).
    static let neuralEngineSpeed = 15.0
    static let cpuSpeed = 3.0

    /// How far along the note being written probably is, 0..<0.99: straight to 0.8 by the time it should take, then
    /// ever slower towards 0.99.
    static func share(elapsed: TimeInterval, audioSeconds: Double, onCPU: Bool) -> Double {
        let expected = max(5, audioSeconds / (onCPU ? cpuSpeed : neuralEngineSpeed))
        let t = max(0, elapsed)
        if t <= expected { return 0.8 * t / expected }
        return 0.8 + 0.19 * (1 - expected / t)
    }

    /// The bar's next value, out of `total` notes: `done` written, and, while one is `underWay` (transcribing, then its
    /// m4a, title, place and move), its guess. Each try of a note starts its guess from `base`, where the bar was within
    /// that note when the try began, so a retry on the CPU carries on from there instead of starting over under it.
    /// While one is under way the bar moves at least one unit a tick (`previous` + 1) whatever the guess says, and
    /// stops short of the note's end until it's written; it never goes backwards.
    static func next(
        previous: Int64, done: Int, base: Int64, share: Double, total: Int, underWay: Bool
    ) -> (completed: Int64, total: Int64) {
        let unit = unitsPerNote
        let totalUnits = Int64(max(1, total, done + (underWay ? 1 : 0))) * unit
        let written = min(Int64(done) * unit, totalUnits)
        guard underWay else { return (min(max(previous, written), totalUnits), totalUnits) }
        let span = unit * 99 / 100
        let from = min(max(0, base), span - 1)
        let guess = written + from + Int64(Double(span - from) * min(0.99, max(0, share)))
        let completed = min(max(guess, previous + 1), written + span)
        return (max(completed, min(previous, written + span)), totalUnits)
    }
}
