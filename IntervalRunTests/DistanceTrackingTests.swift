import CoreLocation
import XCTest
@testable import IntervalRun

final class RunTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testStraightRunMapsWorkoutTimeToClock() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        timeline.end(at: at(100))
        XCTAssertEqual(timeline.dateRanges(for: 30..<60, now: at(200)), [DateInterval(start: at(30), end: at(60))])
        XCTAssertEqual(timeline.activeDuration(for: 30..<60, now: at(200)), 30)
    }

    func testPauseSplitsAnIntervalIntoTwoRanges() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        timeline.end(at: at(40))             // pause at workout time 40
        timeline.begin(at: at(100), elapsed: 40) // resume a minute later
        timeline.end(at: at(150))
        XCTAssertEqual(timeline.dateRanges(for: 30..<60, now: at(200)), [
            DateInterval(start: at(30), end: at(40)),
            DateInterval(start: at(100), end: at(120)),
        ])
        XCTAssertEqual(timeline.activeDuration(for: 30..<60, now: at(200)), 30, accuracy: 1e-9)
    }

    func testSkipShortensTheSkippedInterval() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        timeline.begin(at: at(20), elapsed: 60) // skip at 20 s to the interval starting at 60
        timeline.end(at: at(50))
        XCTAssertEqual(timeline.activeDuration(for: 0..<60, now: at(100)), 20, accuracy: 1e-9)
        XCTAssertEqual(timeline.dateRanges(for: 60..<90, now: at(100)), [DateInterval(start: at(20), end: at(50))])
    }

    func testRunningStretchEndsAtNow() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        XCTAssertTrue(timeline.isRunning)
        XCTAssertEqual(timeline.activeDuration(for: 0..<60, now: at(25)), 25, accuracy: 1e-9)
        timeline.end(at: at(30))
        XCTAssertFalse(timeline.isRunning)
        timeline.end(at: at(40)) // already ended; ignored
        XCTAssertEqual(timeline.activeDuration(for: 0..<60, now: at(100)), 30, accuracy: 1e-9)
    }
}

final class DistanceAccumulatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A fix `north` meters north (and `east` meters east) of a fixed start point.
    private func fix(north: Double, east: Double = 0, accuracy: Double = 5, at seconds: TimeInterval = 0) -> CLLocation {
        let latitude = 40.0 + north / 111_034
        let longitude = -74.0 + east / 85_390
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
            timestamp: t0.addingTimeInterval(seconds)
        )
    }

    private func accumulator(_ seconds: [Int]) -> DistanceAccumulator {
        DistanceAccumulator(segments: seconds.enumerated().map { Segment($0.offset.isMultiple(of: 2) ? .work : .rest, $0.element, round: 1) })
    }

    func testSteadyRunIsSplitByInterval() {
        var acc = accumulator([60, 60])
        for second in 0...120 {
            acc.add(fix(north: Double(second) * 3), elapsed: TimeInterval(second))
        }
        acc.flush()
        XCTAssertEqual(acc.meters[0], 180, accuracy: 180 * 0.01)
        XCTAssertEqual(acc.meters[1], 180, accuracy: 180 * 0.01)
        XCTAssertTrue(acc.hasGoodCoverage(segment: 0, activeSeconds: 60))
    }

    func testFlushKeepsAShortFinalStretchWhileMoving() {
        var acc = accumulator([60])
        acc.add(fix(north: 0), elapsed: 0)
        acc.add(fix(north: 12), elapsed: 4)  // one full step
        acc.add(fix(north: 15), elapsed: 5)  // 3 m more, under a step
        acc.flush()
        XCTAssertEqual(acc.meters[0], 15, accuracy: 0.3)
    }

    func testFlushIgnoresDriftAfterStandingStill() {
        var acc = accumulator([120])
        acc.add(fix(north: 0), elapsed: 0)
        acc.add(fix(north: 6), elapsed: 60) // 6 m of drift over a minute standing
        acc.flush()
        XCTAssertEqual(acc.meters[0], 0)
    }

    func testInaccurateFixesAreIgnored() {
        var acc = accumulator([60])
        for second in 0...60 {
            acc.add(fix(north: Double(second) * 3, accuracy: 50), elapsed: TimeInterval(second))
        }
        XCTAssertEqual(acc.meters[0], 0)
        XCTAssertEqual(acc.fixes[0], 0)
        XCTAssertFalse(acc.hasGoodCoverage(segment: 0, activeSeconds: 60))
    }

    func testJitterWhileStandingStillAddsNothing() {
        var acc = accumulator([60])
        for second in 0...60 {
            // Scattered about 4 m either side of where you stand: within the 5 m accuracy.
            let wobble = second.isMultiple(of: 2) ? 3.0 : -3.0
            acc.add(fix(north: wobble, east: -wobble), elapsed: TimeInterval(second))
        }
        acc.flush()
        XCTAssertLessThan(acc.meters[0], 10)
    }

    func testHeldBackDistanceIsAddedAtTheEnd() {
        var acc = accumulator([60])
        for second in 0...10 {
            acc.add(fix(north: Double(second) * 3), elapsed: TimeInterval(second))
        }
        // 30 m run, but the last stretch is shorter than one step until flushed.
        XCTAssertLessThan(acc.meters[0], 30)
        // The live figure already includes it.
        XCTAssertEqual(acc.liveMeters(segment: 0), 30, accuracy: 0.5)
        acc.flush()
        XCTAssertEqual(acc.meters[0], 30, accuracy: 0.5)
    }

    func testSingleGPSJumpIsIgnored() {
        var acc = accumulator([60])
        for second in 0...60 {
            let north = second == 30 ? 500 : Double(second) * 3
            acc.add(fix(north: north), elapsed: TimeInterval(second))
        }
        acc.flush()
        XCTAssertEqual(acc.meters[0], 180, accuracy: 180 * 0.01)
    }

    func testPersistentJumpIsAcceptedWithoutAddingTheJump() {
        var acc = accumulator([60])
        // Run 30 m, then GPS settles 1 km away and stays there while you keep running.
        for second in 0...10 {
            acc.add(fix(north: Double(second) * 3), elapsed: TimeInterval(second))
        }
        for second in 11...30 {
            acc.add(fix(north: 1000 + Double(second) * 3), elapsed: TimeInterval(second))
        }
        acc.flush()
        // About 30 m before and 50 m after re-anchoring; never the 1 km jump.
        XCTAssertEqual(acc.meters[0], 80, accuracy: 15)
    }

    func testDistanceAcrossABoundaryIsSplitByTime() {
        var acc = accumulator([60, 60])
        acc.add(fix(north: 0), elapsed: 58)
        acc.add(fix(north: 20), elapsed: 62)
        XCTAssertEqual(acc.meters[0], 10, accuracy: 0.2)
        XCTAssertEqual(acc.meters[1], 10, accuracy: 0.2)
    }

    func testBreakPathDropsTheGap() {
        var acc = accumulator([120])
        acc.add(fix(north: 0), elapsed: 10)
        acc.breakPath() // paused, then walked 100 m before resuming
        acc.add(fix(north: 100), elapsed: 40)
        acc.add(fix(north: 112), elapsed: 44)
        XCTAssertEqual(acc.meters[0], 12, accuracy: 0.2)
    }

    func testCoverageNeedsAFixEveryTwoSeconds() {
        var acc = accumulator([60])
        for second in stride(from: 0, through: 60, by: 3) {
            acc.add(fix(north: Double(second) * 3), elapsed: TimeInterval(second))
        }
        XCTAssertFalse(acc.hasGoodCoverage(segment: 0, activeSeconds: 60)) // 21 fixes < 30
        XCTAssertTrue(acc.hasGoodCoverage(segment: 0, activeSeconds: 40))
    }

    func testSplitShares() {
        let shares = DistanceAccumulator.split(30, from: 50, to: 80, starts: [0, 60, 70], total: 100)
        XCTAssertEqual(shares.map(\.index), [0, 1, 2])
        XCTAssertEqual(shares[0].meters, 10, accuracy: 1e-9)
        XCTAssertEqual(shares[1].meters, 10, accuracy: 1e-9)
        XCTAssertEqual(shares[2].meters, 10, accuracy: 1e-9)
    }
}

final class WorkoutResultsTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private let segments = [Segment(.work, 90, round: 1), Segment(.rest, 60, round: 1), Segment(.work, 90, round: 2)]

    func testIntervalsGetTimeFromTimeline() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        timeline.begin(at: at(100), elapsed: 150) // skipped the rest 10 s in
        timeline.end(at: at(190))
        let intervals = WorkoutResults.intervals(for: segments, timeline: timeline, now: at(190))
        XCTAssertEqual(intervals.map(\.title), ["Work 1", "Rest 1", "Work 2"])
        XCTAssertEqual(intervals.map(\.activeSeconds), [90, 10, 90])
        XCTAssertTrue(intervals.allSatisfy { $0.meters == nil && $0.source == .none })
    }

    func testTotalsAndSkippedIntervals() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        timeline.begin(at: at(90), elapsed: 150) // skipped the whole rest
        timeline.end(at: at(180))
        var intervals = WorkoutResults.intervals(for: segments, timeline: timeline, now: at(180))
        XCTAssertTrue(intervals[1].wasSkipped)
        let untracked = WorkoutResults(name: "x", date: t0, completed: true, totalTime: 180, intervals: intervals)
        XCTAssertNil(untracked.totalMeters)
        XCTAssertEqual(untracked.activeTime, 180, accuracy: 1e-9)

        intervals[0].meters = 400
        intervals[1].meters = 0
        intervals[2].meters = 380
        let tracked = WorkoutResults(name: "x", date: t0, completed: true, totalTime: 180, intervals: intervals)
        XCTAssertEqual(tracked.totalMeters, 780)
    }

    func testRecordStoresResults() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        timeline.end(at: at(240))
        var intervals = WorkoutResults.intervals(for: segments, timeline: timeline, now: at(240))
        intervals[0].meters = 402
        intervals[0].source = .gps
        intervals[1].meters = 150
        intervals[1].source = .steps
        intervals[2].meters = 390
        intervals[2].source = .gps
        let results = WorkoutResults(name: "Jog/walk", date: t0, completed: false, totalTime: 250, intervals: intervals)

        let record = WorkoutRecord(results: results)
        XCTAssertEqual(record.name, "Jog/walk")
        XCTAssertEqual(record.date, t0)
        XCTAssertFalse(record.completed)
        XCTAssertEqual(record.totalTime, 250)
        XCTAssertEqual(record.activeTime, 240, accuracy: 1e-9)
        XCTAssertEqual(record.totalMeters, 942)
        XCTAssertEqual(record.intervals, intervals)
    }
}

final class DistanceFormatTests: XCTestCase {
    func testShortDistance() {
        XCTAssertEqual(DistanceFormat.short(0), "0.00 mi")
        XCTAssertEqual(DistanceFormat.short(1609.344), "1.00 mi")
        XCTAssertEqual(DistanceFormat.short(338), "0.21 mi")
    }

    func testPace() {
        XCTAssertEqual(DistanceFormat.pace(seconds: 480, meters: 1609.344), "8:00 /mi")
        XCTAssertEqual(DistanceFormat.pace(seconds: 90, meters: 1609.344 * 0.2), "7:30 /mi")
        XCTAssertEqual(DistanceFormat.pace(seconds: 90, meters: 5), "–:–– /mi")
        XCTAssertEqual(DistanceFormat.pace(seconds: 0, meters: 400), "–:–– /mi")
    }

    func testSpokenDistance() {
        XCTAssertEqual(DistanceFormat.hundredthsOfMile(338), 21)
        XCTAssertEqual(DistanceFormat.spoken(hundredths: 21), "0.21 miles")
        XCTAssertEqual(DistanceFormat.spoken(hundredths: 20), "0.2 miles")
        XCTAssertEqual(DistanceFormat.spoken(hundredths: 100), "1 mile")
        XCTAssertEqual(DistanceFormat.spoken(hundredths: 150), "1.5 miles")
        XCTAssertEqual(DistanceFormat.spoken(hundredths: 0), "0 miles")
    }

    func testSecondsPerMile() {
        XCTAssertEqual(DistanceFormat.secondsPerMile(seconds: 90, meters: 1609.344 * 0.2), 450)
        XCTAssertEqual(DistanceFormat.secondsPerMile(seconds: 180, meters: 1609.344 * 0.35), 514)
        XCTAssertNil(DistanceFormat.secondsPerMile(seconds: 90, meters: 5))
        XCTAssertNil(DistanceFormat.secondsPerMile(seconds: 0, meters: 400))
    }

    func testSpokenPace() {
        XCTAssertEqual(DistanceFormat.spokenPace(secondsPerMile: 495), "8 minutes 15 per mile")
        XCTAssertEqual(DistanceFormat.spokenPace(secondsPerMile: 480), "8 minutes per mile")
        XCTAssertEqual(DistanceFormat.spokenPace(secondsPerMile: 605), "10 minutes 5 per mile")
    }

    func testWorkSummaryPrompt() {
        XCTAssertEqual(
            Announcement.workSummary(hundredthsOfMile: 21, paceSecondsPerMile: 495).text,
            "That was 0.21 miles. 8 minutes 15 per mile."
        )
        XCTAssertEqual(Announcement.workSummary(hundredthsOfMile: 21, paceSecondsPerMile: nil).text, "That was 0.21 miles")
        XCTAssertEqual(Announcement.workSummary(hundredthsOfMile: nil, paceSecondsPerMile: 480).text, "Pace, 8 minutes per mile.")
        XCTAssertEqual(
            Announcement.workSummary(hundredthsOfMile: 21, paceSecondsPerMile: 495).priority,
            Announcement.halfway.priority
        )
    }
}
