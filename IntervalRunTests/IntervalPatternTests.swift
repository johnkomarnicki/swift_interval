import XCTest
@testable import IntervalRun

final class IntervalPatternTests: XCTestCase {
    /// Jog 1:30, walk 1:30, jog 3:00, walk 3:00, twice.
    private let jogWalkSteps = [
        IntervalStep(phase: .work, seconds: 90),
        IntervalStep(phase: .rest, seconds: 90),
        IntervalStep(phase: .work, seconds: 180),
        IntervalStep(phase: .rest, seconds: 180),
    ]

    private func jogWalk(skipLastRest: Bool = false, warmUp: Bool = false, coolDown: Bool = false) -> WorkoutPlan {
        WorkoutPlan(
            warmUpEnabled: warmUp,
            warmUpSeconds: 300,
            rounds: 2,
            skipLastRest: skipLastRest,
            coolDownEnabled: coolDown,
            coolDownSeconds: 300,
            usesPattern: true,
            pattern: jogWalkSteps
        )
    }

    private func pattern(_ steps: [(Phase, Int)], rounds: Int, skipLastRest: Bool) -> WorkoutPlan {
        WorkoutPlan(
            rounds: rounds,
            skipLastRest: skipLastRest,
            usesPattern: true,
            pattern: steps.map { IntervalStep(phase: $0.0, seconds: $0.1) }
        )
    }

    // MARK: Segments

    func testJogWalkPatternRunsTwice() {
        XCTAssertEqual(jogWalk().segments, [
            Segment(.work, 90, round: 1), Segment(.rest, 90, round: 1),
            Segment(.work, 180, round: 1), Segment(.rest, 180, round: 1),
            Segment(.work, 90, round: 2), Segment(.rest, 90, round: 2),
            Segment(.work, 180, round: 2), Segment(.rest, 180, round: 2),
        ])
        XCTAssertEqual(jogWalk().totalSeconds, 18 * 60)
    }

    func testSkipLastRestDropsFinalWalk() {
        let segments = jogWalk(skipLastRest: true).segments
        XCTAssertEqual(segments.count, 7)
        XCTAssertEqual(segments.last, Segment(.work, 180, round: 2))
        XCTAssertEqual(jogWalk(skipLastRest: true).totalSeconds, 15 * 60)
    }

    func testPatternWithWarmUpAndCoolDown() {
        let segments = jogWalk(skipLastRest: true, warmUp: true, coolDown: true).segments
        XCTAssertEqual(segments.first, Segment(.warmUp, 300))
        XCTAssertEqual(Array(segments.suffix(2)), [Segment(.work, 180, round: 2), Segment(.coolDown, 300)])
        XCTAssertEqual(segments.count, 9)
    }

    func testSkipLastRestDropsEveryTrailingRestOfLastRound() {
        let plan = pattern([(.work, 60), (.rest, 30), (.rest, 20)], rounds: 2, skipLastRest: true)
        XCTAssertEqual(plan.segments, [
            Segment(.work, 60, round: 1), Segment(.rest, 30, round: 1), Segment(.rest, 20, round: 1),
            Segment(.work, 60, round: 2),
        ])
    }

    func testSkipLastRestLeavesPatternEndingInWorkAlone() {
        let plan = pattern([(.rest, 30), (.work, 60)], rounds: 2, skipLastRest: true)
        XCTAssertEqual(plan.segments, [
            Segment(.rest, 30, round: 1), Segment(.work, 60, round: 1),
            Segment(.rest, 30, round: 2), Segment(.work, 60, round: 2),
        ])
    }

    func testSimpleModeIgnoresStoredPattern() {
        var plan = jogWalk()
        plan.usesPattern = false
        plan.workSeconds = 60
        plan.restSeconds = 30
        plan.rounds = 1
        XCTAssertEqual(plan.segments, [Segment(.work, 60, round: 1), Segment(.rest, 30, round: 1)])
    }

    // MARK: Switching modes

    func testSwitchingToPatternStartsFromWorkAndRest() {
        var plan = WorkoutPlan(workSeconds: 45, restSeconds: 15)
        plan.setUsesPattern(true)
        XCTAssertTrue(plan.usesPattern)
        XCTAssertEqual(plan.pattern.map(\.phase), [.work, .rest])
        XCTAssertEqual(plan.pattern.map(\.seconds), [45, 15])
    }

    func testSwitchingToPatternWithZeroRestStartsWithWorkOnly() {
        var plan = WorkoutPlan(workSeconds: 45, restSeconds: 0)
        plan.setUsesPattern(true)
        XCTAssertEqual(plan.pattern.map(\.phase), [.work])
    }

    func testSwitchingBackAndForthKeepsPattern() {
        var plan = jogWalk()
        plan.setUsesPattern(false)
        plan.setUsesPattern(true)
        XCTAssertEqual(plan.pattern, jogWalkSteps)
    }

    // MARK: Summary and validation

    func testPatternSummary() {
        XCTAssertEqual(jogWalk().summary, "2 × (1:30 / 1:30 / 3:00 / 3:00)")
        XCTAssertEqual(
            jogWalk(warmUp: true, coolDown: true).summary,
            "5:00 warm-up · 2 × (1:30 / 1:30 / 3:00 / 3:00) · 5:00 cool-down"
        )
    }

    func testPatternValidation() {
        XCTAssertTrue(jogWalk().isValid)
        XCTAssertFalse(pattern([], rounds: 2, skipLastRest: true).isValid)
        XCTAssertFalse(pattern([(.rest, 60)], rounds: 2, skipLastRest: true).isValid)
        XCTAssertFalse(pattern([(.work, 60), (.rest, 0)], rounds: 2, skipLastRest: true).isValid)
        // The simple-mode work field doesn't matter in pattern mode.
        var plan = jogWalk()
        plan.workSeconds = 0
        XCTAssertTrue(plan.isValid)
    }

    // MARK: Storage

    func testWorkoutStoresPattern() {
        let plan = jogWalk(skipLastRest: true, warmUp: true)
        let workout = Workout(name: "Jog/walk", plan: plan)
        XCTAssertEqual(workout.plan, plan)
        XCTAssertEqual(workout.duplicate().plan, plan)
    }

    func testWorkoutWithoutPatternLoadsAsSimple() {
        let workout = Workout.sample()
        XCTAssertNil(workout.patternData)
        XCTAssertFalse(workout.plan.usesPattern)
        XCTAssertEqual(workout.plan.pattern, [])
    }

    // MARK: Beeps

    func testSwitchTonesAtEveryPatternStep() {
        let cues = CuePlanner.cues(for: jogWalk().segments)
        XCTAssertEqual(
            cues.filter { $0.kind == .transition }.map(\.offset),
            [0, 90, 180, 360, 540, 630, 720, 900]
        )
        XCTAssertEqual(cues.last, Cue(offset: 1080, kind: .finish))
        XCTAssertEqual(cues.filter { $0.kind == .countdown }.count, 8 * 5)
    }
}
