import XCTest
@testable import IntervalRun

final class CuePlannerTests: XCTestCase {
    private func offsets(_ cues: [Cue], _ kind: CueKind) -> [TimeInterval] {
        cues.filter { $0.kind == kind }.map(\.offset)
    }

    func testBeepsInLastFiveSecondsOfEveryInterval() {
        let cues = CuePlanner.cues(for: [Segment(.warmUp, 60), Segment(.work, 30, round: 1)])
        XCTAssertEqual(offsets(cues, .countdown), [55, 56, 57, 58, 59, 85, 86, 87, 88, 89])
        XCTAssertEqual(offsets(cues, .transition), [0, 60])
        XCTAssertEqual(offsets(cues, .finish), [90])
    }

    func testCuesAreInTimeOrder() {
        let plan = WorkoutPlan(warmUpEnabled: true, warmUpSeconds: 20, workSeconds: 7, restSeconds: 3, rounds: 4, coolDownEnabled: true, coolDownSeconds: 10)
        let cues = CuePlanner.cues(for: plan.segments)
        XCTAssertEqual(cues.map(\.offset), cues.map(\.offset).sorted())
        XCTAssertEqual(cues.last, Cue(offset: TimeInterval(plan.totalSeconds), kind: .finish))
    }

    func testSixSecondIntervalGetsAllFiveBeeps() {
        let cues = CuePlanner.cues(for: [Segment(.work, 6, round: 1)])
        XCTAssertEqual(offsets(cues, .countdown), [1, 2, 3, 4, 5])
    }

    func testShortIntervalsOnlyBeepForSecondsThatExist() {
        // Beep at "N seconds left" where N equals the interval length would collide
        // with the transition tone at its start, so it is left out.
        XCTAssertEqual(offsets(CuePlanner.cues(for: [Segment(.rest, 5, round: 1)]), .countdown), [1, 2, 3, 4])
        XCTAssertEqual(offsets(CuePlanner.cues(for: [Segment(.rest, 3, round: 1)]), .countdown), [1, 2])
        XCTAssertEqual(offsets(CuePlanner.cues(for: [Segment(.rest, 2, round: 1)]), .countdown), [1])
        XCTAssertEqual(offsets(CuePlanner.cues(for: [Segment(.rest, 1, round: 1)]), .countdown), [])
    }

    func testShortIntervalInsideWorkout() {
        let cues = CuePlanner.cues(for: [Segment(.work, 10, round: 1), Segment(.rest, 3, round: 1), Segment(.work, 10, round: 2)])
        XCTAssertEqual(offsets(cues, .countdown), [5, 6, 7, 8, 9, 11, 12, 18, 19, 20, 21, 22])
        XCTAssertEqual(offsets(cues, .transition), [0, 10, 13])
        XCTAssertEqual(offsets(cues, .finish), [23])
    }

    func testEmptyWorkoutHasNoCues() {
        XCTAssertEqual(CuePlanner.cues(for: []), [])
    }

    func testCountdownAndSwitchToneLengths() {
        XCTAssertLessThan(CueKind.countdown.soundDuration, CueKind.transition.soundDuration)
        XCTAssertLessThan(CueKind.countdown.soundDuration, 1, "Beeps must not overlap the next second")
    }

    // MARK: Duck windows

    func testCountdownAndSwitchShareOneDuckWindow() {
        let cues = CuePlanner.cues(for: [Segment(.work, 60, round: 1), Segment(.rest, 60, round: 1)])
        let windows = CuePlanner.duckWindows(for: cues)
        // Start tone, the switch at 60 (with its countdown), and the finish at 120.
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[1].lowerBound, 55 - 0.35, accuracy: 1e-9)
        XCTAssertEqual(windows[1].upperBound, 60 + CueKind.transition.soundDuration + 0.4, accuracy: 1e-9)
    }

    func testMusicReturnsToNormalBetweenSwitches() {
        let cues = CuePlanner.cues(for: [Segment(.work, 60, round: 1), Segment(.rest, 60, round: 1)])
        let windows = CuePlanner.duckWindows(for: cues)
        let duckedTime = windows.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        XCTAssertLessThan(duckedTime, 25, "Music should be ducked only briefly around each switch")
        XCTAssertFalse(windows.contains { $0.contains(30) })
    }

    func testCloseSwitchesMergeIntoOneWindow() {
        let cues = CuePlanner.cues(for: [Segment(.work, 4, round: 1), Segment(.rest, 4, round: 1)])
        XCTAssertEqual(CuePlanner.duckWindows(for: cues).count, 1)
    }
}
