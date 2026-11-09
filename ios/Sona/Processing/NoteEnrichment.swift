import Foundation

/// What a note gets after it's written: where it was recorded (`PlaceStamps`) and a title from Apple's on-device model
/// (`PhoneTitles`). NotesService calls these; the places and titles lanes fill in what they call.
enum NoteEnrichment {
    /// A note just written for the recording `recordingID`, still on this iPhone: iCloud and the Mac only ever see it
    /// with its place and title.
    static func newNote(_ note: URL, recordingID: String) async {
        await PlaceStamps.shared.apply(toNote: note, recordingID: recordingID)
        await PhoneTitles.apply(toNote: note)
    }

    /// On launch and each return to the foreground: what notes in `conversations` missed (a place not looked up yet, a
    /// title the charging task couldn't make).
    static func foreground(conversations: URL) async {
        await PlaceStamps.shared.fillIn(conversations: conversations)
        await PhoneTitles.foreground(conversations: conversations)
    }
}
