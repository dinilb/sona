import Foundation

/// How a recording gets from the watch to the iPhone, over WatchConnectivity:
///
/// 1. The watch records into its own folder: `<id>.aac` (ADTS AAC, `ADTSFile`) plus `<id>.json`, a `WatchRecording`.
///    Older builds, and the fallback when the AAC encoder won't start, record `<id>.wav` (16 kHz mono 16-bit) instead.
/// 2. It sends the audio with `transferFile(_:metadata:)`, metadata from `WatchRecording.metadata`. The system moves
///    the file to the iPhone whenever it's in range, but Sona on the iPhone only takes it when it runs. So while the
///    watch app is open and the iPhone is reachable, the watch also sends `Wake.message`, which launches Sona on the
///    iPhone in the background (only `sendMessage` from the watch does that). A file that reached the iPhone while
///    Sona was swiped away waits there until Sona next runs.
/// 3. Inside the delegate callback (the system deletes the file after it), the iPhone moves a WAV into its own spool,
///    and keeps an AAC as it came in its staging folder, to decode into the spool's 16 kHz WAV after the callback
///    (an hour takes a while). Either way it then sends `Ack.message(id)` back with `transferUserInfo` (queued,
///    survives both apps quitting). It tells the two apart by their first bytes, not the name.
/// 4. Only on that acknowledgement does the watch delete its copy. A transfer that failed, or one never
///    delivered within `resendAfter`, is sent again. One the system delivered isn't sent again on a timer: it waits
///    on the iPhone. Only a `PhoneInventory` newer than the delivery that doesn't list it (Sona was reinstalled, say)
///    sends it again. The id is the same every time, so the iPhone keeps one recording however many copies arrive.
/// 5. The iPhone also publishes a `PhoneInventory` (the ids it has) as its application context. The watch deletes
///    whatever it lists, which covers an acknowledgement that got lost.
/// `nonisolated`, like `Ack`: both apps read these inside WCSession callbacks, which run off the main thread.
nonisolated struct WatchRecording: Codable, Equatable, Identifiable {
    /// A UUID string, the same on the watch and the iPhone.
    var id: String
    var startedAt: Date
    /// Seconds of audio.
    var duration: Double
    /// When it was last handed to `transferFile`; nil if it hasn't been yet.
    var sentAt: Date?
    /// When the system said that transfer reached the iPhone; nil if it hasn't (or it failed). Optional, so the JSON
    /// of a recording made by an older build still reads. Never in `metadata`.
    var deliveredAt: Date?

    static let kind = "sona.recording"

    var metadata: [String: Any] {
        ["kind": Self.kind, "id": id, "startedAt": startedAt.timeIntervalSince1970, "duration": duration]
    }

    /// Reads the metadata the watch sent with a file; nil if it isn't one of ours.
    init?(metadata: [String: Any]?) {
        guard let metadata, metadata["kind"] as? String == Self.kind,
            let id = metadata["id"] as? String, UUID(uuidString: id) != nil,
            let started = metadata["startedAt"] as? Double
        else { return nil }
        self.id = id
        self.startedAt = Date(timeIntervalSince1970: started)
        self.duration = metadata["duration"] as? Double ?? 0
        self.sentAt = nil
        self.deliveredAt = nil
    }

    init(id: String = UUID().uuidString, startedAt: Date, duration: Double, sentAt: Date? = nil, deliveredAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.sentAt = sentAt
        self.deliveredAt = deliveredAt
    }
}

/// The iPhone's "got it": the watch may now delete its copy.
nonisolated enum Ack {
    static let kind = "sona.ack"

    static func message(_ id: String) -> [String: Any] { ["kind": kind, "id": id] }

    /// The recording id this acknowledges; nil if it isn't an acknowledgement.
    static func id(in message: [String: Any]) -> String? {
        guard message["kind"] as? String == kind, let id = message["id"] as? String else { return nil }
        return id
    }
}

/// The watch's nudge: a `sendMessage` from the watch app in front launches Sona on the iPhone in the background, and
/// that launch takes the files waiting for it. The iPhone ignores the message itself.
nonisolated enum Wake {
    static let kind = "sona.wake"
    static var message: [String: Any] { ["kind": kind] }
}

/// The watch recordings the iPhone has (the newest `kept` ids) and when it said so, sent as the iPhone's
/// application context. The watch deletes the ones it still holds, and sends again one that was delivered before
/// `at` but isn't listed. The iPhone publishes it only once WatchConnectivity has handed over everything pending, so a
/// file still on its way is never taken for a lost one.
nonisolated struct PhoneInventory: Equatable, Sendable {
    var ids: Set<String>
    var at: Date

    static let kind = "sona.inventory"
    /// About 7 KB of ids: well inside the application context's limit, and far more than wait at any time.
    static let kept = 200

    init(ids: [String], at: Date) {
        self.ids = Set(ids)
        self.at = at
    }

    var context: [String: Any] {
        ["kind": Self.kind, "ids": Array(ids), "at": at.timeIntervalSince1970]
    }

    /// Reads an application context; nil if it isn't an inventory.
    init?(context: [String: Any]) {
        guard context["kind"] as? String == Self.kind, let ids = context["ids"] as? [String],
            let at = context["at"] as? Double
        else { return nil }
        self.init(ids: ids, at: Date(timeIntervalSince1970: at))
    }
}

nonisolated enum WatchTransferPolicy {
    /// A transfer the system never delivered in this long is sent again (it may have been lost). A delivered one
    /// isn't, unless a newer `PhoneInventory` leaves it out, and not before this long either.
    static let resendAfter: TimeInterval = 60 * 60
    /// An inventory has to be this much newer than a delivery before a missing id counts: the two clocks differ a
    /// little, and the file may still be on its way into Sona.
    static let inventoryMargin: TimeInterval = 5 * 60
}
