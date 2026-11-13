import Foundation

/// Where the runner is in a plan: which sessions are done, today, missed or
/// upcoming, and which week is the current one. Pure, so it can be unit tested.
struct ProgramProgress {
    enum Status: Equatable {
        case done, today, upcoming, missed
    }

    let plan: ProgramPlan
    let doneSessionIDs: Set<String>
    let calendar: Calendar
    /// Midnight today.
    let today: Date

    init(plan: ProgramPlan, doneSessionIDs: Set<String>, now: Date = .now, calendar: Calendar = .current) {
        self.plan = plan
        self.doneSessionIDs = doneSessionIDs
        self.calendar = calendar
        self.today = calendar.startOfDay(for: now)
    }

    var totalCount: Int { plan.sessions.count }

    var doneCount: Int { plan.sessions.filter { doneSessionIDs.contains($0.id) }.count }

    func status(of session: ProgramSession) -> Status {
        if doneSessionIDs.contains(session.id) { return .done }
        guard let date = session.calendarDate else { return .upcoming }
        if calendar.isDate(date, inSameDayAs: today) { return .today }
        return date < today ? .missed : .upcoming
    }

    /// The first unfinished session from today on.
    var nextSession: ProgramSession? {
        plan.sessions.first { session in
            !doneSessionIDs.contains(session.id) && (session.calendarDate ?? .distantPast) >= today
        }
    }

    /// The week containing today (the first week before the plan starts, the
    /// last one after it ends).
    var currentWeekIndex: Int {
        guard !plan.weeks.isEmpty, let start = ProgramDate.date(from: plan.startDate) else { return 0 }
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return min(max(days >= 0 ? days / 7 : 0, 0), plan.weeks.count - 1)
    }

    func doneCount(in week: ProgramWeek) -> Int {
        week.sessions.filter { doneSessionIDs.contains($0.id) }.count
    }

    /// First and last day of a week (Monday to Sunday).
    func dateRange(ofWeekAt index: Int) -> ClosedRange<Date>? {
        guard let start = ProgramDate.date(from: plan.startDate),
              let first = calendar.date(byAdding: .day, value: index * 7, to: start),
              let last = calendar.date(byAdding: .day, value: 6, to: first) else { return nil }
        return first...last
    }

    /// Sessions on a given day.
    func sessions(on day: Date) -> [ProgramSession] {
        plan.sessions.filter { session in
            session.calendarDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        }
    }

    /// The first day of each month the plan covers.
    var months: [Date] {
        let dates = plan.sessions.compactMap(\.calendarDate)
        guard let first = dates.min(), let last = dates.max(),
              var month = calendar.dateInterval(of: .month, for: first)?.start,
              let lastMonth = calendar.dateInterval(of: .month, for: last)?.start else { return [] }
        var result: [Date] = []
        while month <= lastMonth {
            result.append(month)
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return result
    }
}
