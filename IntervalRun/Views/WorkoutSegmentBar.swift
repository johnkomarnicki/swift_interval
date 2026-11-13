import SwiftUI

/// A workout at a glance: a capsule per interval, as wide as it is long. Runs
/// are in the work color; walks, warm-up and cool-down in the rest color, the
/// warm-up and cool-down fainter.
struct WorkoutSegmentBar: View {
    let segments: [Segment]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let total = max(segments.reduce(0) { $0 + $1.seconds }, 1)
            let spacing: CGFloat = segments.count > 40 ? 1 : 4
            let available = max(geometry.size.width - spacing * CGFloat(max(segments.count - 1, 0)), 0)
            HStack(spacing: spacing) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Capsule()
                        .fill(color(for: segment))
                        .frame(width: max(available * CGFloat(segment.seconds) / CGFloat(total), 2))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func color(for segment: Segment) -> Color {
        switch segment.phase {
        case .work: Phase.work.color
        case .rest: Phase.rest.color
        case .warmUp, .coolDown: Phase.rest.color.opacity(0.45)
        }
    }
}
