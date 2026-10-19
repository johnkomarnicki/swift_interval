import XCTest
@testable import IntervalRun

final class WorkoutPlanTests: XCTestCase {
    private func plan(
        warmUp: Int? = nil,
        work: Int = 90,
        rest: Int = 60,
        rounds: Int = 3,
        skipLastRest: Bool = true,
        coolDown: Int? = nil
    ) -> WorkoutPlan {
        WorkoutPlan(
            warmUpEnabled: warmUp != nil,
            warmUpSeconds: warmUp ?? 300,
            workSeconds: work,
            restSeconds: rest,
            rounds: rounds,
            skipLastRest: skipLastRest,
            coolDownEnabled: coolDown != nil,
            coolDownSeconds: coolDown ?? 300
        )
    }

    // MARK: Segments

    func testSegmentsWithoutWarmUpOrCoolDownSkippingLastRest() {
        XCTAssertEqual(plan().segments, [
            Segment(.work, 90, round: 1), Segment(.rest, 60, round: 1),
            Segment(.work, 90, round: 2), Segment(.rest, 60, round: 2),
            Segment(.work, 90, round: 3),
        ])
    }

    func testSegmentsKeepingLastRest() {
        XCTAssertEqual(plan(skipLastRest: false).segments, [
            Segment(.work, 90, round: 1), Segment(.rest, 60, round: 1),
            Segment(.work, 90, round: 2), Segment(.rest, 60, round: 2),
            Segment(.work, 90, round: 3), Segment(.rest, 60, round: 3),
        ])
    }

    func testSegmentsWithWarmUpAndCoolDown() {
        XCTAssertEqual(plan(warmUp: 300, rounds: 2, coolDown: 240).segments, [
            Segment(.warmUp, 300),
            Segment(.work, 90, round: 1), Segment(.rest, 60, round: 1),
            Segment(.work, 90, round: 2),
            Segment(.coolDown, 240),
        ])
    }

    func testSegmentsWithWarmUpAndCoolDownKeepingLastRest() {
        XCTAssertEqual(plan(warmUp: 60, rounds: 1, skipLastRest: false, coolDown: 60).segments, [
            Segment(.warmUp, 60),
            Segment(.work, 90, round: 1), Segment(.rest, 60, round: 1),
            Segment(.coolDown, 60),
        ])
    }

    func testDisabledWarmUpAndCoolDownAreLeftOut() {
        var p = plan(warmUp: 300, rounds: 1, coolDown: 300)
        p.warmUpEnabled = false
        p.coolDownEnabled = false
        XCTAssertEqual(p.segments, [Segment(.work, 90, round: 1)])
    }

    func testZeroRestMeansNoRestSegments() {
        XCTAssertEqual(plan(rest: 0, rounds: 3, skipLastRest: false).segments, [
            Segment(.work, 90, round: 1), Segment(.work, 90, round: 2), Segment(.work, 90, round: 3),
        ])
    }

    func testRoundsAreClampedToValidRange() {
        XCTAssertEqual(plan(rest: 0, rounds: 0).segments.count, 1)
        XCTAssertEqual(plan(rest: 0, rounds: 99).segments.count, 50)
    }

    // MARK: Totals

    func testTotalSeconds() {
        // 300 + 6×90 + 5×60 + 300
        XCTAssertEqual(plan(warmUp: 300, rounds: 6, coolDown: 300).totalSeconds, 300 + 540 + 300 + 300)
        // Keeping the last rest adds one more 60 s.
        XCTAssertEqual(plan(warmUp: 300, rounds: 6, skipLastRest: false, coolDown: 300).totalSeconds, 1500)
        XCTAssertEqual(plan(work: 30, rest: 0, rounds: 4).totalSeconds, 120)
    }

    func testSampleWorkoutTotalIs24Minutes() {
        XCTAssertEqual(Workout.sample().plan.totalSeconds, 24 * 60)
    }

    // MARK: Summary and validation

    func testSummary() {
        XCTAssertEqual(
            plan(warmUp: 300, rounds: 6, coolDown: 300).summary,
            "5:00 warm-up · 6 × 1:30 / 1:00 · 5:00 cool-down"
        )
        XCTAssertEqual(plan(work: 45, rest: 0, rounds: 8).summary, "8 × 0:45")
    }

    func testValidation() {
        XCTAssertTrue(plan().isValid)
        XCTAssertTrue(plan(rest: 0).isValid)
        XCTAssertFalse(plan(work: 0).isValid)
        XCTAssertFalse(plan(warmUp: 0).isValid)
        XCTAssertFalse(plan(coolDown: 0).isValid)
        XCTAssertFalse(plan(rounds: 51).isValid)
    }

    // MARK: Formatting

    func testClockFormatting() {
        XCTAssertEqual(TimeFormat.clock(0), "0:00")
        XCTAssertEqual(TimeFormat.clock(5), "0:05")
        XCTAssertEqual(TimeFormat.clock(90), "1:30")
        XCTAssertEqual(TimeFormat.clock(3599), "59:59")
        XCTAssertEqual(TimeFormat.clock(3661), "1:01:01")
    }

    func testCountdownRoundsUp() {
        XCTAssertEqual(TimeFormat.countdown(90), "1:30")
        XCTAssertEqual(TimeFormat.countdown(89.2), "1:30")
        XCTAssertEqual(TimeFormat.countdown(0.3), "0:01")
        XCTAssertEqual(TimeFormat.countdown(5.0000000001), "0:05")
        XCTAssertEqual(TimeFormat.countdown(0), "0:00")
    }
}
