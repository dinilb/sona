import Foundation

/// One line of the power log (`Power/YYYY-MM-DD.jsonl`): what Sona used over the last minute and what it was doing,
/// next to the battery. Nothing from the transcript. `sona power` sums them up.
public struct PowerSample: Codable, Equatable, Sendable {
    public var time: String
    public var seconds: Double
    /// Sona's average CPU over the interval, in percent of one core.
    public var cpu: Double
    /// Sona's average energy use over the interval, in milliwatts (the kernel's per-process energy counter).
    public var mW: Double?
    /// Resident memory, MB.
    public var memMB: Double
    /// Battery charge 0-100, and whether the Mac was on the charger. Nil: no battery.
    public var battery: Int?
    public var charging: Bool?
    /// What Sona was doing: mic open, Mac audio tap running, a conversation being turned into a note, someone heard.
    public var mic: Bool
    public var macTap: Bool
    public var processing: Bool
    public var hearing: Bool
    public var recording: Bool

    public init(
        time: Date, seconds: Double, cpu: Double, mW: Double?, memMB: Double, battery: Int?, charging: Bool?, mic: Bool,
        macTap: Bool, processing: Bool, hearing: Bool, recording: Bool
    ) {
        self.time = NoteWriter.iso(time)
        self.seconds = seconds
        self.cpu = cpu
        self.mW = mW
        self.memMB = memMB
        self.battery = battery
        self.charging = charging
        self.mic = mic
        self.macTap = macTap
        self.processing = processing
        self.hearing = hearing
        self.recording = recording
    }

    static var folder: URL { Paths.support.appendingPathComponent("Power") }

    public func append(at date: Date = Date()) {
        Paths.ensure(Self.folder)
        let url = Self.folder.appendingPathComponent("\(NoteWriter.dayString(date)).jsonl")
        guard var line = try? JSONEncoder().encode(self) else { return }
        line.append(10)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
    }

    public static func load(day: String) -> [PowerSample] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("\(day).jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(PowerSample.self, from: Data($0.utf8)) }
    }

    /// Time-weighted averages for the samples where `where` holds.
    public static func average(_ samples: [PowerSample], where keep: (PowerSample) -> Bool) -> (seconds: Double, cpu: Double, mW: Double?) {
        let rows = samples.filter(keep)
        let total = rows.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return (0, 0, nil) }
        let cpu = rows.reduce(0) { $0 + $1.cpu * $1.seconds } / total
        let energy = rows.compactMap { r in r.mW.map { ($0, r.seconds) } }
        let e = energy.reduce(0) { $0 + $1.1 }
        let mW = e > 0 ? energy.reduce(0) { $0 + $1.0 * $1.1 } / e : nil
        return (total, cpu, mW)
    }

    /// A readable summary of a day: what each activity cost on average, and how fast the battery fell on battery power.
    public static func summary(_ samples: [PowerSample]) -> String {
        guard !samples.isEmpty else { return "No power samples yet. Sona logs one a minute while it's open." }
        func row(_ name: String, _ keep: (PowerSample) -> Bool) -> String? {
            let a = average(samples, where: keep)
            guard a.seconds >= 30 else { return nil }
            let power = a.mW.map { String(format: "%6.0f mW", $0) } ?? "     n/a"
            return String(format: "%-34@ %5.1f%% CPU %@  (%.0f min)", name as NSString, a.cpu, power as NSString, a.seconds / 60)
        }
        var out = ["Sona's own use, averaged by what it was doing:"]
        let rows: [(String, (PowerSample) -> Bool)] = [
            ("everything", { _ in true }),
            ("idle (mic off)", { !$0.mic && !$0.processing }),
            ("mic on, quiet", { $0.mic && !$0.hearing && !$0.macTap && !$0.processing }),
            ("hearing someone", { $0.hearing && !$0.processing }),
            ("Mac audio tap running", { $0.macTap }),
            ("making a note", { $0.processing }),
        ]
        out += rows.compactMap { row($0.0, $0.1) }
        let off = samples.filter { $0.charging == false && $0.battery != nil }
        if let first = off.first, let last = off.last, let a = first.battery, let b = last.battery,
           let t0 = ISO8601DateFormatter().date(from: first.time), let t1 = ISO8601DateFormatter().date(from: last.time), t1.timeIntervalSince(t0) > 600 {
            out.append(String(format: "battery on battery power: %d%% to %d%% in %.0f min (the whole Mac, not just Sona)", a, b, t1.timeIntervalSince(t0) / 60))
        }
        return out.joined(separator: "\n")
    }
}
