import Foundation
import Testing
@testable import Sona

/// The off-screen task's bar (`ContinuedProgress`): iOS ends a task whose bar sits still for about 30 s, so the guess
/// must keep moving however long a note takes, and must never say done before the note is written.
struct ContinuedProgressTests {
    @Test func theGuessKeepsMovingAndNeverReachesTheEnd() {
        // A 10-minute recording on the CPU: about 200 s expected.
        var last = -1.0
        for t in stride(from: 0.0, through: 7200, by: 1) {
            let share = ContinuedProgress.share(elapsed: t, audioSeconds: 600, onCPU: true)
            #expect(share > last || t == 0)
            #expect(share < 0.99)
            last = share
        }
        #expect(ContinuedProgress.share(elapsed: 200, audioSeconds: 600, onCPU: true) == 0.8)
        #expect(ContinuedProgress.share(elapsed: -5, audioSeconds: 600, onCPU: true) == 0)
    }

    @Test func theBarMovesEveryTickWhateverTheGuessSays() {
        let unit = ContinuedProgress.unitsPerNote
        // A guess that has stopped moving (an hour over the shortest guess): still a unit a tick.
        let share = ContinuedProgress.share(elapsed: 3600, audioSeconds: 1, onCPU: false)
        var bar = ContinuedProgress.next(previous: 0, done: 0, base: 0, share: share, total: 1, underWay: true)
        for _ in 0..<30 {
            let next = ContinuedProgress.next(
                previous: bar.completed, done: 0, base: 0, share: share, total: 1, underWay: true)
            #expect(next.completed > bar.completed)
            bar = next
        }
        // Never the end of a note before it's written.
        let late = ContinuedProgress.next(previous: unit - 1, done: 0, base: 0, share: 0.99, total: 1, underWay: true)
        #expect(late.completed < unit)
        #expect(late.completed >= unit * 99 / 100)
    }

    @Test func aRetryOnTheCPUCarriesOnFromWhereTheBarWas() {
        let unit = ContinuedProgress.unitsPerNote
        // The Neural Engine try got the bar to 0.32 of the note, then failed off screen; the CPU try starts at 0.
        let was = unit * 32 / 100
        let first = ContinuedProgress.next(previous: was, done: 0, base: was, share: 0, total: 1, underWay: true)
        #expect(first.completed == was + 1)
        let later = ContinuedProgress.next(previous: first.completed, done: 0, base: was, share: 0.4, total: 1, underWay: true)
        #expect(later.completed > first.completed + unit / 10)
    }

    @Test func theUnitsCountNotesDoneAndTheOneUnderWay() {
        let unit = ContinuedProgress.unitsPerNote
        let half = ContinuedProgress.next(previous: 0, done: 1, base: 0, share: 0.5, total: 3, underWay: true)
        #expect(half.total == 3 * unit)
        #expect(half.completed > unit + unit / 3)
        #expect(half.completed < 2 * unit)
        // A note that turned up after the task started grows the bar instead of overflowing it.
        let over = ContinuedProgress.next(previous: 0, done: 3, base: 0, share: 0.5, total: 3, underWay: true)
        #expect(over.total == 4 * unit)
        #expect(over.completed < over.total)
        // Between notes: the ones written, never backwards.
        let between = ContinuedProgress.next(previous: unit / 2, done: 1, base: 0, share: 0, total: 2, underWay: false)
        #expect(between.completed == unit)
        let stays = ContinuedProgress.next(previous: unit / 2, done: 0, base: 0, share: 0, total: 2, underWay: false)
        #expect(stays.completed == unit / 2)
    }

    @Test func theTitleSaysHowMany() {
        #expect(ContinuedProcessing.title(recordings: 1) == "Writing your note")
        #expect(ContinuedProcessing.title(recordings: 3) == "Writing 3 notes")
    }
}
