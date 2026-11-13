import AVFoundation
import os

/// Gets short phrases ready as audio ahead of time.
///
/// Instead of speaking live, each phrase becomes an audio buffer, so
/// `AudioCueScheduler` can queue spoken prompts on the audio clock exactly like
/// beeps: on time, with the screen locked, and inside the same music-ducking
/// windows. Phrases use the chosen coach's recorded clips (`VoiceClips`) when the
/// app has every clip they need, and are otherwise rendered with the system
/// voice via `AVSpeechSynthesizer.write`.
@MainActor
final class SpeechRenderer {
    /// Called after each phrase finishes rendering.
    var onRendered: (() -> Void)?

    /// Who speaks. Changing it drops everything prepared in the old voice.
    var coachVoice: CoachVoice {
        didSet {
            guard coachVoice != oldValue else { return }
            clips = VoiceClipLibrary(format: format, voice: coachVoice, bundle: clipBundle)
            cache = [:]
            failed = []
            queue = []
            if current != nil {
                synthesizer.stopSpeaking(at: .immediate)
                watchdog?.cancel()
                watchdog = nil
                current = nil
            }
        }
    }

    private static let timeout: TimeInterval = 5

    private let format: AVAudioFormat
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let clipBundle: Bundle
    private var clips: VoiceClipLibrary
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var failed: Set<String> = []
    private var queue: [String] = []
    private var current: (text: String, collector: ChunkCollector)?
    private var watchdog: DispatchWorkItem?
    private let log = Logger(subsystem: "IntervalRun", category: "Speech")

    /// - Parameters:
    ///   - format: the format buffers are converted to (the player's format).
    ///   - coachVoice: who speaks.
    ///   - clipBundle: where the recorded voice clips are.
    init(format: AVAudioFormat, coachVoice: CoachVoice, clipBundle: Bundle = .main) {
        self.format = format
        self.coachVoice = coachVoice
        self.clipBundle = clipBundle
        voice = Self.preferredVoice()
        clips = VoiceClipLibrary(format: format, voice: coachVoice, bundle: clipBundle)
    }

    /// The rendered phrase, or nil if it isn't ready (or couldn't be rendered).
    func buffer(for text: String) -> AVAudioPCMBuffer? {
        cache[text]
    }

    func hasFailed(_ text: String) -> Bool {
        failed.contains(text)
    }

    func duration(of text: String) -> TimeInterval? {
        cache[text].map { Double($0.frameLength) / $0.format.sampleRate }
    }

    /// Gets prompts ready, in the order given: recorded clips straight away, the
    /// rest queued for the system voice. Already prepared or queued prompts are skipped.
    func prepare(_ announcements: [Announcement]) {
        var recorded = false
        for announcement in announcements {
            let text = announcement.text
            guard cache[text] == nil, !failed.contains(text), current?.text != text, !queue.contains(text) else { continue }
            if let buffer = clips.buffer(for: announcement) {
                cache[text] = buffer
                recorded = true
            } else {
                queue.append(text)
            }
        }
        if recorded {
            // Report asynchronously, as the system voice does.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onRendered?() }
            }
        }
        renderNext()
    }

    private func renderNext() {
        guard current == nil, !queue.isEmpty else { return }
        let text = queue.removeFirst()
        let collector = ChunkCollector()
        current = (text, collector)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        // If the synthesizer never signals the end, use whatever arrived.
        let watchdog = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(collector, chunks: collector.take()) }
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)

        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                // A zero-length buffer marks the end of the utterance.
                let chunks = collector.take()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finish(collector, chunks: chunks) }
                }
            } else if let copy = AudioBufferTools.concatenate([pcm]) {
                collector.append(copy)
            }
        }
    }

    private func finish(_ collector: ChunkCollector, chunks: [AVAudioPCMBuffer]) {
        // Ignore a render that already finished, timed out, or was dropped by a voice change.
        guard let text = current?.text, current?.collector === collector else { return }
        watchdog?.cancel()
        watchdog = nil
        current = nil

        if let joined = AudioBufferTools.concatenate(chunks),
           let converted = AudioBufferTools.convert(joined, to: format),
           let cleaned = AudioBufferTools.trimmedAndNormalized(converted) {
            cache[text] = cleaned
        } else {
            failed.insert(text)
            log.error("Couldn't render speech for \"\(text)\"")
        }
        onRendered?()
        renderNext()
    }

    /// The best installed voice for the phone's English variant (US English
    /// otherwise), skipping novelty and Personal Voice voices.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let current = AVSpeechSynthesisVoice.currentLanguageCode()
        let language = current.hasPrefix("en") ? current : "en-US"
        let upgraded = AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language == language
                    && $0.quality != .default
                    && !$0.voiceTraits.contains(.isNoveltyVoice)
                    && !$0.voiceTraits.contains(.isPersonalVoice)
            }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        return upgraded ?? AVSpeechSynthesisVoice(language: language)
    }
}

/// Collects buffers delivered on the synthesizer's thread.
private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [AVAudioPCMBuffer] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        chunks.append(buffer)
        lock.unlock()
    }

    func take() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        let taken = chunks
        chunks = []
        return taken
    }
}

enum AudioBufferTools {
    /// Joins buffers of the same format into one new buffer (also used to copy one).
    static func concatenate(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let format = buffers.first?.format else { return nil }
        let total = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard total > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        var frameOffset = 0
        for buffer in buffers {
            guard buffer.format == format else { return nil }
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for (channel, sourceChannel) in source.enumerated() where channel < destination.count {
                guard let from = sourceChannel.mData, let to = destination[channel].mData else { continue }
                memcpy(to + frameOffset * bytesPerFrame, from, Int(buffer.frameLength) * bytesPerFrame)
            }
            frameOffset += Int(buffer.frameLength)
        }
        output.frameLength = total
        return output
    }

    /// Converts sample rate, sample type and channel count.
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        converter.downmix = true
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Cuts leading and trailing silence (so a prompt starts right on time)
    /// and scales the peak to a level that matches the beeps. Mono float only.
    static func trimmedAndNormalized(_ buffer: AVAudioPCMBuffer, threshold: Float = 0.01) -> AVAudioPCMBuffer? {
        trimmed(buffer, threshold: threshold).flatMap(normalized)
    }

    /// Cuts leading and trailing silence, keeping a few milliseconds either side. Mono float only.
    static func trimmed(_ buffer: AVAudioPCMBuffer, threshold: Float = 0.01) -> AVAudioPCMBuffer? {
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard let first = (0..<count).first(where: { abs(samples[$0]) > threshold }),
              let last = (0..<count).last(where: { abs(samples[$0]) > threshold }) else { return nil }
        let rate = buffer.format.sampleRate
        let start = max(0, first - Int(0.005 * rate))
        let end = min(count, last + Int(0.03 * rate))
        let length = end - start
        guard length > 0,
              let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(length)),
              let destination = output.floatChannelData?[0] else { return nil }
        for i in 0..<length { destination[i] = samples[start + i] }
        output.frameLength = AVAudioFrameCount(length)
        return output
    }

    /// `length` frames from `start`, or fewer at the end of the buffer. Mono float only.
    static func slice(_ buffer: AVAudioPCMBuffer, from start: Int, length: Int) -> AVAudioPCMBuffer? {
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        let start = max(0, start)
        let length = min(length, Int(buffer.frameLength) - start)
        guard length > 0,
              let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(length)),
              let destination = output.floatChannelData?[0] else { return nil }
        for i in 0..<length { destination[i] = samples[start + i] }
        output.frameLength = AVAudioFrameCount(length)
        return output
    }

    /// Scales the peak to a level that matches the beeps. Mono float only.
    static func normalized(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0,
              let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let destination = output.floatChannelData?[0] else { return nil }
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(samples[i])) }
        let gain: Float = peak > 0 ? 0.9 / peak : 1
        for i in 0..<count { destination[i] = samples[i] * gain }
        output.frameLength = AVAudioFrameCount(count)
        return output
    }

    /// Silence of the given length.
    static func silence(_ seconds: TimeInterval, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount((seconds * format.sampleRate).rounded())
        guard frames > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        output.frameLength = frames
        let channels = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for channel in channels {
            if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
        }
        return output
    }
}
