// Renders design/icon/icon-ios.svg to the 1024 px PNGs the iPhone and watch asset catalogs need: opaque (App Store
// Connect rejects an icon with an alpha channel), sRGB. Run from the repo root: swift ios/scripts/make-icon.swift
import AppKit

let svg = URL(fileURLWithPath: "design/icon/icon-ios.svg")
let outputs = ["ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
               "ios/Resources/WatchAssets.xcassets/AppIcon.appiconset/AppIcon.png"]
guard let image = NSImage(contentsOf: svg) else { fatalError("can't read \(svg.path)") }
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
for out in outputs {
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}
