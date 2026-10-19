import SwiftData
import SwiftUI

/// Create or edit a workout. Changes are kept in a draft until Save.
struct WorkoutEditorView: View {
    /// The workout being edited, or nil to create a new one.
    let workout: Workout?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var plan: WorkoutPlan
    @State private var expanded: Field?

    private enum Field: Hashable {
        case warmUp, work, rest, coolDown
        case step(UUID)
    }

    init(workout: Workout?) {
        self.workout = workout
        _name = State(initialValue: workout?.name ?? "")
        _plan = State(initialValue: workout?.plan ?? WorkoutPlan())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Week 3: 6 × 90s / 60s)", text: $name)
                }

                Section {
                    Toggle("Warm-up", isOn: $plan.warmUpEnabled.animation())
                    if plan.warmUpEnabled {
                        DurationRow(title: "Duration", seconds: $plan.warmUpSeconds, isExpanded: binding(for: .warmUp))
                    }
                }

                Section {
                    Picker("Round type", selection: usesPattern) {
                        Text("Work + rest").tag(false)
                        Text("Custom pattern").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if plan.usesPattern {
                        patternRows
                    } else {
                        DurationRow(title: "Work", seconds: $plan.workSeconds, isExpanded: binding(for: .work))
                        DurationRow(title: "Rest", seconds: $plan.restSeconds, isExpanded: binding(for: .rest))
                    }
                    Stepper(value: $plan.rounds, in: WorkoutPlan.roundsRange) {
                        HStack {
                            Text("Rounds")
                            Spacer()
                            Text("\(plan.rounds)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Skip rest after last round", isOn: $plan.skipLastRest)
                } header: {
                    Text("Intervals")
                } footer: {
                    if plan.usesPattern {
                        Text("Each round runs the pattern from top to bottom. Tap a step's name to change it, reorder or delete it.")
                    } else {
                        Text("Rest can be 0:00 for back-to-back work intervals.")
                    }
                }

                Section {
                    Toggle("Cool-down", isOn: $plan.coolDownEnabled.animation())
                    if plan.coolDownEnabled {
                        DurationRow(title: "Duration", seconds: $plan.coolDownSeconds, isExpanded: binding(for: .coolDown))
                    }
                } footer: {
                    if let message = plan.validationMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("Total workout time")
                    Spacer()
                    Text(TimeFormat.clock(plan.totalSeconds))
                        .monospacedDigit()
                        .bold()
                }
                .font(.title3)
                .padding()
                .background(.bar)
            }
            .navigationTitle(workout == nil ? "New Workout" : "Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!plan.isValid)
                }
            }
        }
    }

    @ViewBuilder
    private var patternRows: some View {
        ForEach($plan.pattern) { $step in
            let index = plan.pattern.firstIndex { $0.id == step.id } ?? 0
            PatternStepRow(
                step: $step,
                number: index + 1,
                isExpanded: binding(for: .step(step.id)),
                onMoveUp: index > 0 ? { movePatternStep(at: index, by: -1) } : nil,
                onMoveDown: index < plan.pattern.count - 1 ? { movePatternStep(at: index, by: 1) } : nil,
                onDelete: { deletePatternStep(id: step.id) }
            )
        }
        .onDelete { offsets in
            withAnimation { plan.pattern.remove(atOffsets: offsets) }
        }
        if plan.pattern.count < WorkoutPlan.maxPatternSteps {
            HStack {
                Button("Add Work", systemImage: "plus.circle.fill") { addPatternStep(.work) }
                    .foregroundStyle(Phase.work.color)
                Spacer()
                Button("Add Rest", systemImage: "plus.circle.fill") { addPatternStep(.rest) }
                    .foregroundStyle(Phase.rest.color)
            }
            .buttonStyle(.borderless)
        }
    }

    private var usesPattern: Binding<Bool> {
        Binding(
            get: { plan.usesPattern },
            set: { on in
                expanded = nil
                withAnimation { plan.setUsesPattern(on) }
            }
        )
    }

    private func addPatternStep(_ phase: Phase) {
        // Start from the most recent step of the same kind, e.g. another 1:30 jog.
        let seconds = plan.pattern.last { $0.phase == phase }?.seconds ?? (phase == .work ? 90 : 60)
        let step = IntervalStep(phase: phase, seconds: seconds)
        withAnimation {
            plan.pattern.append(step)
            expanded = .step(step.id)
        }
    }

    private func movePatternStep(at index: Int, by offset: Int) {
        let target = index + offset
        guard plan.pattern.indices.contains(target) else { return }
        withAnimation { plan.pattern.swapAt(index, target) }
    }

    private func deletePatternStep(id: UUID) {
        withAnimation { plan.pattern.removeAll { $0.id == id } }
    }

    private func binding(for field: Field) -> Binding<Bool> {
        Binding(
            get: { expanded == field },
            set: { expanded = $0 ? field : nil }
        )
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled workout" : trimmed
        if let workout {
            workout.name = finalName
            workout.plan = plan
        } else {
            modelContext.insert(Workout(name: finalName, plan: plan))
        }
        dismiss()
    }
}
