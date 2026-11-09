import Foundation
import NotesKit
import SonaEngine

/// The app's one spool: the recorder writes recordings into it and the processor turns them into notes. There must be
/// exactly one `Spool` instance, because the recording in progress (`openID`) is only known in memory and the
/// processor skips it.
enum Services {
    static let spool = Spool(dir: Paths.spool)
}
