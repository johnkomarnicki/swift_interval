import XCTest
@testable import IntervalRun

@MainActor
final class RouteGeneratorTests: XCTestCase {
    private let start = RouteCoordinate(lat: 40.7, lon: -74.0)
    /// Stands in for Apple Maps: a straight line between the two points.
    private let straight = RouteGenerator { from, to in [from, to] }

    func testDestinationIsTheRightDistanceAndDirection() {
        let north = RouteGenerator.destination(from: start, bearing: 0, meters: 1000)
        XCTAssertEqual(start.distance(to: north), 1000, accuracy: 0.01)
        XCTAssertGreaterThan(north.lat, start.lat)
        XCTAssertEqual(north.lon, start.lon, accuracy: 1e-9)

        let east = RouteGenerator.destination(from: start, bearing: 90, meters: 1000)
        XCTAssertEqual(start.distance(to: east), 1000, accuracy: 0.01)
        XCTAssertGreaterThan(east.lon, start.lon)
    }

    func testLoopPointsSitOnACircleThroughTheStart() {
        let radius = 500.0
        let center = RouteGenerator.destination(from: start, bearing: 45, meters: radius)
        for point in RouteGenerator.loopPoints(from: start, radius: radius, bearing: 45) {
            XCTAssertEqual(point.distance(to: center), radius, accuracy: 0.01)
        }
    }

    func testLoopsComeOutCloseToTheDistanceAndReturnToStart() async {
        let target = 3 * DistanceFormat.metersPerMile
        let options = await straight.options(from: start, meters: target, shape: .loop)
        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(Set(options.map(\.bearing)).count, 3, "each option heads a different way")
        for option in options {
            XCTAssertEqual(option.meters, target, accuracy: target * RouteGenerator.closeEnough)
            XCTAssertEqual(option.waypoints.first, start)
            XCTAssertEqual(option.waypoints.last, start)
            XCTAssertEqual(option.legs.count, 4)
            XCTAssertEqual(option.meters, RoutePath.length(of: RoutePath.joined(option.legs)), accuracy: 1e-6)
        }
    }

    func testOutAndBackRetracesToTheStart() async {
        let target = 2 * DistanceFormat.metersPerMile
        let options = await straight.options(from: start, meters: target, shape: .outAndBack, count: 2)
        XCTAssertEqual(options.count, 2)
        for option in options {
            XCTAssertEqual(option.meters, target, accuracy: target * RouteGenerator.closeEnough)
            XCTAssertEqual(option.waypoints.count, 3)
            XCTAssertEqual(option.waypoints.last, start)
            XCTAssertEqual(option.legs[1], option.legs[0].reversed())
        }
    }

    func testOptionsAreSortedClosestFirst() async {
        // Paths get longer the further east they head, so options differ in length.
        let lopsided = RouteGenerator { from, to in
            let detour = max(0, to.lon - from.lon) * 50
            return [from, RouteCoordinate(lat: (from.lat + to.lat) / 2 + detour, lon: (from.lon + to.lon) / 2), to]
        }
        let target = 2 * DistanceFormat.metersPerMile
        let options = await lopsided.options(from: start, meters: target, shape: .loop)
        let errors = options.map { abs($0.meters - target) }
        XCTAssertEqual(errors, errors.sorted())
    }

    func testNoWalkingPathsMeansNoOptions() async {
        let nowhere = RouteGenerator { _, _ in nil }
        let loops = await nowhere.options(from: start, meters: 5000, shape: .loop)
        let outAndBacks = await nowhere.options(from: start, meters: 5000, shape: .outAndBack)
        XCTAssertTrue(loops.isEmpty)
        XCTAssertTrue(outAndBacks.isEmpty)
    }

    func testOneMissingLegDropsThatLoop() async {
        var calls = 0
        let flaky = RouteGenerator { from, to in
            calls += 1
            return calls == 2 ? nil : [from, to]
        }
        let options = await flaky.options(from: start, meters: 4000, shape: .loop, count: 1)
        // The first attempt is spoiled; the loop is only kept if the retry works.
        XCTAssertLessThanOrEqual(options.count, 1)
    }

    func testCompassNames() {
        XCTAssertEqual(RouteGenerator.compassName(0), "north")
        XCTAssertEqual(RouteGenerator.compassName(90), "east")
        XCTAssertEqual(RouteGenerator.compassName(225), "south-west")
        XCTAssertEqual(RouteGenerator.compassName(359), "north")
        XCTAssertEqual(RouteGenerator.compassName(-90), "west")
    }

    func testBuilderTakesAGeneratedRoute() async {
        let option = await straight.options(from: start, meters: 3000, shape: .loop, count: 1)[0]
        let builder = RouteBuilder { _, _ in nil }
        builder.replace(waypoints: option.waypoints, legs: option.legs)
        XCTAssertEqual(builder.meters, option.meters, accuracy: 1e-6)
        XCTAssertTrue(builder.isLoop)
        XCTAssertTrue(builder.canSave)
    }
}

@MainActor
final class RouteGeneratorPathsTests: XCTestCase {
    private let start = RouteCoordinate(lat: 40.7, lon: -74.0)
    private let target = 3 * DistanceFormat.metersPerMile

    private func generator(greens: [GreenSpace]) -> RouteGenerator {
        RouteGenerator(findPath: { from, to in [from, to] }, findGreenSpaces: { _, _ in greens })
    }

    /// A park `fraction` of the way out along a bearing, relative to the loop's reach.
    private func park(_ name: String, bearing: Double, fraction: Double, shape: RouteGenerator.Shape = .loop) -> GreenSpace {
        let meters = RouteGenerator.reach(for: target, shape: shape) * fraction
        return GreenSpace(name: name, coordinate: RouteGenerator.destination(from: start, bearing: bearing, meters: meters))
    }

    func testBearingAndAngleHelpers() {
        let east = RouteGenerator.destination(from: start, bearing: 90, meters: 1000)
        XCTAssertEqual(RouteGenerator.bearing(from: start, to: east), 90, accuracy: 0.1)
        XCTAssertEqual(RouteGenerator.angleBetween(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(RouteGenerator.angleBetween(90, 270), 180, accuracy: 1e-9)
    }

    func testOptionsHeadTowardsParks() {
        let reach = RouteGenerator.reach(for: target, shape: .loop)
        let greens = [park("East Park", bearing: 80, fraction: 0.7), park("Far Park", bearing: 200, fraction: 3)]
        let bearings = RouteGenerator.bearings(count: 3, offset: 0, toward: greens, from: start, reach: reach)
        XCTAssertEqual(bearings.count, 3)
        XCTAssertEqual(bearings[0], 80, accuracy: 0.5, "heads for the park in reach first")
        for (i, a) in bearings.enumerated() {
            for b in bearings[(i + 1)...] {
                XCTAssertGreaterThanOrEqual(RouteGenerator.angleBetween(a, b), RouteGenerator.minimumSpread)
            }
        }
    }

    func testWithoutParksBearingsAreEvenlySpread() {
        let bearings = RouteGenerator.bearings(count: 3, offset: 0, toward: [], from: start, reach: 1000)
        XCTAssertEqual(bearings, [0, 120, 240])
    }

    func testLoopGoesThroughANearbyPark() async {
        let options = await generator(greens: [park("Riverside Park", bearing: 45, fraction: 0.6)])
            .options(from: start, meters: target, shape: .loop, prefersPaths: true)
        let throughPark = options.filter { $0.via == ["Riverside Park"] }
        XCTAssertFalse(throughPark.isEmpty)
        XCTAssertEqual(options.first?.via, ["Riverside Park"], "a fitting route through a park comes first")
        for option in throughPark {
            XCTAssertTrue(option.waypoints.contains { $0.distance(to: park("Riverside Park", bearing: 45, fraction: 0.6).coordinate) < 1 })
        }
    }

    func testParksAreIgnoredUnlessPreferred() async {
        let options = await generator(greens: [park("Riverside Park", bearing: 45, fraction: 0.6)])
            .options(from: start, meters: target, shape: .loop, prefersPaths: false)
        XCTAssertTrue(options.allSatisfy(\.via.isEmpty))
    }

    func testOutAndBackPassesThroughAParkOnTheWay() async {
        let greenway = park("Greenway", bearing: 10, fraction: 0.4, shape: .outAndBack)
        let options = await generator(greens: [greenway])
            .options(from: start, meters: 2 * DistanceFormat.metersPerMile, shape: .outAndBack, prefersPaths: true)
        guard let option = options.first(where: { !$0.via.isEmpty }) else { return XCTFail("no option via the park") }
        XCTAssertEqual(option.via, ["Greenway"])
        XCTAssertEqual(option.waypoints.count, 5, "start, park, turnaround, park, start")
        XCTAssertEqual(option.waypoints.first, start)
        XCTAssertEqual(option.waypoints.last, start)
        XCTAssertEqual(option.legs.count, 4)
        XCTAssertEqual(option.legs[3], option.legs[0].reversed())
    }

    func testRankingPutsFittingParkRoutesFirst() {
        func option(_ id: Int, meters: Double, via: [String]) -> RouteGenerator.Option {
            RouteGenerator.Option(id: id, waypoints: [], legs: [], meters: meters, bearing: 0, via: via)
        }
        let ranked = RouteGenerator.ranked([
            option(0, meters: 1000, via: []),            // spot on, streets
            option(1, meters: 1080, via: ["Park"]),      // fits, through a park
            option(2, meters: 2000, via: ["A", "B"]),    // through parks but far too long
        ], target: 1000)
        XCTAssertEqual(ranked.map(\.id), [1, 0, 2])
    }

    func testDuplicateGreenSpacesAreMerged() {
        let a = GreenSpace(name: "Park", coordinate: start)
        let b = GreenSpace(name: "Park Trail", coordinate: RouteGenerator.destination(from: start, bearing: 0, meters: 50))
        let c = GreenSpace(name: "Other", coordinate: RouteGenerator.destination(from: start, bearing: 0, meters: 500))
        XCTAssertEqual(GreenSpaceFinder.deduplicated([a, b, c]).map(\.name), ["Park", "Other"])
    }
}
