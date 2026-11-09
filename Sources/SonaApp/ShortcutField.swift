import AppKit
import Combine
import NotesKit
import SwiftUI

/// The dictation shortcut in Settings, and "change": the next shortcut pressed becomes it. Modifiers held and all
/// let go with no key in between are a hold of those ("Right ⌘", "⌃⌥"); a key pressed while modifiers are held is
/// a combo ("⌃⌥ Space"). Esc cancels.
struct ShortcutField: View {
    let model: AppModel
    @State private var recording = false
    @State private var problem: String?
    @State private var wispr = false

    var body: some View {
        Group {
            LabeledContent("Shortcut") {
                HStack(spacing: 12) {
                    Text(recording ? "Press your shortcut…" : model.settings.dictationKey.title)
                        .foregroundStyle(recording ? Theme.grey : Theme.ink)
                    Button(recording ? "cancel" : "change") { recording ? finish() : start() }
                        .disabled(!model.settings.dictation || !model.dictation.trusted)
                }
            }
            if recording {
                Text(problem ?? "Modifiers held alone (Right ⌘, ⌃⌥), or with one key (⇪ A, ⌃⌥ Space). Esc cancels.")
                    .font(Theme.small).foregroundStyle(Theme.grey)
            } else if model.settings.dictationKey == .fn {
                Text("fn only works on Apple keyboards.").font(Theme.small).foregroundStyle(Theme.grey)
                if wispr { Text("Wispr Flow also uses fn").font(Theme.small).foregroundStyle(Theme.grey) }
            } else if model.settings.dictationKey.usesCapsLock {
                Text("Caps Lock doesn't turn on caps while Sona runs.").font(Theme.small).foregroundStyle(Theme.grey)
            }
        }
        .onAppear { wispr = Self.wisprRunning }
        .onDisappear { finish() }
        // Keys pressed in another app aren't meant for this.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in finish() }
    }

    private func start() {
        problem = nil
        recording = true
        // fn and Caps Lock would do their own thing (the emoji picker, caps on) instead of being held.
        FnKey.takeOver()
        CapsLockKey.takeOver()
        KeyMonitor.shared.record { result in
            switch result {
            case .shortcut(let shortcut):
                model.update { $0.dictationKey = shortcut }
                finish()
            case .refused(let why):
                problem = why
            case .cancelled:
                finish()
            }
        }
    }

    private func finish() {
        guard recording else { return }
        recording = false
        problem = nil
        KeyMonitor.shared.stopRecording()
        // fn and Caps Lock go back unless the shortcut uses them.
        model.dictation.configure(enabled: model.settings.dictation, key: model.settings.dictationKey)
        wispr = Self.wisprRunning
    }

    static var wisprRunning: Bool { NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Wispr Flow" } }
}
