import Foundation

/// An open-ended run or walk with no intervals, tracked from the Free Run tab.
enum FreeActivity: String, Codable, CaseIterable, Identifiable {
    case run
    case walk

    var id: Self { self }

    /// "Run", also used as the name of the history record.
    var title: String {
        switch self {
        case .run: "Run"
        case .walk: "Walk"
        }
    }

    var systemImage: String {
        switch self {
        case .run: "figure.run"
        case .walk: "figure.walk"
        }
    }
}
