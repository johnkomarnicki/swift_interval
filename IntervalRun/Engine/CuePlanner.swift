import Foundation

/// A sound the app plays during a workout.
enum CueKind: CaseIterable {
    /// Short beep at 5, 4, 3, 2, 1 seconds left.
    case countdown
    /// Longer, higher tone when an interval starts.
    case transition
    /// Three rising tones when the workout ends.
    case finish

    /// Notes (frequency in Hz, length in seconds) that make up the sound.
    var notes: [(frequency: Double, duration: TimeInterval)] {
        switch self {
        case .countdown: [(880, 0.12)]
        case .transition: [(1318.5, 0.65)]
        case .finish: [(1046.5, 0.14), (1318.5, 0.14), (1568, 0.35)]
        }
    }

    /// Silence between notes.
    static let noteGap: TimeInterval = 0.06

    var soundDuration: TimeInterval {
        notes.reduce(0) { $0 + $1.duration } + Double(max(0, notes.count - 1)) * Self.noteGap
    }
}

/// A sound at a point in workout-elapsed time.
struct Cue: Equatable {
    let offset: TimeInterval
    let kind: CueKind
}

/// Works out every sound in a workout, and when other apps' audio should be ducked.
enum CuePlanner {
    static let countdownBeeps = 5

    /// All cues for a workout, in time order.
    ///
    /// Each segment gets a transition tone at its start, then countdown beeps at
    /// 5…1 seconds left. A beep that would land exactly on the segment's start is
    /// dropped because the transition tone is already playing then; so a 5-second
    /// interval gets beeps at 4, 3, 2, 1 and a 1-second interval gets none. The
    /// final segment ends with the finish sound instead of a transition.
    static func cues(for segments: [Segment]) -> [Cue] {
        var cues: [Cue] = []
        var start: TimeInterval = 0
        for segment in segments {
            cues.append(Cue(offset: start, kind: .transition))
            let end = start + segment.duration
            let beeps = min(countdownBeeps, segment.seconds - 1)
            if beeps > 0 {
                for secondsLeft in stride(from: beeps, through: 1, by: -1) {
                    cues.append(Cue(offset: end - TimeInterval(secondsLeft), kind: .countdown))
                }
            }
            start = end
        }
        if !segments.isEmpty {
            cues.append(Cue(offset: start, kind: .finish))
        }
        return cues
    }

    /// Stretches of workout time when other audio (music, podcasts) should be
    /// lowered: from just before a group of sounds to just after it. Sounds closer
    /// together than `mergeGap` share one window so music isn't pumped up and down
    /// between countdown beeps.
    static func duckWindows(
        for cues: [Cue],
        lead: TimeInterval = 0.35,
        tail: TimeInterval = 0.4,
        mergeGap: TimeInterval = 2.0
    ) -> [ClosedRange<TimeInterval>] {
        var windows: [ClosedRange<TimeInterval>] = []
        for cue in cues.sorted(by: { $0.offset < $1.offset }) {
            let window = (cue.offset - lead)...(cue.offset + cue.kind.soundDuration + tail)
            if let last = windows.last, window.lowerBound - last.upperBound < mergeGap {
                windows[windows.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else {
                windows.append(window)
            }
        }
        return windows
    }
}
