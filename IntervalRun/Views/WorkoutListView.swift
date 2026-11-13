import SwiftData
import SwiftUI

/// Home screen: saved workouts.
struct WorkoutListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workout.createdAt) private var workouts: [Workout]

    @State private var editorTarget: EditorTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle(eyebrow: "\(workouts.count) CUSTOM", title: "Workouts")
                        .padding(.top, 16)

                    newWorkoutCard
                        .padding(.top, 20)

                    if workouts.isEmpty {
                        Text("Workouts you create will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(workouts) { workout in
                                NavigationLink(value: workout) {
                                    WorkoutCard(workout: workout)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Edit", systemImage: "pencil") {
                                        editorTarget = .edit(workout)
                                    }
                                    Button("Duplicate", systemImage: "plus.square.on.square") {
                                        duplicate(workout)
                                    }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        delete(workout)
                                    }
                                }
                            }
                        }
                        .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color(.systemGroupedBackground))
            .clearsTabBar()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Workout.self) { workout in
                WorkoutDetailView(workout: workout)
            }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .new: WorkoutEditorView(workout: nil)
                case .edit(let workout): WorkoutEditorView(workout: workout)
                }
            }
            .task {
                seedSampleIfNeeded()
            }
        }
    }

    private var newWorkoutCard: some View {
        Button {
            editorTarget = .new
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New workout")
                        .font(.title3.bold())
                    Text("Build your own run/walk intervals")
                        .font(.subheadline)
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(18)
            .background(AccentCardBackground())
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func delete(_ workout: Workout) {
        SyncService.delete(workout, in: modelContext)
    }

    private func duplicate(_ workout: Workout) {
        modelContext.insert(workout.duplicate())
        SyncService.shared.scheduleSync()
    }

    /// Adds the sample workout on first launch only, so deleting it sticks.
    private func seedSampleIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppSettings.hasSeededSampleKey) else { return }
        if workouts.isEmpty {
            modelContext.insert(Workout.sample())
            SyncService.shared.scheduleSync()
        }
        defaults.set(true, forKey: AppSettings.hasSeededSampleKey)
    }
}

/// Which workout the editor sheet is for.
enum EditorTarget: Identifiable {
    case new
    case edit(Workout)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let workout): "\(workout.persistentModelID.hashValue)"
        }
    }
}

/// A saved workout: name, total time, the pattern in words and as a bar.
private struct WorkoutCard: View {
    let workout: Workout

    var body: some View {
        let plan = workout.plan
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(workout.name.isEmpty ? "Untitled workout" : workout.name)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(TimeFormat.clock(plan.totalSeconds))
                    .font(.headline.monospacedDigit())
                RowChevron()
            }
            Text(plan.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            WorkoutSegmentBar(segments: plan.segments, height: 6)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
