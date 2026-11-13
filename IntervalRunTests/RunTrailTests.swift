import CoreLocation
import XCTest
@testable import IntervalRun

final class RunTrailTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let metersPerDegree = RouteCoordinate.earthRadius * .pi / 180

    /// A fix `north` meters north of a fixed point, `seconds` into the run.
    private func fix(north: Double, at seconds: TimeInterval, accuracy: CLLocationAccuracy = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40 + north / metersPerDegree, longitude: -74),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: t0.addingTimeInterval(seconds)
        )
    }

    func testRunningBuildsOneLine() {
        var trail = RunTrail()
        for second in 0...10 {
            trail.add(fix(north: Double(second) * 3, at: TimeInterval(second)))
        }
        XCTAssertEqual(trail.lines.count, 1)
        // 3 m a second with 5 m spacing keeps every other fix.
        XCTAssertEqual(trail.lines[0].count, 6)
    }

    func testStandingStillAddsNoPoints() {
        var trail = RunTrail()
        for second in 0...30 {
            trail.add(fix(north: Double(second % 3), at: TimeInterval(second)))
        }
        XCTAssertEqual(trail.lines.map(\.count), [1])
    }

    func testInaccurateFixesAreIgnored() {
        var trail = RunTrail()
        trail.add(fix(north: 0, at: 0))
        trail.add(fix(north: 10, at: 3, accuracy: 60))
        trail.add(fix(north: 10, at: 4, accuracy: -1))
        XCTAssertEqual(trail.lines.map(\.count), [1])
    }

    func testPauseStartsANewLine() {
        var trail = RunTrail()
        trail.add(fix(north: 0, at: 0))
        trail.add(fix(north: 10, at: 3))
        trail.breakLine()
        trail.add(fix(north: 200, at: 120))
        trail.add(fix(north: 210, at: 123))
        XCTAssertEqual(trail.lines.map(\.count), [2, 2])
    }

    func testOneGPSJumpIsIgnored() {
        var trail = RunTrail()
        trail.add(fix(north: 0, at: 0))
        trail.add(fix(north: 500, at: 1))
        trail.add(fix(north: 6, at: 2))
        XCTAssertEqual(trail.lines.map(\.count), [2])
    }

    func testRepeatedJumpsStartANewLineThere() {
        var trail = RunTrail()
        trail.add(fix(north: 0, at: 0))
        trail.add(fix(north: 10, at: 3))
        for second in 4...6 {
            trail.add(fix(north: 1000 + Double(second), at: TimeInterval(second)))
        }
        XCTAssertEqual(trail.lines.count, 2)
        XCTAssertEqual(trail.lines[0].count, 2)
        XCTAssertEqual(trail.lines[1].count, 1)
    }

    func testBreakBeforeASecondPointReusesTheLine() {
        var trail = RunTrail()
        trail.add(fix(north: 0, at: 0))
        trail.breakLine()
        trail.add(fix(north: 50, at: 60))
        XCTAssertEqual(trail.lines.map(\.count), [1])
    }
}
