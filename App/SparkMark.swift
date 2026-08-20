import AppKit

/// The Claude Runway mark: a four-point spark, drawn programmatically.
///
/// Geometry rather than a bundled asset, so it stays crisp at any size and the
/// bundle needs no image resources. The app icon is generated from this same
/// path (`tools/make-icon.sh`), so the two can't drift.
///
/// Deliberately *not* a rendition of Anthropic's mark. Four concave-flanked
/// points is a different construction from a radially symmetric multi-ray
/// burst; the sparkle is a common idiom rather than anyone's brand. See the
/// trademark note in the README.
///
/// Tuned for legibility at ~16pt in the menu bar: at that size the waist has to
/// stay generous, or the points thin out into whiskers.
enum SparkMark {
    /// How far the concave flanks pull toward the centre, as a fraction of the
    /// radius. Lower is spikier; below ~0.24 it turns to whiskers at 16pt.
    static let waistRatio: CGFloat = 0.30

    /// Builds the mark centered in `rect`.
    static func path(in rect: CGRect) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let waist = radius * waistRatio

        let path = CGMutablePath()

        // Four points at the compass positions, joined by quadratic-ish curves
        // that dip to `waist` on the diagonals. Both control points sit at the
        // same spot, which is what gives the flank its clean single concavity.
        for i in 0..<4 {
            let angle = .pi / 2 - Double(i) * .pi / 2
            let next = angle - .pi / 2
            let diagonal = angle - .pi / 4

            func point(_ theta: Double, _ r: CGFloat) -> CGPoint {
                CGPoint(x: center.x + CGFloat(cos(theta)) * r,
                        y: center.y + CGFloat(sin(theta)) * r)
            }

            let tip = point(angle, radius)
            let waistPoint = point(diagonal, waist)

            if i == 0 { path.move(to: tip) }
            path.addCurve(to: point(next, radius), control1: waistPoint, control2: waistPoint)
        }
        path.closeSubpath()

        return path
    }
}
