import SwiftUI

/// The coach's suggested plan change: why, what changes each week, and each
/// session before and after. Accept rewrites the plan; Keep my plan dismisses
/// the suggestion.
struct ReviewProposalSheet: View {
    let review: ProgramReview

    @Environment(ReviewStore.self) private var reviews
    @Environment(ProgramStore.self) private var programs
    @Environment(\.dismiss) private var dismiss
    @State private var expandedWeeks: Set<Int> = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    /// The review as the store has it now, e.g. superseded by a newer one.
    private var current: ProgramReview {
        reviews.review(id: review.id) ?? review
    }

    private var canDecide: Bool { current.status == .ready && current.proposal != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let proposal = current.proposal {
                    VStack(alignment: .leading, spacing: 28) {
                        intro(proposal)
                        if !proposal.changes.isEmpty {
                            weekChanges(proposal)
                        }
                        sessionChanges(proposal)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Suggested change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
        .interactiveDismissDisabled(isWorking)
    }

    // MARK: Content

    /// The summary as the title, then the coach's reason with its icon.
    private func intro(_ proposal: ReviewProposal) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("FROM YOUR COACH")
                    .font(.footnote.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(proposal.summary)
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 4)

            CardSection {
                HStack(alignment: .top, spacing: 12) {
                    RowIcon(systemImage: "sparkles")
                    Text(proposal.reason)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        }
    }

    /// The coach's one line per week.
    private func weekChanges(_ proposal: ReviewProposal) -> some View {
        CardSection(title: "Week by week") {
            ForEach(proposal.changes) { change in
                if change.id != proposal.changes.first?.id {
                    Divider().padding(.leading, 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Week \(change.week)")
                        .font(.headline)
                    Text(change.change)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// One row per week with changes, opening to its sessions before and after.
    @ViewBuilder
    private func sessionChanges(_ proposal: ReviewProposal) -> some View {
        let currentPlan = programs.program?.id == current.programID ? programs.program?.plan : nil
        let weeks = ProposalDiff(current: currentPlan, proposed: proposal.weeks).changedWeeks
        if !weeks.isEmpty {
            CardSection(title: "Session by session", footer: "Runs you've done and days that have passed stay as they are.") {
                ForEach(weeks) { week in
                    if week.id != weeks.first?.id {
                        Divider().padding(.leading, 16)
                    }
                    WeekDiffRow(week: week, isExpanded: expandedBinding(week.week))
                }
            }
        }
    }

    private func expandedBinding(_ week: Int) -> Binding<Bool> {
        Binding(
            get: { expandedWeeks.contains(week) },
            set: { isExpanded in
                if isExpanded { expandedWeeks.insert(week) } else { expandedWeeks.remove(week) }
            }
        )
    }

    // MARK: Footer

    /// Accept and Keep, pinned, with what went wrong (or why there's nothing
    /// to decide) over them.
    private var footer: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if !canDecide {
                Text(current.status == .accepted ? "This change is already in your plan." : "This suggestion is no longer open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(action: accept) {
                ZStack {
                    Text("Accept change").opacity(isWorking ? 0 : 1)
                    if isWorking { ProgressView().tint(.white) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWorking || !canDecide)

            Button(action: keep) {
                Text("Keep my plan")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isWorking || !canDecide)
            .opacity(canDecide ? 1 : 0.4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .background {
            // Fades the scrolling content out above the buttons, solid behind them.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 20)
                Color(.systemGroupedBackground)
            }
            .ignoresSafeArea()
        }
    }

    private func accept() {
        run {
            try await reviews.accept(current)
            await programs.load()
        }
    }

    private func keep() {
        run { try await reviews.dismiss(current) }
    }

    /// Runs a decision, then closes the sheet; on failure stays open with the error.
    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await work()
                dismiss()
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
            isWorking = false
        }
    }
}

/// A week with changes: "Week 5", how many sessions change and the new focus;
/// tapping it shows each changed session.
private struct WeekDiffRow: View {
    let week: ProposalDiff.Week
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Week \(week.week)")
                            .font(.headline)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    RowChevron()
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(isExpanded ? "Hides the sessions" : "Shows the sessions")

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(week.changes) { change in
                        Divider().padding(.leading, 60)
                        SessionDiffRow(change: change)
                    }
                    if week.unchangedCount > 0 {
                        Divider().padding(.leading, 60)
                        Text(week.unchangedCount == 1 ? "1 other run unchanged" : "\(week.unchangedCount) other runs unchanged")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 60)
                            .padding(.trailing, 16)
                            .padding(.vertical, 12)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// "2 changes · Up to 6 minutes"
    private var summary: String {
        let count = week.changes.count
        let changes = count == 1 ? "1 change" : "\(count) changes"
        return week.focus.isEmpty ? changes : "\(changes) · \(week.focus)"
    }
}

/// One session that changes: before → after for a changed run, or the run
/// that's added or removed.
private struct SessionDiffRow: View {
    let change: ProposalDiff.SessionChange

    var body: some View {
        if let session = change.session {
            HStack(alignment: .top, spacing: 12) {
                RowIcon(systemImage: session.kindIcon, tint: change.kind == .removed ? .secondary : Phase.work.color)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(SessionDateText.label(for: session))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        tag
                    }
                    titleLine(session)
                    minutesLine(session)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel(session))
        }
    }

    @ViewBuilder
    private var tag: some View {
        switch change.kind {
        case .added, .changed:
            Text(change.kind == .added ? "New" : "Updated")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Phase.work.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Phase.work.color.opacity(0.18), in: Capsule())
        case .removed:
            Text("Removed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.1), in: Capsule())
        case .unchanged:
            EmptyView()
        }
    }

    /// The new title, with the old one struck through when it changed.
    @ViewBuilder
    private func titleLine(_ session: ProgramSession) -> some View {
        switch change.kind {
        case .removed:
            Text(session.title)
                .strikethrough()
                .foregroundStyle(.secondary)
        case .changed where change.old?.title != change.new?.title:
            VStack(alignment: .leading, spacing: 1) {
                Text(change.old?.title ?? "")
                    .font(.subheadline)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Text(session.title)
            }
        default:
            Text(session.title)
        }
    }

    /// "30 → 26 min" when the length changed, else "26 min".
    private func minutesLine(_ session: ProgramSession) -> some View {
        let new = ProposalDiff.minutes(session)
        let text: String
        if change.kind == .changed, let old = change.old.map(ProposalDiff.minutes), old != new {
            text = "\(session.kindLabel) · \(old) → \(new) min"
        } else {
            text = "\(session.kindLabel) · \(new) min"
        }
        return Text(text)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func spokenLabel(_ session: ProgramSession) -> String {
        let day = SessionDateText.label(for: session)
        let minutes = ProposalDiff.minutes(session)
        switch change.kind {
        case .added:
            return "\(day), new: \(session.title), \(minutes) minutes"
        case .removed:
            return "\(day), removed: \(session.title)"
        case .changed, .unchanged:
            var parts = ["\(day), updated"]
            if let old = change.old, old.title != session.title {
                parts.append("\(old.title) becomes \(session.title)")
            } else {
                parts.append(session.title)
            }
            if let old = change.old.map(ProposalDiff.minutes), old != minutes {
                parts.append("\(old) minutes becomes \(minutes)")
            } else {
                parts.append("\(minutes) minutes")
            }
            return parts.joined(separator: ", ")
        }
    }
}
