import AppIntents

/// "Record a note" for Siri and Shortcuts: opens Sona on the watch and starts recording (the mic needs the app in
/// front to start; once started it keeps going with the wrist down).
struct RecordNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Note"
    static let description = IntentDescription("Opens Sona on your watch and starts recording a voice note.")
    static let supportedModes: IntentModes = .foreground

    func perform() async throws -> some IntentResult {
        await AppModel.shared.recorder.start()
        return .result()
    }
}

struct SonaWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordNoteIntent(),
            phrases: ["Record a note in \(.applicationName)", "Start recording in \(.applicationName)"],
            shortTitle: "Record a Note",
            systemImageName: "mic.fill")
    }
}
