import AVFoundation
import AudioToolbox
import os

/// Owns the audio session and plays workout cues at exact times.
///
/// How it stays on time and works in the background:
/// - Tones are generated sine-wave buffers and spoken prompts are pre-rendered
///   voice buffers (`SpeechRenderer`). Both are queued on player nodes at precise
///   sample positions, so the audio hardware plays them on schedule even if the
///   main thread is busy. No timer counts seconds.
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

    /// Cue loudness relative to the system volume (0...1).
    var volume: Float = Float(AppSettings.defaultBeepVolume) {
        didSet {
            tonePlayer.volume = volume
            voicePlayer.volume = volume
            promptPlayer.volume = volume
        }
    }
    var vibrateOnCountdown = false

    /// How far ahead the players are started when sounds are (re)queued.
    nonisolated private static let startLatency: TimeInterval = 0.03
    /// A cue due up to this long ago still plays (e.g. the tone right after Skip).
    nonisolated private static let lateTolerance: TimeInterval = 0.1

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let tonePlayer = AVAudioPlayerNode()
    private let voicePlayer = AVAudioPlayerNode()
    /// Plays prompts added mid-workout (`addPrompt`) without restarting the
    /// other players, which would cut off sounds already playing.
    private let promptPlayer = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var toneBuffers: [CueKind: AVAudioPCMBuffer] = [:]
    private let speech: SpeechRenderer
    private let log = Logger(subsystem: "IntervalRun", category: "Audio")

    private var isActive = false
    private var isDucking = false
    /// Everything most recently passed to `schedule`, kept so the queue can be
    /// rebuilt when more voice prompts finish rendering. Empty while paused.
    private var scheduledCues: [Cue] = []
    /// Cues still to play as they will actually sound, in workout-elapsed time.
    private var upcoming: [Cue] = []
    private var duckWindows: [ClosedRange<TimeInterval>] = []
    /// Workout time `anchorElapsed` happens at host clock tick `anchorHostTime`.
    private var anchorHostTime: UInt64 = 0
    private var anchorElapsed: TimeInterval = 0
    /// Host-clock seconds pinned to sample 0 of the players' timelines.
    private var playersStartSeconds: TimeInterval = 0
    /// Mid-workout prompts waiting for their speech to render.
    private var pendingPrompts: [Cue] = []
    /// Duck/unduck and vibration callbacks waiting to fire.
    private var timers: [DispatchWorkItem] = []
    private var pendingDeactivation: DispatchWorkItem?
    private var pendingSpeechRefresh: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        speech = SpeechRenderer(format: format, coachVoice: AppSettings.coachVoice)
        engine.attach(tonePlayer)
        engine.attach(voicePlayer)
        engine.attach(promptPlayer)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: format)
        engine.connect(voicePlayer, to: engine.mainMixerNode, format: format)
        engine.connect(promptPlayer, to: engine.mainMixerNode, format: format)
        tonePlayer.volume = volume
        voicePlayer.volume = volume
        promptPlayer.volume = volume
        for kind in CueKind.tones {
            toneBuffers[kind] = ToneGenerator.buffer(for: kind, format: format)
        }
        speech.onRendered = { [weak self] in self?.speechDidRender() }
        observeSystemEvents()
    }

    // MARK: - Public API

    /// Starts rendering the voice prompts in `cues`, in the coach voice chosen in
    /// Settings, so they're ready when needed. Safe to call repeatedly; already
    /// rendered phrases are skipped.
    func prepareSpeech(for cues: [Cue]) {
        speech.coachVoice = AppSettings.coachVoice
        speech.prepare(CuePlanner.phrases(in: cues))
    }

    /// Adds a spoken prompt whose words are only known during the workout (the
    /// distance of the interval just finished). It's rendered on the fly, then
    /// slotted in at `offset` or just after any speech already queued there.
    /// It's dropped if it would crowd the countdown, or if the workout is paused.
    func addPrompt(_ announcement: Announcement, notBefore offset: TimeInterval) {
        guard isActive, !scheduledCues.isEmpty else { return }
        pendingPrompts.append(Cue(offset: offset, kind: .speech(announcement)))
        speech.prepare([announcement])
        insertReadyPrompts()
    }

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
        schedule(cues, from: elapsed, lateTolerance: Self.lateTolerance)
    }

    /// Silences everything queued (e.g. on pause). The session stays active so the
    /// app keeps running in the background.
    func clear() {
        cancelTimers()
        scheduledCues = []
        pendingPrompts = []
        upcoming = []
        duckWindows = []
        stopPlayers()
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

    /// The cues `playTestSound` plays: "two, one" (spoken or beeped), then the switch tone.
    static func testCues(voiceCountdown: Bool) -> [Cue] {
        [
            Cue(offset: 0.15, kind: voiceCountdown ? .speech(.count(2)) : .countdown),
            Cue(offset: 1.15, kind: voiceCountdown ? .speech(.count(1)) : .countdown),
            Cue(offset: 2.15, kind: .transition),
        ]
    }

    /// Plays a short sample for the Settings screen.
    func playTestSound(voiceCountdown: Bool) {
        let cues = Self.testCues(voiceCountdown: voiceCountdown)
        prepareSpeech(for: cues)
        activate()
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
            queueSounds(lateTolerance: 0)
        } catch {
            log.error("Recovering audio failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Scheduling

    private func schedule(_ cues: [Cue], from elapsed: TimeInterval, lateTolerance: TimeInterval) {
        guard isActive else { return }
        cancelTimers()
        scheduledCues = cues
        anchorHostTime = mach_absolute_time()
        anchorElapsed = elapsed
        upcoming = playable(cues.filter { $0.offset >= elapsed - lateTolerance })
        duckWindows = CuePlanner.duckWindows(for: upcoming, duration: soundDuration(of:))

        let duckNow = duckWindows.contains { $0.contains(elapsed) }
        if duckNow != isDucking {
            setDucking(duckNow) // re-queues sounds after cycling the session
        } else {
            queueSounds(lateTolerance: lateTolerance)
        }
        scheduleTimers(from: elapsed)
    }

    /// Cues as they will actually sound: a spoken number that isn't rendered yet
    /// falls back to a beep, other unrendered speech is skipped, and speech that
    /// would overlap is thinned out by priority.
    private func playable(_ cues: [Cue]) -> [Cue] {
        let available = cues.compactMap { cue -> Cue? in
            guard let announcement = cue.kind.announcement else { return cue }
            if speech.buffer(for: announcement.text) != nil { return cue }
            if case .count = announcement { return Cue(offset: cue.offset, kind: .countdown) }
            return nil
        }
        return CuePlanner.resolvingSpeechOverlaps(available, duration: soundDuration(of:))
    }

    private func soundDuration(of kind: CueKind) -> TimeInterval {
        if let announcement = kind.announcement, let duration = speech.duration(of: announcement.text) {
            return duration
        }
        return kind.soundDuration
    }

    /// Workout-elapsed time right now, according to the current anchor.
    private func currentElapsed() -> TimeInterval {
        anchorElapsed + AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: anchorHostTime)
    }

    private func speechDidRender() {
        insertReadyPrompts()
        scheduleSpeechRefresh()
    }

    /// More voice prompts are ready: rebuild the queue so they replace their
    /// fallbacks. Waits until no sounds are playing so nothing gets cut off, and
    /// coalesces bursts of renders into one rebuild.
    private func scheduleSpeechRefresh() {
        guard isActive, !scheduledCues.isEmpty, pendingSpeechRefresh == nil else { return }
        let now = currentElapsed()
        let delay = max(0.5, (duckWindows.first { $0.contains(now) }?.upperBound ?? now) - now + 0.05)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSpeechRefresh = nil
                guard self.isActive, !self.scheduledCues.isEmpty else { return }
                let now = self.currentElapsed()
                if self.duckWindows.contains(where: { $0.contains(now) }) {
                    self.scheduleSpeechRefresh() // sounds started meanwhile; try after them
                } else {
                    self.schedule(self.scheduledCues, from: now, lateTolerance: 0)
                }
            }
        }
        pendingSpeechRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Mid-workout prompts

    private func insertReadyPrompts() {
        guard !pendingPrompts.isEmpty else { return }
        guard isActive, !scheduledCues.isEmpty else {
            pendingPrompts = []
            return
        }
        var waiting: [Cue] = []
        for prompt in pendingPrompts {
            guard let text = prompt.kind.announcement?.text else { continue }
            if speech.buffer(for: text) != nil {
                insert(prompt)
            } else if !speech.hasFailed(text) {
                waiting.append(prompt)
            }
        }
        pendingPrompts = waiting
    }

    /// Slots a rendered prompt into the live queue on `promptPlayer`, which shares
    /// the other players' timeline, so nothing already queued is restarted.
    private func insert(_ prompt: Cue) {
        guard let announcement = prompt.kind.announcement,
              let buffer = speech.buffer(for: announcement.text) else { return }
        let now = currentElapsed()
        let duration = soundDuration(of: prompt.kind)
        let gap = 0.25

        // Start at the requested time, or after any speech already there.
        var offset = max(prompt.offset, now + 0.15)
        for cue in upcoming.sorted(by: { $0.offset < $1.offset }) where cue.kind.announcement != nil {
            let cueEnd = cue.offset + soundDuration(of: cue.kind) + gap
            if cue.offset < offset + duration + gap, cueEnd > offset {
                offset = cueEnd
            }
        }
        let cue = Cue(offset: offset, kind: prompt.kind)
        let candidate = (upcoming + [cue]).sorted { $0.offset < $1.offset }
        // Give up rather than talk over (or knock out) anything already queued.
        guard CuePlanner.resolvingSpeechOverlaps(candidate, duration: soundDuration(of:)).count == candidate.count else {
            return
        }

        scheduledCues = (scheduledCues + [cue]).sorted { $0.offset < $1.offset }
        upcoming = candidate
        let rate = format.sampleRate
        let delta = hostSeconds(forElapsed: offset) - playersStartSeconds
        guard delta > 0 else { return }
        promptPlayer.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: AVAudioFramePosition((delta * rate).rounded()), atRate: rate), options: [])

        // Make sure music is ducked while it plays.
        duckWindows = CuePlanner.duckWindows(for: upcoming, duration: soundDuration(of:))
        cancelCueTimers()
        if duckWindows.contains(where: { $0.contains(now) }), !isDucking {
            setDucking(true)
        }
        scheduleTimers(from: now)
    }

    // MARK: - Engine and queue

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    private func stopPlayers() {
        tonePlayer.stop()
        voicePlayer.stop()
        promptPlayer.stop()
    }

    /// Queues every remaining cue on its player at its exact sample position.
    private func queueSounds(lateTolerance: TimeInterval = AudioCueScheduler.lateTolerance) {
        stopPlayers()
        guard isActive, engine.isRunning, !upcoming.isEmpty else { return }

        let rate = format.sampleRate
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.startLatency)
        let startSeconds = AVAudioTime.seconds(forHostTime: startHost)
        playersStartSeconds = startSeconds

        for cue in upcoming {
            let player: AVAudioPlayerNode
            let buffer: AVAudioPCMBuffer?
            if let announcement = cue.kind.announcement {
                player = voicePlayer
                buffer = speech.buffer(for: announcement.text)
            } else {
                player = tonePlayer
                buffer = toneBuffers[cue.kind]
            }
            guard let buffer else { continue }
            let delta = hostSeconds(forElapsed: cue.offset) - startSeconds
            if delta < -lateTolerance - Self.startLatency { continue } // already played
            let frame = AVAudioFramePosition((max(0, delta) * rate).rounded())
            player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: frame, atRate: rate), options: [])
        }
        // Sample 0 of all players' timelines is pinned to `startHost`.
        let start = AVAudioTime(hostTime: startHost)
        tonePlayer.play(at: start)
        voicePlayer.play(at: start)
        promptPlayer.play(at: start)
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
        stopPlayers()
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
            for cue in upcoming where cue.kind.isCountdown && cue.offset >= elapsed {
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

    /// Cancels the duck/unduck and vibration timers.
    private func cancelCueTimers() {
        timers.forEach { $0.cancel() }
        timers = []
    }

    private func cancelTimers() {
        cancelCueTimers()
        pendingSpeechRefresh?.cancel()
        pendingSpeechRefresh = nil
    }

    private func deactivateNow() {
        pendingDeactivation = nil
        cancelTimers()
        scheduledCues = []
        pendingPrompts = []
        upcoming = []
        duckWindows = []
        stopPlayers()
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

/// Builds the tone cues as sine-wave buffers, so no audio files are needed.
enum ToneGenerator {
    static func buffer(for kind: CueKind, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !kind.notes.isEmpty else { return nil }
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
