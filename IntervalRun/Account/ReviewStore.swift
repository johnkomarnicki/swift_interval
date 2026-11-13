import Foundation
import Observation
import os
import Supabase

/// The AI coach's reviews of a plan: feedback on finished runs, nudges about
/// missed sessions, and plan changes to accept, keep or undo. Any earlier run
/// without a review can be reviewed from History, once.
///
/// Reviews run on the `review-program` Edge Function: it answers right away
/// with the review's id, then this store watches that row until it's ready
/// (well under a minute) or failed. Runs that can't be reviewed yet (offline,
/// or not uploaded) are queued and asked for again on the next `load`.
@MainActor
@Observable
final class ReviewStore {
    /// Reviews of the loaded program, newest first.
    private(set) var reviews: [ProgramReview] = []
    private(set) var lastError: String?
    /// Runs whose review couldn't be asked for (not offline: those are queued),
    /// by record id, with their plan so the runner can try again.
    private(set) var failedRunRequests: [UUID: FailedRequest] = [:]
    /// Reviews looked up for one run from History, by record id. They may
    /// belong to an earlier plan, or be too old to be among `reviews`.
    private var recordReviews: [UUID: ProgramReview] = [:]
    /// Reviews looked up by id for the coach chat's suggestions, for the same reasons.
    private var lookedUpReviews: [UUID: ProgramReview] = [:]

    /// The program `reviews` belong to, once they've been fetched.
    private var programID: UUID?
    /// Reviews asked for whose row hasn't arrived yet. A nil record is a
    /// missed-sessions review.
    private var inFlight: Set<Request> = []
    /// Reviews being polled.
    private var watching: Set<UUID> = []
    private var isRetryingQueue = false
    /// Bumped by `reset()` so requests and polls from before it stop touching state.
    private var generation = 0

    /// How long to wait for a review before giving up.
    private static let reviewTimeout: TimeInterval = 3 * 60
    private static let pollInterval: Duration = .seconds(3)
    /// Waits before asking again when the run hasn't reached Supabase yet: the
    /// upload started when the run was saved may still be going.
    private static let uploadRetryDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8)]
    /// How many later `load`s retry a queued run before it's dropped.
    private static let maxQueuedAttempts = 5
    private static let undoWindow: TimeInterval = 24 * 60 * 60

    private let log = Logger(subsystem: "IntervalRun", category: "Review")

    private struct Request: Hashable {
        var programID: UUID
        var recordID: UUID?
    }

    private struct ReviewRequest: Encodable {
        var action = "review"
        var programID: UUID
        var trigger: ProgramReview.Trigger
        var recordID: UUID?
        var today: String

        enum CodingKeys: String, CodingKey {
            case action, trigger, today
            case programID = "program_id"
            case recordID = "record_id"
        }
    }

    private struct ActionRequest: Encodable {
        var action: String
        var reviewID: UUID
        /// The runner's date, so accepting a change keeps today's session as it is.
        var today = ProgramDate.string(from: .now)

        enum CodingKeys: String, CodingKey {
            case action, today
            case reviewID = "review_id"
        }
    }

    private struct ReviewResponse: Decodable { var review_id: UUID }
    private struct FunctionError: Decodable { var error: String }

    struct FailedRequest {
        var programID: UUID
        var message: String
    }

    /// A failed accept, dismiss or undo, with a message to show the runner.
    struct ReviewError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    // MARK: Loading

    /// Fetches the program's recent reviews, picks up any still being written,
    /// and asks again for runs that couldn't be reviewed earlier.
    func load(programID: UUID?) async {
        if let programID {
            await fetchReviews(programID)
        } else {
            self.programID = nil
            reviews = []
        }
        await retryQueued()
    }

    private func fetchReviews(_ programID: UUID) async {
        if self.programID != programID {
            self.programID = nil
            reviews = []
        }
        let token = generation
        do {
            let rows: [ProgramReview] = try await supabase.from("program_reviews")
                .select()
                .eq("program_id", value: programID.uuidString)
                .order("created_at", ascending: false)
                .limit(20)
                .execute()
                .value
            guard generation == token else { return }
            self.programID = programID
            reviews = rows.map(Self.expiringStale)
            // A run whose review row is here now is no longer waiting.
            inFlight = inFlight.filter { request in
                guard let recordID = request.recordID else { return true }
                return review(forRecord: recordID) == nil
            }
            // Pick up reviews that were still being written when the app closed.
            for row in reviews where row.status == .generating {
                Task { await watch(row.id, startedAt: row.createdAt, request: nil) }
            }
        } catch {
            log.error("Loading reviews failed: \(error.localizedDescription)")
        }
    }

    /// A review stuck generating past the timeout shows as failed, so it doesn't
    /// block new reviews forever.
    private static func expiringStale(_ review: ProgramReview) -> ProgramReview {
        guard review.status == .generating,
              Date.now.timeIntervalSince(review.createdAt) >= reviewTimeout else { return review }
        var expired = review
        expired.status = .failed
        expired.error = expired.error ?? "Timed out"
        return expired
    }

    // MARK: Asking for reviews

    /// Asks the coach to look at a finished plan run. Does nothing if this run
    /// already has a review or one is on the way.
    func requestRunReview(programID: UUID, recordID: UUID) async {
        // A failed review can be asked for again; the function replaces it.
        guard review(forRecord: recordID).map({ $0.status == .failed }) ?? true,
              !isRequesting(record: recordID) else { return }
        let request = Request(programID: programID, recordID: recordID)
        inFlight.insert(request)
        failedRunRequests[recordID] = nil
        lastError = nil
        let token = generation
        // Upload the run (and its rating) first so the coach can see it.
        await SyncService.shared.syncNow()
        var outcome = await send(request)
        // A sync that was already running when the run was saved makes `syncNow`
        // return early, so give the upload a moment and try again.
        for delay in Self.uploadRetryDelays where outcome == .notUploaded {
            try? await Task.sleep(for: delay)
            guard generation == token else { return }
            await SyncService.shared.syncNow()
            outcome = await send(request)
        }
        guard generation == token else { return }
        finish(request, outcome)
    }

    /// Asks the coach to look at the sessions missed since the last review.
    func requestMissedReview(programID: UUID) async {
        let request = Request(programID: programID, recordID: nil)
        guard !inFlight.contains(request) else { return }
        inFlight.insert(request)
        lastError = nil
        let token = generation
        // Upload recent runs so they don't count as missed.
        await SyncService.shared.syncNow()
        let outcome = await send(request)
        guard generation == token else { return }
        finish(request, outcome)
    }

    func review(forRecord recordID: UUID) -> ProgramReview? {
        reviews.first { $0.recordID == recordID } ?? recordReviews[recordID]
    }

    func review(id: UUID) -> ProgramReview? {
        reviews.first { $0.id == id } ?? lookedUpReviews[id]
    }

    /// Fetches reviews by id that aren't loaded yet, e.g. the coach chat's
    /// suggestions from an earlier plan or from long ago.
    func loadReviews(ids: [UUID]) async {
        let missing = Set(ids.filter { review(id: $0) == nil })
        guard !missing.isEmpty else { return }
        let token = generation
        do {
            let rows: [ProgramReview] = try await supabase.from("program_reviews")
                .select()
                .in("id", values: missing.map(\.uuidString))
                .execute()
                .value
            guard generation == token else { return }
            for row in rows { lookedUpReviews[row.id] = row }
        } catch {
            log.error("Loading reviews by id failed: \(error.localizedDescription)")
        }
    }

    /// Fetches a run's review, whichever plan it belongs to, so History can
    /// show it, or offer one when there's none.
    func loadReview(forRecord recordID: UUID) async {
        let token = generation
        do {
            let rows: [ProgramReview] = try await supabase.from("program_reviews")
                .select()
                .eq("record_id", value: recordID.uuidString)
                .limit(1)
                .execute()
                .value
            guard generation == token, let row = rows.first.map(Self.expiringStale) else { return }
            recordReviews[recordID] = row
            if row.status == .generating {
                Task { await watch(row.id, startedAt: row.createdAt, request: nil) }
            }
        } catch {
            log.error("Loading the run's review failed: \(error.localizedDescription)")
        }
    }

    /// The run is waiting to upload (or for a connection) before the coach can see it.
    func isQueued(record recordID: UUID) -> Bool {
        Self.queued().contains { $0.recordID == recordID }
    }

    /// True from asking for a run's review until its row arrives.
    func isRequesting(record recordID: UUID) -> Bool {
        inFlight.contains { $0.recordID == recordID }
    }

    private enum Outcome: Equatable {
        case sent
        /// The run isn't in Supabase yet (or isn't linked to the plan).
        case notUploaded
        case offline
        case failed(String)
    }

    private func send(_ request: Request) async -> Outcome {
        do {
            let response: ReviewResponse = try await supabase.functions.invoke(
                "review-program",
                options: FunctionInvokeOptions(body: ReviewRequest(
                    programID: request.programID,
                    trigger: request.recordID == nil ? .missed : .run,
                    recordID: request.recordID,
                    today: ProgramDate.string(from: .now)
                ))
            )
            if self.programID != request.programID {
                await fetchReviews(request.programID)
            }
            Task { await watch(response.review_id, startedAt: .now, request: request) }
            return .sent
        } catch let FunctionsError.httpError(code, data) {
            let message = (try? JSONDecoder().decode(FunctionError.self, from: data))?.error
            log.error("Review request failed (\(code)): \(message ?? "no message")")
            if code == 400, request.recordID != nil { return .notUploaded }
            return .failed(message ?? "Your coach couldn't take a look right now. Try again later.")
        } catch let error as URLError {
            log.error("Review request failed: \(error.localizedDescription)")
            return .offline
        } catch {
            log.error("Review request failed: \(error.localizedDescription)")
            return .failed(friendlyMessage(for: error))
        }
    }

    private func finish(_ request: Request, _ outcome: Outcome) {
        switch outcome {
        case .sent:
            if let recordID = request.recordID { Self.dequeue(recordID) }
            // Stays in flight until `watch` sees the row.
            return
        case .notUploaded, .offline:
            if let recordID = request.recordID {
                Self.enqueue(programID: request.programID, recordID: recordID)
            } else {
                lastError = "You're offline. Connect to the internet and try again."
            }
        case .failed(let message):
            if let recordID = request.recordID {
                Self.dequeue(recordID)
                failedRunRequests[recordID] = FailedRequest(programID: request.programID, message: message)
            }
            lastError = message
        }
        inFlight.remove(request)
    }

    /// Polls a review until it's done, keeping `reviews` up to date.
    private func watch(_ id: UUID, startedAt: Date, request: Request?) async {
        guard watching.insert(id).inserted else { return }
        let token = generation
        defer {
            if generation == token {
                watching.remove(id)
                if let request { inFlight.remove(request) }
            }
        }
        var isFirst = true
        while Date.now.timeIntervalSince(startedAt) < Self.reviewTimeout {
            if !isFirst { try? await Task.sleep(for: Self.pollInterval) }
            isFirst = false
            guard let row = try? await fetch(id) else { continue }
            guard generation == token else { return }
            upsert(row)
            if let request { inFlight.remove(request) }
            if row.status != .generating { return }
        }
        guard generation == token, let index = reviews.firstIndex(where: { $0.id == id }) else { return }
        reviews[index] = Self.expiringStale(reviews[index])
    }

    private func upsert(_ row: ProgramReview) {
        if let recordID = row.recordID, recordReviews[recordID] != nil {
            recordReviews[recordID] = row
        }
        if lookedUpReviews[row.id] != nil {
            lookedUpReviews[row.id] = row
        }
        guard row.programID == programID else { return }
        if let index = reviews.firstIndex(where: { $0.id == row.id }) {
            reviews[index] = row
        } else {
            reviews.append(row)
            reviews.sort { $0.createdAt > $1.createdAt }
        }
    }

    private func fetch(_ id: UUID) async throws -> ProgramReview {
        try await supabase.from("program_reviews")
            .select()
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    // MARK: Plan changes

    /// The newest suggested change waiting for an answer.
    var pendingProposal: ProgramReview? {
        reviews.first { $0.status == .ready && $0.proposal != nil }
    }

    /// The last accepted change, if it's still recent enough to undo.
    var undoableChange: ProgramReview? {
        Self.undoableChange(in: reviews)
    }

    /// The newest accepted change, if it was accepted less than a day ago and
    /// nothing has been accepted or undone since.
    static func undoableChange(in reviews: [ProgramReview], now: Date = .now) -> ProgramReview? {
        let changes = reviews.filter { $0.status == .accepted || $0.status == .reverted }
        guard let latest = changes.max(by: { ($0.resolvedAt ?? $0.createdAt) < ($1.resolvedAt ?? $1.createdAt) }),
              latest.status == .accepted,
              let resolvedAt = latest.resolvedAt,
              now.timeIntervalSince(resolvedAt) < undoWindow else { return nil }
        return latest
    }

    /// Applies the suggested change to the plan. Reload the plan afterwards.
    func accept(_ review: ProgramReview) async throws {
        try await perform("accept", on: review, fallback: "Couldn't update your plan. Try again.")
    }

    /// Keeps the plan as it is.
    func dismiss(_ review: ProgramReview) async throws {
        try await perform("dismiss", on: review, fallback: "Couldn't save that. Try again.")
    }

    /// Puts the plan back the way it was before the change. Reload the plan afterwards.
    func undo(_ review: ProgramReview) async throws {
        try await perform("undo", on: review, fallback: "Couldn't undo the change. Try again.")
    }

    private func perform(_ action: String, on review: ProgramReview, fallback: String) async throws {
        do {
            try await supabase.functions.invoke(
                "review-program",
                options: FunctionInvokeOptions(body: ActionRequest(action: action, reviewID: review.id))
            )
        } catch let FunctionsError.httpError(_, data) {
            throw ReviewError(message: (try? JSONDecoder().decode(FunctionError.self, from: data))?.error ?? fallback)
        } catch {
            throw ReviewError(message: friendlyMessage(for: error))
        }
        await fetchReviews(review.programID)
        if let recordID = review.recordID, recordReviews[recordID] != nil {
            await loadReview(forRecord: recordID)
        }
        if lookedUpReviews[review.id] != nil, let row = try? await fetch(review.id) {
            upsert(row)
        }
    }

    // MARK: Missed sessions

    /// Missed sessions worth offering a review for: 2+ `.missed` sessions dated after the
    /// newest review of this program (any status) and after the last "Not now". Empty otherwise,
    /// or while a review is generating or a proposal is pending.
    func missedSessionsToOffer(progress: ProgramProgress, programID: UUID) -> [ProgramSession] {
        // Without the program's reviews there's no telling what was already reviewed.
        guard programID == self.programID else { return [] }
        let isBusy = inFlight.contains { $0.programID == programID }
            || reviews.contains { $0.status == .generating }
            || pendingProposal != nil
        return Self.missedSessionsToOffer(
            sessions: progress.plan.sessions,
            status: progress.status(of:),
            newestReview: reviews.first?.createdAt,
            declinedAt: Self.declines()[programID.uuidString],
            isBusy: isBusy,
            calendar: progress.calendar
        )
    }

    /// The offer rules, pure so they can be unit tested. A session counts if it's
    /// missed and dated on or after the day of the newest review and of the last
    /// "Not now" (sessions due that day weren't missed yet when they happened).
    static func missedSessionsToOffer(
        sessions: [ProgramSession],
        status: (ProgramSession) -> ProgramProgress.Status,
        newestReview: Date?,
        declinedAt: Date?,
        isBusy: Bool,
        calendar: Calendar = .current
    ) -> [ProgramSession] {
        guard !isBusy else { return [] }
        let since = [newestReview, declinedAt].compactMap { $0 }.map { calendar.startOfDay(for: $0) }.max()
            ?? .distantPast
        let missed = sessions.filter { session in
            guard status(session) == .missed, let date = session.calendarDate else { return false }
            return date >= since
        }
        return missed.count >= 2 ? missed : []
    }

    /// "Not now": hides the offer until more sessions are missed.
    func declineMissedReview(programID: UUID) {
        var declines = Self.declines()
        declines[programID.uuidString] = .now
        UserDefaults.standard.set(declines, forKey: Self.declinesKey)
    }

    func reset() {
        generation += 1
        reviews = []
        lastError = nil
        failedRunRequests = [:]
        recordReviews = [:]
        lookedUpReviews = [:]
        programID = nil
        inFlight = []
        watching = []
        isRetryingQueue = false
        UserDefaults.standard.removeObject(forKey: Self.queueKey)
        UserDefaults.standard.removeObject(forKey: Self.declinesKey)
    }

    // MARK: Saved on the phone

    /// When "Not now" was last tapped, by program id.
    private static let declinesKey = "coachMissedReviewDeclines"
    /// Runs still waiting to be reviewed.
    private static let queueKey = "coachQueuedReviews"

    private static func declines() -> [String: Date] {
        UserDefaults.standard.dictionary(forKey: declinesKey) as? [String: Date] ?? [:]
    }

    private struct QueuedReview: Codable {
        var programID: UUID
        var recordID: UUID
        /// How many times it's been put back in the queue.
        var attempts: Int
    }

    private static func queued() -> [QueuedReview] {
        UserDefaults.standard.data(forKey: queueKey)
            .flatMap { try? JSONDecoder().decode([QueuedReview].self, from: $0) } ?? []
    }

    private static func saveQueue(_ queue: [QueuedReview]) {
        if queue.isEmpty {
            UserDefaults.standard.removeObject(forKey: queueKey)
        } else {
            UserDefaults.standard.set(try? JSONEncoder().encode(queue), forKey: queueKey)
        }
    }

    /// Adds a run to the queue, or counts another failed try. Gives up after a
    /// few, e.g. if the run was deleted or isn't part of the plan after all.
    private static func enqueue(programID: UUID, recordID: UUID) {
        var queue = queued()
        if let index = queue.firstIndex(where: { $0.recordID == recordID }) {
            queue[index].attempts += 1
            if queue[index].attempts > maxQueuedAttempts { queue.remove(at: index) }
        } else {
            queue.append(QueuedReview(programID: programID, recordID: recordID, attempts: 1))
        }
        saveQueue(queue)
    }

    private static func dequeue(_ recordID: UUID) {
        saveQueue(queued().filter { $0.recordID != recordID })
    }

    /// Asks again for runs that couldn't be reviewed earlier.
    private func retryQueued() async {
        let queue = Self.queued()
        guard !queue.isEmpty, !isRetryingQueue else { return }
        isRetryingQueue = true
        let token = generation
        defer { if generation == token { isRetryingQueue = false } }
        await SyncService.shared.syncNow()
        for item in queue {
            guard generation == token else { return }
            if review(forRecord: item.recordID) != nil {
                Self.dequeue(item.recordID)
                continue
            }
            guard !isRequesting(record: item.recordID) else { continue }
            let request = Request(programID: item.programID, recordID: item.recordID)
            inFlight.insert(request)
            let outcome = await send(request)
            guard generation == token else { return }
            finish(request, outcome)
        }
    }
}
