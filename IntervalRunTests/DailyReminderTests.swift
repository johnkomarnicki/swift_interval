import XCTest
@testable import IntervalRun

final class DailyReminderTests: XCTestCase {
    private let calendar = Calendar.current
    private let eightAM = 8 * 60

    /// Runs on Mon/Wed/Fri for two weeks from Monday Oct 5, 2026, each a
    /// 5 min warm-up, 20 min run and 5 min cool-down (30 min).
    private func plan() -> ProgramPlan {
        let start = ProgramDate.date(from: "2026-10-05")!
        let workout = ProgramWorkout(warmUpSeconds: 300, steps: [.init(phase: .work, seconds: 1200)], rounds: 1, skipLastRest: true, coolDownSeconds: 300)
        let days: [(Weekday, Int)] = [(.mon, 0), (.wed, 2), (.fri, 4)]
        return ProgramPlan(
            title: "Test plan",
            summary: "",
            startDate: "2026-10-05",
            weeks: (1...2).map { week in
                ProgramWeek(week: week, focus: "Week \(week)", sessions: days.map { day, offset in
                    let date = calendar.date(byAdding: .day, value: (week - 1) * 7 + offset, to: start)!
                    return ProgramSession(
                        id: "w\(week)-\(day.rawValue)", day: day, date: ProgramDate.string(from: date),
                        kind: "easy", title: "Easy 20", description: "", workout: workout
                    )
                })
            }
        )
    }

    private func date(_ string: String, hour: Int) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: ProgramDate.date(from: string)!)!
    }

    private func reminders(done: Set<String> = [], now: Date) -> [DailyReminder] {
        DailyReminderPlanner.reminders(plan: plan(), doneSessionIDs: done, minuteOfDay: eightAM, now: now)
    }

    func testRunDayNamesTheSessionAndRestDaySuggestsAWalk() {
        let result = reminders(now: date("2026-10-05", hour: 6))
        XCTAssertEqual(result.first?.fireDate, date("2026-10-05", hour: 8))
        XCTAssertEqual(result.first?.title, "Run day: Easy 20")
        XCTAssertEqual(result.first?.body, "Easy run, about 30 min. Open Runwise when you're ready to go.")
        XCTAssertEqual(result[1].title, "Rest day") // Tuesday
        XCTAssertTrue(result[1].body.contains("free walk"))
    }

    func testCoversEveryDayUntilTheLastRun() {
        // Mon Oct 5 to Fri Oct 16.
        let result = reminders(now: date("2026-10-05", hour: 6))
        XCTAssertEqual(result.count, 12)
        XCTAssertEqual(result.last?.fireDate, date("2026-10-16", hour: 8))
    }

    func testSkipsTodayOnceTheTimeHasPassed() {
        let result = reminders(now: date("2026-10-05", hour: 9))
        XCTAssertEqual(result.first?.fireDate, date("2026-10-06", hour: 8))
    }

    func testSkipsADayWhoseRunIsDone() {
        let result = reminders(done: ["w1-mon"], now: date("2026-10-05", hour: 6))
        XCTAssertEqual(result.first?.fireDate, date("2026-10-06", hour: 8))
    }

    func testNothingBeforeThePlanStartsOrAfterItEnds() {
        let before = reminders(now: date("2026-10-02", hour: 6))
        XCTAssertEqual(before.first?.fireDate, date("2026-10-05", hour: 8))
        XCTAssertTrue(reminders(now: date("2026-10-17", hour: 6)).isEmpty)
    }

    func testStopsAfterTheGivenNumberOfDays() {
        let result = DailyReminderPlanner.reminders(plan: plan(), doneSessionIDs: [], minuteOfDay: eightAM,
                                                    now: date("2026-10-05", hour: 6), days: 3)
        XCTAssertEqual(result.map(\.title), ["Run day: Easy 20", "Rest day", "Run day: Easy 20"])
    }
}
