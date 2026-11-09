import Foundation

/// The small text rules of dictation that don't need the screen, kept here so they can be tested.
public enum DictationText {
    /// Does a dictation need a space in front when it's pasted at the caret? Without one, two dictations in a row
    /// run together ("opened the lid.Yeah, it shows up").
    ///
    /// `before` is the character just before the caret, or nil when the field can't say (many Electron apps and
    /// terminals hide their text). With a character: a space unless it's already whitespace or an opening bracket or
    /// quote, where the words belong right up against it. Without one, the best guess is that the last dictation went
    /// to this same app a moment ago (`sameAppRecently`), so the new words follow it.
    ///
    /// A capital stays a capital after a comma or a letter: the words are pasted as they were said, never re-cased.
    public static func leadingSpace(before: Character?, sameAppRecently: Bool) -> Bool {
        guard let before else { return sameAppRecently }
        if before.isWhitespace || straightOpeners.contains(before) { return false }
        // ( [ { and the curly and angle opening quotes. Closing ones (” ’ ») get a space like any other mark.
        if let category = before.unicodeScalars.first?.properties.generalCategory,
            category == .openPunctuation || category == .initialPunctuation
        {
            return false
        }
        return true
    }

    /// Straight quotes can't be told apart as opening or closing: they count as opening (the words go inside them).
    private static let straightOpeners: Set<Character> = ["\"", "'", "<", "¿", "¡"]

    // MARK: is there a text box to paste into?

    /// What Accessibility says is focused.
    public enum Focus: Equatable, Sendable {
        /// Nothing: the desktop, or an app with no window in focus.
        case nothing
        /// It wouldn't say (no access, an error, an app that doesn't answer).
        case unreadable
        /// An element. `role` is its AX role (nil if unreadable); `editable` is its AXEditable; `settableText` is that
        /// its text or its selection can be set.
        case element(role: String?, editable: Bool, settableText: Bool)
    }

    public enum PasteTarget: Equatable, Sendable {
        /// A text box: paste, and put the old clipboard back.
        case textBox
        /// Clearly not text (a button, a list): a paste would land nowhere, so the words are left on the clipboard.
        case noTextBox
        /// Can't tell: paste anyway, and leave the words on the clipboard in case it went nowhere.
        case unknown
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Roles that are never a place to type. A short list on purpose: a wrong "no text box" loses the paste, a wrong
    /// "can't tell" only keeps the clipboard. AXWindow and AXApplication aren't here: Electron and other Chromium apps
    /// that hide their text from Accessibility can answer with the window. Cells and rows aren't either (a selected
    /// spreadsheet cell takes a paste).
    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenu", "AXMenuBar",
        "AXMenuBarItem", "AXList", "AXOutline", "AXSlider", "AXTabGroup", "AXToolbar", "AXScrollBar", "AXDisclosureTriangle",
        "AXIncrementor", "AXColorWell", "AXDockItem",
    ]

    /// Where a paste would go, from what Accessibility says is focused. A text role, or an element that's editable,
    /// takes text; a button, list or menu doesn't, even though a checkbox's value can be set; anything else takes text
    /// only if its text or selection can be set, and otherwise we can't tell.
    public static func pasteTarget(for focus: Focus) -> PasteTarget {
        switch focus {
        case .nothing: return .noTextBox
        case .unreadable: return .unknown
        case .element(let role, let editable, let settableText):
            if let role, textRoles.contains(role) { return .textBox }
            if editable { return .textBox }
            if let role, nonTextRoles.contains(role) { return .noTextBox }
            return settableText ? .textBox : .unknown
        }
    }

    // MARK: the pill's line

    /// The latest words of `text` that `fits` the pill's one line: all of it if it fits, else the end of it, cut at a
    /// word boundary with "…" in front, so the line scrolls as the person talks. `fits` measures a string with the
    /// pill's font and width. The last word is always kept, however long.
    public static func tail(of text: String, fits: (String) -> Bool) -> String {
        if fits(text) { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > 1 else { return text }
        func from(_ first: Int) -> String { "…" + words[first...].joined(separator: " ") }
        // The fewest words cut off that still fits (fewer words is never wider, so this is a binary search).
        var low = 1
        var high = words.count - 1
        while low < high {
            let middle = (low + high) / 2
            if fits(from(middle)) { high = middle } else { low = middle + 1 }
        }
        return from(low)
    }

    /// How many words a string has (the log says how many the pill showed, never which).
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: the end of a hold

    /// Was it already quiet when the key came up? `samples` is the last moment before the release (and whatever came
    /// in after it): quiet when every 20 ms of it (`piece`) is below `floor` RMS. Judged in short pieces because a word
    /// still going at the very end is loud in its last piece even when the whole stretch averages quiet. No audio
    /// can't be told apart from speech, so it isn't quiet.
    public static func endsQuiet(_ samples: [Float], floor: Float, piece: Int = 320) -> Bool {
        guard !samples.isEmpty, piece > 0 else { return false }
        var start = 0
        while start < samples.count {
            let end = min(start + piece, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            if (sum / Float(end - start)).squareRoot() >= floor { return false }
            start = end
        }
        return true
    }

    // MARK: the clipboard around a paste

    /// The markers clipboard and password managers put on what they copy (nspasteboard.org's transient, concealed and
    /// auto-generated types, and 1Password's own): kept when the clipboard is saved for after a paste, so a restored
    /// password stays hidden from clipboard history and its manager can still clear it.
    public static func isClipboardMarker(_ type: String) -> Bool {
        type.hasPrefix("org.nspasteboard.") || type == onePasswordType
    }

    /// The clipboard holds a secret (a password manager's copy): it's never put back after a paste.
    public static func isSecret(clipboardTypes types: [String]) -> Bool {
        types.contains { $0 == "org.nspasteboard.ConcealedType" || $0 == onePasswordType }
    }

    static let onePasswordType = "com.agilebits.onepassword"
}
