import SwiftUI

/// One interval's time, heart rate, distance and pace, used on the finish screen and in history.
struct IntervalResultRow: View {
    let result: IntervalResult
    /// Shown instead of the result's own title, e.g. "Work" for a round's average.
    var title: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(result.phase.color)
                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? result.title)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(result.wasSkipped ? "Skipped" : TimeFormat.clock(Int(result.activeSeconds.rounded())))
                    if let heartRate = result.heartRate, !result.wasSkipped {
                        Label("\(heartRate.average) avg · \(heartRate.max) max", systemImage: "heart.fill")
                            .accessibilityLabel("Heart rate \(heartRate.average) average, \(heartRate.max) max")
                    }
                }
                .font(.caption.monospacedDigit())
                .opacity(0.7)
            }
            Spacer()
            if let meters = result.meters, !result.wasSkipped {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(DistanceFormat.short(meters))
                        .font(.headline.monospacedDigit())
                    HStack(spacing: 4) {
                        if result.source == .steps {
                            Image(systemName: "figure.walk")
                                .accessibilityLabel("From step counter")
                        }
                        Text(DistanceFormat.pace(seconds: result.activeSeconds, meters: meters))
                    }
                    .font(.caption.monospacedDigit())
                    .opacity(0.7)
                }
            }
        }
    }
}
