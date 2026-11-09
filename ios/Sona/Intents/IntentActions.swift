import AppIntents
import AVFoundation
import UIKit

// The app's side of the shared intents (Shared/RecordingIntents.swift): these run in the app's process, which iOS may
// launch in the background just for them, so PhoneRecorder needs nothing from the UI.
extension StartRecordingIntent {
    func perform() async throws -> some IntentResult {
        try await continueOnScreenIfMicNotAsked()
        try await PhoneRecorder.shared.start()
        return .result()
    }
}

extension ToggleRecordingIntent {
    func perform() async throws -> some IntentResult {
        if await PhoneRecorder.shared.isRecording {
            await PhoneRecorder.shared.stop()
        } else {
            try await continueOnScreenIfMicNotAsked()
            try await PhoneRecorder.shared.start()
        }
        return .result()
    }
}

extension StopRecordingIntent {
    func perform() async throws -> some IntentResult {
        await PhoneRecorder.shared.stop()
        return .result()
    }
}

extension AppIntent {
    /// The first start from the Lock Screen, Siri or the Action button, before the mic was ever asked for: the
    /// question can only show on screen, so the intent asks to carry on in the app (he confirms), and the recorder asks
    /// there. Otherwise it stays in the background. With Sona already on screen the recorder asks by itself, and where
    /// iOS can't bring the app forward, start() says "tap Record once" (RecordingError.micNotAsked) rather than the
    /// intent failing with the system's own error.
    @MainActor func continueOnScreenIfMicNotAsked() async throws {
        guard AVAudioApplication.shared.recordPermission == .undetermined,
            UIApplication.shared.applicationState == .background,
            systemContext.currentMode.canContinueInForeground
        else { return }
        try await continueInForeground("Open Sona to allow the microphone, then it starts recording.")
    }
}
