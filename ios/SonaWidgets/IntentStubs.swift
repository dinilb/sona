import AppIntents

// The widget extension only needs these intents' types (a Control names one). iOS runs audio-recording and
// Live Activity intents in the app (Sona/Intents/IntentActions.swift), never here.
extension StartRecordingIntent {
    func perform() async throws -> some IntentResult { .result() }
}

extension ToggleRecordingIntent {
    func perform() async throws -> some IntentResult { .result() }
}

extension StopRecordingIntent {
    func perform() async throws -> some IntentResult { .result() }
}
