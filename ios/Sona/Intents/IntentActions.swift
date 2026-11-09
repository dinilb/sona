import AppIntents
import AVFoundation
import NotesKit
import UIKit

// The app's side of the shared intents (Shared/RecordingIntents.swift): these run in the app's process, which iOS may
// launch in the background just for them, so PhoneRecorder needs nothing from the UI.
extension StartRecordingIntent {
    func perform() async throws -> some IntentResult {
        guard try await openAppUntilSetUp() else { return .result() }
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
            guard try await openAppUntilSetUp() else { return .result() }
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
    /// A fresh install whose first tap is the Record control or Siri: no recording until onboarding is done
    /// (`AppModel.outsideStart`), so nothing records under the welcome screen with no Stop. True when it may record.
    @MainActor func openAppUntilSetUp() async throws -> Bool {
        let start = AppModel.outsideStart(
            onboardingDone: AppModel.shared.onboardingDone,
            offScreen: UIApplication.shared.applicationState == .background,
            canOpenApp: systemContext.currentMode.canContinueInForeground)
        switch start {
        case .record: return true
        case .openApp: try await continueInForeground("Open Sona to set it up, then you can record.")
        case .stay: break
        case .refuse: throw RecordingError.notSetUp
        }
        Log.note("a start from outside the app only opened it: onboarding isn't done")
        return false
    }

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
