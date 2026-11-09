import NotesKit
import SwiftUI

/// One note: a big serif title, when and how long, where (a tap shows Home with every note made there) and who, then
/// what was said, with the player pinned at the bottom (Play, the recording's whole wave and where it's at), so Pause
/// is always in reach. While it plays, the line being played stays in full black and the rest go grey, and the page
/// follows it until he scrolls the page himself; Play or a tapped line follows again. Share and the "…" menu (Keep
/// audio, Delete) are at the top.
struct NoteDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var id: String
    @State private var player = AudioPlayer()
    /// Read once: the body runs 5 times a second while the audio plays, and reading means parsing the whole note.
    @State private var note: NoteDetail?
    @State private var looked = false
    /// The recording's loudness for its wave, read off the main thread once the note is open, and the file it's of.
    @State private var peaks: [Float]?
    @State private var peaksURL: URL?
    /// The audio is only in iCloud for now: opening the note started bringing it back, and the player shows once
    /// it's here.
    @State private var downloadingAudio = false
    /// The page follows the line being played. Scrolling the page by hand stops that; Play or a tapped line starts it
    /// again.
    @State private var following = true
    @State private var confirmingDelete = false
    /// Keep audio turned off on an old note waits for its confirm: without it its audio goes at once.
    @State private var confirmingAudioDelete = false

    var body: some View {
        Group {
            if let note {
                content(note)
            } else if looked {
                ContentUnavailableView("This note isn't here any more", systemImage: "doc.questionmark")
            } else {
                placeholder
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) {
            note = await model.detail(id)
            looked = true
            await showAudio(note?.audioURL)
            #if DEBUG
            // `-debugPlayNote`: plays from a third of the way in, for screenshots of a note playing.
            if ProcessInfo.processInfo.arguments.contains("-debugPlayNote") {
                player.muted = true
                player.seek(to: player.duration / 3)
            }
            #endif
            // Audio iCloud took off this iPhone: it's on its way down, and the player shows when it's here. Leaving
            // the page stops the wait.
            guard note != nil, note?.audioURL == nil, model.row(id)?.hasAudio == true else { return }
            downloadingAudio = true
            let url = await model.downloadedAudio(id)
            downloadingAudio = false
            guard !Task.isCancelled, let url else { return }
            note?.audioURL = url
            await showAudio(url)
        }
        .onDisappear { player.stop() }
    }

    private func content(_ note: NoteDetail) -> some View {
        let current = player.isPlaying ? currentLine(note) : nil
        return ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(note)
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(note.lines.indices, id: \.self) { i in
                            line(note, i, current: current)
                                .id(i)
                        }
                    }
                }
                .padding(.horizontal)
                // Clear of the back button and the menu, which float over the page.
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            // A hard edge under the pinned player: with the soft one the words scrolling under it showed through
            // behind its small times.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            // Scrolled by hand: the page stops following the line being played, so it isn't pulled back.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { following = false }
            }
            // The page follows the line being played.
            .onChange(of: current) { _, line in
                guard let line, following else { return }
                withAnimation(.easeInOut(duration: 0.35)) { scroller.scrollTo(line, anchor: .center) }
            }
        }
        // The player stays at the bottom however far the page is scrolled.
        .safeAreaBar(edge: .bottom) {
            if note.audioURL != nil {
                PlayerBar(player: player, peaks: peaks) { following = true }
                    // Fixed chrome, like the system's own bars: it stops growing at the second accessibility size,
                    // where Play, the wave and both times still fit side by side.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            } else if downloadingAudio {
                DownloadingAudio()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: note.markdown) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    keepAudio
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Note", role: .destructive) { Task { await delete() } }
        } message: {
            Text(AppModel.deleteMessage)
        }
        .confirmationDialog(AppModel.keepAudioOffTitle, isPresented: $confirmingAudioDelete, titleVisibility: .visible) {
            Button("Delete Audio", role: .destructive) { Task { await dropAudio() } }
        } message: {
            Text(AppModel.keepAudioOffMessage)
        }
    }

    /// The serif title (the one place New York is used), when it was made, where (each place lists its notes on
    /// Home), and who.
    private func header(_ note: NoteDetail) -> some View {
        let spots = places(note)
        return VStack(alignment: .leading, spacing: 8) {
            Text(note.title)
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let start = note.startedAt { Text(Format.noteWhen(start)) }
                    // With audio, the player says how long it is.
                    if note.audioURL == nil, let length = Format.seconds(fromLength: note.length) {
                        Text(Format.clock(length))
                            .monospacedDigit()
                            .accessibilityLabel(Format.spokenLength(length))
                    }
                }
                ForEach(spots.indices, id: \.self) { i in
                    let name = spots[i]
                    // Every note made here: Home filtered to this place, exactly (not a search for its words).
                    Button {
                        model.showNotes(at: name)
                    } label: {
                        Label(name, systemImage: i == 0 ? "mappin.and.ellipse" : "arrow.turn.down.right")
                    }
                    .buttonStyle(.plain)
                    // With two, which is the start and which the end: the arrow isn't read out.
                    .accessibilityLabel(spots.count > 1 ? (i == 0 ? "Started at \(name)" : "Ended at \(name)") : name)
                    .accessibilityHint("Shows every note made here")
                }
                if let who = who(note) {
                    Label(who.text, systemImage: who.watch ? "applewatch" : "person.2")
                        .accessibilityLabel(who.spoken)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    /// Who's in it ("Speaker 1, Speaker 2"), whether the watch recorded it, and both in words for VoiceOver (the
    /// watch symbol isn't read out).
    private func who(_ note: NoteDetail) -> (text: String, watch: Bool, spoken: String)? {
        let watch = AppModel.isWatch(note.source)
        let speakers = ListFormatter.localizedString(byJoining: note.speakers)
        if !speakers.isEmpty { return (speakers, watch, watch ? "\(speakers), recorded on Apple Watch" : speakers) }
        return watch ? ("Recorded on Apple Watch", true, "Recorded on Apple Watch") : nil
    }

    /// While the note loads (from iCloud, say): its title from the list, and grey lines where the text will be.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.row(id)?.title ?? "Note")
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
            ForEach(0..<4, id: \.self) { _ in
                Text("A line of what was said while the note loads, long enough to wrap.")
            }
            .redacted(reason: .placeholder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func places(_ note: NoteDetail) -> [String] {
        var out: [String] = []
        for name in [note.place, note.placeEnd].compactMap({ $0 }) where !name.isEmpty && !out.contains(name) { out.append(name) }
        return out
    }

    private func line(_ note: NoteDetail, _ i: Int, current: Int?) -> some View {
        let line = note.lines[i]
        let canPlay = note.audioURL != nil
        // Playing: the line being played in full, the rest grey. Otherwise all of it in full.
        let dimmed = current != nil && current != i
        return VStack(alignment: .leading, spacing: 4) {
            // The time in the same grey as the speaker: tertiary was too faint to read at caption size.
            HStack(spacing: 6) {
                Text(line.speaker).fontWeight(.semibold)
                Text(Format.clock(line.offset)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(line.text)
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if canPlay { play(from: line.offset) } }
        .animation(.easeInOut(duration: 0.2), value: dimmed)
        // One element per line for VoiceOver, which can play the audio from it.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canPlay ? .isButton : [])
        .accessibilityHint("Plays from here", isEnabled: canPlay)
        .accessibilityAction { if canPlay { play(from: line.offset) } }
    }

    /// A tapped line: plays from there, and the page follows it again.
    private func play(from offset: Double) {
        following = true
        player.seek(to: offset)
    }

    /// Keep audio, in 30-day mode: this note's audio stays for good. Turning it off on a note over 30 days old asks
    /// first: its audio is deleted at once.
    @ViewBuilder private var keepAudio: some View {
        if model.audioPolicy == .thirtyDays, let row = model.row(id), row.hasAudio {
            Toggle(isOn: Binding(get: { row.keepAudio }, set: { keep in
                if !keep, model.keepAudioOffDeletesAudio(row) {
                    confirmingAudioDelete = true
                } else {
                    Task { await model.setKeepAudio(keep, for: row) }
                }
            })) {
                Label("Keep audio", systemImage: "pin")
            }
        }
    }

    /// Keep audio off, confirmed: the audio goes now, and the player with it. Audio still there afterwards (the change
    /// failed, or the audio is in a folder the setting doesn't reach) is opened again, wave and all, so the player
    /// works as before.
    private func dropAudio() async {
        guard let row = model.row(id) else { return }
        player.stop()
        await model.setKeepAudio(false, for: row)
        if let fresh = await model.detail(id) { note = fresh }
        await showAudio(note?.audioURL)
    }

    /// The player and its wave for `url`: loaded when the audio is here, gone when it isn't.
    private func showAudio(_ url: URL?) async {
        player.load(url)
        guard let url else {
            peaks = nil
            peaksURL = nil
            return
        }
        guard peaks == nil || peaksURL != url else { return }
        peaksURL = url
        peaks = await Task.detached(priority: .userInitiated) { AudioPeaks.load(url) }.value
    }

    private func delete() async {
        guard let row = model.row(id) else {
            model.problem = "Couldn't delete that note. Try again in a moment."
            return
        }
        player.stop()
        if await model.delete(row) { dismiss() }
    }

    /// The line being played: the last one that started before the playhead.
    private func currentLine(_ note: NoteDetail) -> Int? {
        note.lines.lastIndex { $0.offset <= player.current }
    }
}

/// Play, the whole recording as a wave (drag it to move), and where it's at, pinned at the bottom of the note. Flat:
/// no card.
private struct PlayerBar: View {
    var player: AudioPlayer
    var peaks: [Float]?
    /// Play tapped: the page follows the line being played again.
    var onPlay: () -> Void
    /// Play's circle grows with the text size, so its symbol stays inside it.
    @ScaledMetric(relativeTo: .title3) private var playSize = 48.0

    var body: some View {
        HStack(spacing: 16) {
            Button {
                if !player.isPlaying { onPlay() }
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: playSize, height: playSize)
                    .background(Circle().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            VStack(spacing: 4) {
                PlaybackWave(peaks: peaks, progress: player.duration > 0 ? player.current / player.duration : 0) { fraction in
                    player.seek(to: fraction * player.duration, play: false)
                }
                .frame(height: 34)
                .accessibilityElement()
                .accessibilityLabel("Position")
                .accessibilityValue("\(Format.clock(player.current)) of \(Format.clock(player.duration))")
                .accessibilityAdjustableAction { direction in
                    let step: Double = direction == .increment ? 15 : -15
                    player.seek(to: player.current + step, play: false)
                }
                // Each on one line, never broken mid-number: at big sizes they get a little smaller first.
                HStack {
                    Text(Format.clock(player.current))
                    Spacer(minLength: 8)
                    Text(Format.clock(player.duration))
                }
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Where the player goes while the note's audio comes down from iCloud.
private struct DownloadingAudio: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Downloading the audio from iCloud")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
