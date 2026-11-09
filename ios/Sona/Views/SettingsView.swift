import CoreLocation
import SwiftUI
import UIKit

/// Where notes go, how long audio stays, places, the privacy policy and about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// A stricter audio setting waiting for its confirm, and how many audio files it deletes.
    @State private var stricter: (policy: AudioPolicy, files: Int)?
    @State private var working = false
    /// Re-read when the screen shows and when the app comes back (it changes in the Settings app).
    @State private var placesPermission = CLAuthorizationStatus.notDetermined
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Form {
            notesSection
            audioSection
            placesSection
            Section {
                NavigationLink("Privacy policy", value: Route.privacy)
                if let url = PrivacyPolicy.url {
                    Link("Privacy policy on the web", destination: url)
                }
            }
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .confirmationDialog(
            stricterTitle, isPresented: stricterShown, titleVisibility: .visible, presenting: stricter
        ) { pending in
            Button("Delete Audio", role: .destructive) { Task { await apply(pending.policy) } }
        } message: { _ in
            Text("Their text stays. This can't be undone.")
        }
        .onAppear { placesPermission = PlaceStamps.shared.permission }
        .onChange(of: phase) { _, now in if now == .active { placesPermission = PlaceStamps.shared.permission } }
    }

    // MARK: notes

    private var notesSection: some View {
        Section {
            ForEach(NotesChoice.allCases, id: \.self) { choice in
                Button {
                    // Other folder: the picker on Home (one file picker per screen stack), which then moves notes there.
                    if choice == .folder { model.choosingFolder = true } else { Task { await change(to: choice) } }
                } label: {
                    ChoiceRow(
                        title: Self.title(choice), detail: detail(choice), selected: model.notesChoice == choice)
                }
                .foregroundStyle(Color.primary)
            }
        } header: {
            Text("Notes")
        } footer: {
            Text(Self.notesFooter(model.notesChoice))
        }
    }

    /// What a change does to the notes already in `current`. Notes kept On this iPhone stay listed after a switch
    /// (Files can't reach that folder); iCloud and a picked folder are in the Files app.
    static func notesFooter(_ current: NotesChoice?) -> String {
        if current == .iphone {
            "Notes already on this iPhone stay on it when you change this, and Sona still lists them, marked on this iPhone. New notes go to the new place."
        } else {
            "Notes already in the old place stay there when you change this. New notes, and any still waiting on this iPhone, go to the new place."
        }
    }

    private func detail(_ choice: NotesChoice) -> String {
        switch choice {
        case .icloud:
            model.iCloudSignedIn
                ? "In iCloud Drive › Sona, and on your other devices."
                : "Sign in to iCloud in the Settings app first. Until then notes wait on this iPhone."
        case .iphone:
            NotesChoiceText.iPhoneDetail
        case .folder:
            model.notesChoice == .folder ? "\(model.notesPlaceName ?? "A folder you picked"). Tap to pick another." : NotesChoiceText.folderDetail
        }
    }

    static func title(_ choice: NotesChoice) -> String {
        switch choice {
        case .icloud: "iCloud"
        case .iphone: "On this iPhone"
        case .folder: "Other folder"
        }
    }

    private func change(to choice: NotesChoice) async {
        guard choice != model.notesChoice else { return }
        working = true
        if let problem = await model.setNotesChoice(choice, folder: nil) { model.problem = problem }
        working = false
    }

    // MARK: audio

    private var audioSection: some View {
        Section {
            ForEach(AudioPolicy.allCases, id: \.self) { policy in
                Button {
                    Task { await choose(policy) }
                } label: {
                    ChoiceRow(title: Self.title(policy), detail: Self.detail(policy), selected: model.audioPolicy == policy)
                }
                .foregroundStyle(Color.primary)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("The text of every note stays whatever you pick here.")
        }
    }

    static func title(_ policy: AudioPolicy) -> String {
        switch policy {
        case .thirtyDays: "Keep for 30 days"
        case .forever: "Keep forever"
        case .deleteAfterTranscribing: "Delete once transcribed"
        }
    }

    static func detail(_ policy: AudioPolicy) -> String {
        switch policy {
        case .thirtyDays: "Then only the text stays. Keep audio on a note keeps its audio for good."
        case .forever: "Every note keeps its audio. About 14 MB an hour."
        case .deleteAfterTranscribing: "Only the text is kept."
        }
    }

    /// A setting that deletes audio now says how many files first.
    private func choose(_ policy: AudioPolicy) async {
        guard policy != model.audioPolicy else { return }
        working = true
        let files = await model.audioFilesRemoved(by: policy)
        working = false
        if files > 0 { stricter = (policy, files) } else { await apply(policy) }
    }

    private func apply(_ policy: AudioPolicy) async {
        working = true
        await model.setAudioPolicy(policy)
        working = false
    }

    private var stricterTitle: String {
        guard let stricter else { return "" }
        return "Delete the audio of \(stricter.files) note\(stricter.files == 1 ? "" : "s")?"
    }

    private var stricterShown: Binding<Bool> {
        Binding(get: { stricter != nil }, set: { if !$0 { stricter = nil } })
    }

    // MARK: places

    private var placesSection: some View {
        Section {
            LabeledContent("Location", value: Self.describe(placesPermission, asked: PlaceStamps.shared.hasAsked))
            if placesPermission == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Turn On in Settings", destination: settings)
            } else if placesPermission == .notDetermined {
                // Never answered (an Allow Once that ran out, say): iOS's own question again.
                Button("Turn On") { PlaceStamps.shared.askFromSettings() }
            }
        } header: {
            Text("Places")
        } footer: {
            Text("Each note gets the street where you recorded it: one location fix when a recording starts and one when it stops, only while you use Sona. Apple's geocoder gets the coordinates to find the street name.")
        }
        // The answer to Turn On comes while the screen is up.
        .onChange(of: PlaceStamps.shared.permission) { _, now in placesPermission = now }
    }

    /// `asked`: the one question was used (onboarding asks it now), so none comes after a recording.
    static func describe(_ status: CLAuthorizationStatus, asked: Bool) -> String {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: "On"
        case .denied: "Off"
        case .restricted: "Not allowed on this iPhone"
        case .notDetermined: asked ? "Off" : "Asked after your next recording"
        @unknown default: "Unknown"
        }
    }

    // MARK: about

    @ViewBuilder private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            LabeledContent("Speech model", value: "Parakeet TDT 0.6B v2, English")
        } header: {
            Text("About")
        } footer: {
            Text("Sona turns speech into text on this iPhone. It understands English.")
        }
        Section {
            // Each opens its licence's text: Apache-2.0 and BSD-2-Clause ask for the text to go with the app.
            ForEach(Licence.all, id: \.name) { item in
                Link(destination: item.url) {
                    LabeledContent(item.name, value: item.licence)
                }
                .foregroundStyle(Color.primary)
            }
            NavigationLink("Licence texts") { LicenceTextsView() }
        } header: {
            Text("Licences")
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// The lines about notes choices that onboarding and Settings share. The Mac only reads iCloud Drive's own Sona
/// folder and the app's iCloud folder (`PhoneImport.defaultSources`), so these say what it can't see.
nonisolated enum NotesChoiceText {
    static let iPhoneDetail =
        "In a folder on this iPhone, and in its iCloud Backup. Not in iCloud Drive, so Sona on a Mac doesn't see them."
    static let folderDetail = "A folder you pick in the Files app. Sona on a Mac reads it only if it's iCloud Drive › Sona."
}

/// What the app ships or downloads, and under which licence (THIRD_PARTY.md). VBx and fastcluster are inside
/// FluidAudio, from its own third-party notices.
nonisolated struct Licence: Sendable {
    var name: String
    var licence: String
    var url: URL

    private static let apache = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
    private static let ccBy = URL(string: "https://creativecommons.org/licenses/by/4.0/")!

    static let all = [
        Licence(name: "FluidAudio by FluidInference", licence: "Apache-2.0", url: apache),
        Licence(name: "VBx, © BUT Speech@FIT", licence: "Apache-2.0", url: apache),
        Licence(
            name: "fastcluster, © Daniel Müllner and Google Inc.", licence: "BSD-2-Clause",
            url: URL(string: "https://opensource.org/license/bsd-2-clause")!),
        Licence(name: "Parakeet TDT 0.6B v2 by NVIDIA", licence: "CC BY 4.0", url: ccBy),
        Licence(name: "pyannote speaker-diarization-community-1", licence: "CC BY 4.0", url: ccBy),
        Licence(name: "Silero VAD by the Silero Team", licence: "MIT", url: URL(string: "https://opensource.org/license/mit")!),
        Licence(name: "hearsay, © Tanner Vass", licence: "MIT", url: URL(string: "https://opensource.org/license/mit")!),
    ]
}

/// The licence and notice texts that ship inside the app (Apache-2.0 and BSD-2-Clause ask for them to go with it),
/// copied from the repo root and `ios/Resources/Licenses` by project.yml.
nonisolated struct LicenceText: Sendable, Identifiable {
    var title: String
    var file: String
    var id: String { file }

    static let all = [
        LicenceText(title: "Sona", file: "LICENSE"),
        LicenceText(title: "Credits and notices", file: "THIRD_PARTY.md"),
        LicenceText(title: "FluidAudio", file: "FluidAudio-LICENSE.txt"),
        LicenceText(title: "VBx", file: "vbx-LICENSE.md"),
        LicenceText(title: "fastcluster", file: "fastcluster-LICENSE.md"),
    ]

    /// The file's text, or nil if the bundle doesn't have it.
    func text(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: file, withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The bundled licence texts, one screen each.
struct LicenceTextsView: View {
    var body: some View {
        List(LicenceText.all) { item in
            NavigationLink(item.title) { LicenceTextView(item: item) }
        }
        .navigationTitle("Licence texts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenceTextView: View {
    var item: LicenceText

    var body: some View {
        ScrollView {
            Text(item.text() ?? "This text isn't in the app. See github.com/dinilb/sona.")
                .font(.footnote)
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A choice in a list: its name, a line about it, and a checkmark on the one in use.
struct ChoiceRow: View {
    var title: String
    var detail: String
    var selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
