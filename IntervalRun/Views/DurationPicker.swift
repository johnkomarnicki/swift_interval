import SwiftUI

/// Minutes + seconds wheels (0–59 each) bound to a total number of seconds.
struct DurationPicker: View {
    @Binding var seconds: Int

    var body: some View {
        HStack(spacing: 0) {
            Picker("Minutes", selection: minutes) {
                ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
            }
            Picker("Seconds", selection: secondsPart) {
                ForEach(0..<60, id: \.self) { Text("\($0) sec").tag($0) }
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(height: 140)
    }

    private var minutes: Binding<Int> {
        Binding(
            get: { min(seconds / 60, 59) },
            set: { seconds = $0 * 60 + seconds % 60 }
        )
    }

    private var secondsPart: Binding<Int> {
        Binding(
            get: { seconds % 60 },
            set: { seconds = (seconds / 60) * 60 + $0 }
        )
    }
}

/// The title Run or Walk for a pattern step's phase.
extension Phase {
    var stepTitle: String { self == .work ? "Run" : "Walk" }
}

/// One step of a custom pattern: a menu on the name (run/walk, reorder, delete)
/// and a stepper whose value opens `DurationPicker` when tapped.
struct PatternStepRow: View {
    @Binding var step: IntervalStep
    let number: Int
    @Binding var isExpanded: Bool
    /// Nil when the step can't move that way.
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Picker("Type", selection: $step.phase) {
                        Label("Run", systemImage: "figure.run").tag(Phase.work)
                        Label("Walk", systemImage: "figure.walk").tag(Phase.rest)
                    }
                    Button("Move Up", systemImage: "arrow.up") { onMoveUp?() }
                        .disabled(onMoveUp == nil)
                    Button("Move Down", systemImage: "arrow.down") { onMoveDown?() }
                        .disabled(onMoveDown == nil)
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    HStack(spacing: 10) {
                        PhaseDot(phase: step.phase)
                        Text("\(number). \(step.phase.stepTitle)")
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                Spacer(minLength: 8)
                DurationStepper(
                    title: "\(number). \(step.phase.stepTitle)",
                    seconds: $step.seconds,
                    range: step.phase == .work ? 15...WorkoutPlan.maxIntervalSeconds : 0...WorkoutPlan.maxIntervalSeconds,
                    step: 15,
                    isExpanded: $isExpanded
                )
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            if isExpanded {
                DurationPicker(seconds: $step.seconds)
            }
        }
    }
}

/// A card row with a duration stepper; tapping the time opens `DurationPicker`
/// for exact values.
struct DurationRow: View {
    let title: String
    var phase: Phase?
    @Binding var seconds: Int
    var range = 0...WorkoutPlan.maxIntervalSeconds
    var step = 15
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let phase {
                    PhaseDot(phase: phase)
                }
                Text(title)
                Spacer(minLength: 8)
                DurationStepper(title: title, seconds: $seconds, range: range, step: step, isExpanded: $isExpanded)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            if isExpanded {
                DurationPicker(seconds: $seconds)
            }
        }
    }
}

/// "− 1:30 +", stepping by `step`; the time toggles `isExpanded`.
struct DurationStepper: View {
    let title: String
    @Binding var seconds: Int
    let range: ClosedRange<Int>
    let step: Int
    @Binding var isExpanded: Bool

    var body: some View {
        StepperCapsule(
            value: TimeFormat.clock(seconds),
            accessibilityLabel: title,
            canDecrement: seconds > range.lowerBound,
            canIncrement: seconds < range.upperBound,
            onDecrement: { seconds = DurationStep.down(seconds, step: step, in: range) },
            onIncrement: { seconds = DurationStep.up(seconds, step: step, in: range) },
            isHighlighted: isExpanded,
            onTapValue: { withAnimation { isExpanded.toggle() } }
        )
    }
}

/// A small dot in a phase's color.
struct PhaseDot: View {
    let phase: Phase

    var body: some View {
        Circle()
            .fill(phase.color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
