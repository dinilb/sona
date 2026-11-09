// Builds the app icon with nothing but macOS: AppKit draws the logo's SVGs and the app's own MenuBarIcon.swift (the
// menu bar icon, the same wave), iconutil packs the .icns. Build it with that file, then run it from the repo root:
//   swiftc -parse-as-library -o /tmp/sona-icon design/icon/render.swift Sources/SonaApp/MenuBarIcon.swift
//   /tmp/sona-icon          a contact sheet (/tmp/sona-icon.png, or set ICON_SHEET): the icon at 1024, 128,
//                                32 and 16 px in a Dock row, and every menu bar state at 1x and 2x on light and dark bars
//   /tmp/sona-icon apply    the same, and Resources/AppIcon.icns rebuilt from the SVGs
// The logo is icon.svg on the macOS icon grid (1024 canvas, 824 px body with continuous corners), on a 64-cell grid so
// it's sharp from 64 px up, plus icon-32.svg and icon-16.svg redrawn on the pixel grid of those sizes. AppKit draws
// SVG without filters, so the standard icon shadow is added here.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repo = here.deletingLastPathComponent().deletingLastPathComponent()
let sheetURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ICON_SHEET"] ?? "/tmp/sona-icon.png")
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// The .iconset a macOS app icon needs: 16 to 512 points, each at 1x and 2x.
let iconset: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

/// Apps already on this Mac, drawn next to the icon in the Dock rows (read from disk, never launched).
let neighbours = ["/System/Applications/Notes.app", "/System/Applications/VoiceMemos.app",
    "/System/Applications/Reminders.app", "/System/Applications/Calendar.app", "/System/Applications/Mail.app",
    "/Applications/Safari.app"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render: \(message)\n".utf8))
    exit(1)
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("no bitmap context") }
    return cg
}

/// Runs AppKit drawing (NSImage, text) into a CoreGraphics context.
func withAppKit(_ cg: CGContext, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("can't write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("can't write \(url.path)") }
}

/// An NSImage at one pixel size, no shadow.
func pixels(_ image: NSImage, _ px: Int) -> CGImage {
    let cg = bitmap(px, px)
    withAppKit(cg) { image.draw(in: NSRect(x: 0, y: 0, width: px, height: px)) }
    return cg.makeImage()!
}

/// The logo's three drawings: icon.svg, and the 32 and 16 px ones (32 px falls back to icon-16.svg, then icon.svg).
struct Logo {
    let large: NSImage
    let at32: NSImage
    let at16: NSImage

    init() {
        let svg = { (name: String) in NSImage(contentsOf: here.appendingPathComponent(name)) }
        guard let large = svg("icon.svg") else { fail("can't read design/icon/icon.svg") }
        self.large = large
        at16 = svg("icon-16.svg") ?? large
        at32 = svg("icon-32.svg") ?? svg("icon-16.svg") ?? large
    }

    /// One size, with the template's shadow (10 px down, 20 px blur, black at 30%, scaled from 1024).
    func render(_ px: Int) -> CGImage {
        let cg = bitmap(px, px)
        let s = CGFloat(px) / 1024
        cg.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s, color: CGColor(gray: 0, alpha: 0.3))
        let art = px <= 16 ? at16 : px <= 32 ? at32 : large
        withAppKit(cg) { art.draw(in: NSRect(x: 0, y: 0, width: px, height: px)) }
        guard let image = cg.makeImage() else { fail("nothing drawn at \(px) px") }
        return image
    }
}

/// A strip of menu bar (24 pt) at 1x or 2x with the icon in every state, drawn by the app's own code and tinted the
/// way macOS tints template images.
@MainActor func menuBar(scale: Int, dark: Bool) -> CGImage {
    let slot = 30, height = 24, states = MenuBarIcon.State.allCases
    let cg = bitmap((states.count * slot + 12) * scale, height * scale)
    cg.setFillColor(dark ? CGColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1) : CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1))
    cg.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    for (i, state) in states.enumerated() {
        let glyph = bitmap(18 * scale, 18 * scale)
        glyph.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        withAppKit(glyph) { MenuBarIcon.image(state).draw(in: NSRect(x: 0, y: 0, width: 18, height: 18)) }
        glyph.setBlendMode(.sourceIn)
        glyph.setFillColor(dark ? CGColor(gray: 1, alpha: 0.9) : CGColor(gray: 0, alpha: 0.85))
        glyph.fill(CGRect(x: 0, y: 0, width: 18, height: 18))
        cg.draw(glyph.makeImage()!, in: CGRect(x: (12 + i * slot) * scale, y: 3 * scale, width: 18 * scale, height: 18 * scale))
    }
    return cg.makeImage()!
}

/// A Dock-like strip at one icon size: a wallpaper, a frosted shelf, the neighbours with the icon in the middle.
func dock(_ icon: CGImage, px: Int) -> CGImage {
    let gap = max(4, px / 5), pad = max(4, px / 4)
    var icons = neighbours.filter { FileManager.default.fileExists(atPath: $0) }.map { pixels(NSWorkspace.shared.icon(forFile: $0), px) }
    icons.insert(icon, at: icons.count / 2)
    let w = pad * 2 + icons.count * px + (icons.count - 1) * gap, h = px + pad * 2
    let cg = bitmap(w + pad * 2, h + pad * 2)
    let wallpaper = CGGradient(colorsSpace: srgb, colors: [CGColor(srgbRed: 0.80, green: 0.76, blue: 0.70, alpha: 1),
        CGColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(wallpaper, start: .zero, end: CGPoint(x: 0, y: cg.height), options: [])
    cg.setFillColor(CGColor(gray: 1, alpha: 0.38))
    cg.addPath(CGPath(roundedRect: CGRect(x: pad, y: pad, width: w, height: h), cornerWidth: CGFloat(h) * 0.3, cornerHeight: CGFloat(h) * 0.3, transform: nil))
    cg.fillPath()
    for (i, image) in icons.enumerated() {
        cg.draw(image, in: CGRect(x: pad * 2 + i * (px + gap), y: pad * 2, width: px, height: px))
    }
    return cg.makeImage()!
}

@main @MainActor
enum Render {
    static func main() {
        let apply = CommandLine.arguments.dropFirst().first
        if let apply, apply != "apply" { fail("unknown argument \(apply) (only apply)") }
        let logo = Logo()
        var images: [Int: CGImage] = [:]
        for px in Set(iconset.map(\.px)) { images[px] = logo.render(px) }

        if apply != nil {
            let set = FileManager.default.temporaryDirectory.appendingPathComponent("sona-AppIcon.iconset")
            try? FileManager.default.removeItem(at: set)
            do { try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true) } catch { fail("\(error)") }
            for (name, px) in iconset { writePNG(images[px]!, to: set.appendingPathComponent("\(name).png")) }
            let icns = repo.appendingPathComponent("Resources/AppIcon.icns")
            let iconutil = Process()
            iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
            iconutil.arguments = ["-c", "icns", set.path, "-o", icns.path]
            do { try iconutil.run() } catch { fail("\(error)") }
            iconutil.waitUntilExit()
            guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
            try? FileManager.default.removeItem(at: set)
            print("design/icon -> Resources/AppIcon.icns")
        }
        sheet(images)
    }

    /// Top: the icon at 1024, then Dock rows at 128, 32 and 16 px, and the 32 and 16 px icons blown up (pixels as they
    /// are). Bottom: the menu bar in every state on a light and a dark bar, at 1x and 2x, each also blown up.
    static func sheet(_ images: [Int: CGImage]) {
        let pad = 48, gap = 40
        let states = MenuBarIcon.State.allCases
        let barWidth = (states.count * 30 + 12) * 8
        let width = pad * 2 + max(1024 + gap + dock(images[128]!, px: 128).width, barWidth + 500)
        let menuTop = pad + 1024 + 90
        let height = menuTop + 4 * (24 * 8 + 110) + pad
        let cg = bitmap(width, height)
        cg.setFillColor(CGColor(srgbRed: 0.98, green: 0.976, blue: 0.965, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Top-left coordinates: CoreGraphics counts y from the bottom.
        func box(_ x: Int, _ top: Int, _ w: Int, _ h: Int) -> CGRect { CGRect(x: x, y: height - top - h, width: w, height: h) }
        func text(_ s: String, _ x: Int, _ top: Int, size: CGFloat = 14) {
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            withAppKit(cg) {
                NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(white: 0.45, alpha: 1)])
                    .draw(at: NSPoint(x: CGFloat(x), y: CGFloat(height - top) - font.ascender + font.descender))
            }
        }
        func draw(_ image: CGImage, _ x: Int, _ top: Int, _ w: Int, _ h: Int, sharp: Bool = false) {
            cg.interpolationQuality = sharp ? .none : .high
            cg.draw(image, in: box(x, top, w, h))
        }

        draw(images[1024]!, pad, pad, 1024, 1024)
        text("1024", pad + 40, pad + 1024 + 10)
        var x = pad + 1024 + gap, top = pad + 20
        for px in [128, 32, 16] {
            let strip = dock(images[px]!, px: px)
            text("dock \(px) px (real size)", x, top)
            draw(strip, x, top + 28, strip.width, strip.height)
            top += 28 + strip.height + 40
        }
        text("32 px ×8, 16 px ×16 (pixels as they are)", x, top)
        draw(images[32]!, x, top + 28, 256, 256, sharp: true)
        draw(images[16]!, x + 256 + gap, top + 28, 256, 256, sharp: true)

        // The menu bar: the strip at its real size, then blown up so every pixel shows, with each state named.
        top = menuTop
        for dark in [false, true] {
            for scale in [1, 2] {
                let bar = menuBar(scale: scale, dark: dark)
                text("\(dark ? "dark" : "light") menu bar, \(scale)x", pad, top)
                draw(bar, pad, top + 28, bar.width, bar.height)
                let zoom = 8 / scale
                draw(bar, pad + 500, top, bar.width * zoom, bar.height * zoom, sharp: true)
                for (i, state) in states.enumerated() {
                    text(state.rawValue, pad + 500 + (12 + i * 30) * 8, top + 24 * 8 + 8, size: 15)
                }
                top += 24 * 8 + 110
            }
        }
        writePNG(cg.makeImage()!, to: sheetURL)
        print("contact sheet: \(sheetURL.path) (\(width)x\(height))")
    }
}
