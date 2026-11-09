import AVFoundation
import CoreLocation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Onboarding's screens, numbered as `-debugOnboardingStep` takes them. Three, like Apple's own first runs: what Sona
/// is (and the speech model it downloads), your notes, and what it asks for. Home comes straight after.
enum OnboardingStep: Int, CaseIterable {
    /// What Sona is and its speech model: the download starts on Continue (App Review 4.2.3(ii)).
    case welcome = 1
    /// Where notes go and how long their audio stays, both shown with their defaults and changeable here.
    case notes
    /// The microphone, notifications and location, asked one after another after a neutral Continue.
    case allow

    /// The screen after this one; nil after the last, when Home shows.
    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
}

/// Runs once, for existing installs too. Monochrome and quiet (design/DESIGN-RULES.md): one symbol, a title, a few
/// rows, one Continue at the bottom. The model's progress shows at the top of every screen after the welcome.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep
    @State private var notesChoice: NotesChoice
    /// Other folder: the folder picked here, applied on Continue.
    @State private var pickedFolder: URL?
    /// Keep audio as shown: what Continue saves, exactly.
    @State private var audio: AudioChoice
    @State private var choosingFolder = false
    @State private var working = false
    /// Continue found that the audio choice deletes audio now: the choice it counted, and how many files, to confirm.
    @State private var pendingAudio: PendingAudio?
    @State private var showingPrivacy = false
    @State private var micPermission = AVAudioApplication.shared.recordPermission
    /// Follows `PlaceStamps.permission` (see the `onChange` in `body`), so the location row says what's true now.
    @State private var placesPermission: CLAuthorizationStatus

    init(start: OnboardingStep, notesChoice: NotesChoice, audioPolicy: AudioPolicy) {
        _step = State(initialValue: start)
        _notesChoice = State(initialValue: notesChoice)
        _audio = State(initialValue: AudioChoice(audioPolicy))
        _placesPermission = State(initialValue: PlaceStamps.shared.permission)
    }

    var body: some View {
        ZStack {
            ScrollView {
                page
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // At big text sizes the page goes on under the pinned Continue: the scroll bar shows for a moment to say so.
            .scrollIndicatorsFlash(onAppear: true)
            // Each screen slides in over the last (a crossfade showed both screens' text at once).
            .id(step)
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.push(from: .trailing))
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if step != .welcome, let progress = model.modelProgress {
                DownloadLine(progress: progress)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { continueButton }
        .background(Color(uiColor: .systemBackground))
        // Monochrome here: menus, the progress bar and links take the text colour, not the system blue.
        .tint(Color.primary)
        .animation(.smooth, value: step)
        // Back from Settings with location changed: the @State from init would keep the old answer. Not while Continue
        // is working: the closing question would change the row under its alert.
        .onChange(of: PlaceStamps.shared.permission) { _, now in if !working { placesPermission = now } }
        // The notes list can come in after this screen shows: an install that already has notes starts on Keep
        // forever, so going straight on deletes nothing. Only until he picks one or taps Continue (`AudioChoice`).
        .onChange(of: model.notes.notes.isEmpty) { _, _ in
            if step == .notes { audio.suggest(model.defaultAudioPolicy) }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            pickedFolder = url
            notesChoice = .folder
        }
        .confirmationDialog(
            audioConfirmTitle, isPresented: audioConfirmShown, titleVisibility: .visible, presenting: pendingAudio
        ) { pending in
            // The very choice that was counted, never one read again since.
            Button("Delete audio", role: .destructive) {
                Task {
                    await model.setAudioPolicy(pending.policy)
                    step = .allow
                }
            }
        } message: { _ in
            Text("Notes you already have lose their audio now. Their text stays.")
        }
        .sheet(isPresented: $showingPrivacy) {
            NavigationStack {
                PrivacyView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingPrivacy = false } } }
            }
        }
        #if DEBUG
        .onAppear {
            // `-debugOnboardingStep` past the welcome: the welcome's Continue would have allowed the download.
            if step != .welcome, !V1Settings.modelDownloadAllowed { model.allowModelDownload() }
        }
        #endif
    }

    // MARK: screens

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcome
        case .notes: notesPage
        case .allow: allowPage
        }
    }

    private var welcome: some View {
        VStack(spacing: 32) {
            Header(symbol: "waveform", title: "Welcome to Sona")
            VStack(alignment: .leading, spacing: 24) {
                FeatureRow(
                    symbol: "applewatch", title: "One tap to record",
                    detail: "On your iPhone, your Apple Watch or the Lock Screen.")
                FeatureRow(
                    symbol: "text.quote", title: "Every word written down",
                    detail: "Each note keeps who said what, and when and where.")
                FeatureRow(
                    symbol: "lock", title: "Stays on your devices",
                    detail: "Speech turns into text on this iPhone, never on a server. No account.")
            }
            // The model's size is pinned above Continue (`continueButton`), so it's on screen with it at any text size.
            Button("Privacy policy") { showingPrivacy = true }
                .font(.footnote)
                .buttonStyle(.borderless)
        }
    }

    private var notesPage: some View {
        VStack(spacing: 32) {
            Header(symbol: "folder", title: "Your notes", line: "You can change these later in Settings.")
            VStack(spacing: 0) {
                Divider()
                ChoiceMenuRow(
                    label: "Notes go to",
                    value: OnboardingText.notesValue(
                        notesChoice, folderName: pickedFolder.map { FileManager.default.displayName(atPath: $0.path) },
                        hasPickedFolder: AppModel.hasPickedFolder),
                    detail: OnboardingText.notesDetail(notesChoice, iCloudSignedIn: model.iCloudSignedIn)
                ) {
                    choice("iCloud", selected: notesChoice == .icloud) { notesChoice = .icloud }
                    choice("On this iPhone", selected: notesChoice == .iphone) { notesChoice = .iphone }
                    Divider()
                    // The folder is applied once one is picked; a cancelled picker leaves the choice as it was.
                    choice("Other folder...", selected: notesChoice == .folder) { choosingFolder = true }
                }
                Divider()
                ChoiceMenuRow(
                    label: "Keep audio", value: OnboardingText.audioValue(audio.policy),
                    detail: SettingsView.detail(audio.policy)
                ) {
                    ForEach(AudioPolicy.allCases, id: \.self) { policy in
                        choice(SettingsView.title(policy), selected: audio.policy == policy) { audio.pick(policy) }
                    }
                }
                Divider()
            }
        }
        .onAppear { audio.suggest(model.defaultAudioPolicy) }
    }

    /// Like Apple's own: a neutral Continue, then the system's alerts one after another, where he says yes or no. No
    /// button here skips them or says Allow (App Review 5.1.1(iv)); Don't Allow on location just means no places.
    private var allowPage: some View {
        VStack(spacing: 32) {
            Header(symbol: "hand.raised", title: "What Sona asks for")
            VStack(alignment: .leading, spacing: 24) {
                FeatureRow(symbol: "mic", title: "Microphone", detail: "Only while you're recording.")
                FeatureRow(
                    symbol: "bell", title: "Notifications",
                    detail: "If a call or Siri pauses a recording, so one never stops without you knowing.")
                FeatureRow(symbol: "location", title: "Location", detail: OnboardingText.places(placesPermission))
            }
            Text("iOS asks about each one next. Location is up to you: without it, notes just have no place.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if micPermission == .denied {
                micOffNote
            }
        }
    }

    private var micOffNote: some View {
        VStack(spacing: 8) {
            Text("The microphone is off for Sona. Turn it on in Settings to record.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settings)
                    .font(.footnote.weight(.semibold))
            }
        }
    }

    /// A menu item with a checkmark on the one in use.
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    // MARK: moving on

    /// Continue, pinned at the bottom. On the welcome, the model's size sits right above it: Continue starts the
    /// download, so the disclosure App Review 4.2.3(ii) asks for is on screen with it at every text size (in the page
    /// it scrolled out of sight at the large ones). Fixed chrome: it stops growing at the second accessibility size.
    private var continueButton: some View {
        VStack(spacing: 12) {
            if step == .welcome {
                Text(OnboardingText.modelDisclosure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            Button {
                Task { await next() }
            } label: {
                ContinueLabel()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(
                working || continueDisabledForScreenshots
                    || (step == .notes && notesChoice == .folder && pickedFolder == nil && !AppModel.hasPickedFolder))
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private func next() async {
        working = true
        defer { working = false }
        switch step {
        case .welcome:
            // The disclosure App Review 4.2.3(ii) asks for is this screen: from here the model downloads by itself.
            model.allowModelDownload()
            step = .notes
        case .notes:
            // Keep audio as it's on screen, taken before anything else: saving where notes go changes the folder
            // bookmark the suggested default reads, and a value read again could delete audio he chose to keep.
            let policy = audio.take()
            if let problem = await model.setNotesChoice(notesChoice, folder: notesChoice == .folder ? pickedFolder : nil) {
                model.problem = problem
                return
            }
            let files = await model.audioFilesRemoved(by: policy)
            if files > 0 {
                pendingAudio = PendingAudio(policy: policy, files: files)
            } else {
                await model.setAudioPolicy(policy)
                step = .allow
            }
        case .allow:
            // A neutral Continue, then the system's own alerts (no button here says Allow).
            if AVAudioApplication.shared.recordPermission == .undetermined {
                _ = await AVAudioApplication.requestRecordPermission()
            }
            micPermission = AVAudioApplication.shared.recordPermission
            // Notifications here too, so the first recordings aren't interrupted by it. Off the main actor: the
            // notification center can block its caller for seconds (RecordingNotice.swift).
            _ = await Task.detached {
                try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }.value
            // When In Use only, never Always. Asked or not, the question after the first recording doesn't come.
            await PlaceStamps.shared.askInOnboarding()
            placesPermission = PlaceStamps.shared.permission
            // Straight to Home: a microphone that's off says so there when Record is tapped, with Open Settings.
            model.finishOnboarding()
        }
    }

    private var audioConfirmTitle: String {
        guard let files = pendingAudio?.files else { return "" }
        return "Delete the audio of \(files) note\(files == 1 ? "" : "s")?"
    }

    private var audioConfirmShown: Binding<Bool> {
        Binding(get: { pendingAudio != nil }, set: { if !$0 { pendingAudio = nil } })
    }
}

/// An audio choice that deletes audio now, waiting for its confirm: the choice counted, and how many files.
struct PendingAudio: Equatable {
    var policy: AudioPolicy
    var files: Int
}

/// Onboarding's Keep audio: what's on screen is exactly what's saved. The suggested start
/// (`AppModel.defaultAudioPolicy`, Keep forever for an install that already has notes) replaces it only until he picks
/// one or taps Continue. Continue saves where notes go first, which writes or deletes the folder bookmark that default
/// reads: read again then, it saved Forever over a 30 days on screen, or 30 days (deleting older audio) over a Forever.
nonisolated struct AudioChoice: Equatable {
    /// On screen.
    private(set) var policy: AudioPolicy
    /// He picked one himself.
    private(set) var picked = false
    /// Continue took it: from then on it's what's saved.
    private(set) var taken = false

    init(_ policy: AudioPolicy) { self.policy = policy }

    mutating func pick(_ policy: AudioPolicy) {
        self.policy = policy
        picked = true
    }

    /// The suggested start, read again as the notes are listed; ignored once he picked one or Continue took it.
    mutating func suggest(_ policy: AudioPolicy) {
        if !picked, !taken { self.policy = policy }
    }

    /// Continue: the value on screen, which nothing replaces after this.
    mutating func take() -> AudioPolicy {
        taken = true
        return policy
    }
}

/// Continue's words, in a colour for each state. Enabled, the button is filled with the text colour, so the words take
/// the page's colour (white on black, black on white in dark mode: the style's own white vanished on white in dark
/// mode). Disabled, the text colour, which the style fades over its grey fill to a mid grey: its own disabled words
/// measured 1.4:1 in light mode and 2.2:1 in dark, and the secondary label colour, faded the same way, 2:1 in light.
private struct ContinueLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text("Continue")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(isEnabled ? AnyShapeStyle(.background) : AnyShapeStyle(Color.primary))
    }
}

#if DEBUG
/// `-debugContinueDisabled`: Continue drawn disabled, for screenshots of how that reads.
private let continueDisabledForScreenshots = ProcessInfo.processInfo.arguments.contains("-debugContinueDisabled")
#else
private let continueDisabledForScreenshots = false
#endif

// MARK: - Pieces

/// A screen's top: one symbol, the title, and maybe one quiet line, centred.
private struct Header: View {
    var symbol: String
    var title: String
    var line: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .imageScale(.large)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let line {
                Text(line)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }
}

/// A symbol, a short bold title and one grey line, like the rows on Apple's welcome screens.
private struct FeatureRow: View {
    var symbol: String
    var title: String
    var detail: String
    @ScaledMetric(relativeTo: .title2) var symbolWidth: CGFloat = 32

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A setting as one row: its name, the value in use (a menu of the choices), and a grey line about that value.
private struct ChoiceMenuRow<Choices: View>: View {
    var label: String
    var value: String
    var detail: String
    @ViewBuilder var choices: Choices
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                choices
            } label: {
                // Side by side, like Settings; the value goes under the name at the accessibility sizes, where the two
                // squeezed into one line wrapped word by word.
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label)
                                .foregroundStyle(.primary)
                            valueLine
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 8) {
                            Text(label)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            valueLine
                        }
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(label)
            .accessibilityValue(value)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    /// The value in use and the menu's up-down mark, as Settings shows a menu picker.
    private var valueLine: some View {
        HStack(spacing: 8) {
            Text(value)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// The speech model's progress, small and grey at the top: it downloads by itself, so this only says how far.
private struct DownloadLine: View {
    var progress: ModelProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(OnboardingText.download(progress))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let fraction = progress.fraction, !progress.stopped {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .combine)
    }
}

/// What onboarding says, as plain values (unit tested in SonaTests/OnboardingPlacesTests.swift).
enum OnboardingText {
    static let modelDisclosure =
        "Sona downloads its speech model once, about 480 MB. Wi-Fi is best. The download starts when you continue, and you can record while it runs. It understands English."

    /// The notes row's value: short, the folder's own name for Other folder.
    static func notesValue(_ choice: NotesChoice, folderName: String?, hasPickedFolder: Bool) -> String {
        switch choice {
        case .icloud: "iCloud"
        case .iphone: "This iPhone"
        case .folder: folderName ?? (hasPickedFolder ? "Your folder" : "Other folder")
        }
    }

    /// The line under the notes row: where they end up, and what Sona on a Mac sees.
    static func notesDetail(_ choice: NotesChoice, iCloudSignedIn: Bool) -> String {
        switch choice {
        case .icloud:
            iCloudSignedIn
                ? "In iCloud Drive › Sona, and on your other devices."
                : "You're not signed in to iCloud. Notes wait on this iPhone until you are."
        case .iphone: NotesChoiceText.iPhoneDetail
        case .folder: NotesChoiceText.folderDetail
        }
    }

    /// The audio row's value; the menu uses `SettingsView.title`.
    static func audioValue(_ policy: AudioPolicy) -> String {
        switch policy {
        case .thirtyDays: "30 days"
        case .forever: "Forever"
        case .deleteAfterTranscribing: "Until transcribed"
        }
    }

    /// The download line: shorter than Home's, with no "please wait".
    static func download(_ progress: ModelProgress) -> String {
        if progress.stopped { return "The download stopped. Sona tries again by itself." }
        if progress.text.hasPrefix("Getting") { return "Getting the speech model ready" }
        if let fraction = progress.fraction, fraction > 0 {
            return "Downloading the speech model, \(Int((fraction * 100).rounded(.down)))%"
        }
        return "Downloading the speech model"
    }

    /// The location row: what it's for, or what's true already.
    static func places(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: "On. Each note gets the street where you recorded it."
        case .denied: "Off for Sona. Turn it on in Settings › Apps › Sona › Location to add places."
        case .restricted: "Not allowed on this iPhone, so notes won't have a place."
        default: "Adds the street where you recorded, so you can find notes by place. Only while you use Sona."
        }
    }
}
