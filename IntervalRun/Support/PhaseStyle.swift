import SwiftUI

/// Player background colors. All are dark enough for white text to stay readable.
extension Phase {
    var color: Color {
        switch self {
        case .warmUp: Color(red: 0.24, green: 0.29, blue: 0.37)    // slate
        case .work: Color(red: 0.82, green: 0.22, blue: 0.08)      // strong orange-red
        case .rest: Color(red: 0.05, green: 0.47, blue: 0.30)      // green
        case .coolDown: Color(red: 0.20, green: 0.24, blue: 0.42)  // dusk blue
        }
    }
}
