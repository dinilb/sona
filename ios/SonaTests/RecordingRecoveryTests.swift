import Foundation
import Testing
@testable import Sona

/// A fake clock: schedule() queues the work, run() fires the next one and records its delay.
nonisolated private final class Harness {
    struct Boom: Error {}
    var failuresLeft: Int
    var wantsRunning = true
    var tries = 0
    var states: [CaptureState] = []
    var delays: [TimeInterval] = []
    private var queue: [(TimeInterval, () -> Void, Int)] = []
    private var nextID = 0
    private var cancelled = Set<Int>()
    private(set) var loop: RecoveryLoop!

    init(failures: Int) {
        failuresLeft = failures
        loop = RecoveryLoop(
            wantsRunning: { [unowned self] in self.wantsRunning },
            tryRestart: { [unowned self] in
                self.tries += 1
                if self.failuresLeft > 0 {
                    self.failuresLeft -= 1
                    throw Boom()
                }
                self.states.append(.running)
            },
            emit: { [unowned self] state, _ in self.states.append(state) },
            schedule: { [unowned self] delay, work in
                let id = self.nextID
                self.nextID += 1
                self.queue.append((delay, work, id))
                return { self.cancelled.insert(id) }
            })
    }

    /// Fires the next live scheduled job.
    @discardableResult func run() -> Bool {
        while !queue.isEmpty {
            let (delay, work, id) = queue.removeFirst()
            if cancelled.contains(id) { continue }
            delays.append(delay)
            work()
            return true
        }
        return false
    }

    func runAll(limit: Int = 50) {
        var n = 0
        while n < limit, run() { n += 1 }
    }
}

struct RecordingRecoveryTests {
    @Test func backoffSchedule() {
        #expect((1...6).map(RecoveryLoop.backoff) == [1, 2, 4, 8, 15, 15])
    }

    @Test func asksForTheAppAtTheFourthMiss() {
        #expect((1...5).map(RecoveryLoop.stateAfterFailures) == [.interrupted, .interrupted, .interrupted, .needsResume, .needsResume])
    }

    @Test func succeedsFirstTry() {
        let h = Harness(failures: 0)
        h.loop.restart(after: 0.3)
        h.runAll()
        #expect(h.states == [.running])
        #expect(h.delays == [0.3])
    }

    @Test func threeMissesStayInterruptedThenRun() {
        let h = Harness(failures: 3)
        h.loop.restart(after: 0.3)
        h.runAll()
        #expect(h.states == [.interrupted, .interrupted, .interrupted, .running])
        #expect(h.delays == [0.3, 1, 2, 4])
    }

    @Test func fourMissesAskForTheAppThenKeepTryingSlowly() {
        let h = Harness(failures: 6)
        h.loop.restart(after: 0.3)
        h.runAll()
        #expect(h.states == [.interrupted, .interrupted, .interrupted, .needsResume, .needsResume, .needsResume, .running])
        #expect(h.delays == [0.3, 1, 2, 4, 8, 15, 15])
    }

    @Test func neverGivesUpWhileStillWanted() {
        let h = Harness(failures: .max)
        h.loop.restart()
        for _ in 0..<30 { h.run() }
        #expect(h.tries == 30)
        #expect(h.states.last == .needsResume)
    }

    @Test func stopCancelsTheLoop() {
        let h = Harness(failures: .max)
        h.loop.restart()
        h.run()
        h.run()
        h.wantsRunning = false
        h.loop.cancel()
        #expect(!h.run())
        #expect(h.tries == 2)
    }

    @Test func notWantedAnymoreStopsWithoutCancel() {
        let h = Harness(failures: .max)
        h.loop.restart()
        h.run()
        h.wantsRunning = false
        h.run()
        #expect(h.tries == 1)
        #expect(!h.run())
    }

    @Test func aFailedResumeKeepsAskingUntilItWorks() {
        let h = Harness(failures: 7)
        h.loop.restart(after: 0.3)
        for _ in 0..<4 { h.run() }  // 4 misses: now asking for the app
        h.states.removeAll()
        h.delays.removeAll()
        h.loop.restart()  // opened the app: the miss count starts over, and the next tries still fail
        h.runAll()
        #expect(h.states == [.needsResume, .needsResume, .needsResume, .running])
        #expect(h.delays == [0, 1, 2, 4])
    }

    @Test func afterSuccessAFreshInterruptionStartsQuietAgain() {
        let h = Harness(failures: 4)
        h.loop.restart()
        h.runAll()
        #expect(h.states.last == .running)
        h.states.removeAll()
        h.failuresLeft = 1
        h.loop.restart()
        h.runAll()
        #expect(h.states == [.interrupted, .running])
    }

    @Test func stopThenStartForgetsTheAsk() {
        let h = Harness(failures: 4)
        h.loop.restart()
        h.runAll(limit: 4)
        h.loop.cancel()
        h.states.removeAll()
        h.failuresLeft = 1
        h.loop.restart()
        h.runAll()
        #expect(h.states == [.interrupted, .running])
    }
}
