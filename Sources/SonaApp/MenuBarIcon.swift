import AppKit

/// The menu bar icon: the logo's wave (design/icon) as an 18 pt template image, with a look for each state. Drawn in
/// code on whole points, so it's sharp at 1x and 2x. Each state's image is made once and shared, so asking for it on
/// every status change or view update costs nothing; don't change a shared image (set labels on its button instead).
enum MenuBarIcon {
    enum State: String, CaseIterable, Sendable {
        case idle, hearing, paused, problem, loading, notSetUp = "not set up", off
    }

    @MainActor static func image(_ state: State) -> NSImage { images[state]! }

    @MainActor private static let images = Dictionary(uniqueKeysWithValues: State.allCases.map { ($0, make($0)) })

    private static func make(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The left edges of the wave's five columns: two points wide, a point apart, centred.
    private static let columns: [CGFloat] = [2, 5, 8, 11, 14]

    /// Idle: the wave at rest, five dots (the app's .:::. meter, quiet). Hearing: the dots rise into bars. Paused: two
    /// bars, a pause sign. A problem: an exclamation mark stands on the middle dot. Loading: three dots, an ellipsis.
    /// Not set up: one flat line, nothing connected yet. Off (always-on is off): the dots, dimmed.
    private static func draw(_ state: State) {
        NSColor(white: 0, alpha: state == .off ? 0.4 : 1).set()
        switch state {
        case .idle, .off:
            for x in columns { bar(x, 2) }
        case .hearing:
            for (x, height) in zip(columns, [4, 8, 12, 6, 10] as [CGFloat]) { bar(x, height) }
        case .paused:
            bar(6, 10)
            bar(10, 10)
        case .problem:
            for x in columns { bar(x, 2) }
            NSBezierPath(rect: NSRect(x: 8, y: 2, width: 2, height: 5)).fill()
        case .loading:
            for x in columns[1...3] { bar(x, 2) }
        case .notSetUp:
            NSBezierPath(rect: NSRect(x: 2, y: 8, width: 14, height: 2)).fill()
        }
    }

    /// A bar two points wide, centred on the middle of the image.
    private static func bar(_ x: CGFloat, _ height: CGFloat) {
        NSBezierPath(rect: NSRect(x: x, y: 9 - height / 2, width: 2, height: height)).fill()
    }
}
