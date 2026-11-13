import AVFoundation
import XCTest
@testable import IntervalRun

final class VoicePromptTests: XCTestCase {
    /// work 30 · rest 20 · work 30  (round 2's rest skipped)
    private let segments = [
        Segment(.work, 30, round: 1),
        Segment(.rest, 20, round: 1),
        Segment(.work, 30, round: 2),
    ]

    private func speech(_ cues: [Cue]) -> [(TimeInterval, String)] {
        cues.compactMap { cue in cue.kind.announcement.map { (cue.offset, $0.text) } }
    }

    private func offsets(_ cues: [Cue], where match: (CueKind) -> Bool) -> [TimeInterval] {
        cues.filter { match($0.kind) }.map(\.offset)
    }

    // MARK: Phrases

    func testPhraseText() {
        XCTAssertEqual(Announcement.count(3).text, "Three")
        XCTAssertEqual(Announcement.count(1).text, "One")
        XCTAssertEqual(Announcement.halfway.text, "Halfway there")
        XCTAssertEqual(Announcement.intervalsLeft(.rest, 5).text, "Rest. 5 intervals left")
        XCTAssertEqual(Announcement.intervalsLeft(.work, 1).text, "Work. Last interval")
        XCTAssertEqual(Announcement.phase(.rest).text, "Rest")
        XCTAssertEqual(Announcement.coolDown.text, "Cool-down")
    }

    // MARK: Planning

    func testVoiceOffMatchesPlainBeeps() {
        XCTAssertEqual(CuePlanner.cues(for: segments, voice: .off), CuePlanner.cues(for: segments))
        XCTAssertTrue(CuePlanner.cues(for: segments).allSatisfy { $0.kind.announcement == nil })
    }

    func testAllVoicePrompts() {
        let cues = CuePlanner.cues(for: segments, voice: .all)
        let spoken = speech(cues)
        let expected: [(TimeInterval, String)] = [
            (0.8, "Work. 2 intervals left"), (15, "Halfway there"),
            (27, "Three"), (28, "Two"), (29, "One"),
            (30.8, "Rest"), (40, "Halfway there"),
            (47, "Three"), (48, "Two"), (49, "One"),
            (50.8, "Work. Last interval"), (65, "Halfway there"),
            (77, "Three"), (78, "Two"), (79, "One"),
        ]
        XCTAssertEqual(spoken.map(\.0), expected.map(\.0))
        XCTAssertEqual(spoken.map(\.1), expected.map(\.1))
        // Switch tones and the finish are still there.
        XCTAssertEqual(offsets(cues) { $0 == .transition }, [0, 30, 50])
        XCTAssertEqual(offsets(cues) { $0 == .finish }, [80])
        XCTAssertEqual(cues.map(\.offset), cues.map(\.offset).sorted())
    }

    func testSpokenCountdownReplacesBeepsAtTheSameTimes() {
        let beeps = offsets(CuePlanner.cues(for: segments)) { $0 == .countdown }
        XCTAssertEqual(beeps, [27, 28, 29, 47, 48, 49, 77, 78, 79])
        let voiced = CuePlanner.cues(for: segments, voice: VoiceOptions(countdown: true))
        XCTAssertEqual(offsets(voiced) { $0 == .countdown }, [])
        XCTAssertEqual(offsets(voiced) { $0.isCountdown }, beeps)
    }

    func testShortIntervalCountsOnlyTheSecondsItHas() {
        let cues = CuePlanner.cues(for: [Segment(.rest, 3, round: 1)], voice: VoiceOptions(countdown: true))
        XCTAssertEqual(speech(cues).map(\.1), ["Two", "One"])
    }

    func testEachToggleIsIndependent() {
        let halfwayOnly = speech(CuePlanner.cues(for: segments, voice: VoiceOptions(halfway: true)))
        XCTAssertEqual(halfwayOnly.map(\.1), ["Halfway there", "Halfway there", "Halfway there"])

        let leftOnly = speech(CuePlanner.cues(for: segments, voice: VoiceOptions(intervalsLeft: true)))
        XCTAssertEqual(leftOnly.map(\.1), ["Work. 2 intervals left", "Rest", "Work. Last interval"])

        let countOnly = CuePlanner.cues(for: segments, voice: VoiceOptions(countdown: true))
        XCTAssertTrue(speech(countOnly).allSatisfy { ["Three", "Two", "One"].contains($0.1) })
    }

    func testHalfwayOnlyInWorkAndRestOfTwentySecondsOrMore() {
        let cues = CuePlanner.cues(
            for: [Segment(.warmUp, 60), Segment(.work, 19, round: 1), Segment(.rest, 20, round: 1), Segment(.coolDown, 60)],
            voice: VoiceOptions(halfway: true)
        )
        // Only the 20 s rest, which starts at 79 s.
        XCTAssertEqual(offsets(cues) { $0 == .speech(.halfway) }, [89])
    }

    func testOddLengthHalfwayIsMidpoint() {
        let cues = CuePlanner.cues(for: [Segment(.work, 45, round: 1)], voice: VoiceOptions(halfway: true))
        XCTAssertEqual(offsets(cues) { $0 == .speech(.halfway) }, [22.5])
    }

    func testIntervalsLeftSkipsWarmUpAndAnnouncesCoolDown() {
        let plan = WorkoutPlan(
            warmUpEnabled: true, warmUpSeconds: 60, workSeconds: 30, restSeconds: 30,
            rounds: 2, skipLastRest: true, coolDownEnabled: true, coolDownSeconds: 60
        )
        let spoken = speech(CuePlanner.cues(for: plan.segments, voice: VoiceOptions(intervalsLeft: true)))
        XCTAssertEqual(spoken.map(\.1), [
            "Work. 2 intervals left", "Rest", "Work. Last interval", "Cool-down",
        ])
        XCTAssertEqual(spoken.map(\.0), [60.8, 90.8, 120.8, 150.8])
    }

    /// A round of a pattern is one interval, however many steps it has.
    func testJogWalkPatternCountsRounds() {
        let plan = WorkoutPlan(
            rounds: 2, skipLastRest: true, usesPattern: true,
            pattern: [
                IntervalStep(phase: .work, seconds: 90), IntervalStep(phase: .rest, seconds: 90),
                IntervalStep(phase: .work, seconds: 180), IntervalStep(phase: .rest, seconds: 180),
            ]
        )
        let spoken = speech(CuePlanner.cues(for: plan.segments, voice: VoiceOptions(intervalsLeft: true)))
        XCTAssertEqual(spoken.map(\.1), [
            "Work. 2 intervals left", "Rest", "Work", "Rest",
            "Work. Last interval", "Rest", "Work",
        ])
    }

    func testNoIntervalsLeftForVeryShortIntervals() {
        let cues = CuePlanner.cues(for: [Segment(.work, 2, round: 1), Segment(.rest, 3, round: 1)], voice: VoiceOptions(intervalsLeft: true))
        XCTAssertEqual(speech(cues).map(\.1), ["Rest"])
    }

    func testPhrasesAreUniqueInOrderOfUse() {
        let cues = CuePlanner.cues(for: segments, voice: .all)
        XCTAssertEqual(CuePlanner.phrases(in: cues).map(\.text), [
            "Work. 2 intervals left", "Halfway there", "Three", "Two", "One",
            "Rest", "Work. Last interval",
        ])
    }

    // MARK: Overlaps

    func testCountdownWinsOverIntervalsLeftInShortInterval() {
        // In a 4 s rest, "Rest. Last interval" (from 0.8 s) would run into "Three" at 1 s.
        let cues = CuePlanner.cues(for: [Segment(.rest, 4, round: 1)], voice: .all)
        let resolved = CuePlanner.resolvingSpeechOverlaps(cues)
        XCTAssertEqual(speech(resolved).map(\.1), ["Three", "Two", "One"])
        XCTAssertEqual(offsets(resolved) { $0 == .transition }, [0])
        XCTAssertEqual(offsets(resolved) { $0 == .finish }, [4])
    }

    func testIntervalsLeftWinsOverHalfway() {
        let cues = [
            Cue(offset: 10, kind: .speech(.halfway)),
            Cue(offset: 10.5, kind: .speech(.intervalsLeft(.work, 4))),
        ]
        XCTAssertEqual(CuePlanner.resolvingSpeechOverlaps(cues), [cues[1]])
    }

    func testEqualPriorityKeepsTheEarlierPrompt() {
        let cues = [
            Cue(offset: 5, kind: .speech(.halfway)),
            Cue(offset: 5.2, kind: .speech(.halfway)),
        ]
        XCTAssertEqual(CuePlanner.resolvingSpeechOverlaps(cues), [cues[0]])
    }

    func testFullWorkoutKeepsAllPromptsWhenThereIsRoom() {
        let cues = CuePlanner.cues(for: segments, voice: .all)
        // Each recorded number plays for this long, and must fit in its second.
        let resolved = CuePlanner.resolvingSpeechOverlaps(cues) { kind in
            if case .speech(.count) = kind { return VoiceClips.countdownNumberLength }
            return kind.soundDuration
        }
        XCTAssertEqual(resolved, cues)
    }

    func testDuckWindowsUseRealSpeechDurations() {
        let cues = [Cue(offset: 10, kind: .speech(.halfway))]
        let windows = CuePlanner.duckWindows(for: cues) { _ in 1.0 }
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].lowerBound, 10 - 0.35, accuracy: 1e-9)
        XCTAssertEqual(windows[0].upperBound, 10 + 1.0 + 0.4, accuracy: 1e-9)
    }

    // MARK: Rendering with the real system voice

    @MainActor
    func testSpokenNumbersRenderShortEnoughForOnePerSecond() async throws {
        guard AVSpeechSynthesisVoice.speechVoices().contains(where: { $0.language.hasPrefix("en") }) else {
            throw XCTSkip("No English voice installed")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let renderer = SpeechRenderer(format: format, coachVoice: .system)
        let phrases = VoiceClips.countdownRange.map { Announcement.count($0) } + [Announcement.halfway]
        let done = expectation(description: "all phrases rendered")
        done.expectedFulfillmentCount = phrases.count
        renderer.onRendered = { done.fulfill() }
        renderer.prepare(phrases)
        await fulfillment(of: [done], timeout: 60)

        for number in VoiceClips.countdownRange {
            let text = Announcement.count(number).text
            let duration = try XCTUnwrap(renderer.duration(of: text), "\(text) didn't render")
            XCTAssertLessThan(duration, 0.9, "\"\(text)\" must finish before the next second")
            XCTAssertEqual(renderer.buffer(for: text)?.format, format)
        }
        XCTAssertNotNil(renderer.buffer(for: "Halfway there"))
    }
}
