import SwiftUI

/// The Mac app's look (Sources/SonaApp/Theme.swift) for the iPhone, the watch and their widgets: warm paper, ink, one
/// grey, hairlines, nothing blue. Red only means "recording" (and problems). What was said is in the system sans;
/// what's about it (times, speakers, status) is small grey mono, in lowercase.
enum SonaTheme {
    static let paper = rgb(0xFAF9F6)
    static let sidebar = rgb(0xF3F1EC)
    static let ink = rgb(0x1F1E1C)
    static let grey = rgb(0x8C8983)
    static let hairline = rgb(0xE6E3DD)
    /// Recording only (8 Nov 2026 redesign): the record button, the live wave and Stop, on the iPhone, the watch and the
    /// widgets. Everything else is monochrome (.primary and greys). The system red, like Voice Memos: an orange brand
    /// colour was tried and dropped as too loud.
    static let accent = Color.red
    /// Problems (and, until the redesign reaches every screen, recording).
    static let red = rgb(0xB0443A)
    /// The same red on black (the Dynamic Island, a dark Lock Screen), where the darker one sinks.
    static let brightRed = rgb(0xE5584C)

    static let mono = Font.system(size: 12, design: .monospaced)

    private static func rgb(_ hex: Int) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
