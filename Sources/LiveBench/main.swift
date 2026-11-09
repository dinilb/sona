import Foundation
import LiveCore

// sona-live-bench: plays an audio file at real-time speed into each streaming engine, as if it were
// the mic, and measures how long each word takes to reach the screen after it was spoken.
//   sona-live-bench test-audio/two-voices.wav [--engine unified320|eou160|apple|all] [--ref x.ref.json]
//     [--gate on|off] [--diarize fast|low|none]
//
// Ground truth is a reference transcript with word end times (`x.ref.json`, the JSON sidecar `sona file`
// writes, from the offline Parakeet TDT pass). Each engine's final words are aligned to it, and a word's
// latency is when the right word first showed up in its slot minus when the reference says it ended.
// That needs no timestamps from the engine itself, so engines that fudge them (Apple's do) are measured fairly.

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let engineArg = option("--engine") ?? "all"
/// `--mic 30`: listen to the real mic for 30 s instead of playing the file (play it out loud yourself).
let micSeconds = option("--mic").flatMap(Double.init)
/// `--diarize fast|low|none`: speaker separation alongside the Parakeet engines (default fast).
let diarizeArg = option("--diarize") ?? "fast"
let pauseArg = option("--pause").flatMap(Double.init)
/// `--flush off`: on a simulated fn release, wait for real audio instead of feeding the engine silence.
let flushArg = option("--flush") ?? "on"
/// `--gate on|off`: only feed the engine and diarizer while Silero VAD hears speech (default on).
let gateArg = option("--gate") ?? "on"
guard gateArg == "on" || gateArg == "off" else { print("--gate on|off"); exit(2) }
/// `--hangover 1.2`: seconds of silence before the gate closes.
let hangoverArg = option("--hangover").flatMap(Double.init)
var turnsPath = option("--turns")
var refPath = option("--ref")
guard let file = args.first else {
    print("usage: sona-live-bench <audio file> [--engine unified320|eou160|apple|all] [--turns file.turns.tsv]")
    exit(2)
}
let url = URL(fileURLWithPath: file)
if refPath == nil {
    let guess = url.deletingPathExtension().appendingPathExtension("ref.json").path
    if FileManager.default.fileExists(atPath: guess) { refPath = guess }
}
if turnsPath == nil {
    let guess = url.deletingPathExtension().appendingPathExtension("turns.tsv").path
    if FileManager.default.fileExists(atPath: guess) { turnsPath = guess }
}

/// start, end, text
let turns: [(Double, Double, String)] = (turnsPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
    .split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", maxSplits: 3).map(String.init)
        guard f.count == 4, let s = Double(f[0]), let e = Double(f[1]) else { return nil }
        return (s, e, f[3])
    }

struct RefWord: Decodable { let word: String; let end: Double }
struct RefFile: Decodable { let words: [RefWord] }
/// (normalised word, end seconds), one per normalised piece.
let reference: [(String, Double)] = (refPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) })
    .flatMap { try? JSONDecoder().decode(RefFile.self, from: $0) }?.words
    .flatMap { w in words(w.word).map { ($0, w.end) } } ?? []

/// Pairs (ref index, hyp index) of equal words on a minimum-edit alignment.
func align(_ ref: [String], _ hyp: [String]) -> [(Int, Int)] {
    let n = ref.count, m = hyp.count
    guard n > 0, m > 0 else { return [] }
    var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { d[i][0] = i }
    for j in 0...m { d[0][j] = j }
    for i in 1...n {
        for j in 1...m {
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
        }
    }
    var pairs: [(Int, Int)] = []
    var i = n, j = m
    while i > 0, j > 0 {
        if ref[i - 1] == hyp[j - 1], d[i][j] == d[i - 1][j - 1] { pairs.append((i - 1, j - 1)); i -= 1; j -= 1 }
        else if d[i][j] == d[i - 1][j - 1] + 1 { i -= 1; j -= 1 }
        else if d[i][j] == d[i - 1][j] + 1 { i -= 1 }
        else { j -= 1 }
    }
    return pairs.reversed()
}

@Sendable func words(_ s: String) -> [String] {
    s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
}

/// Word error rate (plain edit distance over lowercase words). Rough: "forty" vs "40" counts as wrong.
func wer(_ ref: [String], _ hyp: [String]) -> Double {
    guard !ref.isEmpty else { return 0 }
    var prev = Array(0...hyp.count)
    for i in 1...ref.count {
        var cur = [i] + Array(repeating: 0, count: hyp.count)
        for j in stride(from: 1, through: hyp.count, by: 1) {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return Double(prev[hyp.count]) / Double(ref.count)
}

func fmt(_ x: Double?) -> String { x.map { String(format: "%4.0f", $0) } ?? "   -" }

// @unchecked: the update callback and the release thread write under `lock`; the report reads after the session ends.
final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var heard = LatencyStats()
    var locked = LatencyStats()
    /// (audio time, host time it appeared) for every first-seen word.
    var events: [(Double, Double)] = []
    var text = ""
    var volatile = ""
    /// What was on screen after each update: (host time, words).
    var snapshots: [(Double, [String])] = []
    /// Session time of every token, and fn-style releases: (ms from release to "caught up", tokens by then, release time).
    var tokenStarts: [Double] = []
    var releases: [(ms: Double, tokens: Int, at: Double)] = []
    let transcript: LiveTranscript = {
        let t = LiveTranscript()
        if let pauseArg { t.pauseSeconds = pauseArg }
        return t
    }()
    /// Word spoken (its last token) to its speaker label settling, ms.
    var labelLag = LatencyStats()
}

let kinds: [EngineKind] = engineArg == "all" ? EngineKind.allCases.filter(\.isAvailable) : [EngineKind(rawValue: engineArg)].compactMap { $0 }
guard !kinds.isEmpty else { print("unknown engine \(engineArg)"); exit(2) }

for kind in kinds {
    let engine = kind.make()
    print("\n== \(engine.name)  (model's own delay: \(engine.modelDelay))")
    do {
        let t = hostNow()
        try await engine.prepare { p, phase in
            print(String(format: "\r  %3.0f%% %@", p * 100, phase), terminator: "")
        }
        print(String(format: "\r  ready in %.1f s%@", hostNow() - t, String(repeating: " ", count: 40)))

        let source: LiveAudioSource = micSeconds != nil ? MicSource() : try FileSource(url: url)
        var diarizer: LiveDiarizer?
        if kind.hasTimings, diarizeArg != "none" {
            let d = LiveDiarizer(preset: diarizeArg)
            let t = hostNow()
            try await d.prepare { p, phase in print(String(format: "\r  %3.0f%% %@", p * 100, phase), terminator: "") }
            print(String(format: "\r  speakers: Nemotron 3 %@ (settles %@ after the audio), ready in %.1f s%@", diarizeArg, d.delay, hostNow() - t, String(repeating: " ", count: 30)))
            diarizer = d
        }
        let session = LiveSession(engine: engine, source: source, diarizer: diarizer)
        session.voiceGate = gateArg == "on"
        if let hangoverArg { session.gateConfig.hangoverSeconds = hangoverArg }
        if let micSeconds {
            print("  listening to the mic for \(Int(micSeconds)) s")
            DispatchQueue.global().asyncAfter(deadline: .now() + micSeconds) { session.cancel() }
        }
        let rec = Recorder()
        let clock = source.clock
        // Dictation as if fn were let go at the real end of each sentence: how long until it would paste,
        // and were all that sentence's words in by then?
        if micSeconds == nil, kind.hasTimings, !turns.isEmpty {
            let ends = turns.map(\.1)
            Thread.detachNewThread {
                for end in ends {
                    while clock.hostTime(atSeconds: end).map({ hostNow() < $0 }) ?? true { usleep(2_000) }
                    let released = hostNow()
                    if flushArg != "off" { session.flush() }
                    while !session.hasDecoded(through: end + 0.12), hostNow() - released < 1.0 { usleep(2_000) }
                    let ms = (hostNow() - released) * 1000
                    rec.lock.lock()
                    rec.releases.append((ms, rec.tokenStarts.filter { $0 <= end + 0.12 }.count, end))
                    rec.lock.unlock()
                }
            }
        }
        try await session.run { update in
            let now = hostNow()
            rec.lock.lock()
            defer { rec.lock.unlock() }
            for s in update.heard {
                if let ms = clock.lagMs(atSeconds: s, now: now) { rec.heard.add(ms) }
                rec.events.append((s, now))
            }
            for s in update.locked { if let ms = clock.lagMs(atSeconds: s, now: now) { rec.locked.add(ms) } }
            rec.text += update.appendFinal
            if let v = update.volatile { rec.volatile = v }
            rec.transcript.add(update.tokens)
            rec.tokenStarts += update.tokens.map(\.start)
            rec.transcript.speakers.append(update.speakerFrames)
            for i in rec.transcript.resolveSpeakers() {
                let w = rec.transcript.words[i - rec.transcript.dropped]
                if let ms = clock.lagMs(atSeconds: w.last + 0.08, now: now) { rec.labelLag.add(ms) }
            }
            rec.snapshots.append((now, words(rec.text + " " + rec.volatile)))
        }

        if let mic = source as? MicSource {
            print(String(format: "  mic: %@, IO block %.1f ms, %d samples dropped", mic.deviceDescription, mic.ioBufferMs, mic.droppedSamples))
        }
        let real = max(session.audioSeconds, 0.001)
        let busy = session.computeSeconds + session.vadSeconds + session.diarizerSeconds
        print(String(format: "  gate %@: fed %.1f of %.1f s; compute engine %.2f s + VAD %.2f s + speakers %.2f s = %.2f s (%.1f%% of real time)",
            session.gateActive ? "on" : "off", session.fedSeconds, session.audioSeconds, session.computeSeconds,
            session.vadSeconds, session.diarizerSeconds, busy, busy / real * 100))
        print("  audio \(String(format: "%.1f", session.audioSeconds)) s, compute \(String(format: "%.2f", session.computeSeconds)) s (\(String(format: "%.0f", session.computeSeconds / max(session.audioSeconds, 0.001) * 100))% of real time), slowest step \(String(format: "%.0f", session.slowestFeedMs)) ms")
        if !reference.isEmpty, micSeconds == nil {
            let final = words(rec.text)
            var shown = LatencyStats()
            for (r, h) in align(reference.map(\.0), final) {
                guard let first = rec.snapshots.first(where: { $0.1.count > h && $0.1[h] == final[h] }),
                    let spoken = clock.hostTime(atSeconds: reference[r].1)
                else { continue }
                shown.add((first.0 - spoken) * 1000)
            }
            print("  WORD SPOKEN -> RIGHT WORD ON SCREEN (ms):  p50 \(fmt(shown.percentile(50)))  p95 \(fmt(shown.percentile(95)))  max \(fmt(shown.max))  matched \(shown.count)/\(reference.count) words")
        }
        print("  by the engine's own timestamps (ms):        p50 \(fmt(rec.heard.percentile(50)))  p95 \(fmt(rec.heard.percentile(95)))  max \(fmt(rec.heard.max))  n=\(rec.heard.count)")
        // The release thread can still be finishing its last sentence: copy what it has under the lock.
        let releases = rec.lock.withLock { rec.releases }
        if !releases.isEmpty {
            var delay = LatencyStats()
            var missing = 0
            for r in releases {
                delay.add(r.ms)
                let late = rec.tokenStarts.filter { $0 <= r.at + 0.12 }.count - r.tokens
                missing += late
                if late > 0 {
                    let gap = rec.tokenStarts.filter { $0 <= r.at + 0.12 }.suffix(late).map { String(format: "%.2f", $0) }
                    print(String(format: "    release at %.2f s: %d token(s) came later (at %@), waited %.0f ms", r.at, late, gap.joined(separator: ","), r.ms))
                }
            }
            print("  FN RELEASE -> PASTE (ms, at the end of each sentence): p50 \(fmt(delay.percentile(50)))  p95 \(fmt(delay.percentile(95)))  max \(fmt(delay.max))  n=\(delay.count); tokens that would have been cut off: \(missing)")
        }
        if kind == .apple {
            print("  locked in (final), engine's timestamps:     p50 \(fmt(rec.locked.percentile(50)))  p95 \(fmt(rec.locked.percentile(95)))  max \(fmt(rec.locked.max))  n=\(rec.locked.count)")
        }

        if !turns.isEmpty, micSeconds == nil {
            let ref = turns.flatMap { words($0.2) }
            print(String(format: "  rough WER vs script: %.1f%%", wer(ref, words(rec.text)) * 100))
        }
        if session.diarizer != nil, micSeconds == nil, !turns.isEmpty {
            let words = rec.transcript.words.filter(\.resolved)
            // Which real speaker each word belongs to, from the script's turn times.
            func truth(_ t: Double) -> String? { turns.first { t >= $0.0 - 0.1 && t <= $0.1 + 0.3 }.map { line in
                (try? String(contentsOfFile: turnsPath!, encoding: .utf8))?.split(separator: "\n")
                    .first { $0.hasPrefix(String(format: "%.2f\t", line.0)) }.map { String($0.split(separator: "\t")[2]) } ?? "?"
            } }
            var pairs: [String: [String: Int]] = [:]
            var total = 0
            for w in words {
                guard let real = truth(w.start) else { continue }
                pairs[w.speaker.map { "S\($0 + 1)" } ?? "none", default: [:]][real, default: 0] += 1
                total += 1
            }
            // Each live slot counts as whichever real voice it matched most.
            let right = pairs.values.map { $0.values.max() ?? 0 }.reduce(0, +)
            let slots = pairs.keys.sorted().map { k in "\(k)→" + (pairs[k]!.max { $0.value < $1.value }?.key ?? "?") }
            let lines = rec.transcript.lines()
            let caught = turns.dropFirst().filter { turn in
                lines.contains { l in
                    let w = rec.transcript.words[l.id - rec.transcript.dropped]
                    return w.start >= turn.0 - 0.3 && w.start <= turn.0 + 1.0
                }
            }.count
            print(String(format: "  SPEAKERS: %.1f%% of words on the right speaker (%d words; %@)", Double(right) / Double(max(total, 1)) * 100, total, slots.joined(separator: ", ")))
            print("  speaker label settles after the word (ms):  p50 \(fmt(rec.labelLag.percentile(50)))  p95 \(fmt(rec.labelLag.percentile(95)))  max \(fmt(rec.labelLag.max))")
            print("  lines: \(lines.count) for \(turns.count) real turns; \(caught)/\(turns.count - 1) speaker changes start a new line")
            for l in lines.prefix(6) { print("    [\(l.speaker.map { "Speaker \($0 + 1)" } ?? "?")] \(l.text.prefix(90))") }
        }
        print("  text: \(rec.text.trimmingCharacters(in: .whitespaces).prefix(300))...")
    } catch {
        print("  failed: \(error)")
    }
}
