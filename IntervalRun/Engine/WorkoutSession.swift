import Foundation
import Observation

/// Distance shown on the player while running.
struct LiveDistance: Equatable {
    /// Meters in the interval on screen.
    var interval: Double
    /// Seconds spent in the interval on screen, for its pace.
    var intervalSeconds: TimeInterval
    /// Meters for the whole workout so far.
    var total: Double
    /// Where the on-screen interval's distance is coming from.
    var source: DistanceSource
}

/// A running workout: wraps `WorkoutEngine` with the real clock, the audio
/// scheduler, distance and heart rate tracking and a display refresh for the
/// player screen.
///
/// The display timer only redraws; it never advances time. Each refresh reads the
/// clock and asks the engine where the workout is.
@MainActor
@Observable
final class WorkoutSession: Identifiable {
    let id = UUID()
    let name: String
    let plan: WorkoutPlan
    /// Set when this run is a session from an AI program.
    let programLink: ProgramLink?
    /// The route planned for this run, shown on the player's map.
    let route: RoutePath?

    private(set) var engine: WorkoutEngine
    private(set) var status: WorkoutStatus
    private(set) var isFinished = false
    /// Real time from Start to finish, including pauses.
    private(set) var totalTime: TimeInterval = 0
    /// Nil when distance tracking is off.
    private(set) var liveDistance: LiveDistance?
    /// Where GPS has seen the runner go, for the player's map.
    private(set) var trail = RunTrail()
    /// Where the runner is and which way they're going, for the player's map.
    private(set) var position: LivePosition?
    /// Per-interval results, available shortly after the workout ends.
    private(set) var results: WorkoutResults?
    /// Called once with the results (to save them to history).
    @ObservationIgnored var onResultsReady: ((WorkoutResults) -> Void)?

    /// Workouts ended early shorter than this aren't saved to history.
    private static let minimumSavedTime: TimeInterval = 60
    /// Distance and pace for a work interval are spoken this long into the next
    /// interval, or after the intervals-left prompt if that runs later.
    private static let summaryPromptDelay: TimeInterval = 2.0
    /// Pace over a shorter work interval is too noisy (from GPS) to be worth saying.
    private static let minimumSecondsForPace: TimeInterval = 30

    @ObservationIgnored private let cues: [Cue]
    @ObservationIgnored private let distanceSettings: DistanceSettings?
    @ObservationIgnored private let audio = AudioCueScheduler.shared
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var timeline = RunTimeline()
    @ObservationIgnored private var tracker: DistanceTracker?
    @ObservationIgnored private var lastSegmentIndex: Int?
    @ObservationIgnored private var usesHeartRateMonitor = false

    init(
        name: String,
        plan: WorkoutPlan,
        voice: VoiceOptions = AppSettings.voiceOptions,
        distance: DistanceSettings? = AppSettings.distanceSettings,
        programLink: ProgramLink? = nil,
        route: RoutePath? = nil
    ) {
        self.name = name
        self.plan = plan
        self.programLink = programLink
        self.route = route
        let engine = WorkoutEngine(segments: plan.segments)
        self.engine = engine
        self.status = engine.status(at: .now)
        self.cues = CuePlanner.cues(for: engine.segments, voice: voice)
        self.distanceSettings = distance
        if distance != nil {
            liveDistance = LiveDistance(interval: 0, intervalSeconds: 0, total: 0, source: .none)
        }
        audio.prepareSpeech(for: cues)
    }

    var isPaused: Bool { engine.isPaused }

    /// Whether GPS is tracking this run, so the player can show a live map.
    var usesGPS: Bool { distanceSettings?.mode == .automatic }

    var currentSegment: Segment? {
        status.segmentIndex.map { engine.segments[$0] }
    }

    var nextSegment: Segment? {
        guard let index = status.segmentIndex, index + 1 < engine.segments.count else { return nil }
        return engine.segments[index + 1]
    }

    // MARK: Controls

    func start() {
        guard !engine.hasStarted, !isStopped else { return }
        let now = Date.now
        audio.volume = Float(AppSettings.beepVolume)
        audio.vibrateOnCountdown = AppSettings.vibrateOnCountdown
        audio.activate()
        engine.start(at: now)
        timeline.begin(at: now, elapsed: 0)
        lastSegmentIndex = 0
        HeartRateMonitor.shared.acquire()
        usesHeartRateMonitor = true
        startTracking(at: now)
        syncAudio()
        startTicker()
        refresh()
    }

    func togglePause() {
        guard engine.hasStarted, !isFinished else { return }
        let now = Date.now
        if engine.isPaused {
            engine.resume(at: now)
            timeline.begin(at: now, elapsed: engine.elapsed(at: now))
            syncAudio()
        } else {
            engine.pause(at: now)
            timeline.end(at: now)
            audio.clear()
        }
        tracker?.breakPath()
        refresh()
    }

    func skip() {
        guard engine.hasStarted, !isFinished else { return }
        let now = Date.now
        engine.skip(at: now)
        if !engine.isPaused {
            timeline.begin(at: now, elapsed: engine.elapsed(at: now))
            syncAudio()
        }
        tracker?.breakPath()
        refresh()
    }

    /// Ends the workout early, or cleans up after it finished. Safe to call twice.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        ticker?.invalidate()
        ticker = nil
        guard !isFinished else { return }
        audio.deactivate()
        guard engine.hasStarted, let start = engine.startDate else { return }
        let now = Date.now
        timeline.end(at: now)
        totalTime = now.timeIntervalSince(start)
        if engine.elapsed(at: now) >= Self.minimumSavedTime {
            finishTracking(completed: false, endedAt: now)
        } else {
            tracker?.stop()
            releaseHeartRateMonitor()
        }
    }

    /// Re-reads the clock. Called by the display timer and on returning to the foreground.
    func refresh() {
        let now = Date.now
        status = engine.status(at: now)
        guard engine.hasStarted, !isFinished else { return }
        noteSegmentChange()
        updateLiveDistance(now: now)

        if status.isFinished {
            isFinished = true
            // The exact moment the last interval ended (the clock may be a tick past it).
            let end = engine.date(forElapsed: engine.totalDuration) ?? now
            timeline.end(at: end)
            if let start = engine.startDate {
                totalTime = end.timeIntervalSince(start)
            }
            ticker?.invalidate()
            ticker = nil
            // Let the finish sound play out, then hand full volume back to other apps.
            audio.deactivate(after: CueKind.finish.soundDuration + 0.8)
            finishTracking(completed: true, endedAt: end)
        }
    }

    func handleReturnToForeground() {
        if engine.hasStarted, !isFinished, !isStopped {
            audio.recoverIfNeeded()
        }
        refresh()
    }

    // MARK: Distance

    private func startTracking(at date: Date) {
        guard let distanceSettings else { return }
        let tracker = DistanceTracker(segments: engine.segments, mode: distanceSettings.mode) { [weak self] date in
            guard let self, !self.engine.isPaused else { return nil }
            return self.engine.elapsed(at: date)
        }
        tracker.onChange = { [weak self, weak tracker] in
            guard let self, let tracker else { return }
            if tracker.trail != self.trail { self.trail = tracker.trail }
            if tracker.position != self.position { self.position = tracker.position }
            self.updateLiveDistance(now: .now)
        }
        tracker.start(at: date)
        self.tracker = tracker
    }

    private func activeSeconds(inSegment index: Int, now: Date) -> TimeInterval {
        let start = engine.segmentStarts[index]
        return timeline.activeDuration(for: start..<(start + engine.segments[index].duration), now: now)
    }

    private func updateLiveDistance(now: Date) {
        guard let tracker, let current = status.segmentIndex else { return }
        var total: Double = 0
        var live = LiveDistance(interval: 0, intervalSeconds: 0, total: 0, source: .none)
        for index in 0...current {
            let seconds = activeSeconds(inSegment: index, now: now)
            let (meters, source) = tracker.liveDistance(segment: index, activeSeconds: seconds)
            total += meters
            if index == current {
                live.interval = meters
                live.intervalSeconds = seconds
                live.source = source
            }
        }
        live.total = total
        if live != liveDistance {
            liveDistance = live
        }
    }

    /// When a work interval ends, say how far it was and the pace (after a
    /// moment, so the last GPS fixes of the interval have arrived).
    private func noteSegmentChange() {
        let index = status.segmentIndex
        guard index != lastSegmentIndex else { return }
        let previous = lastSegmentIndex
        lastSegmentIndex = index
        guard let distanceSettings,
              distanceSettings.announceDistance || distanceSettings.announcePace,
              let previous, let index,
              engine.segments[previous].phase == .work,
              !engine.isPaused else { return }
        let promptOffset = engine.segmentStarts[index] + Self.summaryPromptDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.announceSummary(ofSegment: previous, notBefore: promptOffset) }
        }
    }

    private func announceSummary(ofSegment index: Int, notBefore offset: TimeInterval) {
        guard let tracker, let distanceSettings, !isFinished, !isStopped, !engine.isPaused else { return }
        let seconds = activeSeconds(inSegment: index, now: .now)
        let (meters, source) = tracker.liveDistance(segment: index, activeSeconds: seconds)
        guard source != .none else { return }
        let hundredths = distanceSettings.announceDistance ? DistanceFormat.hundredthsOfMile(meters) : nil
        let pace = distanceSettings.announcePace && seconds >= Self.minimumSecondsForPace
            ? DistanceFormat.secondsPerMile(seconds: seconds, meters: meters)
            : nil
        guard hundredths != nil || pace != nil else { return }
        audio.addPrompt(.workSummary(hundredthsOfMile: hundredths, paceSecondsPerMile: pace), notBefore: offset)
    }

    /// Works out the final per-interval results and hands them on for saving.
    private func finishTracking(completed: Bool, endedAt end: Date) {
        tracker?.finish(at: end)
        let tracker = tracker
        let timeline = timeline
        let base = WorkoutResults.intervals(for: engine.segments, timeline: timeline, now: end)
        let startDate = engine.startDate ?? end
        Task { @MainActor in
            var intervals = base
            if let tracker {
                // Let late GPS fixes arrive and the step counter record the last
                // few seconds before totting up.
                try? await Task.sleep(for: .seconds(2))
                tracker.stop()
                intervals = await tracker.fillDistances(base, timeline: timeline, now: end)
            }
            intervals = await HeartRateRecorder.addHeartRate(to: intervals)
            releaseHeartRateMonitor()
            let results = WorkoutResults(
                name: name,
                date: startDate,
                completed: completed,
                totalTime: totalTime,
                intervals: intervals,
                programLink: programLink
            )
            self.results = results
            onResultsReady?(results)
        }
    }

    private func releaseHeartRateMonitor() {
        guard usesHeartRateMonitor else { return }
        usesHeartRateMonitor = false
        HeartRateMonitor.shared.release()
    }

    // MARK: Audio and display

    /// Re-queues all upcoming sounds from the current position.
    private func syncAudio() {
        audio.schedule(cues, from: engine.elapsed(at: .now))
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
}
