import SwiftUI

/// The plan as a month calendar. Tap a day to see its run.
struct ProgramCalendarView: View {
    let plan: ProgramPlan
    let progress: ProgramProgress

    /// Month shown; nil means the month containing today (within the plan).
    @State private var monthIndex: Int?
    @State private var selectedDay: Date?

    private var calendar: Calendar {
        var calendar = progress.calendar
        calendar.firstWeekday = 2 // Monday, like the plan's weeks
        return calendar
    }

    var body: some View {
        let months = progress.months
        if months.isEmpty {
            Text("No runs scheduled.").foregroundStyle(.secondary)
        } else {
            let index = min(monthIndex ?? defaultMonthIndex(months), months.count - 1)
            let month = months[index]
            let day = selectedDay ?? progress.today
            VStack(spacing: 14) {
                VStack(spacing: 10) {
                    header(month: month, index: index, count: months.count)
                    weekdayHeader
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                        ForEach(Array(cells(for: month).enumerated()), id: \.offset) { _, date in
                            if let date {
                                dayCell(date, isSelected: calendar.isDate(date, inSameDayAs: day))
                            } else {
                                Color.clear.frame(height: 40)
                            }
                        }
                    }
                    StatusLegend()
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                selectedDayDetail(day)
            }
        }
    }

    // MARK: Pieces

    private func header(month: Date, index: Int, count: Int) -> some View {
        HStack {
            Button {
                monthIndex = index - 1
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 36)
            }
            .disabled(index == 0)
            .accessibilityLabel("Previous month")
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
            Spacer()
            Button {
                monthIndex = index + 1
            } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 36)
            }
            .disabled(index >= count - 1)
            .accessibilityLabel("Next month")
        }
        .tint(Phase.work.color)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 4) {
            ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                Text(["M", "T", "W", "T", "F", "S", "S"][i])
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ date: Date, isSelected: Bool) -> some View {
        let sessions = progress.sessions(on: date)
        let status = sessions.first.map { progress.status(of: $0) }
        let isToday = calendar.isDate(date, inSameDayAs: progress.today)
        return Button {
            selectedDay = date
        } label: {
            ZStack {
                if let status {
                    Circle().fill(fill(for: status))
                }
                if isToday {
                    Circle().stroke(Phase.work.color, lineWidth: 2)
                }
                if isSelected {
                    Circle().stroke(Color.primary.opacity(0.6), lineWidth: 1.5).padding(-3)
                }
                Text(date.formatted(.dateTime.day()))
                    .font(.subheadline.weight(status == nil ? .regular : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(foreground(for: status))
            }
            .frame(width: 36, height: 36)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(date, sessions: sessions, status: status))
    }

    @ViewBuilder
    private func selectedDayDetail(_ day: Date) -> some View {
        let sessions = progress.sessions(on: day)
        VStack(alignment: .leading, spacing: 8) {
            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if sessions.isEmpty {
                Text("No run scheduled.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(sessions) { session in
                SessionCard(session: session, status: progress.status(of: session))
            }
        }
    }

    // MARK: Helpers

    private func defaultMonthIndex(_ months: [Date]) -> Int {
        months.lastIndex { $0 <= progress.today } ?? 0
    }

    /// Leading blanks so the 1st lands on its weekday (Monday first), then each day.
    private func cells(for month: Date) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: month)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
        return Array(repeating: nil, count: blanks) + days
    }

    private func fill(for status: ProgramProgress.Status) -> Color {
        switch status {
        case .done: Phase.rest.color
        case .today: Phase.work.color
        case .upcoming: Phase.work.color.opacity(0.15)
        case .missed: Color.secondary.opacity(0.2)
        }
    }

    private func foreground(for status: ProgramProgress.Status?) -> Color {
        switch status {
        case .done, .today: .white
        case .upcoming: Phase.work.color
        case .missed, nil: .primary
        }
    }

    private func accessibilityLabel(_ date: Date, sessions: [ProgramSession], status: ProgramProgress.Status?) -> String {
        let day = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard let session = sessions.first, let status else { return day }
        let state = switch status {
        case .done: "done"
        case .today: "today"
        case .upcoming: "upcoming"
        case .missed: "missed"
        }
        return "\(day), \(session.title), \(state)"
    }
}
