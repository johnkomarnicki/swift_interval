import Foundation

/// How a program session felt, picked by the runner after it ends. The coach
/// uses it alongside pace and heart rate when reviewing the run.
enum RunEffort: String, Codable, CaseIterable, Identifiable {
    case easy
    case justRight = "just_right"
    case hard
    case tooHard = "too_hard"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easy: "Easy"
        case .justRight: "Just right"
        case .hard: "Hard"
        case .tooHard: "Too hard"
        }
    }

    /// SF Symbol name.
    var icon: String {
        switch self {
        case .easy: "leaf.fill"
        case .justRight: "hand.thumbsup.fill"
        case .hard: "flame.fill"
        case .tooHard: "exclamationmark.triangle.fill"
        }
    }
}
