import AppKit
import SwiftUI

/// The look, on every screen and the dictation pill: warm paper, ink, one grey and hairlines, always light, nothing
/// blue. What was said is in the system sans; what's about it (times, speakers, headers, status) is small grey mono,
/// in lowercase. Everything here is drawn by SwiftUI, so headless renders look like the window.
enum Theme {
    static let paper = rgb(0xFAF9F6)
    static let sidebar = rgb(0xF3F1EC)
    static let ink = rgb(0x1F1E1C)
    static let grey = rgb(0x8C8983)
    static let hairline = rgb(0xE6E3DD)
    /// A selected row.
    static let selected = rgb(0x1F1E1C).opacity(0.07)
    /// Problems only.
    static let alert = rgb(0xB0443A)

    /// What was said.
    static let text = Font.system(size: 15)
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 12)
    static let title = Font.system(size: 20, weight: .semibold)
    static let mono = Font.system(size: 11, design: .monospaced)

    static let pad: CGFloat = 24

    private static func rgb(_ hex: Int) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// A transcript line's words.
    static func words(_ text: String) -> some View {
        Text(text)
            .font(Theme.text)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Small grey mono, in lowercase: speakers, times, section headers, status.
    static func meta(_ text: String, keepCase: Bool = false) -> some View {
        Text(keepCase ? text : text.lowercased()).font(mono).foregroundStyle(grey).lineLimit(1)
    }

    /// A speaker: "Speaker 2" in lowercase like the rest, a name as it was written.
    static func speaker(_ name: String) -> some View { meta(speakerName(name), keepCase: true) }

    static func speakerName(_ name: String) -> String {
        name.hasPrefix("Speaker ") && Int(name.dropFirst(8)) != nil ? name.lowercased() : name
    }

    /// A progress bar.
    static func bar(_ p: Double) -> some View {
        Capsule().fill(hairline)
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(ink).frame(width: g.size.width * min(max(p, 0), 1)) }
            }
            .frame(height: 4)
    }
}

/// A one-pixel rule.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle().fill(Theme.hairline).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A text button: small mono ink, dimmed while pressed.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono.weight(.medium))
            .foregroundStyle(Theme.ink)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

/// The one filled button (Start): ink with paper text.
struct ProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body.weight(.medium))
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 22)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Rectangle())
    }
}

/// A checkbox in ink.
struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? Theme.ink : Theme.paper)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(configuration.isOn ? Theme.ink : Theme.grey.opacity(0.6)))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.paper)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { $0.height - 3 }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox) }
    }
}

/// A switch drawn by SwiftUI, for headless renders only (the window uses the native one, tinted ink).
struct DrawnSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Capsule()
                .fill(configuration.isOn ? Theme.ink : Theme.grey.opacity(0.3))
                .frame(width: 32, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2)
                }
        }
    }
}

extension NSWindow {
    /// One flat paper surface: the content runs under a transparent title bar, the traffic lights stay.
    func usePaperLook() {
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = NSColor(Theme.paper)
    }
}
