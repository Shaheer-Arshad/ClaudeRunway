import AppKit

// Generates the .iconset PNGs for the app icon.
//
// Drawn from the same SparkMark geometry as the menu bar, so the icon and the
// status item can never drift apart, and no binary asset needs checking in.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Clay ground with a cream mark — Claude's own colouring, and it stays legible
// against both light and dark Finder backgrounds.
let ground = NSColor(srgbRed: 0x5A / 255, green: 0x57 / 255, blue: 0xD6 / 255, alpha: 1)
let markColor = NSColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF5 / 255, alpha: 1)

func icon(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons sit inside the canvas with a transparent margin, so they line
    // up with system icons in the Dock and Finder.
    let margin = s * 0.09
    let plate = NSRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let radius = plate.width * 0.2237   // Apple's squircle ratio

    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    ground.setFill()
    path.fill()

    // The mark reads best occupying a little over half the plate.
    let markSide = plate.width * 0.58
    let markRect = NSRect(x: plate.midX - markSide / 2,
                          y: plate.midY - markSide / 2,
                          width: markSide, height: markSide)
    markColor.setFill()
    NSBezierPath(cgPath: SparkMark.path(in: markRect)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// The exact set `iconutil` expects.
let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for v in variants {
    guard let data = icon(size: v.px) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(v.name).png"))
}
print("wrote \(variants.count) sizes to \(outDir)")
