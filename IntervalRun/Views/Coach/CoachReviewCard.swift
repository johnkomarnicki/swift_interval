import SwiftUI

/// The coach's take on a just-finished plan run, for the Complete screen's
/// colored background: a spinner while it's thinking, then its feedback and,
/// when it suggests a plan change, a button to see it. Shows nothing until a
/// review has been asked for.
struct CoachReviewCard: View {
    let recordID: UUID

    @Environment(ReviewStore.self) private var reviews
    @State private var shownProposal: ProgramReview?

    var body: some View {
        let review = reviews.review(forRecord: recordID)
        // Always present, so the sheet stays up while the review's status changes.
        VStack(spacing: 0) {
            if let review {
                switch review.status {
                case .generating:
                    reviewing
                case .failed:
                    couldntReview(programID: review.programID)
                default:
                    if let feedback = review.feedback {
                        feedbackCard(review, feedback: feedback)
                    }
                }
            } else if reviews.isRequesting(record: recordID) {
                reviewing
            } else if let failed = reviews.failedRunRequests[recordID] {
                couldntReview(programID: failed.programID)
            }
        }
        .animation(.snappy(duration: 0.25), value: review?.status)
        .sheet(item: $shownProposal) { review in
            ReviewProposalSheet(review: review)
                // Back to the system text color, not the Complete screen's white.
                .foregroundStyle(Color.primary)
        }
    }

    private func couldntReview(programID: UUID) -> some View {
        HStack(spacing: 6) {
            Text("Your coach couldn't review this run.")
                .opacity(0.7)
            Button("Try again") {
                Task { await reviews.requestRunReview(programID: programID, recordID: recordID) }
            }
            .fontWeight(.semibold)
            .foregroundStyle(.white)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
    }

    private var reviewing: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text("Your coach is looking at your run…")
                .font(.subheadline)
                .opacity(0.85)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func feedbackCard(_ review: ProgramReview, feedback: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("COACH", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .opacity(0.8)
                .accessibilityLabel("Coach")
            Text(feedback)
                .fixedSize(horizontal: false, vertical: true)

            if review.status == .ready, let proposal = review.proposal {
                Divider().overlay(.white.opacity(0.3))
                    .padding(.vertical, 4)
                Text("Suggested change")
                    .font(.headline)
                Text(proposal.summary)
                    .font(.subheadline)
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    shownProposal = review
                } label: {
                    Text("See the change")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Phase.rest.color)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            } else if review.status == .accepted {
                Label("Your plan has been updated.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
    }
}
