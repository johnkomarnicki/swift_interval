import CoreLocation

/// Adds up GPS distance per interval, with no Core Location manager involved,
/// so the filtering rules can be unit tested.
///
/// - Fixes worse than `maxAccuracy` are ignored (indoors, under trees, startup).
/// - Moves smaller than the two fixes' combined accuracy (between `minimumStep`
///   and `maximumStep`) don't move the anchor point, so GPS jitter while standing
///   still doesn't add up to phantom distance. Whatever is still held back is
///   added when the path breaks (pause, skip) or tracking ends (`flush`).
/// - A move faster than `maxSpeed` is treated as a GPS jump and ignored, unless
///   it keeps happening, in which case the new position is accepted as the truth.
/// - Distance between two fixes that straddle an interval boundary is split
///   between the intervals by time.
struct DistanceAccumulator {
    static let maxAccuracy: CLLocationAccuracy = 25
    static let minimumStep: CLLocationDistance = 4
    static let maximumStep: CLLocationDistance = 20
    /// Held-back distance is only real if it implies at least walking speed;
    /// slower than this it's jitter that built up while standing still.
    static let minimumFlushSpeed: Double = 0.5
    /// Meters per second; well beyond any runner.
    static let maxSpeed: Double = 12
    static let jumpsBeforeReanchoring = 3

    let segmentStarts: [TimeInterval]
    let totalDuration: TimeInterval
    /// GPS meters per segment.
    private(set) var meters: [Double]
    /// Accepted GPS fixes per segment, used to judge whether GPS covered it.
    private(set) var fixes: [Int]

    /// The point distance is measured from.
    private var anchor: (location: CLLocation, elapsed: TimeInterval)?
    /// The most recent accepted fix (may be closer to the anchor than a step).
    private var latest: (location: CLLocation, elapsed: TimeInterval)?
    private var jumpsInARow = 0

    init(segments: [Segment]) {
        var starts: [TimeInterval] = []
        var cursor: TimeInterval = 0
        for segment in segments {
            starts.append(cursor)
            cursor += segment.duration
        }
        segmentStarts = starts
        totalDuration = cursor
        meters = Array(repeating: 0, count: segments.count)
        fixes = Array(repeating: 0, count: segments.count)
    }

    /// Adds a fix taken at workout-elapsed time `elapsed`.
    mutating func add(_ location: CLLocation, elapsed: TimeInterval) {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.maxAccuracy,
              let index = segmentIndex(forElapsed: elapsed) else { return }
        fixes[index] += 1

        guard let anchor else {
            self.anchor = (location, elapsed)
            latest = (location, elapsed)
            return
        }
        let seconds = elapsed - anchor.elapsed
        guard seconds > 0 else { return }
        let distance = location.distance(from: anchor.location)

        if distance / seconds > Self.maxSpeed {
            jumpsInARow += 1
            if jumpsInARow >= Self.jumpsBeforeReanchoring {
                self.anchor = (location, elapsed)
                latest = (location, elapsed)
                jumpsInARow = 0
            }
            return
        }
        jumpsInARow = 0
        latest = (location, elapsed)

        // Two fixes can each be off by their accuracy radius, so smaller moves
        // could be pure jitter.
        let step = min(Self.maximumStep, max(Self.minimumStep, anchor.location.horizontalAccuracy + location.horizontalAccuracy))
        guard distance >= step else { return }
        addDistance(distance, from: anchor.elapsed, to: elapsed)
        self.anchor = (location, elapsed)
    }

    /// GPS meters for a segment including distance still held back below the
    /// step size, so the live display and pace don't lag behind.
    func liveMeters(segment: Int) -> Double {
        guard meters.indices.contains(segment) else { return 0 }
        var value = meters[segment]
        if let anchor, let latest, latest.elapsed > anchor.elapsed {
            let pending = latest.location.distance(from: anchor.location)
            for share in Self.split(pending, from: anchor.elapsed, to: latest.elapsed, starts: segmentStarts, total: totalDuration)
            where share.index == segment {
                value += share.meters
            }
        }
        return value
    }

    /// Adds distance still held back below the step size, up to the latest fix.
    mutating func flush() {
        guard let anchor, let latest, latest.elapsed > anchor.elapsed else { return }
        let distance = latest.location.distance(from: anchor.location)
        guard distance / (latest.elapsed - anchor.elapsed) >= Self.minimumFlushSpeed else { return }
        addDistance(distance, from: anchor.elapsed, to: latest.elapsed)
        self.anchor = latest
    }

    /// Forget the last position, so time spent paused (or jumped over by Skip)
    /// doesn't count as distance.
    mutating func breakPath() {
        flush()
        anchor = nil
        latest = nil
        jumpsInARow = 0
    }

    private mutating func addDistance(_ distance: Double, from start: TimeInterval, to end: TimeInterval) {
        for share in Self.split(distance, from: start, to: end, starts: segmentStarts, total: totalDuration) {
            meters[share.index] += share.meters
        }
    }

    /// Whether GPS had enough good fixes in a segment to trust its distance:
    /// at least one every two seconds on average.
    func hasGoodCoverage(segment: Int, activeSeconds: TimeInterval) -> Bool {
        guard fixes.indices.contains(segment), activeSeconds > 0 else { return false }
        return Double(fixes[segment]) >= max(3, activeSeconds * 0.5)
    }

    func segmentIndex(forElapsed elapsed: TimeInterval) -> Int? {
        guard !segmentStarts.isEmpty, elapsed >= 0, elapsed <= totalDuration + 1e-9 else { return nil }
        return segmentStarts.lastIndex { $0 <= elapsed + 1e-9 }
    }

    /// Splits a distance covered between two workout times across the segments
    /// those times span, in proportion to time.
    static func split(
        _ distance: Double,
        from start: TimeInterval,
        to end: TimeInterval,
        starts: [TimeInterval],
        total: TimeInterval
    ) -> [(index: Int, meters: Double)] {
        guard end > start else { return [] }
        var shares: [(index: Int, meters: Double)] = []
        for (index, segmentStart) in starts.enumerated() {
            let segmentEnd = index + 1 < starts.count ? starts[index + 1] : total
            let overlap = min(end, segmentEnd) - max(start, segmentStart)
            if overlap > 0 {
                shares.append((index, distance * overlap / (end - start)))
            }
        }
        return shares
    }
}
