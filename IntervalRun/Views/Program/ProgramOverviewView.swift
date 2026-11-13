import SwiftUI

/// The whole plan at a glance: one compact row per week with a dot per run.
struct ProgramOverviewView: View {
    let plan: ProgramPlan
    let progress: ProgramProgress
    /// Opens a week in Week view.
    let onSelectWeek: (Int) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(plan.weeks.enumerated()), id: \.element.id) { index, week in
                Button { onSelectWeek(index) } label: {
                    WeekRow(week: week, isCurrent: index == progress.currentWeekIndex, progress: progress)
                }
                .buttonStyle(.plain)
            }
            StatusLegend()
                .padding(.top, 4)
        }
    }
}

private struct WeekRow: View {
    let week: ProgramWeek
    let isCurrent: Bool
    let progress: ProgramProgress

    var body: some View {
        let done = progress.doneCount(in: week)
        let complete = !week.sessions.isEmpty && done == week.sessions.count
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Week \(week.week)").font(.headline)
                    if isCurrent {
                        Text("THIS WEEK")
                            .font(.caption2.weight(.heavy))
                            .tracking(0.5)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Phase.work.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(Phase.work.color)
                    }
                }
                Text(week.focus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(week.sessions) { session in
                        StatusDot(status: progress.status(of: session))
                    }
                }
            }
            Spacer()
            if complete {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(Phase.rest.color)
                    .accessibilityLabel("Week complete")
            } else {
                Text("\(done)/\(week.sessions.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 14).stroke(Phase.work.color, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A run's status as a small dot.
struct StatusDot: View {
    let status: ProgramProgress.Status
    var size: CGFloat = 12

    var body: some View {
        switch status {
        case .done:
            Circle().fill(Phase.rest.color).frame(width: size, height: size)
        case .today:
            Circle().fill(Phase.work.color).frame(width: size, height: size)
        case .upcoming:
            Circle()
                .fill(Phase.work.color.opacity(0.15))
                .overlay(Circle().stroke(Phase.work.color.opacity(0.6), lineWidth: 1))
                .frame(width: size, height: size)
        case .missed:
            Circle().fill(Color.secondary.opacity(0.35)).frame(width: size, height: size)
        }
    }
}

struct StatusLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(.done, "Done")
            item(.today, "Today")
            item(.upcoming, "Upcoming")
            item(.missed, "Missed")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(_ status: ProgramProgress.Status, _ label: String) -> some View {
        HStack(spacing: 4) {
            StatusDot(status: status, size: 9)
            Text(label)
        }
    }
}
