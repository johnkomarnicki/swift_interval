import Foundation
import Observation

/// A running workout: wraps `WorkoutEngine` with the real clock, the audio
/// scheduler and a display refresh for the player screen.
///
/// The display timer only redraws; it never advances time. Each refresh reads the
/// clock and asks the engine where the workout is.
@MainActor
@Observable
final class WorkoutSession: Identifiable {
    let id = UUID()
    let name: String
    let plan: WorkoutPlan

    private(set) var engine: WorkoutEngine
    private(set) var status: WorkoutStatus
    private(set) var isFinished = false
    /// Real time from Start to finish, including pauses.
    private(set) var totalTime: TimeInterval = 0

    @ObservationIgnored private let cues: [Cue]
    @ObservationIgnored private let audio = AudioCueScheduler.shared
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var isStopped = false

    init(name: String, plan: WorkoutPlan) {
        self.name = name
        self.plan = plan
        let engine = WorkoutEngine(segments: plan.segments)
        self.engine = engine
        self.status = engine.status(at: .now)
        self.cues = CuePlanner.cues(for: engine.segments)
    }

    var isPaused: Bool { engine.isPaused }

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
        audio.volume = Float(AppSettings.beepVolume)
        audio.vibrateOnCountdown = AppSettings.vibrateOnCountdown
        audio.activate()
        engine.start(at: .now)
        syncAudio()
        startTicker()
        refresh()
    }

    func togglePause() {
        guard engine.hasStarted, !isFinished else { return }
        let now = Date.now
        if engine.isPaused {
            engine.resume(at: now)
            syncAudio()
        } else {
            engine.pause(at: now)
            audio.clear()
        }
        refresh()
    }

    func skip() {
        guard engine.hasStarted, !isFinished else { return }
        engine.skip(at: .now)
        if !engine.isPaused {
            syncAudio()
        }
        refresh()
    }

    /// Ends the workout early, or cleans up after it finished. Safe to call twice.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        ticker?.invalidate()
        ticker = nil
        if !isFinished {
            audio.deactivate()
        }
    }

    /// Re-reads the clock. Called by the display timer and on returning to the foreground.
    func refresh() {
        let now = Date.now
        status = engine.status(at: now)
        if status.isFinished, !isFinished, engine.hasStarted {
            isFinished = true
            if let start = engine.startDate {
                totalTime = now.timeIntervalSince(start)
            }
            ticker?.invalidate()
            ticker = nil
            // Let the finish sound play out, then hand full volume back to other apps.
            audio.deactivate(after: CueKind.finish.soundDuration + 0.8)
        }
    }

    func handleReturnToForeground() {
        if engine.hasStarted, !isFinished, !isStopped {
            audio.recoverIfNeeded()
        }
        refresh()
    }

    // MARK: Private

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
