import Foundation

/// Identifiers shared by the iPhone app, the watch app and their widgets. They match what's registered in the
/// Apple Developer portal (team 6SM42LA4ZC), so change them there first. `nonisolated`: plain constants, read off the
/// main thread too (background tasks, WCSession callbacks).
nonisolated enum SonaIDs {
    static let appGroup = "group.com.dinilb.sona"
    static let iCloudContainer = "iCloud.com.dinilb.sona"
    /// BGProcessingTask that transcribes waiting recordings while the phone charges.
    static let transcribeTask = "com.dinilb.sona.transcribe"
}

/// This device's secret for links: a random string in the App Group (each device has its own), made the first time
/// anything reads it. The widgets and complications put it in the links they open (`DeepLink.url`) and the app acts on
/// a link only if it carries it. Any app or web page can open `sona://record`, but none can read the App Group.
nonisolated enum LinkKey {
    static let defaultsKey = "sona.linkKey"

    /// `defaults`: the App Group's. If that can't be opened it's the process's own, which no widget shares, so a link
    /// built anywhere else doesn't match and nothing is trusted.
    static func current(in defaults: UserDefaults = UserDefaults(suiteName: SonaIDs.appGroup) ?? .standard) -> String {
        if let key = defaults.string(forKey: defaultsKey), !key.isEmpty { return key }
        let key = UUID().uuidString
        defaults.set(key, forKey: defaultsKey)
        return key
    }
}

/// `sona://record?k=<key>` starts a recording (complications, widgets); `sona://stop?k=<key>` stops it. The key is this
/// device's `LinkKey`. Without it, or with another, a link only opens the app: a page or another app can open any
/// `sona://` link, so a bare `sona://record` must never start the mic.
enum DeepLink: String {
    case record
    case stop

    static let scheme = "sona"
    /// The query item that carries the key.
    static let keyName = "k"

    /// The link a widget or complication opens: this device's key goes with it.
    var url: URL { url(key: LinkKey.current()) }

    func url(key: String) -> URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = rawValue
        parts.queryItems = [URLQueryItem(name: Self.keyName, value: key)]
        return parts.url!
    }

    /// The link `url` stands for, only if it carries `key` (exactly once). Anything else (no key, a wrong one, another
    /// scheme, a host that isn't a link of ours) is nil, and the app does nothing beyond opening. There is no way to
    /// read a link without this check.
    static func trusted(url: URL, key: String = LinkKey.current()) -> DeepLink? {
        guard !key.isEmpty, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == scheme, let host = parts.host, let link = DeepLink(rawValue: host)
        else { return nil }
        let keys = (parts.queryItems ?? []).filter { $0.name == keyName }
        guard keys.count == 1, keys[0].value == key else { return nil }
        return link
    }
}

/// What the widgets and complications show, written by the app into the App Group (each device has its own).
struct SharedStatus: Codable, Equatable {
    /// When the recording now running started; nil when nothing is recording.
    var recordingSince: Date?
    /// Set while that recording's mic is paused (a call has it): the widgets say "paused", not "recording".
    var pausedAt: Date?
    /// Recordings waiting to be transcribed (iPhone) or sent to the iPhone (watch).
    var waiting: Int = 0
    /// The newest note's title, for the widget.
    var latestTitle: String?
    var latestAt: Date?
    /// While it records: the app's last word that it's still recording. The iPhone says it every `aliveEvery` and
    /// its widgets stop claiming to record at `staleAt`; the watch says it about once a minute and its complication
    /// stops counting after `aliveWithin` (`liveRecordingSince`). A recording whose app died (a crash, a kill, a flat
    /// battery) leaves `recordingSince` set and stops getting these. Optional, so status saved by an older build still
    /// decodes. Each device has its own App Group, so the two never mix.
    var aliveAt: Date?

    static let key = "sona.status"
    /// iPhone: how often the recording app says it's alive, and how long a widget trusts it. Each word reloads the
    /// widget, and reloads are budgeted, so minutes rather than the Live Activity's 90 s.
    static let aliveEvery: TimeInterval = 300
    static let staleAfter: TimeInterval = 360
    /// Watch: a recording not heard from in this long counts as stopped.
    static let aliveWithin: TimeInterval = 3 * 60

    /// Watch: `recordingSince`, or nil when the app that wrote it hasn't said it's alive for `aliveWithin`. Before
    /// any heartbeat, the start counts as one.
    func liveRecordingSince(now: Date) -> Date? {
        guard let since = recordingSince else { return nil }
        return now.timeIntervalSince(aliveAt ?? since) > Self.aliveWithin ? nil : since
    }

    /// iPhone: when "recording" stops being believed (nil when nothing records).
    var staleAt: Date? {
        guard let since = recordingSince else { return nil }
        return (aliveAt ?? since).addingTimeInterval(Self.staleAfter)
    }

    /// iPhone: a recording the app hasn't vouched for lately: it may have died, so a widget says "not recording".
    func isStale(at date: Date) -> Bool {
        guard let staleAt else { return false }
        return date >= staleAt
    }

    /// When the iPhone widget's look changes by itself, so its timeline has an entry for each, in order:
    /// - now;
    /// - with a newest note, the next two midnights: "9:41 am" turns into "yesterday", then into a fixed "mon 2 nov",
    ///   which never goes stale (with only the first, "yesterday" stayed for days);
    /// - while it records, `staleAt`, when it turns into "not recording". Each time the app says it's alive the
    ///   widget is reloaded and this moves on; if the app dies, the widget turns by itself.
    func timelineDates(now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = [now]
        if latestAt != nil {
            let today = calendar.startOfDay(for: now)
            dates += [1, 2].compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        }
        if let staleAt, staleAt > now { dates.append(staleAt) }
        return dates.sorted()
    }

    static func load() -> SharedStatus {
        guard let data = UserDefaults(suiteName: SonaIDs.appGroup)?.data(forKey: key),
            let status = try? JSONDecoder().decode(SharedStatus.self, from: data)
        else { return SharedStatus() }
        return status
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: SonaIDs.appGroup)?.set(data, forKey: Self.key)
    }
}
