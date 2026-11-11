import Darwin
import Foundation
import IOKit.ps
import NotesKit

/// Writes a `PowerSample` every minute: Sona's CPU time and energy since the last one (the kernel's own counters for
/// this process, read in microseconds), memory, and the battery. Cheap: no timers beyond the one, nothing per word.
@MainActor
final class PowerSampler {
    private var timer: Timer?
    private var last: (at: Date, cpuNs: UInt64, energyNj: UInt64)?
    /// Asked for what Sona is doing at each sample.
    var state: () -> (mic: Bool, macTap: Bool, processing: Bool, hearing: Bool, recording: Bool) = { (false, false, false, false, false) }

    func start(every seconds: TimeInterval = 60) {
        guard timer == nil else { return }
        _ = usage()  // the baseline
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        t.tolerance = seconds / 4  // lets macOS batch it with other wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func usage() -> (cpuNs: UInt64, energyNj: UInt64, memBytes: UInt64)? {
        var info = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } == 0
        }
        guard ok else { return nil }
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        let cpuTicks = info.ri_user_time + info.ri_system_time
        return (cpuTicks * UInt64(base.numer) / UInt64(base.denom), info.ri_energy_nj, info.ri_phys_footprint)
    }

    private func sample() {
        guard let now = usage() else { return }
        defer { last = (Date(), now.cpuNs, now.energyNj) }
        guard let last else { return }
        let seconds = Date().timeIntervalSince(last.at)
        guard seconds > 1 else { return }
        let cpu = Double(now.cpuNs &- last.cpuNs) / 1e9 / seconds * 100
        let joules = Double(now.energyNj &- last.energyNj) / 1e9
        let (battery, charging) = Self.battery()
        let s = state()
        PowerSample(
            time: Date(), seconds: seconds, cpu: cpu, mW: joules > 0 ? joules / seconds * 1000 : nil,
            memMB: Double(now.memBytes) / 1_048_576, battery: battery, charging: charging, mic: s.mic, macTap: s.macTap,
            processing: s.processing, hearing: s.hearing, recording: s.recording
        ).append()
    }

    static func battery() -> (Int?, Bool?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, nil) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                let cap = d[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            return (cap, (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return (nil, nil)
    }
}
