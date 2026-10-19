import Foundation

/// One step of a custom round, e.g. "work 1:30".
struct IntervalStep: Codable, Equatable, Identifiable {
    var id = UUID()
    /// `.work` or `.rest`.
    var phase: Phase
    var seconds: Int
}

/// The settings that define a workout, as a plain value type.
///
/// `Workout` (the SwiftData model) stores these fields; everything that turns them
/// into segments and times lives here so it can be unit tested without a database.
struct WorkoutPlan: Equatable {
    static let roundsRange = 1...50
    /// Longest value the minutes + seconds pickers can produce (59:59).
    static let maxIntervalSeconds = 59 * 60 + 59
    static let maxPatternSteps = 20

    var warmUpEnabled = false
    var warmUpSeconds = 300
    var workSeconds = 90
    /// 0 means "no rest": work intervals run back to back.
    var restSeconds = 60
    var rounds = 6
    var skipLastRest = true
    var coolDownEnabled = false
    var coolDownSeconds = 300
    /// When true, each round runs `pattern` instead of one work + one rest interval.
    var usesPattern = false
    var pattern: [IntervalStep] = []

    /// The work/rest steps that make up one round.
    var roundSteps: [IntervalStep] {
        if usesPattern { return pattern }
        return [
            IntervalStep(phase: .work, seconds: workSeconds),
            IntervalStep(phase: .rest, seconds: restSeconds),
        ]
    }

    /// The ordered list of intervals the player runs through.
    var segments: [Segment] {
        var result: [Segment] = []
        if warmUpEnabled, warmUpSeconds > 0 {
            result.append(Segment(.warmUp, warmUpSeconds))
        }
        let roundCount = min(max(rounds, Self.roundsRange.lowerBound), Self.roundsRange.upperBound)
        let steps = roundSteps
        for round in 1...roundCount {
            for step in steps where step.seconds > 0 {
                result.append(Segment(step.phase, step.seconds, round: round))
            }
        }
        if skipLastRest {
            // Go straight from the last work interval into the cool-down.
            while let last = result.last, last.phase == .rest, last.round == roundCount {
                result.removeLast()
            }
        }
        if coolDownEnabled, coolDownSeconds > 0 {
            result.append(Segment(.coolDown, coolDownSeconds))
        }
        return result
    }

    var totalSeconds: Int {
        segments.reduce(0) { $0 + $1.seconds }
    }

    /// Switches between "work + rest" and a custom pattern. The first switch to a
    /// pattern starts it from the current work and rest values.
    mutating func setUsesPattern(_ on: Bool) {
        if on, pattern.isEmpty {
            pattern = [IntervalStep(phase: .work, seconds: max(workSeconds, 1))]
            if restSeconds > 0 {
                pattern.append(IntervalStep(phase: .rest, seconds: restSeconds))
            }
        }
        usesPattern = on
    }

    /// Problems that stop the workout from being saved, or nil if it's fine.
    var validationMessage: String? {
        if usesPattern {
            if pattern.isEmpty { return "Add at least one interval to the pattern." }
            if !pattern.contains(where: { $0.phase == .work }) { return "The pattern needs at least one work interval." }
            if pattern.contains(where: { $0.seconds < 1 }) { return "Every interval in the pattern must be at least 1 second." }
        } else if workSeconds < 1 {
            return "Work interval must be at least 1 second."
        }
        if warmUpEnabled, warmUpSeconds < 1 { return "Warm-up must be at least 1 second, or turn it off." }
        if coolDownEnabled, coolDownSeconds < 1 { return "Cool-down must be at least 1 second, or turn it off." }
        if !Self.roundsRange.contains(rounds) { return "Rounds must be between 1 and 50." }
        return nil
    }

    var isValid: Bool { validationMessage == nil }

    /// One-line description, e.g. "5:00 warm-up · 6 × 1:30 / 1:00 · 5:00 cool-down"
    /// or, for a pattern, "2 × (1:30 / 1:30 / 3:00 / 3:00)".
    var summary: String {
        var parts: [String] = []
        if warmUpEnabled, warmUpSeconds > 0 {
            parts.append("\(TimeFormat.clock(warmUpSeconds)) warm-up")
        }
        if usesPattern {
            let steps = pattern.map { TimeFormat.clock($0.seconds) }.joined(separator: " / ")
            parts.append("\(rounds) × (\(steps))")
        } else {
            var main = "\(rounds) × \(TimeFormat.clock(workSeconds))"
            if restSeconds > 0 {
                main += " / \(TimeFormat.clock(restSeconds))"
            }
            parts.append(main)
        }
        if coolDownEnabled, coolDownSeconds > 0 {
            parts.append("\(TimeFormat.clock(coolDownSeconds)) cool-down")
        }
        return parts.joined(separator: " · ")
    }
}
