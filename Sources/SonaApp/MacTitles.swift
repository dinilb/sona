import Foundation
import NotesKit
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Titles the iPhone's notes for iPhones that can't (no Apple Intelligence there), with this Mac's on-device model
/// (`SystemLanguageModel.default`, never Private Cloud Compute). After each import pass it looks in the iPhone's
/// folders (the app's iCloud container and iCloud Drive/Sona) for recent notes with no `ai_title`, titles them one at
/// a time, and writes `<root>/Titles/YYYY-MM-DD.json` beside `<root>/Conversations` (`TitlesFile`). It never edits a
/// note there: the iPhone folds the titles in, and the import brings the titled note back here. This Mac's own copy
/// gets the title at once (`PhoneImport.addTitle`), since the iPhone only folds titles in while Sona is open there.
///
/// FoundationModels is weak-linked (Package.swift): before macOS 26, or without Apple Intelligence, this does nothing
/// and the app still launches on macOS 14.
enum MacTitles {
    /// Notes titled in one pass at most (each takes a second or so), so a pass never runs long.
    static let perPass = 10
    /// How far back it looks, in days: older notes keep their first-words title.
    static let recentDays = 14
    /// Notes the model couldn't title in this launch (an error or no title in its reply): not tried again until the
    /// app starts again.
    private static let tried = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// One pass over `sources` (each a `Conversations` folder). `macConversations`: this Mac's notes folder, where
    /// the import put its copies (nil leaves them as they are). Returns how many notes it titled. Never throws and
    /// never logs a title, a file name or what was said: only counts.
    @discardableResult
    static func run(
        sources: [URL] = PhoneImport.defaultSources, macConversations: URL? = nil,
        statePath: URL = PhoneImport.defaultStatePath, today: Date = Date()
    ) async -> Int {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return 0 }
        guard SystemLanguageModel.default.availability == .available else { return 0 }
        let since = NoteWriter.timeString(today.addingTimeInterval(-Double(recentDays) * 86_400), "yyyy-MM-dd")
        var left = perPass
        var titled = 0
        for conversations in sources where isFolder(conversations) {
            let store = NoteStore(root: conversations)
            for day in store.days(from: since).reversed() where left > 0 {
                var file = load(TitlesFile.url(forConversations: conversations, day: day))
                var new: [String: String] = [:]
                for header in store.headers(from: day, to: day).reversed() where header.aiTitle == nil && left > 0 {
                    let stem = header.url.deletingPathExtension().lastPathComponent
                    guard file.titles[stem] == nil, tried.withLock({ $0.insert(header.url.path).inserted }) else {
                        continue
                    }
                    left -= 1
                    guard let note = try? store.read(url: header.url), let title = await title(for: note) else { continue }
                    new[stem] = title
                    file.titles[stem] = title
                }
                if !new.isEmpty, save(new, to: TitlesFile.url(forConversations: conversations, day: day)) {
                    titled += new.count
                    // Into this Mac's untouched copies too, so its lists show the title before the iPhone folds it in.
                    if let macConversations {
                        for (stem, title) in new {
                            PhoneImport.addTitle(title, day: day, stem: stem, to: macConversations, statePath: statePath)
                        }
                    }
                }
            }
        }
        if titled > 0 { Log.note("titles: \(titled) iPhone note(s) titled on this Mac") }
        return titled
        #else
        return 0
        #endif
    }

    #if canImport(FoundationModels)
    /// The model's title for the note, checked; nil when there's none (no words, a refusal, an error).
    @available(macOS 26.0, *)
    private static func title(for note: ConversationNote) async -> String? {
        // A smaller excerpt once, in a fresh session, if the first try failed (a session that ran out of room can't
        // answer again). Not for a transcript that already fits the smaller one: it would only ask the same again.
        let fitsSmaller = TitleText.transcript(of: note).count <= TitleText.excerptBudget / 2
        for budget in fitsSmaller ? [TitleText.excerptBudget] : [TitleText.excerptBudget, TitleText.excerptBudget / 2] {
            guard let prompt = TitleText.prompt(for: note, budget: budget) else { return nil }
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: TitleText.instructions)
            do {
                // The argument was renamed from `sampling:` to `samplingMode:` in the newer SDK (Swift 6.4); CI builds with 6.3.
                #if compiler(>=6.4)
                let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24)
                #else
                let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 24)
                #endif
                let reply = try await session.respond(to: prompt, options: options)
                return TitleText.check(reply.content)
            } catch {
                continue
            }
        }
        return nil
    }
    #endif

    private static func load(_ url: URL) -> TitlesFile {
        (try? Data(contentsOf: url)).flatMap(TitlesFile.decode) ?? TitlesFile()
    }

    /// Adds `titles` to the day's file, keeping what's there, in one coordinated write (it's in iCloud Drive).
    private static func save(_ titles: [String: String], to url: URL) -> Bool {
        var coordination: NSError?
        var saved = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordination) { url in
            var file = load(url)
            file.titles.merge(titles) { _, new in new }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.encoded().write(to: url, options: .atomic)
                saved = true
            } catch {
                Log.note("titles: couldn't save a titles file: \(Log.describe(error))")
            }
        }
        if let coordination { Log.note("titles: couldn't save a titles file: \(Log.describe(coordination))") }
        return saved
    }

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }
}
