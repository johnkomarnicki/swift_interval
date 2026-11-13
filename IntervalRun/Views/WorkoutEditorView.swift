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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameField

                    toggleCard("Warm-up walk", isOn: $plan.warmUpEnabled) {
                        DurationRow(title: "Duration", seconds: $plan.warmUpSeconds, range: 60...WorkoutPlan.maxIntervalSeconds,
                                    step: 60, isExpanded: binding(for: .warmUp))
                    }

                    intervals
                        .padding(.top, 8)

                    toggleCard("Cool-down walk", isOn: $plan.coolDownEnabled) {
                        DurationRow(title: "Duration", seconds: $plan.coolDownSeconds, range: 60...WorkoutPlan.maxIntervalSeconds,
                                    step: 60, isExpanded: binding(for: .coolDown))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { summary }
            .navigationTitle(workout == nil ? "New workout" : "Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: Sections

    /// A large name field whose placeholder is the name used if it's left empty.
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $name, prompt: Text(plan.suggestedName).foregroundStyle(.tertiary))
                .font(.system(size: 30, weight: .bold))
                .submitLabel(.done)
            Text("Name your workout, or keep the suggested name.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var intervals: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Intervals")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(plan.intervalCount) total")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            PillPicker(options: [false, true], title: { $0 ? "Custom pattern" : "Run + walk" }, selection: usesPattern)

            VStack(spacing: 0) {
                if plan.usesPattern {
                    patternRows
                } else {
                    DurationRow(title: "Run", phase: .work, seconds: $plan.workSeconds,
                                range: 15...WorkoutPlan.maxIntervalSeconds, isExpanded: binding(for: .work))
                    divider
                    DurationRow(title: "Walk", phase: .rest, seconds: $plan.restSeconds, isExpanded: binding(for: .rest))
                }
                divider
                HStack {
                    Text("Rounds")
                    Spacer(minLength: 8)
                    StepperCapsule(
                        value: "× \(plan.rounds)",
                        accessibilityLabel: "Rounds",
                        canDecrement: plan.rounds > WorkoutPlan.roundsRange.lowerBound,
                        canIncrement: plan.rounds < WorkoutPlan.roundsRange.upperBound,
                        onDecrement: { plan.rounds -= 1 },
                        onIncrement: { plan.rounds += 1 }
                    )
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 58)
                divider
                Toggle("Skip walk after last round", isOn: $plan.skipLastRest)
                    .tint(Phase.work.color)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text(plan.usesPattern
                 ? "Each round runs the pattern from top to bottom. Tap a step's name to change it, reorder or delete it."
                 : "Set walk to 0:00 for back-to-back runs.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var patternRows: some View {
        ForEach($plan.pattern) { $step in
            let index = plan.pattern.firstIndex { $0.id == step.id } ?? 0
            if index > 0 { divider }
            PatternStepRow(
                step: $step,
                number: index + 1,
                isExpanded: binding(for: .step(step.id)),
                onMoveUp: index > 0 ? { movePatternStep(at: index, by: -1) } : nil,
                onMoveDown: index < plan.pattern.count - 1 ? { movePatternStep(at: index, by: 1) } : nil,
                onDelete: { deletePatternStep(id: step.id) }
            )
        }
        if plan.pattern.count < WorkoutPlan.maxPatternSteps {
            if !plan.pattern.isEmpty { divider }
            HStack(spacing: 8) {
                addStepButton(.work)
                addStepButton(.rest)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func addStepButton(_ phase: Phase) -> some View {
        Button {
            addPatternStep(phase)
        } label: {
            Label("Add \(phase.stepTitle.lowercased())", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(phase.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(phase.color.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A card with a switch; while it's on, `content` shows under it.
    private func toggleCard<Content: View>(_ title: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Toggle(title, isOn: isOn.animation())
                .tint(Phase.work.color)
                .padding(.horizontal, 16)
                .frame(minHeight: 58)
            if isOn.wrappedValue {
                divider
                content()
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var divider: some View {
        Divider().padding(.leading, 16)
    }

    // MARK: Summary

    /// Total time, the run/walk split, a bar of every interval, and Save.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TOTAL TIME")
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(TimeFormat.clock(plan.totalSeconds))
                        .font(.system(size: 36, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                Spacer()
                splitTotal("Run", phase: .work, seconds: plan.workTotalSeconds)
                splitTotal("Walk", phase: .rest, seconds: plan.walkTotalSeconds)
                    .padding(.leading, 16)
            }

            WorkoutSegmentBar(segments: plan.segments)

            if let message = plan.validationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button(workout == nil ? "Save workout" : "Save changes", action: save)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!plan.isValid)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.primary.opacity(0.06), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background {
            LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
                .ignoresSafeArea()
        }
        .animation(.snappy(duration: 0.25), value: plan)
    }

    private func splitTotal(_ title: String, phase: Phase, seconds: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 5) {
                PhaseDot(phase: phase)
                Text(title)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(TimeFormat.clock(seconds))
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
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
        let finalName = trimmed.isEmpty ? plan.suggestedName : trimmed
        if let workout {
            workout.name = finalName
            workout.plan = plan
            workout.markChanged()
        } else {
            modelContext.insert(Workout(name: finalName, plan: plan))
        }
        SyncService.shared.scheduleSync()
        dismiss()
    }
}
