import XCTest
@testable import IntervalRun

@MainActor
final class FreeRunTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: RunTimeline.elapsed(at:)

    func testElapsedFollowsTheClockWhileRunning() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        XCTAssertEqual(timeline.elapsed(at: at(42)), 42)
    }

    func testElapsedIsNilWhilePausedAndPicksUpAfterResume() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        timeline.end(at: at(30))                 // pause
        timeline.begin(at: at(90), elapsed: 30)  // resume a minute later
        XCTAssertEqual(timeline.elapsed(at: at(20)), 20)
        XCTAssertNil(timeline.elapsed(at: at(60)))
        XCTAssertEqual(timeline.elapsed(at: at(100)), 40)
    }

    func testElapsedIsNilBeforeTheStartAndAfterTheEnd() {
        var timeline = RunTimeline()
        timeline.begin(at: t0, elapsed: 0)
        timeline.end(at: at(50))
        XCTAssertNil(timeline.elapsed(at: at(-1)))
        XCTAssertEqual(timeline.elapsed(at: at(50)), 50)
        XCTAssertNil(timeline.elapsed(at: at(51)))
    }

    // MARK: Chunks

    func testChunksFillAMinuteAtATime() {
        XCTAssertEqual(FreeRunSession.secondsPerChunk(activeTime: 0), [])
        XCTAssertEqual(FreeRunSession.secondsPerChunk(activeTime: 25), [25])
        XCTAssertEqual(FreeRunSession.secondsPerChunk(activeTime: 60), [60])
        XCTAssertEqual(FreeRunSession.secondsPerChunk(activeTime: 150), [60, 60, 30])
    }

    func testCombinedAddsUpChunksAndPicksTheMainSource() {
        func chunk(_ index: Int, _ seconds: TimeInterval, _ meters: Double, _ source: DistanceSource) -> IntervalResult {
            IntervalResult(index: index, phase: .work, round: nil, plannedSeconds: 60, activeSeconds: seconds, meters: meters, source: source)
        }
        let result = FreeRunSession.combined([
            chunk(0, 60, 200, .gps),
            chunk(1, 60, 180, .steps), // GPS dropped out for a minute
            chunk(2, 30, 100, .gps),
        ], activeTime: 150)
        XCTAssertEqual(result.meters ?? 0, 480, accuracy: 1e-9)
        XCTAssertEqual(result.source, .gps)
        XCTAssertEqual(result.activeSeconds, 150)
        XCTAssertEqual(result.plannedSeconds, 150)

        let empty = FreeRunSession.combined([], activeTime: 0)
        XCTAssertEqual(empty.meters, 0)
        XCTAssertEqual(empty.source, .none)
    }

    // MARK: History and sync

    func testFreeRunRecordKeepsItsActivityThroughSync() throws {
        let interval = IntervalResult(index: 0, phase: .work, round: nil, plannedSeconds: 1500, activeSeconds: 1500, meters: 4000, source: .gps)
        let results = WorkoutResults(name: "Walk", date: t0, completed: true, totalTime: 1600, intervals: [interval], activity: .walk)
        let record = WorkoutRecord(results: results)
        XCTAssertEqual(record.freeActivity, .walk)
        XCTAssertEqual(record.displayTime, 1500)

        let row = RemoteWorkoutRecord(record)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any]
        XCTAssertEqual(json?["activity"] as? String, "walk")
        XCTAssertTrue(json?["program_id"] is NSNull, "nil columns are sent as null so batch rows match")

        let restored = row.makeRecord()
        XCTAssertEqual(restored.freeActivity, .walk)
        XCTAssertEqual(restored.totalMeters, 4000)
    }

    func testIntervalWorkoutRecordHasNoActivity() throws {
        let results = WorkoutResults(name: "Intervals", date: t0, completed: true, totalTime: 600, intervals: [])
        let record = WorkoutRecord(results: results)
        XCTAssertNil(record.freeActivity)
        XCTAssertEqual(record.displayTime, 600)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteWorkoutRecord(record))) as? [String: Any]
        XCTAssertTrue(json?["activity"] is NSNull)
    }
}
