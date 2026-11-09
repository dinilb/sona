import AVFoundation
import SwiftUI

/// A note's whole recording as a wave: the part played so far in the text colour, the rest light grey. Drag or tap it
/// to move the playhead. Monochrome on purpose: red is only for recording.
struct PlaybackWave: View {
    /// Loudness across the recording, 0...1 (`AudioPeaks`); nil while it's being read (flat dots meanwhile).
    var peaks: [Float]?
    /// 0...1.
    var progress: Double
    var seek: (Double) -> Void

    private let barWidth: CGFloat = 2.5
    private let gap: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let count = max(1, Int((size.width + gap) / (barWidth + gap)))
            let levels = AudioPeaks.resample(peaks ?? [], to: count)
            for i in 0..<count {
                let level = CGFloat(levels.isEmpty ? 0 : levels[i])
                let height = max(barWidth, size.height * level)
                let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: (size.height - height) / 2, width: barWidth, height: height)
                let played = (Double(i) + 0.5) / Double(count) <= progress
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(played ? Color.primary : Color(uiColor: .tertiaryLabel)))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in scrub(to: value.location.x) }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @State private var width: CGFloat = 1

    private func scrub(to x: CGFloat) {
        seek(min(1, max(0, Double(x / max(width, 1)))))
    }
}

/// A recording's loudness for its wave, read once off the main thread.
nonisolated enum AudioPeaks {
    /// How many it keeps: more than a phone-wide wave draws, so it resamples down without looking blocky.
    static let count = 160

    /// `count` levels (0...1) across the file: each the loudness (RMS, in dB, scaled like the live wave) of its share
    /// of the audio. Nil if the file can't be read.
    static func load(_ url: URL, count: Int = count) -> [Float]? {
        guard count > 0, let file = try? AVAudioFile(forReading: url) else { return nil }
        let total = file.length
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768) else {
            return nil
        }
        var sums = [Double](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: count)
        var position: AVAudioFramePosition = 0
        while position < total {
            do { try file.read(into: buffer) } catch { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let samples = buffer.floatChannelData?[0] else { break }
            for i in 0..<n {
                let bucket = min(count - 1, Int((position + AVAudioFramePosition(i)) * AVAudioFramePosition(count) / total))
                let v = Double(samples[i])
                sums[bucket] += v * v
                counts[bucket] += 1
            }
            position += AVAudioFramePosition(n)
        }
        return (0..<count).map { i in
            guard counts[i] > 0 else { return 0 }
            let rms = (sums[i] / Double(counts[i])).squareRoot()
            return AudioLevel.unit(rms > 0 ? max(-100, 20 * log10(rms)) : -100)
        }
    }

    /// `levels` squeezed or stretched to `count`: the loudest of each share, so short words don't vanish.
    static func resample(_ levels: [Float], to count: Int) -> [Float] {
        guard !levels.isEmpty, count > 0 else { return [] }
        return (0..<count).map { i in
            let from = i * levels.count / count
            let to = max(from + 1, (i + 1) * levels.count / count)
            return levels[from..<min(to, levels.count)].max() ?? 0
        }
    }
}
