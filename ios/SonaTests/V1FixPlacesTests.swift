import CoreLocation
import Foundation
import Testing
@testable import Sona

/// Street names found later (`PlaceStamps.fillIn`): only for notes that are still there, and only while location is
/// allowed. No geocoder here (`looksUpNames: false`): `lookupsAsked` counts what would have gone to it, and every
/// name waits for "later".
@MainActor
struct V1FixPlacesFillInTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("places-fix-\(UUID().uuidString)", isDirectory: true)
    let start = PlaceFix(latitude: -27.469812, longitude: 153.025123, accuracy: 10, at: Date(timeIntervalSince1970: 1_793_000_000), precise: true)
    let relative = "2026-11-07/14-03 Budget.md"

    var store: PlaceStore { PlaceStore(folder: folder.appendingPathComponent("Places", isDirectory: true)) }
    var conversations: URL { folder.appendingPathComponent("Conversations", isDirectory: true) }

    func places(_ permission: CLAuthorizationStatus = .authorizedWhenInUse) -> PlaceStamps {
        PlaceStamps(
            store: store, defaults: UserDefaults(suiteName: "places-\(UUID().uuidString)")!, watchesPermission: false,
            looksUpNames: false, permission: permission)
    }

    /// A record whose note still waits for its street name, last saved `daysAgo` days ago.
    @discardableResult
    func waitingRecord(_ id: String, daysAgo: Double) throws -> Date {
        store.update(id) {
            $0.start = start
            $0.applied = true
            $0.unnamed = [relative]
        }
        let savedAt = Date().addingTimeInterval(-daysAgo * 86_400)
        try FileManager.default.setAttributes([.modificationDate: savedAt], ofItemAtPath: store.url(id).path)
        return savedAt
    }

    func savedAt(_ id: String) -> Date? { store.all().first { $0.id == id }?.savedAt }

    /// `name` relative to Conversations (the note itself by default).
    @discardableResult
    func writeNote(_ name: String? = nil) throws -> URL {
        let note = conversations.appendingPathComponent(name ?? relative)
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\ntitle: \"Budget\"\ndate: 2026-11-07\n---\n\n# Budget\n".write(to: note, atomically: true, encoding: .utf8)
        return note
    }

    @Test func aDeletedNoteIsNeverLookedUpAndItsRecordAgesOut() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try waitingRecord("rec-gone", daysAgo: 29)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)

        // The note was deleted before it got its name: its coordinates go nowhere, on this launch or the next.
        let thisLaunch = places(), nextLaunch = places()
        await thisLaunch.fillIn(conversations: conversations)
        await nextLaunch.fillIn(conversations: conversations)
        #expect(thisLaunch.lookupsAsked == 0)
        #expect(nextLaunch.lookupsAsked == 0)

        // The record isn't saved again, so its age stands and prune drops it at a month.
        let after = try #require(savedAt("rec-gone"))
        #expect(abs(after.timeIntervalSince(saved)) < 1)
        #expect(store.load("rec-gone")?.unnamed == [relative])
        store.prune(now: Date().addingTimeInterval(2 * 86_400))
        #expect(store.load("rec-gone") == nil)
    }

    @Test func aNoteThatsThereIsLookedUp() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try waitingRecord("rec-here", daysAgo: 1)
        try writeNote()
        let places = places()
        await places.fillIn(conversations: conversations)
        #expect(places.lookupsAsked == 1)
        // No answer here ("later"): the name waits, and the record isn't saved again for it.
        #expect(store.load("rec-here")?.unnamed == [relative])
        let after = try #require(savedAt("rec-here"))
        #expect(abs(after.timeIntervalSince(saved)) < 1)
    }

    @Test func aNoteICloudTookOffThePhoneCountsAsThere() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try waitingRecord("rec-stub", daysAgo: 1)
        try writeNote("2026-11-07/.14-03 Budget.md.icloud")
        let places = places()
        await places.fillIn(conversations: conversations)
        #expect(places.lookupsAsked == 1)
    }

    @Test func withLocationTurnedOffNothingIsLookedUpUntilItsBackOn() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try waitingRecord("rec-old", daysAgo: 1)
        try writeNote()

        // Turned off since: neither a note waiting for its name nor one just written sends anything.
        let off = places(.denied)
        await off.fillIn(conversations: conversations)
        let newNote = try writeNote("2026-11-07/15-10 Later.md")
        store.update("rec-new") { $0.start = start }
        await off.apply(toNote: newNote, recordingID: "rec-new")
        #expect(off.lookupsAsked == 0)
        #expect(try String(contentsOf: newNote, encoding: .utf8).contains("geo: -27.4698,153.0251\n"))
        #expect(store.load("rec-new")?.unnamed == ["2026-11-07/15-10 Later.md"])

        // Back on: the names are looked up.
        let on = places(.authorizedWhenInUse)
        await on.fillIn(conversations: conversations)
        #expect(on.lookupsAsked == 1)  // the first one asked; with no answer here the rest wait
    }
}
