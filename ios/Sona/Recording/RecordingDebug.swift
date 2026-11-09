import Foundation
import NotesKit

/// Recording without the mic, for the simulator and headless checks. Debug builds only; launch arguments (read
/// through UserDefaults, e.g. `xcrun simctl launch <sim> com.dinilb.sona -debugRecordFile /path/clip.wav`):
/// - `-debugRecordFile <path>`: recordings play this audio file (any format) in real time instead of the mic.
/// - `-debugAutoRecordSeconds N`: a recording starts at launch and stops after N s.
nonisolated enum RecordingDebug {
    static var recordFile: URL? {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "debugRecordFile"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        #else
        return nil
        #endif
    }

    static var autoRecordSeconds: Double? {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "debugAutoRecordSeconds")
        return seconds > 0 ? seconds : nil
        #else
        return nil
        #endif
    }

    /// The app calls this once at launch (from SonaApp; the app's owner wires it): with `-debugAutoRecordSeconds`,
    /// records for that long by itself.
    @MainActor static func runIfRequested() {
        #if DEBUG
        guard let seconds = autoRecordSeconds else { return }
        Log.note("debug: recording for \(seconds) s from \(recordFile == nil ? "the default source" : "a file")")
        Task { @MainActor in
            do {
                try await PhoneRecorder.shared.start()
            } catch {
                return  // PhoneRecorder logged why
            }
            try? await Task.sleep(for: .seconds(seconds))
            await PhoneRecorder.shared.stop()
        }
        #endif
    }
}
