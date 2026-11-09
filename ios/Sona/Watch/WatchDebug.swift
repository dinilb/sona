#if DEBUG
import Foundation
import NotesKit

/// `-debugReceiveWatchFile <aac or wav>`: hands that file to the watch inbox exactly as if the watch had sent it.
/// WatchConnectivity can't send files between simulators, so this is how the iPhone's half of the hand-off (the
/// watch's AAC staged and decoded, or its WAV layout, the spool, the note marked "Apple Watch") runs end to end there.
enum WatchDebug {
    private struct NoAck: WatchAcknowledging {
        func acknowledge(_ id: String) { Log.note("debug: watch recording acknowledged") }
    }

    @MainActor static func runIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "debugReceiveWatchFile") else { return }
        // The inbox moves the file it's given, like WCSession's: hand it a copy, named as the watch names it.
        let source = URL(fileURLWithPath: path)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension.isEmpty ? "wav" : source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            let inbox = WatchInbox(
                spool: Services.spool,
                receivedFile: FileManager.default.temporaryDirectory.appendingPathComponent("debug-watch-received.json"),
                acknowledger: NoAck())
            let recording = WatchRecording(startedAt: Date().addingTimeInterval(-120), duration: 0)
            switch try inbox.receive(file: copy, metadata: recording.metadata) {
            case .added(let id):
                Log.note("debug: a watch recording went into the spool")
                NotesService.shared.enqueue(id)
            case .staged:
                // Decoded here on the main actor: a debug run, and a short clip.
                for id in inbox.convertStaged() {
                    Log.note("debug: a watch AAC was decoded into the spool")
                    NotesService.shared.enqueue(id)
                }
            case .duplicate, .tooShort, .ignored:
                break
            }
        } catch {
            Log.note("debug: the watch recording couldn't be received: \(Log.describe(error))")
        }
    }
}
#endif
