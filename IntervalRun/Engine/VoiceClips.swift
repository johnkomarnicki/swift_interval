import AVFoundation
import os

/// Who speaks the voice prompts, chosen in Settings.
enum CoachVoice: String, CaseIterable, Identifiable {
    /// Recorded with ElevenLabs.
    case allison, brad
    /// The phone's built-in voice.
    case system

    static let `default` = CoachVoice.allison

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allison: "Allison"
        case .brad: "Brad"
        case .system: "iPhone voice"
        }
    }

    var isRecorded: Bool { self != .system }
}

/// The coaches' recorded voices: short clips in `IntervalRun/Voice/<voice>/`,
/// made with ElevenLabs by `scripts/voice/generate_voice.py`, that are joined
/// into spoken prompts. "That was 0.21 miles. 8 minutes 15 per mile." is
/// that-was, whole-0, point-21, miles, a pause, min-8, sec-15.
///
/// The countdown is the exception: "Three… Two… One…" is one take, with the
/// numbers exactly a second apart, that's cut into its three numbers. Played
/// one per second they join back up into the take, so the count sounds like
/// one smooth delivery rather than three separate words.
///
/// A prompt that needs a clip the app doesn't have (a number past the ranges
/// below, or no clips recorded yet) is spoken by the system voice instead.
enum VoiceClips {
    /// One step of a prompt.
    enum Part: Equatable {
        case clip(String)
        /// One number of the countdown take.
        case countdownNumber(Int)
        case pause(TimeInterval)
    }

    static let fileExtension = "m4a"

    /// "voice-allison-halfway". Xcode copies every voice's clips into the app's
    /// top folder, so the name includes the voice.
    static func fileName(_ clip: String, voice: CoachVoice) -> String {
        "voice-\(voice.rawValue)-\(clip)"
    }

    /// Ranges the clips cover. Keep in sync with `scripts/voice/generate_voice.py`.
    static let intervalsLeftRange = 1...99
    static let wholeMilesRange = 0...20
    static let paceMinutesRange = 1...30

    /// The countdown take: "Three… Two… One…", each number starting exactly one
    /// second after the last.
    static let countdownClip = "countdown"
    static let countdownRange = 1...CuePlanner.countdownSeconds
    /// How much of the take each number plays: its word and natural tail, ending
    /// in the silence before the next number. Under a second, so the numbers
    /// don't count as overlapping speech.
    static let countdownNumberLength: TimeInterval = 0.85
    /// Each number starts this long before its word, so a soft first sound
    /// (the "th" of "three") is kept. The script keeps at most 0.08 s of it.
    static let countdownLeadIn: TimeInterval = 0.09
    /// Where a word starts in the leveled take: 4% of its peak, the level the
    /// recording script lines the numbers up by.
    static let countdownOnsetLevel: Float = 0.04 * 0.9

    static let sentencePause: TimeInterval = 0.22
    static let commaPause: TimeInterval = 0.1

    /// "0.21 miles": whole-0, point-21, miles. "1 mile": whole-1, mile.
    static func distance(hundredths: Int) -> [Part]? {
        let whole = max(0, hundredths) / 100
        let fraction = max(0, hundredths) % 100
        guard wholeMilesRange.contains(whole) else { return nil }
        if fraction == 0 {
            return [.clip("whole-\(whole)"), .clip(whole == 1 ? "mile" : "miles")]
        }
        // Trailing zeros are dropped, as in the spoken text: 0.20 is "point two".
        let digits = fraction % 10 == 0 ? "\(fraction / 10)" : String(format: "%02d", fraction)
        return [.clip("whole-\(whole)"), .clip("point-\(digits)"), .clip("miles")]
    }

    /// "8 minutes 15 per mile": min-8, sec-15. "8 minutes per mile": min-8, per-mile.
    static func pace(secondsPerMile: Int) -> [Part]? {
        let minutes = secondsPerMile / 60
        let seconds = secondsPerMile % 60
        guard paceMinutesRange.contains(minutes) else { return nil }
        return [.clip("min-\(minutes)"), .clip(seconds == 0 ? "per-mile" : "sec-\(seconds)")]
    }

    fileprivate static func clip(for phase: Phase) -> String {
        switch phase {
        case .work: "phase-work"
        case .rest: "phase-rest"
        case .warmUp: "phase-warm-up"
        case .coolDown: "cool-down"
        }
    }
}

extension Announcement {
    /// The clips that say this prompt, or nil if a number is outside what the clips cover.
    var clipScript: [VoiceClips.Part]? {
        switch self {
        case .count(let number):
            return VoiceClips.countdownRange.contains(number) ? [.countdownNumber(number)] : nil
        case .halfway:
            return [.clip("halfway")]
        case .intervalsLeft(let phase, let remaining):
            guard VoiceClips.intervalsLeftRange.contains(remaining) else { return nil }
            return [.clip(VoiceClips.clip(for: phase)), .pause(VoiceClips.sentencePause), .clip("left-\(remaining)")]
        case .phase(let phase):
            switch phase {
            case .work: return [.clip("work")]
            case .rest: return [.clip("rest")]
            case .coolDown: return [.clip("cool-down")]
            case .warmUp: return nil // never said on its own
            }
        case .coolDown:
            return [.clip("cool-down")]
        case .workSummary(let hundredths, let pace):
            var parts: [VoiceClips.Part] = []
            if let hundredths {
                guard let distance = VoiceClips.distance(hundredths: hundredths) else { return nil }
                parts = [.clip("that-was")] + distance
            }
            if let pace {
                guard let spokenPace = VoiceClips.pace(secondsPerMile: pace) else { return nil }
                parts += parts.isEmpty
                    ? [.clip("pace"), .pause(VoiceClips.commaPause)]
                    : [.pause(VoiceClips.sentencePause)]
                parts += spokenPace
            }
            return parts.isEmpty ? nil : parts
        }
    }
}

/// Loads one voice's clips from the app bundle and joins them into prompts.
@MainActor
final class VoiceClipLibrary {
    private let format: AVAudioFormat
    private let voice: CoachVoice
    private let bundle: Bundle
    private var clips: [String: AVAudioPCMBuffer] = [:]
    private var missing: Set<String> = []
    private let log = Logger(subsystem: "IntervalRun", category: "Speech")

    /// - Parameter format: the format buffers are converted to (the player's format).
    init(format: AVAudioFormat, voice: CoachVoice, bundle: Bundle = .main) {
        self.format = format
        self.voice = voice
        self.bundle = bundle
    }

    /// The prompt in the recorded voice, or nil if any of its clips is missing
    /// (always nil for the system voice).
    func buffer(for announcement: Announcement) -> AVAudioPCMBuffer? {
        guard voice.isRecorded, let script = announcement.clipScript else { return nil }
        var pieces: [AVAudioPCMBuffer] = []
        for part in script {
            switch part {
            case .clip(let name):
                guard let clip = clip(named: name) else { return nil }
                pieces.append(clip)
            case .countdownNumber(let number):
                guard let clip = countdownNumber(number) else { return nil }
                pieces.append(clip)
            case .pause(let seconds):
                guard let silence = AudioBufferTools.silence(seconds, format: format) else { return nil }
                pieces.append(silence)
            }
        }
        return AudioBufferTools.concatenate(pieces)
    }

    /// A clip with its silence trimmed and its level evened out, so clips
    /// recorded separately sit together without gaps or jumps in volume.
    private func clip(named name: String) -> AVAudioPCMBuffer? {
        if let cached = clips[name] { return cached }
        guard let loaded = load(name),
              let trimmed = AudioBufferTools.trimmed(loaded),
              let leveled = AudioBufferTools.normalized(trimmed) else {
            return nil
        }
        clips[name] = leveled
        return leveled
    }

    /// One number of the countdown, cut from the countdown take. The take is
    /// leveled as a whole, and nothing is trimmed, so the three numbers played a
    /// second apart sound exactly like the take.
    private func countdownNumber(_ number: Int) -> AVAudioPCMBuffer? {
        let key = "\(VoiceClips.countdownClip)-\(number)"
        if let cached = clips[key] { return cached }
        guard VoiceClips.countdownRange.contains(number),
              let take = load(VoiceClips.countdownClip).flatMap(AudioBufferTools.normalized),
              let samples = take.floatChannelData?[0],
              // Where "Three" starts; the others follow at one-second steps.
              let onset = (0..<Int(take.frameLength)).first(where: { abs(samples[$0]) >= VoiceClips.countdownOnsetLevel }) else {
            return nil
        }
        let rate = take.format.sampleRate
        let secondsIn = Double(VoiceClips.countdownRange.upperBound - number) // Three: 0, Two: 1, One: 2
        let start = onset + Int(((secondsIn - VoiceClips.countdownLeadIn) * rate).rounded())
        guard let piece = AudioBufferTools.slice(take, from: start, length: Int(VoiceClips.countdownNumberLength * rate)) else {
            return nil
        }
        clips[key] = piece
        return piece
    }

    /// A clip as recorded, in the player's format, or nil if the app doesn't have it.
    private func load(_ name: String) -> AVAudioPCMBuffer? {
        guard !missing.contains(name) else { return nil }
        guard let url = bundle.url(forResource: VoiceClips.fileName(name, voice: voice), withExtension: VoiceClips.fileExtension) else {
            missing.insert(name)
            return nil
        }
        do {
            let file = try AVAudioFile(forReading: url)
            guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try file.read(into: raw)
            guard let converted = AudioBufferTools.convert(raw, to: format) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return converted
        } catch {
            log.error("Couldn't load voice clip \(self.voice.rawValue) \(name): \(error.localizedDescription)")
            missing.insert(name)
            return nil
        }
    }
}
