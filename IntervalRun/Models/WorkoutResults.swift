import Foundation

/// Where an interval's distance came from.
enum DistanceSource: String, Codable {
    case gps
    case steps
    case none
}

/// What happened in one interval of a finished workout.
struct IntervalResult: Codable, Equatable, Identifiable {
    var index: Int
    var phase: Phase
    var round: Int?
    var plannedSeconds: Int
    /// Time actually spent in the interval (less if it was skipped part-way).
    var activeSeconds: TimeInterval
    /// Nil when distance wasn't tracked.
    var meters: Double?
    var source: DistanceSource
    /// The real-time stretches spent in the interval (more than one if it was
    /// paused), so heart rate can be matched to it, even after the run.
    var periods: [DateInterval]? = nil
    /// Nil when heart rate wasn't recorded.
    var heartRate: HeartRateStats? = nil

    var id: Int { index }

    var title: String {
        switch phase {
        case .warmUp: "Warm-up"
        case .coolDown: "Cool-down"
        case .work: "Work \(round ?? 1)"
        case .rest: "Rest \(round ?? 1)"
        }
    }

    /// Skipped before it started (no time spent in it).
    var wasSkipped: Bool { activeSeconds < 0.5 }
}

/// The outcome of a workout, saved to history as a `WorkoutRecord`.
struct WorkoutResults: Equatable {
    var name: String
    var date: Date
    /// False when ended early with ✕.
    var completed: Bool
    /// Wall-clock time from Start to the end, including pauses.
    var totalTime: TimeInterval
    var intervals: [IntervalResult]
    /// Set when the run was a session from an AI program.
    var programLink: ProgramLink? = nil
    /// Set for a free run or walk, which has a single interval covering it all.
    var activity: FreeActivity? = nil

    /// Time spent in intervals, excluding pauses and skipped time.
    var activeTime: TimeInterval {
        intervals.reduce(0) { $0 + $1.activeSeconds }
    }

    /// Nil when distance wasn't tracked.
    var totalMeters: Double? {
        let tracked = intervals.compactMap(\.meters)
        return tracked.isEmpty ? nil : tracked.reduce(0, +)
    }

    /// Builds one result per segment with time spent in each, and no distance yet.
    static func intervals(for segments: [Segment], timeline: RunTimeline, now: Date) -> [IntervalResult] {
        var start: TimeInterval = 0
        return segments.enumerated().map { index, segment in
            let span = start..<(start + segment.duration)
            start += segment.duration
            let periods = timeline.dateRanges(for: span, now: now)
            return IntervalResult(
                index: index,
                phase: segment.phase,
                round: segment.round,
                plannedSeconds: segment.seconds,
                activeSeconds: periods.reduce(0) { $0 + $1.duration },
                meters: nil,
                source: .none,
                periods: periods.isEmpty ? nil : periods
            )
        }
    }
}

extension Array where Element == IntervalResult {
    /// One result per step of a round, averaged across the rounds that ran it, so a
    /// workout of repeated rounds can be shown as a single round. Nil for one round.
    var roundAverages: [IntervalResult]? {
        let rounds = Dictionary(grouping: filter { $0.round != nil }) { $0.round ?? 0 }
        guard rounds.count > 1 else { return nil }
        let stepCount = rounds.values.map(\.count).max() ?? 0
        return (0..<stepCount).map { step in
            let runs = rounds.values.compactMap { $0.indices.contains(step) ? $0[step] : nil }
            let ran = runs.filter { !$0.wasSkipped }
            let measured = ran.filter { $0.meters != nil }
            let timed = ran.filter { $0.heartRate != nil }
            var average = IntervalResult(
                index: step,
                phase: runs[0].phase,
                round: nil,
                plannedSeconds: runs[0].plannedSeconds,
                activeSeconds: ran.isEmpty ? 0 : ran.reduce(0) { $0 + $1.activeSeconds } / Double(ran.count),
                meters: measured.isEmpty ? nil : measured.compactMap(\.meters).reduce(0, +) / Double(measured.count),
                source: !measured.isEmpty && measured.allSatisfy { $0.source == .steps } ? .steps : (measured.first?.source ?? .none)
            )
            if let heartRate = timed.averageHeartRate, let max = timed.maxHeartRate {
                let end = Double(timed.compactMap(\.heartRate?.end).reduce(0, +)) / Double(timed.count)
                average.heartRate = HeartRateStats(average: heartRate, max: max, end: Int(end.rounded()))
            }
            return average
        }
    }

    /// Rounds with at least one interval that wasn't skipped.
    var roundsRun: Int {
        Set(filter { !$0.wasSkipped }.compactMap(\.round)).count
    }

    /// Rounds in the workout, run or not.
    var roundCount: Int {
        Set(compactMap(\.round)).count
    }
}
