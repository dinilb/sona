import Foundation

/// Decides when the one mic should be opened, reopened or closed. Pure and synchronous: its owner passes in
/// what happened with the time (seconds on a clock that stops while the Mac sleeps, like `hostNow()`), calls
/// `tick` about once a second (and when a reopen is due), and carries out the actions it returns. The owner does
/// all of that on one serial queue, never the main thread: Core Audio can block for seconds right after a wake.
///
/// - Wanted: open it now. If opening fails, try again after 1, 2, 4 ... 60 s.
/// - Devices changed, or the open one went away or changed its rate: reopen 0.5 s after the last change (they come in
///   bursts).
/// - The Mac woke up: reopen 1 s later, unless the mic has sent audio since (it came through the sleep fine).
/// - Open but no audio for 6 s: reopen. While it stays silent, reopen again after 1, 2, 4 ... 60 s. Any audio
///   resets that. A mic just opened after failed opens (around a sleep, say) still gets the full 6 s: a mic can take
///   a few seconds to start after a wake, and closing it then only starts the wait again.
/// - Wanted but not capturing: `state` is `.problem` with a plain reason.
public struct MicHealth: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Not wanted, so closed.
        case off
        /// Opening, or about to reopen.
        case starting
        /// Open and delivering audio.
        case running
        /// Wanted but not capturing. It keeps trying.
        case problem(String)
    }

    public enum Action: Equatable, Sendable {
        /// Close the mic if it's open, then open it.
        case open
        case close
    }

    public var silenceLimit = 6.0
    public var changeSettle = 0.5
    public var wakeSettle = 1.0
    /// After failures, the soonest a device change or wake retries.
    public var changeFloor = 5.0
    public var firstRetry = 1.0
    public var maxRetry = 60.0

    public private(set) var state = State.off
    public private(set) var wanted = false
    public private(set) var isOpen = false
    /// When the next (re)open is due, if one is.
    public private(set) var openAt: Double?
    /// Failed opens and silent reopens in a row; each one doubles the wait before the next try.
    public private(set) var failures = 0
    /// Silent reopens in a row (only these shorten the wait for audio from the next one).
    public private(set) var silentReopens = 0
    private var openedAt = 0.0
    /// The latest audio since the mic was opened (or the open itself, until audio comes).
    private var heardAt = 0.0
    /// `openAt` is a backoff retry (a new device or a wake brings it forward), not a settle wait.
    private var retrying = false
    /// `openAt` is only for a wake: skipped if audio comes in the meantime.
    private var wokeAt: Double?

    public init() {}

    /// Wait before try number `n` (1-based): 1, 2, 4 ... capped at `maxRetry`.
    public func retryDelay(_ n: Int) -> Double {
        min(firstRetry * pow(2, Double(max(n, 1) - 1)), maxRetry)
    }

    /// The mic is wanted (listening, or the dictation key is down) or not (paused, off).
    public mutating func setWanted(_ on: Bool, now: Double) -> [Action] {
        guard on != wanted else { return tick(now: now) }
        wanted = on
        failures = 0
        silentReopens = 0
        retrying = false
        wokeAt = nil
        guard on else {
            openAt = nil
            state = .off
            defer { isOpen = false }
            return isOpen ? [.close] : []
        }
        openAt = now
        state = .starting
        return tick(now: now)
    }

    /// The owner just opened it.
    public mutating func opened(now: Double) {
        isOpen = true
        openedAt = now
        heardAt = now
    }

    /// Opening failed (`why` is shown to the person, so keep it plain).
    public mutating func openFailed(_ why: String, now: Double) {
        isOpen = false
        guard wanted else { return }
        failures += 1
        openAt = now + retryDelay(failures)
        retrying = true
        state = .problem(why)
    }

    /// Audio arrived; `at` is when its latest sample was captured. Audio from before the last (re)open is stale.
    public mutating func heard(at: Double) {
        guard isOpen, at >= openedAt else { return }
        heardAt = max(heardAt, at)
        failures = 0
        silentReopens = 0
        if wanted { state = .running }
    }

    /// Input devices came or went, the default changed, or the open device went away or changed its rate.
    public mutating func devicesChanged(now: Double) {
        settle(now + changeSettle, now: now)
        wokeAt = nil
    }

    /// The Mac woke from sleep.
    public mutating func woke(now: Double) {
        let pending = openAt != nil
        settle(now + wakeSettle, now: now)
        // A reopen already due for another reason still happens.
        if wanted, !pending { wokeAt = now }
    }

    /// Reopen at `at`, or later if another settle wait already runs past it. A change cuts a long backoff
    /// short (a mic was just plugged in), but after failures never to less than `changeFloor`: devices that
    /// keep coming and going (virtual audio drivers, a Bluetooth mic that stops on every open) mustn't make it
    /// reopen twice a second forever. Only real audio (`heard`) resets the failures.
    private mutating func settle(_ at: Double, now: Double) {
        guard wanted else { return }
        var due = at
        if failures > 0 { due = max(due, now + min(retryDelay(failures), changeFloor)) }
        openAt = retrying ? due : max(openAt ?? due, due)
        retrying = false
    }

    /// Call about once a second while wanted, and when `openAt` comes: returns what's due.
    public mutating func tick(now: Double) -> [Action] {
        guard wanted else { return [] }
        if let due = openAt {
            guard now >= due else { return [] }
            openAt = nil
            retrying = false
            // Woke up, and the mic has sent audio since: it's fine, leave it open.
            if let woke = wokeAt, isOpen, heardAt > woke {
                wokeAt = nil
                return []
            }
            wokeAt = nil
            if state == .off { state = .starting }
            return [.open]
        }
        guard isOpen else { return [] }
        // The first silence gets the full limit; after a silent reopen, the backoff.
        let limit = silentReopens == 0 ? silenceLimit : retryDelay(silentReopens)
        guard now - heardAt >= limit else { return [] }
        failures += 1
        silentReopens += 1
        // One silent reopen usually fixes it quietly; from the second, say so.
        state = silentReopens >= 2 ? .problem("The microphone isn't sending any sound") : .starting
        return [.open]
    }
}
