import SwiftData
import SwiftUI

/// Chat with the AI coach: ask anything about your running, a run or your
/// plan. Replies show as they're written; one that suggests a plan change
/// carries a card to see the change and accept it or keep the plan. Opened
/// from the Plan screen, or from a run in History to ask about that run.
struct CoachChatView: View {
    @Environment(CoachStore.self) private var coach
    @Environment(ReviewStore.self) private var reviews
    @Environment(ProgramStore.self) private var programs
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    /// The run the next message is about, until it's sent or removed.
    @State private var attachedRecordID: UUID?
    @State private var shownProposal: ProgramReview?
    @State private var confirmingClear = false
    @State private var clearError: String?
    @FocusState private var isComposerFocused: Bool

    private let bottomID = "bottom"

    /// - Parameter recordID: the run to ask about, when opened from History.
    init(recordID: UUID? = nil) {
        _attachedRecordID = State(initialValue: recordID)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if coach.messages.isEmpty && coach.sending == nil {
                            if !coach.isLoaded {
                                ProgressView().padding(.top, 60)
                            } else if let error = coach.loadError {
                                ContentUnavailableView {
                                    Label("Can't load your conversation", systemImage: "wifi.exclamationmark")
                                } description: {
                                    Text(error)
                                } actions: {
                                    Button("Try Again") { Task { await coach.load() } }
                                }
                            } else {
                                intro
                            }
                        }
                        ForEach(coach.messages) { message in
                            MessageRow(
                                message: message,
                                isLast: message.id == coach.messages.last?.id,
                                onSeeProposal: { shownProposal = $0 }
                            )
                            .id(message.id)
                        }
                        if let sending = coach.sending {
                            UserBubble(text: sending.text, recordID: sending.recordID)
                                .opacity(0.6)
                            CoachBubble { TypingDots() }
                        }
                        if let error = coach.sendError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: scrollKey) {
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Clear conversation", systemImage: "trash", role: .destructive) { confirmingClear = true }
                            .disabled(coach.messages.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Conversation options")
                }
            }
            .confirmationDialog("Clear your conversation with your coach?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear conversation", role: .destructive, action: clear)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your plan and any changes you've accepted stay as they are.")
            }
            .alert("Couldn't clear the conversation", isPresented: Binding(
                get: { clearError != nil },
                set: { if !$0 { clearError = nil } }
            )) {
                Button("OK") { clearError = nil }
            } message: {
                Text(clearError ?? "")
            }
            .sheet(item: $shownProposal) { review in
                ReviewProposalSheet(review: review)
            }
        }
        .task { await coach.load() }
        // The suggestions' cards need their reviews; a new one also shows on the Plan screen.
        .task(id: coach.suggestionIDs) {
            let ids = coach.suggestionIDs
            guard !ids.isEmpty else { return }
            await reviews.load(programID: programs.program?.id)
            await reviews.loadReviews(ids: ids)
        }
    }

    /// Moves whenever there's more to see at the bottom.
    private var scrollKey: [Int] {
        [coach.messages.count, coach.messages.last?.content.count ?? 0, coach.sending == nil ? 0 : 1,
         coach.sendError == nil ? 0 : 1]
    }

    // MARK: Empty conversation

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Phase.work.color)
                .padding(.top, 24)
            Text("Ask your coach")
                .font(.title2.bold())
            Text(attachedRecordID == nil
                 ? "Ask about a run, your plan or how your training is going. Your coach can also suggest changes to your plan; nothing changes until you accept."
                 : "Ask anything about this run: how it went, why it felt the way it did, or what to change next time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(starters, id: \.self) { starter in
                    Button { send(starter) } label: {
                        Text(starter)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(coach.isAnswering)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 8)
    }

    /// Questions to start with, for this run, the plan, or no plan yet.
    private var starters: [String] {
        if attachedRecordID != nil {
            return ["How did this run go?", "Why did this run feel so hard?", "What should I do differently next time?"]
        }
        if programs.program?.plan != nil {
            return ["How is my training going?", "Can you make this week a bit easier?",
                    "I'm away next week. Can you adjust my plan?", "What pace should my easy runs be?"]
        }
        return ["How should I start running?", "How often should I run each week?", "What should an easy run feel like?"]
    }

    // MARK: Composer

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraft.isEmpty && trimmedDraft.count <= CoachStore.maxMessageLength && !coach.isAnswering
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let recordID = attachedRecordID {
                HStack(spacing: 6) {
                    RunLabel(recordID: recordID)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { attachedRecordID = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Don't ask about this run")
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask your coach…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button { send(trimmedDraft) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(canSend ? Phase.work.color : Color.secondary.opacity(0.35), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            if trimmedDraft.count > CoachStore.maxMessageLength {
                Text("Keep messages under \(CoachStore.maxMessageLength) characters.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func send(_ text: String) {
        guard !text.isEmpty, !coach.isAnswering else { return }
        let recordID = attachedRecordID
        draft = ""
        Task {
            if await coach.send(text, recordID: recordID) {
                if attachedRecordID == recordID { attachedRecordID = nil }
            } else if draft.isEmpty {
                // Back in the box, to send again.
                draft = text
            }
        }
    }

    private func clear() {
        Task {
            do {
                try await coach.clear()
            } catch {
                clearError = friendlyMessage(for: error)
            }
        }
    }
}

// MARK: - Messages

/// One message: the runner's on the right, the coach's on the left with its
/// suggested change under it.
private struct MessageRow: View {
    let message: CoachMessage
    /// Only the last reply can be tried again.
    let isLast: Bool
    let onSeeProposal: (ProgramReview) -> Void

    @Environment(CoachStore.self) private var coach

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.content, recordID: message.recordID)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                switch message.status {
                case .generating where message.content.isEmpty:
                    CoachBubble { TypingDots() }
                case .generating, .ready:
                    CoachBubble {
                        Text(CoachText.formatted(message.content))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .failed:
                    failed
                }
                if message.status == .ready, let reviewID = message.reviewID {
                    SuggestionCard(reviewID: reviewID, onSee: onSeeProposal)
                }
            }
        }
    }

    private var failed: some View {
        HStack(spacing: 10) {
            Label("Your coach couldn't answer that.", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if isLast {
                Button("Try again") { Task { await coach.retry(message) } }
                    .font(.subheadline.weight(.semibold))
                    .tint(Phase.work.color)
                    .disabled(coach.isAnswering)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// The runner's message, in the work color on the right, with the run it's
/// about over it.
private struct UserBubble: View {
    let text: String
    let recordID: UUID?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let recordID {
                RunLabel(recordID: recordID)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Phase.work.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

/// The coach's side of the conversation: a card on the left.
private struct CoachBubble<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 32)
    }
}

/// The plan change a reply suggested, with what became of it; opens the change.
private struct SuggestionCard: View {
    let reviewID: UUID
    let onSee: (ProgramReview) -> Void

    @Environment(ReviewStore.self) private var reviews

    var body: some View {
        if let review = reviews.review(id: reviewID), let proposal = review.proposal {
            Button { onSee(review) } label: {
                HStack(spacing: 12) {
                    RowIcon(systemImage: icon(review.status), tint: review.status == .accepted ? Phase.rest.color : Phase.work.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(review.status))
                            .font(.subheadline.weight(.semibold))
                        Text(proposal.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    RowChevron()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    if review.status == .ready {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Phase.work.color.opacity(0.5), lineWidth: 1.5)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 32)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows the change")
        }
    }

    private func title(_ status: ProgramReview.Status) -> String {
        switch status {
        case .accepted: "Added to your plan"
        case .dismissed: "You kept your plan"
        case .superseded: "Replaced by a newer suggestion"
        case .reverted: "Undone"
        case .generating, .ready, .failed: "Suggested change"
        }
    }

    private func icon(_ status: ProgramReview.Status) -> String {
        switch status {
        case .accepted: "checkmark"
        case .dismissed, .superseded, .reverted: "arrow.uturn.backward"
        case .generating, .ready, .failed: "sparkles"
        }
    }
}

/// "Easy run · Tue, Oct 27", for a message about a run.
private struct RunLabel: View {
    @Query private var records: [WorkoutRecord]

    init(recordID: UUID) {
        let id: UUID? = recordID
        _records = Query(filter: #Predicate<WorkoutRecord> { $0.syncID == id })
    }

    var body: some View {
        Label(text, systemImage: "figure.run")
            .lineLimit(1)
    }

    private var text: String {
        guard let record = records.first else { return "About a run" }
        let date = record.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return record.name.isEmpty ? date : "\(record.name) · \(date)"
    }
}

/// Three dots taking turns, while the coach is thinking.
private struct TypingDots: View {
    @State private var lit = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 7, height: 7)
                    .opacity(index == lit ? 1 : 0.3)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.25), value: lit)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                lit = (lit + 1) % 3
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Your coach is writing")
    }
}

enum CoachText {
    /// The coach's reply with its **bold** and *italics*, keeping line breaks
    /// (so "- " lists read as lists).
    static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
