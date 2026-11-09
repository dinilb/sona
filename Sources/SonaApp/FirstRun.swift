import AVFoundation
import AppKit
import ApplicationServices
import LiveCore
import NotesKit
import SwiftUI

/// The first-run screen, shown once, before anything listens: what Sona does, that it stays on this Mac, the
/// recording-consent line, always on or only while the key is held, the two permissions and the model download.
/// Nothing records until Start (`AppModel.finishFirstRun`).
struct FirstRunView: View {
    let model: AppModel
    /// After Start: the app delegate swaps this window for the main one.
    let done: () -> Void
    @State private var alwaysOn = true
    /// Off until chosen: AI apps reading your notes is opt-in.
    @State private var aiAccess = false
    @State private var openAtLogin = true
    /// Off until chosen: it needs another permission.
    @State private var macAudio = false
    @State private var mic: AVAuthorizationStatus
    @State private var trusted: Bool

    /// `mic`, `trusted`: what the permissions are now (headless renders pass a new Mac's).
    init(
        model: AppModel, mic: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio),
        trusted: Bool = AXIsProcessTrusted(), done: @escaping () -> Void = {}
    ) {
        self.model = model
        self.done = done
        _mic = State(initialValue: mic)
        _trusted = State(initialValue: trusted)
    }

    private var key: String { model.settings.dictationKey.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Welcome to Sona").font(Theme.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text("It shows what's being said, word by word, as it's said.")
                    Text("Hold a key in any app to dictate, and the words are typed for you.")
                    Text("If you want, it keeps a note of every conversation, with who said what.")
                }
                Text("Everything stays on this Mac.").fontWeight(.semibold)
                Text(
                    "Recording laws differ by place: some places need everyone's consent before you record a "
                        + "conversation. Speaker labels come from comparing voices, on this Mac."
                )
                .font(Theme.small).foregroundStyle(Theme.grey)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Theme.meta("how should it listen?")
                choice("Always on (notes of every conversation)", "The mic stays on, and each conversation becomes a note.", value: true)
                choice("Only while I hold the key", "The mic opens only while you hold \(key), and for 30 seconds after so the next one starts at once. Only the text you dictate is kept.", value: false)
                Toggle("Let AI apps on this Mac read the notes and live transcript (MCP)", isOn: $aiAccess)
                    .toggleStyle(CheckboxStyle())
                    .padding(.top, 4)
                Toggle("Open at login", isOn: $openAtLogin)
                    .toggleStyle(CheckboxStyle())
                if MacAudio.supported {
                    Toggle("Also hear what this Mac plays (videos, calls), as its own track", isOn: $macAudio)
                        .toggleStyle(CheckboxStyle())
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Microphone", done: mic == .authorized, detail: micDetail) { micButton }
                step(2, "Accessibility", done: trusted, detail: "So holding \(key) works in any app, and the words can be pasted.") {
                    Button("open accessibility settings") {
                        // Puts Sona in the list (macOS may ask too), then opens that list.
                        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        SystemSettings.open("Privacy_Accessibility")
                    }
                }
                step(3, "Speech models", done: model.live == .ready, detail: modelsDetail) {
                    if !model.liveStarted || model.liveLoadFailed {
                        Button(model.liveLoadFailed ? "try again" : "download now") { model.loadLive() }
                    }
                }
                if model.liveStarted, case .loading(let p, _) = model.live { Theme.bar(p).padding(.leading, 30) }
            }
            HStack {
                Spacer()
                Button("start") {
                    model.finishFirstRun(alwaysOn: alwaysOn, aiAccess: aiAccess, openAtLogin: openAtLogin, macAudio: macAudio)
                    done()
                }
                .buttonStyle(ProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540, alignment: .leading)
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .background(Theme.paper)
        .buttonStyle(LinkButtonStyle())
        .environment(\.colorScheme, .light)
        .task {
            // Permissions are granted in System Settings, which doesn't tell us: look again every second.
            while !Task.isCancelled {
                mic = AVCaptureDevice.authorizationStatus(for: .audio)
                trusted = AXIsProcessTrusted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var micDetail: String {
        switch mic {
        case .authorized: return "Allowed."
        case .notDetermined: return "To hear anything at all. macOS asks once."
        default: return "Turned off for Sona. Allow it in System Settings."
        }
    }

    @ViewBuilder private var micButton: some View {
        if mic == .notDetermined {
            Button("allow") {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    mic = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        } else {
            Button("open microphone settings") { SystemSettings.open("Privacy_Microphone") }
        }
    }

    private var modelsDetail: String {
        let notes = alwaysOn ? " Notes need about 465 MB more, downloaded next." : ""
        switch model.live {
        case .ready: return "Ready." + notes
        case .failed(let why): return why
        case .loading(let p, let text) where model.liveStarted: return p > 0.01 ? "\(text) \(Int(p * 100))%" : text
        case .loading: return "About 960 MB for the live transcript and dictation, downloaded once." + notes
        }
    }

    private func choice(_ title: String, _ detail: String, value: Bool) -> some View {
        Button {
            alwaysOn = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: alwaysOn == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(alwaysOn == value ? Theme.ink : Theme.grey)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(Theme.small).foregroundStyle(Theme.grey)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func step<Action: View>(
        _ n: Int, _ title: String, done: Bool, detail: String, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? Theme.ink : Theme.grey)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(Theme.small).foregroundStyle(Theme.grey).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !done { action() }
        }
    }
}

/// Opens a Privacy & Security pane of System Settings: "Privacy_Microphone", "Privacy_Accessibility".
enum SystemSettings {
    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
