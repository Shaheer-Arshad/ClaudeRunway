import AppKit

// Renders the menu bar item to PNGs for states that can't be reached by waiting
// (0%, 100%, no data) in both appearances. Cheaper and more reliable than
// injecting fake snapshots into the running app.
//
//   ./tools/render.sh /tmp/out

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/menubar"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let scale: CGFloat = 5

func snapshot(session: Double?, weekly: Double? = 14, hoursLeft: Double = 1.7) -> UsageSnapshot? {
    var buckets: [LimitBucket] = []
    if let session {
        buckets.append(LimitBucket(key: "session", displayName: "Session (5h)",
                                   percent: session,
                                   resetsAt: Date().addingTimeInterval(hoursLeft * 3600)))
    }
    if let weekly {
        buckets.append(LimitBucket(key: "weekly_all", displayName: "Weekly (all models)",
                                   percent: weekly,
                                   resetsAt: Date().addingTimeInterval(6 * 86400)))
    }
    return buckets.isEmpty ? nil : UsageSnapshot(buckets: buckets, fetchedAt: Date())
}

/// Composites the item onto a menu-bar-like strip so `labelColor` is judged
/// against a realistic background rather than transparency.
func write(_ image: NSImage, name: String, dark: Bool) {
    let pad: CGFloat = 6
    let w = (image.size.width + pad * 2) * scale
    let h = (image.size.height + pad * 2) * scale

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(w), pixelsHigh: Int(h),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
    NSRect(x: 0, y: 0, width: w / scale, height: h / scale).fill()

    image.draw(at: NSPoint(x: pad, y: pad),
               from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()

    if let data = rep.representation(using: .png, properties: [:]) {
        let path = "\(outDir)/\(name).png"
        try? data.write(to: URL(fileURLWithPath: path))
        print("  \(path)  (\(Int(image.size.width))x\(Int(image.size.height))pt)")
    }
}

let cases: [(String, UsageSnapshot?)] = [
    ("00-no-data", nil),
    ("01-zero", snapshot(session: 0)),
    ("02-low", snapshot(session: 12, hoursLeft: 4.4)),      // early, on pace
    ("03-current", snapshot(session: 71)),                   // ahead of pace
    ("04-high", snapshot(session: 94, hoursLeft: 0.6)),
    ("05-hundred", snapshot(session: 100, hoursLeft: 0.3)),  // widest label
]

for (appearanceName, isDark) in [(NSAppearance.Name.darkAqua, true), (.aqua, false)] {
    let appearance = NSAppearance(named: appearanceName)!
    print("\(isDark ? "dark" : "light"):")
    appearance.performAsCurrentDrawingAppearance {
        for (name, snap) in cases {
            let image = StatusItemView.image(for: snap)
            write(image, name: "\(isDark ? "dark" : "light")-\(name)", dark: isDark)
        }
    }
}

// Mark-size comparison, so the size can be chosen by looking rather than guessing.
print("sizes:")
NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
    for size in [CGFloat(14), 16, 18] {
        let image = StatusItemView.image(for: snapshot(session: 71), markSize: size)
        write(image, name: "size-\(Int(size))pt", dark: true)
    }
}
