import Foundation

/// What a note's `source` says about where its audio came from. Nothing (the Mac's mic), the iPhone or the watch are
/// live recordings, made at the note's own time; anything else is an audio file someone ran through `sona file`.
public enum NoteSource {
    public static let iPhone = "iPhone"
    public static let watch = "Apple Watch"

    /// Recorded live, at the note's time (so "Delete the last N minutes" reaches it). An audio file isn't: its note's
    /// time is when it was transcribed, not when it was said.
    public static func isLive(_ source: String?) -> Bool { source == nil || source == iPhone || source == watch }

    /// Recorded on purpose on a device: never thrown away for having no words (the Mac's mic hears silence and noise all
    /// day; a note someone tapped to record is kept, its audio with it).
    public static func isDeliberate(_ source: String?) -> Bool { source == iPhone || source == watch }
}
