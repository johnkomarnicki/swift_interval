import XCTest
@testable import IntervalRun

final class HeartRateTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func period(_ from: TimeInterval, _ to: TimeInterval) -> DateInterval {
        DateInterval(start: at(from), end: at(to))
    }

    /// One reading a second from `from` to `to`, at `bpm(second)`.
    private func readings(_ from: Int, _ to: Int, bpm: (Int) -> Int) -> [HeartRateSample] {
        (from..<to).map { HeartRateSample(date: at(TimeInterval($0)), bpm: bpm($0)) }
    }

    private func interval(_ index: Int, _ phase: Phase, _ periods: [DateInterval]) -> IntervalResult {
        IntervalResult(
            index: index, phase: phase, round: 1, plannedSeconds: 30,
            activeSeconds: periods.reduce(0) { $0 + $1.duration }, meters: nil, source: .none, periods: periods
        )
    }

    // MARK: Bluetooth measurement

    func testReadsEightBitValue() {
        XCTAssertEqual(HeartRateMonitor.bpm(fromMeasurement: Data([0x00, 142])), 142)
    }

    func testReadsSixteenBitValue() {
        XCTAssertEqual(HeartRateMonitor.bpm(fromMeasurement: Data([0x01, 0xA0, 0x00])), 160)
    }

    func testIgnoresReadingWithoutSkinContact() {
        // Contact supported (bit 2) but not detected (bit 1 clear).
        XCTAssertNil(HeartRateMonitor.bpm(fromMeasurement: Data([0b100, 70])))
        // Contact supported and detected.
        XCTAssertEqual(HeartRateMonitor.bpm(fromMeasurement: Data([0b110, 70])), 70)
    }

    /// A broadcasting watch can come back under a new identifier, so the name counts too.
    func testRemembersMonitorByIdentifierOrName() {
        let paired = UUID(), other = UUID()
        XCTAssertTrue(HeartRateMonitor.isSameMonitor(id: paired, name: nil, pairedID: paired, pairedName: "FR265"))
        XCTAssertTrue(HeartRateMonitor.isSameMonitor(id: other, name: "FR265", pairedID: paired, pairedName: "FR265"))
        XCTAssertFalse(HeartRateMonitor.isSameMonitor(id: other, name: "Polar H10", pairedID: paired, pairedName: "FR265"))
        XCTAssertFalse(HeartRateMonitor.isSameMonitor(id: other, name: nil, pairedID: paired, pairedName: "FR265"))
        // Nothing paired, or paired to a monitor that didn't say its name.
        XCTAssertFalse(HeartRateMonitor.isSameMonitor(id: other, name: "FR265", pairedID: nil, pairedName: "FR265"))
        XCTAssertFalse(HeartRateMonitor.isSameMonitor(id: other, name: "Heart rate monitor", pairedID: paired, pairedName: "Heart rate monitor"))
    }

    func testIgnoresShortOrUnbelievableValues() {
        XCTAssertNil(HeartRateMonitor.bpm(fromMeasurement: Data()))
        XCTAssertNil(HeartRateMonitor.bpm(fromMeasurement: Data([0x01, 0xA0])))
        XCTAssertNil(HeartRateMonitor.bpm(fromMeasurement: Data([0x00, 0])))
        XCTAssertNil(HeartRateMonitor.bpm(fromMeasurement: Data([0x01, 0x2C, 0x01]))) // 300
    }

    // MARK: Matching readings to intervals

    func testEachIntervalGetsItsOwnReadings() {
        let intervals = [interval(0, .work, [period(0, 30)]), interval(1, .rest, [period(30, 60)])]
        let samples = readings(0, 30) { 140 + $0 / 3 } + readings(30, 60) { 160 - ($0 - 30) }
        let filled = WorkoutResults.addingHeartRate(intervals, from: samples)

        XCTAssertEqual(filled[0].heartRate, HeartRateStats(average: 145, max: 149, end: 149))
        XCTAssertEqual(filled[1].heartRate?.max, 160)
        XCTAssertEqual(filled[1].heartRate?.end, 131)
        XCTAssertEqual(filled.averageRecovery, 149 - 131)
    }

    func testReadingsWhilePausedAreLeftOut() {
        // Work ran 0-20 s, was paused, then ran 50-60 s.
        let intervals = [interval(0, .work, [period(0, 20), period(50, 60)])]
        let samples = readings(0, 20) { _ in 150 } + readings(20, 50) { _ in 90 } + readings(50, 60) { _ in 150 }
        let filled = WorkoutResults.addingHeartRate(intervals, from: samples)
        XCTAssertEqual(filled[0].heartRate?.average, 150)
    }

    func testTooFewReadingsAreNotKept() {
        // An Apple Watch outside a workout: one reading every 5 minutes over 30 minutes.
        let intervals = [interval(0, .work, [period(0, 900)]), interval(1, .rest, [period(900, 1800)])]
        let sparse = stride(from: 0, to: 1800, by: 300).map { HeartRateSample(date: at(TimeInterval($0)), bpm: 120) }
        let filled = WorkoutResults.addingHeartRate(intervals, from: sparse)
        XCTAssertEqual(filled, intervals)
        XCTAssertNil(filled.averageHeartRate)
    }

    func testWatchWorkoutRateIsEnough() {
        // An Apple Watch during a workout reads about every 5 seconds.
        let samples = stride(from: 0, to: 600, by: 5).map { HeartRateSample(date: at(TimeInterval($0)), bpm: 130) }
        XCTAssertTrue(HeartRateSample.enough(samples, for: [period(0, 600)]))
    }

    func testIntervalWithoutReadingsStaysEmpty() {
        let intervals = [interval(0, .work, [period(0, 60)]), interval(1, .rest, [period(60, 63)])]
        let filled = WorkoutResults.addingHeartRate(intervals, from: readings(0, 60) { _ in 150 })
        XCTAssertNotNil(filled[0].heartRate)
        XCTAssertNil(filled[1].heartRate)
    }

    // MARK: Summaries

    func testAverageIsWeightedByTime() {
        var long = interval(0, .work, [period(0, 90)])
        long.heartRate = HeartRateStats(average: 160, max: 170, end: 165)
        var short = interval(1, .rest, [period(90, 120)])
        short.heartRate = HeartRateStats(average: 120, max: 165, end: 110)
        XCTAssertEqual([long, short].averageHeartRate, 150)
        XCTAssertEqual([long, short].maxHeartRate, 170)
        XCTAssertEqual([long, short].averageRecovery, 55)
    }

    // MARK: Saving

    func testIntervalsRecordTheirPeriods() {
        var timeline = RunTimeline()
        timeline.begin(at: at(0), elapsed: 0)
        timeline.end(at: at(10)) // paused for 5 s
        timeline.begin(at: at(15), elapsed: 10)
        timeline.end(at: at(50))
        let intervals = WorkoutResults.intervals(
            for: [Segment(.work, 30, round: 1), Segment(.rest, 15, round: 1)], timeline: timeline, now: at(50)
        )
        XCTAssertEqual(intervals[0].periods, [period(0, 10), period(15, 35)])
        XCTAssertEqual(intervals[0].activeSeconds, 30)
        XCTAssertEqual(intervals[1].periods, [period(35, 50)])
    }

    func testRunsSavedBeforeHeartRateStillLoad() throws {
        let old = #"[{"index":0,"phase":"work","round":1,"plannedSeconds":30,"activeSeconds":30,"meters":100,"source":"gps"}]"#
        let decoded = try JSONDecoder().decode([IntervalResult].self, from: Data(old.utf8))
        XCTAssertNil(decoded[0].heartRate)
        XCTAssertNil(decoded[0].periods)
        XCTAssertEqual(decoded[0].meters, 100)
    }

    func testHeartRateSurvivesSaving() throws {
        var result = interval(0, .work, [period(0, 30)])
        result.heartRate = HeartRateStats(average: 150, max: 162, end: 160)
        let data = try JSONEncoder().encode([result])
        XCTAssertEqual(try JSONDecoder().decode([IntervalResult].self, from: data), [result])
    }
}
