import Foundation

/// How long a route a plan session needs. Sessions are timed, so the distance
/// is the session's length at the runner's usual pace, taken from recent runs
/// in History.
enum RouteFit {
    /// 12:00 /mi, a gentle run/walk pace, used before there's any history.
    static let fallbackSpeed = DistanceFormat.metersPerMile / 720
    /// A route within this fraction of the target counts as a fit.
    static let tolerance = 0.15
    /// How many recent runs the pace is averaged over.
    static let recentRuns = 10

    struct Pace: Equatable {
        var metersPerSecond: Double
        /// False when there weren't any usable runs and the fallback was used.
        var fromHistory: Bool

        var secondsPerMile: Int {
            Int((DistanceFormat.metersPerMile / metersPerSecond).rounded())
        }
    }

    enum Match: Equatable {
        case short, fits, long
    }

    /// Average pace over the most recent runs with a real distance (at least a
    /// quarter mile and five minutes). `runs` must be newest first.
    static func usualPace(_ runs: [(meters: Double, seconds: TimeInterval)]) -> Pace {
        let usable = runs.filter { $0.meters >= 400 && $0.seconds >= 300 }.prefix(recentRuns)
        let meters = usable.reduce(0) { $0 + $1.meters }
        let seconds = usable.reduce(0) { $0 + $1.seconds }
        guard meters > 0, seconds > 0 else { return Pace(metersPerSecond: fallbackSpeed, fromHistory: false) }
        return Pace(metersPerSecond: meters / seconds, fromHistory: true)
    }

    static func targetMeters(seconds: Int, pace: Pace) -> Double {
        Double(seconds) * pace.metersPerSecond
    }

    static func match(routeMeters: Double, targetMeters: Double) -> Match {
        guard targetMeters > 0 else { return .fits }
        let ratio = routeMeters / targetMeters
        if ratio < 1 - tolerance { return .short }
        if ratio > 1 + tolerance { return .long }
        return .fits
    }
}

extension RouteFit {
    /// The usual pace from history records, which may be in any order.
    static func usualPace(records: [WorkoutRecord]) -> Pace {
        usualPace(
            records.sorted { $0.date > $1.date }
                .compactMap { record in record.totalMeters.map { ($0, record.activeTime) } }
        )
    }
}
