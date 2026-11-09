import Foundation
import LiveCore
import NotesKit

/// `LIVE_DICTATE` test runs (with `LIVE_FILE`): presses and releases the dictation key at set seconds of the test
/// file, through the same calls the key watcher makes, and writes each result to `dictations-test.jsonl` in the
/// test home instead of pasting it. Never posts a key event or touches the clipboard. `scripts/dictation-bench.sh`
/// scores the file.
@MainActor
final class TestDictation {
    typealias Hold = (down: Double, up: Double)

    private let dictation: Dictation
    private var events: [(at: Double, down: Bool)]
    private var held = false
    private var timer: DispatchSourceTimer?

    /// `"1.0-4.2,8.0-11.5"`: key down and up, in seconds of the test file.
    nonisolated static func parse(_ spec: String) -> [Hold] {
        spec.split(separator: ",").compactMap { part in
            let ends = part.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return ends.count == 2 && ends[1] > ends[0] ? (ends[0], ends[1]) : nil
        }
    }

    /// Starts once the test file is playing (`TestRun.clockStart` is set by then).
    init(_ holds: [Hold], dictation: Dictation) {
        self.dictation = dictation
        let start = TestRun.clockStart
        events = holds.flatMap { [(start + $0.down, true), (start + $0.up, false)] }.sorted { $0.at < $1.at }
        dictation.isKeyStillDown = { [weak self] in self?.held ?? false }
        dictation.testOutput = { report in Self.record(report) }
        // A strict 5 ms timer, not asyncAfter: that one's leeway grows with the delay.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.step() } }
        timer.resume()
        self.timer = timer
        Log.note("test run: \(holds.count) dictation(s) scheduled")
    }

    private func step() {
        let now = hostNow()
        while let next = events.first, now >= next.at {
            events.removeFirst()
            held = next.down
            if next.down { dictation.keyDown(at: next.at) } else { dictation.keyUp(at: next.at) }
        }
        if events.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    /// One JSON line per dictation, times in seconds of the test file.
    static func record(_ r: Dictation.Report) {
        let start = TestRun.clockStart
        var fields: [String: Any] = [
            "text": r.text, "outcome": r.outcome, "micWasOn": r.micWasOn,
            "down": r.pressed - start, "up": r.released - start, "done": r.done - start, "live": r.live,
            "no_tail": r.noTail,
        ]
        if let t = r.liveDone { fields["live_done"] = t - start }
        if let clip = r.clip, let t = r.clipDone {
            fields["clip"] = clip
            fields["clip_done"] = t - start
        }
        for (name, text, done) in r.extra {
            fields[name] = text
            fields[name + "_done"] = done - start
        }
        guard Paths.isTestHome, var line = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        line.append(10)
        let url = Paths.support.appendingPathComponent("dictations-test.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
