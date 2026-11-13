import XCTest
@testable import IntervalRun

final class ProgramProgressTests: XCTestCase {
    private let calendar = Calendar.current

    /// Three runs a week (Mon/Wed/Fri) for `weeks` weeks from Monday Oct 5, 2026.
    private func plan(weeks: Int = 3) -> ProgramPlan {
        let start = ProgramDate.date(from: "2026-10-05")!
        let workout = ProgramWorkout(warmUpSeconds: 300, steps: [.init(phase: .work, seconds: 600)], rounds: 1, skipLastRest: true, coolDownSeconds: 300)
        let days: [(Weekday, Int)] = [(.mon, 0), (.wed, 2), (.fri, 4)]
        return ProgramPlan(
            title: "Test plan",
            summary: "",
            startDate: "2026-10-05",
            weeks: (1...weeks).map { week in
                ProgramWeek(week: week, focus: "Week \(week)", sessions: days.map { day, offset in
                    let date = calendar.date(byAdding: .day, value: (week - 1) * 7 + offset, to: start)!
                    return ProgramSession(
                        id: "w\(week)-\(day.rawValue)", day: day, date: ProgramDate.string(from: date),
                        kind: "easy", title: "Run", description: "", workout: workout
                    )
                })
            }
        )
    }

    private func date(_ string: String, hour: Int = 12) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: ProgramDate.date(from: string)!)!
    }

    private func session(_ id: String, in plan: ProgramPlan) -> ProgramSession {
        plan.sessions.first { $0.id == id }!
    }

    func testCurrentWeekFollowsToday() {
        let p = plan()
        XCTAssertEqual(ProgramProgress(plan: p, doneSessionIDs: [], now: date("2026-10-05")).currentWeekIndex, 0)
        XCTAssertEqual(ProgramProgress(plan: p, doneSessionIDs: [], now: date("2026-10-11")).currentWeekIndex, 0) // Sunday
        XCTAssertEqual(ProgramProgress(plan: p, doneSessionIDs: [], now: date("2026-10-12")).currentWeekIndex, 1)
        XCTAssertEqual(ProgramProgress(plan: p, doneSessionIDs: [], now: date("2026-10-01")).currentWeekIndex, 0) // before the plan
        XCTAssertEqual(ProgramProgress(plan: p, doneSessionIDs: [], now: date("2026-11-30")).currentWeekIndex, 2) // after it
    }

    func testSessionStatuses() {
        let p = plan()
        let progress = ProgramProgress(plan: p, doneSessionIDs: ["w1-mon", "w1-wed"], now: date("2026-10-14"))
        XCTAssertEqual(progress.status(of: session("w1-mon", in: p)), .done)
        XCTAssertEqual(progress.status(of: session("w1-fri", in: p)), .missed)
        XCTAssertEqual(progress.status(of: session("w2-wed", in: p)), .today)
        XCTAssertEqual(progress.status(of: session("w3-mon", in: p)), .upcoming)
        XCTAssertEqual(progress.doneCount, 2)
        XCTAssertEqual(progress.totalCount, 9)
        XCTAssertEqual(progress.doneCount(in: p.weeks[0]), 2)
    }

    func testDoneTodayStillCountsAsDone() {
        let p = plan()
        let progress = ProgramProgress(plan: p, doneSessionIDs: ["w2-wed"], now: date("2026-10-14"))
        XCTAssertEqual(progress.status(of: session("w2-wed", in: p)), .done)
    }

    func testNextSessionIsTodaysUnlessDone() {
        let p = plan()
        XCTAssertEqual(ProgramProgress(plan: p, doneSessionIDs: [], now: date("2026-10-14")).nextSession?.id, "w2-wed")
        XCTAssertEqual(ProgramProgress(plan: p, doneSessionIDs: ["w2-wed"], now: date("2026-10-14")).nextSession?.id, "w2-fri")
        // Missed runs are skipped, not suggested.
        XCTAssertEqual(ProgramProgress(plan: p, doneSessionIDs: [], now: date("2026-10-13")).nextSession?.id, "w2-wed")
        XCTAssertNil(ProgramProgress(plan: p, doneSessionIDs: [], now: date("2026-11-30")).nextSession)
    }

    func testWeekDateRangeIsMondayToSunday() {
        let progress = ProgramProgress(plan: plan(), doneSessionIDs: [], now: date("2026-10-14"))
        let range = progress.dateRange(ofWeekAt: 1)
        XCTAssertEqual(range.map { ProgramDate.string(from: $0.lowerBound) }, "2026-10-12")
        XCTAssertEqual(range.map { ProgramDate.string(from: $0.upperBound) }, "2026-10-18")
    }

    func testSessionsOnADay() {
        let progress = ProgramProgress(plan: plan(), doneSessionIDs: [], now: date("2026-10-14"))
        XCTAssertEqual(progress.sessions(on: date("2026-10-14", hour: 18)).map(\.id), ["w2-wed"])
        XCTAssertEqual(progress.sessions(on: date("2026-10-15")).map(\.id), [])
    }

    func testMonthsCoveredByThePlan() {
        XCTAssertEqual(ProgramProgress(plan: plan(weeks: 3), doneSessionIDs: []).months.map { ProgramDate.string(from: $0) }, ["2026-10-01"])
        XCTAssertEqual(
            ProgramProgress(plan: plan(weeks: 9), doneSessionIDs: []).months.map { ProgramDate.string(from: $0) },
            ["2026-10-01", "2026-11-01", "2026-12-01"]
        )
    }
}
