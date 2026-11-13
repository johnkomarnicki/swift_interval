import Foundation

/// One heart rate reading.
struct HeartRateSample: Equatable, Sendable {
    var date: Date
    var bpm: Int

    /// Readings needed per second of running for heart rate to be worth keeping.
    /// An Apple Watch outside a workout reads only every few minutes, far too
    /// sparse to tell one interval from the next.
    static let minimumReadingsPerSecond = 1.0 / 20

    /// Whether `samples` read often enough during `periods` to be kept.
    static func enough(_ samples: [HeartRateSample], for periods: [DateInterval]) -> Bool {
        let seconds = periods.reduce(0) { $0 + $1.duration }
        guard seconds > 0 else { return false }
        let inside = samples.filter { sample in periods.contains { $0.holds(sample.date) } }
        return Double(inside.count) >= seconds * minimumReadingsPerSecond
    }
}

/// Heart rate over one interval, in beats per minute.
struct HeartRateStats: Codable, Equatable {
    var average: Int
    var max: Int
    /// The last reading in the interval. The end of a work interval minus the end
    /// of the rest after it is how far heart rate recovered during the rest.
    var end: Int

    /// Nil without any readings.
    init?(_ readings: [HeartRateSample]) {
        let sorted = readings.sorted { $0.date < $1.date }
        guard let last = sorted.last else { return nil }
        average = Int((Double(sorted.reduce(0) { $0 + $1.bpm }) / Double(sorted.count)).rounded())
        max = sorted.map(\.bpm).max() ?? last.bpm
        end = last.bpm
    }

    init(average: Int, max: Int, end: Int) {
        self.average = average
        self.max = max
        self.end = end
    }
}

extension WorkoutResults {
    /// Adds heart rate to each interval from the readings taken during its
    /// `periods`. Leaves every interval without it when there are too few readings.
    static func addingHeartRate(_ intervals: [IntervalResult], from samples: [HeartRateSample]) -> [IntervalResult] {
        let periods = intervals.flatMap { $0.periods ?? [] }
        guard HeartRateSample.enough(samples, for: periods) else { return intervals }
        return intervals.map { interval in
            var interval = interval
            let own = interval.periods ?? []
            interval.heartRate = HeartRateStats(samples.filter { sample in own.contains { $0.holds(sample.date) } })
            return interval
        }
    }
}

extension Array where Element == IntervalResult {
    /// Average heart rate over the intervals that have it, weighted by time.
    var averageHeartRate: Int? {
        let measured = filter { $0.heartRate != nil && $0.activeSeconds > 0 }
        let seconds = measured.reduce(0) { $0 + $1.activeSeconds }
        guard seconds > 0 else { return nil }
        let weighted = measured.reduce(0) { $0 + Double($1.heartRate?.average ?? 0) * $1.activeSeconds }
        return Int((weighted / seconds).rounded())
    }

    var maxHeartRate: Int? {
        compactMap(\.heartRate?.max).max()
    }

    /// How far heart rate fell, on average, from the end of each work interval
    /// to the end of the rest after it. Nil without a measured work-then-rest pair.
    var averageRecovery: Int? {
        let drops = indices.dropFirst().compactMap { index -> Int? in
            let rest = self[index], work = self[index - 1]
            guard rest.phase == .rest, work.phase == .work, !rest.wasSkipped,
                  let restEnd = rest.heartRate?.end, let workEnd = work.heartRate?.end else { return nil }
            return workEnd - restEnd
        }
        guard !drops.isEmpty else { return nil }
        return Int((Double(drops.reduce(0, +)) / Double(drops.count)).rounded())
    }
}

private extension DateInterval {
    /// Like `contains`, but the end moment belongs to whatever comes next, so a
    /// reading taken right at a switch counts only for the interval starting then.
    func holds(_ date: Date) -> Bool {
        start <= date && date < end
    }
}
