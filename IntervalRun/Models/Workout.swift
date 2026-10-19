import Foundation
import SwiftData

/// A saved workout, stored on the phone with SwiftData.
@Model
final class Workout {
    var name: String = ""
    var createdAt: Date = Date.now
    var warmUpEnabled: Bool = false
    var warmUpSeconds: Int = 300
    var workSeconds: Int = 90
    var restSeconds: Int = 60
    var rounds: Int = 6
    var skipLastRest: Bool = true
    var coolDownEnabled: Bool = false
    var coolDownSeconds: Int = 300
    var usesPattern: Bool = false
    /// JSON-encoded `[IntervalStep]`, nil when there is no custom pattern.
    var patternData: Data? = nil

    init(name: String, plan: WorkoutPlan, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
        self.plan = plan
    }

    /// The timing settings as a value type. Setting it copies every field back.
    var plan: WorkoutPlan {
        get {
            WorkoutPlan(
                warmUpEnabled: warmUpEnabled,
                warmUpSeconds: warmUpSeconds,
                workSeconds: workSeconds,
                restSeconds: restSeconds,
                rounds: rounds,
                skipLastRest: skipLastRest,
                coolDownEnabled: coolDownEnabled,
                coolDownSeconds: coolDownSeconds,
                usesPattern: usesPattern,
                pattern: patternData.flatMap { try? JSONDecoder().decode([IntervalStep].self, from: $0) } ?? []
            )
        }
        set {
            warmUpEnabled = newValue.warmUpEnabled
            warmUpSeconds = newValue.warmUpSeconds
            workSeconds = newValue.workSeconds
            restSeconds = newValue.restSeconds
            rounds = newValue.rounds
            skipLastRest = newValue.skipLastRest
            coolDownEnabled = newValue.coolDownEnabled
            coolDownSeconds = newValue.coolDownSeconds
            usesPattern = newValue.usesPattern
            patternData = newValue.pattern.isEmpty ? nil : try? JSONEncoder().encode(newValue.pattern)
        }
    }

    func duplicate() -> Workout {
        Workout(name: "\(name) copy", plan: plan)
    }

    static func sample() -> Workout {
        Workout(
            name: "Week 3: 6 × 90s / 60s",
            plan: WorkoutPlan(
                warmUpEnabled: true,
                warmUpSeconds: 300,
                workSeconds: 90,
                restSeconds: 60,
                rounds: 6,
                skipLastRest: true,
                coolDownEnabled: true,
                coolDownSeconds: 300
            )
        )
    }
}
