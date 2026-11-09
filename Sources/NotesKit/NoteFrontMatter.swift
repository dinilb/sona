import Foundation

/// Sets and removes flat `key: value` lines in a note's front matter, for what's added to a note after it's written
/// (its AI title, its place, Keep audio). The rest of the note stays exactly as it is, so old readers, the Mac's
/// import and "delete the last N minutes" see the same note with a few more lines.
public enum NoteFrontMatter {
    /// Keys whose values are written as they are (`true`, `-27.4698,153.0251`); every other value is quoted, like
    /// `title`.
    static let rawKeys: Set<String> = ["keep_audio", "geo", "geo_end", "media"]

    /// The order new keys go in, then any others by name.
    static let order = ["ai_title", "place", "geo", "place_end", "geo_end", "keep_audio"]

    /// `text` with each key in `set` given its value: its line replaced where it is, or added just before the `tags:`
    /// line (at the end of the front matter without one). A key set to nil is removed. Everything from the closing
    /// `---` on stays byte for byte. A note without front matter comes back unchanged, and so does one where nothing
    /// changes. Keys are flat names like `ai_title`: anything else is ignored. A value is kept to one line.
    public static func update(_ text: String, set changes: [String: String?]) -> String {
        guard let front = split(text) else { return text }
        let changes = changes.filter { isKey($0.key) }
        var out: [String] = []
        var seen: Set<String> = []
        for raw in front.lines {
            guard let name = key(of: raw), let change = changes[name] else {
                out.append(String(raw))
                continue
            }
            // The first line with the key gets the value; any later one goes (the reader keeps the last, which would
            // win otherwise).
            if let value = change, !seen.contains(name) { out.append(line(name, value)) }
            seen.insert(name)
        }
        let added = changes.compactMap { name, value in value.map { (name, $0) } }
            .filter { !seen.contains($0.0) }
            .sorted { (rank($0.0), $0.0) < (rank($1.0), $1.0) }
            .map { line($0.0, $0.1) }
        let at = out.firstIndex(where: { key(of: $0) == "tags" }) ?? out.endIndex
        out.insert(contentsOf: added, at: at)
        return "---\n" + out.joined(separator: "\n") + front.rest
    }

    /// The same, on the note at `url`: written atomically (a temp file renamed over it), with the file's permissions.
    /// A note without front matter, or with nothing to change, isn't touched. Throws if it can't be read (one that
    /// isn't UTF-8 included) or written.
    public static func update(fileAt url: URL, set changes: [String: String?]) throws {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        // Only UTF-8 comes back byte for byte: anything else is left alone.
        guard Data(text.utf8) == data else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        let new = Data(update(text, set: changes).utf8)
        guard new != data else { return }
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw NoteWriter.posixError() }
        let tmp = try NoteWriter.privateTemp(new, for: url)
        do {
            guard chmod(tmp.path, st.st_mode & 0o7777) == 0 else { throw NoteWriter.posixError() }
            try NoteWriter.move(tmp, to: url)
        } catch {
            unlink(tmp.path)
            throw error
        }
    }

    /// The front matter's lines, and everything from its closing `---` on, found as NoteStore finds them; nil without
    /// front matter.
    static func split(_ text: String) -> (lines: [Substring], rest: Substring)? {
        guard text.hasPrefix("---\n") else { return nil }
        let open = text.index(text.startIndex, offsetBy: 4)
        guard let close = text.range(of: "\n---", range: open..<text.endIndex) else { return nil }
        return (text[open..<close.lowerBound].split(separator: "\n", omittingEmptySubsequences: false), text[close.lowerBound...])
    }

    /// A front-matter line's key as NoteStore reads it: what's before the first colon, trimmed. Nil without a colon.
    static func key<S: StringProtocol>(of line: S) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return line[..<colon].trimmingCharacters(in: .whitespaces)
    }

    /// `key: "value"`, or `key: value` for a raw key. A line break would end the value early or start another key, so
    /// any becomes a space.
    static func line(_ key: String, _ value: String) -> String {
        let flat = value.components(separatedBy: .newlines).joined(separator: " ")
        return "\(key): \(rawKeys.contains(key) ? flat : NoteWriter.yamlString(flat))"
    }

    /// ASCII letters, digits and `_`: a name that can't break its line or, as `---`, end the front matter.
    static func isKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }

    private static func rank(_ key: String) -> Int { order.firstIndex(of: key) ?? order.count }
}
