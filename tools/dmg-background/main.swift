import AppKit

// Draws the DMG window background: a dashed arrow pointing from the app icon
// to the Applications folder. Usage: dmg-background <out.png> <scale>
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let scale = CGFloat(Double(args[2]) ?? 1)
let size = CGSize(width: 600, height: 380)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(white: 0.925, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

// Arrow centred between the icons (at x=160 and x=440, y=190 from the top).
let cx: CGFloat = 300, cy: CGFloat = size.height - 190
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: cx - 40, y: cy + 14))
arrow.line(to: NSPoint(x: cx + 4, y: cy + 14))
arrow.line(to: NSPoint(x: cx + 4, y: cy + 40))
arrow.line(to: NSPoint(x: cx + 44, y: cy))
arrow.line(to: NSPoint(x: cx + 4, y: cy - 40))
arrow.line(to: NSPoint(x: cx + 4, y: cy - 14))
arrow.line(to: NSPoint(x: cx - 40, y: cy - 14))
arrow.close()
arrow.lineWidth = 2
arrow.lineJoinStyle = .miter
arrow.setLineDash([6, 4], count: 2, phase: 0)
NSColor(white: 0.35, alpha: 1).setStroke()
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
