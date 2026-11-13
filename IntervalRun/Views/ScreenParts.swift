import SwiftUI

/// Small caps line over a large title, at the top of a tab's screen, with an
/// optional line of explanation under it.
struct ScreenTitle: View {
    let eyebrow: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .font(.footnote.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 40, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Today's date as a screen eyebrow, e.g. "FRIDAY, OCT 30".
enum TodayEyebrow {
    static var text: String {
        Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()
    }
}

/// A group of rows in a rounded card, with an optional title over it and small
/// print under it.
struct CardSection<Content: View>: View {
    var title: String?
    var detail: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 10)
            }

            VStack(spacing: 0) {
                content
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
    }
}

/// A row's icon: a symbol in a tinted rounded square.
struct RowIcon: View {
    let systemImage: String
    var tint = Phase.work.color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row's trailing chevron, for rows that open something.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

/// A few options in a capsule, the chosen one on a pill that slides between them.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value
    /// Behind the options; change it when the picker sits on a card.
    var trackColor = Color(.secondarySystemGroupedBackground)
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.spring(duration: 0.3)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color(.systemBackground) : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.primary)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(trackColor, in: Capsule())
    }
}

/// The work color with a soft top-to-bottom sheen and a glow under it, for the
/// one card on a screen that starts something new.
struct AccentCardBackground: View {
    var cornerRadius: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Phase.work.color)
            .overlay {
                LinearGradient(colors: [.white.opacity(0.08), .black.opacity(0.14)], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .shadow(color: Phase.work.color.opacity(0.35), radius: 18, y: 8)
    }
}

/// A full-width capsule in the work color, for a screen's main action.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                Capsule()
                    .fill(Phase.work.color)
                    .overlay {
                        LinearGradient(colors: [.white.opacity(0.08), .black.opacity(0.14)], startPoint: .top, endPoint: .bottom)
                            .clipShape(Capsule())
                    }
                    .shadow(color: Phase.work.color.opacity(isEnabled ? 0.35 : 0), radius: 14, y: 6)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// "− value +" in a capsule, or just "− +" with an empty value. Tapping the
/// value calls `onTapValue`, e.g. to open a picker for exact values.
struct StepperCapsule: View {
    let value: String
    /// What VoiceOver reads for the value, when `value` isn't enough.
    var spokenValue: String?
    let accessibilityLabel: String
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void
    var isHighlighted = false
    var onTapValue: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: canDecrement, action: onDecrement)
            if let onTapValue {
                Button(action: onTapValue) { valueText }
                    .buttonStyle(.plain)
            } else if !value.isEmpty {
                valueText
            }
            stepButton("plus", enabled: canIncrement, action: onIncrement)
        }
        .padding(.horizontal, 4)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(spokenValue ?? value)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if canIncrement { onIncrement() }
            case .decrement: if canDecrement { onDecrement() }
            @unknown default: break
            }
        }
    }

    private var valueText: some View {
        Text(value)
            .font(.body.weight(.semibold).monospacedDigit())
            .foregroundStyle(isHighlighted ? Phase.work.color : .primary)
            .frame(minWidth: 52)
            .contentTransition(.numericText())
    }

    private func stepButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
    }
}

/// A stretch of seconds that steps by `step`, snapping to multiples of it.
enum DurationStep {
    static func up(_ seconds: Int, step: Int, in range: ClosedRange<Int>) -> Int {
        min((seconds / step + 1) * step, range.upperBound)
    }

    static func down(_ seconds: Int, step: Int, in range: ClosedRange<Int>) -> Int {
        let snapped = seconds % step == 0 ? seconds - step : seconds / step * step
        return max(snapped, range.lowerBound)
    }
}
