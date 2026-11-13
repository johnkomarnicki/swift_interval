import Foundation
import Observation
import os
import Supabase

/// The conversation with the AI coach: the runner asks anything about their
/// running, a run or their plan, and the coach answers, sometimes with a
/// suggested plan change (a review, accepted or dismissed like the others).
///
/// Replies are written on the `coach-chat` Edge Function: it answers right
/// away with the reply's id, then saves the reply's text as it's written. This
/// store polls that row until it's ready or failed, so the text shows as it grows.
@MainActor
@Observable
final class CoachStore {
    /// The conversation, oldest first.
    private(set) var messages: [CoachMessage] = []
    private(set) var isLoaded = false
    private(set) var loadError: String?
    /// Why the last message (or try again) didn't reach the coach.
    private(set) var sendError: String?
    /// The runner's message on its way, shown until the function has saved it.
    private(set) var sending: PendingMessage?

    /// Replies being polled.
    private var watching: Set<UUID> = []
    /// Bumped by `reset()` and `clear()` so requests and polls from before
    /// them stop touching state.
    private var generation = 0

    /// How long a reply can go without more of it being saved before it's
    /// given up on. Matches the function's own timeout.
    private static let replyTimeout: TimeInterval = 3 * 60
    private static let pollInterval: Duration = .seconds(1)
    /// The newest messages loaded; the coach itself sees fewer.
    private static let pageSize = 100
    /// Mirrors the function's limit.
    static let maxMessageLength = 2000

    private let log = Logger(subsystem: "IntervalRun", category: "Coach")

    struct PendingMessage {
        var text: String
        var recordID: UUID?
    }

    private struct SendRequest: Encodable {
        var action = "send"
        var message: String
        var recordID: UUID?
        var today: String

        enum CodingKeys: String, CodingKey {
            case action, message, today
            case recordID = "record_id"
        }
    }

    private struct RetryRequest: Encodable {
        var action = "retry"
        var messageID: UUID
        var today: String

        enum CodingKeys: String, CodingKey {
            case action, today
            case messageID = "message_id"
        }
    }

    private struct ClearRequest: Encodable { var action = "clear" }
    private struct SendResponse: Decodable { var message_id: UUID }
    private struct FunctionError: Decodable { var error: String }

    /// A failed clear, with a message to show the runner.
    struct CoachError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// From sending until the coach's reply is ready or failed.
    var isAnswering: Bool {
        sending != nil || messages.contains { $0.status == .generating }
    }

    /// The plan changes the coach suggested in the conversation.
    var suggestionIDs: [UUID] {
        messages.compactMap(\.reviewID)
    }

    // MARK: Loading

    /// Fetches the conversation and picks up a reply still being written.
    func load() async {
        let token = generation
        do {
            let rows: [CoachMessage] = try await supabase.from("coach_messages")
                .select()
                .order("created_at", ascending: false)
                .limit(Self.pageSize)
                .execute()
                .value
            guard generation == token else { return }
            messages = rows.reversed().map(Self.expiringStale)
            loadError = nil
            for row in messages where row.status == .generating {
                Task { await watch(row.id) }
            }
        } catch {
            log.error("Loading the conversation failed: \(error.localizedDescription)")
            guard generation == token else { return }
            if messages.isEmpty { loadError = friendlyMessage(for: error) }
        }
        isLoaded = true
    }

    /// A reply that stopped being saved past the timeout shows as failed, so
    /// the runner can try again.
    private static func expiringStale(_ message: CoachMessage) -> CoachMessage {
        guard message.status == .generating,
              Date.now.timeIntervalSince(message.updatedAt) >= replyTimeout else { return message }
        var expired = message
        expired.status = .failed
        expired.error = expired.error ?? "Timed out"
        return expired
    }

    // MARK: Sending

    /// Sends the runner's message, about a run when `recordID` is set. Returns
    /// false if it didn't reach the coach (the reason is in `sendError`), so
    /// the text can go back in the box.
    func send(_ text: String, recordID: UUID? = nil) async -> Bool {
        guard !isAnswering else { return false }
        sending = PendingMessage(text: text, recordID: recordID)
        sendError = nil
        let token = generation
        defer { if generation == token { sending = nil } }
        // The coach can only see a run once it's uploaded.
        if recordID != nil { await SyncService.shared.syncNow() }
        do {
            let response: SendResponse = try await supabase.functions.invoke(
                "coach-chat",
                options: FunctionInvokeOptions(body: SendRequest(
                    message: text,
                    recordID: recordID,
                    today: ProgramDate.string(from: .now)
                ))
            )
            guard generation == token else { return true }
            await load()
            Task { await watch(response.message_id) }
            return true
        } catch {
            guard generation == token else { return false }
            sendError = message(for: error, fallback: "Your coach couldn't take your message right now. Try again.")
            return false
        }
    }

    /// Asks the coach to write a failed reply again.
    func retry(_ reply: CoachMessage) async {
        guard reply.status == .failed, !isAnswering else { return }
        sendError = nil
        let token = generation
        do {
            let response: SendResponse = try await supabase.functions.invoke(
                "coach-chat",
                options: FunctionInvokeOptions(body: RetryRequest(messageID: reply.id, today: ProgramDate.string(from: .now)))
            )
            guard generation == token else { return }
            if let index = messages.firstIndex(where: { $0.id == reply.id }) {
                messages[index].status = .generating
                messages[index].content = ""
                messages[index].error = nil
                messages[index].reviewID = nil
                messages[index].updatedAt = .now
            }
            Task { await watch(response.message_id) }
        } catch {
            guard generation == token else { return }
            sendError = message(for: error, fallback: "Your coach couldn't try again right now. Try again in a bit.")
        }
    }

    /// Deletes the whole conversation. Suggested changes stay with the plan.
    func clear() async throws {
        do {
            try await supabase.functions.invoke("coach-chat", options: FunctionInvokeOptions(body: ClearRequest()))
        } catch {
            throw CoachError(message: message(for: error, fallback: "Couldn't clear the conversation. Try again."))
        }
        generation += 1
        messages = []
        watching = []
        sending = nil
        sendError = nil
    }

    /// Polls a reply until it's done, keeping `messages` up to date as its text grows.
    private func watch(_ id: UUID) async {
        guard watching.insert(id).inserted else { return }
        let token = generation
        defer { if generation == token { watching.remove(id) } }
        // Measured on the phone's clock, from the last time the reply moved on.
        var lastChange = Date.now
        while Date.now.timeIntervalSince(lastChange) < Self.replyTimeout {
            if let row = try? await fetch(id) {
                guard generation == token else { return }
                if row != messages.first(where: { $0.id == id }) {
                    lastChange = .now
                    upsert(row)
                }
                if row.status != .generating { return }
            }
            try? await Task.sleep(for: Self.pollInterval)
            guard generation == token else { return }
        }
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].status == .generating else { return }
        messages[index].status = .failed
        messages[index].error = "Timed out"
    }

    private func upsert(_ row: CoachMessage) {
        if let index = messages.firstIndex(where: { $0.id == row.id }) {
            messages[index] = row
        } else {
            messages.append(row)
            messages.sort { $0.createdAt < $1.createdAt }
        }
    }

    private func fetch(_ id: UUID) async throws -> CoachMessage {
        try await supabase.from("coach_messages")
            .select()
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    private func message(for error: Error, fallback: String) -> String {
        if case let FunctionsError.httpError(code, data) = error {
            let message = (try? JSONDecoder().decode(FunctionError.self, from: data))?.error
            log.error("Coach request failed (\(code)): \(message ?? "no message")")
            return message ?? fallback
        }
        log.error("Coach request failed: \(error.localizedDescription)")
        return friendlyMessage(for: error)
    }

    func reset() {
        generation += 1
        messages = []
        isLoaded = false
        loadError = nil
        sendError = nil
        sending = nil
        watching = []
    }
}
