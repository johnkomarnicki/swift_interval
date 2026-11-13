import AVFoundation
import XCTest
@testable import IntervalRun

final class VoiceClipsTests: XCTestCase {
    private func names(_ announcement: Announcement) -> [String]? {
        announcement.clipScript?.compactMap { part in
            switch part {
            case .clip(let name): name
            case .countdownNumber: VoiceClips.countdownClip
            case .pause: nil
            }
        }
    }

    // MARK: Scripts

    func testFixedPrompts() {
        XCTAssertEqual(Announcement.count(3).clipScript, [.countdownNumber(3)])
        XCTAssertEqual(Announcement.count(1).clipScript, [.countdownNumber(1)])
        XCTAssertEqual(names(.halfway), ["halfway"])
        XCTAssertEqual(names(.coolDown), ["cool-down"])
        XCTAssertEqual(Announcement.intervalsLeft(.work, 5).clipScript,
                       [.clip("phase-work"), .pause(VoiceClips.sentencePause), .clip("left-5")])
        XCTAssertEqual(names(.intervalsLeft(.rest, 1)), ["phase-rest", "left-1"])
        XCTAssertEqual(names(.phase(.work)), ["work"])
        XCTAssertEqual(names(.phase(.rest)), ["rest"])
    }

    func testDistance() {
        XCTAssertEqual(names(.workSummary(hundredthsOfMile: 21, paceSecondsPerMile: nil)), ["that-was", "whole-0", "point-21", "miles"])
        XCTAssertEqual(names(.workSummary(hundredthsOfMile: 20, paceSecondsPerMile: nil)), ["that-was", "whole-0", "point-2", "miles"])
        XCTAssertEqual(names(.workSummary(hundredthsOfMile: 105, paceSecondsPerMile: nil)), ["that-was", "whole-1", "point-05", "miles"])
        XCTAssertEqual(names(.workSummary(hundredthsOfMile: 100, paceSecondsPerMile: nil)), ["that-was", "whole-1", "mile"])
        XCTAssertEqual(names(.workSummary(hundredthsOfMile: 300, paceSecondsPerMile: nil)), ["that-was", "whole-3", "miles"])
    }

    func testPace() {
        XCTAssertEqual(Announcement.workSummary(hundredthsOfMile: 21, paceSecondsPerMile: 495).clipScript, [
            .clip("that-was"), .clip("whole-0"), .clip("point-21"), .clip("miles"),
            .pause(VoiceClips.sentencePause), .clip("min-8"), .clip("sec-15"),
        ])
        XCTAssertEqual(Announcement.workSummary(hundredthsOfMile: nil, paceSecondsPerMile: 480).clipScript,
                       [.clip("pace"), .pause(VoiceClips.commaPause), .clip("min-8"), .clip("per-mile")])
        XCTAssertEqual(names(.workSummary(hundredthsOfMile: nil, paceSecondsPerMile: 61)), ["pace", "min-1", "sec-1"])
    }

    /// Numbers past the recorded clips fall back to the system voice.
    func testOutOfRangeHasNoScript() {
        XCTAssertNil(Announcement.count(4).clipScript)
        XCTAssertNil(Announcement.intervalsLeft(.work, 100).clipScript)
        XCTAssertNil(Announcement.workSummary(hundredthsOfMile: 2100, paceSecondsPerMile: nil).clipScript)
        XCTAssertNil(Announcement.workSummary(hundredthsOfMile: 21, paceSecondsPerMile: 31 * 60).clipScript)
        XCTAssertNil(Announcement.workSummary(hundredthsOfMile: nil, paceSecondsPerMile: 45).clipScript)
        XCTAssertNil(Announcement.workSummary(hundredthsOfMile: nil, paceSecondsPerMile: nil).clipScript)
    }

    private struct Manifest: Decodable {
        struct Clip: Decodable { let name: String }
        let voices: [String: String]
        let clips: [Clip]
    }

    private func manifest() throws -> Manifest {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/voice/manifest.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    /// The script that records the clips and the app must agree on the voices.
    func testEveryRecordedVoiceIsInTheRecordingScript() throws {
        let recorded = CoachVoice.allCases.filter(\.isRecorded).map(\.rawValue)
        XCTAssertEqual(Set(recorded), Set(try manifest().voices.keys))
    }

    /// ... and on the clip names.
    func testEveryClipIsInTheRecordingScript() throws {
        var used = Set<String>()
        func add(_ announcement: Announcement) { used.formUnion(names(announcement) ?? []) }
        VoiceClips.countdownRange.forEach { add(.count($0)) }
        add(.halfway)
        add(.coolDown)
        for phase in [Phase.work, .rest, .warmUp, .coolDown] {
            VoiceClips.intervalsLeftRange.forEach { add(.intervalsLeft(phase, $0)) }
            add(.phase(phase))
        }
        let maxHundredths = VoiceClips.wholeMilesRange.upperBound * 100 + 99
        (0...maxHundredths).forEach { add(.workSummary(hundredthsOfMile: $0, paceSecondsPerMile: nil)) }
        let maxPace = VoiceClips.paceMinutesRange.upperBound * 60 + 59
        (60...maxPace).forEach { add(.workSummary(hundredthsOfMile: nil, paceSecondsPerMile: $0)) }

        let recorded = Set(try manifest().clips.map(\.name))
        XCTAssertEqual(used.subtracting(recorded).sorted(), [], "clips the app uses but the script doesn't record")
        XCTAssertEqual(recorded.subtracting(used).sorted(), [], "clips the script records but the app never uses")
    }

    // MARK: Joining

    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    /// Writes one of Allison's clips: `lead` s of silence, a tone at `level` for `tone` s, then 0.2 s of silence.
    private func writeClip(_ name: String, in directory: URL, lead: Double, tone: Double, level: Float) throws {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount((lead + tone + 0.2) * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            samples[i] = t >= lead && t < lead + tone ? level * Float(sin(2 * .pi * 440 * t)) : 0
        }
        let url = directory.appendingPathComponent(VoiceClips.fileName(name, voice: .allison) + "." + VoiceClips.fileExtension)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        try file.write(from: buffer)
    }

    @MainActor
    func testJoinsTrimmedLeveledClipsWithPauses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeClip("phase-work", in: directory, lead: 0.3, tone: 0.4, level: 0.2)
        try writeClip("left-3", in: directory, lead: 0.1, tone: 0.6, level: 0.8)

        let library = VoiceClipLibrary(format: format, voice: .allison, bundle: try XCTUnwrap(Bundle(url: directory)))
        let buffer = try XCTUnwrap(library.buffer(for: .intervalsLeft(.work, 3)))
        XCTAssertEqual(buffer.format, format)

        // Silence around each clip is cut, so it's about 0.4 + pause + 0.6 s, not 1.8 s.
        let seconds = Double(buffer.frameLength) / format.sampleRate
        XCTAssertEqual(seconds, 0.4 + VoiceClips.sentencePause + 0.6, accuracy: 0.15)

        // Both clips are brought to the same level, whatever they were recorded at.
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let pauseStart = Int(0.45 * format.sampleRate)
        let firstPeak = (0..<pauseStart).map { abs(samples[$0]) }.max() ?? 0
        let secondPeak = (pauseStart..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
        XCTAssertEqual(firstPeak, 0.9, accuracy: 0.05)
        XCTAssertEqual(secondPeak, 0.9, accuracy: 0.05)
    }

    /// Checks the clips recorded with ElevenLabs, for each voice that has some in the app.
    @MainActor
    func testRecordedCountdownFitsOnePerSecond() throws {
        var checked = 0
        for voice in CoachVoice.allCases where voice.isRecorded {
            let library = VoiceClipLibrary(format: format, voice: voice)
            let counts = VoiceClips.countdownRange.compactMap { library.buffer(for: .count($0)) }
            guard !counts.isEmpty else { continue }
            checked += 1
            XCTAssertEqual(counts.count, 3, "\(voice.title)'s countdown take is too short")
            for buffer in counts {
                XCTAssertLessThan(Double(buffer.frameLength) / format.sampleRate, 0.9,
                                  "\(voice.title): each number must finish before the next second")
                // A number's sound is all inside its piece: quiet where it's cut.
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                let edge = Int(0.02 * format.sampleRate)
                let ends = Array(0..<edge) + Array((Int(buffer.frameLength) - edge)..<Int(buffer.frameLength))
                XCTAssertLessThan(ends.map { abs(samples[$0]) }.max() ?? 0, 0.02,
                                  "\(voice.title): a countdown number is cut off mid-sound")
            }
        }
        if checked == 0 { throw XCTSkip("No voice clips recorded yet") }
    }

    /// The countdown is one take: "Three" at `lead`, then one number a second.
    @MainActor
    func testCountdownIsCutFromOneTakeAtOneSecondSteps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Three words of different loudness, as said in one take.
        let rate = format.sampleRate
        let lead = 0.2
        let levels: [Float] = [0.3, 0.6, 0.45]
        let frames = AVAudioFrameCount((lead + 3.2) * rate)
        let take = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        take.frameLength = frames
        let samples = try XCTUnwrap(take.floatChannelData?[0])
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let word = Int((t - lead).rounded(.down))
            let inWord = word >= 0 && word < 3 && t - lead - Double(word) < 0.4
            samples[i] = inWord ? levels[word] * Float(sin(2 * .pi * 440 * t)) : 0
        }
        let url = directory.appendingPathComponent(VoiceClips.fileName(VoiceClips.countdownClip, voice: .allison) + "." + VoiceClips.fileExtension)
        do { // the file is finished when it's released
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            ])
            try file.write(from: take)
        }

        let library = VoiceClipLibrary(format: format, voice: .allison, bundle: try XCTUnwrap(Bundle(url: directory)))
        var peaks: [Float] = []
        for number in [3, 2, 1] {
            let piece = try XCTUnwrap(library.buffer(for: .count(number)), "no piece for \(number)")
            XCTAssertEqual(Double(piece.frameLength) / rate, VoiceClips.countdownNumberLength, accuracy: 0.001)
            let pieceSamples = try XCTUnwrap(piece.floatChannelData?[0])
            let loud = (0..<Int(piece.frameLength)).map { abs(pieceSamples[$0]) }
            // Each word starts just after its piece does, not partway into it.
            let onset = try XCTUnwrap(loud.firstIndex { $0 > 0.05 })
            XCTAssertEqual(Double(onset) / rate, VoiceClips.countdownLeadIn, accuracy: 0.02)
            peaks.append(loud.max() ?? 0)
        }
        // Leveled as one take, so the numbers keep their loudness relative to each other.
        XCTAssertEqual(peaks[1], 0.9, accuracy: 0.05)
        XCTAssertEqual(peaks[0], 0.45, accuracy: 0.05)
        XCTAssertEqual(peaks[2], 0.675, accuracy: 0.05)
    }

    @MainActor
    func testSystemVoiceUsesNoClips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeClip("halfway", in: directory, lead: 0, tone: 0.3, level: 0.5)

        let bundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertNotNil(VoiceClipLibrary(format: format, voice: .allison, bundle: bundle).buffer(for: .halfway))
        XCTAssertNil(VoiceClipLibrary(format: format, voice: .brad, bundle: bundle).buffer(for: .halfway), "Allison's clip isn't Brad's")
        XCTAssertNil(VoiceClipLibrary(format: format, voice: .system, bundle: bundle).buffer(for: .halfway))
    }

    @MainActor
    func testMissingClipMeansNoRecording() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeClip("phase-work", in: directory, lead: 0, tone: 0.3, level: 0.5)

        let library = VoiceClipLibrary(format: format, voice: .allison, bundle: try XCTUnwrap(Bundle(url: directory)))
        XCTAssertNil(library.buffer(for: .intervalsLeft(.work, 3)), "left-3 isn't there, so the system voice says it")
    }
}
