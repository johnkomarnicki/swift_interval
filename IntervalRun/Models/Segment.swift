import Foundation

/// The kind of interval being run.
enum Phase: String, Codable, CaseIterable {
    case warmUp
    case work
    case rest
    case coolDown

    /// Label shown large on the player screen.
    var title: String {
        switch self {
        case .warmUp: "WARM-UP"
        case .work: "WORK"
        case .rest: "REST"
        case .coolDown: "COOL-DOWN"
        }
    }
}

/// One timed block of a workout, e.g. "work, 90 seconds, round 3".
struct Segment: Equatable {
    let phase: Phase
    /// Length in whole seconds (always at least 1).
    let seconds: Int
    /// 1-based round number for work and rest segments; nil for warm-up and cool-down.
    let round: Int?

    init(_ phase: Phase, _ seconds: Int, round: Int? = nil) {
        self.phase = phase
        self.seconds = seconds
        self.round = round
    }

    var duration: TimeInterval { TimeInterval(seconds) }
}
