import SwiftUI

/// The hero gauge.
///
/// Two quantities on one dial: the arc is how much you've used, the notch is
/// where even consumption would have you right now. The **gap between them** is
/// the thing worth reading — arc past the notch means you're outrunning the
/// window's ability to reset.
struct PaceRing: View {
    let percent: Double
    let risk: UsageRisk
    let caption: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedFill: Double = 0

    private let lineWidth: CGFloat = 9
    private let size: CGFloat = 124
    /// A stroke straddles its path, and the notch overhangs further still, so the
    /// circle is inset far enough that the whole gauge stays inside its frame.
    /// Without this the top of the ring is clipped by the enclosing scroll view.
    private let inset: CGFloat = 8

    /// Distance from centre to the middle of the stroke.
    private var ringRadius: CGFloat { (size - inset * 2) / 2 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.track(scheme), lineWidth: lineWidth)
                .padding(inset)

            Circle()
                .trim(from: 0, to: animatedFill / 100)
                .stroke(Theme.riskColor(risk.value),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .padding(inset)
                .rotationEffect(.degrees(-90))

            paceNotch

            VStack(spacing: 1) {
                Text("\(Int(percent.rounded()))%")
                    .font(Theme.number(27))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(caption)
                    .font(Theme.label(10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { animatedFill = percent; return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                animatedFill = percent
            }
        }
        .onChange(of: percent) { _, new in
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85)) {
                animatedFill = new
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(Int(percent.rounded())) percent used")
        .accessibilityValue(paceDescription)
    }

    /// Deliberately not animated: it's a fixed reference the fill moves against.
    ///
    /// `offset` is a render-time transform, so the capsule's layout frame stays
    /// centred in the ZStack — which means `rotationEffect` pivots around the
    /// ring's centre, not the capsule's own.
    @ViewBuilder
    private var paceNotch: some View {
        if risk.pacePercent > 0.5 {
            Capsule()
                .fill(.primary.opacity(0.55))
                .frame(width: 2, height: lineWidth + 6)
                .offset(y: -ringRadius)
                .rotationEffect(.degrees(risk.pacePercent / 100 * 360))
        }
    }

    private var paceDescription: String {
        guard risk.projectedPercent != nil else { return "" }
        let delta = percent - risk.pacePercent
        if delta > 3 { return "ahead of pace" }
        if delta < -3 { return "behind pace" }
        return "on pace"
    }
}

/// The same idea flattened, for secondary limits that don't warrant a dial.
struct PaceBar: View {
    let percent: Double
    let risk: UsageRisk

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedFill: Double = 0

    private let height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track(scheme))

                Capsule()
                    .fill(Theme.riskColor(risk.value))
                    .frame(width: max(height, geo.size.width * animatedFill / 100))

                if risk.pacePercent > 0.5 {
                    Rectangle()
                        .fill(.primary.opacity(0.5))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * risk.pacePercent / 100 - 0.75)
                }
            }
        }
        .frame(height: height)
        .onAppear {
            guard !reduceMotion else { animatedFill = percent; return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.05)) {
                animatedFill = percent
            }
        }
        .onChange(of: percent) { _, new in
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85)) {
                animatedFill = new
            }
        }
    }
}

/// A card wrapper — one padding level, one radius, one hairline.
struct Panel<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.card(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.hairline(scheme), lineWidth: 1)
            )
    }
}
