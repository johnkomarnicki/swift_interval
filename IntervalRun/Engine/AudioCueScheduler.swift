import AVFoundation
import AudioToolbox
import os

/// Owns the audio session and plays workout cues at exact times.
///
/// How it stays on time and works in the background:
/// - Sounds are generated sine-wave buffers queued on an `AVAudioPlayerNode` at
///   precise sample positions, so the audio hardware plays them on schedule even
///   if the main thread is busy. No timer counts seconds.
/// - Workout time is tied to the host clock (`mach_absolute_time`) through an
///   anchor taken whenever the schedule changes (start, resume, skip).
/// - The engine keeps running for the whole workout. With the "audio" background
///   mode, a running engine is what keeps iOS from suspending the app when locked.
/// - `.playback` plays even with the silent switch on; `.mixWithOthers` keeps
///   other apps' music playing. Music is only ducked in short windows around each
///   group of sounds (see `setDucking`).
@MainActor
final class AudioCueScheduler {
    static let shared = AudioCueScheduler()

    /// Beep loudness relative to the system volume (0...1).
    var volume: Float = Float(AppSettings.defaultBeepVolume) {
        didSet { player.volume = volume }
    }
    var vibrateOnCountdown = false

    /// How far ahead the player is started when sounds are (re)queued.
    private static let startLatency: TimeInterval = 0.03
    /// A cue due up to this long ago still plays (e.g. the tone right after Skip).
    private static let lateTolerance: TimeInterval = 0.1

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var buffers: [CueKind: AVAudioPCMBuffer] = [:]
    private let log = Logger(subsystem: "IntervalRun", category: "Audio")

    private var isActive = false
    private var isDucking = false
    /// Cues still to play, in workout-elapsed time.
    private var upcoming: [Cue] = []
    private var duckWindows: [ClosedRange<TimeInterval>] = []
    /// Workout time `anchorElapsed` happens at host clock tick `anchorHostTime`.
    private var anchorHostTime: UInt64 = 0
    private var anchorElapsed: TimeInterval = 0
    /// Duck/unduck and vibration callbacks waiting to fire.
    private var timers: [DispatchWorkItem] = []
    private var pendingDeactivation: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.volume = volume
        for kind in CueKind.allCases {
            buffers[kind] = ToneGenerator.buffer(for: kind, format: format)
        }
        observeSystemEvents()
    }

    // MARK: - Public API

    /// Activates the audio session (mixing with other apps) and starts the engine.
    /// Call when a workout starts.
    func activate() {
        pendingDeactivation?.cancel()
        pendingDeactivation = nil
        guard !isActive else { return }
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            isActive = true
            isDucking = false
            try startEngine()
        } catch {
            log.error("Activating audio failed: \(error.localizedDescription)")
        }
    }

    /// Replaces everything queued with `cues`, treating workout time `elapsed` as now.
    /// Call on start, resume and skip.
    func schedule(_ cues: [Cue], from elapsed: TimeInterval) {
        guard isActive else { return }
        cancelTimers()
        anchorHostTime = mach_absolute_time()
        anchorElapsed = elapsed
        upcoming = cues.filter { $0.offset >= elapsed - Self.lateTolerance }
        duckWindows = CuePlanner.duckWindows(for: upcoming)

        let duckNow = duckWindows.contains { $0.contains(elapsed) }
        if duckNow != isDucking {
            setDucking(duckNow) // re-queues sounds after cycling the session
        } else {
            queueSounds()
        }
        scheduleTimers(from: elapsed)
    }

    /// Silences everything queued (e.g. on pause). The session stays active so the
    /// app keeps running in the background.
    func clear() {
        cancelTimers()
        upcoming = []
        duckWindows = []
        player.stop()
        setDucking(false)
    }

    /// Stops all audio and deactivates the session so other apps return to full volume.
    func deactivate(after delay: TimeInterval = 0) {
        pendingDeactivation?.cancel()
        pendingDeactivation = nil
        guard delay > 0 else {
            deactivateNow()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.deactivateNow() }
        }
        pendingDeactivation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Plays "beep, beep, TONE" for the Settings screen.
    func playTestSound() {
        activate()
        let cues = [
            Cue(offset: 0.15, kind: .countdown),
            Cue(offset: 1.15, kind: .countdown),
            Cue(offset: 2.15, kind: .transition),
        ]
        schedule(cues, from: 0)
        deactivate(after: 2.15 + CueKind.transition.soundDuration + 0.5)
    }

    /// Restarts audio if the system stopped it (phone call, route change, app
    /// returning from a suspension).
    func recoverIfNeeded() {
        guard isActive, !engine.isRunning else { return }
        do {
            try session.setActive(true)
            try startEngine()
            queueSounds()
        } catch {
            log.error("Recovering audio failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Engine and queue

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    /// Queues every remaining cue on the player at its exact sample position.
    private func queueSounds() {
        player.stop()
        guard isActive, engine.isRunning, !upcoming.isEmpty else { return }

        let rate = format.sampleRate
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.startLatency)
        let startSeconds = AVAudioTime.seconds(forHostTime: startHost)

        for cue in upcoming {
            guard let buffer = buffers[cue.kind] else { continue }
            let delta = hostSeconds(forElapsed: cue.offset) - startSeconds
            if delta < -Self.lateTolerance { continue } // already played
            let frame = AVAudioFramePosition((max(0, delta) * rate).rounded())
            player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: frame, atRate: rate), options: [])
        }
        // Sample 0 of the player's timeline is pinned to `startHost`.
        player.play(at: AVAudioTime(hostTime: startHost))
    }

    /// Host-clock seconds at which a workout-elapsed time is reached.
    private func hostSeconds(forElapsed offset: TimeInterval) -> TimeInterval {
        AVAudioTime.seconds(forHostTime: anchorHostTime) + (offset - anchorElapsed)
    }

    // MARK: - Ducking

    /// Turns ducking of other apps' audio on or off.
    ///
    /// iOS applies `.duckOthers` when the session is activated and only restores
    /// other audio when the session is deactivated. So each change briefly
    /// deactivates and reactivates the session, then restarts the engine and
    /// re-queues the remaining sounds. This happens ~0.35 s before a group of
    /// sounds and ~0.4 s after it, when nothing of ours is playing.
    private func setDucking(_ duck: Bool) {
        guard isActive, duck != isDucking else { return }
        player.stop()
        engine.stop()
        do {
            try? session.setActive(false, options: duck ? [] : .notifyOthersOnDeactivation)
            let options: AVAudioSession.CategoryOptions = duck ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
            try session.setCategory(.playback, mode: .default, options: options)
            try session.setActive(true)
            isDucking = duck
        } catch {
            log.error("Changing ducking failed: \(error.localizedDescription)")
        }
        do {
            try startEngine()
        } catch {
            log.error("Restarting engine failed: \(error.localizedDescription)")
        }
        queueSounds()
    }

    // MARK: - Timers (ducking and vibration only; sounds are queued on the audio clock)

    private func scheduleTimers(from elapsed: TimeInterval) {
        for window in duckWindows {
            if window.lowerBound > elapsed {
                addTimer(atElapsed: window.lowerBound) { $0.setDucking(true) }
            }
            if window.upperBound > elapsed {
                addTimer(atElapsed: window.upperBound) { $0.setDucking(false) }
            }
        }
        if vibrateOnCountdown {
            for cue in upcoming where cue.kind == .countdown && cue.offset >= elapsed {
                addTimer(atElapsed: cue.offset) { _ in
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                }
            }
        }
    }

    private func addTimer(atElapsed offset: TimeInterval, _ action: @escaping (AudioCueScheduler) -> Void) {
        let delay = hostSeconds(forElapsed: offset) - AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        timers.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers = []
    }

    private func deactivateNow() {
        pendingDeactivation = nil
        cancelTimers()
        upcoming = []
        duckWindows = []
        player.stop()
        engine.stop()
        guard isActive else { return }
        isActive = false
        isDucking = false
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.error("Deactivating audio failed: \(error.localizedDescription)")
        }
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.ended.rawValue else { return }
            MainActor.assumeIsolated { self?.recoverIfNeeded() }
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverIfNeeded() }
        })
    }
}

/// Builds the cue sounds as sine-wave buffers, so no audio files are needed.
enum ToneGenerator {
    static func buffer(for kind: CueKind, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frameCount = AVAudioFrameCount((kind.soundDuration * rate).rounded(.up))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount
        let total = Int(frameCount)
        for i in 0..<total { samples[i] = 0 }

        let attack = Int(0.005 * rate)
        let release = Int(0.03 * rate)
        var cursor = 0
        for note in kind.notes {
            let length = Int(note.duration * rate)
            for i in 0..<length where cursor + i < total {
                // Short fade in/out avoids clicks.
                var envelope = 1.0
                if i < attack {
                    envelope = Double(i) / Double(attack)
                } else if i > length - release {
                    envelope = Double(length - i) / Double(release)
                }
                let phase = 2 * Double.pi * note.frequency * Double(i) / rate
                // A little second harmonic helps the tone cut through music.
                let value = (0.8 * sin(phase) + 0.2 * sin(2 * phase)) * envelope * 0.9
                samples[cursor + i] = Float(value)
            }
            cursor += length + Int(CueKind.noteGap * rate)
        }
        return buffer
    }
}
