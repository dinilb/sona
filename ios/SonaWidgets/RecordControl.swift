import AppIntents
import SwiftUI
import WidgetKit

/// The Record control: Lock Screen, Control Center and the Action button. It runs `ToggleRecordingIntent`, an
/// `AudioRecordingIntent`, which iOS runs in the app (in the background, no screen needed) and which needs the Live
/// Activity the recorder starts. Pressed while it records, it stops and saves the note, like Voice Memos.
///
/// It's a button, not a toggle: a toggle needs a `SetValueIntent` that is also an `AudioRecordingIntent`, and its
/// look would have to be reloaded by the app each time a recording starts or ends anywhere (the Live Activity, Siri,
/// the watch). The button always works and says what it does.
struct RecordControl: ControlWidget {
    static let kind = "com.dinilb.sona.record"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleRecordingIntent()) {
                Label("Record / Stop", systemImage: "mic.fill")
            }
        }
        .displayName("Record a note")
        .description("Starts a voice note in Sona. Press again to stop and save it.")
    }
}
