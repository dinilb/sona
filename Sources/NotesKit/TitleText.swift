import Foundation

/// What the iPhone (`PhoneTitles`) and the Mac (`MacTitles`) share to title a note with Apple's on-device model: the
/// instructions and prompt, the excerpt of the transcript it sees, and the check on what comes back. The model call
/// itself stays in each app, so NotesKit never imports FoundationModels. The result goes in a note's `ai_title`;
/// `title`, the heading and the file name keep the first-words title, and no file is ever renamed.
public enum TitleText {
    /// The session's instructions. Plain words and a plain String reply: permissive guardrails only apply to String
    /// output, and real conversations (money, health, swearing) would otherwise lose their titles at random.
    public static let instructions = """
        You write short titles for transcripts of voice notes and conversations. Reply with the title only: \
        2 to 6 plain words that say what it is about. No quotes, no full stop, no names of speakers, no emoji.
        """

    /// About 1,500 to 2,000 tokens of transcript: well inside the model's 4,096-token window with the instructions
    /// and the reply.
    public static let excerptBudget = 6_000

    /// The longest title kept, in words and characters. Anything longer is the model rambling, not a title.
    public static let maxWords = 8
    public static let maxCharacters = 60

    /// The prompt for one note, or nil if it has no words to title.
    public static func prompt(for note: ConversationNote, budget: Int = excerptBudget) -> String? {
        let words = transcript(of: note)
        guard !words.isEmpty else { return nil }
        return prompt(excerpt: excerpt(words, budget: budget))
    }

    public static func prompt(excerpt: String) -> String {
        "Title this transcript in 2 to 6 words.\n\nTranscript:\n\(excerpt)"
    }

    /// The transcript's words, line after line, without times or speaker labels (they'd only cost tokens and end up
    /// in the title).
    public static func transcript(of note: ConversationNote) -> String {
        note.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// At most about `budget` characters of `text`: all of it when it fits, else its start (half the budget), its
    /// middle (a quarter) and its end (a quarter), so a long note's title sees the whole arc. Cuts fall on spaces
    /// where there is one nearby, so no word is cut in half.
    public static func excerpt(_ text: String, budget: Int = excerptBudget) -> String {
        guard text.count > budget, budget >= 8 else { return text }
        let chars = Array(text)
        let head = budget / 2, part = budget / 4
        let middleStart = max(head, chars.count / 2 - part / 2)
        let pieces = [0..<head, middleStart..<min(chars.count, middleStart + part), (chars.count - part)..<chars.count]
        return pieces.map { whole(chars, $0) }.joined(separator: "\n...\n")
    }

    /// `range` of `chars` with a word cut in half at either edge dropped (only if a space is near: a run with no
    /// spaces stays as it is).
    private static func whole(_ chars: [Character], _ range: Range<Int>) -> String {
        var piece = chars[range]
        let near = 30
        let cutAtStart = range.lowerBound > 0 && !chars[range.lowerBound - 1].isWhitespace
        if cutAtStart, let space = piece.prefix(near).firstIndex(where: \.isWhitespace) {
            piece = piece[piece.index(after: space)...]
        }
        let cutAtEnd = range.upperBound < chars.count && !chars[range.upperBound].isWhitespace
        if cutAtEnd, let space = piece.suffix(near).lastIndex(where: \.isWhitespace) {
            piece = piece[..<space]
        }
        return String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title in what the model replied, or nil if it isn't one: empty, a refusal or an apology (it comes back as
    /// text, not an error), or too long. Quotes, a "Title:" prefix, markdown and a full stop are taken off.
    public static func check(_ reply: String) -> String? {
        var title = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        for prefix in ["title:", "**title:**", "title -"] where title.lowercased().hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        let edges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’`*#_.:"))
        title = title.trimmingCharacters(in: edges)
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty, title.count <= maxCharacters,
            title.split(separator: " ").count <= maxWords, !isRefusal(title)
        else { return nil }
        return title
    }

    /// The model's ways of saying no, or of talking about the task instead of doing it.
    static func isRefusal(_ title: String) -> Bool {
        let lower = title.lowercased()
        let starts = [
            "sorry", "i'm sorry", "i am sorry", "i can't", "i cannot", "i can not", "i'm unable", "i am unable",
            "i won't", "unfortunately", "as an ai", "i apologize", "i'm not able", "i am not able", "here is a",
            "here's a", "the transcript", "this transcript", "the conversation is", "this conversation is",
        ]
        if starts.contains(where: { lower.hasPrefix($0) }) { return true }
        // A reply that says there's no title isn't one: the first-words title says more.
        if ["untitled", "no title", "n/a", "none"].contains(lower) { return true }
        let anywhere = ["can't help", "cannot help", "can't assist", "cannot assist", "not able to help"]
        return anywhere.contains { lower.contains($0) }
    }

    /// True for a value the iPhone can take as an `ai_title`: one `check` would keep, unchanged. What comes from the
    /// Mac (through iCloud) is checked again before it's written into a note.
    public static func isAcceptable(_ title: String) -> Bool { check(title) == title }
}

/// The Mac's titles for the iPhone's notes, one file per day: `<root>/Titles/YYYY-MM-DD.json`, beside
/// `<root>/Conversations`. The Mac writes it (`MacTitles`) for notes the iPhone couldn't title (no Apple Intelligence
/// there); the iPhone folds each title into its note's `ai_title` (it's the only one that writes its notes) and leaves
/// the file, until it deletes the note (`removeTitle`). Keys are note file names without `.md`.
public struct TitlesFile: Codable, Equatable, Sendable {
    public var version: Int
    public var titles: [String: String]

    public static let currentVersion = 1
    public static let folderName = "Titles"

    public init(titles: [String: String] = [:]) {
        self.version = Self.currentVersion
        self.titles = titles
    }

    /// `<root>/Titles`, for the notes in `<root>/Conversations`.
    public static func folder(forConversations conversations: URL) -> URL {
        conversations.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    }

    /// The file for one day (`YYYY-MM-DD`).
    public static func url(forConversations conversations: URL, day: String) -> URL {
        folder(forConversations: conversations).appendingPathComponent("\(day).json")
    }

    /// The file's titles; nil if it isn't one this version reads.
    public static func decode(_ data: Data) -> TitlesFile? {
        guard let file = try? JSONDecoder().decode(TitlesFile.self, from: data), file.version == currentVersion else {
            return nil
        }
        return file
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Takes a deleted note's title out of its day's file (`<root>/Titles/<day>.json` for the note at
    /// `<root>/Conversations/<day>/<stem>.md`): the title was made from the note's words, so it goes with the note. One
    /// coordinated read and write, since the file is in iCloud Drive and the Mac may be writing it (the Mac only
    /// titles notes that are there, so it won't put it back). A file left with no titles goes too. Nothing happens
    /// when there's no file, the note has no title in it, or it's a version this one doesn't read. Returns whether a
    /// title went. Blocking: call it off the main thread.
    @discardableResult
    public static func removeTitle(ofNote note: URL) throws -> Bool {
        let fm = FileManager.default
        let dayFolder = note.deletingLastPathComponent()
        let stem = note.deletingPathExtension().lastPathComponent
        let file = url(forConversations: dayFolder.deletingLastPathComponent(), day: dayFolder.lastPathComponent)
        let stub = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
        guard fm.fileExists(atPath: file.path) || fm.fileExists(atPath: stub.path) else { return false }
        var coordination: NSError?
        var failure: Error?
        var removed = false
        // Reading too: a coordinated read waits for a file iCloud hasn't downloaded to this device yet.
        NSFileCoordinator().coordinate(
            readingItemAt: file, options: [], writingItemAt: file, options: .forMerging, error: &coordination
        ) { _, url in
            guard let data = try? Data(contentsOf: url), var titles = decode(data),
                titles.titles.removeValue(forKey: stem) != nil
            else { return }
            do {
                if titles.titles.isEmpty {
                    try fm.removeItem(at: url)
                } else {
                    try titles.encoded().write(to: url, options: .atomic)
                }
                removed = true
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
        return removed
    }
}
