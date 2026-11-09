import CoreLocation
import Foundation

/// One location fix for a recording's start or stop. Kept only in the app's own Places folder and in the note's
/// `geo`; never logged.
nonisolated struct PlaceFix: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Metres, as Core Location gave it.
    var accuracy: Double
    var at: Date
    /// False with Approximate Location: the fix can be kilometres off, so the note shows the city, never a street.
    var precise: Bool
}

/// What's known about one recording's places: `Application Support/Sona/Places/<recording id>.json`. Not in the spool
/// entry, which SpoolRecording rewrites every 10 s.
nonisolated struct PlaceRecord: Codable, Equatable, Sendable {
    var start: PlaceFix?
    var stop: PlaceFix?
    /// Its notes have their `geo`: kept a day after that for any other note from the same recording, then deleted.
    var applied: Bool?
    /// Notes written for it whose street names are still to look up (written in the background, or offline), relative
    /// to the Conversations folder ("2026-11-07/14-03 Title.md"), so they're found after they move to iCloud.
    var unnamed: [String]?
}

/// The decisions behind a note's place, as plain functions (unit tested in SonaTests/V1PlacesTests.swift).
nonisolated enum PlaceRules {
    /// The stop is shown as a second place only when it's this far from the start (metres).
    static let farEnough: CLLocationDistance = 100
    /// A fix Core Location already had (when iOS refuses a live one in the background) is used only if it's this
    /// recent around the moment, and this accurate.
    static let cachedMaxAge: TimeInterval = 300
    static let cachedMaxAccuracy: CLLocationAccuracy = 200
    /// A record whose notes all have their place goes after this; one never applied (its recording failed, say) after
    /// `maxAge`.
    static let keepAfterApplied: TimeInterval = 86_400
    static let maxAge: TimeInterval = 30 * 86_400

    /// `geo`: "lat,lon" with 4 decimals (about 11 m), never "-0.0000".
    static func geo(_ fix: PlaceFix) -> String {
        "\(fourDecimals(fix.latitude)),\(fourDecimals(fix.longitude))"
    }

    static func fourDecimals(_ value: Double) -> String {
        let rounded = (value * 10_000).rounded() / 10_000
        return String(format: "%.4f", rounded == 0 ? 0 : rounded)
    }

    static func distance(_ a: PlaceFix, _ b: PlaceFix) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Which fixes a note shows: the start, or the stop when the start has none (a start from the Lock Screen may
    /// get no fix); and the stop as well only when it's over `farEnough` from the start. Nil: no place at all.
    static func choose(start: PlaceFix?, stop: PlaceFix?) -> (main: PlaceFix, end: PlaceFix?)? {
        guard let start else { return stop.map { ($0, nil) } }
        guard let stop, distance(start, stop) > farEnough else { return (start, nil) }
        return (start, stop)
    }

    /// The front-matter keys to set: `geo` (and `geo_end`) always, `place` (and `place_end`) once a name is known.
    /// Nothing is ever removed here.
    static func changes(main: PlaceFix, end: PlaceFix?, name: String?, endName: String?) -> [String: String?] {
        var set: [String: String?] = ["geo": geo(main)]
        if let name { set["place"] = name }
        if let end {
            set["geo_end"] = geo(end)
            if let endName { set["place_end"] = endName }
        }
        return set
    }

    /// The short name a note shows, from what Apple's geocoder returned: the item's name ("4 Main St"), else the first
    /// line of its full address, else its short address. With Approximate Location, only the city.
    static func label(name: String?, firstLine: String?, short: String?, city: String?, precise: Bool) -> String? {
        let candidates = precise ? [name, firstLine, short, city] : [city]
        return candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// A fix Core Location already had stands in for a live one only if it's from around `moment` and accurate enough.
    static func usableCached(at: Date, accuracy: CLLocationAccuracy, moment: Date) -> Bool {
        abs(at.timeIntervalSince(moment)) <= cachedMaxAge && accuracy >= 0 && accuracy <= cachedMaxAccuracy
    }

    /// Location is touched only with the permission given: with it undecided, the first request would ask by itself.
    static func mayStamp(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// The one ask, When In Use: after a recording stopped, undecided, never asked before, and the app on screen (an
    /// alert can't show otherwise; a stop in the background leaves it for the next time the app is on screen).
    static func shouldAsk(status: CLAuthorizationStatus, alreadyAsked: Bool, onScreen: Bool) -> Bool {
        status == .notDetermined && !alreadyAsked && onScreen
    }

    /// A Places record is deleted once its notes have had their place for a day, or after a month whatever happened.
    static func shouldDelete(_ record: PlaceRecord, savedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        if age > maxAge { return true }
        return record.applied == true && (record.unnamed ?? []).isEmpty && age > keepAfterApplied
    }
}
