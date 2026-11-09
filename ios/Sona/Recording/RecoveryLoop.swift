import Foundation

/// Getting the mic back after an interruption, with retries and backoff. No AVFoundation in it, so it's unit tested
/// (SonaTests/RecordingRecoveryTests.swift); MicCapture hands it the real restart and timer. Everything here runs on MicCapture's serial queue.
nonisolated final class RecoveryLoop: @unchecked Sendable {
    static let attemptsBeforeTap = 4

    /// Delay before try number `attempt` (1-based, counted in failures so far): 1, 2, 4, 8 s, then every 15 s.
    static func backoff(_ attempt: Int) -> TimeInterval {
        attempt >= 5 ? 15 : pow(2, Double(attempt - 1))
    }

    /// What to tell the owner after `attempt` failures in a row.
    static func stateAfterFailures(_ attempt: Int) -> CaptureState {
        attempt >= attemptsBeforeTap ? .needsResume : .interrupted
    }

    private let wantsRunning: () -> Bool
    private let tryRestart: () throws -> Void
    private let emit: (CaptureState, String?) -> Void
    /// Runs the work after the delay; returns a cancel closure.
    private let schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
    private var cancelPending: (() -> Void)?
    /// Once the owner has been told it needs a tap, keep saying so until a restart really works, even if a tap or
    /// the app coming to the foreground restarts the miss count. Retries carry on quietly underneath.
    private var needsTap = false

    init(
        wantsRunning: @escaping () -> Bool,
        tryRestart: @escaping () throws -> Void,
        emit: @escaping (CaptureState, String?) -> Void,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void
    ) {
        self.wantsRunning = wantsRunning
        self.tryRestart = tryRestart
        self.emit = emit
        self.schedule = schedule
    }

    /// Try after `delay`. A miss reports the state and tries again later; a hit stops the loop.
    func restart(after delay: TimeInterval = 0, attempt: Int = 0) {
        cancelPending?()
        cancelPending = schedule(delay) { [weak self] in
            guard let self, self.wantsRunning() else { return }
            do {
                try self.tryRestart()
                self.needsTap = false
            } catch {
                let next = attempt + 1
                let state = self.needsTap ? .needsResume : Self.stateAfterFailures(next)
                self.needsTap = state == .needsResume
                self.emit(state, error.localizedDescription)
                self.restart(after: Self.backoff(next), attempt: next)
            }
        }
    }

    func cancel() {
        cancelPending?()
        cancelPending = nil
        needsTap = false
    }
}
