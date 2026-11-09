import BackgroundTasks
import Foundation
import NotesKit
import os

/// The charging-time drain: a BGProcessingTask (`SonaIDs.transcribeTask`) that transcribes what's waiting while the
/// iPhone is on power. Registered before launch finishes, scheduled whenever something waits.
nonisolated enum BackgroundProcessing {
    static let identifier = SonaIDs.transcribeTask

    /// A running BGTask, handed to the main actor and completed exactly once.
    final class Handle: @unchecked Sendable {  // a let and a lock
        let task: BGTask
        private let done = OSAllocatedUnfairLock(initialState: false)
        /// How many tasks run now (the charging one and the off-screen one can at once): one that expires gives the
        /// note's attempt back only when no other still carries the note (`NotesService.backgroundTaskExpiring`).
        static let running = OSAllocatedUnfairLock(initialState: 0)

        init(_ task: BGTask) {
            self.task = task
            Self.running.withLock { $0 += 1 }
        }

        func complete(success: Bool) {
            guard done.withLock({ done in defer { done = true }; return !done }) else { return }
            Self.running.withLock { $0 -= 1 }
            task.setTaskCompleted(success: success)
        }
    }

    /// Must run before the app finishes launching. The launch handler runs on a background queue, so nothing here
    /// is main-actor code: it hops there.
    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let handle = Handle(task)
            task.expirationHandler = {
                // The cut-short try is given back right here, then the task completes within iOS's grace period
                // whatever the main thread is doing; the main actor only resets its own state after.
                NotesService.backgroundTaskExpiring()
                handle.complete(success: false)
                Task { @MainActor in NotesService.shared.processingTaskExpired(handle) }
            }
            Task { @MainActor in NotesService.shared.runProcessingTask(handle) }
        }
        if !ok { Log.note("couldn't register the background transcription task") }
    }

    /// Asks for a run the next time the iPhone charges. Replaces any request already made, so it's safe to repeat.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        // On power only: that's what lifts iOS's background CPU limit (about 80% over a minute) for a processing task.
        // Off the charger a long note on the CPU would have the app killed partway, and each kill costs it a try.
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator always refuses (code 1, unavailable).
            Log.note("couldn't schedule background transcription: \(Log.describe(error))")
        }
    }
}
