import SwiftUI

/// The coach's review of a past run, in History. A run that never got one
/// (from before the coach, outside the plan, or whose review failed) can ask
/// for it here, once, and it's reviewed against the current plan. Any run can
/// also be talked over with the coach in the chat.
struct HistoryCoachSection: View {
    let recordID: UUID

    @Environment(ReviewStore.self) private var reviews
    @Environment(ProgramStore.self) private var programs
    @State private var isLoaded = false
    @State private var shownProposal: ProgramReview?
    @State private var isChatting = false

    var body: some View {
        Section("Coach") {
            content
            chatButton
        }
        .animation(.snappy(duration: 0.25), value: reviews.review(forRecord: recordID)?.status)
        .task(id: recordID) {
            await reviews.loadReview(forRecord: recordID)
            isLoaded = true
        }
        .sheet(item: $shownProposal) { review in
            ReviewProposalSheet(review: review)
        }
        .sheet(isPresented: $isChatting) {
            CoachChatView(recordID: recordID)
        }
    }

    /// The plan a new review is asked against.
    private var activeProgramID: UUID? { programs.program?.id }

    @ViewBuilder
    private var content: some View {
        if let review = reviews.review(forRecord: recordID) {
            switch review.status {
            case .generating:
                reviewing
            case .failed:
                couldntReview(message: nil)
            default:
                feedback(review)
            }
        } else if reviews.isRequesting(record: recordID) {
            reviewing
        } else if let failed = reviews.failedRunRequests[recordID] {
            couldntReview(message: failed.message)
        } else if reviews.isQueued(record: recordID) {
            Label("Your coach will look at this run once it's uploaded.", systemImage: "icloud.and.arrow.up")
                .foregroundStyle(.secondary)
        } else if !isLoaded {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else if activeProgramID != nil {
            askButton
        } else {
            Text("Start a plan to get your coach's take on your runs.")
                .foregroundStyle(.secondary)
        }
    }

    private var reviewing: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Your coach is looking at your run…")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func couldntReview(message: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label("Your coach couldn't review this run.", systemImage: "exclamationmark.triangle")
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            Spacer(minLength: 8)
            if activeProgramID != nil {
                Button("Try again", action: request)
                    .font(.subheadline.weight(.semibold))
                    .tint(Phase.work.color)
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func feedback(_ review: ProgramReview) -> some View {
        if let feedback = review.feedback {
            Text(feedback)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        }
        // A suggestion for an earlier plan can't be applied any more.
        if review.status == .ready, let proposal = review.proposal, review.programID == activeProgramID {
            Button {
                shownProposal = review
            } label: {
                HStack(spacing: 12) {
                    RowIcon(systemImage: "sparkles")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested change")
                            .foregroundStyle(Color.primary)
                        Text(proposal.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    RowChevron()
                }
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows the change")
        } else if review.status == .accepted {
            Label("Your plan was updated.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Phase.rest.color)
        }
    }

    private var askButton: some View {
        Button(action: request) {
            HStack(spacing: 12) {
                RowIcon(systemImage: "sparkles")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get your coach's review")
                        .foregroundStyle(Color.primary)
                    Text("Feedback on this run, and a change to your plan if it needs one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
    }

    private var chatButton: some View {
        Button { isChatting = true } label: {
            HStack(spacing: 12) {
                RowIcon(systemImage: "bubble.left.and.text.bubble.right")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat about this run")
                        .foregroundStyle(Color.primary)
                    Text("Ask your coach anything about it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
    }

    private func request() {
        guard let programID = activeProgramID else { return }
        Task { await reviews.requestRunReview(programID: programID, recordID: recordID) }
    }
}
