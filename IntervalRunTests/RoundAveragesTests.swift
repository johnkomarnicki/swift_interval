import XCTest
@testable import IntervalRun

final class RoundAveragesTests: XCTestCase {
    private func result(
        _ index: Int, _ phase: Phase, round: Int?, seconds: TimeInterval,
        meters: Double? = nil, heartRate: HeartRateStats? = nil
    ) -> IntervalResult {
        var result = IntervalResult(
            index: index, phase: phase, round: round, plannedSeconds: 60,
            activeSeconds: seconds, meters: meters, source: meters == nil ? .none : .gps
        )
        result.heartRate = heartRate
        return result
    }

    func testNilForASingleRound() {
        let intervals = [
            result(0, .warmUp, round: nil, seconds: 300),
            result(1, .work, round: 1, seconds: 60),
            result(2, .rest, round: 1, seconds: 60),
        ]
        XCTAssertNil(intervals.roundAverages)
    }

    func testAveragesEachStepAcrossRounds() throws {
        let intervals = [
            result(0, .warmUp, round: nil, seconds: 300, meters: 500),
            result(1, .work, round: 1, seconds: 60, meters: 200, heartRate: HeartRateStats(average: 150, max: 160, end: 158)),
            result(2, .rest, round: 1, seconds: 60, meters: 100),
            result(3, .work, round: 2, seconds: 60, meters: 240, heartRate: HeartRateStats(average: 160, max: 170, end: 166)),
            result(4, .coolDown, round: nil, seconds: 300, meters: 500),
        ]
        let averages = try XCTUnwrap(intervals.roundAverages)
        XCTAssertEqual(averages.map(\.phase), [.work, .rest])
        XCTAssertEqual(averages[0].meters, 220)
        XCTAssertEqual(averages[0].heartRate, HeartRateStats(average: 155, max: 170, end: 162))
        // The last round's rest was left out, so only round 1 counts.
        XCTAssertEqual(averages[1].meters, 100)
    }

    func testSkippedIntervalsAreLeftOutOfTheAverage() throws {
        let intervals = [
            result(0, .work, round: 1, seconds: 60, meters: 200),
            result(1, .work, round: 2, seconds: 30, meters: 100),
            result(2, .work, round: 3, seconds: 0),
        ]
        let averages = try XCTUnwrap(intervals.roundAverages)
        XCTAssertEqual(averages[0].activeSeconds, 45)
        XCTAssertEqual(averages[0].meters, 150)
        XCTAssertEqual(intervals.roundsRun, 2)
        XCTAssertEqual(intervals.roundCount, 3)
    }
}
