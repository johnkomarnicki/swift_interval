import CoreLocation
import Foundation
import SwiftData

/// A point on a route. Short JSON keys keep long routes small in Supabase.
struct RouteCoordinate: Codable, Hashable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(lat: coordinate.latitude, lon: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Great-circle distance in meters. Worked out directly rather than with
    /// `CLLocation`, which can differ by a few centimetres between identical
    /// calls; route lengths should come out the same every time.
    func distance(to other: RouteCoordinate) -> Double {
        let toRadians = Double.pi / 180
        let dLat = (other.lat - lat) * toRadians
        let dLon = (other.lon - lon) * toRadians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * toRadians) * cos(other.lat * toRadians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * Self.earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Mean Earth radius in meters.
    static let earthRadius = 6_371_000.0
}

/// A route as a plain value, handed to the player so it doesn't hold on to
/// the SwiftData model during a run.
struct RoutePath: Equatable {
    var name: String
    var coordinates: [RouteCoordinate]
    var meters: Double

    /// Length along the line through `coordinates`.
    static func length(of coordinates: [RouteCoordinate]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// The legs joined into one line, without repeating the point where one leg
    /// ends and the next begins.
    static func joined(_ legs: [[RouteCoordinate]]) -> [RouteCoordinate] {
        var path: [RouteCoordinate] = []
        for leg in legs {
            path += path.last == leg.first ? Array(leg.dropFirst()) : leg
        }
        return path
    }
}

/// A route drawn on the map, stored on the phone with SwiftData and synced to
/// Supabase. Plan sessions point at it by `syncID`.
@Model
final class RunRoute {
    var name: String = ""
    var createdAt: Date = Date.now
    /// Length of the whole route.
    var meters: Double = 0
    /// JSON-encoded `[RouteCoordinate]`: the points tapped on the map.
    var waypointsData: Data? = nil
    /// JSON-encoded `[[RouteCoordinate]]`: the path from each waypoint to the
    /// next, following roads and paths where it could.
    var legsData: Data? = nil
    var syncID: UUID? = nil
    var updatedAt: Date? = nil
    /// Changed on this phone and not uploaded yet.
    var needsUpload: Bool = true

    init(name: String, waypoints: [RouteCoordinate], legs: [[RouteCoordinate]], createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
        self.syncID = UUID()
        self.updatedAt = createdAt
        self.waypoints = waypoints
        self.legs = legs
    }

    var waypoints: [RouteCoordinate] {
        get { waypointsData.flatMap { try? JSONDecoder().decode([RouteCoordinate].self, from: $0) } ?? [] }
        set { waypointsData = try? JSONEncoder().encode(newValue) }
    }

    /// Setting the legs also updates `meters`.
    var legs: [[RouteCoordinate]] {
        get { legsData.flatMap { try? JSONDecoder().decode([[RouteCoordinate]].self, from: $0) } ?? [] }
        set {
            legsData = try? JSONEncoder().encode(newValue)
            meters = RoutePath.length(of: RoutePath.joined(newValue))
        }
    }

    /// The whole line to draw.
    var path: [RouteCoordinate] {
        let legs = legs
        return legs.isEmpty ? waypoints : RoutePath.joined(legs)
    }

    var displayName: String {
        name.isEmpty ? "Untitled route" : name
    }

    var snapshot: RoutePath {
        RoutePath(name: displayName, coordinates: path, meters: meters)
    }

    /// Call after editing, so the change is uploaded.
    func markChanged() {
        updatedAt = .now
        needsUpload = true
    }
}
