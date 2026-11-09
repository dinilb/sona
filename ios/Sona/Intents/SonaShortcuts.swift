import AppIntents

/// Siri ("Record a note in Sona"), Spotlight and the Shortcuts app get the recording intents without any setup, so
/// Back Tap (Settings > Accessibility > Touch > Back Tap > Record a Note) can start a note from a pocket.
struct SonaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Record a note in \(.applicationName)", "Start \(.applicationName)", "Start recording in \(.applicationName)"],
            shortTitle: "Record a Note",
            systemImageName: "mic.fill")
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop \(.applicationName)", "Stop recording in \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.fill")
    }
}
