import SwiftUI

/// A live waveform: one bar per level (0...1), newest on the right. Proof the mic is hearing you, which is all the
/// screen needs while recording (no live words: the note is written once, after). It scrolls on its own clock at
/// every frame (`WaveScroll`), not when levels land: they come unevenly, and bars drawn as they came stalled and
/// jumped.
struct Waveform: View {
    var wave: WaveScroll
    /// How many bars across: no more than `WaveScroll.keep`, or the left end is only dots.
    var bars = 48
    var gap: CGFloat = 3
    var color: Color = SonaTheme.accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: wave.samples.isEmpty)) { timeline in
            Canvas { context, size in
                let width = max(1, (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars))
                // Bars sliding in or out at the edges are cut there.
                context.clip(to: Path(CGRect(origin: .zero, size: size)))
                for bar in wave.bars(at: timeline.date.timeIntervalSinceReferenceDate, count: bars) {
                    let height = max(width, size.height * CGFloat(min(1, bar.level)))
                    let x = size.width - width - CGFloat(bar.position) * (width + gap)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: width / 2),
                        with: .color(color.opacity(bar.level > 0.02 ? 1 : 0.25)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    let now = Date().timeIntervalSinceReferenceDate
    var wave = WaveScroll()
    for i in 0..<60 {
        let heard = now - 6 + Double(i) / WaveScroll.rate
        wave.add(Float(abs(sin(Double(i) / 3))), heard: heard, arrived: heard + 0.1)
    }
    return Waveform(wave: wave)
        .frame(height: 60)
        .padding()
}
