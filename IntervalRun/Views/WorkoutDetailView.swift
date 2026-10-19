import SwiftData
import SwiftUI

/// Shows one workout and starts it.
struct WorkoutDetailView: View {
    let workout: Workout

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var session: WorkoutSession?
    @State private var returnHomeAfterPlayer = false

    var body: some View {
        let plan = workout.plan
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.summary)
                        .font(.headline)
                    Text("Total \(TimeFormat.clock(plan.totalSeconds))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Intervals") {
                ForEach(Array(plan.segments.enumerated()), id: \.offset) { _, segment in
                    HStack {
                        Circle()
                            .fill(segment.phase.color)
                            .frame(width: 10, height: 10)
                        Text(label(for: segment))
                        Spacer()
                        Text(TimeFormat.clock(segment.seconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(workout.name.isEmpty ? "Untitled workout" : workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                session = WorkoutSession(name: workout.name, plan: plan)
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Phase.work.color)
            .padding()
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    modelContext.insert(workout.duplicate())
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEditor = true }
            }
        }
        .sheet(isPresented: $showingEditor) {
            WorkoutEditorView(workout: workout)
        }
        .fullScreenCover(item: $session, onDismiss: {
            if returnHomeAfterPlayer {
                returnHomeAfterPlayer = false
                dismiss()
            }
        }) { session in
            PlayerView(session: session) { completed in
                returnHomeAfterPlayer = completed
                self.session = nil
            }
        }
    }

    private func label(for segment: Segment) -> String {
        switch segment.phase {
        case .warmUp: "Warm-up"
        case .coolDown: "Cool-down"
        case .work: "Work · round \(segment.round ?? 1)"
        case .rest: "Rest · round \(segment.round ?? 1)"
        }
    }
}
