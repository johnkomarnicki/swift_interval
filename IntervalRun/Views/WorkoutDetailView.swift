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

            if plan.rounds > 1 {
                // Every round is the same, so show one round once instead of listing them all.
                let steps = plan.roundSteps.filter { $0.seconds > 0 }
                Section {
                    if plan.warmUpEnabled, plan.warmUpSeconds > 0 {
                        intervalRow(.warmUp, "Warm-up", plan.warmUpSeconds)
                    }
                    HStack {
                        Label("\(plan.rounds) rounds", systemImage: "repeat")
                        Spacer()
                        Text("\(TimeFormat.clock(steps.reduce(0) { $0 + $1.seconds })) each")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.semibold))
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        intervalRow(step.phase, step.phase == .work ? "Work" : "Rest", step.seconds)
                            .padding(.leading, 20)
                    }
                    if plan.coolDownEnabled, plan.coolDownSeconds > 0 {
                        intervalRow(.coolDown, "Cool-down", plan.coolDownSeconds)
                    }
                } header: {
                    Text("Intervals")
                } footer: {
                    if plan.skipLastRest, steps.last?.phase == .rest {
                        Text("No rest after the last round.")
                    }
                }
            } else {
                Section("Intervals") {
                    ForEach(Array(plan.segments.enumerated()), id: \.offset) { _, segment in
                        intervalRow(segment.phase, label(for: segment), segment.seconds)
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
        // After the Start button's inset, so the button sits above the tab bar.
        .clearsTabBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    modelContext.insert(workout.duplicate())
                    SyncService.shared.scheduleSync()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEditor = true }
            }
        }
        .task(id: plan) {
            // Start rendering voice prompts now so they're ready when Start is tapped.
            let cues = CuePlanner.cues(for: plan.segments, voice: AppSettings.voiceOptions)
            AudioCueScheduler.shared.prepareSpeech(for: cues)
            // Ask for location/motion access now rather than mid-run.
            if let distance = AppSettings.distanceSettings {
                DistancePermissions.requestIfNeeded(mode: distance.mode)
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

    private func intervalRow(_ phase: Phase, _ label: String, _ seconds: Int) -> some View {
        HStack {
            Circle()
                .fill(phase.color)
                .frame(width: 10, height: 10)
            Text(label)
            Spacer()
            Text(TimeFormat.clock(seconds))
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
