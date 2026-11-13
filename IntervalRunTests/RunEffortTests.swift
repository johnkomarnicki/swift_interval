import XCTest
@testable import IntervalRun

final class RunEffortTests: XCTestCase {
    func testRawValuesMatchTheDatabase() {
        XCTAssertEqual(RunEffort.allCases.map(\.rawValue), ["easy", "just_right", "hard", "too_hard"])
        XCTAssertEqual(RunEffort(rawValue: "too_hard"), .tooHard)
        XCTAssertNil(RunEffort(rawValue: "tooHard"))
    }

    func testRecordStoresEffortAsRawValue() {
        let record = WorkoutRecord(results: results())
        XCTAssertNil(record.runEffort)
        record.runEffort = .justRight
        XCTAssertEqual(record.effort, "just_right")
        record.runEffort = nil
        XCTAssertNil(record.effort)
    }

    @MainActor
    func testRemoteRowWithoutEffortEncodesNull() throws {
        let row = RemoteWorkoutRecord(WorkoutRecord(results: results()))
        let data = try JSONEncoder().encode(row)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object.keys.contains("effort"))
        XCTAssertTrue(object["effort"] is NSNull)

        let decoded = try JSONDecoder().decode(RemoteWorkoutRecord.self, from: data)
        XCTAssertEqual(decoded, row)
        XCTAssertNil(decoded.makeRecord().runEffort)
    }

    @MainActor
    func testRemoteRowRoundTripsEffort() throws {
        let record = WorkoutRecord(results: results())
        record.runEffort = .tooHard
        let row = RemoteWorkoutRecord(record)
        let data = try JSONEncoder().encode(row)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["effort"] as? String, "too_hard")

        let decoded = try JSONDecoder().decode(RemoteWorkoutRecord.self, from: data)
        XCTAssertEqual(decoded, row)
        let restored = decoded.makeRecord()
        XCTAssertEqual(restored.runEffort, .tooHard)
        XCTAssertEqual(restored.syncID, record.syncID)
        XCTAssertFalse(restored.needsUpload)
    }

    private func results() -> WorkoutResults {
        WorkoutResults(
            name: "Intervals",
            date: Date(timeIntervalSinceReferenceDate: 800_000_000),
            completed: true,
            totalTime: 600,
            intervals: [],
            programLink: ProgramLink(programID: UUID(), sessionID: "w2-tue")
        )
    }
}
