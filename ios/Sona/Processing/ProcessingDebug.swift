import Foundation
import NotesKit
import SonaEngine

/// `-debugProcessSpool` (DEBUG builds only): starts the notes pipeline, turns everything waiting in the spool into
/// notes with nobody touching the app, prints a line about it (counts and times, never titles), and quits. For the
/// end-to-end check in the simulator. The app calls `runIfRequested()` at launch.
enum ProcessingDebug {
    static func runIfRequested() {
        #if DEBUG
        downloadIfRequested()
        guard ProcessInfo.processInfo.arguments.contains("-debugProcessSpool") else { return }
        Task {
            let service = NotesService.shared
            let t0 = Date()
            service.start()
            await service.waitUntilIdle()
            let took = Date().timeIntervalSince(t0)
            let line = "debugProcessSpool: done in \(String(format: "%.1f", took)) s; folder \(service.location?.kind.rawValue ?? "none")"
                + " \(service.location?.folder.path ?? "-"); notes \(service.notes.count); waiting \(service.pending);"
                + " failed \(service.failed); models \(service.modelState); error \(service.lastError ?? "none")"
            print(line)
            Log.note(line)
            exit(0)
        }
        #endif
    }

    /// `-debugDownloadModels`: what the Download button does, with nobody tapping it, then a line saying how it went and
    /// quits. Checks the first thing anyone does with the app: the model download, in the iPhone's own folders.
    private static func downloadIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-debugDownloadModels") else { return }
        Task {
            let service = NotesService.shared
            service.start()
            let t0 = Date()
            await service.downloadModels()
            let line = "debugDownloadModels: \(service.modelState) in \(String(format: "%.0f", Date().timeIntervalSince(t0))) s;"
                + " ready on disk: \(Models.isReady(model: NotesService.model))"
            print(line)
            Log.note(line)
            exit(0)
        }
        #endif
    }
}
