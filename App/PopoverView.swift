import SwiftUI

/// Whether the popover is on screen.
///
/// `NSPopover` builds its content view controller once and reuses it, so the
/// SwiftUI hierarchy below outlives every showing. Anything periodic inside it
/// therefore has to ask whether it is actually visible — otherwise it runs for
/// the lifetime of the app.
@MainActor
final class PopoverVisibility: ObservableObject {
    @Published var isOpen = false
}

/// The popover answers one question: **do I have headroom to start something long?**
///
/// Everything is ordered by how directly it answers that — the session ring
/// first, because it's the limit that actually bites; then weekly; then history;
/// then chrome.
struct PopoverView: View {
    @ObservedObject var controller: UsageController
    @EnvironmentObject private var visibility: PopoverVisibility
    var onQuit: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// Drives the reset countdowns without touching the network.
    @State private var now = Date()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var keyInput = ""
    @State private var editingKey = false
    @State private var keyRejected = false
    @State private var tab = Tab.usage
    /// Held here rather than inside `WorkLogView` so switching tabs doesn't
    /// discard the day being viewed and rescan every transcript.
    @StateObject private var workLog = WorkLogModel()

    private enum Tab: String, CaseIterable, Identifiable {
        case usage = "Usage", work = "Work"
        var id: String { rawValue }
    }

    /// Drives the reset countdowns. Deliberately *not* applied while the
    /// popover is hidden: `NSPopover` keeps its content view alive between
    /// showings, so an unconditional tick re-evaluates this whole body once a
    /// second forever, for labels nobody can see.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tabPicker

            // Scrolls only if it has to. An account with several weekly buckets
            // on a short display would otherwise grow the popover past the
            // screen edge; `maxHeight` bounds it and the scroll view absorbs
            // the rest.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .usage:
                        content
                        sessionKeySection
                    case .work:
                        WorkLogView(model: workLog)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 560)

            footer
        }
        .padding(16)
        .frame(width: 292)
        .background(Theme.background(scheme))
        .onReceive(tick) { if visibility.isOpen { now = $0 } }
        .onChange(of: visibility.isOpen) { _, open in if open { now = Date() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            SparkMarkShape()
                .fill(Theme.accent)
                .frame(width: 13, height: 13)

            Text("Claude Runway")
                .font(Theme.label(12, weight: .semibold))

            Spacer()

            Text(controller.transport.label)
                .font(Theme.label(9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.track(scheme)))
        }
    }

    /// Two questions the app answers: how much headroom is left, and what got
    /// done. They share nothing, so they get a tab each rather than one long
    /// scroll.
    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let snapshot = controller.snapshot, let session = snapshot.session {
            VStack(spacing: 14) {
                sessionHero(session)
                ForEach(snapshot.buckets.filter { !$0.isSession }) { bucket in
                    secondaryRow(bucket)
                }
                sparkline
            }
        } else if let snapshot = controller.snapshot, !snapshot.buckets.isEmpty {
            // No session bucket on this plan — fall back to rows for everything.
            VStack(spacing: 14) {
                ForEach(snapshot.buckets) { bucket in secondaryRow(bucket) }
                sparkline
            }
        } else {
            emptyState
        }
    }

    private func sessionHero(_ bucket: LimitBucket) -> some View {
        let risk = RiskModel.risk(for: bucket, now: now)
        return VStack(spacing: 9) {
            PaceRing(percent: bucket.percent, risk: risk, caption: "session")

            VStack(spacing: 2) {
                if let reset = resetText(bucket) {
                    Text(reset)
                        .font(Theme.label(11))
                        .monospacedDigit()
                }
                if let pacing = pacingText(risk, percent: bucket.percent) {
                    Text(pacing)
                        .font(Theme.label(10, weight: .regular))
                        .foregroundStyle(Theme.riskColor(risk.value))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func secondaryRow(_ bucket: LimitBucket) -> some View {
        let risk = RiskModel.risk(for: bucket, now: now)
        return Panel {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(bucket.displayName)
                        .font(Theme.label(11))
                    Spacer()
                    Text("\(Int(bucket.percent.rounded()))%")
                        .font(Theme.number(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.riskColor(risk.value))
                }

                PaceBar(percent: bucket.percent, risk: risk)

                if let reset = resetText(bucket) {
                    Text(reset)
                        .font(Theme.label(9.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var sparkline: some View {
        Panel {
            VStack(alignment: .leading, spacing: 7) {
                Text("Last 24 hours")
                    .font(Theme.label(9.5, weight: .regular))
                    .foregroundStyle(.secondary)
                Sparkline(samples: controller.recentSeries)
                    .frame(height: 30)
            }
        }
    }

    private var emptyState: some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.lastError ?? "Loading…")
                    .font(Theme.label(11))
                if controller.lastError != nil {
                    Text("Sign in with `claude` in a terminal, or add a session key below.")
                        .font(Theme.label(10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Session key

    /// Shown only when actionable: no key, an expired key, or explicitly opened.
    @ViewBuilder
    private var sessionKeySection: some View {
        if !controller.hasSessionKey || controller.sessionExpired || editingKey {
            Panel {
                VStack(alignment: .leading, spacing: 7) {
                    Text(controller.sessionExpired ? "Session key expired" : "Add a session key")
                        .font(Theme.label(11, weight: .semibold))

                    Text("Updates every minute instead of every 15.")
                        .font(Theme.label(10, weight: .regular))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        SecureField("sk-ant-sid…", text: $keyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))

                        Button("Save") { save() }
                            .controlSize(.small)
                            .disabled(keyInput.isEmpty)
                    }

                    Text(keyRejected
                         ? "That isn't a session key — it should start with sk-ant-sid."
                         : "claude.ai → DevTools → Application → Cookies → sessionKey")
                        .font(Theme.label(9.5, weight: .regular))
                        .foregroundStyle(keyRejected ? Theme.riskColor(1) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func save() {
        if controller.setSessionKey(keyInput) {
            keyInput = ""
            editingKey = false
            keyRejected = false
        } else {
            keyRejected = true
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(controller.statusLine)
                .font(Theme.label(9.5, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 2)

            Toggle("", isOn: Binding(
                get: { launchAtLogin },
                set: { launchAtLogin = LaunchAtLogin.set($0) ? $0 : launchAtLogin }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help("Launch at login")

            Button { controller.requestRefresh(reason: "manual", force: true) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(controller.isRefreshing)
            .help("Refresh now")

            if controller.hasSessionKey && !controller.sessionExpired {
                Button { editingKey.toggle() } label: { Image(systemName: "key") }
                    .buttonStyle(.borderless)
                    .help("Replace session key")
            }

            Button(action: onQuit) { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit")
        }
        .font(.system(size: 11))
    }

    // MARK: - Copy

    private func resetText(_ bucket: LimitBucket) -> String? {
        guard let resetsAt = bucket.resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        // A window that has technically elapsed means our snapshot predates the
        // rollover; say so rather than rendering negative time.
        guard remaining > 0 else { return "resetting now" }
        return "resets in \(format(remaining))"
    }

    /// The one sentence that explains the notch. Only shown when it's actionable —
    /// "on pace" every minute would be noise.
    private func pacingText(_ risk: UsageRisk, percent: Double) -> String? {
        guard let projected = risk.projectedPercent, risk.elapsed > 0.08 else { return nil }
        let delta = percent - risk.pacePercent

        if projected >= 100 {
            return "on track to run out before reset"
        }
        if delta > 5 {
            return "ahead of pace · ~\(Int(projected.rounded()))% by reset"
        }
        return nil
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - Sparkline

private struct Sparkline: View {
    let samples: [HistoryStore.Sample]

    var body: some View {
        GeometryReader { geo in
            if points.count < 2 {
                Text("Collecting history…")
                    .font(Theme.label(9.5, weight: .regular))
                    .foregroundStyle(.tertiary)
            } else {
                ZStack {
                    path(in: geo.size, closed: true)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                    path(in: geo.size)
                        .stroke(Theme.accent, style: .init(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
    }

    private var points: [(x: Double, y: Double)] {
        let usable = samples.compactMap { s -> (Double, Double)? in
            guard let v = s.session else { return nil }
            return (s.t.timeIntervalSince1970, v)
        }
        guard let first = usable.first?.0, let last = usable.last?.0, last > first else {
            return usable.map { (0, $0.1) }
        }
        return usable.map { ((($0.0 - first) / (last - first)), $0.1) }
    }

    /// Scaled to the observed range with a floor, so a flat line sits low in the
    /// band instead of filling it.
    private func path(in size: CGSize, closed: Bool = false) -> Path {
        let pts = points
        let maxY = max(pts.map(\.y).max() ?? 0, 20)

        var path = Path()
        for (i, p) in pts.enumerated() {
            let point = CGPoint(x: p.x * size.width,
                                y: size.height - (p.y / maxY) * size.height)
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        if closed, let lastX = pts.last?.x {
            path.addLine(to: CGPoint(x: lastX * size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

/// SwiftUI wrapper around the same geometry the menu bar uses, so the mark can
/// never drift between the two surfaces.
struct SparkMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(SparkMark.path(in: rect))
    }
}
