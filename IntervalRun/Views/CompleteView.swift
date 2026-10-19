import SwiftUI

/// Shown when a workout finishes.
struct CompleteView: View {
    let name: String
    let totalTime: TimeInterval
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Phase.rest.color.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 96))
                Text("Workout complete")
                    .font(.largeTitle.bold())
                Text(name)
                    .font(.title3)
                    .opacity(0.85)
                VStack(spacing: 4) {
                    Text("TOTAL TIME")
                        .font(.caption.weight(.bold))
                        .opacity(0.8)
                    Text(TimeFormat.clock(Int(totalTime.rounded())))
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.top, 8)
                Spacer()
                Button(action: onDone) {
                    Text("Done")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(Phase.rest.color)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .foregroundStyle(.white)
        }
    }
}
