import Foundation
import WidgetKit

/// Keeps the widgets' `SharedStatus` in step with the notes: how many recordings wait, and the newest note. The
/// recorder owns `recordingSince`, so it's loaded, only these fields change, and it's saved again.
enum WidgetStatus {
    /// Where the status lives: the App Group (SharedStatus's own load and save), or a stand-in for tests.
    struct Store {
        var load: () -> SharedStatus
        var save: (SharedStatus) -> Void
        var reload: () -> Void

        static let appGroup = Store(
            load: { SharedStatus.load() }, save: { $0.save() }, reload: { WidgetCenter.shared.reloadAllTimelines() })
    }

    static func updated(_ status: SharedStatus, waiting: Int, latestTitle: String?, latestAt: Date?) -> SharedStatus {
        var status = status
        status.waiting = waiting
        status.latestTitle = latestTitle
        status.latestAt = latestAt
        return status
    }

    /// Saves the new numbers and reloads the widgets, only if something changed (reloads are budgeted). True if it did.
    @discardableResult
    static func publish(waiting: Int, latestTitle: String?, latestAt: Date?, store: Store = .appGroup) -> Bool {
        let old = store.load()
        let new = updated(old, waiting: waiting, latestTitle: latestTitle, latestAt: latestAt)
        guard new != old else { return false }
        store.save(new)
        store.reload()
        return true
    }
}
