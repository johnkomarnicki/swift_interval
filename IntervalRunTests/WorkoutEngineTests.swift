import XCTest
@testable import IntervalRun

final class WorkoutEngineTests: XCTestCase {
    /// warm-up 60 · work 30 · rest 20 · work 30 · cool-down 40  (total 180 s)
    private let segments = [
        Segment(.warmUp, 60),
        Segment(.work, 30, round: 1),
        Segment(.rest, 20, round: 1),
        Segment(.work, 30, round: 2),
        Segment(.coolDown, 40),
    ]
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func startedEngine() -> WorkoutEngine {
        var engine = WorkoutEngine(segments: segments)
        engine.start(at: t0)
        return engine
    }

    func testSegmentStartsAndTotal() {
        let engine = WorkoutEngine(segments: segments)
        XCTAssertEqual(engine.segmentStarts, [0, 60, 90, 110, 140])
        XCTAssertEqual(engine.totalDuration, 180)
    }

    func testStatusAtStart() {
        let status = startedEngine().status(at: t0)
        XCTAssertEqual(status.segmentIndex, 0)
        XCTAssertEqual(status.timeLeftInSegment, 60)
        XCTAssertEqual(status.totalRemaining, 180)
    }

    func testStatusMidSegment() {
        let status = startedEngine().status(at: at(75.5))
        XCTAssertEqual(status.segmentIndex, 1)
        XCTAssertEqual(status.timeLeftInSegment, 14.5, accuracy: 1e-6)
        XCTAssertEqual(status.totalRemaining, 104.5, accuracy: 1e-6)
    }

    func testBoundaryBelongsToNextSegment() {
        let engine = startedEngine()
        XCTAssertEqual(engine.status(at: at(59.999)).segmentIndex, 0)
        XCTAssertEqual(engine.status(at: at(60)).segmentIndex, 1)
        XCTAssertEqual(engine.status(at: at(60)).timeLeftInSegment, 30, accuracy: 1e-6)
        XCTAssertEqual(engine.status(at: at(110)).segmentIndex, 3)
        XCTAssertEqual(engine.status(at: at(140)).segmentIndex, 4)
    }

    func testFinishedAtAndAfterEnd() {
        let engine = startedEngine()
        XCTAssertTrue(engine.status(at: at(180)).isFinished)
        let later = engine.status(at: at(500))
        XCTAssertTrue(later.isFinished)
        XCTAssertEqual(later.totalRemaining, 0)
        XCTAssertEqual(later.elapsed, 180)
    }

    func testNotStartedShowsFirstSegmentFull() {
        let engine = WorkoutEngine(segments: segments)
        let status = engine.status(at: at(1000))
        XCTAssertEqual(status.segmentIndex, 0)
        XCTAssertEqual(status.timeLeftInSegment, 60)
    }

    func testLongWorkoutDoesNotDrift() {
        // 50 rounds of 30 s work / 30 s rest = 3000 s, checked deep into the workout.
        let plan = WorkoutPlan(workSeconds: 30, restSeconds: 30, rounds: 50, skipLastRest: false)
        var engine = WorkoutEngine(segments: plan.segments)
        engine.start(at: t0)
        let status = engine.status(at: at(2_400 + 25))
        XCTAssertEqual(status.segmentIndex, 80) // round 41 work
        XCTAssertEqual(status.timeLeftInSegment, 5, accuracy: 1e-6)
    }

    // MARK: Pause and resume

    func testPauseFreezesTime() {
        var engine = startedEngine()
        engine.pause(at: at(30))
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.elapsed(at: at(30)), 30)
        XCTAssertEqual(engine.elapsed(at: at(300)), 30)
        XCTAssertEqual(engine.status(at: at(300)).timeLeftInSegment, 30)
    }

    func testResumeShiftsScheduleByPauseLength() {
        var engine = startedEngine()
        engine.pause(at: at(30))
        engine.resume(at: at(130)) // paused 100 s
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(engine.accumulatedPause, 100)
        XCTAssertEqual(engine.elapsed(at: at(140)), 40)
        // Warm-up now ends at real time 160 instead of 60.
        XCTAssertEqual(engine.status(at: at(159)).segmentIndex, 0)
        XCTAssertEqual(engine.status(at: at(160)).segmentIndex, 1)
        XCTAssertEqual(engine.date(forElapsed: 60), at(160))
    }

    func testMultiplePausesAccumulate() {
        var engine = startedEngine()
        engine.pause(at: at(10))
        engine.resume(at: at(20))
        engine.pause(at: at(50))
        engine.resume(at: at(65))
        XCTAssertEqual(engine.accumulatedPause, 25)
        XCTAssertEqual(engine.elapsed(at: at(100)), 75)
    }

    func testDoublePauseAndResumeWithoutPauseAreIgnored() {
        var engine = startedEngine()
        engine.resume(at: at(10))
        XCTAssertEqual(engine.accumulatedPause, 0)
        engine.pause(at: at(10))
        engine.pause(at: at(20))
        engine.resume(at: at(30))
        XCTAssertEqual(engine.accumulatedPause, 20)
    }

    func testDateForElapsedIsNilWhilePaused() {
        var engine = startedEngine()
        engine.pause(at: at(5))
        XCTAssertNil(engine.date(forElapsed: 60))
    }

    // MARK: Skip

    func testSkipJumpsToNextSegmentStart() {
        var engine = startedEngine()
        engine.skip(at: at(20))
        let status = engine.status(at: at(20))
        XCTAssertEqual(status.segmentIndex, 1)
        XCTAssertEqual(status.timeLeftInSegment, 30)
        XCTAssertEqual(engine.skippedTime, 40)
        // Rest of the schedule keeps running from there.
        XCTAssertEqual(engine.status(at: at(50)).segmentIndex, 2)
        XCTAssertEqual(engine.date(forElapsed: 90), at(50))
    }

    func testSkipFromLastSegmentFinishes() {
        var engine = startedEngine()
        engine.skip(at: at(150))
        XCTAssertTrue(engine.status(at: at(150)).isFinished)
    }

    func testSkipWhilePausedStaysPaused() {
        var engine = startedEngine()
        engine.pause(at: at(10))
        engine.skip(at: at(15))
        XCTAssertEqual(engine.status(at: at(40)).segmentIndex, 1)
        XCTAssertEqual(engine.status(at: at(40)).timeLeftInSegment, 30)
        engine.resume(at: at(40))
        XCTAssertEqual(engine.status(at: at(50)).timeLeftInSegment, 20, accuracy: 1e-6)
    }

    func testPauseThenSkipThenResumeCombined() {
        var engine = startedEngine()
        engine.pause(at: at(70))   // 10 s into work 1
        engine.resume(at: at(100)) // 30 s pause
        engine.skip(at: at(105))   // 15 s into work 1 -> rest 1 at elapsed 90
        let status = engine.status(at: at(105))
        XCTAssertEqual(status.segmentIndex, 2)
        XCTAssertEqual(status.elapsed, 90, accuracy: 1e-6)
        XCTAssertEqual(engine.date(forElapsed: 110), at(125))
    }
}
