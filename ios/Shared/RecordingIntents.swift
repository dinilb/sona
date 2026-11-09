import AppIntents
import Foundation

// The intents behind the Lock Screen and Control Center button, the Action button, Siri, and the Live Activity's
// Stop button. They're declared here, in both the app and the widget extension (so a Control can name them), and
// each target gives them their own `perform()`: the app's records (Sona/Intents/IntentActions.swift), the widget
// extension's never runs (SonaWidgets/IntentStubs.swift), because these intent types always run in the app.
// No location code here: this file is in the widget extension too.

/// Starts recording from anywhere, the app in the background included. `AudioRecordingIntent` is what lets iOS
/// start the mic without opening the app; it requires a Live Activity for as long as the recording runs. It runs in
/// the background, and comes to the foreground only when it must: the very first time, when the mic has never been
/// asked for (that question can only show on screen).
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record a Note"
    static let description = IntentDescription("Starts recording a voice note in Sona.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    init() {}
}

/// The Record control's action: starts a note, or stops the one recording when pressed again (the way Voice Memos
/// works). Siri's "Record a note" stays start-only, so saying it twice never stops a note.
struct ToggleRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record or Stop"
    static let description = IntentDescription("Starts a voice note in Sona, or stops and saves the one it's recording.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    init() {}
}

/// Stops the recording (the Live Activity's button, or Siri).
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the voice note Sona is recording and saves it.")
    static let supportedModes: IntentModes = .background

    init() {}
}
