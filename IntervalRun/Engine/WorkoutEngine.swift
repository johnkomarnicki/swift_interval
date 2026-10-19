import Foundation

/// Where the workout is at a given moment.
struct WorkoutStatus: Equatable {
    /// Workout time completed, excluding pauses and including skipped time.
    var elapsed: TimeInterval
    /// Index into `segments`, or nil once the workout is finished.
    var segmentIndex: Int?
    var timeLeftInSegment: TimeInterval
    var totalRemaining: TimeInterval

    var isFinished: Bool { segmentIndex == nil }
}

/// Clock-based workout timing with no UI or audio code.
///
/// Progress is never counted by timer ticks. The engine stores when the workout
/// started, how long it has been paused, and how much time Skip jumped over, then
/// derives everything from the real clock:
///
///     elapsed = (now or pause start) − startDate − accumulatedPause + skippedTime
///
/// So the answer is correct however rarely you ask, including after the app has
/// been in the background.
struct WorkoutEngine {
    let segments: [Segment]
    /// Workout-elapsed time at which each segment begins.
    let segmentStarts: [TimeInterval]
    let totalDuration: TimeInterval

    private(set) var startDate: Date?
    private(set) var accumulatedPause: TimeInterval = 0
    private(set) var pausedAt: Date?
    private(set) var skippedTime: TimeInterval = 0

    init(segments: [Segment]) {
        self.segments = segments
        var starts: [TimeInterval] = []
        var cursor: TimeInterval = 0
        for segment in segments {
            starts.append(cursor)
            cursor += segment.duration
        }
        segmentStarts = starts
        totalDuration = cursor
    }

    var hasStarted: Bool { startDate != nil }
    var isPaused: Bool { pausedAt != nil }

    // MARK: Controls

    mutating func start(at now: Date) {
        guard startDate == nil else { return }
        startDate = now
    }

    mutating func pause(at now: Date) {
        guard hasStarted, pausedAt == nil else { return }
        pausedAt = now
    }

    /// Shifts the whole schedule later by however long the pause lasted.
    mutating func resume(at now: Date) {
        guard let pausedAt else { return }
        accumulatedPause += max(0, now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
    }

    /// Jumps to the start of the next segment (or to the end, from the last one).
    mutating func skip(at now: Date) {
        guard hasStarted else { return }
        let current = elapsed(at: now)
        guard let index = segmentIndex(forElapsed: current) else { return }
        let nextStart = index + 1 < segmentStarts.count ? segmentStarts[index + 1] : totalDuration
        skippedTime += nextStart - current
    }

    // MARK: Queries

    func elapsed(at now: Date) -> TimeInterval {
        guard let startDate else { return 0 }
        let reference = pausedAt ?? now
        let raw = reference.timeIntervalSince(startDate) - accumulatedPause + skippedTime
        return min(max(raw, 0), totalDuration)
    }

    /// The segment running at a given workout-elapsed time, or nil when finished.
    func segmentIndex(forElapsed elapsed: TimeInterval) -> Int? {
        // Tolerance so a boundary that lands a hair early (floating-point noise)
        // still counts as the next segment.
        let e = elapsed + 1e-9
        guard e < totalDuration else { return nil }
        var index = 0
        for (i, start) in segmentStarts.enumerated() where start <= e {
            index = i
        }
        return index
    }

    func status(at now: Date) -> WorkoutStatus {
        let e = elapsed(at: now)
        guard let index = segmentIndex(forElapsed: e) else {
            return WorkoutStatus(elapsed: totalDuration, segmentIndex: nil, timeLeftInSegment: 0, totalRemaining: 0)
        }
        let segmentEnd = segmentStarts[index] + segments[index].duration
        return WorkoutStatus(
            elapsed: e,
            segmentIndex: index,
            timeLeftInSegment: segmentEnd - e,
            totalRemaining: totalDuration - e
        )
    }

    /// The real-clock moment a workout-elapsed time will be reached if nothing else
    /// is paused or skipped. Nil while paused or before starting.
    func date(forElapsed elapsed: TimeInterval) -> Date? {
        guard let startDate, pausedAt == nil else { return nil }
        return startDate.addingTimeInterval(accumulatedPause - skippedTime + elapsed)
    }
}
