import SwiftUI

/// The coach's cards at the top of the Plan screen, each only when there's
/// something to say: a suggested change waiting for an answer, a change that
/// can still be undone, and an offer to adjust the plan after missed runs.
/// With nothing to show it adds nothing to the screen's stack.
struct CoachPlanCards: View {
    let programID: UUID
    let progress: ProgramProgress
    let onSeeProposal: (ProgramReview) -> Void

    @Environment(ReviewStore.self) private var reviews
    @Environment(ProgramStore.self) private var programs
    @State private var isUndoing = false
    @State private var undoError: String?
    @State private var missedRequest: MissedRequest?

    /// Set once the runner taps "Adjust my plan".
    private struct MissedRequest {
        let programID: UUID
        /// The reviews that existed then, so the new one can be told apart.
        let knownIDs: Set<UUID>
        /// The request didn't reach the coach (the error is in `lastError`).
        /// A request that did stays "reviewing" until its row arrives.
        var didFail = false
    }

    var body: some View {
        // A Group, so each card sits directly in the Plan screen's stack.
        Group {
            if let review = reviews.pendingProposal, review.programID == programID {
                proposalCard(review)
            }
            if let review = reviews.undoableChange, review.programID == programID {
                undoCard(review)
            }
            missedCard
        }
    }

    // MARK: Suggested change

    private func proposalCard(_ review: ProgramReview) -> some View {
        CardSection {
            Button { onSeeProposal(review) } label: {
                HStack(spacing: 12) {
                    RowIcon(systemImage: "sparkles")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your coach suggests a change")
                        if let summary = review.proposal?.summary {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 8)
                    RowChevron()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows the change")
        }
    }

    // MARK: Undo

    private func undoCard(_ review: ProgramReview) -> some View {
        CardSection {
            HStack(spacing: 12) {
                RowIcon(systemImage: "checkmark", tint: Phase.rest.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan updated")
                    Text(review.proposal?.summary ?? "Your coach changed your plan.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let undoError {
                        Label(undoError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.top, 4)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if isUndoing {
                    ProgressView()
                } else {
                    Button("Undo") { undo(review) }
                        .font(.subheadline.weight(.semibold))
                        .tint(Phase.work.color)
                        .accessibilityHint("Puts your plan back as it was")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
        }
    }

    private func undo(_ review: ProgramReview) {
        isUndoing = true
        undoError = nil
        Task {
            do {
                try await reviews.undo(review)
                await programs.load()
            } catch {
                undoError = friendlyMessage(for: error)
            }
            isUndoing = false
        }
    }

    // MARK: Missed runs

    /// The review the runner asked for, or one still being worked on from
    /// before (e.g. the app was closed while the coach was thinking).
    private var missedReview: ProgramReview? {
        let missed = reviews.reviews.filter { $0.programID == programID && $0.trigger == .missed }
        if let request = activeRequest {
            return missed.first { !request.knownIDs.contains($0.id) }
        }
        return missed.first { $0.status == .generating }
    }

    private var activeRequest: MissedRequest? {
        missedRequest?.programID == programID ? missedRequest : nil
    }

    @ViewBuilder
    private var missedCard: some View {
        let review = missedReview
        let offered = reviews.missedSessionsToOffer(progress: progress, programID: programID)
        if review?.status == .generating || (activeRequest != nil && review == nil && activeRequest?.didFail == false) {
            coachCard {
                HStack(spacing: 12) {
                    Text("Your coach is going over your plan…")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    ProgressView()
                }
                .accessibilityElement(children: .combine)
            }
        } else if let review, activeRequest != nil {
            coachCard {
                VStack(alignment: .leading, spacing: 14) {
                    if review.status == .failed {
                        Text("Your coach couldn't review your plan right now. Try again later.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(review.feedback ?? "Your coach has looked over your plan.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CoachCardButton(title: "Got it", isPrimary: false) {
                        withAnimation { missedRequest = nil }
                    }
                }
            }
        } else if !offered.isEmpty {
            coachCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("You've missed \(offered.count) sessions. Want me to adjust your plan?")
                        .fixedSize(horizontal: false, vertical: true)
                    if activeRequest?.didFail == true {
                        Label(reviews.lastError ?? "Couldn't reach your coach. Try again in a bit.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: 10) {
                        CoachCardButton(title: "Adjust my plan", isPrimary: true) { requestMissedReview() }
                        CoachCardButton(title: "Not now", isPrimary: false) {
                            withAnimation {
                                missedRequest = nil
                                reviews.declineMissedReview(programID: programID)
                            }
                        }
                    }
                }
            }
        }
    }

    private func requestMissedReview() {
        let known = Set(reviews.reviews.map(\.id))
        withAnimation { missedRequest = MissedRequest(programID: programID, knownIDs: known) }
        Task {
            await reviews.requestMissedReview(programID: programID)
            if missedRequest?.programID == programID, reviews.lastError != nil {
                missedRequest?.didFail = true
            }
        }
    }

    /// The coach's icon beside the card's content, in a plain card.
    private func coachCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        CardSection {
            HStack(alignment: .top, spacing: 12) {
                RowIcon(systemImage: "sparkles")
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
            }
            .padding(16)
        }
    }
}

/// A capsule button for a card's answer: filled in the work color, or a quiet
/// grey for the other choice.
private struct CoachCardButton: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPrimary ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isPrimary ? Phase.work.color : Color.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
