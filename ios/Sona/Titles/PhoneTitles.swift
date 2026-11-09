import Foundation
import FoundationModels
import NotesKit

/// Titles from Apple's on-device model (Foundation Models), written as a note's `ai_title`. `title:`, the `# `
/// heading and the file name keep the first-words title, and no file is ever renamed (the Mac's import keys notes by
/// file name). Only on iPhones with Apple Intelligence on (iPhone 15 Pro and newer): elsewhere the Mac titles the
/// notes (`TitlesFile`) and this folds its titles in. Never logs a title or what was said.
enum PhoneTitles {
    /// How far back a foreground looks for notes still without a title (one a background task couldn't title).
    nonisolated static let retryDays = 3
    /// How far back the Mac's titles are folded in.
    nonisolated static let foldDays = 30
    /// The notes a foreground already tried again, so a note the model won't title isn't tried on every foreground:
    /// one try when it's written, one more on a foreground, then it keeps its first-words title. Each by its day and
    /// start minute ("2026-11-06/09-05", `key`), never its file name: that's its first words, and UserDefaults is
    /// backed up and outlives the note.
    nonisolated static let retriedKey = "titlesRetried"
    nonisolated static let retriedKept = 300

    /// Titles a note just written, before it moves to the notes folder (iCloud and the Mac only see it titled).
    /// In the background the model may be rate-limited: then the note gets its retry on the next foreground.
    static func apply(toNote note: URL) async {
        guard isAvailable else { return }
        await title(note)
    }

    /// On each foreground: the Mac's titles folded into notes with none, then another try for recent notes with no
    /// title yet.
    static func foreground(conversations: URL) async {
        let folded = await Task.detached(priority: .utility) { () -> Int in
            tidyRetried()
            return foldMacTitles(conversations: conversations)
        }.value
        if folded > 0 { Log.note("titles: \(folded) title(s) from the Mac") }
        guard isAvailable else { return }
        let missing = await Task.detached(priority: .utility) { untitled(in: conversations) }.value
        for note in missing {
            markRetried(note)
            await title(note)
        }
    }

    /// The model can run here now. Asked each time: Apple Intelligence can be switched on or off, and the model
    /// may still be downloading.
    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    // MARK: The model

    /// Reads the note, asks for a title, and writes it as `ai_title`. A note with one already, no words, or a reply
    /// that isn't a title is left as it is.
    private static func title(_ note: URL) async {
        let read = await Task.detached(priority: .utility) { () -> ConversationNote? in
            try? NoteStore(root: note.deletingLastPathComponent()).read(url: note)
        }.value
        guard let read, read.aiTitle == nil, let title = await generateWithin(timeLimit, for: read) else { return }
        do {
            try await Task.detached(priority: .utility) { try NoteFiles.updateFrontMatter(note, set: ["ai_title": title]) }.value
        } catch {
            Log.note("titles: couldn't write a title: \(Log.describe(error))")
        }
    }

    /// A new note waits for its title before it moves, so the model gets this long at most; then the note keeps its
    /// first-words title (and gets its one retry on a foreground).
    static let timeLimit: Duration = .seconds(10)

    /// `generate`, or nil if it takes longer than `limit` (it's cancelled then).
    private static func generateWithin(_ limit: Duration, for note: ConversationNote) async -> String? {
        await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { await generate(for: note) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Permissive guardrails (they only apply to plain String output), greedy sampling so a title doesn't change
    /// from one try to the next, and a fresh session per try. nil for a refusal, a reply that's too long or empty,
    /// or an error.
    private static func generate(for note: ConversationNote) async -> String? {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard model.availability == .available else { return nil }
        // Once more with half the excerpt, in a fresh session, if the first try failed (a session that ran out of
        // room can't answer again).
        for budget in [TitleText.excerptBudget, TitleText.excerptBudget / 2] {
            guard let prompt = TitleText.prompt(for: note, budget: budget) else { return nil }
            let session = LanguageModelSession(model: model, instructions: TitleText.instructions)
            do {
                let reply = try await session.respond(
                    to: prompt, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24))
                return TitleText.check(reply.content)
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: Files (off the main thread)

    /// Recent notes (the last `retryDays` days) with no `ai_title` that no foreground has tried again yet, newest
    /// first.
    nonisolated static func untitled(
        in conversations: URL, today: Date = Date(), defaults: UserDefaults = .standard
    ) -> [URL] {
        let store = NoteStore(root: conversations)
        let since = dayString(today.addingTimeInterval(-Double(retryDays) * 86_400))
        let retried = Set(defaults.stringArray(forKey: retriedKey) ?? [])
        // A name with no start time can't be remembered as tried, so it never gets the foreground retry.
        return store.headers(from: since).reversed()
            .filter { header in header.aiTitle == nil && key(header.url).map { !retried.contains($0) } ?? false }
            .map(\.url)
    }

    nonisolated static func markRetried(_ note: URL, defaults: UserDefaults = .standard) {
        guard let id = key(note) else { return }
        var retried = (defaults.stringArray(forKey: retriedKey) ?? []).filter(isKey)
        if !retried.contains(id) { retried.append(id) }
        defaults.set(Array(retried.suffix(retriedKept)), forKey: retriedKey)
    }

    /// Drops the entries an earlier build kept by file name (they held a note's first words), once.
    nonisolated static func tidyRetried(defaults: UserDefaults = .standard) {
        let stored = defaults.stringArray(forKey: retriedKey) ?? []
        let kept = stored.filter(isKey)
        if kept != stored { defaults.set(kept, forKey: retriedKey) }
    }

    /// Folds the Mac's titles (`<root>/Titles/<day>.json`) into the notes in `conversations` that have no
    /// `ai_title`, in coordinated writes: this iPhone is the only one that writes its notes. A title that doesn't pass
    /// `TitleText.check` as it is, or a key that isn't a plain file name, is skipped. Returns how many it wrote.
    nonisolated static func foldMacTitles(conversations: URL, today: Date = Date()) -> Int {
        let fm = FileManager.default
        let folder = TitlesFile.folder(forConversations: conversations)
        let since = dayString(today.addingTimeInterval(-Double(foldDays) * 86_400))
        let store = NoteStore(root: conversations)
        var folded = 0
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            // Not downloaded from iCloud yet: ask for it, and fold it in next time.
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                try? fm.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
                continue
            }
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            let day = String(name.dropLast(".json".count))
            guard isDay(day), day >= since, let file = readTitles(folder.appendingPathComponent(name)) else { continue }
            for (stem, title) in file.titles where isPlainName(stem) && TitleText.isAcceptable(title) {
                let note = conversations.appendingPathComponent(day, isDirectory: true).appendingPathComponent("\(stem).md")
                guard fm.fileExists(atPath: note.path), let header = try? store.readHeader(url: note), header.aiTitle == nil
                else { continue }
                do {
                    try NoteFiles.updateFrontMatter(note, set: ["ai_title": title])
                    folded += 1
                } catch {
                    Log.note("titles: couldn't fold in a title from the Mac: \(Log.describe(error))")
                }
            }
        }
        return folded
    }

    /// A coordinated read: the Mac may be writing it through iCloud.
    private nonisolated static func readTitles(_ url: URL) -> TitlesFile? {
        var coordination: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            data = try? Data(contentsOf: url)
        }
        return data.flatMap(TitlesFile.decode)
    }

    /// "2026-11-06/09-05" for `<...>/2026-11-06/09-05 Title.md`: the same note wherever the notes folder is, without
    /// its words. Nil for a name that doesn't start with a time. Two notes started in the same minute share it, so
    /// the second may miss its foreground retry: it keeps its first-words title.
    nonisolated static func key(_ note: URL) -> String? {
        let day = note.deletingLastPathComponent().lastPathComponent
        let id = "\(day)/\(note.deletingPathExtension().lastPathComponent.prefix(5))"
        return isKey(id) ? id : nil
    }

    private nonisolated static func isKey(_ id: String) -> Bool {
        id.range(of: #"^\d{4}-\d{2}-\d{2}/\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private nonisolated static func dayString(_ date: Date) -> String { NoteWriter.timeString(date, "yyyy-MM-dd") }

    private nonisolated static func isDay(_ name: String) -> Bool {
        name.count == 10 && name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// A note's file name without `.md`: never a path, a hidden file or empty, whatever the file says.
    private nonisolated static func isPlainName(_ stem: String) -> Bool {
        !stem.isEmpty && !stem.hasPrefix(".") && !stem.contains("/") && !stem.contains("\0")
    }
}
