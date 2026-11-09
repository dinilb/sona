// Rewrites each PNG without an alpha channel (App Store Connect refuses screenshots that have one), pixel for
// pixel: the image is drawn once onto an opaque sRGB bitmap. Used by render.sh:
//   swift design/app-store/flatten.swift a.png b.png ...
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
var failed = false
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else {
        FileHandle.standardError.write(Data("flatten: can't read \(path)\n".utf8))
        failed = true
        continue
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let flat = context.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        failed = true
        continue
    }
    CGImageDestinationAddImage(dest, flat, nil)
    if !CGImageDestinationFinalize(dest) { failed = true }
}
exit(failed ? 1 : 0)
