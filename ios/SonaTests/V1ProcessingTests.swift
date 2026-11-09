import Foundation
import NotesKit
import SonaEngine
import Testing
@testable import Sona

/// v1 processing: which recording goes next (R1-2), the charging task's expiry (R1-1), and failed recordings (R3-4).
struct V1ProcessingTests {
    /// In the foreground one never tried goes first, so a recording that keeps killing the app can't hold up the
    /// newer ones; with none untried, the first.
    @Test func theForegroundTakesANeverTriedRecordingFirst() {
        let tries = ["old": 2, "new": 0, "newer": 0]
        let pick = { (queue: [String], background: Bool) in
            NotesService.nextIndex(in: queue, background: background, tries: { tries[$0] ?? 0 })
        }
        #expect(pick(["old", "new", "newer"], false) == 1)
        #expect(pick(["old"], false) == 0)
        #expect(pick([], false) == nil)
        // The charging task never starts one on its last attempt (a background failure must never fail it for good).
        #expect(pick(["old", "new"], true) == 1)
        #expect(pick(["old"], true) == nil)
    }

    /// The charging task's expiration handler gives the cut-short try back itself, before it completes the task,
    /// even when that try had moved the recording to Spool/failed.
    @Test func theChargingTasksExpiryGivesTheTryBack() throws {
        let spool = Spool(dir: makeTempDir())
        var entry = SpoolEntry(id: "20261107-090000-ABCD", startedAt: Date())
        entry.closed = true
        entry.attempts = 2
        try makeSpoolWAV(spool.wav(entry.id), seconds: 1)
        spool.save(entry)
        let id = entry.id
        // Off screen (the test host app is on screen): there the try is cut short.
        let wasOnScreen = NotesService.onScreen.withLock { $0 }
        NotesService.onScreen.withLock { $0 = false }
        NotesService.inFlight.withLock { $0 = (id: id, attempts: 1, spool: spool) }
        defer {
            NotesService.inFlight.withLock { $0 = nil }
            NotesService.onScreen.withLock { $0 = wasOnScreen }
        }

        // On screen the app carries on with the note, so the try isn't cut short and keeps its attempt.
        NotesService.onScreen.withLock { $0 = true }
        NotesService.backgroundTaskExpiring()
        #expect(spool.load(id)?.attempts == 2)
        NotesService.onScreen.withLock { $0 = false }

        NotesService.backgroundTaskExpiring()
        #expect(spool.load(id)?.attempts == 1)

        // Its last try, which moved it to Spool/failed: back in the spool.
        entry.attempts = 3
        spool.save(entry)
        spool.fail(id)
        NotesService.inFlight.withLock { $0 = (id: id, attempts: 2, spool: spool) }
        NotesService.backgroundTaskExpiring()
        #expect(spool.load(id)?.attempts == 2)
        #expect(spool.failedCount() == 0)

        // Nothing being transcribed: nothing to do.
        NotesService.inFlight.withLock { $0 = nil }
        NotesService.backgroundTaskExpiring()
        #expect(spool.load(id)?.attempts == 2)
    }

    /// A recording that failed this launch goes back in the queue with "Try again" on the banner, like the ones in
    /// Spool/failed.
    @MainActor @Test func tryAgainCoversSpoolFailed() throws {
        let id = "20261103-090000-ABCD"
        let spool = try NotesLocationMoveTests.spoolWithAFailure(id)
        let service = NotesService(spool: spool)
        #expect(service.retryFailed() == 1)
        #expect(service.queue == [id])
        #expect(service.failedIDs.isEmpty)
        #expect(service.transcribingID == nil)
    }
}
