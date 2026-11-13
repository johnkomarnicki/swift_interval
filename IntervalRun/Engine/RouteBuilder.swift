import MapKit
import Observation

/// The route being drawn in the editor: tapped waypoints and the path between
/// each pair.
///
/// A new leg appears as a straight line straight away, then is replaced by the
/// walking path from Apple Maps once that arrives (when following roads). If
/// there's no walking path, or no connection, the straight line stays.
@MainActor
@Observable
final class RouteBuilder {
    private(set) var waypoints: [RouteCoordinate]
    private(set) var legs: [[RouteCoordinate]]
    /// Snap new legs to roads and paths. Legs already drawn keep their shape.
    var followsRoads = true
    /// Walking directions still being fetched.
    private(set) var pendingLegs = 0

    /// Looks up the walking path between two points; nil when there isn't one.
    @ObservationIgnored private let findPath: (RouteCoordinate, RouteCoordinate) async -> [RouteCoordinate]?

    init(
        waypoints: [RouteCoordinate] = [],
        legs: [[RouteCoordinate]] = [],
        findPath: @escaping (RouteCoordinate, RouteCoordinate) async -> [RouteCoordinate]? = RouteBuilder.walkingPath
    ) {
        self.waypoints = waypoints
        self.legs = legs
        self.findPath = findPath
    }

    var path: [RouteCoordinate] {
        legs.isEmpty ? waypoints : RoutePath.joined(legs)
    }

    var meters: Double { RoutePath.length(of: path) }

    var canSave: Bool { waypoints.count >= 2 }

    /// Whether the route ends where it started.
    var isLoop: Bool {
        guard waypoints.count > 2, let first = waypoints.first, let last = waypoints.last else { return false }
        return first.distance(to: last) < 30
    }

    func add(_ point: RouteCoordinate) async {
        guard let previous = waypoints.last else {
            waypoints = [point]
            return
        }
        let straight = [previous, point]
        waypoints.append(point)
        legs.append(straight)
        guard followsRoads else { return }

        let index = legs.count - 1
        pendingLegs += 1
        defer { pendingLegs -= 1 }
        guard let walked = await findPath(previous, point) else { return }
        // Undo or Clear may have removed this leg while waiting.
        guard legs.indices.contains(index), legs[index] == straight else { return }
        legs[index] = walked
    }

    /// Adds a last leg back to the first point.
    func backToStart() async {
        guard waypoints.count >= 2, let first = waypoints.first, !isLoop else { return }
        await add(first)
    }

    /// Retraces the whole route back to the start, doubling it.
    func outAndBack() {
        guard waypoints.count >= 2, !isLoop else { return }
        waypoints += waypoints.dropLast().reversed()
        legs += legs.reversed().map { $0.reversed() }
    }

    /// Replaces the whole route, e.g. with one made by `RouteGenerator`.
    func replace(waypoints: [RouteCoordinate], legs: [[RouteCoordinate]]) {
        self.waypoints = waypoints
        self.legs = legs
    }

    func undo() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        if !legs.isEmpty { legs.removeLast() }
    }

    func clear() {
        waypoints = []
        legs = []
    }

    /// The Apple Maps walking path between two points, with the tapped points at
    /// each end so the line joins up even when they're off the road.
    static func walkingPath(from start: RouteCoordinate, to end: RouteCoordinate) async -> [RouteCoordinate]? {
        guard var path = await snappedWalkingPath(from: start, to: end) else { return nil }
        if let first = path.first, first.distance(to: start) > 1 { path.insert(start, at: 0) }
        if let last = path.last, last.distance(to: end) > 1 { path.append(end) }
        return path
    }

    /// The Apple Maps walking path between two points, starting and ending on
    /// the nearest road or path rather than exactly at the points.
    static func snappedWalkingPath(from start: RouteCoordinate, to end: RouteCoordinate) async -> [RouteCoordinate]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = .walking
        guard let polyline = try? await MKDirections(request: request).calculate().routes.first?.polyline,
              polyline.pointCount > 1 else { return nil }
        var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        return points.map(RouteCoordinate.init)
    }
}
