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

/// One step of a custom pattern: a menu on the name (work/rest, reorder, delete)
/// and a duration that expands into `DurationPicker` when tapped.
struct PatternStepRow: View {
    @Binding var step: IntervalStep
    let number: Int
    @Binding var isExpanded: Bool
    /// Nil when the step can't move that way.
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Menu {
                Picker("Type", selection: $step.phase) {
                    Label("Work", systemImage: "figure.run").tag(Phase.work)
                    Label("Rest", systemImage: "figure.walk").tag(Phase.rest)
                }
                Button("Move Up", systemImage: "arrow.up") { onMoveUp?() }
                    .disabled(onMoveUp == nil)
                Button("Move Down", systemImage: "arrow.down") { onMoveDown?() }
                    .disabled(onMoveDown == nil)
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(step.phase.color)
                        .frame(width: 10, height: 10)
                    Text("\(number). \(step.phase == .work ? "Work" : "Rest")")
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.primary)

            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Spacer()
                    Text(TimeFormat.clock(step.seconds))
                        .monospacedDigit()
                        .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        if isExpanded {
            DurationPicker(seconds: $step.seconds)
        }
    }
}

/// A form row showing a duration that expands into `DurationPicker` when tapped.
struct DurationRow: View {
    let title: String
    @Binding var seconds: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(TimeFormat.clock(seconds))
                    .monospacedDigit()
                    .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
            }
        }
        .tint(.primary)
        if isExpanded {
            DurationPicker(seconds: $seconds)
        }
    }
}
