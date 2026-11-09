import CoreLocation
import Foundation
import MapKit
import NotesKit
import Observation
import UIKit

/// Where each recording was made: one location fix when it starts and one when it stops (no polling, no location
/// background mode, When In Use only), and the street name in its note (`place`, `geo`, and `place_end`, `geo_end`
/// when it stopped somewhere else). Watch recordings get no place: the phone can't know where the watch was.
///
/// The fixes wait in `PlaceStore` until the note is written (`apply`). Street names come from Apple's geocoder
/// (`MKReverseGeocodingRequest`, coordinates only), only with the app on screen; a note written in the background or
/// offline gets its `geo` at once and its name on a later foreground (`fillIn`). Coordinates and names are never logged.
@MainActor @Observable
final class PlaceStamps {
    static let shared = PlaceStamps()

    /// How long one fix may take.
    static let timeout: Duration = .seconds(10)
    /// Apple's geocoder allows about 50 requests a minute per app: a foreground pass stays well under.
    static let lookupsPerPass = 20

    /// For Settings: the When In Use permission as it is now.
    private(set) var permission: CLAuthorizationStatus = .notDetermined

    @ObservationIgnored private let store: PlaceStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let looksUpNames: Bool
    @ObservationIgnored private var watch: PermissionWatch?
    /// Fixes still being taken, by recording: a note waits for them (at most `timeout`) before it gets its place.
    @ObservationIgnored private var inFlight: [String: [Task<Void, Never>]] = [:]
    /// Recordings too short to keep: a fix that arrives for one is dropped.
    @ObservationIgnored private var discarded: Set<String> = []
    /// Names looked up this launch, by `geo` (and precision), so a stop near the start or a second note costs nothing.
    @ObservationIgnored private var names: [String: String] = [:]
    /// Places the geocoder had no name for this launch: not asked again until the next launch.
    @ObservationIgnored private var nameless: Set<String> = []
    @ObservationIgnored private var filling = false
    /// Street names asked for this launch, not counting ones already known (tests: none for a deleted note).
    @ObservationIgnored private(set) var lookupsAsked = 0

    private static let askedKey = "placesAsked"
    private static let askPendingKey = "placesAskPending"

    /// `store` and `defaults`: tests pass their own. `watchesPermission`: false in tests (no CLLocationManager at all),
    /// which then say what the permission is with `permission`. `looksUpNames`: false in tests, which must make no
    /// network call (every name waits for "later").
    init(
        store: PlaceStore = .standard, defaults: UserDefaults = .standard, watchesPermission: Bool = true,
        looksUpNames: Bool = true, permission: CLAuthorizationStatus = .notDetermined
    ) {
        self.store = store
        self.defaults = defaults
        self.looksUpNames = looksUpNames
        self.permission = permission
        if watchesPermission {
            let watch = PermissionWatch()
            watch.onChange = { [weak self] status in self?.permission = status }
            self.permission = watch.status
            self.watch = watch
        }
    }

    // MARK: Stamps (PhoneRecorder)

    /// A recording started (PhoneRecorder.begin, after `phase = .recording`). Never waited for.
    func stampStart(recordingID id: String) {
        stamp(id, isStart: true)
    }

    /// It stopped and was kept (PhoneRecorder.close). Never holds up the note: `apply` waits for this fix instead. The
    /// first one is also when Sona asks for the permission, if onboarding hasn't (an install that finished onboarding
    /// before it had a places step).
    func stampStop(recordingID id: String) {
        stamp(id, isStart: false)
        defaults.set(true, forKey: Self.askPendingKey)
        askIfDue()
    }

    /// A recording too short to keep: no note, so nothing of its place is kept.
    func discard(recordingID id: String) {
        discarded.insert(id)
        inFlight[id] = nil
        store.remove(id)
    }

    /// Back on screen: a question left from a recording that stopped in the background is asked now.
    func appBecameActive() {
        askIfDue()
    }

    /// From Settings, a tap on "Turn On": the system question, if it was never answered.
    func askFromSettings() {
        guard permission == .notDetermined else { return }
        defaults.set(true, forKey: Self.askedKey)
        watch?.ask()
    }

    /// The one ask has been used (onboarding, after a first recording, or Settings): none comes by itself again.
    var hasAsked: Bool { defaults.bool(forKey: Self.askedKey) }

    /// Onboarding's places step: the system question if it was never answered, back once it's answered. Whatever the
    /// answer, it counts as the one ask, so none comes after the first recording.
    func askInOnboarding() async {
        defaults.set(true, forKey: Self.askedKey)
        defaults.set(false, forKey: Self.askPendingKey)
        guard permission == .notDetermined, let watch else { return }
        watch.ask()
        // The alert makes the app inactive while it's up. Still active after a moment: iOS showed none, don't wait.
        let asked = Date()
        while permission == .notDetermined, Date().timeIntervalSince(asked) < Self.answerWait {
            let alertUp = UIApplication.shared.applicationState != .active
            if !alertUp, Date().timeIntervalSince(asked) > 2 { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The longest onboarding waits on the system question (seconds).
    static let answerWait: TimeInterval = 60

    private func stamp(_ id: String, isStart: Bool) {
        guard PlaceRules.mayStamp(permission), watch != nil else { return }
        let moment = Date()
        let shot = OneShotFix()
        let task = Task {
            guard let location = await shot.fix(near: moment, timeout: Self.timeout) else { return }
            guard !self.discarded.contains(id) else { return }
            let fix = PlaceFix(
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy, at: location.timestamp, precise: shot.precise)
            self.store.update(id) { record in
                if isStart { record.start = fix } else { record.stop = fix }
            }
        }
        inFlight[id, default: []].append(task)
    }

    private func askIfDue() {
        guard defaults.bool(forKey: Self.askPendingKey) else { return }
        let onScreen = UIApplication.shared.applicationState == .active
        let asked = defaults.bool(forKey: Self.askedKey)
        guard permission == .notDetermined, !asked else {
            defaults.set(false, forKey: Self.askPendingKey)  // decided, or asked once already: never again
            return
        }
        guard PlaceRules.shouldAsk(status: permission, alreadyAsked: asked, onScreen: onScreen), let watch else { return }
        defaults.set(true, forKey: Self.askedKey)
        defaults.set(false, forKey: Self.askPendingKey)
        watch.ask()
    }

    // MARK: Notes (NoteEnrichment)

    /// Writes the recording's place into its note, just written and still on this iPhone: `geo` always, the street
    /// name if the app is on screen, location is allowed and the geocoder answers; otherwise the name is left for
    /// `fillIn`.
    func apply(toNote note: URL, recordingID id: String) async {
        for task in inFlight.removeValue(forKey: id) ?? [] { await task.value }
        guard let record = store.load(id), let chosen = PlaceRules.choose(start: record.start, stop: record.stop) else {
            return
        }
        var name: Lookup = .later, endName: Lookup = .none
        if Self.onScreen, mayLookUp {
            name = await lookUp(chosen.main)
            if let end = chosen.end { endName = await lookUp(end) }
        } else if chosen.end != nil {
            endName = .later
        }
        let changes = PlaceRules.changes(main: chosen.main, end: chosen.end, name: name.text, endName: endName.text)
        guard await Self.write(changes, to: note) else { return }
        let relative = note.deletingLastPathComponent().lastPathComponent + "/" + note.lastPathComponent
        store.update(id) { record in
            record.applied = true
            if name == .later || endName == .later {
                record.unnamed = (record.unnamed ?? []) + [relative]
            }
        }
    }

    /// With the app on screen and location allowed: street names for notes that got only their `geo` (written in the
    /// background or offline), found in `conversations` wherever they moved, and old records deleted. Stops at the
    /// first network failure, and after `lookupsPerPass` lookups; the rest wait for the next foreground.
    func fillIn(conversations: URL) async {
        store.prune()
        // With location turned off since, the coordinates stay in the notes and go nowhere; back on, the names come.
        guard Self.onScreen, !filling, mayLookUp else { return }
        filling = true
        defer { filling = false }
        var lookups = 0
        for item in store.all() {
            let unnamed = item.record.unnamed ?? []
            guard !unnamed.isEmpty else { continue }
            guard let chosen = PlaceRules.choose(start: item.record.start, stop: item.record.stop) else {
                store.remove(item.id)
                continue
            }
            // Only for notes that are there: a deleted note's coordinates never go to the geocoder. A note not in
            // `conversations` yet (still waiting on this iPhone to move) keeps its turn. The record isn't saved, so it
            // ages out after a month (`PlaceRules.maxAge`) if its notes never turn up.
            let present = unnamed.filter { Self.noteExists(conversations.appendingPathComponent($0)) }
            guard !present.isEmpty else { continue }
            guard lookups < Self.lookupsPerPass, Self.onScreen, mayLookUp else { return }
            lookups += chosen.end == nil ? 1 : 2
            let name = await lookUp(chosen.main)
            var endName = Lookup.none
            if let end = chosen.end { endName = await lookUp(end) }
            if name == .later || endName == .later { return }  // offline or throttled: next time
            let changes = PlaceRules.changes(main: chosen.main, end: chosen.end, name: name.text, endName: endName.text)
            var notWritten: [String] = []
            for relative in unnamed {
                if present.contains(relative), await Self.write(changes, to: conversations.appendingPathComponent(relative)) {
                    continue
                }
                notWritten.append(relative)
            }
            // Saved only when a note got its name: each save moves the record's age on, and prune goes by it.
            guard notWritten != unnamed else { continue }
            store.update(item.id) { $0.unnamed = notWritten.isEmpty ? nil : notWritten }
        }
    }

    // MARK: Street names

    private enum Lookup: Equatable {
        case name(String)
        /// The geocoder had nothing for it: no name, and not asked again.
        case none
        /// Not now (in the background, offline, throttled): asked again on a later foreground.
        case later

        var text: String? {
            if case .name(let text) = self { return text }
            return nil
        }
    }

    private static var onScreen: Bool { UIApplication.shared.applicationState != .background }

    /// Coordinates go to the geocoder only while location is allowed: turned off, a name waits until it's back on.
    private var mayLookUp: Bool { PlaceRules.mayStamp(permission) }

    /// The note, or the stub iCloud leaves when it takes the note off the phone.
    nonisolated private static func noteExists(_ note: URL) -> Bool {
        let fm = FileManager.default
        let stub = note.deletingLastPathComponent().appendingPathComponent(".\(note.lastPathComponent).icloud")
        return fm.fileExists(atPath: note.path) || fm.fileExists(atPath: stub.path)
    }

    /// One reverse geocode, or a name already looked up for the same spot. Only coordinates go to Apple.
    private func lookUp(_ fix: PlaceFix) async -> Lookup {
        let key = PlaceRules.geo(fix) + (fix.precise ? "" : "~")
        if let known = names[key] { return .name(known) }
        if nameless.contains(key) { return .none }
        lookupsAsked += 1
        guard looksUpNames else { return .later }
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: fix.latitude, longitude: fix.longitude))
        else { return .none }
        do {
            let label: String? = try await withCheckedThrowingContinuation { continuation in
                request.getMapItems { items, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: Self.label(of: items?.first, precise: fix.precise))
                    }
                }
            }
            guard let label else {
                nameless.insert(key)
                return .none
            }
            names[key] = label
            return .name(label)
        } catch {
            // Offline, throttled (about 50 a minute), or a server error: the coordinates are in the note already.
            Log.note("places: no street name now (\((error as NSError).domain) error \((error as NSError).code))")
            return .later
        }
    }

    private static func label(of item: MKMapItem?, precise: Bool) -> String? {
        guard let item else { return nil }
        let representations = item.addressRepresentations
        let firstLine = representations?.fullAddress(includingRegion: false, singleLine: false)?
            .components(separatedBy: .newlines).first
        return PlaceRules.label(
            name: item.name, firstLine: firstLine, short: item.address?.shortAddress,
            city: representations?.cityName, precise: precise)
    }

    /// Sets the keys in the note's front matter, off the main actor (a coordinated write; one in iCloud may wait for
    /// it to download). False if the note isn't there any more or couldn't be written.
    @concurrent nonisolated private static func write(_ changes: [String: String?], to note: URL) async -> Bool {
        guard noteExists(note) else { return false }
        do {
            try NoteFiles.updateFrontMatter(note, set: changes)
            return true
        } catch {
            Log.note("places: couldn't write a note's place: \(Log.describe(error))")
            return false
        }
    }
}

/// Keeps `PlaceStamps.permission` current, and asks the one question. Created on the main thread, so Core Location
/// calls it back there.
final class PermissionWatch: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    func ask() {
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.onChange?(status) }
    }
}
