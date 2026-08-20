import AppKit

/// Draws the menu bar item: the spark mark, then a percentage.
///
/// The mark is the only status channel — it takes the risk colour, and the
/// number stays in `labelColor` so exactly one thing in the item ever changes
/// appearance. Both read from the same bucket, so they cannot disagree.
///
/// A pure function of a snapshot — no state, no fetching. `main.swift` calls
/// `image(for:)` whenever the data or the system appearance changes.
enum StatusItemView {

    // Layout constants, in points. Total width lands around 44pt.
    // The system menu bar is ~22pt tall, so the image stays a little under that
    // to keep the mark from touching the edges.
    static let markSize: CGFloat = 16
    private static let height: CGFloat = 20
    private static let markGap: CGFloat = 4
    private static let fontSize: CGFloat = 11

    static func image(for snapshot: UsageSnapshot?, markSize: CGFloat = markSize) -> NSImage {
        let bucket = snapshot?.menuBarBucket
        let label = percentLabel(for: bucket)
        let attrs = textAttributes()

        // Measured, not fixed: "100%" is wider than "7%", and a fixed width
        // would either clip it or leave a permanent gap.
        let textWidth = (label as NSString).size(withAttributes: attrs).width.rounded(.up)
        let width = markSize + markGap + textWidth

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            draw(bucket: bucket, label: label, attrs: attrs, markSize: markSize)
            return true
        }
        // Not a template: the mark carries colour, which templates would discard.
        image.isTemplate = false
        return image
    }

    private static func draw(bucket: LimitBucket?, label: String,
                             attrs: [NSAttributedString.Key: Any], markSize: CGFloat) {
        let markRect = NSRect(x: 0, y: (height - markSize) / 2,
                              width: markSize, height: markSize)
        markColor(for: bucket).setFill()
        NSBezierPath(cgPath: SparkMark.path(in: markRect)).fill()

        let textSize = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: markSize + markGap,
                                             y: (height - textSize.height) / 2),
                                 withAttributes: attrs)
    }

    /// Same risk model as the popover, so the two surfaces can never disagree
    /// about how worrying a number is.
    private static func markColor(for bucket: LimitBucket?) -> NSColor {
        guard let bucket else { return .labelColor }
        let risk = RiskModel.risk(for: bucket).value
        return RiskModel.shouldTint(risk) ? Theme.riskNSColor(risk) : .labelColor
    }

    private static func percentLabel(for bucket: LimitBucket?) -> String {
        guard let bucket else { return "—" }
        return "\(Int(bucket.percent.rounded()))%"
    }

    /// Always `labelColor` — never literal white, which would vanish against a
    /// light menu bar.
    private static func textAttributes() -> [NSAttributedString.Key: Any] {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        // Rounded reads better than the default at this size; fall back cleanly
        // if the descriptor isn't available.
        let font: NSFont = {
            guard let descriptor = base.fontDescriptor.withDesign(.rounded),
                  let rounded = NSFont(descriptor: descriptor, size: fontSize) else { return base }
            return rounded
        }()
        return [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
    }
}
