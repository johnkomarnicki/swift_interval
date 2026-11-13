import Foundation

/// Makes routes of about a given length from a start point, following roads
/// and paths.
///
/// A loop goes through three points spaced around a circle that passes through
/// the start; an out-and-back runs to a turnaround point and retraces. The size
/// is first guessed from the distance (roads are longer than straight lines),
/// then the route is measured and rescaled once to get closer. Each option
/// heads off in a different direction.
///
/// When preferring paths, the options head towards nearby parks and trails
/// instead of evenly spread directions, and points that land near one are moved
/// onto it, so the walking directions run through it.
@MainActor
struct RouteGenerator {
    enum Shape: String, CaseIterable, Identifiable {
        case loop
        case outAndBack

        var id: Self { self }

        var title: String {
            switch self {
            case .loop: "Loop"
            case .outAndBack: "Out & back"
            }
        }
    }

    struct Option: Identifiable, Equatable {
        let id: Int
        var waypoints: [RouteCoordinate]
        var legs: [[RouteCoordinate]]
        var meters: Double
        /// Direction the route heads off in, in degrees from north.
        var bearing: Double
        /// Parks and trails the route goes through.
        var via: [String] = []
    }

    /// How much longer a route on roads is than the straight-line shape.
    static let roadFactor = 1.3
    /// Close enough not to bother rescaling.
    static let closeEnough = 0.05
    /// Tries per option: the first guess and one rescale.
    static let attempts = 2
    /// Options must point at least this far apart (degrees) to count as different.
    static let minimumSpread: Double = 50
    /// A loop point moves onto a park within this fraction of the loop's radius.
    static let snapFraction = 0.6
    /// An out-and-back can go through a park this far off its line (degrees).
    static let outAndBackCone: Double = 35

    /// The walking path between two points as the map draws it, or nil when
    /// there isn't one. The ends are snapped to the nearest road or path.
    let findPath: (RouteCoordinate, RouteCoordinate) async -> [RouteCoordinate]?
    /// Parks and trails within a radius (meters) of a point, nearest first.
    let findGreenSpaces: (RouteCoordinate, Double) async -> [GreenSpace]

    init(
        findPath: @escaping (RouteCoordinate, RouteCoordinate) async -> [RouteCoordinate]? = RouteBuilder.snappedWalkingPath,
        findGreenSpaces: @escaping (RouteCoordinate, Double) async -> [GreenSpace] = GreenSpaceFinder.find
    ) {
        self.findPath = findPath
        self.findGreenSpaces = findGreenSpaces
    }

    /// Up to `count` routes heading in different directions. Empty when no
    /// walking paths could be found. Ordered by `ranked`.
    func options(
        from start: RouteCoordinate,
        meters target: Double,
        shape: Shape,
        count: Int = 3,
        bearingOffset: Double = 0,
        prefersPaths: Bool = false
    ) async -> [Option] {
        let reach = Self.reach(for: target, shape: shape)
        let greens = prefersPaths ? await findGreenSpaces(start, reach * 1.2) : []
        let bearings = Self.bearings(count: count, offset: bearingOffset, toward: greens, from: start, reach: reach)
        let options = await withTaskGroup(of: Option?.self) { group in
            for (index, bearing) in bearings.enumerated() {
                group.addTask { @MainActor in
                    await option(id: index, from: start, meters: target, shape: shape, bearing: bearing, greens: greens)
                }
            }
            var options: [Option] = []
            for await option in group {
                if let option { options.append(option) }
            }
            return options
        }
        return Self.ranked(options, target: target)
    }

    /// Options that fit the distance first, those through more parks and
    /// trails first among them, then by how close they are to the target.
    static func ranked(_ options: [Option], target: Double) -> [Option] {
        options.sorted { a, b in
            let aFits = RouteFit.match(routeMeters: a.meters, targetMeters: target) == .fits
            let bFits = RouteFit.match(routeMeters: b.meters, targetMeters: target) == .fits
            if aFits != bFits { return aFits }
            if aFits, a.via.count != b.via.count { return a.via.count > b.via.count }
            return abs(a.meters - target) < abs(b.meters - target)
        }
    }

    /// How far from the start a route of this length reaches, as first guessed.
    static func reach(for meters: Double, shape: Shape) -> Double {
        switch shape {
        case .loop: 2 * initialSize(for: meters, shape: .loop)
        case .outAndBack: initialSize(for: meters, shape: .outAndBack)
        }
    }

    /// Directions for the options: towards green spaces at a usable distance
    /// first (kept at least `minimumSpread` apart), then evenly spread ones.
    /// A non-zero `offset` (Try Different Routes) turns to other green spaces
    /// and directions.
    static func bearings(count: Int, offset: Double, toward greens: [GreenSpace], from start: RouteCoordinate, reach: Double) -> [Double] {
        var candidates = greens
            .filter { (0.25 * reach...1.1 * reach).contains($0.coordinate.distance(to: start)) }
            .map { bearing(from: start, to: $0.coordinate) }
        if !candidates.isEmpty, offset != 0 {
            let shift = Int(offset) % candidates.count
            candidates = Array(candidates[shift...] + candidates[..<shift])
        }
        var chosen: [Double] = []
        func add(_ bearing: Double) {
            guard chosen.count < count, chosen.allSatisfy({ angleBetween($0, bearing) >= minimumSpread }) else { return }
            chosen.append(bearing)
        }
        candidates.forEach(add)
        for index in 0..<count * 4 where chosen.count < count {
            add((offset + Double(index) * 360 / Double(count) + Double(index / count) * 30).truncatingRemainder(dividingBy: 360))
        }
        return chosen
    }

    private func option(id: Int, from start: RouteCoordinate, meters target: Double, shape: Shape, bearing: Double, greens: [GreenSpace]) async -> Option? {
        var size = Self.initialSize(for: target, shape: shape)
        var best: Option?
        for _ in 0..<Self.attempts {
            guard let candidate = await route(id: id, from: start, size: size, shape: shape, bearing: bearing, greens: greens),
                  candidate.meters > 0 else { break }
            if best == nil || abs(candidate.meters - target) < abs(best!.meters - target) {
                best = candidate
            }
            if abs(candidate.meters - target) / target <= Self.closeEnough { break }
            size *= min(2, max(0.5, target / candidate.meters))
        }
        return best
    }

    /// Circle radius for a loop, or distance to the turnaround for an out-and-back.
    static func initialSize(for meters: Double, shape: Shape) -> Double {
        switch shape {
        case .loop: meters / (2 * .pi * roadFactor)
        case .outAndBack: meters / (2 * roadFactor)
        }
    }

    private func route(id: Int, from start: RouteCoordinate, size: Double, shape: Shape, bearing: Double, greens: [GreenSpace]) async -> Option? {
        switch shape {
        case .loop:
            let (stops, via) = Self.loopStops(from: start, radius: size, bearing: bearing, greens: greens)
            guard var found = await paths(between: [start] + stops + [start]) else { return nil }
            // Start and finish exactly where the runner chose.
            found[0] = Self.joining(start, to: found[0], atStart: true)
            found[found.count - 1] = Self.joining(start, to: found[found.count - 1], atStart: false)
            let waypoints = [start] + found.dropLast().compactMap(\.last) + [start]
            return Option(id: id, waypoints: waypoints, legs: found, meters: RoutePath.length(of: RoutePath.joined(found)), bearing: bearing, via: via)

        case .outAndBack:
            let (stops, via) = Self.outAndBackStops(from: start, distance: size, bearing: bearing, greens: greens)
            guard var out = await paths(between: [start] + stops) else { return nil }
            out[0] = Self.joining(start, to: out[0], atStart: true)
            let back = out.reversed().map { Array($0.reversed()) }
            let legs = out + back
            let turns = out.compactMap(\.last)
            let waypoints = [start] + turns + turns.dropLast().reversed() + [start]
            return Option(id: id, waypoints: waypoints, legs: legs, meters: RoutePath.length(of: RoutePath.joined(legs)), bearing: bearing, via: via)
        }
    }

    /// Walking paths between each pair of neighbouring points, fetched all at
    /// once. Nil if any is missing (no path, or no connection).
    private func paths(between points: [RouteCoordinate]) async -> [[RouteCoordinate]]? {
        let pairs = Array(zip(points, points.dropFirst()))
        let legs: [[RouteCoordinate]?] = await withTaskGroup(of: (Int, [RouteCoordinate]?).self) { group in
            for (index, pair) in pairs.enumerated() {
                group.addTask { @MainActor in (index, await findPath(pair.0, pair.1)) }
            }
            var results = [[RouteCoordinate]?](repeating: nil, count: pairs.count)
            for await (index, path) in group { results[index] = path }
            return results
        }
        let found = legs.compactMap { $0 }
        return found.count == legs.count && !found.isEmpty ? found : nil
    }

    /// The loop's three turning points, each moved onto a different green space
    /// if one is near enough. The far point can also be pulled in to any green
    /// space inside the loop, so a loop aimed at a park goes through it; the
    /// rescale then makes up the distance with the side points.
    static func loopStops(from start: RouteCoordinate, radius: Double, bearing: Double, greens: [GreenSpace]) -> (stops: [RouteCoordinate], via: [String]) {
        var stops = loopPoints(from: start, radius: radius, bearing: bearing)
        let center = destination(from: start, bearing: bearing, meters: radius)
        var names: [Int: String] = [:]
        var used: Set<Int> = []
        for index in [1, 0, 2] { // far point first
            let point = stops[index]
            let nearest = greens.indices
                .filter { green in
                    guard !used.contains(green) else { return false }
                    let coordinate = greens[green].coordinate
                    return coordinate.distance(to: point) <= radius * snapFraction
                        || (index == 1 && coordinate.distance(to: center) <= radius)
                }
                .min { greens[$0].coordinate.distance(to: point) < greens[$1].coordinate.distance(to: point) }
            if let nearest {
                used.insert(nearest)
                stops[index] = greens[nearest].coordinate
                names[index] = greens[nearest].name
            }
        }
        return (stops, names.sorted { $0.key < $1.key }.map(\.value))
    }

    /// The turnaround, with a green space on the way if one lies roughly in that
    /// direction and not past it. A green space near the turnaround becomes the
    /// turnaround.
    static func outAndBackStops(from start: RouteCoordinate, distance: Double, bearing: Double, greens: [GreenSpace]) -> (stops: [RouteCoordinate], via: [String]) {
        let turnaround = destination(from: start, bearing: bearing, meters: distance)
        let onTheWay = greens.first { green in
            (0.2 * distance...1.1 * distance).contains(green.coordinate.distance(to: start))
                && angleBetween(Self.bearing(from: start, to: green.coordinate), bearing) <= outAndBackCone
        }
        guard let green = onTheWay else { return ([turnaround], []) }
        if green.coordinate.distance(to: start) >= 0.8 * distance {
            return ([green.coordinate], [green.name])
        }
        return ([green.coordinate, turnaround], [green.name])
    }

    /// Three points a quarter, half and three quarters of the way around a
    /// circle through `start` whose centre lies in the direction `bearing`.
    static func loopPoints(from start: RouteCoordinate, radius: Double, bearing: Double) -> [RouteCoordinate] {
        let center = destination(from: start, bearing: bearing, meters: radius)
        let back = bearing + 180 // from the centre, the start is this way
        return [90.0, 180, 270].map { destination(from: center, bearing: back + $0, meters: radius) }
    }

    /// Adds `point` to one end of a path if the path doesn't already reach it.
    private static func joining(_ point: RouteCoordinate, to path: [RouteCoordinate], atStart: Bool) -> [RouteCoordinate] {
        let end = atStart ? path.first : path.last
        guard let end, end.distance(to: point) > 1 else { return path }
        return atStart ? [point] + path : path + [point]
    }

    /// The point `meters` away from `start` heading `bearing` degrees from north.
    static func destination(from start: RouteCoordinate, bearing: Double, meters: Double) -> RouteCoordinate {
        let angle = meters / RouteCoordinate.earthRadius
        let heading = bearing * .pi / 180
        let lat1 = start.lat * .pi / 180
        let lon1 = start.lon * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angle) + cos(lat1) * sin(angle) * cos(heading))
        let lon2 = lon1 + atan2(sin(heading) * sin(angle) * cos(lat1), cos(angle) - sin(lat1) * sin(lat2))
        return RouteCoordinate(lat: lat2 * 180 / .pi, lon: lon2 * 180 / .pi)
    }

    /// Initial compass bearing from one point to another, 0..<360.
    static func bearing(from start: RouteCoordinate, to end: RouteCoordinate) -> Double {
        let lat1 = start.lat * .pi / 180
        let lat2 = end.lat * .pi / 180
        let dLon = (end.lon - start.lon) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The smaller angle between two bearings, 0...180.
    static func angleBetween(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    /// "north", "south-east", … for a bearing in degrees.
    static func compassName(_ bearing: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((normalized / 45).rounded()) % 8]
    }
}
