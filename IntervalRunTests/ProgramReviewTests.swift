import XCTest
@testable import IntervalRun

final class ProgramReviewDecodingTests: XCTestCase {
    private let base = """
      "id": "3b1f0c52-8a4e-4f7e-9a51-2f4d6c1e9b10",
      "user_id": "5d2a7a0e-1c3b-4b8e-b0a4-9e6f2d1c7a33",
      "program_id": "7fcffe21-32a6-448f-a640-3d3e17b68614",
      "record_id": "a6c1d3e4-5f60-4718-92a3-b4c5d6e7f809",
      "trigger": "run",
      "feedback": "Solid session. Your last reps held pace even as your heart rate crept up.",
      "previous_plan": null,
      "error": null,
      "model": "claude-sonnet-4-5",
      "created_at": "2026-10-28T18:02:11.482913+00:00",
      "updated_at": "2026-10-28T18:02:40.112+00:00"
    """

    func testDecodesReviewWithoutProposal() throws {
        let json = "{\(base), \"status\": \"ready\", \"proposal\": null, \"resolved_at\": null}"
        let review = try JSONDecoder.supabaseRows.decode(ProgramReview.self, from: Data(json.utf8))
        XCTAssertEqual(review.programID, UUID(uuidString: "7fcffe21-32a6-448f-a640-3d3e17b68614"))
        XCTAssertEqual(review.recordID, UUID(uuidString: "a6c1d3e4-5f60-4718-92a3-b4c5d6e7f809"))
        XCTAssertEqual(review.trigger, .run)
        XCTAssertEqual(review.status, .ready)
        XCTAssertNil(review.proposal)
        XCTAssertNil(review.resolvedAt)
        XCTAssertEqual(review.createdAt.timeIntervalSince1970, 1_793_210_531.483, accuracy: 0.01)
    }

    func testDecodesReviewWithProposal() throws {
        let proposal = """
        {
          "reason": "Your last three runs felt too hard and your pace faded late. Let's ease off for a few weeks.",
          "summary": "Ease weeks 4–5 back by about 10%",
          "changes": [{"week": 4, "change": "About 10% less running"}, {"week": 5, "change": "Long run peaks at 30 min"}],
          "weeks": [
            {
              "week": 4,
              "focus": "Recover and rebuild",
              "sessions": [
                {
                  "id": "w4-tue", "day": "tue", "date": "2026-11-17", "kind": "intervals",
                  "title": "Intervals 5 × 2:00",
                  "description": "Run each rep at about 9:30/mile.",
                  "workout": {
                    "warm_up_seconds": 300,
                    "steps": [{"phase": "work", "seconds": 120}, {"phase": "rest", "seconds": 120}],
                    "rounds": 5, "skip_last_rest": true, "cool_down_seconds": 300
                  }
                }
              ]
            },
            {
              "week": 5,
              "focus": "Steady",
              "sessions": [
                {
                  "id": "w5-sat", "day": "sat", "date": "2026-11-28", "kind": "long",
                  "title": "Long run 30 min",
                  "description": "Easy all the way.",
                  "workout": {
                    "warm_up_seconds": 0,
                    "steps": [{"phase": "work", "seconds": 1800}],
                    "rounds": 1, "skip_last_rest": true, "cool_down_seconds": 0
                  }
                }
              ]
            }
          ]
        }
        """
        let json = "{\(base), \"status\": \"accepted\", \"proposal\": \(proposal), \"resolved_at\": \"2026-10-28T18:05:00+00:00\"}"
        let review = try JSONDecoder.supabaseRows.decode(ProgramReview.self, from: Data(json.utf8))
        XCTAssertEqual(review.status, .accepted)
        XCTAssertNotNil(review.resolvedAt)
        let change = try XCTUnwrap(review.proposal)
        XCTAssertEqual(change.summary, "Ease weeks 4–5 back by about 10%")
        XCTAssertEqual(change.changes.map(\.id), [4, 5])
        XCTAssertEqual(change.weeks.map(\.week), [4, 5])
        XCTAssertEqual(change.weeks.flatMap(\.sessions).map(\.id), ["w4-tue", "w5-sat"])
        XCTAssertEqual(change.weeks[0].sessions[0].workout.rounds, 5)
        XCTAssertEqual(change.weeks[1].sessions[0].day, .sat)
    }

    func testDecodesMissedReviewWithoutRecord() throws {
        let json = """
        {
          "id": "3b1f0c52-8a4e-4f7e-9a51-2f4d6c1e9b10",
          "program_id": "7fcffe21-32a6-448f-a640-3d3e17b68614",
          "record_id": null, "trigger": "missed", "status": "generating",
          "feedback": null, "proposal": null, "error": null,
          "created_at": "2026-10-28T18:02:11.482913+00:00", "resolved_at": null
        }
        """
        let review = try JSONDecoder.supabaseRows.decode(ProgramReview.self, from: Data(json.utf8))
        XCTAssertEqual(review.trigger, .missed)
        XCTAssertEqual(review.status, .generating)
        XCTAssertNil(review.recordID)
        XCTAssertNil(review.feedback)
    }
}

@MainActor
final class ReviewOfferTests: XCTestCase {
    private let calendar = Calendar.current

    /// Three runs a week (Mon/Wed/Fri) for 3 weeks from Monday Oct 5, 2026.
    private func plan() -> ProgramPlan {
        let start = ProgramDate.date(from: "2026-10-05")!
        let workout = ProgramWorkout(warmUpSeconds: 300, steps: [.init(phase: .work, seconds: 600)], rounds: 1, skipLastRest: true, coolDownSeconds: 300)
        let days: [(Weekday, Int)] = [(.mon, 0), (.wed, 2), (.fri, 4)]
        return ProgramPlan(
            title: "Test plan",
            summary: "",
            startDate: "2026-10-05",
            weeks: (1...3).map { week in
                ProgramWeek(week: week, focus: "Week \(week)", sessions: days.map { day, offset in
                    let date = calendar.date(byAdding: .day, value: (week - 1) * 7 + offset, to: start)!
                    return ProgramSession(
                        id: "w\(week)-\(day.rawValue)", day: day, date: ProgramDate.string(from: date),
                        kind: "easy", title: "Run", description: "", workout: workout
                    )
                })
            }
        )
    }

    private func date(_ string: String, hour: Int = 12) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: ProgramDate.date(from: string)!)!
    }

    /// The sessions offered on `now`, with `done` sessions run.
    private func offered(
        now: String, done: Set<String> = [], newestReview: Date? = nil, declinedAt: Date? = nil, isBusy: Bool = false
    ) -> [String] {
        let progress = ProgramProgress(plan: plan(), doneSessionIDs: done, now: date(now))
        return ReviewStore.missedSessionsToOffer(
            sessions: progress.plan.sessions,
            status: progress.status(of:),
            newestReview: newestReview,
            declinedAt: declinedAt,
            isBusy: isBusy,
            calendar: calendar
        ).map(\.id)
    }

    func testFewerThanTwoMissedOffersNothing() {
        // Wed Oct 14: w1-mon, w1-wed done; w1-fri missed; w2-mon done.
        XCTAssertEqual(offered(now: "2026-10-14", done: ["w1-mon", "w1-wed", "w2-mon"]), [])
    }

    func testTwoMissedAreOffered() {
        XCTAssertEqual(offered(now: "2026-10-14", done: ["w1-mon", "w1-wed"]), ["w1-fri", "w2-mon"])
    }

    func testSessionsBeforeTheLastReviewDontCount() {
        // Reviewed on Sat Oct 10: only w2-mon is newer, so not enough.
        XCTAssertEqual(offered(now: "2026-10-14", newestReview: date("2026-10-10")), [])
        // Two more missed after it.
        XCTAssertEqual(offered(now: "2026-10-15", newestReview: date("2026-10-10")), ["w2-mon", "w2-wed"])
    }

    func testSessionOnTheReviewDayStillCounts() {
        // A review on Mon Oct 12 happened before that day's session was missed.
        XCTAssertEqual(offered(now: "2026-10-15", newestReview: date("2026-10-12", hour: 8)), ["w2-mon", "w2-wed"])
    }

    func testNotNowHidesTheOfferUntilMoreAreMissed() {
        XCTAssertEqual(offered(now: "2026-10-14", declinedAt: date("2026-10-14")), [])
        // One newer miss isn't enough.
        XCTAssertEqual(offered(now: "2026-10-15", declinedAt: date("2026-10-14")), [])
        // Two newer misses bring it back.
        XCTAssertEqual(offered(now: "2026-10-19", declinedAt: date("2026-10-14")), ["w2-wed", "w2-fri"])
    }

    func testTheLaterOfReviewAndNotNowWins() {
        XCTAssertEqual(offered(now: "2026-10-19", newestReview: date("2026-10-16"), declinedAt: date("2026-10-10")), [])
        XCTAssertEqual(offered(now: "2026-10-19", newestReview: date("2026-10-10"), declinedAt: date("2026-10-16")), [])
    }

    func testNothingWhileBusy() {
        XCTAssertEqual(offered(now: "2026-10-14", isBusy: true), [])
    }

    func testStoreOffersNothingBeforeReviewsLoad() {
        let progress = ProgramProgress(plan: plan(), doneSessionIDs: [], now: date("2026-10-14"))
        XCTAssertEqual(ReviewStore().missedSessionsToOffer(progress: progress, programID: UUID()), [])
    }
}

@MainActor
final class UndoableChangeTests: XCTestCase {
    private let programID = UUID()
    private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private func review(_ status: ProgramReview.Status, resolvedHoursAgo: Double?) -> ProgramReview {
        ProgramReview(
            id: UUID(), programID: programID, recordID: nil, trigger: .run, status: status,
            feedback: "Nice work.", proposal: nil, error: nil,
            createdAt: now.addingTimeInterval(-((resolvedHoursAgo ?? 0) + 1) * 3600),
            resolvedAt: resolvedHoursAgo.map { now.addingTimeInterval(-$0 * 3600) }
        )
    }

    func testRecentAcceptedChangeCanBeUndone() {
        let accepted = review(.accepted, resolvedHoursAgo: 2)
        XCTAssertEqual(ReviewStore.undoableChange(in: [review(.ready, resolvedHoursAgo: nil), accepted], now: now), accepted)
    }

    func testOldChangeCantBeUndone() {
        XCTAssertNil(ReviewStore.undoableChange(in: [review(.accepted, resolvedHoursAgo: 25)], now: now))
    }

    func testOnlyTheNewestAcceptedChange() {
        let older = review(.accepted, resolvedHoursAgo: 5)
        let newer = review(.accepted, resolvedHoursAgo: 1)
        XCTAssertEqual(ReviewStore.undoableChange(in: [older, newer], now: now), newer)
    }

    func testNothingAfterAnUndo() {
        let accepted = review(.accepted, resolvedHoursAgo: 5)
        let reverted = review(.reverted, resolvedHoursAgo: 1)
        XCTAssertNil(ReviewStore.undoableChange(in: [reverted, accepted], now: now))
    }

    func testDismissedChangesDontCount() {
        let accepted = review(.accepted, resolvedHoursAgo: 5)
        XCTAssertEqual(ReviewStore.undoableChange(in: [review(.dismissed, resolvedHoursAgo: 1), accepted], now: now), accepted)
    }
}

final class CoachChatDecodingTests: XCTestCase {
    func testDecodesChatSuggestion() throws {
        let json = """
        {
          "id": "3b1f0c52-8a4e-4f7e-9a51-2f4d6c1e9b10",
          "program_id": "7fcffe21-32a6-448f-a640-3d3e17b68614",
          "record_id": null,
          "trigger": "chat",
          "status": "ready",
          "feedback": "Here's a lighter week while you travel.",
          "proposal": {"reason": "Here's a lighter week while you travel.", "summary": "Lighter week 5", "changes": [], "weeks": []},
          "error": null,
          "created_at": "2026-11-01T09:00:00.123+00:00",
          "resolved_at": null
        }
        """
        let review = try JSONDecoder.supabaseRows.decode(ProgramReview.self, from: Data(json.utf8))
        XCTAssertEqual(review.trigger, .chat)
        XCTAssertNil(review.recordID)
        XCTAssertEqual(review.proposal?.summary, "Lighter week 5")
    }

    func testDecodesRunnerMessageAboutARun() throws {
        let json = """
        {
          "id": "0f6a3c1e-7b2d-4e59-8a10-b2c3d4e5f607",
          "user_id": "5d2a7a0e-1c3b-4b8e-b0a4-9e6f2d1c7a33",
          "role": "user",
          "content": "Why did this one feel so hard?",
          "status": "ready",
          "record_id": "a6c1d3e4-5f60-4718-92a3-b4c5d6e7f809",
          "program_id": null,
          "review_id": null,
          "error": null,
          "model": null,
          "created_at": "2026-11-01T09:00:00.123456+00:00",
          "updated_at": "2026-11-01T09:00:00+00:00"
        }
        """
        let message = try JSONDecoder.supabaseRows.decode(CoachMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.status, .ready)
        XCTAssertEqual(message.recordID, UUID(uuidString: "a6c1d3e4-5f60-4718-92a3-b4c5d6e7f809"))
        XCTAssertNil(message.reviewID)
    }

    func testDecodesReplyBeingWrittenWithSuggestion() throws {
        let json = """
        {
          "id": "9c8b7a6d-5e4f-4321-8a9b-0c1d2e3f4a5b",
          "role": "assistant",
          "content": "Good call. I've eased",
          "status": "generating",
          "record_id": null,
          "review_id": "3b1f0c52-8a4e-4f7e-9a51-2f4d6c1e9b10",
          "error": null,
          "created_at": "2026-11-01T09:00:01.5+00:00",
          "updated_at": "2026-11-01T09:00:04.25+00:00"
        }
        """
        let message = try JSONDecoder.supabaseRows.decode(CoachMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.status, .generating)
        XCTAssertEqual(message.reviewID, UUID(uuidString: "3b1f0c52-8a4e-4f7e-9a51-2f4d6c1e9b10"))
        XCTAssertGreaterThan(message.updatedAt, message.createdAt)
    }

    func testFormatsBoldAndKeepsLineBreaks() {
        let text = String(CoachText.formatted("Keep it **easy**.\n- Walk breaks are fine").characters)
        XCTAssertEqual(text, "Keep it easy.\n- Walk breaks are fine")
    }
}

private extension JSONDecoder {
    /// Decodes Postgres timestamps (with or without fractional seconds) like the Supabase client does.
    static var supabaseRows: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: string))
        }
        return decoder
    }
}
