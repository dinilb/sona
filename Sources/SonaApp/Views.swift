import AppKit
import LiveCore
import NotesKit
import SwiftUI

/// Headless renders (`LIVE_SNAPSHOT`, drawn with ImageRenderer, no window): ImageRenderer can't draw AppKit-backed
/// views, so the window's split view, List, ScrollView, Form and native switches become plain stacks and a drawn
/// switch. Everything inside them is the same view the window shows.
struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var staticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

/// The window: the sidebar (Now, the last 7 days, older days by month, Settings) and what's selected.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        Group {
            if staticRender {
                HStack(spacing: 0) {
                    Sidebar(model: model).frame(width: 250)
                    Hairline(vertical: true)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NavigationSplitView {
                    Sidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
                } detail: {
                    detail
                }
                .frame(minWidth: 720, minHeight: 440)
                .onChange(of: model.selection) { LayoutCheck.soon() }
                .task {
                    // File names only, so it's cheap: on open and every 30 s while the window is open.
                    while !Task.isCancelled {
                        model.library.refresh(root: model.settings.conversationsURL)
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
            }
        }
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .tint(Theme.ink)
        .background(Theme.paper)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var detail: some View {
        switch model.selection ?? .now {
        case .now: NowView(model: model)
        case .dictations: DictationsView(model: model, days: model.previewDictations)
        case .settings: SettingsView(model: model)
        case .about: AboutView()
        case .day(let day): DayView(model: model, day: day, notes: model.previewDay).id(day)
        case .conversation(let id): ConversationView(model: model, id: id, note: model.previewNote).id(id)
        }
    }
}

// MARK: sidebar

/// The sidebar's own rows (not a List), so the selection is a soft grey fill, never the system's blue: Now, the
/// last 7 days by name, older days under their month, Settings. Never a conversation: a day opens its list. Up and
/// down move through the rows that are showing, like a list.
struct Sidebar: View {
    @Bindable var model: AppModel
    @Environment(\.staticRender) private var staticRender
    @FocusState private var focused: Bool

    var body: some View {
        let groups = DayGroups(days: model.library.names.map(\.day), today: model.library.today)
        // Now and Settings stay put and only the days scroll, so the scroll view never runs up under the title bar:
        // there the sidebar column moves it below the bar and SwiftUI scrolls it down by the bar again, so every row
        // was drawn a bar's height below where it took clicks.
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 1) {
                item(.now) { nowRow }
                if showDictations { item(.dictations) { icon("text.bubble", "dictations") } }
            }
            .padding([.horizontal, .top], 10)
            if staticRender {
                days(groups)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView { days(groups) }
                        .focusable()
                        .focused($focused)
                        .defaultFocus($focused, true)
                        .focusEffectDisabled()
                        .onKeyPress(.upArrow) { step(-1, groups, proxy) }
                        .onKeyPress(.downArrow) { step(1, groups, proxy) }
                }
            }
            item(.settings) { icon("gearshape", "settings") }.padding(10)
        }
        .background(Theme.sidebar)
        .onChange(of: groups) { _, groups in
            // The open day is gone (its notes deleted or moved): go to the nearest day still showing, or Now.
            guard case .day(let day) = selected, !groups.allDays.contains(day) else { return }
            model.selection = DayGroups.nearest(to: day, in: groups.shownDays(open: isOpen)).map { .day($0) } ?? .now
        }
    }

    private func days(_ groups: DayGroups) -> some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(groups.recent, id: \.day) { dayRow($0) }
            ForEach(groups.months, id: \.id) { month in
                monthHeader(month)
                if isOpen(month) { ForEach(month.days, id: \.day) { dayRow($0) } }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    private var nowRow: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.image(model.menuIcon)).renderingMode(.template).foregroundStyle(Theme.grey).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("now")
                Theme.meta(model.statusLine)
            }
        }
    }

    /// Where pasted dictations are kept while always-on is off (and stay after it's turned on).
    private var showDictations: Bool { !model.settings.alwaysOn || !model.library.dictationDays.isEmpty }

    private func icon(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Theme.grey).frame(width: 18)
            Text(title)
        }
    }

    /// "today", "yesterday", "fri 23 oct", with its number of conversations.
    private func dayRow(_ day: DayGroups.Day) -> some View {
        item(.day(day.day)) {
            HStack {
                Text(day.title)
                Spacer()
                Theme.meta("\(day.count)")
            }
        }
        .accessibilityLabel("\(day.title), \(day.count == 1 ? "1 conversation" : "\(day.count) conversations")")
    }

    /// The row that shows as selected (a conversation's day).
    private var selected: SidebarItem { (model.selection ?? .now).row }

    private func item<Label: View>(_ target: SidebarItem, @ViewBuilder _ label: () -> Label) -> some View {
        Button {
            model.selection = target
            focused = true
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected == target ? Theme.selected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == target ? .isSelected : [])
        .id(target)
    }

    /// The newest month starts open and older ones closed; a click is remembered (and forgotten when it's back to that).
    private func isOpen(_ month: DayGroups.Month) -> Bool { model.settings.openMonths[month.id] ?? month.startsOpen }

    private func monthHeader(_ month: DayGroups.Month) -> some View {
        let open = isOpen(month)
        return Button {
            model.update { $0.openMonths[month.id] = open == month.startsOpen ? !open : nil }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
                Text(month.title)
            }
            .font(Theme.mono)
            .foregroundStyle(Theme.grey)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    /// Every row in order, and whether it's showing (a day in a closed month isn't; About, opened from Settings,
    /// comes after it): up and down step to the next one that is.
    private func step(_ by: Int, _ groups: DayGroups, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        var rows: [(item: SidebarItem, shown: Bool)] = [(.now, true)]
        if showDictations { rows.append((.dictations, true)) }
        rows += groups.recent.map { (.day($0.day), true) }
        for month in groups.months { rows += month.days.map { (.day($0.day), isOpen(month)) } }
        rows += [(.settings, true), (.about, false)]
        if case .day(let gone) = selected, !rows.contains(where: { $0.item == selected }) {
            // A day that's gone: step from where it was.
            let at = rows.firstIndex { row in
                if case .day(let day) = row.item { return DayGroups.isOlder(day, than: gone) }
                return row.item == .settings
            }
            rows.insert((selected, false), at: at ?? rows.count)
        }
        guard var i = rows.firstIndex(where: { $0.item == selected }) else { return .ignored }
        repeat { i += by } while rows.indices.contains(i) && !rows[i].shown
        if rows.indices.contains(i) {
            model.selection = rows[i].item
            proxy.scrollTo(rows[i].item)
        }
        return .handled
    }
}

// MARK: Now

struct NowView: View {
    let model: AppModel
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            transcript
            Hairline()
            footer
        }
        .background(Theme.paper)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("now").font(Theme.body.weight(.medium))
            Spacer()
            if model.isPaused { Button("resume") { model.resume() } }
            if !model.lines.isEmpty { Button("copy") { model.copyNow() } }
            DeleteMenu(model: model)
        }
        .buttonStyle(LinkButtonStyle())
        .padding(.horizontal, Theme.pad)
        .frame(height: 44)
    }

    private var lineList: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(model.lines.enumerated()), id: \.element.id) { i, line in
                VStack(alignment: .leading, spacing: 3) {
                    if model.labelled(line), i == 0 || model.lines[i - 1].speaker != line.speaker || !line.settled {
                        Theme.meta(!line.settled && line.speaker == nil ? "…" : AppModel.speakerName(line.speaker))
                            .opacity(line.settled ? 1 : 0.5)
                    }
                    if model.isCommand(line) {
                        Theme.meta("agent command", keepCase: true).foregroundStyle(Color.orange)
                        Theme.words(line.text)
                            .padding(6)
                            .background(Color.orange.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Theme.words(line.text)
                    }
                }
            }
        }
        .padding(Theme.pad)
    }

    @ViewBuilder private var transcript: some View {
        if staticRender {
            // The newest lines at the bottom, like the window scrolled to the end.
            lineList
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottomLeading)
                .clipped()
                .overlay { placeholder }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    lineList
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: (model.lines.last?.id ?? -1) * 1_000_000 + (model.lines.last?.text.count ?? 0)) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .overlay { placeholder }
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if model.lines.isEmpty {
            VStack(spacing: 10) {
                if case .loading(let p, let text) = model.live {
                    Theme.bar(p).frame(width: 220)
                    Text(text)
                } else if let problem = model.problem {
                    Text(problem).foregroundStyle(Theme.alert)
                    if model.micDenied {
                        Button("open microphone settings") {
                            SystemSettings.open("Privacy_Microphone")
                        }
                        .buttonStyle(LinkButtonStyle())
                    }
                } else if model.isPaused {
                    Text("Paused. The microphone is off.")
                } else if !model.settings.alwaysOn {
                    Text(
                        model.settings.dictation
                            ? "Always-on recording is off. The microphone only opens while you hold \(model.settings.dictationKey.title) to dictate."
                            : "Always-on recording and dictation are both off.")
                } else {
                    Text("Listening. Say something.")
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.grey)
            .padding(30)
        }
    }

    /// Like a "● rec" line: the level dot, the status and the lag; how to dictate on the right.
    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    model.problem != nil
                        ? Theme.alert
                        : model.mic == .running ? Theme.ink.opacity(Double(min(1, max(0.25, (model.level + 60) / 40)))) : Theme.grey.opacity(0.4)
                )
                .frame(width: 7, height: 7)
            Text(([model.statusLine] + (model.lagMs.map { ["lag ~\(Int($0)) ms"] } ?? [])).joined(separator: " · ").lowercased())
                .foregroundStyle(model.problem == nil ? Theme.grey : Theme.alert)
                .truncationMode(.tail)
            Spacer()
            if model.settings.dictation {
                if !model.dictation.trusted {
                    Button("allow accessibility for dictation") { SystemSettings.open("Privacy_Accessibility") }
                    .buttonStyle(LinkButtonStyle())
                } else {
                    Text("hold \(model.settings.dictationKey.title.lowercased()) to dictate").foregroundStyle(Theme.grey)
                }
            }
        }
        .font(Theme.mono)
        .lineLimit(1)
        .padding(.horizontal, Theme.pad)
        .frame(height: 34)
    }
}

/// "delete…" in Now: the last 5, 15 or 60 minutes.
struct DeleteMenu: View {
    let model: AppModel
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        if staticRender {
            Button("delete…") {}
        } else {
            Menu("delete…") {
                ForEach(DeleteRecent.choices, id: \.self) { minutes in
                    Button("The last \(minutes) minutes") { DeleteRecent.ask(minutes, model: model) }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .font(Theme.mono.weight(.medium))
            .foregroundStyle(Theme.ink)
            .fixedSize()
        }
    }
}

/// "Delete the last N minutes" (the menu bar or Now): one short alert, then `AppModel.deleteLast`.
@MainActor
enum DeleteRecent {
    static let choices = [5, 15, 60]

    static func ask(_ minutes: Int, model: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Delete the last \(minutes) minutes?"
        alert.informativeText = "The audio, notes, live transcript and dictations from that time are deleted for good."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.deleteLast(minutes: minutes)
    }
}

// MARK: one day

/// A day's conversations, newest first: when, title, speakers, length. A row opens the conversation; the one going
/// on now (if it began this day) is on top and opens Now. The rows are the same note files the sidebar counts; each
/// is read for its times and speakers, and one that can't be read is still listed.
struct DayView: View {
    let model: AppModel
    let day: String
    /// The day's notes that could be read, by id; nil until they're read.
    @State private var notes: [String: ConversationNote]?
    @Environment(\.staticRender) private var staticRender

    /// `notes`: already read (headless renders, where `.task` never runs).
    init(model: AppModel, day: String, notes: [ConversationNote]? = nil) {
        self.model = model
        self.day = day
        _notes = State(initialValue: notes.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) })
    }

    private var names: [NoteName] { model.library.names.filter { $0.day == day } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if staticRender {
                list.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
            } else {
                ScrollView { list }
            }
        }
        .background(Theme.paper)
        // Read again when a note lands on this day or one is deleted or cut.
        .task(id: [String(model.library.changes)] + names.map(\.id)) {
            let root = model.settings.conversationsURL, ids = names.map(\.id)
            let read = await Task.detached(priority: .userInitiated) {
                let store = NoteStore(root: root)
                var notes: [String: ConversationNote] = [:]
                for id in ids { notes[id] = try? store.read(url: root.appendingPathComponent(id + ".md")) }
                return notes
            }.value
            // A newer read (a note added or deleted meanwhile) has replaced this one.
            guard !Task.isCancelled else { return }
            notes = read
        }
    }

    /// "23rd of october · 6 conversations · 2h 14m".
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(DayGroups.longTitle(day, today: model.library.today)).font(Theme.body.weight(.medium))
            let count = names.count
            let total = notes.map { notes in names.reduce(0) { $0 + (notes[$1.id].map(Self.seconds) ?? 0) } }
            Theme.meta((count == 1 ? "1 conversation" : "\(count) conversations") + (total.map { " · " + DayGroups.duration($0) } ?? ""))
            Spacer()
        }
        .padding(.horizontal, Theme.pad)
        .frame(height: 44)
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let since = model.conversationStartedAt, NoteWriter.dayString(since) == day {
                row("\(NoteWriter.timeString(since, "HH:mm")) – now", speakers: "", length: "") {
                    Text("In a conversation").lineLimit(1)
                    Text("live")
                        .font(Theme.mono.weight(.medium))
                        .foregroundStyle(Theme.paper)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.ink))
                } open: {
                    model.selection = .now
                }
            }
            ForEach(names) { name in
                // Until it's read: the time and title from its file name.
                let note = notes?[name.id]
                row(
                    note.map { $0.end.isEmpty ? String($0.start.prefix(5)) : "\($0.start.prefix(5)) – \($0.end.prefix(5))" } ?? name.time,
                    speakers: note?.speakers.map(Theme.speakerName).joined(separator: ", ") ?? "",
                    length: note.map { DayGroups.duration(Self.seconds($0)) } ?? ""
                ) {
                    Text(note?.displayTitle ?? name.title).lineLimit(1)
                    if let why = note?.media {
                        Theme.meta("likely media").help("Probably a video or podcast this Mac played: \(why)")
                    } else if notes != nil, note == nil {
                        Theme.meta("couldn't be read")
                    }
                } open: {
                    model.selection = .conversation(name.id)
                }
            }
            if names.isEmpty { Text("No conversations on this day.").foregroundStyle(Theme.grey).padding(.vertical, 16) }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 6)
    }

    /// One conversation: "09:54 – 10:11   Call about the deck        speaker 1, speaker 2   17m", over a hairline.
    private func row<Title: View>(
        _ time: String, speakers: String, length: String, @ViewBuilder title: () -> Title, open: @escaping () -> Void
    ) -> some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Theme.meta(time).frame(width: 96, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 8) { title() }.layoutPriority(1)
                Spacer(minLength: 0)
                Theme.meta(speakers, keepCase: true)
                Theme.meta(length).frame(width: 52, alignment: .trailing)
            }
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// From its start to its end (one past midnight included).
    static func seconds(_ note: ConversationNote) -> Double {
        guard let start = note.startedAt, let end = note.endedAt else { return 0 }
        return end.timeIntervalSince(start)
    }
}

// MARK: one conversation

struct ConversationView: View {
    let model: AppModel
    let id: String
    @State private var note: ConversationNote?
    @State private var gone = false
    @State private var confirmDelete = false
    @Environment(\.staticRender) private var staticRender

    /// `note`: already read (headless renders, where `.task` never runs).
    init(model: AppModel, id: String, note: ConversationNote? = nil) {
        self.model = model
        self.id = id
        _note = State(initialValue: note)
    }

    var body: some View {
        Group {
            if let note {
                content(note)
            } else if gone {
                ContentUnavailableView("This conversation isn't there any more", systemImage: "doc.questionmark")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
        // Read again after a "delete the last N minutes" (it may have cut this one).
        .task(id: "\(id)#\(model.library.changes)") { load() }
    }

    private func load() {
        let root = model.settings.conversationsURL
        note = try? NoteStore(root: root).read(url: root.appendingPathComponent(id + ".md"))
        gone = note == nil
    }

    /// The day folder it's in, `2026-10-29`.
    private var day: String { String(id.prefix(10)) }

    private func content(_ note: ConversationNote) -> some View {
        VStack(spacing: 0) {
            bar(note)
            Hairline()
            if staticRender {
                page(note).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
            } else {
                ScrollView { page(note) }
            }
        }
        .confirmationDialog("Move this conversation to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { delete(note) }
        } message: {
            Text("The note and its word timings go to the Trash.")
        }
    }

    /// "23rd of october / Title": the day goes back to its list. Then what can be done with it.
    private func bar(_ note: ConversationNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    model.selection = .day(day)
                } label: {
                    Text(DayGroups.longTitle(day, today: model.library.today)).font(Theme.mono).foregroundStyle(Theme.grey)
                }
                Theme.meta("/")
                Text(note.displayTitle).font(Theme.body.weight(.medium)).lineLimit(1)
            }
            Spacer()
            Button("copy") { copy(note) }
            Button("show in finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
            Button("delete") { confirmDelete = true }
        }
        .buttonStyle(LinkButtonStyle())
        .padding(.horizontal, Theme.pad)
        .frame(height: 44)
    }

    private func page(_ note: ConversationNote) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(note.displayTitle).font(Theme.title).lineLimit(2)
                    if let why = note.media {
                        Theme.meta("likely media")
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Theme.hairline))
                            .help("Probably a video or podcast this Mac played: \(why)")
                    }
                }
                Theme.meta(subtitle(note))
            }
            .padding(.bottom, 8)
            ForEach(Array(note.lines.enumerated()), id: \.offset) { i, line in
                VStack(alignment: .leading, spacing: 3) {
                    if i == 0 || note.lines[i - 1].speaker != line.speaker {
                        HStack(spacing: 10) {
                            Theme.speaker(line.speaker)
                            Theme.meta(line.clock).opacity(0.7)
                        }
                    }
                    Theme.words(line.text)
                }
            }
            if note.lines.isEmpty { Text("No speech was transcribed.").foregroundStyle(Theme.grey) }
        }
        .padding(Theme.pad)
    }

    private func subtitle(_ note: ConversationNote) -> String {
        var parts: [String] = []
        let times = note.end.isEmpty ? String(note.start.prefix(5)) : "\(note.start.prefix(5))–\(note.end.prefix(5))"
        if !times.isEmpty { parts.append(times) }
        if !note.duration.isEmpty { parts.append(note.duration) }
        if !note.speakers.isEmpty { parts.append(note.speakers.count == 1 ? "1 speaker" : "\(note.speakers.count) speakers") }
        // The iPhone's and the watch's notes: which one, and where.
        if let device = note.recordedOn { parts.append(device) }
        if let place = note.placeText { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    private func copy(_ note: ConversationNote) {
        // The title the page shows (the AI title when it has one).
        let text = "# \(note.displayTitle)\n\n" + note.lines.map { "[\($0.clock)] \($0.speaker): \($0.text)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func delete(_ note: ConversationNote) {
        let urls = NoteStore.files(of: note.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        let model = model
        NSWorkspace.shared.recycle(urls) { _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error { Log.note("couldn't move a note to the Trash: \(Log.describe(error))") }
                    Log.note("conversation \(note.date)/\(note.start.prefix(5).replacingOccurrences(of: ":", with: "-")) moved to the Trash")
                    // Back to its day, unless that was the day's last one.
                    let day = String(note.id.prefix(10))
                    let more = model.library.names.contains { $0.day == day && $0.id != note.id }
                    model.selection = more ? .day(day) : .now
                    model.library.refresh(root: model.settings.conversationsURL)
                }
            }
        }
    }
}

// MARK: settings

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var mics: [InputDevice] = InputDevices.list()
    @State private var watch: InputDevices.Watch?
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        Group {
            if staticRender {
                // Headless: the same sections as cards in a stack, with drawn switches.
                VStack(alignment: .leading, spacing: 14) { sections }
                    .toggleStyle(DrawnSwitch())
                    .padding(Theme.pad)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Form { sections }.formStyle(.grouped).scrollContentBackground(.hidden)
            }
        }
        .background(Theme.paper)
        .buttonStyle(LinkButtonStyle())
        .onAppear {
            mics = InputDevices.list()
            watch = InputDevices.watch(queue: .main) {
                DispatchQueue.main.async { MainActor.assumeIsolated { mics = InputDevices.list() } }
            }
        }
        .onDisappear {
            if let watch { InputDevices.stopWatching(watch) }
            watch = nil
        }
    }

    @ViewBuilder private var sections: some View {
        SettingsSection {
            Toggle("Always-on recording", isOn: binding(\.alwaysOn))
            Text(
                model.settings.alwaysOn
                    ? "Listens all day and turns each conversation into a note with who said what."
                    : "Off: the microphone only opens while you hold the dictation key. Only the text you dictate is kept, in Dictations."
            )
            .font(Theme.small).foregroundStyle(Theme.grey)
        }
        SettingsSection {
            Toggle("Hold to dictate", isOn: binding(\.dictation))
            ShortcutField(model: model)
            if model.settings.dictation, !model.dictation.trusted {
                Button("allow accessibility (needed to see the key and paste)…") { SystemSettings.open("Privacy_Accessibility") }
            }
        }
        WordsSection(model: model)
        SettingsSection {
            Toggle("AI access (MCP)", isOn: binding(\.mcp))
            if model.settings.mcp {
                HStack {
                    Text(Self.mcpCommand)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.grey)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.mcpCommand, forType: .string)
                    }
                }
            } else {
                Text("AI apps get \"AI access is turned off\" and nothing else.").font(Theme.small).foregroundStyle(Theme.grey)
            }
        }
        SettingsSection {
            if staticRender {
                LabeledContent("Microphone") {
                    Text((model.settings.micUID.flatMap { uid in mics.first { $0.uid == uid }?.name } ?? "Automatic (never Bluetooth)") + "  ⌄")
                }
            } else {
                micPicker
            }
            Toggle("Label speakers", isOn: binding(\.speakers))
        }
        SettingsSection {
            Toggle("Hear this Mac's audio too", isOn: binding(\.macAudio)).disabled(!MacAudio.supported && !model.settings.macAudio)
            Text(
                MacAudio.supported
                    ? "Videos, calls, anything this Mac plays, as its own track labelled Mac audio, never as someone in the room. "
                        + "Only while something plays. macOS asks for System Audio Recording once."
                    : "Needs macOS 14.2 or later."
            )
            .font(Theme.small).foregroundStyle(Theme.grey)
            if model.settings.macAudio, case .problem(let why) = model.macAudio {
                Text(why).font(Theme.small).foregroundStyle(Theme.grey)
                Button("open system audio recording settings…") { SystemSettings.open("Privacy_AudioCapture") }
            }
        }
        SettingsSection {
            Toggle("Open at login", isOn: binding(\.launchAtLogin))
            LabeledContent("Notes folder") {
                HStack {
                    Text(model.settings.notesURL.path).font(Theme.mono).foregroundStyle(Theme.grey).lineLimit(1).truncationMode(.middle)
                    Button("choose…") { chooseFolder() }
                }
            }
            if let message = model.loginMessage { Text(message).font(Theme.small).foregroundStyle(Theme.grey) }
        }
        HStack {
            Text("Everything stays on this Mac.").font(Theme.small).foregroundStyle(Theme.grey)
            Spacer()
            Button("about sona") { model.selection = .about }
        }
    }

    private var micPicker: some View {
        Picker("Microphone", selection: binding(\.micUID)) {
            Text("Automatic (never Bluetooth)").tag(String?.none)
            ForEach(mics, id: \.uid) { mic in
                Text(mic.isBluetooth ? "\(mic.name) (Bluetooth: may switch AirPods to call quality)" : mic.name)
                    .tag(String?.some(mic.uid))
            }
            if let uid = model.settings.micUID, !mics.contains(where: { $0.uid == uid }) {
                Text("Not connected").tag(String?.some(uid))
            }
        }
    }

    /// The line that connects Claude Code to this copy's MCP server.
    static var mcpCommand: String {
        let server = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sona-mcp").path
        return "claude mcp add --scope user sona -- \(server)"
    }

    private func binding<T>(_ key: WritableKeyPath<NotesKit.Settings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: key] }, set: { value in model.update { $0[keyPath: key] = value } })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.settings.notesURL
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            model.update { $0.notesFolder = url.path }
        }
    }
}

/// A Form section in the window; a card in headless renders.
struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    @Environment(\.staticRender) private var staticRender

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if staticRender {
            VStack(alignment: .leading, spacing: 6) {
                if let title { Theme.meta(title).padding(.leading, 4) }
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebar))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            }
        } else if let title {
            Section { content } header: { Theme.meta(title) }
        } else {
            Section { content }
        }
    }
}

/// Settings → "Words it should know": what the model writes → how to write it, one line each. Edited as a draft
/// that's saved on Return, when the cursor leaves a field, or on leaving Settings, so a half-typed spelling never
/// changes anything.
struct WordsSection: View {
    let model: AppModel
    @State private var draft: [WordFix]
    /// The field being edited: line × 2, + 1 for "write".
    @FocusState private var focus: Int?
    @Environment(\.staticRender) private var staticRender

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settings.words)
    }

    var body: some View {
        SettingsSection("Words it should know") {
            ForEach(draft.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    field(i, \.heard, id: i * 2, prompt: "Sonar, Sonnar")
                    Image(systemName: "arrow.right").foregroundStyle(Theme.grey)
                    field(i, \.write, id: i * 2 + 1, prompt: "Sona")
                    Button {
                        if i < draft.count { draft.remove(at: i) }
                        save()
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Theme.grey)
                    }
                    .help("Remove")
                }
            }
            Button("add a word") {
                draft.append(WordFix(heard: "", write: ""))
                focus = (draft.count - 1) * 2
            }
            Text("When it hears what's on the left, it writes what's on the right, in dictation, the live transcript and new notes. Put spellings that mean the same word on one line, with commas.")
                .font(Theme.small).foregroundStyle(Theme.grey)
        }
        .onChange(of: focus) { save() }
        .onDisappear { save() }
    }

    private func save() {
        if draft != model.settings.words { model.update { $0.words = draft } }
    }

    @ViewBuilder private func field(_ i: Int, _ key: WritableKeyPath<WordFix, String>, id: Int, prompt: String) -> some View {
        // By index, and safe while a line is being removed.
        let text = Binding(
            get: { i < draft.count ? draft[i][keyPath: key] : "" },
            set: { value in if i < draft.count { draft[i][keyPath: key] = value } })
        Group {
            if staticRender {
                Text(text.wrappedValue.isEmpty ? prompt : text.wrappedValue)
                    .foregroundStyle(text.wrappedValue.isEmpty ? Theme.grey : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: text, prompt: Text(prompt))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($focus, equals: id)
                    .onSubmit { save() }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
    }
}

// MARK: dictations

/// What was pasted while always-on was off, by day, newest first. Text only: no audio was kept.
struct DictationsView: View {
    let model: AppModel
    @State private var days: [DictationDay]
    @Environment(\.staticRender) private var staticRender

    /// `days`: already read (headless renders, where `.task` never runs).
    init(model: AppModel, days: [DictationDay]? = nil) {
        self.model = model
        _days = State(initialValue: days ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dictations").font(Theme.title)
                    Text("What you dictated while always-on was off. Just the text, no audio.")
                        .font(Theme.small).foregroundStyle(Theme.grey)
                }
                Spacer()
                Button("show in finder") {
                    let folder = Dictations.folder(notes: model.settings.notesURL)
                    if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                .buttonStyle(LinkButtonStyle())
            }
            .padding(.horizontal, Theme.pad)
            .padding(.vertical, 16)
            Hairline()
            if staticRender {
                list.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
            } else {
                ScrollView { list }
            }
        }
        .background(Theme.paper)
        .task(id: model.library.dictationChanges) {
            let notes = model.settings.notesURL
            days = await Task.detached(priority: .userInitiated) { DictationDay.load(notes: notes) }.value
        }
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(days, id: \.day) { day in
                VStack(alignment: .leading, spacing: 12) {
                    Theme.meta(DayGroups.title(day.day, today: model.library.today))
                    ForEach(Array(day.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Theme.meta(String(entry.clock.prefix(5)))
                            Theme.words(entry.text)
                        }
                    }
                }
            }
            if days.isEmpty {
                Text("Nothing yet. Hold \(model.settings.dictationKey.title) in any app to dictate, and what's pasted shows up here.")
                    .foregroundStyle(Theme.grey)
            }
        }
        .padding(Theme.pad)
    }
}

// MARK: about

/// About Sona: the version, the promise, and whose work it runs on (the models and licences in
/// THIRD_PARTY.md; keep the two in step).
struct AboutView: View {
    @Environment(\.staticRender) private var staticRender

    private struct Credit {
        var name: String
        var by: String
        var does: String
        var licence: String
    }

    private static let credits = [
        Credit(
            name: "Parakeet Unified 0.6B", by: "NVIDIA", does: "the live transcript and dictation",
            licence: "NVIDIA Open Model License. Licensed by NVIDIA Corporation under the NVIDIA Open Model License."),
        Credit(name: "Nemotron 3 Diarization", by: "NVIDIA", does: "speakers in the live transcript", licence: "OpenMDW License 1.1"),
        Credit(name: "Parakeet TDT 0.6B v2 and v3", by: "NVIDIA", does: "the notes", licence: "CC-BY-4.0"),
        Credit(name: "pyannote speaker-diarization-community-1", by: "pyannote", does: "speakers in the notes", licence: "CC-BY-4.0"),
        Credit(name: "Silero VAD", by: "the Silero Team", does: "hearing when someone talks", licence: "MIT License"),
        Credit(name: "FluidAudio", by: "FluidInference", does: "running the models on this Mac", licence: "Apache License 2.0"),
    ]

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "Version \($0)" } ?? "Development build"
    }

    var body: some View {
        Group {
            if staticRender {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView { content }
            }
        }
        .background(Theme.paper)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sona").font(Theme.title)
                Theme.meta(version)
            }
            Text("Everything stays on this Mac.").fontWeight(.medium)
            Hairline()
            Theme.meta("built on")
            ForEach(Self.credits, id: \.name) { credit in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(credit.name), by \(credit.by), for \(credit.does).")
                    Text(credit.licence).font(Theme.small).foregroundStyle(Theme.grey)
                }
            }
            Text("The models are downloaded once from Hugging Face (FluidInference's Core ML versions) and aren't changed. Sona itself is open source, under the MIT License.")
                .font(Theme.small).foregroundStyle(Theme.grey)
            Button("show licence files") {
                if let folder = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
                    FileManager.default.fileExists(atPath: folder.path)
                {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            .buttonStyle(LinkButtonStyle())
        }
        .padding(Theme.pad + 4)
        .frame(maxWidth: 640, alignment: .leading)
    }
}
