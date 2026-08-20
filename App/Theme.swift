import AppKit
import SwiftUI

/// The palette and type scale.
///
/// Two separate colour families, deliberately:
///
///   - **accent** is chrome (the mark, the sparkline). It never signals state,
///     so it stays constant and the eye learns to ignore it.
///   - **the risk ramp** is the only thing that changes colour, so any colour
///     change in the UI means exactly one thing: your headroom moved.
///
/// The accent is a cool indigo on purpose. It has to sit beside a green → amber
/// → red risk ramp without being mistaken for a step on it, and a warm accent
/// fails that test twice over: it competes with amber, and it borrows a palette
/// this app has no business borrowing (see the trademark note in the README).
enum Theme {

    // MARK: - Chrome

    /// Indigo. Cool, so it can never be read as a point on the warm risk ramp.
    static let accent = Color(hex: 0x5A57D6)

    // MARK: - Risk ramp
    //
    // Interpolated in HSB, not sRGB: a straight RGB blend from green to red
    // passes through a muddy olive, while an HSB sweep stays saturated.

    private static let safe = HSB(hue: 152, saturation: 0.66, brightness: 0.72)
    private static let warn = HSB(hue: 35, saturation: 0.82, brightness: 0.89)
    private static let critical = HSB(hue: 4, saturation: 0.75, brightness: 0.87)

    /// Maps 0…1 risk onto the ramp. Flat at both ends so small wobbles near zero
    /// or near the ceiling don't make the UI flicker between colours.
    static func riskColor(_ risk: Double) -> Color {
        let r = min(max(risk, 0), 1)
        switch r {
        case ..<0.30:
            return safe.color
        case ..<0.55:
            return safe.blended(to: warn, t: (r - 0.30) / 0.25).color
        case ..<0.85:
            return warn.blended(to: critical, t: (r - 0.55) / 0.30).color
        default:
            return critical.color
        }
    }

    /// AppKit twin for the menu bar, which draws outside SwiftUI.
    static func riskNSColor(_ risk: Double) -> NSColor {
        let r = min(max(risk, 0), 1)
        let hsb: HSB
        switch r {
        case ..<0.30: hsb = safe
        case ..<0.55: hsb = safe.blended(to: warn, t: (r - 0.30) / 0.25)
        case ..<0.85: hsb = warn.blended(to: critical, t: (r - 0.55) / 0.30)
        default: hsb = critical
        }
        return hsb.nsColor
    }

    // MARK: - Surfaces

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x17161A) : Color(hex: 0xFBF9F5)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x201E24) : Color.white
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)
    }

    /// The unfilled part of any gauge.
    static func track(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    // MARK: - Type

    /// Numerals. Monospaced so a changing percentage doesn't shift the layout.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Labels and chrome.
    static func label(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - HSB blending

private struct HSB {
    var hue: Double          // degrees
    var saturation: Double
    var brightness: Double

    func blended(to other: HSB, t: Double) -> HSB {
        let t = min(max(t, 0), 1)
        // Hues here always descend (152 → 35 → 4), so a direct lerp is correct
        // and avoids wrapping the long way round the wheel.
        return HSB(hue: hue + (other.hue - hue) * t,
                   saturation: saturation + (other.saturation - saturation) * t,
                   brightness: brightness + (other.brightness - brightness) * t)
    }

    var color: Color {
        Color(hue: hue / 360, saturation: saturation, brightness: brightness)
    }

    var nsColor: NSColor {
        NSColor(calibratedHue: hue / 360, saturation: saturation,
                brightness: brightness, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
