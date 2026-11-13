import CoreLocation

/// The line actually run, built from GPS fixes for the player's map.
///
/// - Fixes worse than `DistanceAccumulator.maxAccuracy` are ignored.
/// - Points closer than `minimumSpacing` to the last one are dropped, so standing
///   still doesn't pile up jitter and long runs stay a manageable size to draw.
/// - A move faster than `DistanceAccumulator.maxSpeed` is a GPS jump and ignored,
///   unless it keeps happening, in which case a new line starts from there.
/// - `breakLine()` (while paused) starts a new line at the next fix, so where
///   you went while paused isn't drawn.
struct RunTrail: Equatable {
    static let minimumSpacing: CLLocationDistance = 5

    /// Separate lines, split at pauses and GPS jumps.
    private(set) var lines: [[RouteCoordinate]] = []

    private var lastTimestamp: Date?
    private var isBroken = true
    private var jumpsInARow = 0

    mutating func add(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= DistanceAccumulator.maxAccuracy else { return }
        let point = RouteCoordinate(location.coordinate)
        guard !isBroken, let last = lines.last?.last, let lastTimestamp else {
            startLine(at: point, time: location.timestamp)
            return
        }
        let distance = point.distance(to: last)
        let seconds = location.timestamp.timeIntervalSince(lastTimestamp)
        guard seconds > 0 else { return }
        if distance / seconds > DistanceAccumulator.maxSpeed {
            jumpsInARow += 1
            if jumpsInARow >= DistanceAccumulator.jumpsBeforeReanchoring {
                startLine(at: point, time: location.timestamp)
            }
            return
        }
        jumpsInARow = 0
        guard distance >= Self.minimumSpacing else { return }
        lines[lines.count - 1].append(point)
        self.lastTimestamp = location.timestamp
    }

    /// The next fix starts a new line.
    mutating func breakLine() {
        isBroken = true
    }

    private mutating func startLine(at point: RouteCoordinate, time: Date) {
        // A line that never got past its first point draws nothing; reuse it.
        if let last = lines.last, last.count < 2 {
            lines[lines.count - 1] = [point]
        } else {
            lines.append([point])
        }
        lastTimestamp = time
        isBroken = false
        jumpsInARow = 0
    }
}
