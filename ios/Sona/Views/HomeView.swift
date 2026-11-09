import SwiftUI
import UniformTypeIdentifiers

/// Home, like Voice Memos: every note in one list, newest first, and the record button floating at the bottom. While
/// it records, a sheet comes up with the time, the live wave and Stop. A tap on a note opens it; Settings and search
/// are the two buttons at the top. Monochrome: red is only for recording.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var searching = false
    /// The recording sheet is asked for. Its own state rather than `isRecording` itself, so it can be asked for again:
    /// a recording started from the Lock Screen, Siri or the Action button while something else was up (a share sheet,
    /// a confirm, an alert) can't present it.
    @State private var showingRecording = false
    /// The recording sheet is on screen.
    @State private var recordingShown = false
    /// The recording sheet grows with the text size, so Stop never ends up below it.
    @ScaledMetric(relativeTo: .title3) private var sheetHeight = 340

    var body: some View {
        @Bindable var bindable = model
        NavigationStack(path: $bindable.path) {
            HomeList()
                .navigationTitle("Sona")
                .navigationBarTitleDisplayMode(.large)
                .searchable(
                    text: $bindable.searchQuery, isPresented: $searching,
                    placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Titles, places and words")
                // Search is the system's field under the title, so there's no second search button up here.
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
                // While it records, a small bar with Stop under the sheet: Stop stays on Home even if the sheet can't
                // come up.
                .safeAreaBar(edge: .bottom) {
                    if model.isRecording {
                        RecordingBar().padding(.horizontal).padding(.bottom, 8)
                    } else {
                        RecordButton().padding(.bottom, 8)
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .note(let id): NoteDetailView(id: id)
                    case .settings: SettingsView()
                    case .privacy: PrivacyView()
                    }
                }
        }
        // The recording: a sheet, so it can't be swiped away while the mic is on (Stop ends it).
        .sheet(isPresented: $showingRecording) {
            RecordingSheet()
                .presentationDetents([.height(sheetHeight)])
                .interactiveDismissDisabled()
                .onAppear { recordingShown = true }
                .onDisappear { recordingShown = false }
        }
        // The sheet follows the recording. One that didn't come up (something else was on screen) is asked for again
        // every second, so it shows as soon as that closes.
        .task(id: model.isRecording) {
            guard model.isRecording else {
                showingRecording = false
                return
            }
            showingRecording = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, model.isRecording else { return }
                guard !recordingShown, scenePhase == .active else { continue }
                showingRecording = false
                try? await Task.sleep(for: .milliseconds(100))
                if !Task.isCancelled, model.isRecording { showingRecording = true }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isRecording)
        // Monochrome controls (black in light, white in dark), not the system blue: red is only for recording.
        .tint(.primary)
        // A place tapped on a note: Home shows that place's notes, with the search closed.
        .onChange(of: model.placeFilter) { _, place in if place != nil { searching = false } }
        #if DEBUG
        // `-debugSearch`: the search open with the words in it (screenshots).
        .onAppear { if AppModel.debugArgument("-debugSearch") != nil { searching = true } }
        #endif
        // Settings' Other folder and a banner's "Choose folder": the folder picked becomes the notes folder. One
        // file picker for the whole stack (two in one hierarchy don't both work).
        .fileImporter(isPresented: $bindable.choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task {
                if let problem = await model.setNotesChoice(.folder, folder: url) { model.problem = problem }
            }
        }
        #if DEBUG
        // `-debugOpenNote latest` opens the newest note once it's listed (for screenshots).
        .onChange(of: model.notes.notes.first?.id) { _, id in
            guard let id, model.path.isEmpty, UserDefaults.standard.string(forKey: "debugOpenNote") == "latest" else { return }
            model.path = [.note(id)]
        }
        #endif
    }
}

/// The one list, with the download line and anything that needs saying above it.
private struct HomeList: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: NoteRow?
    @State private var deletingRecording: NoteRow?
    /// An old kept note whose Don't Keep Audio waits for its confirm: without Keep audio its audio goes at once.
    @State private var droppingAudio: NoteRow?
    /// Notes whose words (with their row's fields) match the search, read off the main thread, and the query.
    @State private var textMatches = TextMatches()

    var body: some View {
        // Read once per render: it lists the spool on disk.
        let all = model.homeRows
        let query = model.searchQuery.trimmingCharacters(in: .whitespaces)
        let place = model.placeFilter
        // A place tapped on a note: the notes made there, by the exact name (not a search for its words).
        let here = place.map { place in all.filter { $0.isAt(place) } } ?? all
        let found = textMatches.ids(for: query)
        let rows = query.isEmpty
            ? here : here.filter { NoteSearch.matches(query, in: NoteSearch.fields($0)) || found.contains($0.id) }
        let banners = model.banners
        let progress = model.modelProgress
        List {
            if query.isEmpty, place == nil {
                if let progress { ModelProgressView(progress: progress, showsKeepOpen: true) }
                ForEach(banners) { banner in BannerRow(banner: banner) }
            }
            if let place { PlaceFilterRow(place: place) }
            ForEach(rows) { row in cell(row) }
        }
        .listStyle(.plain)
        .overlay {
            if all.isEmpty, banners.isEmpty, progress == nil, !model.isRecording {
                ContentUnavailableView("No notes yet", systemImage: "waveform", description: Text("Tap Record to start."))
            } else if !query.isEmpty, rows.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .refreshable { await model.refresh() }
        // What was said: the notes read already answer at once, the rest once the typing stops for a moment. Again
        // whenever the notes change (one listed, downloaded, moved or deleted), so a note never goes missing from a
        // search that's open.
        .task(id: SearchRun(query: query, notes: model.notes.notes)) {
            guard !query.isEmpty else { textMatches = TextMatches(); return }
            let notes = model.notes.notes.filter(\.isDownloaded).map { note in
                TranscriptCache.Searched(id: note.id, url: note.url, fields: NoteSearch.fields(NoteRow(summary: note)))
            }
            let quick = await TranscriptCache.shared.matching(query, in: notes, readingNew: false)
            if !Task.isCancelled { textMatches = TextMatches(query: query, ids: quick) }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let all = await TranscriptCache.shared.matching(query, in: notes)
            if !Task.isCancelled { textMatches = TextMatches(query: query, ids: all) }
        }
        .confirmationDialog(
            "Delete this note?", isPresented: shown($deleting), titleVisibility: .visible, presenting: deleting
        ) { row in
            Button("Delete note", role: .destructive) { Task { await model.delete(row) } }
        } message: { _ in
            Text(AppModel.deleteMessage)
        }
        .confirmationDialog(
            "Delete this recording?", isPresented: shown($deletingRecording), titleVisibility: .visible,
            presenting: deletingRecording
        ) { row in
            Button("Delete recording", role: .destructive) { model.deleteRecording(row) }
        } message: { _ in
            Text("It hasn't turned into a note yet. Its audio is deleted from this iPhone. This can't be undone.")
        }
        .confirmationDialog(
            AppModel.keepAudioOffTitle, isPresented: shown($droppingAudio), titleVisibility: .visible,
            presenting: droppingAudio
        ) { row in
            Button("Delete audio", role: .destructive) { Task { await model.setKeepAudio(false, for: row) } }
        } message: { _ in
            Text(AppModel.keepAudioOffMessage)
        }
    }

    private func shown(_ row: Binding<NoteRow?>) -> Binding<Bool> {
        Binding(get: { row.wrappedValue != nil }, set: { if !$0 { row.wrappedValue = nil } })
    }

    /// A row with its swipes: left to delete (after a confirm), right for Keep audio (after a confirm when turning it
    /// off deletes the audio now). A recording that failed tries again when tapped.
    @ViewBuilder private func cell(_ row: NoteRow) -> some View {
        switch row.state {
        case .note:
            // No chevron, like Voice Memos: the link is behind the row, which is the whole tap target.
            HomeRow(row: row)
                .background { NavigationLink(value: Route.note(row.id)) { EmptyView() }.opacity(0) }
                // The hidden link gives VoiceOver nothing: say it opens, and open it.
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.path.append(.note(row.id)) }
                // Not `role: .destructive`: that takes the row out before the confirm is answered, so Cancel (or a
                // delete that failed) left the note looking deleted. The confirm's own button has the role.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { deleting = row } label: { Label("Delete", systemImage: "trash") }
                        .tint(.red)
                }
                // No full swipe, like Delete: on an old kept note, Don't Keep Audio deletes its audio.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if model.offersKeepAudio(row) {
                        Button {
                            if model.keepAudioOffDeletesAudio(row) {
                                droppingAudio = row
                            } else {
                                Task { await model.setKeepAudio(!row.keepAudio, for: row) }
                            }
                        } label: {
                            Label(row.keepAudio ? "Don't keep audio" : "Keep audio", systemImage: row.keepAudio ? "pin.slash" : "pin")
                        }
                        .tint(Color(uiColor: .systemGray))
                    }
                }
        case .failed:
            HomeRow(row: row)
                .contentShape(Rectangle())
                .onTapGesture { model.retry(row) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Tries to transcribe it again")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { deletingRecording = row } label: { Label("Delete", systemImage: "trash") }
                        .tint(.red)
                }
        case .waiting:
            HomeRow(row: row)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { deletingRecording = row } label: { Label("Delete", systemImage: "trash") }
                        .tint(.red)
                }
        case .transcribing:
            HomeRow(row: row)
        }
    }
}

/// Home showing one place's notes (a place tapped on a note): the place, and a button back to every note.
private struct PlaceFilterRow: View {
    @Environment(AppModel.self) private var model
    var place: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(place, systemImage: "mappin.and.ellipse")
                .font(.headline)
                .accessibilityLabel("Notes made at \(place)")
            Spacer(minLength: 8)
            Button("Show all") { model.placeFilter = nil }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .accessibilityHint("Shows every note again")
        }
        .padding(.vertical, 4)
    }
}

/// What Home's search of the notes' words runs again on: the query, and the notes listed.
private struct SearchRun: Equatable {
    var query: String
    var notes: [NoteSummary]
}

/// A row as Voice Memos has it: the title, then when and where in grey, the length on the right. Its pieces wrap
/// under each other at big text sizes rather than cut off.
struct HomeRow: View {
    @Environment(AppModel.self) private var model
    var row: NoteRow

    var body: some View {
        let parts = row.listParts(notesChoice: model.notesChoice)
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.headline)
                .foregroundStyle(row.state == .note ? Color.primary : Color.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) { pieces(parts) }
                    VStack(alignment: .leading, spacing: 4) { pieces(parts) }
                }
                Spacer(minLength: 8)
                if let length = row.lengthClock {
                    Text(length)
                        .monospacedDigit()
                        // "4 minutes, 25 seconds": read as a clock, "4:25" sounds like a second time of day.
                        .accessibilityLabel(row.lengthSpoken ?? length)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func pieces(_ parts: [String]) -> some View {
        if row.state == .transcribing {
            ProgressView().controlSize(.mini)
        } else if row.state == .failed {
            Image(systemName: "exclamationmark.circle")
        } else if row.isWatch {
            Image(systemName: "applewatch").accessibilityLabel("From watch")
        }
        ForEach(parts, id: \.self) { Text($0) }
    }
}

/// Something that needs saying above the notes (a recording cut short, the notes folder gone, notes that failed),
/// as a plain row: a symbol, the words, and what to do about it.
struct BannerRow: View {
    @Environment(AppModel.self) private var model
    var banner: Banner

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: banner.isProblem ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(banner.text)
                    .font(.subheadline)
                if let action = banner.action {
                    Button(action.title) { model.perform(action) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(.primary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
