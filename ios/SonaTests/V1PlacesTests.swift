import CoreLocation
import Foundation
import Testing
@testable import Sona

/// Where a note was recorded: which fix it shows, how `geo` is written, when the stop counts as somewhere else, when
/// Sona may touch location or ask, and what's kept on disk. No location services and no network here.
struct V1PlacesRuleTests {
    let brisbane = PlaceFix(latitude: -27.469812, longitude: 153.025123, accuracy: 10, at: Date(timeIntervalSince1970: 1_793_000_000), precise: true)

    /// `fix` moved `metres` north (one degree of latitude is about 111 km).
    func north(of fix: PlaceFix, metres: Double) -> PlaceFix {
        var moved = fix
        moved.latitude += metres / 111_000
        return moved
    }

    @Test func geoHasFourDecimals() {
        #expect(PlaceRules.geo(brisbane) == "-27.4698,153.0251")
        let tiny = PlaceFix(latitude: -0.00001, longitude: 0.00004, accuracy: 5, at: .now, precise: true)
        #expect(PlaceRules.geo(tiny) == "0.0000,0.0000")  // never "-0.0000"
        let rounding = PlaceFix(latitude: 51.50007, longitude: -0.12762, accuracy: 5, at: .now, precise: true)
        #expect(PlaceRules.geo(rounding) == "51.5001,-0.1276")
    }

    @Test func theStartIsThePlaceAndTheStopOnlyWhenItsFarEnough() throws {
        let near = north(of: brisbane, metres: 60)
        let far = north(of: brisbane, metres: 250)
        #expect(PlaceRules.distance(brisbane, near) < PlaceRules.farEnough)
        #expect(PlaceRules.distance(brisbane, far) > PlaceRules.farEnough)

        let same = try #require(PlaceRules.choose(start: brisbane, stop: near))
        #expect(same.main == brisbane)
        #expect(same.end == nil)

        let moved = try #require(PlaceRules.choose(start: brisbane, stop: far))
        #expect(moved.main == brisbane)
        #expect(moved.end == far)
    }

    @Test func withOneFixTheNoteUsesThatOne() throws {
        // A start from the Lock Screen may get no fix: the stop's is the place.
        let onlyStop = try #require(PlaceRules.choose(start: nil, stop: brisbane))
        #expect(onlyStop.main == brisbane)
        #expect(onlyStop.end == nil)
        let onlyStart = try #require(PlaceRules.choose(start: brisbane, stop: nil))
        #expect(onlyStart.main == brisbane)
        #expect(onlyStart.end == nil)
        #expect(PlaceRules.choose(start: nil, stop: nil) == nil)
    }

    @Test func frontMatterKeys() {
        let far = north(of: brisbane, metres: 250)
        #expect(PlaceRules.changes(main: brisbane, end: nil, name: nil, endName: nil) == ["geo": "-27.4698,153.0251"])
        #expect(PlaceRules.changes(main: brisbane, end: nil, name: "4 Main St", endName: nil)
            == ["geo": "-27.4698,153.0251", "place": "4 Main St"])
        let both = PlaceRules.changes(main: brisbane, end: far, name: "4 Main St", endName: "9 Queen St")
        #expect(both["geo_end"] == .some(PlaceRules.geo(far)))
        #expect(both["place_end"] == .some("9 Queen St"))
        // A name not known yet is left out, never written as empty or removed.
        let unnamedEnd = PlaceRules.changes(main: brisbane, end: far, name: "4 Main St", endName: nil)
        #expect(unnamedEnd["place_end"] == nil)
        #expect(unnamedEnd.values.allSatisfy { $0 != nil })
    }

    @Test func theShortNameComesFromTheItemThenTheAddress() {
        #expect(PlaceRules.label(name: "4 Main St", firstLine: "4 Main Street", short: "4 Main St, Brisbane", city: "Brisbane", precise: true) == "4 Main St")
        #expect(PlaceRules.label(name: nil, firstLine: "4 Main Street", short: "4 Main St, Brisbane", city: "Brisbane", precise: true) == "4 Main Street")
        #expect(PlaceRules.label(name: " ", firstLine: nil, short: "4 Main St, Brisbane", city: nil, precise: true) == "4 Main St, Brisbane")
        #expect(PlaceRules.label(name: nil, firstLine: nil, short: nil, city: nil, precise: true) == nil)
        // Approximate Location can be kilometres off: the city, never a street.
        #expect(PlaceRules.label(name: "4 Main St", firstLine: "4 Main Street", short: nil, city: "Brisbane", precise: false) == "Brisbane")
    }

    @Test func aCachedFixStandsInOnlyWhenRecentAndAccurate() {
        let moment = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(PlaceRules.usableCached(at: moment.addingTimeInterval(-120), accuracy: 30, moment: moment))
        #expect(!PlaceRules.usableCached(at: moment.addingTimeInterval(-600), accuracy: 30, moment: moment))
        #expect(!PlaceRules.usableCached(at: moment, accuracy: 900, moment: moment))
        #expect(!PlaceRules.usableCached(at: moment, accuracy: -1, moment: moment))  // invalid
    }

    @Test func locationIsTouchedOnlyWithThePermission() {
        #expect(PlaceRules.mayStamp(.authorizedWhenInUse))
        #expect(PlaceRules.mayStamp(.authorizedAlways))
        // Undecided: a request would ask by itself, maybe in the background.
        #expect(!PlaceRules.mayStamp(.notDetermined))
        #expect(!PlaceRules.mayStamp(.denied))
        #expect(!PlaceRules.mayStamp(.restricted))
    }

    @Test func itAsksOnceOnScreenAndNeverAgain() {
        #expect(PlaceRules.shouldAsk(status: .notDetermined, alreadyAsked: false, onScreen: true))
        // Stopped from the Lock Screen: later, when the app is on screen.
        #expect(!PlaceRules.shouldAsk(status: .notDetermined, alreadyAsked: false, onScreen: false))
        // Asked once (or "Allow Once" ran out): never again.
        #expect(!PlaceRules.shouldAsk(status: .notDetermined, alreadyAsked: true, onScreen: true))
        #expect(!PlaceRules.shouldAsk(status: .denied, alreadyAsked: false, onScreen: true))
        #expect(!PlaceRules.shouldAsk(status: .authorizedWhenInUse, alreadyAsked: false, onScreen: true))
    }

    @Test func recordsGoOnceUsedOrAfterAMonth() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let done = PlaceRecord(start: brisbane, applied: true)
        #expect(!PlaceRules.shouldDelete(done, savedAt: now.addingTimeInterval(-3600), now: now))  // another note may come
        #expect(PlaceRules.shouldDelete(done, savedAt: now.addingTimeInterval(-2 * 86_400), now: now))
        let waitingForName = PlaceRecord(start: brisbane, applied: true, unnamed: ["2026-11-07/14-03 Note.md"])
        #expect(!PlaceRules.shouldDelete(waitingForName, savedAt: now.addingTimeInterval(-2 * 86_400), now: now))
        // A recording still waiting for the speech model keeps its fixes.
        let notYet = PlaceRecord(start: brisbane)
        #expect(!PlaceRules.shouldDelete(notYet, savedAt: now.addingTimeInterval(-5 * 86_400), now: now))
        #expect(PlaceRules.shouldDelete(notYet, savedAt: now.addingTimeInterval(-31 * 86_400), now: now))
    }
}

/// The Places folder and writing a place into a note, with no location services and no geocoder.
@MainActor
struct V1PlacesStoreTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID().uuidString)", isDirectory: true)
    let start = PlaceFix(latitude: -27.469812, longitude: 153.025123, accuracy: 10, at: Date(timeIntervalSince1970: 1_793_000_000), precise: true)

    var store: PlaceStore { PlaceStore(folder: folder.appendingPathComponent("Places", isDirectory: true)) }

    func stamps() -> PlaceStamps {
        PlaceStamps(
            store: store, defaults: UserDefaults(suiteName: "places-\(UUID().uuidString)")!, watchesPermission: false,
            looksUpNames: false)
    }

    @Test func aRecordKeepsBothFixesAndGoesWhenDiscarded() {
        store.update("rec-1") { $0.start = start }
        var stop = start
        stop.latitude += 0.01
        store.update("rec-1") { $0.stop = stop }
        #expect(store.load("rec-1") == PlaceRecord(start: start, stop: stop))
        // Out of iCloud Backup.
        let values = try? store.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values?.isExcludedFromBackup == true)

        stamps().discard(recordingID: "rec-1")
        #expect(store.load("rec-1") == nil)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func aNoteGetsItsGeoAndWaitsForItsNames() async throws {
        let day = folder.appendingPathComponent("Conversations/2026-11-07", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let note = day.appendingPathComponent("14-03 Budget.md")
        try "---\ntitle: \"Budget\"\ndate: 2026-11-07\ntags: [conversation]\n---\n\n# Budget\n".write(to: note, atomically: true, encoding: .utf8)
        var stop = start
        stop.latitude += 0.005  // about 550 m: somewhere else
        store.update("rec-2") {
            $0.start = start
            $0.stop = stop
        }

        await stamps().apply(toNote: note, recordingID: "rec-2")
        let text = try String(contentsOf: note, encoding: .utf8)
        #expect(text.contains("geo: -27.4698,153.0251\n"))
        #expect(text.contains("geo_end: \(PlaceRules.geo(stop))\n"))
        #expect(!text.contains("place:"))  // no geocoder here: the name waits for a later foreground
        #expect(text.hasSuffix("---\n\n# Budget\n"))
        let record = try #require(store.load("rec-2"))
        #expect(record.applied == true)
        #expect(record.unnamed == ["2026-11-07/14-03 Budget.md"])
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func aRecordingWithNoFixLeavesTheNoteAlone() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = folder.appendingPathComponent("09-00 Plain.md")
        let original = "---\ntitle: \"Plain\"\n---\n\n# Plain\n"
        try original.write(to: note, atomically: true, encoding: .utf8)
        await stamps().apply(toNote: note, recordingID: "never-stamped")  // a watch recording, or no permission
        #expect(try String(contentsOf: note, encoding: .utf8) == original)
        try? FileManager.default.removeItem(at: folder)
    }
}
