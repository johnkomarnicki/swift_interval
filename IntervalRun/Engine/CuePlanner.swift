import Foundation

/// A spoken prompt.
enum Announcement: Hashable {
    /// "Three", "Two", "One" in the last seconds of an interval.
    case count(Int)
    /// "Halfway there" in the middle of a work or rest interval.
    case halfway
    /// "Work. 3 intervals left" right after the switch into the first interval of
    /// a round. An interval here means a whole round of work and rest.
    case intervalsLeft(Phase, Int)
    /// "Rest" right after a switch within a round, where the intervals left haven't changed.
    case phase(Phase)
    /// "Cool-down" right after the switch into the cool-down.
    case coolDown
    /// "That was 0.21 miles. 8 minutes 15 per mile." after a work interval; either
    /// part can be left out. Only known during the workout, so it's added on the
    /// fly rather than planned.
    case workSummary(hundredthsOfMile: Int?, paceSecondsPerMile: Int?)

    var text: String {
        switch self {
        case .count(let number):
            Self.numberWords[number] ?? "\(number)"
        case .halfway:
            "Halfway there"
        case .intervalsLeft(let phase, let remaining):
            remaining == 1
                ? "\(Self.name(of: phase)). Last interval"
                : "\(Self.name(of: phase)). \(remaining) intervals left"
        case .phase(let phase):
            Self.name(of: phase)
        case .coolDown:
            "Cool-down"
        case .workSummary(let hundredths, let pace):
            switch (hundredths, pace) {
            case let (hundredths?, pace?):
                "That was \(DistanceFormat.spoken(hundredths: hundredths)). \(DistanceFormat.spokenPace(secondsPerMile: pace))."
            case let (hundredths?, nil):
                "That was \(DistanceFormat.spoken(hundredths: hundredths))"
            case let (nil, pace?):
                "Pace, \(DistanceFormat.spokenPace(secondsPerMile: pace))."
            case (nil, nil):
                ""
            }
        }
    }

    /// When two prompts would talk over each other, the higher priority one plays.
    var priority: Int {
        switch self {
        case .count: 3
        case .intervalsLeft, .phase, .coolDown: 2
        case .halfway, .workSummary: 1
        }
    }

    private static let numberWords = [1: "One", 2: "Two", 3: "Three"]

    private static func name(of phase: Phase) -> String {
        switch phase {
        case .work: "Work"
        case .rest: "Rest"
        case .warmUp: "Warm-up"
        case .coolDown: "Cool-down"
        }
    }
}

/// A sound the app plays during a workout.
enum CueKind: Hashable {
    /// Short beep at 3, 2, 1 seconds left.
    case countdown
    /// Longer, higher tone when an interval starts.
    case transition
    /// Three rising tones when the workout ends.
    case finish
    /// A spoken prompt.
    case speech(Announcement)

    /// The kinds that are generated as tones.
    static let tones: [CueKind] = [.countdown, .transition, .finish]

    /// Notes (frequency in Hz, length in seconds) that make up a tone. Empty for speech.
    var notes: [(frequency: Double, duration: TimeInterval)] {
        switch self {
        case .countdown: [(880, 0.12)]
        case .transition: [(1318.5, 0.65)]
        case .finish: [(1046.5, 0.14), (1318.5, 0.14), (1568, 0.35)]
        case .speech: []
        }
    }

    /// Silence between notes.
    static let noteGap: TimeInterval = 0.06

    /// Length of the sound. For speech this is an estimate; the real length is
    /// known once the phrase has been rendered.
    var soundDuration: TimeInterval {
        if case .speech(let announcement) = self {
            return 0.3 + 0.06 * Double(announcement.text.count)
        }
        return notes.reduce(0) { $0 + $1.duration } + Double(max(0, notes.count - 1)) * Self.noteGap
    }

    var announcement: Announcement? {
        if case .speech(let announcement) = self { return announcement }
        return nil
    }

    /// A 3-2-1 cue, as a beep or a spoken number.
    var isCountdown: Bool {
        if case .speech(.count) = self { return true }
        return self == .countdown
    }
}

/// A sound at a point in workout-elapsed time.
struct Cue: Equatable {
    let offset: TimeInterval
    let kind: CueKind
}

/// Which spoken prompts are turned on.
struct VoiceOptions: Equatable {
    /// Speak "three, two, one" instead of beeping.
    var countdown = false
    /// Say "Halfway there" in the middle of work and rest intervals.
    var halfway = false
    /// Say how many intervals (rounds of work and rest) are left as each one
    /// starts, and "Work" or "Rest" at the other switches.
    var intervalsLeft = false

    static let off = VoiceOptions()
    static let all = VoiceOptions(countdown: true, halfway: true, intervalsLeft: true)
}

/// Works out every sound in a workout, and when other apps' audio should be ducked.
enum CuePlanner {
    /// Seconds counted down at the end of each interval, beeped or spoken.
    static let countdownSeconds = 3
    /// "Halfway there" is only said in intervals at least this long, so it can't
    /// crowd the intervals-left prompt or the countdown.
    static let halfwayMinimumSeconds = 20
    /// Intervals shorter than this get no intervals-left prompt.
    static let announcementMinimumSeconds = 3
    /// The intervals-left prompt starts this long after the switch tone begins.
    static let announcementDelay: TimeInterval = 0.8

    /// All cues for a workout, in time order.
    ///
    /// Each segment gets a transition tone at its start, then countdown cues at
    /// 3, 2, 1 seconds left. A countdown cue that would land exactly on the segment's
    /// start is dropped because the transition tone is already playing then; so a
    /// 3-second interval counts 2, 1 and a 1-second interval gets none. The
    /// final segment ends with the finish sound instead of a transition.
    ///
    /// `voice` adds spoken prompts: "Three, two, one" replaces the countdown beeps, "Halfway
    /// there" in the middle of work and rest intervals, and at each switch either
    /// the intervals left (counting whole rounds of work and rest, including the
    /// one just starting) or, within a round, just "Work" or "Rest".
    static func cues(for segments: [Segment], voice: VoiceOptions = .off) -> [Cue] {
        var cues: [Cue] = []
        let startsRound = roundStarts(in: segments)
        let totalRounds = startsRound.filter { $0 }.count
        var roundsStarted = 0
        var start: TimeInterval = 0

        for (index, segment) in segments.enumerated() {
            cues.append(Cue(offset: start, kind: .transition))

            if voice.intervalsLeft, segment.seconds >= announcementMinimumSeconds {
                let announcement: Announcement? = if startsRound[index] {
                    .intervalsLeft(segment.phase, totalRounds - roundsStarted)
                } else if isInterval(segment.phase) {
                    .phase(segment.phase)
                } else if segment.phase == .coolDown {
                    .coolDown
                } else {
                    nil
                }
                if let announcement {
                    cues.append(Cue(offset: start + announcementDelay, kind: .speech(announcement)))
                }
            }
            if startsRound[index] {
                roundsStarted += 1
            }

            if voice.halfway, isInterval(segment.phase), segment.seconds >= halfwayMinimumSeconds {
                cues.append(Cue(offset: start + segment.duration / 2, kind: .speech(.halfway)))
            }

            let end = start + segment.duration
            let beeps = min(countdownSeconds, segment.seconds - 1)
            if beeps > 0 {
                for secondsLeft in stride(from: beeps, through: 1, by: -1) {
                    let kind: CueKind = voice.countdown ? .speech(.count(secondsLeft)) : .countdown
                    cues.append(Cue(offset: end - TimeInterval(secondsLeft), kind: kind))
                }
            }
            start = end
        }
        if !segments.isEmpty {
            cues.append(Cue(offset: start, kind: .finish))
        }
        return cues
    }

    /// Removes spoken prompts that would talk over each other. Higher priority
    /// prompts win (countdown, then intervals left, then halfway); between equals,
    /// the earlier one wins. Tones are never removed.
    static func resolvingSpeechOverlaps(
        _ cues: [Cue],
        gap: TimeInterval = 0.1,
        duration: (CueKind) -> TimeInterval = { $0.soundDuration }
    ) -> [Cue] {
        let speechIndices = cues.indices
            .filter { cues[$0].kind.announcement != nil }
            .sorted { a, b in
                let pa = cues[a].kind.announcement!.priority
                let pb = cues[b].kind.announcement!.priority
                return pa != pb ? pa > pb : cues[a].offset < cues[b].offset
            }
        var taken: [ClosedRange<TimeInterval>] = []
        var dropped = Set<Int>()
        for index in speechIndices {
            let cue = cues[index]
            let span = cue.offset...(cue.offset + duration(cue.kind) + gap)
            if taken.contains(where: { $0.overlaps(span) }) {
                dropped.insert(index)
            } else {
                taken.append(span)
            }
        }
        return cues.indices.filter { !dropped.contains($0) }.map { cues[$0] }
    }

    /// Stretches of workout time when other audio (music, podcasts) should be
    /// lowered: from just before a group of sounds to just after it. Sounds closer
    /// together than `mergeGap` share one window so music isn't pumped up and down
    /// between countdown beeps.
    static func duckWindows(
        for cues: [Cue],
        lead: TimeInterval = 0.35,
        tail: TimeInterval = 0.4,
        mergeGap: TimeInterval = 2.0,
        duration: (CueKind) -> TimeInterval = { $0.soundDuration }
    ) -> [ClosedRange<TimeInterval>] {
        var windows: [ClosedRange<TimeInterval>] = []
        for cue in cues.sorted(by: { $0.offset < $1.offset }) {
            let window = (cue.offset - lead)...(cue.offset + duration(cue.kind) + tail)
            if let last = windows.last, window.lowerBound - last.upperBound < mergeGap {
                windows[windows.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else {
                windows.append(window)
            }
        }
        return windows
    }

    /// The distinct phrases a cue list will speak, in order of first use.
    static func phrases(in cues: [Cue]) -> [Announcement] {
        var seen = Set<String>()
        return cues.compactMap(\.kind.announcement).filter { seen.insert($0.text).inserted }
    }

    /// For each segment, whether it's the first work or rest interval of its round.
    private static func roundStarts(in segments: [Segment]) -> [Bool] {
        var previousRound: Int??
        return segments.map { segment in
            guard isInterval(segment.phase) else { return false }
            defer { previousRound = segment.round }
            return previousRound != .some(segment.round)
        }
    }

    private static func isInterval(_ phase: Phase) -> Bool {
        phase == .work || phase == .rest
    }
}
