import SwiftData
import SwiftUI

/// All of the user's plans: switch which one is active, rename, or delete.
/// Only offered once there's more than one plan.
struct PlansLibraryView: View {
    @Environment(ProgramStore.self) private var programs
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [WorkoutRecord]

    @State private var switchTarget: TrainingProgram?
    @State private var deleteTarget: TrainingProgram?
    @State private var renameTarget: TrainingProgram?
    @State private var renameText = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let active = programs.library.first(where: { $0.status == .active }) {
                    Section("Active plan") {
                        PlanLibraryRow(program: active, doneCount: doneCount(for: active), isActive: true)
                            .contextMenu { renameButton(active) }
                            .swipeActions(edge: .leading) { renameButton(active).tint(.blue) }
                    }
                }

                let others = programs.library.filter { $0.status != .active }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { program in
                            Button { switchTarget = program } label: {
                                PlanLibraryRow(program: program, doneCount: doneCount(for: program), isActive: false)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = program }
                            }
                            .swipeActions(edge: .leading) { renameButton(program).tint(.blue) }
                            .contextMenu {
                                Button("Make active", systemImage: "checkmark.circle") { switchTarget = program }
                                renameButton(program)
                                Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = program }
                            }
                        }
                    } header: {
                        Text("Other plans")
                    } footer: {
                        Text("Tap a plan to make it active. Your progress on every plan is kept.")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView() } }
            .navigationTitle("My plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Switch to this plan?",
                isPresented: isPresented($switchTarget),
                titleVisibility: .visible,
                presenting: switchTarget
            ) { program in
                Button("Switch to “\(program.displayTitle)”") {
                    run { try await programs.activate(program.id) } then: { dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Your current plan moves to Other plans, with its progress kept.")
            }
            .confirmationDialog(
                "Delete this plan?",
                isPresented: isPresented($deleteTarget),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { program in
                Button("Delete “\(program.displayTitle)”", role: .destructive) {
                    run { try await programs.delete(program.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The runs you did on it stay in your History.")
            }
            .alert("Rename plan", isPresented: isPresented($renameTarget), presenting: renameTarget) { program in
                TextField("Plan name", text: $renameText)
                Button("Save") {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    run { try await programs.rename(program.id, to: name) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func renameButton(_ program: TrainingProgram) -> some View {
        Button("Rename", systemImage: "pencil") {
            renameText = program.displayTitle
            renameTarget = program
        }
    }

    private func doneCount(for program: TrainingProgram) -> Int {
        let sessionIDs = Set(program.plan?.sessions.map(\.id) ?? [])
        let done = Set(records.filter { $0.programID == program.id && $0.completed }.compactMap(\.programSessionID))
        return done.intersection(sessionIDs).count
    }

    private func isPresented(_ item: Binding<TrainingProgram?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    private func run(_ work: @escaping () async throws -> Void, then success: @escaping () -> Void = {}) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await work()
                success()
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
            isWorking = false
        }
    }
}

private struct PlanLibraryRow: View {
    let program: TrainingProgram
    let doneCount: Int
    let isActive: Bool

    var body: some View {
        let plan = program.plan
        let total = plan?.sessions.count ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(program.displayTitle).font(.headline)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Phase.work.color)
                }
            }
            if let plan {
                Text(details(plan))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(doneCount), total: Double(max(total, 1)))
                .tint(Phase.rest.color)
            Text("\(doneCount) of \(total) runs done")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func details(_ plan: ProgramPlan) -> String {
        var parts = ["\(plan.weeks.count) weeks"]
        if let start = ProgramDate.date(from: plan.startDate) {
            parts.append("from \(start.formatted(.dateTime.month(.abbreviated).day()))")
        }
        return parts.joined(separator: " · ")
    }
}
