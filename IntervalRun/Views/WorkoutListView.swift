import SwiftData
import SwiftUI

/// Home screen: saved workouts.
struct WorkoutListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workout.createdAt) private var workouts: [Workout]

    @State private var editorTarget: EditorTarget?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(workouts) { workout in
                    NavigationLink(value: workout) {
                        WorkoutRow(workout: workout)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            delete(workout)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Edit", systemImage: "pencil") {
                            editorTarget = .edit(workout)
                        }
                        .tint(.blue)
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            duplicate(workout)
                        }
                        .tint(.indigo)
                    }
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
            .overlay {
                if workouts.isEmpty {
                    ContentUnavailableView(
                        "No Workouts",
                        systemImage: "figure.run",
                        description: Text("Tap + to build your first interval workout.")
                    )
                }
            }
            .navigationTitle("Interval Run")
            .navigationDestination(for: Workout.self) { workout in
                WorkoutDetailView(workout: workout)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") {
                        showingSettings = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Workout", systemImage: "plus") {
                        editorTarget = .new
                    }
                }
            }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .new: WorkoutEditorView(workout: nil)
                case .edit(let workout): WorkoutEditorView(workout: workout)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .task {
                seedSampleIfNeeded()
            }
        }
    }

    private func delete(_ workout: Workout) {
        modelContext.delete(workout)
    }

    private func duplicate(_ workout: Workout) {
        modelContext.insert(workout.duplicate())
    }

    /// Adds the sample workout on first launch only, so deleting it sticks.
    private func seedSampleIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppSettings.hasSeededSampleKey) else { return }
        if workouts.isEmpty {
            modelContext.insert(Workout.sample())
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

private struct WorkoutRow: View {
    let workout: Workout

    var body: some View {
        let plan = workout.plan
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(workout.name.isEmpty ? "Untitled workout" : workout.name)
                    .font(.headline)
                Text(plan.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TimeFormat.clock(plan.totalSeconds))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
