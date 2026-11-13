import Foundation

/// A row of the `coach_messages` table: something the runner said to the AI
/// coach, or the coach's reply (saved as it's written), which may come with a
/// suggested plan change.
struct CoachMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user, assistant
    }

    enum Status: String, Codable {
        case generating, ready, failed
    }

    var id: UUID
    var role: Role
    /// The runner's message, or the coach's reply so far.
    var content: String
    var status: Status
    /// The run the runner asked about, when they asked from History.
    var recordID: UUID?
    /// The plan change the coach suggested in this reply: a review with trigger `.chat`.
    var reviewID: UUID?
    var error: String?
    var createdAt: Date
    /// Moves on each time more of a reply is saved.
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role, content, status, error
        case recordID = "record_id"
        case reviewID = "review_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
