import Foundation
import Observation

/// An open-ended run or walk: a stopwatch with distance, no intervals.
///
/// Distance reuses `DistanceTracker`, which works in intervals, by splitting the
/// run into back-to-back one-minute chunks. GPS or the step counter is chosen per
/// chunk, so a few minutes without GPS (a tunnel, tall buildings) fall back to
/// the step counter for just those minutes instead of the whole run. When the
/// run ends the chunks are added up into a single result.
@MainActor
@Observable
final class FreeRunSession: Identifiable {
    let id = UUID()
    let activity: FreeActivity
    /// The route planned for this run, shown on the player's map.
    let route: RoutePath?

    private(set) var hasStarted = false
    private(set) var isPaused = false
    private(set) var isFinished = false
    /// Time spent moving, excluding pauses.
    private(set) var activeTime: TimeInterval = 0
    /// Real time from Start to Finish, including pauses.
    private(set) var totalTime: TimeInterval = 0
    private(set) var meters: Double = 0
    /// Where the most recent distance is coming from.
    private(set) var source: DistanceSource = .none
    /// Where GPS has seen the runner go, for the player's map.
    private(set) var trail = RunTrail()
    /// Where the runner is and which way they're going, for the player's map.
    private(set) var position: LivePosition?
    /// Available shortly after the run ends.
    private(set) var results: WorkoutResults?
    /// Called once with the results (to save them to history).
    @ObservationIgnored var onResultsReady: ((WorkoutResults) -> Void)?

    static let chunkLength = 60
    /// Distance stops being counted after this long; far beyond any real walk.
    static let maxChunks = 24 * 60

    @ObservationIgnored private let segments = Array(repeating: Segment(.work, FreeRunSession.chunkLength), count: FreeRunSession.maxChunks)
    @ObservationIgnored private let mode: DistanceMode
    @ObservationIgnored private var startDate: Date?
    @ObservationIgnored private var timeline = RunTimeline()
    @ObservationIgnored private var tracker: DistanceTracker?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var usesHeartRateMonitor = false

    init(activity: FreeActivity, route: RoutePath? = nil, mode: DistanceMode = AppSettings.distanceMode) {
        self.activity = activity
        self.route = route
        self.mode = mode
    }

    /// Whether GPS is tracking this run, so the player can show a live map.
    var usesGPS: Bool { mode == .automatic }

    // MARK: Controls

    func start() {
        guard !hasStarted, !isStopped else { return }
        let now = Date.now
        hasStarted = true
        startDate = now
        timeline.begin(at: now, elapsed: 0)
        HeartRateMonitor.shared.acquire()
        usesHeartRateMonitor = true
        let tracker = DistanceTracker(segments: segments, mode: mode) { [weak self] date in
            self?.timeline.elapsed(at: date)
        }
        tracker.onChange = { [weak self, weak tracker] in
            guard let self, let tracker else { return }
            if tracker.trail != self.trail { self.trail = tracker.trail }
            if tracker.position != self.position { self.position = tracker.position }
            self.refresh()
        }
        tracker.start(at: now)
        self.tracker = tracker
        startTicker()
        refresh()
    }

    func togglePause() {
        guard hasStarted, !isFinished else { return }
        let now = Date.now
        if isPaused {
            timeline.begin(at: now, elapsed: activeTime(at: now))
        } else {
            timeline.end(at: now)
        }
        isPaused.toggle()
        tracker?.breakPath()
        refresh()
    }

    /// Ends the run and works out the final distance for saving.
    func finish() {
        guard hasStarted, !isFinished, !isStopped, let startDate else { return }
        let end = Date.now
        timeline.end(at: end)
        refresh()
        isFinished = true
        totalTime = end.timeIntervalSince(startDate)
        stopTicker()
        finishTracking(endedAt: end)
    }

    /// Stops without saving, or cleans up after finishing. Safe to call twice.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        stopTicker()
        if !isFinished {
            tracker?.stop()
            releaseHeartRateMonitor()
        }
    }

    /// Re-reads the clock and distance. Called by the display timer, on new
    /// distance data and on returning to the foreground.
    func refresh() {
        guard hasStarted, !isFinished else { return }
        let now = Date.now
        let active = activeTime(at: now)
        if active != activeTime { activeTime = active }
        updateDistance()
    }

    // MARK: Distance

    private func activeTime(at date: Date) -> TimeInterval {
        timeline.activeDuration(for: 0..<TimeInterval(Self.chunkLength * Self.maxChunks), now: date)
    }

    private func updateDistance() {
        guard let tracker else { return }
        var total: Double = 0
        var latest: DistanceSource = .none
        for (index, seconds) in Self.secondsPerChunk(activeTime: activeTime).enumerated() {
            let (chunkMeters, chunkSource) = tracker.liveDistance(segment: index, activeSeconds: seconds)
            total += chunkMeters
            // A chunk only a few seconds old hasn't had time to judge GPS yet.
            if chunkSource != .none, seconds >= 10 || latest == .none {
                latest = chunkSource
            }
        }
        if total != meters { meters = total }
        if latest != source { source = latest }
    }

    private func finishTracking(endedAt end: Date) {
        guard let tracker, let startDate else { return }
        tracker.finish(at: end)
        let timeline = timeline
        let activeTime = activeTime
        let chunks = WorkoutResults.intervals(for: segments, timeline: timeline, now: end)
            .filter { $0.activeSeconds > 0 }
        Task { @MainActor in
            // Let late GPS fixes arrive and the step counter record the last few
            // seconds before adding up.
            try? await Task.sleep(for: .seconds(2))
            tracker.stop()
            let filled = await tracker.fillDistances(chunks, timeline: timeline, now: end)
            let periods = timeline.dateRanges(for: 0..<TimeInterval(Self.chunkLength * Self.maxChunks), now: end)
            let run = Self.combined(filled, activeTime: activeTime, periods: periods)
            let intervals = await HeartRateRecorder.addHeartRate(to: [run])
            releaseHeartRateMonitor()
            let results = WorkoutResults(
                name: activity.title,
                date: startDate,
                completed: true,
                totalTime: totalTime,
                intervals: intervals,
                activity: activity
            )
            meters = results.totalMeters ?? meters
            self.results = results
            onResultsReady?(results)
        }
    }

    /// Time spent in each one-minute chunk so far; the last one is still filling.
    static func secondsPerChunk(activeTime: TimeInterval) -> [TimeInterval] {
        guard activeTime > 0 else { return [] }
        let count = min(maxChunks, Int((activeTime / TimeInterval(chunkLength)).rounded(.up)))
        return (0..<count).map { index in
            min(TimeInterval(chunkLength), activeTime - TimeInterval(index * chunkLength))
        }
    }

    /// Adds the chunks up into one interval covering the whole run. Its source is
    /// whichever of GPS and the step counter measured more of the time.
    static func combined(_ chunks: [IntervalResult], activeTime: TimeInterval, periods: [DateInterval]? = nil) -> IntervalResult {
        func seconds(from source: DistanceSource) -> TimeInterval {
            chunks.filter { $0.source == source }.reduce(0) { $0 + $1.activeSeconds }
        }
        let gps = seconds(from: .gps)
        let steps = seconds(from: .steps)
        return IntervalResult(
            index: 0,
            phase: .work,
            round: nil,
            plannedSeconds: Int(activeTime.rounded()),
            activeSeconds: activeTime,
            meters: chunks.compactMap(\.meters).reduce(0, +),
            source: gps == 0 && steps == 0 ? .none : (gps >= steps ? .gps : .steps),
            periods: periods
        )
    }

    private func releaseHeartRateMonitor() {
        guard usesHeartRateMonitor else { return }
        usesHeartRateMonitor = false
        HeartRateMonitor.shared.release()
    }

    // MARK: Display

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
