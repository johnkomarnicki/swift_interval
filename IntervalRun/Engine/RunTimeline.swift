import Foundation

/// The real-time stretches during which a workout was running.
///
/// Each stretch starts at a known workout-elapsed time and runs in step with the
/// clock until a pause, a skip or the end. That's enough to answer "during which
/// real moments was the workout inside interval 3?", which is what the step
/// counter needs, and how long was really spent in each interval.
struct RunTimeline: Equatable {
    struct Stretch: Equatable {
        var start: Date
        /// Nil while still running.
        var end: Date?
        var startElapsed: TimeInterval
    }

    private(set) var stretches: [Stretch] = []

    var isRunning: Bool {
        stretches.last.map { $0.end == nil } ?? false
    }

    /// Call on start, on resume, and right after a skip.
    mutating func begin(at date: Date, elapsed: TimeInterval) {
        end(at: date)
        stretches.append(Stretch(start: date, end: nil, startElapsed: elapsed))
    }

    /// Call on pause, right before a skip, and when the workout ends.
    mutating func end(at date: Date) {
        guard isRunning else { return }
        let index = stretches.count - 1
        stretches[index].end = max(date, stretches[index].start)
    }

    /// The real-time ranges during which workout time was inside `span`.
    /// A stretch that's still running is treated as ending at `now`.
    func dateRanges(for span: Range<TimeInterval>, now: Date) -> [DateInterval] {
        stretches.compactMap { stretch in
            let length = max(0, (stretch.end ?? now).timeIntervalSince(stretch.start))
            let lower = max(span.lowerBound, stretch.startElapsed)
            let upper = min(span.upperBound, stretch.startElapsed + length)
            guard upper > lower else { return nil }
            return DateInterval(
                start: stretch.start.addingTimeInterval(lower - stretch.startElapsed),
                end: stretch.start.addingTimeInterval(upper - stretch.startElapsed)
            )
        }
    }

    /// Workout time at `date`, or nil if the workout wasn't running then (paused,
    /// or before the start or after the end).
    func elapsed(at date: Date) -> TimeInterval? {
        guard let stretch = stretches.last(where: { $0.start <= date }),
              date <= stretch.end ?? .distantFuture else { return nil }
        return stretch.startElapsed + date.timeIntervalSince(stretch.start)
    }

    /// Real time spent with workout time inside `span`.
    func activeDuration(for span: Range<TimeInterval>, now: Date) -> TimeInterval {
        dateRanges(for: span, now: now).reduce(0) { $0 + $1.duration }
    }
}
