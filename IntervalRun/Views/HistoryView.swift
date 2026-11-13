import SwiftData
import SwiftUI

enum HistoryFilter: CaseIterable {
    case all, runs, walks

    var title: String {
        switch self {
        case .all: "All"
        case .runs: "Runs"
        case .walks: "Walks"
        }
    }
}

extension WorkoutRecord {
    /// A free walk. Everything else, interval workouts included, counts as running.
    var isWalk: Bool { freeActivity == .walk }
}

/// Past workouts: this month's totals and miles per week, then every workout
/// grouped by week, newest first.
struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutRecord.date, order: .reverse) private var records: [WorkoutRecord]
    @State private var filter = HistoryFilter.all

    /// Weeks run Monday to Sunday, as in the plan.
    private static let calendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle(eyebrow: records.count == 1 ? "1 ACTIVITY" : "\(records.count) ACTIVITIES", title: "History")
                        .padding(.top, 16)

                    if records.isEmpty {
                        ContentUnavailableView(
                            "No Workouts Yet",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Finished workouts show up here with their distances.")
                        )
                        .padding(.top, 60)
                    } else {
                        HistorySummaryCard(records: records, calendar: Self.calendar)
                            .padding(.top, 20)
                        PillPicker(options: HistoryFilter.allCases, title: \.title, selection: $filter)
                            .padding(.top, 20)
                        weeks
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color(.systemGroupedBackground))
            .clearsTabBar()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var filtered: [WorkoutRecord] {
        switch filter {
        case .all: records
        case .runs: records.filter { !$0.isWalk }
        case .walks: records.filter(\.isWalk)
        }
    }

    @ViewBuilder
    private var weeks: some View {
        let groups = Dictionary(grouping: filtered) { Self.weekStart(of: $0.date) }
        if groups.isEmpty {
            Text(filter == .walks ? "No walks yet." : "No runs yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
        ForEach(groups.keys.sorted(by: >), id: \.self) { week in
            let records = groups[week] ?? []
            CardSection(title: title(forWeek: week), detail: miles(records)) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        Divider().padding(.leading, 74)
                    }
                    NavigationLink {
                        HistoryDetailView(record: record)
                    } label: {
                        HistoryRow(record: record)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            SyncService.delete(record, in: modelContext)
                        }
                    }
                }
            }
            .padding(.top, 28)
        }
    }

    static func weekStart(of date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// "This week", "Last week" or "Week of Oct 12".
    private func title(forWeek start: Date) -> String {
        let thisWeek = Self.weekStart(of: .now)
        if start == thisWeek { return "This week" }
        if let last = Self.calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek), start == last { return "Last week" }
        return "Week of \(start.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// "6.12 mi", or nil when none of them tracked distance.
    private func miles(_ records: [WorkoutRecord]) -> String? {
        let meters = records.compactMap(\.totalMeters)
        return meters.isEmpty ? nil : DistanceFormat.short(meters.reduce(0, +))
    }
}

/// This month's distance, time and count, over a chart of miles per week for
/// the last six weeks, split into running and walking.
private struct HistorySummaryCard: View {
    let records: [WorkoutRecord]
    let calendar: Calendar

    private static let weekCount = 6
    private static let chartHeight: CGFloat = 100

    var body: some View {
        let month = calendar.dateInterval(of: .month, for: .now)
        let monthRecords = records.filter { month?.contains($0.date) ?? false }
        let weeks = self.weeks
        let largest = max(weeks.map { $0.running + $0.walking }.max() ?? 0, 0.1)
        VStack(alignment: .leading, spacing: 16) {
            Text(Date.now.formatted(.dateTime.month(.wide)).uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            HStack(alignment: .top) {
                stat(String(format: "%.1f", DistanceFormat.miles(monthRecords.compactMap(\.totalMeters).reduce(0, +))), unit: "mi", label: "Distance")
                stat(Self.duration(monthRecords.reduce(0) { $0 + $1.displayTime }), label: "Time")
                stat("\(monthRecords.count)", label: monthRecords.count == 1 ? "Activity" : "Activities")
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    column(week, largest: largest, isNow: index == weeks.count - 1)
                }
            }
            .padding(.top, 8)

            Divider()

            HStack(spacing: 14) {
                legend("Running", Phase.work.color)
                legend("Walking", Phase.rest.color)
                Spacer()
                Text("Miles per week")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private struct Week {
        let start: Date
        var running: Double = 0
        var walking: Double = 0
    }

    /// Miles run and walked in each of the last six weeks, oldest first.
    private var weeks: [Week] {
        let thisWeek = HistoryListView.weekStart(of: .now)
        var weeks = (0..<Self.weekCount).compactMap { offset in
            calendar.date(byAdding: .weekOfYear, value: offset - (Self.weekCount - 1), to: thisWeek).map { Week(start: $0) }
        }
        for record in records {
            guard let meters = record.totalMeters,
                  let index = weeks.firstIndex(where: { $0.start == HistoryListView.weekStart(of: record.date) }) else { continue }
            if record.isWalk {
                weeks[index].walking += DistanceFormat.miles(meters)
            } else {
                weeks[index].running += DistanceFormat.miles(meters)
            }
        }
        return weeks
    }

    private func column(_ week: Week, largest: Double, isNow: Bool) -> some View {
        VStack(spacing: 8) {
            VStack(spacing: 4) {
                Spacer(minLength: 0)
                if week.running + week.walking == 0 {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 4)
                }
                if week.walking > 0 {
                    bar(Phase.rest.color, height: Self.chartHeight * week.walking / largest)
                }
                if week.running > 0 {
                    bar(Phase.work.color, height: Self.chartHeight * week.running / largest)
                }
            }
            .frame(height: Self.chartHeight)
            Text(isNow ? "Now" : "\(calendar.component(.month, from: week.start))/\(calendar.component(.day, from: week.start))")
                .font(.caption2.weight(isNow ? .bold : .medium))
                .foregroundStyle(isNow ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isNow ? "This week" : "Week of \(week.start.formatted(.dateTime.month(.wide).day()))"): \(String(format: "%.1f", week.running)) miles running, \(String(format: "%.1f", week.walking)) miles walking")
    }

    private func bar(_ color: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color)
            .frame(height: max(height, 6))
    }

    private func stat(_ value: String, unit: String? = nil, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title.weight(.bold))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
    }

    /// "5h 45m", or "45m" under an hour.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// A workout in the list: what it was, when, how far and how long. Free runs
/// and walks are named for the time of day and tagged "Free".
private struct HistoryRow: View {
    let record: WorkoutRecord

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(
                systemImage: record.isWalk ? "figure.walk" : "figure.run",
                tint: record.isWalk ? Phase.rest.color : Phase.work.color,
                size: 44
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(record.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(record.date.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if record.freeActivity != nil {
                        Text("Free")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let meters = record.totalMeters {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.2f", DistanceFormat.miles(meters)))
                            .font(.headline)
                            .monospacedDigit()
                        Text("mi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(TimeFormat.clock(Int(record.displayTime.rounded())))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// "Evening walk" for a free run or walk; the workout's name otherwise.
    private var title: String {
        guard let activity = record.freeActivity else {
            return record.name.isEmpty ? "Untitled workout" : record.name
        }
        let hour = Calendar.current.component(.hour, from: record.date)
        let part = switch hour {
        case 5..<12: "Morning"
        case 12..<17: "Afternoon"
        case 17..<21: "Evening"
        default: "Night"
        }
        return "\(part) \(activity.title.lowercased())"
    }
}

/// One past workout with its interval breakdown.
struct HistoryDetailView: View {
    let record: WorkoutRecord

    var body: some View {
        let intervals = record.intervals
        List {
            Section {
                LabeledContent("Date") {
                    Text(record.date, format: .dateTime.weekday(.wide).month().day().year().hour().minute())
                }
                if record.freeActivity != nil {
                    LabeledContent("Time", value: TimeFormat.clock(Int(record.activeTime.rounded())))
                    if record.totalTime - record.activeTime >= 1 {
                        LabeledContent("Including pauses", value: TimeFormat.clock(Int(record.totalTime.rounded())))
                    }
                } else {
                    LabeledContent("Total time", value: TimeFormat.clock(Int(record.totalTime.rounded())))
                }
                if let meters = record.totalMeters {
                    LabeledContent("Distance", value: DistanceFormat.short(meters))
                    LabeledContent("Average pace", value: DistanceFormat.pace(seconds: record.activeTime, meters: meters))
                    if let work = workSummary(intervals) {
                        LabeledContent("Work intervals", value: work)
                    }
                    if record.freeActivity != nil, intervals.first?.source == .steps {
                        Label("Measured mostly by the step counter", systemImage: "figure.walk")
                            .foregroundStyle(.secondary)
                    }
                }
                if let average = intervals.averageHeartRate, let max = intervals.maxHeartRate {
                    LabeledContent("Heart rate", value: "\(average) avg · \(max) max")
                    if let recovery = intervals.averageRecovery {
                        LabeledContent("Drop during rests", value: "\(recovery) bpm")
                    }
                }
                if !record.completed {
                    Label("Ended early", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if !record.isWalk, let recordID = record.syncID {
                HistoryCoachSection(recordID: recordID)
            }

            if !intervals.isEmpty, record.freeActivity == nil {
                if let averages = intervals.roundAverages {
                    // Every round runs the same steps, so show one averaged round
                    // and keep each round's own numbers one tap away.
                    Section("Intervals") {
                        if let first = intervals.first, first.round == nil {
                            IntervalResultRow(result: first)
                        }
                        HStack {
                            Label(roundsLabel(intervals), systemImage: "repeat")
                            Spacer()
                            Text("Average")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline.weight(.semibold))
                        ForEach(averages) { average in
                            IntervalResultRow(result: average, title: average.phase == .work ? "Work" : "Rest")
                                .padding(.leading, 20)
                        }
                        if let last = intervals.last, last.round == nil {
                            IntervalResultRow(result: last)
                        }
                    }
                    Section {
                        DisclosureGroup("Each round") {
                            ForEach(intervals.filter { $0.round != nil }) { interval in
                                IntervalResultRow(result: interval)
                            }
                        }
                    }
                } else {
                    Section("Intervals") {
                        ForEach(intervals) { interval in
                            IntervalResultRow(result: interval)
                        }
                    }
                }
            }
        }
        .navigationTitle(record.name.isEmpty ? "Untitled workout" : record.name)
        .clearsTabBar()
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "6 rounds", or "4 of 6 rounds" when ended early.
    private func roundsLabel(_ intervals: [IntervalResult]) -> String {
        let run = intervals.roundsRun, total = intervals.roundCount
        return run == total ? "\(total) rounds" : "\(run) of \(total) rounds"
    }

    /// Distance and pace over just the work intervals, e.g. "1.32 mi · 8:05 /mi".
    private func workSummary(_ intervals: [IntervalResult]) -> String? {
        guard record.freeActivity == nil else { return nil }
        let work = intervals.filter { $0.phase == .work && !$0.wasSkipped }
        let meters = work.compactMap(\.meters).reduce(0, +)
        guard !work.isEmpty, meters > 0 else { return nil }
        let seconds = work.reduce(0) { $0 + $1.activeSeconds }
        return "\(DistanceFormat.short(meters)) · \(DistanceFormat.pace(seconds: seconds, meters: meters))"
    }
}
