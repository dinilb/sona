#if DEBUG
import SwiftUI
import UIKit
import WidgetKit

/// Draws the Live Activity and the widgets to PNGs with `ImageRenderer`, so they can be looked at without Xcode
/// previews or a phone. `scripts/widget-snapshots.sh` builds this file with the widgets' views into a small
/// executable and runs it in a simulator. Debug builds only.
///
/// These are the real views at the sizes the system gives them (the Lock Screen banner is 374 pt wide on a 402 pt
/// iPhone, the circular widget 76 pt, and so on) on a stand-in wallpaper. The Dynamic Island's shapes and where it
/// puts its regions are the system's, so those are only a sketch of it, with the sizes SpringBoard logs for an
/// iPhone 18 Pro: the camera is 94.7 by 36.7, the expanded island 374 wide with 18 pt all round and 84 to 160 tall.
@MainActor
enum WidgetSnapshots {
    private static let scale: CGFloat = 3

    /// Writes `sona-activity-*.png` and `sona-widget-*.png` into `directory` and returns their paths.
    @discardableResult
    static func renderAll(into directory: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        func write(_ name: String, _ view: some View) {
            written.append(png(named: name, of: view, in: directory))
        }

        // Live Activity, Lock Screen banner: a light and a dark Lock Screen.
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            write("sona-activity-lock-recording\(suffix)", banner(.sampleRecording, dark: dark))
            write("sona-activity-lock-first\(suffix)", banner(.sampleNoWave, dark: dark))
            write("sona-activity-lock-saved\(suffix)", banner(.sampleSaved, dark: dark))
            write("sona-activity-lock-long\(suffix)", banner(.sampleLong, dark: dark))
            write("sona-activity-lock-paused\(suffix)", banner(.samplePaused, dark: dark))
            write("sona-activity-lock-stale\(suffix)", banner(.sampleRecording, isStale: true, dark: dark))
            write("sona-activity-lock-stale-paused\(suffix)", banner(.samplePaused, isStale: true, dark: dark))
            write("sona-activity-lock-stopped\(suffix)", banner(.sampleStopped, dark: dark))
        }

        // Live Activity, Dynamic Island (sketched).
        write(
            "sona-activity-island-compact",
            Wallpaper {
                VStack(alignment: .leading, spacing: 10) {
                    Captioned("recording") { CompactIsland(state: .sampleRecording) }
                    Captioned("recording, no wave yet") { CompactIsland(state: .sampleNoWave) }
                    Captioned("an hour in") { CompactIsland(state: .sampleLong) }
                    Captioned("paused") { CompactIsland(state: .samplePaused) }
                    Captioned("stale: not recording") { CompactIsland(state: .sampleRecording, isStale: true) }
                    Captioned("saved") { CompactIsland(state: .sampleSaved) }
                    Captioned("stopped by itself") { CompactIsland(state: .sampleStopped) }
                    HStack(spacing: 16) {
                        Captioned("minimal") { MinimalIsland(state: .sampleRecording) }
                        Captioned("paused") { MinimalIsland(state: .samplePaused) }
                        Captioned("saved") { MinimalIsland(state: .sampleSaved) }
                    }
                }
            })
        write(
            "sona-activity-island-expanded",
            Wallpaper {
                VStack(spacing: 10) {
                    Captioned("recording") { ExpandedIsland(state: .sampleRecording) }
                    Captioned("paused") { ExpandedIsland(state: .samplePaused) }
                    Captioned("stale: not recording") { ExpandedIsland(state: .sampleRecording, isStale: true) }
                    Captioned("saved") { ExpandedIsland(state: .sampleSaved) }
                    Captioned("stopped by itself") { ExpandedIsland(state: .sampleStopped) }
                }
            })

        // Lock Screen widgets, drawn the way the Lock Screen does: white on a wallpaper.
        write(
            "sona-widget-lock-circular",
            Wallpaper {
                HStack(spacing: 14) {
                    Captioned("idle") { circular(.sampleIdle) }
                    Captioned("2 waiting") { circular(.sampleWaiting) }
                    Captioned("recording") { circular(.sampleRecording) }
                    Captioned("paused") { circular(.samplePaused) }
                }
            })
        write(
            "sona-widget-lock-rectangular",
            Wallpaper {
                VStack(alignment: .leading, spacing: 10) {
                    Captioned("nothing yet") { rectangular(.sampleIdle) }
                    Captioned("a note") { rectangular(.sampleNote) }
                    Captioned("2 waiting") { rectangular(.sampleWaiting) }
                    Captioned("long title, yesterday, 12 waiting") { rectangular(.sampleLongTitle) }
                    Captioned("recording") { rectangular(.sampleRecording) }
                    Captioned("paused") { rectangular(.samplePaused) }
                }
            })
        write(
            "sona-widget-lock-inline",
            Wallpaper {
                VStack(alignment: .leading, spacing: 10) {
                    Captioned("idle") { inline(.sampleIdle) }
                    Captioned("2 waiting") { inline(.sampleWaiting) }
                    Captioned("recording") { inline(.sampleRecording) }
                    Captioned("paused") { inline(.samplePaused) }
                }
            })

        // Home Screen widget.
        write(
            "sona-widget-home-small",
            Wallpaper(dark: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Captioned("nothing yet", dark: false) { small(.sampleIdle) }
                        Captioned("a note", dark: false) { small(.sampleNote) }
                        Captioned("2 waiting", dark: false) { small(.sampleWaiting) }
                    }
                    HStack(spacing: 14) {
                        Captioned("long title, 12 waiting", dark: false) { small(.sampleLongTitle) }
                        Captioned("recording", dark: false) { small(.sampleRecording) }
                        Captioned("tinted", dark: false) { small(.sampleWaiting, tinted: true) }
                    }
                    HStack(spacing: 14) {
                        Captioned("paused", dark: false) { small(.samplePaused) }
                    }
                }
            })
        return written
    }

    // MARK: - Widgets as the system draws them

    /// `dark`: a dark Lock Screen (the system's appearance), which turns the banner black.
    private static func banner(_ state: RecordingAttributes.ContentState, isStale: Bool = false, dark: Bool = false) -> some View {
        Wallpaper {
            RecordingBanner(state: state, isStale: isStale)
                .frame(width: 374)
                .background(BannerColors.background(dark ? .dark : .light))
                .clipShape(RoundedRectangle(cornerRadius: 23.5, style: .continuous))
                .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    private static func circular(_ status: SharedStatus) -> some View {
        LockCircular(status: status)
            .frame(width: 76, height: 76)
            .background(Circle().fill(.white.opacity(0.18)))
            .foregroundStyle(.white)
    }

    private static func rectangular(_ status: SharedStatus) -> some View {
        LockRectangular(status: status, now: .now)
            .frame(width: 172, height: 76)
            .foregroundStyle(.white)
    }

    private static func inline(_ status: SharedStatus) -> some View {
        LockInline(status: status)
            .font(.system(size: 14))
            .frame(width: 257, height: 26, alignment: .leading)
            .foregroundStyle(.white)
    }

    private static func small(_ status: SharedStatus, tinted: Bool = false) -> some View {
        HomeSmall(status: status, now: .now)
            .padding(16)
            .frame(width: 158, height: 158)
            .environment(\.widgetRenderingMode, tinted ? .accented : .fullColor)
            // A tinted Home Screen draws everything in white or its tint, on the system's own background.
            .environment(\.colorScheme, tinted ? .dark : .light)
            .background(tinted ? Color(white: 0.2) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Drawing

    private static func png(named name: String, of view: some View, in directory: URL) -> URL {
        let url = directory.appendingPathComponent("\(name).png")
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let data = renderer.uiImage?.pngData() else {
            print("could not draw \(name)")
            return url
        }
        do { try data.write(to: url) } catch { print("could not write \(url.path): \(error)") }
        return url
    }
}

// MARK: - Stand-ins for what the system draws around the views

/// Behind everything: a flat wallpaper, dark for the Lock Screen and light for the Home Screen.
private struct Wallpaper<Content: View>: View {
    var dark = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .background(dark ? Color(white: 0.16) : Color(red: 0.74, green: 0.79, blue: 0.83))
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// A view with what it is written under it.
private struct Captioned<Content: View>: View {
    var caption: String
    var dark = true
    var content: Content

    init(_ caption: String, dark: Bool = true, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.dark = dark
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            content
            Text(caption)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5))
        }
    }
}

/// The TrueDepth camera's place in the island, drawn a shade lighter than the island so it shows.
private struct CameraHint: View {
    var body: some View {
        Capsule().fill(Color(white: 0.09)).frame(width: 94.7, height: 36.7)
    }
}

/// The compact island: leading and trailing views either side of the camera.
private struct CompactIsland: View {
    var state: RecordingAttributes.ContentState
    var isStale = false

    var body: some View {
        let look = state.look(isStale: isStale)
        HStack(spacing: 0) {
            IslandCompactLeading(look: look, levels: state.levels).padding(.leading, 14).padding(.trailing, 8)
            CameraHint()
            IslandCompactTrailing(state: state, look: look).padding(.leading, 8).padding(.trailing, 14)
        }
        .frame(height: 36.7)
        .background(Capsule().fill(.black))
    }
}

private struct MinimalIsland: View {
    var state: RecordingAttributes.ContentState

    var body: some View {
        IslandMinimal(look: state.look(isStale: false))
            .frame(width: 36.7, height: 36.7)
            .background(Circle().fill(.black))
    }
}

/// The expanded island with the regions in their usual places: leading and trailing either side of the camera, the
/// middle under it.
private struct ExpandedIsland: View {
    var state: RecordingAttributes.ContentState
    var isStale = false

    var body: some View {
        let look = state.look(isStale: isStale)
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                IslandStatus(look: look).frame(maxWidth: .infinity, alignment: .leading)
                CameraHint()
                Group {
                    if !look.hasEnded { StopButton(inIsland: true) } else { Color.clear.frame(height: 1) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            IslandTimer(state: state, look: look)
            if !look.hasEnded { IslandWave(state: state, look: look) }
        }
        .padding(18)
        .frame(width: 374)
        .background(RoundedRectangle(cornerRadius: 48, style: .continuous).fill(.black))
    }
}
#endif
