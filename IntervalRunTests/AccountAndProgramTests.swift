import XCTest
@testable import IntervalRun

final class SyncMergeTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testRemoteOnlyRowsAreAddedLocally() {
        let plan = SyncMerge.plan(local: [], remote: [.init(id: a, updatedAt: t0)], pendingDeletes: [])
        XCTAssertEqual(plan.insertLocally, [a])
    }

    func testRowWaitingToBeDeletedIsNotAddedBack() {
        let plan = SyncMerge.plan(local: [], remote: [.init(id: a, updatedAt: t0)], pendingDeletes: [a])
        XCTAssertEqual(plan, SyncMerge.Plan())
    }

    func testNewerRemoteRowReplacesSyncedLocalCopy() {
        let plan = SyncMerge.plan(
            local: [.init(id: a, updatedAt: t0, needsUpload: false)],
            remote: [.init(id: a, updatedAt: t0.addingTimeInterval(60))],
            pendingDeletes: []
        )
        XCTAssertEqual(plan.updateLocally, [a])
    }

    func testSameOrOlderRemoteRowLeavesLocalAlone() {
        let plan = SyncMerge.plan(
            local: [.init(id: a, updatedAt: t0, needsUpload: false), .init(id: b, updatedAt: t0, needsUpload: false)],
            remote: [.init(id: a, updatedAt: t0), .init(id: b, updatedAt: t0.addingTimeInterval(-60))],
            pendingDeletes: []
        )
        XCTAssertEqual(plan, SyncMerge.Plan())
    }

    func testUnsentLocalChangesAlwaysWin() {
        let plan = SyncMerge.plan(
            local: [.init(id: a, updatedAt: t0, needsUpload: true), .init(id: b, updatedAt: t0, needsUpload: true)],
            remote: [.init(id: a, updatedAt: t0.addingTimeInterval(600))],
            pendingDeletes: []
        )
        // a isn't overwritten, and b (not uploaded yet) isn't deleted.
        XCTAssertEqual(plan, SyncMerge.Plan())
    }

    func testSyncedItemMissingRemotelyWasDeletedElsewhere() {
        let plan = SyncMerge.plan(
            local: [.init(id: c, updatedAt: t0, needsUpload: false), .init(id: d, updatedAt: t0, needsUpload: false)],
            remote: [.init(id: d, updatedAt: t0)],
            pendingDeletes: []
        )
        XCTAssertEqual(plan.deleteLocally, [c])
    }
}

final class TrainingProgramTests: XCTestCase {
    /// Trimmed from a real plan returned by the generate-program function.
    private let programJSON = """
    {
      "id": "7fcffe21-32a6-448f-a640-3d3e17b68614",
      "status": "active",
      "title": "8-week faster 5K builder",
      "summary": "Three runs a week toward a 26:00 5K.",
      "error": null,
      "created_at": "2026-10-26T17:45:01.123456+00:00",
      "plan": {
        "title": "8-week faster 5K builder",
        "summary": "Three runs a week toward a 26:00 5K.",
        "start_date": "2026-10-26",
        "weeks": [
          {
            "week": 1,
            "focus": "Establish rhythm and speed",
            "sessions": [
              {
                "id": "w1-tue", "day": "tue", "date": "2026-10-27", "kind": "intervals",
                "title": "Intervals 6 × 2:00",
                "description": "Run each rep at about 9:15/mile.",
                "workout": {
                  "warm_up_seconds": 300,
                  "steps": [{"phase": "work", "seconds": 120}, {"phase": "rest", "seconds": 90}],
                  "rounds": 6, "skip_last_rest": true, "cool_down_seconds": 300
                }
              },
              {
                "id": "w1-thu", "day": "thu", "date": "2026-10-29", "kind": "easy",
                "title": "Easy 25 min",
                "description": "Conversational pace.",
                "workout": {
                  "warm_up_seconds": 180,
                  "steps": [{"phase": "work", "seconds": 1500}],
                  "rounds": 1, "skip_last_rest": true, "cool_down_seconds": 180
                }
              }
            ]
          }
        ]
      }
    }
    """

    private func decode() throws -> TrainingProgram {
        try JSONDecoder.supabaseLike.decode(TrainingProgram.self, from: Data(programJSON.utf8))
    }

    func testDecodesProgramRow() throws {
        let program = try decode()
        XCTAssertEqual(program.status, .active)
        XCTAssertEqual(program.plan?.weeks.count, 1)
        XCTAssertEqual(program.plan?.sessions.map(\.id), ["w1-tue", "w1-thu"])
        XCTAssertEqual(program.plan?.sessions.first?.day, .tue)
        XCTAssertEqual(program.plan?.sessions.first?.kindLabel, "Intervals")
    }

    func testIntervalSessionBecomesSimpleWorkRestPlan() throws {
        let session = try XCTUnwrap(try decode().plan?.sessions.first)
        let plan = session.workout.workoutPlan
        XCTAssertFalse(plan.usesPattern)
        XCTAssertTrue(plan.warmUpEnabled)
        XCTAssertEqual(plan.warmUpSeconds, 300)
        XCTAssertEqual(plan.workSeconds, 120)
        XCTAssertEqual(plan.restSeconds, 90)
        XCTAssertEqual(plan.rounds, 6)
        XCTAssertTrue(plan.coolDownEnabled)
        // 5:00 + 6×2:00 + 5×1:30 + 5:00
        XCTAssertEqual(plan.totalSeconds, 300 + 720 + 450 + 300)
        XCTAssertTrue(plan.isValid)
    }

    func testEasyRunBecomesOneLongWorkInterval() throws {
        let session = try XCTUnwrap(try decode().plan?.sessions.last)
        let plan = session.workout.workoutPlan
        XCTAssertEqual(plan.segments, [Segment(.warmUp, 180), Segment(.work, 1500, round: 1), Segment(.coolDown, 180)])
    }

    func testWarmUpAndCoolDownCanBeSwitchedOff() throws {
        let session = try XCTUnwrap(try decode().plan?.sessions.last)
        XCTAssertEqual(
            session.workout.workoutPlan(warmUp: false, coolDown: true).segments,
            [Segment(.work, 1500, round: 1), Segment(.coolDown, 180)]
        )
        XCTAssertEqual(
            session.workout.workoutPlan(warmUp: true, coolDown: false).segments,
            [Segment(.warmUp, 180), Segment(.work, 1500, round: 1)]
        )
        XCTAssertEqual(session.workout.workoutPlan(warmUp: false, coolDown: false).totalSeconds, 1500)
    }

    func testMixedStepsBecomeACustomPattern() {
        let workout = ProgramWorkout(
            warmUpSeconds: 0,
            steps: [.init(phase: .work, seconds: 60), .init(phase: .rest, seconds: 60), .init(phase: .work, seconds: 120), .init(phase: .rest, seconds: 120)],
            rounds: 3,
            skipLastRest: true,
            coolDownSeconds: 0
        )
        let plan = workout.workoutPlan
        XCTAssertTrue(plan.usesPattern)
        XCTAssertFalse(plan.warmUpEnabled)
        XCTAssertEqual(plan.pattern.map(\.seconds), [60, 60, 120, 120])
        XCTAssertEqual(plan.segments.count, 11) // 4 × 3, minus the final rest
    }

    func testSessionDateIsLocalMidnight() throws {
        let session = try XCTUnwrap(try decode().plan?.sessions.first)
        let date = try XCTUnwrap(session.calendarDate)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 10, 27, 0])
    }
}

final class OnboardingAnswersTests: XCTestCase {
    func testEncodesSnakeCaseKeysForTheCoach() throws {
        var answers = OnboardingAnswers()
        answers.goal = .fasterFiveK
        answers.target5KMinutes = 26
        answers.trainingDays = [.tue, .sat]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(answers)) as? [String: Any])
        XCTAssertEqual(object["goal"] as? String, "faster_5k")
        XCTAssertEqual(object["target_5k_minutes"] as? Double, 26)
        XCTAssertEqual(object["training_days"] as? [String], ["tue", "sat"])
        XCTAssertEqual(object["max_session_minutes"] as? Int, 45)
    }

    func testMissingOrUnknownValuesFallBackToDefaults() throws {
        let json = #"{"goal": "ultramarathon", "training_days": ["mon"], "max_session_minutes": 60}"#
        let answers = try JSONDecoder().decode(OnboardingAnswers.self, from: Data(json.utf8))
        XCTAssertEqual(answers.goal, .firstFiveK)
        XCTAssertEqual(answers.trainingDays, [.mon])
        XCTAssertEqual(answers.maxSessionMinutes, 60)
        XCTAssertEqual(answers.surfaces, [.outdoors])
    }

    func testValidation() {
        var answers = OnboardingAnswers()
        XCTAssertNil(answers.validationMessage)
        answers.trainingDays = []
        XCTAssertNotNil(answers.validationMessage)
        answers.trainingDays = [.mon]
        answers.goal = .fasterFiveK
        XCTAssertNotNil(answers.validationMessage)
        answers.target5KMinutes = 25
        XCTAssertNil(answers.validationMessage)
    }

    func testRecordKeepsItsProgramLink() {
        let link = ProgramLink(programID: UUID(), sessionID: "w2-tue")
        let results = WorkoutResults(name: "Intervals", date: .now, completed: true, totalTime: 600, intervals: [], programLink: link)
        let record = WorkoutRecord(results: results)
        XCTAssertEqual(record.programID, link.programID)
        XCTAssertEqual(record.programSessionID, "w2-tue")
        XCTAssertNotNil(record.syncID)
        XCTAssertTrue(record.needsUpload)
    }
}

private extension JSONDecoder {
    /// Decodes Postgres timestamps (with fractional seconds and offset) like the Supabase client does.
    static var supabaseLike: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: string))
        }
        return decoder
    }
}

final class PlanTitleTests: XCTestCase {
    private func program(title: String?, planTitle: String?) -> TrainingProgram {
        TrainingProgram(
            id: UUID(), status: .active, title: title, summary: nil,
            plan: planTitle.map { ProgramPlan(title: $0, summary: "", startDate: "2026-10-05", weeks: []) },
            error: nil, createdAt: .now
        )
    }

    func testRenameWinsOverTheCoachsTitle() {
        XCTAssertEqual(program(title: "My spring 5K", planTitle: "9-week Couch to 5K").displayTitle, "My spring 5K")
    }

    func testFallsBackToThePlanTitle() {
        XCTAssertEqual(program(title: nil, planTitle: "9-week Couch to 5K").displayTitle, "9-week Couch to 5K")
        XCTAssertEqual(program(title: "  ", planTitle: "9-week Couch to 5K").displayTitle, "9-week Couch to 5K")
        XCTAssertEqual(program(title: nil, planTitle: nil).displayTitle, "Your plan")
    }
}
