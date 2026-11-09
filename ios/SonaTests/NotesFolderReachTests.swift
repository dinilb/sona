import Foundation
import Testing
@testable import Sona

/// A picked folder the Mac doesn't import from gets a warning instead of silence.
struct NotesFolderReachTests {
    let cloudDocs = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs"

    @Test func iCloudDriveSonaReachesTheMac() {
        #expect(NotesLocation.isICloudDriveSona(URL(fileURLWithPath: cloudDocs + "/Sona")))
        #expect(NotesLocation.isICloudDriveSona(URL(fileURLWithPath: cloudDocs + "/sona/")))
    }

    @Test func otherFoldersDoNot() {
        #expect(!NotesLocation.isICloudDriveSona(URL(fileURLWithPath: cloudDocs + "/Notes")))
        #expect(!NotesLocation.isICloudDriveSona(URL(fileURLWithPath: cloudDocs + "/Work/Sona")))
        #expect(!NotesLocation.isICloudDriveSona(URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/X/File Provider Storage/Sona")))
    }

    @Test func theKindDecidesTheRest() {
        let local = NotesLocation(kind: .local, folder: URL(fileURLWithPath: "/tmp/Sona"))
        let picked = NotesLocation(kind: .picked, folder: URL(fileURLWithPath: cloudDocs + "/Sona"))
        #expect(!local.reachesMac)
        #expect(picked.reachesMac)
    }
}
