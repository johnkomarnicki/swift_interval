import SwiftUI

/// The frame shared by the interval and free run players: the live map on top
/// with the workout's name over it, and the run's details in a rounded sheet in
/// the phase color below. Without a map the phase color fills the screen.
///
/// The sheet can be collapsed (handle, swipe or the expand button) to give the
/// map more room; the player shows less in `sheet` while `isMapExpanded`.
struct PlayerScaffold<MapContent: View, SheetContent: View>: View {
    let eyebrow: String
    let title: String
    let tint: Color
    /// What's measuring distance, shown just above the sheet; nil when distance isn't tracked.
    let source: DistanceSource?
    let showsMap: Bool
    @Binding var isMapExpanded: Bool
    /// Given how much of the bottom of the screen the sheet covers.
    @ViewBuilder let map: (CGFloat) -> MapContent
    @ViewBuilder let sheet: () -> SheetContent

    @State private var sheetHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if showsMap {
                map(sheetHeight)
            } else {
                tint.ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if let source {
                    SourcePill(source: source)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                sheetContainer
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.3), value: tint)
        .animation(.spring(duration: 0.35), value: isMapExpanded)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .opacity(0.75)
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if showsMap {
                Button {
                    isMapExpanded.toggle()
                } label: {
                    Image(systemName: isMapExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMapExpanded ? "Show workout details" : "Enlarge map")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var sheetContainer: some View {
        VStack(spacing: 0) {
            if showsMap {
                handle
            }
            sheet()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background {
            if showsMap {
                UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                    .fill(tint)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .gesture(swipe, including: showsMap ? .all : .subviews)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.bottom
        } action: { height in
            sheetHeight = height
        }
    }

    private var handle: some View {
        Capsule()
            .fill(.white.opacity(0.4))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { isMapExpanded.toggle() }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isMapExpanded ? "Show workout details" : "Enlarge map")
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height > 40 {
                isMapExpanded = true
            } else if value.translation.height < -40 {
                isMapExpanded = false
            }
        }
    }
}

/// "GPS", "Step counter" or "Waiting for GPS…" with a status dot.
struct SourcePill: View {
    let source: DistanceSource

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Distance from \(label)")
    }

    private var label: String {
        switch source {
        case .gps: "GPS"
        case .steps: "Step counter"
        case .none: "Waiting for GPS…"
        }
    }

    private var dotColor: Color {
        switch source {
        case .gps: .green
        case .steps: .yellow
        case .none: .orange
        }
    }
}

/// The current phase in a white capsule, lettered in the phase color.
struct PhasePill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white, in: Capsule())
            .fixedSize()
    }
}

/// "● Next Rest 1:30", the dot in the next phase's color.
struct NextChip: View {
    let text: String
    let dotColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
            Text("Next")
                .opacity(0.8)
            Text(text)
                .fontWeight(.bold)
                .monospacedDigit()
        }
        .font(.subheadline)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.18), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The big clock, with one smaller figure (total left, distance) beside it.
struct PlayerClockRow: View {
    let time: String
    let timeAccessibilityLabel: String
    let sideTitle: String
    let sideValue: String
    let size: CGFloat
    var isPaused = false

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(time)
                .font(.system(size: size, weight: .bold))
                .tracking(-size * 0.02)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .opacity(isPaused ? 0.6 : 1)
                .accessibilityLabel(timeAccessibilityLabel)
                .accessibilityValue(time)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(sideTitle)
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .opacity(0.75)
                Text(sideValue)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
        // Digits sit well below the top of a font this size; pull them up to
        // the row above.
        .padding(.top, -size * 0.12)
    }
}

/// Every segment of the workout, sized by its length: done in white, the
/// current one filling up, and those to come in a lighter shade for work and
/// darker for everything else.
struct SegmentProgressBar: View {
    let segments: [Segment]
    let starts: [TimeInterval]
    let elapsed: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = segments.count > 24 ? 2 : 4
            let total = segments.reduce(0) { $0 + $1.duration }
            let available = max(0, proxy.size.width - spacing * CGFloat(max(segments.count - 1, 0)))
            HStack(spacing: spacing) {
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    let width = total > 0 ? available * segment.duration / total : 0
                    let done = min(max((elapsed - starts[index]) / segment.duration, 0), 1)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(segment.phase == .work ? .white.opacity(0.3) : .black.opacity(0.18))
                        Rectangle().fill(.white).frame(width: width * done)
                    }
                    .frame(width: width)
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// One figure in the player's stat cards.
struct PlayerStat: Identifiable {
    let title: String
    var systemImage: String?
    let value: String
    var unit: String?
    /// Small print under the value, e.g. why there's no heart rate yet.
    var note: String?
    var dimmed = false
    var accessibilityText: String?

    var id: String { title }

    /// "10:22 /mi", or "–:––" when there's too little distance to tell.
    static func pace(_ title: String, seconds: TimeInterval, meters: Double) -> PlayerStat {
        let pace = DistanceFormat.secondsPerMile(seconds: seconds, meters: meters)
        return PlayerStat(
            title: title,
            value: pace.map(TimeFormat.clock) ?? "–:––",
            unit: "/mi",
            accessibilityText: pace.map { "\(title.capitalized) \(DistanceFormat.spokenPace(secondsPerMile: $0))" } ?? "\(title.capitalized) not known yet"
        )
    }

    /// "0.49 mi"
    static func distance(_ title: String, meters: Double) -> PlayerStat {
        PlayerStat(title: title, value: String(format: "%.2f", DistanceFormat.miles(meters)), unit: "mi")
    }

    /// Dimmed, with the reason, until a reading arrives.
    @MainActor
    static func heartRate(_ monitor: HeartRateMonitor) -> PlayerStat {
        PlayerStat(
            title: "HEART RATE",
            systemImage: "heart.fill",
            value: monitor.bpm.map(String.init) ?? "–",
            unit: monitor.bpm == nil ? nil : "bpm",
            note: monitor.waitingText,
            dimmed: monitor.bpm == nil,
            accessibilityText: monitor.liveAccessibilityText
        )
    }
}

/// Stat cards two to a row; an odd one out takes the full width.
struct PlayerStatGrid: View {
    let stats: [PlayerStat]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(stride(from: 0, to: stats.count, by: 2)), id: \.self) { start in
                HStack(spacing: 10) {
                    ForEach(stats[start..<min(start + 2, stats.count)]) { stat in
                        card(stat)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card(_ stat: PlayerStat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let systemImage = stat.systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(stat.title)
                    .tracking(0.8)
            }
            .font(.caption.weight(.semibold))
            .opacity(0.75)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(stat.value)
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                if let unit = stat.unit {
                    Text(unit)
                        .font(.subheadline.weight(.medium))
                        .opacity(0.75)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            if let note = stat.note {
                Text(note)
                    .font(.caption2.weight(.semibold))
                    .opacity(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(stat.dimmed ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stat.accessibilityText ?? "\(stat.title.capitalized) \(stat.value) \(stat.unit ?? "")")
    }
}

/// End on the left, a big white pause/resume in the middle, skip (if any) on the right.
struct PlayerControls: View {
    let endSystemImage: String
    let endLabel: String
    let onEnd: () -> Void
    let isPaused: Bool
    let tint: Color
    let onTogglePause: () -> Void
    var onSkip: (() -> Void)?

    private let sideSize: CGFloat = 60
    private let mainSize: CGFloat = 84

    var body: some View {
        HStack {
            sideButton(systemImage: endSystemImage, label: endLabel, action: onEnd)
            Spacer()
            Button(action: onTogglePause) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: mainSize, height: mainSize)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPaused ? "Resume" : "Pause")
            Spacer()
            if let onSkip {
                sideButton(systemImage: "forward.end.fill", label: "Skip to next interval", action: onSkip)
            } else {
                // Keeps the pause button centred.
                Color.clear.frame(width: sideSize, height: sideSize)
            }
        }
        .padding(.horizontal, 4)
    }

    private func sideButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .bold))
                .frame(width: sideSize, height: sideSize)
                .background(.black.opacity(0.18), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
