import MapKit

/// A park or trail near the start, for routes to head through.
struct GreenSpace: Equatable {
    var name: String
    var coordinate: RouteCoordinate
}

/// Finds parks and trails with Apple Maps. Walking directions to them tend to
/// follow their paths, which is how made routes come to use walking paths.
@MainActor
enum GreenSpaceFinder {
    /// Places closer together than this are treated as the same place.
    static let duplicateDistance: Double = 150

    /// Parks and trails within `radius` meters of `center`, nearest first.
    /// Empty if there are none or Apple Maps can't be reached.
    static func find(near center: RouteCoordinate, radius: Double) async -> [GreenSpace] {
        let region = MKCoordinateRegion(center: center.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        var categories: [MKPointOfInterestCategory] = [.park, .nationalPark]
        if #available(iOS 18.0, *) {
            categories.append(.hiking)
        }
        let filter = MKPointOfInterestFilter(including: categories)

        let places = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        places.pointOfInterestFilter = filter
        // Named trails and greenways aren't always tagged as parks, so search by name too.
        let trails = MKLocalSearch.Request()
        trails.naturalLanguageQuery = "trail"
        trails.region = region
        trails.resultTypes = .pointOfInterest
        trails.pointOfInterestFilter = filter

        async let parkItems = items(for: MKLocalSearch(request: places))
        async let trailItems = items(for: MKLocalSearch(request: trails))
        let found = (await parkItems + trailItems).compactMap { item -> GreenSpace? in
            let coordinate = RouteCoordinate(item.placemark.coordinate)
            guard coordinate.distance(to: center) <= radius else { return nil }
            return GreenSpace(name: item.name ?? "a park", coordinate: coordinate)
        }
        return deduplicated(found.sorted { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) })
    }

    private static func items(for search: MKLocalSearch) async -> [MKMapItem] {
        (try? await search.start().mapItems) ?? []
    }

    /// Drops places that are next to one already kept (a park and its trail).
    static func deduplicated(_ spaces: [GreenSpace]) -> [GreenSpace] {
        var kept: [GreenSpace] = []
        for space in spaces where !kept.contains(where: { $0.coordinate.distance(to: space.coordinate) < duplicateDistance }) {
            kept.append(space)
        }
        return kept
    }
}
