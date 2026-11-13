import Foundation

/// A row of the `program_reviews` table: the AI coach's look at a finished run
/// (or at missed sessions), with an optional plan change for the runner to
/// accept. A plan change suggested in the coach chat is a review too.
struct ProgramReview: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case generating, ready, accepted, dismissed, superseded, reverted, failed
    }

    /// What asked for the review: a finished run, missed sessions, or the
    /// runner asking for a change in the coach chat.
    enum Trigger: String, Codable {
        case run, missed, chat
    }

    var id: UUID
    var programID: UUID
    var recordID: UUID?
    var trigger: Trigger
    var status: Status
    /// The coach's short note on the run. Always set once ready.
    var feedback: String?
    /// The suggested plan change, or nil when the coach suggests none.
    var proposal: ReviewProposal?
    var error: String?
    var createdAt: Date
    var resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, trigger, status, feedback, proposal, error
        case programID = "program_id"
        case recordID = "record_id"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }
}

/// A plan change suggested by the coach, as written by the `review-program` function.
struct ReviewProposal: Codable, Equatable {
    /// One line per changed week, e.g. "About 10% less running".
    struct WeekChange: Codable, Equatable, Identifiable {
        var week: Int
        var change: String

        var id: Int { week }
    }

    /// Why the coach wants the change, in its own voice.
    var reason: String
    /// One line, e.g. "Ease weeks 4–8 back by about 10%".
    var summary: String
    var changes: [WeekChange]
    /// The new tail of the plan, from the first changed week to the end: what
    /// replaces those weeks in `programs.plan.weeks` on accept.
    var weeks: [ProgramWeek]
}
