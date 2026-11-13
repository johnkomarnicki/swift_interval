import Foundation

enum Weekday: String, Codable, CaseIterable, Identifiable {
    case mon, tue, wed, thu, fri, sat, sun

    var id: String { rawValue }
    var short: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Answers to the questions asked after sign-up. Stored in `profiles.onboarding`
/// and sent to the AI when it builds a program, so the JSON keys are snake_case.
struct OnboardingAnswers: Codable, Equatable {
    enum Goal: String, Codable, CaseIterable, Identifiable {
        case firstFiveK = "first_5k"
        case runFiveKNonstop = "run_5k_nonstop"
        case fasterFiveK = "faster_5k"
        case tenK = "10k"
        case halfMarathon = "half_marathon"
        case fitness

        var id: String { rawValue }

        var title: String {
            switch self {
            case .firstFiveK: "Finish my first 5K"
            case .runFiveKNonstop: "Run a 5K without walking"
            case .fasterFiveK: "Run a faster 5K"
            case .tenK: "Train for a 10K"
            case .halfMarathon: "Train for a half marathon"
            case .fitness: "Get fitter and run regularly"
            }
        }

        var icon: String {
            switch self {
            case .firstFiveK: "flag.checkered"
            case .runFiveKNonstop: "figure.run"
            case .fasterFiveK: "stopwatch"
            case .tenK: "figure.run.circle"
            case .halfMarathon: "medal"
            case .fitness: "heart"
            }
        }
    }

    enum ContinuousRun: String, Codable, CaseIterable, Identifiable {
        case underOneMinute = "under_1_min"
        case oneToFive = "1_to_5_min"
        case fiveToFifteen = "5_to_15_min"
        case fifteenToThirty = "15_to_30_min"
        case thirtyPlus = "30_plus_min"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .underOneMinute: "Less than a minute"
            case .oneToFive: "1–5 minutes"
            case .fiveToFifteen: "5–15 minutes"
            case .fifteenToThirty: "15–30 minutes"
            case .thirtyPlus: "30 minutes or more"
            }
        }
    }

    enum Experience: String, Codable, CaseIterable, Identifiable {
        case new
        case underOneYear = "under_1_year"
        case oneToThreeYears = "1_to_3_years"
        case threePlusYears = "3_plus_years"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .new: "I'm new to running"
            case .underOneYear: "Less than a year"
            case .oneToThreeYears: "1–3 years"
            case .threePlusYears: "More than 3 years"
            }
        }
    }

    enum Surface: String, Codable, CaseIterable, Identifiable {
        case outdoors, treadmill, track

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum AgeRange: String, Codable, CaseIterable, Identifiable {
        case under20 = "under_20"
        case twenties = "20s"
        case thirties = "30s"
        case forties = "40s"
        case fifties = "50s"
        case sixtyPlus = "60_plus"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .under20: "Under 20"
            case .twenties: "20s"
            case .thirties: "30s"
            case .forties: "40s"
            case .fifties: "50s"
            case .sixtyPlus: "60+"
            }
        }
    }

    static let sessionLengths = [20, 30, 45, 60, 75, 90]

    var goal: Goal = .firstFiveK
    /// Goal 5K time, for "faster 5K".
    var target5KMinutes: Double?
    /// yyyy-MM-dd, when training for a race.
    var raceDate: String?
    var continuousRun: ContinuousRun = .oneToFive
    var recent5KMinutes: Double?
    var currentDaysPerWeek: Int = 0
    var currentWeeklyMiles: Double?
    var trainingDays: [Weekday] = [.tue, .thu, .sat]
    var maxSessionMinutes: Int = 45
    var experience: Experience = .new
    var injuries: String = ""
    var surfaces: [Surface] = [.outdoors]
    var ageRange: AgeRange?
    var notes: String = ""

    init() {}

    enum CodingKeys: String, CodingKey {
        case goal
        case target5KMinutes = "target_5k_minutes"
        case raceDate = "race_date"
        case continuousRun = "continuous_run"
        case recent5KMinutes = "recent_5k_minutes"
        case currentDaysPerWeek = "current_days_per_week"
        case currentWeeklyMiles = "current_weekly_miles"
        case trainingDays = "training_days"
        case maxSessionMinutes = "max_session_minutes"
        case experience, injuries, surfaces
        case ageRange = "age_range"
        case notes
    }

    /// Missing or unrecognized values fall back to defaults, so answers saved by
    /// an older version of the app still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OnboardingAnswers()
        goal = (try? c.decodeIfPresent(Goal.self, forKey: .goal)) ?? defaults.goal
        target5KMinutes = try? c.decodeIfPresent(Double.self, forKey: .target5KMinutes)
        raceDate = try? c.decodeIfPresent(String.self, forKey: .raceDate)
        continuousRun = (try? c.decodeIfPresent(ContinuousRun.self, forKey: .continuousRun)) ?? defaults.continuousRun
        recent5KMinutes = try? c.decodeIfPresent(Double.self, forKey: .recent5KMinutes)
        currentDaysPerWeek = (try? c.decodeIfPresent(Int.self, forKey: .currentDaysPerWeek)) ?? defaults.currentDaysPerWeek
        currentWeeklyMiles = try? c.decodeIfPresent(Double.self, forKey: .currentWeeklyMiles)
        trainingDays = (try? c.decodeIfPresent([Weekday].self, forKey: .trainingDays)) ?? defaults.trainingDays
        maxSessionMinutes = (try? c.decodeIfPresent(Int.self, forKey: .maxSessionMinutes)) ?? defaults.maxSessionMinutes
        experience = (try? c.decodeIfPresent(Experience.self, forKey: .experience)) ?? defaults.experience
        injuries = (try? c.decodeIfPresent(String.self, forKey: .injuries)) ?? ""
        surfaces = (try? c.decodeIfPresent([Surface].self, forKey: .surfaces)) ?? defaults.surfaces
        ageRange = try? c.decodeIfPresent(AgeRange.self, forKey: .ageRange)
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
    }

    /// Problems that stop the answers from being saved, or nil.
    var validationMessage: String? {
        if trainingDays.isEmpty { return "Pick at least one day you can train." }
        if goal == .fasterFiveK, target5KMinutes == nil { return "Enter the 5K time you're aiming for." }
        return nil
    }
}
