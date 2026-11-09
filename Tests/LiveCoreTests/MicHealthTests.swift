import XCTest

@testable import LiveCore

/// The mic's open/reopen rules, driven with made-up times.
final class MicHealthTests: XCTestCase {
    /// Wanted at `t`, opened right away, audio flowing.
    private func running(at t: Double = 0) -> MicHealth {
        var h = MicHealth()
        XCTAssertEqual(h.setWanted(true, now: t), [.open])
        h.opened(now: t)
        h.heard(at: t + 0.01)
        return h
    }

    /// Ticks every 0.5 s from `from` to `to`, counting opens (each one is carried out at once, with no audio).
    private func opens(_ h: inout MicHealth, from: Double, to: Double) -> [Double] {
        var at: [Double] = []
        var t = from
        while t <= to + 1e-9 {
            if h.tick(now: t).contains(.open) {
                at.append(t)
                h.opened(now: t)
            }
            t += 0.5
        }
        return at
    }

    func testWantingOpensAndNotWantingCloses() {
        var h = MicHealth()
        XCTAssertEqual(h.state, .off)
        XCTAssertEqual(h.tick(now: 0), [], "nothing happens while it isn't wanted")
        XCTAssertEqual(h.setWanted(true, now: 1), [.open])
        XCTAssertEqual(h.state, .starting)
        h.opened(now: 1.1)
        XCTAssertEqual(h.state, .starting, "open isn't running until audio comes")
        h.heard(at: 1.12)
        XCTAssertEqual(h.state, .running)
        XCTAssertEqual(h.setWanted(true, now: 2), [], "asking again changes nothing")
        XCTAssertEqual(h.setWanted(false, now: 3), [.close])
        XCTAssertEqual(h.state, .off)
        XCTAssertFalse(h.isOpen)
        XCTAssertEqual(h.setWanted(false, now: 4), [])
    }

    func testFailedOpensRetryWithBackoffAndSayWhy() {
        var h = MicHealth()
        XCTAssertEqual(h.setWanted(true, now: 0), [.open])
        var t = 0.0
        var tries: [Double] = []
        // Every open fails: retries come 1, 2, 4, 8, 16, 32, 60, 60 s apart.
        for _ in 0..<8 {
            h.openFailed("No microphone found", now: t)
            XCTAssertEqual(h.state, .problem("No microphone found"))
            let due = try! XCTUnwrap(h.openAt)
            XCTAssertEqual(h.tick(now: due - 0.01), [], "not before it's due")
            XCTAssertEqual(h.tick(now: due), [.open])
            tries.append(due - t)
            t = due
        }
        XCTAssertEqual(tries, [1, 2, 4, 8, 16, 32, 60, 60])
        // Then it works: running, and the count starts over.
        h.opened(now: t)
        h.heard(at: t + 0.02)
        XCTAssertEqual(h.state, .running)
        XCTAssertEqual(h.failures, 0)
    }

    func testDeviceChangesAreDebounced() {
        var h = running()
        h.devicesChanged(now: 10)
        h.devicesChanged(now: 10.3)
        h.devicesChanged(now: 10.6)
        XCTAssertEqual(h.tick(now: 11.0), [], "0.5 s after the last change, not the first")
        XCTAssertEqual(h.tick(now: 11.1), [.open])
        h.opened(now: 11.1)
        XCTAssertEqual(h.tick(now: 11.2), [], "one reopen for the burst")
        XCTAssertEqual(h.state, .running, "a planned reopen doesn't flash a problem")
    }

    func testWakeReopensAfterASecond() {
        var h = running()
        h.heard(at: 5)
        h.woke(now: 6)
        XCTAssertEqual(h.tick(now: 6.5), [])
        XCTAssertEqual(h.tick(now: 7), [.open])
        // A device change right after the wake doesn't bring the reopen forward.
        var g = running()
        g.woke(now: 6)
        g.devicesChanged(now: 6.1)
        XCTAssertEqual(g.tick(now: 6.6), [], "the wake's settle still runs")
        XCTAssertEqual(g.tick(now: 7), [.open])
        var k = running()
        k.devicesChanged(now: 6)
        k.woke(now: 6.1)
        XCTAssertEqual(k.tick(now: 6.6), [], "the wake's 1 s wins over an earlier change")
        XCTAssertEqual(k.tick(now: 7.1), [.open])
    }

    func testWatchdogReopensAfterSixSecondsWithoutAudio() {
        var h = running(at: 0)
        // Audio keeps it alive.
        for t in stride(from: 0.5, through: 30, by: 0.5) {
            h.heard(at: t)
            XCTAssertEqual(h.tick(now: t), [])
        }
        // Then nothing for 6 s.
        XCTAssertEqual(h.tick(now: 35.5), [])
        XCTAssertEqual(h.tick(now: 36), [.open])
        XCTAssertEqual(h.state, .starting, "the first silent reopen is quiet")
    }

    func testWatchdogBacksOffWhileSilentAndResetsOnAudio() {
        var h = running(at: 0)
        // Silent from 0.01 s on: first reopen at 6 s, then 1, 2, 4, 8, 16, 32, 60, 60 s after each reopen.
        let at = opens(&h, from: 0.5, to: 300)
        let gaps = zip(at.dropFirst(), at).map { $0 - $1 }
        XCTAssertEqual(at.first ?? 0, 6.0, accuracy: 0.5)
        XCTAssertEqual(Array(gaps.prefix(8)), [1, 2, 4, 8, 16, 32, 60, 60])
        if case .problem(let why) = h.state {
            XCTAssertTrue(why.contains("isn't sending"), why)
        } else {
            XCTFail("a mic that stays silent is a problem, got \(h.state)")
        }
        // Sound again: running, and the next silence gets the full 6 s.
        let t = at.last! + 0.5
        h.heard(at: t)
        XCTAssertEqual(h.state, .running)
        XCTAssertEqual(h.failures, 0)
        XCTAssertEqual(h.tick(now: t + 5.5), [])
        XCTAssertEqual(h.tick(now: t + 6), [.open])
    }

    func testAudioFromBeforeAReopenDoesntCount() {
        var h = running(at: 0)
        XCTAssertEqual(opens(&h, from: 0.5, to: 6.5), [6.5], "silent reopen")
        h.heard(at: 6.4)  // a late chunk from the old engine
        XCTAssertEqual(h.failures, 1, "stale audio doesn't reset the backoff")
        XCTAssertEqual(h.tick(now: 7.5), [.open], "and doesn't keep the dead mic alive")
    }

    func testANewDeviceOrAWakeCutsABackoffShort() {
        var h = MicHealth()
        _ = h.setWanted(true, now: 0)
        var t = 0.0
        for _ in 0..<6 {
            h.openFailed("No microphone found", now: t)
            t = h.openAt!
            _ = h.tick(now: t)
        }
        h.openFailed("No microphone found", now: t)
        XCTAssertEqual(h.openAt! - t, 60, "deep in the backoff")
        h.devicesChanged(now: t + 1)  // a mic was plugged in: retried within seconds, not a minute
        XCTAssertEqual(h.tick(now: t + 1.5), [])
        XCTAssertEqual(h.tick(now: t + 6), [.open])
        XCTAssertEqual(h.failures, 7, "only real audio resets the failures")
        h.opened(now: t + 6)
        h.heard(at: t + 6.5)
        XCTAssertEqual(h.failures, 0)
    }

    func testEventsWhileNotWantedDoNothing() {
        var h = MicHealth()
        h.devicesChanged(now: 1)
        h.woke(now: 2)
        h.openFailed("x", now: 3)
        h.heard(at: 4)
        XCTAssertEqual(h.tick(now: 10), [])
        XCTAssertEqual(h.state, .off)
        // Pausing mid-retry drops the pending retry.
        var r = MicHealth()
        _ = r.setWanted(true, now: 0)
        r.openFailed("Couldn't open the mic", now: 0)
        XCTAssertEqual(r.setWanted(false, now: 0.5), [])
        XCTAssertNil(r.openAt)
        XCTAssertEqual(r.tick(now: 100), [])
    }

    /// Devices flapping (a virtual driver coming and going) after failures: at most one reopen per 5 s.
    func testFlappingDevicesDontReopenTwiceASecond() {
        var h = MicHealth()
        _ = h.setWanted(true, now: 0)
        _ = h.tick(now: 0)
        h.openFailed("engine stopped", now: 1)
        var opens = 0
        var t = 1.0
        while t < 31 {
            h.devicesChanged(now: t)
            if h.tick(now: t) == [.open] {
                opens += 1
                h.openFailed("engine stopped", now: t)
            }
            t += 0.5
        }
        XCTAssertLessThanOrEqual(opens, 6)
    }
}
