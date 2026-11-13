import Foundation

/// A row of the `programs` table: an AI-built training plan.
struct TrainingProgram: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case generating, active, archived, failed
    }

    var id: UUID
    var status: Status
    var title: String?
    var summary: String?
    var plan: ProgramPlan?
    var error: String?
    var createdAt: Date
    /// The route chosen for each session: session id → route `syncID`.
    var sessionRoutes: [String: UUID]?

    enum CodingKeys: String, CodingKey {
        case id, status, title, summary, plan, error
        case createdAt = "created_at"
        case sessionRoutes = "session_routes"
    }

    /// The plan's name: the user's rename if any, else the coach's title.
    var displayTitle: String {
        let renamed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return renamed.isEmpty ? (plan?.title ?? "Your plan") : renamed
    }
}

/// The plan itself, as written by the `generate-program` function.
struct ProgramPlan: Codable, Equatable {
    var title: String
    var summary: String
    var startDate: String
    var weeks: [ProgramWeek]

    enum CodingKeys: String, CodingKey {
        case title, summary, weeks
        case startDate = "start_date"
    }

    var sessions: [ProgramSession] { weeks.flatMap(\.sessions) }
}

struct ProgramWeek: Codable, Equatable, Identifiable {
    var week: Int
    var focus: String
    var sessions: [ProgramSession]

    var id: Int { week }
}

struct ProgramSession: Codable, Equatable, Identifiable {
    var id: String
    var day: Weekday
    /// yyyy-MM-dd
    var date: String
    var kind: String
    var title: String
    var description: String
    var workout: ProgramWorkout

    var calendarDate: Date? { ProgramDate.date(from: date) }

    var kindLabel: String {
        switch kind {
        case "run_walk": "Run/walk"
        case "easy": "Easy run"
        case "intervals": "Intervals"
        case "tempo": "Tempo"
        case "long": "Long run"
        case "time_trial": "Time trial"
        default: kind.capitalized
        }
    }

    var kindIcon: String {
        switch kind {
        case "run_walk": "figure.walk"
        case "easy": "leaf"
        case "intervals": "bolt"
        case "tempo": "speedometer"
        case "long": "road.lanes"
        case "time_trial": "stopwatch"
        default: "figure.run"
        }
    }
}

struct ProgramWorkout: Codable, Equatable {
    struct Step: Codable, Equatable {
        var phase: Phase
        var seconds: Int
    }

    var warmUpSeconds: Int
    var steps: [Step]
    var rounds: Int
    var skipLastRest: Bool
    var coolDownSeconds: Int

    enum CodingKeys: String, CodingKey {
        case steps, rounds
        case warmUpSeconds = "warm_up_seconds"
        case skipLastRest = "skip_last_rest"
        case coolDownSeconds = "cool_down_seconds"
    }

    var hasWarmUp: Bool { warmUpSeconds > 0 }
    var hasCoolDown: Bool { coolDownSeconds > 0 }

    /// The same workout in the player's format. A plain "work, rest" or "work"
    /// round uses the simple layout so it's easy to edit if saved as a workout.
    var workoutPlan: WorkoutPlan {
        workoutPlan(warmUp: true, coolDown: true)
    }

    /// The workout with the warm-up and/or cool-down switched off, as the runner
    /// chose before starting. Turning one on has no effect if the plan has none.
    func workoutPlan(warmUp: Bool, coolDown: Bool) -> WorkoutPlan {
        var plan = WorkoutPlan(
            warmUpEnabled: warmUp && hasWarmUp,
            warmUpSeconds: hasWarmUp ? warmUpSeconds : 300,
            rounds: min(max(rounds, 1), 50),
            skipLastRest: skipLastRest,
            coolDownEnabled: coolDown && hasCoolDown,
            coolDownSeconds: hasCoolDown ? coolDownSeconds : 300
        )
        let phases = steps.map(\.phase)
        if phases == [.work, .rest] || phases == [.work] {
            plan.workSeconds = steps[0].seconds
            plan.restSeconds = steps.count > 1 ? steps[1].seconds : 0
        } else {
            plan.usesPattern = true
            plan.pattern = steps.map { IntervalStep(phase: $0.phase, seconds: $0.seconds) }
        }
        return plan
    }
}

enum ProgramDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Midnight local time on that day.
    static func date(from string: String) -> Date? {
        formatter.timeZone = .current
        return formatter.date(from: string)
    }

    static func string(from date: Date) -> String {
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// Ties a workout run to the program session it came from.
struct ProgramLink: Equatable {
    var programID: UUID
    var sessionID: String
}
