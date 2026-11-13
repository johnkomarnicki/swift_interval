import CoreLocation
import XCTest
@testable import IntervalRun

@MainActor
final class RouteTests: XCTestCase {
    /// Points along a line of latitude, about 111 m apart.
    private func point(_ step: Double) -> RouteCoordinate {
        RouteCoordinate(lat: 40 + step * 0.001, lon: -74)
    }

    // MARK: RoutePath

    func testDistanceMatchesCoreLocationClosely() {
        let a = RouteCoordinate(lat: 40.7, lon: -74.0)
        let b = RouteCoordinate(lat: 40.71, lon: -73.99)
        let reference = CLLocation(latitude: a.lat, longitude: a.lon).distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
        XCTAssertEqual(a.distance(to: b), reference, accuracy: reference * 0.005)
        XCTAssertEqual(a.distance(to: b), a.distance(to: b))
        XCTAssertEqual(a.distance(to: a), 0)
    }

    func testLengthAddsUpEachStretch() {
        let line = [point(0), point(1), point(2)]
        XCTAssertEqual(RoutePath.length(of: line), point(0).distance(to: point(2)), accuracy: 0.5)
        XCTAssertEqual(RoutePath.length(of: [point(0)]), 0)
        XCTAssertEqual(RoutePath.length(of: []), 0)
    }

    func testJoinedLegsDoNotRepeatTheJoints() {
        let joined = RoutePath.joined([[point(0), point(1)], [point(1), point(2)]])
        XCTAssertEqual(joined, [point(0), point(1), point(2)])
    }

    func testRouteModelKeepsLegsAndLength() {
        let route = RunRoute(name: "Loop", waypoints: [point(0), point(2)], legs: [[point(0), point(1), point(2)]])
        XCTAssertEqual(route.path.count, 3)
        XCTAssertEqual(route.meters, RoutePath.length(of: route.path), accuracy: 1e-9)
        XCTAssertEqual(route.snapshot.name, "Loop")
        XCTAssertEqual(RunRoute(name: "", waypoints: [], legs: []).displayName, "Untitled route")
    }

    // MARK: RouteBuilder

    func testStraightLegsWhenNotFollowingRoads() async {
        let builder = RouteBuilder { _, _ in XCTFail("shouldn't look up paths"); return nil }
        builder.followsRoads = false
        await builder.add(point(0))
        await builder.add(point(1))
        await builder.add(point(2))
        XCTAssertEqual(builder.waypoints.count, 3)
        XCTAssertEqual(builder.legs, [[point(0), point(1)], [point(1), point(2)]])
        XCTAssertTrue(builder.canSave)
    }

    func testFollowingRoadsUsesTheWalkingPath() async {
        let detour = point(0.5)
        let builder = RouteBuilder { start, end in [start, detour, end] }
        await builder.add(point(0))
        await builder.add(point(1))
        XCTAssertEqual(builder.legs, [[point(0), detour, point(1)]])
        XCTAssertEqual(builder.pendingLegs, 0)
    }

    func testNoWalkingPathKeepsTheStraightLine() async {
        let builder = RouteBuilder { _, _ in nil }
        await builder.add(point(0))
        await builder.add(point(1))
        XCTAssertEqual(builder.legs, [[point(0), point(1)]])
    }

    func testUndoAndClear() async {
        let builder = RouteBuilder { _, _ in nil }
        await builder.add(point(0))
        await builder.add(point(1))
        builder.undo()
        XCTAssertEqual(builder.waypoints, [point(0)])
        XCTAssertTrue(builder.legs.isEmpty)
        XCTAssertFalse(builder.canSave)
        builder.clear()
        XCTAssertTrue(builder.waypoints.isEmpty)
    }

    func testOutAndBackRetracesTheRoute() async {
        let builder = RouteBuilder { _, _ in nil }
        await builder.add(point(0))
        await builder.add(point(1))
        await builder.add(point(2))
        let oneWay = builder.meters
        builder.outAndBack()
        XCTAssertEqual(builder.waypoints, [point(0), point(1), point(2), point(1), point(0)])
        XCTAssertEqual(builder.meters, oneWay * 2, accuracy: 0.01)
        XCTAssertTrue(builder.isLoop)
        builder.outAndBack() // already back at the start
        XCTAssertEqual(builder.waypoints.count, 5)
    }

    func testBackToStartClosesTheLoop() async {
        let builder = RouteBuilder { _, _ in nil }
        await builder.add(point(0))
        await builder.add(point(1))
        await builder.add(RouteCoordinate(lat: 40.001, lon: -73.999))
        await builder.backToStart()
        XCTAssertEqual(builder.waypoints.last, point(0))
        XCTAssertTrue(builder.isLoop)
    }

    // MARK: RouteFit

    func testUsualPaceAveragesRecentRealRuns() {
        let pace = RouteFit.usualPace([
            (meters: 3000, seconds: 1200),
            (meters: 100, seconds: 600),   // too short to count
            (meters: 2000, seconds: 800),
        ])
        XCTAssertTrue(pace.fromHistory)
        XCTAssertEqual(pace.metersPerSecond, 2.5, accuracy: 1e-9)
    }

    func testUsualPaceFallsBackWithoutHistory() {
        let pace = RouteFit.usualPace([])
        XCTAssertFalse(pace.fromHistory)
        XCTAssertEqual(pace.secondsPerMile, 720)
    }

    func testUsualPaceOnlyUsesTheMostRecentRuns() {
        let recent = Array(repeating: (meters: 1000.0, seconds: 400.0), count: RouteFit.recentRuns)
        let old = [(meters: 1000.0, seconds: 2000.0)]
        XCTAssertEqual(RouteFit.usualPace(recent + old).metersPerSecond, 2.5, accuracy: 1e-9)
    }

    func testTargetAndMatch() {
        let pace = RouteFit.Pace(metersPerSecond: 2.5, fromHistory: true)
        let target = RouteFit.targetMeters(seconds: 1800, pace: pace)
        XCTAssertEqual(target, 4500)
        XCTAssertEqual(RouteFit.match(routeMeters: 4500, targetMeters: target), .fits)
        XCTAssertEqual(RouteFit.match(routeMeters: 4000, targetMeters: target), .fits)
        XCTAssertEqual(RouteFit.match(routeMeters: 3000, targetMeters: target), .short)
        XCTAssertEqual(RouteFit.match(routeMeters: 6000, targetMeters: target), .long)
    }

    // MARK: Sync

    func testRemoteRouteRoundTrip() throws {
        let route = RunRoute(name: "River", waypoints: [point(0), point(1)], legs: [[point(0), point(1)]])
        let data = try JSONEncoder().encode(RemoteRoute(route))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["legs"])
        XCTAssertNotNil(json?["updated_at"])
        let decoded = try JSONDecoder().decode(RemoteRoute.self, from: data)
        XCTAssertEqual(decoded.id, route.syncID)
        XCTAssertEqual(decoded.legs, route.legs)
    }

    func testProgramDecodesSessionRoutesWhenPresent() throws {
        let routeID = UUID()
        let base = #"{"id":"\#(UUID().uuidString)","status":"active","created_at":0"#
        let withRoutes = try JSONDecoder().decode(
            TrainingProgram.self,
            from: Data((base + #","session_routes":{"w1-s1":"\#(routeID.uuidString)"}}"#).utf8)
        )
        XCTAssertEqual(withRoutes.sessionRoutes?["w1-s1"], routeID)
        let without = try JSONDecoder().decode(TrainingProgram.self, from: Data((base + "}").utf8))
        XCTAssertNil(without.sessionRoutes)
    }
}
