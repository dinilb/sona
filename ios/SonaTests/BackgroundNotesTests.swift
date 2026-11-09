import Foundation
import SonaEngine
import Testing
@testable import Sona

/// Off screen, a short recording that comes in (a stop from the Lock Screen or Siri, the watch) is written on the
/// background time iOS gives; a long one waits (`NotesService.gate`, `nextIndex(in:gate:...)`).
struct BackgroundNotesTests {
    typealias Gate = NotesService.Gate

    private func gate(
        _ background: Bool, task: Bool = false, stopped: Bool = false, hold: TimeInterval? = nil, recording: Bool = false
    ) -> Gate {
        NotesService.gate(background: background, taskRuns: task, stopped: stopped, holdLeft: hold, recording: recording)
    }

    @Test func whatMayStartOnScreenAndOff() {
        // On screen, anything, whatever else is going on.
        #expect(gate(false) == .any(background: false))
        #expect(gate(false, stopped: true, hold: 5) == .any(background: false))
        // A background task carries the feed until something stops it.
        #expect(gate(true, task: true) == .any(background: true))
        #expect(gate(true, task: true, hold: 20) == .any(background: true))
        // Held background time: only what fits it, even after a background task was stopped.
        #expect(gate(true, hold: 25) == .fits(25))
        #expect(gate(true, task: true, stopped: true, hold: 12) == .fits(12))
        // Nothing to run on: it waits, as it always did.
        #expect(gate(true) == .none)
        #expect(gate(true, task: true, stopped: true) == .none)
    }

    /// The mic on: nothing starts, on screen or off, whatever time or task there is, so a new recording also stops
    /// held background time from taking more notes.
    @Test func nothingStartsWhileRecording() {
        #expect(gate(false, recording: true) == .none)
        #expect(gate(true, hold: 30, recording: true) == .none)
        #expect(gate(true, task: true, recording: true) == .none)
    }

    @Test func heldTimeTakesOnlyAShortNoteThatFits() {
        let seconds = ["long": 600.0, "watch": 20, "half": 30, "over": 31, "minute": 60, "last": 10, "missed": 8]
        let tries = ["last": Processor.maxAttempts - 1]
        func pick(_ queue: [String], _ gate: Gate, missed: Set<String> = []) -> Int? {
            NotesService.nextIndex(
                in: queue, gate: gate, tries: { tries[$0] ?? 0 }, audioSeconds: { seconds[$0] ?? 0 }, missed: missed)
        }
        // A long note first in line doesn't hold up the short one behind it.
        #expect(pick(["long", "watch"], .fits(30)) == 1)
        #expect(pick(["long"], .fits(30)) == nil)
        // 30 s of audio or less, and only if it fits what's left of the time.
        #expect(pick(["half"], .fits(30)) == 0)
        #expect(pick(["half"], .fits(15)) == nil)
        // Over 30 s waits for the charger, the screen or a task, even with time to spare: iOS's background CPU limit.
        #expect(pick(["over"], .fits(30)) == nil)
        #expect(pick(["minute"], .fits(30)) == nil)
        #expect(pick(["minute", "watch"], .fits(30)) == 1)
        // Never one on its last attempt, and never one that already failed or ran out of time off screen.
        #expect(pick(["last", "watch"], .fits(30)) == 1)
        #expect(pick(["missed", "watch"], .fits(30), missed: ["missed"]) == 1)
        #expect(pick(["missed"], .fits(30), missed: ["missed"]) == nil)
        // Nothing at all without time, and the other gates pick as before (no length cap there).
        #expect(pick(["watch"], .none) == nil)
        #expect(pick(["long", "watch"], .any(background: true)) == 0)
        #expect(pick(["last", "watch"], .any(background: true)) == 1)
        #expect(pick(["last", "watch"], .any(background: false)) == 1)
    }

    /// The time estimate behind `.fits`: a 30 s note fits iOS's ~30 s with room to spare; longer audio never takes
    /// less time, and `backgroundTimeRemaining` is never trusted for more than the cap (it says forever while the mic
    /// still runs).
    @Test func theTimeEstimate() {
        #expect(NotesService.heldAudioCap == 30)
        #expect(NotesService.backgroundSeconds(audio: 10) < 15)
        #expect(NotesService.backgroundSeconds(audio: NotesService.heldAudioCap) <= NotesService.backgroundTimeCap)
        #expect(NotesService.backgroundSeconds(audio: 30) < NotesService.backgroundSeconds(audio: 31))
        #expect(NotesService.backgroundSeconds(audio: -5) == NotesService.backgroundSeconds(audio: 0))
    }

    /// Held time running out with the charging task or the off-screen task still running: the task carries the note
    /// on, so only the borrowed time goes. With neither, the note under way is out of time.
    @Test func runningOutOfHeldTimeWithATaskRunning() {
        #expect(NotesService.aTaskCarriesOn(continued: false, charging: true))
        #expect(NotesService.aTaskCarriesOn(continued: true, charging: false))
        #expect(!NotesService.aTaskCarriesOn(continued: false, charging: false))
    }

    /// A launch that decodes no new watch recording doesn't tell a wake's hold that its file came.
    @Test func leftoversWithNothingNewDontCountForAWake() {
        #expect(!WatchReceiver.countsForWake(added: []))
        #expect(WatchReceiver.countsForWake(added: ["2026-11-08T16-24-19-watch"]))
    }
}

/// When a wake from the watch lets its background launch go (`WakeWait`).
struct WakeWaitTests {
    @Test func waitsForAFileThenForNothingPending() throws {
        var wait = WakeWait()
        let woke = wait.wake(at: 100)
        let gen = try #require(woke)
        #expect(wait.isCurrent(gen))
        // No file yet: it waits, pending or not.
        #expect(!wait.shouldEnd(at: 101, pending: false))
        wait.fileArrived(at: 103)
        // More on its way: still waits.
        #expect(!wait.shouldEnd(at: 104, pending: true))
        #expect(wait.shouldEnd(at: 104, pending: false))
        wait.ended()
        #expect(!wait.isCurrent(gen))
    }

    @Test func givesUpWhenNoFileComes() {
        var wait = WakeWait()
        _ = wait.wake(at: 100)
        #expect(!wait.shouldEnd(at: 100 + WakeWait.firstFileWait - 1, pending: false))
        #expect(wait.shouldEnd(at: 100 + WakeWait.firstFileWait, pending: false))
    }

    /// A second wake while one holds (a second stop): the same hold, waiting for a new file until a fresh deadline.
    @Test func aSecondWakeWaitsForItsOwnFile() throws {
        var wait = WakeWait()
        let woke = wait.wake(at: 100)
        let gen = try #require(woke)
        wait.fileArrived(at: 105)
        let again = wait.wake(at: 115)
        #expect(again == nil)
        #expect(wait.isCurrent(gen))
        #expect(!wait.fileCame)
        // The first wake's deadline (120) has passed, the second's (135) hasn't.
        #expect(!wait.shouldEnd(at: 125, pending: false))
        wait.fileArrived(at: 126)
        #expect(wait.shouldEnd(at: 126, pending: false))
    }

    /// The watch also wakes Sona right after a delivery, so the file can come first: it counts for a new hold if it
    /// came just before, not if it came long before (an earlier stop's).
    @Test func aFileJustBeforeTheWakeCounts() {
        var wait = WakeWait()
        wait.fileArrived(at: 99)
        _ = wait.wake(at: 100)
        #expect(wait.fileCame)
        #expect(wait.shouldEnd(at: 100.25, pending: false))

        var later = WakeWait()
        later.fileArrived(at: 90)
        _ = later.wake(at: 100)
        #expect(!later.fileCame)
    }

    /// Each hold has its own generation: once it ended, a wait loop of the old one isn't current for the new one.
    @Test func anOldLoopNeverEndsANewHold() throws {
        var wait = WakeWait()
        let firstWake = wait.wake(at: 100)
        let first = try #require(firstWake)
        wait.ended()
        let secondWake = wait.wake(at: 200)
        let second = try #require(secondWake)
        #expect(second != first)
        #expect(!wait.isCurrent(first))
        #expect(wait.isCurrent(second))
    }
}
