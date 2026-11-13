import SwiftData
import SwiftUI

/// Shown when a workout finishes.
struct CompleteView: View {
    let name: String
    let totalTime: TimeInterval
    let tracksDistance: Bool
    /// Nil until the final distances have been worked out (a couple of seconds).
    let results: WorkoutResults?
    /// `syncID` of the saved history record; nil until the results are saved.
    let recordID: UUID?
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(ReviewStore.self) private var reviews
    @State private var effort: RunEffort?
    @State private var requestedReview = false

    var body: some View {
        ZStack {
            Phase.rest.color.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 18) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 72))
                            .padding(.top, 24)
                        Text("Workout complete")
                            .font(.largeTitle.bold())
                        Text(name)
                            .font(.title3)
                            .opacity(0.85)

                        HStack(spacing: 0) {
                            summaryStat("TIME", TimeFormat.clock(Int(totalTime.rounded())))
                            if tracksDistance {
                                summaryStat("DISTANCE", results?.totalMeters.map(DistanceFormat.short) ?? "–")
                                summaryStat("AVG PACE", averagePace)
                            }
                            if let heartRate = results?.intervals.averageHeartRate {
                                summaryStat("AVG HR", "\(heartRate)")
                            }
                        }
                        .padding(.top, 4)

                        if results?.programLink != nil {
                            effortPicker
                            if requestedReview, let recordID {
                                CoachReviewCard(recordID: recordID)
                            }
                        }

                        if tracksDistance || results?.intervals.averageHeartRate != nil {
                            breakdown
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }

                Button(action: done) {
                    Text("Done")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(Phase.rest.color)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .foregroundStyle(.white)
        }
    }

    /// "How did that feel?" for a program session, so the coach knows.
    private var effortPicker: some View {
        VStack(spacing: 10) {
            Text("How did that feel?")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(RunEffort.allCases) { option in
                    effortButton(option)
                }
            }
        }
        .padding(.top, 8)
    }

    private func effortButton(_ option: RunEffort) -> some View {
        let isSelected = effort == option
        return Button {
            pick(option)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.icon)
                    .font(.title3)
                Text(option.title)
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.15)), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(isSelected ? Phase.rest.color : .white)
        }
        .buttonStyle(.plain)
        .disabled(recordID == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func pick(_ option: RunEffort) {
        guard let recordID else { return }
        effort = option
        WorkoutRecord.setEffort(option, forRecord: recordID, in: modelContext)
        requestReview()
    }

    private func done() {
        // The coach still reviews a session the runner didn't rate.
        requestReview()
        onDone()
    }

    /// Asks the coach to review this run, once.
    private func requestReview() {
        guard !requestedReview, let programID = results?.programLink?.programID, let recordID else { return }
        requestedReview = true
        Task { await reviews.requestRunReview(programID: programID, recordID: recordID) }
    }

    @ViewBuilder
    private var breakdown: some View {
        if let results {
            VStack(spacing: 0) {
                ForEach(results.intervals) { interval in
                    IntervalResultRow(result: interval)
                        .padding(.vertical, 10)
                    if interval.id != results.intervals.last?.id {
                        Divider().overlay(.white.opacity(0.3))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
        } else {
            ProgressView("Calculating distance…")
                .tint(.white)
                .padding(.top, 12)
        }
    }

    private var averagePace: String {
        guard let results, let meters = results.totalMeters else { return "–" }
        return DistanceFormat.pace(seconds: results.activeTime, meters: meters)
    }

    private func summaryStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .opacity(0.8)
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}
